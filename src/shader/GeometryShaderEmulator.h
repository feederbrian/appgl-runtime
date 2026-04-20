#ifndef APPGL_SHADER_GEOMETRY_SHADER_EMULATOR_H
#define APPGL_SHADER_GEOMETRY_SHADER_EMULATOR_H

// Geometry-shader CPU emulator.
//
// Metal has no geometry-shader stage. For CTS conformance — starting with
// the KHR-GL46.constant_expressions.*_geometry cluster (224 F) — we
// emulate GS on the CPU:
//   1. VAO attribute data copied from VBO shadow buffers.
//   2. VS body interpreted on CPU per vertex, producing per-vertex
//      outputs (gl_Position + user varyings).
//   3. VS outputs grouped into primitives per the GS input topology.
//   4. GS body interpreted on CPU per primitive. EmitVertex appends
//      snapshot of current output state to an expanded-vertex buffer;
//      EndPrimitive writes a primitive-restart marker.
//   5. Expanded buffer uploaded to a Metal buffer; a synthetic pass-
//      through VS + the program's original FS draw the expanded
//      primitives on GPU.
//
// The interpreter handles a narrow subset of SPIR-V — enough for the
// constant_expressions.*_geometry tests — and fails loudly (with
// opcode names in the log) on anything else so the unsupported-opcode
// list is easy to extend.
//
// This path is CPU-bound; acceptable for CTS (tiny geometry) but not
// for production rendering. The plan is to use this as ground-truth
// for a future GPU emulation path (SPIRV-Cross mesh-shader emitter
// patch or Apple-converter chain).

#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

typedef unsigned int GLenum;
typedef int GLsizei;
typedef int GLint;
typedef unsigned int GLuint;

