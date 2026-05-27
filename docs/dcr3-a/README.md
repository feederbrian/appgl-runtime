# DCR3-A Command Submission Audit

DCR3-A classifies every known command-buffer reason without changing submit
behavior. It also adds debug counters required by the pressure work that follows:

- `pressureFlushCount`
- `currentInFlight`
- `peakInFlight`
- `allocWaitTimeoutsByReason`

Artifacts:

- [Flush-points audit](flush-points-audit.md)
- [Reason disposition table](reason-disposition.md)
- [Command-buffer allocation sites](command-buffer-allocation-sites.md)
- [Emergency-demand reserve](emergency-demand-reserve.md)

Invariants for this commit:

- Existing async frame and present submissions remain async.
- Existing commit-and-wait drains remain commit-and-wait.
- Existing allocation-only paths remain allocation-only.
- Legacy string labels are converted to typed reasons with centralized diagnostic labels.
- No new command buffers are allocated by DCR3-A.
- Memory impact is bounded to fixed-size counters in `MetalCommandSubmission::SharedState`.

DCR3-B remains gated on this audit and must only add pressure gating. DCR3-C
remains gated on B reducing the bounded contended sentinel.
