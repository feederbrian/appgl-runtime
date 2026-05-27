# Reason Disposition

DCR3-A does not convert any wait behavior. The disposition below is the design
gate for later sub-steps: "keep-wait" means no async conversion without a new
barrier proof; "convert" means a later DCR may remove a wait once pressure
gating and ordering sentinels are green.

## Per-Class Table

| Class | Reasons | DCR3 disposition | Justification |
| --- | --- | --- | --- |
| `Legacy` | `Legacy`, `CompletionWait` | Keep-wait / compatibility only | Old string overloads are retained for compatibility. DCR3-A sweeps known callers to typed reasons; new call sites should not use this class. |
| `None` | `BeginRenderPass`, `SolidColorDraw`, `TranslatedDraw`, `ImmediateModeDraw` | Already no wait; pressure-gate allocation | These allocate/encode the current frame CB. There is no immediate CPU read attached to allocation. |
| `FrameRing` | `FrameRingSlot` | Keep-wait | This is the bounded ring-slot backpressure wait, not a command-buffer completion wait. Removing it breaks frame-resource lifetime. |
| `FrameSignal` | `FrameCommandBuffer`, `EndFrame` | Already async; keep async | Completion handler signals the frame semaphore. No CPU-visible result is consumed immediately. |
| `Readback` | `FlushForReadback` | Keep-wait | Direct CPU visibility point for pixels/textures/readback staging. |
| `Present` | `FlushClear`, `PresentPendingWork` | Keep async/allocation-only; pressure-gate | Present work is GPU-visible only. CPU reads after present flush through their own readback paths. |
| `Standalone` | `DrainCurrentStandalone` | Convert only after B | Current drain exists to preserve queue ordering before standalone encoding. It is not itself a CPU read, but conversion requires the B pressure sentinels to prove bounded ordering. |
| `Lifetime` | `FinishWait`, `LifetimeDrain`, `FrameGraphDestruct` | Keep-wait | `glFinish`, lifetime drain, and destruction must return with outstanding work complete or safely owned. |
| `GpuOnlyOrdering` | `LayeredClearDrainCurrent`, `LayeredClear`, `TessDrainCurrent`, `PressureFlush` | Convert after B when no CPU read follows | These are ordering drains between GPU-only producers/consumers. Convert only when the next CPU read is still guarded by a later flush point. |
| `CpuVisibleBarrier` | `VertexTransformFeedbackReadback`, `DepthStencilFlip`, `CpuVisibleBarrier` | Keep-wait | These paths immediately expose Shared/staging data to CPU or are the future explicit CPU visibility barrier class. |
| `Upload` | `TextureUpload`, `RenderbufferMirror` | Keep-wait initially | Uploads are CPU-to-GPU, but many are followed by immediate validation/readback-sensitive use. Convert only with a proof that the next consumer is queue-ordered and no CPU read observes stale state. |
| `Copy` | `CopyImageBlit`, `CopyTextureSubImage` | Mixed; keep in A | GPU-only copies can convert later. CPU-shadow fallback/readback-adjacent paths must stay waited until DCR3-F adds GPU-dirty tracking and CPU-visible barriers. |
| `Tessellation` | `TessVertexCompute`, `TessControlCompute`, `TessFactorClamp`, `TessDomainGenerate`, `TessEvalCompute`, `TessRender` | Mixed; keep in A | Some stages feed later GPU work, but domain/probe/count/debug paths read Shared buffers on CPU. Convert only per-stage in DCR3-E with immediate-consumer proof. |
| `Mesh` | `MeshVertexCompute`, `MeshDraw` | Convert in E with sentinels | Mesh emulation is GPU-only in the target path, but conversion depends on E's ordering and readback sentinels. |
| `Compute` | `ComputeDispatch` | Keep until F | Compute writes can affect buffers/textures later read by CPU. Needs GPU-dirty tracking and `CpuVisibleBarrier` before async conversion. |
| `SparseResidency` | `SparseResidency` | Keep-wait | Sparse mapping/upload must be complete before sparse texture use or sidecar init can rely on it. |
| `Sidecar` | `SparseSidecar`, `Fp64Sidecar` | Keep-wait | Sidecar initialization and fp64 emulation state are correctness prerequisites for immediate later use. |
| `Probe` | `TessProbe` | Keep-wait | Probes immediately read GPU-written diagnostic buffers to decide feature path. |

