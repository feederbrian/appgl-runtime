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
