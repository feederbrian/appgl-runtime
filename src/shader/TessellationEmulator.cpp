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
#include <cstring>
#include <unordered_map>

#include "../objects/GLObjectStore.h"
#include "../state/GLStateTracker.h"
#include "ShaderInterpreter.h"
#include "ShaderTranslator.h"

#include "../../include/AppGL/glcorearb.h"

// Bring in spv:: enums from glslang's SPIR-V headers — same include
// path the GS emulator uses (`spirv.hpp` resolves via the target
// include dirs set up in CMakeLists).
#include "spirv.hpp"

namespace appgl {
namespace {

using namespace appgl::interp;

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

// ─── TCS constant-level extractor ────────────────────────────────────

// Narrow scanner for the "TCS writes constant tess levels" case.
//
// Supported shape:
//   %ct_1f     = OpConstant %float 1.0
//   %ptr       = OpAccessChain %_ptr_Output_float %gl_TessLevelOuter %const_K
//                OpStore %ptr %ct_1f
// where gl_TessLevelOuter is decorated with BuiltIn=TessLevelOuter
// (= 25) and gl_TessLevelInner with BuiltIn=TessLevelInner (= 26).
//
// Returns true if at least one level was resolved; false falls the
// caller back to `defaults` (for now that means the state's
// GL_PATCH_DEFAULT_{OUTER,INNER}_LEVEL values).
//
// The declarative half (decorations, constants, variables) comes from
// the shared `SpirvModule` parser. Access-chain + store tracking
// still walks the module's raw words because the parser doesn't
// record those op kinds — they're interpreter-state, not module-state.
bool scanTessControlConstantLevels(
    const std::uint32_t* spirv,
    std::size_t wordCount,
    float outerOut[4],
    float innerOut[2])
{
    if (spirv == nullptr || wordCount < 5) return false;

    SpirvModule module;
    if (!module.parse(spirv, wordCount)) return false;

    // AccessChain tracking isn't in SpirvModule (it records declarative
    // state only, not per-basic-block SSA). Single-index chains cover
    // every `gl_TessLevelOuter[k] = c` / `gl_TessLevelInner[k] = c`
    // shape glslang emits, which is all CTS's constant-level tests.
    struct AccessChain {
        std::uint32_t rootVarId = 0;
        std::uint32_t indexConstId = 0;
    };
    std::unordered_map<std::uint32_t, AccessChain> accessChains;

    std::size_t i = 5;
    while (i < wordCount) {
        const std::uint32_t inst = spirv[i];
        const std::uint16_t opcode = inst & 0xFFFF;
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0 || i + wc > wordCount) break;
        const std::uint32_t* w = spirv + i + 1;

        if (opcode == spv::OpAccessChain && wc >= 5) {
            AccessChain ac;
            ac.rootVarId = w[2];
            ac.indexConstId = w[3];   // first index only
            accessChains[w[1]] = ac;
        }
        i += wc;
    }

    // Scan for OpStore → AccessChain → gl_TessLevel* variable.
    // Lookup the root variable's BuiltIn decoration via SpirvModule;
    // the access-chain index + store value come from SpirvModule's
    // type-correct constant table.
    bool anyResolved = false;
    i = 5;
    while (i < wordCount) {
        const std::uint32_t inst = spirv[i];
        const std::uint16_t opcode = inst & 0xFFFF;
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0 || i + wc > wordCount) break;
        const std::uint32_t* w = spirv + i + 1;

        if (opcode == spv::OpStore && wc >= 3) {
            const std::uint32_t ptrId = w[0];
            const std::uint32_t valId = w[1];
            auto acIt = accessChains.find(ptrId);
            if (acIt == accessChains.end()) { i += wc; continue; }

            const AccessChain& ac = acIt->second;
            auto decoIt = module.decorations.find(ac.rootVarId);
            if (decoIt == module.decorations.end() || !decoIt->second.hasBuiltIn) {
                i += wc; continue;
            }
            const std::uint32_t builtIn = decoIt->second.builtIn;
            if (builtIn != spv::BuiltInTessLevelOuter &&
                builtIn != spv::BuiltInTessLevelInner) {
                i += wc; continue;
            }

            auto idxConstIt = module.constants.find(ac.indexConstId);
            auto valConstIt = module.constants.find(valId);
            if (idxConstIt == module.constants.end() ||
                valConstIt == module.constants.end()) {
                i += wc; continue;
            }
            const Value& idxC = idxConstIt->second;
            const Value& valC = valConstIt->second;
            const bool idxIsInt =
                idxC.kind == Value::Kind::Int || idxC.kind == Value::Kind::UInt;
            const bool valIsFloat = valC.kind == Value::Kind::Float;
            if (!idxIsInt || !valIsFloat) { i += wc; continue; }

            const std::int32_t idx = idxC.i[0];
            const float value = valC.f[0];
            if (builtIn == spv::BuiltInTessLevelOuter && idx >= 0 && idx < 4) {
                outerOut[idx] = value;
                anyResolved = true;
            } else if (builtIn == spv::BuiltInTessLevelInner && idx >= 0 && idx < 2) {
                innerOut[idx] = value;
                anyResolved = true;
            }
        }
        i += wc;
    }

