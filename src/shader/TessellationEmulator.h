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

// TES output / input interface description. Populated by
// `scanTessEvalInterface` for consumption by `emulateTessellationDraw`
// once the full draw path lands. Fields here answer:
//   - which flat-scalar slots make up each output varying so we can
//     pack the expanded-vertex buffer correctly
//   - whether the TES writes gl_Position (required for the raster
//     path)
//   - whether the TES reads gl_TessCoord (always true in practice but
//     an explicit signal lets the body interpreter skip initialisation
//     otherwise)
struct TessEvalVarying {
    std::uint32_t id = 0;         // SPIR-V result id of the OpVariable
    std::uint32_t location = 0;   // layout(location=N) — only valid when hasLocation
    bool hasLocation = false;
    bool isBuiltIn = false;
    std::uint32_t builtIn = 0;    // spv::BuiltIn enum when isBuiltIn
    std::uint32_t typeId = 0;     // pointer-to-T; `scalarWidth` resolves T
    std::uint32_t scalarCount = 0; // runtime flat-scalar width of the element type
    std::string name;
    bool isArray = false;
    // Per-vertex inputs arrive through gl_in[N].<member>. isPerVertex
    // is true for such members; scalarCount reflects one element's
    // width (not the whole gl_in[] array) because the emulator
    // replays the TES per (patch, domain-coord) and fills gl_in[]
    // per patch.
    bool isPerVertex = false;
};

struct TessEvalInterface {
    std::vector<TessEvalVarying> outputs;
    std::vector<TessEvalVarying> inputs;
    bool writesPosition = false;
    bool readsTessCoord = false;
    bool parsed = false;
    std::string diagnostic;
};

// Walk the TES SPIR-V and populate a `TessEvalInterface`. All returned
// varyings are populated with their type's resolved scalar width so
// the downstream packer doesn't need to re-walk the module to answer
// "how many floats is this output". Failure returns `parsed=false`
// with `diagnostic` set.
TessEvalInterface scanTessEvalInterface(
    const std::uint32_t* tesSpirv,
    std::size_t tesWordCount);

// TCS I/O interface. TCS inputs match the VS outputs per vertex,
// arriving via gl_in[gl_PatchVerticesIn].<member>. TCS outputs are
// either:
//   - per-control-point (gl_out[gl_InvocationID].<member>) — sized by
//     `layout(vertices=W)`
//   - per-patch (`patch out ...`) — single value shared by all W
//     invocations + read by TES as gl_TessLevel* / patch inputs
//
// We track:
//   - outputVertices  (W — the `layout(vertices=W)` constant)
//   - writesTessLevelOuter / Inner (matters for the detector: when a
//     TCS writes levels dynamically we fall back to scan defaults)
//   - the full input/output varying list (same TessEvalVarying struct
//     reused; the `isPerVertex` flag distinguishes per-cp from patch)
struct TessControlInterface {
    std::vector<TessEvalVarying> outputs;
    std::vector<TessEvalVarying> inputs;
    std::uint32_t outputVertices = 0;
    bool writesTessLevelOuter = false;
    bool writesTessLevelInner = false;
    bool parsed = false;
    std::string diagnostic;
};

TessControlInterface scanTessControlInterface(
    const std::uint32_t* tcsSpirv,
    std::size_t tcsWordCount);

// Lightweight complexity classifier for a tess stage's function body.
// Classifies into three buckets so the detector can cheaply decide
// whether `emulateTessellationDraw` should attempt emulation or fall
// back to the translated-no-tess path. Per-bucket thresholds are a
// knob for future iters — right now only `Trivial` is a candidate
// for emulation, the others all fall back.
//
//   Trivial       — reads one scalar/vec varying per output, stores
//                   directly (passthrough). No loops, branches, or
//                   function calls. Always emulatable once draw path
//                   lands.
//   Simple        — trivial + a handful of arithmetic ops. Still no
//                   branches or loops. Future emulation target.
//   Complex       — loops, branches, function calls, extended
//                   instructions beyond a small GLSL.std.450 subset,
//                   or more than ~32 ops. Requires the full
//                   interpreter — deferred.
enum class TessBodyComplexity : std::uint8_t {
    Trivial,
    Simple,
    Complex,
};

struct TessBodyClassification {
    TessBodyComplexity complexity = TessBodyComplexity::Complex;
    std::uint32_t opcodeCount = 0;
    std::uint32_t storeCount = 0;
    std::uint32_t loadCount = 0;
    std::uint32_t branchCount = 0;
    std::uint32_t loopCount = 0;
    std::uint32_t functionCallCount = 0;
    bool parsed = false;
    std::string diagnostic;
};

TessBodyClassification classifyTessBody(
    const std::uint32_t* spirv,
    std::size_t wordCount);

