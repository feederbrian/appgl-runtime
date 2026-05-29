// Shared SPIR-V module reader + scalar-width resolver for both GS and
// tess CPU emulators. Struct definitions live in ShaderInterpreter.h.
//
// This file owns only the parse-side helpers. The body-dispatching
// Interpreter class stays in GeometryShaderEmulator.cpp for now —
// moving it is a separate refactor (next infrastructure round) that
// touches far more code.

#include "ShaderInterpreter.h"

#ifdef APPGL_HAS_SHADER_COMPILER
#include "spirv.hpp"
#else
// Minimal stub when the shader compiler isn't available. Must match
// the mirror in GeometryShaderEmulator.cpp — the enum values are
// SPIR-V spec constants so any real parse path will reach the same
// numbers regardless of which side defines the enum.
namespace spv {
    constexpr std::uint32_t MagicNumber = 0x07230203;
    enum Op : std::uint32_t {
        OpExtInstImport = 11, OpEntryPoint = 15,
        OpExecutionMode = 16,
        OpName = 5, OpMemberName = 6,
        OpDecorate = 71, OpMemberDecorate = 72,
        OpTypeVoid = 19, OpTypeBool = 20, OpTypeInt = 21,
        OpTypeFloat = 22, OpTypeVector = 23, OpTypeMatrix = 24,
        OpTypeArray = 28, OpTypeRuntimeArray = 29,
        OpTypeStruct = 30, OpTypePointer = 32,
        OpTypeFunction = 33,
        OpConstant = 43, OpConstantTrue = 41, OpConstantFalse = 42,
        OpConstantComposite = 44,
        OpSpecConstantTrue = 48, OpSpecConstantFalse = 49,
        OpSpecConstant = 50, OpSpecConstantComposite = 51,
        OpSpecConstantOp = 52,
        OpSNegate = 126,
        OpIAdd = 128, OpISub = 130, OpIMul = 132,
        OpUDiv = 134, OpSDiv = 135,
        OpUMod = 137, OpSRem = 138, OpSMod = 139,
        OpBitwiseAnd = 199, OpBitwiseOr = 197, OpBitwiseXor = 198,
        OpLogicalAnd = 167, OpLogicalOr = 166, OpLogicalNot = 168,
        OpLogicalEqual = 164, OpLogicalNotEqual = 165,
        OpSelect = 169,
        OpIEqual = 170, OpINotEqual = 171,
        OpUGreaterThan = 172, OpSGreaterThan = 173,
        OpUGreaterThanEqual = 174, OpSGreaterThanEqual = 175,
        OpULessThan = 176, OpSLessThan = 177,
        OpULessThanEqual = 178, OpSLessThanEqual = 179,
        OpFNegate = 127, OpFAdd = 129, OpFSub = 131,
        OpFMul = 133, OpFDiv = 136,
        OpFOrdEqual = 180, OpFOrdNotEqual = 182,
        OpFOrdLessThan = 184, OpFOrdGreaterThan = 186,
        OpFOrdLessThanEqual = 188, OpFOrdGreaterThanEqual = 190,
        OpFunction = 54, OpFunctionParameter = 55, OpFunctionEnd = 56,
        OpVariable = 59,
    };
    enum Decoration : std::uint32_t {
        DecorationBlock = 2, DecorationBufferBlock = 3,
        DecorationLocation = 30, DecorationBuiltIn = 11,
        DecorationRowMajor = 4, DecorationColMajor = 5,
        DecorationArrayStride = 6,
        DecorationMatrixStride = 7,
        DecorationNoPerspective = 13, DecorationFlat = 14,
        DecorationPatch = 15,
        DecorationCentroid = 16, DecorationOffset = 35,
        DecorationDescriptorSet = 34, DecorationBinding = 33,
        DecorationSpecId = 1,
        // Sprint 8 #9-C (CKPT96) — GLSL `layout(stream=N) out` decoration.
        DecorationStream = 29,
    };
}
#endif

#include <cstring>

