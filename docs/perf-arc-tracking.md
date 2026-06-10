# AppGL Perf ARC Tracking

Status: C45 is crowned as the Step 7 rung 3 memory/Mach-port stability checkpoint. C46 is crowned as a default-off opt-in perf win: the layered-clear async prototype is committed, live-pinned for opt-in use, locally gated, and backed by autogame plus measured manual A/B throughput lift. Default-on is deferred indefinitely because the +4 FPS class win is real but not the order-of-magnitude lever; canonical launch remains default-off while the next S24 work re-aims at structural frame-shape pathologies.
Date: 2026-06-09
Owner: AppGL-Foreman

## Active Baseline

- Source worktree: `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/appgl-runtime`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/ogl-test-application/ogltest/traces-db/revendor/2026-06-09-step7-rung1-warzone-token-profile-EDB4C8AC-20260609T022218Z/baseline-warzone-tokenprofile-highground-json-1280x720-EDB4C8AC-midscene-sigterm8s/PROFILE-SUMMARY.md`
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
    `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/ogl-test-application/ogltest/traces-db/revendor/2026-06-09-step7-rung3-sampler-gpu-order-synthetic-ab-486490E2-20260609T023739Z`
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
    `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/ogl-test-application/ogltest/traces-db/revendor/2026-06-09-step7-rung3-sampler-gpu-order-synthetic-ab-F120F1C0-20260609T025449Z`
  - Median `perDrawUs` `54.122 -> 37.223`, delta `-16.899 us/draw`
    (`-31.22%`).
  - `sampler_producer_drain` `41.733 -> 0.0065 us/draw`.
  - `drain_flushes` `100 -> 2`; `gpu_order_skips` `0 -> 100`;
    `gpu_order_skip_blocked=0`; readback identical.
- Scout formal Gate 2 focused stale-pixel/conformance rerun passed:
  - Report dir:
    `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/scout-worktree/reports/perf-step7-rung3-sampler-gpu-order-scout-F120F1C0/`
  - Focused `111/111` caselist, default and skip both
    `P=106 F=4 NS=1 IE=0`.
  - F120 skip vs d28b150 baseline: `P->F=0`, `P->nonPass=0`,
    `status_transitions=0`.
  - F120 skip vs F120 default: `status_transitions=0`, `P->nonPass=0`.

Gate 3 live Warzone re-profile on `F120F1C0` completed with valid identity and
profile rows, but did not validate the lever as implemented:

- Artifact root:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/ogl-test-application/ogltest/traces-db/revendor/2026-06-09-step7-rung3-warzone-skip-profile-F120F1C0-20260609T030212Z`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/ogl-test-application/ogltest/traces-db/revendor/2026-06-09-step7-rung3-token-merge-gate1-synthetic-ab-FAF1A9BA-20260609T032512Z`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/scout-worktree/reports/perf-step7-rung3-token-merge-gate2-FAF1A9BA/`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/ogl-test-application/ogltest/traces-db/revendor/2026-06-09-step7-rung3-token-merge-warzone-profile-FAF1A9BA-20260609T033140Z`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/libAppGL-pinned.dylib`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T094759Z-71153768-pre-D0F3A096-warzone-rerun.dylib`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/libAppGL-pinned.dylib`
- staged UUID at rerun time:
  `C26B7090-A8B0-3D97-A7E0-D8CC9EB52FE0`
- staged sha256 at rerun time:
  `c7941d60dcd8345cb19b419ea98763061f515e7bac402722df7d0a54081b35b8`
- staged install-name: `@rpath/libAppGL.dylib`
- staged codesign verify: passed
- pre-stage `71153768` backup:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T101502Z-71153768-pre-C26B7090-depth32f-readback-diag.dylib`
- backup UUID:
  `71153768-044A-3B6C-AB0E-77ED809E6C8F`
- backup sha256:
  `6e2a9d70b9aba0ca1b6fda82a9b5fdba622b0d57170915209e77328e754b5a1c`
- final pin sanity check briefly found the live slot back on `71153768`;
  Foreman restaged `C26B7090` and captured a fresh current audit backup:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T101922Z-71153768-pre-C26B7090-depth32f-readback-diag-restage.dylib`
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

