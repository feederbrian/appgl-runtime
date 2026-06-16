# Phase 2 Encode-Under-Churn Design

Status: design note; Slice 1 instrumentation is opt-in; behavior-changing
levers remain gated on the viewport re-baseline attribution, Foreman review, and
SCOUT-W review.
Date: 2026-05-31

## Gate State

Viewport correctness is closed at `886b1a4`. The corrected head changed the
performance surface because the live MDI wall now coalesces compatible
CPU-authored indirect draws from 128 calls to 1. That makes the older Phase 2
numbers directionally useful but no longer sufficient for authorization.

Do not implement Lever A until the viewport re-baseline attribution answers the
load-bearing question:

> After the MDI coalescing correction, does encode-under-churn still dominate
> the real-app frame cost at the 500-5000 draw target range?

The design work may proceed now so the implementation is ready to start if the
attribution stays positive. The implementation gate remains closed until
GLTest reports the now-correct viewport profile and Foreman explicitly releases
the lever.

> **SUPERSEDED (2026-06-15) for the post-W2-crown surface — see "S25 Post-W2-Crown
> Localization" immediately below.** The S23 gate above (viewport re-baseline,
> `d17e298`-era) is retained for lineage. The W2 CB-leak crown (`5a79c25c` =
> `2566e14`) re-baselined the performance surface and a fresh 6-bucket profile
> moved the target; the load-bearing attribution question is answered there.

## S25 Post-W2-Crown Localization — state_resolve MSL-Hash Memo (2026-06-15)

Status: **design-of-record for the state_resolve lever.** Operator-greenlit
(design phase, read-only). Implementation gated on operator examination + explicit
go. Default-OFF; crown-rotation only on a green gate + operator express in-session
permission + operator live-run.

### S23 → S25 supersede: why the target moved

The S23 gate gated Lever A on whether encode-under-churn still dominates. It does —
but the W2 plan-prepare-at-record (`recordPlanMemo`) already collapsed the S23 #1
cost (`phase2_plan_lookup`, 7.748 ms), which had been **masking** the durable
bottleneck. A 6-bucket per-draw CPU re-profile on the W2 crown (read-only,
DYLD-explicit on `5a79c25c`/`09431D80`, steady-state, relative shares; full table
in `live-targets/appgl-bridge/FOREMAN-S25-PERF-PROFILE-RESULT.md`) exposed it:

- **`state_resolve` ≈ 54% of the per-draw GL-wrapper** (71.3% of
  `framegraph_encode` × 76.5% wrapper-share), #1 by ~4×.
- `phase2_plan_lookup` demoted to 5.0% (W2 worked, as predicted).
- `submission_group` / `preflight` negligible (1.0% / 0.1%).
- Threading is **out** on three independent grounds (draw-encode = 2.8%;
  `PARALLEL_ENCODE` forms zero batches on the crown; `state_resolve` is per-draw
  work *inside* the encode, not the draw-encode). Efficiency-vs-threading framing
  is in the Next-Ceiling cadence below.

### The localized root (a surgical instance of Lever A)

`state_resolve`'s dominant cost is **not** VAO/uniform/texture resolution — it is the
per-draw **re-hash of the full vertex + fragment MSL source** in
`computePipelineCacheKey` (`MetalFrameGraph.mm:4234-4246`, O(KB)/draw). The key's
downstream consumers (slot-cache `translatedDrawMSLSlots`@22727, PSO cache@6021) are
already memoized by the resulting key; **the key-compute is the lone un-memoized
step.** It runs every draw because the W2 plan-prepare that would skip it
(`recordPlanMemo` via `ensureRecordPreparedPlanForArm`) bypasses the dominant ~56%
FBO draws (Requirement-2 prepare-skip @23085-91 → `translatedPlan` null).

Empirically confirmed (read-only, existing Run B): **PSO-cache hit-rate 96.36%**
(35078/1326) → the cost is the pre-cache key-compute, not PSO builds;
`recordPlanMemo` disaggregates 20615 lean-memoized vs ~36K FBO-bypass draws (the
re-hash population). This is the surgical isolation of Lever A's "pipeline cache key"
payload term — the single most expensive un-memoized contribution.

