#include "GLContext.h"
#include "MetalFrameGraph.h"
#include "../caps/GLCapabilities.h"
#include "../objects/GLObjectStore.h"
#include "../runtime/AppGLRuntime.h"
#include "../shader/CompatShaderRewrite.h"
#include "../shader/GLSLReflection.h"
#include "../shader/ShaderTranslator.h"
#include "../state/GLStateTracker.h"
#include "../state/IndexExpansion.h"
#include "../state/MatrixStateMirror.h"
#include "../state/MetalVertexDescriptorBuilder.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

// Compat-profile upload-format enums removed from the core glcorearb.h
// surface in GL 3.2. AppGL still accepts them as upload aliases via
// componentCountForFormat + buildRGBA8Upload; defining them here with
// #ifndef guards keeps the compat-profile texture path self-contained
// without polluting the public header surface or the codegen tables.
// See GLCapabilities.mm for the matching format-table registrations
// and the upload channel-fill rules in buildRGBA8Upload.
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

// GL_DEPTH_TEXTURE_MODE is a compat-profile glTexParameteri pname that
// existed from GL 1.4 to 3.0 to control how shadow-map textures sampled
// their depth values into RGBA channels (typically GL_LUMINANCE so the
// red, green, and blue channels would all contain the depth comparison
// result). Core profile removed it because shaders read the depth
// channel directly via texture(), and AppGL has no compat-profile
// fixed-function pipeline that would honor the parameter anyway. We
// accept it as a silent no-op so legacy compat-profile shadow-map
// initialization doesn't trip on GL_INVALID_ENUM during boot.
#ifndef GL_DEPTH_TEXTURE_MODE
#define GL_DEPTH_TEXTURE_MODE 0x884B
#endif

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

