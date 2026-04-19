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
#include <vector>

typedef unsigned int GLenum;
typedef int GLsizei;
typedef int GLint;

namespace appgl {

struct GLProgramObject;
struct GLVertexArrayObject;
struct GLObjectStore;
class GLStateTracker;

// One interpreted vertex output: gl_Position + concatenated user
// varyings, stored as a flat float32 payload. Layout is described by
// the companion `VaryingLayout`.
struct EmulatedVertex {
    float position[4] = {0, 0, 0, 1};
    std::vector<float> varyings;   // concatenated user varying values
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
// re-parsing the SPIR-V.
bool detectGeometryEmulatable(GLProgramObject& program);

// Emulate a single drawArrays/drawElements call for a program that
// has a GS stage. Returns an `EmulatedDraw` whose `.ok` flag tells
// the caller whether the CPU path produced a usable expanded-vertex
// buffer. On `ok == false`, the caller should record the diagnostic
// and fall back to the VS+FS-only path (same behaviour as before this
// emulator existed).
EmulatedDraw emulateGeometryDraw(
    GLProgramObject& program,
    const GLVertexArrayObject& vao,
    GLObjectStore& objects,
    const GLStateTracker& state,
    GLenum drawMode,
    GLsizei count,
    GLint first,
    const void* indices,
    GLenum indexType);

// Synthesise a pass-through vertex-shader MSL source that reads
// the expanded per-vertex payload (one buffer slot with gl_Position
// + all user varyings packed sequentially) and writes gl_Position
// plus `[[user(locn<N>)]]` outputs at the same locations the
// original GS wrote. Called once per draw after
// `emulateGeometryDraw` succeeds; the resulting MSL is fed into
// the normal translated-draw encoder alongside the program's
// unchanged fragment MSL.
std::string synthesisePassThroughVertexMSL(const EmulatedDraw& draw);

}  // namespace appgl

#endif  // APPGL_SHADER_GEOMETRY_SHADER_EMULATOR_H
