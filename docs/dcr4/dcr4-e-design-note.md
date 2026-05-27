# DCR4-E Design Note

Status: design only. Do not implement until Foreman and Clerk co-review this note and Foreman sends an implementation go.

Scope: F4 B4 exact CPU/TF grouping. B4 is locked to EMULATE for adjacency, geometry-shader streams, transform-feedback-active geometry draws, and stream replay. DCR4-E must not widen B4 into a native Metal path, must not re-open the emulate-vs-NS decision, and must not count approximate fallback as progress.

## Rung Boundary

DCR4-E represents the current exact B4 route as submission groups:

- CPU geometry/tess/VS expansion with no Metal command buffer.
- transform-feedback capture from the CPU-expanded output.
- optional raster replay through `encodeEmulatedGsDraw`.
- stream replay through the `glDrawTransformFeedback*` entry points.
- exact-only fallback/NS decisions when a B4 shape cannot be emulated exactly.

The default behavior is unchanged: adjacency, GS streams, active TF, and replay stay on CPU exact emulation where feasible. Honest NS is allowed only for a genuine spec, Metal, or emulation wall, never for effort. Performance work and wait removal are S23 scope.

## Proposed Group Shape

Add F4 groups only when implementation begins:

- `CpuGsExpansionGroup`: parent group for a B4 exact CPU-emulated draw. It represents CPU-only expansion even when no Metal command buffer is emitted. Set `approximateFallbackDisallowed = true` and carry an exact-only reason such as `B4ExactCpuEmulation`.
- `TransformFeedbackCaptureGroup`: emitted when the CPU-expanded output writes TF buffers, TF object stream counts, overflow flags, or TF/query counters.
- `StreamReplayGroup`: emitted by `glDrawTransformFeedback*` and `glDrawTransformFeedbackStream*` before replay dispatch consumes last-completed stream counts.
- `TranslatedDrawGroup`: reused as the raster subgroup when CPU-expanded vertices are replayed through Metal.
- `VsTfComputeReadbackGroup`: optional subgroup only for the existing env-gated VS-only TF compute helper. It keeps the current `VertexTransformFeedbackReadback` completion wait.
- `FallbackNsGroup`: emitted when an exact-only B4 route cannot continue and legacy approximate fallback is disallowed.

The group declaration rules from DCR4-C/D still apply:

- no silent `None` for an emitted subgroup.
- no subgroup or transient declaration for a path that did not execute.
- declaration ordering must match actual program order and command-buffer reason.
- every declared GL-visible write must either be marked through the producer funnel or explicitly excluded with non-vacuous proof.

The exact-only guard is part of the group metadata, not only a local branch comment. If CPU expansion, TF capture, or raster replay fails after a B4 exact route was selected, the group must end in exact CPU success or `FallbackNsGroup`; it must not fall through to stripped VS+FS, solid fallback, partial raster, or native mesh approximation.

## Resource Sets

Reads to declare for `CpuGsExpansionGroup`:

- source VAO vertex buffers and enabled attribute state.
- element/index buffers, base-vertex, instance, and primitive-restart state for indexed families.
- CPU shadow bytes for buffers read by the emulators.
- UBO/default-uniform state and program reflection used by VS, TCS/TES, GS, and FS emulation.
- sampled textures and texture-buffer source buffers read by the CPU interpreters.
- storage images read by the CPU interpreters.
- active transform-feedback object state and indexed TF buffer bindings when capture is active.
- draw FBO attachments loaded by depth/stencil/blend/raster state when raster replay is active.

Writes to declare:

- TF buffer writes for each bound `GL_TRANSFORM_FEEDBACK_BUFFER` touched by the TF writer.
- TF object stream counts, `lastCompletedVertexCount`, primitive counts, and overflow state.
- query counters for `GL_PRIMITIVES_GENERATED`, `GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN`, `GL_GEOMETRY_SHADER_INVOCATIONS`, `GL_GEOMETRY_SHADER_PRIMITIVES_EMITTED`, and TF overflow targets.
- GS/tess CPU interpreter image writes flushed through `pendingImageWrites`.
- raster FBO color/depth/stencil writes emitted by `encodeEmulatedGsDraw`.
- FS storage-image, SSBO, and atomic writes emitted by the translated raster subgroup.

