# S22 Feature-Tail Scope Note

Status: light scope note for Foreman+Clerk co-review before routine
feature-tail execution.

Baseline: DCR-5 crowned at `f9b5511`
(`Fix argbuf MSAA sample-mask resolve`).

Primary evidence:

- `tests/reports/s22-fantastic-rebuild/DCR5-PHASE0-8643e07/PHASE0-RESULT.md`
- `tests/reports/s22-fantastic-rebuild/DCR5-PHASE0-8643e07/metadata/phase0-comparison-summary.json`
- `tests/reports/s22-fantastic-rebuild/DCR5-PHASE4-EXIT-f9b5511/PHASE4-EXIT-RESULT.md`
- `specs-worker-docs/scout-memos/SCOUT-W-DCR5-f9b5511-FINAL-CROWN-2026-05-28.md`
- `specs-worker-docs/scout-memos/SCOUT-W-SPRINT22-GREAT-CLOSE-GATE-2026-05-23.md`

## Scope Boundary

This phase starts after the DCR-3/DCR-4/DCR-5 arc is crowned complete. The
DCR arc repaired the argument-buffer-specific architectural regressions and
proved production no-argbuf parity. The feature tail is not another DCR rung;
it is the remaining CTS residual cleanup and classification pass before the
S22 conformance verdict, followed later by DCR-ARC-CLOSE methodology
consolidation.

The dispatch calls the inherited DCR-5 reclassify-out starting set a
"24-case" set. The concrete record has 24 entries if framebuffer blit and DSA
are kept as one bucket each: 21 image common-fail cases, one
`basic-allTargets-loadStoreVS` image case, one framebuffer-blit bucket, and one
DSA-framebuffer bucket. If the framebuffer and DSA buckets are expanded to CTS
case names, the set is 26 concrete CTS cases. This note preserves both views.

## Starting Set

### Image Load/Store: 22 Concrete Cases

These are no-argbuf-equivalent or post-fix reclassified residuals, not
argbuf-specific DCR failures after `f9b5511`.

Canonical-identical common failures from DCR-5 Phase 0:

- `KHR-GL46.shader_image_load_store.advanced-allMips`
- `KHR-GL46.shader_image_load_store.advanced-allStages-oneImage`
- `KHR-GL46.shader_image_load_store.advanced-cast`
- `KHR-GL46.shader_image_load_store.advanced-memory-order`
- `KHR-GL46.shader_image_load_store.advanced-sso-simple`
- `KHR-GL46.shader_image_load_store.advanced-sso-subroutine`
- `KHR-GL46.shader_image_load_store.advanced-sync-imageAccess2`
- `KHR-GL46.shader_image_load_store.basic-allFormats-load`
- `KHR-GL46.shader_image_load_store.basic-allTargets-atomic`
- `KHR-GL46.shader_image_load_store.basic-allTargets-atomicGS`
- `KHR-GL46.shader_image_load_store.basic-allTargets-atomicTCS`
- `KHR-GL46.shader_image_load_store.basic-allTargets-atomicVS`
- `KHR-GL46.shader_image_load_store.basic-allTargets-load-nonMS`
- `KHR-GL46.shader_image_load_store.basic-allTargets-loadStoreGS`
- `KHR-GL46.shader_image_load_store.basic-allTargets-loadStoreTCS`
- `KHR-GL46.shader_image_load_store.basic-allTargets-loadStoreTES`
- `KHR-GL46.shader_image_load_store.basic-allTargets-store`
- `KHR-GL46.shader_image_load_store.basic-glsl-misc`
- `KHR-GL46.shader_image_load_store.multiple-uniforms`
- `KHR-GL46.shader_image_load_store.non-layered_binding`
- `KHR-GL46.shader_image_load_store.uniform-limits`

Post-DCR-5 carried reclassify-out:

- `KHR-GL46.shader_image_load_store.basic-allTargets-loadStoreVS`

### Framebuffer Blit Bucket: 3 Concrete Cases

- `KHR-GL46.framebuffer_blit.multisampled_to_singlesampled_blit_color_config_test`
- `KHR-GL46.framebuffer_blit.multisampled_to_singlesampled_blit_depth_config_test`
- `KHR-GL46.framebuffer_blit.scissor_blit`

### DSA Framebuffer Bucket: 1 Concrete Case

- `KHR-GL46.direct_state_access.framebuffers_texture_attachment`

## Broader Residual Context

SCOUT-W DCR-5 confirms focused-family production no-argbuf parity with DCR4-G
and argbuf-on parity with no-argbuf across 11/12 focused families. Known
non-DCR residual buckets in that focused set are:

