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

### `spirv-cross-msl-atomic-3d-dispatch.patch`

**Target:** `third_party/SPIRV-Cross/spirv_msl.cpp` — MSL image
atomic coordinate lowering for emulated image atomics.

**Summary:** Extends the R32I/R32UI image-atomic linearization helper
from 2D-only addressing to 3D/layered addressing. `OpImageTexelPointer`
now routes 2D array, 3D, and cube/cube-array coordinates through a
height-aware linear index, and the atomic preprocessor emits the helper
for `Dim2D`, `Dim3D`, `DimCube`, and `DimRect` images.

**Why:** CTS sparse_texture2 uncommitted-region verification binds
R32I/R32UI cube, cube-array, and 3D sparse textures as storage images
and runs atomic operations through `OpImageTexelPointer`. The previous
2D-only helper left non-2D coordinates in an invalid shape for Metal's
linear atomic backing buffer, causing compute pipeline creation to fail
and surfacing as `glDispatchCompute` `GL_INVALID_OPERATION`.

**CTS tests unlocked:** Sprint 19 Phase 7.4
`KHR-GL46.sparse_texture2_tests.UncommittedRegionsAccess_texture_{cube_map,cube_map_array,3d}_r32{i,ui}`
cluster (6 tests).

### `spirv-cross-msl-shadow-grad-clamp.patch`

**Target:** `third_party/SPIRV-Cross/spirv_msl.cpp` —
`CompilerMSL::to_function_args()` shadow-compare gradient handling.

**Summary:** Keeps the existing macOS zero-gradient shadow-compare
fallback for ordinary calls, but suppresses the synthetic `level(0)`
argument when the texture operation already carries sparse feedback or
a `min_lod_clamp` operand. For GL_ARB_sparse_texture_clamp this drops
the zero gradients and lets `sample_compare` / `sparse_sample_compare`
carry the clamp operand directly.

**Why:** Metal's shadow compare overload accepts `min_lod_clamp`, but
the previous zero-gradient fallback also appended `level(0)`. In CTS
depth clamp Color paths that made `textureGradClampARB` differ from the
passing `textureClampARB` path and returned zeros for 2D, 2D-array, and
cube targets at level 0.

**CTS tests unlocked:** Sprint 19 Phase 7.5
`KHR-GL46.sparse_texture_clamp_tests.SparseTextureClampLookupColor_*_depth_component16`
depth cluster under temporary sparse_texture_clamp advertisement (8/8
after pairing with the AppGL clamp-depth sizing gate).

### `spirv-cross-msl-tcs-output-classification.patch`

**Target:** `third_party/SPIRV-Cross/spirv_msl.{hpp,cpp}` — adds
`msl_options.split_tcs_outputs_by_consumption`, an optional `name`
field on `MSLShaderInterfaceVariable`, and the
`CompilerMSL::classify_tcs_outputs_by_consumption()` method.

