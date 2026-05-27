# DCR4-A Submission Inventory and Taxonomy

Status: behavior-neutral inventory for Foreman review.

This document maps the FANTASTIC F1-F4 submission surfaces to proposed
submission-group kinds, command-buffer reasons, resource read/write sets,
fallback boundaries, and transient ownership. It is a design/inventory rung
only. It does not authorize runtime behavior changes.

## Ordering Rule

Do not treat same-queue command-buffer order as sufficient proof for a GPU
write in one command buffer to be visible to a GPU read in a later command
buffer. Metal command buffers on one queue can pipeline. Every internal
write-to-read dependency that crosses an encoder or command-buffer boundary
must be backed by one of these mechanisms before DCR4-C/D/E can remove an
existing wait:

- same-command-buffer cross-encoder synchronization that is legal for the
  resource and encoder pair.
- Metal hazard tracking that is known to cover the transient resource and its
  usage.
- an explicit `MTLFence` or equivalent encoder-visible fence path.

Current F2/F3 code often uses `commitAndWait`. This is a real completion
mechanism and explains why the current code is ordered. It is not the target
proof for async grouping unless the rung intentionally keeps the wait.

## Group Taxonomy

Proposed group kinds for the DCR-4 implementation rungs:

- `ArgumentBindingGroup`: argument-buffer and sidecar materialization for the
  draw/dispatch that consumes the bindings.
- `TranslatedDrawGroup`: current translated graphics draw work, including
  FBO producer marking.
- `ComputeDispatchGroup`: compute dispatch work and compute resource
  producer marking.
- `MeshGsDrawGroup`: logical F2 hardware mesh-GS draw parent.
- `MeshGsPrepassGroup`: F2 VS-as-compute/remap subgroup.
- `MeshGsRenderGroup`: F2 mesh render subgroup.
- `TessDrawGroup`: logical F3 hardware tessellation draw parent.
- `TessVertexGroup`, `TessControlGroup`, `TessFactorGroup`,
  `TessDomainGroup`, `TessEvalGroup`, `TessRenderGroup`: ordered F3
  subgroups.
- `CpuGsExpansionGroup`: CPU GS/tess expansion and VS-only TF expansion.
- `TransformFeedbackCaptureGroup`: TF buffer/counter/query updates.
- `StreamReplayGroup`: `glDrawTransformFeedback*` replay source selection.
- `FallbackNsGroup`: exact CPU fallback or honest-NS decision record when
  native work cannot be emitted exactly.

Each group records a parent operation, ordered subgroups, command-buffer
reasons, GL-visible reads and writes, internal transients, fallback/NS policy,
and whether approximate legacy fallback is disallowed.

## F1: Argument Buffer ABI and Foundation

### Submission Sites

- Graphics translated draw entry points eventually build `TranslatedDrawInfo`
  and call `MetalFrameGraph::encodeTranslatedDraw`. Important source sites are
  `GLContext::drawArrays`, `drawArraysInstanced`, `drawElements`,
  `drawElementsBaseVertex`, and `drawElementsInstancedBaseVertex`.
- Resource resolution is split through `resolveSamplerBindings`,
  `resolveUBOBindings`, `resolveSSBOBindings`, `resolveImageBindings`, and
  draw-time FBO helpers.
- `encodeTranslatedDrawAndMarkFbo` marks FBO, image, SSBO, and atomic writes
  after successful emission.
- Compute entry points are `GLContext::dispatchCompute` and
  `dispatchComputeIndirect`, which build `ComputeDispatchInfo` and call
  `MetalFrameGraph::encodeComputeDispatch`.
- `MetalFrameGraph::encodeTranslatedDraw` creates graphics argument encoders
  for set 0 at buffer index 24 and set 1 at buffer index 25 when argument
  buffers are enabled and reflected function inputs require them.
- `MetalFrameGraph::encodeComputeDispatch` creates compute argument encoders
  for set 0 and set 1 on the same ABI.

### Proposed Groups

- `TranslatedDrawGroup`
  - child `ArgumentBindingGroup` when graphics argbuf materialization is used.
  - command-buffer reason: `TranslatedDraw` for allocation/reuse of the
    current graphics command buffer.
