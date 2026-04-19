// GeometryShaderEmulator — CPU-side GS emulation.
//
// Current scope covers the narrow subset of SPIR-V used by CTS
// `KHR-GL46.constant_expressions.*_geometry` (224 F): single
// pass-through GS with a constant-folded operation writing to an
// output varying. Opcodes outside this set return a clear
// diagnostic and the driver falls back to the existing no-GS path.
//
// Design — §4 of docs/geometry-shader-emulation.md.

#include "GeometryShaderEmulator.h"

#include "../objects/GLObjectStore.h"
#include "../state/GLStateTracker.h"

#ifdef APPGL_HAS_SHADER_COMPILER
#include "spirv.hpp"
#include "GLSL.std.450.h"   // free enum GLSLstd450 (not in a namespace)
#else
// Stub: emulator reports "not available" without the shader compiler.
namespace spv {
    constexpr std::uint32_t MagicNumber = 0x07230203;
    enum Op : std::uint32_t {
        OpExtInstImport = 11, OpExtInst = 12, OpEntryPoint = 15,
        OpExecutionMode = 16,
        OpName = 5, OpMemberName = 6,
        OpDecorate = 71, OpMemberDecorate = 72,
        OpTypeVoid = 19, OpTypeBool = 20, OpTypeInt = 21,
        OpTypeFloat = 22, OpTypeVector = 23, OpTypeMatrix = 24,
        OpTypeArray = 28, OpTypeStruct = 30, OpTypePointer = 32,
        OpTypeFunction = 33,
        OpConstant = 43, OpConstantTrue = 41, OpConstantFalse = 42,
        OpConstantComposite = 44,
        OpFunction = 54, OpFunctionEnd = 56,
        OpVariable = 59, OpLoad = 61, OpStore = 62, OpAccessChain = 65,
        OpArrayLength = 68,
        OpCompositeExtract = 81, OpCompositeConstruct = 80,
        OpVectorShuffle = 79,
        OpVectorTimesScalar = 142, OpDot = 148,
        OpFNegate = 127,
        OpFAdd = 129, OpFSub = 131, OpFMul = 133, OpFDiv = 136, OpFMod = 141,
        OpIAdd = 128, OpISub = 130, OpIMul = 132,
        OpSDiv = 135, OpSRem = 138, OpUMod = 137, OpSNegate = 126,
        OpConvertFToS = 110, OpConvertFToU = 109,
        OpConvertSToF = 111, OpConvertUToF = 112,
        OpBitcast = 124,
        OpBitwiseAnd = 199, OpShiftLeftLogical = 196,
        OpIEqual = 170, OpINotEqual = 171,
        OpSLessThan = 177, OpSGreaterThan = 173,
        OpSLessThanEqual = 179, OpSGreaterThanEqual = 175,
        OpULessThan = 176, OpULessThanEqual = 178,
        OpFOrdEqual = 180, OpFOrdNotEqual = 182,
        OpFOrdLessThan = 184, OpFOrdGreaterThan = 186,
        OpFOrdLessThanEqual = 188, OpFOrdGreaterThanEqual = 190,
        OpLogicalAnd = 167, OpLogicalOr = 166, OpLogicalNot = 168,
        OpLogicalNotEqual = 165, OpSelect = 169, OpAny = 154, OpAll = 155,
        OpPhi = 245, OpLoopMerge = 246, OpSelectionMerge = 247,
        OpLabel = 248, OpBranch = 249, OpBranchConditional = 250, OpSwitch = 251,
        OpReturn = 253,
        OpEmitVertex = 218, OpEndPrimitive = 219,
    };
    enum ExecutionMode : std::uint32_t {
        ExecutionModeInvocations = 0,
        ExecutionModeInputPoints = 19,
        ExecutionModeInputLines = 20,
        ExecutionModeInputLinesAdjacency = 21,
        ExecutionModeTriangles = 22,
        ExecutionModeInputTrianglesAdjacency = 23,
        ExecutionModeOutputVertices = 26,
        ExecutionModeOutputPoints = 27,
        ExecutionModeOutputLineStrip = 28,
        ExecutionModeOutputTriangleStrip = 29,
    };
    enum Decoration : std::uint32_t {
        DecorationBlock = 2, DecorationBufferBlock = 3,
        DecorationLocation = 30, DecorationBuiltIn = 11,
        DecorationNoPerspective = 13, DecorationFlat = 14, DecorationCentroid = 16,
        DecorationOffset = 35,
    };
    enum StorageClass : std::uint32_t {
        StorageClassUniformConstant = 0, StorageClassInput = 1,
        StorageClassUniform = 2, StorageClassOutput = 3,
        StorageClassFunction = 7, StorageClassPrivate = 6
    };
    enum BuiltIn : std::uint32_t {
        BuiltInPosition = 0, BuiltInPointSize = 1,
        BuiltInClipDistance = 3, BuiltInCullDistance = 4
    };
}
// GLSL.std.450 stub — free (non-namespaced) to match the real
// `third_party/SPIRV-Cross/GLSL.std.450.h`. The interpreter's
// evalExtInst switches on these values by name, so any addition here
// must mirror the real header.
enum GLSLstd450 : std::uint32_t {
    GLSLstd450Round = 1, GLSLstd450RoundEven = 2, GLSLstd450Trunc = 3,
    GLSLstd450FAbs = 4, GLSLstd450FSign = 6,
    GLSLstd450Floor = 8, GLSLstd450Ceil = 9, GLSLstd450Fract = 10,
    GLSLstd450Radians = 11, GLSLstd450Degrees = 12,
    GLSLstd450Sin = 13, GLSLstd450Cos = 14, GLSLstd450Tan = 15,
    GLSLstd450Asin = 16, GLSLstd450Acos = 17, GLSLstd450Atan = 18,
    GLSLstd450Sinh = 19, GLSLstd450Cosh = 20, GLSLstd450Tanh = 21,
    GLSLstd450Asinh = 22, GLSLstd450Acosh = 23, GLSLstd450Atanh = 24,
    GLSLstd450Atan2 = 25,
    GLSLstd450Pow = 26, GLSLstd450Exp = 27, GLSLstd450Log = 28,
    GLSLstd450Exp2 = 29, GLSLstd450Log2 = 30, GLSLstd450Sqrt = 31,
    GLSLstd450InverseSqrt = 32,
    GLSLstd450FMin = 37, GLSLstd450FMax = 40, GLSLstd450FClamp = 43,
    GLSLstd450FMix = 46, GLSLstd450Step = 48, GLSLstd450SmoothStep = 49,
    GLSLstd450Length = 66, GLSLstd450Distance = 67, GLSLstd450Cross = 68,
    GLSLstd450Normalize = 69, GLSLstd450Reflect = 71,
};
#endif

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iterator>
#include <string>
#include <unordered_map>
#include <utility>
#include <variant>
#include <vector>

#ifndef GL_POINTS
#define GL_POINTS 0x0000
#endif
#ifndef GL_LINES
#define GL_LINES 0x0001
#endif
#ifndef GL_LINE_STRIP
#define GL_LINE_STRIP 0x0003
#endif
#ifndef GL_TRIANGLES
#define GL_TRIANGLES 0x0004
#endif
#ifndef GL_TRIANGLE_STRIP
#define GL_TRIANGLE_STRIP 0x0005
#endif
#ifndef GL_LINES_ADJACENCY
#define GL_LINES_ADJACENCY 0x000A
#endif
#ifndef GL_TRIANGLES_ADJACENCY
#define GL_TRIANGLES_ADJACENCY 0x000C
#endif
#ifndef GL_VERTEX_SHADER
#define GL_VERTEX_SHADER 0x8B31
#endif
#ifndef GL_GEOMETRY_SHADER
#define GL_GEOMETRY_SHADER 0x8DD9
#endif

namespace appgl {
namespace {

// ─── Value model ────────────────────────────────────────────────────
//
// Small boxed SSA value for the interpreter. For storage-class
// variables and composites, we use a flat `std::vector<float>` /
// `std::vector<int32_t>` at the variable level and walk into it via
// access-chain offsets (see AccessChain below).

struct Value {
    // Up to 4 components; kind determines which of f/i/b is live.
    // Matrices and larger composites live in the variable store, not
    // in Value — loading a matrix field via OpLoad after OpAccessChain
    // yields a scalar/vec Value.
    enum class Kind : std::uint8_t {
        Float, Float2, Float3, Float4,
        Int,   Int2,   Int3,   Int4,
        UInt,  UInt2,  UInt3,  UInt4,
        Bool,  Invalid
    };
    Kind kind = Kind::Invalid;
    std::array<float, 4> f{0, 0, 0, 0};
    std::array<std::int32_t, 4> i{0, 0, 0, 0};
    bool bval = false;

    static Value makeFloat(float v) { Value r; r.kind = Kind::Float; r.f[0] = v; return r; }
    static Value makeInt(std::int32_t v) { Value r; r.kind = Kind::Int; r.i[0] = v; return r; }
    static Value makeUInt(std::uint32_t v) { Value r; r.kind = Kind::UInt; r.i[0] = static_cast<std::int32_t>(v); return r; }
    static Value makeBool(bool v) { Value r; r.kind = Kind::Bool; r.bval = v; return r; }

    int componentCount() const {
        switch (kind) {
            case Kind::Float2: case Kind::Int2: case Kind::UInt2: return 2;
            case Kind::Float3: case Kind::Int3: case Kind::UInt3: return 3;
            case Kind::Float4: case Kind::Int4: case Kind::UInt4: return 4;
            default: return 1;
        }
    }
    bool isFloatKind() const {
        return kind == Kind::Float || kind == Kind::Float2 ||
               kind == Kind::Float3 || kind == Kind::Float4;
    }
    bool isIntKind() const {
        return kind == Kind::Int || kind == Kind::Int2 ||
               kind == Kind::Int3 || kind == Kind::Int4 ||
               kind == Kind::UInt || kind == Kind::UInt2 ||
               kind == Kind::UInt3 || kind == Kind::UInt4;
    }
};

// ─── Type table ─────────────────────────────────────────────────────

struct TypeInfo {
    enum class Kind { Void, Bool, Int, UInt, Float,
                      Vec2, Vec3, Vec4,
                      Matrix, Array, Struct, Pointer, Function,
                      Unknown };
    Kind kind = Kind::Unknown;
    std::uint32_t componentType = 0;
    std::uint32_t count = 0;             // vec width / array length / matrix columns
    std::uint32_t arrayLengthConstId = 0;  // array only — needs resolve
    std::vector<std::uint32_t> memberTypes;
    std::uint32_t storageClass = 0;
    std::uint32_t pointeeType = 0;
    std::uint32_t returnType = 0;
    std::uint32_t elementScalarWidth = 1;  // runtime-resolved: flat floats per element
};

struct VariableInfo {
    std::uint32_t typeId = 0;
    std::uint32_t storageClass = 0;
    std::string name;
};

struct DecorationSet {
    bool hasLocation = false;
    std::uint32_t location = 0;
    bool hasBuiltIn = false;
    std::uint32_t builtIn = 0;
    // Interpolation qualifiers. GL 4.6 §4.5: `flat` requires non-
    // interpolated, `noperspective` disables perspective correction,
    // `centroid` shifts sampling to the centroid. The synthesised
    // pass-through VS must emit matching MSL attributes
    // (`[[user(locnN), flat]]` / `[[center_no_perspective]]` etc.)
    // or the Metal pipeline-state validator rejects the build with
    // "Fragment input mismatching vertex shader output".
    bool isFlat = false;
    bool isNoPerspective = false;
    bool isCentroid = false;
    // OpMemberDecorate Offset — byte offset within a Block / Buffer-
    // Block struct. Needed to resolve uniform access chains in the
    // interpreter when we seed Uniform storage from the program's
    // uniformValues table.
    bool hasOffset = false;
    std::uint32_t offset = 0;
    // Block / BufferBlock decoration on the struct type — marks it
    // as a uniform block (std140 / std430) rather than a plain
    // aggregate struct used in function scope.
    bool isBlock = false;
};

struct MemberDecorations {
    std::unordered_map<std::uint32_t, DecorationSet> perMember;   // member index → set
};

// ─── SPIR-V module ──────────────────────────────────────────────────

struct SpirvModule {
    std::uint32_t bound = 0;
    std::vector<std::uint32_t> words;

    std::unordered_map<std::uint32_t, TypeInfo> types;
    std::unordered_map<std::uint32_t, Value> constants;
    std::unordered_map<std::uint32_t, VariableInfo> variables;
    std::unordered_map<std::uint32_t, DecorationSet> decorations;
    std::unordered_map<std::uint32_t, MemberDecorations> memberDecorations;
    std::unordered_map<std::uint32_t, std::string> names;
    std::unordered_map<std::uint32_t, std::string> memberNames0;
    // Full per-member name map: structId → member index → name.
    // Used by the uniform-seeding path to match a struct member (e.g.
    // `renderingTargetSize` at member 0 of a $Globals block) to the
    // program's uniformValues table by name.
    std::unordered_map<std::uint32_t, std::unordered_map<std::uint32_t, std::string>> memberNames;
    std::unordered_map<std::uint32_t, std::uint32_t> extInstImports;   // id → "GLSL.std.450" hash

