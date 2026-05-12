#ifndef APPGL_SHADER_SHADER_INTERPRETER_H
#define APPGL_SHADER_SHADER_INTERPRETER_H

// Shared SPIR-V structures + parse helpers used by both the Geometry
// Shader CPU emulator and the Tessellation CPU emulator. Everything
// lives in `appgl::interp::` so call sites can pull in just the pieces
// they need without rolling their own SPIR-V parser.
//
// The full `Interpreter` class (which walks function bodies and
// executes instructions) remains in GeometryShaderEmulator.cpp's
// translation unit for now — only the module-reader half is shared.
// Tess-emul uses the SpirvModule + its lookup tables to answer
// "what's my execution mode, which variables are decorated
// BuiltInTessLevelOuter, etc." without needing to re-run the
// interpreter's dispatch loop.

#include <array>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace appgl::interp {

// ─── Value model ────────────────────────────────────────────────────

struct Value {
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
                      Matrix, Array, RuntimeArray, Struct, Pointer, Function,
                      Unknown };
    Kind kind = Kind::Unknown;
    std::uint32_t componentType = 0;
    std::uint32_t count = 0;
    std::uint32_t arrayLengthConstId = 0;
    std::vector<std::uint32_t> memberTypes;
    std::uint32_t storageClass = 0;
    std::uint32_t pointeeType = 0;
    std::uint32_t returnType = 0;
    std::uint32_t elementScalarWidth = 1;
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
    bool isFlat = false;
    bool isNoPerspective = false;
    bool isCentroid = false;
    // Phase 3f-13: GL 4.6 §11.2.1 `patch in` / `patch out` qualifier.
    // Applies to TCS Output and TES Input interface variables. Marks
    // the value as per-patch (one value shared across all domain
    // vertices in the patch) rather than per-vertex. SPIR-V emits
    // DecorationPatch (=15) on the variable; interpreter reads this
    // to route data through a per-patch scratch map instead of the
    // gl_in[] / gl_out[] array path.
    bool isPatch = false;
    bool hasOffset = false;
    std::uint32_t offset = 0;
    bool isBlock = false;
    // Phase 3f-3: BufferBlock (GLSL 4.2-style SSBO) is distinct from
    // Block (UBO / StorageBuffer storage class). `isBlock` catches
    // both so the interpreter can tell "this is a block-decorated
    // struct" at a glance; `isBufferBlock` narrows to the SSBO
    // variant for storage-class reasoning.
    bool isBufferBlock = false;
    bool hasBinding = false;
    std::uint32_t binding = 0;
    bool hasDescriptorSet = false;
    std::uint32_t descriptorSet = 0;
    // Phase 3f-3: std430 byte stride on OpTypeArray /
    // OpTypeRuntimeArray (via OpDecorate target ArrayStride), and on
    // individual struct-member arrays via OpMemberDecorate. Populated
    // from `DecorationArrayStride = 6` when glslang emits it (every
    // SSBO runtime-array it generates).
    bool hasArrayStride = false;
    std::uint32_t arrayStride = 0;
    bool hasMatrixStride = false;
    std::uint32_t matrixStride = 0;
    bool isRowMajor = false;
    bool isColMajor = false;
    // Sprint 8 #9-C (CKPT96) — GLSL `layout(stream=N) out` →
    // SPIR-V DecorationStream (=29). Carries the target vertex
    // stream index for transform-feedback per-stream BO routing.
    // `gl_MaxTransformFeedbackStreams` floor is 4 (GL 4.0).
    bool hasStream = false;
    std::uint32_t stream = 0;
};

struct MemberDecorations {
    std::unordered_map<std::uint32_t, DecorationSet> perMember;
};

// ─── SPIR-V module ──────────────────────────────────────────────────

struct SpirvModule {
    std::uint32_t bound = 0;
    std::vector<std::uint32_t> words;

    std::unordered_map<std::uint32_t, TypeInfo> types;
    std::unordered_map<std::uint32_t, Value> constants;
    std::unordered_map<std::uint32_t, std::vector<Value>> matrixConstants;
    std::unordered_map<std::uint32_t, VariableInfo> variables;
    std::unordered_map<std::uint32_t, DecorationSet> decorations;
    std::unordered_map<std::uint32_t, MemberDecorations> memberDecorations;
    std::unordered_map<std::uint32_t, std::string> names;
    std::unordered_map<std::uint32_t, std::string> memberNames0;
    std::unordered_map<std::uint32_t, std::unordered_map<std::uint32_t, std::string>> memberNames;
    std::unordered_map<std::uint32_t, std::uint32_t> extInstImports;

