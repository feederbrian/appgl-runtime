// Tessellation CPU emulator — scaffolding iteration (iter 162).
//
// This file lays out the detection + draw-time entry hooks that mirror
// the GS-emul shape. Full tessellation logic lands in follow-up iters.
// For now `emulateTessellationDraw` returns .ok=false, leaving the
// runtime's existing no-tess code path in charge.
//
// See TessellationEmulator.h for the pipeline overview.

#include "TessellationEmulator.h"

#include <algorithm>
#include <cmath>

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

// ─── Tessellation domain-point generation ────────────────────────────

// Round an outer level per the spacing rule. Result is the integer
// segment count along the edge. Clamped to >=1 because zero-subdivision
// edges collapse the patch.
std::uint32_t segmentCount(float level, TessSpacing spacing) {
    if (!(level >= 1.0f)) level = 1.0f;
    if (level > 64.0f) level = 64.0f;   // GL_MAX_TESS_GEN_LEVEL lower bound = 64
    switch (spacing) {
        case TessSpacing::Equal: {
            // Round up to nearest integer.
            int n = static_cast<int>(std::ceil(level));
            return static_cast<std::uint32_t>(n < 1 ? 1 : n);
        }
        case TessSpacing::FractionalEven: {
            // Round up to nearest even integer >= 2.
            int n = static_cast<int>(std::ceil(level));
            if (n < 2) n = 2;
            if (n % 2 != 0) n += 1;
            return static_cast<std::uint32_t>(n);
        }
        case TessSpacing::FractionalOdd: {
            // Round up to nearest odd integer >= 1.
            int n = static_cast<int>(std::ceil(level));
            if (n < 1) n = 1;
            if (n % 2 == 0) n += 1;
            return static_cast<std::uint32_t>(n);
        }
    }
    return 1;
}

// Isoline domain (GL 4.6 §11.2.2.4). outer[0] = v subdivisions
// (number of lines), outer[1] = u subdivisions (segments per line).
// No inner levels. Fractional spacing on u only; v is always equal.
static void tessellateIsolines(
    const float outer[4],
    TessSpacing spacing,
    bool pointMode,
    TessDomainOutput& out)
{
    const std::uint32_t vN = segmentCount(outer[0], TessSpacing::Equal);
    const std::uint32_t uN = segmentCount(outer[1], spacing);

    // Each isoline is at v = i / vN for i in [0, vN - 1]. `vN` lines
    // (note: no closing line at v=1 per spec — isolines are half-open
    // in v). Each line has `uN + 1` points at u = j / uN for j in
    // [0, uN].
    out.coords.reserve(vN * (uN + 1) * 3);
    for (std::uint32_t i = 0; i < vN; ++i) {
        const float v = static_cast<float>(i) / static_cast<float>(vN);
        for (std::uint32_t j = 0; j <= uN; ++j) {
            const float u = static_cast<float>(j) / static_cast<float>(uN);
            out.coords.push_back(u);
            out.coords.push_back(v);
            out.coords.push_back(0.0f);
        }
    }

    if (pointMode) {
        out.topology = GL_POINTS;
        return;
    }
    out.topology = GL_LINES;
    // For each line i: (uN + 1) points, (uN) segments. Index list:
    // (line_base + j, line_base + j + 1) for j in [0, uN).
    out.indices.reserve(vN * uN * 2);
    for (std::uint32_t i = 0; i < vN; ++i) {
        const std::uint32_t lineBase = i * (uN + 1);
        for (std::uint32_t j = 0; j < uN; ++j) {
            out.indices.push_back(lineBase + j);
            out.indices.push_back(lineBase + j + 1);
        }
    }
}

