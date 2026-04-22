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
        OpTypeArray = 28, OpTypeStruct = 30, OpTypePointer = 32,
        OpTypeFunction = 33,
        OpConstant = 43, OpConstantTrue = 41, OpConstantFalse = 42,
        OpConstantComposite = 44,
        OpFunction = 54, OpFunctionEnd = 56, OpVariable = 59,
    };
    enum Decoration : std::uint32_t {
        DecorationBlock = 2, DecorationBufferBlock = 3,
        DecorationLocation = 30, DecorationBuiltIn = 11,
        DecorationNoPerspective = 13, DecorationFlat = 14,
        DecorationCentroid = 16, DecorationOffset = 35,
        DecorationDescriptorSet = 34, DecorationBinding = 33,
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

bool SpirvModule::parse(const std::uint32_t* data, std::size_t count) {
    if (count < 5 || data[0] != spv::MagicNumber) {
        parseError = "bad SPIR-V magic";
        return false;
    }
    bound = data[3];
    words.assign(data, data + count);

    std::size_t i = 5;
    bool inFunctionBody = false;
    std::size_t currentFuncStart = 0;
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
                    entryPoint = w[1];
                    std::size_t j = i + 3;
                    (void)readLiteralString(data, j, count);
                    while (j < i + wc) entryInterface.push_back(data[j++]);
                }
                break;
            }
            case spv::OpExecutionMode: {
                if (wc >= 3) {
                    const std::uint32_t mode = w[1];
                    std::vector<std::uint32_t> operands;
                    for (std::uint32_t k = 2; k < static_cast<std::uint32_t>(wc - 1); ++k) {
                        operands.push_back(w[k]);
                    }
                    executionModes[mode] = std::move(operands);
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
                } else if (deco == spv::DecorationBlock || deco == spv::DecorationBufferBlock) {
                    decorations[target].isBlock = true;
                } else if (deco == spv::DecorationBinding && wc >= 4) {
                    decorations[target].hasBinding = true;
                    decorations[target].binding = w[2];
                } else if (deco == spv::DecorationDescriptorSet && wc >= 4) {
                    decorations[target].hasDescriptorSet = true;
                    decorations[target].descriptorSet = w[2];
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
                } else if (deco == spv::DecorationOffset && wc >= 5) {
                    memberDecorations[target].perMember[member].hasOffset = true;
                    memberDecorations[target].perMember[member].offset = w[3];
                }
                break;
            }
            case spv::OpTypeVoid:  types[w[0]] = {TypeInfo::Kind::Void};  break;
            case spv::OpTypeBool:  types[w[0]] = {TypeInfo::Kind::Bool};  break;
            case spv::OpTypeInt: {
                TypeInfo t;
                const bool isSigned = (wc >= 4 && w[2] != 0);
                t.kind = isSigned ? TypeInfo::Kind::Int : TypeInfo::Kind::UInt;
                types[w[0]] = t;
                break;
            }
            case spv::OpTypeFloat: types[w[0]] = {TypeInfo::Kind::Float}; break;
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
                auto typeIt = types.find(w[0]);
                Value v;
                if (typeIt != types.end()) {
                    const TypeInfo& t = typeIt->second;
                    if (t.kind == TypeInfo::Kind::Float) {
                        float f = 0;
                        std::memcpy(&f, &w[2], sizeof(float));
                        v = Value::makeFloat(f);
                    } else if (t.kind == TypeInfo::Kind::Int) {
                        v = Value::makeInt(static_cast<std::int32_t>(w[2]));
                    } else if (t.kind == TypeInfo::Kind::UInt) {
                        v = Value::makeUInt(w[2]);
                    }
                }
                constants[w[1]] = v;
                break;
            }
            case spv::OpConstantTrue:  constants[w[1]] = Value::makeBool(true);  break;
            case spv::OpConstantFalse: constants[w[1]] = Value::makeBool(false); break;
            case spv::OpConstantComposite: {
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
                            for (std::uint32_t k = 0; k < t.count && (2 + k) < wc; ++k) {
                                auto cIt = constants.find(w[2 + k]);
                                if (cIt != constants.end()) v.f[k] = cIt->second.f[0];
                            }
                        } else {
                            v.kind = (t.count == 2) ? Value::Kind::Int2 :
                                     (t.count == 3) ? Value::Kind::Int3 : Value::Kind::Int4;
                            for (std::uint32_t k = 0; k < t.count && (2 + k) < wc; ++k) {
                                auto cIt = constants.find(w[2 + k]);
                                if (cIt != constants.end()) v.i[k] = cIt->second.i[0];
                            }
                        }
                    }
                }
                constants[w[1]] = v;
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
                }
                break;
            }
            case spv::OpFunctionEnd: {
                if (inFunctionBody && !haveFuncBody) {
                    funcBodyStart = currentFuncStart;
                    funcBodyEnd = i;
                    haveFuncBody = true;
                }
                inFunctionBody = false;
                break;
            }
            default:
                break;
        }
        i += wc;
    }
    return true;
}

}  // namespace appgl::interp