- `ComputeDispatchGroup`
  - child `ArgumentBindingGroup` when compute argbuf materialization is used.
  - command-buffer reason: `ComputeDispatch`, currently `CommitAndWait`.

### Resource Sets

Graphics read set:

- vertex array buffers and optional element/index buffer.
- UBO buffers and default-uniform data.
- sampled textures and texture-buffer source buffers.
- readable SSBO, atomic-counter, and storage-image bindings.
- framebuffer attachments that are loaded or depth/stencil tested.
- sidecar resources such as fp64 transport buffers or sparse/MSAA sidecars
  when those are bound as shader-visible inputs.

Graphics write set:

- draw FBO color attachments as `kProducerFboColorWrite`.
- draw FBO depth/stencil attachments as `kProducerFboDepthStencilWrite`.
- writable SSBOs as `kProducerShaderStorageWrite`.
- writable storage images as `kProducerStorageImageWrite`.
- atomic-counter buffers as `kProducerAtomicCounterWrite`.
- sidecar writeback resources when fp64 or sparse/image emulation writes need
  a GL-visible owner.

Compute read set:

- UBO/default-uniform data, sampled textures, texture-buffer source buffers.
- SSBO/atomic/storage-image bindings whose shader access includes reads.
- indirect dispatch buffer for `dispatchComputeIndirect`.
- sidecar sample-count and fp64/sparse resources used by the compute path.

Compute write set:

- SSBO writes as `kProducerComputeWrite` plus
  `kProducerShaderStorageWrite`.
- storage-image writes as `kProducerComputeWrite` plus
  `kProducerStorageImageWrite`.
- atomic-counter writes as `kProducerComputeWrite` plus
  `kProducerAtomicCounterWrite`.
- any GL-visible sidecar destination that backs a bound resource.

### Internal Transients and Ownership

- Argument-buffer payloads for set 0 and set 1 are ring/suballocation backed.
  The producing group must retain the backing Metal buffer and offset range
  until the consuming command buffer completes.
- Per-draw/per-dispatch uniform bytes and SSBO size sidecar buffers are
  transient payloads consumed by the same draw/dispatch command buffer.
- fp64 transport sidecars may require a CPU-visible sync/readback point. Those
  keep their current explicit `Fp64Sidecar` or readback classification; DCR4-B
  must not turn them into hidden waits inside `ArgumentBindingGroup`.
- Sparse/MSAA/storage-image sidecars remain GL-resource-owned for producer
  funnel purposes even when an internal texture or buffer is what the shader
  actually sees.

Ordering mechanism to verify at DCR4-B:

- Argument-buffer payload writes are CPU-side before command-buffer encode and
  then consumed by the same command buffer, so visibility is same-CB binding
  plus lease lifetime.
- If an argbuf path creates a Metal-side GPU copy/upload before the draw or
  dispatch, that upload must be represented as a producer subgroup with an
  explicit ordering mechanism; same-queue commit order alone is not a proof.

### Fallback and NS Boundary

- Argbuf disabled, unavailable, or not needed falls back to direct binding
  within the same parent draw/dispatch group.
- Graphics fallback remains the owning draw path's fallback policy. F1 argbuf
  failure is not allowed to silently change a promoted F2/F3/F4 exactness
  decision.
- Compute dispatch has no approximate fallback. Invalid program, unsupported
  resource shape, or failed dispatch emission follows existing GL error/return
  behavior.

## F2: Mesh-GS DrawArrays Promotion

### Submission Sites

- `GLContext::drawArrays` resolves the pipeline emulation program and, when
  the program tier is `MeshShader` and transform feedback is inactive, calls
  `tryMetalMeshGSDraw`.
- `tryMetalMeshGSDraw` builds `MetalMeshGSDrawInfo`, resolves the FBO color
  and depth/stencil targets, snapshots draw state, resolves sampler/image
  bindings, and calls `MetalFrameGraph::encodeMetalMeshGSDraw`.
