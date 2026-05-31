# Sampler Producer Hazard-Site Design

Status: design note; implementation gated on review and representativeness close.

## Objective

Phase-1 profiling found that the BAR-B producer path is dominated by the
sampler read-after-write dependency, not ordinary per-draw GL setup:

- Warm 64x64 no-upload producer run: `sampler_producer_drain` was 77.6% of
  `APPGL_GL_DRAW_PROFILE`, about 43.2 us per draw.
- Cold 4096x4096 no-upload producer run: `sampler_producer_drain` was 89.2%,
  about 258.9 us per draw.
- The matching command-buffer profile bucket was
  `FlushForReadback/commit-and-wait/readback`, one wait per sampled-present
  frame, not one wait per producer draw.

The Phase-2 target is therefore the FBO-render -> sampled-texture hazard. The
optimization must preserve data coherence: a perf win that can sample stale
pixels is a regression.

## Representativeness Check

BAR-B producer is representative of an FBO producer followed by a sampled
texture consumer. Its producer mode performs many FBO writes to a texture, then
the default-framebuffer present draw samples that same texture.

The local GLTest BenchInternal evidence does not yet prove the same app-level
hazard for the canonical 4K 358 us/draw number:

- GLTest `BenchInternalScene` mode-12 isolator source uses the general draw
  path (`glDrawElements`) and does not show an FBO texture sample in the
  isolator loop.
- The GLTest worker savefile describes the 358.923 us/draw run as
  "BenchInternal general-draw path only; TESS/MDI excluded"; the "BAR-shape"
  label there means the 4000-draw synthetic substitute, not necessarily the
  BAR-B FBO-sample producer shape.

So this design is valid for BAR-B producer and the DCR3-C sampled-texture
producer-coherence lineage. It should not be claimed as explaining or fixing
the canonical BenchInternal 358 us/draw path until GLTest/Clerk confirms that
BenchInternal also renders to an FBO texture and samples it, or a direct
BenchInternal run with `APPGL_GL_DRAW_PROFILE=1` shows the same
`sampler_producer_drain` dominance.

If GLTest confirms BAR-B producer is the intended 3A-equivalent for the
FBO-sample surface, then this design is the Phase-2 track for that surface. If
BenchInternal is direct-draw only, this remains a BAR-B/DCR3-C producer track
and BenchInternal needs a separate attribution track.

## Non-Goals

- Do not generically defer or batch the existing sampler-side drain call.
- Do not clear producer-pending bits merely because a GPU consumer was encoded.
  A later CPU readback must still wait if the producer command buffer has not
  completed.
- Do not use leak/memory probes as coherence proof. The S22 texture-lazy lesson
  is that leak-clean can still be data-coherence-broken.
- Do not change command-buffer pressure policy, in-flight bounds, or broad
  `flushForReadback` behavior for CPU-visible consumers in this design step.

## Current Problem

`resolveSamplerBindings` forms a texture read set and calls
`drainPendingGpuProducers`. The helper has only a pending bit; it does not know
which producer command buffer owns the hazard or whether that producer has
already completed. If any matching bit is present, it calls
`frameGraph->flushForReadback()`, which commits and waits.

That is correct for CPU visibility, but over-serializes GPU-to-GPU
read-after-write. A sampled draw only needs the FBO producer ordered before the
sampling draw. It does not need the CPU to wait for the producer to complete.

## Hazard-Site Model

Add precise producer dependency state at the producer mark site. A pending
resource bit should carry a producer token, not just a Boolean:

```cpp
struct GpuProducerToken {
    uint64_t epoch;
    uint32_t producerBits;
    AppGLCommandReason reason;
    AppGLSubmissionResourceKind resourceKind;
    GLuint resourceName;
    uint64_t commandBufferSequence;
    bool sameQueueOrdered;
    std::atomic_bool completed;
};
```

The exact storage can differ, but the required semantics are:

- Producer marking records the latest producer token for the resource bits.
- The command-buffer completion handler marks the token completed.
- A newer token supersedes an older token for the same resource bits on the
  same queue; waiting for the latest ordered token is enough for final contents.