### Lever: memoize the MSL-hash term, keep the prefix per-draw

Split `computePipelineCacheKeyFromPrefix` (`MetalFrameGraph.mm:4219`):

- (a) the **MSL-FNV contribution** — `mixString(vertexMSL)` + `mixString(fragmentMSL)`,
  the O(KB) cost — becomes a **memoized lookup**;
- (b) the **per-draw finalize** mixes the cheap O(1) prefix word into the memoized
  MSL-FNV.

**Implementation boundary (load-bearing):** memoize ONLY the MSL-hash term; KEEP the
prefix mixed per-draw — the prefix is what discriminates the per-sample-FS /
clip-control / multiview variants. A memo that swallows the prefix (whole-key per
program) re-introduces variant collisions.

### Keying — MSL-STRING IDENTITY (the correctness core)

Key the MSL-FNV memo on **MSL-string identity**, not program-id: reuse the existing
in-production `phase2PlanHashShaderIdentity` (`GLContext.mm:2243-2251` =
`{string-obj-ptr, size, data-ptr}`, already applied @2345-46 for the phase2 plan
key), as the **PAIR** `{vertexMSL-identity, fragmentMSL-identity}` (the GS-replay
path can mix a gsPassThrough-vertex with a base-fragment, so the pair is required).

**Why string-identity, not per-program (stabilizing rationale).** String-identity is
correctness-complete **by construction**: a content/identity key cannot alias two
distinct hashed MSL strings no matter how many code paths re-point
`tdi.{vertex,fragment}MSL`. Per-program keying is complete *only under exhaustive
enumeration* of every re-point site — an open-ended obligation that already failed
once: a first inspection cleared per-sample-FS / clip-control / multiview (all
genuinely prefix-encoded) and concluded per-program safe, but an **exhaustive sweep**
found the **GS-emulation / tessellation replay** path (`GLContext.mm:39108-39185`)
re-points the hashed pointers to rewritten variants —
`tdi.vertexMSL ← &program.gsPassThroughVertexMSL` (@39119);
`tdi.fragmentMSL ← &program.gsPassThroughFragmentMSL` (@39171, rewritten in place via
`std::move` @39144 on `primIdLoc` change, through `rewriteFragmentMSLForPrimitiveID` /
`rewriteFragmentMSLForFp64StageIn`) — under the **same link-generation** and **not
prefix-encoded**. A per-program key would alias base vs GS-replay in the shared
slot-cache@22727 = a real correctness bug for GS/tessellation draws. (Verified
independently by Worker's sweep, Foreman, and Clerk reading the source.)
String-identity makes correctness independent of that enumeration ever being complete.

**ABA / invalidation.** MSL strings are KB-sized → always heap, non-SSO → the
data-ptr is a reliable realloc signal. All content-mutation sites assign/`std::move`
from a fresh string (new data-ptr): GS draw-time rewrites
(`synthesisePassThroughVertexMSL` @38919, `gsPassThroughFragmentMSL` @39144) and
link-time base reassembly. Fold memo-entry invalidation into those existing mutation
sites (the gsPassThrough cache-clear @39150-61 + the link clears), with the **P1
content-equality probe** as defense-in-depth against the residual theoretical ABA.

**Not bit-identical.** The new key value differs from the crown's (FNV mixes prefix
first, then MSL; reordering to memoize the MSL term changes the value). The safety
invariant is therefore *not* bit-identicality but: (1) **consistency** — every live
key-compute site adopts the scheme atomically (live site = `5911` only; `9441` is
dormant — zero callers / zero enqueue sites — updated for hygiene); (2) **no persisted
keys** — the key feeds only in-memory per-run caches (rebuilt each launch), so a
scheme change strands no on-disk cache; (3) **collision-resistance unchanged** — same
FNV inputs, reordered → same discrimination (re-validated by the P1/P2 probes).