namespace appgl::interp {
namespace {

std::string readLiteralString(const std::uint32_t* w, std::size_t& i, std::size_t wordCount) {
    std::string out;
    while (i < wordCount) {
        std::uint32_t word = w[i++];
        for (int b = 0; b < 4; ++b) {
            char c = static_cast<char>((word >> (b * 8)) & 0xFF);
            if (c == '\0') return out;
            out.push_back(c);
        }
    }
    return out;
}

}  // namespace

std::uint32_t SpirvModule::scalarWidth(std::uint32_t typeId) const {
    auto it = types.find(typeId);
    if (it == types.end()) return 0;
    const TypeInfo& t = it->second;
    switch (t.kind) {
        case TypeInfo::Kind::Bool: case TypeInfo::Kind::Int:
        case TypeInfo::Kind::UInt: case TypeInfo::Kind::Float:
            return 1;
        case TypeInfo::Kind::Vec2: return 2;
        case TypeInfo::Kind::Vec3: return 3;
        case TypeInfo::Kind::Vec4: return 4;
        case TypeInfo::Kind::Matrix:
            return t.count * scalarWidth(t.componentType);
        case TypeInfo::Kind::Array: {
            auto cIt = constants.find(t.arrayLengthConstId);
            std::uint32_t len = 0;
            if (cIt != constants.end()) {
                len = static_cast<std::uint32_t>(cIt->second.i[0]);
            }
            return len * scalarWidth(t.componentType);
        }
        case TypeInfo::Kind::RuntimeArray:
            // Unbounded — scalar-count isn't statically known. Returning
            // 0 means "don't allocate flat storage for this type"; the
            // interpreter's initVariables skips it and the access-chain
            // path routes through StorageBuffer byte-offsets instead.
            return 0;
        case TypeInfo::Kind::Struct: {
            std::uint32_t s = 0;
            for (auto m : t.memberTypes) s += scalarWidth(m);
            return s;
        }
        case TypeInfo::Kind::Pointer:
            return scalarWidth(t.pointeeType);
        default: return 0;
    }
}

bool specializationOverride(
    const std::unordered_map<std::uint32_t, DecorationSet>& decorations,
    const std::unordered_map<std::uint32_t, std::uint32_t>* specializationConstants,
    std::uint32_t resultId,
    std::uint32_t& value) {
    if (specializationConstants == nullptr) return false;
    auto decoIt = decorations.find(resultId);
    if (decoIt == decorations.end() || !decoIt->second.hasSpecId) {
        return false;
    }
    auto valueIt = specializationConstants->find(decoIt->second.specId);
    if (valueIt == specializationConstants->end()) return false;
    value = valueIt->second;
    return true;
}

Value makeScalarConstantValue(
    const std::unordered_map<std::uint32_t, TypeInfo>& types,
    std::uint32_t typeId,
    const std::uint32_t* words,
    std::size_t wordCount) {
    auto typeIt = types.find(typeId);
    Value v;
    if (typeIt == types.end()) return v;
    const TypeInfo& t = typeIt->second;
    if (t.kind == TypeInfo::Kind::Float) {
        if (t.elementScalarWidth == 8 && wordCount >= 2) {
            std::uint64_t bits =
                static_cast<std::uint64_t>(words[0]) |
                (static_cast<std::uint64_t>(words[1]) << 32u);
            double d = 0.0;
            std::memcpy(&d, &bits, sizeof(d));
            return Value::makeFloat(static_cast<float>(d));
        }
        float f = 0.0f;
        if (wordCount >= 1) {
            std::memcpy(&f, &words[0], sizeof(float));
        }
        return Value::makeFloat(f);
    }
    if (t.kind == TypeInfo::Kind::Int) {
        return Value::makeInt(wordCount >= 1 ? static_cast<std::int32_t>(words[0]) : 0);
    }
    if (t.kind == TypeInfo::Kind::UInt) {
        return Value::makeUInt(wordCount >= 1 ? words[0] : 0u);
    }
    if (t.kind == TypeInfo::Kind::Bool) {
        return Value::makeBool(wordCount >= 1 && words[0] != 0);
    }
    return v;
}

std::int32_t valueAsInt(const Value& v) {
    if (v.kind == Value::Kind::Bool) return v.bval ? 1 : 0;
    if (v.isFloatKind()) return static_cast<std::int32_t>(v.f[0]);
    return v.i[0];
}

std::uint32_t valueAsUInt(const Value& v) {
    return static_cast<std::uint32_t>(valueAsInt(v));
}

float valueAsFloat(const Value& v) {
    if (v.kind == Value::Kind::Bool) return v.bval ? 1.0f : 0.0f;
    if (v.isFloatKind()) return v.f[0];
    return static_cast<float>(v.i[0]);
}

bool valueAsBool(const Value& v) {
    if (v.kind == Value::Kind::Bool) return v.bval;
    if (v.isFloatKind()) return v.f[0] != 0.0f;
    return v.i[0] != 0;
}

Value typedScalarValue(const SpirvModule& module, std::uint32_t typeId,
                       std::int32_t i, std::uint32_t u, float f, bool b) {
    auto typeIt = module.types.find(typeId);
    if (typeIt == module.types.end()) return {};
    switch (typeIt->second.kind) {
        case TypeInfo::Kind::Bool:  return Value::makeBool(b);
        case TypeInfo::Kind::UInt:  return Value::makeUInt(u);
        case TypeInfo::Kind::Float: return Value::makeFloat(f);
        case TypeInfo::Kind::Int:   return Value::makeInt(i);
        default: return {};
    }
}

Value evalSpecConstantOp(const SpirvModule& module,
                         std::uint32_t resultTypeId,
                         std::uint32_t opcode,
                         const std::uint32_t* operands,
                         std::size_t operandCount) {
    auto constantAt = [&](std::size_t idx, Value& out) -> bool {
        if (idx >= operandCount) return false;
        auto it = module.constants.find(operands[idx]);
        if (it == module.constants.end()) return false;
        out = it->second;
        return true;
    };
    Value a, b, c;
    const bool haveA = constantAt(0, a);
    const bool haveB = constantAt(1, b);
    const bool haveC = constantAt(2, c);
    (void)haveC;
    if (!haveA) return {};

    switch (opcode) {
        case spv::OpSNegate:
            return typedScalarValue(module, resultTypeId, -valueAsInt(a),
                                    static_cast<std::uint32_t>(-valueAsInt(a)),
                                    -valueAsFloat(a), false);
        case spv::OpIAdd:
            if (!haveB) return {};
            return typedScalarValue(module, resultTypeId,
                                    valueAsInt(a) + valueAsInt(b),
                                    valueAsUInt(a) + valueAsUInt(b),
                                    valueAsFloat(a) + valueAsFloat(b), false);
        case spv::OpISub:
            if (!haveB) return {};
            return typedScalarValue(module, resultTypeId,
                                    valueAsInt(a) - valueAsInt(b),
                                    valueAsUInt(a) - valueAsUInt(b),
                                    valueAsFloat(a) - valueAsFloat(b), false);
        case spv::OpIMul:
            if (!haveB) return {};
            return typedScalarValue(module, resultTypeId,
                                    valueAsInt(a) * valueAsInt(b),
                                    valueAsUInt(a) * valueAsUInt(b),
                                    valueAsFloat(a) * valueAsFloat(b), false);
        case spv::OpUDiv:
            if (!haveB || valueAsUInt(b) == 0u) return {};
            return typedScalarValue(module, resultTypeId, 0,
                                    valueAsUInt(a) / valueAsUInt(b),
                                    0.0f, false);
        case spv::OpSDiv:
            if (!haveB || valueAsInt(b) == 0) return {};
            return typedScalarValue(module, resultTypeId,
                                    valueAsInt(a) / valueAsInt(b),
                                    0, 0.0f, false);
        case spv::OpUMod:
            if (!haveB || valueAsUInt(b) == 0u) return {};
            return typedScalarValue(module, resultTypeId, 0,
                                    valueAsUInt(a) % valueAsUInt(b),
                                    0.0f, false);
        case spv::OpSRem:
        case spv::OpSMod:
            if (!haveB || valueAsInt(b) == 0) return {};
            return typedScalarValue(module, resultTypeId,
                                    valueAsInt(a) % valueAsInt(b),
                                    0, 0.0f, false);
        case spv::OpBitwiseAnd:
            if (!haveB) return {};
            return typedScalarValue(module, resultTypeId,
                                    valueAsInt(a) & valueAsInt(b),
                                    valueAsUInt(a) & valueAsUInt(b),
                                    0.0f, false);
        case spv::OpBitwiseOr:
            if (!haveB) return {};
            return typedScalarValue(module, resultTypeId,
                                    valueAsInt(a) | valueAsInt(b),
                                    valueAsUInt(a) | valueAsUInt(b),
                                    0.0f, false);
        case spv::OpBitwiseXor:
            if (!haveB) return {};
            return typedScalarValue(module, resultTypeId,
                                    valueAsInt(a) ^ valueAsInt(b),
                                    valueAsUInt(a) ^ valueAsUInt(b),
                                    0.0f, false);
        case spv::OpFNegate:
            return typedScalarValue(module, resultTypeId, 0, 0u,
                                    -valueAsFloat(a), false);
        case spv::OpFAdd:
            if (!haveB) return {};
            return typedScalarValue(module, resultTypeId, 0, 0u,
                                    valueAsFloat(a) + valueAsFloat(b), false);
        case spv::OpFSub:
            if (!haveB) return {};
            return typedScalarValue(module, resultTypeId, 0, 0u,
                                    valueAsFloat(a) - valueAsFloat(b), false);
        case spv::OpFMul:
            if (!haveB) return {};
            return typedScalarValue(module, resultTypeId, 0, 0u,
                                    valueAsFloat(a) * valueAsFloat(b), false);
        case spv::OpFDiv:
            if (!haveB || valueAsFloat(b) == 0.0f) return {};
            return typedScalarValue(module, resultTypeId, 0, 0u,
                                    valueAsFloat(a) / valueAsFloat(b), false);
        case spv::OpLogicalAnd:
            if (!haveB) return {};
            return Value::makeBool(valueAsBool(a) && valueAsBool(b));
        case spv::OpLogicalOr:
            if (!haveB) return {};
            return Value::makeBool(valueAsBool(a) || valueAsBool(b));
        case spv::OpLogicalNot:
            return Value::makeBool(!valueAsBool(a));
        case spv::OpLogicalEqual:
            if (!haveB) return {};
            return Value::makeBool(valueAsBool(a) == valueAsBool(b));
        case spv::OpLogicalNotEqual:
            if (!haveB) return {};
            return Value::makeBool(valueAsBool(a) != valueAsBool(b));
        case spv::OpIEqual:
            if (!haveB) return {};
            return Value::makeBool(valueAsInt(a) == valueAsInt(b));
        case spv::OpINotEqual:
            if (!haveB) return {};
            return Value::makeBool(valueAsInt(a) != valueAsInt(b));
        case spv::OpUGreaterThan:
            if (!haveB) return {};
            return Value::makeBool(valueAsUInt(a) > valueAsUInt(b));
        case spv::OpUGreaterThanEqual:
            if (!haveB) return {};
            return Value::makeBool(valueAsUInt(a) >= valueAsUInt(b));
        case spv::OpULessThan:
            if (!haveB) return {};
            return Value::makeBool(valueAsUInt(a) < valueAsUInt(b));
        case spv::OpULessThanEqual:
            if (!haveB) return {};
            return Value::makeBool(valueAsUInt(a) <= valueAsUInt(b));
        case spv::OpSGreaterThan:
            if (!haveB) return {};
            return Value::makeBool(valueAsInt(a) > valueAsInt(b));
        case spv::OpSGreaterThanEqual:
            if (!haveB) return {};
            return Value::makeBool(valueAsInt(a) >= valueAsInt(b));
        case spv::OpSLessThan:
            if (!haveB) return {};
            return Value::makeBool(valueAsInt(a) < valueAsInt(b));
        case spv::OpSLessThanEqual:
            if (!haveB) return {};
            return Value::makeBool(valueAsInt(a) <= valueAsInt(b));
        case spv::OpFOrdEqual:
            if (!haveB) return {};
            return Value::makeBool(valueAsFloat(a) == valueAsFloat(b));
        case spv::OpFOrdNotEqual:
            if (!haveB) return {};
            return Value::makeBool(valueAsFloat(a) != valueAsFloat(b));
        case spv::OpFOrdLessThan:
            if (!haveB) return {};
            return Value::makeBool(valueAsFloat(a) < valueAsFloat(b));
        case spv::OpFOrdGreaterThan:
            if (!haveB) return {};
            return Value::makeBool(valueAsFloat(a) > valueAsFloat(b));
        case spv::OpFOrdLessThanEqual:
            if (!haveB) return {};
            return Value::makeBool(valueAsFloat(a) <= valueAsFloat(b));
        case spv::OpFOrdGreaterThanEqual:
            if (!haveB) return {};
            return Value::makeBool(valueAsFloat(a) >= valueAsFloat(b));
        case spv::OpSelect:
            if (!haveB || !haveC) return {};
            return valueAsBool(a) ? b : c;
        default:
            return {};
    }
}

bool SpirvModule::parse(
    const std::uint32_t* data,
    std::size_t count,
    const std::string* entryPointName,
    const std::unordered_map<std::uint32_t, std::uint32_t>* specializationConstants) {
    if (count < 5 || data[0] != spv::MagicNumber) {
        parseError.clear();
        parseError = "bad SPIR-V magic";
        return false;
    }
    bound = 0;
    words.clear();
    types.clear();
    constants.clear();
    matrixConstants.clear();
    constantComposites.clear();
    variables.clear();
    decorations.clear();
    memberDecorations.clear();
    names.clear();
    memberNames0.clear();
    memberNames.clear();
    extInstImports.clear();
    entryPoint = 0;
    entryInterface.clear();
    executionModes.clear();
    functions.clear();
    funcBodyStart = 0;
    funcBodyEnd = 0;
    haveFuncBody = false;
    parseError.clear();

    bound = data[3];
    words.assign(data, data + count);

    std::size_t i = 5;
    bool inFunctionBody = false;
    std::size_t currentFuncStart = 0;
    std::uint32_t currentFuncId = 0;
    FunctionInfo currentFunc;
    const bool wantsEntryPoint =
        entryPointName != nullptr && !entryPointName->empty();
    bool haveSelectedEntryPoint = false;
    bool haveFallbackEntryPoint = false;
    std::uint32_t fallbackEntryPoint = 0;
    std::vector<std::uint32_t> fallbackEntryInterface;
    struct PendingExecutionMode {
        std::uint32_t entryPointId = 0;
        std::uint32_t mode = 0;
        std::vector<std::uint32_t> operands;
    };
    std::vector<PendingExecutionMode> pendingExecutionModes;
    while (i < count) {
        const std::uint32_t inst = data[i];
        const std::uint16_t opcode = inst & 0xFFFF;
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0 || i + wc > count) {
            parseError = "malformed instruction";
            return false;
        }
        const std::uint32_t* w = data + i + 1;

        switch (opcode) {
            case spv::OpExtInstImport: {
                if (wc >= 3) {
                    std::size_t j = i + 2;
                    std::string name = readLiteralString(data, j, count);
                    if (name == "GLSL.std.450") {
                        extInstImports[w[0]] = 1;
                    }
                }
                break;
            }
            case spv::OpEntryPoint: {
                if (wc >= 3) {
                    const std::uint32_t candidateEntryPoint = w[1];
                    std::size_t j = i + 3;
                    std::string candidateName = readLiteralString(data, j, count);
                    std::vector<std::uint32_t> candidateInterface;
                    while (j < i + wc) candidateInterface.push_back(data[j++]);
                    if (!haveFallbackEntryPoint) {
                        fallbackEntryPoint = candidateEntryPoint;
                        fallbackEntryInterface = candidateInterface;
                        haveFallbackEntryPoint = true;
                    }
                    const bool selectCandidate =
                        (!wantsEntryPoint && !haveSelectedEntryPoint) ||
                        (wantsEntryPoint && candidateName == *entryPointName);
                    if (selectCandidate) {
                        entryPoint = candidateEntryPoint;
                        entryInterface = std::move(candidateInterface);
                        haveSelectedEntryPoint = true;
                    }
                }
                break;
            }
            case spv::OpExecutionMode: {
                if (wc >= 3) {
                    PendingExecutionMode pending;
                    pending.entryPointId = w[0];
                    pending.mode = w[1];
                    for (std::uint32_t k = 2; k < static_cast<std::uint32_t>(wc - 1); ++k) {
                        pending.operands.push_back(w[k]);
                    }
                    pendingExecutionModes.push_back(std::move(pending));
                }
                break;
            }
            case spv::OpName: {
                if (wc >= 3) {
                    std::size_t j = i + 2;
                    names[w[0]] = readLiteralString(data, j, count);
                }
                break;
            }
            case spv::OpMemberName: {
                if (wc >= 4) {
                    const std::uint32_t structId = w[0];
                    const std::uint32_t memberIdx = w[1];
                    std::size_t j = i + 3;
                    std::string mname = readLiteralString(data, j, count);
                    if (memberIdx == 0) memberNames0[structId] = mname;
                    memberNames[structId][memberIdx] = std::move(mname);
                }
                break;
            }
            case spv::OpDecorate: {
                if (wc < 3) break;
                const std::uint32_t target = w[0];
                const std::uint32_t deco = w[1];
                if (deco == spv::DecorationLocation && wc >= 4) {
                    decorations[target].hasLocation = true;
                    decorations[target].location = w[2];
                } else if (deco == spv::DecorationBuiltIn && wc >= 4) {
                    decorations[target].hasBuiltIn = true;
                    decorations[target].builtIn = w[2];
                } else if (deco == spv::DecorationFlat) {
                    decorations[target].isFlat = true;
                } else if (deco == spv::DecorationNoPerspective) {
                    decorations[target].isNoPerspective = true;
                } else if (deco == spv::DecorationCentroid) {
                    decorations[target].isCentroid = true;
                } else if (deco == spv::DecorationPatch) {
                    decorations[target].isPatch = true;
                } else if (deco == spv::DecorationBlock) {
                    decorations[target].isBlock = true;
                } else if (deco == spv::DecorationBufferBlock) {
                    decorations[target].isBlock = true;
                    decorations[target].isBufferBlock = true;
                } else if (deco == spv::DecorationArrayStride && wc >= 4) {
                    decorations[target].hasArrayStride = true;
                    decorations[target].arrayStride = w[2];
                } else if (deco == spv::DecorationMatrixStride && wc >= 4) {
                    decorations[target].hasMatrixStride = true;
                    decorations[target].matrixStride = w[2];
                } else if (deco == spv::DecorationRowMajor) {
                    decorations[target].isRowMajor = true;
                } else if (deco == spv::DecorationColMajor) {
                    decorations[target].isColMajor = true;
                } else if (deco == spv::DecorationBinding && wc >= 4) {
                    decorations[target].hasBinding = true;
                    decorations[target].binding = w[2];
                } else if (deco == spv::DecorationDescriptorSet && wc >= 4) {
                    decorations[target].hasDescriptorSet = true;
                    decorations[target].descriptorSet = w[2];
                } else if (deco == spv::DecorationSpecId && wc >= 4) {
                    decorations[target].hasSpecId = true;
                    decorations[target].specId = w[2];
                } else if (deco == spv::DecorationOffset && wc >= 4) {
                    decorations[target].hasOffset = true;
                    decorations[target].offset = w[2];
                } else if (deco == spv::DecorationStream && wc >= 4) {
                    // Sprint 8 #9-C (CKPT96): GLSL `layout(stream=N) out`
                    // → DecorationStream on the OpVariable. Used by
                    // writeGsXfbAndCheckDiscard to route per-stream BO
                    // writes for multi-stream GS programs.
                    decorations[target].hasStream = true;
                    decorations[target].stream = w[2];
                }
                break;
            }
            case spv::OpMemberDecorate: {
                if (wc < 4) break;
                const std::uint32_t target = w[0];
                const std::uint32_t member = w[1];
                const std::uint32_t deco = w[2];
                if (deco == spv::DecorationBuiltIn && wc >= 5) {
                    memberDecorations[target].perMember[member].hasBuiltIn = true;
                    memberDecorations[target].perMember[member].builtIn = w[3];
                } else if (deco == spv::DecorationLocation && wc >= 5) {
                    memberDecorations[target].perMember[member].hasLocation = true;
                    memberDecorations[target].perMember[member].location = w[3];
                } else if (deco == spv::DecorationPatch) {
                    memberDecorations[target].perMember[member].isPatch = true;
                } else if (deco == spv::DecorationOffset && wc >= 5) {
                    memberDecorations[target].perMember[member].hasOffset = true;
                    memberDecorations[target].perMember[member].offset = w[3];
                } else if (deco == spv::DecorationArrayStride && wc >= 5) {
                    memberDecorations[target].perMember[member].hasArrayStride = true;
                    memberDecorations[target].perMember[member].arrayStride = w[3];
                } else if (deco == spv::DecorationMatrixStride && wc >= 5) {
                    memberDecorations[target].perMember[member].hasMatrixStride = true;
                    memberDecorations[target].perMember[member].matrixStride = w[3];
                } else if (deco == spv::DecorationRowMajor) {
                    memberDecorations[target].perMember[member].isRowMajor = true;
                } else if (deco == spv::DecorationColMajor) {
                    memberDecorations[target].perMember[member].isColMajor = true;
                }
                break;
            }
            case spv::OpTypeVoid:  types[w[0]] = {TypeInfo::Kind::Void};  break;
            case spv::OpTypeBool:  types[w[0]] = {TypeInfo::Kind::Bool};  break;
            case spv::OpTypeInt: {
                TypeInfo t;
                const bool isSigned = (wc >= 4 && w[2] != 0);
                t.kind = isSigned ? TypeInfo::Kind::Int : TypeInfo::Kind::UInt;
                t.elementScalarWidth = (wc >= 3 && w[1] >= 8) ? (w[1] / 8) : 4;
                types[w[0]] = t;
                break;
            }
            case spv::OpTypeFloat: {
                TypeInfo t;
                t.kind = TypeInfo::Kind::Float;
                t.elementScalarWidth = (wc >= 3 && w[1] >= 8) ? (w[1] / 8) : 4;
                types[w[0]] = t;
                break;
            }
            case spv::OpTypeVector: {
                TypeInfo t;
                t.componentType = w[1];
                t.count = w[2];
                if      (t.count == 2) t.kind = TypeInfo::Kind::Vec2;
                else if (t.count == 3) t.kind = TypeInfo::Kind::Vec3;
                else if (t.count == 4) t.kind = TypeInfo::Kind::Vec4;
                types[w[0]] = t;
                break;
            }
            case spv::OpTypeMatrix: {
                TypeInfo t;
                t.kind = TypeInfo::Kind::Matrix;
                t.componentType = w[1];
                t.count = w[2];
                types[w[0]] = t;
                break;
            }
            case spv::OpTypeArray: {
                TypeInfo t;
                t.kind = TypeInfo::Kind::Array;
                t.componentType = w[1];
                t.arrayLengthConstId = w[2];
                types[w[0]] = t;
                break;
            }
            case spv::OpTypeRuntimeArray: {
                // Unbounded array. Only meaningful inside StorageBuffer /
                // UBO blocks. Byte stride lives in the DecorationArrayStride
                // decoration (already parsed above). The element scalar
                // width is computed on demand via `scalarWidth` when
                // needed — we don't know the array length so the total
                // storage allocation is driven by the caller's buffer
                // map (phase 3f-3).
                TypeInfo t;
                t.kind = TypeInfo::Kind::RuntimeArray;
                t.componentType = w[1];
                types[w[0]] = t;
                break;
            }
            case spv::OpTypeStruct: {
                TypeInfo t;
                t.kind = TypeInfo::Kind::Struct;
                for (std::uint32_t k = 1; k < wc - 1; ++k) {
                    t.memberTypes.push_back(w[k]);
                }
                types[w[0]] = t;
                break;
            }
            case spv::OpTypePointer: {
                TypeInfo t;
                t.kind = TypeInfo::Kind::Pointer;
                t.storageClass = w[1];
                t.pointeeType = w[2];
                types[w[0]] = t;
                break;
            }
            case spv::OpTypeFunction: {
                TypeInfo t;
                t.kind = TypeInfo::Kind::Function;
                t.returnType = w[1];
                types[w[0]] = t;
                break;
            }
            case spv::OpConstant: {
                const std::size_t literalWords = wc > 3 ? static_cast<std::size_t>(wc - 3) : 0;
                constants[w[1]] = makeScalarConstantValue(types, w[0], w + 2, literalWords);
                break;
            }
            case spv::OpConstantTrue:  constants[w[1]] = Value::makeBool(true);  break;
            case spv::OpConstantFalse: constants[w[1]] = Value::makeBool(false); break;
            case spv::OpSpecConstant: {
                std::uint32_t overrideValue = 0;
                if (specializationOverride(
                        decorations, specializationConstants, w[1], overrideValue)) {
                    constants[w[1]] = makeScalarConstantValue(types, w[0], &overrideValue, 1);
                } else {
                    const std::size_t literalWords = wc > 3 ? static_cast<std::size_t>(wc - 3) : 0;
                    constants[w[1]] = makeScalarConstantValue(types, w[0], w + 2, literalWords);
                }
                break;
            }
            case spv::OpSpecConstantTrue: {
                std::uint32_t overrideValue = 0;
                constants[w[1]] = Value::makeBool(
                    specializationOverride(decorations, specializationConstants, w[1], overrideValue)
                        ? overrideValue != 0
                        : true);
                break;
            }
            case spv::OpSpecConstantFalse: {
                std::uint32_t overrideValue = 0;
                constants[w[1]] = Value::makeBool(
                    specializationOverride(decorations, specializationConstants, w[1], overrideValue)
                        ? overrideValue != 0
                        : false);
                break;
            }
            case spv::OpConstantComposite: {
                ConstantCompositeInfo compositeInfo;
                compositeInfo.typeId = w[0];
                const std::size_t operandCount = wc > 0 ? static_cast<std::size_t>(wc - 1) : 0;
                if (operandCount > 2) {
                    compositeInfo.constituents.assign(w + 2, w + operandCount);
                }
                constantComposites[w[1]] = std::move(compositeInfo);
                auto typeIt = types.find(w[0]);
                Value v;
                if (typeIt != types.end()) {
                    const TypeInfo& t = typeIt->second;
                    if (t.kind == TypeInfo::Kind::Vec2 || t.kind == TypeInfo::Kind::Vec3 ||
                        t.kind == TypeInfo::Kind::Vec4) {
                        const auto& compT = types[t.componentType];
                        const bool isFloat = (compT.kind == TypeInfo::Kind::Float);
                        if (isFloat) {
                            v.kind = (t.count == 2) ? Value::Kind::Float2 :
                                     (t.count == 3) ? Value::Kind::Float3 : Value::Kind::Float4;
                            for (std::uint32_t k = 0; k < t.count && (2 + k) < operandCount; ++k) {
                                auto cIt = constants.find(w[2 + k]);
                                if (cIt != constants.end()) v.f[k] = cIt->second.f[0];
                            }
                        } else {
                            v.kind = (t.count == 2) ? Value::Kind::Int2 :
                                     (t.count == 3) ? Value::Kind::Int3 : Value::Kind::Int4;
                            const bool isBool = (compT.kind == TypeInfo::Kind::Bool);
                            for (std::uint32_t k = 0; k < t.count && (2 + k) < operandCount; ++k) {
                                auto cIt = constants.find(w[2 + k]);
                                if (cIt != constants.end()) {
                                    v.i[k] = isBool
                                        ? (cIt->second.bval ? 1 : 0)
                                        : cIt->second.i[0];
                                }
                            }
                        }
                    } else if (t.kind == TypeInfo::Kind::Matrix) {
                        std::vector<Value> columns;
                        columns.reserve(operandCount > 2 ? operandCount - 2 : 0);
                        for (std::uint32_t k = 2; k < operandCount; ++k) {
                            auto cIt = constants.find(w[k]);
                            if (cIt != constants.end()) {
                                columns.push_back(cIt->second);
                            }
                        }
                        if (!columns.empty()) {
                            matrixConstants[w[1]] = std::move(columns);
                        }
                    }
                }
                constants[w[1]] = v;
                break;
            }
            case spv::OpSpecConstantComposite: {
                ConstantCompositeInfo compositeInfo;
                compositeInfo.typeId = w[0];
                const std::size_t operandCount = wc > 0 ? static_cast<std::size_t>(wc - 1) : 0;
                if (operandCount > 2) {
                    compositeInfo.constituents.assign(w + 2, w + operandCount);
                }
                constantComposites[w[1]] = std::move(compositeInfo);
                auto typeIt = types.find(w[0]);
                Value v;
                if (typeIt != types.end()) {
                    const TypeInfo& t = typeIt->second;
                    if (t.kind == TypeInfo::Kind::Vec2 || t.kind == TypeInfo::Kind::Vec3 ||
                        t.kind == TypeInfo::Kind::Vec4) {
                        const auto& compT = types[t.componentType];
                        const bool isFloat = (compT.kind == TypeInfo::Kind::Float);
                        if (isFloat) {
                            v.kind = (t.count == 2) ? Value::Kind::Float2 :
                                     (t.count == 3) ? Value::Kind::Float3 : Value::Kind::Float4;
                            for (std::uint32_t k = 0; k < t.count && (2 + k) < operandCount; ++k) {
                                auto cIt = constants.find(w[2 + k]);
                                if (cIt != constants.end()) v.f[k] = cIt->second.f[0];
                            }
                        } else {
                            v.kind = (t.count == 2) ? Value::Kind::Int2 :
                                     (t.count == 3) ? Value::Kind::Int3 : Value::Kind::Int4;
                            const bool isBool = (compT.kind == TypeInfo::Kind::Bool);
                            for (std::uint32_t k = 0; k < t.count && (2 + k) < operandCount; ++k) {
                                auto cIt = constants.find(w[2 + k]);
                                if (cIt != constants.end()) {
                                    v.i[k] = isBool
                                        ? (cIt->second.bval ? 1 : 0)
                                        : cIt->second.i[0];
                                }
                            }
                        }
                    }
                }
                constants[w[1]] = v;
                break;
            }
            case spv::OpSpecConstantOp: {
                const std::size_t operandCount = wc > 4 ? static_cast<std::size_t>(wc - 4) : 0;
                constants[w[1]] = evalSpecConstantOp(
                    *this, w[0], w[2], w + 3, operandCount);
                break;
            }
            case spv::OpVariable: {
                VariableInfo vi;
                vi.typeId = w[0];
                vi.storageClass = w[2];
                auto nameIt = names.find(w[1]);
                if (nameIt != names.end()) vi.name = nameIt->second;
                variables[w[1]] = vi;
                break;
            }
            case spv::OpFunction: {
                if (!inFunctionBody) {
                    inFunctionBody = true;
                    currentFuncStart = i + wc;
                    currentFunc = FunctionInfo{};
                    if (wc >= 5) {
                        currentFunc.returnTypeId = w[0];
                        currentFuncId = w[1];
                        currentFunc.functionTypeId = w[3];
                    } else {
                        currentFuncId = 0;
                    }
                }
                break;
            }
            case spv::OpFunctionParameter: {
                if (inFunctionBody && wc >= 3) {
                    currentFunc.parameterTypeIds.push_back(w[0]);
                    currentFunc.parameters.push_back(w[1]);
                }
                break;
            }
            case spv::OpFunctionEnd: {
                if (inFunctionBody) {
                    currentFunc.bodyStart = currentFuncStart;
                    currentFunc.bodyEnd = i;
                    if (currentFuncId != 0) {
                        functions[currentFuncId] = currentFunc;
                    }
                    if (!haveFuncBody) {
                        funcBodyStart = currentFuncStart;
                        funcBodyEnd = i;
                        haveFuncBody = true;
                    }
                }
                inFunctionBody = false;
                currentFuncId = 0;
                currentFunc = FunctionInfo{};
                break;
            }
            default:
                break;
        }
        i += wc;
    }
    if (!haveSelectedEntryPoint && haveFallbackEntryPoint) {
        entryPoint = fallbackEntryPoint;
        entryInterface = std::move(fallbackEntryInterface);
    }
    for (auto& pending : pendingExecutionModes) {
        if (pending.entryPointId == entryPoint) {
            executionModes[pending.mode] = std::move(pending.operands);
        }
    }
    auto entryIt = functions.find(entryPoint);
    if (entryIt != functions.end()) {
        funcBodyStart = entryIt->second.bodyStart;
        funcBodyEnd = entryIt->second.bodyEnd;
        haveFuncBody = true;
    }
    return true;
}

}  // namespace appgl::interp
