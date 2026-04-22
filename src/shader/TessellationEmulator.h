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

// ─── Tessellation domain-point generation ────────────────────────────
//
// Per GL 4.6 §11.2.2, the tessellator takes an abstract domain
// (triangles / quads / isolines) + outer + inner levels + a spacing
// rule and generates a set of (u,v,w) points inside that domain plus
// index lists that connect them into triangles / line segments /
// points (with point_mode).
//
// All three domains produce 3-component coords for uniform interface:
//   triangles:  barycentric (u, v, w) with u+v+w = 1, w = 1-u-v
//   quads:      (u, v, 0)  with 0 <= u, v <= 1
//   isolines:   (u, v, 0)  with v as the line index / N-1, u along line
//
// Spacing rules from §11.2.2.1:
//   Equal             → outer levels rounded up to nearest integer,
//                       segments uniform size.
//   FractionalEven    → outer levels rounded up to nearest even int,
//                       inner segments uniform + two fractional edge
//                       segments that match the neighbouring patch.
//   FractionalOdd     → outer levels rounded up to nearest odd int,
//                       same fractional-edge shape.
//
// Indices are produced as GL_TRIANGLES (3 per triangle) or GL_LINES
// (2 per segment). Point-mode output is a separate pass — each unique
// coord becomes one GL_POINTS vertex.
enum class TessDomain : std::uint8_t {
    Triangles,
    Quads,
    Isolines,
};

enum class TessSpacing : std::uint8_t {
    Equal,
    FractionalEven,
    FractionalOdd,
};

struct TessDomainOutput {
    // Flat list of (u, v, w) coords, 3 floats per vertex. For quads +
    // isolines, w is always 0.0 (reserved so callers can treat every
    // domain uniformly via gl_TessCoord).
    std::vector<float> coords;

    // GL_TRIANGLES (3 per) for triangles + quads (non-point-mode), or
    // GL_LINES (2 per) for isolines (non-point-mode). When point_mode
    // is set, `indices` is empty — callers emit one GL_POINTS vertex
    // per entry in `coords`.
    std::vector<std::uint32_t> indices;

    // Draw topology the caller should use when encoding the draw.
    //   GL_TRIANGLES  — triangles / quads without point_mode
    //   GL_LINES      — isolines without point_mode
    //   GL_POINTS     — any domain with point_mode
    GLenum topology = 0;
};

// Minimal TCS scan: walk TCS SPIR-V and find constant OpStore writes
// to gl_TessLevelOuter[k] / gl_TessLevelInner[k]. For each level slot
// whose write target is a constant literal, write the value into the
// output array (initialised to `defaults[]` on entry). Returns true
// when at least one level was resolved statically; false means the
// TCS's tess levels are computed dynamically and need full
// interpretation (not yet supported).
//
// The common shader shapes CTS exercises (both
// `tessellation_shader.*` and `shading_language_420pack.*`) set every
// level to a constant literal. Those are the cases this function
// succeeds on. Iter 165 scope.
bool scanTessControlConstantLevels(
    const std::uint32_t* tcsSpirv,
    std::size_t tcsWordCount,
    float outerOut[4],
    float innerOut[2]);

// Generate the tessellation domain coords + indices for one patch.
// All outer / inner levels are pre-clamped by the caller to
// [1, GL_MAX_TESS_GEN_LEVEL]. Called once per patch per draw after
// the TCS runs (or, when TCS is absent, with the default levels from
// `glPatchParameterfv`).
//
// outerLevels: 4-element array indexed by domain:
//   triangles:  [0..2]  (only 3 outer edges)
//   quads:      [0..3]
//   isolines:   [0..1]  (outer[0] = v subdivisions, outer[1] = u subdivisions)
// innerLevels:
//   triangles:  [0] only (single inner level)
//   quads:      [0..1]
//   isolines:   unused
TessDomainOutput generateTessDomain(
    TessDomain domain,
    TessSpacing spacing,
    const float outerLevels[4],
    const float innerLevels[2],
    bool pointMode);

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
