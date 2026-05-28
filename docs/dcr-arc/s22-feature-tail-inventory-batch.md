# S22 Feature-Tail Inventory Batch

Date: 2026-05-28
Worker: AppGL-CW
Baseline for focused scope: post-DCR `f9b5511`

This is the Phase-0-equivalent inventory batch requested before Cluster C/D
execution. It combines the post-DCR focused-family residuals with the historical
Sprint 22 GREAT full-sweep residual surfaces.

## Generated Artifacts

Root:
`tests/reports/s22-fantastic-rebuild/S22-FEATURE-TAIL-INVENTORY-f9b5511/`

Exact case lists:

- Full GREAT sweep, fp64-off:
  - `great/by-status/full-sweep-fp64-off-Fail.cases.txt`
  - `great/by-status/full-sweep-fp64-off-NotSupported.cases.txt`
  - `great/by-status/full-sweep-fp64-off-InternalError.cases.txt`
- Full GREAT sweep, fp64-on:
  - `great/by-status/full-sweep-fp64-on-Fail.cases.txt`
  - `great/by-status/full-sweep-fp64-on-NotSupported.cases.txt`
  - `great/by-status/full-sweep-fp64-on-InternalError.cases.txt`
- Focused post-DCR inventory:
  - `focused/by-status/focused-post-dcr-f9b5511-Fail.cases.tsv`
  - `focused/by-status/focused-post-dcr-f9b5511-NotSupported.cases.tsv`
  - `focused/by-status/focused-post-dcr-f9b5511-InternalError.cases.tsv`

Machine-readable TSVs:

- `great/full-sweep-fp64-off-nonpass.tsv`
- `great/full-sweep-fp64-on-nonpass.tsv`
- `great/full-sweep-family-status-counts.tsv`
- `focused/focused-post-dcr-f9b5511-residual.tsv`
- `focused/dcr4f-final-no-argbuf-nonpass.tsv`
- `focused/dcr4f-argbuf-on-pre-dcr5-nonpass.tsv`

Integrity:

- `metadata/generated-counts.tsv`
- `metadata/SHA256SUMS.generated`

## Provenance

Focused post-DCR inventory uses:

- `SCOUT-W-DCR5-f9b5511-FINAL-CROWN-2026-05-28.md`
- `tests/reports/s22-fantastic-rebuild/DCR5-PHASE4-EXIT-f9b5511/`
- `tests/reports/s22-fantastic-rebuild/DCR5-PHASE0-8643e07/metadata/phase0-comparison-summary.json`
- `tests/reports/s22-fantastic-rebuild/DCR4-F-22496e5-FINAL/`
- `tests/reports/s22-fantastic-rebuild/DCR4-F-argbuf-triage/current-22496e5/`

Full-sweep context uses historical GREAT QPAs:

- `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/scout-worktree/reports/scout-sweep-s22-great-off-2026-05-23.qpa`
- `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/scout-worktree/reports/scout-sweep-s22-great-on-2026-05-23.qpa`

The QPA-derived counts exactly reproduce the GREAT close memo:

| Surface | Fail | NotSupported | InternalError | Item-78-sensitive |
| --- | ---: | ---: | ---: | ---: |
| GREAT fp64-off | 120 | 1,077 | 19 | 0 |
| GREAT fp64-on | 121 | 415 | 19 | 1 |
| Focused post-DCR no-argbuf, per variant | 28 | 6 | 0 | 0 |
| Focused post-DCR argbuf-on, per variant | 32 | 6 | 0 | 0 |

## Focused Residual Scope

The focused post-DCR list is the execution scope input. For both fp64 variants,
the no-argbuf residual set is identical. DCR5 establishes argbuf-on parity for
the same focused families, with `shader_atomic_counter_ops` retained as the
pre-existing argbuf-on baseline residual.

Focused Fail cases common to no-argbuf and argbuf-on:

```text
KHR-GL46.direct_state_access.framebuffers_texture_attachment
KHR-GL46.framebuffer_blit.multisampled_to_singlesampled_blit_color_config_test
KHR-GL46.framebuffer_blit.multisampled_to_singlesampled_blit_depth_config_test
KHR-GL46.framebuffer_blit.scissor_blit
KHR-GL46.geometry_shader.input.gl_pointsize_value
KHR-GL46.geometry_shader.limits.max_combined_texture_units
KHR-GL46.shader_image_load_store.basic-allFormats-load
KHR-GL46.shader_image_load_store.basic-allTargets-store
KHR-GL46.shader_image_load_store.basic-allTargets-load-nonMS
KHR-GL46.shader_image_load_store.basic-allTargets-atomic
KHR-GL46.shader_image_load_store.basic-allTargets-loadStoreVS
KHR-GL46.shader_image_load_store.basic-allTargets-loadStoreTCS
KHR-GL46.shader_image_load_store.basic-allTargets-loadStoreTES
KHR-GL46.shader_image_load_store.basic-allTargets-loadStoreGS
KHR-GL46.shader_image_load_store.basic-allTargets-atomicVS
KHR-GL46.shader_image_load_store.basic-allTargets-atomicTCS
KHR-GL46.shader_image_load_store.basic-allTargets-atomicGS
KHR-GL46.shader_image_load_store.basic-glsl-misc
KHR-GL46.shader_image_load_store.advanced-sync-imageAccess2
KHR-GL46.shader_image_load_store.advanced-allStages-oneImage
KHR-GL46.shader_image_load_store.advanced-memory-order
KHR-GL46.shader_image_load_store.advanced-sso-simple
KHR-GL46.shader_image_load_store.advanced-sso-subroutine
KHR-GL46.shader_image_load_store.advanced-allMips
KHR-GL46.shader_image_load_store.advanced-cast
KHR-GL46.shader_image_load_store.non-layered_binding
KHR-GL46.shader_image_load_store.multiple-uniforms
KHR-GL46.shader_image_load_store.uniform-limits
```

Focused Fail cases added only to final argbuf-on scope:

```text
KHR-GL46.shader_atomic_counter_ops_tests.ShaderAtomicCounterOpsAdditionSubstractionTestCase
KHR-GL46.shader_atomic_counter_ops_tests.ShaderAtomicCounterOpsMinMaxTestCase
KHR-GL46.shader_atomic_counter_ops_tests.ShaderAtomicCounterOpsBitwiseTestCase
KHR-GL46.shader_atomic_counter_ops_tests.ShaderAtomicCounterOpsExchangeTestCase
```

Focused NotSupported cases, both modes:

```text
KHR-GL46.geometry_shader.api.max_atomic_counters
KHR-GL46.geometry_shader.api.max_atomic_counter_buffers
KHR-GL46.shader_image_load_store.basic-allFormats-loadStoreComputeStage
KHR-GL46.shader_image_load_store.basic-allTargets-load-ms
KHR-GL46.shader_image_load_store.advanced-sso-perSample
KHR-GL46.tessellation_shader.tessellation_shader_tessellation.max_in_out_attributes
```

Focused InternalError cases: none.

## Item-78 Marking

The exact full-sweep residual list marks:

```text
KHR-GL46.texture_gather.gather-geometry-shader    ITEM78
```

It appears as `Fail` only in the GREAT fp64-on historical sweep and is the known
sustained-sweep oscillator from the Sprint 22 GOOD/F1 notes. It is not a focused
post-DCR residual.

Known Item-78 watch cases that are not nonpass in the GREAT residual lists:

```text
KHR-GL46.geometry_shader.layered_fbo.fb_texture_invalid_value
```

## Scope Lock Notes

- Full-sweep exact lists are historical GREAT context, not a substitute for the
  focused post-DCR f9b5511 execution scope.
- Focused post-DCR scope has no `InternalError` bucket.
- Cluster C/D should remain held until co-review locks the full scope.
- Cross-cluster cascade replay remains required at cluster completion:
  A->B image descriptors, C->D framebuffer state, E->G atomic binding.
