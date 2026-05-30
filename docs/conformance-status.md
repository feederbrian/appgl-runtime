# AppGL Conformance Status

**Last verified:** 2026-05-30 (Sprint 22 conformance close, HEAD `093a6bd`)

AppGL targets the Khronos OpenGL 4.6 conformance test suite (`KHR-GL46`).
This page summarises the verified state of that suite at each released
build, the residual tests that do not pass, and the structural reason
each one does not. The goal is that an application porter can quickly
see whether a test failure they hit corresponds to a known residual
class or whether it is something new worth reporting.

## At a glance

| Variant | Pass | Fail | Not supported | Notes |
|---------|-----:|-----:|--------------:|-------|
| Default (`APPGL_FP64_EMULATION=OFF`)     | 18,703 | 36 | 976 | 17 residual vs DCR-5 baseline |
| Double-precision (`APPGL_FP64_EMULATION=ON`) | 19,362 | 35 | 312 | 18 residual vs DCR-5 baseline |

These numbers are from the Sprint 22 conformance close
(`SCOUT-W FINAL CROWN #3` at HEAD `093a6bd`), measured at full sweep
under the canonical method (no `--deqp-surface-type=fbo`; window
default surface; AppGL command-buffer environment defaults; see
[performance-levers.md](performance-levers.md) for the relevant runtime
knobs).

The default and double-precision builds share one runtime; the
double-precision build additionally turns on the df64 emulation path
described in [double-precision.md](double-precision.md). The 660-case
gap on `Not supported` between the two variants is the `GL_ARB_gpu_shader_fp64`
surface that is gated off in the default build.

## How to read residuals

Every test in the residual surface falls into one of three top-level
classes. The class tells you whether the residual is something AppGL
can fix, something that depends on the test harness, or something that
will require structural implementation work.

### §75-A — Broadening side-effect (AppGL scope)

A change that AppGL needed to make in one code path produced an
unintended side-effect in a different test. The side-effect is fixable
in AppGL; the residual is open work for a future sprint.

Sub-classes:

- **Runtime code-path** — a fix to one runtime code-path interacts
  with a shared lower-level path. Sprint 22 example: the multisample
  storage-image queries fix in `e0391674` exposed `GL_MAX_IMAGE_SAMPLES`,
  which caused a small number of tests to start exercising a
  previously-unreachable error-validation branch. The narrow follow-up
  fix at `093a6bd` corrected the error-code (returns
  `GL_INVALID_OPERATION` per GL 4.6 §8.19 rather than the previous
  `GL_INVALID_VALUE`).
- **Extension advertisement layer** — advertising a particular
  extension causes the CTS to run a test that another part of AppGL
  cannot satisfy. Sprint 22 example: four `sparse_texture_tests`
  `TextureParameterQueries_*` cases want `GL_ARB_sparse_texture` to be
  the only sparse extension; AppGL advertises both
  `GL_ARB_sparse_texture` and `GL_ARB_sparse_texture2` because hiding
  the latter would regress eight `sparse_texture2_tests` and
  `sparse_texture_clamp_tests` cases. This is a documented project
  trade-off, not a defect.

### §75-B — Latent implementation gap (AppGL scope)

A specific GL surface is present in the runtime but not fully
implemented end-to-end. The residual cannot be fixed by adjusting a
neighbouring code-path; it requires the implementation to be filled
in. As of S22 close, AppGL has exactly one confirmed §75-B residual:

- `KHR-GL46.shader_image_load_store.basic-allTargets-store` —
  the multisample storage-image *store* path is not yet end-to-end.
  The test executes the store branch and reads back the cleared
  default texture state, because the store does not yet reach the
  GPU texture. This is scheduled for an implementation pass in a
  future sprint.

### CTS structural gates (test-suite intent)

