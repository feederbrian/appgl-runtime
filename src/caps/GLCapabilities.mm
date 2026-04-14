#include "GLCapabilities.h"

#import <Metal/Metal.h>

#include <algorithm>

namespace appgl {

GLCapabilities::GLCapabilities(void* metalDevice) {
    initializeFormatTable();
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
    if (value == integerLimits_.end()) {
        return false;
    }
    *out = static_cast<GLint>(value->second);
    return true;
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
    if (value == integerLimits_.end()) {
        return false;
    }
    *out = value->second;
    return true;
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

void GLCapabilities::initializeFormatTable() {
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

    add(GL_R8, MTLPixelFormatR8Unorm, true, true, false, false, false);
    add(GL_RG8, MTLPixelFormatRG8Unorm, true, true, false, false, false);
    add(GL_RGB8, MTLPixelFormatRGBA8Unorm, false, true, false, false, false);
    add(GL_RGBA8, MTLPixelFormatRGBA8Unorm, true, true, true, false, false);
    add(GL_SRGB8_ALPHA8, MTLPixelFormatRGBA8Unorm_sRGB, true, true, true, true, false);
    add(GL_DEPTH_COMPONENT24, MTLPixelFormatDepth32Float, true, false, false, false, false);
    add(GL_DEPTH_COMPONENT32F, MTLPixelFormatDepth32Float, true, false, false, false, false);
    add(GL_DEPTH24_STENCIL8, MTLPixelFormatDepth32Float_Stencil8, true, false, false, false, false);
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
