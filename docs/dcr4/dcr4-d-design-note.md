# DCR4-D Design Note

Status: design only. Do not implement until Foreman and Clerk co-review this note and Foreman sends an implementation go.

Scope: F3 hardware tessellation grouping for the existing hardware-tess routes only. DCR4-D must not widen tess routing, flip CPU-domain defaults, crown local results, or change shader_ballot policy. `shader_ballot` remains honest Hard-NS unless a separate design proves support.

## Rung Boundary

DCR4-D groups the current hardware tessellation submission chain:

- optional VS-as-compute prepass
- TCS compute
- optional factor clamp
- optional domain generation
- optional TES-as-compute
- optional render `drawPatches`
- optional CPU TF write/replay after TES-compute output readback

The default ordering decision is to keep the existing `commitAndWait` behavior on every cross-command-buffer edge. Wait removal is deferred to S23 perf work. This follows the DCR4-C precedent: declare the actual current dependency, prove it with sentinels, and do not claim an async scheduler that does not exist.

CPU-domain default behavior stays unchanged. DCR4-D may declare and harden hardware-tess paths already reached by current gates, but it must not turn a CPU fallback into a new default route without a separate perf gate and SCOUT-W gate-of-record.

## Proposed Group Shape

Add submission kinds only when implementation begins:

- `TessDrawGroup`: parent for one `tryMetalTessellationDraw` encode attempt that succeeds.
- `TessVertexGroup`: emitted only when `vertexComputePipelineState != nullptr`.
- `TessControlGroup`: emitted for the TCS compute command buffer.
- `TessFactorClampGroup`: emitted only when the HW-domain capture path builds and dispatches the clamp PSO.
- `TessDomainGroup`: emitted only when domain generation runs for the TES-compute/TF path.
- `TessEvalGroup`: emitted only when TES-as-compute dispatches.
- `TessRenderGroup`: emitted only when the conventional render path encodes `drawPatches`.
- `FallbackNsGroup`: reused only if DCR4-D introduces an honest unsupported/no-approx fallback boundary for hardware-tess attempts.

`TessDrawGroup.approximateFallbackDisallowed` should be true. The group should be declared from `GLContext` before encode, then supplemented in `MetalFrameGraph` with exact transient sizes after allocation. The implementation must obey the four declaration rules:

- no silent `None` for an emitted subgroup
- no subgroup or transient declaration for a path that did not execute
- declaration ordering must match the actual command reason and command buffer
- every declared resource write must either be marked through the producer funnel or explicitly excluded as not GL-visible

The current `AppGLSubmissionGroup::kMaxSubgroups == 8` is enough for the six tess subgroups and optional fallback because the parent group kind is stored separately, but the implementation should assert this assumption in review.

## Internal Transients

All ten items below are internal and must not be represented as GL resource producer keys. Add tess-specific transient kinds instead of overloading `MeshVsOutputBuffer`.

