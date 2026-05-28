# DCR4-G Scope Note

Status: draft for Foreman and Clerk co-review.

Scope: cleanup rung after the DCR4-F final crown. DCR4-G is not a new feature
surface and must not broaden routing, flip defaults, or reinterpret the
DCR4-F verdict. Its job is to commit the DCR4-F audit artifacts, make the
composition harness usable as an all-in-one tool, and remove runtime-only
test toggles from production builds.

## Goals

1. Hygiene-commit the DCR4-F artifacts that are currently in-tree untracked:
   - `docs/dcr4/dcr4-f-design-note.md`
   - `tests/DCR4FCompositionHarness.cpp`, including the `--argbuf=on|off`
     tooling switch added for GO#3 packaging.
2. Fix the DCR4-F composition harness all-in-one mode:
   - The one-process-per-sentinel mode is accepted and crowned.
   - The all-in-one mode currently aborts around
     `dcr4f.control1-cpu-bufferdata-to-f1-texture-buffer-sample` with a Metal
     command-buffer assertion.
   - Clerk classified this as harness state-leak/cleanup between sentinel
     phases, not a runtime conformance finding.
3. Convert DCR4/DCR3 red-stub environment hooks into compile-gated test hooks
   per Section 91.
4. Sweep for small DCR4-era cleanup items discovered during implementation,
   limited to comments, dead helper paths, and test-only wiring.

## Non-Goals

- No DCR4-F recrowning from AppGL-CW local data.
- No default change for `APPGL_ENABLE_ARGUMENT_BUFFERS`.
- No route widening for F1/F2/F3/F4 surfaces.
- No fixes for argbuf-on baseline residuals; those stay in the S22 feature-tail
  consolidated sub-track.
- No Hard-NS adjudication beyond preserving the DCR4-F draft entry for
  `KHR-GL46.shader_atomic_counters.basic-usage-simple`.

## Work Items

### 1. Artifact Hygiene

Add the DCR4-F design note and composition harness source to the tracked tree.
The harness is test tooling only. It dlopens a supplied `libAppGL.dylib`; it
does not link into or alter the runtime.

Expected edits:

- Track `docs/dcr4/dcr4-f-design-note.md`.
- Track `tests/DCR4FCompositionHarness.cpp`.
- Optionally update `docs/dcr4/README.md` to list DCR4-F and DCR4-G notes if
  that follows the existing README pattern.

### 2. Composition Harness All-In-One Cleanup

Make the harness safe to run all sentinels from one command.

Approach:

- Treat every sentinel as owning an isolated GL/AppGL context lifetime.
- Preserve `--only` as the in-process one-sentinel mode; make default
  all-in-one mode orchestrate one child process per sentinel and aggregate the
  same JSON schema. This keeps the all-in-one tool robust against process-wide
  Metal state left by an argbuf-on sentinel.
- Ensure RAII cleanup runs before the next sentinel starts, including bound FBOs,
  textures, buffers, transform-feedback objects, query objects, VAOs, programs,
  and the AppGL context.
- Drain or finish at sentinel boundaries in the harness only if needed to avoid
  leaving a command encoder active across teardown.
- Preserve the existing one-process-per-sentinel behavior and JSON schema.
- Keep `--argbuf=on|off`; default remains `on` for parity with the DCR4-F
  argbuf-on audit, while GO#3/SCOUT-W ship-mode uses `--argbuf=off`.

Acceptance:

- `appgl_dcr4f_composition --argbuf=off` completes all sentinels from one
  command
  without aborting in both release and fp64-on.
- `appgl_dcr4f_composition --argbuf=on` also completes without process abort.
  Individual verdicts may still include known RED outcomes, but process
  integrity must hold.
- One-process-per-sentinel results remain equivalent to the DCR4-F package
  shape: 9 pass, alias-known-RED, double-count not-constructed.

### 3. Section 91 Env-Stub To Compile-Gate

Runtime red-stub hooks used to prove DCR4 sentinels should not remain in
production builds as environment-variable branches. Convert them to a
compile-gated test-hook layer.

Candidate hooks found in the DCR4 sweep:

- `APPGL_STUB_COMMIT_BEFORE_ABANDON`
- `APPGL_DCR4C_MESH_GS_ZERO_VSOUT`
- `APPGL_DCR4D_TESS_ZERO_VSOUT`
- `APPGL_DCR4D_TESS_ZERO_FACTORBUF`
- `APPGL_DCR4D_TF_EXCLUDE_SKIP_CPU_WRITE`
- `APPGL_DCR4E_TF_SKIP_PRODUCER_MARK`
- `APPGL_DCR4E_IMAGE_SKIP_PRODUCER_MARK`
- `APPGL_DCR4E_FORCE_TF_CAPTURE_FAIL`
- `APPGL_DCR4E_TF_SKIP_CPU_WRITE`
- `APPGL_DCR4E_SKIP_QUERY_UPDATES`
- `APPGL_DCR4E_SKIP_TF_COUNT_UPDATE`
- `APPGL_DCR4E_FORCE_STREAM_REPLAY_ZERO_COUNT`
- `APPGL_DCR4E_FORCE_GS_RASTER_ENCODE_FAIL`