- `geometry_shader`: `132P/2F/2NS`.
  - `KHR-GL46.geometry_shader.input.gl_pointsize_value`: Fail.
  - `KHR-GL46.geometry_shader.limits.max_combined_texture_units`: Fail.
  - `KHR-GL46.geometry_shader.api.max_atomic_counters`: NotSupported.
  - `KHR-GL46.geometry_shader.api.max_atomic_counter_buffers`: NotSupported.
- `tessellation_shader`: `139P/0F/1NS`.
  - `KHR-GL46.tessellation_shader.tessellation_shader_tessellation.max_in_out_attributes`: NotSupported.
- `shader_image_load_store`: `26P/22F/3NS`.
- `dsa_framebuffers`: `21P/1F`.
- `framebuffer_blit`: `3F`.
- `shader_atomic_counter_ops`: argbuf-on remains a pre-existing family-order
  quarantine in the SCOUT-W DCR-5 crown memo; no-argbuf DCR4-F final evidence
  also shows a bounded/hang shape after the first operation case.

The last full S22 GREAT close, before the DCR arc, had fp64-off
`18500P/120F/1077NS/19IE` and fp64-on `19161P/121F/415NS/19IE`.
Notable full-sweep residual buckets not fully expanded in the DCR-5 focused
package include:

- `sepshaderobjs`: `6P/2F`.
- `shader_ballot_tests`: `0P/0F/4NS`; already treated as Hard-NS-adjacent
  after the GS-flip re-exam.
- `shader_image_size`: `38P/0F/36NS`, with advanced-MS still not supported.
- full-sweep residuals outside the DCR focused-family lists, to be enumerated
  by the first post-DCR inventory sweep.

## Cluster Grouping

### Cluster A: Storage Image Load/Store Core

Cases: non-atomic image load/store, target/stage, format, layered binding,
uniform-limit, SSO/subroutine, and memory-order cases from the 22-case image
starting set.

Initial tractability: feature-tail-tractable. These look like runtime
translation, image view/format, stage binding, and memory-visibility gaps. The
first split should separate stage-specific lowering (`VS/TCS/TES/GS`) from
format/target matrix failures and from barrier/sync failures.

Gate shape: focused `shader_image_load_store` release+fp64-on, both modes,
plus a P->F/P->NonPass guard against the DCR-5 crowned baseline.

### Cluster B: Storage Image Atomics

Cases:

- `basic-allTargets-atomic`
- `basic-allTargets-atomicVS`
- `basic-allTargets-atomicTCS`
- `basic-allTargets-atomicGS`

Initial tractability: Hard-NS-register-candidate until proven otherwise.
Reason: GLSL image atomics map to storage-image atomic semantics; Apple Metal
runtime support for texture/image atomics may be absent or narrower than CTS
requires. If diagnosis finds a buffer-backed lowering path with correct GL
visibility, this can move to feature-tail-tractable. If the only route is
unbounded per-texel CPU emulation or an impossible Metal texture atomic, flag
immediately for Clerk+Foreman methodology review.

Gate shape: isolated atomic image cases first, then the image family cluster.

### Cluster C: Framebuffer Blit And MSAA Resolve Semantics

Cases: the three framebuffer-blit residuals.

Initial tractability: feature-tail-tractable, with a watch on the depth-MSAA
case. The failures are deterministic GL error/result mismatches, not hangs, and
the DCR3C producer/readback path is now stable. Likely surfaces are MSAA
resolve legality, CPU fallback equivalence, scissor-state interaction, and
depth/stencil blit policy.

Gate shape: focused framebuffer blit list, DCR3C blit/copy/mipmap sentinel,
and no-regression on readback-focused probes.

### Cluster D: DSA Framebuffer Attachment

Case: `direct_state_access.framebuffers_texture_attachment`.

Initial tractability: feature-tail-tractable. This is probably DSA state,
attachment identity, texture target/layer/level handling, or completeness
metadata. It should be handled near Cluster C because the verification surface
overlaps framebuffer state and readback.

Gate shape: DSA framebuffer focused list plus framebuffer/read-pixels smoke
controls.

### Cluster E: Geometry Shader Residuals

Cases:

- `geometry_shader.input.gl_pointsize_value`
- `geometry_shader.limits.max_combined_texture_units`
- `geometry_shader.api.max_atomic_counters`
- `geometry_shader.api.max_atomic_counter_buffers`

Initial tractability: mixed.

- `gl_pointsize_value`: feature-tail-tractable; likely GS built-in propagation.
- `max_combined_texture_units`: feature-tail-tractable or publication-acceptable
  depending whether the failure is a reported-limit policy issue or missing
  resource plumbing.
- GS atomic counter limits: Hard-NS-register-candidate. If AppGL does not
  support geometry-stage atomic counters by design, this should be reviewed as
  a capability/limit publication question instead of patched ad hoc.

