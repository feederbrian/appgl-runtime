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

#include "ShaderInterpreter.h"
#include "TessellationEmulator.h"   // metalBufferContents — Sprint 7 #5 (CKPT56)
#include "../objects/GLObjectStore.h"
#include "../state/GLStateTracker.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <optional>

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
        OpFunction = 54, OpFunctionParameter = 55, OpFunctionEnd = 56,
        OpFunctionCall = 57,
        OpVariable = 59, OpLoad = 61, OpStore = 62, OpAccessChain = 65,
        OpArrayLength = 68,
        OpCompositeExtract = 81, OpCompositeConstruct = 80,
        OpVectorShuffle = 79,
        OpVectorTimesScalar = 142, OpMatrixTimesScalar = 143,
        OpVectorTimesMatrix = 144, OpMatrixTimesVector = 145,
        OpMatrixTimesMatrix = 146, OpOuterProduct = 147, OpDot = 148,
        OpFNegate = 127,
        OpFAdd = 129, OpFSub = 131, OpFMul = 133, OpFDiv = 136, OpFMod = 141,
        OpIAdd = 128, OpISub = 130, OpIMul = 132,
        OpSDiv = 135, OpSRem = 138, OpSMod = 139, OpUMod = 137, OpSNegate = 126,
        OpConvertFToS = 110, OpConvertFToU = 109,
        OpConvertSToF = 111, OpConvertUToF = 112, OpFConvert = 115,
        OpBitcast = 124,
        OpBitwiseAnd = 199, OpShiftLeftLogical = 196,
        OpIEqual = 170, OpINotEqual = 171,
        OpUGreaterThan = 172,
        OpSLessThan = 177, OpSGreaterThan = 173,
        OpUGreaterThanEqual = 174,
        OpSLessThanEqual = 179, OpSGreaterThanEqual = 175,
        OpULessThan = 176, OpULessThanEqual = 178,
        OpFOrdEqual = 180, OpFOrdNotEqual = 182,
        OpFOrdLessThan = 184, OpFOrdGreaterThan = 186,
        OpFOrdLessThanEqual = 188, OpFOrdGreaterThanEqual = 190,
        OpFUnordEqual = 181, OpFUnordNotEqual = 183,
        OpFUnordLessThan = 185, OpFUnordGreaterThan = 187,
        OpFUnordLessThanEqual = 189, OpFUnordGreaterThanEqual = 191,
        OpLogicalAnd = 167, OpLogicalOr = 166, OpLogicalNot = 168,
        OpLogicalEqual = 164, OpLogicalNotEqual = 165,
        OpSelect = 169, OpAny = 154, OpAll = 155,
        OpPhi = 245, OpLoopMerge = 246, OpSelectionMerge = 247,
        OpLabel = 248, OpBranch = 249, OpBranchConditional = 250, OpSwitch = 251,
        OpReturn = 253,
        OpEmitVertex = 218, OpEndPrimitive = 219,
        // Sprint 8 #9-C (CKPT95) — multi-stream GS emit. Stream operand is
        // an <id> referencing a constant Int specifying the target stream.
	        OpEmitStreamVertex = 220, OpEndStreamPrimitive = 221,
	        OpControlBarrier = 224, OpMemoryBarrier = 225,
	        OpAtomicLoad = 227, OpAtomicStore = 228,
        OpAtomicExchange = 229, OpAtomicCompareExchange = 230,
        OpAtomicCompareExchangeWeak = 231,
        OpAtomicIIncrement = 232, OpAtomicIDecrement = 233,
        OpAtomicIAdd = 234, OpAtomicISub = 235,
        OpAtomicSMin = 236, OpAtomicUMin = 237,
        OpAtomicSMax = 238, OpAtomicUMax = 239,
        OpAtomicAnd = 240, OpAtomicOr = 241, OpAtomicXor = 242,
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
        DecorationRowMajor = 4, DecorationColMajor = 5,
        DecorationArrayStride = 6,
        DecorationMatrixStride = 7,
        DecorationNoPerspective = 13, DecorationFlat = 14, DecorationCentroid = 16,
        DecorationOffset = 35,
        DecorationDescriptorSet = 34, DecorationBinding = 33,
    };
    enum StorageClass : std::uint32_t {
        StorageClassUniformConstant = 0, StorageClassInput = 1,
        StorageClassUniform = 2, StorageClassOutput = 3,
        StorageClassFunction = 7, StorageClassPrivate = 6,
        StorageClassStorageBuffer = 12,
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
    GLSLstd450Determinant = 33, GLSLstd450MatrixInverse = 34,
    GLSLstd450Modf = 35, GLSLstd450ModfStruct = 36,
    GLSLstd450FMin = 37, GLSLstd450FMax = 40, GLSLstd450FClamp = 43,
    GLSLstd450FMix = 46, GLSLstd450Step = 48, GLSLstd450SmoothStep = 49,
    GLSLstd450Fma = 50, GLSLstd450Frexp = 51,
    GLSLstd450FrexpStruct = 52, GLSLstd450Ldexp = 53,
    GLSLstd450PackDouble2x32 = 64, GLSLstd450UnpackDouble2x32 = 65,
    GLSLstd450Length = 66, GLSLstd450Distance = 67, GLSLstd450Cross = 68,
    GLSLstd450Normalize = 69, GLSLstd450FaceForward = 70,
    GLSLstd450Reflect = 71, GLSLstd450Refract = 72,
};
#endif

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <unordered_set>
#include <iterator>
#include <mutex>
#include <string>
#include <thread>
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
#ifndef GL_TESS_CONTROL_SHADER
#define GL_TESS_CONTROL_SHADER 0x8E88
#endif
#ifndef GL_TESS_EVALUATION_SHADER
#define GL_TESS_EVALUATION_SHADER 0x8E87
#endif

namespace appgl {
namespace {

// SPIR-V module reader types (Value, TypeInfo, VariableInfo,
// DecorationSet, MemberDecorations, SpirvModule, AccessChainResult)
// moved to src/shader/ShaderInterpreter.h so TessellationEmulator.cpp
// can reuse the same parser + lookup tables. Body-dispatching
// Interpreter class below still lives here until a later refactor.
using namespace appgl::interp;

float imageHalfToFloat(std::uint16_t h) {
    const std::uint32_t sign = (static_cast<std::uint32_t>(h & 0x8000u)) << 16;
    int exp = static_cast<int>((h >> 10) & 0x1Fu);
    std::uint32_t mant = h & 0x03FFu;
    std::uint32_t bits = 0;
    if (exp == 0) {
        if (mant == 0) {
            bits = sign;
        } else {
            exp = 1;
            while ((mant & 0x0400u) == 0) {
                mant <<= 1;
                --exp;
            }
            mant &= 0x03FFu;
            bits = sign |
                   (static_cast<std::uint32_t>(exp + (127 - 15)) << 23) |
                   (mant << 13);
        }
    } else if (exp == 31) {
        bits = sign | 0x7F800000u | (mant << 13);
    } else {
        bits = sign |
               (static_cast<std::uint32_t>(exp + (127 - 15)) << 23) |
               (mant << 13);
    }
    float f = 0.0f;
    std::memcpy(&f, &bits, sizeof(f));
    return f;
}

float imageUnsignedFPToFloat(std::uint32_t bits, int mantissaBits) {
    const std::uint32_t mantMask = (1u << mantissaBits) - 1u;
    const std::uint32_t mant = bits & mantMask;
    const std::uint32_t exp = (bits >> mantissaBits) & 0x1Fu;
    if (exp == 0u) {
        return std::ldexp(static_cast<float>(mant),
                          -14 - mantissaBits);
    }
    if (exp == 31u) {
        return mant ? NAN : INFINITY;
    }
    return std::ldexp(
        static_cast<float>((1u << mantissaBits) + mant),
        static_cast<int>(exp) - 15 - mantissaBits);
}

void decodeImageRG11B10F(std::uint32_t raw, float& r, float& g, float& b) {
    r = imageUnsignedFPToFloat((raw >> 0) & 0x7FFu, 6);
    g = imageUnsignedFPToFloat((raw >> 11) & 0x7FFu, 6);
    b = imageUnsignedFPToFloat((raw >> 22) & 0x3FFu, 5);
}

float imageSnorm8(std::int8_t v) {
    return std::max(static_cast<float>(v) / 127.0f, -1.0f);
}

float imageSnorm16(std::int16_t v) {
    return std::max(static_cast<float>(v) / 32767.0f, -1.0f);
}

// ─── Interpreter ────────────────────────────────────────────────────

class Interpreter {
public:
    enum class Stage { Vertex, Geometry, TessEvaluation, TessControl };

    struct PerVertexInput {
        std::array<float, 4> position{0, 0, 0, 1};
        // Per-varying payload. Parallel to `inputVaryingNames` below.
        // Each varying is a flat float array (width from varying type).
        std::vector<std::vector<float>> varyings;
        // gl_ClipDistance[] / gl_CullDistance[] written by the VS for
        // this vertex. Read by the caller's pre-GS culling check (a
        // primitive is discarded before the GS runs iff for some plane
        // i, every vertex has cullDistance[i] < 0 — GL 4.6 §13.6) and
        // propagated into the GS's gl_in[].gl_ClipDistance array so a
        // passthrough GS sees the same values the no-GS path would.
        std::vector<float> clipDistance;
        std::vector<float> cullDistance;
        // Sprint 8 #8 β.2 Day 2 (CKPT70): VS's gl_PointSize for this
        // vertex. Routed into gl_in[].gl_PointSize for downstream
        // TCS / TES / GS reads. Default 1.0 matches GL spec's
        // implicit value when VS doesn't write gl_PointSize.
        float pointSize = 1.0f;
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

    // Sprint 8 #8 β.2 (CKPT69): TCS/TES need to look up user-block input
    // member names against the cross-stage interface (VS→TCS or
    // TCS→TES) when seeding gl_in[].user_block.member from
    // PerVertexInput.varyings. The 4-arg constructor only seeds the
    // OUTPUT varying list; this setter back-fills the INPUT list so
    // executeTes / executeVs / execute(GS) all share one entry point.
    // Mirrors the GS constructor's input-varying init path.
    void setInputVaryings(std::vector<std::string> names,
                          std::vector<std::uint32_t> widths) {
        inputVaryingNames_ = std::move(names);
        inputVaryingWidths_ = std::move(widths);
    }

    // Phase 3f-3: SSBO / shader-storage-buffer plumbing. Caller
    // supplies a binding → (host-pointer, size-in-bytes) map drawn
    // from the GL state (indexedBufferBinding(GL_SHADER_STORAGE_BUFFER,
    // N) → MTLBuffer.contents + offset). OpLoad / OpStore through an
    // access chain rooted in a StorageBuffer variable routes byte-
    // level reads/writes into this region.
    struct StorageBufferRegion {
        void* ptr = nullptr;
        std::size_t size = 0;
    };
    using StorageBufferMap = std::unordered_map<std::uint32_t, StorageBufferRegion>;
    void setStorageBuffers(const StorageBufferMap* m) { storageBuffers_ = m; }

    // Sprint 17 Day 4+ BONUS-2 [gpu_shader5 array-indexing]: UBO
    // array dynamic-indexing for the TF-capture VS-only interpreter
    // path. Caller supplies a (binding → const-pointer + size) map
    // drawn from `state.indexedBufferBinding(GL_UNIFORM_BUFFER, N)`
    // → GLBufferObject::shadowBytes. Read-only by GL spec — no
    // store-side counterpart. Sister to StorageBufferMap above.
    // Alias the namespace-level type from ShaderInterpreter.h so
    // callers using `Interpreter::UniformBufferMap` see the same
    // type as `appgl::interp::UniformBufferMap`.
    using UniformBufferMap = appgl::interp::UniformBufferMap;
    void setUniformBuffers(const UniformBufferMap* m) { uniformBuffers_ = m; }

    // Sprint 6 Phase 1 sub-task 3 day 3 (CKPT43): caller-supplied
    // sampler-array texture data for OpImageSampleImplicit/ExplicitLod.
    // Non-null pointer → interpreter accepts OpSampledImage / OpImage*
    // ops in the body walk. Null → those ops fail isSupportedGsOpcode
    // and detection rejects the program (legacy fallback).
    void setSampledTextures(const SampledTextureMap* m) {
        sampledTextures_ = m;
    }

    // Sprint 7 Phase 1 #4 (CKPT54): caller-supplied storage-image data
    // for OpImageRead (imageLoad in GLSL). Same map shape as sampler
    // textures; distinguished by the SampledImageHandle::isStorage flag
    // set when OpAccessChain/OpLoad observes the image variable through
    // this map. Bound via the GL image-unit namespace
    // (glBindImageTexture), not sampler units.
    void setStorageImages(const SampledTextureMap* m) {
        storageImages_ = m;
    }

    // CKPT162 (Sprint 14 Day 9): drain captured imageStore() writes
    // accumulated during this interpreter's execution. Caller flushes
    // them to Metal textures via replaceRegion: after GS completes.
    std::vector<PendingImageWrite> takePendingImageWrites() {
        return std::move(pendingImageWrites_);
    }

    void setUniforms(const UniformValues* u) { uniforms_ = u; }
    void setVsInputs(const VertexAttribs* a, std::int32_t vertexID, std::int32_t instanceID) {
        vsAttribs_ = a;
        vsVertexID_ = vertexID;
        vsInstanceID_ = instanceID;
    }
    // Sprint 17 Day 7+ Bank-Group-H Path B Phase 3 day 5 — caller-supplied
    // base-name → base-Location override map for VS Input variables.
    // Used when SPIR-V's `OpDecorate <var> Location` is absent (e.g.,
    // arrays-of-floats compiled by glslang's xfb path that omits
    // per-variable Location decoration but SPIRV-Cross's reflection
    // recovers the location from the original GLSL `layout(location=N)`).
    // For array Input variables, the per-element location is computed
    // as base + element_index. Default null preserves implicit
    // auto-assign behavior for back-compat.
    void setVsInputLocationOverrides(
            const std::unordered_map<std::string, std::uint32_t>* m) {
        vsInputLocOverrides_ = m;
    }
    // GS-stage gl_PrimitiveIDIn (BuiltInPrimitiveId = 7). Populated
    // per GS invocation by the caller; the emulator's initVariables
    // seeds the GS Input variable with this value when the variable
    // carries DecorationBuiltIn=7.
    void setGsPrimitiveId(std::int32_t primId) { gsPrimitiveId_ = primId; }
    void setGsInvocationId(std::int32_t invId) { gsInvocationId_ = invId; }

    // TES-stage built-in inputs. `tessCoord` feeds BuiltInTessCoord
    // (SPIR-V enum value 13, a vec3) — for isolines only .x is the
    // parametric coord, for triangles the three components are
    // barycentric, for quads (.x, .y) are the domain coords. The
    // shader always sees a vec3, so we splat all three components.
    // `primitiveID` feeds BuiltInPrimitiveId (=7) with the patch-
    // in-draw index per GL 4.6 §11.2.3.
    void setTesInputs(const std::array<float, 3>& tessCoord,
                      std::int32_t primitiveID) {
        tesTessCoord_ = tessCoord;
        tesPrimitiveId_ = primitiveID;
    }

    // TCS-stage built-in inputs (phase 3f-4). The TCS runs once per
    // patch-output-vertex, with `invocationID` stepping through
    // [0, layout(vertices=N)). `primitiveID` is the patch-in-draw
    // index (same semantics as TES's gl_PrimitiveID per GL 4.6
    // §11.2.2). `patchVertices` is the input patch size from
    // glPatchParameteri(GL_PATCH_VERTICES, N), exposed to TCS as
    // gl_PatchVerticesIn.
	    void setTcsInputs(std::int32_t primitiveID,
	                      std::int32_t invocationID,
	                      std::int32_t patchVertices) {
	        tcsPrimitiveId_ = primitiveID;
	        tcsInvocationId_ = invocationID;
	        tcsPatchVertices_ = patchVertices;
	    }
	    void setTcsSharedOutputStorage(TcsSharedOutputStorage* storage) {
	        tcsSharedOutputStorage_ = storage;
	    }

    // Run the entry-point function once, given `inputs` as gl_in[].
    // Appends emitted vertices to `emitted`. Primitive boundaries are
    // pushed into `primEnds` — each entry is `emitted.size()` after a
    // strip ended (either via OpEndPrimitive inside the body or the
    // implicit end on OpReturn). Callers use the boundaries to expand
    // line_strip / triangle_strip output into independent list
    // topologies for Metal.
    bool execute(const std::vector<PerVertexInput>& inputs,
                 std::vector<EmulatedVertex>& emitted,
                 std::vector<std::size_t>& primEnds);

    // Thin back-compat overload for code paths that don't care about
    // strip boundaries (the VS pre-pass emits no GS primitives).
    bool execute(const std::vector<PerVertexInput>& inputs,
                 std::vector<EmulatedVertex>& emitted) {
        std::vector<std::size_t> ignored;
        return execute(inputs, emitted, ignored);
    }

    // VS entry point. Runs the body once, captures gl_Position +
    // user output varyings into the supplied record. Returns false
    // on any interpreter bail.
    bool executeVs(EmulatedVertex& out);

    // TES entry point. Same body-walk shape as VS (run once, capture
    // gl_Position + varyings + clip/cull), but initVariables is
    // given the caller's per-patch-vertex input data so gl_in[] is
    // populated from the VS pre-pass outputs. Used when the TES
    // interprets from gl_in[] (phase 3f-5). Caller fills `patchInputs`
    // — one PerVertexInput per input patch vertex.
    bool executeTes(EmulatedVertex& out,
                    const std::vector<PerVertexInput>& patchInputs);

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
    // Phase 3 day 5 input-array Location override map (see
    // setVsInputLocationOverrides). Non-owning.
    const std::unordered_map<std::string, std::uint32_t>* vsInputLocOverrides_ = nullptr;
    std::int32_t vsVertexID_ = 0;
    std::int32_t vsInstanceID_ = 0;
    std::int32_t gsPrimitiveId_ = 0;
    std::int32_t gsInvocationId_ = 0;

    // TES-stage inputs (see setTesInputs). Read by initVariables when
    // a variable is decorated BuiltInTessCoord / BuiltInPrimitiveId in
    // Stage::TessEvaluation.
    std::array<float, 3> tesTessCoord_{0.0f, 0.0f, 0.0f};
    std::int32_t tesPrimitiveId_ = 0;

    // TCS-stage inputs (see setTcsInputs). Read by initVariables when
    // a variable is decorated BuiltInPrimitiveId / BuiltInInvocationId /
    // BuiltInPatchVertices in Stage::TessControl.
    std::int32_t tcsPrimitiveId_ = 0;
    std::int32_t tcsInvocationId_ = 0;
    std::int32_t tcsPatchVertices_ = 3;

    // Phase 3f-14: caller-supplied patch-in varying map for TES.
    // Pointer so the caller controls lifetime (typically a vector
    // of maps per patch, one entry dereferenced per TES call).
    // Sprint 8 #8 β.2 Day 2 (CKPT70): keyed by NAME.
    const std::unordered_map<std::string, std::vector<float>>*
        tesPatchInputs_ = nullptr;

    // Sprint 8 #8 β.2 Day 2 (CKPT70): set of Output variable ids that
    // received at least one OpStore during the current body run.
    // Consumed by captureTcsPatchOutputs to skip overwriting an
    // existing per-patch map entry with default-zero storage from an
    // invocation whose conditional branch didn't write the variable.
    std::unordered_set<std::uint32_t> writtenOutputVars_;

    // Phase 3f-3: caller-supplied binding → (host pointer, size) map
    // for SSBO-rooted OpLoad / OpStore. Set via `setStorageBuffers`.
    // Per-variable metadata populated from the SpirvModule at
    // initVariables time (so storeSSBO/loadSSBO know which binding
    // and which element/member stride each root varId maps to).
    const StorageBufferMap* storageBuffers_ = nullptr;

    // Sprint 17 Day 4+ BONUS-2 [gpu_shader5 array-indexing]: caller-
    // supplied binding → (const host pointer, size) map for UBO
    // array dynamic-indexing in OpLoad. Sister to storageBuffers_;
    // read-only. Populated from `state.indexedBufferBinding(
    // GL_UNIFORM_BUFFER, N)` → GLBufferObject::shadowBytes by the
    // TF-capture caller (`runVsForVertex`).
    const UniformBufferMap* uniformBuffers_ = nullptr;

    // Sprint 17 Day 4+ BONUS-2: per-variable UBO array meta. Sister
    // to ssboVarMeta_ (line 477). Populated by initVariables when a
    // Uniform variable's pointee is Array(Block-Struct) — i.e. a
    // UBO array like `PositionBlock positionBlocks[4]`. Drives the
    // OpAccessChain dispatch that resolves the first index to a
    // binding (= baseBinding + idx).
    std::unordered_map<std::uint32_t, UniformBufferArrayMeta> uboArrayVarMeta_;
    // Same binding map for ordinary non-array UBO roots:
    // `layout(binding=N) uniform Block { ... } instance;`. Once
    // OpLogicalEqual made 420pack qualifier-order/binding shaders
    // interpreter-eligible, these block reads needed the same byte-
    // offset path as UBO arrays.
    std::unordered_map<std::uint32_t, UniformBufferArrayMeta> uboVarMeta_;

    // Sprint 6 P1 sub-task 3 day 3 (CKPT43): caller-supplied sampler-
    // array texture data, populated by the runtime caller (e.g.
    // emulateGeometryDraw) from program reflection + state's
    // textureUnits + MTLTexture getBytes. Keyed by SPIR-V variable id.
    const SampledTextureMap* sampledTextures_ = nullptr;

    // Sprint 7 Phase 1 #4 (CKPT54): storage-image counterpart to
    // sampledTextures_. Caller (GLContext.mm buildStorageImageMap)
    // walks the program's reflection.storageImages, looks up the
    // imageBindings[] slot that the app set via glBindImageTexture,
    // reads MTLTexture bytes, and packs into this map. Distinct from
    // sampledTextures_ because the GL binding model is different —
    // image units are a separate namespace from sampler units.
    const SampledTextureMap* storageImages_ = nullptr;
    // CKPT162 (Sprint 14 Day 9): captured imageStore() writes during
    // GS interpreter execution. Drained by takePendingImageWrites()
    // after the body walk; the runtime flushes each write to its
    // bound Metal texture via replaceRegion: so subsequent reads
    // (glGetTexImage / FS samples) see the GS-emitted data.
	    std::vector<PendingImageWrite> pendingImageWrites_;
	    TcsSharedOutputStorage* tcsSharedOutputStorage_ = nullptr;

    // Synthetic "sampled image handle" tracked through the SPIR-V
    // body walk. OpAccessChain on a sampler-array variable, OpLoad
    // on the access chain, and OpSampledImage all propagate this
    // handle so OpImageSampleExplicitLod can resolve back to the
    // (array_var_id, element_idx) pair to look up texture data.
    struct SampledImageHandle {
        std::uint32_t arrayVarId = 0;
        // Element index — for non-array samplers always 0; for sampler
        // arrays, the index from OpAccessChain. Constant indices are
        // captured at compile time; non-constant indices (from
        // gl_VertexID-driven loops) are evaluated at OpAccessChain
        // time from the loaded index value.
        std::uint32_t elementIdx = 0;
        // Sprint 7 Phase 1 #4 (CKPT54): true when this handle was
        // minted from a storage-image variable (via storageImages_
        // map). OpImageRead resolves slot data from storageImages_
        // when set; false uses sampledTextures_. Determines which
        // texture map the read goes through — the GL binding
        // namespaces are distinct (image unit vs sampler unit).
        bool isStorage = false;
    };
    std::unordered_map<std::uint32_t, SampledImageHandle> sampledImages_;
    struct StorageBufferVarMeta {
        std::uint32_t binding = 0;
        // Optional top-level struct member offsets + inner array
        // strides — filled in on demand at resolveAccessChain time
        // from the SpirvModule's decoration tables (no pre-compute
        // cache required; the TES bodies we see are small).
    };
    std::unordered_map<std::uint32_t, StorageBufferVarMeta> ssboVarMeta_;

    // Per-id SSA values for loads/arithmetic results.
    std::unordered_map<std::uint32_t, Value> valueStore_;
    // Struct-like SSA composites whose members can have different
    // scalar kinds, e.g. GLSL.std.450 FrexpStruct returns {float, int}.
    std::unordered_map<std::uint32_t, std::vector<Value>> compositeValues_;
    // Matrix SSA values are stored as column vectors. The narrow
    // interpreter Value model is four scalars wide, so mat3/mat4
    // composites need side storage for OpMatrixTimesVector.
    std::unordered_map<std::uint32_t, std::vector<Value>> matrixColumns_;

    // Per-variable flat float storage (indexed by access-chain
    // scalar offset). Float storage is universal — int/uint/bool
    // bitcast into/out of float by the load/store paths.
    std::unordered_map<std::uint32_t, std::vector<float>> varStorage_;
    // Optional precise double sidecar for float-kind values that feed
    // double-precision transform-feedback writes.
    std::unordered_map<std::uint32_t, std::vector<double>> varDoubleStorage_;

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

    // Set to true once any OpEmitVertex captures a non-nullopt
    // gl_Layer value. Read by `emulateGeometryDraw` after the
    // interpreter run to decide whether to flip
    // `EmulatedDraw::hasLayer`. A GS that never writes BuiltInLayer
    // leaves this false and the synth VS skips the
    // `[[render_target_array_index]]` output slot entirely.
    bool didWriteLayer_ = false;

    // Sprint 15 Day 10 [metal-viewport-array]: mirror for
    // BuiltInViewportIndex (sister to didWriteLayer_). Flips on when
    // any emitted vertex captures a non-nullopt gl_ViewportIndex.
    bool didWriteViewportIndex_ = false;

    // Mirror for BuiltInPointSize — flips on if any primitive's
    // emitVertex captured a non-nullopt value. Tells the draw
    // encoder whether to slot a per-vertex pointSize into the
    // packed buffer + synth VS. Not flipping preserves the
    // default-1.0 behaviour and keeps buffer stride stable for
    // non-point draws.
    bool didWritePointSize_ = false;

    // Mirror for BuiltInPrimitiveId written by the GS (OUTPUT).
    // Flips on when any emitted vertex carries a captured
    // primitive-id. The caller then packs a per-vertex int slot +
    // the FS MSL is post-processed to read the override value
    // instead of Metal's rasteriser-provided `[[primitive_id]]`.
    bool didWritePrimitiveID_ = false;

public:
    bool didWriteLayer() const { return didWriteLayer_; }
    bool didWriteViewportIndex() const { return didWriteViewportIndex_; }
    bool didWritePointSize() const { return didWritePointSize_; }
    bool didWritePrimitiveID() const { return didWritePrimitiveID_; }

    // Phase 3f-8: exposed so `runTcsForVertex` can read back
    // gl_TessLevel{Outer,Inner} writes after executeVs completes.
    // Wraps the private-section `captureTessLevels` declared below.
    bool captureTessLevelsPublic(float outer[4], float inner[2]) const {
        return captureTessLevels(outer, inner);
    }

    // Phase 3f-10: After a TCS invocation, read gl_out[invocationID]'s
    // gl_Position / gl_ClipDistance / gl_CullDistance from the
    // Output-side gl_PerVertex array's flat storage. Caller provides
    // the invocationID the body ran with (matches tcsInvocationId_).
    // Fills `out` with the captured values. Returns false if no
    // gl_PerVertex-like Output array was found. Used to stitch the
    // TCS's per-control-point outputs into the TES's gl_in[] array
    // (GL 4.6 §11.2.2 — TES's gl_in is the array of TCS gl_out).
    bool captureTcsOutputForInvocation(std::int32_t invocationID,
                                       EmulatedVertex& out) const;

    // Phase 3f-14: walk TCS Output variables decorated with
    // DecorationPatch + DecorationLocation. Copy their flat scalar
    // float storage (just-written by the body) into `out`, keyed by
    // Location. Existing entries in `out` are overwritten — the
    // caller uses the same map across all invocations of a patch,
    // yielding last-write-wins semantics (spec-permitted when two
    // TCS invocations write the same patch-out variable).
	    void captureTcsPatchOutputs(
	        std::unordered_map<std::string, std::vector<float>>& out) const;
	    void captureTcsSharedOutputs(TcsSharedOutputStorage& out) const;

    // Phase 3f-14: caller-supplied patch-in varying map for TES.
    // initVariables consults this pointer when seeding Input
    // variables with DecorationPatch. Nullptr leaves the storage at
    // its default-zero state. Sprint 8 #8 β.2 Day 2 (CKPT70): keyed
    // by variable NAME (CKPT66/69 SPIR-V two-regime distinction
    // extended to per-patch interface).
    void setTesPatchInputs(
        const std::unordered_map<std::string, std::vector<float>>* m) {
        tesPatchInputs_ = m;
    }
private:

    // Diagnostic + bail.
    void bail(std::string msg) {
        if (errored_) return;
        diagnostic_ = std::move(msg);
        errored_ = true;
    }

    void resetExecutionState();

    // Initialise variable storage for entryInterface. Called at
    // execute() start.
    void initVariables(const std::vector<PerVertexInput>& inputs);

    // Capture the current output state as an EmulatedVertex.
    // Sprint 8 #9-C (CKPT95) — `stream` defaults to 0 (OpEmitVertex).
    // OpEmitStreamVertex(N) passes the stream index from its <id>
    // operand, which is decoded from the constant Int that SPIR-V
    // requires. Per GL 4.6 §11.3.4 only stream 0 feeds the rasterizer.
    void emitVertex(std::vector<EmulatedVertex>& out, std::uint32_t stream = 0);

    // Scan Output variables for gl_ClipDistance / gl_CullDistance
    // (either direct BuiltIn or as members of a gl_PerVertex-style
    // struct) and copy the current storage values out. Callers are
    // `emitVertex` for per-vertex capture on GS emit and `executeVs`
    // for VS pre-pass output capture.
    void captureClipCull(std::vector<float>& clipOut,
                         std::vector<float>& cullOut) const;

    // Scan Output variables for gl_Layer (BuiltIn::Layer) and return
    // the current scalar value, or `std::nullopt` if the GS never
    // wrote it. Same two-shape walk as captureClipCull:
    //  1. Direct `out int gl_Layer;` — Output variable decorated
    //     BuiltInLayer, storage is a single scalar.
    //  2. Member of gl_PerVertex-style struct — MemberDecorate at
    //     some index has BuiltInLayer; we offset into the flat
    //     storage by the member's position.
    // Called from emitVertex to snapshot the per-vertex layer value
    // so the synth pass-through VS can emit
    // `[[render_target_array_index]]`.
    std::optional<std::int32_t> captureLayer() const;
    // Sprint 15 Day 10 [metal-viewport-array]: sister to captureLayer
    // for BuiltInViewportIndex (= 10). Returns nullopt if the GS
    // didn't write gl_ViewportIndex.
    std::optional<std::int32_t> captureViewportIndex() const;

    // Phase 3f-8: after a TCS invocation, scan Output variables for
    // gl_TessLevelOuter (BuiltIn = 11) and gl_TessLevelInner
    // (BuiltIn = 12) writes and copy values into the caller's
    // `outer[4]` / `inner[2]` arrays. Slots the TCS didn't write
    // are left at whatever the caller pre-seeded (typically the
    // glPatchParameterfv defaults). Returns true iff any slot was
    // updated — a signal the draw path can use to rebuild the
    // tess domain using the TCS-computed levels instead of the
    // static defaults.
    bool captureTessLevels(float outer[4], float inner[2]) const;

    // Same two-shape walk for BuiltInPointSize. `std::nullopt` when
    // the GS never writes gl_PointSize — caller keeps the default
    // 1.0. Only exercised for GL_POINTS output topology.
    std::optional<float> capturePointSize() const;

    // Same two-shape walk for BuiltInPrimitiveId on an OUTPUT (the
    // GS overwrites the FS's gl_PrimitiveID; distinct from the
    // INPUT gl_PrimitiveIDIn which we seed from gsPrimitiveId_).
    // `std::nullopt` means the GS didn't write it; the FS sees
    // Metal's rasteriser-provided [[primitive_id]] in that case.
    // Set when any vertex wrote BuiltInPrimitiveId via OpStore;
    // ed.hasPrimitiveID flips on for the whole draw and the synth
    // VS emits a flat `int` user varying that a post-processed FS
    // reads in place of `[[primitive_id]]`. Used by CTS
    // `geometry_shader.primitive_counter.primitive_id_from_fragment`.
    std::optional<std::int32_t> capturePrimitiveID() const;

    // Resolve an access-chain walk. `base` is a pointer variable id.
    // `indices` are the sequence of OpConstant id operands.
    AccessChainResult resolveAccessChain(std::uint32_t base,
                                         const std::uint32_t* indices,
                                         std::uint32_t nIndices);

    // Load scalars from var storage at [off..off+count) into a Value
    // of the leaf type.
    Value loadFromVar(std::uint32_t varId, std::uint32_t off,
                      std::uint32_t count, std::uint32_t leafTypeId);
    std::vector<Value> loadMatrixColumnsFromVar(std::uint32_t varId,
                                                std::uint32_t off,
                                                std::uint32_t matrixTypeId);

    // Store `v` into var storage at [off..off+count).
    void storeToVar(std::uint32_t varId, std::uint32_t off,
                    const Value& v);
    void storeMatrixColumnsToVar(std::uint32_t varId, std::uint32_t off,
                                 const std::vector<Value>& columns);

    // Phase 3f-3: byte-level SSBO read/write via caller-supplied
    // binding → (host ptr, size) map. leafTypeId determines how many
    // scalars to copy (1 for scalar, 2/3/4 for vec2/3/4, struct layout
    // is deferred — the access-chain walk reaches a scalar leaf in
    // the common CE test case).
    Value loadFromSSBO(std::uint32_t binding, std::uint32_t byteOffset,
                       std::uint32_t leafTypeId);
    void storeToSSBO(std::uint32_t binding, std::uint32_t byteOffset,
                     const Value& v, std::uint32_t leafTypeId);
    bool loadSSBOScalarRaw(const AccessChainResult& ac, std::uint32_t& raw);
    bool storeSSBOScalarRaw(const AccessChainResult& ac, std::uint32_t raw);
    bool executeAtomicLoad(std::uint32_t resultTypeId, std::uint32_t resultId,
                           std::uint32_t ptrId);
    bool executeAtomicStore(std::uint32_t ptrId, std::uint32_t valueId);
    bool executeAtomicRMW(std::uint32_t opcode, std::uint32_t resultTypeId,
                          std::uint32_t resultId, std::uint32_t ptrId,
                          std::uint32_t valueId,
                          std::uint32_t comparatorId = 0);
    Value atomicResultValue(std::uint32_t resultTypeId, std::uint32_t raw) const;
    bool rawScalarFromValue(std::uint32_t valueId, std::uint32_t& raw);

    // Sprint 17 Day 4+ BONUS-2: byte-level UBO read via caller-supplied
    // binding → (const host ptr, size) map. Read-only — UBOs are
    // immutable per GL spec; no store counterpart. leafTypeId
    // determines scalar/vec layout (std140 default; extends to
    // std430 in Phase 4 if surfaced). Sister to loadFromSSBO.
    Value loadFromUBO(std::uint32_t binding, std::uint32_t byteOffset,
                      std::uint32_t leafTypeId);
    std::vector<Value> loadMatrixColumnsFromUBO(std::uint32_t binding,
                                                std::uint32_t byteOffset,
                                                std::uint32_t matrixTypeId,
                                                std::uint32_t matrixStride);

    // Apply GLSL.std.450 extended instruction.
    Value evalExtInst(std::uint32_t glslOp, const std::uint32_t* operands,
                      std::uint32_t nOperands, bool resultIsDouble);

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

    // Phase 3f-3: check whether the root variable is an SSBO. Two
    // spellings of an SSBO in SPIR-V:
    //   (a) StorageClassStorageBuffer (SPV_KHR_storage_buffer_storage_class,
    //       the default since glslang 7 / GLSL 4.30+ / SPIR-V 1.3).
    //   (b) StorageClassUniform with BufferBlock decoration on the
    //       pointee struct type (the pre-extension spelling).
    // Either way, the caller's binding map is keyed by the
    // DecorationBinding value on the VARIABLE.
    const auto& varInfo = vIt->second;
    bool rootIsSSBO = false;
    std::uint32_t rootBinding = 0;
    if (varInfo.storageClass == spv::StorageClassStorageBuffer) {
        rootIsSSBO = true;
    } else if (varInfo.storageClass == spv::StorageClassUniform) {
        auto pIt = module_.types.find(tIt->second.pointeeType);
        if (pIt != module_.types.end()) {
            auto dIt = module_.decorations.find(tIt->second.pointeeType);
            if (dIt != module_.decorations.end() && dIt->second.isBufferBlock) {
                rootIsSSBO = true;
            }
        }
    }
    if (rootIsSSBO) {
        auto dIt = module_.decorations.find(base);
        if (dIt != module_.decorations.end() && dIt->second.hasBinding) {
            rootBinding = dIt->second.binding;
        }
    }

    // Sprint 17 Day 4+ BONUS-2 [gpu_shader5 array-indexing]: detect
    // UBO array root via the per-variable meta populated at
    // initVariables time. The first access-chain index resolves to a
    // binding (= baseBinding + idx). Subsequent indices accumulate
    // byteOffset within the indexed buffer using the same SSBO-path
    // member-offset / array-stride rules (std140 layout for UBOs).
    auto uboMetaIt = uboArrayVarMeta_.find(base);
    const bool rootIsUboArray = (uboMetaIt != uboArrayVarMeta_.end());
    auto uboBlockMetaIt = uboVarMeta_.find(base);
    const bool rootIsUBO = (uboBlockMetaIt != uboVarMeta_.end());
    std::uint32_t uboArrayElemBinding = 0;
    bool uboFirstIndexResolved = false;

    std::uint32_t curType = tIt->second.pointeeType;   // deref pointer
    std::uint32_t offset = 0;         // scalar offset (non-SSBO path)
    std::uint32_t byteOffset = 0;     // byte offset (SSBO / UBO path)
    std::uint32_t activeMatrixStride = 0;
    std::uint32_t resolvedMatrixStride = 0;
    auto scalarByteWidth = [&](std::uint32_t typeId) -> std::uint32_t {
        std::uint32_t cur = typeId;
        for (int depth = 0; depth < 8; ++depth) {
            auto it = module_.types.find(cur);
            if (it == module_.types.end()) return 4u;
            const TypeInfo& ti = it->second;
            switch (ti.kind) {
                case TypeInfo::Kind::Float:
                case TypeInfo::Kind::Int:
                case TypeInfo::Kind::UInt:
                case TypeInfo::Kind::Bool:
                    return std::max<std::uint32_t>(ti.elementScalarWidth, 4u);
                case TypeInfo::Kind::Vec2:
                case TypeInfo::Kind::Vec3:
                case TypeInfo::Kind::Vec4:
                case TypeInfo::Kind::Matrix:
                case TypeInfo::Kind::Array:
                case TypeInfo::Kind::RuntimeArray:
                    cur = ti.componentType;
                    break;
                case TypeInfo::Kind::Pointer:
                    cur = ti.pointeeType;
                    break;
                default:
                    return 4u;
            }
        }
        return 4u;
    };
    auto matrixColumnStrideBytes = [&](std::uint32_t matrixTypeId,
                                       std::uint32_t decoratedStride,
                                       bool std140Like) -> std::uint32_t {
        if (decoratedStride != 0) return decoratedStride;
        auto mIt = module_.types.find(matrixTypeId);
        if (mIt == module_.types.end() ||
            mIt->second.kind != TypeInfo::Kind::Matrix) {
            return 0;
        }
        const std::uint32_t scalarBytes =
            scalarByteWidth(mIt->second.componentType);
        const std::uint32_t columnScalars =
            module_.scalarWidth(mIt->second.componentType);
        std::uint32_t stride = columnScalars * scalarBytes;
        if (std140Like) {
            stride = ((stride + 15u) / 16u) * 16u;
        }
        return stride == 0 ? 4u : stride;
    };
    auto decoratedMatrixStrideForType = [&](std::uint32_t typeId) -> std::uint32_t {
        auto dIt = module_.decorations.find(typeId);
        if (dIt != module_.decorations.end() && dIt->second.hasMatrixStride) {
            return dIt->second.matrixStride;
        }
        return 0;
    };

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
        if (t.kind == TypeInfo::Kind::Array ||
            t.kind == TypeInfo::Kind::RuntimeArray) {
            const std::uint32_t elemW = module_.scalarWidth(t.componentType);
            // BONUS-2: for UBO array root, the FIRST array index
            // dispatches to a separate binding (each array element
            // is a distinct GL UBO bound at baseBinding+idx). Don't
            // accumulate byte offset across the dispatch — buffer
            // selection is the entire effect of this index.
            // Subsequent indices (struct member, nested array) walk
            // within the selected buffer per std140 byte rules below.
            if (rootIsUboArray && !uboFirstIndexResolved) {
                uboArrayElemBinding =
                    uboMetaIt->second.baseBinding +
                    static_cast<std::uint32_t>(idx);
                uboFirstIndexResolved = true;
                curType = t.componentType;
                continue;
            }
            offset += static_cast<std::uint32_t>(idx) * elemW;
            // SSBO byte offset: use DecorationArrayStride on the array
            // type, else fall back to scalar-width * 4 bytes (covers
            // packed scalar arrays).
            if (rootIsSSBO || rootIsUboArray || rootIsUBO) {
                std::uint32_t stride = 0;
                auto dIt = module_.decorations.find(curType);
                if (dIt != module_.decorations.end() && dIt->second.hasArrayStride) {
                    stride = dIt->second.arrayStride;
                }
                if (stride == 0) {
                    // Fallback: scalar-width * 4 bytes (std430-style
                    // packed). UBO arrays nested below the dispatch
                    // index typically carry DecorationArrayStride from
                    // glslang per std140; fallback only fires for the
                    // bare-scalar-array edge case.
                    stride = elemW * 4u;
                    if (stride == 0) stride = 4;
                }
                byteOffset += static_cast<std::uint32_t>(idx) * stride;
            }
            curType = t.componentType;
        } else if (t.kind == TypeInfo::Kind::Struct) {
            if (static_cast<std::uint32_t>(idx) >= t.memberTypes.size()) {
                bail("access-chain struct index out of range"); return r;
            }
            for (std::uint32_t m = 0; m < static_cast<std::uint32_t>(idx); ++m) {
                offset += module_.scalarWidth(t.memberTypes[m]);
            }
            // SSBO/UBO byte offset: read DecorationOffset from member
            // decorations. glslang always emits this for every SSBO /
            // UBO struct member (per spec — required for std140/std430
            // member layouts to be unambiguous).
            if (rootIsSSBO || rootIsUboArray || rootIsUBO) {
                auto mdIt = module_.memberDecorations.find(curType);
                activeMatrixStride = 0;
                if (mdIt != module_.memberDecorations.end()) {
                    auto pIt2 = mdIt->second.perMember.find(
                        static_cast<std::uint32_t>(idx));
                    if (pIt2 != mdIt->second.perMember.end()) {
                        if (pIt2->second.hasOffset) {
                            byteOffset += pIt2->second.offset;
                        }
                        if (pIt2->second.hasMatrixStride) {
                            activeMatrixStride = pIt2->second.matrixStride;
                        }
                    }
                }
            }
            curType = t.memberTypes[idx];
        } else if (t.kind == TypeInfo::Kind::Vec2 || t.kind == TypeInfo::Kind::Vec3 ||
                   t.kind == TypeInfo::Kind::Vec4) {
            offset += static_cast<std::uint32_t>(idx);
            if (rootIsSSBO || rootIsUboArray || rootIsUBO) {
                byteOffset +=
                    static_cast<std::uint32_t>(idx) *
                    scalarByteWidth(t.componentType);
            }
            curType = t.componentType;
        } else if (t.kind == TypeInfo::Kind::Matrix) {
            const std::uint32_t colW = module_.scalarWidth(t.componentType);
            offset += static_cast<std::uint32_t>(idx) * colW;
            if (rootIsSSBO || rootIsUboArray || rootIsUBO) {
                const std::uint32_t decoratedStride =
                    activeMatrixStride != 0
                        ? activeMatrixStride
                        : decoratedMatrixStrideForType(curType);
                const std::uint32_t stride = matrixColumnStrideBytes(
                    curType, decoratedStride, (rootIsUboArray || rootIsUBO));
                resolvedMatrixStride = stride;
                byteOffset +=
                    static_cast<std::uint32_t>(idx) * stride;
            }
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
    r.isStorageBuffer = rootIsSSBO;
    r.byteOffset = byteOffset;
    r.binding = rootBinding;
    if (rootIsSSBO || rootIsUboArray || rootIsUBO) {
        auto leafTIt = module_.types.find(curType);
        if (leafTIt != module_.types.end() &&
            leafTIt->second.kind == TypeInfo::Kind::Matrix) {
            const std::uint32_t decoratedStride =
                activeMatrixStride != 0
                    ? activeMatrixStride
                    : decoratedMatrixStrideForType(curType);
            resolvedMatrixStride = matrixColumnStrideBytes(
                curType, decoratedStride, (rootIsUboArray || rootIsUBO));
        }
        if (resolvedMatrixStride != 0) {
            r.hasMatrixStride = true;
            r.matrixStride = resolvedMatrixStride;
        }
    }
    // Sprint 17 Day 4+ BONUS-2: when the root is a UBO array, the
    // resolved binding came from the first array index dispatch
    // (uboArrayElemBinding). Override `binding` and flip
    // `isUniformBuffer` so OpLoad routes through `uniformBuffers_`.
    // The byteOffset accumulated above (struct member / vec
    // component / nested array) addresses within the indexed
    // buffer.
    if (rootIsUboArray && uboFirstIndexResolved) {
        r.isUniformBuffer = true;
        r.binding = uboArrayElemBinding;
    } else if (rootIsUBO) {
        r.isUniformBuffer = true;
        r.binding = uboBlockMetaIt->second.baseBinding;
    }
    return r;
}

Value Interpreter::loadFromVar(std::uint32_t varId, std::uint32_t off,
                               std::uint32_t /*count*/, std::uint32_t leafTypeId) {
    Value v;
    auto sIt = varStorage_.find(varId);
    if (sIt == varStorage_.end()) return v;
    const auto& storage = sIt->second;
    auto tIt = module_.types.find(leafTypeId);
    if (tIt == module_.types.end()) {
        auto vIt = module_.variables.find(varId);
        std::string name = (vIt != module_.variables.end()) ? vIt->second.name : std::string();
        bail("load: unknown leaf type var=" + std::to_string(varId) +
             " name='" + name + "' leaf=" + std::to_string(leafTypeId));
        return v;
    }
    const TypeInfo& t = tIt->second;
    if (off >= storage.size()) { bail("load: offset OOB"); return v; }

    // Helper: the vector Kind in TypeInfo doesn't remember its
    // component base type — a glslang-produced ivec2 and a vec2 both
    // come through as Kind::Vec2 but differ in componentType. Peek
    // at the component type to decide whether to return Float* or
    // Int*/UInt* flavoured Values. Matters for `uniform ivec2
    // renderingTargetSize.y == 45` (used by every rendering-section
    // test's VS) — the int comparison must see int bits, not floats.
    auto componentIsInt  = [&](std::uint32_t compTypeId) -> bool {
        auto cIt = module_.types.find(compTypeId);
        if (cIt == module_.types.end()) return false;
        return cIt->second.kind == TypeInfo::Kind::Int;
    };
    auto componentIsUInt = [&](std::uint32_t compTypeId) -> bool {
        auto cIt = module_.types.find(compTypeId);
        if (cIt == module_.types.end()) return false;
        return cIt->second.kind == TypeInfo::Kind::UInt;
    };

    switch (t.kind) {
        case TypeInfo::Kind::Float:
            v.kind = Value::Kind::Float;
            v.f[0] = storage[off];
            break;
        case TypeInfo::Kind::Vec2:
            if (componentIsInt(t.componentType)) {
                v.kind = Value::Kind::Int2;
                for (int k = 0; k < 2; ++k) std::memcpy(&v.i[k], &storage[off + k], 4);
            } else if (componentIsUInt(t.componentType)) {
                v.kind = Value::Kind::UInt2;
                for (int k = 0; k < 2; ++k) std::memcpy(&v.i[k], &storage[off + k], 4);
            } else {
                v.kind = Value::Kind::Float2;
                for (int k = 0; k < 2; ++k) v.f[k] = storage[off + k];
            }
            break;
        case TypeInfo::Kind::Vec3:
            if (componentIsInt(t.componentType)) {
                v.kind = Value::Kind::Int3;
                for (int k = 0; k < 3; ++k) std::memcpy(&v.i[k], &storage[off + k], 4);
            } else if (componentIsUInt(t.componentType)) {
                v.kind = Value::Kind::UInt3;
                for (int k = 0; k < 3; ++k) std::memcpy(&v.i[k], &storage[off + k], 4);
            } else {
                v.kind = Value::Kind::Float3;
                for (int k = 0; k < 3; ++k) v.f[k] = storage[off + k];
            }
            break;
        case TypeInfo::Kind::Vec4:
            if (componentIsInt(t.componentType)) {
                v.kind = Value::Kind::Int4;
                for (int k = 0; k < 4; ++k) std::memcpy(&v.i[k], &storage[off + k], 4);
            } else if (componentIsUInt(t.componentType)) {
                v.kind = Value::Kind::UInt4;
                for (int k = 0; k < 4; ++k) std::memcpy(&v.i[k], &storage[off + k], 4);
            } else {
                v.kind = Value::Kind::Float4;
                for (int k = 0; k < 4; ++k) v.f[k] = storage[off + k];
            }
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
        case TypeInfo::Kind::Bool: {
            // SPIR-V disallows Bool in Uniform storage; glslang
            // lowers `uniform bool` to uint32 (0/1). But Private /
            // Function-local bool is perfectly legal, and shows up
            // whenever a boolean expression feeds an OpStore (e.g.
            // `bool is_top = (position.z == 0.0);`). Storage here
            // is a single scalar; non-zero → true.
            v.kind = Value::Kind::Bool;
            std::int32_t iv = 0;
            std::memcpy(&iv, &storage[off], 4);
            v.bval = (iv != 0);
            break;
        }
        default:
            bail("load: unsupported leaf kind");
    }
    if (v.isFloatKind()) {
        const auto dIt = varDoubleStorage_.find(varId);
        if (dIt != varDoubleStorage_.end()) {
            const auto& dStorage = dIt->second;
            if (off < dStorage.size()) {
                v.hasDouble = true;
                for (int k = 0; k < v.componentCount(); ++k) {
                    const std::uint32_t idx = off + static_cast<std::uint32_t>(k);
                    v.d[k] = idx < dStorage.size()
                        ? dStorage[idx] : static_cast<double>(v.f[k]);
                }
            }
        }
        if (!v.hasDouble) {
            for (int k = 0; k < v.componentCount(); ++k) {
                v.d[k] = static_cast<double>(v.f[k]);
            }
        }
    }
    return v;
}

std::vector<Value> Interpreter::loadMatrixColumnsFromVar(
    std::uint32_t varId,
    std::uint32_t off,
    std::uint32_t matrixTypeId)
{
    std::vector<Value> columns;
    auto sIt = varStorage_.find(varId);
    if (sIt == varStorage_.end()) return columns;
    const auto& storage = sIt->second;
    auto tIt = module_.types.find(matrixTypeId);
    if (tIt == module_.types.end() ||
        tIt->second.kind != TypeInfo::Kind::Matrix) {
        return columns;
    }
    const TypeInfo& matrix = tIt->second;
    auto cIt = module_.types.find(matrix.componentType);
    if (cIt == module_.types.end()) return columns;
    const TypeInfo& columnType = cIt->second;
    int rows = 1;
    switch (columnType.kind) {
        case TypeInfo::Kind::Vec2: rows = 2; break;
        case TypeInfo::Kind::Vec3: rows = 3; break;
        case TypeInfo::Kind::Vec4: rows = 4; break;
        default: rows = 1; break;
    }
    columns.reserve(matrix.count);
    for (std::uint32_t col = 0; col < matrix.count; ++col) {
        Value v;
        v.kind = rows == 2 ? Value::Kind::Float2
               : rows == 3 ? Value::Kind::Float3
               : rows == 4 ? Value::Kind::Float4
                            : Value::Kind::Float;
        for (int row = 0; row < rows; ++row) {
            const std::uint32_t idx = off + col * static_cast<std::uint32_t>(rows)
                                    + static_cast<std::uint32_t>(row);
            v.f[row] = idx < storage.size() ? storage[idx] : 0.0f;
        }
        columns.push_back(v);
    }
    return columns;
}

void Interpreter::storeToVar(std::uint32_t varId, std::uint32_t off,
                             const Value& v) {
    auto& storage = varStorage_[varId];
    if (off + static_cast<std::uint32_t>(v.componentCount()) > storage.size()) {
        storage.resize(off + v.componentCount(), 0.0f);
    }
    if (v.isFloatKind()) {
        for (int k = 0; k < v.componentCount(); ++k) storage[off + k] = v.f[k];
        auto dIt = varDoubleStorage_.find(varId);
        if (v.hasDouble || dIt != varDoubleStorage_.end()) {
            auto& dStorage = (dIt != varDoubleStorage_.end())
                ? dIt->second
                : varDoubleStorage_[varId];
            if (off + static_cast<std::uint32_t>(v.componentCount()) > dStorage.size()) {
                dStorage.resize(off + v.componentCount(), 0.0);
            }
            for (int k = 0; k < v.componentCount(); ++k) {
                dStorage[off + k] = v.hasDouble ? v.d[k] : static_cast<double>(v.f[k]);
            }
        }
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
    // Sprint 8 #8 β.2 Day 2 (CKPT70): track which variables had at
    // least one OpStore during this body's execution. Used by
    // captureTcsPatchOutputs to skip overwriting existing patch-out
    // map entries with zero-initialised storage from invocations
    // whose conditional branch didn't write the variable. Without
    // this tracking, data_pass_through TCS's
    //   `if (gl_InvocationID == 0) { tc_patch_data = ...; }`
    // had its non-zero invocation-0 write clobbered by invocation-1's
    // unwritten zero storage when both invocations' captures merged
    // into the same per-patch map.
    writtenOutputVars_.insert(varId);
}

void Interpreter::storeMatrixColumnsToVar(std::uint32_t varId,
                                          std::uint32_t off,
                                          const std::vector<Value>& columns)
{
    auto& storage = varStorage_[varId];
    std::uint32_t width = 0;
    for (const auto& column : columns) {
        width += static_cast<std::uint32_t>(column.componentCount());
    }
    if (off + width > storage.size()) {
        storage.resize(off + width, 0.0f);
    }
    std::uint32_t cursor = off;
    for (const auto& column : columns) {
        for (int k = 0; k < column.componentCount(); ++k) {
            storage[cursor++] = column.f[k];
        }
    }
    writtenOutputVars_.insert(varId);
}

// ─── Phase 3f-3: byte-level SSBO load/store ──────────────────────────
//
// Leaf type drives scalar count + kind. Scalars, vec2, vec3, vec4 at
// the access-chain leaf. Each scalar is 4 bytes; vec3 is packed as 12
// bytes (std430 leaf access — the "aligned to 16" rule applies to the
// parent array/struct stride, which resolveAccessChain already
// consumed via DecorationArrayStride / DecorationOffset).

Value Interpreter::loadFromSSBO(std::uint32_t binding,
                                std::uint32_t byteOffset,
                                std::uint32_t leafTypeId)
{
    Value v;
    if (storageBuffers_ == nullptr) {
        bail("loadFromSSBO: no storage buffer map set");
        return v;
    }
    auto bIt = storageBuffers_->find(binding);
    if (bIt == storageBuffers_->end() || bIt->second.ptr == nullptr) {
        // Binding unbound: return zero (GL 4.6 §7.8 — writes to an
        // unbound SSBO are silently ignored; reads are undefined
        // but zero is a safe choice). Not a hard failure.
        auto tIt = module_.types.find(leafTypeId);
        if (tIt != module_.types.end()) {
            switch (tIt->second.kind) {
                case TypeInfo::Kind::Int:   v.kind = Value::Kind::Int;   break;
                case TypeInfo::Kind::UInt:  v.kind = Value::Kind::UInt;  break;
                case TypeInfo::Kind::Bool:  v.kind = Value::Kind::Bool;  break;
                case TypeInfo::Kind::Vec2:  v.kind = Value::Kind::Float2; break;
                case TypeInfo::Kind::Vec3:  v.kind = Value::Kind::Float3; break;
                case TypeInfo::Kind::Vec4:  v.kind = Value::Kind::Float4; break;
                default:                    v.kind = Value::Kind::Float;  break;
            }
        }
        return v;
    }
    const std::uint8_t* base = static_cast<const std::uint8_t*>(bIt->second.ptr);
    const std::size_t   size = bIt->second.size;

    auto readScalar = [&](std::uint32_t off) -> std::uint32_t {
        if (off + 4 > size) return 0;
        std::uint32_t raw = 0;
        std::memcpy(&raw, base + off, 4);
        return raw;
    };

    auto tIt = module_.types.find(leafTypeId);
    if (tIt == module_.types.end()) {
        bail("loadFromSSBO: unknown leaf type");
        return v;
    }
    const TypeInfo& t = tIt->second;

    auto leafIsInt = [&]() -> bool {
        if (t.kind == TypeInfo::Kind::Int)  return true;
        if (t.kind == TypeInfo::Kind::UInt) return true;
        if (t.kind == TypeInfo::Kind::Vec2 || t.kind == TypeInfo::Kind::Vec3 ||
            t.kind == TypeInfo::Kind::Vec4) {
            auto cIt = module_.types.find(t.componentType);
            if (cIt != module_.types.end()) {
                return cIt->second.kind == TypeInfo::Kind::Int ||
                       cIt->second.kind == TypeInfo::Kind::UInt;
            }
        }
        return false;
    };
    auto leafIsUInt = [&]() -> bool {
        if (t.kind == TypeInfo::Kind::UInt) return true;
        if (t.kind == TypeInfo::Kind::Vec2 || t.kind == TypeInfo::Kind::Vec3 ||
            t.kind == TypeInfo::Kind::Vec4) {
            auto cIt = module_.types.find(t.componentType);
            if (cIt != module_.types.end()) {
                return cIt->second.kind == TypeInfo::Kind::UInt;
            }
        }
        return false;
    };

    const int n = (t.kind == TypeInfo::Kind::Vec4)  ? 4 :
                  (t.kind == TypeInfo::Kind::Vec3)  ? 3 :
                  (t.kind == TypeInfo::Kind::Vec2)  ? 2 : 1;

    const bool isInt  = leafIsInt();
    const bool isUInt = leafIsUInt();

    if (isInt) {
        v.kind = isUInt ? (n == 1 ? Value::Kind::UInt :
                           n == 2 ? Value::Kind::UInt2 :
                           n == 3 ? Value::Kind::UInt3 : Value::Kind::UInt4)
                        : (n == 1 ? Value::Kind::Int :
                           n == 2 ? Value::Kind::Int2 :
                           n == 3 ? Value::Kind::Int3 : Value::Kind::Int4);
        for (int k = 0; k < n; ++k) {
            std::uint32_t raw = readScalar(byteOffset + k * 4);
            std::memcpy(&v.i[k], &raw, 4);
        }
    } else if (t.kind == TypeInfo::Kind::Bool) {
        std::uint32_t raw = readScalar(byteOffset);
        v.kind = Value::Kind::Bool;
        v.bval = (raw != 0);
    } else {
        v.kind = (n == 1 ? Value::Kind::Float  :
                  n == 2 ? Value::Kind::Float2 :
                  n == 3 ? Value::Kind::Float3 : Value::Kind::Float4);
        for (int k = 0; k < n; ++k) {
            std::uint32_t raw = readScalar(byteOffset + k * 4);
            float f = 0.0f;
            std::memcpy(&f, &raw, 4);
            v.f[k] = f;
        }
    }
    return v;
}

// Sprint 17 Day 4+ BONUS-2 [gpu_shader5 array-indexing]: byte-level
// UBO read via caller-supplied binding → (const ptr, size) map.
// Sister to `loadFromSSBO` above (~30 LOC of mirrored read paths).
// Read-only — UBOs are immutable per GL spec; no storeToUBO. Layout
// rules: std140 by default. For Phase 1 target uniform_blocks_array_
// indexing, vec4 leaf is layout-invariant (std140 == std430). Defer
// std140 col-major-matrix / array-stride-16 distinctions to Phase 4
// if surfaced.
Value Interpreter::loadFromUBO(std::uint32_t binding,
                               std::uint32_t byteOffset,
                               std::uint32_t leafTypeId)
{
    Value v;
    if (uniformBuffers_ == nullptr) {
        bail("loadFromUBO: no UBO map set");
        return v;
    }
    auto bIt = uniformBuffers_->find(binding);
    if (bIt == uniformBuffers_->end() || bIt->second.ptr == nullptr) {
        // Unbound binding: return zeros (sister to loadFromSSBO defensive
        // path). Spec is undefined for unbound UBO reads but zeros are
        // the GL-conformant safe choice.
        auto tIt = module_.types.find(leafTypeId);
        if (tIt != module_.types.end()) {
            switch (tIt->second.kind) {
                case TypeInfo::Kind::Int:   v.kind = Value::Kind::Int;   break;
                case TypeInfo::Kind::UInt:  v.kind = Value::Kind::UInt;  break;
                case TypeInfo::Kind::Bool:  v.kind = Value::Kind::Bool;  break;
                case TypeInfo::Kind::Vec2:  v.kind = Value::Kind::Float2; break;
                case TypeInfo::Kind::Vec3:  v.kind = Value::Kind::Float3; break;
                case TypeInfo::Kind::Vec4:  v.kind = Value::Kind::Float4; break;
                default:                    v.kind = Value::Kind::Float;  break;
            }
        }
        return v;
    }
    const std::uint8_t* base = bIt->second.ptr;
    const std::size_t size = bIt->second.size;

    auto readScalar = [&](std::uint32_t off) -> std::uint32_t {
        if (off + 4 > size) return 0;
        std::uint32_t raw = 0;
        std::memcpy(&raw, base + off, 4);
        return raw;
    };
    auto readFloatScalar = [&](std::uint32_t off,
                               std::uint32_t scalarBytes) -> float {
        if (scalarBytes == 8u) {
            if (off + sizeof(double) > size) return 0.0f;
            double d = 0.0;
            std::memcpy(&d, base + off, sizeof(d));
            return static_cast<float>(d);
        }
        std::uint32_t raw = readScalar(off);
        float f = 0.0f;
        std::memcpy(&f, &raw, 4);
        return f;
    };

    auto tIt = module_.types.find(leafTypeId);
    if (tIt == module_.types.end()) {
        bail("loadFromUBO: unknown leaf type");
        return v;
    }
    const TypeInfo& t = tIt->second;

    auto leafIsInt = [&]() -> bool {
        if (t.kind == TypeInfo::Kind::Int)  return true;
        if (t.kind == TypeInfo::Kind::UInt) return true;
        if (t.kind == TypeInfo::Kind::Vec2 || t.kind == TypeInfo::Kind::Vec3 ||
            t.kind == TypeInfo::Kind::Vec4) {
            auto cIt = module_.types.find(t.componentType);
            if (cIt != module_.types.end()) {
                return cIt->second.kind == TypeInfo::Kind::Int ||
                       cIt->second.kind == TypeInfo::Kind::UInt;
            }
        }
        return false;
    };
    auto leafIsUInt = [&]() -> bool {
        if (t.kind == TypeInfo::Kind::UInt) return true;
        if (t.kind == TypeInfo::Kind::Vec2 || t.kind == TypeInfo::Kind::Vec3 ||
            t.kind == TypeInfo::Kind::Vec4) {
            auto cIt = module_.types.find(t.componentType);
            if (cIt != module_.types.end()) {
                return cIt->second.kind == TypeInfo::Kind::UInt;
            }
        }
        return false;
    };

    const std::uint32_t scalarBytes = [&]() -> std::uint32_t {
        if (t.kind == TypeInfo::Kind::Vec2 || t.kind == TypeInfo::Kind::Vec3 ||
            t.kind == TypeInfo::Kind::Vec4) {
            auto cIt = module_.types.find(t.componentType);
            if (cIt != module_.types.end()) {
                return std::max<std::uint32_t>(cIt->second.elementScalarWidth, 4u);
            }
        }
        return std::max<std::uint32_t>(t.elementScalarWidth, 4u);
    }();

    const int n = (t.kind == TypeInfo::Kind::Vec4) ? 4 :
                  (t.kind == TypeInfo::Kind::Vec3) ? 3 :
                  (t.kind == TypeInfo::Kind::Vec2) ? 2 : 1;
    if (leafIsInt()) {
        v.kind = (n == 1 ? (leafIsUInt() ? Value::Kind::UInt : Value::Kind::Int) :
                  n == 2 ? (leafIsUInt() ? Value::Kind::UInt2 : Value::Kind::Int2) :
                  n == 3 ? (leafIsUInt() ? Value::Kind::UInt3 : Value::Kind::Int3) :
                           (leafIsUInt() ? Value::Kind::UInt4 : Value::Kind::Int4));
        for (int k = 0; k < n; ++k) {
            std::uint32_t raw = readScalar(byteOffset + k * 4);
            std::memcpy(&v.i[k], &raw, 4);
        }
    } else {
        v.kind = (n == 1 ? Value::Kind::Float :
                  n == 2 ? Value::Kind::Float2 :
                  n == 3 ? Value::Kind::Float3 : Value::Kind::Float4);
        for (int k = 0; k < n; ++k) {
            v.f[k] = readFloatScalar(
                byteOffset + static_cast<std::uint32_t>(k) * scalarBytes,
                scalarBytes);
        }
    }
    return v;
}

std::vector<Value> Interpreter::loadMatrixColumnsFromUBO(
    std::uint32_t binding,
    std::uint32_t byteOffset,
    std::uint32_t matrixTypeId,
    std::uint32_t matrixStride)
{
    std::vector<Value> columns;
    auto mIt = module_.types.find(matrixTypeId);
    if (mIt == module_.types.end() ||
        mIt->second.kind != TypeInfo::Kind::Matrix) {
        bail("loadMatrixColumnsFromUBO: unknown matrix type");
        return columns;
    }
    const TypeInfo& matrix = mIt->second;
    auto cIt = module_.types.find(matrix.componentType);
    if (cIt == module_.types.end()) {
        bail("loadMatrixColumnsFromUBO: unknown column type");
        return columns;
    }
    const TypeInfo& columnType = cIt->second;

    int rows = 1;
    switch (columnType.kind) {
        case TypeInfo::Kind::Vec2: rows = 2; break;
        case TypeInfo::Kind::Vec3: rows = 3; break;
        case TypeInfo::Kind::Vec4: rows = 4; break;
        default: rows = 1; break;
    }

    std::uint32_t scalarBytes = 4;
    auto scalarIt = module_.types.find(columnType.componentType);
    if (scalarIt != module_.types.end()) {
        scalarBytes = std::max<std::uint32_t>(
            scalarIt->second.elementScalarWidth, 4u);
    }
    if (matrixStride == 0) {
        const std::uint32_t packedBytes =
            static_cast<std::uint32_t>(rows) * scalarBytes;
        matrixStride = ((packedBytes + 15u) / 16u) * 16u;
    }

    const std::uint8_t* base = nullptr;
    std::size_t size = 0;
    if (uniformBuffers_ == nullptr) {
        bail("loadMatrixColumnsFromUBO: no UBO map set");
    } else {
        auto bIt = uniformBuffers_->find(binding);
        if (bIt != uniformBuffers_->end()) {
            base = bIt->second.ptr;
            size = bIt->second.size;
        }
    }

    auto readFloatScalar = [&](std::uint32_t off) -> float {
        if (base == nullptr) return 0.0f;
        if (scalarBytes == 8u) {
            if (off + sizeof(double) > size) return 0.0f;
            double d = 0.0;
            std::memcpy(&d, base + off, sizeof(d));
            return static_cast<float>(d);
        }
        if (off + sizeof(float) > size) return 0.0f;
        float f = 0.0f;
        std::memcpy(&f, base + off, sizeof(f));
        return f;
    };

    columns.reserve(matrix.count);
    for (std::uint32_t col = 0; col < matrix.count; ++col) {
        Value v;
        v.kind = rows == 2 ? Value::Kind::Float2
               : rows == 3 ? Value::Kind::Float3
               : rows == 4 ? Value::Kind::Float4
                            : Value::Kind::Float;
        for (int row = 0; row < rows; ++row) {
            const std::uint32_t off =
                byteOffset + col * matrixStride +
                static_cast<std::uint32_t>(row) * scalarBytes;
            v.f[row] = readFloatScalar(off);
        }
        columns.push_back(v);
    }
    return columns;
}

void Interpreter::storeToSSBO(std::uint32_t binding,
                              std::uint32_t byteOffset,
                              const Value& v,
                              std::uint32_t leafTypeId)
{
    (void)leafTypeId;   // leaf drives the scalar count via v.componentCount()
    if (storageBuffers_ == nullptr) return;   // silent no-op
    auto bIt = storageBuffers_->find(binding);
    if (bIt == storageBuffers_->end() || bIt->second.ptr == nullptr) return;
    std::uint8_t* base = static_cast<std::uint8_t*>(bIt->second.ptr);
    const std::size_t size = bIt->second.size;

    const int n = v.componentCount();
    auto writeScalar = [&](std::uint32_t off, std::uint32_t raw) {
        if (off + 4 > size) return;
        std::memcpy(base + off, &raw, 4);
    };

    if (v.isFloatKind()) {
        for (int k = 0; k < n; ++k) {
            std::uint32_t raw = 0;
            std::memcpy(&raw, &v.f[k], 4);
            writeScalar(byteOffset + k * 4, raw);
        }
    } else if (v.isIntKind()) {
        for (int k = 0; k < n; ++k) {
            std::uint32_t raw = 0;
            std::memcpy(&raw, &v.i[k], 4);
            writeScalar(byteOffset + k * 4, raw);
        }
    } else if (v.kind == Value::Kind::Bool) {
        std::uint32_t raw = v.bval ? 1u : 0u;
        writeScalar(byteOffset, raw);
    } else {
        bail("storeToSSBO: unsupported value kind");
    }
}

bool Interpreter::loadSSBOScalarRaw(const AccessChainResult& ac,
                                    std::uint32_t& raw)
{
    raw = 0;
    if (!ac.isStorageBuffer) {
        bail("atomicSSBO: pointer is not an SSBO access chain");
        return false;
    }
    if (storageBuffers_ == nullptr) {
        bail("atomicSSBO: no storage buffer map set");
        return false;
    }
    auto bIt = storageBuffers_->find(ac.binding);
    if (bIt == storageBuffers_->end() || bIt->second.ptr == nullptr) {
        return true;
    }
    if (static_cast<std::size_t>(ac.byteOffset) + 4u > bIt->second.size) {
        return true;
    }
    const auto* base = static_cast<const std::uint8_t*>(bIt->second.ptr);
    std::memcpy(&raw, base + ac.byteOffset, 4);
    return true;
}

bool Interpreter::storeSSBOScalarRaw(const AccessChainResult& ac,
                                     std::uint32_t raw)
{
    if (!ac.isStorageBuffer) {
        bail("atomicSSBO: pointer is not an SSBO access chain");
        return false;
    }
    if (storageBuffers_ == nullptr) {
        bail("atomicSSBO: no storage buffer map set");
        return false;
    }
    auto bIt = storageBuffers_->find(ac.binding);
    if (bIt == storageBuffers_->end() || bIt->second.ptr == nullptr) {
        return true;
    }
    if (static_cast<std::size_t>(ac.byteOffset) + 4u > bIt->second.size) {
        return true;
    }
    auto* base = static_cast<std::uint8_t*>(bIt->second.ptr);
    std::memcpy(base + ac.byteOffset, &raw, 4);
    return true;
}

Value Interpreter::atomicResultValue(std::uint32_t resultTypeId,
                                     std::uint32_t raw) const
{
    Value v;
    v.kind = Value::Kind::UInt;
    auto tIt = module_.types.find(resultTypeId);
    if (tIt != module_.types.end() && tIt->second.kind == TypeInfo::Kind::Int) {
        v.kind = Value::Kind::Int;
    }
    v.i[0] = static_cast<std::int32_t>(raw);
    return v;
}

bool Interpreter::rawScalarFromValue(std::uint32_t valueId,
                                     std::uint32_t& raw)
{
    Value v;
    if (!tryGetValue(valueId, v)) {
        bail("atomicSSBO: unknown scalar operand");
        return false;
    }
    if (v.isFloatKind()) {
        std::memcpy(&raw, &v.f[0], 4);
    } else if (v.isIntKind()) {
        raw = static_cast<std::uint32_t>(v.i[0]);
    } else if (v.kind == Value::Kind::Bool) {
        raw = v.bval ? 1u : 0u;
    } else {
        bail("atomicSSBO: unsupported scalar operand");
        return false;
    }
    return true;
}

bool Interpreter::executeAtomicLoad(std::uint32_t resultTypeId,
                                    std::uint32_t resultId,
                                    std::uint32_t ptrId)
{
    auto acIt = accessChains_.find(ptrId);
    if (acIt == accessChains_.end()) {
        bail("OpAtomicLoad: unresolved pointer");
        return false;
    }
    std::uint32_t raw = 0;
    if (!loadSSBOScalarRaw(acIt->second, raw)) {
        return false;
    }
    valueStore_[resultId] = atomicResultValue(resultTypeId, raw);
    return true;
}

bool Interpreter::executeAtomicStore(std::uint32_t ptrId,
                                     std::uint32_t valueId)
{
    auto acIt = accessChains_.find(ptrId);
    if (acIt == accessChains_.end()) {
        bail("OpAtomicStore: unresolved pointer");
        return false;
    }
    std::uint32_t raw = 0;
    if (!rawScalarFromValue(valueId, raw)) {
        return false;
    }
    return storeSSBOScalarRaw(acIt->second, raw);
}

bool Interpreter::executeAtomicRMW(std::uint32_t opcode,
                                   std::uint32_t resultTypeId,
                                   std::uint32_t resultId,
                                   std::uint32_t ptrId,
                                   std::uint32_t valueId,
                                   std::uint32_t comparatorId)
{
    auto acIt = accessChains_.find(ptrId);
    if (acIt == accessChains_.end()) {
        bail("atomicSSBO: unresolved pointer");
        return false;
    }

    std::uint32_t oldRaw = 0;
    if (!loadSSBOScalarRaw(acIt->second, oldRaw)) {
        return false;
    }

    std::uint32_t valueRaw = 0;
    if (opcode != spv::OpAtomicIIncrement &&
        opcode != spv::OpAtomicIDecrement &&
        !rawScalarFromValue(valueId, valueRaw)) {
        return false;
    }

    std::uint32_t newRaw = oldRaw;
    switch (opcode) {
        case spv::OpAtomicExchange:
            newRaw = valueRaw;
            break;
        case spv::OpAtomicCompareExchange:
        case spv::OpAtomicCompareExchangeWeak: {
            std::uint32_t comparatorRaw = 0;
            if (!rawScalarFromValue(comparatorId, comparatorRaw)) {
                return false;
            }
            if (oldRaw == comparatorRaw) {
                newRaw = valueRaw;
            }
            break;
        }
        case spv::OpAtomicIIncrement:
            newRaw = oldRaw + 1u;
            break;
        case spv::OpAtomicIDecrement:
            newRaw = oldRaw - 1u;
            break;
        case spv::OpAtomicIAdd:
            newRaw = oldRaw + valueRaw;
            break;
        case spv::OpAtomicISub:
            newRaw = oldRaw - valueRaw;
            break;
        case spv::OpAtomicSMin:
            newRaw = static_cast<std::uint32_t>(std::min(
                static_cast<std::int32_t>(oldRaw),
                static_cast<std::int32_t>(valueRaw)));
            break;
        case spv::OpAtomicUMin:
            newRaw = std::min(oldRaw, valueRaw);
            break;
        case spv::OpAtomicSMax:
            newRaw = static_cast<std::uint32_t>(std::max(
                static_cast<std::int32_t>(oldRaw),
                static_cast<std::int32_t>(valueRaw)));
            break;
        case spv::OpAtomicUMax:
            newRaw = std::max(oldRaw, valueRaw);
            break;
        case spv::OpAtomicAnd:
            newRaw = oldRaw & valueRaw;
            break;
        case spv::OpAtomicOr:
            newRaw = oldRaw | valueRaw;
            break;
        case spv::OpAtomicXor:
            newRaw = oldRaw ^ valueRaw;
            break;
        default:
            bail("atomicSSBO: unsupported atomic opcode " + std::to_string(opcode));
            return false;
    }

    if (!storeSSBOScalarRaw(acIt->second, newRaw)) {
        return false;
    }
    valueStore_[resultId] = atomicResultValue(resultTypeId, oldRaw);
    return true;
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
            // Sprint 17 Day 7+ Bank-Group-H Path B Phase 3 day 5 — caller
            // override-map (vertexReflection.vertexInputs base-name → base
            // location) takes precedence over the SPIR-V Decoration walk.
            // glslang's xfb path emits arrays-of-floats inputs without
            // per-variable Location decoration; SPIRV-Cross's reflection
            // recovers the location from the original GLSL layout(location=N).
            // CTS cull_distance.functional_* tests use `in float
            // culldistance_data[8]` (locations 1..8) + `in vec2 position`
            // (location 9) — without this override, implicit auto-assign
            // mismatched the VAO layout, making `runVsForVertex` read all
            // zeros for cull-distance attributes.
            if (vsInputLocOverrides_ != nullptr && !info.name.empty()) {
                auto oIt = vsInputLocOverrides_->find(info.name);
                if (oIt != vsInputLocOverrides_->end()) {
                    inputLocationByVarId[varId] = oIt->second;
                    explicitLocs.push_back(oIt->second);
                    continue;
                }
            }
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
        std::uint32_t width = module_.scalarWidth(tIt->second.pointeeType);
        auto inputPointeeIt = module_.types.find(tIt->second.pointeeType);
        if ((stage_ == Stage::Geometry ||
             stage_ == Stage::TessEvaluation ||
             stage_ == Stage::TessControl) &&
            info.storageClass == spv::StorageClassInput &&
            inputPointeeIt != module_.types.end() &&
            inputPointeeIt->second.kind == TypeInfo::Kind::RuntimeArray) {
            const std::uint32_t elemW =
                module_.scalarWidth(inputPointeeIt->second.componentType);
            width = static_cast<std::uint32_t>(inputs.size()) * elemW;
        }
	        auto& storage = varStorage_[varId];
	        storage.assign(width, 0.0f);
	        if (stage_ == Stage::TessControl &&
	            info.storageClass == spv::StorageClassOutput &&
	            tcsSharedOutputStorage_ != nullptr) {
	            auto sharedIt = tcsSharedOutputStorage_->find(varId);
	            if (sharedIt != tcsSharedOutputStorage_->end()) {
	                const auto& src = sharedIt->second;
	                for (std::size_t k = 0; k < src.size() && k < storage.size(); ++k) {
	                    storage[k] = src[k];
	                }
	            }
	        }

	        // Phase 3f-3: SSBO variables don't get flat-scalar storage —
        // OpLoad / OpStore route through the caller's binding map
        // into real buffer memory. Populate ssboVarMeta_ so the
        // access-chain walk can confirm the root binding later.
        const bool isSSBO = [&]() {
            if (info.storageClass == spv::StorageClassStorageBuffer) return true;
            if (info.storageClass == spv::StorageClassUniform) {
                auto pIt = module_.types.find(tIt->second.pointeeType);
                if (pIt != module_.types.end()) {
                    auto dIt = module_.decorations.find(tIt->second.pointeeType);
                    if (dIt != module_.decorations.end() && dIt->second.isBufferBlock) {
                        return true;
                    }
                }
            }
            return false;
        }();
        if (isSSBO) {
            StorageBufferVarMeta meta;
            auto dIt = module_.decorations.find(varId);
            if (dIt != module_.decorations.end() && dIt->second.hasBinding) {
                meta.binding = dIt->second.binding;
            }
            ssboVarMeta_[varId] = meta;
            continue;   // skip uniform seeding + other per-var handlers
        }

        // Sprint 17 Day 4+ BONUS-2 [gpu_shader5 array-indexing]: detect
        // UBO array shape — Uniform storage class with pointee type
        // Array(Block-decorated Struct). For `uniform PositionBlock {
        // ... } positionBlocks[4]`, glslang emits:
        //   varId : OpVariable <ptr_to_Array_PositionBlock_4> Uniform
        //   <PositionBlock> : OpTypeStruct {decorate Block}
        //   <Array_PositionBlock_4> : OpTypeArray <PositionBlock> 4
        // Stash baseBinding + arrayLen so resolveAccessChain can
        // dispatch the first index → binding=baseBinding+idx.
        if (info.storageClass == spv::StorageClassUniform) {
            auto pT = module_.types.find(tIt->second.pointeeType);
            if (pT != module_.types.end() &&
                pT->second.kind == TypeInfo::Kind::Struct) {
                auto blockDec = module_.decorations.find(tIt->second.pointeeType);
                if (blockDec != module_.decorations.end() &&
                    blockDec->second.isBlock &&
                    !blockDec->second.isBufferBlock) {
                    std::string blockName;
                    auto nameIt = module_.names.find(tIt->second.pointeeType);
                    if (nameIt != module_.names.end()) blockName = nameIt->second;
                    if (blockName != "_DefaultUniforms") {
                        auto vDec = module_.decorations.find(varId);
                        const std::uint32_t baseBinding =
                            (vDec != module_.decorations.end() &&
                             vDec->second.hasBinding)
                                ? vDec->second.binding : 0u;
                        if (uniformBuffers_ != nullptr &&
                            uniformBuffers_->count(baseBinding) != 0) {
                            UniformBufferArrayMeta uboMeta;
                            uboMeta.baseBinding = baseBinding;
                            uboMeta.arrayLen = 1;
                            uboVarMeta_[varId] = uboMeta;
                            continue;   // read through loadFromUBO
                        }
                    }
                }
            } else if (pT != module_.types.end() &&
                       pT->second.kind == TypeInfo::Kind::Array) {
                auto innerT = module_.types.find(pT->second.componentType);
                if (innerT != module_.types.end() &&
                    innerT->second.kind == TypeInfo::Kind::Struct) {
                    auto blockDec = module_.decorations.find(pT->second.componentType);
                    if (blockDec != module_.decorations.end() &&
                        blockDec->second.isBlock &&
                        !blockDec->second.isBufferBlock) {
                        std::string blockName;
                        auto nameIt = module_.names.find(pT->second.componentType);
                        if (nameIt != module_.names.end()) blockName = nameIt->second;
                        if (blockName == "_DefaultUniforms") {
                            continue;
                        }
                        auto vDec = module_.decorations.find(varId);
                        const std::uint32_t baseBinding =
                            (vDec != module_.decorations.end() &&
                             vDec->second.hasBinding)
                                ? vDec->second.binding : 0u;
                        if (uniformBuffers_ != nullptr &&
                            uniformBuffers_->count(baseBinding) != 0) {
                            UniformBufferArrayMeta uboMeta;
                            uboMeta.baseBinding = baseBinding;
                            // OpTypeArray's length lives in
                            // arrayLengthConstId (SPIR-V constant id);
                            // resolve via module_.constants. Mirrors the
                            // pattern in SpirvModule::scalarWidth.
                            auto lenIt = module_.constants.find(pT->second.arrayLengthConstId);
                            uboMeta.arrayLen = (lenIt != module_.constants.end())
                                ? static_cast<std::uint32_t>(lenIt->second.i[0]) : 0;
                            uboArrayVarMeta_[varId] = uboMeta;
                            continue;   // skip varStorage_ seeding for UBO arrays
                        }
                    }
                }
            }
        }

        // ── Uniform / UniformConstant — seed from caller's map.
        if ((info.storageClass == spv::StorageClassUniform ||
             info.storageClass == spv::StorageClassUniformConstant) &&
            uniforms_ != nullptr) {
            const std::uint32_t pointeeType = tIt->second.pointeeType;
            // Sprint 7 Phase 1 #4 (CKPT54): UniformConstant variables
            // pointing at OpTypeImage / OpTypeSampledImage have no
            // entry in `module_.types` (the SPIR-V type parser only
            // tracks scalar / vector / matrix / array / struct /
            // pointer / function — opaque image types are out of
            // band). Sampler tests sidestepped this because their
            // sampler arrays happened to be wrapped in OpTypeArray,
            // which IS parsed. The image-uniforms test declares
            // bare `uniform iimage2D imgN` with no array wrapper, so
            // pointeeType lands on the opaque OpTypeImage id and
            // `module_.types.at` threw `key not found`. Skip uniform
            // seeding for opaque-type pointees — image/sampler texel
            // data is plumbed through sampledTextures_/storageImages_
            // separately, not through the default-uniform values map.
            auto pIt = module_.types.find(pointeeType);
            if (pIt == module_.types.end()) {
                continue;
            }
            const auto& pT = pIt->second;
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
        // ── GS-stage built-ins: gl_PrimitiveIDIn (BuiltInPrimitiveId
        // = 7). `glGetBuiltInDecorations` returns the same decoration
        // value for both `gl_PrimitiveIDIn` in the GS and the FS's
        // `gl_PrimitiveID` input; here we're scoped to the GS stage
        // so the interpretation is unambiguous.
        if (stage_ == Stage::Geometry && info.storageClass == spv::StorageClassInput) {
            auto dIt = module_.decorations.find(varId);
            if (dIt != module_.decorations.end() && dIt->second.hasBuiltIn) {
                if (dIt->second.builtIn == 7 /*BuiltInPrimitiveId*/ && width >= 1) {
                    std::memcpy(&storage[0], &gsPrimitiveId_, 4);
                    continue;
                }
                // gl_InvocationID (BuiltIn=8). Bit-cast the int32
                // invocation index set by the caller into the
                // storage slot so OpLoad reads the correct value
                // per invocation. Single-invocation GS leaves this
                // at 0 which is still spec-correct.
                if (dIt->second.builtIn == 8 /*BuiltInInvocationId*/ && width >= 1) {
                    std::memcpy(&storage[0], &gsInvocationId_, 4);
                    continue;
                }
            }
        }

        // ── TES-stage built-in inputs: gl_TessCoord (BuiltIn=13),
        // gl_PrimitiveID (BuiltIn=7), gl_PatchVerticesIn (BuiltIn=14).
        // Other tess built-ins (gl_in[] array, gl_TessLevel*) need the
        // patch's TCS-output + per-patch state plumbing — they land in
        // phase 3f-2+. For now we seed only the three that the CE
        // tess_eval + passthrough shapes read.
        if (stage_ == Stage::TessEvaluation && info.storageClass == spv::StorageClassInput) {
            auto dIt = module_.decorations.find(varId);
            if (dIt != module_.decorations.end() && dIt->second.hasBuiltIn) {
                if (dIt->second.builtIn == 13 /*BuiltInTessCoord*/ && width >= 3) {
                    // vec3 (domain coord). Splat all three components;
                    // isolines/quads shaders read only a subset but
                    // the scalar storage still needs all three slots
                    // populated in case the body derefs e.g. .z.
                    storage[0] = tesTessCoord_[0];
                    storage[1] = tesTessCoord_[1];
                    storage[2] = tesTessCoord_[2];
                    continue;
                }
                if (dIt->second.builtIn == 7 /*BuiltInPrimitiveId*/ && width >= 1) {
                    std::memcpy(&storage[0], &tesPrimitiveId_, 4);
                    continue;
                }
                // Phase 3f-1 stub: BuiltInPatchVertices = 14. We don't
                // plumb a runtime value yet — leave the storage at 0
                // (safe default; TES bodies that consult it for bounds-
                // checking fall back through the matcher's strictness
                // gate anyway).
            }
            // Phase 3f-14: patch-in varyings — scalar/vec/scalar-array
            // Input variables decorated with DecorationPatch.
            // Seed from the caller-supplied per-patch map keyed by
            // variable name (TCS-side captureTcsPatchOutputs writes
            // by name). If the TCS didn't write this name for this
            // patch, storage stays at zero init (matches GL's
            // "undefined but implementation-consistent" semantics).
            //
            // Sprint 8 #8 β.2 Day 2 (CKPT70): drop the hasLocation
            // gate — `patch in vec4 tc_patch_data;` without explicit
            // layout(location=N) is a valid GLSL shape that glslang
            // emits without Location decoration.
            if (dIt != module_.decorations.end() && dIt->second.isPatch &&
                tesPatchInputs_ != nullptr && !info.name.empty()) {
                auto pIt = tesPatchInputs_->find(info.name);
                if (pIt != tesPatchInputs_->end()) {
                    const auto& src = pIt->second;
                    for (std::size_t k = 0; k < src.size() && k < storage.size(); ++k) {
                        storage[k] = src[k];
                    }
                }
                continue;
            }
        }

        // ── TCS-stage built-in inputs (phase 3f-4):
        //      gl_PrimitiveID       (BuiltIn = 7)  — patch-in-draw index
        //      gl_InvocationID      (BuiltIn = 8)  — 0..vertices-1
        //      gl_PatchVerticesIn   (BuiltIn = 14) — input patch size
        //                                            (GL_PATCH_VERTICES)
        // gl_TessLevelInner / gl_TessLevelOuter writes from the body
        // land in per-variable flat storage through the Output path;
        // the caller reads them post-run if it cares (CE tests don't —
        // levels default to 1.0 from glPatchParameterfv and that's
        // what the TCS also writes, so there's nothing extra to plumb).
        if (stage_ == Stage::TessControl && info.storageClass == spv::StorageClassInput) {
            auto dIt = module_.decorations.find(varId);
            if (dIt != module_.decorations.end() && dIt->second.hasBuiltIn) {
                if (dIt->second.builtIn == 7 /*BuiltInPrimitiveId*/ && width >= 1) {
                    std::memcpy(&storage[0], &tcsPrimitiveId_, 4);
                    continue;
                }
                if (dIt->second.builtIn == 8 /*BuiltInInvocationId*/ && width >= 1) {
                    std::memcpy(&storage[0], &tcsInvocationId_, 4);
                    continue;
                }
                if (dIt->second.builtIn == 14 /*BuiltInPatchVertices*/ && width >= 1) {
                    std::memcpy(&storage[0], &tcsPatchVertices_, 4);
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
                    // Sprint 17 Day 7+ Bank-Group-H Path B Phase 3 day 5 —
                    // detect arrays-of-floats input variables spanning
                    // multiple locations (GL 4.6 §4.4.1: each array
                    // element occupies its own consecutive location).
                    // For `in float arr[N]` at base location L, element K
                    // lives at location L+K and is sourced from
                    // vsAttribs[L+K]. Detect via pointee-type kind ==
                    // Array; element type confirmed scalar-or-vec3-or-
                    // less-floats. Otherwise fall back to single-Value
                    // lookup (preserves existing behavior for vec[2-4] +
                    // scalar inputs which fit in one Value).
                    bool handledAsArray = false;
                    auto pIt = module_.types.find(tIt->second.pointeeType);
                    if (pIt != module_.types.end() &&
                        pIt->second.kind == TypeInfo::Kind::Matrix) {
                        auto columnIt = module_.types.find(pIt->second.componentType);
                        const std::uint32_t columnWidth =
                            module_.scalarWidth(pIt->second.componentType);
                        if (columnIt != module_.types.end() &&
                            columnWidth >= 1 && columnWidth <= 4) {
                            const std::uint32_t baseLoc = locIt->second;
                            for (std::uint32_t col = 0;
                                 col < pIt->second.count;
                                 ++col) {
                                auto eIt = vsAttribs_->find(baseLoc + col);
                                if (eIt == vsAttribs_->end()) continue;
                                const Value& v = eIt->second;
                                const int n = v.componentCount();
                                const std::uint32_t dstBase = col * columnWidth;
                                if (v.isFloatKind()) {
                                    for (int k = 0;
                                         k < n &&
                                         k < static_cast<int>(columnWidth) &&
                                         dstBase + static_cast<std::uint32_t>(k) < width;
                                         ++k) {
                                        storage[dstBase + k] = v.f[k];
                                    }
                                } else {
                                    for (int k = 0;
                                         k < n &&
                                         k < static_cast<int>(columnWidth) &&
                                         dstBase + static_cast<std::uint32_t>(k) < width;
                                         ++k) {
                                        std::memcpy(&storage[dstBase + k],
                                                    &v.i[k], 4);
                                    }
                                }
                            }
                            handledAsArray = true;
                        }
                    }
	                    if (pIt != module_.types.end() &&
	                        pIt->second.kind == TypeInfo::Kind::Array) {
	                        const std::uint32_t elementType = pIt->second.componentType;
	                        const std::uint32_t elementWidth = module_.scalarWidth(elementType);
	                        auto elementIt = module_.types.find(elementType);
	                        if (elementIt != module_.types.end() &&
	                            elementIt->second.kind == TypeInfo::Kind::Matrix) {
	                            const std::uint32_t columnWidth =
	                                module_.scalarWidth(elementIt->second.componentType);
	                            const std::uint32_t columnCount = elementIt->second.count;
	                            if (columnWidth >= 1 && columnWidth <= 4 &&
	                                columnCount >= 1 && elementWidth != 0) {
	                                const std::uint32_t baseLoc = locIt->second;
	                                const std::uint32_t arrayLen =
	                                    width / std::max<std::uint32_t>(1, elementWidth);
	                                for (std::uint32_t e = 0; e < arrayLen; ++e) {
	                                    for (std::uint32_t col = 0; col < columnCount; ++col) {
	                                        auto eIt = vsAttribs_->find(baseLoc + e * columnCount + col);
	                                        if (eIt == vsAttribs_->end()) continue;
	                                        const Value& v = eIt->second;
	                                        const int n = v.componentCount();
	                                        const std::uint32_t dstBase =
	                                            e * elementWidth + col * columnWidth;
	                                        if (v.isFloatKind()) {
	                                            for (int k = 0;
	                                                 k < n &&
	                                                 k < static_cast<int>(columnWidth) &&
	                                                 dstBase + static_cast<std::uint32_t>(k) < width;
	                                                 ++k) {
	                                                storage[dstBase + k] = v.f[k];
	                                            }
	                                        } else {
	                                            for (int k = 0;
	                                                 k < n &&
	                                                 k < static_cast<int>(columnWidth) &&
	                                                 dstBase + static_cast<std::uint32_t>(k) < width;
	                                                 ++k) {
	                                                std::memcpy(&storage[dstBase + k],
	                                                            &v.i[k], 4);
	                                            }
	                                        }
	                                    }
	                                }
	                                handledAsArray = true;
	                            }
	                        }
	                        // Each element occupies one location (per spec)
	                        // when element width <= 4. Wider elements (mat3,
	                        // mat4 inputs) consume multiple locations per
	                        // element — out of scope here; fall through.
	                        if (!handledAsArray && elementWidth >= 1 && elementWidth <= 4) {
	                            const std::uint32_t baseLoc = locIt->second;
	                            const std::uint32_t arrayLen =
	                                width / std::max<std::uint32_t>(1, elementWidth);
                            for (std::uint32_t e = 0; e < arrayLen; ++e) {
                                auto eIt = vsAttribs_->find(baseLoc + e);
                                if (eIt == vsAttribs_->end()) continue;
                                const Value& v = eIt->second;
                                const int n = v.componentCount();
                                const std::uint32_t dstBase = e * elementWidth;
                                if (v.isFloatKind()) {
                                    for (int k = 0;
                                         k < n &&
                                         k < static_cast<int>(elementWidth) &&
                                         dstBase + static_cast<std::uint32_t>(k) < width;
                                         ++k) {
                                        storage[dstBase + k] = v.f[k];
                                    }
                                } else {
                                    for (int k = 0;
                                         k < n &&
                                         k < static_cast<int>(elementWidth) &&
                                         dstBase + static_cast<std::uint32_t>(k) < width;
                                         ++k) {
                                        std::memcpy(&storage[dstBase + k],
                                                    &v.i[k], 4);
                                    }
                                }
                            }
                            handledAsArray = true;
                        }
                    }
                    if (!handledAsArray) {
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
            }
            // VS Input handling is complete regardless of whether
            // we matched — the fall-through GS gl_in[] path isn't
            // applicable to this stage.
            continue;
        }

        if ((stage_ == Stage::Geometry ||
             stage_ == Stage::TessEvaluation ||
             stage_ == Stage::TessControl) &&
            info.storageClass == spv::StorageClassInput) {
            // Identify the variable:
            //  - gl_PerVertex block input (contains gl_Position) —
            //    member 0 is BuiltInPosition. The SPIR-V pointee type
            //    is an array-of-struct (gl_in[]), so its scalar width
            //    is N_vertices × struct_width. We write per-vertex
            //    positions at the member-0 offset within each element.
            //  - Named user varying array (vtx_out_*) — flat array
            //    keyed by varying name, width = array_len × per_vertex.
            // Phase 3f-5: TES reuses the exact same gl_in[] shape —
            //   the interpreter's `inputs` vector holds one entry per
            //   patch vertex (runTesForVertex builds it from the VS
            //   pre-pass output the caller collected upstream).
            // Phase 3f-10: TCS also reuses this path. For TCS,
            //   `inputs` is the VS pre-pass output per input patch
            //   vertex (same as what TES uses when no TCS is present).
            const auto& pointeeType = module_.types.at(tIt->second.pointeeType);
            if (pointeeType.kind == TypeInfo::Kind::Array ||
                pointeeType.kind == TypeInfo::Kind::RuntimeArray) {
                // Determine per-vertex struct / element width.
                const std::uint32_t perVertexW = module_.scalarWidth(pointeeType.componentType);
                const auto& elemT = module_.types.at(pointeeType.componentType);
                if (elemT.kind == TypeInfo::Kind::Struct) {
                    // Two struct shapes to handle:
                    // 1. gl_PerVertex: members decorated BuiltIn
                    //    (Position / PointSize / ClipDistance /
                    //    CullDistance). Populate from inputs[vi]
                    //    fields at the member's scalar offset.
                    // 2. User interface block: members are user
                    //    varyings with plain names; look them up
                    //    by member NAME in inputVaryingNames_ so
                    //    CTS `limits.max_input_components`'s
                    //    `in Vertex { ivec4 vs_gs_out[N]; } vertex
                    //    [1]` block picks up its per-vertex array
                    //    data. Previously this branch only scanned
                    //    for BuiltIns and left user-block storage
                    //    zero-initialised.
                    auto mdIt = module_.memberDecorations.find(pointeeType.componentType);
                    auto mnIt = module_.memberNames.find(pointeeType.componentType);
                    for (std::size_t vi = 0; vi < inputs.size(); ++vi) {
                        const std::uint32_t base = static_cast<std::uint32_t>(vi) * perVertexW;
                        std::uint32_t runningOff = 0;
                        for (std::size_t m = 0; m < elemT.memberTypes.size(); ++m) {
                            const std::uint32_t memType = elemT.memberTypes[m];
                            const std::uint32_t memW = module_.scalarWidth(memType);
                            bool handledBuiltIn = false;
                            if (mdIt != module_.memberDecorations.end()) {
                                auto mm = mdIt->second.perMember.find(static_cast<std::uint32_t>(m));
                                if (mm != mdIt->second.perMember.end() && mm->second.hasBuiltIn) {
                                    // GL 4.6 §11.3.3 gl_in[] built-in member
                                    // population. storage.size() == scalarWidth
                                    // (array) == len × struct-width, where
                                    // struct-width is the sum of member widths
                                    // INCLUDING unsized arrays that resolve to 0.
                                    // When the GS uses `gl_in.length()` but
                                    // DOESN'T read any gl_PerVertex members,
                                    // glslang still emits the struct + member
                                    // decorations but resolves the
                                    // gl_ClipDistance[] array length from
                                    // context (the gl_Max*ClipDistances limits
                                    // the SPIR-V advertises) — which can exceed
                                    // the scalar width our scalarWidth() sums
                                    // up from the members' own type widths.
                                    // Result: `base + runningOff + k` walks
                                    // past the end of storage on the 2nd input
                                    // vertex and trashes the adjacent heap
                                    // allocation.
                                    //
                                    // Mirror the user-block-member branch's
                                    // `base + runningOff + k < storage.size()`
                                    // bound on all three built-in members so
                                    // every indexed write stays in-buffer.
                                    // CTS `geometry_shader.input.gl_in_array_
                                    // length` + the asan_repro (session-16
                                    // iter 158) both hit this path; GuardMalloc
                                    // catches the overrun at the first write.
                                    if (mm->second.builtIn == spv::BuiltInPosition) {
                                        for (int k = 0; k < 4 && static_cast<std::uint32_t>(k) < memW
                                             && base + runningOff + k < storage.size(); ++k) {
                                            storage[base + runningOff + k] = inputs[vi].position[k];
                                        }
                                    } else if (mm->second.builtIn == spv::BuiltInPointSize) {
                                        // Sprint 8 #8 β.2 Day 3 (CKPT71): seed
                                        // gl_in[vi].gl_PointSize from VS pre-pass
                                        // PerVertexInput.pointSize. Required for
                                        // CTS data_pass_through pointsize variants.
                                        //
                                        // CKPT98 (β.3 Day 26): widen to TessControl
                                        // when the source pointSize differs from the
                                        // default (1.0) — this allows TCS bodies that
                                        // read `gl_in[0].gl_PointSize` (e.g. TCS that
                                        // multiplies and copies forward to user-block
                                        // tc_pointSize) to receive the VS-supplied
                                        // value. The default-1.0 guard preserves
                                        // CKPT71's regression-isolation: when the VS
                                        // didn't meaningfully write gl_PointSize, we
                                        // don't seed (avoids the gl_PerVertex
                                        // implicit-copy interference that CKPT71
                                        // observed for non-pointsize sub-runs).
                                        if (memW > 0 && base + runningOff < storage.size() &&
                                            (stage_ == Stage::TessEvaluation ||
                                             stage_ == Stage::TessControl)) {
                                            storage[base + runningOff] = inputs[vi].pointSize;
                                        }
                                    } else if (mm->second.builtIn == spv::BuiltInClipDistance) {
                                        const auto& src = inputs[vi].clipDistance;
                                        for (std::uint32_t k = 0; k < memW
                                             && base + runningOff + k < storage.size(); ++k) {
                                            storage[base + runningOff + k] =
                                                (k < src.size()) ? src[k] : 0.0f;
                                        }
                                    } else if (mm->second.builtIn == spv::BuiltInCullDistance) {
                                        const auto& src = inputs[vi].cullDistance;
                                        for (std::uint32_t k = 0; k < memW
                                             && base + runningOff + k < storage.size(); ++k) {
                                            storage[base + runningOff + k] =
                                                (k < src.size()) ? src[k] : 0.0f;
                                        }
                                    }
                                    handledBuiltIn = true;
                                }
                            }
                            if (!handledBuiltIn && mnIt != module_.memberNames.end()) {
                                // User block member. Look up by name.
                                auto mnm = mnIt->second.find(static_cast<std::uint32_t>(m));
                                if (mnm != mnIt->second.end()) {
                                    const std::string& memberName = mnm->second;
                                    int varyingIdx = -1;
                                    for (std::size_t j = 0; j < inputVaryingNames_.size(); ++j) {
                                        if (inputVaryingNames_[j] == memberName) {
                                            varyingIdx = static_cast<int>(j);
                                            break;
                                        }
                                    }
                                    if (varyingIdx >= 0 &&
                                        static_cast<std::size_t>(varyingIdx) < inputs[vi].varyings.size()) {
                                        const auto& src = inputs[vi].varyings[varyingIdx];
                                        for (std::uint32_t k = 0; k < memW && k < src.size()
                                             && base + runningOff + k < storage.size(); ++k) {
                                            storage[base + runningOff + k] = src[k];
                                        }
                                    }
                                }
                            }
                            runningOff += memW;
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
                        // Bug: the original loop bounded vi by
                        // inputs[vi].varyings.size() — a typo that
                        // reduced the loop to "vi < 1" whenever each
                        // vertex carries a single varying, populating
                        // only vertex 0's slot and leaving vertices
                        // 1..N-1 zero. With `lines`-input GS reading
                        // vs_gs_color[0] + vs_gs_color[1], that made
                        // end_col stay zero and turned every
                        // interpolation test's pixel into 6/7 * start
                        // (or zero when lines rasterisation missed the
                        // sample). Bound is the vertex count; we
                        // separately guard each vertex against a
                        // missing varying-slot.
                        for (std::size_t vi = 0; vi < inputs.size(); ++vi) {
                            if (static_cast<std::size_t>(varyingIdx) >= inputs[vi].varyings.size()) {
                                continue;
                            }
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

// Shared helper: scan module_.variables for Output variables whose
// decoration (direct or member-of-struct) is BuiltInClipDistance /
// BuiltInCullDistance, and copy the current storage values out.
// Used by both `emitVertex` (GS per-vertex capture) and `executeVs`
// (VS full output capture) — they have the same shape.
namespace {
// clip/cull array lengths from the decorated array type. Each is
// OpTypeArray elemType=float length=N.
std::uint32_t clipCullArrayLen(const SpirvModule& mod, std::uint32_t arrayTypeId) {
    auto it = mod.types.find(arrayTypeId);
    if (it == mod.types.end()) return 0;
    if (it->second.kind != TypeInfo::Kind::Array) return 0;
    // Array length is stored on an OpConstant referenced by arrayLengthConstId.
    auto cIt = mod.constants.find(it->second.arrayLengthConstId);
    if (cIt == mod.constants.end()) return 0;
    return static_cast<std::uint32_t>(cIt->second.i[0]);
}
}  // namespace

void Interpreter::captureClipCull(std::vector<float>& clipOut,
                                  std::vector<float>& cullOut) const {
    clipOut.clear();
    cullOut.clear();
    // Two shapes in SPIR-V:
    //  1. Direct: `out float gl_ClipDistance[N];` — Output variable
    //     whose decoration says BuiltInClipDistance. The storage is
    //     a flat float array.
    //  2. Member of gl_PerVertex: `out gl_PerVertex { ... float
    //     gl_ClipDistance[N]; ... };` — Output struct variable whose
    //     member at some index has MemberDecorate BuiltIn
    //     ClipDistance. Storage is a flat concatenation of all
    //     struct members; we offset into it by summing widths of
    //     preceding members.
    for (const auto& [varId, info] : module_.variables) {
        if (info.storageClass != spv::StorageClassOutput) continue;
        auto sIt = varStorage_.find(varId);
        if (sIt == varStorage_.end()) continue;
        // Walk the pointee type. `typeId` is a Pointer; its pointee
        // is either the clip/cull array directly or a struct whose
        // members include clip/cull.
        auto tIt = module_.types.find(info.typeId);
        if (tIt == module_.types.end()) continue;
        const std::uint32_t pointee = tIt->second.pointeeType;
        auto pIt = module_.types.find(pointee);
        if (pIt == module_.types.end()) continue;
        // Shape 1: Output variable decorated BuiltIn ClipDistance /
        // CullDistance. The pointee is the array itself.
        auto dIt = module_.decorations.find(varId);
        if (dIt != module_.decorations.end() && dIt->second.hasBuiltIn) {
            const std::uint32_t n = clipCullArrayLen(module_, pointee);
            if (dIt->second.builtIn == spv::BuiltInClipDistance) {
                for (std::uint32_t k = 0; k < n; ++k) {
                    clipOut.push_back(k < sIt->second.size() ? sIt->second[k] : 0.0f);
                }
                continue;
            }
            if (dIt->second.builtIn == spv::BuiltInCullDistance) {
                for (std::uint32_t k = 0; k < n; ++k) {
                    cullOut.push_back(k < sIt->second.size() ? sIt->second[k] : 0.0f);
                }
                continue;
            }
        }
        // Shape 2: Struct whose members are decorated. Walk member
        // decorations, compute each member's flat-scalar offset,
        // check whether it's clip/cull.
        if (pIt->second.kind != TypeInfo::Kind::Struct) continue;
        auto mdIt = module_.memberDecorations.find(pointee);
        if (mdIt == module_.memberDecorations.end()) continue;
        std::uint32_t runningOff = 0;
        for (std::size_t m = 0; m < pIt->second.memberTypes.size(); ++m) {
            const std::uint32_t memberType = pIt->second.memberTypes[m];
            const std::uint32_t memberWidth = module_.scalarWidth(memberType);
            auto mdm = mdIt->second.perMember.find(static_cast<std::uint32_t>(m));
            if (mdm != mdIt->second.perMember.end() && mdm->second.hasBuiltIn) {
                if (mdm->second.builtIn == spv::BuiltInClipDistance) {
                    for (std::uint32_t k = 0; k < memberWidth; ++k) {
                        const std::uint32_t idx = runningOff + k;
                        clipOut.push_back(idx < sIt->second.size() ? sIt->second[idx] : 0.0f);
                    }
                } else if (mdm->second.builtIn == spv::BuiltInCullDistance) {
                    for (std::uint32_t k = 0; k < memberWidth; ++k) {
                        const std::uint32_t idx = runningOff + k;
                        cullOut.push_back(idx < sIt->second.size() ? sIt->second[idx] : 0.0f);
                    }
                }
            }
            runningOff += memberWidth;
        }
    }
}

std::optional<float> Interpreter::capturePointSize() const {
    // Mirror captureLayer, but for BuiltInPointSize (float). Used by
    // the synth VS to emit `[[point_size]]` on GL_POINTS output.
    //
    // The gl_PerVertex output block declares gl_PointSize as a
    // member even when the GS doesn't write it — the struct just
    // exists at SPIR-V level. So the member "existing" doesn't
    // imply the GS wrote to it. Treat a stored value of exactly
    // 0.0 as "not written" — gl_PointSize = 0 is undefined
    // behaviour in GL 4.6 §11.2.1 anyway, and the Metal-side
    // zero-sized point would make the primitive vanish. Returning
    // std::nullopt here lets the caller fall back to the
    // historical default 1.0 emit.
    auto checkStoredValue = [](float v) -> std::optional<float> {
        if (v == 0.0f) return std::nullopt;
        return v;
    };
    for (const auto& [varId, info] : module_.variables) {
        if (info.storageClass != spv::StorageClassOutput) continue;
        auto sIt = varStorage_.find(varId);
        if (sIt == varStorage_.end()) continue;
        auto tIt = module_.types.find(info.typeId);
        if (tIt == module_.types.end()) continue;
        const std::uint32_t pointee = tIt->second.pointeeType;
        auto pIt = module_.types.find(pointee);
        if (pIt == module_.types.end()) continue;
        // Shape 1: direct Output float decorated BuiltInPointSize.
        auto dIt = module_.decorations.find(varId);
        if (dIt != module_.decorations.end() && dIt->second.hasBuiltIn &&
            dIt->second.builtIn == spv::BuiltInPointSize) {
            if (!sIt->second.empty()) return checkStoredValue(sIt->second[0]);
            return std::nullopt;
        }
        // Shape 2: member of a gl_PerVertex-style struct.
        if (pIt->second.kind != TypeInfo::Kind::Struct) continue;
        auto mdIt = module_.memberDecorations.find(pointee);
        if (mdIt == module_.memberDecorations.end()) continue;
        std::uint32_t runningOff = 0;
        for (std::size_t m = 0; m < pIt->second.memberTypes.size(); ++m) {
            const std::uint32_t memberType = pIt->second.memberTypes[m];
            const std::uint32_t memberWidth = module_.scalarWidth(memberType);
            auto mdm = mdIt->second.perMember.find(static_cast<std::uint32_t>(m));
            if (mdm != mdIt->second.perMember.end() && mdm->second.hasBuiltIn
                && mdm->second.builtIn == spv::BuiltInPointSize) {
                if (runningOff < sIt->second.size()) {
                    return checkStoredValue(sIt->second[runningOff]);
                }
                return std::nullopt;
            }
            runningOff += memberWidth;
        }
    }
    return std::nullopt;
}

std::optional<std::int32_t> Interpreter::capturePrimitiveID() const {
    // Mirror captureLayer but for BuiltInPrimitiveId = 7 on an
    // OUTPUT variable. Unlike gl_Layer, the gl_PerVertex output
    // block does NOT include gl_PrimitiveID as a default member —
    // SPIR-V only produces a BuiltInPrimitiveId-decorated Output
    // when the GS source has a statement like
    // `gl_PrimitiveID = …;`. So whenever we find an Output with
    // that decoration, we know the GS source wrote it at some
    // point; the storage value is the last written value at
    // EmitVertex time. Returning the current scalar value without
    // a "zero means unwritten" heuristic (unlike capturePointSize)
    // is therefore correct.
    for (const auto& [varId, info] : module_.variables) {
        if (info.storageClass != spv::StorageClassOutput) continue;
        auto sIt = varStorage_.find(varId);
        if (sIt == varStorage_.end()) continue;
        auto tIt = module_.types.find(info.typeId);
        if (tIt == module_.types.end()) continue;
        const std::uint32_t pointee = tIt->second.pointeeType;
        auto pIt = module_.types.find(pointee);
        if (pIt == module_.types.end()) continue;
        // Shape 1: direct Output int decorated BuiltInPrimitiveId.
        auto dIt = module_.decorations.find(varId);
        if (dIt != module_.decorations.end() && dIt->second.hasBuiltIn &&
            dIt->second.builtIn == 7 /*BuiltInPrimitiveId*/) {
            if (!sIt->second.empty()) {
                std::int32_t v = 0;
                std::memcpy(&v, &sIt->second[0], sizeof(std::int32_t));
                return v;
            }
            return 0;
        }
        // Shape 2: member of a gl_PerVertex-style struct (rare —
        // glslang usually emits a direct Output — but cover it).
        if (pIt->second.kind != TypeInfo::Kind::Struct) continue;
        auto mdIt = module_.memberDecorations.find(pointee);
        if (mdIt == module_.memberDecorations.end()) continue;
        std::uint32_t runningOff = 0;
        for (std::size_t m = 0; m < pIt->second.memberTypes.size(); ++m) {
            const std::uint32_t memberType = pIt->second.memberTypes[m];
            const std::uint32_t memberWidth = module_.scalarWidth(memberType);
            auto mdm = mdIt->second.perMember.find(static_cast<std::uint32_t>(m));
            if (mdm != mdIt->second.perMember.end() && mdm->second.hasBuiltIn
                && mdm->second.builtIn == 7 /*BuiltInPrimitiveId*/) {
                if (runningOff < sIt->second.size()) {
                    std::int32_t v = 0;
                    std::memcpy(&v, &sIt->second[runningOff], sizeof(std::int32_t));
                    return v;
                }
                return 0;
            }
            runningOff += memberWidth;
        }
    }
    return std::nullopt;
}

std::optional<std::int32_t> Interpreter::captureLayer() const {
    // Same two-shape walk as captureClipCull, but gl_Layer is a
    // scalar int Output, not an array.
    for (const auto& [varId, info] : module_.variables) {
        if (info.storageClass != spv::StorageClassOutput) continue;
        auto sIt = varStorage_.find(varId);
        if (sIt == varStorage_.end()) continue;
        auto tIt = module_.types.find(info.typeId);
        if (tIt == module_.types.end()) continue;
        const std::uint32_t pointee = tIt->second.pointeeType;
        auto pIt = module_.types.find(pointee);
        if (pIt == module_.types.end()) continue;
        // Shape 1: direct Output int decorated BuiltInLayer.
        auto dIt = module_.decorations.find(varId);
        if (dIt != module_.decorations.end() && dIt->second.hasBuiltIn &&
            dIt->second.builtIn == spv::BuiltInLayer) {
            if (!sIt->second.empty()) {
                // varStorage is float-typed; reinterpret to int32.
                std::int32_t v = 0;
                std::memcpy(&v, &sIt->second[0], sizeof(std::int32_t));
                return v;
            }
            return 0;
        }
        // Shape 2: member of a gl_PerVertex-style struct.
        if (pIt->second.kind != TypeInfo::Kind::Struct) continue;
        auto mdIt = module_.memberDecorations.find(pointee);
        if (mdIt == module_.memberDecorations.end()) continue;
        std::uint32_t runningOff = 0;
        for (std::size_t m = 0; m < pIt->second.memberTypes.size(); ++m) {
            const std::uint32_t memberType = pIt->second.memberTypes[m];
            const std::uint32_t memberWidth = module_.scalarWidth(memberType);
            auto mdm = mdIt->second.perMember.find(static_cast<std::uint32_t>(m));
            if (mdm != mdIt->second.perMember.end() && mdm->second.hasBuiltIn
                && mdm->second.builtIn == spv::BuiltInLayer) {
                if (runningOff < sIt->second.size()) {
                    std::int32_t v = 0;
                    std::memcpy(&v, &sIt->second[runningOff], sizeof(std::int32_t));
                    return v;
                }
                return 0;
            }
            runningOff += memberWidth;
        }
    }
    return std::nullopt;
}

// Sprint 15 Day 10 [metal-viewport-array]: sister to captureLayer
// for BuiltInViewportIndex. Same two-shape walk (direct Output int +
// gl_PerVertex-style struct member). Returns the per-vertex
// gl_ViewportIndex as int32, or nullopt if the GS doesn't write the
// builtin.
std::optional<std::int32_t> Interpreter::captureViewportIndex() const {
    for (const auto& [varId, info] : module_.variables) {
        if (info.storageClass != spv::StorageClassOutput) continue;
        auto sIt = varStorage_.find(varId);
        if (sIt == varStorage_.end()) continue;
        auto tIt = module_.types.find(info.typeId);
        if (tIt == module_.types.end()) continue;
        const std::uint32_t pointee = tIt->second.pointeeType;
        auto pIt = module_.types.find(pointee);
        if (pIt == module_.types.end()) continue;
        // Shape 1: direct Output int decorated BuiltInViewportIndex.
        auto dIt = module_.decorations.find(varId);
        if (dIt != module_.decorations.end() && dIt->second.hasBuiltIn &&
            dIt->second.builtIn == spv::BuiltInViewportIndex) {
            if (!sIt->second.empty()) {
                std::int32_t v = 0;
                std::memcpy(&v, &sIt->second[0], sizeof(std::int32_t));
                return v;
            }
            return 0;
        }
        // Shape 2: member of a gl_PerVertex-style struct.
        if (pIt->second.kind != TypeInfo::Kind::Struct) continue;
        auto mdIt = module_.memberDecorations.find(pointee);
        if (mdIt == module_.memberDecorations.end()) continue;
        std::uint32_t runningOff = 0;
        for (std::size_t m = 0; m < pIt->second.memberTypes.size(); ++m) {
            const std::uint32_t memberType = pIt->second.memberTypes[m];
            const std::uint32_t memberWidth = module_.scalarWidth(memberType);
            auto mdm = mdIt->second.perMember.find(static_cast<std::uint32_t>(m));
            if (mdm != mdIt->second.perMember.end() && mdm->second.hasBuiltIn
                && mdm->second.builtIn == spv::BuiltInViewportIndex) {
                if (runningOff < sIt->second.size()) {
                    std::int32_t v = 0;
                    std::memcpy(&v, &sIt->second[runningOff], sizeof(std::int32_t));
                    return v;
                }
                return 0;
            }
            runningOff += memberWidth;
        }
    }
    return std::nullopt;
}

bool Interpreter::captureTessLevels(float outer[4], float inner[2]) const {
    // Scan Output variables for gl_TessLevelOuter / gl_TessLevelInner
    // (BuiltIn = 11 / 12 respectively). These are always arrays of
    // float in GLSL: outer[4] for triangles/quads/isolines (the first
    // `genMode`-dependent count of entries is meaningful; Triangles
    // uses [0..2], Quads [0..3], Isolines [0..1]) and inner[2]
    // (Triangles uses [0], Quads [0..1], Isolines unused).
    //
    // glslang emits them as direct Output-decorated variables (not as
    // members of a gl_PerVertex-style block — gl_PerVertex doesn't
    // include the tess levels). Shape walk:
    //   1. Output var decorated BuiltInTessLevelOuter — pointee is
    //      Array<float, 4>, storage is 4 flat floats.
    //   2. Output var decorated BuiltInTessLevelInner — pointee is
    //      Array<float, 2>, storage is 2 flat floats.
    bool anyWritten = false;
    for (const auto& [varId, info] : module_.variables) {
        if (info.storageClass != spv::StorageClassOutput) continue;
        auto dIt = module_.decorations.find(varId);
        if (dIt == module_.decorations.end() || !dIt->second.hasBuiltIn) continue;
        const std::uint32_t bi = dIt->second.builtIn;
        auto sIt = varStorage_.find(varId);
        if (sIt == varStorage_.end()) continue;
        const auto& storage = sIt->second;
        if (bi == 11 /*BuiltInTessLevelOuter*/) {
            for (std::uint32_t k = 0; k < 4 && k < storage.size(); ++k) {
                outer[k] = storage[k];
            }
            anyWritten = true;
        } else if (bi == 12 /*BuiltInTessLevelInner*/) {
            for (std::uint32_t k = 0; k < 2 && k < storage.size(); ++k) {
                inner[k] = storage[k];
            }
            anyWritten = true;
        }
    }
    return anyWritten;
}

bool Interpreter::captureTcsOutputForInvocation(std::int32_t invocationID,
                                                EmulatedVertex& out) const {
    // Walk Output variables looking for a gl_out[]-shaped one:
    // pointer to Array<gl_PerVertex-like Struct, N>. Read slice at
    // scalar-offset `invocationID * perVertexWidth` for this
    // invocation's gl_Position / gl_ClipDistance / gl_CullDistance.
    //
    // Initialize out with safe defaults — if no gl_out is found we
    // still return a well-formed vertex (useful when the TCS shader
    // is effectively a stub).
    out.position[0] = 0.0f;
    out.position[1] = 0.0f;
    out.position[2] = 0.0f;
    out.position[3] = 1.0f;
    out.varyings.clear();
    out.clipDistance.clear();
    out.cullDistance.clear();

    bool foundBuiltInGlOut = false;
    for (const auto& [varId, info] : module_.variables) {
        if (info.storageClass != spv::StorageClassOutput) continue;
        auto tIt = module_.types.find(info.typeId);
        if (tIt == module_.types.end()) continue;
        auto pIt = module_.types.find(tIt->second.pointeeType);
        if (pIt == module_.types.end()) continue;
        // Must be Array/RuntimeArray-of-Struct (gl_out[gl_PerVertex]).
        if (pIt->second.kind != TypeInfo::Kind::Array &&
            pIt->second.kind != TypeInfo::Kind::RuntimeArray) continue;
        auto eIt = module_.types.find(pIt->second.componentType);
        if (eIt == module_.types.end() ||
            eIt->second.kind != TypeInfo::Kind::Struct) continue;
        // Must have at least one BuiltIn-decorated member (gl_PerVertex
        // signature).
        auto mdIt = module_.memberDecorations.find(pIt->second.componentType);
        if (mdIt == module_.memberDecorations.end()) continue;
        bool hasBuiltInMember = false;
        for (const auto& [midx, mdec] : mdIt->second.perMember) {
            if (mdec.hasBuiltIn) { hasBuiltInMember = true; break; }
        }
        if (!hasBuiltInMember) continue;

        auto sIt = varStorage_.find(varId);
        if (sIt == varStorage_.end()) continue;
        const auto& storage = sIt->second;
        const std::uint32_t perVertexW =
            module_.scalarWidth(pIt->second.componentType);
        const std::uint32_t base =
            static_cast<std::uint32_t>(invocationID) * perVertexW;

        // Walk struct members + copy BuiltIn-decorated ones.
        std::uint32_t runningOff = 0;
        for (std::size_t m = 0; m < eIt->second.memberTypes.size(); ++m) {
            const std::uint32_t memType = eIt->second.memberTypes[m];
            const std::uint32_t memW = module_.scalarWidth(memType);
            auto mm = mdIt->second.perMember.find(static_cast<std::uint32_t>(m));
            if (mm != mdIt->second.perMember.end() && mm->second.hasBuiltIn) {
                const std::uint32_t bi = mm->second.builtIn;
                if (bi == spv::BuiltInPosition) {
                    for (int k = 0; k < 4 && static_cast<std::uint32_t>(k) < memW
                         && base + runningOff + k < storage.size(); ++k) {
                        out.position[k] = storage[base + runningOff + k];
                    }
                } else if (bi == spv::BuiltInPointSize) {
                    // Sprint 8 #8 β.2 Day 2 (CKPT70): capture gl_out[i].
                    // gl_PointSize so downstream stage (TES gl_in[].
                    // gl_PointSize) can read it. Required for CTS
                    // data_pass_through pointsize variants.
                    //
                    // Only overwrite EmulatedVertex.pointSize (default
                    // 1.0) if storage value is non-zero — without this
                    // guard, non-pointsize variants where the TCS
                    // leaves gl_out[].gl_PointSize unwritten capture
                    // a zero from the default-init storage and
                    // propagate 0.0 down the chain instead of GL's
                    // implicit 1.0 default. Heuristic: GL spec says
                    // gl_PointSize is "implementation-defined > 0" if
                    // unwritten, so 0.0 is a reliable "unwritten" sentinel
                    // for our path. Test cases that legitimately write
                    // 0.0 to gl_PointSize (pathological) lose precision
                    // but those tests don't currently exist in our matrix.
                    if (memW > 0 && base + runningOff < storage.size() &&
                        storage[base + runningOff] != 0.0f) {
                        out.pointSize = storage[base + runningOff];
                    }
                } else if (bi == spv::BuiltInClipDistance) {
                    for (std::uint32_t k = 0; k < memW &&
                         base + runningOff + k < storage.size(); ++k) {
                        out.clipDistance.push_back(storage[base + runningOff + k]);
                    }
                } else if (bi == spv::BuiltInCullDistance) {
                    for (std::uint32_t k = 0; k < memW &&
                         base + runningOff + k < storage.size(); ++k) {
                        out.cullDistance.push_back(storage[base + runningOff + k]);
                    }
                }
            }
            runningOff += memW;
        }
        foundBuiltInGlOut = true;
        break;
    }

    // Sprint 8 #8 β.2 (CKPT69): also capture USER-block per-vertex
    // outputs. data_pass_through TCS writes
    //   `out OUT_TC { vec4 tc_position; ... } out_data[];`
    // alongside the gl_out[gl_PerVertex] block. Both are Output
    // Array<Struct, N> shapes, but the user block's struct has NO
    // BuiltIn-decorated members. We walk Outputs again, find one or
    // more user-block-shaped variables, and resolve every name in
    // `outputVaryingNames_` (= TCS user-output member names supplied
    // by the caller) against any user block's member-name list. The
    // matching member's invocationID slice is concatenated into
    // out.varyings in outputVaryingNames_ order so downstream
    // EmulatedVertex → PerVertexInput slicing (using the same widths
    // array the caller supplied) reproduces the same ordering on the
    // TES / GS side.
    for (std::size_t k = 0; k < outputVaryingNames_.size(); ++k) {
        const std::string& wantName = outputVaryingNames_[k];
        const std::uint32_t expectedW =
            (k < outputVaryingWidths_.size()) ? outputVaryingWidths_[k] : 0;
        std::vector<float> v(expectedW, 0.0f);
        bool resolved = false;
        for (const auto& [varId, info] : module_.variables) {
            if (resolved) break;
            if (info.storageClass != spv::StorageClassOutput) continue;
            if (info.name == wantName) {
                auto tIt = module_.types.find(info.typeId);
                if (tIt != module_.types.end()) {
                    auto pIt = module_.types.find(tIt->second.pointeeType);
                    if (pIt != module_.types.end() &&
                        (pIt->second.kind == TypeInfo::Kind::Array ||
                         pIt->second.kind == TypeInfo::Kind::RuntimeArray)) {
                        auto eIt = module_.types.find(pIt->second.componentType);
                        if (eIt != module_.types.end() &&
                            eIt->second.kind != TypeInfo::Kind::Struct) {
                            auto sIt = varStorage_.find(varId);
                            if (sIt != varStorage_.end()) {
                                const auto& storage = sIt->second;
                                const std::uint32_t elemW =
                                    module_.scalarWidth(pIt->second.componentType);
                                const std::uint32_t base =
                                    static_cast<std::uint32_t>(invocationID) * elemW;
                                const std::uint32_t copyW =
                                    std::min(elemW, expectedW);
                                for (std::uint32_t kk = 0;
                                     kk < copyW && base + kk < storage.size();
                                     ++kk) {
                                    v[kk] = storage[base + kk];
                                }
                                resolved = true;
                                break;
                            }
                        }
                    }
                }
            }
            auto tIt = module_.types.find(info.typeId);
            if (tIt == module_.types.end()) continue;
            auto pIt = module_.types.find(tIt->second.pointeeType);
            if (pIt == module_.types.end() ||
                (pIt->second.kind != TypeInfo::Kind::Array &&
                 pIt->second.kind != TypeInfo::Kind::RuntimeArray)) continue;
            auto eIt = module_.types.find(pIt->second.componentType);
            if (eIt == module_.types.end() ||
                eIt->second.kind != TypeInfo::Kind::Struct) continue;
            auto mnIt = module_.memberNames.find(pIt->second.componentType);
            if (mnIt == module_.memberNames.end()) continue;
            // Skip the gl_PerVertex block — its members are BuiltIns.
            // The user block's struct has no BuiltIn member decorations
            // (or has them but for other slots — we still allow a name
            // match against any non-BuiltIn-only member).
            auto mdIt = module_.memberDecorations.find(pIt->second.componentType);
            auto sIt = varStorage_.find(varId);
            if (sIt == varStorage_.end()) continue;
            const auto& storage = sIt->second;
            const std::uint32_t perVertexW =
                module_.scalarWidth(pIt->second.componentType);
            const std::uint32_t base =
                static_cast<std::uint32_t>(invocationID) * perVertexW;
            std::uint32_t runningOff = 0;
            for (std::size_t m = 0; m < eIt->second.memberTypes.size(); ++m) {
                const std::uint32_t memW =
                    module_.scalarWidth(eIt->second.memberTypes[m]);
                bool isBuiltInMember = false;
                if (mdIt != module_.memberDecorations.end()) {
                    auto mm = mdIt->second.perMember.find(
                        static_cast<std::uint32_t>(m));
                    if (mm != mdIt->second.perMember.end() &&
                        mm->second.hasBuiltIn) {
                        isBuiltInMember = true;
                    }
                }
                if (!isBuiltInMember) {
                    auto nIt = mnIt->second.find(static_cast<std::uint32_t>(m));
                    if (nIt != mnIt->second.end() &&
                        nIt->second == wantName) {
                        const std::uint32_t copyW = std::min(memW, expectedW);
                        for (std::uint32_t kk = 0;
                             kk < copyW && base + runningOff + kk < storage.size();
                             ++kk) {
                            v[kk] = storage[base + runningOff + kk];
                        }
                        resolved = true;
                        break;
                    }
                }
                runningOff += memW;
            }
        }
        out.varyings.insert(out.varyings.end(), v.begin(), v.end());
    }

    return foundBuiltInGlOut || !outputVaryingNames_.empty();
}

	void Interpreter::captureTcsPatchOutputs(
	    std::unordered_map<std::string, std::vector<float>>& out) const
	{
    // Walk Output variables. Any with DecorationPatch is a
    // `patch out <type>` varying; copy its flat-float storage
    // into the caller's map, keyed by variable NAME (OpName).
    // Variables without DecorationPatch (gl_out[] array,
    // gl_TessLevel*) are skipped — those flow through
    // captureTcsOutputForInvocation / captureTessLevels.
    //
    // Sprint 8 #8 β.2 Day 2 (CKPT70): no longer requires
    // DecorationLocation. data_pass_through declares
    // `patch out vec4 tc_patch_data;` without explicit
    // `layout(location=N)`; glslang emits no Location.
    // Cross-stage matching is by name (CKPT66/69 SPIR-V two-
    // regime distinction extended to per-patch interface).
    for (const auto& [varId, info] : module_.variables) {
        if (info.storageClass != spv::StorageClassOutput) continue;
        auto dIt = module_.decorations.find(varId);
        if (dIt == module_.decorations.end()) continue;
        if (!dIt->second.isPatch) continue;
        if (info.name.empty()) continue;
        auto sIt = varStorage_.find(varId);
        if (sIt == varStorage_.end()) continue;
        if (sIt->second.empty()) continue;
        // Sprint 8 #8 β.2 Day 2 (CKPT70): skip overwriting the
        // existing map entry when this invocation didn't write the
        // variable. data_pass_through's TCS conditional
        //   `if (gl_InvocationID == 0) { tc_patch_data = ...; }`
        // means invocation 1 has zero-initialised tc_patch_data
        // storage; pre-CKPT70 the unconditional overwrite clobbered
        // invocation 0's correct value with invocation 1's zeros.
        // Skip-on-not-written preserves the last-actual-write.
        if (writtenOutputVars_.count(varId) == 0) continue;
        // Overwrite any existing entry — last-write-wins across
        // invocations (GL 4.6 §11.2.2 permits this when multiple
        // TCS invocations write the same patch-out).
	        out[info.name] = sIt->second;
	    }
	}

	void Interpreter::captureTcsSharedOutputs(TcsSharedOutputStorage& out) const
	{
	    for (const auto& [varId, info] : module_.variables) {
	        if (info.storageClass != spv::StorageClassOutput) {
	            continue;
	        }
	        auto sIt = varStorage_.find(varId);
	        if (sIt == varStorage_.end()) {
	            continue;
	        }
	        out[varId] = sIt->second;
	    }
	}

	void Interpreter::emitVertex(std::vector<EmulatedVertex>& out, std::uint32_t stream) {
    // Capture gl_Position and named output varyings from their
    // respective output variables' storage.
    EmulatedVertex ev;
    ev.stream = stream;
    ev.position[0] = currentPosition_[0];
    ev.position[1] = currentPosition_[1];
    ev.position[2] = currentPosition_[2];
    ev.position[3] = currentPosition_[3];
    // Read each output varying's current value from varStorage_.
    for (std::size_t k = 0; k < outputVaryingNames_.size(); ++k) {
        std::vector<float> v;
        v.assign(outputVaryingWidths_[k], 0.0f);
        const std::string& wantName = outputVaryingNames_[k];
        bool matched = false;
        // Find the Output variable by name.
        for (const auto& [varId, info] : module_.variables) {
            if (info.storageClass != spv::StorageClassOutput) continue;
            if (info.name == wantName) {
                auto sIt = varStorage_.find(varId);
                if (sIt != varStorage_.end()) {
                    for (std::size_t j = 0; j < v.size() && j < sIt->second.size(); ++j) {
                        v[j] = sIt->second[j];
                    }
                }
                matched = true;
                break;
            }
            auto tIt = module_.types.find(info.typeId);
            if (tIt == module_.types.end()) continue;
            const std::uint32_t pointeeId = tIt->second.pointeeType;
            auto pIt = module_.types.find(pointeeId);
            if (pIt == module_.types.end() || pIt->second.kind != TypeInfo::Kind::Struct) continue;
            auto mnIt = module_.memberNames.find(pointeeId);
            if (mnIt == module_.memberNames.end()) continue;
            std::uint32_t runningOff = 0;
            for (std::size_t m = 0; m < pIt->second.memberTypes.size(); ++m) {
                const std::uint32_t memW = module_.scalarWidth(pIt->second.memberTypes[m]);
                auto nameIt = mnIt->second.find(static_cast<std::uint32_t>(m));
                if (nameIt != mnIt->second.end() && nameIt->second == wantName) {
                    auto sIt = varStorage_.find(varId);
                    if (sIt != varStorage_.end()) {
                        for (std::size_t j = 0; j < v.size() && runningOff + j < sIt->second.size(); ++j) {
                            v[j] = sIt->second[runningOff + j];
                        }
                    }
                    matched = true;
                    break;
                }
                runningOff += memW;
            }
            if (matched) break;
        }
        ev.varyings.insert(ev.varyings.end(), v.begin(), v.end());
    }
    // Capture gl_ClipDistance / gl_CullDistance current storage.
    // A GS that doesn't write these arrays will leave the storage
    // zero-initialised (from initVariables), which preserves the VS-
    // supplied values iff we seeded gl_in[].gl_ClipDistance[] into
    // the gl_PerVertex output block — we don't, so zero is the
    // semantic "GS didn't touch these".
    captureClipCull(ev.clipDistance, ev.cullDistance);
    // Capture gl_Layer. `std::nullopt` means the GS didn't write
    // BuiltInLayer — the caller (`emulateGeometryDraw`) leaves
    // ev.layer at its default 0 and won't set EmulatedDraw::
    // hasLayer. If any single vertex wrote it, hasLayer flips on
    // for the whole draw (the synth VS emits the output slot).
    if (auto layerValue = captureLayer(); layerValue.has_value()) {
        ev.layer = *layerValue;
        didWriteLayer_ = true;
    }
    // Sprint 15 Day 10 [metal-viewport-array]: capture gl_ViewportIndex
    // (sister to gl_Layer). Always captured; emission gated on env at
    // the synth-VS site.
    if (auto vi = captureViewportIndex(); vi.has_value()) {
        ev.viewportIndex = *vi;
        didWriteViewportIndex_ = true;
    }
    if (auto pointSizeValue = capturePointSize(); pointSizeValue.has_value()) {
        ev.pointSize = *pointSizeValue;
        didWritePointSize_ = true;
    }
    if (auto primIdValue = capturePrimitiveID(); primIdValue.has_value()) {
        ev.primitiveId = *primIdValue;
        didWritePrimitiveID_ = true;
    }
    out.push_back(std::move(ev));
}

Value Interpreter::evalExtInst(std::uint32_t glslOp,
                               const std::uint32_t* operands,
                               std::uint32_t nOperands,
                               bool resultIsDouble) {
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
    auto clearDoubleSidecar = [](Value& v) {
        v.hasDouble = false;
        if (v.isFloatKind()) {
            for (int k = 0; k < v.componentCount(); ++k) {
                v.d[k] = static_cast<double>(v.f[k]);
            }
        }
    };
    auto scalarMap = [&](float (*fn)(float)) {
        Value r = a;
        for (int k = 0; k < a.componentCount(); ++k) r.f[k] = fn(a.f[k]);
        clearDoubleSidecar(r);
        return r;
    };
    auto binaryMap = [&](float (*fn)(float, float)) {
        Value r = a;
        for (int k = 0; k < a.componentCount(); ++k) r.f[k] = fn(a.f[k], b.f[k]);
        clearDoubleSidecar(r);
        return r;
    };
    auto ternaryMap = [&](float (*fn)(float, float, float)) {
        Value r = a;
        for (int k = 0; k < a.componentCount(); ++k) r.f[k] = fn(a.f[k], b.f[k], c.f[k]);
        clearDoubleSidecar(r);
        return r;
    };
    auto floatLane = [](const Value& v, int lane) {
        const int idx = std::min(lane, v.componentCount() - 1);
        return v.f[idx];
    };
    auto realLane = [](const Value& v, int lane) {
        const int idx = std::min(lane, v.componentCount() - 1);
        return v.hasDouble ? v.d[idx] : static_cast<double>(v.f[idx]);
    };
    auto intLane = [](const Value& v, int lane) {
        const int idx = std::min(lane, v.componentCount() - 1);
        return v.isIntKind() ? v.i[idx] : static_cast<std::int32_t>(v.f[idx]);
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
        case ::GLSLstd450Ldexp: {
            Value r = a;
            r.hasDouble = true;
            for (int k = 0; k < a.componentCount(); ++k) {
                r.d[k] = std::ldexp(realLane(a, k), intLane(b, k));
                r.f[k] = static_cast<float>(r.d[k]);
            }
            return r;
        }
        case ::GLSLstd450Step: {
            // step(edge, x) — edge is operand0 in GLSL, x is operand1.
            Value r = b;   // result matches x shape
            for (int k = 0; k < b.componentCount(); ++k) r.f[k] = (b.f[k] < a.f[k]) ? 0.0f : 1.0f;
            clearDoubleSidecar(r);
            return r;
        }
        case ::GLSLstd450UnpackDouble2x32: {
            Value r;
            r.kind = Value::Kind::UInt2;
            const double x = realLane(a, 0);
            std::uint64_t bits = 0;
            std::memcpy(&bits, &x, sizeof(bits));
            r.i[0] = static_cast<std::int32_t>(
                static_cast<std::uint32_t>(bits & 0xFFFFFFFFull));
            r.i[1] = static_cast<std::int32_t>(
                static_cast<std::uint32_t>(bits >> 32u));
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
            clearDoubleSidecar(r);
            return r;
        }

        // ─ Vector reductions ─
        case ::GLSLstd450Length: {
            Value r;
            r.kind = Value::Kind::Float;
            double s = 0.0;
            for (int k = 0; k < a.componentCount(); ++k) {
                const double x = realLane(a, k);
                s += x * x;
            }
            r.d[0] = std::sqrt(s);
            r.f[0] = static_cast<float>(r.d[0]);
            r.hasDouble = resultIsDouble;
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
            r.d[0] = static_cast<double>(r.f[0]);
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
            clearDoubleSidecar(r);
            return r;
        }
        case ::GLSLstd450Cross: {
            Value r;
            r.kind = Value::Kind::Float3;
            r.f[0] = a.f[1] * b.f[2] - a.f[2] * b.f[1];
            r.f[1] = a.f[2] * b.f[0] - a.f[0] * b.f[2];
            r.f[2] = a.f[0] * b.f[1] - a.f[1] * b.f[0];
            clearDoubleSidecar(r);
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
            clearDoubleSidecar(r);
            return r;
        }
        case ::GLSLstd450FaceForward: {
            // faceforward(N, I, Nref) = dot(Nref, I) < 0 ? N : -N
            Value r = a;
            double dotNrefI = 0.0;
            for (int k = 0; k < a.componentCount(); ++k) {
                dotNrefI += realLane(c, k) * realLane(b, k);
            }
            const double sign = dotNrefI < 0.0 ? 1.0 : -1.0;
            r.hasDouble = true;
            for (int k = 0; k < a.componentCount(); ++k) {
                r.d[k] = realLane(a, k) * sign;
                r.f[k] = static_cast<float>(r.d[k]);
            }
            return r;
        }
        case ::GLSLstd450Refract: {
            // refract(I, N, eta) per GLSL 8.5.
            Value r = a;
            double dotNI = 0.0;
            for (int k = 0; k < a.componentCount(); ++k) {
                dotNI += realLane(b, k) * realLane(a, k);
            }
            const double eta = realLane(c, 0);
            const double kTerm = 1.0 - eta * eta * (1.0 - dotNI * dotNI);
            r.hasDouble = true;
            if (kTerm < 0.0) {
                for (int k = 0; k < a.componentCount(); ++k) {
                    r.d[k] = 0.0;
                    r.f[k] = 0.0f;
                }
            } else {
                const double scale = eta * dotNI + std::sqrt(kTerm);
                for (int k = 0; k < a.componentCount(); ++k) {
                    r.d[k] = eta * realLane(a, k) - scale * realLane(b, k);
                    r.f[k] = static_cast<float>(r.d[k]);
                }
            }
            return r;
        }
        case ::GLSLstd450Fma: {
            // Sprint 8 SCOUT-W (f) regression-fix (CKPT72): fma(a, b, c) =
            // a * b + c. SPIR-V Fma = 3 operands. Required for VS-only-TF
            // CPU emul on programs that use the GLSL `fma()` built-in
            // (e.g. CTS gpu_shader5.fma_accuracy). Pre-CKPT72 the
            // unsupported GLSLstd450 op 50 caused interpreter bail →
            // VS-only-TF returned ok=false → fall-through-to-legacy path
            // didn't capture TF for VS-only programs → test got zeros.
            // CKPT68's VS-only-TF gate relaxation (`emulProgram == nullptr
            // → !emulProgram->geometryEmulated`) widened the population
            // of programs hitting this path; CKPT72 closes the
            // missing-op gap with a faithful Fma evaluator.
            Value r = a;
            for (int k = 0; k < a.componentCount(); ++k) {
                r.f[k] = a.f[k] * b.f[k] + c.f[k];
            }
            clearDoubleSidecar(r);
            return r;
        }

        default:
            bail("OpExtInst: unsupported GLSL.std.450 op " + std::to_string(glslOp));
            return a;
    }
}

bool Interpreter::executeTes(EmulatedVertex& out,
                             const std::vector<PerVertexInput>& patchInputs) {
    if (!module_.haveFuncBody) {
        diagnostic_ = "SPIR-V module has no function body";
        return false;
    }
    // initVariables populates gl_in[] from `patchInputs` (the VS
    // pre-pass output for each input patch vertex) via the shared
    // Geometry/TessEvaluation arm. Built-ins (gl_TessCoord /
    // gl_PrimitiveID) are still seeded from tesTessCoord_ /
    // tesPrimitiveId_ set by setTesInputs.
    initVariables(patchInputs);
    currentOutVaryings_.clear();
    currentOutVaryings_.resize(outputVaryingNames_.size());
    std::vector<EmulatedVertex> dummy;
    if (!execute(patchInputs, dummy)) return false;
    out.position[0] = currentPosition_[0];
    out.position[1] = currentPosition_[1];
    out.position[2] = currentPosition_[2];
    out.position[3] = currentPosition_[3];
    // Phase 3f-6: capture user output varyings by name, matching the
    // executeVs logic so the synth VS receives values to forward to
    // `[[user(locnN)]]` slots. Block-scoped outputs fall through to
    // the member-name walk shape (2).
    out.varyings.clear();
    for (std::size_t k = 0; k < outputVaryingNames_.size(); ++k) {
        std::vector<float> v;
        v.assign(outputVaryingWidths_[k], 0.0f);
        const std::string& wantName = outputVaryingNames_[k];
        bool matched = false;
        for (const auto& [varId, info] : module_.variables) {
            if (info.storageClass != spv::StorageClassOutput) continue;
            if (info.name == wantName) {
                auto sIt = varStorage_.find(varId);
                if (sIt != varStorage_.end()) {
                    for (std::size_t j = 0; j < v.size() && j < sIt->second.size(); ++j) {
                        v[j] = sIt->second[j];
                    }
                }
                matched = true;
                break;
            }
            auto tIt = module_.types.find(info.typeId);
            if (tIt == module_.types.end()) continue;
            const std::uint32_t pointeeId = tIt->second.pointeeType;
            auto pIt = module_.types.find(pointeeId);
            if (pIt == module_.types.end() || pIt->second.kind != TypeInfo::Kind::Struct) continue;
            auto mnIt = module_.memberNames.find(pointeeId);
            if (mnIt == module_.memberNames.end()) continue;
            std::uint32_t runningOff = 0;
            for (std::size_t m = 0; m < pIt->second.memberTypes.size(); ++m) {
                const std::uint32_t memW = module_.scalarWidth(pIt->second.memberTypes[m]);
                auto nameIt = mnIt->second.find(static_cast<std::uint32_t>(m));
                if (nameIt != mnIt->second.end() && nameIt->second == wantName) {
                    auto sIt = varStorage_.find(varId);
                    if (sIt != varStorage_.end()) {
                        for (std::size_t j = 0; j < v.size() && runningOff + j < sIt->second.size(); ++j) {
                            v[j] = sIt->second[runningOff + j];
                        }
                    }
                    matched = true;
                    break;
                }
                runningOff += memW;
            }
            if (matched) break;
        }
        out.varyings.insert(out.varyings.end(), v.begin(), v.end());
    }
    captureClipCull(out.clipDistance, out.cullDistance);
    return !errored_;
}

void Interpreter::resetExecutionState() {
    valueStore_.clear();
    compositeValues_.clear();
    matrixColumns_.clear();
    varStorage_.clear();
    varDoubleStorage_.clear();
    accessChains_.clear();
    writtenOutputVars_.clear();
    uboArrayVarMeta_.clear();
    uboVarMeta_.clear();
    ssboVarMeta_.clear();
    sampledImages_.clear();
    pendingImageWrites_.clear();
    currentPosition_ = {0.0f, 0.0f, 0.0f, 1.0f};
    currentOutVaryings_.clear();
    diagnostic_.clear();
    errored_ = false;
}

bool Interpreter::executeVs(EmulatedVertex& out) {
    resetExecutionState();
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
    out.doubleVaryings.clear();
    for (std::size_t k = 0; k < outputVaryingNames_.size(); ++k) {
        std::vector<float> v;
        v.assign(outputVaryingWidths_[k], 0.0f);
        std::vector<double> dv(outputVaryingWidths_[k], 0.0);
        const std::string& wantName = outputVaryingNames_[k];
        bool matched = false;
        for (const auto& [varId, info] : module_.variables) {
            if (info.storageClass != spv::StorageClassOutput) continue;
            // Shape 1: top-level varying variable with matching name.
            if (info.name == wantName) {
                auto sIt = varStorage_.find(varId);
                if (sIt != varStorage_.end()) {
                    for (std::size_t j = 0; j < v.size() && j < sIt->second.size(); ++j) {
                        v[j] = sIt->second[j];
                    }
                    auto dIt = varDoubleStorage_.find(varId);
                    for (std::size_t j = 0; j < dv.size(); ++j) {
                        dv[j] = (dIt != varDoubleStorage_.end() && j < dIt->second.size())
                            ? dIt->second[j] : static_cast<double>(v[j]);
                    }
                }
                matched = true;
                break;
            }
            // Shape 2: user output interface block. The SPIR-V
            // variable has the BLOCK name (or empty), not the
            // member name. Walk its Struct pointee and find the
            // member whose OpMemberName matches wantName; copy
            // its slice of the block's varStorage. CTS
            // `limits.max_input_components` uses this shape via
            // `out Vertex { flat out ivec4 vs_gs_out[16]; };`.
            auto tIt = module_.types.find(info.typeId);
            if (tIt == module_.types.end()) continue;
            const std::uint32_t pointeeId = tIt->second.pointeeType;
            auto pIt = module_.types.find(pointeeId);
            if (pIt == module_.types.end() || pIt->second.kind != TypeInfo::Kind::Struct) continue;
            auto mnIt = module_.memberNames.find(pointeeId);
            if (mnIt == module_.memberNames.end()) continue;
            std::uint32_t runningOff = 0;
            for (std::size_t m = 0; m < pIt->second.memberTypes.size(); ++m) {
                const std::uint32_t memW = module_.scalarWidth(pIt->second.memberTypes[m]);
                auto nameIt = mnIt->second.find(static_cast<std::uint32_t>(m));
                if (nameIt != mnIt->second.end() && nameIt->second == wantName) {
                    auto sIt = varStorage_.find(varId);
                    if (sIt != varStorage_.end()) {
                        for (std::size_t j = 0; j < v.size() && runningOff + j < sIt->second.size(); ++j) {
                            v[j] = sIt->second[runningOff + j];
                        }
                        auto dIt = varDoubleStorage_.find(varId);
                        for (std::size_t j = 0; j < dv.size(); ++j) {
                            dv[j] = (dIt != varDoubleStorage_.end() &&
                                     runningOff + j < dIt->second.size())
                                ? dIt->second[runningOff + j]
                                : static_cast<double>(v[j]);
                        }
                    }
                    matched = true;
                    break;
                }
                runningOff += memW;
            }
            if (matched) break;
        }
        out.varyings.insert(out.varyings.end(), v.begin(), v.end());
        out.doubleVaryings.insert(out.doubleVaryings.end(), dv.begin(), dv.end());
    }
    // Propagate the VS's gl_ClipDistance[] / gl_CullDistance[] so the
    // emulator's caller can feed them into the GS's gl_in[] and use
    // cull-distance values for the pre-GS primitive cull check
    // (GL 4.6 §13.6).
    captureClipCull(out.clipDistance, out.cullDistance);
    // Sprint 8 #8 β.2 Day 3 (CKPT71): VS gl_PointSize capture for the
    // tess pre-pass chain. capturePointSize walks Output variables
    // looking for BuiltInPointSize (direct or struct member) and
    // returns the stored value via the helper's checkStoredValue
    // zero-sentinel filter (0.0 → nullopt). When the VS doesn't
    // write gl_PointSize, EmulatedVertex.pointSize keeps default 1.0.
    if (auto ps = capturePointSize(); ps.has_value()) {
        out.pointSize = *ps;
    }
    return !errored_;
}

bool Interpreter::execute(const std::vector<PerVertexInput>& inputs,
                          std::vector<EmulatedVertex>& emitted,
                          std::vector<std::size_t>& primEnds) {
    if (!module_.haveFuncBody) {
        diagnostic_ = "SPIR-V module has no function body";
        return false;
    }
    // Snapshot starting emit index — on implicit EndPrimitive at
    // OpReturn we emit a final boundary iff any vertices appeared
    // since the last explicit EndPrimitive.
    const std::size_t primEndsStart = emitted.size();
    // VS's `executeVs` already called initVariables+currentOutVaryings
    // setup before forwarding here — skip them in that case. The dummy
    // emitted buffer won't receive any vertices for VS (no OpEmitVertex
    // in VS GLSL), but we keep the check generic.
    if (stage_ == Stage::Geometry) {
        initVariables(inputs);
        currentOutVaryings_.clear();
        currentOutVaryings_.resize(outputVaryingNames_.size());
    }

    // Build label → instruction offset map for the currently executing
    // function. Sprint 18 Bank C-2 adds simple helper-function calls for
    // viewport_array GS bodies, so the map follows the active call frame.
    auto buildLabelMap = [&](std::size_t start, std::size_t end) {
        std::unordered_map<std::uint32_t, std::size_t> labels;
        std::size_t i = start;
        while (i < end) {
            const std::uint32_t inst = module_.words[i];
            const std::uint16_t opcode = inst & 0xFFFF;
            const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
            if (opcode == spv::OpLabel && wc >= 2) {
                labels[module_.words[i + 1]] = i + wc;  // first instr after label
            }
            i += wc;
        }
        return labels;
    };

    std::size_t pc = module_.funcBodyStart;
    std::size_t currentFuncEnd = module_.funcBodyEnd;
    std::unordered_map<std::uint32_t, std::size_t> labelMap =
        buildLabelMap(pc, currentFuncEnd);
    std::uint32_t previousLabel = 0;
    std::uint32_t currentLabel = 0;
    struct CallFrame {
        std::size_t returnPc = 0;
        std::size_t functionEnd = 0;
        std::unordered_map<std::uint32_t, std::size_t> labels;
        std::uint32_t previousLabel = 0;
        std::uint32_t currentLabel = 0;
        std::uint32_t calleeFunctionId = 0;
        std::unordered_map<std::uint32_t, std::uint32_t> pointerAliases;
    };
    std::vector<CallFrame> callStack;
    std::unordered_set<std::uint32_t> activeFunctions;
    std::unordered_map<std::uint32_t, std::uint32_t> functionPointerAliases;
    if (module_.entryPoint != 0) {
        activeFunctions.insert(module_.entryPoint);
    }

    auto truthy = [](const Value& v, int lane) -> bool {
        if (v.kind == Value::Kind::Bool) {
            return v.bval;
        }
        const int idx = std::min(lane, v.componentCount() - 1);
        if (v.isIntKind()) {
            return v.i[idx] != 0;
        }
        if (v.isFloatKind()) {
            return v.f[idx] != 0.0f;
        }
        return false;
    };
    auto boolVectorWidthForType = [&](std::uint32_t typeId) -> int {
        auto tIt = module_.types.find(typeId);
        if (tIt == module_.types.end()) {
            return 1;
        }
        const TypeInfo& t = tIt->second;
        if (t.kind != TypeInfo::Kind::Vec2 &&
            t.kind != TypeInfo::Kind::Vec3 &&
            t.kind != TypeInfo::Kind::Vec4) {
            return 1;
        }
        auto cIt = module_.types.find(t.componentType);
        if (cIt == module_.types.end() ||
            cIt->second.kind != TypeInfo::Kind::Bool) {
            return 1;
        }
        return t.kind == TypeInfo::Kind::Vec2 ? 2 :
               t.kind == TypeInfo::Kind::Vec3 ? 3 : 4;
    };
    auto makeBoolResult = [&](std::uint32_t typeId,
                              const std::array<bool, 4>& lanes,
                              int fallbackWidth) -> Value {
        const int width = std::max(1, boolVectorWidthForType(typeId) > 1
            ? boolVectorWidthForType(typeId)
            : fallbackWidth);
        Value r;
        if (width <= 1) {
            r.kind = Value::Kind::Bool;
            r.bval = lanes[0];
            return r;
        }
        r.kind = width == 2 ? Value::Kind::Int2 :
                 width == 3 ? Value::Kind::Int3 : Value::Kind::Int4;
        for (int k = 0; k < width && k < 4; ++k) {
            r.i[k] = lanes[k] ? 1 : 0;
        }
        return r;
    };
    auto floatVectorWidthForType = [&](std::uint32_t typeId,
                                       int fallbackWidth) -> int {
        auto tIt = module_.types.find(typeId);
        if (tIt == module_.types.end()) {
            return std::clamp(fallbackWidth, 1, 4);
        }
        const TypeInfo& t = tIt->second;
        switch (t.kind) {
            case TypeInfo::Kind::Vec2: return 2;
            case TypeInfo::Kind::Vec3: return 3;
            case TypeInfo::Kind::Vec4: return 4;
            default: return std::clamp(fallbackWidth, 1, 4);
        }
    };
    auto floatKindForWidth = [](int width) -> Value::Kind {
        return width == 2 ? Value::Kind::Float2 :
               width == 3 ? Value::Kind::Float3 :
               width == 4 ? Value::Kind::Float4 :
                            Value::Kind::Float;
    };
    auto makeFloatValueForType = [&](std::uint32_t typeId,
                                     int fallbackWidth) -> Value {
        Value r;
        r.kind = floatKindForWidth(floatVectorWidthForType(typeId, fallbackWidth));
        return r;
    };
    auto realLane = [](const Value& v, int lane) -> double {
        const int idx = std::min(lane, v.componentCount() - 1);
        return v.hasDouble ? v.d[idx] : static_cast<double>(v.f[idx]);
    };
    auto floatScalarByteSizeForType = [&](std::uint32_t typeId) -> std::uint32_t {
        auto tIt = module_.types.find(typeId);
        if (tIt == module_.types.end()) {
            return 4;
        }
        const TypeInfo& t = tIt->second;
        if (t.kind == TypeInfo::Kind::Float) {
            return t.elementScalarWidth;
        }
        if (t.kind == TypeInfo::Kind::Matrix) {
            auto colIt = module_.types.find(t.componentType);
            if (colIt != module_.types.end() &&
                (colIt->second.kind == TypeInfo::Kind::Vec2 ||
                 colIt->second.kind == TypeInfo::Kind::Vec3 ||
                 colIt->second.kind == TypeInfo::Kind::Vec4)) {
                auto scalarIt = module_.types.find(colIt->second.componentType);
                if (scalarIt != module_.types.end() &&
                    scalarIt->second.kind == TypeInfo::Kind::Float) {
                    return scalarIt->second.elementScalarWidth;
                }
            }
        }
        if (t.kind == TypeInfo::Kind::Vec2 ||
            t.kind == TypeInfo::Kind::Vec3 ||
            t.kind == TypeInfo::Kind::Vec4) {
            auto cIt = module_.types.find(t.componentType);
            if (cIt != module_.types.end() &&
                cIt->second.kind == TypeInfo::Kind::Float) {
                return cIt->second.elementScalarWidth;
            }
        }
        return 4;
    };
    auto firstStructMemberType = [&](std::uint32_t typeId) -> std::uint32_t {
        auto tIt = module_.types.find(typeId);
        if (tIt == module_.types.end() ||
            tIt->second.kind != TypeInfo::Kind::Struct ||
            tIt->second.memberTypes.empty()) {
            return typeId;
        }
        return tIt->second.memberTypes[0];
    };
    auto storeExtInstOutParam = [&](std::uint32_t pointerId,
                                    const Value& v) -> bool {
        auto aliasIt = functionPointerAliases.find(pointerId);
        const std::uint32_t ptrId = aliasIt != functionPointerAliases.end()
            ? aliasIt->second
            : pointerId;

        if (module_.variables.find(ptrId) != module_.variables.end()) {
            storeToVar(ptrId, 0, v);
            return true;
        }

        auto acIt = accessChains_.find(ptrId);
        if (acIt != accessChains_.end()) {
            const AccessChainResult& ac = acIt->second;
            if (ac.isStorageBuffer) {
                storeToSSBO(ac.binding, ac.byteOffset, v, ac.leafTypeId);
            } else {
                storeToVar(ac.rootVarId, ac.scalarOffset, v);
            }
            return true;
        }

        bail("OpExtInst out-param: unsupported pointer target");
        return false;
    };
    auto matrixColumnsForId =
        [&](std::uint32_t id) -> const std::vector<Value>* {
            auto mIt = matrixColumns_.find(id);
            if (mIt != matrixColumns_.end()) return &mIt->second;
            auto cIt = module_.matrixConstants.find(id);
            if (cIt != module_.matrixConstants.end()) return &cIt->second;
            return nullptr;
        };
    auto matrixRowsForType = [&](std::uint32_t matrixTypeId,
                                 int fallbackRows) -> int {
        auto mIt = module_.types.find(matrixTypeId);
        if (mIt == module_.types.end() ||
            mIt->second.kind != TypeInfo::Kind::Matrix) {
            return std::clamp(fallbackRows, 1, 4);
        }
        auto cIt = module_.types.find(mIt->second.componentType);
        if (cIt == module_.types.end()) {
            return std::clamp(fallbackRows, 1, 4);
        }
        switch (cIt->second.kind) {
            case TypeInfo::Kind::Vec2: return 2;
            case TypeInfo::Kind::Vec3: return 3;
            case TypeInfo::Kind::Vec4: return 4;
            default: return 1;
        }
    };
    auto matrixColsForType = [&](std::uint32_t matrixTypeId,
                                 int fallbackCols) -> int {
        auto mIt = module_.types.find(matrixTypeId);
        if (mIt == module_.types.end() ||
            mIt->second.kind != TypeInfo::Kind::Matrix) {
            return std::clamp(fallbackCols, 1, 4);
        }
        return std::clamp(static_cast<int>(mIt->second.count), 1, 4);
    };
    auto squareMatrixSizeForColumns =
        [&](const std::vector<Value>& cols) -> int {
            if (cols.empty()) return 0;
            const int colCount = std::clamp<int>(
                static_cast<int>(cols.size()), 1, 4);
            const int rowCount = std::clamp(cols[0].componentCount(), 1, 4);
            return colCount == rowCount ? colCount : 0;
        };
    auto matrixElement =
        [&](const std::vector<Value>& cols, int row, int col) -> double {
            if (col < 0 || col >= static_cast<int>(cols.size())) return 0.0;
            return realLane(cols[col], row);
        };
    auto determinantFromColumns =
        [&](const std::vector<Value>& cols, int n) -> double {
            if (n == 2) {
                return matrixElement(cols, 0, 0) * matrixElement(cols, 1, 1) -
                       matrixElement(cols, 0, 1) * matrixElement(cols, 1, 0);
            }
            if (n == 3) {
                const double a00 = matrixElement(cols, 0, 0);
                const double a01 = matrixElement(cols, 0, 1);
                const double a02 = matrixElement(cols, 0, 2);
                const double a10 = matrixElement(cols, 1, 0);
                const double a11 = matrixElement(cols, 1, 1);
                const double a12 = matrixElement(cols, 1, 2);
                const double a20 = matrixElement(cols, 2, 0);
                const double a21 = matrixElement(cols, 2, 1);
                const double a22 = matrixElement(cols, 2, 2);
                return a00 * (a11 * a22 - a12 * a21) -
                       a01 * (a10 * a22 - a12 * a20) +
                       a02 * (a10 * a21 - a11 * a20);
            }
            return 0.0;
        };
    auto matrixCofactor =
        [&](const std::vector<Value>& cols, int n,
            int skipRow, int skipCol) -> double {
            if (n == 2) {
                const double minor = matrixElement(cols, 1 - skipRow, 1 - skipCol);
                return ((skipRow + skipCol) & 1) ? -minor : minor;
            }
            std::array<int, 2> rows{};
            std::array<int, 2> outCols{};
            int rCount = 0;
            int cCount = 0;
            for (int r = 0; r < 3; ++r) {
                if (r != skipRow) rows[rCount++] = r;
            }
            for (int c = 0; c < 3; ++c) {
                if (c != skipCol) outCols[cCount++] = c;
            }
            const double minor =
                matrixElement(cols, rows[0], outCols[0]) *
                matrixElement(cols, rows[1], outCols[1]) -
                matrixElement(cols, rows[0], outCols[1]) *
                matrixElement(cols, rows[1], outCols[0]);
            return ((skipRow + skipCol) & 1) ? -minor : minor;
        };
    auto inverseMatrixColumns =
        [&](const std::vector<Value>& cols, int n,
            bool hasDouble) -> std::vector<Value> {
            const double det = determinantFromColumns(cols, n);
            std::vector<Value> out;
            out.reserve(static_cast<std::size_t>(n));
            for (int col = 0; col < n; ++col) {
                Value outCol;
                outCol.kind = floatKindForWidth(n);
                outCol.hasDouble = hasDouble;
                for (int row = 0; row < n; ++row) {
                    const double v = matrixCofactor(cols, n, col, row) / det;
                    outCol.d[row] = v;
                    outCol.f[row] = static_cast<float>(v);
                }
                out.push_back(outCol);
            }
            return out;
        };
    auto applyMatrixElementwise =
        [&](std::uint32_t resultId, std::uint32_t leftId,
            std::uint32_t rightId, std::uint16_t op) -> bool {
            const auto* aCols = matrixColumnsForId(leftId);
            const auto* bCols = matrixColumnsForId(rightId);
            if (aCols == nullptr || bCols == nullptr) return false;
            std::vector<Value> outCols;
            const std::size_t cols = std::min(aCols->size(), bCols->size());
            outCols.reserve(cols);
            for (std::size_t c = 0; c < cols; ++c) {
                Value r = (*aCols)[c];
                const Value& a = (*aCols)[c];
                const Value& b = (*bCols)[c];
                const int n = std::min(a.componentCount(), b.componentCount());
                for (int k = 0; k < n; ++k) {
                    switch (op) {
                        case spv::OpFAdd: r.f[k] = a.f[k] + b.f[k]; break;
                        case spv::OpFSub: r.f[k] = a.f[k] - b.f[k]; break;
                        case spv::OpFMul: r.f[k] = a.f[k] * b.f[k]; break;
                        case spv::OpFDiv: r.f[k] = b.f[k] != 0.0f ? a.f[k] / b.f[k] : 0.0f; break;
                        default: break;
                    }
                }
                outCols.push_back(r);
            }
            matrixColumns_[resultId] = std::move(outCols);
            valueStore_.erase(resultId);
            return true;
        };
    auto applyMatrixScalar =
        [&](std::uint32_t resultId, std::uint32_t matrixId,
            const Value& scalar, std::uint16_t op,
            bool scalarOnLeft = false) -> bool {
            const auto* cols = matrixColumnsForId(matrixId);
            if (cols == nullptr) return false;
            std::vector<Value> outCols = *cols;
            const float s = scalar.f[0];
            for (Value& col : outCols) {
                for (int k = 0; k < col.componentCount(); ++k) {
                    const float v = col.f[k];
                    switch (op) {
                        case spv::OpFAdd: col.f[k] = scalarOnLeft ? s + v : v + s; break;
                        case spv::OpFSub: col.f[k] = scalarOnLeft ? s - v : v - s; break;
                        case spv::OpFMul:
                        case spv::OpVectorTimesScalar:
                        case spv::OpMatrixTimesScalar:
                            col.f[k] = v * s;
                            break;
                        case spv::OpFDiv:
                            col.f[k] = scalarOnLeft
                                ? (v != 0.0f ? s / v : 0.0f)
                                : (s != 0.0f ? v / s : 0.0f);
                            break;
                        default: break;
                    }
                }
            }
            matrixColumns_[resultId] = std::move(outCols);
            valueStore_.erase(resultId);
            return true;
        };
    auto multiplyMatrixVector =
        [&](const std::vector<Value>& cols, const Value& v,
            std::uint32_t resultTypeId, int fallbackRows) -> Value {
            const int n = matrixRowsForType(resultTypeId, fallbackRows);
            Value r;
            r.kind = floatKindForWidth(n);
            const int colCount = std::min<int>(
                static_cast<int>(cols.size()), v.componentCount());
            for (int row = 0; row < n; ++row) {
                float sum = 0.0f;
                for (int col = 0; col < colCount; ++col) {
                    const Value& c = cols[static_cast<std::size_t>(col)];
                    if (row < c.componentCount()) {
                        sum += c.f[row] * v.f[col];
                    }
                }
                r.f[row] = sum;
            }
            return r;
        };

    while (pc < currentFuncEnd && !errored_) {
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
            case spv::OpFunctionParameter: {
                // Parameter ids are pre-bound by the OpFunctionCall
                // dispatcher before entering this helper body.
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
                const std::uint32_t ptrId = [&]() {
                    auto aliasIt = functionPointerAliases.find(w[2]);
                    return aliasIt != functionPointerAliases.end()
                        ? aliasIt->second
                        : w[2];
                }();
                // Sprint 6 P1 sub-task 3 day 3: sampler-image load.
                // If ptrId is a non-array sampler variable in our
                // sampledTextures_ map, propagate a handle (var_id, 0).
                // If ptrId is itself a SampledImageHandle (came from
                // OpAccessChain on a sampler array), forward the handle.
                if (sampledTextures_ != nullptr &&
                    sampledTextures_->count(ptrId) != 0) {
                    SampledImageHandle h;
                    h.arrayVarId = ptrId;
                    h.elementIdx = 0;
                    h.isStorage = false;
                    sampledImages_[w[1]] = h;
                    pc += wc;
                    break;
                }
                // Sprint 7 Phase 1 #4 (CKPT54): storage-image load.
                // Same shape as the sampler-image case but mints a
                // handle with isStorage=true so OpImageRead routes
                // through storageImages_ rather than sampledTextures_.
                if (storageImages_ != nullptr &&
                    storageImages_->count(ptrId) != 0) {
                    SampledImageHandle h;
                    h.arrayVarId = ptrId;
                    h.elementIdx = 0;
                    h.isStorage = true;
                    sampledImages_[w[1]] = h;
                    pc += wc;
                    break;
                }
                {
                    auto sImg = sampledImages_.find(ptrId);
                    if (sImg != sampledImages_.end()) {
                        sampledImages_[w[1]] = sImg->second;
                        pc += wc;
                        break;
                    }
                }
                auto vIt = module_.variables.find(ptrId);
                if (vIt != module_.variables.end()) {
                    // Direct load from a variable (common for scalars).
                    const auto& tIt = module_.types.at(vIt->second.typeId);
                    auto resultTypeIt = module_.types.find(w[0]);
                    if (resultTypeIt != module_.types.end() &&
                        resultTypeIt->second.kind == TypeInfo::Kind::Matrix) {
                        matrixColumns_[w[1]] =
                            loadMatrixColumnsFromVar(ptrId, 0, w[0]);
                        valueStore_.erase(w[1]);
                    } else {
                        valueStore_[w[1]] = loadFromVar(
                            ptrId, 0, module_.scalarWidth(tIt.pointeeType),
                            tIt.pointeeType);
                    }
                } else {
                    // Pointer came from OpAccessChain.
                    auto acIt = accessChains_.find(ptrId);
                    if (acIt != accessChains_.end()) {
                        if (acIt->second.isStorageBuffer) {
                            valueStore_[w[1]] = loadFromSSBO(
                                acIt->second.binding,
                                acIt->second.byteOffset,
                                acIt->second.leafTypeId);
                        } else if (acIt->second.isUniformBuffer) {
                            // Sprint 17 Day 4+ BONUS-2: UBO array load
                            // — read from the per-binding UBO map at
                            // the byteOffset accumulated during access-
                            // chain resolution.
                            auto resultTypeIt = module_.types.find(w[0]);
                            if (resultTypeIt != module_.types.end() &&
                                resultTypeIt->second.kind == TypeInfo::Kind::Matrix) {
                                matrixColumns_[w[1]] = loadMatrixColumnsFromUBO(
                                    acIt->second.binding,
                                    acIt->second.byteOffset,
                                    w[0],
                                    acIt->second.matrixStride);
                                valueStore_.erase(w[1]);
                            } else {
                                valueStore_[w[1]] = loadFromUBO(
                                    acIt->second.binding,
                                    acIt->second.byteOffset,
                                    acIt->second.leafTypeId);
                            }
                        } else {
                            auto resultTypeIt = module_.types.find(w[0]);
                            if (resultTypeIt != module_.types.end() &&
                                resultTypeIt->second.kind == TypeInfo::Kind::Matrix) {
                                matrixColumns_[w[1]] = loadMatrixColumnsFromVar(
                                    acIt->second.rootVarId,
                                    acIt->second.scalarOffset,
                                    w[0]);
                                valueStore_.erase(w[1]);
                            } else {
                                valueStore_[w[1]] = loadFromVar(
                                    acIt->second.rootVarId,
                                    acIt->second.scalarOffset,
                                    acIt->second.scalarCount,
                                    acIt->second.leafTypeId);
                            }
                        }
                    } else {
                        bail("OpLoad: unresolved pointer");
                    }
                }
                pc += wc;
                break;
            }
            case spv::OpStore: {
                // w[0]=ptrId, w[1]=valId
                const std::uint32_t ptrId = [&]() {
                    auto aliasIt = functionPointerAliases.find(w[0]);
                    return aliasIt != functionPointerAliases.end()
                        ? aliasIt->second
                        : w[0];
                }();
                const auto* storeMatrixColumns = matrixColumnsForId(w[1]);
                if (storeMatrixColumns != nullptr) {
                    auto vIt = module_.variables.find(ptrId);
                    if (vIt != module_.variables.end()) {
                        storeMatrixColumnsToVar(ptrId, 0, *storeMatrixColumns);
                    } else {
                        auto acIt = accessChains_.find(ptrId);
                        if (acIt != accessChains_.end()) {
                            if (acIt->second.isStorageBuffer ||
                                acIt->second.isUniformBuffer) {
                                bail("OpStore: matrix buffer store deferred");
                            } else {
                                storeMatrixColumnsToVar(acIt->second.rootVarId,
                                                        acIt->second.scalarOffset,
                                                        *storeMatrixColumns);
                            }
                        } else {
                            bail("OpStore: unresolved matrix pointer");
                        }
                    }
                    pc += wc;
                    break;
                }
                Value v;
                if (!tryGetValue(w[1], v)) { bail("OpStore: unresolved value"); break; }
                auto vIt = module_.variables.find(ptrId);
                if (vIt != module_.variables.end()) {
                    storeToVar(ptrId, 0, v);
                    // Built-in: gl_Position scalar mirror.
                    auto dIt = module_.decorations.find(ptrId);
                    if (dIt != module_.decorations.end() && dIt->second.hasBuiltIn
                        && dIt->second.builtIn == spv::BuiltInPosition) {
                        for (int k = 0; k < 4 && k < v.componentCount(); ++k) {
                            currentPosition_[k] = v.f[k];
                        }
                    }
                } else {
                    auto acIt = accessChains_.find(ptrId);
                    if (acIt != accessChains_.end()) {
                        if (acIt->second.isStorageBuffer) {
                            storeToSSBO(acIt->second.binding,
                                        acIt->second.byteOffset, v,
                                        acIt->second.leafTypeId);
                            pc += wc;
                            break;
                        }
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
            case spv::OpAtomicLoad: {
                // w[0]=type, w[1]=resultId, w[2]=ptrId,
                // w[3]=scope, w[4]=memory semantics. CPU GS execution is
                // single-threaded, so scope/semantics do not alter ordering;
                // the byte-level SSBO helper still returns the pre-write value
                // expected by GLSL atomic functions.
                if (!executeAtomicLoad(w[0], w[1], w[2])) {
                    break;
                }
                pc += wc;
                break;
            }
            case spv::OpAtomicStore: {
                // w[0]=ptrId, w[1]=scope, w[2]=memory semantics, w[3]=valueId.
                if (wc < 5 || !executeAtomicStore(w[0], w[3])) {
                    break;
                }
                pc += wc;
                break;
            }
            case spv::OpAtomicExchange:
            case spv::OpAtomicIIncrement:
            case spv::OpAtomicIDecrement:
            case spv::OpAtomicIAdd:
            case spv::OpAtomicISub:
            case spv::OpAtomicSMin:
            case spv::OpAtomicUMin:
            case spv::OpAtomicSMax:
            case spv::OpAtomicUMax:
            case spv::OpAtomicAnd:
            case spv::OpAtomicOr:
            case spv::OpAtomicXor: {
                const std::uint32_t valueId =
                    (opcode == spv::OpAtomicIIncrement ||
                     opcode == spv::OpAtomicIDecrement) ? 0u : w[5];
                if (!executeAtomicRMW(opcode, w[0], w[1], w[2], valueId)) {
                    break;
                }
                pc += wc;
                break;
            }
            case spv::OpAtomicCompareExchange:
            case spv::OpAtomicCompareExchangeWeak: {
                // w[6]=new value, w[7]=comparator. The return value is the
                // original memory value regardless of whether the swap occurs.
                if (wc < 9 || !executeAtomicRMW(opcode, w[0], w[1], w[2], w[6], w[7])) {
                    break;
                }
                pc += wc;
                break;
            }
            case spv::OpAccessChain: {
                // w[0]=type, w[1]=resultId, w[2]=base, w[3..]=indices
                // Sprint 6 P1 sub-task 3 day 3: sampler-array element
                // selection. If base is in sampledTextures_, the chain
                // selects an array element by w[3] (constant or SSA
                // value). Resolve to SampledImageHandle and store.
                // Sprint 7 Phase 1 #4 (CKPT54): same path for storage-
                // image arrays — mint a handle with isStorage=true.
                const bool baseIsSampler =
                    (sampledTextures_ != nullptr &&
                     sampledTextures_->count(w[2]) != 0);
                const bool baseIsStorageImg =
                    (!baseIsSampler && storageImages_ != nullptr &&
                     storageImages_->count(w[2]) != 0);
                if ((baseIsSampler || baseIsStorageImg) && wc >= 5) {
                    SampledImageHandle h;
                    h.arrayVarId = w[2];
                    h.isStorage = baseIsStorageImg;
                    // Index operand: try constant first, fall back to
                    // SSA value (e.g. loop counter).
                    auto cIt = module_.constants.find(w[3]);
                    if (cIt != module_.constants.end()) {
                        h.elementIdx = static_cast<std::uint32_t>(cIt->second.i[0]);
                    } else {
                        Value idxV;
                        if (tryGetValue(w[3], idxV)) {
                            if (idxV.kind == Value::Kind::UInt ||
                                idxV.kind == Value::Kind::Int) {
                                h.elementIdx = static_cast<std::uint32_t>(idxV.i[0]);
                            } else if (idxV.isFloatKind()) {
                                h.elementIdx =
                                    static_cast<std::uint32_t>(idxV.f[0]);
                            }
                        }
                    }
                    sampledImages_[w[1]] = h;
                    pc += wc;
                    break;
                }
                const std::uint32_t nIdx = wc - 4;
                AccessChainResult r = resolveAccessChain(w[2], &w[3], nIdx);
                if (r.ok) {
                    // SPIR-V's OpAccessChain result type is already the
                    // pointer-to-leaf. Keep it as a fallback for tess-stage
                    // per-vertex arrays whose root walk can lose the leaf id.
                    auto resultPtrIt = module_.types.find(w[0]);
                    if (resultPtrIt != module_.types.end() &&
                        resultPtrIt->second.kind == TypeInfo::Kind::Pointer) {
                        const std::uint32_t pointee =
                            resultPtrIt->second.pointeeType;
                        if (pointee != 0 &&
                            module_.types.find(r.leafTypeId) == module_.types.end() &&
                            module_.types.find(pointee) != module_.types.end()) {
                            r.leafTypeId = pointee;
                            r.scalarCount = module_.scalarWidth(pointee);
                        }
                    }
                    accessChains_[w[1]] = r;
                }
                pc += wc;
                break;
            }
            // Sprint 6 P1 sub-task 3 day 3 (CKPT43): sampler ops.
            //
            // OpSampledImage = 86  : combine an image + sampler into a
            //                       single sampled-image handle. For
            //                       OpenGL combined sampler-textures we
            //                       just propagate the image's handle —
            //                       sampler state is implicit per GL.
            //
            // OpImageSampleImplicitLod = 87 : sample with implicit
            //                       derivatives. Non-FS stages don't
            //                       have derivatives, so we treat as
            //                       Lod=0 sampling. Defensive — the
            //                       test we're targeting emits the
            //                       Explicit form.
            //
            // OpImageSampleExplicitLod = 88 : sample with explicit Lod.
            //                       Common in VS/GS (`texture()` lowers
            //                       to ExplicitLod when no derivatives).
            //                       We support Lod=0 only.
            case spv::OpSampledImage: {
                // w[0]=type, w[1]=resultId, w[2]=image, w[3]=sampler
                auto sIt = sampledImages_.find(w[2]);
                if (sIt != sampledImages_.end()) {
                    sampledImages_[w[1]] = sIt->second;
                }
                pc += wc;
                break;
            }
            case spv::OpImageSampleImplicitLod:
            case spv::OpImageSampleExplicitLod: {
                // w[0]=resultType, w[1]=resultId, w[2]=sampledImage,
                // w[3]=coord, w[4]=imageOperands (for Explicit), …
                auto sIt = sampledImages_.find(w[2]);
                if (sIt == sampledImages_.end() ||
                    sampledTextures_ == nullptr) {
                    // Sampler not bound or untracked — return zeros.
                    valueStore_[w[1]] = Value{Value::Kind::UInt4,
                                              {0, 0, 0, 0},
                                              {0, 0, 0, 0},
                                              false};
                    pc += wc;
                    break;
                }
                const SampledImageHandle& h = sIt->second;
                auto arrIt = sampledTextures_->find(h.arrayVarId);
                if (arrIt == sampledTextures_->end() ||
                    h.elementIdx >= arrIt->second.size()) {
                    valueStore_[w[1]] = Value{Value::Kind::UInt4,
                                              {0, 0, 0, 0},
                                              {0, 0, 0, 0},
                                              false};
                    pc += wc;
                    break;
                }
                const SampledTextureSlot& slot =
                    arrIt->second[h.elementIdx];
                // Resolve coord → texel (NEAREST). For 2D, multiply
                // normalized uv by dim and clamp. Coord can be vec2
                // (regular sampler2D) or vec3 (cubeArr / 2DArr — we
                // only handle 2D so trailing components are ignored).
                Value coord;
                std::uint32_t u = 0, v = 0;
                if (tryGetValue(w[3], coord)) {
                    float uF = coord.f[0];
                    float vF = coord.componentCount() >= 2 ? coord.f[1] : 0.0f;
                    // Wrap with REPEAT (default GL_TEXTURE_WRAP_*).
                    auto wrap = [](float x) {
                        x = x - std::floor(x);
                        if (x < 0.0f) x += 1.0f;
                        if (x >= 1.0f) x -= 1.0f;
                        return x;
                    };
                    uF = wrap(uF);
                    vF = wrap(vF);
                    if (slot.width > 0) {
                        int iu = static_cast<int>(uF * slot.width);
                        if (iu < 0) iu = 0;
                        if (iu >= static_cast<int>(slot.width))
                            iu = static_cast<int>(slot.width) - 1;
                        u = static_cast<std::uint32_t>(iu);
                    }
                    if (slot.height > 0) {
                        int iv = static_cast<int>(vF * slot.height);
                        if (iv < 0) iv = 0;
                        if (iv >= static_cast<int>(slot.height))
                            iv = static_cast<int>(slot.height) - 1;
                        v = static_cast<std::uint32_t>(iv);
                    }
                }
                // Decode texel based on internalFormat. Minimal set
                // that covers initial CTS targets — extensible.
                Value out{};
                if (std::getenv("APPGL_TRACE_GS_EMUL_TEX")) {
                    std::fprintf(stderr,
                        "[GS-tex] sample: var=%u elem=%u uv=(%u,%u) "
                        "fmt=0x%X dim=%ux%u datasz=%zu\n",
                        h.arrayVarId, h.elementIdx, u, v,
                        slot.internalFormat, slot.width, slot.height,
                        slot.data.size());
                }
                const std::uint32_t bpr =
                    slot.bytesPerRow != 0 ? slot.bytesPerRow
                                          : slot.width *
                                                (slot.internalFormat ==
                                                         /*GL_R32UI*/ 0x8236 ||
                                                 slot.internalFormat ==
                                                         /*GL_R32F*/ 0x822E ||
                                                 slot.internalFormat ==
                                                         /*GL_R32I*/ 0x8235
                                                     ? 4u
                                                     : slot.internalFormat ==
                                                                       /*GL_RGBA8*/ 0x8058
                                                           ? 4u
                                                           : 4u);
                const std::size_t off =
                    static_cast<std::size_t>(v) * bpr +
                    static_cast<std::size_t>(u) * 4u;
                if (off + 4 <= slot.data.size()) {
                    std::uint32_t raw = 0;
                    std::memcpy(&raw, slot.data.data() + off, 4);
                    switch (slot.internalFormat) {
                        case 0x8236: { // GL_R32UI
                            out.kind = Value::Kind::UInt4;
                            out.i[0] = static_cast<std::int32_t>(raw);
                            out.i[1] = 0; out.i[2] = 0;
                            out.i[3] = static_cast<std::int32_t>(1u);
                            break;
                        }
                        case 0x8235: { // GL_R32I
                            out.kind = Value::Kind::Int4;
                            out.i[0] = static_cast<std::int32_t>(raw);
                            out.i[1] = 0; out.i[2] = 0; out.i[3] = 1;
                            break;
                        }
                        case 0x822E: { // GL_R32F
                            out.kind = Value::Kind::Float4;
                            std::memcpy(&out.f[0], &raw, 4);
                            out.f[1] = 0.0f; out.f[2] = 0.0f;
                            out.f[3] = 1.0f;
                            break;
                        }
                        case 0x8058: { // GL_RGBA8 — UNORM decode
                            out.kind = Value::Kind::Float4;
                            const std::uint8_t* p =
                                slot.data.data() + off;
                            out.f[0] = p[0] / 255.0f;
                            out.f[1] = p[1] / 255.0f;
                            out.f[2] = p[2] / 255.0f;
                            out.f[3] = p[3] / 255.0f;
                            break;
                        }
                        default: {
                            // Unknown format — return raw bits as UInt4.
                            out.kind = Value::Kind::UInt4;
                            out.i[0] = static_cast<std::int32_t>(raw);
                            out.i[1] = 0; out.i[2] = 0; out.i[3] = 1;
                            break;
                        }
                    }
                } else {
                    // OOB — return zeros.
                    out.kind = Value::Kind::UInt4;
                }
                valueStore_[w[1]] = out;
                pc += wc;
                break;
            }
            // Sprint 7 Phase 1 #4 (CKPT54): OpImageRead = 98.
            // GLSL `imageLoad(img, ivec2(u,v))` lowers to OpImageRead.
            // Word layout: w[0]=resultType, w[1]=resultId, w[2]=image,
            //              w[3]=coord, [w[4]=imageOperands, …].
            // The image operand is the loaded Image value (NOT a
            // SampledImage), so the propagated handle came from
            // OpLoad on a UniformConstant `image*` variable. Coord
            // is integer (no normalization, no wrap, no LOD).
            // Resolves slot data via storageImages_ when the handle
            // was minted there, else sampledTextures_ as a defensive
            // fallback. Format decode mirrors OpImageSample*.
            case spv::OpImageRead: {
                auto sIt = sampledImages_.find(w[2]);
                if (sIt == sampledImages_.end()) {
                    valueStore_[w[1]] = Value{Value::Kind::UInt4,
                                              {0, 0, 0, 0},
                                              {0, 0, 0, 0},
                                              false};
                    pc += wc;
                    break;
                }
                const SampledImageHandle& h = sIt->second;
                const SampledTextureMap* mapPtr = h.isStorage
                    ? storageImages_ : sampledTextures_;
                if (mapPtr == nullptr) {
                    valueStore_[w[1]] = Value{Value::Kind::UInt4,
                                              {0, 0, 0, 0},
                                              {0, 0, 0, 0},
                                              false};
                    pc += wc;
                    break;
                }
                auto arrIt = mapPtr->find(h.arrayVarId);
                if (arrIt == mapPtr->end() ||
                    h.elementIdx >= arrIt->second.size()) {
                    valueStore_[w[1]] = Value{Value::Kind::UInt4,
                                              {0, 0, 0, 0},
                                              {0, 0, 0, 0},
                                              false};
                    pc += wc;
                    break;
                }
                const SampledTextureSlot& slot =
                    arrIt->second[h.elementIdx];
                // Resolve coord → texel. OpImageRead coord is integer
                // (clamp to texture extent on OOB; spec actually says
                // OOB is undefined but returning zeros is the standard
                // emulator pattern).
                Value coord;
                std::uint32_t u = 0, v = 0;
                if (tryGetValue(w[3], coord)) {
                    auto pickI = [&](int idx) -> std::int32_t {
                        if (idx >= coord.componentCount()) return 0;
                        if (coord.isIntKind() ||
                            coord.kind == Value::Kind::UInt ||
                            coord.kind == Value::Kind::UInt2 ||
                            coord.kind == Value::Kind::UInt3 ||
                            coord.kind == Value::Kind::UInt4) {
                            return coord.i[idx];
                        }
                        // GLSL imageLoad takes ivec*, but defensively
                        // accept float (truncates).
                        return static_cast<std::int32_t>(coord.f[idx]);
                    };
                    const std::int32_t iu = pickI(0);
                    const std::int32_t iv = pickI(1);
                    if (iu >= 0 &&
                        static_cast<std::uint32_t>(iu) < slot.width) {
                        u = static_cast<std::uint32_t>(iu);
                    }
                    if (iv >= 0 &&
                        static_cast<std::uint32_t>(iv) < slot.height) {
                        v = static_cast<std::uint32_t>(iv);
                    }
                }
                if (std::getenv("APPGL_TRACE_GS_EMUL_TEX")) {
                    std::fprintf(stderr,
                        "[GS-img] read: var=%u elem=%u uv=(%u,%u) "
                        "fmt=0x%X dim=%ux%u datasz=%zu storage=%d\n",
                        h.arrayVarId, h.elementIdx, u, v,
                        slot.internalFormat, slot.width, slot.height,
                        slot.data.size(), h.isStorage ? 1 : 0);
                }
                Value out{};
                const std::uint32_t bpr =
                    slot.bytesPerRow != 0 ? slot.bytesPerRow
                                          : slot.width * 4u;
                const std::uint32_t bytesPerTexel =
                    (slot.width != 0 && bpr >= slot.width)
                        ? std::max<std::uint32_t>(1u, bpr / slot.width)
                        : 4u;
                const std::size_t off =
                    static_cast<std::size_t>(v) * bpr +
                    static_cast<std::size_t>(u) * bytesPerTexel;
                if (off < slot.data.size()) {
                    std::uint32_t raw = 0;
                    const std::uint8_t* p = slot.data.data() + off;
                    auto have = [&](std::size_t bytes) -> bool {
                        return off + bytes <= slot.data.size();
                    };
                    if (have(4)) {
                        std::memcpy(&raw, p, 4);
                    }
                    auto readU8 = [&](int component) -> std::uint8_t {
                        return have(static_cast<std::size_t>(component) + 1u)
                            ? p[component] : 0u;
                    };
                    auto readI8 = [&](int component) -> std::int8_t {
                        return static_cast<std::int8_t>(readU8(component));
                    };
                    auto readU16 = [&](int component) -> std::uint16_t {
                        std::uint16_t v = 0;
                        if (have(static_cast<std::size_t>(component) * 2u + sizeof(v))) {
                            std::memcpy(&v, p + component * 2, sizeof(v));
                        }
                        return v;
                    };
                    auto readI16 = [&](int component) -> std::int16_t {
                        std::int16_t v = 0;
                        if (have(static_cast<std::size_t>(component) * 2u + sizeof(v))) {
                            std::memcpy(&v, p + component * 2, sizeof(v));
                        }
                        return v;
                    };
                    auto readU32 = [&](int component) -> std::uint32_t {
                        std::uint32_t v = 0;
                        if (have(static_cast<std::size_t>(component) * 4u + sizeof(v))) {
                            std::memcpy(&v, p + component * 4, sizeof(v));
                        }
                        return v;
                    };
                    auto readI32 = [&](int component) -> std::int32_t {
                        return static_cast<std::int32_t>(readU32(component));
                    };
                    auto readF32 = [&](int component) -> float {
                        float v = 0.0f;
                        const std::uint32_t bits = readU32(component);
                        std::memcpy(&v, &bits, sizeof(v));
                        return v;
                    };
                    switch (slot.internalFormat) {
                        // Sprint 18 Bucket 3 GS binding-format limb:
                        // decode the first-8 same-size image formats
                        // using the glBindImageTexture format carried
                        // in slot.internalFormat, sister to the
                        // existing R32*/RGBA8 imageLoad cases below.
                        case 0x8814: { // GL_RGBA32F
                            out.kind = Value::Kind::Float4;
                            out.f[0] = readF32(0);
                            out.f[1] = readF32(1);
                            out.f[2] = readF32(2);
                            out.f[3] = readF32(3);
                            break;
                        }
                        case 0x8230: { // GL_RG32F
                            out.kind = Value::Kind::Float4;
                            out.f[0] = readF32(0);
                            out.f[1] = readF32(1);
                            out.f[2] = 0.0f;
                            out.f[3] = 1.0f;
                            break;
                        }
                        case 0x881A: { // GL_RGBA16F
                            out.kind = Value::Kind::Float4;
                            out.f[0] = imageHalfToFloat(readU16(0));
                            out.f[1] = imageHalfToFloat(readU16(1));
                            out.f[2] = imageHalfToFloat(readU16(2));
                            out.f[3] = imageHalfToFloat(readU16(3));
                            break;
                        }
                        case 0x822F: { // GL_RG16F
                            out.kind = Value::Kind::Float4;
                            out.f[0] = imageHalfToFloat(readU16(0));
                            out.f[1] = imageHalfToFloat(readU16(1));
                            out.f[2] = 0.0f;
                            out.f[3] = 1.0f;
                            break;
                        }
                        case 0x822D: { // GL_R16F
                            out.kind = Value::Kind::Float4;
                            out.f[0] = imageHalfToFloat(readU16(0));
                            out.f[1] = 0.0f;
                            out.f[2] = 0.0f;
                            out.f[3] = 1.0f;
                            break;
                        }
                        case 0x8C3A: { // GL_R11F_G11F_B10F
                            out.kind = Value::Kind::Float4;
                            decodeImageRG11B10F(raw, out.f[0], out.f[1], out.f[2]);
                            out.f[3] = 1.0f;
                            break;
                        }
                        case 0x8D70: { // GL_RGBA32UI
                            out.kind = Value::Kind::UInt4;
                            out.i[0] = static_cast<std::int32_t>(readU32(0));
                            out.i[1] = static_cast<std::int32_t>(readU32(1));
                            out.i[2] = static_cast<std::int32_t>(readU32(2));
                            out.i[3] = static_cast<std::int32_t>(readU32(3));
                            break;
                        }
                        case 0x823C: { // GL_RG32UI
                            out.kind = Value::Kind::UInt4;
                            out.i[0] = static_cast<std::int32_t>(readU32(0));
                            out.i[1] = static_cast<std::int32_t>(readU32(1));
                            out.i[2] = 0;
                            out.i[3] = static_cast<std::int32_t>(1u);
                            break;
                        }
                        case 0x8236: { // GL_R32UI
                            out.kind = Value::Kind::UInt4;
                            out.i[0] = static_cast<std::int32_t>(raw);
                            out.i[1] = 0; out.i[2] = 0;
                            out.i[3] = static_cast<std::int32_t>(1u);
                            break;
                        }
                        case 0x8D82: { // GL_RGBA32I
                            out.kind = Value::Kind::Int4;
                            out.i[0] = readI32(0);
                            out.i[1] = readI32(1);
                            out.i[2] = readI32(2);
                            out.i[3] = readI32(3);
                            break;
                        }
                        case 0x823B: { // GL_RG32I
                            out.kind = Value::Kind::Int4;
                            out.i[0] = readI32(0);
                            out.i[1] = readI32(1);
                            out.i[2] = 0;
                            out.i[3] = 1;
                            break;
                        }
                        case 0x8235: { // GL_R32I
                            out.kind = Value::Kind::Int4;
                            out.i[0] = static_cast<std::int32_t>(raw);
                            out.i[1] = 0; out.i[2] = 0; out.i[3] = 1;
                            break;
                        }
                        case 0x822E: { // GL_R32F
                            out.kind = Value::Kind::Float4;
                            std::memcpy(&out.f[0], &raw, 4);
                            out.f[1] = 0.0f; out.f[2] = 0.0f;
                            out.f[3] = 1.0f;
                            break;
                        }
                        case 0x8059: { // GL_RGB10_A2
                            out.kind = Value::Kind::Float4;
                            out.f[0] = static_cast<float>((raw >> 0) & 0x3FFu) / 1023.0f;
                            out.f[1] = static_cast<float>((raw >> 10) & 0x3FFu) / 1023.0f;
                            out.f[2] = static_cast<float>((raw >> 20) & 0x3FFu) / 1023.0f;
                            out.f[3] = static_cast<float>((raw >> 30) & 0x3u) / 3.0f;
                            break;
                        }
                        case 0x906F: { // GL_RGB10_A2UI
                            out.kind = Value::Kind::UInt4;
                            out.i[0] = static_cast<std::int32_t>((raw >> 0) & 0x3FFu);
                            out.i[1] = static_cast<std::int32_t>((raw >> 10) & 0x3FFu);
                            out.i[2] = static_cast<std::int32_t>((raw >> 20) & 0x3FFu);
                            out.i[3] = static_cast<std::int32_t>((raw >> 30) & 0x3u);
                            break;
                        }
                        case 0x805B: { // GL_RGBA16
                            out.kind = Value::Kind::Float4;
                            out.f[0] = static_cast<float>(readU16(0)) / 65535.0f;
                            out.f[1] = static_cast<float>(readU16(1)) / 65535.0f;
                            out.f[2] = static_cast<float>(readU16(2)) / 65535.0f;
                            out.f[3] = static_cast<float>(readU16(3)) / 65535.0f;
                            break;
                        }
                        case 0x8058: { // GL_RGBA8 — UNORM decode
                            out.kind = Value::Kind::Float4;
                            out.f[0] = static_cast<float>(readU8(0)) / 255.0f;
                            out.f[1] = static_cast<float>(readU8(1)) / 255.0f;
                            out.f[2] = static_cast<float>(readU8(2)) / 255.0f;
                            out.f[3] = static_cast<float>(readU8(3)) / 255.0f;
                            break;
                        }
                        case 0x822B: { // GL_RG8
                            out.kind = Value::Kind::Float4;
                            out.f[0] = static_cast<float>(readU8(0)) / 255.0f;
                            out.f[1] = static_cast<float>(readU8(1)) / 255.0f;
                            out.f[2] = 0.0f;
                            out.f[3] = 1.0f;
                            break;
                        }
                        case 0x8229: { // GL_R8
                            out.kind = Value::Kind::Float4;
                            out.f[0] = static_cast<float>(readU8(0)) / 255.0f;
                            out.f[1] = 0.0f;
                            out.f[2] = 0.0f;
                            out.f[3] = 1.0f;
                            break;
                        }
                        case 0x8D76: { // GL_RGBA16UI
                            out.kind = Value::Kind::UInt4;
                            out.i[0] = static_cast<std::int32_t>(readU16(0));
                            out.i[1] = static_cast<std::int32_t>(readU16(1));
                            out.i[2] = static_cast<std::int32_t>(readU16(2));
                            out.i[3] = static_cast<std::int32_t>(readU16(3));
                            break;
                        }
                        case 0x823A: { // GL_RG16UI
                            out.kind = Value::Kind::UInt4;
                            out.i[0] = static_cast<std::int32_t>(readU16(0));
                            out.i[1] = static_cast<std::int32_t>(readU16(1));
                            out.i[2] = 0;
                            out.i[3] = static_cast<std::int32_t>(1u);
                            break;
                        }
                        case 0x8234: { // GL_R16UI
                            out.kind = Value::Kind::UInt4;
                            out.i[0] = static_cast<std::int32_t>(readU16(0));
                            out.i[1] = 0; out.i[2] = 0;
                            out.i[3] = static_cast<std::int32_t>(1u);
                            break;
                        }
                        case 0x8D88: { // GL_RGBA16I
                            out.kind = Value::Kind::Int4;
                            out.i[0] = static_cast<std::int32_t>(readI16(0));
                            out.i[1] = static_cast<std::int32_t>(readI16(1));
                            out.i[2] = static_cast<std::int32_t>(readI16(2));
                            out.i[3] = static_cast<std::int32_t>(readI16(3));
                            break;
                        }
                        case 0x8239: { // GL_RG16I
                            out.kind = Value::Kind::Int4;
                            out.i[0] = static_cast<std::int32_t>(readI16(0));
                            out.i[1] = static_cast<std::int32_t>(readI16(1));
                            out.i[2] = 0;
                            out.i[3] = 1;
                            break;
                        }
                        case 0x8233: { // GL_R16I
                            out.kind = Value::Kind::Int4;
                            out.i[0] = static_cast<std::int32_t>(readI16(0));
                            out.i[1] = 0; out.i[2] = 0; out.i[3] = 1;
                            break;
                        }
                        case 0x8D7C: { // GL_RGBA8UI
                            out.kind = Value::Kind::UInt4;
                            out.i[0] = static_cast<std::int32_t>(readU8(0));
                            out.i[1] = static_cast<std::int32_t>(readU8(1));
                            out.i[2] = static_cast<std::int32_t>(readU8(2));
                            out.i[3] = static_cast<std::int32_t>(readU8(3));
                            break;
                        }
                        case 0x8238: { // GL_RG8UI
                            out.kind = Value::Kind::UInt4;
                            out.i[0] = static_cast<std::int32_t>(readU8(0));
                            out.i[1] = static_cast<std::int32_t>(readU8(1));
                            out.i[2] = 0;
                            out.i[3] = static_cast<std::int32_t>(1u);
                            break;
                        }
                        case 0x8232: { // GL_R8UI
                            out.kind = Value::Kind::UInt4;
                            out.i[0] = static_cast<std::int32_t>(readU8(0));
                            out.i[1] = 0; out.i[2] = 0;
                            out.i[3] = static_cast<std::int32_t>(1u);
                            break;
                        }
                        case 0x8D8E: { // GL_RGBA8I
                            out.kind = Value::Kind::Int4;
                            out.i[0] = static_cast<std::int32_t>(readI8(0));
                            out.i[1] = static_cast<std::int32_t>(readI8(1));
                            out.i[2] = static_cast<std::int32_t>(readI8(2));
                            out.i[3] = static_cast<std::int32_t>(readI8(3));
                            break;
                        }
                        case 0x8237: { // GL_RG8I
                            out.kind = Value::Kind::Int4;
                            out.i[0] = static_cast<std::int32_t>(readI8(0));
                            out.i[1] = static_cast<std::int32_t>(readI8(1));
                            out.i[2] = 0;
                            out.i[3] = 1;
                            break;
                        }
                        case 0x8231: { // GL_R8I
                            out.kind = Value::Kind::Int4;
                            out.i[0] = static_cast<std::int32_t>(readI8(0));
                            out.i[1] = 0; out.i[2] = 0; out.i[3] = 1;
                            break;
                        }
                        case 0x822C: { // GL_RG16
                            out.kind = Value::Kind::Float4;
                            out.f[0] = static_cast<float>(readU16(0)) / 65535.0f;
                            out.f[1] = static_cast<float>(readU16(1)) / 65535.0f;
                            out.f[2] = 0.0f;
                            out.f[3] = 1.0f;
                            break;
                        }
                        case 0x822A: { // GL_R16
                            out.kind = Value::Kind::Float4;
                            out.f[0] = static_cast<float>(readU16(0)) / 65535.0f;
                            out.f[1] = 0.0f;
                            out.f[2] = 0.0f;
                            out.f[3] = 1.0f;
                            break;
                        }
                        case 0x8F9B: { // GL_RGBA16_SNORM
                            out.kind = Value::Kind::Float4;
                            out.f[0] = imageSnorm16(readI16(0));
                            out.f[1] = imageSnorm16(readI16(1));
                            out.f[2] = imageSnorm16(readI16(2));
                            out.f[3] = imageSnorm16(readI16(3));
                            break;
                        }
                        case 0x8F97: { // GL_RGBA8_SNORM
                            out.kind = Value::Kind::Float4;
                            out.f[0] = imageSnorm8(readI8(0));
                            out.f[1] = imageSnorm8(readI8(1));
                            out.f[2] = imageSnorm8(readI8(2));
                            out.f[3] = imageSnorm8(readI8(3));
                            break;
                        }
                        case 0x8F95: { // GL_RG8_SNORM
                            out.kind = Value::Kind::Float4;
                            out.f[0] = imageSnorm8(readI8(0));
                            out.f[1] = imageSnorm8(readI8(1));
                            out.f[2] = 0.0f;
                            out.f[3] = 1.0f;
                            break;
                        }
                        case 0x8F94: { // GL_R8_SNORM
                            out.kind = Value::Kind::Float4;
                            out.f[0] = imageSnorm8(readI8(0));
                            out.f[1] = 0.0f;
                            out.f[2] = 0.0f;
                            out.f[3] = 1.0f;
                            break;
                        }
                        case 0x8F99: { // GL_RG16_SNORM
                            out.kind = Value::Kind::Float4;
                            out.f[0] = imageSnorm16(readI16(0));
                            out.f[1] = imageSnorm16(readI16(1));
                            out.f[2] = 0.0f;
                            out.f[3] = 1.0f;
                            break;
                        }
                        case 0x8F98: { // GL_R16_SNORM
                            out.kind = Value::Kind::Float4;
                            out.f[0] = imageSnorm16(readI16(0));
                            out.f[1] = 0.0f;
                            out.f[2] = 0.0f;
                            out.f[3] = 1.0f;
                            break;
                        }
                        default: {
                            out.kind = Value::Kind::UInt4;
                            out.i[0] = static_cast<std::int32_t>(raw);
                            out.i[1] = 0; out.i[2] = 0; out.i[3] = 1;
                            break;
                        }
                    }
                } else {
                    out.kind = Value::Kind::UInt4;
                }
                valueStore_[w[1]] = out;
                pc += wc;
                break;
            }
            // CKPT160 (Sprint 14 Day 7): OpImageQuerySize / OpImageQuerySizeLod
            // for storage image variables in GS. Returns the bound texture's
            // dimensions resolved through `storageImages_` (built from
            // imageBindings unit at draw time).
            //   OpImageQuerySize: w[0]=resultType, w[1]=resultId, w[2]=image
            //   OpImageQuerySizeLod: same plus w[3]=lod (we ignore — slot is
            //                        always level 0 in our shadow).
            case spv::OpImageQuerySize:
            case spv::OpImageQuerySizeLod: {
                auto sIt = sampledImages_.find(w[2]);
                if (sIt == sampledImages_.end()) {
                    valueStore_[w[1]] = Value{Value::Kind::Int4,
                                              {0, 0, 0, 0},
                                              {0, 0, 0, 0},
                                              false};
                    pc += wc;
                    break;
                }
                const SampledImageHandle& h = sIt->second;
                const SampledTextureMap* mapPtr = h.isStorage
                    ? storageImages_ : sampledTextures_;
                if (mapPtr == nullptr) {
                    valueStore_[w[1]] = Value{Value::Kind::Int4,
                                              {0, 0, 0, 0},
                                              {0, 0, 0, 0},
                                              false};
                    pc += wc;
                    break;
                }
                auto arrIt = mapPtr->find(h.arrayVarId);
                std::uint32_t qw = 0, qh = 0, qd = 0;
                if (arrIt != mapPtr->end() &&
                    h.elementIdx < arrIt->second.size()) {
                    const SampledTextureSlot& slot =
                        arrIt->second[h.elementIdx];
                    qw = slot.width;
                    qh = slot.height;
                    qd = slot.depth;
                }
                // Result component count from SPIR-V resultType. Vector
                // kinds Vec2/Vec3/Vec4 carry the count via their kind
                // enum; Int / UInt are scalar. Default to ivec2.
                std::uint32_t componentCount = 2;
                auto tIt = module_.types.find(w[0]);
                bool isUnsigned = false;
                if (tIt != module_.types.end()) {
                    using K = TypeInfo::Kind;
                    switch (tIt->second.kind) {
                        case K::Vec2: componentCount = 2; break;
                        case K::Vec3: componentCount = 3; break;
                        case K::Vec4: componentCount = 4; break;
                        case K::Int:  componentCount = 1; break;
                        case K::UInt: componentCount = 1; isUnsigned = true; break;
                        default: break;
                    }
                    if (componentCount > 1) {
                        auto bIt = module_.types.find(tIt->second.componentType);
                        if (bIt != module_.types.end() &&
                            bIt->second.kind == K::UInt) {
                            isUnsigned = true;
                        }
                    }
                }
                Value out{};
                out.kind = isUnsigned ? Value::Kind::UInt4 : Value::Kind::Int4;
                if (componentCount >= 1) {
                    out.i[0] = static_cast<std::int32_t>(qw);
                }
                if (componentCount >= 2) {
                    out.i[1] = static_cast<std::int32_t>(qh);
                }
                if (componentCount >= 3) {
                    out.i[2] = static_cast<std::int32_t>(qd);
                }
                if (std::getenv("APPGL_TRACE_GS_EMUL_TEX")) {
                    std::fprintf(stderr,
                        "[GS-img] querysize: var=%u elem=%u → "
                        "(%u,%u,%u) compCount=%u\n",
                        h.arrayVarId, h.elementIdx, qw, qh, qd,
                        componentCount);
                }
                valueStore_[w[1]] = out;
                pc += wc;
                break;
            }
            // CKPT162 (Sprint 14 Day 9): OpImageWrite — captures the
            // store into pendingImageWrites_ for the runtime to flush
            // to Metal via replaceRegion: after GS execution. Builds
            // on CKPT160 acceptance into isSupportedGsOpcode.
            //   OpImageWrite: w[0]=image, w[1]=coord, w[2]=texel,
            //                 [w[3..]=imageOperands]
            case spv::OpImageWrite: {
                auto sIt = sampledImages_.find(w[0]);
                if (sIt == sampledImages_.end()) { pc += wc; break; }
                const SampledImageHandle& h = sIt->second;
                if (!h.isStorage || storageImages_ == nullptr) {
                    pc += wc; break;
                }
                auto arrIt = storageImages_->find(h.arrayVarId);
                if (arrIt == storageImages_->end() ||
                    h.elementIdx >= arrIt->second.size()) {
                    pc += wc; break;
                }
                Value coordV{}, texelV{};
                if (!tryGetValue(w[1], coordV) ||
                    !tryGetValue(w[2], texelV)) {
                    pc += wc; break;
                }
                PendingImageWrite pw;
                pw.arrayVarId = h.arrayVarId;
                pw.elementIdx = h.elementIdx;
                // Coord is ivec2 / ivec3 / int (pack into 3-int vec).
                auto coordI = [&](int idx) -> std::int32_t {
                    if (idx >= coordV.componentCount()) return 0;
                    if (coordV.isIntKind() ||
                        coordV.kind == Value::Kind::UInt ||
                        coordV.kind == Value::Kind::UInt2 ||
                        coordV.kind == Value::Kind::UInt3 ||
                        coordV.kind == Value::Kind::UInt4) {
                        return coordV.i[idx];
                    }
                    return static_cast<std::int32_t>(coordV.f[idx]);
                };
                pw.coord[0] = coordI(0);
                pw.coord[1] = coordI(1);
                pw.coord[2] = coordI(2);
                // Texel can be ivec4 / uvec4 / vec4 / scalar; pack into
                // 4×u32. For float texels, reinterpret-cast.
                const SampledTextureSlot& slot = arrIt->second[h.elementIdx];
                pw.internalFormat = slot.internalFormat;
                const int texelCount = std::min(4, texelV.componentCount());
                pw.valueIsFloat = texelV.isFloatKind();
                if (texelV.isFloatKind()) {
                    for (int k = 0; k < texelCount; ++k) {
                        std::uint32_t bits = 0;
                        std::memcpy(&bits, &texelV.f[k], 4);
                        pw.value[k] = bits;
                    }
                } else {
                    for (int k = 0; k < texelCount; ++k) {
                        pw.value[k] = static_cast<std::uint32_t>(texelV.i[k]);
                    }
                }
                pendingImageWrites_.push_back(pw);
                if (std::getenv("APPGL_TRACE_GS_EMUL_TEX")) {
                    std::fprintf(stderr,
                        "[GS-img] write: var=%u elem=%u coord=(%d,%d,%d) "
                        "value=(0x%X,0x%X,0x%X,0x%X) fmt=0x%X\n",
                        pw.arrayVarId, pw.elementIdx,
                        pw.coord[0], pw.coord[1], pw.coord[2],
                        pw.value[0], pw.value[1], pw.value[2], pw.value[3],
                        pw.internalFormat);
                }
                pc += wc;
                break;
            }
            case spv::OpCompositeExtract: {
                // w[0]=type, w[1]=resultId, w[2]=composite, w[3..]=indices
                auto compositeIt = compositeValues_.find(w[2]);
                if (compositeIt != compositeValues_.end()) {
                    if (wc < 5) {
                        bail("OpCompositeExtract: missing composite index");
                        break;
                    }
                    const std::uint32_t member = w[3];
                    if (member >= compositeIt->second.size()) {
                        bail("OpCompositeExtract: composite member OOB");
                        break;
                    }
                    Value r = compositeIt->second[member];
                    if (wc >= 6) {
                        const std::uint32_t lane = w[4];
                        Value scalar;
                        if (r.isFloatKind()) {
                            scalar.kind = Value::Kind::Float;
                            const int idx = std::min<int>(
                                static_cast<int>(lane), r.componentCount() - 1);
                            scalar.f[0] = r.f[idx];
                            scalar.d[0] = r.d[idx];
                            scalar.hasDouble = r.hasDouble;
                        } else if (r.isIntKind()) {
                            scalar.kind = Value::Kind::Int;
                            const int idx = std::min<int>(
                                static_cast<int>(lane), r.componentCount() - 1);
                            scalar.i[0] = r.i[idx];
                        } else {
                            bail("OpCompositeExtract: unsupported composite member kind");
                            break;
                        }
                        r = scalar;
                    }
                    valueStore_[w[1]] = r;
                    pc += wc;
                    break;
                }
                const auto* matrixIt = matrixColumnsForId(w[2]);
                if (matrixIt != nullptr) {
                    if (wc >= 4) {
                        const std::uint32_t col = w[3];
                        if (col < matrixIt->size()) {
                            if (wc >= 6) {
                                const std::uint32_t row = w[4];
                                Value r;
                                r.kind = Value::Kind::Float;
                                if (row < static_cast<std::uint32_t>(
                                        (*matrixIt)[col].componentCount())) {
                                    r.f[0] = (*matrixIt)[col].f[row];
                                }
                                valueStore_[w[1]] = r;
                            } else {
                                valueStore_[w[1]] = (*matrixIt)[col];
                            }
                        }
                    }
                    pc += wc;
                    break;
                }
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
                // w[0]=type, w[1]=resultId, w[2..]=component-or-vector ids
                //
                // SPIR-V 1.0 §3.32.12: operands can be either scalars
                // (contributing one component each) or vectors (in
                // which case ALL of the vector's components are
                // flattened into the result). GLSL `vec4(vec2, 0, 1)`
                // emits `OpCompositeConstruct %v4 %vec2val %const0
                // %const1` — three operands producing four
                // components. The naive "one operand per result
                // component" loop drops the vec2's second element,
                // which broke `gl_Position = vec4(position_data, 0, 1)`
                // in every rendering GS test.
                //
                // Result kind MUST reflect the declared vector
                // scalar base — previously hardcoded to Float*, which
                // broke `ivec4(int, int, int, int)` because
                // `cv.f[c]` is zero-initialised when the source
                // operand is an Int Value. Fix: inspect the vector's
                // componentType to pick Float/Int/UInt flavour, and
                // read the operands' native slot matching that base.
                auto typeIt = module_.types.find(w[0]);
                Value r;
                if (typeIt != module_.types.end()) {
                    const auto& t = typeIt->second;
                    matrixColumns_.erase(w[1]);
                    if (t.kind == TypeInfo::Kind::Vec2 || t.kind == TypeInfo::Kind::Vec3 ||
                        t.kind == TypeInfo::Kind::Vec4) {
                        // Pick result kind based on component scalar type.
                        bool isInt = false, isUInt = false;
                        auto ctIt = module_.types.find(t.componentType);
                        if (ctIt != module_.types.end()) {
                            if (ctIt->second.kind == TypeInfo::Kind::Int) isInt = true;
                            else if (ctIt->second.kind == TypeInfo::Kind::UInt) isUInt = true;
                        }
                        if (isInt) {
                            r.kind = (t.count == 2) ? Value::Kind::Int2 :
                                     (t.count == 3) ? Value::Kind::Int3 : Value::Kind::Int4;
                        } else if (isUInt) {
                            r.kind = (t.count == 2) ? Value::Kind::UInt2 :
                                     (t.count == 3) ? Value::Kind::UInt3 : Value::Kind::UInt4;
                        } else {
                            r.kind = (t.count == 2) ? Value::Kind::Float2 :
                                     (t.count == 3) ? Value::Kind::Float3 : Value::Kind::Float4;
                        }
                        std::uint32_t dstIdx = 0;
                        const std::uint32_t nOperands = (wc > 2) ? (wc - 2) : 0;
                        for (std::uint32_t k = 0; k < nOperands && dstIdx < t.count; ++k) {
                            Value cv;
                            if (!tryGetValue(w[2 + k], cv)) continue;
                            const int cc = cv.componentCount();
                            const bool srcIsFloat = cv.isFloatKind();
                            for (int c = 0; c < cc && dstIdx < t.count; ++c) {
                                // Pull from the source's native slot,
                                // write to the result's native slot.
                                // Mixed float↔int composites are not
                                // valid SPIR-V (§3.32.12), but
                                // defensive copy handles both sides
                                // of the union.
                                if (isInt || isUInt) {
                                    if (srcIsFloat) {
                                        std::memcpy(&r.i[dstIdx], &cv.f[c], 4);
                                    } else {
                                        r.i[dstIdx] = cv.i[c];
                                    }
                                } else {
                                    if (srcIsFloat) {
                                        r.f[dstIdx] = cv.f[c];
                                    } else {
                                        std::memcpy(&r.f[dstIdx], &cv.i[c], 4);
                                    }
                                }
                                ++dstIdx;
                            }
                        }
                    } else if (t.kind == TypeInfo::Kind::Matrix) {
                        std::vector<Value> columns;
                        columns.reserve(wc > 2 ? wc - 2 : 0);
                        for (std::uint32_t k = 2; k < wc; ++k) {
                            Value cv;
                            if (tryGetValue(w[k], cv) && cv.isFloatKind()) {
                                columns.push_back(cv);
                            }
                        }
                        if (!columns.empty()) {
                            matrixColumns_[w[1]] = std::move(columns);
                        }
                    }
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpFAdd: case spv::OpFSub:
            case spv::OpFMul: case spv::OpFDiv: {
                if (applyMatrixElementwise(w[1], w[2], w[3], opcode)) {
                    pc += wc;
                    break;
                }
                if (matrixColumnsForId(w[2]) != nullptr) {
                    Value b;
                    if (!tryGetValue(w[3], b)) { bail("arith: unknown matrix scalar"); break; }
                    if (applyMatrixScalar(w[1], w[2], b, opcode)) {
                        pc += wc;
                        break;
                    }
                }
                if (matrixColumnsForId(w[3]) != nullptr) {
                    Value a;
                    if (!tryGetValue(w[2], a)) { bail("arith: unknown scalar matrix"); break; }
                    if (applyMatrixScalar(w[1], w[3], a, opcode, true)) {
                        pc += wc;
                        break;
                    }
                }
                Value a, b;
                if (!tryGetValue(w[2], a) || !tryGetValue(w[3], b)) { bail("arith: unknown operand"); break; }
                Value r = a;
                const bool useDouble = a.hasDouble || b.hasDouble;
                r.hasDouble = useDouble;
                for (int k = 0; k < a.componentCount(); ++k) {
                    if (useDouble) {
                        double rd = 0.0;
                        switch (opcode) {
                            case spv::OpFAdd: rd = realLane(a, k) + realLane(b, k); break;
                            case spv::OpFSub: rd = realLane(a, k) - realLane(b, k); break;
                            case spv::OpFMul: rd = realLane(a, k) * realLane(b, k); break;
                            case spv::OpFDiv: rd = realLane(a, k) / realLane(b, k); break;
                            default: break;
                        }
                        r.d[k] = rd;
                        r.f[k] = static_cast<float>(rd);
                    } else {
                        switch (opcode) {
                            case spv::OpFAdd: r.f[k] = a.f[k] + b.f[k]; break;
                            case spv::OpFSub: r.f[k] = a.f[k] - b.f[k]; break;
                            case spv::OpFMul: r.f[k] = a.f[k] * b.f[k]; break;
                            case spv::OpFDiv: r.f[k] = a.f[k] / b.f[k]; break;
                            default: break;
                        }
                        r.d[k] = static_cast<double>(r.f[k]);
                    }
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpFNegate: {
                const auto* cols = matrixColumnsForId(w[2]);
                if (cols != nullptr) {
                    std::vector<Value> outCols = *cols;
                    for (Value& col : outCols) {
                        for (int k = 0; k < col.componentCount(); ++k) {
                            col.f[k] = -col.f[k];
                        }
                    }
                    matrixColumns_[w[1]] = std::move(outCols);
                    valueStore_.erase(w[1]);
                    pc += wc;
                    break;
                }
                Value a;
                if (!tryGetValue(w[2], a)) { bail("OpFNegate: unknown operand"); break; }
                Value r = a;
                for (int k = 0; k < a.componentCount(); ++k) {
                    if (a.hasDouble) {
                        const double rd = -realLane(a, k);
                        r.d[k] = rd;
                        r.f[k] = static_cast<float>(rd);
                    } else {
                        r.f[k] = -a.f[k];
                        r.d[k] = static_cast<double>(r.f[k]);
                    }
                }
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
            case spv::OpMatrixTimesScalar: {
                Value s;
                if (!tryGetValue(w[3], s) ||
                    !applyMatrixScalar(w[1], w[2], s, opcode)) {
                    bail("OpMatrixTimesScalar: unknown operand");
                    break;
                }
                pc += wc;
                break;
            }
            case spv::OpVectorTimesMatrix: {
                Value v;
                const auto* cols = matrixColumnsForId(w[3]);
                if (!tryGetValue(w[2], v) || cols == nullptr) {
                    bail("OpVectorTimesMatrix: unknown operand");
                    break;
                }
                Value r = makeFloatValueForType(
                    w[0], static_cast<int>(cols->size()));
                for (std::size_t col = 0; col < cols->size() && col < 4; ++col) {
                    const Value& c = (*cols)[col];
                    float sum = 0.0f;
                    const int n = std::min(v.componentCount(), c.componentCount());
                    for (int row = 0; row < n; ++row) {
                        sum += v.f[row] * c.f[row];
                    }
                    r.f[col] = sum;
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpMatrixTimesVector: {
                // Matrix values are column vectors; M * v is
                // sum(column[i] * v[i]). This covers CTS
                // cull_distance item6's TES mat3(position columns)
                // * gl_TessCoord position formula.
                const auto* mIt = matrixColumnsForId(w[2]);
                Value v;
                if (mIt == nullptr || !tryGetValue(w[3], v)) {
                    bail("OpMatrixTimesVector: unknown operand");
                    break;
                }
                const int fallbackRows = !mIt->empty()
                    ? mIt->front().componentCount() : 1;
                Value r = multiplyMatrixVector(*mIt, v, w[0], fallbackRows);
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpMatrixTimesMatrix: {
                const auto* aCols = matrixColumnsForId(w[2]);
                const auto* bCols = matrixColumnsForId(w[3]);
                if (aCols == nullptr || bCols == nullptr) {
                    bail("OpMatrixTimesMatrix: unknown operand");
                    break;
                }
                const int fallbackRows = !aCols->empty()
                    ? aCols->front().componentCount() : 1;
                std::vector<Value> outCols;
                outCols.reserve(bCols->size());
                for (const Value& bCol : *bCols) {
                    outCols.push_back(
                        multiplyMatrixVector(*aCols, bCol, w[0], fallbackRows));
                }
                matrixColumns_[w[1]] = std::move(outCols);
                valueStore_.erase(w[1]);
                pc += wc;
                break;
            }
            case spv::OpOuterProduct: {
                Value left, right;
                if (!tryGetValue(w[2], left) || !tryGetValue(w[3], right)) {
                    bail("OpOuterProduct: unknown operand");
                    break;
                }
                const int rows = matrixRowsForType(w[0], left.componentCount());
                const int cols = matrixColsForType(w[0], right.componentCount());
                std::vector<Value> outCols;
                outCols.reserve(static_cast<std::size_t>(cols));
                for (int col = 0; col < cols; ++col) {
                    Value outCol;
                    outCol.kind = floatKindForWidth(rows);
                    const int rightLane = std::min(col, right.componentCount() - 1);
                    for (int row = 0; row < rows; ++row) {
                        const int leftLane = std::min(row, left.componentCount() - 1);
                        outCol.f[row] = left.f[leftLane] * right.f[rightLane];
                    }
                    outCols.push_back(outCol);
                }
                matrixColumns_[w[1]] = std::move(outCols);
                valueStore_.erase(w[1]);
                pc += wc;
                break;
            }
            case spv::OpVectorShuffle: {
                // w[0]=type, w[1]=resultId, w[2]=v1, w[3]=v2, w[4..]=indices
                Value v1, v2;
                if (!tryGetValue(w[2], v1) || !tryGetValue(w[3], v2)) { bail("OpVectorShuffle: unknown operand"); break; }
                const std::uint32_t n = wc - 5;   // result component count
                Value r;
                bool isInt = false;
                bool isUInt = false;
                auto typeIt = module_.types.find(w[0]);
                if (typeIt != module_.types.end()) {
                    const auto& t = typeIt->second;
                    std::uint32_t scalarType = 0;
                    if (t.kind == TypeInfo::Kind::Vec2 ||
                        t.kind == TypeInfo::Kind::Vec3 ||
                        t.kind == TypeInfo::Kind::Vec4) {
                        scalarType = t.componentType;
                    } else {
                        scalarType = w[0];
                    }
                    auto sIt = module_.types.find(scalarType);
                    if (sIt != module_.types.end()) {
                        isInt = sIt->second.kind == TypeInfo::Kind::Int;
                        isUInt = sIt->second.kind == TypeInfo::Kind::UInt;
                    }
                }
                if (isInt) {
                    r.kind = (n == 2) ? Value::Kind::Int2 :
                             (n == 3) ? Value::Kind::Int3 :
                             (n == 4) ? Value::Kind::Int4 : Value::Kind::Int;
                } else if (isUInt) {
                    r.kind = (n == 2) ? Value::Kind::UInt2 :
                             (n == 3) ? Value::Kind::UInt3 :
                             (n == 4) ? Value::Kind::UInt4 : Value::Kind::UInt;
                } else {
                    r.kind = (n == 2) ? Value::Kind::Float2 :
                             (n == 3) ? Value::Kind::Float3 :
                             (n == 4) ? Value::Kind::Float4 : Value::Kind::Float;
                }
                const int v1n = v1.componentCount();
                auto copyLane = [&](const Value& src, std::uint32_t srcLane,
                                    std::uint32_t dstLane) {
                    if (dstLane >= 4 || srcLane >= 4) return;
                    if (isInt || isUInt) {
                        if (src.isFloatKind()) {
                            r.i[dstLane] = static_cast<std::int32_t>(src.f[srcLane]);
                        } else {
                            r.i[dstLane] = src.i[srcLane];
                        }
                    } else {
                        if (src.isFloatKind()) {
                            r.f[dstLane] = src.f[srcLane];
                        } else {
                            r.f[dstLane] = static_cast<float>(src.i[srcLane]);
                        }
                    }
                };
                for (std::uint32_t k = 0; k < n && k < 4; ++k) {
                    const std::uint32_t sel = w[4 + k];
                    // sel < v1n → pick from v1; else sel - v1n → pick from v2.
                    // 0xFFFFFFFF means "undefined" — we treat as 0.
                    if (sel == 0xFFFFFFFFu) {
                        if (isInt || isUInt) r.i[k] = 0;
                        else r.f[k] = 0.0f;
                    } else if (sel < static_cast<std::uint32_t>(v1n)) {
                        copyLane(v1, sel, k);
                    } else {
                        copyLane(v2, sel - v1n, k);
                    }
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpExtInst: {
                // w[0]=type, w[1]=resultId, w[2]=setId, w[3]=glslOp, w[4..]=operands
                // Word count excludes the header word (which we skipped
                // via `w = words + pc + 1`). From `w[]` the instruction
                // uses 4 slots (type, result, set, glslOp) before the
                // operands start at w[4], so operand count is
                // `wc - 1 - 4 = wc - 5`. The old `wc - 4` reached one
                // word past the last real operand — for 2-operand
                // FMin / FMax this pointed into the next instruction's
                // header, which `tryGetValue` rejected as unknown and
                // `evalExtInst` bailed on. Exposed when triangles-
                // input GS bodies started running through the
                // interpreter (gs_lines_code / gs_triangles_code use
                // `min(a.x, b.x)` to compute an AABB).
                if (module_.extInstImports.count(w[2]) == 0) {
                    bail("OpExtInst: unsupported instruction set");
                    break;
                }
                if (w[3] == ::GLSLstd450Determinant ||
                    w[3] == ::GLSLstd450MatrixInverse) {
                    if (wc < 6) {
                        bail("OpExtInst: missing matrix operand");
                        break;
                    }
                    const auto* cols = matrixColumnsForId(w[4]);
                    if (cols == nullptr) {
                        bail("OpExtInst: unknown matrix operand");
                        break;
                    }
                    const int n = squareMatrixSizeForColumns(*cols);
                    if (n < 2 || n > 3) {
                        bail("OpExtInst: unsupported matrix size");
                        break;
                    }

                    if (w[3] == ::GLSLstd450Determinant) {
                        Value r;
                        r.kind = Value::Kind::Float;
                        r.hasDouble = floatScalarByteSizeForType(w[0]) >= 8;
                        r.d[0] = determinantFromColumns(*cols, n);
                        r.f[0] = static_cast<float>(r.d[0]);
                        valueStore_[w[1]] = r;
                        matrixColumns_.erase(w[1]);
                    } else {
                        const int resultRows = matrixRowsForType(w[0], n);
                        const int resultCols = matrixColsForType(w[0], n);
                        if (resultRows != n || resultCols != n) {
                            bail("OpExtInst: matrix inverse result shape mismatch");
                            break;
                        }
                        matrixColumns_[w[1]] = inverseMatrixColumns(
                            *cols, n, floatScalarByteSizeForType(w[0]) >= 8);
                        valueStore_.erase(w[1]);
                    }
                    pc += wc;
                    break;
                }
                const bool frexpOutParam = w[3] == ::GLSLstd450Frexp;
                const bool modfOutParam = w[3] == ::GLSLstd450Modf;
                const bool frexpStruct = w[3] == ::GLSLstd450FrexpStruct;
                const bool modfStruct = w[3] == ::GLSLstd450ModfStruct;
                if (frexpOutParam || modfOutParam || frexpStruct || modfStruct) {
                    const bool writesOutParam = frexpOutParam || modfOutParam;
                    if ((writesOutParam && wc < 7) || (!writesOutParam && wc < 6)) {
                        bail("OpExtInst: missing frexp/modf operand");
                        break;
                    }
                    Value x;
                    if (!tryGetValue(w[4], x) || !x.isFloatKind()) {
                        bail("OpExtInst: invalid frexp/modf operand");
                        break;
                    }

                    Value result = x;
                    Value outParam;
                    const int n = std::clamp(x.componentCount(), 1, 4);
                    const std::uint32_t floatResultType =
                        writesOutParam ? w[0] : firstStructMemberType(w[0]);
                    const bool doubleResult =
                        floatScalarByteSizeForType(floatResultType) >= 8;
                    result.hasDouble = doubleResult;

                    if (frexpOutParam || frexpStruct) {
                        outParam.kind = n == 1 ? Value::Kind::Int :
                                        n == 2 ? Value::Kind::Int2 :
                                        n == 3 ? Value::Kind::Int3 :
                                                 Value::Kind::Int4;
                        for (int k = 0; k < n; ++k) {
                            int exponent = 0;
                            const double mantissa = std::frexp(realLane(x, k), &exponent);
                            result.f[k] = static_cast<float>(mantissa);
                            result.d[k] = mantissa;
                            outParam.i[k] = exponent;
                        }
                    } else {
                        outParam = x;
                        outParam.hasDouble = doubleResult;
                        for (int k = 0; k < n; ++k) {
                            double integral = 0.0;
                            const double fraction = std::modf(realLane(x, k), &integral);
                            result.f[k] = static_cast<float>(fraction);
                            result.d[k] = fraction;
                            outParam.f[k] = static_cast<float>(integral);
                            outParam.d[k] = integral;
                        }
                    }

                    if (writesOutParam) {
                        if (!storeExtInstOutParam(w[5], outParam)) {
                            break;
                        }
                        valueStore_[w[1]] = result;
                    } else {
                        compositeValues_[w[1]] = {result, outParam};
                        valueStore_.erase(w[1]);
                    }
                    pc += wc;
                    break;
                }
                valueStore_[w[1]] = evalExtInst(
                    w[3], &w[4], wc - 5, floatScalarByteSizeForType(w[0]) >= 8);
                pc += wc;
                break;
            }
            // ─ Integer arithmetic / bitcast / conversions ─
            case spv::OpIAdd: case spv::OpISub: case spv::OpIMul:
            case spv::OpSDiv: case spv::OpSRem: case spv::OpSMod: case spv::OpUMod: {
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
                        case spv::OpSMod: {
                            // SPIR-V §3.32.13: OpSMod result has sign
                            // of operand 2 (the divisor), unlike
                            // OpSRem whose sign follows operand 1.
                            // Computed as `a - b * floor(a / b)` with
                            // floor rounding for negative quotients.
                            if (b.i[k] == 0) { r.i[k] = 0; break; }
                            const std::int32_t ai = a.i[k], bi = b.i[k];
                            std::int32_t q = ai / bi;
                            // Adjust quotient toward floor when the
                            // signed division truncation differs from
                            // floor (mixed-sign operands with a
                            // non-zero remainder).
                            if ((ai % bi != 0) && ((ai < 0) != (bi < 0))) {
                                q -= 1;
                            }
                            r.i[k] = ai - bi * q;
                            break;
                        }
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
                // Reinterpret bits. Source can be int/uint/float; target
                // is int/uint/float. Read from the operand's native slot
                // (float source → a.f[], int/uint source → a.i[]) and
                // write to the target's native slot. Previous impl
                // unconditionally read from `a.f[]` which broke every
                // int→uint / uint→int / int→int cast — the operand's
                // float slot is zero-initialised when the source is an
                // integer Value, so the cast produced 0. Observable on
                // CTS `limits.max_uniform_components` which compiles
                // `uint(uni_array[i].x)` to OpBitcast int→uint — each
                // iteration's accumulator addend was 0, so the sum
                // stayed at 0 instead of reaching 524800.
                Value a;
                if (!tryGetValue(w[2], a)) { bail("OpBitcast: unknown operand"); break; }
                const bool srcIsFloat = a.isFloatKind();
                auto tIt = module_.types.find(w[0]);
                Value r = a;
                if (tIt != module_.types.end()) {
                    switch (tIt->second.kind) {
                        case TypeInfo::Kind::Int:
                            r.kind = Value::Kind::Int;
                            for (int k = 0; k < a.componentCount(); ++k) {
                                if (srcIsFloat) {
                                    std::memcpy(&r.i[k], &a.f[k], 4);
                                } else {
                                    r.i[k] = a.i[k];
                                }
                            }
                            break;
                        case TypeInfo::Kind::UInt:
                            r.kind = Value::Kind::UInt;
                            for (int k = 0; k < a.componentCount(); ++k) {
                                if (srcIsFloat) {
                                    std::memcpy(&r.i[k], &a.f[k], 4);
                                } else {
                                    r.i[k] = a.i[k];
                                }
                            }
                            break;
                        case TypeInfo::Kind::Float:
                            r.kind = Value::Kind::Float;
                            for (int k = 0; k < a.componentCount(); ++k) {
                                if (srcIsFloat) {
                                    r.f[k] = a.f[k];
                                } else {
                                    std::memcpy(&r.f[k], &a.i[k], 4);
                                }
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
                const int n = a.componentCount();
                Value r = makeFloatValueForType(w[0], n);
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
            case spv::OpFConvert: {
                const auto* cols = matrixColumnsForId(w[2]);
                if (cols != nullptr) {
                    matrixColumns_[w[1]] = *cols;
                    valueStore_.erase(w[1]);
                    pc += wc;
                    break;
                }
                Value a;
                if (!tryGetValue(w[2], a)) { bail("OpFConvert: unknown operand"); break; }
                const int n = a.componentCount();
                Value r = makeFloatValueForType(w[0], n);
                if (a.isFloatKind()) {
                    for (int k = 0; k < n; ++k) r.f[k] = a.f[k];
                } else if (a.isIntKind()) {
                    for (int k = 0; k < n; ++k) r.f[k] = static_cast<float>(a.i[k]);
                } else if (a.kind == Value::Kind::Bool) {
                    r.f[0] = a.bval ? 1.0f : 0.0f;
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
            case spv::OpUGreaterThan:
            case spv::OpSLessThan: case spv::OpSGreaterThan:
            case spv::OpUGreaterThanEqual:
            case spv::OpSLessThanEqual: case spv::OpSGreaterThanEqual:
            case spv::OpULessThan: case spv::OpULessThanEqual: {
                Value a, b;
                if (!tryGetValue(w[2], a) || !tryGetValue(w[3], b)) { bail("int-cmp: unknown operand"); break; }
                std::array<bool, 4> lanes{};
                const int n = std::max(a.componentCount(), b.componentCount());
                for (int k = 0; k < n && k < 4; ++k) {
                    const int ak = std::min(k, a.componentCount() - 1);
                    const int bk = std::min(k, b.componentCount() - 1);
                    const std::int32_t ai = a.i[ak], bi = b.i[bk];
                    const std::uint32_t au = static_cast<std::uint32_t>(ai);
                    const std::uint32_t bu = static_cast<std::uint32_t>(bi);
                    switch (opcode) {
                        case spv::OpIEqual:             lanes[k] = (ai == bi); break;
                        case spv::OpINotEqual:          lanes[k] = (ai != bi); break;
                        case spv::OpUGreaterThan:       lanes[k] = (au >  bu); break;
                        case spv::OpSLessThan:          lanes[k] = (ai <  bi); break;
                        case spv::OpSGreaterThan:       lanes[k] = (ai >  bi); break;
                        case spv::OpUGreaterThanEqual:  lanes[k] = (au >= bu); break;
                        case spv::OpSLessThanEqual:     lanes[k] = (ai <= bi); break;
                        case spv::OpSGreaterThanEqual:  lanes[k] = (ai >= bi); break;
                        case spv::OpULessThan:          lanes[k] = (au <  bu); break;
                        case spv::OpULessThanEqual:     lanes[k] = (au <= bu); break;
                    }
                }
                valueStore_[w[1]] = makeBoolResult(w[0], lanes, n);
                pc += wc;
                break;
            }
            case spv::OpFOrdEqual: case spv::OpFOrdNotEqual:
            case spv::OpFOrdLessThan: case spv::OpFOrdGreaterThan:
            case spv::OpFOrdLessThanEqual: case spv::OpFOrdGreaterThanEqual:
            // OpFUnord* are the "unordered" variants — they return
            // true when either operand is NaN, whereas OpFOrd*
            // returns false in that case. glslang emits OpFUnord*
            // for GLSL `!=` / `<` / `>` / `<=` / `>=` by default
            // (scalar comparisons between floats); the ordered
            // forms come from GLSL.std.450 builtins or explicit
            // isnan handling. We don't distinguish NaN semantics
            // in the interpreter — all our tests use finite
            // values — so both variants share the same impl.
            case spv::OpFUnordEqual: case spv::OpFUnordNotEqual:
            case spv::OpFUnordLessThan: case spv::OpFUnordGreaterThan:
            case spv::OpFUnordLessThanEqual: case spv::OpFUnordGreaterThanEqual: {
                Value a, b;
                if (!tryGetValue(w[2], a) || !tryGetValue(w[3], b)) { bail("flt-cmp: unknown operand"); break; }
                std::array<bool, 4> lanes{};
                const int n = std::max(a.componentCount(), b.componentCount());
                for (int k = 0; k < n && k < 4; ++k) {
                    const int ak = std::min(k, a.componentCount() - 1);
                    const int bk = std::min(k, b.componentCount() - 1);
                    const float af = a.f[ak], bf = b.f[bk];
                    switch (opcode) {
                        case spv::OpFOrdEqual:
                        case spv::OpFUnordEqual:            lanes[k] = (af == bf); break;
                        case spv::OpFOrdNotEqual:
                        case spv::OpFUnordNotEqual:         lanes[k] = (af != bf); break;
                        case spv::OpFOrdLessThan:
                        case spv::OpFUnordLessThan:         lanes[k] = (af <  bf); break;
                        case spv::OpFOrdGreaterThan:
                        case spv::OpFUnordGreaterThan:      lanes[k] = (af >  bf); break;
                        case spv::OpFOrdLessThanEqual:
                        case spv::OpFUnordLessThanEqual:    lanes[k] = (af <= bf); break;
                        case spv::OpFOrdGreaterThanEqual:
                        case spv::OpFUnordGreaterThanEqual: lanes[k] = (af >= bf); break;
                    }
                }
                valueStore_[w[1]] = makeBoolResult(w[0], lanes, n);
                pc += wc;
                break;
            }
            case spv::OpLogicalNot: {
                Value a;
                if (!tryGetValue(w[2], a)) { bail("OpLogicalNot: unknown operand"); break; }
                std::array<bool, 4> lanes{};
                const int n = a.componentCount();
                for (int k = 0; k < n && k < 4; ++k) {
                    lanes[k] = !truthy(a, k);
                }
                valueStore_[w[1]] = makeBoolResult(w[0], lanes, n);
                pc += wc;
                break;
            }
            case spv::OpLogicalAnd: case spv::OpLogicalOr:
            case spv::OpLogicalEqual:
            case spv::OpLogicalNotEqual: {
                Value a, b;
                if (!tryGetValue(w[2], a) || !tryGetValue(w[3], b)) { bail("bool-op: unknown operand"); break; }
                std::array<bool, 4> lanes{};
                const int n = std::max(a.componentCount(), b.componentCount());
                for (int k = 0; k < n && k < 4; ++k) {
                    const bool av = truthy(a, k);
                    const bool bv = truthy(b, k);
                    switch (opcode) {
                        case spv::OpLogicalAnd:       lanes[k] = av && bv; break;
                        case spv::OpLogicalOr:        lanes[k] = av || bv; break;
                        case spv::OpLogicalEqual:     lanes[k] = av == bv; break;
                        case spv::OpLogicalNotEqual:  lanes[k] = av != bv; break;
                    }
                }
                valueStore_[w[1]] = makeBoolResult(w[0], lanes, n);
                pc += wc;
                break;
            }
            case spv::OpSelect: {
                // w[2]=cond, w[3]=trueVal, w[4]=falseVal
                Value c, t, f;
                if (!tryGetValue(w[2], c) || !tryGetValue(w[3], t) || !tryGetValue(w[4], f)) {
                    bail("OpSelect: unknown operand"); break;
                }
                if (c.componentCount() <= 1) {
                    valueStore_[w[1]] = truthy(c, 0) ? t : f;
                    pc += wc;
                    break;
                }

                Value r = t;
                const int lanes = std::min(r.componentCount(), 4);
                for (int k = 0; k < lanes; ++k) {
                    const Value& src = truthy(c, k) ? t : f;
                    const int srcLane = std::min(k, src.componentCount() - 1);
                    if (r.isFloatKind()) {
                        r.f[k] = src.f[srcLane];
                    } else if (r.isIntKind()) {
                        r.i[k] = src.i[srcLane];
                    } else if (r.kind == Value::Kind::Bool) {
                        r.bval = truthy(src, srcLane);
                    }
                }
                valueStore_[w[1]] = r;
                pc += wc;
                break;
            }
            case spv::OpAny: case spv::OpAll: {
                Value a;
                if (!tryGetValue(w[2], a)) { bail("OpAny/All: unknown operand"); break; }
                Value r; r.kind = Value::Kind::Bool;
                bool any = false, all = true;
                for (int k = 0; k < a.componentCount(); ++k) {
                    if (truthy(a, k)) any = true;
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
            case spv::OpControlBarrier:
            case spv::OpMemoryBarrier:
                pc += wc;   // CPU TCS replay serializes invocations.
                break;
            case spv::OpEmitVertex:
                emitVertex(emitted);
                pc += wc;
                break;
            case spv::OpEndPrimitive: {
                // Push the current emitted count as a primitive end —
                // callers iterate primEnds pair-wise (prev_end ..
                // next_end) to slice each emitted strip into a
                // standalone primitive.
                const std::size_t sz = emitted.size();
                if (primEnds.empty() || primEnds.back() != sz) {
                    primEnds.push_back(sz);
                }
                pc += wc;
                break;
            }
            case spv::OpEmitStreamVertex: {
                // Sprint 8 #9-C (CKPT95→CKPT96): w[0] = <id> Stream — must
                // be a constant Int per SPIR-V spec. Decode via
                // valueStore_ / module_.constants and route the emit to
                // the named stream. Stream out-of-range clamps to 0
                // (graceful degrade) — multi-stream limit advertised at
                // 4 (gl_MaxTransformFeedbackStreams floor).
                //
                // CKPT96 fix: was reading w[1] (off-by-one — `w` already
                // points one past the opcode word, so the first operand
                // is at w[0], not w[1]). Caught at runtime: streamCounts
                // showed all 32 vertices tagged stream 0 even though 4 of
                // 8 emits per invocation use OpEmitStreamVertex(1).
                std::uint32_t streamIdx = 0;
                if (wc >= 2) {
                    Value sv;
                    if (tryGetValue(w[0], sv)) {
                        const std::int32_t s = sv.i[0];
                        if (s >= 0 && static_cast<std::uint32_t>(s) < 4) {
                            streamIdx = static_cast<std::uint32_t>(s);
                        }
                    }
                }
                emitVertex(emitted, streamIdx);
                pc += wc;
                break;
            }
            case spv::OpEndStreamPrimitive: {
                // Sprint 8 #9-C (CKPT95): same primitive-boundary
                // semantics as OpEndPrimitive. Per-stream prim
                // segmentation (separate primEnds per stream) is a
                // Day-24 / future-CKPT refinement — until per-stream
                // BO writes need it, a shared boundary suffices for
                // current single-stream-renders + count tracking.
                const std::size_t sz = emitted.size();
                if (primEnds.empty() || primEnds.back() != sz) {
                    primEnds.push_back(sz);
                }
                pc += wc;
                break;
            }
            case spv::OpFunctionCall: {
                // Sprint 18 Bank C-2 (`viewport_array.draw_mulitple...`):
                // CTS uses a void helper `routine(int index)` whose only
                // effects are stores to GS outputs plus EmitVertex /
                // EndPrimitive. Support that narrow side-effect call shape
                // without claiming general SPIR-V call-frame semantics.
                if (wc < 4) {
                    bail("OpFunctionCall: malformed");
                    break;
                }
                const std::uint32_t resultTypeId = w[0];
                const std::uint32_t resultId = w[1];
                const std::uint32_t functionId = w[2];
                (void)resultId;
                auto typeIt = module_.types.find(resultTypeId);
                if (typeIt == module_.types.end() ||
                    typeIt->second.kind != TypeInfo::Kind::Void) {
                    bail("OpFunctionCall: non-void return deferred");
                    break;
                }
                auto fnIt = module_.functions.find(functionId);
                if (fnIt == module_.functions.end()) {
                    bail("OpFunctionCall: unknown function");
                    break;
                }
                const auto& fn = fnIt->second;
                const std::uint32_t argCount = wc - 4;
                if (!callStack.empty()) {
                    bail("OpFunctionCall: nested calls deferred");
                    break;
                }
                if (argCount != 1) {
                    bail("OpFunctionCall: only single-parameter helpers supported");
                    break;
                }
                if (activeFunctions.count(functionId) != 0) {
                    bail("OpFunctionCall: recursion deferred");
                    break;
                }
                if (fn.parameters.size() != argCount) {
                    bail("OpFunctionCall: parameter count mismatch");
                    break;
                }
                if (fn.parameterTypeIds.size() != argCount) {
                    bail("OpFunctionCall: parameter type count mismatch");
                    break;
                }
                std::unordered_map<std::uint32_t, std::uint32_t> callPointerAliases;
                for (std::uint32_t ai = 0; ai < argCount; ++ai) {
                    const std::uint32_t paramId = fn.parameters[ai];
                    const std::uint32_t paramTypeId = fn.parameterTypeIds[ai];
                    auto paramTypeIt = module_.types.find(paramTypeId);
                    if (paramTypeIt == module_.types.end()) {
                        bail("OpFunctionCall: missing parameter type");
                        break;
                    }
                    if (paramTypeIt->second.kind != TypeInfo::Kind::Pointer ||
                        paramTypeIt->second.storageClass != spv::StorageClassFunction ||
                        module_.scalarWidth(paramTypeIt->second.pointeeType) != 1) {
                        bail("OpFunctionCall: non-scalar Function pointer parameter deferred");
                        break;
                    }
                    const std::uint32_t argVarId = w[3 + ai];
                    auto argVarIt = module_.variables.find(argVarId);
                    if (argVarIt == module_.variables.end() ||
                        argVarIt->second.storageClass != spv::StorageClassFunction) {
                        bail("OpFunctionCall: non-Function pointer argument deferred");
                        break;
                    }
                    auto argTypeIt = module_.types.find(argVarIt->second.typeId);
                    if (argTypeIt == module_.types.end() ||
                        argTypeIt->second.kind != TypeInfo::Kind::Pointer ||
                        argTypeIt->second.storageClass != spv::StorageClassFunction ||
                        argTypeIt->second.pointeeType != paramTypeIt->second.pointeeType ||
                        module_.scalarWidth(argTypeIt->second.pointeeType) != 1) {
                        bail("OpFunctionCall: incompatible pointer argument deferred");
                        break;
                    }
                    callPointerAliases[paramId] = argVarId;
                }
                if (errored_) break;
                CallFrame frame;
                frame.returnPc = pc + wc;
                frame.functionEnd = currentFuncEnd;
                frame.labels = std::move(labelMap);
                frame.previousLabel = previousLabel;
                frame.currentLabel = currentLabel;
                frame.calleeFunctionId = functionId;
                frame.pointerAliases = std::move(functionPointerAliases);
                callStack.push_back(std::move(frame));
                functionPointerAliases = std::move(callPointerAliases);
                activeFunctions.insert(functionId);

                pc = fn.bodyStart;
                currentFuncEnd = fn.bodyEnd;
                labelMap = buildLabelMap(pc, currentFuncEnd);
                previousLabel = 0;
                currentLabel = 0;
                break;
            }
            case spv::OpReturn: {
                if (!callStack.empty()) {
                    CallFrame frame = std::move(callStack.back());
                    callStack.pop_back();
                    activeFunctions.erase(frame.calleeFunctionId);
                    pc = frame.returnPc;
                    currentFuncEnd = frame.functionEnd;
                    labelMap = std::move(frame.labels);
                    previousLabel = frame.previousLabel;
                    currentLabel = frame.currentLabel;
                    functionPointerAliases = std::move(frame.pointerAliases);
                    break;
                }
                // Implicit EndPrimitive at function exit — GL 4.6 §11.3.4
                // says the current strip (if any) ends when the shader
                // returns. Record the boundary iff any vertex was
                // emitted since the last one.
                const std::size_t sz = emitted.size();
                const std::size_t prev = primEnds.empty() ? primEndsStart : primEnds.back();
                if (sz > prev) {
                    primEnds.push_back(sz);
                }
                return true;
            }
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
        case spv::OpMatrixTimesScalar:
        case spv::OpVectorTimesMatrix:
        case spv::OpMatrixTimesVector:
        case spv::OpMatrixTimesMatrix:
        case spv::OpOuterProduct:
        case spv::OpDot:
        // ─ Int arith ─
        case spv::OpIAdd:
        case spv::OpISub:
        case spv::OpIMul:
        case spv::OpSDiv:
        case spv::OpSRem:
        case spv::OpSMod:
        case spv::OpUMod:
        case spv::OpSNegate:
        // ─ Bit ops ─
        case spv::OpBitwiseAnd:
        case spv::OpShiftLeftLogical:
        // ─ SSBO integer atomics ─
        case spv::OpAtomicLoad:
        case spv::OpAtomicStore:
        case spv::OpAtomicExchange:
        case spv::OpAtomicCompareExchange:
        case spv::OpAtomicCompareExchangeWeak:
        case spv::OpAtomicIIncrement:
        case spv::OpAtomicIDecrement:
        case spv::OpAtomicIAdd:
        case spv::OpAtomicISub:
        case spv::OpAtomicSMin:
        case spv::OpAtomicUMin:
        case spv::OpAtomicSMax:
        case spv::OpAtomicUMax:
        case spv::OpAtomicAnd:
        case spv::OpAtomicOr:
        case spv::OpAtomicXor:
        // ─ Conversions ─
        case spv::OpConvertFToS:
        case spv::OpConvertFToU:
        case spv::OpConvertSToF:
        case spv::OpConvertUToF:
        case spv::OpFConvert:
        // ─ Int comparisons ─
        case spv::OpIEqual:
        case spv::OpINotEqual:
        case spv::OpUGreaterThan:
        case spv::OpSLessThan:
        case spv::OpSGreaterThan:
        case spv::OpUGreaterThanEqual:
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
        case spv::OpFUnordEqual:
        case spv::OpFUnordNotEqual:
        case spv::OpFUnordLessThan:
        case spv::OpFUnordGreaterThan:
        case spv::OpFUnordLessThanEqual:
        case spv::OpFUnordGreaterThanEqual:
        // ─ Logical / selection ─
        case spv::OpLogicalNot:
        case spv::OpLogicalAnd:
        case spv::OpLogicalOr:
        case spv::OpLogicalEqual:
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
        case spv::OpControlBarrier:
        case spv::OpMemoryBarrier:
        // ─ GS-specific ─
        case spv::OpEmitVertex:
        case spv::OpEndPrimitive:
        // ─ GS multi-stream (Sprint 8 #9-C, CKPT95) ─
        case spv::OpEmitStreamVertex:
        case spv::OpEndStreamPrimitive:
        // ─ Function ─
        case spv::OpReturn:
        case spv::OpFunction:
        case spv::OpFunctionParameter:
        case spv::OpFunctionCall:
        case spv::OpFunctionEnd:
        // ─ Sampler / texture (Sprint 6 P1 sub-task 3 day 3, CKPT43) ─
        case spv::OpSampledImage:               // 86
        case spv::OpImageSampleImplicitLod:     // 87 (defensive)
        case spv::OpImageSampleExplicitLod:     // 88
        // ─ Storage image load (Sprint 7 P1 #4, CKPT54) ─
        case spv::OpImageRead:                  // 98
        // ─ Storage image write + size query (Sprint 14 Day 7, CKPT160) ─
        case spv::OpImageWrite:                 // 99 (currently no-op,
                                                //     see body handler)
        case spv::OpImageQuerySizeLod:          // 103
        case spv::OpImageQuerySize:             // 104
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
    program.gsPresent = false;
    program.gsInputTopology = 0;
    program.gsOutputTopology = 0;
    program.gsMaxVertices = 0;
    program.gsInvocations = 1;

    const bool trace = std::getenv("APPGL_TRACE_GS_EMUL") != nullptr;
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

    // Metadata population. Happens even if the body is outside the
    // emulator's opcode subset — `glGetProgramiv(GL_GEOMETRY_*)` has
    // to answer correctly for every GS-containing program, not just
    // the ones we can run.
    program.gsPresent = true;
    if (haveInputTopo)  program.gsInputTopology = inputTopo;
    if (haveOutputTopo) program.gsOutputTopology = outputTopo;
    program.gsMaxVertices = maxVertices;
    program.gsInvocations = invocations;

    if (!haveInputTopo || !haveOutputTopo || maxVertices == 0) return false;
    // Multi-invocation GS supported via per-invocation re-run in
    // `emulateGeometryDraw` (gl_InvocationID fed into the
    // interpreter via setGsInvocationId). Guard against runaway
    // invocations counts that would blow up draw time: reject
    // anything above a sensible advertised upper bound.
    constexpr std::uint32_t kMaxGsInvocationsEmulated = 32;
    if (invocations == 0 || invocations > kMaxGsInvocationsEmulated) return false;
    (void)trace;   // still used in the body walker below

    // Reject emulation when the VS writes gl_ClipDistance /
    // gl_CullDistance. Infrastructure for propagating these through
    // the synth pass-through VS landed in round 1a (captureClipCull
    // + pre-GS cull check + [[clip_distance]] emission), but the
    // synthesized path still delivers wrong pixel coverage for the
    // CTS `cull_distance.functional_test_item_5` lines + triangles
    // variants (8 points variants were regressing too before the
    // re-enabled stopgap — my per-primitive cull check + clip
    // emission gives correct behaviour for the simple passthrough
    // case but not the grid-of-subgrids cases the CTS uses). Kept
    // the scaffolding for later — `cull_distance.functional_test
    // _item_5_primitive_mode_*` remains a targeted follow-up when
    // the rendering semantics land.
    auto programStoresClipOrCull = [&](const std::vector<std::uint32_t>& spirv) -> bool {
        if (spirv.empty()) return false;
        SpirvModule m;
        if (!m.parse(spirv.data(), spirv.size())) return false;
        if (!m.haveFuncBody) return false;
        std::unordered_map<std::uint32_t, std::vector<std::uint32_t>> clipCullMembers;
        for (const auto& [structId, mdSet] : m.memberDecorations) {
            for (const auto& [memberIdx, memberDeco] : mdSet.perMember) {
                if (memberDeco.hasBuiltIn &&
                    (memberDeco.builtIn == spv::BuiltInClipDistance ||
                     memberDeco.builtIn == spv::BuiltInCullDistance)) {
                    clipCullMembers[structId].push_back(memberIdx);
                }
            }
        }
        std::unordered_set<std::uint32_t> clipCullVars;
        for (const auto& [varId, info] : m.variables) {
            if (info.storageClass != spv::StorageClassOutput) continue;
            auto dIt = m.decorations.find(varId);
            if (dIt != m.decorations.end() && dIt->second.hasBuiltIn &&
                (dIt->second.builtIn == spv::BuiltInClipDistance ||
                 dIt->second.builtIn == spv::BuiltInCullDistance)) {
                clipCullVars.insert(varId);
            }
        }
        std::unordered_set<std::uint32_t> clipCullAccessChains;
        std::size_t pc = m.funcBodyStart;
        while (pc < m.funcBodyEnd) {
            const std::uint32_t inst = m.words[pc];
            const std::uint16_t opcode = static_cast<std::uint16_t>(inst & 0xFFFF);
            const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
            if (wc == 0) return false;
            if (opcode == spv::OpAccessChain && wc >= 4) {
                const std::uint32_t resultId = m.words[pc + 2];
                const std::uint32_t base = m.words[pc + 3];
                if (clipCullVars.count(base) != 0) {
                    clipCullAccessChains.insert(resultId);
                } else {
                    auto vIt = m.variables.find(base);
                    if (vIt != m.variables.end() && wc >= 5) {
                        const std::uint32_t firstIdxId = m.words[pc + 4];
                        auto cIt = m.constants.find(firstIdxId);
                        if (cIt != m.constants.end()) {
                            const std::int32_t idx = cIt->second.i[0];
                            auto tIt = m.types.find(vIt->second.typeId);
                            if (tIt != m.types.end()) {
                                const std::uint32_t pointeeType = tIt->second.pointeeType;
                                auto cm = clipCullMembers.find(pointeeType);
                                if (cm != clipCullMembers.end()) {
                                    for (std::uint32_t mi : cm->second) {
                                        if (static_cast<std::uint32_t>(idx) == mi) {
                                            clipCullAccessChains.insert(resultId);
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else if (opcode == spv::OpStore && wc >= 3) {
                const std::uint32_t ptr = m.words[pc + 1];
                if (clipCullVars.count(ptr) != 0 ||
                    clipCullAccessChains.count(ptr) != 0) {
                    return true;
                }
            }
            pc += wc;
        }
        return false;
    };
    // Session 16 stopgap (narrowed in session 16b Phase 6): the
    // original `programStoresClipOrCull` rejected whenever the VS
    // wrote gl_ClipDistance OR gl_CullDistance. Full-sweep
    // comparison (baseline 41 / nostopgap 34 cull_distance
    // passes) showed removing it regresses 7
    // `functional_test_item_5_primitive_mode_points_max_culldist_
    // {1..7}` tests and gains 0 others — the rendering-pipeline
    // gap the stopgap was papering over is still open. Leaving
    // the stopgap for now; future work can try alternative
    // routings (e.g. disabling combined clip/cull slice on the
    // synth VS when the cull count is ambiguous, or
    // reflecting the FS input layout).
    if (programStoresClipOrCull(program.vertexSpirv)) {
        if (std::getenv("APPGL_TRACE_GS_EMUL") != nullptr) {
            std::fprintf(stderr, "[GS-emul] reject: VS stores gl_Clip/CullDistance — "
                         "emulator path still has pixel-coverage gaps for CTS cull_distance.*\n");
        }
        return false;
    }

    // Walk the function body and reject on any unsupported opcode.
    // On rejection, log the opcode + GS source hash so that sweep
    // diagnostics can grep for "[GS-emul] reject" and enumerate which
    // opcodes are still missing. Gated behind APPGL_TRACE_GS_EMUL so
    // production runs stay quiet.
    auto scanFunctionBody = [&](std::size_t start, std::size_t end) -> bool {
        std::size_t pc = start;
        while (pc < end) {
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
        return true;
    };
    if (!mod.functions.empty()) {
        for (const auto& kv : mod.functions) {
            if (!scanFunctionBody(kv.second.bodyStart, kv.second.bodyEnd)) {
                return false;
            }
        }
    } else if (!scanFunctionBody(mod.funcBodyStart, mod.funcBodyEnd)) {
        return false;
    }

    program.geometryEmulated = true;
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
std::uint8_t scalarByteSizeForType(const SpirvModule& mod, std::uint32_t typeId) {
    auto it = mod.types.find(typeId);
    if (it == mod.types.end()) return 4;
    const TypeInfo& t = it->second;
    switch (t.kind) {
        case TypeInfo::Kind::Pointer:
            return scalarByteSizeForType(mod, t.pointeeType);
        case TypeInfo::Kind::Vec2:
        case TypeInfo::Kind::Vec3:
        case TypeInfo::Kind::Vec4:
        case TypeInfo::Kind::Matrix:
        case TypeInfo::Kind::Array:
        case TypeInfo::Kind::RuntimeArray:
            return scalarByteSizeForType(mod, t.componentType);
        case TypeInfo::Kind::Int:
        case TypeInfo::Kind::UInt:
        case TypeInfo::Kind::Float:
            return static_cast<std::uint8_t>(
                std::clamp<std::uint32_t>(t.elementScalarWidth, 4, 8));
        default:
            return 4;
    }
}

std::uint32_t arrayLengthForType(const SpirvModule& mod, const TypeInfo& t) {
    if (t.kind != TypeInfo::Kind::Array) return 1;
    auto cIt = mod.constants.find(t.arrayLengthConstId);
    if (cIt == mod.constants.end()) return 1;
    return std::max<std::uint32_t>(1, static_cast<std::uint32_t>(cIt->second.i[0]));
}

void appendStageSlotWidthsForType(const SpirvModule& mod,
                                  std::uint32_t typeId,
                                  std::vector<std::uint32_t>& widths) {
    auto it = mod.types.find(typeId);
    if (it == mod.types.end()) return;
    const TypeInfo& t = it->second;
    switch (t.kind) {
        case TypeInfo::Kind::Pointer:
            appendStageSlotWidthsForType(mod, t.pointeeType, widths);
            break;
        case TypeInfo::Kind::Array: {
            const std::uint32_t len = arrayLengthForType(mod, t);
            for (std::uint32_t i = 0; i < len; ++i) {
                appendStageSlotWidthsForType(mod, t.componentType, widths);
            }
            break;
        }
        case TypeInfo::Kind::Matrix: {
            const std::uint32_t colWidth = mod.scalarWidth(t.componentType);
            for (std::uint32_t i = 0; i < t.count; ++i) {
                widths.push_back(std::max<std::uint32_t>(1, colWidth));
            }
            break;
        }
        default: {
            const std::uint32_t w = mod.scalarWidth(typeId);
            if (w != 0) widths.push_back(w);
            break;
        }
    }
}

std::uint8_t baseTypeForType(const SpirvModule& mod, std::uint32_t typeId) {
    auto it = mod.types.find(typeId);
    while (it != mod.types.end()) {
        const TypeInfo& t = it->second;
        switch (t.kind) {
            case TypeInfo::Kind::Pointer:
            case TypeInfo::Kind::Array:
            case TypeInfo::Kind::RuntimeArray:
            case TypeInfo::Kind::Matrix:
            case TypeInfo::Kind::Vec2:
            case TypeInfo::Kind::Vec3:
            case TypeInfo::Kind::Vec4:
                it = mod.types.find(t.componentType ? t.componentType : t.pointeeType);
                continue;
            case TypeInfo::Kind::Int:
                return 1;
            case TypeInfo::Kind::UInt:
                return 2;
            case TypeInfo::Kind::Float:
            default:
                return 0;
        }
    }
    return 0;
}

struct OutputVaryingDesc {
    std::string name;
    std::uint32_t width = 0;     // flat scalar count (always in scalar units)
    std::uint32_t location = 0;
    std::uint8_t interp = 0;     // 0=smooth, 1=flat, 2=noperspective, 3=centroid
    std::uint8_t baseType = 0;   // 0=float, 1=int, 2=uint
    std::uint8_t scalarByteSize = 4;
    std::vector<std::uint32_t> stageSlotWidths;
    // Sprint 8 #9-C (CKPT96) — GLSL `layout(stream=N) out` →
    // SPIR-V DecorationStream. Default 0 (single-stream behaviour).
    // writeGsXfbAndCheckDiscard uses this to route per-buffer per-
    // stream TF writes when the GS uses multi-stream emit.
    std::uint32_t stream = 0;
    // Order in OpEntryPoint's interface list. Used only while assigning
    // implicit locations for GS outputs without DecorationLocation.
    std::uint32_t implicitOrder = ~0u;
};

std::vector<OutputVaryingDesc> gatherOutputVaryings(const SpirvModule& mod) {
    std::vector<OutputVaryingDesc> out;
    std::unordered_map<std::uint32_t, std::uint32_t> interfaceOrder;
    interfaceOrder.reserve(mod.entryInterface.size());
    for (std::size_t i = 0; i < mod.entryInterface.size(); ++i) {
        interfaceOrder.emplace(mod.entryInterface[i],
                               static_cast<std::uint32_t>(i));
    }
    // Implicit-location varyings (no explicit `layout(location=N)` in
    // the GLSL) carry no DecorationLocation from glslang. GL 4.6 §4.4.2
    // says the linker assigns them sequentially starting from 0; we
    // mirror that here by collecting them separately and auto-numbering
    // after the explicitly-located ones settle. Use OpEntryPoint's
    // interface order when present so the GS-emul synthetic VS matches
    // SPIRV-Cross's fragment-stage `[[user(locnN)]]` assignment for
    // bare varyings such as `out vec2 uv; flat out int layer_id;`.
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
        if (auto ordIt = interfaceOrder.find(varId);
            ordIt != interfaceOrder.end()) {
            d.implicitOrder = ordIt->second;
        } else {
            d.implicitOrder = varId;
        }
        // Sprint 8 #9-C (CKPT96) — capture DecorationStream on the
        // OpVariable. glslang emits this for `layout(stream=N) out`
        // qualifiers; default 0 means stream 0.
        if (dIt != mod.decorations.end() && dIt->second.hasStream) {
            d.stream = dIt->second.stream;
        }
        auto tIt = mod.types.find(info.typeId);
        if (tIt != mod.types.end()) {
            d.width = mod.scalarWidth(tIt->second.pointeeType);
            d.scalarByteSize = scalarByteSizeForType(mod, tIt->second.pointeeType);
            d.baseType = baseTypeForType(mod, tIt->second.pointeeType);
            appendStageSlotWidthsForType(mod, tIt->second.pointeeType, d.stageSlotWidths);
        }
        if (d.width == 0) continue;   // empty or unresolved — skip
        // If the type pointee is the gl_PerVertex output block
        // (struct with BuiltIn-decorated members), skip — our
        // gl_Position / gl_PointSize / gl_Clip/Cull handling owns
        // that. User interface blocks (e.g. `out Vertex { ivec4
        // vs_gs_out[N]; };`) are structs too but carry no BuiltIn
        // decorations — we want to flow their members through as
        // varyings. CTS `limits.max_input_components` declares a
        // 16-ivec4 user output block and was silently dropped by
        // the old unconditional struct-skip.
        if (tIt != mod.types.end()) {
            const auto pIt = mod.types.find(tIt->second.pointeeType);
            if (pIt != mod.types.end() && pIt->second.kind == TypeInfo::Kind::Struct) {
                const std::uint32_t pointeeId = tIt->second.pointeeType;
                auto mdIt = mod.memberDecorations.find(pointeeId);
                bool hasBuiltInMember = false;
                if (mdIt != mod.memberDecorations.end()) {
                    for (const auto& [midx, mdeco] : mdIt->second.perMember) {
                        if (mdeco.hasBuiltIn) { hasBuiltInMember = true; break; }
                    }
                }
                if (hasBuiltInMember) continue;
                // Fall through: user interface block. Single-member
                // blocks synthesise one varying with the member name
                // + width. Multi-member blocks unroll each member
                // into its own varying with sequential locations —
                // CTS `nonarray_input.nonarray_input` uses a
                // 4-member `out VS_GS { vec4 v1; vec4 v2; vec4 v3;
                // vec4 v4; }` block that must expose all four
                // members to the GS input side.
                const auto& st = pIt->second;
                if (st.memberTypes.size() == 1) {
                    std::string mname;
                    auto mnIt = mod.memberNames.find(pointeeId);
                    if (mnIt != mod.memberNames.end()) {
                        auto nameIt = mnIt->second.find(0);
                        if (nameIt != mnIt->second.end()) mname = nameIt->second;
                    }
                    if (!mname.empty()) d.name = mname;
                    d.width = mod.scalarWidth(st.memberTypes[0]);
                    d.scalarByteSize = scalarByteSizeForType(mod, st.memberTypes[0]);
                    d.baseType = baseTypeForType(mod, st.memberTypes[0]);
                    d.stageSlotWidths.clear();
                    appendStageSlotWidthsForType(mod, st.memberTypes[0], d.stageSlotWidths);
                } else {
                    // Multi-member: emit one descriptor per member.
                    // Locations come from OpMemberDecorate Location
                    // when present; otherwise they are assigned
                    // sequentially starting from the block's
                    // DecorationLocation (if any) or the implicit
                    // auto-allocator. Base type and interpolation
                    // also come from per-member decorations.
                    auto mnIt = mod.memberNames.find(pointeeId);
                    auto mdIt = mod.memberDecorations.find(pointeeId);
                    const std::uint32_t blockBaseLoc =
                        (dIt != mod.decorations.end() && dIt->second.hasLocation)
                            ? dIt->second.location : 0u;
                    std::uint32_t nextMemberLoc = blockBaseLoc;
                    for (std::size_t m = 0; m < st.memberTypes.size(); ++m) {
                        OutputVaryingDesc md;
                        // Name — prefer per-member name, fallback to
                        // "<blockVarName>.<index>".
                        std::string mname;
                        if (mnIt != mod.memberNames.end()) {
                            auto nameIt = mnIt->second.find(static_cast<std::uint32_t>(m));
                            if (nameIt != mnIt->second.end()) mname = nameIt->second;
                        }
                        md.name = mname.empty()
                            ? (info.name + "." + std::to_string(m)) : mname;
                        md.width = mod.scalarWidth(st.memberTypes[m]);
                        md.scalarByteSize = scalarByteSizeForType(mod, st.memberTypes[m]);
                        md.baseType = baseTypeForType(mod, st.memberTypes[m]);
                        appendStageSlotWidthsForType(mod, st.memberTypes[m], md.stageSlotWidths);
                        if (md.width == 0) continue;
                        // Location: per-member Location decoration
                        // wins; otherwise take the block-level base
                        // and increment by width per member (vec4 =
                        // 1 location slot in GL).
                        bool haveLoc = false;
                        std::uint8_t memberInterp = 0;
                        if (mdIt != mod.memberDecorations.end()) {
                            auto mm = mdIt->second.perMember.find(static_cast<std::uint32_t>(m));
                            if (mm != mdIt->second.perMember.end()) {
                                if (mm->second.hasLocation) {
                                    md.location = mm->second.location;
                                    haveLoc = true;
                                }
                                if (mm->second.isFlat) memberInterp = 1;
                                else if (mm->second.isNoPerspective) memberInterp = 2;
                                else if (mm->second.isCentroid) memberInterp = 3;
                            }
                        }
                        md.interp = memberInterp;
                        if (!haveLoc) {
                            md.location = nextMemberLoc;
                        }
                        nextMemberLoc = md.location +
                            std::max<std::uint32_t>(
                                1, static_cast<std::uint32_t>(md.stageSlotWidths.size()));
                        out.push_back(std::move(md));
                    }
                    continue;   // processed — skip the single-desc path below
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
    // Resolve implicit locations in entry-interface order and assign
    // the lowest non-occupied location ≥ 0.
    if (!implicits.empty()) {
        std::sort(implicits.begin(), implicits.end(), [](const auto& a, const auto& b) {
            if (a.implicitOrder != b.implicitOrder) {
                return a.implicitOrder < b.implicitOrder;
            }
            return a.location < b.location;
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

void addUniformBuffersFromModule(const std::vector<std::uint32_t>& spirv,
                                 GLObjectStore& objects,
                                 const GLStateTracker& state,
                                 const GLProgramObject& program,
                                 Interpreter::UniformBufferMap& out) {
    if (spirv.empty()) return;
    SpirvModule mod;
    if (!mod.parse(spirv.data(), spirv.size())) return;

    // Interpreter access chains still carry the SPIR-V binding, even when
    // glUniformBlockBinding redirects the buffer slot at runtime.
    auto addBinding = [&](std::uint32_t mapBinding, std::uint32_t boundBinding) {
        if (out.count(mapBinding) != 0) return;
        GLIndexedBufferBinding bb =
            state.indexedBufferBinding(GL_UNIFORM_BUFFER, boundBinding);
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
        out[mapBinding] = region;
    };
    auto remapBinding = [&](std::uint32_t baseBinding,
                            const std::string& blockName,
                            const std::string& varName,
                            std::uint32_t inst,
                            bool isArray) -> std::uint32_t {
        std::array<std::string, 4> lookupNames{};
        std::array<bool, 4> lookupAddsIndex{};
        std::size_t count = 0;
        auto pushName = [&](const std::string& name, bool addIndex) {
            if (name.empty() || count >= lookupNames.size()) return;
            lookupNames[count] = name;
            lookupAddsIndex[count] = addIndex;
            ++count;
        };
        if (isArray) {
            pushName(blockName + "[" + std::to_string(inst) + "]", false);
            pushName(varName + "[" + std::to_string(inst) + "]", false);
        }
        pushName(blockName, isArray);
        pushName(varName, isArray);
        for (const auto& rb : program.resourceUniformBlocks) {
            if (rb.location < 0) continue;
            for (std::size_t i = 0; i < count; ++i) {
                if (rb.name == lookupNames[i]) {
                    return static_cast<std::uint32_t>(rb.location) +
                           (lookupAddsIndex[i] ? inst : 0u);
                }
            }
        }
        return baseBinding + (isArray ? inst : 0u);
    };

    for (const auto& [varId, info] : mod.variables) {
        if (info.storageClass != spv::StorageClassUniform) continue;
        auto tIt = mod.types.find(info.typeId);
        if (tIt == mod.types.end()) continue;
        auto pT = mod.types.find(tIt->second.pointeeType);
        if (pT == mod.types.end()) continue;

        auto vDec = mod.decorations.find(varId);
        const std::uint32_t baseBinding =
            (vDec != mod.decorations.end() && vDec->second.hasBinding)
                ? vDec->second.binding : 0u;

        if (pT->second.kind == TypeInfo::Kind::Struct) {
            auto blockDec = mod.decorations.find(tIt->second.pointeeType);
            if (blockDec != mod.decorations.end() && blockDec->second.isBlock &&
                !blockDec->second.isBufferBlock) {
                std::string blockName;
                auto nameIt = mod.names.find(tIt->second.pointeeType);
                if (nameIt != mod.names.end()) blockName = nameIt->second;
                if (blockName == "_DefaultUniforms") continue;
                addBinding(baseBinding,
                           remapBinding(baseBinding, blockName, info.name, 0, false));
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
            std::string blockName;
            auto nameIt = mod.names.find(pT->second.componentType);
            if (nameIt != mod.names.end()) blockName = nameIt->second;
            if (blockName == "_DefaultUniforms") continue;
            for (std::uint32_t inst = 0; inst < arrayLen; ++inst) {
                addBinding(baseBinding + inst,
                           remapBinding(baseBinding, blockName, info.name, inst, true));
            }
        }
    }
}

// Scan a SPIR-V module for OpStore instructions whose pointer
// ultimately reaches a gl_ClipDistance / gl_CullDistance BuiltIn
// (either a direct Output variable or a member of gl_PerVertex).
// Returns `{clipWritten, cullWritten}`.
//
// Why: glslang always emits the full `gl_PerVertex { …
// gl_ClipDistance[1]; gl_CullDistance[1]; }` block even when the
// GS never writes those arrays (it's the SPIR-V binding-point for
// the built-ins). Our `captureClipCull` blindly walks member
// decorations and ends up publishing a 1-element clip slot full
// of zeros. The synth VS then emits
// `out.gl_ClipDistance[0] = 0.0`, which Metal interprets as "on
// the clip plane" — and on some drivers floating-point noise
// flips it to negative and clips the whole triangle. That was
// the `geometry_shader.nonarray_input.nonarray_input` failure
// mode. The fix is to suppress the slot entirely unless the GS
// actually stores to clip / cull.
std::pair<bool,bool> scanClipCullWrites(const SpirvModule& mod) {
    bool writeClip = false;
    bool writeCull = false;
    // Collect gl_ClipDistance/gl_CullDistance Output variables +
    // members.
    std::unordered_set<std::uint32_t> clipVars;
    std::unordered_set<std::uint32_t> cullVars;
    for (const auto& [varId, info] : mod.variables) {
        if (info.storageClass != spv::StorageClassOutput) continue;
        auto dIt = mod.decorations.find(varId);
        if (dIt != mod.decorations.end() && dIt->second.hasBuiltIn) {
            if (dIt->second.builtIn == spv::BuiltInClipDistance) clipVars.insert(varId);
            if (dIt->second.builtIn == spv::BuiltInCullDistance) cullVars.insert(varId);
        }
    }
    // Map structId → list of (memberIdx, which builtin).
    std::unordered_map<std::uint32_t, std::vector<std::pair<std::uint32_t,std::uint32_t>>>
        structClipCullMembers;
    for (const auto& [structId, mdSet] : mod.memberDecorations) {
        for (const auto& [memberIdx, memberDeco] : mdSet.perMember) {
            if (memberDeco.hasBuiltIn &&
                (memberDeco.builtIn == spv::BuiltInClipDistance ||
                 memberDeco.builtIn == spv::BuiltInCullDistance)) {
                structClipCullMembers[structId].push_back({memberIdx, memberDeco.builtIn});
            }
        }
    }
    // Walk function body. Track access-chain result ids that
    // point into a clip/cull region so subsequent OpStores on
    // those ids count as a write.
    std::unordered_map<std::uint32_t, std::uint32_t> chainToBuiltIn;
    std::size_t pc = mod.funcBodyStart;
    while (pc < mod.funcBodyEnd) {
        const std::uint32_t inst = mod.words[pc];
        const std::uint16_t opcode = static_cast<std::uint16_t>(inst & 0xFFFF);
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0) break;
        if (opcode == spv::OpAccessChain && wc >= 4) {
            const std::uint32_t resultId = mod.words[pc + 2];
            const std::uint32_t base     = mod.words[pc + 3];
            if (clipVars.count(base) != 0) {
                chainToBuiltIn[resultId] = spv::BuiltInClipDistance;
            } else if (cullVars.count(base) != 0) {
                chainToBuiltIn[resultId] = spv::BuiltInCullDistance;
            } else {
                // base may be a struct variable; check its
                // pointee's member decorations.
                auto vIt = mod.variables.find(base);
                if (vIt != mod.variables.end() && wc >= 5) {
                    const std::uint32_t firstIdxId = mod.words[pc + 4];
                    auto cIt = mod.constants.find(firstIdxId);
                    if (cIt != mod.constants.end()) {
                        const std::int32_t idx = cIt->second.i[0];
                        auto tIt = mod.types.find(vIt->second.typeId);
                        if (tIt != mod.types.end()) {
                            auto sm = structClipCullMembers.find(tIt->second.pointeeType);
                            if (sm != structClipCullMembers.end()) {
                                for (const auto& [memberIdx, bi] : sm->second) {
                                    if (static_cast<std::uint32_t>(idx) == memberIdx) {
                                        chainToBuiltIn[resultId] = bi;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else if (opcode == spv::OpStore && wc >= 3) {
            const std::uint32_t ptr = mod.words[pc + 1];
            if (clipVars.count(ptr) != 0) writeClip = true;
            else if (cullVars.count(ptr) != 0) writeCull = true;
            else {
                auto ci = chainToBuiltIn.find(ptr);
                if (ci != chainToBuiltIn.end()) {
                    if (ci->second == spv::BuiltInClipDistance) writeClip = true;
                    else if (ci->second == spv::BuiltInCullDistance) writeCull = true;
                }
            }
        }
        pc += wc;
    }
    return {writeClip, writeCull};
}

// Augment a uniform map with UBO-block-array data by walking the
// SPIR-V module, finding top-level Uniform variables whose pointee
// is an Array of Block-decorated Struct (or a single Block-
// decorated Struct), looking up their base binding from the
// DescriptorSet/Binding decorations, and copying bytes from the
// GL_UNIFORM_BUFFER binding points `baseBinding + i` into a flat
// float buffer at stride `scalarWidth(struct)`.
// CTS `geometry_shader.limits.max_uniform_blocks` uses a single
// block-array `uni_block_array[14]` bound at binding 0..13; the
// GS reads `uni_block_array[i].entry` and sums all 14 ints.
void augmentUniformMapWithUBOBlocks(
    Interpreter::UniformValues& uniforms,
    const SpirvModule& mod,
    const GLStateTracker& state,
    GLObjectStore& objects)
{
    for (const auto& [varId, info] : mod.variables) {
        if (info.storageClass != spv::StorageClassUniform) continue;
        auto tIt = mod.types.find(info.typeId);
        if (tIt == mod.types.end()) continue;
        const std::uint32_t pointeeId = tIt->second.pointeeType;
        auto pIt = mod.types.find(pointeeId);
        if (pIt == mod.types.end()) continue;
        // Determine element struct + array count.
        std::uint32_t structTypeId = 0;
        std::uint32_t arrayCount = 1;
        if (pIt->second.kind == TypeInfo::Kind::Struct) {
            structTypeId = pointeeId;
            arrayCount = 1;
        } else if (pIt->second.kind == TypeInfo::Kind::Array) {
            auto aIt = mod.types.find(pIt->second.componentType);
            if (aIt == mod.types.end() || aIt->second.kind != TypeInfo::Kind::Struct) continue;
            structTypeId = pIt->second.componentType;
            auto cIt = mod.constants.find(pIt->second.arrayLengthConstId);
            if (cIt == mod.constants.end()) continue;
            arrayCount = static_cast<std::uint32_t>(cIt->second.i[0]);
        } else {
            continue;
        }
        // Struct must be Block-decorated to be a UBO (as opposed
        // to the default-uniform-block aggregate which our other
        // path already handles).
        auto dStructIt = mod.decorations.find(structTypeId);
        if (dStructIt == mod.decorations.end() || !dStructIt->second.isBlock) continue;
        // Binding base comes from the variable's DecorationBinding.
        auto dVarIt = mod.decorations.find(varId);
        if (dVarIt == mod.decorations.end() || !dVarIt->second.hasBinding) continue;
        const GLuint baseBinding = dVarIt->second.binding;
        const std::uint32_t perStructW = mod.scalarWidth(structTypeId);
        if (perStructW == 0) continue;
        // Build flat storage [arrayCount * perStructW] and fill
        // from each bound UBO buffer.
        std::vector<float> flat(static_cast<std::size_t>(arrayCount) * perStructW, 0.0f);
        for (std::uint32_t i = 0; i < arrayCount; ++i) {
            auto binding = state.indexedBufferBinding(GL_UNIFORM_BUFFER, baseBinding + i);
            if (binding.buffer == 0) continue;
            GLBufferObject* buf = objects.buffers().get(binding.buffer);
            if (buf == nullptr || buf->shadowBytes.empty()) continue;
            const std::size_t bufOffset = static_cast<std::size_t>(binding.offset);
            const std::size_t needBytes = perStructW * sizeof(float);
            if (bufOffset + needBytes > buf->shadowBytes.size()) continue;
            // Copy raw bytes — the interpreter's load path bit-casts
            // between float/int/uint so the scalar-kind-agnostic
            // memcpy preserves whatever pattern the GL test wrote.
            const std::size_t dstOff = static_cast<std::size_t>(i) * perStructW;
            std::memcpy(flat.data() + dstOff,
                        buf->shadowBytes.data() + bufOffset,
                        needBytes);
        }
        uniforms[info.name] = std::move(flat);
    }
}

std::size_t vertexAttribComponentByteSize(GLenum type) {
    switch (type) {
        case GL_BYTE:
        case GL_UNSIGNED_BYTE:
            return 1;
        case GL_SHORT:
        case GL_UNSIGNED_SHORT:
        case GL_HALF_FLOAT:
            return 2;
        case GL_INT:
        case GL_UNSIGNED_INT:
        case GL_FLOAT:
        case GL_FIXED:
        case GL_INT_2_10_10_10_REV:
        case GL_UNSIGNED_INT_2_10_10_10_REV:
        case GL_UNSIGNED_INT_10F_11F_11F_REV:
            return 4;
        case GL_DOUBLE:
            return 8;
        default:
            return 0;
    }
}

bool vertexAttribPackedType(GLenum type) {
    return type == GL_INT_2_10_10_10_REV ||
           type == GL_UNSIGNED_INT_2_10_10_10_REV ||
           type == GL_UNSIGNED_INT_10F_11F_11F_REV;
}

std::size_t vertexAttribByteSize(const GLVertexAttributeState& attr) {
    if (vertexAttribPackedType(attr.type)) {
        return 4;
    }
    const std::size_t componentBytes = vertexAttribComponentByteSize(attr.type);
    if (componentBytes == 0) return 0;
    const int componentCount = (attr.size == static_cast<GLint>(GL_BGRA))
        ? 4 : std::clamp(attr.size, 1, 4);
    return componentBytes * static_cast<std::size_t>(componentCount);
}

float halfBitsToFloat(std::uint16_t h) {
    const std::uint32_t sign = (static_cast<std::uint32_t>(h & 0x8000u)) << 16;
    int exp = static_cast<int>((h >> 10) & 0x1Fu);
    std::uint32_t mant = h & 0x03FFu;
    std::uint32_t bits = 0;
    if (exp == 0) {
        if (mant == 0) {
            bits = sign;
        } else {
            exp = 1;
            while ((mant & 0x0400u) == 0) {
                mant <<= 1;
                --exp;
            }
            mant &= 0x03FFu;
            bits = sign |
                   (static_cast<std::uint32_t>(exp + (127 - 15)) << 23) |
                   (mant << 13);
        }
    } else if (exp == 31) {
        bits = sign | 0x7F800000u | (mant << 13);
    } else {
        bits = sign |
               (static_cast<std::uint32_t>(exp + (127 - 15)) << 23) |
               (mant << 13);
    }
    float f = 0.0f;
    std::memcpy(&f, &bits, sizeof(f));
    return f;
}

std::int32_t readSignedVertexComponent(const std::uint8_t* src, GLenum type, int component) {
    switch (type) {
        case GL_BYTE: {
            std::int8_t v = 0;
            std::memcpy(&v, src + component, sizeof(v));
            return static_cast<std::int32_t>(v);
        }
        case GL_SHORT: {
            std::int16_t v = 0;
            std::memcpy(&v, src + component * 2, sizeof(v));
            return static_cast<std::int32_t>(v);
        }
        case GL_INT: {
            std::int32_t v = 0;
            std::memcpy(&v, src + component * 4, sizeof(v));
            return v;
        }
        default:
            return 0;
    }
}

std::uint32_t readUnsignedVertexComponent(const std::uint8_t* src, GLenum type, int component) {
    switch (type) {
        case GL_UNSIGNED_BYTE: {
            std::uint8_t v = 0;
            std::memcpy(&v, src + component, sizeof(v));
            return static_cast<std::uint32_t>(v);
        }
        case GL_UNSIGNED_SHORT: {
            std::uint16_t v = 0;
            std::memcpy(&v, src + component * 2, sizeof(v));
            return static_cast<std::uint32_t>(v);
        }
        case GL_UNSIGNED_INT: {
            std::uint32_t v = 0;
            std::memcpy(&v, src + component * 4, sizeof(v));
            return v;
        }
        default:
            return 0;
    }
}

float normalizeSignedVertexComponent(std::int32_t value, GLenum type) {
    double maxPositive = 1.0;
    switch (type) {
        case GL_BYTE:  maxPositive = 127.0; break;
        case GL_SHORT: maxPositive = 32767.0; break;
        case GL_INT:   maxPositive = 2147483647.0; break;
        default:       return static_cast<float>(value);
    }
    return static_cast<float>(std::max(-1.0, static_cast<double>(value) / maxPositive));
}

float normalizeUnsignedVertexComponent(std::uint32_t value, GLenum type) {
    double maxValue = 1.0;
    switch (type) {
        case GL_UNSIGNED_BYTE:  maxValue = 255.0; break;
        case GL_UNSIGNED_SHORT: maxValue = 65535.0; break;
        case GL_UNSIGNED_INT:   maxValue = 4294967295.0; break;
        default:                return static_cast<float>(value);
    }
    return static_cast<float>(static_cast<double>(value) / maxValue);
}

bool vertexAttribSignedIntegerType(GLenum type) {
    return type == GL_BYTE || type == GL_SHORT || type == GL_INT;
}

bool vertexAttribUnsignedIntegerType(GLenum type) {
    return type == GL_UNSIGNED_BYTE ||
           type == GL_UNSIGNED_SHORT ||
           type == GL_UNSIGNED_INT;
}

float readFloatVertexComponent(const std::uint8_t* src,
                               GLenum type,
                               GLboolean normalized,
                               int component) {
    switch (type) {
        case GL_FLOAT: {
            float v = 0.0f;
            std::memcpy(&v, src + component * 4, sizeof(v));
            return v;
        }
        case GL_HALF_FLOAT: {
            std::uint16_t bits = 0;
            std::memcpy(&bits, src + component * 2, sizeof(bits));
            return halfBitsToFloat(bits);
        }
        case GL_DOUBLE: {
            double v = 0.0;
            std::memcpy(&v, src + component * 8, sizeof(v));
            return static_cast<float>(v);
        }
        case GL_FIXED: {
            std::int32_t v = 0;
            std::memcpy(&v, src + component * 4, sizeof(v));
            return static_cast<float>(static_cast<double>(v) / 65536.0);
        }
        default:
            break;
    }
    if (vertexAttribSignedIntegerType(type)) {
        const std::int32_t v = readSignedVertexComponent(src, type, component);
        return normalized == GL_TRUE
            ? normalizeSignedVertexComponent(v, type)
            : static_cast<float>(v);
    }
    if (vertexAttribUnsignedIntegerType(type)) {
        const std::uint32_t v = readUnsignedVertexComponent(src, type, component);
        return normalized == GL_TRUE
            ? normalizeUnsignedVertexComponent(v, type)
            : static_cast<float>(v);
    }
    return 0.0f;
}

float readFloatVertexComponent(const std::uint8_t* src,
                               const GLVertexAttributeState& attr,
                               int component) {
    return readFloatVertexComponent(src, attr.type, attr.normalized, component);
}

// Extract a single vertex's attribute value from a VAO + VBO shadow.
// `attrIdx` is the GLVertexAttributeState array index (== Location
// for the default non-separated-format path). `vertexIdx` is absolute
// (first + relativeVertex).
Value readVertexAttribFromVAO(
    const GLVertexArrayObject& vao,
    GLObjectStore& objects,
    std::size_t attrIdx,
    std::size_t vertexIdx,
    std::int32_t instanceIdx)
{
    Value v;
    if (attrIdx >= vao.attributes.size()) return v;
    const auto& attr = vao.attributes[attrIdx];
    if (!attr.enabled) {
        v.kind = Value::Kind::Float4;
        for (int k = 0; k < 4; ++k) {
            v.f[k] = static_cast<float>(attr.immediateDouble[k]);
        }
        return v;
    }
    // Sprint 8 SCOUT-W (f) regression-fix (CKPT72): honour
    // glVertexArrayAttribBinding (GL 4.3 §10.3 separated-format
    // routing). The attribute's bindingIndex selects which binding
    // point the buffer + offset + stride come from. For attributes
    // set via the LEGACY glVertexAttrib*Pointer path, the bindingPoint
    // is implicitly populated at index == attrIndex with the same
    // buffer/offset/stride (see GLContext::vertexAttribIPointer
    // around line 10251 — bindingPoints[index] mirrors the attr
    // fields). After a subsequent glVertexArrayAttribBinding swap,
    // `attribute.bindingIndex` changes but `attribute.buffer/pointer/
    // stride` stay at the original values — reading from those
    // legacy fields would IGNORE the binding swap. Use the
    // bindingPoint-keyed values when valid, falling back to legacy
    // attribute fields when bindingPoint is unset (defensive).
    //
    // CTS `direct_state_access.vertex_arrays_attribute_binding`
    // exercises exactly this: vertexArrayAttribBinding swaps attribs
    // 0↔1, expecting result[0]=array[1] and result[1]=array[0].
    // Pre-CKPT72 the VS-only-TF interpreter (engaged for this test
    // post-CKPT68's VS-only-TF gate relaxation) read from the legacy
    // attr fields and produced wrong results. Post-CKPT72: honour
    // bindingPoint[bindingIndex] for the buffer source.
    GLuint bufferName = attr.buffer;
    const std::size_t attrBytes = vertexAttribByteSize(attr);
    if (attrBytes == 0) return v;
    const int componentCount = (attr.size == static_cast<GLint>(GL_BGRA))
        ? 4 : std::clamp(attr.size, 1, 4);
    std::size_t baseOffset = attr.pointer;
    std::size_t stride = attr.stride > 0 ? static_cast<std::size_t>(attr.stride)
                                         : attrBytes;
    GLuint divisor = attr.divisor;
    if (attr.bindingIndex < vao.bindingPoints.size()) {
        const auto& bp = vao.bindingPoints[attr.bindingIndex];
        divisor = bp.divisor;
        if (bp.buffer != 0) {
            bufferName = bp.buffer;
            baseOffset = static_cast<std::size_t>(bp.offset) +
                         static_cast<std::size_t>(attr.relativeOffset);
            if (bp.stride > 0) {
                stride = static_cast<std::size_t>(bp.stride);
            }
        }
    }
    std::size_t relativeOffset = 0;
    if (bufferName == 0) return v;
    GLBufferObject* buf = objects.buffers().get(bufferName);
    if (buf == nullptr || buf->shadowBytes.empty()) return v;
    const std::size_t fetchIdx = divisor > 0
        ? (static_cast<std::size_t>(std::max<std::int32_t>(instanceIdx, 0)) /
           static_cast<std::size_t>(divisor))
        : vertexIdx;
    const std::size_t byteOffset = baseOffset + relativeOffset + stride * fetchIdx;
    if (byteOffset + attrBytes > buf->shadowBytes.size()) {
        return v;
    }
    const std::uint8_t* src = buf->shadowBytes.data() + byteOffset;
    // GL 4.6 §10.2 (Vertex Arrays) table 10.8: when a vertex
    // attribute declared as vec4 in the shader receives a
    // narrower stream, missing components are filled with
    // (0, 0, 0, 1). We always return a 4-component Value so the
    // VS-init path can copy however many components the SPIR-V
    // variable actually declares.
    const bool isUInt = attr.integer && vertexAttribUnsignedIntegerType(attr.type);
    const bool isInt  = attr.integer && !isUInt;
    v.kind = isInt  ? Value::Kind::Int4
           : isUInt ? Value::Kind::UInt4
                    : Value::Kind::Float4;
    // Init w component to spec default of 1 / unit, then overwrite
    // from source. x/y/z init to 0 (spec default).
    if (isInt || isUInt) {
        v.i[0] = v.i[1] = v.i[2] = 0;
        v.i[3] = 1;
        for (int k = 0; k < componentCount; ++k) {
            if (isUInt) {
                const std::uint32_t u = readUnsignedVertexComponent(src, attr.type, k);
                v.i[k] = static_cast<std::int32_t>(u);
            } else if (vertexAttribSignedIntegerType(attr.type)) {
                v.i[k] = readSignedVertexComponent(src, attr.type, k);
            }
        }
    } else {
        v.f[0] = v.f[1] = v.f[2] = 0.0f;
        v.f[3] = 1.0f;
        for (int k = 0; k < componentCount; ++k) {
            v.f[k] = readFloatVertexComponent(src, attr, k);
        }
    }
    return v;
}

struct VsAttribFetchSource {
    // Draw-local immutable VAO/VBO fetch snapshot. The VS-only TF
    // chunk workers read this concurrently, so keep scalar attribute
    // state here instead of retaining pointers into GLVertexArrayObject.
    std::uint32_t location = 0;
    bool enabled = false;
    Value immediate;
    const std::uint8_t* data = nullptr;
    std::size_t dataSize = 0;
    std::size_t attrBytes = 0;
    std::size_t baseOffset = 0;
    std::size_t stride = 0;
    GLuint divisor = 0;
    int componentCount = 4;
    GLenum type = GL_FLOAT;
    GLboolean normalized = GL_FALSE;
    bool isInt = false;
    bool isUInt = false;
};

std::vector<VsAttribFetchSource> buildVsAttribFetchSources(
    const GLVertexArrayObject& vao,
    GLObjectStore& objects)
{
    std::vector<VsAttribFetchSource> sources;
    sources.reserve(vao.attributes.size());
    for (std::size_t ai = 0; ai < vao.attributes.size(); ++ai) {
        const auto& attr = vao.attributes[ai];
        VsAttribFetchSource src;
        src.location = static_cast<std::uint32_t>(ai);
        src.enabled = attr.enabled;
        src.type = attr.type;
        src.normalized = attr.normalized;
        if (!attr.enabled) {
            src.immediate.kind = Value::Kind::Float4;
            for (int k = 0; k < 4; ++k) {
                src.immediate.f[k] = static_cast<float>(attr.immediateDouble[k]);
            }
            sources.push_back(src);
            continue;
        }

        GLuint bufferName = attr.buffer;
        src.attrBytes = vertexAttribByteSize(attr);
        if (src.attrBytes == 0) continue;
        src.componentCount = (attr.size == static_cast<GLint>(GL_BGRA))
            ? 4 : std::clamp(attr.size, 1, 4);
        src.baseOffset = attr.pointer;
        src.stride = attr.stride > 0 ? static_cast<std::size_t>(attr.stride)
                                     : src.attrBytes;
        src.divisor = attr.divisor;
        if (attr.bindingIndex < vao.bindingPoints.size()) {
            const auto& bp = vao.bindingPoints[attr.bindingIndex];
            src.divisor = bp.divisor;
            if (bp.buffer != 0) {
                bufferName = bp.buffer;
                src.baseOffset = static_cast<std::size_t>(bp.offset) +
                                 static_cast<std::size_t>(attr.relativeOffset);
                if (bp.stride > 0) {
                    src.stride = static_cast<std::size_t>(bp.stride);
                }
            }
        }
        if (bufferName == 0) continue;
        GLBufferObject* buf = objects.buffers().get(bufferName);
        if (buf == nullptr || buf->shadowBytes.empty()) continue;
        src.data = buf->shadowBytes.data();
        src.dataSize = buf->shadowBytes.size();
        src.isUInt = attr.integer && vertexAttribUnsignedIntegerType(attr.type);
        src.isInt = attr.integer && !src.isUInt;
        sources.push_back(src);
    }
    return sources;
}

Value readVertexAttribFromSource(const VsAttribFetchSource& src,
                                 std::size_t vertexIdx,
                                 std::int32_t instanceIdx)
{
    if (!src.enabled) return src.immediate;

    Value v;
    if (src.data == nullptr || src.attrBytes == 0) return v;
    const std::size_t fetchIdx = src.divisor > 0
        ? (static_cast<std::size_t>(std::max<std::int32_t>(instanceIdx, 0)) /
           static_cast<std::size_t>(src.divisor))
        : vertexIdx;
    const std::size_t byteOffset = src.baseOffset + src.stride * fetchIdx;
    if (byteOffset > src.dataSize || src.attrBytes > src.dataSize - byteOffset) {
        return v;
    }

    const std::uint8_t* raw = src.data + byteOffset;
    v.kind = src.isInt ? Value::Kind::Int4
           : src.isUInt ? Value::Kind::UInt4
                        : Value::Kind::Float4;
    if (src.isInt || src.isUInt) {
        v.i[0] = v.i[1] = v.i[2] = 0;
        v.i[3] = 1;
        for (int k = 0; k < src.componentCount; ++k) {
            if (src.isUInt) {
                const std::uint32_t u = readUnsignedVertexComponent(raw, src.type, k);
                v.i[k] = static_cast<std::int32_t>(u);
            } else if (vertexAttribSignedIntegerType(src.type)) {
                v.i[k] = readSignedVertexComponent(raw, src.type, k);
            }
        }
    } else {
        v.f[0] = v.f[1] = v.f[2] = 0.0f;
        v.f[3] = 1.0f;
        for (int k = 0; k < src.componentCount; ++k) {
            v.f[k] = readFloatVertexComponent(raw, src.type, src.normalized, k);
        }
    }
    return v;
}

std::unordered_map<std::string, std::uint32_t> buildVsInputLocationOverrides(
    const GLProgramObject& program)
{
    std::unordered_map<std::string, std::uint32_t> overrides;
    for (const auto& vi : program.vertexReflection.vertexInputs) {
        std::string base = vi.name;
        const std::size_t bracket = base.find('[');
        if (bracket != std::string::npos) base.resize(bracket);
        auto it = overrides.find(base);
        if (it == overrides.end() || it->second > vi.location) {
            overrides[base] = vi.location;
        }
    }
    for (const auto& attrib : program.attributes) {
        if (attrib.location < 0 || attrib.name.empty()) continue;
        std::string base = attrib.name;
        const std::size_t bracket = base.find('[');
        if (bracket != std::string::npos) base.resize(bracket);
        overrides[base] = static_cast<std::uint32_t>(attrib.location);
    }
    return overrides;
}
}  // namespace

namespace {

struct VsOnlyTfTimingCounters {
    std::atomic<std::uint64_t> draws{0};
    std::atomic<std::uint64_t> vertices{0};
    std::atomic<std::uint64_t> failures{0};
    std::atomic<std::uint64_t> parseNs{0};
    std::atomic<std::uint64_t> reflectionNs{0};
    std::atomic<std::uint64_t> setupNs{0};
    std::atomic<std::uint64_t> attribFetchNs{0};
    std::atomic<std::uint64_t> executeVsNs{0};
    std::atomic<std::uint64_t> packOutputNs{0};
    std::atomic<std::uint64_t> tfWriteNs{0};
};

VsOnlyTfTimingCounters& vsOnlyTfTimingCounters() {
    static VsOnlyTfTimingCounters counters;
    return counters;
}

std::uint64_t loadTimingCounter(const std::atomic<std::uint64_t>& value) {
    return value.load(std::memory_order_relaxed);
}

void addTimingNs(std::atomic<std::uint64_t>& dst, std::uint64_t ns) {
    dst.fetch_add(ns, std::memory_order_relaxed);
}

// Env-gated Sprint 20 Phase 3a tuning. The threshold keeps tiny VS-only
// TF draws, especially count=1 builtin probes, on the serial path while
// still chunking vertex_attrib_64bit.limits_test-sized draws.
constexpr std::size_t kVsOnlyTfChunkVertexThreshold = 512;
constexpr std::size_t kVsOnlyTfMaxWorkerThreads = 8;  // M1 Max P-core cap.

std::size_t requestedVsOnlyTfChunks() {
    static const std::size_t chunks = [] {
        const char* raw = std::getenv("APPGL_DF64_VSTF_CHUNKS");
        if (raw == nullptr || *raw == '\0') return std::size_t{1};

        char* end = nullptr;
        const long parsed = std::strtol(raw, &end, 10);
        if (end == raw || parsed <= 1) return std::size_t{1};
        return static_cast<std::size_t>(std::min<long>(parsed, 64));
    }();
    return chunks;
}

std::size_t effectiveVsOnlyTfChunks(std::size_t totalVertices) {
    const std::size_t requested = requestedVsOnlyTfChunks();
    if (requested <= 1 || totalVertices <= kVsOnlyTfChunkVertexThreshold) {
        return 1;
    }

    const unsigned hw = std::thread::hardware_concurrency();
    const std::size_t hardwareCap = hw == 0
        ? kVsOnlyTfMaxWorkerThreads
        : std::min<std::size_t>(static_cast<std::size_t>(hw),
                                kVsOnlyTfMaxWorkerThreads);
    std::size_t chunks = std::min(requested, hardwareCap);
    chunks = std::min(chunks, totalVertices);
    return std::max<std::size_t>(1, chunks);
}

void printVsOnlyTfTimingSummary() {
    auto& c = vsOnlyTfTimingCounters();
    const std::uint64_t draws = loadTimingCounter(c.draws);
    if (draws == 0) return;
    std::fprintf(stderr,
        "[APPGL_DF64_VSTF_TIMING] summary "
        "draws=%llu vertices=%llu failures=%llu "
        "parse_ns=%llu reflection_ns=%llu setup_ns=%llu "
        "attrib_fetch_ns=%llu execute_vs_ns=%llu pack_output_ns=%llu "
        "tf_write_ns=%llu\n",
        static_cast<unsigned long long>(draws),
        static_cast<unsigned long long>(loadTimingCounter(c.vertices)),
        static_cast<unsigned long long>(loadTimingCounter(c.failures)),
        static_cast<unsigned long long>(loadTimingCounter(c.parseNs)),
        static_cast<unsigned long long>(loadTimingCounter(c.reflectionNs)),
        static_cast<unsigned long long>(loadTimingCounter(c.setupNs)),
        static_cast<unsigned long long>(loadTimingCounter(c.attribFetchNs)),
        static_cast<unsigned long long>(loadTimingCounter(c.executeVsNs)),
        static_cast<unsigned long long>(loadTimingCounter(c.packOutputNs)),
        static_cast<unsigned long long>(loadTimingCounter(c.tfWriteNs)));
}

}  // namespace

bool vsOnlyTfTimingEnabled() {
    static const bool enabled = [] {
        const bool on = std::getenv("APPGL_DF64_VSTF_TIMING") != nullptr;
        if (on) std::atexit(printVsOnlyTfTimingSummary);
        return on;
    }();
    return enabled;
}

std::uint64_t vsOnlyTfTimingNowNs() {
    const auto now = std::chrono::steady_clock::now().time_since_epoch();
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(now).count());
}

void recordVsOnlyTfWriteDurationNs(std::uint64_t ns) {
    if (!vsOnlyTfTimingEnabled()) return;
    addTimingNs(vsOnlyTfTimingCounters().tfWriteNs, ns);
}

// Sprint 17 Day 7+ Bank-Group-H Path B Component A1 — public helper
// for link-time VS gl_CullDistance detection. Wraps `scanClipCullWrites`
// (in the anon namespace above) behind a stable signature so callers
// (GLContext.mm linkProgram) don't need access to the internal
// SpirvModule type.
bool vsSpirvWritesCullDistance(const std::uint32_t* spirv, std::size_t wordCount) {
    if (spirv == nullptr || wordCount < 5) return false;
    SpirvModule mod;
    if (!mod.parse(spirv, wordCount)) return false;
    return scanClipCullWrites(mod).second;
}

// Sprint 6 P1 sub-task 3 day 3 (CKPT43): expose sampler-variable
// discovery so platform .mm callers can build SampledTextureMaps
// without re-parsing SPIR-V. Walks the module's variables, picks
// out UniformConstant-classed OpTypeImage / OpTypeSampledImage
// (or OpTypeArray thereof), and returns name + arrayCount.
std::vector<SamplerVarInfo> collectSamplerVarsFromSpirv(
    const std::uint32_t* spirv, std::size_t wordCount)
{
    std::vector<SamplerVarInfo> result;
    if (spirv == nullptr || wordCount < 5) return result;
    SpirvModule mod;
    if (!mod.parse(spirv, wordCount)) return result;
    for (const auto& [varId, vinfo] : mod.variables) {
        if (vinfo.storageClass != spv::StorageClassUniformConstant) continue;
        // Type chain: variable's typeId → OpTypePointer pointee → either
        // OpTypeArray (with element type that's image/sampledImage) OR
        // OpTypeImage / OpTypeSampledImage directly.
        auto ptrIt = mod.types.find(vinfo.typeId);
        if (ptrIt == mod.types.end()) continue;
        std::uint32_t pointee = ptrIt->second.pointeeType;
        std::uint32_t arrayCount = 1;
        auto innerIt = mod.types.find(pointee);
        if (innerIt != mod.types.end() &&
            innerIt->second.kind == TypeInfo::Kind::Array) {
            // Array length stored on a constant referenced by
            // arrayLengthConstId.
            auto lenIt = mod.constants.find(innerIt->second.arrayLengthConstId);
            if (lenIt != mod.constants.end()) {
                arrayCount = static_cast<std::uint32_t>(lenIt->second.i[0]);
            }
            // For sampler arrays we don't need to drill further into
            // the element type — the existence of UniformConstant +
            // Array is enough. (Non-sampler UniformConstant arrays are
            // rare and detection by the runtime caller — name match in
            // reflection.sampledTextures — handles disambiguation.)
        }
        // Heuristic-light filter: rely on the runtime caller to
        // confirm via name match against reflection.sampledTextures.
        // We just hand back every UniformConstant variable's id +
        // name + array count; the caller picks samplers from the set.
        SamplerVarInfo info;
        info.varId = varId;
        info.name = vinfo.name;
        info.arrayCount = arrayCount;
        result.push_back(std::move(info));
    }
    return result;
}

// Sprint 7 Phase 2 #7 (CKPT59): public wrapper around the existing
// `gatherOutputVaryings` (file-private). Walks a VS SPIR-V module
// and returns each Output-class user varying's name + scalar width
// + location + base type — the caller (drawArrays VS-only TF capture
// path in GLContext.mm) needs this to size the per-vertex packed
// buffer + match TF varying names against captured outputs.
std::vector<VsOutputVaryingInfo> discoverVsOutputVaryings(
    const std::uint32_t* spirv, std::size_t wordCount)
{
    std::vector<VsOutputVaryingInfo> result;
    if (spirv == nullptr || wordCount < 5) return result;
    SpirvModule mod;
    if (!mod.parse(spirv, wordCount)) return result;
    const std::vector<OutputVaryingDesc> raw = gatherOutputVaryings(mod);
    result.reserve(raw.size());
    for (const auto& v : raw) {
        VsOutputVaryingInfo info;
        info.name = v.name;
        info.width = v.width;
        info.location = v.location;
        info.baseType = v.baseType;
        info.scalarByteSize = v.scalarByteSize;
        result.push_back(std::move(info));
    }
    return result;
}

// Sprint 7 Phase 2 #7 (CKPT59): VS-only TF emulation. Runs the VS
// interpreter once per draw vertex and produces an EmulatedDraw
// shaped exactly like the GS-emul / tess-emul output (per-vertex
// flat float buffer = position[4] + concatenated varyings). The
// caller (drawArrays) feeds the result to `writeGsXfbAndCheckDiscard`
// to land per-vertex bytes in the bound TF buffers + bump primitive
// counters.
//
// Required for separable VS-only programs joined to a program-pipeline
// whose GS is detached (CTS `program_pipeline_vs_gs_capture` pass 2)
// AND for any other VS-only TF surface that doesn't route through GS
// or tess emulation.
EmulatedDraw emulateVsOnlyDrawForTf(
    GLProgramObject& program,
    const GLVertexArrayObject& vao,
    GLObjectStore& objects,
    const GLStateTracker& state,
    GLenum drawMode,
    GLsizei count,
    GLint first,
    GLsizei instanceCount,
    GLuint baseInstance,
    const std::uint32_t* elementIndices)
{
    EmulatedDraw d;
    d.topology = drawMode;
    d.ok = false;
    const bool timing = vsOnlyTfTimingEnabled();
    auto& timingCounters = vsOnlyTfTimingCounters();
    auto markFailure = [&]() {
        if (timing) {
            timingCounters.failures.fetch_add(1, std::memory_order_relaxed);
        }
    };
    if (timing) {
        timingCounters.draws.fetch_add(1, std::memory_order_relaxed);
    }
    if (program.vertexSpirv.empty()) {
        markFailure();
        d.diagnostic = "emulateVsOnlyDrawForTf: empty VS SPIR-V";
        return d;
    }
    if (program.transformFeedbackVaryingNames.empty()) {
        markFailure();
        d.diagnostic = "emulateVsOnlyDrawForTf: no TF varyings recorded";
        return d;
    }
    const std::uint64_t parseStart = timing ? vsOnlyTfTimingNowNs() : 0;
    SpirvModule vsMod;
    if (!vsMod.parse(program.vertexSpirv.data(), program.vertexSpirv.size())) {
        if (timing) {
            addTimingNs(timingCounters.parseNs, vsOnlyTfTimingNowNs() - parseStart);
        }
        markFailure();
        d.diagnostic = "emulateVsOnlyDrawForTf: SpirvModule parse: " + vsMod.parseError;
        return d;
    }
    if (timing) {
        addTimingNs(timingCounters.parseNs, vsOnlyTfTimingNowNs() - parseStart);
    }
    const std::uint64_t reflectionStart = timing ? vsOnlyTfTimingNowNs() : 0;
    // Walk VS SPIR-V outputs once, then filter to TF-captured ones.
    // Order matches `program.transformFeedbackVaryingNames` so the
    // TF capture helper's offset arithmetic lands on the right bytes.
    std::vector<VsOutputVaryingInfo> allOutputs;
    const std::vector<OutputVaryingDesc> rawOutputs = gatherOutputVaryings(vsMod);
    allOutputs.reserve(rawOutputs.size());
    for (const auto& v : rawOutputs) {
        VsOutputVaryingInfo info;
        info.name = v.name;
        info.width = v.width;
        info.location = v.location;
        info.baseType = v.baseType;
        info.scalarByteSize = v.scalarByteSize;
        allOutputs.push_back(std::move(info));
    }
    std::vector<VsOutputVaryingInfo> captured;
    for (const auto& tfName : program.transformFeedbackVaryingNames) {
        if (tfName == "gl_Position") continue;   // handled by position[4]
        for (const auto& v : allOutputs) {
            if (v.name == tfName) {
                captured.push_back(v);
                break;
            }
        }
    }
    // Sum total varying widths to size the per-vertex stride. Even
    // captured.empty() is valid (e.g. only gl_Position) — in that case
    // the per-vertex stride is just position[4].
    std::uint32_t totalVaryingWidth = 0;
    for (const auto& v : captured) totalVaryingWidth += v.width;
    const std::size_t fpv = static_cast<std::size_t>(4) + totalVaryingWidth;

    // Populate ed metadata so writeGsXfbAndCheckDiscard finds each TF
    // varying at the right offset within fpv.
    d.varyingNames.reserve(captured.size());
    d.varyingWidths.reserve(captured.size());
    d.varyingLocations.reserve(captured.size());
    d.varyingInterp.reserve(captured.size());
    d.varyingBaseType.reserve(captured.size());
    d.varyingScalarByteSize.reserve(captured.size());
    for (const auto& v : captured) {
        d.varyingNames.push_back(v.name);
        d.varyingWidths.push_back(v.width);
        d.varyingLocations.push_back(v.location);
        d.varyingInterp.push_back(0);          // smooth (default; TF doesn't care)
        d.varyingBaseType.push_back(v.baseType);
        d.varyingScalarByteSize.push_back(v.scalarByteSize);
    }
    d.floatsPerVertex = fpv;
    if (timing) {
        addTimingNs(timingCounters.reflectionNs,
                    vsOnlyTfTimingNowNs() - reflectionStart);
    }

    const std::uint64_t setupStart = timing ? vsOnlyTfTimingNowNs() : 0;
    const GLsizei effectiveInstances = std::max<GLsizei>(1, instanceCount);
    d.vertexCount = static_cast<std::size_t>(count) *
                    static_cast<std::size_t>(effectiveInstances);
    d.expandedVertexData.assign(d.vertexCount * fpv, 0.0f);
    d.expandedVertexDoubleData.assign(d.vertexCount * fpv, 0.0);
    if (timing) {
        timingCounters.vertices.fetch_add(
            static_cast<std::uint64_t>(d.vertexCount),
            std::memory_order_relaxed);
    }

    // Sprint 18 420pack qualifier_order_uniform: include ordinary
    // UBO roots as well as UBO arrays now that broader bool-op
    // support lets more tess/GS shaders take the CPU interpreter path.
    Interpreter::UniformBufferMap vsUboMap;
    addUniformBuffersFromModule(program.vertexSpirv, objects, state, program, vsUboMap);
    const Interpreter::UniformBufferMap* vsUboMapPtr =
        vsUboMap.empty() ? nullptr : &vsUboMap;

    Interpreter::UniformValues uniforms = buildUniformMap(program);
    std::unordered_map<std::string, std::uint32_t> vsInputLocOverrides =
        buildVsInputLocationOverrides(program);
    const std::vector<VsAttribFetchSource> vsAttribSources =
        buildVsAttribFetchSources(vao, objects);
    std::vector<std::string> capturedNames;
    std::vector<std::uint32_t> capturedWidths;
    capturedNames.reserve(captured.size());
    capturedWidths.reserve(captured.size());
    for (const auto& v : captured) {
        capturedNames.push_back(v.name);
        capturedWidths.push_back(v.width);
    }
    const std::size_t chunkCount = effectiveVsOnlyTfChunks(d.vertexCount);
    auto configureVsInterpreter = [&](Interpreter& interp) {
        interp.setUniforms(&uniforms);
        if (!vsInputLocOverrides.empty()) {
            interp.setVsInputLocationOverrides(&vsInputLocOverrides);
        }
        if (vsUboMapPtr != nullptr) {
            interp.setUniformBuffers(vsUboMapPtr);
        }
    };

    // Sprint20 residual: preserve the pre-existing baseInstance handling
    // in this VS-only TF path. gl_InstanceID remains instanceIdx, and
    // instanced VBO fetch is not adjusted here by Phase 3a.
    (void)baseInstance;

    auto runVertexRange = [&](std::size_t beginVertex,
                              std::size_t endVertex,
                              Interpreter& vsInterp,
                              const std::atomic<bool>* stopFlag,
                              std::string& outDiagnostic) -> bool {
        // Per-vertex VS interpretation. The immutable SPIR-V parse,
        // reflection-derived location overrides, uniform maps, and VAO
        // fetch sources are draw-level setup; each worker owns its
        // Interpreter, attribute scratch map, diagnostic, and output slice.
        EmulatedVertex outVertex;
        Interpreter::VertexAttribs vsAttribs;
        const std::size_t countSize = static_cast<std::size_t>(count);
        for (std::size_t ordinal = beginVertex; ordinal < endVertex; ++ordinal) {
            if (stopFlag != nullptr &&
                stopFlag->load(std::memory_order_relaxed)) {
                return true;
            }
            const std::size_t instanceOrdinal = ordinal / countSize;
            const std::size_t vertexOrdinal = ordinal - instanceOrdinal * countSize;
            const std::int32_t glInstanceID =
                static_cast<std::int32_t>(instanceOrdinal);
            // Sprint 7 #9 (CKPT65) — drawElements indexes via
            // elementIndices[vi]; drawArrays uses sequential first+vi.
            const std::size_t vboSlot = (elementIndices != nullptr)
                ? static_cast<std::size_t>(elementIndices[vertexOrdinal])
                : static_cast<std::size_t>(first + static_cast<GLint>(vertexOrdinal));
            const std::uint64_t attribStart =
                timing ? vsOnlyTfTimingNowNs() : 0;
            outVertex = EmulatedVertex{};
            outVertex.position[0] = outVertex.position[1] = outVertex.position[2] = 0.0f;
            outVertex.position[3] = 1.0f;
            vsAttribs.clear();
            for (const auto& src : vsAttribSources) {
                Value v = readVertexAttribFromSource(src, vboSlot, glInstanceID);
                if (v.kind != Value::Kind::Invalid) {
                    vsAttribs[src.location] = v;
                }
            }
            vsInterp.setVsInputs(&vsAttribs,
                                 static_cast<std::int32_t>(vboSlot),
                                 glInstanceID);
            if (timing) {
                addTimingNs(timingCounters.attribFetchNs,
                            vsOnlyTfTimingNowNs() - attribStart);
            }
            const std::uint64_t executeStart =
                timing ? vsOnlyTfTimingNowNs() : 0;
            const bool ok = vsInterp.executeVs(outVertex);
            if (timing) {
                addTimingNs(timingCounters.executeVsNs,
                            vsOnlyTfTimingNowNs() - executeStart);
            }
            if (!ok) {
                markFailure();
                outDiagnostic = vsInterp.diagnostic();
                return false;
            }
            const std::uint64_t packStart =
                timing ? vsOnlyTfTimingNowNs() : 0;
            float* dst = d.expandedVertexData.data() + ordinal * fpv;
            double* ddst = d.expandedVertexDoubleData.data() + ordinal * fpv;
            for (int k = 0; k < 4; ++k) {
                dst[k] = outVertex.position[k];
                ddst[k] = static_cast<double>(outVertex.position[k]);
            }
            std::size_t cursor = 4;
            for (std::size_t k = 0; k < outVertex.varyings.size() && cursor < fpv; ++k) {
                dst[cursor++] = outVertex.varyings[k];
            }
            cursor = 4;
            for (std::size_t k = 0; k < outVertex.varyings.size() && cursor < fpv; ++k) {
                ddst[cursor] = (k < outVertex.doubleVaryings.size())
                    ? outVertex.doubleVaryings[k]
                    : static_cast<double>(outVertex.varyings[k]);
                ++cursor;
            }
            if (timing) {
                addTimingNs(timingCounters.packOutputNs,
                            vsOnlyTfTimingNowNs() - packStart);
            }
        }
        return true;
    };

    std::optional<Interpreter> serialVsInterp;
    if (chunkCount == 1) {
        serialVsInterp.emplace(vsMod, Interpreter::Stage::Vertex,
                               capturedNames, capturedWidths);
        configureVsInterpreter(*serialVsInterp);
    }
    if (timing) {
        addTimingNs(timingCounters.setupNs,
                    vsOnlyTfTimingNowNs() - setupStart);
    }

    std::string vsDiag;
    if (chunkCount == 1) {
        if (!runVertexRange(0, d.vertexCount, *serialVsInterp, nullptr, vsDiag)) {
            d.ok = false;
            d.diagnostic = "VS-only-TF: " + vsDiag;
            return d;
        }
    } else {
        std::atomic<bool> failed{false};
        std::mutex diagnosticMutex;
        std::string firstDiagnostic;
        auto recordFailure = [&](const std::string& diag) {
            bool expected = false;
            if (failed.compare_exchange_strong(expected, true,
                                               std::memory_order_relaxed)) {
                std::lock_guard<std::mutex> lock(diagnosticMutex);
                firstDiagnostic = diag;
            }
        };

        std::vector<std::thread> workers;
        workers.reserve(chunkCount);
        const std::size_t verticesPerChunk =
            (d.vertexCount + chunkCount - 1) / chunkCount;
        for (std::size_t chunk = 0; chunk < chunkCount; ++chunk) {
            const std::size_t beginVertex = chunk * verticesPerChunk;
            const std::size_t endVertex =
                std::min(d.vertexCount, beginVertex + verticesPerChunk);
            if (beginVertex >= endVertex) break;
            workers.emplace_back([&, beginVertex, endVertex] {
                Interpreter workerInterp(vsMod, Interpreter::Stage::Vertex,
                                         capturedNames, capturedWidths);
                configureVsInterpreter(workerInterp);
                std::string workerDiagnostic;
                if (!runVertexRange(beginVertex, endVertex, workerInterp,
                                    &failed, workerDiagnostic)) {
                    recordFailure(workerDiagnostic);
                }
            });
        }
        for (std::thread& worker : workers) {
            worker.join();
        }
        if (failed.load(std::memory_order_relaxed)) {
            d.ok = false;
            d.diagnostic = "VS-only-TF: " +
                (firstDiagnostic.empty() ? std::string("worker failure")
                                         : firstDiagnostic);
            return d;
        }
    }

    // Strip-topology decomposition isn't relevant for VS-only TF —
    // each output vertex is a final vertex, just like the GS POINTS
    // case. writeGsXfbAndCheckDiscard's vertsPerPrim derives
    // primitive count from the topology, so leave d.topology as the
    // caller's drawMode (after we record the input-mode-dependent
    // vertex count).
    d.ok = true;
    return d;
}

// Sprint 17 Day 7+ Bank-Group-H Path B Component C — CPU cull pre-pass
// for VS+FS programs writing gl_CullDistance. Implements GL §14.6.3:
// "the primitive is discarded iff for some channel i, ALL vertices
// have cull_distance[i] < 0."
//
// Runs the VS interpreter once per draw vertex (sister-pattern reuse
// of emulateVsOnlyDrawForTf at line 5129; same `runVsForVertex`
// engine), captures `cullDistance` per vertex, groups vertices into
// primitives based on `drawMode` topology, applies §14.6.3, and
// outputs a filtered list of original-vertex-indices for non-culled
// primitives. The caller (drawArrays / drawElements) then issues a
// Metal `drawIndexedPrimitives` against a transient index buffer
// built from `filteredIndicesOut` so Metal renders only visible
// primitives.
//
// Topology coverage (Phase 3 day 2 scope):
//   - GL_POINTS (vpp=1)        — discrete; each vertex = 1 primitive
//   - GL_LINES (vpp=2)         — discrete; pairs
//   - GL_TRIANGLES (vpp=3)     — discrete; triplets
//   - GL_LINE_STRIP            — sliding window step=1
//   - GL_TRIANGLE_STRIP        — sliding window with alternating winding
//   - GL_LINE_LOOP             — strip + wraparound primitive
//   - GL_TRIANGLE_FAN          — shared first vertex
// Adjacency variants (GL_LINES_ADJACENCY etc.) are NOT covered by this
// pre-pass — those CTS tests don't exercise cull_distance so deferring
// to future work is safe.
//
// Returns true on success; false (with diagnostic) on VS-pre-pass
// failure or unknown topology. `filteredIndicesOut` is populated only
// when the function returns true; on false, the caller should fall
// through to the legacy (no-cull-prepass) path.
bool emulateVsCullPrepass(
    GLProgramObject& program,
    const GLVertexArrayObject& vao,
    GLObjectStore& objects,
    const GLStateTracker& state,
    GLenum drawMode, GLsizei count, GLint first,
    const std::uint32_t* elementIndices,
    GLsizei instanceCount,
    GLuint baseInstance,
    std::vector<std::uint32_t>& filteredIndicesOut,
    std::string* diagnostic)
{
    filteredIndicesOut.clear();
    if (program.vertexSpirv.empty()) {
        if (diagnostic) *diagnostic = "emulateVsCullPrepass: empty VS SPIR-V";
        return false;
    }
    if (count <= 0) {
        // Empty draw — nothing to cull, nothing to render.
        return true;
    }
    // Per-topology vertices-per-primitive (vpp) + indexing mode.
    enum class Topo { Points, Lines, Triangles, LineStrip, LineLoop,
                      TriangleStrip, TriangleFan, Unknown };
    Topo topo = Topo::Unknown;
    std::uint32_t vpp = 0;
    switch (drawMode) {
        case GL_POINTS:         topo = Topo::Points;        vpp = 1; break;
        case GL_LINES:          topo = Topo::Lines;         vpp = 2; break;
        case GL_TRIANGLES:      topo = Topo::Triangles;     vpp = 3; break;
        case GL_LINE_STRIP:     topo = Topo::LineStrip;     vpp = 2; break;
        case GL_LINE_LOOP:      topo = Topo::LineLoop;      vpp = 2; break;
        case GL_TRIANGLE_STRIP: topo = Topo::TriangleStrip; vpp = 3; break;
        case GL_TRIANGLE_FAN:   topo = Topo::TriangleFan;   vpp = 3; break;
        default:
            if (diagnostic) *diagnostic =
                "emulateVsCullPrepass: unsupported topology 0x" +
                std::to_string(drawMode);
            return false;
    }
    const GLsizei effectiveInstances = std::max<GLsizei>(1, instanceCount);
    const std::size_t totalVerts =
        static_cast<std::size_t>(count) * static_cast<std::size_t>(effectiveInstances);
    // Pre-pass: run VS for each vertex; capture cullDistance + position
    // (position not used here but cheap to grab — runVsForVertex
    // populates it unconditionally).
    std::vector<EmulatedVertex> perVertex(totalVerts);
    {
        // No captured varyings — only need cull/clip distances + position.
        // runVsForVertex populates outVertex.cullDistance via the VS's
        // OpStore-to-BuiltInCullDistance walk regardless of captured
        // names list (sister to emulateVsOnlyDrawForTf line 5295).
        std::vector<std::string> emptyNames;
        std::vector<std::uint32_t> emptyWidths;
        std::string vsDiag;
        for (GLsizei instanceIdx = 0; instanceIdx < effectiveInstances; ++instanceIdx) {
            const std::int32_t glInstanceID = instanceIdx;
            (void)baseInstance;
            for (GLsizei vi = 0; vi < count; ++vi) {
                const std::size_t vboSlot = (elementIndices != nullptr)
                    ? static_cast<std::size_t>(elementIndices[vi])
                    : static_cast<std::size_t>(first + vi);
                const std::size_t globalIdx =
                    static_cast<std::size_t>(instanceIdx) *
                        static_cast<std::size_t>(count) +
                    static_cast<std::size_t>(vi);
                EmulatedVertex& outV = perVertex[globalIdx];
                outV = EmulatedVertex{};
                outV.position[3] = 1.0f;
                if (!runVsForVertex(
                        program.vertexSpirv.data(),
                        program.vertexSpirv.size(),
                        program, vao, objects, vboSlot, glInstanceID,
                        emptyNames, emptyWidths, outV, &vsDiag,
                        nullptr, nullptr, nullptr)) {
                    if (diagnostic) *diagnostic =
                        "emulateVsCullPrepass: VS-pre-pass: " + vsDiag;
                    return false;
                }
            }
        }
    }
    // Per-primitive iteration + §14.6.3 cull check + filtered indices.
    // Helper: vertexForPrim maps (primIdx, slot) → vertex-array index.
    auto vertexForPrim = [&](std::size_t p, std::uint32_t slot,
                             std::size_t baseV, std::size_t cnt) -> std::size_t {
        switch (topo) {
            case Topo::Points:
            case Topo::Lines:
            case Topo::Triangles:
                return baseV + p * vpp + slot;
            case Topo::LineStrip:
                return baseV + p + slot;
            case Topo::LineLoop:
                return baseV + ((p + slot) % cnt);
            case Topo::TriangleStrip: {
                // Alternate winding for odd primitives so the test's
                // §14.6.3 evaluation sees the same vertex set GL would.
                const std::uint32_t s = (p & 1u)
                    ? (slot == 0 ? 1u : (slot == 1 ? 0u : 2u))
                    : slot;
                return baseV + p + s;
            }
            case Topo::TriangleFan:
                return baseV + (slot == 0 ? 0u : (p + slot));
            default:
                return baseV;
        }
    };
    auto primCountFor = [&](std::size_t cnt) -> std::size_t {
        switch (topo) {
            case Topo::Points: return cnt;
            case Topo::Lines: return cnt / 2;
            case Topo::Triangles: return cnt / 3;
            case Topo::LineStrip:
                return (cnt >= 2) ? (cnt - 1) : 0;
            case Topo::LineLoop:
                return cnt;
            case Topo::TriangleStrip:
                return (cnt >= 3) ? (cnt - 2) : 0;
            case Topo::TriangleFan:
                return (cnt >= 3) ? (cnt - 2) : 0;
            default: return 0;
        }
    };
    const std::size_t cnt = static_cast<std::size_t>(count);
    const std::size_t primsPerInstance = primCountFor(cnt);
    filteredIndicesOut.reserve(primsPerInstance * vpp * effectiveInstances);
    for (GLsizei instanceIdx = 0; instanceIdx < effectiveInstances; ++instanceIdx) {
        const std::size_t baseV =
            static_cast<std::size_t>(instanceIdx) * cnt;
        for (std::size_t p = 0; p < primsPerInstance; ++p) {
            // Gather this primitive's vertex indices.
            std::array<std::size_t, 3> primVerts{0, 0, 0};
            for (std::uint32_t s = 0; s < vpp; ++s) {
                primVerts[s] = vertexForPrim(p, s, baseV, cnt);
            }
            // §14.6.3: cull iff for SOME channel i, ALL vertices have
            // cullDistance[i] < 0.
            std::size_t maxCullLen = 0;
            for (std::uint32_t s = 0; s < vpp; ++s) {
                maxCullLen = std::max(maxCullLen,
                                      perVertex[primVerts[s]].cullDistance.size());
            }
            bool culled = false;
            for (std::size_t plane = 0; plane < maxCullLen && !culled; ++plane) {
                bool allNeg = true;
                for (std::uint32_t s = 0; s < vpp; ++s) {
                    const auto& cd = perVertex[primVerts[s]].cullDistance;
                    const float c = (plane < cd.size()) ? cd[plane] : 0.0f;
                    if (c >= 0.0f) { allNeg = false; break; }
                }
                if (allNeg) culled = true;
            }
            if (culled) continue;
            // Primitive survives — append its vertex indices in the
            // order Metal will rasterize them.
            for (std::uint32_t s = 0; s < vpp; ++s) {
                filteredIndicesOut.push_back(
                    static_cast<std::uint32_t>(primVerts[s]));
            }
        }
    }
    (void)state;   // future: per-state coordination (e.g., gl_DrawID)
    return true;
}

EmulatedDraw emulateGeometryDraw(
    GLProgramObject& program,
    const GLVertexArrayObject& vao,
    GLObjectStore& objects,
    const GLStateTracker& state,
    GLenum drawMode, GLsizei count, GLint first,
    const std::uint32_t* elementIndices,
    GLsizei instanceCount,
    GLuint baseInstance,
    const SampledTextureMap* vsSampledTextures,
    const SampledTextureMap* gsSampledTextures,
    const SampledTextureMap* vsStorageImages,
    const SampledTextureMap* gsStorageImages,
    const EmulatedDraw* priorStageOutput)
{
    EmulatedDraw d;

    if (!program.geometryEmulated || program.geometrySpirv.empty()) {
        d.ok = false;
        d.diagnostic = "emulateGeometryDraw called on non-emulated program";
        return d;
    }

    // Sprint 8 #8 β.3 (CKPT97): tess+GS path overrides drawMode and
    // count from the prior stage's output. The post-tess vertex layout
    // is already resolved sequentially; the GS sees each consecutive
    // chunk of `vpp` vertices as one primitive matching its input
    // topology (so use a discrete drawMode that maps 1:1 to vpp).
    if (priorStageOutput != nullptr && priorStageOutput->ok) {
        d.pendingImageWrites.insert(d.pendingImageWrites.end(),
                                    priorStageOutput->pendingImageWrites.begin(),
                                    priorStageOutput->pendingImageWrites.end());
        count = static_cast<GLsizei>(priorStageOutput->vertexCount);
        first = 0;
        elementIndices = nullptr;
        // Override drawMode to the discrete equivalent of the GS input
        // topology so the per-primitive indexing collapses cleanly to
        // `vertex p*vpp+v`.
        switch (program.gsInputTopology) {
            case GL_POINTS:                drawMode = GL_POINTS; break;
            case GL_LINES:                 drawMode = GL_LINES; break;
            case GL_LINES_ADJACENCY:       drawMode = GL_LINES_ADJACENCY; break;
            case GL_TRIANGLES:             drawMode = GL_TRIANGLES; break;
            case GL_TRIANGLES_ADJACENCY:   drawMode = GL_TRIANGLES_ADJACENCY; break;
            default: /* leave caller's mode */ break;
        }
    }

    SpirvModule mod;
    if (!mod.parse(program.geometrySpirv.data(), program.geometrySpirv.size())
        || !mod.haveFuncBody) {
        d.ok = false;
        d.diagnostic = "SPIR-V re-parse failed at draw time: " + mod.parseError;
        return d;
    }

    // Primitive accounting. The draw's `mode` must be compatible with
    // the GS input topology (GL 4.6 §11.3.2). The GS SPIR-V declares
    // the input topology (points / lines / triangles / adjacency
    // variants) — but the DRAW mode may be a strip / loop / fan /
    // strip-adjacency variant that adjusts how vertices are chunked
    // into per-primitive groups.
    //
    // Discrete modes (GL_POINTS, GL_LINES, GL_LINES_ADJACENCY,
    // GL_TRIANGLES, GL_TRIANGLES_ADJACENCY): vertex count / vpp.
    // Strip / loop / fan / strip-adjacency modes: sliding window,
    // resulting in `count - (vpp - step)` primitives where step is
    // how many vertices the window advances per primitive.
    //
    // GL 4.6 §10.1 table 10.2:
    //   GL_LINE_STRIP            : step=1 (N-1 prims of 2 verts each)
    //   GL_LINE_LOOP             : step=1 (N prims of 2 verts, last wraps)
    //   GL_TRIANGLE_STRIP        : step=1 (N-2 prims of 3 verts)
    //   GL_TRIANGLE_FAN          : step=1 with shared first vertex (N-2 prims)
    //   GL_LINE_STRIP_ADJACENCY  : step=1 (N-3 prims of 4 verts)
    //   GL_TRIANGLE_STRIP_ADJ.   : step=2 (N-4)/2 prims of 6 verts
    const std::uint32_t vpp = vertsPerInputPrim(program.gsInputTopology);
    if (vpp == 0) {
        d.ok = false;
        d.diagnostic = "unknown GS input topology";
        return d;
    }

    enum class PrimIndexing { Discrete, Strip, StripAdjacency, Loop, Fan };
    PrimIndexing indexing = PrimIndexing::Discrete;
    switch (drawMode) {
        case GL_LINE_STRIP:
        case GL_TRIANGLE_STRIP:
        case GL_LINE_STRIP_ADJACENCY:
            indexing = PrimIndexing::Strip;
            break;
        case GL_TRIANGLE_STRIP_ADJACENCY:
            indexing = PrimIndexing::StripAdjacency;
            break;
        case GL_LINE_LOOP:
            indexing = PrimIndexing::Loop;
            break;
        case GL_TRIANGLE_FAN:
            indexing = PrimIndexing::Fan;
            break;
        default:
            indexing = PrimIndexing::Discrete;
            break;
    }

    std::size_t primCount = 0;
    switch (indexing) {
        case PrimIndexing::Discrete:
            primCount = (count > 0) ? (static_cast<std::size_t>(count) / vpp) : 0;
            break;
        case PrimIndexing::Strip:
            primCount = (count >= static_cast<GLsizei>(vpp))
                ? (static_cast<std::size_t>(count) - vpp + 1) : 0;
            break;
        case PrimIndexing::StripAdjacency:
            // Each primitive consumes 6 vertices but advances by 2.
            primCount = (count >= static_cast<GLsizei>(vpp))
                ? ((static_cast<std::size_t>(count) - vpp) / 2 + 1) : 0;
            break;
        case PrimIndexing::Loop:
            // LINE_LOOP: N prims (last wraps around).
            primCount = (count >= 2) ? static_cast<std::size_t>(count) : 0;
            break;
        case PrimIndexing::Fan:
            // TRIANGLE_FAN: N-2 prims, each sharing vertex 0.
            primCount = (count >= 3) ? (static_cast<std::size_t>(count) - 2) : 0;
            break;
    }
    if (primCount == 0) {
        d.ok = false;
        d.diagnostic = "vertex count produced zero primitives";
        return d;
    }

    // Helper: per-primitive vertex indexing. Returns the global
    // draw-position index (0..count-1) that should feed gl_in[v] of
    // primitive `p`.
    //
    // GL 4.6 §10.1.12 — triangle strip alternation: even triangles
    // see vertices (p, p+1, p+2); odd triangles see (p+1, p, p+2)
    // so consistent winding survives the strip decomposition. Only
    // applies when the GS input is `triangles` (vpp == 3) on a
    // TRIANGLE_STRIP draw — the line-strip case doesn't care
    // because lines are order-agnostic for rasterisation, and the
    // triangles_adjacency strip variant is handled separately in
    // StripAdjacency.
    auto vertexForPrim = [&](std::size_t p, std::uint32_t v) -> std::size_t {
        switch (indexing) {
            case PrimIndexing::Discrete:
                return p * vpp + v;
            case PrimIndexing::Strip:
                if (vpp == 3 && (p & 1u) != 0u) {
                    // Odd triangle: swap vertex 0 and vertex 1 so the
                    // GS sees the strip-reordered triangle.
                    if (v == 0) return p + 1;
                    if (v == 1) return p;
                    return p + 2;
                }
                return p + v;
            case PrimIndexing::StripAdjacency: {
                // GL 4.6 §10.1.14 Table 10.4 — TRIANGLE_STRIP_ADJACENCY
                // vertex layout per primitive. 4+2N vertices produce
                // N triangles; per-primitive gl_in[0..5] = main
                // triangle (v[0], v[2], v[4]) plus adjacency edges
                // (v[1], v[3], v[5]). Each primitive's vertex-index
                // mapping depends on whether it's the first / last /
                // middle-even / middle-odd primitive in the strip —
                // five cases total. Prior impl only alternated the
                // main triangle (strip winding) and used the naive
                // `p*2 + v` for adjacency slots; CTS
                // `adjacency.adjacency_{non_indiced,indiced}_triangle
                // _strip` reads gl_in[1/3/5] via `flat out vec4
                // out_adjacent_geometry = gl_in[1/3/5].gl_Position;`
                // and compared the TF output against the expected
                // adjacency-geometry — the naive formula produces
                // wrong vertex indices for 3/5 of the slots.
                const std::size_t i = p;
                const std::size_t N = primCount;
                const bool isFirst = (i == 0);
                const bool isLast = (N > 0 && i == N - 1);
                const bool isOdd = (i & 1u) != 0u;
                auto pos = [&](std::size_t idx) -> std::size_t { return idx; };
                if (isFirst && isLast) {
                    // Only primitive in the strip — use the single-
                    // primitive layout {0,1,2,5,4,3}. 4+2·1 = 6
                    // vertices, no "next" to grab v[2i+6] from.
                    switch (v) {
                        case 0: return pos(0);
                        case 1: return pos(1);
                        case 2: return pos(2);
                        case 3: return pos(5);
                        case 4: return pos(4);
                        case 5: return pos(3);
                    }
                } else if (isFirst) {
                    // First of many: {0,1,2,6,4,3}
                    switch (v) {
                        case 0: return pos(0);
                        case 1: return pos(1);
                        case 2: return pos(2);
                        case 3: return pos(6);
                        case 4: return pos(4);
                        case 5: return pos(3);
                    }
                } else if (isOdd && isLast) {
                    // Last odd: {2i+2, 2i-2, 2i, 2i+3, 2i+4, 2i+5}
                    switch (v) {
                        case 0: return 2*i + 2;
                        case 1: return (i >= 1) ? 2*i - 2 : 0;
                        case 2: return 2*i;
                        case 3: return 2*i + 3;
                        case 4: return 2*i + 4;
                        case 5: return 2*i + 5;
                    }
                } else if (isOdd) {
                    // Middle odd: {2i+2, 2i-2, 2i, 2i+3, 2i+4, 2i+6}
                    switch (v) {
                        case 0: return 2*i + 2;
                        case 1: return (i >= 1) ? 2*i - 2 : 0;
                        case 2: return 2*i;
                        case 3: return 2*i + 3;
                        case 4: return 2*i + 4;
                        case 5: return 2*i + 6;
                    }
                } else if (isLast) {
                    // Last even: {2i, 2i-2, 2i+2, 2i+5, 2i+4, 2i+3}
                    switch (v) {
                        case 0: return 2*i;
                        case 1: return (i >= 1) ? 2*i - 2 : 0;
                        case 2: return 2*i + 2;
                        case 3: return 2*i + 5;
                        case 4: return 2*i + 4;
                        case 5: return 2*i + 3;
                    }
                } else {
                    // Middle even: {2i, 2i-2, 2i+2, 2i+6, 2i+4, 2i+3}
                    switch (v) {
                        case 0: return 2*i;
                        case 1: return (i >= 1) ? 2*i - 2 : 0;
                        case 2: return 2*i + 2;
                        case 3: return 2*i + 6;
                        case 4: return 2*i + 4;
                        case 5: return 2*i + 3;
                    }
                }
                return 2*i + v;  // fallback (unreachable)
            }
            case PrimIndexing::Loop:
                return (p + v) % static_cast<std::size_t>(count);
            case PrimIndexing::Fan:
                return (v == 0) ? 0 : (p + v);
        }
        return p * vpp + v;
    };

    // Output varying layout from the GS SPIR-V, ordered by Location.
    const std::vector<OutputVaryingDesc> outVaryings = gatherOutputVaryings(mod);
    std::vector<std::string>   outNames;
    std::vector<std::uint32_t> outWidths;
    std::vector<std::uint32_t> outLocations;
    std::vector<std::uint8_t>  outInterp;
    std::vector<std::uint8_t>  outBaseType;
    std::vector<std::uint8_t>  outScalarByteSize;
    std::vector<std::uint32_t> outStageSlotWidths;
    std::vector<std::uint32_t> outStageSlotLocations;
    std::vector<std::uint8_t>  outStageSlotInterp;
    std::vector<std::uint8_t>  outStageSlotBaseType;
    std::vector<std::uint8_t>  outStageSlotScalarByteSize;
    // Sprint 8 #9-C (CKPT96) — per-varying stream tag from
    // DecorationStream. Default 0 (no decoration). Mirrors the layout
    // of the other outX vectors so the per-varying index lines up.
    std::vector<std::uint32_t> outStreams;
    outNames.reserve(outVaryings.size());
    outWidths.reserve(outVaryings.size());
    outLocations.reserve(outVaryings.size());
    outInterp.reserve(outVaryings.size());
    outBaseType.reserve(outVaryings.size());
    outScalarByteSize.reserve(outVaryings.size());
    outStreams.reserve(outVaryings.size());
    for (const auto& v : outVaryings) {
        outNames.push_back(v.name);
        outWidths.push_back(v.width);
        outLocations.push_back(v.location);
        outInterp.push_back(v.interp);
        outBaseType.push_back(v.baseType);
        outScalarByteSize.push_back(v.scalarByteSize);
        outStreams.push_back(v.stream);
        const auto& slots = v.stageSlotWidths.empty()
            ? std::vector<std::uint32_t>{std::max<std::uint32_t>(1, v.width)}
            : v.stageSlotWidths;
        for (std::size_t slot = 0; slot < slots.size(); ++slot) {
            outStageSlotWidths.push_back(slots[slot]);
            outStageSlotLocations.push_back(v.location + static_cast<std::uint32_t>(slot));
            outStageSlotInterp.push_back(v.interp);
            outStageSlotBaseType.push_back(v.baseType);
            outStageSlotScalarByteSize.push_back(v.scalarByteSize);
        }
    }

    // ─── VS pre-pass ────────────────────────────────────────────
    //
    // For each input vertex, run the VS interpreter on CPU so gl_in[]
    // sees the right per-vertex data. Skipped when the program lacks
    // VS SPIR-V (shouldn't happen for VGF programs, but the
    // constant_expressions path used to work without it because the
    // GS didn't read gl_in[]). In that case we fall back to zero-
    // initialised inputs.
    Interpreter::UniformValues uniforms = buildUniformMap(program);
    // UBO-block-array path: `layout(binding=N) uniform Block { … }
    // arr[K];` values live in GL buffers bound with
    // `glBindBufferBase(GL_UNIFORM_BUFFER, N+i, …)` rather than in
    // the program's own uniformValues table. Seed them into the
    // uniform map under the variable name so the GS interpreter's
    // OpAccessChain path finds them when it resolves
    // `arr[i].entry`. GL 4.6 §7.6 specifies that plain GLSL
    // `layout(binding=N)` establishes the initial mapping, and the
    // runtime may re-bind via glUniformBlockBinding — we honour
    // only the layout-specified binding for now (the common case
    // for limits tests).
    augmentUniformMapWithUBOBlocks(uniforms, mod, state, objects);

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

    // Outer instance loop + VS pre-pass + GS run. For a single-
    // instance draw (drawArrays / drawElements) instanceCount=1 and
    // baseInstance=0 — the loop degenerates to one iteration. For
    // drawArraysInstanced / drawElementsInstanced we run the VS per
    // vertex per instance with gl_InstanceID plumbed from the loop
    // index, then GS per primitive per instance. The expanded vertex
    // payload concatenates each instance's output so the Metal encode
    // issues ONE flat draw for the whole set.
    std::vector<EmulatedVertex> emittedAll;
    emittedAll.reserve(static_cast<std::size_t>(primCount) *
                       program.gsMaxVertices * std::max<GLsizei>(1, instanceCount));
    // Primitive boundaries in `emittedAll` — each entry is `emittedAll
    // .size()` right after a strip ended. Boundaries within a GS
    // invocation come from OpEndPrimitive; the implicit boundary at
    // function return is also pushed. Used below to expand line_strip
    // / triangle_strip output into line_list / triangle_list so Metal
    // doesn't draw spurious connections between independent strips or
    // between per-primitive GS invocations.
    std::vector<std::size_t> primEndsAll;

    // Sprint 7 Phase 1 #5 (CKPT56): GS-stage SSBO binding-resolve.
    // Walk the GS (and VS, when active) SPIR-V for StorageBuffer-class
    // or `Uniform + isBufferBlock`-decorated variables, look up each
    // one's GL_SHADER_STORAGE_BUFFER indexed binding via the state
    // tracker, resolve to the host-visible MTLBuffer contents
    // pointer, and build an Interpreter::StorageBufferMap keyed by
    // SPIR-V binding number. The interpreter's existing
    // resolveAccessChain / loadFromSSBO / storeToSSBO machinery
    // (CKPT43, TES path) does the per-access offset arithmetic from
    // there. Mirrors `addSsbosFromModule` at TessellationEmulator.cpp
    // 1987 — same shape, same StorageBufferRegion type, just per-GS
    // call site. Built once before the instance loop because GL
    // bindings can't change mid-draw (glBindBuffer* handlers are
    // never called while a draw is in flight).
    Interpreter::StorageBufferMap gsSsboMap;
    auto addSsbosFromGsModule = [&](const std::vector<std::uint32_t>& spirv) {
        if (spirv.empty()) return;
        SpirvModule sMod;
        if (!sMod.parse(spirv.data(), spirv.size())) return;
        for (const auto& [varId, info] : sMod.variables) {
            bool isSSBO = false;
            if (info.storageClass == spv::StorageClassStorageBuffer) {
                isSSBO = true;
            } else if (info.storageClass == spv::StorageClassUniform) {
                auto tIt = sMod.types.find(info.typeId);
                if (tIt != sMod.types.end()) {
                    auto dIt = sMod.decorations.find(tIt->second.pointeeType);
                    if (dIt != sMod.decorations.end() && dIt->second.isBufferBlock) {
                        isSSBO = true;
                    }
                }
            }
            if (!isSSBO) continue;
            auto dIt = sMod.decorations.find(varId);
            if (dIt == sMod.decorations.end() || !dIt->second.hasBinding) continue;
            const std::uint32_t binding = dIt->second.binding;
            if (gsSsboMap.find(binding) != gsSsboMap.end()) continue;
            const GLIndexedBufferBinding bb =
                state.indexedBufferBinding(GL_SHADER_STORAGE_BUFFER, binding);
            if (bb.buffer == 0) continue;
            GLBufferObject* bufObj = objects.buffers().get(bb.buffer);
            if (bufObj == nullptr || bufObj->metalBuffer == nullptr) continue;
            void* base = metalBufferContents(bufObj->metalBuffer);
            if (base == nullptr) continue;
            const std::size_t totalSize =
                static_cast<std::size_t>(bufObj->size);
            const std::size_t off =
                static_cast<std::size_t>(bb.offset < 0 ? 0 : bb.offset);
            // bb.size == 0 means BindBufferBase (whole buffer from off).
            const std::size_t span = (bb.size > 0)
                ? static_cast<std::size_t>(bb.size)
                : (totalSize > off ? totalSize - off : 0);
            Interpreter::StorageBufferRegion r;
            r.ptr = static_cast<std::uint8_t*>(base) + off;
            r.size = span;
            gsSsboMap[binding] = r;
        }
    };
    addSsbosFromGsModule(program.geometrySpirv);
    addSsbosFromGsModule(program.vertexSpirv);
    const Interpreter::StorageBufferMap* gsSsboMapPtr =
        gsSsboMap.empty() ? nullptr : &gsSsboMap;

    // UBO reads in CPU VS/GS emulation. Includes both UBO arrays and
    // ordinary block roots; `binding_uniform_blocks` uses the latter.
    Interpreter::UniformBufferMap gsUboMap;
    addUniformBuffersFromModule(program.geometrySpirv, objects, state, program, gsUboMap);
    addUniformBuffersFromModule(program.vertexSpirv, objects, state, program, gsUboMap);
    const Interpreter::UniformBufferMap* gsUboMapPtr =
        gsUboMap.empty() ? nullptr : &gsUboMap;

    const GLsizei effectiveInstances = std::max<GLsizei>(1, instanceCount);
    for (GLsizei instanceIdx = 0; instanceIdx < effectiveInstances; ++instanceIdx) {
        const std::int32_t glInstanceID = static_cast<std::int32_t>(instanceIdx);
        const std::int32_t shaderInstanceID = glInstanceID +
            static_cast<std::int32_t>(baseInstance);
        (void)shaderInstanceID;   // gl_InstanceID = instanceIdx per spec; baseInstance affects VBO fetch.

        // Per-instance VS pre-pass. Results live in a local vector
        // and flow into the per-primitive GS run for THIS instance.
        std::vector<Interpreter::PerVertexInput> allVertexInputs(count);
        if (priorStageOutput != nullptr && priorStageOutput->ok) {
            // Sprint 8 #8 β.3 (CKPT97): tess→GS plumbing. Replace the VS
            // pre-pass with the prior stage's per-vertex output. Each
            // vertex of priorStageOutput->expandedVertexData becomes one
            // entry in `allVertexInputs`, sliced into:
            //   - position[4] from the leading 4 floats
            //   - varyings[k] from priorStageOutput->varyingNames[k] /
            //     varyingWidths[k] in their declared order
            // Clip / cull distance arrays from the tess stage are
            // currently dropped (β.3 minimum: GS reads from the named
            // varyings or from gl_in[].gl_Position; gl_in[].gl_Clip/
            // CullDistance pass-through from TES is a future
            // refinement if a CTS test demands it).
            const std::size_t fpv = priorStageOutput->floatsPerVertex;
            const std::size_t vCnt = priorStageOutput->vertexCount;
            const float* base = priorStageOutput->expandedVertexData.data();
            for (std::size_t vi = 0; vi < vCnt && vi < allVertexInputs.size(); ++vi) {
                const float* v = base + vi * fpv;
                for (int k = 0; k < 4; ++k) allVertexInputs[vi].position[k] = v[k];
                std::size_t cursor = 4;
                allVertexInputs[vi].varyings.resize(priorStageOutput->varyingWidths.size());
                for (std::size_t vk = 0; vk < priorStageOutput->varyingWidths.size(); ++vk) {
                    const std::uint32_t w = priorStageOutput->varyingWidths[vk];
                    auto& dst = allVertexInputs[vi].varyings[vk];
                    dst.assign(w, 0.0f);
                    for (std::uint32_t j = 0; j < w && cursor + j < fpv; ++j) {
                        dst[j] = v[cursor + j];
                    }
                    cursor += w;
                }
            }
        } else if (haveVs) {
            Interpreter::VertexAttribs vsAttribs;
            for (GLsizei vi = 0; vi < count; ++vi) {
                const std::size_t vboSlot = (elementIndices != nullptr)
                    ? static_cast<std::size_t>(elementIndices[vi])
                    : static_cast<std::size_t>(first + vi);
                vsAttribs.clear();
                for (std::size_t ai = 0; ai < vao.attributes.size(); ++ai) {
                    if (!vao.attributes[ai].enabled) continue;
                    Value v = readVertexAttribFromVAO(
                        vao, objects, ai, vboSlot, /*instanceIdx=*/0);
                    if (v.kind != Value::Kind::Invalid) {
                        vsAttribs[static_cast<std::uint32_t>(ai)] = v;
                    }
                }
                Interpreter vsInterp(vsMod, Interpreter::Stage::Vertex,
                                     vsOutNames, vsOutWidths);
                vsInterp.setUniforms(&uniforms);
                vsInterp.setVsInputs(&vsAttribs,
                    static_cast<std::int32_t>(vboSlot), glInstanceID);
                if (vsSampledTextures != nullptr) {
                    vsInterp.setSampledTextures(vsSampledTextures);
                }
                if (vsStorageImages != nullptr) {
                    vsInterp.setStorageImages(vsStorageImages);
                }
                if (gsSsboMapPtr != nullptr) {
                    vsInterp.setStorageBuffers(gsSsboMapPtr);
                }
                if (gsUboMapPtr != nullptr) {
                    vsInterp.setUniformBuffers(gsUboMapPtr);
                }
                EmulatedVertex vsOut;
                vsOut.position[0] = vsOut.position[1] = vsOut.position[2] = 0.0f;
                vsOut.position[3] = 1.0f;
                if (!vsInterp.executeVs(vsOut)) {
                    d.diagnostic = "VS pre-pass failed: " + vsInterp.diagnostic();
                }
                for (int k = 0; k < 4; ++k) {
                    allVertexInputs[vi].position[k] = vsOut.position[k];
                }
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
                // Propagate gl_ClipDistance[] / gl_CullDistance[] the
                // VS captured into the per-vertex input record. These
                // drive the pre-GS primitive cull check below and
                // seed the GS's gl_in[].gl_{Clip,Cull}Distance[]
                // arrays so a passthrough GS can copy them through.
                allVertexInputs[vi].clipDistance = std::move(vsOut.clipDistance);
                allVertexInputs[vi].cullDistance = std::move(vsOut.cullDistance);
            }
        }

        for (std::size_t p = 0; p < primCount; ++p) {
            std::vector<Interpreter::PerVertexInput> inputs(vpp);
            for (std::uint32_t v = 0; v < vpp; ++v) {
                const std::size_t globalIdx = vertexForPrim(p, v);
                if (globalIdx < allVertexInputs.size()) {
                    inputs[v] = allVertexInputs[globalIdx];
                }
            }
            // GL 4.6 §13.6: before the geometry shader runs, discard
            // any primitive whose vertices all have gl_CullDistance
            // [i] < 0 for some i. The emulator's VS pre-pass captured
            // these per vertex; skip the GS invocation entirely when
            // the primitive is culled so the full-screen quad the
            // GS would generate doesn't leak onto a framebuffer the
            // test expected to stay cleared (CTS cull_distance.
            // functional_test_item_5 tests each of the 8 cull planes).
            {
                std::size_t maxCullLen = 0;
                for (const auto& vi : inputs) {
                    maxCullLen = std::max(maxCullLen, vi.cullDistance.size());
                }
                bool culled = false;
                for (std::size_t plane = 0; plane < maxCullLen && !culled; ++plane) {
                    bool allNeg = true;
                    for (const auto& vi : inputs) {
                        const float c = (plane < vi.cullDistance.size())
                            ? vi.cullDistance[plane] : 0.0f;
                        if (c >= 0.0f) { allNeg = false; break; }
                    }
                    if (allNeg) culled = true;
                }
                if (culled) continue;
            }
            // Multi-invocation GS: when the GS declares
            // `layout(invocations = N)`, re-run the interpreter
            // N times per primitive with gl_InvocationID set to
            // each invocation index. N=1 degenerates to the
            // original single-run path.
            const std::uint32_t gsInvocations = std::max<std::uint32_t>(program.gsInvocations, 1);
            for (std::uint32_t invId = 0; invId < gsInvocations; ++invId) {
                // Sprint 8 #8 β.3 (CKPT97): tess+GS path uses the prior
                // stage's varyingNames/Widths as the GS interpreter's
                // input-side names so block-member lookups
                // (`gl_in[N].tc_position` etc.) match TES-emitted names.
                // Falls back to vsOutNames/Widths for legacy VS+GS path.
                const auto& gsInNames = (priorStageOutput != nullptr && priorStageOutput->ok)
                    ? priorStageOutput->varyingNames : vsOutNames;
                const auto& gsInWidths = (priorStageOutput != nullptr && priorStageOutput->ok)
                    ? priorStageOutput->varyingWidths : vsOutWidths;
                Interpreter interp(mod, gsInNames, gsInWidths,
                                   outNames, outWidths);
                interp.setUniforms(&uniforms);
                interp.setGsPrimitiveId(static_cast<std::int32_t>(p));
                interp.setGsInvocationId(static_cast<std::int32_t>(invId));
                if (gsSampledTextures != nullptr) {
                    interp.setSampledTextures(gsSampledTextures);
                }
                if (gsStorageImages != nullptr) {
                    interp.setStorageImages(gsStorageImages);
                }
                if (gsSsboMapPtr != nullptr) {
                    interp.setStorageBuffers(gsSsboMapPtr);
                }
                if (gsUboMapPtr != nullptr) {
                    interp.setUniformBuffers(gsUboMapPtr);
                }
                if (std::getenv("APPGL_TRACE_GS_EMUL_TEX")) {
                    std::fprintf(stderr,
                        "[GS-tex] gs interp.execute begin prim=%zu inv=%u "
                        "gsTexMap=%p\n",
                        p, invId, (const void*)gsSampledTextures);
                }
                std::vector<EmulatedVertex> emitted;
                std::vector<std::size_t> primEnds;
                if (!interp.execute(inputs, emitted, primEnds)) {
                    d.ok = false;
                    d.diagnostic = "interpreter failed on primitive " + std::to_string(p)
                                 + " invocation " + std::to_string(invId)
                                 + ": " + interp.diagnostic();
                    return d;
                }
                // If any primitive's GS wrote gl_Layer, the whole draw
                // needs the synth-VS `[[render_target_array_index]]`
                // output slot. Accumulate across primitives/instances
                // /invocations.
                if (interp.didWriteLayer()) {
                    d.hasLayer = true;
                }
                if (interp.didWriteViewportIndex()) {
                    d.hasViewportIndex = true;
                }
                if (interp.didWritePointSize()) {
                    d.hasPointSize = true;
                }
                if (interp.didWritePrimitiveID()) {
                    d.hasPrimitiveID = true;
                }
                // CKPT162 (Sprint 14 Day 9): drain captured image writes
                // for runtime sync-back after GS body completes.
                {
                    auto writes = interp.takePendingImageWrites();
                    if (!writes.empty()) {
                        for (auto& write : writes) {
                            write.stage = GL_GEOMETRY_SHADER;
                        }
                        d.pendingImageWrites.insert(
                            d.pendingImageWrites.end(),
                            std::make_move_iterator(writes.begin()),
                            std::make_move_iterator(writes.end()));
                    }
                }
                // Shift the per-invocation primEnds by the current
                // emittedAll size so they remain valid indices into
                // the global buffer after insert.
                const std::size_t baseIdx = emittedAll.size();
                for (std::size_t endIdx : primEnds) {
                    primEndsAll.push_back(baseIdx + endIdx);
                }
                // Defensive: ensure a boundary exists at the end of
                // this invocation — an empty GS body that emitted
                // nothing will not have pushed anything, and (if the
                // next invocation adds vertices) we'd otherwise glue
                // them onto the tail of the previous invocation's
                // last strip.
                if (!emitted.empty() &&
                    (primEndsAll.empty() || primEndsAll.back() != baseIdx + emitted.size())) {
                    primEndsAll.push_back(baseIdx + emitted.size());
                }
                emittedAll.insert(emittedAll.end(),
                    std::make_move_iterator(emitted.begin()),
                    std::make_move_iterator(emitted.end()));
            }
        }
    }

    if (emittedAll.empty()) {
        // Emulator ran to completion but the GS body never called
        // EmitVertex — a valid scenario (e.g. `output.vertex_emit_
        // at_end` emits gl_Position writes without matching
        // EmitVertex calls, and expects zero fragments touched).
        // Mark the draw as successfully consumed (`ok = true`) with
        // an empty payload so the caller skips the Metal encode
        // cleanly; a `d.ok = false` fall-through would hand the
        // draw to the legacy VS+FS pipeline, which renders a
        // spurious point at the VS output and fails the test.
        d.ok = true;
        d.vertexCount = 0;
        return d;
    }

    // Strip → list expansion. `layout(line_strip)` + `layout(triangle
    // _strip)` GS outputs imply connectivity within each strip —
    // per-primitive in the GS (separated by OpEndPrimitive) and
    // per-invocation (implicit at function return). Metal has no
    // cross-primitive primitive-restart semantics for a non-indexed
    // draw; rendering N concatenated strips as a single MTL strip
    // would stitch spurious line segments between them. Convert the
    // strip to an explicit list topology (GL_LINES / GL_TRIANGLES):
    //  - line_strip of N vertices → N-1 segments × 2 vertices each
    //  - triangle_strip of N vertices → N-2 triangles; winding
    //    alternates per GL 4.6 §10.1.13 / §13.6 (odd-indexed
    //    triangles have a flipped order to keep consistent
    //    winding after strip decomposition).
    GLenum expandedTopo = program.gsOutputTopology;
    std::vector<EmulatedVertex> expanded;
    if (program.gsOutputTopology == GL_LINE_STRIP ||
        program.gsOutputTopology == GL_TRIANGLE_STRIP) {
        // Ensure primEndsAll has at least the final boundary — some
        // GS shaders may have omitted an explicit EndPrimitive at
        // the end of the last invocation and the implicit OpReturn
        // path above should have covered it, but defend against
        // future changes.
        if (primEndsAll.empty() || primEndsAll.back() != emittedAll.size()) {
            primEndsAll.push_back(emittedAll.size());
        }

        expanded.reserve(emittedAll.size() * 2);   // worst-case for triangle_strip
        std::size_t prev = 0;
        if (program.gsOutputTopology == GL_LINE_STRIP) {
            for (std::size_t endIdx : primEndsAll) {
                if (endIdx <= prev) continue;
                // Each strip of N verts → (N-1) line segments.
                for (std::size_t i = prev; i + 1 < endIdx; ++i) {
                    expanded.push_back(emittedAll[i]);
                    expanded.push_back(emittedAll[i + 1]);
                }
                prev = endIdx;
            }
            expandedTopo = GL_LINES;
        } else {
            for (std::size_t endIdx : primEndsAll) {
                if (endIdx <= prev) continue;
                // Each strip of N verts → (N-2) triangles with
                // alternating winding.
                for (std::size_t i = prev; i + 2 < endIdx; ++i) {
                    const std::size_t offset = i - prev;
                    // Odd offset flips winding — this preserves the
                    // GL-spec front-facing order of every triangle
                    // once decomposed into a list.
                    if ((offset & 1u) == 0u) {
                        expanded.push_back(emittedAll[i]);
                        expanded.push_back(emittedAll[i + 1]);
                        expanded.push_back(emittedAll[i + 2]);
                    } else {
                        expanded.push_back(emittedAll[i + 1]);
                        expanded.push_back(emittedAll[i]);
                        expanded.push_back(emittedAll[i + 2]);
                    }
                }
                prev = endIdx;
            }
            expandedTopo = GL_TRIANGLES;
        }
        emittedAll = std::move(expanded);
    }

    if (emittedAll.empty()) {
        // A single-vertex or two-vertex strip decomposes to zero
        // line segments / triangles — the GS ran correctly but
        // didn't emit enough vertices to form any output
        // primitives. `output.vertex_emit_at_end` hits this via a
        // triangle_strip body that emits 2 verts + EndPrimitive +
        // one unmatched gl_Position set — the expected framebuffer
        // is all-clear. Mark the draw successfully consumed so
        // the caller skips the Metal encode without falling back
        // to the VS+FS path (which would render spurious fragments
        // from the VS's gl_Position).
        d.ok = true;
        d.vertexCount = 0;
        return d;
    }


    // Pack into the flat payload [pos0..3, varying0..N-1] per vertex.
    const std::size_t totalVaryingWidth = [&]() {
        std::size_t s = 0;
        for (std::uint32_t w : outWidths) s += w;
        return s;
    }();
    // Max clip / cull distance across every emitted vertex. If the
    // GS writes neither, both stay 0 and the expanded buffer /
    // synth VS skip their slots. If the GS writes one vertex's
    // clipDistance but not another's, we pad with zero (Metal
    // requires all vertices of a primitive to have matching array
    // length).
    //
    // Suppress the slot when the GS source never stores to
    // gl_ClipDistance / gl_CullDistance. glslang emits the
    // gl_PerVertex output block including both arrays even when
    // the GS doesn't touch them, so `captureClipCull` would
    // publish a 1-element zero-valued slot — which Metal then
    // interprets as "on the clip plane" and may discard the
    // whole primitive due to fp noise. Walk the SPIR-V once to
    // find real writes.
    const auto [gsWritesClip, gsWritesCull] = scanClipCullWrites(mod);
    if (!gsWritesClip) {
        for (auto& e : emittedAll) e.clipDistance.clear();
    }
    if (!gsWritesCull) {
        for (auto& e : emittedAll) e.cullDistance.clear();
    }
    std::uint32_t clipLen = 0, cullLen = 0;
    for (const auto& e : emittedAll) {
        clipLen = std::max(clipLen, static_cast<std::uint32_t>(e.clipDistance.size()));
        cullLen = std::max(cullLen, static_cast<std::uint32_t>(e.cullDistance.size()));
    }
    // Layered-output slot: one int32 per vertex at the tail of
    // the packed payload, only when the GS wrote gl_Layer at all.
    const std::size_t layerSlot = d.hasLayer ? 1 : 0;
    const std::size_t pointSizeSlot = d.hasPointSize ? 1 : 0;
    const std::size_t primIdSlot = d.hasPrimitiveID ? 1 : 0;
    // Sprint 15 Day 10 [metal-viewport-array]: viewport-index slot.
    const std::size_t viSlot = d.hasViewportIndex ? 1 : 0;
    const std::size_t fpv = 4 + totalVaryingWidth + clipLen + cullLen
                          + layerSlot + pointSizeSlot + primIdSlot + viSlot;

    d.topology          = expandedTopo;
    d.vertexCount       = emittedAll.size();
    d.floatsPerVertex   = fpv;
    d.varyingWidths     = outWidths;
    d.varyingNames      = std::move(outNames);
    d.varyingLocations  = std::move(outLocations);
    d.varyingInterp     = std::move(outInterp);
    d.varyingStreams    = std::move(outStreams);   // Sprint 8 #9-C (CKPT96)
    d.varyingBaseType   = std::move(outBaseType);
    d.varyingScalarByteSize = std::move(outScalarByteSize);
    d.varyingStageSlotWidths = std::move(outStageSlotWidths);
    d.varyingStageSlotLocations = std::move(outStageSlotLocations);
    d.varyingStageSlotInterp = std::move(outStageSlotInterp);
    d.varyingStageSlotBaseType = std::move(outStageSlotBaseType);
    d.varyingStageSlotScalarByteSize = std::move(outStageSlotScalarByteSize);
    d.clipDistanceLen   = clipLen;
    d.cullDistanceLen   = cullLen;
    // Pre-compute the primitive-id varying location for the
    // synth VS output + FS post-processor. Use max(userVaryingLoc)+1
    // to avoid collision with regular GS output varyings. When
    // there are no user varyings, location 0 is fine.
    if (d.hasPrimitiveID) {
        std::uint32_t maxLoc = 0;
        const auto& locs = d.varyingStageSlotLocations.empty()
            ? d.varyingLocations : d.varyingStageSlotLocations;
        for (std::uint32_t loc : locs) {
            if (loc > maxLoc) maxLoc = loc;
        }
        d.primitiveIDLocation = locs.empty() ? 0u : (maxLoc + 1u);
    }

    // Per-primitive gl_Layer propagation. GL 4.6 §14.5.1 with
    // `GL_LAST_VERTEX_CONVENTION` (our advertised default — see
    // commit 5588d41) routes the provoking-vertex's gl_Layer to
    // every primitive, and Metal reads `[[render_target_array_
    // index]]` from the provoking vertex. Metal's default
    // provoking-vertex convention for flat varyings + layered
    // output is FIRST-vertex, so without this propagation the
    // per-triangle layer is the value of the first vertex —
    // which on a strip-consumed triangle may be stale (set by a
    // previous strip's GS iteration). Normalising every vertex
    // to the primitive's last vertex makes both conventions
    // agree.
    if (d.hasLayer && expandedTopo != 0) {
        std::size_t primSize = 0;
        switch (expandedTopo) {
            case GL_POINTS:        primSize = 1; break;
            case GL_LINES:         primSize = 2; break;
            case GL_TRIANGLES:     primSize = 3; break;
            default:               primSize = 0; break;
        }
        if (primSize > 0) {
            for (std::size_t i = 0; i + primSize <= emittedAll.size(); i += primSize) {
                const std::int32_t lastLayer = emittedAll[i + primSize - 1].layer;
                for (std::size_t k = 0; k < primSize; ++k) {
                    emittedAll[i + k].layer = lastLayer;
                }
            }
        }
    }
    // Sprint 15 Day 10 [metal-viewport-array]: viewport-index per-
    // primitive propagation. Sister to gl_Layer pattern. LAST_VERTEX_
    // CONVENTION (default user provoking) — copy provoking vertex's
    // value to all vertices in the primitive.
    if (d.hasViewportIndex && expandedTopo != 0) {
        std::size_t primSize = 0;
        switch (expandedTopo) {
            case GL_POINTS:        primSize = 1; break;
            case GL_LINES:         primSize = 2; break;
            case GL_TRIANGLES:     primSize = 3; break;
            default:               primSize = 0; break;
        }
        if (primSize > 0) {
            for (std::size_t i = 0; i + primSize <= emittedAll.size(); i += primSize) {
                const std::int32_t lastVi =
                    emittedAll[i + primSize - 1].viewportIndex;
                for (std::size_t k = 0; k < primSize; ++k) {
                    emittedAll[i + k].viewportIndex = lastVi;
                }
            }
        }
    }

    // Per-primitive flat-varying propagation. GL 4.6 §14.5.1 with
    // `GL_LAST_VERTEX_CONVENTION` routes the LAST vertex's value to
    // the whole primitive for `flat` interpolation — Metal reads
    // from the FIRST vertex by default (`flatInputProvokingVertex`
    // isn't exposed in current Metal headers). Rewrite each flat
    // varying to the provoking vertex's value so both conventions
    // agree. CTS `layered_rendering.layered_rendering` set
    // `provoking_vertex_index=2` (LAST), uses `flat out int
    // layer_id;` and the FS's per-primitive case-match on
    // layer_id decides the output colour — without this fix, the
    // FS sees the strip's first-vertex layer_id (stale from the
    // previous strip iteration) instead of the LAST's.
    // NOTE: read interpolation qualifiers from `d.varyingInterp`, not
    // local `outInterp` — `outInterp` was moved into `d.varyingInterp`
    // at the field-assignment block above (line 5801: `std::move(
    // outInterp)`), leaving the local in valid-but-unspecified
    // (typically empty) state. The original f451ecd flat-varying
    // propagation block read from the moved-from local, so the guard
    // `if (!outInterp.empty())` was always false and the entire block
    // was silently skipped — surfaced by Sprint 16 Day 13 Cowork
    // .gputrace evidence on layered_rendering.layered_rendering
    // showing positions 0,1,4 of each 6-vertex strip-expanded layer
    // group carrying the previous layer's stale `flat out int
    // layer_id` value.
    //
    // Sprint 17 Day 1 (CKPT236) [option (b) gate]: skip propagation
    // when GL_RASTERIZER_DISCARD is enabled. Per GL 4.6 §13.2.2,
    // transform-feedback captures the per-vertex emitted varying
    // values pre-propagation; provoking-vertex flat propagation is
    // a RASTERIZATION-side concept (FS sees the LAST vertex's flat
    // value via `flatInputProvokingVertex` semantics, not XFB).
    // Applying propagation before XFB writeback corrupts
    // `geometry_shader.input.gl_in_array_contents` (CKPT236 bisect
    // identified 96d16b0 as the cause) — that test enables
    // GL_RASTERIZER_DISCARD and validates per-vertex XFB-captured
    // `gs_fs_b = vs_gs_b[i]` values for i=0,1,2 (3 distinct values
    // for a 3-vertex triangle); with propagation active, all 3
    // values become the LAST vertex's, breaking the assertion.
    //
    // The layered_rendering.layered_rendering rasterization use case
    // (the original 96d16b0 fix target) is unaffected — it does NOT
    // enable GL_RASTERIZER_DISCARD, so propagation continues to fire
    // correctly for the FS's per-primitive layer_id case-match.
    const bool rasterizerDiscarded =
        state.isEnabled(GL_RASTERIZER_DISCARD);
    if (!d.varyingInterp.empty() && !rasterizerDiscarded) {
        std::size_t primSize = 0;
        switch (expandedTopo) {
            case GL_POINTS:    primSize = 1; break;
            case GL_LINES:     primSize = 2; break;
            case GL_TRIANGLES: primSize = 3; break;
            default:           primSize = 0; break;
        }
        if (primSize > 0) {
            // Pre-compute varying offsets (flat-scalar start per
            // varying index) so we can copy the last vertex's slice
            // for any flat varying without re-traversing every loop.
            std::vector<std::size_t> varyingOffsets(d.varyingInterp.size(), 0);
            {
                std::size_t off = 0;
                for (std::size_t vi = 0; vi < d.varyingInterp.size(); ++vi) {
                    varyingOffsets[vi] = off;
                    if (vi < outWidths.size()) off += outWidths[vi];
                }
            }
            for (std::size_t i = 0; i + primSize <= emittedAll.size(); i += primSize) {
                const std::size_t last = i + primSize - 1;
                for (std::size_t vi = 0; vi < d.varyingInterp.size(); ++vi) {
                    // Only flat-qualified outputs carry provoking-
                    // vertex semantics. Smooth / noperspective
                    // interpolate across all three vertices and
                    // don't care about the provoking choice.
                    if (d.varyingInterp[vi] != 1) continue;
                    const std::size_t varyOff = varyingOffsets[vi];
                    const std::uint32_t width = (vi < outWidths.size()) ? outWidths[vi] : 0;
                    if (width == 0) continue;
                    if (last >= emittedAll.size()) continue;
                    if (emittedAll[last].varyings.size() < varyOff + width) continue;
                    for (std::size_t k = 0; k < primSize; ++k) {
                        auto& dst = emittedAll[i + k].varyings;
                        if (dst.size() < varyOff + width) continue;
                        for (std::uint32_t w = 0; w < width; ++w) {
                            dst[varyOff + w] = emittedAll[last].varyings[varyOff + w];
                        }
                    }
                }
            }
        }
    }

    d.expandedVertexData.resize(emittedAll.size() * fpv, 0.0f);

    // Sprint 8 #9-C (CKPT95) — capture per-vertex stream tag and
    // accumulate per-stream totals. Stream-tag survives strip→list
    // expansion (each EmulatedVertex carries it through the rebuild
    // above). vertexStreams is parallel to expandedVertexData (one
    // entry per packed vertex); streamVertexCounts is the post-
    // expansion total per stream that writeGsXfbAndCheckDiscard reads
    // to update GLTransformFeedbackObject::capturedVertexCount.
    d.vertexStreams.resize(emittedAll.size(), 0);

    for (std::size_t v = 0; v < emittedAll.size(); ++v) {
        float* dst = d.expandedVertexData.data() + v * fpv;
        const std::uint32_t vstream = emittedAll[v].stream;
        d.vertexStreams[v] = vstream;
        if (vstream < d.streamVertexCounts.size()) {
            d.streamVertexCounts[vstream]++;
        }
        for (int k = 0; k < 4; ++k) dst[k] = emittedAll[v].position[k];
        for (std::size_t j = 0; j < emittedAll[v].varyings.size() && j + 4 < fpv; ++j) {
            dst[4 + j] = emittedAll[v].varyings[j];
        }
        // Append clip then cull after the user varyings.
        const std::size_t clipBase = 4 + totalVaryingWidth;
        for (std::size_t j = 0; j < emittedAll[v].clipDistance.size() && j < clipLen; ++j) {
            dst[clipBase + j] = emittedAll[v].clipDistance[j];
        }
        const std::size_t cullBase = clipBase + clipLen;
        for (std::size_t j = 0; j < emittedAll[v].cullDistance.size() && j < cullLen; ++j) {
            dst[cullBase + j] = emittedAll[v].cullDistance[j];
        }
        // Append gl_Layer int32 (bit-cast into float32 slot) at the
        // very tail when d.hasLayer — read back by the synth VS and
        // emitted as `[[render_target_array_index]]`.
        if (d.hasLayer) {
            const std::size_t layerOff = cullBase + cullLen;
            std::memcpy(&dst[layerOff], &emittedAll[v].layer, sizeof(std::int32_t));
            // Sprint 17 Day 1 (CKPT236) [Probe A]: track max emitted
            // layer for downstream `pass.renderTargetArrayLength`
            // clamp on 2DMSArray attachments (Codex h2DM-3 verdict).
            if (emittedAll[v].layer >= 0 &&
                static_cast<std::uint32_t>(emittedAll[v].layer) > d.maxEmittedLayer) {
                d.maxEmittedLayer =
                    static_cast<std::uint32_t>(emittedAll[v].layer);
            }
        }
        // Append gl_PointSize float at the very tail when
        // d.hasPointSize — read by the synth VS and emitted as
        // `[[point_size]]`. Sits after the layer slot if both are
        // present (matching VsIn attribute ordering in the MSL
        // generator).
        if (d.hasPointSize) {
            const std::size_t psOff = cullBase + cullLen + layerSlot;
            dst[psOff] = emittedAll[v].pointSize;
        }
        // Append gl_PrimitiveID int32 (bit-cast to float32 slot)
        // after layer + pointSize when d.hasPrimitiveID. Read by
        // the synth VS and forwarded to the FS through a flat
        // `int` user varying — the FS MSL post-processor replaces
        // the SPIRV-Cross-generated `uint gl_PrimitiveID
        // [[primitive_id]]` parameter with a read of this value,
        // so the FS sees the GS-supplied override instead of
        // Metal's rasteriser-provided primitive index.
        if (d.hasPrimitiveID) {
            const std::size_t pidOff = cullBase + cullLen + layerSlot + pointSizeSlot;
            std::memcpy(&dst[pidOff], &emittedAll[v].primitiveId, sizeof(std::int32_t));
        }
        // Sprint 15 Day 10 [metal-viewport-array]: viewport-index
        // slot packed after primitiveID.
        if (d.hasViewportIndex) {
            const std::size_t viOff = cullBase + cullLen + layerSlot
                + pointSizeSlot + primIdSlot;
            std::memcpy(&dst[viOff], &emittedAll[v].viewportIndex,
                        sizeof(std::int32_t));
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

std::string synthesisePassThroughVertexMSL(const EmulatedDraw& draw,
                                           bool layeredFbo,
                                           bool viewportArrayBound) {
    // Emit render_target_array_index only when both the GS wrote
    // gl_Layer AND the bound FBO is a layered attachment. On a
    // non-layered FBO, writing [[render_target_array_index]] with
    // renderTargetArrayLength=0 is undefined behaviour under Metal
    // — in practice the driver drops the fragment — so we decline
    // to emit the slot. The vsin_layer input attribute is still
    // declared to keep the vertex-descriptor stride in sync with
    // the packed buffer produced by emulateGeometryDraw.
    const bool emitRenderTargetArrayIndex = draw.hasLayer && layeredFbo;
    // Sprint 15 Day 10 [metal-viewport-array]: emit
    // `[[viewport_array_index]]` only when GS wrote gl_ViewportIndex
    // AND encoder bound multi-viewport (Day 8 commit `39b9fd1`
    // populates this when state diverges from slot 0). Caller
    // additionally gates `viewportArrayBound` on the env-gate
    // `APPGL_ENABLE_METAL_VIEWPORT_INDEX` so this is opt-in
    // groundwork pending Day 11+ deeper Metal-API diagnosis (per
    // CKPT181 finding that unconditional emission caused a
    // pre-merge regression on viewport_array.provoking_vertex).
    const bool emitViewportArrayIndex =
        draw.hasViewportIndex && viewportArrayBound;
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
    const auto& slotWidths = draw.varyingStageSlotWidths.empty()
        ? draw.varyingWidths : draw.varyingStageSlotWidths;
    const auto& slotLocations = draw.varyingStageSlotLocations.empty()
        ? draw.varyingLocations : draw.varyingStageSlotLocations;
    const auto& slotInterp = draw.varyingStageSlotInterp.empty()
        ? draw.varyingInterp : draw.varyingStageSlotInterp;
    const auto& slotBaseType = draw.varyingStageSlotBaseType.empty()
        ? draw.varyingBaseType : draw.varyingStageSlotBaseType;

    std::string src;
    src.reserve(512);
    src += "#include <metal_stdlib>\n";
    src += "using namespace metal;\n\n";

    // ─ Vertex input struct (stage_in).
    src += "struct VsIn {\n";
    src += "    float4 vsin_position [[attribute(0)]];\n";
    for (std::size_t i = 0; i < slotWidths.size(); ++i) {
        const std::uint8_t bt = (i < slotBaseType.size()) ? slotBaseType[i] : 0;
        src += "    ";
        src += mslTypeFor(slotWidths[i], bt);
        src += " vsin_v";
        src += std::to_string(i);
        src += " [[attribute(";
        src += std::to_string(i + 1);   // 0 reserved for position
        src += ")]];\n";
    }
    // Clip + cull distance input slots. Packed one float-per-slot
    // starting immediately after the last user varying's attribute
    // index. Clip first, then cull. The encoder's vertex-descriptor
    // builder emits matching per-scalar attributes so Metal's vertex
    // fetcher pulls one float from the packed expanded buffer.
    const std::uint32_t clipBaseAttrib =
        static_cast<std::uint32_t>(slotWidths.size() + 1);
    for (std::uint32_t i = 0; i < draw.clipDistanceLen; ++i) {
        src += "    float vsin_clip";
        src += std::to_string(i);
        src += " [[attribute(";
        src += std::to_string(clipBaseAttrib + i);
        src += ")]];\n";
    }
    const std::uint32_t cullBaseAttrib = clipBaseAttrib + draw.clipDistanceLen;
    for (std::uint32_t i = 0; i < draw.cullDistanceLen; ++i) {
        src += "    float vsin_cull";
        src += std::to_string(i);
        src += " [[attribute(";
        src += std::to_string(cullBaseAttrib + i);
        src += ")]];\n";
    }
    // Sprint 7 Phase 1 #6 (CKPT58): trailing per-vertex slots
    // (gl_Layer, gl_PointSize, gl_PrimitiveID) used to live as
    // `[[attribute(N)]]` stage_in entries here, but Metal Apple7
    // (M1 Max) caps stage_in at 31 attributes. With max GS output
    // components = 128, the test surfaces 30 ivec4 varyings + position
    // + pointSize = 32 attributes — slot 31 silently drops, breaking
    // every test that maxes the geometry-output budget. Relocate
    // these trailing slots OFF stage_in: the synth-VS reads them
    // manually from the same packed buffer at slot 0 via a
    // `device const float*` parameter + vertex_id arithmetic. Saves
    // up to 3 attribute slots, fitting the 31-attribute budget for
    // GL's spec-floor MAX_GEOMETRY_OUTPUT_COMPONENTS = 128.
    src += "};\n\n";

    // Compute the per-vertex stride (in floats) and the offsets to
    // each trailing slot. These match the encoder-side packing in
    // `emulateGeometryDraw` (search for `dst[layerOff]`).
    std::uint32_t totalVaryingWidth = 0;
    for (auto w : draw.varyingWidths) totalVaryingWidth += w;
    const std::uint32_t strideFloats =
        4 + totalVaryingWidth + draw.clipDistanceLen + draw.cullDistanceLen
        + (draw.hasLayer ? 1u : 0u)
        + (draw.hasPointSize ? 1u : 0u)
        + (draw.hasPrimitiveID ? 1u : 0u)
        + (draw.hasViewportIndex ? 1u : 0u);
    const std::uint32_t layerFloatOff = 4 + totalVaryingWidth
        + draw.clipDistanceLen + draw.cullDistanceLen;
    const std::uint32_t psFloatOff =
        layerFloatOff + (draw.hasLayer ? 1u : 0u);
    const std::uint32_t pidFloatOff =
        psFloatOff + (draw.hasPointSize ? 1u : 0u);
    // Sprint 15 Day 10 [metal-viewport-array]: viewport-index slot
    // sits after primitiveID (matches encoder packing order).
    const std::uint32_t viFloatOff =
        pidFloatOff + (draw.hasPrimitiveID ? 1u : 0u);
    const bool needsTrailingBuffer =
        draw.hasLayer || draw.hasPointSize || draw.hasPrimitiveID
        || draw.hasViewportIndex;

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
    // Metal has no [[cull_distance]] qualifier — cull is expressed by
    // the per-vertex primitive cull check we did before the GS ran
    // (see §13.6 in the spec-quote above the pre-GS loop). That
    // means by the time we get here, the cull_distance values only
    // need to propagate so a downstream stage (if any) can observe
    // them, not to drive the Metal rasterizer. We still emit them as
    // a separate `[[clip_distance]]` slice after the clip array so
    // primitives whose cull distances cause no-op fragments still
    // get clipped per-pixel (matches how drivers emulate cull_distance
    // on APIs that don't natively support it). The combined array
    // size is clip + cull, and the write loop below feeds clip first
    // then cull into it.
    const std::uint32_t totalClipN = draw.clipDistanceLen + draw.cullDistanceLen;
    if (totalClipN > 0) {
        src += "    float gl_ClipDistance [[clip_distance]] [";
        src += std::to_string(totalClipN);
        src += "];\n";
    }
    // Metal point-output pipelines need [[point_size]] on the VS
    // output; without it, GL_POINTS tests render 0-sized / invisible
    // points on Apple GPUs. Emit unconditionally at size 1.0 — the
    // actual GS may have written gl_PointSize, but capturing that
    // per vertex would require extra plumbing; for the rendering
    // tests 1.0 matches the expected behaviour.
    if (draw.topology == GL_POINTS) {
        src += "    float gl_PointSize [[point_size]];\n";
    }
    // Layered output. The GS wrote gl_Layer per vertex; we forward
    // it to Metal's render-target array index so the rasteriser
    // routes each primitive to the correct slice of a layered FBO
    // attachment (MTLRenderPassDescriptor.renderTargetArrayLength
    // must also be set on the encoder side). Per GL 4.6 §11.2.1
    // and Metal spec, the value used for the whole primitive comes
    // from the provoking vertex, but MSL handles that routing — we
    // emit the per-vertex value.
    if (emitRenderTargetArrayIndex) {
        src += "    uint gl_Layer [[render_target_array_index]];\n";
    }
    // Sprint 15 Day 10 [metal-viewport-array]: per-vertex viewport
    // selection slot (sister to render_target_array_index).
    if (emitViewportArrayIndex) {
        src += "    uint gl_ViewportIndex [[viewport_array_index]];\n";
    }
    for (std::size_t i = 0; i < slotWidths.size(); ++i) {
        const std::uint32_t loc = (i < slotLocations.size())
            ? slotLocations[i] : static_cast<std::uint32_t>(i);
        const std::uint8_t interp = (i < slotInterp.size())
            ? slotInterp[i] : 0;
        const std::uint8_t bt = (i < slotBaseType.size())
            ? slotBaseType[i] : 0;
        // Integer varyings MUST be flat — Metal spec and MSL compiler
        // both enforce this. If we got here with smooth on an int
        // varying, force flat.
        const std::uint8_t effInterp = (bt != 0 && interp == 0) ? 1 : interp;
        src += "    ";
        src += mslTypeFor(slotWidths[i], bt);
        src += " vsout_v";
        src += std::to_string(i);
        src += " [[user(locn";
        src += std::to_string(loc);
        src += ")";
        src += interpTag(effInterp);
        src += "]];\n";
    }
    // gl_PrimitiveID routing slot (see EmulatedDraw::primitiveIDLocation).
    // Matched by the FS post-processor that redirects reads from
    // Metal's `[[primitive_id]]` to this flat-int varying.
    if (draw.hasPrimitiveID) {
        src += "    int vsout_prim_id [[user(locn";
        src += std::to_string(draw.primitiveIDLocation);
        src += "), flat]];\n";
    }
    src += "};\n\n";

    // ─ Entry. The `device const float* gs_packed` parameter shares
    // the same Metal buffer slot 0 as the stage_in vertex fetcher, so
    // both views resolve to the same per-vertex data without an extra
    // bind on the encoder side. `[[vertex_id]]` lets us index into
    // gs_packed for the trailing slots that no longer have stage_in
    // attributes (Sprint 7 #6 / CKPT58).
    if (needsTrailingBuffer) {
        src += "vertex VsOut main0(VsIn in [[stage_in]],\n";
        src += "                   uint gs_vid [[vertex_id]],\n";
        src += "                   device const float* gs_packed [[buffer(0)]])\n";
    } else {
        src += "vertex VsOut main0(VsIn in [[stage_in]])\n";
    }
    src += "{\n";
    src += "    VsOut out = {};\n";
    src += "    out.gl_Position = in.vsin_position;\n";
    // GL→Metal depth fixup. Mirrors what SPIRV-Cross emits for every
    // non-geometry VS today.
    src += "    out.gl_Position.z = (out.gl_Position.z + out.gl_Position.w) * 0.5;\n";
    if (draw.topology == GL_POINTS) {
        // If the GS captured a per-vertex gl_PointSize, feed it
        // through; otherwise keep the historical default 1.0.
        // CTS `output.primite_end_done_for_single_primitive` writes
        // gl_PointSize = 2.0 from the GS and expects a 2×2-pixel
        // point at NDC (-1,-1) — the fixed 1.0 previously made the
        // test fail on the bottom-left verifyPixel check.
        if (draw.hasPointSize) {
            // Read pointsize from the packed buffer at the right
            // per-vertex offset (CKPT58: was [[stage_in]] attribute,
            // now manual buffer access to avoid the 31-attribute
            // hardware cap).
            src += "    out.gl_PointSize = gs_packed[gs_vid * ";
            src += std::to_string(strideFloats);
            src += " + ";
            src += std::to_string(psFloatOff);
            src += "];\n";
        } else {
            src += "    out.gl_PointSize = 1.0;\n";
        }
    }
    for (std::size_t i = 0; i < slotWidths.size(); ++i) {
        src += "    out.vsout_v";
        src += std::to_string(i);
        src += " = in.vsin_v";
        src += std::to_string(i);
        src += ";\n";
    }
    // Fill gl_ClipDistance with clip values then cull values. MSL
    // requires constant-index array writes, which is fine at the
    // synthesis level because we know the length.
    for (std::uint32_t i = 0; i < draw.clipDistanceLen; ++i) {
        src += "    out.gl_ClipDistance[";
        src += std::to_string(i);
        src += "] = in.vsin_clip";
        src += std::to_string(i);
        src += ";\n";
    }
    for (std::uint32_t i = 0; i < draw.cullDistanceLen; ++i) {
        src += "    out.gl_ClipDistance[";
        src += std::to_string(draw.clipDistanceLen + i);
        src += "] = in.vsin_cull";
        src += std::to_string(i);
        src += ";\n";
    }
    // Route layer index to render_target_array_index. Cast to uint
    // because MSL spec requires the attribute type to be uint; we
    // read it as `int` (signed) from the packed buffer to preserve
    // negative values during transport (which would be a spec
    // violation on the GS side anyway — GL clamps gl_Layer at 0).
    // Only when the FBO is layered — otherwise we'd write a slot
    // Metal doesn't accept given renderTargetArrayLength=0.
    if (emitRenderTargetArrayIndex) {
        // CKPT58: read gl_Layer from packed buffer (was vsin_layer
        // [[attribute(N)]] before the 31-attribute cap fix). The int
        // value lives bit-cast in the float slot so we go through
        // `as_type<int>(...)` to recover the signed integer.
        src += "    out.gl_Layer = uint(max(as_type<int>(gs_packed[gs_vid * ";
        src += std::to_string(strideFloats);
        src += " + ";
        src += std::to_string(layerFloatOff);
        src += "]), 0));\n";
    }
    // Sprint 15 Day 10 [metal-viewport-array]: read gl_ViewportIndex
    // from packed buffer (sister to gl_Layer).
    if (emitViewportArrayIndex) {
        src += "    out.gl_ViewportIndex = uint(max(as_type<int>(gs_packed[gs_vid * ";
        src += std::to_string(strideFloats);
        src += " + ";
        src += std::to_string(viFloatOff);
        src += "]), 0));\n";
    }
    if (draw.hasPrimitiveID) {
        // CKPT58: read gl_PrimitiveID from packed buffer (was
        // vsin_prim_id [[attribute(N)]] before the cap fix). Same
        // bit-cast pattern as gl_Layer.
        src += "    out.vsout_prim_id = as_type<int>(gs_packed[gs_vid * ";
        src += std::to_string(strideFloats);
        src += " + ";
        src += std::to_string(pidFloatOff);
        src += "]);\n";
    }
    src += "    return out;\n";
    src += "}\n";
    return src;
}

std::string rewriteFragmentMSLForPrimitiveID(const std::string& fsMsl,
                                              const EmulatedDraw& draw)
{
    if (!draw.hasPrimitiveID) return fsMsl;
    // SPIRV-Cross emits the primitive_id parameter with a fixed
    // shape on macOS. Search for the unique substring — if absent,
    // the FS doesn't read gl_PrimitiveID and there's nothing to
    // rewrite (shouldn't happen because hasPrimitiveID only flips
    // when the GS wrote gl_PrimitiveID, but the FS could still
    // ignore it).
    const std::string primIdParam = "uint gl_PrimitiveID [[primitive_id]]";
    const std::size_t paramPos = fsMsl.find(primIdParam);
    if (paramPos == std::string::npos) return fsMsl;

    // Walk forward to the end of the full `fragment main0_out
    // main0(...)` parameter list — we'll rewrite its contents to
    // remove the primitive_id parameter and, if needed, add the
    // GS-prim-id stage_in parameter.
    //
    // Three cases for the original signature (SPIRV-Cross output):
    //   A) single param :  `main0(uint gl_PrimitiveID [[primitive_id]])`
    //   B) first param  :  `main0(uint gl_PrimitiveID [[primitive_id]], main0_in in [[stage_in]], …)`
    //   C) non-first    :  `main0(main0_in in [[stage_in]], uint gl_PrimitiveID [[primitive_id]], …)`
    //
    // For (A) we replace the whole primitive_id param with our
    // stage_in struct. For (B)/(C) we remove the primitive_id
    // param + its surrounding comma, and inject the new
    // struct-field into the existing main0_in. Only case (A)
    // applies to CTS `primitive_id_from_fragment` — cases (B)/(C)
    // need the deeper struct-injection path which we implement
    // when we first hit a test that triggers them.

    // Locate the `fragment <return-type> main0(` line. We find
    // `main0(` first, then walk backwards to the start of that
    // line so our struct definition can be injected on its own
    // line immediately before the function signature.
    const std::size_t mainPos = fsMsl.rfind("main0(", paramPos);
    if (mainPos == std::string::npos) return fsMsl;
    std::size_t sigLineStart = fsMsl.rfind('\n', mainPos);
    if (sigLineStart == std::string::npos) {
        sigLineStart = 0;
    } else {
        ++sigLineStart;   // past the '\n' itself
    }
    // Find the matching closing paren for the parameter list.
    std::size_t depth = 1;
    std::size_t parenEnd = mainPos + 6;   // past "main0("
    while (parenEnd < fsMsl.size() && depth > 0) {
        if (fsMsl[parenEnd] == '(') ++depth;
        else if (fsMsl[parenEnd] == ')') --depth;
        if (depth == 0) break;
        ++parenEnd;
    }
    if (depth != 0) return fsMsl;

    // Inspect param list to classify A (single primitive_id) vs
    // B/C (multiple params). Case A is what CTS
    // primitive_id_from_fragment uses; B/C need struct-injection
    // into an existing main0_in — not yet implemented.
    const std::size_t paramListStart = mainPos + 6;
    const std::string paramList = fsMsl.substr(paramListStart, parenEnd - paramListStart);
    const bool isCaseA = (paramList.find(',') == std::string::npos);
    if (!isCaseA) return fsMsl;

    // Everything between `main0(` and `)`, i.e. `paramList`, is
    // the original parameter (just the primitive_id). We build
    // the rewritten MSL by replacing that whole signature line
    // with our own, with the struct definition preceding it.
    //
    // Find the opening brace that starts the function body.
    std::size_t braceStart = parenEnd + 1;
    while (braceStart < fsMsl.size() && fsMsl[braceStart] != '{') {
        ++braceStart;
    }
    if (braceStart >= fsMsl.size()) return fsMsl;

    // Salvage the original signature prefix (`fragment main0_out `
    // or similar) between line-start and `main0(` — we reuse it
    // so the rewritten function keeps the original return type
    // and any fragment-qualifier attributes SPIRV-Cross emitted.
    const std::string sigPrefix = fsMsl.substr(sigLineStart, mainPos - sigLineStart);

    std::string out;
    out.reserve(fsMsl.size() + 256);

    // Prologue: everything before the function signature line.
    out.append(fsMsl, 0, sigLineStart);

    // Inject a GS-prim-id stage_in struct immediately above the
    // function signature, on its own line block.
    out.append("struct _gs_fs_in {\n");
    out.append("    int _gs_prim_id [[user(locn");
    out.append(std::to_string(draw.primitiveIDLocation));
    out.append("), flat]];\n");
    out.append("};\n\n");

    // Rebuilt function signature: original prefix + main0 with
    // our stage_in parameter replacing the old [[primitive_id]]
    // one. Keep any whitespace between `)` and `{` that was in
    // the original for formatting parity.
    out.append(sigPrefix);
    out.append("main0(_gs_fs_in _gs_in [[stage_in]])");
    out.append(fsMsl, parenEnd + 1, braceStart - (parenEnd + 1));

    // Opening brace + GS-prim-id shadow local, then the rest of
    // the body unchanged. The local shadows the dropped
    // parameter so existing `gl_PrimitiveID` references bind to
    // our injected value without further edits.
    out.append("{\n");
    out.append("    uint gl_PrimitiveID = uint(_gs_in._gs_prim_id);\n");
    out.append(fsMsl, braceStart + 1, std::string::npos);
    return out;
}

std::string rewriteFragmentMSLForFp64StageIn(const std::string& fsMsl)
{
    const std::string structNeedle = "struct main0_in";
    const std::size_t structPos = fsMsl.find(structNeedle);
    if (structPos == std::string::npos ||
        fsMsl.find("appgl_df64", structPos) == std::string::npos) {
        return fsMsl;
    }

    const std::size_t braceOpen = fsMsl.find('{', structPos);
    if (braceOpen == std::string::npos) return fsMsl;
    const std::size_t braceClose = fsMsl.find("};", braceOpen);
    if (braceClose == std::string::npos) return fsMsl;

    struct FieldRewrite {
        std::string name;
        std::string fp64Type;
        std::string transportType;
    };
    std::vector<FieldRewrite> fields;

    auto transportTypeFor = [](const std::string& type) -> std::string {
        if (type == "appgl_df64") return "float";
        if (type == "appgl_df64x2") return "float2";
        if (type == "appgl_df64x3") return "float3";
        if (type == "appgl_df64x4") return "float4";
        return {};
    };
    auto isIdent = [](char c) {
        return std::isalnum(static_cast<unsigned char>(c)) || c == '_';
    };

    std::string rewrittenStruct;
    rewrittenStruct.reserve(braceClose - braceOpen + 64);
    std::size_t lineStart = braceOpen + 1;
    while (lineStart < braceClose) {
        std::size_t lineEnd = fsMsl.find('\n', lineStart);
        if (lineEnd == std::string::npos || lineEnd > braceClose) {
            lineEnd = braceClose;
        }
        std::string line = fsMsl.substr(lineStart, lineEnd - lineStart);
        const std::size_t typePos = line.find("appgl_df64");
        const std::size_t userPos = line.find("[[user(locn");
        bool rewrote = false;
        if (typePos != std::string::npos && userPos != std::string::npos) {
            std::size_t typeEnd = typePos;
            while (typeEnd < line.size() && isIdent(line[typeEnd])) ++typeEnd;
            const std::string fp64Type = line.substr(typePos, typeEnd - typePos);
            const std::string transportType = transportTypeFor(fp64Type);
            if (!transportType.empty()) {
                std::size_t nameStart = typeEnd;
                while (nameStart < line.size() &&
                       std::isspace(static_cast<unsigned char>(line[nameStart]))) {
                    ++nameStart;
                }
                std::size_t nameEnd = nameStart;
                while (nameEnd < line.size() && isIdent(line[nameEnd])) ++nameEnd;
                if (nameEnd > nameStart) {
                    fields.push_back({
                        line.substr(nameStart, nameEnd - nameStart),
                        fp64Type,
                        transportType
                    });
                    line.replace(typePos, fp64Type.size(), transportType);
                    rewrote = true;
                }
            }
        }
        (void)rewrote;
        rewrittenStruct += line;
        if (lineEnd < braceClose) rewrittenStruct += '\n';
        lineStart = lineEnd + 1;
    }

    if (fields.empty()) return fsMsl;

    std::string out;
    out.reserve(fsMsl.size() + fields.size() * 32);
    out.append(fsMsl, 0, braceOpen + 1);
    out.append(rewrittenStruct);
    out.append(fsMsl, braceClose, std::string::npos);

    const std::size_t bodyStart = out.find("main0(", structPos);
    if (bodyStart == std::string::npos) return out;

    for (const auto& field : fields) {
        const std::string needle = "in." + field.name;
        const std::string replacement = "appgl_df64_from_float(" + needle + ")";
        std::size_t pos = bodyStart;
        while ((pos = out.find(needle, pos)) != std::string::npos) {
            const bool leftOk =
                (pos == 0) || !isIdent(out[pos - 1]);
            const std::size_t right = pos + needle.size();
            const bool rightOk =
                (right >= out.size()) || !isIdent(out[right]);
            if (leftOk && rightOk) {
                out.replace(pos, needle.size(), replacement);
                pos += replacement.size();
            } else {
                pos += needle.size();
            }
        }
    }

    return out;
}

std::unordered_set<std::string> scanStageReferencedUniforms(
    const std::vector<std::uint32_t>& spirv)
{
    std::unordered_set<std::string> out;
    if (spirv.empty()) return out;
    SpirvModule mod;
    if (!mod.parse(spirv.data(), spirv.size())) return out;
    if (!mod.haveFuncBody) return out;

    // Classify each uniform variable's struct type and its block
    // name (from OpName on the struct) + whether it's an
    // instanced block (variable name != struct type name). We use
    // the variable id as the key for access-chain base matching.
    struct UniformVarInfo {
        std::uint32_t structTypeId = 0;
        std::string varName;      // OpName on the variable
        std::string blockName;    // OpName on the struct type
        bool isStorageBuffer = false;
        bool isBlockInstanced = false;
    };
    std::unordered_map<std::uint32_t, UniformVarInfo> uniformVars;
    for (const auto& [varId, vinfo] : mod.variables) {
        if (vinfo.storageClass != spv::StorageClassUniform &&
            vinfo.storageClass != spv::StorageClassUniformConstant) {
            continue;
        }
        auto tIt = mod.types.find(vinfo.typeId);
        if (tIt == mod.types.end()) continue;
        std::uint32_t pointeeId = tIt->second.pointeeType;
        auto pIt = mod.types.find(pointeeId);
        if (pIt == mod.types.end()) continue;
        // Unwrap array-of-struct (UBO array) — we record the
        // element struct since access chains index into it.
        if (pIt->second.kind == TypeInfo::Kind::Array) {
            pointeeId = pIt->second.componentType;
            pIt = mod.types.find(pointeeId);
            if (pIt == mod.types.end()) continue;
        }
        if (pIt->second.kind != TypeInfo::Kind::Struct) continue;
        // Only Block / BufferBlock-decorated structs count here —
        // non-block Uniform-storage structs are function-scope
        // locals we don't care about.
        auto sd = mod.decorations.find(pointeeId);
        if (sd == mod.decorations.end() || !sd->second.isBlock) continue;
        UniformVarInfo uvi;
        uvi.structTypeId = pointeeId;
        uvi.varName = vinfo.name;
        auto structNameIt = mod.names.find(pointeeId);
        uvi.blockName = (structNameIt != mod.names.end())
            ? structNameIt->second : "";
        // Instanced iff the GLSL provided an instance name AND it
        // differs from the struct type name. SPIR-V keeps the
        // struct name (e.g. "Colors") as the OpName on the type
        // while the variable carries either the type name (no
        // instance) or the instance name. Matching what
        // SPIRV-Cross's reflection exposes.
        uvi.isBlockInstanced = (!uvi.varName.empty() && uvi.varName != uvi.blockName);
        // Storage class tells us UBO vs SSBO when BufferBlock
        // wasn't used — newer SPIR-V marks SSBOs via
        // StorageClassStorageBuffer (12) but older glslang still
        // uses Uniform + BufferBlock decoration.
        if (vinfo.storageClass == 12 /*StorageClassStorageBuffer*/) {
            uvi.isStorageBuffer = true;
        }
        uniformVars[varId] = std::move(uvi);
    }

    // Walk function body; for each OpAccessChain whose base is a
    // uniform variable, pick out the first-index constant to
    // identify which member was accessed and record
    // "BlockName.memberName" (or just "memberName" for non-
    // instanced default blocks — matching GL_UNIFORM naming).
    std::size_t pc = mod.funcBodyStart;
    while (pc < mod.funcBodyEnd) {
        const std::uint32_t inst = mod.words[pc];
        const std::uint16_t opcode = static_cast<std::uint16_t>(inst & 0xFFFF);
        const std::uint16_t wc = static_cast<std::uint16_t>(inst >> 16);
        if (wc == 0) break;
        if (opcode == spv::OpAccessChain && wc >= 5) {
            const std::uint32_t base = mod.words[pc + 3];
            auto uvIt = uniformVars.find(base);
            if (uvIt != uniformVars.end()) {
                const std::uint32_t firstIdxId = mod.words[pc + 4];
                auto cIt = mod.constants.find(firstIdxId);
                if (cIt != mod.constants.end()) {
                    const std::uint32_t memberIdx =
                        static_cast<std::uint32_t>(cIt->second.i[0]);
                    auto mnIt = mod.memberNames.find(uvIt->second.structTypeId);
                    if (mnIt != mod.memberNames.end()) {
                        auto mNameIt = mnIt->second.find(memberIdx);
                        if (mNameIt != mnIt->second.end()) {
                            // Record both the bare member name
                            // (GL_UNIFORM name for non-instanced
                            // default block) and the qualified
                            // "Block.member" form (for instanced
                            // blocks / SSBOs / GL_BUFFER_VARIABLE).
                            out.insert(mNameIt->second);
                            if (!uvIt->second.blockName.empty()) {
                                out.insert(uvIt->second.blockName + "." + mNameIt->second);
                            }
                            // Also record the block name itself so
                            // callers can test whether the block
                            // is referenced at all.
                            if (!uvIt->second.blockName.empty()) {
                                out.insert(uvIt->second.blockName);
                            }
                        }
                    }
                }
            }
        }
        pc += wc;
    }
    return out;
}

// ─── Public helper — one-off VS run for tess CPU emulator ───────────
//
// Wraps the anonymous-namespace Interpreter so external code
// (currently TessellationEmulator.cpp) can interpret the VS once per
// patch vertex without duplicating the parse + attrib-read + setup
// sequence. Returns false on any interpreter bail; `diagnostic`
// (when non-null) receives the interpreter's failure message.
bool runVsForVertex(
    const std::uint32_t* vsSpirv,
    std::size_t vsWordCount,
    const GLProgramObject& program,
    const GLVertexArrayObject& vao,
    const GLObjectStore& objects,
    std::size_t vboSlot,
    std::int32_t instanceID,
    const std::vector<std::string>& outVaryingNames,
    const std::vector<std::uint32_t>& outVaryingWidths,
    EmulatedVertex& outVertex,
    std::string* diagnostic,
    const SampledTextureMap* sampledTextures,
    const SampledTextureMap* storageImages,
    const Interpreter::UniformBufferMap* uniformBuffers,
    std::vector<PendingImageWrite>* pendingImageWrites)
{
    if (vsSpirv == nullptr || vsWordCount < 5) {
        if (diagnostic) *diagnostic = "runVsForVertex: empty SPIR-V";
        return false;
    }
    SpirvModule vsMod;
    if (!vsMod.parse(vsSpirv, vsWordCount)) {
        if (diagnostic) *diagnostic = "runVsForVertex: SpirvModule parse: " + vsMod.parseError;
        return false;
    }

    // Build uniform map + vertex-attribute map the Interpreter expects.
    // `buildUniformMap` + the VAO fetch-source helpers live in the
    // anon namespace alongside the Interpreter — same TU, so we can
    // call them here.
    Interpreter::UniformValues uniforms = buildUniformMap(program);

    // VAO shadow reads take non-const GLObjectStore&
    // because the BufferObject shadow-pointer readback path is
    // non-const. We cast away the const on the caller's input since
    // we're only reading — future readVertexAttribFromVAO could be
    // made const but that's a GSE-internal refactor for another iter.
    GLObjectStore& mutableObjects = const_cast<GLObjectStore&>(objects);

    Interpreter::VertexAttribs vsAttribs;
    const std::vector<VsAttribFetchSource> vsAttribSources =
        buildVsAttribFetchSources(vao, mutableObjects);
    for (const auto& src : vsAttribSources) {
        // Disabled attributes still feed the VS from current generic state.
        Value v = readVertexAttribFromSource(src, vboSlot, instanceID);
        if (v.kind != Value::Kind::Invalid) {
            vsAttribs[src.location] = v;
        }
    }

    // Sprint 17 Day 7+ Bank-Group-H Path B Phase 3 day 5 — build the
    // base-name → base-Location override map for the interpreter from
    // `program.vertexReflection.vertexInputs` (SPIRV-Cross's reflection
    // recovers explicit `layout(location=N)` qualifiers, including for
    // arrays-of-floats whose per-element entries SPIRV-Cross splits as
    // `name[K]` in the reflection list). Key = base name (`[K]` suffix
    // stripped); value = minimum location across split entries (i.e.,
    // location of element [0]). The interpreter consumes this map in
    // `initVariables` to override implicit auto-assign for variables
    // that lack `OpDecorate <var> Location <N>` in the SPIR-V (sister
    // precedent: glslang's xfb path strips those decorations from
    // certain inputs while still emitting per-element Location info
    // SPIRV-Cross can recover at MSL-emit time).
    std::unordered_map<std::string, std::uint32_t> vsInputLocOverrides =
        buildVsInputLocationOverrides(program);
    // Link-time GLProgramObject::attributes is the authoritative GL view:
    // it folds in glBindAttribLocation requests, which SPIRV-Cross
    // reflection cannot observe from raw SPIR-V. VS-only TF tests that bind
    // a_0, a_2, ... to sparse locations need those exact indices.

    Interpreter vsInterp(vsMod, Interpreter::Stage::Vertex,
                         outVaryingNames, outVaryingWidths);
    vsInterp.setUniforms(&uniforms);
    vsInterp.setVsInputs(&vsAttribs,
                         static_cast<std::int32_t>(vboSlot), instanceID);
    if (!vsInputLocOverrides.empty()) {
        vsInterp.setVsInputLocationOverrides(&vsInputLocOverrides);
    }
    if (sampledTextures != nullptr) {
        vsInterp.setSampledTextures(sampledTextures);
    }
    if (storageImages != nullptr) {
        vsInterp.setStorageImages(storageImages);
    }
    // Sprint 17 Day 4+ BONUS-2 [gpu_shader5 array-indexing]: caller
    // can pass a pre-built UBO array map (per-binding shadow bytes
    // for any `uniform Block { ... } arr[N]` declared in the VS).
    // Built once per draw in `emulateVsOnlyDrawForTf` (has state +
    // objects access); reused across all per-vertex invocations.
    if (uniformBuffers != nullptr) {
        vsInterp.setUniformBuffers(uniformBuffers);
    }

    outVertex.position[0] = outVertex.position[1] = outVertex.position[2] = 0.0f;
    outVertex.position[3] = 1.0f;
    if (!vsInterp.executeVs(outVertex)) {
        if (diagnostic) *diagnostic = "runVsForVertex: VS body: " + vsInterp.diagnostic();
        return false;
    }
    if (pendingImageWrites != nullptr) {
        auto writes = vsInterp.takePendingImageWrites();
        for (auto& write : writes) {
            write.stage = GL_VERTEX_SHADER;
        }
        pendingImageWrites->insert(pendingImageWrites->end(),
                                   std::make_move_iterator(writes.begin()),
                                   std::make_move_iterator(writes.end()));
    }
    return true;
}

// Phase 3f-12: namespace-level wrapper so the tess emul draw path
// (in TessellationEmulator.cpp) can pre-build the uniform map once
// per draw and pass it to every runTes/TcsForVertex invocation.
TesUniformMap buildTesUniformMap(const GLProgramObject& program) {
    return buildUniformMap(program);
}

bool runTesForVertex(
    const std::uint32_t* tesSpirv,
    std::size_t tesWordCount,
    const GLProgramObject& program,
    const std::array<float, 3>& tessCoord,
    std::int32_t primitiveID,
    const std::vector<std::string>& outVaryingNames,
    const std::vector<std::uint32_t>& outVaryingWidths,
    const TesSsboMap* ssboMap,
    const std::vector<EmulatedVertex>& patchInputs,
    EmulatedVertex& outVertex,
    const TesUniformMap* precomputedUniforms,
    const TesPatchVaryingMap* patchVaryings,
    std::string* diagnostic,
    const std::vector<std::string>* inVaryingNames,
    const std::vector<std::uint32_t>* inVaryingWidths,
    const SampledTextureMap* sampledTextures,
    const SampledTextureMap* storageImages,
    const Interpreter::UniformBufferMap* uniformBuffers,
    std::vector<PendingImageWrite>* pendingImageWrites)
{
    if (tesSpirv == nullptr || tesWordCount < 5) {
        if (diagnostic) *diagnostic = "runTesForVertex: empty SPIR-V";
        return false;
    }
    // Phase 3f-11: use the cached parsed SpirvModule on the program
    // object when one exists; otherwise parse once and install into
    // the cache so subsequent (patch, invocation) calls don't re-parse.
    // Cache invalidation happens at link time (see tessEvalSpirv =
    // shader->spirv in GLContext.mm, which resets the unique_ptr).
    if (!program.tessEvalParsedModule) {
        auto fresh = std::make_unique<SpirvModule>();
        if (!fresh->parse(tesSpirv, tesWordCount)) {
            if (diagnostic) *diagnostic =
                "runTesForVertex: SpirvModule parse: " + fresh->parseError;
            return false;
        }
        program.tessEvalParsedModule = std::move(fresh);
    }
    const SpirvModule& tesMod = *program.tessEvalParsedModule;

    // Phase 3f-12: use the caller's pre-built uniform map when
    // supplied; otherwise build one on the spot (legacy behaviour).
    // The pre-built path is the tess-emul draw loop's hot path —
    // avoids rebuilding `program.uniforms × uniformValues` per
    // generated domain vertex.
    Interpreter::UniformValues localUniforms;
    const Interpreter::UniformValues* uniformsPtr = nullptr;
    if (precomputedUniforms != nullptr) {
        uniformsPtr = precomputedUniforms;
    } else {
        localUniforms = buildUniformMap(program);
        uniformsPtr = &localUniforms;
    }
    const Interpreter::UniformValues& uniforms = *uniformsPtr;

    // Re-use the VS-shape constructor (second overload). It expects
    // `outputVaryingNames_/Widths_` — which is what the matched TES
    // body produces as its user-varying output — and produces an
    // `EmulatedVertex` via `executeTes` (phase 3f-5) or `executeVs`
    // (phase 3f-2 no-gl_in[] shortcut). Stage::TessEvaluation drives
    // the built-in init seeding inside initVariables.
    Interpreter tesInterp(tesMod, Interpreter::Stage::TessEvaluation,
                          outVaryingNames, outVaryingWidths);
    tesInterp.setUniforms(&uniforms);
    if (uniformBuffers != nullptr) {
        tesInterp.setUniformBuffers(uniformBuffers);
    }
    tesInterp.setTesInputs(tessCoord, primitiveID);

    // Sprint 8 #8 β.2 (CKPT69): wire cross-stage input varying names
    // (= TCS user-block-output member names, or VS user-block-output
    // member names if there's no TCS) so the Interpreter's gl_in[]
    // user-block-member arm at the bottom of initVariables can resolve
    // `in OUT_TC { vec4 tc_position; ... } in_data[];` reads against
    // the per-vertex slice of patchInputs[k].varyings.
    if (inVaryingNames != nullptr && inVaryingWidths != nullptr) {
        tesInterp.setInputVaryings(*inVaryingNames, *inVaryingWidths);
    }

    // Phase 3f-3: convert public TesSsboMap → Interpreter::StorageBufferMap.
    // Same underlying shape (binding → ptr+size); separate types so the
    // Interpreter's public header doesn't leak through GSE.h.
    Interpreter::StorageBufferMap ssboInterp;
    if (ssboMap != nullptr) {
        for (const auto& [binding, region] : *ssboMap) {
            Interpreter::StorageBufferRegion r;
            r.ptr = region.ptr;
            r.size = region.size;
            ssboInterp[binding] = r;
        }
    }
    tesInterp.setStorageBuffers(&ssboInterp);

    // Sprint 16 Day 6 (CKPT215) — Tess OpImage gap. Sister-pattern to
    // VS pre-pass for tess at GSE.cpp:5486-5491: TES bodies that call
    // texture()/texelFetch()/imageLoad()/imageStore() now resolve
    // through these maps. Without these wires, OpImageSample*/Read/
    // Write ops hit the empty-map fallback at GSE.cpp:2845-2853 and
    // silently return zeros.
    if (sampledTextures != nullptr) {
        tesInterp.setSampledTextures(sampledTextures);
    }
    if (storageImages != nullptr) {
        tesInterp.setStorageImages(storageImages);
    }

    // Phase 3f-14: wire the patch-varying map. Interpreter's TES
    // initVariables arm pulls Input-Patch-Location varying values
    // from here.
    tesInterp.setTesPatchInputs(patchVaryings);

    // Phase 3f-5: convert per-patch EmulatedVertex inputs (position +
    // clip/cull) into PerVertexInput records the interpreter's
    // gl_in[] init path consumes.
    // Sprint 8 #8 β.2 (CKPT69): also slice the EmulatedVertex's
    // concatenated `varyings` buffer into per-varying separate
    // vectors using inVaryingWidths. The Interpreter's user-block
    // member-name arm walks this list keyed by inVaryingNames index.
    std::vector<Interpreter::PerVertexInput> inputs;
    inputs.reserve(patchInputs.size());
    for (const auto& pv : patchInputs) {
        Interpreter::PerVertexInput pvi;
        pvi.position[0] = pv.position[0];
        pvi.position[1] = pv.position[1];
        pvi.position[2] = pv.position[2];
        pvi.position[3] = pv.position[3];
        pvi.clipDistance = pv.clipDistance;
        pvi.cullDistance = pv.cullDistance;
        pvi.pointSize = pv.pointSize;
        if (inVaryingWidths != nullptr && !inVaryingWidths->empty()) {
            pvi.varyings.resize(inVaryingWidths->size());
            std::size_t srcOff = 0;
            for (std::size_t k = 0; k < inVaryingWidths->size(); ++k) {
                const std::uint32_t w = (*inVaryingWidths)[k];
                pvi.varyings[k].assign(w, 0.0f);
                for (std::uint32_t j = 0; j < w && srcOff + j < pv.varyings.size(); ++j) {
                    pvi.varyings[k][j] = pv.varyings[srcOff + j];
                }
                srcOff += w;
            }
        }
        inputs.push_back(std::move(pvi));
    }

    outVertex.position[0] = outVertex.position[1] = outVertex.position[2] = 0.0f;
    outVertex.position[3] = 1.0f;
    const bool ok = inputs.empty()
        ? tesInterp.executeVs(outVertex)
        : tesInterp.executeTes(outVertex, inputs);
    if (!ok) {
        if (diagnostic) *diagnostic = "runTesForVertex: TES body: " + tesInterp.diagnostic();
        return false;
    }
    if (pendingImageWrites != nullptr) {
        auto writes = tesInterp.takePendingImageWrites();
        for (auto& write : writes) {
            write.stage = GL_TESS_EVALUATION_SHADER;
        }
        pendingImageWrites->insert(pendingImageWrites->end(),
                                   std::make_move_iterator(writes.begin()),
                                   std::make_move_iterator(writes.end()));
    }
    return true;
}

bool runTcsForVertex(
    const std::uint32_t* tcsSpirv,
    std::size_t tcsWordCount,
    const GLProgramObject& program,
    std::int32_t primitiveID,
    std::int32_t invocationID,
    std::int32_t patchVertices,
    const TesSsboMap* ssboMap,
    const std::vector<EmulatedVertex>& patchInputs,
    EmulatedVertex& outVertex,
    float* outerLevelsOut,
    float* innerLevelsOut,
    const TesUniformMap* precomputedUniforms,
    TesPatchVaryingMap* patchVaryingsOut,
    std::string* diagnostic,
    const std::vector<std::string>* inVaryingNames,
    const std::vector<std::uint32_t>* inVaryingWidths,
    const std::vector<std::string>* outVaryingNames,
    const std::vector<std::uint32_t>* outVaryingWidths,
    const SampledTextureMap* sampledTextures,
    const SampledTextureMap* storageImages,
    const Interpreter::UniformBufferMap* uniformBuffers,
    std::vector<PendingImageWrite>* pendingImageWrites,
    TcsSharedOutputStorage* sharedOutputStorage)
{
    if (tcsSpirv == nullptr || tcsWordCount < 5) {
        if (diagnostic) *diagnostic = "runTcsForVertex: empty SPIR-V";
        return false;
    }
    // Phase 3f-11: reuse cached parsed module when available; parse
    // once + install on miss. Invalidated on re-link alongside
    // tessControlSpirv.
    if (!program.tessControlParsedModule) {
        auto fresh = std::make_unique<SpirvModule>();
        if (!fresh->parse(tcsSpirv, tcsWordCount)) {
            if (diagnostic) *diagnostic =
                "runTcsForVertex: SpirvModule parse: " + fresh->parseError;
            return false;
        }
        program.tessControlParsedModule = std::move(fresh);
    }
    const SpirvModule& tcsMod = *program.tessControlParsedModule;

    // Phase 3f-12: use caller's precomputed uniform map when
    // available to avoid per-invocation rebuild.
    Interpreter::UniformValues localUniforms;
    const Interpreter::UniformValues* uniformsPtr = nullptr;
    if (precomputedUniforms != nullptr) {
        uniformsPtr = precomputedUniforms;
    } else {
        localUniforms = buildUniformMap(program);
        uniformsPtr = &localUniforms;
    }
    const Interpreter::UniformValues& uniforms = *uniformsPtr;

    // Sprint 8 #8 β.2 (CKPT69): when caller supplies the TCS user-block
    // output member names + widths, the Interpreter walks them after
    // the body executes and `captureTcsOutputForInvocation` returns the
    // captured per-vertex user-block payload alongside gl_PerVertex
    // builtins. When unsupplied (default), TCS keeps the legacy
    // builtin-only output capture (passthrough TCS path).
    static const std::vector<std::string>   kEmptyNames;
    static const std::vector<std::uint32_t> kEmptyWidths;
    const std::vector<std::string>&   tcsOutNames =
        (outVaryingNames != nullptr) ? *outVaryingNames : kEmptyNames;
    const std::vector<std::uint32_t>& tcsOutWidths =
        (outVaryingWidths != nullptr) ? *outVaryingWidths : kEmptyWidths;

    Interpreter tcsInterp(tcsMod, Interpreter::Stage::TessControl,
                          tcsOutNames, tcsOutWidths);
    tcsInterp.setUniforms(&uniforms);
    if (uniformBuffers != nullptr) {
        tcsInterp.setUniformBuffers(uniformBuffers);
    }
    tcsInterp.setTcsInputs(primitiveID, invocationID, patchVertices);
    tcsInterp.setTcsSharedOutputStorage(sharedOutputStorage);

    // Sprint 8 #8 β.2 (CKPT69): cross-stage input varying interface for
    // TCS gl_in[].user_block.member name resolution.
    if (inVaryingNames != nullptr && inVaryingWidths != nullptr) {
        tcsInterp.setInputVaryings(*inVaryingNames, *inVaryingWidths);
    }

    Interpreter::StorageBufferMap ssboInterp;
    if (ssboMap != nullptr) {
        for (const auto& [binding, region] : *ssboMap) {
            Interpreter::StorageBufferRegion r;
            r.ptr = region.ptr;
            r.size = region.size;
            ssboInterp[binding] = r;
        }
    }
    tcsInterp.setStorageBuffers(&ssboInterp);

    // Sprint 16 Day 6 (CKPT215) — Tess OpImage gap; sister to TES.
    if (sampledTextures != nullptr) {
        tcsInterp.setSampledTextures(sampledTextures);
    }
    if (storageImages != nullptr) {
        tcsInterp.setStorageImages(storageImages);
    }

    // Phase 3f-10: convert per-patch EmulatedVertex inputs (position +
    // clip/cull) into PerVertexInput so the interpreter's gl_in[]
    // init path seeds TCS's input array from the VS pre-pass.
    // Sprint 8 #8 β.2 (CKPT69): also slice user varyings (concatenated
    // in EmulatedVertex.varyings) into the per-varying separate
    // PerVertexInput.varyings vector using inVaryingWidths.
    std::vector<Interpreter::PerVertexInput> inputs;
    inputs.reserve(patchInputs.size());
    for (const auto& pv : patchInputs) {
        Interpreter::PerVertexInput pvi;
        pvi.position[0] = pv.position[0];
        pvi.position[1] = pv.position[1];
        pvi.position[2] = pv.position[2];
        pvi.position[3] = pv.position[3];
        pvi.clipDistance = pv.clipDistance;
        pvi.cullDistance = pv.cullDistance;
        pvi.pointSize = pv.pointSize;
        if (inVaryingWidths != nullptr && !inVaryingWidths->empty()) {
            pvi.varyings.resize(inVaryingWidths->size());
            std::size_t srcOff = 0;
            for (std::size_t k = 0; k < inVaryingWidths->size(); ++k) {
                const std::uint32_t w = (*inVaryingWidths)[k];
                pvi.varyings[k].assign(w, 0.0f);
                for (std::uint32_t j = 0; j < w && srcOff + j < pv.varyings.size(); ++j) {
                    pvi.varyings[k][j] = pv.varyings[srcOff + j];
                }
                srcOff += w;
            }
        }
        inputs.push_back(std::move(pvi));
    }

    EmulatedVertex scratch;
    scratch.position[0] = scratch.position[1] = scratch.position[2] = 0.0f;
    scratch.position[3] = 1.0f;
    const bool ok = inputs.empty()
        ? tcsInterp.executeVs(scratch)
        : tcsInterp.executeTes(scratch, inputs);
    if (!ok) {
        if (diagnostic) *diagnostic = "runTcsForVertex: TCS body: " + tcsInterp.diagnostic();
        return false;
    }
    if (pendingImageWrites != nullptr) {
        auto writes = tcsInterp.takePendingImageWrites();
        for (auto& write : writes) {
            write.stage = GL_TESS_CONTROL_SHADER;
        }
        pendingImageWrites->insert(pendingImageWrites->end(),
                                   std::make_move_iterator(writes.begin()),
                                   std::make_move_iterator(writes.end()));
    }
    if (sharedOutputStorage != nullptr) {
        tcsInterp.captureTcsSharedOutputs(*sharedOutputStorage);
    }

    // Phase 3f-10: capture gl_out[invocationID] — position + clip/cull
    // — from the Output-side gl_PerVertex array. Fallback to the
    // VS-pass input value for this slot if the TCS didn't write one
    // (common when TCS is a passthrough stub: it may write for some
    // invocation indices only).
    if (!tcsInterp.captureTcsOutputForInvocation(invocationID, outVertex)) {
        if (static_cast<std::size_t>(invocationID) < patchInputs.size()) {
            outVertex = patchInputs[invocationID];
        } else {
            outVertex.position[0] = 0.0f;
            outVertex.position[1] = 0.0f;
            outVertex.position[2] = 0.0f;
            outVertex.position[3] = 1.0f;
        }
    }

    // Phase 3f-8: capture tess-level writes. Only overwrite caller
    // arrays when non-null AND at least one level was written by the
    // TCS — unwritten slots keep whatever the caller pre-seeded
    // (typically the glPatchParameterfv defaults).
    if (outerLevelsOut != nullptr || innerLevelsOut != nullptr) {
        float capturedOuter[4] = {
            outerLevelsOut ? outerLevelsOut[0] : 1.0f,
            outerLevelsOut ? outerLevelsOut[1] : 1.0f,
            outerLevelsOut ? outerLevelsOut[2] : 1.0f,
            outerLevelsOut ? outerLevelsOut[3] : 1.0f,
        };
        float capturedInner[2] = {
            innerLevelsOut ? innerLevelsOut[0] : 1.0f,
            innerLevelsOut ? innerLevelsOut[1] : 1.0f,
        };
        (void)tcsInterp.captureTessLevelsPublic(capturedOuter, capturedInner);
        if (outerLevelsOut != nullptr) {
            for (int i = 0; i < 4; ++i) outerLevelsOut[i] = capturedOuter[i];
        }
        if (innerLevelsOut != nullptr) {
            for (int i = 0; i < 2; ++i) innerLevelsOut[i] = capturedInner[i];
        }
    }

    // Phase 3f-14: capture patch-out Output varyings into the
    // caller's map. Overwrites on conflict — last-write-wins across
    // invocations of the same patch.
    if (patchVaryingsOut != nullptr) {
        tcsInterp.captureTcsPatchOutputs(*patchVaryingsOut);
    }
    return true;
}

}  // namespace appgl