- `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/appgl-runtime/tests/reports/perf-step7-rung3-depth32f-readback-diag-C26B-warzone-rerun/20260609T101629Z-skip-on/`

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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T101922Z-71153768-pre-C26B7090-depth32f-readback-diag-restage.dylib`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/libAppGL-pinned.dylib`
- live UUID: `DB8D3D1F-0FD3-3BEA-A87B-14C1BDAC00E6`
- live sha256:
  `a50ed84ad11bcc11f9c8984a29fd1c90e8da50c605a90969251312c00f0bb33b`
- live install-name: `@rpath/libAppGL.dylib`
- live codesign verify: passed
- restore backup:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T104141Z-71153768-pre-C27-process-cb-diagnostics.dylib`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/appgl-runtime/tests/reports/perf-step7-rung3-c27-process-cb-tail-diagnostics-warzone-rerun/20260609T104258Z-skip-on/`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/appgl-runtime/tests/reports/perf-step7-rung3-c27-process-cb-tail-diagnostics-warzone-rerun/20260609T104456Z-skip-on/`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T104141Z-71153768-pre-C27-process-cb-diagnostics.dylib`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/diagnose-warzone-memory.sh`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/diagnose-warzone-memory.sh`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/diagnose-warzone-memory.sh`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T121202Z-skip-on/`,
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T121939Z-skip-on/`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T125211Z-skip-on/`.
  It proved the first implementation did not affect Warzone because the live
  mip growth was app-uploaded: RSS `737.047 -> 894.219 MiB`, slope
  `257.557 MiB/min`, `textureShadowMipBytes 0 -> 78446285`, and
  mip eviction bytes stayed `0`.
- C33 review-fix pin:
  UUID `66D1660B-D388-3980-B077-4CD5BB2563E1`, sha256
  `a19522333db285882196ce31754afc3e36b833aa4b775e5b19fac47767225e6d`.
- Profiles-on live artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T130405Z-skip-on/`.
  RSS `706.266 -> 809.047 MiB`, peak `970.156 MiB`, slope
  `307.857 MiB/min`; mip lane active with `textureShadowMipBytes 0`,
  evicted bytes `757115634`, live evicted bytes `78446285`,
  materialize calls `1231`, materialize bytes `678669349`, failures `0`.
- Profiles-off live artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T130516Z-skip-on/`.
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

- `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/libAppGL-pinned.dylib`
  now points to the C34 refined build.
- UUID `25BF6A62-9C1A-3FA3-9A61-B4BF76554EF0`.
- sha256
  `02fce732922b2276a56ae99b43de0dea451f0cad0252547cef47fded8a951e9b`.
- install-name `@rpath/libAppGL.dylib`; codesign verification valid.
- Backup before this repin:
  `pin-backups/libAppGL-pinned-pre-c34-cap-20260609T132433Z.dylib`.

C34 live proof:

- Artifact of record:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T132445Z-skip-on/`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/libAppGL-pinned.dylib`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T142127Z-skip-on/`.
  Frame `45 -> 105`: heap all-zones
  `372,312,640 -> 381,105,584` (`+8.79 MiB`); render PSO and MSL-slot
  retained rows continued growing.
- C39 cap-256 artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T143628Z-skip-on/`.
  Slot cache capped (`live=256`, evictions `479` by frame 105), but render PSO
  evictions stayed `0` and live render PSOs still rose `255 -> 463`.