| Transient | Current object label | Producer | Consumers | DCR4-D ordering decision |
| --- | --- | --- | --- | --- |
| `factorBuf` | `appgl-tess-factor` | TCS compute, synth host populate, or factor clamp | domain generation, Metal tessellator/render | Keep `CpuCompletionWait` from TCS to host populate/domain/render; keep `CpuCompletionWait` from clamp to domain capture when clamp runs. |
| `factorBufFull` | `appgl-tess-factor-full` | TCS compute or synth host populate | TES compute and TES render | Keep `CpuCompletionWait` from TCS/host populate to TES consumers. |
| `indirectBuf` | `appgl-tess-indirect-params` | CPU initialization before encode | TCS compute and TES compute | Declare `CpuBeforeEncodeSameCommandBuffer` for CPU initialization, plus retain lifetime through all tess waits. |
| `vsOutBuf` | `appgl-tess-vs-out` | VS-as-compute, or CPU zero seed for `forcePhase3Buffers` | TCS compute; TES compute for synthesized TCS | Keep `CpuCompletionWait` from VS compute to TCS/TES consumers. For forced zero seed, declare CPU-before-encode initialization rather than a GPU producer. |
| `cpOutBuf` | `appgl-tess-cp-out` | TCS compute | TES compute and TES render | Keep `CpuCompletionWait` from TCS to TES/render consumers. |
| `patchOutBuf` | `appgl-tess-patch-out` | TCS compute | TES compute and TES render | Keep `CpuCompletionWait` from TCS to TES/render consumers. |
| `domainCoordBuf` | `appgl-tess-domain-coord` | domain generator or HW-domain capture | TES compute and diagnostics | Keep `CpuCompletionWait` from domain generation to TES compute. |
| `domainPrimIDBuf` | `appgl-tess-domain-primid` | domain generator or HW-domain capture | TES compute and diagnostics | Keep `CpuCompletionWait` from domain generation to TES compute. |
| `totalVertCountBuf` | `appgl-tess-total-count` | domain generator or HW-domain capture | CPU read for TES dispatch sizing, TF accounting, query accounting | Keep `CpuCompletionWait` before CPU read. This is the most important no-false-async edge. |
| `tesComputeOutBuf` | `appgl-tess-compute-out` | TES compute | CPU TF writer and point-mode replay | Keep `CpuCompletionWait` before CPU read. If returned to `GLContext`, retain exactly as the current `CFBridgingRetain` path does and declare the lifetime. |

The implementation should add transients at the allocation site where actual sizes are known. For paths where a buffer is not allocated, do not declare it.

## Resource Sets

Reads to declare:

- VAO vertex buffers used by VS-as-compute.
- TCS, VS-as-compute, TES-as-compute, TES-render, and FS default-uniform bytes.
- UBOs if DCR4-D wires them through hardware tess; otherwise exclude hardware tess for reflected UBO paths that are not actually bound.
- sampled textures for TCS, VS-as-compute, TES, and FS, including texture-buffer source buffers.
- read-only image textures only if image binding is plumbed; otherwise any reflected image should force CPU fallback/honest NS.
- loaded FBO color/depth/stencil attachments when render state loads prior contents.
- transform-feedback object state when TF capture or rasterizer discard is active.

Writes to declare:

- draw FBO color/depth/stencil attachments for `TessRenderGroup`.
- default framebuffer writes for framebuffer 0.
- transform-feedback buffers when `writeTessTFAndUpdateCounters` deposits TES output.
- query counters updated by tess TF/query paths.
- storage-image, SSBO, and atomic writes only if the hardware route truly binds and records those resources.

## Section 101 Producer-Coverage Audit

DCR4-D must enumerate every GL-visible producer the selected hardware-tess path can activate, then either mark it through the generic funnel or exclude that route before native encode.

Current audit and implementation requirements:

- FBO attachment writes are active on the tess render path. Current code only invalidates default framebuffer shadow or sets legacy texture flags (`wasFramebufferRenderedTo` / `wasViewportRenderedTo`) for user FBOs. DCR4-D must extend this to the generic producer funnel with `appendFramebufferAttachmentWrites` plus `markGpuResourceWrites`, covering color, depth, and stencil attachments.
- Storage-image writes are not currently wired for the hardware-tess path. `tryMetalTessellationDraw` resolves sampler bindings, not image bindings, and `MetalTessDrawInfo` has no image-write producer set. DCR4-D must either plumb image bindings and mark `kProducerStorageImageWrite`, or reject hardware tess whenever TCS/TES/FS image writes are reflected or detected. Do not patch only FBO writes.
- SSBO writes are not currently wired for hardware tess. `MetalTessDrawInfo` has no SSBO binding vectors and `encodeMetalTessellationDraw` has no SSBO buffer binding loop. DCR4-D should conservatively reject hardware tess for TCS/TES/FS storage buffers unless a full binding and `kProducerShaderStorageWrite` funnel path is implemented.
- Atomic counters are not currently wired for hardware tess. Treat storage-buffer-backed atomic paths and explicit atomic counter bindings as native-hardware exclusions unless a full binding and `kProducerAtomicCounterWrite` funnel path is implemented.
- Transform-feedback writes are active when TES-as-compute output is read on CPU and `writeTessTFAndUpdateCounters` writes bound TF buffers. Because the write is CPU-side through `writeBufferRange`, current coherence is immediate rather than pending-GPU. DCR4-D must make this explicit in the declaration: either mark touched TF buffers as `kProducerTransformFeedback` and add a drain/readback sentinel, or document and test why CPU-side TF writes are excluded from pending-producer state.
- Query writes are active for `GL_PRIMITIVES_GENERATED`, TF written, and overflow query objects. They are CPU-side query-state updates, not buffer/texture/renderbuffer producers. They should be declared as query side effects if a query resource kind is added; otherwise explicitly exclude them from producer-pending because there is no GL object storage to drain.
- Point-mode replay after TES compute routes through `encodeEmulatedGsDraw`; any FBO/image/SSBO/atomic producers from that replay must be covered by the translated-draw producer funnel, not by tess transient declarations.

Producer sentinels required before SCOUT-W:

- user-FBO tess draw sets FBO color producer bits and readback drains them.
- depth/stencil tess draw sets the depth/stencil producer bit if those attachments are written.
- storage-image, SSBO, and atomic cases either prove hardware rejection/fallback or prove producer bits for each newly wired class.
- TF tess capture writes a bound buffer, then a GL buffer read observes the bytes after the intended drain path. If `kProducerTransformFeedback` is used, assert the pending bit before readback and cleared bit after readback.
- query-focused tess case proves query counters update on the hardware-tess path and are not double-counted by fallback code.

## Dependency Sentinels

The transient sentinel set should prove dataflow, not only final pixel presence:

- VS-output dependency: change or zero `vsOutBuf` after VS compute and prove TCS/TES/render output changes for a program whose VS output is consumed.
- Factor dependency: change `factorBuf` or `factorBufFull` after TCS and prove generated vertex count or final coverage changes.
- Control-output dependency: change `cpOutBuf` or `patchOutBuf` after TCS and prove TES output changes.
- Domain dependency: change `domainCoordBuf` or `domainPrimIDBuf` after domain generation and prove TES-as-compute output or TF bytes change.
- TES-output dependency: change `tesComputeOutBuf` before CPU TF write/replay and prove TF/readback or point replay changes.

Each sentinel hook must be env-gated, test-only, and paired with a normal draw so it is non-vacuous.

## Gates

Local design and implementation gates:

- `git diff --check`
- build `AppGL` and `appgl_gauntlet_cli` for release and fp64-on variants
- tessellation full
- texture_gather tess residuals
- TF/rasterizer-discard focused tess cases
- producer-coverage sentinels above
- transient-dependency sentinels above
- perf gate before any default-route flip

Gate-of-record:

- SCOUT-W runs both variants and owns any crown decision.
- Do not credit single-run local NonPass->P gains without SCOUT-W multi-run isolate. The DCR4-C `texture_gather.gather-geometry-shader` result remains the Item-78 oscillator, not a banked F2 gain.

## Implementation Checklist After Approval

- Add tess group and transient enum names.
- Add `AppGLSubmissionGroup submissionGroup` to `MetalTessDrawInfo`.
- Add a `declareTessSubmissionGroup` helper in `GLContext` that gathers actual reads/writes from resolved tess resources and FBO state.
- Add encode-time transient declarations in `MetalFrameGraph::encodeMetalTessellationDraw` only at actual allocation/dispatch sites.
- Extend or explicitly exclude every producer in the Section 101 audit before landing any source changes.
- Add sentinels first enough to get red/green on at least FBO producer coverage and one cross-stage transient dependency.