**Thread-safety.** The live key-compute (`5911`) is GL-thread-confined; the
`dispatch_apply` workers consume the precomputed key and do not recompute. The memo
is lock-free by construction; compute the MSL-FNV on the GL thread (first use / at
link) so it is read-only when workers run.

### Validation gate (pre-registered, 3-axis)

Verbatim source: `live-targets/appgl-bridge/FOREMAN-STATE-RESOLVE-GATE-INPUT.md`.
ALL three axes must pass before any crown-rotation.

- **Axis A — MAGNITUDE (the A/B re-profile, headline exit).** Re-run the *identical*
  6-bucket profile, candidate vs crown `5a79c25c`, same harness/posture. Subject
  discipline: DYLD-insert each dylib explicitly (not build-release — it drifts),
  UUID-confirm, and **shape-equivalence** (Release-shape ≈ crown; HALT on
  debug/-O0/ASAN — it inflates buckets unevenly and the relative-share read lies).
  Engagement (non-vacuity): the memo provably fires on FBO draws (hit-rate > 0, MSL
  re-hash count → ~0 there); a zero-fire candidate auto-fails. PASS BAR
  (pre-registered, RELATIVE share — not an absolute-µs claim): `state_resolve` share
  drops to its non-re-hash residual (pre-register the residual target from Worker's
  sub-op sizing before the run). Magnitude sanity: the drop must account for the
  predicted re-hash share, else wrong root → do not crown.
- **Axis B — CORRECTNESS NO-REGRESS.** SCOUT-W full P→F=0 KHR-GL46/CTS, candidate vs
  crown. Variant-discrimination positive-controls (the cache-coherence axis), led by
  the **decisive GS-replay control** — same program's normal draw vs its GS-replay
  draw (primitiveID, and fp64-stage-in; the @39119/@39171 re-point) must get DISTINCT
  keys + correct PSO + NO slot-cache@22727 alias — then per-sample-FS / clip-control /
  multiview, plus re-link re-computes, plus no-persisted-keys confirm.
- **Axis C — BUILD POSTURE.** Default-OFF env-gated for clean A/B isolation;
  crown-applicable (rotate `5a79c25c` → candidate) only on Axis-A ∧ Axis-B green with
  operator express in-session permission (crown-flow: archive-first rollback,
  verify-the-irreversible-step, atomic sidecar regen, no teammate-relay auth) and the
  operator's own live-run.

### Next-ceiling cadence + M2-M6+ scaling

Verbatim source: same Foreman doc, Section 2.

- **The ladder:** profile → lever → re-profile → next-ceiling → repeat, run until
  GPU-bound (hand-off to the Metal-Opt Stage S27, whose §5 entry-gate *is* the
  GPU-bound check). Each lever's Axis-A re-profile names the next #1.
- **Standing prediction:** if `state_resolve` collapses, `pipeline_build` (12.7%) is
  the likely next #1. Pre-register each rung; the re-profile falsifies/confirms.
- **Machine-class honesty:** relative shares are machine-class-dependent — per-hardware
  re-profile (M2/M3/M4/M5/M6) before claiming a lever "scales cleanly"; a lever
  crowned on M1 Max stays gated on a per-class re-profile.
- **Single-core-ceiling → threading go/no-go:** each re-profile also estimates the
  residual single-thread per-draw cost → single-core submission ceiling (draws/sec),
  compared per machine-class vs GPU draw-consumption. One core feeds the GPU →
  efficiency sufficed; one core can't (likely high-end M5/M6) → that is the *measured*
  trigger for the record/replay threading arc (`s25-threading-arc-seed`, Mesa-TC),
  held in reserve — which pays off by then because the efficiency ladder shrank the
  serial fraction (raised the Amdahl ceiling; you don't thread a 97%-serial path —
  why W1 walled). The ladder terminus is the threading decision point, on data.

### Implementation slices

