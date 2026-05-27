# Command-Buffer Allocation Sites

All command-buffer allocations funnel through
`MetalCommandSubmission::makeCommandBufferImpl` (`src/context/MetalCommandSubmission.h:422`).
DCR3-A classifies every call site with a typed reason. DCR3-B must add the
pressure gate at the central allocator plus any pre-allocation current-CB flush
needed for standalone allocations.

| Site | Reason | Pressure-gated in B |
| --- | --- | --- |
| `src/context/MetalFrameGraph.mm:1062` | `BeginRenderPass` | Yes, via `ensureCurrentCommandBuffer` -> central allocator. |
| `src/context/MetalFrameGraph.mm:1169` | `FlushClear` | Yes, via `ensureCurrentCommandBuffer` -> central allocator. |
| `src/context/MetalFrameGraph.mm:1241` | `SolidColorDraw` | Yes, via `ensureCurrentCommandBuffer` -> central allocator. |
| `src/context/MetalFrameGraph.mm:2454` | `TranslatedDraw` | Yes, via `ensureCurrentCommandBuffer` -> central allocator. |
| `src/context/MetalFrameGraph.mm:5355` | `ImmediateModeDraw` | Yes, via `ensureCurrentCommandBuffer` -> central allocator. |
| `src/context/MetalFrameGraph.mm:5214` | `LayeredClear` | Yes, standalone allocation; B must preflight pressure before allocation. |
| `src/context/MetalFrameGraph.mm:5680` | `FlushForReadback` | Yes, emergency readback fence allocation. |
| `src/context/MetalFrameGraph.mm:5722` | `FlushForReadback` | Yes, emergency readback standalone allocation. |
| `src/context/MetalFrameGraph.mm:5805` | `FlushForReadback` | Yes, emergency readback fence allocation. |
| `src/context/MetalFrameGraph.mm:5960` | `VertexTransformFeedbackReadback` | Yes, CPU-visible readback allocation; reserve-protected. |
| `src/context/MetalFrameGraph.mm:6509` | `TessVertexCompute` | Yes, standalone allocation. |
| `src/context/MetalFrameGraph.mm:6602` | `TessControlCompute` | Yes, standalone allocation. |
| `src/context/MetalFrameGraph.mm:6963` | `TessFactorClamp` | Yes, standalone allocation. |
| `src/context/MetalFrameGraph.mm:6984` | `TessDomainGenerate` | Yes, standalone allocation. |
| `src/context/MetalFrameGraph.mm:7054` | `TessDomainGenerate` | Yes, standalone allocation. |
| `src/context/MetalFrameGraph.mm:7078` | `TessDomainGenerate` | Yes, standalone allocation. |
| `src/context/MetalFrameGraph.mm:7192` | `TessEvalCompute` | Yes, standalone allocation. |
| `src/context/MetalFrameGraph.mm:7824` | `MeshVertexCompute` | Yes, standalone allocation. |
| `src/context/MetalFrameGraph.mm:7942` | `MeshDraw` | Yes, standalone allocation. |
| `src/context/MetalFrameGraph.mm:8299` | `ComputeDispatch` | Yes, standalone allocation. |
| `src/context/MetalFrameGraph.mm:9487` | `TessProbe` | Yes, probe allocation; keep inside emergency-safe reserve if probes run near pressure. |
| `src/context/MetalFrameGraph.mm:9714` | `TessProbe` | Yes, probe allocation; keep inside emergency-safe reserve if probes run near pressure. |
| `src/context/GLContext.mm:4955` | `TextureUpload` | Yes, helper routes through context submission wrapper. |
| `src/context/GLContext.mm:5306` | `TextureUpload` | Yes, helper routes through context submission wrapper. |
| `src/context/GLContext.mm:6454` | `DepthStencilFlip` | Yes, CPU-visible staging allocation. |
| `src/context/GLContext.mm:6517` | `DepthStencilFlip` | Yes, CPU-visible staging allocation. |
| `src/context/GLContext.mm:6983` | `RenderbufferMirror` | Yes, upload allocation. |
| `src/context/GLContext.mm:7040` | `RenderbufferMirror` | Yes, upload allocation. |
| `src/context/GLContext.mm:11369` | `FlushForReadback` | Yes, emergency readback allocation. |
| `src/context/GLContext.mm:11566` | `FlushForReadback` | Yes, emergency readback allocation. |
| `src/context/GLContext.mm:11754` | `FlushForReadback` | Yes, emergency readback allocation. |
| `src/context/GLContext.mm:11862` | `FlushForReadback` | Yes, emergency readback allocation. |
| `src/context/GLContext.mm:17825` | `CopyImageBlit` | Yes, GPU-copy allocation. |
| `src/context/GLContext.mm:49866` | `CopyTextureSubImage` | Yes, GPU-copy allocation. |
| `src/context/GLContext.mm:50693` | `FlushForReadback` | Yes, emergency texture readback allocation. |
| `src/context/GLContext.mm:50890` | `FlushForReadback` | Yes, emergency texture readback allocation. |
| `src/context/GLContext.mm:51229` | `FlushForReadback` | Yes, emergency texture readback allocation. |
| `src/extensions/sparse_texture/SparseTextureAlloc.mm:347` | `SparseResidency` | Yes, sparse residency allocation. |
| `src/extensions/sparse_texture/SparseTextureAlloc.mm:769` | `SparseResidency` | Yes, sparse committed-region upload allocation. |
| `src/extensions/sparse_texture/SparseStorageImageEmulation.mm:575` | `SparseSidecar` | Yes, sparse sidecar allocation. |

Non-allocation waits:

- `FrameRingSlot` waits on the frame semaphore and does not allocate a CB.
- `CompletionWait` waits on an external completion semaphore and does not allocate a CB.
- `LifetimeDrain` drains outstanding work by acquiring/releasing the in-flight semaphore capacity and does not allocate a CB.
- `FinishWait`, `FrameCommandBuffer`, `PresentPendingWork`, and `EndFrame` commit an existing current CB with a completion handler and do not allocate a new CB at commit time.

DCR3-B confirmation requirement: a saturation test must prove every allocation
above either proceeds while capacity is below `bound - reserve` or triggers a
pressure flush without consuming the emergency reserve.