Approach:

- Introduce one compile-time guard for DCR sentinel test hooks, for example
  `APPGL_ENABLE_DCR_SENTINEL_HOOKS`.
- Production builds compile these branches out entirely.
- Test-hook builds may still select the red-stub behavior by environment
  variable so existing sentinel drivers stay simple.
- If a hook is no longer used by any tracked test, delete it instead of
  compile-gating it.
- Keep hook names and comments clearly marked as test-only in any guarded code.

Risk classification:

- Section 106 is the expected path for DCR4-G once this work item lands.
  Compile-gating the runtime `getenv` branches changes the production dylib by
  design: production no longer ships the test-stub code.
- Report old and new dylib SHA/UUID for both variants, distinguish the expected
  production hash change from a stale-build accident, and route the standard
  Section 106 gate.

Sub-rung decision:

- Land all four cleanup work items in one DCR4-G artifact rather than splitting
  §91 into a separate sub-rung. The scope is consolidated cleanup, and the
  expected production hash change will be documented once in the DCR4-G close
  result.

### 4. DCR4-Era TODO / Dead-Code Sweep

Perform a narrow audit for cleanup only:

- stale DCR4-era comments that say a sentinel is blocked or pending after
  DCR4-F crown.
- unused helper code introduced solely to diagnose DCR4-F packaging.
- obvious dead test snippets in the harness.

Do not use this sweep to refactor shared runtime infrastructure.

## Gate Plan

### Local Verification

For DCR4-G's consolidated Section 106 path:

- `git diff --check`
- build production release and fp64-on AppGL explicitly with DCR hooks compiled
  out:
  - `cmake --build build-release --target AppGL appgl_gauntlet_cli -j8`
  - `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli -j8`
- build hook-enabled release and fp64-on test artifacts for red-stub sentinel
  verification:
  - `cmake -S . -B build-release-dcrhooks -DCMAKE_BUILD_TYPE=Release -DAPPGL_FP64_EMULATION=OFF -DAPPGL_VENDOR_THIRD_PARTY=ON -DAPPGL_DCR_SENTINEL_HOOKS=ON`
  - `cmake -S . -B build-release-fp64on-dcrhooks -DCMAKE_BUILD_TYPE=Release -DAPPGL_FP64_EMULATION=ON -DAPPGL_VENDOR_THIRD_PARTY=ON -DAPPGL_DCR_SENTINEL_HOOKS=ON`
- build the DCR4-F composition harness with optimized flags, not `-O0`.
- Record old-vs-new release and fp64-on dylib SHA/UUID. A production dylib
  change is expected from §91.
- Run DCR4-F composition harness:
  - all-in-one `--argbuf=off`, hook-enabled release and fp64-on.
  - all-in-one `--argbuf=on`, hook-enabled release and fp64-on.
  - one-process-per-sentinel smoke for any sentinel affected by cleanup, using
    the hook-enabled artifacts.
- Run hard sentinels at least once in ship-mode no-argbuf default:
  - `dcr3-sentinels`
  - `dcr3c-sentinels`
  - `dcr4c-sentinels`
  - `dcr4d-sentinels`
  - `dcr4e-sentinels`
  - Use the hook-enabled test build for red-stub checks; use the production
    hook-off dylib for §106 SHA/UUID and stale-build proof.
- Run focused CTS case lists touched by the affected hook area:
  geometry, tessellation, transform feedback, shader image/SSBO/atomic,
  framebuffer/readback probes as applicable.

### Artifact Expectations

Land DCR4-G artifacts under:

`tests/reports/s22-fantastic-rebuild/DCR4-G-<shortsha>/`

Required contents:

- close/result note with the exact scope completed.
- SHA/UUID proof for both variants.
- dyld proof for the harness and gauntlet CLI.
- harness all-in-one logs and per-sentinel comparison logs.
- hard-sentinel JSON/status logs.
- `git diff --check` result.

### SCOUT-W Routing

After Foreman SHA-confirm:

- Route to SCOUT-W for DCR4-G gate-of-record.
- SCOUT-W validates the cleanup did not perturb the crowned DCR4-F property.
- DCR4-G crown, if earned, clears the path to DCR-5.