1. **Scaffold (default-OFF):** add the MSL-identity PAIR memo + counters
   (lookup/hit/miss/invalidate) at the `computePipelineCacheKeyFromPrefix` split;
   env-gated; OFF path = the unchanged crown key scheme.
2. **Engage:** ON path uses the split scheme (memoized MSL-FNV by identity + per-draw
   prefix mix); wire invalidation into the existing mutation/clear sites.
3. **A/B + correctness:** run the 3-axis gate (Axis A re-profile, Axis B SCOUT-W +
   positive-controls, shape-equivalence).
4. **Rotation (operator-gated):** only on a green gate, with operator express + live-run.

### Decision posture

This section is the design for the operator to examine. The next step —
implementation — is the first move beyond the read-only research mandate and is the
operator's go/no-go. Nothing here has touched code or the canonical pin; all upstream
work was read-only.

## Objective

The S23 viewport correctness arc is closed. Phase 2 targets the remaining
real-app performance cliff only if the re-baseline confirms it: realistic state
churn serializes AppGL's GL-to-Metal encode path enough that the
real-app-pattern benchmark misses the operator's 120 FPS floor early in the
500-5000 draw range.

Pre-viewport-close baseline from the d17e298 stock real-app-pattern run:

| Draws | FPS | Frame Time | Gap to 120 FPS |
| ----- | --- | ---------- | -------------- |
| 100 | 103.4 | 9.7 ms | 1.2x |
| 500 | 23.2 | 43.1 ms | 5.2x |
| 2000 | 5.8 | 172 ms | 20.7x |
| 5000 | 2.5 | 400 ms | 48x |
| 20000 | 0.63 | 1587 ms | 190x |

The 120 FPS budget is 8.33 ms/frame. At 500 draws that is 16.7 us total
per draw. At 5000 draws it is 1.7 us total per draw, which is a stretch goal
unless the workload collapses into a hardware-batched path. Phase 2 should
therefore report both:

- the practical low/mid draw-count floor that can hold 120 FPS after the lever;
- the high-draw-count stretch curve and what additional batching or hardware
  routing would be required to reach it.

## Current Attribution

The useful baseline is harness-free real-app-pattern, not the older
BenchInternal `glFinish`-inflated 358 us number. Treat the numbers below as the
pre-`886b1a4` attribution until GLTest publishes the viewport re-baseline.

Current real-app profile shape:

- full cost is about 80-97 us/draw under realistic churn;
- about half is app-workload setup/state churn outside the AppGL wrapper;
- AppGL GL-wrapper cost is about 43.9 us/draw;
- `framegraph_encode` is the dominant AppGL bucket at about 29.5 us/draw;
- inside `framegraph_encode`, `state_resolve` is about 12.55 us and
  `encoder_setup` is about 8.44 us;
- `sampler_producer_drain` is negligible for this path.

Source shape:

- `GLContext::Impl::encodeTranslatedDrawAndMarkFbo` builds a `TranslatedDrawInfo`
  wrapper, declares the submission group, then calls
  `frameGraph->encodeTranslatedDraw`.
- `MetalFrameGraph::Impl::encodeTranslatedDraw` re-derives the pipeline key,
  shader slot metadata, argument-buffer needs, render-pass/encoder state, and
  resource bindings for each draw.
- The existing VAO layout cache (`cachedVertexArrayLayout`) helps stable VAO
  layouts, but the real-app workload intentionally churns state; a last-state
  cache is not enough.

The target is therefore not a single-threaded micro-shave. The target is to
make the encode path flex Apple Silicon resources: use memory for structural
memoization, cores for parallel draw preparation where GL ordering allows it,
and Metal hardware routing to reduce repeated per-draw binding work.

Foreman-reported Slice 1 signal before the viewport re-baseline showed a
98.18% churned-hit surface for the candidate plan key. That is strong enough to
prepare Lever A, not strong enough to ship it. The re-baseline must confirm the
same hit surface matters after MDI coalescing changes the draw mix.

## Design Constraints