- `MetalFrameGraph::encodeMetalMeshGSDraw` drains any open standalone-conflict
  command buffer, allocates the VS-output transient, runs a VS-as-compute
  command buffer, then runs a mesh render command buffer.
- F2's current native site is the non-indexed `drawArrays` route. Indexed
  `drawElements*` paths route through CPU tess/GS emulation or the translated
  path, not native mesh promotion.

### Proposed Groups

- Parent: `MeshGsDrawGroup`.
- Subgroups:
  - `MeshGsPrepassGroup` for VS-as-compute output.
  - `MeshGsRenderGroup` for the mesh render pass.
  - `FallbackNsGroup` for exact CPU GS or honest-NS decision.
- Command-buffer reasons:
  - `DrainCurrentStandalone` when current work must be committed before the
    standalone mesh path owns command buffers.
  - `MeshVertexCompute` for VS-as-compute.
  - `MeshDraw` for the mesh render command buffer.

### Resource Sets

Read set:

- vertex attribute buffers referenced by the current VAO.
- default-uniform bytes for VS, GS/mesh, and FS.
- sampled textures and read-only image texture inputs resolved for mesh and
  fragment stages.
- FBO depth/stencil attachments when depth/stencil tests load existing data.
- GL raster state snapshots that control render output.

Write set:

- color FBO attachment or default framebuffer color target.
- depth/stencil FBO attachment when depth/stencil writes are enabled.
- default framebuffer shadow invalidation when drawing to framebuffer 0.
- DCR4-C must verify successful native mesh FBO draws mark the bound draw FBO
  through the generic producer funnel, not only invalidate framebuffer 0.
- no transform-feedback writes in the native mesh path; TF-active draws are
  excluded and belong to F4 CPU/TF grouping.

### Internal Transients and Ownership

- `vsOutBuf` (`appgl-mesh-gs-vs-output`): private Metal buffer written by
  `MeshGsPrepassGroup` and read by `MeshGsRenderGroup` as mesh buffer index
  22.
- Mesh render PSO/function cache entries owned by the program, referenced by
  the group.
- Per-stage uniform scratch vectors are CPU-side until encoded with
  `setBytes`.
- Any argument-buffer/ring payloads used by the fragment or mesh stages are
  inherited from F1 `ArgumentBindingGroup` rules.

Current ownership:

- `vsOutBuf` is retained by a local scoped owner until after
  `MeshDraw` `commitAndWait` returns. This is enough only because the current
  render subgroup waits before the function exits.

Ordering mechanism to verify at DCR4-C:

- Current ordering is CPU-visible completion:
  `MeshVertexCompute` `commitAndWait` finishes before `MeshDraw` is encoded.
- If DCR4-C keeps the two command buffers async, it must prove one of:
  same-command-buffer legal cross-encoder ordering, hazard tracking for the
  private buffer, or an explicit `MTLFence`. Same-queue order is not enough.
- Add a sentinel that corrupts or varies the prepass output in a way the mesh
  render must consume, so prepass-to-render visibility is tested directly.

### Fallback and NS Boundary

- Native mesh is only for shapes proven exact by the F2 matrix. Current source
  additionally gates the visible native call site to `GL_POINTS` and
  non-transform-feedback `drawArrays`.
- Transform-feedback-active draws route to F4 CPU capture.
- Indexed draws, primitive restart, adjacency, unsupported streams, unsupported
  resource side effects, unsupported layered/MRT/blend shapes, or PSO/encoder
  failure route to exact CPU GS when available or honest NS.
- F2 must never fall through to stripped VS+FS rendering for an exact GS case.

## F3: Hardware Tessellation Entry

### Submission Sites

- `GLContext::tryMetalTessellationDraw` is the hardware tessellation entry.
  It validates patch mode, program tiers, transform-feedback/discard
  eligibility, uniform and fp64 guards, FBO targets, and per-stage resources.
- `MetalFrameGraph::encodeMetalTessellationDraw` emits the ordered hardware
  tessellation stages and returns optional TES compute output for TF/readback
  handling.
- CPU-domain tessellation remains the default/fallback path outside the
  authorized hardware gate.

