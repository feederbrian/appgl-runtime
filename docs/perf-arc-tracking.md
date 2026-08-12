# AppGL Perf ARC Tracking

Status: C45 is crowned as the Step 7 rung 3 memory/Mach-port stability checkpoint. C46 is crowned as a default-off opt-in perf win. C47 capture evidence now proves the sampler GPU-order skip removes the live sampler-drain wait cost while residual `FlushForReadback` submits remain a structural-attribution lane. C48's `35df142` shadow-compare y-flip attempt was root-caused as helper-scope unsafe in Warzone-shaped shaders, and replacement fix `d73c6e1` is landed with helper-scope threading, negative compile-failure caching, and helper-shaped probes. Fixed-SHA Sweep A default is dispatched to Scout; Sweep B forward/crown remains held behind A. The `e2a876d` C49 census preview is withdrawn, and a new unswept `d73c6e1` operator preview is staged. Canonical live pin remains the pre-C48 `A8483891` runtime.
Date: 2026-06-10
Owner: AppGL-Foreman

## Active Baseline

- Source worktree: `$PROJECT_ROOT/appgl-runtime`
- Base branch at pickup: `master` / `d28b150`
- Perf baseline-of-record remains the GLTest A864F73B provisional Warzone capture:
  `sampler_producer_drain` `21.875 us/draw`, nested under
  `sampler_bindings_total`; `framegraph_encode` is a sibling bucket.
- Current roadmap: `specs-worker-docs/S24-PERF-ARC-PLAN.md`
- Hazard design: `docs/dcr3-c/sampler-producer-hazard-design.md`

## Step 7 Rung 1

Implemented producer-token instrumentation only:

- `GLProducerPendingState` now stores a latest producer token alongside the
  existing pending bitfield.
- When the token profile is enabled, producer marks create token snapshots with
  resource kind/name/bits, token epoch, same-queue-orderable flag, and reserved
  completion/command-buffer fields. When the profile is disabled, producer marks
  use the old bit-only path to avoid disabled-profile hot-path token writes.
- Existing producer-drain behavior is unchanged: pending sampler/CPU consumers
  still call the old `flushForReadback()` path and clear bits exactly through
  the existing mark/drain helpers.
- New aggregate profile dump:
  `[APPGL_GL_PRODUCER_TOKEN_PROFILE]`
- The token profile is enabled by `APPGL_GL_DRAW_PROFILE=1` for profile-of-record
  runs, or directly with `APPGL_GL_PRODUCER_TOKEN_PROFILE=1`.
- Counters cover mark entries, alias fanout, range/direct drains, sampler
  pending hits, completed-token skip candidates, same-queue GPU-order
  candidates, per-resource-kind totals, and translated-draw write sources.
- Profile-enabled contexts now also dump draw/detail/token profile rows through
  the profiling atexit/SIGTERM/SIGINT/SIGHUP path so controlled live-target
  SIGTERM runs can preserve GL/token rows alongside CB rows.

Important limitation: `known_completed_epoch` currently advances only after an
existing AppGL wait completes, and the token `completed` / command-buffer fields
are placeholders for the later completion-handler rung. This is instrumentation
for candidate discovery, not an async Metal completion-handler model and not a
skip gate.

## EDB4C8AC Live Token Profile

GLTest-Foreman completed the EDB4C8AC Warzone token-profile refire:

- Summary:
  `$PROJECT_ROOT/ogl-test-application/ogltest/traces-db/revendor/2026-06-09-step7-rung1-warzone-token-profile-EDB4C8AC-20260609T022218Z/baseline-warzone-tokenprofile-highground-json-1280x720-EDB4C8AC-midscene-sigterm8s/PROFILE-SUMMARY.md`
- Runtime/source UUID: `EDB4C8AC-1682-3477-935B-DBD24DBC875B`
- sha256: `0e3708445bd0f13a8a563c5a35a880f4407769b08aa647d95e9349dfe8827fe5`
- Exit: controlled SIGTERM `143`, no game-ended marker, no shutdown abort.
- Rows: GL draw `27`, GL detail `20`, producer-token `6`, CB `2842`.
- Draw summary: `draws=5193`, `avg_us=40.841`, `total_us=212087.949`,
  `accounted_us=316858.837`; overlapping bucket caveat still applies.
- Hot buckets: `sampler_producer_drain` `116772.353 us` total,
  `22.486 us/draw`, `55.06%`; `sampler_bindings_total` `23.682 us/draw`;
  `framegraph_encode` `31.513 us/draw`.
- Token profile: `sampler pending_hits=46`, `gpu_ordered_candidates=46`,
  `completed_skip_candidates=0`, `unmodeled_token_hits=0`.

Disposition: rung 2 completed-token skip has no live Warzone candidates in this
sample. Rung 3 same-queue GPU-order sampler skip is the profile-supported next
candidate, provided it remains gated by A/B, stale-pixel protection, and live
re-profile.

## Step 7 Rung 3 Candidate

Implemented an opt-in same-queue GPU-order sampler skip candidate:

- Feature gate: `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`.
- Default behavior remains the old sampler wait-and-clear path.
- The sampler path now uses `drainSamplerGpuProducers()`:
  - Records the same sampler read-set/token counters.
  - If every matching pending producer is a texture token with exact pending
    bits, matching resource name, same-queue ordering, and no legacy MSAA flush,
    it skips the CPU `flushForReadback()`.
  - It does not clear producer-pending bits on a GPU-order skip; later
    CPU-visible consumers still drain and clear through the old path.
  - Any buffer, renderbuffer, legacy MSAA, missing token, partial token, or
    unknown-ordering case falls back to the existing drain path.
- Token tracking now activates when either producer-token profiling is enabled
  or the skip gate is enabled, so the feature can be A/B tested without forcing
  profile mode.
- Added token-profile counters:
  `token_merged_marks`, `gpu_order_skips`, `gpu_order_skip_resources`,
  `gpu_order_skip_blocked`, and first-failure block reasons for legacy MSAA,
  non-texture resources, missing tokens, token kind/name mismatches,
  non-ordered tokens, and producer-bit mismatches.

Review-fixed F120 candidate identity:

- `build-release-fp64on/libAppGL.dylib`
- UUID `F120F1C0-1A38-334D-AB1F-6829AEB229D0`
- sha256 `71396b001a7b30b1fa1c64a3269a88d596260ca62dc5529a7e1e61cc5408b918`
- Supersedes pre-review candidate `486490E2-7892-33CF-ABD1-8F24B2A20623`.

Review fixes after AppGL-Worker pass:

- Signal-triggered profile dumps now use a self-pipe/helper-thread path:
  the POSIX signal handler only writes the signal number, while the helper
  thread does the C++ profile dump and re-raises the signal.
- The active profile-context registry uses process-lifetime heap storage to
  avoid atexit/static-destruction ordering hazards.
- The sampler skip predicate now requires exact producer-bit equality
  (`token.producerBits == pendingBits`) instead of accepting a superset.

Post-live follow-up candidate identity:

- `build-release-fp64on/libAppGL.dylib`
- UUID `FAF1A9BA-B6D6-3482-B1B5-7C55621C5AD4`
- sha256 `0395bf4e4dc44e62e7182d07938f2561ce5a64693a1cf696608cb0cc5b026ef3`
- Supersedes `F120F1C0` for the next review/gate cycle.

Follow-up change after Gate 3 miss:

- `GLProducerPendingState::mark(const GLProducerToken&)` now merges token
  producer bits across continuous same-resource, same-queue modeled marks
  instead of overwriting the latest token's bit snapshot each time.
- The exact predicate remains intact. If any legacy/unmodeled mark cleared
  token identity, or if token identity/order/name/kind does not match, the
  sampler skip still blocks and falls back to the old drain path.
- The profile stream now reports `token_merged_marks` plus specific
  `gpu_order_skip_blocked_*` reason counters so another live miss can be
  attributed without guesswork.

## Verification

- Build: `cmake --build build-release-fp64on --target AppGL -j2` passed.
  Existing warnings only: Metal `MTLResourceUsageSample` deprecations and
  duplicate-library linker warnings.
- Smoke:
  `APPGL_GL_DRAW_PROFILE=1 ./build-release-fp64on/appgl_bar_b_benchmark --library ./build-release-fp64on/libAppGL.dylib --mode producer --size 64 --frames 1 --warmup-frames 1 --chain-draws 2 --no-uploads --shader-iters 1`
  passed.
- Smoke token profile: `token_epoch=6`, `drain_flushes=2`,
  `sampler_pending_hits=2`, `sampler_gpu_ordered_candidates=2`,
  `translated_draw_writes fbo=6`.
- Profile SIGTERM smoke:
  `APPGL_GL_DRAW_PROFILE=1 ./build-release-fp64on/appgl_bar_b_benchmark --library ./build-release-fp64on/libAppGL.dylib --mode producer --size 128 --frames 100000 --warmup-frames 1 --chain-draws 48 --no-uploads --shader-iters 4`
  was terminated with SIGTERM after startup and exited `143`; stderr emitted
  both `[APPGL_GL_DRAW_PROFILE]` and `[APPGL_GL_PRODUCER_TOKEN_PROFILE]` rows.
  Token summary included `token_epoch=1274`, `drain_flushes=26`,
  `sampler_pending_hits=26`, `sampler_gpu_ordered_candidates=26`, and
  `translated_draw_writes fbo=1274`.
- DCR3-C sentinel check:
  `cmake --build build-release-fp64on --target appgl_gauntlet_cli -j2` and
  `./build-release-fp64on/appgl_gauntlet_cli dcr3c-sentinels` passed.
  The pre-existing `dcr3c.bar-copyimage-sparse-lifecycle` failure was fixed by
  draining texture producer bits before `getTextureImage` returns through the
  CPU-shadow copy path.
- Opt-in BAR-B A/B smoke after rung 3 candidate:
  - Baseline: `coreMs=14.013667`, `perDrawUs=56.054668`,
    `sampler_producer_drain=45.365 us/draw`, readback RGBA
    `[212,113,22,255]`.
  - `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`: `coreMs=5.379875`,
    `perDrawUs=21.519500`, `sampler_producer_drain=0.013 us/draw`,
    `gpu_order_skips=6`, `gpu_order_skip_blocked=0`, readback RGBA
    `[212,113,22,255]`.
  - The delayed wait moved into isolated readback (`0.024542 ms` baseline to
    `5.307583 ms` skip), matching the design expectation.
- Review-fixed SIGTERM profile smoke:
  - Controlled SIGTERM exited `143`.
  - `[APPGL_GL_DRAW_PROFILE]` and `[APPGL_GL_PRODUCER_TOKEN_PROFILE]` rows
    emitted from the helper-thread dump path.
- DCR3-C gate after rung 3 candidate:
  - `./build-release-fp64on/appgl_gauntlet_cli dcr3c-sentinels`: passed.
  - `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 ./build-release-fp64on/appgl_gauntlet_cli dcr3c-sentinels`: passed.
  - `dcr3c.producer-inventory-bits` now verifies the skip-mode contract:
    sampler GPU-order consumption preserves source producer bits, and a later
    source texture CPU readback drains and clears them.
- Post-live token-merge candidate `FAF1A9BA`:
  - `cmake --build build-release-fp64on --target AppGL -j2`: passed.
  - `cmake --build build-release-fp64on --target appgl_bar_b_benchmark -j2`:
    passed.
  - BAR-B paired smoke artifacts:
    `tests/reports/perf-step7-rung3-token-merge-local/`
  - Baseline: `coreMs=14.003500`, `perDrawUs=56.014000`,
    `sampler_producer_drain=46.371 us/draw`, readback RGBA
    `[212,113,22,255]`, `token_merged_marks=288`.
  - `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`: `coreMs=5.280917`,
    `perDrawUs=21.123668`, `sampler_producer_drain=0.007 us/draw`,
    `gpu_order_skips=6`, `gpu_order_skip_blocked=0`,
    `token_merged_marks=292`, all block-reason counters `0`, readback RGBA
    `[212,113,22,255]`.
  - Skip-enabled controlled SIGTERM smoke exited `143` and emitted draw/token
    rows: `gpu_order_skips=1002`, `gpu_order_skip_blocked=0`,
    `token_merged_marks=49104`.
  - `cmake --build build-release-fp64on --target appgl_gauntlet_cli -j2`:
    passed.
  - Default and `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`
    `dcr3c-sentinels`: both passed.

## External Gate Evidence

Pre-review UUID `486490E2-7892-33CF-ABD1-8F24B2A20623` completed both external
gates before AppGL-Worker review fixes landed:

- GLTest Gate 1 synthetic A/B passed:
  - Artifact root:
    `$PROJECT_ROOT/ogl-test-application/ogltest/traces-db/revendor/2026-06-09-step7-rung3-sampler-gpu-order-synthetic-ab-486490E2-20260609T023739Z`
  - Median `perDrawUs` `56.661 -> 39.477`, delta `-17.184 us/draw`
    (`-30.33%`).
  - `sampler_producer_drain` `44.941 -> 0.0045 us/draw`.
  - `drain_flushes` `100 -> 2`; `gpu_order_skips` `0 -> 100`;
    `gpu_order_skip_blocked=0`; readback identical.
- Scout Gate 2 focused stale-pixel/conformance sweep passed:
  - Focused `111/111` caselist, default and skip both
    `P=106 F=4 NS=1 IE=0`.
  - Skip vs d28b150 baseline: `P->F=0`, `status_transitions=0`.
  - Skip vs default: `status_transitions=0`, `P->nonPass=0`.

Review-fixed UUID `F120F1C0-1A38-334D-AB1F-6829AEB229D0` now has formal Gate 1
and Gate 2 clearance:

- GLTest formal Gate 1 synthetic A/B rerun passed:
  - Artifact root:
    `$PROJECT_ROOT/ogl-test-application/ogltest/traces-db/revendor/2026-06-09-step7-rung3-sampler-gpu-order-synthetic-ab-F120F1C0-20260609T025449Z`
  - Median `perDrawUs` `54.122 -> 37.223`, delta `-16.899 us/draw`
    (`-31.22%`).
  - `sampler_producer_drain` `41.733 -> 0.0065 us/draw`.
  - `drain_flushes` `100 -> 2`; `gpu_order_skips` `0 -> 100`;
    `gpu_order_skip_blocked=0`; readback identical.
- Scout formal Gate 2 focused stale-pixel/conformance rerun passed:
  - Report dir:
    `$PROJECT_ROOT/scout-worktree/reports/perf-step7-rung3-sampler-gpu-order-scout-F120F1C0/`
  - Focused `111/111` caselist, default and skip both
    `P=106 F=4 NS=1 IE=0`.
  - F120 skip vs d28b150 baseline: `P->F=0`, `P->nonPass=0`,
    `status_transitions=0`.
  - F120 skip vs F120 default: `status_transitions=0`, `P->nonPass=0`.

Gate 3 live Warzone re-profile on `F120F1C0` completed with valid identity and
profile rows, but did not validate the lever as implemented:

- Artifact root:
  `$PROJECT_ROOT/ogl-test-application/ogltest/traces-db/revendor/2026-06-09-step7-rung3-warzone-skip-profile-F120F1C0-20260609T030212Z`
- Selected run:
  `skip-warzone-tokenprofile-highground-json-1280x720-F120F1C0-midscene-sigterm8s`
- Rows: GL draw `27`, GL detail `20`, producer-token `6`, CB `2633`.
- Runtime proof passed: source/live UUID and SHA matched, pinned AppGL and
  bridge dylibs mapped, highground loaded, controlled SIGTERM exit `143`, no
  game-ended/shutdown-abort marker.
- Draw summary: `draws=5018`, `avg_us=39.247`, `total_us=196940.745`.
- `sampler_producer_drain`: `21.525 us/draw`, still same-range with
  A864F73B `21.875` and EDB4C8AC `22.486`.
- Token profile: `sampler_pending_hits=42`, `sampler_gpu_ordered_candidates=42`,
  `gpu_order_skips=0`, `gpu_order_skip_blocked=42`,
  `completed_skip_candidates=0`, `unmodeled_token_hits=0`.

Disposition: Gate 3 profile row path and runtime proof passed, but behavior did
not. The exact-token guard blocked every live same-queue sampler candidate, so
the synthetic BAR-B sampler-drain collapse did not reproduce in live Warzone.
The next step is to diagnose and fix the block reason before any crown claim.

FAF1A9BA Gate 1 synthetic A/B rerun is green:

- Bridge message: `a8a7e811-84c5-418d-b051-a6af5d973250`.
- Artifact root:
  `$PROJECT_ROOT/ogl-test-application/ogltest/traces-db/revendor/2026-06-09-step7-rung3-token-merge-gate1-synthetic-ab-FAF1A9BA-20260609T032512Z`
- Workload matched the established Gate 1 BAR-B shape:
  `--mode producer --size 64 --frames 96 --warmup-frames 4 --chain-draws 64 --no-uploads --shader-iters 1`.
- Validity: `8/8` exit `0`; GL draw/detail/token/CB rows present every band;
  full-run readback identity matched `[50, 2, 144, 255]`.
- Median `perDrawUs` `56.637 -> 39.221`, delta `-17.417 us/draw`
  (`-30.75%`).
- `sampler_producer_drain` `44.7515 -> 0.0055 us/draw`.
- `drain_flushes` `100 -> 2`; `gpu_order_skips` `0 -> 100`;
  `gpu_order_skip_resources` `0 -> 100`; `gpu_order_skip_blocked` `0 -> 0`.
- All new block-reason counters were `0` in both arms.
- `token_merged_marks` `6400 -> 6498`.
- `isolatedReadbackMs` shifted `0.013 -> 6.874 ms`, matching the design that
  the wait moves to the final CPU-visible readback.

FAF1A9BA Gate 2 focused stale-pixel/conformance rerun is green:

- Bridge message: `99fc9e61-8c45-46dd-85e0-351fef64e19f`.
- Report dir:
  `$PROJECT_ROOT/scout-worktree/reports/perf-step7-rung3-token-merge-gate2-FAF1A9BA/`
- Focused `111/111` caselist plus `dcr3c-sentinels`.
- Default and skip gauntlet rc `0`; all `9` DCR3-C sentinels passed.
- CTS default and skip both `P=106 F=4 NS=1 IE=0`; inherited
  `4 F / 1 NS` match baseline.
- FAF1 skip vs d28b150 baseline: `status_transitions=0`,
  `P->nonPass=0`, `P->F=0`.
- FAF1 skip vs FAF1 default: `status_transitions=0`, `P->nonPass=0`.
- Worker-emphasis coverage stayed clean: repeated FBO/readback,
  mixed FBO+clear/copy/mipmap, texture-view/source alias sampling,
  texture-buffer fallback, legacy MSAA fallback, and CPU readback after
  skipped sampler consumers.
- Full `19,716`-case CTS was not run.

FAF1A9BA Gate 3 live Warzone rerun achieved live sampler skip behavior:

- Bridge message: `66395c45-4501-4f25-95c0-38e579700228`.
- Artifact root:
  `$PROJECT_ROOT/ogl-test-application/ogltest/traces-db/revendor/2026-06-09-step7-rung3-token-merge-warzone-profile-FAF1A9BA-20260609T033140Z`
- Selected run:
  `skip-warzone-tokenmerge-highground-json-1280x720-FAF1A9BA-midscene-sigterm8s`
- Profile row path passed: GL draw `27`, GL detail `20`, producer-token `6`,
  CB `2180`.
- Identity/runtime proof passed: source and live pin UUID/SHA matched, pinned
  AppGL and bridge dylibs mapped, Warzone reached AppGL renderer, highground
  loaded, controlled SIGTERM exit `143`, no game-ended or shutdown-abort marker,
  final exact-name process scan clean.
- GL draw: `draws=5100`, `avg_us=18.630`, `total_us=95015.054`.
- `sampler_producer_drain`: `0.178 us/draw`, down from A864F73B `21.875`,
  EDB4C8AC `22.486`, and F120 live miss `21.525`.
- Token profile: `token_merged_marks=4254`, `drain_flushes=0`,
  `drain_pending_hits=0`, `sampler_pending_hits=873`,
  `sampler_gpu_ordered_candidates=873`, `gpu_order_skips=873`,
  `gpu_order_skip_resources=873`, `gpu_order_skip_blocked=0`,
  `sampler_unmodeled_token_hits=0`, `completed_skip_candidates=0`.
- All new block-reason counters were `0`: legacy MSAA, non-texture, no-token,
  token kind, token name, ordering, producer bits.
- Draw average moved from F120 `39.247 us/draw` to FAF1A9BA `18.630 us/draw`.
- `framegraph_encode` stayed same-range: F120 `29.945` to FAF1A9BA
  `30.784 us/draw`, confirming the sampler drain pinch moved rather than
  disappearing into that sibling bucket.
- GLTest disposition: profile row path PASS, identity/runtime proof PASS, and
  live sampler skip behavior achieved in this profile; GLTest did not make a
  crown claim.

## User Live Review: Leak Blocker

After the live launcher was pinned to `FAF1A9BA` and
`APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`, the user completed a manual Warzone
review:

- Average FPS varied by scene, around `17 FPS`, up from around `7 FPS`.
- CPU usage was around `70-100%`.
- GPU usage was around `30-40%`.
- Critical blocker: process memory grew by roughly `0.8 GB/sec`, making the
  game usable for only about `40-50 sec`.

Disposition: the perf lever is validated, but the candidate is not shippable and
not crown-ready until the leak is understood and fixed. Keep the launcher in
skip-enabled repro mode for now so the leak can be reproduced against the exact
runtime/env that produced the user observation.

Follow-up diagnostic staging:

- `live-targets/appgl-bridge/libappgl_bridge.dylib` now has opt-in diagnostics
  snapshots. When `APPGL_BRIDGE_DIAG_JSON_PATH=/path/file.jsonl` is set, the
  bridge writes `appglDiagnosticsJSON` payloads every
  `APPGL_BRIDGE_DIAG_FRAME_INTERVAL` frames, default `60` in the collector
  script. `APPGL_BRIDGE_DIAG_LIVE_ONLY=1` switches to the lightweight live
  diagnostics path, but memory triage should prefer full diagnostics.
- `live-targets/appgl-bridge/launch-warzone-appgl.sh` still defaults to
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`, but
  `APPGL_DISABLE_SAMPLER_GPU_ORDER_SKIP=1` now unsets the skip gate for
  same-runtime skip OFF A/B runs.
- `live-targets/appgl-bridge/diagnose-warzone-memory.sh` collects the Warzone
  RSS slope plus GL/CB profile rows and bridge diagnostics JSON. Supported
  modes: `skip-on`, `skip-off`, `skip-on-bound1`, `skip-off-bound1`.

## Next

1. Diagnose the live memory leak with a differential run: skip ON vs skip OFF,
   collecting process RSS, Metal allocation/inventory diagnostics, GL
   draw/token/CB profile rows, and the same runtime identity proof.
2. Fix or gate the leak source, then rerun the live memory soak before making a
   crown/checkpoint claim.
3. Crown `FAF1A9BA` or its leak-fixed successor as a checkpoint only after the
   leak is resolved; then continue down the S24 performance roadmap for the
   next lever.
4. Keep rung 2 deferred; EDB4C8AC showed `0` completed-token candidates.
5. Keep the CPU-shadow readback drain fix in the correctness bucket; it enables
   the DCR3-C gate but should not be conflated with sampler skip optimization.

## Dispatch Log

- 2026-06-08: GLTest ran the post-review AFA88A64 candidate under the live
  Warzone token-profile shape. The target mapped the expected AppGL dylib and
  emitted `2998` `[APPGL_CB_PROFILE]` rows, but emitted `0` draw/detail/token
  rows. Disposition: profiling dump-path miss, not producer-token
  quantification. AppGL restored the profile-run signal/atexit dump path and
  rebuilt a superseding local candidate:
  `build-release-fp64on/libAppGL.dylib`, UUID
  `EDB4C8AC-1682-3477-935B-DBD24DBC875B`, sha256
  `0e3708445bd0f13a8a563c5a35a880f4407769b08aa647d95e9349dfe8827fe5`.
  Local SIGTERM smoke proves draw/token profile rows flush before rerouting to
  GLTest. AppGL-Foreman dispatched the EDB4C8AC refire to GLTest-Foreman in
  bridge message `4c5a5878-52a2-4f8d-9a28-d09fd284d7a2`.
- 2026-06-08: AppGL-Foreman dispatched GLTest-Foreman in bridge thread
  `perf-step7-rung1-warzone-token-profile` to run the accepted live Warzone
  profile shape against local `build-release-fp64on/libAppGL.dylib` UUID
  `AFA88A64-ECDE-3B29-BF47-46E84F79F200`, sha256
  `e6bb1211f5208c4578ba55b3c4aee633b970996b88fb7b2f3d50b1347b7269ef`.
  Request: preserve existing draw/detail/CB profile outputs plus all new
  `[APPGL_GL_PRODUCER_TOKEN_PROFILE]` rows. This is candidate quantification
  only, not an A/B verdict and not a skip-behavior gate.
  This supersedes the earlier pre-review UUID
  `5D9DA83A-D795-3CB4-9723-FCEBD8A3CA23`.
- 2026-06-09: GLTest-Foreman completed EDB4C8AC refire in bridge message
  `29f3ee04-fc17-4c20-83c2-c238c88c66ab`. AppGL accepted it as authoritative
  rung 1 token quantification: `46` sampler pending hits, `46` same-queue
  candidates, `0` completed-token candidates, `0` unmodeled token hits.
- 2026-06-09: AppGL-Foreman implemented opt-in rung 3 candidate
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`; local build, BAR-B A/B smoke, and
  default/skip-enabled DCR3-C sentinel gates passed. Candidate UUID
  `486490E2-7892-33CF-ABD1-8F24B2A20623`, sha256
  `24a1f756b38f1c38fc06eebd66fb30cf9582fe3e23842cb3cd242512060e8473`.
- 2026-06-09: AppGL-Foreman dispatched gate requests:
  AppGL-Worker review `e76ba107-9f4c-48bc-ab28-0fe49bdb059b`,
  GLTest Gate 1 synthetic A/B `e8a24495-913e-4fc4-8b2b-42183ed0c754`,
  and Scout Gate 2 stale-pixel/conformance
  `c5a26626-d0df-43a0-8d13-c9e7b6888045`.
- 2026-06-09: AppGL-Worker review `cbcce8f1-4f39-47ea-abe1-40395b3e7b80`
  found the profile signal handler was not async-signal-safe and suggested a
  stricter token predicate. AppGL patched both issues and rebuilt review-fixed
  candidate UUID `F120F1C0-1A38-334D-AB1F-6829AEB229D0`, sha256
  `71396b001a7b30b1fa1c64a3269a88d596260ca62dc5529a7e1e61cc5408b918`.
- 2026-06-09: GLTest Gate 1 `440932e1-a748-4819-8d4f-e5182c6de047` and Scout
  Gate 2 `b65b71e5-6a87-4263-893e-6eaf3fa9634e` both passed on pre-review
  UUID `486490E2`; AppGL acknowledged them as strong evidence but is
  superseding formal gating to `F120F1C0`.
- 2026-06-09: AppGL-Foreman sent review-fix closeout to AppGL-Worker
  `36aa8268-ebeb-4a33-9780-b6985a1b7ceb`, GLTest Gate 1 supersede/confirmation
  request `56425fba-270a-4c54-a251-5d5363cac7c3`, and Scout Gate 2
  supersede/confirmation request `26a0eb63-132c-462a-ab4d-1c1fbe6686f0`.
- 2026-06-09: Scout formal Gate 2 confirmation
  `64adb0d0-9d1f-4026-a98e-7c4ab1786e99` passed on `F120F1C0` with focused
  `111/111` stale-pixel/conformance sweep and `P->F=0`.
- 2026-06-09: GLTest formal Gate 1 rerun
  `04764f9c-485d-4c65-a0b2-83b831b6bb12` passed on `F120F1C0` with median
  `perDrawUs` `54.122 -> 37.223` and `sampler_producer_drain`
  `41.733 -> 0.0065 us/draw`.
- 2026-06-09: AppGL-Foreman requested Gate 3 live Warzone re-profile with
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1` in bridge message
  `43802414-29ca-4b80-a773-962a61cfd165`.
- 2026-06-09: GLTest Gate 3 live profile
  `78791f2e-5f19-4e67-9de7-02605e91883d` completed on `F120F1C0`. Identity and
  profile rows passed, but behavior missed: `gpu_order_skips=0`,
  `gpu_order_skip_blocked=42`, and `sampler_producer_drain=21.525 us/draw`.
- 2026-06-09: AppGL-Foreman built follow-up token-merge candidate
  `FAF1A9BA-B6D6-3482-B1B5-7C55621C5AD4`, sha256
  `0395bf4e4dc44e62e7182d07938f2561ce5a64693a1cf696608cb0cc5b026ef3`.
  Local BAR-B A/B, skip-enabled SIGTERM profile dump, and default/skip
  `dcr3c-sentinels` are green. Next dispatch: AppGL-Worker review before
  rerouting GLTest Gate 1 and Scout Gate 2.
- 2026-06-09: AppGL-Worker review
  `d5823b53-1124-4421-84b5-837fd9d22fa5` completed green for `FAF1A9BA`;
  no blocking correctness findings. Non-blocking caveat: runtime env-toggle
  after pre-existing bit-only pending state is not formally supported, but
  process-start Gate 1/2 usage is green.
- 2026-06-09: AppGL-Foreman sent Worker ACK
  `818da7d5-c4d5-4eff-9c35-f86a1de9d9bc`, GLTest Gate 1 synthetic A/B request
  `53ab7b54-fda7-4f6f-867c-d713cf82741f`, and Scout Gate 2 focused
  stale-pixel/conformance request `919e0900-b99b-4864-81bb-d1875dffa331` for
  `FAF1A9BA`.
- 2026-06-09: Scout Gate 2
  `99fc9e61-8c45-46dd-85e0-351fef64e19f` passed for `FAF1A9BA`: focused
  `111/111` caselist plus `dcr3c-sentinels`, `P->F=0`, `P->nonPass=0`,
  `status_transitions=0`, and no stale-pixel/readback/alias/MSAA/
  texture-buffer fallback regressions. ACK sent
  `d6a19cde-a5c6-4d80-a329-404670e71818`.
- 2026-06-09: GLTest Gate 1
  `a8a7e811-84c5-418d-b051-a6af5d973250` passed for `FAF1A9BA`: median
  `perDrawUs` `56.637 -> 39.221` (`-30.75%`),
  `sampler_producer_drain` `44.7515 -> 0.0055 us/draw`,
  `gpu_order_skips` `0 -> 100`, `gpu_order_skip_blocked=0`, all new
  block-reason counters `0`, and readback identity preserved. ACK sent
  `f9f40cf6-db5b-4e38-ba31-0144f525d28a`.
- 2026-06-09: With Worker review, Gate 1, and Gate 2 green, AppGL-Foreman
  requested live Warzone Gate 3 rerun for `FAF1A9BA` in bridge message
  `26dd2809-b7ba-4f1d-93bf-fce1eed4a796`.
- 2026-06-09: GLTest Gate 3 live profile
  `66395c45-4501-4f25-95c0-38e579700228` passed profile row path and
  identity/runtime proof and achieved live sampler skip behavior on
  `FAF1A9BA`: `sampler_producer_drain=0.178 us/draw`,
  `gpu_order_skips=873`, `gpu_order_skip_blocked=0`, all new block-reason
  counters `0`, and draw `avg_us=18.630` versus F120 `39.247`.
- 2026-06-09: User manual live review after updating the launcher to the
  `FAF1A9BA` pinned runtime and enabling
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`: average FPS improved to around
  `17 FPS` from around `7 FPS`, CPU observed around `70-100%`, GPU around
  `30-40%`, but a critical memory leak appeared at roughly `0.8 GB/sec`.
  Usability window is only about `40-50 sec`. AppGL-Foreman downgraded the
  candidate from crown-ready to leak-blocked; next work is differential memory
  diagnosis and leak fix before checkpoint crown.

## Continuation Update - 2026-06-09 texture-shadow leak isolation

Leak investigation now has a concrete root cause:

- AppGL-Worker source review confirmed the leak pivot is retained texture host
  shadows, not the sampler skip itself.
- `GLTextureImageLevel` can retain both `rgba8` and `nativeData`, and
  `texStorage*` eagerly preallocates both for native-format textures.
- New diagnostics landed in `appglDiagnosticsJSON`:
  object-store texture/buffer inventory counters plus top-N
  `textureShadowHotspots` rows with GL name/format/flags/bytes.

Hotspot baseline run:

- Artifact root:
  `tests/reports/perf-step7-rung3-hotspot-diag-local/20260609T073111Z-skip-on/`
- Baseline `SUMMARY.txt`:
  `samples=46`, `first_rss_mib=742.250`, `last_rss_mib=1035.234`,
  `peak_rss_mib=1108.938`, `rss_delta_mib=292.984`,
  `slope_mib_per_min=206.898`.
- Frame-60 hotspot proof:
  - `hostCaches.textureShadowBytes=432800910`
  - `hostCaches.totalBytes=459257223`
  - `pressure.currentAllocatedBytes=865370112`
  - texture `5` (`GL_DEPTH_COMPONENT32F`, `2048x2048x3`) held
    `50331648` bytes of `rgba8` plus `50331648` bytes of `nativeData`
    while also carrying `producerPendingBits=130`,
    `wasFramebufferRenderedTo=1`, and `wasViewportRenderedTo=1`.
  - top R8 sampled textures (`GL_R8`, `GL_RED`, `GL_UNSIGNED_BYTE`) held
    `146450980` bytes of duplicated `rgba8` shadow in the top hotspot set.

Experimental lever history:

1. Broad env-gated drop proof:
   `APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1` initially dropped redundant
   `rgba8` on all native-path textures. It reduced frame-60
   `textureShadowBytes` by about `187.5 MiB` and improved the measured RSS
   slope to `138.163 MiB/min`, but it also stripped the depth array texture
   (`name=5`) before that texture was later marked as render-produced. That
   variant is useful as proof-of-cause only and is not checkpoint-safe.
2. Narrowed experimental lever:
   the drop gate now acts only on textures matching
   `GL_R8 + GL_RED + GL_UNSIGNED_BYTE`, while preserving the existing
   non-view/non-sparse/non-render-target/non-authoritative/non-pending guards.
   `texSubImage` now rehydrates a missing `rgba8` shadow for that exact R8
   shape from `nativeData` before applying a sub-image update.

Current experimental candidate:

- Source dylib:
  `build-release-fp64on/libAppGL.dylib`
- UUID: `1C0864FB-8F77-384C-95AF-420A86DE345D`
- Source sha256:
  `5bc0a50ed42a3874cfcdec79be64124bd8308d2f90313b84caa2b9521851f989`
- Live pinned dylib was refreshed to the same UUID and re-signed at:
  `live-targets/appgl-bridge/libAppGL-pinned.dylib`

Verification on the narrowed lever:

- `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j2`: passed.
- `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1 ./build-release-fp64on/appgl_gauntlet_cli dcr3c-sentinels`: passed.
- `DYLD_LIBRARY_PATH=./build-release-fp64on APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1 APPGL_GL_DRAW_PROFILE=1 ./build-release-fp64on/appgl_bar_b_benchmark`: passed.
  - BAR-B measured `perDrawUs=59.939445`.
  - Producer-token summary still showed `gpu_order_skips=104`,
    `gpu_order_skip_blocked=0`.

Current live soak on the narrowed lever:

- Artifact root:
  `tests/reports/perf-step7-rung3-r8-drop-local/20260609T075531Z-skip-on/`
- `SUMMARY.txt`:
  `samples=48`, `first_rss_mib=753.531`, `last_rss_mib=939.984`,
  `peak_rss_mib=1047.453`, `rss_delta_mib=186.453`,
  `slope_mib_per_min=106.822`.
- Frame-60 deltas versus the hotspot baseline:
  - `textureShadowBytes`: `432800910 -> 323093014`
    (`-109707896` bytes)
  - `hostCaches.totalBytes`: `459257223 -> 349568414`
    (`-109688809` bytes)
  - `pressure.currentAllocatedBytes`: `865370112 -> 821395456`
    (`-43974656` bytes)
  - top-hotspot R8 `rgba8` bytes:
    `146450980 -> 36350504` (`-110100476` bytes)
- Most important safety proof:
  texture `5` kept its full duplicated shadow at frame 60
  (`rgba8Bytes=50331648`, `nativeBytes=50331648`) and still reported
  `producerPendingBits=130`, `wasFramebufferRenderedTo=1`,
  `wasViewportRenderedTo=1`.
- Run exited cleanly; stderr still shows existing Warzone
  `map_Height` / `setReticuleStats` assertions, but no AppGL crash.

Disposition:

- Leak source is now materially narrowed to duplicated texture host shadows,
  especially R8 sampled texture mips plus the separate depth-array duplicate.
- The narrower R8-only experiment is the current best live lever: it preserves
  the depth hotspot while roughly halving the measured RSS slope in the current
  30 s soak (`206.898 -> 106.822 MiB/min`).
- This is still experimental and not checkpoint-ready. Remaining work is to
  either prove this shadow-drop path broadly correct or replace it with a more
  principled ownership model for texture host shadows.

Follow-up after AppGL-Worker review `1c9fa536-cfbb-4aca-a0ca-2f2e38b2e4fc`:

- Worker confirmed the narrowed gate is much safer, but flagged three
  correctness gaps for broader enablement:
  1. `generateMipmaps` still rejected a dropped R8 base level.
  2. `getTextureSubImage(..., GL_RGBA, GL_UNSIGNED_BYTE, ...)` still assumed
     `rgba8` existed and could return success with untouched output.
  3. Mixed-bpp `copyImageSubData` mismatch fallback still assumed `rgba8` at
     review time and needed the same R8 rehydrate path.
- Follow-up hardening first landed in local candidate UUID
  `6794FC2B-BF31-3EA4-BE33-CC39E642CF9C`, source sha256
  `386f79d4be4d4725e5c2affd057ea3ede0a499e52f1785aa2637052091fafb8d`, and
  then rolled forward to current source candidate UUID
  `71153768-044A-3B6C-AB0E-77ED809E6C8F`, source sha256
  `2f117b42ea8c1664fb6469dc29ed30a77c88a1f6cdb44ebbd765273f9361368c`:
  - shared `materializeRedR8TextureShadowFromNativeData(...)`
  - `generateMipmaps` now bootstraps from dropped R8 native data
  - `copyRGBA8TextureSubImageShadow` can expand dropped R8 native data
    directly for `getTextureSubImage` RGBA8 reads
  - `texSubImage` reuses the same helper for shadow rehydrate
  - mixed-bpp `copyImageSubData` mismatch fallback now rehydrates dropped R8
    native data on both source and destination paths before touching `rgba8`
- Validation after the hardening:
  - `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j2`: passed.
  - `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1 ./build-release-fp64on/appgl_gauntlet_cli dcr3c-sentinels`: passed.
  - `DYLD_LIBRARY_PATH=./build-release-fp64on APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1 ./build-release-fp64on/appgl_gauntlet_cli dcr3c.bar-copyimage-sparse-lifecycle`: passed.
  - `DYLD_LIBRARY_PATH=./build-release-fp64on APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1 APPGL_GL_DRAW_PROFILE=1 ./build-release-fp64on/appgl_bar_b_benchmark`: passed on the rolled-forward `71153768` source candidate with `perDrawUs=56.968611`.
- Hardened live soak artifact:
  `tests/reports/perf-step7-rung3-r8-drop-hardened-local/20260609T080719Z-skip-on/`
  - Frame-60 inventory stayed effectively identical to the prior R8-only run:
    `textureShadowBytes 323093014 -> 323092898`,
    `totalHostBytes 349568414 -> 349575346`,
    `currentAllocatedBytes 821395456 -> 806682624`.
  - Texture `5` still retained both copies and the same render-produced flags.
  - `SUMMARY.txt` RSS slope was noisier because the process started much lower
    (`first_rss_mib=525.844` vs `753.531`), so frame-60 diagnostic bytes are
    the more trustworthy comparison for this hardened rerun.
- Current blocker before broader enablement / repin:
  Scout has now returned focused correctness GREEN on source candidate
  `71153768` (644-case targeted gate including the full 324-case
  `KHR-GL46.copy_image.*` family, zero pass->fail transitions vs the selected
  baseline). The live pin has been advanced to the same UUID and re-signed as
  `6e2a9d70b9aba0ca1b6fda82a9b5fdba622b0d57170915209e77328e754b5a1c`.
  Checkpoint crown is still blocked by the remaining live leak, not by the
  R8/copy-image correctness gate.
- Follow-up investigation now points at the remaining depth-array duplicate
  (`texture 5`, `GL_DEPTH_COMPONENT32F`, `2048x2048x3`): after real GPU
  depth/stencil rendering, the framegraph path explicitly flips
  `depthStencilShadowAuthoritative = false` for texture attachments while
  leaving both `rgba8` and `nativeData` allocated. That means the next leak
  lever is likely not "rehydrate from trusted native shadow" like R8, but a
  more careful stale-shadow eviction / on-demand Metal-to-host rebuild path
  for render-produced depth textures.
- Diagnostic-only follow-up build UUID
  `63E203F6-9874-3C46-B680-FAC42086D94A`, source sha256
  `1c74067efea12f15ff3751160c5a1355bf659700a9b023e8c2a90f4dda57f1ff`,
  added `hostCaches.depth32fDropDryRun` counters, then was smoke-validated
  locally (`dcr3c-sentinels` passed, BAR-B passed with `perDrawUs=56.644410`).
  It was pinned only long enough to collect a local Warzone artifact and then
  the live pin was restored to the Scout-cleared `71153768` runtime.
- Depth32f dry-run artifact:
  `tests/reports/perf-step7-rung3-depth32f-dryrun-local/20260609T083047Z-skip-on/`
  reported the exact gating picture the audit predicted at frame 60:
  - `depth32fDropDryRun.candidateTextures=2`,
    `candidateRgba8Bytes=50331696`
  - `eligibleTextures=1`, `eligibleRgba8Bytes=48`
  - `blockedTextures=1`, `blockedRgba8Bytes=50331648`
  - blocker flags on the blocked texture were
    `flagRenderedRgba8Bytes=50331648` and
    `flagPendingRgba8Bytes=50331648`
  - the blocked texture was hotspot `5` itself, still showing
    `rgba8Bytes=50331648`, `nativeBytes=50331648`,
    `producerPendingBits=130`, `wasFramebufferRenderedTo=1`,
    `wasViewportRenderedTo=1`, `depthStencilShadowAuthoritative=0`
- Conclusion: a depth32f env gate implemented at the current conservative
  upload/drop point would free essentially nothing useful (`48` bytes of
  eligible rgba8 vs `50,331,648` bytes blocked on the real hotspot). The
  remaining memory win therefore requires a post-drain/post-render drop point
  or a depth-specific rendered-texture policy that preserves Metal/native
  authority while evicting stale host rgba8.
- Experimental follow-up local candidate UUID
  `9A500317-63B0-3241-9FDF-2E2CBDFCF42D`, source sha256
  `97710ee33372e3450ab226025f7b7c0917e8bdfa367ae6c2d4853e230a58ed98`,
  added an env-gated stale-depth32f path:
  `APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8=1`.
  The gate now:
  - drops `rgba8` only for the exact `GL_DEPTH_COMPONENT32F` attachment image
    whose GPU depth/stencil write just flipped
    `depthStencilShadowAuthoritative = false`
  - keeps the drop attachment-scoped instead of clearing every mip/level
  - teaches `copySimpleTextureLevelShadow(...)` and
    `getTextureSubImage(..., GL_RGBA, GL_UNSIGNED_BYTE, ...)` to rebuild the
    red-channel RGBA view safely from authoritative native depth data, with a
    Metal depth readback fallback for dropped non-authoritative sub-image
    reads
- Local validation on that candidate:
  - `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j2`: passed.
  - `DYLD_LIBRARY_PATH=./build-release-fp64on APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1 APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8=1 ./build-release-fp64on/appgl_gauntlet_cli dcr3c-sentinels`: passed.
  - `DYLD_LIBRARY_PATH=./build-release-fp64on APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1 APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8=1 APPGL_GL_DRAW_PROFILE=1 ./build-release-fp64on/appgl_bar_b_benchmark`: passed with `perDrawUs=55.561545`.
- Temporary local Warzone soak artifact:
  `tests/reports/perf-step7-rung3-depth32f-stale-drop-local/20260609T085655Z-skip-on/`
  - The temporary pinned dylib in that artifact was the same source candidate
    UUID `9A500317-63B0-3241-9FDF-2E2CBDFCF42D`, re-signed in the live-target
    slot as sha256
    `9b6c418228ddb776705e749545ee9fa1361113239d2d9c3a0289ac5f6c92a69d`.
  - `SUMMARY.txt` flipped from leak growth to relief over the 25-second run:
    `samples=44`, `first_rss_mib=745.688`, `last_rss_mib=672.391`,
    `peak_rss_mib=1039.797`, `rss_delta_mib=-73.297`,
    `slope_mib_per_min=-35.9892`.
  - Diagnostic frame comparison showed the intended change on hotspot `5`:
    - frame 1: `shadowBytes=100663296`, `rgba8Bytes=50331648`,
      `nativeBytes=50331648`, `producerPendingBits=0`
    - frame 60: `shadowBytes=50331648`, `rgba8Bytes=0`,
      `nativeBytes=50331648`, `producerPendingBits=130`,
      `wasFramebufferRenderedTo=1`, `wasViewportRenderedTo=1`,
      `depthStencilShadowAuthoritative=0`
  - That means the real `50,331,648`-byte stale `rgba8` duplicate on the
    depth-array hotspot was gone by frame 60 while the native depth shadow
    stayed resident.
  - `hostCaches.depth32fDropDryRun` confirmed the old blocker disappeared:
    frame 1 still saw `candidateTextures=2`,
    `candidateRgba8Bytes=50331696`; by frame 60 that fell to
    `candidateTextures=1`, `candidateRgba8Bytes=48`, with no blocked bytes
    left.
- After the soak the live pin was restored to the Scout-cleared
  `71153768-044A-3B6C-AB0E-77ED809E6C8F` runtime and re-verified at signed
  sha256 `6e2a9d70b9aba0ca1b6fda82a9b5fdba622b0d57170915209e77328e754b5a1c`.
- Immediate next work:
  1. get focused correctness review on the new env gate before any repin
  2. audit residual depth32f risk surfaces still called out by Worker
     (future proxy rebuilds, non-subimage readback consumers, and any
     depth-copy/mipmap paths that can still assume a persistent rgba8 shadow)

## Depth32F Correctness Closure

Worker and GLTest review on the first stale-depth32f leak candidate were
directionally right: once the env gate actually fired on immutable-storage
`GL_DEPTH_COMPONENT32F` textures, six real consumer-path gaps surfaced.

- Initial focused failures after the first leak-fix candidate:
  - `getTextureSubImage(..., GL_DEPTH_COMPONENT, GL_FLOAT, ...)`
  - array-layer `getTextureSubImage(..., GL_RGBA, GL_UNSIGNED_BYTE, ...)`
  - `glCopyImageSubData`
  - partial `glTextureSubImage2D`
  - `glGenerateMipmap`
  - post-drop depth swizzle/proxy sampling
- Root causes:
  - the first stale-drop shape check was too strict for `texStorage*`
    depth32f images because immutable-storage metadata still carried stale
    `sourceFormat/sourceType` values
  - the targeted consumers still assumed a persistent `rgba8` host shadow even
    after render-produced depth had deliberately lost
    `depthStencilShadowAuthoritative`
- Source hardening now in the local worktree:
  - relaxed depth32f stale-drop shape matching to key on
    `internalFormat == GL_DEPTH_COMPONENT32F`, float native bytes-per-pixel,
    and native-shadow sizing instead of stale source metadata
  - added a shared Metal-to-native depth32f sync path for non-authoritative
    texture levels before CPU-visible consumers touch them
  - patched depth32f consumer paths to use that authority refresh before
    `getTextureSubImage`, `copyImageSubData`, partial `texSubImage`,
    `generateMipmaps`, and depth swizzle/proxy rebuilds
  - added a dedicated `depth32f-stale-drop-probes` gauntlet phase in
    `tests/GauntletRunner.cpp`; the array-layer probe now seeds depth with a
    layered clear because the earlier layered draw seed proved unreliable
    (`0` readback on the target layer)

Current source build after a clean rebuild:

- UUID `D0F3A096-472D-3A18-8E6B-6E5DD1987504`
- sha256 `f82a95b2cda40429434da9c4b6f2f9789677d621b466bf08fa48d27fb45a9e27`
- Live user-facing pin is unchanged and still points to the Scout-cleared
  `71153768-044A-3B6C-AB0E-77ED809E6C8F` runtime at signed sha256
  `6e2a9d70b9aba0ca1b6fda82a9b5fdba622b0d57170915209e77328e754b5a1c`

Fresh local validation on the rebuilt source candidate:

- Artifact root:
  `tests/reports/perf-step7-rung3-depth32f-correctness-green-local/20260609T094204Z/`
- `./build-release-fp64on/appgl_gauntlet_cli depth32f-stale-drop-probes`:
  passed all six focused probes
  - `depth32f.stale-drop.subimage-depth-float`
  - `depth32f.stale-drop.array-rgba-subimage`
  - `depth32f.stale-drop.copyimage`
  - `depth32f.stale-drop.partial-texsubimage`
  - `depth32f.stale-drop.generate-mipmap`
  - `depth32f.stale-drop.swizzle-proxy`
- `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1 APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8=1 ./build-release-fp64on/appgl_gauntlet_cli dcr3c-sentinels`:
  passed
- `DYLD_LIBRARY_PATH=./build-release-fp64on APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1 APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8=1 ./build-release-fp64on/appgl_bar_b_benchmark`:
  passed with `perDrawUs=59.696953`

Disposition after the focused closure pass:

- The stale-depth32f leak lever is still a real checkpoint candidate.
- The focused correctness risks flagged by Worker/GLTest are now green locally
  on the current source build rather than only on the earlier `9A500317`
  leak-soak source state.
- The gate remains default-off. No repin and no crown yet.
- Remaining gating work before checkpoint claim:
  1. rerun the env-on Warzone soak/profile on the current rebuilt source
     candidate, not just the earlier `9A500317` soak artifact
  2. get broader external depth/copy-image scrutiny from GLTest/Scout around
     the new depth32f authority-refresh paths

## Temporary Live Staging - D0F3 Warzone Rerun

GLTest-Foreman requested a controlled live-target rerun on the rebuilt
correctness-fixed source candidate before any wider CTS/Scout ask.

- Date/time staged: `2026-06-09T09:47:59Z`
- Temporary live-target pin:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-pinned.dylib`
- Staged UUID: `D0F3A096-472D-3A18-8E6B-6E5DD1987504`
- Staged pinned sha256:
  `f82a95b2cda40429434da9c4b6f2f9789677d621b466bf08fa48d27fb45a9e27`
- Source sha256:
  `f82a95b2cda40429434da9c4b6f2f9789677d621b466bf08fa48d27fb45a9e27`
- Codesign delta: none (`pinned == source`)
- Install-name check: `@rpath/libAppGL.dylib`
- Codesign verify: valid / designated requirement satisfied

Restore safety:

- Pre-stage Scout-cleared backup captured at
  `$PROJECT_ROOT/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T094759Z-71153768-pre-D0F3A096-warzone-rerun.dylib`
- Previous user-facing live pin before staging:
  `71153768-044A-3B6C-AB0E-77ED809E6C8F`
  / sha256 `6e2a9d70b9aba0ca1b6fda82a9b5fdba622b0d57170915209e77328e754b5a1c`

Controlled rerun env trio communicated to GLTest:

- `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`
- `APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1`
- `APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8=1`

Boundary:

- This is not a crown or a new user-facing repin.
- It is a temporary test staging so GLTest can verify that the leak-relief
  behavior previously proven on `9A500317` still holds on the
  correctness-fixed `D0F3A096` build.
- Restore the user-facing live pin back to `71153768` immediately after the
  GLTest rerun unless GLTest explicitly asks to hold `D0F3A096` staged for an
  immediate follow-up.

Residual source-audit notes from AppGL-Worker after the focused-green pass:

- do not treat the focused local closure as a clean-none beyond the current
  probe set
- remaining concrete surfaces still outside the new probe coverage:
  1. partial `clearTexSubImage` destination preservation when
     `depthStencilShadowAuthoritative == false`
  2. destination-side partial preservation in depth32f `copyImageSubData`
  3. CPU sampled-texture snapshot path in `buildSampledTextureMap`
  4. target coverage gaps in `syncDepth32FTextureLevelNativeFromMetal` for
     `GL_TEXTURE_3D`, `GL_TEXTURE_CUBE_MAP`, and `GL_TEXTURE_CUBE_MAP_ARRAY`
- these do not supersede the current GLTest Warzone rerun gate, but they do
  block any “done/crowned” interpretation even if the current-candidate leak
  rerun comes back green

## GLTest D0F3 Warzone Rerun

GLTest-Foreman completed the controlled env-on Warzone reruns on the rebuilt
`D0F3A096` candidate and asked for immediate restore of the user-facing live
pin back to `71153768`.

Artifacts:

- Primary natural-exit artifact:
  `tests/reports/perf-step7-rung3-depth32f-D0F3-warzone-rerun/20260609T095205Z-skip-on/`
- Secondary 25-second exact-comparison timeout artifact:
  `tests/reports/perf-step7-rung3-depth32f-D0F3-warzone-rerun/20260609T095001Z-skip-on/`

Primary result (natural exit, treat as canonical):

- exit `0`
- `samples=44`
- `first_rss_mib=818.141`
- `last_rss_mib=892.953`
- `peak_rss_mib=1048.203`
- `rss_delta_mib=+74.812`
- `slope_mib_per_min=+62.3197`

Secondary result (harness SIGTERM, diagnostic only):

- exit `143`
- `first_rss_mib=524.156`
- `last_rss_mib=1043.250`
- `peak_rss_mib=1043.250`
- `rss_delta_mib=+519.094`
- `slope_mib_per_min=+339.713`

Direct comparison versus the earlier leak-relief proof:

- earlier `9A500317` local proof artifact:
  `tests/reports/perf-step7-rung3-depth32f-stale-drop-local/20260609T085655Z-skip-on/`
- earlier result:
  `first_rss_mib=745.688`, `last_rss_mib=672.391`,
  `peak_rss_mib=1039.797`, `rss_delta_mib=-73.297`,
  `slope_mib_per_min=-35.9892`, exit `0`
- current verdict: `D0F3A096` preserves the focused correctness fixes and the
  stale-depth32f drop still fires, but it does not preserve the earlier
  live-memory-relief headline on current-candidate Warzone

Important diagnostic nuance from GLTest:

- the intended stale-depth32f drop definitely still fires on hotspot texture
  `5`
- hotspot `5` at frame `1`: `rgba8Bytes=50331648`, `nativeBytes=50331648`
- hotspot `5` at frame `60`: `rgba8Bytes=0`, `nativeBytes=50331648`,
  `producerPendingBits=130`,
  `wasFramebufferRenderedTo=1`, `wasViewportRenderedTo=1`,
  `depthStencilShadowAuthoritative=0`
- so the regression is not “drop stopped working”; it is “current-candidate
  process RSS no longer improves the way the earlier proof build did”

Restore / live-target disposition after GLTest run:

- user-facing live pin restored immediately after the rerun
- current live pin UUID:
  `71153768-044A-3B6C-AB0E-77ED809E6C8F`
- current live pin signed sha256:
  `6e2a9d70b9aba0ca1b6fda82a9b5fdba622b0d57170915209e77328e754b5a1c`
- codesign verify passed after restore

Updated disposition:

- no crown / no repin on `D0F3A096`
- no checkpoint claim on the current correctness-fixed candidate
- next AppGL task is to explain the RSS regression between `9A500317` and
  `D0F3A096`, or produce a stronger current-candidate live memory-relief proof
  before wider external CTS/Scout gates are worth spending

## Diagnostic Staging - C26B7090 Readback Counters

AppGL-Worker's source review of the D0F3 regression identified the most
plausible next proof as diagnostics, not another behavior change: count
depth32f Metal readbacks/staging by consumer, and export a translated draw-plan
cache size estimate. Foreman implemented that as diagnostic-only candidate
`C26B7090`.

Candidate identity:

- source dylib: `build-release-fp64on/libAppGL.dylib`
- UUID: `C26B7090-A8B0-3D97-A7E0-D8CC9EB52FE0`
- sha256: `c7941d60dcd8345cb19b419ea98763061f515e7bac402722df7d0a54081b35b8`
- install-name: `@rpath/libAppGL.dylib`
- codesign verify: passed

New diagnostics exported in full `appglDiagnosticsJSON`:

- `depth32fReadback`: readback calls, D32F/D32FS8 call split, raw bytes,
  staging calls/bytes/max, consumer split for sync/RGBA8 subimage/attachment/
  other, native-sync calls/success/failure/bytes/slices, and RGBA8 subimage
  output/depth-value byte counters.
- `pipelineCache.liveEntries.translatedDrawPlanBuckets`
- `pipelineCache.liveEntries.translatedDrawPlanApproxBytes`

Local verification on `C26B7090`:

- build:
  `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j2`
  passed; only existing Metal deprecation and duplicate-library warnings.
- `./build-release-fp64on/appgl_gauntlet_cli depth32f-stale-drop-probes`:
  passed `6/6`.
- env trio
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`
  `APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1`
  `APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8=1`
  `./build-release-fp64on/appgl_gauntlet_cli dcr3c-sentinels`:
  passed `9/9`.
- same env trio BAR-B:
  `perDrawUs=57.169045`.
- diagnostics smoke artifact:
  `tests/reports/perf-step7-rung3-depth32f-readback-diag-C26B/diagnostics.json`
  proved `depth32fReadback` and the translated draw-plan estimate fields are
  present. Example smoke values from the focused probe:
  `readbackCalls=2`, `readbackDepth32FCalls=2`,
  `readbackStagingBytes=128`, `readbackConsumerSyncCalls=2`,
  `syncCalls=2`, `syncFailures=0`,
  `translatedDrawPlans=0`, `translatedDrawPlanBuckets=2`,
  `translatedDrawPlanApproxBytes=16`.
- live memory harness update:
  `live-targets/appgl-bridge/diagnose-warzone-memory.sh` now appends a
  `diagnostic_depth32f_summary` block to `SUMMARY.txt` when
  `appgl-diagnostics.jsonl` exists and `jq` is available; `bash -n` passed.

Temporary live staging used for GLTest rerun:

- live pin path:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-pinned.dylib`
- staged UUID at rerun time:
  `C26B7090-A8B0-3D97-A7E0-D8CC9EB52FE0`
- staged sha256 at rerun time:
  `c7941d60dcd8345cb19b419ea98763061f515e7bac402722df7d0a54081b35b8`
- staged install-name: `@rpath/libAppGL.dylib`
- staged codesign verify: passed
- pre-stage `71153768` backup:
  `$PROJECT_ROOT/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T101502Z-71153768-pre-C26B7090-depth32f-readback-diag.dylib`
- backup UUID:
  `71153768-044A-3B6C-AB0E-77ED809E6C8F`
- backup sha256:
  `6e2a9d70b9aba0ca1b6fda82a9b5fdba622b0d57170915209e77328e754b5a1c`
- final pin sanity check briefly found the live slot back on `71153768`;
  Foreman restaged `C26B7090` and captured a fresh current audit backup:
  `$PROJECT_ROOT/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T101922Z-71153768-pre-C26B7090-depth32f-readback-diag-restage.dylib`
  with the same `71153768` UUID and sha256

Bridge coordination:

- GLTest rerun request sent as bridge message
  `1fde8296-7a22-479a-b0f0-593270c9bd10` on thread
  `perf-step7-rung3-depth32f-readback-diag-C26B7090`.
- GLTest script-summary follow-up sent as bridge message
  `cae577bb-9283-430c-a02f-846be5e81dce`.
- GLTest restage correction sent as bridge message
  `d48d80ab-53fb-4c64-b0bf-329bcbbeacf4`.
- AppGL-Worker implementation proof sent as bridge message
  `5ba31c07-6753-4f69-a793-f2dfd6eb9dcd`.

Requested GLTest evidence:

- same 25-second Warzone skip-on harness plus post-drain sample
- RSS first/last/peak/delta/slope and exit status
- hotspot texture `5` frame comparison if available
- `depth32fReadback` values at comparable samples
- translated draw-plan live entries/approx bytes

Boundary:

- This is evidence-only. Do not crown or repin from `C26B7090`.
- Restore `71153768` after the GLTest diagnostic rerun unless there is an
  explicit follow-up reason to hold `C26B7090` staged.

## GLTest C26B Readback Diagnostic Rerun

GLTest-Foreman completed the C26B diagnostic Warzone rerun and confirmed the
artifact launch proof recorded `C26B7090`, so no duplicate rerun was needed
after the restage correction.

Artifact:

- `$PROJECT_ROOT/appgl-runtime/tests/reports/perf-step7-rung3-depth32f-readback-diag-C26B-warzone-rerun/20260609T101629Z-skip-on/`

Launch proof:

- UUID: `C26B7090-A8B0-3D97-A7E0-D8CC9EB52FE0`
- sha256: `c7941d60dcd8345cb19b419ea98763061f515e7bac402722df7d0a54081b35b8`
- exit code: `0`

RSS result:

- `samples=45`
- `first_rss_mib=581.375`
- `last_rss_mib=888.859`
- `peak_rss_mib=1046.359`
- `rss_delta_mib=+307.484`
- `slope_mib_per_min=+236.982`
- note: first sample was unusually low; slope from `>=2s` was
  `-69.686 MiB/min`
- important comparison: C26B still does not reproduce the earlier 9A500
  end-state relief (`C26B last=888.859 MiB` vs `9A500 last=672.391 MiB`)

Hotspot texture `5` still proves the stale-depth32f duplicate drops:

- frame `1`: `shadow=100663296`, `rgba8=50331648`, `native=50331648`,
  `metal=50724864`, `producerPendingBits=0`, rendered flags `0/0`,
  `depthStencilShadowAuthoritative=0`
- frame `60`: `shadow=50331648`, `rgba8=0`, `native=50331648`,
  `metal=50724864`, `producerPendingBits=130`, rendered flags `1/1`,
  `depthStencilShadowAuthoritative=0`

Depth32F readback diagnostics:

- Warzone frame `1` and frame `60` both reported zero for:
  `readbackCalls`, `readbackDepth32FCalls`, `readbackStagingBytes`,
  `readbackConsumerSyncCalls`, `syncCalls`, `syncNativeBytes`,
  `syncDepthValueBytes`, and `rgba8SubImageCalls`
- interpretation: current Warzone RSS behavior does not implicate depth32f
  readback/staging/native-sync/RGBA8-subimage paths

Translated draw-plan cache:

- frame `1`: `translatedDrawPlans=0`, `translatedDrawPlanBuckets=0`,
  `translatedDrawPlanApproxBytes=0`
- frame `60`: `translatedDrawPlans=439`, `translatedDrawPlanBuckets=3203`,
  `translatedDrawPlanApproxBytes=81816`
- interpretation: the cache grows, but the exported approximate plan bytes
  are only about `81.8 KiB`, too small by themselves to explain hundreds of MiB
  of RSS

Restore/race closure:

- GLTest first restored `71153768` from the original `101502Z` backup after
  the run.
- Foreman's final sanity check then saw `71153768` and restaged `C26B7090`,
  creating the `101922Z` restage backup.
- Because the completed artifact already proved C26B at launch, GLTest skipped
  duplicate Warzone work and restored again from:
  `$PROJECT_ROOT/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T101922Z-71153768-pre-C26B7090-depth32f-readback-diag-restage.dylib`
- final live pin UUID:
  `71153768-044A-3B6C-AB0E-77ED809E6C8F`
- final live pin sha256:
  `6e2a9d70b9aba0ca1b6fda82a9b5fdba622b0d57170915209e77328e754b5a1c`
- final install-name: `@rpath/libAppGL.dylib`
- final codesign verify: passed

Disposition:

- no crown
- no repin
- `C26B7090` is closed as useful negative evidence
- next AppGL-side work should move away from depth32f readback/staging and
  toward broader RSS explanations such as driver/allocator lifecycle,
  untracked Metal residency, or another retained/transient cache family

## Diagnostic Staging - C27 Process and Command Buffer Lifetime

C27 is diagnostics-only. It does not change rendering behavior, residency
policy, or the default Warzone perf/leak candidate. The goal is to explain why
9A500 showed an apparent late RSS relief while D0F3/C26B plateaued near
`~889-914 MiB`.

Source proof:

- UUID: `DB8D3D1F-0FD3-3BEA-A87B-14C1BDAC00E6`
- sha256:
  `a50ed84ad11bcc11f9c8984a29fd1c90e8da50c605a90969251312c00f0bb33b`
- install-name: `@rpath/libAppGL.dylib`
- codesign verify: passed

Added instrumentation:

- `metalResources.pressure.processResidentBytes`,
  `processPhysicalFootprintBytes`, and `processHeapBytes` are now populated
  from task/malloc APIs instead of staying zero.
- `metalResources.commandBuffers` now exports submitted/completed/current/peak
  command-buffer counters, plain vs autorelease-drained allocation split,
  retained command-buffer live/peak/released counts, and adopted transient
  object live/peak/released counters with conservative `allocatedSize` byte
  estimates when available.
- `live-targets/appgl-bridge/diagnose-warzone-memory.sh` now records tail
  process/vmmap snapshots at `18,21,23` seconds by default via
  `APPGL_WARZONE_MEMORY_TAIL_SAMPLES`, records the setting in `run-env.txt`,
  and appends `tail_vmmap_samples` to `SUMMARY.txt`.

Local verification:

- `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j2`
  passed.
- `./build-release-fp64on/appgl_gauntlet_cli depth32f-stale-drop-probes`:
  6/6 passed.
- Env trio
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1 APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8=1`
  with `./build-release-fp64on/appgl_gauntlet_cli dcr3c-sentinels`:
  9/9 passed.
- Env trio with
  `DYLD_LIBRARY_PATH=build-release-fp64on ./build-release-fp64on/appgl_bar_b_benchmark`:
  `58.742648 us/draw`.
- Diagnostics smoke artifact:
  `tests/reports/perf-step7-rung3-c27-process-cb-diagnostics-smoke/diagnostics.json`
  proved process fields and `metalResources.commandBuffers` are present.
  Example values: `processResidentBytes=74694656`,
  `processPhysicalFootprintBytes=76743328`, `processHeapBytes=31807552`,
  `submittedCommandBuffers=6`, `completedCommandBuffers=6`,
  `currentInFlight=0`, `retainedCommandBuffersPeakLive=1`,
  `retainedCommandBuffersReleased=6`.
- Harness `bash -n` passed.
- `git diff --check` passed for touched source and roadmap files.

Live staging proof:

- live pin:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-pinned.dylib`
- live UUID: `DB8D3D1F-0FD3-3BEA-A87B-14C1BDAC00E6`
- live sha256:
  `a50ed84ad11bcc11f9c8984a29fd1c90e8da50c605a90969251312c00f0bb33b`
- live install-name: `@rpath/libAppGL.dylib`
- live codesign verify: passed
- restore backup:
  `$PROJECT_ROOT/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T104141Z-71153768-pre-C27-process-cb-diagnostics.dylib`
- restore backup UUID: `71153768-044A-3B6C-AB0E-77ED809E6C8F`
- restore backup sha256:
  `6e2a9d70b9aba0ca1b6fda82a9b5fdba622b0d57170915209e77328e754b5a1c`
- clean process check: no Warzone/AppGL target process found after staging
- GLTest request:
  `41b972a2-715d-49ff-adf1-fbdad74f1e87`
- AppGL-Worker update:
  `f48d1679-2642-4c0d-964f-1396a61bfa6b`

Requested GLTest evidence after live staging:

- rerun Warzone `skip-on` with the updated harness and C27 pin
- compare `rss.csv` first/last/peak/delta/slope against C26B
- attach tail `vmmap-summary-at-18s.txt`, `21s`, and `23s` region summaries
- report `metalResources.pressure` process fields at first/last diagnostics
- report `metalResources.commandBuffers` first/last values, especially
  `currentInFlight`, `retainedObjectsLive`,
  `retainedObjectApproxBytesLive`, and `retainedCommandBuffersLive`
- interpretation target: if RSS changes while tracked AppGL resources and CB
  live counters stay flat/zero, treat 9A-style relief as teardown/driver/
  allocator sampling variance rather than a stable AppGL retained-resource fix

Boundary:

- no crown
- no repin
- restore the previous `71153768` live pin after the diagnostic run unless
  GLTest/AppGL agree to hold C27 for a follow-up A/B

C27 GLTest result:

- bridge result message:
  `8c7ee68e-f2b5-481a-bdc3-5f38aa513d75`
- primary artifact:
  `$PROJECT_ROOT/appgl-runtime/tests/reports/perf-step7-rung3-c27-process-cb-tail-diagnostics-warzone-rerun/20260609T104258Z-skip-on/`
- primary exit/RSS:
  `exit=143`, samples `49`, first `662.734 MiB`, last/peak
  `1047.375 MiB`, delta `+384.641 MiB`, slope `+256.107 MiB/min`
- primary tail process samples:
  `1027.188 / 1028.484 / 1030.547 MiB RSS` at `18s/21s/23s`
- primary tail `vmmap` samples:
  physical footprint `1.4G / 1.4G / 1.5G`, IOSurface
  `393.9M / 422.0M / 450.1M`, MALLOC zone allocated
  `441.5M / 445.0M / 465.1M`
- secondary natural-exit artifact:
  `$PROJECT_ROOT/appgl-runtime/tests/reports/perf-step7-rung3-c27-process-cb-tail-diagnostics-warzone-rerun/20260609T104456Z-skip-on/`
- secondary exit/RSS:
  `exit=0`, samples `45`, first `884.906 MiB`, last `891.500 MiB`,
  peak `1044.469 MiB`, delta `+6.594 MiB`, slope
  `+34.0528 MiB/min`
- primary diagnostics frame `1 -> 60`:
  `processResidentBytes 391315456 -> 1075609600`,
  `processPhysicalFootprintBytes 364102712 -> 1463142128`,
  `processHeapBytes 174800768 -> 462683904`,
  `trackedHostHeapBytes 150619880 -> 299087027`,
  `currentAllocatedBytes 187662336 -> 821133312`
- primary command-buffer diagnostics frame `1 -> 60`:
  `currentInFlight 1 -> 1`, `peakInFlight 1 -> 2`,
  `plainCommandBufferAllocations 3 -> 136`,
  `autoreleaseDrainedCommandBufferAllocations 0 -> 115`,
  `retainedObjectsLive 0 -> 0`,
  `retainedObjectsPeakLive 0 -> 0`,
  `retainedObjectApproxBytesLive 0 -> 0`,
  `retainedObjectApproxBytesPeakLive 0 -> 0`,
  `retainedCommandBuffersLive 1 -> 1`,
  `retainedCommandBuffersPeakLive 1 -> 2`
- depth32f readback/staging/sync counters stayed zero.
- translated draw-plan cache reached `981` plans / about `151192` bytes in
  the primary and `828` plans / about `131608` bytes in the natural-exit
  run, still far too small to explain the RSS movement.
- final live pin restored from:
  `$PROJECT_ROOT/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T104141Z-71153768-pre-C27-process-cb-diagnostics.dylib`
- AppGL-Foreman verified restored live pin:
  UUID `71153768-044A-3B6C-AB0E-77ED809E6C8F`, sha256
  `6e2a9d70b9aba0ca1b6fda82a9b5fdba622b0d57170915209e77328e754b5a1c`,
  install-name `@rpath/libAppGL.dylib`, codesign passed

Interpretation:

- no crown
- no repin
- C27 is useful negative evidence against command-buffer retained-object
  tails, depth32f readback/staging, and translated draw-plan bytes as the
  large leak source
- RSS is highly sensitive to pre/post teardown sampling; 9A-style late relief
  should be treated as driver/allocator/teardown-sensitive evidence rather
  than a stable retained-resource fix
- next work should inspect IOSurface growth, untracked Metal/device residency,
  process heap/MALLOC growth, and possible autorelease or frame-lifetime pools
  only as an A/B, not as the main proven source

## Local Staging - C28 Force Command-Buffer Autorelease Drain

C28 is a default-off separator, not a leak fix and not staged live. It adds
`APPGL_COMMAND_BUFFER_FORCE_DRAIN_AUTORELEASE=1` to force all
`MetalCommandSubmission::makeCommandBufferImpl` allocations through the
existing autorelease-drained branch. Existing `metalResources.commandBuffers`
plain/drained allocation counters prove whether the override is active.

Source proof after local build:

- UUID: `66B7D46B-118C-3E00-A695-0EAAB295CDF0`
- sha256:
  `c25c32d473b7663f854469ffd0ef9493fd526b71ad3733ca44fc67c75f3c528f`
- install-name: `@rpath/libAppGL.dylib`
- codesign verify: passed
- live pin remains restored to `71153768`; C28 was not copied into
  `live-targets/appgl-bridge/libAppGL-pinned.dylib`

Local gates:

- `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j2`
  passed, with only the existing `MTLResourceUsageSample` deprecation warnings.
- `./build-release-fp64on/appgl_gauntlet_cli depth32f-stale-drop-probes`:
  6/6 passed.
- Env trio
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1 APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8=1`
  with `./build-release-fp64on/appgl_gauntlet_cli dcr3c-sentinels`:
  9/9 passed.
- Env trio with
  `DYLD_LIBRARY_PATH=build-release-fp64on ./build-release-fp64on/appgl_bar_b_benchmark`:
  `56.081103 us/draw`.

Forced-drain smoke artifact:

- root:
  `tests/reports/perf-step7-rung3-c28-force-drain-smoke/`
- default diagnostics:
  `default-diagnostics.json` reported `submitted=6`, `completed=6`,
  `currentInFlight=0`, `peakInFlight=1`,
  `plainCommandBufferAllocations=6`,
  `autoreleaseDrainedCommandBufferAllocations=0`,
  `retainedObjectsLive=0`, `retainedObjectsPeakLive=0`
- forced diagnostics:
  `forced-diagnostics.json` reported `submitted=6`, `completed=6`,
  `currentInFlight=0`, `peakInFlight=1`,
  `plainCommandBufferAllocations=0`,
  `autoreleaseDrainedCommandBufferAllocations=6`,
  `retainedObjectsLive=0`, `retainedObjectsPeakLive=0`

Boundary:

- no crown
- no repin
- no live staging yet
- use C28 only as a quick A/B separator for command-buffer autorelease
  accumulation; C27's stronger evidence points the main leak search at
  IOSurface/process heap/untracked Metal residency

## Next Lane - C29 IOSurface / FrameGraph / Process Allocation Diagnostics

AppGL-Worker sanity check `0f4b4163-2ba3-48ce-bc6f-8ec7f8b5e8f6`
agreed that C28 is structurally fine/default-off but should not be the primary
lane. The stronger C27 signal is IOSurface / IOAccelerator / process malloc:

- C27 tail `vmmap` showed IOSurface growth roughly `42.3M -> 450.1M`,
  IOAccelerator graphics roughly `128.7M -> 334.4M`, and DefaultMallocZone
  allocated roughly `297.3M -> 464.9M`.
- AppGL's current frameGraph inventory reported texture bytes near
  `18.625 MiB` and `drawableTextureBytes=0` at diagnostic frames while
  `currentAllocatedBytes` rose to about `783-797 MiB` and process footprint
  reached about `1.39-1.5 GiB`.
- The likely observability gap is that inventory samples only the current
  drawable; present/clear paths nil `currentDrawable` after commit, so the
  CAMetalLayer/driver drawable IOSurface pool is mostly invisible.

C29 scope:

- add tail-time AppGL diagnostics aligned with harness `vmmap` samples
  (`18/21/23s`), not only frame `1/60`
- expand FrameGraph drawable/default-FBO diagnostics:
  acquired/presented/nil-after-present counters, current-drawable present flag,
  current drawable texture bytes/dims/pixelFormat/storageMode/usage, bounded
  unique raw drawable texture pointer count/peak/sum without retaining, and
  CAMetalLayer drawable settings where available
- break out depth/offscreen/default framebuffer texture lifecycle:
  depth/offscreen bytes/dims/sample count plus rebuild/replace/release counters
- add FrameGraph MTLTexture allocation event counters by source bucket before
  broadening to object-store texture creation
- expand process malloc diagnostics beyond default-zone bytes where feasible

Boundary:

- no crown
- no repin
- do not live-stage C29 until local gates and GLTest coordination are complete

## 2026-06-09 C29 local diagnostics gate

C29 is diagnostic-only and remains local. It expands full diagnostics for the
IOSurface/frameGraph/process-allocation leak lane and updates the Warzone
memory harness to capture tail-time AppGL diagnostics alongside `vmmap`
samples.

Source proof after local build:

- UUID: `3D704CB9-6654-3F2F-A487-37F14EBAAB97`
- sha256:
  `c3e4250c0b6a5b43fa3761e420c22897df2b0e33393d035cfe4b6b3071543405`
- install-name: `@rpath/libAppGL.dylib`
- codesign verify passed
- live pin remains restored to `71153768`; C29 was not copied into
  `live-targets/appgl-bridge/libAppGL-pinned.dylib`
- direct live-pin verification after the C29 gate:
  UUID `71153768-044A-3B6C-AB0E-77ED809E6C8F`, sha256
  `6e2a9d70b9aba0ca1b6fda82a9b5fdba622b0d57170915209e77328e754b5a1c`,
  install-name `@rpath/libAppGL.dylib`, codesign valid

New diagnostics exported in full `appglDiagnosticsJSON`:

- process malloc fields:
  `processHeapBlocksInUse`, `processHeapMaxBytesInUse`,
  `processHeapAllocatedBytes`
- frameGraph drawable counters and current drawable properties:
  acquire/hit/success/failure, present/nil-after-present, current drawable
  present flag, texture bytes/dimensions/pixel format/storage mode/usage, and
  bounded unique drawable texture observations
- CAMetalLayer surface settings where available
- default framebuffer depth/offscreen/dummy color lifecycle counters:
  bytes/dimensions/sample count/pixel format plus rebuild/release/allocation
  counters
- Warzone harness tail snapshots:
  `proofs/appgl-diagnostics-at-18s.json`,
  `proofs/appgl-diagnostics-at-21s.json`, and
  `proofs/appgl-diagnostics-at-23s.json` when diagnostics JSONL is present
- Warzone harness summary block:
  `diagnostic_framegraph_process_summary`, reporting first/last process
  resident, physical footprint, heap, heap allocation, device allocation,
  drawable, depth/offscreen, and dummy-color counters from diagnostics JSONL

Local gates:

- `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j2`
  passed, with only the existing `MTLResourceUsageSample` deprecation warnings.
- `./build-release-fp64on/appgl_gauntlet_cli depth32f-stale-drop-probes`:
  6/6 passed.
- Env trio
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1 APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8=1`
  with `./build-release-fp64on/appgl_gauntlet_cli dcr3c-sentinels`:
  9/9 passed.
- Env trio with
  `DYLD_LIBRARY_PATH=build-release-fp64on ./build-release-fp64on/appgl_bar_b_benchmark`:
  `58.340295 us/draw`.
- `bash -n` passed for
  `$PROJECT_ROOT/live-targets/appgl-bridge/diagnose-warzone-memory.sh`.
- The new `diagnostic_framegraph_process_summary` jq block was smoke-tested by
  wrapping the local C29 diagnostics artifact into the bridge JSONL shape; it
  emitted the expected process, device, drawable, depth/offscreen, and
  dummy-color first/last fields.
- `git diff --check` passed for the touched repo files.

Diagnostics smoke artifact:

- root:
  `tests/reports/perf-step7-rung3-c29-framegraph-process-diagnostics-smoke/`
- `gauntlet-output.json`: `depth32f-stale-drop-probes` passed `6/6`
- `diagnostics.json` proved new process/frameGraph fields are present. Example
  smoke values: `processResidentBytes=74809344`,
  `processPhysicalFootprintBytes=76841632`, `processHeapBytes=31812448`,
  `processHeapBlocksInUse=254673`, `processHeapAllocatedBytes=74235904`,
  `depthStencilTextureBytes=32768`, `depthStencilRebuilds=2`,
  `depthStencilReleases=1`, `offscreenColorTextureBytes=128`,
  `offscreenColorRebuilds=1`, `dummyColorTextureAllocations=1`.
  Headless drawable counters were present and zero, as expected without a
  CAMetalLayer-backed live swapchain.

Boundary:

- no crown
- no repin
- no live staging yet
- next action is coordinated GLTest live Warzone proof for C29 tail snapshots,
  not a behavior-change crown

Bridge coordination:

- AppGL-Worker local-gate update: `4d305df6-f27e-41bf-a4d2-a502f5295003`
- AppGL-Worker ACK: `1c35d0ff-2b6c-4af5-b054-a2821e68d186`
- GLTest-Foreman live-proof request:
  `751b2940-7cde-4fac-a8a2-4771c192ebd8`
- GLTest-Foreman harness-summary amendment:
  `d94b8886-b4a3-4eaa-904a-e0d59a3b689d`
- AppGL-Worker harness-summary update:
  `691b1f1b-0961-4f05-b6af-02659ea11cc6`
- AppGL-Worker harness-summary ACK:
  `db8c17d2-4486-439e-b5dc-bbb719798eb0`

## 2026-06-09 C29 live-tail diagnostics proof

GLTest-Foreman completed the coordinated live proof for C29 and restored the
live pin. This is still no-crown/no-repin.

Temporary live staging proof during the run:

- staged UUID: `3D704CB9-6654-3F2F-A487-37F14EBAAB97`
- staged sha256:
  `c3e4250c0b6a5b43fa3761e420c22897df2b0e33393d035cfe4b6b3071543405`
- install-name: `@rpath/libAppGL.dylib`
- codesign valid

Artifact:

- root:
  `tests/reports/perf-step7-rung3-c29-live-tail-diagnostics-warzone-rerun/20260609T111045Z-skip-on/`
- `SUMMARY.txt`: `diagnostic_json_rows=2`, `tail_vmmap_samples=4`,
  `tail_appgl_diagnostic_samples=3`, and
  `diagnostic_framegraph_process_summary` present
- tail AppGL diagnostics preserved:
  `proofs/appgl-diagnostics-at-18s.json`,
  `proofs/appgl-diagnostics-at-21s.json`,
  `proofs/appgl-diagnostics-at-23s.json`
- exit code: `143`

RSS:

- samples: `49`
- first/last/peak RSS MiB: `800.172 / 894.281 / 1047.250`
- delta: `+94.109 MiB`
- slope: `102.318 MiB/min`

Tail lanes from GLTest's vmmap/ps summary (`2s -> 23s`):

- ps RSS: `676.984 -> 1030.875 MiB`
- IOSurface: `42.3M -> 450.1M`
- IOAccelerator graphics: `211.6M -> 315.5M`
- DefaultMalloc allocated: `326.9M -> 446.0M`

C29 frameGraph/process diagnostics (`frame 1 -> frame 60`):

- `processResidentBytes`: `389824512 -> 1076690944`
- `processPhysicalFootprintBytes`: `362628176 -> 1444431624`
- `processHeapBytes`: `174823920 -> 465813088`
- `processHeapBlocksInUse`: `43752 -> 1107358`
- `processHeapAllocatedBytes`: `210878464 -> 517619712`
- `deviceAllocatedBytes`: `187662336 -> 821428224`
- `observedDrawableTextures`: `1 -> 26`
- `observedDrawableTextureBytes`: `14745600 -> 383385600`
- `currentDrawableTextureBytes`: stayed `0`
- `depthStencilTextureBytes`: stayed `19529728`
- `depthStencilRebuilds`: `2 -> 48`
- `offscreenColorTextureBytes/offscreenColorRebuilds`: stayed `0/0`
- `dummyColorTextureAllocations`: `0 -> 2154`
- tail AppGL diagnostics also reported
  `dummyColorTextureAllocatedBytes=36420452352` cumulative

Negative lanes:

- depth32f readback/staging/sync counters stayed `0`
- command-buffer retained object live/approx bytes stayed `0`
- `retainedCommandBuffersLive=1`, peak `2`
- translated draw-plan approx bytes were only `129560` at frame 60

Interpretation:

- C29 localizes the major tail lanes to IOSurface/drawable churn,
  process-heap/default-malloc growth, IOAccelerator residency, and
  depth/dummy-color rebuild churn.
- It does not support a live current-drawable retention leak or a command-buffer
  retained-object leak.
- `observedDrawableTextureBytes` and `dummyColorTextureAllocatedBytes` are churn
  and residency indicators, not direct live-owned totals.
- The next likely fix lane is to reduce default-framebuffer depth rebuilds and
  dummy color texture churn, then re-run the C29 summary to see whether
  IOSurface/device/process growth falls with it.

Restore proof after the run:

- GLTest restored from
  `live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T111020Z-71153768-pre-C29-live-tail-diagnostics.dylib`
- AppGL-Foreman direct post-run verification:
  UUID `71153768-044A-3B6C-AB0E-77ED809E6C8F`, sha256
  `6e2a9d70b9aba0ca1b6fda82a9b5fdba622b0d57170915209e77328e754b5a1c`,
  install-name `@rpath/libAppGL.dylib`, codesign valid
- exact-name process scan after verification found no
  `Warzone`, `ogltest`, `glcts`, or `appgl-cw-dd` processes

Bridge coordination:

- GLTest-Foreman completion:
  `fa067939-5923-4230-b6ef-91446d011984`

## 2026-06-09 C30 drawable/dummy-churn local gate

C30 is the first behavior-change candidate after C29. It is still local only:
no crown, no repin, and no live staging until GLTest completes a Warzone proof
and restores the known live pin.

Worker review signal:

- AppGL-Worker C30 review message:
  `28a009c3-e2ef-4a95-8876-5627c8ee46e2`
- Review disposition: fix depth/dummy churn, but the highest-confidence
  IOSurface target is drawable lifecycle/autorelease/recycling because C29 saw
  `observedDrawableTextures 1 -> 26` while the layer reported
  `layerMaximumDrawableCount=3`.

C30 source changes:

- `acquireDrawableIfNeeded()` now acquires `nextDrawable` inside a local
  `@autoreleasepool`, stores an owned drawable, and exports retain/release/live
  counters.
- `clearCurrentDrawable()` releases that owned drawable on transient-state
  invalidation and after commits/presents.
- translated FBO draws no longer call `ensureDrawableResources()` before the
  code knows whether the draw is targeting the default framebuffer.
- dummy color textures now use a small per-descriptor cache instead of allocating
  a fresh throwaway render-target texture for every attachmentless or
  depth/stencil-only pass.
- diagnostics now export drawable retain/release/live/peak counters plus dummy
  color cache hits/textures/bytes, and the Warzone harness summary includes
  those fields.

Source proof after local build:

- UUID: `9FAA8697-05EF-3760-977A-4145E2A4A4CA`
- sha256:
  `ac9a255b76bf61941a9dfe7adfd0172bb51f206a0ac08005702a0966ae71dd49`
- install-name: `@rpath/libAppGL.dylib`
- codesign verify passed

Local gates:

- `git diff --check` passed for the C30-touched source/doc files.
- `bash -n` passed for
  `$PROJECT_ROOT/live-targets/appgl-bridge/diagnose-warzone-memory.sh`.
- `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j2`
  passed, with only the known `MTLResourceUsageSample` deprecation warnings and
  duplicate-library linker warning.
- `s22-live-present-sentinel`: 2/2 passed.
- `depth32f-stale-drop-probes`: 6/6 passed.
- env trio
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1 APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1 APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8=1`
  with `dcr3c-sentinels`: 9/9 passed.
- env trio BAR-B with `DYLD_LIBRARY_PATH=build-release-fp64on`:
  `58.105208 us/draw`.

Fresh C30 smoke artifact:

- root:
  `tests/reports/perf-step7-rung3-c30-drawable-dummy-local-smoke/20260609T113422Z-post-autoreleasepool/`
- live-present diagnostics:
  drawable `acquire=4`, `success=4`, `present=2`, `nilAfterPresent=2`,
  `retain=4`, `release=4`, `live=0`, `peak=1`,
  `observedDrawableTextures=2`, `observedDrawableTextureBytes=65536`.
- depth32f diagnostics:
  dummy `allocations=1`, `allocatedBytes=128`, `cacheHits=0`,
  `cacheTextures=1`, `cacheBytes=128`; drawable retain/release/live all `0`;
  depth `rebuilds=2`, `releases=1`, `bytes=32768`.
- dcr3c diagnostics:
  `dummyColorTextureAllocations=0`, drawable retain/release/live all `0`;
  depth `rebuilds=2`, `releases=1`, `bytes=32768`.

Boundary and next gate:

- C30 has not been copied into
  `live-targets/appgl-bridge/libAppGL-pinned.dylib`.
- The next required proof is a GLTest Warzone memory harness run with more
  frequent AppGL diagnostics, preferably `APPGL_BRIDGE_DIAG_FRAME_INTERVAL=15`
  or lower, so the C29 first/last frameGraph summary has more than two rows.
- Live proof must report RSS slope, vmmap IOSurface/IOAccelerator/DefaultMalloc,
  drawable retain/release/live/peak, observed drawable textures/bytes, dummy
  allocations/cache hits/cache textures/cache bytes, depth rebuild/release
  counters, process heap, and device allocation.
- Restore the known live pin afterward and verify UUID
  `71153768-044A-3B6C-AB0E-77ED809E6C8F` before any crown discussion.

Bridge coordination:

- AppGL-Worker local-gate update:
  `ae942b08-f6a4-45c3-8102-4ad255fe5cba`
- AppGL-Worker ACK:
  `717d1e84-7015-49fc-9370-dcee6752957f`
- GLTest-Foreman C30 live-proof request:
  `d3ce9a3a-7dc2-4aad-bb30-fbabbf68e2f0`

## 2026-06-09 C30 live Warzone proof

GLTest-Foreman completed the coordinated C30 live proof and restored the live
pin. This is no-crown/no-repin: C30 fixed the drawable/dummy churn lane, but
RSS/process heap remains too high for a checkpoint.

Staging proof during the run:

- UUID: `9FAA8697-05EF-3760-977A-4145E2A4A4CA`
- sha256:
  `ac9a255b76bf61941a9dfe7adfd0172bb51f206a0ac08005702a0966ae71dd49`
- install-name: `@rpath/libAppGL.dylib`
- codesign valid

Artifacts:

- primary:
  `tests/reports/perf-step7-rung3-c30-warzone-live-proof/20260609T113858Z-skip-on/`
- short-tail comparator:
  `tests/reports/perf-step7-rung3-c30-warzone-live-proof-short-tail/20260609T114032Z-skip-on/`
- run env used the sampler/depth trio and
  `APPGL_BRIDGE_DIAG_FRAME_INTERVAL=15`
- the primary exited before the default `18/21/23s` tail samples, so GLTest
  used the short-tail run with `APPGL_WARZONE_MEMORY_TAIL_SAMPLES=2,5,8,11`
  for vmmap/ps comparison; it preserved `2/5/8s` tails before exit

RSS:

- C30 primary: exit `0`, samples `16`, first/last/peak
  `677.109 / 895.547 / 1038.641 MiB`, delta `+218.438 MiB`,
  slope `1084.19 MiB/min`, diagnostics rows `8`
- C30 short-tail: exit `0`, samples `18`, first/last/peak
  `800.797 / 897.688 / 1029.125 MiB`, delta `+96.891 MiB`,
  slope `137.68 MiB/min`, diagnostics rows `7`
- C29 comparator: first/last/peak `800.172 / 894.281 / 1047.250 MiB`,
  delta `+94.109 MiB`, slope `102.318 MiB/min`
- Interpretation: end-state RSS is not improved enough for crown/repin

Short-tail vmmap/ps:

- C30 `2s`: ps RSS `1017.422 MiB`, footprint `1.1G`,
  IOAccelerator graphics `317.1M`, IOSurface `28.2M`,
  DefaultMalloc allocated `441.0M`
- C30 `5s`: ps RSS `1024.406 MiB`, footprint `1.1G`,
  IOAccelerator graphics `317.0M`, IOSurface `14.2M`,
  DefaultMalloc allocated `442.8M`
- C30 `8s`: ps RSS `897.688 MiB`, footprint `934.6M`,
  IOAccelerator graphics `338.0M`, IOSurface `28.2M`,
  DefaultMalloc allocated `386.1M`
- C29 `23s` comparator: ps RSS `1030.875 MiB`, footprint `1.4G`,
  IOAccelerator graphics `315.5M`, IOSurface `450.1M`,
  DefaultMalloc allocated `446.0M`

C30 short-tail diagnostics (`frame 1 -> frame 90`) with C29 frame-60 reference:

- `processResidentBytes`: `391331840 -> 1077592064`
  (C29 `1076690944`)
- `processPhysicalFootprintBytes`: `364135480 -> 1192494712`
  (C29 `1444431624`)
- `processHeapBytes`: `174820208 -> 469926560`
  (C29 `465813088`)
- `processHeapBlocksInUse`: `43741 -> 1137188`
  (C29 `1107358`)
- `processHeapAllocatedBytes`: `215072768 -> 530219008`
  (C29 `517619712`)
- `deviceAllocatedBytes`: `187662336 -> 518225920`
  (C29 `821428224`)
- `observedDrawableTextures`: `1 -> 5` (C29 `26`)
- `observedDrawableTextureBytes`: `14745600 -> 73728000`
  (C29 `383385600`)
- `drawableRetainCalls/ReleaseCalls`: `1/1 -> 90/90`
- `drawableLiveRetains`: stayed `0`; `drawablePeakLiveRetains`: stayed `1`
- `currentDrawableTextureBytes`: stayed `0`
- `dummyColorTextureAllocations`: `0 -> 3` (C29 `2154`)
- `dummyColorTextureAllocatedBytes`: `0 -> 50724864`
  (C29 `36420452352` cumulative)
- `dummyColorTextureCacheHits`: `0 -> 5226`
- `dummyColorTextureCacheTextures`: `0 -> 3`
- `dummyColorTextureCacheBytes`: `0 -> 50724864`
- `depthStencilTextureBytes`: stayed `19529728`
- `depthStencilRebuilds`: `2 -> 114`
- `depthStencilReleases`: `1 -> 113`

Primary C30 final shape agreed at frame `105`:

- `observedDrawableTextures=6`
- `observedDrawableTextureBytes=88473600`
- `dummyColorTextureAllocations=3`
- `dummyColorTextureCacheHits=6501`
- `dummyColorTextureCacheTextures=3`
- `dummyColorTextureCacheBytes=50724864`

Negative lanes:

- depth32f readback/staging/sync counters stayed `0`
- command-buffer retained-object live/approx bytes stayed `0`
- `retainedCommandBuffersLive=1`, peak `2`
- translated draw-plan cache remained small relative to RSS:
  short-tail frame `90` `translatedDrawPlans=1857`, approx bytes `289064`;
  primary frame `105` `translatedDrawPlans=3982`, approx bytes `561064`

Interpretation:

- C30 is strong evidence that drawable/IOSurface and dummy-color churn fixes are
  working: observed drawable bytes drop about `81%` versus the C29 comparison,
  device allocated bytes drop by about `303 MiB`, drawable retain/release is
  balanced with zero live retains, and dummy-color churn drops from thousands of
  allocations to three cached textures.
- C30 is not a complete memory-crown result because process heap/default malloc
  and final RSS remain in the prior end-state band.
- Next lane should localize process heap/default-malloc growth, including the
  million-plus heap-block delta that remains after device/drawable churn falls.

Restore proof after the run:

- GLTest restored the live pin after both runs.
- AppGL-Foreman direct post-run verification:
  UUID `71153768-044A-3B6C-AB0E-77ED809E6C8F`, sha256
  `6e2a9d70b9aba0ca1b6fda82a9b5fdba622b0d57170915209e77328e754b5a1c`,
  install-name `@rpath/libAppGL.dylib`, codesign valid
- exact-name process scan found no
  `Warzone`, `ogltest`, `glcts`, or `appgl-cw-dd` processes

Bridge coordination:

- GLTest-Foreman completion:
  `0716feb8-d4ce-4db7-a5cc-5eb07015f858`
- AppGL-Worker C31 heap-lane review request:
  `bffb8abe-bd37-4fdb-855d-b46df68d5ce1`

## 2026-06-09 C31 heap/default-malloc diagnostics local gate

Current state: C31 is diagnostic-only, locally gated, and temporarily live
pinned for GLTest Warzone proof. It is not a crown and does not claim to fix
the remaining RSS/default-malloc leak.

Worker review and decision:

- AppGL-Worker C31 review response:
  `a57ed949-3e4c-4262-a6a9-1fdaf6c5334e`
- ACK from AppGL-Foreman:
  `a57ed949-3e4c-4262-a6a9-1fdaf6c5334e`
- Review signal: do not change texture-shadow retention yet. First add
  attribution for host texture shadows/mips/uploads, heap residuals, all malloc
  zones, and synchronized live diagnostics.

C31 source changes:

- `MetalMemoryPressureInputs` now exports
  `processHeapMinusTrackedHostCacheBytes`,
  `processHeapAllocatedMinusTrackedHostCacheBytes`, all-zone heap
  bytes/blocks/allocated/count, and non-default-zone bytes/blocks/allocated.
- `metalResourceInventory()` now samples `malloc_get_all_zones()` and exports
  top `mallocZones[]` rows with zone name, bytes, blocks, allocated bytes, and
  `isDefaultZone`.
- `MetalHostCacheSummary` now splits texture shadows by rgba8/native/capacity,
  primary/mip bytes/images/capacity, cube-face rgba8/native/capacity, and
  renderbuffer rgba8/native/depth32/stencil/capacity.
- `MetalFrameGraph` now exports resize calls/noops, resize-triggered default
  depth/offscreen releases, last requested/effective resize dimensions, and
  depth rebuild reason counters:
  `depthStencilRebuildsFromEnsure`,
  `depthStencilRebuildsFromColorSizeMismatch`, and
  `depthStencilRebuildsFromSampleMismatch`.
- The abandoned behavior-clamp counter was removed; C31 does not clamp or
  otherwise change drawable sizing behavior.
- `live-targets/appgl-bridge/diagnose-warzone-memory.sh` now appends the C31
  heap-zone, malloc-zone, host-cache, resize, and depth-reason first/last
  fields to `SUMMARY.txt`.

Source proof:

- built dylib:
  `build-release-fp64on/libAppGL.dylib`
- UUID `97178642-F715-306B-989F-0CB30D131052`
- sha256
  `59f5e498d95eb9e7cce39b62fa27283e7ffc1b659779b987206d075eddd00506`
- install-name `@rpath/libAppGL.dylib`
- codesign verify passed

Local gates:

- `git diff --check`: passed.
- `bash -n` passed for
  `$PROJECT_ROOT/live-targets/appgl-bridge/diagnose-warzone-memory.sh`.
- build passed:
  `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j2`
  with only the existing `MTLResourceUsageSample` deprecation warnings and
  duplicate-library linker warning.
- `s22-live-present-sentinel`: 2/2 passed.
- `depth32f-stale-drop-probes`: 6/6 passed.
- env trio `dcr3c-sentinels`: 9/9 passed.
- env trio BAR-B with `DYLD_LIBRARY_PATH=build-release-fp64on`:
  `58.724644 us/draw`.

Local artifact:

- root:
  `tests/reports/perf-step7-rung3-c31-heap-zone-local-gate/20260609T120344Z-diagnostics-only/`
- `s22-diagnostics.json` proves the new fields are present.
- Corrected default-zone proof:
  `mallocZones[0]=DefaultMallocZone`, `bytesInUse=35946592`,
  `blocksInUse=265775`, `isDefaultZone=1`.
- small-smoke heap proof:
  `processHeapBytes=35946592`,
  `processHeapAllocatedBytes=90439680`,
  `processHeapMinusTrackedHostCacheBytes=35939764`,
  `processHeapAllocatedMinusTrackedHostCacheBytes=90432852`,
  `processHeapAllZonesBytes=35989232`,
  `processHeapAllZonesBlocksInUse=266253`,
  `processHeapAllZonesCount=2`,
  `processHeapNonDefaultZoneBytes=42640`,
  `processHeapNonDefaultZoneBlocksInUse=478`.
- small-smoke frameGraph proof:
  `drawableResizeCalls=13`, `drawableResizeNoops=11`,
  `drawableResizeDepthTextureReleases=1`,
  `depthStencilRebuilds=2`, `depthStencilReleases=1`,
  `depthStencilRebuildsFromEnsure=2`,
  color-size/sample-mismatch rebuild reasons `0`.

Live pin state:

- `live-targets/appgl-bridge/libAppGL-pinned.dylib` has been refreshed to the
  C31 diagnostic candidate for GLTest live proof.
- direct pin verification:
  UUID `97178642-F715-306B-989F-0CB30D131052`, sha256
  `59f5e498d95eb9e7cce39b62fa27283e7ffc1b659779b987206d075eddd00506`,
  install-name `@rpath/libAppGL.dylib`, codesign valid.
- `launch-warzone-appgl.sh` still injects
  `libAppGL-pinned.dylib:libappgl_bridge.dylib`.
- exact-name process scan was clear for
  `Warzone`, `ogltest`, `glcts`, and `appgl-cw-dd`.

Next GLTest request:

- Run short-tail Warzone proof with:
  `APPGL_BRIDGE_DIAG_FRAME_INTERVAL=15`
  and `APPGL_WARZONE_MEMORY_TAIL_SAMPLES=2,5,8,11`.
- Required report: artifact path, RSS first/last/peak/slope, vmmap/ps
  DefaultMalloc/IOAccelerator/IOSurface/footprint/RSS, first/last AppGL
  diagnostics for `processHeap*`, `hostCaches.*`, `mallocZones`,
  `observedDrawable*`, `dummyColor*`, and `depthStencilRebuildsFrom*`, plus
  post-run exact-name process scan.
- If the process exits before 11s, preserve partial artifacts and do not rerun
  until inspected.

Bridge coordination:

- AppGL-Worker review/local-gate update:
  `11c531ed-8f77-4bcb-ae5d-c69c68869254`
- GLTest-Foreman live-proof request:
  `a752b20b-bb00-4451-9327-1383c65b7dc2`

Follow-up correction:

- GLTest completed the first C31 live artifact at
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T121202Z-skip-on/`,
  message `91f90b99-9f72-475f-93cd-d6a8c1163f5b`.
- AppGL-Worker review message
  `92d57fe9-589c-45ae-a5c5-f044f2271144` found two blockers:
  the run-env did not carry forward
  `APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1` or
  `APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8=1`, and the harness jq
  summary block silently failed at `mallocZone0Name`.
- Treat `20260609T121202Z-skip-on` as an accidental no-drop comparator, not the
  C30-comparable C31 proof. Its no-drop tail showed frame `1 -> 105` heap
  `174822672 -> 633034272`, host cache `150619880 -> 459397939`,
  texture shadow bytes `132186240 -> 432934138`, and residual
  `24202792 -> 173636333`.
- Harness fixes applied:
  default-on the two texture-shadow drop flags for this memory harness, fix
  jq empty-string fallbacks for `mallocZone0Name`, and add
  `appgl-diagnostics-at-<label>.meta.txt` tail sidecars with sample time,
  line count/mtime, and copied `bridgeFrame`.
- `bash -n` passes after the harness patch; a jq smoke against the no-drop
  JSONL printed `diagnostic_framegraph_rows=8`,
  `DefaultMallocZone`, host-cache totals, heap residuals, and
  `depthStencilRebuildsFromEnsure=140`.
- Corrected GLTest rerun request:
  `bdd74f81-cc43-47cb-8660-be208357b569`, with explicit sampler skip,
  both texture-shadow drop flags, `APPGL_BRIDGE_DIAG_FRAME_INTERVAL=15`,
  and `APPGL_WARZONE_MEMORY_TAIL_SAMPLES=2,5,8,11`.

Corrected C31 live proof:

- Artifact of record:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T121939Z-skip-on/`
- GLTest-Foreman completion:
  `82e86539-1909-4a96-ab7f-61dd6e15dbea`.
- Run env confirmed sampler GPU-order skip and both C30 texture-shadow drop
  flags:
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`,
  `APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8=1`,
  `APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8=1`,
  `APPGL_BRIDGE_DIAG_FRAME_INTERVAL=15`, and
  `APPGL_WARZONE_MEMORY_TAIL_SAMPLES=2,5,8,11`.
- Exit `0`, game-over duration `6`, RSS samples `19`,
  first/last/peak RSS MiB `849.172 / 670.703 / 1029.266`,
  delta `-178.469`, slope `-436.516 MiB/min`.
- Diagnostic rows `8`; tail vmmap samples `3`; tail AppGL diagnostic
  sidecars `3`.
- Tail vmmap showed IOAccelerator/IOSurface stable at roughly
  `318-337 MiB` / `28.2 MiB`. DefaultMalloc allocated was
  `440.4 MiB` at 2s, `442.1 MiB` at 5s, and `387.2 MiB` at 8s.
  The C30 8s comparator was DefaultMalloc allocated `386.1 MiB`,
  IOAccelerator `338.0 MiB`, and IOSurface `28.2 MiB`.
- Frame `1 -> 105` app diagnostics:
  `processResidentBytes 391233536 -> 1078558720`,
  `processPhysicalFootprintBytes 378766416 -> 1194722912`,
  `processHeapBytes 174823440 -> 470364128`,
  `processHeapAllocatedBytes 223461376 -> 530399232`,
  `trackedHostCacheBytes 150619880 -> 299254827`,
  `processHeapMinusTrackedHostCacheBytes 24203560 -> 171109301`,
  `processHeapAllocatedMinusTrackedHostCacheBytes 72841496 -> 231144405`,
  `processHeapAllZonesBytes 174875392 -> 470438896`,
  `processHeapAllZonesBlocksInUse 44481 -> 1140889`.
- `mallocZones[0]` stayed `DefaultMallocZone` with `isDefaultZone=1`;
  bytes/blocks/allocated went
  `174823440 / 43816 / 223461376 -> 470364128 / 1139898 / 530399232`.
- Host cache first/last:
  total `150619880 -> 299254827`,
  textureShadowBytes `132186240 -> 272764242`,
  textureShadowRgba8Bytes `81854544 -> 185819800`,
  textureShadowNativeBytes `50331696 -> 86944442`,
  textureShadowPrimaryBytes `132186240 -> 194317957`,
  textureShadowMipBytes `0 -> 78446285`,
  renderbufferShadowCapacityBytes stable at `18432000`.
- Drawable/depth counters:
  observed drawable textures `1 -> 5`,
  observed drawable bytes `14745600 -> 73728000`,
  dummy color cache bytes `0 -> 50724864`,
  drawable resize calls `4 -> 18631`,
  resize noops `2 -> 18489`,
  depth rebuilds/releases `2/1 -> 142/141`,
  `depthStencilRebuildsFromEnsure 2 -> 142`, while color-size and
  sample-mismatch rebuild reasons stayed `0`.
- Negative lanes stayed quiet: depth32f readback/staging/sync counters were
  zero, command-buffer retained live/approx bytes were zero, and translated
  plan bytes remained small at `737192`.

C31 interpretation:

- C31 is still diagnostic-only. It is not a crown and does not warrant a
  committed repin by itself.
- The corrected C31 proof narrows the remaining leak pressure away from
  IOAccelerator/IOSurface and non-default malloc zones. DefaultMalloc growth
  remains dominated by texture-shadow host accounting plus a residual
  DefaultMalloc lane.
- The biggest first-row-to-tail jump happened early, by frame 30:
  heap `174823440 -> 470630576`, residual
  `24203560 -> 146771289`, all-zone blocks
  `43816 -> 986602`, host cache `150619880 -> 323859287`,
  texture shadow `132186240 -> 302069873`, texture primary
  `132186240 -> 229980568`, and texture mip `0 -> 72089305`.
- Top live texture-shadow hotspots at the last row were array/mip-heavy
  textures, including texture `34` at `55924040` rgba8 bytes,
  texture `5` at `50331648` native depth bytes after stale depth drop,
  texture `35` at `27962010` split rgba8/native bytes, texture `31` at
  `27961920` rgba8 bytes, and texture `4` at `14745600` framebuffer bytes.
- Resume lane is C32 texture-shadow/mip retention and residual
  DefaultMalloc attribution. AppGL-Worker review request:
  `de5f60ee-fe8d-4f5f-89f1-2b21396efcff`.
- Live pin remains the C31 diagnostic runtime
  `97178642-F715-306B-989F-0CB30D131052`. No restore or promote has been
  requested.

## 2026-06-09 C32 accepted lane

Accepted Worker recommendation:

- AppGL-Worker C32 review:
  `e283675d-2856-4e3d-b31b-24942960d2e9`.
- AppGL-Foreman ACK:
  `d7460700-bb29-48a5-b6ae-98359b6a8de0`.
- C32 should be a default-off texture mip-shadow eviction/materialization rung,
  not a depth/dummy/resize lane and not broad primary-shadow eviction.

C32 target behavior:

- Add an env flag such as `APPGL_TEXTURE_SHADOW_DROP_MIP_LEVELS`, default off.
- Preserve `GLTextureImageLevel` metadata while releasing mip-level
  `rgba8`/`nativeData` shadows after the Metal texture has been successfully
  populated.
- Start with generated/immutable mip levels above the base level only.
- Block eviction for level 0, missing/uninstantiated Metal texture, pending
  producers, authoritative color/depth state, framebuffer/viewport-rendered
  state, texture views/source views, sparse textures, image-atomic textures,
  sampling proxies, and unsupported targets/formats unless a materialization
  path proves the case.
- Provide on-demand materialization for evicted mip shadows before broad use,
  especially for `glGetTextureImage`, `glGetTextureSubImage`,
  `copyImageSubData`, `texSubImage`/clear, and mipmap reuse.

Required C32 diagnostics and gates:

- Add cumulative and live saved-byte counters for mip-shadow eviction:
  calls/images/rgba8Bytes/nativeBytes/saved bytes.
- Add blocked-reason counters and materialization calls/bytes/failures split
  by consumer.
- Keep Warzone harness frame/host summary deltas for
  `textureShadowMipBytes` or saved mip bytes.
- Add focused probes for generated RGBA8 2D mips, 2D-array mips,
  native-format mips, `copyImageSubData` from an evicted mip source,
  `texSubImage`/clear into an evicted mip, texture-view sources starting at
  mip > 0 or explicit block proof, and PBO get paths if cheap.
- Existing gates still apply before live staging:
  `dcr3c-sentinels` with skip and both texture-shadow drop flags,
  `depth32f-stale-drop-probes`, BAR-B, and targeted CTS slices around
  `copy_image.*`, texture storage/mipmap, texture view, image query, and
  get texture subimage.

Success criteria:

- A clean C32 rung proves correctness and shows
  `hostCaches.textureShadowMipBytes` dropping or an equivalent saved-mip byte
  counter rising.
- Do not crown on mip-byte reduction alone. Crown only if residual
  DefaultMalloc and RSS also improve under live proof.

## 2026-06-09 C33 mip-shadow uploaded-drop lane

C33 implementation:

- Implemented texture mip-shadow eviction/materialization over the C32 design,
  with two runtime flags:
  `APPGL_TEXTURE_SHADOW_DROP_MIP_LEVELS` and
  `APPGL_TEXTURE_SHADOW_DROP_UPLOADED_MIP_LEVELS`.
- `GLTextureImageLevel` now preserves metadata while allowing eligible mip
  `rgba8`/native shadows to be released after Metal population. Uploaded,
  generated, and immutable mip levels are tracked separately.
- Materialization is fail-fast before destructive replacement paths and is
  wired into readback/edit/copy consumers: texture image/subimage reads,
  texture clears/subimage uploads, copy-image, mipmap reuse, and upload rebuild.
- Diagnostics now expose mip eviction enabled/uploaded-drop enabled, cumulative
  evicted bytes, live evicted bytes, materialization calls/bytes/failures,
  consumer splits, and block-reason counters.
- The Warzone launcher and memory harness default on the sampler skip, C30
  texture shadow drops, and the C33 mip-shadow drop flags for candidate runs.

C33 local gates:

- `git diff --check`: passed.
- `bash -n launch-warzone-appgl.sh diagnose-warzone-memory.sh`: passed.
- Build passed:
  `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j2`
  with only existing deprecation/duplicate-library warnings.
- Focused probes passed:
  `texture-shadow-mip-eviction-probes` 10/10,
  `depth32f-stale-drop-probes` 6/6,
  `dcr3c-sentinels` 9/9 with all candidate flags, and BAR-B around
  `59.6 us/draw`.
- GLTest targeted C32/C33 CTS proof message
  `0a7747c0-c3bd-49f6-8e23-cfd7aa9ed162`:
  `KHR-GL46.info.*` 6/6 passed, `copy_image.*` 324/324 passed,
  texture storage/view/mipmap bundle 9/10 with the known
  `texture_view.view_classes` failure, and get-texture-sub-image 1/2 with the
  known compressed-subimage stub gap.

C33 live proof:

- Generated/immutable-only C32 live artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T125211Z-skip-on/`.
  It proved the first implementation did not affect Warzone because the live
  mip growth was app-uploaded: RSS `737.047 -> 894.219 MiB`, slope
  `257.557 MiB/min`, `textureShadowMipBytes 0 -> 78446285`, and
  mip eviction bytes stayed `0`.
- C33 review-fix pin:
  UUID `66D1660B-D388-3980-B077-4CD5BB2563E1`, sha256
  `a19522333db285882196ce31754afc3e36b833aa4b775e5b19fac47767225e6d`.
- Profiles-on live artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T130405Z-skip-on/`.
  RSS `706.266 -> 809.047 MiB`, peak `970.156 MiB`, slope
  `307.857 MiB/min`; mip lane active with `textureShadowMipBytes 0`,
  evicted bytes `757115634`, live evicted bytes `78446285`,
  materialize calls `1231`, materialize bytes `678669349`, failures `0`.
- Profiles-off live artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T130516Z-skip-on/`.
  RSS `775.281 -> 806.984 MiB`, peak `967.422 MiB`, slope
  `116.436 MiB/min`; mip lane stayed active with the same clean
  materialization counters.
- C33 interpretation: mip host retention is fixed for the observed Warzone
  path, but the leak is not fixed. After frame 45, resident still rose about
  `10.64 MiB`, heap about `9.10 MiB`, while host/device caches were flat.
  C33 exposed depth/default-drawable resize churn as the next visible lever:
  drawable resize calls `19083`, depth releases `143`, and cumulative
  depth allocation about `2.91 GiB` while live depth was only about
  `19.5 MiB`.

## 2026-06-09 C34 default-drawable grow-only lane

Worker review and accepted direction:

- AppGL-Worker C34 review message
  `72ef5233-042c-4b23-9410-a7a14440c1cf` recommended a split API/policy
  approach, not a broad semantic change to exact `resizeDrawable`.
- Main risk called out: preserve default-framebuffer correctness when the CPU
  shadow remains larger than the current viewport, and cover draw paths that
  still made exact resize requests.

C34 implementation:

- Added `APPGL_DEFAULT_DRAWABLE_GROW_ONLY`, default-off in runtime but
  default-on in the Warzone launcher and memory harness. The launcher can
  disable it with `APPGL_DISABLE_DEFAULT_DRAWABLE_GROW_ONLY=1`.
- Added `MetalFrameGraph::ensureDrawableSizeAtLeast(...)`. Exact
  `resizeDrawable(...)` remains for init/offscreen/exact resize use.
- Grow-only skips preserve non-resource resize side effects when the requested
  drawable size changes: translated batch flush, headless readback clear,
  render-pass end, and transient-state invalidation.
- Default-framebuffer CPU shadow now grows and preserves contents under the
  grow-only policy; out-of-shadow reads fall back to Metal.
- Draw arrays/elements/base-vertex/immediate and viewport encode paths now use
  the grow-aware helper for the default drawable.
- Diagnostics now expose `drawableResizeGrowOnlySkips` and last requested vs
  effective drawable dimensions. The memory harness summarizes those fields.
- Added `default-drawable-grow-only-probes`, including full-size clear/read,
  small-viewport grow-only skip proof, depth-release stability, and readback
  outside the small viewport.

C34 local gates:

- `git diff --check`: passed before documentation edits.
- `bash -n launch-warzone-appgl.sh diagnose-warzone-memory.sh`: passed before
  documentation edits.
- Build passed after C34:
  `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli -j2`
  with only existing warnings.
- `default-drawable-grow-only-probes`: passed.
- With sampler skip, C30 drops, C33 mip drops, and C34 grow-only enabled:
  `texture-shadow-mip-eviction-probes` 10/10,
  `depth32f-stale-drop-probes` 6/6,
  `dcr3c-sentinels` 9/9, and BAR-B passed around `59.57 us/draw`.
- An initial DCR3C `viewport-restore-abandonment` failure was fixed by
  preserving flush/invalidate side effects on requested-size changes even when
  resource resize work is skipped.

Current live pin:

- `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-pinned.dylib`
  now points to the C34 refined build.
- UUID `25BF6A62-9C1A-3FA3-9A61-B4BF76554EF0`.
- sha256
  `02fce732922b2276a56ae99b43de0dea451f0cad0252547cef47fded8a951e9b`.
- install-name `@rpath/libAppGL.dylib`; codesign verification valid.
- Backup before this repin:
  `pin-backups/libAppGL-pinned-pre-c34-cap-20260609T132433Z.dylib`.

C34 live proof:

- Artifact of record:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T132445Z-skip-on/`.
- Run command shape:
  `APPGL_WARZONE_MEMORY_PROFILES=0 APPGL_BRIDGE_DIAG_FRAME_INTERVAL=15 APPGL_WARZONE_MEMORY_TAIL_SAMPLES=2,5,8,11 APPGL_WARZONE_MEMORY_DURATION=25 ./diagnose-warzone-memory.sh skip-on`.
- Profiles stayed off; RSS samples `18`, RSS `752.375 -> 810.391 MiB`,
  peak `964.125 MiB`, delta `58.016 MiB`, slope `181.093 MiB/min`.
- Frame `1 -> 105`:
  resident `391331840 -> 1010565120`, heap
  `174838864 -> 382852736`, host cache `150619880 -> 220804586`,
  device allocated `187662336 -> 537968640`, and texture mip bytes stayed `0`.
- C33 lane remained active and clean:
  evicted bytes `757115634`, live evicted bytes `78446285`,
  materialize calls `1231`, materialize bytes `678669349`, failures `0`.
- C34 stopped the depth churn:
  drawable resize calls/noops/grow-only-skips
  `4/2/2 -> 18848/18845/18845`, depth releases `1 -> 2`,
  depth rebuilds `2 -> 3`, and cumulative depth allocation
  `19,562,496 -> 46,301,184` rather than the prior multi-GiB churn.
- Residual issue remains:
  after frame 45, resident still rose about `10.22 MiB` and heap about
  `5.84 MiB` while host/device/depth allocation deltas were flat. The refined
  C34 build also still retained a transient effective drawable height of
  `2048` (`last requested 2560x1440`, `last effective 2560x2048`), leaving
  observed drawable bytes at `86179840` and live depth bytes at `26738688`.

C34 interpretation and C35 resume lane:

- Do not crown yet. C33 fixed the observed mip-shadow host retention and C34
  eliminated the depth allocation/release churn, but live RSS and
  DefaultMalloc still grow.
- The next lane is C35: attribute the post-frame-45 DefaultMalloc residual
  after host/device/depth caches flatten, with block-size/backtrace or
  allocator-site evidence if practical.
- Secondary C35 diagnostic: explain or cap the transient `2048` effective
  drawable height without regressing default-framebuffer readback, viewport,
  scissor, clip-control, or DCR3C behavior.

## 2026-06-09 C35-C39 leak residual and cache-cap lane

Current state:

- Do not crown yet. The catastrophic live leak is greatly reduced, but there is
  still measurable residual heap/RSS growth under Warzone autogame.
- Current live pin:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-pinned.dylib`.
- UUID `97A0C540-DFAC-3168-B72E-00A478F4219C`, sha256
  `6d01c11dc08643a2f39661f1d4f8ff16aff2aa227c21b589d78a6fd7db2135bb`.
- Backup before this pin:
  `pin-backups/libAppGL-pinned-pre-c39-render-pso-cap-20260609T143620Z.dylib`.
- `launch-warzone-appgl.sh` and `diagnose-warzone-memory.sh` now default to
  `APPGL_RENDER_PSO_CACHE_LIMIT_PER_PROGRAM=64` and
  `APPGL_TRANSLATED_DRAW_MSL_SLOT_CACHE_LIMIT=256`, while preserving the
  sampler-skip, texture-shadow-drop, mip-drop, stale-depth32f-drop, and
  default-drawable grow-only flags.

Implemented after C34:

- C35 retained current render encoders explicitly and added
  `frameGraph.renderEncoder*` diagnostics. Live counters proved the encoder
  path is balanced (`open == release`, live retain `0`, peak `1`).
- C36 converted hot `MTLSamplerDescriptor` / `MTLTextureDescriptor` alloc/init
  sites to scoped ownership. Stack probes showed `MTLSamplerDescriptorInternal`
  stopped growing.
- C37 wrapped remaining texture factory descriptor sites in tight
  autoreleasepools. Stack probes removed `MTLTextureDescriptorInternal` from
  the selected top residual rows.
- C38 owned the hot translated-draw `MTLVertexDescriptor` build object, but
  Worker review concluded the remaining `MTLVertex*DescriptorInternal` rows
  are retained by cached `AGXG13XFamilyRenderPipeline` objects, not a transient
  descriptor factory leak.
- C39 added opt-in cache caps:
  `APPGL_RENDER_PSO_CACHE_LIMIT_PER_PROGRAM` and
  `APPGL_TRANSLATED_DRAW_MSL_SLOT_CACHE_LIMIT`, with LRU-style use stamps,
  eviction counters in `pipelineCache.evictions`, and existing JSON
  `cacheLimits` fields wired.

Local gates for the current build:

- `git diff --check`: passed.
- Build passed:
  `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j 8`.
- With cache caps `renderPsoPerProgram=256`, `translatedDrawMSLSlots=256`:
  `default-drawable-grow-only-probes` 1/1,
  `depth32f-stale-drop-probes` 6/6,
  `texture-shadow-mip-eviction-probes` 10/10,
  `dcr3c-sentinels` 9/9, and BAR-B passed with
  `perDrawUs=59.061085`.

Live Warzone cap comparison:

- C37 baseline artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T142127Z-skip-on/`.
  Frame `45 -> 105`: heap all-zones
  `372,312,640 -> 381,105,584` (`+8.79 MiB`); render PSO and MSL-slot
  retained rows continued growing.
- C39 cap-256 artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T143628Z-skip-on/`.
  Slot cache capped (`live=256`, evictions `479` by frame 105), but render PSO
  evictions stayed `0` and live render PSOs still rose `255 -> 463`.
- C39 cap-64 artifact of record:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T143718Z-skip-on/`.
  Frame `45 -> 105`: heap all-zones
  `375,133,824 -> 376,698,000` (`+1.56 MiB`), resident
  `999,505,920 -> 1,005,699,072` (`+5.91 MiB`), render PSO evictions
  `150 -> 1181`, render PSO live `209 -> 402`, MSL slots flat at `256`.
  Summary RSS samples were `790.562 -> 803.375 MiB`, peak `967.547 MiB`,
  slope `23.0219 MiB/min`.
- C39 cap-32 artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T143818Z-skip-on/`.
  Lower PSO live count (`142 -> 247`) but much higher rebuild churn
  (`misses=4199` by frame 105) and worse frame `45 -> 105` heap growth
  (`+3.26 MiB`). Cap-64 is the better current launcher default.

Immediate next lane:

- Keep cap-64/slot-256 as the best live runtime for user replication.
- Ask Worker/GLTest to review C39 and avoid crowning until a longer manual run
  confirms stability.
- Next implementation should add render-PSO top-N-by-program diagnostics or a
  conservative global render-PSO cap. Per-program cap helps, but live
  `renderPso` still grows across multiple programs.

## 2026-06-09 C40-C41 render-PSO top-N and total-cap probe

Current state:

- Do not crown yet. C40/C41 reduce the remaining cache-growth lane to a small
  residual and give us better attribution, but manual soak is still required.
- Current live pin:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-pinned.dylib`.
- UUID `53FC202F-2C5E-3F82-9562-3E86DA4B4444`, sha256
  `83fb9ecd3e405754b347cfffc535ce5a3add593fa2cb0ebf2475585f7c36671b`.
- Backup before C41 hardening:
  `pin-backups/libAppGL-pinned-pre-c41-synthetic-owner-hardening-20260609T151551Z.dylib`.
- Backup before first C41 pin:
  `pin-backups/libAppGL-pinned-pre-c41-render-pso-total-20260609T150454Z.dylib`.
- Launcher and memory harness defaults remain cap-64/slot-256. C41 total
  render-PSO cap is opt-in only via
  `APPGL_RENDER_PSO_CACHE_LIMIT_TOTAL`.

C40 completed:

- Added top-N render-PSO-by-program diagnostics under
  `pipelineCache.topRenderPsoPrograms`, including live/high-water,
  hits/misses/evictions, last-use ranges, scalar mirror presence, GS
  pass-through parity fields, and source hashes.
- C40 live pin was UUID `4F63CC10-E2EA-3BF6-AFD4-72D36338D790`, sha256
  `28290c20dce49921c28fa2a5e21f28d23e0a24580105e27f3190869841cd30b1`.
- Artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T145529Z-skip-on/`.
- Frame `45 -> 105`: heap all-zones
  `376,045,824 -> 380,432,768` (`+4.18 MiB`), resident
  `1,009,008,640 -> 1,015,775,232` (`+6.45 MiB`), host cache
  `220,813,287 -> 221,000,126`, device allocated
  `538,050,560 -> 538,460,160`.
- Frame 120 top-N showed aggregate render PSO growth across programs:
  live total `436`, per-program evictions `1065`, MSL-slot evictions `917`.
  Hot rows: program `13` live64/high65 evict516, program `28`
  live64/high65 evict502, programs `31`/`34` also live64.
  GS pass-through rows were zero.

C41 completed:

- Added opt-in GLContext-side global render-PSO LRU cap:
  `APPGL_RENDER_PSO_CACHE_LIMIT_TOTAL`.
- Enforcement happens after successful translated-draw encoding; diagnostics
  remain observational.
- The helper enumerates regular and GS pass-through render PSO caches, uses
  the existing cross-program last-use stamps, releases evicted PSOs through the
  same ownership pattern, clears scalar mirrors when they point at the evicted
  object, and increments a separate global eviction counter.
- Hardened after review so the cap helper also scans synthetic tessellation
  program owners counted by inventory.
- Top-N rows now attribute global-cap evictions per owner with regular and GS
  pass-through counters.
- JSON additions:
  `pipelineCache.cacheLimits.renderPsoTotal`,
  `pipelineCache.evictions.renderPsoGlobal`,
  `pipelineCache.liveEntries.renderPsoTotal`, and
  `pipelineCache.highWater.renderPsoTotal`, plus top-N
  `renderPsoGlobalEvictions` and `gsPassThroughPsoGlobalEvictions`.

C41 local validation:

- `git diff --check`: passed.
- Build passed:
  `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j 8`.
- Under cap64/slot256/total384:
  `default-drawable-grow-only-probes` 1/1,
  `depth32f-stale-drop-probes` 6/6,
  `texture-shadow-mip-eviction-probes` 10/10,
  `dcr3c-sentinels` 9/9, and BAR-B passed with
  `perDrawUs=59.359774`.
- After synthetic-owner and attribution hardening, cap64/slot256/total360
  passed the same focused probes, `dcr3c-sentinels` 9/9, and BAR-B
  `perDrawUs=59.408837`.
- AppGL-Worker C41 hardening review (`cb0ff4fc-f376-4b96-9161-680f27ae0fa9`):
  verified synthetic owner enforcement, per-owner global eviction attribution,
  reset paths, and total320 attribution proof. Nuance: hardened total360
  validated the cap boundary but did not exercise eviction in that run; prior
  total360 exercised lightly with global evictions `39`.
- GLTest-Foreman hardened C41 ACK (`5df0421e-7128-43c5-918f-41bac33e73ba`):
  independently verified live pin UUID/SHA/install-name/codesign, prior-C41
  backup SHA, fresh exact-name process hygiene, total360 artifact metrics, and
  total320 attribution rows summing global evictions to `89`. GLTest tracker
  updated under the OGLTest repo.

C41 live probes:

- Total384 artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T150514Z-skip-on/`.
  The run ended at frame 105 before crossing the cap:
  renderPsoTotal `375`, global evictions `0`, heap frame `45 -> 105`
  `376,075,760 -> 379,977,920` (`+3.72 MiB`).
- Total320 artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T150602Z-skip-on/`.
  This proved the cap engages: frame 105 renderPsoTotal `320`,
  global evictions `123`. It is not a default candidate yet because heap rose
  to `394,099,696` by frame 105 and host/texture-shadow bytes were higher.
- Total360 artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T150646Z-skip-on/`.
  This is the best C41 candidate so far. Frame `45 -> 105`: heap all-zones
  `373,563,840 -> 377,957,680` (`+4.19 MiB`), resident
  `1,003,503,616 -> 1,010,302,976` (`+6.48 MiB`), host cache
  `220,808,603 -> 221,011,054`, device allocated
  `538,050,560 -> 538,394,624`. Frame 105 renderPsoTotal was clamped to
  `360`, high-water `361`, global evictions `39`, per-program evictions
  `1014`, MSL-slot evictions `586`.
- Hardened total360 artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T151611Z-skip-on/`.
  Frame 105 reached renderPsoTotal `360` with high-water `360` and global
  evictions `0`; resident `1,010,253,824`, heap all-zones `379,949,008`,
  host cache `221,017,562`, device allocated `538,394,624`.
- Hardened total320 artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T151648Z-skip-on/`.
  This proves per-program global-eviction attribution: frame 105
  renderPsoTotal `320`, high-water `321`, global evictions `89`.
  Example owners: program `34` global `23`, program `55` global `24`,
  program `31` global `12`, program `37` global `13`. Total320 remains a
  diagnostic ceiling, not a default candidate.

Immediate next lane:

- Keep launcher defaults unchanged: cap64/slot256, total cap off.
- Treat total360 as an opt-in candidate for a longer live/manual soak.
- Do not use total320 as a default candidate without deeper analysis.
- Next optimization lane after soak is either a shared render-PSO cache keyed
  by descriptor/source identity, or a lower-risk refinement to global-cap
  hysteresis/protected hot entries if cap360 shows rebuild churn in manual play.

Manual user soak, hardened C41 default launcher:

- User reported memory now holds steady: about 3 minutes at roughly `1.3 GB`,
  with a small load-time climb and then steady behavior.
- Reported performance: steady `20 FPS`, CPU around `90%`, GPU around `35%`.
- New watch item: Mach ports grew continuously during the 3-minute run and
  approached `30,000`. Treat as suspicious until instrumented.
- Added alternate launcher for opt-in total cap soak:
  `$PROJECT_ROOT/live-targets/appgl-bridge/launch-warzone-appgl-total360.sh`.
- AppGL-Worker Mach-port read (`2dc2624f-d38f-4143-bba9-eafec10c98f0`):
  memory result is encouraging but no crown while Mach ports climb. Recommended
  first `lsmp` snapshots where privileges allow, plus an in-process
  `mach_port_names` sampler if external ownership data is insufficient.
- GLTest-Foreman ACK (`ee7c1188-7482-4cfb-b567-21377fef0534`):
  verified the total360 wrapper and current hardened pin, then recommended a
  non-root `top` trend sampler with sparse `sudo lsmp` ownership snapshots,
  comparing hardened default vs total360.
- Harness update:
  `diagnose-warzone-memory.sh` now supports optional Mach-port sampling with
  `APPGL_WARZONE_MEMORY_MACH_PORTS=1`,
  `APPGL_WARZONE_MEMORY_MACH_PORT_INTERVAL`, and
  `APPGL_WARZONE_MEMORY_MACH_PORT_SAMPLES`. It writes
  `mach-ports-top.csv`, `mach_port_summary` in `SUMMARY.txt`, raw `top`
  snapshots, and best-effort `sudo -n lsmp` text/JSON snapshots.
- AppGL-Worker harness review (`2db37199-fca2-445b-afce-6e654ecf0c57`):
  continuous `top` CSV and sparse non-blocking `sudo -n lsmp` snapshots look
  correct. For the active port lane, run with duration `>=180s` because default
  harness duration is only `25s`; if `lsmp` ownership becomes central, add
  first/last right-class deltas from the per-snapshot summaries.
- GLTest-Foreman harness ACK (`45543357-14fb-4d11-8165-437a2fc7c7d8`):
  verified harness knobs, `bash -n`, `git diff --check`, total360 wrapper
  executability, hardened C41 pin, clean process scan, expected `top` row
  shape, and non-blocking `sudo -n lsmp` failure behavior. Recommendation
  matches Worker: duration `>=180s`, then add first/last right-class deltas if
  `lsmp` ownership becomes central.
- User follow-up 3-minute total360 manual run:
  CPU around `90%`, GPU around `30%`, `20 FPS`, memory around `1.37 GB` and
  holding steady. Mach-port behavior was the same as the default run.
  Read: total360 did not change the visible performance/memory/port shape in
  this short soak; Mach-port growth remains the gating issue before crown.
- AppGL-Worker total360 ACK (`da372c57-8346-4b48-a317-8330bd6f4b93`):
  agrees total360 is neutral versus hardened default in the short manual soak,
  launcher defaults should stay cap64/slot256 with total cap off, and the next
  highest-signal lane is controlled Mach-port harness A/B before choosing any
  fix path.
- GLTest-Foreman total360 ACK (`ec3a759c-52a3-4061-ac4e-a875e505e66d`):
  agrees the short total360 run matching hardened default points away from
  render-PSO total-cap pressure as the primary Mach-port cause in the 3-minute
  window. GLTest read: memory leak lane is checkpoint-candidate, but Mach-port
  growth remains the gate before crown/checkpoint.

Controlled harness Mach-port A/B:

- Initial autogame attempts were too short for this lane:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T162911Z-skip-on/`
  and
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T163008Z-skip-on/`.
  Both exited after only a few real seconds despite the second using a longer
  `--gametimelimit`, confirming the known autogame fast-forward caveat.
- Default non-autogame skirmish artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T163057Z-skip-on/`.
  Args: `--window --resolution=1280x720 --nosound --skirmish=highground.json --gametimelimit=1800`.
  Duration `210s`, harness exit `143`. RSS `409.031 -> 542.062 MiB`
  (`+133.031 MiB`, slope `34.9419 MiB/min`). Mach ports stayed flat:
  `370 -> 370`, slope `0`; messages/syscalls still grew:
  msgsent `4430 -> 53347`, msgrecv `4371 -> 141697`, sysmach
  `14144 -> 376971`.
- Total360 non-autogame skirmish artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T163459Z-skip-on/`.
  Same args plus `APPGL_RENDER_PSO_CACHE_LIMIT_TOTAL=360`.
  Duration `210s`, harness exit `143`. RSS `411.656 -> 545.422 MiB`
  (`+133.766 MiB`, slope `36.1852 MiB/min`). Mach ports again stayed flat:
  `370 -> 370`, slope `0`; msgsent `4428 -> 53357`, msgrecv
  `4406 -> 141761`, sysmach `14192 -> 376945`.
- In both long harness runs, `sudo -n lsmp` failed fast with
  `sudo: a password is required`, so ownership snapshots were not available.
- Read: the unattended non-autogame skirmish harness does not reproduce the
  user's manual Mach-port growth. The manual path remains the active port
  blocker; next capture should monitor the actual manual gameplay launch or add
  in-process `mach_port_names` counters.
- Added manual-path monitor:
  `$PROJECT_ROOT/live-targets/appgl-bridge/monitor-warzone-mach-ports.sh`.
  It waits for or accepts a Warzone PID, samples `top` ports/msgsent/msgrecv/
  sysmach/RSS into `mach-ports-top.csv`, writes `SUMMARY.txt`, and captures
  best-effort non-blocking `sudo -n lsmp` snapshots. Self-test against a shell
  PID passed with a valid CSV/summary. Suggested manual use after launching
  Warzone normally:
  `APPGL_WARZONE_MACH_PORT_DURATION=210 APPGL_WARZONE_MACH_PORT_INTERVAL=2 APPGL_WARZONE_MACH_PORT_SAMPLES=30,90,180 monitor-warzone-mach-ports.sh`.
- AppGL-Worker A/B review (`cc064c92-ce83-4d3f-8dd4-7df9a240bead`):
  agrees the unattended A/B is a Mach-port non-repro and total360 remains
  neutral. Next manual pass should be PID-aligned: either pass Activity
  Monitor's selected PID through `APPGL_WARZONE_MACH_PORT_PID=<pid>` or compare
  Activity Monitor's PID with `proofs/warzone.pid`, and record Activity Monitor
  Mach Ports near `30/90/180s` beside monitor CSV values. If Activity Monitor
  climbs but `mach-ports-top.csv` stays flat, treat as wrong-process,
  wrong-column, or observer-semantics issue. If both climb, classify right type
  next via `sudo -v` + `lsmp` or in-process `mach_port_names`. Worker caveat:
  unattended skirmish RSS rose about `133 MiB` over `210s`; keep memory
  checkpoint-candidate wording scoped to the manual hardened path that held
  steady until longer unattended RSS behavior is understood.
- GLTest-Foreman A/B ACK (`18789165-0bec-4189-bd29-d0aa3628e5fb`):
  independently verified the short autogame artifacts, long default/total360
  non-autogame artifacts, fast `sudo -n lsmp` failure, monitor executability,
  script syntax, `git diff --check`, clean process scan, and a local monitor
  self-test. GLTest read matches Worker: do not clear the blocker from harness
  non-repro alone; next capture must target the actual manual gameplay route
  that showed the climb.
- PID-aligned manual monitor artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/manual-mach-ports/20260609T174842Z/`.
  Target PID `35637`, monitor duration `210s`, target alive at monitor end.
  This confirms the manual Mach-port climb in the monitor CSV, not just
  Activity Monitor: ports `336 -> 29,813`, delta `29,477`, slope
  `8964.26 ports/min`. Snapshot points: start `336`, 30s `2,466`,
  90s `12,057`, 180s `25,525`, end `29,848` in raw top snapshot.
  Message/syscall counters also climbed: msgsent `24,631 -> 217,773`,
  msgrecv `41,270 -> 200,200`, sysmach `125,960 -> 442,525`.
  RSS from `ps` was `449.031 -> 1160.172 MiB`, peak `1240.375 MiB`;
  after the early load jump, 30s-to-end RSS was `1233.109 -> 1160.172 MiB`.
  `sudo -n lsmp` failed fast with `sudo: a password is required`, so ownership
  and right-class data are still missing. Next lane: rerun manual monitor after
  `sudo -v` for `lsmp` ownership snapshots, or add in-process
  `mach_port_names(mach_task_self())` counters.

C42 in-process Mach-port classifier:

- Added an opt-in, default-off process Mach-port classifier behind
  `APPGL_DIAG_MACH_PORTS=1`. The sampler uses
  `mach_port_names(mach_task_self())`, deallocates the returned name/type
  arrays with `vm_deallocate`, and exports counts only in full
  `appglDiagnosticsJSON` under `payload.metalResources.pressure`.
- Exported fields include enabled/available/kern-return/name-count/type-count,
  mismatch flag, send/receive/send-once/port-set/dead-name counts,
  DNREQUEST/SPREQUEST/SPREQUEST_DELAYED counts, guarded/immovable-receive
  counts where SDK macros exist, plus unknown type names/mask.
- Validation:
  `git diff --check` passed.
  `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j 8`
  passed with only the existing `MTLResourceUsageSample` deprecation warnings
  and duplicate-library linker warning.
- Focused smoke against `build-release-fp64on/libAppGL.dylib`:
  default env reported `processMachPortsEnabled=0`,
  `processMachPortsAvailable=0`, `processMachPortSampleKernReturn=0`, and all
  classifier counts `0`.
  With `APPGL_DIAG_MACH_PORTS=1`, the tiny offscreen context reported
  `enabled=1`, `available=1`, `kernReturn=0`, `names=53`, `typeNames=53`,
  `send=36`, `receive=21`, `deadName=0`, `DNREQUEST=1`, `SPREQUEST=1`,
  `SPREQUEST_DELAYED=1`, `unknownTypeNames=0`, `unknownTypeMask=0`.
  `appglLiveDiagnosticsJSON` emitted no `processMachPort*` keys.
- Live pin rotated after a clean process/lsof check:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-pinned.dylib`.
  Current live UUID `DCC4AD4B-CA56-352D-92E3-B4C228A5E7CE`, signed SHA256
  `855e7b935d97e96c96524f016bf89e22eca4ae6cacd24c1fa875ea83b2eecc1a`,
  install-name `@rpath/libAppGL.dylib`, codesign valid.
  Pre-C42 backup:
  `$PROJECT_ROOT/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-pre-c42-mach-port-classifier-20260609T180509Z.dylib`,
  UUID `53FC202F-2C5E-3F82-9562-3E86DA4B4444`, SHA256
  `83fb9ecd3e405754b347cfffc535ce5a3add593fa2cb0ebf2475585f7c36671b`.
- Canonical launcher remains unchanged at cap64/slot256 with total cap off:
  `APPGL_RENDER_PSO_CACHE_LIMIT_PER_PROGRAM=64`,
  `APPGL_TRANSLATED_DRAW_MSL_SLOT_CACHE_LIMIT=256`.
  Added classifier helper launcher:
  `$PROJECT_ROOT/live-targets/appgl-bridge/launch-warzone-appgl-machports.sh`.
  It sets `APPGL_DIAG_MACH_PORTS=1`, ensures a full diagnostics JSON path,
  unsets `APPGL_BRIDGE_DIAG_LIVE_ONLY`, records `launch-env.txt`, and then
  execs the canonical launcher. `sh -n` passed and the script is executable.
- Controlled live Warzone bridge proof:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/20260609T180852Z-skip-on/`.
  Env included `APPGL_DIAG_MACH_PORTS=1`,
  `APPGL_BRIDGE_DIAG_FRAME_INTERVAL=30`, cap64/slot256 defaults, and C42 live
  UUID/SHA above. The 60s harness wrote `221` full diagnostics rows and `12`
  external Mach-port samples. External `top` stayed flat
  `371 -> 355` ports; in-process classifier tracked the same endpoint:
  frame `1` `processMachPortNames=209`, send `137`, receive `103`,
  port-set `14`, dead `0`; frame `6600` `processMachPortNames=355`,
  send `263`, receive `141`, port-set `19`, dead `0`. Process scan was clean
  after harness exit. This remains a non-repro path for the manual port climb,
  but proves the classifier is active and aligned with `top` in live Warzone.
- GLTest-Foreman C42 ACK (`428d7b33-83cf-482c-a351-34f92e0dd013`):
  independently verified C42 live pin UUID/SHA/install-name/codesign, pre-C42
  backup identity, helper launcher syntax/executability/env behavior, canonical
  launcher defaults, clean process scan, default-off implementation shape,
  `vm_deallocate` cleanup, full-diagnostics-only serialization, and clean
  `git diff --check`. GLTest reports no correctness blocker for C42 as a
  diagnostic proof lane, but keeps the no-crown gate until manual proof
  correlates external `top` ports with in-process `processMachPortNames` and
  identifies the growing right class.
- AppGL-Worker C42 ACK (`37e8fcf8-10c9-4ccb-bd94-3e29676b2ebb`):
  verified the same live pin/setup, full-diagnostics-only emission, helper
  launcher behavior, and canonical defaults. Worker also ran an independent
  diagnostic-write smoke: default full diagnostics showed Mach-port fields off
  and zero; with `APPGL_DIAG_MACH_PORTS=1`, full diagnostics reported
  `names=90`, `typeNames=90`, send `57`, receive `37`, dead `0`, unknown `0`;
  live diagnostics had no `processMachPort` hits. Worker notes that frame 1
  can precede the first useful external `top` sample, so the manual proof
  should compare 30/90/180/end deltas and classify by slopes, not absolute
  right-count sums.
- Added analyzer:
  `$PROJECT_ROOT/live-targets/appgl-bridge/analyze-mach-port-classifier.sh`.
  It accepts a run directory, finds `appgl-diagnostics.jsonl` and
  `mach-ports-top.csv`, writes `mach-port-classifier-diag.csv` and
  `mach-port-classifier-summary.txt`, reports external/diagnostic endpoint
  alignment, per-right first/last/delta, per-right least-squares slopes, and
  largest positive right-class delta/slope. Optional warm-up cutoff:
  `APPGL_MACH_PORT_CLASSIFIER_MIN_FRAME=<frame>`. `sh -n` passed and the
  script is executable. On the controlled `20260609T180852Z-skip-on` artifact,
  endpoint alignment was exact: diagnostic `355` minus external `355` = `0`.
- Added exact-PID proof wrapper:
  `$PROJECT_ROOT/live-targets/appgl-bridge/run-warzone-appgl-machport-proof.sh`.
  It creates a shared run directory, launches
  `launch-warzone-appgl-machports.sh` in the background, captures the resulting
  exec-preserved Warzone/AppGL PID, runs `monitor-warzone-mach-ports.sh` with
  `APPGL_WARZONE_MACH_PORT_PID=<captured-pid>`, then runs the classifier
  analyzer on the same artifact root. `sh -n` passed and the script is
  executable. By default it leaves the game running after the monitor finishes;
  set `APPGL_WARZONE_MACH_PORT_STOP_AFTER_MONITOR=1` to terminate after the
  monitor window.
- AppGL-Worker tooling ACK (`381f1c65-15fd-4b3a-b66f-febc1c82088f`):
  reviewed the analyzer and exact-PID wrapper; both are executable and
  `sh -n` clean. Worker confirmed the wrapper addresses the PID caveat because
  helper, canonical launcher, and Warzone all `exec`, so the background PID is
  preserved through to the Warzone/AppGL process and is passed to the monitor
  as `APPGL_WARZONE_MACH_PORT_PID=<captured-pid>`. Worker reproduced exact
  endpoint alignment on `20260609T180852Z-skip-on`: external last ports `355`,
  diagnostic last `processMachPortNames=355`, delta `0`. Recommended manual
  analysis: run the analyzer once over the full span, and again with
  `APPGL_MACH_PORT_CLASSIFIER_MIN_FRAME` set near the first stable 30s
  diagnostic row if startup rows are noisy. For unattended proof runs, set
  `APPGL_WARZONE_MACH_PORT_STOP_AFTER_MONITOR=1`.
- GLTest-Foreman tooling ACK (`300bcbbb-4f71-4f90-b224-b8ddb74d4111`):
  independently verified the analyzer and exact-PID wrapper exist, are
  executable, and are `sh -n` clean. GLTest confirmed the PID-preservation
  assumption for the launcher chain because `launch-warzone-appgl-machports.sh`
  execs the canonical launcher, and the canonical launcher execs Warzone.
  GLTest also reran the analyzer on `20260609T180852Z-skip-on`: endpoint
  alignment remained exact (`processMachPortNames=355` and external ports
  `355`), external ports were `371 -> 355`, and with
  `APPGL_MACH_PORT_CLASSIFIER_MIN_FRAME=3000` the post-warm-up deltas were
  names `358 -> 355`, send `265 -> 263`, receive `143 -> 141`, with no
  largest positive right-class delta/slope. GLTest agrees the next manual proof
  should use the one-terminal wrapper and then classify using 30/90/180/end or
  warm-up-filtered deltas/slopes.
- Next manual proof:
  preferred one-terminal path is
  `run-warzone-appgl-machport-proof.sh --window --resolution=1280x720`.
  Compare external `top` ports with full diagnostics JSON rows:
  `jq -r 'select(.kind=="full") | [.bridgeFrame,.payload.metalResources.pressure.processMachPortNames,.payload.metalResources.pressure.processMachPortSendNames,.payload.metalResources.pressure.processMachPortReceiveNames,.payload.metalResources.pressure.processMachPortDeadNameNames,.payload.metalResources.pressure.processMachPortSendOnceNames] | @csv' appgl-diagnostics.jsonl`.
  If `processMachPortNames` tracks external `ports`, classify the growing
  right class from the send/receive/send-once/dead-name slopes.

C42 manual proof result:

- User ran the exact-PID wrapper for about 3 minutes. Artifact root:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess/20260609T182153Z/`.
  External monitor artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess/20260609T182153Z/external/20260609T182158Z/`.
  PID was `42071`. `launch-env.txt` confirms `APPGL_DIAG_MACH_PORTS=1`,
  full diagnostics JSON path, and `APPGL_BRIDGE_DIAG_FRAME_INTERVAL=60`.
  Process scan was clear after analysis.
- Manual path reproduced the Mach-port climb in exact-PID telemetry:
  external `top` ports `338 -> 29,338`, peak `29,338`, delta `29,000`,
  slope `8648.18 ports/min`. Message/syscall counters also climbed:
  msgsent `6,650 -> 238,874`, msgrecv `4,213 -> 157,864`, sysmach
  `17,862 -> 368,420`. RSS by `ps` was `624.203 -> 1158.828 MiB`,
  peak `1213.062 MiB`; this is a much slower RSS trend than the original
  catastrophic leak but still not flat in this 210s proof.
- `sudo -n lsmp` snapshots still failed fast with `sudo: a password is
  required`, so in-process `mach_port_names` remains the classification source.
- Diagnostics JSON had one malformed/interrupted JSONL row, but `84` valid full
  diagnostics rows were salvageable. Hardened
  `analyze-mach-port-classifier.sh` to parse JSONL line-by-line with
  `fromjson?`, so one bad row no longer blocks classification. `sh -n` passed.
- Full-span classifier summary:
  diagnostic names `203 -> 29,877` (`+29,674`), typeNames matched names,
  mismatch `0`, kernReturn `0`.
  Send rights `132 -> 29,768` (`+29,636`) and were the largest positive
  delta/slope. Receive rights only `99 -> 166` (`+67`), send-once `0 -> 0`,
  port-set `14 -> 21`, dead-name `0 -> 0`, unknown `0 -> 0`.
  Endpoint alignment was close: diagnostic last names `29,877` vs external
  last ports `29,338`, delta `+539`.
- Warm-up filtered summaries keep the same conclusion:
  with `APPGL_MACH_PORT_CLASSIFIER_MIN_FRAME=720`, names `369 -> 29,877`
  and send `269 -> 29,768`; with `MIN_FRAME=1800`, names
  `7,187 -> 29,877` and send `7,083 -> 29,768`. In both filtered views, send
  remains the largest positive right-class delta/slope; receive, port-set,
  dead-name, send-once, and unknown are tiny or flat.
- Time-shape check:
  external rows near 30s/90s/180s/end were ports
  `2,959`, `11,865`, `24,836`, `29,338`.
  Diagnostics at nearby bridge frames showed names/send:
  frame `720`: names `369`, send `269`;
  frame `1800`: names `7,187`, send `7,083`;
  frame `2160`: names `9,708`, send `9,604`;
  frame `4320`: names `24,836`, send `24,727`;
  frame `5040`: names `29,877`, send `29,768`.
  Read: the manual Mach-port growth is now localized to retained Mach send
  rights, not receive rights, send-once rights, dead names, port sets, or
  unknown right types.
- Next fix lane: audit send-right producing APIs and Objective-C/CF/Metal/CA
  lifetimes. Prioritize paths that can retain or create remote/send rights per
  frame/draw/present, then add targeted attribution if code inspection does not
  immediately expose ownership.

C43 command-buffer autorelease force-drain result:

- Zero-patch A/B used the already-present runtime knob
  `APPGL_COMMAND_BUFFER_FORCE_DRAIN_AUTORELEASE=1` against the C42 live pin.
  Artifact root:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess-force-drain/20260609T183525Z/`.
  External monitor artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess-force-drain/20260609T183525Z/external/20260609T183530Z/`.
  Exact PID was `45111`; process scan was clear after manual exact-PID
  termination.
- A/B result collapsed the Mach-port growth:
  external `top` ports `338 -> 338`, peak `338`, delta `0`, slope effectively
  `0` ports/min over `210.640s` with `92` external rows. In-process
  diagnostics aligned exactly at the endpoint: diagnostic last
  `processMachPortNames=338`, external last ports `338`, endpoint delta `0`.
  Classifier full span reported names `206 -> 338` (`+132`) and send rights
  `134 -> 251` (`+117`), versus the prior manual baseline send climb
  `132 -> 29,768` (`+29,636`). Read: force draining command-buffer allocation
  autorelease pools is the current fix candidate and is effective in this
  exact-PID proof lane. Because the user's earlier run exercised the live game
  scene with lower FPS and higher RSS, keep the crown gate on a fresh manual
  soak before treating the Mach-port blocker as fully closed.
- Launcher hardening:
  `$PROJECT_ROOT/live-targets/appgl-bridge/launch-warzone-appgl.sh`
  now enables `APPGL_COMMAND_BUFFER_FORCE_DRAIN_AUTORELEASE=1` by default,
  with escape hatch
  `APPGL_DISABLE_COMMAND_BUFFER_FORCE_DRAIN_AUTORELEASE=1`.
  `diagnose-warzone-memory.sh` also defaults the same knob to `1`.
  `sh -n launch-warzone-appgl.sh`, `bash -n diagnose-warzone-memory.sh`, and
  repo `git diff --check` passed.
- Diagnostic runtime hardening:
  command-buffer debug counters now include allocated/submitted/completed counts
  by `AppGLCommandReason`, and the new atomic arrays are explicitly zeroed in
  `MetalCommandSubmission::SharedState`. Build passed:
  `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j 8`.
  Only the pre-existing `MTLResourceUsageSample` deprecation warnings and
  duplicate-library linker warning appeared.
- Live pin rotated after clean process check:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-pinned.dylib`.
  Current live UUID `ED65E893-A296-39B4-8D88-D273A41A4DB3`, signed SHA256
  `5f15d2f2a8264c56a5a75180e4dd6109c02900a9c9399fc980206216d296eb46`,
  install-name `@rpath/libAppGL.dylib`, codesign valid. Pre-rotation backup:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-pinned-DCC4AD4B-pre-ED65E893.dylib`.
- Crown gate: memory is stable in the user's manual soak and the Mach-port
  force-drain candidate is installed as the live launcher default, but
  crown/checkpoint should wait for one fresh user/manual soak on the current
  `ED65E893` live pin. Next performance levers after that: CPU-side command
  submission/frame pacing, draw count reduction, and GPU utilization uplift.
- AppGL-Worker ACK (`586d534c-a93f-4490-8fe0-881d9595bc7c`): independently
  verified the C43 artifact summary, endpoint alignment, launcher default and
  escape hatch, memory-diagnosis default, by-reason diagnostics/zeroing shape,
  `sh -n`/`bash -n`/`git diff --check`, live pin UUID/SHA/install-name/codesign,
  and clean process hygiene. Worker agrees with the gate wording: strong
  installed fix candidate, not crowned closure, until a fresh user/manual soak
  on `ED65E893` confirms the user's lower-FPS/higher-RSS gameplay route keeps
  Mach ports flat.
- GLTest-Foreman ACK (`e2a75483-2789-48d3-8009-1fb23b420871`):
  independently verified the artifact root, exact PID alignment, env,
  external monitor flatness, RSS range, raw `top` snapshots, classifier
  endpoint, script defaults/syntax, live pin identity, backup existence, and
  tracker diff check. GLTest notes the classifier reached the flat endpoint by
  frame `60` and stayed flat through frame `29400`, but agrees the manual
  gameplay soak on `ED65E893` remains the crown gate.
- Short rotated-pin sanity proof:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess-ed65-sanity/20260609T184735Z/`.
  This used live pin `ED65E893`, exact PID `48069`, 90s monitor duration, and
  the canonical launcher path with force-drain defaulted on. External monitor:
  `41` rows over `91.864s`, ports `336 -> 335`, peak `336`, delta `-1`, slope
  `-0.538391 ports/min`; RSS `420.375 -> 419.172 MiB`, peak `444.328 MiB`.
  Classifier endpoint alignment was exact (`335/335`, delta `0`), names
  `204 -> 335`, send `133 -> 249`, receive `99 -> 133`, unknown/dead/send-once
  all flat. Process scan was clear after the run.
- The rotated-pin proof also validates the new by-reason command-buffer
  diagnostics: final row showed `submittedCommandBuffers=13684`,
  `completedCommandBuffers=13684`, `plainCommandBufferAllocations=0`,
  `autoreleaseDrainedCommandBufferAllocations=13684`.
  Allocations were dominated by `TranslatedDraw=13679`; submissions/completions
  were dominated by `PresentPendingWork=13678`, with only small readback/upload
  counts.
- Refined CPU-lane read after AppGL-Worker and GLTest review: the current code
  already reuses an open Metal command buffer while a render pass remains open,
  so `TranslatedDraw` is best treated as the opener/allocation label for a
  frame/present generation, not proof of an unconditional command buffer per
  draw. `GLContext::flush()` and `GLContext::swapBuffers()` both currently alias
  to `presentPendingWork()` and therefore submit as `PresentPendingWork`, so the
  next patch should be attribution-only: split `PresentPendingWork` by API
  source (flush vs swapBuffers vs finish/internal pressure), and record
  `pendingPresent` plus commit/no-work returns. Do not pursue command-buffer
  lease reuse across present boundaries; Metal command buffers are single-use,
  and present/readback/ring-slot/transient-invalidation boundaries remain hard
  correctness boundaries. After attribution, safer behavior levers are
  present-frequency/frame-pacing A/B and no-op/redundant flush coalescing, not
  cross-present command-buffer coalescing.
- Added helper analyzer:
  `$PROJECT_ROOT/live-targets/appgl-bridge/analyze-command-buffer-reasons.sh`.
  It accepts a run directory, finds `appgl-diagnostics.jsonl`, writes
  `command-buffer-reasons.csv` and `command-buffer-reason-deltas.tsv`, and
  emits `command-buffer-reasons-summary.txt`. It handles older artifacts
  without by-reason arrays by still reporting top-level submitted/completed,
  plain-vs-drained allocation, in-flight, and retained-live deltas. Follow-up
  hardening made the by-reason phase streaming and added an explicit
  `reason_deltas_present` count. `bash -n` passed; ED65 sanity artifact and C43
  force-drain artifact both analyzed successfully. ED65 reported
  `reason_deltas_present=10`; the older C43 artifact reported
  `reason_deltas_present=0` as expected.
- AppGL-Worker ACKs:
  `ae19c981-c2db-43ca-bbeb-249a1c4c0449` confirmed the hazard review and
  recommended attribution plus pacing/present-frequency over command-buffer
  reuse; `2f640f8f-1855-4185-8a0a-42a43cbb6ca3` reviewed the analyzer and
  found no runtime-behavior concern.
- GLTest-Foreman ACK (`35d03370-a476-4030-bde3-836f16c8c670`): independently
  verified the ED65 sanity artifact, analyzer outputs, current
  MetalCommandSubmission/MetalFrameGraph path, and the same next-lane guidance.

C44 present-source attribution lane (rotated live diagnostic pin):

- Patch scope is diagnostic-only. Added command reasons `PresentFromFlush` and
  `PresentFromSwapBuffers`; `GLContext::flush()` and `GLContext::swapBuffers()`
  now pass those source reasons through `presentPendingWork()` to
  `MetalFrameGraph::present()`. The legacy/default `PresentPendingWork` reason
  remains for internal callers.
- `MetalFrameGraph::present()` now records source/outcome counters without
  changing ordering, commit, present, or wait behavior:
  `presentCalls`, `presentFromFlushCalls`,
  `presentFromSwapBuffersCalls`, `presentInternalCalls`,
  `presentPendingTrueCalls`, `presentPendingFalseCalls`,
  `presentCommandBufferPresentCalls`, `presentCommandBufferNilCalls`,
  `presentNoWorkReturns`, `presentCommitAttempts`,
  `presentCommitSuccesses`, and `presentCommitFailures`. These are surfaced in
  `metalResources.frameGraph` diagnostics JSON.
- DCR2 sentinels now assert the attribution contract directly:
  clear+`glFlush` submits as `PresentFromFlush`, offscreen `swapBuffers()`
  submits as `PresentFromSwapBuffers`, and idle `glFlush` is recorded as a
  no-work present.
- Validation:
  `git diff --check` clean;
  `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j 8`
  passed with only known `MTLResourceUsageSample` deprecation warnings and the
  duplicate-library linker warning;
  `./build-release-fp64on/appgl_gauntlet_cli dcr2-sentinels` passed after the
  new assertions;
  `./build-release-fp64on/appgl_gauntlet_cli dcr3-sentinels` passed;
  `./build-release-fp64on/appgl_gauntlet_cli dcr3c-sentinels` passed all nine
  tests.
- Diagnostic serialization artifact:
  `tests/reports/perf-step7-rung3-present-attribution/diagnostics.json`.
  It confirms the new `metalResources.frameGraph` keys are emitted. The
  post-run values are zero because gauntlet sentinel contexts are destroyed
  before the final diagnostics dump; the live/manual route will provide nonzero
  values after pin rotation and a fresh run.
- Analyzer follow-up:
  `$PROJECT_ROOT/live-targets/appgl-bridge/analyze-command-buffer-reasons.sh`
  now also emits `present-source-counters.csv` and `present_source_*` deltas
  from `metalResources.frameGraph`. It also prints
  `present_source_available=0/1` so pre-C44 artifacts are not mistaken for
  measured-zero present cadence. Compatibility check passed on pre-C44 ED65 and
  C43 artifacts: original command-buffer summaries remained intact,
  `present_source_available=0`, and present-source deltas were all zero as
  expected for artifacts without the new fields.
- AppGL-Worker ACK (`69ddfe67-5f51-4a2e-8d72-fd7c2339c920`): reviewed the
  attribution split, inventory/JSON plumbing, enum/table consistency, sentinel
  coverage, analyzer smoke, and process hygiene. Worker sees no safety blocker
  for live diagnostic rotation. Non-blocking caveats captured here: older
  artifacts need the availability flag above, and
  `presentCommandBufferPresentCalls` means "current command buffer was non-nil
  at accounting time"; pair it with `presentPending*`,
  `presentNoWorkReturns`, and `drawablePresentCalls` before interpreting actual
  drawable presentation.
- GLTest-Foreman ACK (`5661eb43-f9b7-492f-9cc5-8caabf280c35`): independently
  reviewed the attribution split, current present path, inventory/JSON
  plumbing, sentinel assertions, analyzer changes, and local DCR2 rerun. GLTest
  sees no behavioral safety blocker and agrees this is acceptable as the next
  diagnostic live pin.
- Live pin rotated after clean process check:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-pinned.dylib`.
  Current live UUID `86BE8A4B-ABBA-3891-B738-9668E8355330`, signed SHA256
  `d34eae6de8cca5802d2925894b1495201417771c682546dd5fba06d17679c989`,
  install-name `@rpath/libAppGL.dylib`, codesign valid. Pre-rotation backup:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-pinned-ED65E893-pre-86BE8A4B.dylib`.
  Launcher syntax checks passed and force-drain remains default-on.
- Short C44 automated sanity artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/c44-present-attribution-sanity/20260609T191024Z-skip-on/`.
  Exit code `0`, loaded pin UUID `86BE8A4B`, no leftover process after run.
  This autogame/highground path completed quickly (`Game ended (duration: 5)`),
  so treat it as pin/diagnostic sanity only, not the manual gameplay crown gate.
  Analyzer result: `present_source_available=1`, diagnostic rows `2`
  (`bridgeFrame 1 -> 60`), `presentCalls_delta=59`,
  `presentFromSwapBuffersCalls_delta=59`, `presentFromFlushCalls_delta=0`,
  `presentCommitSuccesses_delta=57`, `presentCommitFailures_delta=0`,
  `submittedByReason_PresentFromSwapBuffers_delta=57`. Memory was not a soak
  signal (`rss.csv` had only seven samples, `955.453 -> 640.906 MiB`).
  Mach-port top sampling was likewise short/early (`365 -> 861`, two samples)
  and is not comparable to the 3-minute manual gate.
- Post-rotation peer ACKs:
  AppGL-Worker (`09d595cf-5340-4e43-ab14-acee304de7fe`) and
  GLTest-Foreman (`c00ff0f9-4dde-49f4-a90e-bf69bd95b9d1`) both independently
  verified the C44 live pin identity, sanity artifact, analyzer deltas, docs,
  and unchanged crown gate.
- Artifact nuance and helper hardening: the C44 sanity artifact's
  `proofs/post-run-process-scan.txt` contains only the scanner command
  self-match, not a live Warzone/AppGL process. `diagnose-warzone-memory.sh`
  now snapshots `ps` to a temporary file before filtering, so future generated
  `post-run-process-scan.txt` files should not include the filter process
  itself.
- AppGL-Worker helper-hardening ACK
  (`fa9d0288-e1f1-491c-8131-4f4fded1fe30`): spot-checked the scanner fix,
  script syntax checks, `git diff --check`, live C44 UUID/SHA/codesign, process
  hygiene, docs, and unchanged manual-soak crown gate. No blocker.
- GLTest-Foreman helper-hardening ACK
  (`9b4fb49b-c60f-42a9-a4fd-8b8ba5e29242`): verified the scanner fix shape,
  syntax checks, `git diff --check`, live C44 UUID/SHA/codesign, process
  hygiene, and GLTest-side tracker update. No crown-state change.
- Crown gate unchanged: fresh user/manual gameplay soak on the current
  `86BE8A4B` live pin with canonical launcher and force-drain defaulted on.

C44 manual gameplay soak result:

- Artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess/20260609T194309Z/`.
  External monitor:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess/20260609T194309Z/external/20260609T194314Z/`.
  Exact PID `55466`; monitor duration `181.599s`; target was alive at monitor
  end. Launch env points at the canonical launcher, in-process Mach-port
  diagnostics enabled, and frame interval `60`.
- Crown gate result: not closed. External ports grew `339 -> 28,377`
  (`+28,038`, slope `9909.68 ports/min`). In-process classifier localized the
  growth to send rights: names `204 -> 28,776`, send `133 -> 28,675`
  (`+28,542`), receive only `+52`; largest positive right class was `send`.
  Endpoint diagnostic-vs-external delta was `399`.
- Memory read is much better than the old catastrophic leak but not the crown
  signal by itself: external RSS `623.359 -> 1084.062 MiB`, peak
  `1200.047 MiB`; after the load peak, `90s -> end` was roughly
  `1064.531 -> 1084.062 MiB` (`+19.531 MiB`).
- C44 present-source result: real manual gameplay cadence is swap-driven, not
  GL flush-driven. Analyzer reported `present_source_available=1`,
  `presentCalls_delta=6299`,
  `presentFromSwapBuffersCalls_delta=6299`,
  `presentFromFlushCalls_delta=0`,
  `presentCommitSuccesses_delta=6297`, and
  `presentCommitFailures_delta=0`.
- Command-buffer result: `submittedCommandBuffers_delta=47,628`, all via
  autorelease-drained allocation (`plainCommandBufferAllocations_delta=0`,
  `autoreleaseDrainedCommandBufferAllocations_delta=47,628`), retained command
  buffers live returned to `0`, and peak in-flight was `2`.
- Strongest next-lane correlation: Mach send-right growth tracks
  `LayeredClear + LayeredClearDrainCurrent`, not `PresentFromSwapBuffers`.
  At frame `600`: send `250`, LayeredClear `0`,
  LayeredClearDrainCurrent `0`. At frame `6300`: send `36,232`,
  LayeredClear `25,685`, LayeredClearDrainCurrent `10,274`. From frame
  `600 -> 6300`, send growth was about `35,982`, while
  LayeredClear+LayeredClearDrainCurrent growth was about `35,959`.
  Read: the next fix lane should inspect/patch layered-clear and
  drain-current command-buffer/encoder lifetime. No additional broad data
  collection is needed before that patch lane; rerun the same manual harness
  after a targeted fix.
- `lsmp` snapshots were unavailable because passwordless sudo was not
  available; the in-process Mach-port classifier remains the right-class proof.
  Bridge update sent to AppGL-Worker and GLTest-Foreman on
  `perf-step7-rung3-c44-manual-soak-layeredclear-port-growth`.
- GLTest-Foreman ACK (`e3ab7b60-7108-4f78-a1cb-a8f9d3bd126a`):
  independently verified the C44 manual soak artifact, live pin identity,
  external/in-process Mach-port failure signal, post-load RSS read,
  swap-driven present attribution, force-drained command-buffer counts, and
  LayeredClear/LayeredClearDrainCurrent correlation. GLTest agrees C44 cannot
  crown and that no further broad data run is needed before targeted
  LayeredClear lifecycle patch work.

C45 command-wait semaphore owner fix:

- Root-cause read: the C44 LayeredClear correlation was a hot-producer signal,
  but the owner bug was lower in `MetalCommandBufferLease::commitAndWaitImpl`.
  Each synchronous command buffer allocated a per-wait dispatch semaphore;
  the completion handler needed its own retained reference, and the local wait
  reference needed release after `waitOnSemaphore` returned. AppGL-Worker
  applied that patch and validated a local build/sentinel set.
- Foreman follow-up hardening: removed the adjacent throwaway
  `MetalCommandSubmission waiter(nil, state->inFlightBound)` path from
  `commitAndWaitImpl`. That constructor created a temporary `SharedState`
  before immediately overwriting it with the real shared state. The wait helper
  now wraps the existing shared state directly, and `SharedState` releases its
  in-flight dispatch semaphore under non-ARC. This keeps the per-wait fix from
  leaving a second dispatch-semaphore ownership trap beside it.
- Validation:
  `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j 8`
  passed. Known warnings only: existing `MTLResourceUsageSample` deprecation
  and duplicate static-library linker warning. Targeted sentinels passed:
  `dcr2-sentinels`, `dcr3-sentinels`, `dcr3c-sentinels`, and
  `depth32f-stale-drop-probes`.
- Live pin rotated from C44 `86BE8A4B` to C45
  `85C5B354-12D6-39C0-B50B-79935A84AA95`; SHA256
  `b2937c485236a727e8467424d96c9a46bbe4cffe8922bf43759c0d77037ae838`;
  install-name `@rpath/libAppGL.dylib`; codesign valid. Backup:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-pinned-86BE8A4B-pre-85C5B354.dylib`.
- Short launcher smoke artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/c45-semaphore-owner-sanity/20260609T200850Z-skip-on/`.
  Exit code `0`; Warzone initialized AppGL (`OpenGL Vendor: AppGL`,
  renderer `AppGL on Metal (Apple M1 Max)`, version `4.6 AppGL core`).
  The 2s `lsof` snapshot proves the process mapped both
  `libappgl_bridge.dylib` and `libAppGL-pinned.dylib`; the paired pin proof is
  UUID `85C5B354`, SHA above.
- Smoke analyzer result: diagnostics rows `3`, frames `1 -> 120`,
  `submittedCommandBuffers_delta=758`, `completedCommandBuffers_delta=759`,
  retained command buffers live returned to `0`, and present source remained
  swap-driven (`presentFromSwapBuffersCalls_delta=119`,
  `presentFromFlushCalls_delta=0`, `presentCommitFailures_delta=0`).
  The short run exercised the previous hot lane:
  `LayeredClear_delta=390`,
  `LayeredClearDrainCurrent_delta=156`, and
  `FlushForReadback_delta=82`.
- Short Mach-port read: external top samples stayed flat, `230 -> 229`
  over the smoke window, despite the LayeredClear/LCDC-heavy sample. This is
  encouraging but not crown evidence: autogame ended quickly
  (`Game ended (duration: 6)`), so the real gate remains the user/manual
  three-minute gameplay soak with the exact-PID in-process + external monitor
  harness.
- Current crown gate: run the manual harness against live pin `85C5B354` and
  verify external ports/in-process send rights stay flat through the
  three-minute gameplay window while memory remains steady.
  Command:
  `cd "$PROJECT_ROOT/live-targets/appgl-bridge" && APPGL_WARZONE_MACH_PORT_DURATION=180 APPGL_WARZONE_MACH_PORT_INTERVAL=2 APPGL_WARZONE_MACH_PORT_SAMPLES=30,90,180 APPGL_WARZONE_MACH_PORT_LSMP=0 APPGL_WARZONE_MACH_PORT_STOP_AFTER_MONITOR=0 ./run-warzone-appgl-machport-proof.sh --window --resolution=1280x720`.
  After the monitor completes, quit the game normally if the wrapper reports it
  is still running.
- Peer ACKs: AppGL-Worker (`c16270d1-42cf-4ff6-b738-1255b3ab7af7`) verified
  the live `85C5B354` pin, short-smoke flat-port read, and manual soak as the
  crown gate, with no worker-side mutation. GLTest-Foreman
  (`4b0bf2e1-b0de-4733-ae3e-2f87de2d48cc`) independently verified the live pin
  UUID/SHA/install-name/codesign, backup, patch shape, diff/syntax checks,
  smoke artifact, command-buffer/present deltas, flat short-window ports, empty
  post-run process scan, and updated the GLTest tracker. Both agree C45 is
  ready for the manual crown gate but is not crowned yet.

C45 manual crown result:

- Artifact:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess/20260609T203253Z/`.
  External monitor:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess/20260609T203253Z/external/20260609T203258Z/`.
  Exact PID `61129`; external monitor captured `84` samples over
  `192.926s`; target exited by monitor end. Launch env points at the canonical
  `launch-warzone-appgl.sh`, with in-process Mach-port diagnostics enabled and
  frame interval `60`.
- Crowned stability checkpoint: the C45 command-wait semaphore owner fix
  collapses the Mach-port leak. External top ports moved only `338 -> 398`
  (`+60`, peak `401`, slope `6.48861 ports/min`) versus the C44 failure
  `339 -> 28,377` (`+28,038`, slope `9909.68 ports/min`). Post-load tail is
  effectively flat: from `90s -> end`, external ports were `397 -> 398`
  (`+1`).
- In-process classifier agrees. Names moved `207 -> 400` (`+193`), send rights
  `134 -> 289` (`+155`), receive rights `103 -> 172` (`+69`), with endpoint
  diagnostic-vs-external delta `2`. After startup, from frame `600 -> 4320`,
  send rights moved only `267 -> 289` (`+22`). This replaces the prior C44
  one-send-right-per-sync-command-buffer failure shape.
- The former hot producer remained heavily exercised without port growth:
  `submittedCommandBuffers_delta=33,283`, all via autorelease-drained command
  buffer allocation (`plainCommandBufferAllocations_delta=0`,
  `autoreleaseDrainedCommandBufferAllocations_delta=33,283`), peak in-flight
  `2`. Reason deltas included `LayeredClear_delta=17,705`,
  `LayeredClearDrainCurrent_delta=7,082`, `FlushForReadback_delta=3,545`,
  `PresentFromSwapBuffers_delta=4,317`, and `PressureFlush_delta=634`.
- Present attribution remained clean and swap-driven:
  `presentFromSwapBuffersCalls_delta=4319`,
  `presentFromFlushCalls_delta=0`,
  `presentCommitSuccesses_delta=4317`, `presentCommitFailures_delta=0`.
- Memory remains within the post-fix stability envelope rather than the old
  catastrophic leak. External RSS was `625.000 -> 1108.344 MiB`, peak
  `1201.344 MiB`; post-load `90s -> end` was
  `1046.562 -> 1108.344 MiB` (`+61.781 MiB` over `100.951s`). Keep watching
  RSS during the next performance levers, but this is no longer the
  `~0.8GB/s` blocker.
- Result: C45 is crowned as the memory/Mach-port stability checkpoint. The
  roadmap can move back to performance work, with CPU still high and FPS/GPU
  utilization as the next optimization lane.

C46 layered-clear async CPU-lane prototype:

- Candidate intent: reduce CPU time spent waiting on GPU-only layered-clear
  ordering in the live Warzone path, where the crowned C45 manual artifact
  still showed heavy `LayeredClear_delta=17,705` and
  `LayeredClearDrainCurrent_delta=7,082` work while CPU remained high and GPU
  underutilized.
- Patch shape:
  - Added `LayeredClearDrainCurrentAsync` and `LayeredClearAsync` command
    reasons as distinct `AsyncCommit` / `GpuOnlyOrdering` counters.
  - Added default-off feature flag `APPGL_ENABLE_LAYERED_CLEAR_ASYNC=1`.
  - Default behavior remains the C45 synchronous layered-clear path.
  - With the flag enabled, `clearLayeredTextureImpl` converts the current
    command-buffer drain to async only after closing the encoder and presenting
    the drawable. If a frame-ring slot is owned, it uses
    `commitWithFrameSignal(...LayeredClearDrainCurrentAsync...)` and advances
    the ring immediately without manually signaling; otherwise it uses an
    ordinary async commit.
  - Standalone layered-clear chunks use
    `makeCommandBufferDrainingAutorelease(LayeredClearAsync)`, explicitly
    retain the target `id<MTLTexture>` until command-buffer completion, and
    submit with plain `commit(LayeredClearAsync)` so they never frame-signal.
  - CPU-visible readback, lifetime/destruct, explicit finish/drain, and
    `FlushForReadback` semantics remain untouched.
- Peer source-hazard review:
  - AppGL-Worker confirmed the opt-in async shape is plausible if ring-slot
    balance, standalone no-frame-signal behavior, texture lifetime, producer
    drains, queue ordering, and in-flight/backpressure counters stay covered.
  - GLTest-Foreman accepted the default-off posture and requested local
    default-off/opt-in correctness gates followed by live Warzone A/B before
    any default-on or crown claim.
- Final local artifact root:
  `tests/reports/perf-step7-rung3-c46-layered-clear-async-local/20260609T205129Z-final`.
- Build/static:
  `git diff --check` passed, and
  `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli appgl_bar_b_benchmark -j 8`
  passed with only the known `MTLResourceUsageSample` deprecation warnings and
  duplicate static-library linker warning.
- Default-off final gate passed:
  `dcr2-sentinels`, `dcr3-sentinels`, `dcr3c-sentinels` 9/9,
  `depth32f-stale-drop-probes` 6/6,
  `texture-shadow-mip-eviction-probes` 10/10, and BAR-B
  `perDrawUs=65.894488`.
- Opt-in final gate passed with `APPGL_ENABLE_LAYERED_CLEAR_ASYNC=1`:
  the same sentinel/probe set stayed green, and BAR-B measured
  `perDrawUs=65.671615`. DCR3C remained bounded with `peakInFlight=2` and
  `allocWaitTimeouts=0`.
- Counter proof:
  - Default-off `default-dcr3c.log` shows
    `LayeredClear mode=commit-and-wait` with the old completion wait.
  - Opt-in `optin-dcr3c.log` shows
    `LayeredClearAsync mode=async-commit` and no
    `reason=LayeredClear mode=commit-and-wait` / old completion wait in the
    opt-in layered-clear slice.
  - Final logs had no failed/timeout markers, no non-4 Metal completion
    statuses, and no `allocWaitTimeouts>0`.
- Commit: `97164c3` (`Add C46 layered-clear async experiment`).
- Live pin:
  - Rotated `libAppGL-pinned.dylib` to the C46-capable build after the local
    gate so live A/B can use the canonical route.
  - UUID `A8483891-2FC0-3D00-BE42-94978B713DB0`, SHA256
    `da11d5d25072d313b7d845d6b421b12557056cefdb282a13fd8a060c5cb915db`,
    codesign valid.
  - C45 backup:
    `$PROJECT_ROOT/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T205432Z-C45-85C5B354-pre-C46-A8483891.dylib`.
  - The canonical launcher still leaves C46 disabled unless
    `APPGL_ENABLE_LAYERED_CLEAR_ASYNC=1` is explicitly exported.
- Profile-on live autogame A/B artifacts:
  - Default/opt-in first pair:
    `memory-runs/c46-layered-clear-async-ab/20260609T205521Z-c46-default`
    and
    `memory-runs/c46-layered-clear-async-ab/20260609T205542Z-c46-async`.
  - Alternating repeat pair set:
    `memory-runs/c46-layered-clear-async-ab-repeat/20260609T205736Z-c46-async`,
    `20260609T205749Z-c46-default`,
    `20260609T205802Z-c46-default`, and
    `20260609T205815Z-c46-async`.
  - All six runs exited `0`; all used live pin UUID `A8483891` and the same
    highground autogame route. The autogame path still ended early
    (`Game ended (duration: 4/5)`), so treat this as a smoke/profile signal,
    not as a manual-gameplay FPS verdict.
  - Averaged profile-on analyzer-window result: opt-in reached bridge frame
    `120` in all three runs versus default-off average `80` (`60/90/90`).
    Opt-in replaced sync reasons with async reasons (`LayeredClearAsync`
    average `396.667`, `LayeredClearDrainCurrentAsync` average `158.667`)
    while default-off still used sync `LayeredClear` average `198.333` and
    `LayeredClearDrainCurrent` average `79.333`.
  - Completion-wait movement: default-off averaged `354,470.741 us` in
    `LayeredClear` + `LayeredClearDrainCurrent` completion waits; opt-in
    recorded `0` for those sync waits.
  - Stability counters stayed clean: present commit failures `0`, no retained
    object growth, no alloc-wait timeouts. Peak in-flight rose from default
    `2` to opt-in `5`, still under the bound.
  - CPU/per-draw read is mixed: opt-in averaged sampled CPU `87.741%` versus
    default `82.655%`, and `framegraph_encode` profile average was higher
    (`48.486` vs `42.034 us/draw`). The higher frame count may explain some
    of the CPU load, but this is not enough for default-on.
- No-profile live autogame A/B artifacts:
  - Runs:
    `memory-runs/c46-layered-clear-async-ab-noprofile/20260609T210032Z-c46-default`,
    `20260609T210045Z-c46-async`,
    `20260609T210058Z-c46-async`, and
    `20260609T210110Z-c46-default`.
  - Average bridge-frame result: opt-in `120`, default-off `90`. Present
    failures remained `0`; retained object delta `0`; peak in-flight remained
    bounded at opt-in `5` versus default `2`.
  - Average sampled CPU was still higher for opt-in (`87.410%` versus
    `83.733%`). Ports/RSS stayed within the short-run stability envelope:
    opt-in average ports delta `+10.5`, default `+12.5`; opt-in peak RSS
    `969.461 MiB`, default `963.078 MiB`.
- Fable-Clerk adjudication, 2026-06-10: C46 is crowned as an opt-in
  throughput win because it removes the LC/LCDC CPU completion waits and
  increases both autogame and manual-gameplay bridge frames without reopening
  the C45 stability blocker. No additional manual pair is required for the
  opt-in crown. Default-on is deferred indefinitely, not because the evidence
  is weak, but because the `+4 FPS` / `~12%` class win is not the lever that
  closes the `24 -> ~150 FPS` gap and may become the wrong policy once the
  real bottleneck moves. Canonical launch remains default-off; use
  `APPGL_ENABLE_LAYERED_CLEAR_ASYNC=1` or the C46 async wrapper for opt-in.
  Step 7 micro-rung cadence is retired as the primary attack; the next S24
  work targets structural frame-shape pathologies: roughly `4.5`
  `LayeredClear` plus `1.8` `LayeredClearDrainCurrent` command buffers per
  frame, and roughly `0.94` `FlushForReadback` commit-and-wait full drains per
  frame in the live Warzone path.
- Gate scope / thermal policy: do not make thermals a near-term C46 gate. The
  user clarified that native/Vulkan control drives thermals when the GPU is fed
  into the `90%` range; current AppGL is still underfeeding the GPU around
  `40%`, and one CPU thread near `100%` is not enough on this hardware to drive
  fan/thermal behavior. Near-term concern is hardware saturation, useful
  utilization, and avoiding wasted cycles. Battery/thermal throttles may be a
  later user-controlled feature, not a C46 crown blocker.
- User manual normal-gameplay observation after the wrapper was added:
  C46 opt-in is now reported consistently higher at roughly `24 FPS` versus
  `20 FPS` control. Async CPU is in the high `90%` range with GPU around
  `40%`; non-async is around `90%` CPU and `35%` GPU. Read: this is stronger
  than the earlier within-noise framing and suggests async converts LC/LCDC
  CPU wait into more delivered work and slightly better GPU feed, not lower
  absolute CPU. Directional CPU-per-delivered-frame improves (`98 / 24 ~= 4.1`
  versus `90 / 20 = 4.5` CPU%-per-FPS), while absolute CPU headroom worsens.
  Follow-up user observations report no hitching in either default-off or async
  mode, with the async uplift consistently around `+4 FPS`; async also feels
  smoother, but treat that as subjective smoothness coupled to higher FPS, not
  as proven lower frame-time variance until a harness captures lows/frame-time
  distribution. User also reports no visual glitches in either path: no
  observed flicker, depth/clear artifacts, or stale-layer artifacts during
  identical-window manual gameplay. Memory and Mach behavior are stable, with
  identical usage windows between default-off and async, materially lowering
  the C45-regression concern for this manual path. This strengthens C46 from a
  qualitative/within-noise result into a repeatable manual opt-in perf-win
  candidate. The measured manual gate should still focus on repeatability,
  frame-time distribution and `1%` lows, input latency, peak
  in-flight/backpressure/alloc waits, present failures, and reason deltas
  proving LC/LCDC sync waits remain removed.
- Measured manual A/B gate result, single paired run:
  artifact root
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/c46-layered-clear-async-manual-ab`.
  Default-off run `20260609T232142Z-c46-default` and async run
  `20260609T232531Z-c46-async` used the same C46-capable live pin
  `A8483891` / SHA256
  `da11d5d25072d313b7d845d6b421b12557056cefdb282a13fd8a060c5cb915db`,
  `--window --resolution=1280x720`, `210s` duration, diagnostics interval
  `30`, profiles disabled, Mach-port sampling enabled, and both exited `0`
  with empty post-run process scans. Analyzer was rerun with a safe `find`
  loop after the user's shell hit zsh `No Matches found` on a glob. Default
  reached bridge frame `4500`; async reached `5070`, a `+570` frame /
  approximately `+12.7%` throughput lift that matches the user's repeatable
  `24 FPS` versus `20 FPS` observation directionally. Present failures stayed
  `0` in both runs. Default used sync reasons:
  `LayeredClear_delta=20165` and `LayeredClearDrainCurrent_delta=8066`, both
  `commit-and-wait`. Async used
  `LayeredClearAsync_delta=21040` and
  `LayeredClearDrainCurrentAsync_delta=8416`, both `async-commit`, while
  `FlushForReadback` remained a `commit-and-wait` readback path as intended.
  Peak in-flight rose from `2/48` default to `6/48` async, with async final
  current in-flight `1`, retained objects live `0`, retained objects peak `3`,
  retained command buffers live `1`, and retained command-buffer peak `6`.
  Post-load `180s -> end` stability stayed bounded: default RSS
  `1036.906 -> 1048.734 MiB` and ports `373 -> 370`; async RSS
  `1144.391 -> 1165.578 MiB` and ports `405 -> 404`. Read: C46 is a measured
  opt-in throughput win. It still does not prove lower CPU cost; it converts
  old GPU-only LC/LCDC waits into more delivered work and modestly better GPU
  feed. The win is crowned for opt-in use, while default-on remains deferred
  and the roadmap moves to structural attribution.

## 2026-06-10 C47/C48 Continuation

C47 was redefined from "flip sampler skip env" into attribution of the
residual live `FlushForReadback` trigger. The reason is launcher posture: the
runtime no-env default for `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP` is still OFF,
but the live Warzone canonical launcher defaults the sampler GPU-order skip ON
unless `APPGL_DISABLE_SAMPLER_GPU_ORDER_SKIP=1` is set. That launcher posture
also carried into the C46 manual A/B evidence above, so the correct question is
not whether skip ON helps; it is why residual FFR submits remain after skip ON.

Valid manual scene capture matrix, pre-C48 live pin `A8483891`:

- `async+skipON`:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/s24-step1-profile-of-record-manual-scene/20260610T014238Z-c46-async`.
  Duration `210.41s`, Studio Display drawable `2560x1440`, scene markers
  `startMultiplayerGame` and `multiplay/maps/4c-rush.gam`. Approx present
  rate `24.65/sec`. Producer-token counters: sampler
  `flush_candidates=124088`, `gpu_order_skips=124088`, `blocked=0`,
  `drain_flushes=1`. `sampler_producer_drain` total `517.4 ms`,
  average `0.425 us`. CB census: `FlushForReadback=4611`, but only `4`
  FFR completion waits totaling `3.21 ms`.
- `async+skipOFF`:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/s24-step1-profile-of-record-manual-scene/20260610T014808Z-c46-async`.
  Duration `210.25s`, same scene/drawable posture. Approx present rate
  `18.50/sec`. Producer-token counters: sampler `flush_candidates=6730`,
  `gpu_order_skips=0`, `drain_flushes=6730`.
  `sampler_producer_drain` total `33803.8 ms`, average `40.265 us`.
  CB census: `FlushForReadback=10099`; FFR completion waits `6734`,
  totaling `33418.58 ms`, p95 `9325.29 us`.
- `default+skipON`:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/s24-step1-profile-of-record-manual-scene/20260610T015217Z-c46-default`.
  Duration `210.03s`, same scene/drawable posture. Approx present rate
  `20.69/sec`. Producer-token counters: sampler
  `flush_candidates=97801`, `gpu_order_skips=97801`, `blocked=0`,
  `drain_flushes=0`. `sampler_producer_drain` total `389.2 ms`,
  average `0.405 us`. CB census: `FlushForReadback=3841`, but only `4`
  FFR completion waits totaling `3.51 ms`.

Read: sampler skip is doing the intended work in live gameplay. Turning it OFF
reintroduces roughly `33.4s` of FFR completion wait and roughly `33.8s` of
sampler-drain CPU time over a `210s` run. With skip ON, residual FFR remains as
a submit-count signature, but not as the dominant completion-wait bucket. The
C47 lane is therefore residual submit-source cleanup/avoidance, not sampler
read-set drain viability. Capture packet was forwarded to Fable-Worker in
bridge message `a37d2d71-5f1a-4e13-aa9f-f13d9bb87312`.

Fable-Worker Step-1 residual verdict:

- Residual FFR source is the per-frame viewport-request invalidate in the
  `ensureSizeAtLeast` grow-only-skip branch.
- The real residual cost was hiding under `drain_all` / `LifetimeDrain` stderr
  rows, not the CB completion-wait table. Async+skipON carried about `9.2s`
  over the `210s` capture. Standard census parsers should include
  `LifetimeDrain` drain-all count and wait so this bucket cannot hide again.
- The CB reason table's `commit-and-wait` submit-mode label is a nominal static
  reason-table class, not measured behavior for this path. Residual FFR submits
  are async; do not read the submit-mode column as actual call mode without
  cross-checking wait rows.
- `APPGL_FRAME_ATTRIBUTION_PROFILE` produced `0` rows despite env-on across the
  three capture roots. Treat this as a reproducible instrumentation bug queued
  under C49 census work.
- The skipON matrix evidence is crown-grade for C47: it removes the live
  sampler-drain burden. C49 should carry the residual viewport-invalidate /
  LifetimeDrain cleanup and census instrumentation.

C48 source state:

- Commit `00fde11` fixes a pre-existing default-path correctness bug: hot
  `drawArrays` / `drawElements` / `drawBaseVertex` paths did not wire the
  FBO attachment depth-stencil slice/level into draw info. A
  `glFramebufferTextureLayer` depth attachment with layer other than `0` could
  draw depth to slice `0` while readbacks sampled the attached layer. Warzone's
  far shadow cascades are the expected visible risk surface, so the visual gate
  must watch shadow quality, not just FPS.
- Commit `bdd2c14` adds default-off C48 FBO attachment clear folding behind
  `APPGL_ENABLE_FBO_CLEAR_FOLDING=1`. The intended forward config is C46
  layered-clear async ON, sampler GPU-order skip ON, and FBO clear folding ON.
  Worker reported local gates green across default/off and forward configs,
  including non-vacuous C48 folding probes and BAR-B identity.
- Runtime feature commits under C48 are `00fde11` and `bdd2c14`. Formal source
  target is now `6be0120`, which adds a C48 cascade-pattern probe only; the
  runtime behavior under preview remains the `00fde11` slice fix plus the
  `bdd2c14` default-off folding gate. A fresh `build-release-fp64on` AppGL
  build completed with only the known `MTLResourceUsageSample` and
  duplicate-library warnings.

C48 live/preview posture:

- Canonical live pin remains unchanged until the C48 gate chain clears:
  `libAppGL-pinned.dylib` UUID
  `A8483891-2FC0-3D00-BE42-94978B713DB0`, SHA256
  `da11d5d25072d313b7d845d6b421b12557056cefdb282a13fd8a060c5cb915db`.
- Separate unswept preview pin:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-c48-preview-bdd2c14-B52F0178.dylib`.
  UUID `B52F0178-6F29-345B-BD50-FD5E405120D1`, SHA256
  `8606e4a8faecc95fb09925203148712fe8cc1f2246d1842ae4266772193c8528`,
  ad-hoc/linker-signed CDHash
  `5c3a085c7cdc42df354afcac5b3551a990c200af`, install-name
  `@rpath/libAppGL.dylib`.
- Preview wrapper:
  `$PROJECT_ROOT/live-targets/appgl-bridge/launch-warzone-appgl-c48-preview.sh`.
  It exports `APPGL_ENABLE_LAYERED_CLEAR_ASYNC=1` and
  `APPGL_ENABLE_FBO_CLEAR_FOLDING=1`, follows canonical sampler-skip posture
  unless explicitly disabled, and injects the preview dylib without touching
  `libAppGL-pinned.dylib`.
- Operator preview is explicitly unswept informal evidence. Watchpoints:
  far-shadow cascades better/same/worse, clear/flicker/stale-frame artifacts,
  rough FPS versus the familiar `20` default / `24` async windows, and anything
  subjectively off.
- Operator preview observation relayed by Fable-Clerk: no FPS delta, still
  about `24 FPS`; visual regression: "the viewport seems to cast a shadow over
  the scene". The operator verified this against the native control binary in
  `/Applications`. Treat this as a parity failure on the C48 preview build
  (`bdd2c14` plus `00fde11`, forward config async+skip+fold). C48 crown chain
  is blocked pending root-cause.
- Artifact triage refuted the initial FBO-fold-loss hypotheses: H1/H3/H4 were
  not supported by the short census because the candidate logged
  `fboClearsDeferred=375`, `fboClearsFolded=375`, `fboClearsMaterialized=0`,
  zero lost clears, and no present failures. H5 is now confirmed precisely:
  `00fde11` correctly unmasked previously-missed nonzero depth cascade slices,
  and shadow-compare sampling of those FBO-rendered `Depth32Float` 2D-array
  cascade slices binds raw y-flipped Metal content without flip compensation.
  The existing flip machinery covers packed depth-stencil 2D textures only, not
  plain D32F arrays. Plain sampling/readback chains still pass, explaining why
  earlier probes and CTS did not catch the Warzone-shaped gap.
- Root-cause proof landed as test-only commit `0b2b1e6` on top of `6be0120`:
  `depth-layer-orientation-probes` adds a deterministic shadow-compare repro.
  Position-derived-Z and absolute gradient orientation probes pass, while the
  shadow-compare probe fails with the content-flip signature. C48 FBO clear
  folding is exonerated; failure reproduces with folding OFF and fold census
  balances. Do not revert `00fde11`; fix the compare sampling path around the
  corrected routing.
- Fix commit `35df142` implements the approved option-A compare-path y-flip in
  `ShaderTranslator`: depth compare/gather compare coordinates for
  `depth2d`/`depth2d_array` receivers get a per-slot flip factor only when the
  bound texture is compare-mode, FBO/viewport-rendered, lower-left, and
  depth-family, excluding packed-2D shapes already served by the flipped
  sampling copy. Worker local gates are green across default / fold / forward
  configs, including promoted orientation probes, uploaded-depth negative
  control, gather-compare, textureProj shadow, sentinel suites, BAR-B identity,
  and GS-emulator static consistency.
- Post-operator regression root cause: `35df142` injects `_appgl_CmpFlip` as a
  `main0` parameter and wraps shadow compare callsites, but Warzone's
  `shadow_mapping.glsl` performs the compare inside a helper function emitted
  by SPIRV-Cross with texture/sampler parameters. The helper body cannot see
  `_appgl_CmpFlip`, so helper-shaped shadow compare shaders compile to invalid
  MSL. The BAR-B/probe gap is now understood: local probes sampled in `main()`
  directly and did not exercise the helper-function shape.
- Amplifier: `MetalFrameGraph::getOrCompileLibrary` did not negative-cache
  failed library compiles, so the same invalid MSL source can recompile and fail
  on every draw. Standing protection for the next fix: add negative-cache
  behavior so future shader bugs fast-fail visibly instead of turning into a
  repeated main-thread compile storm.
- Replacement fix commit `d73c6e1f94ec382476433efcf583ab9344f78f71`
  (`Fix compare-flip helper-function scope + negative-cache MSL compile
  failures`) lands the regression repair on top of `e2a876d`. Commit contents
  are only Worker's three files:
  `src/context/MetalFrameGraph.mm`, `src/shader/ShaderTranslator.cpp`, and
  `tests/GauntletRunner.cpp`.
- `d73c6e1` fix details:
  - `MetalFrameGraph::getOrCompileLibrary` now negative-caches failed MSL
    sources by exact source under hash, bounded at `64`, with loud one-time
    stderr and failure counters. Future broken-shader bugs should fast-fail
    visibly rather than repeat a main-thread Metal compile storm.
  - `ShaderTranslator::injectDepthCompareFlip` now threads
    `constant float* _appgl_CmpFlip` through non-`main0` helper functions whose
    signatures contain depth receivers, mirroring SPIRV-Cross texture/sampler
    threading; call sites pass the factor down and bottom out at `main0`.
  - Second latent defect fixed: `_appgl_cmpFlipCoord` helper injection now
    anchors after `using namespace metal;`. The previous fragment-entry anchor
    placed the helper below helper-function bodies, another way to break
    helper-shaped compare shaders.
  - Any rewrite anchor failure abandons the whole compare-flip rewrite with a
    loud stderr/counter, leaving fast pre-fix/unflipped behavior instead of
    emitting invalid MSL.
  - New `depth-layer.shadow-compare-helper-fn` probe covers the Warzone
    `shadow_mapping.glsl` shape and was red before the fix / green after. The
    compile-storm canary asserts repeat draws add zero library-cache misses.
    Worker reported full sentinel + C48/orientation/compare probes green in
    default and forward configs, with BAR-B readback pixels identical.
- Worktree-collision note from Worker:
  `d876d217-4c4a-49d9-acdd-f05491d86254` reports an initial `git add -A`
  commit attempt briefly swept Foreman's uncommitted
  `docs/perf-arc-tracking.md` edits into the commit. Worker repaired it before
  publishing: local verification after `d73c6e1` showed HEAD at
  `d73c6e1`, the commit containing only the three Worker files above, and the
  ledger still dirty/uncommitted as Foreman-owned state.
- Comparable unattended 4c-rush visual repro is not currently available. The
  Step-1 `4c-rush` manual-scene captures needed operator assistance to enter
  the scene and resize/full-monitor the window. The harness can run unattended
  autogame, but that is a short, scenario-driven path and not a comparable
  visual parity matrix. Because of that, Scout Sweep 1 should continue as the
  default-path `00fde11` gate, while visual screenshot A/B waits for the
  operator window unless a true unattended scene driver is found.
- Short autogame C48 census A/B, informal engagement proof only:
  - Control current pin/C46 async root:
    `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/c48-autogame-census-ab/20260610T020743Z-c46-async`.
    Proved canonical pin `A8483891` /
    `da11d5d25072d313b7d845d6b421b12557056cefdb282a13fd8a060c5cb915db`.
    Highground autogame produced `113` presents, `LayeredClearAsync=350`,
    `LayeredClearDrainCurrentAsync=140`, `FlushForReadback=75`,
    `PressureFlush=11`, about `6.12` CB submits per present.
  - Candidate C48 preview/fold root:
    `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/c48-autogame-census-ab/20260610T020806Z-c48-preview`.
    Proved preview pin `B52F0178` /
    `8606e4a8faecc95fb09925203148712fe8cc1f2246d1842ae4266772193c8528`.
    Same autogame posture produced `116` presents, `LayeredClear*=0`,
    `FlushForReadback=80`, `PressureFlush=12`, about `1.81` CB submits per
    present.
- Candidate diagnostics at last valid frame `118` showed
    `fboClearsDeferred=375`, `fboClearsFolded=375`,
    `fboClearsMaterialized=0`, `fboClearsCoalesced=0`, and present failures
    `0`. This confirms C48 fold engages on the live autogame path and
    eliminates LayeredClear command-buffer submits in the short census. It does
    not replace Scout/default-path proof or the manual visual gate.
- Post-Sweep-1 live triage matrix is pre-staged but cancelled as a gate because
  the deterministic headless repro supersedes screenshots:
  - Arm A canonical control:
    `$PROJECT_ROOT/live-targets/appgl-bridge/launch-warzone-appgl-c48-triage-arm-a-canonical.sh`;
    canonical pin `A8483891`, folding/trace unset.
  - Arm B `00fde11` discriminator:
    `$PROJECT_ROOT/live-targets/appgl-bridge/launch-warzone-appgl-c48-triage-arm-b-00fde11.sh`;
    dylib
    `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-c48-armb-00fde11-7FEDBB3C.dylib`,
    UUID `7FEDBB3C-93D8-3B0B-AC4C-16EEAE34D1F3`, SHA256
    `70d7093c339f0a8bd8a1132ec64026676e8ff259dd10777b9e6b3dfbc4934701`,
    valid on disk, install-name `@rpath/libAppGL.dylib`; async forced OFF and
    `APPGL_ENABLE_FBO_CLEAR_FOLDING=0` / `APPGL_TRACE_FBO_CLEAR_FOLDING=0`
    exported explicitly while preserving canonical skip/drop/cache posture.
  - Arm C C48 preview forward config:
    `$PROJECT_ROOT/live-targets/appgl-bridge/launch-warzone-appgl-c48-triage-arm-c-preview-fold.sh`;
    preview `B52F0178`, async ON, sampler skip ON, folding ON.
  - Arm D optional trace:
    `$PROJECT_ROOT/live-targets/appgl-bridge/launch-warzone-appgl-c48-triage-arm-d-preview-fold-trace.sh`;
    Arm C plus `APPGL_TRACE_FBO_CLEAR_FOLDING=1`.
  Do not spend the post-Sweep-1 slot on this matrix unless Clerk reopens it for
  the 00:00 operator package. Screenshot mechanics are nevertheless proven for
  this shell: CoreGraphics window-ID enumeration works, and
  `screencapture -x -o -l<WID>` produced a real iTerm window PNG rather than
  wallpaper-only output. A reusable launch/capture helper is staged at
  `$PROJECT_ROOT/live-targets/appgl-bridge/run-c48-triage-screenshot-arm.sh`;
  it waits for the Warzone `[gameLoad]` marker, discovers the Warzone window ID,
  and captures fixed offsets/bursts per arm.

Scout retarget rationale:

- The old C47 sweep on `8583284` is superseded by C48 because `00fde11` changes
  default-path behavior and must be conformance-proven before any crown.
- Retarget message `e551f0a6-b5fa-4d81-89b3-55cd5c35a2df` asked Scout for two
  Release-standard full sweeps on C48 HEAD `bdd2c14`:
  1. no-env default config, proving the `00fde11` default-path slice fix;
  2. forward config with `APPGL_ENABLE_LAYERED_CLEAR_ASYNC=1`,
     `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`, and
     `APPGL_ENABLE_FBO_CLEAR_FOLDING=1`.
- Formal target update `1a3b27dc-00ea-4373-8414-01088011affa` retargeted Scout
  to `6be0120`; if Sweep 1 had already started on `bdd2c14`, report it as
  preliminary/superseded and top off at `6be0120`.
- After root cause, the sweep chain is restructured because the forthcoming fix
  is a flag-independent default-path behavior change:
  1. Let Sweep 1 complete on `bdd2c14`/`6be0120` default as the `00fde11`
     default-path gate.
  2. Sweep 2 is fix HEAD, default config. This is the priority sweep; CTS
     uploaded-depth compare coverage is the predicate-overreach backstop.
  3. Sweep 3 is fix HEAD, forward config: async + sampler skip + FBO folding.
     This is the crown sweep.
  GLTest may take a measurement window between Sweep 1 and Sweep 2 if their
  probe is ready; otherwise between Sweep 2 and Sweep 3. Canonical live pin
  remains `A8483891` until the full chain greens.
- Sweep 2 dispatch:
  - Source `35df142`, default/no-forward-env config.
  - Build proof:
    `$PROJECT_ROOT/appgl-runtime/build-release-fp64on/libAppGL.dylib`,
    UUID `B30E9F60-43A2-36B5-BA7D-8981FEA98792`, SHA256
    `0fb708248842698dea1b4fd0f9388891b5217d85058dbc7798bbd0103dc27978`,
    codesign valid on disk, install-name `@rpath/libAppGL.dylib`. Build
    completed with only the known `MTLResourceUsageSample` and
    duplicate-library warnings.
  - Scout dispatch message:
    `7f8d9d76-307e-452a-ab31-634c6dddf305`
    (`s24-c48-sweep2-default-35df142`). Packet explicitly requested default
    config, Item 75 shader-preservation breadth (`shaders.*`,
    `texture_repeat_mode`, `draw_indirect`), texture compare/shadow,
    FBO-rendered depth compare, layered_framebuffer, and uploaded-depth
    negative-control attention. Sweep 3 remains held behind Sweep 2.
  - Hygiene follow-up `5211b216-9dd1-4aba-a3be-b708c0443ea3` told Scout to
    run exact clean `35df142` or an isolated worktree pinned to it, because
    post-dispatch uncommitted census instrumentation appeared in
    `src/context/AppGLCommandReasons.h` and
    `src/context/MetalCommandSubmission.h`. Those edits are not part of Sweep 2
    unless Foreman/Clerk explicitly retarget.
  - Fable-Clerk standing rule: Scout sweeps always run from an isolated checkout
    pinned to the target SHA, using the `scout-worktree/` lane, never the
    shared AppGL working tree. Follow-up
    `3b03bf06-8bc1-4d63-9ad1-a03dbf9253cd` applied this to current Sweep 2 and
    requested checkout path, artifact/source SHA echo, and cleanliness/pin
    proof in the result report.
  - Scout progress update `2b0fec79-3771-4814-ac2d-b15bb5d2082a` confirmed the
    standing rule is in effect. Sweep 2 is running from isolated checkout
    `$PROJECT_ROOT/scout-worktree/checkouts/appgl-c48-sweep2-35df142`,
    pinned to full SHA `35df14294132a421b49cce55f75e49933684fb88`, with clean
    pre-build `git status --short`. Scout populated ignored vendored
    third-party dirs from the local main tree for build only. Release fp64-on
    artifact:
    `$PROJECT_ROOT/scout-worktree/checkouts/appgl-c48-sweep2-35df142/gate-artifacts/35df142-s24-c48-sweep2-default-off/libAppGL.dylib`,
    SHA256 `90e84aa4bc7ada5cec72e3161a71b5b474e5599cfe0e80ba595450e7c6a95a98`,
    UUID `5D196FE0-5C29-31FA-AB06-2568EE376BA1`, release-shape PASS. Full CTS
    default/no-forward-env is running with C48 flags explicitly unset inside
    GLCTS subshells. Report root:
    `$PROJECT_ROOT/scout-worktree/reports/full-cts-s24-c48-sweep2-35df142-default-off`.
  - Sweep 1 disposition from Scout
    `7f8da07b-c2e8-4f3c-8e0c-8f7764bd5b35`: skipped/not completed. Scout had
    only held/read the original Sweep 1 dispatch and inspected/preflighted
    scripts; no full CTS run launched, no `bdd2c14`/`6be0120` artifact was
    built or published, and there is no report artifact to recover. Do not
    rerun Sweep 1 separately. Sweep 2 at exact `35df142` will explicitly call
    out layered-FBO/layered_framebuffer and related FBO/depth-compare coverage
    as satisfying the Sweep-1 default-path slice-fix role. F->P flips there are
    expected fix signal; P->nonPass or P->F still escalates under isolate
    discipline.
  - Sweep 2 progress `2d2b1357-d170-43d5-8d42-57fbada11883`: nonshader chunks
    `ns15_aa` through `ns15_ae` are all `1500/1500` first try. `ns15_af`
    (historically slow fp64-heavy chunk) started at local `23:27`. No final
    report/retry/regression analysis yet.
  - Sweep 2 progress `5a36afbf-3178-4fcc-9a67-8e489b7437d5`: `ns15_af`
    completed first try `1500/1500` after the expected fp64-heavy interval.
    Current nonshader chunks `ns15_aa` through `ns15_af` are all clean
    first-try `1500/1500`; sweep advanced to `ns15_ag`.
  - Sweep 2 final from Scout
    `2945f8d5-4ff4-4564-ade6-3471ae1c38c0`: exact `35df142`
    default/no-forward-env is GREEN versus the `d28b150` crown baseline.
    Candidate and baseline both completed `19716/19716` with
    `P=19365 F=36 NS=314 IE=1`; status transitions `0`, `P->nonPass=0`,
    `P->F=0`, duplicate records `0`, status maps identical `1`, incomplete
    chunks `0`. All nonshader chunks were first try, including `ns15_af` and
    `ns15_aj`; shader shards completed. Delta files are header-only, so no
    isolate probes were required.
  - Sweep 2 final QPA proof:
    candidate
    `scout-sweep-s24-c48-sweep2-candidate-35df142-default-off-2026-06-09.qpa`
    SHA256
    `270cb2bb3d87e61abd4d701c18d0886ebc4b2a520f115a7b70fc85c9ae68a8f7`;
    reused baseline
    `scout-sweep-s24-baseline-d28b150-crown-default-off-reused-2026-06-08.qpa`
    SHA256
    `1dd178e33313389c944e555b831b778699da9d9ed0be6f7196bd9c217b190da3`.
  - Layered-FBO/default-path coverage callout from the green result:
    `geometry_shader.layered_framebuffer.blending_support`,
    `clear_call_support`, `depth_support`, and `stencil_support` are present in
    the candidate map and Pass;
    `direct_state_access.framebuffers_texture_layer_attachment` Pass;
    shadow/depth-array related rows are present and Pass; watched
    `draw_indirect.*` surface rows Pass; the broad `shaders.*` map has no
    transitions. This satisfies the default-path/layered-FBO evidence role for
    the superseded `35df142` target.
  - Updated read guidance after the `35df142` helper-scope root cause:
    compare-suite failures may be the now-known y-flip helper bug rather than
    predicate overreach. Grep one failing case for undeclared
    `_appgl_CmpFlip` in the test log; classify that cluster
    `KNOWN-BUG-SUPERSEDED` while preserving layered-FBO/slice-fix evidence.
    The helper-shape fail list should feed Worker's new probe coverage.
  - Disposition sent to Scout in bridge message
    `61425f62-5456-4171-b52f-baae806b5b67`: do not launch a `35df142` forward
    Sweep 3. The green Sweep 2 is evidence, not a crown, because `35df142` is
    now superseded by the helper-scope shadow-compare bug. The next Scout
    dispatch waits for Worker to land the replacement fixed SHA and for
    Fable-Clerk to clear the isolated-checkout packet.
  - Fable-Clerk accepted the final in message
    `f172dbd5-5845-4dab-94a7-986eb2b0a225` and explicitly hardened the gate
    read: this full CTS run used a build now known to beachball live Warzone,
    yet returned `19716/19716` identical to baseline with zero compare-suite
    failures. CTS contains no helper-function-shaped compare-sampling coverage
    for this class. This is the second CTS-invisible live-critical defect in
    the C48 lane: the slice-routing bug also produced no layered-suite `F->P`
    flips, meaning CTS did not exercise the broken live layer path either.
    Therefore full-CTS-green is necessary-not-sufficient for live correctness.
    Helper-shaped local probes, GLTest synthetic coverage, and the live
    full-frame render-validation lane are required gates for this class; the
    S24 Phase-6 render-validation anchor is no longer optional/nice-to-have.

Post-fix sweep plan after Worker landed replacement SHA `d73c6e1` on top of
`e2a876d`:

1. Build and dispatch a fixed-SHA default/no-forward-env full sweep from an
   isolated clean Scout checkout pinned to that SHA.
2. If default greens, dispatch the fixed-SHA forward-config crown sweep
   (`APPGL_ENABLE_LAYERED_CLEAR_ASYNC=1`,
   `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`,
   `APPGL_ENABLE_FBO_CLEAR_FOLDING=1`).
3. No new operator package until the fixed SHA greens locally and Fable-Clerk
   clears the package.

Pre-authorized downstream sequence from Fable-Clerk
`6d8d6827-8698-4da5-a61e-8f25df38ee36`:

- Operator is away until afternoon, with remote dashboard check-ins only.
  Milestone digests should go to `_ui` with `requires_user:false` at Sweep B
  result, formal A/B result, C49 implementation landed, and crown
  adjudication.
- If Sweep B is GREEN, automatically grant GLTest their formal C48 measurement
  window with no further Clerk signal: vendor the `d73c6e1` build into
  `ogltest` per freshness rule with UUID verification, then run formal C48
  synthetic A/B fold-vs-control arms with hard assertions and distribution data
  (`low1PctMeanMs` plus histograms). Results plus existing evidence go to
  Clerk for C48+fix-chain crown adjudication.
- If Sweep B is NOT GREEN, hold everything downstream, run isolated probe per
  Worker's triage pre-plan, and escalate to Clerk at high severity immediately.
- C49 SHAs from Worker should be verified for commit structure and local gate
  evidence, then queued behind the C48 chain. No C49 sweep dispatch before
  Clerk clears the C48 crown. Intended C49 train: GLTest synthetic A/B with C49
  arms, default sweep, forward sweep, then live re-profile.
- Anything anomalous gets high severity to Clerk immediately.

Sweep A dispatch:

- Bridge message `24d91324-3368-433a-82c7-0ccf8485373d` dispatches Scout's
  fixed-SHA default/no-forward full CTS at exact
  `d73c6e1f94ec382476433efcf583ab9344f78f71`.
- Requirements: isolated checkout under `scout-worktree`, exact pin proof,
  clean pre-build status, release fp64-on/vendor-third-party build, C48 flags
  explicitly unset in GLCTS subshells, UUID/SHA/install-name/codesign proof,
  and comparison against the reused `d28b150` crown baseline.
- Risk surfaces repeated because the fix touches translator and compile-cache
  behavior: Item 75 shader-preservation breadth (`shaders.*`,
  `texture_repeat_mode`, `draw_indirect.*`), texture compare/shadow/depth
  compare suites, FBO-rendered depth compare, helper-function-shaped compare
  sampling, layered-FBO/layered_framebuffer/default-path coverage, and loud
  bounded compile-failure behavior if any shader compile fails.
- Sweep B forward/crown remains held until Sweep A greens and
  Foreman/Fable-Clerk dispatch it.
- Scout ACK/progress `69f888d5-d2d8-488f-aef9-b74e5c588133`: Sweep A is in
  progress from isolated checkout
  `$PROJECT_ROOT/scout-worktree/checkouts/appgl-d73c6e1-sweepA-default`,
  full SHA `d73c6e1f94ec382476433efcf583ab9344f78f71`, tracked pre-build
  status clean. Ignored vendored `third_party/glslang` and `SPIRV-Cross` were
  populated from the local main tree for `APPGL_VENDOR_THIRD_PARTY=ON` build
  input. Report root:
  `$PROJECT_ROOT/scout-worktree/reports/full-cts-s24-d73c6e1-sweepA-default-off`.
  Release fp64-on build is underway with only expected
  `MTLResourceUsageSample` warnings so far; default CTS will explicitly unset
  async, sampler skip, and FBO folding in GLCTS subshells. Sweep B remains
  held.
- Scout artifact proof `9afbb2e6-f1a9-41cd-902d-3cf31762e084`: release fp64-on
  build completed and gate artifact was published at
  `$PROJECT_ROOT/scout-worktree/checkouts/appgl-d73c6e1-sweepA-default/gate-artifacts/d73c6e1-s24-sweepA-default-off/libAppGL.dylib`,
  SHA256 `08418657e3395a2963e28d4f93e98e4477b86406b730a3fd2aebc6bbc13e9dab`,
  UUID `42FF9E75-3374-33CF-85A1-29682C6D5A90`, release shape PASS. Build
  warnings only the expected `MTLResourceUsageSample` deprecations and
  duplicate-library linker warning. Full CTS default/no-forward-env has
  started with `ns15` chunks `12`, shader shards `80`, and `ns15_aa` started
  local `00:07:54`.
- Scout progress `f87fecf0-fd4d-4e50-a907-b42d01dd4df1`: `ns15_aa` through
  `ns15_ae` completed first try `1500/1500`; `ns15_af` started local
  `00:13:18` and is expected to be the slow fp64-heavy interval. No
  retries/resumes/incomplete chunks so far.
- Scout progress `9f1c3995-3675-4385-ad91-a82fa7752621`: nonshader chunks are
  clean first-try `1500/1500` through `ns15_ai`. `ns15_aj` hit the inherited
  short-complete pattern (`1019/1500` on try 1 and try 2); canonical resume
  from line `1020` for the remaining `481` cases started local `00:21:59`.
  Scout infers no candidate regression while awaiting the resume-combined
  count.
- Scout final `f15299e8-e65a-4831-ad36-fb30daa1144a`: exact `d73c6e1`
  default/no-forward-env full CTS is GREEN versus `d28b150`. Candidate
  completed `19716/19716` in about `17m` candidate time / about `20m` wall
  clock with counts `Pass=19365 Fail=36 NotSupported=314 InternalError=1`;
  baseline counts are identical. Status transitions `0`, `P->nonPass=0`,
  `P->Fail=0`, duplicate status records `0` baseline and candidate,
  incomplete chunks `0`, and `status_maps_identical=1`.
- Sweep A final proof:
  - checkout:
    `$PROJECT_ROOT/scout-worktree/checkouts/appgl-d73c6e1-sweepA-default`;
    source `d73c6e1f94ec382476433efcf583ab9344f78f71`; baseline
    `d28b15056c104c50cae9fb9a766a48471065d843`; source status clean before
    build and post-build tracked tree unchanged except expected untracked
    `gate-artifacts/`.
  - artifact:
    `$PROJECT_ROOT/scout-worktree/checkouts/appgl-d73c6e1-sweepA-default/gate-artifacts/d73c6e1-s24-sweepA-default-off/libAppGL.dylib`,
    SHA256 `08418657e3395a2963e28d4f93e98e4477b86406b730a3fd2aebc6bbc13e9dab`,
    UUID `42FF9E75-3374-33CF-85A1-29682C6D5A90`, install name
    `@rpath/libAppGL.dylib`, ad-hoc/linker-signed codesign, release shape
    PASS. Config was Release, fp64 ON, vendor third-party ON, ASAN OFF, DCR
    sentinel hooks OFF.
  - report root:
    `$PROJECT_ROOT/scout-worktree/reports/full-cts-s24-d73c6e1-sweepA-default-off`;
    candidate QPA
    `scout-sweep-s24-sweepA-candidate-d73c6e1-default-off-2026-06-10.qpa`,
    SHA256
    `8fce7c96a582f83701648653c14221cf02bc305e1205e45307860ce0b19321e5`;
    reused baseline QPA
    `scout-sweep-s23-wz-uaf-ui-fix-d28b150-default-off-2026-06-08.qpa`,
    SHA256
    `1dd178e33313389c944e555b831b778699da9d9ed0be6f7196bd9c217b190da3`.
  - Delta files are header-only:
    `status-changes-vs-d28b150.tsv`,
    `p_to_nonpass-vs-d28b150.tsv`, `p_to_fail-vs-d28b150.tsv`, and
    `duplicate-results.tsv`.
- Retry/resume/risk-surface read for Sweep A: `ns15_aa` through `ns15_ai`
  clean; `ns15_aj` short-completed twice at `1019/1500`, then canonical resume
  from line `1020` completed `481/481`; `ns15_ak`, `ns15_al`, and shader
  shards completed. Watched rows for `draw_indirect.*`,
  `framebuffers_texture_layer_attachment`, `layered_framebuffer.*`, texture
  shadow/depth compare, layout/negative texture lookup shadow, and broad
  `shaders.*` are Pass; full-suite transition count `0` covers the rest. No
  `_appgl_CmpFlip` hits, MSL compile failures, or helper signature/call
  threading errors were found in stderr scan. `ns15_aj` stderr residue was AGX
  texture read/write `bytes_per_row` assertions plus expected CTS preprocessor
  test names containing "error"; final status-map identity makes it
  non-regressive.
- Sweep B dispatch:
  - Bridge message `3c6b2836-4848-4504-87bd-3d5d5bbe2389` dispatches exact
    `d73c6e1f94ec382476433efcf583ab9344f78f71` FORWARD config crown sweep.
  - Required GLCTS subshell env:
    `APPGL_ENABLE_LAYERED_CLEAR_ASYNC=1`,
    `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`, and
    `APPGL_ENABLE_FBO_CLEAR_FOLDING=1`.
  - Standing isolated-checkout rule remains in force; suggested checkout label
    `appgl-d73c6e1-sweepB-forward`. Report UUID/SHA/install-name/codesign,
    source cleanliness, QPA hashes, transitions, `P->nonPass`, `P->Fail`,
    duplicate rows, incomplete chunks, retry/resume/isolate activity, and
    watched surfaces across layered clear async, sampler GPU-order skip,
    FBO folding, d73 compare fix, shader translator breadth, and compile-cache
    health. If green, Scout must hold for Foreman/Fable-Clerk crown
    bookkeeping and not promote/pin automatically.
  - Scout ACK/startup `abacda0a-f61a-406c-80e6-0d04a1e68c45`: Sweep B is
    running from isolated checkout
    `$PROJECT_ROOT/scout-worktree/checkouts/appgl-d73c6e1-sweepB-forward`,
    HEAD `d73c6e1f94ec382476433efcf583ab9344f78f71`, pre-build tracked status
    clean. Ignored vendor inputs `third_party/SPIRV-Cross/` and
    `third_party/glslang/` were populated from the local main tree. Runner:
    `$PROJECT_ROOT/scout-worktree/scout-scripts/full_cts_s24_d73c6e1_sweepB_forward.sh`;
    report root:
    `$PROJECT_ROOT/scout-worktree/reports/full-cts-s24-d73c6e1-sweepB-forward`.
    Forward env check passed inside GLCTS subshells for layered-clear async,
    sampler GPU-order skip, and FBO clear folding. Baseline source is the
    available `d28b150` crown default-off QPA reused from Sweep A; Scout has no
    separate `d28b150` forward QPA in reports. Build is underway with only
    expected `MTLResourceUsageSample` deprecation warnings so far.
- Scout artifact proof `b4118e12-c2c5-4177-ac9f-d33164763dbc`: build/artifact
  complete and CTS started. Artifact
  `$PROJECT_ROOT/scout-worktree/checkouts/appgl-d73c6e1-sweepB-forward/gate-artifacts/d73c6e1-s24-sweepB-forward/libAppGL.dylib`,
  SHA256 `244f3978c0d1c1140312f6c9bbe356aacf1a0938f69db2ca3d9f7dd2000d5226`,
  UUID `0B4B1965-ACEB-3CED-A6BF-9E2F695EA182`, release shape PASS, provenance
  log at
  `$PROJECT_ROOT/scout-worktree/reports/full-cts-s24-d73c6e1-sweepB-forward/provenance.log`.
  CTS is now running with 12 ns15 chunks and 80 shader shards; forward
  toggles remain exported inside the `run_one` GLCTS subshells.
- Scout progress `e21bb595-01ee-4763-a4ba-c7aa3eacda94`: Sweep B CTS remains
  clean so far. `ns15_aa` through `ns15_ae` completed first try `1500/1500`
  under forward env, and `ns15_af` is running now. No retry/resume/isolate
  activity yet.
- Scout follow-up `e3f60eb2-a36a-41ba-bdad-f21c99126532`: Sweep B has moved
  through `ns15_ah` cleanly on first try `1500/1500`; `ns15_ai` is running
  now. Still no retry/resume/isolate activity.
- Scout follow-up `ee0874a0-11f1-4306-a4f5-7fc4eb041be9`: `ns15_aj` hit the
  inherited short-complete pattern at a new boundary, with try1 completing
  `1335/1500`. Canonical try2 is running now; if it also short-completes, the
  runner will resume from `got+1` and combine as usual. No candidate
  regression is inferred yet.
- Scout final `ec0c6089-289e-4888-b544-90b89258ce70`: Sweep B forward CTS is
  complete but NOT GREEN vs `d28b150`. Final counts are `19363/19365` pass,
  `38` fail, `314` not-supported, `1` internal error, with two status
  transitions and two `P->Fail` regressions. The only delta rows are
  `KHR-GL46.blend_equation_advanced.test_coherency.mixedSequence` and
  `.multiplySequence`, both Pass -> Fail with RGBA mismatches, so the gate is
  red for concrete blend-equation regressions rather than broad flakiness.
  stderr was also non-clean due to MSL negative-cache and AGX texture
  assertion lines, but the decisive red gate is the pair of blend regressions.
  Do not promote or pin from this result.

C49 is banked as FBO pass continuation after C48. Do not open the pass-
continuation implementation before the C48 sweep/default-path proof settles,
because the C48 slice fix can change shadow correctness independent of
performance and the folding feature has explicit clear-coherence risk surfaces.

C49 census instruments are complete in observation-only commit `e2a876d` on top
of `35df142`, but this does not retarget active Sweep 2. Worker reported full
sentinel + C48 + orientation gates green in default and forward configs, with
BAR-B readback pixels identical. The commit exports standard diagnostics JSON
fields under `metalResources.frameGraph.*` and `.commandBuffers.*`:
encoder opens split FBO/default-FB, closes by reason
(`FboTargetChange`, `ShadingRateChange`, `ViewportRequestInvalidate`,
`Readback`, `CommandBufferCommit`, `Clear`), translated draw encode calls,
pass descriptor builds and build microseconds, baseline-zero continuation
counters, and unconditional `drainAllCalls` / `drainAllWaitUsTotal`. It also
fixes `APPGL_FRAME_ATTRIBUTION_PROFILE` 0-row live captures by emitting
cumulative stderr snapshots every 600 presents when enabled.

First capture on the `e2a876d` lineage should validate the pre-registered C49
premise before implementation: FBO encoder opens per frame should roughly track
FBO translated draws per frame, FBO draws-per-pass should be about `1`, and FBO
closes should be dominated by `FboTargetChange`. If baseline contradicts that,
re-examine the C49 pass-continuation premise before coding.

00:00 operator preview package from `e2a876d` is withdrawn for operator use.
It remains documented as an informal unswept artifact with canonical pin
untouched:

- Preview dylib:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-e2a876d-preview-9F9A494B.dylib`,
  UUID `9F9A494B-CBEE-368A-8F31-5A1C89541830`, SHA256
  `60f4bc5cd46b1449de27718c901ab56ddd09a40f7b1edfd4a38ffabe56e73681`,
  codesign valid on disk, install-name `@rpath/libAppGL.dylib`.
- Canonical `libAppGL-pinned.dylib` remains `A8483891` /
  `da11d5d25072d313b7d845d6b421b12557056cefdb282a13fd8a060c5cb915db`.
- Operator launcher:
  `$PROJECT_ROOT/live-targets/appgl-bridge/launch-warzone-appgl-e2a876d-operator-preview.sh`.
  It sets forward config (`APPGL_ENABLE_LAYERED_CLEAR_ASYNC=1`,
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`,
  `APPGL_ENABLE_FBO_CLEAR_FOLDING=1`), diagnostics JSON, and
  `APPGL_FRAME_ATTRIBUTION_PROFILE=1`, and writes proofs under
  `memory-runs/e2a876d-operator-preview/<timestamp>/proofs/`.
- Withdrawal guard: the launcher now exits `64` unless
  `APPGL_ALLOW_WITHDRAWN_E2A876D_PREVIEW=1` is explicitly exported. This is a
  safety guard only; do not use the override for operator acceptance.
- Build provenance for the withdrawn preview:
  `$PROJECT_ROOT/appgl-runtime/build-release-fp64on`,
  source HEAD `e2a876d`, built with
  `cmake --build .../build-release-fp64on --target AppGL -j 10`.
  Cache proof: `CMAKE_BUILD_TYPE=Release`,
  `CMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG`, `APPGL_FP64_EMULATION=ON`,
  `APPGL_VENDOR_THIRD_PARTY=ON`; no `-O0` trap observed. Build artifact mtime
  was `Jun 9 23:25:23 2026`; preview copy mtime was `Jun 9 23:25:54 2026`.
- Operator watchpoints: shadows correct versus native control, especially far
  cascades; no viewport-shadow artifact; no new clear/flicker/stale-frame
  artifacts; rough FPS. Treat FPS as informal because Sweep 2 is concurrently
  running and may depress readings. Capture also provides the first C49
  kill-switch baseline if the scene is operator-comparable.
- Dashboard package originally sent to the operator as requires-user message
  `a3ab4a98-dc4c-4a81-a040-0a9a51d910b7`, then canceled/withdrawn after the
  operator observed severe live regression: about one frame per `10s`,
  beachball/unresponsive. The known-good informal preview for play meanwhile is
  still `launch-warzone-appgl-c48-preview.sh` / B52F0178.
- Confirmatory discriminator artifacts:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/e2a876d-regression-discriminator/20260610T065012Z`.
  Arm A (`e2a876d` + preview env) reproduced the stall:
  `bridgeFrame=1` at `30s` and `60s`, final `bridgeFrame=1` /
  `flushBuffer=55` over `120s`. Arm B (`e2a876d` + canonical env, diagnostics
  and frame attribution unset) still crawled: `flushBuffer=42` at `30s`,
  `46` at `60s`, final `55`, exonerating diagnostics/attribution env as the
  primary trigger. Arm C (`35df142` Sweep-2 artifact + preview env) was stopped
  after Clerk canceled the now-confirmatory run, but its `30s` and `60s`
  samples also showed `bridgeFrame=1` with `flushBuffer=41/46`, matching the
  helper-scope root-cause prediction. Arm D was intentionally not run.

`d73c6e1` operator preview package is staged as an unswept visual/census
package; crown gates remain pending:

- Preview dylib:
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-d73c6e1-preview-42A8548D.dylib`,
  UUID `42A8548D-5775-30DA-BA00-A1C60A7EE427`, SHA256
  `754310432eb14c6e18ab2556469cf3405ecdbc23b8fc399f6a8210ac8378c933`,
  codesign valid on disk, install-name `@rpath/libAppGL.dylib`.
- Build provenance:
  `$PROJECT_ROOT/appgl-runtime/build-release-fp64on`,
  source HEAD `d73c6e1f94ec382476433efcf583ab9344f78f71`,
  built with `cmake --build .../build-release-fp64on --target AppGL -j 10`.
  Cache proof: `CMAKE_BUILD_TYPE=Release`,
  `CMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG`, `APPGL_FP64_EMULATION=ON`,
  `APPGL_VENDOR_THIRD_PARTY=ON`, `APPGL_ENABLE_ASAN=OFF`,
  `APPGL_DCR_SENTINEL_HOOKS=OFF`. Build warnings only the expected
  `MTLResourceUsageSample` deprecations and duplicate static-library linker
  warning.
- Canonical `libAppGL-pinned.dylib` remains `A8483891` /
  `da11d5d25072d313b7d845d6b421b12557056cefdb282a13fd8a060c5cb915db`.
- Operator launcher:
  `$PROJECT_ROOT/live-targets/appgl-bridge/launch-warzone-appgl-d73c6e1-operator-preview.sh`.
  It sets forward config (`APPGL_ENABLE_LAYERED_CLEAR_ASYNC=1`,
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`,
  `APPGL_ENABLE_FBO_CLEAR_FOLDING=1`), diagnostics JSON with interval `60`,
  and `APPGL_FRAME_ATTRIBUTION_PROFILE=1`, and writes proofs under
  `memory-runs/d73c6e1-operator-preview/<timestamp>/proofs/`.
- Dashboard package posted to the operator in bridge message
  `a0135720-e273-456b-969e-7e84dc1a5a1e`. Goals: visual shadows correct vs
  native and no artifacts/responsiveness regression; collect C49 kill-switch
  census baseline; FPS may be depressed while sweeps grind.
- Operator preview verdict relayed by Fable-Clerk in message
  `d0c53f5f-f1d2-420b-a300-86926fdecccf`:
  "frame rate restored to 24fps; SHADOWS FIXED; everything visually correct as
  far as operator can discern." This is informal visual acceptance: beachball
  gone, viewport-shadow gone, far cascades correct for the first time in
  project history.
- C49 kill-switch artifact root:
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/d73c6e1-operator-preview/20260610T072054Z`.
  Primary payload is `appgl-diagnostics.jsonl` (`48` samples, `8,501,872`
  bytes, bridgeFrame `1 -> 2820`) plus proof files under `proofs/`. The
  launcher-owned artifact tree has diagnostics/proofs only; no stdout/stderr
  capture file is present, so any `APPGL_FRAME_ATTRIBUTION_PROFILE` stderr
  snapshots from this manual launch were terminal-only. `proofs/run-env.txt`
  confirms `APPGL_FRAME_ATTRIBUTION_PROFILE=1`, diagnostics JSON path,
  diagnostics interval `60`, and forward config ON.
- Final C49 diagnostics sample at bridgeFrame `2820`: `encoderOpensFboDraw`
  `345731`, `encoderOpensDefaultFb` `2819`, `translatedDrawEncodeCalls`
  `551644`, `passDescriptorBuilds` `348550`, `passDescriptorBuildUsTotal`
  `1907614`, `encoderClosesFboTargetChange=0`,
  `encoderClosesViewportRequestInvalidate=4808`, `encoderClosesReadback=2`,
  `encoderClosesCommandBufferCommit=2817`, `fboClearsDeferred=12020`,
  `fboClearsFolded=12020`, `fboClearsMaterialized=0`,
  `submittedCommandBuffers=5593`, `FlushForReadback=2408`,
  `PressureFlush=365`, `commandBuffers.drainAllCalls=2404`,
  `commandBuffers.drainAllWaitUsTotal=10418030`, MSL library cache
  `entries=29` / `misses=29` / `hits=5679`, pipeline cache
  `entries=2854` / `hits=548790` / `misses=2854` / `buildFailures=0`,
  and `errorLog` length `0`.
- Kill-switch payload handed to Fable-Worker in bridge message
  `f8fda3e9-74cf-4f31-a580-5cf90679d07a` for the pre-registered verdict:
  whether FBO encoder opens per frame track FBO draws per frame, whether
  FBO-target draws-per-pass is about `1`, whether closes are dominated by
  `FboTargetChange`, and how the first live attribution/diagnostic
  decomposition re-ranks C49 lever order.
- Fable-Worker kill-switch verdict `bed2671b-d931-4ae5-b13a-86e63fe4f70b`:
  PASS; the C49 pass-continuation premise is confirmed, no recapture needed.
  Over `2819` frame delta (about `117.5s` at restored `24 FPS`),
  `encoderOpensFboDraw` is `122.6/frame` versus about `6` logical GL passes,
  about `20x` pass churn. `translatedDrawEncodeCalls` is `195.7/frame`, so
  draws per FBO pass are about `1.2`, matching the pre-registered
  approximately-one prediction. `passDescriptorBuilds` is `123.6/frame` at
  about `677us/frame`, and that only counts descriptor construction, not
  encoder allocation, cached-state reset, or GPU tile load/store round trips.
- C49 attribution refinement: `encoderClosesFboTargetChange=0` because the
  close happens at every FBO draw encode tail, not at the next draw head.
  Primary C49 edit site is the encode-tail close in `MetalFrameGraph.mm`
  around `8168`; implementation should close only on signature
  change/consumption and add an `encoderClosesFboDrawTail` counter for A/B.
- C49 rider value increased: `encoderClosesViewportRequestInvalidate` is about
  `1.7/frame`; `drainAllCalls` is about `0.85/frame`; `drainAllWaitUsTotal`
  is `10.42s / 117.5s`, about `8.9%` of wall, or about `4.3ms` per drain.
  The `ensureSizeAtLeast` / viewport-invalidate rider is now the single largest
  measured live wait in this frame.
- C48 forward engagement in the operator run is crown-grade: deferred clears
  `12020` equal folded clears `12020`, materialized `0`, coalesced `0`, about
  `4.26` folds/frame; zero LayeredClear submits; command buffers per frame
  `5593/2819 = 1.98`, matching the predicted about-`2` shape. Runtime health:
  `29` MSL library compiles total, no compile storm, pipeline build failures
  `0`, errorLog empty, and completed command buffers equal submitted minus one
  in-flight sample.
- Attribution stderr caveat: periodic `APPGL_FRAME_ATTRIBUTION_PROFILE`
  snapshots went to the terminal because the operator launcher does not capture
  stderr. Future preview/capture roots should add `2>>"$RUN/stderr.log"` to
  the launcher/capture wrapper. Not blocking for this verdict because the C49
  diagnostics counters carried the decomposition.
- C49 recommendation from Worker: GO when Fable-Clerk calls it, with the
  primary pass-continuation edit at the FBO draw encode-tail close plus the
  `ensureSizeAtLeast` viewport-invalidate rider, using the approved memo's
  pass-signature design and parity-risk list. Do not start implementation until
  Clerk/roadmap cadence calls the C49 lane.
- Fable-Clerk issued C49 GO to Worker in message
  `668877bc-628c-4042-b886-d834f331967b`. Gate train after Worker SHAs:
  local gates, GLTest synthetic A/B, sweeps, then live A/B. Clerk also set an
  eventual Step-1-style re-profile target: post-C49+rider should approach about
  `1.1` command buffers/frame (draw plus present) and near-zero hard waits,
  verifying the structural ledger zeroes out.
- Wrapper fix after the kill-switch run: both run-rooted operator wrappers
  (`launch-warzone-appgl-d73c6e1-operator-preview.sh` and guarded
  `launch-warzone-appgl-e2a876d-operator-preview.sh`) now record
  `stderr_log=$RUN/stderr.log` in `proofs/run-env.txt`, echo the stderr path
  before launch, and run Warzone with `2>> "$RUN/stderr.log"` so future manual
  preview runs persist `APPGL_FRAME_ATTRIBUTION_PROFILE` snapshots.
- Crown bookkeeping after visual acceptance: C48+fix chain now has visual
  acceptance, green `35df142` default Sweep 2 evidence, green `d73c6e1`
  default Sweep A, Sweep B pending, and formal instrumented live A/B pending.
  No crown until Sweep B and the formal A/B land. Sweeps continue per plan.
- Clerk has now tightened the C49 order around the landed implementation SHAs:
  `1123b43` carries the viewport-request keepalive rider and `b5d4cf4`
  carries the primary FBO render-pass continuation. The next lane is a single
  additional Worker commit on top of `b5d4cf4` for the approved
  skip-posture hygiene flip; that commit is now `1ef873b`. Once Sweep B
  greens, the GLTest window should run both C48 formal A/B and C49 synthetic
  A/B against `1ef873b`, then the C49 sweep train should target `1ef873b`
  first in default mode and then in full-forward mode. The operator forward
  preview should also be built from `1ef873b` after the C49 sweeps green.
- Worker follow-up `21fdfcbd-f949-4070-82b9-8f77bfdebe10` and Clerk
  confirmation `fb92ab97-1389-4267-8688-4621baf14c83`: `1ef873b` is skip
  default-ON, the rollback hatch is `APPGL_DISABLE_SAMPLER_GPU_ORDER_SKIP=1`,
  and `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=0` still works for legacy harness
  arms. The default/no-env sweep now doubles as the real skip gate, so future
  packet wording should treat CTS skip-coverage evidence as first-class signal,
  not just regression absence. Launcher export removal stays pending until the
  `1ef873b` default sweep greens.
- Clerk gate ruling `63aabee1-ca17-4141-a36e-3fef533eff87`: Sweep B is RED
  and the C48 crown chain is HALTED. The combined GLTest window does not
  auto-grant, C49 stays queued, and nothing should be pinned or promoted from
  the forward result. Sweep A green and Sweep 2 green remain default-path
  evidence only. The new triage thread is `s24-sweepB-blend-triage`; Worker
  owns analysis, Scout owns the isolated probes, and results should be routed
  there. The two failing rows are still the blend_equation_advanced
  coherency cases.
- Scout triage final `66ab6dc3-18ac-45de-b828-3ebf47a409ab`: the isolated
  probe matrix is decisive. `APPGL_ENABLE_FBO_CLEAR_FOLDING` alone reproduces
  both blend_equation_advanced coherency failures, while
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP` alone, `APPGL_ENABLE_LAYERED_CLEAR_ASYNC`
  alone, and the no-hatch control all pass. Forward-all fails because it
  includes folding. The folded-arm failure signatures are exactly the two
  Sweep B rows, and the probe bundle lives under
  `reports/s24-sweepB-blend-triage/`.
- Worker triage verdict `a2778c89-9e12-41c5-8252-3b0e47b7cc97`: the fold
  regression is root-caused and fixed in SHA `1104215`, with the crown chain
  ready to resume from the new SHA. The root cause is a write-before-
  materialize hazard in the CPU-emulated advanced-blend path: the CPU blend
  tail writes via direct `[MTLTexture replaceRegion:]` in
  `handleAdvancedBlendDraw` (`GLContext.mm:19802`), leaving the deferred clear
  pending so the next GPU draw folds stale clear state over the blended texels.
  The fix materializes pending FBO clears for the texture at both the blend
  tail replaceRegion site and the sibling `mirrorDepth/StencilRenderbufferRegionToMetal`
  path. H2/H3 were eliminated; the stderr residuals were pre-existing compile
  classes, and the blend chunk stderr is clean.
- Clerk consolidated plan `b3b9633e-5b8a-4a1c-b4ac-9ed025cd7382`: resume the
  crown chain at `1104215` with two sweeps only. Sweep C is `1104215`
  default/no-env and doubles as the real skip gate; Sweep D is
  `1104215` full-forward (continuation+keepalive+async+skip+fold). Once both
  are green, grant the GLTest window for C48 formal A/B plus C49 synthetic A/B
  and then package the crown adjudication for Clerk. The operator preview
  package should also come from `1104215` full-forward after the sweeps green.
  When the next run emits the known negative-cache stderr residuals, classify
  them as the pre-existing S22 compile classes Clerk named, not as new
  regressions.
- Sweep C dispatch `a463e766-c437-4c1b-9d58-465afbc53f20`: Scout was sent
  the `1104215` default/no-env run with the stderr-residual classification
  note. Sweep D remains queued behind it until Sweep C reports green. Clerk
  was notified with the dispatch ID `9edfa1e0-73ca-414d-bfaf-d8518237a64e`.
- Scout startup `260f45e8-65e6-4e3f-a4b3-13b26c185964`: Sweep C is running in
  isolated checkout `appgl-1104215-sweepC-default` from target SHA
  `1104215edd092695887f62ca206be7c5bb038782` with tracked status clean and
  the default/no-env runner active. The stderr-residual classification note is
  in provenance, and Sweep D remains untouched.
- Scout artifact `992d9669-3846-4568-92eb-67fb9e2846c4`: Sweep C built and
  published `libAppGL.dylib` at
  `.../gate-artifacts/1104215-s24-sweepC-default-off/libAppGL.dylib`, SHA256
  `d99547f12b07fe3ce571df4755789ea1a05f22947d8cba0731a7b47f8e4e66fc`,
  UUID `4CFF10EC-A0F1-35EC-9318-BA7C3E41344E`, release shape PASS, and CTS is
  now running with 12 ns15 chunks plus 80 shader shards under default/no-env.
- Scout progress `7db24d60-9d6b-4dcb-8479-fb5d2c751aa4`: ns15_aa through
  ns15_ad completed first try `1500/1500` under DEFAULT/no-env, `ns15_ae` is
  running, and no retry/resume/isolate activity has appeared yet. Sweep D is
  still untouched.
- Scout follow-up `529dab4c-3714-478c-bbd8-17973bd52074`: `ns15_aa` through
  `ns15_ag` are clean first-try `1500/1500` under DEFAULT/no-env, `ns15_ah`
  is running, and no retry/resume/isolate activity has appeared yet. Sweep D
  is still untouched.
- Scout follow-up `d6cb851f-28f3-44f4-9972-3645504fafa0`: the `ns15_aj`
  watchpoint cleared cleanly with a first-try `1500/1500`, no retry/resume/
  isolate activity, and `ns15_ak` is running now. Sweep D is still untouched.
- Scout final `3cd1d13b-35ef-4a74-8c4f-c4b84e303e02`: Sweep C at `1104215`
  DEFAULT/no-env is GREEN vs `d28b150`. Final CTS is `19716/19716` with
  candidate counts exactly matching baseline (`Pass=19365 Fail=36
  NotSupported=314 InternalError=1`), `0` transitions, `0` P->nonPass,
  `0` P->Fail, duplicate status records `0`, incomplete chunks `0`, and
  `status_maps_identical=1`. All `ns15_aa` through `ns15_ak` completed first
  try `1500/1500`, `ns15_al` completed `819/819`, and the known S22 stderr
  residuals were classified as pre-existing because they were not accompanied
  by any status-map regressions. Sweep D remains queued and untouched pending
  explicit dispatch.
- Sweep C explicit final relayed to Clerk after D dispatch: the default/no-env
  gate on `1104215` is green vs `d28b150` with `19716/19716` complete and
  exact baseline-matching counts, `0` transitions, `0` P->nonPass, `0`
  P->Fail, `status_maps_identical=1`, and the S22 stderr residual set
  classified as pre-existing. This is the canonical final that Crown bundles
  should cite, not an inference from the D dispatch.
- Scout startup `80d3fb97-996f-4cd0-b92a-20d6f692aa06`: Sweep D is running in
  isolated checkout `appgl-1104215-sweepD-forward` from target SHA
  `1104215edd092695887f62ca206be7c5bb038782` with a clean pre-build status.
  The full-forward posture is confirmed in env proof and GLCTS subshells:
  `APPGL_ENABLE_FBO_PASS_CONTINUATION=1`,
  `APPGL_ENABLE_VIEWPORT_REQUEST_KEEPALIVE=1`,
  `APPGL_ENABLE_LAYERED_CLEAR_ASYNC=1`,
  `APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP=1`, and
  `APPGL_ENABLE_FBO_CLEAR_FOLDING=1`. Sweep D is the only active Scout task
  now; Sweep C is complete and green.
- Scout artifact `d5335c99-8576-4b18-8876-aeec6f291573`: Sweep D built and
  published `libAppGL.dylib` at
  `.../gate-artifacts/1104215-s24-sweepD-full-forward/libAppGL.dylib`, SHA256
  `7496f476119064a73718823d92d3a741f1bf3d342ca9bfbb9ac24e6611218e40`,
  UUID `FAD51B6F-87E0-3F74-B9CE-82304BDBAFFE`, release shape PASS, and CTS is
  now running with 12 ns15 chunks plus 80 shader shards under FULL-FORWARD
  env.
- Scout progress `f6c9accd-73fd-421e-82cf-fe90f569af8d`: ns15_aa through
  ns15_ad completed first try `1500/1500` under FULL-FORWARD posture,
  `ns15_ae` is running, and no retry/resume/isolate activity has appeared so
  far.
- Scout follow-up `96b5c9c6-494d-4c6a-b675-80d6523ad418`: ns15_aa through
  ns15_ah are all first-try `1500/1500` under FULL-FORWARD posture, `ns15_ai`
  is running now, and no retry/resume/isolate activity has appeared yet.
- Scout follow-up `0b914765-cb16-4cb8-88ff-5c2b961dbd14`: the `ns15_aj`
  watchpoint cleared cleanly with a first-try `1500/1500` under FULL-FORWARD,
  no retry/resume/isolate activity, and `ns15_ak` is running.
- Scout final `a743f097-6138-4e7e-bc06-06f854f830f9`: Sweep D at `1104215`
  FULL-FORWARD is GREEN vs `d28b150`. Final CTS is `19716/19716` with
  candidate counts exactly matching baseline (`Pass=19365 Fail=36
  NotSupported=314 InternalError=1`), `0` transitions, `0` P->nonPass,
  `0` P->Fail, duplicate status records `0`, incomplete chunks `0`, and
  `status_maps_identical=1`. All `ns15_aa` through `ns15_ak` completed first
  try `1500/1500`, `ns15_al` completed `819/819`, and the known S22 stderr
  residuals were classified as pre-existing because they were not accompanied
  by any status-map regressions. Sweep D is the full-forward green gate that
  unlocks the downstream GLTest window and crown bundle.
- Staging note: the 1104215 operator-session control/candidate wrappers are
  now staged on disk as `launch-warzone-appgl-1104215-operator-control.sh`
  and `launch-warzone-appgl-1104215-operator-candidate.sh`, both using the
  frozen operator pin
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-1104215-preview-FAD51B6F.dylib`
  rather than any scout-worktree path. That frozen copy is verified with
  `UUID FAD51B6F-87E0-3F74-B9CE-82304BDBAFFE`,
  `SHA256 7496f476119064a73718823d92d3a741f1bf3d342ca9bfbb9ac24e6611218e40`,
  codesign valid on disk, and install-name `@rpath/libAppGL.dylib`.
  They are manual A/B prep only with 210s window proof fields, APPGL frame
  attribution enabled, stderr capture wired, and the canonical pin untouched.
- GLTest adjudication from Clerk `1e986fc8-40d1-41d7-8350-37eadf37aac9`:
  Bundle 1 (C48 chain) is crowned-pending-reconfirm after formal A/B passed
  with hard assertions, and the final condition is the operator visual
  reconfirm at 1104215 in their session. Bundle 2 (C49) has no GLTest
  synthetic signal because their live scene has zero FBO draws, so the live
  operator control-vs-candidate pair is the real evidence lane. The operator
  dashboard package was posted with the staged wrappers and the frozen pin
  identity, and the canonical pin remains untouched until Clerk's reconfirm
  call.
- Clerk tracker update `1ad47c90-241c-4a97-b5f5-2a3dd34c1463`: GLTest landed
  the same-target C49 probe mode (`c49-same-target-fbo-multidraw`, macrobench
  id 49) and Bundle 2's synthetic engagement is now CONFIRMED. Candidate
  continuation+keepalive achieved `fboPassContinuations 8,712 / tailCloses 0 /
  encoderOpensFboDraw 88 on 8,800 draws`, with `passDescriptorBuilds 8,686→176`
  and roughly a 99% collapse of pass churn on the continuation-friendly
  shape. Baseline stayed at `0 / 8,600 / 8,600`. The initial smoke had
  continuations `0` only because the FBO color texture was still bound on a
  sampler unit; the conservative feedback-hazard break did exactly the right
  thing, and the harness was fixed by unbinding. Record this as SYNTHETIC
  ENGAGEMENT CONFIRMED for Bundle 2, while the perf crown remains live-gated
  on the operator-session requirement.
- Operator answers `4338c99b-f3de-4998-838b-0f63e270c919`: Bundle 1 visual
  re-confirm is complete and shadows are correct in control. The hover-test
  split is recorded as: control mini-model texture breaks completely on hover
  (edges only), while candidate survives hover and only shows lighting flicker
  while rotating. Clerk classified the flicker as pre-existing-class and not a
  Bundle 2 blocker. Bundle 1 is therefore crowned. The canonical pin rotates
  to the 1104215 build: the old `A8483891` pin was backed up as
  `libAppGL-pinned-A8483891-backup.dylib`, and `libAppGL-pinned.dylib` now
  carries the frozen `libAppGL-1104215-preview-FAD51B6F.dylib` identity with
  UUID `FAD51B6F-87E0-3F74-B9CE-82304BDBAFFE`, SHA256
  `7496f476119064a73718823d92d3a741f1bf3d342ca9bfbb9ac24e6611218e40`,
  codesign valid, and install-name `@rpath/libAppGL.dylib`. The canonical
  launcher `launch-warzone-appgl.sh` was cleaned up by removing the redundant
  sampler-skip auto-export now that skip is default-ON since `1ef873b`.
- Clerk crown/sequence update `2bbb3ee3-f653-4a21-a564-64618a228030`:
  C49-Continuation is crowned; keepalive is crown-pending-flicker-
  discrimination and stays opt-in for now. Promotion proceeds with
  async+fold+continuation default-ON while keepalive is excluded from the
  promotion SHA. After the promotion lands and sweeps green, the canonical pin
  rotates again if needed, and only then do the fresh profile-of-record
  captures run on the promoted canonical. Bundle 2's live discriminator is
  staged for the operator's next sitting as two 2-minute build-menu hover
  checks (continuation-only vs keepalive-only). The pipeline-count watch item
  remains noted for Map v2.
- Worker defaults-promotion verdict `aaa8a73c-6569-4097-83ea-b1c26a1bde89`:
  defaults promotion lands as SHA `c23aa37` with async+fold+continuation
  runtime default-ON and keepalive default-OFF by carve-out. The single
  default sweep at `c23aa37` is both defaults-verification and the first
  continuation-on conformance pass; any P->F vs Sweep C/D maps should suspect
  continuation first via the DISABLE-hatch bisection. The fresh default
  profile shows a very large BAR-B drop relative to the old defaults, while the
  hover-flicker discriminator remains staged separately.
- c23aa37 discriminator staging: the current build was refreshed and frozen as
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-c23aa37-preview-1AF20FDC.dylib`
  with UUID `1AF20FDC-8D4B-3C84-A193-4A88A3EDC8C1`, SHA256
  `ed9ff82bf7c74c433c806864feb30f51baf5d7b58eb42fd54ed626fa9a06e983`,
  codesign valid on disk, and install-name `@rpath/libAppGL.dylib`.
  Discriminator wrappers are staged on disk as
  `launch-warzone-appgl-c23aa37-discriminator-keepalive-only.sh` and
  `launch-warzone-appgl-c23aa37-discriminator-continuation-only.sh`. The
  keepalive-only arm sets `APPGL_ENABLE_VIEWPORT_REQUEST_KEEPALIVE=1` and
  `APPGL_DISABLE_FBO_PASS_CONTINUATION=1`; the continuation-only arm clears
  keepalive and relies on the promoted default posture. Both are prep-only
  hover-test wrappers on the frozen c23 pin, with diagnostics, frame
  attribution, and stderr capture wired. The default-verification sweep on
  `c23aa37` is already in flight; keepalive discrimination stays queued for the
  operator's next sitting.
- Scout artifact `c46685cb-09dc-437c-b3df-afc3edfb426c`: the c23aa37
  default-verification build/artifact has been published at
  `$PROJECT_ROOT/scout-worktree/checkouts/appgl-c23aa37-default-verify/gate-artifacts/c23aa37-s24-default-verify/libAppGL.dylib`,
  SHA256 `a8c69530915417ed387db8015e616ca0003566467d204ed1eadc8cdff4c356ad`,
  UUID `CE7A7D04-98AD-30F0-955B-BABAB99A3F45`, release shape PASS, with CTS now
  running 12 ns15 chunks plus 80 shader shards. GLCTS launches clear ambient
  APPGL_* and export no APPGL variables; the promoted runtime defaults own the
  async/fold/continuation posture.
- Scout progress `2e0ec1a8-b16d-4827-9798-c21f75f8aedf`: ns15_aa through
  ns15_ad completed first try `1500/1500` under c23aa37 default verification,
  `ns15_ae` is running, and no retry/resume/isolate activity has appeared so
  far. The GLCTS path remains no-APPGL-env.
- Scout follow-up `c11ce605-b0aa-4a3d-8e57-e82fb6f3a7d6`: `ns15_aa` through
  `ns15_ag` are all first-try `1500/1500` under c23aa37 default verification,
  `ns15_ah` is running, and no retry/resume/isolate activity has appeared.
- Scout follow-up `2a356832-1c78-40a3-a695-55679d792aa7`: the `ns15_aj`
  watchpoint cleared cleanly with a first-try `1500/1500`, no retry/resume/
  isolate activity, and `ns15_ak` is running now.
- Scout final `7f938d1d-4b95-4d5a-87fb-51b6e01d2ae3`: c23aa37 single
  default-verification full CTS is GREEN vs `d28b150`, and it also serves as
  the first continuation-on conformance pass under runtime defaults. Final CTS
  is `19716/19716`, candidate counts exactly match baseline, `0` transitions,
  `0` P->nonPass, `0` P->Fail, duplicate status records `0`, incomplete chunks
  `0`, and `status_maps_identical=1`. `ns15_aa` through `ns15_ak` were clean
  first-try `1500/1500`, `ns15_al` completed `819/819`, and the MSL negative-
  cache / AGX stderr residuals are the known pre-existing class with no
  accompanying status-map regression. The c23aa37 default-verification build
  artifact is the published one at
  `.../checkouts/appgl-c23aa37-default-verify/gate-artifacts/c23aa37-s24-default-verify/libAppGL.dylib`
  with SHA256 `a8c69530915417ed387db8015e616ca0003566467d204ed1eadc8cdff4c356ad`
  and UUID `CE7A7D04-98AD-30F0-955B-BABAB99A3F45`.
- Clerk operator readback `7b30556b-33cd-4ea2-a9a6-874496907739`: the
  operator session is now on a laptop-only display, not the Studio Display,
  so absolute FPS is re-baselined and not comparable to earlier days. Treat
  ~32fps control as the new within-session baseline; within-session
  comparisons remain valid. Control (1104215 async+fold) is ~32-34fps, CPU
  ~90%, GPU 35%, memory 1.35GB stable, and no Mach leaks. Candidate
  (full-forward) is ~42fps, CPU 102%, GPU ~20%, memory 1.05GB, with visibly
  better responsiveness and the click-lag gone. The pre-existing hover-break
  on build-menu mini models still needs attribution split; the operator was
  asked to hover-test in control. The live pair run roots are under
  `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/1104215-operator-session/control/20260610T115039Z`
  and `$PROJECT_ROOT/live-targets/appgl-bridge/memory-runs/1104215-operator-session/candidate/20260610T115636Z`,
  with diagnostics, proofs/run-env.txt, and stderr.log in each root. Worker
  analysis has been handed those paths with the frozen live-targets pin, and
  the canonical pin remains untouched.
- Clerk follow-up `b0a011f6-5a27-424d-8fb8-47dc39a31efa`: pin rotation is
  already complete and verified on disk, with `libAppGL-pinned.dylib` now
  carrying the frozen c23aa37 identity. Next up is the short autogame census
  capture on the new canonical, then the operator sitting package: two 2-minute
  discriminator hover checks plus one 210s canonical profile run. Keepalive
  discrimination remains queued and opt-in until explicitly exercised.
- Worker observation-only commit `4f879ec7fded50090dd14137554a78edafe55ca2`:
  the sitting package has been refreshed to the new frozen preview pin
  `libAppGL-4f879ec-preview-D46E60EC.dylib` (UUID
  `D46E60EC-1C9B-38CC-B810-B50AFCF65AE7`, SHA256
  `73cb56a2b4e4c57f757dcd24ab186eb9465d3e11b47ffc0d5e2e58166cf5e275`,
  install-name `@rpath/libAppGL.dylib`). Matching discriminator wrappers were
  staged as `launch-warzone-appgl-4f879ec-discriminator-keepalive-only.sh` and
  `launch-warzone-appgl-4f879ec-discriminator-continuation-only.sh`. This is
  observation-only and keeps the canonical c23 pin untouched; it just refreshes
  the operator package to the latest export/trace instrumentation.
- Short 4f879ec autogame census run (`/memory-runs/4f879ec-observation/20260610T133242Z-skip-on`):
  PRE-GAME WINDOW / NOT HYPOTHESIS EVIDENCE. Clerk’s interpretation is that
  this was startup/menu time, not in-game steady state. The captured numbers
  remain recorded for completeness: `glCallCensus.totalCalls=433`,
  `distinctFunctions=39`, `exportUs=1.5`, top 10
  `glGetStringi 225`, `glGetError 48`, `glBindTexture 22`, `glTexParameteri 16`,
  `glGetIntegerv 15`, `glGetString 12`, `glBindFramebuffer 12`, `glBindBuffer 10`,
  `glGenBuffers 6`, `glObjectLabel 6`. Do not use this as dispatch-hypothesis
  proof.
- Short 4f879ec PSO-trace run (`/memory-runs/4f879ec-observation/20260610T133401Z-skip-on`):
  PRE-GAME WINDOW / NOT HYPOTHESIS EVIDENCE. `APPGL_TRACE_PSO_BUILDS=1` landed
  cleanly in the launcher stderr, with `1583` `APPGL_PSO_BUILD` misses over the
  25s window. This is loading-phase compilation, not the steady-state trickle.
  Still-recorded shape for later attribution: programs `28` (`533` misses), `13`
  (`509`), `31` (`189`), `34` (`124`), `55` (`75`), `58` (`75`), and `37`
  (`55`); standout build `36.66ms` on program `37`, with the rest mostly
  sub-millisecond and a few ~1ms outliers.
- Discriminator verdict from Clerk on the 4f879ec sitting package: keepalive-only
  arm = NO break, NO flicker; continuation-only arm = NO break, NO flicker.
  Clerk reclassified the visual flicker as a K+C interaction effect only seen
  when both levers are on, and confirmed the shipped canonical posture is
  visually clean. Keepalive remains opt-in pending interaction root-cause.
  The keepalive sample already on disk at
  `/memory-runs/4f879ec-discriminator/keepalive-only/20260610T141955Z/sample.txt`
  is secondary value only; dispatch-hypothesis ground truth still requires the
  later canonical 210s gameplay run plus its own mid-gameplay sample when that
  process appears.
- Clerk follow-up on the same sitting: the flicker triage is now treated as a
  latent correctness bug in the shipped canonical, not a keepalive composition
  issue. The current leading diagnosis is a rename-on-write / hazard-tracking
  bug in `syncMetalFromShadow` for large std140 UBO-backed live buffers. The
  fresh continuation-only gameplay root is `.../continuation-only/20260610T143539Z/`
  and the mid-gameplay sample is now captured there as `sample.txt`; label this
  root as `Map-v2 dispatch census + sample (analysis queued behind rename-on-
  write fix)`. Keep it distinct from the correctness repro chain, which already
  has its own headless deterministic probes from Worker.
- Rename-on-write landing `7613a14cda771146e1a4d43eb0950bcc344c6d88`: the
  fixed preview pin is frozen at
  `$PROJECT_ROOT/live-targets/appgl-bridge/libAppGL-7613a14-preview-28AA5ED5.dylib`
  with UUID `28AA5ED5-BD3A-3EDA-B54C-7562A3D9B1BC`, SHA256
  `8aca8582c70ab27edd25327e91350a6c6f6c08b8eacaa360a4baac8048598d7a`, and
  install-name `@rpath/libAppGL.dylib`. The full default sweep is now in flight
  against this target with the c23aa37 sweep maps as baseline; any new fail
  should first suspect the rename/stamp path until the probe counters say
  otherwise.
- Map-v2 ground truth from the 4f879ec continuation-only dispatch sample:
  `glCallCensus` volume is real (`8618` GL calls/frame), but the prologue cost
  hypothesis is refuted. `recordFunctionInvocation` is only ~0.1% of the main
  thread. The actual dispatch lever is not fast-path prologue trimming; it is
  the clear machinery. Current offender list:
  `applyDefaultFramebufferColorClear` (~40.7% main thread), `clearColorAttachment`
  (~16.9%), with `viewport invalidate + drainAll` at ~2.7% each and
  `encodeTranslatedDrawSerial` only ~2.8%. Worker has now requested GO on the
  new lever #1: lazy CPU-shadow clears for default-FB and texture-FB shadows,
  materializing only on real CPU-shadow consumers. The old recordFunctionInvocation
  prologue target is dead and should not be pursued further.
- Clerk digest acknowledgement: Map v2 is now formally recorded as
  8,618 GL calls/frame with dispatch prologue dead, clear machinery the real
  ~58% main-thread offender, and C49 translated-draw encode noise-level. Lever #1
  is greenlit as lazy CPU-shadow clears (default-off, full probe set, then sweep
  and live A/B). Sequencing remains: 7613a14 sweep continues unchanged; lever #1
  queues behind it, with the keepalive wrapper staged only after the sweep greens.
- Clerk final note: lever #1 is formally APPROVED and already proceeding on the
  Worker side; nothing further is needed from Foreman beyond keeping the tracker
  current while the 7613a14 sweep finishes. Gate train still queues behind the
  sweep.
- Scout startup `dea877f0-53bc-4d72-9410-72169eea895a`: the isolated
  `7613a14` build artifact is published and CTS has started. The gate artifact
  under test is
  `$PROJECT_ROOT/scout-worktree/checkouts/appgl-7613a14-default-verify/gate-artifacts/7613a14-s24-default-verify/libAppGL.dylib`
  with SHA256 `a352037f79875ea28352e6adb17fb224cd2c5b3c517597b565098a9ee32327fc`
  and UUID `04C4EA14-877D-346B-9AE8-77C9F0305FB1`. The frozen preview pin
  identity was separately verified as
  `8aca8582c70ab27edd25327e91350a6c6f6c08b8eacaa360a4baac8048598d7a` /
  `28AA5ED5-BD3A-3EDA-B54C-7562A3D9B1BC`. CTS is running with no APPGL env in
  GLCTS subshells.
- Scout progress `8dee9510-63c5-406f-8599-f6950acabaa0`: `ns15_aa` through
  `ns15_ad` are clean first-try `1500/1500`; `ns15_ae` is running. No
  retry/resume/isolate activity so far, and GLCTS remains no-APPGL-env.
- Scout progress `7ea89e23-13f4-4027-bdc1-cd2f1795fa7d`: `ns15_aa` through
  `ns15_ag` are all first-try `1500/1500`; `ns15_ah` is running. Still no
  retry/resume/isolate activity.
- Scout progress `0bf1519c-f89d-438b-b05b-1d8d6fc68742`: the inherited short-
  complete recurred at `ns15_aj`. `ns15_aa` through `ns15_ai` remain clean
  first-try `1500/1500`; `ns15_aj` try1 completed `1019/1500`; canonical try2
  is running, and if it stays short the runner will resume from `got+1` and
  combine. No isolate activity.
- Scout FIN `a61d9472-be3e-4fcb-90bb-962582cf9a4b`: `7613a14` full default/
  no-env sweep is GREEN vs the reused c23aa37 baseline. Counts are identical
  at `P=19365 F=36 NS=314 IE=1` across `19716/19716` cases, with zero status
  transitions and zero `P->nonPass` / `P->Fail` movement. The isolated gate
  build and the frozen preview pin were both verified, the no-env proof
  remained empty, and the residual stderr classes stayed in the known bucket
  without any status-map regression.
- Lever #1 landed `5c9fcac` (`...7613a14 -> 5c9fcac`), with
  `APPGL_ENABLE_LAZY_SHADOW_CLEARS` default-off. The FB0 axis now uses pending
  fill + materialize-then-fill semantics at the legal consumer funnels, while
  the texture axis deliberately diverged: whole-texture clears route Metal side
  through `clearLayeredTextureColor` and keep CPU shadows eagerly correct to
  avoid a large reader-funnel surface. Evidence: 5-probe set green, 10-phase
  matrix × 3 postures all green, BAR-B rgba identical, and lazy arm is ~12%
  faster within-run. The in-flight `7613a14` sweep remains sweep-equivalent on
  the default path; the lazy arm gets its own sweep when sequenced next.
- Clerk follow-up on `ea345d51-580d-4dc5-b118-8e9685dc6d7f`: keep the
  `7613a14` default sweep in flight, record the sweep-equivalence claim
  explicitly, and only consider a direct canonical repin to `5c9fcac` if we
  independently verify that its diff scope stays limited to flag/probe/counter
  code. Sequencing remains: finish `7613a14`, then dispatch the lazy-arm sweep
  at `5c9fcac` with `APPGL_ENABLE_LAZY_SHADOW_CLEARS=1`, and stage the next
  sitting package after both sweeps.
- Diff-scope verification result for `5c9fcac` vs `7613a14`: not limited to
  flag/probe/counter code. The delta includes runtime behavior in
  `src/context/GLContext.mm` and readback materialization in
  `src/context/GLContextReadback.inc.mm`, plus diagnostics plumbing in
  `src/runtime/AppGLRuntime.cpp` and probe coverage in
  `tests/GauntletRunner.cpp`. Per Clerk's fallback path, the canonical pin was
  left on the verified `7613a14` lineage instead of repinning to `5c9fcac`
  directly.
- Foreman context export written at
  `$PROJECT_ROOT/contexts/AppGL-Foreman-context-20260610.md`.
  The lazy-arm sweep is now the active next action and Clerk asked for this
  tracker to stay in lockstep with the export.

Fable-Worker has landed two C49 draft artifacts in `specs-worker-docs/`:

- `S24-C49-PASS-CONTINUATION-DRAFT-MEMO-2026-06-10.md`.
  Draft lever: cache an active-FBO-pass signature and continue the open encoder
  for same-target translated draws. The viewport-invalidate residual is a
  required rider, because the per-frame invalidate would otherwise force-close
  continued passes. C48 composition caution: `deferFboClear` must end an open
  pass targeting the cleared attachment with `endEncoding` only and no commit,
  so later same-pass draws cannot read pre-clear contents.
- `S24-C49-DRAW-PATH-CENSUS-SPEC-2026-06-10.md`.
  Instrumentation-first plan: encoder opens/closes by reason, draws-per-pass,
  continuation hit/miss/break counters, pass descriptor build count/time,
  `drainAllCalls`/wait time for the `LifetimeDrain` bucket, and the
  `APPGL_FRAME_ATTRIBUTION_PROFILE` zero-row bug. The census portion is now
  landed in `e2a876d`. (Stale phrasing corrected per Clerk 2026-06-10: nothing
  queues behind a "C48 sweep" — see numbering correction below.)

- Foreman handoff 2026-06-10: AppGL-Foreman switched to Claude and re-oriented
  from the 20260610 context export per Fable-Clerk directive (thread
  `s24-c49-killswitch`). State confirmed in sync with this tracker: canonical
  pin stays `7613a14` (28AA5ED5 preview identity), `5c9fcac` remains the queued
  lazy-arm target only, and Scout's lazy-arm sweep
  (`APPGL_ENABLE_LAZY_SHADOW_CLEARS=1`, baselines `7613a14`/`c23aa37`) is in
  flight. Awaiting Scout FIN; on green, rotation recommendation goes to Clerk,
  then the next-sitting package stages on the `5c9fcac` lineage.

- Numbering correction per Fable-Clerk 2026-06-10 (thread `s24-c49-killswitch`):
  C48 = FBO clear folding and C49 = pass continuation + keepalive rider — BOTH
  already crowned, and async+fold+continuation are already promoted to runtime
  defaults (`c23aa37`). The lazy-shadow-clears lever (`5c9fcac`) is NEW — logged
  as C50 going forward. Corrected state line: "C48/C49 crowned + promoted; C50
  (lazy shadow clears, 5c9fcac) in gate train — flag-ON sweep in flight." The
  earlier "queued behind C48 sweep results" phrasing was mid-arc staleness and
  has been struck above. Thread name `s24-c49-killswitch` is a historical
  artifact (C49 kill-switch baseline question); no obligation attaches to it.

- Wrapper supersession verification 2026-06-10 (Clerk directive, thread
  `s24-c49-killswitch`): live-target inventory audited. Canonical live pin
  `libAppGL-pinned.dylib` SHA256-verified identical to
  `libAppGL-7613a14-preview-28AA5ED5.dylib`
  (`8aca8582c70ab27edd25327e91350a6c6f6c08b8eacaa360a4baac8048598d7a`), and the
  main launcher `launch-warzone-appgl.sh` DYLD_INSERTs only the pinned path
  (export-then-exec, no env-prefix). The 4f879ec-era discriminator wrappers
  (`launch-warzone-appgl-4f879ec-discriminator-{keepalive,continuation}-only.sh`)
  and the c23aa37 discriminator pair stay on disk as historical artifacts but
  are SUPERSEDED: they will NOT appear in the next-sitting dashboard package.
  Staging plan of record for the C50 package: build a fresh frozen preview pin
  on the `5c9fcac` lineage (post-sweep-green, post-Clerk rotation decision) and
  fresh wrappers named on that lineage — keepalive flicker-check wrapper +
  lazy A/B pair (control canonical vs `+LAZY_SHADOW_CLEARS`, 210s each, full
  capture, mid-game `sample` both arms) — frozen-pin paths only, stderr capture
  preserved, run-root env proofs kept with the artifact.

- Scout C50 lazy-arm sweep launch + artifact proof (msgs `34d3dd48` /
  `8b0bc8ff`): target `5c9fcac5da9680fe4acad5ade0507dac45d4453b` verified
  (`7613a14` and `c23aa37` confirmed ancestors). Isolated checkout
  `scout-worktree/checkouts/appgl-5c9fcac-lazy-shadow-clears`; report root
  `scout-worktree/reports/full-cts-s24-5c9fcac-lazy-shadow-clears`. Built gate
  artifact `gate-artifacts/5c9fcac-s24-lazy-shadow-clears/libAppGL.dylib`,
  SHA256 `b6e650bc744a537f624b10cd3556221679d9d6e9c45e80ec3f37fe1da614ee8f`,
  UUID `274A7FAA-EAB3-399E-9FA8-43847D02AE8A`, install-name
  `@rpath/libAppGL.dylib`, release_shape_status PASS. Env proof
  `run-env-lazy-shadow-clears-env.txt` = `APPGL_ENABLE_LAZY_SHADOW_CLEARS=1`;
  GLCTS run_one clears ambient APPGL_* then exports the lazy flag +
  DYLD_LIBRARY_PATH to the artifact dir. Baseline primary: `7613a14` QPA
  `fb9a0b7a885fba9da15f8a97484bd2ce514b5cc4f2e3e69dd1f01a52dd5331b2`;
  secondary sanity: `7613a14` vs `c23aa37` status-map diff clean/identical.
  Provenance note: an initial write_provenance redirection typo (pre-GLCTS) was
  repaired via a corrective addendum at the report root; the GLCTS run_one
  launch path was unaffected (bash -n rc=0). Sweep launched ~15:37Z, running
  candidate ns15 chunks. Triage prior on any new fail: deferred-fill consumer
  funnels first (readback / getTexImage / blend-seed).

- Scout C50 progress `3ae961fa`: `ns15_aa`-`ns15_af` all clean first-try
  `1500/1500` (`ns15_ad` long-tail but completed); `ns15_ag` active (partial
  probe 1119/1500, fresh mtime, around KHR-GL46.copy_image functional texture
  cases). No retry/resume so far; status-regression data pending QPA
  merge/analyze.

- Scout C50 progress `2beb4e18`: ALL non-shader chunks completed first try
  under the lazy flag — `ns15_aa`-`ns15_ak` each `1500/1500`, `ns15_al`
  `819/819`; zero retry/resume/isolate in non-shaders (notably cleaner than the
  `7613a14` run, which short-completed at `ns15_aj`). Shader shard phase
  started 08:54 local; candidate QPA merge/analyze follows after all shards.

- Scout FIN `35e24d48` — C50 lazy-arm full CTS at `5c9fcac` with
  `APPGL_ENABLE_LAZY_SHADOW_CLEARS=1`: NOT GREEN, regression tight and
  LAZY-FLAG-OWNED. Counts: candidate `P=19357 F=44 NS=314 IE=1` vs baseline
  `P=19365 F=36 NS=314 IE=1` over `19716/19716` (incomplete_chunks=0);
  status_transitions=8, P->nonPass=8, P->Fail=8. The `7613a14` and `c23aa37`
  candidate maps are identical (diff_rc=0), so the same 8 deltas apply vs both.
  All 8 P->F: `KHR-GL46.texture_barrier{,_ARB}.{disjoint-texels,
  overlapping-texels, same-texel-rw, same-texel-rw-multipass}`, all failing
  "Failed to validate rendering results at gl4cTextureBarrierTests.cpp:469".
  OWNERSHIP PROBE on the same artifact: lazy_off 8/8 Pass, lazy_on 8/8 Fail —
  pins the delta to the flag, not build/source drift. Shape classification:
  texture feedback / read-after-write under texture_barrier (incl. same-texel
  + multipass), consistent with deferred-fill visibility/flush-before-consumer
  risk — a consumer-funnel miss, though NOT the predicted
  readback/getTexImage/blend-seed classes. Artifact: SHA256 `b6e650bc…ee8f`,
  UUID `274A7FAA-EAB3-399E-9FA8-43847D02AE8A`, release-shape PASS, codesign
  ad-hoc. Candidate QPA SHA256 `dfb83965…d346`; baseline QPA reused `fb9a0b7a…
  31b2`. Delta TSVs + 8-case caselist + probe summary at the report root.
  Sweep hygiene: all chunks first-try (no retry/resume/isolate), shader shards
  complete; stderr residuals in known bucket (AGX assertion 157, zero CmpFlip/
  MSL-FAIL/helper-threading); the texture-barrier fails are QPA
  rendering-validation, not stderr-only. Caveat: launch shell exited rc=2
  post-merge on a write_provenance/analyze-tail quote typo; harness repaired
  (bash -n rc=0), analyzer re-run manually over the completed candidate QPA,
  corrective provenance addendum appended.
- Foreman gate consequence: C50 canonical rotation criteria (flag-ON sweep
  green + flag-off gate matrix) are NOT met — recommendation to Clerk is NO
  rotation; canonical stays `7613a14`/28AA5ED5. Default path remains safe
  (flag default-off, default sweep-equivalence on record). Next-sitting package
  staging on the `5c9fcac` lineage is BLOCKED pending Clerk decision (fix-first
  vs restage-on-7613a14). Precedent note: this is the read-coherence class the
  P->F=0 conformance gate exists for (cf. S22 §37 texture-lazy 195 P->F) — the
  lazy-arm sweep caught what probes/matrix/BAR-B did not.

- Clerk adjudication `6acb0c26` on the C50 red gate: (1) NO ROTATION confirmed
  — canonical stays `7613a14`/28AA5ED5; default path unthreatened. (2) Worker
  dispatched on the 8-case texture_barrier triage (thread
  `s24-c50-texbarrier-triage`); Foreman forwarded the full handoff (caselist,
  ON/OFF probe summary, delta TSVs, artifact identity, shape note: FB0-axis
  funnel-into-texture-feedback vs clearLayeredTextureColor-barrier-interaction
  as leading suspects) in msg `739b6f56`. (3) SITTING PACKAGE SPLIT: keepalive
  flicker wrapper stages NOW on the `7613a14` lineage (keepalive's
  discriminator never depended on C50; kc race probes pass in +keepalive
  posture; clean flicker check unblocks keepalive promotion independently);
  the lazy A/B pair restages ONLY on a fixed C50 SHA after a green re-sweep —
  joins the sitting if fix+re-sweep beat the operator's return (~90min), else
  waits for the next window. Scout's same-artifact 8-case ON/OFF probe
  initiative recorded as positive precedent (ownership-pinning before
  reporting). The rc=2 harness-repair caveat accepted; corrective provenance
  addendum is the right shape.
- Keepalive flicker wrapper STAGED:
  `live-targets/appgl-bridge/launch-warzone-appgl-7613a14-keepalive-flicker.sh`
  (sh -n clean, executable). Posture: canonical runtime defaults + 
  `APPGL_ENABLE_VIEWPORT_REQUEST_KEEPALIVE=1` (pass continuation NOT disabled —
  this is the K+C composition check on the fixed lineage, distinct from the
  4f879ec keepalive-only discriminator which isolated keepalive). Frozen pin
  `libAppGL-7613a14-preview-28AA5ED5.dylib` (UUID re-verified 28AA5ED5), 210s
  window, full capture (diag jsonl + frame attribution + stderr), per-run
  proofs incl. pin UUID/SHA256/codesign + canonical-pin cross-proof. Art root:
  `memory-runs/7613a14-keepalive-flicker/`. Dashboard digest posted to operator
  inbox (sitting scope: keepalive-ready-now, lazy-A/B-conditional).

- Clerk endorsement + adjudication stakes for the keepalive flicker check
  (`79314da5`, DIR-FIN): wrapper posture (canonical defaults + keepalive,
  continuation NOT disabled) is the endorsed reinterpretation — the promotion
  question is keepalive-clean-ON-CANONICAL, and the 7613a14 rename-on-write fix
  is what should have killed the original K+C flicker. Outcome map of record:
  NO flicker in K+C on 7613a14 → UBO race confirmed as the flicker root cause
  → keepalive PROMOTES (own default-flip commit + sweep) and the 15-20% wall
  win ships; flicker PERSISTS → race fix necessary-but-insufficient → keepalive
  returns to triage. Two standing watches: Worker C50 triage
  (`s24-c50-texbarrier-triage`; on fix-SHA, Foreman relays to Scout for
  re-sweep, gate result routes to Clerk thread) + operator return (~90min) for
  the conditional lazy A/B call.

- KEEPALIVE CROWNED (Clerk `3e486ff1`, operator K+C check on `7613a14`,
  recorded verbatim): "~45fps, no flicker, no break, visuals correct, CPU
  105%/GPU 25%". The C49-rider thread CLOSES: UBO race was the root cause,
  rename-on-write the cure, keepalive promotes to default. (Outcome map's
  no-flicker branch confirmed — see stakes entry above.)
- SEQUENCE OF RECORD (post-crown train):
  1. Worker finishes the C50 authority fix, then lands the keepalive
     default-flip commit on top — separate commits, one train.
  2. On Worker's SHAs + green matrix, Foreman dispatches TWO sweeps to Scout
     SEQUENTIALLY: (a) combined-SHA DEFAULT config (gates keepalive-default +
     C50-fix flag-off path), (b) C50 FLAG-ON re-sweep (formal retest of the
     8-case texture_barrier red). Standard isolated-checkout discipline.
     SIGNAL CLERK AT EACH DISPATCH — Clerk relays the GPU-yield to GLTest
     (mid-piglit-baseline, checkpoint rule).
  3. Both green → rotation recommendation to Clerk for the combined SHA
     (criteria: both sweeps + Worker matrix + operator visual evidence on
     record).
  4. Then the sitting package: lazy A/B pair on the ROTATED canonical
     (control = new canonical, candidate = +LAZY_SHADOW_CLEARS), 210s each,
     full capture + mid-game samples both arms. Worker's 90-100fps-class
     prediction stands on record.
  5. Dashboard digest posted: keepalive crowned at 45fps clean, C50 fix
     nearing, two-sweep train queued, lazy A/B next sitting.

- Clerk sequencing resolution (`8d7175f3`, DIR-FIN): HOLD FOR BOTH SHAs
  confirmed — the sweeps gate the combined train, not the C50 fix alone. The
  keepalive flip is a one-liner + hatch landing minutes behind the fix;
  sweeping once at the combined SHA beats sweep-then-resweep. SOLE EXCEPTION:
  if Worker reports the flip BLOCKED, Foreman escalates to Clerk and the fix
  sweeps alone rather than stalling the C50 chain. Otherwise proceed exactly
  as stated (sequential a-then-b dispatches, signal Clerk at each for the
  GLTest GPU-yield relay).

- Worker FIN `9e16249a` (s24-c50-texbarrier-triage): BOTH SHAs delivered —
  C50 fix `8951e1f` + keepalive promotion `9ecf45b` (lineage `…5c9fcac ->
  8951e1f -> 9ecf45b`), one gate train. C50 ROOT CAUSE (third suspect; both
  seeded suspects — FB0-axis funnel + barrier-semantics interaction —
  empirically eliminated): the texture-axis reroute sent full-surface clears
  to `clearLayeredTextureColor`, whose GPU clear takes FLOAT values, garbage-
  seeding the texture_barrier suite's R32UI-class integer attachments where
  the old CPU pattern-fill+push was integer-correct ("no fold-trace lines" was
  the tell — immediate GPU-clear path, not defer). FIX: integer internal
  formats keep the eager fill+push; everything else stays rerouted. 8-case
  harness 8/8 GREEN lazy-on on the fixed build. Barrier-aware
  `materializeAllPendingFboClears` in `glTextureBarrier` STAYS as hardening
  (correct semantics, found en route, not the cause — honestly labeled).
  KEEPALIVE PROMOTION `9ecf45b`: default-ON with
  `APPGL_DISABLE_VIEWPORT_REQUEST_KEEPALIVE` hatch, `ENABLE=0` honored.
  Canonical no-env posture is now the FULL forward stack (async + fold + skip
  + continuation + keepalive) + both correctness fixes (rename-on-write +
  mirror-family materialize). GATES: 10-phase matrix green at new default AND
  lazy-on; DISABLE-hatch arm green; BAR-B rgba identical throughout.
- HOLD LIFTED (both SHAs + green matrix in hand): dispatching Scout sweep (a)
  combined-SHA `9ecf45b` DEFAULT config now; sweep (b) C50 flag-ON re-sweep
  queues behind it. Clerk signaled at each dispatch per the GLTest GPU-yield
  protocol.

- Scout sweep (a) setup `2cba463f`: target
  `9ecf45b9b029a8b776a004d1d617588a942a4916` verified, full lineage `7613a14
  -> 5c9fcac -> 8951e1f -> 9ecf45b` ancestry-confirmed. Isolated checkout
  `scout-worktree/checkouts/appgl-9ecf45b-default-combined`; report root
  `scout-worktree/reports/full-cts-s24-9ecf45b-default-combined`; primary
  baseline `7613a14` QPA `fb9a0b7a…31b2` (reused), c23aa37 secondary sanity
  clean. No-env discipline confirmed (ambient APPGL_* cleared, nothing
  exported, DYLD_LIBRARY_PATH only); triage priority registered
  keepalive-default-first / texture_barrier-secondary. Build/publish underway;
  artifact identity echo to follow.

- Scout sweep (a) artifact proof `823346c7`: gate artifact
  `gate-artifacts/9ecf45b-s24-default-combined/libAppGL.dylib`, SHA256
  `2960fd10a75383968368fe681fa85e0123c038bb4c755b871ba17158503bcfcb`, UUID
  `F39C99D7-8D46-3988-8164-7D25D737DFFF`, install-name `@rpath/libAppGL.dylib`,
  codesign ad-hoc, release_shape PASS (source_commit `9ecf45b…4916`, parent
  `8951e1f`). No-env proof file present and 0 bytes (empty = clean). CTS
  running default/no-env candidate chunks from `ns15_aa`.

- Scout sweep (a) progress `8d1f8c16`: `ns15_aa`-`ns15_af` all first-try
  `1500/1500` (`ns15_ad` slow texture-swizzle tail, completed); `ns15_ag`
  active (probe 1090/1500, fresh mtime, in KHR-GL46.copy_image texture-format
  coverage). No retry/resume so far.

- Scout sweep (a) progress `823ce3f2`: `ns15_aa`-`ns15_ai` first-try
  `1500/1500`; `ns15_aj` try1 ended short at `1019/1500` and try2 started —
  EXACTLY matching the `7613a14` default-sweep noise pattern (same chunk, same
  1019/1500 short-complete count), so treated as inherited harness noise, NOT
  keepalive/C50 signal unless try2/resume leaves a real incomplete or the
  analyzer shows status deltas.

- Scout sweep (a) HIGH-SIGNAL `6064a203`: `ns15_aj` INCOMPLETE in the
  automated pass — try1 `1019/1500`, try2 `1019/1500`, resume-from-line-1020
  (count 481) returned `0/481`; harness marked WARN-incomplete (`1019+0/1500`)
  and moved on to `ns15_ak`. DIVERGENCE from the `7613a14` baseline pattern:
  there the same-chunk short-complete recovered via resume-and-combine; here
  the resume produced ZERO cases — the case at caselist line 1020 looks like a
  start-blocker/hang candidate, which under the registered triage prior must
  be suspected as keepalive-default-path signal until shown otherwise. Scout's
  plan (endorsed): let the main sweep finish, then rescue the `ns15_aj`
  tail/isolate before final analysis; candidate aggregate stays
  incomplete-unless-repaired, so no status-map classification yet.

- Scout FIN sweep (a) `47d37c5a` — `9ecf45b` DEFAULT/no-env full CTS: GREEN
  after `ns15_aj` tail rescue. Repaired-complete analysis: `19716/19716` both
  sides, counts IDENTICAL (`P=19365 F=36 NS=314 IE=1`),
  `status_maps_identical=1`, zero transitions, zero P->nonPass/P->Fail, zero
  duplicates; repaired delta TSVs header-only. Applies to BOTH baselines
  (7613a14 primary fb9a0b7a…, c23aa37 sanity-identical). WATCH FAMILIES CLEAN:
  texture_barrier{,_ARB} 8-case set Pass in repaired candidate; NO
  keepalive-default status regression. RESCUE DETAIL: raw harness aggregate
  was 19235/19716 (incomplete_chunks=1, ns15_aj try1/try2 both 1019/1500,
  auto-resume 0/481); Scout rescued the 481-case tail on the SAME artifact +
  same no-env discipline (first tail case isolated = quick Fail in 5s,
  baseline-fail-equivalent — explains the resume wedge as harness artifact,
  not keepalive signal; remainder in 40-case batches, 481/481 complete),
  appended rescued QPAs -> repaired complete candidate QPA `619c7eca…b95a`
  (raw `77153420…21ca` retained). Rescue evidence dir `ns15_aj_tail_rescue/`
  at the report root. Artifact identity re-confirmed (`2960fd10…cfcb` /
  `F39C99D7`); no-env proof 0 bytes; stderr residuals known-bucket (AGX 357,
  zero CmpFlip/MSL-FAIL/helper-threading; AGX/renderbuffer lines confined to
  baseline-fail-equivalent rescued tail cases, no map delta). Sweep (b) held
  pending Foreman GO per dispatch discipline.
- Foreman: sweep (b) GO issued at this boundary (C50 flag-ON re-sweep at the
  same `9ecf45b` artifact); Clerk signaled for the GLTest GPU-yield relay.
  Gate-(a) criteria satisfied: keepalive-as-default + C50-fix flag-off path
  both green on the full surface.

- KNOWN HARNESS BUG (per Clerk `70fceaaa`, banked for auto-classification):
  the sweep batch runner can WEDGE ON A QUICK-FAIL at a resume boundary —
  trigger case identified as
  `KHR-GL46.direct_state_access.renderbuffers_storage_multisample` (a standing
  baseline Fail among the 36 F; quick-Fails in ~5s, SelfValidate
  StatusCode=Fail, verified in `ns15_aj_tail_rescue/tail_000_firstcase.qpa`).
  Symptom signature: chunk try1/try2 end short at the same count with the
  quick-Fail case first in the un-run tail, then auto-resume returns 0/N.
  Future sweeps hitting this signature at this case should AUTO-CLASSIFY as
  harness artifact (not runtime signal) and proceed straight to tail rescue —
  status-map evidence still required before final classification.
- PRECEDENT BANKED — incomplete-chunk recovery procedure (Scout, sweep (a)
  2026-06-10): (1) let the main sweep finish, don't stall mid-run; (2) isolate
  the FIRST un-run tail case solo on the SAME SHA-verified artifact + same env
  discipline (classifies wedge cause); (3) run the remaining tail in small
  batches (40-case) to completion; (4) append rescued QPAs to the raw
  candidate to form a repaired-complete candidate QPA; (5) retain BOTH raw and
  repaired QPAs with SHA256 identities recorded; (6) keep all rescue evidence
  in a dedicated dir at the report root; (7) classify only from the
  repaired-complete map. Clerk-endorsed as the evidence standard for this
  recovery class.
- Clerk `70fceaaa` also: sweep (a) green ACCEPTED (keepalive-as-default
  conformance-proven); GLTest stays parked through sweep (b) by their own
  standing decision (no GPU-yield relay needed at the (b) boundary — they wait
  for the both-sweeps all-clear). On (b) green: rotation recommendation, then
  the sitting package.

- Scout sweep (b) startup `829872ee`: C50 FLAG-ON re-sweep launching on the
  SAME `9ecf45b` artifact (no rebuild; identity re-echoed `2960fd10…cfcb` /
  `F39C99D7`, release-shape PASS from existing metadata). Report root
  `scout-worktree/reports/full-cts-s24-9ecf45b-lazy-shadow-clears`; baseline
  unchanged (`7613a14` QPA `fb9a0b7a…31b2`, c23aa37 sanity identical). Env
  discipline: ambient APPGL_* cleared, then
  `APPGL_ENABLE_LAZY_SHADOW_CLEARS=1` only + DYLD_LIBRARY_PATH; proof file at
  run root. Watch order registered: texture_barrier{,_ARB} first,
  keepalive-default secondary; pre-authorized same-pattern rescue if `ns15_aj`
  wedges at the known case.

- Scout sweep (b) progress `9334b3a5`: `ns15_aa`-`ns15_af` all first-try
  `1500/1500` (`ns15_ad` slow swizzle tail, completed); `ns15_ag` started
  10:44:55. Env proof at run root contains exactly
  `APPGL_ENABLE_LAZY_SHADOW_CLEARS=1`. No retry/resume yet.

- Scout sweep (b) progress `9c4f1c68`: `ns15_aa`-`ns15_ai` first-try
  `1500/1500`; `ns15_aj` try1 ended `1019/1500` (the KNOWN harness wedge
  signature at `…renderbuffers_storage_multisample`), try2 started 10:51:31.
  Same-pattern flag-ON rescue pre-armed if the 481-case tail goes incomplete.

- Scout sweep (b) progress `89a9da14`: non-shaders complete except the known
  `ns15_aj` tail — `ns15_aa`-`ns15_ai` + `ns15_ak` first-try `1500/1500`,
  `ns15_al` `819/819`; `ns15_aj` repeated the EXACT wedge signature
  (try1/try2 both `1019/1500`, auto-resume `0/481`) — auto-classified per the
  banked harness bug. Shader shards started 10:56; flag-ON same-artifact
  481-case tail rescue + repaired-QPA reanalysis queued after raw
  merge/analyze.

- Scout FIN sweep (b) `d307b73f` — `9ecf45b` FLAG-ON
  (`APPGL_ENABLE_LAZY_SHADOW_CLEARS=1`) full CTS: NOT GREEN, but the failure
  surface is exactly ONE case and it is abort-class, not regression-class.
  HEADLINE SPLITS: (1) FORMAL TEXTURE_BARRIER RETEST CLEAN — dedicated 8-case
  run on the same artifact: ends=8 pass=8 fail=0 rc=0 (QPA `cc0cee72…297f`);
  the original C50 red is FIXED under the flag. (2) ZERO P->F / P->nonPass
  among all cases that produced status; keepalive-default not implicated.
  (3) THE ONE ISSUE: `KHR-GL46.direct_state_access.renderbuffers_storage_multisample`
  — a baseline-fail-equivalent case (standing 36-F member; quick-Fails
  normally in default config, incl. sweep (a)) — under flag-ON it ABORTS
  rc=133 with NO StatusCode (#beginTestCaseResult + renderbuffer mismatch
  text, no end record; AGX bytes_per_row assertions in stderr; abort proof
  QPA+stderr at report root `ns15_aj_tail_firstcase_lazy_on.*`). So the wedge
  case escalates Fail->abort when lazy is ON: a crash-class defect in the
  OPT-IN lever, invisible to the default posture. Repaired-minus-abort
  analysis vs 7613a14: candidate `19715` cases, `P=19365 F=35 NS=314 IE=1`,
  exactly 1 transition = that case Fail->ABSENT (not synthesized — honest
  accounting); zero P->F. Tail-after-first rescued 480/480
  (pass=475 fail=2 NS=2 IE=1, baseline-consistent). Artifact identity
  unchanged (`2960fd10…cfcb`/`F39C99D7`, no rebuild); env proof flag-only; raw
  QPA `dc6c7d7f…bfc3` + repaired-minus-abort `9c52680d…d7f3` both retained.
  Stderr residuals known-bucket (AGX 557, zero CmpFlip/MSL-FAIL/helper).
- Foreman read for adjudication: sweep (a) gates the CANONICAL posture
  (lazy default-off) completely green; sweep (b)'s sole defect lives behind
  the opt-in flag and cannot reach the canonical posture. The C50 8-case
  conformance question is answered clean. The abort is a real crash-class
  defect in the lazy lever (Fail-path + lazy interaction on the DSA
  renderbuffer-multisample route) and directly gates the lazy A/B sitting arm
  (which runs flag-ON live). Rotation recommendation + abort-handling
  routed to Clerk.

- Clerk ADJUDICATION `102c0090`: both recommendation halves ADOPTED. (A)
  ROTATE canonical to `9ecf45b` (controlling rationale recorded: the
  both-green criterion protects the thing being rotated; sweep (a) gates the
  canonical posture completely; the sweep (b) defect is unreachable without
  the opt-in flag the canonical never sets). (B) LAZY A/B HELD; the
  flag-ON abort routed to Worker by Clerk. MODIFICATION: NO operator package
  this window — the keepalive-crowned-canonical check is already satisfied
  (the 45fps clean run on 7613a14+keepalive is posture-equivalent to the new
  canonical); operator's next item is the lazy A/B AFTER the abort fix
  re-greens the flag arm. GLTest GPU all-clear relayed by Clerk.
- CANONICAL ROTATION EXECUTED 2026-06-10 (Foreman): new canonical pin =
  `9ecf45b` via the EXACT swept gate artifact (strongest identity: the binary
  that passed both gates). Frozen preview pin
  `libAppGL-9ecf45b-preview-F39C99D7.dylib` copied from Scout's
  `gate-artifacts/9ecf45b-s24-default-combined/libAppGL.dylib`; SHA256
  verified IDENTICAL source->dest
  `2960fd10a75383968368fe681fa85e0123c038bb4c755b871ba17158503bcfcb`; UUID
  `F39C99D7-8D46-3988-8164-7D25D737DFFF`; install-name `@rpath/libAppGL.dylib`;
  sha256 sidecar written. BACKUP: prior live pin preserved as
  `libAppGL-pinned-28AA5ED5-backup.dylib` (SHA256 re-verified `8aca8582…7a` =
  the 7613a14 identity). `libAppGL-pinned.dylib` repointed to the 9ecf45b
  artifact (SHA256 + UUID re-verified post-copy); `libAppGL-pinned.sha256.txt`
  updated. Launcher `launch-warzone-appgl.sh` UNTOUCHED (DYLD_INSERTs the
  pinned path). Canonical no-env posture is now the full forward stack
  (async + fold + skip + continuation + keepalive-default) + both correctness
  fixes. The lazy lever stays default-off with one known flag-only abort
  residual (DSA renderbuffer-multisample, under Worker triage).

- Worker FIN `0202d071` (s24-c50-texbarrier-triage) — C50-RESIDUAL VERDICT:
  LAZY OWNERSHIP REFUTED. The
  `…direct_state_access.renderbuffers_storage_multisample` abort is the
  standing-F case's OWN heap corruption, nondeterministic in BOTH arms.
  Evidence: 3×3 stability matrix on the fixed build — DEFAULT config
  rc=133/1/134 across three runs (aborts 2 of 3); lazy-on rc=1/1/133
  (clean-fails 2 of 3). The sweep-(b) lazy=abort / sweep-(a) default=quick-Fail
  split was ALLOCATION LUCK — each single-arm probe sampled one coin flip.
  Mechanism: the case's standing-F path emits 100-150 AGX bytes_per_row
  asserts per run (linear-staging overrun in pre-existing MS-depth readback
  territory; crash stack `readDepthFromMetalTexture` → malloc abort on
  corrupted heap); whether malloc trips is timing. This is another instance of
  the single-sample-attribution trap (cf. isolated-probe cross-check item):
  one observation per arm cannot own a nondeterministic outcome to a flag.
- Worker LANDED `3848a30` regardless: texture-axis reroute narrowed from
  integer-blacklist to a probe-covered UNORM whitelist
  (RGBA8/RGB8/SRGB8_ALPHA8/RGBA/RGB — the live-WZ win set); texture_barrier
  stays 8/8 green, lazy + c48 probe families green. Worker states the change
  is flag-gated code only (default-path equivalent to 9ecf45b) — per the
  5c9fcac diff-scope lesson this claim needs independent verification before
  the default path is treated as swept.
- AMENDMENT to the KNOWN HARNESS BUG entry: the wedge-trigger case is ITSELF
  nondeterministically abort-prone in ANY config (default included) — the
  rc-133 class at this case is case-owned heap corruption, not flag signal and
  not purely runner-owned; it likely explains historical rc-133 flakes. Any
  sweep in any config may hit it; auto-classify per the banked signature and
  rescue. S25 DEBT ENTRY (flake-risk flag): underlying MS-depth readback
  linear-staging overrun needs a real fix; case is QUARANTINE-CANDIDATE per
  the maximal-conformance endgame discipline (Clerk decision pending).
- Worker recommendations routed to Clerk (decisions pending): (1) un-hold
  lazy A/B operator package; (2) S25 debt + flake-flag + quarantine-candidate
  for the standing-F corruption; (3) sweep replan to `3848a30` when
  convenient.

- Clerk ADJUDICATION `8f16b85d` — C50-residual RESOLVED (lazy ownership
  refuted; same case = sweep-(a) wedge = likely historical rc-133 flake
  class). Execution list: quarantine register entry, 3848a30 flag-ON crown
  re-sweep with quarantine protocol, lazy A/B UN-HELD and staged NOW on the
  3848a30 lineage, dashboard digest.

## FLAKE-QUARANTINE REGISTER

- CASE: `KHR-GL46.direct_state_access.renderbuffers_storage_multisample`
  (quarantined 2026-06-10, Clerk adjudication `8f16b85d` per the
  maximal-conformance endgame discipline).
  RATIONALE: nondeterministic abort from PRE-EXISTING heap corruption on the
  case's standing-F path — linear-staging overrun in MS-depth readback
  territory (crash stack `readDepthFromMetalTexture` → malloc abort on
  corrupted heap; 100-150 AGX bytes_per_row asserts per run; malloc timing
  decides abort-vs-Fail). Evidence: Worker 3×3 stability matrix on the fixed
  build — DEFAULT rc=133/1/134 (aborts 2/3), lazy-on rc=1/1/133 (Worker FIN
  `0202d071`). Config-independent; wedges the batch runner; likely explains
  historical rc-133 flakes.
  UN-QUARANTINE CONDITION: the underlying MS-depth staging-overrun fix lands
  (S25 debt entry WITH flake-risk flag) and the case shows deterministic
  status across a 3×-isolated stability check.
  SWEEP PROTOCOL (ALL future sweeps): EXCLUDE the case from the batch run;
  execute it 3× ISOLATED as a sidecar on the same artifact/env; report its
  status separately in the FIN. Signal is preserved; runs can no longer be
  poisoned.

- Diff-scope verification 3848a30 vs 9ecf45b (Clerk-adopted amendment,
  executed): CLEAN/VERIFIED — exactly one hunk, `src/context/GLContext.mm`
  `clearColorAttachment` (+13/−6), replacing the integer-format exclusion with
  the UNORM whitelist; the entire changed condition chain sits directly under
  `lazyShadowClearsEnabled() &&`. Flag-gated-only claim VERIFIED (contrast
  5c9fcac where the same claim shape failed) → default path is
  9ecf45b-equivalent, NO default re-sweep needed, canonical stays 9ecf45b.
- C50 crown sweep DISPATCHED to Scout (`18c78044`): 3848a30 flag-ON, full
  ancestry verify, baselines unchanged, QUARANTINE PROTOCOL ACTIVE for the
  first time (batch-exclude the DSA case + 3×-isolated sidecar + separate
  reporting; expected batch accounting 19715 + sidecar block; prediction:
  ns15_aj completes without rescue — if it still wedges, that is NEW
  information). Watch order: texture_barrier confirm-clean, then
  whitelist-narrowing consumer funnels (newly-excluded formats take eager
  fill+push), then keepalive×lazy composition. Early artifact echo requested —
  the A/B candidate pin cuts from the published gate artifact.
- Lazy A/B operator package staging (UN-HELD per `8f16b85d`): CONTROL wrapper
  staged `launch-warzone-appgl-3848a30-operator-control.sh` (sh -n clean,
  executable) — canonical 9ecf45b posture, frozen pin
  `libAppGL-9ecf45b-preview-F39C99D7.dylib`, no APPGL env, 210s, full capture
  + per-run proofs. CANDIDATE wrapper pends Scout's 3848a30 artifact echo
  (frozen pin cut from the swept binary, then `+APPGL_ENABLE_LAZY_SHADOW_
  CLEARS=1`). Dashboard digest posts when both arms staged. Worker prediction
  on record: applyDefaultFramebufferColorClear 40.7%→~0, 90-100fps class.
- METHODOLOGY ENTRY (Clerk-endorsed, cross-arc value): single-sample-
  attribution trap — a one-observation-per-arm gate CANNOT own a
  nondeterministic outcome to a flag/config; the sweep-arm coin-flip
  (lazy=abort / default=quick-Fail, refuted by Worker's 3×3 stability matrix)
  pairs with the isolated-probe cross-check precedent (S21): before accepting
  a config-owned classification of an abort/flake-class delta, run a
  stability matrix (≥3× per arm) on the same artifact.

- Scout crown-sweep artifact echo `b117e6e4`: `3848a30c4fbe7dda39427c3edf373b
  20972434c1` ancestry-verified through the full chain; published gate
  artifact SHA256
  `209ce170cce8b6dfbb7c5650da89ec3b1655826d5a0e3fb77bed0876660697b9`, UUID
  `2B752DEB-DB25-3C4F-A2BE-E7DB39E005BC`, release-shape PASS (parent
  `9ecf45b`). Quarantine-protocol runner proceeding (batch-exclude + 3×
  flag-ON isolated sidecar).
- LAZY A/B PACKAGE FULLY STAGED: candidate frozen pin
  `libAppGL-3848a30-preview-2B752DEB.dylib` cut from the swept gate artifact
  (SHA256 verified identical source->dest, UUID re-verified, install-name
  `@rpath/libAppGL.dylib`, sidecar written). CANDIDATE wrapper
  `launch-warzone-appgl-3848a30-operator-candidate.sh` (sh -n clean,
  executable): frozen 3848a30 pin + `APPGL_ENABLE_LAZY_SHADOW_CLEARS=1`, 210s,
  full capture + proofs. CONTROL wrapper (staged earlier): canonical 9ecf45b
  posture on frozen F39C99D7 pin, no APPGL env. Both arms: per-run identity
  proofs + canonical-pin cross-proof; mid-game `sample` captured Foreman-side
  per arm. Art roots `memory-runs/3848a30-lazy-ab/{control,candidate}/`.
  Dashboard digest posting now. NOTE: package is informal-preview class — the
  formal C50 crown still waits on the 3848a30 flag-ON sweep FIN.

- Scout quarantine-protocol sweep launch `738f67a9`: dedicated runner
  `full_cts_s24_3848a30_lazy_shadow_clears_quarantine.sh`; report root
  `full-cts-s24-3848a30-lazy-shadow-clears-quarantine`. Pre-launch protocol
  checks all confirmed: artifact identity rechecked (`209ce170…97b9` /
  `2B752DEB`), filtered non-shader split excludes the quarantined DSA case,
  analyzer removes it from baseline/candidate comparison and writes
  `quarantine-case-status.tsv` separately, sidecar runs it 3× flag-ON on the
  same artifact, env discipline flag-only. Quarantine protocol implementation
  matches the register spec exactly.

- Scout crown-sweep progress `6834b52e`: two setup hiccups, both handled
  honestly — (1) first launch stopped pre-CTS on a wrong expected filtered
  non-shader count (corrected 17319 -> 17318 after the quarantine exclusion);
  (2) relaunch sidecar helper hit a portability bug (`/bin/printf` absent on
  this macOS) so the in-script sidecar didn't record — batch unaffected and
  running with the case excluded; runner patched for repeatability and the 3×
  sidecar will run MANUALLY after batch completion. Batch: `ns15_aa`-`ns15_af`
  first-try `1500/1500`, `ns15_ag` started 11:30.

- Scout crown-sweep progress `d0dcafd4`: QUARANTINE PREDICTION CONFIRMED —
  `ns15_aj` completed `1500/1500` FIRST TRY with the DSA case excluded,
  crossing the prior 1019 wedge boundary cleanly. Empirically nails the wedge
  attribution to the quarantined case (third consistent data point: wedged in
  both 9ecf45b sweeps with the case in-batch, clean with it out). `ns15_aa`-
  `ns15_ai` also all first-try. Current chunk `ns15_ak`; manual 3× sidecar
  still queued post-batch.

- Scout FIN C50 CROWN SWEEP `e8e993c0` — `3848a30` flag-ON, quarantine
  protocol active: GREEN on the effective map. Batch `19715/19715`
  (incomplete_chunks=0), counts `P=19365 F=35 NS=314 IE=1` vs effective
  baseline (7613a14 minus quarantined case) IDENTICAL same counts;
  status_transitions=0, P->nonPass=0, P->Fail=0,
  status_maps_identical_effective=1, duplicates 0/0. texture_barrier{,_ARB}
  8/8 Pass IN THE BATCH MAP (not just the dedicated retest). Filtered-split
  leak check clean; `ns15_aj` crossed the old wedge point first-try
  `1500/1500`, no rescue. QUARANTINE SIDECAR (3× isolated, same artifact/env):
  rc=133 results=0 (SIGTRAP, AGX bytes_per_row asserts) / rc=1 results=1 Fail
  / rc=139 results=0 (SEGFAULT, same asserts) — a THIRD failure mode
  (segfault) joins trap+clean-Fail, further cementing the case-owned
  nondeterministic-corruption classification; sidecar summary + QPA hashes
  recorded (`0853e74d…` / `a9fbb1a3…`). Artifact identity re-confirmed
  (`209ce170…97b9` / `2B752DEB`); candidate batch QPA `6d6ba540…04aa`;
  baseline reused `fb9a0b7a…31b2`; analysis summary `45224122…62fd`. Stderr
  residuals zero in the tracked classes. Env proof flag-only. Honesty notes:
  two pre-batch setup faults (filtered-count expectation, /bin/printf) fixed
  before the valid batch; post-batch script fault (line-425/TOTAL parsing)
  meant analyzer+sidecar ran MANUALLY on the same artifact/env; no glcts
  processes left behind.
- Foreman gate read: C50 formal crown criteria are now fully satisfied on the
  conformance axis — flag-ON full surface green (effective map identical),
  texture_barrier formally retested clean in-batch, quarantine protocol
  validated end-to-end on its first run. Crown adjudication routed to Clerk.
  The staged A/B candidate pin is this exact swept binary (`209ce170…`/
  `2B752DEB`), so the operator package needs no re-cut.

- Clerk ADJUDICATION `a570cd32` — C50 CROWNED on the CONFORMANCE+CORRECTNESS
  axes at `3848a30`: flag-ON full surface green (19715/19715
  effective-identical, texture_barrier 8/8 in batch map), default path
  diff-scope-verified equivalent, red→green arc fully documented (float-clear
  root cause → UNORM whitelist → formal retest). Per the two-bundle
  discipline: PERF crown + any default-flip decision WAIT on the live A/B
  (engagement+perf same-run, slow-tail metrics, operator visual parity).
  QUARANTINE PROTOCOL validated as STANDING METHODOLOGY. Foreman lane:
  watch-only until operator session data lands.
- S25 DEBT ADDENDUM (sidecar third failure mode): the quarantined DSA case's
  3× isolated sidecar at 3848a30 produced rc=133 SIGTRAP / rc=1 clean-Fail /
  rc=139 SEGFAULT — three distinct outcomes, same AGX bytes_per_row asserts.
  The corruption expresses as trap, clean fail, OR segfault on timing; any
  future rc-139 at this case is the same debt item, not new signal.
- OPERATOR A/B SITTING IN PROGRESS (operator ack `cd4182f7` 18:47Z, "runs in
  progress, results momentarily"): CANDIDATE arm ran first
  (`candidate/20260610T184038Z`, 18:40-18:44Z — full capture present: 74MB
  diagnostics jsonl + stderr + proofs; NO mid-game sample.txt — the arm
  completed before the sitting was announced, sample window missed).
  CONTROL arm live at capture time (`control/20260610T184537Z`, PID 83699,
  ~107% CPU): mid-game `sample` CAPTURED Foreman-side at 18:48Z (~2.5min into
  the 210s window) -> `sample.txt` (1.6MB) in the run dir alongside 20MB
  diagnostics. Candidate-sample gap flagged in the digest: a candidate re-run
  can capture it if the dispatch-census analysis needs it; the frame
  attribution profile in the jsonl may suffice for the perf axis.

- Clerk sample-gap ruling `d6576082`: candidate re-run is CONDITIONAL ON
  RESULTS — no preemptive request. Perf-crown chain needs engagement (census
  counters in candidate jsonl — present) + frame-time/FPS evidence (present)
  + control baseline sample (captured, re-anchoring the 40.7%). The candidate
  stack sample is load-bearing ONLY if the numbers MISS the 90-100fps
  prediction (then a re-run-with-sample becomes the diagnostic for where the
  time went). Flow: results land → Worker analyzes existing captures → re-run
  only if analysis says the missing sample blocks a verdict. Foreman
  watch-only.

- OPERATOR A/B RESULTS (relayed by Clerk `9f19567e`, thread
  s24-c50-perf-verdict, recorded verbatim): CANDIDATE (3848a30 + lazy) ~75fps
  avg (80/72), CPU 98% w/ 88 min, GPU 37%; CONTROL (canonical 9ecf45b) ~42fps,
  CPU 105%, GPU 20% — +79% candidate over control. PREDICTION-VS-ACTUAL:
  90-100fps class predicted (applyDefaultFramebufferColorClear 40.7%→~0); 75
  actual — real residual under Worker analysis (where the remaining main-
  thread time went). Largest single-lever win in project history (vs prior
  best: keepalive 24→45fps class). Worker handed both run roots + pin
  identities + analysis asks (engagement counters, frame-time both arms,
  residual attribution, slow-tail, sample-gap blocking-check). Conditional
  candidate re-run stays ARMED pending Worker's residual-resolution read.
  GPU utilization doubling (20%→37%) + CPU dropping below saturation
  (105%→98%) consistent with submission-overhead relief.

- Worker PERF-VERDICT FIN `a42ab21f` (s24-c50-perf-verdict): CROWN YES; the
  missing candidate sample does NOT block (conditional re-run STOOD DOWN);
  DEFAULT-FLIP RECOMMENDED with its own sweep.
  (1) ENGAGEMENT (candidate JSONL, same-run): shadowClearsDeferred 2.00/frame
  (1 FB0 + 1 texture-axis; fboClearsDeferred 6/frame vs control 5 = reroute
  feeding C48 confirmed), shadowClearsCoalesced 1.00/frame,
  shadowClearsMaterialized = TWO in the entire 4-min run (Warzone never reads
  the shadow — the design bet exactly); control all-zero; bufferRenames=20
  total (no rename storm; pool deferral vindicated).
  (2) PREDICTION RECONCILIATION (90-100 predicted vs 75 actual): fresh control
  sample re-anchors clear machinery at 53.5% main thread (33.1% applyDefault-
  FramebufferColorClear + 20.4% clearColorAttachment/replaceMetalTexture) ≈
  12.7ms of the 23.8ms control frame; arithmetic floor after removal ~11.1ms
  ≈ 90fps — the prediction WAS the floor; actual 13.3ms carries +2.2ms of
  non-clear work that was always present and now owns the frame. AppGL
  frame-level machinery EXONERATED: present 19.7µs avg, ring_slot_wait 2.15µs,
  2 readbacks ≈ 24µs/frame, waits dead. Residual named with evidence — no
  stack sample required.
  (3) NEW DOMINANT OWNERS (post-C50, clears subtracted): (a) GAME-SIDE
  sim/prep (drawTiles non-clear + InstancedMeshRenderer) ~12-15% ≈ 3-3.5ms —
  largest block, NOT ours; (b) AppGL PER-DRAW PATH
  (glDrawElementsInstanced→encodeTranslatedDraw, ~13% ≈ 3ms @ 220-232
  draws/frame) — OURS, NEXT-LEVER TERRITORY (phase2_plan_lookup,
  fixed-function state, info-init per BAR-B bucket calibration); (c) UI
  widgets 5.4%; (d) REAL-resize path ~3.3% (glViewport→resize→invalidate-
  TransientState→drainAll firing in CONTROL despite keepalive-default —
  actual-resize not request-only; small, next-characterization item). GPU 37%
  = still CPU-bound; ceiling ours to take.
  (4) STABILITY: both arms clean (in-flight peak 3/2, zero retained growth,
  zero PSO failures, empty error logs). Frame bands tight (72-80) but these
  roots lack per-frame time series (GLTest instrument not in this run shape)
  — slow-tail metrics ride the next sitting's harness arm; noted honestly,
  not verdict-blocking.
  (5) VERDICT: perf crown YES (+79% same-run, engagement proven, C45-clean
  envelope). DEFAULT-FLIP recommendation: APPGL_ENABLE_LAZY_SHADOW_CLEARS →
  default-ON (skip-posture pattern, DISABLE hatch), own commit + ONE default
  sweep on the flip SHA. With it canonical Warzone = 24fps (sprint start) →
  ~75fps: 3.1× in one sprint, ~50% of native. Routed to Clerk for crown +
  flip adjudication.

- Clerk ADJUDICATION `e5ede7b6` — C50 FULL CROWN GRANTED (conformance +
  correctness + perf: +79% same-run, engagement proven, envelope clean,
  residual attributed). Sequence of record: (1) Worker lands the default-flip
  commit (LAZY_SHADOW_CLEARS → default-ON, hatch pattern) → Foreman verifies +
  dispatches ONE default/no-env sweep at the flip SHA (isolated checkout,
  baselines = 3848a30/9ecf45b maps, quarantine protocol standing, Clerk
  signaled at dispatch; GLTest piglit-window check first — local process
  check, ~16min run-length math). (2) Sweep green → rotate canonical to the
  flip SHA (backup discipline); canonical Warzone then ships the ENTIRE S24
  arc as plain defaults — 24fps → ~75fps, 3.1× in one sprint, ~50% of the old
  native reference. (3)+(4) digest + standing watch below.
- METHODOLOGY NOTE (floor-reconciliation, Clerk-endorsed): a perf prediction
  derived by subtracting an attributed block from a measured frame time is a
  FLOOR, not a point estimate — removal exposes the next-largest pre-existing
  block, so actual lands floor+exposed-residual. Reconcile
  prediction-vs-actual by re-anchoring the attribution on a fresh same-run
  control sample and NAMING the exposed residual with evidence (C50: 90-100
  predicted-as-floor, 75 actual, +2.2ms exposed = game-side sim/prep + per-
  draw path + UI + real-resize, each quantified). A miss that reconciles
  arithmetically with named owners is a HIT on a floor prediction.
- NEXT-LEVER RANKING (post-C50 frame, on record for planning): (1) game-side
  sim/prep ~3-3.5ms — largest overall, NOT AppGL-owned (the ceiling question
  is now real); (2) AppGL per-draw GL prep ~3ms @ 220-232 draws/frame —
  LARGEST APPGL-OWNED BLOCK, next arc (Worker memo in draft);
  (3) UI widgets 5.4%; (4) real-resize drainAll ~3.3% (fires in control
  despite keepalive-default — actual-resize class, next characterization).
  GPU at 37% = still CPU-bound; headroom is ours.
- STANDING WATCH (operator queue): native/Vulkan re-baseline number on the
  laptop setup owed as the parity denominator — surfaced gently in the
  dashboard digest.

- Worker FIN `8c0eaa20`: DEFAULT-FLIP LANDED at `0fc817b` (`…3848a30 ->
  0fc817b`) — `APPGL_ENABLE_LAZY_SHADOW_CLEARS` default-ON,
  `APPGL_DISABLE_LAZY_SHADOW_CLEARS` hatch, ENABLE=0 honored. 10-phase matrix
  green at the new no-env default; hatch arm green (probe-pinning interaction
  fixed the established way); BAR-B rgba identical. Foreman diff-scope
  verification: `GLContext.mm` +11/−3 + `GauntletRunner.cpp` +4 — flip-shaped,
  confined.
- DEFAULT-FLIP GATE SWEEP DISPATCHED (`79ded4cf`): 0fc817b DEFAULT/no-env,
  EMPTY env proof required (lazy-ON from code); primary baseline = crowned
  3848a30 flag-ON QPA `6d6ba540…04aa` (the map the new default must
  reproduce), secondary = 9ecf45b default repaired `619c7eca…`; quarantine
  protocol standing (19715 expected + 3× no-env sidecar). GPU-YIELD
  SEQUENCING: GLTest piglit-runner live at dispatch (PID 85181, started
  18:51Z, ~19:07Z finish) — Scout does setup/build/publish immediately, HOLDS
  GLCTS launch until the PID exits (escalation guard at +10min). Clerk
  signaled with the corrected window-math. ROTATION ON GREEN per ruling
  `e5ede7b6` — canonical then ships the complete S24 stack (async + fold +
  skip + continuation + keepalive + lazy clears + both correctness fixes) as
  plain defaults: 24fps sprint-start → ~75fps.

- Scout flip-gate setup echo `8f6cf62b`: target
  `0fc817b46c90e3ea800eb28fa606289d869663b4` ancestry-verified; Scout
  independently observed the diff scope (GLContext.mm + GauntletRunner.cpp
  only — matches my verification). Gate artifact SHA256
  `e60256de2b520a2cd9c905e11dcf31964881c67aaa2fc758040394e7a379c165`, UUID
  `1A68DE3F-C094-3B52-B80D-D3CA2AAFDCAD`, release-shape PASS (parent
  `3848a30`). Runner prepared (no-env/default + standing DSA quarantine);
  GLCTS launch HOLDING on piglit PID 85181 exit per sequencing.

- Scout flip-gate LAUNCH `e979d971`: GPU-yield hold cleared cleanly (piglit
  PID 85181 exited ~19:07Z — I verified the same independently), GLCTS
  launched on the published `0fc817b` artifact. Both baseline QPA identities
  re-confirmed at launch (primary crowned-3848a30 `6d6ba540…04aa`, secondary
  repaired-9ecf45b `619c7eca…b95a`). Sequencing worked as designed: setup
  overlapped piglit's tail, zero contention, zero idle gap.

- BUDGET HOLD (Clerk `7ca1bc33`, operator directive): discretionary spend
  paused until next 5h refresh. Critical path continues: receive 0fc817b FIN
  → rotate on green per standing ruling → terse closing digest. Worker pure
  standby; non-essentials batched post-refresh; no ack replies.

- Scout flip-gate progress `cbc434bb`: non-shaders through `ns15_aj` all
  first-try (`ns15_aj` 1500/1500 quarantine-excluded, no rescue — protocol
  holds at the new default); `ns15_ak` running. No-env sidecar already done:
  rc=133/1/133 (trap, clean-Fail, trap) — nondeterminism consistent at the
  flipped default, same debt item.

- Scout FIN flip-gate `27c4cec7` — `0fc817b` DEFAULT/no-env: GREEN. The
  no-env default REPRODUCES the crowned 3848a30 flag-ON effective map EXACTLY:
  19715/19715, `P=19365 F=35 NS=314 IE=1`, zero transitions vs BOTH baselines
  (primary crowned-3848a30 summary `9662ff50…`; secondary repaired-9ecf45b
  summary `aebf9244…`), status_maps_identical_effective=1 both. ns15_aj
  first-try no-rescue; ns15_al 818/818; no-env proof 0 bytes; sidecar 3×
  no-env rc=133/1/133 (AGX asserts 100/150/100 — same debt item); artifact
  `e60256de…c165`/`1A68DE3F` re-confirmed; candidate QPA `50527d4f…5092`.
  Honesty note: wrapper shell lingered post-batch and was terminated; primary
  + secondary summaries written manually from completed QPAs.
- CANONICAL ROTATION EXECUTED (S24 arc close): pin = `0fc817b` via the exact
  swept artifact. `libAppGL-0fc817b-preview-1A68DE3F.dylib` cut (SHA256
  verified identical `e60256de…c165`, UUID `1A68DE3F` re-verified); prior pin
  backed up as `libAppGL-pinned-F39C99D7-backup.dylib` (re-verified
  `2960fd10…` = 9ecf45b); `libAppGL-pinned.dylib` repointed + sidecar updated;
  launcher untouched. THE CANONICAL NO-ENV POSTURE NOW SHIPS THE COMPLETE S24
  STACK AS PLAIN DEFAULTS: async + fold + skip + continuation + keepalive +
  lazy shadow clears + rename-on-write + mirror-family + integer/UNORM clear
  correctness. Canonical Warzone: 24fps (sprint start) → ~75fps — 3.1× in one
  sprint, ~50% of the old native reference. C50 FULLY CROWNED AND SHIPPED
  DEFAULT. Next arc: per-draw GL prep (Worker memo in draft); pending
  operator item: native/Vulkan re-baseline.

- OPERATOR NATIVE RE-BASELINE (Clerk `fdded908`, recorded verbatim; laptop
  setup, same conditions as the 75fps candidate run): Vulkan ~265-290fps;
  Apple native GL ~280-300fps (native slightly ahead). PARITY DENOMINATOR =
  ~290. AppGL at 75 = ~26% of native; remaining gap ~3.9×.
- OPEN QUESTION FOR WORKER'S NEXT WINDOW (re-baseline contradicts the
  C50-verdict ceiling estimate): Worker's control sample attributed
  ~4.5-5ms/frame to game-own work ⇒ implied game wall ~200-210fps — but
  native runs 280-300, so under native the game-side block must be FAR
  smaller. Two lever-shaped candidate explanations: (a) ATTRIBUTION — part of
  the sampled 'game-side' time is AppGL-inflated (game code calling into our
  µs-class dispatch: glGetError / state queries / buffer updates attributed
  to game frames; native per-call ~0.1-0.2µs vs ours ~10×); (b) STRUCTURAL —
  Apple GL + MoltenVK offload driver work to worker threads (kCGLCEMPEngine
  MT engine, the same one that blinded apitrace) while AppGL does ALL
  translation+encode on the game thread. If (b) dominates, the road to ~290
  runs through a driver-thread architecture (app thread records, worker
  thread translates+encodes) — an S25-CLASS STRUCTURAL LEVER, not C51-class.
  Worker reconciliation task: re-read the control sample with (a) in mind +
  scope (b) feasibility. C51 (per-draw GL prep) PROCEEDS UNCHANGED — its
  ~87fps floor stands on its own arithmetic.

- OPERATOR FOLLOW-UP DATUM (Clerk `b39db9b9`, recorded verbatim): native-
  driver run shows ~30% TOTAL CPU across ~21 threads with GPU 90%+ fed —
  against AppGL's one-core-saturated / GPU-37% profile. UPGRADE: explanation
  (b) is EMPIRICALLY CONFIRMED as the dominant structural factor — native's
  win is parallel pipeline architecture, not per-call cost alone. The
  GPU-feed ratio (37% vs 90%+) tracks the fps ratio (75 vs ~290) almost
  directly.
- Tracker updates per adjudication: (1) hypothesis (b) status: open-question
  → CONFIRMED-DOMINANT, magnitude TBD — Worker's next-window re-read now
  QUANTIFIES the (a)-dispatch-inflation vs (b)-serialization split rather
  than adjudicating between them. (2) DRIVER-THREAD ARCHITECTURE = formal
  S25 ARCHITECTURE CANDIDATE (app thread records → worker threads
  translate+encode; + whatever Metal parallelRenderCommandEncoder affords).
  Scope question BANKED for Worker: what does AppGL's current design assume
  about thread affinity (GL context-current semantics, Metal object
  lifetimes), and what is the cheapest staged path — single worker thread
  first (Apple's own MT-GL kCGLCEMPEngine shape) before any fan-out?
  (3) C51 unchanged; NOTE: single-thread wins COMPOUND with the future
  architecture (less work per frame = less work to parallelize).

## C51 ARC — PER-DRAW GL PREP (s24-c51-prep-memo)

- OPERATOR GO 2026-06-11 (Clerk `52a77bdf`): C51 implementation ACTIVE —
  Worker on a 4-commit train per the accepted design; floor revised honestly
  to 81-83fps; encode-side C52 to follow from live data. GATE-TRAIN SEQUENCE
  OF RECORD: (1) Foreman verifies each landing SHA per the established
  pattern (commit structure, diff scope vs design contract, local gate
  evidence); (2) train-complete → ONE default sweep (flag-off equivalence) +
  ONE flag-ON sweep (`APPGL_ENABLE_DRAW_PREP_MEMO=1`), isolated checkouts,
  quarantine protocol standing, baselines = current canonical (0fc817b-era)
  maps; commit-1 (gen-plumbing) is observation-only and rides the train;
  (3) GLTest synthetic window AFTER sweeps (WarmFullKeyRepeat vs RealApp arms
  per plan of record; Clerk grants window + vendor SHA); (4) operator live
  A/B package, C50 pattern. 

- C51 BATCH 1 LANDED (Worker FIN `2026202c`; commits 1+2 of 4, clean
  partial-train handoff). FOREMAN VERIFICATION (established pattern): commit
  structure correct — exactly `032dc9b` + `6272b0c` atop canonical `0fc817b`.
  COMMIT 1 `032dc9b` (observation-only): insertions-only +34 across
  GLStateTracker.{cpp,h} + texture/sampler funnel files — monotonic
  stateGeneration bumped by all 48 markDirty sites + 7 non-dirty-system
  binding mutators + texParameter*/samplerParameter* funnels;
  glUniformSubroutinesuiv deliberately non-bumping (subroutines =
  never-memoized class via per-draw hazard recompute, documented in-commit).
  COMMIT 2 `6272b0c`: memo behind `APPGL_ENABLE_DRAW_PREP_MEMO` default-off
  (drawPrepMemoEnabled() gate verified at the instanced-elements builder);
  +280 lines of probes in GauntletRunner; HIT skips fixed-function/program-
  pointers/VAO-apply/UBO-SSBO-image/FBO-resolves with ratified carve-outs
  (sampler resolve ALWAYS runs + clears push vectors on reuse; uniforms +
  liveBind stamps always run; hazard recomputed every draw).
  DEFAULT-PATH NUANCE PINNED: the binding-setter EARLY-RETURN on
  value-identical rebinds (GLStateTracker.cpp) is LIVE ON THE DEFAULT PATH
  (not flag-gated) — disclosed by Worker, correctness-neutral by argument
  (no-op rebind = no state change), required for the memo to ever hit, and
  itself shaves dispatch work. The train's DEFAULT sweep is the formal gate
  for exactly this delta (flag-off equivalence) — noted so the sweep's
  purpose is explicit.
  EVIDENCE on record: 4 probes green incl. gold hazard probe (real subroutine
  program never memo-hits while every draw renders freshly-selected
  subroutine), same-state 3-hits-with-uniforms, dirty-must-miss busts on
  blend toggle + texture rebind, default-off zero-activity; 11-phase matrix ×
  canonical + memo-on ALL GREEN; BAR-B rgba identical both arms. Tree clean
  at `6272b0c`. REMAINING (next window): lever-2 plan-reuse-on-HIT, resize
  rider (log-first) + PSO trace line, drawArrays builder extension. No sweep
  yet per gate plan — twin sweeps come at train-complete.

- TRACKER CORRECTION (Clerk `cdb5bbd0`, per Worker's gating audit): the
  batch-1 equivalence claim is formally SPLIT — `032dc9b` =
  observation-only/default-path-equivalent ✓; `6272b0c` = NOT
  default-path-equivalent — it carries UNCONDITIONAL early-returns on
  value-identical rebinds in SIX GLStateTracker setters alongside the
  flag-gated memo. The train's DEFAULT sweep is therefore THE GATE that
  proves the early-returns safe — not a formality. (Supersedes the softer
  "nuance" framing in the batch-1 entry above.)
- FOREMAN DIFF-SCOPE VERIFICATION (Clerk item 2, executed): `032dc9b` is
  PURE-ADDITIVE — 34 insertions, ZERO deletions, counters/bumps only ✓.
  `6272b0c` delta composition confirmed = (a) flag-gated memo (key-struct
  fields + drawPrepMemoEnabled()-gated builder path), (b) exactly SIX
  GLStateTracker early-return sites (bufferBindings / texture-unit binding /
  activeTextureUnit / sampler / vertexArray / program — all
  value-identical-compare + return), (c) +280 lines GauntletRunner probes,
  (d) AppGLRuntime diagnostics export (prepMemoHits/Misses/Busts counters).
  NOTHING ELSE ✓.
- S25 CLEANUP-DEBT LINE ITEM (Worker audit, Clerk-directed): VESTIGIAL
  DIRTYBIT PLUMBING — the DirtyBit system is WRITE-ONLY (zero consumers
  outside the tracker); all real bind side effects live at the GLContext
  layer (untouched by the early-returns). Remove/retire the dead plumbing in
  S25 cleanup.

- C51 BATCH 2 LANDED (Worker FIN `41446ef3`): `8b786f4` — TRAIN COMPLETE
  (with one deferral + one escalation). FOREMAN VERIFICATION: single commit
  atop `6272b0c`, +49/−2 across GLContext{.h,.mm,DrawBaseVertex},
  MetalFrameGraph (PSO trace enrichment), AppGLRuntime (counter export),
  GauntletRunner (probe extension). LEVER 2: plan-key reuse on prep-memo HIT
  — skips phase2PlanCandidateKeyForDraw (the 16% bucket); cache FIND still
  runs (eviction + force-miss safe); reachable only on memo hit = flag-gated
  by construction; `prepMemoPlanKeyReuses` counter; probes assert
  reuse-engages-on-hit + busted-memo-rebuilds-key. All probes green; 11-phase
  matrix both postures green; BAR-B identical. PSO TRACE LINE firing
  (attr0Stride=8 attr0Fmt=0x1406/2/0 on BAR-B).
- DRAWARRAYS EXTENSION DEFERRED (rationale on record): 5 separate tdi sites
  at 3.3% sample share vs the wired hot builder's 8.8%; extension follows
  live A/B data — mechanical follow-up if drawArrays-class miss share is
  meaningful.
- ESCALATION (needs Clerk adjudication, NOT landed): DRAWABLE-EXTENT THRASH.
  Worker's log-first rider found the extent-equality early-out ALREADY EXISTS
  (drawableResizeNoops): control capture = 2.24M resize calls / 2.22M
  correctly no-op'd / 19,535 ACTUAL transitions ≈ ~1.0 REAL drawable resize
  per frame — the extent thrashes between two sizes every frame, each
  transition releasing+recreating the default depth texture; this is the
  canonical ~3.3% invalidate+drainAll chain + per-frame texture recreation.
  Fix candidates: (i) grow-only default flip (VRAM tradeoff — drawable pins
  at max requested); (ii) find the caller alternation (likely viewport-driven
  ensureSizeAtLeast grow vs present-driven shrink). Routed to Clerk.
- TWIN SWEEPS DISPATCHED (msg above): target `8b786f4`, both on same
  artifact back-to-back (no GPU contention verified, GLTest window follows
  sweeps). Sweep (a) DEFAULT = THE PROVING GATE for the six unconditional
  early-returns (binding-coherence watch order); sweep (b) FLAG-ON
  (`APPGL_ENABLE_DRAW_PREP_MEMO=1`) gates memo + plan-key-reuse (draw-path +
  subroutine watch order). Quarantine standing both; baselines = 0fc817b
  primary (`50527d4f…5092`) + crowned-3848a30 secondary. Tree clean at
  `8b786f4`.

- Clerk trigger confirmation `afd411d0` (crossed with my dispatch — same
  sequence; on record): drawArrays deferral RATIFIED as data-gated (extends
  only on meaningful drawArrays-class miss share in the live A/B; mechanical
  follow-up). RESIZE-THRASH = NEW INVESTIGATION LANE (Worker dispatched by
  Clerk directly); any fix lands AFTER the C51 chain closes, as its own gated
  train — the current sweeps stay clean of it. Twin-sweep note: dispatched as
  back-to-back on one artifact (GLTest window follows the sweeps, so no
  yield boundary between (a) and (b); GPU verified clear at dispatch); single
  dispatch signal covers both.

- Scout twin-sweep artifact echo `054ee8f7`: `8b786f42dd92e81b3f2c090826de
  313f5315898e` ancestry-verified through the full train; shared gate
  artifact SHA256
  `b29be6907138c54b5f9759f1f52d58b349c810fe300d1e832b9fbb81a24b19fa`, UUID
  `8F27C479-420A-3ECB-8743-2190AE5C5FE0`, release-shape PASS (parent
  `6272b0c`). Both baseline QPAs confirmed; GPU clear at preflight; sweep (a)
  DEFAULT first, then (b) flag-ON, same artifact. Identity forwarded to Clerk
  for the GLTest vendor-SHA grant.

- Sweep (a) DEFAULT/no-env GREEN (`8abb94e2`): 19715/19715, counts identical
  (`P=19365 F=35 NS=314 IE=1`), zero transitions vs BOTH baselines,
  status_maps_identical_effective=1. THE PROVING GATE HOLDS — the six
  unconditional GLStateTracker early-returns are conformance-proven safe on
  the default path. Sidecar no-env rc=1/1/133 (same debt signature). Sweep
  (b) flag-ON launched immediately on the same artifact.

- SWEEP (b) RED SIGNAL (`6eb85262`, pre-FIN): flag-ON batch completed
  19715/19715 but `P=19360 F=40` vs canonical `P=19365 F=35` — 5 P->F, ALL in
  `KHR-GL46.draw_elements_base_vertex_tests` (AEP_shader_stages,
  basevertex_behavior1, basevertex_behavior2, overflow, underflow). EXACTLY
  the dispatched watch family (draw-path/baseVertex). Sweep (a) default
  remains GREEN — the regression is memo-flag-arm only. Foreman triage prior:
  the memo key likely misses a baseVertex-class draw-parameter input — a draw
  differing only in basevertex hits the memo and reuses stale prep (same
  hidden-dynamic-input class as the S23 SSO+subroutine catch). Scout directed
  to add a 5-case ON/OFF ownership probe (2× per arm) + failure-class detail
  to the combined FIN. Chain consequence pending Clerk: GLTest window + A/B
  hold against the red arm.

- Clerk ADJUDICATION `f31e2566` — all three adopted: (1) 5-case repro to
  Worker (Clerk dispatching); (2) GLTest synthetic + operator A/B HELD until
  the flag arm re-greens (lever-owned, correctly distinguished from C50's
  refuted hold); (3) canonical untouched — sweep (a) green STANDS as the
  early-returns proof; re-sweep scope = flag-ON only unless Worker's fix
  diff touches non-gated code (Foreman diff-scope verification decides).
  Watch-order first-call noted as the system working. Foreman forwards
  Scout's ownership probe + combined FIN to the triage thread on landing.

- Scout COMBINED TWIN-SWEEP FIN `4b14d4d3` (8b786f4, shared artifact
  `b29be690…19fa`/`8F27C479`): (a) DEFAULT GREEN / (b) FLAG-ON RED,
  deterministic, flag-owned.
  SWEEP (a): 19715/19715, `P=19365 F=35 NS=314 IE=1`, zero transitions vs
  both baselines, maps-identical=1; candidate QPA `e3b8ef97…611b`; summaries
  `480ce1ef…` / `82137bb1…`; env proof 0 bytes; sidecar rc=1/1/133.
  SWEEP (b): 19715/19715, `P=19360 F=40` — 5 P->F, all
  `draw_elements_base_vertex_tests` (AEP_shader_stages, behavior1, behavior2,
  overflow, underflow), same 5 vs both baselines; candidate QPA
  `ae6edaf8…78dd`; summaries `357f0f22…` / `ed1ffd2c…`; env proof flag-only;
  sidecar rc=1/133/133 (same debt signature).
  OWNERSHIP PROBE (directed, 2× per arm, same artifact): flag-OFF run1+run2 =
  5/5 Pass; flag-ON run1+run2 = 5/5 Fail — DETERMINISTIC BOTH ARMS,
  flag-owned, no coin-flip ambiguity (summary `409270f4…`; 4 QPA hashes
  recorded in the FIN). FAILURE CLASS: render-validation, NOT API-error —
  `Pixel mismatch at esextcDrawElementsBaseVertexTests.cpp:419` /
  reference-texture-not-changed at `:439`. Consistent with stale-prep-reuse
  (memo HIT on a draw differing only in basevertex → wrong vertex offsets
  rendered).
  CROSS-CHECKS: texture_barrier 8/8 both sweeps; zero subroutine rows in
  either transition TSV (never-memoized class held); stderr residuals
  known-bucket (MSL negative-cache 16/16 both arms, zero CmpFlip/helper).
  Honesty note: lingering-wrapper-shell issue recurred post-batch (inherited
  harness trait, 3rd occurrence); summaries written manually from completed
  QPAs; no stray processes.

- Clerk `50ddae6e` (DIR-FIN): FIN routing accepted; the two negative
  confirmations formally noted as the fix's bracketing (subroutine
  transitions ZERO = never-memoized carve-out empirically held;
  texture_barrier 8/8 both arms = C50 fix robust under the memo).
  WRAPPER-SHELL LIFECYCLE: graduated at 3 occurrences from note to APPROVED
  QUIET-WINDOW TASK — Scout root-causes and fixes the harness wrapper-shell
  lifecycle when next idle post-C51-chain (their tooling, isolated from
  runtime). Queued for dispatch to Scout at chain-close.

- Worker TRIAGE FIN `2e86b129` — basevertex red FIXED at `99140ca`. THREE
  STACKED KEY GAPS (both seeded priors latent, neither root): (1) ROOT — FBO
  ATTACHMENT mutations changed no generation: CTS re-attaches a different
  texture to the SAME FBO name between draws → same drawFbo name + same
  stateGen → memo HIT → skipped resolveFBOColorTarget → drew into the
  PREVIOUS texture ("draw did not change the texture", verbatim);
  framebufferTexture/framebufferRenderbuffer/drawBuffer/drawBuffers now bump
  stateGeneration. ACCOUNTABILITY (Worker, recorded in-commit): the design
  doc listed FBO-attachment sites as 'VERIFY each calls markDirty' and the
  verification was never done — the exact class the verify item existed for.
  (2) LATENT (Foreman's prior): plan-key reuse ignored per-draw params
  feeding plan identity; reuse now requires a draw-parameter signature match
  (field-for-field mirror of phase2 per-draw inputs, per-param disposition
  documented; primitive-restart stateGen-covered; new counter
  prepMemoPlanKeyDrawSigMisses). (3) LATENT: conditionally-set per-draw
  fields — metalIndexBuffer/Offset now reset before their conditionals on
  the HIT path (stale Metal index buffer = vanished-geometry shape).
  EVIDENCE: 5-case harness flag-ON 11/12 pass 0 fail (1 NotSupported =
  baseline); PROBE EXTENSION landed: c51.prep-memo.draw-param-variation
  (basevertex-only variation + attachment-swap-on-same-FBO-name gold leg);
  11-phase matrix both postures green; BAR-B identical.
- FOREMAN DIFF-SCOPE VERIFICATION of `99140ca` (rules re-sweep scope):
  +176/−2 across GLContext.mm (draw-sig struct + comparison — memo-gated),
  DrawBaseVertex.inc.mm (+7, HIT-path field resets — gated),
  GLContextFramebuffer.inc.mm (+12 — the four FBO bump sites, UNCONDITIONAL
  but dead-counter-class flag-off, no flag-off reader, 032dc9b-class),
  GauntletRunner (+98 probes). NO new flag-off control flow, NO new
  early-returns outside memo code. VERDICT: FLAG-ON RE-SWEEP ONLY; default
  arm unaffected; sweep-(a) green stands. Re-sweep dispatched to Scout
  (watch order: 5 cases flip-to-Pass in batch map, FBO/attachment families,
  draw-path + subroutine re-confirm). GLTest + A/B unhold on green.

- METHODOLOGY RULE (Clerk `3a077a90`, born from Worker's accountability note
  — recorded with credit): DESIGN-DOC 'VERIFY' ITEMS ARE GATES — any design
  doc line of the form "VERIFY each X does Y" requires an EXPLICIT
  CHECKED-ENTRY in the implementing commit (verified site list or
  counter-evidence), enforced at adjudication. An unverified VERIFY item is
  an open hazard, not a TODO: the C51 root cause (FBO-attachment sites
  listed as 'VERIFY each calls markDirty', never verified, shipped as a
  silent key gap) is the canonical instance.
- Clerk sequence note (`3a077a90`, crossed with my execution): diff-scope +
  flag-ON-only dispatch already executed and conclusions match (counters-
  only default delta confirmed → no default arm). On flag-ON green: GLTest
  all-clear is Clerk's, with 99140ca artifact re-vendor required (their
  vendor pin is 8b786f4) — the new artifact identity rides my green report.
  Then the operator A/B package at 99140ca.

- Scout fix-gate artifact echo `25f335cf`: `99140ca95f7dd62583e23fbe1bd8af5d
  6b60c289` full-train ancestry verified; diff scope independently observed
  (matches my verification). Gate artifact SHA256
  `e53985c2f573b59a8ce6e5550abe353b063fb96c962c5a9445ba8b6ceb3ef0ce`, UUID
  `5BF13F0B-D898-3B95-AF60-A05D29586441`, release-shape PASS (parent
  `8b786f4`). Baselines confirmed; flag-ON quarantine runner preparing.
  This identity = GLTest's re-vendor target on green.

- Scout FIN fix gate `7368f2e2` — `99140ca` FLAG-ON: GREEN. 19715/19715,
  counts back to canonical (`P=19365 F=35 NS=314 IE=1`), zero transitions vs
  BOTH baselines, maps-identical=1 (primary summary `d9904812…`, secondary
  `82137bb1…` — byte-identical to sweep-(a)'s secondary, as expected for
  identical maps). WATCH-ORDER EVIDENCE ALL CLEAN: the 5 base_vertex cases
  Pass IN THE BATCH MAP; zero FBO/attachment rows; zero
  draw/basevertex/indirect/instanced rows; zero subroutine rows;
  texture_barrier 8/8. Candidate QPA `44df4004…52d6`; env proof flag-only;
  sidecar rc=133/1/133 (same debt signature, hashes recorded); stderr
  residuals known-bucket (MSL negative-cache 16, zero CmpFlip/helper).
  Wrapper-linger trait recurred (4th) — already an approved quiet-window
  task. C51 FLAG ARM RE-GREENED: the triple-stacked key fix is
  conformance-proven; GLTest synthetic + operator A/B UNHOLD per ruling.

- C51 A/B PACKAGE STAGED ON DISK (digest holds until post-GLTest-window per
  Clerk sequence): candidate pin `libAppGL-99140ca-preview-5BF13F0B.dylib`
  cut from the swept fix-gate artifact (SHA256 verified identical
  `e53985c2…f0ce`, UUID `5BF13F0B` re-verified, sidecar written). Wrappers
  both sh -n clean + executable: CONTROL
  `launch-warzone-appgl-99140ca-operator-control.sh` = canonical 0fc817b
  posture on frozen 1A68DE3F pin, no APPGL env; CANDIDATE
  `launch-warzone-appgl-99140ca-operator-candidate.sh` = frozen 99140ca pin
  + `APPGL_ENABLE_DRAW_PREP_MEMO=1`. 210s each, full capture, per-run
  identity proofs + canonical cross-proof, mid-game `sample` Foreman-side
  per arm. Art roots `memory-runs/99140ca-prep-memo-ab/{control,candidate}/`.
  Sequence: GLTest synthetic window (Clerk all-clear + re-vendor to
  `e53985c2…`/`5BF13F0B`) → operator A/B vs the 81-83fps floor.

- C51 GATE-1 FAILED (Clerk `1e629682` — GLTest synthetic, WRONG-DIRECTION):
  the memo's HIT PATH regresses its target workload +286%. Engagement proven
  at 99.98% hit rate, so the regression IS the hit path itself; miss and
  control arms clean. Conformance-green ≠ perf-green — the flag arm is
  correct but slower. OPERATOR A/B HELD: the staged 99140ca package stays ON
  DISK, UNPOSTED (wrappers + pin remain valid for re-stage only if the fixed
  SHA preserves them; expect a re-cut). Mechanism investigation dispatched
  to Worker by Clerk (shared-persistent-tdi / Metal-hazard hypothesis).
  Sequence: fix → mode-10 synthetic re-verification → A/B re-stages on the
  fixed SHA. CANONICAL UNTOUCHED THROUGHOUT (lever default-off; sweep-(a)
  proof unaffected).
- TRIPLE-GATE DISCIPLINE NOTE (on record): Gate-1's reject-rule fired
  exactly as the S24 plan wrote it — "reject levers that do not move the
  synthetic probe" — AMENDED per this instance: ...or move it BACKWARD. The
  gate caught a +286% hit-path regression BEFORE any operator minutes were
  spent; the sequencing (synthetic between conformance and live A/B) earned
  its place in the chain.

- MECHANISM VERDICT updates (Clerk `4b593ae5`): (1) GLTest's serialization
  hypothesis REFUTED — pass census identical memo-on/off (refutation method
  credited); the +286% re-attributed to DUPLICATE PER-DRAW HAZARD RECOMPUTE
  on the hit path: the memo's safety guard recomputed the hazard the prep
  path ALSO computed, and the guard cost ate the prep savings. Stage-A fix
  in flight (single-compute + carried verdict); Stage-B (shallow-copy) HELD
  pending the amplification attribution run now executing at GLTest.
  (2) The 4× HARNESS AMPLIFICATION = OPEN question; attribution run
  capturing its signature pre-Stage-A. (3) NEW CORRECTNESS-TRAIN ITEM:
  latent glFinish-on-open-continued-pass crash seam ("command encoder
  already encoding") — CANONICAL-REACHABLE, diag-shape-only today, but
  LEGACY-CORPUS-CRITICAL (pre-3.0 apps call glFinish constantly; S24-compat
  relevance). The banked resize-gate train is now a TWO-FIX CORRECTNESS
  TRAIN (resize-gate + glFinish-funnel), post-C51, one gate set.
  (4) SEQUENCE OF RECORD: Stage A → attribution read → Stage B y/n →
  mode-10 reverify → correctness train → operator A/B.

- Worker STAGE A LANDED `33efd7f5`: `d3e62ea` — local regression was the
  duplicate hazard scan + TWO PER-DRAW getenv ENVIRON SCANS in the flag
  check. Fix: builder carries hazard verdict on the tdi
  (hazardPrecomputed/Value, wrapper consumes) + flag latches PER-CONTEXT
  (fresh probe contexts keep toggling; draws pay zero getenv). LOCAL RESULT:
  warm diag +11.7%-consistent → within-noise across 3 runs
  (−2.5/+5.6/−3.6%); Worker's gauntlet resolves only ±5% — definitive
  magnitude belongs to GLTest mode-10 (0.1µs) on d3e62ea AFTER the
  attribution run on the UNFIXED artifact (evidence-preservation ruling).
  Matrix green both postures; probes green; BAR-B identical. PREDICTION ON
  RECORD: same-guard-class amplifier ⇒ d3e62ea near-parity-or-better warm;
  different per-frame-scaled signature (avgNonRender 1.3→5.6ms) ⇒ Stage B
  (shallow-copy), census+sample says what to copy vs share.
- FOREMAN DIFF-SCOPE of `d3e62ea`: +102/−9 — GLContext.mm (hazard dedupe +
  flag latch), DrawBaseVertex (+6 tdi consume), MetalFrameGraph.h (+5 tdi
  fields), GauntletRunner (+69 probes). DEFAULT-PATH RULING: the flag check
  runs on every draw, so the per-context latch DOES change default-path code
  — but it is semantically equivalent for any fixed environment (latched
  getenv=null ≡ per-call getenv=null; only mid-process env mutation could
  diverge, unsupported posture, GLCTS subshells fix env). Ruling:
  equivalence-class refactor, NO default re-sweep triggered by Stage A
  alone. RECOMMENDATION ON RECORD: one flag-ON conformance re-sweep at the
  FINAL C51 SHA (post Stage-B-y/n) before the operator A/B re-stage —
  mode-10 is perf-only and Stage A touches hit-path execution order.

- Clerk `ec4f9c57` (DIR-FIN): BOTH RULINGS RATIFIED — (1) getenv-latch
  equivalence-class call correct and correctly surfaced; no default re-sweep
  from Stage A alone. (2) Flag-ON conformance re-sweep at the FINAL C51 SHA
  ADOPTED into the sequence of record (swept artifact cuts the A/B candidate
  pin — single-source discipline). SEQUENCE OF RECORD (current): attribution
  read → Stage-B y/n → mode-10 reverify → flag-ON conformance re-sweep at
  final SHA → correctness train (resize-gate + glFinish-funnel) → operator
  A/B.

- FOREMAN ARTIFACT CUT (Clerk `35d8d17f` — new STANDING PATTERN: Foreman
  cuts + attests artifacts for perf-only iterations when no sweep artifact
  exists): `d3e62ea` built from a clean isolated git-worktree checkout
  (`foreman-worktree/checkouts/appgl-d3e62ea-c51-stagea`, HEAD verified
  `d3e62eaa75…6532`, tracked files clean), era-correct vendors copied from
  the 99140ca Scout checkout (SPIRV-Cross `601164c` exonerated-era, glslang
  `dcf1aaa`). CONFIG TRAP CAUGHT + RECORDED: standard config requires
  `-DAPPGL_VENDOR_THIRD_PARTY=ON` in addition to Release + FP64-emulation-ON
  (default-OFF silently drops the vendored subdirectories → spirv.hpp
  include failures); first build failed, reconfigured, clean rebuild.
  PUBLISHED: `foreman-worktree/checkouts/appgl-d3e62ea-c51-stagea/
  gate-artifacts/d3e62ea-s24-c51-stagea-mode10/libAppGL.dylib` — SHA256
  `0f2e784dac843f5526c8fee0f29b97def26b9ed8c9e3115e8ade834570914c2f`, UUID
  `E3A78018-253A-3F71-8C9F-1B674EC5CEB4`, install-name `@rpath/libAppGL.dylib`,
  codesign valid. Identity triple relayed to Clerk for GLTest's mode-10
  reverify.

- Worker STAGE B LANDED `72c69119` / Clerk `10338bfb`: `158fb64` — GATE-1
  MYSTERY CLOSES IN ONE ROOT CAUSE: the lever-2 reuse splice wrapped TOO
  MUCH — it skipped the candidate-key computation AND the decision tree
  containing the cache FIND, so on every memo HIT the find never ran,
  `tdi.translatedPlan` stayed NULL, and `encodeTranslatedDrawSerial` took
  the no-plan heavy path (per-draw pipelineCacheKey recompute + MSL slot
  needle-scans over the FULL shader source). ALL LOOSE ENDS TIE OFF: (a) the
  3.9× Serial cost with zero memo-conditional branches = data-shaped
  (translatedPlan==nullptr); (b) the magnitude gap (+286% GLTest vs +11%
  Worker-local) = needle-scans scale with MSL LENGTH (WZ-size shaders vs
  gauntlet quads); (c) the same scan family as the C52 sample-mask lever —
  now TRIPLY evidenced as encode-side cost. FIX: shortcut skips ONLY the key
  compute; the shared decision tree (force-miss, find, hit/miss bookkeeping)
  runs on both paths. Local: warm ON≤OFF all 3 runs (−1.7/−0.3/−9.3%);
  matrix green both postures; BAR-B identical. PRE-REGISTERED EXPECTATION:
  parity-or-BETTER vs GLTest's 6.0µs OFF baseline.
- FOREMAN DIFF-SCOPE of `158fb64`: ONE file, GLContext.mm +19/−14, entirely
  within the memo/plan-cache decision-tree splice (comments + candidate
  logic) — memo-arm only, NO default-path delta. No default re-sweep; the
  adopted flag-ON conformance re-sweep at the final C51 SHA (= 158fb64 if
  the reverify holds) covers conformance.
- PATTERN-BANK ENTRY (Clerk-directed; C50 leak-probe≠coherence SIBLING at
  the perf-gate level): ENGAGEMENT ≠ BENEFIT — `prepMemoPlanKeyReuses`
  counted engagement while every hit was LOSING its plan. An engagement
  counter proves a mechanism FIRED; only output-cost validation (the
  synthetic gate) proves it HELPED. Both axes required for any
  cache/memo/shortcut lever — joins leak-probe≠coherence (memory axis vs
  data-coherence axis) as the perf-axis instance of the same
  one-axis-validation trap class.

- FOREMAN ARTIFACT CUT #2 (standing perf-iteration pattern): `158fb64` built
  clean from isolated worktree
  (`foreman-worktree/checkouts/appgl-158fb64-c51-stageb`, HEAD verified
  `158fb64f0d…2e14`, tracked clean), same era-correct vendors, full standard
  config (Release + FP64-ON + VENDOR_THIRD_PARTY=ON — the recorded trap
  avoided). PUBLISHED:
  `gate-artifacts/158fb64-s24-c51-stageb-mode10/libAppGL.dylib` — SHA256
  `f4a1c115b41879944878e6783785a086ec7d21324fe1dd11233c6e0b31bed400`, UUID
  `B4790195-E93A-343C-9FDE-3E54148D1B03`, install-name `@rpath/libAppGL.dylib`,
  codesign valid. Triple relayed to Clerk → GLTest mode-10 reverify vs the
  6.0µs OFF baseline (pre-registered expectation: parity-or-better).

- Clerk ordering ruling `0a03dd1c`: REVERIFY FIRST (decision-bearing perf
  gate — a Stage-B miss would waste the sweep), conformance re-sweep SECOND
  on explicit Clerk signal after the verdict lands on-thread. 158fb64 triple
  relayed to GLTest, reverify firing. Scout dispatch packet held ready
  (target 158fb64, flag-ON, quarantine standing, baselines = current
  canonical maps + crowned-3848a30 secondary; the swept artifact would NOT
  cut the A/B pin this time — the A/B candidate pin cuts from MY attested
  158fb64 artifact or the sweep artifact per single-source discipline at
  staging time; resolve at dispatch).

- MODE-10 REVERIFY VERDICT on `158fb64` (Clerk `4ce1c161`): CONTRACT UNMET —
  warm arm +69% residual vs the ≤OFF expectation. LARGE PARTIAL WIN: 76% of
  the Gate-1 overhead removed (Stage A+B real), but parity-or-better did not
  hold; ~4.1µs/draw remains unattributed on the hit path. SWEEP HOLD
  CONFIRMED: Scout was never dispatched (packet held pending explicit GO per
  the ordering ruling — the reverify-first ordering earned its keep: a
  wasted sweep was avoided). DECISION PROCESS: GLTest runs one
  residual-attribution sample on 158fb64 (name the remaining 4.1µs/draw) →
  Worker reads → STAGE-C-SURGICAL vs ACCEPT-AS-IMPROVED-and-judge-on-real-app.
  158fb64 is NOT final-C51 until that resolves; a Stage-C commit would
  supersede the SHA.
- OPERATIONAL NOTE (Clerk-directed): operator's permissions editor broken;
  DURABLE IN-SESSION EXPRESS AUTHORIZATION granted for the iteration class —
  Foreman artifact-cut iterations now run operator-free (forward-durable
  express auth case on record).

- RESUME (Clerk `c8fd4b62`, operator signal): residual attribution LANDED —
  Stage-B's target is AT PARITY (the plan-loss fix fully held); the +69%
  residual is LOCALIZED to one inlined encMark-body region. The
  delta-symbol attribution method is noted VALIDATED (Clerk's 3-way table
  reference; full table lives with the GLTest/Worker exchange). Worker is
  ruling ELIMINABLE-vs-INHERENT at source now. FOREMAN POSTURE: sweep HOLD
  continues until the ruling names the FINAL SHA (Stage-C commit vs 158fb64
  as-is); on the ruling the chain runs: conformance re-sweep at final SHA →
  DocWorker boundary signal → correctness train (resize-gate +
  glFinish-funnel) → operator A/B. GLTest hot; ruling expected shortly.

- Worker STAGE-C RULING + LANDING `9ba21976`: ELIMINABLE — `dd0361d`
  (cumulative atop 158fb64). ROOT: the wrapper's per-draw MARKING LOOPS
  iterate `tdi.sampledTextureNames`; resolveSamplerBindings (the always-run
  carve-out) APPENDS per draw, and the hit path cleared
  fragmentTextures/vertexTextures but NOT sampledTextureNames → vector grew
  across hits → O(n²) marking per frame. Every datum clicks: hit-specific ✓,
  encMark-body-not-Serial ✓, +4.6µs/draw on TEXTURED GLTest warm but
  invisible on UNTEXTURED gauntlet quads (empty vector — why local read
  parity at Stage B) ✓, near-absent OFF ✓. AUDIT CLOSED EXHAUSTIVELY: the
  conditionally-accumulated-vector class now enumerated over every container
  the always-run blocks touch (fragment/vertex/sampledTextureNames cleared
  on hit; readImage/writtenImage/UBO/SSBO/atomic vectors live in SKIPPED
  blocks, cannot grow). Second member of the conditionally-set-field class
  from the basevertex triage — family now enumerated, not instance-chased.
  Local instrument BLIND to this one by construction (untextured) — GLTest
  textured mode-10 is the resolving gate; probes + matrix green, BAR-B
  identical. PRE-REGISTERED EXPECTATION for the run that counts: warm ON ≤
  6.0µs OFF (Stage B plan parity + Stage C marking fix + prep skips).
- FOREMAN DIFF-SCOPE of `dd0361d`: ONE file, GLContextDrawBaseVertex.inc.mm,
  +7 insertions ONLY (the hit-path clear) — memo-arm only, no default-path
  delta. Artifact cut in progress (express-auth class).

- FOREMAN ARTIFACT CUT #3 (express-auth class): `dd0361d` built clean from
  isolated worktree (HEAD verified `dd0361d7fb…7eaf`, tracked clean), era
  vendors + full standard config. PUBLISHED:
  `foreman-worktree/checkouts/appgl-dd0361d-c51-stagec/gate-artifacts/
  dd0361d-s24-c51-stagec-mode10/libAppGL.dylib` — SHA256
  `328c5f9d065a193ab673a4527690757ffde74115544bb0701c190aa247495129`, UUID
  `4C8EB4E3-F6E8-37D6-9EB8-771E9CD60C13`, install-name correct, codesign
  valid. Triple to Clerk → GLTest reverify (THE RUN THAT COUNTS: warm ON ≤
  6.0µs OFF). On green: dd0361d = C51 FINAL SHA.

- STAGE-C REVERIFY VERDICT (Clerk `a6033d29`): GREEN AND EXCEEDED —
  bv_warm ON 5.117µs vs OFF 5.952µs = −14.0%. THE MEMO NOW BEATS FLAG-OFF ON
  MAXIMAL REDUNDANCY (its own worst-case synthetic). Engagement 99.98%
  intact; integrity clean. GATE-1 TRAJECTORY ON RECORD: +286.5% → +69% →
  −14% (Stage A guard-dedupe → Stage B plan-on-hits → Stage C marking-loop).
  Gate-1 formally PASSES at −14% pending the conformance gate.
- FINAL-SHA CONFORMANCE GATE DISPATCHED (Scout, flag-ON at `dd0361d`):
  full-ancestry verify, held-packet baselines, quarantine standing, watch
  order base_vertex-retention → FBO/attachment → draw-path/subroutine →
  TEXTURE families (Stage C touched texture-name marking). Swept artifact
  cuts the A/B candidate pin (single-source). ON ITS GREEN: (1) dd0361d =
  C51 FINAL, Gate-1 passed; (2) DocWorker boundary signal (032dc9b..dd0361d)
  — Clerk sends; (3) correctness train GO for Worker (resize-gate +
  glFinish funnel); (4) operator A/B package — control canonical-0fc817b vs
  candidate dd0361d+DRAW_PREP_MEMO=1, C50 pattern, 81-83fps floor with a
  worst-case-winning candidate.

- Scout final-gate artifact echo `07e21a55`: `dd0361d` full-ancestry verified
  (both branches of the train). Swept gate artifact SHA256
  `e5faacbb30e7907fdde0b22bd5ece9a7c45f872e296f81873261ababeffe042a`, UUID
  `607F6C36-2130-3E7D-A7D2-724AB4112E53`, release-shape PASS (parent
  `158fb64`). Baselines confirmed. THIS artifact cuts the A/B candidate pin
  on green (single-source; supersedes my mode-10 attestation artifact
  `328c5f9d…`/`4C8EB4E3` for operator use — mine remains the perf-gate
  record). Launch follows preflight.

- Scout FIN FINAL-SHA GATE `ca4abb8c` — `dd0361d` flag-ON: GREEN.
  19715/19715, counts canonical (`P=19365 F=35 NS=314 IE=1`), zero
  transitions vs BOTH baselines, effective maps identical (summaries
  `d9904812…` / `82137bb1…`); candidate QPA `366dad06…e07f`. WATCH ORDER ALL
  CLEAN: base_vertex 5 Pass (flip retained), zero FBO/attachment rows, zero
  draw-path rows, zero subroutine rows, zero texture-family rows (Stage-C
  watch), texture_barrier 8/8. Sidecar standing-debt signature
  (rc=133/1/1, hashes recorded); env proof flag-only; stderr known-bucket.
  C51 FINAL SHA = dd0361d: Gate-1 PASSED at −14%, conformance surface
  preserved. Chain per adjudication: DocWorker boundary signal
  (032dc9b..dd0361d, Clerk sends) → correctness train GO (Worker) →
  operator A/B (control 0fc817b canonical vs candidate dd0361d+memo,
  sitting AFTER the correctness train per the sequence of record).

- C51 A/B PACKAGE STAGED at dd0361d (supersedes the never-posted 99140ca
  pair — old wrappers/pin stay on disk as historical artifacts, EXCLUDED
  from any dashboard package): candidate pin
  `libAppGL-dd0361d-preview-607F6C36.dylib` cut from Scout's SWEPT final-gate
  artifact (single-source; SHA256 verified identical `e5faacbb…042a`, UUID
  re-verified `607F6C36`). Wrappers sh -n clean + executable:
  `launch-warzone-appgl-dd0361d-operator-control.sh` (canonical 0fc817b
  posture, frozen 1A68DE3F pin, no APPGL env) +
  `launch-warzone-appgl-dd0361d-operator-candidate.sh` (frozen dd0361d pin +
  `APPGL_ENABLE_DRAW_PREP_MEMO=1`); 210s each, full capture, identity
  proofs, mid-game sample Foreman-side per arm. Art roots
  `memory-runs/dd0361d-prep-memo-ab/{control,candidate}/`. SITTING TIMING:
  after the correctness train per the sequence of record — operator digest
  holds until Clerk times the sitting.

- Clerk CLOSE-OUT ADJUDICATION `6787e10b`: FOUR-STEP CLOSE COMPLETE —
  (1) dd0361d = C51 FINAL (Gate-1 −14% + zero-transition conformance);
  (2) DocWorker boundary signal 032dc9b..dd0361d SENT; (3) correctness
  train DISPATCHED to Worker; (4) A/B PACKAGE POSTS NOW. SEQUENCE-OF-RECORD
  AMENDED (rationale on record): A/B sitting runs BEFORE the correctness
  train lands — the sitting measures C51 against the exact baseline its
  floor was computed on (control = canonical 0fc817b), the operator declared
  ready-before-next-work-run, and the train implements in PARALLEL on
  frozen-pin isolation (its commits land after the sitting; its own default
  sweep gates it separately). Sitting watchpoints: FPS vs the 81-83 floor +
  prepMemo hit-rate economics in the census + visual parity + smoothness.

## CORRECTNESS TRAIN (post-C51, parallel-implemented)

- Worker FIN `4a1aec0e` — TRAIN COMPLETE, three commits (`dd0361d ->
  f15e56d -> 8fd3a39 -> cd2014c`), all default-path, full matrix green:
  (1) `f15e56d` RESIZE-GATE: FBO-bound viewports no longer size the window
  drawable — kills the ~2.0 real resizes/frame + per-frame depth-texture
  recreate + the ViewportRequestInvalidate class at source; 3-probe set
  green incl. set-while-FBO-bound-then-draw-FB0 safety case.
  (2) `8fd3a39` GLFINISH SEAM: finish() previously closed the open pass
  AFTER materializeAll/flushPendingClear (both open their own encoders →
  Metal double-encoder abort with a continued pass open, no present — the
  legacy-GL mid-frame-finish shape); pass now closes FIRST; probe replicates
  the exact diag shape.
  (3) `cd2014c` SENTINEL POSTURE: dcr3c.viewport-restore-abandonment encoded
  the PRE-resize-gate posture; updated to assert NO-invalidate on FBO-bound
  restores, RC-A02 commit-before-invalidate guarantee MOVED to an FB0-scoped
  resize leg (3rd posture-encoding sentinel this sprint). Worker PROCESS
  NOTE on record (self-reported): matrix FAIL printed before the 8fd3a39
  commit ran in the same shell pipeline — commit should have waited;
  sequencing slip noted, sweep gates everything.
- FOREMAN DIFF-SCOPE of the train: +169/−7 — GLContext.mm +10 (resize gate),
  MetalFrameGraph.mm +8 (finish ordering), GauntletRunner +158 (probes +
  sentinel) — matches the design contract, no out-of-lane code. ALL
  DEFAULT-PATH: ONE default sweep at `cd2014c` gates the train. Sweep triage
  note registered: viewport/FBO-coupled transitions read against the NEW
  posture first (dcr3c is the template). TIMING + boundary-extension
  (DocWorker 032dc9b..dd0361d vs ..cd2014c) routed to Clerk: sweep must not
  contend with the operator A/B sitting (perf arms need a quiet GPU).

- Clerk gate-sequencing ruling `82b549f0`: train sweep HELD BEHIND THE
  OPERATOR'S SITTING (C50-era rule: a running sweep contaminates perf-arm
  evidence). Scout dispatched on the HELD-LAUNCH pattern (`c936f3f2` answer):
  setup/build/publish NOW (CPU-side), GLCTS launch ONLY on Foreman's
  explicit GO at the post-sitting process-scan boundary — Foreman owns the
  boundary, no further Clerk signal. After the sweep greens: pin-rotation
  recommendation to Clerk (canonical → cd2014c = C51-default-off + both
  correctness fixes). BOUNDARY RULING: DocWorker's 032dc9b..dd0361d signal
  does NOT extend mid-flight — the train gets its OWN boundary signal
  (dd0361d..cd2014c) after ITS sweep greens (boundary = gate-train CLOSE,
  per cadence definition).
- METHODOLOGY NOTES (Clerk-directed): (1) the POSTURE-ENCODING SENTINEL
  class is now a NAMED PATTERN (third instance this sprint) — sentinels that
  assert a specific runtime posture must be re-examined whenever the posture
  legitimately changes; protective intent preserved by MOVING the guarantee,
  not deleting the sentinel. (2) Worker's self-reported sequencing slip,
  rule restated: COMMITS WAIT FOR MATRIX VERDICTS — a commit must not run in
  the same pipeline as the matrix that gates it; the sweep gates regardless,
  but the local discipline stands.

- Clerk amendment `a959b4bb` (crossed-message reconcile; supersedes the
  own-signal boundary ruling above): the correctness train's boundary signal
  does NOT fire alone — its range (dd0361d..cd2014c, 2 runtime files +
  probes) RIDES THE C52 BOUNDARY as one bundled DocWorker activation. NEW
  STANDING RULE: boundary signals fire per gate-train close, but adjacent
  SMALL trains (≲5 semantically-changed files) may bundle into the next
  boundary. Also on record: DocWorker merge #1 COMPLETE (gates
  1.00/1.00/1.00, graph 7,446 nodes with provenance tags) — the delta
  pipeline is end-to-end proven.

- Scout held-launch prep complete `5d4951ff`: `cd2014c4852400340d6b9d1a2482
  1a494f0639a0` ancestry verified (all three train commits rc=0). Artifact
  published: `cd2014c-s24-c51-correctness-train-default-gate/libAppGL.dylib`
  — SHA256 `aeda91fdafea5b87aae93acb4558a086560d96fc28d3e84d3b312f0d6e1d417a`,
  UUID `F32236C2-25A8-31F5-96EC-7BEB8EBD99D1`, release-shape PASS, standard
  config confirmed (Release + FP64-ON + VENDOR_THIRD_PARTY=ON). GLCTS NOT
  launched; no run-env artifacts beyond the dylib package; standing by for
  Foreman launch-GO at the post-sitting boundary.

- MID-SITTING INTERRUPTION (Clerk `d9de6fa7`, critical): unknown ~40%-GPU
  process between arms HELD the candidate. Foreman ID'd in two minutes:
  `bare-modifier-monitor` (PID 74686) = Codex.app's bundled native hotkey
  helper (parent = Codex desktop app) — THIRD-PARTY, not killed, operator
  decides (quit/relaunch Codex or kill the helper; anomalous GPU for a
  key-listener suggests stuck overlay/render loop). Our lane verified
  GPU-clean: Scout prep CPU-only complete, Foreman watcher sleep-poll only.
  Control arm: COMPLETE (results with Clerk); thermal note — control hit
  throttle late-run (fan, GPU mid-20s, FPS to 60s), operator re-stabilized;
  candidate mid-game sample at ~100s is comfortably pre-thermal. Control
  sample.txt captured on time at 19:35Z. Candidate fires on GPU-clean.

- OPERATOR C51 A/B RESULTS (Clerk `8095ea55`, verbatim): CONTROL pre-thermal
  75-90 / avg 80, CPU 80-85, GPU 35-45, mem ~1.35 stable, Mach 323 stable,
  correct; late-run THERMAL THROTTLE (fan, GPU mid-20s, FPS 60s),
  re-stabilized before candidate. CANDIDATE 79-94 / avg 83, CPU 91-98,
  GPU 35-45, mem/Mach same, correct.
- FLOOR RECONCILIATION (pending Worker verdict): the 81-83 floor was
  computed on the ~75 baseline; scaled expectation at the operator's
  80-baseline control ≈ 86-88; actual 83 ≈ HALF the projected reclaim. The
  census hit-rate economics (real-app prepMemo hit rate vs the 99.98%
  synthetic) are the suspected explainer — Worker analyzing.
- THERMAL-ENVELOPE DATUM: first documented sustained-load throttle on this
  chassis (control arm late-run: fan up, GPU to mid-20s%, FPS to 60s) —
  henceforth a measurement-window consideration for all live perf arms
  (pre-thermal sampling is now the standing bias; candidate sampled ~100s
  pre-thermal by design).
- COLD-LOAD HITCH — named C52-era characterization item: first
  building-menu selection with mini models drops FPS to mid-60s for a few
  seconds; suspected first-touch PSO compiles + model upload (the
  PSO-trickle + frame-time-instrumentation territory).
- Both arms' full captures + mid-game samples handed to Worker
  (`8fe23bff`); BOTH samples captured this sitting (control 19:35Z,
  candidate ~100s-in pre-thermal — the C50 gap did not repeat). cd2014c
  sweep LAUNCH-GO fired to Scout (`62bb048b`) on the confirmed post-run
  boundary (watcher: 60s+ no-Warzone). Dashboard digest HELD until Worker's
  verdict per Clerk.

- C51 LIVE VERDICT ADJUDICATED (Clerk `a6839591`; full analysis Worker
  `d8ce5f1a` + Clerk ruling): THE MEMO FLAG ENGAGED ZERO TIMES LIVE — the
  single GLOBAL stateGeneration busts on every draw (real apps touch state
  ~37 calls/draw; any one bump invalidates every cached draw's key). The
  +3.75% live win (80→83) was carried ENTIRELY by the train's UNCONDITIONAL
  layer: the six binding early-returns + the correctness fixes. CROWN = the
  unconditional layer. MEMO stays DEFAULT-OFF, documented opt-in for
  same-state-run titles. C52 MEMO GO: per-domain generations (so unrelated
  state churn doesn't bust draw-class keys) + sample-mask cache + cold-load
  characterization.
- PATTERN-BANK ENTRY — ENGAGED-NOWHERE-LIVE (zero-churn-synthetic artifact):
  a synthetic harness with no inter-draw state churn produced a 99.98% hit
  rate; the live app produced ~0%. A cache keyed on a GLOBAL generation is
  vacuous under realistic churn — key granularity must match the churn
  topology (per-domain generations, the C52 lesson). Cross-references:
  engagement≠benefit (this sprint), caching-lever non-vacuity 2-layer
  (S23 — layer-1 'mechanism engaged' must be measured ON THE REAL WORKLOAD,
  not only the probe). The two-bundle discipline (conformance+perf split
  from live evidence) prevented the memo's SECOND false crown this sprint.
- QUEUED ON cd2014c SWEEP GREEN (per adjudication): (1) rotation
  recommendation canonical → cd2014c (ships the crowned unconditional layer,
  +3.75%); (2) RELEASE the held dashboard digest, honest framing verbatim:
  "the flagged lever engaged nowhere live; its unflagged byproducts carried
  the win; flag stays opt-in; the two-bundle discipline prevented its second
  false crown this sprint."

- Scout FIN CORRECTNESS-TRAIN GATE `0d5fb993` — `cd2014c` DEFAULT/no-env:
  GREEN. 19715/19715, counts canonical (`P=19365 F=35 NS=314 IE=1`), zero
  transitions vs BOTH baselines, effective maps identical (summaries
  `480ce1ef…` / `82137bb1…`); candidate QPA `d4fd8195…2c38`. WATCH-ORDER
  VERDICT ALL CLEAN: zero viewport/FBO/attachment transitions (the NEW
  resize-gate posture holds on the full surface), zero glFinish/sync-coupled
  transitions, zero draw-path rows, basevertex 5 Pass, texture_barrier 8/8.
  No-env proof empty; sidecar standing-debt profile (rc=133/1/1, hashes
  recorded); stderr known-bucket; no stray processes. THE CORRECTNESS TRAIN
  IS CONFORMANCE-PROVEN: resize-thrash fix + glFinish seam + sentinel
  posture, zero status-map cost.

- CANONICAL ROTATION EXECUTED — C51 ARC CLOSE (Clerk confirmation
  `6ba8aff6`): pin = `cd2014c` via the EXACT swept gate artifact
  (single-source). Verification chain: source SHA256 matched Scout's
  published identity pre-copy; frozen preview pin
  `libAppGL-cd2014c-preview-F32236C2.dylib` cut + sidecar written (SHA256
  `aeda91fdafea5b87aae93acb4558a086560d96fc28d3e84d3b312f0d6e1d417a`, UUID
  `F32236C2-25A8-31F5-96EC-7BEB8EBD99D1` re-verified post-copy); prior pin
  backed up as `libAppGL-pinned-1A68DE3F-backup.dylib` (re-verified
  `e60256de…c165` = the 0fc817b identity); `libAppGL-pinned.dylib`
  repointed + sidecar updated; install-name `@rpath/libAppGL.dylib`;
  launcher UNTOUCHED.
  THE CANONICAL NO-ENV POSTURE NOW SHIPS: full S24 forward stack (async +
  fold + skip + continuation + keepalive + lazy clears) + ALL correctness
  fixes (rename-on-write, mirror-family, integer/UNORM clear, resize-thrash
  dead at source, glFinish seam closed) + the crowned C51 unconditional
  layer (binding early-returns, +3.75% live) + C51 memo present-as-opt-in
  (APPGL_ENABLE_DRAW_PREP_MEMO, default-off, documented for same-state-run
  titles). Live trajectory this sprint: 24fps (S24 start) → ~75 (C50) →
  ~80-83 (C51 layer) — best-ever correctness/perf posture.
  BOARD STATE post-close: C52 implementation next work window (per-domain
  generations + sample-mask cache + cold-load characterization); (a)
  autogame topology run schedulable on GPU idle; (c) rides the next sitting.
  Clerk's arc note on record: Gate-1 red → rotation in ONE DAY, zero wasted
  operator minutes.

- QUIET-WINDOW ACTIVATION (Clerk `a3f7cd40`): Scout's approved harness fix
  dispatched (`wrapper-shell lifecycle` — 4+ occurrences across the
  9ecf45b/99140ca/cd2014c gates; root-cause + fix + clean-exit demo on a
  short run; adjacent items foldable: line-425/TOTAL parsing, /bin/printf
  portability). Preemption rule set: gate-train dispatches preempt the fix.
  STANDING WATCHES: C52 commits (Worker window refresh) → per-SHA
  verification; (a) autogame topology run follows its counter SHA — GPU
  schedule sequenced by Foreman (harness fix CPU-mostly, topology run
  short).

- Scout QUIET-WINDOW FIN `29a469d9` — wrapper-shell lifecycle bug FIXED.
  ROOT CAUSE: watchdog subshells `( sleep $t; kill -9 $pid ) &` under a
  top-level `exec > >(tee -a launch.log) 2>&1` — killing the watchdog PID
  could orphan its child `sleep`, which INHERITED the harness stdout FD on
  the tee process-substitution pipe; the top-level bash/tee then waited for
  pipe EOF held open by the orphan. Explains both the lingering shells AND
  why process scans missed the holder (scans matched glcts/python/full_cts —
  the FD holder was a plain `sleep`). FIX: single-process perl watchdog
  (`perl -e 'sleep shift; kill 9, shift'`, no child fork, no inherited tee
  FD) for both main + sidecar watchdogs, patched across the whole
  `full_cts_s24_*.sh` family (bash -n PASS all; representative hashes
  recorded in FIN). FOLDED IN: TOTAL computation moved to `$(date +%s)-T0`
  arithmetic, removing the brittle `stat -f %B launch.log` parse (the
  3848a30 line-425/TOTAL fault class — dead at source). CLEAN-EXIT DEMO:
  `full_cts_s24_lifecycle_clean_exit_demo.sh` — full launch→tee→glcts(6
  KHR-GL46.info.* cases on the cd2014c artifact)→analyzer→TOTAL→exit path;
  rc=0, 6/6 pass, maps identical, post-exit scan ZERO matching processes
  (proof hashes in FIN). Scope confirmed: harness tooling only, zero runtime
  changes. The manual-kill + manual-summary era of sweep closeouts ends
  here.

## C52 ARC — MEMO ECONOMICS + ENCODE RESIDUALS (s24-c51-prep-memo cont.)

- C52 STAGES 1+2 LANDED (Worker FIN `dac35b61`, conditional window
  activation): `cd2014c -> 07070b4 -> c1bffac`, local gates green (12-phase
  matrix both postures, BAR-B identical at 13.9-14.0µs/draw).
  07070b4 — ITEM (b): sample-mask buffer slot rides TranslatedDrawMSLSlots +
  the plan round-trip (compare-flip/clip-control sibling pattern); the
  per-draw whole-MSL scan is eliminated on plan-path draws; floor banked
  ~0.3ms/frame. DEFAULT-PATH ENCODE change → default sweep is its gate.
  NEEDLE-SCAN AUDIT CLOSURE: that scan was the LAST raw per-draw find() in
  the encode region — all sibling slot lookups already plan-cached; the cold
  GS-emulator site is outside the per-draw path. The family the Gate-1 saga
  exposed is EXTINCT in the encode region.
  c1bffac — ITEM (a) INSTRUMENT (observation-only): six domain generations
  (texture/buffer/vertex-input/fixed-function/program/framebuffer) advance
  at mutator + markDirty sites; memo snapshots them and attributes every
  advanced domain per bust → `prepMemoBustsByDomain[6]` in diagnostics JSON.
  Caveat documented: one mutator can advance two domains (bindTexture also
  marks Program) — analysis reads the advanced-SET per bust. No behavior
  change; memo still keys globally. Foreman diff-scope: both commits match
  contract (07070b4 MetalFrameGraph-only +12/−4; c1bffac instrument
  plumbing +64/−19).
- ORDER-OF-OPERATIONS (Clerk `b742a66e`, rationale on record): (1) TOPOLOGY
  RUN FIRST at c1bffac (flag-ON autogame, diag JSONL; deltas to Worker) —
  the per-domain go/no-go decides whether more commits follow; a sweep at
  c1bffac would be superseded by GO. NO SWEEP until the read. (2) ONE
  default sweep at the mini-train's FINAL SHA gates it ((b) default-path;
  (a) rides). (3) On green: rotation recommendation (canonical picks up the
  slot-cache ~0.3ms + the instrument). Scout's held-launch prep amended to
  indefinite-hold-pending-read; Foreman c1bffac artifact cut in progress
  for the topology run (perf-iteration pattern).

- Scout C52 prep complete `cf9a760a` (held-launch, amendment applied —
  indefinite hold pending GO with confirmed target SHA): `c1bffac` ancestry
  verified, diff scope independently observed (matches my verification).
  Sweep-ready artifact published: `c1bffac-s24-c52-stages12-default-gate`,
  SHA256 `3e9977a6ab80062d79f7b1dc56e414245cfc59e819ffeff737b28ab41f1ddd13`,
  UUID `BAC203B5-3E6B-3A55-9406-D6216F012A5C`, release-shape PASS. Baselines
  re-confirmed. Foreman topology artifact (`7a3163e2…`/`628AC24A`) is
  separate per the two-artifact pattern (observation vs gate).

- C52(a) TOPOLOGY RUNS executed (Foreman, autogame, flag-ON, attested
  `7a3163e2…`/`628AC24A`): run 1 `20260611T204204Z` (inherited
  gametimelimit=30, ~30s, startup-window — annotated per the 4f879ec
  pre-game lesson) and run 2 `20260611T204729Z` (gametimelimit=300 but the
  autogame match self-ended ~60s; ~60% more draws). BOTH runs, stable
  identical topology: hits=0, planKeyReuses=0;
  buffer = vertex-input = framebuffer = 100% OF BUSTS (every draw-to-draw
  transition advances all three domains); texture ~34-35%, program ~20-22%,
  fixed-function ~6%. Run-2 final: busts=26959, bustsByDomain
  [9268, 26959, 26959, 1549, 6048, 26959].
  HYPOTHESIS FLAGGED to Worker (theirs to rule): the 99140ca FBO-mutator
  bumps are NOT value-gated (the binding early-returns are) — a
  value-identical per-draw glDrawBuffers would advance fbo with zero
  semantic change (eliminable); buffer/vertex-input 100% may be real
  per-draw streaming churn (inherent). The per-domain go/no-go hinges on the
  value-gateable-vs-inherent split of the three 100% columns. Delivery
  `(msg to Worker)`; Scout's gate artifact parked pending the verdict.

- C52(a) VERDICT BOOKKEEPING (Clerk `b342de0d`): Worker SOURCE-VERIFIED the
  Foreman three-column hypothesis as CORRECT — all three 100% domains carry
  UNCONDITIONAL bumps: value-identical FBO re-attachments, ungated indexed
  buffer binds, uncompared attrib re-specifications (the same
  redundant-mutation family as the crowned early-returns). PLAN OF RECORD:
  VALUE-GATING MINI-TRAIN at Worker's next window (three gate sites; the
  gates carry standalone dispatch-savings worth, same as the early-returns
  did) → ONE autogame topology re-run with the bump noise removed →
  per-domain go/no-go from THAT read (the current topology cannot rule;
  the noise dominates). Scout's parked c1bffac artifact:
  SUPERSEDED-PENDING — the value-gating mini-train's SHA becomes the sweep
  target; ONE default sweep then gates slot-cache + instrument + value-gates
  together as the mini-train's single gate. BOARD STATE: idle to watches
  (Worker's window for the value-gating train; standing watches otherwise;
  nothing else pending).

- C52 VALUE-GATING MINI-TRAIN LANDED (Worker `f3350950`): `c1bffac ->
  5cff969 (fbo-mutator gates) -> 3d283d9 (indexed-buffer tuple gates) ->
  8094dc8 (attrib-setter record-compare gates)`. Foreman diff-scope: +483/−74
  contract-matching (Framebuffer +96, VertexArray +135, StateTracker +30,
  probes +287). Highlights: detach bumps only on real erase; error paths no
  longer bump; value-identical attrib re-specs skip BOTH the domain bump AND
  markVertexDescriptorDirty (descriptor-cache invalidation was paid per
  redundant call — likely live-perf component); new
  inventory.stateDomainGenerations obs channel; 4/4 must-miss/must-hit probe
  pairs green; full local matrix green. IN-FAMILY RIDERS flagged for Clerk
  adjudication: tracker-level FB setters gated (bindDraw/ReadFramebuffer —
  same-FBO rebinds previously DOUBLE-busted the fbo domain — +
  setDrawBuffers/setReadBuffer). ATTRIBUTION CAVEATS left untouched for the
  read (on record): generic bindBuffer→fbo-domain routing; unconditional
  encode-boundary flush on value-identical re-attach (possible future
  encode lever); setCurrentProgramPipeline ungated. 8094dc8 = topology
  re-run SHA; Scout's c1bffac artifact superseded.

- Clerk trigger `8dcaedfd` (crossed with my execution, sequence identical):
  RIDERS ADJUDICATED-APPROVED (tracker-level FB setters incl. the
  glBindFramebuffer double-bust fix stay in). Topology re-run spec confirmed:
  gameplay-grade window per the run-2 lesson (gametimelimit=300, 270s
  observation), deltas to Worker WITH the three interpretation caveats
  attached (bindBuffer→Framebuffer cross-route = EXPECTED signal in the
  read; encode-flush untouched; pipeline ungated). Then: go/no-go → ONE
  default sweep at the mini-train's final SHA gates everything since
  cd2014c → rotation recommendation.

- C52(a) DEGATED TOPOLOGY RUN (8094dc8, Foreman-attested `c5ae29c0…642e`/
  `187A4426`, run `20260611T214120Z`): RATIO-IDENTICAL to the pre-gate
  topology — final [tex 9063, buf 25431, vtx 25431, ff 1586, prog 5690,
  fbo 25431] vs c1bffac run-2 [9268, 26959, 26959, 1549, 6048, 26959];
  hits=0, planKeyReuses=0. THE VALUE-GATES DID NOT COLLAPSE THE 100%
  COLUMNS: with redundant-mutation noise gone by construction (must-miss
  probes prove the gates fire), the remaining churn is REAL — every
  draw-to-draw transition genuinely changes buffer + vertex-input state
  (per-mesh VBO/attrib rebinds, what a real renderer does); the fbo column
  is plausibly the bindBuffer→Framebuffer cross-route mirroring buffer
  (caveat (a), expected signal). Delivered to Worker (`msg 850d… family`)
  with all three caveats; Foreman implication flagged: per-domain keys
  cannot rescue a SINGLE-SLOT memo when relevant domains change every draw
  — consecutive-draw state identity doesn't exist in this workload; a
  frame-over-frame keyed-map shape would be C53-class architecture, not a
  granularity fix. Value-gates stand on their own dispatch-savings merit.
  Worker's go/no-go names the final SHA; sweep fires on it.

- C52(a) PER-DOMAIN GO/NO-GO (Worker ruling `a0c7479e`): **NO-GO** for
  per-domain key granularity on WZ-class workloads; FINAL MINI-TRAIN SHA =
  8094dc8 AS-IS. Reasoning of record: (1) degated data DISPOSITIVE —
  buf=vtx=100% is real inter-draw churn (per-mesh streaming); every draw
  depends on those domains, so no dependency-set key excludes them;
  consecutive-draw state identity does not exist in this workload
  (ratio-identical to pre-gate: tex 34.4→35.6%, prog 22.4→22.4%, ff
  5.7→6.2%, scale −5.7%). (2) fbo=100% unresolved (plausibly the
  bindBuffer cross-route) and MOOT — buf/vtx alone kill the memo; NOT worth
  an instrument-purity commit unless C53 scoping needs true fbo churn.
  (3) Memo: permanently default-OFF, documented opt-in, no further key
  work. (4) FRAME-OVER-FRAME correspondence (draw N of F+1 vs F) = the only
  shape the data leaves open — keyed-map ARCHITECTURE (multi-entry storage +
  frame-position index + per-lookup validation), BANKED as C53-class
  candidate for Clerk/operator scoping against S25 thesis economics,
  explicitly not a commitment. (5) Value-gates stand on standalone
  dispatch-savings merit (attrib descriptor-invalidation skip likely
  largest, 5.0 attrib calls/draw); conformance gate = the default sweep;
  perf attribution rides the next operator A/B (dispatch-side,
  codegen-neutral → S24 perf-skip policy, no GLTest arm).
- SWEEP GO FIRED at 8094dc8 (`4bb8bb29`): Scout re-preps from the
  superseded c1bffac checkout pattern and launches when ready — no holds
  (operator away, GPU verified idle). One sweep gates everything since
  cd2014c; watch order sample-mask → FBO/drawbuffer (missed-bump =
  stale-resolve class) → vertex-attrib/VAO → re-confirms.

- Clerk ruling `70e3e469` (crossed with execution, identical conclusions):
  NO-GO ratified; final SHA 8094dc8; sweep already dispatched per my GO.
  BOUNDARY UPDATE: the bundled DocWorker signal becomes dd0361d..8094dc8
  (correctness train + full C52 mini-train, ONE activation per the
  small-train bundling rule) — Clerk sends it on my green report.
  CLOSED-INQUIRY NOTE (on the record for future sessions): THE MEMO
  QUESTION IS SETTLED — single-slot draw-prep memoization is permanently
  default-OFF on WZ-class workloads because consecutive-draw state identity
  does not exist there (instrument-proven, two-topology-run evidence chain,
  value-gates eliminated the alternative explanation). Do NOT reopen
  without NEW WORKLOAD EVIDENCE (a genuine same-state-run title or
  CTS-shaped consumer); the C53 frame-over-frame keyed-map candidate is the
  only sanctioned successor shape and it is banked-not-committed. Perf
  attribution of the value-gates + the cold-load capture ride the next
  operator sitting together.

- Scout C52 final-gate launch `2287e573`: `8094dc8` ancestry verified
  (cd2014c..8094dc8 = 13 files +554/−92, consistent with my per-train
  verifications summed). Gate artifact
  `8094dc8-s24-c52-final-default-gate/libAppGL.dylib`, SHA256
  `d7d20b2169b8075ad70dcfbe59712190a3a0bc819c13fd0242c6c4c4b8ae5770`, UUID
  `DDF7C237-DF9F-31FB-BC0F-0224E2F985EF`, release-shape PASS. Baselines
  verified; preflight clean; runner = PATCHED LIFECYCLE VERSION (perl
  watchdog + T0 total — second full-length validation). Launching.

- Scout FIN C52 FINAL GATE `c13b441a` — `8094dc8` DEFAULT/no-env: GREEN.
  19715/19715, counts canonical (`P=19365 F=35 NS=314 IE=1`), zero
  transitions vs BOTH baselines, effective maps identical (summaries
  `480ce1ef…`/`82137bb1…`); candidate QPA `d0255eae…0dd2`. WATCH-ORDER
  VERDICT ALL CLEAN: zero sample-mask/multisample rows (the slot-cache
  encode change), zero FBO/attachment/drawbuffer rows (the moved
  framebufferGen bumps — no missed-bump/stale-resolve fallout), zero
  vertex-attrib/VAO rows (record-compare gates + descriptor-dirty skip),
  zero draw-path rows, basevertex 5 Pass, texture_barrier 8/8. Sidecar 3×
  clean-Fail (benign face of the standing distribution; hashes recorded).
  LIFECYCLE FIX FULL-LENGTH VALIDATED: patched harness completed + exited
  rc=0 ON ITS OWN — no manual kill, no manual analyzer; complete marker
  printed (TOTAL ≈16m); transient post-batch wrapper window resolved
  naturally; final scan zero processes incl. watchdogs. The manual-closeout
  caveat era is formally over. ONE SWEEP GATED EVERYTHING SINCE cd2014c:
  slot-cache + domain instrument + value-gate train incl. riders —
  conformance-proven at zero status-map cost.

- CANONICAL ROTATION EXECUTED — C52 MINI-ARC CLOSE (Clerk confirmation
  `f93333dd`): pin = `8094dc8` via the EXACT swept gate artifact. Chain:
  source SHA256 matched pre-copy; frozen preview pin
  `libAppGL-8094dc8-preview-DDF7C237.dylib` cut + sidecar (SHA256
  `d7d20b2169b8075ad70dcfbe59712190a3a0bc819c13fd0242c6c4c4b8ae5770`, UUID
  `DDF7C237-DF9F-31FB-BC0F-0224E2F985EF` re-verified post-copy); prior pin
  backed up `libAppGL-pinned-F32236C2-backup.dylib` (re-verified
  `aeda91fd…417a` = cd2014c identity); pinned + sidecar repointed;
  install-name correct; launcher UNTOUCHED. (Note: the earlier
  Foreman-built 187A4426 pin remains on disk as the topology-observation
  artifact — distinct name, never canonical.)
  CANONICAL NOW SHIPS additionally: sample-mask slot-cache (~0.3ms floor,
  last per-draw MSL scan dead), value-gate dispatch savings (FBO-mutator +
  indexed-buffer + attrib-record gates incl. the descriptor-invalidation
  skip), domain-generation instrument (obs-only), memo settled-closed as
  documented opt-in.
  C52 MINI-ARC CLOSED: two days, zero false crowns — the per-domain no-go
  was the INSTRUMENT WORKING (Clerk framing, on record). BOARD: next
  sitting = value-gate attribution + cold-load capture; next major scoping
  = S25 threading (operator's call); C53 frame-over-frame banked;
  DocWorker bundled boundary dd0361d..8094dc8 sent by Clerk.

## S24 FINAL OPT-PASS (s24-final-opt-pass; memo
## specs-worker-docs/S24-GRAPH-OPT-PASS-2026-06-11.md)

- OPT-PASS MEMO entry (Worker, graph-instrument first research workout: 56
  draw roots → 830 reachable functions, pattern-scanned, hand-confirmed;
  house discipline: NO projected hit rates, floors measured/instrument-first
  /strategic only): (1) per-program sampler-resolve cache — NOW VIABLE
  because C52 made textureBindingGen/programGen honest (tex 35.6% / prog
  22.4% bust shares vs the fatal buf/vtx 100%) — narrow memo over a quiet
  domain pair; instrument-first floor via APPGL_DRAW_PROFILE; (2) parallel-
  encode boundary conservatism — 29 unconditional flushParallelEncode-
  Boundary sites; (3) unlatched per-draw getenvs (2-3/draw, 0.05-0.4ms band);
  (4) OPT-6 gap — viewport/scissor re-set per draw despite pass
  continuation; (5) occlusion-query uniform walks (parked, conditional).
- ITEM-2 ROUTING NOTE (on record): batch-flush conservatism = S25 THREADING
  PRECONDITION, routed to the threading dossier, NOT this sprint's perf
  ledger. KEY GRAPH INSIGHT: rename-on-write ALREADY provides the narrowing
  correctness mechanism — a renamed write hands batched draws the old
  allocation untouched, so the boundary is unnecessary whenever rename
  engaged (narrow condition: flush only when rename did NOT engage, strictly
  better than today).
- NEGATIVE-RESULTS AUDIT CLOSURE (equally load-bearing, on record): zero
  surviving unconditional per-draw MSL needle-scans (C52(b) conclusion
  stands); heavy-lookup functions outside the hot path are link/compile-time;
  SSO validation per-draw only for pipeline-object apps; resolveFBOColorTarget
  4/frame cold post-keepalive. The graph scan CLOSED the encode-scan family
  audit rather than just finding instances.
- ITEM-1 MEASUREMENT launched: APPGL_DRAW_PROFILE=1 autogame on the
  CANONICAL 8094dc8 swept pin (DDF7C237 — zero new code, profile buckets
  exist), gameplay-grade window; deliverable = resolveSamplerBindings share
  to Worker on s24-final-opt-pass; floor then = share × measured hit rate
  from gens. Worker rider commit (getenv latches + viewport/scissor dedup,
  items 3+4) expected — verify per pattern on landing; queues for the next
  sweep train, no dedicated sweep.

- ITEM-1 MEASUREMENT BLOCKED — INSTRUMENTATION GAP (Foreman, source-located):
  `APPGL_DRAW_PROFILE` ran on the canonical pin (2 runs:
  `8094dc8-drawprofile/20260611T230826Z` + a SIGTERM probe at `…231553Z`;
  env proof confirms both flags reached the process) but produced ZERO
  output: `DrawSubmitProfile.dump()` fires ONLY at frame-graph teardown
  (MetalFrameGraph.mm:3913) and the WZ exit path never destructs the
  context (autogame match self-ends in seconds, process exits from menu;
  natural exit skipped the dump; SIGTERM untestable — process gone before
  45s). The buckets do NOT reach the diag JSONL (stderr-only). Same gap
  class as the old FRAME_ATTRIBUTION zero-row item. FIX SHAPE (rider-class,
  for Worker's pending rider commit): emit the DrawSubmitProfile buckets
  into the diagnostics JSONL payload (alongside the existing counters) or
  add a periodic dump (every N frames); then the item-1 re-run costs
  minutes. The autogame short-match shape also noted: "Game ended
  (duration: 5)" — matches end near-instantly on this map/AI combo; fine
  for counter topology, but worth a longer-lived scenario if steady-state
  windows ever become load-bearing.

- PATTERN-BANK ENTRY (Clerk `39ed916e`, canonized): TEARDOWN-ONLY-OUTPUT
  INSTRUMENTS — a known DEFECT CLASS, not a style choice. Third instance:
  FRAME_ATTRIBUTION destructor-dump (the original zero-row item),
  DRAW_PROFILE teardown-dump (this one); same class, same fix shape.
  STANDING DESIGN RULE for ALL future instrumentation: output channels must
  be EXIT-PATH-INDEPENDENT — periodic emission into the diag JSONL stream is
  the house pattern. How the class hides, verbatim: "the profiler exists but
  assumed an app that tears down." Item-1 gap fix joins Worker's rider queue
  (second small commit on the 4a816cb line); re-run costs minutes on the
  staged wrapper.

- RIDER LINE LANDED + VERIFIED: `8094dc8 -> 4a816cb (items 3+4: per-draw
  trace-getenv latches + OPT-6 extended to viewport/scissor/stencil-ref;
  +125/−10, half probes) -> cca3730 (drawProfile JSONL emission — the
  teardown-only fix; +116 pure-additive)`. Both contract-matching; queue for
  the next sweep train, no dedicated sweep. Foreman artifact cut #4:
  `cca3730` attested (`b49d3d85…f0db`/`EA68C033`).
- ITEM-1 MEASUREMENT COMPLETE (run `cca3730-drawprofile/20260611T232809Z`):
  THE INSTRUMENT WORKS (4 per-interval drawProfile records, exit-path-
  independent — the defect-class fix proven on first use) and THE SHARE IS
  MATERIAL: sampler_bindings_total = 63.75ms / 304.67ms gl-side = 20.9%
  (steady ~21.7% across intervals after startup), + producer_drain 6.9%,
  synthesize negligible → SAMPLER CLASS ≈ 27.9% OF GL-SIDE PER-DRAW COST.
  Submit-side state_resolve 66% of submit total — consistent. Per the memo
  composition: the per-program sampler-resolve cache FLAGS as the next
  mini-train (gens in place; floor = measured share × measured gen-quiet
  rates; the producer-pending/rename invalidation hook is the one design
  item). Delivered to Worker; verdict + design route to Clerk.

- ITEM-1 VERDICT (Worker `bf4028e8`): GO — per-program sampler-resolve cache
  recommended as the next flagged mini-train (operator arc-composition
  permitting). THE 2.1× MAPPING resolved: resolveStage runs per STAGE
  (fragment+vertex) per draw → 2.80µs/gl-draw = 20.9% ✓. HONEST FLOOR
  (measured only): joint tex+prog quiet ≥ 42.0% (union bound from the
  degated topology; true per-program rate strictly better, measured by the
  cache's own counter at land time) × 2.80µs ≈ 1.18µs/draw ≈ 0.29ms/frame ≈
  +2.4% @83fps — crowned-C52-family scale with measured upside to ~2×.
  Producer_drain (6.9%) explicitly OUT of scope (correctness wait).
  DESIGN — FOUR-CONDITION INVALIDATION MATRIX (gens alone NOT sufficient):
  (1) gens key (textureBindingGen, programGen); (2) SAMPLER-UNIT REMAP trap
  — glUniform1i remapping a sampler unit bumps neither gen (C51 uniform
  carve-out) → new per-program samplerUniformValueGen joins the key
  (99140ca key-gap class, own must-miss probe); (3) STORAGE REDEFINITION —
  texImage/texStorage recreates MTLTexture without bumping bindingGen →
  per-texture storage epoch validated per entry (own must-miss probe);
  (4) PRODUCER-PENDING carve-out — per-entry bypass flag (default) or
  producerTokenEpoch in key. POSTURE: APPGL_ENABLE_SAMPLER_RESOLVE_CACHE
  default-OFF, full probe set (must-hit + 3 must-miss classes +
  delete-texture), default sweep + live A/B before promotion — full C51/C52
  discipline. Sequencing to Clerk/operator (review pair: this memo + the
  threading dossier). Routed to Clerk.

- Clerk adjudication `d398656a`/`3a4c965e` (DIR-FIN): sampler-resolve-cache
  design + GO verdict RATIFIED ready-to-implement; SLOT pending the
  operator's arc composition (review pair: opt-pass memo + threading
  dossier). SWEEP SEQUENCING ruled: the rider line (4a816cb + cca3730)
  RIDES the sampler-cache mini-train's sweep as ONE train if the cache gets
  the slot; if the operator routes the cache behind threading rungs, the
  riders get a STANDALONE sweep at that point (no indefinite unswept
  sitting); either way NO sweep fires before the composition call. BOARD
  RESTS FOR THE OPERATOR. Nothing further pends.

- ATTRIBUTION + COLD-LOAD SITTING CAPTURED (2026-06-12 ~00:17-01:25Z):
  CONTROL run 1 `attr-ab/control/20260612T001724Z` (cd2014c pre-value-gates
  pin) — full capture + mid-game sample (90s pre-thermal). CANDIDATE
  `attr-ab/candidate/20260612T011126Z` (canonical 8094dc8 + PSO trace +
  fine diag interval 10) — full capture (721MB JSONL) + mid-game sample +
  929 APPGL_PSO_BUILD stderr lines (the cold-load build-menu capture
  WORKED). BONUS: the operator ran CONTROL A SECOND TIME after the candidate
  (`control/20260612T011655Z`, 101MB diag + stderr, NO sample — watcher had
  retired) — purpose unstated; usable as a warm-baseline cross-check,
  honestly flagged sample-less. Both watcher samples landed pre-thermal at
  90s per the standing rule; sitting-clear boundary confirmed. Roots to
  Worker; operator's subjective numbers expected via Clerk.

- SITTING RESULTS (Clerk `934892c0`; verbatim numbers in Clerk's Worker
  dispatch): HEADLINE = FLICKER RETURNED on the candidate's BUILD MENU —
  triage dispatched to Worker, FBO-MUTATOR GATES (5cff969) PRIME SUSPECT (a
  missed-bump would be exactly the stale-resolve class the sweep watch
  anticipated; CTS green + live flicker = a live-only reproduction path).
  ATTRIBUTION: inconclusive-by-variance — candidate ≈ control, environmental
  swings dominate the value-gate-family's expected ~0.3ms scale. COLD-LOAD:
  REFRAMED — not a transient hitch but a standing mini-stress scenario
  (consistent 85-96fps in the build-menu posture). Second control run
  EXPLAINED: operator comparison re-run; folds into the attribution read.
- MEASUREMENT PROTOCOL CANONIZED (operator-derived, standing for all live
  perf work): (1) PAIRED SAME-CONDITIONS captures only; (2) ambient
  temperature recorded per sitting; (3) fans-maxed as the normalization
  option (operator-measured: native 240→215 under soak); (4) FURTHEST ZOOM
  = the standard stress posture; (5) scene/explored-state noted per run.
  ABSOLUTES ARE NOT COMPARABLE ACROSS SITTINGS — within-sitting deltas only
  (today's candidate avg 122 under today's conditions vs yesterday's 83
  under yesterday's is NOT a +47% claim). Extends the thermal-envelope
  datum into a full protocol.

## ARC COMPOSITION — THE ROAD TO THE RIBBON (operator verdict 2026-06-12)

- OPERATOR VERDICT (verbatim): "Finish the squeeze while mindful of future
  threading. Set the lay-up for the threading arc. Once that's in, we'll
  finish this arc with a ribbon and bow, ready to thread and close the gap
  with Native."
- SEQUENCE OF RECORD: (1) FLICKER FIX (triage in flight) → (2)
  SAMPLER-RESOLVE-CACHE MINI-TRAIN — its ONE sweep carries the riders
  4a816cb+cca3730 + the flicker fix as a CONSOLIDATED TRAIN → (3) THREADING
  LAY-UP: flush-narrowing (rung 1.5, the rename-predicate from the opt-pass
  item-2 insight) + Worker's dossier source-read → (4) RIBBON: final
  sweep+rotation shipping everything, S24 close-out memo, S25 starting-state
  documentation.
- NEW STANDING RULE (composition-derived): every remaining draw-path commit
  carries a ONE-LINE THREADING-IMPACT NOTE — no new deep-copy burden without
  flagging it.
- GAP MATH of record: 122 avg (today's conditions) vs native 180-215
  same-conditions ≈ 60% — squeeze-finish + lay-up is the run-up; threading
  closes from there. Foreman duties continue per pattern (verification,
  cuts/attestation, sweep dispatches on Clerk signals, tracker).

- SECOND-CONTROL-RUN ANOMALY CLOSED (Clerk `6352b481`) — explained-and-
  valuable: operator's stated purpose was confirming FPS influence factors
  (scene/zoom) and measuring EMPTY map areas. Classification:
  METHODOLOGY-VALIDATION RUN — it produced the scene-state and zoom findings
  now canonized in the measurement protocol, and its data supports the
  attribution inconclusive-by-variance read (within-run scene variance
  exceeds the C52 expected delta). KEY DATUM: dark/unexplored areas ≈180fps
  — bounds scene-complexity cost at ~60fps-worth on our stack under those
  conditions, and gives the eventual threading A/B a LOW-LOAD REFERENCE
  SCENE. Forwarded to Worker's analysis context.

- FLICKER TRIAGE FIN (Worker `01bc2c9e`) — RACE REPRODUCED HEADLESSLY,
  deterministic, first run, at HEAD c5cf05f. New probe
  `c52.triage.mid-frame-upload-order`: draw-sampling-A → texSubImage to B
  (no flush) → draw → readback; RED = the PRE-upload draw renders B (the
  write beat the already-encoded draw). MECHANISM (GLContext.mm:11271):
  `fastPathNeedsBlit` keys on STORAGE MODE ONLY, never in-flight reads —
  shared/managed takes CPU-immediate replaceRegion; private takes a blit on
  a SEPARATE upload CB that can commit before the still-open draw CB; with
  pass continuation holding the draw CB open, mid-frame uploads JUMP THE
  QUEUE. THE RESIZE-GATE UNMASKED IT: the pre-f15e56d per-frame
  invalidate/drain serialized this BY ACCIDENT (Clerk's unmasking hypothesis
  confirmed in mechanism; dd0361d cross-check build queued as
  story-clincher). C52 value-gates EXONERATED ON MECHANISM (preview-churn
  probe green, encoder structure arm-identical 4.02/4.03/3.92 opens/frame,
  dirty-audit clean) — the prime suspect was innocent; the latent-bug-
  unmasked-by-removing-an-accidental-serializer class strikes again (C49/
  3c6dbea precedent).
- FIX-SHAPE RATIFICATION REQUESTED (architectural, routed to Clerk):
  A (Worker-recommended): HAZARD-KEYED UPLOAD ROUTING — if dest texture may
  be referenced by the open CB, close the pass and encode staging+blit INTO
  THE SAME CB (in-CB ordering, prior draws read old bytes, zero stall);
  replaceRegion stays for no-hazard. Build item: per-CB texture-reference
  tracking (keepalive-adjacent) + routing switch. Threading note: per-CB
  state owned by the frame graph, replay-split safe. B: drain-on-hazard —
  re-masking + stalls, rejected by keepalive precedent. C: texture
  rename-on-write — correct but heavy.
- TRIAGE BYPRODUCTS: (1) ATTRIBUTION inconclusive-by-variance RATIFIED in
  data (per-frame counters arm-identical); CONFOUND recorded: candidate ran
  PSO-trace + 6× diag rate; PROCESS NOTE: drawProfile key absent BOTH arms —
  the candidate dylib was TRUE 8094dc8 (pre-cca3730); the live sampler-share
  cross-check needs the next capture on cca3730+ with both profile envs.
  (2) COLD-LOAD: PSO compile EXONERATED — 929 builds, 118.9ms total session,
  median 0.07ms, p99 1.2ms, max 2.05ms, ZERO ≥5ms (the 36ms class absent);
  sustained-load reframe ratified. (3) NEW MEASURED FINDING: getenv ≈4% OF
  MAIN THREAD both arms — the 4a816cb rider's two sites measured-validated
  (≈1.2-1.3%pt), plus THREE unlatched sites (samplerReadSetCanUseGpuOrderSkip
  ~0.7, encodeTranslatedDrawAndMarkFbo ~0.6-0.9, fboPassContinuationEnabled
  ~0.5 ≈ 2%pt) = RIDER-2 CANDIDATE for the consolidated train.

- Clerk ratifications `3d6f4f6a`/`c4c990d8` (DIR-FIN, crossed —
  concurrence-aligned): OPTION A RATIFIED (intervention-at-the-hazard-site;
  C held as cost-surprise fallback); RIDER-2 GO. CONSOLIDATED TRAIN MANIFEST
  of record: flicker-fix-A + sampler-resolve-cache + rider-1 (4a816cb) +
  cca3730 + rider-2 (three getenv latches) → ONE sweep → rotation →
  threading lay-up → RIBBON. Worker builds with the race fix leading.
  Byproduct reads all accepted (attribution-inconclusive w/ cca3730+
  cross-check rider; cold-load exonerated; CTS-blind/headless-probe-covers
  note adopted). Foreman watches per pattern.

- FLICKER FIX LANDED `af26b86` (Worker `e4ba0714`; + triage probe commit
  `c5cf05f`). FOREMAN VERIFICATION: +466/−8 — GLContext.mm +64 (upload
  routing, all six fast-path variants), MetalFrameGraph +154 (CB read-set
  tracking — keyed to CB identity, self-heals across rotation sites, zero
  commit-path changes), probes +252. Contract-matching Option A. RED PROBE
  NOW GREEN with engagement asserted (new `inventory.orderedTextureUploads`
  counter) + must-miss companion green (no-hazard uploads keep the fast
  path untaxed); 18-phase matrix green incl. full texture family. Threading
  note carried per standing rule: read-set is frame-graph-owned GL-thread
  state, no per-draw record payload growth.
- STORY REVISIONS (on record): (1) dd0361d ALSO RED headlessly — THE BUG
  PREDATES THE CORRECTNESS TRAIN; the masking mechanism (viewport-leak
  invalidate/drain) never engages headlessly (no live drawable resizes), so
  the live unmasking story STANDS — the resize-gate (correct, staying)
  merely stopped hiding an OLD defect in live runs; also explains dd0361d's
  operator-clean A/B (that sitting's drains still masking). Suspect-window
  logic right about mechanism, wrong about defect age. (2) DEEPER than
  hypothesized: the private-storage path was ALSO hazard-broken (separate
  blit CB commits-and-waits BEFORE the draw CB commits — a stall AND no
  ordering).
- KNOWN RESIDUAL (commit-documented, explicit): a CPU upload can still race
  a PRIOR committed-but-incomplete CB's reads (cross-CB; much narrower
  frame-paced window). Follow-up leg = per-texture last-read fence tracking,
  same class, IF the operator still sees flicker on the fixed build.
  Pattern-bank amendment: the mask-audit obligation extends to uploads
  against COMMITTED in-flight work, not just the open CB.
- TRAIN STATE: af26b86 joins the consolidated manifest (flicker fix +
  resolve-cache + rider-1 + cca3730 + rider-2). LIVE CONFIRMATION
  REQUIREMENT stands: operator-eyes on the build menu with a fixed build —
  rides the consolidated train's operator A/B (or earlier if Clerk wants a
  dedicated peek). Worker proceeds to the sampler-resolve-cache mini-train
  per sequence.

- Clerk acceptance `9fcf3006` (crossed; tracker items 1-3 already recorded
  above verbatim): ITEM 4 added — the private-storage upload path was
  stall-AND-no-order (separate CB commit-and-WAIT), so the Option-A fix is
  a MINOR PERF WIN besides the correctness fix (the wait is gone). Also on
  record: every historical clean eyeball of the upload race is explained by
  the then-active drains. Verification already done (+466/−8
  contract-matching, reported f398c675). Train assembles: 5 items;
  Foreman cut/attest + consolidated sweep at train-complete.

- SAMPLER-RESOLVE CACHE LANDED `b261f7d` (Worker `caf35877`):
  `APPGL_ENABLE_SAMPLER_RESOLVE_CACHE` + DISABLE hatch, default-OFF. FOREMAN
  VERIFICATION: +425 PURE-ADDITIVE — GLContext.mm +151 (cache + four-
  condition matrix), GLContextShader +59 (the samplerUniformValueGen at the
  uniform setter), GLObjectStore +7, runtime +7 (counters), probes +196;
  flag-gating confirmed (9 gate references). TWO IMPLEMENTATION-TIME DESIGN
  REALIZATIONS (both strictly tighter than ratified): (1) POINTER-IDENTITY
  REPLACES THE STORAGE EPOCH — hit-time compare of live metalTexture pointer
  vs cached IS the per-texture epoch; zero global-epoch false busts;
  subsumes delete-texture; proven by pixels. (2) samplerUniformValueGen is
  ITSELF VALUE-GATED (the C52 family rule applied recursively, type-precise
  at the setter) — WZ per-draw identical glUniform1i re-issues cannot bust.
  As ratified: producer-pending per-entry bypass (magenta-not-stale-blue
  probe leg), reflection-pointer key pair, deleteProgram evicts, suffix-only
  store/replay. PROBES: must-hit + three pixel-proven must-miss legs
  (remap→green, redefinition→blue, producer→magenta) + default-off
  zero-engagement pin; 16-phase default + 13-phase flag-ON matrices green.
  Threading note: program-keyed GL-thread cache, hits COPY into draw info,
  record payload unchanged.
- TRAIN STATUS: 4 of 5 landed (af26b86 + b261f7d + 4a816cb + cca3730);
  RIDER-2 (3 getenv latches) pending — caboose question + sweep-shape
  question routed to Clerk (Foreman recommendation: WAIT for the caboose —
  small, completes the manifest, avoids unswept-or-resweep; sweep shape =
  TWIN default+flag-ON per the 8b786f4 precedent since the train carries
  both default-path deltas AND a new flagged lever needing its flag-ON
  conformance before the live A/B).

- Clerk ruling `892860c3` (crossed; conclusions aligned): CONSOLIDATED TRAIN
  CLOSED at `b261f7d` — FOUR members (af26b86 + b261f7d + 4a816cb +
  cca3730); RIDER-2 REASSIGNED to the lay-up train (flush-narrowing needs
  its own gate anyway; no third sweep). TWIN SWEEPS ruled per the C51
  pattern: (a) DEFAULT gates the unflagged members (the flicker fix's upload
  routing IS default-path) + cache-default-off equivalence, texture-upload/
  sampling families first watch; (b) cache FLAG-ON conformance before the
  operator's flag-ON A/B, sampler/texture-completeness first watch. ON BOTH
  GREEN: rotation recommendation (canonical → b261f7d ships flicker fix +
  riders; cache stays default-off pending A/B) + operator A/B package
  (control = new canonical, candidate = +SAMPLER_RESOLVE_CACHE=1, BOTH arms
  with BOTH profile envs — the deferred live sampler-share cross-check rides
  this capture; watchpoints = BUILD-MENU FLICKER CHECK headline + cache
  hit-rate + FPS per the canonized protocol).

- Scout twin-gate launch `d5cf9ab7`: `b261f7d3b1b30a9faee0f6e67d9709c3069f
  4759` full-ancestry verified (8094dc8 -> 4a816cb -> cca3730 -> c5cf05f ->
  af26b86 -> b261f7d; 8 files +1132/−18 — consistent with my per-commit
  verifications summed). Shared gate artifact
  `b261f7d-s24-final-opt-pass-twin-gate`, SHA256
  `4f2faf29373825b802890a13f3804083e40693e683610bbcc584d14cc020ce12`, UUID
  `80B04CE0-DBCB-3DA7-B781-0FAF594318D1`, release-shape PASS. Env discipline
  confirmed both arms; sweep (a) DEFAULT launched, watch order as
  dispatched. This artifact cuts BOTH the rotation pin and the A/B candidate
  pin on green (single-source).

- Twin sweep arm (a) DEFAULT GREEN (`b9d22cef`): 19715/19715, counts
  canonical, zero transitions vs both baselines, maps identical. THE
  FLICKER FIX'S DEFAULT-PATH ROUTING IS CONFORMANCE-PROVEN (texture/copy/
  sampling watch families zero rows — the missed-hazard/stale-read class
  absent), riders + instrument + cache-default-off equivalence proven with
  it. Env proof empty; sidecar standing profile; residuals known-bucket.
  Arm (b) flag-ON launched immediately, same artifact.

- Scout FIN TWIN GATE `f4e79865` — b261f7d BOTH ARMS GREEN: (a) DEFAULT
  19715/19715 zero transitions (candidate QPA `4001116f…5cae`); (b) FLAG-ON
  (SAMPLER_RESOLVE_CACHE=1) 19715/19715 zero transitions (candidate QPA
  `228464be…7ea0`); both vs both baselines, maps identical, watch scans
  EMPTY in every dispatched family, env proofs exact, sidecars standing
  profile (a: 133/1/133, b: 1/1/1 — both within distribution), lifecycle
  runners exited cleanly BOTH arms (no manual closeout — the fix's third
  and fourth full-length validations). All hashes in FIN. THE CONSOLIDATED
  TRAIN IS CONFORMANCE-PROVEN: flicker fix (default-path), riders,
  instrument, cache (both postures).

- A/B PACKAGE STAGED at b261f7d (per registered spec, digest holds for
  rotation confirmation): candidate pin
  `libAppGL-b261f7d-preview-80B04CE0.dylib` cut from the swept twin-gate
  artifact (SHA256 verified identical `4f2faf29…ce12`, UUID re-verified).
  Wrappers sh -n clean: CONTROL `launch-warzone-appgl-b261f7d-ab-control.sh`
  = b261f7d default posture + BOTH profile envs (DRAW_PROFILE +
  GL_DRAW_PROFILE — the deferred live sampler-share cross-check rides);
  CANDIDATE `launch-warzone-appgl-b261f7d-ab-candidate.sh` = same +
  `APPGL_ENABLE_SAMPLER_RESOLVE_CACHE=1` (control verified clean of the
  cache flag). 210s, full capture, identity proofs, samples Foreman-side.
  Art roots `memory-runs/b261f7d-cache-ab/{control,candidate}/`.
  Watchpoints registered: BUILD-MENU FLICKER CHECK headline (clean closes
  the residual question; survivor activates the fence leg) + cache hit-rate
  counters + FPS per canonized protocol.

- CANONICAL ROTATION EXECUTED — CONSOLIDATED TRAIN CLOSE (Clerk
  `198a4993`): pin = `b261f7d` via the exact swept twin-gate artifact.
  Chain: preview pin `libAppGL-b261f7d-preview-80B04CE0.dylib` (SHA256
  `4f2faf29373825b802890a13f3804083e40693e683610bbcc584d14cc020ce12`
  verified pre/post-copy, UUID `80B04CE0-DBCB-3DA7-B781-0FAF594318D1`);
  prior pin backed up `libAppGL-pinned-DDF7C237-backup.dylib` (re-verified
  `d7d20b21…5770` = 8094dc8); pinned + sidecar repointed; install-name
  correct; launcher UNTOUCHED. CANONICAL NOW ADDITIONALLY SHIPS: the
  upload-ordering flicker fix (hazard-keyed in-CB blits — live confirmation
  = operator build-menu eyes, the residual-question gate), rider-1 getenv
  latches + OPT-6 viewport/scissor/stencil-ref dedup, the drawProfile
  instrument, and the sampler-resolve cache present-but-default-OFF pending
  its A/B. BOARD: operator sitting next (flicker headline + cache A/B +
  sampler cross-check); Worker's next window = LAY-UP TRAIN (flush-narrowing
  + rider-2 + stale-comment cleanup + dossier source-read) — the last train
  before the RIBBON.

- CACHE A/B SITTING RESULTS (Clerk `1c423e82` + Foreman extractions):
  CANDIDATE +8.7% (operator), cache verdict PENDING-CROWN on the engagement
  read. FLICKER PERSISTS BOTH ARMS — residual question OPEN, round-2 triage
  dispatched. FOREMAN'S AIMING DIAGNOSTIC (delivered to Worker ebc02c55):
  orderedTextureUploads = 0 BOTH ARMS — the fix's ordered route never fired
  live (headless probe DID fire it at land) → live pattern ≠ probe pattern;
  splits toward fence-leg (cross-CB residual) / read-set-miss / other.
  CACHE ENGAGEMENT REAL: 35.5% live hit rate (2.78M/7.82M; busts 97% of
  misses; 136k producer bypasses; control zeros — flag separation proven
  live). RECONCILIATION PUZZLE on record: per-count sampler cost ~identical
  between arms (1.21 vs 1.17µs) and share ~14% both — engagement without
  visible bucket savings; the +8.7% needs attribution before any crown
  (engagement≠benefit applies). LIVE SAMPLER SHARE = ~14% vs autogame 21.7%
  — the cross-check's real-workload correction.
- NEW HARNESS TASK (operator request via Clerk): PER-SECOND TELEMETRY in
  the capture wrappers — CPU%, GPU%, temperature each second + FPS-per-
  second; assess JSONL-bridgeFrame-delta derivation (interval=1, no
  game-side hooks) vs screen-scrape; flag sudo needs. Spec + implement in
  the wrapper family before the next sitting. IN PROGRESS.

- DUAL VERDICT (Worker `fba3ede5` + Clerk corrections `c70294b4`):
  FLICKER ROUND-2 — CROSS-CB RESIDUAL CONFIRMED PRIME, mechanism CLOSED:
  the census shows glTexSubImage2D ran 7,488× live (the zero-stderr read was
  the APPGL_LOG category gate, census = truth); PressureFlush commits rotate
  CBs ~900+×/run, clearing the open-CB read-set at every rotation → an
  upload almost always sees an EMPTY read-set while the texture's sampling
  draws sit in the PRIOR committed-but-incomplete CB. The af26b86 open-CB
  window is structurally narrow under live CB pressure; probe-vs-live gap
  EXPLAINED (one long-lived CB headless, no pressure flush). FENCE-LEG
  SHAPE RATIFIED (trigger-widening, not new machinery): the ordered-blit
  route is ALREADY cross-CB-safe (Metal auto-hazard tracks blits vs prior
  CBs' reads; only CPU replaceRegion is untracked) → fold each CB's
  read-set into per-texture lastReadCommitSeq at commit + completedSeq in
  the completion handler; hazard = open-CB-read OR lastRead > completed.
  GPU producers Metal-tracked/safe — CPU-upload-vs-prior-CB is precisely
  the remaining unprotected class (consistent with flicker-no-break).
  CACHE — ENGAGED, NOT WON, DO NOT CROWN: 35.5% live hits (topology band ✓,
  default-off [0,0,0,0] ✓, bypasses live-exercised ✓) but service economics
  NEGATIVE — per-hit validation walk (N×textures().get) + 3-vector copies
  on hit AND store-on-every-miss (64.5% of calls, the silent tax);
  resolveSamplerBindings UP 7.9%→9.6% main-thread in the candidate sample.
  The +8.7% fps is UNATTRIBUTED — scene-confounded (116 vs 137 draws/frame,
  non-comparable content). ENGAGEMENT≠BENEFIT, THIRD APPLICATION.
  RETRACTION-WITH-CREDIT on record: Worker's pointer-identity tightening
  traded rare false busts for a per-hit walk that costs more — the
  ORIGINALLY-RATIFIED global storage-epoch shape wins on measured economics.
  OPTIMIZATION LEG (bounded retry, Clerk-slotted LAST/droppable): epoch
  compare + store-only-when-stable + cheap producer flag; same twin A/B
  gate; fails-again → park alongside the prep memo as documented opt-in.
  LIVE SAMPLER SHARE correction: ~14% (autogame 21.7%); cache ceiling
  +1.4-1.6% at 35.5% hits — the retry must be CHEAP to be worth it.
- LAY-UP MANIFEST of record (Clerk): fence leg (LEADS) → flush-narrowing →
  rider-2 + comment cleanup → cache retry (LAST, droppable) → dossier
  source-read; ONE twin-sweep gate at train end. PROTOCOL ADDITION:
  per-draw normalization via the per-second telemetry (the manual arms
  diverged 18% in content — 116 vs 137 draws/frame).

- FENCE-LEG CHECKPOINT `01179d3` (Worker `2586284d`; window break, state
  banked). Foreman verification: one commit, MetalFrameGraph +108/−11 +
  probes +144 — contract-shaped. THREE PIECES:
  (1) BONUS 4TH CORRECTNESS FIX: the glFlush/PRESENT seam — present() ran
  flushPendingClear with a continued pass open (the exact 8fd3a39
  finish-seam class on the sibling path, latent until the probe did
  mid-frame glFlush; live apps flush mid-frame). Pass closes first now.
  (2) FENCE MACHINERY landed (ratified shape + crash-forced refinement):
  per-texture lastReadCommitSeq @ commit + completedSeq from completion
  handlers; the hazard route SPLITS — open-CB hazard → close-pass + in-CB
  blit; prior-CB-only hazard → separate immediately-committed CB (Metal
  hazard tracking orders it; the single-route design aborted at mid-encode
  sync sites; split safe at any call depth).
  (3) THE HEADLINE — STALE-REBIND-AFTER-REALLOC (documented-red probe,
  POINTER-LEVEL evidence): heavy in-flight draw → glFlush → upload → draw2;
  draws bind MTLTexture 0x..7ac0 while the upload path's object.metalTexture
  is 0x..6480 — THE BOUND SAMPLING POINTER SURVIVES A BASE REALLOCATION;
  uploads write a texture the draws never sample; draw2 encoded AFTER the
  upload still shows old content. The fence correctly never fires (hazard
  identity itself diverges). STRONGEST LIVE-FLICKER CANDIDATE YET — survives
  af26b86 AND the fence, matching the operator's persistence exactly.
  Next-window suspect surfaces: the resolve path returning pointer ≠
  object.metalTexture post-realloc (R5 primary-restore / sampling proxy /
  held binding) + WHY a 4x4 RGBA8 texSubImage reallocs at all
  (creation-vs-refresh shape-recompute mismatch — itself suspicious).
  Probe lives in triage-cross-cb-only (NOT sweep-gating, documented-red
  convention); 16-phase matrix green. NEXT WINDOW: (a) stale-rebind
  root-cause, (b) fence green-proof rides the same fix (one probe proves
  both on flip), (c) remaining lay-up items per manifest.

- URGENT: CATASTROPHIC CANDIDATE RUN (Clerk `1dadfd44`, operator re-ran the
  b261f7d A/B; cache-ON arm ~20fps + MEMORY LEAK + GPU starvation —
  start-of-sprint signature; sitting-2's candidate was CLEAN at 125fps —
  same wrapper/flag, variable = run conditions). FOREMAN EXTRACTIONS
  (packet af230638): candidate 23.6µs/draw GL-side vs control 15.6 (+51%);
  CACHE HIT RATE COLLAPSED to 16.4% (sitting-2: 35.5%) — ~589k misses ×
  store-on-every-miss; IMPORTANT NEGATIVE: GL-object inventory shows NO
  monotonic growth → leak is HEAP-side (cache entries/copies), consistent
  with the unbounded-entry hypothesis IF entries mint per gen-state; no
  entry-count counter exists (triage build should add one). OPERATOR
  EXPOSURE: NONE (default-OFF; canonical unaffected — stated in digest).
  DO-NOT-CROWN RETROACTIVELY RE-VALIDATED HARD; cache retry-or-park now
  starts from "has a catastrophic failure mode under churn" — PARK IS THE
  STRONG DEFAULT unless the redesign provably bounds it. Worker triages
  by its own severity-vs-budget call vs the stale-rebind lead.
- TELEMETRY MAIDEN-USE LESSON + FIX: the re-run's wrappers ran under SUDO
  (root-owned run dirs — likely for the temperature column) and pgrep -f
  CANNOT MATCH under sudo → no CSVs on the runs that mattered most. FIXED:
  wrappers now pass their $$ to the sampler (exec preserves PID —
  deterministic, sudo-proof, user-proof; pgrep stays as fallback); PID-arg
  path tested live. Also explains the earlier smoke-test miss class. Next
  sitting gets full curves regardless of sudo.

- TRIAGE CONTEXT UPDATE (Clerk `7c757fc1`, operator clarifiers — forwarded
  to Worker): (1) the catastrophic candidate was TERMINATED EARLY by the
  operator on seeing the leak in Activity Monitor (truncated tail expected;
  the growth curve up to termination IS the evidence); control normal;
  flicker still present in control (expected — stale-rebind fix not yet
  landed). (2) THE CONDITION DELTA: sudo'd wrappers → Warzone under the
  ROOT PROFILE → GAME SETTINGS RESET → sitting-3 ran at unknown-delta
  graphics settings vs sitting-2's clean candidate — texture-quality/scene
  -detail changes are exactly the churn-profile shift that pushes
  store-on-every-miss across the growth threshold. Hypothesis chain:
  settings delta → distinct-texture/gen churn up → miss/entry-mint rate up
  → unbounded growth in minutes. Worker reads sitting-3-vs-2 texture/census
  counters to confirm directly. (3) PROTOCOL NOTE (standing, BANNED):
  sudo'd wrappers = settings-profile confound. The sudo-scoped shape is now
  IN THE SAMPLER: `sudo -n /usr/bin/powermetrics` alone (one sudoers line:
  `<your-account> ALL=(root) NOPASSWD: /usr/bin/powermetrics`), temp_c column
  added, wrapper itself NEVER under sudo. (4) HYGIENE: root-owned files in
  candidate/20260612T045904Z + control/20260612T044858Z — chown needs the
  operator (no passwordless sudo on this shell); flagged in the packet.

- CACHE PARK VERDICT (Worker `fc3ab423`, `875902f` comment-only park record
  at the flag site; probes green, flag default-OFF): PARKED as documented
  opt-in for same-state-run workloads only. TRIAGE READ: (1) ENTRY MINTING
  KILLED BY CONSTRUCTION — the map is program-keyed, store REPLACES,
  deleteProgram evicts → entry count bounded by live programs (consistent
  with the no-GL-object-growth negative). (2) Partial suspect: 589k misses
  ran full-resolve+store; pointer-stale busts erase/re-insert the node;
  first-store allocates 3 vectors — but steady-state busts assign() into
  retained capacity, so allocator churn does NOT fully explain the
  heap-growth + 20fps-starvation signature. (3) AN UNIDENTIFIED COMPONENT
  REMAINS — itself the strongest park argument: a retry that can't NAME the
  failure mode can't BOUND it. RETRY HARD PRECONDITION (banked): provably
  bound the churn pathology AND explain the 20fps signature (instruments:
  entry-count counter + the telemetry RSS curve); Worker recommends nobody
  picks it up this sprint — the corrected +1.4-1.6% ceiling doesn't fund it.
- SEQUENCING (Worker's call per delegation): STALE-REBIND KEEPS THE LEAD —
  live correctness bug on the DEFAULT path with pointer evidence vs a
  parked zero-exposure lever; the realloc-trigger thread first. TELEMETRY
  ADDENDUM: rss_mb column added to the sampler (ps-based, per second) —
  the park record's named instrument now exists; temp_c column rides the
  sudo-scoped powermetrics shape.

- PROTOCOL RECORD (Clerk `dbe53df4`, operator disclaimer): hardware BACK ON
  THE 3-MONITOR SETUP as of 2026-06-12 ~08:40Z; all sittings since
  2026-06-10 were LAPTOP-ONLY. DISPLAY-CONFIGURATION joins the per-sitting
  recorded-conditions list (ambient/fans/zoom/scene/display-config). Every
  laptop-era absolute (the 115-125 band, the 122-avg, the catastrophic-run
  numbers) is NON-COMPARABLE to 3-monitor numbers; within-sitting deltas
  remain the only valid comparison; the next sitting's control arm
  RE-ANCHORS the 3-monitor baseline fresh, and a native re-reference under
  the same config is requested of the operator (the parity denominator
  moves with the setup). The telemetry shakedown proceeds under the new
  config — better: it validates under the next evidence sitting's config.

- TELEMETRY SHAKEDOWN VERDICT: PASS 7/8 columns + one bug found-and-fixed
  + one blocked-on-operator. (1) CHOWN CLOSURE verified: both sitting-3 dirs
  <your-account>:staff, zero root-owned files remain. (2) Shakedown runs (canonical
  autogame, no sudo, /tmp/telem-shakedown{,2}): PID-arg matching ✓ (rows
  from t+1, no pgrep dependence), cpu_pct ✓, gpu device/renderer ✓, rss_mb ✓
  (the 76→1118MB load curve plainly visible — the leak instrument works),
  thermal-pressure blank-when-none ✓, bridge_frame ✓ AFTER FIX, fps ✓
  (59-60 steady on the new config). (3) BUG FOUND+FIXED: diag records are
  now 204KB (drawProfile + inventory growth) — the sampler's 200KB tail
  window landed mid-record below the bridgeFrame header → blank
  bridge_frame/fps; window widened to 2MB (~10 records). (4) temp_c BLOCKED:
  the powermetrics sudoers line was NEVER INSTALLED — sudo -n -l shows only
  the pmset disablesleep entries; the sampler's probe correctly degrades to
  blank. Operator one-liner needed:
  `echo '<your-account> ALL=(root) NOPASSWD: /usr/bin/powermetrics' | sudo tee /etc/sudoers.d/powermetrics`
  then temp_c populates with zero further changes.

- TWO OPERATOR RECORDS (Clerk `1a9b8127`): (1) powermetrics sudoers line
  INSTALLED — temp_c populates from the next run; TELEMETRY CHAIN NOW 8/8.
  (2) NATIVE RE-REFERENCE under the new config (condition stamp: Studio
  display / 3-monitor setup, room temperature, fans presumed auto): ~150fps
  average. NEW PARITY DENOMINATOR ≈ 150 for this configuration (laptop-era
  was 180-215 fans-maxed — the Studio config costs native ~25-30% too,
  consistent with backing-scale/compositor load). GAP MATH FROZEN until the
  next control arm re-anchors AppGL under the same config — no cross-config
  speculation. The post-stale-rebind-fix sitting delivers BOTH the flicker
  verdict AND the new gap number in one sitting. Board watch unchanged:
  Worker's stale-rebind window.

- STALE-REBIND WITHDRAWN AS PROBE ARTIFACT (Clerk `ad489548`, Worker
  `2a9a02c` accepted): the triage probe left glActiveTexture at unit 7 after
  FBO setup → its uploads hit the FBO COLOR TARGET, not the sampled texture
  → the "pointer-level evidence" compared two DIFFERENT textures; zero
  reallocs fire under instrumentation; the mip-shape hypothesis is moot
  (the banked line ref was a garbled cross-file anchor). PROBE FIXED →
  FENCE GREEN-PROVEN 9/9 same-run (trigger fires on committed-incomplete
  CBs; must-miss holds) — PROMOTED into the gate phases. SERVE-SIDE: no
  identity hole on the default path (always-dereference resolve IS the
  correctness guarantee; pointer-caching flagged as a precondition item on
  any future cache retry). NET: af26b86 + the fence stand UNREFUTED as the
  flicker fix pair; FLICKER STATUS = FIX-LANDED-PENDING-LIVE-VALIDATION (the
  operator's post-train sitting is THE validation; no known mechanism
  remains). THREE LESSONS recorded: (1) probe-state hygiene — a probe's own
  GL state (active texture unit) can manufacture pointer-divergence
  evidence; reset state between probe phases; (2) inherited line refs are
  HINTS requiring source verification (the garbled cross-file anchor);
  (3) a red probe withdrawn under instrumentation can still pay its way —
  the SAME instrumented run green-proved the fence. Worker proceeds to
  FLUSH-NARROWING; remaining manifest is lay-up only (flush-narrowing +
  rider-2 + cleanup + source-read).

- LAY-UP TRAIN COMPLETE (Clerk trigger `97df4f71`): sweep target `7c0dd85`,
  lineage since canonical: `01179d3` fence+flush/present-seam (NEVER YET
  SWEPT — this gate is its conformance proof) → `875902f` park record
  (comment-only, +15/−1) → `2a9a02c` probe fix (tests-only, +14/−6) →
  `9a18c61` flush-narrowing (S25 Rung 1.5 — default-inert for batching
  [APPGL_PARALLEL_ENCODE opt-in] but extra-VBO liveBind marking + classify
  tree touch default code) → `7c0dd85` rider-2 latches (default-path,
  +42/−17). FOREMAN DIFF-SCOPE: five commits verified per pattern, +705/−67
  across 9 files, all contract-shaped. FLAG ARM CONFIRMED at source:
  `APPGL_PARALLEL_ENCODE=1` (the narrowing's live surface; Worker's probes
  use it). TWIN SWEEPS dispatched: (a) DEFAULT (gates fence machinery, both
  seam fixes, liveBind marking, latches; watch texture-upload/sync first
  [fence], buffer/copy second [classify tree]); (b) PARALLEL_ENCODE flag-ON
  (narrowing live behavior + batch keepalive under conformance). DOSSIER-
  HAZARD CATCH featured per Clerk: the unconditional flush was MASKING the
  dossier's §4.4 hazard — the mindful-of-threading rule paid in full. ON
  BOTH GREEN: rotation rec (canonical → 7c0dd85) → SINGLE-ARM operator
  sitting (build-menu flicker = THE question + 3-monitor re-anchor vs
  native 150 + first 8/8 telemetry). RIBBON PREP parallel: Worker drafts
  the S24 close-out memo (24fps→current ledger, lever+fix inventory,
  lessons canon, S25 starting state: ThreadedDeferred = prep-parallel
  skeleton, lean-descriptor record unit, FBO-ineligibility = Rung-2 wall).

- Scout lay-up twin-gate artifact echo `169ef6bb`: `7c0dd85` full ancestry
  + diff shape independently verified (+705/−67, 9 files — matches).
  Shared gate artifact `7c0dd85-s24-layup-final-opt-pass-twin-gate`, SHA256
  `0d7c4ba795ef59882c3158501bae293ffa4c9c202a1fe3e4aeb1b06526a6ae38`, UUID
  `04AA828D-1A50-327D-A931-C06BE48989A1`, release-shape PASS. Arm (a)
  preparing. This artifact cuts the rotation pin on green (single-source).

- Lay-up arm (a) DEFAULT GREEN (`7e25b516`): 19715/19715, counts canonical,
  zero transitions vs both baselines, maps identical. THE FENCE MACHINERY +
  BOTH SEAM FIXES + liveBind marking + latches ARE CONFORMANCE-PROVEN on the
  default surface (texture-upload/sync + buffer/copy watch scans EMPTY —
  no missed-hazard, no over-eager-fence stalls, no classify-tree
  misclassification). Sidecar standing profile; arm (b)
  APPGL_PARALLEL_ENCODE=1 launched on the same artifact.

- Scout FIN LAY-UP TWIN GATE `49bd6720` — `7c0dd85` BOTH ARMS GREEN:
  (a) DEFAULT 19715/19715 zero transitions (candidate QPA `27339971…f8b5`);
  (b) APPGL_PARALLEL_ENCODE=1 19715/19715 zero transitions (candidate QPA
  `1831bbf1…1407`) — THE PARALLEL-ENCODE PATH'S FIRST CONFORMANCE PROOF,
  with the narrowed boundary live. Both vs both baselines, maps identical;
  watch scans empty in every dispatched family both arms; env proofs exact;
  sidecars standing profile; lifecycle runners clean both arms (5th/6th
  full-length validations); artifact cmp build-vs-published = 0. All hashes
  in FIN. THE LAY-UP TRAIN IS CONFORMANCE-PROVEN: fence pair + seam fixes +
  flush-narrowing (both postures) + latches.

- CANONICAL ROTATION EXECUTED — THE LAST ROTATION OF THE SQUEEZE (Clerk
  `a70da27a`): pin = `7c0dd85` via the exact swept twin-gate artifact.
  Chain: preview pin `libAppGL-7c0dd85-preview-04AA828D.dylib` (SHA256
  `0d7c4ba795ef59882c3158501bae293ffa4c9c202a1fe3e4aeb1b06526a6ae38`
  verified pre/post-copy, UUID `04AA828D-1A50-327D-A931-C06BE48989A1`);
  prior pin backed up `libAppGL-pinned-80B04CE0-backup.dylib` (re-verified
  `4f2faf29…ce12` = b261f7d); pinned + sidecar repointed; launcher
  UNTOUCHED. CANONICAL NOW ADDITIONALLY SHIPS: the complete flicker fix
  pair (ordered uploads + cross-CB fence, conformance-proven), the
  flush/present seam fix, S25 Rung-1.5 flush-narrowing (parallel-encode
  surface swept), rider-2 latches, the park record. CLOSING SITTING
  PACKAGE staged: `launch-warzone-appgl-7c0dd85-closing.sh` (single-arm,
  new canonical + both profilers + full telemetry incl. temp_c via the
  installed sudoers line; art root `memory-runs/7c0dd85-closing-sitting/`).
  THE THREE VERDICTS it carries: build-menu flicker validation (the
  unrefuted pair, THE question), 3-monitor re-anchor (gap math unfreezes vs
  native ≈150), first 8/8 telemetry curves. Worker drafts the ribbon memo
  in parallel. S24 IS ONE SITTING FROM THE BOW.

- RIBBON MEMO DRAFTED (Worker `af72210d`):
  `specs-worker-docs/S24-CLOSEOUT-MEMO-2026-06-12.md` — four sections per
  the GO: (1) dated LEDGER 24 → ~75 (2026-06-10, 3.1×) → 80-83 (C51/C52) →
  85-96 build-menu posture, FINAL CELL OPEN for the closing sitting's three
  verdicts; map-v2 + native re-baseline as thesis seeds. (2) INVENTORY:
  C47-C52 crowns w/ mechanisms + postures; the correctness trains (rename /
  resize-gate / seam pair / flicker pair / phantom dissolution); BOTH parks
  verbatim w/ preconditions; standing debt incl. the MS-renderbuffer
  quarantine. (3) LESSONS CANON: 7 entries from the pattern-bank language
  w/ instance counts + standing rules. (4) S25 STARTING STATE: thesis,
  rung-ladder w/ Rung 1.5 DONE-AND-SWEPT (arm (b) maiden proof cited),
  Rung-2 design inputs (lean-descriptor record unit + retain arena;
  FBO-ineligibility = THE wall; texture-family encode-time-tracking
  prerequisite), frame-pacing gate methodology. One-edit final-cell slot.
  Memo ships with the bow.

- CLOSING SITTING CAPTURED (runs `7c0dd85-closing-sitting/20260612T150610Z`
  [first attempt, ended early] + `…151043Z` [the sitting: 81MB diag, 229
  telemetry rows ≈ 4min, mid-game sample at 90s pre-thermal]). FOREMAN
  EXTRACTIONS: FPS avg 98 / min 30 / max 180 over 224 in-game seconds;
  GPU avg 67.3% (the GPU is finally FED — laptop-era 35-45%, sprint-start
  ~20%); CPU ~102%; RSS stable ~1.6GB. **THE FENCE IS LIVE-ENGAGED:
  orderedTextureUploads = 2,914** — the widened cross-CB trigger ordered
  ~2.9k hazardous mid-frame uploads in real play (it was 0 under the
  open-CB-only trigger) — the flicker fix pair is demonstrably ACTIVE, not
  just conformance-proven. Cache [0,0,0,0] ✓ parked-off. TELEMETRY 7/8 in
  the capture; temp_c root-caused at last: Apple Silicon powermetrics has
  NO die-temperature sampler on this OS (smc unrecognized; gpu_power
  carries none) — the column now records the THERMAL PRESSURE LEVEL
  (Nominal/Moderate/Heavy) via the sudoers path, the honest available
  signal. Operator verdicts (flicker eyes + conditions stamp) come via
  Clerk; gap math awaits their FPS reading + protocol stamp.

- FLICKER ROUND 3 (Clerk `5b7beebf`, critical): THE PAIR IS REFUTED LIVE —
  flicker persists on 7c0dd85 in the closing run. OPERATOR ARCHAEOLOGY
  re-confirms the window WITH CERTAINTY: dd0361d wrappers (both arms) =
  last flicker-free; cd2014c = first flicker → the CORRECTNESS TRAIN
  introduced it (f15e56d resize-gate / 8fd3a39 glFinish-seam are the two
  runtime commits; cd2014c test-only). NEW LEAD (Worker dispatch): LOSS OF
  THE IMPLICIT PER-FRAME SCRUB — the resize-gate ended per-frame
  depth-texture recreation; stale persistent state where fresh-each-frame
  was accidental. FOREMAN REREAD folded into the packet: the fence engaged
  2,914× live AND flicker persisted → upload-race class DOUBLE-EXONERATED
  (engagement + archaeology); the bug is counter-silent (no leak/perf
  signature) — fits stale-content-served. Round-3 irony noted: af26b86 +
  fence fixed REAL bugs (probe-proven, live-engaged) — they were just not
  THIS bug; the af26b86-era "fix pair" framing was built when cd2014c was
  already in the lineage, so the window evidence never actually pointed at
  uploads. BISECTION ACCELERATOR: frozen pins cutting at f15e56d + 8fd3a39
  (operator hover-checks, ~6 min total, optional); Worker hunts mechanism
  in parallel. RIBBON HOLDS — correctness owns the close.
- CLOSING SITTING'S OTHER TWO VERDICTS delivered (don't wait on flicker):
  3-MONITOR RE-ANCHOR: telemetry in-game avg 98fps (min 30 loads / max 180)
  over 224s vs native ≈150 same-config → ≈65% of native (vs ~60%
  laptop-era estimate; CAVEAT: telemetry-derived avg, scene-dependent —
  the operator's protocol-stamped reading supersedes when it arrives).
  TELEMETRY: first full evidence capture delivered (7/8 + pressure-level
  column now live); GPU avg 67.3% — the feed ratio's sprint journey 20% →
  67% IS the thesis trajectory in one number.

- BISECTION PINS CUT + STAGED (Foreman builds, express-auth pattern):
  `libAppGL-f15e56d-preview-564323E1.dylib` (SHA256 `c9cdb4ce…b562`, full
  SHA `f15e56da8222…2dc3`) + `libAppGL-8fd3a39-preview-E9E94056.dylib`
  (SHA256 `f1c6cf47…55c5`, full SHA `8fd3a391fafb…68bf`); hover wrappers
  `launch-warzone-appgl-{f15e56d,8fd3a39}-bisect.sh` (sh -n clean,
  telemetry-wired, art roots `memory-runs/flicker-bisect/{f15e56d,8fd3a39}`).
  DECISION TABLE: known clean = dd0361d; known flicker = cd2014c-era.
  f15e56d-pin FLICKER → resize-gate scrub-loss confirmed (fix = explicit
  scrub replacing the accidental one); f15e56d CLEAN → 8fd3a39 pass-close
  ordering is the thread (8fd3a39-pin check confirms). Posted to dashboard
  as OPTIONAL-ACCELERATOR (~6 operator minutes); Worker hunts mechanism in
  parallel regardless.

- BISECTION RESULT (Clerk `8429f07e`, operator hover checks — conclusive in
  4 operator-minutes): BOTH pins flicker → **f15e56d (resize-gate) OWNS THE
  FLICKER**, 8fd3a39 merely inherited; SCRUB-LOSS CONFIRMED (the decision
  table's first branch fired). Worker's hunt narrowed to the two f15e56d
  behavior deltas — PRIME: the per-frame depth-texture recreation was an
  ACCIDENTAL ZERO-FILL CLEAR; persistence exposes unclear-region stale
  depth. FIX BAR on record: the resize-gate STAYS (it's correct) — the
  revealed dependency gets fixed AT ROOT (explicit scrub/clear semantics,
  not a revert). NEXT GATE TRAIN = the FLICKER FIX train: its own sweep +
  an operator hover validation — THE LAST VALIDATION OF THE SQUEEZE.
  Standing watch: Worker's mechanism + fix.

- ROOT CAUSE NAMED (Worker `01c478e1`; red→green probe in flight, packet
  within the hour): `invalidateTransientState()` ends with
  `hasPendingClear=false`, and `commitCurrentAsync` calls it AFTER EVERY
  COMMIT — including mid-frame PRESSURE FLUSHES (~900+/run, + the
  sampler-skip periodic flush every 256 decisions). A pending glClear is
  FRAME-SEMANTIC GL state; any pressure flush landing between glClear and
  the consuming FB0 pass-open silently DESTROYS the frame's clear → next
  FB0 pass opens depth loadAction=LOAD of LAST frame's depth →
  clear-dependent draws (the depth-tested preview model) intermittently
  fail depth test = flicker-without-break, counter-silent, load-dependent.
  THE f15e56d CONNECTION (bisection right, commit innocent): pre-gate, the
  two per-frame resize invalidates PINNED CB rotation to viewport switches
  (no clear pending there) and kept CBs small; the gate removed them → CBs
  accumulate → pressure commits DRIFT into the clear-pending window. Defect
  = OURS, PRE-EXISTING, unmasked. FAMILY NOTE: this is the S22
  intervention-at-hazard-site lineage — the same invalidateTransientState
  that abandoned uncommitted FBO-draw CBs in DCR3-C now shown destroying
  pending-clear state; commit-path invalidation of frame-semantic GL state
  is the recurring class. HEADLESS CADENCE CONFIRMED: preview-shaped probe
  with per-frame clears green BOTH arms of the new triage knob
  (APPGL_TRIAGE_DISABLE_RESIZE_GATE, in-tree) — only the pressure-flush
  window kills it (why it never showed headless). FIX (local):
  hasPendingClear + values (texture-independent loadAction state, valid
  across depth-texture recreation) SURVIVE invalidateTransientState.
  Deterministic red→green probe via
  APPGL_SAMPLER_GPU_ORDER_SKIP_PERIODIC_PRESSURE_FLUSH=1 forcing the flush
  into the clear→draw window. Prediction on record for the capture: closing-
  run flicker frames correlate with pressure-flush timestamps right after
  mid-frame depth clears (corroboration available, likely unnecessary given
  the deterministic probe).

- MECHANISM RATIFIED (Clerk `4222f13c`): fix shape right (loadAction state
  is FRAME-SEMANTIC, not transient), deterministic probe = correct proof
  vehicle, corroboration-decline = house standard. CLASS-CLOSING ADDITION
  ADOPTED — THE AUDIT RIDES THE FIX TRAIN: third scalp for the
  invalidateTransientState-destroys-frame-semantic-state class (S22 DCR3-C
  abandoned CBs / keepalive-era masking dynamics / the clear-kill). Worker
  ENUMERATES everything invalidateTransientState clears, classifies each
  transient-vs-frame-semantic, fixes-or-documents EACH in the same train —
  CLOSE THE CLASS, NOT THE INSTANCE. The enumeration feeds the memo's
  lessons canon. TRAIN SHAPE: fix + audit + probe → own sweep → THE LAST
  hover validation → the ribbon.

- FLICKER FIX TRAIN LANDED `a9ccea4` (Clerk trigger `394956ce`): the
  pending-clear fix + THE SECOND SCALP + the class CLOSED + both-directions
  probe; 23-phase matrix green. SECOND SCALP (likely the DOMINANT visible
  mechanism): pressure commits ran the FULL frame-boundary tail —
  presentCurrentDrawable mid-frame (showing a HALF-DRAWN frame; draws after
  the commit missed that presented frame) + invalidateTransientState
  dropping drawable + pendingPresent (splitting the frame across
  drawables). THE FIX: pressure commits are NOT frame boundaries —
  frame-semantic state (drawable, pendingPresent, pending clear + values)
  SURVIVES; only CB/encoder-coupled state resets. FOREMAN VERIFICATION
  (+315/−4): the frameBoundaryCommit branch keeps the HISTORICAL tail
  character-identical (present → commit → invalidate) — the present path
  PROVABLY untouched for frame-boundary reasons, the change reason-scoped
  to PressureFlush; invalidateTransientState's hasPendingClear reset
  removed with the full mechanism documented in-comment; +271 probe lines.
  f15e56d FULL RESOLUTION: gate stays; BOTH unmaskings fixed at root.
  ONE default sweep dispatched (changes default-path); watch order
  present/swap families FIRST (the commit-tail semantic change), clear/
  depth second, standing set third. On green: rotation rec + THE LAST HOVER
  VALIDATION (Worker's prediction on record: both mechanisms die; any
  survivor = a NEW mechanism with these two excluded by construction).

- Scout flicker-fix gate artifact echo `8c06ca2c`: `a9ccea4` ancestry + diff
  shape independently verified (+315/−4 — matches). Gate artifact
  `a9ccea4-s24-flicker-fix-final-gate`, SHA256
  `74f386050e0cf639c62063d1e49d1ff74e513f48aaba74bcb27a507b04fa8565`, UUID
  `EA66FDED-93D7-3205-A578-9E0810CDBA7A`, release-shape PASS. Single
  DEFAULT sweep preparing. This artifact cuts the rotation pin AND the final
  hover-validation pin on green.

- Scout FIN FLICKER-FIX GATE `d0190fba` — `a9ccea4` DEFAULT/no-env: GREEN.
  19715/19715, counts canonical, zero transitions vs both baselines, maps
  identical (candidate QPA `f322f6d7…32d8`). WATCH PROOF: present/swap
  change scan EMPTY (the commit-tail semantic change is conformance-clean),
  clear/depth scan EMPTY (pending-clear survival semantics clean),
  fence/upload standing clean. Sidecar 3× clean-Fail; lifecycle runner
  clean exit. THE FLICKER FIX TRAIN IS CONFORMANCE-PROVEN — both
  mechanisms' fixes + the class closure gated at zero status-map cost.

- CANONICAL ROTATION EXECUTED — THE FLICKER-FIX ROTATION (Clerk
  `dced854d`): pin = `a9ccea4` via the exact swept artifact. Chain: preview
  pin `libAppGL-a9ccea4-preview-EA66FDED.dylib` (SHA256
  `74f386050e0cf639c62063d1e49d1ff74e513f48aaba74bcb27a507b04fa8565`
  verified pre/post-copy, UUID `EA66FDED-93D7-3205-A578-9E0810CDBA7A`);
  prior pin backed up `libAppGL-pinned-04AA828D-backup.dylib` (re-verified
  `0d7c4ba7…ae38` = 7c0dd85); pinned + sidecar repointed; launcher
  UNTOUCHED. THE CANONICAL NOW CARRIES BOTH FLICKER MECHANISM FIXES AT ROOT
  + THE CLOSED invalidateTransientState CLASS. THE LAST HOVER VALIDATION
  posts to Clerk's thread for operator relay. Clean hover → THE RIBBON.

## ═══ S24 CLOSED — THE RIBBON (2026-06-12) ═══

- OPERATOR VERDICT (verbatim, of record): "FLICKER IS GONE. Proceed with
  ribbon, crown this release. We're ready for S25."
- **CROWN: a9ccea4 = THE S24 CLOSING CROWN.** Both flicker mechanisms
  confirmed DEAD LIVE on the operator's eyes — Worker's by-construction
  prediction VINDICATED; the invalidateTransientState class closed at zero
  conformance cost (hover-clean = the last validation of the squeeze).
- CLOSING LEDGER: 24fps (sprint start) → 98 avg Studio-config ≈65% of
  native-150 same-config; GPU feed 20% → 67.3%; 8.3 → 1.16 CB/frame; zero
  hard waits. FLICKER ARC RESOLUTION: f15e56d INNOCENT (gate stays); the
  two-mechanism class closed (half-drawn-present + pending-clear-kill =
  third + fourth scalps of the invalidateTransientState family); two
  earlier real fixes (af26b86 + fence) live-engaged and standing.
- RIBBON TRAIN: close-out memo = the arc's document of record AND S25's
  starting-state document (the three operator adjudications fold in as
  DECIDED: per-pass record boundary, single-worker-first, C53 banked);
  SWEEP CADENCE: S25 inherits the standing Scout discipline, the
  PARALLEL_ENCODE arm joins the twin-sweep rotation once Rung-1 work
  begins. S25 OPENS ON THE MEMO'S LANDING — no further gate between here
  and the threading arc.

- MEMO FINAL (Worker `3958778c`):
  `specs-worker-docs/S24-CLOSEOUT-MEMO-2026-06-12.md` — all five checklist
  items in: closing ledger slotted (24→98 ≈4×, ≈65% of native-150,
  GPU 20%→67.3%, 8.3→1.16 CB/frame, zero hard waits; header re-stamped
  canonical=a9ccea4 crowned); lessons-canon entry #8 = the
  invalidateTransientState class (four scalps, closed-with-enumeration,
  signature diagnostic: BISECTION NAMES THE UNMASKER, MECHANISM WORK NAMES
  THE DEFECT); §2 resolution narrative w/ the 2,914-engagement
  double-exoneration; §4 three adjudications DECIDED; S25 cadence note.
  S25 OPENING DISPATCH banked (Rung-1 prep-parallel on the ThreadedDeferred
  skeleton, INSTRUMENTS FIRST: copy-headroom before Rung-2 arithmetic +
  frame-pacing A/B harness p99/hitch/stall). Worker session-boundary note
  (the discipline applied to itself): context deep in the red post-round-3 —
  S25's first train opens in a FRESH session against seed memory + dossier
  + source-read + memo; partial trains fine, partial commits not, an
  opening train deserves a full window.
  **S24 IS COMPLETE. S25 OPENS ON THE NEXT WINDOW.**

## ═══ S25 — THE THREADING ARC (opened 2026-06-12) ═══

- S25 OPEN (Clerk `a4f7f42f`, operator GO; Worker refreshed in a fresh
  session). ARC = threading per the dossier rung ladder. **GATE CURRENCY =
  FRAME-PACING (p99 / hitch / main-thread-stall), NOT avg-FPS** — the
  per-frame time series the telemetry harness was built for.
- RUNG-1 OPENING DISPATCH (thread s25-rung1-instruments, Worker has it):
  INSTRUMENTS FIRST — (1) copy-headroom measurement (before any Rung-2
  go-arithmetic), (2) the frame-pacing A/B harness (p99/hitch/stall),
  (3) ThreadedDeferred prep-parallel LIVE behind APPGL_PARALLEL_ENCODE,
  (4) FBO-draw-share instrumentation (Rung-2 scoping input — the
  FBO-ineligibility wall's size).
- FOREMAN S25 POSTURE: standing sweep discipline unchanged; the
  PARALLEL_ENCODE arm joins the twin-sweep rotation FROM THE FIRST TRAIN
  FORWARD; attestation duties per the S24 pattern (express-auth artifact
  cuts for perf-only iterations; swept-artifact single-source for
  rotations); relay cadence sparse. Baselines of record: canonical a9ccea4
  (crown), native ≈150 same-config, AppGL 98 avg / GPU 67.3% / 1.16
  CB/frame starting state.

- S25 RUNG-1 INSTRUMENT TRAIN landed (Worker `611bce49`): `a9ccea4 ->
  8ab5cf4 (frame-pacing + stall + parallel-share counters) -> 977f6d9
  (copy-headroom shadow probe)`, both observation-only, Clerk-ratified.
  Foreman diff-scope: +1022/−13, 8 files, 431 probe lines, counter-shape
  residue only ✓. NEW INSTRUMENTS in the JSONL: framePacing (1ms-bucket
  cumulative histogram → p50/p99 via bucket deltas, hitch25/50/100,
  frameTimeUsMax), commandBuffers wait fields (inFlightToken/ringSlot/
  completionWait — unconditional), drawableWaitUs, copyHeadroom (fb0 real
  lean-fill µs/draw + retains + uniform/inlineUbo bytes; fbo CENSUS-ONLY by
  design — real fill calls ensureDrawableResources, forbidden mid-FBO-pass;
  project fbo cost from fb0 per-byte/per-handle), parallelEncode
  (boundaryReasons incl. FboDraw share, batch topology, worker wall-vs-sum).
- PROBE-ROBUSTNESS CLASS NOTE (Clerk-directed, banked): deterministic-RED
  on clean canonical ≠ runtime defect until CB COMPLETION STATUS is read —
  cb_complete now carries the NSError; status=5 innocent-victim =
  GPU-recovery discard (2a9a02c sibling). SECOND MECHANISM: a single
  multi-hundred-ms fragment dispatch is PREEMPTION-HOSTILE and trips macOS
  GPU error/recovery — heavy-GPU probes must be MANY BOUNDED DRAWS in one
  CB, never one pathological draw (cross-cb probe reshaped 1×8M → 64×50k,
  5/5 green where full-phase context previously failed).
- FIRST-READINGS PLAN (operator returns ~18:45Z; readings packet to Worker
  for analysis assembly): Scout builds NOW (held launch); three Foreman
  autogame instrument runs on the published artifact — (a) BASELINE no
  flags [pacing baseline of the arc], (b) APPGL_COPY_HEADROOM_PROBE=1
  [Rung-2 go-arithmetic inputs], (c) APPGL_PARALLEL_ENCODE=1 [FboDraw
  share + batch topology + pacing-under-arm]; then sweep GO.

- FIRST READINGS delivered (three Foreman autogame arms on the attested
  977f6d9 pin; packet to Worker `07d4f304`; sweep GO fired after):
  BASELINE PACING: 239 frames, p50 ≈18-19ms, hitch25/50/100 = 55/36/11,
  max 349ms (incl. transitions); WAITS at instrument resolution:
  completionWait 13.4ms total/6 events, ring/token µs-class — zero-hard-
  waits HOLDS; drawableWait ~5-6ms cumulative.
  COPY-HEADROOM: fb0 lean-fill = 0.085µs/draw REAL (18.2k draws), retains
  0.017µs; fbo = 62% OF ALL DRAWS (29.7k) at 7.6KB uniform/draw (~41× fb0
  density) — the Rung-2 cost question quantified.
  PARALLEL (THE HEADLINE): **ZERO BATCHES FORMED** — candidateDraws 13.4%,
  parallelBatchCount=0; boundaryReasons fbo_draw=29,583 +
  pipeline_not_prepared=11,800. THE DOSSIER'S FBO-INELIGIBILITY WALL IS NOW
  MEASURED: 62% of draws FBO-bound, every batch broken before forming.
  Descriptor-prep path engaged clean (6,408/6,408, zero fallbacks).
  Pacing-neutral under the arm (it never acts). Caveat: short-match
  autogame scene mix; the operator sitting confirms the share in long play.
  Worker assembles the analysis for the operator's ~18:45Z return.

- ═══ GRACEFUL PAUSE (operator directive, 2026-06-12 ~18:22Z; machine
  restart imminent — compositing glitches plausibly downstream of today's
  gpuEvent GPU-recovery windows) ═══
  PAUSE STATE: S25 Rung-1 instrument train VERIFIED + first readings
  DELIVERED (packet `07d4f304` to Worker; the FBO-wall measurement is the
  headline). Scout's 977f6d9 twin sweep was IN-FLIGHT → ABORT-CLEAN
  pre-authorized + relayed; it RE-FIRES post-restart from the prepared
  runners (checkout/artifact/runners persist; identity ff4b480a…/B3A50C90
  on record). RESUMES FIRST POST-RESTART: (1) Scout re-fires the twin sweep
  (one launch command), (2) Worker's analysis assembly of the readings
  packet (data all on disk at memory-runs/s25-rung1-readings/), (3) the
  operator sitting (pacing baseline + FBO-share confirmation in long play).
  EVERYTHING IN-CONTEXT IS ON DISK: this tracker is current through the
  first readings; all pins/wrappers/artifacts attested with sidecars; no
  partial commits anywhere (Worker's tree clean at 977f6d9). The S24 crown
  (a9ccea4) is the live canonical — restart-safe by construction
  (frozen-pin launcher).

- Scout pause-state confirmed (`13d51b2c`, on the ledger thread): sweep
  aborted at ns15_ah, no salvage; artifact + both runners persist; resume =
  relaunch default/no-env from scratch, then the PARALLEL_ENCODE arm after
  its green. ALL SESSIONS PAUSED CLEAN. Idle until the resume signal.

- ═══ RESUME (post-restart, 2026-06-12 ~20:53Z; Clerk resume directive
  `ba341797` on the pause thread, handoff ledger of record
  contexts/S25-PAUSE-HANDOFF-20260612T1830Z.md) ═══
  Bridge re-registered (AppGL-Foreman, tty /dev/ttys002 unshifted);
  identity check PASSED per the cross-load checklist (one restart
  artifact: a pre-resume comm-rule deny before rules were restored —
  identity-verified, no retry; rules restored with the resume signal).
  Scout RE-DISPATCHED (`81dc750e`, thread s25-rung1-twin-sweep-977f6d9):
  default/no-env arm FROM SCRATCH first, PARALLEL_ENCODE arm after its
  green; artifact identity verify (ff4b480a…/B3A50C90) before launch;
  quarantine protocol + 0fc817b/crowned-3848a30 baselines restated. The
  sweep gates the S25 instrument train — NO rotation until green.
  Parallel per Clerk: Worker resumes commit-C stash-pop (LeanFillFailSite
  site-split) → matrix → land BEFORE any stress-posture run; GLTest
  Phase 1 continues (Phase 2 HOLDS on sweep-green + operator clearance,
  still undecided); DocWorker staged AppleDocs ISOLATED, promote decision
  with the operator. Canonical pin a9ccea4 verified untouched.

- ROUTING (Clerk `52572fce`, thread s25-rung1-instruments, 2026-06-12
  ~21:07Z): commit-C LANDED — train now 8ab5cf4 → 977f6d9 → 65666b4
  ("S25 Rung-1 instruments: pipeline_not_prepared site-split"), Worker's
  full 18-phase matrix green incl. both probe families.
  SWEEP-SLOT DELTA-RATIONALE (gate-of-record): Scout's in-flight 977f6d9
  twin sweep CONTINUES AS-IS — not churned for 65666b4. Ruling basis:
  65666b4 is a strict obs-only rider (LeanFillFailSite out-param, nullptr
  = zero real-path cost; default-off latch unchanged), so it RIDES THE
  NEXT SCHEDULED SWEEP SLOT instead of its own. The 977f6d9 twin green
  still gates the train's risky surfaces; 65666b4's deferred slot is the
  delta this entry records.
  FORWARD: (1) Foreman-attested artifact at 65666b4 (sha256+UUID sidecar)
  staged NOW for the GLTest Phase-2 re-vendor — released only on twin
  green + operator clearance (cross-team routes via Clerk); (2) the
  stress-posture operator sitting runs on 65666b4 (instrument currency,
  obs-only — canonical pin a9ccea4 untouched, rotation gated on sweeps).

- 65666b4 ATTESTATION STAGED (Foreman cut, 2026-06-12 ~21:15Z): detached
  worktree appgl-65666b4-s25-rung1-commitc, era-correct vendors from the
  d3e62ea reference (SPIRV-Cross 601164c + glslang dcf1aaa, SHA-verified
  post-copy), CMakeCache-confirmed Release/FP64=ON/VENDOR_THIRD_PARTY=ON/
  target-14.0, build exit=0. Frozen pin
  live-targets/appgl-bridge/libAppGL-65666b4-preview-50D0DD58.dylib —
  SHA256 5eb13c480d680954e5bee7330ded91cb81a51f650bfe944199da9835ab6e9fed,
  UUID 50D0DD58-85CF-3C47-8E29-6C3A8E8EF47B (arm64); .sha256 + .uuid.txt
  sidecars written; pre/post-copy SHA match verified. HELD for GLTest
  Phase-2 re-vendor — release gates: 977f6d9 twin green + operator
  clearance, routed via Clerk. Canonical pin re-verified untouched
  (74f38605… = a9ccea4 crown).

- 977f6d9 TWIN SWEEP, ARM A (default/no-env) GREEN (Scout `c7115c8b`,
  2026-06-12 ~21:13Z; re-fired FROM SCRATCH post-restart): artifact
  ff4b480a…/B3A50C90 identity-confirmed. Candidate 19715/19715;
  P=19365 F=35 NS=314 IE=1 (expected-exact); incomplete_chunks=0.
  Vs 0fc817b primary AND crowned-3848a30 secondary: status_transitions=0,
  p_to_nonpass=0, p_to_fail=0, maps_identical=1. Env proof empty
  (correct for the no-env arm). QPA sha256 f044a991…e155. Quarantine
  sidecar (renderbuffers_storage_multisample 3× isolated): rc1/Fail,
  rc1/Fail, rc133/ends=0 — the case's known quarantined behavior,
  batch-excluded as standing. Watch scans clean; standing basevertex +
  texture_barrier Pass; MSL_FAILED=16 standing. ARM B
  (APPGL_PARALLEL_ENCODE=1) launched by Scout. Twin verdict to Clerk
  on both arms complete.

- ═══ 977f6d9 TWIN SWEEP GREEN — S25 RUNG-1 INSTRUMENT GATE-OF-RECORD
  (Scout FIN `b5971fe1`, 2026-06-12 ~21:32Z; re-fired from scratch
  post-restart) ═══
  One artifact both arms: ff4b480a…43a / UUID B3A50C90-A78A-3FB1-9019-
  443204D70ADF, release_shape=PASS, install_name=@rpath/libAppGL.dylib.
  ARM A (default/no-env): 19715/19715, P=19365 F=35 NS=314 IE=1,
  incomplete_chunks=0; vs 0fc817b primary + crowned-3848a30 secondary:
  transitions=0, p_to_nonpass=0, p_to_fail=0, maps_identical=1; env
  proof empty; QPA f044a991…e155.
  ARM B (APPGL_PARALLEL_ENCODE=1 only): same counts expected-exact,
  zero transitions vs both baselines, maps_identical=1; env proof
  exactly the one flag; QPA bc75d5a7…6cb. Batching/draw change scan
  EMPTY (the load-bearing arm-B check for the parallel path).
  Quarantine sidecars: armA rc1/Fail,rc1/Fail,rc133; armB rc1/Fail,
  rc133,rc133 — the case's known quarantined behavior, batch-excluded
  standing. Watch scans clean both arms; standing basevertex +
  texture_barrier Pass; MSL_FAILED=16 standing; runners exited clean,
  no residual processes. Analysis manifests + sidecar sha256s in Scout's
  FIN on the sweep thread.
  EFFECT: the S25 Rung-1 instrument train (8ab5cf4 → 977f6d9) is
  SWEPT-GREEN on both postures. 65666b4 rider sweeps next slot per
  Clerk ruling `52572fce`. Verdict relayed to Clerk; rotation +
  GLTest-Phase-2 clearance are Clerk/operator calls.

- ROTATION RULING — HOLD (Clerk `f9eca134`, 2026-06-12 ~21:51Z, on the
  twin-green verdict): canonical pin STAYS a9ccea4 until 65666b4's rider
  sweep greens, then ONE rotation to the full train. Rationale: the
  instrument train is obs-only value — nothing changes for uninstrumented
  live runs, so two rotations (977f6d9 now + 65666b4 later) is churn for
  zero live benefit; one rotation per swept value-increment. The
  stress-posture sitting runs on the staged 65666b4 preview pin
  (50D0DD58) via wrapper regardless — nothing waits on rotation.
  GLTest side: Clerk has signaled sweep-green (rider classification
  stated); operator clearance is the only remaining Phase-2 gate; the
  staged attestation continues to HOLD.

- STRESS-POSTURE SITTING CALLED (Clerk `0d92653e`, 2026-06-12 ~22:37Z) →
  wrapper STAGED (`ebce45bc` confirm):
  launch-warzone-appgl-65666b4-stress-posture.sh on the attested
  65666b4 preview pin (sidecar-verified at stage: sha256 -c OK +
  UUID 50D0DD58). Env: APPGL_COPY_HEADROOM_PROBE=1 +
  APPGL_PARALLEL_ENCODE=1 + APPGL_FRAME_ATTRIBUTION_PROFILE=1 + diag
  JSONL interval-60 (framePacing rides the build) — the Rung-1 readings
  arm exactly, plus the copy-headroom latch. Live operator shape:
  pass-through args, NO autogame, telemetry sampler armed, NO-sudo ban
  in header. Output memory-runs/s25-stress-posture/<stamp>/ with full
  proofs incl. canonical-pin cross-proof. Launch line handed to Clerk
  for the operator. Canonical launcher + pin untouched.

- READINGS PASS GO + ROUTING (Clerk `9aa56f24`, 2026-06-12 ~23:30Z):
  commit D LANDED — 4ffd297 "plan-mismatch sub-reason split", matrix
  18/18; train = 8ab5cf4 → 977f6d9 → 65666b4 → 4ffd297 (verified on
  master). Four lanes: (1) Foreman attests a 4ffd297 preview pin (same
  protocol) — worktree cut, vendors SHA-verified (601164c/dcf1aaa),
  CMakeCache Release-verified, build in flight; (2) Foreman stages+runs
  the readings pass SOLO — single-arm autogame short-match on the
  4ffd297 pin, env COPY_HEADROOM_PROBE=1 + PARALLEL_ENCODE=1 (the
  known-clean combined posture), JSONL to memory-runs/
  s25-rung1-readings/<new stamp>; Worker analyzes on landing.
  PRE-REGISTERED KEY: plan_null/plan_invalid ⇒ prepare-at-record from
  record-time snapshot; color_format/sample_count/fragment_stage ⇒
  prepare SITE wrong; mixed ⇒ both legs. (3) SWEEP-SLOT RULING UPDATED:
  rider slot moves to the train head — ONE twin at 4ffd297 covers both
  obs-only riders (65666b4 + 4ffd297); Scout dispatched (`7ef28b32`,
  queue-permitting, no preemption); rotation unchanged (one rotation to
  full train on its green). (4) GLTest Phase-2 staging UNCHANGED on the
  attested 65666b4 pin; re-stage once at swept head ONLY if clearance
  stretches past the 4ffd297 green.

- 4ffd297 ATTESTED + READINGS PASS LANDED (Foreman solo, 2026-06-12
  ~23:33Z): pin libAppGL-4ffd297-preview-BAC17C48.dylib — SHA256
  9d3f05fb83448429074a319110550f80b729f582f7efb16ea111099614e88865,
  UUID BAC17C48-EFD8-3213-A2AD-C654B0F7B98F; full attestation protocol
  (vendors 601164c/dcf1aaa verified, CMakeCache Release-confirmed,
  build exit=0, sidecars, pre/post-copy match). Readings run exit=0:
  wrapper launch-warzone-appgl-4ffd297-readings.sh, combined
  COPY_HEADROOM_PROBE+PARALLEL_ENCODE posture, run dir memory-runs/
  s25-rung1-readings/plan-mismatch-split/20260612T233245Z/ (full
  proofs). Shape VERIFIED protocol-normal vs the morning's accepted
  readings runs (same 5-record/bridgeFrame-240 profile — initial
  short-run suspicion resolved by direct comparison). Worker handed
  the run dir + the pre-registered key verbatim (`a712e641`); Clerk
  UPD'd all four lanes (`e37b5385`). Canonical pin untouched in every
  proof set.

- 4ffd297 twin sweep LAUNCH-PREP (Scout `116e6d75`, ~23:34Z): ancestry
  verified 8ab5cf4→977f6d9→65666b4→4ffd297; rider delta 977f6d9..4ffd297
  = 2 files, +207/−14; isolated checkout built Release fp64-on/vendored.
  Sweep artifact: 0e5afbd894c8634cca6f977fa1cf73ac40be4a32bab3693e2819
  49533fe5f489 / UUID 655B78F9-91BD-308D-A937-B0A27B9F3284,
  release_shape=PASS, cmp_vs_build=0. Default arm first.

- 4ffd297 twin, ARM A (default/no-env) GREEN (Scout `a7300585`,
  ~23:53Z): 19715/19715, P=19365 F=35 NS=314 IE=1 expected-exact,
  incomplete_chunks=0; vs 0fc817b + crowned-3848a30: transitions=0,
  p_to_fail=0, maps_identical=1; env proof empty; QPA 0842b2dc…7e06.
  Quarantine sidecar VARIATION noted: rc134/rc133/rc134 all ends=0
  (all-no-result this round vs Fail/Fail/crash on the 977f6d9 twin) —
  within the case's known instability class, the reason it is
  batch-excluded; no gate impact. Watch scans clean; standing
  basevertex + texture_barrier Pass; MSL_FAILED=16 standing. ARM B
  (APPGL_PARALLEL_ENCODE=1) launching.

- ═══ 4ffd297 TWIN SWEEP GREEN — S25 TRAIN GATE-OF-RECORD (Scout FIN
  `42733edb`, 2026-06-13 ~00:12Z; ONE twin covers BOTH obs-only riders
  65666b4 + 4ffd297 per Clerk ruling `9aa56f24`) ═══
  Ancestry verified 8ab5cf4→977f6d9→65666b4→4ffd297; rider delta 2
  files +207/−14. One artifact both arms: 0e5afbd8…f489 /
  UUID 655B78F9-91BD-308D-A937-B0A27B9F3284, release_shape=PASS,
  cmp_vs_build=0. ARM A (default): expected-exact counts, zero
  transitions vs both baselines, maps_identical=1, env proof empty,
  QPA 0842b2dc…7e06. ARM B (APPGL_PARALLEL_ENCODE=1 only): same
  expected-exact, zero transitions, env proof exactly the flag, QPA
  7db3b94b…4fb2; batching/draw change scan EMPTY. Quarantine sidecars
  within known instability class (armA all-no-result, armB
  Fail/crash/Fail). Watch scans clean both arms; runners exited clean.
  EFFECT: full S25 Rung-1 instrument train SWEPT-GREEN on both
  postures. ROTATION GO issued by Clerk (`99d2adc0`): rotate canonical
  ONCE to 4ffd297, source = FOREMAN-ATTESTED pin BAC17C48 (NOT the
  Scout sweep artifact, per standing artifact-provenance rule); backup
  the a9ccea4 crown pin first (remains S24 crown of record).
  EXECUTION GATE: the classifier soft-block on live-canonical
  overwrite requires the operator's direct in-session permission
  (bridge-relayed clearance ≠ user intent for shared-resource mods —
  the standing [[classifier-softblock-peer-relay]] pattern); rotation
  surfaced to the operator at the Foreman console, awaiting express GO.

- ═══ CANONICAL ROTATION EXECUTED — 4ffd297 IS THE LIVE CANONICAL
  (2026-06-13 ~00:45Z; operator EXPRESS GO at the Foreman console —
  explicit in-session authorization after the soft-block, per pattern;
  Clerk ROTATION GO `99d2adc0` as the gate basis) ═══
  Backup: a9ccea4 crown pin → libAppGL-pinned-EA66FDED-backup.dylib,
  SHA256 74f386050e0cf639c62063d1e49d1ff74e513f48aaba74bcb27a507b04fa
  8565 (sidecar written) — the S24 crown of record, recoverable in one
  copy. Canonical libAppGL-pinned.dylib NOW: SHA256 9d3f05fb83448429
  074a319110550f80b729f582f7efb16ea111099614e88865, UUID BAC17C48-EFD8-
  3213-A2AD-C654B0F7B98F = the Foreman-attested 4ffd297 pin (provenance
  per Clerk's ruling — attested lineage, not the sweep artifact).
  Launcher untouched (frozen-pin discipline). Canonical lineage
  advances: …7c0dd85 → a9ccea4 (S24 crown) → 4ffd297 (S25 Rung-1
  instrument train, swept-green both postures).

- GLTEST PHASE-2 VENDOR RETARGET (Clerk ruling `fcddd183`, 2026-06-13
  ~00:54Z): vendor target moves to the SWEPT TRAIN HEAD 4ffd297 —
  attested pin BAC17C48 (SHA256 9d3f05fb…) — SUPERSEDING the 65666b4
  staging. Basis: canonical just rotated to 4ffd297 + the
  committed-vendor freshness rule (vendor tracks canonical-HEAD;
  staging 65666b4 would mint a one-commit-stale vendor on day one);
  4ffd297 is a strict superset of 65666b4 for Phase-2. Coverage: the
  operator's durable clearance included a one-time re-stage at the
  swept head — NO new operator prompt for the retarget itself
  (GLTest-Worker's in-session soft-block remains its own gate).
  SOURCE OF RECORD for the re-vendor: live-targets/appgl-bridge/
  libAppGL-4ffd297-preview-BAC17C48.dylib + .sha256/.uuid.txt sidecars
  (re-verified intact, sha -c OK). 65666b4 staging RETIRED from the
  Phase-2 lane — pin + sidecars stay on disk as attested history (it
  remains the swept stress-sitting pin), no deletion. GLTest-Foreman
  updates Worker's checklist to the BAC17C48 identity before the swap.
  AMENDMENT (Clerk `48c5fba9`, ~00:56Z) — RACE: GLTest's 65666b4 swap
  had ALREADY FIRED (operator express at their Worker's seat, all
  gates green) 2 seconds BEFORE the retarget ruling landed.
  Adjudicated OPTION A on GLTest-Foreman's escalation: the pacing
  ladder runs NOW on the swapped 65666b4 vendor (instrument-level
  validation, identical framePacing instrumentation, verdict transfers
  — basis to be stated in their FIN); the 4ffd297 re-stage from the
  served source of record becomes a STANDING PRECONDITION before any
  Rung-2 A/B MEASUREMENT (was: before the ladder). Source-of-record
  serving + 65666b4-as-attested-history unchanged.

- ═══ W2 LANDED — 4a7a1b3 "S25 W2: plan-prepare-at-record (commit E)"
  (Clerk gate dispatch `c0a69de9`, 2026-06-13 ~00:58Z; matrix 19/19 =
  18 standing + 4 new W2 probes; FIN adjudicated ACCEPTED) ═══
  FIRST ACTIVE-PATH change of S25 — reserved OWN-SLOT sweep, not a
  rider. W2 root-cause item → LANDED-PENDING-GATES;
  cap-with-eviction stays open-separate. GATE LANES: (1) Foreman
  attestation at 4a7a1b3 in flight (worktree cut, vendors
  601164c/dcf1aaa verified, CMakeCache Release-confirmed, build
  running); (2) Scout dispatched (`64058ef7`, thread
  s25-w2-twin-sweep-4a7a1b3) — twin, pipeline/PSO watch families LEAD
  (plan-built-at-record ⇒ wrong-plan surfaces as pipeline-state P→F),
  P→F=0 bar; (3) exit-criteria = OPERATOR stress sitting on the
  4a7a1b3 pin post-green (fill-success off 0%, pipeline_not_prepared
  collapse, plan_null measured-confirm, pacing vs MacBook baseline) —
  wrapper staged in advance; (4) ROTATION HOLD at 4ffd297 until the
  sitting reads clean — active-path rotates on EVIDENCE, not
  sweep-green alone (S24 lesson: conformance-green ≠ live-correct).

- 4a7a1b3 ATTESTED + W2 SITTING WRAPPER PRE-STAGED (~01:05Z): pin
  libAppGL-4a7a1b3-preview-2AD513EF.dylib — SHA256 f221005178601d356c
  1ddb2ccc72c2dc5b90869c762fd29e99cb5092b3fa8b2c, UUID 2AD513EF-BA8B-
  348A-8D93-DE86EB1E8E0B; full protocol, build exit=0, sidecars,
  pre/post-copy match; canonical verified still 4ffd297 post-cut
  (hold respected). Wrapper launch-warzone-appgl-4a7a1b3-w2-sitting.sh
  staged (syntax-checked, pin sidecar-verified): combined instrument
  posture (COPY_HEADROOM_PROBE+PARALLEL_ENCODE+FRAME_ATTRIBUTION,
  diag-60), telemetry armed, live shape no-autogame/no-sudo, output
  memory-runs/s25-w2-sitting/<stamp>/, exit-criteria in header. One
  launch line when Clerk calls the sitting. Clerk UPD `9d1ebf8d`.

- 4a7a1b3 twin LAUNCH-PREP (Scout `d8d9446d`, ~01:03Z): ancestry
  verified 4ffd297→4a7a1b3; ACTIVE-PATH delta 7 files +656/−36 (vs the
  riders' 2/+207 — size consistent with commit E's scope). Sweep
  artifact 182db0f18021b26133205b61b2529a47ae359b8d4c56279ee961e3a187
  000d90 / UUID F7A4981E-E6B8-35F2-AD51-CE5306136585,
  release_shape=PASS, cmp_vs_build=0, size 11519152 (+18720 vs
  4ffd297's artifact, nm +21 lines — new code present as expected).
  Default arm first.

- 4a7a1b3 twin, ARM A (default/no-env) GREEN (Scout `8ea25628`,
  ~01:23Z): 19715/19715, P=19365 F=35 NS=314 IE=1 expected-exact,
  incomplete_chunks=0, wall ~17m; vs 0fc817b + crowned-3848a30:
  transitions=0, P→fail=0, maps identical; env proof 0 bytes; QPA
  696bda12…370a. LEAD WATCH FAMILY CLEAN: pipeline/PSO changes=0 (the
  active-path signal for plan-prepare-at-record), sync/fence/flush=0,
  standing basevertex/texture_barrier all Pass. Quarantine sidecar
  rc133/rc133/rc1-Fail — within known instability class. Residuals
  standing (MSL_FAILED=16 raw-log, no status-map deltas). ARM B
  (APPGL_PARALLEL_ENCODE=1) proceeding.

- ═══ 4a7a1b3 TWIN SWEEP GREEN — W2 ACTIVE-PATH GATE-OF-RECORD
  (Scout FIN `5254d39a`, 2026-06-13 ~01:42Z) ═══
  One artifact both arms: 182db0f1…0d90 / UUID F7A4981E-E6B8-35F2-
  AD51-CE5306136585, release_shape=PASS, cmp_vs_build=0; ancestry
  4ffd297→4a7a1b3 verified, source pin 4a7a1b339a….
  ARM A (default): expected-exact counts, transitions=0 / P→F=0 vs
  BOTH baselines, maps identical, env proof 0 bytes, QPA 696bda12…,
  wall ~17m. ARM B (APPGL_PARALLEL_ENCODE=1 only): expected-exact,
  transitions=0 / P→F=0 both baselines, env proof exactly the flag,
  QPA 2d659f1d…, wall ~16m. LEAD WATCH FAMILIES CLEAN BOTH ARMS:
  pipeline/PSO changes=0 (the wrong-plan signal for
  plan-prepare-at-record), sync/fence/flush=0, batching/draw=0 (arm
  B). Standing basevertex + texture_barrier Pass; residuals standing
  only (MSL_FAILED=16 raw-log, no status deltas); quarantine sidecars
  within known instability class; runners exited clean.
  EFFECT: W2's conformance gate is CLEAR. REMAINING W2 GATES:
  operator sitting on the 4a7a1b3 pin (exit criteria: fill-success
  off 0%, pipeline_not_prepared collapse, plan_null measured-confirm,
  pacing vs MacBook baseline) — wrapper pre-staged, one launch line.
  ROTATION HOLD at 4ffd297 STANDS until the sitting reads clean
  (active-path rotates on evidence).

- ═══ W2 SITTING = FALSE-GREEN — ROTATION STAYS HELD (Clerk
  `48795065`, 2026-06-13 ~02:31Z; run 4a7a1b3/20260613T014836Z) ═══
  The live sitting caught what the conformance sweep structurally
  COULD NOT. W2's record-prepare is PROVEN CORRECT (memo 100% hit /
  verifyMismatches=0 / pacing no-regress at 106fps) — BUT it lives
  inside prepareLean, DOWNSTREAM of the candidate gate
  translatedDrawParallelCaptureEligible (MetalFrameGraph.mm:2152),
  which hard-rejects plan-null draws BEFORE they reach the fix.
  Real-arm candidate share = 0.00% from decile 2 (pre-W2 freeze
  dynamic intact); EXIT CRITERION (2) pipeline_not_prepared collapse
  FAILED (40.5%, unchanged). The sweep couldn't see it — the gate
  rejection is spec-correct behavior; only the live sitting + the
  cross-instrument cross-check exposed the false-green. (Validates the
  active-path "rotate on evidence, not sweep-green" rule — S24 lesson
  in action: conformance-green ≠ live-correct.) TRACKER MOVES: W2 →
  LANDED-CORRECT-BUT-INCOMPLETE (does NOT meet its own exit criteria;
  commit stays as a valid prerequisite). NEW W2.1 = gate
  eligibility-authority leg. W1 dispatch HELD behind W2.1.
  cap-with-eviction unchanged. No artifact rotates; no GLTest re-stage
  move (their precondition target becomes the eventual swept head —
  likely the W2.1 pin, not 4a7a1b3).

- W2.1 DESIGN APPROVED — Worker implementing (Clerk `01ce416e`,
  ~02:39Z; specs/S25-W2_1-GATE-WIRE-DESIGN-2026-06-13.md). Reader
  audit found a THIRD plan-null hard-reject authority (threaded-
  deferred capture, MetalFrameGraph.mm:8944) BEYOND the gate (:2152)
  — both covered by a single resolve-at-gate (the gate is the first
  plan reader in every arm dispatch). Lifetime risk closed by the
  pre-existing deep-copy invariant (9027/9028/9399, in-code
  assertion). Clerk added one structural condition (shared
  target-state derivation helper so gate + prepareLean cannot drift)
  + 3 implementation watch-items. W2.1 lands as its OWN commit →
  needs own attestation + twin sweep + RE-FIRE of the W2 sitting.
  Rotation still HELD at 4ffd297; W1 still HELD behind W2.1; GLTest
  precondition unchanged (eventual swept head, now likely W2.1).

- W2.1 LANDED — ATTESTATION HELD ONE BEAT (Clerk `7cf18ff2`,
  2026-06-13 ~02:52Z): commit 732c763, 20-phase matrix green. Foreman
  does NOT attest yet — Clerk has ONE structural confirm out to Worker
  (is the factored structural-reject predicate single-source vs a
  duplicate that could drift from the gate). If the confirm needs a
  small unify-refactor the SHA changes; holding avoids re-cutting a
  sweep on a stale SHA. Clerk signals GO with the FINAL SHA (likely
  732c763 itself) the moment Worker answers. Rotation HELD at 4ffd297,
  W1 HELD behind the W2.1 sitting — unchanged. ON GO: attest final SHA
  → twin sweep → re-fire W2 sitting (the full W2.1 gate chain).

- ═══ W2.1 SWEEP GO — final SHA 732c763 (Clerk `c752a909`, 2026-06-13
  ~02:54Z; predicate source-verified single-source: gate delegates
  :2160-2163, resolve calls the same fn → drift impossible) ═══
  Two parallel lanes fired. (1) SWEEP: Scout dispatched (`efa6a245`,
  thread s25-w2_1-twin-sweep-732c763) — own-slot twin, pipeline/PSO
  LEAD. (2) ATTEST: worktree cut (732c7637dd…), vendors 601164c/dcf1aaa
  verified, CMakeCache Release-confirmed, build running.
  GATE-OF-RECORD FRAMING (load-bearing): W2.1 is correctness-PRESERVING
  but behavior-CHANGING — it resolves plans AT THE GATE so MORE draws
  take the parallel-candidate path; it changes WHICH path encodes a
  draw, NOT the pixels. THE BAR = result-map IDENTITY (P→F=0 + maps
  identical) between arms + vs both baselines; a wrong gate-resolved
  plan → wrong pipeline → pipeline-state P→F = the conformance risk.
  The batching/draw + candidate-share COUNTER SHIFT IS EXPECTED (the
  point of the commit; candidate-formation RED→GREEN already
  probe-verified in-gauntlet) — NOT a regression, NOT an empty-delta
  bar (unlike the obs-only riders). EXIT CRITERIA for the re-fire
  sitting: pipeline_not_prepared COLLAPSE + candidate-share OFF 0%
  steady-state + pacing no-regress vs p99=16/p99.9=23. Attested 732c763
  pin is ALSO the GLTest re-stage target once the sweep certifies it.
  Rotation HELD at 4ffd297 until the sitting reads clean; W1 HELD.

- 732c763 ATTESTED + W2.1 RE-FIRE SITTING WRAPPER PRE-STAGED (~03:00Z):
  pin libAppGL-732c763-preview-4BB4EA9D.dylib — SHA256 07627872d9c9e39e
  089194cf96443f11b9efeda88a7fab5643ffc6881882b6fa, UUID 4BB4EA9D-BE60-
  3FB3-9BE0-4E546D1B83FE; full protocol, build exit=0, sidecars,
  pre/post-copy match; canonical verified still 4ffd297 post-cut (hold
  respected). Wrapper launch-warzone-appgl-732c763-w2_1-sitting.sh
  staged (syntax-checked, pin sidecar-verified): same combined posture
  as the W2 sitting (COPY_HEADROOM_PROBE+PARALLEL_ENCODE+
  FRAME_ATTRIBUTION, diag-60, telemetry, MacBook, live no-autogame/
  no-sudo); exit criteria in header = pipeline_not_prepared COLLAPSE +
  candidate-share OFF 0% steady-state + pacing no-regress vs
  p99=16/p99.9=23; output memory-runs/s25-w2_1-sitting/<stamp>/. One
  launch line when Clerk calls the re-fire after the sweep greens.

- 732c763 twin LAUNCH-PREP (Scout `cf45faf9`, ~02:59Z): ancestry
  verified parent 4a7a1b3 → 732c763. Sweep artifact e31a6b11309b02862e
  70d1896f3e29ad6f17bfb288b01cbf03af9d99c185c4a0 / UUID 0A5E37F2-3F5F-
  3766-BF0D-BC776C72FC83, release_shape=PASS, cmp_vs_build=0, size
  11536016 (+16864 vs 4a7a1b3 artifact, nm +5 lines — gate-wire code
  present). Build warnings only known MTLResourceUsageSample
  deprecation. Retargeted twin runners preparing; default arm first.
  (NOTE: Scout sweep artifact 0A5E37F2 is distinct from the Foreman
  attested pin 4BB4EA9D — both 732c763, each in its proper role per
  standing provenance rule.)

- 732c763 twin, ARM A (default/no-env) GREEN (Scout `e059e7c0`,
  ~03:19Z): 19715/19715, P=19365 F=35 NS=314 IE=1 expected-exact,
  incomplete_chunks=0, wall ~16m; vs 0fc817b + crowned-3848a30:
  transitions=0, P→fail=0, MAPS IDENTICAL effective=1 — the
  result-map-identity bar is MET (the conformance bar for this
  behavior-changing commit). pipeline/PSO status changes=0 (lead
  family — no wrong gate-resolved plan); sync/fence/flush=0;
  batching/draw status changes=0 AND Scout correctly noted "counters
  not used as bar per dispatch" (the framing landed — the candidate
  counter shift lives in the live sitting, not the CTS status maps).
  Quarantine sidecar rc133/rc1-F/rc1-F known class; residuals standing
  (MSL_FAILED=16, no status deltas). ARM B (APPGL_PARALLEL_ENCODE=1)
  proceeding.

- ═══ 732c763 W2.1 TWIN SWEEP = RED — ARM-B CONFORMANCE REGRESSION
  (Scout FIN `916ca2a8`, severity HIGH, 2026-06-13 ~03:39Z) ═══
  ARM A (default/no-env) GREEN — maps identical vs both baselines.
  ARM B (APPGL_PARALLEL_ENCODE=1) RED: ONE case flips
  KHR-GL46.shader_image_load_store.advanced-sso-simple Pass→Fail vs
  BOTH baselines (status_transitions=1, P→fail=1, maps identical
  effective=0). Counts P=19364 F=36 (one more F than the 35 standing).
  Location: filtered-split/nonshaders.txt:9555, chunk ns15_ag line 555;
  candidate QPA line 188810. QPA contrast: default case Pass, parallel
  case Fail. Scout ATTRIBUTION (load-bearing): RED is a REQUIRED
  result-map-identity failure, NOT a batching/draw counter
  misinterpretation (batching/draw status changes=0; the framing held).
  READ: the failure is on the LEAD pipeline/PSO family — exactly the
  predicted risk ("wrong gate-resolved plan → wrong pipeline → P→F").
  Arm-asymmetry is diagnostic: W2.1 makes MORE draws eligible for the
  parallel-candidate path; this SSO/image_load_store case is presumably
  newly-eligible and renders WRONG under parallel encode → either the
  gate-resolved plan is wrong for the SSO case, or W2.1 newly EXPOSES a
  latent parallel-encode defect for image_load_store/SSO draws. VINDICATES
  the parallel-arm-in-twin discipline: a default-only sweep would have
  shipped this (arm A is green). CONSEQUENCES: 732c763 pin 4BB4EA9D
  HELD — NOT certified, re-fire sitting NOT fired, GLTest re-stage does
  NOT move to it. Rotation stays HELD at 4ffd297; W1 stays HELD. Scout
  dispatched to isolate-probe the single case (confirm deterministic +
  parallel-specific, not a GPU-recovery/sweep-condition artifact) per
  the standing isolated-probe-before-repair discipline. RED verdict +
  read routed to Clerk (RQ-DIR) for repair routing.

- W2.1 RED — CLERK RULING (`96d9fc6a`, ~03:41Z; crossed/answered my
  RQ-DIR 4cbb3e16): W2.1 (732c763) → SWEPT-RED, regression-iterate.
  Clerk confirms it a REAL correctness regression — W2.1 broadened
  parallel eligibility to an image-load-store/SSO draw class that
  doesn't render bit-identical under parallel encode (matches my read).
  "The sweep caught what the sitting could not — gate-of-record working
  as designed." MOVES: 4BB4EA9D attested pin + sitting wrapper PARKED
  (not retired — likely reused if the fix is small, BUT a fix = new SHA
  = new attestation, so treat 4BB4EA9D as PROVISIONAL). Worker
  root-causing now (two hypotheses, as flagged: wrong gate-resolved
  plan vs exposed parallel-hazard from broadened eligibility). Rotation
  HELD 4ffd297; W1 HELD; GLTest re-stage target REVERTS to "pending the
  GREEN W2.1 SHA" (NOT 4BB4EA9D until it sweeps clean). No new sweep
  until Worker's fix lands + Clerk dispatches. (Foreman note: the
  single-case isolate-probe I dispatched [`b86daf90`] is a 6-run
  determinism diagnostic, NOT a sweep — left running to feed Worker's
  hypothesis split; offered Clerk the abort override.)

- W2.1 REPAIR ROUTING — CLERK RATIFIES (`ec7202af`, ~03:43Z, reply to
  my RQ-DIR 4cbb3e16): Worker ALREADY root-cause-dispatched (Clerk
  e782694d) with the two hypotheses PLUS a PRIME H2 CANDIDATE: does
  translatedDrawParallelStructuralReject (the GATE) carry the
  gpuAuthored/SSBO-image guards that prepareLean's lean path has? If
  the GATE lacks a guard prepareLean has → W2.1 lets an image/SSO draw
  past into captured-parallel encode WITHOUT it = single-source guard
  miss = the clean H2 mechanism. No separate Worker-diagnosis dispatch
  needed.
  SEQUENCING (nothing wasted): Worker does STATIC source analysis NOW
  (guard-asymmetry check = pure source read, can't be wasted by probe
  outcome). The DYNAMIC deep-isolation + the actual W2.2 REPAIR COMMIT
  GATE ON my isolate-probe (b86daf90) — RATIFIED as the is-it-real
  gate (isolated-probe-cross-check discipline). Probe says NOT
  reproducible / not parallel-specific → STOP, do NOT repair a phantom,
  route result to Clerk. Confirmed deterministic+parallel-specific →
  W2.2 repair leg proceeds (provisional name). All my enforced
  consequences ratified (4BB4EA9D held/uncertified, sitting not fired,
  rotation+W1 held, GLTest re-stage doesn't move). Clerk relaying the
  QPA location to Worker. Parallel-arm-in-twin credited — default-only
  sweep ships this regression.

- PROBE-RESULT INTERPRETATION KEY (Clerk `f6d2f089`, ~03:44Z; LET IT
  FINISH ratified + asymmetry refinement — corrects my earlier
  deterministic→H1 over-simplification): the determinism mapping is
  NOT symmetric. INTERMITTENT → strongly H2, a clean verdict (a true
  race/coherence hazard; a wrong-but-STABLE plan wouldn't flicker).
  DETERMINISTIC → does NOT cleanly pick H1 — it is consistent with
  H1 (wrong gate-resolved plan) AND with the deterministic H2 variant
  (gate missing prepareLean's gpuAuthored/SSBO-image guard → draw
  consistently let through + consistently encoded wrong). So
  deterministic MUST be crossed with Worker's STATIC guard-asymmetry
  read to disambiguate wrong-plan vs missing-guard. WHEN I HAND THE
  PROBE RESULT to Worker + Clerk: tag intermittent = clean-H2;
  tag deterministic = H1-OR-deterministic-H2, needs Worker's static
  read to split (do NOT report deterministic as "H1 confirmed").

- ISOLATE-PROBE RESULT = DETERMINISTIC REAL ASYMMETRY (Scout FIN
  `89de3c4e`, ~03:44Z; same artifact e31a6b11…/0A5E37F2): case
  KHR-GL46.shader_image_load_store.advanced-sso-simple ran 3× default
  (all rc=0 Pass) + 3× APPGL_PARALLEL_ENCODE=1 (all rc=1 Fail), zero
  status=5/recovery markers. (Scout caught a false-positive: the broad
  marker regex matched "fault" inside the path token "default" →
  manually inspected stderr/QPA for status=5/recover/reset/hang/IOAF/
  trap, found NO real markers. Diligent.) CONCLUSION: reliably Pass
  serial / reliably Fail parallel — a REAL W2.1 parallel-path
  result-map issue, NOT an intermittent GPU-recovery/sweep-condition
  artifact. GATE OUTCOME: confirmed real + parallel-specific → W2.2
  repair leg GREENLIT (per Clerk's sequencing). TAGGED per the
  interpretation key: deterministic does NOT confirm H1 — it is
  H1 (wrong gate-resolved plan) OR deterministic-H2 (gate missing
  prepareLean's gpuAuthored/SSBO-image guard); Worker's STATIC
  guard-asymmetry read splits it. Handed to Worker + Clerk.

- ═══ W2.2 FIX LANDED — a1677d9 "guard read-image draws off the
  parallel arm" (Clerk re-sweep GO `3581a89b`, 2026-06-13 ~04:02Z) ═══
  RESOLUTION: the disambiguation landed on the deterministic-H2
  GUARD-MISS (Clerk's prime candidate) — the fix guards read-image
  draws off the parallel arm (class-wide reroute to the proven-correct
  serial path). Worker matrix 20-phase green; W2.2 read-image-reject
  probe RED-on-732c763 → GREEN-post captured. Three lanes fired:
  (1) RE-SWEEP: Scout dispatched (`910cd4e2`, thread
  s25-w2_2-twin-sweep-a1677d9) — SPECIFIC gate: advanced-sso-simple
  must flip Pass→PASS in arm B; both arms 19715/19715 maps-identical;
  ZERO collateral P→F from the serial reroute (serial is proven-correct
  — rerouting INTO it can't regress); PRESERVATION check = non-image
  draws still form candidates (guard is read-image-specific, not a
  blanket disable; candidate-formation collapse-to-zero would flag an
  over-broad guard). (2) ATTEST: worktree cut (a1677d9a912…), vendors
  601164c/dcf1aaa verified, CMakeCache Release-confirmed, build
  running — supersedes parked 4BB4EA9D/732c763 as the W2.1+W2.2 head.
  (3) WRAPPER RETARGET: re-stage the sitting onto a1677d9 (same env/
  posture/exit-criteria as the 732c763 wrapper). a1677d9 = GLTest
  re-stage target once this twin certifies. Rotation HELD 4ffd297 until
  the W2.1 sitting reads clean; W1 HELD.

- a1677d9 ATTESTED + SITTING WRAPPER RETARGETED (~04:08Z): pin
  libAppGL-a1677d9-preview-B18646BF.dylib — SHA256 99f7f1ba129735908aa5
  499cd39c8ef7785b949efef16807d715ef18175040fc, UUID B18646BF-3FFB-34C7-
  BF3D-DD09B584D5D8; full protocol, build exit=0, sidecars, pre/post
  match; canonical verified still 4ffd297 post-cut (hold respected).
  This pin SUPERSEDES the parked 732c763/4BB4EA9D as the W2.1+W2.2 head.
  Wrapper launch-warzone-appgl-a1677d9-w2_1-sitting.sh staged
  (syntax-checked, pin sidecar-verified): same env/posture/exit-criteria
  as the 732c763 wrapper (COPY_HEADROOM+PARALLEL_ENCODE+FRAME_ATTR,
  diag-60, telemetry, MacBook, live no-autogame/no-sudo); exit criteria
  = pipeline_not_prepared COLLAPSE + candidate-share OFF 0% steady-state
  (over the non-image-eligible class — W2.2 guards read-image to serial)
  + pacing no-regress vs p99=16/p99.9=23; output memory-runs/
  s25-w2_1-sitting/<stamp>/. One launch line when Clerk calls the
  sitting after the re-sweep greens. B18646BF = GLTest re-stage target
  once the twin certifies it.

- a1677d9 re-sweep LAUNCH-PREP (Scout `22a221ea`, ~04:07Z): parent
  732c763 → a1677d9 verified. Sweep artifact 4355854b5487ea2db877e544
  03cef618bcd8be8a4c7d968de6003e977103c24f / UUID 2BE8380E-E76C-3364-
  8682-69B572C95E93, release_shape=PASS, cmp_vs_build=0, size 11536160
  (+144 vs 732c763 artifact, nm +2 lines — the small read-image guard).
  Build warnings only known MTLResourceUsageSample deprecation. Twin
  runners preparing, default arm first.

- a1677d9 re-sweep, ARM A (default/no-env) GREEN (Scout `53796061`,
  ~04:27Z): 19715/19715 expected-exact, transitions=0 / P→F=0 vs both
  baselines, maps identical, target advanced-sso-simple = Pass, all
  watch scans clean. NECESSARY-BUT-NOT-DECISIVE: default was never the
  failing arm (the 732c763 regression was parallel-ONLY) — ARM B
  (APPGL_PARALLEL_ENCODE=1) is the decisive check (the case must flip
  back to Pass there + no collateral). Arm B proceeding.

- ═══ a1677d9 W2.2 RE-SWEEP GREEN — W2.1+W2.2 CONFORMANCE GATE CLEAR
  (Scout FIN `9a03d7c7`, 2026-06-13 ~04:46Z) ═══
  One artifact both arms: 4355854b…c24f / UUID 2BE8380E-E76C-3364-8682-
  69B572C95E93, release_shape=PASS, cmp_vs_build=0; ancestry 732c763→
  a1677d9 verified. BOTH arms 19715/19715, P=19365 F=35 (back to the 35
  standing — NOT the 36 of the 732c763 arm-B RED), transitions=0 /
  P→F=0 vs both baselines, maps identical. FIX CONFIRMED: arm-B primary
  target KHR-GL46.shader_image_load_store.advanced-sso-simple RESTORED
  732c763-arm-B-RED(Pass→Fail) → a1677d9-arm-B PASS. Zero collateral
  P→F from the serial reroute (as predicted — serial is proven-correct).
  PRESERVATION confirmed (NOT an over-broad guard) via a SEPARATE
  gauntlet probe on the same a1677d9 build (Scout's cross-instrument
  care): s25.w2_1.candidate-delivery PASS "real parallel arm forms
  candidates under a frozen Phase-2 cache" + arm-off PASS counters-zero
  + s25.w2_2.read-image-reject PASS "image-load draw rejected from the
  parallel arm, takes serial path". Scout correctly did NOT read the
  full-CTS parallel_summary_counter_lines=0 as zero-candidates (the
  env posture suppresses those counters — avoided the engaged-nowhere
  false-inference); used the direct probe instead. EFFECT: a1677d9
  (pin B18646BF) CERTIFIED as the W2.1+W2.2 head + the GLTest re-stage
  target. Conformance leg CLEAR. REMAINING W2.1 GATE: the operator
  sitting (wrapper retargeted + staged) — the live-evidence gate the
  rotation HOLD waits on. Rotation still HELD at 4ffd297; W1 HELD.

- SITTING CALLED on a1677d9 (Clerk `dc609251`, ~04:47Z): operator
  running the a1677d9 wrapper live; Worker analyzes the JSONL on
  landing; Clerk dispatches on completion. W2.1+W2.2 → SWEPT-GREEN,
  pending the live-evidence sitting (conformance-green necessary, NOT
  sufficient — same discipline that caught the W2 false-green). ON A
  CLEAN SITTING, THREE THINGS UNLOCK TOGETHER: (a) rotation to a1677d9,
  (b) W1 design dispatch, (c) GLTest re-stage to B18646BF. Until then:
  rotation HELD 4ffd297, W1 HELD. (When the clean sitting lands and
  Clerk issues ROTATION GO, the canonical overwrite will again need the
  operator's express in-session permission per the standing
  classifier-softblock-peer-relay pattern.)

- ═══ W2.1 SITTING NOT CLEAN — LIVE 3D SPARSE-RENDER DEFECT (Clerk
  `dc632c82`, 2026-06-13 ~05:15Z) ═══
  Operator observed on the a1677d9 sitting (PARALLEL_ENCODE=1): the 3D
  SCENE renders SPARSE/STALE frames at MAINTAINED framerate; UI
  (HUD/build-menu/mini-models/mipmap) renders fine. Conformance-green
  (both arms 19715) did NOT catch it — a COMMIT/PRESENT/SYNC-axis
  defect at live scale; the live-evidence gate doing its job. KEY: this
  is the FIRST extended live run where the 3D scene ACTUALLY flows
  through parallel encode (the W2 sitting had candidate-share 0% → 3D
  went serial → looked fine). W2.1 broadened eligibility + W2.2 cleared
  the read-image blocker, so the 3D draws now hit the parallel path and
  a LATENT parallel-encode-path defect surfaced. SECOND live-sitting
  catch in this arc (W2 false-green downstream-of-gate, now W2.1
  sparse-render) — "rotate on EVIDENCE not sweep-green" vindicated
  twice. MOVES: rotation STAYS HELD 4ffd297; W1 STAYS HELD; GLTest
  re-stage does NOT move to B18646BF; a1677d9/B18646BF certified for
  CONFORMANCE ONLY, NOT live-clean. Worker analyzing captured sitting
  telemetry + root-causing (assessment to Clerk BEFORE any fix). No new
  sweep/sitting until Worker assessment + Clerk dispatch; Scout idle.
  Possible same-build PARALLEL_ENCODE on/off A/B re-run TBD pending
  Worker's telemetry read (Clerk dispatches if needed).
  FOREMAN PATTERN-BANK LEAD (offered to Clerk for Worker): sparse/stale
  3D at maintained framerate + UI-fine = the COMMIT/PRESENT/SYNC-axis
  signature of the S24 FLICKER CLASS (invalidateTransientState-destroys-
  frame-semantic-state; a9ccea4 crown fixed pressure-commits-skip-
  present + hasPendingClear frame-semantic state). Parallel-encode
  analogue to check: are the parallel-encoded 3D command buffers being
  COMMITTED/PRESENTED each frame, or abandoned/coalesced while the UI
  CB presents (→ maintained framerate, stale 3D)?
  CLERK relayed the lead to Worker as PRIORITY-1 cross-check
  (`10bf4ced`) — may root-cause from the captured sitting data WITHOUT
  a re-run. POSTURE NOTE: operator is now BACK ON STUDIO — the MacBook
  baseline-of-record (p99=16/p99.9=23) is NO LONGER the current
  posture; any eventual A/B re-run is Studio-posture, awaiting the
  operator's which-display answer. CONSEQUENCE (Foreman flag): the
  a1677d9 sitting wrapper's exit_criteria hardcodes the MacBook pacing
  baseline (p99_16/p999_23); a Studio re-run needs its OWN paired
  Studio baseline — the MacBook numbers do NOT transfer (measurement
  canon: cross-sitting absolutes non-comparable, paired same-conditions
  only). Will re-baseline the wrapper pacing reference if/when Clerk
  dispatches a Studio re-run.
  CLERK STRENGTHENED (`f36af82b`) — supersedes the posture-only flag:
  the pacing leg is INVALID on a1677d9-as-is, not just posture-bound.
  "Maintained framerate with sparse/stale 3D" is a FALSE PERF SIGNAL —
  the framerate is held up PRECISELY by NOT doing the 3D work every
  frame; reading it as "at least pacing held" is the exact mistake.
  This is the PERF-AXIS instance of the false-green / engagement≠benefit
  class (framerate-engaged ≠ frames-actually-rendered) + S23
  correctness-before-perf canon (a path's perf-credit isn't valid until
  correct). SEQUENCING: defect root-cause → fix → re-sweep → re-run;
  ONLY at the post-fix re-run do the display-agnostic exit criteria
  (pipeline_not_prepared collapse + candidate-share off 0%) carry over
  AND I cut a fresh Studio paired pacing baseline. NO pacing read off
  a1677d9-as-is. The wrapper pacing re-cut happens at that post-fix
  re-run, not before.

- LEAD CORROBORATED + BOOKKEEPING (Clerk `00dbe12b`, ~05:25Z): operator
  A/B reproduces the sparse-3D on BOTH Studio (original) AND MacBook
  (re-test), flicker rate SCALES WITH FPS → display-independent +
  FPS-scaling = per-frame worker-CB commit/present-sync defect (rules
  out vsync-interaction; confirms per-frame mechanism = the parallel
  analogue of a9ccea4). The S24-flicker-class lead confirmed.
  FOREMAN RECONCILED (POSTURE-RECONCILIATION.txt in
  memory-runs/s25-w2_1-sitting/, original run-env proofs left intact):
  3 runs on a1677d9/B18646BF — (i) 045039Z = STUDIO original
  defect-capture, ~1221s, ~86 present-FPS, 1752 records (richest data);
  (ii) 052010Z = MacBook re-test, ~29s, ~132 present-FPS, 65 records —
  CONFIRMS Clerk item-2 second-JSONL captured; (iii) 044849Z = short
  04:48 pre-run, ~63s, ~109 FPS, attribution-to-confirm (presumed same
  Studio session, not asserted). FPS-A/B for Worker: ~86 (Studio) vs
  ~132 (MacBook) same-build, flicker∝FPS. Posture-baseline mismatch
  (wrapper hardcoded MacBook p99_16/p999_23 but original was Studio)
  documented as MOOT — pacing invalid on the defective build anyway.

- ═══ DIAGNOSIS SHIFTED — REAL CAUSE = STALE-BUFFER-CAPTURE (Clerk
  `e08b5d86`, 2026-06-13 ~05:32Z; telemetry SUPERSEDED my flicker-class
  lead) ═══
  DISCRIMINATING FACT (telemetry, not the A/B): parallelEncodedDraws=0
  — batches NEVER form (the pre-registered FBO-interleave-below-min-
  batch outcome = the Rung-1 ZERO-batches headline). So NO separate
  worker 3D command buffer ever exists → CB-present-sync is
  STRUCTURALLY IMPOSSIBLE; the 3D draws serial-replay into the UI's
  present CB in lockstep. My commit/present-sync hypothesis = RULED OUT.
  (The A/B cuts — display-independent + FPS-scaling — were consistent
  with BOTH hypotheses; they did NOT discriminate. The telemetry did.
  My pattern-match still earned its keep: it pointed Worker at the right
  AXIS [commit/present/CAPTURE] and ruling out the present-sync leg
  cleanly is what surfaced the real leg. Methodology note: a sound-but-
  wrong prior that names the right axis + gets cleanly ruled out
  ACCELERATES diagnosis — value even when superseded.)
  REAL CAUSE: stale-buffer-CAPTURE. The lean descriptor captures
  buffer-backed bindings (vertex MetalFrameGraph.mm:1879, buffer-UBOs
  :9347) by RAW UN-RETAINED POINTER. rename-on-write's keepalive (:11971)
  retains the OLD buffer for LIVENESS, but the deferred draw binds that
  old buffer → renders the PREVIOUS frame's data (= sparse/stale 3D;
  scales with FPS because more frames = more rename cycles = more
  visible staleness; display-independent because it's a data-capture
  bug). This is the DOSSIER'S pre-identified deep-copy+retain /
  capture-completeness precondition, forced EMPIRICALLY: W2.1 fed real
  per-frame 3D through the lean path for the first time; CTS never
  orphans-mid-deferral at scale → THE MASK (why conformance stayed
  green). CLASSIFICATION: a Rung-2 DESIGN PRECONDITION (blocks W1 too),
  NOT a contained repair. NEXT: Worker building a deep-copy-toggle A/B
  (prefer in-gauntlet deterministic repro) to CONFIRM the mechanism +
  MEASURE real-scale deep-copy cost vs the Rung-1 projection (the
  dossier's deep-copy economics, now the load-bearing number; the
  eventual re-sitting's frame-pacing leg validates whether the cost is
  acceptable). No new sweep/attest until confirm + fix lands. Holds all
  stand (rotation 4ffd297, W1, GLTest re-stage). a1677d9/B18646BF =
  conformance-certified / LIVE-DEFECTIVE.

- DIAGNOSIS UPDATE — rename-on-write ALSO REFUTED, METHOD PIVOTS (Clerk
  `5c8e4ef1`, ~05:38Z; Worker self-corrected from the FPS-A/B):
  bufferRenames=42 over 105,059 frames Studio / 0 on MacBook = ≈0/frame
  → rename-on-write is NOT the staleness trigger (WZ isn't orphaning
  buffers at a meaningful rate). ⚠ SUPERSEDES the mechanism in my prior
  entry ("rename-on-write keepalive retains old buffer → prev-frame
  data") — that specific trigger is REFUTED; the capture-by-raw-pointer
  FACT survives, the rename-on-write TRIGGER does not.
  THREE MECHANISMS NOW RULED OUT BY EVIDENCE: (1) rename-on-write
  [renames≈0], (2) drawable-split [same currentDrawable :9673], (3)
  separate-worker-CB present-sync [parallelEncoded=0 — my lead].
  STANDING FACT (code-confirmed, survives all three): the lean
  descriptor captures buffer bindings by RAW UN-RETAINED POINTER
  (vertex :1879, UBOs :9347). The defect is real (live sitting); the
  TRIGGER (what invalidates the captured data) is NARROWER than any
  hypothesis tried.
  METHOD PIVOT: Worker STOPS hypothesizing from observational captures
  (insufficient TWICE — present-sync, then rename-on-write) → builds a
  DETERMINISTIC IN-GAUNTLET BINARY-SEARCH repro to find the trigger BY
  CONSTRUCTION (candidates: in-place glBufferSubData / uniform /
  index-vertex / pass-structure / drawable-recycle), THEN the deep-copy
  toggle confirms fix-direction + measures cost. METHODOLOGY LESSON
  (pattern-bank): observational-capture hypothesizing failed twice;
  deterministic construction is the escalation — same family as
  isolated-probe / GPU-output-not-counters / deterministic-repro.
  No new sweep/attest until the trigger is PINNED + fix lands. Holds
  all stand; Scout idle.

- 044849Z DISPLAY FINALIZED + DIAGNOSTIC (Clerk `537a5f50`, ~05:40Z):
  operator-confirmed 044849Z = STUDIO (the initial glitch-sighting
  launch, ~63s, before the full 045039Z capture) — no longer
  presumed-unconfirmed; POSTURE-RECONCILIATION.txt updated. All three
  a1677d9 captures now display-KNOWN: 044849Z Studio (~109fps, initial
  sighting), 045039Z Studio (~86fps, full capture), 052010Z MacBook
  (~132fps, re-test). KEY DIAGNOSTIC: the glitch was present FROM the
  initial short launch → staleness is IMMEDIATE, not accumulation
  (relayed to Worker — constrains the binary-search: the trigger fires
  on the FIRST deferred replay, NOT after N frames of orphan buildup;
  rules out slow-leak/accumulation classes).

- ═══ DIAGNOSIS CONVERGED — PRESENT/COMPOSITING AXIS (a9ccea4
  frame-semantic CLASS VINDICATED) (Clerk `ce64b21b`, 2026-06-13
  ~05:50Z) ═══
  Worker's deterministic in-gauntlet repro REFUTED the data-staleness
  axis (v2: 8192B by-reference UBO, in-place mutation while pending →
  draw preserved draw-TIME content → the by-reference path is PROTECTED
  by liveBindSubmitIndex / flushEncodeBoundaryForBufferWrite). FOUR
  mechanisms now eliminated: rename-on-write, drawable-split,
  separate-CB, data-mutation. RESIDUAL BY ELIMINATION = the PRESENT/
  COMPOSITING axis: the lean-direct render PASS intermittently does NOT
  land on the PRESENTED drawable → stale 3D on the presented surface.
  MY a9ccea4 FRAME-SEMANTIC CLASS INSTINCT = VINDICATED — refined to
  the exact axis: LEAN-DIRECT-PASS present/compositing, NOT separate-CB
  (parallelEncoded=0 ruled that out). The gauntlet structurally CAN'T
  settle it (offscreen, no real drawable/present — the SAME gap that
  hid it from CTS). FOREMAN ON DECK: Worker is building a MATRIX-SAFE
  OBS-ONLY per-frame counter (lean-direct-pass landed-on-presented-
  drawable vs present count + the inverse). WHEN THE COUNTER SHA LANDS:
  (a) attest the new pin (full protocol), (b) stage a SHORT obs-only
  sitting wrapper on it — same posture/env, Studio, ~1-2min (defect is
  immediate), NO pacing gate (obs-only; the only "exit criterion" is
  the new counter captured in the JSONL). Clerk coordinates the
  operator short run to PIN THE SEAM → then a precise fix mirroring
  a9ccea4 frame-boundary discipline for the lean-direct pass. NO
  active-path fix until the seam is localized. Holds all stand
  (rotation 4ffd297, W1, GLTest re-stage); Scout idle.

- SHORT OBS-SITTING WRAPPER — RATIFIED + 3 ADDITIONS (Clerk
  `b130501e`, ~05:53Z): shape approved (Studio condition-IDENTITY with
  the 045039Z defect-capture; KEEP env — PARALLEL_ENCODE=1 is MANDATORY,
  it's what routes the 3D through the defective lean-direct pass [serial
  3D renders fine, nothing to observe]; DROP the pacing exit-criterion —
  invalid on defective build + obs-only). ADDITIONS:
  (1) VERIFY the new landed-on-presented-drawable counter latch is ON +
  actually EMITS to the framePacing JSONL — SOLE success condition; a
  non-emitting run = wasted operator interruption. FOREMAN: dry-run the
  new pin MYSELF post-attest, grep the JSONL for the counter section
  before pinging Clerk (VERIFY-items-are-gates / teardown-only-output
  instrument discipline).
  (2) the FALSIFIABLE INVERSE is THE signal — "presents where the
  lean-3D pass did NOT land"; the counter is built to be able to prove
  the present/compositing hypothesis WRONG (lands-every-present →
  refuted → re-open). Read BOTH landed AND not-landed, not just the
  positive.
  (3) ONE short Studio run SUFFICES; decisive datum = presents-without-
  lean-3D > 0. FPS-scaling is secondary corroboration, ALREADY in hand
  (86fps-Studio vs 132fps-MacBook) — do NOT require a 2nd posture/run;
  keep the operator ask to the single short Studio run.
  SEQUENCE: Worker SHA lands → I attest full-protocol → build wrapper →
  I dry-run-verify the counter emits (both fields) → ping Clerk
  verified-ready → Clerk coordinates the single short Studio operator
  run. No build until the SHA exists.

- DRY-RUN UPGRADED — MAY PIN THE SEAM OUTRIGHT (Clerk `70785a30`,
  ~05:55Z): the counter (lean-3D pass landed-on-presented-drawable) is
  a STRUCTURAL/timing fact — camera-motion-INDEPENDENT. The operator
  needed camera panning to SEE staleness (static content looks the same
  stale-or-fresh), but the counter detects pass-not-landing DIRECTLY
  regardless of motion. My autogame dry-run (PARALLEL_ENCODE=1, 3D
  presenting through a REAL --window drawable) uses the SAME
  lean-direct-pass routing as the operator session → DECISION-RELEVANT,
  not just a latch check. REPORT THE ACTUAL VALUES:
  • presents-without-lean-3D > 0 in autogame → seam PINNED structurally
    → likely SKIP the operator run (recommend so to Clerk).
  • presents-without-lean-3D = 0 in autogame → either #4 refuted OR
    intermittency is input/motion-dependent (autogame pans less than the
    operator) → operator short run discriminates (operator >0 =
    motion-dependent; operator also 0 = #4 refuted, re-open).
  REPRESENTATIVENESS (pattern-bank, verify-instrument-matches-real-use):
  the autogame dry-run is decision-CAPABLE precisely BECAUSE it's
  windowed → presents to a REAL drawable (the real-usage present path) —
  the OFFSCREEN gauntlet structurally could NOT land-check, the same gap
  that hid the defect from CTS. Ensure --window (real drawable). Ping
  Clerk with emit-confirm AND the values; Clerk decides operator-needed
  vs pinned-already.

- ═══ fb200aa LOCALIZER ATTESTED + DRY-RUN = EMISSION-VERIFIED /
  OFFSCREEN-NON-DIAGNOSTIC (Foreman, 2026-06-13 ~06:05Z) ═══
  Pin libAppGL-fb200aa-preview-3296379A.dylib — SHA256 173cfdc3acc2dab5
  ec11354f4264d218c5a4acb20662de3f01b87dcdc97365b3, UUID 3296379A-CD49-
  3EB0-BF1F-F0F4339676C7; full protocol, build exit=0, canonical held
  4ffd297. Wrapper launch-warzone-appgl-fb200aa-localizer.sh (--window,
  PARALLEL_ENCODE=1 mandatory, obs-only, no pacing gate). Counter keys
  (framePacing.presentLeanLanding): swapPresents/withLeanEncoded/
  drawableMatched/drawableMismatched/leanInPresentedCB/leanInPriorCB/
  candidatesButZeroEncoded.
  DRY-RUN (autogame, dryrun-20260613T060401Z): EMISSION ✓ VERIFIED —
  the section emits + populates in the captured JSONL (final sp=270,
  withLean=263, matched=261, mismatched=2, leanInPriorCB=2, candZero=6).
  The wrapper CAPTURES the counter → the operator run will too.
  BUT PATH = OFFSCREEN / NON-DIAGNOSTIC: currentDrawablePresent=0 +
  currentDrawableTextureBytes=0 + currentDrawableWidth=0 across ALL 10
  records → NO real on-screen CAMetalLayer drawable. My bridge-shell
  launch (tty ttys002, no window-server/Aqua session) gives WZ NO
  on-screen drawable → offscreen by construction (also: CGWindowList
  found NO WZ window, only my iTerm2 title false-positive). HARD
  CONSTRAINT: Foreman CANNOT produce an on-screen drawable from the
  bridge shell — only the operator's GUI-session launch gets a real
  CAMetalLayer. The mismatched=2/priorCB=2 are NOT the seam: they
  FROZE at exactly 2 from sp=60 onward (one-time early-startup
  transition; a real per-present seam ACCUMULATES). So I do NOT report
  pinned (offscreen mismatched>0 = artifact, not the on-screen
  drawable-rotation seam — the representativeness-gap discipline:
  offscreen instrument ≠ on-screen real usage). VERDICT: offscreen-only
  dry-run → EMISSION-VERIFY ONLY → the OPERATOR ON-SCREEN SHORT RUN IS
  NEEDED to pin. Bonus for that run: subtract my baseline — the real
  seam shows mismatched/priorCB ACCUMULATING with presents; a frozen
  small constant (~2) is startup artifact. (Autogame also ended in ~5s
  on an HCI assert — short, but 270 presents captured, emission valid.)

- VERDICT ACCEPTED + OPERATOR RUN DISPATCHED (Clerk `c7d702df`,
  ~06:10Z): offscreen self-diagnosis + the frozen-mismatch restraint
  credited as the representativeness-gap rigor applied to my OWN
  instrument (refusing to mis-pin). Clerk dispatching the operator
  on-screen short run NOW (their GUI session = the ONLY source of a
  real CAMetalLayer — confirmed unavoidable). Wrapper verified-ready:
  launch-warzone-appgl-fb200aa-localizer.sh (--window, Studio, obs-only,
  PARALLEL_ENCODE=1; short skirmish w/ camera panning ~1-2min). MY
  baseline-subtraction key = INTERPRETATION OF RECORD: decisive seam =
  ACCUMULATING drawableMismatched OR leanInPriorCB (>0 AND growing with
  swapPresents), NOT the ~2 startup constant. SEQUENCE: operator JSONL
  → Worker localizes the seam → precise fix proposal to Clerk. Holds
  stay (rotation 4ffd297, W1). FOREMAN STANDING BY — ready to extract
  the operator JSONL counter-progression on landing if Clerk/Worker
  want the accumulating-vs-frozen read (tooling primed); not preempting
  Worker's localization.

- ═══ OPERATOR LOCALIZER RUN = HYPOTHESIS #4 REFUTED (Foreman extract,
  2026-06-13 ~13:05Z; run 20260613T124927Z, 426 records, fb200aa pin
  3296379A, operator-live; Clerk dispatch af28c8b7/ca91f115 [post-clog
  re-sync]) ═══
  VALIDITY — currentDrawable*=0 across all 426 records (the field Clerk
  flagged as the validity proxy), BUT THIS IS NOT AN INVALID/OFFSCREEN
  RUN. Decisive counter-evidence the run IS valid on-screen: offscreen
  Color* = 0 (offscreen target NEVER allocated → usesOffscreenTarget=
  false → the localizer compared against the REAL drawable, NOT
  offscreen-by-construction); layerDrawableWidth/Height = 5120×2756
  (real CAMetalLayer, Studio retina); drawableAcquireSuccesses=12750 +
  drawablePresentCalls=12748 + drawableReleaseCalls=12750 (real
  drawable lifecycle); observedDrawableTextureBytes=171,868,160 / 6
  textures. currentDrawable* is a MISLEADING proxy here — reads 0
  because the member is nil'd post-present (drawableNilAfterPresent=
  12748) and the diag snapshots after; the matched logic PROVES a
  non-nil real presented texture was compared (matched can't increment
  against nil). Validity = VALID on-screen, per the acquire/layer/
  offscreen=0 evidence, NOT the currentDrawable* proxy.
  COUNTERS (valid, diagnostic): swapPresents=12750, withLeanEncoded=
  10023, drawableMatched=10023, drawableMismatched=0, leanInPresentedCB
  =10023, leanInPriorCB=0, candidatesButZeroEncoded=2726.
  RESULT = OPPOSITE of the expected signature (Clerk expected mismatched
  HIGH from the blue-most-frames visual): matched==withLean (10023),
  mismatched=0, priorCB=0 → the lean-3D pass LANDS on the presented
  drawable, in the presented CB, EVERY present. Per Clerk's falsifiable
  design (matched≈withLean + mismatched/priorCB≈0 → #4 DISPROVEN) →
  HYPOTHESIS #4 REFUTED. Drawable-rotation (mismatched=0) AND
  out-of-band-CB (priorCB=0) BOTH eliminated. REOPEN.
  VISUAL-VS-COUNTER GAP (for Worker's next layer): operator sees
  blue-most-frames, yet 79% of presents (10023/12750) land 3D correctly
  + 21% candidatesButZeroEncoded (2726, no 3D encoded those presents).
  So the seam is DOWNSTREAM of drawable+CB IDENTITY: the 3D reaches the
  right texture in the right CB yet shows blue → CONTENT/encode-order/
  store-action/overwrite (a clear or pass overwriting the landed 3D, or
  storeAction=dontCare, or pass-ordering) AND/OR the candidatesButZero
  presents. The localizer instruments IDENTITY (matched), not
  content-survival — that's the next localization layer. Holds stay
  (rotation 4ffd297, W1).

- SEAM REDIRECTED → PASS SURVIVAL (Clerk `489107c0`, ~13:08Z; confirms
  my refutation): landing hypotheses are counter-DEAD (steady-state
  100% drawableMatched, 0 mismatched, 0 leanInPriorCB). Seam =
  DOWNSTREAM PASS SURVIVAL — the 3D lands on the presented drawable+CB
  but is OVERWRITTEN/DISCARDED before present (store-action discard or
  clear-after-3D; present() lean-flush vs flushPendingClear ORDERING =
  leading candidate). Worker pinning the exact code-site now.
  ⚠ INSTRUMENT CONSEQUENCE (my role): the fb200aa landing-localizer is
  now KNOWN-BLIND to survival (SATURATED 100%-landed) → do NOT reuse it
  to validate the eventual fix — it reads green regardless = a
  false-green generator (pattern-bank: saturated instrument / VERIFY-
  items-are-gates / instrument-must-match-real-usage). Fix-validation
  needs a SURVIVAL-aware instrument (Worker builds: store-action audit /
  post-present pixel-check) OR operator-visual — NOT the landing
  counter. When the fix lands: attest new SHA + Clerk-dispatched twin
  sweep still apply (real code change → conformance re-validate); the
  LIVE-validation leg switches to survival-aware, not landing-localizer.
  Clerk dispatches the fix's gate shape when Worker's pin + fix proposal
  lands. No attest/sweep until the fix exists. Holds all stand
  (rotation 4ffd297, W1, GLTest re-stage).

- TRIANGULATED + ALIGNED (Clerk `0ede9e4c`, ~13:09Z): three independent
  reads converge — Foreman extract + Worker (25f6b4cb) + Clerk's own
  direct pull of 20260613T124927Z during the clog — IDENTICAL counters,
  #4 disproven, seam = PASS-SURVIVAL. My drawable-validity evidence is
  the CAVEAT-CLOSER for Worker's usesOffscreenTarget open question
  (offscreenColor*=0 + layer 5120×2756 + drawableNilAfterPresent=12748
  → currentDrawable*=0 is a post-present-nil snapshot artifact, NOT a
  validity failure → drawableMatched=10023 is a REAL signal). Worker
  pinning present()-lean-flush vs flushPendingClear ORDERING now. My
  "localizer measures IDENTITY not SURVIVAL → instrument survival next"
  IS Clerk's fix-validation ruling (saturated landing-localizer is
  blind to survival; fix gate needs a survival-aware instrument or
  operator-visual, NOT the landing counter). Fully aligned — awaiting
  Clerk's fix-gate-shape dispatch when Worker's pin + fix proposal land.

- FIX-TIME SEQUENCE CONFIRMED + SURVIVAL-GATE IS MECHANISM-DEPENDENT
  (Clerk `a7756f33`, ~13:10Z): at fix-time I still (a) attest new SHA
  full-protocol + (b) twin sweep (active-path present/clear-ordering
  change → conformance MUST re-validate, P→F=0); LIVE-validation leg
  switches to the survival-aware instrument (the spent landing-localizer
  = false-green generator if reused, banked). ⚠ DON'T PRE-BUILD the
  survival instrument — its EXACT FORM is decided by the MECHANISM and
  ships WITH Clerk's fix adjudication: (i) clear-after-3D on the SAME
  target → OFFSCREEN pixel-readback (render 3D → assert target holds 3D
  not just clear) = NO operator, in-gauntlet; (ii) present/store-action
  drawable-specific → live/operator-visual. Clerk dispatches the
  survival-gate-shape together with the fix go. Holds all stand
  (rotation 4ffd297, W1, GLTest re-stage); Scout idle. WAITING: Worker
  pin → Clerk fix-go + survival-gate-shape → my attest + twin sweep +
  survival-validation.

- ═══ 3b57be0 SURVIVAL PROBE — INCONCLUSIVE (overwritten=0 but NON-
  REPRESENTATIVE run), branch 2-vs-3 routed to Clerk (Foreman,
  2026-06-13 ~13:35Z; run-20260613T133244Z) ═══
  Pin libAppGL-3b57be0-preview-5B9F6309.dylib (SHA256 44da0d80…), full
  protocol, canonical held 4ffd297. Counters: framePacing.
  presentLeanLanding.{lean3DSurvived,lean3DOverwritten}; wipe-detect =
  noteDrawablePassOpenForSurvival (drawable pass loadAction=Clear/
  DontCare after last lean-3D draw flips drawableLastWriteWas3D=false).
  PRE-CHECK ✓: lean ENGAGED (withLeanEncoded=294>0), FBO-interleave
  PRESENT (fbo_draw=39188); parallelEncodedDraws=0 (ZERO batches —
  known WZ FBO-interleave-below-min-batch; lean draws encode serial-
  into-present-CB but ARE lean-encoded). PATH: REAL CAMetalLayer
  drawable — layerDrawable 2560×1440 triple-buffered (observedDrawable
  TextureBytes=44,236,800 = exactly 3×2560×1440×4), drawableAcquire
  Successes=300, offscreenColor*=0 → NOT offscreen-by-construction;
  currentDrawable*=0 = the post-present-nil snapshot artifact (as in
  the operator run). SURVIVAL: lean3DSurvived=294, lean3DOverwritten=0
  → NO wipe this run.
  ⚠ INCONCLUSIVE, NOT a clean disproof — REPRESENTATIVENESS CAVEAT: the
  run does NOT reproduce the operator's repro conditions — res
  2560×1440 (likely a HEADLESS layer, bridge shell no display) vs the
  operator's on-DISPLAY 5120×2756; SHORT ~5s/300-present autogame (HCI
  assert "Invalid ButId" → game-over duration-5) vs operator 12750; NO
  camera panning (operator's defect was explicitly pan-/live-specific).
  A structural per-MOST-frames wipe should show SOME overwritten in 294
  lean presents → clean 0 + non-matching conditions = INCONCLUSIVE.
  Literally matches Clerk branch 2 (engaged+FBO+overwritten≈0 →
  disproven) BUT the representativeness gap leans branch 3 (on-display/
  pan-specific → operator on-screen authoritative). Hinges on what
  Worker's "offscreen-detectable deterministic repro" demonstrated
  (synthetic construct vs autogame stream) — Clerk/Worker know, I
  don't → RQ-DIR to Clerk to adjudicate. Holds stand (rotation 4ffd297,
  W1).

- HARDENING VERDICT = OPERATOR-ONLY (Foreman, 2026-06-13 ~13:45Z; answers
  Clerk ddb1d36b/c833ca6a). Clerk branch-2 OUT (Worker's "offscreen-
  detectable" was SYNTHETIC instrument-validity, not natural-repro;
  my restraint validated). Worker mechanism (c833ca6a): the wipe is
  MOTION-DEPENDENT — FBO draws are shadow/RTT passes CACHED when
  camera+scene static, RE-RENDERED on PAN → pan produces the multi-pass
  interleave → post-3D drawable clear → wipe. CAN MY AUTOGAME HARDEN
  (pan + run-past-5s)? NO — hard wall on the decisive lever:
  • Autogame has ZERO camera motion (grep-empty: no setViewPos/scroll in
    the autogame path); camera is keybind-only (kf_ScrollCamera needs key
    input — my bridge CLI cannot inject keypresses); no recorded panning
    replay exists to --loadreplay (only netreplay infra, no .wzrp).
  • The 5s end = the autogame PLAYER is eliminated (makePlayerSpectator
    player 0, ~20 game-min simulated in ~5s wall); a longer-surviving
    config wouldn't add PANNING.
  ⇒ the motion-dependent wipe cannot be triggered from my CLI → OPERATOR
  on-screen run (manual panning) is authoritative.
  NUANCE for Worker's classification: my survival run had fbo_draw=39188
  (HIGH) + withLeanEncoded=294 + overwritten=0 — so by the new precheck
  (fbo-high + lean-engaged) it borderline reads as interleave-PRESENT →
  the FALSIFICATION branch (→ operator + Worker extends instrument),
  not cleanly "near-static/under-exercised". Whether fbo_draw=39188 is
  the pan-triggered shadow-rerender interleave vs cached-FBO bulk is
  Worker's call — both routes → operator. PRE-STAGED: on-screen survival
  wrapper launch-warzone-appgl-3b57be0-survival-onscreen.sh (pin
  5B9F6309, --window, PARALLEL_ENCODE=1, obs-only, operator-instructions
  = short skirmish WITH PANNING). Recommend dispatch operator; optional
  low-confidence long-shot (unit-heavy config for incidental warcam-
  follow motion) NOT recommended (my run already had gameplay motion +
  high fbo + overwritten=0). Holds stand (rotation 4ffd297, W1).

- NUANCE FLIPPED THE PLAN → CONTENT PROBE ON MY AUTOGAME FIRST (Clerk
  `fb36cd5d`, ~13:49Z): my fbo-high(39188) + lean-engaged(294) +
  overwritten=0 = interleave-PRESENT + no-wipe-seen = FALSIFICATION of
  the structural counter → the survival counter is TOO NARROW (the wipe
  is plausibly a Load-pass DRAW-OVER it can't see, possibly even
  WITHOUT pan). NOT going straight to operator. NEW PLAN (operator-
  AVOIDING first): Worker building the CONTENT PROBE = authoritative
  pixel-survival readback (reads the drawable's scene region, counts
  clear-color samples → catches EVERY overwrite class incl. draw-over)
  + an ordinal localizer. KEY ENABLER: my autogame has a REAL headless
  CAMetalLayer (2560×1440) → content READBACK WORKS HEADLESS → I run
  the content probe on MY AUTOGAME FIRST. BRANCHES: contentMissing>0 in
  my no-pan/high-fbo run → wipe present WITHOUT pan → PINNED, NO
  operator; contentPresent (3D survives) → wipe IS pan-dependent → THEN
  operator on-screen content-run (my pre-staged onscreen wrapper =
  FALLBACK, will carry the content probe). STAND BY for Worker's
  content-probe build → Clerk dispatches the autogame content-run to me.
  Holds stand (rotation 4ffd297, W1); Scout idle.

- VEHICLE CONFIRMED = MY AUTOGAME content-run, NOT operator (Clerk
  `e61b1707`, ~13:53Z). Worker's fbo_draw=39188 analysis: GENUINE
  per-frame interleave — ~133 FBO/frame, 63% FBO share MATCHING the
  operator's 56-58%, 98% lean-engaged = gameplay-scale (NOT cached
  bulk). So my survival run was a TRUE branch-(b) FALSIFICATION:
  interleave-present + lean-engaged + overwritten=0 → the structural
  counter is proven too narrow; the wipe is plausibly a Load-pass
  DRAW-OVER present EVERY frame (operator pan-correlation = "you only
  NOTICE missing 3D when the scene should move"). REPRESENTATIVENESS
  RESOLVED: my autogame IS representative (matching FBO share + genuine
  interleave) → the content readback on my headless CAMetalLayer
  (2560×1440) SHOULD catch it → NO operator expected. STAND BY for
  Worker's content-probe build (§2 ordinal + §1 pixel-readback, matrix)
  → Clerk dispatches my autogame content-run on the new SHA. Expected:
  contentMissing in the SCENE region → PINNED + the ordinal localizes
  the over-drawing pass → no operator; contentPresent → pan-dependent →
  operator fallback (pre-staged on-screen wrapper). The fbo-high+
  overwritten=0 nuance unlocked the no-operator path. Holds stand
  (rotation 4ffd297, W1); Scout idle.

- ═══ 5754c36 CONTENT-PROBE RUN = GAMEPLAY CONTENT SURVIVES (the
  contentMissing is a GAME-OVER FALSE-POSITIVE) → BRANCH 2, OPERATOR
  NEEDED (Foreman, 2026-06-13 ~14:10Z; run-20260613T140802Z, pin
  FE219790, APPGL_W2_SURVIVAL_CONTENT_PROBE=1) ═══
  PRE-CHECK ✓: lean engaged (withLeanEncoded=264), fbo_draw=34382 high
  (genuine interleave). FINAL counters: lean3DContentPresent=197,
  lean3DContentMissing=65 (structural lean3DOverwritten=0 as expected —
  blind). NAIVE read = "contentMissing=65 → wipe". ⚠ FALSE POSITIVE,
  caught by progression+stderr correlation: contentPresent grew
  MONOTONICALLY 24→171 through sp1-180 with contentMissing=0 (3D
  content SURVIVES during ACTIVE GAMEPLAY); then contentPresent FROZE
  at ~196 while contentMissing accumulated 6→35→65 (sp210→270) — and
  stderr shows makePlayerSpectator player0 + displayGameOver "Game
  ended" at exactly that transition. So the 65 missing = the GAME-OVER/
  spectator screen (legitimately NOT a 3D scene), NOT the operator's
  mid-gameplay wipe. During no-pan gameplay the content SURVIVED
  (missing=0, present growing). VERDICT: BRANCH 2 — 3D genuinely
  survives no-pan in gameplay → the operator's wipe IS pan-dependent
  (Worker's "every frame even without pan" NOT supported by the
  gameplay data) → OPERATOR ON-SCREEN content-run needed (pre-staged
  wrapper re-pointed to FE219790 + content probe). PROBE-QUALITY FLAG
  for Worker: the content probe counts game-over/spectator/menu frames
  as contentMissing (false-positive class) — needs a GAMEPLAY-ONLY gate
  (exclude post-displayGameOver / spectator / menu), else any run that
  ends in game-over inflates contentMissing. Routed to Clerk RQ-DIR.
  Holds stand (rotation 4ffd297, W1); Scout idle.

- BRANCH 2 ACCEPTED + GAMEPLAY-GATE REQUIRED BEFORE OPERATOR (Clerk
  `265713d7`, ~14:14Z): the progression+stderr correlation is the rigor
  of record (final counts alone would have FALSE-pinned; reading the
  progression caught the game-over false-positive). Wipe IS pan-/live-
  dependent → operator on-screen content-run genuinely needed. PROBE-
  QUALITY FLAG = correct + REQUIRED: the gameplay-only gate (exclude
  post-displayGameOver/spectator/menu) MUST land FIRST — the false-
  positive class is PROVEN and the operator's read must be gameplay-
  clean (their run could also end in game-over). SEQUENCE: HOLD the
  operator run → Worker adds the gameplay-gate → NEW SHA → I attest +
  cut the on-screen content wrapper on the GATED SHA → Clerk dispatches
  the operator. ⚠ DO NOT cut the wrapper on FE219790 (pre-gate) —
  superseded by the gated SHA. Stand by for Worker's gated build. Holds
  stand (rotation 4ffd297, W1); Scout idle.

- ═══ GAMEPLAY-GATE DATA-FIT = FAILED + REFRAMES MY FALSE-POSITIVE CALL
  (Foreman, 2026-06-13 ~14:30Z; Clerk d93f960 gate = arm probe only when
  frame FBO ≥ APPGL_W2_SURVIVAL_GAMEPLAY_MIN_FBO, default 16) ═══
  Data-fit on my 5754c36 run (per-interval fbo_draw cumulative deltas
  over 30-frame records): GAMEPLAY (sp60-180, contentMissing=0) =
  ~131-135 FBO/frame; the contentMissing PHASE (sp210-270) = ~163-168
  FBO/frame — HIGHER than gameplay, NOT ≤16. So threshold-16 does NOT
  exclude the contentMissing frames, and NO MIN_FBO value separates
  game-over/late-phase from gameplay (the former has MORE FBO). ⇒ the
  FBO-interleave proxy FAILS as a game-over discriminator for this data;
  Worker's "game-over ≈0 FBO" assumption is REFUTED.
  REFRAME (overturns my earlier game-over-false-positive call): a static
  game-over/menu screen would NOT render ~165 FBO/frame. So the
  contentMissing frames are 3D-RENDERING frames showing CLEAR color =
  plausibly the REAL WIPE caught WITHOUT pan (likely in spectator-view
  post-player-0-elimination — WZ skirmish loss → spectator, the 3D world
  keeps rendering [165 FBO] while the scene-center is wiped to clear).
  My sp1-180 "gameplay survives" still holds (contentMissing=0 there),
  but the sp196-270 missing is NOT a static-screen artifact — it may be
  the wipe in the spectator/late phase. This is AMBIGUOUS: (A) real wipe
  caught no-pan → possible no-operator pin, OR (B) spectator-view-
  specific path. CONSEQUENCE: do NOT cut the operator wrapper — the gate
  as built won't make the run clean (FBO doesn't discriminate), and
  whether my run already caught the wipe needs Worker re-analysis.
  Routed to Clerk RQ-DIR. Holds stand (rotation 4ffd297, W1); Scout idle.

- CAMERA-MOTION FINDING + SYNC (Clerk `54bcae7d`, ~14:31Z; routing:
  sync run to Worker + check spectator-phase camera motion + HOLD
  wrapper-cut): NO direct camera/view-motion counter in the diag (only
  sparse wasViewportRenderedTo 0/1). BUT the FBO/frame jump itself IS
  the motion proxy per Worker's mechanism: active gameplay sp60-180 =
  ~131-135 FBO/frame (content SURVIVES), spectator sp210-270 = ~163-168
  FBO/frame (content MISSING). Higher FBO = MORE shadow/RTT re-render =
  MORE camera motion (spectator auto-follow) → this UNIFIES the
  spectator-wipe with the operator's pan-correlation (motion→shadow-
  rerender→interleave→wipe) ⇒ my autogame plausibly ALREADY CAUGHT the
  wipe in the spectator phase → POSSIBLE NO-OPERATOR PIN. SYNC: only
  ONE memory-runs root exists (live-targets/appgl-bridge/memory-runs,
  shared) — the run is already at the canonical path; handed Worker the
  absolute path + extracted per-interval analysis directly (no separate
  Worker memory-runs to copy to). Worker disambiguates: sp196-270 =
  real wipe (auto-follow-motion class, = operator's pan class → already
  caught) vs spectator-render-path artifact. HOLD operator wrapper-cut;
  NOT cutting on d93f960 FBO-gate (can't separate phases). Holds stand
  (rotation 4ffd297, W1); Scout idle.

- WIPE CONFIRMED FROM MY RUN — CAMERA-MOTION READ VALIDATED (Clerk
  `c7d4be37` cross-checked my 5754c36 run directly, ~14:37Z): through
  the contentMissing phase, drawableMatched climbs LINEARLY +30/interval
  (sp180→270: 172→202→232→262) = 3D LANDS EVERY FRAME (NOT
  spectator-empty), lean3DSurvived +30 (structural blind), contentMissing
  accelerates +6/+29/+30 while contentPresent FREEZES = scene-center
  pixels CLEAR. So the 3D renders+lands every frame yet pixels read
  clear = the REAL WIPE, caught in my autogame's spectator-AUTO-SCROLL
  phase (FBO-up-as-motion proxy was right). ⇒ VERY LIKELY NO OPERATOR —
  the pin comes from my EXISTING run; the data-fit step + camera-motion
  catch turned a needless operator interruption into an already-captured
  pin. Worker confirming authoritatively (rule out spectator-empty-
  terrain confound) → then the FIX proposal. Holds stand (rotation
  4ffd297, W1); Scout idle.

- ═══ §2 PASS-TRACE = DRAW-OVER DOMINANT → REAL WIPE, NO OPERATOR, FIX
  TARGET NAMED (Foreman e9b8055 run, 2026-06-13 ~15:13Z; run-
  20260613T151153Z, pin 01281524, probe ON; extractor s25_pacing_
  extract.py) ═══
  Pre-check ✓: withLeanEncoded=210, fbo_draw boundary 65.6%/30746
  (genuine interleave). §2 CROSS-TAB (raw, as extracted): lean3D
  ContentMissing=30, contentPresent=173; contentMissingDrawOver=30,
  ...ViaPass=30, ...ViaDraw=30, contentMissingBenignSky=0,
  contentExcludedNonGameplay=4 (gate active). §1: present=85.22%
  MISSING=14.78% (sampled=203). EXTRACTOR VERDICT LINE: "DRAW-OVER
  dominant ⇒ REAL WIPE the autogame caught (NO operator); fix target =
  separate post-3D overlay PASS." Note viaPass=viaDraw=drawOver=30 (both
  classifications fire on every missing frame — Worker's
  ViaPass-not-positive-controlled caveat; I do NOT interpret, handed raw
  to Clerk+Worker). ROUTING per Clerk 849f9436: drawOver-dominant →
  Worker's FIX proposal, NO operator. The whole spectator-phase wipe
  (caught in MY autogame, no operator interruption) localizes to a
  separate post-3D overlay PASS drawing the clear color over the landed
  3D. Obs-only → no rotation/sweep. Holds stand (rotation 4ffd297, W1).

- §2 VERDICT CONFIRMED + FORWARD SEQUENCE (Clerk `1040c8b4`, ~15:15Z):
  drawOver=30 / benignSky=0 = REAL WIPE, ZERO benign-sky false-positives
  (anti-bias guard confirms genuine over-draw); contentExcludedNonGame
  play=4 = re-scoped gate working; NO OPERATOR — full spectator-phase
  wipe localized in MY autogame run. viaPass=viaDraw=30 → Worker
  resolving overlay-pass-vs-serial-draw-vs-both in the fix proposal.
  e9b8055 run STAYS AUTHORITATIVE (Worker's a93d2d5 ViaPass-control is
  test-side-only, byte-identical instrument — no restart). FORWARD:
  Worker fix proposal + survival-gate → Clerk adjudicates → my attest
  of the fix SHA + CONFORMANCE TWIN SWEEP baselined vs the 6 KNOWN
  pre-existing failures (dcr4c/d/e GS-mesh + phase-7/a/c smoke-coverage)
  + SURVIVAL-VALIDATION re-run on this autogame (fix-green = 6 known
  unchanged + no NEW P→F + spectator-phase contentMissing→0). Stand by
  for Worker's fix proposal. Holds stand (rotation 4ffd297, W1, GLTest
  re-stage); Scout idle.

- ⚠ §2 VERDICT RETRACTED — CONFOUNDED (Clerk `870981be`, ~15:23Z;
  Worker withdrew the "REAL WIPE localized" verdict): §2 is CONFOUNDED
  on this engine — the HUD/overlay pass is UNIVERSAL (Worker's
  per-interval proof: presentWithPost3DDraw≡present every interval) →
  benignSky is STRUCTURALLY UNREACHABLE → benignSky=0 was FORCED by
  frame structure, NOT evidence → drawOver≡contentMissing = ZERO
  discriminating power. The viaPass=viaDraw=30 UNIFORMITY I flagged as
  the caveat was THE TELL (Clerk credit: load-bearing instinct — flagging
  the uniformity instead of glossing it is what surfaced the confound).
  STATE: 3D-lands-every-frame still SOLID (doesn't-land dead); the
  wipe-vs-benign-sky residual is OPEN AGAIN. Worker building a TEMPORAL
  CENTER-SNAPSHOT RESOLVER (T1 = 3D-pass-close vs T2 = present, at the
  scene-center — immune to the universal-overlay confound), obs-only,
  NO operator, validated THIS time with confound-replicating controls.
  HOLD: NO fix, NO attest, NO sweep. The e9b8055 run STANDS AS DATA but
  its VERDICT IS WITHDRAWN. DO NOT prep fix attest/sweep. Stand by for
  the resolver → definitive wipe-vs-sky → then (if wipe) the fix. Holds
  stand (rotation 4ffd297, W1, GLTest re-stage); Scout idle.

- WORKER FIN — CONFOUND PROOF + RE-RUN HANDOFF (`b37dabf4`, ~15:25Z):
  the proof from MY run's own data — contentPresentWithPost3DDraw tracks
  lean3DContentPresent EXACTLY at every record (24/24, 53/53, 89/89,
  143/143, 173/173) → the post-3D overlay pass is on 100% of frames
  (present AND missing) → benignSky structurally unreachable → §2 zero
  discriminating power; my uniform viaPass=viaDraw=30 flag was exactly
  that symptom (universal edge-HUD, not a wipe-specific signal — §2
  counts post-3D activity ANYWHERE, not at-center). STILL SOLID: 3D
  lands every frame (matched 99% / survived 100%); 30/203 frames
  center==clear, clustered in the spectator/MOTION phase. OPEN:
  wipe-vs-benign-sky. HANDOFF: Worker builds the temporal center-
  snapshot resolver (T1=3D-pass-close vs T2=present at scene-center,
  overlay-CARRYING controls this time) → pings me to RE-RUN THIS SAME
  autogame on the new SHA → definitive wipe-vs-sky. I'm primed (same
  deterministic scenario, attest+run on his SHA). Holds stand.

- WINDOW-STATUS ANSWER = ON-SCREEN CAPTURABLE (Foreman, 2026-06-13
  ~15:28Z; answers Clerk `2432adc3`) — CORRECTS my earlier "headless"
  belief, which was a MISTIMED CHECK: CGWindowList shows a real WZ
  window owner='Warzone 2100', pid-matched (not the iTerm2 title
  false-positive), appearing ~2-3s into the run; the ~5s game had
  exited before my earlier single-shot checks ran → false "no window".
  Confirmed CAPTURABLE: WID=6083 → screencapture -l → 2560×1504 PNG
  (157KB) of the WZ window. So Clerk's ON-SCREEN branch applies (NOT the
  headless drawable-save fallback). currentDrawable*=0 was the
  post-present-nil artifact all along, never a headless tell. CAPTURE
  APPROACH coordinating with Worker: screencapture-burst bucketed
  gameplay(pre-displayGameOver)/spectator(post) by the stderr game-over
  timestamp → present-phase image vs missing/spectator-phase image →
  eyeball wipe-vs-sky; OR Worker's drawable-image-SAVE §1 extension for
  exact §1-tag correlation (JSONL is 30-frame interval, so exact
  per-frame tagging isn't in my reach for capture-timing). NOT reading
  PNGs mid-flow ([[no_image_read_midflow]]) — capture + hand to
  Worker/operator, or peek at end-of-turn. No fix/attest/sweep until the
  visual resolves wipe-vs-sky; e9b8055 §2 verdict stays withdrawn. Holds
  stand (rotation 4ffd297, W1).

- SCREENCAPTURE BURST DONE + WIPE INTERMITTENCY FINDING (Foreman,
  2026-06-13 ~15:36Z; Clerk greenlit screencapture as preferred
  eyeball artifact, Worker `1061c4ad` = do BOTH A-screencapture +
  B-counter): ⚠ THE AUTOGAME WIPE IS INTERMITTENT — refutes Worker's
  "deterministic → same frames": burst attempt-1 max contentMissing=0
  (NO wipe), attempt-2 contentMissing=6 (WIPE). Also the 151153Z run was
  cMISS=30. So the spectator-auto-scroll wipe manifests ~probabilistic-
  ally and BRIEFLY (6-30 frames ≈ 0.1-0.5s, ~3-15% of frames), much
  briefer than the operator's "blue most of the time". Kept the wipe run
  visb-a2-153554Z (cMISS=6 @ sp240). Captures bucketed by game-over
  epoch: GAMEPLAY (cap-014-019, pre-displayGameOver, present) vs
  SPECTATOR (cap-020-023, post-game-over, in the wipe window). Handoff
  set /tmp/wz-wipe-handoff/ (GAMEPLAY-present-A/B + SPECTATOR-candidate-
  1..4). OBJECTIVE FILE-SIZE OBSERVATION (no pixel-read): gameplay PNGs
  ~5.5MB (detailed 3D) vs spectator ~86KB (candidates 2/3/4 byte-
  IDENTICAL = static uniform screen) → consistent with the scene-center
  going uniform/blue in the spectator phase, BUT wipe(bug) vs game-over-
  MENU(expected) vs benign-SKY needs the eye + B's T1-snapshot. CAVEAT:
  screencapture is async/coarse vs a brief 6-frame wipe → may not land
  on a wiped frame; B's per-frame counter is the RELIABLE arbiter, my
  screencapture the visual complement. Handed Worker for the eye call
  (NOT reading PNGs mid-orchestration). Ready for B SHA re-run. Holds
  stand (rotation 4ffd297, W1).

- INTERMITTENCY ACCEPTED → METHODOLOGY CHANGE (Clerk `5c7c0a72`,
  ~15:40Z): per-run cMISS>0 VERIFICATION now MANDATORY before any
  verdict (mine or Worker's B); deterministic-same-frames is OUT.
  B-primary / screencapture-complement weighting confirmed (B's
  per-frame counter catches a brief 6-frame wipe a coarse async burst
  would miss; screencapture = eyeball on a CONFIRMED-wipe run). File-
  size signal (spectator ~86KB uniform vs gameplay ~5.5MB detailed) =
  strong objective corroborator that the center goes uniform. MECHANISM-
  MATCH (Clerk flagging to Worker, my awareness): the autogame wipe
  (~3-15%, brief) is FAR briefer than the operator's "most of the time"
  — LIKELY the SAME mechanism at different motion-intensity (operator's
  manual pan more continuous than spectator auto-scroll → higher rate),
  but Worker ASSESSES the mechanism-match (load-bearing: if same
  mechanism, fixing the autogame wipe fixes the operator's; if
  different, the autogame catch ≠ the operator's bug). STAND BY: Worker
  runs B on a cMISS>0-verified run + the eye call → the verdict. (I
  execute the autogame B-run when Worker ships the SHA per his
  `1061c4ad` "re-run this same autogame on the B SHA"; confirm who-runs
  on SHA arrival.) Holds stand (rotation 4ffd297, W1); Scout idle.

- ═══ §3 TEMPORAL RESOLVER = BENIGN SKY (HYPOTHESIS REVERSED — autogame
  does NOT reproduce the operator's wipe) (Foreman, 2026-06-13 ~15:46Z;
  pin 242E68AA, 6a5fd6b, probe ON; extractor §3 authoritative) ═══
  Ran the run-until-wipe loop (8 runs: 5 wiped cMISS 32-88, 3 cMISS=0 —
  intermittency reconfirmed). §3 (confound-FREE: center pixel at T1
  3D-pass-close-before-overlay vs T2 present; immune to the universal-
  overlay confound that killed §2) verdict ACROSS ALL 5 VERIFIED-WIPE
  RUNS: WIPE=0, SKY=100% (32/32, 56/56, 42/42, 88/88, 78/78 all SKY,
  ZERO wipe, ZERO T1-unavailable). DEFINITIVE + ROBUST. MEANING: the
  autogame's spectator-phase contentMissing is BENIGN SKY — T1 already
  clear ⇒ the 3D NEVER drew the scene-center (spectator auto-scroll
  camera pointed at sky/empty terrain) ⇒ legitimately clear, NOT a
  draw-over wipe. §1 contentMissing (real) + §2 drawOver (confounded)
  were FALSE LEADS; §3 resolves it. ⇒ GENUINE REOPEN: the autogame does
  NOT reproduce the operator's wipe (real: T1 nonclear→T2 clear). The
  whole "spectator-phase wipe caught in my autogame" line is REFUTED by
  §3 — it was benign sky all along. NO fix from autogame data (nothing
  to fix — it's not the bug). The operator's defect is ELSEWHERE; my
  autogame's center-clear ≠ their wipe. LIKELY NEXT: operator on-screen
  §3 run (manual pan → the real "most frames" wipe under the confound-
  free resolver) — autogame can't pan, so it can't produce the real
  wipe. Routed §3 split to Worker (verdict) + Clerk (reopen). Holds
  stand (rotation 4ffd297, W1).

- ON-SCREEN §3 OPERATOR WRAPPER CUT + DRY-VERIFIED (Clerk `1a2ffb05`,
  ~15:51Z: operator on-screen §3 run now NECESSARY + definitive — the
  autogame can't pan so can't produce the real wipe; only operator
  manual-pan reproduces "blue most of the time", §3 classifies it
  confound-free). Wrapper launch-warzone-appgl-6a5fd6b-onscreen-s3.sh:
  --window, manual-play pass-through (no autogame), §3 latch =
  APPGL_W2_SURVIVAL_CONTENT_PROBE=1 (activates §1+§2+§3, NO separate
  flag — single env latch confirmed), PARALLEL_ENCODE=1, obs-only,
  Studio, header tells operator: short skirmish ~1-2min PAN CAMERA
  CONTINUOUSLY. DRY-VERIFY PASSED: §3 section ARMS on-screen + emits all
  keys in the JSONL (lean3DContentMissing + contentMissingWipeConfirmed/
  SkyConfirmed/T1Unavailable present; no wipe needed for the arm-check).
  Pin 242E68AA sidecar-verified; 6a5fd6b attested full-protocol
  (SHA256 859d2f0c…). Launch line handed to Clerk → operator. NO fix
  until the operator §3 run classifies the REAL defect (WIPE vs SKY).
  Holds stand (rotation 4ffd297, W1).

- 01f11c8 EYEBALL: (A) OPERATOR WRAPPER READY + (B) INJECTION FEASIBILITY
  (Worker `a94bd89f` ships 01f11c8 = §3 + T1|T2 PNG eyeball on first
  confirmed-wipe frame; Clerk `aa00bdbd` = A immediate + B parallel for
  the no-operator fix-validation loop):
  (A) ATTESTED + WRAPPER READY: pin libAppGL-01f11c8-preview-96151D5D
  (SHA256 43cb90af…), canonical held 4ffd297. Wrapper
  launch-warzone-appgl-01f11c8-onscreen-s3.sh (--window manual-play,
  APPGL_W2_SURVIVAL_CONTENT_PROBE=1 + APPGL_W2_SURVIVAL_IMAGE_DIR=
  $RUN/wipe-images for the eyeball, PARALLEL_ENCODE=1, obs-only, Studio,
  pan-continuously header). DRY-VERIFY PASSED: §3 emits + image-dir
  created; the autogame dry-launch hit cMISS=83 but wipeConfirmed=0
  (all SKY) → NO PNG saved (eyeball correctly inert without a real wipe;
  re-corroborates benign-sky). Launch line → Clerk → operator =
  authoritative capture of the real defect.
  (B) INJECTION: PERMISSION GRANTED (AXIsProcessTrusted=TRUE, CGEvent
  synth works, osascript System Events ran clean — Accessibility is
  granted to my context, separate from Screen Recording). BUT FUNCTIONAL
  UNCONFIRMED: first attempt (CGEventPostToPid arrow keys ×150 to live
  autogame) showed NO camera-pan effect — fbo/frame stayed ~115 (==
  no-inject baseline), cMISS=0. Likely needs WZ-FOCUS + session-level
  CGEventPost (SDL reads the focused-app stream, not per-pid), or
  edge-scroll, or autogame ignores camera input. → B is permission-ready
  but needs functional iteration; valuable for the no-operator
  fix-validation loop, NOT yet a capture path. A NOT blocked on B. Holds
  stand (rotation 4ffd297, W1).

- A DISPATCHED TO OPERATOR + B-HELD-FOR-COLLISION (Clerk `e6d1f894` +
  Worker `1d9d9310`, ~16:00Z): A-wrapper on 01f11c8 CONFIRMED good
  (the dry-verify benign-sky/no-PNG = real-environment instrument-
  integrity proof: §3 doesn't false-fire → an operator WIPE will be
  trustworthy); Clerk DISPATCHED the operator now. Worker's B technique:
  (1) CGEventPost(kCGSessionEventTap/kCGHIDEventTap) with WZ made
  FRONTMOST first (NSRunningApplication activate / osascript activate) —
  CGEventPostToPid bypasses SDL's focused-app grab (= why my inject
  moved nothing); (2) SUSTAINED key-hold (keyDown→hold 0.5-1s→keyUp,
  repeat) for continuous motion — a single tap won't reproduce the
  motion-dependent wipe; check wipeConfirmed specifically (cMISS alone
  can be all-SKY). ⚠ FOREMAN B-HOLD (collision avoidance, surfaced to
  Clerk): B's focus-steal + SESSION-LEVEL key/mouse injection is
  SYSTEM-WIDE — running it WHILE the operator does the live A capture
  would hijack their focus/keyboard/mouse mid-run. So B's functional
  iteration HOLDS until the operator A capture completes; then I apply
  Worker's focus+session-tap+sustained-hold technique. Stand by for the
  operator §3 split + eyeball → Worker verdict (WIPE→fix proposal;
  SKY-under-pan→deeper reopen). Holds stand (rotation 4ffd297, W1).

- B HARD RULE + PREPPED (Clerk `be8fa56e`, ~16:03Z): ⛔ HARD RULE — do
  NOT EXECUTE B injection until Clerk's EXPLICIT signal; the operator
  must confirm A complete AND cede the machine (B takes over input
  system-wide → needs a coordinated machine-free-for-automation window
  Clerk sets up post-A). PREP is allowed. PREPPED + COMPILED (NOT
  FIRED): /tmp/wzpan2 = focus WZ frontmost (NSRunningApplication.
  activate) → session-level CGEventPost(.cgSessionEventTap) sustained
  arrow pans (keyDown→HOLD 0.7s→keyUp, alternating L/R/U/D for
  continuous motion — the motion-dependent wipe needs sustained scroll,
  not taps). FIRE SEQUENCE (on signal): launch 01f11c8 onscreen wrapper
  +--autogame + IMAGE_DIR → get WZ pid → /tmp/wzpan2 <pid> <secs> →
  extract §3, verify cMISS>0 AND wipeConfirmed>0 specifically (autogame
  cMISS is all-SKY) → ship WIPE/SKY split + PPM. Awaiting Clerk's
  machine-free signal. Stand by for the operator A §3 split + eyeball.
  Holds stand (rotation 4ffd297, W1).

- ═══ OPERATOR §3 REPRODUCED + AUTOGAME MATCHES (state-corruption, NOT
  benign sky) — DIAGNOSIS RE-OPENS UP (Clerk `2956c842` operator run +
  Foreman corroboration, 2026-06-13 ~16:11Z) ═══
  OPERATOR RUN (s25-s3-onscreen-eyeball/20260613T160214Z): reproduced
  real + HIGH-RATE — clean first ~1320 presents, then PERSISTENT onset
  ~sp1350 (contentMissing→6907/81%, contentPresent FROZEN). §3 =
  wipeConfirmed=0 / skyConfirmed=6907 → NOT a draw-over; the 3D STOPS
  filling the scene-center after a pan-triggered STATE TRANSITION. The
  PERSISTENCE says STATE CORRUPTION, not benign — §3's center-only
  "sky" is AMBIGUOUS (benign-empty vs 3D-renders-WRONG-PLACE).
  FOREMAN CORROBORATION (data, not just hypothesis): my 3 autogame
  §3-"sky" runs show the IDENTICAL persistent-freeze — contentPresent
  grows clean then FREEZES PERMANENTLY after a motion-triggered onset
  (154459Z froze@235 miss→88; 154438Z@157 miss→78; 154520Z@119 miss→87),
  contentMissing accumulating, NEVER recovers. Benign sky would let
  present keep growing (camera pans back); frozen = corruption. ⇒ MY
  AUTOGAME REPRODUCES THE OPERATOR'S DEFECT (via the spectator
  auto-scroll transition) — the earlier "benign sky / autogame doesn't
  reproduce" §3 verdict is REVISED: §3's coarse sky-label mislabeled the
  SAME state corruption. CONSEQUENCE: NO operator needed for the repro,
  NO B-injection needed for the basic case — Worker's SPATIAL/full-frame
  probe (where is the 3D on a degraded frame: benign-empty vs
  wrong-place) RUNS ON MY AUTOGAME directly (run-until-freeze, ~60%).
  B-injection (HELD for Clerk's machine-free signal) extends repro to
  ACTIVE-gameplay context closer to the operator, not required for the
  spatial localization. Routed to Worker (spatial-probe SHA → I run on
  autogame) + Clerk. No fix/attest/sweep. Holds stand (rotation
  4ffd297, W1).

- CONFIRMED — NO OPERATOR FROM HERE + B PARKED (Clerk `7bb2993a`,
  ~16:15Z): freeze-PERMANENCE discriminator credited as the sharp
  insight (benign-sky RECOVERS when camera pans back to terrain;
  corruption PERSISTS, never recovers). My autogame REPRODUCES the
  operator's defect (spectator-auto-scroll transition); earlier
  benign-sky verdict CORRECTED (§3 center-only "sky" conflated
  benign-empty with persistent-corruption; permanence separates them).
  ⇒ NO OPERATOR needed from here — the autogame carries BOTH the spatial
  probe AND eventual fix-validation. B keystroke-injection KEPT HELD +
  DE-PRIORITIZED (NOT needed — the autogame's own transition triggers
  the freeze; only for later active-gameplay fix-validation, machine-
  free window arranged THEN; NO signal needed now; operator RELEASED).
  NEXT: Worker's spatial/full-frame probe (where is the 3D on a degraded
  frame: benign-empty vs renders-wrong-place) → I run on the autogame
  (run-until-freeze ~60%) → report. Stand by for the spatial-probe SHA.
  Holds stand (rotation 4ffd297, W1); Scout idle.

- PARALLEL ON/OFF (§3-CIRCULAR) + PERSISTENCE (Worker asks 1+3, Clerk
  `aa4d600c`/`a956741b`, ~16:24Z):
  ASK 3 FAULT-ASSIGNMENT = §3-INCONCLUSIVE/CIRCULAR (Clerk concurred, my
  catch): ARM-1 PARALLEL_ENCODE=1 freezes (confirmed); ARM-2 serial
  (PARALLEL_ENCODE=0) 6/6 → withLeanEncoded=0 → §3 (lean-path-only)
  measures NOTHING → "no-freeze-serial" is TRUE-BY-CONSTRUCTION, NOT
  evidence the serial RENDERING is clean. History (a9ccea4 hover-clean =
  serial-3D; freeze on W2.1-lineage = lean-3D) is suggestive-of-W2 but
  NOT proof. ⇒ DEFER fault-assignment to the FULL-FRAME spatial probe
  run PARALLEL vs SERIAL — REQUIREMENT (me + Clerk flagged to Worker):
  the probe's TRIGGER AND read must both be LEAN-AGNOSTIC (read the
  drawable, not gated on §3-saw-missing) or the serial arm reads empty
  the same way. serial-full-frame-CLEAN ⇒ W2-lean-fault; serial-ALSO-
  freezes ⇒ pre-existing bug W2.1 merely exposed.
  ASK 1 PERSISTENCE = PERMANENT (not a blip) WITHIN SCOPE: both
  verified-freeze runs → contentPresent peaks at onset then NEVER grows
  again (154459Z peak=236@rec12/13; 154438Z peak=158@rec8/10) = permanent
  freeze, never recovers (a blip would recover). BUT autogame CAPS
  ~300-360 presents (player-elimination game-over) → can't reach
  operator-scale sp1000+ from the spectator-phase freeze; that needs
  ACTIVE-gameplay (B-injection, parked) or a survival-config (offered
  Worker). Stand by for the lean-agnostic spatial-probe SHA. Holds
  stand (rotation 4ffd297, W1); Scout idle.

- ASK 1 RESOLVED + §4 LEAN-AGNOSTIC CONFIRMED (Worker `32da8090`/
  `89a2e854`, ~16:26Z): ask-1 = go (b), DON'T burn a survival config —
  persistence is established TWO ways: (1) my within-window permanence
  (present peaks at onset, NEVER recovers — a blip would resume), (2)
  the OPERATOR's own run already ran 7000+ frames frozen (sp1350→8520)
  = operator-scale ALREADY confirmed. Park operator-scale-active-gameplay
  for B-injection if ever needed. §4 REDESIGN CONFIRMED lean-agnostic
  (my catch + Clerk spec): §4's TRIGGER = an always-on drawable-center
  census every GAMEPLAY frame (fboDrawsSincePresent≥threshold, lean-
  INDEPENDENT — counts all FBO draws serial+parallel, excludes 2D menu),
  NOT gated on the §3 lean-missing flag; §4 sets its OWN saw-degraded
  flag from its own center-read → full-readback + grid fire in SERIAL
  too. Counters spatialPresentFrames vs spatialDegradedFrames = the
  parallel-vs-serial fault test directly (serial freezes ⇒ general/
  pre-existing; serial clean ⇒ W2-lean-fault). Worker building +
  validating (controls + matrix) → commit → ship SHA + counter names.
  Canonical re-verified 4ffd297 (9d3f05fb); no stray WZ. STAND BY for
  the §4 SHA → attest + run parallel-vs-serial run-until-freeze →
  report spatialPresent/Degraded + frozenGridInner/Total + PPM. Holds
  stand (rotation 4ffd297, W1); Scout idle.

- ═══ §4 SPATIAL = FAULT + WHERE PINNED — W2-LEAN-PATH / 3D-RENDERS-
  NOWHERE (Foreman, 2026-06-13 ~16:42Z; 2a7ffe8 pin 711D0FDC, lean-
  agnostic; extractor §4) ═══
  FAULT = W2 LEAN-PATH (W2.1 regression), DEFINITIVE: PARALLEL run-
  until-freeze (par-a4 froze) spatialPresentFrames=129 FROZEN /
  spatialDegradedFrames=76 (37%); SERIAL 8/8 runs spatialPresent climbs
  204-236 / spatialDegraded=0 / NEVER freezes. §4 is lean-AGNOSTIC
  (measured serial directly, non-circular unlike §3) → serial-3D-CLEAN +
  parallel-3D-FREEZES ⇒ the W2 parallel/lean-encode path IS the cause,
  NOT pre-existing (8/8 serial-clean = strong null). IN W2 SCOPE.
  WHERE = NOWHERE: frozenGridInner=0 / frozenGridTotal=80 of 256. The
  16×16 frozenGridMap (objective counter data, NOT a pixel-read): top
  HUD bar (rows1-2) + bottom/edge HUD panels non-clear, but the SCENE-
  CENTER (rows3-8 + central cols) ENTIRELY CLEAR → the lean-3D renders
  NOWHERE in the viewport while the 2D HUD renders fine ⇒ stale/wrong
  TARGET or null/wrong plan/descriptor for the lean-3D draws, set-once-
  wrong after the motion-state-transition (HUD/2D unaffected = consistent
  with serial-clean). Full-frame PPM (2560×1440) handed to Worker for
  the eye-call (pixels NOT read by me). ⇒ FIX SCOPE PINNED: a W2.1
  lean-path state (target/plan/descriptor) set wrong on the motion
  transition. Worker localizes the set-once-wrong state → FIX PROPOSAL.
  No fix yet. Run data: memory-runs/s25-spatial-{par,ser}/. Holds stand
  (rotation 4ffd297, W1); Scout idle.

- §4 ACCEPTED + FIX-VALIDATION ROLE (Clerk `c90827c2`, ~16:44Z): FAULT=
  W2.1-lean-path (in-scope) + WHERE=NOWHERE (stale/wrong target or
  null/wrong plan/descriptor, NOT off-center) accepted as the clean
  definitive pin; discipline credited (frozenGridMap-as-objective-data +
  PPM-to-Worker-unread). FIX SCOPE: a W2.1 lean-path state set-once-wrong
  on the motion transition; Worker localizing the exact state → fix
  proposal → Clerk adjudication. ⭐ MY §4-AUTOGAME = the NO-OPERATOR
  FIX-VALIDATION GATE: post-fix → §4 PARALLEL run-until-freeze →
  spatialDegradedFrames→0 = freeze ELIMINATED. KEEP §4 (2a7ffe8 / pin
  711D0FDC + wrappers launch-warzone-appgl-2a7ffe8-{par,ser}.sh) READY.
  FORWARD on Clerk's fix-go (after Worker localize + fix proposal +
  Clerk adjudicate): I attest the FIX SHA + conformance TWIN SWEEP
  (baselined vs the 6 known pre-existing failures) + §4-VALIDATION
  re-run on the autogame (spatialDegraded→0) + eventual operator
  generalization run. No fix yet. Stand by for Worker's localization +
  fix proposal. Holds stand (rotation 4ffd297, W1); Scout idle.

- EYE-CALL CONFIRMED — ALL THREE METHODS AGREE (Worker FIN `3ba84ddb`,
  ~16:45Z): Worker converted+read the PPM — the HUD renders PERFECTLY
  (top text, settings gear, build-menu hexagons, Unit-Groups bar,
  resource counter 4680, AND the MINIMAP showing actual terrain + unit
  dots) while the entire main 3D VIEWPORT is BLANK (dark clear). THE
  CLINCHER: the minimap proving the WORLD EXISTS while the viewport is
  empty ⇒ the lean-3D SCENE render produces nothing in the viewport;
  the 2D/HUD/minimap paths are fine. Matches frozenGridInner=0 + the
  grid map exactly. NOWHERE confirmed VISUALLY + OBJECTIVELY (grid) +
  the serial 8/8 null (counter) = W2-lean-path — unimpeachable after the
  two earlier confounds. FAULT=W2.1 lean-path, WHERE=nowhere, ALL THREE
  (counter + grid + eyeball) AGREE. Worker localizing the set-once-wrong
  target/plan/descriptor in the lean path → fix proposal to Clerk
  (design-before-code). My §4 parallel run-until-freeze
  (spatialDegradedFrames→0) = the no-operator fix-validation gate;
  Worker hands me the fixed SHA to gate-run. STAND BY for the fix
  proposal. Holds stand (rotation 4ffd297, W1); Scout idle.

- ═══ §5 BATCH-PASS-STATE = (b) CLEAR-TIMING — MECHANISM PINNED, S24-
  FLICKER PARALLEL ANALOGUE (Foreman, 2026-06-13 ~17:25Z; 867da59 pin
  30845158; extractor §5) ═══
  SANITY-CHECK PASSED (Worker+Clerk load-bearing gate): every freeze run
  has degraded/presentBatchFlushes NON-ZERO (degraded 6-432, present
  307-759) → the worker batch (buildDefaultParallelRenderPass flush) IS
  the exercised path → verdict trustworthy. ROBUST across 7 freeze runs
  (degraded-frame counts 2-140), split DEAD-CONSISTENT: degraded color-
  CLEAR rate ~0.32 vs present ~0.00; degraded depth-LOAD ~0.67 vs present
  ~1.00. VERDICT: (b) CLEAR-TIMING — degraded frames read a HIGHER
  color-CLEAR loadAction rate ⇒ a late parallel batch CLEARS the 3D
  away. NOT (a) depth-discard (degraded depth-LOADS LESS, not more —
  ~1/3 color-clear+depth-clear instead of load). = the S24-FLICKER
  PARALLEL-BATCH ANALOGUE → closes the loop on the FIRST lead I flagged
  this arc (the a9ccea4 frame-semantic-clear CLASS): right class at the
  root, just needed full localization to land on the batch-clear-timing
  sub-axis (not landing/survival/draw-over). FIX DIRECTION: port
  a9ccea4's frame-boundary-clear discipline to the parallel batch (a
  late worker-batch flush must NOT re-clear color on a frame that
  already rendered 3D). ═ FULL DIAGNOSIS COMPLETE: FAULT=W2.1-lean-path
  → WHERE=nowhere → WHY=(b) batch clear-timing ═. Worker → fix proposal
  (design-before-code) → Clerk adjudicate. My §4 parallel
  run-until-freeze (spatialDegraded→0) stays the no-operator
  fix-validation gate. No fix yet. Run data memory-runs/s25-batchstate/.
  Stand by for Worker's fix proposal. Holds stand (rotation 4ffd297,
  W1); Scout idle.

- DIAGNOSIS COMPLETE — ACCEPTED + FIX BEING DESIGNED (Worker FIN
  `686a827a` + Clerk `f7993149`, ~17:23Z): §5 (b) CLEAR-TIMING accepted
  (sanity-gate + 7-run dead-consistent split = airtight). FULL CHAIN:
  FAULT=W2.1-lean → WHERE=nowhere → WHY=(b) late-batch-color-reclear =
  the a9ccea4 frame-semantic-clear CLASS, parallel-batch analogue. Five
  instruments (§1-§5) + eyeball; every hypothesis evidence-killed; two
  self-corrections caught by the empirical gate (the fbo-high drop
  false-lead, the benign-sky relabel). MY FIRST LEAD this arc (a9ccea4/
  S24-flicker class) CREDITED as the right root class all along — the
  full localization just had to land on the batch-clear-timing sub-axis.
  Worker designing the fix: port a9ccea4's frame-boundary-clear
  discipline to the parallel worker batch (a late batch flush must NOT
  re-apply loadAction=Clear on a frame that already rendered 3D — clear
  ONCE per frame, not per-batch); investigating the hasPendingClear
  lifecycle + the a9ccea4 serial-path fix → exact re-clear site →
  design-before-code proposal to Clerk. ⭐ REFINED SURVIVAL-GATE (my
  role): §4 spatialDegradedFrames→0 on the parallel run-until-freeze
  AND NO serialFallback spike (draws must stay PARALLEL = W2.1 win
  preserved; a serial-fallback "fix" would mask the freeze but lose the
  win). FORWARD: Worker proposal → Clerk adjudicate → Clerk dispatches
  my ATTEST + §4-VALIDATION + conformance TWIN-SWEEP (vs the 6
  pre-existing) → OPERATOR GENERALIZATION (final). No fix yet. Stand by
  for Worker's proposal. Holds stand (rotation 4ffd297, W1); Scout idle.

- §5.1 INCOMING — FINAL DISCRIMINATOR + FIX-SITE (Clerk `8249e0b4`,
  ~17:31Z): Worker building §5.1 before the fix — closes a potential
  3RD CONFOUND: confirms the color-clear lands AFTER the 3D rendered
  THIS frame (the real wipe signature) vs a benign FRAME-START clear
  (which §5's color-clear RATE alone can't separate) + captures the
  INTERPOSER (2nd glClear / FBO-return / flush-boundary) = the EXACT
  FIX SITE. I run it on the autogame frozen repro, SAME §5 discipline:
  non-zero-batchFlushes sanity-check FIRST → run-until-freeze → read
  degraded-vs-present clear-AFTER-3D. Closes the confound + names the
  fix site → Worker's precise fix code → Clerk approval → dispatch my
  attest + §4-validation + conformance-sweep. (Rigor holds: even with
  §5 pinning (b), Worker adds §5.1 rather than over-reading the rate.)
  Stand by for the §5.1 SHA. Holds stand (rotation 4ffd297, W1); Scout
  idle.

- ═══ §5.1 WIPE-ORDERING = §5 WAS A CONFOUND — (b) CLEAR-TIMING REFUTED,
  3RD CONFOUND CAUGHT (Foreman, 2026-06-13 ~17:45Z; 7099b71 pin
  04B63E47; extractor §5.1) ═══
  SANITY PASSED every freeze run (batch-flushes non-zero). ROBUST across
  5 freeze runs (spatialDegraded 3-118): degradedBatchClearAfter3D=0 =
  presentBatchClearAfter3D=0 EVERY run — NO batch clears color AFTER a
  prior batch rendered 3D this frame. INTERPOSER FLAT: encodeClears/
  frame=1.00 deg/1.00 pres (one clear/frame, NO 2nd mid-frame glClear
  re-arm); midFrameCommits=0 both (NO frame-split). ⇒ §5's degraded
  color-clear rate (~0.32) was BENIGN FRAME-START clears (before any 3D
  this frame), NOT after-3D wipes — exactly the first-pass confound
  §5.1 was built to catch. THE CLEAR-TIMING IS NOT THE MECHANISM;
  a9ccea4-clear-discipline is the WRONG fix (do NOT fix the clear).
  MECHANISM REOPENS: FAULT=W2.1-lean + WHERE=nowhere STILL STAND, only
  WHY changes — real direction = the WHERE verdict's "stale/wrong TARGET
  or null/wrong plan/descriptor": the lean-3D draws DON'T REACH the
  drawable viewport (never drawn there, NOT cleared-away). The §5
  color-clear correlation = downstream symptom, not cause. Worker
  re-examines the lean batch's render TARGET/plan/descriptor on a
  degraded frame. ═ 3RD SELF-CORRECTION caught by the empirical gate
  this arc (after the fbo-high drop false-lead + the benign-sky relabel)
  — the discipline holding (a wrong a9ccea4-clear fix would have shipped
  otherwise). ═ No fix yet. Run data memory-runs/s25-wipeorder/. Stand
  by for Worker's next probe. Holds stand (rotation 4ffd297, W1); Scout
  idle.

- REFUTATION ACCEPTED + REDIRECT REFINED → OUTPUT-SUPPRESSION (Worker
  FIN `e6f91709` + Clerk `4a7f6fa8`, ~17:43Z): §5.1 refutation accepted,
  clear-timing DEAD, "3rd self-correction" framing confirmed. KEY: my
  midFrameCommits=0 finding is a strong POSITIVE — the drawable is
  STABLE within a frame (no mid-frame advance/split), the batch renders
  to currentDrawable.texture = the SAME currentDrawable present presents
  (usesOffscreenTarget=false) → the TARGET POINTER is correct + stable
  → NOT target-divergence. Combined with draws-ENCODE (descriptorEncoded
  climbs) + nothing-clears (§5.1) ⇒ the lean-3D draws HIT the right
  drawable but PRODUCE NO PIXELS = OUTPUT-SUPPRESSION. TWO candidate
  sub-mechanisms: (Worker) per-fragment DISCARD (depth/stencil/PSO-
  state); DEPTH leading = a parallel-batch depth hazard (child encoders
  sharing the depth attachment, or stale/wrong depth state discarding
  the new fragments) — the (a) depth axis §5's loadActions only
  HALF-ruled-out (loadAction ≠ depth CONTENTS). (Clerk) WRONG non-null
  PSO/plan from W2.1's content-key/MSL-identity approximation for the
  post-pan cache-MISS draws (the pre-registered verifyMismatches
  suspect) — encodes but renders nothing. Worker designing the
  discriminator: on a degraded frame, capture depth has-geometry-vs-
  all-cleared + depth-test disposition (depth-discard) AND/OR the
  encoded PSO/plan + verifyMismatches (wrong-PSO), degraded-vs-present.
  STAND BY for the next probe SHA → same autogame-frozen run-until-freeze
  + non-zero-batchFlush sanity-check discipline. No fix yet. Holds stand
  (rotation 4ffd297, W1); Scout idle.

- §6 INCOMING — WRONG-PLAN TEST (Clerk `1d68fab7`, ~17:47Z): Worker
  building §6, the wrong-PLAN discriminator via the EXISTING
  APPGL_W2_PLAN_VERIFY instrument (rebuilds-and-compares plans on cache
  HIT). HYPOTHESIS (Clerk's output-suppression candidate): recordPlan
  IdentityKey approximates the plan key by MSL POINTER+SIZE → a
  post-pan cache-MISS MSL string ALIASES an evicted draw's key →
  COLLISION → cache serves the OLD WRONG plan/PSO → encodes but renders
  nothing → NOWHERE. RUN: autogame FROZEN repro, BOTH env
  APPGL_W2_PLAN_VERIFY=1 + APPGL_W2_SURVIVAL_CONTENT_PROBE=1, SAME
  discipline (non-zero batch-flushes sanity FIRST; run-until-freeze).
  VERDICT: degraded verifyMismatches ≫ present (≫0) ⇒ WRONG-PLAN
  CONFIRMED → fix = content-hash key; degraded≈0 ⇒ plans correct →
  PIVOT to the child-encoder/DEPTH ALT (Worker's candidate). So §6
  discriminates Clerk-wrong-PLAN vs Worker-depth-discard. Stand by for
  the §6 SHA. No fix yet. Holds stand (rotation 4ffd297, W1); Scout
  idle.

- ═══ §6 WRONG-PLAN = RULED OUT → PIVOT TO CHILD-ENCODER SHARED-STATE
  (Foreman, 2026-06-13 ~17:58Z; SHA UPDATED d0a7511→5af756d [adds
  verifyChecks latch-engagement proof, Clerk's ask]; pin 34E68D81) ═══
  3 VALUES (authoritative): (1) verifyChecks = 22562-36144 across runs
  = LATCH DEFINITIVELY ENGAGED (the verify rebuilt+compared plans tens
  of thousands of times — NOT a non-engaged false-negative; my d0a7511
  pre-run already showed env-proof + ~22% fewer-frames perf-cost, now
  the direct counter confirms). (2) degraded verifyMismatches = 0 =
  present = 0, EVERY freeze run (5af756d sd 1-88 + d0a7511 pre-runs sd
  29-141). (3) per-frame mismatch count = 0/frame. VERDICT: latch-
  engaged + verifyMismatches≈0 ⇒ the cached plans are CORRECT ⇒ NOT a
  wrong-plan ⇒ PIVOT to the child-encoder shared-state-application ALT.
  ⇒ Clerk's pre-registered MSL-identity-collision suspect is DEAD (cache
  serves CORRECT plans, verified tens of thousands of times). The
  "whole-scene-gone" is NOT a per-draw wrong-PSO — it fits a single
  WRONG SHARED STATE (depth/stencil/child-encoder) that wipes ALL the
  parallel-batch draws at once. CHAIN NOW: FAULT=W2.1-lean → WHERE=
  nowhere → NOT-cleared (§5.1) → CORRECT-plans + stable-target (§6) ⇒
  output-suppression via a shared child-encoder/depth state. Worker
  pivots to the depth-contents/shared-encoder-state probe. (4th candidate
  eliminated cleanly — wrong-plan; leading hypothesis = Worker's
  per-fragment-discard/shared-state.) No fix yet. Run data memory-runs/
  s25-wrongplan2/. Stand by for Worker's next probe SHA. Holds stand
  (rotation 4ffd297, W1); Scout idle.

- §6 ACCEPTED + PIVOT CONFIRMED → SHARED-STATE (Clerk `a90b9ad4`,
  ~18:01Z): wrong-plan RULED OUT authoritative; the latch-engagement
  proof (22k-36k verifyChecks) = a REAL null, not a false-negative —
  Clerk credits adding the latch-proof as closing the exact confound
  hole. MSL-collision suspect DEAD. PIVOT ACCEPTED → child-encoder
  SHARED-STATE-application. CHAIN STANDS: FAULT=W2.1-lean → WHERE=nowhere
  → NOT-dropped (per-interval) → NOT-cleared (§5.1) → plans-CORRECT (§6)
  ⇒ output-suppression via a WRONG SHARED STATE (depth-stencil /
  viewport / PSO-application to the child encoder) that wipes ALL the
  parallel-batch draws at once (fits whole-scene-gone). Worker designing
  the depth/shared-state probe → I run it autogame-frozen + same
  sanity-check discipline (spatialDegraded>0 + non-zero flushes + any
  new latch-engagement proof). No fix yet. Stand by for the probe SHA.
  Holds stand (rotation 4ffd297, W1); Scout idle.

- PIVOT DETAIL — DEPTH/SHARED-CHILD-ENCODER-STATE (Worker FIN
  `7ca38282`, ~18:02Z): wrong-plan DEAD; the verifyChecks guard (Clerk's
  ask, my 22k-36k engaged proof) credited again as preventing the 5th
  confound (a disengaged-latch 0). GRANULARITY (Foreman+operator): 3D-
  gone (persistent) + text-flicker (intermittent) + HUD-stable = a
  PER-PARALLEL-BATCH shared state — the 3D scene goes through the worker
  batch's CHILD ENCODERS (one wrong shared state wipes ALL its draws =
  whole-scene-gone); the HUD renders via a DIFFERENT path (stable).
  LEADING SUB-HYPOTHESES: (i) the batch's DEPTH ATTACHMENT contents/state
  wrong on degraded → all 3D fragments DEPTH-DISCARDED; (ii) a
  parallel-CHILDREN depth/state RACE (children render concurrently to
  the shared depth attachment — SERIAL has no concurrency = serial-clean
  FITS). §5's depth signal is suggestive (degraded = a batch does the
  frame-start depth-CLEAR; present = load) but loadAction ≠ CONTENTS.
  NEXT PROBE (Worker designing — DESIGN-BEFORE-BUILD to Clerk first
  after a pivot this big; TRICKIER: the depth texture is
  MTLStorageModePrivate → a direct depth readback needs a resolve/
  sample): pin whether the 3D fragments are DEPTH-DISCARDED (depth
  all-at-cleared = no 3D depth written = discarded) vs
  depth-written-but-no-color. Ships me the SHA when ready → I run
  autogame-frozen + same sanity discipline. No fix yet. Stand by for the
  probe SHA. Holds stand (rotation 4ffd297, W1); Scout idle.

- §7 INCOMING — CHILD-ENCODER APPLIED-STATE probe (Clerk `db13a867`,
  ~18:04Z): Worker building §7 (the pivot target — applied-state on the
  parallel batch's child encoder). PRIME SUSPECT: leanScissorDegenerate
  — the SCISSOR rect computing to a degenerate 1×1 corner (a Y-FLIP-vs-
  RENDER-TARGET-HEIGHT going wrong → finalW/H≤0 → ALL 3D fragments
  scissored OUT → NOWHERE, identical across every draw = whole-scene-
  gone). Also captures leanViewportUnset/tiny + leanDepthStateNull +
  the RAW scissor/viewport/rtH values on a sample degraded draw
  (confirm + inform the fix). PSO already ruled out (§5/§6). RUN:
  autogame FROZEN repro, SAME discipline (non-zero batch-flush sanity
  + run-until-freeze + degraded-vs-present). VERDICT: degraded ≫ present
  on ONE counter = the wrong applied-state; leanScissorDegenerate +
  raw-values-show-1×1 ⇒ CONFIRMED → the fix site (the scissor Y-flip/rtH
  derivation). (Note: prime suspect is SCISSOR, not depth — §7 captures
  scissor+viewport+depth-state so it discriminates among them.) Stand by
  for the §7 SHA. Holds stand (rotation 4ffd297, W1); Scout idle.

- ⭐ RUNG-2 OPERATOR GO (Clerk `83c1158b`, 2026-06-13 ~00:21Z; verbatim
  "Reviewed. We're looking good. Let's GO.") on the adjudicated scoping
  memo with W2→W1 ordering. Worker dispatched W2 design-first (thread
  s25-rung2-w2-plan-prepare) — design-before-code, S25's first
  active-path change. Standing gates unchanged: matrix → twin sweep
  (W2 gets its OWN slot — NOT an obs-only rider) → frame-pacing A/B vs
  the MacBook baseline. Rung-2 sweep-side landing gate was already
  CLEAR on the 4ffd297 green.

- W2 DESIGN ADJUDICATION items (Clerk `d0916630`, 2026-06-13 ~00:33Z;
  design APPROVED, Worker implementing —
  specs/S25-W2-PLAN-PREPARE-DESIGN-2026-06-13.md):
  (1) ROOT CAUSE OF RECORD, plan_null wall — MEASURED: the Phase-2
  translatedDrawPlans cache FREEZES AT CAPACITY (1,048,576 == 2^20,
  ~156MB retained; the C51 decision tree at GLContext.mm:39916 rejects
  every new key at capacity — no staging, no eviction).
  phase2PlanKeyForDraw OVER-KEYS on vaoName/vaoGeneration + raw FBO
  texture pointers → 1.65M+ distinct keys over 18M draws for content
  plausibly in the hundreds; fb0 fillSuccesses froze at exactly
  770,097 at the capacity-hit record index.
  (2) NEW S25 TRACKED ITEM — Phase-2 cache cap-with-eviction (separate
  train; timing adjudicated at W2 close). Two heads: memory shape
  (~156MB retained at freeze) AND the byproduct perf finding — in
  today's steady state every no-plan draw recomputes the full plan
  derivation on the app thread (MetalFrameGraph.mm:5304-5339), i.e.
  C51's intended steady-state win is PARTIALLY DEAD in live play. W2
  fixes the record path's exposure; this item restores C51's
  heavy-path economics + bounds the memory. Explicitly NOT riding W2's
  train per single-lever attribution on the sprint's first active-path
  change.

- W2 §7 CHILD-ENCODER APPLIED-STATE PROBE — RESULT (Foreman, 2026-06-13,
  f73c0e8; pin libAppGL-f73c0e8-preview-C169C3E6, SHA ab092e84;
  canonical untouched 9d3f05fb / BAC17C48 = 4ffd297). Dispatch: Worker
  c0257a87 + Clerk e2948db8 (run §7 on autogame FROZEN repro; report
  leanScissorDegenerate + leanDepthStateNull degraded-vs-present +
  raw degenSample; NO PLAN_VERIFY). Wrapper
  launch-warzone-appgl-f73c0e8-scissor.sh (fresh-authored → STAMP var
  honored, no sed-copy aliasing; CONTENT_PROBE+IMAGE_DIR+PARALLEL_ENCODE,
  MIN_FBO=16, NO PLAN_VERIFY). run-until-freeze, 6 runs a1..a6
  (highground.json autogame, gametimelimit 240). Degraded spectrum
  10→94 frames: a1=11(5.4%) a2=60(29.3%) a3=90(43.7%) a4=10(4.9%)
  a5=28(13.5%) a6=94(40.0%). 2 HARD FREEZES a3 + a6 — both EXCEED the
  confirmed 2a7ffe8 par-a4 bar (37%); frozenGridInner=0 (3D NOWHERE)
  both. SANITY PASS (Clerk-required): withLeanEncoded 234/262, non-zero
  batch-flushes (a6 deg=288/pres=465; a3 deg=282/pres=365),
  spatialDegraded≫0.
  ⇒ VERDICT — DEGENERATE-SCISSOR HYPOTHESIS REFUTED:
    (1) leanScissorDegenerate(1×1): degraded=0 (0.0%) present=0 (0.0%)
        — ALL 6 runs, no exception across the full 10→94 spectrum.
    (2) leanDepthStateNull: degraded=0 (0.0%) present=0 (0.0%) — ALL 6.
    (3) degenSample = null — RAW, every emit on both freezes (a3 9×null,
        a6 10×null, ZERO non-null objects). No degenerate draw EVER
        fired → there is no sample; the null IS the payload.
    lean-3D draws checked: a6 degraded=7175/present=10349; a3
    degraded=6857/present=8383 (large samples).
  CONFOUND RULED OUT (would have made scissor-clean a false-negative):
  lean draws routed the DESCRIPTOR-encoder path — parallelEncodedDraws=0,
  batchCount=0, descriptorEncodedDraws=20064(a6)/17708(a3),
  descriptorWorkerWallUs~12.8k. §7 STILL counted 7175/6857 degraded lean
  draws ⇒ instrument is ON the path the draws took, not an empty/inactive
  mechanism ⇒ scissor-clean is a REAL measurement. (7th confound-guard of
  the W2.1 arc.)
  CHAIN NOW: FAULT=W2.1-lean (serial 8/8 clean) → WHERE=nowhere
  (frozenGridInner=0) → NOT-dropped → NOT-cleared (§5.1 clearAfter3D=0/0,
  re-confirmed a3/a6; §5 color-clear stays the first-pass-type confound)
  → plans-CORRECT (§6 5af756d verifyChecks engaged, mismatches=0) →
  scissor-NOT-degenerate + depth-NOT-null (§7) ⇒ suppression is via a
  CORRECTLY-applied-state path. Narrowed suspect set handed to Worker:
  (a) stale/wrong render-TARGET binding on the descriptor/child encoder
  (the §4 "stale/wrong TARGET" lead), (b) PSO color-write-mask/blend
  zeroing output, (c) child-encoder concurrency hazard. Reported Worker
  3a0bdba6 (full data) + Clerk 0730130c (verdict). Holds stand
  (4ffd297 / W1). Awaiting Clerk next-probe call. Data:
  live-targets/appgl-bridge/memory-runs/s25-scissor/a1..a6.
  → WORKER REFINEMENT (ffd306c2, FIN, reply to 3a0bdba6): the
  batchCount=0 / parallelEncodedDraws=0 / descriptorEncodedDraws~20k
  catch is the load-bearing reshape — the lean-3D draws take the
  IMMEDIATE descriptor path (single render encoder, per-draw via
  ensureLeanDirectDefaultRenderPass → encodeLeanDirectTranslatedDraw-
  DescriptorOnEncoder), NOT a worker-batch/child-encoder path. ⇒ there
  are NO child encoders → suspect (c) concurrency-hazard is OUT; and the
  §5/§5.1 "batch" framing was the immediate path all along (batchCount=0
  confirms). Suspects narrowed to TWO: (a) [Worker's lead] stale/wrong
  render-TARGET — ensureLeanDirectDefaultRenderPass REUSES
  currentRenderEncoder (MetalFrameGraph ~9784) + REPORTS
  colorTexture=currentDrawable WITHOUT verifying the reused encoder
  actually targets the drawable; if an FBO-interleave encoder isn't
  switched on the FB-rebind, the lean-3D draw renders into the FBO while
  the readback reads the (clear) drawable = NOWHERE. (b) wrong PSO
  (blend/color-write-mask) — still alive; §6 verified the PLAN content
  but NOT the PSO-cache lookup. Worker designing the next probe WITH
  Clerk (the lean-3D draw's ACTUAL target/encoder + PSO color-write/blend,
  degraded vs present); Foreman standby for the SHA → attest + run.

- W2 §8 DESIGN-TIME REORIENT + DEPTH-REJECTION FREE-PIN REFUTATION
  (Foreman + Clerk + Worker, 2026-06-13; NO new build — data-surfaced
  from retained logs). Suspect set collapsed at design time before any
  §8 build:
  • (a) wrong-render-TARGET — CLOSED BY SOURCE (Worker): presentCurrent-
    Drawable:20717 early-returns if usesOffscreenTarget; the screen
    visibly presents ⇒ usesOffscreenTarget=FALSE ⇒ no offscreen path ⇒
    offscreen-recreation structurally moot; + §1 drawableMatched=99% on
    currentDrawable. The 3D hits the RIGHT drawable.
  • (c) child-encoder concurrency — OUT (§7: immediate descriptor path,
    batchCount=0, no child encoders).
  • (b) collapsed-onto lead, first framed as DEPTH-REJECTION (stale depth
    LOADED on degraded → new 3D fragments depth-fail → scene gone,
    HUD/text survive depth-off). Clerk ASK (DIR-PT ba639d58): cheap-first
    surface batchDepthLoads vs batchDepthClears degraded-vs-present from
    retained §5 data; predicted degraded depthLoads≫/clears≈0, present
    clears.
  ⇒ FOREMAN FREE-PIN RESULT (msg Clerk 3a877c7f, Worker adaba6d2):
    DEPTH-REJECTION REFUTED — the data is the EXACT INVERSE of the
    prediction, consistent across 4 independent hard freezes (§7 a3/a6 +
    867da59 b5-a11/b5-a17):
      depth-LOAD : degraded ~0.67-0.68/flush | present 1.00/flush
      depth-CLEAR: degraded ~0.32-0.33/flush | present 0.00/flush
      raw: a6 dL=194/dC=94 vs pL=464/pC=1 · a3 192/90 vs 365/0 ·
           b5-a11 292/140 vs 306/1 · b5-a17 267/128 vs 352/1
    PRESENT (healthy) loads depth 100% & NEVER clears → loading depth is
    NOT the rejector; DEGRADED loads LESS & CLEARS MORE → cleared depth =
    far plane = accepts ALL fragments → cannot reject the scene. Corrob:
    degradedBatchDepthClears == degradedBatchColorClears ==
    spatialDegradedFrames EXACTLY (1 color+depth clear / degraded-frame =
    the frame-start boundary clear §5.1 flagged benign, clearAfter3D=0).
    CAVEAT: §5 is a per-flush AGGREGATE across all passes, not lean-pass-
    isolated → refutes the aggregate-frame depth story, doesn't isolate
    the lean pass's own depth-COMPARE-function (§7 leanDepthStateNull=0 =
    state applied). Decisive one-bit closer offered: depth-compare=ALWAYS
    / depth-test-disabled A/B on the lean-3D draw.
  ⇒ STANDING (b) LEAD NOW = PSO COLOR-WRITE-MASK / BLEND on the lean-3D
    draw (right drawable + depth-not-rejecting ⇒ the color output itself
    is masked/blended to nothing). §8 (b)-probe should target color-write-
    mask + blend degraded-vs-present (+ optional force-depth-always A/B as
    the depth-closer). 8th pre-build confound gate of the W2.1 arc.
    Awaiting Clerk adjudication → §8 SHA. Holds stand (4ffd297 / W1).
  → ADJUDICATED (Clerk 19b901cc, ACK): refutation accepted ("9th confound
    down, free"). §8-(b) firmed into an A/B FORCE-BATTERY (causal, not
    passive-observe — sidesteps Metal-can't-read-back-built-mask/blend):
    three diagnostic force-arms — force-depth-ALWAYS (closes the
    lean-pass compare residual = my caveat), force-mask-ALL (color-write),
    force-blend-OFF — interleaved PER-FRAME, measuring §4 spatialDegraded
    PER ARM. The force-X arm that RESTORES the scene (spatialDegraded→0) =
    the causal pin. Forces are DIAGNOSTIC-ONLY, never land. Foreman
    run-protocol: attest (canonical-untouched) + frozen run-until-freeze +
    sanity, per-arm spatialDegraded, same rigor as §7. Standby for the
    §8-(b) SHA from Worker.
  → CORRECTION + 2nd FREE-PIN (Clerk DIR-PT 508ae9b7 → Foreman 0e1e4955 /
    Worker 8517f65e). Clerk/Worker crossed Worker's read-only depth trace
    with my readout → a SHARPER depth candidate that survives my aggregate
    caveat: DEPTH-TEXTURE REBUILD-THEN-LOAD (buildDefaultParallelRenderPass
    rebuilds depthStencilTexture on colorTexture size/sample mismatch
    9702-9745; flushPendingClear consumes hasPendingClear on the OLD tex,
    lean batch loads the NEW UNINITIALIZED tex → lean-3D depth-fails vs
    garbage Z; fits operator PAN→resize→rebuild). Clerk free-check ask:
    surface depthStencilRebuildsFromColorSizeMismatch/SampleMismatch +
    drawableResize, degraded-vs-present.
    ⇒ FOREMAN RESULT — REFUTED for the autogame freeze (rebuild counters
    are GLOBAL/un-bucketed → gross + cross-run + time-series):
      • RebuildsFromColorSizeMismatch = 0 + FromSampleMismatch = 0 in ALL
        8 runs (the exact 9702-9745 trigger NEVER fired).
      • depthStencilRebuilds total = 2 (both FromEnsure), FLAT across a 14×
        degraded range (a4=10 → b5-a11=140) ⇒ ZERO freeze-correlation.
      • EFFECTIVE resizes = drawableResizeCalls − noops = exactly 2/run,
        both at STARTUP (18.5-21k resize calls ~all no-ops → autogame does
        NOT pan/resize during play).
      • TIME-SERIES (a6): rebuilds cum=2 by emit#1 (startup Ensure);
        freeze onset emit#7 (~180 frames later) ⇒ temporally UNRELATED.
    STRUCTURAL CAVEAT (decision-relevant): rebuild-then-load is PAN-
    triggered; the autogame structurally can't fire it ⇒ refuted for the
    AUTOGAME freeze, but the autogame can't TEST the operator's pan path.
    FORK surfaced to Clerk: (a) autogame freeze == operator defect ⇒
    rebuild-out, §8-(b) force-battery (autogame) decides real cause =
    color-mask/blend; OR (b) operator pan-wipe is a DISTINCT autogame-
    invisible trigger ⇒ needs an OPERATOR on-screen PAN run w/ rebuild
    counters + force-depth-always. simple-depth DOWN + rebuild-depth DOWN
    (for autogame); force-depth-ALWAYS arm is the depth decider. Awaiting
    Clerk adjudication. Holds stand (4ffd297 / W1).
  → CLERK RULING ON THE FORK (5dffce8d, ACK; refutation accepted, "good
    catch" on the structural insight):
    1. LEAD = §8-(b) force-battery on the AUTOGAME (build gate resolved,
       Worker building). INTERPRETATION KEY for the per-arm result:
       • arm1 force-depth-always RESTORES ⇒ NON-rebuild depth-rejection
         (rebuilds=0 ⇒ a different depth path, NOT rebuild-then-load).
       • arm2 full-color-output (mask-all/blend-off) RESTORES ⇒
         color-suppression (the color-mask/blend lead).
       • NEITHER restores ⇒ geometry/shader.
    2. RECONCILIATION = the operator generalization run (always the final
       gate): battery pins autogame cause → FIX → operator pan validates.
       IF operator pan STILL wipes post-fix ⇒ distinct pan-specific cause
       ⇒ run the SAME §8-(b) build as an OPERATOR PAN session (rebuild
       counters fire under real pan + arm1 tests it). One instrument both.
    3. rebuild-then-load = REFUTED-FOR-AUTOGAME, PARKED-pending-operator-
       pan, LOW-PRIORITY (Occam: autogame freezes WITHOUT rebuilds +
       signatures match ⇒ most likely ONE shared defect the autogame CAN
       fire). Foreman run-protocol confirmed: autogame battery FIRST
       (frozen + per-arm spatialDegraded + sanity ≥37%). Standby for the
       §8-(b) SHA. Holds stand (4ffd297 / W1).

- W2 §8-(b) A/B FORCE-BATTERY — RESULT (Foreman, 2026-06-13, 4a5eeb8; pin
  libAppGL-4a5eeb8-preview-237E2D34, SHA 1640f35a; canonical untouched
  9d3f05fb / BAC17C48 = 4ffd297). Dispatch: Worker 2e25f412 + Clerk
  84d084ab (both latches APPGL_W2_AB_BATTERY=1 + ..._CONTENT_PROBE=1 +
  PARALLEL_ENCODE + MIN_FBO16; per-arm spatialDegraded; engagement
  non-vacuity gate). Wrapper launch-warzone-appgl-4a5eeb8-abbattery.sh.
  run-until-freeze, 11 runs (ab1..ab11), 6 froze.
  ⇒ VERDICT — NO ARM RESTORES (engaged, non-vacuous):
    POOLED per-arm over 6 freeze runs (~490 fr/arm):
      arm0 control     = 27.9% (deg 138 / pres 356)
      arm1 depthAlways = 29.7% (deg 146 / pres 345)
      arm2 fullColor   = 28.2% (deg 137 / pres 349)
    max delta 1.8pts << the 15pt restore threshold. At-bar single run ab4:
    arm0=37.2 / arm1=38.0 / arm2=36.4. No restore at ANY freeze level
    (ab1=10% ab3=26% ab4/ab8/ab9/ab11=29-37%, all arms-equal).
  NON-VACUITY (§6-lesson, NOT skipped): forcedDepthAlways 5062-6570 +
  forcedFullColor 5079-6502 + variant-missing=0 EVERY run ⇒ forces APPLIED
  thousands of times, arm2 variant-PSOs built ⇒ the no-restore is REAL.
  SANITY: usesOffscreenTarget=0 ((a) backstop holds), rebuilds 0/0 every
  run (in-band; rebuild-then-load NOT firing in autogame → stays PARKED-
  pending-operator-pan), arm0 reproduced freeze (ab4 37.2%≥bar),
  withLeanEncoded 234-270. passiveSample on a DEGRADED lean draw:
  blendEnabled=1 maskRGBA=[1,1,1,1] ⇒ FULL color-write + blend-on captured
  on the SUPPRESSED draw → color-mask INDEPENDENTLY exonerated.
  ⇒ CAUSALLY: NOT depth-reject (arm1 force-depth-always no-restore =
  causal confirmation of the free-pin depth refutations), NOT color-mask/
  blend (arm2 + passiveSample). The lean-3D draws have VALID scissor(§7) +
  depth-state(§7) + right drawable (a-closed/usesOffscreen=0) + full mask +
  blend-on, yet render NOWHERE ⇒ suppression is UPSTREAM of all per-fragment
  raster state: GEOMETRY/MVP-DEGENERATE (stale/wrong transform UNIFORM →
  verts off-frustum/collapsed; fits §6 ruling out wrong-PLAN but NOT
  wrong-uniform-VALUES) OR SHADER-OUTPUT-NOTHING. Autogame reproduces
  WITHOUT pan ⇒ steady-state lean geometry/uniform bug.
  SUSPECT LEDGER NOW: (a) target CLOSED · (b) simple-depth REFUTED-free ·
  (b) rebuild-depth REFUTED-free(autogame) · (b) depth-reject REFUTED-
  causal(arm1) · (b) color-mask/blend REFUTED-causal(arm2+passiveSample) ·
  (c) concurrency OUT ⇒ NEW LEAD = geometry/MVP-degenerate OR shader-
  output-nothing. NEXT = GPU-marker / geometry-capture (transformed vertex
  positions or MVP uniform, degraded-vs-present; or Metal frame capture)
  — Worker design-before-code. Reported Worker c9bbd17e + Clerk b8427530.
  No fix. Holds stand (4ffd297 / W1). Awaiting Clerk next-probe call.

- W2 §9 GEOMETRY/DATA-INTEGRITY (gross) — RESULT (Foreman, 2026-06-13,
  30c8043; pin libAppGL-30c8043-preview-A5706DF1, SHA cb2c04d0; canonical
  untouched 9d3f05fb/BAC17C48=4ffd297). Dispatch Worker 28dbfd38 + Clerk
  8ce27f98 (obs-only, NO battery latch — reads the descriptor AT ENCODE;
  CONTENT_PROBE+PARALLEL_ENCODE+MIN_FBO16). Wrapper launch-warzone-appgl-
  30c8043-geometry.sh. run-until-freeze, 5 runs (geo1..geo5), 2 froze
  (geo5 64.7% HARD, geo2 11.1%).
  ⇒ VERDICT — §9-GROSS ALL CLEAN (the predicted subtle-data-bug branch):
    4 checks degraded/present (geo5 hard freeze; geo2 identical):
      (A) degenUniform (MVP zero/NaN)  : 0 / 0  CLEAN [EXPECTED — uniforms
          deep-copied-safe @prepare 9342→encode 10159; per Clerk guard NOT
          read as "no data bug"]
      (B) nullTexture (unbound→discard): 0 / 0  CLEAN
      (C) degenDrawParams (zero count) : 0 / 0  CLEAN
      (C) nullVbuf (null vertex ptr)   : 0 / 0  CLEAN
  NON-VACUITY: geometry.checks=20073(geo5)/19834(geo2) ⇒ instrument ran on
    ~20k lean draws/run; withLeanEncoded 263-264; control froze 64.7%≥bar.
  SAMPLE (one-shot, eyeball): vertexCount=4 indexCount=0 instanceCount=1
    mode=5(TRI_STRIP) vbufPtr=33392731776(non-null) vtxUniformSize=96
    fragTex=0; MVP diag=[0.0211,-0.0042,-1,1] transl=[0.332,-0.9,0] =
    FINITE/sane ORTHO ⇒ rules out stale-GARBAGE MVP. ⚠ that sample is a
    UI/HUD quad (4-vert untextured ortho), NOT 3D-scene geometry — but the
    20k gross checks cover ALL lean draws incl. 3D-scene, uniformly clean.
  ⇒ ALL GROSS CLEAN ⇒ NEXT = §9.1 VBUF-CONTENT-HASH (record-vs-encode; the
    PRIME suspect = vertex-buffer raw ptr 9314, content NOT deep-copied,
    bound at encode 10132, mutable across the deferred-encode window — gross
    confirms ptr+counts valid but NOT content-integrity). Foreman flagged:
    §9.1 should hash a HIGH-VERT/textured 3D-SCENE draw's content, not the
    UI-quad first-lean-draw. If §9.1 clean → Metal frame-capture (Foreman
    venue, Worker in-dylib MTLCapture trigger). Reported Worker 6549c146 +
    Clerk 9709c66e. Worker shipping §9.1 (gross-clean = the trigger). No
    fix. Holds stand (4ffd297 / W1). Awaiting §9.1 SHA.

- W2 §9.1 VBUF-CONTENT-HASH + 3D-MVP SAMPLE — RESULT (Foreman,
  2026-06-13, c951ad5; pin libAppGL-c951ad5-preview-80BCC7F3, SHA
  4938453349c9...; canonical untouched 9d3f05fb/BAC17C48=4ffd297).
  TIE-BREAK CHURN (resolved): Worker hold(edd9bf3e)→rescind/RUN(9747aa3e);
  Clerk reshape-request→hold(48a79615)→GREENLIGHT-A(914515a4/d01e66bc);
  two crosses ~25-30s. Foreman HELD + surfaced both crosses (d2c91674,
  6e8788f6) rather than run a contested directive; Clerk final-locked
  RUN-c951ad5-as-is (no reshaped SHA — comparison leg low-power w/ ~static
  autogame camera, Worker reverted it; source==commit==staged UUID
  80BCC7F3 per Worker dab79a1f). Wrapper launch-warzone-appgl-c951ad5-
  vbufhash.sh. run-until-freeze, 3 runs, vh3 hard freeze 39.1%.
  ⇒ VERDICT — STALE-VBUF REFUTED; sample STILL HUD (re-target needed):
    NON-VACUITY: vbufChecks deg/pres=5169/7634 (12803) ⇒ hash RAN, vbufs
      CPU-readable (NOT Private storage); §9 checks=15434; control froze
      39.1%≥bar.
    (1) §9.1 VBUF-HASH mismatch deg/pres = 0/0 across ALL 12803 checks ⇒
      vbuf CONTENT STABLE record→encode ⇒ STALE-VBUF REFUTED. Mechanism:
      batchCount=0 / descriptorEncodedDraws=15434 = IMMEDIATE descriptor
      path → effectively NO record→encode gap to mutate (immediacy hint
      confirmed).
    (2) SAMPLE: vertexCount=4 indexCount=0 mode=5(TRI_STRIP) fragTex=1
      vbufPtr=39734224512 vtxUniformSize=96; MVP diag=[0.032,-0.068,-1,1]
      transl=[-0.150,-0.826,0] → mvp[15]=1 = ORTHO = HUD. The looks3DScene
      3D-bias MIS-FIRED — the `|| textured` clause picked a TEXTURED HUD
      quad (fragTex=1) as "3D"; 4-vert/ortho/non-indexed = HUD panel. So a
      real 3D-SCENE draw's MVP is STILL UNSEEN.
  SUSPECT LEDGER: target/depth×3/color/concurrency/gross-data-integrity/
  STALE-VBUF all eliminated. The leading WRONG-but-FINITE-MVP suspect
  (deep-copied-faithful-but-wrong matrix @prepare) is STILL UNTESTED
  (needs a real 3D-draw MVP). NEXT = Worker MINIMAL 3D-TARGETING FIX (drop
  `||textured`; require perspective mvp[15]≈0 OR indexed+vertexCount>6) →
  re-sample: 3D-MVP grossly-wrong ⇒ wrong-MVP PIN; 3D-perspective-sane ⇒
  Metal frame-capture (Foreman venue; ~static-camera caveat ⇒ likely
  Metal regardless). Reported Worker 15dc2467 + Clerk a789b7a1. No fix.
  Holds stand (4ffd297 / W1). Awaiting the 3D-targeting re-sample SHA.

- W2 §9.1-RETARGET 3D-MVP (6d542bc) — RESULT = STRUCTURAL REDIRECT
  (Foreman, 2026-06-13; pin libAppGL-6d542bc-preview-C2105341, SHA
  b45c37d3; canonical untouched 9d3f05fb/BAC17C48=4ffd297). Heavy
  Clerk↔Worker THRASH preceded (run-6d542bc ↔ §9.2-count, ~4 flips/~5min):
  Foreman HELD through every cross + routed ONE tie-break (d25eb39a)
  recommending RUN-6d542bc; Clerk LOCKED 6d542bc / §9.2 cancelled
  permanently (e637156a/f8684cfd; Worker 25efc8cb/dfb25a4c aligned).
  Wrapper launch-warzone-appgl-6d542bc-3dtarget.sh. 5 runs td1-5, td5
  hard freeze 40.2% (checks=19983, vbufChecks=7164/10196).
  ⇒ VERDICT — geometry.sample = NULL = EDGE 2 (Worker's flagged finding),
  and it is STRUCTURAL not freeze-dependent:
    • sample NULL across ALL 5 runs / 92 emits, INCLUDING td3+td4 (0%
      degraded = ALL-HEALTHY, 3D rendering fine). Capture is a one-shot
      whole-run latch on the FIRST looks3DScene draw, NOT degraded-gated
      (src MetalFrameGraph.mm:10029-30) ⇒ looks3DScene NEVER matched ANY
      lean draw, present OR degraded.
    • looks3DScene = perspective(|proj[3][3]|<0.5 @uniform+60) OR
      (indexCount>0 && vertexCount>6). The TOPOLOGY clause is MVP-
      independent yet never fired across ~100k draws ⇒ genuinely NO
      3D-mesh-topology draw on the lean path.
    • CORROBORATED: parallel boundaryReasons fbo_draw=62.8% of translated
      draws → the fbo_draw BOUNDARY excludes FBO-targeted (3D-scene) draws
      from the lean path; lean path = drawable composition/UI quads only
      (consistently 4-vert ortho, vtxUniformSize=96).
  ⇒ REFRAME OF THE ENTIRE W2.1 CHAIN: every probe (§7 scissor / §8b
  depth+color causal / §9 gross / §9.1 vbuf / this MVP) measured the
  UI/COMPOSITION quad — all FINE because the 3D geometry was never on the
  lean path. LEADING HYPOTHESIS: 3D renders to an offscreen FBO (non-lean
  draws); the lean path's ortho composition quad SAMPLES that FBO; "3D
  gone/blue" ⇒ on degraded frames the 3D-FBO is empty/unrendered OR the
  composition samples a stale/wrong FBO texture, when the lean path is
  engaged. Fits ALL priors (quad state/geometry/vbuf fine + nullTexture=0
  bound ⇒ FBO CONTENT is the problem) and reconciles §4 FAULT=W2.1-lean
  (lean-encode disrupts the non-lean 3D-FBO render/handoff). §9.1 vbuf
  STILL 0/0 (re-refuted). RESIDUAL edge-1: a non-indexed + vtxUniformSize
  <64 3D draw would slip looks3DScene (unlikely — 0 indexed-high-vert
  across 100k draws; Worker can confirm w/ a max-vtx/any-indexed lean
  counter).
  ⇒ NEXT redirects OFF the lean-draw-data axis → the 3D-FBO render +
  FBO→composition handoff: (1) Worker FBO-path probe (3D-FBO render +
  composition-source-texture identity, degraded-vs-present) OR (2) Metal
  frame-capture (Foreman venue) — directly shows 3D-FBO contents +
  composition source + RT graph. Reported Clerk 2598459b + Worker
  046c6d16. No fix. Holds stand (4ffd297 / W1). Awaiting redirect call.

- W2 REDIRECT to FBO-axis + METAL-CAPTURE FEASIBILITY (Foreman,
  2026-06-13). Worker (b2d4b8dc) + Clerk (266d50a7) BOTH ACCEPT the
  structural reframe: the 11 confounds were genuine but on the WRONG
  SURFACE (the composition quad, which is fine); the bug is in the 3D-FBO
  CONTENT or the FBO→composition handoff. Clerk likely-root = a render-pass
  DEPENDENCY/BARRIER (FBO-write→composition-read) broken when the lean
  path splits the frame encode; reconciles usesOffscreenTarget=false
  (that was the composition→drawable layer, orthogonal to the 3D→FBO
  intermediate). Clerk directs: LEAD with METAL FRAME-CAPTURE (Foreman
  venue) showing (a) 3D-FBO render ran/non-empty, (b) composition-quad
  sampled texture (current vs stale), (c) RT dep-graph + execution ORDER;
  ideally a serial(clean) + lean(frozen) DIFF. Worker building FBO-path in
  parallel.
  ⇒ FOREMAN CAPTURE-FEASIBILITY (smoke-verified; reported Clerk fb5d6ffd +
  Worker 883b4426): the in-dylib hook (APPGL_METAL_CAPTURE_PATH +
  MTL_CAPTURE_ENABLED → .gputrace via MTLCaptureManager,
  MetalFrameGraph.mm:22285/22317, called 22826-launch/22836-shutdown)
  WORKS — but is WHOLE-PROCESS-LIFETIME (built for short CTS tests).
  EMPIRICAL: 907MB for 8s NON-freezing game-time ⇒ a freezing run (~210+
  frames to reach+hold freeze) ≈ ~3GB = impractical (slow flush, unwieldy
  in Xcode, ~95% UI/load noise). TWO constraints + path: (1) NEED a BOUNDED
  window — start on the §4 sustained-degraded ONSET (not launch) + stop
  after ~3-5 frames (persistent freeze → few suffice) → ~tens-of-MB trace
  of exactly the frozen frames; asked Worker to fold into the FBO-readback
  SHA (opt-in env APPGL_METAL_CAPTURE_ON_DEGRADED). (2) .gputrace
  INSPECTION (FBO contents / RT-graph / order) needs Xcode GPU-debugger =
  an OPERATOR step. Recommended sequencing: Worker's headless FBO counters
  answer (a)/(b) without Xcode; bounded capture for (c) ordering, operator-
  inspected, + the serial-vs-frozen diff.
  EDGE-1 CENSUS in flight: Worker shipped ad19ed2 (geometry.leanMaxVertex
  Count + leanIndexedDraws + leanHighVertDraws); Foreman attesting+running
  to LOCK the reframe (expect maxVert~4-6 / indexed=0 / highVert=0 = zero
  3D-topology on lean). Holds stand (4ffd297 / W1).
  → CENSUS RESULT (Foreman, pin ad19ed2/C4EB9322, canonical untouched; 2
  runs cen1/cen2, withLeanEncoded=234): leanMaxVertexCount=4 ·
  leanIndexedDraws=0 · leanHighVertDraws=0 RUN-WIDE ⇒ ZERO indexed / ZERO
  high-vert(>6) / max-4-vert across ALL lean draws ⇒ NO 3D-mesh-topology
  on the lean path; residual edge-1 CLOSED. REFRAME PROVEN (not inferred):
  lean = composition/UI quads (≤4-vert) ONLY. Reported Clerk 27aec102 +
  Worker aac179b8.
  → CAPTURE PLAN converged (Clerk 2400a05f + Worker ab4466f5): the capture
  LEADS for the MECHANISM (RT-graph + execution-ORDER = the barrier/
  dependency test a counter can't show). Worker building the bounded-window
  as a STANDALONE SHA: opt-in APPGL_METAL_CAPTURE_ON_DEGRADED; §4
  completedHandler detects sustained-degraded onset (async) → atomic flag →
  start at NEXT present (frame boundary) + ~5-frame countdown → stop;
  one-shot. PLUS a FIXED steady-state frame trigger (Clerk's catch: the
  serial-clean half won't hit a degraded-onset since serial doesn't freeze)
  → BOTH modes. Foreman produces the bounded PAIR (serial-clean[fixed-
  frame] + lean-frozen[onset]) → operator inspects the ORDERING DIFF in
  Xcode (Clerk briefs the operator). IN PARALLEL: Worker's FBO-source-
  readback probe (deterministic, no-operator, targeted by his read-only
  FBO-trace) gives the which-half split fast [FBO-empty=3D-render-dropped /
  FBO-content-but-clear=handoff-wrong]. FBO nav: isFBODraw=fboColorTexture
  !=null → fboColorTex (MetalFrameGraph.mm:5254-5314); composition reads it
  as a lean draw's fragmentTexture. Foreman standby for the both-modes
  window SHA. Holds stand (4ffd297 / W1).
  → CAPTURE PAIR PRODUCED (Foreman, 031263e; pin libAppGL-031263e-preview-
  1911FD5C, SHA 0257c7e8; canonical untouched 9d3f05fb). Worker shipped the
  bounded-window 031263e (f221fad6): two triggers, both need APPGL_METAL_
  CAPTURE_PATH + MTL_CAPTURE_ENABLED=1; ON_DEGRADED arms at §4
  spatialDegradedFrames≥3, AT_FRAME=N arms at the Nth present() (total, incl
  load) — both one-shot, 6-frame auto-stop (MetalFrameGraph.mm present()
  16453-16475). Wrapper launch-warzone-appgl-031263e-capture.sh (flexible:
  CONTENT_PROBE+MIN_FBO baked, PARALLEL_ENCODE + capture-vars CALLER-
  controlled). TRAP caught: AT_FRAME=150 never fired (autogame resolves
  ~56-frame fast → total presents <150) → lowered to 40 (reached mid-
  gameplay). PAIR (both valid .gputrace bundles w/ resource streams +
  CAMetalLayer, machine-safe bounded):
    • SERIAL-CLEAN (reference) memory-runs/s25-capture/serial-clean.gputrace
      385MB — armed @present-frame 40, spatialDegraded=0 (clean steady-
      state), SERIAL (correct non-lean FBO→composition path).
    • LEAN-FROZEN (defect) memory-runs/s25-capture/lean-frozen.gputrace
      457MB — armed @present-frame 64 EXACTLY at the degraded ONSET
      (spatialDegraded=3, run froze to 20), PARALLEL_ENCODE=1.
  Reported Clerk 4c6c5461 (handoff for the operator Xcode 3-axis DIFF:
  (a) 3D-FBO rendered/non-empty frozen-vs-clean? (b) composition fragment
  Texture binds CURRENT vs stale/empty 3D-FBO? (c) FBO-write→composition-
  read execution ORDER/barrier — frozen samples the FBO before it's
  rendered? FBO-nav isFBODraw=fboColorTexture!=null→fboColorTex 5254-5314).
  Clerk briefs operator; Worker's deterministic FBO-source-readback runs in
  PARALLEL (no-operator which-half: FBO-empty=3D-dropped / FBO-content-but-
  clear=handoff). Foreman standby for operator (a)/(b)/(c) verdict + Worker
  readback SHA. Holds stand (4ffd297 / W1).

- W2 §10 FBO-SOURCE-READBACK — WHICH-HALF PINNED (Foreman, 2026-06-13,
  83c00b8; pin libAppGL-83c00b8-preview-DB7F120A, SHA 8c78a507; canonical
  untouched 9d3f05fb). Worker's deterministic no-operator which-half probe
  (95b76b12) — reads back the composition's SOURCE texture (the 3D-FBO it
  samples) center, correlated with the §4 drawable readback SAME-frame.
  Wrapper launch-warzone-appgl-83c00b8-fbosrc.sh (CONTENT_PROBE+PARALLEL+
  MIN_FBO16). run-until-freeze, 4 freeze runs (fbo1-4, degraded 3.4-59.6%).
  NON-VACUITY: fboSource.checks=265, compositionTexturedDraws=19140 (found
  the scene-FBO), control froze (fbo1 59.6%≥bar).
  ⇒ VERDICT — NOT 3D-RENDER-DROPPED; it's the COMPOSITION/HANDOFF side
  (confirms Clerk's render-pass barrier lead):
    ROBUST across ALL 4 runs: degraded source-FBO content-rate =
    96.8/100/100/100% (the 3D-FBO IS RENDERED with 3D) while the §4
    drawable is CLEAR in the SAME frame ⇒ FBO rendered but NOT composited
    ⇒ the 3D-render is NOT dropped; the FBO-write→composition-read HANDOFF
    is broken.
  SUB-SPLIT (source-ptr deg-vs-pres) — FLAGGED not asserted (confound):
    fbo1 (hardest 59.6%) ptr SAME (46762158080) → pure ORDERING/barrier-
    lost. fbo2/3/4 (softer) ptr DIFFER ~15-20MB → extractor's first-elif
    flags WRONG/STALE-FBO, BUT (i) both FBOs content-FULL (100%, NOT empty)
    + (ii) the differ tracks degraded-sampling RARITY not freeze-severity
    ⇒ likely a MULTI-BUFFER artifact (19140 textured draws = multi-FBO
    ring; rare degraded readback latches a different ring slot than the
    common present one), NOT a real empty-wrong-bind. The operator's Metal-
    capture is the ground-truth tiebreaker (per Worker) for pure-ordering
    vs wrong-bind — its (a) corroborates FBO-content-full, (c) the order.
  ⇒ Which-half CONVERGES with the capture's (a). FIX = restore the FBO-
  write→composition-read dependency/ORDERING broken when the lean encode
  splits the frame (+ verify the FBO-bind) — NOT the FBO-render path.
  Worker design-before-code. Reported Worker 138df601 + Clerk 083f0cb1.
  Data memory-runs/s25-fbosrc/fbo1..fbo4. No fix. Holds stand (4ffd297/W1).

- W2 §11 CB-EPOCH ORDER — FIX NAMED (Foreman, 2026-06-13, a7eca11; pin
  libAppGL-a7eca11-preview-37D32375, SHA 609b563d; canonical untouched
  9d3f05fb). Worker's no-operator probe (ac5b54b3): cbEpoch++ per CB,
  records each FBO's render epoch, captures the composition's read epoch on
  the §10 scene-FBO, compares render-vs-read epoch end-of-frame. Wrapper
  launch-warzone-appgl-a7eca11-epoch.sh. run-until-freeze, 5 freeze runs
  (epo1 32.2% / epo6 10.7% / epo7 66.7% / epo9 50.9% / epo10 61.2%; epo2-5,8
  no-freeze=no-epoch-data — checks engage ONLY on freeze).
  ⇒ VERDICT — INTRA-CB PASS-ORDER REORDER, NOT a CB-split:
    POOLED degraded epoch-order across all 5 freeze runs: sameCb=554 /
    renderAfterRead=0 / renderBeforeRead=0. EVERY degraded epoch-check
    (554/554, incl 3 HARD ≥50%: epo7=156, epo9=118, epo10=180) is SAME-CB.
    renderAfterRead=0 REFUTES the §10 cross-CB "smoking gun"; renderBefore
    Read=0 REFUTES cross-CB-split. FBO-render + composition are ALWAYS
    same-CB yet still frozen ⇒ INTRA-CB pass reorder: within the CB the
    composition (drawable) pass is encoded BEFORE the FBO-render pass that
    samples it → composition reads the FBO BEFORE its content lands.
    Consistent w/ §10 (post-frame readback sees FBO content-FULL; during-
    frame the composition already read it empty).
  NON-VACUITY: epochs captured on BOTH the FBO-render + the composition-read
  (checks engage only on freeze); control froze 66.7/50.9/61.2%≥bar.
  ⇒ The CB-granularity probe confirms same-CB; the operator's Metal-capture
  PASS-ORDER view is the confirmer (composition pass before FBO pass on the
  frozen frame) — §11 + capture CONVERGE. Clerk's focused (c)-ordering
  tiebreak is now PRECISE: pass-encode-order WITHIN the CB, not a cross-CB
  barrier. FIX = the pass ENCODE ORDER on the deferred/parallel/lean path
  (encode the FBO-render pass BEFORE the composition pass), NOT a CB-barrier
  /same-CB-after (those are cross-CB). Worker design-before-code. Reported
  Worker 1744317c + Clerk b4d263ac. Data memory-runs/s25-epoch/epo{1,6,7,9,
  10}. No fix. Holds stand (4ffd297 / W1).

- W2 §12 PASS-ORDER — DRAW-SEQ REORDER REFUTED → FIX REDIRECT (Foreman,
  2026-06-13, f1a017d; pin libAppGL-f1a017d-preview-21FC5FDB, SHA 18f5e4f5;
  canonical untouched 9d3f05fb). Worker's per-DRAW encode-order probe
  (1d9c3338): drawEncodeSeq++ at the FBO-render encode (5320) + the lean/
  composition encode + WHICH PATH the composition took. Wrapper launch-
  warzone-appgl-f1a017d-passorder.sh. run-until-freeze, 2 hard freezes
  (po1 56.8%/134chk, po4 42.9%/100chk; po2/3 no-freeze=no-data).
  ⇒ VERDICT — NO draw-seq reorder (the EXPECTED smoking-gun is REFUTED):
    POOLED degraded: renderAfterSeq=0 (rate 0.0%) / sameOrBefore=234. The
    FBO-render draw is ALWAYS encoded BEFORE the composition (draw-encode
    order is CORRECT). present renderAfterSeq=0 too. Composition PATH =
    DEFERRED 234/234 (flushLeanDirectDescriptorBatch:12343). NON-VACUITY:
    checks engage only on freeze (both seqs captured), control froze.
  ⇒ THE MECHANISM IS FINER THAN DRAW-ENCODE-SEQ: FBO-render encoded BEFORE
    composition + SAME-CB (§11) yet composition reads FBO EMPTY (§10:
    drawable-clear during-frame / FBO content-FULL post-frame) ⇒ in the
    DEFERRED-flush path (12343) the composition's drawable pass READS the
    FBO before the FBO-render pass's writes LAND = a missing FBO-write→
    composition-read DEPENDENCY/BARRIER, or a PASS-FLUSH-ORDER reorder (the
    deferred batch flushes/commits the composition pass ahead of the FBO-
    render pass) — NOT a draw-encode-order error.
  ⇒ FIX REDIRECT (overturns the §11-based "encode-order correction, NOT a
    barrier" call): the draw-encode order is ALREADY correct per §12, so
    the fix is NOT reordering the draw encode. Fix SITE = the deferred-
    flush (12343) holds, but the fix TYPE = the WRITE-BEFORE-READ sync —
    (a) establish the missing FBO-render→composition dependency/barrier
    (same-CB auto-hazard-tracking evidently NOT catching this FBO →
    untracked-resource/fence), or (b) flush/commit the FBO-render pass
    BEFORE the deferred composition batch reads it. Worker pins the exact
    finer mechanism (pass-flush-order vs missing-hazard) + designs.
    Reconciles §10+§11+§12: same-CB + encode-order-correct + composition-
    reads-empty = missing intra-CB write-before-read sync in the deferred
    path. Reported Worker 7112081e + Clerk c526175e. Data memory-runs/
    s25-passorder/po1,po4. No fix. Holds stand (4ffd297 / W1).

- W2 FIX df4e8c8 — §4 VALIDATION NOT GREEN ⇒ SAFEGUARD STOP, DIAGNOSIS
  REFUTED (Foreman, 2026-06-13; pin libAppGL-df4e8c8-preview-27FEDE8B, SHA
  acaaeaab; canonical untouched 9d3f05fb — fix is a PREVIEW pin, NEVER
  rotated to canonical). Worker's fix (956fab5a, FIRST active-path change):
  carveFboCompositionToImmediate (MetalFrameGraph.mm:13045) — routes
  FBO-sampling composition draws to the immediate C49 path instead of the
  deferred write-before-read (§10-§12); gated !APPGL_W2_FBO_CARVE_OFF &&
  workers>1 && leanDrawSamplesFboColor. Wrapper launch-warzone-appgl-
  df4e8c8-fixval.sh. A/B 6+6 run-until-freeze (Clerk 993c3ae1 + Worker
  956fab5a, deduped to ONE autogame no-operator run; operator pan run =
  SEPARATE final-gen AFTER green).
  ⇒ RESULT — NO DELTA, fix EXERCISED but INEFFECTIVE:
    carve-ON (fix default): spatialDegraded 30.1/11.3/60.9/27.4/0.0/0.0%
      (froze 4/6, max 60.9%).
    carve-OFF (APPGL_W2_FBO_CARVE_OFF=1 baseline): 0.0/36.6/10.2/24.3/46.6/
      47.7% (froze 5/6, max 47.7%).
    carve-ON ≈ carve-OFF ⇒ criterion-1 (carve-ON→0) FAILS.
  NON-VACUITY SATISFIED (the carve FIRED — proven via §12 path fields, NOT
  a no-op): carve-ON degradedCompImmediate=142/52 (deferred=0) vs carve-OFF
  degradedCompDeferred=109/126 (immediate=0) ⇒ the composition WAS rerouted
  deferred→immediate as designed; renderAfterSeq=0 on BOTH.
  ⇒ The deferred→immediate reroute does NOT reduce the freeze ⇒ the §10-§12
  "deferred-path composition write-before-read" is NOT the freeze cause; the
  composition's encode-PATH is not the determinant. DIAGNOSIS REFUTED by the
  empirical gate — exactly why pin-then-fix + the §4 A/B safeguard exist.
  ⇒ SAFEGUARD: STOPPING, NO iterate-guess (Clerk+Worker directive). Operator
  pan run NOT triggered (§4 not green). Re-diagnosis candidates (Worker/
  Clerk, not asserted): (1) a GPU-EXECUTION write-before-read surviving the
  immediate reroute (immediate/C49 ALSO reads FBO pre-write-land; same-CB
  auto-hazard genuinely not firing for this tracked FBO); (2) the
  composition's OUTPUT to the drawable is the failure, not its FBO-input;
  (3) §10 "FBO content-full" = post-frame-readback artifact (empty at the
  actual read). The reserved CAPTURE pair (serial-clean + lean-frozen, on
  disk) is now the ground-truth. Reported Clerk ec0711f9 + Worker 77cc872d.
  Foreman HOLDING (no more fix runs) for the re-diagnosis call. Data
  memory-runs/s25-fixval/on1-6+off1-6. Holds stand (4ffd297 / W1).

- W2 GPU-CAPTURE GROUND-TRUTH — DIAGNOSIS FLIPS TO OUTPUT/PRESENT-SELECTION
  (Clerk 7c9cb1aa via operator Codex-worker inspector, 2026-06-13). After
  the df4e8c8 §4-A/B falsified the input/encode-side diagnosis, Clerk
  pivoted to the GPU capture (NOT another encode re-pin — the encode
  instruments misled). The Codex-worker's Xcode read of Foreman's reserved
  lean-frozen.gputrace (frame 64 @ §4 onset, 031263e bounded-window) is
  DECISIVE:
    • the 3D IS RENDERED — FBO MTLTexture-53 is FULL (render NOT dropped).
    • all 32 CBs complete, SAME-CB ⇒ NO sync/barrier/write-before-read
      issue (§11/§12 cbEpoch/encode-order story is moot).
    • BUT the DRAWABLE presents BLUE/UI (MTLTexture-69/97/682) NOT the
      3D-composite (MTLTexture-53) — multiple textures, wrong one selected.
  ⇒ THE BUG IS OUTPUT / COMPOSITION-OUTPUT / PRESENT-SELECTION side — the
  WRONG source texture reaches the drawable. NOT render, NOT sync, NOT
  input. Flips the ENTIRE §10-§12 input-side chain (already exonerated by
  the §4 A/B) and EXPLAINS why df4e8c8 failed (it reworked the input/encode
  path = orthogonal to an output-selection bug). MATCHES Foreman's
  §4-NOT-GREEN re-hypothesis #2 ("composition's OUTPUT to the drawable is
  the failure, not its FBO-input") — the reserved capture investment paid
  off as the decisive ground-truth. Worker tracing the output/present-
  selection path now. Foreman capture vehicle (031263e bounded-window) HELD
  READY for the output-side confirm (which texture the final present/blit
  samples frozen-vs-clean + df4e8c8 A/B GPU-trace); confirmed Clerk
  f6a0f09a. Hold (4ffd297/W1, df4e8c8 parked). 13-step arc: render→sync→
  input ALL cleared; OUTPUT/present-selection is the live lead.

- W2 OUTPUT-LEAD REFINED to DROPPED-COMPOSITE + §4-DATA EXTRACT (Foreman,
  2026-06-13). Clerk 10c3e647: Inspector refined the output bug to
  DROPPED-COMPOSITE (the 3D-composite DRAW never reaches the drawable —
  drawable gets UI-only, NO tex-53), NOT wrong-selection. Worker's leading
  cause = the DEFERRED-flush path SILENTLY drops encode/pass-build FAILURES
  (no serial-fallback, unlike the immediate path). Clerk asked for a
  no-new-run extract of the deferred-flush failure counters degraded-vs-
  present from the existing fixval data.
  ⇒ FOREMAN EXTRACT (memory-runs/s25-fixval/on1-6 + off1-6): ALL failure
  counters = 0 across ALL 12 runs, INCLUDING the 3 hard freezes (on3 60.9%,
  off5 46.6%, off6 47.7%), lean/deferred path active (withLeanEncoded 262/
  294): drawableAcquireFailures, buildFails, buildFailures,
  presentCommitFailures, syncFailures, drainFailures, materializeFailures,
  reconstructionFailures, primaryReconstructionFailures, purgeFailures all
  ZERO (and global, not degraded/present-bucketed).
  ⇒ RULES OUT all COUNTED failure modes as the composite-drop cause. And
  this is CONSISTENT WITH + SUPPORTS Worker's SILENT-DROP hypothesis: the
  composite IS dropped (Inspector UI-only) yet ZERO counters fire ⇒ the
  drop site is UNINSTRUMENTED (silent, no serial-fallback). The existing
  data CANNOT confirm a silent drop by definition.
  ⇒ FLAGGED: the deferred-flush-SITE drop counter (null-pipeline/null-
  sampler/pass-build-fail at replayPendingLeanDirectDescriptorBatchSerial:
  11472 + worker-batch, bucketed degraded-vs-present) is NOT in the JSON →
  Worker adds a 1-line emit + a quick re-run → Foreman extracts the
  degraded-vs-present spike → CONFIRM the composite-drop at the deferred-
  flush site. Reported Worker 08935005 + Clerk fc24a4f1. Runs parallel to
  the Inspector's serial-clean composite-structure read. Hold (4ffd297/W1).
  → REFINED to MISTARGET, NOT DROP (Clerk e0336ae0, decisive-by-
  elimination): Foreman's ALL-failure-counters-ZERO + Inspector's 3D-IS-
  RENDERED-FULL-in-tex-53 together ⇒ NOT a fails-and-drops — the 3D
  SUCCEEDED to the WRONG TARGET (tex-53, offscreen/FBO) instead of the
  presented drawable = a MISTARGET. ⇒ the 1-line drop-emit is MOOT (a
  fails-and-drops counter reads zero for a mistarget too — no failure),
  SKIPPED, no re-run. The zero-counters extract was decisive WITH the
  Inspector (settled drop-vs-mistarget → mistarget). Worker now pinning the
  mistarget-ROOT (why the lean path targets tex-53 not the drawable) →
  route-to-serial fix → Foreman §4 A/B (carve-style, same as df4e8c8).
  Capture vehicle held for post-fix §4 + output-side re-confirm. LIVE LEAD
  = lean-path render-TARGET mistarget (3D→tex-53 not the presented
  drawable). Hold (4ffd297/W1, df4e8c8 parked).

- W2 TARGET-PROBE (4e8b422) RUN + STAND-DOWN/CORRECTION (Foreman,
  2026-06-14). Worker's obs-only Site-1 probe (df0e0bd9; env APPGL_W2_
  TARGET_PROBE, [W2_TARGET_PROBE] stderr emit) — aimed to catch the main-3D
  pass binding tex-53 instead of the drawable. Pin libAppGL-4e8b422-preview-
  46654B19, SHA 4834208e; canonical untouched 9d3f05fb. Foreman RAN it
  (tp1-3, fix-OFF defect arm) BEFORE Worker's stand-down crossed it.
  RESULT (reported Worker e59b0e2f + Clerk 50b17977): main-3D binds a LARGE
  OFFSCREEN not the drawable — 2560x1440 fmt=70 (=tex-53, 51 logged) +
  2048x2048 fmt=70 (2nd offscreen/shadow, 141 logged); match=0 (CASE B,
  prepared/non-live bind) + drawableAcquired=0 + drawableTex=nil (drawable
  NOT acquired at the 3D pass-open); summary boundNotDrawable 136→402→668→
  936 (reproduces in autogame). Foreman NUANCE-FLAGGED: the bind is
  STRUCTURAL every-frame (incl. non-freezing tp2/tp3 0%), so the §4 freeze
  is DOWNSTREAM at the COMPOSITE (Site-2).
  ⇒ STAND-DOWN (Worker f222d208, new Inspector ground-truth crossed the
  dispatch): tex-53 is the game's LEGIT persistent scene FBO — the 3D
  renders INTO it BY-DESIGN, then a composite samples tex-53→writes the
  drawable. So the probe-as-aimed mis-reads BY-DESIGN binds = WRONG SUBJECT
  (NOT a leak). Foreman's nuance-flag ALREADY converged (structural+by-
  design + freeze-at-composite) ⇒ the run CORROBORATES tex-53-legit + points
  the bug at the COMPOSITE/PRESENT path, NOT a 3D-bind leak (clarified
  Worker fde4713f + Clerk 68c2cbae; not a wasted run). Instrument NOT
  discarded — to be RE-AIMED at the composite/present draws. Clerk re-pinning
  the present-path delta first. Foreman STOOD DOWN on the probe-as-aimed.
  LIVE LEAD = the COMPOSITE/present-path (samples tex-53 → drawable) failing
  intermittently on degraded frames. Hold (4ffd297/W1, df4e8c8 parked).

- W2 ROOT CAUSE CONFIRMED = MISSING COMPOSITE (Clerk 5f42ecce via
  Inspector, 2026-06-14). DECISIVE: the degraded frame SKIPS the tex-53→
  drawable composite ENTIRELY (healthy frames have it pre-present). So on a
  degraded frame the composite draw (Render Encoder 4, samples tex-53 as
  fragment-tex 0 → writes the CAMetalLayer drawable) is DROPPED → the
  drawable never receives the 3D → blue/UI-only. The whole §1-§12 + fix-
  falsification + GPU-capture + target-probe arc converges here: render(ok)
  → sync(ok) → input(ok) → output → DROP → misdirect → Site-1(by-design,
  ruled out) → SITE-2 = MISSING COMPOSITE on degraded frames. Foreman's
  constant-cause-can't-explain-intermittent-effect inference + the §4-A/B
  fix-falsification were the corroboration.
  §4-GATE SPEC (refined, Clerk + Foreman, for WHEN the composite fix lands —
  NO §4 A/B until then): (1) PRIMARY co-gate = Worker's compositeEncoded
  Count (deterministic per-frame composite-drop count: fix-ON never drops /
  fix-OFF drops) — sharper than the intermittent visual freeze, de-risks
  intermittency; spatialDegraded = the visual confirm (boundNotDrawable
  DISCARDED — conflates by-design FBO renders). (2) INTERMITTENCY-CALIBRATED
  A/B (drop the fixed 37% bar): fix-OFF demonstrably freezes (spatialDegraded
  >0 in ≥1 run) + fix-ON = 0 across ALL runs, ≥~12-15 ON runs (N set at
  fix-time from the OFF freeze-rate). (3) OPERATOR-PAN efficacy SEAL (Clerk
  arranges): autogame §4 = cheap structural+visual screen, operator pan A/B
  = high-confidence seal (autogame only hit ~10.7% intermittent; pan
  reproduces reliably). + carveFired-analogue on the composite draws (Worker
  emits) = fix-path non-vacuity. Confirmed Clerk 189c8fc1. Site-1/route-to-
  serial = DEAD branch-A (would clobber the by-design composite). Sequence:
  Clerk Inspector present-path delta (done=missing-composite) → Worker
  composite-probe re-aim + COMPOSITE FIX design+code → Foreman §4 A/B →
  operator-pan seal. Foreman STANDING BY. Hold (4ffd297/W1, df4e8c8 parked).

- W2 COMPOSITE-PROBE (ca35c41) — DROP-SITE PINNED = ENCODE/ELIGIBILITY (NOT
  routing); EXPLAINS df4e8c8's FAILURE (Foreman, 2026-06-14; pin libAppGL-
  ca35c41-preview-EB593659, SHA 8d35e3c3; canonical untouched 9d3f05fb).
  Worker's re-aimed composite probe (1394c996 + amendment fc87fa48: drop is
  intermittent, run-until-CATCH ≥1 drop, prioritize carve-OFF). [W2_COMPOSITE
  _PROBE] per-frame: issued/immediate/recorded/encoded; DROP=1 = issued>0 +
  encoded=0. CAUGHT a drop on run-1 of BOTH arms:
    • CARVE-OFF (APPGL_W2_FBO_CARVE_OFF=1, deferred = Inspector-matching):
      off1, spatialDegraded=4.7%, 224 DROP frames — issued=1 immediate=0
      recorded=1 encoded=0 writeDrawable=0x0 ⇒ DEFERRED-FLUSH-DROP.
    • CARVE-ON (default = df4e8c8 carve, immediate): on1, spatialDegraded=
      31.9%, 138 DROP frames — issued=1 immediate=1 recorded=0 encoded=0
      writeDrawable=0x0 ⇒ IMMEDIATE-ENCODE-FAIL.
  ⇒ DECISIVE: the scene composite is ISSUED but NEVER ENCODED (encoded=0) in
  BOTH paths ⇒ the drop is at the ENCODE/ELIGIBILITY step, NOT routing. The
  carve (df4e8c8) just MOVES the drop (immediate-encode-fail ↔ deferred-flush-
  drop) — doesn't fix it ⇒ THIS IS WHY df4e8c8 FAILED the §4 A/B (the encode-
  drop persists regardless of routing). writeDrawable=0x0 both ⇒ composite
  never writes the drawable; presentedDrawable=valid ⇒ UI-only present.
  ⇒ compositeEncodedCount CO-GATE VALIDATED: 138-224 per-frame drops vs only
  4.7-31.9% visual-freeze ⇒ the per-frame drop is FAR more sensitive than the
  intermittent visual freeze (de-risks intermittency, Clerk's point).
  ⇒ FIX = the ENCODE/eligibility of the scene composite draw (WHY issued→
  routed→encoded=0 in BOTH paths), NOT the routing — the carve is the wrong
  lever. Worker pins the exact encode-skip + designs the encode-fix → Foreman
  §4 A/B (compositeEncodedCount primary). Reported Worker a830f5b3 + Clerk
  1941173f. Data memory-runs/s25-compositeprobe/off1+on1. Hold (4ffd297/W1).

- W2 ROOT CAUSE FULLY PINNED = ACQUIRE-vs-ENCODE RACE (Foreman, 2026-06-14;
  ENCODE-SKIP refinement 2cb241a; pin libAppGL-2cb241a-preview-64D3D41E, SHA
  57210f63; canonical untouched 9d3f05fb). Worker's probe (d5ab40cc) added
  skipReason(1=prepare/2=ensure/3=encode) + skipDrawNil + encDrawableAcq +
  reachedSerial. Foreman ran BOTH arms run-until-catch-a-drop.
  ⭐ THE RACE DELTA (carve-ON immediate, DECISIVE):
    • DROP frames (142×): skipReason=1 (PREPARE) + skipDrawNil=1 (current
      Drawable NIL) + encDrawableAcq=0 + reachedSerial=1.
    • HEALTHY frames: encDrawableAcq=1 (drawable ACQUIRED) + encoded=1 +
      skipReason=0/skipDrawNil=0.
  ⇒ CONFIRMED: the composite (tex-53→drawable) ENCODE RACES the drawable
  ACQUIRE (nextDrawable @1567-late). encode-BEFORE-acquire (drawable NIL) →
  the composite PREPARE-step skips (skipReason=1) → never encoded → drawable
  gets UI-only → BLUE. acquire-BEFORE-encode (healthy) → encoded → renders.
  INTERMITTENT exactly because it's a RACE.
  reachedSerial=1 on drops ⇒ the skip FELL to serial but STILL dropped
  (serial can't render to a NIL drawable) = genuinely MISSING (resolves the
  compositeEncoded-vs-spatialDegraded caveat: TRUE drop, not benign serial-
  fallback). CARVE-OFF (deferred): same root, drops at the FLUSH (skipReason=
  0/skipDrawNil=0, immediate-skip not taken). ⇒ BOTH paths race the same root
  = DRAWABLE-NOT-ACQUIRED-AT-COMPOSITE-ENCODE ⇒ routing (df4e8c8) couldn't fix
  it. Ties the whole arc: my target-probe drawableAcquired=0 (3D-pass) →
  here drawable-nil-at-COMPOSITE-encode is the live defect.
  ⇒ FIX = ACQUIRE THE DRAWABLE BEFORE THE COMPOSITE ENCODES (acquire earlier
  / defer the composite until the drawable's live / composite waits-for-or-
  triggers the acquire) — NOT routing. Worker designs → Clerk adjudicates →
  Foreman §4 A/B (efficacy spatialDegraded→0 + compositeEncodedCount
  sensitivity + ≥12-15 ON + carveFired-analogue) → operator-pan seal.
  Reported Worker f1d537dc + Clerk 120acdcd. Data memory-runs/s25-encodeskip/
  on1(immediate-prepare-skip)+off1(deferred-flush-drop). Hold (4ffd297/W1).

- W2 ⭐ THE FIX fcc7ffb — §4 A/B VALIDATED (acquire-race FIXED) (Foreman,
  2026-06-14; pin libAppGL-fcc7ffb-preview-5374E830, SHA 1db0bf14; canonical
  untouched 9d3f05fb — fix is a PREVIEW pin). Worker's fix (e9b105b5): C49
  acquire-on-transition at the lean-fork (acquire the drawable UPSTREAM of
  both encode paths); default-ON, APPGL_W2_LEAN_C49_FIX_OFF=1 = pre-fix
  baseline. §4 A/B PRIMARILY on the canonical carve-OFF defect; 6 FIX-OFF +
  14 FIX-ON. New probe fields leanC49Fired (fire-check) + serialAcqFailed/Ok.
  ⇒ VERDICT — ACQUIRE-RACE CAUSALLY FIXED:
    1. EFFICACY: FIX-OFF dropFrames=162-239/run (defect) → FIX-ON 1-2/run
       (~99% gone); spatialDegraded FIX-OFF freezes → FIX-ON 0% across ALL
       14. ✓
    2. FIRE-CHECK: leanC49Fired=255 every FIX-ON run (non-vacuity). ✓
    3. ≥12-15: 14 FIX-ON, all consistent. ✓
    4. PACING: FIX-ON fps 30.7-43.1 (no regress; earlier-acquire helps —
       pre-validates the Rung-2 pacing payoff). ✓
    5. serialFallback: FIX-ON 2-4 (no spike; df4e8c8 was 125-240). ✓
  ⚠ RESIDUAL (Clerk's anticipated "separate flush-mechanism" → FLAG, not
    re-diagnose): the 2 FIX-ON drops/run are NOT the acquire-race —
    skipDrawNil=0 (drawable IS acquired) + serialAcqOk=1 + recorded=1 +
    encoded=0 (present=35,47 mid-run), DISTINCT from the defect's
    skipDrawNil=1; NO visual impact (spatialDegraded=0). Acquire-race GREEN;
    residual = separate rare item for adjudication.
  OPERATOR confirmed visually ("didn't see any defect") + requested a test
  run → Foreman cut launch-warzone-appgl-fcc7ffb-TESTRUN.sh (GUI play, fix
  default-ON, --fixoff A/B toggle). Reported Clerk e581941c + Worker
  f3403de6. NEXT = Clerk green-adjudication → operator-pan SEAL + SCOUT
  regression sweep (C49 now fires for ANY default-FB-after-FBO lean draw →
  collateral). Data memory-runs/s25-c49fixval/fixoff1-6 + fixon1-14. Hold
  (4ffd297/W1; fcc7ffb NOT yet canonical — pending green+seal+sweep).

- W2 CROWN STATUS — 2 of 3 GATES GREEN; SCOUT-sweep the only remainder
  (2026-06-14). After the §4 A/B strong-green:
  • GATE 1 §4-green: LOCKED ✓ (Clerk 08e7f08c — all 5 criteria, causal test
    passed, residual adjudicated non-blocking follow-up).
  • GATE 2 OPERATOR-PAN-SEAL: GREEN ✓ (Clerk 77b0e4ac — operator live-
    confirmed flicker-free + textures/shadows/mini-models solid on
    fcc7ffb-TESTRUN.sh).
  • GATE 3 SCOUT REGRESSION SWEEP: PENDING = the ONLY gate left. Foreman
    caught Scout STALE (~21h, last_seen 2026-06-13T04:46) + the §4 batch
    was autogame-not-CTS ⇒ the regression gate genuinely hasn't run.
    OPERATOR chose PATH (A) via AskUserQuestion = bring Scout online → Scout
    runs the turnkey sweep [fix fcc7ffb default-ON (pin 5374E830/1db0bf14)
    vs canonical 9d3f05fb, full CTS twin-sweep default+PARALLEL_ENCODE,
    0-P→F bar, collateral focus lean default-FB transitions = the general
    C49-on-lean]. (B)-Foreman-fallback armed if Scout can't come online.
    Foreman TRACKING + will relay the delta to Clerk = SCOUT-green.
  ⇒ SCOUT-green → Clerk crowns + ROTATES CANONICAL onto fcc7ffb + unlocks
  W1. Canonical 4ffd297 held — nothing rotated. The §4-A/B gate held it
  honest the whole arc (caught df4e8c8 fired-but-ineffective; this fix is
  effective AND engaged). Reported Clerk fbcf19db. Hold (4ffd297/W1).

- W2 GATE 3 SCOUT-SWEEP — DISPATCHED + RUNNING; artifact identity VALIDATED
  (Foreman, 2026-06-13). Operator re-activated Scout (last_seen 02:23 fresh,
  was ~21h stale) + flagged I'd packaged the sweep TO the operator instead of
  dispatching it ("Did you message Scout?") — corrected: sent Scout the
  turnkey sweep task directly (6b8355a8). Scout did NOT reuse my pre-built pin
  — it INDEPENDENTLY rebuilt fcc7ffb in its own worktree with era-correct
  vendors (the right conformance-regression rigor; independent attestation >
  reusing my pin). Scout artifact (ee4f3e13):
    source_commit fcc7ffb5d015efa3a19a8e54a6f87a1273b61f70 (= the W2.1 fix) ✓
    parent_commit 4ffd297 (= canonical baseline) ✓
    sha256 5c85b442… / uuid 0C7227C9 — DIFFER from my pin (1db0bf14 /
      5374E830); EXPECTED for an independent non-reproducible build (different
      build env → different bytes; same SOURCE is what matters).
    release_shape_status PASS (Release / FP64-ON / vendor-third-party-ON /
      ASAN-OFF / DCR-hooks-OFF) ✓ — correct build config.
  ⇒ Identity VALIDATED (source+parent+shape); Scout "preparing retargeted full
  CTS twin-sweep runners vs canonical 4ffd297 now" (default + PARALLEL_ENCODE
  arms, 0-P→F bar, S22 quarantine ~batch-19715, collateral focus lean
  default-FB transitions = the general C49-on-lean). Confirmed back to Scout
  (61ef9a00) + relayed RUNNING to Clerk (c8d0590d — answers 'confirm it's
  running'). Foreman TRACKING for the P→F delta → relay to Clerk = SCOUT-green.
  ⇒ SCOUT-green → Clerk crowns + rotates canonical onto fcc7ffb + unlocks W1.
  Hold (4ffd297/W1; nothing rotated till the delta's in).

- W2 GATE 3 SCOUT-SWEEP — ARM 1 (default/no-env) GREEN, P→F=0 (Foreman,
  2026-06-13; Scout 8b4e8608). Default/no-env main CTS gate COMPLETE,
  fcc7ffb vs canonical 4ffd297:
    ends 19715/19715, incomplete_chunks=0; P=19365 F=35 NS=314 IE=1.
    vs 4ffd297: status_transitions=0, P→nonpass=0, P→F=0,
      status_maps_identical_effective=1.
  ⇒ Default arm = conformance-CLEAN (the 35F/314NS/1IE all PRE-EXISTING —
  nothing changed buckets vs canonical). candidate_qpa under scout-worktree/
  reports/full-cts-s25-fcc7ffb-…-default-noenv-quarantine/. This is ARM 1 of
  2 — NOT the gate-close. STILL PENDING: (a) PARALLEL_ENCODE arm = the
  MORE-probative arm for this fix (W2.1 + C49 acquire-on-transition both live
  on the parallel/lean path — collateral surfaces there if anywhere),
  (b) quarantine sidecar rc=133 SIGTRAP attribution (runs 2,3 trapped on the
  fcc7ffb arm; Scout running canonical 4ffd297 sidecar now → pre-existing
  [non-blocking note] vs fix-introduced [real finding regardless of bucket]).
  Foreman HOLDS Clerk SCOUT-green relay until the FULL delta (both arms +
  sidecar attribution); interim relayed Clerk (de-risk only). Hold (4ffd297/
  W1; nothing rotated).

- W2 GATE 3 SCOUT-SWEEP — sidecar rc=133 ATTRIBUTED PRE-EXISTING (criterion
  b SETTLED) + parallel arm running (Foreman, 2026-06-13; Scout 63d26f0f +
  1948e1ca). DEFAULT-arm sidecar twin:
    fcc7ffb: run1 rc=1/1row/fail, run2 rc=133/0, run3 rc=133/0 (SHA 469bf358…)
    canonical 4ffd297 fresh: run1 rc=133, run2 rc=133, run3 rc=134 — all 0
      rows (SHA 006e6946…); prior canonical 134/133/134/0-rows too.
  Shared signature BOTH arms: AGX `Texture read/write assertion failed:
  bytes_per_row >= used_bytes_per_row` (Apple-GPU driver-level assert);
  canonical run3 + ObjC weak-table spew → rc=134 SIGABRT. ⇒ baseline AGX
  quarantine behavior, canonical equal-or-WORSE, fcc7ffb marginally MORE
  stable (1 row on run1 vs canonical's 0). NOT fcc7ffb-introduced. (b)
  SETTLED pre-existing. PARALLEL-arm sidecar even cleaner: fcc7ffb runs
  1/2/3 ALL rc=1/1row/fail, ZERO rc=133 traps — nothing to attribute.
  Clerk (62b91635) CONFIRMED the regression-handling: a fix-INTRODUCED
  sidecar SIGTRAP = regression regardless of bucket (flag-not-crown); here
  pre-existing ⇒ non-blocking. ONLY REMAINING for the full delta = ARM 2
  PARALLEL_ENCODE MAIN CTS batch P→F=0 + identical-effective (the probative
  surface for this fix; RUNNING). Foreman brings the full delta to Clerk in
  ONE message → crown adjudication. Hold (4ffd297/W1).

- W2 GATE 3 SCOUT-SWEEP — ⭐ GREEN (FULL DELTA); ALL 3 CROWN GATES GREEN
  (Foreman, 2026-06-13; Scout FIN b4816805, Foreman-verified no-gaps).
  fcc7ffb vs canonical 4ffd297, BOTH main arms full 19715/19715
  (incomplete=0, quarantine_excluded=1):
    DEFAULT/no-env: P=19365 F=35 NS=314 IE=1; status_transitions=0 P→F=0
      identical_eff=1; env-proof 0-bytes (truly no env). qpa 220b8e01,
      analysis d990481.
    PARALLEL_ENCODE=1 (PROBATIVE — W2.1+C49 live on this path): IDENTICAL
      counts; status_transitions=0 P→F=0 identical_eff=1; env-proof = exactly
      APPGL_PARALLEL_ENCODE=1 (NON-VACUOUS, path actually exercised). qpa
      8e62089e, analysis d990481 (= same verdict as default).
  (b) sidecar = PRE-EXISTING: case KHR-GL46.direct_state_access.
    renderbuffers_storage_multisample; default fcc7ffb 133/133 but canonical
    EQUAL-OR-WORSE (133/133/134-SIGABRT + ObjC spew); shared AGX assert
    `bytes_per_row >= used_bytes_per_row`; parallel fcc7ffb TRAP-FREE (all
    rc=1). NOT fix-introduced.
  COLLATERAL (lean default-FB focus): status-changes-vs-4ffd297.tsv
    HEADER-ONLY both arms = ZERO lean/default-FB/FBO/draw/blit/acquire
    transitions; residual scan clean (CmpFlip=0, threading=0, MSL_FAILED=16
    pre-existing/no-transition); no leftover procs. ⇒ the general C49-on-lean
    introduced NO collateral.
  ⇒ GATE 3 SCOUT-GREEN. Relayed Clerk = full delta (FIN). ⭐ ALL THREE CROWN
  GATES GREEN: §4-A/B ✓ + operator-pan-seal ✓ + SCOUT-regression ✓. Awaiting
  Clerk crown adjudication → rotate canonical onto fcc7ffb (preview 1db0bf14/
  5374E830 OR Scout artifact 5c85b442/0C7227C9) — needs operator EXPRESS
  permission (classifier soft-block) at the rotation step. 4ffd297 held till
  crown.

- W2 ⭐ CROWN GRANTED — fcc7ffb (W2.1 acquire-on-transition fix) CROWNED
  (Clerk be7313ad, 2026-06-13). All 3 gates green (§4-A/B causal ~99% +
  operator-pan-seal live + SCOUT-regression full-delta both-arms), all 4
  rigor flags cleared, residual non-blocking. PIN: Clerk + Foreman CONCUR on
  Scout's gate artifact (5c85b442/0C7227C9, conformance-validated independent
  era-correct rebuild) as the new canonical. Foreman verify-probe-subject
  NOTE: the EFFICACY gates (§4 + pan-seal) ran on preview 5374E830 not
  5c85b442 ⇒ efficacy carries via same-source (fcc7ffb5d01, both
  release-shape-PASS, structurally cross-checked); optional cheap §4-smoke on
  5c85b442 offered (~4 autogame runs, belt-and-suspenders). ROTATION GATED on
  operator EXPRESS in-session permission (classifier soft-block) — Foreman
  capturing it in-session + rotate-now-vs-smoke-first choice. On authorize:
  verify 5c85b442 → PRESERVE 9d3f05fb rollback → swap libAppGL-pinned.dylib →
  verify 5c85b442/0C7227C9 + refresh .sha256 → report new canonical → W1
  unlocks. 4ffd297 held till authorize.

- W2 ROTATION PRE-FLIGHT — §4-CLOSER on 5c85b442 RUNNING; in-session
  permission ✓ (Foreman, 2026-06-13). Operator gave EXPRESS in-session
  permission (selected 'Rotate now' in an on-record AskUserQuestion in
  Foreman's session → shared-resource soft-block satisfied on the actual
  write; bridge-relay alone did NOT). Clerk (b8b980cd/cbd78742) TOOK
  Foreman's offered verify-probe-subject closer + made it a MANDATORY
  rotate-gate: the §4 efficacy ran on preview 5374E830, so re-run it on the
  EXACT canonical binary 5c85b442 before the write (converts same-source
  carry → direct observation). Closer = 4 fix-ON + 1 fix-OFF anchor,
  carve-OFF/composite-drop probe (DYLD → archived
  libAppGL-fcc7ffb-preview-0C7227C9.dylib, hash-verified 5c85b442; canonical
  9d3f05fb untouched during closer). GREEN bar = fix-ON dropFrames≈1-2 +
  leanC49Fired>0 + DROP=0 (×4) AND fix-OFF anchor dropFrames>>50 + DROP=1 +
  leanC49Fired=0. Green → archive-first 5-step rotate → W1. Surprise-fail →
  STOP (build-divergence), no rotate. Running (bg ~8-10 min). 4ffd297 held.

- W2 ⚠ ROTATION HALTED — Research-Stats SIGABRT = PRE-EXISTING parallel-
  encode crash, NOT W2.1-introduced (Foreman, 2026-06-13; Clerk halt
  2b0bd942/f222658e). Operator hit SIGABRT live; closer caught it too (3/5
  runs rc=134). Stack: pie_Draw3DButton → displayResearchButton →
  ResearchStatsButton::display → glDrawElements → encodeTranslatedDraw →
  flushParallelTranslatedDrawBatch → tryEncodeLeanDirectDescriptorWorkerBatch
  → AGX renderCommandEncoder → beginRenderPass →
  IOGPUMetalCommandBufferStorageAllocResourceAtIndex → abort (command-buffer
  STORAGE EXHAUSTION in the PARALLEL worker-batch encoder). ⭐ INTERVENTION
  PROOF pre-existing: crashreport 2.txt = closer fixoff-canon-1 =
  APPGL_W2_LEAN_C49_FIX_OFF=1 (C49 fix DISABLED) on the SAME 0C7227C9 →
  IDENTICAL stack ⇒ C49 fix is NOT the trigger. Trigger = Research-Stats
  many-pie_Draw3DButton 3D-previews × PARALLEL_ENCODE=1 → too many
  sub-render-encoders/command-buffer → IOGPU abort; never exercised by
  autogame (no menus) or CTS (no UI) = COVERAGE GAP. ⭐ W2.1 closer GREEN on
  0C7227C9 (real purpose): fix-ON dropFrames=2 + leanC49Fired=21,631/25,919,
  fix-OFF dropFrames=789 climbing + leanC49Fired=0 ⇒ W2.1 defect
  reproduces-fix-OFF→eliminated-fix-ON on the canonical binary; efficacy
  CONFIRMED, crash ORTHOGONAL. ⇒ W2.1 crown NOT invalidated (pre-existing, no
  regression); rotation HELD pending (1) source-confirm canonical 4ffd297 +
  PARALLEL + Research-Stats, (2) triage pre-existing parallel-encode crash =
  NEW item, (3) Clerk rotation adjudication (fix-crash-then-rotate-both vs
  rotate-W2.1-now). 3 crash reports + closer data in
  memory-runs/s25-c49fixval-canon5c85b442/CRASH-EVIDENCE/. Canonical 4ffd297
  HELD.

- W2 ROTATION HELD — hold-and-fix-first ADJUDICATED; crash-fix gates W1
  (Clerk 8239853d/0e99c895, 2026-06-13). Attribution SETTLED pre-existing
  (nm-clincher: 4ffd297 carries the IDENTICAL worker-batch path tryEncode…
  WorkerBatch ×2 = same as 0C7227C9). W2.1 crown NOT invalidated (no
  regression) + efficacy confirmed on 0C7227C9. ROTATION = HOLD + fix the
  pre-existing parallel-encode crash FIRST, bundle to ONE rotation: W1 adds
  parallel-path load → would WORSEN the exhaustion → crash-fix gates W1
  regardless ⇒ holding costs no arc-time. Operator-rotation-dialogue = Clerk
  owns (Foreman defers, avoid double-pester). 4ffd297 Research-Stats launcher
  (launch-warzone-appgl-4ffd297-researchstats-test.sh) delivered to operator
  (non-blocking visual nail; already settled by fix-OFF-on-0C7227C9).
  ⭐ CRASH-FIX GATE = synthetic-stress (the §4-analogue — live crash is
  intermittent+menu-gated = no clean gate; synthetic stress = deterministic+
  repeatable): N=64-256 small 3D draws each forcing FBO→default-FB encoder
  transition × PARALLEL_ENCODE=1 → assert completes + sub-encoders-per-CB ≤
  threshold. Placement lean appgl-unit (closest to MetalFrameGraph; reuse
  probe infra for the sub-encoder counter) + optional ogltest mirror.
  SEQUENCE: Worker flush-cadence mechanism → Clerk fix-shape + bounding
  INVARIANT → Foreman formalizes stress THRESHOLD → fix+gate coded together.
  COVERAGE-GAP root: gates ran gameplay (autogame, no menus) + CTS (no UI),
  never heavy-UI-menu × PARALLEL_ENCODE. Canonical 4ffd297 HELD; standing by
  for Worker mechanism.

- W2 CRASH-FIX GATE — PLACEMENT RESOLVED = appgl-unit in-repo (Foreman scout,
  2026-06-13). Read-only scout grounded the gate home + counter point:
  HOME = appgl-unit — appgl-runtime has tests/GauntletRunner.cpp headless
  GL-context harness + test exes in CMakeLists ~L210 (appgl_gauntlet_cli /
  asan_repro / bar_b / feature_flags_probe) → new tests/ exe loops N small 3D
  draws each forcing FBO→default-FB transition × PARALLEL_ENCODE=1;
  deterministic + CI-able + closest to code-under-test; ogltest mirror
  optional (Scout lane). COUNTER POINT = the LEAN child-encoder loop
  (MetalFrameGraph.mm tryEncodeLeanDirectDescriptorWorkerBatch child
  sub-render-encoders ~12193-12210; parallel-batch twin ~12415-12432) — a
  subEncodersThisCommandBuffer member piggybacks the [W2_COMPOSITE_PROBE]
  infra (decls ~21294-21331, per-frame reset commitCurrentAsync ~5036-5049,
  CB create ~4877-4880): ++ at child-encoder create, reset at CB create/
  commit, gate asserts max-per-CB ≤ threshold. Corroborates mechanism
  (unbounded child-encoder/CB → IOGPU storage abort); fix-shape = Worker's.
  Gate HOME + COUNTER LOCKED; THRESHOLD pending Worker flush-cadence
  INVARIANT. Relayed Clerk. Canonical 4ffd297 HELD.

- W2 CRASH-FIX CALIBRATION — revised plan: real-repro calibration via Worker's
  APPGL_W2_CB_PRESSURE_PROBE (Clerk 1d23c587, 2026-06-13). FIX SHAPE (Clerk-
  approved): per-CB encoder/resource counter → fire the EXISTING
  maybeFlushCurrentForPressure rotation (commit + rotate-fresh-CB, no-present,
  content-safe Load/Store) at a calibrated threshold; reuses proven machinery,
  only the trigger's missing. Worker building APPGL_W2_CB_PRESSURE_PROBE (obs-
  only/default-OFF/matrix-safe) → Foreman runs BOTH precursors on the heavy
  Research-Stats repro (the 4ffd297 launcher): P1 abort-count (last flushed
  high-water before SIGABRT = IOGPU per-CB cap proxy → synthetic-stress gate
  threshold) + per-frame total/peak (induced-rotation baseline, guards
  too-low-threshold → CB-churn/submission-overhead regression); P2
  PARALLEL_ENCODE=0/1 A/B (probe-ON both) → serial-vs-parallel per-CB footprint
  + does-serial-crash (serial-survives=parallel-chunk accelerant /
  serial-crashes=fundamental accumulation). FOREMAN FLAG: Research-Stats repro
  = OPERATOR-INTERACTIVE (menu-nav, autogame can't) + intermittent →
  probe-instrumented launchers (PARALLEL 1+0 arms), operator navigates,
  Foreman parses; CONTINUOUS high-water ⇒ non-crash visit still yields peak
  (de-risks intermittency). Synthetic-stress harness = DETERMINISTIC GATE
  (post-calibration; templated tests/asan_repro: dlopen→
  appglCreateOffscreenContext→appglGetProcAddress→FBO↔default-FB draw-loop) so
  the GATE never needs menu-nav. SEQUENCE: Worker instrument commit → Foreman
  precursor runs → report cap+peak+serial → Foreman formalizes gate threshold
  + Worker codes fix (Clerk confirms patch). Standing by for instrument
  commit. 4ffd297 + W1 held.

- W2 CRASH-FIX CALIBRATION cont'd — synthetic NON-REPRO → STRUCTURAL-GATE
  pivot (Foreman, 2026-06-13; Clerk e19bfe23). Synthetic CANNOT reproduce the
  abort: uniform clean to 32768 transitions; distinct-res+vbo clean to N=32768
  (65536 transitions, 32768 distinct textures+buffers) on 4ffd297. ⇒ FALSIFIES
  encoder-transition-count as the fault → it's per-CB DISTINCT-RESOURCE-table
  accumulation (IOGPU…AllocResourceAtIndex). Clerk REFINED the fix metric:
  pressure-trigger = per-CB RESOURCE-table count, NOT encoder count (relayed
  Worker; PressureFlush mechanism holds). KEY DISCOVERY: 4ffd297 ALREADY ships
  cbPressure machinery (strings cbPressureSoftCapSlots/ReserveSlots/FlushCount)
  ⇒ an EXISTING soft-cap rotates the synthetic CB before the hard cap (why it
  can't accumulate) = the SAME maybeFlushCurrentForPressure the fix
  re-triggers; fix = REFINE its metric, not new machinery. ⭐ STRUCTURAL-GATE
  PIVOT: given intermittency (operator 20-min-no-crash + synthetic non-repro),
  do NOT gate on crash-REPRODUCTION — gate on INSTRUMENT-measured per-CB
  resource pressure ≤ threshold + rotation-fires-on-heavy-frames (deterministic
  via probe; same shape as compositeEncodedCount co-gate). Synthetic stays
  VIABLE as gate vehicle IF it drives measurable pressure. DIAGNOSIS (pending
  8c8f503 build — NONE local): synthetic + APPGL_W2_CB_PRESSURE_PROBE →
  pressure-climbs-no-abort=(a)auto-rotation-masks / flat=(b)wrong-path. Worker
  committed instrument 8c8f503 (obs-only/default-OFF/matrix-safe, 3
  encoder-sites, high-water+per-frame-rollup); Foreman RQ-DIR'd the build path.
  REAL-repro (operator Research-Stats heavy + probe) = PRIMARY cap-source
  (continuous high-water → non-crash visit yields peak). Harness =
  tests/CbEncoderPressureStress.cpp (Foreman-owned, NOT committed until a valid
  gate). Operator asked cheat/limit-raise → Foreman dispatched WZ-source dig.
  4ffd297 + W1 held.

- W2 CRASH-FIX — CONVERGED design + real-repro calibration (Foreman, 2026-06-13;
  Clerk bf74fdc4/bc82f013 fix-NOD, Worker resource-probe 553aa5e). SYNTHETIC
  serial-path-LOCKED (kind=serial on BOTH FBO-alternate AND consecutive-batch;
  offscreen generic draws never reach the lean-direct worker-batch; probe
  reconcile: inFlight=1 FLAT, cbPressureFlushCount=0, encoders climb 8192/1-CB
  no-rotation no-abort = soft-cap orthogonal + serial-headroom-high) ⇒ NOT a
  viable gate/cal vehicle → DEFERRED future-CI-coverage item; real-repro = the
  only cap. SOFT-CAP CHARACTERIZED = in-flight-CB-count PACING (MetalCommand
  Submission: currentInFlight ≥ pressureSoftCap, kDefaultInFlightBound=48 −
  APPGL_COMMAND_BUFFER_RESERVE), ORTHOGONAL to the per-CB resource-table.
  ⭐ FIX (Clerk-APPROVED): ADD a NEW per-CB resource-pressure trigger to
  maybeFlushCurrentForPressure (rotate-on-resource-OR-in-flight whichever first),
  in-flight/pacing throttle INTACT (refining it = Rung-2 pacing regression).
  METRIC = per-CB distinct-RESOURCE set, TEXTURES+BUFFERS from the lean
  descriptor (samplers/PSO EXCLUDED = not MTLResource/not in AllocResourceAtIndex
  table). RESOURCE-PROBE built (Worker 553aa5e; build-release sha 5a11723a /
  UUID EBB35A1F; [W2_CB_RESOURCE] cb=… distinct=N FLUSHED per-CB high-water +
  [W2_CB_PRESSURE present] resPeak/resHighwater; APPGL_W2_CB_PRESSURE_PROBE=1 +
  PARALLEL_ENCODE=1). PREP-vs-CODE: probe CALIBRATES first → rotation-trigger
  WIRES only with the calibrated threshold + Clerk patch-confirm. GATE = the
  STRUCTURAL instrument on the real-repro (with fix: per-CB resource high-water ≤
  threshold + rotation fires; deterministic-given-probe, operator-run; CI-
  synthetic deferred). CALIBRATION (Foreman, operator-run): launch-warzone-
  researchstats-cbpressure.sh (DYLD build-release + probe envs) → operator
  cheat-on / give-all / open Research → CAPTURE: (1) [W2_CB_RESOURCE] FIRES
  (=on-lean-path not serial-locked), (2) distinct=@abort across ≥2-3 runs,
  (3) consistency + T+B-tracks-cap (distinct LOW/inconsistent → table exhausted
  by non-T+B argbuf/indirect/heap useResource @8365 serial /@20477 parallel →
  Worker broadens). Cap+consistency → Worker rotation-patch (conservative
  threshold below cap) → Clerk patch-confirm → re-validate → bundle-rotate onto
  fcc7ffb + W1. WZ cheat-ref delivered to operator (cheat on/give all/clone
  wars!!/superpower). 4ffd297 + W1 held; nothing rotates till the crash-fix lands.

- W2 CRASH-FIX — probe-segfault detour + cross-thread-lifetime PRECURSOR
  (Foreman, 2026-06-13; Clerk 91489d4c). Worker's resource-probe build
  (5a11723a) SEGFAULTED WZ on skirmish-load (×2: 22:18 game-load, 22:23
  skirmish-loader, operator-hit) — EXC_BAD_ACCESS/SIGSEGV wild-ptr in
  encodeLeanDirectTranslatedDrawDescriptorOnEncoder +10892 ← the
  tryEncodeLeanDirectDescriptorWorkerBatch WORKER-block. = CROSS-THREAD-
  LIFETIME hazard in the resource-set hook (worker-thread encode derefs a
  bad/stale ptr). ⭐ The FIX reads the SAME cbDistinctResources set ⇒ the
  hook's thread/lifetime must be correct for BOTH probe-measure AND
  trigger-read → Worker's probe-fix is a PRECURSOR to the fix (same class as
  C49 drawable-lifetime-through-the-worker-flush). SILVER LINING: segfault IN
  the worker-batch encode ⇒ WZ DOES hit the lean-direct worker-batch on load
  (real-repro VEHICLE VALID, unlike the serial-locked synthetic). 4ffd297-no-
  crash on heavy-Research = intermittency (don't over-read; pre-existing
  already settled by the fix-OFF-on-0C7227C9 intervention proof). PROCESS-FIX:
  SMOKE-TEST instrument builds BEFORE operator handoff — and the smoke-test
  MUST use WZ (worker-batch active), NOT the serial-locked synthetic (which
  would FALSE-PASS, can't reach the encode path). Foreman handed the unrun
  probe-build → operator hit the segfault (owned miss). .ips preserved
  memory-runs/s25-researchstats-cbpressure-SEGV/. Only the cbpressure launcher
  is broken (loads 5a11723a); 4ffd297/5c85b442/fcc7ffb-TESTRUN launchers safe.
  Calibration resumes on Worker's fixed probe. 4ffd297 + W1 held.

- W2 CRASH-FIX — UAF ground-truth + autogame-no-repro isolation (Foreman,
  2026-06-13; Worker 4ec3a37b ground-truth, Clerk c7bc48c8 decision-A). The
  probe-segfault = PRE-EXISTING use-after-free of a deferred-descriptor
  SAMPLER (raw un-retained metalSamplerState, freed before the worker encodes;
  objc_retain-on-freed-ptr in setFragmentSamplerState ←
  encodeLeanDirectTranslatedDrawDescriptorOnEncoder, worker thread). NOT the
  probe's hook (textures+buffers only, never derefs samplers) — the probe's
  TIMING exposed a pre-existing deferred-descriptor lifetime gap (= the FLAG-2
  resource-lifetime-through-worker-flush gap, concrete). CLERK DECISION (A):
  fix the UAF FIRST (retain the descriptor's Metal resources through the
  worker flush) — gates W1 + calibration; Worker design-first, Clerk
  adjudicates. ISOLATION (Foreman, autogame highground 25s): does NOT
  reproduce on ANY arm — probe-ON CLEAN (fired 351×, worker-batch active),
  probe-OFF×2 CLEAN, fcc7ffb CLEAN ⇒ UAF is INTERACTIVE-PATH/TIMING-specific
  (operator skirmish-loader/Research ×2; autogame misses it). probe-OFF-
  deterministic-vs-latent UNSETTLED by autogame (leans latent/timing —
  probe-fired-351×-no-crash = not deterministically fatal). ⚠ KEY: autogame
  FALSE-PASSES the UAF → validating the UAF-fixed probe needs the INTERACTIVE
  skirmish-load (operator), NOT just autogame. Smoke-test = autogame (gross
  worker-batch stability) + 1 operator interactive skirmish-load (the UAF
  path). (autogame-invocation needs --resolution=1280x720 or WZ rejects the
  gfxbackend.) SEQUENCE: Worker UAF-fix design → Clerk patch-confirm → rebuild
  probe → Foreman smoke-test (autogame + operator interactive) → operator
  give-all-Research calibration → resource-cap → trigger wires → re-validate →
  bundle-rotate fcc7ffb + W1. 4ffd297 + W1 held.

- W2 CRASH-FIX — UAF-fix LEAKS → leak-diag → (B) operator-diag (Foreman,
  2026-06-13; operator + Worker ec0ebfe/bd635fea, Clerk). The UAF-fix (010a2ff2
  retain-through-flush) WORKS (operator 3× give-all-Research: ZERO segfault on
  the ×2-crash path) BUT introduced a ~1GB/sec MEMORY LEAK (operator Activity-
  Monitor; logs OOM-death) = retain-without-balanced-release. CHARACTERIZED:
  autogame RSS PLATEAUS ~1GB (no leak) ⇒ leak is HEAVY-RESEARCH/pie_Draw3DButton
  -SPECIFIC (scales with distinct-resources/frame), autogame-BLIND (SAME as the
  UAF — both heavy-Research-only). ⚠ Foreman autogame gross-smoke MISSED both
  the segfault (handed unrun) + the leak (checked crash not RSS) → PROCESS-FIX:
  smoke MUST use WZ + RSS; the heavy-Research interactive path is the only real
  gate (autogame = gross-stability only). Worker LEAK-DIAG bd635fea
  ([W2_LEAN_RETAIN] retains/releases/live/dtors/deque). AUTOGAME leak-diag =
  PERFECTLY BALANCED (retains==releases, live=0, deque=0 thru 103837 retains,
  dtors firing) ⇒ machinery SOUND on the battlefield path; leak is path-specific.
  Worker (A)-inspection TIMEBOXED-OUT (FboDraw=serial/no-retain; pie_Draw3DButton
  reaches the deferred batch @13507 yet autogame-balanced — can't see the
  Research imbalance by code) → (B) called. RSS-LAUNCHER built+self-tested
  (launch-warzone-researchstats-cbpressure-rss.sh: loads build-release, samples
  WZ RSS→rss.log + captures [W2_LEAN_RETAIN] + [W2_CB_RESOURCE]) = the (B)
  vehicle. (B) OPERATOR-DIAG cut: short give-all → hold Research ~5-10s → quit
  (no OOM needed, lines flushed). DISCRIMINATOR: live>0 on Research = Worker's
  retain-imbalance (dtors/deque localize WHICH → release-fix); live=0 + RSS-grows
  = SEPARATE pre-existing leak the UAF-fix UNMASKED (re-subject to alloc-
  attribution). (B)-run cap = PROVISIONAL only (leaking/degraded build) — clean
  threshold-cap re-reads PASS-1 post-leak-fix. Awaiting operator (B) run → relay
  live-trend + RSS → Worker. BUGS: 1 flicker FIXED; 2 resource-crash = rotation-
  fix pending clean cap; 3 UAF FIXED; 4 leak = release-regression-OR-pre-existing
  -unmasked (B-run discriminates). 4ffd297 + W1 held.

- W2 CRASH-FIX — (B) DISCRIMINATOR RESOLVED: leak = SEPARATE PRE-EXISTING,
  UAF-fix EXONERATED (Foreman, 2026-06-13). Operator give-all-Research run
  (bd635fea, ~30s on the pane): [W2_LEAN_RETAIN] live=0 THROUGHOUT
  (retains==releases at 3,390,752; deque=0; dtors=808,418 firing; 5766 samples,
  NEVER imbalanced) ⇒ Worker's retain-through-flush BALANCED even on
  heavy-Research = NOT the leak. rss.log STEADY CLIMB ~160 MB/sec (1.4→6.9GB
  over ~32s, then →0 operator-quit). segfault=0 (UAF-fix works on the pane).
  ⇒ live=0 + RSS-grows = the SEPARATE-LEAK branch: the UAF-fix UNMASKED a
  pre-existing leak in the pie_Draw3DButton/Research-render path (the pane now
  survives long enough to OOM where it used to segfault first; the leak was
  always there, masked by the crash). ⇒ bug-3 UAF FIXED + EXONERATED of the
  leak; the LEAK (separate, NOT the retain-fix) needs ALLOC-ATTRIBUTION
  (different diag/tool) to localize WHAT allocates-without-freeing on the
  Research-render path. Worker building the alloc-attribution diag → Foreman
  runs it (same operator-short-Research vehicle = the RSS-launcher). distinct=62
  = PROVISIONAL (~floor, leak-degraded). Clean threshold-cap still waits on a
  leak-FREE build. BUGS: 1 flicker FIXED; 2 resource-crash = rotation-fix
  pending clean cap; 3 UAF FIXED+exonerated; 4/5 SEPARATE pre-existing
  Research-path leak = alloc-attribution next. 4ffd297 + W1 held.

- W2 LEAK LOCALIZED + pre-existing→BUILD-INTRODUCED correction (Foreman,
  2026-06-14; operator allocattrib 070035Z heap-diff, Clerk cdab5f92). ⚠
  CORRECTION to the prior 'pre-existing' framing: launch-warzone-appgl-4ffd297-
  researchstats-test = APPGL_PARALLEL_ENCODE=1 (PARALLEL, line 27 — NOT serial).
  Operator ran it (4ffd297 PRE-FIX canonical, PARALLEL, give-all-Research) → NO
  leak + NO segfault ⇒ leak is BUILD-INTRODUCED post-4ffd297 ([fcc7ffb..
  010a2ff2]), NOT pre-existing (REVERSED; UAF-latency broke the no-segfault⇒
  serial inference). HEAP-DIFF (allocattrib 070035Z: MallocStackLogging + heap
  early/mid/late + leaks + RSS→4.7GB): TRAJECTORY — WZ js_def_malloc/realloc
  jump-to-125MB/55MB-by-mid-then-FLAT = BOUNDED give-all data (NOT the leak);
  OUR libAppGL MONOTONIC — encodeTranslatedDrawAndMarkFbo 352→528→11.5MB +
  replaceBufferStorage 10.9MB/2972 + ObjectTable<GLBufferObject>::reserveName +
  AGXG13XFamilyBuffer (GPU 12K→1.35M→1.52M). ⇒ OUR appgl creates GL BUFFER
  OBJECTS + Metal buffers PER-FRAME on the mini-model pie_Draw3DButton previews
  WITHOUT freeing/reusing (malloc ~100MB; ~4.7GB BULK = GPU AGX buffers in VM).
  WHOSE = libAppGL (OURS). OPERATOR gold: leak tied to mini-model menus
  (research/BUILD/etc.), climbs-open/HALTS-closed. leaks/malloc_history BLOCKED
  ('not debuggable, security restrictions') → no stack; heap-diff functions
  localize. ⭐ TWO FIXES, ONE ROOT (Clerk): shared ROOT (mini-model per-frame
  path) but NOT shared FIX — bug-4 LEAK = across-frame accumulation → POOL/REUSE
  the per-frame buffers; bug-2 CRASH = within-CB distinct-count → STILL its own
  per-CB rotation-trigger (reuse doesn't cut within-frame N-buffer count). Worker
  designs the leak-fix standalone → Foreman re-verifies on the RSS-auto-logging
  validation launcher (leak-free + UAF-clean + cap, one operator run on return).
  ⚠ CROWN-VALIDATION GAP: leak in the fcc7ffb-era train — §4 crown validated
  DROPS(autogame) not MEMORY/HEAVY-UI; the bug-2 rotation-HOLD + operator
  heavy-UI testing caught it pre-canonicalize (4ffd297 never took it) → the
  bundle re-validate MUST add RSS + heavy-UI-menu. OPERATOR stepped away
  (out-of-time); all unblocked, validation staged for return. 4ffd297 + W1 held.

- W2 LEAK CAUSE REFINED + narrow-fix design (Foreman, 2026-06-14; Worker
  0c73f953 + heap-diff convergence). ⭐ CAUSE: the leak = the UAF-FIX
  (010a2ff2)'s BUFFER-retains double-keeping the rename-on-write keepalive's
  donated buffers (S25 Rung-1.5 @GLContext:17719 donates the OLD buffer storage
  to a keepalive, EXPECTING descriptors to hold it UN-retained; the UAF-fix
  retained the buffers → double-keep → old storages pile up per-frame on the
  mini-model menu). MATCHES the heap-diff EXACTLY (BUFFERS grew —
  replaceBufferStorage/GLBufferObject/AGX-buffers — NOT samplers). Reconciles
  the discriminator live=0: retains ARE balanced/eventually-released, but the
  buffer-retains EXTEND lifetime past the keepalive's free → menu-accumulation
  (counter balanced; a buffer-SUBSET broke the invariant). FIX = NARROW-(b):
  drop the buffer-retains (vertex/index/extra/ubo), KEEP the sampler-retain
  (the real transient UAF) — ~4-line revert, un-breaks the invariant; buffers
  stay alive via GLBufferObject+keepalive+encoder-bind. Foreman CONCURS (b)
  over (a)-pool/reuse (keepalive ALREADY pools; fix = STOP double-keeping).
  ⭐ ATTRIBUTION REFINED: the leak is the UAF-FIX (010a2ff2), NOT fcc7ffb ⇒ the
  CROWNED fcc7ffb is MECHANICALLY clean of the leak (pre-UAF-fix, no
  buffer-retains) = drop-fix EXONERATED (caveat: inferred — fcc7ffb
  segfaults-on-Research, untestable directly; narrow-fix RSS-validation
  confirms). Crown-gap narrower than feared. SEQUENCE: Clerk (b)-nod → Worker
  codes narrow-patch → relay sha → Foreman autogame gross-smoke (no-crash,
  leak-BLIND — NOT leak-validation) → PARK → operator heavy-UI RSS-validation
  (RSS-FLAT + segfault=0 + heap-diff buffer-class stops-growing + cap) → bug-2
  rotation-trigger → bundle re-validate (4 axes) → rotate (operator + express
  permission). Operator away ~few hours; autonomous floor (Clerk 597b6e2c).
  4ffd297 + W1 held.

- W2 LEAK NARROW-FIX af8366c8 — AUTONOMOUS GATE GREEN (Foreman, 2026-06-14;
  Worker a688473/af8366c8). Build verified (af8366c8, retainDeferredHandles +
  [W2_LEAN_RETAIN] present). 3× autogame (probe=1 + parallel=1): GROSS-SMOKE
  ALL rc=0 + segfault=0 (sampler-retain KEPT = UAF still fixed) + probe-fires
  (291-307 lines/run); RETAIN-COUNTER retains/present = 274/275/275 vs bd635fea
  baseline ~350 = ~21% DROP = buffer-retains REMOVED = narrow ENGAGED; live=0
  all 3 = kept sampler/tex/PSO/DSS retains BALANCED = UAF intact, no new
  imbalance. ⇒ fix PRESENT + ENGAGED + UAF-preserved, autonomously confirmed.
  PARK: the leak-EFFECT (RSS-FLAT heavy-Research + heap-diff buffer-class-stops
  + no-other-class-grows) is autogame-leak-BLIND → operator heavy-UI return.
  ON OPERATOR RETURN: 1 RSS-vehicle heavy-Research run = leak-fix-validate +
  UAF-clean + bug-2-cap; + Foreman autogame §4 (flicker) → then bug-2
  rotation-trigger calibration → bundle re-validate (4 axes: flicker-drops +
  UAF-clean + leak-RSS-flat + exhaustion-bounded) → rotate (operator + express
  permission). build-release = af8366c8. 4ffd297 + W1 held.

- W2 LEAK-FIX af8366c8 — EFFECT FALSIFIED by operator heavy-Research run; ROOT
  CORRECTED (Foreman, 2026-06-14; operator run 075826Z FIXED + control 070035Z
  bd635fea, both INTERACTIVE Research, build verified af8366c8 mtime 00:30 <
  run 07:58). narrow-fix is ENGAGED (retains/present 546→362 same workload =
  buffer-retains removed) + UAF intact (segfault=0, live=0) — but LEAK PERSISTS:
  RSS 0→4742MB vs control 0→4771MB = IDENTICAL; operator confirms "same
  behavior, tied to build/research screens." ⇒ leak-CROWN DENIED.
  HEAP-DIFF ROOT CORRECTED: dominant grower = buildRGBA8Upload (the per-level
  CPU RGBA8 texture SHADOW, image.rgba8, held by GLTextureObject) 83→377MB /
  31→304 live-obj on af8366c8 — IDENTICAL on bd635fea (107→387MB/334) →
  fix didn't touch it. The buffer-class the fix targeted (replaceBufferStorage)
  = 10MB/~2978obj in BOTH = NOISE. Buffer-retain double-keep hypothesis
  FALSIFIED. ⚠ MAGNITUDE LESSON (Clerk): 10MB buffers vs a 4.7GB leak = 470×
  mismatch — the per-draw buffers could NEVER account for it; we all glossed the
  magnitude in the original heap-diff. Sanity-check magnitude before causal-claim.
  WORKER CODE-GROUNDING: deleteTextures (GLContextTextureCore:32) frees CORRECTLY
  — releaseTextureStorage + objects.textures().erase destroys GLTextureObject ⇒
  BOTH CPU-shadow AND Metal-texture freed (one object owns both); re-upload on
  SAME texture OVERWRITES (levels[level]=move + replaceMetalTexture frees old).
  ⇒ leak = textures NEVER glDeleteTextures'd → GLTextureObjects ACCUMULATE
  (live 31→304 ≈ give-all's ~273 mini-model textures). ~290MB CPU shadow +
  correlated ~4GB GPU VM. Worker's kept tex-retains pin the GPU Metal-texture,
  NOT the CPU shadow ⇒ can't be the dominant; retains exonerated for it.
  TWO-STAGE VALIDATION WORKED AS DESIGNED: autonomous gate = ENGAGEMENT (true);
  operator run = EFFECT (failed) → caught the fix-failure PRE-CROWN. af8366c8 =
  NEUTRAL (UAF intact, safe cleanup, leak-orthogonal); a688473 STAYS; keep-vs-
  revert LOW-PRI. bug-2 cap-FLOOR = resHighwater=39 distinct (interactive).
  Operator-flagged scene-load freeze/beachball = MallocStackLogging harness
  overhead (alloc-heavy load) — confirm w/ no-MSL run, PARKED.
  ⭐ NEXT (staged): launch-warzone-4ffd297-allocattrib.sh — CONTROL, pre-flighted
  GREEN (4ffd297 preview 9d3f05fb/BAC17C48 byte-identical to pin; syntax+bridge+
  MSL/parallel/heap-timing matched). CLASSIFIES: buildRGBA8Upload GROWS on
  4ffd297 ⇒ PRE-EXISTING (game keeps give-all mini-model textures w/o glDelete /
  cache-no-evict → fix = eviction/footprint, NOT retains; SEPARABLE, does NOT
  block flicker+UAF crown) — Worker's lean; FLAT ⇒ INTRODUCED post-4ffd297
  (surprising — W2.1 commits are MetalFrameGraph.mm not GLContext texture path →
  indirect, bisect carefully). Operator offered the run; classify → design-
  before-code → Worker codes → Foreman re-runs operator gate. NO re-fix on
  hypothesis (buffer-miss discipline). Nothing crowns; 4ffd297 + W1 held.

- W2 LEAK — 4ffd297 CONTROL + LEVEL-2 CORRECTION + CLASS NAMED (Foreman,
  2026-06-14; ops runs: 4ffd297 control 081701Z, af8366c8 leakclass 083150Z).
  (A) 4ffd297 CONTROL: RSS PLATEAUS ~1.5GB over 62 samples (longer hold than
  af8366c8) → operator "holds stable" CORRECT. buildRGBA8Upload on 4ffd297 =
  107→388MB/40→314obj, PLATEAUS by i9 (mid=late) = IDENTICAL to af8366c8 →
  BOUNDED ~388MB FOOTPRINT (give-all ~273 model-textures, model-count-capped),
  on BOTH builds = PRE-EXISTING, RED HERRING #2 (388MB ≠ 4.7GB).
  (B) SNAPSHOT-TIMING bug: i4/9/15 were ALL pre-'roar' (footprint phase) → the
  unbounded class was never snapshotted. FIX = launch-warzone-researchstats-
  leakclass.sh: RSS-THRESHOLD heap (heap-climb>2.5GB, heap-peak>3.5GB) + MSL
  DROPPED (heap doesn't need it; MSL was the scene-load BEACHBALL root-cause).
  (C) ⭐ CLASS NAMED (leakclass 083150Z, af8366c8, RSS→5910MB, heap-mid→peak
  growers): UNBOUNDED leak = COMMAND-BUFFER accumulation, NOT textures —
  FPInFlightCommandBuffer (FramePacing in-flight CBs) 258→4751 (~18×),
  MTLResourceList 511→9515, AGXG13XFamilyRenderContext._impl 253→4745,
  IOGPUMetalPooledResource 4651→85670. buildRGBA8Upload GONE from growers.
  MECHANISM: [W2_CB_PRESSURE] cbs=1 ALL-run (cbPressure counter retires fine)
  BUT 4751 CB OBJECTS alive ⇒ completed command buffers RETAINED past GPU-
  completion (strong-ref pins them; not the counter). [W2_LEAN_RETAIN] deque=0/
  live=0 ⇒ NOT the UAF-retain/deferred deques (Worker corroborated they drain).
  Likely an IDLE-GATED CB-retirement on a never-idle menu (Worker's drain-when-
  idle pattern, applied to FramePacing CBs).
  VERDICT: INTRODUCED CONFIRMED (command-submission/FramePacing = W2 domain;
  4ffd297 plateaus = retires correctly) ⇒ GATES the crown. ⚠ fcc7ffb NOT yet
  exonerated for THIS leak (in the delta) → per-commit BISECT after grounding.
  Magnitude-sanity struck TWICE (10MB buffers, 388MB textures) — lesson DEEP:
  name-the-class AT-ROAR before reasoning. NEXT: Worker grounds the FP/command-
  submission CB-retirement → bisect (Foreman testing autogame-CB-leak
  feasibility via launch-warzone-autogame-leakprobe.sh = CHEAP autonomous bisect
  if it repros battlefield-side) → design→Clerk-confirm→code→re-gate. No
  hypothesis-coding. af8366c8/a688473 STAYS; UAF+flicker stand. 4ffd297 + W1 held.
