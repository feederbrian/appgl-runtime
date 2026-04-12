#include "GLContext.h"
#include "MetalFrameGraph.h"
#include "../caps/GLCapabilities.h"
#include "../objects/GLObjectStore.h"
#include "../runtime/AppGLRuntime.h"
#include "../shader/GLSLReflection.h"
#include "../shader/ShaderTranslator.h"
#include "../state/GLStateTracker.h"
#include "../state/IndexExpansion.h"
#include "../state/MetalVertexDescriptorBuilder.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace appgl {
namespace {

constexpr std::size_t kMaxDebugMessages = 64;
constexpr std::size_t kMaxDebugMessageLength = 1024;
constexpr std::size_t kMaxDebugGroupDepth = 64;

struct DebugMessageRecord {
    GLenum source = GL_DEBUG_SOURCE_APPLICATION;
    GLenum type = GL_DEBUG_TYPE_OTHER;
    GLuint id = 0;
    GLenum severity = GL_DEBUG_SEVERITY_NOTIFICATION;
    std::string message;
};

struct DebugControlRule {
    GLenum source = GL_DONT_CARE;
    GLenum type = GL_DONT_CARE;
    GLenum severity = GL_DONT_CARE;
    std::unordered_set<GLuint> ids;
    bool hasIds = false;
    bool enabled = true;
};

std::uint64_t objectLabelKey(GLenum identifier, GLuint name) {
    return (static_cast<std::uint64_t>(identifier) << 32u) | static_cast<std::uint64_t>(name);
}

bool matchesDebugField(GLenum rule, GLenum value) {
    return rule == GL_DONT_CARE || rule == value;
}

bool debugRuleMatches(const DebugControlRule& rule, const DebugMessageRecord& message) {
    if (!matchesDebugField(rule.source, message.source)
        || !matchesDebugField(rule.type, message.type)
        || !matchesDebugField(rule.severity, message.severity)) {
        return false;
    }
    return !rule.hasIds || rule.ids.contains(message.id);
}

std::string trimDebugMessage(std::string_view message) {
    const std::size_t maxPayload = kMaxDebugMessageLength > 0 ? kMaxDebugMessageLength - 1 : 0;
    const std::size_t count = std::min(message.size(), maxPayload);
    return std::string(message.substr(0, count));
}

void copyLabelString(std::string_view value, GLsizei bufSize, GLsizei* length, GLchar* label) {
    if (length != nullptr) {
        *length = static_cast<GLsizei>(value.size());
    }
    if (label == nullptr || bufSize <= 0) {
        return;
    }

    const std::size_t writable = static_cast<std::size_t>(bufSize - 1);
    const std::size_t copied = std::min(value.size(), writable);
    if (copied > 0) {
        std::memcpy(label, value.data(), copied);
    }
    label[copied] = '\0';
}

void* transferRetainedMetalObject(id object) {
    if (object == nil) {
        return nullptr;
    }
#if __has_feature(objc_arc)
    return (__bridge_retained void*)object;
#else
    return object;
#endif
}

void releaseRetainedMetalObject(void* object) {
    if (object == nullptr) {
        return;
    }
#if __has_feature(objc_arc)
    CFRelease(object);
#else
    [(id)object release];
#endif
}

id<MTLBuffer> metalBufferFromRaw(void* object) {
    if (object == nullptr) {
        return nil;
    }
#if __has_feature(objc_arc)
    return (__bridge id<MTLBuffer>)object;
#else
    return (id<MTLBuffer>)object;
#endif
}

MTLResourceOptions metalBufferOptionsForUsage(GLenum usage) {
    MTLResourceOptions options = MTLResourceStorageModeShared;
    switch (usage) {
        case GL_STREAM_DRAW:
        case GL_STATIC_DRAW:
        case GL_DYNAMIC_DRAW:
            options |= MTLResourceCPUCacheModeWriteCombined;
            break;
        default:
            break;
    }
    return options;
}

MTLTextureType metalTextureTypeForTarget(GLenum target) {
    switch (target) {
        case GL_TEXTURE_1D:
            return MTLTextureType1D;
        case GL_TEXTURE_2D:
            return MTLTextureType2D;
        case GL_TEXTURE_3D:
            return MTLTextureType3D;
        default:
            return MTLTextureType2D;
    }
}

id<MTLTexture> metalTextureFromRaw(void* object) {
    if (object == nullptr) {
        return nil;
    }
#if __has_feature(objc_arc)
    return (__bridge id<MTLTexture>)object;
#else
    return (id<MTLTexture>)object;
#endif
}

MTLPixelFormat metalRenderbufferFormat(GLenum internalFormat) {
    switch (internalFormat) {
        case GL_RGB:
        case GL_RGBA:
        case GL_RGB8:
        case GL_RGBA8:
            return MTLPixelFormatRGBA8Unorm;
        case GL_DEPTH_COMPONENT:
        case GL_DEPTH_COMPONENT16:
        case GL_DEPTH_COMPONENT24:
        case GL_DEPTH_COMPONENT32:
        case GL_DEPTH_COMPONENT32F:
            return MTLPixelFormatDepth32Float;
        case GL_STENCIL_INDEX:
        case GL_STENCIL_INDEX8:
            return MTLPixelFormatStencil8;
        case GL_DEPTH_STENCIL:
        case GL_DEPTH24_STENCIL8:
        case GL_DEPTH32F_STENCIL8:
            return MTLPixelFormatDepth32Float_Stencil8;
        default:
            return MTLPixelFormatInvalid;
    }
}

bool isSupportedRenderbufferFormat(GLenum internalFormat) {
    return metalRenderbufferFormat(internalFormat) != MTLPixelFormatInvalid;
}

bool isColorAttachment(GLenum attachment) {
    return attachment >= GL_COLOR_ATTACHMENT0 && attachment < GL_COLOR_ATTACHMENT0 + 8;
}

bool isFramebufferAttachment(GLenum attachment) {
    return isColorAttachment(attachment)
        || attachment == GL_DEPTH_ATTACHMENT
        || attachment == GL_STENCIL_ATTACHMENT
        || attachment == GL_DEPTH_STENCIL_ATTACHMENT;
}

bool isFramebufferColorBuffer(GLenum buffer) {
    return buffer >= GL_COLOR_ATTACHMENT0 && buffer < GL_COLOR_ATTACHMENT0 + 8;
}

bool isDefaultFramebufferBuffer(GLenum buffer) {
    return buffer == GL_NONE
        || buffer == GL_FRONT
        || buffer == GL_BACK
        || buffer == GL_FRONT_AND_BACK
        || buffer == GL_FRONT_LEFT
        || buffer == GL_BACK_LEFT;
}

bool isDepthFormat(GLenum internalFormat) {
    switch (internalFormat) {
        case GL_DEPTH_COMPONENT:
        case GL_DEPTH_COMPONENT16:
        case GL_DEPTH_COMPONENT24:
        case GL_DEPTH_COMPONENT32:
        case GL_DEPTH_COMPONENT32F:
        case GL_DEPTH_STENCIL:
        case GL_DEPTH24_STENCIL8:
        case GL_DEPTH32F_STENCIL8:
            return true;
        default:
            return false;
    }
}

bool isStencilFormat(GLenum internalFormat) {
    switch (internalFormat) {
        case GL_STENCIL_INDEX:
        case GL_STENCIL_INDEX8:
        case GL_DEPTH_STENCIL:
        case GL_DEPTH24_STENCIL8:
        case GL_DEPTH32F_STENCIL8:
            return true;
        default:
            return false;
    }
}

bool isColorFormat(GLenum internalFormat) {
    return !isDepthFormat(internalFormat) && !isStencilFormat(internalFormat);
}

bool isTextureTarget(GLenum target) {
    return target == GL_TEXTURE_1D || target == GL_TEXTURE_2D || target == GL_TEXTURE_3D;
}

bool isSupportedInternalTextureFormat(GLenum internalFormat) {
    switch (internalFormat) {
        case GL_RED:
        case GL_RG:
        case GL_RGB:
        case GL_RGBA:
        case GL_R8:
        case GL_RG8:
        case GL_RGB8:
        case GL_RGBA8:
            return true;
        default:
            return false;
    }
}

std::size_t componentCountForFormat(GLenum format) {
    switch (format) {
        case GL_RED:
            return 1;
        case GL_RG:
            return 2;
        case GL_RGB:
            return 3;
        case GL_RGBA:
            return 4;
        default:
            return 0;
    }
}

bool isPowerOfTwoAlignment(GLint value) {
    return value == 1 || value == 2 || value == 4 || value == 8;
}

std::size_t alignByteCount(std::size_t value, GLint alignment) {
    const std::size_t align = static_cast<std::size_t>(alignment > 0 ? alignment : 1);
    return ((value + align - 1u) / align) * align;
}

std::size_t safeDimension(GLsizei value) {
    return static_cast<std::size_t>(std::max<GLsizei>(value, 1));
}

std::uint8_t normalizedByte(GLfloat value) {
    const GLfloat clamped = std::clamp(value, 0.0f, 1.0f);
    return static_cast<std::uint8_t>(clamped * 255.0f + 0.5f);
}

std::size_t rgba8ByteCount(GLsizei width, GLsizei height, GLsizei depth) {
    return safeDimension(width) * safeDimension(height) * safeDimension(depth) * 4u;
}

GLsizei mipDimension(GLsizei base, GLint levelOffset) {
    if (levelOffset <= 0) {
        return std::max<GLsizei>(base, 1);
    }
    return std::max<GLsizei>(base >> levelOffset, 1);
}

GLint mipTailOffset(GLsizei width, GLsizei height, GLsizei depth) {
    std::size_t maxDimension = std::max({safeDimension(width), safeDimension(height), safeDimension(depth)});
    GLint offset = 0;
    while (maxDimension > 1) {
        maxDimension >>= 1;
        ++offset;
    }
    return offset;
}

std::vector<std::uint8_t> downsampleRGBA8(
    const std::vector<std::uint8_t>& source,
    GLsizei sourceWidth,
    GLsizei sourceHeight,
    GLsizei sourceDepth,
    GLsizei destWidth,
    GLsizei destHeight,
    GLsizei destDepth
) {
    std::vector<std::uint8_t> dest(rgba8ByteCount(destWidth, destHeight, destDepth), 0);
    if (source.empty()) {
        return dest;
    }

    for (GLsizei z = 0; z < destDepth; ++z) {
        for (GLsizei y = 0; y < destHeight; ++y) {
            for (GLsizei x = 0; x < destWidth; ++x) {
                std::uint32_t totals[4] = {};
                std::uint32_t samples = 0;
                for (GLsizei dz = 0; dz < 2; ++dz) {
                    const GLsizei sourceZ = std::min<GLsizei>(z * 2 + dz, sourceDepth - 1);
                    for (GLsizei dy = 0; dy < 2; ++dy) {
                        const GLsizei sourceY = std::min<GLsizei>(y * 2 + dy, sourceHeight - 1);
                        for (GLsizei dx = 0; dx < 2; ++dx) {
                            const GLsizei sourceX = std::min<GLsizei>(x * 2 + dx, sourceWidth - 1);
                            const std::size_t sourceOffset =
                                ((static_cast<std::size_t>(sourceZ) * static_cast<std::size_t>(sourceHeight)
                                    + static_cast<std::size_t>(sourceY))
                                    * static_cast<std::size_t>(sourceWidth)
                                    + static_cast<std::size_t>(sourceX))
                                * 4u;
                            for (std::size_t component = 0; component < 4; ++component) {
                                totals[component] += source[sourceOffset + component];
                            }
                            ++samples;
                        }
                    }
                }

                const std::size_t destOffset =
                    ((static_cast<std::size_t>(z) * static_cast<std::size_t>(destHeight)
                        + static_cast<std::size_t>(y))
                        * static_cast<std::size_t>(destWidth)
                        + static_cast<std::size_t>(x))
                    * 4u;
                for (std::size_t component = 0; component < 4; ++component) {
                    dest[destOffset + component] = static_cast<std::uint8_t>((totals[component] + samples / 2u) / samples);
                }
            }
        }
    }
    return dest;
}

MTLSamplerAddressMode metalAddressMode(GLint mode) {
    switch (mode) {
        case GL_CLAMP_TO_EDGE:
            return MTLSamplerAddressModeClampToEdge;
        case GL_CLAMP_TO_BORDER:
            if (@available(macOS 10.12, *)) {
                return MTLSamplerAddressModeClampToBorderColor;
            }
            return MTLSamplerAddressModeClampToEdge;
        case GL_MIRRORED_REPEAT:
            return MTLSamplerAddressModeMirrorRepeat;
        case GL_REPEAT:
        default:
            return MTLSamplerAddressModeRepeat;
    }
}

MTLSamplerMinMagFilter metalMinMagFilter(GLint filter) {
    switch (filter) {
        case GL_NEAREST:
        case GL_NEAREST_MIPMAP_NEAREST:
        case GL_NEAREST_MIPMAP_LINEAR:
            return MTLSamplerMinMagFilterNearest;
        case GL_LINEAR:
        case GL_LINEAR_MIPMAP_NEAREST:
        case GL_LINEAR_MIPMAP_LINEAR:
        default:
            return MTLSamplerMinMagFilterLinear;
    }
}

MTLSamplerMipFilter metalMipFilter(GLint filter) {
    switch (filter) {
        case GL_NEAREST_MIPMAP_NEAREST:
        case GL_LINEAR_MIPMAP_NEAREST:
            return MTLSamplerMipFilterNearest;
        case GL_NEAREST_MIPMAP_LINEAR:
        case GL_LINEAR_MIPMAP_LINEAR:
            return MTLSamplerMipFilterLinear;
        default:
            return MTLSamplerMipFilterNotMipmapped;
    }
}

MTLCompareFunction metalCompareFunction(GLint func) {
    switch (func) {
        case GL_NEVER:
            return MTLCompareFunctionNever;
        case GL_LESS:
            return MTLCompareFunctionLess;
        case GL_EQUAL:
            return MTLCompareFunctionEqual;
        case GL_LEQUAL:
            return MTLCompareFunctionLessEqual;
        case GL_GREATER:
            return MTLCompareFunctionGreater;
        case GL_NOTEQUAL:
            return MTLCompareFunctionNotEqual;
        case GL_GEQUAL:
            return MTLCompareFunctionGreaterEqual;
        case GL_ALWAYS:
        default:
            return MTLCompareFunctionAlways;
    }
}

bool legacyMapAccessToFlags(GLenum access, GLbitfield* flags) {
    if (flags == nullptr) {
        return false;
    }
    switch (access) {
        case GL_READ_ONLY:
            *flags = GL_MAP_READ_BIT;
            return true;
        case GL_WRITE_ONLY:
            *flags = GL_MAP_WRITE_BIT;
            return true;
        case GL_READ_WRITE:
            *flags = GL_MAP_READ_BIT | GL_MAP_WRITE_BIT;
            return true;
        default:
            return false;
    }
}

GLenum legacyMapAccessFromFlags(GLbitfield access) {
    const bool readable = (access & GL_MAP_READ_BIT) != 0;
    const bool writable = (access & GL_MAP_WRITE_BIT) != 0;
    if (readable && !writable) {
        return GL_READ_ONLY;
    }
    if (!readable && writable) {
        return GL_WRITE_ONLY;
    }
    return GL_READ_WRITE;
}

bool mapAccessWrites(GLbitfield access) {
    return (access & GL_MAP_WRITE_BIT) != 0;
}

bool isSupportedMapBufferRangeAccess(GLbitfield access) {
    constexpr GLbitfield kSupportedAccessBits = GL_MAP_READ_BIT
        | GL_MAP_WRITE_BIT
        | GL_MAP_INVALIDATE_RANGE_BIT
        | GL_MAP_INVALIDATE_BUFFER_BIT
        | GL_MAP_FLUSH_EXPLICIT_BIT
        | GL_MAP_UNSYNCHRONIZED_BIT;
    if ((access & ~kSupportedAccessBits) != 0) {
        return false;
    }
    const bool readable = (access & GL_MAP_READ_BIT) != 0;
    const bool writable = (access & GL_MAP_WRITE_BIT) != 0;
    if (!readable && !writable) {
        return false;
    }
    if (readable && (access & (GL_MAP_INVALIDATE_RANGE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT | GL_MAP_UNSYNCHRONIZED_BIT)) != 0) {
        return false;
    }
    return (access & GL_MAP_FLUSH_EXPLICIT_BIT) == 0 || writable;
}

void resetBufferMapping(GLBufferObject& object) {
    object.mapped = false;
    object.mapAccess = GL_READ_WRITE;
    object.mapAccessFlags = 0;
    object.mapOffset = 0;
    object.mapLength = 0;
    object.mapPointer = nullptr;
}

void markVertexDescriptorDirty(GLVertexArrayObject& vertexArray) {
    vertexArray.vertexDescriptorDirty = true;
    vertexArray.vertexDescriptorError.clear();
}

bool setTextureParameterInteger(GLTextureParameters& params, GLenum pname, const GLint* values) {
    if (values == nullptr) {
        return false;
    }
    switch (pname) {
        case GL_TEXTURE_MIN_FILTER:
            params.minFilter = values[0];
            return true;
        case GL_TEXTURE_MAG_FILTER:
            params.magFilter = values[0];
            return true;
        case GL_TEXTURE_WRAP_S:
            params.wrapS = values[0];
            return true;
        case GL_TEXTURE_WRAP_T:
            params.wrapT = values[0];
            return true;
        case GL_TEXTURE_WRAP_R:
            params.wrapR = values[0];
            return true;
        case GL_TEXTURE_BASE_LEVEL:
            params.baseLevel = values[0];
            return true;
        case GL_TEXTURE_MAX_LEVEL:
            params.maxLevel = values[0];
            return true;
        case GL_TEXTURE_COMPARE_MODE:
            params.compareMode = values[0];
            return true;
        case GL_TEXTURE_COMPARE_FUNC:
            params.compareFunc = values[0];
            return true;
        case GL_TEXTURE_SWIZZLE_R:
            params.swizzle[0] = values[0];
            return true;
        case GL_TEXTURE_SWIZZLE_G:
            params.swizzle[1] = values[0];
            return true;
        case GL_TEXTURE_SWIZZLE_B:
            params.swizzle[2] = values[0];
            return true;
        case GL_TEXTURE_SWIZZLE_A:
            params.swizzle[3] = values[0];
            return true;
        case GL_TEXTURE_SWIZZLE_RGBA:
            params.swizzle = {values[0], values[1], values[2], values[3]};
            return true;
        case GL_TEXTURE_BORDER_COLOR:
            params.borderColor = {
                static_cast<GLfloat>(values[0]),
                static_cast<GLfloat>(values[1]),
                static_cast<GLfloat>(values[2]),
                static_cast<GLfloat>(values[3])
            };
            return true;
        default:
            return false;
    }
}

bool setTextureParameterFloat(GLTextureParameters& params, GLenum pname, const GLfloat* values) {
    if (values == nullptr) {
        return false;
    }
    switch (pname) {
        case GL_TEXTURE_MIN_LOD:
            params.minLod = values[0];
            return true;
        case GL_TEXTURE_MAX_LOD:
            params.maxLod = values[0];
            return true;
        case GL_TEXTURE_BORDER_COLOR:
            params.borderColor = {values[0], values[1], values[2], values[3]};
            return true;
        case GL_TEXTURE_SWIZZLE_RGBA: {
            const GLint converted[4] = {
                static_cast<GLint>(values[0]),
                static_cast<GLint>(values[1]),
                static_cast<GLint>(values[2]),
                static_cast<GLint>(values[3])
            };
            return setTextureParameterInteger(params, pname, converted);
        }
        default: {
            const GLint converted[4] = {
                static_cast<GLint>(values[0]),
                0,
                0,
                0
            };
            return setTextureParameterInteger(params, pname, converted);
        }
    }
}

bool getTextureParameterInteger(const GLTextureParameters& params, GLenum pname, GLint* values) {
    if (values == nullptr) {
        return false;
    }
    switch (pname) {
        case GL_TEXTURE_MIN_FILTER:
            values[0] = params.minFilter;
            return true;
        case GL_TEXTURE_MAG_FILTER:
            values[0] = params.magFilter;
            return true;
        case GL_TEXTURE_WRAP_S:
            values[0] = params.wrapS;
            return true;
        case GL_TEXTURE_WRAP_T:
            values[0] = params.wrapT;
            return true;
        case GL_TEXTURE_WRAP_R:
            values[0] = params.wrapR;
            return true;
        case GL_TEXTURE_MIN_LOD:
            values[0] = static_cast<GLint>(params.minLod);
            return true;
        case GL_TEXTURE_MAX_LOD:
            values[0] = static_cast<GLint>(params.maxLod);
            return true;
        case GL_TEXTURE_BASE_LEVEL:
            values[0] = params.baseLevel;
            return true;
        case GL_TEXTURE_MAX_LEVEL:
            values[0] = params.maxLevel;
            return true;
        case GL_TEXTURE_COMPARE_MODE:
            values[0] = params.compareMode;
            return true;
        case GL_TEXTURE_COMPARE_FUNC:
            values[0] = params.compareFunc;
            return true;
        case GL_TEXTURE_SWIZZLE_R:
            values[0] = params.swizzle[0];
            return true;
        case GL_TEXTURE_SWIZZLE_G:
            values[0] = params.swizzle[1];
            return true;
        case GL_TEXTURE_SWIZZLE_B:
            values[0] = params.swizzle[2];
            return true;
        case GL_TEXTURE_SWIZZLE_A:
            values[0] = params.swizzle[3];
            return true;
        case GL_TEXTURE_SWIZZLE_RGBA:
            values[0] = params.swizzle[0];
            values[1] = params.swizzle[1];
            values[2] = params.swizzle[2];
            values[3] = params.swizzle[3];
            return true;
        case GL_TEXTURE_BORDER_COLOR:
            values[0] = static_cast<GLint>(params.borderColor[0]);
            values[1] = static_cast<GLint>(params.borderColor[1]);
            values[2] = static_cast<GLint>(params.borderColor[2]);
            values[3] = static_cast<GLint>(params.borderColor[3]);
            return true;
        default:
            return false;
    }
}

bool getTextureParameterFloat(const GLTextureParameters& params, GLenum pname, GLfloat* values) {
    if (values == nullptr) {
        return false;
    }
    if (pname == GL_TEXTURE_BORDER_COLOR) {
        values[0] = params.borderColor[0];
        values[1] = params.borderColor[1];
        values[2] = params.borderColor[2];
        values[3] = params.borderColor[3];
        return true;
    }
    if (pname == GL_TEXTURE_MIN_LOD) {
        values[0] = params.minLod;
        return true;
    }
    if (pname == GL_TEXTURE_MAX_LOD) {
        values[0] = params.maxLod;
        return true;
    }
    GLint integerValue[4] = {};
    if (!getTextureParameterInteger(params, pname, integerValue)) {
        return false;
    }
    values[0] = static_cast<GLfloat>(integerValue[0]);
    return true;
}

}  // namespace

struct GLContext::Impl {
    ~Impl() {
        if (objects == nullptr) {
            return;
        }
        objects->buffers().forEach([&](GLuint, GLBufferObject& buffer) {
            releaseBufferStorage(buffer);
        });
        objects->textures().forEach([&](GLuint, GLTextureObject& texture) {
            releaseTextureStorage(texture);
        });
        objects->renderbuffers().forEach([&](GLuint, GLRenderbufferObject& renderbuffer) {
            releaseRenderbufferStorage(renderbuffer);
        });
        objects->samplers().forEach([&](GLuint, GLSamplerObject& sampler) {
            releaseSamplerState(sampler);
        });
        objects->vertexArrays().forEach([&](GLuint, GLVertexArrayObject& vertexArray) {
            releaseVertexDescriptor(vertexArray);
        });
    }

    Impl(void* rawLayer, GLsizei initialWidth, GLsizei initialHeight, bool offscreen) {
        layer = (__bridge CAMetalLayer*)rawLayer;
        device = MTLCreateSystemDefaultDevice();
        if (layer != nil && device != nil) {
            layer.device = device;
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.framebufferOnly = NO;
            layer.contentsGravity = kCAGravityResizeAspect;
            const CGSize bounds = layer.bounds.size;
            viewportWidth = initialWidth > 0 ? initialWidth : static_cast<GLsizei>(bounds.width > 0.0 ? bounds.width : 1.0);
            viewportHeight = initialHeight > 0 ? initialHeight : static_cast<GLsizei>(bounds.height > 0.0 ? bounds.height : 1.0);
            layer.drawableSize = CGSizeMake(viewportWidth, viewportHeight);
        } else {
            viewportWidth = initialWidth > 0 ? initialWidth : viewportWidth;
            viewportHeight = initialHeight > 0 ? initialHeight : viewportHeight;
        }
        if (device != nil) {
            commandQueue = [device newCommandQueue];
            rendererString = "AppGL on Metal (" + std::string([[device name] UTF8String]) + ")";
        } else {
            rendererString = "AppGL on Metal (No Metal Device)";
        }
        frameGraph = std::make_unique<MetalFrameGraph>((__bridge void*)layer, (__bridge void*)device, (__bridge void*)commandQueue);
        capabilities = std::make_unique<GLCapabilities>((__bridge void*)device);
        objects = std::make_unique<GLObjectStore>();
        state = std::make_unique<GLStateTracker>();
        if (frameGraph != nullptr) {
            frameGraph->resizeDrawable(viewportWidth, viewportHeight);
            if (offscreen) {
                frameGraph->enableOffscreenDrawable(viewportWidth, viewportHeight);
            }
        }
        state->setViewport(viewportX, viewportY, viewportWidth, viewportHeight);
        extensionsString = capabilities != nullptr ? capabilities->extensionString() : "";
        // Initialize per-context immediate double attribs to {0,0,0,1} (OpenGL default).
        for (auto& slot : immediateDoubleAttribs) {
            slot = {0.0, 0.0, 0.0, 1.0};
        }
    }