### Proposed Groups

- Parent: `TessDrawGroup`.
- Subgroups:
  - `TessVertexGroup` for VS-as-compute.
  - `TessControlGroup` for TCS/tess-factor generation.
  - `TessFactorGroup` for factor clamp when needed.
  - `TessDomainGroup` for domain coordinate generation.
  - `TessEvalGroup` for TES-as-compute.
  - `TessRenderGroup` for hardware tessellation render.
  - `TransformFeedbackCaptureGroup` when TES compute output is consumed by
    CPU TF writing.
  - `FallbackNsGroup` for CPU-domain exact or honest-NS decision.
- Command-buffer reasons:
  - `TessDrainCurrent`
  - `TessVertexCompute`
  - `TessControlCompute`
  - `TessFactorClamp`
  - `TessDomainGenerate`
  - `TessEvalCompute`
  - `TessRender`
  - `TessProbe` for probe-only support checks outside the draw group.

### Resource Sets

Read set:

- vertex attribute buffers and any element/index data used by CPU-domain
  fallback.
- TCS/TES/VS/FS uniform data, UBOs, sampled textures, texture-buffer source
  buffers, and readable image inputs.
- patch parameters, primitive mode, and tessellation levels.
- FBO attachments loaded by render/depth/stencil state.
- transform-feedback object state when TF capture or rasterizer discard is
  active.

Write set:

- draw FBO color/depth/stencil attachments for `TessRenderGroup`.
- TF buffers, captured counts, and query state when TES output is captured.
- CPU-domain fallback writes to storage images or shader side-effect resources
  when the interpreter path handles them.
- Hardware tessellation should not claim support for writable SSBO/image/atomic
  side effects unless the selected hardware route actually binds and records
  those writes.

### Internal Transients and Ownership

All of the following are internal/non-GL resources and must be represented as
subgroup-owned transients, not as GL-resource producer keys:

- `factorBuf` (`appgl-tess-factor`): tess factor buffer. Written by
  `TessControlGroup`, optional CPU synthesized-TCS path, or clamp path; read
  by domain generation and render/tessellator consumers.
- `factorBufFull` (`appgl-tess-factor-full`): shared full factor copy. Written
  by TCS or CPU synthesis; read by TES compute/render diagnostics and fallback
  logic.
- `indirectBuf` (`appgl-tess-indirect-params`): shared dispatch/draw
  parameter buffer. CPU initialized, read by GPU stages.
- `vsOutBuf` (`appgl-tess-vs-out`): VS-as-compute output. Written by
  `TessVertexGroup`; read by `TessControlGroup` or later synthesized paths.
- `cpOutBuf` (`appgl-tess-cp-out`): control-point output. Written by
  `TessControlGroup`; read by TES compute and render.
- `patchOutBuf` (`appgl-tess-patch-out`): per-patch output. Written by
  `TessControlGroup`; read by TES compute and render.
- `domainCoordBuf` (`appgl-tess-domain-coord`): generated domain
  coordinates. Written by `TessDomainGroup`; read by `TessEvalGroup` and
  optional diagnostics.
- `domainPrimIDBuf` (`appgl-tess-domain-primid`): generated primitive IDs.
  Written by `TessDomainGroup`; read by `TessEvalGroup`.
- `totalVertCountBuf` (`appgl-tess-total-count`): total generated vertex
  count. Written by domain generation; read by CPU for dispatch sizing and TF
  accounting.
- `tesComputeOutBuf` (`appgl-tess-compute-out`): TES output stream. Written by
  `TessEvalGroup`; read by CPU TF writing or point-mode replay. It is returned
  retained to the caller when the caller must read it after
  `encodeMetalTessellationDraw`.

Current ownership:

- Most buffers are scoped Objective-C owners in
  `encodeMetalTessellationDraw`, which is safe because each current subgroup
  waits before later use and before function exit.
- `tesComputeOutBuf` is specially retained for the GLContext caller when CPU
  TF or replay needs to read it after the frame-graph function returns.

Ordering mechanism to verify at DCR4-D:

- Current ordering is explicit completion via `commitAndWait` after each
  emitted tess subgroup and before every CPU read.
- If DCR4-D groups these stages without waits, each transient edge must get a
  named proof:
  - `vsOutBuf`: VS compute -> TCS/read stage.
  - `factorBuf`: TCS/clamp/synthesis -> domain/render.
  - `factorBufFull`: TCS/synthesis -> TES compute/render.
  - `cpOutBuf`: TCS -> TES compute/render.
  - `patchOutBuf`: TCS -> TES compute/render.
  - `domainCoordBuf` and `domainPrimIDBuf`: domain generation -> TES compute.
  - `totalVertCountBuf`: domain generation -> CPU read.
  - `tesComputeOutBuf`: TES compute -> CPU read or replay.
- Add a sentinel that exercises prepass/control/domain/render dependency
  visibility, not just final pixel presence.

### Fallback and NS Boundary

- Hardware tess remains parked behind the existing gates unless a later rung
  explicitly authorizes a policy change.
- CPU-domain exact fallback owns cases where hardware tier, link/probe, TF,
  rasterizer discard, GS-after-tess, side effects, isolines/points, fp64, or
  resource requirements are not exact in the Metal route.
- Honest NS is allowed only for a genuine spec/Metal/emulation wall, not
  effort. Heavy but feasible exact handling stays in-tier for DCR4-D/E review.

## F4: B4 Adjacency, Streams, Transform Feedback, Replay

### Submission Sites

- CPU GS emulation sites live in `drawArrays`, `drawArraysInstanced`,
  `drawElements`, `drawElementsBaseVertex`, and
  `drawElementsInstancedBaseVertex`.
- VS-only transform-feedback emulation sites live in the same draw families
  when TF is active, the program has TF varyings, and there is no GS/tess
  emulation route.
- An env-gated VS-only TF GPU path exists behind
  `APPGL_ENABLE_METAL_TF_VS_DISPATCH=1`. The drawArrays VS-only TF gate can
  call `MetalFrameGraph::encodeVsTfComputeDraw`, then copy the shared output
  bytes into TF buffers through `writeVsTfFromComputeOutput`. Encoder failure
  falls back to the CPU helper.
- `writeGsXfbAndCheckDiscard` writes TF buffers, captured counts, overflow
  state, and query state, and returns true when rasterizer discard consumes
  the draw before raster encoding.
- `encodeEmulatedGsDraw` turns CPU-expanded geometry into a translated draw
  when rasterization remains active.
- `drawTransformFeedback`, `drawTransformFeedbackStream`,
  `drawTransformFeedbackInstanced`, and
  `drawTransformFeedbackStreamInstanced` read last-completed per-stream counts
  and route replay through `drawArrays` or `drawArraysInstanced`.

### Proposed Groups

- `CpuGsExpansionGroup`
  - no command buffer for CPU-only expansion.
  - captures source VAO/index/shader-resource reads and CPU temporaries.
- `TransformFeedbackCaptureGroup`
  - no command buffer for current CPU writer.
  - records TF buffer/counter/query writes.
- `VsTfComputeReadbackGroup`
  - optional env-gated subgroup for the current VS-only TF GPU helper.
  - command-buffer reason: `VertexTransformFeedbackReadback`, currently
    `CommitAndWait`.
- `TranslatedDrawGroup`
  - child raster subgroup when `encodeEmulatedGsDraw` emits expanded geometry.
  - command-buffer reason: `TranslatedDraw`.
- `StreamReplayGroup`
  - reads last-completed TF stream counts and dispatches to normal draw groups.
- `FallbackNsGroup`
  - records exact CPU or honest-NS outcome and whether legacy fallback is
    disallowed.

### Resource Sets

Read set:

- source vertex buffers, VAO state, and element/index data.
- CPU shadow bytes for buffers used by the CPU interpreters.
- sampled textures and storage images used by VS/GS/TCS/TES CPU emulation.
- UBO/default-uniform state and shader reflection data.
- active transform-feedback object state and last-completed stream counts for
  replay.