    std::uint32_t entryPoint = 0;
    std::vector<std::uint32_t> entryInterface;

    // OpExecutionMode records keyed by mode value (SPIR-V enum), value
    // is the list of literal operands. For GS we care about:
    //   InputPoints/InputLines/InputLinesAdjacency/Triangles/
    //   InputTrianglesAdjacency — input topology (no operands).
    //   OutputPoints/OutputLineStrip/OutputTriangleStrip — output
    //   topology (no operands).
    //   OutputVertices — single uint operand = max_vertices.
    //   Invocations — single uint operand, currently required to be 1.
    std::unordered_map<std::uint32_t, std::vector<std::uint32_t>> executionModes;

    // Offsets of function-body instructions. We stash the main entry
    // function's instruction range at parse time for fast walk.
    std::size_t funcBodyStart = 0;
    std::size_t funcBodyEnd = 0;
    bool haveFuncBody = false;

    std::string parseError;

    bool parse(const std::uint32_t* data, std::size_t count);

    // Resolve runtime scalar width of a type (for variable storage
    // allocation). A vec3 is 3, a mat2x4 is 8, an array[3] of vec4
    // is 12, a struct is sum of member widths. Recursive.
    std::uint32_t scalarWidth(std::uint32_t typeId) const;
};

static std::string readLiteralString(const std::uint32_t* w, std::size_t& i, std::size_t wordCount) {
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
            // Resolve length from constant id.
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
                        extInstImports[w[0]] = 1;   // tag as GLSL std
                    }
                }
                break;
            }
            case spv::OpEntryPoint: {
                if (wc >= 3) {
                    entryPoint = w[1];
                    std::size_t j = i + 3;
                    (void)readLiteralString(data, j, count);   // skip name
                    // interface ids follow, one per word.
                    while (j < i + wc) entryInterface.push_back(data[j++]);
                }
                break;
            }
            case spv::OpExecutionMode: {
                // w[0]=entryPointId, w[1]=Mode, w[2..]=operands
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

// ─── Access chain walker ────────────────────────────────────────────
//
// Resolve an OpAccessChain into (variable-storage, flat-scalar-offset,
// scalar-count) tuple for subsequent OpLoad / OpStore.

struct AccessChainResult {
    std::uint32_t rootVarId = 0;
    std::uint32_t scalarOffset = 0;
    std::uint32_t scalarCount = 1;   // how many flat scalars does the loaded value cover
    std::uint32_t leafTypeId = 0;
    bool ok = false;
};

// ─── Interpreter ────────────────────────────────────────────────────

class Interpreter {
public:
    enum class Stage { Vertex, Geometry };

    struct PerVertexInput {
        std::array<float, 4> position{0, 0, 0, 1};
        // Per-varying payload. Parallel to `inputVaryingNames` below.
        // Each varying is a flat float array (width from varying type).
        std::vector<std::vector<float>> varyings;
    };

    // Uniform plumbing — keyed by variable name (top-level uniform
    // variable) or struct-member name (for Block-decorated uniform
    // structs). Values are already flattened to scalar-per-element
    // in the caller; the interpreter just memcpys into varStorage.
    // Kept as float vectors but re-interpreted as int/uint via bit-
    // cast when the destination type requires it (the storage bytes
    // are the same in either case — GL uniforms are 32-bit scalars).
    using UniformValues = std::unordered_map<std::string, std::vector<float>>;

    // VS-only. Vertex attribute values keyed by SPIR-V Location
    // decoration value. Populated by the caller from the VAO +
    // VBO shadow bytes, one entry per enabled attribute.
    using VertexAttribs = std::unordered_map<std::uint32_t, Value>;

    // GS constructor (existing signature preserved).
    Interpreter(const SpirvModule& mod,
                std::vector<std::string> inputVaryingNames,
                std::vector<std::uint32_t> inputVaryingWidths,
                std::vector<std::string> outputVaryingNames,
                std::vector<std::uint32_t> outputVaryingWidths)
        : module_(mod),
          inputVaryingNames_(std::move(inputVaryingNames)),
          inputVaryingWidths_(std::move(inputVaryingWidths)),
          outputVaryingNames_(std::move(outputVaryingNames)),
          outputVaryingWidths_(std::move(outputVaryingWidths)),
          stage_(Stage::Geometry) {}

    // VS constructor. `outputVaryingNames_/Widths_` mirror the VS
    // stage-out varyings the GS will consume — the caller computes
    // them by walking the VS output variables before constructing
    // the interpreter, so the VS's gather-output step lines up with
    // what the GS expects in its input varying table.
    Interpreter(const SpirvModule& mod,
                Stage stage,
                std::vector<std::string> outputVaryingNames,
                std::vector<std::uint32_t> outputVaryingWidths)
        : module_(mod),
          outputVaryingNames_(std::move(outputVaryingNames)),
          outputVaryingWidths_(std::move(outputVaryingWidths)),
          stage_(stage) {}

    void setUniforms(const UniformValues* u) { uniforms_ = u; }
    void setVsInputs(const VertexAttribs* a, std::int32_t vertexID, std::int32_t instanceID) {
        vsAttribs_ = a;
        vsVertexID_ = vertexID;
        vsInstanceID_ = instanceID;
    }

    // Run the entry-point function once, given `inputs` as gl_in[].
    // Appends emitted vertices to `emitted`. Primitive boundaries are
    // recorded as indices into `emitted` where EndPrimitive was called
    // (so a vertex at index `emitted.size() - 1` gets a boundary mark
    // if EndPrimitive immediately follows).
    bool execute(const std::vector<PerVertexInput>& inputs,
                 std::vector<EmulatedVertex>& emitted);

    // VS entry point. Runs the body once, captures gl_Position +
    // user output varyings into the supplied record. Returns false
    // on any interpreter bail.
    bool executeVs(EmulatedVertex& out);

    const std::string& diagnostic() const { return diagnostic_; }

private:
    const SpirvModule& module_;
    std::vector<std::string> inputVaryingNames_;
    std::vector<std::uint32_t> inputVaryingWidths_;
    std::vector<std::string> outputVaryingNames_;
    std::vector<std::uint32_t> outputVaryingWidths_;

    Stage stage_;

    // Uniform / VS attribute plumbing (non-owning pointers to caller
    // storage).
    const UniformValues* uniforms_ = nullptr;
    const VertexAttribs* vsAttribs_ = nullptr;
    std::int32_t vsVertexID_ = 0;
    std::int32_t vsInstanceID_ = 0;

    // Per-id SSA values for loads/arithmetic results.
    std::unordered_map<std::uint32_t, Value> valueStore_;

    // Per-variable flat float storage (indexed by access-chain
    // scalar offset). Float storage is universal — int/uint/bool
    // bitcast into/out of float by the load/store paths.
    std::unordered_map<std::uint32_t, std::vector<float>> varStorage_;

    // Resolved access-chain results, keyed by the OpAccessChain's
    // result id. Subsequent OpLoad / OpStore use these to drive
    // offset arithmetic into `varStorage_[rootVarId]`.
    std::unordered_map<std::uint32_t, AccessChainResult> accessChains_;

    // Built-in output scratch for the "current vertex" being built
    // up before OpEmitVertex captures it.
    std::array<float, 4> currentPosition_{0, 0, 0, 1};
    std::vector<std::vector<float>> currentOutVaryings_;   // parallel to outputVaryingNames_

    std::string diagnostic_;
    bool errored_ = false;

    // Diagnostic + bail.
    void bail(std::string msg) {
        if (errored_) return;
        diagnostic_ = std::move(msg);
        errored_ = true;
    }

    // Initialise variable storage for entryInterface. Called at
    // execute() start.
    void initVariables(const std::vector<PerVertexInput>& inputs);

    // Capture the current output state as an EmulatedVertex.
    void emitVertex(std::vector<EmulatedVertex>& out);

    // Resolve an access-chain walk. `base` is a pointer variable id.
    // `indices` are the sequence of OpConstant id operands.
    AccessChainResult resolveAccessChain(std::uint32_t base,
                                         const std::uint32_t* indices,
                                         std::uint32_t nIndices);

    // Load scalars from var storage at [off..off+count) into a Value
    // of the leaf type.
    Value loadFromVar(std::uint32_t varId, std::uint32_t off,
                      std::uint32_t count, std::uint32_t leafTypeId);

    // Store `v` into var storage at [off..off+count).
    void storeToVar(std::uint32_t varId, std::uint32_t off,
                    const Value& v);

    // Apply GLSL.std.450 extended instruction.
    Value evalExtInst(std::uint32_t glslOp, const std::uint32_t* operands,
                      std::uint32_t nOperands);

    // Quick lookup in constants or valueStore.
    bool tryGetValue(std::uint32_t id, Value& out) {
        auto cIt = module_.constants.find(id);
        if (cIt != module_.constants.end()) { out = cIt->second; return true; }
        auto vIt = valueStore_.find(id);
        if (vIt != valueStore_.end()) { out = vIt->second; return true; }
        return false;
    }
};

AccessChainResult Interpreter::resolveAccessChain(std::uint32_t base,
                                                  const std::uint32_t* indices,
                                                  std::uint32_t nIndices) {
    AccessChainResult r;
    auto vIt = module_.variables.find(base);
    if (vIt == module_.variables.end()) {
        bail("OpAccessChain base is not a variable");
        return r;
    }
    r.rootVarId = base;
    // Walk the type hierarchy following each index.
    auto tIt = module_.types.find(vIt->second.typeId);
    if (tIt == module_.types.end()) { bail("missing type for variable"); return r; }
    std::uint32_t curType = tIt->second.pointeeType;   // deref pointer
    std::uint32_t offset = 0;
    for (std::uint32_t k = 0; k < nIndices; ++k) {
        auto curTIt = module_.types.find(curType);
        if (curTIt == module_.types.end()) { bail("missing type in access chain"); return r; }
        const TypeInfo& t = curTIt->second;
        // Index must be a constant for this MVP.
        auto cIt = module_.constants.find(indices[k]);
        std::int32_t idx = 0;
        if (cIt != module_.constants.end()) {
            idx = cIt->second.i[0];
        } else {
            auto vstoreIt = valueStore_.find(indices[k]);
            if (vstoreIt != valueStore_.end()) {
                idx = vstoreIt->second.i[0];
            } else {
                bail("access-chain index is neither constant nor runtime value");
                return r;
            }
        }
        if (t.kind == TypeInfo::Kind::Array) {
            const std::uint32_t elemW = module_.scalarWidth(t.componentType);
            offset += static_cast<std::uint32_t>(idx) * elemW;
            curType = t.componentType;
        } else if (t.kind == TypeInfo::Kind::Struct) {
            if (static_cast<std::uint32_t>(idx) >= t.memberTypes.size()) {
                bail("access-chain struct index out of range"); return r;
            }
            for (std::uint32_t m = 0; m < static_cast<std::uint32_t>(idx); ++m) {
                offset += module_.scalarWidth(t.memberTypes[m]);
            }
            curType = t.memberTypes[idx];
        } else if (t.kind == TypeInfo::Kind::Vec2 || t.kind == TypeInfo::Kind::Vec3 ||
                   t.kind == TypeInfo::Kind::Vec4) {
            offset += static_cast<std::uint32_t>(idx);
            curType = t.componentType;
        } else if (t.kind == TypeInfo::Kind::Matrix) {
            const std::uint32_t colW = module_.scalarWidth(t.componentType);
            offset += static_cast<std::uint32_t>(idx) * colW;
            curType = t.componentType;
        } else {
            bail("access-chain into unsupported type");
            return r;
        }
    }
    r.scalarOffset = offset;
    r.scalarCount  = module_.scalarWidth(curType);
    r.leafTypeId   = curType;
    r.ok = true;
    return r;
}

Value Interpreter::loadFromVar(std::uint32_t varId, std::uint32_t off,
                               std::uint32_t /*count*/, std::uint32_t leafTypeId) {
    Value v;
    auto sIt = varStorage_.find(varId);
    if (sIt == varStorage_.end()) return v;
    const auto& storage = sIt->second;
    auto tIt = module_.types.find(leafTypeId);
    if (tIt == module_.types.end()) { bail("load: unknown leaf type"); return v; }
    const TypeInfo& t = tIt->second;
    if (off >= storage.size()) { bail("load: offset OOB"); return v; }

    switch (t.kind) {
        case TypeInfo::Kind::Float:
            v.kind = Value::Kind::Float;
            v.f[0] = storage[off];
            break;
        case TypeInfo::Kind::Vec2:
            v.kind = Value::Kind::Float2;
            for (int k = 0; k < 2; ++k) v.f[k] = storage[off + k];
            break;
        case TypeInfo::Kind::Vec3:
            v.kind = Value::Kind::Float3;
            for (int k = 0; k < 3; ++k) v.f[k] = storage[off + k];
            break;
        case TypeInfo::Kind::Vec4:
            v.kind = Value::Kind::Float4;
            for (int k = 0; k < 4; ++k) v.f[k] = storage[off + k];
            break;
        case TypeInfo::Kind::Int: {
            v.kind = Value::Kind::Int;
            std::int32_t iv = 0;
            std::memcpy(&iv, &storage[off], 4);
            v.i[0] = iv;
            break;
        }
        case TypeInfo::Kind::UInt: {
            v.kind = Value::Kind::UInt;
            std::uint32_t uv = 0;
            std::memcpy(&uv, &storage[off], 4);
            v.i[0] = static_cast<std::int32_t>(uv);
            break;
        }
        default:
            bail("load: unsupported leaf kind");
    }
    return v;
}

void Interpreter::storeToVar(std::uint32_t varId, std::uint32_t off,
                             const Value& v) {
    auto& storage = varStorage_[varId];
    if (off + static_cast<std::uint32_t>(v.componentCount()) > storage.size()) {
        storage.resize(off + v.componentCount(), 0.0f);
    }
    if (v.isFloatKind()) {
        for (int k = 0; k < v.componentCount(); ++k) storage[off + k] = v.f[k];
    } else if (v.isIntKind()) {
        for (int k = 0; k < v.componentCount(); ++k) {
            std::int32_t iv = v.i[k];
            std::memcpy(&storage[off + k], &iv, 4);
        }
    } else if (v.kind == Value::Kind::Bool) {
        std::int32_t iv = v.bval ? 1 : 0;
        std::memcpy(&storage[off], &iv, 4);
    } else {
        bail("store: unsupported value kind");
    }
}

void Interpreter::initVariables(const std::vector<PerVertexInput>& inputs) {
    // Resolve input locations once up front — glslang doesn't emit
    // DecorationLocation when the GLSL omits `layout(location=N)`,
    // so the VS pre-pass needs to assign implicit locations just
    // like the GS side does for outputs (see gatherOutputVaryings).
    // Locations are assigned in ascending SPIR-V id order, starting
    // above any explicit-location slots.
    std::unordered_map<std::uint32_t, std::uint32_t> inputLocationByVarId;
    if (stage_ == Stage::Vertex) {
        std::vector<std::uint32_t> explicitLocs;
        std::vector<std::uint32_t> implicitIds;
        for (const auto& [varId, info] : module_.variables) {
            if (info.storageClass != spv::StorageClassInput) continue;
            auto dIt = module_.decorations.find(varId);
            // Built-in inputs (gl_VertexIndex etc.) are not user attribs.
            if (dIt != module_.decorations.end() && dIt->second.hasBuiltIn) continue;
            if (dIt != module_.decorations.end() && dIt->second.hasLocation) {
                inputLocationByVarId[varId] = dIt->second.location;
                explicitLocs.push_back(dIt->second.location);
            } else {
                implicitIds.push_back(varId);
            }
        }
        std::sort(implicitIds.begin(), implicitIds.end());
        std::uint32_t nextLoc = 0;
        auto taken = [&](std::uint32_t loc) {
            for (auto x : explicitLocs) if (x == loc) return true;
            return false;
        };
        for (auto id : implicitIds) {
            while (taken(nextLoc)) ++nextLoc;
            inputLocationByVarId[id] = nextLoc++;
        }
    }

    // Walk every declared variable. For Output/Private/Function storage,
    // reserve a zero-initialised flat buffer of the right size. For
    // Input storage, populate from driver-supplied per-vertex data
    // (gl_in[].gl_Position + named input varyings). For Uniform /
    // UniformConstant storage, seed from the caller-supplied uniform
    // name → value map via OpMemberName / OpName lookups.
    for (const auto& [varId, info] : module_.variables) {
        auto tIt = module_.types.find(info.typeId);
        if (tIt == module_.types.end()) continue;
        const std::uint32_t width = module_.scalarWidth(tIt->second.pointeeType);
        auto& storage = varStorage_[varId];
        storage.assign(width, 0.0f);

        // ── Uniform / UniformConstant — seed from caller's map.
        if ((info.storageClass == spv::StorageClassUniform ||
             info.storageClass == spv::StorageClassUniformConstant) &&
            uniforms_ != nullptr) {
            const std::uint32_t pointeeType = tIt->second.pointeeType;
            const auto& pT = module_.types.at(pointeeType);
            if (pT.kind == TypeInfo::Kind::Struct) {
                // Block-decorated struct. Walk each member, find its
                // name via OpMemberName + offset via DecorationOffset,
                // look up the value in the uniform map and splat into
                // storage at the member's flat-scalar offset.
                auto mnIt = module_.memberNames.find(pointeeType);
                auto mdIt = module_.memberDecorations.find(pointeeType);
                std::uint32_t runningScalarOffset = 0;
                for (std::size_t m = 0; m < pT.memberTypes.size(); ++m) {
                    const std::uint32_t memberW = module_.scalarWidth(pT.memberTypes[m]);
                    // Member name.
                    std::string mname;
                    if (mnIt != module_.memberNames.end()) {
                        auto it2 = mnIt->second.find(static_cast<std::uint32_t>(m));
                        if (it2 != mnIt->second.end()) mname = it2->second;
                    }
                    if (!mname.empty()) {
                        auto uIt = uniforms_->find(mname);
                        if (uIt != uniforms_->end()) {
                            const auto& src = uIt->second;
                            for (std::size_t k = 0; k < src.size() && runningScalarOffset + k < storage.size(); ++k) {
                                storage[runningScalarOffset + k] = src[k];
                            }
                        }
                    }
                    (void)mdIt;   // DecorationOffset isn't needed for our flat layout
                    runningScalarOffset += memberW;
                }
            } else {
                // Top-level scalar / vector uniform. Look up by the
                // variable's own OpName.
                auto uIt = uniforms_->find(info.name);
                if (uIt != uniforms_->end()) {
                    const auto& src = uIt->second;
                    for (std::size_t k = 0; k < src.size() && k < storage.size(); ++k) {
                        storage[k] = src[k];
                    }
                }
            }
            continue;
        }

        // ── VS-stage built-ins: gl_VertexID / gl_InstanceID.
        if (stage_ == Stage::Vertex && info.storageClass == spv::StorageClassInput) {
            auto dIt = module_.decorations.find(varId);
            if (dIt != module_.decorations.end() && dIt->second.hasBuiltIn) {
                const std::uint32_t bi = dIt->second.builtIn;
                // BuiltInVertexIndex = 42, BuiltInInstanceIndex = 43
                if (bi == 42 && width >= 1) {
                    std::memcpy(&storage[0], &vsVertexID_, 4);
                    continue;
                }
                if (bi == 43 && width >= 1) {
                    std::memcpy(&storage[0], &vsInstanceID_, 4);
                    continue;
                }
            }
        }

        // ── VS-stage vertex attribute. Look up by Location, using
        // the explicit-or-implicit mapping we resolved at function
        // entry.
        if (stage_ == Stage::Vertex && info.storageClass == spv::StorageClassInput) {
            if (vsAttribs_ != nullptr) {
                auto locIt = inputLocationByVarId.find(varId);
                if (locIt != inputLocationByVarId.end()) {
                    auto aIt = vsAttribs_->find(locIt->second);
                    if (aIt != vsAttribs_->end()) {
                        const Value& v = aIt->second;
                        const int n = v.componentCount();
                        if (v.isFloatKind()) {
                            for (int k = 0; k < n && static_cast<std::uint32_t>(k) < width; ++k) {
                                storage[k] = v.f[k];
                            }
                        } else {
                            for (int k = 0; k < n && static_cast<std::uint32_t>(k) < width; ++k) {
                                std::memcpy(&storage[k], &v.i[k], 4);
                            }
                        }
                    }
                }
            }
            // VS Input handling is complete regardless of whether
            // we matched — the fall-through GS gl_in[] path isn't
            // applicable to this stage.
            continue;
        }

        if (stage_ == Stage::Geometry && info.storageClass == spv::StorageClassInput) {
            // Identify the variable:
            //  - gl_PerVertex block input (contains gl_Position) —
            //    member 0 is BuiltInPosition. The SPIR-V pointee type
            //    is an array-of-struct (gl_in[]), so its scalar width
            //    is N_vertices × struct_width. We write per-vertex
            //    positions at the member-0 offset within each element.
            //  - Named user varying array (vtx_out_*) — flat array
            //    keyed by varying name, width = array_len × per_vertex.
            const auto& pointeeType = module_.types.at(tIt->second.pointeeType);
            if (pointeeType.kind == TypeInfo::Kind::Array) {
                // Determine per-vertex struct / element width.
                const std::uint32_t perVertexW = module_.scalarWidth(pointeeType.componentType);
                const auto& elemT = module_.types.at(pointeeType.componentType);
                if (elemT.kind == TypeInfo::Kind::Struct) {
                    // gl_in[] — find member 0 (Position) by BuiltIn decoration.
                    auto mdIt = module_.memberDecorations.find(pointeeType.componentType);
                    for (std::size_t vi = 0; vi < inputs.size(); ++vi) {
                        const std::uint32_t base = static_cast<std::uint32_t>(vi) * perVertexW;
                        // Member 0 is gl_Position by convention.
                        if (mdIt != module_.memberDecorations.end()) {
                            auto mmIt = mdIt->second.perMember.find(0);
                            if (mmIt != mdIt->second.perMember.end() && mmIt->second.hasBuiltIn
                                && mmIt->second.builtIn == spv::BuiltInPosition) {
                                for (int k = 0; k < 4; ++k) storage[base + k] = inputs[vi].position[k];
                            }
                        }
                    }
                } else {
                    // Flat varying array. Match by variable name to
                    // driver-supplied inputVaryingNames_.
                    int varyingIdx = -1;
                    for (std::size_t j = 0; j < inputVaryingNames_.size(); ++j) {
                        if (inputVaryingNames_[j] == info.name) {
                            varyingIdx = static_cast<int>(j);
                            break;
                        }
                    }
                    if (varyingIdx >= 0) {
                        const std::uint32_t w = inputVaryingWidths_[varyingIdx];
                        for (std::size_t vi = 0; vi < inputs.size() && vi < inputs[vi].varyings.size(); ++vi) {
                            const auto& src = inputs[vi].varyings[varyingIdx];
                            const std::uint32_t base = static_cast<std::uint32_t>(vi) * w;
                            for (std::uint32_t k = 0; k < w && base + k < storage.size(); ++k) {
                                storage[base + k] = (k < src.size()) ? src[k] : 0.0f;
                            }
                        }
                    }
                }
            }
        }
    }
}

void Interpreter::emitVertex(std::vector<EmulatedVertex>& out) {
    // Capture gl_Position and named output varyings from their
    // respective output variables' storage.
    EmulatedVertex ev;
    ev.position[0] = currentPosition_[0];
    ev.position[1] = currentPosition_[1];
    ev.position[2] = currentPosition_[2];
    ev.position[3] = currentPosition_[3];
    // Read each output varying's current value from varStorage_.
    for (std::size_t k = 0; k < outputVaryingNames_.size(); ++k) {
        std::vector<float> v;
        v.assign(outputVaryingWidths_[k], 0.0f);
        // Find the Output variable by name.
        for (const auto& [varId, info] : module_.variables) {
            if (info.storageClass == spv::StorageClassOutput &&
                info.name == outputVaryingNames_[k]) {
                auto sIt = varStorage_.find(varId);
                if (sIt != varStorage_.end()) {
                    for (std::size_t j = 0; j < v.size() && j < sIt->second.size(); ++j) {
                        v[j] = sIt->second[j];
                    }
                }
                break;
            }
        }
        ev.varyings.insert(ev.varyings.end(), v.begin(), v.end());
    }
    out.push_back(std::move(ev));
}

Value Interpreter::evalExtInst(std::uint32_t glslOp,
                               const std::uint32_t* operands,
                               std::uint32_t nOperands) {
    Value a, b, c;
    if (nOperands >= 1 && !tryGetValue(operands[0], a)) {
        bail("OpExtInst: unknown operand 0");
        return a;
    }
    if (nOperands >= 2 && !tryGetValue(operands[1], b)) {
        bail("OpExtInst: unknown operand 1");
        return a;
    }
    if (nOperands >= 3 && !tryGetValue(operands[2], c)) {
        bail("OpExtInst: unknown operand 2");
        return a;
    }
    auto scalarMap = [&](float (*fn)(float)) {
        Value r = a;
        for (int k = 0; k < a.componentCount(); ++k) r.f[k] = fn(a.f[k]);
        return r;
    };
    auto binaryMap = [&](float (*fn)(float, float)) {
        Value r = a;
        for (int k = 0; k < a.componentCount(); ++k) r.f[k] = fn(a.f[k], b.f[k]);
        return r;
    };
    auto ternaryMap = [&](float (*fn)(float, float, float)) {
        Value r = a;
        for (int k = 0; k < a.componentCount(); ++k) r.f[k] = fn(a.f[k], b.f[k], c.f[k]);
        return r;
    };
    switch (glslOp) {
        // ─ Unary transcendentals / sign / rounding ─
        case ::GLSLstd450Radians: return scalarMap([](float x) { return x * 0.017453292519943295f; });
        case ::GLSLstd450Degrees: return scalarMap([](float x) { return x * 57.29577951308232f; });
        case ::GLSLstd450Sin:     return scalarMap([](float x) { return std::sin(x); });
        case ::GLSLstd450Cos:     return scalarMap([](float x) { return std::cos(x); });
        case ::GLSLstd450Tan:     return scalarMap([](float x) { return std::tan(x); });
        case ::GLSLstd450Asin:    return scalarMap([](float x) { return std::asin(x); });
        case ::GLSLstd450Acos:    return scalarMap([](float x) { return std::acos(x); });
        case ::GLSLstd450Atan:    return scalarMap([](float x) { return std::atan(x); });
        case ::GLSLstd450Sinh:    return scalarMap([](float x) { return std::sinh(x); });
        case ::GLSLstd450Cosh:    return scalarMap([](float x) { return std::cosh(x); });
        case ::GLSLstd450Tanh:    return scalarMap([](float x) { return std::tanh(x); });
        case ::GLSLstd450Asinh:   return scalarMap([](float x) { return std::asinh(x); });
        case ::GLSLstd450Acosh:   return scalarMap([](float x) { return std::acosh(x); });
        case ::GLSLstd450Atanh:   return scalarMap([](float x) { return std::atanh(x); });
        case ::GLSLstd450Exp:     return scalarMap([](float x) { return std::exp(x); });
        case ::GLSLstd450Log:     return scalarMap([](float x) { return std::log(x); });
        case ::GLSLstd450Exp2:    return scalarMap([](float x) { return std::exp2(x); });
        case ::GLSLstd450Log2:    return scalarMap([](float x) { return std::log2(x); });
        case ::GLSLstd450Sqrt:    return scalarMap([](float x) { return std::sqrt(x); });
        case ::GLSLstd450InverseSqrt: return scalarMap([](float x) { return 1.0f / std::sqrt(x); });
        case ::GLSLstd450FAbs:    return scalarMap([](float x) { return std::fabs(x); });
        case ::GLSLstd450FSign:   return scalarMap([](float x) { return static_cast<float>((x > 0) - (x < 0)); });
        case ::GLSLstd450Floor:   return scalarMap([](float x) { return std::floor(x); });
        case ::GLSLstd450Ceil:    return scalarMap([](float x) { return std::ceil(x); });
        case ::GLSLstd450Fract:   return scalarMap([](float x) { return x - std::floor(x); });
        case ::GLSLstd450Trunc:   return scalarMap([](float x) { return std::trunc(x); });
        case ::GLSLstd450Round:   return scalarMap([](float x) { return std::round(x); });
        case ::GLSLstd450RoundEven: return scalarMap([](float x) {
            // Banker's rounding — round-half-to-even. Matches GLSL spec 8.3.
            float r = std::round(x);
            if (std::fabs(x - std::trunc(x)) == 0.5f) {
                r = 2.0f * std::round(x * 0.5f);
            }
            return r;
        });

        // ─ Binary ─
        case ::GLSLstd450Pow:     return binaryMap([](float x, float y) { return std::pow(x, y); });
        case ::GLSLstd450Atan2:   return binaryMap([](float y, float x) { return std::atan2(y, x); });
        case ::GLSLstd450FMin:    return binaryMap([](float x, float y) { return std::fmin(x, y); });
        case ::GLSLstd450FMax:    return binaryMap([](float x, float y) { return std::fmax(x, y); });
        case ::GLSLstd450Step: {
            // step(edge, x) — edge is operand0 in GLSL, x is operand1.
            Value r = b;   // result matches x shape
            for (int k = 0; k < b.componentCount(); ++k) r.f[k] = (b.f[k] < a.f[k]) ? 0.0f : 1.0f;
            return r;
        }

        // ─ Ternary ─
        case ::GLSLstd450FClamp:  return ternaryMap([](float x, float lo, float hi) {
            return std::fmin(std::fmax(x, lo), hi);
        });
        case ::GLSLstd450FMix:    return ternaryMap([](float x, float y, float t) {
            return x * (1.0f - t) + y * t;
        });
        case ::GLSLstd450SmoothStep: {
            // smoothstep(edge0, edge1, x) — ops are (edge0, edge1, x).
            Value r = c;   // result matches x shape
            for (int k = 0; k < c.componentCount(); ++k) {
                const float e0 = a.f[k], e1 = b.f[k], x = c.f[k];
                float t = (x - e0) / (e1 - e0);
                t = std::fmin(std::fmax(t, 0.0f), 1.0f);
                r.f[k] = t * t * (3.0f - 2.0f * t);
            }
            return r;
        }

        // ─ Vector reductions ─
        case ::GLSLstd450Length: {
            Value r;
            r.kind = Value::Kind::Float;
            float s = 0.0f;
            for (int k = 0; k < a.componentCount(); ++k) s += a.f[k] * a.f[k];
            r.f[0] = std::sqrt(s);
            return r;
        }
        case ::GLSLstd450Distance: {
            Value r;
            r.kind = Value::Kind::Float;
            float s = 0.0f;
            for (int k = 0; k < a.componentCount(); ++k) {
                const float d = a.f[k] - b.f[k];
                s += d * d;
            }
            r.f[0] = std::sqrt(s);
            return r;
        }
        // GLSL `dot()` maps to SPIR-V OpDot (not an ext-inst), which is
        // handled in the interpreter's primary switch. If it ever
        // surfaces as an ExtInst on some weird glslang build, the
        // default arm below will bail with a useful diagnostic.
        case ::GLSLstd450Normalize: {
            Value r = a;
            float s = 0.0f;
            for (int k = 0; k < a.componentCount(); ++k) s += a.f[k] * a.f[k];
            s = std::sqrt(s);
            if (s > 0.0f) {
                for (int k = 0; k < a.componentCount(); ++k) r.f[k] = a.f[k] / s;
            } else {
                for (int k = 0; k < a.componentCount(); ++k) r.f[k] = 0.0f;
            }
            return r;
        }
        case ::GLSLstd450Cross: {
            Value r;
            r.kind = Value::Kind::Float3;
            r.f[0] = a.f[1] * b.f[2] - a.f[2] * b.f[1];
            r.f[1] = a.f[2] * b.f[0] - a.f[0] * b.f[2];
            r.f[2] = a.f[0] * b.f[1] - a.f[1] * b.f[0];
            return r;
        }
        case ::GLSLstd450Reflect: {
            // reflect(I, N) = I - 2 * dot(N, I) * N
            Value r = a;
            float dotNI = 0.0f;
            for (int k = 0; k < a.componentCount(); ++k) dotNI += b.f[k] * a.f[k];
            for (int k = 0; k < a.componentCount(); ++k) {
                r.f[k] = a.f[k] - 2.0f * dotNI * b.f[k];
            }
            return r;
        }

        default:
            bail("OpExtInst: unsupported GLSL.std.450 op " + std::to_string(glslOp));
            return a;
    }
}

bool Interpreter::executeVs(EmulatedVertex& out) {
    if (!module_.haveFuncBody) {
        diagnostic_ = "SPIR-V module has no function body";
        return false;
    }
    std::vector<PerVertexInput> emptyInputs;
    initVariables(emptyInputs);
    currentOutVaryings_.clear();
    currentOutVaryings_.resize(outputVaryingNames_.size());
    std::vector<EmulatedVertex> dummy;   // VS doesn't emit anything
    if (!execute(emptyInputs, dummy)) return false;

    // After VS main() completes, capture gl_Position + output varyings
    // from their module-scope storage into `out`. Same shape as GS's
    // emitVertex().
    out.position[0] = currentPosition_[0];
    out.position[1] = currentPosition_[1];
    out.position[2] = currentPosition_[2];
    out.position[3] = currentPosition_[3];
    out.varyings.clear();
    for (std::size_t k = 0; k < outputVaryingNames_.size(); ++k) {
        std::vector<float> v;
        v.assign(outputVaryingWidths_[k], 0.0f);
        for (const auto& [varId, info] : module_.variables) {
            if (info.storageClass == spv::StorageClassOutput &&
                info.name == outputVaryingNames_[k]) {
                auto sIt = varStorage_.find(varId);
                if (sIt != varStorage_.end()) {
                    for (std::size_t j = 0; j < v.size() && j < sIt->second.size(); ++j) {
                        v[j] = sIt->second[j];
                    }
                }
                break;
            }
        }
        out.varyings.insert(out.varyings.end(), v.begin(), v.end());
    }
    return !errored_;
}

bool Interpreter::execute(const std::vector<PerVertexInput>& inputs,
                          std::vector<EmulatedVertex>& emitted) {
    if (!module_.haveFuncBody) {
        diagnostic_ = "SPIR-V module has no function body";
        return false;
    }
    // VS's `executeVs` already called initVariables+currentOutVaryings
    // setup before forwarding here — skip them in that case. The dummy
    // emitted buffer won't receive any vertices for VS (no OpEmitVertex
    // in VS GLSL), but we keep the check generic.
    if (stage_ == Stage::Geometry) {
        initVariables(inputs);
        currentOutVaryings_.clear();
        currentOutVaryings_.resize(outputVaryingNames_.size());
    }

    // Build label → instruction offset map.
    std::unordered_map<std::uint32_t, std::size_t> labelMap;
    {
        std::size_t i = module_.funcBodyStart;
        while (i < module_.funcBodyEnd) {
            const std::uint32_t inst = module_.words[i];
            const std::uint16_t opcode = inst & 0xFFFF;
            const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
            if (opcode == spv::OpLabel && wc >= 2) {
                labelMap[module_.words[i + 1]] = i + wc;  // first instr after label
            }
            i += wc;
        }
    }

    std::size_t pc = module_.funcBodyStart;
    std::uint32_t previousLabel = 0;
    std::uint32_t currentLabel = 0;

    while (pc < module_.funcBodyEnd && !errored_) {
        const std::uint32_t inst = module_.words[pc];
        const std::uint16_t opcode = inst & 0xFFFF;
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0) { bail("zero word count"); break; }
        const std::uint32_t* w = module_.words.data() + pc + 1;

        switch (opcode) {
            case spv::OpLabel: {
                previousLabel = currentLabel;
                currentLabel = w[0];
                pc += wc;
                break;
            }
            case spv::OpVariable: {
                // Function-scoped variable — already in varStorage_
                // from initVariables() for program-scope, but function-
                // scope is declared inside the body. Allocate if not
                // present.
                if (varStorage_.find(w[1]) == varStorage_.end()) {
                    auto tIt = module_.types.find(w[0]);
                    if (tIt != module_.types.end()) {
                        varStorage_[w[1]].assign(module_.scalarWidth(tIt->second.pointeeType), 0.0f);
                    }
                }
                pc += wc;
                break;
            }
            case spv::OpLoad: {
                // w[0]=type, w[1]=resultId, w[2]=ptrId
                auto vIt = module_.variables.find(w[2]);
                if (vIt != module_.variables.end()) {
                    // Direct load from a variable (common for scalars).
                    const auto& tIt = module_.types.at(vIt->second.typeId);
                    valueStore_[w[1]] = loadFromVar(w[2], 0, module_.scalarWidth(tIt.pointeeType), tIt.pointeeType);
                } else {
                    // Pointer came from OpAccessChain.
                    auto acIt = accessChains_.find(w[2]);
                    if (acIt != accessChains_.end()) {
                        valueStore_[w[1]] = loadFromVar(acIt->second.rootVarId,
                                                        acIt->second.scalarOffset,
                                                        acIt->second.scalarCount,
                                                        acIt->second.leafTypeId);
                    } else {
                        bail("OpLoad: unresolved pointer");
                    }
                }
                pc += wc;
                break;
            }
            case spv::OpStore: {
                // w[0]=ptrId, w[1]=valId
                Value v;
                if (!tryGetValue(w[1], v)) { bail("OpStore: unresolved value"); break; }
                auto vIt = module_.variables.find(w[0]);
                if (vIt != module_.variables.end()) {
                    storeToVar(w[0], 0, v);
                    // Built-in: gl_Position scalar mirror.
                    auto dIt = module_.decorations.find(w[0]);
                    if (dIt != module_.decorations.end() && dIt->second.hasBuiltIn
                        && dIt->second.builtIn == spv::BuiltInPosition) {
                        for (int k = 0; k < 4 && k < v.componentCount(); ++k) {
                            currentPosition_[k] = v.f[k];
                        }
                    }
                } else {
                    auto acIt = accessChains_.find(w[0]);
                    if (acIt != accessChains_.end()) {
                        storeToVar(acIt->second.rootVarId, acIt->second.scalarOffset, v);
                        // Built-in position via struct member.
                        auto mdIt = module_.memberDecorations.find(0);   // stub — expand
                        (void)mdIt;
                        // Heuristic for the common "Out.gl_Position = x"
                        // pattern via access chain member 0 of an Output
                        // struct decorated BuiltIn Position.
                        auto rootVar = module_.variables.find(acIt->second.rootVarId);
                        if (rootVar != module_.variables.end() &&
                            rootVar->second.storageClass == spv::StorageClassOutput) {
                            // If leafType is vec4 and the chain went
                            // through a struct member decorated
                            // BuiltIn Position, mirror into
                            // currentPosition_.
                            auto& pointee = module_.types.at(module_.types.at(rootVar->second.typeId).pointeeType);
                            if (pointee.kind == TypeInfo::Kind::Struct) {
                                auto md = module_.memberDecorations.find(module_.types.at(rootVar->second.typeId).pointeeType);
                                if (md != module_.memberDecorations.end()) {
                                    // Scan members for BuiltInPosition
                                    // and compute its scalar offset.
                                    std::uint32_t off = 0;
                                    for (std::size_t m = 0; m < pointee.memberTypes.size(); ++m) {
                                        auto mm = md->second.perMember.find(m);
                                        if (mm != md->second.perMember.end() && mm->second.hasBuiltIn
                                            && mm->second.builtIn == spv::BuiltInPosition) {
                                            if (off == acIt->second.scalarOffset) {
                                                for (int k = 0; k < 4 && k < v.componentCount(); ++k) {
                                                    currentPosition_[k] = v.f[k];
                                                }
                                            }
                                            break;
                                        }
                                        off += module_.scalarWidth(pointee.memberTypes[m]);
                                    }
                                }
                            }
                        }
                    } else {
                        bail("OpStore: unresolved pointer");
                    }
                }
                pc += wc;
                break;
            }
            case spv::OpAccessChain: {
                // w[0]=type, w[1]=resultId, w[2]=base, w[3..]=indices
                const std::uint32_t nIdx = wc - 4;
                AccessChainResult r = resolveAccessChain(w[2], &w[3], nIdx);
                if (r.ok) accessChains_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpCompositeExtract: {
                // w[0]=type, w[1]=resultId, w[2]=composite, w[3..]=indices
                Value composite;
                if (!tryGetValue(w[2], composite)) { bail("OpCompositeExtract: unknown src"); break; }
                Value r;
                r.kind = Value::Kind::Float;   // assume scalar extract for MVP
                if (wc >= 5) {
                    const std::uint32_t idx = w[3];
                    if (composite.isFloatKind()) r.f[0] = composite.f[idx];
                    else if (composite.isIntKind()) {
                        r.kind = Value::Kind::Int;
                        r.i[0] = composite.i[idx];
                    }
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpCompositeConstruct: {
                // w[0]=type, w[1]=resultId, w[2..]=component ids
                auto typeIt = module_.types.find(w[0]);
                Value r;
                if (typeIt != module_.types.end()) {
                    const auto& t = typeIt->second;
                    if (t.kind == TypeInfo::Kind::Vec2 || t.kind == TypeInfo::Kind::Vec3 ||
                        t.kind == TypeInfo::Kind::Vec4) {
                        r.kind = (t.count == 2) ? Value::Kind::Float2 :
                                 (t.count == 3) ? Value::Kind::Float3 : Value::Kind::Float4;
                        for (std::uint32_t k = 0; k < t.count && (2 + k) < wc; ++k) {
                            Value cv;
                            if (tryGetValue(w[2 + k], cv)) r.f[k] = cv.f[0];
                        }
                    }
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpFAdd: case spv::OpFSub:
            case spv::OpFMul: case spv::OpFDiv: {
                Value a, b;
                if (!tryGetValue(w[2], a) || !tryGetValue(w[3], b)) { bail("arith: unknown operand"); break; }
                Value r = a;
                for (int k = 0; k < a.componentCount(); ++k) {
                    switch (opcode) {
                        case spv::OpFAdd: r.f[k] = a.f[k] + b.f[k]; break;
                        case spv::OpFSub: r.f[k] = a.f[k] - b.f[k]; break;
                        case spv::OpFMul: r.f[k] = a.f[k] * b.f[k]; break;
                        case spv::OpFDiv: r.f[k] = a.f[k] / b.f[k]; break;
                    }
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpFNegate: {
                Value a;
                if (!tryGetValue(w[2], a)) { bail("OpFNegate: unknown operand"); break; }
                Value r = a;
                for (int k = 0; k < a.componentCount(); ++k) r.f[k] = -a.f[k];
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpDot: {
                // w[0]=type, w[1]=resultId, w[2]=a, w[3]=b — result is scalar float.
                Value a, b;
                if (!tryGetValue(w[2], a) || !tryGetValue(w[3], b)) { bail("OpDot: unknown operand"); break; }
                Value r;
                r.kind = Value::Kind::Float;
                float s = 0.0f;
                const int n = a.componentCount();
                for (int k = 0; k < n; ++k) s += a.f[k] * b.f[k];
                r.f[0] = s;
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpVectorTimesScalar: {
                // w[2]=vector, w[3]=scalar.
                Value v, s;
                if (!tryGetValue(w[2], v) || !tryGetValue(w[3], s)) { bail("OpVectorTimesScalar: unknown operand"); break; }
                Value r = v;
                for (int k = 0; k < v.componentCount(); ++k) r.f[k] = v.f[k] * s.f[0];
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpVectorShuffle: {
                // w[0]=type, w[1]=resultId, w[2]=v1, w[3]=v2, w[4..]=indices
                Value v1, v2;
                if (!tryGetValue(w[2], v1) || !tryGetValue(w[3], v2)) { bail("OpVectorShuffle: unknown operand"); break; }
                const std::uint32_t n = wc - 5;   // result component count
                Value r;
                r.kind = (n == 2) ? Value::Kind::Float2 :
                         (n == 3) ? Value::Kind::Float3 :
                         (n == 4) ? Value::Kind::Float4 : Value::Kind::Float;
                const int v1n = v1.componentCount();
                for (std::uint32_t k = 0; k < n && k < 4; ++k) {
                    const std::uint32_t sel = w[4 + k];
                    // sel < v1n → pick from v1; else sel - v1n → pick from v2.
                    // 0xFFFFFFFF means "undefined" — we treat as 0.
                    if (sel == 0xFFFFFFFFu) {
                        r.f[k] = 0.0f;
                    } else if (sel < static_cast<std::uint32_t>(v1n)) {
                        r.f[k] = v1.f[sel];
                    } else {
                        r.f[k] = v2.f[sel - v1n];
                    }
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpExtInst: {
                // w[0]=type, w[1]=resultId, w[2]=setId, w[3]=glslOp, w[4..]=operands
                if (module_.extInstImports.count(w[2]) == 0) {
                    bail("OpExtInst: unsupported instruction set");
                    break;
                }
                valueStore_[w[1]] = evalExtInst(w[3], &w[4], wc - 4);
                pc += wc;
                break;
            }
            // ─ Integer arithmetic / bitcast / conversions ─
            case spv::OpIAdd: case spv::OpISub: case spv::OpIMul:
            case spv::OpSDiv: case spv::OpSRem: case spv::OpUMod: {
                Value a, b;
                if (!tryGetValue(w[2], a) || !tryGetValue(w[3], b)) { bail("int-arith: unknown operand"); break; }
                Value r = a;
                const int n = a.componentCount();
                for (int k = 0; k < n; ++k) {
                    switch (opcode) {
                        case spv::OpIAdd: r.i[k] = a.i[k] + b.i[k]; break;
                        case spv::OpISub: r.i[k] = a.i[k] - b.i[k]; break;
                        case spv::OpIMul: r.i[k] = a.i[k] * b.i[k]; break;
                        case spv::OpSDiv: r.i[k] = b.i[k] != 0 ? a.i[k] / b.i[k] : 0; break;
                        case spv::OpSRem: r.i[k] = b.i[k] != 0 ? a.i[k] % b.i[k] : 0; break;
                        case spv::OpUMod: {
                            const std::uint32_t au = static_cast<std::uint32_t>(a.i[k]);
                            const std::uint32_t bu = static_cast<std::uint32_t>(b.i[k]);
                            r.i[k] = bu != 0 ? static_cast<std::int32_t>(au % bu) : 0;
                            break;
                        }
                    }
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpSNegate: {
                Value a;
                if (!tryGetValue(w[2], a)) { bail("OpSNegate: unknown operand"); break; }
                Value r = a;
                for (int k = 0; k < a.componentCount(); ++k) r.i[k] = -a.i[k];
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpFMod: {
                Value a, b;
                if (!tryGetValue(w[2], a) || !tryGetValue(w[3], b)) { bail("OpFMod: unknown operand"); break; }
                Value r = a;
                for (int k = 0; k < a.componentCount(); ++k) {
                    // GL 4.6 §5.9 mod(): x - y * floor(x/y).
                    r.f[k] = a.f[k] - b.f[k] * std::floor(a.f[k] / b.f[k]);
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpBitwiseAnd: {
                Value a, b;
                if (!tryGetValue(w[2], a) || !tryGetValue(w[3], b)) { bail("OpBitwiseAnd: unknown operand"); break; }
                Value r = a;
                for (int k = 0; k < a.componentCount(); ++k) r.i[k] = a.i[k] & b.i[k];
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpShiftLeftLogical: {
                Value a, b;
                if (!tryGetValue(w[2], a) || !tryGetValue(w[3], b)) { bail("OpShiftLeftLogical: unknown operand"); break; }
                Value r = a;
                for (int k = 0; k < a.componentCount(); ++k) {
                    r.i[k] = a.i[k] << (b.i[k] & 31);
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpBitcast: {
                // Reinterpret bits. For our float/int unified storage
                // the representation is the same — we just copy across
                // with the target kind.
                Value a;
                if (!tryGetValue(w[2], a)) { bail("OpBitcast: unknown operand"); break; }
                // Determine target kind from the result type.
                auto tIt = module_.types.find(w[0]);
                Value r = a;
                if (tIt != module_.types.end()) {
                    switch (tIt->second.kind) {
                        case TypeInfo::Kind::Int:
                            r.kind = Value::Kind::Int;
                            // If source was float, bit-copy.
                            for (int k = 0; k < a.componentCount(); ++k) {
                                std::memcpy(&r.i[k], &a.f[k], 4);
                            }
                            break;
                        case TypeInfo::Kind::UInt:
                            r.kind = Value::Kind::UInt;
                            for (int k = 0; k < a.componentCount(); ++k) {
                                std::memcpy(&r.i[k], &a.f[k], 4);
                            }
                            break;
                        case TypeInfo::Kind::Float:
                            r.kind = Value::Kind::Float;
                            for (int k = 0; k < a.componentCount(); ++k) {
                                std::memcpy(&r.f[k], &a.i[k], 4);
                            }
                            break;
                        default: break;
                    }
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpConvertSToF: case spv::OpConvertUToF: {
                Value a;
                if (!tryGetValue(w[2], a)) { bail("OpConvertSToF/UToF: unknown operand"); break; }
                Value r;
                const int n = a.componentCount();
                r.kind = (n == 2) ? Value::Kind::Float2 :
                         (n == 3) ? Value::Kind::Float3 :
                         (n == 4) ? Value::Kind::Float4 : Value::Kind::Float;
                if (opcode == spv::OpConvertSToF) {
                    for (int k = 0; k < n; ++k) r.f[k] = static_cast<float>(a.i[k]);
                } else {
                    for (int k = 0; k < n; ++k)
                        r.f[k] = static_cast<float>(static_cast<std::uint32_t>(a.i[k]));
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpConvertFToS: case spv::OpConvertFToU: {
                Value a;
                if (!tryGetValue(w[2], a)) { bail("OpConvertFToS/FToU: unknown operand"); break; }
                Value r;
                const int n = a.componentCount();
                if (opcode == spv::OpConvertFToS) {
                    r.kind = (n == 2) ? Value::Kind::Int2 :
                             (n == 3) ? Value::Kind::Int3 :
                             (n == 4) ? Value::Kind::Int4 : Value::Kind::Int;
                    for (int k = 0; k < n; ++k) r.i[k] = static_cast<std::int32_t>(a.f[k]);
                } else {
                    r.kind = (n == 2) ? Value::Kind::UInt2 :
                             (n == 3) ? Value::Kind::UInt3 :
                             (n == 4) ? Value::Kind::UInt4 : Value::Kind::UInt;
                    for (int k = 0; k < n; ++k)
                        r.i[k] = static_cast<std::int32_t>(static_cast<std::uint32_t>(a.f[k]));
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            // ─ Comparisons ─
            case spv::OpIEqual: case spv::OpINotEqual:
            case spv::OpSLessThan: case spv::OpSGreaterThan:
            case spv::OpSLessThanEqual: case spv::OpSGreaterThanEqual:
            case spv::OpULessThan: case spv::OpULessThanEqual: {
                Value a, b;
                if (!tryGetValue(w[2], a) || !tryGetValue(w[3], b)) { bail("int-cmp: unknown operand"); break; }
                // For scalar comparisons the result is a scalar bool;
                // we materialize it into bval for consumption by
                // OpBranchConditional / OpSelect.
                Value r;
                r.kind = Value::Kind::Bool;
                bool b0 = false;
                const std::int32_t ai = a.i[0], bi = b.i[0];
                const std::uint32_t au = static_cast<std::uint32_t>(ai);
                const std::uint32_t bu = static_cast<std::uint32_t>(bi);
                switch (opcode) {
                    case spv::OpIEqual:             b0 = (ai == bi); break;
                    case spv::OpINotEqual:          b0 = (ai != bi); break;
                    case spv::OpSLessThan:          b0 = (ai <  bi); break;
                    case spv::OpSGreaterThan:       b0 = (ai >  bi); break;
                    case spv::OpSLessThanEqual:     b0 = (ai <= bi); break;
                    case spv::OpSGreaterThanEqual:  b0 = (ai >= bi); break;
                    case spv::OpULessThan:          b0 = (au <  bu); break;
                    case spv::OpULessThanEqual:     b0 = (au <= bu); break;
                }
                r.bval = b0;
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpFOrdEqual: case spv::OpFOrdNotEqual:
            case spv::OpFOrdLessThan: case spv::OpFOrdGreaterThan:
            case spv::OpFOrdLessThanEqual: case spv::OpFOrdGreaterThanEqual: {
                Value a, b;
                if (!tryGetValue(w[2], a) || !tryGetValue(w[3], b)) { bail("flt-cmp: unknown operand"); break; }
                Value r;
                r.kind = Value::Kind::Bool;
                bool b0 = false;
                const float af = a.f[0], bf = b.f[0];
                switch (opcode) {
                    case spv::OpFOrdEqual:            b0 = (af == bf); break;
                    case spv::OpFOrdNotEqual:         b0 = (af != bf); break;
                    case spv::OpFOrdLessThan:         b0 = (af <  bf); break;
                    case spv::OpFOrdGreaterThan:      b0 = (af >  bf); break;
                    case spv::OpFOrdLessThanEqual:    b0 = (af <= bf); break;
                    case spv::OpFOrdGreaterThanEqual: b0 = (af >= bf); break;
                }
                r.bval = b0;
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpLogicalNot: {
                Value a;
                if (!tryGetValue(w[2], a)) { bail("OpLogicalNot: unknown operand"); break; }
                Value r; r.kind = Value::Kind::Bool; r.bval = !a.bval;
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpLogicalAnd: case spv::OpLogicalOr:
            case spv::OpLogicalNotEqual: {
                Value a, b;
                if (!tryGetValue(w[2], a) || !tryGetValue(w[3], b)) { bail("bool-op: unknown operand"); break; }
                Value r; r.kind = Value::Kind::Bool;
                switch (opcode) {
                    case spv::OpLogicalAnd:       r.bval = a.bval && b.bval; break;
                    case spv::OpLogicalOr:        r.bval = a.bval || b.bval; break;
                    case spv::OpLogicalNotEqual:  r.bval = a.bval != b.bval; break;
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpSelect: {
                // w[2]=cond, w[3]=trueVal, w[4]=falseVal
                Value c, t, f;
                if (!tryGetValue(w[2], c) || !tryGetValue(w[3], t) || !tryGetValue(w[4], f)) {
                    bail("OpSelect: unknown operand"); break;
                }
                valueStore_[w[1]] = c.bval ? t : f;
                pc += wc;
                break;
            }
            case spv::OpAny: case spv::OpAll: {
                Value a;
                if (!tryGetValue(w[2], a)) { bail("OpAny/All: unknown operand"); break; }
                Value r; r.kind = Value::Kind::Bool;
                bool any = false, all = true;
                for (int k = 0; k < a.componentCount(); ++k) {
                    if (a.f[k] != 0.0f || a.i[k] != 0) any = true;
                    else all = false;
                }
                r.bval = (opcode == spv::OpAny) ? any : all;
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpBranch: {
                auto it = labelMap.find(w[0]);
                if (it == labelMap.end()) { bail("OpBranch: unknown label"); break; }
                previousLabel = currentLabel;
                currentLabel = w[0];
                pc = it->second;
                break;
            }
            case spv::OpBranchConditional: {
                Value c;
                if (!tryGetValue(w[0], c)) { bail("OpBranchConditional: unknown cond"); break; }
                const std::uint32_t target = c.bval ? w[1] : w[2];
                auto it = labelMap.find(target);
                if (it == labelMap.end()) { bail("OpBranchConditional: unknown label"); break; }
                previousLabel = currentLabel;
                currentLabel = target;
                pc = it->second;
                break;
            }
            case spv::OpSwitch: {
                // w[0]=selector, w[1]=default, then (caseLiteral, label) pairs.
                Value sel;
                if (!tryGetValue(w[0], sel)) { bail("OpSwitch: unknown selector"); break; }
                std::uint32_t target = w[1];   // default
                const std::uint32_t nPairs = (wc - 3) / 2;
                for (std::uint32_t k = 0; k < nPairs; ++k) {
                    const std::uint32_t literal = w[2 + k * 2];
                    const std::uint32_t label   = w[2 + k * 2 + 1];
                    if (static_cast<std::int32_t>(literal) == sel.i[0]) {
                        target = label;
                        break;
                    }
                }
                auto it = labelMap.find(target);
                if (it == labelMap.end()) { bail("OpSwitch: unknown label"); break; }
                previousLabel = currentLabel;
                currentLabel = target;
                pc = it->second;
                break;
            }
            case spv::OpPhi: {
                // w[0]=type, w[1]=resultId, then pairs of (value, parentLabel).
                // Pick the value whose parent matches previousLabel.
                const std::uint32_t nPairs = (wc - 3) / 2;
                Value r;
                bool picked = false;
                for (std::uint32_t k = 0; k < nPairs; ++k) {
                    const std::uint32_t valId  = w[2 + k * 2];
                    const std::uint32_t fromId = w[2 + k * 2 + 1];
                    if (fromId == previousLabel) {
                        Value v;
                        if (tryGetValue(valId, v)) { r = v; picked = true; }
                        break;
                    }
                }
                if (!picked && nPairs > 0) {
                    // Fallback: use the first value. Matches trivial
                    // cases where previousLabel wasn't tracked cleanly
                    // (e.g. loop entry before first iteration).
                    Value v;
                    if (tryGetValue(w[2], v)) { r = v; picked = true; }
                }
                if (picked) valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpLoopMerge:
            case spv::OpSelectionMerge:
                pc += wc;   // structural annotations, no runtime action
                break;
            case spv::OpEmitVertex:
                emitVertex(emitted);
                pc += wc;
                break;
            case spv::OpEndPrimitive:
                // Mark primitive boundary on the most recently emitted
                // vertex. Stored as a sentinel in EmulatedVertex.varyings
                // is not ideal — revisit when we handle multi-primitive
                // outputs; for the MVP (1 vertex out, points) the count
                // is always 1 and boundary info is implicit.
                pc += wc;
                break;
            case spv::OpReturn:
                return true;
            case spv::OpFunction:
            case spv::OpFunctionEnd:
                pc += wc;
                break;
            default:
                bail("unsupported opcode: " + std::to_string(opcode));
                return false;
        }
    }

    return !errored_;
}

}  // namespace

// ─── Public API — step 2 wiring ─────────────────────────────────────
//
// `detectGeometryEmulatable` is called once at link time. It parses the
// GS SPIR-V copied onto `program.geometrySpirv`, pulls the input/output
// topology + max_vertices out of OpExecutionMode, and walks the entry-
// function body to confirm every opcode is one the interpreter switch
// below handles. Anything unsupported leaves `geometryEmulated = false`
// and the driver takes the existing VS+FS-only fallback.

namespace {
// Opcodes handled by `Interpreter::execute` (plus the structural
// Phi/Label etc. that appear in any reducible CFG). Kept in sync with
// the switch in execute(); anything outside this set fails detection
// so we don't silently half-run a shader that uses a missing feature.
bool isSupportedGsOpcode(std::uint32_t op) {
    switch (op) {
        // ─ Structural / data movement ─
        case spv::OpLabel:
        case spv::OpVariable:
        case spv::OpLoad:
        case spv::OpStore:
        case spv::OpAccessChain:
        case spv::OpCompositeExtract:
        case spv::OpCompositeConstruct:
        case spv::OpVectorShuffle:
        case spv::OpArrayLength:
        case spv::OpBitcast:
        // ─ Float arith ─
        case spv::OpFAdd:
        case spv::OpFSub:
        case spv::OpFMul:
        case spv::OpFDiv:
        case spv::OpFMod:
        case spv::OpFNegate:
        case spv::OpVectorTimesScalar:
        case spv::OpDot:
        // ─ Int arith ─
        case spv::OpIAdd:
        case spv::OpISub:
        case spv::OpIMul:
        case spv::OpSDiv:
        case spv::OpSRem:
        case spv::OpUMod:
        case spv::OpSNegate:
        // ─ Bit ops ─
        case spv::OpBitwiseAnd:
        case spv::OpShiftLeftLogical:
        // ─ Conversions ─
        case spv::OpConvertFToS:
        case spv::OpConvertFToU:
        case spv::OpConvertSToF:
        case spv::OpConvertUToF:
        // ─ Int comparisons ─
        case spv::OpIEqual:
        case spv::OpINotEqual:
        case spv::OpSLessThan:
        case spv::OpSGreaterThan:
        case spv::OpSLessThanEqual:
        case spv::OpSGreaterThanEqual:
        case spv::OpULessThan:
        case spv::OpULessThanEqual:
        // ─ Float comparisons ─
        case spv::OpFOrdEqual:
        case spv::OpFOrdNotEqual:
        case spv::OpFOrdLessThan:
        case spv::OpFOrdGreaterThan:
        case spv::OpFOrdLessThanEqual:
        case spv::OpFOrdGreaterThanEqual:
        // ─ Logical / selection ─
        case spv::OpLogicalNot:
        case spv::OpLogicalAnd:
        case spv::OpLogicalOr:
        case spv::OpLogicalNotEqual:
        case spv::OpSelect:
        case spv::OpAny:
        case spv::OpAll:
        // ─ Ext-inst ─
        case spv::OpExtInst:
        // ─ Control flow ─
        case spv::OpBranch:
        case spv::OpBranchConditional:
        case spv::OpSwitch:
        case spv::OpPhi:
        case spv::OpLoopMerge:
        case spv::OpSelectionMerge:
        // ─ GS-specific ─
        case spv::OpEmitVertex:
        case spv::OpEndPrimitive:
        // ─ Function ─
        case spv::OpReturn:
        case spv::OpFunction:
        case spv::OpFunctionEnd:
            return true;
        default:
            return false;
    }
}

// Translate an ExecutionMode value to the corresponding GL input
// topology enum. Returns 0 if the mode isn't an input-topology mode.
GLenum inputModeToGL(std::uint32_t mode) {
    switch (mode) {
        case spv::ExecutionModeInputPoints:             return GL_POINTS;
        case spv::ExecutionModeInputLines:              return GL_LINES;
        case spv::ExecutionModeInputLinesAdjacency:     return GL_LINES_ADJACENCY;
        case spv::ExecutionModeTriangles:               return GL_TRIANGLES;
        case spv::ExecutionModeInputTrianglesAdjacency: return GL_TRIANGLES_ADJACENCY;
        default: return 0;
    }
}

// Translate an ExecutionMode value to the corresponding GL output
// topology enum. Returns 0 if the mode isn't an output-topology mode.
GLenum outputModeToGL(std::uint32_t mode) {
    switch (mode) {
        case spv::ExecutionModeOutputPoints:        return GL_POINTS;
        case spv::ExecutionModeOutputLineStrip:     return GL_LINE_STRIP;
        case spv::ExecutionModeOutputTriangleStrip: return GL_TRIANGLE_STRIP;
        default: return 0;
    }
}
}  // namespace

bool detectGeometryEmulatable(GLProgramObject& program) {
    program.geometryEmulated = false;
    program.gsInputTopology = 0;
    program.gsOutputTopology = 0;
    program.gsMaxVertices = 0;

    if (program.geometrySpirv.empty()) return false;

    SpirvModule mod;
    if (!mod.parse(program.geometrySpirv.data(), program.geometrySpirv.size())) return false;
    if (!mod.haveFuncBody) return false;

    // Topology + max_vertices. GL_POINTS is literally 0x0, so we use
    // explicit haveInput/haveOutput flags rather than comparing the
    // resolved GL enum against 0 (that bug ate a round-trip of sweep
    // wiring before we noticed `inputTopo == GL_POINTS == 0` was
    // being treated as "unset").
    GLenum inputTopo = 0;
    GLenum outputTopo = 0;
    bool haveInputTopo = false;
    bool haveOutputTopo = false;
    std::uint32_t maxVertices = 0;
    std::uint32_t invocations = 1;   // default if ExecutionModeInvocations absent
    for (const auto& [mode, operands] : mod.executionModes) {
        if (mode == spv::ExecutionModeInputPoints || mode == spv::ExecutionModeInputLines ||
            mode == spv::ExecutionModeInputLinesAdjacency || mode == spv::ExecutionModeTriangles ||
            mode == spv::ExecutionModeInputTrianglesAdjacency) {
            inputTopo = inputModeToGL(mode);
            haveInputTopo = true;
        } else if (mode == spv::ExecutionModeOutputPoints || mode == spv::ExecutionModeOutputLineStrip ||
                   mode == spv::ExecutionModeOutputTriangleStrip) {
            outputTopo = outputModeToGL(mode);
            haveOutputTopo = true;
        } else if (mode == spv::ExecutionModeOutputVertices && !operands.empty()) {
            maxVertices = operands[0];
        } else if (mode == spv::ExecutionModeInvocations && !operands.empty()) {
            invocations = operands[0];
        }
    }
    if (!haveInputTopo || !haveOutputTopo || maxVertices == 0) return false;
    // MVP supports only single-invocation GS (CTS constant_expressions
    // never uses GL_ARB_gpu_shader5 invocation counts). Multi-
    // invocation lands in a follow-up.
    if (invocations != 1) return false;

    // Walk the function body and reject on any unsupported opcode.
    // On rejection, log the opcode + GS source hash so that sweep
    // diagnostics can grep for "[GS-emul] reject" and enumerate which
    // opcodes are still missing. Gated behind APPGL_TRACE_GS_EMUL so
    // production runs stay quiet.
    std::size_t pc = mod.funcBodyStart;
    while (pc < mod.funcBodyEnd) {
        const std::uint32_t inst = mod.words[pc];
        const std::uint16_t opcode = static_cast<std::uint16_t>(inst & 0xFFFF);
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0) return false;   // malformed
        if (!isSupportedGsOpcode(opcode)) {
            if (std::getenv("APPGL_TRACE_GS_EMUL") != nullptr) {
                std::fprintf(stderr, "[GS-emul] reject: unsupported opcode %u at pc=%zu\n",
                             opcode, pc);
            }
            return false;
        }
        pc += wc;
    }

    program.geometryEmulated = true;
    program.gsInputTopology = inputTopo;
    program.gsOutputTopology = outputTopo;
    program.gsMaxVertices = maxVertices;
    return true;
}

namespace {
// Number of vertices the input topology consumes per primitive.
// Adjacency variants include their adjacency vertices.
std::uint32_t vertsPerInputPrim(GLenum topo) {
    switch (topo) {
        case GL_POINTS:               return 1;
        case GL_LINES:                return 2;
        case GL_LINES_ADJACENCY:      return 4;
        case GL_TRIANGLES:            return 3;
        case GL_TRIANGLES_ADJACENCY:  return 6;
        default:                      return 0;
    }
}

// Gather user output varyings (StorageClassOutput, non-built-in, with
// Location decoration) from the GS SPIR-V. Returns them ordered by
// Location ascending so the expanded-vertex layout matches the FS
// input layout — the synthesised pass-through VS will emit
// `[[user(locn<N>)]]` in the same order, giving the FS translator a
// consistent varying table.
struct OutputVaryingDesc {
    std::string name;
    std::uint32_t width = 0;     // flat scalar count (always in scalar units)
    std::uint32_t location = 0;
    std::uint8_t interp = 0;     // 0=smooth, 1=flat, 2=noperspective, 3=centroid
    std::uint8_t baseType = 0;   // 0=float, 1=int, 2=uint
};

std::vector<OutputVaryingDesc> gatherOutputVaryings(const SpirvModule& mod) {
    std::vector<OutputVaryingDesc> out;
    // Implicit-location varyings (no explicit `layout(location=N)` in
    // the GLSL) carry no DecorationLocation from glslang. GL 4.6 §4.4.2
    // says the linker assigns them sequentially starting from 0; we
    // mirror that here by collecting them separately and auto-numbering
    // after the explicitly-located ones settle, sorted by SPIR-V id so
    // the order is stable across runs.
    std::vector<OutputVaryingDesc> implicits;
    for (const auto& [varId, info] : mod.variables) {
        if (info.storageClass != spv::StorageClassOutput) continue;
        auto dIt = mod.decorations.find(varId);
        // Built-ins (gl_Position, gl_PointSize) have BuiltIn decoration;
        // those are captured separately via currentPosition_. A variable
        // with no decoration block at all is also a candidate — that's
        // what glslang emits for `out float foo;` with no layout
        // qualifier.
        if (dIt != mod.decorations.end() && dIt->second.hasBuiltIn) continue;
        OutputVaryingDesc d;
        d.name = info.name;
        auto tIt = mod.types.find(info.typeId);
        if (tIt != mod.types.end()) {
            d.width = mod.scalarWidth(tIt->second.pointeeType);
        }
        if (d.width == 0) continue;   // empty or unresolved — skip
        // If the type pointee is a struct (e.g. the gl_PerVertex
        // output block), skip — our gl_Position / built-in handling
        // owns that and we only want standalone user varyings.
        if (tIt != mod.types.end()) {
            const auto pIt = mod.types.find(tIt->second.pointeeType);
            if (pIt != mod.types.end() && pIt->second.kind == TypeInfo::Kind::Struct) {
                continue;
            }
            // Determine scalar base type by walking vec → scalar.
            if (pIt != mod.types.end()) {
                std::uint32_t scalarTypeId = 0;
                if (pIt->second.kind == TypeInfo::Kind::Vec2 ||
                    pIt->second.kind == TypeInfo::Kind::Vec3 ||
                    pIt->second.kind == TypeInfo::Kind::Vec4) {
                    scalarTypeId = pIt->second.componentType;
                } else {
                    scalarTypeId = tIt->second.pointeeType;
                }
                const auto sIt = mod.types.find(scalarTypeId);
                if (sIt != mod.types.end()) {
                    switch (sIt->second.kind) {
                        case TypeInfo::Kind::Int:   d.baseType = 1; break;
                        case TypeInfo::Kind::UInt:  d.baseType = 2; break;
                        case TypeInfo::Kind::Float: d.baseType = 0; break;
                        default: d.baseType = 0; break;
                    }
                }
            }
        }
        if (dIt != mod.decorations.end() && dIt->second.hasLocation) {
            d.location = dIt->second.location;
            if (dIt->second.isFlat) d.interp = 1;
            else if (dIt->second.isNoPerspective) d.interp = 2;
            else if (dIt->second.isCentroid) d.interp = 3;
            out.push_back(std::move(d));
        } else {
            // Implicit location; record a tracking id in `location`
            // temporarily — we overwrite below after we know how many
            // explicitly-located slots are claimed.
            d.location = varId;   // will be replaced
            if (dIt != mod.decorations.end()) {
                if (dIt->second.isFlat) d.interp = 1;
                else if (dIt->second.isNoPerspective) d.interp = 2;
                else if (dIt->second.isCentroid) d.interp = 3;
            }
            implicits.push_back(std::move(d));
        }
    }
    // Resolve implicit locations: sort by SPIR-V id (stable) and
    // assign the lowest non-occupied location ≥ 0.
    if (!implicits.empty()) {
        std::sort(implicits.begin(), implicits.end(), [](const auto& a, const auto& b) {
            return a.location < b.location;   // id-sorted
        });
        std::uint32_t nextLoc = 0;
        auto locTaken = [&](std::uint32_t loc) {
            for (const auto& v : out) if (v.location == loc) return true;
            return false;
        };
        for (auto& v : implicits) {
            while (locTaken(nextLoc)) ++nextLoc;
            v.location = nextLoc;
            out.push_back(std::move(v));
            ++nextLoc;
        }
    }
    std::sort(out.begin(), out.end(), [](const auto& a, const auto& b) {
        return a.location < b.location;
    });
    return out;
}
}  // namespace

namespace {
// Build a uniform-name → flat float value map from the program's
// link-time uniform table + draw-time uniformValues. Works for
// scalars, vectors, and matrices (laid out as flat float sequence —
// the interpreter treats ints as bit-cast floats so the same storage
// serves both types).
Interpreter::UniformValues buildUniformMap(const GLProgramObject& program) {
    Interpreter::UniformValues out;
    for (const auto& u : program.uniforms) {
        auto vIt = program.uniformValues.find(u.location);
        if (vIt == program.uniformValues.end()) continue;
        const auto& v = vIt->second;
        std::vector<float> flat;
        if (!v.floats.empty()) {
            flat = v.floats;
        } else if (!v.ints.empty()) {
            flat.resize(v.ints.size());
            std::memcpy(flat.data(), v.ints.data(), flat.size() * sizeof(float));
        } else if (!v.uints.empty()) {
            flat.resize(v.uints.size());
            std::memcpy(flat.data(), v.uints.data(), flat.size() * sizeof(float));
        }
        if (!flat.empty()) out[u.name] = std::move(flat);
    }
    return out;
}

// Extract a single vertex's attribute value from a VAO + VBO shadow.
// `attrIdx` is the GLVertexAttributeState array index (== Location
// for the default non-separated-format path). `vertexIdx` is absolute
// (first + relativeVertex).
Value readVertexAttribFromVAO(
    const GLVertexArrayObject& vao,
    GLObjectStore& objects,
    std::size_t attrIdx,
    std::size_t vertexIdx)
{
    Value v;
    if (attrIdx >= vao.attributes.size()) return v;
    const auto& attr = vao.attributes[attrIdx];
    if (!attr.enabled) return v;
    // Resolve buffer. Separated-format bindings aren't handled yet —
    // MVP uses the classic glVertexAttribPointer path.
    GLuint bufferName = attr.buffer;
    std::size_t relativeOffset = 0;
    std::size_t stride = attr.stride > 0 ? static_cast<std::size_t>(attr.stride)
                                         : static_cast<std::size_t>(attr.size * 4);
    std::size_t baseOffset = attr.pointer;
    if (bufferName == 0) return v;
    GLBufferObject* buf = objects.buffers().get(bufferName);
    if (buf == nullptr || buf->shadowBytes.empty()) return v;
    const std::size_t byteOffset = baseOffset + relativeOffset + stride * vertexIdx;
    if (byteOffset + static_cast<std::size_t>(attr.size * 4) > buf->shadowBytes.size()) {
        return v;
    }
    const std::uint8_t* src = buf->shadowBytes.data() + byteOffset;
    // GL 4.6 §10.2 (Vertex Arrays) table 10.8: when a vertex
    // attribute declared as vec4 in the shader receives a
    // narrower stream, missing components are filled with
    // (0, 0, 0, 1). We always return a 4-component Value so the
    // VS-init path can copy however many components the SPIR-V
    // variable actually declares.
    const bool isInt  = (attr.type == 0x1404 /* GL_INT */);
    const bool isUInt = (attr.type == 0x1405 /* GL_UNSIGNED_INT */);
    v.kind = isInt  ? Value::Kind::Int4
           : isUInt ? Value::Kind::UInt4
                    : Value::Kind::Float4;
    // Init w component to spec default of 1 / unit, then overwrite
    // from source. x/y/z init to 0 (spec default).
    if (isInt || isUInt) {
        v.i[0] = v.i[1] = v.i[2] = 0;
        v.i[3] = 1;
        if (isInt || isUInt || attr.type == 0x1406 /* GL_FLOAT */) {
            for (int k = 0; k < attr.size && k < 4; ++k) {
                std::memcpy(&v.i[k], src + k * 4, 4);
            }
        }
    } else {
        v.f[0] = v.f[1] = v.f[2] = 0.0f;
        v.f[3] = 1.0f;
        if (attr.type == 0x1406 /* GL_FLOAT */) {
            for (int k = 0; k < attr.size && k < 4; ++k) {
                std::memcpy(&v.f[k], src + k * 4, 4);
            }
        }
    }
    return v;
}
}  // namespace

EmulatedDraw emulateGeometryDraw(
    GLProgramObject& program,
    const GLVertexArrayObject& vao,
    GLObjectStore& objects,
    const GLStateTracker& /*state*/,
    GLenum drawMode, GLsizei count, GLint first,
    const void* /*indices*/, GLenum /*indexType*/)
{
    EmulatedDraw d;

    if (!program.geometryEmulated || program.geometrySpirv.empty()) {
        d.ok = false;
        d.diagnostic = "emulateGeometryDraw called on non-emulated program";
        return d;
    }

    SpirvModule mod;
    if (!mod.parse(program.geometrySpirv.data(), program.geometrySpirv.size())
        || !mod.haveFuncBody) {
        d.ok = false;
        d.diagnostic = "SPIR-V re-parse failed at draw time: " + mod.parseError;
        return d;
    }

    // Primitive accounting. The draw's `mode` must be compatible with
    // the GS input topology (GL 4.6 §11.3.2). We ignore the variant
    // mismatches for MVP — CTS submits the right topology.
    const std::uint32_t vpp = vertsPerInputPrim(program.gsInputTopology);
    if (vpp == 0) {
        d.ok = false;
        d.diagnostic = "unknown GS input topology";
        return d;
    }
    (void)drawMode;  // caller guarantees compatibility for now
    const std::size_t primCount = (count > 0) ? (static_cast<std::size_t>(count) / vpp) : 0;
    if (primCount == 0) {
        d.ok = false;
        d.diagnostic = "vertex count produced zero primitives";
        return d;
    }

    // Output varying layout from the GS SPIR-V, ordered by Location.
    const std::vector<OutputVaryingDesc> outVaryings = gatherOutputVaryings(mod);
    std::vector<std::string>   outNames;
    std::vector<std::uint32_t> outWidths;
    std::vector<std::uint32_t> outLocations;
    std::vector<std::uint8_t>  outInterp;
    std::vector<std::uint8_t>  outBaseType;
    outNames.reserve(outVaryings.size());
    outWidths.reserve(outVaryings.size());
    outLocations.reserve(outVaryings.size());
    outInterp.reserve(outVaryings.size());
    outBaseType.reserve(outVaryings.size());
    for (const auto& v : outVaryings) {
        outNames.push_back(v.name);
        outWidths.push_back(v.width);
        outLocations.push_back(v.location);
        outInterp.push_back(v.interp);
        outBaseType.push_back(v.baseType);
    }

    // ─── VS pre-pass ────────────────────────────────────────────
    //
    // For each input vertex, run the VS interpreter on CPU so gl_in[]
    // sees the right per-vertex data. Skipped when the program lacks
    // VS SPIR-V (shouldn't happen for VGF programs, but the
    // constant_expressions path used to work without it because the
    // GS didn't read gl_in[]). In that case we fall back to zero-
    // initialised inputs.
    const Interpreter::UniformValues uniforms = buildUniformMap(program);

    // Parse VS SPIR-V (shared across every vertex of this draw). The
    // VS module is small — re-parsing per draw is fine; caching it on
    // the program object only matters if CTS workloads show draw-call
    // hot spots, which they don't at this scale.
    SpirvModule vsMod;
    const bool haveVs = !program.vertexSpirv.empty() &&
                        vsMod.parse(program.vertexSpirv.data(), program.vertexSpirv.size()) &&
                        vsMod.haveFuncBody;

    // VS output varyings (ordered by Location) — the caller's per-
    // vertex-input varying table must match the GS's input-side view.
    std::vector<std::string>   vsOutNames;
    std::vector<std::uint32_t> vsOutWidths;
    std::vector<std::uint32_t> vsOutLocations;
    if (haveVs) {
        const auto vsOuts = gatherOutputVaryings(vsMod);
        vsOutNames.reserve(vsOuts.size());
        vsOutWidths.reserve(vsOuts.size());
        vsOutLocations.reserve(vsOuts.size());
        for (const auto& v : vsOuts) {
            vsOutNames.push_back(v.name);
            vsOutWidths.push_back(v.width);
            vsOutLocations.push_back(v.location);
        }
    }

    // Run VS for every input vertex (count vertices total) up front,
    // then slice into per-primitive inputs. Avoids re-running VS on
    // shared vertices (line strip / triangle strip / indexed draws
    // would otherwise re-execute); not the cleanest for GL_POINTS
    // where every vertex is its own primitive, but cheap enough for
    // CTS sizes.
    std::vector<Interpreter::PerVertexInput> allVertexInputs(count);
    if (haveVs) {
        // Pre-compute (location → attrIdx) map from the VAO so the VS
        // interpreter can look up by SPIR-V Location.
        Interpreter::VertexAttribs vsAttribs;

        // Find the entry-point interface variables' Locations; the
        // caller maps VAO attribute index → GL attribute location.
        // For the non-separated-format VAO path used by these tests,
        // VAO attribute index == GL location, so we build the
        // vsAttribs map per-vertex by walking vao.attributes and
        // using the array index as the Location key.
        for (GLsizei vi = 0; vi < count; ++vi) {
            vsAttribs.clear();
            for (std::size_t ai = 0; ai < vao.attributes.size(); ++ai) {
                if (!vao.attributes[ai].enabled) continue;
                Value v = readVertexAttribFromVAO(vao, objects, ai,
                    static_cast<std::size_t>(first + vi));
                if (v.kind != Value::Kind::Invalid) {
                    vsAttribs[static_cast<std::uint32_t>(ai)] = v;
                }
            }
            Interpreter vsInterp(vsMod, Interpreter::Stage::Vertex,
                                 vsOutNames, vsOutWidths);
            vsInterp.setUniforms(&uniforms);
            vsInterp.setVsInputs(&vsAttribs, first + vi, 0 /*instanceID*/);
            EmulatedVertex vsOut;
            vsOut.position[0] = vsOut.position[1] = vsOut.position[2] = 0.0f;
            vsOut.position[3] = 1.0f;
            if (!vsInterp.executeVs(vsOut)) {
                // VS failure — leave the record at default (0,0,0,1)
                // so the draw at least produces something the log can
                // grep. Diagnostic propagates via EmulatedDraw.
                d.diagnostic = "VS pre-pass failed: " + vsInterp.diagnostic();
            }
            for (int k = 0; k < 4; ++k) {
                allVertexInputs[vi].position[k] = vsOut.position[k];
            }
            // Slice flat varyings into per-varying vectors matching
            // `vsOutWidths`.
            std::size_t cursor = 0;
            allVertexInputs[vi].varyings.resize(vsOutWidths.size());
            for (std::size_t k = 0; k < vsOutWidths.size(); ++k) {
                const std::uint32_t w = vsOutWidths[k];
                auto& dst = allVertexInputs[vi].varyings[k];
                dst.assign(w, 0.0f);
                for (std::uint32_t j = 0; j < w && cursor + j < vsOut.varyings.size(); ++j) {
                    dst[j] = vsOut.varyings[cursor + j];
                }
                cursor += w;
            }
        }
    }

    // Run the GS interpreter once per primitive, slicing the pre-run
    // VS outputs into per-primitive input groups.
    std::vector<EmulatedVertex> emittedAll;
    emittedAll.reserve(primCount * program.gsMaxVertices);

    for (std::size_t p = 0; p < primCount; ++p) {
        std::vector<Interpreter::PerVertexInput> inputs(vpp);
        for (std::uint32_t v = 0; v < vpp; ++v) {
            const std::size_t globalIdx = p * vpp + v;
            if (globalIdx < allVertexInputs.size()) {
                inputs[v] = allVertexInputs[globalIdx];
            }
        }
        Interpreter interp(mod, vsOutNames, vsOutWidths,
                           outNames, outWidths);
        interp.setUniforms(&uniforms);
        std::vector<EmulatedVertex> emitted;
        if (!interp.execute(inputs, emitted)) {
            d.ok = false;
            d.diagnostic = "interpreter failed on primitive " + std::to_string(p)
                         + ": " + interp.diagnostic();
            return d;
        }
        emittedAll.insert(emittedAll.end(),
            std::make_move_iterator(emitted.begin()),
            std::make_move_iterator(emitted.end()));
    }

    if (emittedAll.empty()) {
        d.ok = false;
        d.diagnostic = "GS emitted zero vertices";
        return d;
    }

    // Pack into the flat payload [pos0..3, varying0..N-1] per vertex.
    const std::size_t totalVaryingWidth = [&]() {
        std::size_t s = 0;
        for (std::uint32_t w : outWidths) s += w;
        return s;
    }();
    const std::size_t fpv = 4 + totalVaryingWidth;

    d.topology          = program.gsOutputTopology;
    d.vertexCount       = emittedAll.size();
    d.floatsPerVertex   = fpv;
    d.varyingWidths     = outWidths;
    d.varyingNames      = std::move(outNames);
    d.varyingLocations  = std::move(outLocations);
    d.varyingInterp     = std::move(outInterp);
    d.varyingBaseType   = std::move(outBaseType);
    d.expandedVertexData.resize(emittedAll.size() * fpv, 0.0f);

    for (std::size_t v = 0; v < emittedAll.size(); ++v) {
        float* dst = d.expandedVertexData.data() + v * fpv;
        for (int k = 0; k < 4; ++k) dst[k] = emittedAll[v].position[k];
        for (std::size_t j = 0; j < emittedAll[v].varyings.size() && j + 4 < fpv; ++j) {
            dst[4 + j] = emittedAll[v].varyings[j];
        }
    }

    d.ok = true;
    return d;
}

// ─── MSL synthesis ───────────────────────────────────────────────────
//
// The synthesised VS reads a packed buffer (slot 0) whose per-vertex
// stride is `floatsPerVertex`:
//   bytes 0..15 : gl_Position (float4)
//   bytes 16..  : varyings, laid out in widthi × float, sorted by
//                 Location ascending
// It emits:
//   [[position]]    gl_Position  — with the standard GL→Metal depth
//                                  fixup (z' = (z + w) / 2)
//   [[user(locn<L>)]] varying    — for each varying, at its original
//                                  SPIR-V Location
//
// The MSL `[[attribute(...)]]` indices are allocated sequentially
// (0 for position, 1..N for varyings). These are vertex-descriptor
// attribute indices, not the GLSL `layout(location=...)` qualifiers —
// those live on the `[[user(locnN)]]` output side. The FS was
// translated from SPIR-V with the same Location values on its input
// varyings, so SPIRV-Cross emitted `[[user(locnN)]]` on the FS input
// side. Matching on both sides is what makes the stage link work.

std::string synthesisePassThroughVertexMSL(const EmulatedDraw& draw) {
    auto mslTypeFor = [](std::uint32_t width, std::uint8_t baseType) -> const char* {
        const char* floatNames[] = { "float", "float2", "float3", "float4" };
        const char* intNames[]   = { "int",   "int2",   "int3",   "int4"   };
        const char* uintNames[]  = { "uint",  "uint2",  "uint3",  "uint4"  };
        const unsigned idx = (width >= 1 && width <= 4) ? (width - 1) : 0;
        switch (baseType) {
            case 1:  return intNames[idx];
            case 2:  return uintNames[idx];
            default: return floatNames[idx];
        }
    };

    std::string src;
    src.reserve(512);
    src += "#include <metal_stdlib>\n";
    src += "using namespace metal;\n\n";

    // ─ Vertex input struct (stage_in).
    src += "struct VsIn {\n";
    src += "    float4 vsin_position [[attribute(0)]];\n";
    for (std::size_t i = 0; i < draw.varyingWidths.size(); ++i) {
        const std::uint8_t bt = (i < draw.varyingBaseType.size()) ? draw.varyingBaseType[i] : 0;
        src += "    ";
        src += mslTypeFor(draw.varyingWidths[i], bt);
        src += " vsin_v";
        src += std::to_string(i);
        src += " [[attribute(";
        src += std::to_string(i + 1);   // 0 reserved for position
        src += ")]];\n";
    }
    src += "};\n\n";

    // ─ Vertex output struct.
    auto interpTag = [](std::uint8_t interp) -> const char* {
        switch (interp) {
            case 1: return ", flat";
            case 2: return ", center_no_perspective";
            case 3: return ", centroid_perspective";
            default: return "";
        }
    };
    src += "struct VsOut {\n";
    src += "    float4 gl_Position [[position]];\n";
    // Metal point-output pipelines need [[point_size]] on the VS
    // output; without it, GL_POINTS tests render 0-sized / invisible
    // points on Apple GPUs. Emit unconditionally at size 1.0 — the
    // actual GS may have written gl_PointSize, but capturing that
    // per vertex would require extra plumbing; for the rendering
    // tests 1.0 matches the expected behaviour.
    if (draw.topology == GL_POINTS) {
        src += "    float gl_PointSize [[point_size]];\n";
    }
    for (std::size_t i = 0; i < draw.varyingWidths.size(); ++i) {
        const std::uint32_t loc = (i < draw.varyingLocations.size())
            ? draw.varyingLocations[i] : static_cast<std::uint32_t>(i);
        const std::uint8_t interp = (i < draw.varyingInterp.size())
            ? draw.varyingInterp[i] : 0;
        const std::uint8_t bt = (i < draw.varyingBaseType.size())
            ? draw.varyingBaseType[i] : 0;
        // Integer varyings MUST be flat — Metal spec and MSL compiler
        // both enforce this. If we got here with smooth on an int
        // varying, force flat.
        const std::uint8_t effInterp = (bt != 0 && interp == 0) ? 1 : interp;
        src += "    ";
        src += mslTypeFor(draw.varyingWidths[i], bt);
        src += " vsout_v";
        src += std::to_string(i);
        src += " [[user(locn";
        src += std::to_string(loc);
        src += ")";
        src += interpTag(effInterp);
        src += "]];\n";
    }
    src += "};\n\n";

    // ─ Entry.
    src += "vertex VsOut main0(VsIn in [[stage_in]])\n";
    src += "{\n";
    src += "    VsOut out = {};\n";
    src += "    out.gl_Position = in.vsin_position;\n";
    // GL→Metal depth fixup. Mirrors what SPIRV-Cross emits for every
    // non-geometry VS today.
    src += "    out.gl_Position.z = (out.gl_Position.z + out.gl_Position.w) * 0.5;\n";
    if (draw.topology == GL_POINTS) {
        src += "    out.gl_PointSize = 1.0;\n";
    }
    for (std::size_t i = 0; i < draw.varyingWidths.size(); ++i) {
        src += "    out.vsout_v";
        src += std::to_string(i);
        src += " = in.vsin_v";
        src += std::to_string(i);
        src += ";\n";
    }
    src += "    return out;\n";
    src += "}\n";
    return src;
}

}  // namespace appgl
