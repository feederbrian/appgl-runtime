# Third-Party Patches

Local modifications applied to vendored third-party checkouts. Keep this
directory in sync with the actual state of `third_party/<name>/` on disk
so a clean rebuild can re-apply.

## Fork Policy (2026-04-23)

The `third_party/SPIRV-Cross/` checkout is treated as an **AppGL fork** —
take free reign to modify it for any changes pertinent to AppGL. We ship
the modified SPIRV-Cross tree alongside appgl-runtime. The original
Khronos maintainers can choose to upstream any of our patches they like;
we don't block on upstream review. Patches captured here are both a
documentation trail and a mechanism to re-apply on a clean re-fetch of
the upstream SHA we branched from.

Typical triggers for a SPIRV-Cross modification:
- Metal backend emits MSL that's valid per the SPIRV-Cross test corpus
  but hits a Metal API-validation assertion we can't work around at the
  AppGL layer (phase-7 argbuf: bare `texture2d<T>` for readonly storage
  images → `access::read_write`).
- Missing SPIR-V opcode handling surfaces when a CTS shader uses a
  corner-case construct (session-6 atomic-unpacked-expression).
- Runtime arrays on Apple GPUs need a declared size bump to avoid
  silent drop (`unsized_array_fallback_literal`).

Prefer the AppGL layer when feasible (post-process MSL, SPIR-V
decoration edits, etc.); fall back to SPIRV-Cross when the change is
structural enough that string processing or decoration fiddling would
be brittle.

## Applying

```bash
cd third_party/<name>
git apply ../../third_party/patches/<patch-name>.patch
```

## Patches

### `spirv-cross-unsized-array-fallback-literal.patch`

**Target:** `third_party/SPIRV-Cross/` (KhronosGroup/SPIRV-Cross @ 4d4b79b)

**Summary:** Adds `backend.unsized_array_fallback_literal` (default `"1"`).
`CompilerGLSL::to_array_size` emits this literal for runtime-sized arrays
when the backend doesn't support unsized arrays directly. `CompilerMSL`
sets it to `"65536"`.

**Why:** Apple GPUs silently drop `device T&` writes past index 0 when
the struct's trailing member is declared as `T data[1]` (the MSL
workaround the upstream emits for `OpTypeRuntimeArray`), even though
the underlying `MTLBuffer` is sized to hold many elements. Bumping the
declared size to 65536 makes the MSL compiler treat indexed writes as
in-bounds relative to the reference.

Previous AppGL approach was a post-process in `ShaderTranslator.cpp`
that rewrote `[1];` to `[65536];` inside struct declarations. That
couldn't distinguish SSBO runtime arrays from UBO fixed-size-1 arrays
(`struct sC { uint3 mA[1]; };`) and also corrupted SPIRV-Cross's
std140 matrix-column stores like `= float2x2(a, b)[1];`, dropping the
second matrix column of every `mat2[N]` in std140 SSBOs. The upstream
SPIRV-Cross path only emits the fallback literal for *actual* runtime
arrays (`array_size_literal[i] == true && size == 0`), so the
distinction is made at the SPIR-V decoration level, not the text.

**CTS tests unlocked / un-regressed:**
- `shader_storage_buffer_object.basic-std140Layout-case6-cs`
- `es_31_compatibility.shader_storage_buffer_object.basic-std140Layout-case6-cs`
- `shaders.uniform_block.random.all_per_block_buffers.18`