- Preserve GL draw order. Do not reorder overlapping draws, blending,
  depth/stencil side effects, transform feedback, image/SSBO writes, queries,
  or readbacks unless a proof says the sequence is order-independent.
- Preserve CPU-visible synchronization. Phase 2 must not hide stale pixels or
  stale buffer contents from `glReadPixels`, `glGetTexImage`,
  `glGetBufferSubData`, mapped reads, or lifecycle edges.
- Do not build a churn-busted last-draw cache. Cache keys must describe stable
  structural state, not the last draw serial.
- Keep caches bounded and invalidated by explicit generations. Perf credit is
  not worth unbounded memory growth or stale resource bindings.
- Maintain a conformance gate of P-to-F equals zero for the selected SCOUT-W
  baseline before claiming the lever.

## Lever A: Structural Draw-Plan Memoization

First implementation candidate.

Build a reusable `TranslatedDrawPlan` for the parts of
`TranslatedDrawInfo`/`encodeTranslatedDraw` that are structural rather than
per-draw values. The plan is keyed by structural state and fills a per-draw
packet with the current dynamic values.

Design contract:

- `TranslatedDrawPlan` is a memoized recipe, not a draw snapshot.
- The plan may cache decisions that are invariant for a structural state shape.
- The plan must not own live GL object contents, live Metal resource pointers, or
  producer-token state.
- A cache hit must produce the same `TranslatedDrawInfo`/Metal binding behavior
  as the current direct path for the same GL state.
- Any missing generation, side effect, or hazard proof is a miss or reject, not a
  fallback approximation.

Candidate key fields:

- program object/generation and translated MSL generation;
- VAO object plus `attribGeneration`, or a content hash for layout-equivalent
  VAOs when safe;
- draw mode/topology class, indexed vs arrays, instanced vs non-instanced;
- fixed-function state fingerprint: blend tuple, depth/stencil tuple,
  rasterizer state, clip origin/depth mode, viewport-array shape,
  sample mask/shading, polygon offset, cull/front-face/fill mode;
- framebuffer attachment signature: color/depth/stencil Metal formats,
  sample counts, array/layer shape, attachmentless FBO shape;
- resource layout shape: which samplers, UBOs, SSBOs, images, atomics, and
  push/default uniform blocks the program uses, plus their Metal slots;
- argument-buffer mode and shader slot metadata.

Candidate cached payload:

- pipeline cache key and translated shader slot metadata;
- vertex descriptor / vertex layout binding plan;
- fixed-function binding plan for depth/stencil, cull, winding, fill,
  sample mask, viewport/scissor mode, and polygon offset;
- resource binding plan mapping program reflection entries to GL texture units
  and buffer binding points;
- submission-group read/write classification that does not depend on the
  current object names;
- flags that decide whether the draw can use argument-buffer or future ICB
  paths.

Candidate per-draw packet populated from a plan:

- current vertex/index object names, Metal buffers, offsets, counts, and ranges;
- current uniform bytes, dynamic UBO offsets, and ring-buffer allocations;
- current texture, sampler, image, SSBO, atomic-counter, and buffer binding
  objects;
- current viewport/scissor rectangles and depth-range arrays;
- current FBO attachment objects and drawable/FBO dimensions;
- read/write resource declarations with actual object names;
- a hazard summary produced from live producer-token state immediately before
  encode.

Dynamic values that must remain per draw:

- vertex/index buffer object names, Metal pointers, offsets, counts;
- current uniform bytes and ring offsets;
- actual texture/sampler objects and buffer binding objects;
- viewport/scissor rectangles;
- FBO attachment object pointers;
- producer-token state and pending read/write hazards;
- query/TF/feedback side effects.

### GAP-A2 Hazard Composition

The compute-source MDI fix at `886b1a4` is the rule for Lever A: producer-token
discipline composes with memoization only when the memoized path keeps live
hazards outside the cached payload.

Required behavior:

- Plan keys may include resource layout shape and read/write classes, but not the
  current pending producer bits.