**Summary:** When `split_tcs_outputs_by_consumption=true` on a TCS
translation, classifies each user-varying output as TES-consumed (kept
in the per-CP device buffer that the linked TES reads) or TCS-internal
(routed to **threadgroup memory** instead, invisible to the TES). The
classification is name-based: a TCS output is TES-consumed iff its
name appears in the `outputs_by_location` / `outputs_by_builtin` maps
that AppGL's β orchestrator populates via `add_msl_shader_output(tcs,
{... name=<TES_input_name> ...})` for each TES input. Names are the
stable cross-stage identifier — separable programs auto-assign
locations per-stage independently, so location alone is unreliable.

**Why:** Metal has no native tessellation control shader stage; TCS is
emulated as a compute kernel with the per-CP output landing in a
device buffer the linked TES then reads. SPIRV-Cross's existing
emission stuffs ALL TCS outputs into that device buffer — including
outputs the TCS uses purely for `barrier()`-mediated inter-invocation
sync that the TES never reads. This bloats per-CP buffer stride with
TCS-internal data and breaks byte-offset alignment between TCS-out and
TES-in for non-block standalone outputs (e.g. `out ivec4
test_vector[4]; barrier(); ... = test_vector[next].xyz`).

Threadgroup memory is the natural Metal home for inter-invocation sync
data: doesn't leak into the device buffer, doesn't bloat per-CP
stride, exists for the lifetime of the workgroup which matches a TCS
patch. The patch leverages SPIRV-Cross's existing `mask_stage_output_*`
infrastructure plus the `variable_decl_is_remapped_storage(StorageClassWorkgroup)`
plumbing to route TCS-internal outputs to threadgroup memory at
emission time. No new emission code paths required — the classifier
synthesizes a high-range Location decoration on each non-consumed
output and calls `mask_stage_output_by_location`, which the existing
`is_stage_output_variable_masked` checks at five emission sites
(struct membership, address-space decoration, access-chain rewrite,
function-parameter pass-through, etc.) all consult correctly.

**Implementation note — synth-fake dedup:** the classifier also
removes `outputs_by_location` entries whose name matches a natural TCS
output. This prevents the synth-fake-variable loop at
`spirv_msl.cpp:4682` from materializing opaque `uint4 m_<N>` padding
members when AppGL's β passes a name that the TCS already writes
under a different (auto-assigned) location. Without this dedup, the
m_<N> members displace the natural-output struct layout (observed in
the original failing tests as offset corruption — TES read
`tc_primitive_id` finding `float-1.0-bits` from a synth-fake at
offset 0).

**Use case:** separable-program tess pipelines where the TCS uses
`out` arrays + `barrier()` for inter-invocation coordination —
specifically CTS `tessellation_shader_tessellation.{
barrier_guarded_read_calls, barrier_guarded_read_write_calls,
input_patch_discard }` cluster (3 tests). Without the option, these
tests fail with byte-offset misalignment between TCS-out and TES-in;
with the option, TCS main0_out shrinks from 48B (test_vector +
test_vector2 + m_91 padding) to 16B (test_vector2 only) — exact match
for TES main0_in.

**CTS tests unlocked:** +3 (the tc_barriers + input_patch_discard
cluster). Potentially also unblocks AppGL-W's previously-attempted
discard-fix once the underlying byte-alignment is corrected.

**Regression-safe:** when the option is off (default), classifier
returns early at `if (!is_tesc_shader() ||
!msl_options.split_tcs_outputs_by_consumption) return;` — no
masked-output-locations modifications, no behavioural change. Verified
byte-identical TCS emission for `data_pass_through` (cluster A, B, C
representatives) before vs after the patch (modulo a pre-existing
4-line buffer-slot-remapping difference between local CLI and AppGL
runtime invocation, unrelated to this patch). The flag-on path only
fires when AppGL passes consumed names via the new `name` field on
`MSLShaderInterfaceVariable`; absent names, classifier returns early
on `consumed_names.empty()` — defensive behaviour for transitional
AppGL state.

**Architectural narrative:** publication-track material — Metal
doesn't have TCS, but it has threadgroup memory; this option teaches
SPIRV-Cross to use the right Metal storage class per output usage
rather than uniformly stuffing everything into the per-CP device
buffer.

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

### `spirv-cross-msl-geometry-shader-as-mesh.patch`

**Target:** `third_party/SPIRV-Cross/main.cpp`, `spirv_msl.{hpp,cpp}` —
adds `msl_options.geometry_shader_as_mesh`, `--msl-geometry-shader-as-mesh`
CLI flag, GS topology classification (triangle / line / point) into the
mesh-shader emission infrastructure, and OpEmitVertex / OpEndPrimitive /
OpStore intercepts that route geometry-shader source into the existing
`is_mesh_shader()` emission paths. Companion fixtures:
`tools/gs-as-mesh-input.geom` (synthetic GS exercising EmitVertex +
EndPrimitive + per-primitive `gl_Layer`), `tools/gs-as-mesh-hand-target.metal`
(hand-authored target MSL for design validation), and
`tools/msl-gs-as-mesh-test.cpp` (standalone unit test asserting flag-OFF
preservation and flag-ON mesh-shader markers).

**Apply order:** layer this patch on top of
`spirv-cross-msl-tcs-output-classification.patch` (the cumulative
Sprint 1 snapshot — already includes earlier `tes-as-compute`,
`tess-isolines-compute-bypass`, and `msl-interface-introspection`
content) plus `spirv-cross-cli-tese-as-compute-flags.patch`. Forward
re-apply on a clean SPIRV-Cross HEAD checkout: TCS classification →
CLI tese flags → this patch. Verified `git apply --check` and `git apply
--reverse --check` rc=0.

**Summary:** Translates a SPIR-V geometry shader (ExecutionModelGeometry)
into a Metal `[[mesh]] void main0(...)` function instead of the
upstream's non-functional vertex-form emission that leaves literal
`EmitVertex();` / `EndPrimitive();` calls (Metal has no such intrinsics).
Each GS invocation maps to one mesh threadgroup with a single thread.
`OpEmitVertex` becomes `++spvVertexIndex;` (after the OpStore intercept
populates `spvVertices[spvVertexIndex].MEMBER`); `OpEndPrimitive` writes
the strip's triangle / line / point indices into `spvMesh.set_index(...)`,
flushes any latched per-primitive output struct via
`spvMesh.set_primitive(spvPrimitiveIndex, spvCurrentPrim)`, and
increments the primitive counter. Function exit flushes
`spvMesh.set_primitive_count(spvPrimitiveIndex)` and copies the
function-local `spvVertices` buffer into `spvMesh.set_vertex(...)`.

**Component breakdown:**

1. **Topology classification (`is_mesh_shader()` extension + entry attr):**
   `is_mesh_shader()` recognizes ExecutionModelGeometry under the flag,
   so the existing mesh-shader emission paths fire for GS source. Entry
   attribute switches from `kernel void` to `[[mesh]]`. The GS
   `OutputTriangleStrip` / `OutputLineStrip` / `OutputPoints` execution
   modes select Metal's `topology::triangle` / `topology::line` /
   `topology::point`, and `max_vertices` drives `MAX_V` /
   `max_primitives` parameters of the `mesh<...>` template.

2. **Counter + buffer synthesis (`fixup_hooks_in`):** Function preamble
   declares `spvVertexIndex`, `spvPrimitiveIndex`, the
   `spvUnsafeArray<spvPerVertex, max_vertices> spvVertices` capture
   buffer, the optional `spvPerPrimitive spvCurrentPrim` per-primitive
   latch, and zero-init function-locals for each Input variable that
   the body references (`gl_in[]`, `in_color[]`, etc.).

3. **OpStore intercept:** When the body writes a global Output (per-vertex
   `gl_Position`/user-varyings or per-primitive `gl_Layer`/
   `gl_ViewportIndex`/`gl_PrimitiveID`), redirect the store to
   `spvVertices[spvVertexIndex].MEMBER` or `spvCurrentPrim.MEMBER`.
   Per-primitive vs per-vertex routing comes from a
   `DecorationPerPrimitiveEXT` synthesis sub-pass that tags the GS's
   per-primitive builtin outputs (since GLSL geometry shaders don't
   carry that decoration; only mesh shaders do).

4. **Function-exit flush (`fixup_hooks_out`):** Trailing
   `spvMesh.set_primitive_count(...)` + `for (vi=0; vi<spvVertexIndex;
   ++vi) spvMesh.set_vertex(vi, spvVertices[vi]);` copies captured
   per-vertex output into the mesh.

5. **Input-element type extraction:** Walks Input-storage variables and
   uses `get_variable_element_type(var)` (peels both pointer and array
   from the SPIR-V variable's pointer type) so `type_to_glsl(element)`
   returns the bare element-type name suitable as a `spvUnsafeArray`
   template parameter, without the over-decorated `thread T*` form
   `type_to_glsl` produces for raw input variables.

6. **`spvMeshSizes` gate:** Native mesh shaders use a threadgroup
   `spvMeshSizes` counter populated by `OpSetMeshOutputsEXT`; GS-as-mesh
   tracks via function-local `spvVertexIndex`/`spvPrimitiveIndex`
   instead, so the `spvMeshSizes` declaration is gated off in GS-as-mesh
   mode to eliminate dead-variable warnings.

**Why:** Metal has no native geometry shader stage. Apple has a Metal
mesh shader execution model (Metal 3+, Apple GPU family 7+) that can
faithfully express GS semantics — per-invocation variable-vertex-count
emission, per-primitive output, dynamic primitive count — through a
different but functionally-equivalent API surface
(`spvMesh.set_vertex`/`set_primitive`/`set_primitive_count`). Without
this patch, the AppGL OpenGL→Metal translation layer rejects every GS
source; with it, GS programs validate and run on chips with mesh-shader
support, with a runtime-capability fallback to a CPU GS interpreter on
chips that lack support.

**MVP scope (Step 2):** triangle in/out + EmitVertex/EndPrimitive +
per-primitive `gl_Layer` exercised end-to-end on a synthetic GS through
the validation pipeline (glslc → SPIR-V → spirv-cross →
`xcrun -sdk macosx metal -c` rc=0 → 3 unused-`threadgroup`-variable
warnings only, zero errors). Standalone unit test
`tools/msl-gs-as-mesh-test.cpp` asserts 10 properties across flag-OFF
(upstream behaviour preserved) and flag-ON (mesh-shader markers
present, EmitVertex literal absent) — passes 10/10.

**Path J' Option E.4 (gate 21 — explicit-flag-gated emission opt-in after CKPT39 rig-vs-integration symmetry violation):**
extends Option E.3's `MemberSorter::InsertionOrderThenLocationThenBuiltInType`
aspect with a new option flag `msl_options.input_emission_in_call_order`
that opts in to call-order emission, and widens E.3's recording side
from synthetic-range-only to ALL non-empty-name `add_msl_shader_input`
calls (Class 2A uniform discipline).

**CKPT39 finding — rig-vs-integration symmetry violation:** E.3's
standalone test rig (`tools/msl-cross-stage-order-test.cpp`) used
`synth_loc = 0xE0000000u` uniformly to register every entry in
synthetic range, demonstrating clean permutation behavior — but
AppGL-W's β orchestrator (`src/shader/ShaderTranslator.cpp:856-858`)
only escalates to synthetic-range when the TCS sibling LACKS a
Location decoration. When TCS has explicit `layout(location=N)`
qualifiers (the typical case — separable programs auto-assign
locations, monolithic programs preserve them), the orchestrator
passes natural-range locations. E.3's recording was synthetic-
range-gated, so it captured 0% of typical production calls; the
insertion-order list stayed empty, the new aspect never engaged,
emission fell through to LocationThenBuiltInType — and the
identical CKPT34 field-order mismatch persisted on the production
`tc2te.gl_in` integration path despite E.3 standalone PASS.

**Methodology contribution — §3.6 rig-vs-integration symmetry:**
standalone rigs MUST cover the production caller's call shape as a
GATING criterion, not as a separate confirmation step. Any
divergence between rig call shape (range, options, sequence,
pipeline stage) and integration call shape is a validation gap that
will surface as integration failure regardless of how many rig
permutations pass. E.4's rig adds explicit "natural-range +
flag-ON" + "natural-range + flag-OFF" scenarios alongside the
original synthetic-range scenarios, mirroring both the AppGL
production caller (natural-range + flag-ON) and the back-compat
public-API caller (natural-range + flag-OFF).

**Why a flag (vs unconditional widening of emission):** the public
C API `spvc_compiler_msl_add_shader_input` is used by upstream
consumers (MoltenVK, vkd3d-proton). Unconditional widening of the
emission aspect would change struct member order for every consumer
that registers inputs via this path, regardless of whether they
expected call-order emission. The flag makes the new behavior
explicit opt-in. AppGL fork orchestrators set the flag; non-AppGL
consumers don't, preserving `LocationThenBuiltInType` emission.

**Recording-vs-emission split (Class 2A vs Class 2C):**
- Recording (Class 2A — uniform): every non-empty-name
  `add_msl_shader_input` call appends to
  `inputs_by_location_insertion_order`, regardless of synthetic-
  range or flag. Recording is observably a no-op when emission is
  flag-gated off. The Class 2A discipline of "no consumer
  coordination required for the uniform side" holds — the recording
  itself doesn't change behavior.
- Emission (Class 2C — flag-gated): the new sort aspect engages
  only when `msl_options.input_emission_in_call_order == true`
  AND `storage == StorageClassInput` AND list non-empty. The
  flag is the explicit consumer-coordinated opt-in, replacing
  E.3's implicit synthetic-range gate that turned out to be
  non-representative of production callers.

**AppGL-W integration coordination:** the β orchestrator at
`src/shader/ShaderTranslator.cpp` needs to set
`mslOpts.input_emission_in_call_order = true` before calling
`compiler.set_msl_options(mslOpts)` on the TES compile path
(canonical spot: alongside the existing `mslOpts.raw_buffer_tese_input
= true` at line 449). The `add_msl_shader_input` calls that follow
at line 889 then populate the insertion-order list during compile
preamble; MemberSorter consults it at the `add_interface_block`
sort step. No changes needed to the orchestrator's call-side
logic — the natural-range + synthetic-range hybrid pattern at
lines 856-858 is exactly what E.4 supports.

**CLI flag:** `--msl-input-emission-in-call-order` for testability.
Off by default; when set, the spirv-cross CLI passes
`input_emission_in_call_order = true` through.

**Validation matrix (rig-vs-integration symmetry baked in):**
- `tools/msl-cross-stage-order-test.cpp` asserts 9 properties via
  the CKPT34 fixture pair across 6 wiring scenarios:
  1. synthetic-range + flag-ON, forward order → matches TCS-out
  2. synthetic-range + flag-ON, REVERSED → tracks call sequence
  3. natural-range + flag-ON, forward → matches TCS-out
     **(PRODUCTION-CALLER SHAPE)**
  4. natural-range + flag-ON, REVERSED → tracks call sequence
     **(PRODUCTION-CALLER SHAPE)**
  5. natural-range + flag-OFF, forward → LocationThenBuiltInType
     emission (BACK-COMPAT for non-AppGL consumers)
  6. natural-range + flag-OFF, REVERSED → STILL Location-ascending
     (BACK-COMPAT — call order does NOT override flag-OFF emission)
- GS standalone rig (`msl-gs-as-mesh-test`): 25/25 PASS × 3
  fixtures unchanged
- Cross-stage probe rigs unchanged (don't set the flag, no
  behavior change)

**Path J' Option E.3 (gate 20 — orchestrator-driven main0_in emission order via MemberSorter):**
extends the input-interface emission pipeline so the orchestrator's
`add_msl_shader_input` call sequence becomes the authoritative
cross-stage member layout. CKPT34 surfaced: monolithic-program TES
emits `main0_in` members in TES-IR-walk order followed by a
`MemberSorter::LocationThenBuiltInType` pass; the resulting struct
order can disagree with TCS-out struct order even when both stages
share natural locations, breaking byte alignment when TES reads
the cross-stage buffer. Specifically, AppGL-W's β orchestrator
observed `TCS out_uint(5)/out_struct(8) vs TES out_struct(5)/out_uint(6)`
on `tc2te.gl_in` — TES's ad-hoc IR ordering placed `out_struct`
before `out_uint`, but TCS-out had laid them out the opposite
way, so a TES read at offset 5 hit struct bytes instead of the
expected uint.

**Implementation — single source of truth via MemberSorter:**

A new persistent member `inputs_by_location_insertion_order` (a
`std::vector<std::string>`) records names appended at
`add_msl_shader_input` call time, gated on synthetic-range
location (`>= 0xE0000000`). Recording happens BEFORE the Path J'
Option A1 dedupe `return` so that even when a synthetic-range
call dedupes against an existing natural entry, the orchestrator's
intended emission position is captured.

A new `MemberSorter::SortAspect`,
`InsertionOrderThenLocationThenBuiltInType`, is selected by
`add_interface_block` when `storage == StorageClassInput` and the
insertion-order list is non-empty. The comparator orders builtins
to the end (matching `LocationThenBuiltInType`), then non-builtins
in three tiers:

1. Both names appear in `insertion_order` → compare positions.
2. Exactly one name appears → that one wins (orchestrator-tracked
   members come before untracked).
3. Neither appears → fall through to location-then-component
   (preserves existing behavior for entries the orchestrator
   didn't touch — typical for fragment-output mask members or
   builtin-absorbed entries).

**Why MemberSorter (not vars[] reorder):** an earlier draft applied
a pre-sort vars[] reorder in the IR-walk path plus a
supplementation-walk reorder. Both were correctly producing
ordered vars[]/iteration sequences, but the post-emission
`MemberSorter` pass at `spirv_msl.cpp:5150` re-sorted by Location
ascending, undoing the pre-sort work. MemberSorter is the
authoritative ordering pass; the clean fix is to extend
MemberSorter rather than fight it. The `vars[]` and supplementation
walks now run in their original (map-key/IR-ID) order; correct
emission order is restored at the MemberSorter call site.

**Class candidacy — paired Class 2A + 2C:**

- **Class 2A side** (preamble-time uniform record): the
  `add_msl_shader_input` call hook records EVERY synthetic-range
  call regardless of whether the entry survives Option A1's
  add-time dedupe. The orchestrator's intent is "emit this name
  at this position" — which is independent of whether the
  synthetic-keyed map entry itself sticks around or gets deduped
  against a natural-loc entry.
- **Class 2C side** (range-gated emission): the new SortAspect
  fires only when `inputs_by_location_insertion_order` is
  non-empty AND `storage == StorageClassInput`. Default-empty
  consumers (anyone not calling `add_msl_shader_input` with
  synthetic-range locations) see zero behavior change.

The pair-class diagnosis follows the §3.6.6 "producer +
consumer" pattern banked from earlier sprints (Path L paired
2A + 2C, Path I synthesis paired 2A + 2C). Three-step decision
tree:
1. **Empirical vs spec?** Empirical — Metal struct layout drives
   byte offset, no spec mandate on emission order.
2. **Single sub-class vs paired?** Paired (registration side +
   emission side both load-bearing, neither sufficient alone).
3. **Identify complementary sub-classes:** 2A (uniform record at
   `add_msl_shader_input`) + 2C (range-gated emission via
   `MemberSorter`).

**Methodology contribution — single-source-of-truth ordering:**
when post-processing passes (sort, dedupe, normalize) re-establish
canonical order downstream of intermediate work, mid-pipeline
reorders are dead weight that a downstream pass undoes. The right
intervention point is the canonical pass itself. Identifying the
single source of truth before authoring multi-site fixes is the
discipline. (For E.3, this realization came after a probe rig
showed `vars[]` was correctly reordered yet emission still in
location-ascending order — the diagnostic chain was: probe FAIL →
add debug prints → confirm reorder applied → trace emission to
MemberSorter → recognize MemberSorter as authority → discard
mid-pipeline reorders → extend MemberSorter.)

**Validation:** standalone test `tools/msl-cross-stage-order-test.cpp`
asserts 7 properties via the CKPT34 fixture pair (TCS-out
`{out_uint, out_vec3}`, TES with reverse declaration order). Two
exercises: (a) register in TCS-out order → TES emission matches
TCS-out order; (b) register in REVERSED order → TES emission
permutes to match the reversed call sequence. The permutation
test is load-bearing — it proves the orchestrator's call order
can override IR-walk order in either direction. Existing GS
fixtures (`gs-as-mesh-input.geom`, `gs-as-mesh-iface-block.geom`,
`gs-as-mesh-no-position.geom`) and the cross-stage probe rigs
(`msl-cross-stage-probe`, `msl-cross-stage-probe-tcs-to-tes`,
`msl-split-tcs-test`) all run regression-clean — they don't call
`add_msl_shader_input` with synthetic-range locations, so their
insertion-order list stays empty and emission falls through to
the original `LocationThenBuiltInType` aspect.

**Path J' Option E.2 (gate 19 refinement — relax Pass 1 Location-decoration gate):**
widens Option E's Pass 1 to capture natural Input variable NAMES
regardless of OpDecorate Location presence. CKPT31 surfaced:
monolithic-program TES inputs may have a name but lack
OpDecorate Location — linkers don't always emit explicit Location
decorations for inputs whose location is implicit from cross-stage
linkage. Option E's narrow gating (`if (!has_decoration ...)
return;`) skipped these entries, so Pass 3's dedupe iterated 0
matches and synthetic-range duplicates survived into main0_in.

**Refinement:** Pass 1 now tracks two structures —
`natural_with_loc` (only Location-decorated entries, used by Pass 2
for map population) and `natural_names` (full name set, used by
Pass 3 for dedupe). Un-decorated natural entries can't form a
valid `inputs_by_location` map key (no location), so Pass 2 still
gates on Location decoration. But Pass 3's name-based dedupe now
matches against the full name set, catching synthetic-range
duplicates that share a name with un-decorated natural entries.

**Implementation — chosen design (transient name-set):**

Of the three options (variable-ID-as-location, separate
`inputs_by_name` map, hash-synthesized location key), the chosen
design uses a transient name-set local to the helper. Avoids:
- Variable-ID collision risk (variable IDs aren't in the
  synthetic-range convention; using them as location keys would
  collide with natural locations).
- Separate persistent map (more invasive plumbing through dedupe
  logic).
- Hash collision risk (synthesized keys could collide for
  same-name-different-id natural entries).

The transient set is local to `pre_populate_inputs_by_location_from_ir()`
and disappears when the helper returns; persistent state in
`inputs_by_location` is unchanged in shape.

**Class 2A spec-compliance refinement** — same class as Option E
(uniform applicability, no consumer coordination required). The
`add_msl_shader_input` API surface is still unchanged.

**Path J' Option E (gate 19 — pre-populate `inputs_by_location` from natural emission):**
walks SPIR-V Input variables at `compile()` preamble (before
`add_interface_block(StorageClassInput)` consumes the map),
populates `inputs_by_location` with each natural Input variable's
`{location, component, name}`, then dedupes any synthetic-range
entry (location ≥ `0xE0000000`) whose name matches a natural-range
entry.

**Why Option E in addition to Option A1:** Option A1 (`fce60f8`)
fires the synthetic-range dedupe at `add_msl_shader_input` call
time. But the typical flow is consumers register synthetic-range
entries BEFORE compile() — at which point the map is empty (no
natural entries yet) so Option A1's dedupe doesn't fire. CKPT30
diagnosed this: "natural-emission pipeline does NOT pre-populate
inputs_by_location from SPIR-V Input variables." Option E
addresses the order issue: pre-populating at compile() time makes
the map canonical, then the dedupe pass removes synthetic-range
duplicates that Option A1 missed.

The combined Option A1 + Option E covers both registration orders:
- Consumer registers synthetic-range entries → compile() runs →
  pre-populate natural + dedupe synthetic-range (Option E catches it).
- Consumer compile() runs first (e.g., orchestrator inspecting the
  IR), then registers synthetic-range entries → Option A1's
  add-time dedupe sees the natural entries pre-populated by
  Option E.

**Implementation — 3-pass helper:**

1. **Pass 1**: walk SPIR-V Input variables, gather natural-range
   entries (location < 0xE0000000) with names. Skip builtins (handled
   separately by `inputs_by_builtin`) and entries without
   Location decoration.
2. **Pass 2**: populate `inputs_by_location` with natural entries
   (only if absent — preserves richer API-registered entries).
3. **Pass 3**: dedupe synthetic-range entries whose names match
   natural entries — natural is canonical.

**Class 2A spec-compliance** — uniform-applicability default-on,
no consumer coordination required. The `add_msl_shader_input` API
surface is unchanged; consumers calling it get the same behavior;
consumers not calling it now have natural entries populated for
downstream coordination. Class 2A discipline (vs. Class 2C used
by Option A1) reflects the broader applicability — Option A1 was
gated on synthetic-range location at add-time; Option E
unconditionally pre-populates natural entries.

**Path J' Option A1 (gate 18 — synthetic-range dedupe by name in `add_msl_shader_input`):**
extends `add_msl_shader_input` with a name-dedupe check gated on
synthetic-range location keys. AppGL fork orchestrators (and other
cross-stage emission consumers) use synthetic-range location values
(`>= 0xE0000000`) to disambiguate type collisions on natural
location — e.g., when multiple TES inputs naturally collide at
location 0 component 0 because the linked TCS auto-allocates them.
When the orchestrator passes the same NAME with both a natural-range
location AND a synthetic-range location to drive cross-stage matching,
the unguarded keying on `{location, component}` would create two
map entries with identical names; main0_in would then emit
duplicate-name members, violating GLSL/SPIR-V spec uniqueness
constraints and breaking cross-stage linkage.

**Fix:** when adding an entry whose location is in the synthetic-key
range AND whose name matches any existing entry in
`inputs_by_location` (regardless of that entry's location range),
skip the add. The natural-range entry remains the canonical
interface member. Synthetic-range entries with NEW names continue
to add normally — only same-name dupes are filtered.

**Class 2 spec-compliance, default-on**, no flag-gating. The
synthetic-range gating provides the safety: non-synthetic-range
entries are unaffected (preserves the `{loc, comp}`-keyed API
behavior for consumers that don't use synthetic-range
disambiguation). Inverse cases — different name in synthetic range,
same name in natural range with same loc — are handled correctly:
synthetic-different-name preserves new entry; natural-same-loc
overwrites by `{loc, comp}` key as before.

**Cross-project upstream-ability** (foresight side-benefit per
user's Sprint 4 (c.1) discipline): the synthetic-range threshold
(`0xE0000000u`) is a forking-fork-friendly convention; cross-project
consumers using synthetic-range location keys for any
disambiguation purpose get the dedupe automatically.

Validation:
- Default behavior unchanged for non-synthetic-range entries
  (regression-safe — existing `{loc, comp}` keying preserved).
- Existing fixtures (gs-as-mesh, gs-no-position, gs-iface-block,
  spv_lr/, tcs-write-tess) all xcrun rc=0 post-patch.
- `add_msl_shader_input` exhibits the dedupe behavior empirically:
  passing same name with natural + synthetic-range locations
  results in only the natural-range entry being kept.

**Path L extension (gate 17 dual-write — TCS-side full-precision write):**
extends Path L's TES-side reads with TCS-side writes. The TCS-compute
kernel already computes full-precision tess factor values; with the
extension, those values are written to BOTH the existing
half-precision `spvTessLevel` (Metal HW tessellator API) AND the
new `spvTessLevelFull` shadow buffer (TES read source).

**Why extension:** AppGL-W's deeper analysis revealed that
host-side population of `spvTessLevelFull` from GL uniform state is
fragile (test-specific uniform-name matching). TCS-side dual-write
eliminates the host-side coordination — the TCS-compute kernel
produces the full-precision values during its own computation;
dual-writing them to the shadow buffer in addition to the
half-precision API is the cleaner fix.

Implementation:
- TCS-compute entry signature: when flag set, also add
  `device float* spvTessLevelFull [[buffer(N)]]` parameter
  alongside the existing
  `device MTLQuadTessellationFactorsHalf* spvTessLevel`. Same slot
  for read/write coherence — TCS writes and TES reads use the same
  buffer in the same pipeline cycle.
- OpStore intercept (in `CompilerMSL::emit_instruction` after
  the standard half-precision write): when target is
  BuiltInTessLevelOuter or BuiltInTessLevelInner Output and the
  flag is set, emit additional
  `spvTessLevelFull[primId * stride + offset] = float_val;`. Index
  extracted by string-parsing the resolved LHS expression for the
  well-defined tess-level access patterns.
- Same per-domain stride logic (4 / 6 / 2) and outer-then-inner
  layout as TES-side reads.

Validated:
- Default-off TCS emission: byte-identical to pre-extension (no
  `spvTessLevelFull` references when flag off).
- Flag-on TCS emission: dual-writes for outer (4 quads), outer
  (3 triangles), inner (2 quads or 1 triangle scalar). All paths
  xcrun rc=0.
- Flag-on TES read side: still works correctly (Path L original).

**Path L (gate 17 — TES-as-compute full-precision tess level shadow buffer):**
adds `msl_options.use_full_precision_tess_level_buffer` (CLI:
`--msl-use-full-precision-tess-level-buffer`) +
`msl_options.shader_tess_factor_buffer_full_index` (CLI:
`--msl-tess-factor-buffer-full-index <N>`, default 23). When the
flag is set, TES-as-compute emission for `gl_TessLevelOuter` /
`gl_TessLevelInner` reads from a `device const float*` shadow
buffer at the configured slot instead of from Metal's
half-precision `MTLQuadTessellationFactorsHalf` /
`MTLTriangleTessellationFactorsHalf` API (member access via
`.edgeTessellationFactor[k]` / `.insideTessellationFactor[k]`).

**Why:** per GL 4.6 §11.2.2, outer/inner tess level values are
float; CTS validates with float precision. Metal's half-precision
API truncates information at write time (CKPT25 Option B
elimination demonstrated the lossy-write). Full-precision shadow
buffer preserves the float precision the CTS expects.

**Buffer layout** (per primitive, stride depends on domain):
- triangles: 4 floats = 3 outer + 1 inner
- quads: 6 floats = 4 outer + 2 inner
- isolines: 2 floats = 2 outer + 0 inner

Outer levels first, then inner levels per primitive. Read pattern:
`spvTessLevelFull[gl_PrimitiveID * stride + index]`.

**Flag-gated** (not default-on under `tess_evaluation_as_compute`)
because consumers must provide the shadow buffer infrastructure
at the documented slot. Default-off preserves byte-identical
emission for existing consumers without shadow buffer support.

**Half-precision parameter remains in the entry signature** when
the flag is on — preserves AppGL/MoltenVK runtime parameter-binding
compatibility for callers that haven't migrated. The reads in
`add_tess_level_input` redirect to the full-precision buffer when
the flag is on; the half-precision parameter becomes unused (Metal
warns but compiles).

**Cross-project upstream-ability** (per user's "public benefit"
mandate): MoltenVK has the same Metal half-precision constraint
on Vulkan tess factor precision. The patch shape is upstream-able
to Khronos SPIRV-Cross — clean separation of concerns (Path L is
purely TES-compute emission), spec citation
(GL 4.6 §11.2.2 / VK_KHR_portability_subset analogous), test rig
assertions demonstrate the documented contract being honored,
buffer slot documented for consumer-side coordination.

Test rig adds Path L conditional regression-guard assertion (fires
when the optional second SPIR-V argument compiles as a TES with
full-precision tess level reads — checks
`device float* spvTessLevelFull` parameter presence + reads use
that buffer).

**Path K (gate 16 — TES-as-compute `gl_PatchVerticesIn` runtime parameter source):**
TES emission for `tess_evaluation_as_compute + raw_buffer_tese_input`
previously hardcoded `uint gl_PatchVerticesIn = N;` using
`get_entry_point().output_vertices` as the literal — but
`output_vertices` is the linked TCS's `layout(vertices = N) out;`
declaration, which isn't encoded on the TES side of the link, so the
literal evaluated to 0. Every gl_PatchVerticesIn read in the TES
body returned 0; bounds-check / count-driven code paths universally
short-circuited.

**Fix:** read from `spvIndirectParams[0]` (the runtime indirect-
parameters buffer slot 0), populated by the host with the linked
TCS's `output_vertices` value at dispatch time. The
spvIndirectParams parameter is already in the TES-as-compute entry
signature (added at spirv_msl.cpp:15670 for
`capture_output_to_buffer && !VS-for-tess`), so no new parameter
plumbing required — just change the literal initialization to a
runtime read.

**Compile-time override path preserved:** if
`msl_options.tese_input_patch_vertices` is set non-zero (Sprint 1
override), emit it as a literal instead of the runtime read. AppGL
fork callers can pin compile-time when the linked TCS's value is
known statically; default 0 means runtime.

Default-on under `tess_evaluation_as_compute + raw_buffer_tese_input`
(Class 2 spec-compliance, no flag-gating). Spec citation:
GL 4.6 §8.5.4 (gl_PatchVerticesIn) — value is the input patch
vertex count from the linked TCS, not the TES's own declaration.

Companion CLI flag `--msl-tese-input-patch-vertices <count>` (added
in Sprint 1) provides the compile-time override for callers without
a runtime indirect-parameters buffer.

**Path I (gate 15 — interface-block GS input member population):**
extends the Path A population loop to handle user-defined block
member writes alongside the existing builtin block member handling.

**Diagnosis (CKPT19):** GS source pattern with interface-block input

```glsl
layout(location = 0) in VS_GS {
    vec4 v1;
    vec4 v2;
} iface[];
```

Pre-Path I, the population loop ONLY handled builtin block members
(gl_Position/gl_PointSize/gl_ClipDistance/gl_CullDistance). The
function-local `spvUnsafeArray<VS_GS, 3> iface;` was declared but
NEVER populated for `iface[i].v1` / `iface[i].v2` reads — the body
read uninitialized array values, producing garbage user varyings,
which the rasterizer interpreted as degenerate or off-viewport
triangles. Result: zero rasterized output despite clean xcrun rc=0
+ clean dispatch.

**Fix:** add an else-branch in the block-member iteration that
maps user-defined block members to their flattened main0_in field
names. SPIRV-Cross's interface-block-flattening convention is
`<var_name>_<block_member_name>`:

```cpp
else  // user-defined block member
{
    std::string block_mbr_name = to_member_name(element_type, m);  // "v1"
    std::string main0_in_field = name + "_" + block_mbr_name;       // "iface_v1"
    statement(name, "[spvVI].", block_mbr_name,
              " = spvVsIn.", main0_in_field, ";");
}
```

Result: `iface[spvVI].v1 = spvVsIn.iface_v1;` populates the
function-local iface array correctly. Body reads
`iface[i].v1` / `iface[i].v2` resolve to populated values.

Default-on under `geometry_shader_as_mesh` (no flag — Class 2
spec-compliance). Companion fixture `tools/gs-as-mesh-iface-block.geom`
captures the GLSL pattern.

Test rig adds Path I conditional regression-guard assertion
(fires on fixtures with interface-block input — synthetic fixture
exercises this; existing `gl_pointsize_value` and synthetic
fixtures don't and skip the check).

**Phase 2.5 Gap B (gate 14 — `max_vertices > 3` strip-to-list expansion):**
extends the EndPrimitive flush emission with a strip-to-list
expansion loop for `triangle_strip` and `line_strip` outputs with
`max_vertices` beyond the simple-case threshold. Per GL §10.1.13:

- A triangle_strip of N vertices represents (N-2) triangles with
  alternating winding — even-indexed triangles use (T, T+1, T+2);
  odd-indexed use (T+1, T, T+2) so consecutive triangles share an
  edge with consistent winding.
- A line_strip of N vertices = (N-1) line segments using
  consecutive vertex pairs.

Pre-Gap B, the OpEndPrimitive emit hardcoded the simple "1 triangle
from the last 3 vertices" / "1 line from the last 2 vertices" form,
silently dropping any earlier vertices in strips of N > 3 (or N > 2
for lines). For the Phase 2 `max_vertices=3` MVP envelope this
worked. For Phase 2.5's layered_rendering tests
(`max_vertices=64-96`), the GS would emit dozens of vertices and
only the last 3 would form a triangle.

Implementation:
- New shared helper `CompilerMSL::emit_gs_as_mesh_endprimitive()`
  at spirv_msl.cpp:5249. Branches on output topology +
  `execution.output_vertices`:
  - triangle_strip with max_vertices ≤ 3: simple emit (byte-identical
    to pre-Gap B, preserves synthetic fixture rig assertions).
  - triangle_strip with max_vertices > 3: strip-to-list loop with
    even/odd winding alternation, increments spvPrimitiveIndex by
    (N-2) per strip.
  - line_strip with max_vertices ≤ 2: simple emit.
  - line_strip with max_vertices > 2: (N-1)-line expansion loop.
  - points: 1-point emit (max_vertices irrelevant).
- New function-local `uint spvStripStart = 0u;` tracker declared in
  `fixup_hooks_in` alongside `spvVertexIndex`/`spvPrimitiveIndex`.
  Updated to `spvVertexIndex` at the end of each EndPrimitive flush
  (both explicit OpEndPrimitive and Path H implicit). Strip-loop
  uses it to compute per-strip indices independent of cumulative
  vertex emission count.
- OpEndPrimitive emit and Path H implicit emit both call the
  shared helper — single source of truth for strip-to-list
  expansion logic.

Validated against all four `/tmp/spirv_lr/spv_{0002,0005,0008,0011}.spv`
layered_rendering CTS dumps (`points in / triangle_strip out /
max_vertices=64-96`) — all four xcrun rc=0 with strip expansion.
Combined with Gap C (function-local shadows for per-primitive
output reads), layered_rendering tests now have:
- Compile-validate clean (Gap C unblocked the gl_Layer reads)
- Strip-to-list expansion semantically correct per GL §10.1.13
  (Gap B handles the (N-2) triangle expansion)

Synthetic max_vertices=3 fixture: simple-case branch fires;
byte-identical to pre-Gap B emission past the new
`spvStripStart` tracker declaration.

Test rig adds a Gap B regression-guard assertion for the
`spvStripStart` tracker presence.

**Phase 2.5 Gap C (gate 13 — function-local shadows for per-primitive
Output reads):** layered_rendering GS source pattern reads back its
own per-primitive output mid-body — e.g.
`gl_Layer = i; layer_id = gl_Layer; EmitVertex();`. Pre-Gap C, the
GS-as-mesh OpStore intercept routed `gl_Layer = i;` to
`spvCurrentPrim.gl_Layer = i;` correctly, but the subsequent
`int(gl_Layer)` read emitted a bare undeclared identifier — Metal
compile failed with `error: use of undeclared identifier
'gl_Layer'`.

**Fix:** declare a function-local shadow for each per-primitive
Output member in `fixup_hooks_in` (alongside the existing
`spvPerPrimitive spvCurrentPrim = {};` declaration). The OpStore
intercept now writes to BOTH the shadow AND `spvCurrentPrim`:

```cpp
gl_Layer = i;                           // shadow write
spvCurrentPrim.gl_Layer = gl_Layer;    // propagate to per-primitive
```

Body OpLoad of `gl_Layer` resolves naturally to the shadow (a
function-local `uint gl_Layer = {};`). EndPrimitive flush still
sees the latest value via spvCurrentPrim.

Validated against all four `/tmp/spirv_lr/spv_{0002,0005,0008,0011}.spv`
layered_rendering CTS dumps (`points in / triangle_strip out /
max_vertices=64-96`) — all four xcrun rc=0 with Gap C. Pre-Gap C:
4 errors per dump. Compile path unblocked; runtime semantic
correctness for `max_vertices > 3` strips remains gated on Gap B
(strip-to-list expansion).

Test rig adds a Gap C regression-guard assertion (conditional on
GS body containing `gl_Layer = ` write — fires on synthetic GS,
skipped on fixtures without gl_Layer writes).

**Phase 2.5 Gap A (gate 12 — synthesize gl_Position Output for GS-as-mesh
shaders that don't write one):** Apple Metal's mesh-shader vertex output
type must declare a member with the `[[position]]` attribute. GLSL
geometry shaders that omit `gl_Position = ...` (TF-only / depth-only
patterns, e.g. `lines_adjacency in / line_strip out` exporting only user
varyings) compile cleanly per GL spec — gl_Position default is undefined
when not written; rasterizer reads garbage but the program is well-formed.
Mesh-pipeline emission rejects this with `error: invalid type
'spvPerVertex' for mesh vertex type / missing mesh output declaration with
attribute 'position'`.

**Fix:** new `ensure_gs_as_mesh_position_output()` helper called from the
existing GS-as-mesh pre-pass in `compile()`. Walks Output variables
checking for `BuiltIn Position` decoration at BOTH variable level
(rare standalone `out vec4 gl_Position` form) AND member level (typical
gl_PerVertex Output block form, where Position is decorated on the
struct member, not the variable itself). If absent, synthesizes a
vec4 OpVariable with `Output` storage class and `BuiltIn Position`
decoration via the standard `ir.increase_bound_by(3)` + `set<SPIRType>`
+ `set<SPIRVariable>` + `set_decoration` + `mark_implicit_builtin`
pattern (mirrors `gl_FragCoord` synthesis at line 681 area).

The body never references the synthesized variable; the function-local
`spvVertices = {}` zero-init carries (0, 0, 0, 0) through to
`spvMesh.set_vertex` at function exit. Existing `add_meshlet_block`
machinery picks up the synthesized variable via the
`for_each_typed_id<SPIRVariable>` walk and adds it to `spvPerVertex`
with the `[[position]]` attribute automatically — no further emission
changes needed.

Default-on under `geometry_shader_as_mesh` (no flag — option (b) per
Path H precedent). This is GL spec-bridging, not an empirical
mitigation. Member-level Position detection prevents duplicate
synthesis when GS source already writes gl_Position via gl_PerVertex
block (validated against the synthetic GS that DOES write gl_Position;
no duplicate `[[position]]` member regression).

Test rig adds a Gap A regression-guard assertion: spvPerVertex must
contain exactly one `[[position]]` member when GS writes gl_Position.
Total rig: 40 assertions across 7 ladder rungs (1, 2, 3, 4, 5, 7, 9).

**Path H (gate 11 — implicit EndPrimitive at GS function exit):**
implements GL 4.6 §11.3.4 spec compliance. When a GS source emits
vertices (via `EmitVertex()`) but doesn't call `EndPrimitive()`
explicitly before function exit, the spec mandates that an implicit
EndPrimitive is honored. The current GS-as-mesh emission tracks
this via a function-local boolean and emits the trailing primitive
flush at the end of `fixup_hooks_out`:

```cpp
bool spvNeedImplicitEndPrimitive = false;        // declared in fixup_hooks_in
// ...
spvNeedImplicitEndPrimitive = true;              // after each ++spvVertexIndex (OpEmitVertex)
// ...
spvNeedImplicitEndPrimitive = false;             // after each ++spvPrimitiveIndex (OpEndPrimitive)
// ...
if (spvNeedImplicitEndPrimitive)                 // at function exit, before set_primitive_count
{
    spvMesh.set_index(...);                       // same shape as OpEndPrimitive emit
    spvMesh.set_primitive(spvPrimitiveIndex, spvCurrentPrim);  // if mesh_out_per_primitive
    ++spvPrimitiveIndex;
}
spvMesh.set_primitive_count(spvPrimitiveIndex);  // reflects correct count
```

**Default-on under `geometry_shader_as_mesh`** (no flag) — this is
GL spec compliance, not an empirical mitigation. The boolean
tracker handles all combinations naturally:
- Body has explicit EndPrimitive last → tracker is false at exit → no implicit emit (no double-flush)
- Body has EmitVertex without trailing EndPrimitive → tracker is true at exit → implicit emit fires

**Why this matters:** `KHR-GL46.geometry_shader.output.primite_end_done_for_single_primitive` (and similar tests) exercise the implicit-EndPrimitive semantic. Without Path H, mesh-GS emits `set_primitive_count(0)` because `spvPrimitiveIndex` is never incremented for the dangling vertex run — zero rasterized output. Path H fixes the regression that AppGL-W's CKPT16 pixel diff surfaced.

Test rig adds 4 Path H structural-marker assertions (tracker
declaration, set-on-EmitVertex, clear-on-EndPrimitive, runtime
guard at function exit). Total rig: 39 assertions across 7 ladder
rungs.

**Path G (gate 10 — `[[grid_size]]` → `[[threads_per_grid]]` for VS-compute kernel-arg synthesis):**
adds `msl_options.force_threads_per_grid_for_stage_input_size`
(CLI: `--msl-force-threads-per-grid-for-stage-input-size`). When
set, emits `[[threads_per_grid]]` instead of `[[grid_size]]` on the
synthesized `spvStageInputSize` kernel parameter for
`vertex_for_tessellation` VS-compute kernels. Default off —
preserves byte-identical emission for the Phase-3 metal-tess
(compute → compute) path.

**The breakthrough explanation:** `[[grid_size]]` is documented as
the threadgroup-grid dimensions (the number-of-threadgroups
argument to `dispatchThreadgroups:`). On Apple Silicon under both
`dispatchThreads:` AND `dispatchThreadgroups:` it returns
`(0, 0, 0)` for these kernel signatures. AppGL-W's H14c
kernel-internal probe (write each builtin attribute to a buffer
from thread 0; inspect from outside) surfaced the value
empirically. Effect: every thread early-returns at:

```cpp
if (any(gl_GlobalInvocationID >= spvStageInputSize)) return;
//     any(>= 0) is universally true ⇒ every thread returns
```

Kernel body never runs. `cmdBuf.status` reports Completed; PSO API
queries report healthy; capture inspector shows no validation
errors. Path E (barrier) / E++ (volatile) / E+++ (atomic) were all
attempting to preserve writes from a kernel body that was never
actually executing — the elimination class never existed.

**`[[threads_per_grid]]`** is the actual thread count of the
entire grid — what bounds checks should reference for
`dispatchThreads:`-shaped dispatches. Single-attribute change;
all downstream code (gl_GlobalInvocationID and the rest)
unaffected.

Test rig adds rung-9 silent-attribute-value-zero-failure
assertions: presence-when-Path-G-on (`threads_per_grid`),
absence-when-Path-G-on of `[[grid_size]]` (mutual exclusion), and
presence-when-default of `[[grid_size]]` (tess-default invariant
regression guard). 3 new asserts; total rig: 35 assertions across
7 ladder rungs (1, 2, 3, 4, 5, 7, 9).

**Methodology contribution (publication-prep §3.6.4 ladder, rung 9):**
silent attribute-value-zero failures. When a Metal builtin
attribute returns 0 instead of its expected value, every guard
pattern referencing it fires universally and silently no-ops the
kernel. External tools cannot see this failure mode; only
kernel-internal probing reveals the broken attribute. The H14c
diagnostic primitive — write each Metal builtin attribute to a
buffer from thread 0 + inspect from outside — is the durable
methodology artifact for this gap class.

**Path E+++ (gate 9 escalation — `atomic_store` on spvOut + execution probe):**

Two new flags that pair together (or run independently) for the
post-volatile mitigation tier and the execution-flow diagnostic:

1. **`force_compute_kernel_atomic_writes_on_spvOut`** (CLI:
   `--msl-force-compute-kernel-atomic-writes-on-spvOut`). At kernel
   exit, walks `main0_out`'s members and emits per-scalar
   `atomic_store_explicit` re-stores via raw uint reinterpret:

   ```cpp
   atomic_store_explicit(
       &((device atomic_uint*)&out.gl_Position)[0],
       ((device uint*)&out.gl_Position)[0],
       memory_order_relaxed);
   ```

   For vec/array container types, takes the address of the whole
   container and offsets by uint slot — bypasses MSL's
   address-of-vector-element restriction AND `spvUnsafeArray`'s
   missing `volatile device` operator[] overload uniformly. Atomic
   stores are contractually non-eliminable per Apple's MSL spec,
   so this is the strongest mitigation in the Path E ladder.
   `memory_order_relaxed` keeps overhead low (no cross-thread
   ordering implied; only the non-eliminability property matters).

2. **`force_compute_kernel_entry_counter_probe`** (CLI:
   `--msl-force-compute-kernel-entry-counter-probe`, with
   `entry_counter_buffer_index` defaulting to 27). Adds a
   `device atomic_uint* spvKernelEntryCounter [[buffer(27)]]`
   parameter and emits `atomic_fetch_add_explicit(...)` increment
   in the kernel preamble. AppGL-W's runtime reads the counter
   post-`waitUntilCompleted` to definitively answer "did the
   kernel body execute" — distinguishing AIR-elimination
   escalation territory (kernel runs, writes lost) from
   different-layer characterization (kernel didn't run; binding
   or resource issue at the encoder/driver layer).

**Why E+++ instead of E++:** AppGL-W's Phase 2 Checkpoint 11pp
readback diagnostic with both Path E + E++ flags ON proved
empirically that `volatile` qualifier alone is insufficient against
AIR cross-encoder-family elimination — every byte of the Private
buffer preserved the `0xCC` pre-fill sentinel despite spec-mandated
volatile preservation.

**Strength-tier calibration table** (banked for §3.6.4 ladder):

| Mitigation | Verdict |
|---|---|
| (none) | writes lost |
| barrier (Path E) | writes lost |
| barrier + volatile (Path E++) | **writes lost despite spec mandate** |
| barrier + volatile + atomic (Path E+++) | tested pending AppGL-W readback |

Each rung up the ladder corresponds to a stronger spec contract.
The atomic rung is the last empirically-defensible mitigation —
if it also proves insufficient, that's a publication-grade negative
result on AIR optimizer's spec-conformance for cross-encoder-family
scenarios. The counter probe routes the outcome:

- counter > 0 + buffer populated → mitigation worked, Phase 2 unblocks
- counter > 0 + buffer still `0xCC` → AIR eliminating spec-preserved
  atomic writes (publication-grade negative result)
- counter == 0 → kernel didn't execute, different-layer issue
  (escalate; not an AIR optimizer issue)

Test rig adds 6 additional rung-7 asserts (atomic emission +
counter parameter + counter increment + 3 absent-in-tess-default
regression guards). Total rung-7 asserts: 11. Total rig: 32
assertions across 6 ladder rungs.

**Path E++ (gate 9 escalation — `volatile` qualifier on spvOut):**
adds `msl_options.force_compute_kernel_device_volatile_writes` (CLI:
`--msl-force-compute-kernel-device-volatile-writes`). When set on a
`vertex_for_tessellation + capture_output_to_buffer` VS-as-compute
kernel, emits `volatile device main0_out* spvOut [[buffer(28)]]`
instead of `device main0_out*`, AND propagates `volatile` to the
local reference declaration `volatile device main0_out& out = ...`
(C++ disallows binding `device T&` to a `volatile device T` lvalue).
Default off — preserves byte-identical emission for the Phase-3
metal-tess (compute → compute) path.

**Why E++ instead of E:** AppGL-W's Phase 2 Checkpoint 11 readback
diagnostic (Private buffer pre-fill with `0xCC` sentinel before
dispatch, blit-to-Shared after waitUntilCompleted) proved
empirically that the Path E barrier alone is **insufficient**
against Apple's AIR cross-encoder-family elimination. With the
barrier emitted at kernel exit, every byte of the Private buffer
preserved the `0xCC` sentinel — kernel writes never reached the
buffer. The AIR optimizer can prove nothing reads spvOut within
the kernel, so writes + the barrier they're meant to order get
eliminated as a unit. Path E++ escalates to `volatile` per Apple's
MSL spec contract: each write through a `volatile`-qualified pointer
**must** be observable at its source location, blocking the
elimination class. The Path E barrier flag is preserved for
empirical-calibration value (and as future-proofing if Apple driver
behavior changes).

Test rig adds 3 additional rung-7 cross-encoder AIR liveness asserts
(volatile parameter presence-when-on, volatile reference
presence-when-on, volatile absence-in-tess-default). Total rung-7
asserts: 5 (barrier on/off + volatile param/ref on + volatile off).
Total rig: 27 assertions across 6 ladder rungs.

**Path E (gate 9 — cross-encoder-family AIR liveness barrier):**
adds `msl_options.force_compute_kernel_device_barrier_at_exit` (CLI:
`--msl-force-compute-kernel-device-barrier-at-exit`). When set on a
`vertex_for_tessellation` VS-as-compute kernel, emits
`threadgroup_barrier(mem_flags::mem_device);` at function exit before
the implicit return. Default off — preserves byte-identical emission
for the Phase-3 metal-tess (compute → compute) path.

**Why:** AppGL-W's Phase 2 Checkpoint 9-10 diagnostic confirmed
VS-compute writes to `device main0_out* spvOut [[buffer(28)]]`
survive on the compute → compute consumer path (Phase-3 VS → TCS,
both compute encoder family) but vanish on the compute → render
consumer path (mesh-GS Phase 2 VS → mesh function). Same MSL, same
dispatch shape, same buffer slot — only the consumer encoder family
differs. Apple's AIR optimizer + Metal driver appear to eliminate
the cross-encoder-family writes in the absence of an explicit memory
ordering signal at kernel exit. The `mem_flags::mem_device` barrier
forces all device writes to be ordered before kernel exit, which
blocks the AIR-layer elimination.

Test rig adds rung-7 cross-encoder AIR liveness assertion (per
publication-prep §3.6.4 ladder, rung 7) — barrier presence when flag
enabled AND barrier absence in tess-default (98 GENUINE_PASS
invariant regression guard). 2 new asserts; total rig: 24
assertions across 6 ladder rungs.

**Path B (gate 8 — emit_fixup() side-effects):** the legacy
`CompilerMSL::emit_fixup()` short-circuits when
`capture_output_to_buffer == true` (set by VS-compute via
`vertex_for_tessellation`) on the assumption that a downstream vertex
stage will re-apply its three conditional transforms. Mesh-GS has no
such downstream stage — the mesh function IS the last vertex stage
before rasterization. Each transform is replicated in the
`fixup_hooks_out` trailing emit (in the same loop that calls
`spvMesh.set_vertex`), gated by the same option flags emit_fixup
consults:

1. `needs_point_size_output && !writes_to_point_size` →
   `spvVertices[spvVI].gl_PointSize = default_point_size;`
2. `options.vertex.fixup_clipspace` →
   `spvVertices[spvVI].gl_Position.z = (z+w) * 0.5;` (Metal clip space)
3. `options.vertex.flip_vert_y` →
   `spvVertices[spvVI].gl_Position.y = -y;`

Without gate 8, points at near-plane render incorrectly because
gl_Position arrives at Metal's rasterizer in GL clip space
(z ∈ [-w, +w]) instead of Metal clip space (z ∈ [0, +w]). H6 in
AppGL-W's Phase 2 Checkpoint 5 diagnostic.

Test rig adds rung-5 runtime-semantic-invariant assertions (per
publication-prep §3.6.4 ladder, rung 5) — for each transform, asserts
presence when option enabled AND absence when option disabled
(regression guard). 4 new asserts (clipspace + y-flip × on/off);
point-size injection deferred to a follow-on per-pipeline test
fixture (current synthetic doesn't trigger the
`needs_point_size_output` path). Total rig: 22 assertions across
5 ladder rungs.

**Path A++ (gate 7 — shared-struct-layout parity):** the existing
`add_interface_block` flatten loop emits gl_ClipDistance / gl_CullDistance
for VS-Output (`vertex_for_tessellation + capture_output_to_buffer`)
but `emit_struct_member`'s "do not emit unused builtins in mesh-output
blocks" filter dropped them from GS-as-mesh's main0_in. Result: VS
writes 32 B/vertex while mesh reads 24 B/vertex — first vertex aligns
by accident, subsequent vertices misalign and gl_Position lands at
wrong byte offsets. Gate 7 narrows the filter to skip GS-as-mesh's
main0_in (tracked by `type.self == get_stage_in_struct_type().self`)
plus a post-pass `ensure_gs_as_mesh_gl_per_vertex_parity()` that walks
the GS source's input gl_PerVertex block and injects any missing
ClipDistance/CullDistance member into main0_in. Source of truth for
array sizes is the SPIR-V input block — same shape the linked VS's
main0_out is emitted from, so byte parity falls out automatically.

Test rig adds rung-4 cross-stage struct-byte parity assertion (per
publication-prep §3.6.4 false-confidence ladder) — given a 2nd
`vs.spv` argument, compiles VS with `vertex_for_tessellation +
capture_output_to_buffer` and asserts `sizeof(VS::main0_out) ==
sizeof(mesh::main0_in)` with per-member offset+size compare. Catches
the divergence class that triggered Path A++, which marker presence
+ compile validity + structural-runtime-flow markers all PASS for
each stage independently.

**Path A (gl_in[] population from VS-output buffer):** the function-local
input arrays declared by Components 6 are populated from a
`device const main0_in* spvVsOutputs [[buffer(22)]]` parameter at the
start of the `[[mesh]]` function. Each mesh threadgroup processes one
input primitive (`[[threadgroup_position_in_grid]]` -> `spvPrimitiveID`),
reading `spvVsOutputs[spvPrimitiveID * verticesPerPrim + i]` for each
of the input primitive's vertices. `main0_in` is built by extending
`add_interface_block(StorageClassInput)` to fire for GS-as-mesh with
`strip_array=true` (one main0_in per VS output vertex, mirroring TES
`raw_buffer_tese_input` shape) and re-using the existing
phase-3-tess-struct-parity gate to force-include gl_PerVertex builtins
(`gl_Position`, etc.) so VS main0_out and GS main0_in match
byte-for-byte. The native `[[stage_in]]` parameter path is gated off
for GS-as-mesh; AppGL-W's runtime configures the linked VS to write
its output to the buffer, then dispatches the mesh as
`drawMeshThreadgroups(numPrimitives, ...)`. Resolves the AppGL-W
pre-PSO regression where 102 currently-passing GS programs would
silently switch from the CPU GS interpreter (which populates gl_in)
to the mesh-shader path (which previously zero-init'd it).

**Deferred / follow-on:**
- Phase 2.5 Gap A: GS that doesn't write `gl_Position` (e.g. TF-only
  patterns) produces `spvPerVertex` without `[[position]]` -> Metal
  rejects mesh vertex type. Spec'd in
  [SPIRVC-MESH-PHASE-2.5-PREP-2026-04-27.md](../../specs-worker-docs/crossworker/SPIRVC-MESH-PHASE-2.5-PREP-2026-04-27.md).
- Phase 2.5 Gap B: `max_vertices > 3` strip-to-list expansion with
  proper winding alternation per GL spec.
- Phase 2.5 Gap C: layered_rendering test verification of `gl_Layer`
  per-primitive routing through `[[render_target_array_index]]`.
- Strip handling for `max_vertices > 3` (would emit (N-2) triangles
  from a strip of N vertices with proper winding alternation).
- Stream output (`OpEmitStreamVertex` / `OpEndStreamPrimitive`) — the
  Step 2 scope deferred multi-stream GS.
- Adjacency input topologies (`triangles_adjacency`, etc.).
- Cosmetic `_RESERVED_IDENTIFIER_FIXUP_` prefix stripping on
  builtin-block names emitted in the GS-as-mesh body — currently
  cosmetic (Metal validates rc=0); fix would touch
  SPIRV-Cross's reserved-name sanitization with a GS-specific override.
- Three remaining unused-`threadgroup`-variable warnings (`gl_out`,
  `out_color`, builtin-prefixed `gl_Layer` etc.) — emitted by the
  existing mesh-shader output-remapping path. Suppressing them at
  declaration time without breaking the OpStore intercept's
  expression-resolution dependency on the remap is a follow-on
  refactor.

**Regression-safe:** flag-OFF (default) preserves upstream emission
byte-identically — verified by `tools/msl-gs-as-mesh-test` flag-OFF
asserts. The flag is opt-in; absent it, existing TCS/TES/VS/FS/CS
emission paths are unaffected.

**Architectural narrative:** publication-track material — Metal
doesn't have a geometry shader stage, but it has mesh shaders; this
option teaches SPIRV-Cross to bridge GS source semantics onto Apple's
mesh-shader API. Continues the "drive existing infrastructure with
alternate signal" pattern from
`spirv-cross-msl-tcs-output-classification.patch`
(`is_mesh_shader()` / `variable_decl_is_remapped_storage(StorageClassWorkgroup)`
plumbing already present for native MeshEXT shaders; GS source rides
those rails through the GS→mesh translation layer this patch adds).

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

### `glslang-vulkanrelaxed-binding-range-check.patch`

**Target:** `third_party/glslang/glslang/MachineIndependent/ParseHelper.cpp` (KhronosGroup/glslang) — extends `TParseContext::layoutTypeCheck()` to enforce GL 4.6 §4.4.4 sampler/image/atomic-counter binding-range checks under `vulkanRelaxed` mode (OpenGL emulation through glslang's Vulkan target).

**Summary:** Three small gate adjustments:
1. Sampler binding-range check (was `if (spvVersion.vulkan == 0 && lastBinding >= maxCombinedTextureImageUnits)`) now also fires under `vulkanRelaxed`. Distinguishes images via `type.getSampler().isImage()` and uses `maxImageUnits` as the limit for those.
2. Atomic-counter binding-range check (was `if (type.isAtomic() && !spvVersion.vulkanRelaxed)`) now fires regardless of `vulkanRelaxed` — the GL spec rule applies during OpenGL emulation.
3. Error message split between sampler and image variants for diagnostic clarity.

**Why:** AppGL's shader-translator pipes OpenGL GLSL through glslang's Vulkan target with `setEnvInputVulkanRulesRelaxed()` so SPIRV-Cross can downstream-convert the SPIR-V to MSL. The relaxed-Vulkan mode skips most Vulkan-strict requirements (like requiring `layout(binding=X)` on uniforms), but glslang's design also skips the OpenGL upper-bound binding-range checks under any non-zero Vulkan version — including the relaxed mode. CTS `KHR-GL46.layout_binding.*.binding_compilation_errors` exercises that the GL spec rule still applies (binding ≥ `gl_MaxCombinedTextureImageUnits` must produce a compile error), so the check needs to fire when we're emulating OpenGL semantics inside Vulkan-flavoured glslang.

**CTS tests unlocked:** +4 on Cluster F (Sprint 8 B Cluster F F1 Day 6 / CKPT78):
- `KHR-GL46.layout_binding.sampler2D_layout_binding_texture_FragmentShader`
- `KHR-GL46.layout_binding.sampler2D_layout_binding_texture_ComputeShader`
- `KHR-GL46.layout_binding.sampler2DArray_layout_binding_texture_FragmentShader`
- `KHR-GL46.layout_binding.sampler3D_layout_binding_texture_FragmentShader`

**Regression-safe:** when `spvVersion.vulkan == 0` (pure OpenGL through glslang), the gate keeps its original true-for-GL semantics. When `vulkanRelaxed == false` (strict Vulkan target), no behaviour change. AppGL is the only known caller of `setEnvInputVulkanRulesRelaxed()` in the runtime, so the new check fires exclusively for our path. Section sweep verified zero regression: 272/297 P, 22 F, 3 NS on `tessellation_shader.* + geometry_shader.* + transform_feedback.*`.

### `spirv-cross-msl-dim-rect-as-texture2d.patch`

**Target:** `third_party/SPIRV-Cross/spirv_msl.cpp` — `CompilerMSL::image_type_glsl()` non-depth texture switch.

**Summary:** Adds a `case DimRect: img_type_name += "texture2d";` arm to the per-Dim switch that decides the MSL texture type emitted for a SPIR-V image. Pre-patch, the switch handled only `Dim1D / Dim2D / DimSubpassData / Dim3D / DimCube`; SPIR-V `Dim::Rect` fell into `default:` and emitted the literal token `unknown_texture_type<T>`, which is invalid MSL and silently broke pipeline state build for any shader declaring `sampler2DRect`.

**Why:** Metal has no separate rectangle texture type. Both GL `sampler2DRect` and a regular `sampler2D` map to the same Metal `texture2d<T>` underlying object — the only runtime difference is normalized vs unnormalized texel coordinates, handled via the sampler's `coord::pixel` mode rather than a distinct texture type. Mapping `DimRect → texture2d` is the canonical and only correct emission.

**CTS tests advanced (sub-section progress):** `KHR-GL46.shading_language_420pack.binding_samplers_texture_type_2D_rectangle` — pipeline build now succeeds (output transitions from `Invalid texel: 00000000` / silent pipeline failure to `Invalid texel: ff0000ff` / shader runs but sampling returns wrong data — distinct downstream residual deferred to next dispatch). No whole-test flip yet because the sample-correctness gap is a separate fix surface.

**Regression-safe:** the new arm fires only on `image_type.dim == DimRect`. `default:` arm preserved for any future SPIR-V Dim values. Section sweep verified zero regression: 272/297 P, 22 F, 3 NS on `tessellation_shader.* + geometry_shader.* + transform_feedback.*`.

### `spirv-cross-msl-dim-rect-skip-level.patch`

**Target:** `third_party/SPIRV-Cross/spirv_msl.cpp` — `CompilerMSL::to_function_args()` LOD/bias/gradient option emission.

**Summary:** Extends the existing `Dim1D` skip-gates in the bias / lod / gradient option emission to also skip `Dim::Rect`. Pre-patch, samples on `sampler2DRect` emitted `goku.sample(s, c, level(0.0))` (or `bias(...)`, `gradient(...)`) — which Metal's specification forbids when the sampler is configured with `normalizedCoordinates=NO`. Quote from the Metal Shading Language specification: *"These overloads are only valid if normalizedCoordinates property of the sampler is true."* Pre-patch, our CKPT83 rect sampler (which sets `normalizedCoordinates=NO` per GL 4.6 §8.10) silently returned undefined values for any sampling that included an LOD argument.

**Why:** Sister patch to `spirv-cross-msl-dim-rect-as-texture2d.patch` (CKPT82B). That patch closed the pipeline-build gap by mapping `Dim::Rect` to `texture2d<T>` in MSL emit. CKPT83 closed the runtime sampler-state gap (`normalizedCoordinates=NO` + Metal-validation coercions on mipFilter/addressMode/min==mag). CKPT84 closes the third gap: bias/lod/gradient overloads must be skipped on rect sample emit because the underlying sampler can't honour them without violating Metal's non-normalized-coords constraints.

**CTS tests advanced (sub-section progress):** Multi-stage iterations of `KHR-GL46.shading_language_420pack.binding_samplers_texture_type_2D_rectangle` no longer emit `sample(s, c, level(0.0))` from VS-stage compilation. Whole-test pass still blocked by an independent VS-reflection gap (sampCount=0 for VS in the multi-stage iteration, distinct fix surface deferred). No whole-test flip yet.

**Regression-safe:** the new arms add `imgtype.image.dim != DimRect` to existing skip gates that already exclude `Dim1D`. Non-rect samplers retain their original LOD/bias/gradient emission. Section sweep verified zero regression: 272/297 P, 22 F, 3 NS on `tessellation_shader.* + geometry_shader.* + transform_feedback.*`.

### `spirv-cross-msl-shading-rate-builtins.patch`

**Target:** `third_party/SPIRV-Cross/spirv_msl.cpp` — adds MSL backend
emit for `BuiltInShadingRateKHR` (per-fragment input) and
`BuiltInPrimitiveShadingRateKHR` (per-primitive mesh-shader output),
backing the SPV_KHR_fragment_shading_rate capability that
`GL_EXT_fragment_shading_rate` lowers to.

**Summary:** Five surgical insertion points in `spirv_msl.cpp`:
(1) `CompilerMSL::builtin_qualifier` (~line 20200): add two arms returning `"shading_rate"` and `"primitive_shading_rate"` with MSL-2.4 version gate and an execution-model gate that requires `ExecutionModelMeshEXT` for the primitive-output case (Apple Metal does not expose primitive-shading-rate from vertex/geometry stages).
(2) `CompilerMSL::builtin_type_decl` (~line 20347): both builtins map to `"uint"` — the SPIR-V `FragmentShadingRateMask` encoding (V2/V4/H2/H4 bits) matches Metal's `[[shading_rate]]` integer-mask layout.
(3) Mesh-shader output struct path (~line 14792): replace the pre-existing `// not supported in metal 3.0` early-return for `BuiltInPrimitiveShadingRateKHR` with an MSL-2.4 version gate — when 2.4+ is targeted, fall through to the standard member-emit path so the `[[primitive_shading_rate]]` qualifier flows from `builtin_qualifier`. Also extend the basetype-to-uint coercion list (already covering `BuiltInPrimitiveId` / `BuiltInLayer` / `BuiltInViewportIndex`) to include `BuiltInPrimitiveShadingRateKHR`.
(4) `CompilerMSL::member_attribute_qualifier` fragment-input switch (~line 15166): add `BuiltInShadingRateKHR` to the case list so fragment-stage stage_in struct members receive the qualifier.