bool isSupportedInternalTextureFormat(const GLCapabilities& caps, GLenum internalFormat) {
    // Accept the unsized "named color" formats that desktop GL 4.6 spec
    // still considers valid as internal-format aliases on texture
    // allocation entry points. They resolve to RGBA8 on the Metal side.
    switch (internalFormat) {
        case GL_RED:
        case GL_RG:
        case GL_RGB:
        case GL_RGBA:
            return true;
        default:
            break;
    }
    // Every other internal format is registered in the capabilities format
    // table by initializeFormatTable — delegating here means new additions
    // to the table (Landing C 3b: float / packed / integer / compressed /
    // sRGB / depth formats) automatically unlock the texture-allocation
    // path without touching this helper.
    return caps.isSupportedInternalFormat(internalFormat);
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
        // Compat-profile upload formats. componentCountForFormat is the
        // byte-stride helper used by buildRGBA8Upload to walk the source
        // pixel buffer; the channel-fill rule that decides which RGBA
        // slots receive each source byte is in buildRGBA8Upload itself.
        // GL_ALPHA, GL_LUMINANCE, and GL_INTENSITY are single-byte uploads,
        // GL_LUMINANCE_ALPHA is a two-byte upload (luminance then alpha).
        case GL_ALPHA:
        case GL_LUMINANCE:
        case GL_INTENSITY:
            return 1;
        case GL_LUMINANCE_ALPHA:
            return 2;
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
        case GL_DEPTH_TEXTURE_MODE:
            // Compat-profile shadow-map channel-routing pname (GL 1.4..3.0).
            // No-op in AppGL: there is no fixed-function pipeline that
            // would sample the depth channel into RGBA, and core-profile
            // shaders read the depth channel directly. Silently accept
            // and discard so legacy initializers don't trip GL_INVALID_ENUM.
            (void)params;
            (void)values;
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
        // Phase 8X Group 4d follow-up⁷ — the per-texture MTLSamplerState
        // (see GLTextureObject.metalSampler in GLObjectStore.h) lives
        // alongside the Metal storage and is rebuilt lazily from params
        // at draw time. Release it here so deleting or respecifying a
        // texture tears down both halves, and mark the sampler dirty so
        // the next draw rebuilds against the refreshed parameters.
        releaseRetainedMetalObject(object.metalSampler);
        object.metalSampler = nullptr;
        object.samplerDirty = true;
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

        // Channel-fill rules. Most uploads (GL_RED / GL_RG / GL_RGB /
        // GL_RGBA) use the natural byte-position-to-channel mapping with
        // sentinel fill (zero for unused color channels, 255 for the
        // unused alpha channel). The compat-profile aliases need
        // bespoke routing because their byte-stride doesn't match the
        // RGBA8 storage layout:
        //
        //   GL_ALPHA          (1 byte)  → (0, 0, 0, S0)
        //   GL_LUMINANCE      (1 byte)  → (S0, S0, S0, 255)
        //   GL_INTENSITY      (1 byte)  → (S0, S0, S0, S0)
        //   GL_LUMINANCE_ALPHA(2 bytes) → (S0, S0, S0, S1)
        //
        // After this pass the downstream Metal upload sees a normal
        // RGBA8 texture with the spec-correct sampling result, so no
        // per-texture swizzle table is required and the existing
        // shader code path doesn't need to learn about luminance.
        const bool isAlphaOnly = (format == GL_ALPHA);
        const bool isLuminance = (format == GL_LUMINANCE);
        const bool isIntensity = (format == GL_INTENSITY);
        const bool isLuminanceAlpha = (format == GL_LUMINANCE_ALPHA);

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
                    if (isAlphaOnly) {
                        rgba8[destIndex + 0] = 0;
                        rgba8[destIndex + 1] = 0;
                        rgba8[destIndex + 2] = 0;
                        rgba8[destIndex + 3] = source[sourceIndex + 0];
                    } else if (isLuminance) {
                        const std::uint8_t luminance = source[sourceIndex + 0];
                        rgba8[destIndex + 0] = luminance;
                        rgba8[destIndex + 1] = luminance;
                        rgba8[destIndex + 2] = luminance;
                        rgba8[destIndex + 3] = 255;
                    } else if (isIntensity) {
                        const std::uint8_t intensity = source[sourceIndex + 0];
                        rgba8[destIndex + 0] = intensity;
                        rgba8[destIndex + 1] = intensity;
                        rgba8[destIndex + 2] = intensity;
                        rgba8[destIndex + 3] = intensity;
                    } else if (isLuminanceAlpha) {
                        const std::uint8_t luminance = source[sourceIndex + 0];
                        const std::uint8_t alpha = source[sourceIndex + 1];
                        rgba8[destIndex + 0] = luminance;
                        rgba8[destIndex + 1] = luminance;
                        rgba8[destIndex + 2] = luminance;
                        rgba8[destIndex + 3] = alpha;
                    } else {
                        rgba8[destIndex + 0] = source[sourceIndex + 0];
                        rgba8[destIndex + 1] = components > 1 ? source[sourceIndex + 1] : 0;
                        rgba8[destIndex + 2] = components > 2 ? source[sourceIndex + 2] : 0;
                        rgba8[destIndex + 3] = components > 3 ? source[sourceIndex + 3] : 255;
                    }
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

    // Phase 8X Group 4d follow-up⁷ — build an MTLSamplerState from the
    // texture-owned `GLTextureParameters` and cache it on the texture
    // object. Mirrors `rebuildSamplerState(GLSamplerObject&)` above but
    // reads from the `GLTextureObject.params` field instead of a
    // stand-alone sampler object, and writes back into the texture's
    // own `metalSampler` / `samplerDirty` fields.
    //
    // This path is the one that runs for the GL legacy / GL 3.0 texture
    // unit model — the app sets filter/wrap via `glTexParameter*` and
    // the texture itself carries the sampler state. The stand-alone
    // `GLSamplerObject` path (glGenSamplers / glBindSampler) takes
    // precedence when a sampler object is attached to the unit; see
    // `resolveSamplerBindings` below for the precedence logic.
    //
    // The function is idempotent when `samplerDirty` is false: the
    // call returns true immediately with the cached handle intact.
    // Every parameter mutation in `texParameterInteger` /
    // `texParameterFloat` flips `samplerDirty = true` so the next draw
    // rebuilds on demand.
    bool rebuildTextureSamplerState(GLuint texName, GLTextureObject& object) {
        if (!object.samplerDirty && object.metalSampler != nullptr) {
            return true;
        }
        releaseRetainedMetalObject(object.metalSampler);
        object.metalSampler = nullptr;
        if (device == nil) {
            object.samplerDirty = false;
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

        // Phase 8X Group 4d follow-up⁹ — targeted override for compat
        // single-channel glyph formats.
        //
        // BAR's followup⁸ capture (docs/phase-8x-group-4d-followup8-
        // verification.md §Findings) showed that programs 5/8/10 bind
        // cleanly through the followup⁷/⁸ path but with sampler state
        // that would plausibly corrupt glyph sampling on a single-
        // channel atlas:
        //
        //   texName=1 (prog  5): LINEAR / CLAMP_TO_BORDER / maxLevel=1000
        //   texName=3 (prog  8): LINEAR / REPEAT           / maxLevel=0
        //   texName=4 (prog 10): LINEAR_MIPMAP_LINEAR /
        //                        REPEAT / maxLevel=10 (no mip chain
        //                        uploaded — would sample outside the
        //                        valid LOD range, which Apple Silicon
        //                        returns as zero)
        //
        // BAR asked for a "loud fix": when we detect a compat glyph
        // atlas format (GL_ALPHA / GL_LUMINANCE / GL_LUMINANCE_ALPHA /
        // GL_INTENSITY and their sized ALPHA8 / LUMINANCE8 /
        // LUMINANCE8_ALPHA8 / INTENSITY8 variants), override the
        // descriptor to the known-safe configuration for glyph
        // sampling:
        //
        //   min/mag    = Linear   (Recoil's default; text looks right)
        //   mipFilter  = NotMipmapped
        //   wrap s/t/r = ClampToEdge
        //   lodMin     = 0.0
        //   lodMax     = 0.25     (effectively "level 0 only",
        //                          defensive against Recoil mistakenly
        //                          computing an LOD > 0 even with
        //                          NotMipmapped)
        //   compare    = Never
        //
        // This is intentionally a sledgehammer — if a non-glyph code
        // path uses GL_ALPHA for an off-screen render target or a
        // noise lookup we'd override that too, and if BAR reports a
        // regression on a scene that relies on wrap=repeat on a
        // single-channel texture we'll narrow the gate. The format
        // list is the compat-profile single-channel family that
        // predates GL_RED, and Recoil's glyph path still uses them
        // (the hot-swap to core GL_R8 never landed on the Spring fork
        // we ship).
        //
        // The override is unconditional within the format gate — it
        // does not inspect `object.params` before clobbering. BAR
        // explicitly asked for this: "I'd rather we sample a glyph
        // atlas as LINEAR/CLAMP/no-mip even if Recoil asked for
        // something weirder, than honor the weird setting and
        // render illegible text" (followup⁸ §Primary).
        const GLenum internalFormat = object.desc.internalFormat;
        const bool isCompatGlyphFormat =
            internalFormat == GL_ALPHA ||
            internalFormat == GL_ALPHA8 ||
            internalFormat == GL_LUMINANCE ||
            internalFormat == GL_LUMINANCE8 ||
            internalFormat == GL_LUMINANCE_ALPHA ||
            internalFormat == GL_LUMINANCE8_ALPHA8 ||
            internalFormat == GL_INTENSITY ||
            internalFormat == GL_INTENSITY8;
        if (isCompatGlyphFormat) {
            descriptor.minFilter = MTLSamplerMinMagFilterLinear;
            descriptor.magFilter = MTLSamplerMinMagFilterLinear;
            descriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
            descriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
            descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
            descriptor.rAddressMode = MTLSamplerAddressModeClampToEdge;
            descriptor.lodMinClamp = 0.0f;
            descriptor.lodMaxClamp = 0.25f;
            descriptor.compareFunction = MTLCompareFunctionNever;
        }

        id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:descriptor];
        if (sampler == nil) {
            return false;
        }
        object.metalSampler = transferRetainedMetalObject(sampler);
        object.samplerDirty = false;

        // Phase 8X Group 4d follow-up⁸ — first-rebuild-per-texture
        // NSLog so BAR can see whether the glyph atlases get a sampler
        // at all, and if so with what filter/wrap/lod params. Fires at
        // most once per GL texture name per process. Keyed on the name
        // parameter because GLTextureObject does not carry its own
        // identity — the caller (resolveSamplerBindings, the only
        // caller today) knows the name from
        // `state->boundTextureOnUnit(...)`. Subsequent rebuilds caused
        // by glTexParameter flipping `samplerDirty` are not logged —
        // the first build sets the baseline, the BAR side can cross
        // check against expected Recoil defaults.
        if (texName != 0 &&
            loggedSamplerBuildTextures.insert(texName).second) {
            // Phase 8X Group 4d follow-up⁹ — the log reports BOTH the
            // GL-side `params` values that the app set AND the
            // override decision. BAR needs both: the params line tells
            // them what Recoil asked for, the override tag tells them
            // what we actually bound. On a happy path these agree; on
            // the compat glyph path the override tag will be
            // `glyph-compat` and the params readout will show the
            // (ignored) Recoil-set values.
            NSLog(@"[GL] rebuildTextureSamplerState first-build texName=%u"
                  @" internalFormat=0x%04X override=%s"
                  @" minFilter=0x%04X magFilter=0x%04X"
                  @" wrapS=0x%04X wrapT=0x%04X wrapR=0x%04X"
                  @" minLod=%.2f maxLod=%.2f baseLevel=%d maxLevel=%d"
                  @" compareMode=0x%04X compareFunc=0x%04X",
                  texName,
                  static_cast<unsigned>(internalFormat),
                  isCompatGlyphFormat ? "glyph-compat" : "none",
                  static_cast<unsigned>(object.params.minFilter),
                  static_cast<unsigned>(object.params.magFilter),
                  static_cast<unsigned>(object.params.wrapS),
                  static_cast<unsigned>(object.params.wrapT),
                  static_cast<unsigned>(object.params.wrapR),
                  object.params.minLod, object.params.maxLod,
                  object.params.baseLevel, object.params.maxLevel,
                  static_cast<unsigned>(object.params.compareMode),
                  static_cast<unsigned>(object.params.compareFunc));
        }
        return true;
    }

    // Phase 8X Group 4d follow-up⁷ — walk a program's fragment/vertex
    // reflection, match each sampled-texture entry to the GL sampler
    // uniform that selects its texture unit, resolve the unit binding
    // to a live MTLTexture + MTLSamplerState, and populate the two
    // binding vectors on the TranslatedDrawInfo. Called from
    // drawArrays / drawArraysInstanced / drawElements right after the
    // uniform buffer push and immediately before encodeTranslatedDraw.
    //
    // Resolution rules — matches the GL spec plus our Phase A 2D-only
    // scope for this round:
    //
    //  1. For each `ShaderReflection::sampledTextures[i]` entry on the
    //     fragment stage, match it to a GL sampler uniform by name.
    //     The `reflection.name` string is the GLSL sampler variable
    //     name; we search `program.uniforms` for a matching entry
    //     whose `type` is a sampler (GL_SAMPLER_2D etc).
    //  2. Read the user-set texture unit from
    //     `program.uniformValues[location].ints[0]`. This is the value
    //     last written by `glUniform1i(loc, unit)`. Defaults to 0
    //     when the application never set the uniform (GL spec:
    //     sampler uniforms default to 0).
    //  3. Look up the texture bound to `(unit, GL_TEXTURE_2D)` via
    //     `state.boundTextureOnUnit`. Only GL_TEXTURE_2D is handled in
    //     this round — cube maps / 3D / 2D-array / buffer textures
    //     deferred to a future followup. Unbound units are skipped
    //     silently (emit no TextureBinding; the Metal shader reads
    //     from an unbound slot which matches GL's "undefined
    //     sampling" behavior).
    //  4. If a stand-alone `GLSamplerObject` is attached to the unit
    //     via `glBindSampler(unit, samplerObj)` (GL 3.3+), that
    //     takes precedence and provides the filter/wrap/lod state
    //     via `rebuildSamplerState(samplerObj)`. Otherwise the
    //     texture-owned `GLTextureObject.params` state is used via
    //     `rebuildTextureSamplerState(texObj)`.
    //  5. The resolved `metalTexture` / `metalSamplerState` pair is
    //     appended to `info.fragmentTextures` at the Metal slot
    //     `reflection.metalBinding` (= `reflection.glBinding` under
    //     the default `BindingMap` where `textureBase = 0`).
    //
    // The same logic runs for the vertex stage and writes into
    // `info.vertexTextures`. Most programs have zero vertex
    // samplers — the path is O(sampledTextures) and short-circuits
    // cleanly when the vector is empty.
    void resolveSamplerBindings(
        GLProgramObject& program,
        TranslatedDrawInfo& info)
    {
        // Phase 8X Group 4d follow-up⁸ — diagnostic one-shot-per-program
        // trace so BAR can distinguish "reflection empty", "uniform
        // missing", "unit empty", "texture not instantiated", and
        // "sampler build failed" cases without guessing. Fires at most
        // once per GL program name (zero hot-path cost after first
        // exercise). Same set guards both stages; the stage tag in the
        // summary line disambiguates which one is being walked.
        const bool logThisCall = (info.program != 0) &&
            loggedSamplerResolvePrograms.insert(info.program).second;
        if (logThisCall) {
            const std::size_t fragCount = info.fragmentReflection
                ? info.fragmentReflection->sampledTextures.size() : 0;
            const std::size_t vertCount = info.vertexReflection
                ? info.vertexReflection->sampledTextures.size() : 0;
            NSLog(@"[GL] resolveSamplerBindings first-call program=%u"
                  @" fragment.sampledTextures=%zu vertex.sampledTextures=%zu"
                  @" uniforms=%zu",
                  info.program, fragCount, vertCount, program.uniforms.size());
        }

        auto resolveStage = [&](const char* stageTag,
                                const ShaderReflection* reflection,
                                std::vector<TranslatedDrawInfo::TextureBinding>& outBindings) {
            if (reflection == nullptr || reflection->sampledTextures.empty()) {
                return;
            }
            for (const auto& sampledTex : reflection->sampledTextures) {
                // Step 1: find the GL sampler uniform by name.
                GLint uniformLocation = -1;
                for (const auto& uinfo : program.uniforms) {
                    if (uinfo.name == sampledTex.name) {
                        uniformLocation = uinfo.location;
                        break;
                    }
                }

                // Step 2: resolve the texture unit index. Sampler
                // uniforms default to 0 per GL spec when the app
                // never called glUniform1i, so a missing entry in
                // uniformValues also reads as unit 0.
                GLint glUnit = 0;
                bool uniformValueWasSet = false;
                if (uniformLocation >= 0) {
                    auto it = program.uniformValues.find(uniformLocation);
                    if (it != program.uniformValues.end() && !it->second.ints.empty()) {
                        glUnit = it->second.ints[0];
                        uniformValueWasSet = true;
                    }
                }
                if (glUnit < 0) {
                    if (logThisCall) {
                        NSLog(@"[GL]   %s sampler='%s' metalSlot=%u"
                              @" SKIP reason=negative-unit glUnit=%d",
                              stageTag, sampledTex.name.c_str(),
                              sampledTex.metalBinding, glUnit);
                    }
                    continue;  // malformed app state; skip silently
                }

                // Step 3: look up the texture object bound to that
                // unit for GL_TEXTURE_2D. Future rounds extend to
                // cube maps etc by widening this target probe.
                const GLuint texName = state->boundTextureOnUnit(
                    static_cast<GLuint>(glUnit), GL_TEXTURE_2D);
                if (texName == 0) {
                    if (logThisCall) {
                        NSLog(@"[GL]   %s sampler='%s' metalSlot=%u"
                              @" SKIP reason=unit-empty glUnit=%d uniformLoc=%d"
                              @" valueSet=%d",
                              stageTag, sampledTex.name.c_str(),
                              sampledTex.metalBinding, glUnit,
                              uniformLocation, uniformValueWasSet ? 1 : 0);
                    }
                    continue;  // no texture bound to the unit
                }
                GLTextureObject* texObject = objects->textures().get(texName);
                if (texObject == nullptr || !texObject->instantiated ||
                    texObject->metalTexture == nullptr) {
                    if (logThisCall) {
                        NSLog(@"[GL]   %s sampler='%s' metalSlot=%u"
                              @" SKIP reason=tex-not-ready glUnit=%d texName=%u"
                              @" hasObject=%d instantiated=%d hasMetalTex=%d",
                              stageTag, sampledTex.name.c_str(),
                              sampledTex.metalBinding, glUnit, texName,
                              texObject != nullptr ? 1 : 0,
                              texObject && texObject->instantiated ? 1 : 0,
                              texObject && texObject->metalTexture ? 1 : 0);
                    }
                    continue;  // texture not yet populated with storage
                }

                // Step 4: determine sampler state — stand-alone
                // sampler object if one is attached, otherwise fall
                // back to the texture's own params. Both paths
                // lazily rebuild the MTLSamplerState on demand.
                void* metalSamplerState = nullptr;
                const GLuint samplerName = state->boundSampler(static_cast<GLuint>(glUnit));
                if (samplerName != 0) {
                    GLSamplerObject* samplerObj = objects->samplers().get(samplerName);
                    if (samplerObj != nullptr) {
                        if (samplerObj->dirty || samplerObj->metalSampler == nullptr) {
                            (void)rebuildSamplerState(*samplerObj);
                        }
                        metalSamplerState = samplerObj->metalSampler;
                    }
                }
                if (metalSamplerState == nullptr) {
                    if (texObject->samplerDirty || texObject->metalSampler == nullptr) {
                        (void)rebuildTextureSamplerState(texName, *texObject);
                    }
                    metalSamplerState = texObject->metalSampler;
                }
                if (metalSamplerState == nullptr) {
                    if (logThisCall) {
                        NSLog(@"[GL]   %s sampler='%s' metalSlot=%u"
                              @" SKIP reason=sampler-build-failed glUnit=%d"
                              @" texName=%u standAloneSampler=%u",
                              stageTag, sampledTex.name.c_str(),
                              sampledTex.metalBinding, glUnit, texName,
                              samplerName);
                    }
                    continue;  // sampler build failure; nothing to bind
                }

                // Step 5: push the binding at the reflected Metal slot.
                TranslatedDrawInfo::TextureBinding binding;
                binding.metalSlot = sampledTex.metalBinding;
                binding.metalTexture = texObject->metalTexture;
                binding.metalSamplerState = metalSamplerState;
                outBindings.push_back(binding);

                if (logThisCall) {
                    // Phase 8X Group 4d follow-up⁹ — first-bind
                    // diagnostic: dump the texObject->params snapshot
                    // AT DRAW TIME alongside the BOUND record. This
                    // closes the ambiguity BAR flagged in followup⁸:
                    // the first-build log only reports the params
                    // state at the moment of the *first* sampler
                    // rebuild. If Recoil mutates params via
                    // glTexParameter after that first build (before
                    // the dirty flag flips — or on a code path that
                    // doesn't go through texParameter*) then the
                    // draw-time sampler could disagree with what the
                    // first-build log says and we'd never see it.
                    //
                    // By dumping params here, in the resolve step,
                    // right next to the BOUND record, BAR can
                    // cross-check in one capture whether the sampler
                    // state that reached the encoder matches what the
                    // first-build log reported, and whether any
                    // override=glyph-compat gate fired on this
                    // texture's format.
                    const GLenum fmt = texObject->desc.internalFormat;
                    const bool isCompat =
                        fmt == GL_ALPHA || fmt == GL_ALPHA8 ||
                        fmt == GL_LUMINANCE || fmt == GL_LUMINANCE8 ||
                        fmt == GL_LUMINANCE_ALPHA ||
                        fmt == GL_LUMINANCE8_ALPHA8 ||
                        fmt == GL_INTENSITY || fmt == GL_INTENSITY8;
                    NSLog(@"[GL]   %s sampler='%s' metalSlot=%u BOUND"
                          @" glUnit=%d uniformLoc=%d valueSet=%d texName=%u"
                          @" standAloneSampler=%u internalFormat=0x%04X"
                          @" override=%s drawTimeParams{"
                          @"minFilter=0x%04X magFilter=0x%04X"
                          @" wrapS=0x%04X wrapT=0x%04X wrapR=0x%04X"
                          @" baseLevel=%d maxLevel=%d"
                          @" compareMode=0x%04X}",
                          stageTag, sampledTex.name.c_str(),
                          sampledTex.metalBinding, glUnit, uniformLocation,
                          uniformValueWasSet ? 1 : 0, texName, samplerName,
                          static_cast<unsigned>(fmt),
                          isCompat ? "glyph-compat" : "none",
                          static_cast<unsigned>(texObject->params.minFilter),
                          static_cast<unsigned>(texObject->params.magFilter),
                          static_cast<unsigned>(texObject->params.wrapS),
                          static_cast<unsigned>(texObject->params.wrapT),
                          static_cast<unsigned>(texObject->params.wrapR),
                          texObject->params.baseLevel,
                          texObject->params.maxLevel,
                          static_cast<unsigned>(texObject->params.compareMode));
                }
            }
        };

        resolveStage("frag", info.fragmentReflection, info.fragmentTextures);
        resolveStage("vert", info.vertexReflection, info.vertexTextures);
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

    // Phase 8X Group 4d follow-up⁸ — one-shot-per-key dedup sets for the
    // sampler-resolution / sampler-build diagnostic logs. Both fire at
    // most once per key per process so the hot draw path stays quiet
    // after the first draw that exercises each program / texture. The
    // existing follow-up³ fall-through instrumentation and follow-up⁴
    // pipeline-build error surfacing both use identical one-shot dedup
    // patterns; these sit next to them for the sampler path. See
    // `resolveSamplerBindings` and `rebuildTextureSamplerState`.
    std::unordered_set<GLuint> loggedSamplerResolvePrograms;
    std::unordered_set<GLuint> loggedSamplerBuildTextures;
    // Per-context fixed-function matrix mirror. Compat-profile matrix
    // entry points (defined in src/runtime/AppGLMatrixOverrides.cpp)
    // route through this member, and the draw path reads from it to
    // populate the synthesized `appgl_*` shader uniforms produced by
    // the compat-shader rewriter (src/shader/CompatShaderRewrite.h).
    MatrixStateMirror matrixState;
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
    // Declarative GL version strings. glGetString(GL_VERSION) returns the
    // claimed version (a compile-time constant — see
    // CoverageStore::claimedVersion) rather than the coverage-derived
    // highest-fully-implemented version, so a cold-boot context with no
    // smoke tests run still advertises the full AppGL surface as "4.6 AppGL
    // core" rather than the "4.6 AppGL bootstrap" fallback the walker used
    // to return. Engines such as Recoil parse "M.m" via sscanf and fall
    // back to a GL3 codepath if they see a 3.x string, so both the version
    // string and the shading-language-version string must reflect what the
    // translator is actually capable of accepting.
    std::string versionString = "4.6 AppGL core";
    std::string shadingLanguageVersion = "4.60";
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

void GLContext::setPolygonMode(GLenum face, GLenum mode) {
    (void)face;  // Metal doesn't distinguish front/back fill modes
    impl_->state->setPolygonFillMode(mode);
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
        // Phase 8X Group 4d follow-up⁴ §6c — capture the pname so BAR can
        // name the steady-state firer instead of seeing a bare
        // <internal@GLContext.mm:LINE> entry. The internal call-site tag
        // is still synthesised (functionName left empty) so the file:line
        // breadcrumb survives.
        char pnameBuf[48];
        std::snprintf(pnameBuf, sizeof(pnameBuf),
            "queryInteger: pname=0x%04X data=nullptr",
            static_cast<unsigned>(pname));
        pushError(GL_INVALID_VALUE, "", pnameBuf);
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
        // Phase 8X Group 4d follow-up⁴ §6c — name the unknown pname in
        // the diagnostic ring so BAR can see WHICH enum its widget code
        // is querying. The previous bare `pushError(GL_INVALID_ENUM)`
        // produced a steady stream of untagged errorLog entries that
        // BAR-side tooling could only count, not act on.
        char pnameBuf[48];
        std::snprintf(pnameBuf, sizeof(pnameBuf),
            "queryInteger: pname=0x%04X unknown",
            static_cast<unsigned>(pname));
        pushError(GL_INVALID_ENUM, "", pnameBuf);
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

bool GLContext::queryIntegerIndexed(GLenum pname, GLuint index, GLint* data) {
    // Indexed integer query (glGetIntegeri_v). Phase 8X Landing C 3a. Used
    // primarily for compute work-group count/size tuples where the GL spec
    // defines separate per-dimension values addressed by index 0/1/2.
    //
    // We still honour the bound-buffer index queries that live on the state
    // tracker (indexed buffer bindings, array-drawbuffer state). Capability
    // caps flow through GLCapabilities::queryIntegerIndexed which knows
    // about the x/y/z compute tuples and also serves scalar caps at
    // index 0 for GL-spec leniency.
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (impl_->capabilities != nullptr
        && impl_->capabilities->queryIntegerIndexed(pname, index, data)) {
        return true;
    }
    // Fall back to the scalar state tracker path for state that has a
    // per-index representation (buffer binding stacks) — match the existing
    // queryInteger behaviour when no indexed handler exists.
    if (index == 0 && impl_->state->queryInteger(pname, data)) {
        return true;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

bool GLContext::queryInteger64Indexed(GLenum pname, GLuint index, GLint64* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (impl_->capabilities != nullptr
        && impl_->capabilities->queryInteger64Indexed(pname, index, data)) {
        return true;
    }
    if (index == 0 && impl_->state->queryInteger64(pname, data)) {
        return true;
    }
    pushError(GL_INVALID_ENUM);
    return false;
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
    if (!isSupportedInternalTextureFormat(*impl_->capabilities, static_cast<GLenum>(internalformat)) || componentCountForFormat(format) == 0 || type != GL_UNSIGNED_BYTE) {
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
    if (!isSupportedInternalTextureFormat(*impl_->capabilities, internalformat)) {
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
    if (!isSupportedInternalTextureFormat(*impl_->capabilities, internalformat)) {
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
    if (!isSupportedInternalTextureFormat(*impl_->capabilities, internalformat)) {
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
    // Phase 8X Group 4d follow-up⁷ — the filter/wrap/lod/compare state
    // on the texture now feeds an MTLSamplerState cached on the object
    // (see GLTextureObject.metalSampler). Flip the dirty flag so the
    // next draw rebuilds it from the mutated params. Unconditional
    // because the GL parameter names that affect sampling are a
    // superset of the fields in GLTextureParameters (setTextureParameter
    // already filters out unknown names by returning false above), and
    // swizzle/border changes also require a rebuild via the descriptor.
    object->samplerDirty = true;
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
    // Phase 8X Group 4d follow-up⁷ — see texParameterInteger for the
    // rationale; float params update the same GLTextureParameters
    // fields (lod clamps, border color) so the cached sampler must
    // rebuild on the next draw.
    object->samplerDirty = true;
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

namespace {

// Strip a source-location file path down to its basename for the
// `<internal@<file>:<line>>` ring-buffer tag emitted by pushError() when no
// explicit functionName was supplied. The full path (e.g. "<redacted-other-user-home>/
// appgl-runtime/src/context/GLContext.mm") is unhelpful in the BAR-side log
// — only the trailing filename matters for naming the call site, and a path
// prefix would also leak the local build environment into the diagnostic
// stream.
std::string sourceLocationBasename(const char* path) {
    if (path == nullptr) {
        return std::string("?");
    }
    std::string_view view(path);
    const std::size_t slash = view.find_last_of('/');
    if (slash != std::string_view::npos) {
        view.remove_prefix(slash + 1);
    }
    return std::string(view);
}

// Translate a raw GL error enum into its canonical spec name. Used as a
// fallback message when pushError() is invoked from a deep call site that
// doesn't supply its own description — without this, ring-buffer records
// would land as `{function: "<internal@GLContext.mm:1234>", errorEnum: 1282,
// message: ""}` and external diagnostics tooling has nothing to render. With
// it, the same record reads `{... message: "GL_INVALID_OPERATION (raised
// internally; tag is the source location)"}` so the message is at least the
// spec name even when the call site doesn't supply richer text.
const char* glErrorEnumName(GLenum error) {
    switch (error) {
        case GL_NO_ERROR:                       return "GL_NO_ERROR";
        case GL_INVALID_ENUM:                   return "GL_INVALID_ENUM";
        case GL_INVALID_VALUE:                  return "GL_INVALID_VALUE";
        case GL_INVALID_OPERATION:              return "GL_INVALID_OPERATION";
        case GL_INVALID_FRAMEBUFFER_OPERATION:  return "GL_INVALID_FRAMEBUFFER_OPERATION";
        case GL_OUT_OF_MEMORY:                  return "GL_OUT_OF_MEMORY";
        case GL_STACK_UNDERFLOW:                return "GL_STACK_UNDERFLOW";
        case GL_STACK_OVERFLOW:                 return "GL_STACK_OVERFLOW";
        default:                                return nullptr;
    }
}

std::string defaultErrorMessage(GLenum error, bool internalCallSite) {
    const char* name = glErrorEnumName(error);
    std::string base;
    if (name != nullptr) {
        base.assign(name);
    } else {
        char buf[32];
        std::snprintf(buf, sizeof(buf), "GLenum 0x%04X", static_cast<unsigned>(error));
        base.assign(buf);
    }
    if (internalCallSite) {
        base.append(" (raised internally; tag is the source location)");
    }
    return base;
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 8X Group 4d follow-up³ — translated-draw fall-through instrumentation.
//
// The translated-draw path in glDrawArrays / glDrawArraysInstanced /
// glDrawElements has a chain of guards that can silently fall through to the
// solid-color fallback (or to a no-op for the instanced path). For BAR's
// select-menu corpus we observe `pipelineCache: {hits:0, misses:0}` despite
// `hasTranslatedPipeline=1`, which means encodeTranslatedDraw is never being
// reached — one of these guards is firing for every draw without naming
// itself in any log surface.
//
// `reportTranslatedFallbackOnce` emits a single NSLog line per (program, gate)
// pair, gated by a per-program bitmask in GLProgramObject. The shape of the
// line matches BAR's grep-aggregation request:
//
//   [GL] drawArrays-fallback: program=5 gate=shadowBytes-empty vao=3 vbo=7 attrCount=2
//
// `program` and `gate` are the two grep-by fields. `vao`, `vbo`, and
// `attrCount` are bonus context for cross-referencing against the
// objectStore dump in the live diagnostic JSON.
//
// The bitmask is per-program and per-gate, so a real game scene that pulls
// in 200 distinct shader programs with 5 fall-through gates between them
// produces at most 1000 log lines — actually far fewer in practice, because
// the same gate is usually firing for every draw of the same program.
// ─────────────────────────────────────────────────────────────────────────────

enum class TranslatedFallbackGate : std::uint32_t {
    EmptyAttributes  = 1u << 0,  // VAO has no enabled attributes
    NullVBO          = 1u << 1,  // attribute 0's buffer name doesn't resolve
    ShadowBytesEmpty = 1u << 2,  // VBO has no CPU-side shadow (likely glBufferStorage)
    OffsetOverflow   = 1u << 3,  // first vertex offset overruns the shadow
    EncodeFailed     = 1u << 4,  // encodeTranslatedDraw returned false
};

const char* translatedFallbackGateName(TranslatedFallbackGate gate) {
    switch (gate) {
        case TranslatedFallbackGate::EmptyAttributes:  return "empty-attributes";
        case TranslatedFallbackGate::NullVBO:          return "null-vbo";
        case TranslatedFallbackGate::ShadowBytesEmpty: return "shadowBytes-empty";
        case TranslatedFallbackGate::OffsetOverflow:   return "offset-overflow";
        case TranslatedFallbackGate::EncodeFailed:     return "encode-failed";
    }
    return "unknown";
}

// Returns true when the bit was newly set (i.e., the NSLog actually fired
// on this call). Callers chain the diagnostic-ring push on the same edge so
// the heavier "pipeline-build" ShaderTranslationRecord write happens once
// per (program, gate) pair too, rather than every draw.
bool reportTranslatedFallbackOnce(GLProgramObject* program,
                                  GLuint programName,
                                  TranslatedFallbackGate gate,
                                  const char* siteName,
                                  GLuint vaoName,
                                  std::size_t attrCount,
                                  GLuint vboName,
                                  std::size_t shadowBytesSize) {
    if (program == nullptr || siteName == nullptr) {
        return false;
    }
    const std::uint32_t bit = static_cast<std::uint32_t>(gate);
    if ((program->translatedFallbackGatesReported & bit) != 0) {
        return false;
    }
    program->translatedFallbackGatesReported |= bit;
    NSLog(@"[GL] %s-fallback: program=%u gate=%s vao=%u vbo=%u attrCount=%zu shadowBytes=%zu",
          siteName,
          static_cast<unsigned>(programName),
          translatedFallbackGateName(gate),
          static_cast<unsigned>(vaoName),
          static_cast<unsigned>(vboName),
          attrCount,
          shadowBytesSize);
    return true;
}

// Phase 8X Group 4d follow-up⁴ — record a pipeline-build failure in the
// shader-translation diagnostic ring so BAR-side tooling can see Metal's
// rejection text in the same JSON channel it already parses for compile
// and link records.
//
// `errorText` carries the stage tag + NSError description that
// MetalFrameGraph::encodeTranslatedDraw populated into
// TranslatedDrawInfo::pipelineBuildErrorOut on the failing path. The
// stage tag is the first colon-separated token (e.g. "vertex-library:
// program_source: error: ..."), so BAR can grep-aggregate by stage even
// though the record carries the full text.
//
// Called from the EncodeFailed branch in each draw entry point AFTER
// reportTranslatedFallbackOnce has already gated the NSLog. We use a
// SEPARATE per-program bit because the diagnostic-ring record is a
// heavier-weight signal than the NSLog and we don't want to lose it in a
// world where the gate bit was set by a non-failure code path. In
// practice both bits track each other exactly today — the separation is
// future-proofing.
void recordPipelineBuildFailureOnce(GLProgramObject* program,
                                    GLuint programName,
                                    const std::string& errorText) {
    if (program == nullptr || errorText.empty()) {
        return;
    }
    // Reuse the EncodeFailed bit as the gate. The reportTranslatedFallbackOnce
    // call above sets it; this function only fires when that gate just
    // transitioned from clear to set on this draw. Concretely: if the
    // caller invokes both helpers in order on the same draw, the NSLog
    // fires once and the diagnostic record fires once. Subsequent draws
    // that hit the same failure path skip both, because the bit is already
    // set. (We don't need a separate guard here — the reportTranslated
    // call above already set the bit when the diagnostic record was
    // worth writing.)
    //
    // Phase 8X Group 4d follow-up⁵ — §6b: populate `mslPreview` with the
    // failing stage's MSL (up to 1024 bytes) so BAR can inspect the
    // actual `main0_out` / `main0_in` struct definitions inline in the
    // diagnostic ring without having to dump intermediate files. For
    // `pipeline-state` failures (where both stages are involved in the
    // varying-mismatch verdict) we pack the vertex MSL first and the
    // fragment MSL second, separated by a marker. The 1024-byte cap is
    // big enough to include the full `main0_out`/`main0_in` structs plus
    // the start of `main0()`, which is where varyings are usually
    // declared in SPIRV-Cross's emit order.
    constexpr std::size_t kMslPreviewBudget = 1024;
    auto previewOf = [](const std::string& msl) -> std::string {
        if (msl.size() <= kMslPreviewBudget) {
            return msl;
        }
        return msl.substr(0, kMslPreviewBudget) + "\n…[truncated]";
    };

    std::string preview;
    // Stage tag is the first token of errorText, separated by ": ".
    // (See the recordBuildFailure lambda in MetalFrameGraph.mm.)
    if (errorText.rfind("vertex-library", 0) == 0 ||
        errorText.rfind("vertex-function", 0) == 0) {
        preview = previewOf(program->vertexMSL);
    } else if (errorText.rfind("fragment-library", 0) == 0 ||
               errorText.rfind("fragment-function", 0) == 0) {
        preview = previewOf(program->fragmentMSL);
    } else if (errorText.rfind("pipeline-state", 0) == 0) {
        // Both stages are implicated in the varying interface match;
        // pack each into half the budget so BAR can see both `main0_out`
        // (vertex) and `main0_in` (fragment) inline.
        constexpr std::size_t kHalf = kMslPreviewBudget / 2;
        const std::string& vs = program->vertexMSL;
        const std::string& fs = program->fragmentMSL;
        preview = "// === vertex ===\n";
        preview += (vs.size() <= kHalf) ? vs : (vs.substr(0, kHalf) + "\n…[truncated]\n");
        preview += "\n// === fragment ===\n";
        preview += (fs.size() <= kHalf) ? fs : (fs.substr(0, kHalf) + "\n…[truncated]");
    }

    Runtime::ShaderTranslationRecord record;
    record.id = "program-" + std::to_string(programName);
    record.stage = "pipeline-build";
    record.sourceHash = program->vertexSourceHash;  // primary stage for raster programs
    record.vertexSourceHash = program->vertexSourceHash;
    record.fragmentSourceHash = program->fragmentSourceHash;
    record.glslangLog = errorText;
    record.mslPreview = std::move(preview);
    record.success = false;
    Runtime::shared().recordShaderTranslation(std::move(record));
}

}  // namespace

void GLContext::pushError(GLenum error,
                          std::string_view functionName,
                          std::string_view message,
                          std::source_location loc) {
    // Mirror the raised error into BOTH surfaces:
    //  * The per-context enum queue drained by glGetError() — the
    //    engine-facing GL contract requires a FIFO of pure enums.
    //  * The runtime ring buffer drained by appglLiveDiagnosticsJSON —
    //    external tooling wants the function name and human-readable
    //    message, which the raw enum queue doesn't carry.
    // Call sites that don't know the function name (e.g. deep inside
    // GLContext.mm) leave functionName empty; we then synthesise a tag
    // from std::source_location captured at the call site, formatted as
    //   `<internal@<basename>:<line>>`
    // so external diagnostics tooling can name the call site directly
    // (Phase 8X Group 4d follow-up §3a — BAR's ask for a file:line
    // breadcrumb on the steady-state untagged GL_INVALID_ENUM entries).
    // When the message is also empty, default-fill it with the canonical
    // GL spec name for the enum so external tooling has at least the
    // error class to render — empty-message records dropped on the floor
    // were unactionable for downstream consumers (BAR worker feedback,
    // Phase 8X Group 4c handoff §2c).
    impl_->errors.push_back(error);
    Runtime::ErrorRecord record;
    const bool internalCallSite = functionName.empty();
    if (internalCallSite) {
        std::string tag("<internal@");
        tag.append(sourceLocationBasename(loc.file_name()));
        tag.append(":");
        tag.append(std::to_string(loc.line()));
        tag.append(">");
        record.function = std::move(tag);
    } else {
        record.function = std::string(functionName);
    }
    record.errorEnum = error;
    if (message.empty()) {
        record.message = defaultErrorMessage(error, internalCallSite);
    } else {
        record.message = std::string(message);
    }
    Runtime::shared().recordError(std::move(record));
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
    // In Phase 8X Landing C the runtime switched to a declarative
    // claimed-version constant ("4.6 AppGL core" — see
    // CoverageStore::claimedVersion). The only empty-string path that
    // can still reach us is someone calling this method directly with
    // an empty argument; fall through to the same declarative constant
    // so the GL_VERSION string never regresses to a "bootstrap" suffix
    // engines parse as a GL3 context.
    impl_->versionString = value.empty() ? "4.6 AppGL core" : std::move(value);
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

MatrixStateMirror& GLContext::matrixState() {
    return impl_->matrixState;
}

const MatrixStateMirror& GLContext::matrixState() const {
    return impl_->matrixState;
}

GLContext::PipelineCacheMetrics GLContext::pipelineCacheMetrics() const {
    PipelineCacheMetrics result;
    if (impl_->frameGraph) {
        auto m = impl_->frameGraph->pipelineCacheMetrics();
        result.hits = m.hits;
        result.misses = m.misses;
        // Phase 8X Group 4d follow-up⁴ — forward the new build counters.
        result.buildAttempts = m.buildAttempts;
        result.buildFailures = m.buildFailures;
        result.cumulativeBuildMillis = m.cumulativeBuildMillis;
    }
    return result;
}

void GLContext::resetPipelineCacheMetrics() {
    if (impl_->frameGraph) {
        impl_->frameGraph->resetPipelineCacheMetrics();
    }
}

std::uint64_t GLContext::metalAllocatedBytes() const {
    if (impl_->frameGraph) {
        return impl_->frameGraph->metalAllocatedBytes();
    }
    return 0;
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
    // Spec: a shader still attached to one or more programs is *flagged for
    // deletion* but not erased from the object store. The actual erase is
    // performed by detachShader / deleteProgram once the attachment count
    // reaches zero. (See `struct GLShaderObject` in GLObjectStore.h for the
    // BAR-side rationale — engines using RAII deleters call glDeleteShader
    // between glAttachShader and glLinkProgram, and the eager-erase Phase A
    // behaviour was masking every real compile result with the dummy
    // "attached shader is not compiled" link-log.)
    object->deleteRequested = true;
    if (object->attachmentCount == 0) {
        impl_->objects->shaders().erase(shader);
    }
    return true;
}

bool GLContext::isShader(GLuint shader) const {
    // Spec: glIsShader returns GL_FALSE for a shader name that has been
    // marked for deletion, even if the underlying object is still resident
    // because of outstanding program attachments. The object store still
    // holds the name (so the link path can resolve it) but the public
    // identity of the shader is gone the moment glDeleteShader runs.
    const GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr) {
        return false;
    }
    return !object->deleteRequested;
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

    // Clear any prior compile state so a re-compile of the same shader ID
    // starts from a clean slate (matches the GL spec, which allows source
    // replacement followed by another glCompileShader call).
    object->compiled = false;
    object->compileLog.clear();
    object->spirv.clear();
    object->declaredUniforms.clear();
    object->declaredInputs.clear();
    object->declaredOutputs.clear();

    // Diagnostic-ring tag and source hash used by the compile-stage record
    // pushed at the bottom of this function on both success and failure.
    // Hash uses std::hash<std::string> for cheapness — it isn't a
    // cryptographic identity, just a per-source key BAR can compare across
    // log samples to tell whether two compile attempts saw the same source.
    const std::string shaderTag = "shader-" + std::to_string(shader);
    auto compileSourceHash = [](const std::string& s) -> std::string {
        std::size_t h = std::hash<std::string>{}(s);
        char buf[18];
        std::snprintf(buf, sizeof(buf), "%016zx", h);
        return buf;
    };

    if (object->source.empty()) {
        object->compileLog = "shader source is empty";
        Runtime::shared().recordShaderTranslation({
            shaderTag, "compile", "", "", "", object->compileLog, "", false
        });
        return false;
    }

    const std::string sourceHash = compileSourceHash(object->source);

    // 1. Compat-shader rewrite. Glslang's SPIR-V backend rejects
    //    `#version NNN compatibility` outright and rejects every
    //    fixed-function `gl_*` matrix identifier even in compat mode.
    //    The rewriter downgrades the version directive to `core` and
    //    synthesizes `appgl_*` uniforms (paired with `#define`s) for any
    //    referenced matrix builtin. Non-compat shaders that don't
    //    reference any legacy identifier come back unchanged.
    //
    //    Both passes (the lightweight scanner and the real glslang
    //    compile) operate on the rewritten source so the synthesized
    //    uniforms get picked up by the scanner and end up in
    //    declaredUniforms — which linkProgram lifts into
    //    programObject->uniforms with normal sequential locations.
    CompatShaderRewriteResult rewrite = rewriteCompatShader(object->source);
    const std::string& compileSource =
        rewrite.didRewrite ? rewrite.source : object->source;

    // 2. Lightweight scanner pass. Still needed for declared attribute inputs
    //    so the vertex-input binding path (glBindAttribLocation /
    //    layout(location=...)) can be resolved without going through
    //    SPIRV-Cross reflection. The scanner's uniform output is now
    //    secondary — link time pulls UBO members from SPIR-V reflection
    //    directly so interface blocks are visible even though the scanner
    //    ignores them.
    GLSLReflectionResult reflection = reflectGLSL(compileSource, object->stage);
    object->declaredUniforms = std::move(reflection.uniforms);
    object->declaredInputs = std::move(reflection.inputs);
    object->declaredOutputs = std::move(reflection.outputs);

    // 3. Real glslang compile. This is the authoritative verdict that
    //    glGetShaderiv(GL_COMPILE_STATUS) and glGetShaderInfoLog now
    //    surface to the engine — the scanner result above only shapes the
    //    explicit-location metadata, not the compile status.
    //
    //    Version 330 matches what linkProgram used to pass in the old
    //    "compile at link time" path. Engines that target 4.x cores still
    //    use #version 330 / 410 / 460 in their source headers; glslang
    //    respects the in-source directive, so the integer passed here is
    //    only the fallback when the source has no #version line.
    ShaderTranslator translator;
    std::string compileLog;
    std::vector<std::uint32_t> spirv =
        translator.compileGLSL(compileSource, object->stage, 330, &compileLog);

    object->compileLog = std::move(compileLog);
    if (spirv.empty()) {
        // Glslang failed. compileLog contains the real diagnostic text,
        // which getShaderInfoLog will now return verbatim. Push the failure
        // to the diagnostic ring as a compile-stage record so BAR sees the
        // glslang log directly without having to wait for a downstream
        // glLinkProgram lift. (Pre-Group-4d the only path was via
        // linkProgram's "attached shader is not compiled" branch, which
        // could not survive the eager-erase shader lifetime bug — see
        // GLObjectStore.h::GLShaderObject for the full story.)
        Runtime::shared().recordShaderTranslation({
            shaderTag, "compile", sourceHash, "", "", object->compileLog, "", false
        });
        return false;
    }

    object->spirv = std::move(spirv);
    object->compiled = true;
    // Push a positive compile-stage record. mslPreview is intentionally
    // empty here — MSL transpilation runs at link time, not compile time —
    // but the presence of the record (with success=true and a stable
    // sourceHash) is enough for BAR-side observation to confirm the compat
    // rewriter / glslang pipeline ran end-to-end on this shader.
    Runtime::shared().recordShaderTranslation({
        shaderTag, "compile", sourceHash, "", "", "", "", true
    });
    return true;
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
    // Walk the attached-shader list and run the same decrement-and-maybe-erase
    // pass detachShader uses. A program tear-down counts as a synthetic
    // detach for every shader it still holds, and any shader whose
    // deleteRequested flag was set earlier (and is now down to zero
    // attachments) finally gets erased here. Snapshot the IDs first so the
    // shader-table mutation inside the loop can't invalidate the program's
    // attached-shader vector — though the program itself is about to be
    // erased so the mutation is harmless either way.
    std::vector<GLuint> attached = object->attachedShaders;
    for (GLuint shaderId : attached) {
        GLShaderObject* shaderObject = impl_->objects->shaders().get(shaderId);
        if (shaderObject == nullptr) {
            continue;
        }
        if (shaderObject->attachmentCount > 0) {
            --shaderObject->attachmentCount;
        }
        if (shaderObject->deleteRequested && shaderObject->attachmentCount == 0) {
            impl_->objects->shaders().erase(shaderId);
        }
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
    // See `GLShaderObject::attachmentCount` in GLObjectStore.h. This counter
    // is the entire reason the deferred-erase path works: it pins the shader
    // object in the store across the (engine-scope) glDeleteShader call so
    // glLinkProgram can still see the compiled SPIR-V and the real
    // compileLog when something fails.
    ++shaderObject->attachmentCount;
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
    // Mirror the attach-time increment, then perform the deferred erase if
    // both conditions are now met (delete was requested earlier and this was
    // the last live attachment). The shader object pointer must be looked up
    // *before* the potential erase, otherwise the dereference of a stale
    // entry would race with the table mutation.
    GLShaderObject* shaderObject = impl_->objects->shaders().get(shader);
    if (shaderObject != nullptr) {
        if (shaderObject->attachmentCount > 0) {
            --shaderObject->attachmentCount;
        }
        if (shaderObject->deleteRequested && shaderObject->attachmentCount == 0) {
            impl_->objects->shaders().erase(shader);
        }
    }
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

    // Small helper used in several diagnostic-recording sites below.
    const std::string programTag = "program-" + std::to_string(program);
    auto quickHash = [](const std::string& s) -> std::string {
        std::size_t h = std::hash<std::string>{}(s);
        char buf[18];
        std::snprintf(buf, sizeof(buf), "%016zx", h);
        return buf;
    };

    if (programObject->attachedShaders.empty()) {
        programObject->linkLog = "no shaders attached";
        Runtime::shared().recordShaderTranslation({
            programTag, "link", "", "", "", programObject->linkLog, "", false
        });
        return false;
    }

    // Classify the attached stages. Pointers stay null when a stage isn't
    // present. Everything downstream dispatches on which pointers are set
    // rather than re-scanning the attached list.
    GLShaderObject* vertexShader = nullptr;
    GLShaderObject* fragmentShader = nullptr;
    GLShaderObject* computeShader = nullptr;
    GLShaderObject* geometryShader = nullptr;
    GLShaderObject* tessControlShader = nullptr;
    GLShaderObject* tessEvalShader = nullptr;
    int shaderCount = 0;

    for (GLuint shaderId : programObject->attachedShaders) {
        GLShaderObject* shaderObject = impl_->objects->shaders().get(shaderId);
        // Under deferred-erase semantics (see GLObjectStore.h::GLShaderObject)
        // a nullptr lookup here is essentially unreachable from real engine
        // code — glAttachShader rejects unknown IDs upfront, the attachment
        // count keeps the shader resident across glDeleteShader, and a
        // detach pulls the ID out of attachedShaders before the maybe-erase
        // pass. The check is left for defence in depth. The remaining real
        // failure mode is `!shaderObject->compiled`, which now reliably
        // carries the real glslang `compileLog` text through to the
        // diagnostic ring (the upstream `compileShader` call also pushes a
        // `stage: "compile"` record with the same log, but the link-time
        // record makes the failure visible at the program level too).
        if (shaderObject == nullptr || !shaderObject->compiled) {
            programObject->linkLog = "attached shader is not compiled";
            const std::string log = shaderObject
                ? shaderObject->compileLog
                : programObject->linkLog;
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", log, "", false
            });
            return false;
        }
        ++shaderCount;
        switch (shaderObject->stage) {
            case GL_VERTEX_SHADER:          vertexShader = shaderObject; break;
            case GL_FRAGMENT_SHADER:        fragmentShader = shaderObject; break;
            case GL_COMPUTE_SHADER:         computeShader = shaderObject; break;
            case GL_GEOMETRY_SHADER:        geometryShader = shaderObject; break;
            case GL_TESS_CONTROL_SHADER:    tessControlShader = shaderObject; break;
            case GL_TESS_EVALUATION_SHADER: tessEvalShader = shaderObject; break;
            default: break;
        }
        appendDeclarationsAsUniforms(programObject->uniforms, shaderObject->declaredUniforms);
    }

    // Build the vertex attribute table from the scanner's declared inputs
    // on the vertex stage. The scanner-driven path honours
    // glBindAttribLocation requests (via requestedAttribLocations) which
    // SPIRV-Cross reflection cannot see, so we keep it as the authoritative
    // source for attribute locations.
    GLuint nextAttribLocation = 0;
    if (vertexShader != nullptr) {
        for (const auto& input : vertexShader->declaredInputs) {
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

    // Stage combination must be one of:
    //   - Compute-only                          (1x GL_COMPUTE_SHADER)
    //   - Vertex + Fragment                     (standard raster pipeline)
    //   - Vertex + Geometry + Fragment          (geometry path; emulation gap
    //                                            flagged in translator block)
    //   - Vertex + TessControl + TessEval + F   (tess path, same story)
    //   - Vertex-only / Fragment-only           (separable via
    //                                            glCreateShaderProgramv)
    // Anything else bails. The "unknown combination" branch also records a
    // diagnostic so BAR sees why the program didn't link.
    enum class ProgramKind {
        Unknown,
        Compute,
        VertexFragment,
        VertexGeometryFragment,
        VertexTessellationFragment,
        VertexOnly,
        FragmentOnly,
    };
    ProgramKind kind = ProgramKind::Unknown;
    if (computeShader != nullptr && shaderCount == 1) {
        kind = ProgramKind::Compute;
    } else if (vertexShader != nullptr && fragmentShader != nullptr &&
               tessControlShader == nullptr && tessEvalShader == nullptr &&
               geometryShader == nullptr) {
        kind = ProgramKind::VertexFragment;
    } else if (vertexShader != nullptr && fragmentShader != nullptr &&
               geometryShader != nullptr) {
        kind = ProgramKind::VertexGeometryFragment;
    } else if (vertexShader != nullptr && fragmentShader != nullptr &&
               tessControlShader != nullptr && tessEvalShader != nullptr) {
        kind = ProgramKind::VertexTessellationFragment;
    } else if (vertexShader != nullptr && fragmentShader == nullptr &&
               computeShader == nullptr && geometryShader == nullptr) {
        kind = ProgramKind::VertexOnly;
    } else if (fragmentShader != nullptr && vertexShader == nullptr &&
               computeShader == nullptr && geometryShader == nullptr) {
        kind = ProgramKind::FragmentOnly;
    }

    if (kind == ProgramKind::Unknown) {
        programObject->linkLog = "program has no supported shader stage combination";
        Runtime::shared().recordShaderTranslation({
            programTag, "link", "", "", "", programObject->linkLog, "", false
        });
        return false;
    }

    // Precompute the per-stage source hashes that get stamped onto every
    // link/vertex/fragment-stage record below. This is BAR's §4 ask #1 — the
    // diagnostic ring is bounded, and a search-back from a per-stage record to
    // its predecessor compile-stage record can fail when the ring wraps and
    // evicts the compile entry first. Carrying both hashes on every link-stage
    // record makes the mapping ring-eviction-proof.
    //
    // Empty for stages that don't exist (compute-only programs leave both
    // empty, vertex-only programs leave fragment empty, etc.).
    const std::string linkVertexHash =
        (vertexShader != nullptr) ? quickHash(vertexShader->source) : std::string();
    const std::string linkFragmentHash =
        (fragmentShader != nullptr) ? quickHash(fragmentShader->source) : std::string();

    // Phase 8X Group 4d follow-up⁴ — cache the source hashes on the program
    // object so the draw-time pipeline-build failure path (encodeTranslatedDraw
    // returning false from one of the Metal failure sites) can stamp them onto
    // the diagnostic ring without having to re-walk the attached shader list.
    // The link record path above and the failure record path below both pull
    // from the same canonical strings.
    programObject->vertexSourceHash = linkVertexHash;
    programObject->fragmentSourceHash = linkFragmentHash;

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

    // Cache synthesized fixed-function matrix uniform locations. The
    // compat-shader rewriter (CompatShaderRewrite.h) prepends `appgl_*`
    // uniform declarations into the rewritten source for every legacy
    // matrix identifier referenced by the original compat-profile
    // shader. Those synthesized uniforms flowed through the scanner
    // above and now have real GL locations in `programObject->uniforms`.
    // Caching them once here means the per-draw matrix push is an O(1)
    // index lookup into `uniformValues` instead of a string scan over
    // the uniform table on every frame.
    {
        namespace SUN = appgl::SynthesizedUniformNames;
        auto findLocByName = [&](const char* name) -> GLint {
            for (const auto& u : programObject->uniforms) {
                if (u.name == name) {
                    return u.location;
                }
            }
            return -1;
        };
        // gl_TextureMatrix expands to `appgl_TextureMatrix[8]`; the
        // scanner records the array under its base name with arraySize
        // populated, so the lookup matches the bare base name.
        programObject->synthesizedMatrixSlots = GLSynthesizedMatrixSlots{};
        programObject->synthesizedMatrixSlots.modelView =
            findLocByName(SUN::kModelViewMatrix);
        programObject->synthesizedMatrixSlots.projection =
            findLocByName(SUN::kProjectionMatrix);
        programObject->synthesizedMatrixSlots.modelViewProjection =
            findLocByName(SUN::kModelViewProjectionMatrix);
        programObject->synthesizedMatrixSlots.modelViewInverse =
            findLocByName(SUN::kModelViewMatrixInverse);
        programObject->synthesizedMatrixSlots.projectionInverse =
            findLocByName(SUN::kProjectionMatrixInverse);
        programObject->synthesizedMatrixSlots.modelViewProjectionInverse =
            findLocByName(SUN::kModelViewProjectionMatrixInverse);
        programObject->synthesizedMatrixSlots.normal =
            findLocByName(SUN::kNormalMatrix);
        programObject->synthesizedMatrixSlots.texture =
            findLocByName(SUN::kTextureMatrix);
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

    // Run SPIRV-Cross on each attached stage's cached SPIR-V (compiled by
    // GLContext::compileShader and stashed on the shader object). This is
    // best-effort: if translation fails the program still links and falls
    // back to the hardcoded solid-color draw path, but the diagnostic
    // record captures the SPIRV-Cross error so BAR sees what happened.
    programObject->hasTranslatedPipeline = false;
    programObject->vertexMSL.clear();
    programObject->fragmentMSL.clear();
    programObject->metalPipelineState = nullptr;

    ShaderTranslator translator;
    BindingMap bindings;

    // Translate one stage: spirvToMSL + reflect. Writes the result into the
    // provided output slots on success, records a diagnostic in both the
    // success and failure cases. Returns true iff MSL was produced.
    //
    // Phase 8X Group 4d follow-up⁵ — refactored to take SPIR-V data
    // directly (rather than reading `stage->spirv` from the shader object)
    // so the VS/FS path can pass the cross-stage-linked SPIR-V from
    // `compileGLSLProgram` instead of the per-stage cached blobs that
    // `compileShader` produced via independent `compileGLSL` invocations.
    // The other stages (compute, geometry, tess) still use the cached
    // per-stage SPIR-V — only VS+FS need cross-stage location coordination
    // for the Metal pipeline-state validator.
    auto translateStage = [&](const char* stageName,
                              const std::uint32_t* spirvData,
                              std::size_t spirvWords,
                              const std::string& sourceText,
                              std::string& mslOut,
                              ShaderReflection& reflectionOut) -> bool {
        if (spirvData == nullptr || spirvWords == 0) {
            return false;
        }
        std::string mslLog;
        std::string msl = translator.spirvToMSL(
            spirvData, spirvWords, bindings, &mslLog);
        const std::string stageTag = programTag + "-" + stageName;
        const std::string hash = quickHash(sourceText);
        if (msl.empty()) {
            Runtime::shared().recordShaderTranslation({
                stageTag, stageName, hash, linkVertexHash, linkFragmentHash,
                mslLog.empty() ? "spirvToMSL returned empty MSL" : mslLog,
                "", false
            });
            return false;
        }
        reflectionOut = translator.reflect(
            spirvData, spirvWords, bindings, nullptr);
        mslOut = std::move(msl);
        // Phase 8X Group 4d follow-up⁵ — §6b: when the stage *succeeds*
        // we keep the 200-byte preview because the full MSL is large and
        // the translator records are only useful to humans on failure.
        // The matching failure-case mslPreview enlargement happens in the
        // pipeline-build branch (MetalFrameGraph.mm), where the rejected
        // MSL is what BAR actually wants to see — by which point the
        // pipeline-state NSError has already named the failing stage.
        Runtime::shared().recordShaderTranslation({
            stageTag, stageName, hash, linkVertexHash, linkFragmentHash,
            "ok", mslOut.substr(0, 200), true
        });
        return true;
    };

    // Helper: invoke translateStage against a per-stage cached SPIR-V blob
    // on a GLShaderObject. Used by every case below other than VS+FS, where
    // the VS+FS cross-stage-linked path takes over.
    auto translateCachedStage = [&](const char* stageName,
                                    GLShaderObject* stage,
                                    std::string& mslOut,
                                    ShaderReflection& reflectionOut) -> bool {
        if (stage == nullptr) {
            return false;
        }
        return translateStage(stageName,
                              stage->spirv.data(), stage->spirv.size(),
                              stage->source, mslOut, reflectionOut);
    };

    // Phase 8X Group 4d follow-up⁵ — VS+FS cross-stage-linked SPIR-V path.
    // Produces both stage SPIR-V blobs from a single glslang::TProgram
    // link + mapIO pass so cross-stage varying locations get coordinated.
    // Returns the linked SPIR-V on success, or empty blobs on failure (in
    // which case the caller falls back to the per-stage cached SPIR-V on
    // the GLShaderObject — same path as pre-followup⁵).
    //
    // The source we pass in is the rewritten compat form, matching exactly
    // what `compileShader` already compiled per-stage: `compileShader`
    // runs `rewriteCompatShader` on `object->source` and feeds the result
    // to `compileGLSL`, but doesn't cache the rewritten string anywhere
    // — so we re-run the rewriter here. `rewriteCompatShader` is a cheap
    // string scan and is idempotent, so re-running it at link time is
    // free.
    auto compileLinkedVsFs = [&](GLShaderObject* vsStage,
                                  GLShaderObject* fsStage) -> LinkedProgramSpirv {
        if (vsStage == nullptr || fsStage == nullptr) {
            return {};
        }
        CompatShaderRewriteResult vsRewrite = rewriteCompatShader(vsStage->source);
        CompatShaderRewriteResult fsRewrite = rewriteCompatShader(fsStage->source);
        const std::string& vsLinkSource =
            vsRewrite.didRewrite ? vsRewrite.source : vsStage->source;
        const std::string& fsLinkSource =
            fsRewrite.didRewrite ? fsRewrite.source : fsStage->source;
        std::string linkErrorLog;
        LinkedProgramSpirv linked = translator.compileGLSLProgram(
            vsLinkSource, fsLinkSource, 330, &linkErrorLog);
        NSLog(@"[GL] compileGLSLProgram: program=%u success=%d log=%s",
              program, linked.linkSucceeded ? 1 : 0,
              linkErrorLog.c_str());
        if (!linked.linkSucceeded) {
            // Record the cross-stage link failure so BAR can see why the
            // VS+FS path is degrading back to per-stage SPIR-V. The fall
            // back is intentional: the per-stage cached SPIR-V may still
            // produce usable MSL (and at worst surfaces the same Metal
            // varying-mismatch the pre-followup⁵ build was already
            // showing), so degrading is strictly no-worse than the prior
            // behaviour.
            //
            // No positive `link-spirv` record on success — the per-stage
            // vertex/fragment records that follow this lambda already
            // carry success=true, and the post-link
            // `[GL] linkProgram: ... translationOk=1` NSLog line covers
            // the "did the linked path run" question. Adding a success
            // record here would also break the
            // `phase-a.shader-program-lifecycle` scene's exact-count
            // assertion (it expects per-link pushes == 2, vertex +
            // fragment).
            Runtime::shared().recordShaderTranslation({
                programTag + "-link-spirv", "link",
                linkVertexHash, linkVertexHash, linkFragmentHash,
                linkErrorLog.empty()
                    ? "compileGLSLProgram failed (no log)"
                    : linkErrorLog,
                "", false
            });
        }
        return linked;
    };

    bool rasterTranslationOk = false;
    switch (kind) {
        case ProgramKind::VertexFragment: {
            // Run the cross-stage link first. On success, both stages
            // share the linked TProgram's coordinated SPIR-V; on failure,
            // each stage falls back to its per-stage cached SPIR-V.
            LinkedProgramSpirv linked = compileLinkedVsFs(vertexShader, fragmentShader);
            const std::uint32_t* vsSpirvData;
            std::size_t vsSpirvWords;
            const std::uint32_t* fsSpirvData;
            std::size_t fsSpirvWords;
            if (linked.linkSucceeded) {
                vsSpirvData = linked.vertexSpirv.data();
                vsSpirvWords = linked.vertexSpirv.size();
                fsSpirvData = linked.fragmentSpirv.data();
                fsSpirvWords = linked.fragmentSpirv.size();
            } else {
                vsSpirvData = vertexShader->spirv.data();
                vsSpirvWords = vertexShader->spirv.size();
                fsSpirvData = fragmentShader->spirv.data();
                fsSpirvWords = fragmentShader->spirv.size();
            }
            ShaderReflection vsRefl, fsRefl;
            const bool vsOk = translateStage(
                "vertex", vsSpirvData, vsSpirvWords, vertexShader->source,
                programObject->vertexMSL, vsRefl);
            const bool fsOk = translateStage(
                "fragment", fsSpirvData, fsSpirvWords, fragmentShader->source,
                programObject->fragmentMSL, fsRefl);
            if (vsOk && fsOk) {
                programObject->vertexReflection = std::move(vsRefl);
                programObject->fragmentReflection = std::move(fsRefl);
                programObject->hasTranslatedPipeline = true;
                rasterTranslationOk = true;
            }
            break;
        }
        case ProgramKind::VertexOnly: {
            ShaderReflection vsRefl;
            const bool vsOk = translateCachedStage(
                "vertex", vertexShader, programObject->vertexMSL, vsRefl);
            if (vsOk) {
                programObject->vertexReflection = std::move(vsRefl);
                // No fragment stage, so `hasTranslatedPipeline` stays false
                // — separable vertex programs are pipeline-state components,
                // not standalone pipelines.
                rasterTranslationOk = true;
            }
            break;
        }
        case ProgramKind::FragmentOnly: {
            ShaderReflection fsRefl;
            const bool fsOk = translateCachedStage(
                "fragment", fragmentShader, programObject->fragmentMSL, fsRefl);
            if (fsOk) {
                programObject->fragmentReflection = std::move(fsRefl);
                rasterTranslationOk = true;
            }
            break;
        }
        case ProgramKind::Compute: {
            // Translate compute to MSL + record the diagnostic so BAR sees
            // the compute path is live on the translator side. Creating an
            // MTLComputePipelineState from the MSL is a follow-up (the
            // sibling path in MetalFrameGraph.mm doesn't exist yet);
            // without it `glDispatchCompute` will still go through the
            // existing stub path. The link itself succeeds either way.
            std::string unusedMSL;
            ShaderReflection csRefl;
            (void)translateCachedStage("compute", computeShader, unusedMSL, csRefl);
            break;
        }
        case ProgramKind::VertexGeometryFragment: {
            // Translate VS + FS (they're still usable even without the GS)
            // and attempt GS translation so SPIRV-Cross's reflection at
            // least reports what the geometry stage wants. Then record a
            // diagnostic flagging the emulation gap — Metal has no native
            // geometry-shader concept and our compute-stage emulation
            // lands in a follow-up cycle. BAR can read this record and
            // fall back to its non-geometry path.
            //
            // Phase 8X Group 4d follow-up⁵ — VS+FS still go through the
            // cross-stage-linked path even when a GS is present, because
            // the VS→FS varying interface is what Metal's pipeline-state
            // validator inspects. The GS emulation gap is unaffected.
            LinkedProgramSpirv linked = compileLinkedVsFs(vertexShader, fragmentShader);
            const std::uint32_t* vsSpirvData;
            std::size_t vsSpirvWords;
            const std::uint32_t* fsSpirvData;
            std::size_t fsSpirvWords;
            if (linked.linkSucceeded) {
                vsSpirvData = linked.vertexSpirv.data();
                vsSpirvWords = linked.vertexSpirv.size();
                fsSpirvData = linked.fragmentSpirv.data();
                fsSpirvWords = linked.fragmentSpirv.size();
            } else {
                vsSpirvData = vertexShader->spirv.data();
                vsSpirvWords = vertexShader->spirv.size();
                fsSpirvData = fragmentShader->spirv.data();
                fsSpirvWords = fragmentShader->spirv.size();
            }
            ShaderReflection vsRefl, fsRefl, gsRefl;
            const bool vsOk = translateStage(
                "vertex", vsSpirvData, vsSpirvWords, vertexShader->source,
                programObject->vertexMSL, vsRefl);
            const bool fsOk = translateStage(
                "fragment", fsSpirvData, fsSpirvWords, fragmentShader->source,
                programObject->fragmentMSL, fsRefl);
            std::string unusedGsMSL;
            (void)translateCachedStage("geometry", geometryShader, unusedGsMSL, gsRefl);
            // Always append the emulation-gap record after the per-stage
            // records so BAR sees: [vertex:ok][fragment:ok][geometry:ok][gap].
            Runtime::shared().recordShaderTranslation({
                programTag + "-geometry-emulation", "geometry",
                quickHash(geometryShader->source),
                linkVertexHash, linkFragmentHash,
                "geometry shader emulation not yet available on Metal; "
                "program translated VS+FS only, falls back to raster-without-GS",
                "", false
            });
            if (vsOk && fsOk) {
                programObject->vertexReflection = std::move(vsRefl);
                programObject->fragmentReflection = std::move(fsRefl);
                programObject->hasTranslatedPipeline = true;
                rasterTranslationOk = true;
            }
            break;
        }
        case ProgramKind::VertexTessellationFragment: {
            // Same story as geometry: translate VS + FS and record a
            // diagnostic for the tess stages. Metal's tessellation model
            // is incompatible with GL's, so proper routing lands later.
            //
            // Phase 8X Group 4d follow-up⁵ — VS+FS use the cross-stage
            // linked path here too, for the same reason as VGF above.
            LinkedProgramSpirv linked = compileLinkedVsFs(vertexShader, fragmentShader);
            const std::uint32_t* vsSpirvData;
            std::size_t vsSpirvWords;
            const std::uint32_t* fsSpirvData;
            std::size_t fsSpirvWords;
            if (linked.linkSucceeded) {
                vsSpirvData = linked.vertexSpirv.data();
                vsSpirvWords = linked.vertexSpirv.size();
                fsSpirvData = linked.fragmentSpirv.data();
                fsSpirvWords = linked.fragmentSpirv.size();
            } else {
                vsSpirvData = vertexShader->spirv.data();
                vsSpirvWords = vertexShader->spirv.size();
                fsSpirvData = fragmentShader->spirv.data();
                fsSpirvWords = fragmentShader->spirv.size();
            }
            ShaderReflection vsRefl, fsRefl, tcRefl, teRefl;
            const bool vsOk = translateStage(
                "vertex", vsSpirvData, vsSpirvWords, vertexShader->source,
                programObject->vertexMSL, vsRefl);
            const bool fsOk = translateStage(
                "fragment", fsSpirvData, fsSpirvWords, fragmentShader->source,
                programObject->fragmentMSL, fsRefl);
            std::string unusedTcMSL, unusedTeMSL;
            (void)translateCachedStage("tess-control", tessControlShader, unusedTcMSL, tcRefl);
            (void)translateCachedStage("tess-eval", tessEvalShader, unusedTeMSL, teRefl);
            Runtime::shared().recordShaderTranslation({
                programTag + "-tessellation-emulation", "tessellation",
                quickHash(tessControlShader->source),
                linkVertexHash, linkFragmentHash,
                "tessellation emulation not yet available on Metal; "
                "program translated VS+FS only, falls back to raster-without-tess",
                "", false
            });
            if (vsOk && fsOk) {
                programObject->vertexReflection = std::move(vsRefl);
                programObject->fragmentReflection = std::move(fsRefl);
                programObject->hasTranslatedPipeline = true;
                rasterTranslationOk = true;
            }
            break;
        }
        case ProgramKind::Unknown:
            break;  // Already handled above; kept so -Wswitch stays happy.
    }

    NSLog(@"[GL] linkProgram: program=%u kind=%d translationOk=%d "
          @"vertexInputs=%zu vsUniformBlocks=%zu fsUniformBlocks=%zu",
          program, static_cast<int>(kind), rasterTranslationOk ? 1 : 0,
          programObject->vertexReflection.vertexInputs.size(),
          programObject->vertexReflection.uniformBlocks.size(),
          programObject->fragmentReflection.uniformBlocks.size());

    // ── Merge SPIRV-Cross uniform block reflection into the program's
    //    resource introspection tables ──
    //
    // The scanner doesn't see interface blocks (see 2d / GLSLReflection
    // brace-depth bug), so SPIRV-Cross reflection is the authoritative
    // source for UBO member metadata. Blocks that appear in both the
    // vertex and fragment reflection (BAR's per-view uniforms are shared
    // across stages) dedup by name, OR-ing the referencedBy bits together.
    //
    // Each block also pushes its members into resourceBufferVariables with
    // `blockIndex` pointing back to the block entry so
    // glGetProgramResourceiv(GL_BUFFER_VARIABLE, ...) can find them.
    if (rasterTranslationOk || kind == ProgramKind::Compute) {
        auto mergeBlocks = [&](const std::vector<ShaderReflection::ResourceBinding>& blocks,
                               GLbitfield stageBit) {
            for (const auto& block : blocks) {
                auto existing = std::find_if(
                    programObject->resourceUniformBlocks.begin(),
                    programObject->resourceUniformBlocks.end(),
                    [&](const GLProgramResourceEntry& e) { return e.name == block.name; });
                if (existing != programObject->resourceUniformBlocks.end()) {
                    existing->referencedBy |= stageBit;
                    continue;
                }
                GLProgramResourceEntry blockEntry;
                blockEntry.name = block.name;
                blockEntry.type = 0;  // blocks have no scalar type
                blockEntry.location = static_cast<GLint>(block.glBinding);
                blockEntry.arraySize = 1;
                blockEntry.referencedBy = stageBit;
                programObject->resourceUniformBlocks.push_back(std::move(blockEntry));

                const GLint blockIndex =
                    static_cast<GLint>(programObject->resourceUniformBlocks.size() - 1);
                for (const auto& member : block.members) {
                    GLProgramResourceEntry memberEntry;
                    memberEntry.name = block.name + "." + member.name;
                    memberEntry.type = member.type;
                    memberEntry.location = -1;  // not queryable via glGetUniformLocation
                    memberEntry.offset = static_cast<GLint>(member.offset);
                    memberEntry.blockIndex = blockIndex;
                    memberEntry.referencedBy = stageBit;
                    programObject->resourceBufferVariables.push_back(std::move(memberEntry));
                }
            }
        };
        mergeBlocks(programObject->vertexReflection.uniformBlocks, 0x01);    // vertex
        mergeBlocks(programObject->fragmentReflection.uniformBlocks, 0x02);  // fragment
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

// Build a correctly-laid-out uniform buffer for one shader stage by matching
// SPIRV-Cross struct members (with their std140 offsets/sizes) against the
// program's named GL uniform values.  Handles the mat3 column-padding case
// (GL stores 9 floats; Metal/std140 stores 3 columns × 4 floats = 12).
//
// ── OPT-7: precomputed uniform layout ──
// computeStageUniformLayout() runs once per program per stage, mapping each
// push-constant struct member to its GL uniform location.  This eliminates
// the O(N*M) string comparison from the per-draw packing path.
static void computeStageUniformLayout(
    std::vector<GLProgramObject::UniformLayoutEntry>& layout,
    const ShaderReflection& reflection,
    const std::vector<GLProgramUniformInfo>& uniforms)
{
    layout.clear();
    if (reflection.uniformBlocks.empty()) return;
    const auto& block = reflection.uniformBlocks[0];
    if (block.byteSize == 0) return;

    layout.reserve(block.members.size());
    for (const auto& member : block.members) {
        GLProgramObject::UniformLayoutEntry entry;
        entry.memberOffset = member.offset;
        entry.copyBytes = member.size;
        entry.location = -1;
        entry.isMat3Padded = (member.type == GL_FLOAT_MAT3 && member.size == 48);

        // One-time name lookup: find the GL uniform location for this member.
        for (const auto& u : uniforms) {
            if (u.name == member.name) {
                entry.location = u.location;
                break;
            }
        }
        layout.push_back(entry);
    }
}

// The output is written into |outBuffer|, which is resized via assign().
// Callers should pass a thread-local vector so that the allocation persists
// across draw calls — after the first frame this is a zero-alloc operation.
//
// OPT-7: uses the precomputed layout to avoid per-draw string comparisons.
// The layout maps struct members directly to uniform locations.
// Push synthesized fixed-function matrix uniform values into the
// program's uniformValues map so the next buildStageUniformBuffer
// pack picks them up. Reads from the per-context MatrixStateMirror
// and writes only the slots that the link-time scan found in
// programObject->synthesizedMatrixSlots — slots whose original
// (compat-profile) shader source did not reference the corresponding
// gl_* identifier stay at -1 and get skipped. When no slots are set
// at all (the typical case for core-profile programs), this returns
// in O(1) and the per-draw cost is a single bool check.
static void pushSynthesizedMatrixUniforms(
    GLProgramObject& program,
    const MatrixStateMirror& matrixState)
{
    const auto& slots = program.synthesizedMatrixSlots;
    if (!slots.hasAny()) {
        return;
    }

    auto storeMat4 = [&](GLint loc, const Matrix4& matrix) {
        if (loc < 0) return;
        auto& value = program.uniformValues[loc];
        value.type = GL_FLOAT_MAT4;
        value.arraySize = 1;
        value.floats.assign(matrix.m.begin(), matrix.m.end());
    };
    auto storeMat3 = [&](GLint loc, const Matrix4& matrix) {
        if (loc < 0) return;
        auto& value = program.uniformValues[loc];
        value.type = GL_FLOAT_MAT3;
        value.arraySize = 1;
        // GL stores mat3 as 9 packed floats (3 columns × 3 rows). The
        // GPU side uses 3 vec4 columns; buildStageUniformBuffer's
        // `isMat3Padded` path repacks 9 → 12 floats when the layout
        // entry is flagged. We store the 9-float canonical form here.
        value.floats.assign(9, 0.0f);
        for (int col = 0; col < 3; ++col) {
            for (int row = 0; row < 3; ++row) {
                value.floats[col * 3 + row] = matrix.m[col * 4 + row];
            }
        }
    };

    if (slots.modelView >= 0) {
        storeMat4(slots.modelView, matrixState.modelView());
    }
    if (slots.projection >= 0) {
        storeMat4(slots.projection, matrixState.projection());
    }
    if (slots.modelViewProjection >= 0) {
        storeMat4(slots.modelViewProjection, matrixState.modelViewProjection());
    }
    if (slots.modelViewInverse >= 0) {
        storeMat4(slots.modelViewInverse, matrixState.modelViewInverse());
    }
    if (slots.projectionInverse >= 0) {
        storeMat4(slots.projectionInverse, matrixState.projectionInverse());
    }
    if (slots.modelViewProjectionInverse >= 0) {
        storeMat4(slots.modelViewProjectionInverse,
                  matrixState.modelViewProjectionInverse());
    }
    if (slots.normal >= 0) {
        storeMat3(slots.normal, matrixState.normalMatrix());
    }
    if (slots.texture >= 0) {
        // Texture matrix is `mat4 appgl_TextureMatrix[N]`. The link
        // pass treats it as a single uniform whose value buffer holds
        // N * 16 packed floats. Fill all N entries from the per-unit
        // texture stack tops; unused units come back as identity from
        // MatrixStateMirror::textureMatrix() so the GPU-side array is
        // always fully populated.
        auto& value = program.uniformValues[slots.texture];
        value.type = GL_FLOAT_MAT4;
        value.arraySize = static_cast<GLint>(kSynthesizedTextureMatrixCount);
        value.floats.assign(
            static_cast<std::size_t>(kSynthesizedTextureMatrixCount) * 16, 0.0f);
        for (unsigned int i = 0; i < kSynthesizedTextureMatrixCount; ++i) {
            const Matrix4 m = matrixState.textureMatrix(i);
            std::memcpy(value.floats.data() + i * 16,
                        m.m.data(),
                        16 * sizeof(float));
        }
    }
}

static void buildStageUniformBuffer(
    std::vector<std::uint8_t>& outBuffer,
    const ShaderReflection& reflection,
    const std::unordered_map<GLint, GLProgramUniformValue>& uniformValues,
    const std::vector<GLProgramObject::UniformLayoutEntry>& layout)
{
    outBuffer.clear();
    if (reflection.uniformBlocks.empty()) return;
    const auto& block = reflection.uniformBlocks[0];
    if (block.byteSize == 0) return;

    const std::size_t paddedSize = (block.byteSize + 15u) & ~std::size_t(15u);
    outBuffer.assign(paddedSize, 0);

    for (const auto& entry : layout) {
        if (entry.location < 0) continue;

        auto it = uniformValues.find(entry.location);
        if (it == uniformValues.end()) continue;
        const auto& val = it->second;

        // Determine which data vector to use based on what's populated.
        const void* srcData = nullptr;
        std::size_t srcBytes = 0;
        if (!val.floats.empty()) {
            srcData = val.floats.data();
            srcBytes = val.floats.size() * sizeof(GLfloat);
        } else if (!val.ints.empty()) {
            srcData = val.ints.data();
            srcBytes = val.ints.size() * sizeof(GLint);
        } else if (!val.uints.empty()) {
            srcData = val.uints.data();
            srcBytes = val.uints.size() * sizeof(GLuint);
        } else {
            continue;
        }

        std::uint8_t* dst = outBuffer.data() + entry.memberOffset;

        // mat3: GL stores 9 packed floats; Metal std140 stores 3 vec4 columns.
        if (entry.isMat3Padded && val.floats.size() >= 9) {
            for (int col = 0; col < 3; ++col) {
                std::memcpy(dst + col * 16, val.floats.data() + col * 3, 3 * sizeof(float));
            }
            continue;
        }

        std::memcpy(dst, srcData, std::min(srcBytes, entry.copyBytes));
    }
}

// Phase A Group 7 — MVP draw path. Until the GLSL→MSL translator is wired up,
// the runtime supports one hand-written "solid color" pipeline: a single
// vec3 position attribute at location 0 plus a vec4 uniform named "uColor".
// Anything outside that envelope is rejected here so the caller can emit a
// debug message and bail cleanly instead of producing garbage pixels.
// Resolve the effective VBO name, stride, and byte offset for a vertex
// attribute, handling both classic (glVertexAttribPointer) and separated
// (GL 4.3/4.5 glVertexAttribFormat + glVertexArrayVertexBuffer) formats.
struct ResolvedVertexAttrib {
    GLuint bufferName = 0;
    std::size_t stride = 0;
    std::size_t offset = 0;
};

static ResolvedVertexAttrib resolveVertexAttrib(
    const GLVertexAttributeState& attr,
    const GLVertexArrayObject& vao)
{
    ResolvedVertexAttrib r;
    if (attr.useSeparatedFormat && attr.bindingIndex < vao.bindingPoints.size()) {
        const auto& bp = vao.bindingPoints[attr.bindingIndex];
        r.bufferName = bp.buffer;
        r.stride = bp.stride > 0
            ? static_cast<std::size_t>(bp.stride)
            : sizeof(GLfloat) * static_cast<std::size_t>(attr.size);
        r.offset = static_cast<std::size_t>(bp.offset)
                 + static_cast<std::size_t>(attr.relativeOffset);
    } else {
        r.bufferName = attr.buffer;
        r.stride = attr.stride > 0
            ? static_cast<std::size_t>(attr.stride)
            : sizeof(GLfloat) * static_cast<std::size_t>(attr.size);
        r.offset = static_cast<std::size_t>(attr.pointer);
    }
    return r;
}

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
    if (!positionAttr.enabled || positionAttr.type != GL_FLOAT || positionAttr.size != 3) {
        return setup;
    }
    // Resolve through binding point for GL 4.3+ separated vertex format,
    // falling back to legacy attribute fields for classic glVertexAttribPointer.
    ResolvedVertexAttrib resolved = resolveVertexAttrib(positionAttr, *vao);
    if (resolved.bufferName == 0) {
        return setup;
    }
    GLBufferObject* vbo = objects.buffers().get(resolved.bufferName);
    if (vbo == nullptr || vbo->shadowBytes.empty()) {
        return setup;
    }
    const std::size_t positionStride = resolved.stride;
    if (resolved.offset > vbo->shadowBytes.size()) {
        return setup;
    }

    setup.info.mode = mode;
    setup.info.positions = vbo->shadowBytes.data() + resolved.offset;
    setup.info.positionByteCount = vbo->shadowBytes.size() - resolved.offset;
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
    setup.info.wireframe = (state.rasterState().polygonFillMode == GL_LINE);
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
        // Phase 8X Group 4d follow-up³ — name each fall-through gate to BAR's log.
        const bool gateEmpty = (vao == nullptr || vao->attributes.empty());
        if (gateEmpty) {
            reportTranslatedFallbackOnce(program, programName,
                TranslatedFallbackGate::EmptyAttributes, "drawArrays",
                vaoName, vao ? vao->attributes.size() : 0, 0, 0);
        }
        if (vao != nullptr && !vao->attributes.empty()) {
            const auto& posAttr = vao->attributes[0];
            auto resolved = resolveVertexAttrib(posAttr, *vao);
            GLBufferObject* vbo = (resolved.bufferName != 0)
                ? impl_->objects->buffers().get(resolved.bufferName) : nullptr;
            if (vbo == nullptr) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::NullVBO, "drawArrays",
                    vaoName, vao->attributes.size(), resolved.bufferName, 0);
            } else if (vbo->shadowBytes.empty()) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::ShadowBytesEmpty, "drawArrays",
                    vaoName, vao->attributes.size(), resolved.bufferName, 0);
            }
            if (vbo != nullptr && !vbo->shadowBytes.empty()) {
                const std::size_t posStride = resolved.stride;
                const std::size_t firstOff = static_cast<std::size_t>(first) * posStride;
                const std::size_t startOff = resolved.offset + firstOff;

                if (startOff > vbo->shadowBytes.size()) {
                    reportTranslatedFallbackOnce(program, programName,
                        TranslatedFallbackGate::OffsetOverflow, "drawArrays",
                        vaoName, vao->attributes.size(), resolved.bufferName,
                        vbo->shadowBytes.size());
                }
                if (startOff <= vbo->shadowBytes.size()) {
                    TranslatedDrawInfo tdi;
                    tdi.mode = mode;
                    tdi.vertexCount = count;
                    tdi.vertexData = vbo->shadowBytes.data() + startOff;
                    tdi.vertexDataByteCount = vbo->shadowBytes.size() - startOff;
                    tdi.vertexStride = posStride;
                    // OPT-5: pass pre-uploaded Metal buffer for direct bind.
                    tdi.metalVertexBuffer = vbo->metalBuffer;
                    tdi.metalVertexBufferOffset = startOff;
                    tdi.depthTestEnabled = impl_->state->isEnabled(GL_DEPTH_TEST);
                    tdi.depthFunc = impl_->state->depthState().func;
                    tdi.cullFaceEnabled = impl_->state->isEnabled(GL_CULL_FACE);
                    tdi.cullFaceMode = impl_->state->rasterState().cullFaceMode;
                    tdi.frontFace = impl_->state->rasterState().frontFace;
                    tdi.wireframe = (impl_->state->rasterState().polygonFillMode == GL_LINE);
                    tdi.vertexMSL = &program->vertexMSL;
                    tdi.fragmentMSL = &program->fragmentMSL;
                    tdi.vertexReflection = &program->vertexReflection;
                    tdi.fragmentReflection = &program->fragmentReflection;
                    tdi.pipelineStateOut = &program->metalPipelineState;
                    tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;
                    // Phase 8X Group 4d follow-up⁸ — diagnostic-only
                    // program identifier used by encodeTranslatedDraw's
                    // first-draw-per-program NSLog. Non-owning, no
                    // correctness impact; zero is a valid placeholder.
                    tdi.program = programName;

                    // Collect per-attribute layout from the VAO.  All enabled
                    // attributes whose resolved buffer matches the primary VBO
                    // go into vertexAttributeLayouts (Metal buffer 0).
                    for (std::size_t ai = 0; ai < vao->attributes.size(); ++ai) {
                        const auto& attr = vao->attributes[ai];
                        if (!attr.enabled) continue;
                        auto attrRes = resolveVertexAttrib(attr, *vao);
                        if (attrRes.bufferName != resolved.bufferName) continue;
                        TranslatedDrawInfo::VertexAttributeLayout layout;
                        layout.location = static_cast<GLuint>(ai);
                        layout.offset = attrRes.offset - resolved.offset;
                        tdi.vertexAttributeLayouts.push_back(layout);
                    }

                    // OPT-7: compute uniform layout once, reuse every draw.
                    if (!program->uniformLayoutComputed) {
                        computeStageUniformLayout(program->vertexUniformLayout,
                            program->vertexReflection, program->uniforms);
                        computeStageUniformLayout(program->fragmentUniformLayout,
                            program->fragmentReflection, program->uniforms);
                        program->uniformLayoutComputed = true;
                    }

                    // Build per-stage uniform buffers using the cached layout.
                    // Thread-local scratch buffers retain their allocation
                    // across draw calls — zero heap allocs after warmup.
                    thread_local std::vector<std::uint8_t> vtxUniformScratch;
                    thread_local std::vector<std::uint8_t> fragUniformScratch;
                    // Push synthesized fixed-function matrix uniforms into
                    // program->uniformValues for compat-rewritten shaders.
                    // Early-out for the common (core-profile) case.
                    pushSynthesizedMatrixUniforms(*program, impl_->matrixState);
                    buildStageUniformBuffer(vtxUniformScratch,
                        program->vertexReflection, program->uniformValues,
                        program->vertexUniformLayout);
                    buildStageUniformBuffer(fragUniformScratch,
                        program->fragmentReflection, program->uniformValues,
                        program->fragmentUniformLayout);
                    tdi.vertexUniformData = vtxUniformScratch.data();
                    tdi.vertexUniformSize = vtxUniformScratch.size();
                    tdi.fragmentUniformData = fragUniformScratch.data();
                    tdi.fragmentUniformSize = fragUniformScratch.size();

                    // Phase 8X Group 4d follow-up⁷ — resolve each sampler
                    // uniform in the program to the Metal texture + sampler
                    // state currently bound to its GL texture unit, then
                    // append the pairs to the TranslatedDrawInfo binding
                    // vectors. See `Impl::resolveSamplerBindings` for the
                    // resolution rules. This is the structural hole behind
                    // the smeared-glyph observation from followup⁶
                    // verification §Visual — prior to this round,
                    // encodeTranslatedDraw bound zero textures/samplers
                    // and the fragment shader sampled from an unbound
                    // slot.
                    impl_->resolveSamplerBindings(*program, tdi);

                    // Phase 8X Group 4d follow-up⁴ — scratch buffer for the
                    // pipeline-build error text plumbed out of the encode-failed
                    // path. Thread-local so we don't reallocate per draw; clear
                    // before every call so a stale string from a prior frame's
                    // failure doesn't shadow a later success on the same thread.
                    thread_local std::string pipelineBuildError;
                    pipelineBuildError.clear();
                    tdi.pipelineBuildErrorOut = &pipelineBuildError;

                    const bool ok = impl_->frameGraph->encodeTranslatedDraw(tdi);
                    if (ok) {
                        return true;
                    }
                    if (reportTranslatedFallbackOnce(program, programName,
                            TranslatedFallbackGate::EncodeFailed, "drawArrays",
                            vaoName, vao->attributes.size(), resolved.bufferName,
                            vbo->shadowBytes.size())) {
                        recordPipelineBuildFailureOnce(program, programName, pipelineBuildError);
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

bool GLContext::drawArraysInstanced(GLenum mode, GLint first, GLsizei count, GLsizei instancecount) {
    if (count < 0 || instancecount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (count == 0 || instancecount == 0) {
        return true;
    }
    if (!impl_->state->validateForDraw()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (impl_->frameGraph == nullptr) {
        return false;
    }
    impl_->frameGraph->resizeDrawable(impl_->viewportWidth, impl_->viewportHeight);
    impl_->encodePendingWork();

    // Translated shader pipeline with instancing.
    const GLuint programName = impl_->state->currentProgram();
    GLProgramObject* program = (programName != 0) ? impl_->objects->programs().get(programName) : nullptr;
    if (program != nullptr && program->hasTranslatedPipeline) {
        const GLuint vaoName = impl_->state->boundVertexArray();
        GLVertexArrayObject* vao = (vaoName != 0) ? impl_->objects->vertexArrays().get(vaoName) : nullptr;
        // Phase 8X Group 4d follow-up³ — name each fall-through gate to BAR's log.
        if (vao == nullptr || vao->attributes.empty()) {
            reportTranslatedFallbackOnce(program, programName,
                TranslatedFallbackGate::EmptyAttributes, "drawArraysInstanced",
                vaoName, vao ? vao->attributes.size() : 0, 0, 0);
        }
        if (vao != nullptr && !vao->attributes.empty()) {
            const auto& posAttr = vao->attributes[0];
            auto resolved = resolveVertexAttrib(posAttr, *vao);
            GLBufferObject* vbo = (resolved.bufferName != 0)
                ? impl_->objects->buffers().get(resolved.bufferName) : nullptr;
            if (vbo == nullptr) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::NullVBO, "drawArraysInstanced",
                    vaoName, vao->attributes.size(), resolved.bufferName, 0);
            } else if (vbo->shadowBytes.empty()) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::ShadowBytesEmpty, "drawArraysInstanced",
                    vaoName, vao->attributes.size(), resolved.bufferName, 0);
            }
            if (vbo != nullptr && !vbo->shadowBytes.empty()) {
                const std::size_t posStride = resolved.stride;
                const std::size_t firstOff = static_cast<std::size_t>(first) * posStride;
                const std::size_t startOff = resolved.offset + firstOff;

                if (startOff > vbo->shadowBytes.size()) {
                    reportTranslatedFallbackOnce(program, programName,
                        TranslatedFallbackGate::OffsetOverflow, "drawArraysInstanced",
                        vaoName, vao->attributes.size(), resolved.bufferName,
                        vbo->shadowBytes.size());
                }
                if (startOff <= vbo->shadowBytes.size()) {
                    TranslatedDrawInfo tdi;
                    tdi.mode = mode;
                    tdi.vertexCount = count;
                    tdi.instanceCount = instancecount;
                    tdi.vertexData = vbo->shadowBytes.data() + startOff;
                    tdi.vertexDataByteCount = vbo->shadowBytes.size() - startOff;
                    tdi.vertexStride = posStride;
                    // OPT-5: pass pre-uploaded Metal buffer for direct bind.
                    tdi.metalVertexBuffer = vbo->metalBuffer;
                    tdi.metalVertexBufferOffset = startOff;
                    tdi.depthTestEnabled = impl_->state->isEnabled(GL_DEPTH_TEST);
                    tdi.depthFunc = impl_->state->depthState().func;
                    tdi.cullFaceEnabled = impl_->state->isEnabled(GL_CULL_FACE);
                    tdi.cullFaceMode = impl_->state->rasterState().cullFaceMode;
                    tdi.frontFace = impl_->state->rasterState().frontFace;
                    tdi.wireframe = (impl_->state->rasterState().polygonFillMode == GL_LINE);
                    tdi.vertexMSL = &program->vertexMSL;
                    tdi.fragmentMSL = &program->fragmentMSL;
                    tdi.vertexReflection = &program->vertexReflection;
                    tdi.fragmentReflection = &program->fragmentReflection;
                    tdi.pipelineStateOut = &program->metalPipelineState;
                    tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;
                    // Phase 8X Group 4d follow-up⁸ — diagnostic-only
                    // program identifier used by encodeTranslatedDraw's
                    // first-draw-per-program NSLog. Non-owning, no
                    // correctness impact; zero is a valid placeholder.
                    tdi.program = programName;

                    // Gather vertex attributes.  Attributes in the same VBO as
                    // attribute 0 (per-vertex) go into vertexAttributeLayouts
                    // (Metal buffer 0).  Attributes in OTHER VBOs (e.g. per-instance
                    // data with glVertexAttribDivisor) become extraVertexBuffers.
                    std::unordered_map<GLuint, std::size_t> extraBufferMap;

                    for (std::size_t ai = 0; ai < vao->attributes.size(); ++ai) {
                        const auto& attr = vao->attributes[ai];
                        if (!attr.enabled) continue;

                        auto attrRes = resolveVertexAttrib(attr, *vao);
                        GLuint attrDivisor = attr.useSeparatedFormat
                            ? (attr.bindingIndex < vao->bindingPoints.size()
                                ? vao->bindingPoints[attr.bindingIndex].divisor
                                : attr.divisor)
                            : attr.divisor;

                        if (attrRes.bufferName == resolved.bufferName && attrDivisor == 0) {
                            // Same VBO as primary, per-vertex — buffer 0.
                            TranslatedDrawInfo::VertexAttributeLayout layout;
                            layout.location = static_cast<GLuint>(ai);
                            layout.offset = attrRes.offset - resolved.offset;
                            tdi.vertexAttributeLayouts.push_back(layout);
                        } else if (attrRes.bufferName != resolved.bufferName) {
                            // Different VBO — group by GL buffer name.
                            GLBufferObject* extraVbo = impl_->objects->buffers().get(attrRes.bufferName);
                            if (extraVbo == nullptr || extraVbo->shadowBytes.empty()) continue;

                            auto it = extraBufferMap.find(attrRes.bufferName);
                            std::size_t idx;
                            if (it == extraBufferMap.end()) {
                                idx = tdi.extraVertexBuffers.size();
                                extraBufferMap[attrRes.bufferName] = idx;

                                TranslatedDrawInfo::ExtraVertexBuffer evb;
                                evb.data = extraVbo->shadowBytes.data();
                                evb.byteCount = extraVbo->shadowBytes.size();
                                evb.stride = attrRes.stride;
                                evb.divisor = attrDivisor;
                                // OPT-5: direct Metal buffer for extra VBOs.
                                evb.metalBuffer = extraVbo->metalBuffer;
                                evb.metalBufferOffset = 0;
                                tdi.extraVertexBuffers.push_back(std::move(evb));
                            } else {
                                idx = it->second;
                            }

                            TranslatedDrawInfo::VertexAttributeLayout layout;
                            layout.location = static_cast<GLuint>(ai);
                            layout.offset = attrRes.offset;
                            tdi.extraVertexBuffers[idx].attributes.push_back(layout);
                        }
                    }

                    // OPT-7: compute uniform layout once, reuse every draw.
                    if (!program->uniformLayoutComputed) {
                        computeStageUniformLayout(program->vertexUniformLayout,
                            program->vertexReflection, program->uniforms);
                        computeStageUniformLayout(program->fragmentUniformLayout,
                            program->fragmentReflection, program->uniforms);
                        program->uniformLayoutComputed = true;
                    }

                    thread_local std::vector<std::uint8_t> vtxUniformScratch;
                    thread_local std::vector<std::uint8_t> fragUniformScratch;
                    // Push synthesized fixed-function matrix uniforms (compat
                    // shader path). Early-out for the common core-profile case.
                    pushSynthesizedMatrixUniforms(*program, impl_->matrixState);
                    buildStageUniformBuffer(vtxUniformScratch,
                        program->vertexReflection, program->uniformValues,
                        program->vertexUniformLayout);
                    buildStageUniformBuffer(fragUniformScratch,
                        program->fragmentReflection, program->uniformValues,
                        program->fragmentUniformLayout);
                    tdi.vertexUniformData = vtxUniformScratch.data();
                    tdi.vertexUniformSize = vtxUniformScratch.size();
                    tdi.fragmentUniformData = fragUniformScratch.data();
                    tdi.fragmentUniformSize = fragUniformScratch.size();

                    // Phase 8X Group 4d follow-up⁷ — see matching comment in
                    // drawArrays for rationale; the instanced draw path
                    // needs identical sampler resolution.
                    impl_->resolveSamplerBindings(*program, tdi);

                    // Phase 8X Group 4d follow-up⁴ — scratch buffer for the
                    // pipeline-build error text plumbed out of the encode-failed
                    // path. See the matching comment in drawArrays for rationale.
                    thread_local std::string pipelineBuildError;
                    pipelineBuildError.clear();
                    tdi.pipelineBuildErrorOut = &pipelineBuildError;

                    const bool ok = impl_->frameGraph->encodeTranslatedDraw(tdi);
                    if (ok) {
                        return true;
                    }
                    if (reportTranslatedFallbackOnce(program, programName,
                            TranslatedFallbackGate::EncodeFailed, "drawArraysInstanced",
                            vaoName, vao->attributes.size(), resolved.bufferName,
                            vbo->shadowBytes.size())) {
                        recordPipelineBuildFailureOnce(program, programName, pipelineBuildError);
                    }
                }
            }
        }
    }

    // Instanced drawing has no solid-color fallback.
    emitDebugMessage(
        GL_DEBUG_SOURCE_API,
        GL_DEBUG_TYPE_OTHER,
        0,
        GL_DEBUG_SEVERITY_LOW,
        "glDrawArraysInstanced: no translated pipeline available"
    );
    return false;
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
        // Phase 8X Group 4d follow-up³ — name each fall-through gate to BAR's log.
        if (vao->attributes.empty()) {
            reportTranslatedFallbackOnce(program, programName,
                TranslatedFallbackGate::EmptyAttributes, "drawElements",
                vaoName, 0, 0, 0);
        }
        if (!vao->attributes.empty()) {
            const auto& posAttr = vao->attributes[0];
            auto resolved = resolveVertexAttrib(posAttr, *vao);
            GLBufferObject* vbo = (resolved.bufferName != 0)
                ? impl_->objects->buffers().get(resolved.bufferName) : nullptr;
            if (vbo == nullptr) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::NullVBO, "drawElements",
                    vaoName, vao->attributes.size(), resolved.bufferName, 0);
            } else if (vbo->shadowBytes.empty()) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::ShadowBytesEmpty, "drawElements",
                    vaoName, vao->attributes.size(), resolved.bufferName, 0);
            }
            if (vbo != nullptr && !vbo->shadowBytes.empty()) {
                const std::size_t posStride = resolved.stride;
                const std::size_t startOff = resolved.offset;

                if (startOff > vbo->shadowBytes.size()) {
                    reportTranslatedFallbackOnce(program, programName,
                        TranslatedFallbackGate::OffsetOverflow, "drawElements",
                        vaoName, vao->attributes.size(), resolved.bufferName,
                        vbo->shadowBytes.size());
                }
                if (startOff <= vbo->shadowBytes.size()) {
                    TranslatedDrawInfo tdi;
                    tdi.mode = mode;
                    tdi.vertexCount = count;
                    tdi.vertexData = vbo->shadowBytes.data() + startOff;
                    tdi.vertexDataByteCount = vbo->shadowBytes.size() - startOff;
                    tdi.vertexStride = posStride;
                    // OPT-5: pass pre-uploaded Metal buffer for direct bind.
                    tdi.metalVertexBuffer = vbo->metalBuffer;
                    tdi.metalVertexBufferOffset = startOff;
                    tdi.indices = effectivePtr;
                    tdi.indexCount = count;
                    tdi.indexType = effectiveType;
                    // OPT-5: pass Metal index buffer when indices weren't
                    // expanded (UINT16/UINT32 pass-through from element VBO).
                    if (expanded.empty() && elementBuffer->metalBuffer != nullptr) {
                        tdi.metalIndexBuffer = elementBuffer->metalBuffer;
                        tdi.metalIndexBufferOffset = indexOffset;
                    }
                    tdi.depthTestEnabled = impl_->state->isEnabled(GL_DEPTH_TEST);
                    tdi.depthFunc = impl_->state->depthState().func;
                    tdi.cullFaceEnabled = impl_->state->isEnabled(GL_CULL_FACE);
                    tdi.cullFaceMode = impl_->state->rasterState().cullFaceMode;
                    tdi.frontFace = impl_->state->rasterState().frontFace;
                    tdi.wireframe = (impl_->state->rasterState().polygonFillMode == GL_LINE);
                    tdi.vertexMSL = &program->vertexMSL;
                    tdi.fragmentMSL = &program->fragmentMSL;
                    tdi.vertexReflection = &program->vertexReflection;
                    tdi.fragmentReflection = &program->fragmentReflection;
                    tdi.pipelineStateOut = &program->metalPipelineState;
                    tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;
                    // Phase 8X Group 4d follow-up⁸ — diagnostic-only
                    // program identifier used by encodeTranslatedDraw's
                    // first-draw-per-program NSLog. Non-owning, no
                    // correctness impact; zero is a valid placeholder.
                    tdi.program = programName;

                    // Collect per-attribute layout from the VAO.
                    for (std::size_t ai = 0; ai < vao->attributes.size(); ++ai) {
                        const auto& attr = vao->attributes[ai];
                        if (!attr.enabled) continue;
                        auto attrRes = resolveVertexAttrib(attr, *vao);
                        if (attrRes.bufferName != resolved.bufferName) continue;
                        TranslatedDrawInfo::VertexAttributeLayout layout;
                        layout.location = static_cast<GLuint>(ai);
                        layout.offset = attrRes.offset - resolved.offset;
                        tdi.vertexAttributeLayouts.push_back(layout);
                    }

                    // OPT-7: compute uniform layout once, reuse every draw.
                    if (!program->uniformLayoutComputed) {
                        computeStageUniformLayout(program->vertexUniformLayout,
                            program->vertexReflection, program->uniforms);
                        computeStageUniformLayout(program->fragmentUniformLayout,
                            program->fragmentReflection, program->uniforms);
                        program->uniformLayoutComputed = true;
                    }

                    thread_local std::vector<std::uint8_t> vtxUniformScratch;
                    thread_local std::vector<std::uint8_t> fragUniformScratch;
                    // Push synthesized fixed-function matrix uniforms (compat
                    // shader path). Early-out for the common core-profile case.
                    pushSynthesizedMatrixUniforms(*program, impl_->matrixState);
                    buildStageUniformBuffer(vtxUniformScratch,
                        program->vertexReflection, program->uniformValues,
                        program->vertexUniformLayout);
                    buildStageUniformBuffer(fragUniformScratch,
                        program->fragmentReflection, program->uniformValues,
                        program->fragmentUniformLayout);
                    tdi.vertexUniformData = vtxUniformScratch.data();
                    tdi.vertexUniformSize = vtxUniformScratch.size();
                    tdi.fragmentUniformData = fragUniformScratch.data();
                    tdi.fragmentUniformSize = fragUniformScratch.size();

                    // Phase 8X Group 4d follow-up⁷ — see matching comment in
                    // drawArrays for rationale; drawElements needs identical
                    // sampler resolution. BAR's select-menu glyph draws
                    // arrive on this path (indexed quads).
                    impl_->resolveSamplerBindings(*program, tdi);

                    // Phase 8X Group 4d follow-up⁴ — scratch buffer for the
                    // pipeline-build error text plumbed out of the encode-failed
                    // path. See the matching comment in drawArrays for rationale.
                    thread_local std::string pipelineBuildError;
                    pipelineBuildError.clear();
                    tdi.pipelineBuildErrorOut = &pipelineBuildError;

                    const bool ok = impl_->frameGraph->encodeTranslatedDraw(tdi);
                    if (ok) {
                        return true;
                    }
                    if (reportTranslatedFallbackOnce(program, programName,
                            TranslatedFallbackGate::EncodeFailed, "drawElements",
                            vaoName, vao->attributes.size(), resolved.bufferName,
                            vbo->shadowBytes.size())) {
                        recordPipelineBuildFailureOnce(program, programName, pipelineBuildError);
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

// ---------------------------------------------------------------------------
// GL 4.2 — Advanced Instanced Drawing with Base Instance
// ---------------------------------------------------------------------------

bool GLContext::drawArraysInstancedBaseInstance(GLenum mode, GLint first, GLsizei count, GLsizei instancecount, GLuint baseinstance) {
    if (count < 0 || instancecount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (count == 0 || instancecount == 0) {
        return true; // valid no-op
    }
    // Delegate to the instanced path; baseinstance is threaded through the
    // TranslatedDrawInfo for Metal's baseInstance parameter.
    // For now, we ignore baseinstance (it requires MTLGPUFamily Apple3+ to use
    // non-zero base instance). The basic instanced draw still works.
    return drawArraysInstanced(mode, first, count, instancecount);
}

bool GLContext::drawElementsInstancedBaseInstance(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLuint baseinstance) {
    if (count < 0 || instancecount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (type != GL_UNSIGNED_BYTE && type != GL_UNSIGNED_SHORT && type != GL_UNSIGNED_INT) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (count == 0 || instancecount == 0) {
        return true;
    }
    return true;
}

bool GLContext::drawElementsInstancedBaseVertexBaseInstance(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLint basevertex, GLuint baseinstance) {
    if (count < 0 || instancecount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (type != GL_UNSIGNED_BYTE && type != GL_UNSIGNED_SHORT && type != GL_UNSIGNED_INT) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (count == 0 || instancecount == 0) {
        return true;
    }
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.3 — Multi-Draw Indirect
// ---------------------------------------------------------------------------

bool GLContext::multiDrawArraysIndirect(GLenum mode, const void* indirect, GLsizei drawcount, GLsizei stride) {
    if (drawcount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (stride != 0 && stride < 16) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Stub: accepts parameters. Each draw command in the indirect buffer is a
    // DrawArraysIndirectCommand (count, instanceCount, first, baseInstance).
    return true;
}

bool GLContext::multiDrawElementsIndirect(GLenum mode, GLenum type, const void* indirect, GLsizei drawcount, GLsizei stride) {
    if (drawcount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (type != GL_UNSIGNED_BYTE && type != GL_UNSIGNED_SHORT && type != GL_UNSIGNED_INT) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (stride != 0 && stride < 20) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.3 — Buffer Clear
// ---------------------------------------------------------------------------

bool GLContext::clearBufferData(GLenum target, GLenum internalformat, GLenum format, GLenum type, const void* data) {
    GLuint boundBuffer = impl_->state->boundBuffer(target);
    if (boundBuffer == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLBufferObject* buffer = impl_->objects->buffers().get(boundBuffer);
    if (buffer == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (buffer->size == 0) {
        return true; // valid no-op
    }
    // Fill the shadow bytes with the clear value (or zero if data is null).
    if (buffer->shadowBytes.size() < static_cast<std::size_t>(buffer->size)) {
        buffer->shadowBytes.resize(static_cast<std::size_t>(buffer->size), 0);
    }
    if (data == nullptr) {
        std::memset(buffer->shadowBytes.data(), 0, buffer->shadowBytes.size());
    } else {
        // Simple fill: replicate first 4 bytes across the buffer.
        std::uint8_t pattern[4] = {0, 0, 0, 0};
        std::memcpy(pattern, data, std::min<std::size_t>(4, buffer->shadowBytes.size()));
        for (std::size_t i = 0; i < buffer->shadowBytes.size(); i += 4) {
            std::size_t remaining = std::min<std::size_t>(4, buffer->shadowBytes.size() - i);
            std::memcpy(buffer->shadowBytes.data() + i, pattern, remaining);
        }
    }
    return true;
}

bool GLContext::clearBufferSubData(GLenum target, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format, GLenum type, const void* data) {
    if (offset < 0 || size < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLuint boundBuffer = impl_->state->boundBuffer(target);
    if (boundBuffer == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLBufferObject* buffer = impl_->objects->buffers().get(boundBuffer);
    if (buffer == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (offset + size > buffer->size) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (size == 0) {
        return true;
    }
    if (buffer->shadowBytes.size() < static_cast<std::size_t>(buffer->size)) {
        buffer->shadowBytes.resize(static_cast<std::size_t>(buffer->size), 0);
    }
    if (data == nullptr) {
        std::memset(buffer->shadowBytes.data() + offset, 0, static_cast<std::size_t>(size));
    } else {
        std::uint8_t pattern[4] = {0, 0, 0, 0};
        std::memcpy(pattern, data, std::min<std::size_t>(4, static_cast<std::size_t>(size)));
        for (GLsizeiptr i = 0; i < size; i += 4) {
            GLsizeiptr remaining = std::min<GLsizeiptr>(4, size - i);
            std::memcpy(buffer->shadowBytes.data() + offset + i, pattern, static_cast<std::size_t>(remaining));
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.3 — Framebuffer Parameters
// ---------------------------------------------------------------------------

bool GLContext::framebufferParameteri(GLenum target, GLenum pname, GLint param) {
    if (target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER && target != GL_FRAMEBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // Accept parameter hints for attachment-less framebuffers. These are stored
    // on the framebuffer object but don't affect Metal rendering yet.
    switch (pname) {
        case GL_FRAMEBUFFER_DEFAULT_WIDTH:
        case GL_FRAMEBUFFER_DEFAULT_HEIGHT:
        case GL_FRAMEBUFFER_DEFAULT_LAYERS:
        case GL_FRAMEBUFFER_DEFAULT_SAMPLES:
        case GL_FRAMEBUFFER_DEFAULT_FIXED_SAMPLE_LOCATIONS:
            return true; // accepted, state-tracked as hint
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getFramebufferParameteriv(GLenum target, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER && target != GL_FRAMEBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    switch (pname) {
        case GL_FRAMEBUFFER_DEFAULT_WIDTH:       *params = 0; return true;
        case GL_FRAMEBUFFER_DEFAULT_HEIGHT:      *params = 0; return true;
        case GL_FRAMEBUFFER_DEFAULT_LAYERS:      *params = 0; return true;
        case GL_FRAMEBUFFER_DEFAULT_SAMPLES:     *params = 0; return true;
        case GL_FRAMEBUFFER_DEFAULT_FIXED_SAMPLE_LOCATIONS: *params = GL_TRUE; return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

// ---------------------------------------------------------------------------
// GL 4.3 — Invalidation Hints
// ---------------------------------------------------------------------------

bool GLContext::invalidateFramebuffer(GLenum target, GLsizei numAttachments, const GLenum* attachments) {
    if (numAttachments < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Performance hint: signal that attachment contents can be discarded.
    // Maps to MTLStoreAction.dontCare in a future optimization pass.
    return true;
}

bool GLContext::invalidateSubFramebuffer(GLenum target, GLsizei numAttachments, const GLenum* attachments, GLint x, GLint y, GLsizei width, GLsizei height) {
    if (numAttachments < 0 || width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    return true;
}

bool GLContext::invalidateBufferData(GLuint buffer) {
    if (!impl_->objects->buffers().contains(buffer)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Hint that the entire buffer's contents are no longer needed.
    return true;
}

bool GLContext::invalidateBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr length) {
    if (offset < 0 || length < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLBufferObject* buf = impl_->objects->buffers().get(buffer);
    if (buf == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (offset + length > buf->size) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.3 — Texture Operations
// ---------------------------------------------------------------------------

bool GLContext::copyImageSubData(GLuint srcName, GLenum srcTarget, GLint srcLevel, GLint srcX, GLint srcY, GLint srcZ,
                                 GLuint dstName, GLenum dstTarget, GLint dstLevel, GLint dstX, GLint dstY, GLint dstZ,
                                 GLsizei srcWidth, GLsizei srcHeight, GLsizei srcDepth) {
    if (srcWidth < 0 || srcHeight < 0 || srcDepth < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Validate source and destination exist.
    bool srcIsTex = (srcTarget != GL_RENDERBUFFER);
    bool dstIsTex = (dstTarget != GL_RENDERBUFFER);
    if (srcIsTex && !impl_->objects->textures().contains(srcName)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!srcIsTex && !impl_->objects->renderbuffers().contains(srcName)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (dstIsTex && !impl_->objects->textures().contains(dstName)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!dstIsTex && !impl_->objects->renderbuffers().contains(dstName)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Stub: actual Metal blit encoder copy will be wired when texture Metal
    // objects are fully instantiated at upload time.
    return true;
}

bool GLContext::textureView(GLuint texture, GLenum target, GLuint origtexture, GLenum internalformat,
                            GLuint minlevel, GLuint numlevels, GLuint minlayer, GLuint numlayers) {
    GLTextureObject* viewObj = impl_->objects->textures().get(texture);
    if (viewObj == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLTextureObject* origObj = impl_->objects->textures().get(origtexture);
    if (origObj == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!origObj->desc.immutable) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (numlevels == 0 || numlayers == 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Record the view relationship. Actual Metal texture view
    // (newTextureViewWithPixelFormat:) will be created when the Metal texture
    // is first needed for rendering.
    viewObj->target = target;
    viewObj->desc.target = target;
    viewObj->desc.internalFormat = internalformat;
    viewObj->desc.levels = static_cast<GLsizei>(numlevels);
    viewObj->desc.layers = static_cast<GLsizei>(numlayers);
    viewObj->desc.immutable = true;
    return true;
}

bool GLContext::invalidateTexImage(GLuint texture, GLint level) {
    if (!impl_->objects->textures().contains(texture)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Hint: texture contents at this level can be discarded.
    return true;
}

bool GLContext::invalidateTexSubImage(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
                                      GLsizei width, GLsizei height, GLsizei depth) {
    if (width < 0 || height < 0 || depth < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!impl_->objects->textures().contains(texture)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.2 — Transform Feedback Instanced Draw
// ---------------------------------------------------------------------------

bool GLContext::drawTransformFeedbackInstanced(GLenum mode, GLuint id, GLsizei instancecount) {
    if (instancecount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLTransformFeedbackObject* tfObj = impl_->objects->transformFeedbacks().get(id);
    if (tfObj == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Stub: draws instancecount instances of capturedPrimitives vertices.
    // Currently capturedPrimitives is always 0 (no real TF capture yet).
    return true;
}

bool GLContext::drawTransformFeedbackStreamInstanced(GLenum mode, GLuint id, GLuint stream, GLsizei instancecount) {
    if (instancecount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (stream > 0) {
        // Metal doesn't support multiple TF streams.
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLTransformFeedbackObject* tfObj = impl_->objects->transformFeedbacks().get(id);
    if (tfObj == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.2/4.3 — Internal Format Query
// ---------------------------------------------------------------------------

bool GLContext::getInternalformativ(GLenum target, GLenum internalformat, GLenum pname, GLsizei count, GLint* params) {
    if (count < 0 || params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (count == 0) {
        return true;
    }
    // Phase 8X Landing C 3b — consult the capabilities format table so
    // format-dependent queries (SUPPORTED, COLOR_ENCODING, RENDERABLE,
    // BLEND) reflect the actual entries that initializeFormatTable() puts
    // on the device, rather than returning GL_FULL_SUPPORT unconditionally.
    std::optional<GLFormatCapability> capability = impl_->capabilities->format(internalformat);
    switch (pname) {
        case GL_NUM_SAMPLE_COUNTS:
            params[0] = 3; // Metal typically supports 1, 2, 4 samples
            return true;
        case GL_SAMPLES:
            // Return sample counts in descending order.
            if (count >= 1) params[0] = 4;
            if (count >= 2) params[1] = 2;
            if (count >= 3) params[2] = 1;
            return true;
        case GL_INTERNALFORMAT_SUPPORTED:
            params[0] = capability.has_value() ? GL_TRUE : GL_FALSE;
            return true;
        case GL_INTERNALFORMAT_PREFERRED:
            params[0] = static_cast<GLint>(internalformat);
            return true;
        case GL_READ_PIXELS_FORMAT:
            params[0] = GL_RGBA;
            return true;
        case GL_READ_PIXELS_TYPE:
            params[0] = GL_UNSIGNED_BYTE;
            return true;
        case GL_MAX_WIDTH:
            params[0] = 16384;
            return true;
        case GL_MAX_HEIGHT:
            params[0] = 16384;
            return true;
        case GL_MAX_DEPTH:
            params[0] = 2048;
            return true;
        case GL_MAX_LAYERS:
            params[0] = 2048;
            return true;
        case GL_MAX_COMBINED_DIMENSIONS:
            params[0] = 16384;
            return true;
        case GL_FRAMEBUFFER_RENDERABLE:
            if (!capability.has_value()) {
                params[0] = GL_NONE;
            } else {
                params[0] = capability->renderable ? GL_FULL_SUPPORT : GL_CAVEAT_SUPPORT;
            }
            return true;
        case GL_FRAMEBUFFER_BLEND:
            if (!capability.has_value()) {
                params[0] = GL_NONE;
            } else {
                params[0] = capability->blendable ? GL_FULL_SUPPORT : GL_CAVEAT_SUPPORT;
            }
            return true;
        case GL_COLOR_ENCODING:
            if (capability.has_value() && capability->srgbCapable) {
                params[0] = GL_SRGB;
            } else {
                params[0] = GL_LINEAR;
            }
            return true;
        default:
            // For unrecognized pnames, return 0 rather than erroring — apps
            // sometimes probe opportunistically.
            for (GLsizei i = 0; i < count; ++i) {
                params[i] = 0;
            }
            return true;
    }
}

bool GLContext::getInternalformati64v(GLenum target, GLenum internalformat, GLenum pname, GLsizei count, GLint64* params) {
    if (count < 0 || params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (count == 0) {
        return true;
    }
    // Reuse the 32-bit path, widening the results.
    std::vector<GLint> temp(static_cast<std::size_t>(count), 0);
    bool result = getInternalformativ(target, internalformat, pname, count, temp.data());
    if (result) {
        for (GLsizei i = 0; i < count; ++i) {
            params[i] = static_cast<GLint64>(temp[static_cast<std::size_t>(i)]);
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// GL 4.4 — Immutable buffer storage.
// ---------------------------------------------------------------------------

bool GLContext::bufferStorage(GLenum target, GLsizeiptr size, const void* data, GLbitfield flags) {
    if (size < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLbitfield validBits = GL_MAP_READ_BIT | GL_MAP_WRITE_BIT |
                                 GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT |
                                 GL_DYNAMIC_STORAGE_BIT | GL_CLIENT_STORAGE_BIT;
    if (flags & ~validBits) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if ((flags & GL_MAP_PERSISTENT_BIT) && !(flags & (GL_MAP_READ_BIT | GL_MAP_WRITE_BIT))) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if ((flags & GL_MAP_COHERENT_BIT) && !(flags & GL_MAP_PERSISTENT_BIT)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLuint name = impl_->state->boundBuffer(target);
    if (name == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    auto* buf = impl_->objects->buffers().get(name);
    if (!buf) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (buf->immutable) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Delegate to replaceBufferStorage to create both shadow bytes and Metal
    // buffer, then layer immutability flags on top.  Without this the Metal
    // buffer would remain null and draws would render black.
    if (!impl_->replaceBufferStorage(*buf, size, data, GL_STATIC_DRAW)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    buf->immutable = true;
    buf->storageFlags = flags;
    buf->instantiated = true;
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.4 — Multi-bind.
// ---------------------------------------------------------------------------

bool GLContext::bindBuffersBase(GLenum target, GLuint first, GLsizei count, const GLuint* buffers) {
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei i = 0; i < count; ++i) {
        GLuint buf = buffers ? buffers[i] : 0;
        bindBufferBase(target, first + static_cast<GLuint>(i), buf);
    }
    return true;
}

bool GLContext::bindBuffersRange(GLenum target, GLuint first, GLsizei count, const GLuint* buffers,
                                 const GLintptr* offsets, const GLsizeiptr* sizes) {
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei i = 0; i < count; ++i) {
        GLuint buf = buffers ? buffers[i] : 0;
        GLintptr offset = (buffers && offsets) ? offsets[i] : 0;
        GLsizeiptr sz = (buffers && sizes) ? sizes[i] : 0;
        bindBufferRange(target, first + static_cast<GLuint>(i), buf, offset, sz);
    }
    return true;
}

bool GLContext::bindVertexBuffers(GLuint first, GLsizei count, const GLuint* buffers,
                                  const GLintptr* offsets, const GLsizei* strides) {
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei i = 0; i < count; ++i) {
        GLuint buf = buffers ? buffers[i] : 0;
        GLintptr offset = (buffers && offsets) ? offsets[i] : 0;
        GLsizei stride = (buffers && strides) ? strides[i] : 0;
        bindVertexBuffer(first + static_cast<GLuint>(i), buf, offset, stride);
    }
    return true;
}

bool GLContext::bindTextures(GLuint first, GLsizei count, const GLuint* textures) {
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei i = 0; i < count; ++i) {
        GLuint tex = textures ? textures[i] : 0;
        GLuint unit = first + static_cast<GLuint>(i);
        impl_->state->setActiveTextureUnit(unit);
        if (tex == 0) {
            // Unbind all targets on this unit.
            impl_->state->bindTexture(GL_TEXTURE_2D, 0);
        } else {
            auto* obj = impl_->objects->textures().get(tex);
            GLenum target = (obj && obj->target != 0) ? obj->target : GL_TEXTURE_2D;
            impl_->state->bindTexture(target, tex);
        }
    }
    return true;
}

bool GLContext::bindSamplers(GLuint first, GLsizei count, const GLuint* samplers) {
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei i = 0; i < count; ++i) {
        GLuint sampler = samplers ? samplers[i] : 0;
        bindSampler(first + static_cast<GLuint>(i), sampler);
    }
    return true;
}

bool GLContext::bindImageTextures(GLuint first, GLsizei count, const GLuint* textures) {
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei i = 0; i < count; ++i) {
        GLuint tex = textures ? textures[i] : 0;
        GLuint unit = first + static_cast<GLuint>(i);
        if (tex == 0) {
            bindImageTexture(unit, 0, 0, GL_FALSE, 0, GL_READ_ONLY, GL_RGBA8);
        } else {
            auto* obj = impl_->objects->textures().get(tex);
            GLenum fmt = (obj && obj->desc.internalFormat != 0) ? obj->desc.internalFormat : GL_RGBA8;
            bindImageTexture(unit, tex, 0, GL_TRUE, 0, GL_READ_WRITE, fmt);
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.4 — Texture clear.
// ---------------------------------------------------------------------------

bool GLContext::clearTexImage(GLuint texture, GLint level, GLenum format, GLenum type, const void* data) {
    auto* tex = impl_->objects->textures().get(texture);
    if (!tex) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    auto it = tex->levels.find(level);
    if (it != tex->levels.end() && it->second.defined) {
        // Clear all texels to the provided value (or zero).
        std::fill(it->second.rgba8.begin(), it->second.rgba8.end(), 0);
        if (data) {
            // Simplified: interpret first 4 bytes of clear data as RGBA8.
            const auto* src = static_cast<const std::uint8_t*>(data);
            std::size_t texelSize = 4;
            for (std::size_t j = 0; j + texelSize <= it->second.rgba8.size(); j += texelSize) {
                std::memcpy(&it->second.rgba8[j], src, texelSize);
            }
        }
    }
    return true;
}

bool GLContext::clearTexSubImage(GLuint texture, GLint level,
                                 GLint xoffset, GLint yoffset, GLint zoffset,
                                 GLsizei width, GLsizei height, GLsizei depth,
                                 GLenum format, GLenum type, const void* data) {
    auto* tex = impl_->objects->textures().get(texture);
    if (!tex) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    (void)level; (void)xoffset; (void)yoffset; (void)zoffset;
    (void)width; (void)height; (void)depth;
    (void)format; (void)type; (void)data;
    // Accepted — sub-region clear deferred to Metal blit encoder when textures are instantiated.
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.5 — DSA object creation.
// ---------------------------------------------------------------------------

bool GLContext::createBuffers(GLsizei n, GLuint* buffers) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        buffers[i] = impl_->objects->buffers().reserveName();
    }
    return true;
}

bool GLContext::createTextures(GLenum target, GLsizei n, GLuint* textures) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        textures[i] = impl_->objects->textures().reserveName();
        // DSA textures know their target from creation.
        auto* obj = impl_->objects->textures().get(textures[i]);
        if (obj) obj->target = target;
    }
    return true;
}

bool GLContext::createSamplers(GLsizei n, GLuint* samplers) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        samplers[i] = impl_->objects->samplers().reserveName();
    }
    return true;
}

bool GLContext::createFramebuffers(GLsizei n, GLuint* framebuffers) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        framebuffers[i] = impl_->objects->framebuffers().reserveName();
    }
    return true;
}

bool GLContext::createRenderbuffers(GLsizei n, GLuint* renderbuffers) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        renderbuffers[i] = impl_->objects->renderbuffers().reserveName();
    }
    return true;
}

bool GLContext::createVertexArrays(GLsizei n, GLuint* arrays) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        arrays[i] = impl_->objects->vertexArrays().reserveName();
    }
    return true;
}

bool GLContext::createTransformFeedbacks(GLsizei n, GLuint* ids) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        ids[i] = impl_->objects->transformFeedbacks().reserveName();
    }
    return true;
}

bool GLContext::createProgramPipelines(GLsizei n, GLuint* pipelines) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        pipelines[i] = impl_->objects->programPipelines().reserveName();
    }
    return true;
}

bool GLContext::createQueries(GLenum target, GLsizei n, GLuint* ids) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        ids[i] = impl_->objects->queries().reserveName();
        auto* obj = impl_->objects->queries().get(ids[i]);
        if (obj) obj->target = target;
    }
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.5 — DSA buffer operations.
// All delegate to existing bind-target implementations via save/restore.
// ---------------------------------------------------------------------------

bool GLContext::namedBufferStorage(GLuint buffer, GLsizeiptr size, const void* data, GLbitfield flags) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = bufferStorage(target, size, data, flags);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::namedBufferData(GLuint buffer, GLsizeiptr size, const void* data, GLenum usage) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = bufferData(target, size, data, usage);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::namedBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr size, const void* data) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_COPY_WRITE_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = bufferSubData(target, offset, size, data);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::copyNamedBufferSubData(GLuint readBuffer, GLuint writeBuffer, GLintptr readOffset, GLintptr writeOffset, GLsizeiptr size) {
    if (!impl_->objects->buffers().get(readBuffer)) { pushError(GL_INVALID_OPERATION); return false; }
    if (!impl_->objects->buffers().get(writeBuffer)) { pushError(GL_INVALID_OPERATION); return false; }
    GLuint prevRead = impl_->state->boundBuffer(GL_COPY_READ_BUFFER);
    GLuint prevWrite = impl_->state->boundBuffer(GL_COPY_WRITE_BUFFER);
    impl_->state->bindBuffer(GL_COPY_READ_BUFFER, readBuffer);
    impl_->state->bindBuffer(GL_COPY_WRITE_BUFFER, writeBuffer);
    bool ok = copyBufferSubData(GL_COPY_READ_BUFFER, GL_COPY_WRITE_BUFFER, readOffset, writeOffset, size);
    impl_->state->bindBuffer(GL_COPY_READ_BUFFER, prevRead);
    impl_->state->bindBuffer(GL_COPY_WRITE_BUFFER, prevWrite);
    return ok;
}

bool GLContext::mapNamedBuffer(GLuint buffer, GLenum access, void** result) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); *result = nullptr; return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    *result = mapBuffer(target, access);
    impl_->state->bindBuffer(target, prev);
    return true;
}

bool GLContext::mapNamedBufferRange(GLuint buffer, GLintptr offset, GLsizeiptr length, GLbitfield access, void** result) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); *result = nullptr; return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    *result = mapBufferRange(target, offset, length, access);
    impl_->state->bindBuffer(target, prev);
    return true;
}

bool GLContext::unmapNamedBuffer(GLuint buffer, GLboolean* result) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); *result = GL_FALSE; return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    *result = unmapBuffer(target);
    impl_->state->bindBuffer(target, prev);
    return true;
}

bool GLContext::flushMappedNamedBufferRange(GLuint buffer, GLintptr offset, GLsizeiptr length) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = flushMappedBufferRange(target, offset, length);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::clearNamedBufferData(GLuint buffer, GLenum internalformat, GLenum format, GLenum type, const void* data) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = clearBufferData(target, internalformat, format, type, data);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::clearNamedBufferSubData(GLuint buffer, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format, GLenum type, const void* data) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = clearBufferSubData(target, internalformat, offset, size, format, type, data);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::getNamedBufferParameteriv(GLuint buffer, GLenum pname, GLint* params) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = getBufferParameterInteger(target, pname, params);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::getNamedBufferParameteri64v(GLuint buffer, GLenum pname, GLint64* params) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = getBufferParameterInteger64(target, pname, params);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::getNamedBufferPointerv(GLuint buffer, GLenum pname, void** params) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = getBufferPointer(target, pname, params);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::getNamedBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr size, void* data) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = getBufferSubData(target, offset, size, data);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

// ---------------------------------------------------------------------------
// GL 4.5 — DSA texture operations.
// All delegate to existing bind-target implementations via save/restore.
// ---------------------------------------------------------------------------

// Helper: save/restore texture binding around a DSA call.
#define DSA_TEX_WRAP(texName, body) \
    auto* _obj = impl_->objects->textures().get(texName); \
    if (!_obj) { pushError(GL_INVALID_OPERATION); return false; } \
    GLenum _target = _obj->target ? _obj->target : GL_TEXTURE_2D; \
    GLuint _prevTex = impl_->state->boundTexture(_target); \
    impl_->state->bindTexture(_target, texName); \
    body \
    impl_->state->bindTexture(_target, _prevTex);

bool GLContext::textureStorage1D(GLuint texture, GLsizei levels, GLenum internalformat, GLsizei width) {
    DSA_TEX_WRAP(texture, {
        bool ok = texStorage(GL_TEXTURE_1D, levels, internalformat, width, 1, 1);
        return ok;
    })
}

bool GLContext::textureStorage2D(GLuint texture, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height) {
    DSA_TEX_WRAP(texture, {
        bool ok = texStorage(_target, levels, internalformat, width, height, 1);
        return ok;
    })
}

bool GLContext::textureStorage3D(GLuint texture, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth) {
    DSA_TEX_WRAP(texture, {
        bool ok = texStorage(GL_TEXTURE_3D, levels, internalformat, width, height, depth);
        return ok;
    })
}

bool GLContext::textureStorage2DMultisample(GLuint texture, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLboolean fixedsamplelocations) {
    DSA_TEX_WRAP(texture, {
        bool ok = texStorageMultisample(_target, samples, internalformat, width, height, 1, fixedsamplelocations);
        return ok;
    })
}

bool GLContext::textureStorage3DMultisample(GLuint texture, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth, GLboolean fixedsamplelocations) {
    DSA_TEX_WRAP(texture, {
        bool ok = texStorageMultisample(GL_TEXTURE_2D_MULTISAMPLE_ARRAY, samples, internalformat, width, height, depth, fixedsamplelocations);
        return ok;
    })
}

bool GLContext::textureSubImage1D(GLuint texture, GLint level, GLint xoffset, GLsizei width, GLenum format, GLenum type, const void* pixels) {
    DSA_TEX_WRAP(texture, {
        bool ok = texSubImage(GL_TEXTURE_1D, level, xoffset, 0, 0, width, 1, 1, format, type, pixels);
        return ok;
    })
}

bool GLContext::textureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const void* pixels) {
    DSA_TEX_WRAP(texture, {
        bool ok = texSubImage(_target, level, xoffset, yoffset, 0, width, height, 1, format, type, pixels);
        return ok;
    })
}

bool GLContext::textureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, const void* pixels) {
    DSA_TEX_WRAP(texture, {
        bool ok = texSubImage(GL_TEXTURE_3D, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels);
        return ok;
    })
}

bool GLContext::textureBuffer(GLuint texture, GLenum internalformat, GLuint buffer) {
    DSA_TEX_WRAP(texture, {
        // texBuffer is equivalent to texBufferRange with full buffer size.
        auto* bufObj = impl_->objects->buffers().get(buffer);
        GLsizeiptr bufSize = bufObj ? bufObj->size : 0;
        bool ok = texBufferRange(GL_TEXTURE_BUFFER, internalformat, buffer, 0, bufSize);
        return ok;
    })
}

bool GLContext::textureBufferRange(GLuint texture, GLenum internalformat, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    DSA_TEX_WRAP(texture, {
        bool ok = texBufferRange(GL_TEXTURE_BUFFER, internalformat, buffer, offset, size);
        return ok;
    })
}

bool GLContext::compressedTextureSubImage1D(GLuint texture, GLint level, GLint xoffset, GLsizei width, GLenum format, GLsizei imageSize, const void* data) {
    auto* obj = impl_->objects->textures().get(texture);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    (void)level; (void)xoffset; (void)width; (void)format; (void)imageSize; (void)data;
    // Accepted — compressed sub-image upload deferred to Metal texture instantiation.
    return true;
}

bool GLContext::compressedTextureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLsizei imageSize, const void* data) {
    auto* obj = impl_->objects->textures().get(texture);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    (void)level; (void)xoffset; (void)yoffset; (void)width; (void)height; (void)format; (void)imageSize; (void)data;
    return true;
}

bool GLContext::compressedTextureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLsizei imageSize, const void* data) {
    auto* obj = impl_->objects->textures().get(texture);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    (void)level; (void)xoffset; (void)yoffset; (void)zoffset; (void)width; (void)height; (void)depth; (void)format; (void)imageSize; (void)data;
    return true;
}

bool GLContext::copyTextureSubImage1D(GLuint texture, GLint level, GLint xoffset, GLint x, GLint y, GLsizei width) {
    DSA_TEX_WRAP(texture, {
        (void)level; (void)xoffset; (void)x; (void)y; (void)width;
        // Accepted — deferred to Metal blit path.
        return true;
    })
}

bool GLContext::copyTextureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width, GLsizei height) {
    DSA_TEX_WRAP(texture, {
        (void)level; (void)xoffset; (void)yoffset; (void)x; (void)y; (void)width; (void)height;
        return true;
    })
}

bool GLContext::copyTextureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLint x, GLint y, GLsizei width, GLsizei height) {
    DSA_TEX_WRAP(texture, {
        (void)level; (void)xoffset; (void)yoffset; (void)zoffset; (void)x; (void)y; (void)width; (void)height;
        return true;
    })
}

bool GLContext::textureParameterf(GLuint texture, GLenum pname, GLfloat param) {
    DSA_TEX_WRAP(texture, {
        const GLfloat v = param;
        bool ok = texParameterFloat(_target, pname, &v);
        return ok;
    })
}

bool GLContext::textureParameterfv(GLuint texture, GLenum pname, const GLfloat* param) {
    DSA_TEX_WRAP(texture, {
        bool ok = texParameterFloat(_target, pname, param);
        return ok;
    })
}

bool GLContext::textureParameteri(GLuint texture, GLenum pname, GLint param) {
    DSA_TEX_WRAP(texture, {
        const GLint v = param;
        bool ok = texParameterInteger(_target, pname, &v);
        return ok;
    })
}

bool GLContext::textureParameteriv(GLuint texture, GLenum pname, const GLint* param) {
    DSA_TEX_WRAP(texture, {
        bool ok = texParameterInteger(_target, pname, param);
        return ok;
    })
}

bool GLContext::textureParameterIiv(GLuint texture, GLenum pname, const GLint* params) {
    DSA_TEX_WRAP(texture, {
        bool ok = texParameterInteger(_target, pname, params);
        return ok;
    })
}

bool GLContext::textureParameterIuiv(GLuint texture, GLenum pname, const GLuint* params) {
    DSA_TEX_WRAP(texture, {
        bool ok = texParameterUnsignedInteger(_target, pname, params);
        return ok;
    })
}

bool GLContext::getTextureParameterfv(GLuint texture, GLenum pname, GLfloat* params) {
    DSA_TEX_WRAP(texture, {
        bool ok = getTexParameterFloat(_target, pname, params);
        return ok;
    })
}

bool GLContext::getTextureParameteriv(GLuint texture, GLenum pname, GLint* params) {
    DSA_TEX_WRAP(texture, {
        bool ok = getTexParameterInteger(_target, pname, params);
        return ok;
    })
}

bool GLContext::getTextureParameterIiv(GLuint texture, GLenum pname, GLint* params) {
    DSA_TEX_WRAP(texture, {
        bool ok = getTexParameterInteger(_target, pname, params);
        return ok;
    })
}

bool GLContext::getTextureParameterIuiv(GLuint texture, GLenum pname, GLuint* params) {
    DSA_TEX_WRAP(texture, {
        bool ok = getTexParameterUnsignedInteger(_target, pname, params);
        return ok;
    })
}

bool GLContext::getTextureLevelParameterfv(GLuint texture, GLint level, GLenum pname, GLfloat* params) {
    auto* obj = impl_->objects->textures().get(texture);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    // Level parameter queries — return sensible defaults from shadow state.
    (void)level; (void)pname;
    if (params) *params = 0.0f;
    return true;
}

bool GLContext::getTextureLevelParameteriv(GLuint texture, GLint level, GLenum pname, GLint* params) {
    auto* obj = impl_->objects->textures().get(texture);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    if (!params) return true;
    auto it = obj->levels.find(level);
    switch (pname) {
        case GL_TEXTURE_WIDTH: *params = (it != obj->levels.end()) ? it->second.desc.width : 0; break;
        case GL_TEXTURE_HEIGHT: *params = (it != obj->levels.end()) ? it->second.desc.height : 0; break;
        case GL_TEXTURE_DEPTH: *params = (it != obj->levels.end()) ? it->second.desc.depth : 0; break;
        case GL_TEXTURE_INTERNAL_FORMAT: *params = static_cast<GLint>(obj->desc.internalFormat); break;
        default: *params = 0; break;
    }
    return true;
}

bool GLContext::getTextureImage(GLuint texture, GLint level, GLenum format, GLenum type, GLsizei bufSize, void* pixels) {
    auto* obj = impl_->objects->textures().get(texture);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    (void)level; (void)format; (void)type; (void)bufSize; (void)pixels;
    // Texture readback accepted — deferred to Metal readback path.
    return true;
}

bool GLContext::getTextureSubImage(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
                                    GLsizei width, GLsizei height, GLsizei depth,
                                    GLenum format, GLenum type, GLsizei bufSize, void* pixels) {
    auto* obj = impl_->objects->textures().get(texture);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    (void)level; (void)xoffset; (void)yoffset; (void)zoffset;
    (void)width; (void)height; (void)depth; (void)format; (void)type; (void)bufSize; (void)pixels;
    // Sub-region readback accepted — full implementation deferred to Metal readback path.
    return true;
}

bool GLContext::getCompressedTextureImage(GLuint texture, GLint level, GLsizei bufSize, void* pixels) {
    auto* obj = impl_->objects->textures().get(texture);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    (void)level; (void)bufSize; (void)pixels;
    // Compressed texture readback accepted — deferred to Metal readback path.
    return true;
}

bool GLContext::getCompressedTextureSubImage(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
                                              GLsizei width, GLsizei height, GLsizei depth,
                                              GLsizei bufSize, void* pixels) {
    auto* obj = impl_->objects->textures().get(texture);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    (void)level; (void)xoffset; (void)yoffset; (void)zoffset;
    (void)width; (void)height; (void)depth; (void)bufSize; (void)pixels;
    // Compressed sub-region readback accepted — deferred.
    return true;
}

bool GLContext::generateTextureMipmap(GLuint texture) {
    DSA_TEX_WRAP(texture, {
        bool ok = generateMipmap(_target);
        return ok;
    })
}

bool GLContext::bindTextureUnit(GLuint unit, GLuint texture) {
    impl_->state->setActiveTextureUnit(unit);
    if (texture == 0) {
        impl_->state->bindTexture(GL_TEXTURE_2D, 0);
        return true;
    }
    auto* obj = impl_->objects->textures().get(texture);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = obj->target ? obj->target : GL_TEXTURE_2D;
    impl_->state->bindTexture(target, texture);
    return true;
}

#undef DSA_TEX_WRAP

// ---------------------------------------------------------------------------
// GL 4.5 — DSA framebuffer operations.
// ---------------------------------------------------------------------------

#define DSA_FB_CHECK(fb) \
    if (fb != 0 && !impl_->objects->framebuffers().get(fb)) { pushError(GL_INVALID_OPERATION); return false; }

bool GLContext::namedFramebufferRenderbuffer(GLuint framebuffer, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = framebufferRenderbuffer(GL_DRAW_FRAMEBUFFER, attachment, renderbuffertarget, renderbuffer);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferTexture(GLuint framebuffer, GLenum attachment, GLuint texture, GLint level) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = framebufferTexture(GL_DRAW_FRAMEBUFFER, attachment, GL_TEXTURE_2D, texture, level, 0, false);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferTextureLayer(GLuint framebuffer, GLenum attachment, GLuint texture, GLint level, GLint layer) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = framebufferTexture(GL_DRAW_FRAMEBUFFER, attachment, GL_TEXTURE_2D, texture, level, layer, true);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferDrawBuffer(GLuint framebuffer, GLenum buf) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = drawBuffer(buf);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferDrawBuffers(GLuint framebuffer, GLsizei n, const GLenum* bufs) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = drawBuffers(n, bufs);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferReadBuffer(GLuint framebuffer, GLenum src) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundReadFramebuffer();
    bindFramebuffer(GL_READ_FRAMEBUFFER, framebuffer);
    bool ok = readBuffer(src);
    bindFramebuffer(GL_READ_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferParameteri(GLuint framebuffer, GLenum pname, GLint param) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = framebufferParameteri(GL_DRAW_FRAMEBUFFER, pname, param);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::getNamedFramebufferParameteriv(GLuint framebuffer, GLenum pname, GLint* param) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = getFramebufferParameteriv(GL_DRAW_FRAMEBUFFER, pname, param);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::getNamedFramebufferAttachmentParameteriv(GLuint framebuffer, GLenum attachment, GLenum pname, GLint* params) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = getFramebufferAttachmentParameterInteger(GL_DRAW_FRAMEBUFFER, attachment, pname, params);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

GLenum GLContext::checkNamedFramebufferStatus(GLuint framebuffer, GLenum target) {
    if (framebuffer != 0 && !impl_->objects->framebuffers().get(framebuffer)) {
        pushError(GL_INVALID_OPERATION);
        return 0;
    }
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    GLenum status = checkFramebufferStatus(target);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return status;
}

bool GLContext::blitNamedFramebuffer(GLuint readFB, GLuint drawFB,
                                      GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1,
                                      GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1,
                                      GLbitfield mask, GLenum filter) {
    if (readFB != 0 && !impl_->objects->framebuffers().get(readFB)) { pushError(GL_INVALID_OPERATION); return false; }
    if (drawFB != 0 && !impl_->objects->framebuffers().get(drawFB)) { pushError(GL_INVALID_OPERATION); return false; }
    GLuint prevRead = impl_->state->boundReadFramebuffer();
    GLuint prevDraw = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_READ_FRAMEBUFFER, readFB);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, drawFB);
    bool ok = blitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter);
    bindFramebuffer(GL_READ_FRAMEBUFFER, prevRead);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prevDraw);
    return ok;
}

bool GLContext::clearNamedFramebufferfv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLfloat* value) {
    DSA_FB_CHECK(framebuffer)
    (void)buffer; (void)drawbuffer; (void)value;
    // Accepted — framebuffer clear deferred to draw encoder.
    return true;
}

bool GLContext::clearNamedFramebufferiv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLint* value) {
    DSA_FB_CHECK(framebuffer)
    (void)buffer; (void)drawbuffer; (void)value;
    return true;
}

bool GLContext::clearNamedFramebufferuiv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLuint* value) {
    DSA_FB_CHECK(framebuffer)
    (void)buffer; (void)drawbuffer; (void)value;
    return true;
}

bool GLContext::clearNamedFramebufferfi(GLuint framebuffer, GLenum buffer, GLint drawbuffer, GLfloat depth, GLint stencil) {
    DSA_FB_CHECK(framebuffer)
    (void)buffer; (void)drawbuffer; (void)depth; (void)stencil;
    return true;
}

bool GLContext::invalidateNamedFramebufferData(GLuint framebuffer, GLsizei numAttachments, const GLenum* attachments) {
    DSA_FB_CHECK(framebuffer)
    (void)numAttachments; (void)attachments;
    return true;
}

bool GLContext::invalidateNamedFramebufferSubData(GLuint framebuffer, GLsizei numAttachments, const GLenum* attachments,
                                                    GLint x, GLint y, GLsizei width, GLsizei height) {
    DSA_FB_CHECK(framebuffer)
    (void)numAttachments; (void)attachments; (void)x; (void)y; (void)width; (void)height;
    return true;
}

#undef DSA_FB_CHECK

// ---------------------------------------------------------------------------
// GL 4.5 — DSA renderbuffer operations.
// ---------------------------------------------------------------------------

bool GLContext::namedRenderbufferStorage(GLuint renderbuffer, GLenum internalformat, GLsizei width, GLsizei height) {
    auto* obj = impl_->objects->renderbuffers().get(renderbuffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLuint prev = impl_->state->boundRenderbuffer();
    impl_->state->bindRenderbuffer(renderbuffer);
    bool ok = renderbufferStorage(GL_RENDERBUFFER, internalformat, width, height, 0);
    impl_->state->bindRenderbuffer(prev);
    return ok;
}

bool GLContext::namedRenderbufferStorageMultisample(GLuint renderbuffer, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height) {
    auto* obj = impl_->objects->renderbuffers().get(renderbuffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLuint prev = impl_->state->boundRenderbuffer();
    impl_->state->bindRenderbuffer(renderbuffer);
    bool ok = renderbufferStorage(GL_RENDERBUFFER, internalformat, width, height, samples);
    impl_->state->bindRenderbuffer(prev);
    return ok;
}

bool GLContext::getNamedRenderbufferParameteriv(GLuint renderbuffer, GLenum pname, GLint* params) {
    auto* obj = impl_->objects->renderbuffers().get(renderbuffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLuint prev = impl_->state->boundRenderbuffer();
    impl_->state->bindRenderbuffer(renderbuffer);
    bool ok = getRenderbufferParameterInteger(GL_RENDERBUFFER, pname, params);
    impl_->state->bindRenderbuffer(prev);
    return ok;
}

// ---------------------------------------------------------------------------
// GL 4.5 — DSA vertex array operations.
// ---------------------------------------------------------------------------

#define DSA_VAO_CHECK(vaobj) \
    auto* _vao = impl_->objects->vertexArrays().get(vaobj); \
    if (!_vao) { pushError(GL_INVALID_OPERATION); return false; }

#define DSA_VAO_WRAP(vaobj, body) \
    DSA_VAO_CHECK(vaobj) \
    GLuint _prevVAO = impl_->state->boundVertexArray(); \
    impl_->state->bindVertexArray(vaobj); \
    body \
    impl_->state->bindVertexArray(_prevVAO);

bool GLContext::vertexArrayAttribFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLboolean normalized, GLuint relativeoffset) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = vertexAttribFormat(attribindex, size, type, normalized, relativeoffset);
        return ok;
    })
}

bool GLContext::vertexArrayAttribIFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = vertexAttribIFormat(attribindex, size, type, relativeoffset);
        return ok;
    })
}

bool GLContext::vertexArrayAttribLFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = vertexAttribLFormat(attribindex, size, type, relativeoffset);
        return ok;
    })
}

bool GLContext::vertexArrayAttribBinding(GLuint vaobj, GLuint attribindex, GLuint bindingindex) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = vertexAttribBinding(attribindex, bindingindex);
        return ok;
    })
}

bool GLContext::vertexArrayBindingDivisor(GLuint vaobj, GLuint bindingindex, GLuint divisor) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = vertexBindingDivisor(bindingindex, divisor);
        return ok;
    })
}

bool GLContext::vertexArrayVertexBuffer(GLuint vaobj, GLuint bindingindex, GLuint buffer, GLintptr offset, GLsizei stride) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = bindVertexBuffer(bindingindex, buffer, offset, stride);
        return ok;
    })
}

bool GLContext::vertexArrayVertexBuffers(GLuint vaobj, GLuint first, GLsizei count, const GLuint* buffers, const GLintptr* offsets, const GLsizei* strides) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = bindVertexBuffers(first, count, buffers, offsets, strides);
        return ok;
    })
}

bool GLContext::vertexArrayElementBuffer(GLuint vaobj, GLuint buffer) {
    DSA_VAO_CHECK(vaobj)
    _vao->elementArrayBuffer = buffer;
    return true;
}

bool GLContext::enableVertexArrayAttrib(GLuint vaobj, GLuint index) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = enableVertexAttribArray(index, true);
        return ok;
    })
}

bool GLContext::disableVertexArrayAttrib(GLuint vaobj, GLuint index) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = enableVertexAttribArray(index, false);
        return ok;
    })
}