- Plan payload may classify that a draw reads a vertex buffer, an index buffer,
  sampled textures, SSBOs, images, UBOs, atomics, or FBO attachments, but it must
  bind actual resource names and hazard bits per draw.
- A cache hit must still call the same producer-drain logic as the direct path
  before reading CPU-visible shadow bytes or before using a resource as a GPU
  read after a GPU write.
- Direct-Metal VBO binding must stay selected for GPU-authored vertex buffers
  even when a plan-hit draw is otherwise structurally identical to a CPU-authored
  draw.
- The recent-GPU-write state (`gpuAuthoredSinceCpuWrite`) is live object state.
  It cannot be baked into a reusable plan and cannot be cleared by a plan hit.
- Argument-buffer or future ICB routes inherit the same rule: they may memoize
  binding layout, but actual resources and producer fences are populated from
  the current draw packet.

Reject conditions:

- any draw whose correctness depends on CPU shadow bytes for a resource with
  pending or recent GPU writes;
- any resource alias where the read/write relationship cannot be represented in
  the plan's live hazard packet;
- any command sequence where plan replay would bypass `drainPendingGpuProducers`,
  framebuffer attachment producer drains, or readback invalidation.

Invalidation:

- program relink invalidates all plans for that program;
- VAO attribute mutation invalidates plans keyed by that VAO generation;
- framebuffer attachment mutation invalidates plans keyed by that FBO
  generation;
- texture sampler parameter changes invalidate sampler-state payload only, not
  the whole program reflection plan;
- global fixed-function state changes select a different structural key rather
  than mutating the prior plan.

Plan cache ownership:

- Store plans per context, because GL object names and program/VAO/FBO
  generations are context-local.
- Bound the cache by entry count and/or memory. Eviction must be LRU or epoch
  based and must not require object callbacks to stay correct.
- Use generations for correctness and eviction hints for memory only. A missing
  invalidation callback must degrade to a miss, not stale reuse.
- Keep the Slice 1 key profiler separate from the behavior-changing cache so
  instrumentation can remain enabled during conformance gates.

Expected movement:

- `framegraph_encode` drops first;
- `state_resolve` should drop sharply on recurring churn patterns;
- `encoder_setup` drops only where the plan avoids repeated per-draw encoder
  decisions or allows more redundant state calls to be suppressed.

Review decision: key by VAO identity first for safety, then add optional
layout-content keys after a dedicated equivalence gate. The ADV-3 lesson is
that stable-layout caching is real, but layout-content equivalence needs
instrumentation and proof.

### Lever A Implementation Boundary

The first behavior-changing Lever A slice should cache only validation-free,
pure structural payload:

- pipeline key selection and shader function identity;
- vertex descriptor and attribute layout binding recipe;
- reflected resource binding layout, including shader slots and binding point
  indices;
- fixed-function state encoding decisions that depend only on the structural
  fingerprint;
- submission read/write shape without concrete object names.

Do not include:

- command buffer, render encoder, drawable, or ring-buffer allocation state;
- current Metal resource pointers;
- current uniform bytes;
- current producer-token bits;
- CPU shadow data pointers;
- transform-feedback, query, rasterizer-discard, image/SSBO side-effect replay.

The expected first implementation shape is:

1. Keep the existing direct path as the reference builder.
2. Add a plan lookup after `TranslatedDrawInfo` has been populated enough to
   compute the structural key.
3. On miss, build the plan from the direct-path metadata and then execute the
   direct path.
4. On hit, populate a fresh per-draw packet from live GL objects, run normal
   hazard classification/drain, and encode using the cached recipe.
5. Keep a kill switch that forces misses and a trace flag that dumps key,
   generation, hit/miss, and reject reason.

This slice should not introduce argument buffers, parallel preparation, or
hardware batching. Those are follow-on levers that consume the explicit plan.

## Lever B: Encoder Binding Plan + Argument Buffers

Second implementation candidate, after Lever A gives a safe structural plan.

The real-app path repeatedly binds per-stage textures, samplers, UBOs, SSBOs,
image bindings, atomics, and default uniform buffers. The code already has
argument-buffer plumbing behind `APPGL_ENABLE_ARGUMENT_BUFFERS`, but it is not
the default safe path.