**Why:** MSL backend had zero arm for `BuiltInShadingRateKHR` in `builtin_qualifier` / `builtin_type_decl`, so the default `"unsupported-built-in"` token would land in the emitted MSL and the AppGL ShaderTranslator would fail downstream Metal compile. The pre-existing `BuiltInPrimitiveShadingRateKHR` partial handling in the mesh-out path silently dropped the member, which would compile cleanly but produce semantically-wrong MSL (the SPIR-V write target effectively disappeared).

**CTS tests advanced (sub-section progress):** AppGL-CW CTS coverage for `KHR-GL46.fragment_shading_rate.*` was previously blocked at the shader-translation layer for any test reading `gl_ShadingRateEXT` or writing `gl_PrimitiveShadingRateEXT`. Post-patch, the SPIRV-Cross CLI emits `uint gl_ShadingRateEXT [[shading_rate]]` for a minimal fragment shader and `uint gl_PrimitiveShadingRateEXT [[primitive_shading_rate]]` for a minimal mesh shader — both confirmed via synthetic translate probe at MSL 2.4 target. Test-flip count deferred to AppGL-CW integration verification (advertise-gated; current `GL_EXT_fragment_shading_rate` is no-advert per `0bf67db`).

**Regression-safe:** All additions are switch-arms with version-gates guarded by `msl_options.supports_msl_version(2, 4)`; the pre-patch behavior is exactly preserved for any target below MSL 2.4. The mesh-out path's early-return is preserved verbatim when `!supports_msl_version(2, 4)`. No new SPVFuncImpl helpers, no new public API. Patch size: 7 hunks, 33 lines added, 2 lines removed (35 LOC net additions excluding context).

