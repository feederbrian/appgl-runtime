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
        OpCompositeExtract = 81, OpCompositeConstruct = 80,
        OpFAdd = 129, OpFSub = 131, OpFMul = 133, OpFDiv = 136,
        OpIAdd = 128,  OpIMul = 132,
        OpConvertFToS = 110, OpConvertSToF = 111,
        OpSLessThan = 177,
        OpLogicalAnd = 167, OpLogicalOr = 166, OpLogicalNot = 168,
        OpPhi = 245, OpLoopMerge = 246, OpSelectionMerge = 247,
        OpLabel = 248, OpBranch = 249, OpBranchConditional = 250,
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
    enum Decoration : std::uint32_t { DecorationLocation = 30, DecorationBuiltIn = 11 };
    enum StorageClass : std::uint32_t {
        StorageClassUniformConstant = 0, StorageClassInput = 1,
        StorageClassUniform = 2, StorageClassOutput = 3,
        StorageClassFunction = 7, StorageClassPrivate = 6
    };
    enum BuiltIn : std::uint32_t {
        BuiltInPosition = 0, BuiltInPointSize = 1,
        BuiltInClipDistance = 3, BuiltInCullDistance = 4
    };
    enum GLSLstd450 : std::uint32_t {
        GLSLstd450Radians = 11, GLSLstd450Degrees = 12,
        GLSLstd450Sin = 13, GLSLstd450Cos = 14, GLSLstd450Tan = 15,
        GLSLstd450Asin = 16, GLSLstd450Acos = 17, GLSLstd450Atan = 18,
        GLSLstd450Pow = 26, GLSLstd450Exp = 27, GLSLstd450Log = 28,
        GLSLstd450Exp2 = 29, GLSLstd450Log2 = 30, GLSLstd450Sqrt = 31,
        GLSLstd450InverseSqrt = 32, GLSLstd450Abs = 4,
        GLSLstd450Length = 66, GLSLstd450Distance = 67,
        GLSLstd450Normalize = 69, GLSLstd450Dot = 0xCAFEBABE,  // stub
    };
}
#endif