    void releaseBufferStorage(GLBufferObject& object) {
        releaseRetainedMetalObject(object.metalBuffer);
        object.metalBuffer = nullptr;
        object.size = 0;
        object.shadowBytes.clear();
        resetBufferMapping(object);
    }

    void releaseVertexDescriptor(GLVertexArrayObject& vertexArray) {
        releaseMetalVertexDescriptor(vertexArray.metalVertexDescriptor);
        vertexArray.metalVertexDescriptor = nullptr;
        vertexArray.vertexDescriptorHash.clear();
        vertexArray.vertexDescriptorError.clear();
        vertexArray.vertexDescriptorDirty = true;
    }

    void releaseTextureStorage(GLTextureObject& object) {
        releaseRetainedMetalObject(object.metalTexture);
        object.metalTexture = nullptr;
        object.desc = {};
        object.levels.clear();
    }

    void releaseRenderbufferStorage(GLRenderbufferObject& object) {
        releaseRetainedMetalObject(object.metalTexture);
        object.metalTexture = nullptr;
        object.internalFormat = 0;
        object.width = 0;
        object.height = 0;
        object.samples = 0;
        object.rgba8.clear();
        object.depth32.clear();
        object.stencil8.clear();
        object.storageDefined = false;
    }

    void releaseSamplerState(GLSamplerObject& object) {
        releaseRetainedMetalObject(object.metalSampler);
        object.metalSampler = nullptr;
        object.dirty = true;
    }

    GLTextureObject* currentTexture(GLenum target) {
        const GLuint name = state->boundTexture(target);
        if (name == 0) {
            return nullptr;
        }
        return objects->textures().get(name);
    }

    bool buildRGBA8Upload(
        GLsizei width,
        GLsizei height,
        GLsizei depth,
        GLenum format,
        GLenum type,
        const void* pixels,
        std::vector<std::uint8_t>& rgba8
    ) {
        if (width < 0 || height < 0 || depth < 0) {
            return false;
        }
        rgba8.assign(rgba8ByteCount(width, height, depth), 0);
        if (pixels == nullptr || width == 0 || height == 0 || depth == 0) {
            return true;
        }
        if (type != GL_UNSIGNED_BYTE) {
            return false;
        }
        const std::size_t components = componentCountForFormat(format);
        if (components == 0) {
            return false;
        }

        const auto& store = state->pixelStore();
        const std::size_t sourceWidth = static_cast<std::size_t>(store.unpackRowLength > 0 ? store.unpackRowLength : width);
        const std::size_t sourceHeight = static_cast<std::size_t>(store.unpackImageHeight > 0 ? store.unpackImageHeight : height);
        const std::size_t rowBytes = alignByteCount(sourceWidth * components, store.unpackAlignment);
        const std::size_t imageBytes = rowBytes * sourceHeight;
        const std::size_t sourceOffset =
            static_cast<std::size_t>(store.unpackSkipImages) * imageBytes
            + static_cast<std::size_t>(store.unpackSkipRows) * rowBytes
            + static_cast<std::size_t>(store.unpackSkipPixels) * components;
        const auto* source = static_cast<const std::uint8_t*>(pixels) + sourceOffset;

        for (GLsizei z = 0; z < depth; ++z) {
            for (GLsizei y = 0; y < height; ++y) {
                for (GLsizei x = 0; x < width; ++x) {
                    const std::size_t sourceIndex =
                        static_cast<std::size_t>(z) * imageBytes
                        + static_cast<std::size_t>(y) * rowBytes
                        + static_cast<std::size_t>(x) * components;
                    const std::size_t destIndex =
                        ((static_cast<std::size_t>(z) * static_cast<std::size_t>(height)
                            + static_cast<std::size_t>(y))
                            * static_cast<std::size_t>(width)
                            + static_cast<std::size_t>(x))
                        * 4u;
                    rgba8[destIndex + 0] = source[sourceIndex + 0];
                    rgba8[destIndex + 1] = components > 1 ? source[sourceIndex + 1] : 0;
                    rgba8[destIndex + 2] = components > 2 ? source[sourceIndex + 2] : 0;
                    rgba8[destIndex + 3] = components > 3 ? source[sourceIndex + 3] : 255;
                }
            }
        }
        return true;
    }

    bool replaceMetalTexture(GLTextureObject& object) {
        const auto baseIt = object.levels.find(0);
        if (baseIt == object.levels.end()) {
            releaseRetainedMetalObject(object.metalTexture);
            object.metalTexture = nullptr;
            return true;
        }
        const GLTextureImageLevel& baseLevel = baseIt->second;
        if (device == nil || !baseLevel.defined || baseLevel.desc.width <= 0 || baseLevel.desc.height <= 0 || baseLevel.desc.depth <= 0) {
            return true;
        }

        GLint highestDefinedLevel = 0;
        for (const auto& [levelIndex, image] : object.levels) {
            if (levelIndex >= 0 && image.defined) {
                highestDefinedLevel = std::max(highestDefinedLevel, levelIndex);
            }
        }

        releaseRetainedMetalObject(object.metalTexture);
        object.metalTexture = nullptr;

        MTLTextureDescriptor* descriptor = [[MTLTextureDescriptor alloc] init];
        descriptor.textureType = metalTextureTypeForTarget(object.target);
        descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.width = static_cast<NSUInteger>(baseLevel.desc.width);
        descriptor.height = static_cast<NSUInteger>(object.target == GL_TEXTURE_1D ? 1 : baseLevel.desc.height);
        descriptor.depth = static_cast<NSUInteger>(object.target == GL_TEXTURE_3D ? baseLevel.desc.depth : 1);
        descriptor.mipmapLevelCount = static_cast<NSUInteger>(highestDefinedLevel + 1);
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;

        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture == nil) {
            return false;
        }