- C39 cap-64 artifact of record:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T143718Z-skip-on/`.
  Frame `45 -> 105`: heap all-zones
  `375,133,824 -> 376,698,000` (`+1.56 MiB`), resident
  `999,505,920 -> 1,005,699,072` (`+5.91 MiB`), render PSO evictions
  `150 -> 1181`, render PSO live `209 -> 402`, MSL slots flat at `256`.
  Summary RSS samples were `790.562 -> 803.375 MiB`, peak `967.547 MiB`,
  slope `23.0219 MiB/min`.
- C39 cap-32 artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T143818Z-skip-on/`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/libAppGL-pinned.dylib`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T145529Z-skip-on/`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T150514Z-skip-on/`.
  The run ended at frame 105 before crossing the cap:
  renderPsoTotal `375`, global evictions `0`, heap frame `45 -> 105`
  `376,075,760 -> 379,977,920` (`+3.72 MiB`).
- Total320 artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T150602Z-skip-on/`.
  This proved the cap engages: frame 105 renderPsoTotal `320`,
  global evictions `123`. It is not a default candidate yet because heap rose
  to `394,099,696` by frame 105 and host/texture-shadow bytes were higher.
- Total360 artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T150646Z-skip-on/`.
  This is the best C41 candidate so far. Frame `45 -> 105`: heap all-zones
  `373,563,840 -> 377,957,680` (`+4.19 MiB`), resident
  `1,003,503,616 -> 1,010,302,976` (`+6.48 MiB`), host cache
  `220,808,603 -> 221,011,054`, device allocated
  `538,050,560 -> 538,394,624`. Frame 105 renderPsoTotal was clamped to
  `360`, high-water `361`, global evictions `39`, per-program evictions
  `1014`, MSL-slot evictions `586`.
- Hardened total360 artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T151611Z-skip-on/`.
  Frame 105 reached renderPsoTotal `360` with high-water `360` and global
  evictions `0`; resident `1,010,253,824`, heap all-zones `379,949,008`,
  host cache `221,017,562`, device allocated `538,394,624`.
- Hardened total320 artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T151648Z-skip-on/`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/launch-warzone-appgl-total360.sh`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T162911Z-skip-on/`
  and
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T163008Z-skip-on/`.
  Both exited after only a few real seconds despite the second using a longer
  `--gametimelimit`, confirming the known autogame fast-forward caveat.
- Default non-autogame skirmish artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T163057Z-skip-on/`.
  Args: `--window --resolution=1280x720 --nosound --skirmish=highground.json --gametimelimit=1800`.
  Duration `210s`, harness exit `143`. RSS `409.031 -> 542.062 MiB`
  (`+133.031 MiB`, slope `34.9419 MiB/min`). Mach ports stayed flat:
  `370 -> 370`, slope `0`; messages/syscalls still grew:
  msgsent `4430 -> 53347`, msgrecv `4371 -> 141697`, sysmach
  `14144 -> 376971`.
- Total360 non-autogame skirmish artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T163459Z-skip-on/`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/monitor-warzone-mach-ports.sh`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/manual-mach-ports/20260609T174842Z/`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/libAppGL-pinned.dylib`.
  Current live UUID `DCC4AD4B-CA56-352D-92E3-B4C228A5E7CE`, signed SHA256
  `855e7b935d97e96c96524f016bf89e22eca4ae6cacd24c1fa875ea83b2eecc1a`,
  install-name `@rpath/libAppGL.dylib`, codesign valid.
  Pre-C42 backup:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-pre-c42-mach-port-classifier-20260609T180509Z.dylib`,
  UUID `53FC202F-2C5E-3F82-9562-3E86DA4B4444`, SHA256
  `83fb9ecd3e405754b347cfffc535ce5a3add593fa2cb0ebf2475585f7c36671b`.