### `spirv-cross-msl-sparse-feedback.patch`

**Target:** `third_party/SPIRV-Cross/spirv_msl.cpp` — implements `CompilerMSL::emit_texture_op` lowering for `OpImageSparseSample*` / `OpImageSparseFetch` / `OpImageSparseGather*` / `OpImageSparseTexelsResident`, backing `SPV_KHR_sparse_residency` (the SPIR-V capability that `GL_ARB_sparse_texture2` and `GL_ARB_sparse_texture_clamp` lower to).

**Summary:** Three surgical change sites in `spirv_msl.cpp`:
(1) `CompilerMSL::emit_instruction` (~line 10970): new arms for `OpImageSparseTexelsResident` (emit `(<feedback_code> != 0)` bool expression) and `OpImageSparseRead` (explicit `SPIRV_CROSS_THROW` for unsupported storage-image sparse load — separate patch surface).
(2) `CompilerMSL::emit_texture_op` (~line 12039): replace the pre-existing `Sparse feedback not yet supported in MSL.` throw with a `sparse_color<T>` rebind. When `sparse=true`: gate on `msl_options.supports_msl_version(2, 3)`, allocate feedback-code + texel temporaries via the GLSL-backend helper `emit_sparse_feedback_temporaries`, build the call expression via `to_texture_op` (which now routes to `sparse_sample` / `sparse_read` / `sparse_gather` via `to_function_name`), emit `auto spvSparseN = <call>;`, bind `<feedback_code> = int(spvSparseN.resident());` and `<texel> = spvSparseN.value();`, then rebind the SPIR-V result id to a `ResultStruct{ feedback, texel }` brace-init aggregate.
(3) `CompilerMSL::to_function_name` (~line 13519): prepend `sparse_` to the base call when `args.is_sparse_feedback` is true — `sample`→`sparse_sample`, `read`→`sparse_read`, `gather`→`sparse_gather`. The `_compare` suffix flows through unchanged for `sparse_sample_compare` (Dref variants).

