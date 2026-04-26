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

### `spirv-cross-tess-isolines-compute-bypass.patch`

**Target:** `third_party/SPIRV-Cross/spirv_msl.cpp` —
`CompilerMSL::func_type_decl` (the `case ExecutionModelTessellationEvaluation:`
arm).

**Summary:** Gates the upstream
`SPIRV_CROSS_THROW("Metal does not support isoline tessellation.")`
inside the TES execution-model branch on
`!msl_options.tess_evaluation_as_compute`. The throw still fires for
the upstream `[[patch(...)]] vertex` form (Metal's HW tessellator
genuinely does not support isolines); it no longer fires when AppGL is
asking SPIRV-Cross to emit the TES as a compute kernel
(`tess_evaluation_as_compute=true`). In that mode the TES is run from a
compute dispatch that consumes domain coords from a host-supplied
buffer — AppGL's `spvGenTessDomain` runtime kernel — so Metal's HW
tessellator is bypassed entirely; its isolines limitation is irrelevant.

**Why:** Without the gate, every `tessellation_invariance.*`,
`primitive_coverage.*`, and `tc2te.*` test variant whose TES uses
`layout(isolines, ...) in;` produces empty MSL on the program object
(`tesAsComputeMSL_empty=1` in AppGL's lift_translate trace). The
runtime falls back to CPU emulation, which emits wrong content for
isolines + point_mode. The gate lets the compute path engage; correctness
of the resulting output then depends on AppGL's `spvGenTessDomain`
having the right per-primitive vertex-count formula for isolines (a
separate runtime audit, not an emission concern).

**CTS tests unlocked:** ~33 isolines-using TES tests across the
`tessellation_shader.*` suite that were failing with empty kernel-form
MSL. Emission verified clean across 10 representative isolines-variant
SPIR-V dumps (Metal-validates via `xcrun -sdk macosx metal -c`,
byte-identical to runtime invocation when `--msl-capture-output` +
`--msl-multi-patch-workgroup` + `--msl-raw-buffer-tese-input` are
paired with `--msl-tess-evaluation-as-compute`).

**Regression-safe:** non-isolines TES emission is unchanged — verified
byte-identical for `data_pass_through` (quad domain) and
`invariance_rule6` (quad domain) before vs after the patch. The
isolines vertex form (non-compute path) still throws as before; only
the compute path changes behavior, and only for isolines TES.

**TCS not affected:** the parallel `case ExecutionModelTessellationControl:`
throw is left as-is. CTS isolines tests set `ExecutionModeIsolines` on
the TES SPIR-V only; the paired TCS module does not carry that mode,
so the TCS throw is not in the affected codepath. Verified empirically
across the test corpus: `spirv-cross --msl-multi-patch-workgroup ...`
on 10+ TCS dumps emitted cleanly.

### `spirv-cross-msl-interface-introspection.patch`

**Target:** `third_party/SPIRV-Cross/spirv_msl.{hpp,cpp}` — adds public
struct `MSLInterfaceLayout` + member `MSLInterfaceMember`, and the
`CompilerMSL::get_msl_interface_layout(StorageClass, bool patch=false)`
method. Companion test program at `third_party/SPIRV-Cross/tools/msl-introspect-test.cpp`.

**Summary:** Read-only post-`compile()` introspection of the actual MSL
stage-interface struct. Returns each member's `name`, `location`,
`builtin`, type info, plus computed Metal-C-ABI `offset` and `size`,
plus the padded total `struct_size` and `struct_alignment`. AppGL's
runtime reads the layout this returns and uses it directly instead of
synthesizing a parallel layout from SPIR-V reflection.

**Why:** AppGL's `reflectStageOutputLayout` had been synthesizing the
expected MSL struct layout based on SPIR-V plus assumptions about
`spirv-cross-tess-struct-parity.patch`'s insertion behavior. Drift
between AppGL's mirror and SPIRV-Cross's actual emission corrupted TF
buffer stride math (e.g. `data_pass_through` TES wrote a 5-member
80-byte struct, AppGL assumed 7 members at 112 bytes → 32-byte
drift/vertex). Exposing the canonical layout via a public method
forecloses the entire class of mirror-decay bugs as future emission
patches evolve.

**Implementation notes:** Stage interface block members do **not**
carry `DecorationOffset` (that decoration is set on UBO/SSBO members
only), so offsets are computed manually using Metal C ABI alignment
rules — the same rules the MSL emitter applies when laying out the
struct in the emitted source. Sizes for non-array, non-struct members
come from `bit_width × vecsize × columns`; for arrays, each element is
padded up to the element type's alignment. A debug-build assertion
checks that the running offset+size matches the padded total —
emission changes that invalidate the introspected layout fail loudly
in debug builds.

**CTS tests unlocked / un-regressed:** none directly — this is a
runtime-side dependency unblock. AppGL-W's downstream walker fix uses
this method to size + write TF buffers correctly across the
`tessellation_shader.*` cluster.

### `spirv-cross-cli-tese-as-compute-flags.patch`

**Target:** `third_party/SPIRV-Cross/main.cpp` (CLI arg parser + help)
plus a new `third_party/SPIRV-Cross/tools/msl-tess-diff.sh`
developer-side helper script.

**Summary:** Exposes two `msl_options` fields through the
`spirv-cross` CLI binary so they can be flipped from a shell:

- `--msl-tess-evaluation-as-compute` → `msl_options.tess_evaluation_as_compute`
- `--msl-tese-input-patch-vertices <count>` → `msl_options.tese_input_patch_vertices`

These are the AppGL-specific flags introduced by
`spirv-cross-tes-as-compute.patch`; the patch wires them up the same
way upstream wires `--msl-vertex-for-tessellation` and
`--msl-multi-patch-workgroup`, with `[AppGL fork]` markers in the help
text so future maintainers can see they're not vanilla SPIRV-Cross.
The companion `tools/msl-tess-diff.sh` wraps the binary to produce
paired vertex-form / kernel-form MSL outputs and a unified diff for a
given TES SPIR-V dump — the SPIRV-W MSL-diff study workflow per
`SPIRV-W-CONTEXT.md` §5.2. The script also runs `xcrun -sdk macosx
metal -c` on each form (per §7 invariant #4) and surfaces asymmetric
validation results: a kernel form that compiles cleanly while the
vertex form does (or vice versa) is itself diagnostic, distinguishing
"SPIRV-Cross emits MSL Metal rejects" (codegen bug) from "MSL is
valid but PSO creation fails on usage-level constraints" (runtime
API bug). Skip via `NO_METAL_VALIDATE=1`. Empty / boilerplate-only
MSL (where SPIRV-Cross silently bails on a program shape, e.g.
entry-point detection failure) is flagged as `EMPTY_MSL` ahead of
xcrun rather than passed through — `xcrun metal -c` trivially
succeeds on near-empty files and would otherwise corrupt the
diagnostic. Threshold is 100 bytes by default, tunable via
`EMPTY_MSL_THRESHOLD`.

**Why:** Without CLI exposure, exercising the kernel form requires
either a custom C++ harness linked against `libspirv-cross.a` or
running through the full AppGL runtime invocation. Both are heavier
than the diff workflow needs. CLI flags let SPIRV-W and AppGL-W
iterate on emission shape changes against captured SPIR-V dumps in
seconds rather than full CTS-rebuild cycles.

**CTS tests unlocked:** none directly — this is developer-tooling
infrastructure. Indirectly enables faster iteration on the
`tessellation_shader.*` debugging surface.

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