    std::uint32_t entryPoint = 0;
    std::vector<std::uint32_t> entryInterface;
    std::unordered_map<std::uint32_t, std::vector<std::uint32_t>> executionModes;

    struct FunctionInfo {
        std::uint32_t returnTypeId = 0;
        std::uint32_t functionTypeId = 0;
        std::size_t bodyStart = 0;
        std::size_t bodyEnd = 0;
        std::vector<std::uint32_t> parameters;
        std::vector<std::uint32_t> parameterTypeIds;
    };
    std::unordered_map<std::uint32_t, FunctionInfo> functions;

    std::size_t funcBodyStart = 0;
    std::size_t funcBodyEnd = 0;
    bool haveFuncBody = false;

    std::string parseError;

    bool parse(const std::uint32_t* data, std::size_t count);
    std::uint32_t scalarWidth(std::uint32_t typeId) const;
};

// ─── Access-chain result ────────────────────────────────────────────

struct AccessChainResult {
    std::uint32_t rootVarId = 0;
    std::uint32_t scalarOffset = 0;
    std::uint32_t scalarCount = 1;
    std::uint32_t leafTypeId = 0;
    bool ok = false;
    // Phase 3f-3: when the root variable is a StorageBuffer (or
    // Uniform with BufferBlock), `isStorageBuffer` flips on and
    // the interpreter uses `byteOffset` / `binding` to route
    // OpLoad / OpStore through a caller-supplied raw-pointer map
    // instead of the flat-scalar `varStorage_`.
    bool isStorageBuffer = false;
    std::uint32_t byteOffset = 0;
    std::uint32_t binding = 0;
    // Sprint 17 Day 4+ BONUS-2 [gpu_shader5 array-indexing]: when
    // the root variable is a UBO ARRAY (Uniform storage class +
    // pointee Array(Block-decorated Struct)), `isUniformBuffer`
    // flips on. The first index in the access-chain resolves to a
    // GL UBO binding (= baseBinding + idx); subsequent indices
    // accumulate `byteOffset` within that bound buffer. OpLoad
    // routes through caller-supplied `UniformBufferMap` instead of
    // varStorage_. Read-only — no storeToUBO counterpart (UBOs are
    // read-only per GL spec). Mutually exclusive with
    // isStorageBuffer (which is read+write).
    bool isUniformBuffer = false;
    bool hasMatrixStride = false;
    std::uint32_t matrixStride = 0;
};

// ─── UBO array dispatch (Sprint 17 Day 4+ BONUS-2) ──────────────────

// Per-binding UBO buffer region for runtime UBO/UBO-array dynamic
// indexing in the CPU SPIR-V interpreter. Used by the TF-capture
// path (`emulateVsOnlyDrawForTf` → `runVsForVertex`) to feed UBO
// data the Interpreter wouldn't otherwise see. Sister to the SSBO
// path's StorageBufferRegion (declared in GeometryShaderEmulator.cpp's
// translation unit alongside the Interpreter class).
struct UniformBufferRegion {
    const std::uint8_t* ptr = nullptr;
    std::size_t size = 0;
};

// Public typedef for UBO array map shared between callers and
// Interpreter. Mirrors the pattern of `SampledTextureMap` from
// GeometryShaderEmulator.h. The Interpreter class re-aliases the
// same type internally.
using UniformBufferMap = std::unordered_map<std::uint32_t, UniformBufferRegion>;

// Per-variable UBO array meta. baseBinding is the GL binding point
// of element [0]; arrayLen is the static array length parsed from
// the SPIR-V type. OpAccessChain uses this to resolve the first
// index → binding=baseBinding+idx. Sister to StorageBufferVarMeta.
struct UniformBufferArrayMeta {
    std::uint32_t baseBinding = 0;
    std::uint32_t arrayLen = 1;
};

}  // namespace appgl::interp

#endif   // APPGL_SHADER_SHADER_INTERPRETER_H