    return anyResolved;
}

// ─── Shared TES/TCS interface walker ─────────────────────────────────

// Shared helper used by both `scanTessEvalInterface` and
// `scanTessControlInterface`. Walks the declarative half of a tess
// stage's I/O: for each Input/Output variable, decomposes block
// structs into per-member TessEvalVarying entries (so gl_PerVertex
// members end up as separately addressable slots) and resolves flat
// scalar widths via SpirvModule.
//
// The two callback hooks let the caller react to per-varying
// classification without exposing the interface layout (TCS cares
// about TessLevelOuter/Inner writes, TES cares about Position writes
// + TessCoord reads).
template <typename OnOutput, typename OnInput>
void walkTessInterface(
    const SpirvModule& module,
    std::vector<TessEvalVarying>* outputs,
    std::vector<TessEvalVarying>* inputs,
    OnOutput&& onOutput,
    OnInput&& onInput)
{
    auto record = [&](std::uint32_t varId, bool asOutput) {
        auto varIt = module.variables.find(varId);
        if (varIt == module.variables.end()) return;
        const VariableInfo& vi = varIt->second;
        auto ptrTypeIt = module.types.find(vi.typeId);
        if (ptrTypeIt == module.types.end() ||
            ptrTypeIt->second.kind != TypeInfo::Kind::Pointer) return;
        std::uint32_t pointee = ptrTypeIt->second.pointeeType;
        bool isPerVertex = false;

        auto pointeeIt = module.types.find(pointee);
        if (pointeeIt != module.types.end() &&
            pointeeIt->second.kind == TypeInfo::Kind::Array) {
            isPerVertex = true;
            pointee = pointeeIt->second.componentType;
        }

        TessEvalVarying ev;
        ev.id = varId;
        ev.typeId = pointee;
        ev.name = vi.name;
        ev.isPerVertex = isPerVertex;

        auto decoIt = module.decorations.find(varId);
        if (decoIt != module.decorations.end()) {
            if (decoIt->second.hasLocation) {
                ev.hasLocation = true;
                ev.location = decoIt->second.location;
            }
            if (decoIt->second.hasBuiltIn) {
                ev.isBuiltIn = true;
                ev.builtIn = decoIt->second.builtIn;
            }
        }

        auto leafIt = module.types.find(pointee);
        if (leafIt != module.types.end() &&
            leafIt->second.kind == TypeInfo::Kind::Struct) {
            auto memDecoIt = module.memberDecorations.find(pointee);
            std::uint32_t memberIdx = 0;
            for (auto memberType : leafIt->second.memberTypes) {
                TessEvalVarying sub;
                sub.id = varId;
                sub.typeId = memberType;
                sub.isPerVertex = isPerVertex;
                sub.scalarCount = module.scalarWidth(memberType);
                sub.name = vi.name;
                auto namesIt = module.memberNames.find(pointee);
                if (namesIt != module.memberNames.end()) {
                    auto nmIt = namesIt->second.find(memberIdx);
                    if (nmIt != namesIt->second.end()) sub.name = nmIt->second;
                }
                if (memDecoIt != module.memberDecorations.end()) {
                    auto perIt = memDecoIt->second.perMember.find(memberIdx);
                    if (perIt != memDecoIt->second.perMember.end()) {
                        if (perIt->second.hasBuiltIn) {
                            sub.isBuiltIn = true;
                            sub.builtIn = perIt->second.builtIn;
                        }
                        if (perIt->second.hasLocation) {
                            sub.hasLocation = true;
                            sub.location = perIt->second.location;
                        }
                    }
                }
                if (asOutput) {
                    onOutput(sub);
                    if (outputs) outputs->push_back(std::move(sub));
                } else {
                    onInput(sub);
                    if (inputs) inputs->push_back(std::move(sub));
                }
                ++memberIdx;
            }
            return;
        }

        ev.scalarCount = module.scalarWidth(pointee);
        if (asOutput) {
            onOutput(ev);
            if (outputs) outputs->push_back(std::move(ev));
        } else {
            onInput(ev);
            if (inputs) inputs->push_back(std::move(ev));
        }
    };

    for (const auto& kv : module.variables) {
        const std::uint32_t varId = kv.first;
        const VariableInfo& vi = kv.second;
        if (vi.storageClass == spv::StorageClassOutput) {
            record(varId, /*asOutput=*/true);
        } else if (vi.storageClass == spv::StorageClassInput) {
            record(varId, /*asOutput=*/false);
        }
    }
}