**Why:** MSL backend hard-coded `SPIRV_CROSS_THROW("Sparse feedback not yet supported in MSL.")` on any `sparse=true` invocation, blocking the entire `GL_ARB_sparse_texture2` / `GL_ARB_sparse_texture_clamp` lookup family (`sparseTextureARB`, `sparseTextureLodARB`, `sparseTextureGradARB`, `sparseTextureOffsetARB`, `sparseTexelFetchARB`, `sparseTextureGatherARB`, `sparseTextureClampARB`, `sparseTextureGradClampARB`, and `sparseTexelsResidentARB`). Apple's MSL exposes `metal::sparse_color<T>` from `texture::sparse_sample` / `texture::sparse_read` / `texture::sparse_gather` (MSL 2.3+ / macOS 11+) carrying `.value()` (T) and `.resident()` (bool) — the natural target for the SPIR-V `{int feedback_code, vec4 texel}` result struct. SPIR-V `OpImageSparseTexelsResident(<code>)` semantically is `<code> != 0` after the `int(resident())` encoding, identical to the GLSL backend's `sparseTexelsResidentARB(<code>)` reading.

**Risk-E follow-up resolved:** `GL_ARB_sparse_texture_clamp` (`sparseTextureClampARB`, `sparseTextureGradClampARB`) was orientation-flagged as potentially needing a separate patch for the SPIR-V `MinLod` image operand. Synthetic translate probe at MSL 2.3 target confirms the existing MSL `to_function_args` `min_lod_clamp(...)` overload (line 14034) flows through the sparse path unmodified — `sparse_sample(s, c, min_lod_clamp(L))` and `sparse_sample(s, c, gradient2d(gx, gy), min_lod_clamp(L))` both emit cleanly. No separate clamp patch needed; this single patch covers the full ARB sparse_texture2 + sparse_texture_clamp opcode family.