Reads to declare for `StreamReplayGroup`:

- transform-feedback object state and the selected `lastCompletedVertexCount[stream]`.
- replay mode, instance count, and stream index.
- downstream draw resources consumed by the delegated `drawArrays*` route.

## Section 101 F4 Producer-Coverage Audit

DCR4-E must audit F4 producers fresh. DCR4-D's tess TF exclusion does not transfer: F4 TF is the active CPU-GS/TF emulation route and is the canonical B4 output path for several CTS surfaces.

Required classification:

- TF buffer writes: mark touched GL buffer objects with `kProducerTransformFeedback` through `markGpuResourceWrites` after `writeBufferRange` writes the captured bytes. This is producer metadata for replay/lifecycle/readback audit even though the current bytes are CPU-written and immediately copied into GL-owned storage. The sentinel must prove both the byte source and the pending-bit mark/drain.
- TF object stream counts and `lastCompletedVertexCount`: declare as `TransformFeedbackCaptureGroup` CPU-side object state. There is no buffer/texture/renderbuffer pending bit for these counters; exclude them from `producerPending` only with query/replay sentinels proving the counters drive GL-visible behavior.
- Query writes: declare as CPU-side query-object state. There is no GL storage object to drain. Exclude from `producerPending` with non-vacuous query sentinels that fail if query updates are skipped or double-counted.
- CPU interpreter image writes: mark affected texture objects with `kProducerStorageImageWrite` unless implementation proves the write is CPU-immediate and all consumers read the updated texture without a pending GPU drain. Any exclusion needs a red/green sentinel, because these are GL-visible texture writes.
- Raster FBO writes from `encodeEmulatedGsDraw`: reuse translated-draw FBO producer marking for color, depth, and stencil attachments.
- FS storage-image/SSBO/atomic writes from the raster replay: reuse translated-draw image, SSBO, and atomic producer marking. Do not assume CPU-GS grouping covers the FS raster subgroup.
- Default framebuffer writes: keep default-framebuffer shadow invalidation; no GL object producer bit exists for framebuffer 0.
- Optional VS-only TF compute helper: GPU output is internal until copied into TF buffers. Keep `VertexTransformFeedbackReadback` wait. The GL-visible producer is the subsequent TF buffer write, classified as above.

Producer sentinels required before SCOUT-W:

- TF buffer capture marks `kProducerTransformFeedback`, readback drains it, and the bytes match the CPU-expanded output.
- A red-stub that disables the TF producer mark must fail the pending-bit assertion while normal data capture still proves the sentinel is checking the mark, not only bytes.
- A red-stub that skips the CPU TF buffer write must leave the buffer zero, proving F4 TF bytes come from the TF writer.
- Stream replay after capture must consume `lastCompletedVertexCount[stream]`; disabling the count update must make replay fail or draw zero.
- Query sentinels must cover primitives generated, TF primitives written, and overflow/stream overflow where bindings truncate output.
- CPU interpreter image-write sentinel must either prove producer marking or prove an explicit no-pending exclusion with a red stub.
- Raster replay producer sentinels must cover FBO color and depth/stencil attachment writes when rasterizer discard is off.
- FS side-effect sentinels must cover image, SSBO, and atomic writes when those side effects are activated by the raster replay path.

## Internal Transients And Ordering

F4 has mostly CPU temporaries rather than Metal transients:

| Transient/state | Producer | Consumers | DCR4-E ordering decision |
| --- | --- | --- | --- |
| `appgl::EmulatedDraw` expanded vertices | CPU GS/tess/VS emulator | TF writer and raster replay | Program-order CPU dependency; represent as `CpuGsExpansionGroup` temporary retained until capture/raster completes. |
| `pendingImageWrites` | CPU interpreter | texture flush / later GL texture consumers | CPU program order; mark or explicitly exclude GL texture producers after flush. |
| TF write cursors/truncation state | `writeGsXfbAndCheckDiscard` | TF buffer writes, query/counter updates | CPU local state, no Metal wait. |
| `capturedVertexCount[]` | TF capture | `EndTransformFeedback`, stream replay | CPU object state. Declare under `TransformFeedbackCaptureGroup`; prove with replay sentinels. |
| `lastCompletedVertexCount[]` | `EndTransformFeedback` | `glDrawTransformFeedback*` | CPU object state. Declare as `StreamReplayGroup` read; no GPU wait. |
| `appgl-vstf-out` | optional VS-only TF compute helper | CPU copy into TF writer | Keep current `VertexTransformFeedbackReadback` `CpuCompletionWait`; async removal is S23 only. |
| expanded raster upload | `encodeEmulatedGsDraw` translated draw setup | Metal raster replay | Inherits translated-draw upload/lease rules and producer funnel. |