- Texture aliases must resolve to the same backing-storage token set, matching
  the existing texture-view alias handling.

`AppGLSubmissionGroup` already declares resource reads and writes. It can be
extended to attach producer tokens to encoded work, but the authoritative
hazard state must live on the resource/backing storage because later consumers
need to query it.

## GPU Consumer Rule

The sampler binding path may remain the discovery point for a read set, but the
optimization decision is made from the producer token:

1. No matching token: bind normally.
2. Token completed: clear the completed pending bits lazily and bind normally.
3. Token belongs to the current open framegraph command buffer: encode the
   sampling draw after the producer pass in the same command buffer, ending the
   current render encoder if required. No CPU wait.
4. Token belongs to a prior command buffer already submitted to the same Metal
   queue: commit the consumer after it. Queue FIFO ordering satisfies the GPU
   read-after-write hazard. No CPU wait.
5. Token has unknown ordering, crosses a queue/domain not modeled here, or
   represents a producer family outside the token model: fall back to the
   existing `flushForReadback()` wait.

Cases 3 and 4 must not clear CPU-visibility pending state. They only prove that
this GPU consumer is ordered after the specific producer it reads. A later
`glReadPixels`, `glGetTexImage`, lifecycle edge, or CPU shadow read still waits
unless the token has completed by then.

## CPU Consumer Rule

CPU-visible consumers keep the existing safety contract with one refinement:

- If all matching producer tokens are already completed, clear the pending bits
  without a wait.
- If any matching token is incomplete, call the existing `flushForReadback()`
  path and clear only after the wait completes.

This makes the completed-token skip safe without changing CPU readback
semantics.

## Implementation Slices

1. Token instrumentation only: attach producer tokens and completion state while
   keeping `drainPendingGpuProducers` behavior unchanged. Add counters for
   completed-token skip candidates and GPU-ordered sampler candidates.
2. Completed-token skip: allow sampler and CPU consumers to avoid
   `flushForReadback()` only when the exact producer token is already complete.
3. Same-queue GPU ordering for sampler reads: remove the CPU wait for
   FBO-texture -> sampler hazards when the producer token is known ordered by
   same-command-buffer or same-queue FIFO. Keep fallback to the old drain for
   unmodeled producers.
4. Generalize only after the BAR-B/DCR3-C sampler surface is green. Storage
   images, SSBOs, blits, mipmaps, and sparse sidecars have similar structure
   but should not be broadened in the first behavior-changing slice.

## Validation Gates

Performance gate:

- Re-run the Phase-1 BAR-B profiles:
  - warm 64x64 no-upload producer
  - cold 4096x4096 no-upload producer
- Expected movement: `sampler_producer_drain` and
  `FlushForReadback/commit-and-wait/readback` inside the draw core drop
  sharply. Some time may move to final frame/readback waits in synthetic runs;
  report both core and total wall-clock so the shift is visible.
- If BenchInternal representativeness closes, run the same profile flags there
  and require the same bucket-level explanation.

Coherence gate:

- DCR3-C producer-pending sentinels, especially FBO texture write -> sampler
  consumer -> readback.
- Focused shader sampler/readback cases where a texture is produced by FBO,
  copy/blit, storage image, mipmap, or upload before being sampled.
- CTS/gauntlet P->F=0 versus the selected baseline. A single new stale-pixel
  failure blocks the perf credit.
- Lifecycle checks for deleting/redefining texture objects with incomplete
  producer tokens.

Negative proof:

- A leak/memory probe is not a substitute for the coherence gate. It can be
  run as a resource-lifetime check, but it does not prove sampled data is fresh.

## Review Checklist

- Does every optimized skip name the exact producer token it relies on?
- Is the producer token complete or explicitly GPU-ordered before the consumer?
- Are CPU-visible pending bits kept until completion or a real wait?
- Does every unmodeled producer family fall back to the old wait?
- Are texture aliases and texture views resolved to the same backing hazard?
- Are perf and coherence gates both green before claiming Phase-2 credit?
