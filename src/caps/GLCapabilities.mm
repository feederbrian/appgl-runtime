#include "GLCapabilities.h"

#import <Metal/Metal.h>

#include <algorithm>

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
    initializeExtensions();
}

const std::string& GLCapabilities::extensionString() const {
    return extensions_;
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
    if (pname == GL_MAX_VIEWPORT_DIMS) {
        const auto value = integerLimits_.find(GL_MAX_VIEWPORT_DIMS);
        if (value == integerLimits_.end()) {
            return false;
        }
        out[0] = value->second;
        out[1] = value->second;
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
    // Depth / stencil. DEPTH_COMPONENT24 maps to Depth32Float because Metal
    // has no native 24-bit depth — precision goes up, sample semantics are
    // the same. STENCIL_INDEX8 is a dedicated Metal format.
    // ------------------------------------------------------------------
    add(GL_DEPTH_COMPONENT16, MTLPixelFormatDepth16Unorm, true, false, false, false, false);
    add(GL_DEPTH_COMPONENT24, MTLPixelFormatDepth32Float, true, false, false, false, false);
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

        // S3TC (BC1/BC2/BC3) is not in the AppGL generated enum header yet
        // — S3TC is an optional extension that BAR doesn't currently use.
        // Skipping registration here keeps the cap table aligned with the
        // symbols the engine can actually reference.
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

    if (device != nil) {
        maxBufferLength = static_cast<GLint64>(device.maxBufferLength);
        if ([device supportsFamily:MTLGPUFamilyApple7] || [device supportsFamily:MTLGPUFamilyMac2]) {
            maxTextureSize = 16384;
            max3DTextureSize = 2048;
            maxArrayLayers = 2048;
            maxSamples = 8;
            maxViewportDimension = 16384;
        }
    }

    integerLimits_[GL_MAX_TEXTURE_SIZE] = maxTextureSize;
    integerLimits_[GL_MAX_CUBE_MAP_TEXTURE_SIZE] = maxTextureSize;
    integerLimits_[GL_MAX_3D_TEXTURE_SIZE] = max3DTextureSize;
    integerLimits_[GL_MAX_ARRAY_TEXTURE_LAYERS] = maxArrayLayers;
    integerLimits_[GL_MAX_COLOR_ATTACHMENTS] = 8;
    integerLimits_[GL_MAX_DRAW_BUFFERS] = 8;
    integerLimits_[GL_MAX_VERTEX_ATTRIBS] = 16;
    integerLimits_[GL_MAX_TEXTURE_IMAGE_UNITS] = 16;
    integerLimits_[GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS] = 32;
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
    // Phase 8X Group 4d follow-up⁷ — SSBO offset alignment. Sibling of the
    // UBO alignment above; GL 4.3 introduces shader storage buffers with
    // the same `setBufferOffset:` constraint on the Metal side. Published
    // as the universal Mac floor (256) for the same reason — safe on both
    // Apple-family and Mac2-family GPUs, strictly wider than the GL spec
    // minimum of 1. BAR surfaced this pname as the single `0x90DF` hit in
    // followup⁶ verification §5, where Recoil probes it once at startup to
    // size its SSBO ring buffer. Publishing it here moves that probe from
    // GL_INVALID_ENUM to a clean scalar read without touching the draw
    // path.
    integerLimits_[GL_SHADER_STORAGE_BUFFER_OFFSET_ALIGNMENT] = 256;
    integerLimits_[GL_MAX_VERTEX_UNIFORM_COMPONENTS] = 4096;
    integerLimits_[GL_MAX_FRAGMENT_UNIFORM_COMPONENTS] = 4096;
    integerLimits_[GL_MAX_SAMPLES] = maxSamples;
    integerLimits_[GL_MAX_RENDERBUFFER_SIZE] = maxTextureSize;
    integerLimits_[GL_MAX_VIEWPORT_DIMS] = maxViewportDimension;
    // GL 4.3 spec: GL_MAX_ELEMENT_INDEX must be at least 2^32 - 2 for the largest
    // index type (GL_UNSIGNED_INT). It is a property of the index format, not of
    // any particular buffer's storage size.
    integerLimits_[GL_MAX_ELEMENT_INDEX] = static_cast<GLint64>(0xFFFFFFFEull);
    integerLimits_[GL_MAX_ELEMENTS_INDICES] = std::min<GLint64>(maxBufferLength / 4, 0x7fffffff);
    integerLimits_[GL_MAX_ELEMENTS_VERTICES] = std::min<GLint64>(maxBufferLength / 16, 0x7fffffff);
    integerLimits_[GL_MAX_DEBUG_MESSAGE_LENGTH] = 1024;
    integerLimits_[GL_MAX_DEBUG_LOGGED_MESSAGES] = 64;
    integerLimits_[GL_MAX_DEBUG_GROUP_STACK_DEPTH] = 64;
    integerLimits_[GL_MAX_LABEL_LENGTH] = 1024;
    integerLimits_[GL_MIN_MAP_BUFFER_ALIGNMENT] = 64;
    // GL 3.0+ core: glGetIntegerv(GL_NUM_EXTENSIONS) is the canonical way to
    // probe the indexed-extension list. Loaders such as GLAD rely on this
    // returning a non-zero count before they will populate the extension
    // table; without it they treat the context as "no GL symbols visible".
    // Bumped from 37 → 38 in Phase 8X Group 4d follow-up¹⁶ when
    // GL_ARB_map_buffer_range was added to both extension tables.
    // Bumped from 38 → 42 in Phase 8X Group 4d follow-up²² when the
    // buffer-family ARB/EXT aliases (vertex_buffer_object, copy_buffer,
    // draw_elements_base_vertex, EXT_pixel_buffer_object) were added so
    // GLAD's string-matched has_ext() flips Recoil's VBO::IsSupported
    // gates from their default-false state.
    integerLimits_[GL_NUM_EXTENSIONS] = 42;
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
    integerLimits_[GL_MAX_UNIFORM_BUFFER_BINDINGS] = uniformBindings;
    integerLimits_[GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS] = storageBindings;
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
    integerLimits_[GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS] = 16;
    integerLimits_[GL_MAX_GEOMETRY_TEXTURE_IMAGE_UNITS] = 16;
    integerLimits_[GL_MAX_COMPUTE_TEXTURE_IMAGE_UNITS] = 16;
    integerLimits_[GL_MAX_TESS_CONTROL_TEXTURE_IMAGE_UNITS] = 16;
    integerLimits_[GL_MAX_TESS_EVALUATION_TEXTURE_IMAGE_UNITS] = 16;

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
    integerLimits_[GL_MAX_GEOMETRY_UNIFORM_BLOCKS] = uniformBindings;
    integerLimits_[GL_MAX_GEOMETRY_SHADER_INVOCATIONS] = 32;

    // Tessellation caps. Same emulation-gap caveat as geometry: the
    // translator will eventually lower these onto Metal's tessellator via
    // MTLComputePipelineState + tessellation factor buffers, but the cap
    // numbers need to be reported now so engines don't fall back.
    integerLimits_[GL_MAX_TESS_CONTROL_INPUT_COMPONENTS] = 128;
    integerLimits_[GL_MAX_TESS_CONTROL_OUTPUT_COMPONENTS] = 128;
    integerLimits_[GL_MAX_TESS_CONTROL_TOTAL_OUTPUT_COMPONENTS] = 4096;
    integerLimits_[GL_MAX_TESS_CONTROL_UNIFORM_COMPONENTS] = 1024;
    integerLimits_[GL_MAX_TESS_CONTROL_UNIFORM_BLOCKS] = uniformBindings;
    integerLimits_[GL_MAX_TESS_EVALUATION_INPUT_COMPONENTS] = 128;
    integerLimits_[GL_MAX_TESS_EVALUATION_OUTPUT_COMPONENTS] = 128;
    integerLimits_[GL_MAX_TESS_EVALUATION_UNIFORM_COMPONENTS] = 1024;
    integerLimits_[GL_MAX_TESS_EVALUATION_UNIFORM_BLOCKS] = uniformBindings;
    integerLimits_[GL_MAX_TESS_GEN_LEVEL] = 64;
    integerLimits_[GL_MAX_TESS_PATCH_COMPONENTS] = 120;
    integerLimits_[GL_MAX_PATCH_VERTICES] = 32;

    // Compute caps. Metal's threadgroup limits are 1024 invocations total
    // with shared memory tiers of 16K/32K depending on GPU family; use the
    // high value so engines sizing compute passes don't under-subscribe.
    integerLimits_[GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS] = 1024;
    integerLimits_[GL_MAX_COMPUTE_SHARED_MEMORY_SIZE] = 32768;
    integerLimits_[GL_MAX_COMPUTE_UNIFORM_COMPONENTS] = 1024;
    integerLimits_[GL_MAX_COMPUTE_UNIFORM_BLOCKS] = uniformBindings;
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
    const GLint64 combinedUniforms = 4096 + uniformBindings * (maxUniformBlockSize / 4);
    integerLimits_[GL_MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS] = combinedUniforms;
    integerLimits_[GL_MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS] = combinedUniforms;
    integerLimits_[GL_MAX_COMBINED_GEOMETRY_UNIFORM_COMPONENTS] = combinedUniforms;
    integerLimits_[GL_MAX_COMBINED_COMPUTE_UNIFORM_COMPONENTS] = combinedUniforms;
    integerLimits_[GL_MAX_COMBINED_TESS_CONTROL_UNIFORM_COMPONENTS] = combinedUniforms;
    integerLimits_[GL_MAX_COMBINED_TESS_EVALUATION_UNIFORM_COMPONENTS] = combinedUniforms;
    integerLimits_[GL_MAX_COMBINED_UNIFORM_BLOCKS] = uniformBindings * 6;

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
}

void GLCapabilities::initializeExtensions() {
    // Advertise the full extension set that the AppGL surface emulates on
    // top of Metal. GL loaders (GLAD in particular) wire their per-extension
    // bool flags from the strings returned by glGetStringi(GL_EXTENSIONS, i),
    // so this list must include every extension the host engine probes —
    // even the ones that are core in 4.6, because loaders don't auto-promote
    // ARB/EXT flags from the version number.
    //
    // Keep in sync with kAppGLExtensionList in AppGLGroup8.cpp and the
    // GL_NUM_EXTENSIONS limit above.
    extensions_ =
        "GL_KHR_debug "
        "GL_ARB_debug_output "
        "GL_ARB_multitexture "
        "GL_ARB_texture_env_combine "
        "GL_ARB_texture_compression "
        "GL_ARB_texture_float "
        "GL_ARB_texture_non_power_of_two "
        "GL_ARB_texture_query_lod "
        "GL_ARB_framebuffer_object "
        "GL_EXT_framebuffer_object "
        "GL_EXT_framebuffer_multisample "
        "GL_EXT_texture_filter_anisotropic "
        "GL_ARB_vertex_shader "
        "GL_ARB_fragment_shader "
        "GL_ARB_geometry_shader4 "
        "GL_ARB_uniform_buffer_object "
        // Phase 8X Group 4d follow-up¹⁶ — see the matching entry and
        // the longer comment in `kAppGLExtensionList` (AppGLGroup8.cpp).
        // The `glMapBufferRange` family is implemented; this advertises
        // the extension so loaders set GLAD_GL_ARB_map_buffer_range = 1.
        "GL_ARB_map_buffer_range "
        // Phase 8X Group 4d follow-up²² — buffer-family aliases that
        // BAR/Recoil's `VBO::IsSupported` gate reads through GLAD's
        // string-matched `has_ext()`. All four correspond to features
        // that are either core since GL 2.1/3.1/3.2 or otherwise fully
        // implemented on the AppGL surface; advertising them here flips
        // the GLAD bool so Recoil's buffer path stops short-circuiting.
        // See the matching block in `kAppGLExtensionList` for the full
        // gate analysis.
        "GL_ARB_vertex_buffer_object "
        "GL_ARB_copy_buffer "
        "GL_ARB_draw_elements_base_vertex "
        "GL_EXT_pixel_buffer_object "
        "GL_ARB_shader_storage_buffer_object "
        "GL_ARB_explicit_attrib_location "
        "GL_ARB_explicit_uniform_location "
        "GL_ARB_buffer_storage "
        "GL_ARB_multi_draw_indirect "
        "GL_ARB_clip_control "
        "GL_ARB_seamless_cube_map "
        "GL_ARB_conservative_depth "
        "GL_ARB_timer_query "
        "GL_ARB_multisample "
        "GL_ARB_vertex_array_object "
        "GL_ARB_instanced_arrays "
        "GL_ARB_draw_instanced "
        "GL_ARB_base_instance "
        "GL_ARB_sampler_objects "
        "GL_ARB_texture_storage "
        "GL_ARB_texture_swizzle "
        "GL_ARB_separate_shader_objects "
        "GL_ARB_program_interface_query "
        "GL_ARB_shading_language_420pack "
        "GL_ARB_shading_language_packing";
}

}  // namespace appgl
