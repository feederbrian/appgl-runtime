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
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unordered_map>
#include <unordered_set>

#include "../objects/GLObjectStore.h"
#include "../state/GLStateTracker.h"
#include "GeometryShaderEmulator.h"   // runVsForVertex + EmulatedVertex
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

std::uint8_t interpolationFromDecorations(const DecorationSet& decorations) {
    if (decorations.isFlat) return 1;
    if (decorations.isNoPerspective) return 2;
    if (decorations.isCentroid) return 3;
    return 0;
}

std::uint32_t scalarTypeIdForTessType(
    const SpirvModule& module,
    std::uint32_t typeId)
{
    auto it = module.types.find(typeId);
    if (it == module.types.end()) return 0;
    const TypeInfo& type = it->second;
    switch (type.kind) {
        case TypeInfo::Kind::Vec2:
        case TypeInfo::Kind::Vec3:
        case TypeInfo::Kind::Vec4:
            return type.componentType;
        case TypeInfo::Kind::Matrix:
        case TypeInfo::Kind::Array:
        case TypeInfo::Kind::RuntimeArray:
            return scalarTypeIdForTessType(module, type.componentType);
        case TypeInfo::Kind::Pointer:
            return scalarTypeIdForTessType(module, type.pointeeType);
        default:
            return typeId;
    }
}

std::uint8_t baseTypeForTessType(
    const SpirvModule& module,
    std::uint32_t typeId)
{
    const std::uint32_t scalarTypeId =
        scalarTypeIdForTessType(module, typeId);
    auto it = module.types.find(scalarTypeId);
    if (it == module.types.end()) return 0;
    switch (it->second.kind) {
        case TypeInfo::Kind::Int:  return 1;
        case TypeInfo::Kind::UInt: return 2;
        default:                   return 0;
    }
}

bool appglEnvEnabledDefaultOn(const char* name) {
    const char* v = std::getenv(name);
    return v == nullptr || (v[0] != '0' && v[0] != '\0');
}

void addTessUniformBuffersFromModule(const std::vector<std::uint32_t>& spirv,
                                     GLObjectStore& objects,
                                     const GLStateTracker& state,
                                     UniformBufferMap& out) {
    if (spirv.empty()) return;
    SpirvModule mod;
    if (!mod.parse(spirv.data(), spirv.size())) return;

    auto addBinding = [&](std::uint32_t binding) {
        if (out.count(binding) != 0) return;
        GLIndexedBufferBinding bb =
            state.indexedBufferBinding(GL_UNIFORM_BUFFER, binding);
        if (bb.buffer == 0) return;
        const GLBufferObject* bufObj = objects.buffers().get(bb.buffer);
        if (bufObj == nullptr || bufObj->shadowBytes.empty()) return;
        const std::uint8_t* dataPtr = bufObj->shadowBytes.data();
        std::size_t dataSize = bufObj->shadowBytes.size();
        if (bb.offset > 0) {
            if (static_cast<std::size_t>(bb.offset) >= dataSize) return;
            dataPtr += bb.offset;
            dataSize -= static_cast<std::size_t>(bb.offset);
        }
        if (bb.size > 0 && static_cast<std::size_t>(bb.size) < dataSize) {
            dataSize = static_cast<std::size_t>(bb.size);
        }
        UniformBufferRegion region;
        region.ptr = dataPtr;
        region.size = dataSize;
        out[binding] = region;
    };

    for (const auto& [varId, info] : mod.variables) {
        if (info.storageClass != spv::StorageClassUniform) continue;
        auto tIt = mod.types.find(info.typeId);
        if (tIt == mod.types.end()) continue;
        auto pT = mod.types.find(tIt->second.pointeeType);
        if (pT == mod.types.end()) continue;
        auto vDec = mod.decorations.find(varId);
        if (vDec == mod.decorations.end() || !vDec->second.hasBinding) continue;
        const std::uint32_t baseBinding = vDec->second.binding;

        if (pT->second.kind == TypeInfo::Kind::Struct) {
            auto blockDec = mod.decorations.find(tIt->second.pointeeType);
            if (blockDec != mod.decorations.end() && blockDec->second.isBlock &&
                !blockDec->second.isBufferBlock) {
                addBinding(baseBinding);
            }
        } else if (pT->second.kind == TypeInfo::Kind::Array) {
            auto innerT = mod.types.find(pT->second.componentType);
            if (innerT == mod.types.end() ||
                innerT->second.kind != TypeInfo::Kind::Struct) {
                continue;
            }
            auto blockDec = mod.decorations.find(pT->second.componentType);
            if (blockDec == mod.decorations.end() || !blockDec->second.isBlock ||
                blockDec->second.isBufferBlock) {
                continue;
            }
            auto lenIt = mod.constants.find(pT->second.arrayLengthConstId);
            const std::uint32_t arrayLen = (lenIt != mod.constants.end())
                ? static_cast<std::uint32_t>(lenIt->second.i[0]) : 0;
            for (std::uint32_t inst = 0; inst < arrayLen; ++inst) {
                addBinding(baseBinding + inst);
            }
        }
    }
}

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
            ev.interp = interpolationFromDecorations(decoIt->second);
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
                sub.baseType = baseTypeForTessType(module, memberType);
                sub.interp = ev.interp;
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
                        const std::uint8_t memberInterp =
                            interpolationFromDecorations(perIt->second);
                        if (memberInterp != 0) sub.interp = memberInterp;
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
        ev.baseType = baseTypeForTessType(module, pointee);
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

// ─── Phase-3f-2 interpretability classifier ──────────────────────────
//
// Wider gate than the passthrough matcher below. Interpreter path
// cost: one `Interpreter` per generated domain vertex. Safe to admit
// any TES body that only reads built-ins the init seeding knows how
// to populate (gl_TessCoord, gl_PrimitiveID) — reading gl_in[] or
// per-patch varyings would return zeros, which corrupts rasterization
// output silently. So we stay strict on inputs and rely on the
// interpreter itself to bail on unsupported opcodes.

TessBodyInterpretabilityCheck classifyTessEvalInterpretable(
    const std::uint32_t* tesSpirv,
    std::size_t tesWordCount)
{
    TessBodyInterpretabilityCheck out;
    if (tesSpirv == nullptr || tesWordCount < 5) {
        out.diagnostic = "empty SPIR-V";
        return out;
    }
    SpirvModule module;
    if (!module.parse(tesSpirv, tesWordCount)) {
        out.diagnostic = "SpirvModule::parse failed: " + module.parseError;
        return out;
    }
    if (!module.haveFuncBody) {
        out.diagnostic = "no function body";
        return out;
    }
    out.parsed = true;

    // Walk every Input variable and reject anything the interpreter
    // can't seed. Accept shapes:
    //   - Built-in inputs: gl_TessCoord (13), gl_PrimitiveID (7),
    //     gl_PatchVerticesIn (14).
    //   - gl_in[] arrays: Input variable typed Array-of-Struct where
    //     the struct has at least one BuiltIn-decorated member
    //     (i.e. a gl_PerVertex block). Default-on in Sprint 18 after
    //     the R2 cull_distance metadata fix; set
    //     APPGL_ENABLE_TESS_EMUL_GLIN=0 to force the old fallback.
    // Reject per-patch Input varyings (non-array Input struct) and
    // location-decorated user inputs — those still need dedicated
    // plumbing.
    static const bool glInEnabled =
        appglEnvEnabledDefaultOn("APPGL_ENABLE_TESS_EMUL_GLIN");
    for (const auto& [varId, info] : module.variables) {
        if (info.storageClass != spv::StorageClassInput) continue;
        auto dIt = module.decorations.find(varId);
        if (dIt != module.decorations.end() && dIt->second.hasBuiltIn) {
            const std::uint32_t bi = dIt->second.builtIn;
            if (bi == 13 /*TessCoord*/ ||
                bi == 7  /*PrimitiveId*/ ||
                bi == 14 /*PatchVertices*/) {
                continue;
            }
            out.diagnostic = "unsupported builtin input: " + std::to_string(bi);
            return out;
        }
        // Phase 3f-14 + Sprint 8 #8 Day 1 (CKPT66): accept `patch in`
        // Input variables. Per-patch scalar/vec shape shared across
        // all domain vertices. TCS-side capture + TES-side init feed
        // the caller's TesPatchVaryingMap.
        //
        // CKPT66 relaxation: glslang doesn't emit Location on
        // `patch in` variables without explicit `layout(location=N)`
        // — cross-stage matching is by NAME (mirror of the interface
        // block case below). CTS data_pass_through declares
        // `patch in vec4 tc_patch_data;` with no explicit layout.
        // Accept Location-less patch-in; the initVariables TES arm's
        // patch-input lookup will need a name-keyed fallback (or the
        // caller's TesPatchVaryingMap can hold name-keyed entries).
        if (dIt != module.decorations.end() && dIt->second.isPatch) {
            continue;
        }
        // Non-builtin, non-patch Input. The default-on gl_in[] gate
        // admits per-vertex input arrays unless explicitly disabled.
        if (!glInEnabled) {
            out.diagnostic = "non-builtin Input variable (id=" +
                             std::to_string(varId) + "): " + info.name +
                             " (gl_in[] path disabled by APPGL_ENABLE_TESS_EMUL_GLIN=0)";
            return out;
        }
        auto tIt = module.types.find(info.typeId);
        if (tIt == module.types.end()) {
            out.diagnostic = "Input var with missing type (id=" +
                             std::to_string(varId) + ")";
            return out;
        }
        auto pIt = module.types.find(tIt->second.pointeeType);
        if (pIt == module.types.end() ||
            pIt->second.kind != appgl::interp::TypeInfo::Kind::Array) {
            out.diagnostic = "non-builtin Input variable (id=" +
                             std::to_string(varId) + "): " + info.name;
            return out;
        }
        auto eIt = module.types.find(pIt->second.componentType);
        if (eIt == module.types.end()) {
            out.diagnostic = "Input array with missing element type (id=" +
                             std::to_string(varId) + "): " + info.name;
            return out;
        }
        // Sprint 15 Day 23 (CKPT196): 4th accepted shape — bare
        // scalar / vector array Inputs. CTS cull_distance.coverage
        // uses `flat in int INPUT_TE_NAME[]` for chain propagation
        // through TES (similarly `flat in vec4 foo[]` patterns are
        // common). glslang emits these as `Array of scalar` (Int /
        // UInt / Float / Bool) or `Array of vector` (Vec2 / Vec3 /
        // Vec4) — no struct wrapping. Pre-existing classifier
        // rejected these as "Input array of non-struct" because the
        // initVariables branch (GeometryShaderEmulator.cpp ~1431+)
        // only knew the struct-array seeding path. Component 6
        // (Day 24+) extends initVariables to handle scalar-array
        // seeding; this gate (Component 5) just admits the shape so
        // the chain plumbing engages. Default-on with the other
        // non-builtin Input array support; APPGL_ENABLE_TESS_EMUL_GLIN=0
        // restores the pre-Sprint-18 fallback.
        using K = appgl::interp::TypeInfo::Kind;
        const K eKind = eIt->second.kind;
        const bool isScalarArray =
            eKind == K::Bool || eKind == K::Int || eKind == K::UInt ||
            eKind == K::Float;
        const bool isVectorArray =
            eKind == K::Vec2 || eKind == K::Vec3 || eKind == K::Vec4;
        const bool isMatrixArray = eKind == K::Matrix;
        if (isScalarArray || isVectorArray || isMatrixArray) {
            // 4th accepted shape — proceed to next Input variable
            // without further struct-decoration checks. Component 6
            // (Day 24+) handles the per-vertex seeding from
            // EmulatedDraw.varyingNames lookup keyed by the var's
            // declared name (info.name).
            continue;
        }
        if (eIt->second.kind != appgl::interp::TypeInfo::Kind::Struct) {
            out.diagnostic = "Input array of non-struct/scalar/vector (id=" +
                             std::to_string(varId) + "): " + info.name;
            return out;
        }
        // Sprint 8 #8 Day 1 (CKPT66): accept THREE array-of-struct
        // shapes —
        //   (a) gl_PerVertex block — at least one BuiltIn member
        //       (gl_Position / gl_PointSize / gl_ClipDistance / etc).
        //       Original Sprint 5 supported shape.
        //   (b) Interface block (GLSL `in BLOCK { ... } name[];`) —
        //       struct is decorated `Block`. CTS data_pass_through-
        //       class shape: `in OUT_TC { vec4 tc_position; ... }
        //       in_data[];`. glslang emits NO Location decorations on
        //       interface blocks without explicit `layout(location=N)`
        //       — cross-stage matching is by member NAME instead.
        //       initVariables reads per-vertex member values from
        //       inputs[vi].varyings via member-name lookup (existing
        //       branch at GeometryShaderEmulator.cpp:~1431-1452).
        //   (c) Member-Location-decorated array — explicit
        //       `layout(location=N) in TYPE name[];` per-member.
        //       Reserved for shapes that explicitly use Location.
        // Reject only if NONE of the three signatures match.
        bool sawBuiltInMember = false;
        bool sawLocationMember = false;
        auto mdIt = module.memberDecorations.find(pIt->second.componentType);
        if (mdIt != module.memberDecorations.end()) {
            for (const auto& [midx, mdec] : mdIt->second.perMember) {
                if (mdec.hasBuiltIn) sawBuiltInMember = true;
                if (mdec.hasLocation) sawLocationMember = true;
            }
        }
        bool isBlockDecorated = false;
        auto sdIt = module.decorations.find(pIt->second.componentType);
        if (sdIt != module.decorations.end() && sdIt->second.isBlock) {
            isBlockDecorated = true;
        }
        if (!sawBuiltInMember && !sawLocationMember && !isBlockDecorated) {
            out.diagnostic = "Input array-of-struct has no BuiltIn / Location / Block decoration (id=" +
                             std::to_string(varId) + "): " + info.name;
            return out;
        }
        // Accepted — gl_in[] (BuiltIn) OR interface block (Block-
        // decorated, name-matched) OR Location-decorated members.
    }

    // Upper bound on body size so a pathological shader can't hang
    // the draw path. The CE test template body is ~40-80 opcodes; we
    // pick a generous ceiling (4096) that still guards against
    // mischievous shaders.
    std::size_t i = module.funcBodyStart;
    const std::size_t end = module.funcBodyEnd;
    std::size_t opcodeCount = 0;
    while (i < end) {
        const std::uint32_t inst = module.words[i];
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0 || i + wc > end) break;
        ++opcodeCount;
        if (opcodeCount > 4096) {
            out.diagnostic = "body opcode count > 4096";
            return out;
        }
        i += wc;
    }

    out.interpretable = true;
    return out;
}