// ─── TES interface extractor ─────────────────────────────────────────

TessEvalInterface scanTessEvalInterface(
    const std::uint32_t* tesSpirv,
    std::size_t tesWordCount)
{
    TessEvalInterface iface;
    if (tesSpirv == nullptr || tesWordCount < 5) {
        iface.diagnostic = "empty SPIR-V";
        return iface;
    }

    SpirvModule module;
    if (!module.parse(tesSpirv, tesWordCount)) {
        iface.diagnostic = "SpirvModule::parse failed: " + module.parseError;
        return iface;
    }
    iface.parsed = true;

    walkTessInterface(
        module, &iface.outputs, &iface.inputs,
        [&](const TessEvalVarying& o) {
            if (o.isBuiltIn && o.builtIn == spv::BuiltInPosition) {
                iface.writesPosition = true;
            }
        },
        [&](const TessEvalVarying& i) {
            if (i.isBuiltIn && i.builtIn == spv::BuiltInTessCoord) {
                iface.readsTessCoord = true;
            }
        });
    return iface;
}

// ─── TCS interface extractor ─────────────────────────────────────────

TessControlInterface scanTessControlInterface(
    const std::uint32_t* tcsSpirv,
    std::size_t tcsWordCount)
{
    TessControlInterface iface;
    if (tcsSpirv == nullptr || tcsWordCount < 5) {
        iface.diagnostic = "empty SPIR-V";
        return iface;
    }

    SpirvModule module;
    if (!module.parse(tcsSpirv, tcsWordCount)) {
        iface.diagnostic = "SpirvModule::parse failed: " + module.parseError;
        return iface;
    }
    iface.parsed = true;

    // OutputVertices execution mode (layout(vertices=W)).
    auto execIt = module.executionModes.find(spv::ExecutionModeOutputVertices);
    if (execIt != module.executionModes.end() && !execIt->second.empty()) {
        iface.outputVertices = execIt->second[0];
    }

    walkTessInterface(
        module, &iface.outputs, &iface.inputs,
        [&](const TessEvalVarying& o) {
            if (o.isBuiltIn) {
                if (o.builtIn == spv::BuiltInTessLevelOuter) iface.writesTessLevelOuter = true;
                if (o.builtIn == spv::BuiltInTessLevelInner) iface.writesTessLevelInner = true;
            }
        },
        [&](const TessEvalVarying&) {});
    return iface;
}

// ─── Body complexity classifier ──────────────────────────────────────