- Canonical launcher remains unchanged at cap64/slot256 with total cap off:
  `APPGL_RENDER_PSO_CACHE_LIMIT_PER_PROGRAM=64`,
  `APPGL_TRANSLATED_DRAW_MSL_SLOT_CACHE_LIMIT=256`.
  Added classifier helper launcher:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/launch-warzone-appgl-machports.sh`.
  It sets `APPGL_DIAG_MACH_PORTS=1`, ensures a full diagnostics JSON path,
  unsets `APPGL_BRIDGE_DIAG_LIVE_ONLY`, records `launch-env.txt`, and then
  execs the canonical launcher. `sh -n` passed and the script is executable.
- Controlled live Warzone bridge proof:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/20260609T180852Z-skip-on/`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/analyze-mach-port-classifier.sh`.
  It accepts a run directory, finds `appgl-diagnostics.jsonl` and
  `mach-ports-top.csv`, writes `mach-port-classifier-diag.csv` and
  `mach-port-classifier-summary.txt`, reports external/diagnostic endpoint
  alignment, per-right first/last/delta, per-right least-squares slopes, and
  largest positive right-class delta/slope. Optional warm-up cutoff:
  `APPGL_MACH_PORT_CLASSIFIER_MIN_FRAME=<frame>`. `sh -n` passed and the
  script is executable. On the controlled `20260609T180852Z-skip-on` artifact,
  endpoint alignment was exact: diagnostic `355` minus external `355` = `0`.
- Added exact-PID proof wrapper:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/run-warzone-appgl-machport-proof.sh`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess/20260609T182153Z/`.
  External monitor artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess/20260609T182153Z/external/20260609T182158Z/`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess-force-drain/20260609T183525Z/`.
  External monitor artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess-force-drain/20260609T183525Z/external/20260609T183530Z/`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/launch-warzone-appgl.sh`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/libAppGL-pinned.dylib`.
  Current live UUID `ED65E893-A296-39B4-8D88-D273A41A4DB3`, signed SHA256
  `5f15d2f2a8264c56a5a75180e4dd6109c02900a9c9399fc980206216d296eb46`,
  install-name `@rpath/libAppGL.dylib`, codesign valid. Pre-rotation backup:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/libAppGL-pinned-DCC4AD4B-pre-ED65E893.dylib`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess-ed65-sanity/20260609T184735Z/`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/analyze-command-buffer-reasons.sh`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/analyze-command-buffer-reasons.sh`
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/libAppGL-pinned.dylib`.
  Current live UUID `86BE8A4B-ABBA-3891-B738-9668E8355330`, signed SHA256
  `d34eae6de8cca5802d2925894b1495201417771c682546dd5fba06d17679c989`,
  install-name `@rpath/libAppGL.dylib`, codesign valid. Pre-rotation backup:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/libAppGL-pinned-ED65E893-pre-86BE8A4B.dylib`.
  Launcher syntax checks passed and force-drain remains default-on.
- Short C44 automated sanity artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/c44-present-attribution-sanity/20260609T191024Z-skip-on/`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess/20260609T194309Z/`.
  External monitor:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess/20260609T194309Z/external/20260609T194314Z/`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/libAppGL-pinned-86BE8A4B-pre-85C5B354.dylib`.
- Short launcher smoke artifact:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/c45-semaphore-owner-sanity/20260609T200850Z-skip-on/`.
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
  `cd "/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge" && APPGL_WARZONE_MACH_PORT_DURATION=180 APPGL_WARZONE_MACH_PORT_INTERVAL=2 APPGL_WARZONE_MACH_PORT_SAMPLES=30,90,180 APPGL_WARZONE_MACH_PORT_LSMP=0 APPGL_WARZONE_MACH_PORT_STOP_AFTER_MONITOR=0 ./run-warzone-appgl-machport-proof.sh --window --resolution=1280x720`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess/20260609T203253Z/`.
  External monitor:
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/manual-mach-ports-inprocess/20260609T203253Z/external/20260609T203258Z/`.
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
    `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/pin-backups/libAppGL-pinned-20260609T205432Z-C45-85C5B354-pre-C46-A8483891.dylib`.
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
  `/Users/excalibur/Documents/Developer/OpenGL 4.6 Mac/live-targets/appgl-bridge/memory-runs/c46-layered-clear-async-manual-ab`.
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