Gate shape: geometry_shader full focused list and any geometry atomic-counter
limit probes identified during diagnosis.

### Cluster F: Tessellation Limit/Publication Residual

Case:

- `tessellation_shader.tessellation_shader_tessellation.max_in_out_attributes`

Initial tractability: publication-acceptable-residual candidate or
feature-tail-tractable limit-policy fix. The current NotSupported reason says
`GL_MAX_TESS_EVALUATION_OUTPUT_COMPONENTS > GL_MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS`.
If the advertised maxima are internally inconsistent, this may be fixed by
reported-limit policy. If CTS requires a capability Apple Metal cannot support
without large emulation, flag for methodology review before deep work.

Gate shape: single case first, then focused tessellation list.

### Cluster G: Shader Atomic Counter Ops

Cases: `KHR-GL46.shader_atomic_counter_ops_tests.*`.

Initial tractability: Hard-NS-register-candidate pending current isolate. DCR5
unlocked `shader_atomic_counters.basic-usage-simple`, but the ops family still
has return-value failures and bounded/hang history in prior artifacts. The
first move should be a current `f9b5511` isolated run per op case in both
modes, with wall caps, before any fix. If the family still hangs, flag
immediately for Clerk+Foreman methodology review.

Gate shape: per-case bounded isolates, then family run only after hang behavior
is understood.

### Cluster H: Known Full-Sweep Feature Tail Outside DCR Focus

Examples from Sprint 22 GREAT: `sepshaderobjs` 2F, `shader_ballot_tests` 4NS,
`shader_image_size` advanced-MS 36NS, plus any residuals found by the first
post-DCR full inventory sweep.

Initial tractability: mixed.

- `sepshaderobjs`: likely feature-tail-tractable.
- `shader_ballot_tests`: Hard-NS-register-candidate; prior notes tie this to
  int64/ballot capability.
- `shader_image_size` advanced-MS NS: publication-acceptable-residual or
  feature-tail-tractable depending on Metal multisample image-size support.
- Other full-sweep residuals: classify after inventory.

Gate shape: no cluster fix should claim S22 conformance movement without a
focused batch gate and a later full inventory comparison.

## Proposed Execution Order

1. Phase-0-equivalent inventory batch: run or assemble the post-DCR `f9b5511`
   residual inventory from SCOUT-W focused lists plus the latest full-sweep
   surfaces. Output exact case lists for all F/NS/IE buckets and mark
   Item-78-sensitive cases. The scope-note co-review locks the starting set;
   the inventory-batch joint review locks the full post-discovery scope.
2. Low-risk framebuffer batch: Clusters C and D. Small deterministic surface;
   good first routine-cadence batch gate.
3. Image core batch: Cluster A, split by target/stage versus sync/barrier.
4. Image atomic decision batch: Cluster B, with immediate methodology review
   if Metal image atomic support blocks a faithful implementation.
5. Geometry/tess limits batch: Clusters E and F, focusing first on reported
   limits and publication policy before runtime emulation.
6. Atomic counter ops isolate: Cluster G, with wall caps and immediate
   Hard-NS review if the hang shape persists.
7. Broader full-sweep residual batches: Cluster H after the inventory batch
   makes the full list precise.

## Gate And Review Cadence

Routine cadence applies:

- Mini-rungs: worker autonomy plus Foreman SHA-confirm per commit.
- Cluster completion: joint Foreman+Clerk co-review.
- Hard-NS candidate flag: immediate joint methodology review at diagnosis
  confirm time, before deciding whether to attempt a fix.
- Aggregate batch gate at cluster completion or every small group of mini-rungs
  when the cluster is large.
- Cluster completion review includes cross-cluster cascade replay at three
  levels: class, layer, and specific root. Initial layer-share candidates are
  A -> B for image-descriptor machinery, C -> D for framebuffer-state surface,
  and E -> G for atomic-binding paths.
- Cluster completion review also re-evaluates classifications against the
  just-closed diagnosis. Expected flip directions include
  Hard-NS-candidate -> feature-tail-tractable, feature-tail-tractable ->
  publication-acceptable-residual, and F/F-divergent -> canonical-identical
  reclassify-out when a fix removes AppGL-introduced divergence without
  resolving the underlying CTS failure.

Every aggregate batch gate must prove:

1. no regression versus DCR-5 crowned baseline `f9b5511`;
2. claimed improvements materialize in both relevant variants/modes;
3. unexpected deltas are explicitly classified.

The S22 conformance verdict still needs a pre-verdict joint closed-set review.
DCR-ARC-CLOSE happens after the feature tail, NS-post investigation, and S22
conformance verdict, before S22 close.

Calibrated expectation: cascade replay may materially compress the feature
tail, as DCR-5 did. Do not crown that compression locally; record it only when
the relevant batch gate proves it.
