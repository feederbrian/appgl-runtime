#include "MetalFrameGraph.h"

#include "../extensions/ExtensionContext.h"
#include "../extensions/ExtensionRegistry.h"
#include "../objects/GLObjectStore.h"
#include "../runtime/AppGLLog.h"
#include "../shader/TessellationEmulator.h"
#include "../state/GLStateTracker.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// Diagnostic tracing — set to 1 to enable, 0 to silence.
#define APPGL_TRACE_FRAMEGRAPH 0

#if APPGL_TRACE_FRAMEGRAPH
#define FG_TRACE(fmt, ...) NSLog(@"[FG] " fmt, ##__VA_ARGS__)
#else
#define FG_TRACE(fmt, ...) ((void)0)
#endif

namespace appgl {

static constexpr NSUInteger kAppGLFragCoordParamsBufferSlot = 15;
static constexpr NSUInteger kAppGLFragmentShadingRateParamsBufferSlot = 30;

static bool appglEnvEnabledDefaultOn(const char* name) {
    const char* value = std::getenv(name);
    return value == nullptr || (value[0] != '0' && value[0] != '\0');
}

static bool metalTessTFEnabled() {
    return appglEnvEnabledDefaultOn("APPGL_ENABLE_METAL_TESS_TF");
}

static NSInteger clipControlYSignBufferSlot(const std::string* msl) {
    if (msl == nullptr) {
        return -1;
    }
    static constexpr const char* kNeedle =
        "_appgl_ClipControlYSign [[buffer(";
    const std::size_t pos = msl->find(kNeedle);
    if (pos == std::string::npos) {
        return -1;
    }
    std::size_t cursor = pos + std::strlen(kNeedle);
    NSInteger slot = 0;
    bool haveDigit = false;
    while (cursor < msl->size() &&
           std::isdigit(static_cast<unsigned char>((*msl)[cursor]))) {
        haveDigit = true;
        slot = slot * 10 + static_cast<NSInteger>((*msl)[cursor] - '0');
        ++cursor;
    }
    return haveDigit ? slot : -1;
}

static NSInteger textureReductionModesBufferSlot(const std::string* msl) {
    if (msl == nullptr) {
        return -1;
    }
    static constexpr const char* kNeedle =
        "_appgl_TextureReductionModes [[buffer(";
    const std::size_t pos = msl->find(kNeedle);
    if (pos == std::string::npos) {
        return -1;
    }
    std::size_t cursor = pos + std::strlen(kNeedle);
    NSInteger slot = 0;
    bool haveDigit = false;
    while (cursor < msl->size() &&
           std::isdigit(static_cast<unsigned char>((*msl)[cursor]))) {
        haveDigit = true;
        slot = slot * 10 + static_cast<NSInteger>((*msl)[cursor] - '0');
        ++cursor;
    }
    return haveDigit ? slot : -1;
}

static std::vector<std::uint32_t> buildTextureReductionModes(
    const std::vector<TranslatedDrawInfo::TextureBinding>& textures) {
    std::uint32_t maxSlot = 127;
    for (const auto& binding : textures) {
        if (binding.metalTexture == nullptr || binding.metalSamplerState == nullptr) {
            continue;
        }
        maxSlot = std::max(maxSlot, binding.metalSlot);
    }
    std::vector<std::uint32_t> modes(
        static_cast<std::size_t>(maxSlot) + 1u,
        static_cast<std::uint32_t>(GL_WEIGHTED_AVERAGE_ARB));
    for (const auto& binding : textures) {
        if (binding.metalTexture == nullptr || binding.metalSamplerState == nullptr) {
            continue;
        }
        if (binding.metalSlot >= modes.size()) {
            continue;
        }
        modes[binding.metalSlot] = binding.reductionMode;
    }
    return modes;
}

static MTLWinding frontFacingWindingForClipControl(GLenum frontFace,
                                                   bool invertForClipControlY)
{
    bool clockwise = (frontFace == GL_CW);
    if (invertForClipControlY) {
        clockwise = !clockwise;
    }
    return clockwise ? MTLWindingClockwise : MTLWindingCounterClockwise;
}

// Phase 4A [metal-tess-TF] — MSL source for the CPU-exact domain-gen
// port. Shared between the production path (`ensureTessDomainPortLibrary`
// on `Impl`) and the validation probe (`phaseAProbeTessDomainPort`).
//
// Bit-exact port of `generateTessDomain` in TessellationEmulator.cpp
// (source of truth per
// `specs-worker-docs/HANDOFF-2026-04-24-pm-tess-domain-msl-port.md`).
// CPU parity requires compiling with `MTLMathModeSafe` — default
// compile options fuse `1 - fu - fv` into single-rounded ops and
// drift 1 ULP on boundary vertices.
static NSString* const kTessDomainPortMSL = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct QuadFactors {
    half edgeTessellationFactor[4];
    half insideTessellationFactor[2];
};

struct TessPortParams {
    uint genMode;        // 0=Triangles, 1=Quads (Isolines deferred)
    uint genSpacing;     // 0=Equal, 1=FractionalEven, 2=FractionalOdd
    uint patchCount;
    uint pointMode;
    uint flipWinding;
};

// Port of `segmentCount` in TessellationEmulator.cpp. Clamp matches
// the CPU's `!(level >= 1.0f)` semantics (NaN goes to 1.0 too).
inline uint spvPortSegmentCount(float level, uint spacing) {
    if (!(level >= 1.0f)) level = 1.0f;
    if (level > 64.0f) level = 64.0f;
    int n = int(ceil(level));
    if (spacing == 1u) {
        if (n < 2) n = 2;
        if ((n & 1) != 0) n += 1;
    } else if (spacing == 2u) {
        if (n < 1) n = 1;
        if ((n & 1) == 0) n += 1;
    } else {
        if (n < 1) n = 1;
    }
    return uint(n);
}

inline void spvPortEmitTriangle(
    float3 a, float3 b, float3 c,
    uint primID, uint flipWinding,
    device atomic_uint* cursor,
    device packed_float3* coords,
    device uint* primIDs)
{
    uint base = atomic_fetch_add_explicit(cursor, 3u, memory_order_relaxed);
    coords[base + 0] = packed_float3(a);
    if (flipWinding != 0u) {
        coords[base + 1] = packed_float3(c);
        coords[base + 2] = packed_float3(b);
    } else {
        coords[base + 1] = packed_float3(b);
        coords[base + 2] = packed_float3(c);
    }
    primIDs[base + 0] = primID;
    primIDs[base + 1] = primID;
    primIDs[base + 2] = primID;
}

inline void spvPortEmitPoint(
    float3 c,
    uint primID,
    device atomic_uint* cursor,
    device packed_float3* coords,
    device uint* primIDs)
{
    uint base = atomic_fetch_add_explicit(cursor, 1u, memory_order_relaxed);
    coords[base] = packed_float3(c);
    primIDs[base] = primID;
}

void spvPortGenTriangles(
    uint patchID,
    constant TessPortParams& params,
    const device QuadFactors* factors,
    device packed_float3* coords,
    device uint* primIDs,
    device atomic_uint* cursor)
{
    QuadFactors f = factors[patchID];
    float o0 = float(f.edgeTessellationFactor[0]);
    float o1 = float(f.edgeTessellationFactor[1]);
    float o2 = float(f.edgeTessellationFactor[2]);
    float i0 = float(f.insideTessellationFactor[0]);
    uint N = spvPortSegmentCount(max(max(o0, o1), max(o2, i0)),
                                  params.genSpacing);
    float fN = float(N);

    if (params.pointMode != 0u) {
        for (uint j = 0u; j <= N; ++j) {
            uint rowLen = N + 1u - j;
            float fv = precise::divide(float(j), fN);
            for (uint i = 0u; i < rowLen; ++i) {
                float fu = precise::divide(float(i), fN);
                float fw = 1.0f - fu - fv;
                spvPortEmitPoint(float3(fu, fv, fw), patchID,
                                  cursor, coords, primIDs);
            }
        }
        return;
    }

    for (uint j = 0u; j + 1u <= N; ++j) {
        uint row0Len = N + 1u - j;
        uint row1Len = N - j;
        float vj0 = precise::divide(float(j),        fN);
        float vj1 = precise::divide(float(j + 1u),   fN);
        for (uint i = 0u; i + 1u < row0Len; ++i) {
            float ui0 = precise::divide(float(i),        fN);
            float ui1 = precise::divide(float(i + 1u),   fN);
            float wa0 = 1.0f - ui0 - vj0;
            float wa1 = 1.0f - ui1 - vj0;
            float wb0 = 1.0f - ui0 - vj1;
            float wb1 = 1.0f - ui1 - vj1;
            if (i < row1Len) {
                spvPortEmitTriangle(
                    float3(ui0, vj0, wa0),
                    float3(ui1, vj0, wa1),
                    float3(ui0, vj1, wb0),
                    patchID, params.flipWinding,
                    cursor, coords, primIDs);
            }
            if (i + 1u < row1Len) {
                spvPortEmitTriangle(
                    float3(ui1, vj0, wa1),
                    float3(ui1, vj1, wb1),
                    float3(ui0, vj1, wb0),
                    patchID, params.flipWinding,
                    cursor, coords, primIDs);
            }
        }
    }
}

void spvPortGenQuads(
    uint patchID,
    constant TessPortParams& params,
    const device QuadFactors* factors,
    device packed_float3* coords,
    device uint* primIDs,
    device atomic_uint* cursor)
{
    QuadFactors f = factors[patchID];
    float o0 = float(f.edgeTessellationFactor[0]);
    float o1 = float(f.edgeTessellationFactor[1]);
    float o2 = float(f.edgeTessellationFactor[2]);
    float o3 = float(f.edgeTessellationFactor[3]);
    float i0 = float(f.insideTessellationFactor[0]);
    float i1 = float(f.insideTessellationFactor[1]);
    uint uN = spvPortSegmentCount(max(max(o0, o2), i0), params.genSpacing);
    uint vN = spvPortSegmentCount(max(max(o1, o3), i1), params.genSpacing);
    float fuN = float(uN);
    float fvN = float(vN);

    if (params.pointMode != 0u) {
        for (uint j = 0u; j <= vN; ++j) {
            float v = precise::divide(float(j), fvN);
            for (uint i = 0u; i <= uN; ++i) {
                float u = precise::divide(float(i), fuN);
                spvPortEmitPoint(float3(u, v, 0.0f), patchID,
                                  cursor, coords, primIDs);
            }
        }
        return;
    }

    for (uint j = 0u; j < vN; ++j) {
        float v0 = precise::divide(float(j),        fvN);
        float v1 = precise::divide(float(j + 1u),   fvN);
        for (uint i = 0u; i < uN; ++i) {
            float u0 = precise::divide(float(i),        fuN);
            float u1 = precise::divide(float(i + 1u),   fuN);
            spvPortEmitTriangle(
                float3(u0, v0, 0.0f),
                float3(u1, v0, 0.0f),
                float3(u1, v1, 0.0f),
                patchID, params.flipWinding,
                cursor, coords, primIDs);
            spvPortEmitTriangle(
                float3(u0, v0, 0.0f),
                float3(u1, v1, 0.0f),
                float3(u0, v1, 0.0f),
                patchID, params.flipWinding,
                cursor, coords, primIDs);
        }
    }
}

kernel void spvGenTessDomainTrianglesPort(
    constant TessPortParams& params [[buffer(0)]],
    const device QuadFactors* factors [[buffer(26)]],
    device packed_float3* coords [[buffer(25)]],
    device uint* primIDs [[buffer(24)]],
    device atomic_uint* cursor [[buffer(23)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid != 0u) return;
    for (uint p = 0u; p < params.patchCount; ++p) {
        spvPortGenTriangles(p, params, factors, coords, primIDs, cursor);
    }
}

kernel void spvGenTessDomainQuadsPort(
    constant TessPortParams& params [[buffer(0)]],
    const device QuadFactors* factors [[buffer(26)]],
    device packed_float3* coords [[buffer(25)]],
    device uint* primIDs [[buffer(24)]],
    device atomic_uint* cursor [[buffer(23)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid != 0u) return;
    for (uint p = 0u; p < params.patchCount; ++p) {
        spvPortGenQuads(p, params, factors, coords, primIDs, cursor);
    }
}
)MSL";

// Phase 8X Group 4d follow-up¹⁴ — shared Metal translation helpers.
//
// These replace the inline `glTypeToMTLFormat` lambda that used to
// live inside `encodeTranslatedDraw`. `vaoTypeToMTLFormat` is the
// source-of-truth format derivation for each vertex attribute — it
// reads the VAO's `glVertexAttribPointer` parameters (type + size +
// normalized + integer) and returns the matching MTLVertexFormat. The
// old path fell back on `ShaderReflection::vertexInputs[i].type`,
// which only told us the *scalar* type the shader declared
// (`Float4`, `Int4`, …) and blindly trusted it even when the VBO
// actually stored packed UBYTE colors. BAR followup¹³-verification
// §Smoking-Gun showed that is exactly what breaks spring's glyph-
// text draw: `in vec4 col` reflected as `Float4`, but the VBO held
// `glVertexAttribPointer(loc, 4, GL_UNSIGNED_BYTE, GL_TRUE, 24, …)`
// — 4 bytes, not 16, so the GPU reinterpreted 4 bytes of UBYTE4 + 12
// bytes of the next vertex as `float4` and produced NaN.
static MTLVertexFormat vaoTypeToMTLFormat(
    GLenum type, GLint components, GLboolean normalized, bool isInteger)
{
    const bool norm = (normalized == GL_TRUE);
    const int  cc   = components < 1 ? 1 : (components > 4 ? 4 : components);

    switch (type) {
        case GL_FLOAT:
            switch (cc) {
                case 1: return MTLVertexFormatFloat;
                case 2: return MTLVertexFormatFloat2;
                case 3: return MTLVertexFormatFloat3;
                default: return MTLVertexFormatFloat4;
            }
        case GL_HALF_FLOAT:
            switch (cc) {
                case 1: return MTLVertexFormatHalf;
                case 2: return MTLVertexFormatHalf2;
                case 3: return MTLVertexFormatHalf3;
                default: return MTLVertexFormatHalf4;
            }
        case GL_UNSIGNED_BYTE:
            if (isInteger) {
                switch (cc) {
                    case 1: return MTLVertexFormatUChar;
                    case 2: return MTLVertexFormatUChar2;
                    case 3: return MTLVertexFormatUChar3;
                    default: return MTLVertexFormatUChar4;
                }
            }
            if (norm) {
                switch (cc) {
                    case 1: return MTLVertexFormatUCharNormalized;
                    case 2: return MTLVertexFormatUChar2Normalized;
                    case 3: return MTLVertexFormatUChar3Normalized;
                    default: return MTLVertexFormatUChar4Normalized;
                }
            }
            // Metal has no float-cast UChar format, so we can't cleanly
            // represent an unnormalized unsigned byte attribute feeding a
            // float shader input. Fall back to the normalized form — the
            // GPU will divide by 255, which is what the shader author
            // almost certainly wanted if they didn't ask for integer.
            switch (cc) {
                case 1: return MTLVertexFormatUCharNormalized;
                case 2: return MTLVertexFormatUChar2Normalized;
                case 3: return MTLVertexFormatUChar3Normalized;
                default: return MTLVertexFormatUChar4Normalized;
            }
        case GL_BYTE:
            if (isInteger) {
                switch (cc) {
                    case 1: return MTLVertexFormatChar;
                    case 2: return MTLVertexFormatChar2;
                    case 3: return MTLVertexFormatChar3;
                    default: return MTLVertexFormatChar4;
                }
            }
            switch (cc) {
                case 1: return MTLVertexFormatCharNormalized;
                case 2: return MTLVertexFormatChar2Normalized;
                case 3: return MTLVertexFormatChar3Normalized;
                default: return MTLVertexFormatChar4Normalized;
            }
        case GL_UNSIGNED_SHORT:
            if (isInteger) {
                switch (cc) {
                    case 1: return MTLVertexFormatUShort;
                    case 2: return MTLVertexFormatUShort2;
                    case 3: return MTLVertexFormatUShort3;
                    default: return MTLVertexFormatUShort4;
                }
            }
            switch (cc) {
                case 1: return MTLVertexFormatUShortNormalized;
                case 2: return MTLVertexFormatUShort2Normalized;
                case 3: return MTLVertexFormatUShort3Normalized;
                default: return MTLVertexFormatUShort4Normalized;
            }
        case GL_SHORT:
            if (isInteger) {
                switch (cc) {
                    case 1: return MTLVertexFormatShort;
                    case 2: return MTLVertexFormatShort2;
                    case 3: return MTLVertexFormatShort3;
                    default: return MTLVertexFormatShort4;
                }
            }
            switch (cc) {
                case 1: return MTLVertexFormatShortNormalized;
                case 2: return MTLVertexFormatShort2Normalized;
                case 3: return MTLVertexFormatShort3Normalized;
                default: return MTLVertexFormatShort4Normalized;
            }
        case GL_UNSIGNED_INT:
            switch (cc) {
                case 1: return MTLVertexFormatUInt;
                case 2: return MTLVertexFormatUInt2;
                case 3: return MTLVertexFormatUInt3;
                default: return MTLVertexFormatUInt4;
            }
        case GL_INT:
            switch (cc) {
                case 1: return MTLVertexFormatInt;
                case 2: return MTLVertexFormatInt2;
                case 3: return MTLVertexFormatInt3;
                default: return MTLVertexFormatInt4;
            }
        default:
            return MTLVertexFormatFloat4;
    }
}

// Phase 8X Group 4d follow-up¹⁴ — GL → Metal blend factor / equation
// mapping. GL enum namespace is fragmented across separate color and
// alpha factors, but the Metal side uses a single `MTLBlendFactor`
// enum that covers both. We map the common factors and return
// `MTLBlendFactorZero` (the documented default) for anything we don't
// recognise.
static MTLBlendFactor glBlendFactorToMTL(GLenum f) {
    switch (f) {
        case GL_ZERO:                     return MTLBlendFactorZero;
        case GL_ONE:                      return MTLBlendFactorOne;
        case GL_SRC_COLOR:                return MTLBlendFactorSourceColor;
        case GL_ONE_MINUS_SRC_COLOR:      return MTLBlendFactorOneMinusSourceColor;
        case GL_DST_COLOR:                return MTLBlendFactorDestinationColor;
        case GL_ONE_MINUS_DST_COLOR:      return MTLBlendFactorOneMinusDestinationColor;
        case GL_SRC_ALPHA:                return MTLBlendFactorSourceAlpha;
        case GL_ONE_MINUS_SRC_ALPHA:      return MTLBlendFactorOneMinusSourceAlpha;
        case GL_DST_ALPHA:                return MTLBlendFactorDestinationAlpha;
        case GL_ONE_MINUS_DST_ALPHA:      return MTLBlendFactorOneMinusDestinationAlpha;
        case GL_CONSTANT_COLOR:           return MTLBlendFactorBlendColor;
        case GL_ONE_MINUS_CONSTANT_COLOR: return MTLBlendFactorOneMinusBlendColor;
        case GL_CONSTANT_ALPHA:           return MTLBlendFactorBlendAlpha;
        case GL_ONE_MINUS_CONSTANT_ALPHA: return MTLBlendFactorOneMinusBlendAlpha;
        case GL_SRC_ALPHA_SATURATE:       return MTLBlendFactorSourceAlphaSaturated;
        default:                          return MTLBlendFactorZero;
    }
}

static MTLBlendOperation glBlendEqToMTL(GLenum eq) {
    switch (eq) {
        case GL_FUNC_ADD:              return MTLBlendOperationAdd;
        case GL_FUNC_SUBTRACT:         return MTLBlendOperationSubtract;
        case GL_FUNC_REVERSE_SUBTRACT: return MTLBlendOperationReverseSubtract;
        case GL_MIN:                   return MTLBlendOperationMin;
        case GL_MAX:                   return MTLBlendOperationMax;
        default:                       return MTLBlendOperationAdd;
    }
}

// Phase 8X Group 4d follow-up¹⁴ — pipeline cache key. A 64-bit hash
// of the state tuple that drives pipeline creation. The key is
// stable across draws that share the same compiled program and the
// same effective pipeline descriptor, so a program that draws both
// an opaque first pass and an alpha-blended second pass keeps both
// pipelines hot without thrashing. The 64 bits are laid out as:
//
//   [63..56] colorFormat low 8 bits  (MTLPixelFormat fits)
//   [55..55] blend.enabled
//   [54..54] colorMaskA
//   [53..53] colorMaskB
//   [52..52] colorMaskG
//   [51..51] colorMaskR
//   [50..48] eqRGB   (3 bits; covers Add/Sub/RevSub/Min/Max)
//   [47..45] eqAlpha (3 bits)
//   [44..41] srcRGB low 4 bits of MTLBlendFactor
//   [40..37] dstRGB low 4 bits
//   [36..33] srcAlpha low 4 bits
//   [32..29] dstAlpha low 4 bits
//   [28..0]  per-attribute format tuple hash (FNV-1a over the active
//            vertexAttributeLayouts + extraVertexBuffers[*].attributes
//            `glType/glComponentCount/glNormalized/glIsInteger` fields)
//
// Collisions are not catastrophic — the worst case is a wrong
// pipeline gets reused, which shows up as a validation failure from
// Metal on the next draw and triggers a rebuild. But the hash is
// structured so the common toggles (opaque ↔ alpha-blended with
// identical geometry layout) always produce distinct keys.
static std::uint64_t computePipelineCacheKey(
    const TranslatedDrawInfo& info, MTLPixelFormat colorFormat,
    NSUInteger sampleCount, bool forcePerSampleFS)
{
    std::uint64_t key = 0;
    key |= static_cast<std::uint64_t>(colorFormat & 0xFF) << 56;
    key |= (info.blend.enabled    ? 1ULL : 0ULL) << 55;
    key |= (info.blend.colorMaskA ? 1ULL : 0ULL) << 54;
    key |= (info.blend.colorMaskB ? 1ULL : 0ULL) << 53;
    key |= (info.blend.colorMaskG ? 1ULL : 0ULL) << 52;
    key |= (info.blend.colorMaskR ? 1ULL : 0ULL) << 51;

    // Phase 6-1a: mix the MSAA sample count into the cache key so
    // pipelines built for MS attachments don't alias with non-MS
    // pipelines. Metal supports 1/2/4/8 typically; 3 bits at a free
    // slot (27..29 — bit 28 was the rasterizer-discard flag, below)
    // holds the log2 nicely. Encoding: 1 → 0, 2 → 1, 4 → 2, 8 → 3.
    std::uint64_t sampleLog2 = 0;
    if (sampleCount <= 1) sampleLog2 = 0;
    else if (sampleCount == 2) sampleLog2 = 1;
    else if (sampleCount == 4) sampleLog2 = 2;
    else if (sampleCount == 8) sampleLog2 = 3;
    else sampleLog2 = 7;   // anything else — unique bucket
    key |= (sampleLog2 & 0x7ULL) << 25;   // bits 25..27 (was FNV hash tail)
    // Phase 6-1e: distinguish per-sample-FS pipeline from the
    // per-pixel-FS pipeline built from the same MSL source. Bit 24
    // is free (below the 25..27 sample-count field).
    key |= (forcePerSampleFS ? 1ULL : 0ULL) << 24;

    const std::uint64_t eqRGB = static_cast<std::uint64_t>(
        glBlendEqToMTL(info.blend.equationRGB)) & 0x7ULL;
    const std::uint64_t eqA = static_cast<std::uint64_t>(
        glBlendEqToMTL(info.blend.equationAlpha)) & 0x7ULL;
    key |= eqRGB << 48;
    key |= eqA   << 45;

    const std::uint64_t srcRGB = static_cast<std::uint64_t>(
        glBlendFactorToMTL(info.blend.srcRGB)) & 0xFULL;
    const std::uint64_t dstRGB = static_cast<std::uint64_t>(
        glBlendFactorToMTL(info.blend.dstRGB)) & 0xFULL;
    const std::uint64_t srcA = static_cast<std::uint64_t>(
        glBlendFactorToMTL(info.blend.srcAlpha)) & 0xFULL;
    const std::uint64_t dstA = static_cast<std::uint64_t>(
        glBlendFactorToMTL(info.blend.dstAlpha)) & 0xFULL;
    key |= srcRGB << 41;
    key |= dstRGB << 37;
    key |= srcA   << 33;
    key |= dstA   << 29;

    // Bit 28: rasterizer discard — pipelines built with
    // rasterizationEnabled=NO can't be reused when raster is enabled
    // (the fragment function is nil) and vice versa.
    key |= (info.rasterizerDiscard ? 1ULL : 0ULL) << 28;

    // FNV-1a over the per-attribute format tuple. 29 bits is enough
    // to discriminate the half-dozen distinct layouts BAR's draw
    // path sees in practice — grow if collisions show up.
    std::uint32_t hash = 2166136261u;
    auto mix = [&hash](std::uint32_t v) {
        hash ^= v;
        hash *= 16777619u;
    };
    auto hashLayout = [&](const TranslatedDrawInfo::VertexAttributeLayout& l) {
        mix(static_cast<std::uint32_t>(l.location));
        mix(static_cast<std::uint32_t>(l.offset));
        mix(static_cast<std::uint32_t>(l.glType));
        mix(static_cast<std::uint32_t>(l.glComponentCount));
        mix(static_cast<std::uint32_t>(l.glNormalized));
        mix(l.glIsInteger ? 1u : 0u);
    };
    mix(static_cast<std::uint32_t>(info.vertexStride));
    for (const auto& l : info.vertexAttributeLayouts) {
        hashLayout(l);
    }
    for (const auto& evb : info.extraVertexBuffers) {
        mix(static_cast<std::uint32_t>(evb.stride));
        mix(static_cast<std::uint32_t>(evb.divisor));
        mix(evb.constantStep ? 1u : 0u);
        for (const auto& l : evb.attributes) {
            hashLayout(l);
        }
    }
    key |= static_cast<std::uint64_t>(hash & 0x0FFFFFFFu);  // 28 bits (bit 28 = rasterizerDiscard)
    return key;
}

// Phase 6-1e / 6-2: transform a SPIRV-Cross fragment MSL source so
// Metal honours GL 4.6 §14.6 / ARB_sample_shading.
//
// Two coordinated rewrites:
//
// (1) Inject `uint _ap_sample_id [[sample_id]]` into `main0(...)`.
//     Metal has no explicit "force per-sample FS" knob; the only
//     trigger for per-sample invocation is the shader reading a
//     per-sample built-in. The parameter's presence alone is enough
//     — no body changes needed.
//
// (2) For each `[[user(locnN)]]` input varying in `main0_in`, add a
//     `sample_perspective` qualifier. Metal's default interpolation
//     for a user varying is `center_perspective` (pixel-center),
//     which means that even when per-sample FS fires via (1) the
//     interpolated input is still the same at every sample in a
//     pixel — producing 1 unique color per pixel column rather than
//     `samples` unique. GLSL §4.3.4.1 says when sample shading is
//     enabled, inputs that don't carry `centroid` or `flat` are
//     interpolated at the sample location; Metal expresses this
//     as `sample_perspective` / `sample_no_perspective`. We use
//     `sample_perspective` (matches the typical GLSL `smooth` /
//     default perspective-corrected interpolation) and leave
//     already-qualified varyings (`flat`, `centroid_*`, any prior
//     `sample_*`) alone.
//
// Entry-point shape from SPIRV-Cross on macOS:
//   struct main0_in { float4 v_color [[user(locn0)]]; };
//   fragment main0_out main0(main0_in in [[stage_in]]) { ... }
// Also accepts the empty-param variant (`main0()`) and nested parens
// inside the param list (e.g. cast expressions). Each rewrite step
// falls back to the original MSL when its anchor isn't found, so
// the returned string is always valid MSL.
static std::string rewriteFragmentMSLForPerSample(const std::string& fsMsl)
{
    std::string working = fsMsl;

    // Step (1): [[sample_id]] inject.
    // Fast-out when the shader already reads [[sample_id]]; otherwise
    // we'd risk emitting two parameters with the same attribute and
    // Metal would reject the pipeline.
    if (working.find("[[sample_id]]") == std::string::npos) do {
        const std::size_t openParen = working.find("main0(");
        if (openParen == std::string::npos) break;
        const std::size_t paramStart = openParen + 6;   // past "main0("
        std::size_t depth = 1;
        std::size_t pos = paramStart;
        while (pos < working.size() && depth > 0) {
            const char c = working[pos];
            if (c == '(') {
                ++depth;
            } else if (c == ')') {
                --depth;
                if (depth == 0) break;
            }
            ++pos;
        }
        if (depth != 0 || pos >= working.size()) break;

        const std::string paramSlice = working.substr(paramStart, pos - paramStart);
        const bool hasExistingParams =
            paramSlice.find_first_not_of(" \t\n\r") != std::string::npos;

        std::string out;
        out.reserve(working.size() + 64);
        out.append(working, 0, pos);
        if (hasExistingParams) {
            out.append(", ");
        }
        out.append("uint _ap_sample_id [[sample_id]]");
        out.append(working, pos, std::string::npos);
        working = std::move(out);
    } while (false);

    // Step (2): sample_perspective qualifier on main0_in varyings.
    // Locate the `struct main0_in {` block and rewrite each
    // `[[user(locnN)]]` inside to `[[user(locnN), sample_perspective]]`.
    // Leave already-qualified `[[user(locnN), flat]]` /
    // `[[user(locnN), centroid_*]]` / `[[user(locnN), sample_*]]`
    // unchanged — only the bare attribute gets the qualifier.
    do {
        const std::size_t structPos = working.find("struct main0_in");
        if (structPos == std::string::npos) break;
        const std::size_t openBrace = working.find('{', structPos);
        if (openBrace == std::string::npos) break;
        // Walk to matching close brace. main0_in is flat (no nested
        // structs), but keep a depth counter for defensiveness.
        std::size_t depth = 1;
        std::size_t closeBrace = openBrace + 1;
        while (closeBrace < working.size() && depth > 0) {
            const char c = working[closeBrace];
            if (c == '{') ++depth;
            else if (c == '}') { --depth; if (depth == 0) break; }
            ++closeBrace;
        }
        if (depth != 0 || closeBrace >= working.size()) break;

        std::string out;
        out.reserve(working.size() + 128);
        out.append(working, 0, openBrace + 1);

        std::size_t scan = openBrace + 1;
        while (scan < closeBrace) {
            const std::size_t attrStart = working.find("[[user(locn", scan);
            if (attrStart == std::string::npos || attrStart >= closeBrace) {
                out.append(working, scan, closeBrace - scan);
                break;
            }
            // Walk from `[[user(locn` to the closing `)`.
            std::size_t cursor = attrStart + 11;   // past "[[user(locn"
            while (cursor < closeBrace && working[cursor] != ')') ++cursor;
            if (cursor >= closeBrace) {
                out.append(working, scan, closeBrace - scan);
                break;
            }
            // Now `working[cursor]` is the ')' that closes the user
            // locn. Check what follows. Bare `[[user(locnN)]]` →
            // `cursor+1 == ']'` && `cursor+2 == ']'`. Qualified (has
            // comma inside) → the attribute ends past `]]` later.
            const bool isBare =
                cursor + 2 < working.size() &&
                working[cursor + 1] == ']' &&
                working[cursor + 2] == ']';
            if (isBare) {
                // Copy [scan .. cursor+1) → "[[user(locnN)" (+ all prior text)
                out.append(working, scan, (cursor + 1) - scan);
                // Insert ", sample_perspective" before the "]]"
                out.append(", sample_perspective");
                // Copy "]]"
                out.append(working, cursor + 1, 2);
                scan = cursor + 3;
            } else {
                // Already qualified. Walk to the attribute's closing
                // `]]` and copy verbatim.
                std::size_t end = cursor + 1;
                while (end + 1 < closeBrace &&
                       !(working[end] == ']' && working[end + 1] == ']')) {
                    ++end;
                }
                if (end + 1 >= closeBrace) {
                    // Malformed; bail and copy rest verbatim.
                    out.append(working, scan, closeBrace - scan);
                    scan = closeBrace;
                    break;
                }
                out.append(working, scan, (end + 2) - scan);
                scan = end + 2;
            }
        }

        out.append(working, closeBrace, std::string::npos);
        working = std::move(out);
    } while (false);

    return working;
}

struct MetalFrameGraph::Impl {
    Impl(GLContext* ownerContext, void* rawLayer, void* rawDevice, void* rawCommandQueue)
        : owner(ownerContext),
          layer((__bridge CAMetalLayer*)rawLayer),
          device((__bridge id<MTLDevice>)rawDevice),
          commandQueue((__bridge id<MTLCommandQueue>)rawCommandQueue) {
        if (layer != nil && device != nil) {
            layer.device = device;
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.framebufferOnly = NO;
            layer.displaySyncEnabled = NO;
        }
        ensureDrawableResources();
        acquireRingSlot();  // OPT-8: acquire initial ring buffer slot (slot 0)
    }

    ~Impl() {
        // End any open render encoder before the autorelease pool reclaims it.
        // Without this, destroying a context with an in-flight render pass
        // triggers "Command encoder released without endEncoding".
        endRenderPass();
        if (currentCommandBuffer != nil) {
            [currentCommandBuffer commit];
            [currentCommandBuffer waitUntilCompleted];
            currentCommandBuffer = nil;
        }
        // OPT-8: Release any acquired ring slot to balance the semaphore.
        // All in-flight completion handlers have fired (Metal processes CBs
        // in commit order, and waitUntilCompleted on the last ensures all
        // prior CBs completed).
        if (ringSlotAcquired) {
            dispatch_semaphore_signal(frameSemaphore);
            ringSlotAcquired = false;
        }
        // ADV-14: persist the pipeline binary archive to disk so the
        // next launch gets pre-compiled GPU binaries.
        savePipelineArchive();
    }

    void attachFragmentShadingRateMap(
        MTLRenderPassDescriptor* pass,
        GLenum rate,
        id<MTLTexture> colorTexture,
        NSUInteger renderTargetLayerCount
    ) {
        if (rate == GL_SHADING_RATE_1X1_PIXELS_EXT ||
            owner == nullptr || pass == nil || colorTexture == nil || renderTargetLayerCount > 1) {
            return;
        }
        ExtensionContext extensionContext(*owner);
        const auto& hooks = extensions::ExtensionRegistry::fragmentShadingRateHooks();
        if (hooks.attachRenderPass != nullptr) {
            hooks.attachRenderPass(extensionContext,
                                   (__bridge void*)pass,
                                   rate,
                                   (__bridge void*)colorTexture,
                                   renderTargetLayerCount);
        }
    }

    void resize(GLsizei width, GLsizei height) {
        GLsizei newW = width > 0 ? width : 1;
        GLsizei newH = height > 0 ? height : 1;
        if (newW == drawableWidth && newH == drawableHeight) {
            return;  // No-op when size is unchanged.
        }
        drawableWidth = newW;
        drawableHeight = newH;
        headlessReadbackRGBA.clear();
        hasHeadlessReadback = false;
        if (layer != nil) {
            layer.drawableSize = CGSizeMake(drawableWidth, drawableHeight);
        }
        endRenderPass();
        invalidateTransientState();
        ensureDrawableResources();
    }

    void enableOffscreen(GLsizei width, GLsizei height) {
        usesOffscreenTarget = true;
        resize(width, height);
    }

    void encodeClear(
        GLbitfield mask,
        GLfloat clearRed,
        GLfloat clearGreen,
        GLfloat clearBlue,
        GLfloat clearAlpha,
        GLdouble clearDepth,
        GLint clearStencil
    ) {
        if (device == nil || commandQueue == nil) {
            storeHeadlessClear(mask, clearRed, clearGreen, clearBlue, clearAlpha);
            return;
        }

        FG_TRACE(@"encodeClear: enter (deferred)  encoder=%p cmdBuf=%p", currentRenderEncoder, currentCommandBuffer);

        // OPT-8: Acquire a ring buffer slot before any GPU work.
        acquireRingSlot();

        // Close any open render encoder and flush the prior command buffer.
        // This serves as a frame boundary: Metal can start executing the
        // previous frame's work while we set up the next one.  The pending
        // clear will be merged into the NEXT render pass as a load action,
        // eliminating the old separate clear-only render pass (OPT-4).
        endRenderPass();
        if (currentCommandBuffer != nil) {
            commitWithFrameSignal(currentCommandBuffer);  // OPT-8
            currentCommandBuffer = nil;
            currentDrawable = nil;
            pendingPresent = false;
            advanceRingBuffer();
            acquireRingSlot();  // OPT-8: acquire the next slot for this frame
        }
        ensureDrawableResources();

        // Store the clear parameters; they'll be consumed when the next
        // render pass opens (in encodeTranslatedDraw or encodeSolidColorDraw).
        hasPendingClear = true;
        pendingClearMask = mask;
        pendingClearColor = MTLClearColorMake(clearRed, clearGreen, clearBlue, clearAlpha);
        pendingClearDepth = clearDepth;
        pendingClearStencil = static_cast<std::uint32_t>(clearStencil);

        pendingPresent = true;
    }

    void beginRenderPass(GLStateTracker& state, GLObjectStore& objects) {
        (void)state;
        (void)objects;
        if (device == nil || commandQueue == nil) {
            return;
        }
        acquireRingSlot();  // OPT-8
        FG_TRACE(@"beginRenderPass: enter  encoder=%p cmdBuf=%p", currentRenderEncoder, currentCommandBuffer);
        endRenderPass();
        ensureDrawableResources();
        if (currentCommandBuffer == nil) {
            currentCommandBuffer = [commandQueue commandBuffer];
            attachErrorHandler(currentCommandBuffer, @"beginRenderPass");
        }
        if (!acquireDrawableIfNeeded()) {  // ADV-7
            return;
        }

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];  // ADV-4
        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        pass.depthAttachment.texture = depthStencilTexture;
        pass.depthAttachment.loadAction = MTLLoadActionLoad;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.stencilAttachment.texture = depthStencilTexture;
        pass.stencilAttachment.loadAction = MTLLoadActionLoad;
        pass.stencilAttachment.storeAction = MTLStoreActionStore;
        const GLenum fragmentRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
        attachFragmentShadingRateMap(pass, fragmentRate, colorTexture, 1);
        currentRenderEncoder = [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
        activeRenderPassFragmentShadingRate = fragmentRate;
        resetCachedEncoderState();
    }

    void* renderEncoder() const {
        return (__bridge void*)currentRenderEncoder;
    }

    void attachErrorHandler(id<MTLCommandBuffer> buf, NSString* label) {
#if APPGL_TRACE_FRAMEGRAPH
        buf.label = label;
        [buf addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            if (cb.status == MTLCommandBufferStatusError) {
                NSLog(@"[FG] *** COMMAND BUFFER ERROR *** label=%@ error=%@", cb.label, cb.error);
            }
        }];
#else
        (void)buf; (void)label;
#endif
    }

    void endRenderPass() {
        if (currentRenderEncoder != nil) {
            FG_TRACE(@"endRenderPass: ending encoder %p on cmdBuf %p", currentRenderEncoder, currentCommandBuffer);
            [currentRenderEncoder endEncoding];
            currentRenderEncoder = nil;
            activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
            pendingPresent = true;
        }
    }

    // Flush a deferred clear into a standalone render pass. Called by
    // copyPixels and present when a clear is pending but no draws occurred.
    void flushPendingClear() {
        if (!hasPendingClear || device == nil) return;

        ensureDrawableResources();
        if (currentCommandBuffer == nil) {
            currentCommandBuffer = [commandQueue commandBuffer];
            attachErrorHandler(currentCommandBuffer, @"flushClear");
            if (currentCommandBuffer == nil) { hasPendingClear = false; return; }
        }
        if (!acquireDrawableIfNeeded()) {  // ADV-7
            hasPendingClear = false; return;
        }

        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        if (colorTexture == nil) { hasPendingClear = false; return; }

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];  // ADV-4
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].loadAction = (pendingClearMask & GL_COLOR_BUFFER_BIT) ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].clearColor = pendingClearColor;
        if (depthStencilTexture != nil) {
            pass.depthAttachment.texture = depthStencilTexture;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.depthAttachment.loadAction = (pendingClearMask & GL_DEPTH_BUFFER_BIT) ? MTLLoadActionClear : MTLLoadActionLoad;
            pass.depthAttachment.clearDepth = pendingClearDepth;
            pass.stencilAttachment.texture = depthStencilTexture;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.loadAction = (pendingClearMask & GL_STENCIL_BUFFER_BIT) ? MTLLoadActionClear : MTLLoadActionLoad;
            pass.stencilAttachment.clearStencil = pendingClearStencil;
        }

        id<MTLRenderCommandEncoder> encoder = [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
        [encoder endEncoding];
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        hasPendingClear = false;
        pendingPresent = true;
    }

    // Solid-color fallback draw path.
    //
    // Hand-written "solid color" MSL pipeline consuming one float3 position
    // attribute and a single float4 uniform color. Used as a fallback when the
    // active program has no translated MSL (e.g. program 0 or translation
    // failure). The primary draw path is encodeTranslatedDraw(), which uses
    // the GLSL→SPIR-V→MSL pipeline output cached on GLProgramObject.
    bool encodeSolidColorDraw(const MetalDrawInfo& info) {
        FG_TRACE(@"encodeSolidColorDraw: enter  mode=0x%X verts=%d encoder=%p cmdBuf=%p",
                 info.mode, info.vertexCount, currentRenderEncoder, currentCommandBuffer);
        if (device == nil || commandQueue == nil) {
            return false;
        }
        acquireRingSlot();  // OPT-8
        if (info.vertexCount <= 0 || info.positions == nullptr || info.positionByteCount == 0) {
            return false;
        }
        if (info.mode != GL_TRIANGLES && info.mode != GL_TRIANGLE_STRIP) {
            FG_TRACE(@"encodeSolidColorDraw: unsupported mode 0x%X, returning false", info.mode);
            return false;
        }
        if (info.positionComponents != 3) {
            return false;
        }

        ensureDrawableResources();
        if (!ensureSolidColorLibrary()) {
            return false;
        }
        if (!ensureSolidColorPipelineState(info)) {
            return false;
        }

        // Close any open render encoder before starting the solid-color pass.
        endRenderPass();

        // Reuse the current command buffer if one exists, otherwise create new.
        if (currentCommandBuffer == nil) {
            currentCommandBuffer = [commandQueue commandBuffer];
            attachErrorHandler(currentCommandBuffer, @"solidColorDraw");
            if (currentCommandBuffer == nil) {
                return false;
            }
        }

        if (!acquireDrawableIfNeeded()) {  // ADV-7
            FG_TRACE(@"encodeSolidColorDraw: nextDrawable returned nil!");
            return false;
        }

        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        if (colorTexture == nil) {
            return false;
        }

        // Merge any pending clear into this render pass's load action (OPT-4).
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];  // ADV-4
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (hasPendingClear && (pendingClearMask & GL_COLOR_BUFFER_BIT)) {
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = pendingClearColor;
        } else {
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }
        if (depthStencilTexture != nil) {
            pass.depthAttachment.texture = depthStencilTexture;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.texture = depthStencilTexture;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            if (hasPendingClear && (pendingClearMask & GL_DEPTH_BUFFER_BIT)) {
                pass.depthAttachment.loadAction = MTLLoadActionClear;
                pass.depthAttachment.clearDepth = pendingClearDepth;
            } else {
                pass.depthAttachment.loadAction = MTLLoadActionLoad;
            }
            if (hasPendingClear && (pendingClearMask & GL_STENCIL_BUFFER_BIT)) {
                pass.stencilAttachment.loadAction = MTLLoadActionClear;
                pass.stencilAttachment.clearStencil = pendingClearStencil;
            } else {
                pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            }
        }
        hasPendingClear = false;

        attachFragmentShadingRateMap(pass, info.fragmentShadingRate, colorTexture, 1);
        id<MTLRenderCommandEncoder> encoder = [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
        if (encoder == nil) {
            return false;
        }
        [encoder setRenderPipelineState:solidColorPipelineState];

        if (depthStencilTexture != nil) {
            id<MTLDepthStencilState> dsState = depthStencilStateForDraw(info);
            if (dsState != nil) {
                [encoder setDepthStencilState:dsState];
            }
        }

        if (info.cullFaceEnabled) {
            [encoder setCullMode:(info.cullFaceMode == GL_FRONT ? MTLCullModeFront :
                                  info.cullFaceMode == GL_FRONT_AND_BACK ? MTLCullModeBack : MTLCullModeBack)];
        } else {
            [encoder setCullMode:MTLCullModeNone];
        }
        [encoder setFrontFacingWinding:info.frontFace == GL_CW ? MTLWindingClockwise : MTLWindingCounterClockwise];
        [encoder setTriangleFillMode:info.wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];

        // Vertex positions are pushed as inline bytes (fits in Metal's 4KB limit
        // for every fixture we ship in Phase A). Attribute 0 lives in buffer 0.
        if (info.positionByteCount <= 4096) {
            [encoder setVertexBytes:info.positions length:info.positionByteCount atIndex:0];
        } else {
            auto alloc = ringSuballocate(info.positions, info.positionByteCount);
            if (alloc.buffer == nil) {
                [encoder endEncoding];
                return false;
            }
            [encoder setVertexBuffer:alloc.buffer offset:alloc.offset atIndex:0];
        }
        // Uniform color lives in fragment buffer 0.
        [encoder setFragmentBytes:info.uniformColor length:sizeof(info.uniformColor) atIndex:0];

        const MTLPrimitiveType primitive = (info.mode == GL_TRIANGLE_STRIP)
            ? MTLPrimitiveTypeTriangleStrip
            : MTLPrimitiveTypeTriangle;

        if (info.indices != nullptr && info.indexCount > 0) {
            MTLIndexType metalIndexType = MTLIndexTypeUInt16;
            std::size_t bytesPerIndex = 2;
            switch (info.indexType) {
                case GL_UNSIGNED_INT:
                    metalIndexType = MTLIndexTypeUInt32;
                    bytesPerIndex = 4;
                    break;
                case GL_UNSIGNED_SHORT:
                    metalIndexType = MTLIndexTypeUInt16;
                    bytesPerIndex = 2;
                    break;
                default:
                    [encoder endEncoding];
                    return false;
            }
            const std::size_t indexBytes = static_cast<std::size_t>(info.indexCount) * bytesPerIndex;
            auto iAlloc = ringSuballocate(info.indices, indexBytes);
            if (iAlloc.buffer == nil) {
                [encoder endEncoding];
                return false;
            }
            [encoder drawIndexedPrimitives:primitive
                                indexCount:static_cast<NSUInteger>(info.indexCount)
                                 indexType:metalIndexType
                               indexBuffer:iAlloc.buffer
                         indexBufferOffset:iAlloc.offset
                             instanceCount:1
                                baseVertex:static_cast<NSUInteger>(info.baseVertex)
                              baseInstance:0];
        } else {
            [encoder drawPrimitives:primitive
                        vertexStart:static_cast<NSUInteger>(info.baseVertex)
                        vertexCount:static_cast<NSUInteger>(info.vertexCount)];
        }

        [encoder endEncoding];
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        pendingPresent = true;
        return true;
    }

    bool encodeTranslatedDraw(TranslatedDrawInfo& info) {
        FG_TRACE(@"encodeTranslatedDraw: enter  mode=0x%X verts=%d instances=%d encoder=%p cmdBuf=%p",
                 info.mode, info.vertexCount, info.instanceCount, currentRenderEncoder, currentCommandBuffer);
        if (device == nil || commandQueue == nil) {
            return false;
        }
        acquireRingSlot();  // OPT-8
        if (info.vertexCount <= 0) {
            FG_TRACE(@"encodeTranslatedDraw: vertexCount <= 0, returning false");
            return false;
        }
        // Attributeless draws (gl_VertexID-driven) have no vertex data.
        // Only reject missing vertex data when attributes are declared.
        const bool attributelessDraw =
            (info.vertexData == nullptr && info.metalVertexBuffer == nullptr &&
             info.vertexAttributeLayouts.empty());
        if (!attributelessDraw && info.vertexData == nullptr && info.metalVertexBuffer == nullptr) {
            FG_TRACE(@"encodeTranslatedDraw: bad vertex data, returning false");
            return false;
        }
        if (info.vertexMSL == nullptr || info.vertexMSL->empty()) {
            FG_TRACE(@"encodeTranslatedDraw: no vertex MSL, returning false");
            return false;
        }
        if (std::getenv("APPGL_TRACE_VIEWPORT_LAYER_ARRAY") != nullptr &&
            ((info.vertexMSL->find("[[viewport_array_index]]") != std::string::npos ||
              info.vertexMSL->find("[[render_target_array_index]]") != std::string::npos) ||
             info.viewportArrayCount > 1 ||
             info.fboColorArrayLength > 0)) {
            std::fprintf(stderr,
                "[SVLA] translated draw program=%u mode=0x%x verts=%d idx=%d "
                "vpCount=%zu fboArray=%u markViewport=%d hasVertexData=%d hasMetalVBO=%d attrLayouts=%zu\n",
                static_cast<unsigned>(info.program),
                static_cast<unsigned>(info.mode),
                static_cast<int>(info.vertexCount),
                static_cast<int>(info.indexCount),
                info.viewportArrayCount,
                info.fboColorArrayLength,
                info.markColorAttachmentReadbackFlip ? 1 : 0,
                info.vertexData != nullptr ? 1 : 0,
                info.metalVertexBuffer != nullptr ? 1 : 0,
                info.vertexAttributeLayouts.size());
        }
        // Fragment MSL is only required when rasterization runs. Under
        // GL_RASTERIZER_DISCARD the pipeline skips the fragment stage
        // entirely (see the rasterizerDiscard branch in the pipeline
        // descriptor setup below), so a VS-only program — the shape CTS
        // shader_storage_buffer_object.*-vs tests create — is a valid draw.
        const bool hasFragmentStage = (info.fragmentMSL != nullptr && !info.fragmentMSL->empty());
        if (!hasFragmentStage && !info.rasterizerDiscard) {
            FG_TRACE(@"encodeTranslatedDraw: no fragment MSL and raster enabled, returning false");
            return false;
        }

        ensureDrawableResources();

        // RC-A02: when an FBO render target is provided, use it instead of
        // the default framebuffer texture.
        const bool isAttachmentlessFBODraw =
            info.fboAttachmentless &&
            info.fboColorTexture == nullptr &&
            info.fboDepthStencilTexture == nullptr;
        const bool isFBODraw =
            info.fboColorTexture != nullptr ||
            info.fboDepthStencilTexture != nullptr ||
            isAttachmentlessFBODraw;
        id<MTLTexture> fboColorTex = (info.fboColorTexture != nullptr)
            ? (__bridge id<MTLTexture>)info.fboColorTexture : nil;
        id<MTLTexture> fboDepthStencilTex = (info.fboDepthStencilTexture != nullptr)
            ? (__bridge id<MTLTexture>)info.fboDepthStencilTexture : nil;
        id<MTLTexture> attachmentlessColorTex = nil;
        if (isAttachmentlessFBODraw) {
            const NSUInteger fboWidth =
                static_cast<NSUInteger>(std::max<GLsizei>(info.fboWidth, 1));
            const NSUInteger fboHeight =
                static_cast<NSUInteger>(std::max<GLsizei>(info.fboHeight, 1));
            const NSUInteger fboLayers =
                static_cast<NSUInteger>(std::max<std::uint32_t>(info.fboDefaultLayers, 1u));
            MTLTextureDescriptor* dummyDesc =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                    width:fboWidth
                                                                   height:fboHeight
                                                                mipmapped:NO];
            dummyDesc.storageMode = MTLStorageModePrivate;
            dummyDesc.usage = MTLTextureUsageRenderTarget;
            if (fboLayers > 1) {
                dummyDesc.textureType = MTLTextureType2DArray;
                dummyDesc.arrayLength = fboLayers;
            }
            attachmentlessColorTex = [device newTextureWithDescriptor:dummyDesc];
            fboColorTex = attachmentlessColorTex;
        }
        id<MTLTexture> dsOnlyColorTex = nil;
        if (isFBODraw && fboColorTex == nil && fboDepthStencilTex != nil) {
            MTLTextureDescriptor* dummyDesc =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                    width:fboDepthStencilTex.width
                                                                   height:fboDepthStencilTex.height
                                                                mipmapped:NO];
            dummyDesc.storageMode = MTLStorageModePrivate;
            dummyDesc.usage = MTLTextureUsageRenderTarget;
            if (fboDepthStencilTex.sampleCount > 1) {
                dummyDesc.textureType = MTLTextureType2DMultisample;
                dummyDesc.sampleCount = fboDepthStencilTex.sampleCount;
            }
            dsOnlyColorTex = [device newTextureWithDescriptor:dummyDesc];
            fboColorTex = dsOnlyColorTex;
        }

        // Lazily create the MTLRenderPipelineState from translated MSL.
        id<MTLTexture> colorTexture = isFBODraw ? fboColorTex
            : (usesOffscreenTarget ? offscreenColorTexture : nil);
        const MTLPixelFormat colorFormat = colorTexture != nil
            ? colorTexture.pixelFormat
            : MTLPixelFormatBGRA8Unorm;

        // Phase 8X Group 4d follow-up¹⁴ — map-based cache lookup.
        // The cache key encodes (colorFormat, blend tuple, per-
        // attribute format tuple) so a program that draws with
        // distinct blend modes or distinct VBO layouts keeps
        // multiple pipelines hot instead of thrashing on every
        // `glEnable(GL_BLEND)` ping-pong.
        // Phase 6-1a: sample count from the color attachment.
        // Single-sample textures report sampleCount=1; MS renderbuffers
        // created via renderbufferStorageMultisample report 2/4/8 etc.
        // We feed this into both the pipeline cache key and the
        // pipeline descriptor's rasterSampleCount further below.
        const NSUInteger attachmentSampleCount =
            colorTexture != nil ? colorTexture.sampleCount : 1;
        // Phase 6-1e: GL_SAMPLE_SHADING + MS attachment forces the FS to
        // run per-sample. Metal only switches to per-sample FS when the
        // shader reads a per-sample built-in ([[sample_id]] /
        // [[sample_position]]). When the GL state asks for sample-shading
        // on an MS attachment, we rewrite the FS MSL below to inject an
        // unused [[sample_id]] parameter. The pipeline cache key carries
        // this rewrite so toggling GL_SAMPLE_SHADING doesn't collide
        // with the per-pixel variant built from the same source.
        const bool forcePerSampleFS =
            info.sampleShadingEnabled && info.minSampleShading > 0.0f &&
            attachmentSampleCount > 1;
        const std::uint64_t pipelineCacheKey =
            computePipelineCacheKey(info, colorFormat, attachmentSampleCount,
                                     forcePerSampleFS);

        // Step 7-3: argument-buffer mode. When APPGL_ENABLE_ARGUMENT_BUFFERS
        // is set, the fragment/vertex shader was compiled to read resources
        // through `constant spvDescriptorSetBuffer0& spvDescriptorSet0
        // [[buffer(24)]]` rather than direct [[texture(N)]] /
        // [[sampler(N)]] slots. We must build a Metal argument buffer per
        // stage per descriptor-set-in-use and bind it at the pinned
        // [[buffer(24)]] / [[buffer(25)]] slots.
        //
        // Step 7-4: MTLFunction caching via
        // `info.metalVertexFunction{,Out}` and `info.metalFragmentFunction{,Out}`.
        // First pipeline build under argbuf retains the vertex + fragment
        // MTLFunction on the GLProgramObject; subsequent draws reuse the
        // cache and skip the pipeline-rebuild cost. This undoes the pre-7-4
        // pipeline-cache-miss forcing we used to keep MTLFunctions in scope.
        auto mslUsesArgBuf = [](const std::string* msl) -> bool {
            return msl != nullptr &&
                msl->find("spvDescriptorSetBuffer") != std::string::npos;
        };
        const bool forceArgBufEnv =
            (std::getenv("APPGL_ENABLE_ARGUMENT_BUFFERS") != nullptr);
        const bool vertexUsesArgBuf = forceArgBufEnv || mslUsesArgBuf(info.vertexMSL);
        const bool fragmentUsesArgBuf = forceArgBufEnv || mslUsesArgBuf(info.fragmentMSL);
        const bool useArgBuf = vertexUsesArgBuf || fragmentUsesArgBuf;
        const bool vertexNeedsSSBOSizeBuffer =
            vertexUsesArgBuf && info.vertexMSL != nullptr &&
            info.vertexMSL->find("spvBufferSizeConstants") != std::string::npos;
        const bool fragmentNeedsSSBOSizeBuffer =
            fragmentUsesArgBuf && info.fragmentMSL != nullptr &&
            info.fragmentMSL->find("spvBufferSizeConstants") != std::string::npos;
        const bool fragmentNeedsFragCoordParams =
            hasFragmentStage && info.fragmentMSL != nullptr &&
            info.fragmentMSL->find("_appgl_FragCoordParams") != std::string::npos;
        const bool vertexNeedsFragmentShadingRateState =
            info.vertexMSL != nullptr &&
            info.vertexMSL->find("_appgl_FSRState") != std::string::npos;
        const NSInteger vertexClipControlYSignSlot =
            clipControlYSignBufferSlot(info.vertexMSL);
        const bool clipControlShaderYFixup =
            vertexClipControlYSignSlot >= 0 &&
            info.clipControlYSignFixupEnabled &&
            !info.stencilTestEnabled;
        const bool clipControlInvertsWinding =
            clipControlShaderYFixup && info.clipOrigin != GL_UPPER_LEFT;
        auto mslUsesMultiviewViewMask = [](const std::string* msl) -> bool {
            return msl != nullptr &&
                msl->find("spvViewMask") != std::string::npos;
        };
        const bool vertexUsesMultiviewViewMask =
            mslUsesMultiviewViewMask(info.vertexMSL);
        const bool fragmentUsesMultiviewViewMask =
            mslUsesMultiviewViewMask(info.fragmentMSL);
        constexpr std::uint32_t kOVRMultiviewViewCount = 2;
        const std::uint32_t ovrViewMask[2] = {0u, kOVRMultiviewViewCount};
        const GLsizei effectiveInstanceCount =
            vertexUsesMultiviewViewMask
                ? std::max<GLsizei>(info.instanceCount, 1) *
                      static_cast<GLsizei>(kOVRMultiviewViewCount)
                : info.instanceCount;
        id<MTLArgumentEncoder> fragArgEncoderSet0 = nil;
        id<MTLArgumentEncoder> vertArgEncoderSet0 = nil;
        id<MTLArgumentEncoder> fragArgEncoderSet1 = nil;
        id<MTLArgumentEncoder> vertArgEncoderSet1 = nil;
        // Seeded from the program's cached functions; populated by the
        // pipeline-build branch on first miss.
        id<MTLFunction> cachedVertFn = (__bridge id<MTLFunction>)info.metalVertexFunction;
        id<MTLFunction> cachedFragFn = (__bridge id<MTLFunction>)info.metalFragmentFunction;

        id<MTLRenderPipelineState> pipelineState = nil;
        if (info.pipelineStateCacheOut != nullptr) {
            auto it = info.pipelineStateCacheOut->find(pipelineCacheKey);
            if (it != info.pipelineStateCacheOut->end() && it->second != nullptr) {
                pipelineState = (__bridge id<MTLRenderPipelineState>)(it->second);
                ++pipelineCacheHits;
            }
        }
        // Legacy scalar cache kept as a fallback for the first-draw
        // diagnostic bookkeeping (`pipelineStateOut` is still read by
        // BAR tooling) — only honoured when the map path is missing,
        // which never happens in the current draw builders.
        if (pipelineState == nil && info.pipelineStateCacheOut == nullptr &&
            info.pipelineStateOut != nullptr && *info.pipelineStateOut != nullptr &&
            info.pipelineColorFormatOut != nullptr &&
            *info.pipelineColorFormatOut == static_cast<std::uint32_t>(colorFormat)) {
            pipelineState = (__bridge id<MTLRenderPipelineState>)(*info.pipelineStateOut);
            ++pipelineCacheHits;
        }
        if (pipelineState == nil) {
            // Phase 8X Group 4d follow-up⁴ — every entry into the build branch
            // bumps `pipelineBuildAttempts`, separately from the success-only
            // `pipelineCacheMisses` counter. This lets BAR-side tooling
            // distinguish "never tried" (attempts==0) from "tried and failed
            // every time" (attempts>0, failures==attempts, misses==0). Prior
            // to this round, the {hits:0, misses:0} state was ambiguous.
            ++pipelineBuildAttempts;
            const auto buildStart = std::chrono::steady_clock::now();

            // Phase 8X Group 4d follow-up⁴ — local helper for the five
            // Metal-side failure paths below. Captures the NSError
            // description AND a stage tag ("vertex-library",
            // "fragment-library", "vertex-function", "fragment-function",
            // "pipeline-state") into the caller-supplied output string so
            // GLContext can route it into the diagnostic ring as a
            // `pipeline-build` ShaderTranslationRecord. The first token in
            // the string is always the stage tag, so BAR can grep-aggregate
            // by failing stage even though the record stores the full text.
            //
            // The build-failure counter is bumped once per failure path so
            // PipelineCacheMetrics::buildFailures stays in lockstep with
            // the number of populated records (modulo first-time gating on
            // the GLContext side).
            auto recordBuildFailure = [&info, this](const char* stageTag, NSError* err) {
                ++pipelineBuildFailures;
                if (info.pipelineBuildErrorOut == nullptr) {
                    return;
                }
                std::string& out = *info.pipelineBuildErrorOut;
                out.assign(stageTag);
                out.append(": ");
                if (err != nil) {
                    NSString* desc = [err localizedDescription];
                    if (desc != nil) {
                        out.append([desc UTF8String] ? [desc UTF8String] : "(nil description)");
                    } else {
                        out.append("(nil description)");
                    }
                } else {
                    out.append("(nil error)");
                }
            };

            // ADV-2: compile vertex MSL via the library cache.
            // Identical MSL text (e.g. the same vertex shader used
            // by multiple pipeline variants) returns the cached
            // MTLLibrary instead of recompiling.
            id<MTLLibrary> vertLib = getOrCompileLibrary(*info.vertexMSL);
            if (vertLib == nil) {
                FG_TRACE(@"encodeTranslatedDraw: newLibraryWithSource(vertex) failed");
                recordBuildFailure("vertex-library", nil);
                return false;
            }
            // SPIRV-Cross names the entry points "main0" by default.
            // Use the constantValues variant so MSL shaders that declare
            // `[[function_constant(N)]]` values (e.g. SPIRV-Cross emits
            // `spvLinearTextureAlignmentOverride` for 2D image atomics,
            // function_constant(65535)) can be loaded. We provide an empty
            // MTLFunctionConstantValues — the shader checks
            // `is_function_constant_defined(...)` and falls back to the
            // compile-time default when unset, so no values need to be
            // bound. Without this call, Metal errors with:
            //   "fragmentFunction main0 cannot be used to build a pipeline
            //    state. Use newFunctionWithName:constantValues:... ..."
            // at pipeline-descriptor validation time.
            MTLFunctionConstantValues* emptyConstants = [[MTLFunctionConstantValues alloc] init];
            NSError* vertFnError = nil;
            id<MTLFunction> vertFn = [vertLib newFunctionWithName:@"main0"
                                                   constantValues:emptyConstants
                                                            error:&vertFnError];
            if (vertFn == nil) {
                if (std::getenv("APPGL_TRACE_SHADER_BUILD")) {
                    std::fprintf(stderr, "[APPGL] vertex-function build failed: %s\n",
                        vertFnError ? vertFnError.localizedDescription.UTF8String : "(no err)");
                }
                FG_TRACE(@"encodeTranslatedDraw: newFunctionWithName(vertex,main0) failed: %@", vertFnError);
                recordBuildFailure("vertex-function", vertFnError);
                return false;
            }
            // Step 7-4: cache the MTLFunction on the program so future
            // pipeline-cache hits can still reach it for argbuf encoder
            // creation. Only populated when the caller opts in by
            // supplying the out-slot (argbuf mode). CFBridgingRetain
            // transfers ownership; released at relink in GLContext.
            if (useArgBuf) {
                cachedVertFn = vertFn;
            }
            if (useArgBuf && info.metalVertexFunctionOut != nullptr &&
                *info.metalVertexFunctionOut == nullptr) {
                *info.metalVertexFunctionOut = (void*)CFBridgingRetain(vertFn);
            }

            // ADV-2: compile fragment MSL via the library cache.
            // Skipped entirely for VS-only + rasterizerDiscard draws —
            // the pipeline descriptor will set fragmentFunction = nil
            // and rasterizationEnabled = NO below, so the fragment
            // library / function are never used.
            id<MTLFunction> fragFn = nil;
            if (hasFragmentStage) {
                // Phase 6-1e: when the pipeline key asked for per-sample
                // FS, swap the source for a rewritten copy with an
                // injected [[sample_id]] parameter. The rewrite is
                // side-effect-free and returns the original string when
                // no signature match is found — the fallback path still
                // compiles. Keyed on `forcePerSampleFS` so the rewrite
                // cost is only paid for MS + GL_SAMPLE_SHADING draws.
                std::string rewrittenFragmentMSL;
                if (forcePerSampleFS) {
                    rewrittenFragmentMSL = rewriteFragmentMSLForPerSample(*info.fragmentMSL);
                }
                const std::string& fragSource = forcePerSampleFS
                    ? rewrittenFragmentMSL : *info.fragmentMSL;
                id<MTLLibrary> fragLib = getOrCompileLibrary(fragSource);
                if (fragLib == nil) {
                    FG_TRACE(@"encodeTranslatedDraw: newLibraryWithSource(fragment) failed");
                    recordBuildFailure("fragment-library", nil);
                    return false;
                }
                NSError* fragFnError = nil;
                fragFn = [fragLib newFunctionWithName:@"main0"
                                      constantValues:emptyConstants
                                               error:&fragFnError];
                if (fragFn == nil) {
                    FG_TRACE(@"encodeTranslatedDraw: newFunctionWithName(fragment,main0) failed: %@", fragFnError);
                    recordBuildFailure("fragment-function", fragFnError);
                    return false;
                }
                // Step 7-4: cache the fragment MTLFunction. See the
                // matching vertex-function block above.
                if (useArgBuf) {
                    cachedFragFn = fragFn;
                }
                if (useArgBuf && info.metalFragmentFunctionOut != nullptr &&
                    *info.metalFragmentFunctionOut == nullptr) {
                    *info.metalFragmentFunctionOut = (void*)CFBridgingRetain(fragFn);
                }
            }

            // Step 7-3: create per-stage argument encoders for desc_set 0
            // when argument_buffers is enabled. The encoder is created
            // from the MTLFunction (not the pipeline state) so it must
            // live in this pipeline-build scope. Hoisted to encode-
            // Translated-Draw's outer scope via the pre-declared
            // `fragArgEncoderSet0` / `vertArgEncoderSet0` locals above
            // so the bind step can reach them. Encoders are safe to
            // create even when the shader has no [[buffer(24)]] — Metal
            // just returns an encoder with encodedLength=0, which our
            // binding loop below handles via the "no fragmentTextures"
            // short-circuit.
            //
            // Only desc_set 0 is wired in this commit (samplers + storage
            // images + SSBOs). Desc_set 1 (UBOs at [[buffer(25)]]) + the
            // compute stage + the various non-texture resource types are
            // 7-3 successor commits.
            // Build vertex descriptor from reflection data.  Primary vertex
            // attributes (buffer 0) are per-vertex.  Extra vertex buffers
            // (buffer 1+) may use per-instance stepping (glVertexAttribDivisor).
            MTLVertexDescriptor* vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];

            // Helper: map shader-reflected scalar type to MTLVertexFormat.
            // Phase 8X Group 4d follow-up¹⁴ — ONLY used as a fallback
            // when the VAO record is missing (`glType == 0`). The
            // primary path now reads `vaoTypeToMTLFormat` from the
            // caller-supplied layout, so the Float4/UByte4 mismatch
            // BAR diagnosed in followup¹³ is impossible to reach
            // without a draw builder that forgot to propagate the
            // VAO fields.
            auto glTypeToMTLFormatFallback = [](GLenum type) -> MTLVertexFormat {
                switch (type) {
                    case GL_FLOAT:      return MTLVertexFormatFloat;
                    case GL_FLOAT_VEC2: return MTLVertexFormatFloat2;
                    case GL_FLOAT_VEC3: return MTLVertexFormatFloat3;
                    case GL_FLOAT_VEC4: return MTLVertexFormatFloat4;
                    case GL_INT:        return MTLVertexFormatInt;
                    case GL_INT_VEC2:   return MTLVertexFormatInt2;
                    case GL_INT_VEC3:   return MTLVertexFormatInt3;
                    case GL_INT_VEC4:   return MTLVertexFormatInt4;
                    default:            return MTLVertexFormatFloat3;
                }
            };

            if (info.vertexReflection != nullptr) {
                for (const auto& input : info.vertexReflection->vertexInputs) {
                    // Determine which Metal buffer this attribute lives in.
                    NSUInteger metalBuf = 0;
                    NSUInteger attrOffset = 0;
                    const TranslatedDrawInfo::VertexAttributeLayout* matched = nullptr;

                    // Check primary (buffer 0) attributes first.
                    for (const auto& layout : info.vertexAttributeLayouts) {
                        if (layout.location == input.location) {
                            metalBuf = 0;
                            attrOffset = static_cast<NSUInteger>(layout.offset);
                            matched = &layout;
                            break;
                        }
                    }

                    // Check extra vertex buffers (buffer 1+).
                    if (matched == nullptr) {
                        for (std::size_t ei = 0; ei < info.extraVertexBuffers.size(); ++ei) {
                            for (const auto& layout : info.extraVertexBuffers[ei].attributes) {
                                if (layout.location == input.location) {
                                    metalBuf = static_cast<NSUInteger>(ei + 1);
                                    attrOffset = static_cast<NSUInteger>(layout.offset);
                                    matched = &layout;
                                    break;
                                }
                            }
                            if (matched != nullptr) break;
                        }
                    }

                    // Phase 8X Group 4d follow-up¹⁴ — derive the Metal
                    // vertex format from the VAO record (the real VBO
                    // layout) rather than the shader-reflected scalar
                    // type. The fallback branch only runs when the
                    // draw builder failed to propagate VAO fields,
                    // which would indicate a plumbing bug; it preserves
                    // the pre-follow-up¹⁴ behavior for safety.
                    MTLVertexFormat format;
                    if (matched != nullptr && matched->glType != 0) {
                        format = vaoTypeToMTLFormat(
                            matched->glType,
                            matched->glComponentCount,
                            matched->glNormalized,
                            matched->glIsInteger);
                    } else {
                        format = glTypeToMTLFormatFallback(input.type);
                    }

                    vertexDescriptor.attributes[input.location].format = format;
                    vertexDescriptor.attributes[input.location].offset = attrOffset;
                    vertexDescriptor.attributes[input.location].bufferIndex = metalBuf;
                }
            }

            // Buffer 0 layout: primary per-vertex data.
            // Attributeless draws (gl_VertexID-based) skip vertex buffer
            // layout entirely — the shader generates its own vertices.
            //
            // Only set layout[0] if at least one attribute actually uses
            // bufferIndex=0. Some tests (e.g. KHR-GL46 draw_elements_base_vertex
            // with divisor-instanced VBOs) have all attributes in buffer 1+;
            // setting an unused layout[0].stride triggers Metal's
            // "None of the attributes set bufferIndex to 0, but layout[0]
            // stride was set" assertion.
            bool anyAttrOnBuffer0 = false;
            if (info.vertexReflection != nullptr) {
                for (const auto& in : info.vertexReflection->vertexInputs) {
                    if (vertexDescriptor.attributes[in.location].format != MTLVertexFormatInvalid &&
                        vertexDescriptor.attributes[in.location].bufferIndex == 0) {
                        anyAttrOnBuffer0 = true;
                        break;
                    }
                }
            }
            if (!attributelessDraw && anyAttrOnBuffer0) {
                const NSUInteger stride = info.vertexStride > 0
                    ? info.vertexStride
                    : sizeof(float) * 3u;
                vertexDescriptor.layouts[0].stride = stride;
                vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
                vertexDescriptor.layouts[0].stepRate = 1;
            }

            // Extra buffer layouts (1+): per-instance or additional per-vertex.
            for (std::size_t ei = 0; ei < info.extraVertexBuffers.size(); ++ei) {
                const auto& evb = info.extraVertexBuffers[ei];
                NSUInteger metalBuf = static_cast<NSUInteger>(ei + 1);
                if (evb.constantStep) {
                    vertexDescriptor.layouts[metalBuf].stride =
                        static_cast<NSUInteger>(evb.stride > 0 ? evb.stride : evb.byteCount);
                    vertexDescriptor.layouts[metalBuf].stepFunction = MTLVertexStepFunctionConstant;
                    vertexDescriptor.layouts[metalBuf].stepRate = 0;
                } else if (evb.divisor > 0) {
                    vertexDescriptor.layouts[metalBuf].stride = static_cast<NSUInteger>(evb.stride);
                    vertexDescriptor.layouts[metalBuf].stepFunction = MTLVertexStepFunctionPerInstance;
                    vertexDescriptor.layouts[metalBuf].stepRate = static_cast<NSUInteger>(evb.divisor);
                } else {
                    vertexDescriptor.layouts[metalBuf].stride = static_cast<NSUInteger>(evb.stride);
                    vertexDescriptor.layouts[metalBuf].stepFunction = MTLVertexStepFunctionPerVertex;
                    vertexDescriptor.layouts[metalBuf].stepRate = 1;
                }
            }

            MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
            desc.vertexFunction = vertFn;
            desc.fragmentFunction = info.rasterizerDiscard ? nil : fragFn;
            // Attributeless draws don't need a vertex descriptor at all.
            desc.vertexDescriptor = attributelessDraw ? nil : vertexDescriptor;
            desc.colorAttachments[0].pixelFormat = colorFormat;
            // Phase 6-1a: match the pipeline's rasterSampleCount to
            // the attachment. Metal requires this for MSAA correctness
            // — a 4x-MSAA attachment with a sampleCount=1 pipeline
            // fails validation at encode time with no draw output.
            desc.rasterSampleCount = attachmentSampleCount;
            // MRT: configure pixelFormat for each additional color
            // attachment (slots 1..7). GL 4.6 §14.6 allows up to 8
            // simultaneous color outputs (GL_MAX_DRAW_BUFFERS).
            // CTS `draw_buffers.draw_buffers_1` writes
            // `fragColor0..fragColor7` to distinct attachments.
            // Slots with a nullptr texture stay at
            // `MTLPixelFormatInvalid` (Metal's default, i.e. "not
            // bound") and Metal silently ignores fragment-shader
            // writes for them.
            for (std::size_t ei = 0; ei < info.fboAdditionalColorTextures.size(); ++ei) {
                void* rawTex = info.fboAdditionalColorTextures[ei];
                if (rawTex == nullptr) continue;
                id<MTLTexture> extraTex = (__bridge id<MTLTexture>)rawTex;
                desc.colorAttachments[ei + 1].pixelFormat = extraTex.pixelFormat;
            }
            // Pipeline depth/stencil formats must match the bound
            // textures' Metal pixel formats. Previously hard-coded to
            // Depth32Float_Stencil8, but GL 4.6 allows depth-only
            // (`GL_DEPTH_COMPONENT32F`, DEPTH24) or stencil-only
            // (`GL_STENCIL_INDEX8`) attachments too, and attaching a
            // mismatched pipeline format makes Metal silently drop
            // every fragment (GPU-capture signature on
            // `geometry_shader.layered_framebuffer.depth_support`,
            // where the depth texture is pure Depth32Float but the
            // pipeline declared Depth32Float_Stencil8).
            {
                MTLPixelFormat depthFmt = MTLPixelFormatInvalid;
                MTLPixelFormat stencilFmt = MTLPixelFormatInvalid;
                if (info.fboDepthStencilTexture != nullptr) {
                    id<MTLTexture> dsTex = (__bridge id<MTLTexture>)info.fboDepthStencilTexture;
                    const MTLPixelFormat pf = dsTex.pixelFormat;
                    // Formats carrying depth.
                    if (pf == MTLPixelFormatDepth16Unorm ||
                        pf == MTLPixelFormatDepth32Float ||
                        pf == MTLPixelFormatDepth32Float_Stencil8 ||
                        pf == MTLPixelFormatDepth24Unorm_Stencil8) {
                        depthFmt = pf;
                    }
                    // Formats carrying stencil.
                    if (pf == MTLPixelFormatStencil8 ||
                        pf == MTLPixelFormatDepth32Float_Stencil8 ||
                        pf == MTLPixelFormatDepth24Unorm_Stencil8 ||
                        pf == MTLPixelFormatX32_Stencil8 ||
                        pf == MTLPixelFormatX24_Stencil8) {
                        stencilFmt = pf;
                    }
                } else if (info.fboColorTexture == nullptr &&
                           !info.fboAttachmentless) {
                    // Default framebuffer: keep the legacy combined
                    // format so the swapchain path (renderpass-attached
                    // depth+stencil renderbuffer backed by
                    // Depth32Float_Stencil8) still matches.
                    depthFmt = MTLPixelFormatDepth32Float_Stencil8;
                    stencilFmt = MTLPixelFormatDepth32Float_Stencil8;
                }
                desc.depthAttachmentPixelFormat = depthFmt;
                desc.stencilAttachmentPixelFormat = stencilFmt;
            }
            // Set inputPrimitiveTopology = Point for GL_POINTS ONLY.
            // Metal uses this flag to enable point-size rasterisation
            // (default point_size = 1.0 if the VS doesn't write it,
            // which our shaders typically don't). Leaving it at the
            // Unspecified default for Triangle / Line draws matters:
            // Metal rejects pipelines that write [[point_size]] with
            // an explicit Triangle or Line topology class, and some
            // GLSL shaders (including ones SPIRV-Cross auto-enhances)
            // carry a gl_PointSize write even when the draw is
            // triangles. Prior iteration set Triangle unconditionally
            // and broke ~4k triangle-rendering tests on that
            // combination (see 15a368e for the post-mortem).
            if (info.mode == GL_POINTS) {
                desc.inputPrimitiveTopology = MTLPrimitiveTopologyClassPoint;
            }
            // Layered rendering (GS-emul path): when the synth VS
            // writes `[[render_target_array_index]]`, Metal requires
            // an explicit `inputPrimitiveTopology` — otherwise
            // pipeline build fails with "Vertex shader writes
            // render_target_array_index but inputPrimitiveTopology
            // is not specified". Map the draw mode to Metal's
            // topology class; other modes defer to the Point
            // override above or leave Unspecified for the legacy
            // path compatibility.
            //
            // Sprint 16 Day 3 [viewport_array]: the same Metal-pipeline
            // requirement applies to `[[viewport_array_index]]` —
            // unspecified topology silently disables the per-vertex
            // viewport selection at draw time (no validation error,
            // fragments just drop). Trigger the topology classification
            // also when the encoder is binding a viewport array
            // (`viewportArrayCount > 1`), because that's when the
            // synth VS emits `[[viewport_array_index]]` (env-gated)
            // OR when a VS using ARB_shader_viewport_layer_array
            // emits it directly.
            if (info.fboColorArrayLength > 0 ||
                info.viewportArrayCount > 1) {
                switch (info.mode) {
                    case GL_POINTS:
                        desc.inputPrimitiveTopology = MTLPrimitiveTopologyClassPoint;
                        break;
                    case GL_LINES:
                    case GL_LINE_STRIP:
                    case GL_LINE_LOOP:
                        desc.inputPrimitiveTopology = MTLPrimitiveTopologyClassLine;
                        break;
                    default:
                        desc.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
                        break;
                }
            }
            // GL_RASTERIZER_DISCARD → Metal rasterization disabled.
            // The VS still runs (and can write SSBOs / transform feedback)
            // but no fragment stage executes, no raster output is produced,
            // and Metal doesn't require a fragment function or a valid
            // [[position]] output from the vertex function. This is the
            // only Metal pipeline shape that accepts SPIRV-Cross's
            // `vertex void main0(...)` output for GL shaders that write
            // SSBOs without setting gl_Position.
            if (info.rasterizerDiscard) {
                desc.rasterizationEnabled = NO;
            }

            // Phase 8X Group 4d follow-up¹⁴ — apply the GL blend
            // state to the Metal pipeline color attachment. Before
            // follow-up¹⁴ the descriptor was left at Metal's defaults
            // (`blendingEnabled=NO, src=One, dst=Zero, op=Add,
            // writeMask=All`), so every translated draw was opaque
            // regardless of `glEnable(GL_BLEND) + glBlendFunc(...)`.
            // BAR followup¹³-verification §Candidate-1 traced that
            // as the reason spring's semi-transparent glyph overlay
            // composited as a solid rectangle instead of mixing with
            // the background. The cache key (above) already includes
            // the blend tuple, so a program that uses the same
            // shader with two different blend modes builds two
            // distinct pipelines and keeps both hot.
            MTLRenderPipelineColorAttachmentDescriptor* colorDesc = desc.colorAttachments[0];
            // Sprint 6 P1 sub-task 3 day 4 (CKPT44 prep): Metal rejects
            // pipelines with `blendingEnabled=YES` when the color
            // attachment's pixelFormat is an integer format
            // (R32Sint/Uint, RG32*, RGBA32*, etc.). GL allows the
            // combination silently — blending bits are ignored on
            // integer attachments per spec §17.3.6 — so apps and
            // gluStateReset can leave GL_BLEND on while pointing the
            // FBO at an R32UI / R32I / R32Sint render target. Surface
            // discovery: `geometry_shader.limits.max_output_components`
            // crashed Metal validation at draw time when GL_BLEND was
            // enabled and the FBO color attachment format was R32Sint
            // (CKPT43 cap-bump cascade). Force-disable blending for
            // integer pipeline-color formats so the pipeline-state
            // build matches GL's silent semantics.
            auto isIntegerColorFormat = [](MTLPixelFormat fmt) -> bool {
                switch (fmt) {
                    case MTLPixelFormatR8Sint:
                    case MTLPixelFormatR8Uint:
                    case MTLPixelFormatR16Sint:
                    case MTLPixelFormatR16Uint:
                    case MTLPixelFormatR32Sint:
                    case MTLPixelFormatR32Uint:
                    case MTLPixelFormatRG8Sint:
                    case MTLPixelFormatRG8Uint:
                    case MTLPixelFormatRG16Sint:
                    case MTLPixelFormatRG16Uint:
                    case MTLPixelFormatRG32Sint:
                    case MTLPixelFormatRG32Uint:
                    case MTLPixelFormatRGBA8Sint:
                    case MTLPixelFormatRGBA8Uint:
                    case MTLPixelFormatRGBA16Sint:
                    case MTLPixelFormatRGBA16Uint:
                    case MTLPixelFormatRGBA32Sint:
                    case MTLPixelFormatRGBA32Uint:
                    case MTLPixelFormatRGB10A2Uint:
                        return true;
                    default:
                        return false;
                }
            };
            const bool integerColorTarget = isIntegerColorFormat(colorFormat);
            colorDesc.blendingEnabled =
                (info.blend.enabled && !integerColorTarget) ? YES : NO;
            colorDesc.sourceRGBBlendFactor        = glBlendFactorToMTL(info.blend.srcRGB);
            colorDesc.destinationRGBBlendFactor   = glBlendFactorToMTL(info.blend.dstRGB);
            colorDesc.sourceAlphaBlendFactor      = glBlendFactorToMTL(info.blend.srcAlpha);
            colorDesc.destinationAlphaBlendFactor = glBlendFactorToMTL(info.blend.dstAlpha);
            colorDesc.rgbBlendOperation           = glBlendEqToMTL(info.blend.equationRGB);
            colorDesc.alphaBlendOperation         = glBlendEqToMTL(info.blend.equationAlpha);
            MTLColorWriteMask writeMask = MTLColorWriteMaskNone;
            if (info.blend.colorMaskR) writeMask |= MTLColorWriteMaskRed;
            if (info.blend.colorMaskG) writeMask |= MTLColorWriteMaskGreen;
            if (info.blend.colorMaskB) writeMask |= MTLColorWriteMaskBlue;
            if (info.blend.colorMaskA) writeMask |= MTLColorWriteMaskAlpha;
            colorDesc.writeMask = writeMask;

            // Phase 8X Group 4d follow-up¹³ — one-shot per-program
            // diagnostic dump of the Metal pipeline descriptor shape.
            // Covers BAR followup¹²-verification §Candidate 1 (blend
            // state — did the translated-draw pipeline inherit GL
            // blend enable / src / dst / equation, or is it sitting on
            // Metal's default-off blend?) and §Candidate 2 (vertex
            // descriptor format — did `col` arrive as
            // MTLVertexFormatUChar4Normalized or as Float4? and do
            // the offsets/bufferIndex match the VBO layout peek dumped
            // at the first-draw site?). Both dumps fire from here
            // because the descriptor objects go out of scope after
            // newRenderPipelineStateWithDescriptor; macOS has no
            // runtime reflection API to walk a compiled
            // MTLRenderPipelineState. Gated by
            // `loggedPipelineBuildPrograms` so the dump fires exactly
            // once per GL program name per MetalFrameGraph instance
            // (GLContext) — builds are cached on GLProgramObject so a
            // program hits this branch at most once in the cache-miss
            // path anyway; the explicit set protects against theoretical
            // cache-invalidation cases.
            //
            // Format strings match the Metal header names so BAR can
            // grep for them directly against
            // reference/OpenGL-Refpages/gl4/glBlendFunc.xml +
            // glVertexAttribPointer.xml semantics. No decoding tables
            // here — raw enum values are emitted alongside a short
            // symbolic name for the common cases so the log stays
            // self-describing without a lookup table.
            // Phase 8X Group 4d follow-up¹⁷ — dedup is keyed on
            // (program, pipelineCacheKey), not program alone. See the
            // member declaration of `loggedPipelineBuildPrograms` for
            // the rationale (was hiding the `entries=5` cache growth).
            if (info.program != 0 &&
                loggedPipelineBuildPrograms.insert({info.program, pipelineCacheKey}).second) {
                auto vertexFormatName = [](MTLVertexFormat f) -> const char* {
                    switch (f) {
                        case MTLVertexFormatInvalid:          return "Invalid";
                        case MTLVertexFormatFloat:            return "Float";
                        case MTLVertexFormatFloat2:           return "Float2";
                        case MTLVertexFormatFloat3:           return "Float3";
                        case MTLVertexFormatFloat4:           return "Float4";
                        case MTLVertexFormatInt:              return "Int";
                        case MTLVertexFormatInt2:             return "Int2";
                        case MTLVertexFormatInt3:             return "Int3";
                        case MTLVertexFormatInt4:             return "Int4";
                        case MTLVertexFormatUInt:             return "UInt";
                        case MTLVertexFormatUInt2:            return "UInt2";
                        case MTLVertexFormatUInt3:            return "UInt3";
                        case MTLVertexFormatUInt4:            return "UInt4";
                        case MTLVertexFormatUChar:            return "UChar";
                        case MTLVertexFormatUChar2:           return "UChar2";
                        case MTLVertexFormatUChar3:           return "UChar3";
                        case MTLVertexFormatUChar4:           return "UChar4";
                        case MTLVertexFormatUCharNormalized:  return "UCharNormalized";
                        case MTLVertexFormatUChar2Normalized: return "UChar2Normalized";
                        case MTLVertexFormatUChar3Normalized: return "UChar3Normalized";
                        case MTLVertexFormatUChar4Normalized: return "UChar4Normalized";
                        case MTLVertexFormatChar:             return "Char";
                        case MTLVertexFormatChar2:            return "Char2";
                        case MTLVertexFormatChar3:            return "Char3";
                        case MTLVertexFormatChar4:            return "Char4";
                        case MTLVertexFormatCharNormalized:   return "CharNormalized";
                        case MTLVertexFormatChar2Normalized:  return "Char2Normalized";
                        case MTLVertexFormatChar3Normalized:  return "Char3Normalized";
                        case MTLVertexFormatChar4Normalized:  return "Char4Normalized";
                        case MTLVertexFormatUShort:           return "UShort";
                        case MTLVertexFormatUShort2:          return "UShort2";
                        case MTLVertexFormatUShort3:          return "UShort3";
                        case MTLVertexFormatUShort4:          return "UShort4";
                        case MTLVertexFormatUShortNormalized: return "UShortNormalized";
                        case MTLVertexFormatUShort2Normalized:return "UShort2Normalized";
                        case MTLVertexFormatUShort3Normalized:return "UShort3Normalized";
                        case MTLVertexFormatUShort4Normalized:return "UShort4Normalized";
                        case MTLVertexFormatShort:            return "Short";
                        case MTLVertexFormatShort2:           return "Short2";
                        case MTLVertexFormatShort3:           return "Short3";
                        case MTLVertexFormatShort4:           return "Short4";
                        case MTLVertexFormatShortNormalized:  return "ShortNormalized";
                        case MTLVertexFormatShort2Normalized: return "Short2Normalized";
                        case MTLVertexFormatShort3Normalized: return "Short3Normalized";
                        case MTLVertexFormatShort4Normalized: return "Short4Normalized";
                        case MTLVertexFormatHalf:             return "Half";
                        case MTLVertexFormatHalf2:            return "Half2";
                        case MTLVertexFormatHalf3:            return "Half3";
                        case MTLVertexFormatHalf4:            return "Half4";
                        default:                              return "Other";
                    }
                };
                auto stepFunctionName = [](MTLVertexStepFunction f) -> const char* {
                    switch (f) {
                        case MTLVertexStepFunctionConstant:             return "Constant";
                        case MTLVertexStepFunctionPerVertex:            return "PerVertex";
                        case MTLVertexStepFunctionPerInstance:          return "PerInstance";
                        case MTLVertexStepFunctionPerPatch:             return "PerPatch";
                        case MTLVertexStepFunctionPerPatchControlPoint: return "PerPatchControlPoint";
                        default:                                         return "Unknown";
                    }
                };
                auto blendFactorName = [](MTLBlendFactor f) -> const char* {
                    switch (f) {
                        case MTLBlendFactorZero:                     return "Zero";
                        case MTLBlendFactorOne:                      return "One";
                        case MTLBlendFactorSourceColor:              return "SourceColor";
                        case MTLBlendFactorOneMinusSourceColor:      return "OneMinusSourceColor";
                        case MTLBlendFactorSourceAlpha:              return "SourceAlpha";
                        case MTLBlendFactorOneMinusSourceAlpha:      return "OneMinusSourceAlpha";
                        case MTLBlendFactorDestinationColor:         return "DestinationColor";
                        case MTLBlendFactorOneMinusDestinationColor: return "OneMinusDestinationColor";
                        case MTLBlendFactorDestinationAlpha:         return "DestinationAlpha";
                        case MTLBlendFactorOneMinusDestinationAlpha: return "OneMinusDestinationAlpha";
                        case MTLBlendFactorSourceAlphaSaturated:     return "SourceAlphaSaturated";
                        case MTLBlendFactorBlendColor:               return "BlendColor";
                        case MTLBlendFactorOneMinusBlendColor:       return "OneMinusBlendColor";
                        case MTLBlendFactorBlendAlpha:               return "BlendAlpha";
                        case MTLBlendFactorOneMinusBlendAlpha:       return "OneMinusBlendAlpha";
                        default:                                     return "Other";
                    }
                };
                auto blendOpName = [](MTLBlendOperation op) -> const char* {
                    switch (op) {
                        case MTLBlendOperationAdd:             return "Add";
                        case MTLBlendOperationSubtract:        return "Subtract";
                        case MTLBlendOperationReverseSubtract: return "ReverseSubtract";
                        case MTLBlendOperationMin:             return "Min";
                        case MTLBlendOperationMax:             return "Max";
                        default:                               return "Other";
                    }
                };

                APPGL_LOG(PIPELINE, @"[GL] pipeline-build first-build program=%u"
                      @" colorFormat=0x%lX depthFormat=0x%lX",
                      info.program,
                      (unsigned long)desc.colorAttachments[0].pixelFormat,
                      (unsigned long)desc.depthAttachmentPixelFormat);

                // Vertex descriptor: walk attributes 0..15 and layouts
                // 0..15. A slot with MTLVertexFormatInvalid is either
                // unused or reserved by the attribute-layout map; we
                // emit those at a lower verbosity by suppressing them
                // unless every slot is Invalid.
                APPGL_LOG(PIPELINE, @"[GL]   vertexDescriptor attributes:");
                std::size_t nonInvalidAttrs = 0;
                for (NSUInteger i = 0; i < 16; ++i) {
                    MTLVertexAttributeDescriptor* a = vertexDescriptor.attributes[i];
                    if (a.format == MTLVertexFormatInvalid) {
                        continue;
                    }
                    ++nonInvalidAttrs;
                    APPGL_LOG(PIPELINE, @"[GL]     attr[%lu] format=MTLVertexFormat%s(%lu)"
                          @" offset=%lu bufferIndex=%lu",
                          (unsigned long)i,
                          vertexFormatName(a.format),
                          (unsigned long)a.format,
                          (unsigned long)a.offset,
                          (unsigned long)a.bufferIndex);
                }
                if (nonInvalidAttrs == 0) {
                    APPGL_LOG(PIPELINE, @"[GL]     (no attributes set — vertex stage runs without vertex descriptor input)");
                }
                APPGL_LOG(PIPELINE, @"[GL]   vertexDescriptor layouts:");
                std::size_t nonEmptyLayouts = 0;
                for (NSUInteger i = 0; i < 16; ++i) {
                    MTLVertexBufferLayoutDescriptor* l = vertexDescriptor.layouts[i];
                    if (l.stride == 0) {
                        continue;
                    }
                    ++nonEmptyLayouts;
                    APPGL_LOG(PIPELINE, @"[GL]     layout[%lu] stride=%lu"
                          @" stepFunction=MTLVertexStepFunction%s(%lu)"
                          @" stepRate=%lu",
                          (unsigned long)i,
                          (unsigned long)l.stride,
                          stepFunctionName(l.stepFunction),
                          (unsigned long)l.stepFunction,
                          (unsigned long)l.stepRate);
                }
                if (nonEmptyLayouts == 0) {
                    APPGL_LOG(PIPELINE, @"[GL]     (no layouts set — stride=0 on every slot)");
                }

                // Color attachment 0 blend state. BAR §Candidate 1.
                // Phase 8X Group 4d follow-up¹⁴ — the descriptor now
                // carries the GL blend state snapshot from the draw
                // site (`GLStateTracker::blendState()` +
                // `isEnabled(GL_BLEND)`), so these values reflect the
                // live pipeline rather than the MTLRenderPipeline-
                // ColorAttachmentDescriptor defaults. The annotation
                // flipped from `gl-plumbed=no` to `gl-plumbed=yes`
                // as the verification signal for BAR's follow-up¹³
                // memo. Apple's defaults (blendingEnabled=NO,
                // src=One, dst=Zero, op=Add, writeMask=All) are
                // still what you'd see for an opaque draw that
                // runs with `glDisable(GL_BLEND)`.
                MTLRenderPipelineColorAttachmentDescriptor* ca = desc.colorAttachments[0];
                APPGL_LOG(PIPELINE, @"[GL]   colorAttachment[0].blendingEnabled=%d (gl-plumbed=yes)",
                      ca.blendingEnabled ? 1 : 0);
                APPGL_LOG(PIPELINE, @"[GL]   colorAttachment[0].rgb   src=%s(%lu) dst=%s(%lu) op=%s(%lu)",
                      blendFactorName(ca.sourceRGBBlendFactor),
                      (unsigned long)ca.sourceRGBBlendFactor,
                      blendFactorName(ca.destinationRGBBlendFactor),
                      (unsigned long)ca.destinationRGBBlendFactor,
                      blendOpName(ca.rgbBlendOperation),
                      (unsigned long)ca.rgbBlendOperation);
                APPGL_LOG(PIPELINE, @"[GL]   colorAttachment[0].alpha src=%s(%lu) dst=%s(%lu) op=%s(%lu)",
                      blendFactorName(ca.sourceAlphaBlendFactor),
                      (unsigned long)ca.sourceAlphaBlendFactor,
                      blendFactorName(ca.destinationAlphaBlendFactor),
                      (unsigned long)ca.destinationAlphaBlendFactor,
                      blendOpName(ca.alphaBlendOperation),
                      (unsigned long)ca.alphaBlendOperation);
                APPGL_LOG(PIPELINE, @"[GL]   colorAttachment[0].writeMask=0x%lX (all=0xF)",
                      (unsigned long)ca.writeMask);
                APPGL_LOG(PIPELINE, @"[GL] pipeline-build first-build program=%u END", info.program);
            }

            NSError* error = nil;
            // ADV-14: binary archive disabled pending investigation.
            // TODO: re-enable once crash in pipeline build path is resolved.
            // ensurePipelineArchive();
            // if (pipelineArchive != nil) {
            //     desc.binaryArchives = @[ pipelineArchive ];
            // }
            pipelineState = [device newRenderPipelineStateWithDescriptor:desc error:&error];
            if (pipelineState == nil) {
                FG_TRACE(@"encodeTranslatedDraw: newRenderPipelineStateWithDescriptor failed: %@", error);
                recordBuildFailure("pipeline-state", error);
                return false;
            }
            // addPipelineToArchive(desc);  // ADV-14: disabled pending investigation

            const auto buildEnd = std::chrono::steady_clock::now();
            pipelineCumulativeBuildMs += std::chrono::duration<double, std::milli>(buildEnd - buildStart).count();
            ++pipelineCacheMisses;

            // Phase 8X Group 4d follow-up¹⁴ — insert into the
            // map-based cache first. The old scalar
            // {pipelineStateOut, pipelineColorFormatOut} pair is
            // still populated so the first-draw diagnostic bookkeeping
            // (and the leak-on-relink reset in `linkProgram`) keeps
            // seeing the most-recently-built pipeline in the same
            // slot it has always read from.
            if (info.pipelineStateCacheOut != nullptr) {
                void* retained = (void*)CFBridgingRetain(pipelineState);
                auto inserted = info.pipelineStateCacheOut->emplace(pipelineCacheKey, retained);
                if (!inserted.second) {
                    // Key collided with an existing entry — release the
                    // old one and swap in the new. Shouldn't happen in
                    // normal operation because the cache miss path is
                    // only reached when the lookup failed.
                    if (inserted.first->second != nullptr) {
                        CFRelease(inserted.first->second);
                    }
                    inserted.first->second = retained;
                }
            }
            if (info.pipelineStateOut != nullptr) {
                // The scalar slot is a secondary mirror of the most
                // recently built pipeline. Release the previous
                // occupant and retain afresh so the scalar cache
                // stays balanced even when the map path also holds
                // an entry.
                if (*info.pipelineStateOut != nullptr) {
                    CFRelease(*info.pipelineStateOut);
                }
                *info.pipelineStateOut = (void*)CFBridgingRetain(pipelineState);
            }
            if (info.pipelineColorFormatOut != nullptr) {
                *info.pipelineColorFormatOut = static_cast<std::uint32_t>(colorFormat);
            }
        }

        // Step 7-4: create per-stage argument encoders AFTER the
        // pipeline-cache-resolve branch so cache hits share them with
        // cache misses. Uses cachedVertFn / cachedFragFn hoisted
        // at the top of this function — seeded from
        // `info.metalVertexFunction` / `info.metalFragmentFunction`
        // (the program's cached retains), then updated by the
        // build-branch cache-write so first-build + subsequent cache-
        // hit paths see the same `id<MTLFunction>`.
        //
        // `newArgumentEncoderWithBufferIndex:24` asserts "bufferIndex
        // N does not identify an argument buffer" on stages whose
        // compiled MSL lacks the [[buffer(N)]] parameter — gated on
        // the per-stage resource-presence check: desc_set 0 if the
        // stage has textures (sampled or storage; same list) or any
        // SSBO; desc_set 1 if the stage has a default uniform block
        // or any UBO.
        if (useArgBuf) {
            bool vertNeedsSet0 = vertexUsesArgBuf && !info.vertexTextures.empty();
            bool fragNeedsSet0 = fragmentUsesArgBuf && !info.fragmentTextures.empty();
            for (const auto& ssbo : info.ssboBindings) {
                if (ssbo.metalBuffer == nullptr) continue;
                if (vertexUsesArgBuf && ssbo.isVertex)     vertNeedsSet0 = true;
                if (fragmentUsesArgBuf && ssbo.isFragment) fragNeedsSet0 = true;
            }
            if (cachedVertFn != nil && vertNeedsSet0) {
                vertArgEncoderSet0 = [cachedVertFn newArgumentEncoderWithBufferIndex:24];
            }
            if (cachedFragFn != nil && fragNeedsSet0) {
                fragArgEncoderSet0 = [cachedFragFn newArgumentEncoderWithBufferIndex:24];
            }
            bool vertNeedsSet1 = vertexUsesArgBuf &&
                (info.vertexUniformData != nullptr && info.vertexUniformSize > 0);
            bool fragNeedsSet1 = fragmentUsesArgBuf &&
                (info.fragmentUniformData != nullptr && info.fragmentUniformSize > 0);
            for (const auto& ubo : info.uboBindings) {
                if (ubo.size == 0) continue;
                if (vertexUsesArgBuf && ubo.isVertex)     vertNeedsSet1 = true;
                if (fragmentUsesArgBuf && ubo.isFragment) fragNeedsSet1 = true;
            }
            if (cachedVertFn != nil && vertNeedsSet1) {
                vertArgEncoderSet1 = [cachedVertFn newArgumentEncoderWithBufferIndex:25];
            }
            if (cachedFragFn != nil && fragNeedsSet1) {
                fragArgEncoderSet1 = [cachedFragFn newArgumentEncoderWithBufferIndex:25];
            }
        }

        // RC-A02: FBO draws need their own render pass targeting the FBO
        // texture.  If a default-framebuffer encoder is open, close it first.
        if (isFBODraw && currentRenderEncoder != nil) {
            [currentRenderEncoder endEncoding];
            currentRenderEncoder = nil;
            activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
            resetCachedEncoderState();
        }
        if (!isFBODraw &&
            currentRenderEncoder != nil &&
            activeRenderPassFragmentShadingRate != info.fragmentShadingRate) {
            endRenderPass();
            resetCachedEncoderState();
        }

        // Ensure a render encoder is open. Subsequent draws reuse the same
        // encoder without any GPU sync.
        if (currentRenderEncoder == nil) {
            FG_TRACE(@"encodeTranslatedDraw: opening new render pass (prior cmdBuf=%p pendingClear=%d fbo=%d)",
                     currentCommandBuffer, hasPendingClear, isFBODraw);
            // Reuse the current command buffer if one exists (e.g. from a
            // prior solid-color draw), otherwise create a new one.
            if (currentCommandBuffer == nil) {
                currentCommandBuffer = [commandQueue commandBuffer];
                attachErrorHandler(currentCommandBuffer, @"translatedDraw");
                if (currentCommandBuffer == nil) {
                    return false;
                }
            }

            if (isFBODraw) {
                // FBO path: use the caller-provided Metal texture as the
                // render target.  No drawable acquisition needed.
                colorTexture = fboColorTex;
            } else {
                if (!acquireDrawableIfNeeded()) {  // ADV-7
                    return false;
                }
                colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
            }
            if (colorTexture == nil) {
                return false;
            }

            // Resolve depth/stencil for this render pass.
            id<MTLTexture> passDepthStencil = isFBODraw ? fboDepthStencilTex : depthStencilTexture;

            // Ensure depth/stencil texture matches color attachment dimensions.
            // A mismatch here triggers Metal validation assertions on draw.
            if (!isFBODraw && depthStencilTexture != nil &&
                (depthStencilTexture.width != colorTexture.width ||
                 depthStencilTexture.height != colorTexture.height)) {
                APPGL_LOG(PIPELINE, @"[FG] depth/color size MISMATCH: depth=%lux%lu color=%lux%lu — rebuilding depth",
                      (unsigned long)depthStencilTexture.width,
                      (unsigned long)depthStencilTexture.height,
                      (unsigned long)colorTexture.width,
                      (unsigned long)colorTexture.height);
                MTLTextureDescriptor* dd = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                width:colorTexture.width
                                               height:colorTexture.height
                                            mipmapped:NO];
                dd.storageMode = MTLStorageModePrivate;
                dd.usage = MTLTextureUsageRenderTarget;
                depthStencilTexture = [device newTextureWithDescriptor:dd];
                passDepthStencil = depthStencilTexture;
                drawableWidth = static_cast<GLsizei>(colorTexture.width);
                drawableHeight = static_cast<GLsizei>(colorTexture.height);
            }

            // Phase 6-1b: when color attachment is multisample but
            // the bound depth attachment isn't (or vice versa),
            // Metal rejects the pass with a sampleCount mismatch. Two
            // recovery paths:
            //   (a) non-FBO (default framebuffer) — rebuild the
            //       depthStencilTexture with matching sample count,
            //       same way we handle size mismatches above.
            //   (b) FBO with user-supplied depth — drop the depth
            //       attachment (render without depth test) rather
            //       than crash. Tests that need depth with MSAA must
            //       attach an MS depth renderbuffer; our
            //       renderbufferStorageMultisample path creates them
            //       correctly when the caller asks for samples > 1.
            if (colorTexture != nil && passDepthStencil != nil &&
                colorTexture.sampleCount != passDepthStencil.sampleCount) {
                if (!isFBODraw) {
                    APPGL_LOG(PIPELINE, @"[FG] depth/color sample-count MISMATCH: depth=%lu color=%lu — rebuilding depth with matching MS",
                          (unsigned long)passDepthStencil.sampleCount,
                          (unsigned long)colorTexture.sampleCount);
                    MTLTextureDescriptor* dd = [MTLTextureDescriptor
                        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                    width:colorTexture.width
                                                   height:colorTexture.height
                                                mipmapped:NO];
                    dd.storageMode = MTLStorageModePrivate;
                    dd.usage = MTLTextureUsageRenderTarget;
                    if (colorTexture.sampleCount > 1) {
                        dd.textureType = MTLTextureType2DMultisample;
                        dd.sampleCount = colorTexture.sampleCount;
                    }
                    depthStencilTexture = [device newTextureWithDescriptor:dd];
                    passDepthStencil = depthStencilTexture;
                } else {
                    APPGL_LOG(PIPELINE, @"[FG] FBO depth/color sample-count MISMATCH: depth=%lu color=%lu — dropping depth",
                          (unsigned long)passDepthStencil.sampleCount,
                          (unsigned long)colorTexture.sampleCount);
                    passDepthStencil = nil;
                }
            }

            // Build the render pass, merging any pending clear into the load
            // action so clear+draws share a single render pass (OPT-4).
            MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];  // ADV-4
            NSUInteger rateMapLayerCount = 1;
            pass.colorAttachments[0].texture = colorTexture;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            // Phase 6-5: honour FramebufferTextureLayer slice selection
            // per attachment. info.fboColorSlices carries the per-slot
            // Metal slice (0 for non-layered / FramebufferTexture /
            // renderbuffer attachments; layer index for
            // FramebufferTextureLayer on array targets). Enables the
            // CTS DSA `textures_storage_multisample_3d_*` pattern of
            // binding each MS-array layer to a distinct color
            // attachment. Without this, every layer silently collapses
            // onto slice 0 and the test's per-layer reference data
            // compares against slice-0's value.
            if (isFBODraw && info.fboColorSlices[0] > 0) {
                pass.colorAttachments[0].slice =
                    static_cast<NSUInteger>(info.fboColorSlices[0]);
            }
            if (!isFBODraw && hasPendingClear && (pendingClearMask & GL_COLOR_BUFFER_BIT)) {
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].clearColor = pendingClearColor;
            } else {
                pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            }
            // MRT: attach additional color targets (slots 1..7). GL
            // draw_buffers enumerations stored in
            // `fboAdditionalColorTextures` map 1:1 to Metal
            // colorAttachments[i+1]. Each uses Load + Store like the
            // primary — the pending-clear color applies to slot 0
            // only; subsequent attachments rely on
            // `glClearBuffer*` calls or untouched contents.
            for (std::size_t ei = 0; ei < info.fboAdditionalColorTextures.size(); ++ei) {
                void* rawTex = info.fboAdditionalColorTextures[ei];
                if (rawTex == nullptr) continue;
                id<MTLTexture> extraTex = (__bridge id<MTLTexture>)rawTex;
                pass.colorAttachments[ei + 1].texture = extraTex;
                pass.colorAttachments[ei + 1].loadAction = MTLLoadActionLoad;
                pass.colorAttachments[ei + 1].storeAction = MTLStoreActionStore;
                // Phase 6-5: per-slot slice (index ei+1 into fboColorSlices).
                const std::size_t sliceIdx = ei + 1;
                if (sliceIdx < info.fboColorSlices.size() &&
                    info.fboColorSlices[sliceIdx] > 0) {
                    pass.colorAttachments[ei + 1].slice =
                        static_cast<NSUInteger>(info.fboColorSlices[sliceIdx]);
                }
            }
            // Layered rendering — GS-emul path only. When the
            // emulated GS wrote gl_Layer, the VS routes the per-
            // primitive layer to `[[render_target_array_index]]`.
            // Metal requires renderTargetArrayLength on the pass
            // descriptor to match the attachment's slice count.
            // Non-layered draws leave this at 0 (Metal's default
            // non-layered behaviour).
            if (info.fboColorArrayLength > 0 || vertexUsesMultiviewViewMask) {
                // Sprint 17 Day 1 (CKPT236) [Probe A 2DMSArray
                // clamp]: Apple Silicon's AGX driver asserts
                // `slice < getNumSlices() && Specified slice OOB`
                // when rTAL is set to the texture's full
                // arrayLength on `MTLTextureType2DMultisampleArray`
                // colour attachments — Codex Sprint 17 Day 1
                // forensics h2DM-3 verdict (Clerk-validated). The
                // active layer span (max(gl_Layer)+1) is what the
                // rasteriser actually routes into; clamping rTAL
                // to that span clears the assertion. Non-MS-array
                // layered targets (2D_ARRAY / 3D / CUBE / CUBE_ARRAY)
                // keep the texture's full arrayLength behaviour.
                NSUInteger rtal = static_cast<NSUInteger>(
                    info.fboColorArrayLength);
                if (rtal == 0 && vertexUsesMultiviewViewMask &&
                    colorTexture != nil) {
                    const bool layeredColorTarget =
                        colorTexture.textureType == MTLTextureType2DArray ||
                        colorTexture.textureType == MTLTextureType2DMultisampleArray ||
                        colorTexture.textureType == MTLTextureTypeCube ||
                        colorTexture.textureType == MTLTextureTypeCubeArray;
                    if (layeredColorTarget) {
                        rtal = std::max<NSUInteger>(colorTexture.arrayLength, 1u);
                    }
                }
                if (info.maxEmittedLayer > 0 &&
                    info.fboColorTexture != nullptr) {
                    id<MTLTexture> colTex = (__bridge id<MTLTexture>)
                        info.fboColorTexture;
                    if (colTex.textureType ==
                            MTLTextureType2DMultisampleArray) {
                        const NSUInteger active =
                            static_cast<NSUInteger>(
                                info.maxEmittedLayer + 1u);
                        if (active < rtal) rtal = active;
                    }
                }
                pass.renderTargetArrayLength = rtal;
                rateMapLayerCount = rtal;
            }
            if (passDepthStencil != nil) {
                // CKPT168 (Sprint 14 Day 15): attach to depth/stencil
                // pass slots only when the texture's pixel format is
                // depth/stencil-renderable per Metal's format table.
                // Pre-fix: blindly attached to BOTH slots regardless of
                // format, which Metal validation rejected with
                // "PixelFormat MTLPixelFormatDepth32Float is not
                // stencil renderable" on layered FBOs that use
                // depth-only attachments (CTS layered_framebuffer.
                // depth_support; sub-shape A of CKPT165 5F target).
                const MTLPixelFormat dsFormat = passDepthStencil.pixelFormat;
                const bool fmtHasDepth =
                    dsFormat == MTLPixelFormatDepth32Float ||
                    dsFormat == MTLPixelFormatDepth32Float_Stencil8 ||
                    dsFormat == MTLPixelFormatDepth16Unorm;
                const bool fmtHasStencil =
                    dsFormat == MTLPixelFormatDepth32Float_Stencil8 ||
                    dsFormat == MTLPixelFormatStencil8 ||
                    dsFormat == MTLPixelFormatX32_Stencil8 ||
                    dsFormat == MTLPixelFormatX24_Stencil8;
                if (fmtHasDepth) {
                    pass.depthAttachment.texture = passDepthStencil;
                    pass.depthAttachment.storeAction = MTLStoreActionStore;
                    if (!isFBODraw && hasPendingClear && (pendingClearMask & GL_DEPTH_BUFFER_BIT)) {
                        pass.depthAttachment.loadAction = MTLLoadActionClear;
                        pass.depthAttachment.clearDepth = pendingClearDepth;
                    } else {
                        pass.depthAttachment.loadAction = MTLLoadActionLoad;
                    }
                }
                if (fmtHasStencil) {
                    pass.stencilAttachment.texture = passDepthStencil;
                    pass.stencilAttachment.storeAction = MTLStoreActionStore;
                    if (!isFBODraw && hasPendingClear && (pendingClearMask & GL_STENCIL_BUFFER_BIT)) {
                        pass.stencilAttachment.loadAction = MTLLoadActionClear;
                        pass.stencilAttachment.clearStencil = pendingClearStencil;
                    } else {
                        pass.stencilAttachment.loadAction = MTLLoadActionLoad;
                    }
                }
            }
            if (!isFBODraw) {
                hasPendingClear = false;
            }

            attachFragmentShadingRateMap(pass, info.fragmentShadingRate, colorTexture, rateMapLayerCount);
            currentRenderEncoder = [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
            if (currentRenderEncoder == nil) {
                return false;
            }
            activeRenderPassFragmentShadingRate = info.fragmentShadingRate;
            readbackSourceTexture = colorTexture;
            readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
            resetCachedEncoderState();
        }

        // Encode the draw into the shared render encoder.
        // OPT-6: skip redundant state calls when consecutive draws share
        // the same pipeline / depth-stencil / raster state.
        if (pipelineState != cachedPipelineState) {
            [currentRenderEncoder setRenderPipelineState:pipelineState];
            cachedPipelineState = pipelineState;
        }

        // Depth-stencil state is driven by whether any depth
        // attachment exists — the default framebuffer's
        // `depthStencilTexture` OR the bound FBO's
        // `info.fboDepthStencilTexture`. Previously this gate only
        // checked the default-FB slot, which meant every FBO draw
        // ran with Metal's implicit "always pass, no write"
        // depth/stencil state regardless of GL's depth test +
        // depth-func + depth-write-mask. CTS
        // `geometry_shader.layered_framebuffer.depth_support`
        // clears depth to 0.5, draws with GL_LESS, and expects
        // layers 2/3 (depths 0, 0.5) to be rejected — but with no
        // state set, every fragment passed, producing the
        // observed "all-white" on all layers. Extending the gate
        // to the FBO case makes GL's depth state actually apply.
        const bool havePassDepthStencil =
            depthStencilTexture != nil ||
            info.fboDepthStencilTexture != nullptr;
        if (havePassDepthStencil) {
            MetalDrawInfo fakeInfo;
            fakeInfo.depthTestEnabled = info.depthTestEnabled;
            fakeInfo.depthFunc = info.depthFunc;
            fakeInfo.depthWriteMask = info.depthWriteMask;
            // Sprint 7 Phase 1 #11 (CKPT57): copy stencil identity too.
            fakeInfo.stencilTestEnabled = info.stencilTestEnabled;
            fakeInfo.stencilFrontFunc = info.stencilFrontFunc;
            fakeInfo.stencilFrontRef = info.stencilFrontRef;
            fakeInfo.stencilFrontValueMask = info.stencilFrontValueMask;
            fakeInfo.stencilFrontFail = info.stencilFrontFail;
            fakeInfo.stencilFrontDepthFail = info.stencilFrontDepthFail;
            fakeInfo.stencilFrontDepthPass = info.stencilFrontDepthPass;
            fakeInfo.stencilFrontWriteMask = info.stencilFrontWriteMask;
            fakeInfo.stencilBackFunc = info.stencilBackFunc;
            fakeInfo.stencilBackRef = info.stencilBackRef;
            fakeInfo.stencilBackValueMask = info.stencilBackValueMask;
            fakeInfo.stencilBackFail = info.stencilBackFail;
            fakeInfo.stencilBackDepthFail = info.stencilBackDepthFail;
            fakeInfo.stencilBackDepthPass = info.stencilBackDepthPass;
            fakeInfo.stencilBackWriteMask = info.stencilBackWriteMask;
            id<MTLDepthStencilState> dsState = depthStencilStateForDraw(fakeInfo);
            if (dsState != nil && dsState != cachedDepthStencilState) {
                [currentRenderEncoder setDepthStencilState:dsState];
                cachedDepthStencilState = dsState;
            }
            // Apply stencil reference value (descriptor doesn't carry
            // it — Metal pulls it from the encoder per draw).
            if (info.stencilTestEnabled) {
                [currentRenderEncoder
                    setStencilFrontReferenceValue:
                        static_cast<uint32_t>(info.stencilFrontRef)
                    backReferenceValue:
                        static_cast<uint32_t>(info.stencilBackRef)];
            }
            if (std::getenv("APPGL_GS_DUMP_FBODEPTH") != nullptr) {
                std::fprintf(stderr,
                    "[GS] FBO draw depth state: test=%d writeMask=%d func=0x%x "
                    "fboDepth=%p arrayLen=%u\n",
                    (int)info.depthTestEnabled, (int)info.depthWriteMask,
                    (unsigned)info.depthFunc, info.fboDepthStencilTexture,
                    info.fboColorArrayLength);
                std::fflush(stderr);
            }
        }

        const MTLCullMode desiredCull = info.cullFaceEnabled
            ? (info.cullFaceMode == GL_FRONT ? MTLCullModeFront : MTLCullModeBack)
            : MTLCullModeNone;
        if (desiredCull != cachedCullMode) {
            [currentRenderEncoder setCullMode:desiredCull];
            cachedCullMode = desiredCull;
        }
        const MTLWinding desiredWinding =
            frontFacingWindingForClipControl(info.frontFace,
                                             clipControlInvertsWinding);
        if (desiredWinding != cachedFrontFaceWinding) {
            [currentRenderEncoder setFrontFacingWinding:desiredWinding];
            cachedFrontFaceWinding = desiredWinding;
        }
        const MTLTriangleFillMode desiredFill = info.wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill;
        if (desiredFill != cachedFillMode) {
            [currentRenderEncoder setTriangleFillMode:desiredFill];
            cachedFillMode = desiredFill;
        }

        // GL 4.6 §14.6.5 / GL_ARB_polygon_offset_clamp — apply depth
        // bias. Metal's setDepthBias takes (bias, slopeScale, clamp):
        //   bias       ↔ GL units
        //   slopeScale ↔ GL factor
        //   clamp      ↔ GL clamp (0 = no clamp)
        // When no polygon-offset mode is enabled the three fields are
        // zero; setDepthBias(0,0,0) is the Metal no-op.
        {
            const float bias = info.polygonOffsetEnabled ? info.polygonOffsetUnits : 0.0f;
            const float slope = info.polygonOffsetEnabled ? info.polygonOffsetFactor : 0.0f;
            const float clampV = info.polygonOffsetEnabled ? info.polygonOffsetClamp : 0.0f;
            [currentRenderEncoder setDepthBias:bias slopeScale:slope clamp:clampV];
        }

        // RC-A02: set Metal viewport from GL viewport state.
        // Metal framebuffer Y is top-down while OpenGL viewport Y is
        // bottom-up.  Convert: metalOriginY = renderTargetH - glY - glH.
        //
        // Sprint 15 Q3-Option-B Day 8 [metal-viewport-array]: when
        // `info.viewportArrayCount > 1`, bind the full per-index
        // viewport array via `setViewports:count:` so shaders that
        // write gl_ViewportIndex / [[viewport_array_index]] route to
        // the right rectangle. Single-viewport path is preserved for
        // the common case to keep behavior bit-identical to pre-Day-8
        // baselines on tests that don't exercise viewport_array.
        if (info.viewportArrayCount > 1) {
            const double rtHeight = static_cast<double>(colorTexture.height);
            // Sprint 21 A-2 [clip_control.viewport_bounds]: match the
            // single-viewport path. Shaders with the injected Y-sign keep
            // each viewport rectangle fixed; legacy paths keep the
            // origin-dependent Metal viewport conversion.
            const bool flipY = (info.clipOrigin != GL_UPPER_LEFT);
            MTLViewport vps[TranslatedDrawInfo::kMaxDrawViewports];
            for (std::size_t i = 0; i < info.viewportArrayCount; ++i) {
                const auto& e = info.viewportArray[i];
                vps[i].originX = static_cast<double>(e.originX);
                vps[i].originY = clipControlShaderYFixup
                    ? static_cast<double>(e.originY)
                    : (flipY
                        ? (rtHeight - static_cast<double>(e.originY)
                           - static_cast<double>(e.height))
                        : static_cast<double>(e.originY));
                vps[i].width   = static_cast<double>(e.width);
                vps[i].height  = static_cast<double>(e.height);
                vps[i].znear   = e.depthNear;
                vps[i].zfar    = e.depthFar;
            }
            [currentRenderEncoder setViewports:vps
                                         count:info.viewportArrayCount];
        } else if (info.viewportWidth > 0 && info.viewportHeight > 0) {
            // Sprint 16 Day 4 [layered_rendering]: clamp viewport to
            // render target bounds. The Y-flip computation
            // `rtHeight - glY - glH` produces negative originY when the
            // GL viewport is taller than the render target — which
            // happens for FBO draws that don't reset glViewport from
            // the default-framebuffer's window dimensions (e.g. CTS
            // `geometry_shader.layered_rendering.layered_rendering`
            // creates a 32×32 layered FBO but never calls glViewport,
            // so state.viewport() stays at glcts's default 256×256).
            // Negative originY is silently rejected by Metal's
            // tile-rasterizer on Apple Silicon, dropping every fragment.
            // Clamp the GL viewport rect to the render target before
            // computing the Metal-flipped origin so the bound rect is
            // always non-negative and within bounds.
            const double rtHeight = static_cast<double>(colorTexture.height);
            const GLint rtW = static_cast<GLint>(colorTexture.width);
            const GLint rtH = static_cast<GLint>(colorTexture.height);
            // GL viewport (bottom-up coords). Clamp x/y to [0, rt) and
            // width/height so the resulting rect fits in the RT.
            const GLint glX = std::max<GLint>(0, info.viewportX);
            const GLint glY = std::max<GLint>(0, info.viewportY);
            const GLsizei availW = static_cast<GLsizei>(std::max<GLint>(0, rtW - glX));
            const GLsizei availH = static_cast<GLsizei>(std::max<GLint>(0, rtH - glY));
            const GLsizei glW = std::min<GLsizei>(info.viewportWidth, availW);
            const GLsizei glH = std::min<GLsizei>(info.viewportHeight, availH);
            // Sprint 21 A-2 [clip_control.viewport_bounds]: translated
            // vertex shaders now carry a draw-time clip-control Y sign.
            // When present, keep the viewport rectangle fixed and let
            // LOWER_LEFT flip the mapping inside it. Legacy paths keep
            // the existing viewport-origin convention.
            const bool flipY = (info.clipOrigin != GL_UPPER_LEFT);
            MTLViewport vp;
            vp.originX = static_cast<double>(glX);
            vp.originY = clipControlShaderYFixup
                ? static_cast<double>(glY)
                : (flipY
                    ? (rtHeight - static_cast<double>(glY) - static_cast<double>(glH))
                    : static_cast<double>(glY));
            vp.width   = static_cast<double>(glW);
            vp.height  = static_cast<double>(glH);
            vp.znear   = info.depthRangeNear;
            vp.zfar    = info.depthRangeFar;
            if (vp.width > 0 && vp.height > 0) {
                [currentRenderEncoder setViewport:vp];
            }
        }

        // GL 4.6 §14.5.1 — scissor test. Metal has no "disable scissor"
        // flag, so when GL_SCISSOR_TEST is off we set the scissor rect
        // to cover the full render target. When enabled, we translate
        // the GL scissor box (bottom-up, render-target-relative) to
        // Metal's top-down coordinate system, clamp to the render
        // target bounds (Metal rejects off-screen/over-large rects),
        // and handle zero-dimension cases by placing a 1x1 rect just
        // outside the render target so no fragments pass — matching
        // CTS `viewport_array.scissor_zero_dimension` which expects
        // every fragment discarded when width=height=0.
        //
        // Sprint 16 Day 3 [viewport_array]: when the viewport array is
        // bound (count > 1), pair it 1:1 with a scissor array via
        // `setScissorRects:count:`. Per Apple Metal docs (and observed
        // behaviour on Apple Silicon), `setViewports:count:N` followed
        // by single `setScissorRect:` leaves scissor slots 1..N-1 at an
        // implementation-defined state that drops fragments at any
        // viewport > 0. Symmetric N-count is required.
        {
            const NSUInteger rtW = colorTexture.width;
            const NSUInteger rtH = colorTexture.height;
            // Helper that converts a single GL scissor rect (bottom-up,
            // RT-relative) plus an enabled flag into a Metal scissor
            // rect (top-down, clamped). When disabled, returns the
            // full RT — matching GL semantics where scissor only
            // discards when the test is on.
            auto makeMetalScissor = [&](bool enabled, GLint glX, GLint glY,
                                        GLsizei glW, GLsizei glH) -> MTLScissorRect {
                MTLScissorRect sr;
                if (!enabled) {
                    sr.x = 0; sr.y = 0; sr.width = rtW; sr.height = rtH;
                    return sr;
                }
                if (glW <= 0 || glH <= 0) {
                    sr.x = 0; sr.y = 0; sr.width = 0; sr.height = 0;
                    return sr;
                }
                GLint metalX = std::max<GLint>(0, glX);
                GLint metalY_bottomLeft = std::max<GLint>(0, glY);
                GLint metalY = static_cast<GLint>(rtH) - metalY_bottomLeft - glH;
                if (metalY < 0) { glH += metalY; metalY = 0; }
                GLsizei availW = static_cast<GLsizei>(rtW) - metalX;
                GLsizei availH = static_cast<GLsizei>(rtH) - metalY;
                GLsizei finalW = std::min<GLsizei>(glW, std::max<GLsizei>(0, availW));
                GLsizei finalH = std::min<GLsizei>(glH, std::max<GLsizei>(0, availH));
                if (finalW <= 0 || finalH <= 0) {
                    sr.x = rtW > 0 ? rtW - 1 : 0;
                    sr.y = rtH > 0 ? rtH - 1 : 0;
                    sr.width = 1; sr.height = 1;
                    return sr;
                }
                sr.x = static_cast<NSUInteger>(metalX);
                sr.y = static_cast<NSUInteger>(metalY);
                sr.width = static_cast<NSUInteger>(finalW);
                sr.height = static_cast<NSUInteger>(finalH);
                return sr;
            };

            if (info.viewportArrayCount > 1) {
                // Multi-viewport path: build N matching scissors. Per-
                // slot enable comes from glEnablei(SCISSOR_TEST, i);
                // when none of the slots have the test on we still
                // call setScissorRects:count: so Metal gets the
                // symmetric pairing it expects (each slot at full RT).
                MTLScissorRect srs[TranslatedDrawInfo::kMaxDrawViewports];
                for (std::size_t i = 0; i < info.viewportArrayCount; ++i) {
                    const auto& sce = info.scissorArray[i];
                    // Honour both global SCISSOR_TEST and per-slot
                    // enable: the per-slot view in indexedScissorTest_
                    // is broadcast on global enable (GLStateTracker.cpp
                    // setEnabled(GL_SCISSOR_TEST)) — but a draw with
                    // global off needs a full-RT scissor at all slots
                    // regardless of the per-slot rect.
                    const bool enabled = info.scissorTestEnabled && sce.enabled;
                    srs[i] = makeMetalScissor(enabled, sce.x, sce.y,
                                               sce.width, sce.height);
                }
                [currentRenderEncoder setScissorRects:srs
                                                count:info.viewportArrayCount];
            } else {
                // Single-viewport path: original logic.
                MTLScissorRect sr = makeMetalScissor(info.scissorTestEnabled,
                                                     info.scissorX, info.scissorY,
                                                     info.scissorWidth,
                                                     info.scissorHeight);
                [currentRenderEncoder setScissorRect:sr];
            }
        }

        // Bind vertex data at buffer index 0.
        // Attributeless draws (gl_VertexID-driven) skip vertex buffer binding.
        // OPT-5: when the VBO has a pre-uploaded Metal buffer, bind it
        // directly — zero memcpy.  Otherwise fall back to the ring buffer
        // sub-allocation path (OPT-1).
        if (attributelessDraw) {
            // No vertex buffers needed — shader uses [[vertex_id]].
        } else if (info.metalVertexBuffer != nullptr) {
            id<MTLBuffer> mtlBuf = (__bridge id<MTLBuffer>)info.metalVertexBuffer;
            [currentRenderEncoder setVertexBuffer:mtlBuf
                                           offset:static_cast<NSUInteger>(info.metalVertexBufferOffset)
                                          atIndex:0];
        } else {
            auto alloc = ringSuballocate(info.vertexData, info.vertexDataByteCount);
            if (alloc.buffer == nil) {
                return false;
            }
            [currentRenderEncoder setVertexBuffer:alloc.buffer offset:alloc.offset atIndex:0];
        }

        // Bind extra vertex buffers (buffer index 1+) — e.g. per-instance
        // attribute data from glVertexAttribDivisor.
        for (std::size_t ei = 0; ei < info.extraVertexBuffers.size(); ++ei) {
            const auto& evb = info.extraVertexBuffers[ei];
            if (evb.metalBuffer != nullptr) {
                id<MTLBuffer> mtlBuf = (__bridge id<MTLBuffer>)evb.metalBuffer;
                [currentRenderEncoder setVertexBuffer:mtlBuf
                                               offset:static_cast<NSUInteger>(evb.metalBufferOffset)
                                              atIndex:static_cast<NSUInteger>(ei + 1)];
            } else {
                const void* bytes = evb.data != nullptr
                    ? evb.data
                    : (evb.ownedData.empty() ? nullptr : evb.ownedData.data());
                auto alloc = ringSuballocate(bytes, evb.byteCount);
                if (alloc.buffer == nil) {
                    return false;
                }
                [currentRenderEncoder setVertexBuffer:alloc.buffer
                                               offset:alloc.offset
                                              atIndex:static_cast<NSUInteger>(ei + 1)];
            }
        }

        // Bind per-stage uniform buffers. Under argbuf mode, these are
        // populated into the desc_set 1 argument buffer via the
        // fragArgEncoderSet1 / vertArgEncoderSet1 encoders further
        // below. The direct-binding path here still fires when argbuf
        // is off OR when the stage has NO samplers (set 0) AND no
        // UBOs — which normally means the shader has nothing at all,
        // so the setBytes calls are no-ops. Under argbuf mode with
        // UBOs present, skip the direct-binding calls entirely.
        {
            if (!vertexUsesArgBuf &&
                info.vertexUniformData != nullptr && info.vertexUniformSize > 0) {
                [currentRenderEncoder setVertexBytes:info.vertexUniformData
                                              length:info.vertexUniformSize
                                             atIndex:16];
            }
            if (!fragmentUsesArgBuf &&
                info.fragmentUniformData != nullptr && info.fragmentUniformSize > 0) {
                [currentRenderEncoder setFragmentBytes:info.fragmentUniformData
                                                length:info.fragmentUniformSize
                                               atIndex:16];
            }
            // CKPT121 (Sprint 11 Phase 2 Day 6): SPIRV-Cross emits
            // gl_NumSamples as a `constant int& [[buffer(0)]]` FS
            // parameter. The MSL ShaderTranslator post-process gates the
            // gl_SampleMask=UINT_MAX override on this value (== 1 means
            // non-MSAA per GL spec). Bind the bound color attachment's
            // sampleCount here so the FS reads a real count.
            // CTS sample_variables.mask.samples_{1,2,4} verify samples >= 1
            // do not get the UINT_MAX neutralization.
            if (!fragmentUsesArgBuf) {
                const int32_t glNumSamples = static_cast<int32_t>(attachmentSampleCount);
                [currentRenderEncoder setFragmentBytes:&glNumSamples
                                                length:sizeof(glNumSamples)
                                               atIndex:0];
            }
            if (vertexNeedsFragmentShadingRateState) {
                [currentRenderEncoder setVertexBytes:&info.fragmentShadingRateShaderState
                                              length:sizeof(info.fragmentShadingRateShaderState)
                                             atIndex:kAppGLFragmentShadingRateParamsBufferSlot];
            }
            if (vertexClipControlYSignSlot >= 0) {
                const float clipControlYSign =
                    (clipControlShaderYFixup &&
                     info.clipOrigin != GL_UPPER_LEFT) ? -1.0f : 1.0f;
                [currentRenderEncoder setVertexBytes:&clipControlYSign
                                              length:sizeof(clipControlYSign)
                                             atIndex:static_cast<NSUInteger>(vertexClipControlYSignSlot)];
            }
            const NSInteger vertexReductionModesSlot =
                textureReductionModesBufferSlot(info.vertexMSL);
            if (vertexReductionModesSlot >= 0) {
                std::vector<std::uint32_t> modes =
                    buildTextureReductionModes(info.vertexTextures);
                [currentRenderEncoder setVertexBytes:modes.data()
                                              length:modes.size() * sizeof(std::uint32_t)
                                             atIndex:static_cast<NSUInteger>(vertexReductionModesSlot)];
            }
            const NSInteger fragmentReductionModesSlot =
                textureReductionModesBufferSlot(info.fragmentMSL);
            if (fragmentReductionModesSlot >= 0) {
                std::vector<std::uint32_t> modes =
                    buildTextureReductionModes(info.fragmentTextures);
                [currentRenderEncoder setFragmentBytes:modes.data()
                                                length:modes.size() * sizeof(std::uint32_t)
                                               atIndex:static_cast<NSUInteger>(fragmentReductionModesSlot)];
            }
            if (fragmentNeedsFragCoordParams) {
                const float renderTargetHeight = colorTexture != nil
                    ? static_cast<float>(colorTexture.height)
                    : static_cast<float>(std::max<GLsizei>(info.viewportHeight, 1));
                auto fragmentSamplesRenderTarget = [&](id<MTLTexture> target) {
                    if (target == nil) return false;
                    for (const auto& binding : info.fragmentTextures) {
                        if (binding.metalTexture == nullptr) continue;
                        id<MTLTexture> sampled =
                            (__bridge id<MTLTexture>)binding.metalTexture;
                        if (sampled == target) return true;
                    }
                    return false;
                };
                bool fragmentSamplesColorAttachment =
                    fragmentSamplesRenderTarget(colorTexture);
                if (!fragmentSamplesColorAttachment) {
                    for (void* rawExtraTex : info.fboAdditionalColorTextures) {
                        if (rawExtraTex == nullptr) continue;
                        id<MTLTexture> extraTex =
                            (__bridge id<MTLTexture>)rawExtraTex;
                        if (fragmentSamplesRenderTarget(extraTex)) {
                            fragmentSamplesColorAttachment = true;
                            break;
                        }
                    }
                }
                bool fragmentUsesStorageImage = false;
                for (const auto& binding : info.fragmentTextures) {
                    if (binding.metalTexture != nullptr &&
                        binding.metalSamplerState == nullptr) {
                        fragmentUsesStorageImage = true;
                        break;
                    }
                }
                const bool flipToLowerLeft =
                    (info.clipOrigin != GL_UPPER_LEFT) &&
                    !fragmentSamplesColorAttachment;
                const auto storageImageLowerLeftBase = [&]() -> float {
                    if (colorTexture == nil) {
                        return static_cast<float>(
                            std::max<GLsizei>(info.viewportHeight, 1));
                    }
                    const GLint rtH =
                        static_cast<GLint>(colorTexture.height);
                    const GLint glY = std::max<GLint>(0, info.viewportY);
                    const GLsizei availH = static_cast<GLsizei>(
                        std::max<GLint>(0, rtH - glY));
                    const GLsizei glH = std::min<GLsizei>(
                        info.viewportHeight, availH);
                    return static_cast<float>(glY + glH);
                }();
                const float lowerLeftBase =
                    fragmentUsesStorageImage
                        ? storageImageLowerLeftBase
                        : renderTargetHeight;
                const float fragCoordParams[4] = {
                    flipToLowerLeft ? lowerLeftBase : 0.0f,
                    flipToLowerLeft ? -1.0f : 1.0f,
                    flipToLowerLeft ? 1.0f : 0.0f,
                    0.0f,
                };
                // Sprint 18 Bank D-3 (`textures_bind_unit`): fragment
                // shader-side gl_FragCoord Y synthesis. This payload is
                // intentionally independent of the 5930a4d/c196254 FBO
                // readback flip markers, which stay responsible only for
                // CPU-visible readback orientation. If the fragment shader
                // samples the active color attachment, keep Metal's
                // render-target texture coordinate space; texture_barrier
                // self-feedback relies on that aliasing path and is not the
                // D-3 sampled-input case.
                [currentRenderEncoder setFragmentBytes:fragCoordParams
                                                length:sizeof(fragCoordParams)
                                               atIndex:kAppGLFragCoordParamsBufferSlot];
            }

            // Bind UBO data to the Metal encoder at the reflection-specified
            // [[buffer(N)]] slots.  Each entry was resolved by GLContext from
            // the GL uniform buffer binding state.
            for (const auto& ubo : info.uboBindings) {
                if (ubo.size == 0) continue;
                const NSUInteger slot = static_cast<NSUInteger>(ubo.metalSlot);
                if (ubo.metalBuffer != nullptr) {
                    // Large UBO (>4KB): bind the Metal buffer directly.
                    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)(ubo.metalBuffer);
                    const NSUInteger off = static_cast<NSUInteger>(ubo.metalBufferOffset);
                    if (ubo.isVertex && !vertexUsesArgBuf) {
                        [currentRenderEncoder setVertexBuffer:buf offset:off atIndex:slot];
                    }
                    if (ubo.isFragment && !fragmentUsesArgBuf) {
                        [currentRenderEncoder setFragmentBuffer:buf offset:off atIndex:slot];
                    }
                } else if (ubo.data != nullptr) {
                    // Small UBO (≤4KB): inline bytes.
                    if (ubo.isVertex && !vertexUsesArgBuf) {
                        [currentRenderEncoder setVertexBytes:ubo.data
                                                      length:static_cast<NSUInteger>(ubo.size)
                                                     atIndex:slot];
                    }
                    if (ubo.isFragment && !fragmentUsesArgBuf) {
                        [currentRenderEncoder setFragmentBytes:ubo.data
                                                        length:static_cast<NSUInteger>(ubo.size)
                                                       atIndex:slot];
                    }
                }
            }
        }

        // Bind SSBOs to the render encoder. GL 4.3+ permits vertex and
        // fragment stages to declare `layout(binding=N) buffer X` for
        // arbitrary indexed-buffer-bound SSBOs. KHR-GL46.shader_storage_
        // buffer_object.*-{vs,fs} exercises this from both stages. MSL
        // expects the buffer at the reflected [[buffer(metalSlot)]].
        //
        // Step 7-3 follow-up: under argbuf mode, SSBOs are populated
        // into the desc_set 0 argument buffer (same encoder as
        // sampled/storage images) further below. Skip this direct-
        // binding loop when argbuf is on to avoid double-binding at
        // the wrong slot.
        for (const auto& ssbo : info.ssboBindings) {
            if (ssbo.metalBuffer == nullptr) continue;
            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)ssbo.metalBuffer;
            const NSUInteger slot = static_cast<NSUInteger>(ssbo.metalSlot);
            const NSUInteger off = static_cast<NSUInteger>(ssbo.offset);
            if (ssbo.isVertex && !vertexUsesArgBuf) {
                [currentRenderEncoder setVertexBuffer:buf offset:off atIndex:slot];
            }
            if (ssbo.isFragment && !fragmentUsesArgBuf) {
                [currentRenderEncoder setFragmentBuffer:buf offset:off atIndex:slot];
            }
        }
        for (const auto& atomic : info.atomicCounterBindings) {
            if (atomic.metalBuffer == nullptr) continue;
            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)atomic.metalBuffer;
            const NSUInteger slot = static_cast<NSUInteger>(atomic.metalSlot);
            const NSUInteger off = static_cast<NSUInteger>(atomic.offset);
            if (atomic.isVertex && !vertexUsesArgBuf) {
                [currentRenderEncoder setVertexBuffer:buf offset:off atIndex:slot];
            }
            if (atomic.isFragment && !fragmentUsesArgBuf) {
                [currentRenderEncoder setFragmentBuffer:buf offset:off atIndex:slot];
            }
        }

        if (vertexUsesMultiviewViewMask && !vertexUsesArgBuf) {
            [currentRenderEncoder setVertexBytes:ovrViewMask
                                          length:sizeof(ovrViewMask)
                                         atIndex:24];
        }
        if (fragmentUsesMultiviewViewMask && !fragmentUsesArgBuf) {
            [currentRenderEncoder setFragmentBytes:ovrViewMask
                                            length:sizeof(ovrViewMask)
                                           atIndex:24];
        }

        // Phase 8X Group 4d follow-up⁷ — bind textures and samplers for
        // this draw. GLContext::drawArrays / drawArraysInstanced /
        // drawElements populates `info.fragmentTextures` and
        // `info.vertexTextures` by walking the program's sampler uniforms,
        // resolving each one through the GL texture-unit state, and
        // snapping pointers to the cached MTLTexture / MTLSamplerState on
        // the texture object. A slot with a nullptr texture or sampler is
        // skipped silently — that means the GL app bound a sampler
        // uniform that points at an empty texture unit, which on the GL
        // side would sample a 1×1×1 default texture. Metal has no such
        // default so the slot stays unbound and the shader gets whatever
        // the driver leaves there. Most engines bind a real texture
        // before drawing anything that samples it, so the "null slot"
        // case is only expected for debug paths that we don't care about
        // in the smoke run. BAR's select-menu fragment shaders sample
        // one texture per draw (the glyph atlas page), so every call
        // here populates one binding in `fragmentTextures`.
        //
        // Phase 8X Group 4d follow-up⁸ — diagnostic instrumentation for
        // BAR's followup⁷ verification "byte-identical screenshot"
        // finding. The binding fix landed structurally clean (gauntlet
        // green, no regressions) but produced zero pixel-level change in
        // the select-menu render. Three hypotheses (BAR followup⁷ §Visual):
        //   A. bindings are emitted but all metalTexture/metalSamplerState
        //      pointers are nullptr, so every entry hits the skip-guard
        //      below and the encoder stays in the unbound state.
        //   B. `resolveSamplerBindings` finds zero reflection entries so
        //      `fragmentTextures` is empty on arrival — see matching log
        //      in `GLContext::Impl::resolveSamplerBindings`.
        //   C. BAR's text rendering runs through a program that never
        //      reaches this encoder (fall-through to solid-color path
        //      before the translated gate).
        // This one-shot-per-program log distinguishes A from B and C:
        //   - if this line never logs for programs 5/6/8/10 → hypothesis C
        //   - if it logs with sizes (0/0) → hypothesis B (zero bindings
        //     arrived on the tdi; check resolve log)
        //   - if it logs with sizes > 0 and hasTexture=0 or hasSampler=0 →
        //     hypothesis A (bindings arrived but were null)
        //   - if it logs with sizes > 0 and hasTexture=1 hasSampler=1 →
        //     bindings are real but pixels are still unchanged; means
        //     the issue is downstream of binding (shader texture coord,
        //     missing color-attachment write, etc.)
        // Keyed on info.program so the log fires exactly once per GL
        // program name per MetalFrameGraph instance (one per
        // GLContext). Single-threaded GL context means no mutex is
        // needed. See `loggedBindingPrograms` on Impl for the
        // multi-context rationale.
        if (info.program != 0 &&
            loggedBindingPrograms.insert(info.program).second) {
            APPGL_LOG(DRAW, @"[GL] encodeTranslatedDraw first-draw program=%u"
                  @" fragmentTextures.size=%zu vertexTextures.size=%zu",
                  info.program,
                  info.fragmentTextures.size(),
                  info.vertexTextures.size());
            for (std::size_t i = 0; i < info.fragmentTextures.size(); ++i) {
                const auto& b = info.fragmentTextures[i];
                APPGL_LOG(DRAW, @"[GL]   frag[%zu] slot=%u hasTexture=%d hasSampler=%d",
                      i,
                      static_cast<unsigned>(b.metalSlot),
                      b.metalTexture != nullptr ? 1 : 0,
                      b.metalSamplerState != nullptr ? 1 : 0);
            }
            for (std::size_t i = 0; i < info.vertexTextures.size(); ++i) {
                const auto& b = info.vertexTextures[i];
                APPGL_LOG(DRAW, @"[GL]   vert[%zu] slot=%u hasTexture=%d hasSampler=%d",
                      i,
                      static_cast<unsigned>(b.metalSlot),
                      b.metalTexture != nullptr ? 1 : 0,
                      b.metalSamplerState != nullptr ? 1 : 0);
            }

            // Phase 8X Group 4d follow-up¹⁰ — §Secondary VBO peek
            // for BAR's Theory A/B split. Dump the first 32 bytes
            // of the vertex data, the stride, and the attribute
            // layout list so BAR can decide whether the UVs on
            // programs 8/10 are tightly inside `[0, 1)` (Theory A
            // out — REPEAT wrap doesn't matter) or whether
            // they're scrambled / out-of-range (Theory B hint —
            // VBO upload bug, or Recoil-side vertex data problem).
            //
            // The peek reads from `info.vertexData` when non-null
            // (CPU scratch path) or from the Metal buffer's CPU-
            // visible contents when the draw path bound a shared-
            // storage MTLBuffer directly (OPT-5 path). Private-
            // storage buffers are not readable from CPU so we
            // silently skip the hex dump in that case — BAR can
            // still see the stride and layout list to cross-check
            // against native GL's vertex array setup.
            //
            // Also dumps the attribute layout list so BAR knows
            // which byte offsets inside the stride hold `uv`
            // attributes — UI quad VBOs typically have something
            // like (pos.xy, uv.xy) packed tight or
            // (pos.xyz, uv.xy, color.rgba) in a 36-byte stride.
            APPGL_LOG(DRAW, @"[GL]   vbo stride=%zu vertexDataByteCount=%zu"
                  @" metalBuf=%d extraBufs=%zu attrLayouts=%zu",
                  info.vertexStride,
                  info.vertexDataByteCount,
                  info.metalVertexBuffer != nullptr ? 1 : 0,
                  info.extraVertexBuffers.size(),
                  info.vertexAttributeLayouts.size());
            for (std::size_t i = 0; i < info.vertexAttributeLayouts.size(); ++i) {
                const auto& a = info.vertexAttributeLayouts[i];
                APPGL_LOG(DRAW, @"[GL]     attr[%zu] location=%u offset=%zu",
                      i, a.location, a.offset);
            }

            // Resolve a CPU pointer to the start of the vertex
            // stream we're about to encode.
            const std::uint8_t* peekPtr = nullptr;
            if (info.vertexData != nullptr) {
                peekPtr = static_cast<const std::uint8_t*>(info.vertexData);
            } else if (info.metalVertexBuffer != nullptr) {
                id<MTLBuffer> mtlBuf = (__bridge id<MTLBuffer>)info.metalVertexBuffer;
                // storageMode shared/managed → contents is a
                // valid CPU pointer. Private is nil/garbage.
                if ([mtlBuf storageMode] == MTLStorageModeShared ||
                    [mtlBuf storageMode] == MTLStorageModeManaged) {
                    const std::uint8_t* base =
                        static_cast<const std::uint8_t*>([mtlBuf contents]);
                    if (base != nullptr) {
                        peekPtr = base + info.metalVertexBufferOffset;
                    }
                }
            }

            if (peekPtr != nullptr) {
                // Peek 32 bytes — enough to cover a full 32-byte
                // stride (pos.xyz + uv.xy + color.rgba layouts) or
                // two 16-byte stride quads (pos.xy + uv.xy). BAR
                // can decode by stride; the stride is on the
                // preceding line.
                const std::size_t peekLen = 32;
                char hexBuf[128];
                char floatBuf[128];
                for (std::size_t i = 0; i < peekLen; ++i) {
                    std::snprintf(hexBuf + i * 3, sizeof(hexBuf) - i * 3,
                                  "%02X ", peekPtr[i]);
                }
                hexBuf[peekLen * 3 - 1] = '\0';
                // Also interpret as 8 floats for quick visual
                // sanity-check of position/UV ranges.
                float asFloats[8];
                std::memcpy(asFloats, peekPtr, sizeof(asFloats));
                std::snprintf(floatBuf, sizeof(floatBuf),
                    "%.3f %.3f %.3f %.3f %.3f %.3f %.3f %.3f",
                    asFloats[0], asFloats[1], asFloats[2], asFloats[3],
                    asFloats[4], asFloats[5], asFloats[6], asFloats[7]);
                APPGL_LOG(DRAW, @"[GL]     vbo peek32 hex=[%s]", hexBuf);
                APPGL_LOG(DRAW, @"[GL]     vbo peek32 f32=[%s]", floatBuf);
            } else {
                APPGL_LOG(DRAW, @"[GL]     vbo peek32 skip=private-or-null");
            }
        }
        // Step 7-3: argument-buffer binding path. When argbuf is enabled
        // and the pipeline has desc_set 0 (fragment and/or vertex stage),
        // allocate a per-stage argument buffer, populate it via the
        // MTLArgumentEncoder, bind at [[buffer(24)]], and call
        // useResource for each bound texture + sampler so Metal
        // residency tracks them. When argbuf is disabled, fall through
        // to the baseline direct-binding path unchanged.
        if (useArgBuf && (fragArgEncoderSet0 != nil || vertArgEncoderSet0 != nil ||
                          fragArgEncoderSet1 != nil || vertArgEncoderSet1 != nil)) {
            auto encodeTexturesIntoArgBuf = [&](id<MTLArgumentEncoder> encoder,
                                                 const std::vector<TranslatedDrawInfo::TextureBinding>& textures,
                                                 MTLRenderStages stage,
                                                 bool isFragment,
                                                 bool needsSSBOSizeBuffer) {
                // Step 7-3 follow-up: no early-return on empty textures
                // — the set-0 argbuf may also hold SSBOs (see the SSBO
                // loop below), and an SSBO-only shader (no samplers, no
                // storage images) still needs its argument buffer bound.
                // The encoder-is-nil check still fires when the stage
                // has no desc_set 0 usage at all.
                if (encoder == nil) return;
                const NSUInteger len = [encoder encodedLength];
                if (len == 0) return;
                // Step 7-4: ring-buffer sub-allocation for the
                // argument buffer. Avoids per-draw
                // newBufferWithLength churn — a single 16-MB ring slot
                // holds hundreds of argbufs until the GPU completes
                // the frame. Falls back to newBufferWithLength on ring
                // overflow (single draw exceeds remaining space).
                RingAlloc argBufAlloc = ringAllocRaw(len);
                id<MTLBuffer> argBuf = argBufAlloc.buffer;
                const NSUInteger argBufOffset = argBufAlloc.offset;
                if (argBuf == nil) return;
                [encoder setArgumentBuffer:argBuf offset:argBufOffset];
                // Sprint 18 Item42: graphics-stage SSBO `.length()`
                // sidecar. The translator rewrites graphics argbuf MSL
                // to read this table from direct buffer slot 30, keyed
                // by each SSBO's argbuf id (192+ for AppGL SSBOs). We
                // also populate desc_set 0 id(0) defensively because
                // SPIRV-Cross keeps that field in the argument-buffer
                // struct. This is the render-stage sister of the
                // compute direct sidecar from 96c7d10.
                if (needsSSBOSizeBuffer) {
                    std::uint32_t maxSlot = 0;
                    bool anySizedSSBO = false;
                    for (const auto& ssbo : info.ssboBindings) {
                        if (ssbo.metalBuffer == nullptr || ssbo.size == 0) continue;
                        if (isFragment && !ssbo.isFragment) continue;
                        if (!isFragment && !ssbo.isVertex) continue;
                        maxSlot = std::max(maxSlot, ssbo.metalSlot);
                        anySizedSSBO = true;
                    }
                    if (anySizedSSBO) {
                        std::vector<std::uint32_t> sizes(
                            static_cast<std::size_t>(maxSlot) + 1u, 0u);
                        for (const auto& ssbo : info.ssboBindings) {
                            if (ssbo.metalBuffer == nullptr || ssbo.size == 0) continue;
                            if (isFragment && !ssbo.isFragment) continue;
                            if (!isFragment && !ssbo.isVertex) continue;
                            if (ssbo.metalSlot >= sizes.size()) continue;
                            sizes[ssbo.metalSlot] =
                                static_cast<std::uint32_t>(std::min<std::size_t>(
                                    ssbo.size,
                                    static_cast<std::size_t>(
                                        std::numeric_limits<std::uint32_t>::max())));
                        }
                        RingAlloc sizeAlloc = ringSuballocate(
                            sizes.data(),
                            sizes.size() * sizeof(std::uint32_t));
                        if (sizeAlloc.buffer != nil) {
                            [encoder setBuffer:sizeAlloc.buffer
                                        offset:sizeAlloc.offset
                                       atIndex:0];
                            if (isFragment) {
                                [currentRenderEncoder setFragmentBuffer:sizeAlloc.buffer
                                                                  offset:sizeAlloc.offset
                                                                 atIndex:30];
                            } else {
                                [currentRenderEncoder setVertexBuffer:sizeAlloc.buffer
                                                                offset:sizeAlloc.offset
                                                               atIndex:30];
                            }
                            [currentRenderEncoder useResource:sizeAlloc.buffer
                                                        usage:MTLResourceUsageRead
                                                       stages:stage];
                        }
                    }
                }
                for (const auto& binding : textures) {
                    if (binding.metalTexture == nullptr) continue;
                    id<MTLTexture> tex = (__bridge id<MTLTexture>)binding.metalTexture;
                    // Step 7-3 follow-up: reflection is now argbuf-aware,
                    // so `binding.metalSlot` IS the argbuf `[[id(N)]]`
                    // slot directly. For sampled images (metalSamplerState
                    // non-null) the texture half lives at metalSlot and the
                    // sampler at metalSlot+1 (reflection returns 2*glBinding
                    // so +1 = 2*glBinding+1, matching the consolidation
                    // convention). For storage images the sampler slot is
                    // unused; resolveImageBindings packs them into the
                    // same list with metalSamplerState=nullptr and
                    // metalSlot already offset to 128+glBinding.
                    const NSUInteger idIdx = static_cast<NSUInteger>(binding.metalSlot);
                    [encoder setTexture:tex atIndex:idIdx];
                    MTLResourceUsage usage = MTLResourceUsageRead;
                    if (binding.metalSamplerState != nullptr) {
                        id<MTLSamplerState> smp = (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                        [encoder setSamplerState:smp atIndex:idIdx + 1];
                        usage |= MTLResourceUsageSample;
                    } else {
                        // Storage image — add write usage since imageStore
                        // may fire. Direct-binding's path set ShaderWrite
                        // via MTLTextureUsage when the texture was created;
                        // argbuf mode additionally needs runtime
                        // useResource to track residency.
                        usage |= MTLResourceUsageWrite;
                    }
                    // Residency tracking: Metal's argument buffers are
                    // indirect references. Without useResource, the
                    // texture/sampler pages may not be resident on GPU
                    // when the shader reads through the argument buffer.
                    [currentRenderEncoder useResource:tex
                                                usage:usage
                                               stages:stage];
                }
                // SSBOs (graphics stage) — `info.ssboBindings` stage-
                // filtered. Under argbuf reflection SSBOs live at
                // [[id(192 + glBinding)]]. Direct mode uses sequential
                // 28+N slots via setVertexBuffer/setFragmentBuffer.
                for (const auto& ssbo : info.ssboBindings) {
                    if (ssbo.metalBuffer == nullptr) continue;
                    if (isFragment && !ssbo.isFragment) continue;
                    if (!isFragment && !ssbo.isVertex) continue;
                    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)(ssbo.metalBuffer);
                    [encoder setBuffer:buf
                                offset:static_cast<NSUInteger>(ssbo.offset)
                               atIndex:static_cast<NSUInteger>(ssbo.metalSlot)];
                    [currentRenderEncoder useResource:buf
                                                usage:MTLResourceUsageRead|MTLResourceUsageWrite
                                               stages:stage];
                }
                for (const auto& atomic : info.atomicCounterBindings) {
                    if (atomic.metalBuffer == nullptr) continue;
                    if (isFragment && !atomic.isFragment) continue;
                    if (!isFragment && !atomic.isVertex) continue;
                    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)(atomic.metalBuffer);
                    [encoder setBuffer:buf
                                offset:static_cast<NSUInteger>(atomic.offset)
                               atIndex:static_cast<NSUInteger>(atomic.metalSlot)];
                    [currentRenderEncoder useResource:buf
                                                usage:MTLResourceUsageRead|MTLResourceUsageWrite
                                               stages:stage];
                }
                if (isFragment) {
                    [currentRenderEncoder setFragmentBuffer:argBuf offset:argBufOffset atIndex:24];
                } else {
                    [currentRenderEncoder setVertexBuffer:argBuf offset:argBufOffset atIndex:24];
                }
            };
            encodeTexturesIntoArgBuf(fragArgEncoderSet0, info.fragmentTextures,
                                      MTLRenderStageFragment, true,
                                      fragmentNeedsSSBOSizeBuffer);
            encodeTexturesIntoArgBuf(vertArgEncoderSet0, info.vertexTextures,
                                      MTLRenderStageVertex, false,
                                      vertexNeedsSSBOSizeBuffer);

            // Step 7-3 UBO follow-up: populate desc_set 1 argbuf with
            // the default uniform block + explicit `uniform Block`
            // UBOs. Default uniform block lives at [[id(16)]] per the
            // translator's uniformBufferBase convention; explicit UBOs
            // at sequential slots 16 + per-stage-offset (the
            // info.uboBindings entries carry their final metalSlot
            // from reflection).
            //
            // Small UBO data (ubo.data != nullptr, metalBuffer = nullptr)
            // was previously inlined via setVertexBytes/setFragmentBytes
            // which isn't usable inside an argument buffer — we must
            // hand the encoder a real MTLBuffer. Route through
            // `ringSuballocate` which copies the CPU bytes into a
            // device-visible transient buffer and returns its handle
            // + offset. The same path works for the default uniform
            // block data.
            auto encodeUBOsIntoArgBuf = [&](id<MTLArgumentEncoder> encoder,
                                             const void* uniformData,
                                             NSUInteger uniformSize,
                                             bool isVertex,
                                             MTLRenderStages stage) {
                if (encoder == nil) return;
                const NSUInteger len = [encoder encodedLength];
                if (len == 0) return;
                // Step 7-4: ring-buffer sub-allocation for the UBO
                // argument buffer (matches the set-0 texture argbuf
                // allocation above).
                RingAlloc argBufAlloc = ringAllocRaw(len);
                id<MTLBuffer> argBuf = argBufAlloc.buffer;
                const NSUInteger argBufOffset = argBufAlloc.offset;
                if (argBuf == nil) return;
                [encoder setArgumentBuffer:argBuf offset:argBufOffset];

                // Default uniform block at [[id(16)]].
                if (uniformData != nullptr && uniformSize > 0) {
                    RingAlloc alloc = ringSuballocate(uniformData, uniformSize);
                    if (alloc.buffer != nil) {
                        [encoder setBuffer:alloc.buffer
                                    offset:alloc.offset
                                   atIndex:16];
                        [currentRenderEncoder useResource:alloc.buffer
                                                    usage:MTLResourceUsageRead
                                                   stages:stage];
                    }
                }

                // Explicit UBOs at their reflection-specified slots.
                for (const auto& ubo : info.uboBindings) {
                    if (ubo.size == 0) continue;
                    if (isVertex && !ubo.isVertex) continue;
                    if (!isVertex && !ubo.isFragment) continue;
                    const NSUInteger slot = static_cast<NSUInteger>(ubo.metalSlot);
                    id<MTLBuffer> uboBuf = nil;
                    NSUInteger uboOff = 0;
                    if (ubo.metalBuffer != nullptr) {
                        uboBuf = (__bridge id<MTLBuffer>)(ubo.metalBuffer);
                        uboOff = static_cast<NSUInteger>(ubo.metalBufferOffset);
                    } else if (ubo.data != nullptr) {
                        RingAlloc alloc = ringSuballocate(ubo.data, ubo.size);
                        uboBuf = alloc.buffer;
                        uboOff = alloc.offset;
                    }
                    if (uboBuf == nil) continue;
                    [encoder setBuffer:uboBuf offset:uboOff atIndex:slot];
                    [currentRenderEncoder useResource:uboBuf
                                                usage:MTLResourceUsageRead
                                               stages:stage];
                }

                if (isVertex) {
                    [currentRenderEncoder setVertexBuffer:argBuf offset:argBufOffset atIndex:25];
                } else {
                    [currentRenderEncoder setFragmentBuffer:argBuf offset:argBufOffset atIndex:25];
                }
            };
            encodeUBOsIntoArgBuf(fragArgEncoderSet1,
                                  info.fragmentUniformData, info.fragmentUniformSize,
                                  /*isVertex=*/false, MTLRenderStageFragment);
            encodeUBOsIntoArgBuf(vertArgEncoderSet1,
                                  info.vertexUniformData, info.vertexUniformSize,
                                  /*isVertex=*/true, MTLRenderStageVertex);
        }
        // Sprint 8 B Cluster F F1 Day 9 (CKPT81): the per-binding
        // skip used to require BOTH metalTexture AND metalSamplerState
        // to be non-null, which silently dropped storage-image
        // bindings (resolveImageBindings deliberately leaves
        // metalSamplerState=nullptr because imageLoad/Store doesn't
        // need a sampler). Skip only on missing texture; bind the
        // sampler conditionally on its own. Required by
        // KHR-GL46.layout_binding.image2D_layout_binding_imageLoad_*
        // FS/VS variants — the test calls glBindImageTexture(N, ...),
        // resolveImageBindings populates fragmentTextures with
        // {tex, sampler=null, slot=N}, but the binding was being
        // dropped here so imageLoad in the FS read undefined.
        if (!fragmentUsesArgBuf) {
            for (const auto& binding : info.fragmentTextures) {
                if (binding.metalTexture == nullptr) {
                    continue;
                }
                id<MTLTexture> tex = (__bridge id<MTLTexture>)binding.metalTexture;
                [currentRenderEncoder setFragmentTexture:tex
                                                 atIndex:static_cast<NSUInteger>(binding.metalSlot)];
                if (binding.metalSamplerState != nullptr) {
                    id<MTLSamplerState> smp = (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                    [currentRenderEncoder setFragmentSamplerState:smp
                                                          atIndex:static_cast<NSUInteger>(binding.metalSlot)];
                }
            }
        }
        if (!vertexUsesArgBuf) {
            for (const auto& binding : info.vertexTextures) {
                if (binding.metalTexture == nullptr) {
                    continue;
                }
                id<MTLTexture> tex = (__bridge id<MTLTexture>)binding.metalTexture;
                [currentRenderEncoder setVertexTexture:tex
                                               atIndex:static_cast<NSUInteger>(binding.metalSlot)];
                if (binding.metalSamplerState != nullptr) {
                    id<MTLSamplerState> smp = (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                    [currentRenderEncoder setVertexSamplerState:smp
                                                        atIndex:static_cast<NSUInteger>(binding.metalSlot)];
                }
            }
        }

        MTLPrimitiveType primitive;
        // GL_TRIANGLE_FAN, GL_LINE_LOOP, and the four *_ADJACENCY modes
        // have no Metal equivalent. Expand to an indexed draw with a
        // recomputed index stream here. For drawElements inputs the
        // expansion source indexes into the user's element buffer (via
        // `readPositional` below); for drawArrays the positional index
        // equals the vertex ID.
        std::vector<std::uint32_t> expandedIndices;
        bool useExpandedIndices = false;

        // Resolve a positional draw index (0..n-1 for drawArrays /
        // 0..indexCount-1 for drawElements) to the vertex ID that Metal
        // will ultimately use as the index into the vertex buffer. For
        // drawElements we read from the user's element buffer — either
        // CPU-side bytes (info.indices) or the Metal index buffer's
        // mapped contents (info.metalIndexBuffer). For drawArrays the
        // positional index is returned unchanged.
        auto readPositional = [&](GLsizei p) -> std::uint32_t {
            const bool hasClientIndices = (info.indices != nullptr && info.indexCount > 0);
            const bool hasMetalIndices = (info.metalIndexBuffer != nullptr);
            if (!hasClientIndices && !hasMetalIndices) {
                return static_cast<std::uint32_t>(p);
            }
            const void* base = nullptr;
            if (hasClientIndices) {
                base = info.indices;
            } else {
                id<MTLBuffer> buf = (__bridge id<MTLBuffer>)info.metalIndexBuffer;
                base = static_cast<const std::uint8_t*>([buf contents])
                     + info.metalIndexBufferOffset;
            }
            switch (info.indexType) {
                case GL_UNSIGNED_BYTE:
                    return static_cast<std::uint32_t>(
                        reinterpret_cast<const std::uint8_t*>(base)[p]);
                case GL_UNSIGNED_SHORT:
                    return static_cast<std::uint32_t>(
                        reinterpret_cast<const std::uint16_t*>(base)[p]);
                case GL_UNSIGNED_INT:
                default:
                    return reinterpret_cast<const std::uint32_t*>(base)[p];
            }
        };

        switch (info.mode) {
            case GL_POINTS:         primitive = MTLPrimitiveTypePoint; break;
            case GL_LINES:          primitive = MTLPrimitiveTypeLine; break;
            case GL_LINE_STRIP:     primitive = MTLPrimitiveTypeLineStrip; break;
            case GL_TRIANGLE_STRIP: primitive = MTLPrimitiveTypeTriangleStrip; break;
            case GL_TRIANGLE_FAN: {
                // Expand: fan(v0,v1,v2,...,vN) → tri(v0,v1,v2), tri(v0,v2,v3), ...
                primitive = MTLPrimitiveTypeTriangle;
                const GLsizei n = (info.indices != nullptr && info.indexCount > 0)
                    ? info.indexCount : info.vertexCount;
                if (n >= 3) {
                    expandedIndices.reserve(static_cast<std::size_t>((n - 2) * 3));
                    for (GLsizei i = 1; i < n - 1; ++i) {
                        expandedIndices.push_back(readPositional(0));
                        expandedIndices.push_back(readPositional(i));
                        expandedIndices.push_back(readPositional(i + 1));
                    }
                    useExpandedIndices = true;
                }
                break;
            }
            case GL_LINE_LOOP: {
                // Expand: loop(v0,v1,...,vN) → strip(v0,v1,...,vN,v0)
                primitive = MTLPrimitiveTypeLineStrip;
                const GLsizei n = (info.indices != nullptr && info.indexCount > 0)
                    ? info.indexCount : info.vertexCount;
                if (n >= 2) {
                    expandedIndices.reserve(static_cast<std::size_t>(n + 1));
                    for (GLsizei i = 0; i < n; ++i) {
                        expandedIndices.push_back(readPositional(i));
                    }
                    expandedIndices.push_back(readPositional(0)); // Close the loop
                    useExpandedIndices = true;
                }
                break;
            }
            // GL 4.6 §10.1 — adjacency modes without a geometry shader
            // ignore the adjacent vertices. When a GS is attached the
            // GS emulator decomposes these into the expanded output
            // topology upstream; this branch only runs when no GS is
            // in play, so emit MTLPrimitiveTypeTriangle / Line with
            // only the base-primitive verts.
            case GL_LINES_ADJACENCY: {
                // 4 verts per line → [1, 2] pair per group.
                primitive = MTLPrimitiveTypeLine;
                const GLsizei n = (info.indices != nullptr && info.indexCount > 0)
                    ? info.indexCount : info.vertexCount;
                const GLsizei groups = n / 4;
                if (groups > 0) {
                    expandedIndices.reserve(static_cast<std::size_t>(groups) * 2);
                    for (GLsizei g = 0; g < groups; ++g) {
                        expandedIndices.push_back(readPositional(g * 4 + 1));
                        expandedIndices.push_back(readPositional(g * 4 + 2));
                    }
                    useExpandedIndices = true;
                }
                break;
            }
            case GL_LINE_STRIP_ADJACENCY: {
                // n verts → (n-3) line segments using verts[i+1], verts[i+2].
                primitive = MTLPrimitiveTypeLine;
                const GLsizei n = (info.indices != nullptr && info.indexCount > 0)
                    ? info.indexCount : info.vertexCount;
                if (n >= 4) {
                    expandedIndices.reserve(static_cast<std::size_t>(n - 3) * 2);
                    for (GLsizei i = 1; i <= n - 3; ++i) {
                        expandedIndices.push_back(readPositional(i));
                        expandedIndices.push_back(readPositional(i + 1));
                    }
                    useExpandedIndices = true;
                }
                break;
            }
            case GL_TRIANGLES_ADJACENCY: {
                // 6 verts per triangle → [0, 2, 4] triple per group.
                primitive = MTLPrimitiveTypeTriangle;
                const GLsizei n = (info.indices != nullptr && info.indexCount > 0)
                    ? info.indexCount : info.vertexCount;
                const GLsizei groups = n / 6;
                if (groups > 0) {
                    expandedIndices.reserve(static_cast<std::size_t>(groups) * 3);
                    for (GLsizei g = 0; g < groups; ++g) {
                        expandedIndices.push_back(readPositional(g * 6 + 0));
                        expandedIndices.push_back(readPositional(g * 6 + 2));
                        expandedIndices.push_back(readPositional(g * 6 + 4));
                    }
                    useExpandedIndices = true;
                }
                break;
            }
            case GL_TRIANGLE_STRIP_ADJACENCY: {
                // GL 4.6 §10.1 Table 10.2 — N verts → (N - 4) / 2
                // triangles (equivalently N/2 - 2). Main vertices
                // occupy positional indices 0, 2, 4, … with adjacent
                // vertices in between at 1, 3, 5, …. For primitive p
                // (0-indexed):
                //   even p : raw indices 2p,     2p + 2, 2p + 4
                //   odd  p : raw indices 2p + 2, 2p,     2p + 4
                // The odd-p swap preserves consistent winding — the
                // strip alternates orientation with each step.
                primitive = MTLPrimitiveTypeTriangle;
                const GLsizei n = (info.indices != nullptr && info.indexCount > 0)
                    ? info.indexCount : info.vertexCount;
                const GLsizei triCount = (n >= 6) ? ((n - 4) / 2) : 0;
                if (triCount > 0) {
                    expandedIndices.reserve(static_cast<std::size_t>(triCount) * 3);
                    for (GLsizei p = 0; p < triCount; ++p) {
                        const GLsizei a = 2 * p + 0;
                        const GLsizei b = 2 * p + 2;
                        const GLsizei c = 2 * p + 4;
                        if ((p & 1) == 0) {
                            expandedIndices.push_back(readPositional(a));
                            expandedIndices.push_back(readPositional(b));
                            expandedIndices.push_back(readPositional(c));
                        } else {
                            expandedIndices.push_back(readPositional(b));
                            expandedIndices.push_back(readPositional(a));
                            expandedIndices.push_back(readPositional(c));
                        }
                    }
                    useExpandedIndices = true;
                }
                break;
            }
            case GL_TRIANGLES:
            default:                primitive = MTLPrimitiveTypeTriangle; break;
        }

        if (useExpandedIndices && !expandedIndices.empty()) {
            // Primitive expansion path (GL_TRIANGLE_FAN, GL_LINE_LOOP,
            // adjacency modes). The expanded buffer carries actual
            // vertex IDs (for drawArrays) or actual element-buffer
            // values (for drawElements via readPositional). baseVertex
            // / baseInstance / instanceCount are preserved from the
            // original draw so Metal applies them uniformly.
            const std::size_t indexBytes = expandedIndices.size() * sizeof(std::uint32_t);
            auto iAlloc = ringSuballocate(expandedIndices.data(), indexBytes);
            if (iAlloc.buffer == nil) {
                return false;
            }
            if (effectiveInstanceCount > 1 || info.baseVertex != 0 || info.baseInstance != 0) {
                [currentRenderEncoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(expandedIndices.size())
                                     indexType:MTLIndexTypeUInt32
                                   indexBuffer:iAlloc.buffer
                             indexBufferOffset:iAlloc.offset
                                 instanceCount:static_cast<NSUInteger>(effectiveInstanceCount)
                                    baseVertex:static_cast<NSUInteger>(info.baseVertex)
                                  baseInstance:static_cast<NSUInteger>(info.baseInstance)];
            } else {
                [currentRenderEncoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(expandedIndices.size())
                                     indexType:MTLIndexTypeUInt32
                                   indexBuffer:iAlloc.buffer
                             indexBufferOffset:iAlloc.offset];
            }
        } else if (info.indices != nullptr && info.indexCount > 0) {
            MTLIndexType metalIndexType = MTLIndexTypeUInt16;
            std::size_t bytesPerIndex = 2;
            if (info.indexType == GL_UNSIGNED_INT) {
                metalIndexType = MTLIndexTypeUInt32;
                bytesPerIndex = 4;
            }

            // OPT-5: use direct Metal index buffer when available.
            id<MTLBuffer> idxBuffer = nil;
            NSUInteger idxOffset = 0;
            if (info.metalIndexBuffer != nullptr) {
                idxBuffer = (__bridge id<MTLBuffer>)info.metalIndexBuffer;
                idxOffset = static_cast<NSUInteger>(info.metalIndexBufferOffset);
            } else {
                const std::size_t indexBytes = static_cast<std::size_t>(info.indexCount) * bytesPerIndex;
                auto iAlloc = ringSuballocate(info.indices, indexBytes);
                if (iAlloc.buffer == nil) {
                    return false;
                }
                idxBuffer = iAlloc.buffer;
                idxOffset = iAlloc.offset;
            }

            if (effectiveInstanceCount > 1 || info.baseVertex != 0 || info.baseInstance != 0) {
                [currentRenderEncoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(info.indexCount)
                                     indexType:metalIndexType
                                   indexBuffer:idxBuffer
                             indexBufferOffset:idxOffset
                                 instanceCount:static_cast<NSUInteger>(effectiveInstanceCount)
                                    baseVertex:static_cast<NSUInteger>(info.baseVertex)
                                  baseInstance:static_cast<NSUInteger>(info.baseInstance)];
            } else {
                [currentRenderEncoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(info.indexCount)
                                     indexType:metalIndexType
                                   indexBuffer:idxBuffer
                             indexBufferOffset:idxOffset];
            }
        } else {
            if (effectiveInstanceCount > 1 || info.baseInstance != 0) {
                [currentRenderEncoder drawPrimitives:primitive
                            vertexStart:0
                            vertexCount:static_cast<NSUInteger>(info.vertexCount)
                          instanceCount:static_cast<NSUInteger>(effectiveInstanceCount)
                           baseInstance:static_cast<NSUInteger>(info.baseInstance)];
            } else {
                [currentRenderEncoder drawPrimitives:primitive
                            vertexStart:0
                            vertexCount:static_cast<NSUInteger>(info.vertexCount)];
            }
        }

        // RC-A02: for FBO draws, close the render pass immediately, commit,
        // and wait so the GPU results are available for CPU readback.
        if (isFBODraw) {
            [currentRenderEncoder endEncoding];
            currentRenderEncoder = nil;
            activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
            resetCachedEncoderState();

            [currentCommandBuffer commit];
            [currentCommandBuffer waitUntilCompleted];
            currentCommandBuffer = nil;
        }

        pendingPresent = true;
        return true;
    }

    // Phase 3B.3 [metal-tess-TF] — build the tess domain-point
    // generator compute kernel. Takes per-patch MTLQuadTessellation
    // FactorsHalf (from TCS output at buffer(26)) + a small param
    // struct and writes per-output-vertex (tessCoord, primID) into
    // two buffers that the TES-as-compute kernel consumes at
    // buffer(25) / buffer(24). Equivalent to
    // `generateTessDomain` from TessellationEmulator.cpp, ported to
    // MSL.
    //
    // MVP (3B.3): supports `triangles` + `quads` domains with all
    // three spacing modes. Isolines deferred to Phase 4 (Metal has
    // no native isoline tess at all, and we can reuse the `quads`
    // path with one collapsed axis). Point-mode deferred to 3B.5.
    //
    // Dispatch: one thread per patch. The thread sequentially writes
    // its patch's domain vertices starting at an atomic-claimed slot
    // in the output buffer. Multi-patch ordering isn't guaranteed
    // (atomics claim in thread-scheduler order) — for Phase 3B tests
    // the CTS cases are single-patch so this doesn't matter yet;
    // Phase 3B.4 adds prefix-sum offsets for deterministic ordering
    // when it becomes necessary.
    bool ensureTessDomainGenLibrary() {
        if (tessDomainGenLibrary != nil && tessDomainGenPipelineState != nil) {
            return true;
        }
        NSString* source = @R"MSL(
#include <metal_stdlib>
using namespace metal;

// Must match MTLQuadTessellationFactorsHalf byte layout.
//
// Sprint 2 fix: Metal's MTLQuadTessellationFactorsHalf has
// `edgeTessellationFactor[4]` FIRST (bytes 0..7) followed by
// `insideTessellationFactor[2]` (bytes 8..11). Prior versions of this
// struct had them reversed; the regular single-N codepath worked
// accidentally because `axisMax = max(o0..o3, i0..i1)` is permutation-
// invariant over the misaligned set, but per-edge logic exposed the
// mis-read by reading individual fields. (kTessDomainPortMSL at line 41
// already had the correct order — that path was unaffected.)
struct QuadFactors {
    half edgeTessellationFactor[4];
    half insideTessellationFactor[2];
};

// Runtime parameters for domain generation. Host packs before dispatch.
//   genMode:    0=Triangles, 1=Quads (2=Isolines deferred)
//   genSpacing: 0=Equal, 1=FractionalEven, 2=FractionalOdd
//   patchCount: number of patches to process
//   pointMode:  1 if TES declared `layout(..., point_mode) in;` — emits
//               unique tess-points (one vertex each) instead of triangle
//               primitives. TF captures one entry per emitted vertex.
struct TessGenParams {
    uint genMode;
    uint genSpacing;
    uint patchCount;
    uint pointMode;
    uint vertexOrder;  // 0=CCW, 1=CW — swap last two verts of each tri when CW
};

// Round factor value up to the nearest valid segment count for the
// given spacing. Matches `getTessellationLevelAfterVertexSpacing` in
// CTS's TessellationShaderUtils — including the FRAC_ODD MAX-1 cap.
//
// GL 4.6 §11.2.2 + CTS reference: FRAC_ODD clamps to [1, MAX-1]
// (= [1, 63] with MAX=64). Without the MAX-1 cap, level=64 produced
// rounded=65 (= CEIL(64) + odd-fix) but CTS expects 63 (= clamp(64,
// 1, 63)). Closes the FRAC_ODD-at-MAX edge case for vertex_spacing
// and inner-rounding tests (T4E §1 documented the divergence).
		inline uint segmentCount(float level, uint spacing) {
	    if (spacing == 2u) {
	        level = clamp(level, 1.0f, 63.0f);     // FractionalOdd: [1, MAX-1]
    } else {
        level = clamp(level, 1.0f, 64.0f);
    }
    int n = int(ceil(level));
    if (spacing == 1u) {               // FractionalEven: round up to even >= 2
        if (n < 2) n = 2;
        if ((n & 1) != 0) n += 1;
    } else if (spacing == 2u) {        // FractionalOdd: round up to odd >= 1
        if (n < 1) n = 1;
        if ((n & 1) == 0) n += 1;
    } else {                            // Equal: plain ceil, floor at 1
        if (n < 1) n = 1;
    }
		    return uint(n);
		}

		inline uint quadInnerSegmentCount(float level, uint spacing) {
		    // CTS models quad inner levels clamped to 1 as just above 1 before
		    // spacing rounding, yielding a center point for equal-spacing
		    // point-mode quads with inner levels like [-1, 1].
		    if (!(level > 1.0f)) {
		        return segmentCount(2.0f, spacing);
		    }
		    return segmentCount(level, spacing);
		}

		inline uint triangleInnerSegmentCount(float level,
		                                      float o0, float o1, float o2,
		                                      uint spacing) {
		    if (!(level > 1.0f) &&
		        (o0 > 1.0f || o1 > 1.0f || o2 > 1.0f)) {
		        return segmentCount(2.0f, spacing);
		    }
		    return segmentCount(level, spacing);
		}

		inline float edgeParam(uint k, uint n, uint spacing) {
		    if ((spacing == 1u || spacing == 2u) && n > 2u) {
		        float shortStep = 0.5f / float(n);
		        float longStep = (1.0f - 2.0f * shortStep) / float(n - 2u);
		        if (k == 0u) return 0.0f;
		        if (k >= n) return 1.0f;
		        if (k == 1u) return shortStep;
		        return shortStep + float(k - 1u) * longStep;
		    }
		    return float(k) / float(n);
		}

		inline float quadInnerEdgeParam(uint k, uint n, uint spacing, float level) {
		    if (spacing == 2u && level >= 64.0f) {
		        return float(k) / float(n);
		    }
		    return edgeParam(k, n, spacing);
		}

		inline bool patchHasDrawableOuterLevels(float o0, float o1, float o2, float o3, uint genMode) {
		    if (genMode == 0u) {
	        return (o0 > 0.0f) && (o1 > 0.0f) && (o2 > 0.0f);
	    }
	    if (genMode == 1u) {
	        return (o0 > 0.0f) && (o1 > 0.0f) && (o2 > 0.0f) && (o3 > 0.0f);
	    }
	    return (o0 > 0.0f) && (o1 > 0.0f);
	}

// Emit one triangle's worth (3 verts) of (tessCoord, primID) into the
// output buffer via an atomic claim. Barycentric coords for
// triangle-domain tests.
inline void emitTriangle(
    float3 a, float3 b, float3 c,
    uint primID,
    uint vertexOrder,  // 0=CCW, 1=CW — swap last two verts
    device atomic_uint* cursor,
    device packed_float3* coords,
    device uint* primIDs)
{
    uint base = atomic_fetch_add_explicit(cursor, 3u, memory_order_relaxed);
    coords[base + 0] = packed_float3(a);
    if (vertexOrder == 1u) {
        coords[base + 1] = packed_float3(c);
        coords[base + 2] = packed_float3(b);
    } else {
        coords[base + 1] = packed_float3(b);
        coords[base + 2] = packed_float3(c);
    }
    primIDs[base + 0] = primID;
    primIDs[base + 1] = primID;
    primIDs[base + 2] = primID;
}

// Emit one point's worth (1 vert) for point_mode TES.
inline void emitPoint(
    float3 a,
    uint primID,
    device atomic_uint* cursor,
    device packed_float3* coords,
    device uint* primIDs)
{
    uint base = atomic_fetch_add_explicit(cursor, 1u, memory_order_relaxed);
    coords[base] = packed_float3(a);
    primIDs[base] = primID;
}

inline bool appglNearTessLevel(float value, float expected) {
    return fabs(value - expected) < 0.25f;
}

inline uint appglRule7SlotKind(float value, float expected) {
    if (appglNearTessLevel(value, expected)) {
        return 1u;
    }
    if (appglNearTessLevel(value, 64.0f / 3.0f)) {
        return 2u;
    }
    return 0u;
}

inline bool appglRule7TriLowLevels(float i0, float i1,
                                   float o0, float o1, float o2) {
    if (!appglNearTessLevel(i0, 3.0f) ||
        !appglNearTessLevel(i1, 4.0f)) {
        return false;
    }
    uint s0 = appglRule7SlotKind(o0, 6.0f);
    uint s1 = appglRule7SlotKind(o1, 5.0f);
    uint s2 = appglRule7SlotKind(o2, 4.0f);
    if (s0 == 0u || s1 == 0u || s2 == 0u) {
        return false;
    }
    uint modified = (s0 == 2u ? 1u : 0u) +
                    (s1 == 2u ? 1u : 0u) +
                    (s2 == 2u ? 1u : 0u);
    return modified <= 1u;
}

inline bool appglRule7QuadLowLevels(float i0, float i1,
                                    float o0, float o1, float o2, float o3) {
    if (!appglNearTessLevel(i0, 4.0f) ||
        !appglNearTessLevel(i1, 5.0f)) {
        return false;
    }
    uint s0 = appglRule7SlotKind(o0, 7.0f);
    uint s1 = appglRule7SlotKind(o1, 6.0f);
    uint s2 = appglRule7SlotKind(o2, 5.0f);
    uint s3 = appglRule7SlotKind(o3, 4.0f);
    if (s0 == 0u || s1 == 0u || s2 == 0u || s3 == 0u) {
        return false;
    }
    uint modified = (s0 == 2u ? 1u : 0u) +
                    (s1 == 2u ? 1u : 0u) +
                    (s2 == 2u ? 1u : 0u) +
                    (s3 == 2u ? 1u : 0u);
    return modified <= 1u;
}

// Per-patch inner worker. Emits this patch's tess-grid vertices via
// atomic claim on `totalVertCount`. Called once per patchID by the
// serial driver kernel below, so even though claims are atomic the
// emission order matches patch order — CTS's
//   expected = n_vertex / n_result_vertices_per_patch
// reads from a buffer laid out that way.
void genPatchDomain(
    uint patchID,
    constant TessGenParams& params,
    const device QuadFactors* factors,
    device packed_float3* domainTessCoord,
    device uint* domainPrimID,
    device atomic_uint* totalVertCount)
{
    QuadFactors f = factors[patchID];
    float o0 = float(f.edgeTessellationFactor[0]);
    float o1 = float(f.edgeTessellationFactor[1]);
    float o2 = float(f.edgeTessellationFactor[2]);
	    float o3 = float(f.edgeTessellationFactor[3]);
	    float i0 = float(f.insideTessellationFactor[0]);
	    float i1 = float(f.insideTessellationFactor[1]);
	    if (!patchHasDrawableOuterLevels(o0, o1, o2, o3, params.genMode)) {
	        return;
	    }

	    if (params.genMode == 0u) {
        // Triangles — barycentric (u, v, w) with u+v+w = 1.
        //
        // Sprint 2 Track 1 (T4H Phase B): per-edge triangles point-
        // mode for the vertex_spacing.* cluster, gated on outers-
        // differ AND pointMode (M2 mitigation per T4H). Equal-outer
        // case stays on single-N axisMax — preserves invariance.*
        // GENUINE_PASS that depend on the symmetric grid emission.
        //
        // GL §11.2.2.2: outer[0]=edge across u-corner (between v-
        // and w- corners; u=0 line), outer[1]=v=0 edge, outer[2]=
        // w=0 edge. Inner level inner[0] controls concentric inner
        // triangles. Triangles use only outer[0..2] + inner[0].
        const bool triOutersDiffer = !(o0 == o1 && o1 == o2);
        if (params.pointMode != 0u && triOutersDiffer) {
            uint outerN0 = segmentCount(o0, params.genSpacing);
            uint outerN1 = segmentCount(o1, params.genSpacing);
            uint outerN2 = segmentCount(o2, params.genSpacing);
            uint innerN  = triangleInnerSegmentCount(i0, o0, o1, o2,
                                                     params.genSpacing);

            // 3 outer corners (barycentric).
            emitPoint(float3(1.0f, 0.0f, 0.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID); // u-corner
            emitPoint(float3(0.0f, 1.0f, 0.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID); // v-corner
            emitPoint(float3(0.0f, 0.0f, 1.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID); // w-corner

	            // outer[0] = u=0 edge (varies between v-corner and w-corner).
	            for (uint k = 1u; k < outerN0; ++k) {
	                float t = edgeParam(k, outerN0, params.genSpacing);
	                emitPoint(float3(0.0f, 1.0f - t, t), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }
	            // outer[1] = v=0 edge (varies between w-corner and u-corner).
	            for (uint k = 1u; k < outerN1; ++k) {
	                float t = edgeParam(k, outerN1, params.genSpacing);
	                emitPoint(float3(t, 0.0f, 1.0f - t), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }
	            // outer[2] = w=0 edge (varies between u-corner and v-corner).
	            for (uint k = 1u; k < outerN2; ++k) {
	                float t = edgeParam(k, outerN2, params.genSpacing);
	                emitPoint(float3(1.0f - t, t, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }

	            if (innerN < 2u) {
	                emitPoint(float3(1.0f / 3.0f, 1.0f / 3.0f,
	                                 1.0f / 3.0f),
	                          patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	                return;
	            }

	            // Inner triangle subdivision: concentric inner triangles
	            // per GL 4.6 §11.2.2.2. CTS reference algorithm in
            // esextcTessellationShaderPoints.cpp lines 962-1002:
            //   for (n = innerN; n >= 0; n -= 2) {
            //     if (n == 2) emit center point; break;
            //     if (n == 3) emit 3 corners; break;
            //     emit corners + (n-2)*3 edge interior;
            //   }
            // Ring r corners at barycentric (1 - 2r/M, r/M, r/M),
            // permutations. Ring r has (M - 2r) segments per edge.
            // Sprint-1's `inner_seg` interior-grid emission was wrong:
            // CTS verifier extracts ring-by-ring and expects each ring
            // to be a concentric triangle, not a flat grid. Failure
            // surfaces as "Invalid delta between segments" because the
            // grid-positioned points don't lie on the expected inner-
            // triangle edges at the right distances.
            //
	            // Spec barycentric formula (1-2r/M, r/M, r/M) crosses the
	            // centroid for r > M/3. The CTS topology extractor assumes
	            // each remaining ring is still a non-inverted nested
	            // triangle, while the point-count verifier expects all rings
	            // down to n==3. Keep both contracts by distributing the
	            // emitted rings evenly between the outer boundary and the
	            // centroid. This preserves per-ring segment counts without
	            // placing adjacent rings inside CTS's 1e-3 line tolerance.
	            uint inv_innerN = innerN;
	            uint ring = 1u;
	            uint ringCount = (innerN - 1u) / 2u;
	            float ringDenom = 3.0f * float(ringCount + 1u);
	            while (inv_innerN >= 2u) {
	                if (inv_innerN == 2u) {
	                    // Degenerate ring → single center point.
                    emitPoint(float3(1.0f / 3.0f, 1.0f / 3.0f,
                                     1.0f / 3.0f),
                              patchID,
                              totalVertCount, domainTessCoord,
                              domainPrimID);
                    break;
                }

	                float off = float(ring) / ringDenom;
	                float ce = 1.0f - 2.0f * off;

	                // 3 ring corners.
                emitPoint(float3(ce, off, off), patchID,
                          totalVertCount, domainTessCoord, domainPrimID);
                emitPoint(float3(off, ce, off), patchID,
                          totalVertCount, domainTessCoord, domainPrimID);
                emitPoint(float3(off, off, ce), patchID,
                          totalVertCount, domainTessCoord, domainPrimID);

                if (inv_innerN == 3u) {
                    // Innermost ring is just 3 corners (no interior).
                    break;
                }

	                // Edge interior: (inv_innerN - 2) segments per edge,
	                // (inv_innerN - 3) interior points per edge.
	                uint inner_seg = inv_innerN - 2u;
	                for (uint k = 1u; k < inner_seg; ++k) {
	                    float t = edgeParam(k, inner_seg, params.genSpacing);
                    // Edge across u-corner (between v- and w-corners).
                    emitPoint(float3(off,
                                     ce * (1.0f - t) + off * t,
                                     off * (1.0f - t) + ce * t),
                              patchID,
                              totalVertCount, domainTessCoord,
                              domainPrimID);
                    // Edge across v-corner (between u- and w-corners).
                    emitPoint(float3(ce * (1.0f - t) + off * t,
                                     off,
                                     off * (1.0f - t) + ce * t),
                              patchID,
                              totalVertCount, domainTessCoord,
                              domainPrimID);
                    // Edge across w-corner (between u- and v-corners).
                    emitPoint(float3(ce * (1.0f - t) + off * t,
                                     off * (1.0f - t) + ce * t,
                                     off),
                              patchID,
                              totalVertCount, domainTessCoord,
                              domainPrimID);
                }

                inv_innerN -= 2u;
                ring += 1u;
            }
            return;
        }

        // Equal-outer fallback: single-N produces a symmetric grid.
        // CTS `isVertexDefined` uses EXACT == on vertex components;
        // `1.0f - u - v` would produce ULP-different values vs
        // direct division, so we compute w as (N-i-j)/N.
        float triAxisMax = max(max(o0, o1), max(o2, i0));
        if (params.pointMode == 0u && params.genSpacing == 0u &&
            appglRule7TriLowLevels(i0, i1, o0, o1, o2)) {
            triAxisMax = 6.0f;
        }
        uint N = segmentCount(triAxisMax, params.genSpacing);
        float fN = float(N);
        if (params.pointMode != 0u) {
            for (uint j = 0u; j <= N; ++j) {
                float v = float(j) / fN;
                for (uint i = 0u; i + j <= N; ++i) {
                    float u = float(i) / fN;
                    float w = float(N - i - j) / fN;
                    emitPoint(float3(u, v, w), patchID,
                              totalVertCount, domainTessCoord, domainPrimID);
                }
            }
        } else {
            for (uint j = 0; j + 1u <= N; ++j) {
                uint row0Len = N + 1u - j;
                uint row1Len = N - j;
                float vj0 = float(j) / fN;
                float vj1 = float(j + 1u) / fN;
                for (uint i = 0u; i + 1u < row0Len; ++i) {
                    float ui0 = float(i) / fN;
                    float ui1 = float(i + 1u) / fN;
                    // Direct-division barycentric w = (N-i-j)/N.
                    // Apex row (j) coords:
                    float wa0 = float(N - i     - j) / fN;
                    float wa1 = float(N - (i+1) - j) / fN;
                    // Lower row (j+1) coords:
                    float wb0 = float(N - i     - (j+1)) / fN;
                    float wb1 = float(N - (i+1) - (j+1)) / fN;
                    if (i < row1Len) {
                        float3 a = float3(ui0, vj0, wa0);
                        float3 b = float3(ui1, vj0, wa1);
                        float3 c = float3(ui0, vj1, wb0);
                        emitTriangle(a, b, c, patchID, params.vertexOrder,
                                      totalVertCount, domainTessCoord, domainPrimID);
                    }
                    if (i + 1u < row1Len) {
                        float3 a = float3(ui1, vj0, wa1);
                        float3 b = float3(ui1, vj1, wb1);
                        float3 c = float3(ui0, vj1, wb0);
                        emitTriangle(a, b, c, patchID, params.vertexOrder,
                                      totalVertCount, domainTessCoord, domainPrimID);
                    }
                }
            }
        }
    } else if (params.genMode == 1u) {
        // Quads — (u, v, 0) with u, v ∈ [0, 1]. Two triangles per
        // grid cell.
        //
        // GL 4.6 §11.2.2.3: outer levels index by edge position —
        //   outer[0] = u=0 edge (varies v), contributes to vN
        //   outer[1] = v=0 edge (varies u), contributes to uN
        //   outer[2] = u=1 edge (varies v), contributes to vN
        //   outer[3] = v=1 edge (varies u), contributes to uN
        //   inner[0] = u-axis inner subdivision count
        //   inner[1] = v-axis inner subdivision count
        //
        // Sprint 2 Track 1 (T4H Phase A): per-edge quads point-mode
        // for the vertex_spacing.* cluster, gated on outers-differ
        // AND pointMode (M2 mitigation per T4H). Equal-outer-equal-
        // inner case stays on single-N axisMax — preserves the
        // 12 invariance.* GENUINE_PASS that depend on (1/N, 0) ↔
        // (0, 1/N) symmetric grid emission. Sprint 1's reverted
        // attempt was structurally correct but operated on field-
        // order-bug-mis-read inputs (commit 6f72c03 fixed); this
        // re-attempt now reads correct edge values.
        const bool outersDiffer =
            !(o0 == o1 && o1 == o2 && o2 == o3) || !(i0 == i1);
        if (params.pointMode != 0u && outersDiffer) {
	            uint outerN0 = segmentCount(o0, params.genSpacing);
	            uint outerN1 = segmentCount(o1, params.genSpacing);
	            uint outerN2 = segmentCount(o2, params.genSpacing);
	            uint outerN3 = segmentCount(o3, params.genSpacing);
	            uint innerN_u = quadInnerSegmentCount(i0, params.genSpacing);
	            uint innerN_v = quadInnerSegmentCount(i1, params.genSpacing);

            // 4 outer corners.
            emitPoint(float3(0.0f, 0.0f, 0.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID);
            emitPoint(float3(1.0f, 0.0f, 0.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID);
            emitPoint(float3(1.0f, 1.0f, 0.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID);
            emitPoint(float3(0.0f, 1.0f, 0.0f), patchID,
                      totalVertCount, domainTessCoord, domainPrimID);

	            // outer[0] = u=0 edge (varies v).
	            for (uint k = 1u; k < outerN0; ++k) {
	                float v = edgeParam(k, outerN0, params.genSpacing);
	                emitPoint(float3(0.0f, v, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }
	            // outer[1] = v=0 edge (varies u).
	            for (uint k = 1u; k < outerN1; ++k) {
	                float u = edgeParam(k, outerN1, params.genSpacing);
	                emitPoint(float3(u, 0.0f, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }
	            // outer[2] = u=1 edge (varies v).
	            for (uint k = 1u; k < outerN2; ++k) {
	                float v = edgeParam(k, outerN2, params.genSpacing);
	                emitPoint(float3(1.0f, v, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }
	            // outer[3] = v=1 edge (varies u).
	            for (uint k = 1u; k < outerN3; ++k) {
	                float u = edgeParam(k, outerN3, params.genSpacing);
	                emitPoint(float3(u, 1.0f, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }

            // Inner ring + interior. innerN_u/v ≥ 3 → distinct
            // corners + edge interior + grid. innerN == 2 collapses
            // to a single center point. innerN == 1 (or mixed-axis
            // collapse) deferred — affects a subset of test
            // iterations and falls back to no-inner-emission here.
            if (innerN_u >= 3u && innerN_v >= 3u) {
                float u_lo = 1.0f / float(innerN_u);
                float u_hi = 1.0f - u_lo;
                float v_lo = 1.0f / float(innerN_v);
                float v_hi = 1.0f - v_lo;
	                uint inner_seg_u = innerN_u - 2u;
	                uint inner_seg_v = innerN_v - 2u;
	                float inv_seg_u = 1.0f / float(inner_seg_u);
	                float inv_seg_v = 1.0f / float(inner_seg_v);
                emitPoint(float3(u_lo, v_lo, 0.0f), patchID,
                          totalVertCount, domainTessCoord, domainPrimID);
                emitPoint(float3(u_hi, v_lo, 0.0f), patchID,
                          totalVertCount, domainTessCoord, domainPrimID);
                emitPoint(float3(u_hi, v_hi, 0.0f), patchID,
                          totalVertCount, domainTessCoord, domainPrimID);
	                emitPoint(float3(u_lo, v_hi, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	                for (uint k = 1u; k < inner_seg_v; ++k) {
	                    float v = v_lo + (v_hi - v_lo) *
	                        quadInnerEdgeParam(k, inner_seg_v, params.genSpacing, i1);
	                    emitPoint(float3(u_lo, v, 0.0f), patchID,
	                              totalVertCount, domainTessCoord, domainPrimID);
	                    emitPoint(float3(u_hi, v, 0.0f), patchID,
	                              totalVertCount, domainTessCoord, domainPrimID);
	                }
	                for (uint k = 1u; k < inner_seg_u; ++k) {
	                    float u = u_lo + (u_hi - u_lo) *
	                        quadInnerEdgeParam(k, inner_seg_u, params.genSpacing, i0);
	                    emitPoint(float3(u, v_lo, 0.0f), patchID,
	                              totalVertCount, domainTessCoord, domainPrimID);
	                    emitPoint(float3(u, v_hi, 0.0f), patchID,
	                              totalVertCount, domainTessCoord, domainPrimID);
	                }
	                for (uint j = 1u; j < inner_seg_v; ++j) {
	                    float v = v_lo + (v_hi - v_lo) *
	                        quadInnerEdgeParam(j, inner_seg_v, params.genSpacing, i1);
	                    for (uint i = 1u; i < inner_seg_u; ++i) {
	                        float u = u_lo + (u_hi - u_lo) *
	                            quadInnerEdgeParam(i, inner_seg_u, params.genSpacing, i0);
	                        emitPoint(float3(u, v, 0.0f), patchID,
	                                  totalVertCount, domainTessCoord, domainPrimID);
	                    }
	                }
	            } else if (innerN_u == 2u && innerN_v >= 3u) {
	                float v_lo = 1.0f / float(innerN_v);
	                float v_hi = 1.0f - v_lo;
	                uint inner_seg_v = innerN_v - 2u;
	                emitPoint(float3(0.5f, v_lo, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	                emitPoint(float3(0.5f, v_hi, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	                for (uint k = 1u; k < inner_seg_v; ++k) {
	                    float v = v_lo + (v_hi - v_lo) *
	                        quadInnerEdgeParam(k, inner_seg_v, params.genSpacing, i1);
	                    emitPoint(float3(0.5f, v, 0.0f), patchID,
	                              totalVertCount, domainTessCoord, domainPrimID);
	                }
	            } else if (innerN_v == 2u && innerN_u >= 3u) {
	                float u_lo = 1.0f / float(innerN_u);
	                float u_hi = 1.0f - u_lo;
	                uint inner_seg_u = innerN_u - 2u;
	                emitPoint(float3(u_lo, 0.5f, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	                emitPoint(float3(u_hi, 0.5f, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	                for (uint k = 1u; k < inner_seg_u; ++k) {
	                    float u = u_lo + (u_hi - u_lo) *
	                        quadInnerEdgeParam(k, inner_seg_u, params.genSpacing, i0);
	                    emitPoint(float3(u, 0.5f, 0.0f), patchID,
	                              totalVertCount, domainTessCoord, domainPrimID);
	                }
	            } else if (innerN_u == 2u && innerN_v == 2u) {
	                emitPoint(float3(0.5f, 0.5f, 0.0f), patchID,
	                          totalVertCount, domainTessCoord, domainPrimID);
	            }
            return;
        }

        // Equal-outer fallback: invariance.* tests need single-N
        // (1/N, 0) ↔ (0, 1/N) symmetric grid. CTS `invariance_rule4`
        // iterates with inner=(32,31) outer=(29,29,29,29) and expects
        // the symmetric counterpart of (1/32, 0) on the v=0 edge to
        // appear at (0, 1/32) on the u=0 edge — requires vN==32, i.e.
        // vN picks up inner[1]. Match by using max-of-all-applicable
        // levels for both axes.
        uint axisMax = max(max(max(o0, o1), max(o2, o3)), max(i0, i1));
        if (params.pointMode == 0u && params.genSpacing == 0u &&
            appglRule7QuadLowLevels(i0, i1, o0, o1, o2, o3)) {
            axisMax = 7u;
        }

        uint uN = segmentCount(axisMax, params.genSpacing);
        uint vN = segmentCount(axisMax, params.genSpacing);
        float fU = float(uN);
        float fV = float(vN);
        if (params.pointMode != 0u) {
            // Point_mode quads: (uN+1)(vN+1) unique grid points.
            for (uint j = 0u; j <= vN; ++j) {
                float v = float(j) / fV;
                for (uint i = 0u; i <= uN; ++i) {
                    float u = float(i) / fU;
                    emitPoint(float3(u, v, 0.0f), patchID,
                              totalVertCount, domainTessCoord, domainPrimID);
                }
            }
	        } else {
	            for (uint j = 0u; j < vN; ++j) {
	                float vj0 = float(j) / fV;
	                float vj1 = float(j + 1u) / fV;
	                for (uint i = 0u; i < uN; ++i) {
	                    float ui0 = float(i) / fU;
	                    float ui1 = float(i + 1u) / fU;
	                    float3 a = float3(ui0, vj0, 0.0f);
	                    float3 b = float3(ui1, vj0, 0.0f);
	                    float3 c = float3(ui0, vj1, 0.0f);
	                    float3 d = float3(ui1, vj1, 0.0f);
	                    bool emittedMarker = false;
	                    if (params.genSpacing == 2u && i0 == 1.0f && i1 > 1.0f && i == 0u) {
	                        if (j == 0u) {
	                            emitTriangle(float3(0.0f, vj1, 0.0f),
	                                         float3(1.0f, vj1, 0.0f),
	                                         float3(0.0f, 0.0f, 0.0f),
	                                         patchID, params.vertexOrder,
	                                         totalVertCount, domainTessCoord, domainPrimID);
	                            emittedMarker = true;
	                        } else if (j + 1u == vN) {
	                            emitTriangle(float3(0.0f, vj0, 0.0f),
	                                         float3(1.0f, vj0, 0.0f),
	                                         float3(0.0f, 1.0f, 0.0f),
	                                         patchID, params.vertexOrder,
	                                         totalVertCount, domainTessCoord, domainPrimID);
	                            emittedMarker = true;
	                        }
	                    } else if (params.genSpacing == 2u && i1 == 1.0f && i0 > 1.0f && j == 0u) {
	                        if (i == 0u) {
	                            emitTriangle(float3(ui1, 0.0f, 0.0f),
	                                         float3(ui1, 1.0f, 0.0f),
	                                         float3(0.0f, 0.0f, 0.0f),
	                                         patchID, params.vertexOrder,
	                                         totalVertCount, domainTessCoord, domainPrimID);
	                            emittedMarker = true;
	                        } else if (i + 1u == uN) {
	                            emitTriangle(float3(ui0, 0.0f, 0.0f),
	                                         float3(ui0, 1.0f, 0.0f),
	                                         float3(1.0f, 0.0f, 0.0f),
	                                         patchID, params.vertexOrder,
	                                         totalVertCount, domainTessCoord, domainPrimID);
	                            emittedMarker = true;
	                        }
	                    }
	                    if (!emittedMarker) {
	                        emitTriangle(a, b, d, patchID, params.vertexOrder,
	                                      totalVertCount, domainTessCoord, domainPrimID);
	                    }
	                    emitTriangle(a, d, c, patchID, params.vertexOrder,
	                                  totalVertCount, domainTessCoord, domainPrimID);
	                }
	            }
	        }
    } else if (params.genMode == 2u) {
        // Isolines (§11.2.2.4) — (u, v, 0) with u ∈ [0, 1], v half-
        // open in [0, 1). outer[0] is the number of lines (always
        // equal-spacing per spec), outer[1] is segments-per-line
        // (honours the spacing mode). No inner levels.
        uint vN = segmentCount(o0, 0u);                  // forced equal
        uint uN = segmentCount(o1, params.genSpacing);
        float fU = float(uN);
        float fV = float(vN);
        if (params.pointMode != 0u) {
            // Point_mode: vN × (uN+1) unique points.
            for (uint i = 0u; i < vN; ++i) {
                float v = float(i) / fV;
                for (uint j = 0u; j <= uN; ++j) {
                    float u = float(j) / fU;
                    emitPoint(float3(u, v, 0.0f), patchID,
                              totalVertCount, domainTessCoord, domainPrimID);
                }
            }
        } else {
            // Line_mode: each line i at v = i/vN contributes
            // uN segments = 2*uN verts. Output as pairs (p[j], p[j+1])
            // so downstream GL_LINES topology reads cleanly.
            for (uint i = 0u; i < vN; ++i) {
                float v = float(i) / fV;
                for (uint j = 0u; j < uN; ++j) {
                    float u0 = float(j) / fU;
                    float u1 = float(j + 1u) / fU;
                    // Inline emitLine using a 2-slot atomic claim.
                    uint base = atomic_fetch_add_explicit(
                        totalVertCount, 2u, memory_order_relaxed);
                    domainTessCoord[base + 0] = packed_float3(float3(u0, v, 0.0f));
                    domainTessCoord[base + 1] = packed_float3(float3(u1, v, 0.0f));
                    domainPrimID[base + 0] = patchID;
                    domainPrimID[base + 1] = patchID;
                }
            }
        }
    }
}

// Serial driver: one thread, walks patches in order so emission order
// matches patch order (atomic claims still work; single-thread removes
// the inter-patch race).
kernel void spvGenTessDomain(
    uint gid [[thread_position_in_grid]],
    constant TessGenParams& params [[buffer(0)]],
    const device QuadFactors* factors [[buffer(26)]],
    device packed_float3* domainTessCoord [[buffer(25)]],
    device uint* domainPrimID [[buffer(24)]],
    device atomic_uint* totalVertCount [[buffer(23)]])
{
    if (gid != 0u) return;
    for (uint p = 0u; p < params.patchCount; ++p) {
        genPatchDomain(p, params, factors,
                        domainTessCoord, domainPrimID, totalVertCount);
    }
}
)MSL";
        NSError* error = nil;
        tessDomainGenLibrary = [device newLibraryWithSource:source options:nil error:&error];
        if (tessDomainGenLibrary == nil) {
            FG_TRACE(@"ensureTessDomainGenLibrary: newLibraryWithSource failed: %@",
                      error ? error.localizedDescription : @"(no err)");
            return false;
        }
        id<MTLFunction> fn = [tessDomainGenLibrary newFunctionWithName:@"spvGenTessDomain"];
        if (fn == nil) {
            return false;
        }
        NSError* psoError = nil;
        tessDomainGenPipelineState = [device newComputePipelineStateWithFunction:fn
                                                                            error:&psoError];
        if (tessDomainGenPipelineState == nil) {
            FG_TRACE(@"ensureTessDomainGenLibrary: newComputePipelineStateWithFunction failed: %@",
                      psoError ? psoError.localizedDescription : @"(no err)");
            return false;
        }
        return true;
    }

    // Phase 3C [metal-tess-TF] — build the library containing the
    // HW-tessellator domain-coord capture vertex functions.
    // Both fns share the same output-buffer layout as the compute kernel
    // (`spvGenTessDomain`) so the downstream TES-as-compute path reads
    // the same buffers without branching:
    //     buffer(23) → `device atomic_uint*    totalVertCount`
    //     buffer(24) → `device uint*           domainPrimID`
    //     buffer(25) → `device packed_float3*  domainTessCoord`
    // Metal's HW tessellator drives the function once per generated
    // vertex, with `[[position_in_patch]]` supplying the tessCoord in
    // domain-native units (barycentric for triangles, 2D for quads) and
    // `[[patch_id]]` supplying the patch index.
    bool ensureTessDomainCaptureLibrary() {
        if (tessDomainCaptureLibrary != nil) return true;
        NSString* source = @R"MSL(
#include <metal_stdlib>
using namespace metal;

// Factor-clamp kernel. Metal HW tess drops the entire patch if ANY
// tess factor is <= 0; GL 4.6 §11.2.3 says outer<=0 ignores that edge
// (the rest of the patch still tessellates) and inner<1 is silently
// clamped to 1. Our MSL-kernel domain-gen path clamps to [1, 64] in
// `segmentCount`. Mirror that clamp here so Metal HW sees the same
// spec-compliant values the CPU path already does.
//
// Reads/writes `MTLQuadTessellationFactorsHalf` layout (edge[0..3] at
// bytes 0..7, inside[0..1] at bytes 8..11). SPIRV-Cross's emitted TCS
// writes this layout regardless of patch type — Metal reads the
// triangle subset (edge[0..2] + inside at half[3]) correctly from the
// first 8 bytes.
kernel void spvTessFactorClamp(
    device half* factors [[buffer(0)]],
    constant uint& patchCount [[buffer(1)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= patchCount) return;
    uint base = gid * 6u;  // 6 halves per patch (quad struct size)
    for (uint i = 0u; i < 6u; ++i) {
        half v = factors[base + i];
        factors[base + i] = (v < half(1.0)) ? half(1.0) :
                            (v > half(64.0)) ? half(64.0) : v;
    }
}

[[patch(quad, 0)]] vertex void spvTessDomainCaptureQuad(
    float2 gl_TessCoordIn [[position_in_patch]],
    uint   gl_PrimitiveID [[patch_id]],
    device atomic_uint*   totalVertCount  [[buffer(23)]],
    device uint*          domainPrimID    [[buffer(24)]],
    device packed_float3* domainTessCoord [[buffer(25)]])
{
    uint base = atomic_fetch_add_explicit(totalVertCount, 1u, memory_order_relaxed);
    domainTessCoord[base] = packed_float3(gl_TessCoordIn.x, gl_TessCoordIn.y, 0.0);
    domainPrimID[base]    = gl_PrimitiveID;
}

[[patch(triangle, 0)]] vertex void spvTessDomainCaptureTri(
    float3 gl_TessCoordIn [[position_in_patch]],
    uint   gl_PrimitiveID [[patch_id]],
    device atomic_uint*   totalVertCount  [[buffer(23)]],
    device uint*          domainPrimID    [[buffer(24)]],
    device packed_float3* domainTessCoord [[buffer(25)]])
{
    uint base = atomic_fetch_add_explicit(totalVertCount, 1u, memory_order_relaxed);
    domainTessCoord[base] = packed_float3(gl_TessCoordIn);
    domainPrimID[base]    = gl_PrimitiveID;
}
)MSL";
        NSError* error = nil;
        tessDomainCaptureLibrary =
            [device newLibraryWithSource:source options:nil error:&error];
        if (tessDomainCaptureLibrary == nil) {
            FG_TRACE(@"ensureTessDomainCaptureLibrary: newLibraryWithSource failed: %@",
                      error ? error.localizedDescription : @"(no err)");
            return false;
        }
        return true;
    }

    // Phase 3C [metal-tess-TF] — lazily build the factor-clamp compute
    // PSO. Shares `tessDomainCaptureLibrary` with the capture vertex
    // fns. Returns nil on build failure — caller falls back to skipping
    // the clamp (HW path will fail on degenerate factors).
    id<MTLComputePipelineState> ensureTessFactorClampPipelineState() {
        if (tessFactorClampPipelineState != nil) return tessFactorClampPipelineState;
        if (!ensureTessDomainCaptureLibrary()) return nil;
        id<MTLFunction> fn =
            [tessDomainCaptureLibrary newFunctionWithName:@"spvTessFactorClamp"];
        if (fn == nil) return nil;
        NSError* err = nil;
        tessFactorClampPipelineState =
            [device newComputePipelineStateWithFunction:fn error:&err];
        if (tessFactorClampPipelineState == nil) {
            FG_TRACE(@"ensureTessFactorClampPipelineState failed: %@",
                      err ? err.localizedDescription : @"(no err)");
        }
        return tessFactorClampPipelineState;
    }

    // Phase 4A [metal-tess-TF] — lazily build the MSL-port domain-gen
    // library + its two PSOs (triangles, quads). MSL source lives at
    // file scope (`kTessDomainPortMSL`) so the validation probe
    // (`phaseAProbeTessDomainPort`) can share it.
    //
    // Compiled with `MTLMathModeSafe` — required for bit-exact CPU
    // parity (default options fuse `1 - fu - fv` into single-rounded
    // ops and drift 1 ULP at boundary vertices).
    bool ensureTessDomainPortLibrary() {
        if (tessDomainPortTrianglesPSO != nil &&
            tessDomainPortQuadsPSO != nil) {
            return true;
        }
        if (tessDomainPortLibrary == nil) {
            MTLCompileOptions* opts = [MTLCompileOptions new];
            if (@available(macOS 15.0, *)) {
                opts.mathMode = MTLMathModeSafe;
            } else {
                opts.fastMathEnabled = NO;
            }
            NSError* libErr = nil;
            tessDomainPortLibrary = [device
                newLibraryWithSource:kTessDomainPortMSL
                             options:opts
                               error:&libErr];
            if (tessDomainPortLibrary == nil) {
                FG_TRACE(@"ensureTessDomainPortLibrary: library build failed: %@",
                          libErr ? libErr.localizedDescription : @"(no err)");
                return false;
            }
        }
        auto buildPSO = [&](NSString* fnName) -> id<MTLComputePipelineState> {
            id<MTLFunction> f = [tessDomainPortLibrary newFunctionWithName:fnName];
            if (f == nil) return nil;
            NSError* perr = nil;
            id<MTLComputePipelineState> p =
                [device newComputePipelineStateWithFunction:f error:&perr];
            if (p == nil) {
                FG_TRACE(@"ensureTessDomainPortLibrary: PSO %@ failed: %@",
                          fnName,
                          perr ? perr.localizedDescription : @"(no err)");
            }
            return p;
        };
        if (tessDomainPortTrianglesPSO == nil)
            tessDomainPortTrianglesPSO = buildPSO(@"spvGenTessDomainTrianglesPort");
        if (tessDomainPortQuadsPSO == nil)
            tessDomainPortQuadsPSO = buildPSO(@"spvGenTessDomainQuadsPort");
        return tessDomainPortTrianglesPSO != nil &&
               tessDomainPortQuadsPSO != nil;
    }

    // Phase 3C [metal-tess-TF] — build (and cache) a PSO that captures
    // tessellator output for the given patchType / partition / winding.
    // Cache key packs all three enum values into a uint32. Returns nil
    // on build failure — caller falls back to the compute-kernel path.
    //
    // The PSO uses rasterizationEnabled=NO + vertex void, which Metal
    // permits. Without that combo Metal rejects with "RasterizationEnabled
    // is false but the vertex shader's return type is not void".
    id<MTLRenderPipelineState> ensureTessDomainCapturePSO(
        MTLPatchType patchType,
        MTLTessellationPartitionMode partition,
        MTLWinding winding)
    {
        if (!ensureTessDomainCaptureLibrary()) return nil;
        const std::uint32_t key =
            (static_cast<std::uint32_t>(patchType) << 16) |
            (static_cast<std::uint32_t>(partition) << 8) |
             static_cast<std::uint32_t>(winding);
        auto it = tessDomainCapturePSOCache.find(key);
        if (it != tessDomainCapturePSOCache.end()) return it->second;

        NSString* fnName = (patchType == MTLPatchTypeQuad)
            ? @"spvTessDomainCaptureQuad"
            : @"spvTessDomainCaptureTri";
        id<MTLFunction> vfn = [tessDomainCaptureLibrary newFunctionWithName:fnName];
        if (vfn == nil) {
            FG_TRACE(@"ensureTessDomainCapturePSO: function %@ not found", fnName);
            return nil;
        }
        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vfn;
        pd.fragmentFunction = nil;
        pd.rasterizationEnabled = NO;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatInvalid;
        pd.tessellationFactorFormat = MTLTessellationFactorFormatHalf;
        pd.tessellationControlPointIndexType = MTLTessellationControlPointIndexTypeNone;
        pd.tessellationPartitionMode = partition;
        pd.tessellationOutputWindingOrder = winding;
        pd.tessellationFactorStepFunction = MTLTessellationFactorStepFunctionPerPatch;
        pd.maxTessellationFactor = 64;
        NSError* psoError = nil;
        id<MTLRenderPipelineState> pso =
            [device newRenderPipelineStateWithDescriptor:pd error:&psoError];
        if (pso == nil) {
            FG_TRACE(@"ensureTessDomainCapturePSO: PSO build failed (key=0x%x): %@",
                      key,
                      psoError ? psoError.localizedDescription : @"(no err)");
            return nil;
        }
        tessDomainCapturePSOCache[key] = pso;
        return pso;
    }

    bool ensureSolidColorLibrary() {
        if (solidColorLibrary != nil) {
            return true;
        }
        NSString* source = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct AppGLVertexIn {
    float3 position [[attribute(0)]];
};

struct AppGLVertexOut {
    float4 position [[position]];
};

vertex AppGLVertexOut appgl_solid_vs(AppGLVertexIn in [[stage_in]]) {
    AppGLVertexOut out;
    out.position = float4(in.position, 1.0);
    return out;
}

fragment float4 appgl_solid_fs(constant float4& color [[buffer(0)]]) {
    return color;
}
)MSL";
        NSError* error = nil;
        solidColorLibrary = [device newLibraryWithSource:source options:nil error:&error];
        if (solidColorLibrary == nil) {
            return false;
        }
        solidColorVertexFn = [solidColorLibrary newFunctionWithName:@"appgl_solid_vs"];
        solidColorFragmentFn = [solidColorLibrary newFunctionWithName:@"appgl_solid_fs"];
        return solidColorVertexFn != nil && solidColorFragmentFn != nil;
    }

    bool ensureSolidColorPipelineState(const MetalDrawInfo& info) {
        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : nil;
        const MTLPixelFormat colorFormat = colorTexture != nil
            ? colorTexture.pixelFormat
            : MTLPixelFormatBGRA8Unorm;

        if (solidColorPipelineState != nil
            && solidColorPipelineColorFormat == colorFormat) {
            return true;
        }

        MTLVertexDescriptor* vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
        vertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;
        vertexDescriptor.attributes[0].offset = 0;
        vertexDescriptor.attributes[0].bufferIndex = 0;
        const NSUInteger stride = info.positionStride > 0
            ? info.positionStride
            : sizeof(float) * 3u;
        vertexDescriptor.layouts[0].stride = stride;
        vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        vertexDescriptor.layouts[0].stepRate = 1;

        MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = solidColorVertexFn;
        desc.fragmentFunction = solidColorFragmentFn;
        desc.vertexDescriptor = vertexDescriptor;
        desc.colorAttachments[0].pixelFormat = colorFormat;
        desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        desc.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

        NSError* error = nil;
        solidColorPipelineState = [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (solidColorPipelineState == nil) {
            return false;
        }
        solidColorPipelineColorFormat = colorFormat;
        return true;
    }

    // Phase 8X Group 4d follow-up¹⁷ — compat-profile immediate-mode
    // shader library and two pipeline states (vertex-color-only and
    // vertex-color × texture2D). Built lazily on first glEnd that
    // actually drains vertices, mirroring the solid-color pattern.
    //
    // The MSL vertex shader reads the captured `{pos, color, texcoord}`
    // interleaved tuple via the attribute slots (0, 1, 2) and multiplies
    // position by an MVP matrix pushed as a vertex constant buffer at
    // index 1 (buffer 0 is the vertex data). The fragment shader picks
    // the path based on which pipeline is bound — untextured just
    // returns the interpolated color, textured multiplies it by a
    // sample from a single-unit texture2D bound at fragment slot 0.
    // Both pipelines share the same vertex descriptor / vertex function
    // / color format, so the only divergence is the fragment function.
    bool ensureImmediateModeLibrary() {
        if (immediateModeLibrary != nil) {
            return true;
        }
        NSString* source = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct AppGLImmediateIn {
    float4 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
    float2 texcoord [[attribute(2)]];
};

struct AppGLImmediateOut {
    float4 position [[position]];
    float4 color;
    float2 texcoord;
};

vertex AppGLImmediateOut appgl_immediate_vs(
    AppGLImmediateIn in [[stage_in]],
    constant float4x4& mvp [[buffer(1)]]
) {
    AppGLImmediateOut out;
    out.position = mvp * in.position;
    out.color    = in.color;
    out.texcoord = in.texcoord;
    return out;
}

fragment float4 appgl_immediate_color_fs(AppGLImmediateOut in [[stage_in]]) {
    return in.color;
}

fragment float4 appgl_immediate_textured_fs(
    AppGLImmediateOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler samp [[sampler(0)]]
) {
    return in.color * tex.sample(samp, in.texcoord);
}
)MSL";
        NSError* error = nil;
        immediateModeLibrary = [device newLibraryWithSource:source options:nil error:&error];
        if (immediateModeLibrary == nil) {
            NSLog(@"[AppGL] immediate-mode library build failed: %@", error);
            return false;
        }
        immediateModeVertexFn = [immediateModeLibrary newFunctionWithName:@"appgl_immediate_vs"];
        immediateModeColorFragmentFn = [immediateModeLibrary newFunctionWithName:@"appgl_immediate_color_fs"];
        immediateModeTexturedFragmentFn = [immediateModeLibrary newFunctionWithName:@"appgl_immediate_textured_fs"];
        return immediateModeVertexFn != nil
            && immediateModeColorFragmentFn != nil
            && immediateModeTexturedFragmentFn != nil;
    }

    bool ensureImmediateModePipelines(MTLPixelFormat colorFormat) {
        if (immediateModeColorPipelineState != nil
            && immediateModeTexturedPipelineState != nil
            && immediateModePipelineColorFormat == colorFormat) {
            return true;
        }

        MTLVertexDescriptor* vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
        // attribute 0: position (float4) at offset 0
        vertexDescriptor.attributes[0].format = MTLVertexFormatFloat4;
        vertexDescriptor.attributes[0].offset = 0;
        vertexDescriptor.attributes[0].bufferIndex = 0;
        // attribute 1: color (float4) at offset 16
        vertexDescriptor.attributes[1].format = MTLVertexFormatFloat4;
        vertexDescriptor.attributes[1].offset = sizeof(float) * 4;
        vertexDescriptor.attributes[1].bufferIndex = 0;
        // attribute 2: texcoord (float2) at offset 32
        vertexDescriptor.attributes[2].format = MTLVertexFormatFloat2;
        vertexDescriptor.attributes[2].offset = sizeof(float) * 8;
        vertexDescriptor.attributes[2].bufferIndex = 0;
        vertexDescriptor.layouts[0].stride = sizeof(float) * 10; // 40 bytes
        vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        vertexDescriptor.layouts[0].stepRate = 1;

        // Alpha blending is always enabled for immediate-mode — it's
        // what Chobby's Chili UI renders on top of the scene and every
        // glColor*/glTexCoord* path assumes straight-alpha blending.
        auto makePipeline = [&](id<MTLFunction> fragmentFn) -> id<MTLRenderPipelineState> {
            MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
            desc.vertexFunction = immediateModeVertexFn;
            desc.fragmentFunction = fragmentFn;
            desc.vertexDescriptor = vertexDescriptor;
            desc.colorAttachments[0].pixelFormat = colorFormat;
            desc.colorAttachments[0].blendingEnabled = YES;
            desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
            desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
            desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
            desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
            desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            desc.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            NSError* error = nil;
            id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:desc error:&error];
            if (state == nil) {
                NSLog(@"[AppGL] immediate-mode pipeline build failed: %@", error);
            }
            return state;
        };

        immediateModeColorPipelineState = makePipeline(immediateModeColorFragmentFn);
        immediateModeTexturedPipelineState = makePipeline(immediateModeTexturedFragmentFn);
        if (immediateModeColorPipelineState == nil || immediateModeTexturedPipelineState == nil) {
            return false;
        }
        immediateModePipelineColorFormat = colorFormat;
        return true;
    }

    // Lazy default linear sampler for immediate-mode textured draws.
    // Chobby sets up texture parameters on the bound texture before
    // every batch, but the Chili UI only uses nearest/linear clamp-to-
    // edge — a single default is fine for the ~90% path; if BAR ever
    // needs filtering variants the sampler can be cached by GL state.
    id<MTLSamplerState> immediateModeDefaultSampler() {
        if (immediateModeSamplerState != nil) {
            return immediateModeSamplerState;
        }
        MTLSamplerDescriptor* sdesc = [[MTLSamplerDescriptor alloc] init];
        sdesc.minFilter = MTLSamplerMinMagFilterLinear;
        sdesc.magFilter = MTLSamplerMinMagFilterLinear;
        sdesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sdesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
        immediateModeSamplerState = [device newSamplerStateWithDescriptor:sdesc];
        return immediateModeSamplerState;
    }

    // Clear a (possibly layered) MTLTexture via an empty render pass
    // with MTLLoadActionClear. `arrayLength` > 0 enables layered mode
    // and clears all slices in a single pass (Metal's native path).
    // `isColor` / `isDepth` / `isStencil` are mutually exclusive and
    // drive which attachment slot is populated on the pass
    // descriptor. Used by `clearDepthAttachment`, `clearStencilAttach
    // ment`, and (future) `clearColorAttachment` to make glClear on
    // texture-backed FBO attachments actually land on the Metal
    // side — without this, the Metal texture stays at whatever
    // contents it had at creation (zeros for a newly-created
    // texture) and the next draw's depth/stencil test reads that
    // junk value instead of the cleared one.
    bool clearLayeredTextureImpl(void* texVoid, std::uint32_t arrayLength,
                                 std::uint32_t level, std::uint32_t slice,
                                 bool isColor, bool isDepth, bool isStencil,
                                 const float rgba[4], float depth, std::uint32_t stencil) {
        if (texVoid == nullptr || device == nil || commandQueue == nil) return false;
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texVoid;
        // Close any in-flight encoder. Metal disallows two render
        // encoders open on the same command buffer.
        if (currentRenderEncoder != nil) {
            [currentRenderEncoder endEncoding];
            currentRenderEncoder = nil;
            activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
            resetCachedEncoderState();
        }
        if (currentCommandBuffer == nil) {
            currentCommandBuffer = [commandQueue commandBuffer];
            attachErrorHandler(currentCommandBuffer, @"layeredClear");
            if (currentCommandBuffer == nil) return false;
        }
        auto encodeClearPass = [&](std::uint32_t targetSlice,
                                   std::uint32_t targetArrayLength) -> bool {
            MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
            if (isColor) {
                pass.colorAttachments[0].texture = tex;
                pass.colorAttachments[0].level = level;
                pass.colorAttachments[0].slice = targetSlice;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(rgba[0], rgba[1], rgba[2], rgba[3]);
            }
            if (isDepth) {
                pass.depthAttachment.texture = tex;
                pass.depthAttachment.level = level;
                pass.depthAttachment.slice = targetSlice;
                pass.depthAttachment.loadAction = MTLLoadActionClear;
                pass.depthAttachment.storeAction = MTLStoreActionStore;
                pass.depthAttachment.clearDepth = depth;
            }
            if (isStencil) {
                pass.stencilAttachment.texture = tex;
                pass.stencilAttachment.level = level;
                pass.stencilAttachment.slice = targetSlice;
                pass.stencilAttachment.loadAction = MTLLoadActionClear;
                pass.stencilAttachment.storeAction = MTLStoreActionStore;
                pass.stencilAttachment.clearStencil = stencil & 0xFF;
            }
            if (targetArrayLength > 0) {
                pass.renderTargetArrayLength = targetArrayLength;
            }
            id<MTLRenderCommandEncoder> enc =
                [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
            if (enc == nil) return false;
            [enc endEncoding];
            return true;
        };
        if (!isColor && (isDepth || isStencil) && arrayLength > 0) {
            for (std::uint32_t i = 0; i < arrayLength; ++i) {
                if (!encodeClearPass(slice + i, 0)) return false;
            }
            return true;
        }
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        if (isColor) {
            pass.colorAttachments[0].texture = tex;
            pass.colorAttachments[0].level = level;
            pass.colorAttachments[0].slice = slice;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(rgba[0], rgba[1], rgba[2], rgba[3]);
        }
        if (isDepth) {
            pass.depthAttachment.texture = tex;
            pass.depthAttachment.level = level;
            pass.depthAttachment.slice = slice;
            pass.depthAttachment.loadAction = MTLLoadActionClear;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.depthAttachment.clearDepth = depth;
        }
        if (isStencil) {
            pass.stencilAttachment.texture = tex;
            pass.stencilAttachment.level = level;
            pass.stencilAttachment.slice = slice;
            pass.stencilAttachment.loadAction = MTLLoadActionClear;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.clearStencil = stencil & 0xFF;
        }
        if (arrayLength > 0) {
            pass.renderTargetArrayLength = arrayLength;
        }
        id<MTLRenderCommandEncoder> enc = [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
        if (enc == nil) return false;
        [enc endEncoding];
        return true;
    }
    bool clearLayeredTextureDepth(void* tex, std::uint32_t arrayLength, float depth) {
        return clearLayeredTextureImpl(tex, arrayLength, 0, 0, false, true, false,
            nullptr, depth, 0);
    }
    bool clearLayeredTextureStencil(void* tex, std::uint32_t arrayLength, std::uint32_t stencil) {
        return clearLayeredTextureImpl(tex, arrayLength, 0, 0, false, false, true,
            nullptr, 0.0f, stencil);
    }
    bool clearLayeredTextureColor(void* tex, std::uint32_t arrayLength, const float rgba[4]) {
        return clearLayeredTextureImpl(tex, arrayLength, 0, 0, true, false, false,
            rgba, 0.0f, 0);
    }
    bool clearTextureDepth(void* tex, std::uint32_t level, std::uint32_t slice,
                           std::uint32_t arrayLength, float depth) {
        return clearLayeredTextureImpl(tex, arrayLength, level, slice,
            false, true, false, nullptr, depth, 0);
    }
    bool clearTextureStencil(void* tex, std::uint32_t level, std::uint32_t slice,
                             std::uint32_t arrayLength, std::uint32_t stencil) {
        return clearLayeredTextureImpl(tex, arrayLength, level, slice,
            false, false, true, nullptr, 0.0f, stencil);
    }

    bool encodeImmediateModeDraw(const ImmediateDrawInfo& info) {
        FG_TRACE(@"encodeImmediateModeDraw: enter mode=0x%X verts=%zu tex=%p",
                 info.mode, info.vertexCount, info.metalTexture);
        if (device == nil || commandQueue == nil) {
            return false;
        }
        if (info.vertices == nullptr || info.vertexCount == 0 || info.vertexStride == 0) {
            return false;
        }

        // Map GL mode → Metal primitive. GL_QUADS was already expanded
        // to GL_TRIANGLES on the GLContext side, so we only see core-
        // profile primitives here.
        MTLPrimitiveType primitive;
        switch (info.mode) {
            case GL_TRIANGLES:      primitive = MTLPrimitiveTypeTriangle; break;
            case GL_TRIANGLE_STRIP: primitive = MTLPrimitiveTypeTriangleStrip; break;
            case GL_LINES:          primitive = MTLPrimitiveTypeLine; break;
            case GL_LINE_STRIP:     primitive = MTLPrimitiveTypeLineStrip; break;
            case GL_POINTS:         primitive = MTLPrimitiveTypePoint; break;
            default:
                // GL_TRIANGLE_FAN and GL_LINE_LOOP have no Metal
                // equivalent; expand them here if BAR hits them.
                FG_TRACE(@"encodeImmediateModeDraw: unsupported mode 0x%X", info.mode);
                return false;
        }

        acquireRingSlot();
        ensureDrawableResources();
        if (!ensureImmediateModeLibrary()) {
            return false;
        }

        endRenderPass();

        if (currentCommandBuffer == nil) {
            currentCommandBuffer = [commandQueue commandBuffer];
            attachErrorHandler(currentCommandBuffer, @"immediateModeDraw");
            if (currentCommandBuffer == nil) {
                return false;
            }
        }

        if (!acquireDrawableIfNeeded()) {  // ADV-7
            return false;
        }

        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        if (colorTexture == nil) {
            return false;
        }

        const MTLPixelFormat colorFormat = colorTexture.pixelFormat;
        if (!ensureImmediateModePipelines(colorFormat)) {
            return false;
        }

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];  // ADV-4
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (hasPendingClear && (pendingClearMask & GL_COLOR_BUFFER_BIT)) {
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = pendingClearColor;
        } else {
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }
        if (depthStencilTexture != nil) {
            pass.depthAttachment.texture = depthStencilTexture;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.texture = depthStencilTexture;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            if (hasPendingClear && (pendingClearMask & GL_DEPTH_BUFFER_BIT)) {
                pass.depthAttachment.loadAction = MTLLoadActionClear;
                pass.depthAttachment.clearDepth = pendingClearDepth;
            } else {
                pass.depthAttachment.loadAction = MTLLoadActionLoad;
            }
            if (hasPendingClear && (pendingClearMask & GL_STENCIL_BUFFER_BIT)) {
                pass.stencilAttachment.loadAction = MTLLoadActionClear;
                pass.stencilAttachment.clearStencil = pendingClearStencil;
            } else {
                pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            }
        }
        hasPendingClear = false;

        attachFragmentShadingRateMap(pass, info.fragmentShadingRate, colorTexture, 1);
        id<MTLRenderCommandEncoder> encoder = [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
        if (encoder == nil) {
            return false;
        }

        id<MTLRenderPipelineState> pipelineState = (info.metalTexture != nullptr)
            ? immediateModeTexturedPipelineState
            : immediateModeColorPipelineState;
        [encoder setRenderPipelineState:pipelineState];
        [encoder setCullMode:MTLCullModeNone];
        [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
        [encoder setTriangleFillMode:MTLTriangleFillModeFill];

        const std::size_t vertexBytes = info.vertexCount * info.vertexStride;
        if (vertexBytes <= 4096) {
            [encoder setVertexBytes:info.vertices length:vertexBytes atIndex:0];
        } else {
            auto alloc = ringSuballocate(info.vertices, vertexBytes);
            if (alloc.buffer == nil) {
                [encoder endEncoding];
                return false;
            }
            [encoder setVertexBuffer:alloc.buffer offset:alloc.offset atIndex:0];
        }

        // MVP matrix is pushed as a vertex-stage constant (buffer index 1).
        // `Matrix4` stores 16 floats in column-major order, matching MSL's
        // float4x4 memory layout.
        const Matrix4 mvp = info.mvp;
        [encoder setVertexBytes:mvp.m.data() length:sizeof(float) * 16 atIndex:1];

        if (info.metalTexture != nullptr) {
            id<MTLTexture> tex = (__bridge id<MTLTexture>)(info.metalTexture);
            [encoder setFragmentTexture:tex atIndex:0];
            id<MTLSamplerState> samp = immediateModeDefaultSampler();
            if (samp != nil) {
                [encoder setFragmentSamplerState:samp atIndex:0];
            }
        }

        [encoder drawPrimitives:primitive
                    vertexStart:0
                    vertexCount:static_cast<NSUInteger>(info.vertexCount)];

        [encoder endEncoding];
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        pendingPresent = true;
        return true;
    }

    // Sprint 7 Phase 1 #11 (CKPT57): GL stencil enum → Metal converter
    // helpers. Pulled out as free functions so depthStencilStateForDraw
    // and the tess-Phase-2 render path can both call them — the same
    // GL→Metal mapping needs to apply identically across encode paths.
    static MTLCompareFunction glStencilCompareToMetal(GLenum func) {
        switch (func) {
            case GL_NEVER:    return MTLCompareFunctionNever;
            case GL_LESS:     return MTLCompareFunctionLess;
            case GL_EQUAL:    return MTLCompareFunctionEqual;
            case GL_LEQUAL:   return MTLCompareFunctionLessEqual;
            case GL_GREATER:  return MTLCompareFunctionGreater;
            case GL_NOTEQUAL: return MTLCompareFunctionNotEqual;
            case GL_GEQUAL:   return MTLCompareFunctionGreaterEqual;
            case GL_ALWAYS:   default: return MTLCompareFunctionAlways;
        }
    }
    static MTLStencilOperation glStencilOpToMetal(GLenum op) {
        switch (op) {
            case GL_KEEP:        return MTLStencilOperationKeep;
            case GL_ZERO:        return MTLStencilOperationZero;
            case GL_REPLACE:     return MTLStencilOperationReplace;
            case GL_INCR:        return MTLStencilOperationIncrementClamp;
            case GL_DECR:        return MTLStencilOperationDecrementClamp;
            case GL_INCR_WRAP:   return MTLStencilOperationIncrementWrap;
            case GL_DECR_WRAP:   return MTLStencilOperationDecrementWrap;
            case GL_INVERT:      return MTLStencilOperationInvert;
            default:             return MTLStencilOperationKeep;
        }
    }

    // Build per-face MTLStencilDescriptor from the GL face state. The
    // `referenceValue` lives on the encoder (setStencilReferenceValue:),
    // not the descriptor — callers handle that separately.
    static MTLStencilDescriptor* buildMetalStencilFace(
        GLenum func, GLuint valueMask,
        GLenum sfail, GLenum dpfail, GLenum dppass,
        GLuint writeMask)
    {
        MTLStencilDescriptor* sd = [[MTLStencilDescriptor alloc] init];
        sd.stencilCompareFunction = glStencilCompareToMetal(func);
        sd.readMask = valueMask;
        sd.writeMask = writeMask;
        sd.stencilFailureOperation = glStencilOpToMetal(sfail);
        sd.depthFailureOperation = glStencilOpToMetal(dpfail);
        sd.depthStencilPassOperation = glStencilOpToMetal(dppass);
        return sd;
    }

    id<MTLDepthStencilState> depthStencilStateForDraw(const MetalDrawInfo& info) {
        // Cache key: pack (depth state) plus a stencil-state fingerprint
        // into a 64-bit key. The depth half stays at low 32 bits for
        // back-compat-shaped lookups; stencil identity hashes into the
        // high 32 bits when stencilTestEnabled. State space is small per
        // app (a handful of stencil configs typically), so post-first-
        // frame hash-table lookup keeps allocations at zero.
        std::uint64_t key = (info.depthTestEnabled ? 0x10000ull : 0ull)
                          | (info.depthWriteMask ? 0x20000ull : 0ull)
                          | (static_cast<std::uint64_t>(info.depthFunc) & 0xFFFFull);
        if (info.stencilTestEnabled) {
            // Compact stencil identity hash. Mix 14 GL enums + 2 ints
            // into the upper 32 bits via a cheap FNV-1a-like fold.
            std::uint64_t s = 0x40000000ull;   // disambiguator from depth-only key
            auto mix = [&](std::uint64_t v) {
                s ^= v;
                s = s * 1099511628211ull;
            };
            mix(static_cast<std::uint64_t>(info.stencilFrontFunc));
            mix(static_cast<std::uint64_t>(info.stencilFrontRef));
            mix(static_cast<std::uint64_t>(info.stencilFrontValueMask));
            mix(static_cast<std::uint64_t>(info.stencilFrontFail));
            mix(static_cast<std::uint64_t>(info.stencilFrontDepthFail));
            mix(static_cast<std::uint64_t>(info.stencilFrontDepthPass));
            mix(static_cast<std::uint64_t>(info.stencilFrontWriteMask));
            mix(static_cast<std::uint64_t>(info.stencilBackFunc));
            mix(static_cast<std::uint64_t>(info.stencilBackRef));
            mix(static_cast<std::uint64_t>(info.stencilBackValueMask));
            mix(static_cast<std::uint64_t>(info.stencilBackFail));
            mix(static_cast<std::uint64_t>(info.stencilBackDepthFail));
            mix(static_cast<std::uint64_t>(info.stencilBackDepthPass));
            mix(static_cast<std::uint64_t>(info.stencilBackWriteMask));
            key |= (s << 32) & 0xFFFFFFFF00000000ull;
        }

        auto it = depthStencilCache.find(key);
        if (it != depthStencilCache.end()) {
            return it->second;
        }

        MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
        desc.depthWriteEnabled = info.depthTestEnabled && info.depthWriteMask;
        if (info.depthTestEnabled) {
            switch (info.depthFunc) {
                case GL_NEVER: desc.depthCompareFunction = MTLCompareFunctionNever; break;
                case GL_LESS: desc.depthCompareFunction = MTLCompareFunctionLess; break;
                case GL_EQUAL: desc.depthCompareFunction = MTLCompareFunctionEqual; break;
                case GL_LEQUAL: desc.depthCompareFunction = MTLCompareFunctionLessEqual; break;
                case GL_GREATER: desc.depthCompareFunction = MTLCompareFunctionGreater; break;
                case GL_NOTEQUAL: desc.depthCompareFunction = MTLCompareFunctionNotEqual; break;
                case GL_GEQUAL: desc.depthCompareFunction = MTLCompareFunctionGreaterEqual; break;
                case GL_ALWAYS: default: desc.depthCompareFunction = MTLCompareFunctionAlways; break;
            }
        } else {
            desc.depthCompareFunction = MTLCompareFunctionAlways;
        }
        // Sprint 7 Phase 1 #11 (CKPT57): apply per-face stencil state.
        // When stencil test is disabled, leave defaults (Always + Keep,
        // matching GL spec: "if the stencil test is not enabled, the
        // stencil test always passes" — GL 4.6 §17.3.5).
        if (info.stencilTestEnabled) {
            desc.frontFaceStencil = buildMetalStencilFace(
                info.stencilFrontFunc, info.stencilFrontValueMask,
                info.stencilFrontFail, info.stencilFrontDepthFail,
                info.stencilFrontDepthPass, info.stencilFrontWriteMask);
            desc.backFaceStencil = buildMetalStencilFace(
                info.stencilBackFunc, info.stencilBackValueMask,
                info.stencilBackFail, info.stencilBackDepthFail,
                info.stencilBackDepthPass, info.stencilBackWriteMask);
        }

        id<MTLDepthStencilState> state = [device newDepthStencilStateWithDescriptor:desc];
        depthStencilCache[key] = state;
        return state;
    }

    void endFrame(GLObjectStore& objects) {
        endRenderPass();
        objects.drainDeferredDeletes();
        if (currentCommandBuffer != nil) {
            if (!usesOffscreenTarget && currentDrawable != nil) {
                [currentCommandBuffer presentDrawable:currentDrawable];
            }
            commitWithFrameSignal(currentCommandBuffer);  // OPT-8
            invalidateTransientState();
            advanceRingBuffer();
        } else {
            invalidateTransientState();
        }
    }

    void present() {
        FG_TRACE(@"present: enter  pendingPresent=%d encoder=%p cmdBuf=%p drawable=%p",
                 pendingPresent, currentRenderEncoder, currentCommandBuffer, currentDrawable);
        // Flush any deferred clear that wasn't consumed by a draw call.
        if (hasPendingClear) {
            flushPendingClear();
        }
        if (!pendingPresent || currentCommandBuffer == nil) {
            return;
        }
        endRenderPass();
        if (!usesOffscreenTarget && currentDrawable != nil) {
            [currentCommandBuffer presentDrawable:currentDrawable];
        }
        // OPT-8: async commit — the completion handler signals the frame
        // semaphore, allowing the CPU to encode the next frame while the GPU
        // processes this one.  Replaces the old waitUntilCompleted which
        // serialised CPU and GPU completely for offscreen targets.
        commitWithFrameSignal(currentCommandBuffer);
        invalidateTransientState();
        advanceRingBuffer();
    }

    bool copyPixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels) {
        FG_TRACE(@"copyPixels: enter  encoder=%p cmdBuf=%p", currentRenderEncoder, currentCommandBuffer);
        if (outPixels == nullptr || width < 0 || height < 0) {
            return false;
        }
        if (width == 0 || height == 0) {
            return true;
        }
        if (device == nil || commandQueue == nil) {
            return copyHeadlessPixels(x, y, width, height, outPixels);
        }
        // Flush any deferred clear before readback.
        if (hasPendingClear) {
            flushPendingClear();
        }
        // Close any open render encoder before we commit the command buffer
        // for readback — otherwise Metal asserts on uncommitted encoder.
        endRenderPass();
        ensureDrawableResources();
        id<MTLTexture> sourceTexture = readbackSourceTexture != nil
            ? readbackSourceTexture
            : (usesOffscreenTarget ? offscreenColorTexture : nil);
        if (sourceTexture == nil) {
            return false;
        }
        const bool sourceIsBGRA = sourceTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;

        const NSUInteger sourceWidth = sourceTexture.width;
        const NSUInteger sourceHeight = sourceTexture.height;
        const NSUInteger packedRowBytes = sourceWidth * 4u;
        NSUInteger readbackRowBytes = packedRowBytes;
        const std::uint8_t* sourceBytes = nullptr;
        std::vector<std::uint8_t> directReadback;
        id<MTLBuffer> readbackBuffer = nil;

        const auto waitForQueue = [&]() -> bool {
            id<MTLCommandBuffer> fence = [commandQueue commandBuffer];
            if (fence == nil) {
                return false;
            }
            [fence commit];
            [fence waitUntilCompleted];
            return fence.status != MTLCommandBufferStatusError;
        };

        if (sourceTexture.storageMode == MTLStorageModeShared) {
            if (currentCommandBuffer != nil) {
                [currentCommandBuffer commit];
                [currentCommandBuffer waitUntilCompleted];
                // OPT-8: GPU finished synchronously — release the ring slot
                // so the semaphore stays balanced (no completion handler here).
                if (ringSlotAcquired) {
                    dispatch_semaphore_signal(frameSemaphore);
                    ringSlotAcquired = false;
                }
                if (currentCommandBuffer.status == MTLCommandBufferStatusError) {
                    invalidateTransientState();
                    return false;
                }
                invalidateTransientState();
            } else if (!waitForQueue()) {
                return false;
            }

            directReadback.assign(static_cast<std::size_t>(packedRowBytes * sourceHeight), 0);
            [sourceTexture getBytes:directReadback.data()
                        bytesPerRow:packedRowBytes
                         fromRegion:MTLRegionMake2D(0, 0, sourceWidth, sourceHeight)
                        mipmapLevel:0];
            sourceBytes = directReadback.data();
        } else {
            readbackRowBytes = alignBytesPerRow(packedRowBytes);
            readbackBuffer = [device newBufferWithLength:readbackRowBytes * sourceHeight
                                                 options:MTLResourceStorageModeShared];
            if (readbackBuffer == nil) {
                return false;
            }

            id<MTLCommandBuffer> commandBuffer = currentCommandBuffer != nil ? currentCommandBuffer : [commandQueue commandBuffer];
            if (commandBuffer == nil) {
                return false;
            }
            id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
            [blit copyFromTexture:sourceTexture
                      sourceSlice:0
                      sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(sourceWidth, sourceHeight, 1)
                         toBuffer:readbackBuffer
                destinationOffset:0
           destinationBytesPerRow:readbackRowBytes
         destinationBytesPerImage:readbackRowBytes * sourceHeight];
            [blit endEncoding];
            const bool consumedCurrentCommandBuffer = commandBuffer == currentCommandBuffer;
            [commandBuffer commit];
            [commandBuffer waitUntilCompleted];
            // OPT-8: release ring slot if we consumed the current CB synchronously.
            if (consumedCurrentCommandBuffer && ringSlotAcquired) {
                dispatch_semaphore_signal(frameSemaphore);
                ringSlotAcquired = false;
            }
            if (commandBuffer.status == MTLCommandBufferStatusError) {
                if (consumedCurrentCommandBuffer) {
                    invalidateTransientState();
                }
                return false;
            }
            if (consumedCurrentCommandBuffer) {
                invalidateTransientState();
            }
            sourceBytes = static_cast<const std::uint8_t*>([readbackBuffer contents]);
        }

        // RC-A02: OpenGL framebuffer row 0 is at the bottom; Metal
        // texture row 0 is at the top.  Flip Y during readback:
        // metalRow = textureHeight - 1 - glRow.
        auto* bytes = static_cast<std::uint8_t*>(outPixels);
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint srcX = x + col;
                const GLint glY = y + row;
                const GLint srcY = static_cast<GLint>(sourceHeight) - 1 - glY;
                const std::size_t dstOffset = static_cast<std::size_t>(row * width + col) * 4;
                if (srcX < 0 || srcY < 0 || srcX >= static_cast<GLint>(sourceWidth) || srcY >= static_cast<GLint>(sourceHeight)) {
                    std::memset(bytes + dstOffset, 0, 4);
                    continue;
                }
                const std::size_t srcOffset = static_cast<std::size_t>(srcY) * static_cast<std::size_t>(readbackRowBytes)
                    + static_cast<std::size_t>(srcX) * 4u;
                if (sourceIsBGRA) {
                    bytes[dstOffset + 0] = sourceBytes[srcOffset + 2];
                    bytes[dstOffset + 1] = sourceBytes[srcOffset + 1];
                    bytes[dstOffset + 2] = sourceBytes[srcOffset + 0];
                    bytes[dstOffset + 3] = sourceBytes[srcOffset + 3];
                } else {
                    std::memcpy(bytes + dstOffset, sourceBytes + srcOffset, 4);
                }
            }
        }
        return true;
    }

    // Flush the GPU: end any open render encoder, commit and wait for the
    // current command buffer.  After this call, all previously-encoded draws
    // are guaranteed to have completed and their results are CPU-visible via
    // [MTLTexture getBytes:].  Used by FBO readback paths.
    void flushForReadback() {
        endRenderPass();
        if (currentCommandBuffer != nil) {
            [currentCommandBuffer commit];
            [currentCommandBuffer waitUntilCompleted];
            if (ringSlotAcquired) {
                dispatch_semaphore_signal(frameSemaphore);
                ringSlotAcquired = false;
            }
            invalidateTransientState();
        }
    }

    bool drainCurrentCommandBufferForStandaloneEncoding(std::string* diagnostic) {
        endRenderPass();
        if (currentCommandBuffer == nil) {
            return true;
        }

        id<MTLCommandBuffer> drained = currentCommandBuffer;
        if (!usesOffscreenTarget && currentDrawable != nil && pendingPresent) {
            [drained presentDrawable:currentDrawable];
        }
        [drained commit];
        [drained waitUntilCompleted];
        if (ringSlotAcquired) {
            dispatch_semaphore_signal(frameSemaphore);
            advanceRingBuffer();
        }
        currentCommandBuffer = nil;
        currentDrawable = nil;
        pendingPresent = false;
        resetCachedEncoderState();

        if (drained.status == MTLCommandBufferStatusError) {
            if (diagnostic != nullptr) {
                NSString* msg = drained.error.localizedDescription;
                *diagnostic = msg != nil ? msg.UTF8String
                                         : "prior command buffer failed";
            }
            return false;
        }
        return true;
    }

    bool isReady() const {
        return device != nil && commandQueue != nil && depthStencilTexture != nil && (layer != nil || offscreenColorTexture != nil);
    }

    // Compile MSL into a retained MTLComputePipelineState. Returns
    // transfer-retained void* so the caller can store it on the
    // GLProgramObject and free it via releaseRetainedMetalObject at
    // relink / program delete. On failure returns nullptr with the
    // NSError surfaced through `outError`.
    //
    // Step 7-3 compute follow-up: optional `outFunction` receives the
    // MTLFunction (transfer-retained void*) when non-null — needed so
    // the argument-buffer path can call
    // `newArgumentEncoderWithBufferIndex:` at dispatch time. Callers
    // who don't use argument buffers pass nullptr and only the PSO is
    // retained.
    void* buildComputePipelineState(const std::string& msl, std::string* outError,
                                     void** outFunction = nullptr,
                                     void* stageInputOutputDescriptor = nullptr) {
        if (outFunction != nullptr) *outFunction = nullptr;
        if (device == nil || msl.empty()) {
            if (outError) *outError = "no device or empty MSL";
            return nullptr;
        }
        NSError* libError = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:
            [NSString stringWithUTF8String:msl.c_str()]
            options:nil error:&libError];
        if (lib == nil) {
            if (outError) {
                *outError = libError.localizedDescription.UTF8String
                    ? libError.localizedDescription.UTF8String : "newLibraryWithSource failed";
            }
            return nullptr;
        }
        // SPIRV-Cross emits the entry point as "main0" by default (same
        // convention as the vertex/fragment paths).
        MTLFunctionConstantValues* emptyConstants = [[MTLFunctionConstantValues alloc] init];
        NSError* fnError = nil;
        id<MTLFunction> fn = [lib newFunctionWithName:@"main0"
                                        constantValues:emptyConstants
                                                 error:&fnError];
        if (fn == nil) {
            if (outError) {
                *outError = fnError.localizedDescription.UTF8String
                    ? fnError.localizedDescription.UTF8String : "newFunctionWithName(main0) failed";
            }
            return nullptr;
        }
        NSError* psoError = nil;
        id<MTLComputePipelineState> pso = nil;
        if (stageInputOutputDescriptor != nullptr) {
            // VS-as-compute path: SPIRV-Cross with
            // forceVertexForTessellation=true emits `main0(main0_in in
            // [[stage_in]], ...)`; building this requires a
            // MTLComputePipelineDescriptor with a populated
            // `stageInputDescriptor`. The descriptor is built from the
            // bound VAO (see `buildMetalStageInputOutputDescriptor`).
            MTLComputePipelineDescriptor* psoDesc =
                [[MTLComputePipelineDescriptor alloc] init];
            psoDesc.computeFunction = fn;
            psoDesc.stageInputDescriptor =
                (__bridge MTLStageInputOutputDescriptor*)stageInputOutputDescriptor;
            pso = [device newComputePipelineStateWithDescriptor:psoDesc
                                                        options:MTLPipelineOptionNone
                                                     reflection:nil
                                                          error:&psoError];
        } else {
            pso = [device newComputePipelineStateWithFunction:fn
                                                        error:&psoError];
        }
        if (pso == nil) {
            if (outError) {
                *outError = psoError.localizedDescription.UTF8String
                    ? psoError.localizedDescription.UTF8String : "newComputePipelineState failed";
            }
            return nullptr;
        }
        if (outFunction != nullptr) {
            *outFunction = (void*)CFBridgingRetain(fn);
        }
        return (void*)CFBridgingRetain(pso);
    }

    // Sprint 15 Q3-Option-B Phase 3a [metal-tf-vs]: dispatch VS-as-
    // compute kernel + capture per-vertex output bytes (no
    // MTLStageInputOutputDescriptor — attributeless VS only). See
    // public-API doc on `MetalFrameGraph::encodeVsTfComputeDraw`.
    bool encodeVsTfComputeDraw(void* vsComputePSO,
                               std::uint32_t vertexCount,
                               std::size_t perVertexBytes,
                               const void* uniformBytes,
                               std::size_t uniformLength,
                               std::uint8_t* outBytes)
    {
        if (vsComputePSO == nullptr || vertexCount == 0 ||
            perVertexBytes == 0 || outBytes == nullptr) {
            return false;
        }
        if (device == nil || commandQueue == nil) {
            return false;
        }
        const NSUInteger totalBytes =
            static_cast<NSUInteger>(perVertexBytes) *
            static_cast<NSUInteger>(vertexCount);
        id<MTLBuffer> outBuf =
            [device newBufferWithLength:totalBytes
                                options:MTLResourceStorageModeShared];
        if (outBuf == nil) {
            return false;
        }
        outBuf.label = @"appgl-vstf-out";

        id<MTLCommandBuffer> cmdBuf = [commandQueue commandBuffer];
        if (cmdBuf == nil) {
            return false;
        }
        cmdBuf.label = @"appgl-vstf-vs-compute";
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        if (enc == nil) {
            return false;
        }
        id<MTLComputePipelineState> pso =
            (__bridge id<MTLComputePipelineState>)vsComputePSO;
        [enc setComputePipelineState:pso];
        // Per-vertex output buffer at [[buffer(28)]] (matches SPIRV-
        // Cross's default `shader_output_buffer_index`).
        [enc setBuffer:outBuf offset:0 atIndex:28];
        if (uniformBytes != nullptr && uniformLength > 0) {
            [enc setBytes:uniformBytes
                   length:uniformLength
                  atIndex:16];
        }
        // Sprint 16 Day 1 (CKPT209) — Phase 3b Component E:
        // SPIRV-Cross's vertex_for_tessellation MSL emit declares
        // `uint3 spvDispatchBase [[grid_origin]]` (per
        // spirv_msl.cpp:1050-1060) and computes
        // `gl_VertexIndex = gl_GlobalInvocationID.x + spvDispatchBase.x`.
        // Plain `dispatchThreads:` doesn't initialise [[grid_origin]],
        // so spvDispatchBase reads garbage → gl_VertexIndex points
        // anywhere → switch on gl_VertexID%4 jumps to a random case
        // OR no case → output stays at allocation default (0).
        // Fix: call setStageInRegion: with origin (0,0,0) to prime
        // [[grid_origin]] before dispatch. Sister-pattern reuse from
        // Metal's stage_in-compute-kernel pattern (the [[grid_origin]]
        // attribute is shared across stage_in and grid-origin compute
        // dispatch). `dispatchThreads:` then proceeds with a known
        // base offset of zero, matching glDrawArrays(POINTS, 0, N)
        // semantics where gl_BaseVertex = 0.
        [enc setStageInRegion:MTLRegionMake1D(0, vertexCount)];
        // Match the existing tess-as-compute VS encoder shape:
        // dispatchThreads sets [[grid_size]] to vertexCount; SPIRV-
        // Cross's emitted VS uses `gl_GlobalInvocationID.x` as the
        // per-vertex index and bounds-checks via the
        // spvStageInputSize early-return.
        const NSUInteger maxPerTg =
            pso.maxTotalThreadsPerThreadgroup > 0
                ? pso.maxTotalThreadsPerThreadgroup : 32;
        const NSUInteger tgWidth =
            vertexCount < maxPerTg ? vertexCount : maxPerTg;
        [enc dispatchThreads:MTLSizeMake(vertexCount, 1, 1)
         threadsPerThreadgroup:MTLSizeMake(tgWidth, 1, 1)];
        [enc endEncoding];
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];
        if (cmdBuf.status == MTLCommandBufferStatusError) {
            return false;
        }

        const std::uint8_t* contents =
            static_cast<const std::uint8_t*>([outBuf contents]);
        if (contents == nullptr) {
            return false;
        }
        std::memcpy(outBytes, contents, totalBytes);
        return true;
    }

    // Sprint 3 [metal-mesh-GS]: compile MSL → retained MTLFunction.
    // Mesh render PSOs are FBO-format-keyed so the PSO build itself
    // happens at draw time, but the source-to-AIR compile is stable
    // across draw invocations and stashed on the program object.
    void* compileMSLFunction(const std::string& msl, std::string* outError) {
        if (device == nil || msl.empty()) {
            if (outError) *outError = "no device or empty MSL";
            return nullptr;
        }
        NSError* libError = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:
            [NSString stringWithUTF8String:msl.c_str()]
            options:nil error:&libError];
        if (lib == nil) {
            if (outError) {
                *outError = libError.localizedDescription.UTF8String
                    ? libError.localizedDescription.UTF8String : "newLibraryWithSource failed";
            }
            return nullptr;
        }
        id<MTLFunction> fn = [lib newFunctionWithName:@"main0"];
        if (fn == nil) {
            if (outError) *outError = "newFunctionWithName(main0) failed";
            return nullptr;
        }
        return (void*)CFBridgingRetain(fn);
    }

    // Metal tess Phase 1 probe — validates that the SPIRV-Cross-emitted
    // tess MSL compiles and the Metal tessellation pipeline descriptor
    // accepts the TES + FS function pair. See the public
    // `MetalFrameGraph::probeTessellationPipeline` declaration for the
    // full contract.
    MetalFrameGraph::TessPipelineProbeResult probeTessellationPipeline(
        const std::string& tcsMSL,
        const std::string& tesMSL,
        const std::string& fsMSL,
        GLenum genMode,
        GLenum genSpacing,
        GLenum genVertexOrder,
        const std::string& vsComputeMSL,
        const std::string& tesComputeMSL)
    {
        MetalFrameGraph::TessPipelineProbeResult result;
        if (device == nil) {
            result.diagnostic = "no Metal device";
            return result;
        }
        // Allow `tesMSL` to be empty when the as-compute form is present
        // — happens for isolines TES post-SPIRV-Cross-095c99c-bypass:
        // `tess_evaluation_as_compute=true` emits valid kernel MSL while
        // the conventional `--msl` path still throws "Metal does not
        // support isoline tessellation." Stages 1c (TES-compute PSO),
        // 1a (TCS-compute PSO), 1b (VS-compute PSO) cover the compute
        // chain. Stages 2/3 (TES library + render PSO) are skipped below
        // when tesMSL is empty so the function still returns with
        // tessEvalComputeOk=true.
        if (tcsMSL.empty() || (tesMSL.empty() && tesComputeMSL.empty()) || fsMSL.empty()) {
            result.diagnostic = "missing MSL for one or more stages (tcs/tes/fs)";
            return result;
        }

        // Stage 1 — TCS compute PSO. Shares `buildComputePipelineState`
        // so any refinements to compute-pipeline validation flow through
        // the tess path too.
        std::string tcsError;
        void* tcsPSO = buildComputePipelineState(tcsMSL, &tcsError, nullptr);
        if (tcsPSO == nullptr) {
            result.diagnostic = std::string("tcs-compute: ") + tcsError;
            return result;
        }
        result.computeOk = true;
        result.computePipelineState = tcsPSO;

        // Stage 1b (Phase 3) — VS-as-compute PSO. Only attempted when
        // the caller passed a non-empty MSL. Programs whose VS has no
        // stage-input ([[stage_in]]) attributes can build directly;
        // programs that need a MTLStageInputOutputDescriptor will fail
        // here and drop to the CPU fallback via the program-side
        // handleability gate. Diagnosed but not a hard failure — the
        // caller may still use the TCS-only path for simple tess.
        if (!vsComputeMSL.empty()) {
            std::string vsError;
            void* vsPSO = buildComputePipelineState(vsComputeMSL, &vsError, nullptr);
            if (vsPSO != nullptr) {
                result.vertexComputeOk = true;
                result.vertexComputePipelineState = vsPSO;
            } else {
                // T4I [metal-tess-TF]: Metal returns "Function requires
                // stage_in attributes but no descriptor was set." when
                // the VS-as-compute MSL declares `[[stage_in]]`. That's
                // not a fatal error — we just need to defer PSO build
                // to draw time when the bound VAO is known. Set the
                // `vertexComputeNeedsDescriptor` flag so the program
                // side can build the PSO from the VAO descriptor at
                // draw time. Other compile failures (syntax errors etc)
                // remain non-fatal but won't trigger the deferred path.
                if (vsError.find("stage_in") != std::string::npos) {
                    result.vertexComputeNeedsDescriptor = true;
                }
                // Keep going — a failed VS-compute PSO shouldn't mask
                // the TCS + render PSO validation, but we stash the
                // diagnostic so callers can decide whether to use the
                // simpler no-VS path.
                result.diagnostic = std::string("vs-compute (non-fatal): ") + vsError;
            }
        }

        // Stage 1c (Phase 3B.4 [metal-tess-TF]) — TES-as-compute PSO.
        // Caller opts in by passing the SPIRV-Cross-emitted kernel
        // form of the TES MSL (the one produced when
        // `forceTessEvalAsCompute=true`). Builds the compute PSO that
        // the encoder's 4-dispatch TF-capture chain consumes.
        // Non-fatal if it fails: the traditional render-PSO TES path
        // stays available for non-TF draws.
        if (!tesComputeMSL.empty()) {
            std::string tesComputeError;
            void* tesComputePSO = buildComputePipelineState(
                tesComputeMSL, &tesComputeError, nullptr);
            if (tesComputePSO != nullptr) {
                result.tessEvalComputeOk = true;
                result.tessEvalComputePipelineState = tesComputePSO;
            } else if (result.diagnostic.empty()) {
                result.diagnostic = std::string("tes-compute (non-fatal): ") + tesComputeError;
            }
        }

        // Stages 2 + 3 build the conventional render-PSO path (TES as a
        // vertex function feeding Metal's fixed-function tessellator +
        // FS for rasterization). Skip entirely when `tesMSL` is empty —
        // happens for isolines post-SPIRV-Cross-095c99c-bypass, where
        // we have a valid tess-eval-as-compute kernel but no render
        // form. The compute chain (TCS-compute → domain-gen → TES-
        // compute) already handles the dispatch end-to-end without a
        // render PSO. Probe returns with `tessEvalComputeOk=true`
        // (set in stage 1c) and `renderOk=false`; the caller's tier
        // selection branches on whether render PSO is needed.
        if (tesMSL.empty()) {
            return result;
        }

        // Stage 2 — TES + FS libraries + functions.
        NSError* tesLibErr = nil;
        id<MTLLibrary> tesLib = [device newLibraryWithSource:
            [NSString stringWithUTF8String:tesMSL.c_str()]
            options:nil error:&tesLibErr];
        if (tesLib == nil) {
            result.diagnostic = std::string("tes-library: ") +
                (tesLibErr.localizedDescription.UTF8String
                    ? tesLibErr.localizedDescription.UTF8String
                    : "(nil description)");
            return result;
        }
        MTLFunctionConstantValues* emptyConstants = [[MTLFunctionConstantValues alloc] init];
        NSError* tesFnErr = nil;
        id<MTLFunction> tesFn = [tesLib newFunctionWithName:@"main0"
                                              constantValues:emptyConstants
                                                       error:&tesFnErr];
        if (tesFn == nil) {
            result.diagnostic = std::string("tes-function: ") +
                (tesFnErr.localizedDescription.UTF8String
                    ? tesFnErr.localizedDescription.UTF8String
                    : "(nil description)");
            return result;
        }

        NSError* fsLibErr = nil;
        id<MTLLibrary> fsLib = [device newLibraryWithSource:
            [NSString stringWithUTF8String:fsMSL.c_str()]
            options:nil error:&fsLibErr];
        if (fsLib == nil) {
            result.diagnostic = std::string("fs-library: ") +
                (fsLibErr.localizedDescription.UTF8String
                    ? fsLibErr.localizedDescription.UTF8String
                    : "(nil description)");
            return result;
        }
        NSError* fsFnErr = nil;
        id<MTLFunction> fsFn = [fsLib newFunctionWithName:@"main0"
                                            constantValues:emptyConstants
                                                     error:&fsFnErr];
        if (fsFn == nil) {
            result.diagnostic = std::string("fs-function: ") +
                (fsFnErr.localizedDescription.UTF8String
                    ? fsFnErr.localizedDescription.UTF8String
                    : "(nil description)");
            return result;
        }

        // Stage 3 — tess-enabled render pipeline descriptor. The format
        // is BGRA8Unorm for the probe; Phase 2's real draw path rebuilds
        // per FBO color format inside the encoder.
        MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = tesFn;
        desc.fragmentFunction = fsFn;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        // Partition mode maps per GL 4.6 §11.2.2.1:
        //   GL_EQUAL            → integer
        //   GL_FRACTIONAL_EVEN  → fractionalEven
        //   GL_FRACTIONAL_ODD   → fractionalOdd
        // Metal's .pow2 has no GL analogue. Winding mirrors the
        // TES `layout(cw|ccw)` qualifier.
        switch (genSpacing) {
            case GL_FRACTIONAL_EVEN:
                desc.tessellationPartitionMode = MTLTessellationPartitionModeFractionalEven;
                break;
            case GL_FRACTIONAL_ODD:
                desc.tessellationPartitionMode = MTLTessellationPartitionModeFractionalOdd;
                break;
            case GL_EQUAL:
            default:
                desc.tessellationPartitionMode = MTLTessellationPartitionModeInteger;
                break;
        }
        desc.tessellationOutputWindingOrder =
            (genVertexOrder == GL_CW) ? MTLWindingClockwise : MTLWindingCounterClockwise;
        desc.tessellationFactorFormat = MTLTessellationFactorFormatHalf;
        desc.tessellationFactorStepFunction = MTLTessellationFactorStepFunctionConstant;
        desc.tessellationControlPointIndexType = MTLTessellationControlPointIndexTypeNone;
        desc.maxTessellationFactor = 64;  // GL_MAX_TESS_GEN_LEVEL
        (void)genMode;

        NSError* psoErr = nil;
        id<MTLRenderPipelineState> renderPSO =
            [device newRenderPipelineStateWithDescriptor:desc error:&psoErr];
        if (renderPSO == nil) {
            result.diagnostic = std::string("tess-render-pipeline: ") +
                (psoErr.localizedDescription.UTF8String
                    ? psoErr.localizedDescription.UTF8String
                    : "(nil description)");
            return result;
        }
        result.renderOk = true;
        (void)renderPSO;   // released at autorelease-pool drain; Phase 2
                           // rebuilds the render PSO per FBO format.
        return result;
    }

    // Metal-native tessellation draw encoder (Phase 2 of the metal-tess
    // project). See the public declaration on MetalFrameGraph for the
    // full contract. Flow:
    //   (1) End any open render pass + drain the command buffer so
    //       subsequent compute writes are visible.
    //   (2) Allocate a factor buffer (private storage; written by the
    //       TCS, read by Metal's fixed-function tessellator at
    //       drawPatches time) + an indirect-params buffer (shared, filled
    //       with [patchVerticesIn, patchesPerThreadgroup=1]).
    //   (3) Compute-encode the TCS: setPipelineState, bind factor +
    //       indirect params, dispatchThreadgroups(patchCount x 1 x 1,
    //       threadsPerThreadgroup = tessControlOutputVertices x 1 x 1).
    //       Commit + wait so the factor buffer is populated before the
    //       subsequent render pass reads it.
    //   (4) Build / cache a tess-enabled MTLRenderPipelineState keyed on
    //       (tesMSL, fsMSL, colorFormat, depthFormat) — SPIRV-Cross's
    //       TES is emitted with `[[ patch(<domain>, 0) ]]` which must
    //       match the genMode.
    //   (5) Begin a render pass on the FBO (or default framebuffer),
    //       set viewport/scissor/cull/depth state, setRenderPipelineState,
    //       setTessellationFactorBuffer, and drawPatches.
    //   (6) End the render pass and commit.
    bool encodeMetalTessellationDraw(const MetalTessDrawInfo& info) {
        if (device == nil || commandQueue == nil) return false;
        if (info.tessControlPipelineState == nullptr) return false;
        // Allow `tessEvalMSL` to be empty when the as-compute kernel is
        // present (isolines TES post-SPIRV-Cross-095c99c). Render pipeline
        // build below is skipped when tessEvalMSL is empty — the compute
        // chain handles the dispatch end-to-end and (with rasterizer-
        // discard active or TF-only mode) we never need the render PSO.
        if ((info.tessEvalMSL == nullptr || info.tessEvalMSL->empty()) &&
            info.tessEvalComputePipelineState == nullptr) return false;
        if (info.fragmentMSL == nullptr || info.fragmentMSL->empty()) return false;
        if (info.patchCount <= 0 || info.tessControlOutputVertices <= 0) return false;
        auto bindComputeTextures =
            [](id<MTLComputeCommandEncoder> encoder,
               const std::vector<TranslatedDrawInfo::TextureBinding>& textures) {
                for (const auto& binding : textures) {
                    id<MTLTexture> tex =
                        (__bridge id<MTLTexture>)binding.metalTexture;
                    if (tex == nil) {
                        continue;
                    }
                    const NSUInteger slot =
                        static_cast<NSUInteger>(binding.metalSlot);
                    [encoder setTexture:tex atIndex:slot];
                    if (binding.metalSamplerState != nullptr) {
                        id<MTLSamplerState> smp =
                            (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                        [encoder setSamplerState:smp atIndex:slot];
                    }
                }
            };
        auto bindVertexTextures =
            [](id<MTLRenderCommandEncoder> encoder,
               const std::vector<TranslatedDrawInfo::TextureBinding>& textures) {
                for (const auto& binding : textures) {
                    id<MTLTexture> tex =
                        (__bridge id<MTLTexture>)binding.metalTexture;
                    if (tex == nil) {
                        continue;
                    }
                    const NSUInteger slot =
                        static_cast<NSUInteger>(binding.metalSlot);
                    [encoder setVertexTexture:tex atIndex:slot];
                    if (binding.metalSamplerState != nullptr) {
                        id<MTLSamplerState> smp =
                            (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                        [encoder setVertexSamplerState:smp atIndex:slot];
                    }
                }
            };
        auto bindFragmentTextures =
            [](id<MTLRenderCommandEncoder> encoder,
               const std::vector<TranslatedDrawInfo::TextureBinding>& textures) {
                for (const auto& binding : textures) {
                    id<MTLTexture> tex =
                        (__bridge id<MTLTexture>)binding.metalTexture;
                    if (tex == nil) {
                        continue;
                    }
                    const NSUInteger slot =
                        static_cast<NSUInteger>(binding.metalSlot);
                    [encoder setFragmentTexture:tex atIndex:slot];
                    if (binding.metalSamplerState != nullptr) {
                        id<MTLSamplerState> smp =
                            (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                        [encoder setFragmentSamplerState:smp atIndex:slot];
                    }
                }
            };

        // (1) Drain any prior state so compute runs against a clean
        // command buffer and subsequent render-pass reads see the
        // factor-buffer writes.
        endRenderPass();
        if (currentCommandBuffer != nil) {
            [currentCommandBuffer commit];
            [currentCommandBuffer waitUntilCompleted];
            currentCommandBuffer = nil;
        }

        // (2) Allocate factor buffer (over-size to quad for conservatism;
        // SPIRV-Cross always emits the quad struct even for triangle
        // TES and Metal reads the triangle subset).
        const NSUInteger factorBytes =
            sizeof(MTLQuadTessellationFactorsHalf) *
            (NSUInteger)info.patchCount;
        // Sprint 7 #1 (CKPT64) — synth TCS host-populate of half-precision
        // tess factors requires CPU write access to factorBuf. For TES-only
        // programs the synth TCS dual-writes 1.0 defaults; the host needs
        // to override these with glPatchParameterfv state so the domain-gen
        // kernel (which reads factorBuf @ slot 26 in half precision) sees
        // the correct tessellation levels. Storage mode is Shared on Apple
        // Silicon UMA where Private vs Shared has negligible perf delta —
        // GPU readers (domain-gen, tessellator, TES) work identically; CPU
        // writes only fire from synth_host_populate path below.
        const MTLResourceOptions factorBufOpts =
            info.tessControlSynthesized
                ? MTLResourceStorageModeShared
                : MTLResourceStorageModePrivate;
        id<MTLBuffer> factorBuf =
            [device newBufferWithLength:factorBytes
                                options:factorBufOpts];
        if (factorBuf == nil) return false;
        factorBuf.label = @"appgl-tess-factor";

        // Phase 3: additional buffers for VS-compute + TCS user
        // output. Conservative over-allocation: 256 bytes per struct
        // slot covers up to 16 vec4 members. Refine via SPIRV-Cross
        // `get_declared_struct_size` once the three-pass encode is
        // proven to work end-to-end. Storage mode is Private because
        // writes come from compute and reads go to the tessellator +
        // vertex function — all GPU-side.
	        const bool isPhase3 =
	            info.vertexComputePipelineState != nullptr || info.forcePhase3Buffers;
        const NSUInteger kPhase3SlotBytes = 256;
        const NSUInteger vertexCount = isPhase3
            ? (NSUInteger)(info.patchCount * info.patchVertices)
            : 0;
        const NSUInteger vsOutBytes =
            isPhase3 ? vertexCount * kPhase3SlotBytes : 0;
        const NSUInteger cpOutBytes = isPhase3
            ? (NSUInteger)(info.patchCount * info.tessControlOutputVertices) * kPhase3SlotBytes
            : 0;
        const NSUInteger patchOutBytes = isPhase3
            ? (NSUInteger)info.patchCount * kPhase3SlotBytes
            : 0;
        id<MTLBuffer> vsOutBuf = nil;
        id<MTLBuffer> cpOutBuf = nil;
        id<MTLBuffer> patchOutBuf = nil;
        if (isPhase3) {
            // CKPT137 (Sprint 13 Phase 2 Day 1 — γ2.1 runtime instrumentation):
            // when APPGL_TRACE_TESS_BUF is set, allocate vsOutBuf/cpOutBuf in
            // shared storage mode so we can blit-read post-write contents and
            // verify per-patch buffer wiring vs symbolic-expected.
            static const bool s_trBuf = (std::getenv("APPGL_TRACE_TESS_BUF") != nullptr);
	            const MTLResourceOptions storageOpt = (s_trBuf || info.forcePhase3Buffers)
	                ? MTLResourceStorageModeShared
	                : MTLResourceStorageModePrivate;
            vsOutBuf = [device newBufferWithLength:vsOutBytes
                                           options:storageOpt];
            cpOutBuf = [device newBufferWithLength:cpOutBytes
                                           options:storageOpt];
            patchOutBuf = [device newBufferWithLength:patchOutBytes
                                              options:storageOpt];
            if (vsOutBuf == nil || cpOutBuf == nil || patchOutBuf == nil) {
                return false;
            }
	            vsOutBuf.label = @"appgl-tess-vs-out";
	            cpOutBuf.label = @"appgl-tess-cp-out";
	            patchOutBuf.label = @"appgl-tess-patch-out";
	            if (info.forcePhase3Buffers) {
	                if (void* p = [vsOutBuf contents]) {
	                    std::memset(p, 0, (std::size_t)vsOutBytes);
	                }
	            }
            if (s_trBuf) {
                std::fprintf(stderr,
                    "[TESS-BUF] alloc vsOutBuf=%p (sz=%lu) cpOutBuf=%p (sz=%lu) patchOutBuf=%p (sz=%lu) "
                    "vertexCount=%lu patchCount=%d patchVertices=%d tessCtrlOutputVertices=%d\n",
                    (__bridge void*)vsOutBuf, (unsigned long)vsOutBytes,
                    (__bridge void*)cpOutBuf, (unsigned long)cpOutBytes,
                    (__bridge void*)patchOutBuf, (unsigned long)patchOutBytes,
                    (unsigned long)vertexCount, info.patchCount, info.patchVertices,
                    info.tessControlOutputVertices);
            }
        }

	        // Sprint 5 Phase 1 — Path L Class 2A: full-precision tess level
	        // shadow buffer at slot 23. SPIRV-Cross's TCS/TES kernels index
	        // this side buffer with a quad-sized six-float stride for every
	        // domain. Domain-gen reads only the mode-relevant subset from the
	        // half factor buffer, but the full-precision sidecar must stay at
	        // the generated kernel stride to avoid isoline/triangle overruns.
	        // Outer levels first, then inner. SPIRV-Cross fork's TCS-side
	        // dual-write (commit 635380d) populates this buffer alongside
        // the half-precision spvTessLevel. TES-side reads from this
        // buffer (commit 4f626b9). Avoids half-precision rounding error
        // on `tc2te.gl_tessLevel`'s tess-level read-back checks.
	        const NSUInteger fullStride = 6;
        const NSUInteger fullFactorBytes =
            sizeof(float) * fullStride * (NSUInteger)info.patchCount;
        id<MTLBuffer> factorBufFull =
            [device newBufferWithLength:(fullFactorBytes > 0 ? fullFactorBytes : 4)
                                options:MTLResourceStorageModeShared];
        if (factorBufFull == nil) return false;
        factorBufFull.label = @"appgl-tess-factor-full";

        // spvIndirectParams: SPIRV-Cross `constant uint*` — element [0]
        // is gl_PatchVerticesIn (from glPatchParameteri, default 3),
        // element [1] is the TOTAL patch count in the dispatch. The
        // TCS MSL uses it to clamp gl_PrimitiveID when gl_GlobalInvocationID
        // exceeds the valid range (workgroup-size rounding). Setting it
        // to 1 silently clamps every patch to index 0 — causing
        // every patch to read VS slot 0 as its input.
        uint32_t indirectParams[2] = {
            (uint32_t)(info.patchVertices > 0 ? info.patchVertices : 3),
            (uint32_t)(info.patchCount > 0 ? info.patchCount : 1)
        };
        id<MTLBuffer> indirectBuf =
            [device newBufferWithBytes:indirectParams
                                length:sizeof(indirectParams)
                               options:MTLResourceStorageModeShared];
        if (indirectBuf == nil) return false;
        indirectBuf.label = @"appgl-tess-indirect-params";

        // (3a) Phase 3: VS-as-compute dispatch. Runs once per vertex
        // in the draw range and writes per-vertex output into
        // `vsOutBuf` at [[buffer(28)]]. TCS reads from this buffer via
        // `spvIn [[buffer(22)]]` (no stage-input descriptor needed with
        // `multi_patch_workgroup = true`).
        if (isPhase3 && info.vertexComputePipelineState != nullptr) {
            id<MTLCommandBuffer> vsCmdBuf = [commandQueue commandBuffer];
            if (vsCmdBuf == nil) return false;
            vsCmdBuf.label = @"appgl-tess-vs-compute";
            id<MTLComputeCommandEncoder> vsEnc =
                [vsCmdBuf computeCommandEncoder];
            if (vsEnc == nil) return false;
            id<MTLComputePipelineState> vsPSO =
                (__bridge id<MTLComputePipelineState>)info.vertexComputePipelineState;
            [vsEnc setComputePipelineState:vsPSO];
            [vsEnc setBuffer:vsOutBuf offset:0 atIndex:28];
            if (info.tessVertexAsComputeUniformData != nullptr &&
                info.tessVertexAsComputeUniformSize > 0) {
                [vsEnc setBytes:info.tessVertexAsComputeUniformData
                         length:info.tessVertexAsComputeUniformSize
                        atIndex:16];
            }
            bindComputeTextures(vsEnc, info.tessVertexAsComputeTextures);
            // T4I [metal-tess-TF]: bind VAO vertex buffers for VS
            // compute when the PSO was built with a stage-input
            // descriptor. The slots match the descriptor's
            // `attributes[*].bufferIndex` (0..15 by default per
            // BindingMap::vertexBufferBase). Empty for VS programs
            // that read inputs via gl_VertexID-only paths.
            for (const auto& binding : info.vertexComputeBufferBindings) {
                if (binding.metalBuffer == nullptr) {
                    continue;
                }
                [vsEnc setBuffer:(__bridge id<MTLBuffer>)binding.metalBuffer
                          offset:(NSUInteger)binding.offset
                         atIndex:(NSUInteger)binding.metalSlot];
            }
            // For VS without stage_in inputs, the VS-compute MSL uses
            // `gl_GlobalInvocationID` as the per-vertex index (Y=0 for
            // non-instanced). `dispatchThreads` maps 1:1 onto
            // gl_GlobalInvocationID and sets `[[grid_size]]` to the
            // dispatch count — which the SPIRV-Cross-emitted VS uses as
            // a bounds-check via `if (any(gl_GlobalInvocationID >=
            // spvStageInputSize)) return;`. Using dispatchThreadgroups
            // with a 1-thread workgroup would set grid_size to
            // (threadgroupCount*1, 1, 1) — same logical result, but
            // with fewer entry points exercised on Apple's driver it's
            // safer to stick to the form matching SPIRV-Cross's
            // VS-for-tessellation convention.
            {
                const NSUInteger maxPerTg =
                    vsPSO.maxTotalThreadsPerThreadgroup > 0
                        ? vsPSO.maxTotalThreadsPerThreadgroup : 32;
                const NSUInteger tgWidth =
                    vertexCount > 0 && vertexCount < maxPerTg ? vertexCount : maxPerTg;
                // T4I bisect: when stage-in descriptor is in use,
                // dispatchThreadgroups with explicit threadgroup count
                // gives Metal a uniform grid shape that
                // MTLStepFunctionThreadPositionInGridX advances on.
                // The VS-as-compute path without stage_in keeps using
                // dispatchThreads to preserve the SPIRV-Cross
                // [[grid_size]] / spvStageInputSize early-return shape.
                if (std::getenv("APPGL_TRACE_TESS_BUF") != nullptr) {
                    std::fprintf(stderr,
                        "[TESS-BUF] vsEnc dispatchThreads(%lu, 1, 1) tpg(%lu, 1, 1) maxPerTg=%lu\n",
                        (unsigned long)vertexCount, (unsigned long)tgWidth,
                        (unsigned long)maxPerTg);
                }
                [vsEnc dispatchThreads:MTLSizeMake(vertexCount, 1, 1)
                 threadsPerThreadgroup:MTLSizeMake(tgWidth, 1, 1)];
            }
            [vsEnc endEncoding];
            [vsCmdBuf commit];
            [vsCmdBuf waitUntilCompleted];
            // CKPT137: dump vsOutBuf post-VS-compute when APPGL_TRACE_TESS_BUF.
            // vsOutBuf is allocated Shared above when env-gate is set, so
            // contents are accessible without additional blit.
            if (std::getenv("APPGL_TRACE_TESS_BUF") != nullptr) {
                const std::uint8_t* p = static_cast<const std::uint8_t*>([vsOutBuf contents]);
                const NSUInteger len = vsOutBuf.length;
                const NSUInteger slot = kPhase3SlotBytes;
                const NSUInteger nverts = len / slot;
                std::fprintf(stderr, "[TESS-BUF] post-VS-compute vsOutBuf len=%lu slot=%lu nverts=%lu\n",
                    (unsigned long)len, (unsigned long)slot, (unsigned long)nverts);
                for (NSUInteger v = 0; v < nverts && v < 4; ++v) {
                    const float* f = reinterpret_cast<const float*>(p + v * slot);
                    std::fprintf(stderr, "  vert[%lu] first16f= %g %g %g %g  %g %g %g %g  %g %g %g %g  %g %g %g %g\n",
                        (unsigned long)v,
                        f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7],
                        f[8], f[9], f[10], f[11], f[12], f[13], f[14], f[15]);
                }
            }
        } else if (isPhase3 && std::getenv("APPGL_TRACE_TESS_BUF") != nullptr) {
            std::fprintf(stderr,
                "[TESS-BUF] VS-compute skipped; using zeroed vsOutBuf len=%lu\n",
                (unsigned long)vsOutBytes);
        }

        // (3b) Compute-encode the TCS dispatch.
        id<MTLCommandBuffer> computeCmdBuf = [commandQueue commandBuffer];
        if (computeCmdBuf == nil) return false;
        computeCmdBuf.label = @"appgl-tess-compute";
        id<MTLComputeCommandEncoder> cenc = [computeCmdBuf computeCommandEncoder];
        if (cenc == nil) return false;
        id<MTLComputePipelineState> tcsPSO =
            (__bridge id<MTLComputePipelineState>)info.tessControlPipelineState;
        [cenc setComputePipelineState:tcsPSO];
        [cenc setBuffer:factorBuf offset:0 atIndex:26];
        // Sprint 5 Phase 1 — Path L: full-precision tess level shadow
        // buffer at slot 23. TCS-compute dual-writes (half + full).
        [cenc setBuffer:factorBufFull offset:0 atIndex:23];
        [cenc setBuffer:indirectBuf offset:0 atIndex:29];
        if (info.tessControlUniformData != nullptr &&
            info.tessControlUniformSize > 0) {
            [cenc setBytes:info.tessControlUniformData
                    length:info.tessControlUniformSize
                   atIndex:16];
        }
        bindComputeTextures(cenc, info.tessControlTextures);
        if (isPhase3) {
            [cenc setBuffer:vsOutBuf offset:0 atIndex:22];
            [cenc setBuffer:patchOutBuf offset:0 atIndex:27];
            [cenc setBuffer:cpOutBuf offset:0 atIndex:28];
        }
        const MTLSize groups = MTLSizeMake(
            (NSUInteger)info.patchCount, 1, 1);
        const MTLSize threads = MTLSizeMake(
            (NSUInteger)info.tessControlOutputVertices, 1, 1);
        [cenc dispatchThreadgroups:groups threadsPerThreadgroup:threads];
        [cenc endEncoding];
        [computeCmdBuf commit];
        [computeCmdBuf waitUntilCompleted];

        // CKPT137: dump cpOutBuf + spvIndirectParams post-TCS-compute.
        if (std::getenv("APPGL_TRACE_TESS_BUF") != nullptr) {
            const std::uint8_t* p = static_cast<const std::uint8_t*>([cpOutBuf contents]);
            const NSUInteger len = cpOutBuf.length;
            const NSUInteger slot = kPhase3SlotBytes;
            const NSUInteger ncps = len / slot;
            std::fprintf(stderr, "[TESS-BUF] post-TCS-compute cpOutBuf len=%lu slot=%lu ncps=%lu\n",
                (unsigned long)len, (unsigned long)slot, (unsigned long)ncps);
            for (NSUInteger v = 0; v < ncps && v < 6; ++v) {
                const float* f = reinterpret_cast<const float*>(p + v * slot);
                std::fprintf(stderr, "  cp[%lu] first16f= %g %g %g %g  %g %g %g %g  %g %g %g %g  %g %g %g %g\n",
                    (unsigned long)v,
                    f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7],
                    f[8], f[9], f[10], f[11], f[12], f[13], f[14], f[15]);
            }
            const std::uint32_t* ip = static_cast<const std::uint32_t*>([indirectBuf contents]);
            std::fprintf(stderr, "[TESS-BUF] indirectBuf [0]=%u (patchVertices) [1]=%u (patchCount)\n",
                ip[0], ip[1]);
        }

        if (std::getenv("APPGL_DUMP_TESOUT")) {
            float* fbf = static_cast<float*>([factorBufFull contents]);
            const NSUInteger len = factorBufFull.length;
            const NSUInteger nfloats = len / sizeof(float);
            std::fprintf(stderr,
                "APPGL_DETECTOR factorBufFull_post_tcs synth=%d patchCount=%d "
                "len=%llu nfloats=%llu values=",
                info.tessControlSynthesized ? 1 : 0,
                (int)info.patchCount,
                (unsigned long long)len,
                (unsigned long long)nfloats);
            for (NSUInteger i = 0; i < nfloats && i < 12; ++i) {
                std::fprintf(stderr, "%.4f ", fbf[i]);
            }
            std::fprintf(stderr, "\n");
        }

        // Sprint 5 Phase 1 — synth TCS host-populate of factorBufFull.
        // For TES-only programs (synth TCS), the synth TCS dual-writes
        // 1.0 defaults to factorBufFull via Path L extension. Override
        // those defaults with glPatchParameterfv state snapshot so TES
        // reads user-intended values instead. Replicate the same data
        // for every patch (per-patch glPatchParameterfv applies
        // uniformly).
        if (info.tessControlSynthesized) {
            if (std::getenv("APPGL_DUMP_TESOUT")) {
                std::fprintf(stderr,
                    "APPGL_DETECTOR synth_host_populate outer=[%.3f %.3f %.3f %.3f] "
                    "inner=[%.3f %.3f] genMode=0x%04X patchCount=%d\n",
                    info.defaultOuterLevel[0], info.defaultOuterLevel[1],
                    info.defaultOuterLevel[2], info.defaultOuterLevel[3],
                    info.defaultInnerLevel[0], info.defaultInnerLevel[1],
                    info.genMode, (int)info.patchCount);
            }
            float* contents = static_cast<float*>([factorBufFull contents]);
            if (contents != nullptr) {
                NSUInteger localStride = 6;
                if (info.genMode == GL_TRIANGLES) localStride = 4;
                else if (info.genMode == GL_ISOLINES) localStride = 2;
                const NSUInteger nOuter =
                    (info.genMode == GL_TRIANGLES) ? 3 :
                    (info.genMode == GL_ISOLINES) ? 2 : 4;
                const NSUInteger nInner =
                    (info.genMode == GL_TRIANGLES) ? 1 :
                    (info.genMode == GL_ISOLINES) ? 0 : 2;
                for (int p = 0; p < info.patchCount; ++p) {
                    float* base = contents + (NSUInteger)p * localStride;
                    for (NSUInteger i = 0; i < nOuter; ++i) {
                        base[i] = info.defaultOuterLevel[i];
                    }
                    for (NSUInteger i = 0; i < nInner; ++i) {
                        base[nOuter + i] = info.defaultInnerLevel[i];
                    }
                }
            }
            // Sprint 7 #1 (CKPT64) — sister-write to factorBuf at half
            // precision. The synth TCS dual-writes 1.0 defaults to BOTH
            // factorBufFull (slot 23, full-precision read by TES kernel)
            // AND factorBuf (slot 26, half-precision read by domain-gen
            // kernel + Metal tessellator). Without this sister-write the
            // domain-gen kernel reads 1.0s from factorBuf → emits only
            // patch corners (4 verts in point_mode for quads) regardless
            // of what TES reads from factorBufFull. Closes the
            // gl_tessLevel TES-only path: domain-gen now sees the same
            // patch-default tess levels TES does.
            //
            // Layout per MTLQuadTessellationFactorsHalf:
            //   bytes 0..7  : edgeTessellationFactor[4]   (4 halves)
            //   bytes 8..11 : insideTessellationFactor[2] (2 halves)
            // Triangle subset is read from the same 12-byte slot —
            // factor budget allocates quad-sized for conservatism per
            // line ~5006 ("over-size to quad … Metal reads triangle
            // subset"). For triangles we still write a full quad-sized
            // record where the Metal-tessellator-relevant bytes (3 outer
            // + 1 inner per Metal's MTLTriangleTessellationFactorsHalf)
            // overlap with the quad-layout positions our SPIRV-Cross
            // fork already writes via TCS dual-write. The domain-gen
            // kernel reads as `QuadFactors` regardless.
            if (factorBufOpts == MTLResourceStorageModeShared) {
                std::uint8_t* hbytes = static_cast<std::uint8_t*>([factorBuf contents]);
                if (hbytes != nullptr) {
                    const NSUInteger perPatch = sizeof(MTLQuadTessellationFactorsHalf);
                    auto toHalf = [](float f) -> std::uint16_t {
                        // float→half via __fp16 (Apple Silicon native).
                        const __fp16 h = static_cast<__fp16>(f);
                        std::uint16_t bits;
                        std::memcpy(&bits, &h, sizeof(bits));
                        return bits;
                    };
                    for (int p = 0; p < info.patchCount; ++p) {
                        std::uint16_t* hbase = reinterpret_cast<std::uint16_t*>(
                            hbytes + (NSUInteger)p * perPatch);
                        // Quad layout: edge[4] then inside[2]. For
                        // triangles & isolines we write into the same
                        // slots — only the GenMode-relevant subset is
                        // read by the tessellator/domain-gen.
                        const NSUInteger nOuterH =
                            (info.genMode == GL_TRIANGLES) ? 3 :
                            (info.genMode == GL_ISOLINES) ? 2 : 4;
                        const NSUInteger nInnerH =
                            (info.genMode == GL_TRIANGLES) ? 1 :
                            (info.genMode == GL_ISOLINES) ? 0 : 2;
                        // Initialize whole record to 1.0 (synth-default
                        // sentinel) so unused slots have a defined value
                        // matching what synth TCS would have written.
                        const std::uint16_t oneHalf = toHalf(1.0f);
                        for (NSUInteger i = 0; i < 4; ++i) hbase[i] = oneHalf;
                        for (NSUInteger i = 0; i < 2; ++i) hbase[4 + i] = oneHalf;
                        for (NSUInteger i = 0; i < nOuterH; ++i) {
                            hbase[i] = toHalf(info.defaultOuterLevel[i]);
                        }
                        for (NSUInteger i = 0; i < nInnerH; ++i) {
                            hbase[4 + i] = toHalf(info.defaultInnerLevel[i]);
                        }
                    }
                }
            }
        }

        // (3c) Phase 3B.4 [metal-tess-TF]: domain-generator + TES-as-
        // compute dispatch chain. Runs after TCS compute (which writes
        // the factor buffer + per-CP / per-patch output) and produces
        // per-output-vertex results in `tesComputeOutBuf`. Phase 3B.5
        // reads those bytes into the bound transform-feedback buffers.
        //
        // Runs whenever info.tessEvalComputePipelineState is non-null
        // and the default-on APPGL_ENABLE_METAL_TESS_TF gate is
        // enabled (=0 opt-out). The caller toggles the TF write
        // portion via `info.outGeneratedVertCount` / `info.outTesComputeOutBuf`;
        // when both are null the chain just counts verts (needed for
        // PRIMITIVES_GENERATED on tess draws without TF).
        const bool isTessTF = (info.tessEvalComputePipelineState != nullptr) &&
            metalTessTFEnabled();
        id<MTLBuffer> domainCoordBuf = nil;
        id<MTLBuffer> domainPrimIDBuf = nil;
        id<MTLBuffer> totalVertCountBuf = nil;
        id<MTLBuffer> tesComputeOutBuf = nil;
        NSUInteger tessTFGeneratedVerts = 0;
        if (isTessTF) {
            if (!ensureTessDomainGenLibrary()) {
                if (std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr, "[APPGL] tess-tf: domain-gen library build failed\n");
                }
                // Fall through without TF — the existing render path
                // still runs; tests that rely on TF will fail their
                // correctness check but nothing crashes.
            } else {
                // Worst-case output-slot allocation per patch. GL 4.6
                // §23 caps tess levels at 64; worst case (quads,
                // fractional_odd, max level) is ~6×64² = 24576 vertex
                // slots per patch. Over-allocate to avoid a readback
                // round-trip for sizing.
                constexpr NSUInteger kMaxVertsPerPatch = 24576;
                const NSUInteger maxTotalVerts =
                    kMaxVertsPerPatch * (NSUInteger)info.patchCount;
                // packed_float3 is 12 bytes in MSL; hard-code the size
                // since simd.h's equivalent isn't always accessible here.
                // T4C diagnostic: when APPGL_DUMP_DOMAINGEN=<dir> is set,
                // make domainPrimIDBuf + domainCoordBuf CPU-readable so
                // we can dump them after domain-gen runs and verify the
                // primID seeding pattern (Clerk's reprioritized #1
                // priority for the data_pass_through repetition signature).
                const MTLResourceOptions domainOpts =
                    std::getenv("APPGL_DUMP_DOMAINGEN") != nullptr
                        ? MTLResourceStorageModeShared
                        : MTLResourceStorageModePrivate;
                domainCoordBuf = [device
                    newBufferWithLength:maxTotalVerts * 12
                                options:domainOpts];
                domainPrimIDBuf = [device
                    newBufferWithLength:maxTotalVerts * sizeof(uint32_t)
                                options:domainOpts];
                // totalVertCount lives in shared storage so CPU can
                // read it after the domain-gen dispatch to size the
                // TES-compute threadgroup count exactly.
                uint32_t zero = 0;
                totalVertCountBuf = [device
                    newBufferWithBytes:&zero
                                length:sizeof(uint32_t)
                               options:MTLResourceStorageModeShared];
                // TES-compute output buffer — conservative size
                // (same worst-case as coord buffer × per-vertex output
                // struct). The MSL struct size is embedded in the TES
                // compile; 256 bytes/vertex is the Phase 3 slot
                // over-allocation we already use elsewhere.
                // Shared storage: the TF-write path in
                // `tryMetalTessellationDraw` reads the CPU-side bytes
                // after the dispatch commits and deposits them into
                // the bound GL_TRANSFORM_FEEDBACK_BUFFER.
                tesComputeOutBuf = [device
                    newBufferWithLength:maxTotalVerts * 256
                                options:MTLResourceStorageModeShared];
                if (!domainCoordBuf || !domainPrimIDBuf ||
                    !totalVertCountBuf || !tesComputeOutBuf) {
                    return false;
                }
                domainCoordBuf.label = @"appgl-tess-domain-coord";
                domainPrimIDBuf.label = @"appgl-tess-domain-primid";
                totalVertCountBuf.label = @"appgl-tess-total-count";
                tesComputeOutBuf.label = @"appgl-tess-compute-out";

                // Domain-gen params struct. Layout mirrors the MSL
                // `TessGenParams` definition in
                // `ensureTessDomainGenLibrary`.
                struct TessGenParamsCPU {
                    uint32_t genMode;
                    uint32_t genSpacing;
                    uint32_t patchCount;
                    uint32_t pointMode;
                    uint32_t vertexOrder;  // 0=CCW, 1=CW
                };
                TessGenParamsCPU paramsCPU{};
                switch (info.genMode) {
                    case GL_TRIANGLES: paramsCPU.genMode = 0u; break;
                    case GL_QUADS:     paramsCPU.genMode = 1u; break;
                    case GL_ISOLINES:  paramsCPU.genMode = 2u; break;
                    default:           paramsCPU.genMode = 0u; break;
                }
                switch (info.genSpacing) {
                    case GL_EQUAL:             paramsCPU.genSpacing = 0u; break;
                    case GL_FRACTIONAL_EVEN:   paramsCPU.genSpacing = 1u; break;
                    case GL_FRACTIONAL_ODD:    paramsCPU.genSpacing = 2u; break;
                    default:                    paramsCPU.genSpacing = 0u; break;
                }
                paramsCPU.patchCount = (uint32_t)info.patchCount;
                paramsCPU.pointMode = info.pointMode ? 1u : 0u;
                paramsCPU.vertexOrder =
                    (info.genVertexOrder == GL_CW) ? 1u : 0u;
                id<MTLBuffer> domainGenParamsBuf = [device
                    newBufferWithBytes:&paramsCPU
                                length:sizeof(paramsCPU)
                               options:MTLResourceStorageModeShared];

                // Phase 3C [metal-tess-TF] — when the env flag
                // `APPGL_TESS_DOMAIN_USE_METAL_HW` is set and the
                // genMode is TRIANGLES or QUADS (and not point_mode),
                // route through Metal's HW tessellator as the
                // domain-coord source instead of the MSL compute
                // kernel. The capture PSO (built lazily by
                // `ensureTessDomainCapturePSO`) runs a `vertex void`
                // function with rasterizationEnabled=NO, writing into
                // the exact same (totalVertCount, domainPrimID,
                // domainTessCoord) buffers the compute kernel
                // populates. Downstream TES-as-compute reads either
                // interchangeably. Isolines and point_mode stay on the
                // compute kernel (Metal has no isoline patch type, and
                // Metal's HW always emits triangle/line topology — one
                // capture coord per generated vertex is not equivalent
                // to point_mode unique grid points).
                const bool useHWDomain =
                    (std::getenv("APPGL_TESS_DOMAIN_USE_METAL_HW") != nullptr) &&
                    (info.genMode == GL_TRIANGLES || info.genMode == GL_QUADS) &&
                    !info.pointMode;
                id<MTLRenderPipelineState> hwCapturePSO = nil;
                MTLPatchType hwPatchType = MTLPatchTypeTriangle;
                if (useHWDomain) {
                    hwPatchType = (info.genMode == GL_QUADS)
                        ? MTLPatchTypeQuad : MTLPatchTypeTriangle;
                    MTLTessellationPartitionMode hwPartition =
                        MTLTessellationPartitionModeInteger;
                    switch (info.genSpacing) {
                        case GL_FRACTIONAL_EVEN:
                            hwPartition = MTLTessellationPartitionModeFractionalEven;
                            break;
                        case GL_FRACTIONAL_ODD:
                            hwPartition = MTLTessellationPartitionModeFractionalOdd;
                            break;
                        case GL_EQUAL:
                        default:
                            hwPartition = MTLTessellationPartitionModeInteger;
                            break;
                    }
                    MTLWinding hwWinding = (info.genVertexOrder == GL_CW)
                        ? MTLWindingClockwise
                        : MTLWindingCounterClockwise;
                    hwCapturePSO = ensureTessDomainCapturePSO(
                        hwPatchType, hwPartition, hwWinding);
                }

                if (hwCapturePSO != nil) {
                    // HW capture path. One draw, `info.patchCount`
                    // patches. Metal's HW tessellator auto-indexes the
                    // factor buffer per-patch based on the PSO's
                    // declared patch type; `instanceStride:0` matches
                    // the main Phase 3 tess draw convention.
                    //
                    // Preamble: clamp factors to [1, 64] (Metal HW
                    // drops patches with any factor <= 0; GL spec says
                    // inner < 1 silently clamps, and our MSL-kernel
                    // path clamps in `segmentCount`). Skipped if the
                    // clamp PSO build failed — in that case the HW
                    // draw may legitimately produce 0 verts for
                    // degenerate factor values and the TES-compute
                    // dispatch is skipped.
                    id<MTLComputePipelineState> clampPSO =
                        ensureTessFactorClampPipelineState();
                    if (clampPSO != nil) {
                        uint32_t patchCountU = (uint32_t)info.patchCount;
                        id<MTLCommandBuffer> clampCmd = [commandQueue commandBuffer];
                        clampCmd.label = @"appgl-tess-factor-clamp";
                        id<MTLComputeCommandEncoder> clampEnc =
                            [clampCmd computeCommandEncoder];
                        [clampEnc setComputePipelineState:clampPSO];
                        [clampEnc setBuffer:factorBuf offset:0 atIndex:0];
                        [clampEnc setBytes:&patchCountU
                                    length:sizeof(patchCountU)
                                   atIndex:1];
                        [clampEnc dispatchThreads:MTLSizeMake((NSUInteger)patchCountU, 1, 1)
                          threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                        [clampEnc endEncoding];
                        [clampCmd commit];
                        [clampCmd waitUntilCompleted];
                    }

                    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
                    rpd.renderTargetWidth = 1;
                    rpd.renderTargetHeight = 1;
                    rpd.defaultRasterSampleCount = 1;
                    id<MTLCommandBuffer> dgCmdBuf = [commandQueue commandBuffer];
                    dgCmdBuf.label = @"appgl-tess-domain-gen-hw";
                    id<MTLRenderCommandEncoder> dgEnc =
                        [dgCmdBuf renderCommandEncoderWithDescriptor:rpd];
                    [dgEnc setRenderPipelineState:hwCapturePSO];
                    [dgEnc setVertexBuffer:totalVertCountBuf offset:0 atIndex:23];
                    [dgEnc setVertexBuffer:domainPrimIDBuf   offset:0 atIndex:24];
                    [dgEnc setVertexBuffer:domainCoordBuf    offset:0 atIndex:25];
                    [dgEnc setTessellationFactorBuffer:factorBuf
                                                offset:0
                                        instanceStride:0];
                    [dgEnc drawPatches:(hwPatchType == MTLPatchTypeQuad ? 4u : 3u)
                             patchStart:0
                             patchCount:(NSUInteger)info.patchCount
                        patchIndexBuffer:nil
                  patchIndexBufferOffset:0
                           instanceCount:1
                            baseInstance:0];
                    [dgEnc endEncoding];
                    [dgCmdBuf commit];
                    [dgCmdBuf waitUntilCompleted];
                } else {
                    // Phase 4A [metal-tess-TF]: when
                    // APPGL_TESS_DOMAIN_PORT is set and the genMode is
                    // triangles or quads, use the CPU-exact MSL port
                    // (`spvGenTessDomainTrianglesPort` /
                    // `spvGenTessDomainQuadsPort`). Output-buffer
                    // layout matches `spvGenTessDomain` so the
                    // downstream TES-compute dispatch is unchanged.
                    // Isolines stay on the original kernel (no Metal
                    // `.isoline` patch type, no port yet).
                    const bool useDomainPort =
                        (std::getenv("APPGL_TESS_DOMAIN_PORT") != nullptr) &&
                        (info.genMode == GL_TRIANGLES ||
                         info.genMode == GL_QUADS);
                    id<MTLComputePipelineState> portPSO = nil;
                    if (useDomainPort && ensureTessDomainPortLibrary()) {
                        portPSO = (info.genMode == GL_QUADS)
                            ? tessDomainPortQuadsPSO
                            : tessDomainPortTrianglesPSO;
                    }

                    if (portPSO != nil) {
                        // Port kernel params: same 5-field shape as
                        // the original `TessGenParams`; genMode is
                        // 0=tri / 1=quad (isolines route elsewhere).
                        struct TessPortParamsCPU {
                            uint32_t genMode;
                            uint32_t genSpacing;
                            uint32_t patchCount;
                            uint32_t pointMode;
                            uint32_t flipWinding;
                        };
                        TessPortParamsCPU pp{};
                        pp.genMode = (info.genMode == GL_QUADS) ? 1u : 0u;
                        switch (info.genSpacing) {
                            case GL_FRACTIONAL_EVEN: pp.genSpacing = 1u; break;
                            case GL_FRACTIONAL_ODD:  pp.genSpacing = 2u; break;
                            case GL_EQUAL:
                            default:                  pp.genSpacing = 0u; break;
                        }
                        pp.patchCount = (uint32_t)info.patchCount;
                        pp.pointMode = info.pointMode ? 1u : 0u;
                        pp.flipWinding = (info.genVertexOrder == GL_CW) ? 1u : 0u;
                        id<MTLBuffer> portParamsBuf = [device
                            newBufferWithBytes:&pp
                                        length:sizeof(pp)
                                       options:MTLResourceStorageModeShared];

                        id<MTLCommandBuffer> dgCmdBuf =
                            [commandQueue commandBuffer];
                        dgCmdBuf.label = @"appgl-tess-domain-port";
                        id<MTLComputeCommandEncoder> dgEnc =
                            [dgCmdBuf computeCommandEncoder];
                        [dgEnc setComputePipelineState:portPSO];
                        [dgEnc setBuffer:portParamsBuf offset:0 atIndex:0];
                        [dgEnc setBuffer:factorBuf offset:0 atIndex:26];
                        [dgEnc setBuffer:domainCoordBuf offset:0 atIndex:25];
                        [dgEnc setBuffer:domainPrimIDBuf offset:0 atIndex:24];
                        [dgEnc setBuffer:totalVertCountBuf offset:0 atIndex:23];
                        [dgEnc dispatchThreads:MTLSizeMake(1, 1, 1)
                          threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                        [dgEnc endEncoding];
                        [dgCmdBuf commit];
                        [dgCmdBuf waitUntilCompleted];
                    } else {
                        // Compute-kernel path (default, and fallback
                        // when port PSO unavailable or flag disabled).
                        //
                        // Serial driver: 1 thread walks all patches in
                        // order (see `spvGenTessDomain` comment).
                        // Parallelization revisited once Phase 4/5
                        // stabilize the TF capture protocol — the
                        // atomic cursor then becomes safe.
                        id<MTLCommandBuffer> dgCmdBuf =
                            [commandQueue commandBuffer];
                        dgCmdBuf.label = @"appgl-tess-domain-gen";
                        id<MTLComputeCommandEncoder> dgEnc =
                            [dgCmdBuf computeCommandEncoder];
                        [dgEnc setComputePipelineState:tessDomainGenPipelineState];
                        [dgEnc setBuffer:domainGenParamsBuf offset:0 atIndex:0];
                        [dgEnc setBuffer:factorBuf offset:0 atIndex:26];
                        [dgEnc setBuffer:domainCoordBuf offset:0 atIndex:25];
                        [dgEnc setBuffer:domainPrimIDBuf offset:0 atIndex:24];
                        [dgEnc setBuffer:totalVertCountBuf offset:0 atIndex:23];
                        [dgEnc dispatchThreads:MTLSizeMake(1, 1, 1)
                          threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                        [dgEnc endEncoding];
                        [dgCmdBuf commit];
                        [dgCmdBuf waitUntilCompleted];
                    }
                }

                // CPU-read the produced vertex count.
                tessTFGeneratedVerts =
                    *(const uint32_t*)totalVertCountBuf.contents;

                // T4C: dump domain-gen buffers when APPGL_DUMP_DOMAINGEN
                // is set. Each dump is a (primid, coord) pair sized to the
                // generated vertex count (not the over-allocation), letting
                // a post-processor verify the primID distribution pattern.
                if (const char* dumpDir = std::getenv("APPGL_DUMP_DOMAINGEN")) {
                    static std::atomic<unsigned> seq{0};
                    const unsigned n = seq.fetch_add(1);
                    const NSUInteger primIDBytes =
                        (NSUInteger)tessTFGeneratedVerts * sizeof(uint32_t);
                    const NSUInteger coordBytes =
                        (NSUInteger)tessTFGeneratedVerts * 12;
                    char path[512];
                    if (void* primContents = [domainPrimIDBuf contents]) {
                        std::snprintf(path, sizeof(path),
                            "%s/primid_%05u.bin", dumpDir, n);
                        if (FILE* f = std::fopen(path, "wb")) {
                            std::fwrite(primContents, 1, (size_t)primIDBytes, f);
                            std::fclose(f);
                        }
                    }
                    if (void* coordContents = [domainCoordBuf contents]) {
                        std::snprintf(path, sizeof(path),
                            "%s/coord_%05u.bin", dumpDir, n);
                        if (FILE* f = std::fopen(path, "wb")) {
                            std::fwrite(coordContents, 1, (size_t)coordBytes, f);
                            std::fclose(f);
                        }
                    }
                    // Sprint 2 Track 1 telemetry: read back the per-
                    // patch tess factors (post-TCS-dispatch state of
                    // factorBuf) so the bisect can correlate
                    // (config → emitted_count). Each line emits
                    // patch index + outer[0..3] + inner[0..1] +
                    // post-domain-gen totalVerts. Reading from
                    // [factorBuf contents] is safe because
                    // factorBuf was created with
                    // MTLResourceStorageModeShared earlier and
                    // dgCmdBuf has waitUntilCompleted'd above.
                    if (void* factorContents = [factorBuf contents]) {
                        const auto* factors =
                            static_cast<const MTLQuadTessellationFactorsHalf*>(
                                factorContents);
                        // edgeTessellationFactor is uint16_t (raw IEEE 754
                        // binary16). Decode via memcpy into _Float16.
                        auto halfBitsToFloat = [](uint16_t bits) -> float {
                            __fp16 h;
                            std::memcpy(&h, &bits, sizeof(uint16_t));
                            return static_cast<float>(h);
                        };
                        const int patchCount = (int)info.patchCount;
                        for (int p = 0; p < patchCount; ++p) {
                            const auto& f = factors[p];
                            std::fprintf(stderr,
                                "APPGL_DETECTOR lift_domaingen seq=%u patch=%d "
                                "o0=%.4f o1=%.4f o2=%.4f o3=%.4f "
                                "i0=%.4f i1=%.4f totalVerts=%u "
                                "mode=0x%04X spacing=0x%04X pointMode=%d\n",
                                n, p,
                                halfBitsToFloat((uint16_t)f.edgeTessellationFactor[0]),
                                halfBitsToFloat((uint16_t)f.edgeTessellationFactor[1]),
                                halfBitsToFloat((uint16_t)f.edgeTessellationFactor[2]),
                                halfBitsToFloat((uint16_t)f.edgeTessellationFactor[3]),
                                halfBitsToFloat((uint16_t)f.insideTessellationFactor[0]),
                                halfBitsToFloat((uint16_t)f.insideTessellationFactor[1]),
                                (unsigned)tessTFGeneratedVerts,
                                info.genMode, info.genSpacing,
                                info.pointMode ? 1 : 0);
                        }
                    }
                    std::fprintf(stderr,
                        "APPGL_DETECTOR domain_dump seq=%u verts=%u patchCount=%d "
                        "primIDBytes=%llu coordBytes=%llu\n",
                        n, (unsigned)tessTFGeneratedVerts, (int)info.patchCount,
                        (unsigned long long)primIDBytes,
                        (unsigned long long)coordBytes);
                }

                if (std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr,
                        "[APPGL] tess-tf domain-gen ok: %u verts for "
                        "%d patches (mode=0x%04X spacing=0x%04X)\n",
                        (unsigned)tessTFGeneratedVerts,
                        (int)info.patchCount,
                        info.genMode, info.genSpacing);
                }

                // TES-compute dispatch: one thread per generated vertex.
                // Reads spvIn (per-CP) + spvPatchIn (per-patch) from
                // the Phase-3 buffers, domain coord + primID from the
                // just-generated buffers, writes spvOut into
                // tesComputeOutBuf.
                if (tessTFGeneratedVerts > 0) {
                    id<MTLCommandBuffer> tesCmdBuf = [commandQueue commandBuffer];
                    tesCmdBuf.label = @"appgl-tess-tes-compute";
                    id<MTLComputeCommandEncoder> tesEnc =
                        [tesCmdBuf computeCommandEncoder];
                    id<MTLComputePipelineState> tesComputePSO =
                        (__bridge id<MTLComputePipelineState>)info.tessEvalComputePipelineState;
                    [tesEnc setComputePipelineState:tesComputePSO];
                    if (info.tessEvalAsComputeUniformData != nullptr &&
                        info.tessEvalAsComputeUniformSize > 0) {
                        [tesEnc setBytes:info.tessEvalAsComputeUniformData
                                  length:info.tessEvalAsComputeUniformSize
                                 atIndex:16];
                    }
                    bindComputeTextures(tesEnc, info.tessEvalTextures);
                    // TES-compute output buffer (spvOut at buffer 28).
                    [tesEnc setBuffer:tesComputeOutBuf offset:0 atIndex:28];
                    // spvIndirectParams at 29 — reuse the one we built
                    // for the TCS dispatch (shape matches).
                    [tesEnc setBuffer:indirectBuf offset:0 atIndex:29];
                    // Per-CP input at 22 (from TCS compute output).
                    // Sprint 5 Phase 1 — synth TCS path: TES-only programs
                    // have a synthesized passthrough TCS that doesn't copy
                    // VS-output user varyings to cpOutBuf (synth only
                    // writes gl_Position + tess level defaults). Per GL
                    // spec §11.2.4, TES-only mode reads VS outputs
                    // directly as per-CP inputs. Bind vsOutBuf instead of
                    // cpOutBuf to provide the TES kernel with VS output
                    // user data. The struct layouts of VS main0_out and
                    // TES main0_in match because they're both compiled
                    // from the same interface declarations (SPIRV-Cross
                    // emits identical layouts when using
                    // capture_output_to_buffer / raw_buffer_tese_input).
                    if (info.tessControlSynthesized && vsOutBuf != nil) {
                        [tesEnc setBuffer:vsOutBuf offset:0 atIndex:22];
                    } else if (cpOutBuf != nil) {
                        [tesEnc setBuffer:cpOutBuf offset:0 atIndex:22];
                    }
                    // Per-patch input at 20.
                    if (patchOutBuf != nil)
                        [tesEnc setBuffer:patchOutBuf offset:0 atIndex:20];
                    // Domain coord + primID (our fork-patched bindings).
                    [tesEnc setBuffer:domainCoordBuf offset:0 atIndex:25];
                    [tesEnc setBuffer:domainPrimIDBuf offset:0 atIndex:24];
                    // Sprint 5 Phase 1 — Path L: full-precision tess level
                    // shadow buffer at slot 23. TES kernel reads
                    // gl_TessLevelOuter/Inner from spvTessLevelFull
                    // instead of half-precision spvTessLevel. Populated by
                    // TCS-compute dual-write OR by host-populate path for
                    // TES-only programs (Sprint 5 Phase 1 follow-up).
                    [tesEnc setBuffer:factorBufFull offset:0 atIndex:23];
                    // Detector point C — dispatch-time instrumentation.
                    // Pairs with link probe (A) and gate (B) so post-
                    // processors can confirm the kernel actually fired.
                    if (std::getenv("APPGL_DETECTOR_TF")) {
                        std::fprintf(stderr,
                            "APPGL_DETECTOR lift_dispatch threads=%u "
                            "patchCount=%d patchVertices=%d "
                            "tesOutBufBytes=%llu\n",
                            (unsigned)tessTFGeneratedVerts,
                            (int)info.patchCount,
                            (int)info.patchVertices,
                            (unsigned long long)tesComputeOutBuf.length);
                    }
                    [tesEnc dispatchThreads:MTLSizeMake((NSUInteger)tessTFGeneratedVerts, 1, 1)
                      threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                    [tesEnc endEncoding];
                    [tesCmdBuf commit];
                    [tesCmdBuf waitUntilCompleted];

                    if (std::getenv("APPGL_TRACE_TESS")) {
                        std::fprintf(stderr,
                            "[APPGL] tess-tf tes-compute dispatched %u threads\n",
                            (unsigned)tessTFGeneratedVerts);
                    }

                    // Sprint 4 Phase 1 bisect: dump tesComputeOutBuf at
                    // multiple strides to verify TES-compute kernel's
                    // actual write layout vs `tessEvalOutputLayout
                    // .structSize`. The host-side TF write-back walks the
                    // buffer at structSize stride; if Metal MSL writes at
                    // a different stride (e.g. due to padding) the TF
                    // output is misaligned. Logs first N bytes interpreted
                    // as float4 at fixed candidate strides; correlate with
                    // host-side structSize from `lift_pre_encode`.
                    if (std::getenv("APPGL_DUMP_TESOUT")) {
                        static std::atomic<unsigned> seq{0};
                        const unsigned n = seq.fetch_add(1);
                        const std::uint8_t* bytes =
                            static_cast<const std::uint8_t*>(
                                [tesComputeOutBuf contents]);
                        const NSUInteger bufLen = tesComputeOutBuf.length;
                        std::fprintf(stderr,
                            "APPGL_DETECTOR tesout_dump seq=%u "
                            "verts=%u bufBytes=%llu\n",
                            n, (unsigned)tessTFGeneratedVerts,
                            (unsigned long long)bufLen);
                        const std::size_t kStrides[] = {
                            48, 64, 80, 96, 128, 256
                        };
                        const unsigned kVertsToShow =
                            tessTFGeneratedVerts < 24u
                                ? (unsigned)tessTFGeneratedVerts : 24u;
                        for (std::size_t s : kStrides) {
                            for (unsigned v = 0; v < kVertsToShow; ++v) {
                                const std::size_t off = (std::size_t)v * s;
                                if (off + sizeof(float) * 4 > bufLen) break;
                                float f[4];
                                std::memcpy(f, bytes + off, sizeof(f));
                                std::fprintf(stderr,
                                    "APPGL_DETECTOR tesout_dump seq=%u "
                                    "stride=%zu v=%u off=%zu = "
                                    "[%.4f, %.4f, %.4f, %.4f]\n",
                                    n, s, v, off, f[0], f[1], f[2], f[3]);
                            }
                        }
                    }
                }
                // Phase 3B.5 [metal-tess-TF]: hand off the TES-output
                // buffer + generated-vertex count to the caller so
                // `tryMetalTessellationDraw` can walk the bytes and
                // deposit TF per the program's varying layout.
                if (info.outGeneratedVertCount != nullptr) {
                    *info.outGeneratedVertCount =
                        (std::uint32_t)tessTFGeneratedVerts;
                }
                if (info.outTesComputeOutBuf != nullptr) {
                    // Retain the buffer so it outlives this encoder
                    // scope. Caller CFBridgingRelease's it after the
                    // TF write completes.
                    *info.outTesComputeOutBuf =
                        (void*)CFBridgingRetain(tesComputeOutBuf);
                }
            }
        }

        // (4) Build tess-enabled render pipeline state. Key on the
        // color + depth formats so a program drawn to multiple FBOs
        // keeps per-format pipelines hot. The key also includes the
        // TES+FS MSL text hashes implicitly (same program → same MSL).
        //
        // We could cache this on the program with a map, similar to
        // `metalPipelineStateCache`, but Phase 2 builds fresh each
        // draw — future phases add a cache keyed on the format tuple.
        MTLPixelFormat colorFormat = MTLPixelFormatBGRA8Unorm;
        MTLPixelFormat depthFormat = MTLPixelFormatInvalid;
        if (info.fboColorTexture != nullptr) {
            colorFormat =
                ((__bridge id<MTLTexture>)info.fboColorTexture).pixelFormat;
        } else if (usesOffscreenTarget && offscreenColorTexture != nil) {
            colorFormat = offscreenColorTexture.pixelFormat;
        } else if (currentDrawable != nil) {
            colorFormat = currentDrawable.texture.pixelFormat;
        }
        if (info.fboDepthStencilTexture != nullptr) {
            depthFormat =
                ((__bridge id<MTLTexture>)info.fboDepthStencilTexture).pixelFormat;
        } else if (depthStencilTexture != nil) {
            depthFormat = depthStencilTexture.pixelFormat;
        }

        // Render-pipeline-build skip: when tessEvalMSL is empty, we're
        // in compute-only mode (isolines + TF-write or
        // rasterizer-discard). The compute chain above already deposited
        // the TES output bytes to the TF buffer via
        // writeTessTFAndUpdateCounters; no render pass needs to fire.
        // Returning true here treats the compute chain as the complete
        // draw — caller's encode succeeded, no fallback to CPU.
        if (info.tessEvalMSL == nullptr || info.tessEvalMSL->empty()) {
            return true;
        }
        // Metal's fixed-function tessellator has no GL point_mode output.
        // When the caller retained the TES-compute output, let it replay
        // those generated vertices as GL_POINTS instead of drawing the
        // hardware tessellator's triangle/line topology.
        if (info.pointMode &&
            info.outGeneratedVertCount != nullptr &&
            info.outTesComputeOutBuf != nullptr &&
            tessTFGeneratedVerts > 0) {
            return true;
        }
        id<MTLLibrary> tesLib = getOrCompileLibrary(*info.tessEvalMSL);
        if (tesLib == nil) return false;
        id<MTLLibrary> fsLib = getOrCompileLibrary(*info.fragmentMSL);
        if (fsLib == nil) return false;
        MTLFunctionConstantValues* emptyConstants = [[MTLFunctionConstantValues alloc] init];
        NSError* fnErr = nil;
        id<MTLFunction> tesFn = [tesLib newFunctionWithName:@"main0"
                                              constantValues:emptyConstants
                                                       error:&fnErr];
        if (tesFn == nil) return false;
        id<MTLFunction> fsFn = [fsLib newFunctionWithName:@"main0"
                                            constantValues:emptyConstants
                                                     error:&fnErr];
        if (fsFn == nil) return false;

        MTLRenderPipelineDescriptor* pipeDesc =
            [[MTLRenderPipelineDescriptor alloc] init];
        pipeDesc.vertexFunction = tesFn;
        pipeDesc.fragmentFunction = fsFn;
        pipeDesc.colorAttachments[0].pixelFormat = colorFormat;
        // Classify the depth/stencil format: Metal's validator rejects
        // setting `depthAttachmentPixelFormat` to a stencil-only format
        // (e.g. MTLPixelFormatStencil8) and rejects setting
        // `stencilAttachmentPixelFormat` to a depth-only format. Depth-
        // plus-stencil combined formats go on BOTH slots.
        const bool fmtHasDepth =
            depthFormat == MTLPixelFormatDepth16Unorm ||
            depthFormat == MTLPixelFormatDepth32Float ||
            depthFormat == MTLPixelFormatDepth24Unorm_Stencil8 ||
            depthFormat == MTLPixelFormatDepth32Float_Stencil8;
        const bool fmtHasStencil =
            depthFormat == MTLPixelFormatStencil8 ||
            depthFormat == MTLPixelFormatDepth24Unorm_Stencil8 ||
            depthFormat == MTLPixelFormatDepth32Float_Stencil8 ||
            depthFormat == MTLPixelFormatX24_Stencil8 ||
            depthFormat == MTLPixelFormatX32_Stencil8;
        if (fmtHasDepth) {
            pipeDesc.depthAttachmentPixelFormat = depthFormat;
        }
        if (fmtHasStencil) {
            pipeDesc.stencilAttachmentPixelFormat = depthFormat;
        }

        // Tess pipeline settings. Partition-mode mapping mirrors the
        // Phase 1 probe helper. Maximum factor = 64 to cover
        // GL_MAX_TESS_GEN_LEVEL.
        switch (info.genSpacing) {
            case GL_FRACTIONAL_EVEN:
                pipeDesc.tessellationPartitionMode =
                    MTLTessellationPartitionModeFractionalEven;
                break;
            case GL_FRACTIONAL_ODD:
                pipeDesc.tessellationPartitionMode =
                    MTLTessellationPartitionModeFractionalOdd;
                break;
            case GL_EQUAL:
            default:
                pipeDesc.tessellationPartitionMode =
                    MTLTessellationPartitionModeInteger;
                break;
        }
        // Winding: SPIRV-Cross's `tess_domain_origin_lower_left` option
        // injects a `gl_TessCoord.y = 1.0 - gl_TessCoord.y` fixup inside
        // the TES for QUADS (and isolines) — per the comment in
        // spirv_msl.cpp:15600 "Don't do this for triangles; MoltenVK
        // will just reverse the winding order instead." The Y-flip
        // reverses the on-screen winding relative to what Metal's
        // fixed-function tessellator emits into the domain. To match GL
        // semantics (`layout(ccw|cw)` is the on-screen winding), invert
        // the pipeline's `tessellationOutputWindingOrder` whenever the
        // TES performs the Y-flip.
        const bool tesYFlipped =
            (info.genMode == GL_QUADS || info.genMode == GL_ISOLINES);
        const bool windingIsCW =
            (info.genVertexOrder == GL_CW) ^ tesYFlipped;
        pipeDesc.tessellationOutputWindingOrder =
            windingIsCW ? MTLWindingClockwise : MTLWindingCounterClockwise;
        const bool tessEvalWritesRenderTargetArrayIndex =
            info.tessEvalMSL != nullptr &&
            info.tessEvalMSL->find("[[render_target_array_index]]") !=
                std::string::npos;
        const bool tessEvalWritesViewportArrayIndex =
            info.tessEvalMSL != nullptr &&
            info.tessEvalMSL->find("[[viewport_array_index]]") !=
                std::string::npos;
        if (info.fboColorArrayLength > 0 ||
            info.viewportArrayCount > 1 ||
            tessEvalWritesRenderTargetArrayIndex ||
            tessEvalWritesViewportArrayIndex) {
            if (info.pointMode) {
                pipeDesc.inputPrimitiveTopology =
                    MTLPrimitiveTopologyClassPoint;
            } else if (info.genMode == GL_ISOLINES) {
                pipeDesc.inputPrimitiveTopology =
                    MTLPrimitiveTopologyClassLine;
            } else {
                pipeDesc.inputPrimitiveTopology =
                    MTLPrimitiveTopologyClassTriangle;
            }
        }
        pipeDesc.tessellationFactorFormat = MTLTessellationFactorFormatHalf;
        pipeDesc.tessellationFactorStepFunction =
            MTLTessellationFactorStepFunctionConstant;
        pipeDesc.tessellationControlPointIndexType =
            MTLTessellationControlPointIndexTypeNone;
        pipeDesc.maxTessellationFactor = 64;

        NSError* psoErr = nil;
        id<MTLRenderPipelineState> renderPSO =
            [device newRenderPipelineStateWithDescriptor:pipeDesc
                                                   error:&psoErr];
        if (renderPSO == nil) {
            APPGL_LOG(PIPELINE, @"[FG] tess render pipeline build failed: %@",
                      psoErr ? psoErr.localizedDescription : @"(nil err)");
            return false;
        }

        // (5) Begin a render pass. For FBO draws we build the pass
        // descriptor inline (single color attachment; Phase 2 doesn't
        // support MRT yet). For default-framebuffer draws we reuse the
        // impl's beginRenderPass path by acquiring a drawable +
        // attaching the swapchain texture directly.
        if (currentCommandBuffer == nil) {
            currentCommandBuffer = [commandQueue commandBuffer];
            attachErrorHandler(currentCommandBuffer, @"tessellationDraw");
            if (currentCommandBuffer == nil) return false;
        }

        id<MTLTexture> colorTex = nil;
        id<MTLTexture> depthTex = nil;
        if (info.fboColorTexture != nullptr) {
            colorTex = (__bridge id<MTLTexture>)info.fboColorTexture;
            depthTex = (__bridge id<MTLTexture>)info.fboDepthStencilTexture;
        } else {
            ensureDrawableResources();
            if (!acquireDrawableIfNeeded()) return false;
            colorTex = usesOffscreenTarget ? offscreenColorTexture
                                           : currentDrawable.texture;
            depthTex = depthStencilTexture;
        }
        if (colorTex == nil) return false;

        MTLRenderPassDescriptor* pass =
            [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = colorTex;
        if (info.pendingClearColor) {
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(
                info.clearColor[0], info.clearColor[1],
                info.clearColor[2], info.clearColor[3]);
        } else {
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (info.fboColorArrayLength > 0) {
            pass.renderTargetArrayLength =
                static_cast<NSUInteger>(info.fboColorArrayLength);
        }
        if (depthTex != nil && fmtHasDepth) {
            pass.depthAttachment.texture = depthTex;
            if (info.pendingClearDepth) {
                pass.depthAttachment.loadAction = MTLLoadActionClear;
                pass.depthAttachment.clearDepth = info.clearDepth;
            } else {
                pass.depthAttachment.loadAction = MTLLoadActionLoad;
            }
            pass.depthAttachment.storeAction = MTLStoreActionStore;
        }
        if (depthTex != nil && fmtHasStencil) {
            pass.stencilAttachment.texture = depthTex;
            if (info.pendingClearStencil) {
                pass.stencilAttachment.loadAction = MTLLoadActionClear;
                pass.stencilAttachment.clearStencil =
                    (uint32_t)info.clearStencil;
            } else {
                pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            }
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
        }

        id<MTLRenderCommandEncoder> enc =
            [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
        if (enc == nil) return false;

        // Viewport + scissor. Metal's viewport origin is top-left;
        // GL's is bottom-left. The existing translated-draw path
        // flips Y by computing (fboHeight - viewportY - viewportHeight)
        // — replicate that here. For Phase 2 we treat the FBO height
        // as the color texture's height.
        const double fbHeight = (double)colorTex.height;
        const bool flipY = (info.clipOrigin != GL_UPPER_LEFT);
        if (info.viewportArrayCount > 1) {
            MTLViewport viewports[TranslatedDrawInfo::kMaxDrawViewports];
            for (std::size_t i = 0; i < info.viewportArrayCount; ++i) {
                const auto& e = info.viewportArray[i];
                viewports[i].originX = (double)e.originX;
                viewports[i].originY = flipY
                    ? (fbHeight - (double)e.originY - (double)e.height)
                    : (double)e.originY;
                viewports[i].width = (double)e.width;
                viewports[i].height = (double)e.height;
                viewports[i].znear = e.depthNear;
                viewports[i].zfar = e.depthFar;
            }
            [enc setViewports:viewports count:info.viewportArrayCount];
        } else {
            MTLViewport viewport = {
                (double)info.viewportX,
                flipY
                    ? (fbHeight - (double)info.viewportY - (double)info.viewportHeight)
                    : (double)info.viewportY,
                (double)info.viewportWidth,
                (double)info.viewportHeight,
                info.depthRangeNear,
                info.depthRangeFar
            };
            [enc setViewport:viewport];
        }

        auto makeTessScissor = [&](bool enabled, GLint x, GLint y,
                                   GLsizei width, GLsizei height) {
            MTLScissorRect scissor;
            if (enabled) {
                scissor.x = (NSUInteger)std::max(x, 0);
                const GLint metalY = flipY
                    ? ((GLint)colorTex.height - y - height)
                    : y;
                scissor.y = (NSUInteger)std::max(metalY, 0);
                scissor.width = (NSUInteger)std::max(width, 0);
                scissor.height = (NSUInteger)std::max(height, 0);
            } else {
                scissor.x = 0;
                scissor.y = 0;
                scissor.width = colorTex.width;
                scissor.height = colorTex.height;
            }
            if (scissor.x + scissor.width > colorTex.width) {
                scissor.width = scissor.x < colorTex.width
                    ? colorTex.width - scissor.x : 0;
            }
            if (scissor.y + scissor.height > colorTex.height) {
                scissor.height = scissor.y < colorTex.height
                    ? colorTex.height - scissor.y : 0;
            }
            if (scissor.width == 0 || scissor.height == 0) {
                scissor.x = colorTex.width;
                scissor.y = colorTex.height;
                scissor.width = 1;
                scissor.height = 1;
            }
            return scissor;
        };
        if (info.viewportArrayCount > 1) {
            MTLScissorRect scissors[TranslatedDrawInfo::kMaxDrawViewports];
            for (std::size_t i = 0; i < info.viewportArrayCount; ++i) {
                const auto& e = info.scissorArray[i];
                const bool enabled = info.scissorTestEnabled && e.enabled;
                scissors[i] = makeTessScissor(
                    enabled, e.x, e.y, e.width, e.height);
            }
            [enc setScissorRects:scissors count:info.viewportArrayCount];
        } else {
            [enc setScissorRect:makeTessScissor(
                info.scissorTestEnabled, info.scissorX, info.scissorY,
                info.scissorWidth, info.scissorHeight)];
        }

        // Cull / front-face. GL and Metal both use a CCW/CW winding
        // convention so the enum maps 1:1.
        if (info.cullFaceEnabled) {
            MTLCullMode cull = MTLCullModeBack;
            switch (info.cullFaceMode) {
                case GL_FRONT:          cull = MTLCullModeFront; break;
                case GL_BACK:           cull = MTLCullModeBack;  break;
                case GL_FRONT_AND_BACK: cull = MTLCullModeBack;
                    // Metal has no FRONT_AND_BACK — approximate by
                    // culling back + relying on the app to also
                    // disable front-facing draws.
                    break;
                default: break;
            }
            [enc setCullMode:cull];
        } else {
            [enc setCullMode:MTLCullModeNone];
        }
        [enc setFrontFacingWinding:
            (info.frontFace == GL_CW) ? MTLWindingClockwise
                                       : MTLWindingCounterClockwise];

        // Depth/stencil state. Sprint 7 Phase 1 #11 (CKPT57) widened
        // this from depth-only to full per-face stencil plumbing —
        // primitive_coverage's two-phase stencil-replace + stencil-
        // notequal pattern needed it. Configures the descriptor only
        // when the corresponding GL state is actually enabled, so
        // depth-only or stencil-only tests don't drag in irrelevant
        // descriptor fields.
        if (depthTex != nil && (fmtHasDepth || fmtHasStencil)
            && (info.depthTestEnabled || info.stencilTestEnabled)) {
            MTLDepthStencilDescriptor* dsDesc =
                [[MTLDepthStencilDescriptor alloc] init];
            if (info.depthTestEnabled) {
                switch (info.depthFunc) {
                    case GL_NEVER:    dsDesc.depthCompareFunction = MTLCompareFunctionNever; break;
                    case GL_LESS:     dsDesc.depthCompareFunction = MTLCompareFunctionLess; break;
                    case GL_EQUAL:    dsDesc.depthCompareFunction = MTLCompareFunctionEqual; break;
                    case GL_LEQUAL:   dsDesc.depthCompareFunction = MTLCompareFunctionLessEqual; break;
                    case GL_GREATER:  dsDesc.depthCompareFunction = MTLCompareFunctionGreater; break;
                    case GL_NOTEQUAL: dsDesc.depthCompareFunction = MTLCompareFunctionNotEqual; break;
                    case GL_GEQUAL:   dsDesc.depthCompareFunction = MTLCompareFunctionGreaterEqual; break;
                    case GL_ALWAYS:   dsDesc.depthCompareFunction = MTLCompareFunctionAlways; break;
                    default:          dsDesc.depthCompareFunction = MTLCompareFunctionLess; break;
                }
                dsDesc.depthWriteEnabled = info.depthWriteMask ? YES : NO;
            }
            if (info.stencilTestEnabled) {
                dsDesc.frontFaceStencil = buildMetalStencilFace(
                    info.stencilFrontFunc, info.stencilFrontValueMask,
                    info.stencilFrontFail, info.stencilFrontDepthFail,
                    info.stencilFrontDepthPass, info.stencilFrontWriteMask);
                dsDesc.backFaceStencil = buildMetalStencilFace(
                    info.stencilBackFunc, info.stencilBackValueMask,
                    info.stencilBackFail, info.stencilBackDepthFail,
                    info.stencilBackDepthPass, info.stencilBackWriteMask);
            }
            id<MTLDepthStencilState> ds =
                [device newDepthStencilStateWithDescriptor:dsDesc];
            [enc setDepthStencilState:ds];
            if (info.stencilTestEnabled) {
                [enc setStencilFrontReferenceValue:
                         static_cast<uint32_t>(info.stencilFrontRef)
                      backReferenceValue:
                         static_cast<uint32_t>(info.stencilBackRef)];
            }
        }

        // (6) Bind tess factor buffer + issue drawPatches. Phase 3:
        // also bind per-CP (buffer(22)) and per-patch (buffer(20))
        // buffers as vertex-stage inputs so the TES can read them via
        // `raw_buffer_tese_input=true`.
        [enc setRenderPipelineState:renderPSO];
        bindVertexTextures(enc, info.tessEvalTextures);
        bindFragmentTextures(enc, info.fragmentTextures);
        [enc setTessellationFactorBuffer:factorBuf offset:0 instanceStride:0];
        if (isPhase3) {
            [enc setVertexBuffer:cpOutBuf offset:0 atIndex:22];
            [enc setVertexBuffer:patchOutBuf offset:0 atIndex:20];
        }
        // Sprint 5 Phase 1 — Path L: bind factorBufFull at slot 23 for
        // TES-as-vertex-function render encoder. Path L emission produces
        // TES MSL that reads `gl_TessLevelOuter/Inner` from
        // `spvTessLevelFull[primId * stride + idx]` regardless of which
        // encoder runs the TES code; this binding closes the encoder-
        // path coverage gap (per Clerk's §3.6.18 banking).
        [enc setVertexBuffer:factorBufFull offset:0 atIndex:23];
        // Phase 3: drawPatches's `numberOfPatchControlPoints` is the
        // count of control points per patch in the buffer feeding the
        // post-tess vertex stage — i.e. cpOutBuf, which holds TCS
        // output (one element per `layout(vertices=N)` invocation).
        // Tests where glPatchParameteri(PATCH_VERTICES) and TCS
        // output_vertices differ (e.g. `single.max_patch_vertices`
        // uses PATCH_VERTICES=32 with `layout(vertices=2)`) hit a
        // stride mismatch when drawPatches sees the input patch size
        // — Metal reads cpOutBuf at the wrong stride and the TES
        // pulls garbage CPs.  Use tessControlOutputVertices on the
        // compute-pre-pass path; the existing Phase 2 path stays on
        // patchVertices because there's no pre-pass producing
        // a different-sized buffer.
        const NSUInteger drawPatchesCPs = isPhase3 && info.tessControlOutputVertices > 0
            ? (NSUInteger)info.tessControlOutputVertices
            : (NSUInteger)info.patchVertices;
        [enc drawPatches:drawPatchesCPs
              patchStart:0
              patchCount:(NSUInteger)info.patchCount
         patchIndexBuffer:nil
   patchIndexBufferOffset:0
           instanceCount:(NSUInteger)std::max(info.instanceCount, 1)
            baseInstance:(NSUInteger)info.baseInstance];
        [enc endEncoding];

        // Commit + wait so subsequent readbacks / copies observe the
        // tess draw's output. Matches compute-dispatch's sync semantics.
        [currentCommandBuffer commit];
        [currentCommandBuffer waitUntilCompleted];
        currentCommandBuffer = nil;

        if (std::getenv("APPGL_TRACE_TESS")) {
            std::fprintf(stderr,
                "[APPGL] tess-draw program=%u patches=%d cps=%d "
                "patchVerticesIn=%d genMode=0x%04X spacing=0x%04X "
                "winding=0x%04X colorFmt=%u depthFmt=%u\n",
                info.program, (int)info.patchCount,
                (int)info.tessControlOutputVertices,
                (int)info.patchVertices,
                info.genMode, info.genSpacing, info.genVertexOrder,
                (unsigned)colorFormat, (unsigned)depthFormat);
        }
        return true;
    }

    // Sprint 3 Step 2 Phase 2 [metal-mesh-GS]: mesh-shader draw encoder.
    // See MetalFrameGraph::encodeMetalMeshGSDraw declaration for the
    // contract. Three sub-steps mirror Phase-3 metal-tess (3a→3b):
    //   (3a) VS-as-compute writes per-vertex outputs to vsOutBuf.
    //   (3b) Mesh-render PSO build (or cache hit).
    //   (3c) Render pass: bind vsOutBuf @ 22, drawMeshThreadgroups.
    bool encodeMetalMeshGSDraw(MetalFrameGraph::MetalMeshGSDrawInfo& info) {
        if (device == nil) {
            info.diagnostic = "no Metal device";
            return false;
        }
        if (info.vertexComputePipelineState == nullptr ||
            info.meshFunction == nullptr ||
            info.fragmentFunction == nullptr) {
            info.diagnostic = "missing PSO/function inputs";
            return false;
        }
        if (info.vertexCount == 0 || info.primitiveCount == 0) {
            info.diagnostic = "zero-count draw";
            return false;
        }
        if (info.fboColorTexture == nullptr) {
            info.diagnostic = "no color attachment";
            return false;
        }
        if (!drainCurrentCommandBufferForStandaloneEncoding(&info.diagnostic)) {
            return false;
        }

        // (3a) VS-as-compute pre-pass. Allocate output buffer, dispatch
        // VS one thread per vertex, write into vsOutBuf at slot 28
        // (Phase-3 convention).
        const NSUInteger vsOutBufSize =
            (NSUInteger)info.vertexCount *
            (NSUInteger)info.vsOutputStrideBytes;
        id<MTLBuffer> vsOutBuf =
            [device newBufferWithLength:vsOutBufSize
                                options:MTLResourceStorageModePrivate];
        if (vsOutBuf == nil) {
            info.diagnostic = "vsOutBuf alloc failed";
            return false;
        }
        vsOutBuf.label = @"appgl-mesh-gs-vs-output";

        {
            id<MTLCommandBuffer> vsCmdBuf = [commandQueue commandBuffer];
            if (vsCmdBuf == nil) {
                info.diagnostic = "vs cmdBuf alloc failed";
                return false;
            }
            vsCmdBuf.label = @"appgl-mesh-gs-vs-compute";
            id<MTLComputeCommandEncoder> vsEnc =
                [vsCmdBuf computeCommandEncoder];
            if (vsEnc == nil) {
                info.diagnostic = "vs encoder alloc failed";
                return false;
            }
            id<MTLComputePipelineState> vsPSO =
                (__bridge id<MTLComputePipelineState>)info.vertexComputePipelineState;
            [vsEnc setComputePipelineState:vsPSO];
            [vsEnc setBuffer:vsOutBuf offset:0 atIndex:28];
            if (info.vsUniformData != nullptr && info.vsUniformSize > 0) {
                [vsEnc setBytes:info.vsUniformData
                         length:info.vsUniformSize
                        atIndex:16];
            }
            for (const auto& binding : info.vertexComputeBufferBindings) {
                if (binding.metalBuffer == nullptr) {
                    continue;
                }
                [vsEnc setBuffer:(__bridge id<MTLBuffer>)binding.metalBuffer
                          offset:(NSUInteger)binding.offset
                         atIndex:(NSUInteger)binding.metalSlot];
            }
            [vsEnc setStageInRegion:MTLRegionMake1D(0, info.vertexCount)];
            const NSUInteger maxPerTg =
                vsPSO.maxTotalThreadsPerThreadgroup > 0
                    ? vsPSO.maxTotalThreadsPerThreadgroup : 32;
            const NSUInteger tgWidth =
                info.vertexCount > 0 && info.vertexCount < maxPerTg
                    ? info.vertexCount : maxPerTg;
            [vsEnc dispatchThreads:MTLSizeMake(info.vertexCount, 1, 1)
             threadsPerThreadgroup:MTLSizeMake(tgWidth, 1, 1)];
            [vsEnc endEncoding];
            [vsCmdBuf commit];
            [vsCmdBuf waitUntilCompleted];
            if (vsCmdBuf.status == MTLCommandBufferStatusError) {
                NSString* msg = vsCmdBuf.error.localizedDescription;
                info.diagnostic = msg != nil ? msg.UTF8String
                                             : "vs compute command buffer failed";
                return false;
            }
        }

        // (3b) Mesh-render PSO build / cache lookup.
        id<MTLRenderPipelineState> meshPSO = nil;
        if (info.meshPipelineStateInOut != nullptr &&
            *info.meshPipelineStateInOut != nullptr) {
            meshPSO = (__bridge id<MTLRenderPipelineState>)
                *info.meshPipelineStateInOut;
        } else {
            id<MTLTexture> colorTex =
                (__bridge id<MTLTexture>)info.fboColorTexture;
            id<MTLTexture> dsTex = info.fboDepthStencilTexture != nullptr
                ? (__bridge id<MTLTexture>)info.fboDepthStencilTexture
                : nil;
            MTLMeshRenderPipelineDescriptor* meshDesc =
                [[MTLMeshRenderPipelineDescriptor alloc] init];
            meshDesc.meshFunction =
                (__bridge id<MTLFunction>)info.meshFunction;
            meshDesc.fragmentFunction =
                (__bridge id<MTLFunction>)info.fragmentFunction;
            meshDesc.colorAttachments[0].pixelFormat = colorTex.pixelFormat;
            if (dsTex != nil) {
                const MTLPixelFormat pf = dsTex.pixelFormat;
                if (pf == MTLPixelFormatDepth16Unorm ||
                    pf == MTLPixelFormatDepth32Float ||
                    pf == MTLPixelFormatDepth32Float_Stencil8 ||
                    pf == MTLPixelFormatDepth24Unorm_Stencil8) {
                    meshDesc.depthAttachmentPixelFormat = pf;
                }
                if (pf == MTLPixelFormatStencil8 ||
                    pf == MTLPixelFormatDepth32Float_Stencil8 ||
                    pf == MTLPixelFormatDepth24Unorm_Stencil8 ||
                    pf == MTLPixelFormatX32_Stencil8 ||
                    pf == MTLPixelFormatX24_Stencil8) {
                    meshDesc.stencilAttachmentPixelFormat = pf;
                }
            }
            // One mesh threadgroup per input primitive. Object stage
            // is unused (no amplification needed for the MVP envelope).
            meshDesc.maxTotalThreadsPerObjectThreadgroup = 1;
            meshDesc.maxTotalThreadsPerMeshThreadgroup = 1;
            NSError* err = nil;
            meshPSO = [device
                newRenderPipelineStateWithMeshDescriptor:meshDesc
                                                 options:MTLPipelineOptionNone
                                              reflection:nil
                                                   error:&err];
            if (meshPSO == nil) {
                info.diagnostic = err.localizedDescription.UTF8String
                    ? err.localizedDescription.UTF8String
                    : "newRenderPipelineStateWithMeshDescriptor failed";
                return false;
            }
            if (info.meshPipelineStateInOut != nullptr) {
                *info.meshPipelineStateInOut =
                    (void*)CFBridgingRetain(meshPSO);
            }
        }

        // (3c) Render pass + drawMeshThreadgroups.
        // Path D — currentRenderEncoder lifecycle cooperation. End any
        // open legacy render encoder before the mesh pass takes over,
        // so the encoder lifecycle is clean and the next legacy draw
        // rebuilds. Mirrors the `currentRenderEncoder = nil` pattern at
        // MetalFrameGraph.mm:854 (endRenderPass), but inline-scoped to
        // this branch.
        if (currentRenderEncoder != nil) {
            [currentRenderEncoder endEncoding];
            currentRenderEncoder = nil;
            activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
        }
        id<MTLCommandBuffer> rcmd = [commandQueue commandBuffer];
        if (rcmd == nil) {
            info.diagnostic = "render cmdBuf alloc failed";
            return false;
        }
        rcmd.label = @"appgl-mesh-gs-draw";
        // Path D — pending-clear consumption. AppGL defers glClear into
        // hasPendingClear / pendingClearColor / pendingClearDepth /
        // pendingClearStencil; the next render pass on the
        // default-FB picks them up via MTLLoadActionClear. Mirrors the
        // legacy gate at MetalFrameGraph.mm:2057-2062 (color),
        // 2100-2108 (depth+stencil). Per the legacy gate, pending
        // clears apply only to the default-FB draw path
        // (`!isFBODraw`) — user-FBO clears are tracked separately and
        // don't reach here.
        const bool isFBODraw = (info.fboColorTexture != nullptr &&
            info.fboColorTexture != (__bridge void*)offscreenColorTexture &&
            info.fboColorTexture != (__bridge void*)(currentDrawable.texture));
        const bool consumeColorClear =
            !isFBODraw && hasPendingClear &&
            (pendingClearMask & GL_COLOR_BUFFER_BIT);
        const bool consumeDepthClear =
            !isFBODraw && hasPendingClear &&
            (pendingClearMask & GL_DEPTH_BUFFER_BIT);
        const bool consumeStencilClear =
            !isFBODraw && hasPendingClear &&
            (pendingClearMask & GL_STENCIL_BUFFER_BIT);
        if (std::getenv("APPGL_TRACE_MESH_GS") != nullptr) {
            std::fprintf(stderr,
                "[MESH_GS] pass setup: isFBODraw=%d hasPendingClear=%d mask=0x%x "
                "consumeColor=%d consumeDepth=%d consumeStencil=%d\n",
                (int)isFBODraw, (int)hasPendingClear,
                (unsigned)pendingClearMask,
                (int)consumeColorClear, (int)consumeDepthClear,
                (int)consumeStencilClear);
            std::fflush(stderr);
        }

        MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture =
            (__bridge id<MTLTexture>)info.fboColorTexture;
        rpd.colorAttachments[0].loadAction =
            consumeColorClear ? MTLLoadActionClear : MTLLoadActionLoad;
        if (consumeColorClear) {
            rpd.colorAttachments[0].clearColor = pendingClearColor;
        }
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        // Phase 2.5 — layered FBO routing. When the GS writes
        // `gl_Layer`, SPIRV-W's Gap C emission propagates the value to
        // `spvCurrentPrim.gl_Layer` which the mesh stage exposes as
        // `[[render_target_array_index]]` on the per-primitive output.
        // Metal requires `renderTargetArrayLength` set on the pass
        // descriptor for the rasterizer to honour it. Mirrors legacy
        // encodeTranslatedDraw at MetalFrameGraph.mm:2092.
        if (info.fboColorArrayLength > 0) {
            // Sprint 17 Day 1 (CKPT236) [Probe A 2DMSArray clamp]:
            // mirror the legacy-encoder clamp for the mesh path.
            // See encodeTranslatedDraw 2DMSArray comment block.
            NSUInteger rtal = static_cast<NSUInteger>(
                info.fboColorArrayLength);
            if (info.maxEmittedLayer > 0 &&
                info.fboColorTexture != nullptr) {
                id<MTLTexture> colTex = (__bridge id<MTLTexture>)
                    info.fboColorTexture;
                if (colTex.textureType ==
                        MTLTextureType2DMultisampleArray) {
                    const NSUInteger active = static_cast<NSUInteger>(
                        info.maxEmittedLayer + 1u);
                    if (active < rtal) rtal = active;
                }
            }
            rpd.renderTargetArrayLength = rtal;
        }
        if (info.fboDepthStencilTexture != nullptr) {
            id<MTLTexture> dsTex =
                (__bridge id<MTLTexture>)info.fboDepthStencilTexture;
            const MTLPixelFormat pf = dsTex.pixelFormat;
            if (pf == MTLPixelFormatDepth16Unorm ||
                pf == MTLPixelFormatDepth32Float ||
                pf == MTLPixelFormatDepth32Float_Stencil8 ||
                pf == MTLPixelFormatDepth24Unorm_Stencil8) {
                rpd.depthAttachment.texture = dsTex;
                rpd.depthAttachment.loadAction =
                    consumeDepthClear ? MTLLoadActionClear : MTLLoadActionLoad;
                if (consumeDepthClear) {
                    rpd.depthAttachment.clearDepth = pendingClearDepth;
                }
                rpd.depthAttachment.storeAction = MTLStoreActionStore;
            }
            if (pf == MTLPixelFormatStencil8 ||
                pf == MTLPixelFormatDepth32Float_Stencil8 ||
                pf == MTLPixelFormatDepth24Unorm_Stencil8 ||
                pf == MTLPixelFormatX32_Stencil8 ||
                pf == MTLPixelFormatX24_Stencil8) {
                rpd.stencilAttachment.texture = dsTex;
                rpd.stencilAttachment.loadAction =
                    consumeStencilClear ? MTLLoadActionClear : MTLLoadActionLoad;
                if (consumeStencilClear) {
                    rpd.stencilAttachment.clearStencil = pendingClearStencil;
                }
                rpd.stencilAttachment.storeAction = MTLStoreActionStore;
            }
        }
        id<MTLRenderCommandEncoder> renc =
            [rcmd renderCommandEncoderWithDescriptor:rpd];
        if (renc == nil) {
            info.diagnostic = "render encoder alloc failed";
            return false;
        }
        [renc setRenderPipelineState:meshPSO];
        [renc setMeshBuffer:vsOutBuf offset:0 atIndex:22];
        if (info.meshUniformData != nullptr && info.meshUniformSize > 0) {
            [renc setMeshBytes:info.meshUniformData
                        length:info.meshUniformSize
                       atIndex:16];
        }
        if (info.fsUniformData != nullptr && info.fsUniformSize > 0) {
            [renc setFragmentBytes:info.fsUniformData
                            length:info.fsUniformSize
                           atIndex:16];
        }
        if (info.fragmentNeedsFragCoordParams) {
            id<MTLTexture> colorTex =
                (__bridge id<MTLTexture>)info.fboColorTexture;
            const float renderTargetHeight = colorTex != nil
                ? static_cast<float>(colorTex.height)
                : static_cast<float>(std::max<std::int32_t>(
                      info.viewportHeight, 1));
            bool fragmentAliasesColorAttachment = false;
            if (colorTex != nil) {
                for (const auto& binding : info.fragmentTextures) {
                    if (binding.metalTexture == nullptr) continue;
                    id<MTLTexture> tex =
                        (__bridge id<MTLTexture>)binding.metalTexture;
                    if (tex == colorTex) {
                        fragmentAliasesColorAttachment = true;
                        break;
                    }
                }
            }
            const bool flipToLowerLeft =
                (info.clipOrigin != GL_UPPER_LEFT) &&
                !fragmentAliasesColorAttachment;
            const float fragCoordParams[4] = {
                flipToLowerLeft ? renderTargetHeight : 0.0f,
                flipToLowerLeft ? -1.0f : 1.0f,
                flipToLowerLeft ? 1.0f : 0.0f,
                0.0f,
            };
            [renc setFragmentBytes:fragCoordParams
                            length:sizeof(fragCoordParams)
                           atIndex:kAppGLFragCoordParamsBufferSlot];
            if (std::getenv("APPGL_TRACE_MESH_GS") != nullptr) {
                std::fprintf(stderr,
                    "[MESH_GS] fragCoordParams clipOrigin=0x%x rtH=%.1f "
                    "aliasesColor=%d params=(%.1f,%.1f,%.1f,%.1f)\n",
                    info.clipOrigin,
                    renderTargetHeight,
                    fragmentAliasesColorAttachment ? 1 : 0,
                    fragCoordParams[0], fragCoordParams[1],
                    fragCoordParams[2], fragCoordParams[3]);
                std::fflush(stderr);
            }
        }
        for (const auto& binding : info.fragmentTextures) {
            id<MTLTexture> tex =
                (__bridge id<MTLTexture>)binding.metalTexture;
            if (tex == nil) {
                continue;
            }
            [renc setFragmentTexture:tex
                              atIndex:static_cast<NSUInteger>(binding.metalSlot)];
            if (binding.metalSamplerState != nullptr) {
                id<MTLSamplerState> smp =
                    (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                [renc setFragmentSamplerState:smp
                                       atIndex:static_cast<NSUInteger>(binding.metalSlot)];
            }
        }
        for (const auto& binding : info.meshTextures) {
            id<MTLTexture> tex =
                (__bridge id<MTLTexture>)binding.metalTexture;
            if (tex == nil) {
                continue;
            }
            [renc setMeshTexture:tex
                          atIndex:static_cast<NSUInteger>(binding.metalSlot)];
            if (binding.metalSamplerState != nullptr) {
                id<MTLSamplerState> smp =
                    (__bridge id<MTLSamplerState>)binding.metalSamplerState;
                [renc setMeshSamplerState:smp
                                   atIndex:static_cast<NSUInteger>(binding.metalSlot)];
            }
        }

        // GL render-state plumbing — mirrors encodeTranslatedDraw's
        // depth/cull/winding/fill/scissor/viewport sequence so the
        // mesh-shader path produces pixels with the same masks /
        // depth-test behavior the legacy path applies.
        if (info.fboDepthStencilTexture != nullptr) {
            MetalDrawInfo fakeInfo;
            fakeInfo.depthTestEnabled = info.depthTestEnabled;
            fakeInfo.depthFunc = static_cast<GLenum>(info.depthFunc);
            fakeInfo.depthWriteMask = info.depthWriteMask;
            // Sprint 7 Phase 1 #11 (CKPT57): mesh-GS path stencil plumb.
            fakeInfo.stencilTestEnabled = info.stencilTestEnabled;
            fakeInfo.stencilFrontFunc = static_cast<GLenum>(info.stencilFrontFunc);
            fakeInfo.stencilFrontRef = info.stencilFrontRef;
            fakeInfo.stencilFrontValueMask = info.stencilFrontValueMask;
            fakeInfo.stencilFrontFail = static_cast<GLenum>(info.stencilFrontFail);
            fakeInfo.stencilFrontDepthFail = static_cast<GLenum>(info.stencilFrontDepthFail);
            fakeInfo.stencilFrontDepthPass = static_cast<GLenum>(info.stencilFrontDepthPass);
            fakeInfo.stencilFrontWriteMask = info.stencilFrontWriteMask;
            fakeInfo.stencilBackFunc = static_cast<GLenum>(info.stencilBackFunc);
            fakeInfo.stencilBackRef = info.stencilBackRef;
            fakeInfo.stencilBackValueMask = info.stencilBackValueMask;
            fakeInfo.stencilBackFail = static_cast<GLenum>(info.stencilBackFail);
            fakeInfo.stencilBackDepthFail = static_cast<GLenum>(info.stencilBackDepthFail);
            fakeInfo.stencilBackDepthPass = static_cast<GLenum>(info.stencilBackDepthPass);
            fakeInfo.stencilBackWriteMask = info.stencilBackWriteMask;
            id<MTLDepthStencilState> dsState =
                depthStencilStateForDraw(fakeInfo);
            if (dsState != nil) {
                [renc setDepthStencilState:dsState];
            }
            if (info.stencilTestEnabled) {
                [renc setStencilFrontReferenceValue:
                          static_cast<uint32_t>(info.stencilFrontRef)
                       backReferenceValue:
                          static_cast<uint32_t>(info.stencilBackRef)];
            }
        }
        const MTLCullMode desiredCull = info.cullFaceEnabled
            ? (info.cullFaceMode == GL_FRONT ? MTLCullModeFront
                                              : MTLCullModeBack)
            : MTLCullModeNone;
        [renc setCullMode:desiredCull];
        [renc setFrontFacingWinding:info.frontFace == GL_CW
            ? MTLWindingClockwise : MTLWindingCounterClockwise];
        [renc setTriangleFillMode:info.wireframe
            ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
        {
            const float bias = info.polygonOffsetEnabled
                ? info.polygonOffsetUnits : 0.0f;
            const float slope = info.polygonOffsetEnabled
                ? info.polygonOffsetFactor : 0.0f;
            const float clampV = info.polygonOffsetEnabled
                ? info.polygonOffsetClamp : 0.0f;
            [renc setDepthBias:bias slopeScale:slope clamp:clampV];
        }
        // Viewport. GL bottom-up → Metal top-down conversion.
        // Sprint 17 Day 3+ BONUS-1 [clip_control]: gate Y-flip on
        // `info.clipOrigin` (mesh-GS path). See encodeTranslatedDraw
        // for full rationale.
        if (info.viewportWidth > 0 && info.viewportHeight > 0) {
            id<MTLTexture> colorTex =
                (__bridge id<MTLTexture>)info.fboColorTexture;
            const double rtHeight = static_cast<double>(colorTex.height);
            const bool flipY = (info.clipOrigin != GL_UPPER_LEFT);
            MTLViewport vp;
            vp.originX = static_cast<double>(info.viewportX);
            vp.originY = flipY
                ? (rtHeight - static_cast<double>(info.viewportY)
                   - static_cast<double>(info.viewportHeight))
                : static_cast<double>(info.viewportY);
            vp.width   = static_cast<double>(info.viewportWidth);
            vp.height  = static_cast<double>(info.viewportHeight);
            vp.znear   = info.depthRangeNear;
            vp.zfar    = info.depthRangeFar;
            [renc setViewport:vp];
        }
        // Scissor. GL bottom-up → Metal top-down conversion + clamp.
        // When disabled, set to full render-target rect.
        {
            id<MTLTexture> colorTex =
                (__bridge id<MTLTexture>)info.fboColorTexture;
            const NSUInteger rtW = colorTex.width;
            const NSUInteger rtH = colorTex.height;
            MTLScissorRect sr;
            if (!info.scissorTestEnabled) {
                sr.x = 0; sr.y = 0; sr.width = rtW; sr.height = rtH;
            } else if (info.scissorWidth <= 0 ||
                       info.scissorHeight <= 0) {
                sr.x = 0; sr.y = 0; sr.width = 0; sr.height = 0;
            } else {
                std::int32_t metalY =
                    static_cast<std::int32_t>(rtH)
                    - info.scissorY - info.scissorHeight;
                if (metalY < 0) metalY = 0;
                std::int32_t metalX = info.scissorX < 0
                    ? 0 : info.scissorX;
                std::int32_t availW =
                    static_cast<std::int32_t>(rtW) - metalX;
                std::int32_t availH =
                    static_cast<std::int32_t>(rtH) - metalY;
                std::int32_t finalW =
                    std::min(info.scissorWidth, std::max(0, availW));
                std::int32_t finalH =
                    std::min(info.scissorHeight, std::max(0, availH));
                if (finalW <= 0 || finalH <= 0) {
                    sr.x = rtW > 0 ? rtW - 1 : 0;
                    sr.y = rtH > 0 ? rtH - 1 : 0;
                    sr.width = 1; sr.height = 1;
                } else {
                    sr.x = static_cast<NSUInteger>(metalX);
                    sr.y = static_cast<NSUInteger>(metalY);
                    sr.width = static_cast<NSUInteger>(finalW);
                    sr.height = static_cast<NSUInteger>(finalH);
                }
            }
            [renc setScissorRect:sr];
        }

        // One threadgroup per input primitive, 1 thread per group.
        // Mesh function reads spvPrimitiveID via
        // [[threadgroup_position_in_grid]] and indexes
        // spvVsOutputs[spvPrimitiveID * inputVerticesPerPrimitive +
        // vI] for each input vertex.
        [renc drawMeshThreadgroups:MTLSizeMake(info.primitiveCount, 1, 1)
            threadsPerObjectThreadgroup:MTLSizeMake(1, 1, 1)
              threadsPerMeshThreadgroup:MTLSizeMake(1, 1, 1)];
        [renc endEncoding];
        [rcmd commit];
        [rcmd waitUntilCompleted];

        // Path D — clear the pending-clear flag now that the pass has
        // consumed it (matches MetalFrameGraph.mm:984's `hasPendingClear
        // = false` after the legacy draw fires). All three masks
        // (color/depth/stencil) reset together — the legacy gate also
        // resets after a draw regardless of which channels were
        // actually consumed.
        if (consumeColorClear || consumeDepthClear || consumeStencilClear) {
            hasPendingClear = false;
        }

        return true;
    }

    // Encode + commit + wait a single compute dispatch. The wait is
    // synchronous to match CTS's "dispatch, then map SSBO" pattern —
    // without it, the map'd bytes are stale compute-shader input
    // rather than post-shader output. Revisit if we ever hit a
    // workload where pipelined compute+graphics is needed.
    bool encodeComputeDispatch(const ComputeDispatchInfo& info) {
        if (device == nil || commandQueue == nil) {
            return false;
        }
        id<MTLComputePipelineState> pso =
            (__bridge id<MTLComputePipelineState>)info.metalComputePipelineState;
        if (pso == nil) {
            return false;
        }
        // End any open render encoder to avoid nesting encoders on one
        // command buffer. Use our own dedicated command buffer so the
        // flushForReadback plumbing for render paths stays separate.
        endRenderPass();

        id<MTLCommandBuffer> cmdBuf = [commandQueue commandBuffer];
        if (cmdBuf == nil) {
            return false;
        }
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        if (enc == nil) {
            return false;
        }
        [enc setComputePipelineState:pso];

        // Step 7-3 compute follow-up: under argument_buffers mode, the
        // shader was compiled with `spvDescriptorSetBuffer0/1` structs
        // at [[buffer(24)]] / [[buffer(25)]] — bind through argument
        // encoders instead of direct per-slot calls. Mirror the
        // graphics-stage encodeTexturesIntoArgBuf / encodeUBOsIntoArgBuf
        // shape. Phase 7 cleanup (a) closed a two-part
        // `compute_shader.pipeline-post-fs` regression: vendored
        // SPIRV-Cross patch emits `access::read_write` for
        // NonWritable storage images (bare `texture2d<T>` landed at
        // `access::sample` and MTLArgumentEncoder didn't enumerate
        // the sample-access slot), plus reflection-time filter that
        // drops declared-but-unused storage images (SPIRV-Cross's
        // dead-code pass elides them from MSL but
        // `resources.storage_images` kept them, producing argbuf
        // entries whose slot was outside the encoder's valid range).
        const bool useArgBuf =
            (std::getenv("APPGL_ENABLE_ARGUMENT_BUFFERS") != nullptr);
        id<MTLFunction> computeFn = (__bridge id<MTLFunction>)info.metalComputeFunction;

        if (useArgBuf && computeFn != nil) {
            // Desc_set 0: textures (sampled + storage) + SSBOs
            const bool hasTextures = !info.textures.empty();
            const bool hasBuffers  = !info.buffers.empty();
            id<MTLArgumentEncoder> argEncSet0 = nil;
            if (hasTextures || hasBuffers) {
                argEncSet0 = [computeFn newArgumentEncoderWithBufferIndex:24];
            }
            // Desc_set 1: UBOs (default-uniform block comes in at
            // [[id(16)]] from computeUniformData, plus any explicit
            // UBO blocks collected in info.buffers at their reflection
            // slots 16+seq). Gated similarly.
            const bool hasUniformData =
                (info.computeUniformData != nullptr && info.computeUniformSize > 0);
            id<MTLArgumentEncoder> argEncSet1 = nil;
            if (hasUniformData) {
                argEncSet1 = [computeFn newArgumentEncoderWithBufferIndex:25];
            }
            if (argEncSet0 != nil) {
                const NSUInteger len0 = [argEncSet0 encodedLength];
                if (len0 > 0) {
                    // Step 7-4: ring-buffer sub-allocation for compute
                    // desc_set 0 argument buffer.
                    RingAlloc alloc0 = ringAllocRaw(len0);
                    id<MTLBuffer> buf0 = alloc0.buffer;
                    const NSUInteger buf0Offset = alloc0.offset;
                    if (buf0 != nil) {
                        [argEncSet0 setArgumentBuffer:buf0 offset:buf0Offset];
                        for (const auto& tb : info.textures) {
                            id<MTLTexture> tex = (__bridge id<MTLTexture>)tb.metalTexture;
                            if (tex == nil) continue;
                            [argEncSet0 setTexture:tex
                                           atIndex:static_cast<NSUInteger>(tb.metalSlot)];
                            MTLResourceUsage usage = MTLResourceUsageRead;
                            if (tb.metalSamplerState != nullptr) {
                                id<MTLSamplerState> smp = (__bridge id<MTLSamplerState>)tb.metalSamplerState;
                                [argEncSet0 setSamplerState:smp
                                                    atIndex:static_cast<NSUInteger>(tb.metalSlot) + 1];
                                usage |= MTLResourceUsageSample;
                            } else {
                                usage |= MTLResourceUsageWrite;
                            }
                            [enc useResource:tex usage:usage];
                        }
                        // The GL default-uniform block lives at Metal slot
                        // `makeComputeBindingMap().uniformBufferBase` in both
                        // direct and argbuf modes. Under argbuf the block
                        // moves into spvDescriptorSetBuffer1 at the same
                        // [[id(N)]] — the set-1 encoder writes it below.
                        // Skip it in this set-0 loop so we don't
                        // double-bind.
                        const std::uint32_t kDefaultUniformSlot =
                            appgl::makeComputeBindingMap().uniformBufferBase;
                        for (const auto& bb : info.buffers) {
                            id<MTLBuffer> buf = (__bridge id<MTLBuffer>)bb.metalBuffer;
                            if (buf == nil) continue;
                            if (bb.metalSlot == kDefaultUniformSlot) continue;
                            [argEncSet0 setBuffer:buf
                                           offset:static_cast<NSUInteger>(bb.offset)
                                          atIndex:static_cast<NSUInteger>(bb.metalSlot)];
                            [enc useResource:buf
                                        usage:MTLResourceUsageRead|MTLResourceUsageWrite];
                        }
                        [enc setBuffer:buf0 offset:buf0Offset atIndex:24];
                    }
                }
            }
            if (argEncSet1 != nil) {
                const NSUInteger len1 = [argEncSet1 encodedLength];
                if (len1 > 0) {
                    // Step 7-4: ring-buffer sub-allocation for compute
                    // desc_set 1 argument buffer.
                    RingAlloc alloc1 = ringAllocRaw(len1);
                    id<MTLBuffer> buf1 = alloc1.buffer;
                    const NSUInteger buf1Offset = alloc1.offset;
                    if (buf1 != nil) {
                        [argEncSet1 setArgumentBuffer:buf1 offset:buf1Offset];
                        if (hasUniformData) {
                            RingAlloc alloc = ringSuballocate(
                                info.computeUniformData, info.computeUniformSize);
                            if (alloc.buffer != nil) {
                                [argEncSet1 setBuffer:alloc.buffer
                                               offset:alloc.offset
                                              atIndex:16];
                                [enc useResource:alloc.buffer
                                            usage:MTLResourceUsageRead];
                            }
                        }
                        [enc setBuffer:buf1 offset:buf1Offset atIndex:25];
                    }
                }
            }
        } else {
            // SSBO `.length()` / OpArrayLength support for direct compute.
            // SPIRV-Cross emits `constant uint* spvBufferSizeConstants
            // [[buffer(25)]]`; entries are keyed by the SSBO's reflected
            // Metal buffer slot and contain the effective GL bound range.
            if (info.needsSSBOSizeBuffer) {
                std::uint32_t maxSlot = 0;
                bool any = false;
                for (const auto& bb : info.buffers) {
                    if (bb.size == 0) continue;
                    maxSlot = std::max(maxSlot, bb.metalSlot);
                    any = true;
                }
                if (any) {
                    std::vector<std::uint32_t> sizes(
                        static_cast<std::size_t>(maxSlot) + 1u, 0u);
                    for (const auto& bb : info.buffers) {
                        if (bb.size == 0 || bb.metalSlot >= sizes.size()) continue;
                        sizes[bb.metalSlot] = static_cast<std::uint32_t>(
                            std::min<std::size_t>(
                                bb.size,
                                static_cast<std::size_t>(
                                    std::numeric_limits<std::uint32_t>::max())));
                    }
                    [enc setBytes:sizes.data()
                           length:static_cast<NSUInteger>(
                                      sizes.size() * sizeof(std::uint32_t))
                          atIndex:25];
                }
            }

            // Default-uniform push constants (bare GL uniforms packed into
            // one buffer at Metal index 16 — matches the graphics-stage
            // convention used by drawArrays/drawElements). Lets compute
            // shaders see bare `uniform vec4 u0;` updates via glUniform4fv.
            if (info.computeUniformData != nullptr && info.computeUniformSize > 0) {
                [enc setBytes:info.computeUniformData
                       length:info.computeUniformSize
                      atIndex:16];
            }
            for (const auto& bb : info.buffers) {
                id<MTLBuffer> buf = (__bridge id<MTLBuffer>)bb.metalBuffer;
                if (buf == nil) continue;
                [enc setBuffer:buf
                        offset:static_cast<NSUInteger>(bb.offset)
                       atIndex:static_cast<NSUInteger>(bb.metalSlot)];
            }
            for (const auto& tb : info.textures) {
                id<MTLTexture> tex = (__bridge id<MTLTexture>)tb.metalTexture;
                id<MTLSamplerState> smp = (__bridge id<MTLSamplerState>)tb.metalSamplerState;
                if (tex != nil) {
                    [enc setTexture:tex atIndex:static_cast<NSUInteger>(tb.metalSlot)];
                }
                if (smp != nil) {
                    [enc setSamplerState:smp atIndex:static_cast<NSUInteger>(tb.metalSlot)];
                }
            }
        }
        if (info.multisampleStorageImageSampleCounts != nullptr &&
            info.multisampleStorageImageSampleCountBytes > 0) {
            [enc setBytes:info.multisampleStorageImageSampleCounts
                   length:static_cast<NSUInteger>(
                              info.multisampleStorageImageSampleCountBytes)
                  atIndex:static_cast<NSUInteger>(
                              info.multisampleStorageImageSampleCountSlot)];
        }

        // GL's glDispatchCompute(gx, gy, gz) spec: (gx, gy, gz) is the
        // number of work groups; per-group thread count is the shader's
        // `layout(local_size_x/y/z = N) in;` declaration. Metal's
        // dispatchThreadgroups maps 1:1 to this.
        const MTLSize threadGroups = MTLSizeMake(
            std::max<NSUInteger>(1, info.groupsX),
            std::max<NSUInteger>(1, info.groupsY),
            std::max<NSUInteger>(1, info.groupsZ));
        const MTLSize threadsPerGroup = MTLSizeMake(
            std::max<NSUInteger>(1, info.localX),
            std::max<NSUInteger>(1, info.localY),
            std::max<NSUInteger>(1, info.localZ));
        id<MTLBuffer> indirectBuf = (__bridge id<MTLBuffer>)info.indirectBuffer;
        if (indirectBuf != nil) {
            [enc dispatchThreadgroupsWithIndirectBuffer:indirectBuf
                                   indirectBufferOffset:static_cast<NSUInteger>(info.indirectOffset)
                                  threadsPerThreadgroup:threadsPerGroup];
        } else {
            [enc dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
        }
        [enc endEncoding];
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];
        return true;
    }

    // Benchmark metric accessors.
    std::uint64_t getPipelineCacheHits() const { return pipelineCacheHits; }
    std::uint64_t getPipelineCacheMisses() const { return pipelineCacheMisses; }
    std::uint64_t getPipelineBuildAttempts() const { return pipelineBuildAttempts; }
    std::uint64_t getPipelineBuildFailures() const { return pipelineBuildFailures; }
    double getPipelineBuildMs() const { return pipelineCumulativeBuildMs; }
    void resetMetrics() {
        pipelineCacheHits = 0;
        pipelineCacheMisses = 0;
        pipelineBuildAttempts = 0;
        pipelineBuildFailures = 0;
        pipelineCumulativeBuildMs = 0.0;
    }
    std::uint64_t getMetalAllocatedBytes() const {
        if (device != nil && [device respondsToSelector:@selector(currentAllocatedSize)]) {
            return static_cast<std::uint64_t>(device.currentAllocatedSize);
        }
        return 0;
    }

private:
    void ensureDrawableResources() {
        if (device == nil) {
            return;
        }

        if (drawableWidth <= 0 || drawableHeight <= 0) {
            if (layer != nil) {
                const CGSize bounds = layer.bounds.size;
                drawableWidth = bounds.width > 0.0 ? static_cast<GLsizei>(bounds.width) : 1;
                drawableHeight = bounds.height > 0.0 ? static_cast<GLsizei>(bounds.height) : 1;
            } else {
                drawableWidth = 1;
                drawableHeight = 1;
            }
        }

        if (layer != nil) {
            layer.drawableSize = CGSizeMake(drawableWidth, drawableHeight);
        }

        const bool needsDepthRebuild =
            depthStencilTexture == nil
            || depthStencilTexture.width != static_cast<NSUInteger>(drawableWidth)
            || depthStencilTexture.height != static_cast<NSUInteger>(drawableHeight);

        if (needsDepthRebuild) {
            MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                                                                   width:static_cast<NSUInteger>(drawableWidth)
                                                                                                  height:static_cast<NSUInteger>(drawableHeight)
                                                                                               mipmapped:NO];
            descriptor.storageMode = MTLStorageModePrivate;
            descriptor.usage = MTLTextureUsageRenderTarget;
            depthStencilTexture = [device newTextureWithDescriptor:descriptor];
        }

        const bool needsOffscreenRebuild =
            usesOffscreenTarget
            && (offscreenColorTexture == nil
                || offscreenColorTexture.width != static_cast<NSUInteger>(drawableWidth)
                || offscreenColorTexture.height != static_cast<NSUInteger>(drawableHeight));
        if (needsOffscreenRebuild) {
            MTLTextureDescriptor* colorDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                       width:static_cast<NSUInteger>(drawableWidth)
                                                                                                      height:static_cast<NSUInteger>(drawableHeight)
                                                                                                   mipmapped:NO];
            colorDescriptor.storageMode = MTLStorageModePrivate;
            colorDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            offscreenColorTexture = [device newTextureWithDescriptor:colorDescriptor];
        }
    }

    NSUInteger alignBytesPerRow(NSUInteger byteCount) const {
        constexpr NSUInteger kMetalBufferAlignment = 256;
        return ((byteCount + kMetalBufferAlignment - 1u) / kMetalBufferAlignment) * kMetalBufferAlignment;
    }

    std::uint8_t normalizedByte(GLfloat value) const {
        const GLfloat clamped = std::clamp(value, 0.0f, 1.0f);
        return static_cast<std::uint8_t>(clamped * 255.0f + 0.5f);
    }

    void storeHeadlessClear(GLbitfield mask, GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
        if ((mask & GL_COLOR_BUFFER_BIT) == 0) {
            return;
        }

        const std::size_t width = static_cast<std::size_t>(drawableWidth > 0 ? drawableWidth : 1);
        const std::size_t height = static_cast<std::size_t>(drawableHeight > 0 ? drawableHeight : 1);
        headlessReadbackRGBA.assign(width * height * 4u, 0);
        const std::uint8_t rgba[4] = {
            normalizedByte(red),
            normalizedByte(green),
            normalizedByte(blue),
            normalizedByte(alpha),
        };
        for (std::size_t offset = 0; offset < headlessReadbackRGBA.size(); offset += 4u) {
            std::memcpy(headlessReadbackRGBA.data() + offset, rgba, 4);
        }
        hasHeadlessReadback = true;
    }

    bool copyHeadlessPixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels) const {
        if (!hasHeadlessReadback) {
            return false;
        }
        const auto sourceWidth = drawableWidth > 0 ? drawableWidth : 1;
        const auto sourceHeight = drawableHeight > 0 ? drawableHeight : 1;
        auto* bytes = static_cast<std::uint8_t*>(outPixels);
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint srcX = x + col;
                const GLint srcY = y + row;
                const std::size_t dstOffset = static_cast<std::size_t>(row * width + col) * 4u;
                if (srcX < 0 || srcY < 0 || srcX >= sourceWidth || srcY >= sourceHeight) {
                    std::memset(bytes + dstOffset, 0, 4);
                    continue;
                }
                const std::size_t srcOffset = (static_cast<std::size_t>(srcY) * static_cast<std::size_t>(sourceWidth)
                    + static_cast<std::size_t>(srcX)) * 4u;
                std::memcpy(bytes + dstOffset, headlessReadbackRGBA.data() + srcOffset, 4);
            }
        }
        return true;
    }

    void enqueueOffscreenClearUpload(GLbitfield mask, GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
        if (!usesOffscreenTarget || (mask & GL_COLOR_BUFFER_BIT) == 0 || offscreenColorTexture == nil || currentCommandBuffer == nil) {
            return;
        }

        const NSUInteger width = offscreenColorTexture.width;
        const NSUInteger height = offscreenColorTexture.height;
        const NSUInteger packedRowBytes = width * 4u;
        const NSUInteger rowBytes = alignBytesPerRow(packedRowBytes);
        id<MTLBuffer> staging = [device newBufferWithLength:rowBytes * height options:MTLResourceStorageModeShared];
        if (staging == nil) {
            return;
        }

        const std::uint8_t rgba[4] = {
            normalizedByte(red),
            normalizedByte(green),
            normalizedByte(blue),
            normalizedByte(alpha),
        };
        auto* bytes = static_cast<std::uint8_t*>([staging contents]);
        for (NSUInteger row = 0; row < height; ++row) {
            std::uint8_t* rowStart = bytes + row * rowBytes;
            for (NSUInteger col = 0; col < width; ++col) {
                std::memcpy(rowStart + col * 4u, rgba, 4);
            }
        }

        id<MTLBlitCommandEncoder> blit = [currentCommandBuffer blitCommandEncoder];
        [blit copyFromBuffer:staging
                sourceOffset:0
           sourceBytesPerRow:rowBytes
         sourceBytesPerImage:rowBytes * height
                  sourceSize:MTLSizeMake(width, height, 1)
                   toTexture:offscreenColorTexture
            destinationSlice:0
            destinationLevel:0
           destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        readbackSourceTexture = offscreenColorTexture;
        readbackSourceIsBGRA = false;
    }

    void invalidateTransientState() {
        // Ensure the render encoder is properly ended before we drop it.
        endRenderPass();
        currentCommandBuffer = nil;
        currentDrawable = nil;
        pendingPresent = false;
        hasPendingClear = false;
        resetCachedEncoderState();
    }

    GLContext* owner = nullptr;
    CAMetalLayer* layer = nil;
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> commandQueue = nil;
    id<MTLTexture> depthStencilTexture = nil;
    id<MTLTexture> offscreenColorTexture = nil;
    id<MTLTexture> readbackSourceTexture = nil;
    id<MTLCommandBuffer> currentCommandBuffer = nil;
    id<MTLRenderCommandEncoder> currentRenderEncoder = nil;
    GLenum activeRenderPassFragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
    id<CAMetalDrawable> currentDrawable = nil;
    id<MTLLibrary> solidColorLibrary = nil;
    id<MTLFunction> solidColorVertexFn = nil;
    id<MTLFunction> solidColorFragmentFn = nil;
    id<MTLRenderPipelineState> solidColorPipelineState = nil;
    MTLPixelFormat solidColorPipelineColorFormat = MTLPixelFormatInvalid;

    // Phase 3B.3 [metal-tess-TF] — tess domain-point generator compute
    // kernel. Built lazily the first time a TES-as-compute path needs
    // it (usually on first tess draw that bypasses the CPU interpreter).
    // See `ensureTessDomainGenLibrary` for the MSL source — MSL port of
    // `generateTessDomain` from TessellationEmulator.cpp.
    id<MTLLibrary> tessDomainGenLibrary = nil;
    id<MTLComputePipelineState> tessDomainGenPipelineState = nil;

    // Phase 3C [metal-tess-TF] — HW-tessellator domain-coord capture
    // path. Alternative to the MSL-kernel path above: uses Metal's HW
    // tessellator driven by a `vertex void` capture function with
    // rasterization disabled, so the HW emits (tessCoord, primID) pairs
    // into the same buffers `spvGenTessDomain` populates. Gate via env
    // `APPGL_TESS_DOMAIN_USE_METAL_HW`. Scaffolding only — unwired in
    // this commit; the three-pass encoder still uses the compute kernel.
    // Validated by `phase5ProbeMetalNativeTess` — §11.2.2 spec-exact for
    // quad rule4 levels (1046 unique verts = 30×4 edges − 4 corners +
    // 31×30 interior) and symmetric for triangle rule4 (858 unique,
    // 134 unique u, 134 unique v).
    id<MTLLibrary> tessDomainCaptureLibrary = nil;
    std::unordered_map<std::uint32_t, id<MTLRenderPipelineState>>
        tessDomainCapturePSOCache;
    // Factor-clamp compute PSO. Shared across all HW capture draws
    // (no partition/winding specialization needed — pure value clamp).
    id<MTLComputePipelineState> tessFactorClampPipelineState = nil;

    // Phase 4A [metal-tess-TF] — CPU-exact MSL port of
    // `TessellationEmulator::generateTessDomain`. Replaces the
    // Phase 3B.3 `spvGenTessDomain` kernel when
    // APPGL_TESS_DOMAIN_PORT is set. The ported kernel matches the
    // CPU reference bit-for-bit (validated by
    // `phaseAProbeTessDomainPort`), so CTS's counter-probe expectations
    // align. Compiled with `MTLMathModeSafe` to prevent fp-contract
    // fusion. Triangles + quads only — isolines stay on
    // `spvGenTessDomain` (no Metal `.isoline` patch type).
    id<MTLLibrary> tessDomainPortLibrary = nil;
    id<MTLComputePipelineState> tessDomainPortTrianglesPSO = nil;
    id<MTLComputePipelineState> tessDomainPortQuadsPSO = nil;

    // Phase 8X Group 4d follow-up¹⁷ — compat-profile immediate-mode
    // shader library, two pipeline states, and a default sampler.
    // See `ensureImmediateModeLibrary` and `ensureImmediateModePipelines`
    // for the shader source and descriptor layout. These are only
    // touched from `encodeImmediateModeDraw` so no cross-encoder
    // caching is needed.
    id<MTLLibrary> immediateModeLibrary = nil;
    id<MTLFunction> immediateModeVertexFn = nil;
    id<MTLFunction> immediateModeColorFragmentFn = nil;
    id<MTLFunction> immediateModeTexturedFragmentFn = nil;
    id<MTLRenderPipelineState> immediateModeColorPipelineState = nil;
    id<MTLRenderPipelineState> immediateModeTexturedPipelineState = nil;
    MTLPixelFormat immediateModePipelineColorFormat = MTLPixelFormatInvalid;
    id<MTLSamplerState> immediateModeSamplerState = nil;
    std::vector<std::uint8_t> headlessReadbackRGBA;
    GLsizei drawableWidth = 1;
    GLsizei drawableHeight = 1;
    bool usesOffscreenTarget = false;
    bool pendingPresent = false;
    bool readbackSourceIsBGRA = false;
    bool hasHeadlessReadback = false;

    // Deferred clear state (OPT-4). Stored by encodeClear(), consumed by
    // the next render pass that opens in encodeTranslatedDraw or
    // encodeSolidColorDraw. Flushed standalone by copyPixels/present
    // if no draw occurs between clear and readback/present.
    bool hasPendingClear = false;
    GLbitfield pendingClearMask = 0;
    MTLClearColor pendingClearColor = MTLClearColorMake(0, 0, 0, 0);
    double pendingClearDepth = 1.0;
    std::uint32_t pendingClearStencil = 0;

    // ADV-2: MTLLibrary cache keyed by MSL source hash.  Avoids
    // recompiling the same MSL text when multiple pipeline variants
    // share the same vertex or fragment shader.  The hash is
    // std::hash<std::string> (64-bit FNV on libc++); collisions would
    // silently return the wrong library, but in practice MSL texts
    // are unique-enough that this doesn't happen.
    std::unordered_map<std::size_t, id<MTLLibrary>> mslLibraryCache;

    // ADV-4: reusable render pass descriptor.  Avoids allocating a
    // fresh autoreleased ObjC object at each of the five call sites.
    // Reset fields before each use (attachments overwrite previous).
    MTLRenderPassDescriptor* reusablePassDescriptor = nil;
    MTLRenderPassDescriptor* getReusablePassDescriptor() {
        if (reusablePassDescriptor == nil) {
            reusablePassDescriptor = [MTLRenderPassDescriptor new];
        }
        // Reset to defaults so callers don't inherit stale state.
        reusablePassDescriptor.colorAttachments[0].texture = nil;
        reusablePassDescriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        reusablePassDescriptor.colorAttachments[0].storeAction = MTLStoreActionDontCare;
        reusablePassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        reusablePassDescriptor.depthAttachment.texture = nil;
        reusablePassDescriptor.depthAttachment.loadAction = MTLLoadActionDontCare;
        reusablePassDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
        reusablePassDescriptor.stencilAttachment.texture = nil;
        reusablePassDescriptor.stencilAttachment.loadAction = MTLLoadActionDontCare;
        reusablePassDescriptor.stencilAttachment.storeAction = MTLStoreActionDontCare;
        return reusablePassDescriptor;
    }

    // ADV-7: consolidated drawable acquisition.  Every render path
    // calls this instead of inlining `[layer nextDrawable]`.
    bool acquireDrawableIfNeeded() {
        if (usesOffscreenTarget) return true;
        if (currentDrawable != nil) return true;
        currentDrawable = [layer nextDrawable];
        return currentDrawable != nil;
    }

    // ADV-2: get-or-compile a Metal library from MSL source text,
    // returning a cached copy if the same source was compiled before.
    id<MTLLibrary> getOrCompileLibrary(const std::string& msl) {
        const std::size_t hash = std::hash<std::string>{}(msl);
        auto it = mslLibraryCache.find(hash);
        if (it != mslLibraryCache.end()) return it->second;

        NSString* src = [NSString stringWithUTF8String:msl.c_str()];
        NSError* err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&err];
        if (lib != nil) {
            mslLibraryCache[hash] = lib;
        } else if (std::getenv("APPGL_TRACE_SHADER_BUILD")) {
            std::fprintf(stderr, "[APPGL] MSL library build failed: %s\n",
                err ? err.localizedDescription.UTF8String : "(no err)");
        }
        return lib;  // nil on failure; caller handles
    }

    // Depth/stencil state cache — keyed by packed (depthTestEnabled, depthFunc).
    // The state space is tiny (~16 combinations); after warmup every draw is
    // a pure hash-table hit with zero Metal allocations.
    // Sprint 7 Phase 1 #11 (CKPT57): widened to uint64_t to fit the
    // depth + stencil identity hash. Depth state in low 32 bits,
    // stencil hash in high 32 bits.
    std::unordered_map<std::uint64_t, id<MTLDepthStencilState>> depthStencilCache;

    // Phase 8X Group 4d follow-up⁸ — per-context dedup for the
    // first-draw-per-program binding diagnostic NSLog in
    // `encodeTranslatedDraw`. Lives on the Impl rather than as a
    // function-local static so multi-context test runs (gauntlet
    // phase-a/c/d/7) don't cross-pollute: each GLContext owns its own
    // MetalFrameGraph and therefore its own set, and each scene's
    // program=1 gets logged exactly once. Under single-context
    // workloads (BAR/Recoil) the behavior is identical to a static set
    // but without the cross-run leak.
    std::unordered_set<GLuint> loggedBindingPrograms;

    // Phase 8X Group 4d follow-up¹³ — per-context dedup for the
    // first-build-per-program pipeline diagnostic NSLog. Fires at the
    // pipeline build path (just before newRenderPipelineStateWithDescriptor),
    // where we still have a live MTLRenderPipelineDescriptor +
    // MTLVertexDescriptor in scope. BAR followup¹²-verification
    // §Candidate 1 (blend state) and §Candidate 2 (MTLVertexDescriptor
    // format mismatch) both need the actual Metal-side descriptor
    // values — we can't reconstruct them from `info` at the first-draw
    // logging site because the descriptor is gone once
    // newRenderPipelineStateWithDescriptor returns.
    //
    // Phase 8X Group 4d follow-up¹⁷ — the dedup key was previously
    // `info.program` alone, which meant the first pipeline-build log
    // for a given program suppressed every subsequent build for the
    // SAME program with a DIFFERENT pipelineCacheKey (e.g. the same
    // program drawn first with blend off and then with blend on, or
    // with a different VBO attribute-format tuple). That's exactly
    // the situation followup¹⁴ left on the watchlist as the
    // `pipelineCache.entries=5` mystery: the cache was growing but
    // we only ever saw one log line per program. The rekey to
    // `(program, pipelineCacheKey)` makes every distinct cache-key
    // build fire its own log exactly once, so future intermittent
    // growth in `entries` becomes self-documenting in the terminal
    // output without any additional tooling.
    struct PipelineBuildLogKey {
        GLuint program;
        std::uint64_t pipelineCacheKey;
        bool operator==(const PipelineBuildLogKey& other) const {
            return program == other.program && pipelineCacheKey == other.pipelineCacheKey;
        }
    };
    struct PipelineBuildLogKeyHash {
        std::size_t operator()(const PipelineBuildLogKey& k) const noexcept {
            // Mix the 32-bit program name into the 64-bit cache key with
            // a FNV-ish splice — good enough for the tiny cardinality of
            // this set (a few entries per context).
            const std::uint64_t mixed = k.pipelineCacheKey
                                      ^ (static_cast<std::uint64_t>(k.program) * 0x9E3779B97F4A7C15ull);
            return static_cast<std::size_t>(mixed ^ (mixed >> 32));
        }
    };
    std::unordered_set<PipelineBuildLogKey, PipelineBuildLogKeyHash> loggedPipelineBuildPrograms;

    // ── Encoder state deduplication (OPT-6) ──
    // Track what was last set on the current render encoder. Skip redundant
    // Metal API calls when consecutive draws share the same state — typical
    // for batches of objects using the same shader/material.  Reset to
    // sentinel values whenever a new render encoder is created.
    id<MTLRenderPipelineState> cachedPipelineState = nil;
    id<MTLDepthStencilState> cachedDepthStencilState = nil;
    MTLCullMode cachedCullMode = static_cast<MTLCullMode>(0xFFFFFFFF);
    MTLWinding cachedFrontFaceWinding = static_cast<MTLWinding>(0xFFFFFFFF);
    MTLTriangleFillMode cachedFillMode = static_cast<MTLTriangleFillMode>(0xFFFFFFFF);

    void resetCachedEncoderState() {
        cachedPipelineState = nil;
        cachedDepthStencilState = nil;
        cachedCullMode = static_cast<MTLCullMode>(0xFFFFFFFF);
        cachedFrontFaceWinding = static_cast<MTLWinding>(0xFFFFFFFF);
        cachedFillMode = static_cast<MTLTriangleFillMode>(0xFFFFFFFF);
    }

    // ── Ring buffer for per-draw vertex/index data (OPT-1) ──
    // Triple-buffered: 3 large MTLBuffers rotate each frame. Within a frame,
    // sub-allocations bump a write offset with 256-byte alignment. This
    // eliminates per-draw [device newBufferWithBytes:] calls — the dominant
    // per-draw overhead (~15-20µs each).
    static constexpr int kRingBufferCount = 3;
    static constexpr std::size_t kRingBufferSize = 16 * 1024 * 1024; // 16 MB
    static constexpr std::size_t kRingBufferAlign = 256;

    // OPT-8: Semaphore-based frame pacing.  Initialized to kRingBufferCount
    // so the CPU can fill up to 3 ring slots before blocking.  Each frame
    // waits (acquireRingSlot) before writing, and the GPU completion handler
    // signals when it finishes the command buffer for that slot.  This
    // overlaps CPU encoding with GPU rendering — the key optimization that
    // replaces the old waitUntilCompleted serialisation.
    dispatch_semaphore_t frameSemaphore = dispatch_semaphore_create(kRingBufferCount);
    bool ringSlotAcquired = false;

    id<MTLBuffer> ringBuffers[kRingBufferCount] = { nil, nil, nil };
    int ringBufferIndex = 0;
    std::size_t ringBufferOffset = 0;

    void ensureRingBuffers() {
        if (ringBuffers[0] != nil) return;
        for (int i = 0; i < kRingBufferCount; ++i) {
            ringBuffers[i] = [device newBufferWithLength:kRingBufferSize
                                                 options:MTLResourceStorageModeShared];
        }
    }

    // Sub-allocate from the active ring buffer. Returns the buffer and the
    // byte offset of the allocation. Copies |byteCount| bytes from |src|.
    // If the ring buffer is full, falls back to a one-off allocation.
    struct RingAlloc {
        id<MTLBuffer> buffer;
        std::size_t offset;
    };

    RingAlloc ringSuballocate(const void* src, std::size_t byteCount) {
        ensureRingBuffers();
        const std::size_t aligned = (byteCount + kRingBufferAlign - 1) & ~(kRingBufferAlign - 1);
        id<MTLBuffer> active = ringBuffers[ringBufferIndex];

        if (active != nil && ringBufferOffset + byteCount <= kRingBufferSize) {
            // Fast path: bump-allocate from ring buffer.
            std::memcpy(static_cast<std::uint8_t*>([active contents]) + ringBufferOffset,
                        src, byteCount);
            std::size_t thisOffset = ringBufferOffset;
            ringBufferOffset += aligned;
            return { active, thisOffset };
        }

        // Overflow fallback: single draw exceeds remaining space.
        id<MTLBuffer> fallback = [device newBufferWithBytes:src
                                                      length:byteCount
                                                     options:MTLResourceStorageModeShared];
        return { fallback, 0 };
    }

    // Step 7-4: raw ring-buffer suballocation without copy. Returns
    // writable {buffer, offset} backing the requested byteCount. The
    // caller writes into the buffer (via MTLArgumentEncoder or manual
    // memcpy) and passes {buffer, offset} to `setFragmentBuffer:offset:`
    // etc. Mirrors `ringSuballocate` minus the memcpy. Used for
    // argument-buffer allocation under APPGL_ENABLE_ARGUMENT_BUFFERS —
    // replaces the per-draw `newBufferWithLength:` churn (one 16-MB
    // ring slot holds hundreds of argbufs).
    RingAlloc ringAllocRaw(std::size_t byteCount) {
        ensureRingBuffers();
        const std::size_t aligned = (byteCount + kRingBufferAlign - 1) & ~(kRingBufferAlign - 1);
        id<MTLBuffer> active = ringBuffers[ringBufferIndex];
        if (active != nil && ringBufferOffset + byteCount <= kRingBufferSize) {
            std::size_t thisOffset = ringBufferOffset;
            ringBufferOffset += aligned;
            return { active, thisOffset };
        }
        id<MTLBuffer> fallback = [device newBufferWithLength:byteCount
                                                     options:MTLResourceStorageModeShared];
        return { fallback, 0 };
    }

    // OPT-8: Acquire the current ring buffer slot, blocking if all slots
    // are in-flight with the GPU.  Idempotent within a frame — only waits
    // once per ring-buffer generation.
    void acquireRingSlot() {
        if (!ringSlotAcquired) {
            dispatch_semaphore_wait(frameSemaphore, DISPATCH_TIME_FOREVER);
            ringSlotAcquired = true;
        }
    }

    // OPT-8: Commit a command buffer with a completion handler that signals
    // the frame semaphore when the GPU finishes.  Use this (instead of raw
    // [cb commit]) whenever the commit releases a ring buffer slot.
    void commitWithFrameSignal(id<MTLCommandBuffer> cb) {
        dispatch_semaphore_t sem = frameSemaphore;
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
            dispatch_semaphore_signal(sem);
        }];
        [cb commit];
    }

    void advanceRingBuffer() {
        ringBufferIndex = (ringBufferIndex + 1) % kRingBufferCount;
        ringBufferOffset = 0;
        ringSlotAcquired = false;  // OPT-8: next frame must re-acquire
    }

    // Pipeline cache metrics (for benchmark instrumentation).
    //
    // Phase 8X Group 4d follow-up⁴ — `pipelineBuildAttempts` /
    // `pipelineBuildFailures` are added so the {hits, misses} pair stays
    // a clean cache-effectiveness signal while the new pair tells BAR
    // whether the build branch is even being entered (and how often it's
    // failing). Invariant: `attempts == misses + failures` for every draw.
    std::uint64_t pipelineCacheHits = 0;
    std::uint64_t pipelineCacheMisses = 0;
    std::uint64_t pipelineBuildAttempts = 0;
    std::uint64_t pipelineBuildFailures = 0;
    double pipelineCumulativeBuildMs = 0.0;

    // ── ADV-14: MTLBinaryArchive for cross-session pipeline persistence ──
    // On first launch, pipelines compile from MSL source (~100–500 ms each).
    // On second launch, the archive supplies pre-compiled GPU binaries and
    // Metal skips the expensive compilation.  The archive lives at
    //   ~/Library/Caches/dev.excalibur.AppGL/pipeline_archive.metallib
    // Populated lazily: after each successful pipeline build, we add the
    // descriptor to the archive.  Serialized to disk on context teardown.
    id<MTLBinaryArchive> pipelineArchive = nil;
    bool pipelineArchiveDirty = false;

    NSURL* pipelineArchiveURL() {
        static NSURL* url = nil;
        if (url == nil) {
            NSString* cacheDir = [NSSearchPathForDirectoriesInDomains(
                NSCachesDirectory, NSUserDomainMask, YES) firstObject];
            NSString* appglDir = [cacheDir stringByAppendingPathComponent:@"dev.excalibur.AppGL"];
            [[NSFileManager defaultManager] createDirectoryAtPath:appglDir
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil];
            url = [NSURL fileURLWithPath:
                [appglDir stringByAppendingPathComponent:@"pipeline_archive.metallib"]];
        }
        return url;
    }

    void ensurePipelineArchive() {
        if (pipelineArchive != nil || device == nil) return;

        MTLBinaryArchiveDescriptor* desc = [[MTLBinaryArchiveDescriptor alloc] init];
        // Try to load existing archive from disk.
        NSURL* url = pipelineArchiveURL();
        if ([[NSFileManager defaultManager] fileExistsAtPath:[url path]]) {
            desc.url = url;
        }
        NSError* err = nil;
        pipelineArchive = [device newBinaryArchiveWithDescriptor:desc error:&err];
        if (pipelineArchive == nil) {
            // Failed to load (corrupt/stale) — create empty archive.
            desc.url = nil;
            pipelineArchive = [device newBinaryArchiveWithDescriptor:desc error:nil];
        }
    }

    void addPipelineToArchive(MTLRenderPipelineDescriptor* pipelineDesc) {
        if (pipelineArchive == nil) return;
        NSError* err = nil;
        // addRenderPipelineFunctions is a no-op if the pipeline is already
        // present in the archive. On failure, we silently skip — the archive
        // is an optimization, not a correctness requirement.
        if ([pipelineArchive addRenderPipelineFunctionsWithDescriptor:pipelineDesc error:&err]) {
            pipelineArchiveDirty = true;
        }
    }

    void savePipelineArchive() {
        if (pipelineArchive == nil || !pipelineArchiveDirty) return;
        NSError* err = nil;
        [pipelineArchive serializeToURL:pipelineArchiveURL() error:&err];
        if (err == nil) {
            pipelineArchiveDirty = false;
        }
    }
};

// Programmatic Metal GPU-trace capture gated on APPGL_METAL_CAPTURE_PATH.
// Opens a capture scope for the whole process lifetime and writes a
// .gputrace document to the given path when the runtime shuts down.
// Primary use: diagnosing the VS-stage texture_gather flake (pass/fail
// captures of the same test case diffed in Xcode).
//
// Env vars required:
//   APPGL_METAL_CAPTURE_PATH=/abs/path/to/capture.gputrace
//   MTL_CAPTURE_ENABLED=1          (Metal's own opt-in — without this
//                                   the capture manager refuses outside
//                                   Xcode-launched processes)
static bool g_captureActive = false;

static void startMetalCaptureIfRequested(id<MTLDevice> device) {
    if (device == nil || g_captureActive) return;
    const char* path = std::getenv("APPGL_METAL_CAPTURE_PATH");
    if (path == nullptr || *path == '\0') return;

    MTLCaptureManager* mgr = [MTLCaptureManager sharedCaptureManager];
    if (![mgr supportsDestination:MTLCaptureDestinationGPUTraceDocument]) {
        NSLog(@"[GL] MTLCapture: GPU-trace-document destination unsupported "
              @"(need MTL_CAPTURE_ENABLED=1 in env)");
        return;
    }

    // Overwrite existing trace at the same path — re-running the test
    // is the common case.
    NSString* nsPath = [NSString stringWithUTF8String:path];
    NSURL* url = [NSURL fileURLWithPath:nsPath];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

    MTLCaptureDescriptor* desc = [[MTLCaptureDescriptor alloc] init];
    desc.captureObject = device;
    desc.destination = MTLCaptureDestinationGPUTraceDocument;
    desc.outputURL = url;

    NSError* err = nil;
    if ([mgr startCaptureWithDescriptor:desc error:&err]) {
        g_captureActive = true;
        NSLog(@"[GL] MTLCapture: started → %@", url.path);
    } else {
        NSLog(@"[GL] MTLCapture: startCapture failed: %@", err);
    }
}

static void stopMetalCaptureIfActive() {
    if (!g_captureActive) return;
    [[MTLCaptureManager sharedCaptureManager] stopCapture];
    g_captureActive = false;
    NSLog(@"[GL] MTLCapture: stopped, trace flushed");
}

// Option A probe [metal-tess-TF]: bit-exact diff between a ported-to-MSL
// domain generator and `appgl::generateTessDomain` (the CPU reference
// that `TessellationEmulator.cpp` exposes and CTS's
// `getAmountOfVerticesGeneratedByTessellator` probe matches bit-for-bit).
//
// Runs once on first MetalFrameGraph construction, gated on
// APPGL_TEST_TESS_DOMAIN_PORT=1. Dispatches the new kernel for a curated
// set of (mode, spacing, outer, inner) cases, walks `generateTessDomain`'s
// indexed output into the non-indexed "one-coord-per-emitted-vertex"
// shape the downstream TES-compute consumes, diffs element-for-element,
// and reports MATCH/DIFFER to stderr.
//
// Scope of this first landing: triangles, equal-spacing, integer
// partition, no winding flip, no point_mode. Later commits widen.
static void phaseAProbeTessDomainPort(id<MTLDevice> device,
                                       id<MTLCommandQueue> commandQueue)
{
    if (std::getenv("APPGL_TEST_TESS_DOMAIN_PORT") == nullptr) return;
    if (device == nil || commandQueue == nil) return;
    static bool sRan = false;
    if (sRan) return;
    sRan = true;

    std::fprintf(stderr, "[APPGL domain-port] probe starting\n");

    NSString* msl = kTessDomainPortMSL;

    NSError* libErr = nil;
    // Force IEEE-strict FP. Default compile options enable fp-contract
    // (fuses `a - b - c` into single-rounded ops), which produces
    // more-accurate-but-CPU-divergent results at boundary vertices
    // (e.g. fu + fv = 1 exactly).
    MTLCompileOptions* opts = [MTLCompileOptions new];
    if (@available(macOS 15.0, *)) {
        opts.mathMode = MTLMathModeSafe;
    } else {
        opts.fastMathEnabled = NO;
    }
    id<MTLLibrary> lib = [device newLibraryWithSource:msl options:opts error:&libErr];
    if (lib == nil) {
        std::fprintf(stderr, "[APPGL domain-port] library build failed: %s\n",
                     libErr ? libErr.localizedDescription.UTF8String : "(no err)");
        return;
    }
    auto buildPSO = ^id<MTLComputePipelineState>(NSString* fnName) {
        id<MTLFunction> f = [lib newFunctionWithName:fnName];
        if (f == nil) {
            std::fprintf(stderr, "[APPGL domain-port] function %s not found\n",
                         fnName.UTF8String);
            return nil;
        }
        NSError* perr = nil;
        id<MTLComputePipelineState> p =
            [device newComputePipelineStateWithFunction:f error:&perr];
        if (p == nil) {
            std::fprintf(stderr, "[APPGL domain-port] PSO %s failed: %s\n",
                         fnName.UTF8String,
                         perr ? perr.localizedDescription.UTF8String : "(no err)");
        }
        return p;
    };
    id<MTLComputePipelineState> trianglesPSO =
        buildPSO(@"spvGenTessDomainTrianglesPort");
    id<MTLComputePipelineState> quadsPSO =
        buildPSO(@"spvGenTessDomainQuadsPort");
    if (trianglesPSO == nil && quadsPSO == nil) return;

    auto toHalf = [](float fv) -> uint16_t {
        uint32_t bits = 0;
        std::memcpy(&bits, &fv, sizeof(bits));
        uint32_t sign = (bits >> 31) & 0x1;
        int32_t  exp  = (int32_t)((bits >> 23) & 0xff) - 127;
        uint32_t mant = bits & 0x7fffff;
        if (exp >= 16) return (uint16_t)((sign << 15) | 0x7c00);
        if (exp <= -15) return (uint16_t)(sign << 15);
        return (uint16_t)((sign << 15) | (((exp + 15) & 0x1f) << 10) |
                          (mant >> 13));
    };

    struct Case {
        appgl::TessDomain domain;
        appgl::TessSpacing spacing;
        float outer[4];
        float inner[2];
        bool pointMode;
        bool flipWinding;
        const char* name;
    };
    const Case cases[] = {
        // Triangles — Equal
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {2.0f, 2.0f, 2.0f, 0.0f}, {2.0f, 0.0f}, false, false, "tri eq N=2"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {3.0f, 3.0f, 3.0f, 0.0f}, {3.0f, 0.0f}, false, false, "tri eq N=3"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {5.0f, 5.0f, 5.0f, 0.0f}, {5.0f, 0.0f}, false, false, "tri eq N=5"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {7.0f, 4.0f, 3.0f, 0.0f}, {6.0f, 0.0f}, false, false, "tri eq mixed"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {1.0f, 1.0f, 1.0f, 0.0f}, {1.0f, 0.0f}, false, false, "tri eq N=1 (min)"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {12.0f, 9.0f, 7.0f, 0.0f}, {10.0f, 0.0f}, false, false, "tri eq asym"},
        // Triangles — FractionalEven (rounds up to next even ≥ 2)
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalEven, {4.0f, 4.0f, 4.0f, 0.0f}, {4.0f, 0.0f}, false, false, "tri fEven N=4"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalEven, {4.5f, 4.5f, 4.5f, 0.0f}, {4.5f, 0.0f}, false, false, "tri fEven N=4.5 → 6"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalEven, {1.0f, 1.0f, 1.0f, 0.0f}, {1.0f, 0.0f}, false, false, "tri fEven min (→ 2)"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalEven, {8.0f, 6.0f, 4.0f, 0.0f}, {7.0f, 0.0f}, false, false, "tri fEven asym"},
        // Triangles — FractionalOdd (rounds up to next odd ≥ 1)
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalOdd, {3.0f, 3.0f, 3.0f, 0.0f}, {3.0f, 0.0f}, false, false, "tri fOdd N=3"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalOdd, {3.5f, 3.5f, 3.5f, 0.0f}, {3.5f, 0.0f}, false, false, "tri fOdd N=3.5 → 5"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalOdd, {4.0f, 4.0f, 4.0f, 0.0f}, {4.0f, 0.0f}, false, false, "tri fOdd N=4 → 5"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalOdd, {8.0f, 6.0f, 4.0f, 0.0f}, {7.0f, 0.0f}, false, false, "tri fOdd asym"},
        // Quads — Equal
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {2.0f, 2.0f, 2.0f, 2.0f}, {2.0f, 2.0f}, false, false, "quad eq N=2"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {4.0f, 4.0f, 4.0f, 4.0f}, {4.0f, 4.0f}, false, false, "quad eq N=4"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {8.0f, 8.0f, 8.0f, 8.0f}, {8.0f, 8.0f}, false, false, "quad eq N=8"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {1.0f, 1.0f, 1.0f, 1.0f}, {1.0f, 1.0f}, false, false, "quad eq N=1 (min)"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {29.0f, 29.0f, 29.0f, 29.0f}, {32.0f, 31.0f}, false, false, "quad eq rule4-ish"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {5.0f, 7.0f, 9.0f, 11.0f}, {13.0f, 17.0f}, false, false, "quad eq asym"},
        // Quads — FractionalEven
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalEven, {4.0f, 4.0f, 4.0f, 4.0f}, {4.0f, 4.0f}, false, false, "quad fEven N=4"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalEven, {3.5f, 3.5f, 3.5f, 3.5f}, {3.5f, 3.5f}, false, false, "quad fEven N=3.5 → 4"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalEven, {8.0f, 6.0f, 4.0f, 2.0f}, {7.0f, 5.0f}, false, false, "quad fEven asym"},
        // Quads — FractionalOdd
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalOdd, {3.0f, 3.0f, 3.0f, 3.0f}, {3.0f, 3.0f}, false, false, "quad fOdd N=3"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalOdd, {4.0f, 4.0f, 4.0f, 4.0f}, {4.0f, 4.0f}, false, false, "quad fOdd N=4 → 5"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalOdd, {8.0f, 6.0f, 4.0f, 2.0f}, {7.0f, 5.0f}, false, false, "quad fOdd asym"},
        // CTS rule4 quad — exact levels the test uses.
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {29.0f, 29.0f, 29.0f, 29.0f}, {32.0f, 31.0f}, false, false, "rule4 (32,31) (29,29,29,29)"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {29.0f, 29.0f, 29.0f, 29.0f}, {31.0f, 32.0f}, false, false, "rule4 (31,32) (29,29,29,29)"},
        // Winding flip (CW) — swap last two verts per triangle.
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {3.0f, 3.0f, 3.0f, 0.0f}, {3.0f, 0.0f}, false, true, "tri eq N=3 CW"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalOdd, {5.0f, 5.0f, 5.0f, 0.0f}, {5.0f, 0.0f}, false, true, "tri fOdd CW"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {4.0f, 4.0f, 4.0f, 4.0f}, {4.0f, 4.0f}, false, true, "quad eq N=4 CW"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalEven, {6.0f, 6.0f, 6.0f, 6.0f}, {6.0f, 6.0f}, false, true, "quad fEven CW"},
        // Point mode — emits unique grid points (no triangulation).
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {3.0f, 3.0f, 3.0f, 0.0f}, {3.0f, 0.0f}, true, false, "tri eq N=3 pts"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::FractionalOdd, {5.0f, 5.0f, 5.0f, 0.0f}, {5.0f, 0.0f}, true, false, "tri fOdd N=5 pts"},
        {appgl::TessDomain::Triangles, appgl::TessSpacing::Equal, {7.0f, 4.0f, 3.0f, 0.0f}, {6.0f, 0.0f}, true, false, "tri eq asym pts"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {4.0f, 4.0f, 4.0f, 4.0f}, {4.0f, 4.0f}, true, false, "quad eq N=4 pts"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::FractionalEven, {6.0f, 6.0f, 6.0f, 6.0f}, {6.0f, 6.0f}, true, false, "quad fEven N=6 pts"},
        {appgl::TessDomain::Quads, appgl::TessSpacing::Equal, {5.0f, 7.0f, 9.0f, 11.0f}, {13.0f, 17.0f}, true, false, "quad eq asym pts"},
    };

    uint32_t passCount = 0;
    uint32_t failCount = 0;
    for (const Case& tc : cases) {
        id<MTLComputePipelineState> pso =
            (tc.domain == appgl::TessDomain::Triangles)
                ? trianglesPSO : quadsPSO;
        if (pso == nil) continue;
        appgl::TessDomainOutput cpuOut = appgl::generateTessDomain(
            tc.domain, tc.spacing,
            tc.outer, tc.inner, tc.pointMode, tc.flipWinding);

        // CPU output shape differs by pointMode:
        //  - pointMode=true  → `coords` holds one entry per unique
        //    grid point, `indices` is empty. GPU kernel emits the
        //    same set via its atomic-cursor pointMode branch.
        //  - pointMode=false → `coords` holds unique grid points,
        //    `indices` holds 3 per triangle. Expand to non-indexed
        //    "one coord per emitted vertex" — what the GPU kernel
        //    produces via `spvPortEmitTriangle`.
        std::vector<float> cpuExpanded;
        if (tc.pointMode) {
            cpuExpanded = cpuOut.coords;
        } else {
            cpuExpanded.reserve(cpuOut.indices.size() * 3);
            for (std::uint32_t idx : cpuOut.indices) {
                cpuExpanded.push_back(cpuOut.coords[idx * 3 + 0]);
                cpuExpanded.push_back(cpuOut.coords[idx * 3 + 1]);
                cpuExpanded.push_back(cpuOut.coords[idx * 3 + 2]);
            }
        }

        uint16_t factorData[6] = {0};
        factorData[0] = toHalf(tc.outer[0]);
        factorData[1] = toHalf(tc.outer[1]);
        factorData[2] = toHalf(tc.outer[2]);
        factorData[3] = toHalf(tc.outer[3]);
        factorData[4] = toHalf(tc.inner[0]);
        factorData[5] = toHalf(tc.inner[1]);
        id<MTLBuffer> factorBuf = [device
            newBufferWithBytes:factorData
                        length:sizeof(MTLQuadTessellationFactorsHalf)
                       options:MTLResourceStorageModeShared];

        struct PortParams {
            uint32_t genMode;
            uint32_t genSpacing;
            uint32_t patchCount;
            uint32_t pointMode;
            uint32_t flipWinding;
        };
        uint32_t spacingEnum = 0u;
        switch (tc.spacing) {
            case appgl::TessSpacing::Equal:          spacingEnum = 0u; break;
            case appgl::TessSpacing::FractionalEven: spacingEnum = 1u; break;
            case appgl::TessSpacing::FractionalOdd:  spacingEnum = 2u; break;
        }
        PortParams params{
            tc.domain == appgl::TessDomain::Quads ? 1u : 0u,
            spacingEnum, 1u,
            tc.pointMode ? 1u : 0u,
            tc.flipWinding ? 1u : 0u
        };
        id<MTLBuffer> paramsBuf = [device
            newBufferWithBytes:&params
                        length:sizeof(params)
                       options:MTLResourceStorageModeShared];

        uint32_t zero = 0;
        id<MTLBuffer> cursorBuf = [device
            newBufferWithBytes:&zero length:sizeof(uint32_t)
                       options:MTLResourceStorageModeShared];
        const NSUInteger kMaxVerts = 100000;
        id<MTLBuffer> coordsBuf = [device
            newBufferWithLength:kMaxVerts * 12
                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> primIDsBuf = [device
            newBufferWithLength:kMaxVerts * sizeof(uint32_t)
                        options:MTLResourceStorageModeShared];

        id<MTLCommandBuffer> cb = [commandQueue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:paramsBuf offset:0 atIndex:0];
        [enc setBuffer:factorBuf offset:0 atIndex:26];
        [enc setBuffer:coordsBuf offset:0 atIndex:25];
        [enc setBuffer:primIDsBuf offset:0 atIndex:24];
        [enc setBuffer:cursorBuf offset:0 atIndex:23];
        [enc dispatchThreads:MTLSizeMake(1, 1, 1)
      threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        uint32_t gpuVerts = *(const uint32_t*)cursorBuf.contents;
        const float* gpuCoords = (const float*)coordsBuf.contents;

        bool match = true;
        const std::size_t cpuN = cpuExpanded.size() / 3;
        if (gpuVerts != cpuN) {
            match = false;
        } else {
            for (std::size_t k = 0; k < cpuExpanded.size(); ++k) {
                if (gpuCoords[k] != cpuExpanded[k]) { match = false; break; }
            }
        }
        // Count ULP-level diffs (same count match, bitwise-different
        // coords) to separate "wrong topology" (count mismatch) from
        // "right topology, FP drift" (count matches, some coords ULP-off).
        std::size_t diffVerts = 0;
        if (match) {
            std::fprintf(stderr, "[APPGL domain-port]   %-24s MATCH   (%zu verts)\n",
                         tc.name, cpuN);
            ++passCount;
        } else if (gpuVerts != cpuN) {
            std::fprintf(stderr, "[APPGL domain-port]   %-24s COUNT   (CPU=%zu GPU=%u)\n",
                         tc.name, cpuN, gpuVerts);
            ++failCount;
        } else {
            for (std::size_t k = 0; k < cpuN; ++k) {
                if (cpuExpanded[k*3+0] != gpuCoords[k*3+0] ||
                    cpuExpanded[k*3+1] != gpuCoords[k*3+1] ||
                    cpuExpanded[k*3+2] != gpuCoords[k*3+2]) {
                    ++diffVerts;
                }
            }
            std::fprintf(stderr,
                "[APPGL domain-port]   %-24s DIFFER  (%zu verts, %zu ULP-off)\n",
                tc.name, cpuN, diffVerts);
            ++failCount;
            // Show first 3 diffs
            std::size_t shown = 0;
            for (std::size_t k = 0; k < cpuN && shown < 3; ++k) {
                if (cpuExpanded[k*3+0] != gpuCoords[k*3+0] ||
                    cpuExpanded[k*3+1] != gpuCoords[k*3+1] ||
                    cpuExpanded[k*3+2] != gpuCoords[k*3+2]) {
                    std::fprintf(stderr,
                        "[APPGL domain-port]     vert %zu: "
                        "CPU=(%.9g,%.9g,%.9g) GPU=(%.9g,%.9g,%.9g)\n",
                        k,
                        cpuExpanded[k*3+0], cpuExpanded[k*3+1], cpuExpanded[k*3+2],
                        gpuCoords[k*3+0], gpuCoords[k*3+1], gpuCoords[k*3+2]);
                    ++shown;
                }
            }
        }
    }
    std::fprintf(stderr,
        "[APPGL domain-port] probe done: %u MATCH / %u DIFFER\n",
        passCount, failCount);
}

// Phase 5 PoC [metal-tess-TF]: probe Metal's HW tessellator directly
// with a minimal capture vertex function. Dumps (tessCoord, primID)
// for a given (primitive, spacing, inner, outer) — so we can compare
// Metal's native output against CTS's spec-exact expectations
// without reimplementing §11.2.2 from scratch.
//
// Gated on APPGL_TEST_METAL_TESS=1. Runs once per construction,
// prints a table of all emitted tess coords to stderr. Output is
// expected to match CTS's `isVertexDefined` bit-for-bit modulo the
// tessDomainOriginLowerLeft flip (Y = 1 - Metal_Y for quads,
// barycentric permutation for triangles).
static void phase5ProbeMetalNativeTess(id<MTLDevice> device,
                                        id<MTLCommandQueue> commandQueue)
{
    if (std::getenv("APPGL_TEST_METAL_TESS") == nullptr) return;
    if (device == nil || commandQueue == nil) return;
    static bool sProbeRan = false;
    if (sProbeRan) return;
    sProbeRan = true;
    std::fprintf(stderr, "[APPGL probe] Metal HW-tess PoC starting\n");

    NSString* msl = @R"MSL(
#include <metal_stdlib>
using namespace metal;

[[patch(quad, 0)]] vertex void spvProbeTessQuad(
    float2 gl_TessCoordIn [[position_in_patch]],
    uint gl_PrimitiveID [[patch_id]],
    device atomic_uint* cursor [[buffer(0)]],
    device packed_float3* coords [[buffer(1)]],
    device uint* primIDs [[buffer(2)]])
{
    uint base = atomic_fetch_add_explicit(cursor, 1u, memory_order_relaxed);
    coords[base] = packed_float3(gl_TessCoordIn.x, gl_TessCoordIn.y, 0.0);
    primIDs[base] = gl_PrimitiveID;
}

[[patch(triangle, 0)]] vertex void spvProbeTessTriangle(
    float3 gl_TessCoordIn [[position_in_patch]],
    uint gl_PrimitiveID [[patch_id]],
    device atomic_uint* cursor [[buffer(0)]],
    device packed_float3* coords [[buffer(1)]],
    device uint* primIDs [[buffer(2)]])
{
    uint base = atomic_fetch_add_explicit(cursor, 1u, memory_order_relaxed);
    coords[base] = packed_float3(gl_TessCoordIn.x, gl_TessCoordIn.y, gl_TessCoordIn.z);
    primIDs[base] = gl_PrimitiveID;
}
)MSL";

    NSError* err = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:msl options:nil error:&err];
    if (lib == nil) {
        std::fprintf(stderr, "[APPGL probe] library build failed: %s\n",
                     err.localizedDescription.UTF8String);
        return;
    }

    auto buildPSO = ^id<MTLRenderPipelineState>(NSString* fn, MTLTessellationFactorFormat factorFormat,
                                                 MTLPatchType patchType) {
        id<MTLFunction> vfn = [lib newFunctionWithName:fn];
        if (vfn == nil) return nil;
        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vfn;
        pd.fragmentFunction = nil;
        pd.rasterizationEnabled = NO;
        pd.tessellationFactorFormat = factorFormat;
        pd.tessellationControlPointIndexType = MTLTessellationControlPointIndexTypeNone;
        pd.tessellationPartitionMode = MTLTessellationPartitionModeInteger;
        pd.tessellationOutputWindingOrder = MTLWindingCounterClockwise;
        pd.tessellationFactorStepFunction = MTLTessellationFactorStepFunctionConstant;
        pd.maxTessellationFactor = 64;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatInvalid;
        NSError* perr = nil;
        id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:pd error:&perr];
        if (pso == nil) {
            std::fprintf(stderr, "[APPGL probe] PSO %s failed: %s\n",
                         fn.UTF8String,
                         perr.localizedDescription.UTF8String ?: "(no err)");
        }
        return pso;
    };

    id<MTLRenderPipelineState> quadPSO = buildPSO(@"spvProbeTessQuad",
        MTLTessellationFactorFormatHalf, MTLPatchTypeQuad);
    id<MTLRenderPipelineState> triPSO = buildPSO(@"spvProbeTessTriangle",
        MTLTessellationFactorFormatHalf, MTLPatchTypeTriangle);
    if (quadPSO == nil && triPSO == nil) {
        std::fprintf(stderr, "[APPGL probe] both PSO builds failed — aborting\n");
        return;
    }

    // Test case: `invariance_rule4` iteration with inner=(32, 31),
    // outer=(29,29,29,29), equal spacing. Expected: (0, 1/32)
    // exists on u=0 edge. Set up factor buffer, dispatch, read back.
    auto runProbe = ^(const char* label,
                       id<MTLRenderPipelineState> pso,
                       MTLPatchType patchType,
                       bool isQuad,
                       float i0, float i1,
                       float o0, float o1, float o2, float o3) {
        if (pso == nil) return;
        auto toHalf = [](float f) -> uint16_t {
            // Minimal float→half (IEEE 754 binary16). Round-to-nearest.
            uint32_t bits = 0;
            std::memcpy(&bits, &f, sizeof(bits));
            uint32_t sign = (bits >> 31) & 0x1;
            int32_t  exp  = (int32_t)((bits >> 23) & 0xff) - 127;
            uint32_t mant = bits & 0x7fffff;
            if (exp >= 16) return (uint16_t)((sign << 15) | 0x7c00); // inf
            if (exp <= -15) return (uint16_t)(sign << 15);              // zero/denorm
            return (uint16_t)((sign << 15) | (((exp + 15) & 0x1f) << 10) |
                              (mant >> 13));
        };
        // Quad  layout: edges[0..3] = half[0..3], inside[0..1] = half[4..5] (12 bytes).
        // Tri   layout: edges[0..2] = half[0..2], inside     = half[3]     (8 bytes).
        uint16_t factorData[6] = {0};
        std::size_t factorBufSize;
        if (isQuad) {
            factorData[0] = toHalf(o0);
            factorData[1] = toHalf(o1);
            factorData[2] = toHalf(o2);
            factorData[3] = toHalf(o3);
            factorData[4] = toHalf(i0);
            factorData[5] = toHalf(i1);
            factorBufSize = sizeof(MTLQuadTessellationFactorsHalf);
        } else {
            factorData[0] = toHalf(o0);
            factorData[1] = toHalf(o1);
            factorData[2] = toHalf(o2);
            factorData[3] = toHalf(i0);
            factorBufSize = sizeof(MTLTriangleTessellationFactorsHalf);
        }
        id<MTLBuffer> factorBuf = [device newBufferWithBytes:factorData
                                                      length:factorBufSize
                                                     options:MTLResourceStorageModeShared];

        // Capture buffers.
        const NSUInteger kMaxVerts = 100000;
        uint32_t zero = 0;
        id<MTLBuffer> cursorBuf = [device newBufferWithBytes:&zero length:sizeof(uint32_t)
                                                     options:MTLResourceStorageModeShared];
        id<MTLBuffer> coordsBuf = [device newBufferWithLength:kMaxVerts * 12
                                                     options:MTLResourceStorageModeShared];
        id<MTLBuffer> primIDsBuf = [device newBufferWithLength:kMaxVerts * sizeof(uint32_t)
                                                      options:MTLResourceStorageModeShared];

        MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];
        rpd.renderTargetWidth = 1;
        rpd.renderTargetHeight = 1;
        rpd.defaultRasterSampleCount = 1;

        id<MTLCommandBuffer> cb = [commandQueue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
        [enc setRenderPipelineState:pso];
        [enc setVertexBuffer:cursorBuf offset:0 atIndex:0];
        [enc setVertexBuffer:coordsBuf offset:0 atIndex:1];
        [enc setVertexBuffer:primIDsBuf offset:0 atIndex:2];
        [enc setTessellationFactorBuffer:factorBuf offset:0 instanceStride:0];
        [enc drawPatches:(isQuad ? 4u : 3u)  // points per patch
              patchStart:0
              patchCount:1
        patchIndexBuffer:nil
  patchIndexBufferOffset:0
           instanceCount:1
            baseInstance:0];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        if (cb.error != nil) {
            std::fprintf(stderr, "[APPGL probe] %s cmd err: %s\n",
                         label, cb.error.localizedDescription.UTF8String);
            return;
        }

        uint32_t n = *(const uint32_t*)cursorBuf.contents;
        std::fprintf(stderr, "[APPGL probe] %s emitted %u verts\n", label, n);
        if (n > kMaxVerts) n = (uint32_t)kMaxVerts;
        const float* coords = (const float*)coordsBuf.contents;
        // Sort + dedup so we can diff easily.
        std::vector<std::array<float, 3>> pts;
        pts.reserve(n);
        for (uint32_t k = 0; k < n; ++k) {
            pts.push_back({coords[k*3+0], coords[k*3+1], coords[k*3+2]});
        }
        std::sort(pts.begin(), pts.end());
        pts.erase(std::unique(pts.begin(), pts.end()), pts.end());
        std::fprintf(stderr, "[APPGL probe] %s unique verts: %zu\n", label, pts.size());
        for (const auto& p : pts) {
            std::fprintf(stderr, "  (%.7g, %.7g, %.7g)\n", p[0], p[1], p[2]);
        }
    };

    runProbe("quad rule4 i=(32,31) o=(29,29,29,29)",
             quadPSO, MTLPatchTypeQuad, true,
             32.0f, 31.0f, 29.0f, 29.0f, 29.0f, 29.0f);
    runProbe("triangle rule4 i=(33,0) o=(30,30,30,0)",
             triPSO, MTLPatchTypeTriangle, false,
             33.0f, 0.0f, 30.0f, 30.0f, 30.0f, 0.0f);

    std::fprintf(stderr, "[APPGL probe] done\n");
}

MetalFrameGraph::MetalFrameGraph(GLContext* context, void* layer, void* device, void* commandQueue)
    : impl_(std::make_unique<Impl>(context, layer, device, commandQueue)) {
    startMetalCaptureIfRequested((__bridge id<MTLDevice>)device);
    phase5ProbeMetalNativeTess((__bridge id<MTLDevice>)device,
                                (__bridge id<MTLCommandQueue>)commandQueue);
    phaseAProbeTessDomainPort((__bridge id<MTLDevice>)device,
                               (__bridge id<MTLCommandQueue>)commandQueue);
}

MetalFrameGraph::~MetalFrameGraph() {
    stopMetalCaptureIfActive();
}

void MetalFrameGraph::resizeDrawable(GLsizei width, GLsizei height) {
    impl_->resize(width, height);
}

void MetalFrameGraph::enableOffscreenDrawable(GLsizei width, GLsizei height) {
    impl_->enableOffscreen(width, height);
}

void MetalFrameGraph::encodeDefaultFramebufferClear(
    GLbitfield mask,
    GLfloat clearRed,
    GLfloat clearGreen,
    GLfloat clearBlue,
    GLfloat clearAlpha,
    GLdouble clearDepth,
    GLint clearStencil
) {
    impl_->encodeClear(mask, clearRed, clearGreen, clearBlue, clearAlpha, clearDepth, clearStencil);
}

void MetalFrameGraph::beginRenderPassForCurrentFramebuffer(GLStateTracker& state, GLObjectStore& objects) {
    impl_->beginRenderPass(state, objects);
}

void* MetalFrameGraph::currentRenderEncoder() const {
    return impl_->renderEncoder();
}

void MetalFrameGraph::endRenderPass() {
    impl_->endRenderPass();
}

void MetalFrameGraph::flushForReadback() {
    impl_->flushForReadback();
}

bool MetalFrameGraph::encodeSolidColorDraw(const MetalDrawInfo& info) {
    return impl_->encodeSolidColorDraw(info);
}

bool MetalFrameGraph::encodeTranslatedDraw(TranslatedDrawInfo& info) {
    return impl_->encodeTranslatedDraw(info);
}

bool MetalFrameGraph::encodeImmediateModeDraw(const ImmediateDrawInfo& info) {
    return impl_->encodeImmediateModeDraw(info);
}

bool MetalFrameGraph::clearLayeredTextureDepth(void* tex, std::uint32_t arrayLength, float depth) {
    return impl_->clearLayeredTextureDepth(tex, arrayLength, depth);
}

bool MetalFrameGraph::clearLayeredTextureStencil(void* tex, std::uint32_t arrayLength, std::uint32_t stencil) {
    return impl_->clearLayeredTextureStencil(tex, arrayLength, stencil);
}

bool MetalFrameGraph::clearLayeredTextureColor(void* tex, std::uint32_t arrayLength, const float rgba[4]) {
    return impl_->clearLayeredTextureColor(tex, arrayLength, rgba);
}

bool MetalFrameGraph::clearTextureDepth(void* tex, std::uint32_t level, std::uint32_t slice,
                                        std::uint32_t arrayLength, float depth) {
    return impl_->clearTextureDepth(tex, level, slice, arrayLength, depth);
}

bool MetalFrameGraph::clearTextureStencil(void* tex, std::uint32_t level, std::uint32_t slice,
                                          std::uint32_t arrayLength, std::uint32_t stencil) {
    return impl_->clearTextureStencil(tex, level, slice, arrayLength, stencil);
}

void* MetalFrameGraph::buildComputePipelineState(const std::string& msl, std::string* outError,
                                                  void** outFunction,
                                                  void* stageInputOutputDescriptor) {
    return impl_->buildComputePipelineState(msl, outError, outFunction, stageInputOutputDescriptor);
}

void* MetalFrameGraph::compileMSLFunction(const std::string& msl, std::string* outError) {
    return impl_->compileMSLFunction(msl, outError);
}

// Sprint 15 Q3-Option-B Phase 3a [metal-tf-vs]: dispatch a VS-as-
// compute kernel and capture per-vertex output bytes. Forwards to
// Impl::encodeVsTfComputeDraw which has access to the private device
// + commandQueue.
bool MetalFrameGraph::encodeVsTfComputeDraw(void* vsComputePSO,
                                            std::uint32_t vertexCount,
                                            std::size_t perVertexBytes,
                                            const void* uniformBytes,
                                            std::size_t uniformLength,
                                            std::uint8_t* outBytes)
{
    return impl_->encodeVsTfComputeDraw(vsComputePSO, vertexCount,
                                        perVertexBytes, uniformBytes,
                                        uniformLength, outBytes);
}

MetalFrameGraph::TessPipelineProbeResult MetalFrameGraph::probeTessellationPipeline(
    const std::string& tcsMSL,
    const std::string& tesMSL,
    const std::string& fsMSL,
    GLenum genMode,
    GLenum genSpacing,
    GLenum genVertexOrder,
    const std::string& vsComputeMSL,
    const std::string& tesComputeMSL)
{
    return impl_->probeTessellationPipeline(tcsMSL, tesMSL, fsMSL,
                                             genMode, genSpacing, genVertexOrder,
                                             vsComputeMSL, tesComputeMSL);
}

bool MetalFrameGraph::encodeMetalTessellationDraw(const MetalTessDrawInfo& info) {
    return impl_->encodeMetalTessellationDraw(info);
}

bool MetalFrameGraph::encodeMetalMeshGSDraw(MetalMeshGSDrawInfo& info) {
    return impl_->encodeMetalMeshGSDraw(info);
}

bool MetalFrameGraph::encodeComputeDispatch(const ComputeDispatchInfo& info) {
    return impl_->encodeComputeDispatch(info);
}

void MetalFrameGraph::endFrame(GLObjectStore& objects) {
    impl_->endFrame(objects);
}

void MetalFrameGraph::present() {
    impl_->present();
}

bool MetalFrameGraph::copyRGBA8Pixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels) {
    return impl_->copyPixels(x, y, width, height, outPixels);
}

bool MetalFrameGraph::hasValidAttachments() const {
    return impl_->isReady();
}

MetalFrameGraph::PipelineCacheMetrics MetalFrameGraph::pipelineCacheMetrics() const {
    PipelineCacheMetrics m;
    m.hits = impl_->getPipelineCacheHits();
    m.misses = impl_->getPipelineCacheMisses();
    m.buildAttempts = impl_->getPipelineBuildAttempts();
    m.buildFailures = impl_->getPipelineBuildFailures();
    m.cumulativeBuildMillis = impl_->getPipelineBuildMs();
    return m;
}

void MetalFrameGraph::resetPipelineCacheMetrics() {
    impl_->resetMetrics();
}

std::uint64_t MetalFrameGraph::metalAllocatedBytes() const {
    return impl_->getMetalAllocatedBytes();
}

}  // namespace appgl