No DCR4-E implementation should remove existing `CommitAndWait` or `CpuCompletionWait` behavior. If any F4 path becomes GPU-produced later, its GPU-to-CPU or GPU-to-GPU edge needs a new explicit ordering proof; same-queue command-buffer order alone is not enough.

## Exact-Only Guard

B4 exact-only means:

- native mesh-GS stays excluded for adjacency, GS streams, and active TF.
- CPU GS/TF emulation is the only credit path for B4.
- encode failure, emulator failure, unresolved stream/TF shape, unsupported resource state, or PSO failure cannot fall through to legacy approximate rendering.
- `FallbackNsGroup` is the required terminal classification when exact emulation cannot proceed.

Implementation should classify exact-only B4 at the draw-family entry points using actual stage shape:

- adjacency input topology.
- GS stream usage (`OpEmitStreamVertex`, `OpEndStreamPrimitive`, `DecorationStream`) or reflected stream metadata.
- transform-feedback active with GS/tess/VS emulation route.
- stream replay entry points.
- any prior route that selected CPU-GS expansion for exact B4 behavior.

No-slip sentinels:

- force CPU-GS raster encode failure after successful B4 expansion and prove the draw is consumed or honestly unsupported, not rendered through stripped VS+FS.
- force TF capture failure after expansion and prove fallback does not emit approximate raster/TF output.
- force stream replay count read to zero and prove replay output disappears, then restore normal replay and prove output returns.

## Gates

Local design and implementation gates:

- `git diff --check`.
- build `AppGL` and `appgl_gauntlet_cli` for release and fp64-on variants.
- `KHR-GL46.geometry_shader.*` full, with adjacency and stream subsets summarized.
- `KHR-GL46.transform_feedback.*` full.
- stream replay probes: `draw_xfb_stream_test`, `draw_xfb_stream_instanced_test`, `draw_xfb_test`, `draw_xfb_instanced_test`, and `transform_feedback3.multiple_streams` when present.
- query/counter readback probes for primitives generated, TF primitives written, GS invocations, GS primitives emitted, overflow, and stream overflow.
- Section 101 F4 producer-coverage sentinels listed above.
- exact-only guard/no-slip sentinels.
- P->F and P->NonPass enumeration versus the accepted DCR4-D/SCOUT-W baseline for both variants.

Gate-of-record:

- SCOUT-W runs both variants and owns any crown decision.
- Do not bank single-run local gains. B4 is EMULATE-locked; any NonPass->P requires SCOUT-W multi-run confirmation and Foreman/Clerk acceptance.

## Implementation Checklist After Approval

- Add F4 group enum names and exact-only metadata if the existing `approximateFallbackDisallowed` flag is insufficient for diagnostics.
- Add a declaration helper for CPU-GS/TF groups that records reads, writes, and exact-only guard state before any B4 work can fall through.
- Add `TransformFeedbackCaptureGroup` resource marking for touched TF buffers with `kProducerTransformFeedback`.
- Add explicit CPU-side exclusions for TF object counters and query objects, backed by red/green sentinels.
- Add producer handling for CPU interpreter image writes or prove a no-pending exclusion.
- Ensure `encodeEmulatedGsDraw` raster replay continues through translated-draw producer marking for FBO/image/SSBO/atomic writes.
- Add exact-only no-slip guards in every draw family touched by CPU-GS/TF routes.
- Add sentinels before relying on CTS pass deltas.

## Non-Goals

- No native Metal implementation for B4 adjacency, streams, active TF, or replay.
- No approximate fallback.
- No default-policy flip.
- No wait removal or async TF/raster scheduling.
- No claim that F3 tess TF producer classification applies to F4.
- No local crown.