Use the `TranslatedDrawPlan` to decide when a draw's resource shape is stable
enough to route through a persistent Metal binding layout:

- precompute per-stage argument encoder layouts from the structural plan;
- allocate/update small argument-buffer records for current dynamic resources;
- bind one or two argument buffers instead of many `set*` calls;
- keep direct binding as the fallback for unsupported stages or high-risk
  resource shapes.

Correctness guard:

- argument buffers may replace binding calls only when every shader-visible
  resource in the plan is represented;
- missing resource slots, sampler defaulting, texture view aliases, image
  bindings, SSBO size buffers, and default uniform blocks must have focused
  gates before default-on;
- CPU/GPU hazard tracking remains outside the argument buffer and must still
  decide whether a producer needs ordering or a CPU wait.

Expected movement:

- `encoder_setup` and `binding` buckets drop;
- Metal encoder call count per draw drops;
- Apple Silicon memory bandwidth is used for compact argument records instead
  of CPU-side Objective-C binding churn.

## Lever C: Parallel Draw Preparation

Third implementation candidate. It is useful only after the draw packet shape
is explicit.

Metal render encoders are not a general thread-parallel escape hatch for GL:
GL draw order is observable. The safe first target is CPU-side preparation,
not parallel command emission.

Safe shape:

1. On the GL thread, record an ordered draw packet containing the current GL
   state snapshot, object generations, dynamic resource handles, and side-effect
   flags.
2. In worker tasks, resolve structural plan lookups, uniform packing, resource
   binding records, and validation for packets that do not need immediate GL
   feedback.
3. On the owning GL/Metal encode thread, replay packets to the Metal encoder in
   original order.

Hard stops that keep preparation serial:

- CPU readbacks or queries that require immediate results;
- buffer/texture mapping with CPU-visible effects;
- transform feedback side effects;
- commands that mutate object storage used by already-recorded packets;
- any path without enough generation tracking to prove the packet snapshot is
  still valid.

Future-only shape:

- `MTLParallelRenderCommandEncoder`, multiple command buffers, or ICBs can be
  considered only for provably order-independent draw runs, such as no blend,
  no feedback writes, no image/SSBO writes, compatible depth semantics, and no
  order-dependent queries. General GL cannot assume that.

Expected movement:

- wall-clock frame time drops more than single-draw `framegraph_encode` if the
  workload has enough independent packets;
- per-draw profile buckets may not drop proportionally because work moves to
  worker threads. Reports must include total frame time and CPU utilization,
  not just bucket percentages.

## Lever D: Hardware Batching Routes

Fourth implementation candidate and the likely requirement for the high end of
the 5000-draw range.

When the structural plan detects a long run of compatible draws, AppGL can use
Metal hardware routing instead of issuing one fully-bound draw at a time:

- merge compatible draws into `glMultiDraw*`/MDI-style internal batches when
  GL input already provides independent draw records;
- use indirect argument buffers or ICBs for repeated static draw streams;
- keep per-draw fallback for dynamic state changes, feedback, queries, and
  order-dependent blending/depth cases.

This is not the first patch because it has the largest semantic surface. It is
the path that can plausibly move 5000 draws toward the 120 FPS stretch target.

## Instrumentation Needed

Before the behavior-changing lever lands:

- keep `APPGL_GL_DRAW_PROFILE=1` and `APPGL_DRAW_PROFILE=1` reports comparable
  to the d17e298 baseline;
- add plan-cache counters: lookup, hit, miss, invalidated-by-program,
  invalidated-by-VAO, invalidated-by-FBO, rejected-by-side-effect;
- add resource-route counters: direct binding vs argument-buffer binding,
  set-call counts, argument-buffer bytes updated;
- keep the existing `vaoLayoutCacheHit` field and add explicit plan-cache hit
  status so ADV-3 and Phase 2 are not conflated;
