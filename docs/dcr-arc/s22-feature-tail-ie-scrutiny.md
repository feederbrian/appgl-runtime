# S22 Feature-Tail IE Scrutiny

Artifact root: `tests/reports/s22-fantastic-rebuild/S22-FEATURE-TAIL-IE-SCRUTINY-f9b5511/`

Summary:

- GREAT fp64-off and fp64-on IE sets are identical: 19 cases.
- All 19 are `InternalError` in the checked prior/current matrix: Apr 28 merged inventory, Sprint 20 close, Sprint 21 close, GREAT off/on, DCR4E off/on.
- Post-adjudication classification: 19 known pre-existing with prior protocol disclosure, 0 pre-existing but uncharacterized, 0 possible regressions.
- Hard-NS candidates: 0.

`KHR-GL46.direct_state_access.textures_compressed_subimage` was promoted after joint adjudication under the graded protocol-disclosure standard. Prose characterization: DSA compressed texture subimage upload/update path aborts internally; QPA result text is only `InternalError/Error`, but exact multi-sweep stability plus the DCR3-B `IE=19 baseline` gate language validates it as pre-existing and supplies the protocol-disclosure handle for future reviewers.

Primary files:

- `IE-SCRUTINY-RESULT.md`
- `ie-classification.tsv`
- `ie-status-matrix.tsv`
- `ie-cases-symmetric.txt`
