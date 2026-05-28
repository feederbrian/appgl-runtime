# S22 Feature-Tail C/D Batch

Date: 2026-05-28
Worker: AppGL-CW
Baseline: parent `f9b5511`, committed as one C/D mini-rung
Artifact root shape: `tests/reports/s22-fantastic-rebuild/CDBATCH-CD1-<commit-short>/`

## Scope

Cluster C:

- `KHR-GL46.framebuffer_blit.multisampled_to_singlesampled_blit_color_config_test`
- `KHR-GL46.framebuffer_blit.multisampled_to_singlesampled_blit_depth_config_test`
- `KHR-GL46.framebuffer_blit.scissor_blit`

Cluster D:

- `KHR-GL46.direct_state_access.framebuffers_texture_attachment`

## Result

All four focused CTS cases pass in the release no-argbuf default environment.

| Case | rc | QPA result | Duration |
| --- | ---: | --- | ---: |
| `KHR-GL46.framebuffer_blit.multisampled_to_singlesampled_blit_color_config_test` | 0 | Pass | 2258.29s |
| `KHR-GL46.framebuffer_blit.multisampled_to_singlesampled_blit_depth_config_test` | 0 | Pass | 42.60s |
| `KHR-GL46.framebuffer_blit.scissor_blit` | 0 | Pass | 490.81s |
| `KHR-GL46.direct_state_access.framebuffers_texture_attachment` | 0 | Pass | 0.55s |

## Cascade Replay

`dcr3c-sentinels` was replayed under the same release no-argbuf environment.
Result: rc 0, `passed=true`, 9/9 tests passed. The replay includes the
`dcr3c.bar-blit-copy-mipmap` BAR blit/copy/mipmap sentinel.

Evidence:

- `tests/reports/s22-fantastic-rebuild/CDBATCH-CD1-<commit-short>/logs/dcr3c-sentinels-cd1-release.json`
- `tests/reports/s22-fantastic-rebuild/CDBATCH-CD1-<commit-short>/status/dcr3c-sentinels-cd1-release.rc`

## IE Scrutiny Link

The paired IE scrutiny update promotes
`KHR-GL46.direct_state_access.textures_compressed_subimage` to classification
(i), yielding final counts: 19 known pre-existing with prior protocol
disclosure, 0 uncharacterized, 0 possible regressions, 0 Hard-NS.