// Narrow shape matcher for a TES body that's safe to emulate with
// the phase-2 "position = tess coord" baseline. Detects the pattern:
//
//   void main() {
//     gl_Position = vec4(gl_TessCoord.x, gl_TessCoord.y, gl_TessCoord.z, 1.0);
//   }
//
// (plus the glslang-emitted variants that swap component order or
// build the vec4 through OpVectorShuffle / per-component OpAccessChain
// of gl_TessCoord). No user varying writes, no patch-input loads, no
// interpolation — whatever `expandedVertexData` the phase-2a builder
// produces is literally the TES output.
//
// Returns `matched = true` only when ALL of:
//  - Output write set is exactly { gl_Position }
//  - The value stored to gl_Position is a 4-component composite where
//    x/y/z/(w) trace back to gl_TessCoord components (and 1.0 for w
//    when not from gl_TessCoord)
//  - No input loads beyond gl_TessCoord
//
// On match, `positionMapping[i]` for i ∈ {0,1,2,3} encodes how
// gl_Position.i is derived:
//   mapping >= 0   → gl_Position.i = gl_TessCoord[mapping] * scale[i]
//                                    + offset[i]
//                    (0=x, 1=y, 2=z — always a single-component pick)
//   mapping == -1  → gl_Position.i = positionConstant[i]
//                    (OpConstant float, typically 0.0 or 1.0)
//
// Phase-3c only recognised identity mappings (scale=1, offset=0).
// Phase-3d extends this to support affine transforms built from
// OpFMul / OpFAdd / OpFSub with OpConstant operands. Example
// shape that matches under phase-3d:
//
//   gl_Position = vec4(gl_TessCoord.x * 2.0 - 1.0,
//                      gl_TessCoord.y * 2.0 - 1.0,
//                      0.0, 1.0);
//
// Used at draw time to compute the actual TES gl_Position output for
// each generated domain vertex — no full interpreter required for
// this narrow shape.
//
// Used by `detectTessellationEmulatable` to flip `program.
// tessellationEmulated` on for the narrow set. `diagnostic` on a
// false return explains which predicate broke.
// Per-varying mapping record populated by phase-3e. Each stored-to
// location-decorated Output varying gets one entry; the mapping is
// the same shape as gl_Position's (single tessCoord component +
// affine scale/offset, or a constant fallback).
//
// Phase 3e-1 supports scalar float varyings only — `numComponents`
// is always 1 for now. Later phases will extend to vec2/3/4 with
// per-component mappings.
struct TessVaryingMapping {
    std::string name;
    std::uint32_t location = 0;
    std::uint8_t numComponents = 1;
    // Per-component source (same encoding as positionMapping):
    //   mapping[i] >= 0 → varying.i = tessCoord[mapping] * scale[i] + offset[i]
    //   mapping[i] == -1 → varying.i = constant[i]
    std::int8_t mapping[4] = {-1, -1, -1, -1};
    float scale[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    float offset[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    float constant[4] = {0.0f, 0.0f, 0.0f, 0.0f};
};

struct TessBodyPassthroughMatch {
    bool matched = false;
    bool parsed = false;
    std::string diagnostic;
    // Per-component source: -1 = use constant, 0..2 = gl_TessCoord.{x,y,z}.
    // Only meaningful when matched.
    std::int8_t positionMapping[4] = {0, 1, 2, -1};
    // Applied only when mapping[i] >= 0:
    //   out[i] = tessCoord[mapping[i]] * scale[i] + offset[i]
    // positionConstant[i] is used when mapping[i] == -1.
    float positionScale[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    float positionOffset[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    float positionConstant[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    // Phase-3e — per-user-varying mappings. Empty under phase-3d
    // (the legacy no-user-varying matcher still populates this).
    // Future phases consume it in the draw path + synth VS.
    std::vector<TessVaryingMapping> varyings;
};

TessBodyPassthroughMatch matchTessEvalPassthrough(
    const std::uint32_t* tesSpirv,
    std::size_t tesWordCount);

// Wider gate than `matchTessEvalPassthrough`: decides whether the
// GSE `Interpreter` (via `runTesForVertex`) can execute the TES
// body per generated domain vertex. Phase 3f-2 opens the door to
// shapes the passthrough matcher rejects — gl_Position writes mixed
// with side-effect SSBO reads/writes, for example — but still keeps
// out the hard cases:
//
//   - Reading `gl_in[]` (the TCS output array) requires per-patch-
//     vertex plumbing that doesn't exist yet.
//   - Writing `gl_TessLevel*` outputs from TES is a no-op per spec
//     but glslang still emits the opcode; harmless to interpret.
//
// The interpreter itself already bails on any opcode it doesn't
// support, so this classifier only needs to rule out interfaces
// the init path can't seed. Returns `interpretable = true` when
// the caller can safely attempt the interpreter path.
struct TessBodyInterpretabilityCheck {
    bool interpretable = false;
    bool parsed = false;
    std::string diagnostic;
};

TessBodyInterpretabilityCheck classifyTessEvalInterpretable(
    const std::uint32_t* tesSpirv,
    std::size_t tesWordCount);

// Phase 3f-3 helper: return the CPU-visible contents pointer of an
// MTLBuffer stored as `void*` in `GLBufferObject::metalBuffer`.
// Implemented in GLContext.mm (calls `[(id<MTLBuffer>)buf contents]`
// under the __bridge cast). Returns nullptr when the input is nil or
// when the buffer has been torn down. Lives here because the tess
// emulator is the first CPU-side consumer; future CPU-shader paths
// can reuse the same hook.
void* metalBufferContents(void* metalBuffer);

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