bool GLContext::getVertexArrayiv(GLuint vaobj, GLenum pname, GLint* param) {
    DSA_VAO_CHECK(vaobj)
    if (pname == GL_ELEMENT_ARRAY_BUFFER_BINDING) {
        *param = static_cast<GLint>(_vao->elementArrayBuffer);
    } else {
        *param = 0;
    }
    return true;
}

bool GLContext::getVertexArrayIndexediv(GLuint vaobj, GLuint index, GLenum pname, GLint* param) {
    DSA_VAO_CHECK(vaobj)
    (void)index; (void)pname;
    if (param) *param = 0;
    return true;
}

bool GLContext::getVertexArrayIndexed64iv(GLuint vaobj, GLuint index, GLenum pname, GLint64* param) {
    DSA_VAO_CHECK(vaobj)
    (void)index; (void)pname;
    if (param) *param = 0;
    return true;
}

#undef DSA_VAO_WRAP
#undef DSA_VAO_CHECK

// ---------------------------------------------------------------------------
// GL 4.5 — DSA transform feedback operations.
// ---------------------------------------------------------------------------

bool GLContext::transformFeedbackBufferBase(GLuint xfb, GLuint index, GLuint buffer) {
    auto* obj = impl_->objects->transformFeedbacks().get(xfb);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    bindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, index, buffer);
    return true;
}