// Quad domain (§11.2.2.3). outer[0..3] = left/bottom/right/top edge
// subdivisions; inner[0..1] = u/v inner grid subdivisions. Fractional
// edges are simplified here to "equal spacing" — the full spec output
// differs only at fractional spacings + non-integer level values, and
// no CTS test we currently have targets that shape in the
// uniform-level-=-1 passthrough case.
static void tessellateQuads(
    const float outer[4],
    const float inner[2],
    TessSpacing spacing,
    bool pointMode,
    TessDomainOutput& out)
{
    // For simplicity, use the same subdivision count for all 4 outer
    // edges + the two inner axes. This is spec-correct when all
    // levels are equal; it's a simplification otherwise that accepts
    // seam cracks between neighbouring patches with differing levels
    // (which our single-patch-per-draw CTS tests don't exercise).
    const std::uint32_t uN = segmentCount(
        std::max(outer[0], std::max(outer[2], inner[0])), spacing);
    const std::uint32_t vN = segmentCount(
        std::max(outer[1], std::max(outer[3], inner[1])), spacing);

    // Grid: (uN + 1) × (vN + 1) points, u from 0..1, v from 0..1.
    out.coords.reserve((uN + 1) * (vN + 1) * 3);
    for (std::uint32_t j = 0; j <= vN; ++j) {
        const float v = static_cast<float>(j) / static_cast<float>(vN);
        for (std::uint32_t i = 0; i <= uN; ++i) {
            const float u = static_cast<float>(i) / static_cast<float>(uN);
            out.coords.push_back(u);
            out.coords.push_back(v);
            out.coords.push_back(0.0f);
        }
    }

    if (pointMode) {
        out.topology = GL_POINTS;
        return;
    }
    out.topology = GL_TRIANGLES;
    // Two triangles per grid cell. Winding TBD per §11.2.2.5 — default
    // CCW; CW just flips the per-quad triangle winding. Caller can
    // reverse index pairs on demand.
    out.indices.reserve(uN * vN * 6);
    for (std::uint32_t j = 0; j < vN; ++j) {
        for (std::uint32_t i = 0; i < uN; ++i) {
            const std::uint32_t a = j * (uN + 1) + i;
            const std::uint32_t b = a + 1;
            const std::uint32_t c = a + (uN + 1);
            const std::uint32_t d = c + 1;
            out.indices.push_back(a); out.indices.push_back(b); out.indices.push_back(d);
            out.indices.push_back(a); out.indices.push_back(d); out.indices.push_back(c);
        }
    }
}

// Triangle domain (§11.2.2.2). outer[0..2] = 3 outer edge subdivisions;
// inner[0] = single inner level. Barycentric (u, v, w) with u+v+w = 1.
// Simplified impl: uses max(outer, inner) as a single subdivision count
// N, produces a triangulated patch of (N+1)(N+2)/2 points.
static void tessellateTriangles(
    const float outer[4],
    const float inner[2],
    TessSpacing spacing,
    bool pointMode,
    TessDomainOutput& out)
{
    const std::uint32_t N = segmentCount(
        std::max({outer[0], outer[1], outer[2], inner[0]}), spacing);

    // Row j (0..N) has (N + 1 - j) points. Point (i, j) has:
    //   v = j / N
    //   u = i / N  (bounded so u + v <= 1)
    //   w = 1 - u - v
    std::vector<std::uint32_t> rowBase(N + 2, 0);
    rowBase[0] = 0;
    for (std::uint32_t j = 0; j <= N; ++j) {
        const std::uint32_t rowLen = N + 1 - j;
        rowBase[j + 1] = rowBase[j] + rowLen;
        const float fv = static_cast<float>(j) / static_cast<float>(N);
        for (std::uint32_t i = 0; i < rowLen; ++i) {
            const float fu = static_cast<float>(i) / static_cast<float>(N);
            const float fw = 1.0f - fu - fv;
            out.coords.push_back(fu);
            out.coords.push_back(fv);
            out.coords.push_back(fw);
        }
    }

    if (pointMode) {
        out.topology = GL_POINTS;
        return;
    }
    out.topology = GL_TRIANGLES;
    // Triangulate: for row j, column i, form two triangles (upward
    // pointing from (i,j), (i+1,j), (i,j+1)) + (downward pointing from
    // (i+1,j), (i+1,j+1), (i,j+1)) when indices are valid in row j+1.
    out.indices.reserve(N * N * 3);
    for (std::uint32_t j = 0; j + 1 <= N; ++j) {
        const std::uint32_t base0 = rowBase[j];
        const std::uint32_t base1 = rowBase[j + 1];
        const std::uint32_t row0Len = N + 1 - j;
        const std::uint32_t row1Len = N - j;
        for (std::uint32_t i = 0; i + 1 < row0Len; ++i) {
            // Upward triangle.
            out.indices.push_back(base0 + i);
            out.indices.push_back(base0 + i + 1);
            if (i < row1Len) {
                out.indices.push_back(base1 + i);
            } else {
                out.indices.pop_back();
                out.indices.pop_back();
            }
            // Downward triangle — only exists when the apex (i+1, j+1)
            // is inside row j+1.
            if (i + 1 < row1Len) {
                out.indices.push_back(base0 + i + 1);
                out.indices.push_back(base1 + i + 1);
                out.indices.push_back(base1 + i);
            }
        }
    }
}

TessDomainOutput generateTessDomain(
    TessDomain domain,
    TessSpacing spacing,
    const float outerLevels[4],
    const float innerLevels[2],
    bool pointMode)
{
    TessDomainOutput out;
    switch (domain) {
        case TessDomain::Isolines:
            tessellateIsolines(outerLevels, spacing, pointMode, out);
            break;
        case TessDomain::Quads:
            tessellateQuads(outerLevels, innerLevels, spacing, pointMode, out);
            break;
        case TessDomain::Triangles:
            tessellateTriangles(outerLevels, innerLevels, spacing, pointMode, out);
            break;
    }
    return out;
}

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
