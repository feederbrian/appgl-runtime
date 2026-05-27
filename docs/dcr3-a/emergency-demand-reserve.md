# Emergency-Demand Reserve

DCR3-A defines the must-not-block command-buffer demand that DCR3-B must keep
available while normal allocations are pressure-gated.

| Emergency need | Allocates a new CB today | Maximum concurrent demand | Notes |
| --- | --- | --- | --- |
| Readback fence after outstanding async work | Yes | 1 | `flushForReadback()` may allocate a fence CB when no current CB exists but outstanding work remains. |
| Readback staging blit | Yes | 1 | Texture/depth readbacks allocate a `FlushForReadback` CB for private/sparse texture staging. This is the same emergency class as the readback fence. |
| Current-CB readback flush | No | 0 | Commits and waits the existing current CB. |
| `glFinish` / drain-all | No | 0 | Commits existing current work with `FinishWait`, then drains the in-flight semaphore with `LifetimeDrain`. |
| Lifetime/destructor drain | No | 0 | `FrameGraphDestruct` may commit an existing current CB; `LifetimeDrain` does not allocate. |
| Present / swap / `glFlush` | No | 0 | Commits existing current CB asynchronously. No CPU visibility is promised. |
| Query-result fence | No today | 0 today, 1 future | Query results are CPU-side today. GPU-backed queries must reserve one fence CB or reuse `CpuVisibleBarrier`. |
| Pressure flush's own CB | Must be no | 0 | Pressure flush must commit existing current work and record `PressureFlush`; it must not allocate a CB. If a future implementation allocates a pressure fence, reserve must increase. |
| Probe or sidecar diagnostic CB | Yes, but normal class | 0 emergency today | `TessProbe`, `SparseSidecar`, and `Fp64Sidecar` remain keep-wait normal allocations. They should run below `bound - reserve` unless explicitly promoted. |

Current maximum concurrent emergency allocation demand is 1 CB. That covers the
readback fence/staging case because each path allocates one emergency CB and
waits it before continuing.

DCR3-B reserve recommendation:

- Set `reserve >= 4`.
- Required minimum by today's audit is `1`.
- The extra margin covers one future query-result fence, one diagnostic or
  pressure-implementation mistake during development, and one safety slot while
  sentinels validate edge cases.

B must prove:

- Normal allocations stop or pressure-flush before consuming the reserve.
- Readback, `glFinish`, present, lifetime drain, and query-result paths cannot
  block forever when normal work has filled the non-reserved capacity.
- `pressureFlushCount` increments only when a pressure flush is requested.
- `peakInFlight` never exceeds the configured bound.
- `allocWaitTimeoutsByReason` remains zero for all reasons in the contended
  sentinel.