**CTS tests advanced (sub-section progress):** AppGL-CW CTS coverage for `KHR-GL46.sparse_texture2_tests.*` (1204 cases) and the `negative_texture_lookup_functions_with_bias_tests.sparseTexture*` wrapper bias coverage (27 cases) was previously blocked at the shader-translation layer with `msl_log=SPIRV-Cross error: Sparse feedback not yet supported in MSL.` (per AppGL-CW empirical probe in `sprint19-sparse-texture2-spirv-gap-2026-05-11.md`). Post-patch, the AppGL-CW substrate compute shader emits clean MSL with `tex.sparse_sample(texSmplr, float2(0.5), level(0.0))` + `.resident()` / `.value()` accessors. Synthetic translate probes at MSL 2.3 target cover sparseTextureARB / sparseTextureLodARB / sparseTextureGradARB / sparseTextureOffsetARB / sparseTexelFetchARB / sparseTextureGatherARB / sparseTexelsResidentARB / sparseTextureClampARB / sparseTextureGradClampARB / sampler2DShadow-dref — all MSL emit verified clean. Test-flip count deferred to AppGL-CW integration verification (advertise-gated; `GL_ARB_sparse_texture2` and `GL_ARB_sparse_texture_clamp` no-advert per `35a4e67`).

**Regression-safe:** The `sparse=false` path is untouched — the non-sparse `emit_texture_op` body (frame-buffer-fetch subpass shortcut + `CompilerGLSL::emit_texture_op` fallback) flows through verbatim. `to_function_name` adds a `sparse_` prefix only when `args.is_sparse_feedback` is true; non-sparse callers emit `sample` / `read` / `gather` exactly as before. MSL version gate at `msl_options.supports_msl_version(2, 3)` throws a clear error for pre-2.3 targets instead of emitting invalid code. `OpImageSparseRead` throws explicitly rather than falling through to GLSL's `sparseImageLoadARB` (which would emit invalid MSL). GLSL backend emission for the same input SPIR-V is byte-identical pre- and post-patch (verified via diff against SPIRV-Cross's `reference/shaders-no-opt/frag/sparse-texture-feedback.desktop.frag`). Patch size: 3 hunks, 105 lines added, 4 lines removed (101 LOC net additions excluding context).