TessBodyInterpretabilityCheck classifyTessControlInterpretable(
    const std::uint32_t* tcsSpirv,
    std::size_t tcsWordCount)
{
    TessBodyInterpretabilityCheck out;
    if (tcsSpirv == nullptr || tcsWordCount < 5) {
        out.diagnostic = "empty SPIR-V";
        return out;
    }
    SpirvModule module;
    if (!module.parse(tcsSpirv, tcsWordCount)) {
        out.diagnostic = "SpirvModule::parse failed: " + module.parseError;
        return out;
    }
    if (!module.haveFuncBody) {
        out.diagnostic = "no function body";
        return out;
    }
    out.parsed = true;

    // TCS admits gl_PrimitiveID (7), gl_InvocationID (8), and
    // gl_PatchVerticesIn (14) on Input. Phase 3f-10 adds gl_in[]
    // (Array of gl_PerVertex-style struct with BuiltIn members),
    // default-on with the TES classifier's gl_in[] arm. Per-patch
    // varyings (`patch in`) still reject.
    static const bool glInEnabled =
        appglEnvEnabledDefaultOn("APPGL_ENABLE_TESS_EMUL_GLIN");
    for (const auto& [varId, info] : module.variables) {
        if (info.storageClass != spv::StorageClassInput) continue;
        auto dIt = module.decorations.find(varId);
        if (dIt != module.decorations.end() && dIt->second.hasBuiltIn) {
            const std::uint32_t bi = dIt->second.builtIn;
            if (bi == 7  /*PrimitiveId*/   ||
                bi == 8  /*InvocationId*/  ||
                bi == 14 /*PatchVertices*/) {
                continue;
            }
            out.diagnostic = "TCS unsupported builtin input: " + std::to_string(bi);
            return out;
        }
        // Non-builtin Input. Accept only when it's an array-of-struct
        // with a BuiltIn-decorated member (gl_in[] shape) unless the
        // default-on gl_in[] gate is explicitly disabled.
        if (!glInEnabled) {
            out.diagnostic = "TCS non-builtin Input variable (id=" +
                             std::to_string(varId) + "): " + info.name +
                             " (gl_in[] path disabled by APPGL_ENABLE_TESS_EMUL_GLIN=0)";
            return out;
        }
        auto tIt = module.types.find(info.typeId);
        if (tIt == module.types.end()) {
            out.diagnostic = "TCS Input var with missing type (id=" +
                             std::to_string(varId) + ")";
            return out;
        }
        auto pIt = module.types.find(tIt->second.pointeeType);
        if (pIt == module.types.end() ||
            pIt->second.kind != appgl::interp::TypeInfo::Kind::Array) {
            out.diagnostic = "TCS non-builtin Input variable (id=" +
                             std::to_string(varId) + "): " + info.name;
            return out;
        }
        auto eIt = module.types.find(pIt->second.componentType);
        if (eIt == module.types.end() ||
            eIt->second.kind != appgl::interp::TypeInfo::Kind::Struct) {
            out.diagnostic = "TCS Input array of non-struct (id=" +
                             std::to_string(varId) + "): " + info.name;
            return out;
        }
        // Sprint 8 #8 β.2 (CKPT69): accept the same three array-of-
        // struct shapes the TES classifier admits (CKPT66 mirror) —
        //   (a) gl_PerVertex block — at least one BuiltIn member.
        //   (b) GLSL interface block (`in OUT_VS { ... } in_vs_data[];`) —
        //       struct decorated Block; cross-stage matching by NAME.
        //       data_pass_through TCS uses this exact shape.
        //   (c) Member-Location-decorated array — explicit per-member
        //       layout(location=N).
        bool sawBuiltInMember = false;
        bool sawLocationMember = false;
        auto mdIt = module.memberDecorations.find(pIt->second.componentType);
        if (mdIt != module.memberDecorations.end()) {
            for (const auto& [midx, mdec] : mdIt->second.perMember) {
                if (mdec.hasBuiltIn) sawBuiltInMember = true;
                if (mdec.hasLocation) sawLocationMember = true;
            }
        }
        bool isBlockDecorated = false;
        auto sdIt = module.decorations.find(pIt->second.componentType);
        if (sdIt != module.decorations.end() && sdIt->second.isBlock) {
            isBlockDecorated = true;
        }
        if (!sawBuiltInMember && !sawLocationMember && !isBlockDecorated) {
            out.diagnostic = "TCS Input array-of-struct has no BuiltIn / Location / Block decoration";
            return out;
        }
        // Accepted — gl_in[] gl_PerVertex block, user interface block,
        // or member-Location-decorated array.
    }

    // Same 4096-opcode body-size guard as the TES classifier.
    std::size_t i = module.funcBodyStart;
    const std::size_t end = module.funcBodyEnd;
    std::size_t opcodeCount = 0;
    while (i < end) {
        const std::uint32_t inst = module.words[i];
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0 || i + wc > end) break;
        ++opcodeCount;
        if (opcodeCount > 4096) {
            out.diagnostic = "body opcode count > 4096";
            return out;
        }
        i += wc;
    }

    out.interpretable = true;
    return out;
}

// ─── Phase-2b passthrough shape matcher ──────────────────────────────