// Walk the SPIR-V function body and count ops of interest. Used by the
// detector to cheaply reject bodies the interpreter doesn't yet
// handle. Counts are informational — the complexity bucket is derived
// at the end from simple heuristics.
TessBodyClassification classifyTessBody(
    const std::uint32_t* spirv,
    std::size_t wordCount)
{
    TessBodyClassification out;
    if (spirv == nullptr || wordCount < 5) {
        out.diagnostic = "empty SPIR-V";
        return out;
    }

    SpirvModule module;
    if (!module.parse(spirv, wordCount)) {
        out.diagnostic = "SpirvModule::parse failed: " + module.parseError;
        return out;
    }
    if (!module.haveFuncBody) {
        out.diagnostic = "no function body";
        return out;
    }
    out.parsed = true;

    std::size_t i = module.funcBodyStart;
    const std::size_t end = module.funcBodyEnd;
    while (i < end) {
        const std::uint32_t inst = module.words[i];
        const std::uint16_t opcode = inst & 0xFFFF;
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0 || i + wc > end) break;
        ++out.opcodeCount;

        switch (opcode) {
            case spv::OpStore:             ++out.storeCount; break;
            case spv::OpLoad:              ++out.loadCount; break;
            case spv::OpBranch:            ++out.branchCount; break;
            case spv::OpBranchConditional: ++out.branchCount; break;
            case spv::OpSwitch:            ++out.branchCount; break;
            case spv::OpLoopMerge:         ++out.loopCount; break;
            case spv::OpFunctionCall:      ++out.functionCallCount; break;
            default: break;
        }
        i += wc;
    }

    // Bucket heuristic. "Trivial" matches a passthrough TES that
    // writes gl_Position + a handful of varyings copy-out style
    // (one OpLoad per OpStore, no control flow). "Simple" allows
    // a small amount of arithmetic. Anything else is complex.
    const bool noControlFlow =
        out.branchCount == 0 && out.loopCount == 0 && out.functionCallCount == 0;
    const bool loadStoreBalanced = (out.storeCount > 0) &&
                                    (out.loadCount <= out.storeCount * 4);

    if (noControlFlow && out.opcodeCount <= 32 && loadStoreBalanced) {
        out.complexity = TessBodyComplexity::Trivial;
    } else if (noControlFlow && out.opcodeCount <= 128) {
        out.complexity = TessBodyComplexity::Simple;
    } else {
        out.complexity = TessBodyComplexity::Complex;
    }
    return out;
}

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

    // Full 5-stage (VS+TCS+TES+GS+FS) support deferred to a future
    // infrastructure round.
    if (!program.geometrySpirv.empty()) {
        program.linkLog += "\n[tess-emul] TES+GS 5-stage pipeline not yet emulated";
        return false;
    }

    // Validate the TES execution mode is one we know how to tessellate.
    // `extractTessellationModes` was originally built for the
    // glGetProgramiv(GL_TESS_*) queries; it returns a normalized GL
    // enum for domain + spacing + winding + a point_mode flag.
    const auto teModes = extractTessellationModes(
        program.tessEvalSpirv.data(), program.tessEvalSpirv.size());
    const bool knownDomain =
        teModes.genMode == GL_TRIANGLES ||
        teModes.genMode == GL_QUADS ||
        teModes.genMode == GL_ISOLINES;
    const bool knownSpacing =
        teModes.genSpacing == GL_EQUAL ||
        teModes.genSpacing == GL_FRACTIONAL_EVEN ||
        teModes.genSpacing == GL_FRACTIONAL_ODD;
    if (!knownDomain || !knownSpacing) {
        program.linkLog += "\n[tess-emul] TES execution mode outside emulated subset";
        return false;
    }

    // Exercise the TCS scanner when a TCS is attached — it's a no-op
    // without a TCS (TES-only program uses patch-default levels). The
    // return value is informational here; a dynamic TCS (false) still
    // lets detect succeed under the simplifying assumption that we'll
    // fall back to patch defaults at draw time.
    if (!program.tessControlSpirv.empty()) {
        float outer[4] = {1.0f, 1.0f, 1.0f, 1.0f};
        float inner[2] = {1.0f, 1.0f};
        (void)scanTessControlConstantLevels(
            program.tessControlSpirv.data(),
            program.tessControlSpirv.size(),
            outer, inner);
    }

    // Exercise the TES interface scanner — at detect-time this gives
    // us parse coverage over every tess program CTS throws at us so
    // a bug in the walker surfaces as a link error rather than a
    // hard-to-diagnose crash inside `emulateTessellationDraw`. The
    // scanner logs a diagnostic on failure but otherwise doesn't
    // affect detector behaviour (emul still declines to fire).
    TessEvalInterface teIface = scanTessEvalInterface(
        program.tessEvalSpirv.data(), program.tessEvalSpirv.size());
    if (!teIface.parsed) {
        program.linkLog += "\n[tess-emul] TES interface parse: " + teIface.diagnostic;
    }

    // Same for TCS when one is attached. The outputVertices metadata
    // also lands on the program object so `glGetProgramiv(
    // GL_TESS_CONTROL_OUTPUT_VERTICES)` has a backing value extracted
    // via the shared parser (the previous path uses a different
    // extractor in GLContext.mm — this keeps us in sync with no
    // behaviour change when both agree).
    if (!program.tessControlSpirv.empty()) {
        TessControlInterface tcIface = scanTessControlInterface(
            program.tessControlSpirv.data(), program.tessControlSpirv.size());
        if (!tcIface.parsed) {
            program.linkLog += "\n[tess-emul] TCS interface parse: " + tcIface.diagnostic;
        }
    }

    // Classify TES body complexity. Result is informational right
    // now — when the draw path lands, only `Trivial` cases will
    // be attempted; `Simple` and `Complex` fall back. Running the
    // classifier here surfaces walker bugs at link time for every
    // tess program CTS throws at us.
    TessBodyClassification teClass = classifyTessBody(
        program.tessEvalSpirv.data(), program.tessEvalSpirv.size());
    if (!teClass.parsed) {
        program.linkLog += "\n[tess-emul] TES body classify: " + teClass.diagnostic;
    }

    // Stays false through iter 169 — detection probes landed, but the
    // actual draw-time emulation (VS + TES interpretation) is the
    // next infrastructure milestone. Flipping this true without the
    // draw path wired would route every tess draw through
    // `emulateTessellationDraw`'s stub and silently drop the output,
    // which the CTS would catch as a data-compare failure far worse
    // than the existing "tess draws produce nothing meaningful" state.
    (void)isSupportedTessMode;
    return false;
}

