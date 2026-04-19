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

}  // namespace appgl

#endif  // APPGL_SHADER_GEOMETRY_SHADER_EMULATOR_H