TessBodyPassthroughMatch matchTessEvalPassthrough(
    const std::uint32_t* tesSpirv,
    std::size_t tesWordCount)
{
    TessBodyPassthroughMatch out;
    if (tesSpirv == nullptr || tesWordCount < 5) {
        out.diagnostic = "empty SPIR-V";
        return out;
    }
    SpirvModule module;
    if (!module.parse(tesSpirv, tesWordCount)) {
        out.diagnostic = "SpirvModule::parse failed: " + module.parseError;
        return out;
    }
    if (!module.haveFuncBody) {
        out.diagnostic = "no function body";
        return out;
    }
    out.parsed = true;

    // Find the gl_Position variable id and gl_TessCoord variable id. Both
    // are BuiltIn-decorated. gl_Position lives on the Output storage
    // (either directly or as member 0 of a gl_PerVertex block); gl_TessCoord
    // is an Input vec3.
    std::uint32_t positionVarId = 0;
    std::uint32_t positionStructMember = UINT32_MAX;  // non-UINT32_MAX if gl_Position is a block member
    std::uint32_t tessCoordVarId = 0;
    for (const auto& [varId, vi] : module.variables) {
        auto decoIt = module.decorations.find(varId);
        const bool isOutput = vi.storageClass == spv::StorageClassOutput;
        const bool isInput = vi.storageClass == spv::StorageClassInput;
        if (decoIt != module.decorations.end() && decoIt->second.hasBuiltIn) {
            if (isOutput && decoIt->second.builtIn == spv::BuiltInPosition) {
                positionVarId = varId;
            } else if (isInput && decoIt->second.builtIn == spv::BuiltInTessCoord) {
                tessCoordVarId = varId;
            }
        }
        // gl_Position may live as a member of the Output gl_PerVertex
        // block. Check member decorations.
        if (isOutput && positionVarId == 0) {
            auto ptrIt = module.types.find(vi.typeId);
            if (ptrIt != module.types.end() && ptrIt->second.kind == TypeInfo::Kind::Pointer) {
                auto leafIt = module.types.find(ptrIt->second.pointeeType);
                if (leafIt != module.types.end() && leafIt->second.kind == TypeInfo::Kind::Struct) {
                    auto memDecoIt = module.memberDecorations.find(ptrIt->second.pointeeType);
                    if (memDecoIt != module.memberDecorations.end()) {
                        for (const auto& [memIdx, memDeco] : memDecoIt->second.perMember) {
                            if (memDeco.hasBuiltIn && memDeco.builtIn == spv::BuiltInPosition) {
                                positionVarId = varId;
                                positionStructMember = memIdx;
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
    if (positionVarId == 0) {
        out.diagnostic = "no gl_Position output variable";
        return out;
    }
    if (tessCoordVarId == 0) {
        out.diagnostic = "no gl_TessCoord input variable";
        return out;
    }

    // Phase-3e: collect user-varying Output variables by location.
    // Each will get a store-target mapping traced during the body
    // walk. Currently scalar floats only — wider types need per-
    // component source tracking (punt to a later phase).
    struct UserVaryingInfo {
        std::uint32_t varId = 0;
        std::uint32_t location = 0;
        std::string name;
        std::uint8_t numComponents = 1;
        // Filled in after the body walk from the OpStore's value.
        TessVaryingMapping mapping;
    };
    std::vector<UserVaryingInfo> userVaryings;
    std::unordered_map<std::uint32_t, std::size_t> varIdToUserVaryingIdx;

    for (const auto& [varId, vi] : module.variables) {
        if (vi.storageClass != spv::StorageClassOutput) continue;
        auto decoIt = module.decorations.find(varId);
        if (decoIt == module.decorations.end() || !decoIt->second.hasLocation) continue;

        // Inspect the pointee type — we support scalar float only
        // for this phase. Anything else falls back to rejection.
        auto ptrTypeIt = module.types.find(vi.typeId);
        if (ptrTypeIt == module.types.end() ||
            ptrTypeIt->second.kind != TypeInfo::Kind::Pointer) {
            out.diagnostic = "user varying " + vi.name + " has non-pointer type";
            return out;
        }
        auto pointeeIt = module.types.find(ptrTypeIt->second.pointeeType);
        if (pointeeIt == module.types.end() ||
            pointeeIt->second.kind != TypeInfo::Kind::Float) {
            out.diagnostic = "user varying " + vi.name +
                             " is not scalar float (phase-3e scope)";
            return out;
        }

        UserVaryingInfo uv;
        uv.varId = varId;
        uv.location = decoIt->second.location;
        uv.name = vi.name;
        uv.numComponents = 1;
        uv.mapping.name = vi.name;
        uv.mapping.location = uv.location;
        uv.mapping.numComponents = 1;
        varIdToUserVaryingIdx[varId] = userVaryings.size();
        userVaryings.push_back(std::move(uv));
    }

    // Walk the function body. Track every OpStore's pointer — the
    // pointer id must trace back to positionVarId via OpAccessChain(s)
    // rooted at positionVarId. Any OpStore whose pointer isn't
    // traceable back to positionVarId (or is to a different root
    // Output variable) disqualifies.
    //
    // Also check that every OpLoad is sourced from an AccessChain
    // rooted at tessCoordVarId (or is loading an unrelated
    // input that happens to be permissible — we don't model that).
    //
    // `pointerRoot[id]` → root variable id reached via AccessChain, or
    //                     the id itself if no AccessChain applied
    std::unordered_map<std::uint32_t, std::uint32_t> pointerRoot;

    std::size_t i = module.funcBodyStart;
    const std::size_t end = module.funcBodyEnd;
    std::uint32_t storesToPosition = 0;
    std::uint32_t storesOther = 0;
    std::uint32_t loadsFromTessCoord = 0;
    std::uint32_t loadsOther = 0;
    while (i < end) {
        const std::uint32_t inst = module.words[i];
        const std::uint16_t opcode = inst & 0xFFFF;
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0 || i + wc > end) break;
        const std::uint32_t* w = module.words.data() + i + 1;

        switch (opcode) {
            case spv::OpAccessChain: {
                if (wc >= 4) {
                    const std::uint32_t resultId = w[1];
                    const std::uint32_t baseId = w[2];
                    auto it = pointerRoot.find(baseId);
                    pointerRoot[resultId] = (it != pointerRoot.end()) ? it->second : baseId;
                }
                break;
            }
            case spv::OpStore: {
                if (wc >= 3) {
                    const std::uint32_t ptrId = w[0];
                    auto it = pointerRoot.find(ptrId);
                    const std::uint32_t root = (it != pointerRoot.end()) ? it->second : ptrId;
                    if (root == positionVarId) {
                        ++storesToPosition;
                    } else {
                        // Phase-3e: accept stores whose root is a
                        // tracked user varying. Anything else counts
                        // as "other" and disqualifies the match.
                        auto uvIt = varIdToUserVaryingIdx.find(root);
                        if (uvIt == varIdToUserVaryingIdx.end()) {
                            ++storesOther;
                        }
                    }
                }
                break;
            }
            case spv::OpLoad: {
                if (wc >= 4) {
                    const std::uint32_t ptrId = w[2];
                    auto it = pointerRoot.find(ptrId);
                    const std::uint32_t root = (it != pointerRoot.end()) ? it->second : ptrId;
                    if (root == tessCoordVarId) ++loadsFromTessCoord;
                    else ++loadsOther;
                }
                break;
            }
            default:
                break;
        }
        i += wc;
    }

    if (storesToPosition == 0) {
        out.diagnostic = "body doesn't write gl_Position";
        return out;
    }
    if (storesOther > 0) {
        out.diagnostic = "body writes " + std::to_string(storesOther) +
                         " non-Position locations";
        return out;
    }
    if (loadsOther > 0) {
        // Allow loads of constants / function-local temps — those don't
        // go through OpLoad-of-pointer typically. `loadsOther` here
        // means an OpLoad whose pointer rooted at a variable that isn't
        // gl_TessCoord. That includes loads from gl_PerVertex.gl_Position
        // for readback, which is unusual for a passthrough.
        out.diagnostic = "body loads " + std::to_string(loadsOther) +
                         " non-TessCoord inputs";
        return out;
    }

    // Phase-3c/3d: derive position mapping + scale + offset per
    // component. Each scalar feeding gl_Position is tracked as
    // either:
    //   - an affine combination of tessCoord[comp]: value = tc * scale + offset
    //   - a constant float
    //
    // Value-source record (phase-3d extension):
    //   kind == TessCoord       → affine tc[component] * scale + offset
    //                             (scale=1, offset=0 at the OpLoad site;
    //                             OpFMul / OpFAdd / OpFSub combine into it)
    //   kind == Constant        → constantValue
    //   kind == TessCoordVec    → whole vec3 load of gl_TessCoord, used
    //                             only by the CompositeConstruct(v3, w)
    //                             shape.
    enum SrcKind : std::uint8_t { SrcUnknown = 0, SrcTessCoord = 1, SrcConstant = 2, SrcTessCoordVec = 3 };
    struct SrcRecord {
        SrcKind kind = SrcUnknown;
        std::int8_t component = -1;   // 0..2 for TessCoord scalar pick
        float scale = 1.0f;
        float offset = 0.0f;
        float constantValue = 0.0f;
    };
    std::unordered_map<std::uint32_t, SrcRecord> valueSource;

    // Track OpAccessChain results that point into gl_TessCoord with a
    // constant first index → scalar-component AccessChain. Reuse the
    // pointerRoot map populated above + extend with the component idx.
    std::unordered_map<std::uint32_t, std::int8_t> tessCoordComponentOf;

    // Seed constants BEFORE the body walk so OpFMul/FAdd/FSub folding
    // in the walk can look them up on either operand. OpConstant
    // records are already captured by SpirvModule::parse into
    // `module.constants` at module-scope, so they're visible before
    // the function body starts.
    for (const auto& [cid, cv] : module.constants) {
        if (cv.kind == Value::Kind::Float) {
            SrcRecord rec;
            rec.kind = SrcConstant;
            rec.constantValue = cv.f[0];
            valueSource[cid] = rec;
        }
    }

    i = module.funcBodyStart;
    while (i < end) {
        const std::uint32_t inst = module.words[i];
        const std::uint16_t opcode = inst & 0xFFFF;
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0 || i + wc > end) break;
        const std::uint32_t* w = module.words.data() + i + 1;

        switch (opcode) {
            case spv::OpAccessChain: {
                // result, baseVar, idx0, idx1, ...
                if (wc >= 5) {
                    const std::uint32_t resultId = w[1];
                    const std::uint32_t baseId = w[2];
                    if (baseId == tessCoordVarId) {
                        // idx0 should be a constant int (0, 1, 2).
                        auto idxIt = module.constants.find(w[3]);
                        if (idxIt != module.constants.end() &&
                            (idxIt->second.kind == Value::Kind::Int ||
                             idxIt->second.kind == Value::Kind::UInt)) {
                            const std::int32_t cIdx = idxIt->second.i[0];
                            if (cIdx >= 0 && cIdx < 3) {
                                tessCoordComponentOf[resultId] =
                                    static_cast<std::int8_t>(cIdx);
                            }
                        }
                    }
                }
                break;
            }
            case spv::OpLoad: {
                // result, type, pointer
                if (wc >= 4) {
                    const std::uint32_t resultId = w[1];
                    const std::uint32_t ptrId = w[2];
                    auto compIt = tessCoordComponentOf.find(ptrId);
                    if (compIt != tessCoordComponentOf.end()) {
                        SrcRecord rec;
                        rec.kind = SrcTessCoord;
                        rec.component = compIt->second;
                        valueSource[resultId] = rec;
                    } else if (ptrId == tessCoordVarId) {
                        // Whole-vec3 load of gl_TessCoord — used by
                        // CompositeConstruct(v3, 1.0) shape.
                        SrcRecord rec;
                        rec.kind = SrcTessCoordVec;
                        valueSource[resultId] = rec;
                    }
                }
                break;
            }
            case spv::OpCompositeExtract: {
                // result, type, composite, idx0 (literal)
                if (wc >= 5) {
                    const std::uint32_t resultId = w[1];
                    const std::uint32_t compositeId = w[2];
                    const std::uint32_t idx = w[3];
                    auto srcIt = valueSource.find(compositeId);
                    if (srcIt != valueSource.end() &&
                        srcIt->second.kind == SrcTessCoordVec &&
                        idx < 3) {
                        SrcRecord rec;
                        rec.kind = SrcTessCoord;
                        rec.component = static_cast<std::int8_t>(idx);
                        rec.scale = 1.0f;
                        rec.offset = 0.0f;
                        valueSource[resultId] = rec;
                    }
                }
                break;
            }
            case spv::OpFMul:
            case spv::OpFAdd:
            case spv::OpFSub: {
                // Phase-3d: fold affine transforms
                //   tc[i] * const  → scale=const
                //   tc[i] * scaleA + const → offset=const
                // `valueSource` already records constants for any
                // OpConstant id (populated by the constants seed
                // loop below — we rely on that ordering being okay
                // because OpConstant always appears before the
                // function body).
                //
                // Operand handling: commutative for FMul / FAdd;
                // FSub requires operand-order awareness.
                if (wc >= 5) {
                    const std::uint32_t resultId = w[1];
                    const std::uint32_t lhsId = w[2];
                    const std::uint32_t rhsId = w[3];
                    auto lhsIt = valueSource.find(lhsId);
                    auto rhsIt = valueSource.find(rhsId);
                    if (lhsIt == valueSource.end() || rhsIt == valueSource.end()) break;
                    const SrcRecord& L = lhsIt->second;
                    const SrcRecord& R = rhsIt->second;

                    auto recordAffine =
                        [&](SrcKind kind, std::int8_t comp, float scale, float offset) {
                            SrcRecord rec;
                            rec.kind = kind;
                            rec.component = comp;
                            rec.scale = scale;
                            rec.offset = offset;
                            valueSource[resultId] = rec;
                        };

                    if (opcode == spv::OpFMul) {
                        // One side TessCoord-affine, other side Constant.
                        if (L.kind == SrcTessCoord && R.kind == SrcConstant) {
                            recordAffine(SrcTessCoord, L.component,
                                         L.scale * R.constantValue,
                                         L.offset * R.constantValue);
                        } else if (R.kind == SrcTessCoord && L.kind == SrcConstant) {
                            recordAffine(SrcTessCoord, R.component,
                                         R.scale * L.constantValue,
                                         R.offset * L.constantValue);
                        } else if (L.kind == SrcConstant && R.kind == SrcConstant) {
                            SrcRecord rec;
                            rec.kind = SrcConstant;
                            rec.constantValue = L.constantValue * R.constantValue;
                            valueSource[resultId] = rec;
                        }
                    } else if (opcode == spv::OpFAdd) {
                        if (L.kind == SrcTessCoord && R.kind == SrcConstant) {
                            recordAffine(SrcTessCoord, L.component, L.scale,
                                         L.offset + R.constantValue);
                        } else if (R.kind == SrcTessCoord && L.kind == SrcConstant) {
                            recordAffine(SrcTessCoord, R.component, R.scale,
                                         R.offset + L.constantValue);
                        } else if (L.kind == SrcConstant && R.kind == SrcConstant) {
                            SrcRecord rec;
                            rec.kind = SrcConstant;
                            rec.constantValue = L.constantValue + R.constantValue;
                            valueSource[resultId] = rec;
                        }
                    } else {  // OpFSub: L - R
                        if (L.kind == SrcTessCoord && R.kind == SrcConstant) {
                            recordAffine(SrcTessCoord, L.component, L.scale,
                                         L.offset - R.constantValue);
                        } else if (L.kind == SrcConstant && R.kind == SrcTessCoord) {
                            // const - tc * scale - offset
                            //   = -scale * tc + (const - offset)
                            recordAffine(SrcTessCoord, R.component, -R.scale,
                                         L.constantValue - R.offset);
                        } else if (L.kind == SrcConstant && R.kind == SrcConstant) {
                            SrcRecord rec;
                            rec.kind = SrcConstant;
                            rec.constantValue = L.constantValue - R.constantValue;
                            valueSource[resultId] = rec;
                        }
                    }
                }
                break;
            }
            case spv::OpFNegate: {
                // unary -x : flip scale and offset signs
                if (wc >= 4) {
                    const std::uint32_t resultId = w[1];
                    const std::uint32_t opId = w[2];
                    auto srcIt = valueSource.find(opId);
                    if (srcIt != valueSource.end()) {
                        SrcRecord rec = srcIt->second;
                        if (rec.kind == SrcTessCoord) {
                            rec.scale = -rec.scale;
                            rec.offset = -rec.offset;
                        } else if (rec.kind == SrcConstant) {
                            rec.constantValue = -rec.constantValue;
                        }
                        valueSource[resultId] = rec;
                    }
                }
                break;
            }
            default:
                break;
        }
        i += wc;
    }

    // Find the OpStore to gl_Position and trace its value argument.
    std::uint32_t positionStoreValue = 0;
    i = module.funcBodyStart;
    while (i < end) {
        const std::uint32_t inst = module.words[i];
        const std::uint16_t opcode = inst & 0xFFFF;
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0 || i + wc > end) break;
        const std::uint32_t* w = module.words.data() + i + 1;
        if (opcode == spv::OpStore && wc >= 3) {
            const std::uint32_t ptrId = w[0];
            auto pit = pointerRoot.find(ptrId);
            const std::uint32_t root = (pit != pointerRoot.end()) ? pit->second : ptrId;
            if (root == positionVarId) {
                positionStoreValue = w[1];
                break;
            }
        }
        i += wc;
    }
    if (positionStoreValue == 0) {
        out.diagnostic = "failed to locate gl_Position store value";
        return out;
    }

    // The value is expected to be an OpCompositeConstruct over
    // 4 scalar operands (or over (vec3, float) — glslang splits
    // vec4(gl_TessCoord, 1.0) into (v3_load, 1.0_const)).
    i = module.funcBodyStart;
    bool mappingFound = false;
    while (i < end && !mappingFound) {
        const std::uint32_t inst = module.words[i];
        const std::uint16_t opcode = inst & 0xFFFF;
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0 || i + wc > end) break;
        const std::uint32_t* w = module.words.data() + i + 1;
        if (opcode == spv::OpCompositeConstruct && wc >= 3) {
            const std::uint32_t resultId = w[1];
            if (resultId == positionStoreValue) {
                // Handle two shapes:
                //   wc == 6 (4 scalars)  → 4 operands at w[2..5]
                //   wc == 4 (vec3, w)    → operand at w[2] is v3,
                //                          w[3] is w-constant
                if (wc == 6) {
                    bool allOk = true;
                    for (int c = 0; c < 4; ++c) {
                        const std::uint32_t opId = w[2 + c];
                        auto it = valueSource.find(opId);
                        if (it == valueSource.end()) { allOk = false; break; }
                        const SrcRecord& src = it->second;
                        if (src.kind == SrcTessCoord) {
                            out.positionMapping[c] = src.component;
                            out.positionScale[c] = src.scale;
                            out.positionOffset[c] = src.offset;
                        } else if (src.kind == SrcConstant) {
                            out.positionMapping[c] = -1;
                            out.positionConstant[c] = src.constantValue;
                        } else {
                            allOk = false; break;
                        }
                    }
                    if (allOk) mappingFound = true;
                } else if (wc == 4) {
                    // (vec3, w-constant) shape. The v3 always
                    // corresponds to an identity tessCoord load
                    // (scale=1, offset=0 per component).
                    const std::uint32_t v3Id = w[2];
                    const std::uint32_t wId = w[3];
                    auto v3It = valueSource.find(v3Id);
                    auto wIt = valueSource.find(wId);
                    if (v3It != valueSource.end() &&
                        v3It->second.kind == SrcTessCoordVec &&
                        wIt != valueSource.end() &&
                        wIt->second.kind == SrcConstant) {
                        for (int c = 0; c < 3; ++c) {
                            out.positionMapping[c] = static_cast<std::int8_t>(c);
                            out.positionScale[c] = 1.0f;
                            out.positionOffset[c] = 0.0f;
                        }
                        out.positionMapping[3] = -1;
                        out.positionConstant[3] = wIt->second.constantValue;
                        mappingFound = true;
                    }
                }
            }
        }
        i += wc;
    }

    if (!mappingFound) {
        out.diagnostic = "gl_Position store value isn't a simple CompositeConstruct";
        return out;
    }

    // Phase-3e: trace each user varying's store value back to the
    // same valueSource map and populate its TessVaryingMapping. For
    // scalar float varyings the OpStore's value is either a
    // TessCoord-affine scalar or a constant float. A varying that
    // isn't written anywhere (unusual — glslang inlines constants
    // into the store) disqualifies the match since the FS would
    // still read it.
    i = module.funcBodyStart;
    std::vector<bool> varyingMatched(userVaryings.size(), false);
    while (i < end) {
        const std::uint32_t inst = module.words[i];
        const std::uint16_t opcode = inst & 0xFFFF;
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0 || i + wc > end) break;
        const std::uint32_t* w = module.words.data() + i + 1;
        if (opcode == spv::OpStore && wc >= 3) {
            const std::uint32_t ptrId = w[0];
            auto pit = pointerRoot.find(ptrId);
            const std::uint32_t root = (pit != pointerRoot.end()) ? pit->second : ptrId;
            auto uvIt = varIdToUserVaryingIdx.find(root);
            if (uvIt != varIdToUserVaryingIdx.end()) {
                const std::size_t idx = uvIt->second;
                const std::uint32_t valueId = w[1];
                auto vsIt = valueSource.find(valueId);
                if (vsIt != valueSource.end()) {
                    const SrcRecord& src = vsIt->second;
                    if (src.kind == SrcTessCoord) {
                        userVaryings[idx].mapping.mapping[0] = src.component;
                        userVaryings[idx].mapping.scale[0] = src.scale;
                        userVaryings[idx].mapping.offset[0] = src.offset;
                        varyingMatched[idx] = true;
                    } else if (src.kind == SrcConstant) {
                        userVaryings[idx].mapping.mapping[0] = -1;
                        userVaryings[idx].mapping.constant[0] = src.constantValue;
                        varyingMatched[idx] = true;
                    }
                }
            }
        }
        i += wc;
    }
    for (std::size_t k = 0; k < userVaryings.size(); ++k) {
        if (!varyingMatched[k]) {
            out.diagnostic = "user varying " + userVaryings[k].name +
                             " has non-affine store value (phase-3e scope)";
            return out;
        }
        out.varyings.push_back(userVaryings[k].mapping);
    }

    out.matched = true;
    (void)positionStructMember;
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
    if (N == 1) {
        // Single-segment triangle tessellation should reproduce the
        // input patch vertices in TES barycentric order. The generic
        // row walk stores them as (0,0,1), (1,0,0), (0,1,0), so remap
        // the only primitive to gl_in[0], gl_in[1], gl_in[2].
        out.indices.push_back(1);
        out.indices.push_back(2);
        out.indices.push_back(0);
        return;
    }
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
    bool pointMode,
    bool flipWinding)
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
    // Phase 3f-9: CW winding = swap indices[1] and [2] in each
    // triangle (3-element stride). Only applies to Triangle /
    // triangle-decomposed-Quad outputs — Isolines and point-mode
    // topology have no winding semantic. We detect that via the
    // topology flag on the output (GL_TRIANGLES only).
    if (flipWinding && out.topology == GL_TRIANGLES &&
        !out.indices.empty() && (out.indices.size() % 3) == 0) {
        for (std::size_t i = 0; i + 2 < out.indices.size(); i += 3) {
            std::swap(out.indices[i + 1], out.indices[i + 2]);
        }
    }
    return out;
}

// ─── Public API — link-time detection ────────────────────────────────

bool detectTessellationEmulatable(GLProgramObject& program) {
    program.tessellationEmulated = false;

    // Must have a TES at minimum (§11.2.3: TCS is optional).
    if (program.tessEvalSpirv.empty()) return false;

    // Sprint 8 #8 β.3 (CKPT97): the historical "TES+GS 5-stage pipeline
    // not yet emulated" gate is dropped. The driver now supports the
    // tess→GS plumbing path: tess-emul produces the post-tess vertex
    // stream, then GLContext.mm passes it as `priorStageOutput` to
    // `emulateGeometryDraw` (the GS interpreter consumes the prior
    // stage's per-vertex output instead of running its own VS pre-pass).
    // The detector still requires the TES body to match the same
    // passthrough / interpretable subsets it requires for tess-only
    // programs — the GS attachment doesn't change what the tess stage
    // is allowed to do.

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

    // Phase-2b shape matcher — detect TES bodies whose whole output
    // payload is `gl_Position = vec4(gl_TessCoord.xyz, ...)`. These
    // are the only bodies the phase-2a position-only EmulatedDraw
    // can faithfully represent.
    TessBodyPassthroughMatch tePass = matchTessEvalPassthrough(
        program.tessEvalSpirv.data(), program.tessEvalSpirv.size());
    if (!tePass.parsed) {
        program.linkLog += "\n[tess-emul] TES passthrough match: " + tePass.diagnostic;
    } else if (tePass.matched) {
        program.linkLog += "\n[tess-emul] TES is passthrough — phase-2b candidate";
    }

    // Phase-2c enablement gate (default-on in Sprint 18):
    //   unset / nonzero APPGL_ENABLE_TESS_EMUL → use the emulated TES path.
    //   APPGL_ENABLE_TESS_EMUL=0               → force the legacy fallback.
    (void)isSupportedTessMode;
    if (tePass.matched) {
        static const bool emulEnabled =
            appglEnvEnabledDefaultOn("APPGL_ENABLE_TESS_EMUL");
        if (emulEnabled) {
            program.tessellationEmulated = true;
            // Copy the phase-3c/3d position mapping onto the program so
            // the draw path can apply it per generated vertex without
            // re-parsing the SPIR-V.
            for (int c = 0; c < 4; ++c) {
                program.tessPositionMapping[c] = tePass.positionMapping[c];
                program.tessPositionScale[c] = tePass.positionScale[c];
                program.tessPositionOffset[c] = tePass.positionOffset[c];
                program.tessPositionConstant[c] = tePass.positionConstant[c];
            }
            // Phase-3e-2: copy per-varying mappings onto the program.
            program.tessVaryings.clear();
            program.tessVaryings.reserve(tePass.varyings.size());
            for (const auto& v : tePass.varyings) {
                GLProgramObject::TessVaryingSlot slot;
                slot.name = v.name;
                slot.location = v.location;
                slot.numComponents = v.numComponents;
                for (int c = 0; c < 4; ++c) {
                    slot.mapping[c] = v.mapping[c];
                    slot.scale[c] = v.scale[c];
                    slot.offset[c] = v.offset[c];
                    slot.constant[c] = v.constant[c];
                }
                program.tessVaryings.push_back(std::move(slot));
            }
            program.linkLog +=
                "\n[tess-emul] TES emulation enabled — passthrough TES ("
                + std::to_string(tePass.varyings.size()) + " user varyings)";
        }
    }

    // Phase-3f-2: if the passthrough matcher rejected the body,
    // try the wider interpretability classifier. Shapes that only
    // read gl_TessCoord / gl_PrimitiveID / gl_PatchVerticesIn can
    // run through the GSE Interpreter per generated vertex. Same
    // default-on APPGL_ENABLE_TESS_EMUL gate.
    static const bool emulEnabled =
        appglEnvEnabledDefaultOn("APPGL_ENABLE_TESS_EMUL");
    if (emulEnabled && !program.tessellationEmulated) {
        TessBodyInterpretabilityCheck teInterp =
            classifyTessEvalInterpretable(
                program.tessEvalSpirv.data(),
                program.tessEvalSpirv.size());
        if (teInterp.interpretable) {
            program.tessellationInterpreted = true;
            program.linkLog +=
                "\n[tess-emul] TES emulation enabled — interpreter TES";

            // Phase 3f-6: populate program.tessVaryings from the TES's
            // Output varyings so the interpreter path emits matching
            // `[[user(locnN)]]` slots in the synth VS and the FS can
            // read per-vertex interpolated values, AND so XFB writes
            // pick up tc_position / tc_value1 / etc. by name.
            //
            // Sprint 8 #8 β.2 Day 2 (CKPT70): drop the `hasLocation`
            // filter that pre-CKPT70 rejected unlocated top-level
            // outputs (glslang emits NO Location decoration on plain
            // `out vec4 tc_position;` declarations without explicit
            // `layout(location=N)`). data_pass_through-class TES bodies
            // hit this exact shape — the XFB chain captures by name
            // (transformFeedbackVaryingNames), so an unlocated output
            // that has a name is captureable. Synthesise a sequential
            // location for the synth VS varying-slot routing (reserved
            // for non-XFB-only use; rasterizer-discard XFB path skips
            // the synth VS).
            TessEvalInterface teIface = scanTessEvalInterface(
                program.tessEvalSpirv.data(),
                program.tessEvalSpirv.size());
            program.tessVaryings.clear();
            std::uint32_t nextSyntheticLocation = 0;
            if (teIface.parsed) {
                for (const auto& ov : teIface.outputs) {
                    if (ov.isBuiltIn) continue;
                    if (ov.isPerVertex) continue;
                    if (ov.scalarCount == 0 || ov.scalarCount > 4) continue;
                    if (ov.name.empty()) continue;
                    GLProgramObject::TessVaryingSlot slot;
                    slot.name = ov.name;
                    if (ov.hasLocation) {
                        slot.location = ov.location;
                        if (ov.location >= nextSyntheticLocation) {
                            nextSyntheticLocation = ov.location + 1;
                        }
                    } else {
                        slot.location = nextSyntheticLocation++;
                    }
                    slot.numComponents = ov.scalarCount;
                    slot.baseType = ov.baseType;
                    slot.interp = ov.interp;
                    // Interpreter path produces these values at runtime;
                    // the mapping/scale/offset/constant fields are unused
                    // (only the matcher's affine path consults them).
                    program.tessVaryings.push_back(std::move(slot));
                }
            }
        }
        if (!teInterp.interpretable && !teInterp.diagnostic.empty()) {
            program.linkLog +=
                "\n[tess-emul] TES interpretability rejected: " + teInterp.diagnostic;
        }
    }

    // Phase-3f-4: independently classify the TCS (when present). If
    // the TES already landed on either the passthrough or interpreter
    // path, adding TCS interpretation only adds more coverage —
    // programs with both interpretable stages run TCS then TES under
    // `emulateTessellationDraw`.
    if (emulEnabled && !program.tessControlSpirv.empty()) {
        TessBodyInterpretabilityCheck tcInterp =
            classifyTessControlInterpretable(
                program.tessControlSpirv.data(),
                program.tessControlSpirv.size());
        if (tcInterp.interpretable) {
            program.tessControlInterpreted = true;
            program.linkLog +=
                "\n[tess-emul] TES emulation enabled — interpreter TCS";
        }
        if (!tcInterp.interpretable && !tcInterp.diagnostic.empty()) {
            program.linkLog +=
                "\n[tess-emul] TCS interpretability rejected: " + tcInterp.diagnostic;
        }
    }

    return program.tessellationEmulated || program.tessellationInterpreted;
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
    GLuint baseInstance,
    const SampledTextureMap* tcsSampledTextures,
    const SampledTextureMap* tcsStorageImages,
    const SampledTextureMap* tesSampledTextures,
    const SampledTextureMap* tesStorageImages)
{
    (void)vao;
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

    // Resolve tessellation levels. Precedence (low → high):
    //   1. glPatchParameterfv(GL_PATCH_DEFAULT_*_LEVEL) defaults
    //   2. Compile-time constants written by the TCS body
    //      (scanTessControlConstantLevels)
    //   3. Phase 3f-8: runtime-computed tess levels captured by
    //      running the TCS interpreter for patch 0 invocation 0
    //      and reading back BuiltInTessLevel{Outer,Inner} storage.
    //      This handles shaders that compute levels from uniforms
    //      or gl_PrimitiveID (typical in CTS vertex_spacing,
    //      tessellation_invariance, etc.).
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

    // Phase 3f-8: TCS runtime tess-level capture. When the TCS is
    // interpretable, run invocation 0 of patch 0 for its side
    // effect on the tess-level outputs. SSBO writes the invocation
    // performs are intentional — we'll run the remaining
    // (patch × invocation) pairs in the full pre-pass below. This
    // first run is only for getting correct tess levels before we
    // compute the domain.
    bool tcsLevelsCaptured = false;
    if (program.tessControlInterpreted && !program.tessControlSpirv.empty() &&
        numPatches > 0) {
        std::string diag;
        EmulatedVertex scratchOut;
        scratchOut.position[0] = scratchOut.position[1] = 0.0f;
        scratchOut.position[2] = 0.0f; scratchOut.position[3] = 1.0f;
        const std::vector<EmulatedVertex> emptyPatchInputs;
        const bool ok = runTcsForVertex(
            program.tessControlSpirv.data(),
            program.tessControlSpirv.size(),
            program,
            /*primitiveID=*/0, /*invocationID=*/0,
            patchVertices,
            /*ssboMap=*/nullptr,   // side-effect-free capture pass
            emptyPatchInputs,       // VS hasn't run yet; gl_in[] = zeros
            scratchOut,
            outerLevels, innerLevels,
            /*precomputedUniforms=*/nullptr,  // pre-map; not built yet
            /*patchVaryingsOut=*/nullptr,    // phase 3f-14 — early capture
                                             // discards per-patch outputs;
                                             // the full pre-pass rebuilds
                                             // them below.
            &diag,
            /*inVaryingNames=*/nullptr,
            /*inVaryingWidths=*/nullptr,
            /*outVaryingNames=*/nullptr,
            /*outVaryingWidths=*/nullptr,
            /*sampledTextures=*/tcsSampledTextures,
            /*storageImages=*/tcsStorageImages);
        tcsLevelsCaptured = ok;
    }

    // Generate the domain coord set for ONE patch. Every patch in this
    // draw shares the same levels for now — per-patch level variation
    // (gl_PrimitiveID-dependent TCS) would need per-patch domain
    // regeneration, which is phase 3f-9+ infrastructure.
    //
    // Phase 3f-9: honour the TES's `layout(..., cw/ccw)` qualifier.
    // Default GL winding is CCW per §11.2.2; CW flips the indices
    // of each emitted triangle. Only affects the triangle/quad
    // output topology (isolines/points have no winding).
    const bool flipWinding = (program.tessGenVertexOrder == GL_CW);
    TessDomainOutput domainOut =
        generateTessDomain(domain, spacing, outerLevels, innerLevels, pointMode,
                           flipWinding);
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

    // Phase-3e-2: varying layout. Each user varying adds
    // `numComponents` floats per vertex, concatenated after the
    // 4-wide position. The EmulatedDraw's synth-VS path reads the
    // same flat layout via `varyingWidths` and `varyingNames`.
    std::size_t varyingFloats = 0;
    for (const auto& v : program.tessVaryings) {
        d.varyingNames.push_back(v.name);
        d.varyingWidths.push_back(static_cast<std::uint32_t>(v.numComponents));
        d.varyingLocations.push_back(v.location);
        d.varyingInterp.push_back(v.interp);
        d.varyingBaseType.push_back(v.baseType);
        varyingFloats += v.numComponents;
    }
    const bool useInterpreter =
        program.tessellationInterpreted && !program.tessellationEmulated;

    // Sprint 18 cull_distance item6: TES interpreter outputs from
    // gl_PerVertex need the same synth-VS handoff lanes as the
    // Sprint17 R13 cull pre-pass path. Keep clip distances for
    // Metal's clip planes, but cull distances are consumed by the
    // primitive-level CPU filter below.
    std::uint32_t tessClipLen = 0;
    std::uint32_t tessCullLen = 0;
    if (useInterpreter && !program.tessEvalSpirv.empty()) {
        TessEvalInterface teIface = scanTessEvalInterface(
            program.tessEvalSpirv.data(),
            program.tessEvalSpirv.size());
        if (teIface.parsed) {
            for (const auto& ov : teIface.outputs) {
                if (!ov.isBuiltIn) continue;
                if (ov.builtIn == spv::BuiltInClipDistance) {
                    tessClipLen = std::max(tessClipLen, ov.scalarCount);
                } else if (ov.builtIn == spv::BuiltInCullDistance) {
                    tessCullLen = std::max(tessCullLen, ov.scalarCount);
                }
            }
        }
    }
    const std::size_t clipBase = kPosFloats + varyingFloats;
    const std::size_t cullBase = clipBase + tessClipLen;
    const std::size_t floatsPerVertex = cullBase + tessCullLen;
    d.vertexCount = totalVerts;
    d.floatsPerVertex = floatsPerVertex;
    d.clipDistanceLen = tessClipLen;
    d.cullDistanceLen = tessCullLen;
    d.expandedVertexData.assign(totalVerts * floatsPerVertex, 0.0f);
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
    d.expandedVertexData.assign(d.vertexCount * floatsPerVertex, 0.0f);

    // Phase-3c/3d/3e-2: apply position mapping AND varying mappings to
    // each generated domain coord. Non-emulated path sticks with the
    // phase-2a identity default (u,v,w,1) — harmless since .ok=false
    // will force the draw through the legacy translated path.
    auto emitVertex = [&](std::size_t dstIdx, float u, float v, float w) {
        const float coordsPerPatchLookup[3] = {u, v, w};
        const std::size_t dst = dstIdx * floatsPerVertex;
        // Position first (always 4 floats).
        for (int c = 0; c < 4; ++c) {
            const std::int8_t src = program.tessPositionMapping[c];
            if (src >= 0 && src < 3) {
                d.expandedVertexData[dst + c] =
                    coordsPerPatchLookup[src] * program.tessPositionScale[c]
                    + program.tessPositionOffset[c];
            } else {
                d.expandedVertexData[dst + c] = program.tessPositionConstant[c];
            }
        }
        // Varyings after position, in declaration order.
        std::size_t vOff = kPosFloats;
        for (const auto& vmap : program.tessVaryings) {
            for (std::uint32_t c = 0; c < vmap.numComponents; ++c) {
                const std::int8_t src = vmap.mapping[c];
                float out;
                if (src >= 0 && src < 3) {
                    out = coordsPerPatchLookup[src] * vmap.scale[c]
                        + vmap.offset[c];
                } else {
                    out = vmap.constant[c];
                }
                d.expandedVertexData[dst + vOff + c] = out;
            }
            vOff += vmap.numComponents;
        }
    };

    // Phase-3f-3/3f-4: build the SSBO region map the interpreter
    // routes OpLoad / OpStore through. Walks BOTH the TES and TCS
    // SPIR-V for StorageBuffer-class (or Uniform+BufferBlock) block
    // variables, since either stage's body may reference SSBOs. Each
    // binding is resolved against the GL state's
    // GL_SHADER_STORAGE_BUFFER indexed slot and the host-visible
    // MTLBuffer contents pointer is recorded. Map is built once per
    // draw (bindings don't change mid-draw) and captured by the
    // per-invocation TCS + per-vertex TES code below.
    TesSsboMap ssboBindings;
    auto addSsbosFromModule = [&](const std::vector<std::uint32_t>& spirv) {
        if (spirv.empty()) return;
        appgl::interp::SpirvModule mod;
        if (!mod.parse(spirv.data(), spirv.size())) return;
        for (const auto& [varId, info] : mod.variables) {
            bool isSSBO = false;
            if (info.storageClass == 12 /*StorageClassStorageBuffer*/) {
                isSSBO = true;
            } else if (info.storageClass == 2 /*StorageClassUniform*/) {
                auto tIt = mod.types.find(info.typeId);
                if (tIt != mod.types.end()) {
                    auto dIt = mod.decorations.find(tIt->second.pointeeType);
                    if (dIt != mod.decorations.end() && dIt->second.isBufferBlock) {
                        isSSBO = true;
                    }
                }
            }
            if (!isSSBO) continue;
            auto dIt = mod.decorations.find(varId);
            if (dIt == mod.decorations.end() || !dIt->second.hasBinding) continue;
            const std::uint32_t binding = dIt->second.binding;
            // Skip if this binding already in the map (TES and TCS
            // may share bindings — glslang emits the same binding
            // number on both sides for interface-matching).
            if (ssboBindings.find(binding) != ssboBindings.end()) continue;

            const GLIndexedBufferBinding bb =
                state.indexedBufferBinding(GL_SHADER_STORAGE_BUFFER, binding);
            if (bb.buffer == 0) continue;
            GLBufferObject* bufObj = objects.buffers().get(bb.buffer);
            if (bufObj == nullptr || bufObj->metalBuffer == nullptr) continue;
            void* base = metalBufferContents(bufObj->metalBuffer);
            if (base == nullptr) continue;
            const std::size_t totalSize = static_cast<std::size_t>(bufObj->size);
            const std::size_t off =
                static_cast<std::size_t>(bb.offset < 0 ? 0 : bb.offset);
            // bb.size == 0 means BindBufferBase (whole buffer).
            const std::size_t span = (bb.size > 0)
                ? static_cast<std::size_t>(bb.size)
                : (totalSize > off ? totalSize - off : 0);
            TesSsboRegion r;
            r.ptr = static_cast<std::uint8_t*>(base) + off;
            r.size = span;
            ssboBindings[binding] = r;
        }
    };
    if (program.tessellationInterpreted || program.tessControlInterpreted) {
        addSsbosFromModule(program.tessEvalSpirv);
        addSsbosFromModule(program.tessControlSpirv);
    }
    const TesSsboMap* ssboMap = ssboBindings.empty() ? nullptr : &ssboBindings;

    // Phase 3f-12: build the uniform map ONCE for this draw. Passed
    // to every runTes/TcsForVertex call below to avoid rebuilding
    // (program.uniforms × uniformValues) per invocation. Uniforms
    // can't change mid-draw — glUniform* handlers are never called
    // while a draw is in flight — so the snapshot we take here is
    // valid for every (patch, invocation) pair we'll generate.
    const bool needUniformMap =
        program.tessellationEmulated || program.tessellationInterpreted ||
        program.tessControlInterpreted;
    TesUniformMap precomputedUniforms;
    const TesUniformMap* uniformMapPtr = nullptr;
    if (needUniformMap) {
        precomputedUniforms = buildTesUniformMap(program);
        uniformMapPtr = &precomputedUniforms;
    }

    UniformBufferMap tessUboMap;
    if (needUniformMap) {
        addTessUniformBuffersFromModule(program.vertexSpirv, objects, state, tessUboMap);
        addTessUniformBuffersFromModule(program.tessControlSpirv, objects, state, tessUboMap);
        addTessUniformBuffersFromModule(program.tessEvalSpirv, objects, state, tessUboMap);
    }
    const UniformBufferMap* tessUboMapPtr =
        tessUboMap.empty() ? nullptr : &tessUboMap;

    // patchInputs[] + tcsOutputs[] declarations moved up so the TCS
    // pre-pass (below) can populate tcsOutputs and consult patchInputs
    // that the VS pre-pass (which runs BEFORE this block — order was
    // flipped in phase 3f-10 to let TCS see real VS outputs) wrote.
    std::vector<std::vector<EmulatedVertex>> patchInputs;
    // Phase 3f-10: captured TCS gl_out[] per (patch, invocation).
    // When populated and `tcsOutputsValid` is true, the TES emit
    // loop uses tcsOutputs[p] as gl_in[] instead of routing VS
    // pre-pass outputs directly — so TCS-driven pipelines that
    // transform vertices before tessellation are honoured.
    std::vector<std::vector<EmulatedVertex>> tcsOutputs;
    bool tcsOutputsValid = false;

    // Phase 3f-14: per-patch varying maps. tcsPatchVaryings[p]
    // accumulates TCS patch-out writes across invocations of patch
    // `p` (last-write-wins on Location collisions). The TES emit
    // loop's lambda consults tcsPatchVaryings[patchIdx] and hands
    // the matching map pointer to runTesForVertex so Input-Patch-
    // Location variables are seeded with the right values.
    std::vector<TesPatchVaryingMap> tcsPatchVaryings;

    // Sprint 8 #8 β.2 (CKPT69): cross-stage varying interface chain.
    // Scan TCS interface to derive:
    //   crossStageVsToTcs[k] = TCS-input user-block member names (= VS
    //     output member names), widths parallel.
    //   crossStageTcsToTes[k] = TCS-output user-block member names
    //     (= TES input member names), widths parallel.
    // Filter to per-vertex non-builtin user-block members; built-in
    // gl_PerVertex slots (Position / ClipDistance / CullDistance) are
    // routed through EmulatedVertex's dedicated fields, not the
    // generic varyings list.
    std::vector<std::string>   crossStageVsToTcs;
    std::vector<std::uint32_t> crossStageVsToTcsWidths;
    std::vector<std::string>   crossStageTcsToTes;
    std::vector<std::uint32_t> crossStageTcsToTesWidths;
    if (!program.tessControlSpirv.empty()) {
        TessControlInterface tcIface = scanTessControlInterface(
            program.tessControlSpirv.data(),
            program.tessControlSpirv.size());
        if (tcIface.parsed) {
            for (const auto& iv : tcIface.inputs) {
                if (iv.isBuiltIn) continue;
                if (!iv.isPerVertex) continue;
                if (iv.scalarCount == 0) continue;
                crossStageVsToTcs.push_back(iv.name);
                crossStageVsToTcsWidths.push_back(iv.scalarCount);
            }
            for (const auto& ov : tcIface.outputs) {
                if (ov.isBuiltIn) continue;
                if (!ov.isPerVertex) continue;
                if (ov.scalarCount == 0) continue;
                crossStageTcsToTes.push_back(ov.name);
                crossStageTcsToTesWidths.push_back(ov.scalarCount);
            }
        }
    }
    // When there's no TCS, the VS-output → TES-input cross-stage runs
    // directly. Scan TES inputs for the same user-block per-vertex
    // shape to derive what the VS pre-pass should capture, and use the
    // same list as the TES input map (since there's no intermediate
    // TCS to relabel members).
    if (program.tessControlSpirv.empty() && !program.tessEvalSpirv.empty()) {
        TessEvalInterface teIface = scanTessEvalInterface(
            program.tessEvalSpirv.data(),
            program.tessEvalSpirv.size());
        if (teIface.parsed) {
            for (const auto& iv : teIface.inputs) {
                if (iv.isBuiltIn) continue;
                if (!iv.isPerVertex) continue;
                if (iv.scalarCount == 0) continue;
                crossStageVsToTcs.push_back(iv.name);
                crossStageVsToTcsWidths.push_back(iv.scalarCount);
                crossStageTcsToTes.push_back(iv.name);
                crossStageTcsToTesWidths.push_back(iv.scalarCount);
            }
        }
    }

    // Phase 3f-10: VS pre-pass now runs BEFORE the TCS pre-pass so
    // TCS's gl_in[] reads see real VS outputs. Runs whenever EITHER
    // `tessellationEmulated` (passthrough) or `tessellationInterpreted`
    // (body walker) is set. Moved from below the TES emit loop.
    std::size_t vsFailures = 0;
    const bool needVsPrePass =
        (program.tessellationEmulated || program.tessellationInterpreted) &&
        !program.vertexSpirv.empty();
    if (needVsPrePass) {
        patchInputs.assign(numPatches,
            std::vector<EmulatedVertex>(static_cast<std::size_t>(patchVertices)));
        for (std::size_t p = 0; p < numPatches; ++p) {
            const std::size_t patchBase = p * static_cast<std::size_t>(patchVertices);
            for (GLint pv = 0; pv < patchVertices; ++pv) {
                // Phase 3f-16: pick the VBO slot based on the draw
                // entry. drawArrays: (first + patchBase + pv).
                // drawElements: elementIndices[patchBase + pv] — the
                // index buffer resolves to the VBO slot. Caller is
                // responsible for uint32-promotion of byte/short
                // indices (IndexExpansion handles it).
                std::size_t vboSlot;
                if (elementIndices != nullptr) {
                    const std::size_t elemIdx = patchBase + static_cast<std::size_t>(pv);
                    vboSlot = static_cast<std::size_t>(elementIndices[elemIdx]);
                } else {
                    vboSlot = static_cast<std::size_t>(first) + patchBase +
                              static_cast<std::size_t>(pv);
                }
                std::string vsDiag;
                const bool vsOk = runVsForVertex(
                    program.vertexSpirv.data(), program.vertexSpirv.size(),
                    program, vao, objects, vboSlot, 0 /*instanceID*/,
                    crossStageVsToTcs, crossStageVsToTcsWidths,
                    patchInputs[p][static_cast<std::size_t>(pv)], &vsDiag,
                    nullptr, tessUboMapPtr);
                if (!vsOk) {
                    ++vsFailures;
                    auto& pos = patchInputs[p][static_cast<std::size_t>(pv)].position;
                    pos[0] = pos[1] = pos[2] = 0.0f;
                    pos[3] = 1.0f;
                }
            }
        }
    }

    // Phase-3f-4: TCS pre-pass. Runs once per (patch, invocationID)
    // where invocationID ∈ [0, layout(vertices=N)). SSBO writes land
    // through the same binding map; gl_TessLevel* writes are ignored
    // (emulateTessellationDraw is already using the TCS constant-
    // level extractor's output or the glPatchParameterfv defaults).
    // TCS-INTERPRETED branch: the SSBO side effects are the whole
    // point of running the TCS for the CE tess_control cluster.
    if (program.tessControlInterpreted && !program.tessControlSpirv.empty()) {
        const std::int32_t outputVertices =
            program.tessControlOutputVertices > 0
                ? program.tessControlOutputVertices : 1;
        const bool tcsDebug = (std::getenv("APPGL_TESS_EMUL_DEBUG") != nullptr);
        if (tcsDebug) {
            std::fprintf(stderr, "[tess-emul] TCS pre-pass: %zu patches x %d invocations, "
                "ssboBindings=%zu, patchVertices=%d\n",
                numPatches, outputVertices,
                ssboMap ? ssboMap->size() : 0, patchVertices);
        }
        // Phase 3f-10: also collect gl_out[k] for each (patch,
        // invocation) so the TES emit loop can feed it as gl_in[].
        // Dimensions: tcsOutputs[p][k] where k ∈ [0, outputVertices).
        // Only populated when VS pre-pass produced patchInputs AND
        // the TCS actually reads them (gl_in[] path); otherwise a
        // no-op fallback keeps the VS-direct flow.
        tcsOutputs.assign(numPatches,
            std::vector<EmulatedVertex>(static_cast<std::size_t>(outputVertices)));
        // Phase 3f-14: allocate one patch-varying map per patch.
        // Each invocation of a given patch accumulates into the
        // same map (last-write-wins per GL 4.6 §11.2.2).
        tcsPatchVaryings.assign(numPatches, TesPatchVaryingMap{});
        const std::vector<EmulatedVertex> emptyPatchInputs;
        for (std::size_t p = 0; p < numPatches; ++p) {
            const auto& thisPatchInputs = (p < patchInputs.size())
                ? patchInputs[p] : emptyPatchInputs;
            for (std::int32_t iv = 0; iv < outputVertices; ++iv) {
                std::string diag;
                EmulatedVertex& slot = tcsOutputs[p][static_cast<std::size_t>(iv)];
                slot.position[0] = 0.0f; slot.position[1] = 0.0f;
                slot.position[2] = 0.0f; slot.position[3] = 1.0f;
                const bool ok = runTcsForVertex(
                    program.tessControlSpirv.data(),
                    program.tessControlSpirv.size(),
                    program,
                    static_cast<std::int32_t>(p),
                    iv,
                    patchVertices,
                    ssboMap,
                    thisPatchInputs,
                    slot,
                    /*outerLevelsOut=*/nullptr,
                    /*innerLevelsOut=*/nullptr,
                    uniformMapPtr,
                    &tcsPatchVaryings[p],
                    &diag,
                    /*inVaryingNames=*/  &crossStageVsToTcs,
                    /*inVaryingWidths=*/ &crossStageVsToTcsWidths,
                    /*outVaryingNames=*/ &crossStageTcsToTes,
                    /*outVaryingWidths=*/&crossStageTcsToTesWidths,
                    /*sampledTextures=*/tcsSampledTextures,
                    /*storageImages=*/tcsStorageImages,
                    /*uniformBuffers=*/tessUboMapPtr);
                if (tcsDebug && !ok) {
                    std::fprintf(stderr, "[tess-emul] TCS bail (patch=%zu iv=%d): %s\n",
                        p, iv, diag.c_str());
                }
                (void)ok; (void)diag;
                // On TCS bail we'd lose the side effects for that
                // invocation, but still run subsequent ones — this
                // mirrors how GL's "undefined on shader error" model
                // allows graceful degradation per spec §8.5.
            }
        }
        tcsOutputsValid = true;
    }

    // Phase-3f-2: interpreter path. When the passthrough matcher
    // rejected the TES body but the classifier flipped
    // `tessellationInterpreted`, invoke runTesForVertex per generated
    // vertex — slower (one interpreter run per output vertex) but
    // expressive enough to handle CE tess_eval bodies. Position is
    // captured from gl_Position; user varyings are NOT propagated yet
    // (phase 3f-4 scans TES outputs to populate tessVaryings). SSBO
    // reads/writes are routed byte-level through `ssboMap` into the
    // bound GL buffer's Metal contents.
    // patchInputs[] is populated in a VS pre-pass further below, but
    // the emitVertex lambda captures it by reference so the later
    // Build the varying-names/widths vectors the interpreter expects
    // — same shape as the passthrough matcher's tessVaryings but
    // produced from the scanned TES output interface at link time.
    std::vector<std::string> interpVaryingNames;
    std::vector<std::uint32_t> interpVaryingWidths;
    interpVaryingNames.reserve(program.tessVaryings.size());
    interpVaryingWidths.reserve(program.tessVaryings.size());
    for (const auto& v : program.tessVaryings) {
        interpVaryingNames.push_back(v.name);
        interpVaryingWidths.push_back(v.numComponents);
    }

    // Phase 3f-9: surface interpreter bail reasons behind the debug
    // env var. One-shot per draw (dedup by diagnostic string) so a
    // failing body doesn't spam every vertex.
    const bool tesDebug = (std::getenv("APPGL_TESS_EMUL_DEBUG") != nullptr);
    auto tesBailSeen = std::make_shared<std::unordered_set<std::string>>();

    // Phase 3f-15: track whether any TES invocation bailed. When
    // even one body fails, the draw's output is fundamentally
    // incorrect — silently rendering identity-coord geometry
    // masks bugs and produces false-pass results on tests that
    // happen not to check the bad vertex. Flipping
    // `anyTesBailed` causes emulateTessellationDraw to return
    // ok=false; the caller (drawArrays) falls through to the
    // legacy translated-no-tess path, which is closer to GL's
    // "undefined on shader error" behaviour.
    auto anyTesBailed = std::make_shared<bool>(false);

    auto emitVertexInterpreted = [&, tesDebug, tesBailSeen, anyTesBailed](
                                     std::size_t dstIdx,
                                     std::size_t patchIdx,
                                     float u, float v, float w) {
        EmulatedVertex outV;
        outV.position[0] = 0.0f; outV.position[1] = 0.0f;
        outV.position[2] = 0.0f; outV.position[3] = 1.0f;
        const std::array<float, 3> tessCoord{u, v, w};
        const std::int32_t primID = static_cast<std::int32_t>(patchIdx);
        std::string diag;
        const std::vector<EmulatedVertex> emptyInputs;
        // Phase 3f-10: prefer TCS outputs as TES gl_in[] when
        // available; fall back to VS outputs (the pre-3f-10 flow).
        const auto& thisPatchInputs =
            (tcsOutputsValid && patchIdx < tcsOutputs.size())
                ? tcsOutputs[patchIdx]
                : (patchIdx < patchInputs.size()
                       ? patchInputs[patchIdx] : emptyInputs);
        // Phase 3f-14: pick the patch-varying map for this patch.
        // Empty (no TCS ran, or no patch-out captured) is safe —
        // patch-in vars just stay at zero init.
        const TesPatchVaryingMap* thisPatchVaryings =
            (patchIdx < tcsPatchVaryings.size())
                ? &tcsPatchVaryings[patchIdx] : nullptr;
        const bool ok = runTesForVertex(
            program.tessEvalSpirv.data(),
            program.tessEvalSpirv.size(),
            program, tessCoord, primID,
            interpVaryingNames, interpVaryingWidths,
            ssboMap, thisPatchInputs, outV,
            uniformMapPtr, thisPatchVaryings, &diag,
            /*inVaryingNames=*/  &crossStageTcsToTes,
            /*inVaryingWidths=*/ &crossStageTcsToTesWidths,
            /*sampledTextures=*/tesSampledTextures,
            /*storageImages=*/tesStorageImages,
            /*uniformBuffers=*/tessUboMapPtr);
        if (!ok && tesDebug && !diag.empty() &&
            tesBailSeen->insert(diag).second) {
            std::fprintf(stderr, "[tess-emul] TES bail: %s\n", diag.c_str());
        }
        const std::size_t dst = dstIdx * floatsPerVertex;
        if (ok) {
            // Position
            d.expandedVertexData[dst + 0] = outV.position[0];
            d.expandedVertexData[dst + 1] = outV.position[1];
            d.expandedVertexData[dst + 2] = outV.position[2];
            d.expandedVertexData[dst + 3] = outV.position[3];
            // User varyings, concatenated in declaration order
            // (matches program.tessVaryings order).
            std::size_t vOff = kPosFloats;
            std::size_t src = 0;
            for (const auto& vmap : program.tessVaryings) {
                for (std::uint32_t c = 0; c < vmap.numComponents; ++c) {
                    d.expandedVertexData[dst + vOff + c] =
                        (src + c) < outV.varyings.size()
                            ? outV.varyings[src + c] : 0.0f;
                }
                vOff += vmap.numComponents;
                src += vmap.numComponents;
            }
            for (std::uint32_t c = 0; c < tessClipLen; ++c) {
                d.expandedVertexData[dst + clipBase + c] =
                    c < outV.clipDistance.size() ? outV.clipDistance[c] : 0.0f;
            }
            for (std::uint32_t c = 0; c < tessCullLen; ++c) {
                d.expandedVertexData[dst + cullBase + c] =
                    c < outV.cullDistance.size() ? outV.cullDistance[c] : 0.0f;
            }
        } else {
            // Phase 3f-15: interpreter bailed. Mark the draw as
            // failed so the caller (emulateTessellationDraw's
            // bottom-of-function enablement gate) returns
            // ok=false. drawArrays then falls through to the
            // legacy path, which doesn't render tessellation at
            // all — closer to GL's "undefined on shader error"
            // model than rendering visibly-wrong geometry.
            // Still zero-fill this vertex's slot so downstream
            // buffer consumers aren't reading uninitialised data
            // (defensive — we return ok=false either way).
            *anyTesBailed = true;
            d.expandedVertexData[dst + 0] = 0.0f;
            d.expandedVertexData[dst + 1] = 0.0f;
            d.expandedVertexData[dst + 2] = 0.0f;
            d.expandedVertexData[dst + 3] = 1.0f;
        }
    };

    // Phase 3f-10 moved the VS pre-pass BEFORE the TCS pre-pass so
    // TCS's gl_in[] reads see real VS outputs. `vsFailures` was
    // computed up there.

    for (std::size_t p = 0; p < numPatches; ++p) {
        const std::size_t dstPatchBase = p * expandPerPatch;
        if (isPoints) {
            for (std::size_t i = 0; i < coordsPerPatch; ++i) {
                const float u = coords[i * 3 + 0];
                const float v = coords[i * 3 + 1];
                const float w = coords[i * 3 + 2];
                if (useInterpreter) {
                    emitVertexInterpreted(dstPatchBase + i, p, u, v, w);
                } else {
                    emitVertex(dstPatchBase + i, u, v, w);
                }
            }
        } else {
            for (std::size_t i = 0; i < indices.size(); ++i) {
                const std::uint32_t idx = indices[i];
                const float u = coords[idx * 3 + 0];
                const float v = coords[idx * 3 + 1];
                const float w = coords[idx * 3 + 2];
                if (useInterpreter) {
                    emitVertexInterpreted(dstPatchBase + i, p, u, v, w);
                } else {
                    emitVertex(dstPatchBase + i, u, v, w);
                }
            }
        }
    }

    if (useInterpreter && d.cullDistanceLen > 0 && d.vertexCount > 0) {
        std::size_t primSize = 0;
        switch (d.topology) {
            case GL_POINTS:    primSize = 1; break;
            case GL_LINES:     primSize = 2; break;
            case GL_TRIANGLES: primSize = 3; break;
            default:           primSize = 0; break;
        }
        if (primSize > 0) {
            const std::size_t oldFpv = d.floatsPerVertex;
            const std::size_t newFpv = cullBase;
            std::vector<float> filtered;
            filtered.reserve(d.expandedVertexData.size());
            for (std::size_t base = 0; base < d.vertexCount; base += primSize) {
                const std::size_t avail =
                    std::min<std::size_t>(primSize, d.vertexCount - base);
                bool primitiveCulled = false;
                if (avail == primSize) {
                    for (std::uint32_t c = 0; c < d.cullDistanceLen; ++c) {
                        bool allNegative = true;
                        for (std::size_t k = 0; k < primSize; ++k) {
                            const float value =
                                d.expandedVertexData[(base + k) * oldFpv + cullBase + c];
                            if (value >= 0.0f) {
                                allNegative = false;
                                break;
                            }
                        }
                        if (allNegative) {
                            primitiveCulled = true;
                            break;
                        }
                    }
                }
                if (primitiveCulled) continue;
                for (std::size_t k = 0; k < avail; ++k) {
                    const float* src =
                        d.expandedVertexData.data() + (base + k) * oldFpv;
                    filtered.insert(filtered.end(), src, src + newFpv);
                }
            }
            d.vertexCount = newFpv > 0 ? filtered.size() / newFpv : 0;
            d.floatsPerVertex = newFpv;
            d.cullDistanceLen = 0;
            d.expandedVertexData = std::move(filtered);
        }
    }

    // Phase-2c enablement gate: only return ok=true when link-time
    // detection flipped one of the tess-emul flags. APPGL_ENABLE_TESS_EMUL=0
    // keeps the old legacy translated path for attribution/debugging.
    if (program.tessellationEmulated || program.tessellationInterpreted) {
        // Phase 3f-15: if any TES invocation bailed, the output is
        // incorrect by construction. Return ok=false so drawArrays
        // falls through to the legacy translated-no-tess path
        // instead of rendering the zeros we filled the buffer with.
        // Preserves the spec's "undefined on shader error" semantic
        // and avoids false-pass on tests that don't check bad
        // vertices.
        if (*anyTesBailed) {
            d.ok = false;
            d.diagnostic = "tess-emul 3f-15: TES interpreter bailed on one or "
                           "more invocations; falling back to legacy path. "
                           "Re-run with APPGL_TESS_EMUL_DEBUG=1 to surface "
                           "the specific bail reason.";
            return d;
        }
        d.ok = true;
        const char* mode = program.tessellationEmulated ? "passthrough" : "interpreter";
        d.diagnostic = std::string("tess-emul phase-3f-2 (") + mode + "): " +
                       std::to_string(numPatches) +
                       " patches × " + std::to_string(expandPerPatch) +
                       " verts = " + std::to_string(d.vertexCount) +
                       " (topology=0x" +
                       std::to_string(static_cast<unsigned>(domainOut.topology)) +
                       "), VS failures=" + std::to_string(vsFailures);
        return d;
    }
    d.diagnostic = "tess-emul phase-2a: " + std::to_string(numPatches) +
                   " patches × " + std::to_string(expandPerPatch) +
                   " output verts = " + std::to_string(d.vertexCount) +
                   " (topology=0x" +
                   std::to_string(static_cast<unsigned>(domainOut.topology)) +
                   ") — phase-2c disabled (APPGL_ENABLE_TESS_EMUL=0)";
    return d;
}

}  // namespace appgl
