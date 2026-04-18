# Third-Party Patches

Local modifications applied to vendored third-party checkouts. Keep this
directory in sync with the actual state of `third_party/<name>/` on disk
so a clean rebuild can re-apply.

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

### `spirv-cross-atomic-unpacked-expression.patch`

**Target:** `third_party/SPIRV-Cross/` (KhronosGroup/SPIRV-Cross @ 4d4b79b + previous local patch)

**Summary:** `CompilerMSL::emit_atomic_func_op` passes the atomic `operand` (op1)
via `bitcast_expression(expected_type, op1)` and the compare-exchange `desired`
(op2) via `to_expression(op2)`. Both collapse to `to_expression` for the common
non-remapped case, which produces the full `uint4`/`int4` when the underlying
uniform is a scalar stored in a std140-padded physical type. MSL's `atomic_*`
functions require scalar operands, so the pipeline build fails with:

```
error: from vector 'unsigned int __attribute__((ext_vector_type(4)))'
       to scalar 'unsigned int' of different size
```

The patch swaps those three call sites (one for the non-CAS operand, one for
the CAS `desired`, one for the CAS `expected` refresh inside the do-while
body) to `to_unpacked_expression(...)` — which applies the `.x` swizzle when
physical > logical, and is a no-op otherwise.

**Why this matters:** CTS atomic tests read constants from
`uniform uint g_uint_value[8]` (which SPIRV-Cross emits as `uint4[8]` in MSL
under default-uniform std140 rules). Without the patch, every `atomicAdd`
/`atomicExchange` / etc. that reads from such an array fails the pipeline
build, and the test silently reports zero-valued output.

**CTS tests unlocked:**
- `shader_storage_buffer_object.basic-atomic-case1-cs`

(The non-cs atomic variants require GS/tessellation emulation we don't have;
case3-cs / case4-cs pass independently because they don't use default-uniform
arrays.)
