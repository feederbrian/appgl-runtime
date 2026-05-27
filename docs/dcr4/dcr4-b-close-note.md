# DCR4-B Close Note

Status: submission grouping implemented; runtime policy unchanged.

## Implementation Pattern

- Added `AppGLSubmissionGroup` in `src/context/AppGLSubmissionGroups.h` as a fixed-capacity, behavior-neutral declaration record for parent groups, subgroups, resource reads/writes, and internal transients.
- Threaded group declarations through `TranslatedDrawInfo`, `ComputeDispatchInfo`, and `MetalMeshGSDrawInfo`.
- `GLContext` declares semantic resource sets from existing GL resource resolution and DCR3 producer-funnel data before encoding.
- `MetalFrameGraph` annotates actual transient materialization where argbuf payloads, uniform-ring bytes, SSBO-size sidecars, and mesh-GS VS-output buffers are allocated.
- No new scheduler, queue, fallback path, command-buffer wait, or env policy was introduced. Producer marking and draining remain on the existing DCR3 path.

## F1 Ordering

- Graphics and compute argbuf payloads are CPU-populated before binding and consumed by the same render or compute command encoder/command buffer.
- Ring-backed uniform bytes and SSBO-size sidecars are same-draw or same-dispatch transients, annotated as `CpuBeforeEncodeSameCommandBuffer`.
- Resources referenced indirectly through argument buffers continue to use the existing `useResource` calls for textures and buffers referenced through the argbuf.
- Compute dispatch keeps its existing `ComputeDispatch` commit-and-wait policy.
- Mesh-GS `vsOutBuf` remains ordered by the current `CpuCompletionWait`; removing that wait belongs to a later rung.

## Gate Results

Artifact/log root: `tests/reports/s22-fantastic-rebuild/DCR4-B-wip-688f37a`.

- Build: `cmake --build build-release --target AppGL -j8` passed with existing `MTLResourceUsageSample` deprecation warnings.
- Renderer preflight: 1/1 pass, `logs/renderer-preflight.stdout`.
- CKPT91 default-off: 15/15 pass, `logs/ckpt91-defaultoff.stdout`.
- CKPT91 argbuf-on: 7/15 pass, 8 fail, `logs/ckpt91-argbufon.stdout`.
- SSBO family: 247/247 pass, `logs/ssbo-family.stdout`.
- Storage-image family: 31/51 pass, 17 fail, 3 not supported, `logs/storage-image-family.stdout`.
- Shader atomic counters: 31/31 pass, `logs/shader-atomic-counters-family.stdout`.
- Program interface query: 43/43 pass, `logs/program-interface-family.stdout`.

The CKPT91 argbuf-on failure was present on the current s22-fantastic-rebuild line before the DCR4-B grouping edits: the same gate shape failed 7/15 with a pre-DCR4-B dylib during triage. DCR4-B triage experiments also forced standalone transient buffers, tried dense UBO encoder indices, and restored an argbuf-only FBO tail wait; the single UBO case still failed. That points away from the new grouping metadata and toward the existing current-line F1 argbuf baseline.

SCOUT-W was not run because this change does not modify shader translation or binding routing; it only declares resource sets and transients around existing binding code.
