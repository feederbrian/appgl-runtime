#include "GLCapabilities.h"

#import <Metal/Metal.h>

#include <algorithm>

#include "../shader/ShaderTranslator.h"

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
    integerLimits_[GL_NUM_EXTENSIONS] = 37;
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