- FBO/depth/stencil attachments when raster output is encoded after expansion.

Write set:

- transform-feedback buffers via `writeBufferRange`.
- captured vertex counts and per-stream `lastCompletedVertexCount`.
- primitives generated/written, overflow, and query result state.
- pending image writes flushed out of CPU interpreters to GL texture objects.
- optional VS-only TF GPU helper output copied into TF buffers by CPU after the
  `VertexTransformFeedbackReadback` wait.
- raster FBO color/depth/stencil writes from the translated draw subgroup when
  rasterizer discard is not active.

### Internal Transients and Ownership

- `appgl::EmulatedDraw` vertex payloads, varying payloads, topology, and
  per-stream tags are CPU temporaries owned by the parent operation until TF
  capture and optional raster encoding consume them.
- Stream routing metadata and slot truncation state are CPU temporaries inside
  `writeGsXfbAndCheckDiscard`.
- `appgl-vstf-out`: shared Metal buffer written by the optional VS-as-compute
  TF helper, copied into CPU memory after `commitAndWait`, and then consumed
  by `writeVsTfFromComputeOutput`.
- Expanded raster vertex data is uploaded through the translated draw path and
  inherits F1/translated-draw ring and lease rules.
- TF write cursors and counters are GL object state, not Metal command-buffer
  transients.

Ordering mechanism to verify at DCR4-E:

- Current TF capture writes are CPU writes through `writeBufferRange`, so
  following CPU reads observe them without a GPU fence.
- The optional VS-only TF GPU helper currently orders GPU output to CPU copy by
  `VertexTransformFeedbackReadback` `commitAndWait`. If it becomes async, the
  shared output buffer requires an explicit GPU->CPU completion/readback
  mechanism.
- Raster replay after CPU expansion is ordered by program flow before
  `encodeEmulatedGsDraw` records the translated draw.
- If any F4 capture path becomes GPU-produced, TF buffers must enter the
  producer-pending funnel with an explicit GPU->CPU and GPU->GPU replay
  mechanism. Same-queue order is not enough.
- DCR4-E must classify whether CPU TF writes should set
  `kProducerTransformFeedback` metadata for lifecycle/replay audit even though
  they are not GPU producers today.

### Fallback and NS Boundary

- B4 covers adjacency, GS streams, TF-active geometry draws, VS-only TF, and
  transform-feedback replay.
- Exact CPU handling is required where feasible. Approximate legacy translated
  fallback is forbidden for exact-only B4 shapes.
- The DCR4-E scope decision is explicitly left for the user/Foreman at that
  rung. Do not pre-decide that a hard CPU exact case is NS. Honest NS is only
  for a genuine spec/Metal/emulation wall.

## Cross-Surface Composition for DCR4-F

DCR4-F must test F1-F4 together, not as isolated surfaces. The audit should
prove the DCR-3 legs still hold with all promoted paths active in one process
or frame sequence.

Required composition cases:

- F1 argbuf graphics draw followed by F2 mesh-GS draw using overlapping
  sampled/SSBO/image/FBO resources.
- F1 argbuf compute writes followed by F2/F3 graphics reads through the
  producer-pending funnel.
- F2 mesh-GS and F3 tessellation both active in the same frame, including
  current-command-buffer drain/standalone boundaries.
- F3 tessellation output followed by F4 TF capture or replay where exactness
  permits.
- F4 TF capture followed by readback, buffer redefinition, stream replay, and
  delete/lifetime cleanup.
- Resize/restore/transient invalidation while F1-F4 groups have pending work.
- Pressure/BAR-B style submission check if any implementation rung changes
  command-buffer counts, waits, or async behavior.

DCR4-F must preserve:

- bounded-outstanding pressure net.
- producer-pending resource funnel.
- commit-before-abandon.
- the existing DCR-3 sentinels and the 9/9 sentinel set under composed
  workloads, not only per-F isolated workloads.

## DCR4-A Gates

- This rung is doc-only.
- No runtime/source behavior changed.
- Validation for this rung is markdown/source hygiene only. Focused DCR-3
  sentinel runs are required only if a later revision touches code.