### `spirv-cross-msl-ms-sparse-fetch.patch`

**Target:** `third_party/SPIRV-Cross/spirv_msl.cpp` — extends
`CompilerMSL::emit_texture_op` sparse-feedback lowering for
`OpImageSparseFetch` on compute-stage `sampler2DMS` /
`sampler2DMSArray` sampled images.

**Summary:** Adds a sparse-fetch fast path inside the existing
`sparse=true` branch. For compute-stage non-depth multisample sampled
images, SPIRV-Cross still emits Metal's native `sparse_read(...)` call
to obtain residency, but sources the returned texel from
`appgl_ms_sampled_sidecar_<resource>.read(...)`, the sample-expanded
sidecar populated by AppGL's multisample storage-image lowering. The
sample operand is required, clamped against
`appgl_ms_storage_image_samples[resource]`, and arrayed MS images map
`layer * sample_count + sample` to the sidecar slice. The emitted marker
`// APPGL_MS_SAMPLED_SIDECAR` lets `ShaderTranslator` inject the extra
`texture2d_array<T>` parameter after SPIRV-Cross emission.

**Why:** `GL_ARB_sparse_texture2` includes
`sparseTexelFetchARB(sampler2DMS*)`. Metal can report sparse residency
for the original MS texture, but AppGL's compute `imageStore` path writes
MS storage images through the sample-expanded sidecar. Without this
bridge, sparse MS sampled fetch observes the stale/native texture value
instead of the coherent sidecar value written by imageStore. This patch
keeps native Metal residency feedback and redirects only the texel
payload for the AppGL MS-storage sidecar coherence case.