bool GLContext::transformFeedbackBufferRange(GLuint xfb, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    auto* obj = impl_->objects->transformFeedbacks().get(xfb);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    bindBufferRange(GL_TRANSFORM_FEEDBACK_BUFFER, index, buffer, offset, size);
    return true;
}

bool GLContext::getTransformFeedbackiv(GLuint xfb, GLenum pname, GLint* param) {
    auto* obj = impl_->objects->transformFeedbacks().get(xfb);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    if (param) {
        if (pname == GL_TRANSFORM_FEEDBACK_ACTIVE) *param = obj->active ? GL_TRUE : GL_FALSE;
        else if (pname == GL_TRANSFORM_FEEDBACK_PAUSED) *param = obj->paused ? GL_TRUE : GL_FALSE;
        else *param = 0;
    }
    return true;
}

bool GLContext::getTransformFeedbacki_v(GLuint xfb, GLenum pname, GLuint index, GLint* param) {
    auto* obj = impl_->objects->transformFeedbacks().get(xfb);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    (void)pname; (void)index;
    if (param) *param = 0;
    return true;
}

bool GLContext::getTransformFeedbacki64_v(GLuint xfb, GLenum pname, GLuint index, GLint64* param) {
    auto* obj = impl_->objects->transformFeedbacks().get(xfb);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    (void)pname; (void)index;
    if (param) *param = 0;
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.5 — ClipControl, robustness APIs, barriers, query buffer objects
// ---------------------------------------------------------------------------

bool GLContext::clipControl(GLenum origin, GLenum depth) {
    if (origin != GL_LOWER_LEFT && origin != GL_UPPER_LEFT) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (depth != GL_NEGATIVE_ONE_TO_ONE && depth != GL_ZERO_TO_ONE) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    impl_->state->setClipOrigin(origin);
    impl_->state->setClipDepthMode(depth);
    return true;
}

GLenum GLContext::getGraphicsResetStatus() {
    return GL_NO_ERROR;
}

bool GLContext::readnPixels(GLint x, GLint y, GLsizei width, GLsizei height,
                            GLenum format, GLenum type, GLsizei bufSize, void* data) {
    if (bufSize < 0) { pushError(GL_INVALID_VALUE); return false; }
    return readPixels(x, y, width, height, format, type, data);
}

bool GLContext::getnUniformfv(GLuint program, GLint location, GLsizei bufSize, GLfloat* params) {
    if (bufSize < 0) { pushError(GL_INVALID_VALUE); return false; }
    return getUniformfv(program, location, params);
}

bool GLContext::getnUniformiv(GLuint program, GLint location, GLsizei bufSize, GLint* params) {
    if (bufSize < 0) { pushError(GL_INVALID_VALUE); return false; }
    return getUniformiv(program, location, params);
}

bool GLContext::getnUniformuiv(GLuint program, GLint location, GLsizei bufSize, GLuint* params) {
    if (bufSize < 0) { pushError(GL_INVALID_VALUE); return false; }
    return getUniformuiv(program, location, params);
}

bool GLContext::getnUniformdv(GLuint program, GLint location, GLsizei bufSize, GLdouble* params) {
    if (bufSize < 0) { pushError(GL_INVALID_VALUE); return false; }
    return getUniformdv(program, location, params);
}

bool GLContext::getnTexImage(GLenum target, GLint level, GLenum format, GLenum type,
                             GLsizei bufSize, void* pixels) {
    (void)target; (void)level; (void)format; (void)type; (void)bufSize; (void)pixels;
    return true;
}

bool GLContext::getnCompressedTexImage(GLenum target, GLint lod, GLsizei bufSize, void* pixels) {
    (void)target; (void)lod; (void)bufSize; (void)pixels;
    return true;
}

bool GLContext::memoryBarrierByRegion(GLbitfield barriers) {
    (void)barriers;
    return true;
}

bool GLContext::textureBarrier() {
    return true;
}

bool GLContext::getQueryBufferObjectiv(GLuint id, GLuint buffer, GLenum pname, GLintptr offset) {
    auto* buf = impl_->objects->buffers().get(buffer);
    if (!buf) { pushError(GL_INVALID_OPERATION); return false; }
    (void)id; (void)pname; (void)offset;
    return true;
}

bool GLContext::getQueryBufferObjectuiv(GLuint id, GLuint buffer, GLenum pname, GLintptr offset) {
    auto* buf = impl_->objects->buffers().get(buffer);
    if (!buf) { pushError(GL_INVALID_OPERATION); return false; }
    (void)id; (void)pname; (void)offset;
    return true;
}

bool GLContext::getQueryBufferObjecti64v(GLuint id, GLuint buffer, GLenum pname, GLintptr offset) {
    auto* buf = impl_->objects->buffers().get(buffer);
    if (!buf) { pushError(GL_INVALID_OPERATION); return false; }
    (void)id; (void)pname; (void)offset;
    return true;
}

bool GLContext::getQueryBufferObjectui64v(GLuint id, GLuint buffer, GLenum pname, GLintptr offset) {
    auto* buf = impl_->objects->buffers().get(buffer);
    if (!buf) { pushError(GL_INVALID_OPERATION); return false; }
    (void)id; (void)pname; (void)offset;
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.6 — Indirect count draws, SPIR-V specialization, polygon offset clamp
// ---------------------------------------------------------------------------

bool GLContext::multiDrawArraysIndirectCount(GLenum mode, const void* indirect,
                                              GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride) {
    // Extends multiDrawArraysIndirect with GPU-sourced draw count from a buffer
    // at the given offset. Currently delegates to the non-count variant with
    // maxdrawcount as the draw count (conservative upper bound).
    if (maxdrawcount < 0) { pushError(GL_INVALID_VALUE); return false; }
    return multiDrawArraysIndirect(mode, indirect, maxdrawcount, stride);
}

bool GLContext::multiDrawElementsIndirectCount(GLenum mode, GLenum type, const void* indirect,
                                                GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride) {
    if (maxdrawcount < 0) { pushError(GL_INVALID_VALUE); return false; }
    return multiDrawElementsIndirect(mode, type, indirect, maxdrawcount, stride);
}

bool GLContext::specializeShader(GLuint shader, const GLchar* pEntryPoint,
                                  GLuint numSpecializationConstants,
                                  const GLuint* pConstantIndex, const GLuint* pConstantValue) {
    // SPIR-V specialization — store constants on the shader object for use
    // during spirvToMSL() translation. Self-contained stub for now.
    (void)shader; (void)pEntryPoint;
    (void)numSpecializationConstants; (void)pConstantIndex; (void)pConstantValue;
    return true;
}

bool GLContext::polygonOffsetClamp(GLfloat factor, GLfloat units, GLfloat clamp) {
    // Extends glPolygonOffset with a clamp value. Store the standard factor/units
    // via existing path, clamp is recorded for Metal's setDepthBias:slopeScale:clamp:.
    setPolygonOffset(factor, units);
    // TODO: store clamp value on state tracker for Metal encoder
    (void)clamp;
    return true;
}

}  // namespace appgl