#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
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
                if (wc >= 4 && w[1] == 0) {   // only stash member-0 name for now
                    std::size_t j = i + 3;
                    memberNames0[w[0]] = readLiteralString(data, j, count);
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
    struct PerVertexInput {
        std::array<float, 4> position{0, 0, 0, 1};
        // Per-varying payload. Parallel to `inputVaryingNames` below.
        // Each varying is a flat float array (width from varying type).
        std::vector<std::vector<float>> varyings;
    };

    Interpreter(const SpirvModule& mod,
                std::vector<std::string> inputVaryingNames,
                std::vector<std::uint32_t> inputVaryingWidths,
                std::vector<std::string> outputVaryingNames,
                std::vector<std::uint32_t> outputVaryingWidths)
        : module_(mod),
          inputVaryingNames_(std::move(inputVaryingNames)),
          inputVaryingWidths_(std::move(inputVaryingWidths)),
          outputVaryingNames_(std::move(outputVaryingNames)),
          outputVaryingWidths_(std::move(outputVaryingWidths)) {}

    // Run the entry-point function once, given `inputs` as gl_in[].
    // Appends emitted vertices to `emitted`. Primitive boundaries are
    // recorded as indices into `emitted` where EndPrimitive was called
    // (so a vertex at index `emitted.size() - 1` gets a boundary mark
    // if EndPrimitive immediately follows).
    bool execute(const std::vector<PerVertexInput>& inputs,
                 std::vector<EmulatedVertex>& emitted);

    const std::string& diagnostic() const { return diagnostic_; }

private:
    const SpirvModule& module_;
    std::vector<std::string> inputVaryingNames_;
    std::vector<std::uint32_t> inputVaryingWidths_;
    std::vector<std::string> outputVaryingNames_;
    std::vector<std::uint32_t> outputVaryingWidths_;

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
    // Walk every declared variable. For Output/Private/Function storage,
    // reserve a zero-initialised flat buffer of the right size. For
    // Input storage, populate from driver-supplied per-vertex data
    // (gl_in[].gl_Position + named input varyings).
    for (const auto& [varId, info] : module_.variables) {
        auto tIt = module_.types.find(info.typeId);
        if (tIt == module_.types.end()) continue;
        const std::uint32_t width = module_.scalarWidth(tIt->second.pointeeType);
        auto& storage = varStorage_[varId];
        storage.assign(width, 0.0f);

        if (info.storageClass == spv::StorageClassInput) {
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
    Value a;
    if (nOperands >= 1 && !tryGetValue(operands[0], a)) {
        bail("OpExtInst: unknown operand 0");
        return a;
    }
    auto scalarMap = [&](float (*fn)(float)) {
        Value r = a;
        for (int k = 0; k < a.componentCount(); ++k) r.f[k] = fn(a.f[k]);
        return r;
    };
    switch (glslOp) {
        case ::GLSLstd450Radians: return scalarMap([](float x) { return x * 0.017453292519943295f; });
        case ::GLSLstd450Degrees: return scalarMap([](float x) { return x * 57.29577951308232f; });
        case ::GLSLstd450Sin:     return scalarMap([](float x) { return std::sin(x); });
        case ::GLSLstd450Cos:     return scalarMap([](float x) { return std::cos(x); });
        case ::GLSLstd450Tan:     return scalarMap([](float x) { return std::tan(x); });
        case ::GLSLstd450Asin:    return scalarMap([](float x) { return std::asin(x); });
        case ::GLSLstd450Acos:    return scalarMap([](float x) { return std::acos(x); });
        case ::GLSLstd450Atan:    return scalarMap([](float x) { return std::atan(x); });
        case ::GLSLstd450Exp:     return scalarMap([](float x) { return std::exp(x); });
        case ::GLSLstd450Log:     return scalarMap([](float x) { return std::log(x); });
        case ::GLSLstd450Exp2:    return scalarMap([](float x) { return std::exp2(x); });
        case ::GLSLstd450Log2:    return scalarMap([](float x) { return std::log2(x); });
        case ::GLSLstd450Sqrt:    return scalarMap([](float x) { return std::sqrt(x); });
        case ::GLSLstd450InverseSqrt: return scalarMap([](float x) { return 1.0f / std::sqrt(x); });
        case ::GLSLstd450FAbs:    return scalarMap([](float x) { return std::fabs(x); });
        default:
            bail("OpExtInst: unsupported GLSL.std.450 op " + std::to_string(glslOp));
            return a;
    }
}

bool Interpreter::execute(const std::vector<PerVertexInput>& inputs,
                          std::vector<EmulatedVertex>& emitted) {
    if (!module_.haveFuncBody) {
        diagnostic_ = "SPIR-V module has no function body";
        return false;
    }
    initVariables(inputs);
    currentOutVaryings_.clear();
    currentOutVaryings_.resize(outputVaryingNames_.size());

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
        case spv::OpLabel:
        case spv::OpVariable:
        case spv::OpLoad:
        case spv::OpStore:
        case spv::OpAccessChain:
        case spv::OpCompositeExtract:
        case spv::OpCompositeConstruct:
        case spv::OpFAdd:
        case spv::OpFSub:
        case spv::OpFMul:
        case spv::OpFDiv:
        case spv::OpExtInst:
        case spv::OpBranch:
        case spv::OpBranchConditional:
        case spv::OpLoopMerge:
        case spv::OpSelectionMerge:
        case spv::OpEmitVertex:
        case spv::OpEndPrimitive:
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
    if (!mod.parse(program.geometrySpirv.data(), program.geometrySpirv.size())) {
        return false;
    }
    if (!mod.haveFuncBody) return false;

    // Topology + max_vertices. All three must be present; otherwise the
    // shader is malformed and we let the normal path complain.
    GLenum inputTopo = 0;
    GLenum outputTopo = 0;
    std::uint32_t maxVertices = 0;
    std::uint32_t invocations = 1;   // default if ExecutionModeInvocations absent
    for (const auto& [mode, operands] : mod.executionModes) {
        if (GLenum g = inputModeToGL(mode); g != 0) {
            inputTopo = g;
        } else if (GLenum g2 = outputModeToGL(mode); g2 != 0) {
            outputTopo = g2;
        } else if (mode == spv::ExecutionModeOutputVertices && !operands.empty()) {
            maxVertices = operands[0];
        } else if (mode == spv::ExecutionModeInvocations && !operands.empty()) {
            invocations = operands[0];
        }
    }
    if (inputTopo == 0 || outputTopo == 0 || maxVertices == 0) return false;
    // MVP supports only single-invocation GS (CTS constant_expressions
    // never uses GL_ARB_gpu_shader5 invocation counts). Multi-
    // invocation lands in a follow-up.
    if (invocations != 1) return false;

    // Walk the function body and reject on any unsupported opcode.
    std::size_t pc = mod.funcBodyStart;
    while (pc < mod.funcBodyEnd) {
        const std::uint32_t inst = mod.words[pc];
        const std::uint16_t opcode = static_cast<std::uint16_t>(inst & 0xFFFF);
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0) return false;   // malformed
        if (!isSupportedGsOpcode(opcode)) return false;
        pc += wc;
    }

    program.geometryEmulated = true;
    program.gsInputTopology = inputTopo;
    program.gsOutputTopology = outputTopo;
    program.gsMaxVertices = maxVertices;
    return true;
}

EmulatedDraw emulateGeometryDraw(
    GLProgramObject& /*program*/,
    const GLVertexArrayObject& /*vao*/,
    GLObjectStore& /*objects*/,
    const GLStateTracker& /*state*/,
    GLenum /*drawMode*/, GLsizei /*count*/, GLint /*first*/,
    const void* /*indices*/, GLenum /*indexType*/)
{
    EmulatedDraw d;
    d.ok = false;
    d.diagnostic = "GS emulator wiring pending — interpreter implemented, linkProgram / "
                   "drawArrays hooks not yet hooked in";
    return d;
}

}  // namespace appgl
