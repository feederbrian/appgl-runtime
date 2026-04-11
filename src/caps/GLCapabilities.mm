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
    integerLimits_[GL_MAX_ELEMENT_INDEX] = std::min<GLint64>(maxBufferLength / 4, 0x7fffffff);
    integerLimits_[GL_MAX_DEBUG_MESSAGE_LENGTH] = 1024;
    integerLimits_[GL_MAX_DEBUG_LOGGED_MESSAGES] = 64;
    integerLimits_[GL_MAX_DEBUG_GROUP_STACK_DEPTH] = 64;
    integerLimits_[GL_MAX_LABEL_LENGTH] = 1024;
    integerLimits_[GL_MIN_MAP_BUFFER_ALIGNMENT] = 64;
}

void GLCapabilities::initializeExtensions() {
    extensions_ = "GL_KHR_debug";
}

}  // namespace appgl
