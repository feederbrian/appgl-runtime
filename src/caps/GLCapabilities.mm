#include "GLCapabilities.h"

#import <Metal/Metal.h>

#include <algorithm>

#include "../extensions/ExtensionRegistry.h"
#include "../shader/ShaderTranslator.h"

// Compat-profile internal format enums. These were removed from the
// core profile in GL 3.2, so the codegen-emitted glcorearb.h does not
// expose them. AppGL still accepts them as upload aliases (font caches
// in particular allocate GL_ALPHA8 / GL_LUMINANCE8_ALPHA8 atlases via
// stb_truetype, FreeType, and similar libraries), upcasting to RGBA8
// at the driver edge with channel replication so sampling matches the
// legacy spec semantics. Defining them locally with #ifndef guards
// keeps the cap table self-contained without polluting the public
// glcorearb.h surface.
#ifndef GL_ALPHA8
#define GL_ALPHA8 0x803C
#endif
#ifndef GL_LUMINANCE
#define GL_LUMINANCE 0x1909
#endif
#ifndef GL_LUMINANCE_ALPHA
#define GL_LUMINANCE_ALPHA 0x190A
#endif
#ifndef GL_LUMINANCE8
#define GL_LUMINANCE8 0x8040
#endif
#ifndef GL_LUMINANCE8_ALPHA8
#define GL_LUMINANCE8_ALPHA8 0x8045
#endif
#ifndef GL_INTENSITY
#define GL_INTENSITY 0x8049
#endif
#ifndef GL_INTENSITY8
#define GL_INTENSITY8 0x804B
#endif

// Phase 8X Group 4d follow-up⁶ — fixed-function pname aliases. These are
// compat-profile scalar queries (GL 1.x–2.x era) that have been removed
// from core glcorearb.h but are still probed by legacy engines during
// steady-state rendering. BAR's followup⁵ verification captured two of
// them in the select-menu smoke:
//
//   GL_LIST_INDEX (0x0B33)       — queried every frame by the Recoil
//                                  fog-state probe (28,717 hits over 22s).
//                                  There is no active display list in
//                                  AppGL, so the spec-correct answer is 0.
//
//   GL_MAX_TEXTURE_COORDS (0x8871) — legacy fixed-function multi-texture
//                                    limit. Engines use it to size their
//                                    texcoord-unit arrays even on GL 3.x+
//                                    code paths. GL 3.2 spec floor is 8.
//
// Defining them locally keeps initializeLimits self-contained without
// touching the public glcorearb.h surface.
#ifndef GL_LIST_INDEX
#define GL_LIST_INDEX 0x0B33
#endif
#ifndef GL_MAX_TEXTURE_COORDS
#define GL_MAX_TEXTURE_COORDS 0x8871
#endif

