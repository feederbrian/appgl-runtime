# Artifact Producer Hardening

Gate candidates for perf or crown review should be release-shaped by default:

```sh
cmake -S . -B build-release \
  -DCMAKE_BUILD_TYPE=Release \
  -DAPPGL_VENDOR_THIRD_PARTY=ON \
  -DAPPGL_ENABLE_ASAN=OFF \
  -DAPPGL_DCR_SENTINEL_HOOKS=OFF
cmake --build build-release --target AppGL
```

Before handoff, every candidate package should carry binary-shape evidence:

- `libAppGL.dylib.meta`
- `libAppGL.dylib.sha256`
- `current-lib/libAppGL.dylib.meta`
- `current-lib/libAppGL.dylib.sha256`
- `SHA256SUMS`
- `shape/binary-shape.txt`

Use the lightweight gate publisher for AppGL-only handoffs:

```sh
tools/publish_gate_dylib_artifact.sh \
  --artifact-id my-gate-id \
  --dylib build-release/libAppGL.dylib \
  --build-dir build-release \
  --source-commit "$(git rev-parse HEAD)" \
  --parent-commit "$(git rev-parse HEAD^)"
```

Use the CTS artifact emitter for runnable GL CTS packages:

```sh
tools/emit_glcts_artifact.sh \
  --artifact-id my-cts-id \
  --build-dir build-release \
  --variant release \
  --source-commit "$(git rev-parse HEAD)" \
  --parent-commit "$(git rev-parse HEAD^)" \
  --schema appgl-glcts-artifact-v2
```

Both producers call `tools/appgl_binary_shape_report.sh` and fail the release
gate when the build cache or Mach-O shape looks debug/helper-heavy. The default
limits can be overridden for operator-approved release-shape changes:

```sh
APPGL_SHAPE_MAX_SIZE_BYTES=18000000 \
APPGL_SHAPE_MAX_NM_M_LINES=45000 \
APPGL_SHAPE_MAX_STUBS_BYTES=30000 \
APPGL_SHAPE_MAX_LINKEDIT_FILESIZE=7000000 \
tools/publish_gate_dylib_artifact.sh ...
```

Diagnostic or debug artifacts must opt out explicitly and label themselves:

```sh
tools/publish_gate_dylib_artifact.sh \
  --artifact-id my-diagnostic-id \
  --dylib build-debug/libAppGL.dylib \
  --build-dir build-debug \
  --source-commit "$(git rev-parse HEAD)" \
  --parent-commit "$(git rev-parse HEAD^)" \
  --diagnostic-label "asan investigation, not perf gate"
```

Do not use diagnostic-labeled packages for perf gates unless the operator
explicitly asks for a diagnostic comparison.
