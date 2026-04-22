#ifndef APPGL_SHADER_TESSELLATION_EMULATOR_H
#define APPGL_SHADER_TESSELLATION_EMULATOR_H

// Tessellation CPU emulator — stopgap for CTS conformance on Metal.
//
// Metal has native tessellation via compute-shader patch processing, but
// wiring SPIRV-Cross's MSL tess output through MTLRenderPipeline +
// MTLComputePipeline chaining is a multi-week project. Per the sprint
// plan's step 4 we mirror the GS-emul approach: run tessellation on CPU
// once per draw, emit an expanded per-vertex buffer, then hand it to the
// existing GS-emulation encode path (synth pass-through VS + original FS).
//
// Pipeline shape handled:
//   VS → [TCS] → TES → [GS] → FS          (GL 4.6 §11.2)
// TCS is optional (§11.2.3); without it the default tess levels come from
// `glPatchParameterfv(GL_PATCH_DEFAULT_{INNER,OUTER}_LEVEL, ...)`.
//
// CPU steps per drawArrays(GL_PATCHES, first, count) with
// GL_PATCH_VERTICES = V:
//
//   1. VS per vertex over [first .. first+count).
//   2. For each patch p (count / V patches):
//        a. Collect the V VS outputs as gl_in[] for the TCS.
//        b. Run TCS once per gl_InvocationID in [0, layout(vertices=W)).
//           This produces W control-point outputs plus the
//           gl_TessLevelOuter / gl_TessLevelInner scalars.
//        c. Generate tessellation domain vertices per TES's
//           execution mode (triangles / quads / isolines) + spacing
//           (equal / fractional_odd / fractional_even) + vertex order
//           (ccw / cw). This step is pure math — GL 4.6 §11.2.2 / §11.2.3
//           define the point set exactly.
//        d. TES per generated vertex:
//             - gl_in[] = TCS outputs (W control points)
//             - gl_TessCoord = generated domain coord (vec3 for triangles,
//               vec2 for quads/isolines.y=0)
//             - gl_TessLevelOuter / gl_TessLevelInner from TCS outputs
//           TES produces gl_Position + user varyings.
//   3. Expanded vertex buffer filled with the TES outputs, topology
//      picked from TES output declaration (isolines→GL_LINES,
//      triangles/quads→GL_TRIANGLES with per-patch index winding).
//
// Unlike the GS emulator, tess doesn't emit primitives sequentially —
// every (p, coord) pair is one output vertex, and the topology is
// derived from the tessellation algorithm's grid pattern.
//
// Status: SCAFFOLDING ONLY this iter. `detectTessellationEmulatable` is
// implemented as a minimal "has-TES, has-supported-execution-mode"
// check; `emulateTessellationDraw` is a stub returning .ok=false so
// every draw falls back to the existing non-emulated path.

#include <cstdint>
#include <string>
#include <vector>

#include "GeometryShaderEmulator.h"   // EmulatedDraw reused

typedef unsigned int GLenum;
typedef int GLsizei;
typedef int GLint;
typedef unsigned int GLuint;

namespace appgl {

struct GLProgramObject;
struct GLVertexArrayObject;
struct GLObjectStore;
class GLStateTracker;

// Detect whether a program's tessellation stages can be emulated. Called
// once at link time. Sets `program.tessellationEmulated` on success. Also
// populates the program's tess metadata fields whenever the SPIR-V parses
// (`hasTessellation`, `tessGenMode`, `tessGenSpacing`, etc.), regardless
// of whether the emulator can handle the body — those fields back the
// `glGetProgramiv(GL_TESS_*)` queries.
bool detectTessellationEmulatable(GLProgramObject& program);

// Emulate a single drawArrays/drawElements call for a program with a TES
// stage. Returns an `EmulatedDraw` whose `.ok` flag tells the caller
// whether the CPU path produced a usable expanded-vertex buffer. On
// `ok == false`, the caller falls back to the existing translated-pipeline
// path (which for tess programs either returns an error or silently
// produces undefined output).
EmulatedDraw emulateTessellationDraw(
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

}  // namespace appgl

#endif   // APPGL_SHADER_TESSELLATION_EMULATOR_H