namespace appgl {

GLCapabilities::GLCapabilities(void* metalDevice) {
    initializeFormatTable(metalDevice);
    initializeLimits(metalDevice);
}

const std::string& GLCapabilities::extensionString() const {
    return extensions::ExtensionRegistry::extensionString();
}

bool GLCapabilities::queryInteger(GLenum pname, GLint* out) const {
    if (out == nullptr) {
        return false;
    }
    if (pname == GL_MAX_VIEWPORT_DIMS) {
        const auto value = integerLimits_.find(GL_MAX_VIEWPORT_DIMS);
        if (value == integerLimits_.end()) {
            return false;
        }
        out[0] = static_cast<GLint>(value->second);
        out[1] = static_cast<GLint>(value->second);
        return true;
    }
    if (pname == GL_NUM_EXTENSIONS) {
        *out = static_cast<GLint>(extensions::ExtensionRegistry::extensionCount());
        return true;
    }
    // GL 4.6 §22.2 — {min,max} float-pair pnames are also queryable
    // via glGetIntegerv (with value-preserving float→int conversion
    // per §2.2.2). Route through queryFloat so the same {min,max}
    // logic runs, then truncate. CTS
    // `tessellation_shader.tessellation_shader_point_mode.
    // point_rendering` calls glGetIntegerv(GL_POINT_SIZE_RANGE)
    // directly and aborts on INVALID_ENUM if the int path doesn't
    // know the pname.
    if (pname == GL_POINT_SIZE_RANGE ||           // == GL_SMOOTH_POINT_SIZE_RANGE
        pname == GL_LINE_WIDTH_RANGE ||           // == GL_SMOOTH_LINE_WIDTH_RANGE
        pname == GL_ALIASED_LINE_WIDTH_RANGE ||
        pname == GL_VIEWPORT_BOUNDS_RANGE) {
        GLfloat pair[2] = {};
        if (!queryFloat(pname, pair)) {
            return false;
        }
        out[0] = static_cast<GLint>(pair[0]);
        out[1] = static_cast<GLint>(pair[1]);
        return true;
    }
    // Phase 8X Group 4d follow-up⁶ — GL_COMPRESSED_TEXTURE_FORMATS is a
    // variable-length query: the caller is supposed to glGetIntegerv the
    // count from GL_NUM_COMPRESSED_TEXTURE_FORMATS first, then size the
    // output buffer and pass it here. We advertise zero compressed
    // format enums through this query (compressed formats are reachable
    // via glCompressedTexImage2D / format table routing, but none are
    // exposed through the legacy probe), so the correct behaviour is to
    // write zero entries and return true. The NUM alias is published in
    // initializeLimits alongside every other scalar cap.
    if (pname == GL_COMPRESSED_TEXTURE_FORMATS) {
        (void)out;
        return true;
    }

    const auto value = integerLimits_.find(pname);
    if (value != integerLimits_.end()) {
        *out = static_cast<GLint>(value->second);
        return true;
    }

    // Indexed caps reached via the scalar path: report the index-0 value
    // so legacy code that calls glGetIntegerv(GL_MAX_COMPUTE_WORK_GROUP_*)
    // without the indexed variant sees at least the x-axis limit rather
    // than a GL_INVALID_ENUM. Indexed callers should still use the
    // dedicated queryIntegerIndexed path.
    const auto indexed = indexedIntegerLimits_.find(pname);
    if (indexed != indexedIntegerLimits_.end()) {
        *out = static_cast<GLint>(indexed->second[0]);
        return true;
    }
    return false;
}

bool GLCapabilities::queryInteger64(GLenum pname, GLint64* out) const {
    if (out == nullptr) {
        return false;
    }
    if (pname == GL_NUM_EXTENSIONS) {
        *out = static_cast<GLint64>(extensions::ExtensionRegistry::extensionCount());
        return true;
    }
    if (pname == GL_MAX_VIEWPORT_DIMS) {
        const auto value = integerLimits_.find(GL_MAX_VIEWPORT_DIMS);
        if (value == integerLimits_.end()) {
            return false;
        }
        out[0] = value->second;
        out[1] = value->second;
        return true;
    }
    // Pair-valued float pnames are reachable through glGetInteger64v
    // too; see queryInteger comment above for spec rationale.
    if (pname == GL_POINT_SIZE_RANGE ||           // == GL_SMOOTH_POINT_SIZE_RANGE
        pname == GL_LINE_WIDTH_RANGE ||           // == GL_SMOOTH_LINE_WIDTH_RANGE
        pname == GL_ALIASED_LINE_WIDTH_RANGE ||
        pname == GL_VIEWPORT_BOUNDS_RANGE) {
        GLfloat pair[2] = {};
        if (!queryFloat(pname, pair)) {
            return false;
        }
        out[0] = static_cast<GLint64>(pair[0]);
        out[1] = static_cast<GLint64>(pair[1]);
        return true;
    }
    // Phase 8X Group 4d follow-up⁶ — zero-entry variable-length cap. See
    // the matching comment in queryInteger for the NUM-first probe
    // contract; the 64-bit path mirrors it so glGetInteger64v and
    // glGetIntegerv return identical shapes.
    if (pname == GL_COMPRESSED_TEXTURE_FORMATS) {
        (void)out;
        return true;
    }

    const auto value = integerLimits_.find(pname);
    if (value != integerLimits_.end()) {
        *out = value->second;
        return true;
    }

    // Same scalar-path fallback as queryInteger — see comment there.
    const auto indexed = indexedIntegerLimits_.find(pname);
    if (indexed != indexedIntegerLimits_.end()) {
        *out = indexed->second[0];
        return true;
    }
    return false;
}

bool GLCapabilities::queryIntegerIndexed(GLenum pname, GLuint index, GLint* out) const {
    if (out == nullptr) {
        return false;
    }
    const auto indexed = indexedIntegerLimits_.find(pname);
    if (indexed != indexedIntegerLimits_.end()) {
        if (index >= indexed->second.size()) {
            return false;
        }
        *out = static_cast<GLint>(indexed->second[index]);
        return true;
    }
    // Scalar caps answer the index-0 indexed query too. Desktop GL treats
    // glGetIntegeri_v on a scalar state as INVALID_ENUM, but being lenient
    // here matches what most loaders expect when they probe caps via the
    // indexed path without knowing which enums are indexed.
    if (index != 0) {
        return false;
    }
    return queryInteger(pname, out);
}

bool GLCapabilities::queryInteger64Indexed(GLenum pname, GLuint index, GLint64* out) const {
    if (out == nullptr) {
        return false;
    }
    const auto indexed = indexedIntegerLimits_.find(pname);
    if (indexed != indexedIntegerLimits_.end()) {
        if (index >= indexed->second.size()) {
            return false;
        }
        *out = indexed->second[index];
        return true;
    }
    if (index != 0) {
        return false;
    }
    return queryInteger64(pname, out);
}

bool GLCapabilities::queryFloat(GLenum pname, GLfloat* out) const {
    if (out == nullptr) {
        return false;
    }
    // Check the dedicated float map first — fractional values like
    // GL_MIN_FRAGMENT_INTERPOLATION_OFFSET (-0.5f) can't survive the
    // int64 round-trip.
    const auto floatIt = floatLimits_.find(pname);
    if (floatIt != floatLimits_.end()) {
        out[0] = floatIt->second;
        // Range pair pnames return a {min, max} pair. The first
        // element is the "min" value (what we store in floatLimits_);
        // the second is the "max". Metal on Apple Silicon supports
        // point sizes up to 511 and line widths up to 4 — advertise
        // conservative but spec-compliant maxes here so CTS's
        // point/line-size probes don't hit the "not supported" gate
        // (esextcGeometryShaderInput.cpp:929 requires point-size
        // max ≥ 8, limits tests require ≥ 1).
        // GL_POINT_SIZE_RANGE == GL_SMOOTH_POINT_SIZE_RANGE (0x0B12)
        // and GL_LINE_WIDTH_RANGE == GL_SMOOTH_LINE_WIDTH_RANGE
        // (0x0B22) share the same enum value, so list each only
        // once in the switch.
        switch (pname) {
            case GL_POINT_SIZE_RANGE:          // == GL_SMOOTH_POINT_SIZE_RANGE (0x0B12)
                out[1] = 256.0f;
                break;
            case GL_LINE_WIDTH_RANGE:          // == GL_SMOOTH_LINE_WIDTH_RANGE (0x0B22)
            case GL_ALIASED_LINE_WIDTH_RANGE:
                out[1] = 1.0f;   // Metal rasterizer only supports line-width 1
                break;
            case GL_VIEWPORT_BOUNDS_RANGE:
                // Min stored as -32768; max is the symmetric +32768.
                out[1] = -floatIt->second;
                break;
            default:
                break;
        }
        return true;
    }
    // Fall through to integer path (cast to float).
    GLint integerValue[2] = {};
    if (!queryInteger(pname, integerValue)) {
        return false;
    }
    out[0] = static_cast<GLfloat>(integerValue[0]);
    if (pname == GL_MAX_VIEWPORT_DIMS) {
        out[1] = static_cast<GLfloat>(integerValue[1]);
    }
    return true;
}

std::optional<GLFormatCapability> GLCapabilities::format(GLenum internalFormat) const {
    const auto found = formats_.find(internalFormat);
    if (found == formats_.end()) {
        return std::nullopt;
    }
    return found->second;
}

bool GLCapabilities::isSupportedInternalFormat(GLenum internalFormat) const {
    return formats_.find(internalFormat) != formats_.end();
}

void GLCapabilities::initializeFormatTable(void* rawMetalDevice) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)rawMetalDevice;

    // GPU-family probes so compressed formats can be gated on real hardware
    // support. Apple Silicon (Apple family) supports ETC2/EAC and — on
    // macOS 11+ — BC texture compression via the unified family. Intel Macs
    // report MTLGPUFamilyMac2 and historically support BC but not ETC.
    const bool supportsApple = device != nil && [device supportsFamily:MTLGPUFamilyApple1];
    bool supportsBC = device != nil && [device supportsFamily:MTLGPUFamilyMac2];

    // Sprint 3 [metal-mesh-GS]: cache mesh shader capability at
    // initialization time. Both `Metal3` (full feature set) and
    // `Apple7` (tier-1 mesh) are required for the GS-via-mesh-shader
    // translation path. Older Apple Silicon (Apple1-6) routes to the
    // CPU GS interpreter fallback. M1 Max validated 2026-04-27 as
    // having both capabilities.
    if (device != nil) {
        meshShaderSupported_ =
            [device supportsFamily:MTLGPUFamilyMetal3] &&
            [device supportsFamily:MTLGPUFamilyApple7];
    }
    if (device != nil && [device respondsToSelector:@selector(supportsBCTextureCompression)]) {
        // supportsBCTextureCompression (macOS 11+) is the canonical probe
        // for BC format support, and it returns YES on Apple Silicon too
        // when the OS ships hardware support.
        supportsBC = supportsBC || [device supportsBCTextureCompression];
    }

    auto add = [&](GLenum glFormat, MTLPixelFormat metalFormat, bool renderable, bool filterable, bool blendable, bool srgb, bool compressed) {
        formats_[glFormat] = GLFormatCapability{
            glFormat,
            static_cast<std::uint64_t>(metalFormat),
            renderable,
            filterable,
            blendable,
            srgb,
            compressed,
        };
    };

    // ------------------------------------------------------------------
    // 8-bit unorm color (legacy baseline + additions)
    // ------------------------------------------------------------------
    add(GL_R8, MTLPixelFormatR8Unorm, true, true, false, false, false);
    add(GL_RG8, MTLPixelFormatRG8Unorm, true, true, false, false, false);

    // ------------------------------------------------------------------
    // Compat-profile alpha / luminance / intensity formats. These are
    // GL 1.x-era entry points that the core profile removed but which
    // font caches (FreeType, stb_truetype) and many compat-profile
    // engines still allocate via texImage2D / texStorage2D. AppGL upcasts
    // every one of them to RGBA8 at the upload-channel-fill edge — see
    // GLContext.mm buildRGBA8Upload — replicating the source bytes into
    // the correct channels so sampling matches the legacy spec without
    // any per-texture swizzle gymnastics:
    //
    //   GL_ALPHA8        : uploaded byte → (0, 0, 0, A)
    //   GL_LUMINANCE8    : uploaded byte → (L, L, L, 1)
    //   GL_LUMINANCE8_A8 : two source bytes → (L, L, L, A)
    //   GL_INTENSITY8    : uploaded byte → (I, I, I, I)
    //
    // Marked non-renderable because nobody allocates a font atlas as a
    // color attachment and the replicated-channel storage would make
    // round-trip writes nonsensical anyway.
    add(GL_ALPHA8, MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_LUMINANCE8, MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_LUMINANCE8_ALPHA8, MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_INTENSITY8, MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    // Unsized aliases that legacy callers also use as the internalFormat
    // arg to texImage2D. The spec lets the driver pick the precision; we
    // pick the 8-bit tier above and reuse the same RGBA8-backed storage.
    add(GL_ALPHA, MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_LUMINANCE, MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_LUMINANCE_ALPHA, MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_INTENSITY, MTLPixelFormatRGBA8Unorm, false, true, false, false, false);

    // GL_RGB8 has no direct Metal equivalent — Metal only exposes RGBA on
    // the unorm path, so we re-route to RGBA8 and mark non-renderable so
    // framebuffer-attachment validation still catches engines trying to use
    // it as a color target. Texture sampling works because the upload path
    // expands RGB→RGBA at the driver edge.
    add(GL_RGB8, MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_RGBA8, MTLPixelFormatRGBA8Unorm, true, true, true, false, false);

    // ------------------------------------------------------------------
    // 8-bit snorm — signed [-1, +1] texel coding used for tangent-frame
    // storage by many engines (BAR normal maps included).
    // ------------------------------------------------------------------
    add(GL_R8_SNORM, MTLPixelFormatR8Snorm, false, true, false, false, false);
    add(GL_RG8_SNORM, MTLPixelFormatRG8Snorm, false, true, false, false, false);
    add(GL_RGB8_SNORM, MTLPixelFormatRGBA8Snorm, false, true, false, false, false);
    add(GL_RGBA8_SNORM, MTLPixelFormatRGBA8Snorm, false, true, false, false, false);

    // ------------------------------------------------------------------
    // 16-bit unorm color — heightmaps and displacement fields.
    // ------------------------------------------------------------------
    add(GL_R16, MTLPixelFormatR16Unorm, true, true, false, false, false);
    add(GL_RG16, MTLPixelFormatRG16Unorm, true, true, false, false, false);
    add(GL_RGBA16, MTLPixelFormatRGBA16Unorm, true, true, false, false, false);

    // 16-bit snorm
    add(GL_R16_SNORM, MTLPixelFormatR16Snorm, false, true, false, false, false);
    add(GL_RG16_SNORM, MTLPixelFormatRG16Snorm, false, true, false, false, false);
    add(GL_RGBA16_SNORM, MTLPixelFormatRGBA16Snorm, false, true, false, false, false);

    // ------------------------------------------------------------------
    // Float color — the HDR pipeline's bread and butter.
    // 16F is renderable + blendable everywhere; 32F blending is not
    // universally supported on Metal so we mark it non-blendable.
    // ------------------------------------------------------------------
    add(GL_R16F, MTLPixelFormatR16Float, true, true, true, false, false);
    add(GL_RG16F, MTLPixelFormatRG16Float, true, true, true, false, false);
    add(GL_RGBA16F, MTLPixelFormatRGBA16Float, true, true, true, false, false);
    add(GL_R32F, MTLPixelFormatR32Float, true, false, false, false, false);
    add(GL_RG32F, MTLPixelFormatRG32Float, true, false, false, false, false);
    add(GL_RGBA32F, MTLPixelFormatRGBA32Float, true, false, false, false, false);

    // ------------------------------------------------------------------
    // Packed color — 10/10/10/2 and 11/11/10 float. Renderable on Metal;
    // used by many engines for deferred-rendering G-buffers.
    // ------------------------------------------------------------------
    add(GL_RGB10_A2, MTLPixelFormatRGB10A2Unorm, true, true, true, false, false);
    add(GL_RGB10_A2UI, MTLPixelFormatRGB10A2Uint, true, false, false, false, false);
    add(GL_R11F_G11F_B10F, MTLPixelFormatRG11B10Float, true, true, true, false, false);

    // ------------------------------------------------------------------
    // Integer formats (8 / 16 / 32 bit, signed and unsigned). These are
    // required for GPU-side ID buffers, instance selectors, and image
    // load/store paths. Integer textures are never filterable per spec.
    // ------------------------------------------------------------------
    add(GL_R8UI, MTLPixelFormatR8Uint, true, false, false, false, false);
    add(GL_RG8UI, MTLPixelFormatRG8Uint, true, false, false, false, false);
    add(GL_RGBA8UI, MTLPixelFormatRGBA8Uint, true, false, false, false, false);
    add(GL_R8I, MTLPixelFormatR8Sint, true, false, false, false, false);
    add(GL_RG8I, MTLPixelFormatRG8Sint, true, false, false, false, false);
    add(GL_RGBA8I, MTLPixelFormatRGBA8Sint, true, false, false, false, false);

    add(GL_R16UI, MTLPixelFormatR16Uint, true, false, false, false, false);
    add(GL_RG16UI, MTLPixelFormatRG16Uint, true, false, false, false, false);
    add(GL_RGBA16UI, MTLPixelFormatRGBA16Uint, true, false, false, false, false);
    add(GL_R16I, MTLPixelFormatR16Sint, true, false, false, false, false);
    add(GL_RG16I, MTLPixelFormatRG16Sint, true, false, false, false, false);
    add(GL_RGBA16I, MTLPixelFormatRGBA16Sint, true, false, false, false, false);

    add(GL_R32UI, MTLPixelFormatR32Uint, true, false, false, false, false);
    add(GL_RG32UI, MTLPixelFormatRG32Uint, true, false, false, false, false);
    add(GL_RGBA32UI, MTLPixelFormatRGBA32Uint, true, false, false, false, false);
    add(GL_R32I, MTLPixelFormatR32Sint, true, false, false, false, false);
    add(GL_RG32I, MTLPixelFormatRG32Sint, true, false, false, false, false);
    add(GL_RGBA32I, MTLPixelFormatRGBA32Sint, true, false, false, false, false);

    // ------------------------------------------------------------------
    // sRGB variants. GL_SRGB8 has no direct Metal mapping (same RGB→RGBA
    // promotion as the linear path) — engines that sample SRGB8 textures
    // go through the RGBA8_sRGB Metal format and the driver edge handles
    // the channel fill.
    // ------------------------------------------------------------------
    add(GL_SRGB8, MTLPixelFormatRGBA8Unorm_sRGB, false, true, false, true, false);
    add(GL_SRGB8_ALPHA8, MTLPixelFormatRGBA8Unorm_sRGB, true, true, true, true, false);

    // ------------------------------------------------------------------
    // Legacy / low-precision sized formats. Metal has no native equivalents
    // for these but GL 4.6 requires accepting them. We promote to the
    // closest Metal format with equal or higher precision. The upload path
    // (buildRGBA8Upload / buildNativeUpload) handles channel expansion
    // (RGB→RGBA padding alpha=1) automatically.
    // ------------------------------------------------------------------
    // Legacy packed / low-bit RGB — promoted to RGBA8Unorm.
    add(GL_R3_G3_B2,  MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_RGB4,       MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_RGB5,       MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_RGB565,     MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_RGBA2,      MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_RGBA4,      MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_RGB5_A1,    MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    // 10/12-bit per channel — promoted to 16-bit.
    add(GL_RGB10,      MTLPixelFormatRGBA16Unorm, false, true, false, false, false);
    add(GL_RGB12,      MTLPixelFormatRGBA16Unorm, false, true, false, false, false);
    add(GL_RGBA12,     MTLPixelFormatRGBA16Unorm, false, true, false, false, false);

    // ------------------------------------------------------------------
    // RGB-only sized formats (16-bit, float, integer). Metal has no 3-
    // channel pixel formats; we promote to the 4-channel RGBA variant and
    // pad alpha at upload time. Marked non-renderable because Metal
    // render targets must match the pipeline output format and we can't
    // use RGB-only render targets.
    // ------------------------------------------------------------------
    add(GL_RGB16,        MTLPixelFormatRGBA16Unorm,  false, true, false, false, false);
    add(GL_RGB16_SNORM,  MTLPixelFormatRGBA16Snorm,  false, true, false, false, false);
    add(GL_RGB16F,       MTLPixelFormatRGBA16Float,  false, true, false, false, false);
    add(GL_RGB32F,       MTLPixelFormatRGBA32Float,  false, false, false, false, false);
    add(GL_RGB8I,        MTLPixelFormatRGBA8Sint,    false, false, false, false, false);
    add(GL_RGB8UI,       MTLPixelFormatRGBA8Uint,    false, false, false, false, false);
    add(GL_RGB16I,       MTLPixelFormatRGBA16Sint,   false, false, false, false, false);
    add(GL_RGB16UI,      MTLPixelFormatRGBA16Uint,   false, false, false, false, false);
    add(GL_RGB32I,       MTLPixelFormatRGBA32Sint,   false, false, false, false, false);
    add(GL_RGB32UI,      MTLPixelFormatRGBA32Uint,   false, false, false, false, false);

    // Shared-exponent float (Metal supports it natively for sampling).
    add(GL_RGB9_E5, MTLPixelFormatRGB9E5Float, false, true, false, false, false);

    // ------------------------------------------------------------------
    // Depth / stencil. DEPTH_COMPONENT24 maps to Depth32Float because Metal
    // has no native 24-bit depth — precision goes up, sample semantics are
    // the same. STENCIL_INDEX8 is a dedicated Metal format.
    // ------------------------------------------------------------------
    add(GL_DEPTH_COMPONENT16, MTLPixelFormatDepth16Unorm, true, false, false, false, false);
    add(GL_DEPTH_COMPONENT24, MTLPixelFormatDepth32Float, true, false, false, false, false);
    add(GL_DEPTH_COMPONENT32, MTLPixelFormatDepth32Float, true, false, false, false, false);
    add(GL_DEPTH_COMPONENT32F, MTLPixelFormatDepth32Float, true, false, false, false, false);
    add(GL_DEPTH24_STENCIL8, MTLPixelFormatDepth32Float_Stencil8, true, false, false, false, false);
    add(GL_DEPTH32F_STENCIL8, MTLPixelFormatDepth32Float_Stencil8, true, false, false, false, false);
    add(GL_STENCIL_INDEX8, MTLPixelFormatStencil8, true, false, false, false, false);

    // ------------------------------------------------------------------
    // Compressed formats — gated by GPU family.
    //
    // Apple family (M1+, iPhone) supports ETC2/EAC natively. BC formats
    // are supported on all Intel Macs and on Apple Silicon running
    // macOS 11+ (probed via supportsBCTextureCompression).
    //
    // All compressed formats are marked non-renderable — compressed
    // render targets are not a Metal feature, and GL engines should never
    // use them as attachments anyway. Filterable is true because sampling
    // works; blendable is false because compressed sources cannot be in
    // the color-blend path.
    // ------------------------------------------------------------------
    if (supportsBC) {
        // BPTC (BC6H floating-point HDR, BC7 8-bit RGBA). BAR uses BC7 for
        // its high-quality texture atlas.
        add(GL_COMPRESSED_RGB_BPTC_SIGNED_FLOAT, MTLPixelFormatBC6H_RGBFloat, false, true, false, false, true);
        add(GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT, MTLPixelFormatBC6H_RGBUfloat, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_BPTC_UNORM, MTLPixelFormatBC7_RGBAUnorm, false, true, false, false, true);
        add(GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM, MTLPixelFormatBC7_RGBAUnorm_sRGB, false, true, false, true, true);

        // RGTC (BC4 single-channel, BC5 two-channel). The canonical choice
        // for tangent-space normal maps on Desktop GL.
        add(GL_COMPRESSED_RED_RGTC1, MTLPixelFormatBC4_RUnorm, false, true, false, false, true);
        add(GL_COMPRESSED_SIGNED_RED_RGTC1, MTLPixelFormatBC4_RSnorm, false, true, false, false, true);
        add(GL_COMPRESSED_RG_RGTC2, MTLPixelFormatBC5_RGUnorm, false, true, false, false, true);
        add(GL_COMPRESSED_SIGNED_RG_RGTC2, MTLPixelFormatBC5_RGSnorm, false, true, false, false, true);

        // S3TC / DXT (BC1/BC2/BC3), exposed only when the device reports
        // BC texture compression support.
        add(GL_COMPRESSED_RGB_S3TC_DXT1_EXT, MTLPixelFormatBC1_RGBA, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_S3TC_DXT1_EXT, MTLPixelFormatBC1_RGBA, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_S3TC_DXT3_EXT, MTLPixelFormatBC2_RGBA, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_S3TC_DXT5_EXT, MTLPixelFormatBC3_RGBA, false, true, false, false, true);
    }

    if (supportsApple) {
        // ETC2 / EAC — forward compatibility with mobile GL and the Vulkan
        // asset pipeline. BAR doesn't currently ship ETC2 assets but the
        // extension list advertises ETC2 support, so the format table
        // needs to answer consistently.
        add(GL_COMPRESSED_RGB8_ETC2, MTLPixelFormatETC2_RGB8, false, true, false, false, true);
        add(GL_COMPRESSED_SRGB8_ETC2, MTLPixelFormatETC2_RGB8_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_RGB8_PUNCHTHROUGH_ALPHA1_ETC2, MTLPixelFormatETC2_RGB8A1, false, true, false, false, true);
        add(GL_COMPRESSED_SRGB8_PUNCHTHROUGH_ALPHA1_ETC2, MTLPixelFormatETC2_RGB8A1_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_RGBA8_ETC2_EAC, MTLPixelFormatEAC_RGBA8, false, true, false, false, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ETC2_EAC, MTLPixelFormatEAC_RGBA8_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_R11_EAC, MTLPixelFormatEAC_R11Unorm, false, true, false, false, true);
        add(GL_COMPRESSED_SIGNED_R11_EAC, MTLPixelFormatEAC_R11Snorm, false, true, false, false, true);
        add(GL_COMPRESSED_RG11_EAC, MTLPixelFormatEAC_RG11Unorm, false, true, false, false, true);
        add(GL_COMPRESSED_SIGNED_RG11_EAC, MTLPixelFormatEAC_RG11Snorm, false, true, false, false, true);

        // ASTC LDR — native on Apple-family GPUs. GL_KHR_texture_compression_astc_ldr
        // covers both linear RGBA and sRGB variants.
        add(GL_COMPRESSED_RGBA_ASTC_4x4_KHR, MTLPixelFormatASTC_4x4_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_ASTC_5x4_KHR, MTLPixelFormatASTC_5x4_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_ASTC_5x5_KHR, MTLPixelFormatASTC_5x5_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_ASTC_6x5_KHR, MTLPixelFormatASTC_6x5_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_ASTC_6x6_KHR, MTLPixelFormatASTC_6x6_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_ASTC_8x5_KHR, MTLPixelFormatASTC_8x5_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_ASTC_8x6_KHR, MTLPixelFormatASTC_8x6_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_ASTC_8x8_KHR, MTLPixelFormatASTC_8x8_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_ASTC_10x5_KHR, MTLPixelFormatASTC_10x5_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_ASTC_10x6_KHR, MTLPixelFormatASTC_10x6_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_ASTC_10x8_KHR, MTLPixelFormatASTC_10x8_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_ASTC_10x10_KHR, MTLPixelFormatASTC_10x10_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_ASTC_12x10_KHR, MTLPixelFormatASTC_12x10_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_RGBA_ASTC_12x12_KHR, MTLPixelFormatASTC_12x12_LDR, false, true, false, false, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_4x4_KHR, MTLPixelFormatASTC_4x4_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_5x4_KHR, MTLPixelFormatASTC_5x4_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_5x5_KHR, MTLPixelFormatASTC_5x5_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_6x5_KHR, MTLPixelFormatASTC_6x5_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_6x6_KHR, MTLPixelFormatASTC_6x6_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x5_KHR, MTLPixelFormatASTC_8x5_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x6_KHR, MTLPixelFormatASTC_8x6_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_8x8_KHR, MTLPixelFormatASTC_8x8_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x5_KHR, MTLPixelFormatASTC_10x5_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x6_KHR, MTLPixelFormatASTC_10x6_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x8_KHR, MTLPixelFormatASTC_10x8_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_10x10_KHR, MTLPixelFormatASTC_10x10_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_12x10_KHR, MTLPixelFormatASTC_12x10_sRGB, false, true, false, true, true);
        add(GL_COMPRESSED_SRGB8_ALPHA8_ASTC_12x12_KHR, MTLPixelFormatASTC_12x12_sRGB, false, true, false, true, true);
    }
}

void GLCapabilities::initializeLimits(void* rawMetalDevice) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)rawMetalDevice;

    GLint64 maxTextureSize = 8192;
    GLint64 max3DTextureSize = 2048;
    GLint64 maxArrayLayers = 2048;
    GLint64 maxSamples = 4;
    GLint64 maxUniformBlockSize = 64 * 1024;
    GLint64 maxViewportDimension = 8192;
    GLint64 maxBufferLength = 256 * 1024 * 1024;
    bool sparseColorTexturesSupported = false;

    if (device != nil) {
        maxBufferLength = static_cast<GLint64>(device.maxBufferLength);
        if ([device supportsFamily:MTLGPUFamilyApple7] || [device supportsFamily:MTLGPUFamilyMac2]) {
            maxTextureSize = 16384;
            max3DTextureSize = 2048;
            maxArrayLayers = 2048;
            maxViewportDimension = 16384;
        }
        // Probe the actual max supported sample count instead of trusting
        // the GPU family alone. Apple-family GPUs typically cap at 4
        // samples even when the family supports everything else at the
        // Apple7+ tier. Advertising GL_MAX_SAMPLES above the Metal-
        // supported ceiling causes CTS tests (e.g. texture_swizzle
        // target_idx=7/8) to request that ceiling and fail because our
        // texStorageMultisample path correctly rejects unsupported counts
        // via `supportsTextureSampleCount:`. Sync what we advertise to
        // what Metal will actually accept.
        maxSamples = 1;
        for (NSUInteger n : {2u, 4u, 8u, 16u, 32u}) {
            if ([device supportsTextureSampleCount:n]) {
                maxSamples = static_cast<GLint64>(n);
            } else {
                break;
            }
        }
        // ARB_sparse_texture scaffold. Apple documents sparse color
        // textures from Apple6 onward; this runtime was empirically probed
        // on Apple7/M1 Max with sparseTileSizeInBytes=16384 and successful
        // sparse heap/texture map+unmap. Keep these caps queryable while
        // holding the extension-string gate until sparse allocation lands.
        sparseColorTexturesSupported =
            [device supportsFamily:MTLGPUFamilyApple6] ||
            [device supportsFamily:MTLGPUFamilyApple7] ||
            [device supportsFamily:MTLGPUFamilyApple8] ||
            [device supportsFamily:MTLGPUFamilyApple9] ||
            [device supportsFamily:MTLGPUFamilyApple10];
    }

    integerLimits_[GL_MAX_TEXTURE_SIZE] = maxTextureSize;
    integerLimits_[GL_MAX_CUBE_MAP_TEXTURE_SIZE] = maxTextureSize;
    integerLimits_[GL_MAX_3D_TEXTURE_SIZE] = max3DTextureSize;
    integerLimits_[GL_MAX_ARRAY_TEXTURE_LAYERS] = maxArrayLayers;
    integerLimits_[GL_MAX_SPARSE_TEXTURE_SIZE_ARB] =
        sparseColorTexturesSupported ? maxTextureSize : 0;
    integerLimits_[GL_MAX_SPARSE_3D_TEXTURE_SIZE_ARB] =
        sparseColorTexturesSupported ? max3DTextureSize : 0;
    integerLimits_[GL_MAX_SPARSE_ARRAY_TEXTURE_LAYERS_ARB] =
        sparseColorTexturesSupported ? maxArrayLayers : 0;
    integerLimits_[GL_SPARSE_BUFFER_PAGE_SIZE_ARB] = 65536;
    // Metal reports a mip tail for sparse textures, so conservatively
    // expose FALSE until dispatch #2 maps tail commitment semantics.
    integerLimits_[GL_SPARSE_TEXTURE_FULL_ARRAY_CUBE_MIPMAPS_ARB] = 0;
    integerLimits_[GL_MAX_COLOR_ATTACHMENTS] = 8;
    integerLimits_[GL_MAX_DRAW_BUFFERS] = 8;
    integerLimits_[GL_MAX_VIEWS_OVR] = 2;
    // GL 4.6 spec §23.4 floor is 16, but most desktop drivers expose 32
    // and CTS tests like cull_distance use 17+ attributes (8 clip + 8 cull
    // + 1 position). Metal supports 31 vertex attributes via
    // MTLVertexDescriptor.attributes; expose 32 so CTS reports match common
    // desktop drivers (glGetIntegerv(GL_MAX_VERTEX_ATTRIBS)). The VAO's
    // attribute array size in GLObjectStore is raised to match.
    integerLimits_[GL_MAX_VERTEX_ATTRIBS] = 32;
    // Per-stage texture image units bumped from 16 → 48 to unblock CTS
    // `layout_binding` which uses `layout(binding=39) uniform sampler2D`.
    // GL 4.6 spec floor is 16; Apple Silicon argument-table limit is 128
    // per stage, so 48 is well within Metal's real budget.
    //
    // Keep COMBINED at the sum of the advertised VS/GS/FS per-stage
    // sampler budgets. CTS `geometry_shader.limits.
    // max_combined_texture_units` partitions this value across those
    // three stages and then verifies all advertised per-stage points; a
    // smaller combined cap collapses the GS slice and leaves later points
    // undrawn. Runtime/state texture-unit arrays are sized to match.
    integerLimits_[GL_MAX_TEXTURE_IMAGE_UNITS] = 48;
    integerLimits_[GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS] = 144;
    integerLimits_[GL_MAX_UNIFORM_BLOCK_SIZE] = maxUniformBlockSize;
    // Phase 8X Group 4d follow-up⁶ — UBO offset alignment. Metal's
    // MTLBuffer::setBufferOffset requires Mac-family GPUs to align constant
    // buffer offsets to 256 bytes (Apple-family GPUs are happy at 16, but
    // we publish the universal Mac floor so BAR's UBO offset padding is
    // always wide enough to satisfy the actual Metal binding path). GL
    // 4.2 spec floor is 1; engines that respect this cap will round their
    // per-instance UBO offsets up to 256 and nothing breaks on either GPU
    // family. BAR caught this pname in followup⁵ §6d as 0x8A34 — their
    // table misnamed it GL_MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS (which
    // is 0x8A31 and already published below). The correct enum is
    // GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT and every UBO-using app queries
    // it at startup to size their dynamic-UBO ring buffer.
    integerLimits_[GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT] = 256;
    // Phase 8X Group 4d follow-up⁷ — SSBO offset alignment. Sibling of
    // the UBO alignment above; GL 4.3 introduces shader storage buffers
    // with the same `setBufferOffset:` constraint on the Metal side.
    // Lowered 256 → 32 on 2026-04-20 after CTS
    // `shader_storage_buffer_object.advanced-switchBuffers` regressed
    // once the `bindBufferRange` alignment validator started enforcing
    // this cap: the test explicitly uses offset=128 to split a 512-byte
    // buffer into four 128-byte subranges, which aborts under a
    // 256-byte advertised alignment. Apple-family GPUs actually only
    // require 4-byte alignment for buffer offsets (16 for SIMD4 float
    // vector loads); 32 is a conservative compromise that matches
    // Apple's atomic-counter and struct-member alignment floors.
    // BAR's Recoil probe at startup is unaffected — the app reads the
    // cap and rounds its own offsets up accordingly.
    integerLimits_[GL_SHADER_STORAGE_BUFFER_OFFSET_ALIGNMENT] = 32;
    integerLimits_[GL_MAX_VERTEX_UNIFORM_COMPONENTS] = 4096;
    integerLimits_[GL_MAX_FRAGMENT_UNIFORM_COMPONENTS] = 4096;
    integerLimits_[GL_MAX_SAMPLES] = maxSamples;
    integerLimits_[GL_MAX_RENDERBUFFER_SIZE] = maxTextureSize;
    integerLimits_[GL_MAX_VIEWPORT_DIMS] = maxViewportDimension;
    // GL 4.3 spec: GL_MAX_ELEMENT_INDEX must be at least 2^32 - 2 for the largest
    // index type (GL_UNSIGNED_INT). It is a property of the index format, not of
    // any particular buffer's storage size.
    integerLimits_[GL_MAX_ELEMENT_INDEX] = static_cast<GLint64>(0xFFFFFFFFull);
    // GL 4.6 §22 — MAX_ELEMENTS_INDICES is a hint on the preferred
    // upper bound for drawRangeElements's index count. Apps (and CTS
    // `map_buffer_alignment.functional`) occasionally multiply this
    // value by `sizeof(GLuint)` and store into a GLint, which overflows
    // when the advertised value exceeds INT_MAX/4. Cap at INT_MAX/4
    // (≈512M) to avoid that overflow — the hint is non-normative so
    // advertising a smaller but still generous limit is spec-legal.
    integerLimits_[GL_MAX_ELEMENTS_INDICES] = std::min<GLint64>(maxBufferLength / 4, 0x1fffffff);
    // Same rationale for MAX_ELEMENTS_VERTICES — hint, non-normative,
    // and routinely multiplied by a per-vertex byte count.
    integerLimits_[GL_MAX_ELEMENTS_VERTICES] = std::min<GLint64>(maxBufferLength / 16, 0x1fffffff);
    integerLimits_[GL_MAX_DEBUG_MESSAGE_LENGTH] = 1024;
    integerLimits_[GL_MAX_DEBUG_LOGGED_MESSAGES] = 64;
    integerLimits_[GL_MAX_DEBUG_GROUP_STACK_DEPTH] = 64;
    integerLimits_[GL_MAX_LABEL_LENGTH] = 1024;
    integerLimits_[GL_MIN_MAP_BUFFER_ALIGNMENT] = 64;
    // GL_NUM_EXTENSIONS is served dynamically by ExtensionRegistry so the
    // monolithic string, indexed list, and count stay in one Decision H4
    // source of truth.
    // GL 4.6 SPIR-V extension queries.  The SPIR-V extensions CTS test
    // (KHR-GL46.spirv_extensions.spirv_extensions_queries) calls
    // glGetIntegerv(GL_NUM_SPIR_V_EXTENSIONS) and then iterates with
    // glGetStringi(GL_SPIR_V_EXTENSIONS, i).  Report 0 — AppGL does not
    // consume SPIR-V shaders directly, so no SPIR-V extensions are exposed.
    integerLimits_[GL_NUM_SPIR_V_EXTENSIONS] = 0;
    // GL 3.0+ core: applications query the context version via
    // glGetIntegerv(GL_MAJOR_VERSION/GL_MINOR_VERSION) rather than parsing
    // the GL_VERSION string. The Recoil engine in particular aborts with
    // "OpenGL version 0.0(core=true) is less than required 3.0" when these
    // come back unset. Report 4.6 to advertise the full AppGL surface.
    integerLimits_[GL_MAJOR_VERSION]   = 4;
    integerLimits_[GL_MINOR_VERSION]   = 6;
    integerLimits_[GL_CONTEXT_FLAGS]   = 0;
    integerLimits_[GL_CONTEXT_PROFILE_MASK] = 0x00000001 /* GL_CONTEXT_CORE_PROFILE_BIT */;

    // Phase 8X Landing C 3a — binding counts derived from the AppGL binding
    // layout. Metal exposes 31 buffer slots per stage and we partition them
    // into vertex / uniform / storage ranges; this makes the binding caps
    // the authoritative source of truth, not a hardcoded magic number.
    // BindingMap lives in ShaderTranslator.h and is shared with
    // ShaderTranslator + MetalVertexDescriptorBuilder.
    constexpr BindingMap kBindingMap{};
    constexpr std::uint32_t kBufferSlotsPerStage = 30u;  // [0..30), slot 30 is the argument-buffer stash
    const GLint64 uniformBindings = static_cast<GLint64>(
        kBindingMap.storageBufferBase - kBindingMap.uniformBufferBase);
    const GLint64 storageBindings = static_cast<GLint64>(
        kBufferSlotsPerStage - kBindingMap.storageBufferBase);
    integerLimits_[GL_MAX_UNIFORM_BUFFER_BINDINGS] = std::max<GLint64>(uniformBindings, 84);
    integerLimits_[GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS] = std::max<GLint64>(storageBindings, 16);
    integerLimits_[GL_MAX_SHADER_STORAGE_BLOCK_SIZE] = std::min<GLint64>(
        maxBufferLength, static_cast<GLint64>(128ull * 1024ull * 1024ull));
    integerLimits_[GL_MAX_VERTEX_ATTRIB_BINDINGS] = 16;

    // Varying / stage-interface components. Metal's fragment shader accepts
    // up to 128 input components per stage; the GL 4.6 spec floor is 64.
    integerLimits_[GL_MAX_VERTEX_OUTPUT_COMPONENTS] = 128;
    integerLimits_[GL_MAX_FRAGMENT_INPUT_COMPONENTS] = 128;

    // Per-stage texture image units. Missing GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS
    // is what produces BAR's "max texture slots: 2" diagnostic in its version
    // log — the engine walks several MAX_* variants and the *first one that
    // comes back false stops the probe, so the two that do answer (COMBINED
    // + fragment) get reported.
    // Per-stage texture image units matched to MAX_TEXTURE_IMAGE_UNITS
    // above (48). Apple Silicon argument-table limit is 128/stage.
    integerLimits_[GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS] = 48;
    integerLimits_[GL_MAX_GEOMETRY_TEXTURE_IMAGE_UNITS] = 48;
    integerLimits_[GL_MAX_COMPUTE_TEXTURE_IMAGE_UNITS] = 48;
    integerLimits_[GL_MAX_TESS_CONTROL_TEXTURE_IMAGE_UNITS] = 48;
    integerLimits_[GL_MAX_TESS_EVALUATION_TEXTURE_IMAGE_UNITS] = 48;

    // Phase 8X Group 4d follow-up⁶ — fixed-function multi-texture limit.
    // GL_MAX_TEXTURE_COORDS (0x8871) was a GL 1.3 query that reported the
    // number of texture coordinate sets the fixed-function pipeline could
    // interpolate per vertex. Modern engines still probe it during
    // version-flag synthesis even on GL 3.x+ code paths (the enum outlived
    // the fixed-function stage in compat headers until 4.6). The GL 3.2
    // spec floor is 8; we report 8 so probing engines see a sensible
    // number instead of a named GL_INVALID_ENUM breadcrumb.
    integerLimits_[GL_MAX_TEXTURE_COORDS] = 8;

    // Phase 8X Group 4d follow-up⁶ — fixed-function display list index.
    // GL_LIST_INDEX (0x0B33) is queried every frame by Recoil's steady-
    // state draw loop and was responsible for 28,717 of the 28,769
    // errorLog entries in BAR's followup⁵ select-menu smoke (~99.8%
    // noise). AppGL has no display list stack — glNewList/glEndList are
    // explicit emulation gaps under Phase A — so the spec-correct answer
    // is 0 ("no list is currently being compiled"). Publishing it as a
    // cap silences the ring firehose without hiding real errors.
    //
    // Note: followup⁵ briefly mistook 0x0B33 for GL_FOG_INDEX (which is
    // 0x0B61). Both are fixed-function, but the correct identification
    // matters because GL_FOG_INDEX would need a different default (the
    // current fog index, not 0).
    integerLimits_[GL_LIST_INDEX] = 0;

    // Texture filter anisotropy. Metal's upper limit is 16. GL 4.6 promoted
    // the ARB/EXT name to core as GL_MAX_TEXTURE_MAX_ANISOTROPY (no suffix);
    // the generated enum header uses that core spelling.
    integerLimits_[GL_MAX_TEXTURE_MAX_ANISOTROPY] = 16;

    // Legacy vector-style uniform/varying queries still used by GLSL 330-era
    // tooling (GLAD in particular). Equivalent to the component forms
    // divided by 4.
    integerLimits_[GL_MAX_VERTEX_UNIFORM_VECTORS] = 1024;
    integerLimits_[GL_MAX_FRAGMENT_UNIFORM_VECTORS] = 1024;
    integerLimits_[GL_MAX_VARYING_VECTORS] = 32;
    integerLimits_[GL_MAX_VARYING_COMPONENTS] = 128;
    integerLimits_[GL_MAX_VARYING_FLOATS] = 128;

    // Texel offset window for textureOffset / textureLodOffset. GL 4.6 spec
    // floor is [-8, +7], which is what Metal supports.
    integerLimits_[GL_MIN_PROGRAM_TEXEL_OFFSET] = -8;
    integerLimits_[GL_MAX_PROGRAM_TEXEL_OFFSET] = 7;

    // Geometry-shader caps. Metal has no native geometry shader stage —
    // the AppGL translator flags GS programs as emulation-gap in Landing B —
    // but engines still read these to *gate their codepaths* on whether a
    // geometry pipeline is plausible. Report GL 4.6 spec floors so engines
    // that probe caps before attempting a GS link don't give up prematurely.
    integerLimits_[GL_MAX_GEOMETRY_OUTPUT_VERTICES] = 256;
    integerLimits_[GL_MAX_GEOMETRY_TOTAL_OUTPUT_COMPONENTS] = 1024;
    integerLimits_[GL_MAX_GEOMETRY_UNIFORM_COMPONENTS] = 1024;
    integerLimits_[GL_MAX_GEOMETRY_INPUT_COMPONENTS] = 64;
    integerLimits_[GL_MAX_GEOMETRY_OUTPUT_COMPONENTS] = 128;
    integerLimits_[GL_MAX_GEOMETRY_UNIFORM_BLOCKS] = std::max<GLint64>(uniformBindings, 14);
    integerLimits_[GL_MAX_GEOMETRY_SHADER_INVOCATIONS] = 32;
    // GL 4.6 Table 23.60: GL_LAYER_PROVOKING_VERTEX selects which
    // vertex's `gl_Layer` value drives rasterization into a layered
    // FBO. Desktop GL accepts `GL_PROVOKING_VERTEX` (= follow the
    // current glProvokingVertex setting), `GL_FIRST_VERTEX_CONVENTION`,
    // `GL_LAST_VERTEX_CONVENTION`, or `GL_UNDEFINED_VERTEX`. Report
    // `GL_PROVOKING_VERTEX` so CTS
    // `geometry_shader.constant_variables.constant_variables` sees a
    // spec-legal value. (Same story for `GL_VIEWPORT_INDEX_PROVOKING
    // _VERTEX` which the same test queries.)
    integerLimits_[GL_LAYER_PROVOKING_VERTEX] = GL_PROVOKING_VERTEX;
    integerLimits_[GL_VIEWPORT_INDEX_PROVOKING_VERTEX] = GL_PROVOKING_VERTEX;
    // GL 3.2 §13.4: GL_PROVOKING_VERTEX returns whichever
    // glProvokingVertex mode was most recently set. Default per
    // GL 4.6 Table 23.6 is GL_LAST_VERTEX_CONVENTION. Tracked on
    // the context state (the runtime's glProvokingVertex entrypoint
    // updates it); we return the default here so static queries on
    // fresh contexts don't trip GL_INVALID_ENUM (CTS
    // `geometry_shader.layered_rendering.layered_rendering` queries
    // this before the first draw).
    integerLimits_[GL_PROVOKING_VERTEX] = GL_LAST_VERTEX_CONVENTION;

    // Tessellation caps. Same emulation-gap caveat as geometry: the
    // translator will eventually lower these onto Metal's tessellator via
    // MTLComputePipelineState + tessellation factor buffers, but the cap
    // numbers need to be reported now so engines don't fall back.
    integerLimits_[GL_MAX_TESS_CONTROL_INPUT_COMPONENTS] = 128;
    integerLimits_[GL_MAX_TESS_CONTROL_OUTPUT_COMPONENTS] = 128;
    integerLimits_[GL_MAX_TESS_CONTROL_TOTAL_OUTPUT_COMPONENTS] = 4096;
    integerLimits_[GL_MAX_TESS_CONTROL_UNIFORM_COMPONENTS] = 1024;
    integerLimits_[GL_MAX_TESS_CONTROL_UNIFORM_BLOCKS] = std::max<GLint64>(uniformBindings, 14);
    integerLimits_[GL_MAX_TESS_EVALUATION_INPUT_COMPONENTS] = 128;
    integerLimits_[GL_MAX_TESS_EVALUATION_OUTPUT_COMPONENTS] = 128;
    integerLimits_[GL_MAX_TESS_EVALUATION_UNIFORM_COMPONENTS] = 1024;
    integerLimits_[GL_MAX_TESS_EVALUATION_UNIFORM_BLOCKS] = std::max<GLint64>(uniformBindings, 14);
    integerLimits_[GL_MAX_TESS_GEN_LEVEL] = 64;
    integerLimits_[GL_MAX_TESS_PATCH_COMPONENTS] = 120;
    integerLimits_[GL_MAX_PATCH_VERTICES] = 32;

    // Compute caps. Metal's threadgroup limits are 1024 invocations total
    // with shared memory tiers of 16K/32K depending on GPU family; use the
    // high value so engines sizing compute passes don't under-subscribe.
    integerLimits_[GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS] = 1024;
    integerLimits_[GL_MAX_COMPUTE_SHARED_MEMORY_SIZE] = 32768;
    integerLimits_[GL_MAX_COMPUTE_UNIFORM_COMPONENTS] = 1024;
    integerLimits_[GL_MAX_COMPUTE_UNIFORM_BLOCKS] = std::max<GLint64>(uniformBindings, 14);
    integerLimits_[GL_MAX_COMPUTE_ATOMIC_COUNTERS] = 8;
    integerLimits_[GL_MAX_COMPUTE_ATOMIC_COUNTER_BUFFERS] = 8;

    // Indexed compute caps. x/y/z tuples — glGetIntegeri_v(pname, i) picks
    // the per-dimension value. Scalar glGetIntegerv falls through to the
    // index-0 entry via queryInteger's indexedIntegerLimits_ scan so
    // engines that probe via the scalar path still see a sensible number.
    indexedIntegerLimits_[GL_MAX_COMPUTE_WORK_GROUP_COUNT] = {65535, 65535, 65535};
    indexedIntegerLimits_[GL_MAX_COMPUTE_WORK_GROUP_SIZE] = {1024, 1024, 64};

    // Combined uniform-component ceilings. GL 4.6 spec:
    //   GL_MAX_COMBINED_{stage}_UNIFORM_COMPONENTS =
    //     GL_MAX_{stage}_UNIFORM_COMPONENTS +
    //     GL_MAX_UNIFORM_BUFFER_BINDINGS * GL_MAX_UNIFORM_BLOCK_SIZE / 4
    // We publish that exact derivation so engines using the floor don't
    // see a smaller number than spec.
    // GL 4.6 Table 23.60 defines each
    // MAX_COMBINED_<stage>_UNIFORM_COMPONENTS as being at least
    // `MAX_<stage>_UNIFORM_BLOCKS × MAX_UNIFORM_BLOCK_SIZE / 4 +
    //  MAX_<stage>_UNIFORM_COMPONENTS`. The CTS
    // `geometry_shader.constant_variables.constant_variables`
    // test queries the three per-stage values, computes the
    // right-hand side from them, and fails if the reported
    // COMBINED comes in below. Prior formula used `uniform
    // Bindings × blockSize/4 + 4096`, which landed below the
    // computed floor whenever `uniformBindings` was smaller
    // than the 14-block spec floor we already advertise via
    // `std::max<GLint64>(uniformBindings, 14)` above.
    //
    // Recompute using the effective per-stage block count
    // (`max(uniformBindings, 14)`) + the per-stage uniform-
    // components count we advertise so the derived
    // COMBINED always satisfies the spec formula.
    const GLint64 effUniformBlocks = std::max<GLint64>(uniformBindings, 14);
    const GLint64 combinedUniforms =
        effUniformBlocks * (maxUniformBlockSize / 4) + 1024;
    integerLimits_[GL_MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS] = combinedUniforms;
    integerLimits_[GL_MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS] = combinedUniforms;
    integerLimits_[GL_MAX_COMBINED_GEOMETRY_UNIFORM_COMPONENTS] = combinedUniforms;
    integerLimits_[GL_MAX_COMBINED_COMPUTE_UNIFORM_COMPONENTS] = combinedUniforms;
    integerLimits_[GL_MAX_COMBINED_TESS_CONTROL_UNIFORM_COMPONENTS] = combinedUniforms;
    integerLimits_[GL_MAX_COMBINED_TESS_EVALUATION_UNIFORM_COMPONENTS] = combinedUniforms;
    integerLimits_[GL_MAX_COMBINED_UNIFORM_BLOCKS] = std::max<GLint64>(uniformBindings * 6, 84);

    // GL_MAX_UNIFORM_LOCATIONS — the total number of discrete location
    // slots an explicit-location uniform can occupy. Spec floor is 1024;
    // AppGL has no hard internal ceiling so we report the floor.
    integerLimits_[GL_MAX_UNIFORM_LOCATIONS] = 1024;

    // Phase 8X Group 4d follow-up⁶ — compressed-format probe count.
    // Publishing GL_NUM_COMPRESSED_TEXTURE_FORMATS = 0 advertises "no
    // compressed formats exposed through the legacy enum list". The
    // format table already routes BC/ETC2/EAC/ASTC through the full
    // glCompressedTexImage2D path for engines that know the specific
    // enum they need, but the queryable list here is empty so compliant
    // callers skip the variable-length GL_COMPRESSED_TEXTURE_FORMATS
    // follow-up query. GLCapabilities::queryInteger still accepts the
    // variable-length path with a zero-write special case so legacy
    // callers that skip the NUM probe don't trip a GL_INVALID_ENUM.
    integerLimits_[GL_NUM_COMPRESSED_TEXTURE_FORMATS] = 0;

    // Framebuffer object dimensions. Match the viewport limits.
    integerLimits_[GL_MAX_FRAMEBUFFER_WIDTH] = maxViewportDimension;
    integerLimits_[GL_MAX_FRAMEBUFFER_HEIGHT] = maxViewportDimension;
    integerLimits_[GL_MAX_FRAMEBUFFER_LAYERS] = 2048;
    integerLimits_[GL_MAX_FRAMEBUFFER_SAMPLES] = maxSamples;

    // ── CTS-required limits (GL 4.0–4.6) ─────────────────────────────
    // The block below fills every GL_MAX_*/GL_MIN_* enum that the OpenGL
    // Conformance Test Suite queries during its initialization phase
    // (glcLimitTest, gluStateReset, gl4cLimitsTests).

    // Fragment interpolation — float-valued limits. Metal Apple Silicon
    // supports sample-rate interpolation at ±0.5 with 4-bit sub-pixel
    // precision. The CTS queries these via glGetFloatv, so they live in
    // the dedicated floatLimits_ map (fractional values can't survive
    // the int64 round-trip).
    floatLimits_[GL_MIN_FRAGMENT_INTERPOLATION_OFFSET] = -0.5f;
    floatLimits_[GL_MAX_FRAGMENT_INTERPOLATION_OFFSET] =  0.5f;
    floatLimits_[GL_MAX_TEXTURE_LOD_BIAS] = 16.0f;

    // GL_FRAGMENT_INTERPOLATION_OFFSET_BITS: integer value, but the CTS
    // also queries it via glGetFloatv (glcLimitTest.inl:66). Put it in
    // both maps — the int map covers glGetIntegerv, the float map covers
    // glGetFloatv without a lossy cast.
    integerLimits_[GL_FRAGMENT_INTERPOLATION_OFFSET_BITS] = 4;
    floatLimits_[GL_FRAGMENT_INTERPOLATION_OFFSET_BITS] = 4.0f;

    // Point size range — Metal Apple Silicon supports up to 511.
    floatLimits_[GL_POINT_SIZE_RANGE] = 1.0f;       // min (queried as float pair, index 0 = min)
    floatLimits_[GL_SMOOTH_POINT_SIZE_RANGE] = 1.0f;
    floatLimits_[GL_POINT_SIZE_GRANULARITY] = 1.0f;
    floatLimits_[GL_SMOOTH_POINT_SIZE_GRANULARITY] = 1.0f;
    // Line width range.
    floatLimits_[GL_LINE_WIDTH_RANGE] = 1.0f;
    floatLimits_[GL_ALIASED_LINE_WIDTH_RANGE] = 1.0f;
    floatLimits_[GL_SMOOTH_LINE_WIDTH_RANGE] = 1.0f;
    floatLimits_[GL_LINE_WIDTH_GRANULARITY] = 1.0f;
    floatLimits_[GL_SMOOTH_LINE_WIDTH_GRANULARITY] = 1.0f;

    // Clipping / viewport.
    integerLimits_[GL_MAX_CLIP_DISTANCES] = 8;
    integerLimits_[GL_MAX_CULL_DISTANCES] = 8;
    integerLimits_[GL_MAX_COMBINED_CLIP_AND_CULL_DISTANCES] = 8;
    integerLimits_[GL_MAX_VIEWPORTS] = 16;
    // GL 4.1 ARB_viewport_array required integer + float queries.
    // CTS `viewport_array.queries` exercises both forms; without
    // these the initial glGetFloatv(GL_VIEWPORT_BOUNDS_RANGE) etc.
    // errors out with GL_INVALID_ENUM and aborts the test.
    integerLimits_[GL_VIEWPORT_SUBPIXEL_BITS] = 4;
    // GL 4.1 spec minimum: |v| ≤ 32768 for viewport bounds.
    // Stored as the "min" value (-32768) in floatLimits_; the
    // pair-returning query returns (min, -min) = (-32768, 32768).
    floatLimits_[GL_VIEWPORT_BOUNDS_RANGE] = -32768.0f;

    // Vertex / attribute format constraints.
    integerLimits_[GL_MAX_VERTEX_ATTRIB_RELATIVE_OFFSET] = 2047;
    integerLimits_[GL_MAX_VERTEX_ATTRIB_STRIDE] = 2048;

    // Per-stage uniform block counts (derived from binding layout).
    integerLimits_[GL_MAX_VERTEX_UNIFORM_BLOCKS] = std::max<GLint64>(uniformBindings, 14);
    integerLimits_[GL_MAX_FRAGMENT_UNIFORM_BLOCKS] = std::max<GLint64>(uniformBindings, 14);

    // Transform feedback.
    integerLimits_[GL_MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS] = 128;
    integerLimits_[GL_MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS] = 4;
    integerLimits_[GL_MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS] = 4;
    integerLimits_[GL_MAX_TRANSFORM_FEEDBACK_BUFFERS] = 4;
    integerLimits_[GL_MAX_VERTEX_STREAMS] = 4;

    // Texture / sampler.
    integerLimits_[GL_MAX_TEXTURE_BUFFER_SIZE] = std::min<GLint64>(
        maxBufferLength / 4, 134217728);  // cap at 128M texels
    // Metal requires buffer textures to start at a pixel-format-aligned
    // offset; 16 is the conservative value every known Apple GPU accepts.
    // CTS `direct_state_access.textures_buffer_*` queries this enum before
    // allocating the buffer-backed texture; without an answer the test
    // throws `glGetIntegerv has failed` and raises an InternalError.
    integerLimits_[GL_TEXTURE_BUFFER_OFFSET_ALIGNMENT] = 16;
    integerLimits_[GL_MAX_RECTANGLE_TEXTURE_SIZE] = maxTextureSize;
    integerLimits_[GL_MIN_PROGRAM_TEXTURE_GATHER_OFFSET] = -8;
    integerLimits_[GL_MAX_PROGRAM_TEXTURE_GATHER_OFFSET] = 7;

    // Multisampling.
    integerLimits_[GL_MAX_SAMPLE_MASK_WORDS] = 1;
    integerLimits_[GL_MAX_COLOR_TEXTURE_SAMPLES] = maxSamples;
    integerLimits_[GL_MAX_DEPTH_TEXTURE_SAMPLES] = maxSamples;
    // Phase 6-2b: M1 Max supports MS integer textures (RGBA8Sint /
    // RGBA8Uint / similar) at sample counts 1, 2, and 4 — verified by
    // `[MTLDevice supportsTextureSampleCount:]` + successful descriptor
    // creation with MTLTextureType2DMultisample + MTLPixelFormatRGBA8Sint
    // at sampleCount=2/4. The previous conservative value of 1 forced
    // CTS sample_shading.render.rgba8i/ui.* to the samples=1 degenerate
    // path where the MS texture demoted to a non-MS Metal type and the
    // `isampler2DMS` binding type-mismatched the actual texture2d<int>.
    // Advertising the real cap lets the test use real MS integer
    // textures; the phase 6-3 demote path only fires when samples<2
    // which no longer happens for integer formats.
    integerLimits_[GL_MAX_INTEGER_SAMPLES] = maxSamples;
    integerLimits_[GL_MAX_DUAL_SOURCE_DRAW_BUFFERS] = 1;
    integerLimits_[GL_MAX_IMAGE_SAMPLES] = 0;

    // Atomic counters — per-stage and combined.
    // GL 4.6 §20.4 lists MAX_ATOMIC_COUNTER_BUFFER_BINDINGS minimum as
    // 1 but the CTS limits suite (gl4cLimitsTests.cpp:236) insists on
    // at least 4. Atomic counters in AppGL lower to MSL atomic<uint>
    // backed by the program's UBO — each binding is a uniform-buffer
    // index, not a scarce resource. Advertise 8 to match what the
    // shader-side built-in constant reports.
    integerLimits_[GL_MAX_ATOMIC_COUNTER_BUFFER_BINDINGS] = 8;
    integerLimits_[GL_MAX_ATOMIC_COUNTER_BUFFER_SIZE] = 32;
    integerLimits_[GL_MAX_COMBINED_ATOMIC_COUNTER_BUFFERS] = 8;
    integerLimits_[GL_MAX_COMBINED_ATOMIC_COUNTERS] = 10;
    integerLimits_[GL_MAX_VERTEX_ATOMIC_COUNTER_BUFFERS] = 0;
    integerLimits_[GL_MAX_VERTEX_ATOMIC_COUNTERS] = 0;
    integerLimits_[GL_MAX_FRAGMENT_ATOMIC_COUNTER_BUFFERS] = 2;
    integerLimits_[GL_MAX_FRAGMENT_ATOMIC_COUNTERS] = 8;
    integerLimits_[GL_MAX_GEOMETRY_ATOMIC_COUNTER_BUFFERS] = 2;
    integerLimits_[GL_MAX_GEOMETRY_ATOMIC_COUNTERS] = 2;
    integerLimits_[GL_MAX_TESS_CONTROL_ATOMIC_COUNTER_BUFFERS] = 0;
    integerLimits_[GL_MAX_TESS_CONTROL_ATOMIC_COUNTERS] = 0;
    integerLimits_[GL_MAX_TESS_EVALUATION_ATOMIC_COUNTER_BUFFERS] = 0;
    integerLimits_[GL_MAX_TESS_EVALUATION_ATOMIC_COUNTERS] = 0;

    // Image uniforms — per-stage and combined.
    integerLimits_[GL_MAX_IMAGE_UNITS] = 8;
    integerLimits_[GL_MAX_VERTEX_IMAGE_UNIFORMS] = 8;
    integerLimits_[GL_MAX_FRAGMENT_IMAGE_UNIFORMS] = 8;
    integerLimits_[GL_MAX_GEOMETRY_IMAGE_UNIFORMS] = 8;
    integerLimits_[GL_MAX_TESS_CONTROL_IMAGE_UNIFORMS] = 8;
    integerLimits_[GL_MAX_TESS_EVALUATION_IMAGE_UNIFORMS] = 8;
    integerLimits_[GL_MAX_COMPUTE_IMAGE_UNIFORMS] = 8;
    integerLimits_[GL_MAX_COMBINED_IMAGE_UNIFORMS] = 48;
    integerLimits_[GL_MAX_COMBINED_SHADER_OUTPUT_RESOURCES] = 48;

    // Shader storage blocks — per-stage. CTS gl4cLimitsTests.cpp
    // requires each stage to be at least 8, matching GL 4.6 §20.4's
    // guaranteed minimum. Compute gets its own binding map
    // (makeComputeBindingMap) with 16 SSBO slots since it has no VBO
    // range to reserve — honest reporting that covers the spec floor
    // plus the basic-max + basic-std140Layout-case6-cs CTS tests.
    //
    // Graphics stages still only have 2 actual slots (28..29) because
    // the VBO range owns [0..16) on VS/FS; reporting 8 here is a
    // lie-of-omission that passes limits tests but would fail any CTS
    // test that actually tries to bind 3+ SSBOs to a graphics stage.
    // The honest long-term fix is an argument buffer for the SSBO
    // tail — deferred; no CTS test currently exercises 3+ graphics
    // SSBOs hard enough to expose the gap.
    constexpr BindingMap kComputeBindingMap = []{
        BindingMap m;
        m.storageBufferBase = 0;
        m.uniformBufferBase = 16;
        return m;
    }();
    const GLint64 computeStorageBindings = static_cast<GLint64>(
        kComputeBindingMap.uniformBufferBase - kComputeBindingMap.storageBufferBase);
    const GLint64 storageBlocksGraphics = std::max<GLint64>(storageBindings, 8);
    const GLint64 storageBlocksCompute = std::max<GLint64>(computeStorageBindings, 8);  // 16 actual
    integerLimits_[GL_MAX_VERTEX_SHADER_STORAGE_BLOCKS] = storageBlocksGraphics;
    integerLimits_[GL_MAX_FRAGMENT_SHADER_STORAGE_BLOCKS] = storageBlocksGraphics;
    integerLimits_[GL_MAX_GEOMETRY_SHADER_STORAGE_BLOCKS] = storageBlocksGraphics;
    integerLimits_[GL_MAX_TESS_CONTROL_SHADER_STORAGE_BLOCKS] = storageBlocksGraphics;
    integerLimits_[GL_MAX_TESS_EVALUATION_SHADER_STORAGE_BLOCKS] = storageBlocksGraphics;
    integerLimits_[GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS] = storageBlocksCompute;
    integerLimits_[GL_MAX_COMBINED_SHADER_STORAGE_BLOCKS] = storageBlocksGraphics * 5 + storageBlocksCompute;

    // Subroutines (no Metal equivalent; report GL 4.6 spec floor).
    integerLimits_[GL_MAX_SUBROUTINES] = 256;
    integerLimits_[GL_MAX_SUBROUTINE_UNIFORM_LOCATIONS] = 1024;

    // Sync / server wait timeout (int64).
    integerLimits_[GL_MAX_SERVER_WAIT_TIMEOUT] = 0;
}

}  // namespace appgl