## Per-Reason Matrix

| Reason | Mode in DCR3-A | Class | Later disposition |
| --- | --- | --- | --- |
| `Legacy` | `Allocate` | `Legacy` | Compatibility only; no new use. |
| `BeginRenderPass` | `Allocate` | `None` | Pressure-gate allocation. |
| `FlushClear` | `Allocate` | `Present` | Pressure-gate allocation. |
| `SolidColorDraw` | `Allocate` | `None` | Pressure-gate allocation. |
| `TranslatedDraw` | `Allocate` | `None` | Pressure-gate allocation. |
| `ImmediateModeDraw` | `Allocate` | `None` | Pressure-gate allocation. |
| `FrameCommandBuffer` | `AsyncCommit` | `FrameSignal` | Keep async. |
| `PresentPendingWork` | `AsyncCommit` | `Present` | Keep async. |
| `EndFrame` | `AsyncCommit` | `FrameSignal` | Keep async. |
| `FlushForReadback` | `CommitAndWait` | `Readback` | Keep-wait. |
| `DrainCurrentStandalone` | `CommitAndWait` | `Standalone` | Convert only after B. |
| `FrameRingSlot` | `WaitOnly` | `FrameRing` | Keep-wait. |
| `CompletionWait` | `WaitOnly` | `Legacy` | Compatibility only. |
| `FinishWait` | `AsyncCommit` | `Lifetime` | Keep async commit plus lifetime drain. |
| `LifetimeDrain` | `DrainAll` | `Lifetime` | Keep-wait. |
| `FrameGraphDestruct` | `CommitAndWait` | `Lifetime` | Keep-wait. |
| `LayeredClearDrainCurrent` | `CommitAndWait` | `GpuOnlyOrdering` | Convert after B if no immediate CPU read. |
| `LayeredClear` | `CommitAndWait` | `GpuOnlyOrdering` | Convert after B if no immediate CPU read. |
| `VertexTransformFeedbackReadback` | `CommitAndWait` | `CpuVisibleBarrier` | Keep-wait. |
| `TessDrainCurrent` | `CommitAndWait` | `GpuOnlyOrdering` | Convert only with E ordering proof. |
| `TessVertexCompute` | `CommitAndWait` | `Tessellation` | Stage-specific E decision. |
| `TessControlCompute` | `CommitAndWait` | `Tessellation` | Stage-specific E decision. |
| `TessFactorClamp` | `CommitAndWait` | `Tessellation` | Stage-specific E decision. |
| `TessDomainGenerate` | `CommitAndWait` | `Tessellation` | Keep where CPU count/probe follows; otherwise E may convert. |
| `TessEvalCompute` | `CommitAndWait` | `Tessellation` | Stage-specific E decision. |
| `TessRender` | `CommitAndWait` | `Tessellation` | Stage-specific E decision. |
| `TessProbe` | `CommitAndWait` | `Probe` | Keep-wait. |
| `MeshVertexCompute` | `CommitAndWait` | `Mesh` | E may convert with sentinels. |
| `MeshDraw` | `CommitAndWait` | `Mesh` | E may convert with sentinels. |
| `ComputeDispatch` | `CommitAndWait` | `Compute` | Keep until F. |
| `CopyImageBlit` | `CommitAndWait` | `Copy` | Convert GPU-only copies only after D/F barriers. |
| `CopyTextureSubImage` | `CommitAndWait` | `Copy` | Convert GPU-only copies only after D/F barriers. |
| `TextureUpload` | `CommitAndWait` | `Upload` | Keep initially. |
| `DepthStencilFlip` | `CommitAndWait` | `CpuVisibleBarrier` | Keep-wait. |
| `RenderbufferMirror` | `CommitAndWait` | `Upload` | Keep initially. |
| `SparseResidency` | `CommitAndWait` | `SparseResidency` | Keep-wait. |
| `SparseSidecar` | `CommitAndWait` | `Sidecar` | Keep-wait. |
| `CpuVisibleBarrier` | `CommitAndWait` | `CpuVisibleBarrier` | Future explicit keep-wait barrier. |
| `Fp64Sidecar` | `CommitAndWait` | `Sidecar` | Keep-wait. |
| `PressureFlush` | `AsyncCommit` | `GpuOnlyOrdering` | Async; must not allocate its own CB. |