A test is structurally written to be unreachable on AppGL's capability
matrix. AppGL cannot resolve these without modifying the CTS test
source. They show up as `NotSupported` rather than `Fail`, and they
are stable; you should not treat them as defects in AppGL. Examples
include `texture_swizzle` projection / `texelFetch` cases that are
gated on target+access+format combinations, `shader_integer_mix.prototypes`
which gates on GLSL 4.50 in a way that does not interact with the
non-extension path AppGL takes, and the LOW-priority sample-count
limit gates (`sample_variables.samples_8`, the
`fragment_shading_rate.render_target_multiview` layer cap).

## Residual at S22 close (HEAD `093a6bd`)

These are the tests that change state versus the DCR-5 baseline at
Sprint 22 close. There are 17 of these in the default build and 18 in
the double-precision build.

### §75-A shared-path side-effect (13 default / 14 double-precision)

The dominant residual class at S22 close. These tests share an internal
code path with one of the Sprint 22 fixes and went `Fail` at the same
time the fix landed. Each one is a small follow-up fix, similar in
character to the `093a6bd` narrow follow-up that closed
`KHR-GL46.direct_state_access.textures_storage_errors`. Tracked in
[`tests/caselists/ns-post-phase1-deep-inspection-pending.txt`](../tests/caselists/ns-post-phase1-deep-inspection-pending.txt)
with class-tag annotations.

### §75-A extension-advertisement trade-off (4 cases, both variants)

These four `KHR-GL46.sparse_texture_tests.TextureParameterQueries_*`
cases (`texture_2d_array`, `texture_2d_multisample_array`, `texture_3d`,
`texture_cube_map`) want only the original `GL_ARB_sparse_texture`
extension to be advertised. AppGL advertises both `GL_ARB_sparse_texture`
and `GL_ARB_sparse_texture2`. Hiding `_sparse_texture2` would regress
eight tests in the `_sparse_texture2_tests` and
`_sparse_texture_clamp_tests` families. The trade is +4 / −8, so the
documented choice is to keep the broader surface advertised.

### §75-B latent implementation gap (1 case, both variants)

- `KHR-GL46.shader_image_load_store.basic-allTargets-store` — see the
  §75-B description above. Open implementation work.

### Properly-deferred (no change vs DCR-5)

Two additional residual classes are stable and structural; they appear
in `NotSupported` and do not change with a runtime fix.

- **Apple Silicon FP64 ALU absence**: 660 cases in the default build
  are gated on `GL_ARB_gpu_shader_fp64`. They pass in the
  double-precision build via the df64 emulation path; the default
  build returns `NotSupported`. See [double-precision.md](double-precision.md)
  for the alternate build instructions.
- **CTS structural gates**: 73 `LOW-PURE-ARCH-LIMIT-GATE` cases
  (`sample_variables.samples_8` family, three `fragment_shading_rate`
  multiview cases), 186 `texture_swizzle.*` target/access/format
  gates, one `shader_integer_mix.prototypes` GLSL-version gate, and
  five other related deferrals are CTS-side classification, not AppGL
  defects.

## Pending caselist

The full set of cases that the project tracks for future investigation
lives in
[`tests/caselists/ns-post-phase1-deep-inspection-pending.txt`](../tests/caselists/ns-post-phase1-deep-inspection-pending.txt).
That file has roughly 207 case-level entries; about 127 of them are
status-confirmed-correctly-deferred (the four `§75-A-EXT-ADV`, the
186 `texture_swizzle` CTS-structural cases, and so on — listed so a
future sprint can re-check them when relevant Apple Metal evolution
lands), and the remaining ~80 are the actionable items for a future
feature-tail subtrack.

## Regression-guard caselists

Every test that the Sprint 22 arc recovered from `Fail` or `NotSupported`
to `Pass` is captured in a per-fix caselist under `tests/caselists/`.
The guard caselists are short, focused, and meant to be run by a
contributor who is editing the corresponding runtime code path:

