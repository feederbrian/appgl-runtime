// Tessellation CPU emulator — scaffolding iteration (iter 162).
//
// This file lays out the detection + draw-time entry hooks that mirror
// the GS-emul shape. Full tessellation logic lands in follow-up iters.
// For now `emulateTessellationDraw` returns .ok=false, leaving the
// runtime's existing no-tess code path in charge.
//
// See TessellationEmulator.h for the pipeline overview.

#include "TessellationEmulator.h"

#include "../objects/GLObjectStore.h"

#include "../../include/AppGL/glcorearb.h"

// Bring in spv:: enums from glslang's SPIR-V headers — same include
// path the GS emulator uses (`spirv.hpp` resolves via the target
// include dirs set up in CMakeLists).
#include "spirv.hpp"

namespace appgl {
namespace {

// TES execution modes we can handle (GL 4.6 §11.2.3 Table 11.8):
//   ExecutionModeTriangles    → barycentric (u,v,w) with u+v+w = 1
//   ExecutionModeQuads        → (u,v) with 0 <= u,v <= 1
//   ExecutionModeIsolines     → (u,v) with v as line index, u along line
// Spacing:
//   SpacingEqual
//   SpacingFractionalEven
//   SpacingFractionalOdd
// Ordering:
//   VertexOrderCw
//   VertexOrderCcw
//
// PointMode modifies the output: instead of lines/triangles, emit a
// point at each generated domain coord. CTS shading_language_420pack
// tests that set `layout(isolines, point_mode)` on the TES need this.
bool isSupportedTessMode(std::uint32_t mode) {
    switch (mode) {
        case spv::ExecutionModeTriangles:
        case spv::ExecutionModeQuads:
        case spv::ExecutionModeIsolines:
        case spv::ExecutionModeSpacingEqual:
        case spv::ExecutionModeSpacingFractionalEven:
        case spv::ExecutionModeSpacingFractionalOdd:
        case spv::ExecutionModeVertexOrderCw:
        case spv::ExecutionModeVertexOrderCcw:
        case spv::ExecutionModePointMode:
            return true;
        default:
            return false;
    }
}

}  // namespace

// ─── Public API — link-time detection ────────────────────────────────

bool detectTessellationEmulatable(GLProgramObject& program) {
    program.tessellationEmulated = false;

    // Must have a TES at minimum (§11.2.3: TCS is optional).
    if (program.tessEvalSpirv.empty()) return false;

    // Every tess-emulated draw will later need the GS-emul encode
    // infrastructure, so short-circuit if that path is unavailable.
    // (Non-emulated GS-present programs fall through the normal link.)
    // Presence of a GS in the chain is fine — the GS emulator can run
    // on top of our tessellated output — but that combined path isn't
    // wired in this scaffolding iter. Flag accordingly.
    if (!program.geometrySpirv.empty()) {
        // Full 5-stage (VS+TCS+TES+GS+FS) support is deferred.
        // Surface the decision in the program's link log so the
        // CTS triage tooling can see why the draw fell back.
        program.linkLog += "\n[tess-emul] TES+GS 5-stage pipeline not yet emulated";
        return false;
    }

    // Scaffolding gate: this iter only records the detect call —
    // actual emulation lands in iter 163+. Leave tessellationEmulated
    // false so the runtime's existing non-emulated path stays in
    // charge. Once the draw-time routine is implemented, flip this to
    // `return true;` once the supported-execution-mode / opcode checks
    // pass.
    (void)isSupportedTessMode;
    return false;
}

// ─── Public API — draw-time stub ─────────────────────────────────────

EmulatedDraw emulateTessellationDraw(
    GLProgramObject& program,
    const GLVertexArrayObject& vao,
    GLObjectStore& objects,
    const GLStateTracker& state,
    GLenum drawMode,
    GLsizei count,
    GLint first,
    const std::uint32_t* elementIndices,
    GLsizei instanceCount,
    GLuint baseInstance)
{
    (void)program;
    (void)vao;
    (void)objects;
    (void)state;
    (void)drawMode;
    (void)count;
    (void)first;
    (void)elementIndices;
    (void)instanceCount;
    (void)baseInstance;

    EmulatedDraw d;
    d.ok = false;
    d.diagnostic = "tessellation emulation not yet implemented (iter 162 scaffolding)";
    return d;
}

}  // namespace appgl