        for (const auto& [levelIndex, image] : object.levels) {
            if (levelIndex < 0 || !image.defined || image.rgba8.empty()) {
                continue;
            }
            const NSUInteger mipLevel = static_cast<NSUInteger>(levelIndex);
            const NSUInteger bytesPerRow = static_cast<NSUInteger>(safeDimension(image.desc.width) * 4u);
            const NSUInteger bytesPerImage = bytesPerRow * static_cast<NSUInteger>(safeDimension(image.desc.height));
            const MTLRegion region = MTLRegionMake3D(
                0,
                0,
                0,
                static_cast<NSUInteger>(safeDimension(image.desc.width)),
                static_cast<NSUInteger>(object.target == GL_TEXTURE_1D ? 1 : safeDimension(image.desc.height)),
                static_cast<NSUInteger>(object.target == GL_TEXTURE_3D ? safeDimension(image.desc.depth) : 1)
            );
            if (object.target == GL_TEXTURE_3D) {
                for (NSUInteger slice = 0; slice < region.size.depth; ++slice) {
                    const MTLRegion sliceRegion = MTLRegionMake3D(0, 0, slice, region.size.width, region.size.height, 1);
                    const auto* sliceBytes = image.rgba8.data() + static_cast<std::size_t>(slice * bytesPerImage);
                    [texture replaceRegion:sliceRegion mipmapLevel:mipLevel withBytes:sliceBytes bytesPerRow:bytesPerRow];
                }
            } else {
                [texture replaceRegion:region mipmapLevel:mipLevel withBytes:image.rgba8.data() bytesPerRow:bytesPerRow];
            }
        }
        object.metalTexture = transferRetainedMetalObject(texture);
        return true;
    }

    bool replaceRenderbufferStorage(GLRenderbufferObject& object, GLenum internalFormat, GLsizei width, GLsizei height, GLsizei samples) {
        if (width < 0 || height < 0 || samples < 0 || !isSupportedRenderbufferFormat(internalFormat)) {
            return false;
        }

        void* retainedTexture = nullptr;
        if (device != nil && width > 0 && height > 0) {
            const MTLPixelFormat pixelFormat = metalRenderbufferFormat(internalFormat);
            MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                                                                   width:static_cast<NSUInteger>(width)
                                                                                                  height:static_cast<NSUInteger>(height)
                                                                                               mipmapped:NO];
            descriptor.storageMode = MTLStorageModePrivate;
            descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            if (samples > 0) {
                descriptor.textureType = MTLTextureType2DMultisample;
                descriptor.sampleCount = static_cast<NSUInteger>(samples);
            }

            id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
            if (texture == nil) {
                return false;
            }
            retainedTexture = transferRetainedMetalObject(texture);
        }

        releaseRenderbufferStorage(object);
        object.metalTexture = retainedTexture;
        object.internalFormat = internalFormat;
        object.width = width;
        object.height = height;
        object.samples = samples;
        const std::size_t texelCount = static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
        if (isColorFormat(internalFormat)) {
            object.rgba8.assign(texelCount * 4u, 0);
        }
        if (isDepthFormat(internalFormat)) {
            object.depth32.assign(texelCount, 1.0f);
        }
        if (isStencilFormat(internalFormat)) {
            object.stencil8.assign(texelCount, 0);
        }
        object.storageDefined = true;
        return true;
    }

    bool generateMipmaps(GLTextureObject& object) {
        const GLint baseLevelIndex = object.params.baseLevel;
        const auto baseIt = object.levels.find(baseLevelIndex);
        if (baseIt == object.levels.end() || !baseIt->second.defined || baseIt->second.rgba8.empty()) {
            return false;
        }
        if (object.params.maxLevel < baseLevelIndex) {
            return false;
        }

        const GLTextureImageLevel baseLevel = baseIt->second;
        const GLint tailOffset = mipTailOffset(
            baseLevel.desc.width,
            object.target == GL_TEXTURE_1D ? 1 : baseLevel.desc.height,
            object.target == GL_TEXTURE_3D ? baseLevel.desc.depth : 1
        );
        const GLint finalLevel = std::min(baseLevelIndex + tailOffset, object.params.maxLevel);
        GLTextureImageLevel previousLevel = baseLevel;
        for (GLint levelIndex = baseLevelIndex + 1; levelIndex <= finalLevel; ++levelIndex) {
            const GLint offsetFromBase = levelIndex - baseLevelIndex;
            GLTextureImageLevel generated;
            generated.desc = baseLevel.desc;
            generated.desc.width = mipDimension(baseLevel.desc.width, offsetFromBase);
            generated.desc.height = object.target == GL_TEXTURE_1D ? 1 : mipDimension(baseLevel.desc.height, offsetFromBase);
            generated.desc.depth = object.target == GL_TEXTURE_3D ? mipDimension(baseLevel.desc.depth, offsetFromBase) : 1;
            generated.desc.levels = std::max<GLsizei>(object.desc.levels, levelIndex + 1);
            generated.defined = true;
            generated.rgba8 = downsampleRGBA8(
                previousLevel.rgba8,
                previousLevel.desc.width,
                previousLevel.desc.height,
                previousLevel.desc.depth,
                generated.desc.width,
                generated.desc.height,
                generated.desc.depth
            );
            object.levels[levelIndex] = std::move(generated);
            previousLevel = object.levels.at(levelIndex);
        }

        if (const auto levelZero = object.levels.find(0); levelZero != object.levels.end()) {
            object.desc = levelZero->second.desc;
        } else {
            object.desc = baseLevel.desc;
        }
        object.desc.levels = std::max<GLsizei>(object.desc.levels, finalLevel + 1);
        for (auto& [levelIndex, image] : object.levels) {
            (void)levelIndex;
            image.desc.levels = object.desc.levels;
        }
        return replaceMetalTexture(object);
    }

    bool rebuildSamplerState(GLSamplerObject& object) {
        releaseRetainedMetalObject(object.metalSampler);
        object.metalSampler = nullptr;
        if (device == nil) {
            object.dirty = false;
            return true;
        }

        MTLSamplerDescriptor* descriptor = [[MTLSamplerDescriptor alloc] init];
        descriptor.minFilter = metalMinMagFilter(object.params.minFilter);
        descriptor.magFilter = metalMinMagFilter(object.params.magFilter);
        descriptor.mipFilter = metalMipFilter(object.params.minFilter);
        descriptor.sAddressMode = metalAddressMode(object.params.wrapS);
        descriptor.tAddressMode = metalAddressMode(object.params.wrapT);
        descriptor.rAddressMode = metalAddressMode(object.params.wrapR);
        descriptor.lodMinClamp = object.params.minLod;
        descriptor.lodMaxClamp = object.params.maxLod;
        descriptor.compareFunction = object.params.compareMode == GL_COMPARE_REF_TO_TEXTURE
            ? metalCompareFunction(object.params.compareFunc)
            : MTLCompareFunctionNever;

        id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:descriptor];
        if (sampler == nil) {
            return false;
        }
        object.metalSampler = transferRetainedMetalObject(sampler);
        object.dirty = false;
        return true;
    }

    bool replaceBufferStorage(GLBufferObject& object, GLsizeiptr size, const void* data, GLenum usage) {
        std::vector<std::uint8_t> shadowBytes(static_cast<std::size_t>(size), 0);
        if (data != nullptr && size > 0) {
            std::memcpy(shadowBytes.data(), data, static_cast<std::size_t>(size));
        }

        void* retainedMetalBuffer = nullptr;
        if (size > 0 && device != nil) {
            id<MTLBuffer> metalBuffer =
                [device newBufferWithLength:static_cast<NSUInteger>(size) options:metalBufferOptionsForUsage(usage)];
            if (metalBuffer == nil) {
                return false;
            }
            std::memcpy([metalBuffer contents], shadowBytes.data(), static_cast<std::size_t>(size));
            retainedMetalBuffer = transferRetainedMetalObject(metalBuffer);
        }

        releaseBufferStorage(object);
        object.size = size;
        object.usage = usage;
        object.shadowBytes = std::move(shadowBytes);
        object.metalBuffer = retainedMetalBuffer;
        resetBufferMapping(object);
        return true;
    }

    std::uint8_t* mutableBufferContents(GLBufferObject& object) {
        id<MTLBuffer> metalBuffer = metalBufferFromRaw(object.metalBuffer);
        if (metalBuffer != nil) {
            return static_cast<std::uint8_t*>([metalBuffer contents]);
        }
        return object.shadowBytes.empty() ? nullptr : object.shadowBytes.data();
    }

    const std::uint8_t* readableBufferContents(const GLBufferObject& object) const {
        id<MTLBuffer> metalBuffer = metalBufferFromRaw(object.metalBuffer);
        if (metalBuffer != nil) {
            return static_cast<const std::uint8_t*>([metalBuffer contents]);
        }
        return object.shadowBytes.empty() ? nullptr : object.shadowBytes.data();
    }

    void syncShadowFromMetal(GLBufferObject& object, GLintptr offset, GLsizeiptr length) {
        if (length <= 0 || object.metalBuffer == nullptr || object.shadowBytes.empty()) {
            return;
        }
        const std::uint8_t* contents = readableBufferContents(object);
        if (contents == nullptr) {
            return;
        }
        std::memcpy(
            object.shadowBytes.data() + static_cast<std::size_t>(offset),
            contents + static_cast<std::size_t>(offset),
            static_cast<std::size_t>(length)
        );
    }

    void syncMetalFromShadow(GLBufferObject& object, GLintptr offset, GLsizeiptr length) {
        if (length <= 0 || object.metalBuffer == nullptr || object.shadowBytes.empty()) {
            return;
        }
        std::uint8_t* contents = mutableBufferContents(object);
        if (contents == nullptr) {
            return;
        }
        std::memcpy(
            contents + static_cast<std::size_t>(offset),
            object.shadowBytes.data() + static_cast<std::size_t>(offset),
            static_cast<std::size_t>(length)
        );
    }

    GLVertexArrayObject* vertexArray(GLuint name) {
        GLVertexArrayObject* object = objects->vertexArrays().get(name);
        if (object != nullptr && object->attributes.empty()) {
            objects->initializeVertexArray(*object);
        }
        return object;
    }

    GLVertexArrayObject* currentVertexArray() {
        const GLuint name = state->boundVertexArray();
        if (name == 0) {
            return nullptr;
        }
        return vertexArray(name);
    }

    void deleteBufferReferencesFromVertexArrays(GLuint buffer) {
        objects->vertexArrays().forEach([&](GLuint, GLVertexArrayObject& vertexArray) {
            if (vertexArray.elementArrayBuffer == buffer) {
                vertexArray.elementArrayBuffer = 0;
            }
            for (auto& attribute : vertexArray.attributes) {
                if (attribute.buffer == buffer) {
                    attribute.buffer = 0;
                    markVertexDescriptorDirty(vertexArray);
                }
            }
        });
    }

    void deleteTextureReferencesFromFramebuffers(GLuint texture) {
        objects->framebuffers().forEach([&](GLuint, GLFramebufferObject& framebuffer) {
            for (auto& [attachmentPoint, attachment] : framebuffer.attachments) {
                (void)attachmentPoint;
                if (attachment.kind == GLFramebufferAttachment::Kind::Texture && attachment.object == texture) {
                    attachment = {};
                }
            }
        });
    }

    void deleteRenderbufferReferencesFromFramebuffers(GLuint renderbuffer) {
        objects->framebuffers().forEach([&](GLuint, GLFramebufferObject& framebuffer) {
            for (auto& [attachmentPoint, attachment] : framebuffer.attachments) {
                (void)attachmentPoint;
                if (attachment.kind == GLFramebufferAttachment::Kind::Renderbuffer && attachment.object == renderbuffer) {
                    attachment = {};
                }
            }
        });
    }

    struct AttachmentInfo {
        bool present = false;
        bool complete = false;
        GLsizei width = 0;
        GLsizei height = 0;
        GLsizei samples = 0;
        GLenum internalFormat = 0;
    };

    AttachmentInfo framebufferAttachmentInfo(const GLFramebufferAttachment& attachment) const {
        AttachmentInfo info;
        if (attachment.kind == GLFramebufferAttachment::Kind::None || attachment.object == 0) {
            return info;
        }
        info.present = true;
        if (attachment.kind == GLFramebufferAttachment::Kind::Texture) {
            const GLTextureObject* texture = objects->textures().get(attachment.object);
            if (texture == nullptr || !texture->instantiated || attachment.level < 0) {
                return info;
            }
            const auto level = texture->levels.find(attachment.level);
            if (level == texture->levels.end() || !level->second.defined) {
                return info;
            }
            info.complete = level->second.desc.width > 0 && level->second.desc.height > 0 && level->second.desc.depth > 0;
            info.width = level->second.desc.width;
            info.height = texture->target == GL_TEXTURE_1D ? 1 : level->second.desc.height;
            info.samples = 0;
            info.internalFormat = level->second.desc.internalFormat;
            return info;
        }
        if (attachment.kind == GLFramebufferAttachment::Kind::Renderbuffer) {
            const GLRenderbufferObject* renderbuffer = objects->renderbuffers().get(attachment.object);
            if (renderbuffer == nullptr || !renderbuffer->instantiated || !renderbuffer->storageDefined) {
                return info;
            }
            info.complete = renderbuffer->width > 0 && renderbuffer->height > 0;
            info.width = renderbuffer->width;
            info.height = renderbuffer->height;
            info.samples = renderbuffer->samples;
            info.internalFormat = renderbuffer->internalFormat;
            return info;
        }
        return info;
    }

    GLenum framebufferStatus(const GLFramebufferObject& framebuffer) const {
        bool hasAttachment = false;
        bool hasDimensions = false;
        GLsizei width = 0;
        GLsizei height = 0;
        GLsizei samples = 0;
        for (const auto& [attachmentPoint, attachment] : framebuffer.attachments) {
            (void)attachmentPoint;
            const AttachmentInfo info = framebufferAttachmentInfo(attachment);
            if (!info.present) {
                continue;
            }
            hasAttachment = true;
            if (!info.complete) {
                return GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT;
            }
            if (!hasDimensions) {
                width = info.width;
                height = info.height;
                samples = info.samples;
                hasDimensions = true;
            } else if (width != info.width || height != info.height) {
                return GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT;
            } else if (samples != info.samples) {
                return GL_FRAMEBUFFER_INCOMPLETE_MULTISAMPLE;
            }
        }

        if (!hasAttachment) {
            return GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT;
        }

        // Spec: if separate depth and stencil attachments are present, they must
        // refer to the same image. Mismatched separate attachments are reported as
        // GL_FRAMEBUFFER_UNSUPPORTED on a Metal-backed implementation. (A combined
        // GL_DEPTH_STENCIL_ATTACHMENT does not trip this — it occupies both points
        // through a single entry.)
        {
            const auto depthIt = framebuffer.attachments.find(GL_DEPTH_ATTACHMENT);
            const auto stencilIt = framebuffer.attachments.find(GL_STENCIL_ATTACHMENT);
            const bool depthPresent = depthIt != framebuffer.attachments.end()
                && framebufferAttachmentInfo(depthIt->second).present;
            const bool stencilPresent = stencilIt != framebuffer.attachments.end()
                && framebufferAttachmentInfo(stencilIt->second).present;
            if (depthPresent && stencilPresent) {
                const auto& d = depthIt->second;
                const auto& s = stencilIt->second;
                if (d.kind != s.kind || d.object != s.object || d.level != s.level || d.layer != s.layer) {
                    return GL_FRAMEBUFFER_UNSUPPORTED;
                }
            }
        }

        for (GLenum buffer : framebuffer.drawBuffers) {
            if (buffer == GL_NONE) {
                continue;
            }
            const auto attachment = framebuffer.attachments.find(buffer);
            if (attachment == framebuffer.attachments.end() || framebufferAttachmentInfo(attachment->second).present == false) {
                return GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER;
            }
        }
        if (framebuffer.readBuffer != GL_NONE) {
            const auto attachment = framebuffer.attachments.find(framebuffer.readBuffer);
            if (attachment == framebuffer.attachments.end() || framebufferAttachmentInfo(attachment->second).present == false) {
                return GL_FRAMEBUFFER_INCOMPLETE_READ_BUFFER;
            }
        }
        return GL_FRAMEBUFFER_COMPLETE;
    }

    GLFramebufferAttachment* framebufferAttachment(GLFramebufferObject& framebuffer, GLenum attachment) {
        if (auto found = framebuffer.attachments.find(attachment); found != framebuffer.attachments.end()) {
            return &found->second;
        }
        if (attachment == GL_DEPTH_ATTACHMENT || attachment == GL_STENCIL_ATTACHMENT) {
            if (auto found = framebuffer.attachments.find(GL_DEPTH_STENCIL_ATTACHMENT); found != framebuffer.attachments.end()) {
                return &found->second;
            }
        }
        return nullptr;
    }

    const GLFramebufferAttachment* framebufferAttachment(const GLFramebufferObject& framebuffer, GLenum attachment) const {
        if (auto found = framebuffer.attachments.find(attachment); found != framebuffer.attachments.end()) {
            return &found->second;
        }
        if (attachment == GL_DEPTH_ATTACHMENT || attachment == GL_STENCIL_ATTACHMENT) {
            if (auto found = framebuffer.attachments.find(GL_DEPTH_STENCIL_ATTACHMENT); found != framebuffer.attachments.end()) {
                return &found->second;
            }
        }
        return nullptr;
    }

    bool clearColorAttachment(const GLFramebufferAttachment& attachment, const GLfloat color[4]) {
        const std::uint8_t rgba[4] = {
            normalizedByte(color[0]),
            normalizedByte(color[1]),
            normalizedByte(color[2]),
            normalizedByte(color[3]),
        };

        if (attachment.kind == GLFramebufferAttachment::Kind::Texture) {
            GLTextureObject* texture = objects->textures().get(attachment.object);
            if (texture == nullptr) {
                return false;
            }
            auto level = texture->levels.find(attachment.level);
            if (level == texture->levels.end() || !level->second.defined) {
                return false;
            }
            GLTextureImageLevel& image = level->second;
            const GLsizei sourceWidth = std::max<GLsizei>(image.desc.width, 1);
            const GLsizei sourceHeight = texture->target == GL_TEXTURE_1D ? 1 : std::max<GLsizei>(image.desc.height, 1);
            const GLsizei sourceDepth = texture->target == GL_TEXTURE_3D ? std::max<GLsizei>(image.desc.depth, 1) : 1;
            if (image.rgba8.size() < rgba8ByteCount(sourceWidth, sourceHeight, sourceDepth)) {
                image.rgba8.assign(rgba8ByteCount(sourceWidth, sourceHeight, sourceDepth), 0);
            }
            const GLsizei firstLayer = attachment.layered ? 0 : attachment.layer;
            const GLsizei lastLayer = attachment.layered ? sourceDepth : firstLayer + 1;
            if (firstLayer < 0 || firstLayer >= sourceDepth || lastLayer > sourceDepth) {
                return false;
            }
            for (GLsizei z = firstLayer; z < lastLayer; ++z) {
                for (GLsizei y = 0; y < sourceHeight; ++y) {
                    for (GLsizei x = 0; x < sourceWidth; ++x) {
                        const std::size_t offset =
                            ((static_cast<std::size_t>(z) * static_cast<std::size_t>(sourceHeight)
                                + static_cast<std::size_t>(y))
                                * static_cast<std::size_t>(sourceWidth)
                                + static_cast<std::size_t>(x))
                            * 4u;
                        std::memcpy(image.rgba8.data() + offset, rgba, 4);
                    }
                }
            }
            return replaceMetalTexture(*texture);
        }

        if (attachment.kind == GLFramebufferAttachment::Kind::Renderbuffer) {
            GLRenderbufferObject* renderbuffer = objects->renderbuffers().get(attachment.object);
            if (renderbuffer == nullptr || !renderbuffer->storageDefined || !isColorFormat(renderbuffer->internalFormat)) {
                return false;
            }
            renderbuffer->rgba8.assign(static_cast<std::size_t>(renderbuffer->width) * static_cast<std::size_t>(renderbuffer->height) * 4u, 0);
            for (std::size_t offset = 0; offset < renderbuffer->rgba8.size(); offset += 4u) {
                std::memcpy(renderbuffer->rgba8.data() + offset, rgba, 4);
            }
            return true;
        }

        return false;
    }

    bool clearDepthAttachment(const GLFramebufferAttachment& attachment, GLdouble value) {
        const auto depth = static_cast<GLfloat>(std::clamp(value, 0.0, 1.0));
        if (attachment.kind != GLFramebufferAttachment::Kind::Renderbuffer) {
            return false;
        }
        GLRenderbufferObject* renderbuffer = objects->renderbuffers().get(attachment.object);
        if (renderbuffer == nullptr || !renderbuffer->storageDefined || !isDepthFormat(renderbuffer->internalFormat)) {
            return false;
        }
        renderbuffer->depth32.assign(static_cast<std::size_t>(renderbuffer->width) * static_cast<std::size_t>(renderbuffer->height), depth);
        return true;
    }

    bool clearStencilAttachment(const GLFramebufferAttachment& attachment, GLint value) {
        if (attachment.kind != GLFramebufferAttachment::Kind::Renderbuffer) {
            return false;
        }
        GLRenderbufferObject* renderbuffer = objects->renderbuffers().get(attachment.object);
        if (renderbuffer == nullptr || !renderbuffer->storageDefined || !isStencilFormat(renderbuffer->internalFormat)) {
            return false;
        }
        renderbuffer->stencil8.assign(
            static_cast<std::size_t>(renderbuffer->width) * static_cast<std::size_t>(renderbuffer->height),
            static_cast<std::uint8_t>(value & 0xff)
        );
        return true;
    }

    bool clearBoundFramebuffer(GLbitfield mask) {
        const GLuint framebufferName = state->boundDrawFramebuffer();
        GLFramebufferObject* framebuffer = objects->framebuffers().get(framebufferName);
        if (framebufferName == 0 || framebuffer == nullptr || !framebuffer->instantiated || framebufferStatus(*framebuffer) != GL_FRAMEBUFFER_COMPLETE) {
            return false;
        }

        if ((mask & GL_COLOR_BUFFER_BIT) != 0) {
            for (GLenum buffer : framebuffer->drawBuffers) {
                if (buffer == GL_NONE) {
                    continue;
                }
                const GLFramebufferAttachment* attachment = framebufferAttachment(*framebuffer, buffer);
                if (attachment != nullptr && !clearColorAttachment(*attachment, state->clearState().color)) {
                    return false;
                }
            }
        }
        if ((mask & GL_DEPTH_BUFFER_BIT) != 0) {
            const GLFramebufferAttachment* attachment = framebufferAttachment(*framebuffer, GL_DEPTH_ATTACHMENT);
            if (attachment != nullptr && !clearDepthAttachment(*attachment, state->clearState().depth)) {
                return false;
            }
        }
        if ((mask & GL_STENCIL_BUFFER_BIT) != 0) {
            const GLFramebufferAttachment* attachment = framebufferAttachment(*framebuffer, GL_STENCIL_ATTACHMENT);
            if (attachment != nullptr && !clearStencilAttachment(*attachment, state->clearState().stencil)) {
                return false;
            }
        }
        return true;
    }

    bool readColorAttachmentPixels(const GLFramebufferAttachment& attachment, GLint x, GLint y, GLsizei width, GLsizei height, void* pixels) const {
        const std::uint8_t* source = nullptr;
        GLsizei sourceWidth = 0;
        GLsizei sourceHeight = 0;
        GLsizei sourceLayer = 0;

        if (attachment.kind == GLFramebufferAttachment::Kind::Texture) {
            const GLTextureObject* texture = objects->textures().get(attachment.object);
            if (texture == nullptr) {
                return false;
            }
            const auto level = texture->levels.find(attachment.level);
            if (level == texture->levels.end() || !level->second.defined || level->second.rgba8.empty()) {
                return false;
            }
            source = level->second.rgba8.data();
            sourceWidth = std::max<GLsizei>(level->second.desc.width, 1);
            sourceHeight = texture->target == GL_TEXTURE_1D ? 1 : std::max<GLsizei>(level->second.desc.height, 1);
            sourceLayer = texture->target == GL_TEXTURE_3D ? attachment.layer : 0;
            if (sourceLayer < 0 || sourceLayer >= std::max<GLsizei>(level->second.desc.depth, 1)) {
                return false;
            }
        } else if (attachment.kind == GLFramebufferAttachment::Kind::Renderbuffer) {
            const GLRenderbufferObject* renderbuffer = objects->renderbuffers().get(attachment.object);
            if (renderbuffer == nullptr || !renderbuffer->storageDefined || renderbuffer->rgba8.empty()) {
                return false;
            }
            source = renderbuffer->rgba8.data();
            sourceWidth = renderbuffer->width;
            sourceHeight = renderbuffer->height;
        } else {
            return false;
        }

        auto* out = static_cast<std::uint8_t*>(pixels);
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint srcX = x + col;
                const GLint srcY = y + row;
                const std::size_t dstOffset = static_cast<std::size_t>(row * width + col) * 4u;
                if (srcX < 0 || srcY < 0 || srcX >= sourceWidth || srcY >= sourceHeight) {
                    std::memset(out + dstOffset, 0, 4);
                    continue;
                }
                const std::size_t srcOffset =
                    ((static_cast<std::size_t>(sourceLayer) * static_cast<std::size_t>(sourceHeight)
                        + static_cast<std::size_t>(srcY))
                        * static_cast<std::size_t>(sourceWidth)
                        + static_cast<std::size_t>(srcX))
                    * 4u;
                std::memcpy(out + dstOffset, source + srcOffset, 4);
            }
        }
        return true;
    }

    bool readDepthAttachmentPixels(const GLFramebufferAttachment& attachment, GLint x, GLint y, GLsizei width, GLsizei height, void* pixels) const {
        if (attachment.kind != GLFramebufferAttachment::Kind::Renderbuffer) {
            return false;
        }
        const GLRenderbufferObject* renderbuffer = objects->renderbuffers().get(attachment.object);
        if (renderbuffer == nullptr || !renderbuffer->storageDefined || renderbuffer->depth32.empty()) {
            return false;
        }
        auto* out = static_cast<GLfloat*>(pixels);
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint srcX = x + col;
                const GLint srcY = y + row;
                const std::size_t dstOffset = static_cast<std::size_t>(row * width + col);
                if (srcX < 0 || srcY < 0 || srcX >= renderbuffer->width || srcY >= renderbuffer->height) {
                    out[dstOffset] = 0.0f;
                    continue;
                }
                out[dstOffset] = renderbuffer->depth32[static_cast<std::size_t>(srcY) * static_cast<std::size_t>(renderbuffer->width) + static_cast<std::size_t>(srcX)];
            }
        }
        return true;
    }

    bool readStencilAttachmentPixels(const GLFramebufferAttachment& attachment, GLint x, GLint y, GLsizei width, GLsizei height, void* pixels) const {
        if (attachment.kind != GLFramebufferAttachment::Kind::Renderbuffer) {
            return false;
        }
        const GLRenderbufferObject* renderbuffer = objects->renderbuffers().get(attachment.object);
        if (renderbuffer == nullptr || !renderbuffer->storageDefined || renderbuffer->stencil8.empty()) {
            return false;
        }
        auto* out = static_cast<std::uint8_t*>(pixels);
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint srcX = x + col;
                const GLint srcY = y + row;
                const std::size_t dstOffset = static_cast<std::size_t>(row * width + col);
                if (srcX < 0 || srcY < 0 || srcX >= renderbuffer->width || srcY >= renderbuffer->height) {
                    out[dstOffset] = 0;
                    continue;
                }
                out[dstOffset] = renderbuffer->stencil8[static_cast<std::size_t>(srcY) * static_cast<std::size_t>(renderbuffer->width) + static_cast<std::size_t>(srcX)];
            }
        }
        return true;
    }

    // Write helpers for blitFramebuffer. They mirror readXxxAttachmentPixels and
    // commit pixels into the attachment's CPU shadow store (and re-upload to Metal
    // for color textures so subsequent samples see the blitted pixels).
    bool writeColorAttachmentPixels(const GLFramebufferAttachment& attachment, GLint x, GLint y, GLsizei width, GLsizei height, const std::uint8_t* pixels) {
        std::uint8_t* dest = nullptr;
        GLsizei destWidth = 0;
        GLsizei destHeight = 0;
        GLsizei destLayer = 0;
        GLTextureObject* writableTexture = nullptr;

        if (attachment.kind == GLFramebufferAttachment::Kind::Texture) {
            writableTexture = objects->textures().get(attachment.object);
            if (writableTexture == nullptr) {
                return false;
            }
            auto level = writableTexture->levels.find(attachment.level);
            if (level == writableTexture->levels.end() || !level->second.defined) {
                return false;
            }
            const GLsizei sourceWidth = std::max<GLsizei>(level->second.desc.width, 1);
            const GLsizei sourceHeight = writableTexture->target == GL_TEXTURE_1D ? 1 : std::max<GLsizei>(level->second.desc.height, 1);
            const GLsizei sourceDepth = writableTexture->target == GL_TEXTURE_3D ? std::max<GLsizei>(level->second.desc.depth, 1) : 1;
            if (level->second.rgba8.size() < rgba8ByteCount(sourceWidth, sourceHeight, sourceDepth)) {
                level->second.rgba8.assign(rgba8ByteCount(sourceWidth, sourceHeight, sourceDepth), 0);
            }
            destLayer = writableTexture->target == GL_TEXTURE_3D ? attachment.layer : 0;
            if (destLayer < 0 || destLayer >= sourceDepth) {
                return false;
            }
            dest = level->second.rgba8.data();
            destWidth = sourceWidth;
            destHeight = sourceHeight;
        } else if (attachment.kind == GLFramebufferAttachment::Kind::Renderbuffer) {
            GLRenderbufferObject* renderbuffer = objects->renderbuffers().get(attachment.object);
            if (renderbuffer == nullptr || !renderbuffer->storageDefined || !isColorFormat(renderbuffer->internalFormat)) {
                return false;
            }
            if (renderbuffer->rgba8.empty()) {
                renderbuffer->rgba8.assign(static_cast<std::size_t>(renderbuffer->width) * static_cast<std::size_t>(renderbuffer->height) * 4u, 0);
            }
            dest = renderbuffer->rgba8.data();
            destWidth = renderbuffer->width;
            destHeight = renderbuffer->height;
        } else {
            return false;
        }

        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint dstX = x + col;
                const GLint dstY = y + row;
                if (dstX < 0 || dstY < 0 || dstX >= destWidth || dstY >= destHeight) {
                    continue;
                }
                const std::size_t srcOffset = static_cast<std::size_t>(row * width + col) * 4u;
                const std::size_t dstOffset =
                    ((static_cast<std::size_t>(destLayer) * static_cast<std::size_t>(destHeight)
                        + static_cast<std::size_t>(dstY))
                        * static_cast<std::size_t>(destWidth)
                        + static_cast<std::size_t>(dstX))
                    * 4u;
                std::memcpy(dest + dstOffset, pixels + srcOffset, 4);
            }
        }

        if (writableTexture != nullptr) {
            return replaceMetalTexture(*writableTexture);
        }
        return true;
    }

    bool writeDepthAttachmentPixels(const GLFramebufferAttachment& attachment, GLint x, GLint y, GLsizei width, GLsizei height, const GLfloat* pixels) {
        if (attachment.kind != GLFramebufferAttachment::Kind::Renderbuffer) {
            return false;
        }
        GLRenderbufferObject* renderbuffer = objects->renderbuffers().get(attachment.object);
        if (renderbuffer == nullptr || !renderbuffer->storageDefined || !isDepthFormat(renderbuffer->internalFormat)) {
            return false;
        }
        if (renderbuffer->depth32.empty()) {
            renderbuffer->depth32.assign(static_cast<std::size_t>(renderbuffer->width) * static_cast<std::size_t>(renderbuffer->height), 0.0f);
        }
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint dstX = x + col;
                const GLint dstY = y + row;
                if (dstX < 0 || dstY < 0 || dstX >= renderbuffer->width || dstY >= renderbuffer->height) {
                    continue;
                }
                renderbuffer->depth32[
                    static_cast<std::size_t>(dstY) * static_cast<std::size_t>(renderbuffer->width) + static_cast<std::size_t>(dstX)
                ] = pixels[static_cast<std::size_t>(row * width + col)];
            }
        }
        return true;
    }

    bool writeStencilAttachmentPixels(const GLFramebufferAttachment& attachment, GLint x, GLint y, GLsizei width, GLsizei height, const std::uint8_t* pixels) {
        if (attachment.kind != GLFramebufferAttachment::Kind::Renderbuffer) {
            return false;
        }
        GLRenderbufferObject* renderbuffer = objects->renderbuffers().get(attachment.object);
        if (renderbuffer == nullptr || !renderbuffer->storageDefined || !isStencilFormat(renderbuffer->internalFormat)) {
            return false;
        }
        if (renderbuffer->stencil8.empty()) {
            renderbuffer->stencil8.assign(static_cast<std::size_t>(renderbuffer->width) * static_cast<std::size_t>(renderbuffer->height), 0);
        }
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint dstX = x + col;
                const GLint dstY = y + row;
                if (dstX < 0 || dstY < 0 || dstX >= renderbuffer->width || dstY >= renderbuffer->height) {
                    continue;
                }
                renderbuffer->stencil8[
                    static_cast<std::size_t>(dstY) * static_cast<std::size_t>(renderbuffer->width) + static_cast<std::size_t>(dstX)
                ] = pixels[static_cast<std::size_t>(row * width + col)];
            }
        }
        return true;
    }

    // Phase A blit: nearest-only, integer-clamped CPU copy between attached images.
    // Scaling and linear filtering land alongside the Metal compute path in a later
    // group; for the bootstrap-bridge surface we just need a correct 1:1 copy that
    // honors the COLOR/DEPTH/STENCIL mask plumbing and the read/draw bindings.
    bool blitFramebuffer(GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1, GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1, GLbitfield mask, GLenum filter) {
        if (filter != GL_NEAREST && filter != GL_LINEAR) {
            return false;
        }
        const GLbitfield kSupportedMask = GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT;
        if ((mask & ~kSupportedMask) != 0 || mask == 0) {
            return false;
        }

        const GLuint readName = state->boundReadFramebuffer();
        const GLuint drawName = state->boundDrawFramebuffer();
        const GLFramebufferObject* readFb = objects->framebuffers().get(readName);
        GLFramebufferObject* drawFb = objects->framebuffers().get(drawName);
        if (readName == 0 || drawName == 0 || readFb == nullptr || drawFb == nullptr) {
            return false;
        }
        if (framebufferStatus(*readFb) != GL_FRAMEBUFFER_COMPLETE || framebufferStatus(*drawFb) != GL_FRAMEBUFFER_COMPLETE) {
            return false;
        }

        const GLint srcX = std::min(srcX0, srcX1);
        const GLint srcY = std::min(srcY0, srcY1);
        const GLsizei copyWidth = static_cast<GLsizei>(std::abs(srcX1 - srcX0));
        const GLsizei copyHeight = static_cast<GLsizei>(std::abs(srcY1 - srcY0));
        const GLint dstX = std::min(dstX0, dstX1);
        const GLint dstY = std::min(dstY0, dstY1);
        const GLsizei dstWidth = static_cast<GLsizei>(std::abs(dstX1 - dstX0));
        const GLsizei dstHeight = static_cast<GLsizei>(std::abs(dstY1 - dstY0));
        if (copyWidth <= 0 || copyHeight <= 0) {
            return true;  // empty blit is a no-op success per spec
        }
        // Phase A: only 1:1 unmagnified blits are wired up. Scale-aware sampling
        // belongs with the Metal blit encoder pass in Group 6.
        if (dstWidth != copyWidth || dstHeight != copyHeight) {
            return false;
        }

        if ((mask & GL_COLOR_BUFFER_BIT) != 0) {
            const GLFramebufferAttachment* srcAttachment = framebufferAttachment(*readFb, readFb->readBuffer);
            if (srcAttachment == nullptr) {
                return false;
            }
            std::vector<std::uint8_t> staging(static_cast<std::size_t>(copyWidth) * static_cast<std::size_t>(copyHeight) * 4u);
            if (!readColorAttachmentPixels(*srcAttachment, srcX, srcY, copyWidth, copyHeight, staging.data())) {
                return false;
            }
            for (GLenum buffer : drawFb->drawBuffers) {
                if (buffer == GL_NONE) {
                    continue;
                }
                const GLFramebufferAttachment* dstAttachment = framebufferAttachment(*drawFb, buffer);
                if (dstAttachment == nullptr) {
                    continue;
                }
                if (!writeColorAttachmentPixels(*dstAttachment, dstX, dstY, copyWidth, copyHeight, staging.data())) {
                    return false;
                }
            }
        }

        if ((mask & GL_DEPTH_BUFFER_BIT) != 0) {
            const GLFramebufferAttachment* srcAttachment = framebufferAttachment(*readFb, GL_DEPTH_ATTACHMENT);
            const GLFramebufferAttachment* dstAttachment = framebufferAttachment(*drawFb, GL_DEPTH_ATTACHMENT);
            if (srcAttachment != nullptr && dstAttachment != nullptr) {
                std::vector<GLfloat> staging(static_cast<std::size_t>(copyWidth) * static_cast<std::size_t>(copyHeight));
                if (!readDepthAttachmentPixels(*srcAttachment, srcX, srcY, copyWidth, copyHeight, staging.data())) {
                    return false;
                }
                if (!writeDepthAttachmentPixels(*dstAttachment, dstX, dstY, copyWidth, copyHeight, staging.data())) {
                    return false;
                }
            }
        }

        if ((mask & GL_STENCIL_BUFFER_BIT) != 0) {
            const GLFramebufferAttachment* srcAttachment = framebufferAttachment(*readFb, GL_STENCIL_ATTACHMENT);
            const GLFramebufferAttachment* dstAttachment = framebufferAttachment(*drawFb, GL_STENCIL_ATTACHMENT);
            if (srcAttachment != nullptr && dstAttachment != nullptr) {
                std::vector<std::uint8_t> staging(static_cast<std::size_t>(copyWidth) * static_cast<std::size_t>(copyHeight));
                if (!readStencilAttachmentPixels(*srcAttachment, srcX, srcY, copyWidth, copyHeight, staging.data())) {
                    return false;
                }
                if (!writeStencilAttachmentPixels(*dstAttachment, dstX, dstY, copyWidth, copyHeight, staging.data())) {
                    return false;
                }
            }
        }

        return true;
    }

    bool readFramebufferPixels(GLenum format, GLint x, GLint y, GLsizei width, GLsizei height, void* pixels) const {
        const GLuint framebufferName = state->boundReadFramebuffer();
        const GLFramebufferObject* framebuffer = objects->framebuffers().get(framebufferName);
        if (framebufferName == 0 || framebuffer == nullptr || !framebuffer->instantiated || framebufferStatus(*framebuffer) != GL_FRAMEBUFFER_COMPLETE) {
            return false;
        }

        if (format == GL_RGBA) {
            if (framebuffer->readBuffer == GL_NONE) {
                return false;
            }
            const GLFramebufferAttachment* attachment = framebufferAttachment(*framebuffer, framebuffer->readBuffer);
            return attachment != nullptr && readColorAttachmentPixels(*attachment, x, y, width, height, pixels);
        }
        if (format == GL_DEPTH_COMPONENT) {
            const GLFramebufferAttachment* attachment = framebufferAttachment(*framebuffer, GL_DEPTH_ATTACHMENT);
            return attachment != nullptr && readDepthAttachmentPixels(*attachment, x, y, width, height, pixels);
        }
        if (format == GL_STENCIL_INDEX) {
            const GLFramebufferAttachment* attachment = framebufferAttachment(*framebuffer, GL_STENCIL_ATTACHMENT);
            return attachment != nullptr && readStencilAttachmentPixels(*attachment, x, y, width, height, pixels);
        }
        return false;
    }

    void encodePendingWork() {
        if (!pendingClear || frameGraph == nullptr) {
            return;
        }

        frameGraph->resizeDrawable(viewportWidth, viewportHeight);
        frameGraph->encodeDefaultFramebufferClear(
            pendingMask,
            state->clearState().color[0],
            state->clearState().color[1],
            state->clearState().color[2],
            state->clearState().color[3],
            state->clearState().depth,
            state->clearState().stencil
        );
        pendingMask = 0;
        pendingClear = false;
    }

    void presentPendingWork() {
        encodePendingWork();
        if (frameGraph != nullptr) {
            frameGraph->present();
        }
    }

    bool debugMessageEnabled(const DebugMessageRecord& message) const {
        for (auto cursor = debugControlRules.rbegin(); cursor != debugControlRules.rend(); ++cursor) {
            if (debugRuleMatches(*cursor, message)) {
                return cursor->enabled;
            }
        }
        return true;
    }

    void enqueueDebugMessage(DebugMessageRecord message) {
        if (!debugMessageEnabled(message)) {
            return;
        }
        message.message = trimDebugMessage(message.message);
        debugMessages.push_back(message);
        while (debugMessages.size() > kMaxDebugMessages) {
            debugMessages.pop_front();
        }

        if (debugCallback != nullptr) {
            debugCallback(
                message.source,
                message.type,
                message.id,
                message.severity,
                static_cast<GLsizei>(message.message.size()),
                message.message.c_str(),
                debugUserParam
            );
        }
    }

    CAMetalLayer* layer = nil;
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> commandQueue = nil;
    std::unique_ptr<MetalFrameGraph> frameGraph;
    std::unique_ptr<GLCapabilities> capabilities;
    std::unique_ptr<GLObjectStore> objects;
    std::unique_ptr<GLStateTracker> state;
    GLbitfield pendingMask = GL_COLOR_BUFFER_BIT;
    bool pendingClear = true;
    GLint viewportX = 0;
    GLint viewportY = 0;
    GLsizei viewportWidth = 1280;
    GLsizei viewportHeight = 720;
    GLDEBUGPROC debugCallback = nullptr;
    const void* debugUserParam = nullptr;
    std::deque<DebugMessageRecord> debugMessages;
    std::vector<DebugControlRule> debugControlRules;
    std::vector<DebugMessageRecord> debugGroupStack;
    std::unordered_map<std::uint64_t, std::string> objectLabels;
    std::unordered_map<const void*, std::string> pointerLabels;
    std::deque<GLenum> errors;
    // Per-context immediate double vertex attribute values (GL 4.1 glVertexAttribL*).
    // Indexed by attribute slot; each stores 4 doubles (default {0,0,0,1}).
    static constexpr std::size_t kMaxImmediateDoubleAttribs = 16;
    std::array<std::array<GLdouble, 4>, kMaxImmediateDoubleAttribs> immediateDoubleAttribs{};
    // GL 4.2 — image load/store unit bindings.
    struct ImageBinding {
        GLuint texture = 0;
        GLint level = 0;
        GLboolean layered = GL_FALSE;
        GLint layer = 0;
        GLenum access = GL_READ_ONLY;
        GLenum format = GL_RGBA8;
    };
    static constexpr std::size_t kMaxImageUnits = 8;
    std::array<ImageBinding, kMaxImageUnits> imageBindings{};

    std::string vendorString = "AppGL";
    std::string rendererString = "AppGL on Metal";
    std::string versionString;
    std::string shadingLanguageVersion = "3.30 AppGL bootstrap";
    std::string extensionsString;
};

GLContext::GLContext(void* layer)
    : impl_(std::make_unique<Impl>(layer, 1280, 720, false)) {
    Runtime::shared().registerContext(this);
}

GLContext::GLContext(GLsizei offscreenWidth, GLsizei offscreenHeight)
    : impl_(std::make_unique<Impl>(nullptr, offscreenWidth, offscreenHeight, true)) {
    Runtime::shared().registerContext(this);
}

GLContext::~GLContext() {
    Runtime::shared().unregisterContext(this);
}

void GLContext::setClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    impl_->state->setClearColor(red, green, blue, alpha);
}

void GLContext::setClearDepth(GLdouble depth) {
    impl_->state->setClearDepth(depth);
}

void GLContext::setClearStencil(GLint stencil) {
    impl_->state->setClearStencil(stencil);
}