| Caselist | Cases | Origin |
|----------|-----:|--------|
| `ns-post-hard-viewport-layer-array.txt` | 3 | NS-POST step (1) viewport-layer locations fix |
| `ns-post-pub-shader-image-size-ms.txt`  | ~42 | NS-POST step (2) multisample storage-image queries + `multi_bind` protection |
| `phase1-med-feature-tail-recovered-926091ca.txt` | 13 | Path Z `multi_bind` recovery + IE-roots `clear_tex_image` recoveries |
| `phase1-med-feature-tail-dsa-rgb32-recovered.txt` | 23 | Direct-state-access RGB32 texture path recovery |
| `phase1-med-feature-tail-dsa-rgb32-recovered-narrowed-584b481.txt` | 24 | Path X-MED narrowed superset (23 DSA RGB32 + `textures_storage_errors`) |
| `phase1-med-feature-tail-internalformat-recovered.txt` | 12 | `internalformat` depth + RGB10 copy recoveries |
| `phase1-med-feature-tail-shader-integer-mix-recovered.txt` | 6 | `GL_EXT_shader_integer_mix` advertisement recoveries |
| `phase1-med-feature-tail-texture-swizzle-already-passing.txt` | 6 | `texture_swizzle.functional_*` MS variants confirmed-already-passing |

Running any one of these against a build at HEAD `093a6bd` should
produce a clean pass; a failure in one of these is a meaningful
regression signal and worth reporting.

## Reporting a residual

If you encounter a `KHR-GL46.*` test failure that does not appear in
the regression-guard caselists above, the most useful thing you can
include in a report is:

1. The exact test name (full `KHR-GL46.*` path).
2. The AppGL commit you tested.
3. The variant (default or double-precision).
4. The `.qpa` or `.stdout` excerpt for the test.
5. Whether the test appears in
   `tests/caselists/ns-post-phase1-deep-inspection-pending.txt`.
   If yes, the class-tag column tells you which residual category
   AppGL has already classified it under; surfacing the wider context
   is usually still valuable.

## Method

The numbers on this page were measured with the AppGL conformance
runner at the canonical method:

- Window-default surface (no `--deqp-surface-type=fbo`).
- AppGL command-buffer environment defaults
  (`APPGL_COMMAND_BUFFER_BOUND=48`, `APPGL_COMMAND_BUFFER_RESERVE=4`,
  `APPGL_COMMAND_BUFFER_TIMEOUT_MS=30000`).
- Tessellation emulation flags
  (`APPGL_ENABLE_METAL_TESS=1`, `APPGL_ENABLE_METAL_TESS_TF=1`,
  `APPGL_ENABLE_TESS_EMUL=1`, `APPGL_ENABLE_TESS_EMUL_GLIN=1`,
  `APPGL_LIFT_TESS_UNIFORM_GUARD=1`).
- The default (`APPGL_FP64_EMULATION=OFF`) and double-precision
  (`APPGL_FP64_EMULATION=ON`) variants are measured separately;
  the conformance verdict requires both.
- `KHR-GL46` test surface; per-variant 19,716 cases.

Any test result reported on this page can be reproduced by running
`tests/caselists/<test-list>.txt` against a build at HEAD `093a6bd`
under that same environment.

## Cross-references

- [README.md](README.md) — project overview and supported GL versions.
- [performance-levers.md](performance-levers.md) — runtime knobs
  including the command-buffer environment defaults.
- [double-precision.md](double-precision.md) — `APPGL_FP64_EMULATION=ON`
  variant and the `GL_ARB_gpu_shader_fp64` surface.
- [apple-metal-upstream-tracking.md](apple-metal-upstream-tracking.md) —
  the Apple Metal capability constraints that drive several of the
  residual classes on this page.

---

*This page is updated at each sprint close. The numbers above are at
the Sprint 22 conformance close (HEAD `093a6bd`, 2026-05-30); the
next refresh follows the Sprint 23 close.*