**CTS tests advanced (sub-section progress):** Synthetic AppGL
translation and real-device compute probes verified the lowered MSL emits
both the native sparse read and the injected sampled-sidecar read for
non-depth `sampler2DMS*` fetches, with dynamic sample-count metadata
binding. Full `KHR-GL46.sparse_texture2_tests.*` and
`KHR-GL46.sparse_texture_clamp_tests.*` pass-rate measurement is
advertise-gated and follows the Sprint 19 Phase 4 Item 38 protocol.

**Regression-safe:** The fast path is gated to `OpImageSparseFetch`,
`ExecutionModelGLCompute`, `Dim2D`, multisample, sampled-image, non-depth
images. All other sparse-feedback texture operations continue through
the generic sparse-feedback lowering from
`spirv-cross-msl-sparse-feedback.patch`. Pre-MSL-2.3 targets still throw
the same explicit sparse-feedback error. Depth MS sparse fetch remains a
documented follow-up blocker rather than silently mis-lowering.

### `glslang-cull-distance-builtin-constants.patch`

**Target:** `third_party/glslang/glslang/MachineIndependent/{Initialize.cpp, Versions.cpp, Versions.h}` (KhronosGroup/glslang) — three small adjustments that make `gl_MaxCullDistances` / `gl_MaxCombinedClipAndCullDistances` GLSL constants visible to shaders that declare `#extension GL_ARB_cull_distance : require` at desktop GL versions 130-440.

**Summary:** (1) `Versions.h:152` — un-stub the `E_GL_ARB_cull_distance = "GL_ARB_cull_distance"` symbol declaration (was commented out with the note "present for 4.5, but need extension control over block members"). (2) `Versions.cpp:215` — register the extension with `EBhDisable` initial state, matching every other `E_GL_ARB_*` desktop-GL extension. (3) `Versions.cpp:524` — emit the `#define GL_ARB_cull_distance 1` preprocessor symbol in the desktop-GL preamble. (4) `Initialize.cpp:8796` — lower the version gate that emits the `gl_MaxCullDistances` + `gl_MaxCombinedClipAndCullDistances` builtin-constant declarations from `version >= 450` to `version >= 130`, mirroring the `gl_MaxClipDistances` policy (line 8580) for any desktop GL profile.

**Why:** CTS `KHR-GL46.cull_distance.coverage` compiles a multi-stage program with `#version 150 + #extension GL_ARB_cull_distance : require` and reads `gl_MaxCullDistances` via transform feedback. Pre-patch the extension wasn't registered (so `:require` would fail), and the constants weren't emitted at version 150 even with the extension declared. Block-member-level extension gating (the upstream comment's stated concern) is a separate enforcement question — the test asks only that the constants be visible when the extension is required.

**CTS tests advanced (sub-section progress):** `cull_distance.coverage` glslang side now compiles cleanly with `gl_MaxCullDistances=8`. Confirmed via `APPGL_TRACE_CULL_BUILTIN=1` stderr trace during development: glslang sees `version=150 profile=2 maxCullDistances=8`. Whole-test pass still blocked by a downstream multi-stage TF chain bug (pre-existing CKPT189 Class A characterization — the CS / VS+GS+TC+TE+FS / VS+GS+FS / VS+TC+TE+FS / VS-only stages run in series and one of the multi-stage chains produces `-1` in TF readback even after the GLSL constant emits correctly). No whole-test flip yet.

**Regression-safe:** the constant emission gate now mirrors `gl_MaxClipDistances` (which has been at `version >= 130` indefinitely without controversy). Multi-section regression sweep with stash + rebuild: identical 584P/251F/21NS across `shader_image_load_store + shader_storage_buffer_object + copy_image + geometry_shader + cull_distance + clip_distance + linking` (856 tests) with vs without the patch.