void GLContext::clear(GLbitfield mask) {
    if (impl_->state->boundDrawFramebuffer() != 0) {
        if (!impl_->clearBoundFramebuffer(mask)) {
            pushError(GL_INVALID_FRAMEBUFFER_OPERATION);
        }
        return;
    }
    // Accumulate mask bits so consecutive glClear calls (e.g. color then
    // depth) don't overwrite each other before the pending clear is flushed.
    impl_->pendingMask |= mask;
    impl_->pendingClear = (impl_->pendingMask & (GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT)) != 0;
}

void GLContext::setViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    impl_->viewportX = x;
    impl_->viewportY = y;
    impl_->viewportWidth = width > 0 ? width : 1;
    impl_->viewportHeight = height > 0 ? height : 1;
    impl_->state->setViewport(x, y, width, height);
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->resizeDrawable(impl_->viewportWidth, impl_->viewportHeight);
    }
}

void GLContext::setScissor(GLint x, GLint y, GLsizei width, GLsizei height) {
    impl_->state->setScissor(x, y, width, height);
}

void GLContext::setDepthRange(GLdouble nearValue, GLdouble farValue) {
    impl_->state->setDepthRange(nearValue, farValue);
}

// --- Per-viewport-index state (GL 4.1 ARB_viewport_array) ---

void GLContext::setViewportIndexed(GLuint index, GLfloat x, GLfloat y, GLfloat w, GLfloat h) {
    impl_->state->setViewportIndexed(index, x, y, w, h);
}

void GLContext::setViewportArray(GLuint first, GLsizei count, const GLfloat* v) {
    impl_->state->setViewportArray(first, count, v);
}

void GLContext::setScissorIndexed(GLuint index, GLint left, GLint bottom, GLsizei width, GLsizei height) {
    impl_->state->setScissorIndexed(index, left, bottom, width, height);
}

void GLContext::setScissorArray(GLuint first, GLsizei count, const GLint* v) {
    impl_->state->setScissorArray(first, count, v);
}

void GLContext::setDepthRangeIndexed(GLuint index, GLdouble nearVal, GLdouble farVal) {
    impl_->state->setDepthRangeIndexed(index, nearVal, farVal);
}

void GLContext::setDepthRangeArray(GLuint first, GLsizei count, const GLdouble* v) {
    impl_->state->setDepthRangeArray(first, count, v);
}

bool GLContext::queryFloatIndexed(GLenum target, GLuint index, GLfloat* data) {
    return impl_->state->queryFloatIndexed(target, index, data);
}

bool GLContext::queryDoubleIndexed(GLenum target, GLuint index, GLdouble* data) {
    return impl_->state->queryDoubleIndexed(target, index, data);
}

// --- Tessellation state (GL 4.0) ---

void GLContext::setPatchParameteri(GLenum pname, GLint value) {
    impl_->state->setPatchParameteri(pname, value);
}

void GLContext::setPatchParameterfv(GLenum pname, const GLfloat* values) {
    impl_->state->setPatchParameterfv(pname, values);
}

// --- Shader precision query (GL 4.1) ---

void GLContext::getShaderPrecisionFormat(GLenum shadertype, GLenum precisiontype, GLint* range, GLint* precision) {
    // Metal GPUs support full 32-bit float and integer precision.
    // Report ranges matching IEEE 754 single-precision and 32-bit integer.
    (void)shadertype;
    switch (precisiontype) {
        case GL_LOW_FLOAT:
        case GL_MEDIUM_FLOAT:
        case GL_HIGH_FLOAT:
            if (range) { range[0] = 127; range[1] = 127; }
            if (precision) { *precision = 23; }
            break;
        case GL_LOW_INT:
        case GL_MEDIUM_INT:
        case GL_HIGH_INT:
            if (range) { range[0] = 31; range[1] = 30; }
            if (precision) { *precision = 0; }
            break;
        default:
            if (range) { range[0] = 0; range[1] = 0; }
            if (precision) { *precision = 0; }
            break;
    }
}

void GLContext::setBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha) {
    impl_->state->setBlendFuncSeparate(srcRGB, dstRGB, srcAlpha, dstAlpha);
}

void GLContext::setBlendFuncSeparatei(GLuint index, GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha) {
    impl_->state->setBlendFuncSeparatei(index, srcRGB, dstRGB, srcAlpha, dstAlpha);
}

void GLContext::setBlendEquationSeparate(GLenum equationRGB, GLenum equationAlpha) {
    impl_->state->setBlendEquationSeparate(equationRGB, equationAlpha);
}

void GLContext::setBlendEquationSeparatei(GLuint index, GLenum equationRGB, GLenum equationAlpha) {
    impl_->state->setBlendEquationSeparatei(index, equationRGB, equationAlpha);
}

void GLContext::setBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    impl_->state->setBlendColor(red, green, blue, alpha);
}

void GLContext::setColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha) {
    impl_->state->setColorMask(red, green, blue, alpha);
}

void GLContext::setColorMaski(GLuint index, GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha) {
    impl_->state->setColorMaski(index, red, green, blue, alpha);
}

void GLContext::setMinSampleShading(GLfloat value) {
    impl_->state->setMinSampleShading(value);
}

void GLContext::setDepthFunc(GLenum func) {
    impl_->state->setDepthFunc(func);
}

void GLContext::setDepthMask(GLboolean flag) {
    impl_->state->setDepthMask(flag);
}

void GLContext::setStencilFuncSeparate(GLenum face, GLenum func, GLint ref, GLuint mask) {
    impl_->state->setStencilFuncSeparate(face, func, ref, mask);
}

void GLContext::setStencilOpSeparate(GLenum face, GLenum fail, GLenum depthFail, GLenum depthPass) {
    impl_->state->setStencilOpSeparate(face, fail, depthFail, depthPass);
}

void GLContext::setStencilMaskSeparate(GLenum face, GLuint mask) {
    impl_->state->setStencilMaskSeparate(face, mask);
}

void GLContext::setCullFace(GLenum mode) {
    impl_->state->setCullFace(mode);
}

void GLContext::setFrontFace(GLenum mode) {
    impl_->state->setFrontFace(mode);
}

void GLContext::setPolygonOffset(GLfloat factor, GLfloat units) {
    impl_->state->setPolygonOffset(factor, units);
}

void GLContext::setLineWidth(GLfloat width) {
    impl_->state->setLineWidth(width);
}

void GLContext::setPointSize(GLfloat size) {
    impl_->state->setPointSize(size);
}

void GLContext::setHint(GLenum target, GLenum mode) {
    impl_->state->setHint(target, mode);
}

void GLContext::flush() {
    impl_->presentPendingWork();
}

void GLContext::swapBuffers() {
    impl_->presentPendingWork();
}