- report worker-thread preparation time separately if Lever C lands.

Do not claim a Phase-2 win from aggregate FPS alone. The component shift must
show which stall moved.

## Implementation Slices

1. Instrumentation-only patch: plan-key prototype and counters, no behavior
   change. Run real-app-pattern to size the hit surface under churn.
2. Structural draw-plan memoization for validation-free payloads only:
   pipeline key, shader slots, vertex layout plan, resource reflection plan.
   Existing direct binding path stays active.
3. Extend memoization to fixed-function encoder decisions and FBO attachment
   signatures. Keep per-draw dynamic resources and hazards live.
4. Argument-buffer route for the subset whose plan proves complete shader
   resource coverage. Default off until focused gates pass, then default-on for
   the proven subset.
5. Parallel draw preparation for snapshot-safe packets. Serial replay remains
   the GL-order-preserving path.
6. Hardware batching for compatible draw runs after real-app evidence shows the
   remaining high-draw-count gap.

Each slice should carry its own before/after profile, not wait for the whole
stack to land.

Slice 1 instrumentation flag:

- `APPGL_PHASE2_PLAN_PROFILE=1` enables candidate plan-key lookup accounting
  in the translated-draw wrapper after submission-group classification.
- `APPGL_PHASE2_PLAN_KEY_PROFILE=1` is accepted as an alias.
- The report prefix is `[APPGL_PHASE2_PLAN_PROFILE]` and emits total draws,
  lookups, hits, misses, rejects, unique key count, hit-rate percentage, and
  per-reject reason counts.
- The hook is measurement-only: every draw still executes the existing direct
  `frameGraph->encodeTranslatedDraw` path.

## Validation Gates

Performance axis:

- GLTest real-app-pattern re-measure against the d17e298 baseline at
  100/500/2000/5000/20000 draws.
- Required report: FPS, frame time, total per-draw cost, AppGL wrapper cost,
  `framegraph_encode`, `state_resolve`, `encoder_setup`, binding cost,
  plan-cache hit rate, and argument-buffer route rate if applicable.
- Report where 120 FPS holds after the lever. If it does not hold at 500 draws,
  the lever is not Phase-2 sufficient.
- For 5000 draws, report the remaining gap and whether it is runtime encode,
  app workload setup, GPU time, or order-dependent draw emission.

Conformance axis:

- SCOUT-W gate of record with P-to-F equals zero for the selected baseline.
- Focused churn cases:
  - VAO layout mutation and VAO rebind with identical layouts;
  - blend/depth/stencil/raster toggles across recurring state patterns;
  - texture/sampler rebinding and sampler parameter mutation;
  - UBO/SSBO/image binding mutation;
  - FBO attachment swaps, MRT, MSAA, layered targets;
  - transform feedback, queries, rasterizer discard, and image/SSBO writes;
  - CPU readback after GPU writes.
- Negative controls where the optimization must not apply:
  - order-dependent blending;
  - depth/stencil side-effect tests;
  - texture or buffer storage redefinition between packet record and replay;
  - resource aliases with pending writes.

## Review Checklist

- Does every cache key name the GL state and object generations that make the
  cached payload valid?
- Is every dynamic value intentionally excluded from the cached payload?
- Can a stale plan survive program relink, VAO mutation, FBO attachment change,
  texture sampler mutation, or buffer storage replacement?
- Does the slice preserve GL draw order and CPU-visible synchronization?
- Does the validation report show component movement, not just FPS movement?
- Is the claimed win resource-flexing Apple Silicon, or merely moving a few
  microseconds inside a serial path?

## Recommended First Patch

Land the instrumentation-only plan-key prototype first. It should compute the
candidate key and record hit/miss/reject counts, but still execute the existing
path. That answers the load-bearing question before behavior changes:

> Under real-app churn, is the state stream structurally repetitive enough for
> draw-plan memoization to pay?

If yes, implement Lever A. If no, go directly to Lever B/D hardware routing,
because the workload is genuinely too unique for memoization to unlock the
120 FPS floor.