// ─── Public API — draw-time emulator ─────────────────────────────────
//
// Iter 186 scope: phase-1 wiring. Computes the per-patch tessellation
// domain (via scanTessControlConstantLevels + generateTessDomain) and
// records the point/index count so future iters can slot the VS/TES
// interpretation onto the same preparation. Still returns
// `.ok = false` — the draw path falls back to the translated-no-tess
// path for now. Phase 2 will produce a real EmulatedDraw and flip
// `detectTessellationEmulatable` to return true for the narrow
// pass-through cases.

namespace {

// Translate the program's `tessGenMode` (GL_TRIANGLES / GL_QUADS /
// GL_ISOLINES) to the emulator's `TessDomain` enum. Caller-validated
// to be one of the three on entry, but we fall back to Triangles for
// safety in case a future mode creeps through.
TessDomain tessDomainFromGenMode(GLenum genMode) {
    switch (genMode) {
        case GL_QUADS:    return TessDomain::Quads;
        case GL_ISOLINES: return TessDomain::Isolines;
        case GL_TRIANGLES:
        default:          return TessDomain::Triangles;
    }
}

TessSpacing tessSpacingFromGenSpacing(GLenum genSpacing) {
    switch (genSpacing) {
        case GL_FRACTIONAL_EVEN: return TessSpacing::FractionalEven;
        case GL_FRACTIONAL_ODD:  return TessSpacing::FractionalOdd;
        case GL_EQUAL:
        default:                 return TessSpacing::Equal;
    }
}

}  // namespace

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
    (void)vao;
    (void)objects;
    (void)first;
    (void)elementIndices;
    (void)instanceCount;
    (void)baseInstance;

    EmulatedDraw d;
    d.ok = false;

    // Phase-1 pre-checks — anything outside the expected shape short-
    // circuits immediately so the translated-no-tess path takes over.
    if (drawMode != GL_PATCHES || count <= 0) {
        d.diagnostic = "tess-emul: non-PATCHES draw or empty count";
        return d;
    }
    if (!program.hasTessellation || program.tessEvalSpirv.empty()) {
        d.diagnostic = "tess-emul: program has no tess-eval stage";
        return d;
    }

    const GLint patchVertices = state.tessellationState().patchVertices;
    if (patchVertices <= 0 || count < patchVertices) {
        d.diagnostic = "tess-emul: count smaller than patchVertices — draw is a no-op";
        return d;
    }
    const std::size_t numPatches = static_cast<std::size_t>(count) /
                                   static_cast<std::size_t>(patchVertices);

    const TessDomain domain = tessDomainFromGenMode(program.tessGenMode);
    const TessSpacing spacing = tessSpacingFromGenSpacing(program.tessGenSpacing);
    const bool pointMode = (program.tessGenPointMode == GL_TRUE);

    // Resolve tessellation levels. When a TCS is attached and writes
    // constant levels, `scanTessControlConstantLevels` reads them out
    // of the SPIR-V. Otherwise fall back to the GL state's
    // glPatchParameterfv(GL_PATCH_DEFAULT_*_LEVEL) values.
    float outerLevels[4];
    float innerLevels[2];
    const auto& tessState = state.tessellationState();
    for (int i = 0; i < 4; ++i) outerLevels[i] = tessState.defaultOuterLevel[i];
    for (int i = 0; i < 2; ++i) innerLevels[i] = tessState.defaultInnerLevel[i];
    if (!program.tessControlSpirv.empty()) {
        (void)scanTessControlConstantLevels(
            program.tessControlSpirv.data(),
            program.tessControlSpirv.size(),
            outerLevels, innerLevels);
    }

    // Generate the domain coord set for ONE patch. Every patch in this
    // draw shares the same levels (either static TCS constants or the
    // GL_PATCH_DEFAULT_* state) so the coord layout is identical.
    TessDomainOutput domainOut =
        generateTessDomain(domain, spacing, outerLevels, innerLevels, pointMode);
    const std::size_t coordsPerPatch = domainOut.coords.size() / 3;
    if (coordsPerPatch == 0) {
        d.diagnostic = "tess-emul: domain produced zero vertices";
        return d;
    }

    // Phase-2a: build an EmulatedDraw whose positions come straight
    // from the tess-domain coords. Each output vertex's position is
    // (u, v, w, 1.0) — the raw barycentric / parametric triple. No
    // user varyings, no VS/TES execution. This is the "zero-op
    // passthrough" baseline: downstream ViewFromMetal code can
    // inspect the buffer to see that phase-2 scaffolding produced
    // a non-empty output.
    //
    // The draw-path caller still falls back to the legacy translated
    // path — `.ok` stays false until phase 2b enables a narrow
    // allowlist (TES body that writes exactly
    // `gl_Position = gl_TessCoord` shape).
    const std::size_t totalVerts = coordsPerPatch * numPatches;
    constexpr std::size_t kPosFloats = 4;
    d.vertexCount = totalVerts;
    d.floatsPerVertex = kPosFloats;
    d.expandedVertexData.assign(totalVerts * kPosFloats, 0.0f);
    d.topology = domainOut.topology;

    // Fill in position data. For GL_POINTS/GL_LINES/GL_TRIANGLES the
    // emitter's ordering is index-dependent — the caller's Metal
    // encoder consumes expandedVertexData as a flat vertex buffer
    // indexed by gl_VertexIndex, so we need to expand the index list
    // into a de-indexed vertex stream. (GSE follows the same pattern
    // — no index buffer in the EmulatedDraw output.)
    const std::vector<float>& coords = domainOut.coords;
    const std::vector<std::uint32_t>& indices = domainOut.indices;
    const bool isPoints = (domainOut.topology == GL_POINTS);
    const std::size_t expandPerPatch = isPoints ? coordsPerPatch : indices.size();
    // Recompute if point-mode path was chosen — indices empty, walk coords.
    d.vertexCount = expandPerPatch * numPatches;
    d.expandedVertexData.assign(d.vertexCount * kPosFloats, 0.0f);
    for (std::size_t p = 0; p < numPatches; ++p) {
        const std::size_t dstPatchBase = p * expandPerPatch * kPosFloats;
        if (isPoints) {
            // One vertex per coord.
            for (std::size_t i = 0; i < coordsPerPatch; ++i) {
                const float u = coords[i * 3 + 0];
                const float v = coords[i * 3 + 1];
                const float w = coords[i * 3 + 2];
                const std::size_t dst = dstPatchBase + i * kPosFloats;
                d.expandedVertexData[dst + 0] = u;
                d.expandedVertexData[dst + 1] = v;
                d.expandedVertexData[dst + 2] = w;
                d.expandedVertexData[dst + 3] = 1.0f;
            }
        } else {
            // Walk index list; one vertex per index.
            for (std::size_t i = 0; i < indices.size(); ++i) {
                const std::uint32_t idx = indices[i];
                const float u = coords[idx * 3 + 0];
                const float v = coords[idx * 3 + 1];
                const float w = coords[idx * 3 + 2];
                const std::size_t dst = dstPatchBase + i * kPosFloats;
                d.expandedVertexData[dst + 0] = u;
                d.expandedVertexData[dst + 1] = v;
                d.expandedVertexData[dst + 2] = w;
                d.expandedVertexData[dst + 3] = 1.0f;
            }
        }
    }

    // Stays false through iter 187 — phase-2b needs to both (a)
    // detect the narrow TES body shape where `gl_Position =
    // gl_TessCoord[.xyzw permutations]` is the only output write,
    // and (b) verify the FS has no user-varying inputs (otherwise
    // the synth pass-through VS will fail pipeline-state validation
    // against the FS's expected locations). Keep returning false
    // so the existing-translation path handles every tess draw.
    d.diagnostic = "tess-emul phase-2a: " + std::to_string(numPatches) +
                   " patches × " + std::to_string(expandPerPatch) +
                   " output verts = " + std::to_string(d.vertexCount) +
                   " (topology=0x" +
                   std::to_string(static_cast<unsigned>(domainOut.topology)) +
                   ") — pending phase-2b enablement";
    return d;
}

}  // namespace appgl
