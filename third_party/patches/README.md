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

### `spirv-cross-tes-as-compute.patch`

**Target:** `third_party/SPIRV-Cross/spirv_msl.{hpp,cpp}` —
`msl_options` struct + five call sites.

**Status:** IN PROGRESS (Phase 3B.2). MSL is well-formed at the
signature / indexing level but still references undeclared
`gl_TessCoord` / `gl_PrimitiveID` locals. 3B.2.4 follow-up adds
the domain-coord buffer arg + fixup_hooks_in that seeds those
locals from it. Patch is regression-free as-is because the
resulting MSL is stashed only, never compiled to a PSO yet.

**Summary:** Enables `msl_options.tess_evaluation_as_compute`. When
set on a TES translation, SPIRV-Cross emits:

- `kernel void main0(...)` entry point instead of
  `[[patch(...)]] vertex main0_out main0(...)`.
- `main0_out` is written through a `device main0_out& out =
  spvOut[gl_GlobalInvocationID.x]` reference rather than returned.
- `[[position_in_patch]]` + `[[patch_id]]` entry-point args are
  dropped — downstream `fixup_hooks_in` seeds the equivalent locals
  from a host-supplied domain-coord buffer (3B.2.4 work).
- `BuiltInGlobalInvocationId` + `spvStageInputSize` are synthesised
  (same path `vertex_for_tessellation` already used for VS-compute).

**Why:** Phase 3B of the metal-tess project needs a compute path
for TES so AppGL can capture TES output into the bound
transform-feedback buffer. Metal's
`[[patch(...)]] vertex` form goes to the rasterizer and the
output isn't accessible to a host-side memcpy. Running the same
TES logic from a compute kernel with explicit buffer IO gives us
TF capture without CPU-side interpretation.

**CTS tests unlocked:** none yet (work in progress). Completing
3B.2.4 + 3B.3/4/5 downstream is expected to unlock the
`tessellation_control_to_tessellation_evaluation.*` +
`tessellation_invariance.*` + non-isoline `vertex_spacing.*`
clusters — ~100 tests total.

### `spirv-cross-tess-struct-parity.patch`

**Target:** `third_party/SPIRV-Cross/spirv_msl.cpp` —
`CompilerMSL::add_variable_to_interface_block`.

**Summary:** Force `gl_PerVertex` block builtin members (gl_Position,
gl_PointSize, gl_ClipDistance, gl_CullDistance) to be emitted in the
MSL interface struct regardless of whether the current stage actively
references them, whenever the storage is a **tess capture-buffer
interface**:

- `StorageClassOutput` from a VS compiled with
  `vertex_for_tessellation + capture_output_to_buffer` (or from a TCS
  writing to its per-CP output buffer)
- `StorageClassInput` of a TCS in `multi_patch_workgroup` mode
- `StorageClassInput` of a TES in `raw_buffer_tese_input` mode

**Why:** Upstream's `has_active_builtin` gate (line 4004) prunes
unused-in-this-stage builtins. For the tess capture-buffer model, VS
and TCS (or TCS and TES) read/write a shared struct typed as `device
main0_in*` / `device main0_out*` — pointer arithmetic uses
`sizeof(main0_in)`. If VS writes `gl_PointSize` (so the VS's
`main0_out` includes it) but the TCS doesn't read `gl_PointSize`
(so the TCS's `main0_in` prunes it), struct strides diverge and the
TCS's indexed reads return garbage for every patch past the first.

Forcing gl_PerVertex inclusion on both sides keeps stride parity at
the cost of a few unused bytes per vertex. No effect outside tess
capture-buffer mode — the gate is tightly scoped so non-tess and
non-capture-mode stages continue to emit the minimal struct.

**CTS tests unlocked:** Phase 3 of the metal-tess project requires
this. Without the patch, `tessellation_invariance.invariance_rule3-7`
and much of the `vertex_spacing.*` / `tessellation_control_to_
tessellation_evaluation.*` clusters read wrong per-CP/per-patch data
even when the Metal dispatch shape is correct. With the patch plus
the other Phase 3 infrastructure, TF-free programs can validate.

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
