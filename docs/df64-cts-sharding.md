# Decision F df64 CTS sharding runner

`tools/run_df64_cts_shards.py` is a harness-only runner for the temporary
Decision F df64 CTS surface:

- `KHR-GL46.gpu_shader_fp64.*`
- `KHR-GL46.vertex_attrib_64bit.*`

The runner exports the current CTS case list, verifies the expected 663-case
surface, splits `gpu_shader_fp64.builtin.*` on builtin function-family
boundaries, snapshots `libAppGL.dylib` into the run directory, launches N glcts
processes with isolated QPA/log files, merges QPAs, and compares status counts
to the Phase 7.2x baseline.

## Prepare only

```bash
appgl-runtime/tools/run_df64_cts_shards.py \
  --workers 2 \
  --prepare-only \
  --out-dir appgl-runtime/tests/reports/df64-shards/prepare-2w
```

Important artifacts:

- `case-lists/df64-all.cases.txt`
- `case-lists/groups/*.cases.txt`
- `shards/*.cases.txt`
- `shards/*.trie`
- `manifest.json`
- `summary.txt`

## Runtime-enabled validation

```bash
appgl-runtime/tools/run_df64_cts_shards.py \
  --workers 4 \
  --appgl-lib-dir appgl-runtime/build \
  --out-dir appgl-runtime/tests/reports/df64-shards/runtime-enabled-4w \
  --label df64-runtime \
  --expect-pass 663 \
  --expect-fail 0 \
  --no-default-baseline-qpas \
  --env APPGL_ENABLE_FP64_EMULATION=1
```

Sprint 21 validates the default build with a runtime opt-in. With
`APPGL_ENABLE_FP64_EMULATION=1`, the expected df64 surface is 663 Pass and
0 Fail. Without the runtime opt-in, the same default build should report the
extension-gated cases as `NotSupported`. Do not use
`gpu_shader_fp64.fp64.state_query` as the default-off advertising probe; that
CTS case intentionally skips the `GL_ARB_gpu_shader_fp64` support check.

## Historical calibration

The default unsharded baseline is 9,134.20 seconds, from the Phase 7.2x
real-device fp64 core, builtin, and vertex64 QPAs. The historical preservation
counts were 611 Pass and 52 Fail.

The 611/52 preservation gate required the same temporary dual-advertising
runtime behavior used for the Phase 7.2x measurement. A held-advertising
runtime build reports these extension-gated cases as `NotSupported`; that is
correct for the held product state but is not a valid sharding calibration
artifact for the temporary advertised baseline.

For Step 0 and later calibration probes, prefer the committed measurement gate:

```bash
APPGL_DF64_FORCE_ADVERTISE=1 APPGL_DF64_VSTF_TIMING=1 ...
```

`APPGL_DF64_FORCE_ADVERTISE=1` is measurement-only. It does not replace the
production advertising-flip protocol; default runtime behavior must continue to
hold `GL_ARB_gpu_shader_fp64` and `GL_ARB_vertex_attrib_64bit`.

## Four-worker calibration

Run this only after the 2-worker calibration shows acceptable contention:

```bash
appgl-runtime/tools/run_df64_cts_shards.py \
  --workers 4 \
  --out-dir appgl-runtime/tests/reports/df64-shards/calibration-4w
```

## Notes

- This script does not modify runtime source or CTS source.
- It uses `build-fp64-phase1/libAppGL.dylib` by default and copies it to
  `runtime-snapshot/libAppGL.dylib` inside the run directory before launching
  shards.
- Shard processes run with `cwd` set to the runtime snapshot directory. Keep
  this invariant for one-off probes too: the CTS AppGL platform calls
  `dlopen("libAppGL.dylib")`, and the CTS modules directory may contain a stale
  `libAppGL.dylib` that wins resolution if `glcts` is launched from there.
- QPAs and logs are per-shard under `qpa/` and `logs/`.
- `merged/df64-sharded-merged.qpa` is a simple merged QPA for downstream
  status parsing; the original shard QPAs remain authoritative.
- `summary.json` records case counts, status counts, speedup, shard timing, and
  per-case status mismatches against the Phase 7.2x baseline QPAs when those
  files are present.