namespace appgl {

struct GLProgramObject;
struct GLVertexArrayObject;
struct GLObjectStore;
class GLStateTracker;

// One interpreted vertex output: gl_Position + concatenated user
// varyings, stored as a flat float32 payload. Layout is described by
// the companion `VaryingLayout`. `clipDistance` / `cullDistance`
// capture the gl_ClipDistance[] / gl_CullDistance[] arrays at the
// moment of OpEmitVertex so the synth pass-through VS can emit them
// as `[[clip_distance]]` outputs and Metal performs per-vertex
// clipping / culling the same way the legacy no-GS pipeline would.
// Sized dynamically — empty when the GS writes neither.
struct EmulatedVertex {
    float position[4] = {0, 0, 0, 1};
    std::vector<float> varyings;       // concatenated user varying values
    std::vector<float> clipDistance;   // gl_ClipDistance[] at EmitVertex
    std::vector<float> cullDistance;   // gl_CullDistance[] at EmitVertex
    // gl_Layer value at EmitVertex (GL 4.6 §11.2.1 /
    // BuiltInLayer). Routed through the synth pass-through VS as
    // `[[render_target_array_index]]` to send each primitive to the
    // correct layer of a layered framebuffer attachment. The GS sets
    // gl_Layer per-vertex; per spec the value from the provoking
    // vertex is used for the whole primitive, but the per-vertex
    // snapshot lets us pick the right one on the MSL side.
    std::int32_t layer = 0;
    // gl_PointSize value at EmitVertex (BuiltInPointSize). Routed
    // through the synth pass-through VS as `[[point_size]]` on
    // GL_POINTS output topologies. Default 1.0 matches the value
    // the synth VS emitted before per-vertex capture landed —
    // preserves behaviour when the GS doesn't write gl_PointSize.
    float pointSize = 1.0f;
    // gl_PrimitiveID value written by the GS (OUTPUT side — not the
    // per-invocation INPUT gl_PrimitiveIDIn). Routed through the
    // synth VS as a flat `int` user varying that a post-processed
    // FS reads instead of Metal's rasteriser-provided
    // `[[primitive_id]]`. Default 0; only used when ed.hasPrimitiveID
    // is set (i.e. the GS source stores to gl_PrimitiveID anywhere).
    std::int32_t primitiveId = 0;
};

// Post-GS output topology + vertex buffer ready for GPU raster.
struct EmulatedDraw {
    GLenum topology = 0;              // one of GL_POINTS / GL_LINE_STRIP / GL_TRIANGLE_STRIP
    // Interleaved per-vertex payload: [pos0..pos3, varying0..N-1] per vertex.
    std::vector<float> expandedVertexData;
    std::size_t vertexCount = 0;
    std::size_t floatsPerVertex = 0;   // 4 (position) + sum of varying widths
    // Per-output-varying widths (float count), in the order they appear
    // in the payload after the 4-wide position.
    std::vector<std::uint32_t> varyingWidths;
    // Varying names, parallel to varyingWidths. Used to synthesise the
    // pass-through VS and to map to the FS's input varyings by name.
    std::vector<std::string> varyingNames;
    // Per-varying SPIR-V Location decoration, parallel to varying-
    // Widths. The pass-through VS emits `[[user(locn<N>)]]` with these
    // values so the FS reads the varying at its original layout
    // qualifier — the FS MSL was translated against that location and
    // expects it to match.
    std::vector<std::uint32_t> varyingLocations;
    // Interpolation qualifier (per-varying). 0=smooth (default), 1=flat,
    // 2=noperspective, 3=centroid. Metal requires VS output qualifiers
    // to match FS input qualifiers or the pipeline-state validator
    // rejects the build — integer varyings must always be flat, and
    // any `flat out float` in the GS GLSL also needs the matching tag
    // on the synthesised VS output.
    std::vector<std::uint8_t> varyingInterp;
    // Scalar base type (per-varying): 0=float, 1=int, 2=uint. Width
    // combines with this to give the final MSL type (`float3`, `int2`,
    // etc.). CTS `array_*_geometry` tests surface integer outputs —
    // `flat out int geom_out_out0;` — that fail Metal pipeline-state
    // validation if the synthesised VS emits `float` on them.
    std::vector<std::uint8_t> varyingBaseType;
    // gl_ClipDistance / gl_CullDistance array sizes captured on the
    // last EmitVertex. Per GL 4.6 §7.1 these are per-vertex float
    // arrays with implementation-defined max length (we advertise 8).
    // When non-zero, the synth pass-through VS emits them as
    // `[[clip_distance]] [N]` outputs so Metal's rasteriser performs
    // the clip/cull stage — an emulated GS that doesn't touch the
    // builtins still propagates them from the VS pre-pass (each
    // emitted vertex is the snapshot of the GS interpreter's
    // current clip/cull state, which defaults to the input vertex's
    // values when the GS declares an `out gl_PerVertex { ... }`
    // passthrough). Both arrays share a single Metal
    // `[[clip_distance]] float[N]` slot; total N = clipDistanceLen +
    // cullDistanceLen with cull coming after clip.
    std::uint32_t clipDistanceLen = 0;
    std::uint32_t cullDistanceLen = 0;
    // True if any emitted vertex wrote gl_Layer. The synth pass-
    // through VS only emits the `[[render_target_array_index]]`
    // slot when this is set — emitting on every GS-emulated draw
    // would force Metal to treat every FBO as layered, which it
    // isn't. When false, the packed buffer omits the layer slot
    // entirely so existing (non-layered) pipelines remain binary-
    // compatible. When true, each vertex in expandedVertexData
    // carries an `int32` layer value appended after clip/cull.
    bool hasLayer = false;
    // True when the GS wrote gl_PointSize on any primitive. Drives
    // whether the packed buffer carries a per-vertex point-size
    // slot + whether the synth VS emits `[[point_size]]` with that
    // value vs. its old hardcoded 1.0. Only relevant for GL_POINTS
    // output topology; other topologies have Metal-rejected
    // `[[point_size]]` slots so we gate the emission accordingly.
    bool hasPointSize = false;
    // True when the GS wrote gl_PrimitiveID on any emitted vertex.
    // Flips on the `[[user(locnK), flat]] int` output on the synth
    // VS and instructs the FS MSL post-processor to redirect
    // `gl_PrimitiveID` reads to that varying. When false, the FS
    // keeps Metal's rasteriser-generated `[[primitive_id]]` (= the
    // index of the current primitive in the expanded draw), which
    // is the right behaviour when the GS doesn't override it.
    bool hasPrimitiveID = false;
    // Location of the synth-VS `int vsout_prim_id` output varying
    // when hasPrimitiveID is set. Matched by the post-processed
    // FS's `int gs_prim_id [[user(locnN), flat]]` input. Computed
    // as `max(varyingLocations) + 1` so it doesn't collide with
    // the GS's regular user varyings (which flow through the FS
    // unchanged at their SPIR-V Location). Zero when hasPrimitiveID
    // is false.
    std::uint32_t primitiveIDLocation = 0;
    // True if emulation succeeded. False leaves expandedVertexData empty
    // and the caller should fall back to the existing no-GS path.
    bool ok = false;
    // Diagnostic: populated on failure with the reason (e.g. missing
    // opcode). Kept for surfacing in debug builds.
    std::string diagnostic;
};

// Detect whether a program's GS stage can be emulated. Called once
// at link time. The decision is stored on the GLProgramObject
// (`program.geometryEmulation.*`) so drawArrays can branch without
// re-parsing the SPIR-V. Also populates the program's GS metadata
// fields (`gsPresent`, `gsInputTopology`, `gsOutputTopology`,
// `gsMaxVertices`, `gsInvocations`) whenever the SPIR-V parses,
// regardless of whether the emulator can handle the body — those
// fields back the `glGetProgramiv(GL_GEOMETRY_*)` queries, which
// have to answer correctly even for programs we can't emulate.
bool detectGeometryEmulatable(GLProgramObject& program);

// Emulate a single drawArrays/drawElements call for a program that
// has a GS stage. Returns an `EmulatedDraw` whose `.ok` flag tells
// the caller whether the CPU path produced a usable expanded-vertex
// buffer. On `ok == false`, the caller should record the diagnostic
// and fall back to the VS+FS-only path (same behaviour as before this
// emulator existed).
// drawArrays call-site: pass `elementIndices = nullptr`. The emulator
// reads VBO slot `(first + i)` for the i-th vertex.
// drawElements call-site: pass a pre-resolved uint32 index array
// (already indexOffset-resolved and promoted to uint32 — the caller
// handles GL_UNSIGNED_BYTE / _SHORT promotion, which the runtime
// index-expansion cache already does for Metal). The emulator reads
// VBO slot `elementIndices[i]` for the i-th vertex.
EmulatedDraw emulateGeometryDraw(
    GLProgramObject& program,
    const GLVertexArrayObject& vao,
    GLObjectStore& objects,
    const GLStateTracker& state,
    GLenum drawMode,
    GLsizei count,
    GLint first,
    const std::uint32_t* elementIndices,
    GLsizei instanceCount = 1,
    GLuint baseInstance = 0);

// Synthesise a pass-through vertex-shader MSL source that reads
// the expanded per-vertex payload (one buffer slot with gl_Position
// + all user varyings packed sequentially) and writes gl_Position
// plus `[[user(locn<N>)]]` outputs at the same locations the
// original GS wrote. Called once per draw after
// `emulateGeometryDraw` succeeds; the resulting MSL is fed into
// the normal translated-draw encoder alongside the program's
// unchanged fragment MSL.
// When `layeredFbo` is true and `draw.hasLayer` is true, the synth
// VS emits `[[render_target_array_index]]` as the final output and
// reads `vsin_layer` from the packed buffer. When either is false,
// the attribute slot is still declared (so the vertex descriptor
// and packed-buffer stride match between the MSL and the encoder),
// but `gl_Layer` isn't wired to the render-target array index —
// non-layered attachments route all writes to slice 0 per
// GL 4.6 §9.4.1.
std::string synthesisePassThroughVertexMSL(const EmulatedDraw& draw,
                                           bool layeredFbo = true);

// Post-process the fragment shader MSL that SPIRV-Cross produced
// for a GS-emulated program so it reads the GS-supplied
// gl_PrimitiveID override from a flat user varying instead of
// Metal's rasteriser-provided `[[primitive_id]]`.
//
// The SPIRV-Cross output for an FS that reads `gl_PrimitiveID`
// looks like:
//
//   fragment main0_out main0(uint gl_PrimitiveID [[primitive_id]])
//   {
//       main0_out out = {};
//       ...references to gl_PrimitiveID...
//   }
//
// or, with user varyings present:
//
//   struct main0_in { … };
//   fragment main0_out main0(main0_in in [[stage_in]],
//                            uint gl_PrimitiveID [[primitive_id]])
//   { … }
//
// This helper rewrites the parameter list to drop the
// `[[primitive_id]]` parameter and adds a stage_in field (on an
// existing main0_in, or a synthesised GS-prim-id-only struct)
// whose value is bound to a local `uint gl_PrimitiveID =
// uint(<readback>);` at the start of main0(). The local shadows
// what SPIRV-Cross was otherwise receiving from Metal's
// rasteriser, and the rest of the function body references it
// unchanged.
//
// `primitiveIdLocation` must match the output location picked by
// `synthesisePassThroughVertexMSL` (via
// `draw.primitiveIDLocation`) so the FS input and VS output line
// up — Metal's pipeline validator rejects the link otherwise.
//
// Returns the original `fsMsl` unchanged when either
// `!draw.hasPrimitiveID` or the MSL doesn't contain a
// `[[primitive_id]]` reference.
std::string rewriteFragmentMSLForPrimitiveID(const std::string& fsMsl,
                                              const EmulatedDraw& draw);

// Walk a SPIR-V module's entry-point function body for
// OpAccessChain instructions that reach any Uniform-storage
// variable, and return a set of "stage-referenced uniform names"
// covering:
//   - Plain uniforms (default-block members): the member's GLSL
//     name (e.g. "uni_colors_white").
//   - UBO block members: "BlockName.memberName".
//   - SSBO block members: "BlockName.memberName".
// The returned names match what `glGetProgramResource*` would
// return for GL_UNIFORM / GL_BUFFER_VARIABLE queries. Callers
// narrow the `GL_REFERENCED_BY_<stage>_SHADER` bitmask so
// declared-but-unused uniforms don't get the stage's bit. Used
// by `glGetProgramResourceiv` for the GS side — VS/FS stages
// get the equivalent via SPIRV-Cross `get_active_interface_
// variables()`, but the GS is CPU-emulated and we keep all
// uniform-related reflection at block-level (active) granularity
// only for its own translation path; per-member usage here
// closes the gap for CTS
// `program_resource.program_resource`.
//
// Returns an empty set when the SPIR-V doesn't parse or has no
// function body. Safe no-op on programs without a GS stage.
std::unordered_set<std::string> scanStageReferencedUniforms(
    const std::vector<std::uint32_t>& spirv);

}  // namespace appgl

#endif  // APPGL_SHADER_GEOMETRY_SHADER_EMULATOR_H