bool GLContext::readPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels) {
    if (pixels == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (width == 0 || height == 0) {
        return true;
    }

    if (impl_->state->boundReadFramebuffer() != 0) {
        const bool supportedReadback =
            (format == GL_RGBA && type == GL_UNSIGNED_BYTE)
            || (format == GL_DEPTH_COMPONENT && type == GL_FLOAT)
            || (format == GL_STENCIL_INDEX && type == GL_UNSIGNED_BYTE);
        if (!supportedReadback) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        if (!impl_->readFramebufferPixels(format, x, y, width, height, pixels)) {
            pushError(GL_INVALID_FRAMEBUFFER_OPERATION);
            return false;
        }
        return true;
    }

    if (format != GL_RGBA || type != GL_UNSIGNED_BYTE) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    impl_->encodePendingWork();
    if (impl_->frameGraph == nullptr || !impl_->frameGraph->copyRGBA8Pixels(x, y, width, height, pixels)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    return true;
}

bool GLContext::queryBoolean(GLenum pname, GLboolean* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH || pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = integerValue != 0 ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (impl_->state->queryBoolean(pname, data)) {
        return true;
    }
    GLint integerData[4] = {};
    if (impl_->capabilities != nullptr && impl_->capabilities->queryInteger(pname, integerData)) {
        data[0] = integerData[0] != 0 ? GL_TRUE : GL_FALSE;
        if (pname == GL_MAX_VIEWPORT_DIMS) {
            data[1] = integerData[1] != 0 ? GL_TRUE : GL_FALSE;
        }
        return true;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

bool GLContext::queryInteger(GLenum pname, GLint* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH) {
        *data = static_cast<GLint>(impl_->debugGroupStack.size());
        return true;
    }
    if (pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        *data = impl_->debugMessages.empty()
            ? 0
            : static_cast<GLint>(impl_->debugMessages.front().message.size() + 1);
        return true;
    }
    if (pname == GL_READ_BUFFER) {
        const GLuint framebufferName = impl_->state->boundReadFramebuffer();
        const GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
        *data = static_cast<GLint>(framebufferName != 0 && framebuffer != nullptr ? framebuffer->readBuffer : impl_->state->readBuffer());
        return true;
    }
    if (pname == GL_DRAW_BUFFER || (pname >= GL_DRAW_BUFFER0 && pname <= GL_DRAW_BUFFER7)) {
        const GLuint index = pname == GL_DRAW_BUFFER ? 0u : static_cast<GLuint>(pname - GL_DRAW_BUFFER0);
        const GLuint framebufferName = impl_->state->boundDrawFramebuffer();
        const GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
        *data = static_cast<GLint>(framebufferName != 0 && framebuffer != nullptr ? framebuffer->drawBuffers[index] : impl_->state->drawBuffer(index));
        return true;
    }
    if (impl_->state->queryInteger(pname, data)) {
        return true;
    }
    if (impl_->capabilities == nullptr || !impl_->capabilities->queryInteger(pname, data)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::queryInteger64(GLenum pname, GLint64* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH || pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = static_cast<GLint64>(integerValue);
        return true;
    }
    if (impl_->state->queryInteger64(pname, data)) {
        return true;
    }
    if (impl_->capabilities == nullptr || !impl_->capabilities->queryInteger64(pname, data)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::queryFloat(GLenum pname, GLfloat* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH || pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = static_cast<GLfloat>(integerValue);
        return true;
    }
    if (impl_->state->queryFloat(pname, data)) {
        return true;
    }
    if (impl_->capabilities == nullptr || !impl_->capabilities->queryFloat(pname, data)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::queryDouble(GLenum pname, GLdouble* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH || pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = static_cast<GLdouble>(integerValue);
        return true;
    }
    if (impl_->state->queryDouble(pname, data)) {
        return true;
    }
    GLfloat floatData[4] = {};
    if (impl_->capabilities != nullptr && impl_->capabilities->queryFloat(pname, floatData)) {
        data[0] = static_cast<GLdouble>(floatData[0]);
        if (pname == GL_MAX_VIEWPORT_DIMS) {
            data[1] = static_cast<GLdouble>(floatData[1]);
        }
        return true;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

void GLContext::setEnabled(GLenum cap, bool enabled) {
    if (enabled) {
        impl_->state->enable(cap);
    } else {
        impl_->state->disable(cap);
    }
}

bool GLContext::isEnabled(GLenum cap) const {
    return impl_->state->isEnabled(cap);
}

void GLContext::setDebugCallback(GLDEBUGPROC callback, const void* userParam) {
    impl_->debugCallback = callback;
    impl_->debugUserParam = userParam;
}

void GLContext::emitDebugMessage(
    GLenum source,
    GLenum type,
    GLuint id,
    GLenum severity,
    std::string_view message
) {
    impl_->enqueueDebugMessage({source, type, id, severity, std::string(message)});
}

void GLContext::setDebugMessageControl(
    GLenum source,
    GLenum type,
    GLenum severity,
    GLsizei count,
    const GLuint* ids,
    GLboolean enabled
) {
    DebugControlRule rule;
    rule.source = source;
    rule.type = type;
    rule.severity = severity;
    rule.enabled = enabled == GL_TRUE;
    rule.hasIds = count > 0;
    for (GLsizei index = 0; index < count; ++index) {
        rule.ids.insert(ids[index]);
    }
    impl_->debugControlRules.push_back(std::move(rule));
}

void GLContext::insertDebugMessage(
    GLenum source,
    GLenum type,
    GLuint id,
    GLenum severity,
    std::string_view message
) {
    emitDebugMessage(source, type, id, severity, message);
}

GLuint GLContext::getDebugMessageLog(
    GLuint count,
    GLsizei bufSize,
    GLenum* sources,
    GLenum* types,
    GLuint* ids,
    GLenum* severities,
    GLsizei* lengths,
    GLchar* messageLog
) {
    if (bufSize < 0) {
        pushError(GL_INVALID_VALUE);
        return 0;
    }

    GLuint delivered = 0;
    GLsizei usedBytes = 0;
    while (delivered < count && !impl_->debugMessages.empty()) {
        const DebugMessageRecord& message = impl_->debugMessages.front();
        const GLsizei requiredBytes = static_cast<GLsizei>(message.message.size() + 1);
        if (messageLog != nullptr && usedBytes + requiredBytes > bufSize) {
            break;
        }

        if (sources != nullptr) {
            sources[delivered] = message.source;
        }
        if (types != nullptr) {
            types[delivered] = message.type;
        }
        if (ids != nullptr) {
            ids[delivered] = message.id;
        }
        if (severities != nullptr) {
            severities[delivered] = message.severity;
        }
        if (lengths != nullptr) {
            lengths[delivered] = requiredBytes;
        }
        if (messageLog != nullptr) {
            std::memcpy(messageLog + usedBytes, message.message.c_str(), static_cast<std::size_t>(requiredBytes));
            usedBytes += requiredBytes;
        }

        impl_->debugMessages.pop_front();
        ++delivered;
    }
    return delivered;
}

void GLContext::pushDebugGroup(GLenum source, GLuint id, std::string_view message) {
    if (impl_->debugGroupStack.size() >= kMaxDebugGroupDepth) {
        pushError(GL_STACK_OVERFLOW);
        return;
    }
    DebugMessageRecord record{source, GL_DEBUG_TYPE_PUSH_GROUP, id, GL_DEBUG_SEVERITY_NOTIFICATION, std::string(message)};
    impl_->debugGroupStack.push_back(record);
    impl_->enqueueDebugMessage(record);
}

bool GLContext::popDebugGroup() {
    if (impl_->debugGroupStack.empty()) {
        pushError(GL_STACK_UNDERFLOW);
        return false;
    }
    DebugMessageRecord record = impl_->debugGroupStack.back();
    impl_->debugGroupStack.pop_back();
    record.type = GL_DEBUG_TYPE_POP_GROUP;
    impl_->enqueueDebugMessage(std::move(record));
    return true;
}

void GLContext::setObjectLabel(GLenum identifier, GLuint name, std::string_view label) {
    const std::uint64_t key = objectLabelKey(identifier, name);
    if (label.empty()) {
        impl_->objectLabels.erase(key);
        return;
    }
    impl_->objectLabels[key] = trimDebugMessage(label);
}

void GLContext::getObjectLabel(GLenum identifier, GLuint name, GLsizei bufSize, GLsizei* length, GLchar* label) {
    if (bufSize < 0) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    const auto found = impl_->objectLabels.find(objectLabelKey(identifier, name));
    const std::string_view value = found == impl_->objectLabels.end() ? std::string_view{} : std::string_view(found->second);
    copyLabelString(value, bufSize, length, label);
}

void GLContext::setObjectPtrLabel(const void* ptr, std::string_view label) {
    if (label.empty()) {
        impl_->pointerLabels.erase(ptr);
        return;
    }
    impl_->pointerLabels[ptr] = trimDebugMessage(label);
}

void GLContext::getObjectPtrLabel(const void* ptr, GLsizei bufSize, GLsizei* length, GLchar* label) {
    if (bufSize < 0) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    const auto found = impl_->pointerLabels.find(ptr);
    const std::string_view value = found == impl_->pointerLabels.end() ? std::string_view{} : std::string_view(found->second);
    copyLabelString(value, bufSize, length, label);
}

bool GLContext::getPointer(GLenum pname, void** params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    switch (pname) {
        case GL_DEBUG_CALLBACK_FUNCTION:
            *params = reinterpret_cast<void*>(impl_->debugCallback);
            return true;
        case GL_DEBUG_CALLBACK_USER_PARAM:
            *params = const_cast<void*>(impl_->debugUserParam);
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::genBuffers(GLsizei count, GLuint* buffers) {
    if (count < 0 || (count > 0 && buffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        buffers[index] = impl_->objects->buffers().reserveName();
    }
    return true;
}

bool GLContext::deleteBuffers(GLsizei count, const GLuint* buffers) {
    if (count < 0 || (count > 0 && buffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = buffers[index];
        if (name == 0) {
            continue;
        }
        if (GLBufferObject* object = impl_->objects->buffers().get(name); object != nullptr) {
            impl_->releaseBufferStorage(*object);
        }
        if (impl_->objects->buffers().erase(name)) {
            impl_->state->deleteBufferBindings(name);
            impl_->deleteBufferReferencesFromVertexArrays(name);
            impl_->objects->deferDelete("buffer " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isBuffer(GLuint buffer) const {
    const GLBufferObject* object = impl_->objects->buffers().get(buffer);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindBuffer(GLenum target, GLuint buffer) {
    if (buffer == 0) {
        impl_->state->bindBuffer(target, 0);
        if (target == GL_ELEMENT_ARRAY_BUFFER) {
            if (GLVertexArrayObject* vertexArray = impl_->currentVertexArray(); vertexArray != nullptr) {
                vertexArray->elementArrayBuffer = 0;
            }
        }
        return true;
    }
    GLBufferObject* object = impl_->objects->buffers().get(buffer);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    object->instantiated = true;
    impl_->state->bindBuffer(target, buffer);
    if (target == GL_ELEMENT_ARRAY_BUFFER) {
        if (GLVertexArrayObject* vertexArray = impl_->currentVertexArray(); vertexArray != nullptr) {
            vertexArray->elementArrayBuffer = buffer;
        }
    }
    return true;
}

bool GLContext::bindBufferRange(GLenum target, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    if (buffer == 0) {
        impl_->state->bindIndexedBuffer(target, index, 0, 0, 0);
        // Spec: bind* with buffer == 0 also resets the generic target binding.
        impl_->state->bindBuffer(target, 0);
        return true;
    }
    if (offset < 0 || size < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLBufferObject* object = impl_->objects->buffers().get(buffer);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    object->instantiated = true;
    impl_->state->bindIndexedBuffer(target, index, buffer, offset, size);
    // Spec (4.6 §6.1.1): BindBufferRange additionally binds buffer to the generic
    // buffer binding point specified by target. Without this the generic UBO/SSBO
    // bindings would silently desync from the indexed table after a per-index bind.
    impl_->state->bindBuffer(target, buffer);
    return true;
}

bool GLContext::bindBufferBase(GLenum target, GLuint index, GLuint buffer) {
    GLsizeiptr size = 0;
    if (buffer != 0) {
        GLBufferObject* object = impl_->objects->buffers().get(buffer);
        if (object == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        object->instantiated = true;
        size = object->size;
    }
    impl_->state->bindIndexedBuffer(target, index, buffer, 0, size);
    // Spec (4.6 §6.1.1): BindBufferBase also binds buffer to the generic target.
    impl_->state->bindBuffer(target, buffer);
    return true;
}

bool GLContext::bufferData(GLenum target, GLsizeiptr size, const void* data, GLenum usage) {
    if (size < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (object->mapped) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!impl_->replaceBufferStorage(*object, size, data, usage)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::bufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data) {
    if (offset < 0 || size < 0 || (size > 0 && data == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || object->mapped) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (offset > object->size || size > object->size - offset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (size > 0) {
        std::memcpy(
            object->shadowBytes.data() + static_cast<std::size_t>(offset),
            data,
            static_cast<std::size_t>(size)
        );
        impl_->syncMetalFromShadow(*object, offset, size);
    }
    return true;
}

bool GLContext::copyBufferSubData(
    GLenum readTarget,
    GLenum writeTarget,
    GLintptr readOffset,
    GLintptr writeOffset,
    GLsizeiptr size
) {
    if (readOffset < 0 || writeOffset < 0 || size < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint readName = impl_->state->boundBuffer(readTarget);
    const GLuint writeName = impl_->state->boundBuffer(writeTarget);
    GLBufferObject* readObject = impl_->objects->buffers().get(readName);
    GLBufferObject* writeObject = impl_->objects->buffers().get(writeName);
    if (readName == 0 || writeName == 0 || readObject == nullptr || writeObject == nullptr
        || !readObject->instantiated || !writeObject->instantiated || readObject->mapped || writeObject->mapped) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (readOffset > readObject->size || size > readObject->size - readOffset
        || writeOffset > writeObject->size || size > writeObject->size - writeOffset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (readName == writeName) {
        const GLintptr readEnd = readOffset + size;
        const GLintptr writeEnd = writeOffset + size;
        if (size > 0 && readOffset < writeEnd && writeOffset < readEnd) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    if (size > 0) {
        const std::uint8_t* readBytes = impl_->readableBufferContents(*readObject);
        if (readBytes == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        std::memcpy(
            writeObject->shadowBytes.data() + static_cast<std::size_t>(writeOffset),
            readBytes + static_cast<std::size_t>(readOffset),
            static_cast<std::size_t>(size)
        );
        impl_->syncMetalFromShadow(*writeObject, writeOffset, size);
    }
    return true;
}

bool GLContext::getBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, void* data) {
    if (offset < 0 || size < 0 || (size > 0 && data == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || object->mapped) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (offset > object->size || size > object->size - offset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (size > 0) {
        const std::uint8_t* bytes = impl_->readableBufferContents(*object);
        if (bytes == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        std::memcpy(data, bytes + static_cast<std::size_t>(offset), static_cast<std::size_t>(size));
    }
    return true;
}

void* GLContext::mapBuffer(GLenum target, GLenum access) {
    GLbitfield flags = 0;
    if (!legacyMapAccessToFlags(access, &flags)) {
        pushError(GL_INVALID_ENUM);
        return nullptr;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || object->mapped || object->size <= 0) {
        pushError(GL_INVALID_OPERATION);
        return nullptr;
    }
    void* pointer = mapBufferRange(target, 0, object->size, flags);
    if (pointer != nullptr) {
        object->mapAccess = access;
    }
    return pointer;
}

void* GLContext::mapBufferRange(GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield access) {
    if (offset < 0 || length < 0) {
        pushError(GL_INVALID_VALUE);
        return nullptr;
    }
    if (!isSupportedMapBufferRangeAccess(access)) {
        pushError(GL_INVALID_VALUE);
        return nullptr;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || object->mapped) {
        pushError(GL_INVALID_OPERATION);
        return nullptr;
    }
    if (length == 0 || object->size <= 0) {
        pushError(GL_INVALID_OPERATION);
        return nullptr;
    }
    if (offset > object->size || length > object->size - offset) {
        pushError(GL_INVALID_VALUE);
        return nullptr;
    }

    std::uint8_t* contents = impl_->mutableBufferContents(*object);
    if (contents == nullptr) {
        pushError(GL_OUT_OF_MEMORY);
        return nullptr;
    }

    object->mapped = true;
    object->mapAccess = legacyMapAccessFromFlags(access);
    object->mapAccessFlags = access;
    object->mapOffset = offset;
    object->mapLength = length;
    object->mapPointer = contents + static_cast<std::size_t>(offset);
    return object->mapPointer;
}

GLboolean GLContext::unmapBuffer(GLenum target) {
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || !object->mapped) {
        pushError(GL_INVALID_OPERATION);
        return GL_FALSE;
    }
    if (mapAccessWrites(object->mapAccessFlags)) {
        impl_->syncShadowFromMetal(*object, object->mapOffset, object->mapLength);
    }
    resetBufferMapping(*object);
    return GL_TRUE;
}

bool GLContext::flushMappedBufferRange(GLenum target, GLintptr offset, GLsizeiptr length) {
    if (offset < 0 || length < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || !object->mapped
        || (object->mapAccessFlags & GL_MAP_FLUSH_EXPLICIT_BIT) == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (offset > object->mapLength || length > object->mapLength - offset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (mapAccessWrites(object->mapAccessFlags)) {
        impl_->syncShadowFromMetal(*object, object->mapOffset + offset, length);
    }
    return true;
}

bool GLContext::getBufferParameterInteger(GLenum target, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLint64 value = 0;
    if (!getBufferParameterInteger64(target, pname, &value)) {
        return false;
    }
    *params = static_cast<GLint>(value);
    return true;
}

bool GLContext::getBufferParameterInteger64(GLenum target, GLenum pname, GLint64* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    switch (pname) {
        case GL_BUFFER_SIZE:
            *params = object->size;
            return true;
        case GL_BUFFER_USAGE:
            *params = object->usage;
            return true;
        case GL_BUFFER_ACCESS:
            *params = object->mapAccess;
            return true;
        case GL_BUFFER_ACCESS_FLAGS:
            *params = object->mapped ? object->mapAccessFlags : 0;
            return true;
        case GL_BUFFER_MAPPED:
            *params = object->mapped ? GL_TRUE : GL_FALSE;
            return true;
        case GL_BUFFER_MAP_OFFSET:
            *params = object->mapped ? object->mapOffset : 0;
            return true;
        case GL_BUFFER_MAP_LENGTH:
            *params = object->mapped ? object->mapLength : 0;
            return true;
        case GL_BUFFER_IMMUTABLE_STORAGE:
            *params = GL_FALSE;
            return true;
        case GL_BUFFER_STORAGE_FLAGS:
            *params = 0;
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getBufferPointer(GLenum target, GLenum pname, void** params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname != GL_BUFFER_MAP_POINTER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    *params = object->mapped ? object->mapPointer : nullptr;
    return true;
}

bool GLContext::genVertexArrays(GLsizei count, GLuint* arrays) {
    if (count < 0 || (count > 0 && arrays == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = impl_->objects->vertexArrays().reserveName();
        arrays[index] = name;
        if (GLVertexArrayObject* object = impl_->objects->vertexArrays().get(name); object != nullptr) {
            impl_->objects->initializeVertexArray(*object);
        }
    }
    return true;
}

bool GLContext::deleteVertexArrays(GLsizei count, const GLuint* arrays) {
    if (count < 0 || (count > 0 && arrays == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = arrays[index];
        if (name == 0) {
            continue;
        }
        if (GLVertexArrayObject* object = impl_->objects->vertexArrays().get(name); object != nullptr) {
            impl_->releaseVertexDescriptor(*object);
        }
        if (impl_->objects->vertexArrays().erase(name)) {
            if (impl_->state->boundVertexArray() == name) {
                impl_->state->bindVertexArray(0);
                impl_->state->bindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
            }
            impl_->objects->deferDelete("vertex array " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isVertexArray(GLuint array) const {
    const GLVertexArrayObject* object = impl_->objects->vertexArrays().get(array);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindVertexArray(GLuint array) {
    if (array == 0) {
        impl_->state->bindVertexArray(0);
        impl_->state->bindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
        return true;
    }
    GLVertexArrayObject* object = impl_->vertexArray(array);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    object->instantiated = true;
    impl_->state->bindVertexArray(array);
    impl_->state->bindBuffer(GL_ELEMENT_ARRAY_BUFFER, object->elementArrayBuffer);
    return true;
}

bool GLContext::enableVertexAttribArray(GLuint index, bool enabled) {
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    vertexArray->attributes[index].enabled = enabled;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribPointer(
    GLuint index,
    GLint size,
    GLenum type,
    GLboolean normalized,
    GLsizei stride,
    const void* pointer
) {
    if (size < 1 || size > 4 || stride < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    const GLuint buffer = impl_->state->boundBuffer(GL_ARRAY_BUFFER);
    if (buffer == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    auto& attribute = vertexArray->attributes[index];
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = normalized;
    attribute.stride = stride;
    attribute.pointer = reinterpret_cast<std::uintptr_t>(pointer);
    attribute.buffer = buffer;
    attribute.integer = false;
    attribute.longData = false;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribIPointer(GLuint index, GLint size, GLenum type, GLsizei stride, const void* pointer) {
    if (size < 1 || size > 4 || stride < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    const GLuint buffer = impl_->state->boundBuffer(GL_ARRAY_BUFFER);
    if (buffer == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    auto& attribute = vertexArray->attributes[index];
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = GL_FALSE;
    attribute.stride = stride;
    attribute.pointer = reinterpret_cast<std::uintptr_t>(pointer);
    attribute.buffer = buffer;
    attribute.integer = true;
    attribute.longData = false;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribDivisor(GLuint index, GLuint divisor) {
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    vertexArray->attributes[index].divisor = divisor;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

// --- GL 4.3: Separated vertex format (ARB_vertex_attrib_binding) ---

bool GLContext::bindVertexBuffer(GLuint bindingindex, GLuint buffer, GLintptr offset, GLsizei stride) {
    if (stride < 0 || offset < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (bindingindex >= vertexArray->bindingPoints.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Buffer 0 is valid (unbinds the binding point).
    if (buffer != 0 && !impl_->objects->buffers().contains(buffer)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    auto& bp = vertexArray->bindingPoints[bindingindex];
    bp.buffer = buffer;
    bp.offset = offset;
    bp.stride = stride;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribFormat(GLuint attribindex, GLint size, GLenum type, GLboolean normalized, GLuint relativeoffset) {
    if (size < 1 || size > 4) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || attribindex >= vertexArray->attributes.size()) {
        pushError(attribindex >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    auto& attribute = vertexArray->attributes[attribindex];
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = normalized;
    attribute.relativeOffset = relativeoffset;
    attribute.integer = false;
    attribute.longData = false;
    attribute.useSeparatedFormat = true;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribIFormat(GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset) {
    if (size < 1 || size > 4) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || attribindex >= vertexArray->attributes.size()) {
        pushError(attribindex >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    auto& attribute = vertexArray->attributes[attribindex];
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = GL_FALSE;
    attribute.relativeOffset = relativeoffset;
    attribute.integer = true;
    attribute.longData = false;
    attribute.useSeparatedFormat = true;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribLFormat(GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset) {
    if (size < 1 || size > 4) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (type != GL_DOUBLE) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || attribindex >= vertexArray->attributes.size()) {
        pushError(attribindex >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    auto& attribute = vertexArray->attributes[attribindex];
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = GL_FALSE;
    attribute.relativeOffset = relativeoffset;
    attribute.integer = false;
    attribute.longData = true;
    attribute.useSeparatedFormat = true;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribBinding(GLuint attribindex, GLuint bindingindex) {
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (attribindex >= vertexArray->attributes.size() || bindingindex >= vertexArray->bindingPoints.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    vertexArray->attributes[attribindex].bindingIndex = bindingindex;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexBindingDivisor(GLuint bindingindex, GLuint divisor) {
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (bindingindex >= vertexArray->bindingPoints.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    vertexArray->bindingPoints[bindingindex].divisor = divisor;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::getVertexAttribInteger(GLuint index, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    const auto& attribute = vertexArray->attributes[index];
    switch (pname) {
        case GL_VERTEX_ATTRIB_ARRAY_ENABLED:
            params[0] = attribute.enabled ? GL_TRUE : GL_FALSE;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_SIZE:
            params[0] = attribute.size;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_STRIDE:
            params[0] = attribute.stride;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_TYPE:
            params[0] = static_cast<GLint>(attribute.type);
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_NORMALIZED:
            params[0] = attribute.normalized;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING:
            params[0] = static_cast<GLint>(attribute.buffer);
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_INTEGER:
            params[0] = attribute.integer ? GL_TRUE : GL_FALSE;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_DIVISOR:
            params[0] = static_cast<GLint>(attribute.divisor);
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_LONG:
            params[0] = attribute.longData ? GL_TRUE : GL_FALSE;
            return true;
        case GL_CURRENT_VERTEX_ATTRIB:
            params[0] = 0;
            params[1] = 0;
            params[2] = 0;
            params[3] = 1;
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getVertexAttribFloat(GLuint index, GLenum pname, GLfloat* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_CURRENT_VERTEX_ATTRIB) {
        params[0] = 0.0f;
        params[1] = 0.0f;
        params[2] = 0.0f;
        params[3] = 1.0f;
        return true;
    }

    GLint values[4] = {};
    if (!getVertexAttribInteger(index, pname, values)) {
        return false;
    }
    params[0] = static_cast<GLfloat>(values[0]);
    return true;
}

bool GLContext::getVertexAttribPointer(GLuint index, GLenum pname, void** pointer) {
    if (pointer == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname != GL_VERTEX_ATTRIB_ARRAY_POINTER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    *pointer = reinterpret_cast<void*>(vertexArray->attributes[index].pointer);
    return true;
}

// --- GL 4.1: Double-precision vertex attributes (Group 12) ---

bool GLContext::vertexAttribLPointer(GLuint index, GLint size, GLenum type, GLsizei stride, const void* pointer) {
    // GL spec: type must be GL_DOUBLE for glVertexAttribLPointer.
    if (size < 1 || size > 4 || stride < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (type != GL_DOUBLE) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    const GLuint buffer = impl_->state->boundBuffer(GL_ARRAY_BUFFER);
    if (buffer == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    auto& attribute = vertexArray->attributes[index];
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = GL_FALSE;
    attribute.stride = stride;
    attribute.pointer = reinterpret_cast<std::uintptr_t>(pointer);
    attribute.buffer = buffer;
    attribute.integer = false;
    attribute.longData = true;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::setVertexAttribLImmediate(GLuint index, GLint count, const GLdouble* values) {
    // Immediate vertex attributes are per-context state (not per-VAO).
    if (index >= impl_->kMaxImmediateDoubleAttribs) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    auto& slot = impl_->immediateDoubleAttribs[index];
    slot[0] = count >= 1 ? values[0] : 0.0;
    slot[1] = count >= 2 ? values[1] : 0.0;
    slot[2] = count >= 3 ? values[2] : 0.0;
    slot[3] = count >= 4 ? values[3] : 1.0;
    return true;
}

bool GLContext::getVertexAttribLdv(GLuint index, GLenum pname, GLdouble* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_CURRENT_VERTEX_ATTRIB) {
        // Return the stored per-context immediate double values (lossless).
        if (index >= impl_->kMaxImmediateDoubleAttribs) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        const auto& slot = impl_->immediateDoubleAttribs[index];
        params[0] = slot[0];
        params[1] = slot[1];
        params[2] = slot[2];
        params[3] = slot[3];
        return true;
    }
    // For non-CURRENT_VERTEX_ATTRIB pnames, delegate to the integer getter and widen.
    GLint values[4] = {};
    if (!getVertexAttribInteger(index, pname, values)) {
        return false;
    }
    params[0] = static_cast<GLdouble>(values[0]);
    return true;
}

bool GLContext::activeTexture(GLenum texture) {
    if (texture < GL_TEXTURE0 || texture >= GL_TEXTURE0 + 32) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    impl_->state->setActiveTextureUnit(texture - GL_TEXTURE0);
    return true;
}

bool GLContext::genTextures(GLsizei count, GLuint* textures) {
    if (count < 0 || (count > 0 && textures == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        textures[index] = impl_->objects->textures().reserveName();
    }
    return true;
}

bool GLContext::deleteTextures(GLsizei count, const GLuint* textures) {
    if (count < 0 || (count > 0 && textures == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = textures[index];
        if (name == 0) {
            continue;
        }
        if (GLTextureObject* object = impl_->objects->textures().get(name); object != nullptr) {
            impl_->releaseTextureStorage(*object);
        }
        if (impl_->objects->textures().erase(name)) {
            impl_->state->deleteTextureBindings(name);
            impl_->deleteTextureReferencesFromFramebuffers(name);
            impl_->objects->deferDelete("texture " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isTexture(GLuint texture) const {
    const GLTextureObject* object = impl_->objects->textures().get(texture);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindTexture(GLenum target, GLuint texture) {
    if (!isTextureTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (texture == 0) {
        impl_->state->bindTexture(target, 0);
        return true;
    }
    GLTextureObject* object = impl_->objects->textures().get(texture);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (object->target != 0 && object->target != target) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    object->target = target;
    object->desc.target = target;
    object->instantiated = true;
    impl_->state->bindTexture(target, texture);
    return true;
}

bool GLContext::texImage(
    GLenum target,
    GLint level,
    GLint internalformat,
    GLsizei width,
    GLsizei height,
    GLsizei depth,
    GLint border,
    GLenum format,
    GLenum type,
    const void* pixels
) {
    if (!isTextureTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (level < 0 || width < 0 || height < 0 || depth < 0 || border != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!isSupportedInternalTextureFormat(static_cast<GLenum>(internalformat)) || componentCountForFormat(format) == 0 || type != GL_UNSIGNED_BYTE) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if ((target == GL_TEXTURE_1D && (height != 1 || depth != 1))
        || (target == GL_TEXTURE_2D && depth != 1)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (object->desc.immutable) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    GLTextureImageLevel image;
    image.desc.target = target;
    image.desc.internalFormat = static_cast<GLenum>(internalformat);
    image.desc.sourceFormat = format;
    image.desc.sourceType = type;
    image.desc.width = width;
    image.desc.height = target == GL_TEXTURE_1D ? 1 : height;
    image.desc.depth = target == GL_TEXTURE_3D ? depth : 1;
    image.desc.levels = std::max<GLsizei>(object->desc.levels, level + 1);
    image.defined = true;
    if (!impl_->buildRGBA8Upload(image.desc.width, image.desc.height, image.desc.depth, format, type, pixels, image.rgba8)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    if (level == 0 || !object->levels.contains(0)) {
        object->desc = image.desc;
    }
    object->desc.levels = std::max<GLsizei>(object->desc.levels, level + 1);
    image.desc.levels = object->desc.levels;
    object->levels[level] = std::move(image);
    if (!impl_->replaceMetalTexture(*object)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::texSubImage(
    GLenum target,
    GLint level,
    GLint xoffset,
    GLint yoffset,
    GLint zoffset,
    GLsizei width,
    GLsizei height,
    GLsizei depth,
    GLenum format,
    GLenum type,
    const void* pixels
) {
    if (!isTextureTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (level < 0 || xoffset < 0 || yoffset < 0 || zoffset < 0 || width < 0 || height < 0 || depth < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (componentCountForFormat(format) == 0 || type != GL_UNSIGNED_BYTE) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (width > 0 && height > 0 && depth > 0 && pixels == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    auto levelIt = object->levels.find(level);
    if (levelIt == object->levels.end() || !levelIt->second.defined) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLTextureImageLevel& image = levelIt->second;
    if (xoffset > image.desc.width || width > image.desc.width - xoffset
        || yoffset > image.desc.height || height > image.desc.height - yoffset
        || zoffset > image.desc.depth || depth > image.desc.depth - zoffset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    std::vector<std::uint8_t> upload;
    if (!impl_->buildRGBA8Upload(width, height, depth, format, type, pixels, upload)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    for (GLsizei z = 0; z < depth; ++z) {
        for (GLsizei y = 0; y < height; ++y) {
            const std::size_t sourceOffset =
                (static_cast<std::size_t>(z) * static_cast<std::size_t>(height) + static_cast<std::size_t>(y))
                * static_cast<std::size_t>(width) * 4u;
            const std::size_t destOffset =
                ((static_cast<std::size_t>(z + zoffset) * static_cast<std::size_t>(image.desc.height)
                    + static_cast<std::size_t>(y + yoffset))
                    * static_cast<std::size_t>(image.desc.width)
                    + static_cast<std::size_t>(xoffset))
                * 4u;
            std::memcpy(
                image.rgba8.data() + destOffset,
                upload.data() + sourceOffset,
                static_cast<std::size_t>(width) * 4u
            );
        }
    }
    if (!impl_->replaceMetalTexture(*object)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::texStorage(
    GLenum target,
    GLsizei levels,
    GLenum internalformat,
    GLsizei width,
    GLsizei height,
    GLsizei depth
) {
    if (!isTextureTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (levels < 1 || width < 1 || height < 1 || depth < 1) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!isSupportedInternalTextureFormat(internalformat)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }

    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (object->desc.immutable) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    object->desc.target = target;
    object->desc.internalFormat = internalformat;
    object->desc.width = width;
    object->desc.height = (target == GL_TEXTURE_1D) ? 1 : height;
    object->desc.depth = (target == GL_TEXTURE_3D) ? depth : 1;
    object->desc.levels = levels;
    object->desc.immutable = true;
    object->target = target;

    // Pre-create level-0 image entry so replaceMetalTexture has something to work with.
    GLTextureImageLevel baseLevel;
    baseLevel.desc = object->desc;
    baseLevel.defined = true;
    const std::size_t byteCount = static_cast<std::size_t>(width) * static_cast<std::size_t>(height) * static_cast<std::size_t>(object->desc.depth) * 4u;
    baseLevel.rgba8.resize(byteCount, 0);
    object->levels[0] = std::move(baseLevel);

    if (!impl_->replaceMetalTexture(*object)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::texStorageMultisample(
    GLenum target,
    GLsizei samples,
    GLenum internalformat,
    GLsizei width,
    GLsizei height,
    GLsizei depth,
    GLboolean fixedsamplelocations
) {
    if (target != GL_TEXTURE_2D_MULTISAMPLE && target != GL_TEXTURE_2D_MULTISAMPLE_ARRAY) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (samples < 1 || width < 1 || height < 1 || depth < 1) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!isSupportedInternalTextureFormat(internalformat)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }

    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (object->desc.immutable) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    // Clamp sample count to Metal maximum (typically 4 on Apple Silicon).
    GLsizei clampedSamples = std::min<GLsizei>(samples, 4);

    object->desc.target = target;
    object->desc.internalFormat = internalformat;
    object->desc.width = width;
    object->desc.height = height;
    object->desc.depth = (target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY) ? depth : 1;
    object->desc.levels = 1;
    object->desc.samples = clampedSamples;
    object->desc.immutable = true;
    object->target = target;

    // Create a base-level entry for Metal texture creation.
    GLTextureImageLevel baseLevel;
    baseLevel.desc = object->desc;
    baseLevel.defined = true;
    const std::size_t byteCount = static_cast<std::size_t>(width) * static_cast<std::size_t>(height) * static_cast<std::size_t>(object->desc.depth) * 4u;
    baseLevel.rgba8.resize(byteCount, 0);
    object->levels[0] = std::move(baseLevel);

    if (!impl_->replaceMetalTexture(*object)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::texBufferRange(
    GLenum target,
    GLenum internalformat,
    GLuint buffer,
    GLintptr offset,
    GLsizeiptr size
) {
    if (target != GL_TEXTURE_BUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (!isSupportedInternalTextureFormat(internalformat)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (offset < 0 || size <= 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    // Record the buffer-texture binding state.
    object->desc.target = target;
    object->desc.internalFormat = internalformat;
    object->desc.sourceBuffer = buffer;
    object->desc.bufferOffset = offset;
    object->desc.bufferSize = size;
    object->desc.immutable = true;
    object->target = target;

    // Metal texture-buffer creation would go here; for now we record the state
    // so higher-level code can query and create the MTLTextureBuffer view later.
    return true;
}

bool GLContext::texParameterInteger(GLenum target, GLenum pname, const GLint* params) {
    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!setTextureParameterInteger(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::texParameterUnsignedInteger(GLenum target, GLenum pname, const GLuint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLint converted[4] = {
        static_cast<GLint>(params[0]),
        0,
        0,
        0
    };
    if (pname == GL_TEXTURE_BORDER_COLOR || pname == GL_TEXTURE_SWIZZLE_RGBA) {
        converted[1] = static_cast<GLint>(params[1]);
        converted[2] = static_cast<GLint>(params[2]);
        converted[3] = static_cast<GLint>(params[3]);
    }
    return texParameterInteger(target, pname, converted);
}

bool GLContext::texParameterFloat(GLenum target, GLenum pname, const GLfloat* params) {
    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!setTextureParameterFloat(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::getTexParameterInteger(GLenum target, GLenum pname, GLint* params) {
    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!getTextureParameterInteger(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::getTexParameterUnsignedInteger(GLenum target, GLenum pname, GLuint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLint values[4] = {};
    if (!getTexParameterInteger(target, pname, values)) {
        return false;
    }
    params[0] = static_cast<GLuint>(values[0]);
    if (pname == GL_TEXTURE_BORDER_COLOR || pname == GL_TEXTURE_SWIZZLE_RGBA) {
        params[1] = static_cast<GLuint>(values[1]);
        params[2] = static_cast<GLuint>(values[2]);
        params[3] = static_cast<GLuint>(values[3]);
    }
    return true;
}

bool GLContext::getTexParameterFloat(GLenum target, GLenum pname, GLfloat* params) {
    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!getTextureParameterFloat(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::generateMipmap(GLenum target) {
    if (!isTextureTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!impl_->generateMipmaps(*object)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    return true;
}

bool GLContext::pixelStore(GLenum pname, GLint value) {
    impl_->state->setPixelStore(pname, value);
    return true;
}

bool GLContext::genRenderbuffers(GLsizei count, GLuint* renderbuffers) {
    if (count < 0 || (count > 0 && renderbuffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        renderbuffers[index] = impl_->objects->renderbuffers().reserveName();
    }
    return true;
}

bool GLContext::deleteRenderbuffers(GLsizei count, const GLuint* renderbuffers) {
    if (count < 0 || (count > 0 && renderbuffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = renderbuffers[index];
        if (name == 0) {
            continue;
        }
        if (GLRenderbufferObject* object = impl_->objects->renderbuffers().get(name); object != nullptr) {
            impl_->releaseRenderbufferStorage(*object);
        }
        if (impl_->objects->renderbuffers().erase(name)) {
            impl_->state->deleteRenderbufferBinding(name);
            impl_->deleteRenderbufferReferencesFromFramebuffers(name);
            impl_->objects->deferDelete("renderbuffer " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isRenderbuffer(GLuint renderbuffer) const {
    const GLRenderbufferObject* object = impl_->objects->renderbuffers().get(renderbuffer);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindRenderbuffer(GLenum target, GLuint renderbuffer) {
    if (target != GL_RENDERBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (renderbuffer != 0) {
        GLRenderbufferObject* object = impl_->objects->renderbuffers().get(renderbuffer);
        if (object == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        object->instantiated = true;
    }
    impl_->state->bindRenderbuffer(renderbuffer);
    return true;
}

bool GLContext::renderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height, GLsizei samples) {
    if (target != GL_RENDERBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (width < 0 || height < 0 || samples < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!isSupportedRenderbufferFormat(internalformat)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const GLuint name = impl_->state->boundRenderbuffer();
    GLRenderbufferObject* object = impl_->objects->renderbuffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!impl_->replaceRenderbufferStorage(*object, internalformat, width, height, samples)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::getRenderbufferParameterInteger(GLenum target, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (target != GL_RENDERBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const GLuint name = impl_->state->boundRenderbuffer();
    const GLRenderbufferObject* object = impl_->objects->renderbuffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    const auto componentSize = [&](GLenum component) -> GLint {
        if (!object->storageDefined) {
            return 0;
        }
        switch (component) {
            case GL_RED:
            case GL_GREEN:
            case GL_BLUE:
                return isColorFormat(object->internalFormat) ? 8 : 0;
            case GL_ALPHA:
                return object->internalFormat == GL_RGBA || object->internalFormat == GL_RGBA8 ? 8 : 0;
            case GL_DEPTH:
                if (object->internalFormat == GL_DEPTH_COMPONENT16) {
                    return 16;
                }
                if (object->internalFormat == GL_DEPTH_COMPONENT24 || object->internalFormat == GL_DEPTH24_STENCIL8) {
                    return 24;
                }
                return isDepthFormat(object->internalFormat) ? 32 : 0;
            case GL_STENCIL:
                return isStencilFormat(object->internalFormat) ? 8 : 0;
            default:
                return 0;
        }
    };

    switch (pname) {
        case GL_RENDERBUFFER_WIDTH:
            params[0] = object->width;
            return true;
        case GL_RENDERBUFFER_HEIGHT:
            params[0] = object->height;
            return true;
        case GL_RENDERBUFFER_INTERNAL_FORMAT:
            params[0] = static_cast<GLint>(object->internalFormat);
            return true;
        case GL_RENDERBUFFER_RED_SIZE:
            params[0] = componentSize(GL_RED);
            return true;
        case GL_RENDERBUFFER_GREEN_SIZE:
            params[0] = componentSize(GL_GREEN);
            return true;
        case GL_RENDERBUFFER_BLUE_SIZE:
            params[0] = componentSize(GL_BLUE);
            return true;
        case GL_RENDERBUFFER_ALPHA_SIZE:
            params[0] = componentSize(GL_ALPHA);
            return true;
        case GL_RENDERBUFFER_DEPTH_SIZE:
            params[0] = componentSize(GL_DEPTH);
            return true;
        case GL_RENDERBUFFER_STENCIL_SIZE:
            params[0] = componentSize(GL_STENCIL);
            return true;
        case GL_RENDERBUFFER_SAMPLES:
            params[0] = object->samples;
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::genFramebuffers(GLsizei count, GLuint* framebuffers) {
    if (count < 0 || (count > 0 && framebuffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        framebuffers[index] = impl_->objects->framebuffers().reserveName();
    }
    return true;
}

bool GLContext::deleteFramebuffers(GLsizei count, const GLuint* framebuffers) {
    if (count < 0 || (count > 0 && framebuffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = framebuffers[index];
        if (name == 0) {
            continue;
        }
        if (impl_->objects->framebuffers().erase(name)) {
            impl_->state->deleteFramebufferBindings(name);
            impl_->objects->deferDelete("framebuffer " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isFramebuffer(GLuint framebuffer) const {
    const GLFramebufferObject* object = impl_->objects->framebuffers().get(framebuffer);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindFramebuffer(GLenum target, GLuint framebuffer) {
    if (target != GL_FRAMEBUFFER && target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (framebuffer != 0) {
        GLFramebufferObject* object = impl_->objects->framebuffers().get(framebuffer);
        if (object == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        object->instantiated = true;
    }
    if (target == GL_FRAMEBUFFER || target == GL_DRAW_FRAMEBUFFER) {
        impl_->state->bindDrawFramebuffer(framebuffer);
    }
    if (target == GL_FRAMEBUFFER || target == GL_READ_FRAMEBUFFER) {
        impl_->state->bindReadFramebuffer(framebuffer);
    }
    return true;
}

GLenum GLContext::checkFramebufferStatus(GLenum target) const {
    if (target != GL_FRAMEBUFFER && target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
        return 0;
    }
    const GLuint name = target == GL_READ_FRAMEBUFFER
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    if (name == 0) {
        return impl_->frameGraph != nullptr && impl_->frameGraph->hasValidAttachments()
            ? GL_FRAMEBUFFER_COMPLETE
            : GL_FRAMEBUFFER_UNDEFINED;
    }
    const GLFramebufferObject* object = impl_->objects->framebuffers().get(name);
    if (object == nullptr || !object->instantiated) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_OPERATION);
        return 0;
    }
    return impl_->framebufferStatus(*object);
}

bool GLContext::framebufferTexture(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level, GLint layer, bool layered) {
    if (target != GL_FRAMEBUFFER && target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (!isFramebufferAttachment(attachment) || (textarget != 0 && !isTextureTarget(textarget))) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (level < 0 || layer < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint framebufferName = target == GL_READ_FRAMEBUFFER
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebufferName == 0 || framebuffer == nullptr || !framebuffer->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    if (texture == 0) {
        framebuffer->attachments.erase(attachment);
        return true;
    }

    const GLTextureObject* textureObject = impl_->objects->textures().get(texture);
    if (textureObject == nullptr || !textureObject->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (textarget != 0 && textureObject->target != textarget) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Spec: GL_INVALID_VALUE if level is greater than the texture's effective max level.
    // Immutable textures pin a hard ceiling at desc.levels - 1; mutable textures fall back
    // on the highest defined level via desc.levels (initialized to 1 by texImage).
    {
        const GLsizei maxLevel = std::max<GLsizei>(textureObject->desc.levels, 1);
        if (level >= maxLevel) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    // Spec: GL_INVALID_VALUE if layer is outside the texture's array/depth range.
    // Only validate for layered targets — 1D/2D ignore the layer parameter.
    if (!layered) {
        const bool isLayered =
            textureObject->target == GL_TEXTURE_3D ||
            textureObject->target == GL_TEXTURE_2D_ARRAY ||
            textureObject->target == GL_TEXTURE_1D_ARRAY ||
            textureObject->target == GL_TEXTURE_CUBE_MAP_ARRAY ||
            textureObject->target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY;
        if (isLayered) {
            const GLsizei maxLayer = textureObject->target == GL_TEXTURE_3D
                ? std::max<GLsizei>(textureObject->desc.depth, 1)
                : std::max<GLsizei>(textureObject->desc.layers, 1);
            if (layer >= maxLayer) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
        }
    }
    if (attachment == GL_DEPTH_ATTACHMENT && !isDepthFormat(textureObject->desc.internalFormat)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (attachment == GL_STENCIL_ATTACHMENT && !isStencilFormat(textureObject->desc.internalFormat)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (isColorAttachment(attachment) && !isColorFormat(textureObject->desc.internalFormat)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    GLFramebufferAttachment stored;
    stored.kind = GLFramebufferAttachment::Kind::Texture;
    stored.object = texture;
    stored.level = level;
    stored.layer = layer;
    stored.textureTarget = textarget == 0 ? textureObject->target : textarget;
    stored.layered = layered;
    framebuffer->attachments[attachment] = stored;
    return true;
}

bool GLContext::framebufferRenderbuffer(GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer) {
    if (target != GL_FRAMEBUFFER && target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (!isFramebufferAttachment(attachment) || renderbuffertarget != GL_RENDERBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const GLuint framebufferName = target == GL_READ_FRAMEBUFFER
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebufferName == 0 || framebuffer == nullptr || !framebuffer->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    if (renderbuffer == 0) {
        framebuffer->attachments.erase(attachment);
        return true;
    }

    const GLRenderbufferObject* renderbufferObject = impl_->objects->renderbuffers().get(renderbuffer);
    if (renderbufferObject == nullptr || !renderbufferObject->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (attachment == GL_DEPTH_ATTACHMENT && renderbufferObject->storageDefined && !isDepthFormat(renderbufferObject->internalFormat)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (attachment == GL_STENCIL_ATTACHMENT && renderbufferObject->storageDefined && !isStencilFormat(renderbufferObject->internalFormat)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (isColorAttachment(attachment) && renderbufferObject->storageDefined && !isColorFormat(renderbufferObject->internalFormat)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    GLFramebufferAttachment stored;
    stored.kind = GLFramebufferAttachment::Kind::Renderbuffer;
    stored.object = renderbuffer;
    framebuffer->attachments[attachment] = stored;
    return true;
}

bool GLContext::blitFramebuffer(GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1, GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1, GLbitfield mask, GLenum filter) {
    if (filter != GL_NEAREST && filter != GL_LINEAR) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const GLbitfield kSupportedMask = GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT;
    if ((mask & ~kSupportedMask) != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!impl_->blitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    return true;
}

bool GLContext::getFramebufferAttachmentParameterInteger(GLenum target, GLenum attachment, GLenum pname, GLint* params) const {
    if (params == nullptr) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_VALUE);
        return false;
    }
    if (target != GL_FRAMEBUFFER && target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
        return false;
    }
    if (!isFramebufferAttachment(attachment)) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
        return false;
    }

    const GLuint framebufferName = target == GL_READ_FRAMEBUFFER
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    if (framebufferName == 0) {
        switch (pname) {
            case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE:
                params[0] = GL_FRAMEBUFFER_DEFAULT;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME:
            case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL:
            case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER:
                params[0] = 0;
                return true;
            default:
                const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
                return false;
        }
    }

    const GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebuffer == nullptr || !framebuffer->instantiated) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_OPERATION);
        return false;
    }
    const auto found = framebuffer->attachments.find(attachment);
    const GLFramebufferAttachment attachmentState = found == framebuffer->attachments.end() ? GLFramebufferAttachment{} : found->second;
    const auto attachmentInfo = impl_->framebufferAttachmentInfo(attachmentState);

    switch (pname) {
        case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE:
            params[0] = attachmentState.kind == GLFramebufferAttachment::Kind::Texture
                ? GL_TEXTURE
                : (attachmentState.kind == GLFramebufferAttachment::Kind::Renderbuffer ? GL_RENDERBUFFER : GL_NONE);
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME:
            params[0] = static_cast<GLint>(attachmentState.object);
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL:
            params[0] = attachmentState.kind == GLFramebufferAttachment::Kind::Texture ? attachmentState.level : 0;
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER:
            params[0] = attachmentState.kind == GLFramebufferAttachment::Kind::Texture ? attachmentState.layer : 0;
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_LAYERED:
            params[0] = attachmentState.layered ? GL_TRUE : GL_FALSE;
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE:
            params[0] = attachmentInfo.complete && isColorFormat(attachmentInfo.internalFormat) ? 8 : 0;
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_GREEN_SIZE:
            params[0] = attachmentInfo.complete && isColorFormat(attachmentInfo.internalFormat) ? 8 : 0;
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_BLUE_SIZE:
            params[0] = attachmentInfo.complete && isColorFormat(attachmentInfo.internalFormat) ? 8 : 0;
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE:
            params[0] = attachmentInfo.complete && (attachmentInfo.internalFormat == GL_RGBA || attachmentInfo.internalFormat == GL_RGBA8) ? 8 : 0;
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE:
            params[0] = attachmentInfo.complete && isDepthFormat(attachmentInfo.internalFormat) ? 24 : 0;
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE:
            params[0] = attachmentInfo.complete && isStencilFormat(attachmentInfo.internalFormat) ? 8 : 0;
            return true;
        default:
            const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::drawBuffer(GLenum buffer) {
    return drawBuffers(1, &buffer);
}

bool GLContext::drawBuffers(GLsizei count, const GLenum* buffers) {
    if (count < 0 || count > 8 || (count > 0 && buffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint framebufferName = impl_->state->boundDrawFramebuffer();
    if (framebufferName == 0) {
        for (GLsizei index = 0; index < count; ++index) {
            if (!isDefaultFramebufferBuffer(buffers[index])) {
                pushError(GL_INVALID_ENUM);
                return false;
            }
        }
        return impl_->state->setDrawBuffers(count, buffers);
    }

    GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebuffer == nullptr || !framebuffer->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    framebuffer->drawBuffers.fill(GL_NONE);
    for (GLsizei index = 0; index < count; ++index) {
        if (buffers[index] != GL_NONE && !isFramebufferColorBuffer(buffers[index])) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        framebuffer->drawBuffers[static_cast<std::size_t>(index)] = buffers[index];
    }
    return true;
}

bool GLContext::readBuffer(GLenum buffer) {
    const GLuint framebufferName = impl_->state->boundReadFramebuffer();
    if (framebufferName == 0) {
        if (!isDefaultFramebufferBuffer(buffer)) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        return impl_->state->setReadBuffer(buffer);
    }

    GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebuffer == nullptr || !framebuffer->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (buffer != GL_NONE && !isFramebufferColorBuffer(buffer)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    framebuffer->readBuffer = buffer;
    return true;
}

bool GLContext::genSamplers(GLsizei count, GLuint* samplers) {
    if (count < 0 || (count > 0 && samplers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = impl_->objects->samplers().reserveName();
        samplers[index] = name;
        if (GLSamplerObject* object = impl_->objects->samplers().get(name); object != nullptr) {
            object->instantiated = true;
            (void)impl_->rebuildSamplerState(*object);
        }
    }
    return true;
}

bool GLContext::deleteSamplers(GLsizei count, const GLuint* samplers) {
    if (count < 0 || (count > 0 && samplers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = samplers[index];
        if (name == 0) {
            continue;
        }
        if (GLSamplerObject* object = impl_->objects->samplers().get(name); object != nullptr) {
            impl_->releaseSamplerState(*object);
        }
        if (impl_->objects->samplers().erase(name)) {
            impl_->state->deleteSamplerBindings(name);
            impl_->objects->deferDelete("sampler " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isSampler(GLuint sampler) const {
    const GLSamplerObject* object = impl_->objects->samplers().get(sampler);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindSampler(GLuint unit, GLuint sampler) {
    if (unit >= 32) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (sampler != 0 && !isSampler(sampler)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    impl_->state->bindSampler(unit, sampler);
    return true;
}

bool GLContext::samplerParameterInteger(GLuint sampler, GLenum pname, const GLint* params) {
    GLSamplerObject* object = impl_->objects->samplers().get(sampler);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!setTextureParameterInteger(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    object->dirty = true;
    if (!impl_->rebuildSamplerState(*object)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::samplerParameterUnsignedInteger(GLuint sampler, GLenum pname, const GLuint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLint converted[4] = {
        static_cast<GLint>(params[0]),
        0,
        0,
        0
    };
    if (pname == GL_TEXTURE_BORDER_COLOR || pname == GL_TEXTURE_SWIZZLE_RGBA) {
        converted[1] = static_cast<GLint>(params[1]);
        converted[2] = static_cast<GLint>(params[2]);
        converted[3] = static_cast<GLint>(params[3]);
    }
    return samplerParameterInteger(sampler, pname, converted);
}

bool GLContext::samplerParameterFloat(GLuint sampler, GLenum pname, const GLfloat* params) {
    GLSamplerObject* object = impl_->objects->samplers().get(sampler);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!setTextureParameterFloat(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    object->dirty = true;
    if (!impl_->rebuildSamplerState(*object)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::getSamplerParameterInteger(GLuint sampler, GLenum pname, GLint* params) {
    const GLSamplerObject* object = impl_->objects->samplers().get(sampler);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!getTextureParameterInteger(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::getSamplerParameterUnsignedInteger(GLuint sampler, GLenum pname, GLuint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLint values[4] = {};
    if (!getSamplerParameterInteger(sampler, pname, values)) {
        return false;
    }
    params[0] = static_cast<GLuint>(values[0]);
    if (pname == GL_TEXTURE_BORDER_COLOR || pname == GL_TEXTURE_SWIZZLE_RGBA) {
        params[1] = static_cast<GLuint>(values[1]);
        params[2] = static_cast<GLuint>(values[2]);
        params[3] = static_cast<GLuint>(values[3]);
    }
    return true;
}

bool GLContext::getSamplerParameterFloat(GLuint sampler, GLenum pname, GLfloat* params) {
    const GLSamplerObject* object = impl_->objects->samplers().get(sampler);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!getTextureParameterFloat(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    return true;
}

void GLContext::pushError(GLenum error) {
    impl_->errors.push_back(error);
}

GLenum GLContext::popError() {
    if (impl_->errors.empty()) {
        return GL_NO_ERROR;
    }
    const GLenum error = impl_->errors.front();
    impl_->errors.pop_front();
    return error;
}

const GLubyte* GLContext::getString(GLenum name) {
    switch (name) {
        case GL_VENDOR:
            return reinterpret_cast<const GLubyte*>(impl_->vendorString.c_str());
        case GL_RENDERER:
            return reinterpret_cast<const GLubyte*>(impl_->rendererString.c_str());
        case GL_VERSION:
            return reinterpret_cast<const GLubyte*>(impl_->versionString.c_str());
        case GL_SHADING_LANGUAGE_VERSION:
            return reinterpret_cast<const GLubyte*>(impl_->shadingLanguageVersion.c_str());
        case GL_EXTENSIONS:
            return reinterpret_cast<const GLubyte*>(impl_->extensionsString.c_str());
        default:
            pushError(GL_INVALID_ENUM);
            return nullptr;
    }
}

const std::string& GLContext::rendererString() const {
    return impl_->rendererString;
}

void GLContext::setClaimedVersionString(std::string value) {
    impl_->versionString = value.empty() ? "3.0 AppGL bootstrap" : std::move(value);
}

GLCapabilities& GLContext::capabilities() {
    return *impl_->capabilities;
}

GLObjectStore& GLContext::objects() {
    return *impl_->objects;
}

GLStateTracker& GLContext::state() {
    return *impl_->state;
}

// ============================================================================
// Phase A Group 6 — Shaders and Programs
// ============================================================================

namespace {

bool isValidShaderStage(GLenum stage) {
    switch (stage) {
        case GL_VERTEX_SHADER:
        case GL_FRAGMENT_SHADER:
        case GL_GEOMETRY_SHADER:
        case GL_TESS_CONTROL_SHADER:
        case GL_TESS_EVALUATION_SHADER:
        case GL_COMPUTE_SHADER:
            return true;
        default:
            return false;
    }
}

void copyStringToBuffer(const std::string& source, GLsizei bufSize, GLsizei* length, GLchar* dest) {
    if (dest == nullptr || bufSize <= 0) {
        if (length != nullptr) {
            *length = 0;
        }
        return;
    }
    const GLsizei copyLen = std::min<GLsizei>(static_cast<GLsizei>(source.size()), bufSize - 1);
    std::memcpy(dest, source.data(), static_cast<std::size_t>(copyLen));
    dest[copyLen] = '\0';
    if (length != nullptr) {
        *length = copyLen;
    }
}

void appendDeclarationsAsUniforms(
    std::vector<GLProgramUniformInfo>& out,
    const std::vector<GLShaderDeclaration>& decls
) {
    for (const auto& decl : decls) {
        const auto existing = std::find_if(out.begin(), out.end(),
            [&](const GLProgramUniformInfo& u) { return u.name == decl.name; });
        if (existing != out.end()) {
            continue;
        }
        GLProgramUniformInfo info;
        info.name = decl.name;
        info.type = decl.type;
        info.arraySize = decl.arraySize > 0 ? decl.arraySize : 1;
        info.location = -1;  // assigned below
        out.push_back(std::move(info));
    }
}

}  // namespace

GLuint GLContext::createShader(GLenum stage) {
    if (!isValidShaderStage(stage)) {
        pushError(GL_INVALID_ENUM);
        return 0;
    }
    const GLuint id = impl_->objects->shaders().create();
    GLShaderObject* shader = impl_->objects->shaders().get(id);
    shader->stage = stage;
    return id;
}

bool GLContext::deleteShader(GLuint shader) {
    if (shader == 0) {
        return true;
    }
    GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL allows the name to remain valid until detached from all programs.
    // Phase A's gauntlet flow always detaches before deleting, so we just remove.
    object->deleteRequested = true;
    impl_->objects->shaders().erase(shader);
    return true;
}

bool GLContext::isShader(GLuint shader) const {
    return impl_->objects->shaders().contains(shader);
}

bool GLContext::shaderSource(GLuint shader, GLsizei count, const GLchar* const* strings, const GLint* length) {
    GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    std::string concatenated;
    for (GLsizei i = 0; i < count; ++i) {
        if (strings == nullptr || strings[i] == nullptr) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (length != nullptr && length[i] >= 0) {
            concatenated.append(strings[i], static_cast<std::size_t>(length[i]));
        } else {
            concatenated.append(strings[i]);
        }
    }
    object->source = std::move(concatenated);
    object->compiled = false;
    object->compileLog.clear();
    object->declaredUniforms.clear();
    object->declaredInputs.clear();
    object->declaredOutputs.clear();
    return true;
}

bool GLContext::compileShader(GLuint shader) {
    GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLSLReflectionResult reflection = reflectGLSL(object->source, object->stage);
    object->declaredUniforms = std::move(reflection.uniforms);
    object->declaredInputs = std::move(reflection.inputs);
    object->declaredOutputs = std::move(reflection.outputs);
    object->compiled = reflection.ok;
    object->compileLog = reflection.log;
    if (object->source.empty()) {
        object->compiled = false;
        object->compileLog = "shader source is empty";
    }
    return object->compiled;
}

bool GLContext::getShaderiv(GLuint shader, GLenum pname, GLint* params) {
    GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr || params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    switch (pname) {
        case GL_SHADER_TYPE:
            *params = static_cast<GLint>(object->stage);
            return true;
        case GL_DELETE_STATUS:
            *params = object->deleteRequested ? GL_TRUE : GL_FALSE;
            return true;
        case GL_COMPILE_STATUS:
            *params = object->compiled ? GL_TRUE : GL_FALSE;
            return true;
        case GL_INFO_LOG_LENGTH:
            *params = static_cast<GLint>(object->compileLog.size() + (object->compileLog.empty() ? 0 : 1));
            return true;
        case GL_SHADER_SOURCE_LENGTH:
            *params = static_cast<GLint>(object->source.size() + (object->source.empty() ? 0 : 1));
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* infoLog) {
    GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    copyStringToBuffer(object->compileLog, bufSize, length, infoLog);
    return true;
}

bool GLContext::getShaderSource(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* source) {
    GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    copyStringToBuffer(object->source, bufSize, length, source);
    return true;
}

GLuint GLContext::createProgram() {
    return impl_->objects->programs().create();
}

bool GLContext::deleteProgram(GLuint program) {
    if (program == 0) {
        return true;
    }
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    object->deleteRequested = true;
    if (impl_->state->currentProgram() == program) {
        impl_->state->useProgram(0);
    }
    impl_->objects->programs().erase(program);
    return true;
}

bool GLContext::isProgram(GLuint program) const {
    return impl_->objects->programs().contains(program);
}

bool GLContext::attachShader(GLuint program, GLuint shader) {
    GLProgramObject* programObject = impl_->objects->programs().get(program);
    GLShaderObject* shaderObject = impl_->objects->shaders().get(shader);
    if (programObject == nullptr || shaderObject == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (std::find(programObject->attachedShaders.begin(), programObject->attachedShaders.end(), shader) !=
        programObject->attachedShaders.end()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    programObject->attachedShaders.push_back(shader);
    return true;
}

bool GLContext::detachShader(GLuint program, GLuint shader) {
    GLProgramObject* programObject = impl_->objects->programs().get(program);
    if (programObject == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    auto it = std::find(programObject->attachedShaders.begin(), programObject->attachedShaders.end(), shader);
    if (it == programObject->attachedShaders.end()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    programObject->attachedShaders.erase(it);
    return true;
}

bool GLContext::linkProgram(GLuint program) {
    GLProgramObject* programObject = impl_->objects->programs().get(program);
    if (programObject == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    programObject->uniforms.clear();
    programObject->attributes.clear();
    programObject->uniformValues.clear();
    programObject->linkLog.clear();
    programObject->linked = false;

    if (programObject->attachedShaders.empty()) {
        programObject->linkLog = "no shaders attached";
        return false;
    }

    bool sawVertex = false;
    bool sawFragment = false;
    GLuint nextAttribLocation = 0;

    for (GLuint shaderId : programObject->attachedShaders) {
        GLShaderObject* shaderObject = impl_->objects->shaders().get(shaderId);
        if (shaderObject == nullptr || !shaderObject->compiled) {
            programObject->linkLog = "attached shader is not compiled";
            return false;
        }
        if (shaderObject->stage == GL_VERTEX_SHADER) {
            sawVertex = true;
            for (const auto& input : shaderObject->declaredInputs) {
                GLProgramAttributeInfo attrib;
                attrib.name = input.name;
                attrib.type = input.type;
                if (input.explicitLocation >= 0) {
                    attrib.location = input.explicitLocation;
                } else {
                    auto requested = programObject->requestedAttribLocations.find(input.name);
                    if (requested != programObject->requestedAttribLocations.end()) {
                        attrib.location = static_cast<GLint>(requested->second);
                    } else {
                        attrib.location = static_cast<GLint>(nextAttribLocation++);
                    }
                }
                if (static_cast<GLuint>(attrib.location) >= nextAttribLocation) {
                    nextAttribLocation = static_cast<GLuint>(attrib.location) + 1;
                }
                programObject->attributes.push_back(std::move(attrib));
            }
        }
        if (shaderObject->stage == GL_FRAGMENT_SHADER) {
            sawFragment = true;
        }
        appendDeclarationsAsUniforms(programObject->uniforms, shaderObject->declaredUniforms);
    }

    if (!sawVertex || !sawFragment) {
        programObject->linkLog = "program requires both vertex and fragment shaders";
        return false;
    }

    // Assign sequential dense uniform locations and seed default values.
    GLint nextLocation = 0;
    for (auto& uniform : programObject->uniforms) {
        uniform.location = nextLocation;
        const GLint components = glslComponentCount(uniform.type) * std::max<GLint>(uniform.arraySize, 1);
        GLProgramUniformValue value;
        value.type = uniform.type;
        value.arraySize = uniform.arraySize;
        switch (uniform.type) {
            case GL_INT:
            case GL_INT_VEC2:
            case GL_INT_VEC3:
            case GL_INT_VEC4:
            case GL_BOOL:
            case GL_BOOL_VEC2:
            case GL_BOOL_VEC3:
            case GL_BOOL_VEC4:
            case GL_SAMPLER_1D:
            case GL_SAMPLER_2D:
            case GL_SAMPLER_3D:
            case GL_SAMPLER_CUBE:
            case GL_SAMPLER_2D_ARRAY:
            case GL_SAMPLER_2D_SHADOW:
                value.ints.assign(static_cast<std::size_t>(components), 0);
                break;
            case GL_UNSIGNED_INT:
            case GL_UNSIGNED_INT_VEC2:
            case GL_UNSIGNED_INT_VEC3:
            case GL_UNSIGNED_INT_VEC4:
                value.uints.assign(static_cast<std::size_t>(components), 0u);
                break;
            default:
                value.floats.assign(static_cast<std::size_t>(components), 0.0f);
                break;
        }
        programObject->uniformValues[nextLocation] = std::move(value);
        nextLocation += std::max<GLint>(uniform.arraySize, 1);
    }

    programObject->linked = true;
    programObject->linkLog = "ok";

    // Populate GL 4.3 program resource introspection tables from the
    // reflection data we already gathered above.
    programObject->resourceUniforms.clear();
    programObject->resourceUniformBlocks.clear();
    programObject->resourceInputs.clear();
    programObject->resourceOutputs.clear();
    programObject->resourceStorageBlocks.clear();
    programObject->resourceAtomicCounterBuffers.clear();
    programObject->resourceBufferVariables.clear();
    programObject->ssboBindingRemap.clear();

    for (const auto& u : programObject->uniforms) {
        GLProgramResourceEntry entry;
        entry.name = u.name;
        entry.type = u.type;
        entry.location = u.location;
        entry.arraySize = u.arraySize;
        entry.referencedBy = 0x03; // vertex + fragment (conservative)
        programObject->resourceUniforms.push_back(std::move(entry));
    }
    for (const auto& a : programObject->attributes) {
        GLProgramResourceEntry entry;
        entry.name = a.name;
        entry.type = a.type;
        entry.location = a.location;
        entry.referencedBy = 0x01; // vertex
        programObject->resourceInputs.push_back(std::move(entry));
    }
    // Fragment outputs: populate from fragment shader declared outputs.
    for (GLuint shaderId : programObject->attachedShaders) {
        GLShaderObject* shaderObject = impl_->objects->shaders().get(shaderId);
        if (shaderObject == nullptr) continue;
        if (shaderObject->stage == GL_FRAGMENT_SHADER) {
            GLint nextOutputLoc = 0;
            for (const auto& output : shaderObject->declaredOutputs) {
                GLProgramResourceEntry entry;
                entry.name = output.name;
                entry.type = output.type;
                entry.location = (output.explicitLocation >= 0) ? output.explicitLocation : nextOutputLoc;
                entry.arraySize = output.arraySize;
                entry.referencedBy = 0x02; // fragment
                if (entry.location >= nextOutputLoc) {
                    nextOutputLoc = entry.location + 1;
                }
                programObject->resourceOutputs.push_back(std::move(entry));
            }
        }
    }

    // Attempt GLSL→SPIR-V→MSL translation for the GPU pipeline. This is
    // best-effort: if it fails the program still links and falls back to the
    // hardcoded solid-color draw path.
    programObject->hasTranslatedPipeline = false;
    programObject->vertexMSL.clear();
    programObject->fragmentMSL.clear();
    programObject->metalPipelineState = nullptr;

    {
        ShaderTranslator translator;
        BindingMap bindings;
        std::string vertexSource, fragmentSource;
        GLenum vertexStage = 0, fragmentStage = 0;

        for (GLuint shaderId : programObject->attachedShaders) {
            GLShaderObject* shaderObject = impl_->objects->shaders().get(shaderId);
            if (shaderObject == nullptr) continue;
            if (shaderObject->stage == GL_VERTEX_SHADER) {
                vertexSource = shaderObject->source;
                vertexStage = shaderObject->stage;
            } else if (shaderObject->stage == GL_FRAGMENT_SHADER) {
                fragmentSource = shaderObject->source;
                fragmentStage = shaderObject->stage;
            }
        }

        if (!vertexSource.empty() && !fragmentSource.empty()) {
            std::string compileLog;
            auto vertexSPIRV = translator.compileGLSL(vertexSource, vertexStage, 330, &compileLog);
            NSLog(@"[GL] linkProgram: vertex SPIRV %s (%zu words) log: %s",
                  vertexSPIRV.empty() ? "FAILED" : "ok", vertexSPIRV.size(), compileLog.c_str());
            auto fragmentSPIRV = translator.compileGLSL(fragmentSource, fragmentStage, 330, &compileLog);
            NSLog(@"[GL] linkProgram: fragment SPIRV %s (%zu words) log: %s",
                  fragmentSPIRV.empty() ? "FAILED" : "ok", fragmentSPIRV.size(), compileLog.c_str());

            if (!vertexSPIRV.empty() && !fragmentSPIRV.empty()) {
                std::string mslLog;
                std::string vertMSL = translator.spirvToMSL(vertexSPIRV.data(), vertexSPIRV.size(), bindings, &mslLog);
                NSLog(@"[GL] linkProgram: vertex MSL %s (%zu chars) log: %s",
                      vertMSL.empty() ? "FAILED" : "ok", vertMSL.size(), mslLog.c_str());
                std::string fragMSL = translator.spirvToMSL(fragmentSPIRV.data(), fragmentSPIRV.size(), bindings, &mslLog);
                NSLog(@"[GL] linkProgram: fragment MSL %s (%zu chars) log: %s",
                      fragMSL.empty() ? "FAILED" : "ok", fragMSL.size(), mslLog.c_str());

                if (!vertMSL.empty() && !fragMSL.empty()) {
                    programObject->vertexMSL = std::move(vertMSL);
                    programObject->fragmentMSL = std::move(fragMSL);

                    // Reflect vertex stage for attribute layout.
                    programObject->vertexReflection = translator.reflect(
                        vertexSPIRV.data(), vertexSPIRV.size(), bindings, nullptr);
                    programObject->fragmentReflection = translator.reflect(
                        fragmentSPIRV.data(), fragmentSPIRV.size(), bindings, nullptr);
                    programObject->hasTranslatedPipeline = true;
                    NSLog(@"[GL] linkProgram: *** TRANSLATION SUCCEEDED *** vertexInputs=%zu uniformBlocks=%zu",
                          programObject->vertexReflection.vertexInputs.size(),
                          programObject->vertexReflection.uniformBlocks.size());
                }
            }
        }
    }

    return true;
}

bool GLContext::useProgram(GLuint program) {
    if (program != 0) {
        GLProgramObject* object = impl_->objects->programs().get(program);
        if (object == nullptr) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (!object->linked) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    impl_->state->useProgram(program);
    return true;
}

bool GLContext::validateProgram(GLuint program) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    object->validated = object->linked;
    object->validateLog = object->linked ? "validation passed" : "program is not linked";
    return object->validated;
}

bool GLContext::getProgramiv(GLuint program, GLenum pname, GLint* params) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    switch (pname) {
        case GL_DELETE_STATUS:
            *params = object->deleteRequested ? GL_TRUE : GL_FALSE;
            return true;
        case GL_LINK_STATUS:
            *params = object->linked ? GL_TRUE : GL_FALSE;
            return true;
        case GL_VALIDATE_STATUS:
            *params = object->validated ? GL_TRUE : GL_FALSE;
            return true;
        case GL_INFO_LOG_LENGTH: {
            const std::string& log = object->validateLog.empty() ? object->linkLog : object->validateLog;
            *params = static_cast<GLint>(log.size() + (log.empty() ? 0 : 1));
            return true;
        }
        case GL_ATTACHED_SHADERS:
            *params = static_cast<GLint>(object->attachedShaders.size());
            return true;
        case GL_ACTIVE_UNIFORMS:
            *params = static_cast<GLint>(object->uniforms.size());
            return true;
        case GL_ACTIVE_UNIFORM_MAX_LENGTH: {
            std::size_t maxLen = 0;
            for (const auto& u : object->uniforms) {
                maxLen = std::max(maxLen, u.name.size() + 1);
            }
            *params = static_cast<GLint>(maxLen);
            return true;
        }
        case GL_ACTIVE_ATTRIBUTES:
            *params = static_cast<GLint>(object->attributes.size());
            return true;
        case GL_ACTIVE_ATTRIBUTE_MAX_LENGTH: {
            std::size_t maxLen = 0;
            for (const auto& a : object->attributes) {
                maxLen = std::max(maxLen, a.name.size() + 1);
            }
            *params = static_cast<GLint>(maxLen);
            return true;
        }
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getProgramInfoLog(GLuint program, GLsizei bufSize, GLsizei* length, GLchar* infoLog) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const std::string& log = object->validateLog.empty() ? object->linkLog : object->validateLog;
    copyStringToBuffer(log, bufSize, length, infoLog);
    return true;
}

bool GLContext::getAttachedShaders(GLuint program, GLsizei maxCount, GLsizei* count, GLuint* shaders) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLsizei n = std::min<GLsizei>(maxCount, static_cast<GLsizei>(object->attachedShaders.size()));
    if (shaders != nullptr) {
        for (GLsizei i = 0; i < n; ++i) {
            shaders[i] = object->attachedShaders[static_cast<std::size_t>(i)];
        }
    }
    if (count != nullptr) {
        *count = n;
    }
    return true;
}

bool GLContext::bindAttribLocation(GLuint program, GLuint index, const GLchar* name) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || name == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    object->requestedAttribLocations[std::string(name)] = index;
    return true;
}

GLint GLContext::getAttribLocation(GLuint program, const GLchar* name) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || name == nullptr) {
        pushError(GL_INVALID_VALUE);
        return -1;
    }
    if (!object->linked) {
        pushError(GL_INVALID_OPERATION);
        return -1;
    }
    const std::string lookup = name;
    for (const auto& attrib : object->attributes) {
        if (attrib.name == lookup) {
            return attrib.location;
        }
    }
    return -1;
}

bool GLContext::getActiveAttrib(GLuint program, GLuint index, GLsizei bufSize, GLsizei* length, GLint* size, GLenum* type, GLchar* name) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (index >= object->attributes.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const auto& attrib = object->attributes[index];
    if (size != nullptr) {
        *size = 1;
    }
    if (type != nullptr) {
        *type = attrib.type;
    }
    copyStringToBuffer(attrib.name, bufSize, length, name);
    return true;
}

GLint GLContext::getUniformLocation(GLuint program, const GLchar* name) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || name == nullptr) {
        pushError(GL_INVALID_VALUE);
        return -1;
    }
    if (!object->linked) {
        pushError(GL_INVALID_OPERATION);
        return -1;
    }
    const std::string lookup = name;
    for (const auto& uniform : object->uniforms) {
        if (uniform.name == lookup) {
            return uniform.location;
        }
    }
    return -1;
}

bool GLContext::getActiveUniform(GLuint program, GLuint index, GLsizei bufSize, GLsizei* length, GLint* size, GLenum* type, GLchar* name) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (index >= object->uniforms.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const auto& uniform = object->uniforms[index];
    if (size != nullptr) {
        *size = std::max<GLint>(uniform.arraySize, 1);
    }
    if (type != nullptr) {
        *type = uniform.type;
    }
    copyStringToBuffer(uniform.name, bufSize, length, name);
    return true;
}

namespace {

GLProgramUniformValue* lookupUniformValue(GLProgramObject* program, GLint location) {
    if (program == nullptr || location < 0) {
        return nullptr;
    }
    auto it = program->uniformValues.find(location);
    if (it == program->uniformValues.end()) {
        return nullptr;
    }
    return &it->second;
}

}  // namespace

bool GLContext::getUniformfv(GLuint program, GLint location, GLfloat* params) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLProgramUniformValue* value = lookupUniformValue(object, location);
    if (value == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!value->floats.empty()) {
        std::memcpy(params, value->floats.data(), value->floats.size() * sizeof(GLfloat));
    } else if (!value->ints.empty()) {
        for (std::size_t i = 0; i < value->ints.size(); ++i) {
            params[i] = static_cast<GLfloat>(value->ints[i]);
        }
    } else if (!value->uints.empty()) {
        for (std::size_t i = 0; i < value->uints.size(); ++i) {
            params[i] = static_cast<GLfloat>(value->uints[i]);
        }
    }
    return true;
}

bool GLContext::getUniformiv(GLuint program, GLint location, GLint* params) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLProgramUniformValue* value = lookupUniformValue(object, location);
    if (value == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!value->ints.empty()) {
        std::memcpy(params, value->ints.data(), value->ints.size() * sizeof(GLint));
    } else if (!value->floats.empty()) {
        for (std::size_t i = 0; i < value->floats.size(); ++i) {
            params[i] = static_cast<GLint>(value->floats[i]);
        }
    } else if (!value->uints.empty()) {
        for (std::size_t i = 0; i < value->uints.size(); ++i) {
            params[i] = static_cast<GLint>(value->uints[i]);
        }
    }
    return true;
}

bool GLContext::getUniformuiv(GLuint program, GLint location, GLuint* params) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLProgramUniformValue* value = lookupUniformValue(object, location);
    if (value == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!value->uints.empty()) {
        std::memcpy(params, value->uints.data(), value->uints.size() * sizeof(GLuint));
    } else if (!value->ints.empty()) {
        for (std::size_t i = 0; i < value->ints.size(); ++i) {
            params[i] = static_cast<GLuint>(value->ints[i]);
        }
    } else if (!value->floats.empty()) {
        for (std::size_t i = 0; i < value->floats.size(); ++i) {
            params[i] = static_cast<GLuint>(value->floats[i]);
        }
    }
    return true;
}

bool GLContext::setUniformScalarVector(GLint location, UniformElementType element, GLint vectorSize, GLsizei count, const void* values) {
    if (location < 0) {
        return true;  // -1 silently no-ops per spec.
    }
    if (count < 0 || vectorSize < 1 || vectorSize > 4) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint currentProgram = impl_->state->currentProgram();
    GLProgramObject* object = impl_->objects->programs().get(currentProgram);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramUniformValue* slot = lookupUniformValue(object, location);
    if (slot == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const std::size_t expected = static_cast<std::size_t>(vectorSize) *
                                 static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    switch (element) {
        case UniformElementType::Float: {
            slot->floats.assign(static_cast<const GLfloat*>(values), static_cast<const GLfloat*>(values) + expected);
            slot->ints.clear();
            slot->uints.clear();
            break;
        }
        case UniformElementType::Int: {
            slot->ints.assign(static_cast<const GLint*>(values), static_cast<const GLint*>(values) + expected);
            slot->floats.clear();
            slot->uints.clear();
            break;
        }
        case UniformElementType::UnsignedInt: {
            slot->uints.assign(static_cast<const GLuint*>(values), static_cast<const GLuint*>(values) + expected);
            slot->floats.clear();
            slot->ints.clear();
            break;
        }
    }
    return true;
}

bool GLContext::setUniformMatrix(GLint location, GLint rows, GLint cols, GLsizei count, GLboolean transpose, const GLfloat* values) {
    if (location < 0) {
        return true;
    }
    if (count < 0 || rows < 2 || rows > 4 || cols < 2 || cols > 4 || values == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint currentProgram = impl_->state->currentProgram();
    GLProgramObject* object = impl_->objects->programs().get(currentProgram);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramUniformValue* slot = lookupUniformValue(object, location);
    if (slot == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const std::size_t elements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols) *
                                 static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    slot->floats.assign(elements, 0.0f);
    if (transpose == GL_FALSE) {
        std::memcpy(slot->floats.data(), values, elements * sizeof(GLfloat));
    } else {
        const std::size_t matrixElements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols);
        for (GLsizei m = 0; m < std::max<GLsizei>(count, 1); ++m) {
            for (GLint r = 0; r < rows; ++r) {
                for (GLint c = 0; c < cols; ++c) {
                    const std::size_t srcIndex = static_cast<std::size_t>(m) * matrixElements +
                                                 static_cast<std::size_t>(r) * static_cast<std::size_t>(cols) +
                                                 static_cast<std::size_t>(c);
                    const std::size_t dstIndex = static_cast<std::size_t>(m) * matrixElements +
                                                 static_cast<std::size_t>(c) * static_cast<std::size_t>(rows) +
                                                 static_cast<std::size_t>(r);
                    slot->floats[dstIndex] = values[srcIndex];
                }
            }
        }
    }
    slot->ints.clear();
    slot->uints.clear();
    return true;
}

bool GLContext::setUniformDouble(GLint location, GLint vectorSize, GLsizei count, const GLdouble* values) {
    if (location < 0) {
        return true;
    }
    if (count < 0 || vectorSize < 1 || vectorSize > 4 || values == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint currentProgram = impl_->state->currentProgram();
    GLProgramObject* object = impl_->objects->programs().get(currentProgram);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramUniformValue* slot = lookupUniformValue(object, location);
    if (slot == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const std::size_t expected = static_cast<std::size_t>(vectorSize) *
                                 static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    // Shadow original doubles for lossless glGetUniformdv readback.
    slot->doubles.assign(values, values + expected);
    // Narrow to float for the Metal pipeline.
    slot->floats.resize(expected);
    for (std::size_t i = 0; i < expected; ++i) {
        slot->floats[i] = static_cast<GLfloat>(values[i]);
    }
    slot->ints.clear();
    slot->uints.clear();
    return true;
}

bool GLContext::setUniformDoubleMatrix(GLint location, GLint rows, GLint cols, GLsizei count, GLboolean transpose, const GLdouble* values) {
    if (location < 0) {
        return true;
    }
    if (count < 0 || rows < 2 || rows > 4 || cols < 2 || cols > 4 || values == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint currentProgram = impl_->state->currentProgram();
    GLProgramObject* object = impl_->objects->programs().get(currentProgram);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramUniformValue* slot = lookupUniformValue(object, location);
    if (slot == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const std::size_t elements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols) *
                                 static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    // Shadow original doubles.
    slot->doubles.resize(elements);
    slot->floats.resize(elements);
    if (transpose == GL_FALSE) {
        for (std::size_t i = 0; i < elements; ++i) {
            slot->doubles[i] = values[i];
            slot->floats[i] = static_cast<GLfloat>(values[i]);
        }
    } else {
        const std::size_t matrixElements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols);
        for (GLsizei m = 0; m < std::max<GLsizei>(count, 1); ++m) {
            for (GLint r = 0; r < rows; ++r) {
                for (GLint c = 0; c < cols; ++c) {
                    const std::size_t srcIndex = static_cast<std::size_t>(m) * matrixElements +
                                                 static_cast<std::size_t>(r) * static_cast<std::size_t>(cols) +
                                                 static_cast<std::size_t>(c);
                    const std::size_t dstIndex = static_cast<std::size_t>(m) * matrixElements +
                                                 static_cast<std::size_t>(c) * static_cast<std::size_t>(rows) +
                                                 static_cast<std::size_t>(r);
                    slot->doubles[dstIndex] = values[srcIndex];
                    slot->floats[dstIndex] = static_cast<GLfloat>(values[srcIndex]);
                }
            }
        }
    }
    slot->ints.clear();
    slot->uints.clear();
    return true;
}

// --- GL 4.1: glProgramUniform* family — explicit program handle variants ---

bool GLContext::setUniformScalarVectorForProgram(GLuint program, GLint location, UniformElementType element, GLint vectorSize, GLsizei count, const void* values) {
    if (location < 0) return true;
    if (count < 0 || vectorSize < 1 || vectorSize > 4) { pushError(GL_INVALID_VALUE); return false; }
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    GLProgramUniformValue* slot = lookupUniformValue(object, location);
    if (slot == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    const std::size_t expected = static_cast<std::size_t>(vectorSize) * static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    switch (element) {
        case UniformElementType::Float:
            slot->floats.assign(static_cast<const GLfloat*>(values), static_cast<const GLfloat*>(values) + expected);
            slot->ints.clear(); slot->uints.clear(); break;
        case UniformElementType::Int:
            slot->ints.assign(static_cast<const GLint*>(values), static_cast<const GLint*>(values) + expected);
            slot->floats.clear(); slot->uints.clear(); break;
        case UniformElementType::UnsignedInt:
            slot->uints.assign(static_cast<const GLuint*>(values), static_cast<const GLuint*>(values) + expected);
            slot->floats.clear(); slot->ints.clear(); break;
    }
    return true;
}

bool GLContext::setUniformMatrixForProgram(GLuint program, GLint location, GLint rows, GLint cols, GLsizei count, GLboolean transpose, const GLfloat* values) {
    if (location < 0) return true;
    if (count < 0 || rows < 2 || rows > 4 || cols < 2 || cols > 4 || values == nullptr) { pushError(GL_INVALID_VALUE); return false; }
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    GLProgramUniformValue* slot = lookupUniformValue(object, location);
    if (slot == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    const std::size_t elements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols) * static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    slot->floats.assign(elements, 0.0f);
    if (transpose == GL_FALSE) {
        std::memcpy(slot->floats.data(), values, elements * sizeof(GLfloat));
    } else {
        const std::size_t matrixElements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols);
        for (GLsizei m = 0; m < std::max<GLsizei>(count, 1); ++m) {
            for (GLint r = 0; r < rows; ++r) {
                for (GLint c = 0; c < cols; ++c) {
                    const std::size_t srcIndex = static_cast<std::size_t>(m) * matrixElements + static_cast<std::size_t>(r) * static_cast<std::size_t>(cols) + static_cast<std::size_t>(c);
                    const std::size_t dstIndex = static_cast<std::size_t>(m) * matrixElements + static_cast<std::size_t>(c) * static_cast<std::size_t>(rows) + static_cast<std::size_t>(r);
                    slot->floats[dstIndex] = values[srcIndex];
                }
            }
        }
    }
    slot->ints.clear(); slot->uints.clear();
    return true;
}

bool GLContext::setUniformDoubleForProgram(GLuint program, GLint location, GLint vectorSize, GLsizei count, const GLdouble* values) {
    if (location < 0) return true;
    if (count < 0 || vectorSize < 1 || vectorSize > 4 || values == nullptr) { pushError(GL_INVALID_VALUE); return false; }
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    GLProgramUniformValue* slot = lookupUniformValue(object, location);
    if (slot == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    const std::size_t expected = static_cast<std::size_t>(vectorSize) * static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    slot->doubles.assign(values, values + expected);
    slot->floats.resize(expected);
    for (std::size_t i = 0; i < expected; ++i) { slot->floats[i] = static_cast<GLfloat>(values[i]); }
    slot->ints.clear(); slot->uints.clear();
    return true;
}

bool GLContext::setUniformDoubleMatrixForProgram(GLuint program, GLint location, GLint rows, GLint cols, GLsizei count, GLboolean transpose, const GLdouble* values) {
    if (location < 0) return true;
    if (count < 0 || rows < 2 || rows > 4 || cols < 2 || cols > 4 || values == nullptr) { pushError(GL_INVALID_VALUE); return false; }
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    GLProgramUniformValue* slot = lookupUniformValue(object, location);
    if (slot == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    const std::size_t elements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols) * static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    slot->doubles.resize(elements);
    slot->floats.resize(elements);
    if (transpose == GL_FALSE) {
        for (std::size_t i = 0; i < elements; ++i) { slot->doubles[i] = values[i]; slot->floats[i] = static_cast<GLfloat>(values[i]); }
    } else {
        const std::size_t matrixElements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols);
        for (GLsizei m = 0; m < std::max<GLsizei>(count, 1); ++m) {
            for (GLint r = 0; r < rows; ++r) {
                for (GLint c = 0; c < cols; ++c) {
                    const std::size_t srcIndex = static_cast<std::size_t>(m) * matrixElements + static_cast<std::size_t>(r) * static_cast<std::size_t>(cols) + static_cast<std::size_t>(c);
                    const std::size_t dstIndex = static_cast<std::size_t>(m) * matrixElements + static_cast<std::size_t>(c) * static_cast<std::size_t>(rows) + static_cast<std::size_t>(r);
                    slot->doubles[dstIndex] = values[srcIndex];
                    slot->floats[dstIndex] = static_cast<GLfloat>(values[srcIndex]);
                }
            }
        }
    }
    slot->ints.clear(); slot->uints.clear();
    return true;
}

bool GLContext::getUniformdv(GLuint program, GLint location, GLdouble* params) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLProgramUniformValue* value = lookupUniformValue(object, location);
    if (value == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Prefer the lossless double shadow if available.
    if (!value->doubles.empty()) {
        std::memcpy(params, value->doubles.data(), value->doubles.size() * sizeof(GLdouble));
    } else if (!value->floats.empty()) {
        for (std::size_t i = 0; i < value->floats.size(); ++i) {
            params[i] = static_cast<GLdouble>(value->floats[i]);
        }
    } else if (!value->ints.empty()) {
        for (std::size_t i = 0; i < value->ints.size(); ++i) {
            params[i] = static_cast<GLdouble>(value->ints[i]);
        }
    } else if (!value->uints.empty()) {
        for (std::size_t i = 0; i < value->uints.size(); ++i) {
            params[i] = static_cast<GLdouble>(value->uints[i]);
        }
    }
    return true;
}

namespace {

// Phase A Group 7 — MVP draw path. Until the GLSL→MSL translator is wired up,
// the runtime supports one hand-written "solid color" pipeline: a single
// vec3 position attribute at location 0 plus a vec4 uniform named "uColor".
// Anything outside that envelope is rejected here so the caller can emit a
// debug message and bail cleanly instead of producing garbage pixels.
struct SolidColorDrawSetup {
    bool ok = false;
    MetalDrawInfo info;
    GLVertexArrayObject* vertexArray = nullptr;
    GLProgramObject* program = nullptr;
    const std::uint8_t* positionShadow = nullptr;
    std::size_t positionShadowSize = 0;
};

SolidColorDrawSetup buildSolidColorDrawSetup(GLStateTracker& state, GLObjectStore& objects, GLenum mode, const char* debugLabel) {
    SolidColorDrawSetup setup;

    if (mode != GL_TRIANGLES && mode != GL_TRIANGLE_STRIP && mode != GL_TRIANGLE_FAN) {
        return setup;
    }

    const GLuint vaoName = state.boundVertexArray();
    if (vaoName == 0) {
        return setup;
    }
    GLVertexArrayObject* vao = objects.vertexArrays().get(vaoName);
    if (vao == nullptr) {
        return setup;
    }
    if (vao->attributes.empty()) {
        objects.initializeVertexArray(*vao);
        if (vao->attributes.empty()) {
            return setup;
        }
    }

    const GLuint programName = state.currentProgram();
    if (programName == 0) {
        return setup;
    }
    GLProgramObject* program = objects.programs().get(programName);
    if (program == nullptr || !program->linked) {
        return setup;
    }

    const auto& positionAttr = vao->attributes[0];
    if (!positionAttr.enabled || positionAttr.type != GL_FLOAT || positionAttr.size != 3 || positionAttr.buffer == 0) {
        return setup;
    }
    GLBufferObject* vbo = objects.buffers().get(positionAttr.buffer);
    if (vbo == nullptr || vbo->shadowBytes.empty()) {
        return setup;
    }
    const std::size_t positionStride = positionAttr.stride > 0
        ? static_cast<std::size_t>(positionAttr.stride)
        : sizeof(GLfloat) * 3;
    if (static_cast<std::size_t>(positionAttr.pointer) > vbo->shadowBytes.size()) {
        return setup;
    }

    setup.info.mode = mode;
    setup.info.positions = vbo->shadowBytes.data() + static_cast<std::size_t>(positionAttr.pointer);
    setup.info.positionByteCount = vbo->shadowBytes.size() - static_cast<std::size_t>(positionAttr.pointer);
    setup.info.positionStride = positionStride;
    setup.info.positionComponents = 3;
    setup.positionShadow = vbo->shadowBytes.data();
    setup.positionShadowSize = vbo->shadowBytes.size();

    // Default to opaque white, then override from the "uColor" uniform if the
    // linked program has one. This mirrors what the hand-written fragment
    // shader expects at fragment buffer index 0.
    setup.info.uniformColor[0] = 1.0f;
    setup.info.uniformColor[1] = 1.0f;
    setup.info.uniformColor[2] = 1.0f;
    setup.info.uniformColor[3] = 1.0f;
    for (const auto& uniform : program->uniforms) {
        if (uniform.name == "uColor" && uniform.type == GL_FLOAT_VEC4 && uniform.location >= 0) {
            auto it = program->uniformValues.find(uniform.location);
            if (it != program->uniformValues.end() && it->second.floats.size() >= 4) {
                setup.info.uniformColor[0] = it->second.floats[0];
                setup.info.uniformColor[1] = it->second.floats[1];
                setup.info.uniformColor[2] = it->second.floats[2];
                setup.info.uniformColor[3] = it->second.floats[3];
            }
            break;
        }
    }

    setup.info.depthTestEnabled = state.isEnabled(GL_DEPTH_TEST);
    setup.info.depthFunc = state.depthState().func;
    setup.info.cullFaceEnabled = state.isEnabled(GL_CULL_FACE);
    setup.info.cullFaceMode = state.rasterState().cullFaceMode;
    setup.info.frontFace = state.rasterState().frontFace;
    if (debugLabel != nullptr) {
        setup.info.debugLabel = debugLabel;
    }

    setup.vertexArray = vao;
    setup.program = program;
    setup.ok = true;
    return setup;
}

}  // namespace

bool GLContext::drawArrays(GLenum mode, GLint first, GLsizei count) {
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (count == 0) {
        return true;
    }
    if (!impl_->state->validateForDraw()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    if (impl_->frameGraph == nullptr) {
        return false;
    }
    // Make sure the drawable and depth targets are sized for the current
    // viewport BEFORE we flush the pending clear. Resizing invalidates any
    // unflushed command buffer, so doing it after the clear would drop the
    // clear on the floor and leave the offscreen attachment uninitialized.
    impl_->frameGraph->resizeDrawable(impl_->viewportWidth, impl_->viewportHeight);
    // Flush any pending clear before we start the draw render pass; otherwise
    // the draw would run against an uncleared default attachment.
    impl_->encodePendingWork();

    // Try the translated shader pipeline first (GPU-side vertex processing).
    const GLuint programName = impl_->state->currentProgram();
    GLProgramObject* program = (programName != 0) ? impl_->objects->programs().get(programName) : nullptr;
    NSLog(@"[GL] drawArrays: mode=0x%X count=%d program=%u hasTranslated=%d",
          mode, count, programName, program ? (int)program->hasTranslatedPipeline : -1);
    if (program != nullptr && program->hasTranslatedPipeline) {
        const GLuint vaoName = impl_->state->boundVertexArray();
        GLVertexArrayObject* vao = (vaoName != 0) ? impl_->objects->vertexArrays().get(vaoName) : nullptr;
        if (vao != nullptr && !vao->attributes.empty()) {
            const auto& posAttr = vao->attributes[0];
            GLBufferObject* vbo = (posAttr.buffer != 0) ? impl_->objects->buffers().get(posAttr.buffer) : nullptr;
            if (vbo != nullptr && !vbo->shadowBytes.empty()) {
                const std::size_t posStride = posAttr.stride > 0
                    ? static_cast<std::size_t>(posAttr.stride)
                    : sizeof(GLfloat) * static_cast<std::size_t>(posAttr.size);
                const std::size_t firstOff = static_cast<std::size_t>(first) * posStride;
                const std::size_t startOff = static_cast<std::size_t>(posAttr.pointer) + firstOff;

                if (startOff <= vbo->shadowBytes.size()) {
                    TranslatedDrawInfo tdi;
                    tdi.mode = mode;
                    tdi.vertexCount = count;
                    tdi.vertexData = vbo->shadowBytes.data() + startOff;
                    tdi.vertexDataByteCount = vbo->shadowBytes.size() - startOff;
                    tdi.vertexStride = posStride;
                    tdi.depthTestEnabled = impl_->state->isEnabled(GL_DEPTH_TEST);
                    tdi.depthFunc = impl_->state->depthState().func;
                    tdi.cullFaceEnabled = impl_->state->isEnabled(GL_CULL_FACE);
                    tdi.cullFaceMode = impl_->state->rasterState().cullFaceMode;
                    tdi.frontFace = impl_->state->rasterState().frontFace;
                    tdi.vertexMSL = &program->vertexMSL;
                    tdi.fragmentMSL = &program->fragmentMSL;
                    tdi.vertexReflection = &program->vertexReflection;
                    tdi.fragmentReflection = &program->fragmentReflection;
                    tdi.pipelineStateOut = &program->metalPipelineState;
                    tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;

                    // Pack all uniform values into a single buffer matching the
                    // SPIRV-Cross push-constant struct layout.  For simple programs
                    // the uniforms are laid out in declaration order.
                    for (const auto& uniform : program->uniforms) {
                        auto it = program->uniformValues.find(uniform.location);
                        if (it != program->uniformValues.end()) {
                            const auto& val = it->second;
                            if (!val.floats.empty()) {
                                tdi.uniformBuffer.insert(tdi.uniformBuffer.end(),
                                    val.floats.begin(), val.floats.end());
                            } else if (!val.ints.empty()) {
                                for (GLint v : val.ints) {
                                    float fv;
                                    std::memcpy(&fv, &v, sizeof(float));
                                    tdi.uniformBuffer.push_back(fv);
                                }
                            }
                        }
                    }

                    const bool ok = impl_->frameGraph->encodeTranslatedDraw(tdi);
                    if (ok) {
                        return true;
                    }
                    // Fall through to solid-color path on failure.
                }
            }
        }
    }

    // Fallback: solid-color draw path (hardcoded appgl_solid pipeline).
    SolidColorDrawSetup setup = buildSolidColorDrawSetup(*impl_->state, *impl_->objects, mode, "glDrawArrays");
    if (!setup.ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_OTHER,
            0,
            GL_DEBUG_SEVERITY_LOW,
            "glDrawArrays: draw skipped (no translated pipeline and solid-color path unsupported)"
        );
        return false;
    }

    setup.info.vertexCount = count;
    setup.info.baseVertex = first;
    const std::size_t stride = setup.info.positionStride;
    const std::size_t firstOffset = static_cast<std::size_t>(first) * stride;
    const std::size_t startOffset = static_cast<std::size_t>(setup.vertexArray->attributes[0].pointer) + firstOffset;
    if (startOffset > setup.positionShadowSize) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    setup.info.positions = setup.positionShadow + startOffset;
    setup.info.positionByteCount = setup.positionShadowSize - startOffset;
    setup.info.indices = nullptr;
    setup.info.indexCount = 0;
    setup.info.indexType = 0;

    const bool ok = impl_->frameGraph->encodeSolidColorDraw(setup.info);
    if (!ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_ERROR,
            0,
            GL_DEBUG_SEVERITY_HIGH,
            "glDrawArrays: MetalFrameGraph failed to encode draw"
        );
    }
    return ok;
}

bool GLContext::drawElements(GLenum mode, GLsizei count, GLenum type, const void* indices) {
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (count == 0) {
        return true;
    }
    if (!isSupportedElementIndexType(type)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (!impl_->state->validateForDraw()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    if (impl_->frameGraph == nullptr) {
        return false;
    }
    // Size the drawable before flushing the clear — see glDrawArrays for the
    // rationale.
    impl_->frameGraph->resizeDrawable(impl_->viewportWidth, impl_->viewportHeight);
    impl_->encodePendingWork();

    // Resolve element buffer early — needed by both translated and solid paths.
    const GLuint vaoName = impl_->state->boundVertexArray();
    GLVertexArrayObject* vao = (vaoName != 0) ? impl_->objects->vertexArrays().get(vaoName) : nullptr;
    if (vao == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const GLuint elementBufferName = vao->elementArrayBuffer;
    if (elementBufferName == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLBufferObject* elementBuffer = impl_->objects->buffers().get(elementBufferName);
    if (elementBuffer == nullptr || elementBuffer->shadowBytes.empty()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    const std::size_t indexOffset = reinterpret_cast<std::uintptr_t>(indices);
    if (indexOffset > elementBuffer->shadowBytes.size()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const void* indexPtr = elementBuffer->shadowBytes.data() + indexOffset;

    // GL_UNSIGNED_BYTE is not supported natively by Metal; expandElementIndices
    // promotes to GL_UNSIGNED_SHORT. For UINT16/UINT32 we can pass through.
    std::vector<std::uint8_t> expanded;
    GLenum effectiveType = type;
    const void* effectivePtr = indexPtr;
    if (elementIndexTypeNeedsExpansion(type)) {
        IndexExpansionResult result = expandElementIndices(count, type, indexPtr);
        if (!result.ok) {
            pushError(result.error);
            return false;
        }
        expanded = std::move(result.bytes);
        effectiveType = result.outputType;
        effectivePtr = expanded.data();
    }

    // Try the translated shader pipeline first (GPU-side vertex processing).
    const GLuint programName = impl_->state->currentProgram();
    GLProgramObject* program = (programName != 0) ? impl_->objects->programs().get(programName) : nullptr;
    if (program != nullptr && program->hasTranslatedPipeline) {
        if (!vao->attributes.empty()) {
            const auto& posAttr = vao->attributes[0];
            GLBufferObject* vbo = (posAttr.buffer != 0) ? impl_->objects->buffers().get(posAttr.buffer) : nullptr;
            if (vbo != nullptr && !vbo->shadowBytes.empty()) {
                const std::size_t posStride = posAttr.stride > 0
                    ? static_cast<std::size_t>(posAttr.stride)
                    : sizeof(GLfloat) * static_cast<std::size_t>(posAttr.size);
                const std::size_t startOff = static_cast<std::size_t>(posAttr.pointer);

                if (startOff <= vbo->shadowBytes.size()) {
                    TranslatedDrawInfo tdi;
                    tdi.mode = mode;
                    tdi.vertexCount = count;
                    tdi.vertexData = vbo->shadowBytes.data() + startOff;
                    tdi.vertexDataByteCount = vbo->shadowBytes.size() - startOff;
                    tdi.vertexStride = posStride;
                    tdi.indices = effectivePtr;
                    tdi.indexCount = count;
                    tdi.indexType = effectiveType;
                    tdi.depthTestEnabled = impl_->state->isEnabled(GL_DEPTH_TEST);
                    tdi.depthFunc = impl_->state->depthState().func;
                    tdi.cullFaceEnabled = impl_->state->isEnabled(GL_CULL_FACE);
                    tdi.cullFaceMode = impl_->state->rasterState().cullFaceMode;
                    tdi.frontFace = impl_->state->rasterState().frontFace;
                    tdi.vertexMSL = &program->vertexMSL;
                    tdi.fragmentMSL = &program->fragmentMSL;
                    tdi.vertexReflection = &program->vertexReflection;
                    tdi.fragmentReflection = &program->fragmentReflection;
                    tdi.pipelineStateOut = &program->metalPipelineState;
                    tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;

                    for (const auto& uniform : program->uniforms) {
                        auto it = program->uniformValues.find(uniform.location);
                        if (it != program->uniformValues.end()) {
                            const auto& val = it->second;
                            if (!val.floats.empty()) {
                                tdi.uniformBuffer.insert(tdi.uniformBuffer.end(),
                                    val.floats.begin(), val.floats.end());
                            } else if (!val.ints.empty()) {
                                for (GLint v : val.ints) {
                                    float fv;
                                    std::memcpy(&fv, &v, sizeof(float));
                                    tdi.uniformBuffer.push_back(fv);
                                }
                            }
                        }
                    }

                    const bool ok = impl_->frameGraph->encodeTranslatedDraw(tdi);
                    if (ok) {
                        return true;
                    }
                    // Fall through to solid-color path on failure.
                }
            }
        }
    }

    // Fallback: solid-color draw path (hardcoded appgl_solid pipeline).
    SolidColorDrawSetup setup = buildSolidColorDrawSetup(*impl_->state, *impl_->objects, mode, "glDrawElements");
    if (!setup.ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_OTHER,
            0,
            GL_DEBUG_SEVERITY_LOW,
            "glDrawElements: draw skipped (no translated pipeline and solid-color path unsupported)"
        );
        return false;
    }

    setup.info.vertexCount = count;
    setup.info.baseVertex = 0;
    setup.info.indices = effectivePtr;
    setup.info.indexCount = count;
    setup.info.indexType = effectiveType;

    const bool ok = impl_->frameGraph->encodeSolidColorDraw(setup.info);
    if (!ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_ERROR,
            0,
            GL_DEBUG_SEVERITY_HIGH,
            "glDrawElements: MetalFrameGraph failed to encode draw"
        );
    }
    return ok;
}

// ---------------------------------------------------------------------------
// GL 4.2 — Memory Barriers
// ---------------------------------------------------------------------------

bool GLContext::memoryBarrier(GLbitfield barriers) {
    // All valid GL 4.2/4.3 barrier bits.
    constexpr GLbitfield kValidBarrierBits =
        GL_VERTEX_ATTRIB_ARRAY_BARRIER_BIT |
        GL_ELEMENT_ARRAY_BARRIER_BIT |
        GL_UNIFORM_BARRIER_BIT |
        GL_TEXTURE_FETCH_BARRIER_BIT |
        GL_SHADER_IMAGE_ACCESS_BARRIER_BIT |
        GL_COMMAND_BARRIER_BIT |
        GL_PIXEL_BUFFER_BARRIER_BIT |
        GL_TEXTURE_UPDATE_BARRIER_BIT |
        GL_BUFFER_UPDATE_BARRIER_BIT |
        GL_FRAMEBUFFER_BARRIER_BIT |
        GL_TRANSFORM_FEEDBACK_BARRIER_BIT |
        GL_ATOMIC_COUNTER_BARRIER_BIT |
        GL_SHADER_STORAGE_BARRIER_BIT;

    if (barriers != GL_ALL_BARRIER_BITS && (barriers & ~kValidBarrierBits) != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    // Validated no-op. Metal command queue ordering handles most barriers
    // implicitly; explicit MTLFence/MTLEvent synchronization will be added
    // when compute pipelines are fully wired.
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.3 — Compute Shaders
// ---------------------------------------------------------------------------

bool GLContext::dispatchCompute(GLuint num_groups_x, GLuint num_groups_y, GLuint num_groups_z) {
    constexpr GLuint kMaxWorkGroups = 65535;

    if (num_groups_x == 0 || num_groups_y == 0 || num_groups_z == 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (num_groups_x > kMaxWorkGroups || num_groups_y > kMaxWorkGroups || num_groups_z > kMaxWorkGroups) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    // Stub: compute pipeline creation at link time is not yet wired.
    // When GLSL compute shaders are compiled and linked, this will encode
    // a Metal compute command via the frame graph.
    return true;
}

bool GLContext::dispatchComputeIndirect(GLintptr indirect) {
    if (indirect < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if ((indirect % 4) != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    // Stub: indirect compute dispatch. The offset points into the currently
    // bound GL_DISPATCH_INDIRECT_BUFFER. Actual Metal encoding will be wired
    // when compute shader programs are created at link time.
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.2 — Image Load/Store
// ---------------------------------------------------------------------------

bool GLContext::bindImageTexture(GLuint unit, GLuint texture, GLint level, GLboolean layered, GLint layer, GLenum access, GLenum format) {
    if (unit >= Impl::kMaxImageUnits) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (access != GL_READ_ONLY && access != GL_WRITE_ONLY && access != GL_READ_WRITE) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Validate format — accept the common image load/store formats.
    switch (format) {
        case GL_RGBA32F:
        case GL_RGBA16F:
        case GL_RG32F:
        case GL_RG16F:
        case GL_R11F_G11F_B10F:
        case GL_R32F:
        case GL_R16F:
        case GL_RGBA32UI:
        case GL_RGBA16UI:
        case GL_RGB10_A2UI:
        case GL_RGBA8UI:
        case GL_RG32UI:
        case GL_RG16UI:
        case GL_RG8UI:
        case GL_R32UI:
        case GL_R16UI:
        case GL_R8UI:
        case GL_RGBA32I:
        case GL_RGBA16I:
        case GL_RGBA8I:
        case GL_RG32I:
        case GL_RG16I:
        case GL_RG8I:
        case GL_R32I:
        case GL_R16I:
        case GL_R8I:
        case GL_RGBA16:
        case GL_RGB10_A2:
        case GL_RGBA8:
        case GL_RG16:
        case GL_RG8:
        case GL_R16:
        case GL_R8:
        case GL_RGBA16_SNORM:
        case GL_RGBA8_SNORM:
        case GL_RG16_SNORM:
        case GL_RG8_SNORM:
        case GL_R16_SNORM:
        case GL_R8_SNORM:
            break;
        default:
            pushError(GL_INVALID_VALUE);
            return false;
    }

    auto& binding = impl_->imageBindings[unit];
    binding.texture = texture;
    binding.level = level;
    binding.layered = layered;
    binding.layer = layer;
    binding.access = access;
    binding.format = format;
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.2 — Atomic Counter Buffer Queries
// ---------------------------------------------------------------------------

bool GLContext::getActiveAtomicCounterBufferiv(GLuint program, GLuint bufferIndex, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Metal has no native atomic counters. Programs will never report any
    // active atomic counter buffers, so any bufferIndex is out of range.
    // However, for applications that query speculatively we return sensible
    // defaults when bufferIndex == 0 to avoid error spam, and GL_INVALID_VALUE
    // otherwise.
    if (bufferIndex > 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    switch (pname) {
        case GL_ATOMIC_COUNTER_BUFFER_BINDING:
            *params = 0;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_DATA_SIZE:
            *params = 0;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_ACTIVE_ATOMIC_COUNTERS:
            *params = 0;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_VERTEX_SHADER:
            *params = GL_FALSE;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_FRAGMENT_SHADER:
            *params = GL_FALSE;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_GEOMETRY_SHADER:
            *params = GL_FALSE;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_TESS_CONTROL_SHADER:
            *params = GL_FALSE;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_TESS_EVALUATION_SHADER:
            *params = GL_FALSE;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_COMPUTE_SHADER:
            *params = GL_FALSE;
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

// ---------------------------------------------------------------------------
// GL 4.3 — Program Resource Introspection (ARB_program_interface_query)
// ---------------------------------------------------------------------------

namespace {

const std::vector<GLProgramResourceEntry>* getResourceTable(const GLProgramObject& prog, GLenum programInterface) {
    switch (programInterface) {
        case GL_UNIFORM:                return &prog.resourceUniforms;
        case GL_UNIFORM_BLOCK:          return &prog.resourceUniformBlocks;
        case GL_PROGRAM_INPUT:          return &prog.resourceInputs;
        case GL_PROGRAM_OUTPUT:         return &prog.resourceOutputs;
        case GL_SHADER_STORAGE_BLOCK:   return &prog.resourceStorageBlocks;
        case GL_ATOMIC_COUNTER_BUFFER:  return &prog.resourceAtomicCounterBuffers;
        case GL_BUFFER_VARIABLE:        return &prog.resourceBufferVariables;
        default: return nullptr;
    }
}

GLint getResourceProperty(const GLProgramResourceEntry& entry, GLenum prop) {
    switch (prop) {
        case GL_NAME_LENGTH:       return static_cast<GLint>(entry.name.size() + 1);
        case GL_TYPE:              return static_cast<GLint>(entry.type);
        case GL_ARRAY_SIZE:        return entry.arraySize;
        case GL_OFFSET:            return entry.offset;
        case GL_BLOCK_INDEX:       return entry.blockIndex;
        case GL_LOCATION:          return entry.location;
        case GL_REFERENCED_BY_VERTEX_SHADER:   return (entry.referencedBy & 1) ? GL_TRUE : GL_FALSE;
        case GL_REFERENCED_BY_FRAGMENT_SHADER: return (entry.referencedBy & 2) ? GL_TRUE : GL_FALSE;
        case GL_REFERENCED_BY_COMPUTE_SHADER:  return (entry.referencedBy & 4) ? GL_TRUE : GL_FALSE;
        case GL_REFERENCED_BY_GEOMETRY_SHADER: return GL_FALSE;
        case GL_REFERENCED_BY_TESS_CONTROL_SHADER: return GL_FALSE;
        case GL_REFERENCED_BY_TESS_EVALUATION_SHADER: return GL_FALSE;
        case GL_BUFFER_BINDING:    return entry.location;
        case GL_BUFFER_DATA_SIZE:  return 0;
        case GL_NUM_ACTIVE_VARIABLES: return 0;
        case GL_ACTIVE_VARIABLES:  return 0;
        case GL_IS_ROW_MAJOR:      return GL_FALSE;
        case GL_MATRIX_STRIDE:     return 0;
        case GL_ATOMIC_COUNTER_BUFFER_INDEX: return -1;
        case GL_TOP_LEVEL_ARRAY_SIZE:   return 1;
        case GL_TOP_LEVEL_ARRAY_STRIDE: return 0;
        default: return 0;
    }
}

}  // anonymous namespace

bool GLContext::getProgramInterfaceiv(GLuint program, GLenum programInterface, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr || !prog->linked) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const auto* table = getResourceTable(*prog, programInterface);
    if (table == nullptr) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    switch (pname) {
        case GL_ACTIVE_RESOURCES:
            *params = static_cast<GLint>(table->size());
            return true;
        case GL_MAX_NAME_LENGTH: {
            GLint maxLen = 0;
            for (const auto& entry : *table) {
                GLint len = static_cast<GLint>(entry.name.size() + 1);
                if (len > maxLen) maxLen = len;
            }
            *params = maxLen;
            return true;
        }
        case GL_MAX_NUM_ACTIVE_VARIABLES:
            *params = 0;
            return true;
        case GL_MAX_NUM_COMPATIBLE_SUBROUTINES:
            *params = 0;
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getProgramResourceiv(GLuint program, GLenum programInterface, GLuint index, GLsizei propCount, const GLenum* props, GLsizei count, GLsizei* length, GLint* params) {
    if (propCount <= 0 || props == nullptr || count <= 0 || params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr || !prog->linked) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const auto* table = getResourceTable(*prog, programInterface);
    if (table == nullptr) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (index >= table->size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const auto& entry = (*table)[index];
    GLsizei written = 0;
    for (GLsizei i = 0; i < propCount && written < count; ++i) {
        params[written++] = getResourceProperty(entry, props[i]);
    }
    if (length != nullptr) {
        *length = written;
    }
    return true;
}

bool GLContext::getProgramResourceName(GLuint program, GLenum programInterface, GLuint index, GLsizei bufSize, GLsizei* length, GLchar* name) {
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr || !prog->linked) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const auto* table = getResourceTable(*prog, programInterface);
    if (table == nullptr) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (index >= table->size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const auto& entry = (*table)[index];
    if (name != nullptr && bufSize > 0) {
        std::size_t toCopy = std::min(static_cast<std::size_t>(bufSize - 1), entry.name.size());
        std::memcpy(name, entry.name.c_str(), toCopy);
        name[toCopy] = '\0';
        if (length != nullptr) {
            *length = static_cast<GLsizei>(toCopy);
        }
    } else if (length != nullptr) {
        *length = 0;
    }
    return true;
}

GLuint GLContext::getProgramResourceIndex(GLuint program, GLenum programInterface, const GLchar* name) {
    if (name == nullptr) {
        pushError(GL_INVALID_VALUE);
        return GL_INVALID_INDEX;
    }
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr || !prog->linked) {
        pushError(GL_INVALID_OPERATION);
        return GL_INVALID_INDEX;
    }
    const auto* table = getResourceTable(*prog, programInterface);
    if (table == nullptr) {
        pushError(GL_INVALID_ENUM);
        return GL_INVALID_INDEX;
    }
    for (std::size_t i = 0; i < table->size(); ++i) {
        if ((*table)[i].name == name) {
            return static_cast<GLuint>(i);
        }
    }
    return GL_INVALID_INDEX;
}

GLint GLContext::getProgramResourceLocation(GLuint program, GLenum programInterface, const GLchar* name) {
    if (name == nullptr) {
        pushError(GL_INVALID_VALUE);
        return -1;
    }
    if (programInterface != GL_UNIFORM && programInterface != GL_PROGRAM_INPUT && programInterface != GL_PROGRAM_OUTPUT) {
        pushError(GL_INVALID_ENUM);
        return -1;
    }
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr || !prog->linked) {
        pushError(GL_INVALID_OPERATION);
        return -1;
    }
    const auto* table = getResourceTable(*prog, programInterface);
    if (table == nullptr) {
        return -1;
    }
    for (const auto& entry : *table) {
        if (entry.name == name) {
            return entry.location;
        }
    }
    return -1;
}

GLint GLContext::getProgramResourceLocationIndex(GLuint program, GLenum programInterface, const GLchar* name) {
    if (name == nullptr) {
        pushError(GL_INVALID_VALUE);
        return -1;
    }
    if (programInterface != GL_PROGRAM_OUTPUT) {
        pushError(GL_INVALID_ENUM);
        return -1;
    }
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr || !prog->linked) {
        pushError(GL_INVALID_OPERATION);
        return -1;
    }
    // Fragment output location index (dual-source blending). Since we don't
    // track dual-source indices yet, return 0 if the name is found.
    for (const auto& entry : prog->resourceOutputs) {
        if (entry.name == name) {
            return 0;
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------
// GL 4.3 — Shader Storage Block Binding
// ---------------------------------------------------------------------------

bool GLContext::shaderStorageBlockBinding(GLuint program, GLuint storageBlockIndex, GLuint storageBlockBinding) {
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr || !prog->linked) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (storageBlockIndex >= prog->resourceStorageBlocks.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    prog->ssboBindingRemap[storageBlockIndex] = storageBlockBinding;
    // Also update the resource entry's location field so queries reflect the remap.
    prog->resourceStorageBlocks[storageBlockIndex].location = static_cast<GLint>(storageBlockBinding);
    return true;
}

}  // namespace appgl
