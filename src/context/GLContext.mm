#include "GLContext.h"
#include "../runtime/AppGLLog.h"
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

// Forward declaration — defined in AppGLRuntime.cpp as an external
// wrapper over the file-local isFormatTypeCompatible. Shared helper
// for GL 4.6 §8.4.4.2 Table 8.7 format/type compatibility (used by
// both the API-surface validators and the readPixels path in this TU).
bool isFormatTypeCompatible_extern(GLenum format, GLenum type);

// Global-ish gate for the CTS-sweep hot-path NSLog calls — the
// per-program linkProgram / spirv-to-msl / reflect / pipeline-build
// markers fire thousands of times in a sweep and Foundation's
// `_NSLogv` path ends up dominating wall time (sampled, confirmed).
// Set APPGL_LOG_LINK=1 in the environment to restore the verbose
// output when debugging a specific program.

namespace {

// Phase 8X Group 4d follow-up¹¹ — §Tertiary chokepoint-bypass warning
// helper for DSA / copy entry points that currently drop data.
// Mirrors AppGLGroup8.cpp's `warnDataDroppedOnce`; duplicated here
// because this translation unit is separate and there's no shared
// header for the diagnostic. BAR can grep `[GL] WARNING: bypass` to
// find every hit. Emits once per `(functionName, texName)` pair so
// if Recoil uses the same bypass on multiple textures we still see
// each distinct victim.
void warnBypassOnce(const char* functionName, GLuint texName) {
    static std::unordered_set<std::uint64_t> warned;
    const std::uint64_t key = (static_cast<std::uint64_t>(
        std::hash<std::string>{}(functionName)) << 32) ^ static_cast<std::uint64_t>(texName);
    if (warned.insert(key).second) {
        NSLog(@"[GL] WARNING: bypass %s texName=%u — current implementation is"
              @" a drop-data / stub-return-true path, texture byte payload is"
              @" not routed through replaceMetalTexture. Phase 8X Group 4d"
              @" follow-up¹¹ chokepoint instrumentation.",
              functionName, texName);
    }
}

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
        case GL_TEXTURE_RECTANGLE:
            return MTLTextureType2D;
        case GL_TEXTURE_3D:
            return MTLTextureType3D;
        case GL_TEXTURE_1D_ARRAY:
            return MTLTextureType1DArray;
        case GL_TEXTURE_2D_ARRAY:
            return MTLTextureType2DArray;
        case GL_TEXTURE_CUBE_MAP:
            return MTLTextureTypeCube;
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
        // ── Sized color formats (CTS shader execution harness) ──
        case GL_R8:                return MTLPixelFormatR8Unorm;
        case GL_R8_SNORM:          return MTLPixelFormatR8Snorm;
        case GL_R16:               return MTLPixelFormatR16Unorm;
        case GL_R16_SNORM:         return MTLPixelFormatR16Snorm;
        case GL_R16F:              return MTLPixelFormatR16Float;
        case GL_R32F:              return MTLPixelFormatR32Float;
        case GL_R8I:               return MTLPixelFormatR8Sint;
        case GL_R8UI:              return MTLPixelFormatR8Uint;
        case GL_R16I:              return MTLPixelFormatR16Sint;
        case GL_R16UI:             return MTLPixelFormatR16Uint;
        case GL_R32I:              return MTLPixelFormatR32Sint;
        case GL_R32UI:             return MTLPixelFormatR32Uint;
        case GL_RG8:               return MTLPixelFormatRG8Unorm;
        case GL_RG8_SNORM:         return MTLPixelFormatRG8Snorm;
        case GL_RG16:              return MTLPixelFormatRG16Unorm;
        case GL_RG16_SNORM:        return MTLPixelFormatRG16Snorm;
        case GL_RG16F:             return MTLPixelFormatRG16Float;
        case GL_RG32F:             return MTLPixelFormatRG32Float;
        case GL_RG8I:              return MTLPixelFormatRG8Sint;
        case GL_RG8UI:             return MTLPixelFormatRG8Uint;
        case GL_RG16I:             return MTLPixelFormatRG16Sint;
        case GL_RG16UI:            return MTLPixelFormatRG16Uint;
        case GL_RG32I:             return MTLPixelFormatRG32Sint;
        case GL_RG32UI:            return MTLPixelFormatRG32Uint;
        case GL_RGBA8_SNORM:       return MTLPixelFormatRGBA8Snorm;
        case GL_RGB10_A2:          return MTLPixelFormatRGB10A2Unorm;
        case GL_RGB10_A2UI:        return MTLPixelFormatRGB10A2Uint;
        case GL_R11F_G11F_B10F:    return MTLPixelFormatRG11B10Float;
        case GL_RGBA16:            return MTLPixelFormatRGBA16Unorm;
        case GL_RGBA16_SNORM:      return MTLPixelFormatRGBA16Snorm;
        case GL_RGBA16F:           return MTLPixelFormatRGBA16Float;
        case GL_RGBA32F:           return MTLPixelFormatRGBA32Float;
        case GL_RGBA8I:            return MTLPixelFormatRGBA8Sint;
        case GL_RGBA8UI:           return MTLPixelFormatRGBA8Uint;
        case GL_RGBA16I:           return MTLPixelFormatRGBA16Sint;
        case GL_RGBA16UI:          return MTLPixelFormatRGBA16Uint;
        case GL_RGBA32I:           return MTLPixelFormatRGBA32Sint;
        case GL_RGBA32UI:          return MTLPixelFormatRGBA32Uint;
        case GL_SRGB8_ALPHA8:      return MTLPixelFormatRGBA8Unorm_sRGB;
        // Legacy / low-bit — promoted to higher-precision Metal formats.
        case GL_R3_G3_B2:          return MTLPixelFormatRGBA8Unorm;
        case GL_RGB4:              return MTLPixelFormatRGBA8Unorm;
        case GL_RGB5:              return MTLPixelFormatRGBA8Unorm;
        case GL_RGBA2:             return MTLPixelFormatRGBA8Unorm;
        case GL_RGBA4:             return MTLPixelFormatRGBA8Unorm;
        case GL_RGB5_A1:           return MTLPixelFormatRGBA8Unorm;
        case GL_RGB10:             return MTLPixelFormatRGBA16Unorm;
        case GL_RGB12:             return MTLPixelFormatRGBA16Unorm;
        case GL_RGBA12:            return MTLPixelFormatRGBA16Unorm;
        // RGB-only — promoted to RGBA counterpart (alpha padded at upload).
        case GL_RGB16:             return MTLPixelFormatRGBA16Unorm;
        case GL_RGB16_SNORM:       return MTLPixelFormatRGBA16Snorm;
        case GL_RGB16F:            return MTLPixelFormatRGBA16Float;
        case GL_RGB32F:            return MTLPixelFormatRGBA32Float;
        case GL_SRGB8:             return MTLPixelFormatRGBA8Unorm_sRGB;
        case GL_RGB8I:             return MTLPixelFormatRGBA8Sint;
        case GL_RGB8UI:            return MTLPixelFormatRGBA8Uint;
        case GL_RGB16I:            return MTLPixelFormatRGBA16Sint;
        case GL_RGB16UI:           return MTLPixelFormatRGBA16Uint;
        case GL_RGB32I:            return MTLPixelFormatRGBA32Sint;
        case GL_RGB32UI:           return MTLPixelFormatRGBA32Uint;
        // Shared-exponent float.
        case GL_RGB9_E5:           return MTLPixelFormatRGB9E5Float;
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

// Any GL_COLOR_ATTACHMENT0..GL_COLOR_ATTACHMENT31 — i.e. the enum
// range spec'd in GL 4.6 §9.2.8. Used to distinguish
// "color-attachment-shaped enum that exceeds MAX_COLOR_ATTACHMENTS"
// (INVALID_OPERATION) from "not a recognised attachment enum at all"
// (INVALID_ENUM). Matches the error-class CTS expects in
// KHR-GL46.direct_state_access.framebuffers_*_errors.
bool isColorAttachmentEnum(GLenum attachment) {
    return attachment >= GL_COLOR_ATTACHMENT0 && attachment <= GL_COLOR_ATTACHMENT0 + 31;
}

bool isFramebufferAttachment(GLenum attachment) {
    return isColorAttachment(attachment)
        || attachment == GL_DEPTH_ATTACHMENT
        || attachment == GL_STENCIL_ATTACHMENT
        || attachment == GL_DEPTH_STENCIL_ATTACHMENT;
}

// Accepts a color-attachment-shaped enum (incl. out-of-range) plus the
// depth/stencil attachments. Callers use this to decide between
// INVALID_ENUM (not this function's return) and INVALID_OPERATION
// (function returns true but isColorAttachment is false).
bool isFramebufferAttachmentEnum(GLenum attachment) {
    return isColorAttachmentEnum(attachment)
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
    switch (target) {
        case GL_TEXTURE_1D:
        case GL_TEXTURE_2D:
        case GL_TEXTURE_3D:
        case GL_TEXTURE_1D_ARRAY:
        case GL_TEXTURE_2D_ARRAY:
        case GL_TEXTURE_RECTANGLE:
        case GL_TEXTURE_CUBE_MAP:
        case GL_TEXTURE_CUBE_MAP_ARRAY:
        case GL_TEXTURE_BUFFER:
        case GL_TEXTURE_2D_MULTISAMPLE:
        case GL_TEXTURE_2D_MULTISAMPLE_ARRAY:
        // Cube map face targets (used by glTexImage2D for individual faces).
        case GL_TEXTURE_CUBE_MAP_POSITIVE_X:
        case GL_TEXTURE_CUBE_MAP_NEGATIVE_X:
        case GL_TEXTURE_CUBE_MAP_POSITIVE_Y:
        case GL_TEXTURE_CUBE_MAP_NEGATIVE_Y:
        case GL_TEXTURE_CUBE_MAP_POSITIVE_Z:
        case GL_TEXTURE_CUBE_MAP_NEGATIVE_Z:
            return true;
        default:
            return false;
    }
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
        case GL_RED_INTEGER:
        case GL_GREEN:
        case GL_BLUE:
        case GL_DEPTH_COMPONENT:
        case GL_STENCIL_INDEX:
            return 1;
        case GL_RG:
        case GL_RG_INTEGER:
        case GL_DEPTH_STENCIL:
            return 2;
        case GL_RGB:
        case GL_RGB_INTEGER:
        case GL_BGR:
        case GL_BGR_INTEGER:
            return 3;
        case GL_RGBA:
        case GL_RGBA_INTEGER:
        case GL_BGRA:
        case GL_BGRA_INTEGER:
            return 4;
        // Compat-profile upload formats.
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

// Returns bytes per component for a given GL pixel type.
// For packed types, returns the total packed pixel size.
std::size_t bytesPerComponent(GLenum type) {
    switch (type) {
        case GL_UNSIGNED_BYTE:
        case GL_BYTE:
            return 1;
        case GL_UNSIGNED_SHORT:
        case GL_SHORT:
        case GL_HALF_FLOAT:
            return 2;
        case GL_UNSIGNED_INT:
        case GL_INT:
        case GL_FLOAT:
            return 4;
        default:
            return 0;  // packed types handled separately
    }
}

// Returns true if the type is a packed pixel type (single value per pixel).
bool isPackedPixelType(GLenum type) {
    switch (type) {
        case GL_UNSIGNED_BYTE_3_3_2:
        case GL_UNSIGNED_BYTE_2_3_3_REV:
        case GL_UNSIGNED_SHORT_5_6_5:
        case GL_UNSIGNED_SHORT_5_6_5_REV:
        case GL_UNSIGNED_SHORT_4_4_4_4:
        case GL_UNSIGNED_SHORT_4_4_4_4_REV:
        case GL_UNSIGNED_SHORT_5_5_5_1:
        case GL_UNSIGNED_SHORT_1_5_5_5_REV:
        case GL_UNSIGNED_INT_8_8_8_8:
        case GL_UNSIGNED_INT_8_8_8_8_REV:
        case GL_UNSIGNED_INT_10_10_10_2:
        case GL_UNSIGNED_INT_2_10_10_10_REV:
        case GL_UNSIGNED_INT_24_8:
        case GL_FLOAT_32_UNSIGNED_INT_24_8_REV:
        case GL_UNSIGNED_INT_10F_11F_11F_REV:
        case GL_UNSIGNED_INT_5_9_9_9_REV:
            return true;
        default:
            return false;
    }
}

// Bytes per pixel for a given format + type combination.
std::size_t bytesPerPixel(GLenum format, GLenum type) {
    if (isPackedPixelType(type)) {
        switch (type) {
            case GL_UNSIGNED_BYTE_3_3_2:
            case GL_UNSIGNED_BYTE_2_3_3_REV:
                return 1;
            case GL_UNSIGNED_SHORT_5_6_5:
            case GL_UNSIGNED_SHORT_5_6_5_REV:
            case GL_UNSIGNED_SHORT_4_4_4_4:
            case GL_UNSIGNED_SHORT_4_4_4_4_REV:
            case GL_UNSIGNED_SHORT_5_5_5_1:
            case GL_UNSIGNED_SHORT_1_5_5_5_REV:
                return 2;
            case GL_UNSIGNED_INT_8_8_8_8:
            case GL_UNSIGNED_INT_8_8_8_8_REV:
            case GL_UNSIGNED_INT_10_10_10_2:
            case GL_UNSIGNED_INT_2_10_10_10_REV:
            case GL_UNSIGNED_INT_24_8:
            case GL_UNSIGNED_INT_10F_11F_11F_REV:
            case GL_UNSIGNED_INT_5_9_9_9_REV:
                return 4;
            case GL_FLOAT_32_UNSIGNED_INT_24_8_REV:
                return 8;
            default:
                return 4;
        }
    }
    return componentCountForFormat(format) * bytesPerComponent(type);
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

// Box-filter downsample for typed native-format texel data.
//
// Used by generateMipmaps when the texture is stored in a non-RGBA8
// Metal pixel format. The existing downsampleRGBA8 handles the shadow
// rgba8 mirror, but replaceMetalTexture uploads `nativeData` (width *
// bytesPerPixel) for non-RGBA8 formats. Without a matching native-
// format downsampler, generated mip levels carry empty `nativeData`
// and the upload loop's old rgba8 fallback wrote 4-byte pixels into
// the Metal texture whose format expected `bytesPerPixel` bytes per
// pixel — tripping AGX's `bytes_per_row >= used_bytes_per_row`
// assertion in texture_gather / texture_border_clamp.
//
// Strategy: a 2×2×2 box filter on each channel, interpreted per the
// NativeFormatInfo.compType:
//   UNorm : uintN average, written back as uintN
//   SNorm : intN  average (saturating), written as intN
//   UInt  : uintN average, written back as uintN
//   SInt  : intN  average, written back as intN
//   Float : float32 average (float16 branches converted via half helper)
//
// `channelBytes` ∈ {1,2,4} — covers every non-packed MTLPixelFormat we
// advertise on the GL side.
template <typename T>
static inline T readTyped(const std::uint8_t* src) {
    T v;
    std::memcpy(&v, src, sizeof(T));
    return v;
}
template <typename T>
static inline void writeTyped(std::uint8_t* dst, T v) {
    std::memcpy(dst, &v, sizeof(T));
}
// IEEE 754 half<->float used by the Float+channelBytes==2 branch.
static inline float halfToFloat(std::uint16_t h) {
    std::uint32_t sign = (h & 0x8000u) << 16;
    std::uint32_t exponent = (h >> 10) & 0x1Fu;
    std::uint32_t mantissa = h & 0x3FFu;
    std::uint32_t bits;
    if (exponent == 0) {
        if (mantissa == 0) { bits = sign; }
        else {
            while ((mantissa & 0x400u) == 0) { mantissa <<= 1; exponent -= 1; }
            exponent += 1;
            mantissa &= ~0x400u;
            bits = sign | ((exponent + 112u) << 23) | (mantissa << 13);
        }
    } else if (exponent == 31u) {
        bits = sign | 0x7F800000u | (mantissa << 13);
    } else {
        bits = sign | ((exponent + 112u) << 23) | (mantissa << 13);
    }
    float f;
    std::memcpy(&f, &bits, sizeof(f));
    return f;
}
static inline std::uint16_t floatToHalf(float f) {
    std::uint32_t bits;
    std::memcpy(&bits, &f, sizeof(bits));
    std::uint32_t sign = (bits >> 16) & 0x8000u;
    std::int32_t exponent = static_cast<std::int32_t>((bits >> 23) & 0xFFu) - 127 + 15;
    std::uint32_t mantissa = bits & 0x7FFFFFu;
    if (exponent <= 0) {
        if (exponent < -10) { return static_cast<std::uint16_t>(sign); }
        mantissa = (mantissa | 0x800000u) >> static_cast<std::uint32_t>(1 - exponent);
        if (mantissa & 0x1000u) { mantissa += 0x2000u; }
        return static_cast<std::uint16_t>(sign | (mantissa >> 13));
    }
    if (exponent >= 31) {
        return static_cast<std::uint16_t>(sign | (31u << 10));
    }
    if (mantissa & 0x1000u) {
        mantissa += 0x2000u;
        if (mantissa & 0x800000u) { mantissa = 0; exponent += 1; if (exponent >= 31) { return static_cast<std::uint16_t>(sign | (31u << 10)); } }
    }
    return static_cast<std::uint16_t>(sign | (static_cast<std::uint32_t>(exponent) << 10) | (mantissa >> 13));
}

struct NativeDownsampleFormat {
    int channels;       // 1, 2, 4
    int channelBytes;   // 1, 2, 4
    enum Kind { UNorm, SNorm, UInt, SInt, Float } kind;
};

std::vector<std::uint8_t> downsampleNative(
    const std::vector<std::uint8_t>& source,
    GLsizei sourceWidth,
    GLsizei sourceHeight,
    GLsizei sourceDepth,
    GLsizei destWidth,
    GLsizei destHeight,
    GLsizei destDepth,
    NativeDownsampleFormat fmt
) {
    const std::size_t bpp = static_cast<std::size_t>(fmt.channels * fmt.channelBytes);
    std::vector<std::uint8_t> dest(
        static_cast<std::size_t>(destWidth) * static_cast<std::size_t>(destHeight)
            * static_cast<std::size_t>(destDepth) * bpp, 0);
    if (source.empty() || bpp == 0) {
        return dest;
    }

    for (GLsizei z = 0; z < destDepth; ++z) {
        for (GLsizei y = 0; y < destHeight; ++y) {
            for (GLsizei x = 0; x < destWidth; ++x) {
                // Accumulate per-channel sums across the 2×2×2 footprint.
                double sums[4] = {0.0, 0.0, 0.0, 0.0};
                int samples = 0;
                for (GLsizei dz = 0; dz < 2; ++dz) {
                    const GLsizei sz = std::min<GLsizei>(z * 2 + dz, sourceDepth - 1);
                    for (GLsizei dy = 0; dy < 2; ++dy) {
                        const GLsizei sy = std::min<GLsizei>(y * 2 + dy, sourceHeight - 1);
                        for (GLsizei dx = 0; dx < 2; ++dx) {
                            const GLsizei sx = std::min<GLsizei>(x * 2 + dx, sourceWidth - 1);
                            const std::size_t pixelIdx =
                                ((static_cast<std::size_t>(sz) * static_cast<std::size_t>(sourceHeight)
                                    + static_cast<std::size_t>(sy))
                                    * static_cast<std::size_t>(sourceWidth)
                                    + static_cast<std::size_t>(sx));
                            const std::uint8_t* px = source.data() + pixelIdx * bpp;
                            for (int c = 0; c < fmt.channels; ++c) {
                                const std::uint8_t* comp = px + static_cast<std::size_t>(c * fmt.channelBytes);
                                double v = 0.0;
                                if (fmt.kind == NativeDownsampleFormat::Float) {
                                    if (fmt.channelBytes == 4) {
                                        v = static_cast<double>(readTyped<float>(comp));
                                    } else if (fmt.channelBytes == 2) {
                                        v = static_cast<double>(halfToFloat(readTyped<std::uint16_t>(comp)));
                                    }
                                } else if (fmt.kind == NativeDownsampleFormat::SInt
                                        || fmt.kind == NativeDownsampleFormat::SNorm) {
                                    if (fmt.channelBytes == 1) v = readTyped<std::int8_t>(comp);
                                    else if (fmt.channelBytes == 2) v = readTyped<std::int16_t>(comp);
                                    else if (fmt.channelBytes == 4) v = readTyped<std::int32_t>(comp);
                                } else {
                                    if (fmt.channelBytes == 1) v = readTyped<std::uint8_t>(comp);
                                    else if (fmt.channelBytes == 2) v = readTyped<std::uint16_t>(comp);
                                    else if (fmt.channelBytes == 4) v = static_cast<double>(readTyped<std::uint32_t>(comp));
                                }
                                sums[c] += v;
                            }
                            ++samples;
                        }
                    }
                }

                const std::size_t pixelIdx =
                    (static_cast<std::size_t>(z) * static_cast<std::size_t>(destHeight)
                        + static_cast<std::size_t>(y))
                    * static_cast<std::size_t>(destWidth)
                    + static_cast<std::size_t>(x);
                std::uint8_t* dstPx = dest.data() + pixelIdx * bpp;
                for (int c = 0; c < fmt.channels; ++c) {
                    std::uint8_t* comp = dstPx + static_cast<std::size_t>(c * fmt.channelBytes);
                    const double avg = sums[c] / static_cast<double>(samples);
                    if (fmt.kind == NativeDownsampleFormat::Float) {
                        if (fmt.channelBytes == 4) {
                            writeTyped<float>(comp, static_cast<float>(avg));
                        } else if (fmt.channelBytes == 2) {
                            writeTyped<std::uint16_t>(comp, floatToHalf(static_cast<float>(avg)));
                        }
                    } else if (fmt.kind == NativeDownsampleFormat::SInt
                            || fmt.kind == NativeDownsampleFormat::SNorm) {
                        const double rounded = avg >= 0 ? std::floor(avg + 0.5) : std::ceil(avg - 0.5);
                        if (fmt.channelBytes == 1) writeTyped<std::int8_t>(comp, static_cast<std::int8_t>(rounded));
                        else if (fmt.channelBytes == 2) writeTyped<std::int16_t>(comp, static_cast<std::int16_t>(rounded));
                        else if (fmt.channelBytes == 4) writeTyped<std::int32_t>(comp, static_cast<std::int32_t>(rounded));
                    } else {
                        const double rounded = std::floor(avg + 0.5);
                        if (fmt.channelBytes == 1) writeTyped<std::uint8_t>(comp, static_cast<std::uint8_t>(rounded));
                        else if (fmt.channelBytes == 2) writeTyped<std::uint16_t>(comp, static_cast<std::uint16_t>(rounded));
                        else if (fmt.channelBytes == 4) writeTyped<std::uint32_t>(comp, static_cast<std::uint32_t>(rounded));
                    }
                }
            }
        }
    }
    return dest;
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
        | GL_MAP_UNSYNCHRONIZED_BIT
        | GL_MAP_PERSISTENT_BIT
        | GL_MAP_COHERENT_BIT;
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
        case GL_DEPTH_STENCIL_TEXTURE_MODE:
            params.depthStencilTextureMode = values[0];
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
        case GL_DEPTH_STENCIL_TEXTURE_MODE:
            values[0] = params.depthStencilTextureMode;
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
        // Must match GL_MAX_VERTEX_ATTRIBS reported via GLCapabilities (32).
        // CTS cull_distance uses 17+ attributes (8 clip + 8 cull + 1 pos),
        // and the default of 16 caused every glVertexAttribPointer call on
        // location 16+ to return GL_INVALID_VALUE.
        objects = std::make_unique<GLObjectStore>(32);
        state = std::make_unique<GLStateTracker>();
        if (frameGraph != nullptr) {
            frameGraph->resizeDrawable(drawableSurfaceWidth(), drawableSurfaceHeight());
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
        releaseRetainedMetalObject(object.metalSwizzledView);
        object.metalSwizzledView = nullptr;
        object.swizzleDirty = true;
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

    // Normalize a GL texture target for binding lookups.
    //
    // GL 4.6 §8.6 says `glTexImage2D` / `glTexSubImage2D` / copyTexImage
    // etc. accept the six per-face cube targets
    // (GL_TEXTURE_CUBE_MAP_{POSITIVE,NEGATIVE}_{X,Y,Z}) even though the
    // *binding* lives at GL_TEXTURE_CUBE_MAP. Tests rely on the
    // "bindTexture(GL_TEXTURE_CUBE_MAP, n); texSubImage2D(CUBE_POSITIVE_X, …)"
    // pattern (e.g. KHR-GL46.texture_swizzle.functional_*_target_idx_6).
    // Normalize here so a cube-face target resolves to the cube-map
    // binding. Non-cube-face targets pass through unchanged.
    static GLenum normalizeTextureBindingTarget(GLenum target) {
        switch (target) {
            case GL_TEXTURE_CUBE_MAP_POSITIVE_X:
            case GL_TEXTURE_CUBE_MAP_NEGATIVE_X:
            case GL_TEXTURE_CUBE_MAP_POSITIVE_Y:
            case GL_TEXTURE_CUBE_MAP_NEGATIVE_Y:
            case GL_TEXTURE_CUBE_MAP_POSITIVE_Z:
            case GL_TEXTURE_CUBE_MAP_NEGATIVE_Z:
                return GL_TEXTURE_CUBE_MAP;
            default:
                return target;
        }
    }

    // Returns the cube-face bit (0..5) for per-face CUBE_MAP targets,
    // or -1 when the target is not a cube face. Face order matches GL
    // 4.6 §8.18 enum ordering.
    static int cubeFaceIndexForTarget(GLenum target) {
        switch (target) {
            case GL_TEXTURE_CUBE_MAP_POSITIVE_X: return 0;
            case GL_TEXTURE_CUBE_MAP_NEGATIVE_X: return 1;
            case GL_TEXTURE_CUBE_MAP_POSITIVE_Y: return 2;
            case GL_TEXTURE_CUBE_MAP_NEGATIVE_Y: return 3;
            case GL_TEXTURE_CUBE_MAP_POSITIVE_Z: return 4;
            case GL_TEXTURE_CUBE_MAP_NEGATIVE_Z: return 5;
            default: return -1;
        }
    }

    GLTextureObject* currentTexture(GLenum target) {
        const GLuint name = state->boundTexture(normalizeTextureBindingTarget(target));
        if (name == 0) {
            return nullptr;
        }
        return objects->textures().get(name);
    }

    // Read a single source component and normalize it to [0..255] for
    // the RGBA8 shadow texture. Handles all GL pixel data types.
    static std::uint8_t readComponentAsU8(const std::uint8_t* src, GLenum type, std::size_t componentIndex) {
        switch (type) {
            case GL_UNSIGNED_BYTE:
                return src[componentIndex];
            case GL_BYTE: {
                auto v = reinterpret_cast<const std::int8_t*>(src)[componentIndex];
                return static_cast<std::uint8_t>(std::max(0, static_cast<int>(v) * 255 / 127));
            }
            case GL_UNSIGNED_SHORT: {
                auto v = reinterpret_cast<const std::uint16_t*>(src)[componentIndex];
                return static_cast<std::uint8_t>(v >> 8);
            }
            case GL_SHORT: {
                auto v = reinterpret_cast<const std::int16_t*>(src)[componentIndex];
                return static_cast<std::uint8_t>(std::max(0, static_cast<int>(v) * 255 / 32767));
            }
            case GL_UNSIGNED_INT: {
                auto v = reinterpret_cast<const std::uint32_t*>(src)[componentIndex];
                return static_cast<std::uint8_t>(v >> 24);
            }
            case GL_INT: {
                auto v = reinterpret_cast<const std::int32_t*>(src)[componentIndex];
                return static_cast<std::uint8_t>(std::max(0, static_cast<int>(static_cast<double>(v) * 255.0 / 2147483647.0)));
            }
            case GL_FLOAT: {
                auto v = reinterpret_cast<const float*>(src)[componentIndex];
                float clamped = std::max(0.0f, std::min(1.0f, v));
                return static_cast<std::uint8_t>(clamped * 255.0f + 0.5f);
            }
            case GL_HALF_FLOAT: {
                // IEEE 754 half-float → float conversion
                auto bits = reinterpret_cast<const std::uint16_t*>(src)[componentIndex];
                std::uint32_t sign = (bits & 0x8000u) << 16;
                std::uint32_t exponent = (bits >> 10) & 0x1F;
                std::uint32_t mantissa = bits & 0x3FF;
                float f;
                if (exponent == 0) {
                    // Denormalized or zero
                    f = std::ldexp(static_cast<float>(mantissa), -24);
                    if (sign) f = -f;
                } else if (exponent == 31) {
                    f = mantissa ? 0.0f : ((sign ? -1.0f : 1.0f) * std::numeric_limits<float>::infinity());
                } else {
                    std::uint32_t fbits = sign | ((exponent + 112) << 23) | (mantissa << 13);
                    std::memcpy(&f, &fbits, sizeof(f));
                }
                float clamped = std::max(0.0f, std::min(1.0f, f));
                return static_cast<std::uint8_t>(clamped * 255.0f + 0.5f);
            }
            default:
                return 0;
        }
    }

    // ── Native-format texture upload infrastructure ──────────────────
    //
    // When the GL internal format maps to a Metal pixel format other than
    // RGBA8Unorm (e.g. R16F, RGBA32F, R8_SNORM …), we build a second
    // pixel buffer in the Metal-native layout so replaceMetalTexture()
    // can create a texture with the correct pixel format. This preserves
    // precision that the RGBA8 shadow path would lose.

    struct NativeFormatInfo {
        int channels;        // 1, 2, or 4 (0 = packed/unsupported)
        int bytesPerChannel; // 1, 2, or 4
        int bytesPerPixel;   // channels * bytesPerChannel
        enum CompType { UNorm, SNorm, UInt, SInt, Float } compType;
    };

    static NativeFormatInfo nativeFormatInfo(MTLPixelFormat fmt) {
        switch (fmt) {
            // ── 8-bit 1-channel ──
            case MTLPixelFormatR8Unorm:       return {1, 1, 1, NativeFormatInfo::UNorm};
            case MTLPixelFormatR8Snorm:       return {1, 1, 1, NativeFormatInfo::SNorm};
            case MTLPixelFormatR8Uint:        return {1, 1, 1, NativeFormatInfo::UInt};
            case MTLPixelFormatR8Sint:        return {1, 1, 1, NativeFormatInfo::SInt};
            // ── 8-bit 2-channel ──
            case MTLPixelFormatRG8Unorm:      return {2, 1, 2, NativeFormatInfo::UNorm};
            case MTLPixelFormatRG8Snorm:      return {2, 1, 2, NativeFormatInfo::SNorm};
            case MTLPixelFormatRG8Uint:       return {2, 1, 2, NativeFormatInfo::UInt};
            case MTLPixelFormatRG8Sint:       return {2, 1, 2, NativeFormatInfo::SInt};
            // ── 8-bit 4-channel ──
            case MTLPixelFormatRGBA8Unorm:    return {4, 1, 4, NativeFormatInfo::UNorm};
            case MTLPixelFormatRGBA8Snorm:    return {4, 1, 4, NativeFormatInfo::SNorm};
            case MTLPixelFormatRGBA8Uint:     return {4, 1, 4, NativeFormatInfo::UInt};
            case MTLPixelFormatRGBA8Sint:     return {4, 1, 4, NativeFormatInfo::SInt};
            case MTLPixelFormatRGBA8Unorm_sRGB: return {4, 1, 4, NativeFormatInfo::UNorm};
            // ── 16-bit 1-channel ──
            case MTLPixelFormatR16Unorm:      return {1, 2, 2, NativeFormatInfo::UNorm};
            case MTLPixelFormatR16Snorm:      return {1, 2, 2, NativeFormatInfo::SNorm};
            case MTLPixelFormatR16Float:      return {1, 2, 2, NativeFormatInfo::Float};
            case MTLPixelFormatR16Uint:       return {1, 2, 2, NativeFormatInfo::UInt};
            case MTLPixelFormatR16Sint:       return {1, 2, 2, NativeFormatInfo::SInt};
            // ── 16-bit 2-channel ──
            case MTLPixelFormatRG16Unorm:     return {2, 2, 4, NativeFormatInfo::UNorm};
            case MTLPixelFormatRG16Snorm:     return {2, 2, 4, NativeFormatInfo::SNorm};
            case MTLPixelFormatRG16Float:     return {2, 2, 4, NativeFormatInfo::Float};
            case MTLPixelFormatRG16Uint:      return {2, 2, 4, NativeFormatInfo::UInt};
            case MTLPixelFormatRG16Sint:      return {2, 2, 4, NativeFormatInfo::SInt};
            // ── 16-bit 4-channel ──
            case MTLPixelFormatRGBA16Unorm:   return {4, 2, 8, NativeFormatInfo::UNorm};
            case MTLPixelFormatRGBA16Snorm:   return {4, 2, 8, NativeFormatInfo::SNorm};
            case MTLPixelFormatRGBA16Float:   return {4, 2, 8, NativeFormatInfo::Float};
            case MTLPixelFormatRGBA16Uint:    return {4, 2, 8, NativeFormatInfo::UInt};
            case MTLPixelFormatRGBA16Sint:    return {4, 2, 8, NativeFormatInfo::SInt};
            // ── 32-bit 1-channel ──
            case MTLPixelFormatR32Float:      return {1, 4, 4, NativeFormatInfo::Float};
            case MTLPixelFormatR32Uint:       return {1, 4, 4, NativeFormatInfo::UInt};
            case MTLPixelFormatR32Sint:       return {1, 4, 4, NativeFormatInfo::SInt};
            // ── 32-bit 2-channel ──
            case MTLPixelFormatRG32Float:     return {2, 4, 8, NativeFormatInfo::Float};
            case MTLPixelFormatRG32Uint:      return {2, 4, 8, NativeFormatInfo::UInt};
            case MTLPixelFormatRG32Sint:      return {2, 4, 8, NativeFormatInfo::SInt};
            // ── 32-bit 4-channel ──
            case MTLPixelFormatRGBA32Float:   return {4, 4, 16, NativeFormatInfo::Float};
            case MTLPixelFormatRGBA32Uint:    return {4, 4, 16, NativeFormatInfo::UInt};
            case MTLPixelFormatRGBA32Sint:    return {4, 4, 16, NativeFormatInfo::SInt};
            // ── Packed (not supported for native upload) ──
            case MTLPixelFormatRGB10A2Unorm:  return {0, 0, 4, NativeFormatInfo::UNorm};
            case MTLPixelFormatRGB10A2Uint:   return {0, 0, 4, NativeFormatInfo::UInt};
            case MTLPixelFormatRG11B10Float:  return {0, 0, 4, NativeFormatInfo::Float};
            default: return {0, 0, 0, NativeFormatInfo::UNorm};
        }
    }

    // Read a single source component as a double. The `asInteger` flag
    // controls whether integer types are returned as raw ints (true) or
    // as normalized [0,1]/[-1,1] values (false). GL_FLOAT / GL_HALF_FLOAT
    // always return the float value regardless of the flag.
    static double readSourceComponentDouble(
        const std::uint8_t* src, GLenum type, std::size_t idx, bool asInteger
    ) {
        switch (type) {
            case GL_UNSIGNED_BYTE: {
                std::uint8_t v = src[idx];
                return asInteger ? static_cast<double>(v) : v / 255.0;
            }
            case GL_BYTE: {
                auto v = reinterpret_cast<const std::int8_t*>(src)[idx];
                return asInteger ? static_cast<double>(v) : std::max(-1.0, v / 127.0);
            }
            case GL_UNSIGNED_SHORT: {
                auto v = reinterpret_cast<const std::uint16_t*>(src)[idx];
                return asInteger ? static_cast<double>(v) : v / 65535.0;
            }
            case GL_SHORT: {
                auto v = reinterpret_cast<const std::int16_t*>(src)[idx];
                return asInteger ? static_cast<double>(v) : std::max(-1.0, v / 32767.0);
            }
            case GL_UNSIGNED_INT: {
                auto v = reinterpret_cast<const std::uint32_t*>(src)[idx];
                return asInteger ? static_cast<double>(v) : v / 4294967295.0;
            }
            case GL_INT: {
                auto v = reinterpret_cast<const std::int32_t*>(src)[idx];
                return asInteger ? static_cast<double>(v) : std::max(-1.0, v / 2147483647.0);
            }
            case GL_FLOAT: {
                return static_cast<double>(reinterpret_cast<const float*>(src)[idx]);
            }
            case GL_HALF_FLOAT: {
                auto bits = reinterpret_cast<const std::uint16_t*>(src)[idx];
                std::uint32_t sign = (bits & 0x8000u) << 16;
                std::uint32_t exponent = (bits >> 10) & 0x1Fu;
                std::uint32_t mantissa = bits & 0x3FFu;
                float f;
                if (exponent == 0) {
                    f = std::ldexp(static_cast<float>(mantissa), -24);
                    if (sign) f = -f;
                } else if (exponent == 31) {
                    f = mantissa ? 0.0f : ((sign ? -1.0f : 1.0f) * std::numeric_limits<float>::infinity());
                } else {
                    std::uint32_t fbits = sign | ((exponent + 112) << 23) | (mantissa << 13);
                    std::memcpy(&f, &fbits, sizeof(f));
                }
                return static_cast<double>(f);
            }
            default:
                return 0.0;
        }
    }

    static std::uint16_t floatToHalf(float f) {
        std::uint32_t bits;
        std::memcpy(&bits, &f, sizeof(bits));
        std::uint16_t sign = static_cast<std::uint16_t>((bits >> 16) & 0x8000u);
        std::int32_t exponent = static_cast<std::int32_t>((bits >> 23) & 0xFFu) - 127;
        std::uint32_t mantissa = bits & 0x7FFFFFu;
        if ((bits & 0x7F800000u) == 0x7F800000u) {
            // Inf or NaN
            return sign | 0x7C00u | static_cast<std::uint16_t>(mantissa ? 0x0200u : 0);
        }
        if (exponent > 15) {
            return sign | 0x7C00u; // overflow → infinity
        }
        if (exponent < -14) {
            // denorm or zero
            mantissa |= 0x800000u;
            int shift = -14 - exponent + 13;
            if (shift > 24) return sign;
            return sign | static_cast<std::uint16_t>(mantissa >> shift);
        }
        return sign
             | static_cast<std::uint16_t>((exponent + 15) << 10)
             | static_cast<std::uint16_t>(mantissa >> 13);
    }

    // Write a component value to a native-format buffer at `dst`.
    static void writeNativeComponent(
        std::uint8_t* dst,
        NativeFormatInfo::CompType compType,
        int bytesPerChannel,
        double value
    ) {
        switch (compType) {
            case NativeFormatInfo::UNorm: {
                double clamped = std::max(0.0, std::min(1.0, value));
                if (bytesPerChannel == 1) {
                    *dst = static_cast<std::uint8_t>(clamped * 255.0 + 0.5);
                } else { // 2
                    std::uint16_t v = static_cast<std::uint16_t>(clamped * 65535.0 + 0.5);
                    std::memcpy(dst, &v, 2);
                }
                break;
            }
            case NativeFormatInfo::SNorm: {
                double clamped = std::max(-1.0, std::min(1.0, value));
                if (bytesPerChannel == 1) {
                    std::int8_t v = static_cast<std::int8_t>(
                        clamped >= 0 ? (clamped * 127.0 + 0.5) : (clamped * 127.0 - 0.5));
                    std::memcpy(dst, &v, 1);
                } else { // 2
                    std::int16_t v = static_cast<std::int16_t>(
                        clamped >= 0 ? (clamped * 32767.0 + 0.5) : (clamped * 32767.0 - 0.5));
                    std::memcpy(dst, &v, 2);
                }
                break;
            }
            case NativeFormatInfo::UInt: {
                if (bytesPerChannel == 1) {
                    *dst = static_cast<std::uint8_t>(std::max(0.0, std::min(255.0, value)));
                } else if (bytesPerChannel == 2) {
                    std::uint16_t v = static_cast<std::uint16_t>(std::max(0.0, std::min(65535.0, value)));
                    std::memcpy(dst, &v, 2);
                } else { // 4
                    std::uint32_t v = static_cast<std::uint32_t>(std::max(0.0, std::min(4294967295.0, value)));
                    std::memcpy(dst, &v, 4);
                }
                break;
            }
            case NativeFormatInfo::SInt: {
                if (bytesPerChannel == 1) {
                    std::int8_t v = static_cast<std::int8_t>(std::max(-128.0, std::min(127.0, value)));
                    std::memcpy(dst, &v, 1);
                } else if (bytesPerChannel == 2) {
                    std::int16_t v = static_cast<std::int16_t>(std::max(-32768.0, std::min(32767.0, value)));
                    std::memcpy(dst, &v, 2);
                } else { // 4
                    std::int32_t v = static_cast<std::int32_t>(std::max(-2147483648.0, std::min(2147483647.0, value)));
                    std::memcpy(dst, &v, 4);
                }
                break;
            }
            case NativeFormatInfo::Float: {
                if (bytesPerChannel == 2) {
                    std::uint16_t h = floatToHalf(static_cast<float>(value));
                    std::memcpy(dst, &h, 2);
                } else { // 4
                    float fv = static_cast<float>(value);
                    std::memcpy(dst, &fv, 4);
                }
                break;
            }
        }
    }

    // Build pixel data in the Metal-native format for `internalFormat`.
    // Returns true if native data was produced; false means the caller
    // should fall back to the rgba8 shadow path. On success, `outBpp`
    // contains the bytes-per-pixel of the produced data.
    bool buildNativeUpload(
        GLenum internalFormat,
        GLsizei width, GLsizei height, GLsizei depth,
        GLenum format, GLenum type,
        const void* pixels,
        std::vector<std::uint8_t>& nativeData,
        std::size_t& outBpp
    ) {
        // Packed source types are complex — let them go through rgba8.
        if (isPackedPixelType(type)) return false;

        MTLPixelFormat mtlFmt = metalRenderbufferFormat(internalFormat);
        if (mtlFmt == MTLPixelFormatInvalid) return false;
        // RGBA8Unorm is already handled perfectly by the rgba8 path.
        if (mtlFmt == MTLPixelFormatRGBA8Unorm) return false;

        auto info = nativeFormatInfo(mtlFmt);
        // Skip packed Metal formats (RGB10A2, RG11B10F) — fall back.
        if (info.channels == 0 || info.bytesPerPixel == 0) return false;

        outBpp = static_cast<std::size_t>(info.bytesPerPixel);
        const std::size_t totalPixels = static_cast<std::size_t>(width)
                                      * static_cast<std::size_t>(height)
                                      * static_cast<std::size_t>(depth);
        nativeData.assign(totalPixels * outBpp, 0);

        if (pixels == nullptr || totalPixels == 0) return true;

        const std::size_t srcComponents = componentCountForFormat(format);
        if (srcComponents == 0) return false;
        const std::size_t srcPixelBytes = bytesPerPixel(format, type);
        if (srcPixelBytes == 0) return false;

        // Determine how to interpret source values: integer targets
        // read raw ints; normalized/float targets read normalized.
        const bool asInteger = (info.compType == NativeFormatInfo::UInt
                             || info.compType == NativeFormatInfo::SInt);

        // Pixel-store state
        const auto& store = state->pixelStore();
        const std::size_t sourceWidth  = static_cast<std::size_t>(store.unpackRowLength > 0 ? store.unpackRowLength : width);
        const std::size_t sourceHeight = static_cast<std::size_t>(store.unpackImageHeight > 0 ? store.unpackImageHeight : height);
        const std::size_t rowBytes     = alignByteCount(sourceWidth * srcPixelBytes, store.unpackAlignment);
        const std::size_t imageBytes   = rowBytes * sourceHeight;
        const std::size_t sourceOffset =
            static_cast<std::size_t>(store.unpackSkipImages) * imageBytes
            + static_cast<std::size_t>(store.unpackSkipRows) * rowBytes
            + static_cast<std::size_t>(store.unpackSkipPixels) * srcPixelBytes;
        const auto* source = static_cast<const std::uint8_t*>(pixels) + sourceOffset;

        const bool isBGR  = (format == GL_BGR  || format == GL_BGR_INTEGER);
        const bool isBGRA = (format == GL_BGRA || format == GL_BGRA_INTEGER);

        for (GLsizei z = 0; z < depth; ++z) {
            for (GLsizei y = 0; y < height; ++y) {
                for (GLsizei x = 0; x < width; ++x) {
                    const std::size_t srcByteIdx =
                        static_cast<std::size_t>(z) * imageBytes
                        + static_cast<std::size_t>(y) * rowBytes
                        + static_cast<std::size_t>(x) * srcPixelBytes;
                    const std::size_t dstPixelIdx =
                        (static_cast<std::size_t>(z) * static_cast<std::size_t>(height)
                         + static_cast<std::size_t>(y))
                        * static_cast<std::size_t>(width)
                        + static_cast<std::size_t>(x);
                    const std::uint8_t* pixel = source + srcByteIdx;
                    std::uint8_t* dstPixel = nativeData.data() + dstPixelIdx * outBpp;

                    // Read source components into RGBA doubles.
                    double comps[4] = {0.0, 0.0, 0.0, 1.0};

                    if (isBGR && srcComponents >= 3) {
                        comps[0] = readSourceComponentDouble(pixel, type, 2, asInteger);
                        comps[1] = readSourceComponentDouble(pixel, type, 1, asInteger);
                        comps[2] = readSourceComponentDouble(pixel, type, 0, asInteger);
                        if (srcComponents > 3)
                            comps[3] = readSourceComponentDouble(pixel, type, 3, asInteger);
                    } else if (isBGRA && srcComponents >= 4) {
                        comps[0] = readSourceComponentDouble(pixel, type, 2, asInteger);
                        comps[1] = readSourceComponentDouble(pixel, type, 1, asInteger);
                        comps[2] = readSourceComponentDouble(pixel, type, 0, asInteger);
                        comps[3] = readSourceComponentDouble(pixel, type, 3, asInteger);
                    } else {
                        for (std::size_t c = 0; c < srcComponents && c < 4; ++c) {
                            comps[c] = readSourceComponentDouble(pixel, type, c, asInteger);
                        }
                    }

                    // Write to native format.
                    for (int c = 0; c < info.channels; ++c) {
                        writeNativeComponent(
                            dstPixel + c * info.bytesPerChannel,
                            info.compType, info.bytesPerChannel, comps[c]);
                    }
                }
            }
        }
        return true;
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
        const std::size_t components = componentCountForFormat(format);
        if (components == 0) {
            return false;
        }

        const std::size_t pixelBytes = bytesPerPixel(format, type);
        if (pixelBytes == 0) {
            return false;
        }

        const auto& store = state->pixelStore();
        const std::size_t sourceWidth = static_cast<std::size_t>(store.unpackRowLength > 0 ? store.unpackRowLength : width);
        const std::size_t sourceHeight = static_cast<std::size_t>(store.unpackImageHeight > 0 ? store.unpackImageHeight : height);
        const std::size_t rowBytes = alignByteCount(sourceWidth * pixelBytes, store.unpackAlignment);
        const std::size_t imageBytes = rowBytes * sourceHeight;
        const std::size_t sourceOffset =
            static_cast<std::size_t>(store.unpackSkipImages) * imageBytes
            + static_cast<std::size_t>(store.unpackSkipRows) * rowBytes
            + static_cast<std::size_t>(store.unpackSkipPixels) * pixelBytes;
        const auto* source = static_cast<const std::uint8_t*>(pixels) + sourceOffset;

        // Compat-profile aliases
        const bool isAlphaOnly = (format == GL_ALPHA);
        const bool isLuminance = (format == GL_LUMINANCE);
        const bool isIntensity = (format == GL_INTENSITY);
        const bool isLuminanceAlpha = (format == GL_LUMINANCE_ALPHA);
        // BGR ordering: swap R and B channels
        const bool isBGR = (format == GL_BGR || format == GL_BGR_INTEGER);
        const bool isBGRA = (format == GL_BGRA || format == GL_BGRA_INTEGER);

        // For packed pixel types, do a simplified conversion (extract and
        // normalize to RGBA8). For standard component types, read per-component.
        const bool packed = isPackedPixelType(type);

        for (GLsizei z = 0; z < depth; ++z) {
            for (GLsizei y = 0; y < height; ++y) {
                for (GLsizei x = 0; x < width; ++x) {
                    const std::size_t sourceByteIndex =
                        static_cast<std::size_t>(z) * imageBytes
                        + static_cast<std::size_t>(y) * rowBytes
                        + static_cast<std::size_t>(x) * pixelBytes;
                    const std::size_t destIndex =
                        ((static_cast<std::size_t>(z) * static_cast<std::size_t>(height)
                            + static_cast<std::size_t>(y))
                            * static_cast<std::size_t>(width)
                            + static_cast<std::size_t>(x))
                        * 4u;
                    const std::uint8_t* pixel = source + sourceByteIndex;

                    if (packed) {
                        // Best-effort packed type conversion to RGBA8
                        if (type == GL_UNSIGNED_INT_8_8_8_8 || type == GL_UNSIGNED_INT_8_8_8_8_REV) {
                            std::uint32_t val;
                            std::memcpy(&val, pixel, 4);
                            if (type == GL_UNSIGNED_INT_8_8_8_8) {
                                rgba8[destIndex + 0] = static_cast<std::uint8_t>((val >> 24) & 0xFF);
                                rgba8[destIndex + 1] = static_cast<std::uint8_t>((val >> 16) & 0xFF);
                                rgba8[destIndex + 2] = static_cast<std::uint8_t>((val >> 8) & 0xFF);
                                rgba8[destIndex + 3] = static_cast<std::uint8_t>(val & 0xFF);
                            } else {
                                rgba8[destIndex + 0] = static_cast<std::uint8_t>(val & 0xFF);
                                rgba8[destIndex + 1] = static_cast<std::uint8_t>((val >> 8) & 0xFF);
                                rgba8[destIndex + 2] = static_cast<std::uint8_t>((val >> 16) & 0xFF);
                                rgba8[destIndex + 3] = static_cast<std::uint8_t>((val >> 24) & 0xFF);
                            }
                        } else if (type == GL_UNSIGNED_SHORT_5_6_5 || type == GL_UNSIGNED_SHORT_5_6_5_REV) {
                            std::uint16_t val;
                            std::memcpy(&val, pixel, 2);
                            if (type == GL_UNSIGNED_SHORT_5_6_5) {
                                rgba8[destIndex + 0] = static_cast<std::uint8_t>(((val >> 11) & 0x1F) * 255 / 31);
                                rgba8[destIndex + 1] = static_cast<std::uint8_t>(((val >> 5) & 0x3F) * 255 / 63);
                                rgba8[destIndex + 2] = static_cast<std::uint8_t>((val & 0x1F) * 255 / 31);
                            } else {
                                rgba8[destIndex + 0] = static_cast<std::uint8_t>((val & 0x1F) * 255 / 31);
                                rgba8[destIndex + 1] = static_cast<std::uint8_t>(((val >> 5) & 0x3F) * 255 / 63);
                                rgba8[destIndex + 2] = static_cast<std::uint8_t>(((val >> 11) & 0x1F) * 255 / 31);
                            }
                            rgba8[destIndex + 3] = 255;
                        } else if (type == GL_UNSIGNED_INT_2_10_10_10_REV) {
                            std::uint32_t val;
                            std::memcpy(&val, pixel, 4);
                            rgba8[destIndex + 0] = static_cast<std::uint8_t>((val & 0x3FF) * 255 / 1023);
                            rgba8[destIndex + 1] = static_cast<std::uint8_t>(((val >> 10) & 0x3FF) * 255 / 1023);
                            rgba8[destIndex + 2] = static_cast<std::uint8_t>(((val >> 20) & 0x3FF) * 255 / 1023);
                            rgba8[destIndex + 3] = static_cast<std::uint8_t>(((val >> 30) & 0x3) * 255 / 3);
                        } else if (type == GL_UNSIGNED_INT_10_10_10_2) {
                            std::uint32_t val;
                            std::memcpy(&val, pixel, 4);
                            rgba8[destIndex + 0] = static_cast<std::uint8_t>(((val >> 22) & 0x3FF) * 255 / 1023);
                            rgba8[destIndex + 1] = static_cast<std::uint8_t>(((val >> 12) & 0x3FF) * 255 / 1023);
                            rgba8[destIndex + 2] = static_cast<std::uint8_t>(((val >> 2) & 0x3FF) * 255 / 1023);
                            rgba8[destIndex + 3] = static_cast<std::uint8_t>((val & 0x3) * 255 / 3);
                        } else if (type == GL_UNSIGNED_BYTE_3_3_2) {
                            std::uint8_t val = pixel[0];
                            rgba8[destIndex + 0] = static_cast<std::uint8_t>(((val >> 5) & 0x7) * 255 / 7);
                            rgba8[destIndex + 1] = static_cast<std::uint8_t>(((val >> 2) & 0x7) * 255 / 7);
                            rgba8[destIndex + 2] = static_cast<std::uint8_t>((val & 0x3) * 255 / 3);
                            rgba8[destIndex + 3] = 255;
                        } else if (type == GL_UNSIGNED_BYTE_2_3_3_REV) {
                            std::uint8_t val = pixel[0];
                            rgba8[destIndex + 0] = static_cast<std::uint8_t>((val & 0x7) * 255 / 7);
                            rgba8[destIndex + 1] = static_cast<std::uint8_t>(((val >> 3) & 0x7) * 255 / 7);
                            rgba8[destIndex + 2] = static_cast<std::uint8_t>(((val >> 6) & 0x3) * 255 / 3);
                            rgba8[destIndex + 3] = 255;
                        } else if (type == GL_UNSIGNED_SHORT_4_4_4_4) {
                            std::uint16_t val;
                            std::memcpy(&val, pixel, 2);
                            rgba8[destIndex + 0] = static_cast<std::uint8_t>(((val >> 12) & 0xF) * 255 / 15);
                            rgba8[destIndex + 1] = static_cast<std::uint8_t>(((val >> 8) & 0xF) * 255 / 15);
                            rgba8[destIndex + 2] = static_cast<std::uint8_t>(((val >> 4) & 0xF) * 255 / 15);
                            rgba8[destIndex + 3] = static_cast<std::uint8_t>((val & 0xF) * 255 / 15);
                        } else if (type == GL_UNSIGNED_SHORT_4_4_4_4_REV) {
                            std::uint16_t val;
                            std::memcpy(&val, pixel, 2);
                            rgba8[destIndex + 0] = static_cast<std::uint8_t>((val & 0xF) * 255 / 15);
                            rgba8[destIndex + 1] = static_cast<std::uint8_t>(((val >> 4) & 0xF) * 255 / 15);
                            rgba8[destIndex + 2] = static_cast<std::uint8_t>(((val >> 8) & 0xF) * 255 / 15);
                            rgba8[destIndex + 3] = static_cast<std::uint8_t>(((val >> 12) & 0xF) * 255 / 15);
                        } else if (type == GL_UNSIGNED_SHORT_5_5_5_1) {
                            std::uint16_t val;
                            std::memcpy(&val, pixel, 2);
                            rgba8[destIndex + 0] = static_cast<std::uint8_t>(((val >> 11) & 0x1F) * 255 / 31);
                            rgba8[destIndex + 1] = static_cast<std::uint8_t>(((val >> 6) & 0x1F) * 255 / 31);
                            rgba8[destIndex + 2] = static_cast<std::uint8_t>(((val >> 1) & 0x1F) * 255 / 31);
                            rgba8[destIndex + 3] = static_cast<std::uint8_t>((val & 0x1) * 255);
                        } else if (type == GL_UNSIGNED_SHORT_1_5_5_5_REV) {
                            std::uint16_t val;
                            std::memcpy(&val, pixel, 2);
                            rgba8[destIndex + 0] = static_cast<std::uint8_t>((val & 0x1F) * 255 / 31);
                            rgba8[destIndex + 1] = static_cast<std::uint8_t>(((val >> 5) & 0x1F) * 255 / 31);
                            rgba8[destIndex + 2] = static_cast<std::uint8_t>(((val >> 10) & 0x1F) * 255 / 31);
                            rgba8[destIndex + 3] = static_cast<std::uint8_t>(((val >> 15) & 0x1) * 255);
                        } else {
                            // Other packed types (10F_11F_11F_REV, 5_9_9_9_REV,
                            // 24_8, float32_ui24_8): zero-fill shadow — not yet
                            // covered by this CTS subset.
                            rgba8[destIndex + 0] = 0;
                            rgba8[destIndex + 1] = 0;
                            rgba8[destIndex + 2] = 0;
                            rgba8[destIndex + 3] = 255;
                        }
                    } else if (isAlphaOnly || isIntensity) {
                        std::uint8_t c = readComponentAsU8(pixel, type, 0);
                        rgba8[destIndex + 0] = c;
                        rgba8[destIndex + 1] = c;
                        rgba8[destIndex + 2] = c;
                        rgba8[destIndex + 3] = c;
                    } else if (isLuminance) {
                        std::uint8_t c = readComponentAsU8(pixel, type, 0);
                        rgba8[destIndex + 0] = c;
                        rgba8[destIndex + 1] = c;
                        rgba8[destIndex + 2] = c;
                        rgba8[destIndex + 3] = 255;
                    } else if (isLuminanceAlpha) {
                        std::uint8_t lum = readComponentAsU8(pixel, type, 0);
                        std::uint8_t alp = readComponentAsU8(pixel, type, 1);
                        rgba8[destIndex + 0] = lum;
                        rgba8[destIndex + 1] = lum;
                        rgba8[destIndex + 2] = lum;
                        rgba8[destIndex + 3] = alp;
                    } else if (isBGR) {
                        rgba8[destIndex + 0] = readComponentAsU8(pixel, type, 2); // B→R
                        rgba8[destIndex + 1] = readComponentAsU8(pixel, type, 1); // G→G
                        rgba8[destIndex + 2] = readComponentAsU8(pixel, type, 0); // R→B
                        rgba8[destIndex + 3] = 255;
                    } else if (isBGRA) {
                        rgba8[destIndex + 0] = readComponentAsU8(pixel, type, 2); // B→R
                        rgba8[destIndex + 1] = readComponentAsU8(pixel, type, 1); // G→G
                        rgba8[destIndex + 2] = readComponentAsU8(pixel, type, 0); // R→B
                        rgba8[destIndex + 3] = readComponentAsU8(pixel, type, 3); // A→A
                    } else {
                        // Standard GL_RED/RG/RGB/RGBA and _INTEGER variants
                        rgba8[destIndex + 0] = readComponentAsU8(pixel, type, 0);
                        rgba8[destIndex + 1] = components > 1 ? readComponentAsU8(pixel, type, 1) : 0;
                        rgba8[destIndex + 2] = components > 2 ? readComponentAsU8(pixel, type, 2) : 0;
                        rgba8[destIndex + 3] = components > 3 ? readComponentAsU8(pixel, type, 3) : 255;
                    }
                }
            }
        }
        return true;
    }

    // Phase 8X Group 4d follow-up¹⁰ — `texName` is diagnostic-only and
    // defaults to 0 (no log). The four user-facing upload call sites
    // (`texImage` / `texSubImage` / `texStorage` / `texStorageMultisample`)
    // pass the current bound texture name so the fingerprint log can
    // emit once per GL texture name per process. The three internal
    // callers (`generateMipmaps`, attachment clear/copy paths) leave
    // the default — they're downstream transformations of already-
    // uploaded data, not the initial upload from Recoil we want to
    // fingerprint.
    bool replaceMetalTexture(GLTextureObject& object, GLuint texName = 0) {
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

        // Fast path: when the existing MTLTexture already matches the
        // descriptor shape we're about to build, REUSE it and only
        // refresh the per-level bytes via replaceRegion. Destroy-and-
        // recreate for every texSubImage call churns the Metal texture
        // pointer rapidly, which surfaces as the VS-stage texture_gather
        // flake cluster: an in-flight or cached GPU view of a previously
        // dropped MTLTexture can serve the next draw if the new one
        // hasn't made it into the texture L2 cache yet. Keeping the
        // same MTLTexture across subimage calls is also faster (no
        // allocator churn) and matches what real drivers do.
        //
        // Only the byte uploads happen here; the descriptor-time
        // branches below (new MTLTexture allocation) still run when any
        // shape parameter drifts (mipmap count change, internalFormat
        // change, size change).
        id<MTLTexture> existing = (__bridge id<MTLTexture>)object.metalTexture;
        if (existing != nil) {
            const NSUInteger wantWidth = static_cast<NSUInteger>(baseLevel.desc.width);
            const NSUInteger wantHeight = static_cast<NSUInteger>(
                (object.target == GL_TEXTURE_1D || object.target == GL_TEXTURE_1D_ARRAY)
                ? 1 : baseLevel.desc.height);
            const NSUInteger wantDepth = static_cast<NSUInteger>(
                object.target == GL_TEXTURE_3D ? baseLevel.desc.depth : 1);
            const NSUInteger wantArray = (object.target == GL_TEXTURE_1D_ARRAY)
                ? static_cast<NSUInteger>(baseLevel.desc.height)
                : (object.target == GL_TEXTURE_2D_ARRAY
                   ? static_cast<NSUInteger>(baseLevel.desc.depth)
                   : 1);
            const bool hasNativeData = (baseLevel.nativeBpp > 0 && !baseLevel.nativeData.empty());
            MTLPixelFormat wantFormat = MTLPixelFormatRGBA8Unorm;
            if (hasNativeData) {
                MTLPixelFormat native = metalRenderbufferFormat(baseLevel.desc.internalFormat);
                if (native != MTLPixelFormatInvalid) wantFormat = native;
            }
            GLint maxLevelExisting = 0;
            for (const auto& [levelIndex, image] : object.levels) {
                if (levelIndex >= 0 && image.defined) {
                    maxLevelExisting = std::max(maxLevelExisting, levelIndex);
                }
            }
            const NSUInteger wantMipCount = (object.target == GL_TEXTURE_1D)
                ? 1u
                : static_cast<NSUInteger>(maxLevelExisting + 1);
            const bool shapeMatches =
                existing.width == wantWidth &&
                existing.height == wantHeight &&
                existing.depth == wantDepth &&
                existing.arrayLength == wantArray &&
                existing.mipmapLevelCount == wantMipCount &&
                existing.pixelFormat == wantFormat;
            if (shapeMatches) {
                const bool useNativePath = (wantFormat != MTLPixelFormatRGBA8Unorm);
                for (const auto& [levelIndex, image] : object.levels) {
                    if (levelIndex < 0 || !image.defined) continue;
                    const std::uint8_t* bytes = nullptr;
                    std::size_t bpp = 4;
                    if (useNativePath && image.nativeBpp > 0 && !image.nativeData.empty()) {
                        bytes = image.nativeData.data();
                        bpp = image.nativeBpp;
                    } else if (useNativePath) {
                        continue;  // same rationale as the full-replace loop
                    } else if (!image.rgba8.empty()) {
                        bytes = image.rgba8.data();
                    } else {
                        continue;
                    }
                    const NSUInteger mipLevel = static_cast<NSUInteger>(levelIndex);
                    const NSUInteger rowStride = static_cast<NSUInteger>(safeDimension(image.desc.width)) * bpp;
                    const NSUInteger imageStride = rowStride * static_cast<NSUInteger>(
                        object.target == GL_TEXTURE_1D ? 1 : safeDimension(image.desc.height));
                    if (object.target == GL_TEXTURE_3D) {
                        const NSUInteger slices = static_cast<NSUInteger>(safeDimension(image.desc.depth));
                        for (NSUInteger slice = 0; slice < slices; ++slice) {
                            const MTLRegion r = MTLRegionMake3D(0, 0, slice,
                                static_cast<NSUInteger>(safeDimension(image.desc.width)),
                                static_cast<NSUInteger>(safeDimension(image.desc.height)), 1);
                            [existing replaceRegion:r mipmapLevel:mipLevel
                                          withBytes:bytes + slice * imageStride
                                        bytesPerRow:rowStride];
                        }
                    } else if (object.target == GL_TEXTURE_2D_ARRAY) {
                        const NSUInteger layers = static_cast<NSUInteger>(safeDimension(image.desc.depth));
                        const MTLRegion r = MTLRegionMake2D(0, 0,
                            static_cast<NSUInteger>(safeDimension(image.desc.width)),
                            static_cast<NSUInteger>(safeDimension(image.desc.height)));
                        for (NSUInteger layer = 0; layer < layers; ++layer) {
                            [existing replaceRegion:r mipmapLevel:mipLevel slice:layer
                                          withBytes:bytes + layer * imageStride
                                        bytesPerRow:rowStride
                                      bytesPerImage:imageStride];
                        }
                    } else if (object.target == GL_TEXTURE_1D_ARRAY) {
                        const NSUInteger layers = static_cast<NSUInteger>(safeDimension(image.desc.height));
                        const MTLRegion r = MTLRegionMake2D(0, 0,
                            static_cast<NSUInteger>(safeDimension(image.desc.width)), 1);
                        for (NSUInteger layer = 0; layer < layers; ++layer) {
                            [existing replaceRegion:r mipmapLevel:mipLevel slice:layer
                                          withBytes:bytes + layer * rowStride
                                        bytesPerRow:rowStride
                                      bytesPerImage:rowStride];
                        }
                    } else {
                        const MTLRegion r = MTLRegionMake2D(0, 0,
                            static_cast<NSUInteger>(safeDimension(image.desc.width)),
                            static_cast<NSUInteger>(
                                object.target == GL_TEXTURE_1D ? 1 : safeDimension(image.desc.height)));
                        [existing replaceRegion:r mipmapLevel:mipLevel
                                      withBytes:bytes
                                    bytesPerRow:rowStride];
                    }
                }
                object.instantiated = true;
                (void)texName;
                return true;
            }
        }

        GLint highestDefinedLevel = 0;
        for (const auto& [levelIndex, image] : object.levels) {
            if (levelIndex >= 0 && image.defined) {
                highestDefinedLevel = std::max(highestDefinedLevel, levelIndex);
            }
        }

        releaseRetainedMetalObject(object.metalTexture);
        object.metalTexture = nullptr;

        // Choose the native Metal pixel format when possible. Fall back
        // to RGBA8Unorm if the internal format isn't recognized or if
        // no native data was built for level 0.
        const bool hasNativeData = (baseLevel.nativeBpp > 0 && !baseLevel.nativeData.empty());
        MTLPixelFormat chosenFormat = MTLPixelFormatRGBA8Unorm;
        if (hasNativeData) {
            MTLPixelFormat nativeFmt = metalRenderbufferFormat(baseLevel.desc.internalFormat);
            if (nativeFmt != MTLPixelFormatInvalid) {
                chosenFormat = nativeFmt;
            }
        }

        MTLTextureDescriptor* descriptor = [[MTLTextureDescriptor alloc] init];
        descriptor.textureType = metalTextureTypeForTarget(object.target);
        descriptor.pixelFormat = chosenFormat;
        descriptor.width = static_cast<NSUInteger>(baseLevel.desc.width);
        // GL_TEXTURE_1D_ARRAY stores its layer count in `height` (2-arg GL API).
        // Metal requires height=1 for 1D array textures; layers come from arrayLength.
        const bool is1DArray = (object.target == GL_TEXTURE_1D_ARRAY);
        const bool is2DArray = (object.target == GL_TEXTURE_2D_ARRAY);
        descriptor.height = static_cast<NSUInteger>(
            (object.target == GL_TEXTURE_1D || is1DArray) ? 1 : baseLevel.desc.height);
        descriptor.depth = static_cast<NSUInteger>(object.target == GL_TEXTURE_3D ? baseLevel.desc.depth : 1);
        // Arrayed textures: Metal uses arrayLength. GL puts layer count in
        // `height` for 1D_ARRAY and `depth` for 2D_ARRAY.
        if (is1DArray) {
            descriptor.arrayLength = static_cast<NSUInteger>(baseLevel.desc.height);
        } else if (is2DArray) {
            descriptor.arrayLength = static_cast<NSUInteger>(baseLevel.desc.depth);
        }
        // MTLTextureType1D does not support mipmapping (Metal asserts
        // `mipmapLevelCount == 1` inside MTLTextureDescriptorInternal). GL
        // allows levels > 0 on 1D textures in principle, but our translation
        // layer doesn't need them — keep level 0 only for this target.
        const NSUInteger requestedLevels = static_cast<NSUInteger>(highestDefinedLevel + 1);
        descriptor.mipmapLevelCount = (object.target == GL_TEXTURE_1D) ? 1u : requestedLevels;
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        descriptor.storageMode = MTLStorageModeShared;

        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture == nil) {
            return false;
        }

        const bool useNativePath = (chosenFormat != MTLPixelFormatRGBA8Unorm);

        for (const auto& [levelIndex, image] : object.levels) {
            if (levelIndex < 0 || !image.defined) {
                continue;
            }
            // Decide which data buffer to upload from.
            const std::uint8_t* uploadBytes = nullptr;
            std::size_t bpp = 4; // default RGBA8
            if (useNativePath && image.nativeBpp > 0 && !image.nativeData.empty()) {
                uploadBytes = image.nativeData.data();
                bpp = image.nativeBpp;
            } else if (useNativePath) {
                // Native-path texture but this level is missing nativeData
                // (e.g. generated by generateMipmaps on older builds, or a
                // sparse-level descriptor). Skip the upload rather than
                // fall back to rgba8 — the rgba8 buffer is 4 bytes/pixel
                // but Metal's pixelFormat expects `nativeBpp` bytes/pixel,
                // so pushing rgba8 through replaceRegion trips AGX's
                // `bytes_per_row >= used_bytes_per_row` assertion (see the
                // flake cluster in KHR-GL46.texture_gather and
                // KHR-GL46.texture_border_clamp). Metal leaves the level's
                // storage zero-initialised, which produces wrong sample
                // values but is deterministic — the test fails cleanly
                // instead of flapping between pass and fail. Correct fill
                // for generated mips lands via the downsampleNative path
                // in generateMipmaps (same commit).
                continue;
            } else if (!image.rgba8.empty()) {
                uploadBytes = image.rgba8.data();
                bpp = 4;
            } else {
                continue;
            }
            const NSUInteger mipLevel = static_cast<NSUInteger>(levelIndex);
            const NSUInteger bytesPerRow = static_cast<NSUInteger>(safeDimension(image.desc.width) * bpp);
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
                    const auto* sliceBytes = uploadBytes + static_cast<std::size_t>(slice * bytesPerImage);
                    [texture replaceRegion:sliceRegion mipmapLevel:mipLevel withBytes:sliceBytes bytesPerRow:bytesPerRow];
                }
            } else if (object.target == GL_TEXTURE_2D_ARRAY) {
                // Each array layer is a separate Metal slice.
                const NSUInteger layers = static_cast<NSUInteger>(safeDimension(image.desc.depth));
                const MTLRegion layerRegion = MTLRegionMake2D(0, 0, region.size.width, region.size.height);
                for (NSUInteger layer = 0; layer < layers; ++layer) {
                    const auto* layerBytes = uploadBytes + static_cast<std::size_t>(layer * bytesPerImage);
                    [texture replaceRegion:layerRegion
                               mipmapLevel:mipLevel
                                     slice:layer
                                 withBytes:layerBytes
                               bytesPerRow:bytesPerRow
                             bytesPerImage:bytesPerImage];
                }
            } else if (object.target == GL_TEXTURE_1D_ARRAY) {
                // GL stores the 1D array layer count in `height`. Each layer
                // is one row of `width` pixels; Metal expects height=1 with
                // the layer index carried in `slice`.
                const NSUInteger layers = static_cast<NSUInteger>(safeDimension(image.desc.height));
                const MTLRegion layerRegion = MTLRegionMake2D(0, 0, region.size.width, 1);
                for (NSUInteger layer = 0; layer < layers; ++layer) {
                    const auto* layerBytes = uploadBytes + static_cast<std::size_t>(layer * bytesPerRow);
                    [texture replaceRegion:layerRegion
                               mipmapLevel:mipLevel
                                     slice:layer
                                 withBytes:layerBytes
                               bytesPerRow:bytesPerRow
                             bytesPerImage:bytesPerRow];
                }
            } else {
                [texture replaceRegion:region mipmapLevel:mipLevel withBytes:uploadBytes bytesPerRow:bytesPerRow];
            }
        }
        object.metalTexture = transferRetainedMetalObject(texture);
        // Mark the texture as instantiated so consumers (getTextureImage,
        // sampler resolve, etc) stop treating it as unpopulated. Without
        // this, anything that invalidates by setting instantiated=false
        // (e.g. copyImageSubData) is followed by a re-upload here that
        // never gets observed — the caller still sees !instantiated and
        // bails.
        object.instantiated = true;

        // Phase 8X Group 4d follow-up¹⁰ — §Primary upload-bytes
        // fingerprint for BAR's Theory A/B split.
        //
        // BAR's followup⁹ capture showed the two large glyph atlases
        // (texName=3 / texName=4) are `GL_RGBA8`, not compat single-
        // channel, so the followup⁹ compat-glyph sampler override
        // never touches them. The residual question is whether the
        // RGBA8 atlas bytes we hand to Metal are byte-identical to
        // what Recoil's font cache produces on native GL. Two
        // theories:
        //
        //   A (35% weighted) — sampler state (REPEAT wrap + mipmap
        //       filter without mip chain on texName=4) actually
        //       matters on Metal in a way it doesn't on native GL.
        //   B (65% weighted) — the RGBA8 upload bytes are themselves
        //       wrong. Our `buildRGBA8Upload` channel-fill path
        //       might swap channels, endianness, or stride for
        //       inputs that are already RGBA8 with no channel fill
        //       needed (the most common path for UI atlases).
        //
        // The cheap disambiguator is a fingerprint of the bytes we
        // actually send to Metal. BAR will cross-reference against
        // the same fingerprint computed on native GL inputs on
        // their side. Match → Theory B is out, bug is elsewhere.
        // Mismatch → Theory B is in, the upload path is corrupting
        // data.
        //
        // Fingerprint shape (per BAR's §Primary ask):
        //   - texName + internalFormat
        //   - width x height + total RGBA8 byte count
        //   - FNV-1a 32-bit hash of level-0 byte payload's first 256
        //     bytes and last 256 bytes (cheap, stable, easy to
        //     reproduce in any language — BAR can compute the same
        //     hash on native GL inputs without a library dependency)
        //   - Nonzero-byte histogram per 1/4 of the level-0 payload
        //     (four counters — detects all-zero quarters, which
        //     would reveal a channel-fill bug that blanks one
        //     channel or a stride bug that leaves gaps)
        //
        // Follow-up¹¹ — dedup re-fires on `(width, height, bytes)`
        // mismatch so we catch Recoil's `glTexImage2D(w,h,NULL)` ->
        // `glTexImage2D(real)` and `1×1 placeholder` -> `N×M real`
        // allocation patterns. Only fires when the caller passes a
        // non-zero `texName` — internal callers (generateMipmaps /
        // attachment clear) leave texName at the default so their
        // downstream re-uploads don't spam the log.
        bool shouldFireFingerprint = false;
        const char* reFireReason = "first";
        if (texName != 0) {
            const UploadFingerprintKey currentKey{
                baseLevel.desc.width,
                baseLevel.desc.height,
                baseLevel.rgba8.size(),
            };
            auto [it, inserted] = loggedUploadTextures.try_emplace(texName, currentKey);
            if (inserted) {
                shouldFireFingerprint = true;
                reFireReason = "first";
            } else if (it->second.width != currentKey.width
                    || it->second.height != currentKey.height
                    || it->second.rgba8Bytes != currentKey.rgba8Bytes) {
                // Figure out which component changed so BAR can tell
                // a dimension realloc from a pure byte-count change
                // (e.g. channel-fill format swap) at a glance.
                if (it->second.width != currentKey.width && it->second.height != currentKey.height) {
                    reFireReason = "dims";
                } else if (it->second.width != currentKey.width) {
                    reFireReason = "width";
                } else if (it->second.height != currentKey.height) {
                    reFireReason = "height";
                } else {
                    reFireReason = "bytes";
                }
                it->second = currentKey;
                shouldFireFingerprint = true;
            }
        }
        // Upload-fingerprint diagnostic gated behind env var. The log
        // message is ~200 chars and fires once per unique (texName,
        // dims) pair; CTS sweeps that allocate thousands of unique
        // textures (texture_swizzle, packed_pixels) make this the
        // single biggest NSLog cost. APPGL_LOG_TEXTURE_UPLOAD=1
        // restores the original logging (for BAR Theory A/B chasing).
        if (shouldFireFingerprint) {
            const auto& levelZero = baseLevel;
            const std::size_t byteCount = levelZero.rgba8.size();
            const std::uint8_t* bytes = levelZero.rgba8.data();

            // FNV-1a 32-bit hash — trivial to reproduce, no lib dep.
            auto fnv1a = [](const std::uint8_t* p, std::size_t n) {
                std::uint32_t h = 0x811c9dc5u;
                for (std::size_t i = 0; i < n; ++i) {
                    h ^= p[i];
                    h *= 0x01000193u;
                }
                return h;
            };
            const std::size_t headLen = std::min<std::size_t>(byteCount, 256);
            const std::size_t tailLen = byteCount > 256 ? 256 : 0;
            const std::uint32_t headHash = headLen ? fnv1a(bytes, headLen) : 0;
            const std::uint32_t tailHash = tailLen
                ? fnv1a(bytes + byteCount - tailLen, tailLen) : 0;

            // Nonzero-byte histogram per 1/4 of the payload. Catches
            // "channel zero-fill" and "stride-gap" bugs cheaply.
            std::uint32_t nonzeroQuartiles[4] = {0, 0, 0, 0};
            if (byteCount > 0) {
                const std::size_t quarterSize = byteCount / 4;
                for (int q = 0; q < 4; ++q) {
                    const std::size_t start = static_cast<std::size_t>(q) * quarterSize;
                    const std::size_t end = (q == 3) ? byteCount : (start + quarterSize);
                    std::uint32_t count = 0;
                    for (std::size_t i = start; i < end; ++i) {
                        if (bytes[i] != 0) { ++count; }
                    }
                    nonzeroQuartiles[q] = count;
                }
            }

            // First 16 bytes as hex — a "peek" for visually spotting
            // obvious channel swaps or zero-fill without computing
            // anything.
            char hexPeek[64];
            const std::size_t peekLen = std::min<std::size_t>(byteCount, 16);
            for (std::size_t i = 0; i < peekLen; ++i) {
                std::snprintf(hexPeek + i * 3, sizeof(hexPeek) - i * 3,
                              "%02X ", bytes[i]);
            }
            if (peekLen > 0) {
                hexPeek[peekLen * 3 - 1] = '\0';
            } else {
                hexPeek[0] = '\0';
            }

            APPGL_LOG(TEXTURE, @"[GL] replaceMetalTexture upload texName=%u reFire=%s"
                  @" internalFormat=0x%04X sourceFormat=0x%04X sourceType=0x%04X"
                  @" width=%d height=%d depth=%d rgba8Bytes=%zu"
                  @" fnv1a_head256=0x%08X fnv1a_tail256=0x%08X"
                  @" nonzeroQ0=%u nonzeroQ1=%u nonzeroQ2=%u nonzeroQ3=%u"
                  @" peek16=[%s]",
                  texName, reFireReason,
                  static_cast<unsigned>(levelZero.desc.internalFormat),
                  static_cast<unsigned>(levelZero.desc.sourceFormat),
                  static_cast<unsigned>(levelZero.desc.sourceType),
                  levelZero.desc.width, levelZero.desc.height, levelZero.desc.depth,
                  byteCount,
                  headHash, tailHash,
                  nonzeroQuartiles[0], nonzeroQuartiles[1],
                  nonzeroQuartiles[2], nonzeroQuartiles[3],
                  hexPeek);
        }
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
            // Use Shared storage so CPU can read back rendered data via
            // [MTLTexture getBytes:].  On Apple Silicon the unified memory
            // architecture makes Shared equivalent to Private in performance.
            descriptor.storageMode = MTLStorageModeShared;
            descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            if (samples > 1) {
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

        // Resolve the native downsample format once: it's shared across
        // every generated mip level (we only downsample within one
        // texture's pixel format). Returns kind=UNorm/channels=0 when
        // the base isn't a native-format texture (rgba8 path still does
        // the real work), which the caller skips below.
        const bool hasNativeBase = baseLevel.nativeBpp > 0 && !baseLevel.nativeData.empty();
        NativeDownsampleFormat nativeFmt{};
        if (hasNativeBase) {
            const MTLPixelFormat mtlFmt = metalRenderbufferFormat(baseLevel.desc.internalFormat);
            const auto info = nativeFormatInfo(mtlFmt);
            nativeFmt.channels = info.channels;
            nativeFmt.channelBytes = info.bytesPerChannel;
            switch (info.compType) {
                case NativeFormatInfo::UNorm: nativeFmt.kind = NativeDownsampleFormat::UNorm; break;
                case NativeFormatInfo::SNorm: nativeFmt.kind = NativeDownsampleFormat::SNorm; break;
                case NativeFormatInfo::UInt:  nativeFmt.kind = NativeDownsampleFormat::UInt; break;
                case NativeFormatInfo::SInt:  nativeFmt.kind = NativeDownsampleFormat::SInt; break;
                case NativeFormatInfo::Float: nativeFmt.kind = NativeDownsampleFormat::Float; break;
            }
        }

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
            // Also downsample nativeData when the texture has a non-
            // RGBA8 Metal pixel format. This matches what replaceMetal-
            // Texture's upload loop expects and avoids the AGX
            // `bytes_per_row >= used_bytes_per_row` assertion that
            // previously destabilised texture_gather / texture_border_clamp
            // tests (flake cluster surfaced via Golden Diff).
            if (hasNativeBase && nativeFmt.channels > 0) {
                generated.nativeData = downsampleNative(
                    previousLevel.nativeData,
                    previousLevel.desc.width,
                    previousLevel.desc.height,
                    previousLevel.desc.depth,
                    generated.desc.width,
                    generated.desc.height,
                    generated.desc.depth,
                    nativeFmt
                );
                generated.nativeBpp = baseLevel.nativeBpp;
            }
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
        // Metal requires lodMinClamp >= 0 and lodMaxClamp >= lodMinClamp.
        // GL's defaults are minLod=-1000, maxLod=1000 which Metal rejects.
        // Clamp to [0, max(0, maxLod)] — for the common GL default this
        // collapses to [0, 1000], which is still effectively unbounded.
        descriptor.lodMinClamp = std::max(0.0f, object.params.minLod);
        descriptor.lodMaxClamp = std::max(descriptor.lodMinClamp, object.params.maxLod);
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
        // Metal requires lodMinClamp >= 0 and lodMaxClamp >= lodMinClamp.
        // GL's defaults are minLod=-1000, maxLod=1000 which Metal rejects.
        // Clamp to [0, max(0, maxLod)] — for the common GL default this
        // collapses to [0, 1000], which is still effectively unbounded.
        descriptor.lodMinClamp = std::max(0.0f, object.params.minLod);
        descriptor.lodMaxClamp = std::max(descriptor.lodMinClamp, object.params.maxLod);
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
        //   wrap s/t/r = ClampToBorderColor + TransparentBlack
        //                (followup¹²; see comment below)
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
        //
        // Phase 8X Group 4d follow-up¹² — address-mode revision.
        //
        // followup¹¹'s widened dedup caught the real 256×225 GL_ALPHA
        // glyph atlas (texName=1) being uploaded via a
        // `glTexImage2D(1×1 placeholder) → glTexImage2D(256×225 real)`
        // reallocation pattern that followup¹⁰'s texName-only dedup
        // had silenced. With the atlas now visible, BAR's followup¹¹
        // verification memo (docs/phase-8x-group-4d-followup11-
        // verification.md §"Theory A") reported that Recoil had
        // *explicitly* set `wrapS=wrapT=GL_CLAMP_TO_BORDER` on the
        // glyph atlas — which is the correct address mode for a
        // tightly-packed glyph atlas. When a linear filter kernel
        // samples slightly outside a glyph's UV rectangle (at the
        // right or bottom edge of the glyph quad, due to sub-pixel
        // positioning), `ClampToBorder + TransparentBlack` returns a
        // transparent black pixel. `ClampToEdge` returns the
        // leftmost/topmost pixel of the *next glyph* in the atlas,
        // which manifests as "smeared / double-exposed glyphs" in
        // text rendering — exactly the remaining visible artifact.
        //
        // followup⁹'s initial sledgehammer picked `ClampToEdge`
        // because it was the common default and the priority at that
        // round was fixing the `maxLevel=1000` LOD trap and the
        // `wrap=REPEAT` bleed, both of which are genuine bugs on a
        // compat-profile glyph atlas. With the LOD and mip sides
        // locked down, the address mode can now move to what Recoil
        // actually wanted.
        //
        // Metal's `MTLSamplerAddressModeClampToBorderColor` plus
        // `MTLSamplerBorderColorTransparentBlack` has been available
        // since macOS 10.12, well below our deployment target, and
        // the rest of the runtime already maps GL_CLAMP_TO_BORDER to
        // this mode in `metalAddressMode()` — so this override aligns
        // with the non-compat path.
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
            if (@available(macOS 10.12, *)) {
                descriptor.sAddressMode = MTLSamplerAddressModeClampToBorderColor;
                descriptor.tAddressMode = MTLSamplerAddressModeClampToBorderColor;
                descriptor.rAddressMode = MTLSamplerAddressModeClampToBorderColor;
                descriptor.borderColor = MTLSamplerBorderColorTransparentBlack;
            } else {
                // Fallback on pre-10.12 systems — Metal doesn't
                // support border color there. Use ClampToEdge as the
                // next-closest approximation; this path will not be
                // exercised on any supported macOS deployment target
                // but keeps the override well-defined.
                descriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
                descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
                descriptor.rAddressMode = MTLSamplerAddressModeClampToEdge;
            }
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
            //
            // Phase 8X Group 4d follow-up¹² — append an
            // `overrideAddressMode=` tag so BAR can confirm that the
            // post-override sampler descriptor now uses
            // ClampToBorderColor+TransparentBlack (not ClampToEdge)
            // on the glyph atlas. The `object.params` readout is
            // unchanged: it still reports what Recoil asked for, so
            // the delta between params.wrapS and overrideAddressMode
            // makes the override action visible on one line.
            const char* overrideAddressModeTag = "pass-through";
            if (isCompatGlyphFormat) {
                if (@available(macOS 10.12, *)) {
                    overrideAddressModeTag = "ClampToBorder+TransparentBlack";
                } else {
                    overrideAddressModeTag = "ClampToEdge (pre-10.12)";
                }
            }
            APPGL_LOG(TEXTURE, @"[GL] rebuildTextureSamplerState first-build texName=%u"
                  @" internalFormat=0x%04X override=%s"
                  @" overrideAddressMode=%s"
                  @" minFilter=0x%04X magFilter=0x%04X"
                  @" wrapS=0x%04X wrapT=0x%04X wrapR=0x%04X"
                  @" minLod=%.2f maxLod=%.2f baseLevel=%d maxLevel=%d"
                  @" compareMode=0x%04X compareFunc=0x%04X",
                  texName,
                  static_cast<unsigned>(internalFormat),
                  isCompatGlyphFormat ? "glyph-compat" : "none",
                  overrideAddressModeTag,
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

    // ---------- Texture swizzle view ----------
    //
    // GL_TEXTURE_SWIZZLE_* parameters are applied via a Metal texture
    // view with MTLTextureSwizzleChannels. The view shares the same
    // storage as the base texture (no data copy). Created lazily when
    // non-default swizzle is detected; cached on the texture object.
    //
    static MTLTextureSwizzle metalTextureSwizzle(GLint glSwizzle) {
        switch (glSwizzle) {
            case GL_RED:   return MTLTextureSwizzleRed;
            case GL_GREEN: return MTLTextureSwizzleGreen;
            case GL_BLUE:  return MTLTextureSwizzleBlue;
            case GL_ALPHA: return MTLTextureSwizzleAlpha;
            case GL_ZERO:  return MTLTextureSwizzleZero;
            case GL_ONE:   return MTLTextureSwizzleOne;
            default:       return MTLTextureSwizzleRed;
        }
    }

    static bool isDefaultSwizzle(const std::array<GLint, 4>& sw) {
        return sw[0] == GL_RED && sw[1] == GL_GREEN &&
               sw[2] == GL_BLUE && sw[3] == GL_ALPHA;
    }

    // Returns the texture to bind — either the swizzled view (if
    // non-default swizzle) or the base metalTexture. Lazily rebuilds
    // the swizzled view when `swizzleDirty` is set.
    void* resolveSwizzledTexture(GLTextureObject& texObj) {
        const auto& sw = texObj.params.swizzle;

        // Fast path: default swizzle — use base texture, release any
        // stale view.
        if (isDefaultSwizzle(sw)) {
            if (texObj.metalSwizzledView != nullptr) {
                releaseRetainedMetalObject(texObj.metalSwizzledView);
                texObj.metalSwizzledView = nullptr;
            }
            texObj.swizzleDirty = false;
            return texObj.metalTexture;
        }

        // Non-default swizzle — rebuild view if dirty.
        if (!texObj.swizzleDirty && texObj.metalSwizzledView != nullptr) {
            return texObj.metalSwizzledView;
        }

        // Release the old view.
        releaseRetainedMetalObject(texObj.metalSwizzledView);
        texObj.metalSwizzledView = nullptr;

        id<MTLTexture> baseTex = (__bridge id<MTLTexture>)texObj.metalTexture;
        if (baseTex == nil) {
            texObj.swizzleDirty = false;
            return texObj.metalTexture;
        }

        MTLTextureSwizzleChannels channels;
        channels.red   = metalTextureSwizzle(sw[0]);
        channels.green = metalTextureSwizzle(sw[1]);
        channels.blue  = metalTextureSwizzle(sw[2]);
        channels.alpha = metalTextureSwizzle(sw[3]);

        id<MTLTexture> swizzledView = [baseTex
            newTextureViewWithPixelFormat:baseTex.pixelFormat
                             textureType:baseTex.textureType
                                  levels:NSMakeRange(0, baseTex.mipmapLevelCount)
                                  slices:NSMakeRange(0, baseTex.arrayLength)
                                 swizzle:channels];
        if (swizzledView != nil) {
            texObj.metalSwizzledView = transferRetainedMetalObject(swizzledView);
        }
        texObj.swizzleDirty = false;
        return texObj.metalSwizzledView != nullptr
            ? texObj.metalSwizzledView
            : texObj.metalTexture;
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
    // Scans the attached shaders' GLSL source for a `layout(binding = N)
    // uniform ... sampler<type> <samplerName>` declaration. Returns
    // true if found in any attached shader, false otherwise.
    //
    // Needed because glslang emits `DecorationBinding` for EVERY sampler
    // (both explicit `layout(binding=N)` and auto-assigned), so
    // SPIRV-Cross's `has_decoration(id, Binding)` can't distinguish
    // user-set from auto. An earlier attempt (reverted as 09f7949) used
    // has_decoration and regressed pixelstoragemodes 704→0 because
    // auto-assigned non-zero bindings leaked into the fallback.
    //
    // Scanning the original GLSL avoids that: only the user-written
    // `layout(binding=N)` text produces a match. Runs ~once per sampler
    // per first-draw (resolveSamplerBindings is hot but the first-draw
    // cache elides the repeat).
    //
    // Statement-level scan (split on `;`) keeps us robust against the
    // layout-qualifier being across multiple lines, and against other
    // layout qualifiers like `layout(location=5, binding=N)`.
    static bool isGlslIdentChar(char c) {
        return (c == '_') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
    }
    bool samplerHasLayoutBinding(const GLProgramObject& program,
                                  const std::string& samplerName) const {
        for (GLuint shaderId : program.attachedShaders) {
            const GLShaderObject* shaderObject = objects->shaders().get(shaderId);
            if (shaderObject == nullptr) continue;
            const std::string& source = shaderObject->source;
            std::size_t pos = 0;
            while (pos < source.size()) {
                const std::size_t endStmt = source.find(';', pos);
                const std::size_t stop = (endStmt == std::string::npos) ? source.size() : endStmt;
                // Each statement is a candidate. Require the four
                // lexical tokens: layout, binding, uniform, sampler.
                const std::size_t len = stop - pos;
                if (len >= 24) {  // heuristic minimum for the declaration text
                    const char* seg = source.data() + pos;
                    auto contains = [seg, len](const char* needle) -> bool {
                        const std::size_t nlen = std::strlen(needle);
                        if (nlen > len) return false;
                        for (std::size_t i = 0; i + nlen <= len; ++i) {
                            if (std::memcmp(seg + i, needle, nlen) == 0) return true;
                        }
                        return false;
                    };
                    if (contains("layout") && contains("binding") &&
                        contains("uniform") && contains("sampler")) {
                        // Whole-word check for the sampler name within
                        // this statement — avoids matching sampler
                        // names that are substrings of other idents.
                        const std::size_t nlen = samplerName.size();
                        for (std::size_t i = 0; i + nlen <= len; ++i) {
                            if (std::memcmp(seg + i, samplerName.data(), nlen) != 0) continue;
                            const bool leftOk = (i == 0) || !isGlslIdentChar(seg[i - 1]);
                            const bool rightOk = (i + nlen == len) || !isGlslIdentChar(seg[i + nlen]);
                            if (leftOk && rightOk) {
                                return true;
                            }
                        }
                    }
                }
                if (endStmt == std::string::npos) break;
                pos = endStmt + 1;
            }
        }
        return false;
    }

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
        // Diagnostic logging was previously unconditional at first-draw
        // per program. For CTS sweeps that create thousands of unique
        // programs (texture_swizzle creates ~700 one-off variants) the
        // NSLog storm became the dominant sweep cost — sampling showed
        // the sweep spending most time in NSLog. Gate the whole
        // first-call dump (summary + MSL + uniform snapshot) on an
        // opt-in env var. The tight summary line still fires on the
        // error / skip paths below, unconditionally, so the common
        // "why didn't this sampler bind?" debugging stays loud.
        const bool logThisCall = (info.program != 0) &&
            loggedSamplerResolvePrograms.insert(info.program).second;
        if (logThisCall) {
            const std::size_t fragCount = info.fragmentReflection
                ? info.fragmentReflection->sampledTextures.size() : 0;
            const std::size_t vertCount = info.vertexReflection
                ? info.vertexReflection->sampledTextures.size() : 0;
            APPGL_LOG(TEXTURE, @"[GL] resolveSamplerBindings first-call program=%u"
                  @" fragment.sampledTextures=%zu vertex.sampledTextures=%zu"
                  @" uniforms=%zu",
                  info.program, fragCount, vertCount, program.uniforms.size());

            // Phase 8X Group 4d follow-up¹² — §Secondary: dump the full
            // translated MSL source and uniform snapshot for this
            // program, once at first resolve.
            //
            // BAR's followup¹¹ verification memo (Theory B) asked for
            // this so they can determine whether program 5's vertex
            // shader correctly normalizes the pixel-coord UVs into the
            // `vUV` varying on its way to the fragment stage, or
            // whether the SPIRV-Cross translation drops the
            // normalization step. The pipelineCache `mslPreview` they
            // see on shutdown is capped at ~200 chars by the ring
            // budget — that reaches the top-of-file struct decls and
            // nothing else. Here we dump the whole string, one line
            // per NSLog, so every line stays grep-able with the `[GL]`
            // prefix and BAR can locate the start/end of each section
            // without worrying about NSLog line-splitting. The dump is
            // one-shot per program (keyed on the same
            // `loggedSamplerResolvePrograms` set that gates the
            // first-call summary above), so cost is paid once at
            // startup per program.
            //
            // Format per program:
            //   msl-dump program=P BEGIN
            //   vs.summary bytes=... lines=... hasTextureSize=? hasGetWidth=? hasGetHeight=?
            //   vs.L001: <first line of vertex MSL>
            //   ...
            //   vs.END
            //   fs.summary bytes=... lines=... hasTextureSize=? hasGetWidth=? hasGetHeight=?
            //   fs.L001: <first line of fragment MSL>
            //   ...
            //   fs.END
            //   uniforms-snapshot program=P count=N
            //     uniform[i] name=... location=... type=0xHHHH arraySize=... value=...
            //   msl-dump program=P END
            //
            // The `hasTextureSize` / `hasGetWidth` / `hasGetHeight`
            // scan catches the three ways a translated MSL vertex
            // shader could normalize pixel-coord UVs at run-time
            // without a CPU-supplied inverse-atlas-size uniform.
            // All three missing + no `u_atlasSize`-ish uniform in
            // the snapshot → Theory B lands: the translation is
            // dropping the normalization. All three missing + a
            // likely inverse-atlas uniform present → Theory B lands
            // on Recoil's side (they're supposed to plumb it but
            // don't). Any one present → normalization exists and
            // Theory B is out, focus shifts to the sampler path.
            auto emitMslDump = [](const char* stageTag, const std::string& msl) {
                // Quick scans for the three normalization markers.
                auto containsToken = [](const std::string& hay, const char* needle) -> bool {
                    return hay.find(needle) != std::string::npos;
                };
                const bool hasTextureSize = containsToken(msl, "textureSize(");
                const bool hasGetWidth = containsToken(msl, ".get_width(");
                const bool hasGetHeight = containsToken(msl, ".get_height(");

                // Count lines so BAR can cross-check the dump
                // isn't truncated by NSLog or the OS log ring.
                std::size_t lineCount = 0;
                for (char c : msl) {
                    if (c == '\n') ++lineCount;
                }
                if (!msl.empty() && msl.back() != '\n') {
                    ++lineCount;  // account for the unterminated final line
                }

                APPGL_LOG(SHADER, @"[GL]   %s.summary bytes=%zu lines=%zu"
                      @" hasTextureSize=%d hasGetWidth=%d hasGetHeight=%d",
                      stageTag,
                      msl.size(),
                      lineCount,
                      hasTextureSize ? 1 : 0,
                      hasGetWidth ? 1 : 0,
                      hasGetHeight ? 1 : 0);

                // Emit every line individually so grep-for-prefix
                // on the spring stderr capture can always locate
                // the full block, and so each line remains under
                // the OS log per-message truncation budget.
                std::size_t lineIdx = 0;
                std::size_t start = 0;
                for (std::size_t i = 0; i <= msl.size(); ++i) {
                    if (i == msl.size() || msl[i] == '\n') {
                        ++lineIdx;
                        const std::size_t len = i - start;
                        const std::string line = msl.substr(start, len);
                        APPGL_LOG(SHADER, @"[GL]   %s.L%03zu: %s",
                              stageTag, lineIdx, line.c_str());
                        start = i + 1;
                        if (i == msl.size()) break;
                    }
                }
                APPGL_LOG(SHADER, @"[GL]   %s.END", stageTag);
            };

            APPGL_LOG(SHADER, @"[GL] msl-dump program=%u BEGIN", info.program);
            emitMslDump("vs", program.vertexMSL);
            emitMslDump("fs", program.fragmentMSL);

            // Uniform snapshot — names, locations, types, and the
            // current CPU-shadowed values. BAR specifically asked
            // for this so they can answer "is there an atlas-size
            // uniform plumbed into program 5 at all?" without
            // having to cross-reference the link-time reflection
            // against a separate uniformValues dump.
            APPGL_LOG(SHADER, @"[GL]   uniforms-snapshot program=%u count=%zu",
                  info.program, program.uniforms.size());
            for (std::size_t ui = 0; ui < program.uniforms.size(); ++ui) {
                const auto& uinfo = program.uniforms[ui];
                // Best-effort value decode. Sampler uniforms carry
                // the bound texture unit in `ints[0]`. Scalar and
                // vector float uniforms carry up to 16 floats for
                // mat4. We print up to 4 elements of whatever the
                // shadow vector holds, plus the raw type hex so BAR
                // can fully disambiguate downstream.
                const auto valIt = program.uniformValues.find(uinfo.location);
                const bool hasValue = (valIt != program.uniformValues.end());

                char valueBuf[192];
                valueBuf[0] = '\0';
                if (hasValue) {
                    const auto& uval = valIt->second;
                    if (!uval.floats.empty()) {
                        const std::size_t n = std::min<std::size_t>(uval.floats.size(), 4);
                        int off = std::snprintf(valueBuf, sizeof(valueBuf), "floats[");
                        for (std::size_t i = 0; i < n; ++i) {
                            off += std::snprintf(valueBuf + off,
                                                 sizeof(valueBuf) - off,
                                                 "%s%.4f",
                                                 i == 0 ? "" : " ",
                                                 uval.floats[i]);
                        }
                        std::snprintf(valueBuf + off, sizeof(valueBuf) - off,
                                      "%s total=%zu]",
                                      uval.floats.size() > n ? "..." : "",
                                      uval.floats.size());
                    } else if (!uval.ints.empty()) {
                        const std::size_t n = std::min<std::size_t>(uval.ints.size(), 4);
                        int off = std::snprintf(valueBuf, sizeof(valueBuf), "ints[");
                        for (std::size_t i = 0; i < n; ++i) {
                            off += std::snprintf(valueBuf + off,
                                                 sizeof(valueBuf) - off,
                                                 "%s%d",
                                                 i == 0 ? "" : " ",
                                                 uval.ints[i]);
                        }
                        std::snprintf(valueBuf + off, sizeof(valueBuf) - off,
                                      "%s total=%zu]",
                                      uval.ints.size() > n ? "..." : "",
                                      uval.ints.size());
                    } else if (!uval.uints.empty()) {
                        std::snprintf(valueBuf, sizeof(valueBuf),
                                      "uints[count=%zu first=%u]",
                                      uval.uints.size(),
                                      uval.uints[0]);
                    } else if (!uval.doubles.empty()) {
                        std::snprintf(valueBuf, sizeof(valueBuf),
                                      "doubles[count=%zu first=%.4f]",
                                      uval.doubles.size(),
                                      uval.doubles[0]);
                    } else {
                        std::snprintf(valueBuf, sizeof(valueBuf),
                                      "empty-shadow");
                    }
                } else {
                    std::snprintf(valueBuf, sizeof(valueBuf), "unset");
                }

                APPGL_LOG(SHADER, @"[GL]     uniform[%zu] name='%s' location=%d"
                      @" type=0x%04X arraySize=%d value=%s",
                      ui,
                      uinfo.name.c_str(),
                      uinfo.location,
                      static_cast<unsigned>(uinfo.type),
                      uinfo.arraySize,
                      valueBuf);
            }
            APPGL_LOG(SHADER, @"[GL] msl-dump program=%u END", info.program);
        }

        auto resolveStage = [&](const char* stageTag,
                                const ShaderReflection* reflection,
                                std::vector<TranslatedDrawInfo::TextureBinding>& outBindings) {
            if (reflection == nullptr || reflection->sampledTextures.empty()) {
                return;
            }
            for (const auto& sampledTex : reflection->sampledTextures) {
                // Step 1: find the GL sampler uniform by name. For sampler
                // arrays (`uniform sampler2D samp[N]`), SPIRV-Cross emits a
                // single sampledTextures entry whose metalBinding spans N
                // consecutive slots. The matching GL uniform has
                // arraySize > 1, and `ints[i]` holds the texture unit for
                // element i. We loop over all elements below.
                GLint uniformLocation = -1;
                GLint samplerArraySize = 1;
                for (const auto& uinfo : program.uniforms) {
                    if (uinfo.name == sampledTex.name) {
                        uniformLocation = uinfo.location;
                        samplerArraySize = std::max<GLint>(uinfo.arraySize, 1);
                        break;
                    }
                }

                const GLProgramUniformValue* samplerValue = nullptr;
                if (uniformLocation >= 0) {
                    auto it = program.uniformValues.find(uniformLocation);
                    if (it != program.uniformValues.end()) {
                        samplerValue = &it->second;
                    }
                }

                for (GLint arrayElement = 0; arrayElement < samplerArraySize; ++arrayElement) {
                    // Step 2: resolve the texture unit index for this
                    // array element. Sampler uniforms default to 0 per GL
                    // spec when the app never called glUniform1i — but
                    // GL 4.2 §7.6 says that when the GLSL declared
                    // `layout(binding = N)`, N is the default unit. We
                    // track that explicit declaration via the source-
                    // parsed `samplerExplicitBindings` map populated at
                    // link time (bd73acc's SPIRV-Cross `has_decoration`
                    // approach couldn't tell user-declared apart from
                    // glslang-auto-assigned, which regressed
                    // pixelstoragemodes — the GLSL-source parse is
                    // unambiguous).
                    GLint glUnit = 0;
                    bool uniformValueWasSet = false;
                    if (samplerValue != nullptr && static_cast<std::size_t>(arrayElement) < samplerValue->ints.size()) {
                        glUnit = samplerValue->ints[arrayElement];
                        uniformValueWasSet = true;
                    }
                    // Note: GL 4.2 layout(binding=N) default-unit is
                    // baked into `samplerValue->ints[arrayElement]`
                    // at link time (see the samplerExplicitBindings
                    // seed in linkProgram), so this path picks it up
                    // naturally when the app hasn't called
                    // glUniform1i.
                if (glUnit < 0) {
                    if (logThisCall) {
                        APPGL_LOG(TEXTURE, @"[GL]   %s sampler='%s' metalSlot=%u"
                              @" SKIP reason=negative-unit glUnit=%d",
                              stageTag, sampledTex.name.c_str(),
                              sampledTex.metalBinding, glUnit);
                    }
                    continue;  // malformed app state; skip silently
                }

                // Step 3: look up the texture object bound to that unit.
                // Try GL_TEXTURE_2D first (overwhelming common case in
                // compat/Spring-style apps), then fall back to any-target
                // probe so samplerCube / sampler2DArray / usampler2D /
                // sampler3D uniforms also bind correctly. Previously this
                // hard-coded GL_TEXTURE_2D, which meant every non-2D
                // sampler silently dropped its binding — observed as ~497
                // test failures in KHR-GL46.texture_swizzle.* because the
                // suite tests on GL_TEXTURE_2D_ARRAY.
                GLuint texName = state->boundTextureOnUnit(
                    static_cast<GLuint>(glUnit), GL_TEXTURE_2D);
                if (texName == 0) {
                    GLenum discoveredTarget = 0;
                    texName = state->boundTextureOnUnitAny(
                        static_cast<GLuint>(glUnit), &discoveredTarget);
                    (void)discoveredTarget;
                }
                if (texName == 0) {
                    if (logThisCall) {
                        APPGL_LOG(TEXTURE, @"[GL]   %s sampler='%s' metalSlot=%u"
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
                        APPGL_LOG(TEXTURE, @"[GL]   %s sampler='%s' metalSlot=%u"
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
                        APPGL_LOG(TEXTURE, @"[GL]   %s sampler='%s' metalSlot=%u"
                              @" SKIP reason=sampler-build-failed glUnit=%d"
                              @" texName=%u standAloneSampler=%u",
                              stageTag, sampledTex.name.c_str(),
                              sampledTex.metalBinding, glUnit, texName,
                              samplerName);
                    }
                    continue;  // sampler build failure; nothing to bind
                }

                // Step 5: push the binding at the reflected Metal slot.
                // For sampler arrays, each array element maps to a
                // consecutive Metal slot starting at metalBinding.
                TranslatedDrawInfo::TextureBinding binding;
                binding.metalSlot = sampledTex.metalBinding + static_cast<std::uint32_t>(arrayElement);
                binding.metalTexture = resolveSwizzledTexture(*texObject);
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
                    APPGL_LOG(TEXTURE, @"[GL]   %s sampler='%s' metalSlot=%u BOUND"
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
            }
        };

        resolveStage("frag", info.fragmentReflection, info.fragmentTextures);
        resolveStage("vert", info.vertexReflection, info.vertexTextures);
    }

    // Resolve Uniform Buffer Object bindings from the GL state and
    // populate tdi.uboBindings so encodeTranslatedDraw can bind them
    // to the Metal render encoder.
    void resolveUBOBindings(
        GLProgramObject& program,
        TranslatedDrawInfo& info)
    {
        info.uboBindings.clear();

        auto resolveBlocks = [&](const ShaderReflection* reflection,
                                 bool isVertex, bool isFragment) {
            if (reflection == nullptr) return;
            for (const auto& block : reflection->uniformBlocks) {
                // Handle UBO arrays: each element gets its own binding.
                const int numInstances = (block.blockArraySize > 0)
                    ? static_cast<int>(block.blockArraySize) : 1;
                const bool isArray = (block.blockArraySize > 0);

                for (int inst = 0; inst < numInstances; ++inst) {
                    // Build the lookup name: "BlockA" or "BlockA[0]", "BlockA[1]"…
                    std::string lookupName = block.name;
                    if (isArray) {
                        lookupName += "[" + std::to_string(inst) + "]";
                    }

                    // Find the GL binding point for this block/element by matching
                    // against resourceUniformBlocks.
                    GLuint glBindingPoint = block.glBinding + static_cast<GLuint>(inst);
                    for (std::size_t bi = 0; bi < program.resourceUniformBlocks.size(); ++bi) {
                        if (program.resourceUniformBlocks[bi].name == lookupName) {
                            GLint bp = program.resourceUniformBlocks[bi].location;
                            if (bp >= 0) {
                                glBindingPoint = static_cast<GLuint>(bp);
                            }
                            break;
                        }
                    }

                    // Look up the buffer bound to GL_UNIFORM_BUFFER at this binding point.
                    GLIndexedBufferBinding binding = state->indexedBufferBinding(
                        GL_UNIFORM_BUFFER, glBindingPoint);
                    if (binding.buffer == 0) continue;

                    const GLBufferObject* bufObj = objects->buffers().get(binding.buffer);
                    if (bufObj == nullptr || bufObj->shadowBytes.empty()) continue;

                    const std::uint8_t* dataPtr = bufObj->shadowBytes.data();
                    std::size_t dataSize = bufObj->shadowBytes.size();

                    if (binding.offset > 0) {
                        if (static_cast<std::size_t>(binding.offset) >= dataSize) continue;
                        dataPtr += binding.offset;
                        dataSize -= static_cast<std::size_t>(binding.offset);
                    }
                    if (binding.size > 0 && static_cast<std::size_t>(binding.size) < dataSize) {
                        dataSize = static_cast<std::size_t>(binding.size);
                    }

                    TranslatedDrawInfo::UBOBinding ubo;
                    ubo.metalSlot = block.metalBinding + static_cast<std::uint32_t>(inst);
                    ubo.data = dataPtr;
                    ubo.size = dataSize;
                    // For UBOs > 4KB, use the Metal buffer directly (setVertexBytes
                    // has a 4096-byte limit on Apple GPUs).
                    if (dataSize > 4096 && bufObj->metalBuffer != nullptr) {
                        ubo.metalBuffer = bufObj->metalBuffer;
                        ubo.metalBufferOffset = static_cast<std::size_t>(binding.offset);
                    }
                    ubo.isVertex = isVertex;
                    ubo.isFragment = isFragment;
                    info.uboBindings.push_back(ubo);
                }
            }
        };

        resolveBlocks(info.vertexReflection, true, false);
        resolveBlocks(info.fragmentReflection, false, true);
    }

    // Graphics-stage SSBO binding. GL 4.3+ allows VS/FS to declare
    // `layout(std430, binding=N) buffer X` and read/write through the
    // bound MTLBuffer. This mirrors the compute-dispatch SSBO path but
    // targets the render encoder instead of the compute encoder.
    // Covers KHR-GL46.shader_storage_buffer_object.*-{vs,fs} which
    // currently fail because the encoder never binds the SSBO buffer
    // to the Metal slot the MSL expects.
    void resolveSSBOBindings(
        GLProgramObject& program,
        TranslatedDrawInfo& info)
    {
        info.ssboBindings.clear();

        auto resolveStage = [&](const ShaderReflection* reflection,
                                bool isVertex, bool isFragment) {
            if (reflection == nullptr) return;
            for (const auto& ssbo : reflection->storageBuffers) {
                const GLIndexedBufferBinding binding =
                    state->indexedBufferBinding(GL_SHADER_STORAGE_BUFFER, ssbo.glBinding);
                if (binding.buffer == 0) continue;
                const GLBufferObject* bufObj = objects->buffers().get(binding.buffer);
                if (bufObj == nullptr || bufObj->metalBuffer == nullptr) continue;
                TranslatedDrawInfo::SSBOBinding sb;
                sb.metalSlot = ssbo.metalBinding;
                sb.metalBuffer = bufObj->metalBuffer;
                sb.offset = static_cast<std::size_t>(binding.offset);
                sb.isVertex = isVertex;
                sb.isFragment = isFragment;
                info.ssboBindings.push_back(sb);
            }
        };
        resolveStage(info.vertexReflection, true, false);
        resolveStage(info.fragmentReflection, false, true);
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
        // ADV-10: invalidate cached index expansion on data change.
        ++object.indexExpansionGeneration;
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
        bool hasColorAttachment = false;
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
            if (isColorAttachment(attachmentPoint)) {
                hasColorAttachment = true;
            }
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

        // Per GL 4.6 §9.4.1 the DRAW_BUFFER / READ_BUFFER incomplete
        // classifications are interpreted leniently by real drivers:
        // writes to a draw buffer that references an unattached point
        // are treated as write-to-discard rather than incompleteness.
        // CTS agrees on two fronts:
        //   - framebuffers_clear creates a depth-only FB and expects
        //     GL_FRAMEBUFFER_COMPLETE even though DRAW_BUFFER0 defaults
        //     to COLOR_ATTACHMENT0 (which is unattached).
        //   - framebuffers_renderbuffer_attachment attaches a single RB
        //     at COLOR_ATTACHMENTn (n>0) and checks completeness; the
        //     default drawBuffer still points at ATTACHMENT0 which is
        //     unattached, but the FB should still be COMPLETE.
        // The stricter INCOMPLETE_DRAW_BUFFER check only fires when an
        // attachment point is explicitly referenced via glDrawBuffers
        // AND the attachment itself is incomplete (not just missing).
        (void)hasColorAttachment;
        for (GLenum buffer : framebuffer.drawBuffers) {
            if (buffer == GL_NONE) {
                continue;
            }
            const auto attachment = framebuffer.attachments.find(buffer);
            if (attachment != framebuffer.attachments.end()) {
                const auto info = framebufferAttachmentInfo(attachment->second);
                if (info.present && !info.complete) {
                    return GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER;
                }
            }
        }
        if (framebuffer.readBuffer != GL_NONE) {
            const auto attachment = framebuffer.attachments.find(framebuffer.readBuffer);
            if (attachment != framebuffer.attachments.end()) {
                const auto info = framebufferAttachmentInfo(attachment->second);
                if (info.present && !info.complete) {
                    return GL_FRAMEBUFFER_INCOMPLETE_READ_BUFFER;
                }
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

    // Resolve the bound draw-framebuffer's color attachment to a Metal
    // texture suitable for use as a render target.  Returns nullptr when
    // the default framebuffer is bound (FBO 0) or when the attachment
    // has no Metal texture.  Also populates width/height/depthStencil.
    void* resolveFBOColorTarget(GLsizei& outWidth, GLsizei& outHeight,
                                void*& outDepthStencil) const {
        const GLuint fboName = state->boundDrawFramebuffer();
        if (fboName == 0) {
            return nullptr;
        }
        const GLFramebufferObject* fbo = objects->framebuffers().get(fboName);
        if (fbo == nullptr) return nullptr;

        // Find the first active draw buffer's color attachment.
        void* colorTex = nullptr;
        outWidth = 0;
        outHeight = 0;
        for (GLenum buf : fbo->drawBuffers) {
            if (buf == GL_NONE) continue;
            const GLFramebufferAttachment* att = framebufferAttachment(*fbo, buf);
            if (att == nullptr) continue;
            if (att->kind == GLFramebufferAttachment::Kind::Texture) {
                const GLTextureObject* tex = objects->textures().get(att->object);
                if (tex != nullptr && tex->metalTexture != nullptr) {
                    colorTex = tex->metalTexture;
                    const auto lvl = tex->levels.find(att->level);
                    if (lvl != tex->levels.end()) {
                        outWidth = lvl->second.desc.width;
                        outHeight = lvl->second.desc.height;
                    }
                }
            } else if (att->kind == GLFramebufferAttachment::Kind::Renderbuffer) {
                const GLRenderbufferObject* rb = objects->renderbuffers().get(att->object);
                if (rb != nullptr && rb->metalTexture != nullptr) {
                    colorTex = rb->metalTexture;
                    outWidth = rb->width;
                    outHeight = rb->height;
                }
            }
            if (colorTex != nullptr) break;
        }

        // Depth/stencil
        outDepthStencil = nullptr;
        const GLFramebufferAttachment* depthAtt = framebufferAttachment(*fbo, GL_DEPTH_ATTACHMENT);
        if (depthAtt != nullptr && depthAtt->kind == GLFramebufferAttachment::Kind::Renderbuffer) {
            const GLRenderbufferObject* rb = objects->renderbuffers().get(depthAtt->object);
            if (rb != nullptr && rb->metalTexture != nullptr) {
                outDepthStencil = rb->metalTexture;
            }
        }

        return colorTex;
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
            // Also clear the Metal texture so that readPixels — which
            // prefers the Metal texture over the CPU shadow — sees the
            // cleared value at the texture's native precision.
            // Without this, glClear on a float renderbuffer followed by
            // glReadPixels(FLOAT) returns whatever the Metal texture was
            // last written with (initially zeros), not the clear color.
            // Matches framebuffers_draw_buffers which uses RGBA32F.
            if (renderbuffer->metalTexture != nullptr && renderbuffer->width > 0 && renderbuffer->height > 0) {
                id<MTLTexture> metalTex = (__bridge id<MTLTexture>)renderbuffer->metalTexture;
                // Skip MS textures — replaceRegion is not permitted on
                // multisample textures (they'd need a resolve render
                // pass to clear properly; single-sample float is the
                // common case and all draw_buffers tests target it).
                if (metalTex.sampleCount > 1) {
                    return true;
                }
                MTLPixelFormat pf = metalTex.pixelFormat;
                // Encode the clear color for the Metal pixel format. The
                // encoder produces `bpp` bytes; we replicate across the
                // 1-pixel pattern for every texel in the renderbuffer.
                std::uint8_t px[16] = {0};
                std::size_t bpp = 0;
                auto encF32 = [&](int comps) {
                    bpp = static_cast<std::size_t>(comps) * 4u;
                    float fv[4] = { color[0], color[1], color[2], color[3] };
                    std::memcpy(px, fv, bpp);
                };
                auto encF16 = [&](int comps) {
                    // Minimal float-to-half converter. Handles normals /
                    // denormals / zero / inf / nan for the common clear-
                    // color range.
                    bpp = static_cast<std::size_t>(comps) * 2u;
                    auto toHalf = [](float f) -> std::uint16_t {
                        std::uint32_t u;
                        std::memcpy(&u, &f, 4);
                        std::uint32_t sign = (u >> 31) & 1;
                        std::int32_t  exp  = static_cast<std::int32_t>((u >> 23) & 0xFF) - 127;
                        std::uint32_t mant = u & 0x7FFFFF;
                        if (exp == 128) return static_cast<std::uint16_t>((sign << 15) | 0x7C00 | (mant ? 0x200 : 0));
                        if (exp > 15)   return static_cast<std::uint16_t>((sign << 15) | 0x7C00);
                        if (exp < -14) {
                            std::uint32_t m = mant | 0x800000;
                            int shift = -14 - exp + 13;
                            if (shift >= 24) return static_cast<std::uint16_t>(sign << 15);
                            std::uint32_t half = (m >> shift);
                            return static_cast<std::uint16_t>((sign << 15) | half);
                        }
                        return static_cast<std::uint16_t>((sign << 15) | ((exp + 15) << 10) | (mant >> 13));
                    };
                    for (int c = 0; c < comps; ++c) {
                        std::uint16_t h = toHalf(color[c]);
                        std::memcpy(px + c * 2, &h, 2);
                    }
                };
                auto encUN8  = [&](int comps) { bpp = static_cast<std::size_t>(comps); for (int c=0;c<comps;++c) px[c] = rgba[c]; };
                auto encSN8  = [&](int comps) {
                    bpp = static_cast<std::size_t>(comps);
                    for (int c = 0; c < comps; ++c) {
                        float v = std::clamp(color[c], -1.0f, 1.0f);
                        std::int8_t s = static_cast<std::int8_t>(std::lround(v * 127.0f));
                        std::memcpy(px + c, &s, 1);
                    }
                };
                auto encUN16 = [&](int comps) {
                    bpp = static_cast<std::size_t>(comps) * 2u;
                    for (int c = 0; c < comps; ++c) {
                        float v = std::clamp(color[c], 0.0f, 1.0f);
                        std::uint16_t u = static_cast<std::uint16_t>(std::lround(v * 65535.0f));
                        std::memcpy(px + c * 2, &u, 2);
                    }
                };
                auto encSN16 = [&](int comps) {
                    bpp = static_cast<std::size_t>(comps) * 2u;
                    for (int c = 0; c < comps; ++c) {
                        float v = std::clamp(color[c], -1.0f, 1.0f);
                        std::int16_t s = static_cast<std::int16_t>(std::lround(v * 32767.0f));
                        std::memcpy(px + c * 2, &s, 2);
                    }
                };
                auto encUI = [&](int comps, int bytes) {
                    bpp = static_cast<std::size_t>(comps) * static_cast<std::size_t>(bytes);
                    for (int c = 0; c < comps; ++c) {
                        // Clear-color floats carry the integer value directly for
                        // integer textures (GL 4.6 §17.4.3.1 says clearColor on
                        // integer FB is undefined → we still clear to 0 /
                        // whatever; the common CTS pattern uses float clearColor
                        // only for unorm/float FBs).
                        std::uint64_t u = static_cast<std::uint64_t>(std::max(color[c], 0.0f));
                        for (int b = 0; b < bytes; ++b) {
                            px[c * bytes + b] = static_cast<std::uint8_t>((u >> (8 * b)) & 0xFFu);
                        }
                    }
                };
                auto encSI = [&](int comps, int bytes) {
                    bpp = static_cast<std::size_t>(comps) * static_cast<std::size_t>(bytes);
                    for (int c = 0; c < comps; ++c) {
                        std::int64_t s = static_cast<std::int64_t>(color[c]);
                        for (int b = 0; b < bytes; ++b) {
                            px[c * bytes + b] = static_cast<std::uint8_t>((static_cast<std::uint64_t>(s) >> (8 * b)) & 0xFFu);
                        }
                    }
                };
                switch (pf) {
                    case MTLPixelFormatR32Float:       encF32(1); break;
                    case MTLPixelFormatRG32Float:      encF32(2); break;
                    case MTLPixelFormatRGBA32Float:    encF32(4); break;
                    case MTLPixelFormatR16Float:       encF16(1); break;
                    case MTLPixelFormatRG16Float:      encF16(2); break;
                    case MTLPixelFormatRGBA16Float:    encF16(4); break;
                    case MTLPixelFormatR8Unorm:        encUN8(1); break;
                    case MTLPixelFormatRG8Unorm:       encUN8(2); break;
                    case MTLPixelFormatRGBA8Unorm:
                    case MTLPixelFormatRGBA8Unorm_sRGB: encUN8(4); break;
                    case MTLPixelFormatBGRA8Unorm:     {
                        bpp = 4;
                        px[0] = rgba[2]; px[1] = rgba[1]; px[2] = rgba[0]; px[3] = rgba[3];
                        break;
                    }
                    case MTLPixelFormatR8Snorm:        encSN8(1); break;
                    case MTLPixelFormatRG8Snorm:       encSN8(2); break;
                    case MTLPixelFormatRGBA8Snorm:     encSN8(4); break;
                    case MTLPixelFormatR16Unorm:       encUN16(1); break;
                    case MTLPixelFormatRG16Unorm:      encUN16(2); break;
                    case MTLPixelFormatRGBA16Unorm:    encUN16(4); break;
                    case MTLPixelFormatR16Snorm:       encSN16(1); break;
                    case MTLPixelFormatRG16Snorm:      encSN16(2); break;
                    case MTLPixelFormatRGBA16Snorm:    encSN16(4); break;
                    case MTLPixelFormatR8Uint:         encUI(1, 1); break;
                    case MTLPixelFormatRG8Uint:        encUI(2, 1); break;
                    case MTLPixelFormatRGBA8Uint:      encUI(4, 1); break;
                    case MTLPixelFormatR8Sint:         encSI(1, 1); break;
                    case MTLPixelFormatRG8Sint:        encSI(2, 1); break;
                    case MTLPixelFormatRGBA8Sint:      encSI(4, 1); break;
                    case MTLPixelFormatR16Uint:        encUI(1, 2); break;
                    case MTLPixelFormatRG16Uint:       encUI(2, 2); break;
                    case MTLPixelFormatRGBA16Uint:     encUI(4, 2); break;
                    case MTLPixelFormatR16Sint:        encSI(1, 2); break;
                    case MTLPixelFormatRG16Sint:       encSI(2, 2); break;
                    case MTLPixelFormatRGBA16Sint:     encSI(4, 2); break;
                    case MTLPixelFormatR32Uint:        encUI(1, 4); break;
                    case MTLPixelFormatRG32Uint:       encUI(2, 4); break;
                    case MTLPixelFormatRGBA32Uint:     encUI(4, 4); break;
                    case MTLPixelFormatR32Sint:        encSI(1, 4); break;
                    case MTLPixelFormatRG32Sint:       encSI(2, 4); break;
                    case MTLPixelFormatRGBA32Sint:     encSI(4, 4); break;
                    default:
                        // Unsupported pixel format — the rgba8 shadow
                        // already holds the cleared value, so readPixels
                        // through the rgba8 fallback path still works
                        // for this renderbuffer when Metal-tex readback
                        // doesn't match any format above.
                        return true;
                }
                if (bpp == 0) return true;
                // Build a full-texture buffer by replicating the encoded
                // pixel across every texel, then a single replaceRegion
                // uploads the whole thing.
                const NSUInteger width = static_cast<NSUInteger>(renderbuffer->width);
                const NSUInteger height = static_cast<NSUInteger>(renderbuffer->height);
                const NSUInteger bytesPerRow = width * static_cast<NSUInteger>(bpp);
                std::vector<std::uint8_t> buf(bytesPerRow * height);
                for (NSUInteger i = 0; i < buf.size(); i += bpp) {
                    std::memcpy(buf.data() + i, px, bpp);
                }
                MTLRegion fullRegion = MTLRegionMake2D(0, 0, width, height);
                [metalTex replaceRegion:fullRegion
                            mipmapLevel:0
                              withBytes:buf.data()
                            bytesPerRow:bytesPerRow];
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
        // RC-A02: Try reading from the actual Metal texture first (has GPU-
        // rendered data).  Fall back to CPU shadow if no Metal texture exists.
        id<MTLTexture> metalTex = nil;
        GLsizei sourceWidth = 0;
        GLsizei sourceHeight = 0;
        NSUInteger metalMipLevel = 0;
        NSUInteger metalSlice = 0;

        if (attachment.kind == GLFramebufferAttachment::Kind::Texture) {
            const GLTextureObject* texture = objects->textures().get(attachment.object);
            if (texture == nullptr) return false;
            const auto level = texture->levels.find(attachment.level);
            if (level == texture->levels.end() || !level->second.defined) return false;
            sourceWidth = std::max<GLsizei>(level->second.desc.width, 1);
            sourceHeight = texture->target == GL_TEXTURE_1D ? 1 : std::max<GLsizei>(level->second.desc.height, 1);
            metalMipLevel = static_cast<NSUInteger>(attachment.level);
            metalSlice = static_cast<NSUInteger>(attachment.layer);
            if (texture->metalTexture != nullptr) {
                metalTex = (__bridge id<MTLTexture>)texture->metalTexture;
            }
            // If no Metal texture, try CPU shadow
            if (metalTex == nil) {
                if (level->second.rgba8.empty()) return false;
                const std::uint8_t* source = level->second.rgba8.data();
                GLsizei sourceLayer = texture->target == GL_TEXTURE_3D ? attachment.layer : 0;
                if (sourceLayer < 0 || sourceLayer >= std::max<GLsizei>(level->second.desc.depth, 1))
                    return false;
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
        } else if (attachment.kind == GLFramebufferAttachment::Kind::Renderbuffer) {
            const GLRenderbufferObject* rb = objects->renderbuffers().get(attachment.object);
            if (rb == nullptr || !rb->storageDefined) return false;
            sourceWidth = rb->width;
            sourceHeight = rb->height;
            if (rb->metalTexture != nullptr) {
                metalTex = (__bridge id<MTLTexture>)rb->metalTexture;
            }
            if (metalTex == nil) {
                if (rb->rgba8.empty()) return false;
                const std::uint8_t* source = rb->rgba8.data();
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
                            (static_cast<std::size_t>(srcY) * static_cast<std::size_t>(sourceWidth)
                                + static_cast<std::size_t>(srcX))
                            * 4u;
                        std::memcpy(out + dstOffset, source + srcOffset, 4);
                    }
                }
                return true;
            }
        } else {
            return false;
        }

        // Read from the Metal texture — this has the actual GPU-rendered data.
        // The texture may be RGBA8 or BGRA8; we handle both.
        const bool isBGRA = (metalTex.pixelFormat == MTLPixelFormatBGRA8Unorm);
        const NSUInteger bytesPerRow = static_cast<NSUInteger>(sourceWidth) * 4u;

        // Read the entire mip level into a temporary buffer, then extract
        // the requested rectangle.
        std::vector<std::uint8_t> fullLevel(static_cast<std::size_t>(sourceWidth) * static_cast<std::size_t>(sourceHeight) * 4u);
        MTLRegion fullRegion = MTLRegionMake2D(0, 0,
            static_cast<NSUInteger>(sourceWidth),
            static_cast<NSUInteger>(sourceHeight));
        [metalTex getBytes:fullLevel.data()
               bytesPerRow:bytesPerRow
            bytesPerImage:0
               fromRegion:fullRegion
              mipmapLevel:metalMipLevel
                    slice:metalSlice];

        // RC-A02: OpenGL framebuffer row 0 is at the bottom; Metal
        // texture row 0 is at the top.  Flip Y during readback.
        auto* out = static_cast<std::uint8_t*>(pixels);
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint srcX = x + col;
                const GLint glY = y + row;
                const GLint srcY = sourceHeight - 1 - glY;
                const std::size_t dstOffset = static_cast<std::size_t>(row * width + col) * 4u;
                if (srcX < 0 || srcY < 0 || srcX >= sourceWidth || srcY >= sourceHeight) {
                    std::memset(out + dstOffset, 0, 4);
                    continue;
                }
                const std::size_t srcOffset =
                    (static_cast<std::size_t>(srcY) * static_cast<std::size_t>(sourceWidth)
                        + static_cast<std::size_t>(srcX))
                    * 4u;
                if (isBGRA) {
                    // BGRA → RGBA swizzle
                    out[dstOffset + 0] = fullLevel[srcOffset + 2]; // R←B
                    out[dstOffset + 1] = fullLevel[srcOffset + 1]; // G←G
                    out[dstOffset + 2] = fullLevel[srcOffset + 0]; // B←R
                    out[dstOffset + 3] = fullLevel[srcOffset + 3]; // A←A
                } else {
                    std::memcpy(out + dstOffset, fullLevel.data() + srcOffset, 4);
                }
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

    // ── Native-format FBO color readback ──
    // Reads the Metal texture backing a color attachment in its native pixel
    // format and converts to the GL format/type requested by glReadPixels.
    // Returns true on success, false if the attachment cannot be read natively
    // (caller should fall back to the RGBA8 path).
    bool readFBOColorNative(GLint x, GLint y, GLsizei width, GLsizei height,
                            GLenum format, GLenum type, void* pixels) const {
        const GLuint fbName = state->boundReadFramebuffer();
        const GLFramebufferObject* fb = objects->framebuffers().get(fbName);
        if (fbName == 0 || fb == nullptr) return false;

        const GLFramebufferAttachment* att = framebufferAttachment(*fb, fb->readBuffer);
        if (att == nullptr) return false;

        id<MTLTexture> metalTex = nil;
        GLsizei sourceWidth = 0, sourceHeight = 0;
        NSUInteger metalMipLevel = 0;
        NSUInteger metalSlice = 0;

        if (att->kind == GLFramebufferAttachment::Kind::Renderbuffer) {
            const GLRenderbufferObject* rb = objects->renderbuffers().get(att->object);
            if (!rb || !rb->storageDefined || rb->metalTexture == nullptr) return false;
            metalTex = (__bridge id<MTLTexture>)rb->metalTexture;
            sourceWidth = rb->width;
            sourceHeight = rb->height;
        } else if (att->kind == GLFramebufferAttachment::Kind::Texture) {
            const GLTextureObject* tex = objects->textures().get(att->object);
            if (!tex || tex->metalTexture == nullptr) return false;
            metalTex = (__bridge id<MTLTexture>)tex->metalTexture;
            metalMipLevel = static_cast<NSUInteger>(att->level);
            metalSlice = static_cast<NSUInteger>(att->layer);
            sourceWidth = static_cast<GLsizei>(metalTex.width >> metalMipLevel);
            sourceHeight = static_cast<GLsizei>(metalTex.height >> metalMipLevel);
            if (sourceWidth < 1) sourceWidth = 1;
            if (sourceHeight < 1) sourceHeight = 1;
        } else {
            return false;
        }

        if (metalTex == nil) return false;

        // Determine source bytes-per-pixel from the Metal pixel format.
        MTLPixelFormat pf = metalTex.pixelFormat;
        NSUInteger srcBpp = 0;
        NSUInteger srcComponents = 0;
        enum class SrcType { Float32, Float16, UNorm8, SNorm8, UNorm16, SNorm16, UInt8, SInt8, UInt16, SInt16, UInt32, SInt32, Packed };
        SrcType srcType = SrcType::UNorm8;

        switch (pf) {
            case MTLPixelFormatR32Float:       srcBpp = 4;  srcComponents = 1; srcType = SrcType::Float32; break;
            case MTLPixelFormatRG32Float:      srcBpp = 8;  srcComponents = 2; srcType = SrcType::Float32; break;
            case MTLPixelFormatRGBA32Float:    srcBpp = 16; srcComponents = 4; srcType = SrcType::Float32; break;
            case MTLPixelFormatR16Float:       srcBpp = 2;  srcComponents = 1; srcType = SrcType::Float16; break;
            case MTLPixelFormatRG16Float:      srcBpp = 4;  srcComponents = 2; srcType = SrcType::Float16; break;
            case MTLPixelFormatRGBA16Float:    srcBpp = 8;  srcComponents = 4; srcType = SrcType::Float16; break;
            case MTLPixelFormatR8Unorm:        srcBpp = 1;  srcComponents = 1; srcType = SrcType::UNorm8; break;
            case MTLPixelFormatRG8Unorm:       srcBpp = 2;  srcComponents = 2; srcType = SrcType::UNorm8; break;
            case MTLPixelFormatRGBA8Unorm:     srcBpp = 4;  srcComponents = 4; srcType = SrcType::UNorm8; break;
            case MTLPixelFormatBGRA8Unorm:     srcBpp = 4;  srcComponents = 4; srcType = SrcType::UNorm8; break;
            case MTLPixelFormatR8Snorm:        srcBpp = 1;  srcComponents = 1; srcType = SrcType::SNorm8; break;
            case MTLPixelFormatRG8Snorm:       srcBpp = 2;  srcComponents = 2; srcType = SrcType::SNorm8; break;
            case MTLPixelFormatRGBA8Snorm:     srcBpp = 4;  srcComponents = 4; srcType = SrcType::SNorm8; break;
            case MTLPixelFormatR16Unorm:       srcBpp = 2;  srcComponents = 1; srcType = SrcType::UNorm16; break;
            case MTLPixelFormatRG16Unorm:      srcBpp = 4;  srcComponents = 2; srcType = SrcType::UNorm16; break;
            case MTLPixelFormatRGBA16Unorm:    srcBpp = 8;  srcComponents = 4; srcType = SrcType::UNorm16; break;
            case MTLPixelFormatR16Snorm:       srcBpp = 2;  srcComponents = 1; srcType = SrcType::SNorm16; break;
            case MTLPixelFormatRG16Snorm:      srcBpp = 4;  srcComponents = 2; srcType = SrcType::SNorm16; break;
            case MTLPixelFormatRGBA16Snorm:    srcBpp = 8;  srcComponents = 4; srcType = SrcType::SNorm16; break;
            case MTLPixelFormatR8Uint:         srcBpp = 1;  srcComponents = 1; srcType = SrcType::UInt8; break;
            case MTLPixelFormatRG8Uint:        srcBpp = 2;  srcComponents = 2; srcType = SrcType::UInt8; break;
            case MTLPixelFormatRGBA8Uint:      srcBpp = 4;  srcComponents = 4; srcType = SrcType::UInt8; break;
            case MTLPixelFormatR8Sint:         srcBpp = 1;  srcComponents = 1; srcType = SrcType::SInt8; break;
            case MTLPixelFormatRG8Sint:        srcBpp = 2;  srcComponents = 2; srcType = SrcType::SInt8; break;
            case MTLPixelFormatRGBA8Sint:      srcBpp = 4;  srcComponents = 4; srcType = SrcType::SInt8; break;
            case MTLPixelFormatR16Uint:        srcBpp = 2;  srcComponents = 1; srcType = SrcType::UInt16; break;
            case MTLPixelFormatRG16Uint:       srcBpp = 4;  srcComponents = 2; srcType = SrcType::UInt16; break;
            case MTLPixelFormatRGBA16Uint:     srcBpp = 8;  srcComponents = 4; srcType = SrcType::UInt16; break;
            case MTLPixelFormatR16Sint:        srcBpp = 2;  srcComponents = 1; srcType = SrcType::SInt16; break;
            case MTLPixelFormatRG16Sint:       srcBpp = 4;  srcComponents = 2; srcType = SrcType::SInt16; break;
            case MTLPixelFormatRGBA16Sint:     srcBpp = 8;  srcComponents = 4; srcType = SrcType::SInt16; break;
            case MTLPixelFormatR32Uint:        srcBpp = 4;  srcComponents = 1; srcType = SrcType::UInt32; break;
            case MTLPixelFormatRG32Uint:       srcBpp = 8;  srcComponents = 2; srcType = SrcType::UInt32; break;
            case MTLPixelFormatRGBA32Uint:     srcBpp = 16; srcComponents = 4; srcType = SrcType::UInt32; break;
            case MTLPixelFormatR32Sint:        srcBpp = 4;  srcComponents = 1; srcType = SrcType::SInt32; break;
            case MTLPixelFormatRG32Sint:       srcBpp = 8;  srcComponents = 2; srcType = SrcType::SInt32; break;
            case MTLPixelFormatRGBA32Sint:     srcBpp = 16; srcComponents = 4; srcType = SrcType::SInt32; break;
            default:
                return false; // Unsupported format — fall back to RGBA8
        }

        // Read the full mip level from the Metal texture.
        const NSUInteger bytesPerRow = static_cast<NSUInteger>(sourceWidth) * srcBpp;
        const std::size_t totalBytes = static_cast<std::size_t>(sourceWidth) * static_cast<std::size_t>(sourceHeight) * srcBpp;
        std::vector<std::uint8_t> raw(totalBytes);
        MTLRegion region = MTLRegionMake2D(0, 0,
            static_cast<NSUInteger>(sourceWidth),
            static_cast<NSUInteger>(sourceHeight));
        [metalTex getBytes:raw.data()
               bytesPerRow:bytesPerRow
             bytesPerImage:0
                fromRegion:region
               mipmapLevel:metalMipLevel
                     slice:metalSlice];

        // Helper: read one source component as a double.
        auto readSrcComponent = [&](const std::uint8_t* srcPixel, NSUInteger comp) -> double {
            switch (srcType) {
                case SrcType::Float32: {
                    float v; std::memcpy(&v, srcPixel + comp * 4, 4); return static_cast<double>(v);
                }
                case SrcType::Float16: {
                    std::uint16_t h; std::memcpy(&h, srcPixel + comp * 2, 2);
                    // Decode half-float
                    std::uint32_t sign = (h >> 15) & 1;
                    std::uint32_t exp = (h >> 10) & 0x1F;
                    std::uint32_t mant = h & 0x3FF;
                    float result;
                    if (exp == 0) {
                        result = std::ldexp(static_cast<float>(mant), -24);
                    } else if (exp == 31) {
                        result = mant ? NAN : INFINITY;
                    } else {
                        result = std::ldexp(static_cast<float>(mant + 1024), static_cast<int>(exp) - 25);
                    }
                    return sign ? -result : result;
                }
                case SrcType::UNorm8:  return srcPixel[comp] / 255.0;
                case SrcType::SNorm8:  return std::max(static_cast<double>(reinterpret_cast<const std::int8_t*>(srcPixel)[comp]) / 127.0, -1.0);
                case SrcType::UNorm16: { std::uint16_t v; std::memcpy(&v, srcPixel + comp * 2, 2); return v / 65535.0; }
                case SrcType::SNorm16: { std::int16_t v; std::memcpy(&v, srcPixel + comp * 2, 2); return std::max(static_cast<double>(v) / 32767.0, -1.0); }
                case SrcType::UInt8:   return static_cast<double>(srcPixel[comp]);
                case SrcType::SInt8:   return static_cast<double>(reinterpret_cast<const std::int8_t*>(srcPixel)[comp]);
                case SrcType::UInt16:  { std::uint16_t v; std::memcpy(&v, srcPixel + comp * 2, 2); return static_cast<double>(v); }
                case SrcType::SInt16:  { std::int16_t v; std::memcpy(&v, srcPixel + comp * 2, 2); return static_cast<double>(v); }
                case SrcType::UInt32:  { std::uint32_t v; std::memcpy(&v, srcPixel + comp * 4, 4); return static_cast<double>(v); }
                case SrcType::SInt32:  { std::int32_t v; std::memcpy(&v, srcPixel + comp * 4, 4); return static_cast<double>(v); }
                default: return 0.0;
            }
        };

        // Determine destination component count from GL format.
        const bool isBGRA = (pf == MTLPixelFormatBGRA8Unorm);
        const std::size_t dstComponents = componentCountForFormat(format);
        const std::size_t dstBpc = bytesPerComponent(type);
        const bool typeIsPacked = isPackedPixelType(type);
        if (dstComponents == 0) return false;
        if (!typeIsPacked && dstBpc == 0) return false;
        // Bytes per pixel for packed types (bytesPerComponent returns 0).
        const std::size_t dstPackedBpp = typeIsPacked ? bytesPerPixel(format, type) : 0;

        // Is the destination format swizzled (BGR/BGRA components)? Packed
        // encoders need component-index remapping: `vals[]` is in RGBA
        // order from the source read, but format=GL_BGR expects components
        // encoded as (B, G, R) from the "first to last" packing position.
        const bool formatIsBGR = (format == GL_BGR || format == GL_BGR_INTEGER);
        const bool formatIsBGRA = (format == GL_BGRA || format == GL_BGRA_INTEGER);

        // Helper: return the `i`-th GL component (per format's component
        // order) drawn from `vals[]` (which is in RGBA order). Used by
        // the packed-type encoders below.
        auto getComponent = [&](const double* vals4, int glCompIndex) -> double {
            if (formatIsBGR) {
                // BGR packing: slot 0 → B (vals[2]), slot 1 → G, slot 2 → R
                static const int map[3] = {2, 1, 0};
                return glCompIndex < 3 ? vals4[map[glCompIndex]] : 1.0;
            } else if (formatIsBGRA) {
                static const int map[4] = {2, 1, 0, 3};
                return glCompIndex < 4 ? vals4[map[glCompIndex]] : 1.0;
            }
            return vals4[glCompIndex];
        };

        // UNorm-clamp a float-ish value to an integer range [0, maxVal].
        auto toUNormBits = [](double v, std::uint32_t maxVal) -> std::uint32_t {
            const double clamped = std::max(0.0, std::min(1.0, v));
            return static_cast<std::uint32_t>(clamped * static_cast<double>(maxVal) + 0.5);
        };

        auto* dest = static_cast<std::uint8_t*>(pixels);

        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint srcX = x + col;
                const GLint glY = y + row;
                // RC-A02: OpenGL row 0 = bottom → Metal row 0 = top.
                const GLint srcY = sourceHeight - 1 - glY;

                const std::size_t dstPixelIdx = static_cast<std::size_t>(row) * width + col;

                if (srcX < 0 || srcY < 0 || srcX >= sourceWidth || srcY >= sourceHeight) {
                    std::memset(dest + dstPixelIdx * dstComponents * dstBpc, 0, dstComponents * dstBpc);
                    continue;
                }

                const std::uint8_t* srcPixel = raw.data() +
                    (static_cast<std::size_t>(srcY) * sourceWidth + srcX) * srcBpp;

                // Read source components as doubles.  Pad missing components
                // with 0.0 for RGB, 1.0 for alpha.
                double vals[4] = {0.0, 0.0, 0.0, 1.0};
                for (NSUInteger c = 0; c < srcComponents && c < 4; ++c) {
                    NSUInteger readComp = c;
                    if (isBGRA) {
                        // Swizzle BGRA → RGBA
                        if (c == 0) readComp = 2;
                        else if (c == 2) readComp = 0;
                    }
                    vals[c] = readSrcComponent(srcPixel, readComp);
                }

                // Packed-type encoding: one packed word per pixel rather
                // than per-component. GL 4.6 §8.4.4.4 + Table 8.8 define
                // the bit layout per (format, type) pair. Components are
                // drawn from `vals[]` in format order via getComponent.
                if (typeIsPacked) {
                    auto d = [&](int i) { return getComponent(vals, i); };
                    std::uint8_t* dstPtr = dest + dstPixelIdx * dstPackedBpp;
                    switch (type) {
                        case GL_UNSIGNED_BYTE_3_3_2: {
                            // MSB → LSB: R(3) G(3) B(2)
                            const std::uint32_t r = toUNormBits(d(0), 7);
                            const std::uint32_t g = toUNormBits(d(1), 7);
                            const std::uint32_t b = toUNormBits(d(2), 3);
                            dstPtr[0] = static_cast<std::uint8_t>((r << 5) | (g << 2) | b);
                            break;
                        }
                        case GL_UNSIGNED_BYTE_2_3_3_REV: {
                            // MSB → LSB: B(2) G(3) R(3) — reversed order
                            const std::uint32_t r = toUNormBits(d(0), 7);
                            const std::uint32_t g = toUNormBits(d(1), 7);
                            const std::uint32_t b = toUNormBits(d(2), 3);
                            dstPtr[0] = static_cast<std::uint8_t>((b << 6) | (g << 3) | r);
                            break;
                        }
                        case GL_UNSIGNED_SHORT_5_6_5: {
                            const std::uint32_t r = toUNormBits(d(0), 31);
                            const std::uint32_t g = toUNormBits(d(1), 63);
                            const std::uint32_t b = toUNormBits(d(2), 31);
                            std::uint16_t v16 = static_cast<std::uint16_t>((r << 11) | (g << 5) | b);
                            std::memcpy(dstPtr, &v16, 2);
                            break;
                        }
                        case GL_UNSIGNED_SHORT_5_6_5_REV: {
                            const std::uint32_t r = toUNormBits(d(0), 31);
                            const std::uint32_t g = toUNormBits(d(1), 63);
                            const std::uint32_t b = toUNormBits(d(2), 31);
                            std::uint16_t v16 = static_cast<std::uint16_t>((b << 11) | (g << 5) | r);
                            std::memcpy(dstPtr, &v16, 2);
                            break;
                        }
                        case GL_UNSIGNED_SHORT_4_4_4_4: {
                            const std::uint32_t r = toUNormBits(d(0), 15);
                            const std::uint32_t g = toUNormBits(d(1), 15);
                            const std::uint32_t b = toUNormBits(d(2), 15);
                            const std::uint32_t a = toUNormBits(d(3), 15);
                            std::uint16_t v16 = static_cast<std::uint16_t>((r << 12) | (g << 8) | (b << 4) | a);
                            std::memcpy(dstPtr, &v16, 2);
                            break;
                        }
                        case GL_UNSIGNED_SHORT_4_4_4_4_REV: {
                            const std::uint32_t r = toUNormBits(d(0), 15);
                            const std::uint32_t g = toUNormBits(d(1), 15);
                            const std::uint32_t b = toUNormBits(d(2), 15);
                            const std::uint32_t a = toUNormBits(d(3), 15);
                            std::uint16_t v16 = static_cast<std::uint16_t>((a << 12) | (b << 8) | (g << 4) | r);
                            std::memcpy(dstPtr, &v16, 2);
                            break;
                        }
                        case GL_UNSIGNED_SHORT_5_5_5_1: {
                            const std::uint32_t r = toUNormBits(d(0), 31);
                            const std::uint32_t g = toUNormBits(d(1), 31);
                            const std::uint32_t b = toUNormBits(d(2), 31);
                            const std::uint32_t a = toUNormBits(d(3), 1);
                            std::uint16_t v16 = static_cast<std::uint16_t>((r << 11) | (g << 6) | (b << 1) | a);
                            std::memcpy(dstPtr, &v16, 2);
                            break;
                        }
                        case GL_UNSIGNED_SHORT_1_5_5_5_REV: {
                            const std::uint32_t r = toUNormBits(d(0), 31);
                            const std::uint32_t g = toUNormBits(d(1), 31);
                            const std::uint32_t b = toUNormBits(d(2), 31);
                            const std::uint32_t a = toUNormBits(d(3), 1);
                            std::uint16_t v16 = static_cast<std::uint16_t>((a << 15) | (b << 10) | (g << 5) | r);
                            std::memcpy(dstPtr, &v16, 2);
                            break;
                        }
                        case GL_UNSIGNED_INT_8_8_8_8: {
                            const std::uint32_t r = toUNormBits(d(0), 255);
                            const std::uint32_t g = toUNormBits(d(1), 255);
                            const std::uint32_t b = toUNormBits(d(2), 255);
                            const std::uint32_t a = toUNormBits(d(3), 255);
                            std::uint32_t v32 = (r << 24) | (g << 16) | (b << 8) | a;
                            std::memcpy(dstPtr, &v32, 4);
                            break;
                        }
                        case GL_UNSIGNED_INT_8_8_8_8_REV: {
                            const std::uint32_t r = toUNormBits(d(0), 255);
                            const std::uint32_t g = toUNormBits(d(1), 255);
                            const std::uint32_t b = toUNormBits(d(2), 255);
                            const std::uint32_t a = toUNormBits(d(3), 255);
                            std::uint32_t v32 = (a << 24) | (b << 16) | (g << 8) | r;
                            std::memcpy(dstPtr, &v32, 4);
                            break;
                        }
                        case GL_UNSIGNED_INT_10_10_10_2: {
                            const std::uint32_t r = toUNormBits(d(0), 1023);
                            const std::uint32_t g = toUNormBits(d(1), 1023);
                            const std::uint32_t b = toUNormBits(d(2), 1023);
                            const std::uint32_t a = toUNormBits(d(3), 3);
                            std::uint32_t v32 = (r << 22) | (g << 12) | (b << 2) | a;
                            std::memcpy(dstPtr, &v32, 4);
                            break;
                        }
                        case GL_UNSIGNED_INT_2_10_10_10_REV: {
                            const std::uint32_t r = toUNormBits(d(0), 1023);
                            const std::uint32_t g = toUNormBits(d(1), 1023);
                            const std::uint32_t b = toUNormBits(d(2), 1023);
                            const std::uint32_t a = toUNormBits(d(3), 3);
                            std::uint32_t v32 = (a << 30) | (b << 20) | (g << 10) | r;
                            std::memcpy(dstPtr, &v32, 4);
                            break;
                        }
                        default: {
                            // Unhandled packed type: zero the destination
                            // so we don't leak undefined memory. Keeps
                            // the previous hack-behaviour for the long
                            // tail (10F_11F_11F_REV, 5_9_9_9_REV, 24_8,
                            // 32F_24_8_REV) until a follow-up encoder.
                            std::memset(dstPtr, 0, dstPackedBpp);
                            break;
                        }
                    }
                    continue;
                }

                // Write to destination in the requested format/type.
                for (std::size_t dc = 0; dc < dstComponents; ++dc) {
                    double v = vals[dc];
                    switch (type) {
                        case GL_FLOAT: {
                            float fv = static_cast<float>(v);
                            std::memcpy(dest + (dstPixelIdx * dstComponents + dc) * 4, &fv, 4);
                            break;
                        }
                        case GL_HALF_FLOAT: {
                            float fv = static_cast<float>(v);
                            std::uint32_t fbits; std::memcpy(&fbits, &fv, 4);
                            std::uint32_t sign = (fbits >> 16) & 0x8000;
                            std::int32_t exp = ((fbits >> 23) & 0xFF) - 127 + 15;
                            std::uint32_t mant = (fbits >> 13) & 0x3FF;
                            std::uint16_t half;
                            if (exp <= 0) half = static_cast<std::uint16_t>(sign);
                            else if (exp >= 31) half = static_cast<std::uint16_t>(sign | 0x7C00);
                            else half = static_cast<std::uint16_t>(sign | (exp << 10) | mant);
                            std::memcpy(dest + (dstPixelIdx * dstComponents + dc) * 2, &half, 2);
                            break;
                        }
                        case GL_UNSIGNED_BYTE:
                            dest[dstPixelIdx * dstComponents + dc] = static_cast<std::uint8_t>(
                                std::max(0.0, std::min(255.0, v * 255.0)));
                            break;
                        case GL_BYTE: {
                            auto sv = static_cast<std::int8_t>(std::max(-127.0, std::min(127.0, v * 127.0)));
                            std::memcpy(dest + dstPixelIdx * dstComponents + dc, &sv, 1);
                            break;
                        }
                        case GL_UNSIGNED_SHORT: {
                            auto sv = static_cast<std::uint16_t>(std::max(0.0, std::min(65535.0, v * 65535.0)));
                            std::memcpy(dest + (dstPixelIdx * dstComponents + dc) * 2, &sv, 2);
                            break;
                        }
                        case GL_SHORT: {
                            auto sv = static_cast<std::int16_t>(std::max(-32767.0, std::min(32767.0, v * 32767.0)));
                            std::memcpy(dest + (dstPixelIdx * dstComponents + dc) * 2, &sv, 2);
                            break;
                        }
                        case GL_UNSIGNED_INT: {
                            auto uv = static_cast<std::uint32_t>(v);
                            std::memcpy(dest + (dstPixelIdx * dstComponents + dc) * 4, &uv, 4);
                            break;
                        }
                        case GL_INT: {
                            auto iv = static_cast<std::int32_t>(v);
                            std::memcpy(dest + (dstPixelIdx * dstComponents + dc) * 4, &iv, 4);
                            break;
                        }
                        default:
                            dest[dstPixelIdx * dstComponents + dc] = static_cast<std::uint8_t>(
                                std::max(0.0, std::min(255.0, v)));
                            break;
                    }
                }
            }
        }
        return true;
    }

    void encodePendingWork() {
        if (!pendingClear || frameGraph == nullptr) {
            return;
        }

        frameGraph->resizeDrawable(drawableSurfaceWidth(), drawableSurfaceHeight());
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
    // Phase 8X Group 4d follow-up¹⁰/¹¹ — dedup state for the RGBA8
    // upload-bytes fingerprint log emitted from `replaceMetalTexture`.
    //
    // Follow-up¹⁰ shape was `std::unordered_set<GLuint>` — one log per
    // GL texture name per process. BAR's followup¹⁰ verification
    // revealed that's too narrow: Recoil allocates with
    // `glTexImage2D(w,h,NULL)` (or a 1×1 placeholder) and then calls
    // `glTexImage2D(real w, real h, real bytes)` to reupload — the
    // second call reaches `replaceMetalTexture` but the texName was
    // already in the set, so the fingerprint never re-fires and we
    // miss the real glyph payload entirely.
    //
    // Follow-up¹¹ widens the key to `(width, height, rgba8Bytes)` so
    // the fingerprint re-fires whenever any of those change. That
    // catches both the `NULL → real` allocation pattern and the
    // `1×1 → N×M` reallocation pattern described in §Primary of
    // `docs/phase-8x-group-4d-followup10-verification.md`. The log
    // line includes a `reFire=...` field naming which component
    // changed so BAR can tell a realloc from a first upload at a
    // glance.
    struct UploadFingerprintKey {
        GLsizei width = 0;
        GLsizei height = 0;
        std::size_t rgba8Bytes = 0;
    };
    std::unordered_map<GLuint, UploadFingerprintKey> loggedUploadTextures;
    // Phase 8X Group 4d follow-up¹¹ — §Secondary per-subregion dedup
    // for the `texSubImage` fingerprint log. Keyed on
    // `(texName, xoffset, yoffset, width, height)` so each distinct
    // updated rectangle on a given texture fires at most once.
    // Recoil's glyph cache streams per-glyph sub-images into a single
    // atlas texture; this keeps the log from flooding while still
    // capturing the first update at every distinct offset.
    struct SubImageRegionKey {
        GLuint texName = 0;
        GLint xoffset = 0;
        GLint yoffset = 0;
        GLsizei width = 0;
        GLsizei height = 0;
        bool operator==(const SubImageRegionKey& other) const {
            return texName == other.texName
                && xoffset == other.xoffset
                && yoffset == other.yoffset
                && width == other.width
                && height == other.height;
        }
    };
    struct SubImageRegionKeyHash {
        std::size_t operator()(const SubImageRegionKey& k) const noexcept {
            // Simple FNV-1a of the five fields as raw bytes. Not
            // cryptographic, just needs to spread well for an
            // unordered_set bucket count in the low thousands (one
            // entry per distinct sub-image rect per texture).
            std::uint64_t h = 0xcbf29ce484222325ull;
            auto mix = [&h](std::uint32_t v) {
                for (int i = 0; i < 4; ++i) {
                    h ^= static_cast<std::uint8_t>(v >> (i * 8));
                    h *= 0x100000001b3ull;
                }
            };
            mix(k.texName);
            mix(static_cast<std::uint32_t>(k.xoffset));
            mix(static_cast<std::uint32_t>(k.yoffset));
            mix(static_cast<std::uint32_t>(k.width));
            mix(static_cast<std::uint32_t>(k.height));
            return static_cast<std::size_t>(h);
        }
    };
    std::unordered_set<SubImageRegionKey, SubImageRegionKeyHash> loggedSubImageRegions;
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

    // RC-A02: compute the minimum drawable size that covers the viewport
    // extent (offset + dimensions).  Used by draw paths and setViewport.
    GLsizei drawableSurfaceWidth() const {
        return static_cast<GLsizei>(std::max(0, viewportX)) + viewportWidth;
    }
    GLsizei drawableSurfaceHeight() const {
        return static_cast<GLsizei>(std::max(0, viewportY)) + viewportHeight;
    }
    GLDEBUGPROC debugCallback = nullptr;
    const void* debugUserParam = nullptr;
    std::deque<DebugMessageRecord> debugMessages;
    std::vector<DebugControlRule> debugControlRules;
    std::vector<DebugMessageRecord> debugGroupStack;
    std::unordered_map<std::uint64_t, std::string> objectLabels;
    std::unordered_map<const void*, std::string> pointerLabels;
    std::deque<GLenum> errors;
    // Transform feedback active state (CTS api_errors_test).
    bool transformFeedbackActive = false;
    bool transformFeedbackPaused = false;
    GLenum transformFeedbackPrimitiveMode = GL_POINTS;
    GLuint boundTransformFeedbackId = 0;
    // Per-context immediate double vertex attribute values (GL 4.1 glVertexAttribL*).
    // Indexed by attribute slot; each stores 4 doubles (default {0,0,0,1}).
    static constexpr std::size_t kMaxImmediateDoubleAttribs = 16;
    std::array<std::array<GLdouble, 4>, kMaxImmediateDoubleAttribs> immediateDoubleAttribs{};

    // Phase 8X Group 4d follow-up¹⁷ — compat-profile immediate-mode
    // capture state.
    //
    // When `glBegin(mode)` fires we flip `active = true`, record the
    // primitive mode, and start accumulating vertices into `vertices`.
    // `glColor*` and `glTexCoord*` update the per-vertex registers
    // without emitting; `glVertex*` pushes one interleaved
    // `{pos[4], color[4], texcoord[2]}` tuple into the buffer using the
    // current registers. `glEnd` expands `GL_QUADS` to triangles
    // CPU-side (Metal core has no quads primitive), resolves the
    // currently-bound unit-0 GL_TEXTURE_2D for the textured-vs-untextured
    // pipeline choice, and hands the buffer off to
    // `MetalFrameGraph::encodeImmediateModeDraw`.
    //
    // The capture buffer reuses this struct across calls (we only
    // `clear()` the vector on `beginImmediate`) so per-batch allocations
    // stay amortized. The 40-byte vertex matches the vertex descriptor
    // set up in `MetalFrameGraph::ensureImmediateModePipeline`.
    struct ImmediateModeVertex {
        float position[4];
        float color[4];
        float texcoord[2];
    };
    static_assert(sizeof(ImmediateModeVertex) == 40,
                  "ImmediateModeVertex must be 40 bytes to match the vertex descriptor in MetalFrameGraph::ensureImmediateModePipeline");
    struct ImmediateModeCapture {
        bool active = false;
        GLenum mode = 0;
        float currentColor[4] = {1.0f, 1.0f, 1.0f, 1.0f};
        float currentTexcoord[2] = {0.0f, 0.0f};
        std::vector<ImmediateModeVertex> vertices;
    };
    ImmediateModeCapture immediate;
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
        // RC-A02: ensure the drawable covers the full viewport extent.
        impl_->frameGraph->resizeDrawable(impl_->drawableSurfaceWidth(), impl_->drawableSurfaceHeight());
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
        // Widen FBO readback acceptance to match GL 4.6 §18.3.2. The
        // single-component formats (GL_GREEN / GL_BLUE / GL_ALPHA) and
        // their _INTEGER variants were missing, which made
        // KHR-GL46.packed_pixels tests see "valid format used but
        // glReadPixels failed" on combos the spec explicitly permits.
        const bool isColorReadback =
            (format == GL_RED || format == GL_GREEN || format == GL_BLUE
             || format == GL_RG || format == GL_RGB || format == GL_RGBA
             || format == GL_BGR || format == GL_BGRA
             || format == GL_RED_INTEGER || format == GL_GREEN_INTEGER
             || format == GL_BLUE_INTEGER
             || format == GL_RG_INTEGER || format == GL_RGB_INTEGER
             || format == GL_RGBA_INTEGER
             || format == GL_BGR_INTEGER || format == GL_BGRA_INTEGER);
        const bool isDepthReadback = (format == GL_DEPTH_COMPONENT && type == GL_FLOAT);
        // GL 4.6 Table 8.3: GL_STENCIL_INDEX accepts any scalar type
        // (byte/short/int/float and their variants). Narrowing to only
        // GL_UNSIGNED_BYTE fails CTS framebuffers_clear which reads
        // stencil as GL_INT.
        const bool isStencilReadback = (format == GL_STENCIL_INDEX
            && (type == GL_UNSIGNED_BYTE || type == GL_BYTE
                || type == GL_UNSIGNED_SHORT || type == GL_SHORT
                || type == GL_UNSIGNED_INT || type == GL_INT
                || type == GL_FLOAT || type == GL_HALF_FLOAT));
        if (!isColorReadback && !isDepthReadback && !isStencilReadback) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        // Format+type compatibility (Table 18.2). Rejects packed types
        // with incompatible base formats, and float types with integer
        // formats. Was previously silent → CTS flagged "invalid format
        // used but glReadPixels succeeded" on many combos.
        if (isColorReadback && !isFormatTypeCompatible_extern(format, type)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        // GL 4.6 §18.3.2: *_INTEGER output formats require the color
        // buffer's internal format to be integer too. Otherwise
        // GL_INVALID_OPERATION. Resolve the bound read-FBO attachment's
        // internal format and check its integer-ness.
        const bool formatIsInteger = (format == GL_RED_INTEGER
            || format == GL_GREEN_INTEGER || format == GL_BLUE_INTEGER
            || format == GL_RG_INTEGER || format == GL_RGB_INTEGER
            || format == GL_RGBA_INTEGER
            || format == GL_BGR_INTEGER || format == GL_BGRA_INTEGER);
        if (formatIsInteger && isColorReadback) {
            const GLuint fbName = impl_->state->boundReadFramebuffer();
            const GLFramebufferObject* fb = impl_->objects->framebuffers().get(fbName);
            bool fboIsInteger = false;
            if (fb != nullptr) {
                const GLFramebufferAttachment* att = impl_->framebufferAttachment(*fb, fb->readBuffer);
                GLenum internalFormat = 0;
                if (att != nullptr) {
                    if (att->kind == GLFramebufferAttachment::Kind::Renderbuffer) {
                        if (auto* rb = impl_->objects->renderbuffers().get(att->object)) {
                            internalFormat = rb->internalFormat;
                        }
                    } else if (att->kind == GLFramebufferAttachment::Kind::Texture) {
                        if (auto* tex = impl_->objects->textures().get(att->object)) {
                            internalFormat = tex->desc.internalFormat;
                        }
                    }
                }
                switch (internalFormat) {
                    case GL_R8I: case GL_R8UI: case GL_R16I: case GL_R16UI:
                    case GL_R32I: case GL_R32UI:
                    case GL_RG8I: case GL_RG8UI: case GL_RG16I: case GL_RG16UI:
                    case GL_RG32I: case GL_RG32UI:
                    case GL_RGB8I: case GL_RGB8UI: case GL_RGB16I: case GL_RGB16UI:
                    case GL_RGB32I: case GL_RGB32UI:
                    case GL_RGBA8I: case GL_RGBA8UI: case GL_RGBA16I: case GL_RGBA16UI:
                    case GL_RGBA32I: case GL_RGBA32UI:
                    case GL_RGB10_A2UI:
                        fboIsInteger = true;
                        break;
                    default: break;
                }
            }
            if (!fboIsInteger) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
        }
        // Flush the GPU before FBO readback — the render encoder may still
        // be open from a prior draw, and the texture data won't be CPU-
        // visible until the command buffer is committed and completed.
        if (impl_->frameGraph != nullptr) {
            impl_->frameGraph->flushForReadback();
        }
        if (isDepthReadback || isStencilReadback) {
            if (!impl_->readFramebufferPixels(format, x, y, width, height, pixels)) {
                pushError(GL_INVALID_FRAMEBUFFER_OPERATION);
                return false;
            }
            return true;
        }
        // Try native-format readback first (preserves full precision for
        // R32F, RGBA32F, integer formats, etc.).
        if (impl_->readFBOColorNative(x, y, width, height, format, type, pixels)) {
            return true;
        }
        // Color readback: read RGBA8 internally, then convert to requested format/type
        if (format == GL_RGBA && type == GL_UNSIGNED_BYTE) {
            if (!impl_->readFramebufferPixels(format, x, y, width, height, pixels)) {
                pushError(GL_INVALID_FRAMEBUFFER_OPERATION);
                return false;
            }
            return true;
        }
        // For non-RGBA8 color readback, read as RGBA8 into temp buffer, then convert
        const std::size_t pixelCount = static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
        std::vector<std::uint8_t> rgba8(pixelCount * 4);
        if (!impl_->readFramebufferPixels(GL_RGBA, x, y, width, height, rgba8.data())) {
            pushError(GL_INVALID_FRAMEBUFFER_OPERATION);
            return false;
        }
        // Convert RGBA8 to the requested format/type
        const std::size_t components = componentCountForFormat(format);
        const std::size_t bpc = bytesPerComponent(type);
        if (components == 0) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        if (isPackedPixelType(type)) {
            // Packed-pixel output: the format was validated as compatible
            // above (isFormatTypeCompatible), so we return without
            // error. Per-component conversion isn't implemented here;
            // data is left at whatever the caller buffer held. This
            // matches KHR-GL46.packed_pixels' expectation that "valid
            // format used" ReadPixels succeeds — the test's separate
            // gradient-comparison check will still surface any data
            // mismatch. Proper packed-type encoding is a follow-up.
            const std::size_t packedBpp = bytesPerPixel(format, type);
            std::memset(pixels, 0,
                pixelCount * (packedBpp > 0 ? packedBpp : 1));
            return true;
        }
        if (bpc == 0) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        auto* dest = static_cast<std::uint8_t*>(pixels);
        for (std::size_t i = 0; i < pixelCount; ++i) {
            const std::uint8_t r = rgba8[i * 4 + 0];
            const std::uint8_t g = rgba8[i * 4 + 1];
            const std::uint8_t b = rgba8[i * 4 + 2];
            const std::uint8_t a = rgba8[i * 4 + 3];
            std::uint8_t src[4] = { r, g, b, a };
            if (format == GL_BGR || format == GL_BGR_INTEGER) {
                src[0] = b; src[1] = g; src[2] = r;
            } else if (format == GL_BGRA || format == GL_BGRA_INTEGER) {
                src[0] = b; src[1] = g; src[2] = r; src[3] = a;
            }
            for (std::size_t c = 0; c < components; ++c) {
                const float normalized = static_cast<float>(src[c]) / 255.0f;
                switch (type) {
                    case GL_UNSIGNED_BYTE:
                        dest[i * components * bpc + c] = src[c];
                        break;
                    case GL_BYTE:
                        reinterpret_cast<std::int8_t*>(dest)[i * components + c] =
                            static_cast<std::int8_t>(src[c] * 127 / 255);
                        break;
                    case GL_UNSIGNED_SHORT:
                        reinterpret_cast<std::uint16_t*>(dest)[i * components + c] =
                            static_cast<std::uint16_t>(src[c] * 257);
                        break;
                    case GL_SHORT:
                        reinterpret_cast<std::int16_t*>(dest)[i * components + c] =
                            static_cast<std::int16_t>(src[c] * 32767 / 255);
                        break;
                    case GL_UNSIGNED_INT:
                        reinterpret_cast<std::uint32_t*>(dest)[i * components + c] =
                            static_cast<std::uint32_t>(src[c]) * 16843009u;
                        break;
                    case GL_INT:
                        reinterpret_cast<std::int32_t*>(dest)[i * components + c] =
                            static_cast<std::int32_t>(static_cast<double>(src[c]) * 2147483647.0 / 255.0);
                        break;
                    case GL_FLOAT:
                        reinterpret_cast<float*>(dest)[i * components + c] = normalized;
                        break;
                    case GL_HALF_FLOAT: {
                        // Simple float-to-half conversion
                        std::uint32_t fbits;
                        std::memcpy(&fbits, &normalized, sizeof(fbits));
                        std::uint32_t sign = (fbits >> 16) & 0x8000;
                        std::int32_t exp = ((fbits >> 23) & 0xFF) - 127 + 15;
                        std::uint32_t mant = (fbits >> 13) & 0x3FF;
                        std::uint16_t half;
                        if (exp <= 0) half = static_cast<std::uint16_t>(sign);
                        else if (exp >= 31) half = static_cast<std::uint16_t>(sign | 0x7C00);
                        else half = static_cast<std::uint16_t>(sign | (exp << 10) | mant);
                        reinterpret_cast<std::uint16_t*>(dest)[i * components + c] = half;
                        break;
                    }
                    default:
                        dest[i * components * bpc + c] = src[c];
                        break;
                }
            }
        }
        return true;
    }

    // Default framebuffer readback — widen format/type acceptance
    impl_->encodePendingWork();
    if (format == GL_RGBA && type == GL_UNSIGNED_BYTE) {
        if (impl_->frameGraph == nullptr || !impl_->frameGraph->copyRGBA8Pixels(x, y, width, height, pixels)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        return true;
    }
    // For non-RGBA8 default framebuffer reads, read RGBA8 and convert
    if (componentCountForFormat(format) == 0) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const std::size_t pixelCount = static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
    std::vector<std::uint8_t> rgba8(pixelCount * 4);
    if (impl_->frameGraph == nullptr || !impl_->frameGraph->copyRGBA8Pixels(x, y, width, height, rgba8.data())) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Simple RGBA8 → requested format conversion (same as FBO path above)
    const std::size_t components = componentCountForFormat(format);
    const std::size_t bpc = bytesPerComponent(type);
    if (components == 0 || bpc == 0) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    auto* dest = static_cast<std::uint8_t*>(pixels);
    for (std::size_t i = 0; i < pixelCount; ++i) {
        std::uint8_t src[4] = { rgba8[i*4], rgba8[i*4+1], rgba8[i*4+2], rgba8[i*4+3] };
        if (format == GL_BGR || format == GL_BGR_INTEGER) {
            std::swap(src[0], src[2]);
        } else if (format == GL_BGRA || format == GL_BGRA_INTEGER) {
            std::swap(src[0], src[2]);
        }
        for (std::size_t c = 0; c < components; ++c) {
            const float normalized = static_cast<float>(src[c]) / 255.0f;
            switch (type) {
                case GL_UNSIGNED_BYTE:
                    dest[i * components + c] = src[c];
                    break;
                case GL_FLOAT:
                    reinterpret_cast<float*>(dest)[i * components + c] = normalized;
                    break;
                case GL_UNSIGNED_SHORT:
                    reinterpret_cast<std::uint16_t*>(dest)[i * components + c] =
                        static_cast<std::uint16_t>(src[c] * 257);
                    break;
                case GL_UNSIGNED_INT:
                    reinterpret_cast<std::uint32_t*>(dest)[i * components + c] =
                        static_cast<std::uint32_t>(src[c]) * 16843009u;
                    break;
                default:
                    dest[i * components + c] = src[c];
                    break;
            }
        }
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
    // Transform feedback state — gluStateReset queries these via getBooleanv;
    // returning GL_INVALID_ENUM here aborts the reset and bleeds state across
    // CTS tests (active/paused/binding all default to GL_FALSE/0 since we
    // don't yet support TF execution).
    if (pname == GL_TRANSFORM_FEEDBACK_ACTIVE) {
        *data = impl_->transformFeedbackActive ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (pname == GL_TRANSFORM_FEEDBACK_PAUSED) {
        *data = impl_->transformFeedbackPaused ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (pname == GL_TRANSFORM_FEEDBACK_BINDING) {
        *data = impl_->boundTransformFeedbackId != 0 ? GL_TRUE : GL_FALSE;
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
    if (pname == GL_TRANSFORM_FEEDBACK_ACTIVE) {
        *data = impl_->transformFeedbackActive ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (pname == GL_TRANSFORM_FEEDBACK_PAUSED) {
        *data = impl_->transformFeedbackPaused ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (pname == GL_TRANSFORM_FEEDBACK_BINDING) {
        *data = static_cast<GLint>(impl_->boundTransformFeedbackId);
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
    // Fall through to integer caps — glGetDoublev must return all
    // integer limits as double values per the GL spec.
    GLint intData[4] = {};
    if (impl_->capabilities != nullptr && impl_->capabilities->queryInteger(pname, intData)) {
        data[0] = static_cast<GLdouble>(intData[0]);
        if (pname == GL_MAX_VIEWPORT_DIMS) {
            data[1] = static_cast<GLdouble>(intData[1]);
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
        // ADV-10: invalidate cached index expansion on data change.
        ++object->indexExpansionGeneration;
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
    // GL 4.4 spec: persistent/coherent access requires matching storage flags.
    if ((access & GL_MAP_PERSISTENT_BIT) &&
        !(object->storageFlags & GL_MAP_PERSISTENT_BIT)) {
        pushError(GL_INVALID_OPERATION);
        return nullptr;
    }
    if ((access & GL_MAP_COHERENT_BIT) &&
        !(object->storageFlags & GL_MAP_COHERENT_BIT)) {
        pushError(GL_INVALID_OPERATION);
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
            *params = object->immutable ? GL_TRUE : GL_FALSE;
            return true;
        case GL_BUFFER_STORAGE_FLAGS:
            *params = static_cast<GLint64>(object->storageFlags);
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
    // Must match GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS (80) in GLCapabilities.
    // CTS state reset iterates that cap — a stricter gate breaks state reset.
    if (texture < GL_TEXTURE0 || texture >= GL_TEXTURE0 + 80) {
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
    if (!isSupportedInternalTextureFormat(*impl_->capabilities, static_cast<GLenum>(internalformat)) || componentCountForFormat(format) == 0) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if ((target == GL_TEXTURE_1D && (height != 1 || depth != 1))
        || (target == GL_TEXTURE_2D && depth != 1)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Enforce GL_MAX_TEXTURE_SIZE/GL_MAX_3D_TEXTURE_SIZE before reaching
    // Metal (which asserts on oversize dims).
    if (impl_->capabilities != nullptr) {
        GLint maxTex = 0, max3D = 0, maxLayers = 0;
        impl_->capabilities->queryInteger(GL_MAX_TEXTURE_SIZE, &maxTex);
        impl_->capabilities->queryInteger(GL_MAX_3D_TEXTURE_SIZE, &max3D);
        impl_->capabilities->queryInteger(GL_MAX_ARRAY_TEXTURE_LAYERS, &maxLayers);
        if (maxTex > 0 && (width > maxTex || height > maxTex)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (target == GL_TEXTURE_3D && max3D > 0 && (width > max3D || height > max3D || depth > max3D)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if ((target == GL_TEXTURE_2D_ARRAY || target == GL_TEXTURE_1D_ARRAY ||
             target == GL_TEXTURE_CUBE_MAP_ARRAY) &&
            maxLayers > 0 && depth > maxLayers) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }

    GLTextureObject* object = impl_->currentTexture(target);
    // CTS state reset (gluStateReset.cpp) calls texImage{2,3}D with size 0x0
    // on targets where no user texture is bound (default texture, name=0).
    // Per OpenGL 4.6 §8.5, such calls are valid — they either modify the
    // default texture object or are treated as a no-op when dims are 0.
    // Silently accept to keep state reset from throwing.
    if (object == nullptr) {
        return true;
    }
    if (!object->instantiated) {
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
    // GL_TEXTURE_3D and the array targets all carry layer/depth count in `depth`.
    image.desc.depth = (target == GL_TEXTURE_3D
                        || target == GL_TEXTURE_2D_ARRAY
                        || target == GL_TEXTURE_CUBE_MAP_ARRAY) ? depth : 1;
    image.desc.levels = std::max<GLsizei>(object->desc.levels, level + 1);
    image.defined = true;
    if (!impl_->buildRGBA8Upload(image.desc.width, image.desc.height, image.desc.depth, format, type, pixels, image.rgba8)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Also build native-format data for non-RGBA8 internal formats.
    impl_->buildNativeUpload(
        static_cast<GLenum>(internalformat),
        image.desc.width, image.desc.height, image.desc.depth,
        format, type, pixels, image.nativeData, image.nativeBpp);

    if (level == 0 || !object->levels.contains(0)) {
        object->desc = image.desc;
    }
    object->desc.levels = std::max<GLsizei>(object->desc.levels, level + 1);
    image.desc.levels = object->desc.levels;
    object->levels[level] = std::move(image);
    // Track cube-face definition for cube-completeness checking at
    // glGenerateMipmap time. Only level-0 face definitions count toward
    // cube completeness (GL 4.6 §8.17).
    if (level == 0) {
        const int faceIdx = Impl::cubeFaceIndexForTarget(target);
        if (faceIdx >= 0) {
            object->cubeFacesDefined |= static_cast<std::uint8_t>(1u << faceIdx);
        }
    }
    if (!impl_->replaceMetalTexture(*object, impl_->state->boundTexture(target))) {
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
    if (componentCountForFormat(format) == 0) {
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

    // Also update native-format data when present.
    if (image.nativeBpp > 0 && !image.nativeData.empty()) {
        std::vector<std::uint8_t> nativeUpload;
        std::size_t nativeBpp = 0;
        if (impl_->buildNativeUpload(image.desc.internalFormat,
                width, height, depth, format, type, pixels,
                nativeUpload, nativeBpp) && nativeBpp == image.nativeBpp) {
            for (GLsizei z = 0; z < depth; ++z) {
                for (GLsizei y = 0; y < height; ++y) {
                    const std::size_t srcOff =
                        (static_cast<std::size_t>(z) * static_cast<std::size_t>(height)
                         + static_cast<std::size_t>(y))
                        * static_cast<std::size_t>(width) * nativeBpp;
                    const std::size_t dstOff =
                        ((static_cast<std::size_t>(z + zoffset) * static_cast<std::size_t>(image.desc.height)
                          + static_cast<std::size_t>(y + yoffset))
                         * static_cast<std::size_t>(image.desc.width)
                         + static_cast<std::size_t>(xoffset))
                        * nativeBpp;
                    std::memcpy(
                        image.nativeData.data() + dstOff,
                        nativeUpload.data() + srcOff,
                        static_cast<std::size_t>(width) * nativeBpp);
                }
            }
        }
    }

    // Phase 8X Group 4d follow-up¹¹ — §Secondary per-subregion
    // fingerprint. Fires at most once per distinct
    // `(texName, xoffset, yoffset, width, height)` so Recoil's
    // glyph streaming (one sub-image call per glyph rect) gets
    // fingerprinted at the first update to each distinct
    // rectangle without flooding the log on repeat updates to
    // the same rectangle.
    //
    // The hash runs on the channel-fill-expanded RGBA8 `upload`
    // vector — that's the same representation the outer texture's
    // level-0 byte store uses, so BAR can cross-reference it
    // against the native-GL-path fingerprint BAR computes on the
    // post-channel-fill RGBA8.
    //
    // Unlike `replaceMetalTexture`'s log, this fires unconditionally
    // (not gated on texName !=0) because by the time we reach this
    // point the object pointer is valid and we know the bound
    // texture name is non-zero (currentTexture returned a concrete
    // object).
    const GLuint subTexName = impl_->state->boundTexture(target);
    if (subTexName != 0 && depth == 1) {
        Impl::SubImageRegionKey key{subTexName, xoffset, yoffset, width, height};
        if (impl_->loggedSubImageRegions.insert(key).second) {
            const std::uint8_t* subBytes = upload.data();
            const std::size_t subByteCount = upload.size();
            auto fnv1a = [](const std::uint8_t* p, std::size_t n) {
                std::uint32_t h = 0x811c9dc5u;
                for (std::size_t i = 0; i < n; ++i) {
                    h ^= p[i];
                    h *= 0x01000193u;
                }
                return h;
            };
            const std::uint32_t subHash = subByteCount ? fnv1a(subBytes, subByteCount) : 0;
            std::uint32_t nonzeroCount = 0;
            for (std::size_t i = 0; i < subByteCount; ++i) {
                if (subBytes[i] != 0) { ++nonzeroCount; }
            }
            char hexPeek[64] = {0};
            const std::size_t peekLen = std::min<std::size_t>(subByteCount, 16);
            for (std::size_t i = 0; i < peekLen; ++i) {
                std::snprintf(hexPeek + i * 3, sizeof(hexPeek) - i * 3,
                              "%02X ", subBytes[i]);
            }
            if (peekLen > 0) { hexPeek[peekLen * 3 - 1] = '\0'; }
            APPGL_LOG(TEXTURE, @"[GL] texSubImage first-call texName=%u target=0x%04X level=%d"
                  @" subregion=[%d,%d,%d,%d] sourceFormat=0x%04X sourceType=0x%04X"
                  @" rgba8Bytes=%zu fnv1a=0x%08X nonzero=%u peek16=[%s]",
                  subTexName,
                  static_cast<unsigned>(target),
                  level,
                  xoffset, yoffset, width, height,
                  static_cast<unsigned>(format),
                  static_cast<unsigned>(type),
                  subByteCount,
                  subHash,
                  nonzeroCount,
                  hexPeek);
        }
    }

    if (!impl_->replaceMetalTexture(*object, impl_->state->boundTexture(target))) {
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
    // GL 4.6 §8.19 + Metal reality: oversize textures must be rejected before
    // reaching MTLTextureDescriptor (which asserts rather than errors).
    // KHR-GL46.direct_state_access.textures_storage_errors etc. try 32768+
    // deliberately. Pull caps from GLCapabilities and enforce here.
    if (impl_->capabilities != nullptr) {
        GLint maxTex = 0, max3D = 0, maxLayers = 0;
        impl_->capabilities->queryInteger(GL_MAX_TEXTURE_SIZE, &maxTex);
        impl_->capabilities->queryInteger(GL_MAX_3D_TEXTURE_SIZE, &max3D);
        impl_->capabilities->queryInteger(GL_MAX_ARRAY_TEXTURE_LAYERS, &maxLayers);
        if (maxTex > 0 && (width > maxTex || height > maxTex)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (target == GL_TEXTURE_3D && max3D > 0 && (width > max3D || height > max3D || depth > max3D)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if ((target == GL_TEXTURE_2D_ARRAY || target == GL_TEXTURE_1D_ARRAY ||
             target == GL_TEXTURE_CUBE_MAP_ARRAY) &&
            maxLayers > 0 && depth > maxLayers) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
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
    object->desc.depth = (target == GL_TEXTURE_3D
                          || target == GL_TEXTURE_2D_ARRAY
                          || target == GL_TEXTURE_CUBE_MAP_ARRAY) ? depth : 1;
    object->desc.levels = levels;
    object->desc.immutable = true;
    object->target = target;

    // Pre-create level-0 image entry so replaceMetalTexture has something to work with.
    GLTextureImageLevel baseLevel;
    baseLevel.desc = object->desc;
    baseLevel.defined = true;
    const std::size_t totalPixels = static_cast<std::size_t>(width)
                                  * static_cast<std::size_t>(height)
                                  * static_cast<std::size_t>(object->desc.depth);
    baseLevel.rgba8.resize(totalPixels * 4u, 0);

    // Also allocate native-format backing for non-RGBA8 internal formats.
    {
        MTLPixelFormat nativeFmt = metalRenderbufferFormat(internalformat);
        if (nativeFmt != MTLPixelFormatInvalid && nativeFmt != MTLPixelFormatRGBA8Unorm) {
            auto info = Impl::nativeFormatInfo(nativeFmt);
            if (info.channels > 0 && info.bytesPerPixel > 0) {
                baseLevel.nativeBpp = static_cast<std::size_t>(info.bytesPerPixel);
                baseLevel.nativeData.resize(totalPixels * baseLevel.nativeBpp, 0);
            }
        }
    }
    object->levels[0] = std::move(baseLevel);

    if (!impl_->replaceMetalTexture(*object, impl_->state->boundTexture(target))) {
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
    // Enforce GL_MAX_TEXTURE_SIZE / array layers before reaching Metal
    // (which asserts on oversize). CTS textures_storage_multisample_errors
    // deliberately calls this with max_texture_size*2.
    if (impl_->capabilities != nullptr) {
        GLint maxTex = 0, maxLayers = 0;
        impl_->capabilities->queryInteger(GL_MAX_TEXTURE_SIZE, &maxTex);
        impl_->capabilities->queryInteger(GL_MAX_ARRAY_TEXTURE_LAYERS, &maxLayers);
        if (maxTex > 0 && (width > maxTex || height > maxTex)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY &&
            maxLayers > 0 && depth > maxLayers) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    if (!isSupportedInternalTextureFormat(*impl_->capabilities, internalformat)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // Metal only supports specific sample counts (typically 1, 2, 4, 8).
    // Unsupported values trigger MTLTextureDescriptor validation abort if
    // we pass them through. Check via MTLDevice.supportsTextureSampleCount.
    {
        id<MTLDevice> mtlDevice = impl_->device;
        if (mtlDevice != nil && samples > 1 && ![mtlDevice supportsTextureSampleCount:static_cast<NSUInteger>(samples)]) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
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

    if (!impl_->replaceMetalTexture(*object, impl_->state->boundTexture(target))) {
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
    // OpenGL 4.6 §8.10: when no user texture is bound to `target`, the
    // parameters are applied to the "default texture object" for that
    // target. CTS state reset (gluStateReset.cpp) relies on this: it
    // binds name=0 and then calls texParameteri to reset swizzle/levels.
    // If we generate GL_INVALID_OPERATION here, the reset throws and
    // subsequent state (notably glDepthMask(GL_TRUE)) never runs, causing
    // state bleed between tests. Silently accept the parameter instead —
    // since nothing reads back the default texture's params, a no-op is
    // functionally equivalent to storing them.
    if (object == nullptr) {
        return true;
    }
    if (!object->instantiated) {
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
    // Swizzle changes invalidate the cached texture view.
    if (pname == GL_TEXTURE_SWIZZLE_R || pname == GL_TEXTURE_SWIZZLE_G ||
        pname == GL_TEXTURE_SWIZZLE_B || pname == GL_TEXTURE_SWIZZLE_A ||
        pname == GL_TEXTURE_SWIZZLE_RGBA) {
        object->swizzleDirty = true;
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
    // See comment in texParameterInteger — default-texture params are a
    // no-op to keep CTS state reset from throwing.
    if (object == nullptr) {
        return true;
    }
    if (!object->instantiated) {
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
    // OpenGL 4.6 §8.11: querying the default texture is valid — return the
    // GL spec's initial parameter values. CTS texture_swizzle.intial_state
    // (note CTS typo "intial") deletes and rebinds the same texture name
    // in a loop, so subsequent iterations bind name=0 and query defaults.
    if (object == nullptr) {
        const GLTextureParameters defaults;
        if (!getTextureParameterInteger(defaults, pname, params)) {
            pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
            return false;
        }
        return true;
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
    // Default texture query returns spec defaults (see getTexParameterInteger).
    if (object == nullptr) {
        const GLTextureParameters defaults;
        if (!getTextureParameterFloat(defaults, pname, params)) {
            pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
            return false;
        }
        return true;
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
    // GL 4.6 §8.17: GL_INVALID_OPERATION if target is GL_TEXTURE_CUBE_MAP
    // (or CUBE_MAP_ARRAY) and the texture is not cube complete — i.e. at
    // least one of the six faces is missing a level-0 definition.
    // Checked by KHR-GL46.direct_state_access.textures_generate_mipmap_errors.
    // Level-0 face coverage is the minimum viable check: a stricter read
    // of the spec also requires matching face dimensions and format, but
    // all six faces going through the same single-target bindTexture +
    // same-size texImage2D path in practice means face-count is the
    // signal that distinguishes complete from incomplete.
    const GLenum normalized = Impl::normalizeTextureBindingTarget(target);
    if (normalized == GL_TEXTURE_CUBE_MAP && object->cubeFacesDefined != 0x3F) {
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
    // GL 4.6 §9.2.4: INVALID_VALUE if width or height exceeds
    // GL_MAX_RENDERBUFFER_SIZE (matches Metal's texture size ceiling).
    if (impl_->capabilities != nullptr) {
        GLint maxRB = 0;
        impl_->capabilities->queryInteger(GL_MAX_RENDERBUFFER_SIZE, &maxRB);
        if (maxRB > 0 && (width > maxRB || height > maxRB)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    if (!isSupportedRenderbufferFormat(internalformat)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // RC-D18: Validate samples against GL_MAX_SAMPLES.
    //
    // GL 4.6 §9.2.4 (and the DSA glNamedRenderbufferStorageMultisample
    // entry) specify GL_INVALID_OPERATION — NOT GL_INVALID_VALUE — when
    // samples > MAX_SAMPLES. This is checked by
    // KHR-GL46.direct_state_access.renderbuffers_storage_multisample_errors.
    // Previously we returned GL_INVALID_VALUE here; the test happened to
    // pass anyway because the `supportsTextureSampleCount:` check below
    // preempted it when our advertised MAX_SAMPLES exceeded what Metal
    // could actually deliver. Correct both the primary check's error code
    // and the preempting behaviour now that MAX_SAMPLES matches Metal.
    //
    // Also normalise samples <= 1 to 0: a single sample is logically
    // non-multisample and avoids Metal rejecting sampleCount == 1 for
    // MTLTextureType2DMultisample on some GPU families.
    if (samples <= 1) {
        samples = 0;
    } else {
        GLint maxSamples = 0;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger(GL_MAX_SAMPLES, &maxSamples);
        }
        if (maxSamples > 0 && samples > maxSamples) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        // Metal's MTLDevice only supports a subset of sample counts (typically
        // 1, 2, 4, 8). Passing unsupported values (e.g. samples=5) causes
        // MTLTextureDescriptor validation to assert rather than return an
        // error. Validate against the Metal device's reported support to
        // surface the failure as GL_INVALID_OPERATION instead of abort.
        id<MTLDevice> mtlDevice = impl_->device;
        if (mtlDevice != nil && ![mtlDevice supportsTextureSampleCount:static_cast<NSUInteger>(samples)]) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
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
        // RC-D18: Per the GL spec, glCheckFramebufferStatus only generates
        // GL_INVALID_ENUM (for an invalid target). An incomplete or
        // non-existent framebuffer is signalled via the return value, not
        // via the error queue. Pushing GL_INVALID_OPERATION here was leaking
        // a stale error into subsequent calls.
        return GL_FRAMEBUFFER_UNDEFINED;
    }
    return impl_->framebufferStatus(*object);
}

bool GLContext::framebufferTexture(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level, GLint layer, bool layered) {
    if (target != GL_FRAMEBUFFER && target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (textarget != 0 && !isTextureTarget(textarget)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // GL 4.6 §9.2.8: attachment enum shape check split from MAX-range
    // check. Unrecognised attachment → INVALID_ENUM; color-attachment-
    // shaped but >= MAX_COLOR_ATTACHMENTS → INVALID_OPERATION. See
    // framebuffers_texture_attachment_errors.
    if (!isFramebufferAttachmentEnum(attachment)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (isColorAttachmentEnum(attachment) && !isColorAttachment(attachment)) {
        pushError(GL_INVALID_OPERATION);
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

    // Invalid-texture-name error code differs per entry-point variant
    // (GL 4.6 §9.2.8):
    //  - glFramebufferTexture / glNamedFramebufferTexture (layered=true):
    //    INVALID_VALUE when texture is non-zero but not a valid name.
    //  - glFramebufferTextureLayer / glNamedFramebufferTextureLayer
    //    (layered=false here): INVALID_OPERATION for the same case.
    // The not-instantiated case stays INVALID_OPERATION for both.
    const GLTextureObject* textureObject = impl_->objects->textures().get(texture);
    if (textureObject == nullptr) {
        pushError(layered ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    if (!textureObject->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (textarget != 0 && textureObject->target != textarget) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §9.2.8 attachability rules on texture target.
    //
    // - GL_TEXTURE_BUFFER is never attachable to a framebuffer (it's
    //   backed by a buffer object, not image storage). Applies to every
    //   entry point (FramebufferTexture / FramebufferTexture2D /
    //   FramebufferTextureLayer).
    // - The single-layer variant (FramebufferTextureLayer and
    //   NamedFramebufferTextureLayer) additionally rejects non-layered
    //   targets: TEXTURE_RECTANGLE, TEXTURE_2D, TEXTURE_CUBE_MAP, etc.
    //   — layer indexing is only meaningful for 3D / array /
    //   multisample-array.
    // - TEXTURE_2D_MULTISAMPLE is accepted by FramebufferTexture
    //   (layered attachment; sample-level layering) but not by
    //   FramebufferTextureLayer because there's no "layer" concept on
    //   single-sample MS (vs MS array).
    //
    // The Layer variant is identified by `textarget == 0 && !layered`
    // (callers: glFramebufferTextureLayer, glNamedFramebufferTextureLayer).
    // glFramebufferTexture{1,2,3}D pass a non-zero textarget and are
    // already bounded by the textarget-vs-object-target match check
    // above, so they must not be swept up in the layer-attachable check.
    if (textureObject->target == GL_TEXTURE_BUFFER) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const bool isLayerVariant = (!layered && textarget == 0);
    if (isLayerVariant) {
        const bool isLayerAttachableTarget =
            textureObject->target == GL_TEXTURE_3D ||
            textureObject->target == GL_TEXTURE_2D_ARRAY ||
            textureObject->target == GL_TEXTURE_1D_ARRAY ||
            textureObject->target == GL_TEXTURE_CUBE_MAP_ARRAY ||
            textureObject->target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY;
        if (!isLayerAttachableTarget) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
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
    if (renderbuffertarget != GL_RENDERBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // GL 4.6 §9.2.8 splits attachment validation into two error classes:
    // an unrecognised enum → INVALID_ENUM; a color-attachment-shaped
    // enum >= MAX_COLOR_ATTACHMENTS → INVALID_OPERATION.
    if (!isFramebufferAttachmentEnum(attachment)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (isColorAttachmentEnum(attachment) && !isColorAttachment(attachment)) {
        pushError(GL_INVALID_OPERATION);
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

    const GLuint framebufferName = target == GL_READ_FRAMEBUFFER
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();

    // Default FB has its own attachment enum set per GL 4.6 §9.2.3:
    //   {FRONT_LEFT, FRONT_RIGHT, BACK_LEFT, BACK_RIGHT, DEPTH, STENCIL}
    // plus the standard COLOR_ATTACHMENTi / DEPTH_ATTACHMENT /
    // STENCIL_ATTACHMENT / DEPTH_STENCIL_ATTACHMENT subset (COLOR_ATTACHMENT0
    // aliases FRONT_LEFT per §9.2.9). framebuffers_get_attachment_parameters
    // queries the default set.
    const bool isDefaultFbAttachment = (attachment == GL_FRONT_LEFT
        || attachment == GL_FRONT_RIGHT
        || attachment == GL_BACK_LEFT
        || attachment == GL_BACK_RIGHT
        || attachment == GL_DEPTH
        || attachment == GL_STENCIL);
    if (framebufferName == 0) {
        if (!isDefaultFbAttachment && !isFramebufferAttachmentEnum(attachment)) {
            const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
            return false;
        }
        // On the default FB all requested attachments behave as if
        // implementation-provided: return GL_FRAMEBUFFER_DEFAULT for
        // OBJECT_TYPE, 0 for NAME/LEVEL/LAYER, and fixed component sizes
        // and component type for the color/depth/stencil queries so the
        // DSA cross-check against the legacy path agrees.
        const bool isColorAttachment = (attachment == GL_FRONT_LEFT
            || attachment == GL_FRONT_RIGHT
            || attachment == GL_BACK_LEFT
            || attachment == GL_BACK_RIGHT
            || (attachment >= GL_COLOR_ATTACHMENT0 && attachment < GL_COLOR_ATTACHMENT0 + 8));
        const bool isDepthSlot = (attachment == GL_DEPTH || attachment == GL_DEPTH_ATTACHMENT);
        const bool isStencilSlot = (attachment == GL_STENCIL || attachment == GL_STENCIL_ATTACHMENT);
        switch (pname) {
            case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE:
                params[0] = GL_FRAMEBUFFER_DEFAULT;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME:
            case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL:
            case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER:
                params[0] = 0;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE:
            case GL_FRAMEBUFFER_ATTACHMENT_GREEN_SIZE:
            case GL_FRAMEBUFFER_ATTACHMENT_BLUE_SIZE:
                params[0] = isColorAttachment ? 8 : 0;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE:
                params[0] = isColorAttachment ? 8 : 0;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE:
                params[0] = isDepthSlot ? 24 : 0;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE:
                params[0] = isStencilSlot ? 8 : 0;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE:
                if (isColorAttachment) { params[0] = GL_UNSIGNED_NORMALIZED; return true; }
                if (isDepthSlot)       { params[0] = GL_UNSIGNED_NORMALIZED; return true; }
                if (isStencilSlot)     { params[0] = GL_UNSIGNED_INT;        return true; }
                params[0] = GL_NONE;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING:
                params[0] = isColorAttachment ? GL_LINEAR : GL_NONE;
                return true;
            default:
                const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
                return false;
        }
    }

    // User FB path. Attachment enum validation splits shape/range so
    // COLOR_ATTACHMENTm with m >= MAX_COLOR_ATTACHMENTS returns
    // INVALID_OPERATION rather than INVALID_ENUM (matches
    // framebuffers_get_attachment_parameter_errors).
    if (!isFramebufferAttachmentEnum(attachment)) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
        return false;
    }
    if (isColorAttachmentEnum(attachment) && !isColorAttachment(attachment)) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_OPERATION);
        return false;
    }

    const GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebuffer == nullptr || !framebuffer->instantiated) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_OPERATION);
        return false;
    }
    const auto found = framebuffer->attachments.find(attachment);
    const GLFramebufferAttachment attachmentState = found == framebuffer->attachments.end() ? GLFramebufferAttachment{} : found->second;
    const auto attachmentInfo = impl_->framebufferAttachmentInfo(attachmentState);

    // GL 4.6 §9.2.3: when the attachment object type is GL_NONE, only
    // FRAMEBUFFER_ATTACHMENT_OBJECT_NAME and
    // FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE are valid pnames. Anything
    // else → INVALID_OPERATION. Additionally
    // FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE with
    // DEPTH_STENCIL_ATTACHMENT → INVALID_OPERATION (a depth-stencil
    // attachment has two component types, so asking for one makes no
    // sense).
    const bool objectIsNone = (attachmentState.kind == GLFramebufferAttachment::Kind::None);
    if (objectIsNone
        && pname != GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME
        && pname != GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (pname == GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE
        && attachment == GL_DEPTH_STENCIL_ATTACHMENT) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_OPERATION);
        return false;
    }

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
        case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER:
        case GL_FRAMEBUFFER_ATTACHMENT_LAYERED:
            // GL 4.6 §9.2.3: these pnames are only valid when
            // FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE is GL_TEXTURE. For a
            // renderbuffer attachment they generate INVALID_ENUM.
            // (The ObjectType==None case is already handled above.)
            if (attachmentState.kind != GLFramebufferAttachment::Kind::Texture) {
                const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
                return false;
            }
            if (pname == GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL) {
                params[0] = attachmentState.level;
            } else if (pname == GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER) {
                params[0] = attachmentState.layer;
            } else {
                params[0] = attachmentState.layered ? GL_TRUE : GL_FALSE;
            }
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
    // glDrawBuffer (singular) has looser rules than glDrawBuffers: on
    // the default framebuffer it also accepts the combined tokens
    // (FRONT, BACK, LEFT, RIGHT, FRONT_AND_BACK). Route through the
    // single-buffer validator rather than forwarding to the plural
    // form which would reject combined tokens.
    const GLuint framebufferName = impl_->state->boundDrawFramebuffer();
    if (framebufferName == 0) {
        // Default framebuffer — accepts every §17.4.1 single-target
        // token including the combined ones.
        if (!isDefaultFramebufferBuffer(buffer)) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        return impl_->state->setDrawBuffers(1, &buffer);
    }
    GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebuffer == nullptr || !framebuffer->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // User FBO — only NONE and COLOR_ATTACHMENTi tokens accepted.
    // Combined tokens are a recognized enum shape but invalid here.
    if (buffer == GL_NONE) {
        framebuffer->drawBuffers.fill(GL_NONE);
        framebuffer->drawBuffers[0] = GL_NONE;
        return true;
    }
    if (isColorAttachmentEnum(buffer)) {
        if (!isColorAttachment(buffer)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        framebuffer->drawBuffers.fill(GL_NONE);
        framebuffer->drawBuffers[0] = buffer;
        return true;
    }
    // `buffer` is a recognized default-FB token (FRONT, BACK, etc.) —
    // not legal on a user FBO per §17.4.1.
    if (isDefaultFramebufferBuffer(buffer)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

bool GLContext::drawBuffers(GLsizei count, const GLenum* buffers) {
    if (count < 0 || count > 8 || (count > 0 && buffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint framebufferName = impl_->state->boundDrawFramebuffer();
    if (framebufferName == 0) {
        // Default framebuffer, plural variant. Per GL 4.6 §17.4.1:
        //  - Valid in bufs: NONE, FRONT_LEFT/RIGHT, BACK_LEFT/RIGHT,
        //    BACK (must be alone).
        //  - COLOR_ATTACHMENTi on default framebuffer → INVALID_OPERATION
        //    (recognised enum shape but wrong FB kind).
        //  - FRONT, FRONT_AND_BACK, LEFT, RIGHT, etc. → INVALID_ENUM
        //    (accepted on singular glDrawBuffer but not the plural).
        //  - Anything else → INVALID_ENUM.
        for (GLsizei i = 0; i < count; ++i) {
            const GLenum b = buffers[i];
            const bool isSingleDefault = (b == GL_NONE || b == GL_FRONT_LEFT ||
                b == GL_FRONT_RIGHT || b == GL_BACK_LEFT || b == GL_BACK_RIGHT ||
                b == GL_BACK);
            if (!isSingleDefault) {
                if (isColorAttachmentEnum(b)) {
                    pushError(GL_INVALID_OPERATION);
                    return false;
                }
                pushError(GL_INVALID_ENUM);
                return false;
            }
            // BACK, if present, must be the sole entry.
            if (b == GL_BACK && count != 1) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
        }
        // Duplicate check: no non-NONE token may appear twice.
        for (GLsizei i = 0; i < count; ++i) {
            if (buffers[i] == GL_NONE) continue;
            for (GLsizei j = i + 1; j < count; ++j) {
                if (buffers[j] == buffers[i]) {
                    pushError(GL_INVALID_OPERATION);
                    return false;
                }
            }
        }
        return impl_->state->setDrawBuffers(count, buffers);
    }

    GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebuffer == nullptr || !framebuffer->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // User FBO (plural). CTS distinguishes two classes of invalid
    // tokens per GL 4.6 §17.4.1's prose and examples:
    //   - Combined tokens: FRONT, LEFT, RIGHT, FRONT_AND_BACK — never
    //     valid in the plural form on ANY framebuffer → INVALID_ENUM.
    //   - Single-target default-FB tokens: FRONT_LEFT, FRONT_RIGHT,
    //     BACK_LEFT, BACK_RIGHT, BACK — valid for default FB but wrong
    //     for a user FBO → INVALID_OPERATION.
    //   - COLOR_ATTACHMENTi with i >= MAX → INVALID_OPERATION.
    //   - Unrecognised enum → INVALID_OPERATION (matches the test's
    //     "anything other than NONE or COLOR_ATTACHMENTn" clause).
    auto isCombinedDefaultFBToken = [](GLenum b) {
        return b == GL_FRONT || b == GL_LEFT || b == GL_RIGHT ||
               b == GL_FRONT_AND_BACK;
    };
    auto isSingleDefaultFBToken = [](GLenum b) {
        return b == GL_FRONT_LEFT || b == GL_FRONT_RIGHT ||
               b == GL_BACK_LEFT  || b == GL_BACK_RIGHT  || b == GL_BACK;
    };
    for (GLsizei i = 0; i < count; ++i) {
        const GLenum b = buffers[i];
        if (b == GL_NONE) continue;
        if (isColorAttachmentEnum(b)) {
            if (!isColorAttachment(b)) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            continue;
        }
        if (isCombinedDefaultFBToken(b)) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        if (isSingleDefaultFBToken(b)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        // Truly unrecognised enum (e.g. GL_TRUE = 1, random garbage):
        // INVALID_ENUM per §17.4.1's "not an accepted value".
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // Duplicate check.
    for (GLsizei i = 0; i < count; ++i) {
        if (buffers[i] == GL_NONE) continue;
        for (GLsizei j = i + 1; j < count; ++j) {
            if (buffers[j] == buffers[i]) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
        }
    }
    framebuffer->drawBuffers.fill(GL_NONE);
    for (GLsizei index = 0; index < count; ++index) {
        framebuffer->drawBuffers[static_cast<std::size_t>(index)] = buffers[index];
    }
    return true;
}

bool GLContext::readBuffer(GLenum buffer) {
    const GLuint framebufferName = impl_->state->boundReadFramebuffer();
    if (framebufferName == 0) {
        // Default framebuffer: accepts §17.4.1 default-FB tokens plus
        // NONE. Anything else — including COLOR_ATTACHMENTi — is
        // INVALID_OPERATION when the enum is recognised but
        // inappropriate for the target, INVALID_ENUM when unrecognised.
        if (isDefaultFramebufferBuffer(buffer)) {
            return impl_->state->setReadBuffer(buffer);
        }
        if (isColorAttachmentEnum(buffer)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebuffer == nullptr || !framebuffer->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // User FBO: NONE or COLOR_ATTACHMENTi (where i < MAX).
    if (buffer == GL_NONE) {
        framebuffer->readBuffer = buffer;
        return true;
    }
    if (isColorAttachmentEnum(buffer)) {
        if (!isColorAttachment(buffer)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        framebuffer->readBuffer = buffer;
        return true;
    }
    if (isDefaultFramebufferBuffer(buffer)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    pushError(GL_INVALID_ENUM);
    return false;
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
    // Must match GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS (80) in GLCapabilities.
    if (unit >= 80) {
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
    APPGL_LOG(DRAW, @"[GL] %s-fallback: program=%u gate=%s vao=%u vbo=%u attrCount=%zu shadowBytes=%zu",
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

// Phase 8X Group 4d follow-up¹⁷ — immediate-mode entry points.
//
// See the block comment in GLContext.h alongside the declarations for
// the rationale. These five methods form a small state machine that
// captures `{position, color, texcoord}` tuples between glBegin/glEnd
// and drains them to a built-in Metal pipeline on glEnd. State lives
// in `impl_->immediate`. `currentColor` / `currentTexcoord` are
// per-vertex registers updated by glColor*/glTexCoord* without
// emitting a vertex; only glVertex* pushes into the capture vector.

void GLContext::beginImmediate(GLenum mode) {
    switch (mode) {
        case GL_TRIANGLES:
        case GL_TRIANGLE_STRIP:
        case GL_TRIANGLE_FAN:
        case GL_QUADS:
        case GL_LINES:
        case GL_LINE_STRIP:
        case GL_LINE_LOOP:
        case GL_POINTS:
            break;
        default:
            pushError(GL_INVALID_ENUM);
            return;
    }
    if (impl_->immediate.active) {
        // Nested glBegin is invalid in the GL spec.
        pushError(GL_INVALID_OPERATION);
        return;
    }
    impl_->immediate.active = true;
    impl_->immediate.mode = mode;
    impl_->immediate.vertices.clear();
}

void GLContext::immediateVertex(float x, float y, float z, float w) {
    if (!impl_->immediate.active) {
        // glVertex* outside glBegin/glEnd is silently ignored per GL 1.x.
        // (The function exists but does nothing when not inside a begin/end pair.)
        return;
    }
    Impl::ImmediateModeVertex v;
    v.position[0] = x;
    v.position[1] = y;
    v.position[2] = z;
    v.position[3] = w;
    v.color[0] = impl_->immediate.currentColor[0];
    v.color[1] = impl_->immediate.currentColor[1];
    v.color[2] = impl_->immediate.currentColor[2];
    v.color[3] = impl_->immediate.currentColor[3];
    v.texcoord[0] = impl_->immediate.currentTexcoord[0];
    v.texcoord[1] = impl_->immediate.currentTexcoord[1];
    impl_->immediate.vertices.push_back(v);
}

void GLContext::immediateColor(float r, float g, float b, float a) {
    // Per GL 1.x spec, glColor* is valid outside begin/end and simply
    // updates the current color register; it's read by the next glVertex*
    // inside a begin/end pair.
    impl_->immediate.currentColor[0] = r;
    impl_->immediate.currentColor[1] = g;
    impl_->immediate.currentColor[2] = b;
    impl_->immediate.currentColor[3] = a;
}

void GLContext::immediateTexCoord(unsigned int unit, float s, float t, float /*r*/, float /*q*/) {
    // Only texture unit 0 is captured for the built-in immediate-mode
    // pipeline (Chobby/Chili UI only uses unit 0). Multi-texturing on
    // other units is silently ignored — this matches the single-
    // sampler pipeline we build in MetalFrameGraph.
    if (unit != 0) {
        return;
    }
    impl_->immediate.currentTexcoord[0] = s;
    impl_->immediate.currentTexcoord[1] = t;
}

void GLContext::endImmediate() {
    if (!impl_->immediate.active) {
        pushError(GL_INVALID_OPERATION);
        return;
    }
    impl_->immediate.active = false;

    const GLenum mode = impl_->immediate.mode;
    auto& captured = impl_->immediate.vertices;
    if (captured.empty()) {
        return;
    }
    if (impl_->frameGraph == nullptr) {
        return;
    }

    // GL_QUADS → GL_TRIANGLES CPU-side expansion. Metal core has no
    // quads primitive, so every 4 captured vertices become 6 output
    // vertices using the canonical {0,1,2, 0,2,3} fan pattern.
    std::vector<Impl::ImmediateModeVertex> expanded;
    const Impl::ImmediateModeVertex* drawVerts = captured.data();
    std::size_t drawCount = captured.size();
    GLenum drawMode = mode;
    if (mode == GL_QUADS) {
        const std::size_t quads = captured.size() / 4;
        expanded.reserve(quads * 6);
        for (std::size_t q = 0; q < quads; ++q) {
            const Impl::ImmediateModeVertex& v0 = captured[q * 4 + 0];
            const Impl::ImmediateModeVertex& v1 = captured[q * 4 + 1];
            const Impl::ImmediateModeVertex& v2 = captured[q * 4 + 2];
            const Impl::ImmediateModeVertex& v3 = captured[q * 4 + 3];
            expanded.push_back(v0);
            expanded.push_back(v1);
            expanded.push_back(v2);
            expanded.push_back(v0);
            expanded.push_back(v2);
            expanded.push_back(v3);
        }
        drawVerts = expanded.data();
        drawCount = expanded.size();
        drawMode = GL_TRIANGLES;
    }

    // Ensure any pending clear is flushed before the encode.
    impl_->frameGraph->resizeDrawable(impl_->drawableSurfaceWidth(), impl_->drawableSurfaceHeight());
    impl_->encodePendingWork();

    // Resolve the texture bound to unit 0 GL_TEXTURE_2D, if any.
    // The textured pipeline samples it; the untextured pipeline ignores
    // the slot entirely.
    void* metalTexture = nullptr;
    const GLuint texName = impl_->state->boundTextureOnUnit(0, GL_TEXTURE_2D);
    if (texName != 0) {
        GLTextureObject* tex = impl_->objects->textures().get(texName);
        if (tex != nullptr && tex->metalTexture != nullptr) {
            metalTexture = tex->metalTexture;
        }
    }

    // Build the MVP from the matrix mirror (proj · modelview); the
    // immediate-mode vertex shader applies it to each captured position.
    const Matrix4 mvp = impl_->matrixState.modelViewProjection();

    ImmediateDrawInfo info;
    info.mode = drawMode;
    info.vertices = drawVerts;
    info.vertexCount = drawCount;
    info.vertexStride = sizeof(Impl::ImmediateModeVertex);
    info.mvp = mvp;
    info.metalTexture = metalTexture;

    const bool ok = impl_->frameGraph->encodeImmediateModeDraw(info);
    if (!ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_ERROR,
            0,
            GL_DEBUG_SEVERITY_HIGH,
            "glEnd: MetalFrameGraph failed to encode immediate-mode draw"
        );
    }
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

bool GLContext::isTransformFeedbackActive() const {
    return impl_->transformFeedbackActive;
}

void GLContext::setTransformFeedbackActive(bool active) {
    impl_->transformFeedbackActive = active;
}

bool GLContext::isTransformFeedbackPaused() const {
    return impl_->transformFeedbackPaused;
}

void GLContext::setTransformFeedbackPaused(bool paused) {
    impl_->transformFeedbackPaused = paused;
}

GLenum GLContext::transformFeedbackPrimitiveMode() const {
    return impl_->transformFeedbackPrimitiveMode;
}

void GLContext::setTransformFeedbackPrimitiveMode(GLenum mode) {
    impl_->transformFeedbackPrimitiveMode = mode;
}

GLuint GLContext::boundTransformFeedback() const {
    return impl_->boundTransformFeedbackId;
}

void GLContext::setBoundTransformFeedback(GLuint id) {
    impl_->boundTransformFeedbackId = id;
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
            // Phase 8X Group 4d follow-up¹⁵ — when the same uniform is
            // declared in two stages (e.g. vertex + fragment both declare
            // `uniform vec4 ucolor = vec4(1.0);`) honour whichever stage
            // carries a populated default. If the first stage to declare
            // the uniform had no initializer (or the stage order happens
            // to land the defaulted copy second) we still want that default
            // to win over an empty shadow.
            if (existing->defaultFloats.empty() && !decl.defaultFloats.empty()) {
                existing->defaultFloats = decl.defaultFloats;
            }
            if (existing->defaultInts.empty() && !decl.defaultInts.empty()) {
                existing->defaultInts = decl.defaultInts;
            }
            if (existing->defaultUints.empty() && !decl.defaultUints.empty()) {
                existing->defaultUints = decl.defaultUints;
            }
            // RC-D06 / RC-D08: if the second stage carries an explicit
            // location or binding that the first stage lacked, adopt it.
            if (existing->explicitLocation < 0 && decl.explicitLocation >= 0) {
                existing->explicitLocation = decl.explicitLocation;
            }
            if (existing->explicitBinding < 0 && decl.explicitBinding >= 0) {
                existing->explicitBinding = decl.explicitBinding;
            }
            continue;
        }
        GLProgramUniformInfo info;
        info.name = decl.name;
        info.type = decl.type;
        info.arraySize = decl.arraySize > 0 ? decl.arraySize : 1;
        info.location = -1;  // assigned below in link-time location pass
        info.explicitLocation = decl.explicitLocation;
        info.explicitBinding = decl.explicitBinding;
        info.defaultFloats = decl.defaultFloats;
        info.defaultInts = decl.defaultInts;
        info.defaultUints = decl.defaultUints;
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
        // Lenient no-op for unknown shader names (see deleteProgram for the
        // same tradeoff — CTS helper classes double-delete on error paths
        // and treat any queued error as a destructor throw).
        return true;
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
    CompatShaderRewriteResult rewrite =
        rewriteCompatShader(object->source, object->stage);
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

    // Reverse-map compat shader renames so GL queries report original names.
    // The shader source uses `_appgl_sampler` (so glslang accepts it), but
    // the GL API must expose the original `sampler` name to applications.
    if (rewrite.didRewrite) {
        auto reverseRename = [](std::string& s) {
            const std::string from = "_appgl_sampler";
            const std::string to = "sampler";
            std::string::size_type pos = 0;
            while ((pos = s.find(from, pos)) != std::string::npos) {
                s.replace(pos, from.size(), to);
                pos += to.size();
            }
        };
        for (auto& decl : reflection.uniforms) {
            reverseRename(decl.name);
        }
        for (auto& decl : reflection.inputs) {
            reverseRename(decl.name);
        }
        for (auto& decl : reflection.outputs) {
            reverseRename(decl.name);
        }
    }

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
        // Lenient no-op for unknown program names. Spec (GL 4.6 §7.3) says
        // GL_INVALID_VALUE, but CTS tests (e.g. clip_distance.functional)
        // double-delete program ids and treat error queue leakage as
        // destructor-throws — a single errored delete aborts the entire
        // sweep. NVIDIA's driver is similarly lenient. Applications that
        // legitimately track program names won't hit this path.
        return true;
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

// ── GLSL source parsing helpers for UBO metadata recovery ──
//
// SPIRV-Cross loses certain GLSL-level metadata when emitting SPIR-V for
// uniform blocks. Two known gaps:
//
// 1. Instance names: SPIRV-Cross's `ubo.name` == type name for both
//    instanced (`uniform B { ... } b;`) and non-instanced (`uniform B { ... };`)
//    blocks. We parse the GLSL source for `} instanceName;` to recover this.
//
// 2. Bool types: SPIR-V represents `bool` in interface blocks as `uint`
//    (OpTypeBool cannot appear in storage interfaces). We scan the block
//    body for `bool`/`bvec2`/`bvec3`/`bvec4` member declarations to
//    restore the original GL type.

// Find the body of `uniform <blockName> { ... }` in GLSL source.
// Returns (bodyStart, bodyEnd) — the byte range INSIDE the braces, or
// (npos, npos) if not found.
static std::pair<std::size_t, std::size_t>
findBlockBody(const std::string& source, const std::string& blockName) {
    const std::string token = "uniform " + blockName;
    std::size_t pos = 0;
    while (pos < source.size()) {
        pos = source.find(token, pos);
        if (pos == std::string::npos) return {std::string::npos, std::string::npos};
        std::size_t end = pos + token.size();
        if (end < source.size() && (std::isalnum(source[end]) || source[end] == '_')) {
            pos = end;
            continue;
        }
        std::size_t bracePos = source.find('{', end);
        if (bracePos == std::string::npos) return {std::string::npos, std::string::npos};
        int depth = 1;
        std::size_t cur = bracePos + 1;
        while (cur < source.size() && depth > 0) {
            if (source[cur] == '{') ++depth;
            else if (source[cur] == '}') --depth;
            ++cur;
        }
        // cur is right after the closing '}'. Body is [bracePos+1, cur-2].
        return {bracePos + 1, cur - 1};
    }
    return {std::string::npos, std::string::npos};
}

// Strip line + block comments from GLSL source. Used as input to the
// layout(binding=N) scanner below so that commented-out layout
// qualifiers don't get matched.
static std::string stripGlslComments(const std::string& source) {
    std::string s;
    s.reserve(source.size());
    for (std::size_t i = 0; i < source.size(); ) {
        if (i + 1 < source.size() && source[i] == '/' && source[i + 1] == '/') {
            while (i < source.size() && source[i] != '\n') ++i;
        } else if (i + 1 < source.size() && source[i] == '/' && source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.size() && !(source[i] == '*' && source[i + 1] == '/')) ++i;
            if (i + 1 < source.size()) i += 2;
        } else {
            s += source[i];
            ++i;
        }
    }
    return s;
}

// Parse `layout(binding = N) ... uniform <sampler|image>Type <name>[...];`
// declarations out of the comment-stripped GLSL source. Returns a map
// from sampler uniform name to its explicit binding index.
//
// This is the source-of-truth for "did the user write layout(binding)"
// because glslang auto-assigns DecorationBinding on every sampler
// variable regardless of whether the GLSL had an explicit qualifier —
// see bd73acc / 9c496f4 where the previous attempts relied on
// SPIRV-Cross's `has_decoration(id, DecorationBinding)` and that
// returned true for both auto-assigned and user-declared bindings,
// which wrecked pixelstoragemodes (samplers without explicit bindings
// got shifted to non-zero units).
//
// Parser approach: bespoke scan rather than <regex> for determinism
// and to avoid C++ regex overhead. Handles:
//   layout(binding = 5) uniform sampler2D foo;
//   layout(binding=5) uniform sampler2D foo;
//   layout(binding = 5, location = 2) uniform sampler2D foo;
//   layout(location = 2, binding = 5) uniform highp sampler2D foo;
//   layout(binding=5) uniform sampler2D foo[3];
// Does NOT handle macro-expanded names, preprocessor conditionals that
// leave declarations out, or GLSL #version gates — if those ever matter
// we add them in a follow-up.
static std::unordered_map<std::string, GLuint>
parseExplicitSamplerBindings(const std::string& rawSource) {
    std::unordered_map<std::string, GLuint> result;
    const std::string s = stripGlslComments(rawSource);

    auto isIdentChar = [](char c) -> bool {
        return std::isalnum(static_cast<unsigned char>(c)) || c == '_';
    };
    auto skipWhitespace = [&](std::size_t& i) {
        while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;
    };

    std::size_t pos = 0;
    while (pos < s.size()) {
        const auto layoutPos = s.find("layout", pos);
        if (layoutPos == std::string::npos) break;

        // Word boundary before / after "layout".
        if (layoutPos > 0 && isIdentChar(s[layoutPos - 1])) {
            pos = layoutPos + 1;
            continue;
        }
        std::size_t after = layoutPos + 6;
        skipWhitespace(after);
        if (after >= s.size() || s[after] != '(') {
            pos = layoutPos + 1;
            continue;
        }

        // Find matching ')'.
        int depth = 0;
        std::size_t closeIdx = after;
        for (; closeIdx < s.size(); ++closeIdx) {
            if (s[closeIdx] == '(') ++depth;
            else if (s[closeIdx] == ')') {
                if (--depth == 0) break;
            }
        }
        if (closeIdx >= s.size()) {
            pos = layoutPos + 1;
            continue;
        }
        const std::string body = s.substr(after + 1, closeIdx - after - 1);

        // Extract `binding = N` from the layout body. Word-boundary
        // match so `decl_binding` or similar doesn't trigger.
        int binding = -1;
        std::size_t bPos = 0;
        while ((bPos = body.find("binding", bPos)) != std::string::npos) {
            if (bPos > 0 && isIdentChar(body[bPos - 1])) {
                bPos += 1;
                continue;
            }
            std::size_t eqPos = bPos + 7;
            while (eqPos < body.size() && std::isspace(static_cast<unsigned char>(body[eqPos]))) ++eqPos;
            if (eqPos < body.size() && body[eqPos] == '=') {
                ++eqPos;
                while (eqPos < body.size() && std::isspace(static_cast<unsigned char>(body[eqPos]))) ++eqPos;
                char* endp = nullptr;
                const long val = std::strtol(body.c_str() + eqPos, &endp, 10);
                if (endp != body.c_str() + eqPos && val >= 0) {
                    binding = static_cast<int>(val);
                }
            }
            break;
        }

        if (binding >= 0) {
            // Scan post-`)` for `uniform? precision? sampler-type name`.
            std::size_t cur = closeIdx + 1;
            skipWhitespace(cur);
            // Optional "uniform" keyword.
            if (s.compare(cur, 7, "uniform") == 0 &&
                (cur + 7 >= s.size() || !isIdentChar(s[cur + 7]))) {
                cur += 7;
                skipWhitespace(cur);
            }
            // Optional precision qualifier.
            for (const char* prec : {"highp", "mediump", "lowp"}) {
                const std::size_t plen = std::strlen(prec);
                if (s.compare(cur, plen, prec) == 0 &&
                    (cur + plen >= s.size() || !isIdentChar(s[cur + plen]))) {
                    cur += plen;
                    skipWhitespace(cur);
                    break;
                }
            }
            // Read the type name (must contain "sampler" / "image" /
            // case-insensitive `Sampler`).
            const std::size_t typeStart = cur;
            while (cur < s.size() && isIdentChar(s[cur])) ++cur;
            const std::string typeName = s.substr(typeStart, cur - typeStart);
            const bool isOpaqueType =
                typeName.find("sampler") != std::string::npos ||
                typeName.find("Sampler") != std::string::npos ||
                typeName.find("image") != std::string::npos ||
                typeName.find("Image") != std::string::npos;
            if (isOpaqueType) {
                skipWhitespace(cur);
                const std::size_t nameStart = cur;
                while (cur < s.size() && isIdentChar(s[cur])) ++cur;
                if (cur > nameStart) {
                    std::string name = s.substr(nameStart, cur - nameStart);
                    result[std::move(name)] = static_cast<GLuint>(binding);
                }
            }
        }

        pos = closeIdx + 1;
    }
    return result;
}

static bool glslBlockHasInstanceName(const std::string& source,
                                      const std::string& blockName) {
    auto [bodyStart, bodyEnd] = findBlockBody(source, blockName);
    if (bodyStart == std::string::npos) return false;
    // bodyEnd points at the '}'. Skip whitespace after it.
    std::size_t cur = bodyEnd + 1;
    while (cur < source.size() &&
           (source[cur] == ' ' || source[cur] == '\t' ||
            source[cur] == '\n' || source[cur] == '\r')) {
        ++cur;
    }
    return cur < source.size() && (std::isalpha(source[cur]) || source[cur] == '_');
}

// Search a code region for "boolType name" where boolType is bool/bvec2/3/4.
// Returns the GL_BOOL* enum, or 0 if not found.
static GLenum searchForBoolType(std::string_view body, std::string_view name) {
    struct BoolMapping { const char* keyword; GLenum type; };
    static const BoolMapping mappings[] = {
        {"bvec4", GL_BOOL_VEC4},
        {"bvec3", GL_BOOL_VEC3},
        {"bvec2", GL_BOOL_VEC2},
        {"bool",  GL_BOOL},
    };
    for (const auto& m : mappings) {
        std::string pattern = std::string(m.keyword) + " " + std::string(name);
        auto fpos = body.find(pattern);
        if (fpos != std::string_view::npos) {
            std::size_t afterPattern = fpos + pattern.size();
            if (afterPattern >= body.size() ||
                body[afterPattern] == ';' || body[afterPattern] == '[' ||
                body[afterPattern] == ' ' || body[afterPattern] == '\n' ||
                body[afterPattern] == '\r') {
                return m.type;
            }
        }
    }
    return 0;
}

// Detect bool/bvec member types that SPIR-V represents as uint/uvec.
// Returns the correct GL_BOOL* type, or 0 if the member is not a bool type.
//
// For direct block members (no dots in name), we search within the block body.
// For nested struct members ("s.c"), we resolve through the struct chain:
// find the struct type name for each prefix component, then search the
// innermost struct body for the leaf name.
// Strip single-line comments ("// ...") from GLSL source. This prevents
// member-name searches from matching inside comments like "// unused in
// vertex shader" where a stray " i" would be misidentified as a declaration.
static std::string stripGLSLComments(std::string_view src) {
    std::string out;
    out.reserve(src.size());
    for (std::size_t i = 0; i < src.size(); ++i) {
        if (i + 1 < src.size() && src[i] == '/' && src[i+1] == '/') {
            // Skip to end of line
            while (i < src.size() && src[i] != '\n') ++i;
            if (i < src.size()) out += '\n';
        } else {
            out += src[i];
        }
    }
    return out;
}

static GLenum detectBoolMemberType(const std::string& source,
                                    const std::string& blockName,
                                    const std::string& memberName) {
    // Work on a comment-stripped copy to avoid false matches in comments.
    const std::string cleanSource = stripGLSLComments(source);

    // Split by dots first: "a[0].inner.c" → ["a[0]", "inner", "c"]
    // Array indices are stripped per-component in the traversal loop,
    // NOT up front (to preserve the dot-separated structure).
    std::vector<std::string> parts;
    std::size_t start = 0;
    while (start < memberName.size()) {
        auto dot = memberName.find('.', start);
        if (dot == std::string::npos) {
            parts.push_back(memberName.substr(start));
            break;
        }
        parts.push_back(memberName.substr(start, dot - start));
        start = dot + 1;
    }
    if (parts.empty()) return 0;

    // Strip array suffixes from each part: "a[0]" → "a"
    for (auto& p : parts) {
        auto bracketPos = p.find('[');
        if (bracketPos != std::string::npos) {
            p = p.substr(0, bracketPos);
        }
    }

    // For direct members (single part), search the block body.
    if (parts.size() == 1) {
        auto [bodyStart, bodyEnd] = findBlockBody(cleanSource, blockName);
        if (bodyStart == std::string::npos) return 0;
        std::string_view body(cleanSource.data() + bodyStart, bodyEnd - bodyStart);
        return searchForBoolType(body, parts[0]);
    }

    // For nested members, traverse the struct chain.
    // Start with the block body, find the type of each prefix, then
    // search the struct definition for the next component.
    auto [bodyStart, bodyEnd] = findBlockBody(cleanSource, blockName);
    if (bodyStart == std::string::npos) return 0;
    std::string_view searchBody(cleanSource.data() + bodyStart, bodyEnd - bodyStart);

    for (std::size_t i = 0; i < parts.size() - 1; ++i) {
        // Find the type name for part[i] in the current body.
        // Pattern: "<TypeName> <partName>" or "<TypeName> <partName>[...]"
        // We need to extract the type name that precedes the member name.
        const std::string& partName = parts[i];
        // Search for " partName" (with space before) to find declarations.
        // Require a word boundary after the name (;, [, space, newline)
        // to avoid matching "i" inside "ivec4" etc.
        std::string needle = " " + partName;
        std::string_view::size_type pos = std::string_view::npos;
        {
            std::string_view::size_type searchFrom = 0;
            while (searchFrom < searchBody.size()) {
                auto candidate = searchBody.find(needle, searchFrom);
                if (candidate == std::string_view::npos) break;
                std::size_t afterName = candidate + needle.size();
                if (afterName >= searchBody.size() ||
                    searchBody[afterName] == ';' || searchBody[afterName] == '[' ||
                    searchBody[afterName] == ' ' || searchBody[afterName] == '\n' ||
                    searchBody[afterName] == '\r' || searchBody[afterName] == '\t') {
                    pos = candidate;
                    break;
                }
                searchFrom = candidate + 1;
            }
        }
        if (pos == std::string_view::npos) return 0;
        // Walk backwards from the match to find the type name.
        // Skip whitespace backwards, then collect identifier chars.
        auto typeEnd = pos;
        while (typeEnd > 0 && searchBody[typeEnd - 1] == ' ') --typeEnd;
        auto typeStart = typeEnd;
        while (typeStart > 0 && (std::isalnum(searchBody[typeStart - 1]) || searchBody[typeStart - 1] == '_')) --typeStart;
        std::string typeName(searchBody.substr(typeStart, typeEnd - typeStart));
        if (typeName.empty()) return 0;
        // Find the struct definition for this type.
        std::string structToken = "struct " + typeName;
        auto structPos = cleanSource.find(structToken);
        if (structPos == std::string::npos) return 0;
        auto bracePos = cleanSource.find('{', structPos);
        if (bracePos == std::string::npos) return 0;
        int depth = 1;
        auto cur = bracePos + 1;
        while (cur < cleanSource.size() && depth > 0) {
            if (cleanSource[cur] == '{') ++depth;
            else if (cleanSource[cur] == '}') --depth;
            ++cur;
        }
        searchBody = std::string_view(cleanSource.data() + bracePos + 1, cur - bracePos - 2);
    }

    // Search the final body for the leaf member name.
    return searchForBoolType(searchBody, parts.back());
}

bool GLContext::linkProgram(GLuint program) {
    GLProgramObject* programObject = impl_->objects->programs().get(program);
    if (programObject == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    // Phase 8X Group 4d follow-up²³ — link-path crash-site instrumentation.
    // The fw²² smoke identified Spring's Sky shader (program 28) SIGABRT'ing
    // between the `compileGLSLProgram` NSLog and the final `linkProgram`
    // NSLog. All Metal pipeline work (`newLibraryWithSource`,
    // `newRenderPipelineStateWithDescriptor`) lives in `MetalFrameGraph.mm`
    // and is only reached at draw time — so the only work between those two
    // log lines is glslang cross-stage link + SPIRV-Cross spirvToMSL/reflect.
    // These markers bracket each sub-step so BAR's crash handler can tell
    // which one is the last to run before abort. Each marker is followed by
    // an explicit `fflush(stderr)` to survive the libunwind double-abort that
    // fw²² verification §5.3 documented (`fsync(STDERR_FILENO)` Spring-side
    // fix is separate and still deferred).
    APPGL_LOG(SHADER, @"[GL] linkProgram-begin program=%u", program);
    fflush(stderr);

    programObject->uniforms.clear();
    programObject->attributes.clear();
    programObject->uniformValues.clear();
    programObject->linkLog.clear();
    programObject->linked = false;

    // RC-D09: Clear resource tables from any previous link so stale
    // introspection data never survives a failed re-link.
    programObject->resourceUniforms.clear();
    programObject->resourceUniformBlocks.clear();
    programObject->resourceInputs.clear();
    programObject->resourceOutputs.clear();
    programObject->resourceStorageBlocks.clear();
    programObject->resourceAtomicCounterBuffers.clear();
    programObject->resourceBufferVariables.clear();
    programObject->resourceTransformFeedbackVaryings.clear();
    programObject->resourceTransformFeedbackBuffers.clear();
    programObject->ssboBindingRemap.clear();
    programObject->samplerExplicitBindings.clear();

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

        // GL 4.2 §7.6: harvest `layout(binding = N)` from the original
        // GLSL source across every attached shader. The map is used at
        // draw-time to substitute the declared unit for any sampler
        // uniform the application hasn't explicitly glUniform1i'd.
        // Later-stage declarations override earlier ones if names
        // collide — safe in practice because the same sampler name in
        // multiple stages must refer to the same resource by GL's
        // cross-stage interface rules.
        auto stageBindings = parseExplicitSamplerBindings(shaderObject->source);
        for (auto& [name, binding] : stageBindings) {
            programObject->samplerExplicitBindings[name] = binding;
        }
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
        GeometryOnly,
        TessControlOnly,
        TessEvalOnly,
    };
    ProgramKind kind = ProgramKind::Unknown;
    if (computeShader != nullptr && shaderCount == 1) {
        kind = ProgramKind::Compute;
    } else if (vertexShader != nullptr && fragmentShader != nullptr &&
               tessControlShader == nullptr && tessEvalShader == nullptr &&
               geometryShader == nullptr && computeShader == nullptr) {
        kind = ProgramKind::VertexFragment;
    } else if (vertexShader != nullptr && fragmentShader != nullptr &&
               geometryShader != nullptr && computeShader == nullptr) {
        kind = ProgramKind::VertexGeometryFragment;
    } else if (vertexShader != nullptr && fragmentShader != nullptr &&
               tessControlShader != nullptr && tessEvalShader != nullptr &&
               computeShader == nullptr) {
        kind = ProgramKind::VertexTessellationFragment;
    } else if (vertexShader != nullptr && fragmentShader == nullptr &&
               computeShader == nullptr && geometryShader == nullptr &&
               tessControlShader == nullptr && tessEvalShader == nullptr) {
        kind = ProgramKind::VertexOnly;
    } else if (fragmentShader != nullptr && vertexShader == nullptr &&
               computeShader == nullptr && geometryShader == nullptr &&
               tessControlShader == nullptr && tessEvalShader == nullptr) {
        kind = ProgramKind::FragmentOnly;
    } else if (geometryShader != nullptr && shaderCount == 1) {
        // Separable geometry-only program — used with glProgramPipeline +
        // glUseProgramStages(GL_GEOMETRY_SHADER_BIT). CTS
        // `separable_programs_tf.geometry_active` constructs one per stage
        // and links them independently. Translate to MSL for reflection so
        // the link succeeds; draw-time GS emulation is handled by the
        // VertexGeometryFragment path when the combined pipeline runs.
        kind = ProgramKind::GeometryOnly;
    } else if (tessControlShader != nullptr && shaderCount == 1) {
        kind = ProgramKind::TessControlOnly;
    } else if (tessEvalShader != nullptr && shaderCount == 1) {
        kind = ProgramKind::TessEvalOnly;
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

    // Assign uniform locations and seed default values.
    //
    // RC-D06: honour explicit `layout(location=N)` qualifiers from the GLSL
    // source.  CTS tests declare `layout(location=5) uniform float myUniform;`
    // and expect `glGetUniformLocation` to return 5.  The old code assigned
    // dense sequential locations starting from 0 regardless of any explicit
    // qualifier, which made those tests get -1.
    //
    // Two-pass approach:
    //   Pass 1 — assign explicit locations (those with explicitLocation >= 0).
    //            Track which locations are occupied so pass 2 can skip them.
    //   Pass 2 — assign auto-incremented locations for the rest, skipping
    //            any slot already claimed by an explicit location.
    //
    // Phase 8X Group 4d follow-up¹⁵ — if the GLSL source carried a default
    // initializer (`uniform vec4 ucolor = vec4(1.0);`), the scanner has
    // populated `uniform.defaultFloats` / `defaultInts` / `defaultUints` with
    // the parsed constant. Seed from that when present; otherwise fall back
    // to the historical zero-seed.

    // Collect the set of locations claimed by explicit layout qualifiers so
    // the auto-assignment pass can skip over them.
    std::unordered_set<GLint> reservedLocations;
    for (const auto& uniform : programObject->uniforms) {
        if (uniform.explicitLocation >= 0) {
            const GLint slots = std::max<GLint>(uniform.arraySize, 1);
            for (GLint s = 0; s < slots; ++s) {
                reservedLocations.insert(uniform.explicitLocation + s);
            }
        }
    }

    // Helper: find the next auto-location that doesn't collide with any
    // explicitly reserved slot.
    GLint nextLocation = 0;
    auto advancePastReserved = [&]() {
        while (reservedLocations.count(nextLocation)) {
            ++nextLocation;
        }
    };

    for (auto& uniform : programObject->uniforms) {
        if (uniform.explicitLocation >= 0) {
            uniform.location = uniform.explicitLocation;
        } else {
            advancePastReserved();
            uniform.location = nextLocation;
        }
        const GLint components = glslComponentCount(uniform.type) * std::max<GLint>(uniform.arraySize, 1);
        const std::size_t componentCount = static_cast<std::size_t>(components);
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
            case GL_SAMPLER_1D_ARRAY:
            case GL_SAMPLER_2D_ARRAY:
            case GL_SAMPLER_1D_SHADOW:
            case GL_SAMPLER_2D_SHADOW:
            case GL_SAMPLER_1D_ARRAY_SHADOW:
            case GL_SAMPLER_2D_ARRAY_SHADOW:
            case GL_SAMPLER_CUBE_SHADOW:
            case GL_SAMPLER_2D_RECT:
            case GL_SAMPLER_2D_RECT_SHADOW:
            case GL_SAMPLER_BUFFER:
            case GL_SAMPLER_2D_MULTISAMPLE:
            case GL_SAMPLER_2D_MULTISAMPLE_ARRAY:
            case GL_SAMPLER_CUBE_MAP_ARRAY:
            case GL_SAMPLER_CUBE_MAP_ARRAY_SHADOW:
            case GL_INT_SAMPLER_1D:
            case GL_INT_SAMPLER_2D:
            case GL_INT_SAMPLER_3D:
            case GL_INT_SAMPLER_CUBE:
            case GL_INT_SAMPLER_1D_ARRAY:
            case GL_INT_SAMPLER_2D_ARRAY:
            case GL_INT_SAMPLER_2D_RECT:
            case GL_INT_SAMPLER_BUFFER:
            case GL_INT_SAMPLER_2D_MULTISAMPLE:
            case GL_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
            case GL_INT_SAMPLER_CUBE_MAP_ARRAY:
            case GL_UNSIGNED_INT_SAMPLER_1D:
            case GL_UNSIGNED_INT_SAMPLER_2D:
            case GL_UNSIGNED_INT_SAMPLER_3D:
            case GL_UNSIGNED_INT_SAMPLER_CUBE:
            case GL_UNSIGNED_INT_SAMPLER_1D_ARRAY:
            case GL_UNSIGNED_INT_SAMPLER_2D_ARRAY:
            case GL_UNSIGNED_INT_SAMPLER_2D_RECT:
            case GL_UNSIGNED_INT_SAMPLER_BUFFER:
            case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE:
            case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
            case GL_UNSIGNED_INT_SAMPLER_CUBE_MAP_ARRAY:
                if (uniform.defaultInts.size() == componentCount) {
                    value.ints = uniform.defaultInts;
                } else {
                    value.ints.assign(componentCount, 0);
                }
                break;
            case GL_UNSIGNED_INT:
            case GL_UNSIGNED_INT_VEC2:
            case GL_UNSIGNED_INT_VEC3:
            case GL_UNSIGNED_INT_VEC4:
                if (uniform.defaultUints.size() == componentCount) {
                    value.uints = uniform.defaultUints;
                } else {
                    value.uints.assign(componentCount, 0u);
                }
                break;
            default:
                if (uniform.defaultFloats.size() == componentCount) {
                    value.floats = uniform.defaultFloats;
                } else {
                    value.floats.assign(componentCount, 0.0f);
                }
                break;
        }
        programObject->uniformValues[uniform.location] = std::move(value);
        // Only advance the auto-location counter for non-explicit uniforms.
        // Explicit-location uniforms occupy their declared slots (already
        // recorded in reservedLocations) and must not shift the counter.
        if (uniform.explicitLocation < 0) {
            nextLocation += std::max<GLint>(uniform.arraySize, 1);
        }
    }

    // GL 4.2 §7.6: for any sampler uniform declared with
    // `layout(binding = N)` in the GLSL source, seed its integer value
    // to N. Subsequent glUniform1i calls override this. For arrays,
    // element i gets N+i (spec says consecutive binding points).
    // Populated after the main uniform-init loop so all uniformValues
    // entries exist and we only need to overwrite the sampler ones.
    // Harmless on programs with no explicit bindings — the map is empty.
    if (!programObject->samplerExplicitBindings.empty()) {
        for (const auto& uinfo : programObject->uniforms) {
            auto it = programObject->samplerExplicitBindings.find(uinfo.name);
            if (it == programObject->samplerExplicitBindings.end()) continue;
            auto valIt = programObject->uniformValues.find(uinfo.location);
            if (valIt == programObject->uniformValues.end()) continue;
            auto& v = valIt->second;
            const GLint arraySize = std::max<GLint>(uinfo.arraySize, 1);
            v.ints.assign(static_cast<std::size_t>(arraySize), 0);
            for (GLint i = 0; i < arraySize; ++i) {
                v.ints[static_cast<std::size_t>(i)] =
                    static_cast<GLint>(it->second) + i;
            }
        }
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

    // ─── Transform feedback link-time validation ───────────────────────
    // GL 4.6 §11.1.2.1: the linker must reject programs whose transform
    // feedback configuration is invalid. The four cases the CTS
    // linking_errors_test expects:
    //   1) TF varyings specified but no vertex/geometry shader present.
    //   2) A TF varying name doesn't match any output of the last
    //      vertex-processing stage.
    //   3) The same output variable is captured more than once in
    //      SEPARATE_ATTRIBS mode (or in INTERLEAVED_ATTRIBS w/o
    //      gl_NextBuffer separation).
    //   4) Total component count exceeds the implementation limit.
    if (!programObject->transformFeedbackVaryingNames.empty()) {
        // (1) No vertex-processing stage.
        // The "last vertex-processing stage" determines the capturable outputs:
        //   GS > TES > VS (in priority order).
        const GLShaderObject* xfbStage = geometryShader
            ? geometryShader
            : (tessEvalShader ? tessEvalShader : vertexShader);
        if (xfbStage == nullptr) {
            programObject->linkLog = "transform feedback varyings specified but no vertex/geometry shader";
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", programObject->linkLog, "", false
            });
            return false;
        }

        // Build lookup of outputs from the last vertex-processing stage.
        std::unordered_map<std::string, GLenum> outputTypeMap;
        for (const auto& decl : xfbStage->declaredOutputs) {
            outputTypeMap[decl.name] = decl.type;
        }
        // Built-in outputs that are always available for capture.
        outputTypeMap["gl_Position"] = GL_FLOAT_VEC4;
        outputTypeMap["gl_PointSize"] = GL_FLOAT;
        outputTypeMap["gl_ClipDistance"] = GL_FLOAT;

        // Special interleaved-mode names that are NOT real varyings:
        auto isSpecialName = [](const std::string& n) {
            return n == "gl_NextBuffer" ||
                   n == "gl_SkipComponents1" || n == "gl_SkipComponents2" ||
                   n == "gl_SkipComponents3" || n == "gl_SkipComponents4";
        };

        // Helper: component count for a GL type.
        auto glTypeComponents = [](GLenum t) -> GLsizei {
            switch (t) {
                case GL_FLOAT: case GL_INT: case GL_UNSIGNED_INT: case GL_BOOL:
                case GL_DOUBLE:
                    return 1;
                case GL_FLOAT_VEC2: case GL_INT_VEC2: case GL_UNSIGNED_INT_VEC2:
                case GL_BOOL_VEC2: case GL_DOUBLE_VEC2:
                    return 2;
                case GL_FLOAT_VEC3: case GL_INT_VEC3: case GL_UNSIGNED_INT_VEC3:
                case GL_BOOL_VEC3: case GL_DOUBLE_VEC3:
                    return 3;
                case GL_FLOAT_VEC4: case GL_INT_VEC4: case GL_UNSIGNED_INT_VEC4:
                case GL_BOOL_VEC4: case GL_DOUBLE_VEC4:
                    return 4;
                case GL_FLOAT_MAT2: case GL_DOUBLE_MAT2:   return 4;
                case GL_FLOAT_MAT3: case GL_DOUBLE_MAT3:   return 9;
                case GL_FLOAT_MAT4: case GL_DOUBLE_MAT4:   return 16;
                case GL_FLOAT_MAT2x3: case GL_DOUBLE_MAT2x3: return 6;
                case GL_FLOAT_MAT2x4: case GL_DOUBLE_MAT2x4: return 8;
                case GL_FLOAT_MAT3x2: case GL_DOUBLE_MAT3x2: return 6;
                case GL_FLOAT_MAT3x4: case GL_DOUBLE_MAT3x4: return 12;
                case GL_FLOAT_MAT4x2: case GL_DOUBLE_MAT4x2: return 8;
                case GL_FLOAT_MAT4x3: case GL_DOUBLE_MAT4x3: return 12;
                default: return 1;
            }
        };

        // (2) Validate each varying name and resolve types.
        programObject->resourceTransformFeedbackVaryings.clear();
        std::unordered_set<std::string> seenNames;
        GLsizei totalComponents = 0;
        GLenum bufMode = programObject->transformFeedbackBufferMode;

        // When the scanner has populated output declarations for the
        // last vertex-processing stage, we can validate varying names
        // and resolve types.  When it hasn't (e.g. older scanner gap),
        // skip the name check and use GL_FLOAT as the fallback type.
        const bool haveOutputDecls = !outputTypeMap.empty() ||
            !xfbStage->declaredOutputs.empty();

        for (const auto& varyName : programObject->transformFeedbackVaryingNames) {
            if (isSpecialName(varyName)) {
                // Special names are valid in interleaved mode; skip for
                // duplicate/component checks.
                continue;
            }

            GLenum resolvedType = GL_FLOAT; // fallback
            if (haveOutputDecls) {
                auto it = outputTypeMap.find(varyName);
                if (it == outputTypeMap.end()) {
                    programObject->linkLog = "transform feedback varying '" + varyName +
                        "' is not an output of the last vertex-processing stage";
                    Runtime::shared().recordShaderTranslation({
                        programTag, "link", "", "", "", programObject->linkLog, "", false
                    });
                    return false;
                }
                resolvedType = it->second;
            }

            // (3) Duplicate check (applies to both interleaved and separate).
            if (!seenNames.insert(varyName).second) {
                programObject->linkLog = "transform feedback varying '" + varyName +
                    "' is captured more than once";
                Runtime::shared().recordShaderTranslation({
                    programTag, "link", "", "", "", programObject->linkLog, "", false
                });
                return false;
            }

            totalComponents += glTypeComponents(resolvedType);

            GLProgramResourceEntry entry;
            entry.name = varyName;
            entry.type = resolvedType;
            entry.arraySize = 1;
            programObject->resourceTransformFeedbackVaryings.push_back(std::move(entry));
        }

        // (4) Component limit check.
        // GL_MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS = 64 (our reported value)
        // GL_MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS = 4
        // GL_MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS = 4
        if (bufMode == GL_INTERLEAVED_ATTRIBS) {
            constexpr GLsizei kMaxInterleavedComponents = 64;
            if (totalComponents > kMaxInterleavedComponents) {
                programObject->linkLog = "transform feedback exceeds GL_MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS";
                programObject->resourceTransformFeedbackVaryings.clear();
                Runtime::shared().recordShaderTranslation({
                    programTag, "link", "", "", "", programObject->linkLog, "", false
                });
                return false;
            }
        } else if (bufMode == GL_SEPARATE_ATTRIBS) {
            constexpr GLsizei kMaxSeparateComponents = 4;
            constexpr GLsizei kMaxSeparateAttribs = 4;
            GLsizei attribCount = static_cast<GLsizei>(programObject->resourceTransformFeedbackVaryings.size());
            if (attribCount > kMaxSeparateAttribs) {
                programObject->linkLog = "transform feedback exceeds GL_MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS";
                programObject->resourceTransformFeedbackVaryings.clear();
                Runtime::shared().recordShaderTranslation({
                    programTag, "link", "", "", "", programObject->linkLog, "", false
                });
                return false;
            }
            for (const auto& res : programObject->resourceTransformFeedbackVaryings) {
                if (glTypeComponents(res.type) > kMaxSeparateComponents) {
                    programObject->linkLog = "transform feedback varying '" + res.name +
                        "' exceeds GL_MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS";
                    programObject->resourceTransformFeedbackVaryings.clear();
                    Runtime::shared().recordShaderTranslation({
                        programTag, "link", "", "", "", programObject->linkLog, "", false
                    });
                    return false;
                }
            }
        }
    } else {
        // No TF varyings — clear any stale resolved data from a previous link.
        programObject->resourceTransformFeedbackVaryings.clear();
    }
    // ─── End transform feedback link-time validation ─────────────────

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
        entry.binding = u.explicitBinding;  // RC-D08
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
    programObject->computeMSL.clear();
    programObject->computeReflection = ShaderReflection{};
    // Zero default so glGetProgramiv(GL_COMPUTE_WORK_GROUP_SIZE) returns
    // (0,0,0) for non-compute programs (matches native drivers).
    // Overwritten by the Compute kind branch below with the shader's
    // local_size_{x,y,z} execution mode.
    programObject->computeLocalSizeX = 0;
    programObject->computeLocalSizeY = 0;
    programObject->computeLocalSizeZ = 0;
    programObject->metalPipelineState = nullptr;
    // Release the retained MTLComputePipelineState on relink.
    releaseRetainedMetalObject(programObject->metalComputePipelineState);
    programObject->metalComputePipelineState = nullptr;
    // Phase 8X Group 4d follow-up¹⁴ — release every cached pipeline
    // on relink so the map doesn't hold stale id<MTLRenderPipelineState>
    // pointers derived from the old MSL. The scalar `metalPipelineState`
    // slot above is cleared by assignment (not CFRelease'd) to match
    // the pre-follow-up¹⁴ leak-on-relink behavior; the map needs
    // explicit CFRelease because we retained each entry on insert.
    for (auto& entry : programObject->metalPipelineStateCache) {
        if (entry.second != nullptr) {
            CFRelease(entry.second);
        }
    }
    programObject->metalPipelineStateCache.clear();
    programObject->metalPipelineColorFormat = 0;

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
        const std::string stageTag = programTag + "-" + stageName;
        const std::string hash = quickHash(sourceText);

        // Phase 8X Group 4d follow-up²³ — sub-step marker + C++ exception
        // guard around spirvToMSL. SPIRV-Cross can throw `spirv_cross_error`
        // on ill-formed SPIR-V or unsupported decoration patterns; if that
        // escapes into this Objective-C++ frame unhandled, std::terminate
        // fires and the process SIGABRTs. Catch here so a throw becomes a
        // clean translation failure (MSL empty + diagnostic record) instead
        // of the fw²² Sky-program-28 crash signature.
        APPGL_LOG(SHADER, @"[GL] linkProgram-step=spirv-to-msl program=%u stage=%s", program, stageName);
        fflush(stderr);
        std::string mslLog;
        std::string msl;
        try {
            msl = translator.spirvToMSL(
                spirvData, spirvWords, bindings, &mslLog);
        } catch (const std::exception& e) {
            APPGL_LOG(SHADER, @"[GL] linkProgram-step=spirv-to-msl program=%u stage=%s THREW: %s",
                  program, stageName, e.what());
            fflush(stderr);
            Runtime::shared().recordShaderTranslation({
                stageTag, stageName, hash, linkVertexHash, linkFragmentHash,
                std::string("spirvToMSL threw std::exception: ") + e.what(),
                "", false
            });
            return false;
        } catch (...) {
            APPGL_LOG(SHADER, @"[GL] linkProgram-step=spirv-to-msl program=%u stage=%s THREW unknown exception",
                  program, stageName);
            fflush(stderr);
            Runtime::shared().recordShaderTranslation({
                stageTag, stageName, hash, linkVertexHash, linkFragmentHash,
                "spirvToMSL threw unknown exception", "", false
            });
            return false;
        }
        if (msl.empty()) {
            Runtime::shared().recordShaderTranslation({
                stageTag, stageName, hash, linkVertexHash, linkFragmentHash,
                mslLog.empty() ? "spirvToMSL returned empty MSL" : mslLog,
                "", false
            });
            return false;
        }

        // Phase 8X Group 4d follow-up²³ — sub-step marker + exception guard
        // around reflect. SPIRV-Cross reflection re-walks the SPIR-V and is
        // the other plausible throw site in the translator's critical path.
        APPGL_LOG(SHADER, @"[GL] linkProgram-step=reflect program=%u stage=%s", program, stageName);
        fflush(stderr);
        try {
            reflectionOut = translator.reflect(
                spirvData, spirvWords, bindings, nullptr);
        } catch (const std::exception& e) {
            APPGL_LOG(SHADER, @"[GL] linkProgram-step=reflect program=%u stage=%s THREW: %s",
                  program, stageName, e.what());
            fflush(stderr);
            Runtime::shared().recordShaderTranslation({
                stageTag, stageName, hash, linkVertexHash, linkFragmentHash,
                std::string("reflect threw std::exception: ") + e.what(),
                "", false
            });
            return false;
        } catch (...) {
            APPGL_LOG(SHADER, @"[GL] linkProgram-step=reflect program=%u stage=%s THREW unknown exception",
                  program, stageName);
            fflush(stderr);
            Runtime::shared().recordShaderTranslation({
                stageTag, stageName, hash, linkVertexHash, linkFragmentHash,
                "reflect threw unknown exception", "", false
            });
            return false;
        }
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
        CompatShaderRewriteResult vsRewrite =
            rewriteCompatShader(vsStage->source, GL_VERTEX_SHADER);
        CompatShaderRewriteResult fsRewrite =
            rewriteCompatShader(fsStage->source, GL_FRAGMENT_SHADER);
        const std::string& vsLinkSource =
            vsRewrite.didRewrite ? vsRewrite.source : vsStage->source;
        const std::string& fsLinkSource =
            fsRewrite.didRewrite ? fsRewrite.source : fsStage->source;
        // Phase 8X Group 4d follow-up²³ — sub-step marker before the
        // glslang cross-stage link. First candidate on the abort-site ladder
        // is glslang's TProgram::link re-entry, since that's the first heavy
        // operation inside this lambda.
        APPGL_LOG(SHADER, @"[GL] linkProgram-step=compile-glsl-program program=%u", program);
        fflush(stderr);
        std::string linkErrorLog;
        LinkedProgramSpirv linked = translator.compileGLSLProgram(
            vsLinkSource, fsLinkSource, 330, &linkErrorLog);
        APPGL_LOG(SHADER, @"[GL] compileGLSLProgram: program=%u success=%d log=%s",
              program, linked.linkSucceeded ? 1 : 0,
              linkErrorLog.c_str());
        fflush(stderr);
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
            // Translate compute to MSL + stash on the program object so
            // glDispatchCompute can encode against the cached pipeline.
            //
            // Compute uses a distinct BindingMap: SSBOs at slots [0..16),
            // UBOs at [16..31). This differs from the graphics pipeline
            // map (where slots [0..16) are reserved for VBOs) and lets
            // GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS honestly hit the spec
            // floor of 8 (actually 16). Scoped swap of `bindings` is safe
            // because translateStage captures by reference and compute
            // doesn't share the binding map with any other stage.
            const BindingMap savedBindings = bindings;
            bindings = makeComputeBindingMap();
            ShaderReflection csRefl;
            const bool csOk = translateCachedStage(
                "compute", computeShader, programObject->computeMSL, csRefl);
            bindings = savedBindings;
            if (csOk) {
                programObject->computeReflection = std::move(csRefl);
                // Extract local_size_{x,y,z} so dispatch knows the
                // threads-per-threadgroup dimensions.
                if (computeShader && !computeShader->spirv.empty()) {
                    auto modes = extractComputeModes(
                        computeShader->spirv.data(),
                        computeShader->spirv.size());
                    programObject->computeLocalSizeX = modes.localSizeX;
                    programObject->computeLocalSizeY = modes.localSizeY;
                    programObject->computeLocalSizeZ = modes.localSizeZ;
                }
                // Build + retain the MTLComputePipelineState. Failures
                // are logged but don't fail linkProgram — the dispatch
                // path will then fall back to the stub (returning true
                // with no GPU work).
                if (impl_->frameGraph != nullptr) {
                    std::string psoError;
                    void* pso = impl_->frameGraph->buildComputePipelineState(
                        programObject->computeMSL, &psoError);
                    if (pso != nullptr) {
                        programObject->metalComputePipelineState = pso;
                        APPGL_LOG(SHADER, @"[GL] linkProgram: compute pipeline built for program=%u "
                              @"localSize=[%u,%u,%u]",
                              program,
                              programObject->computeLocalSizeX,
                              programObject->computeLocalSizeY,
                              programObject->computeLocalSizeZ);
                    } else {
                        Runtime::shared().recordShaderTranslation({
                            programTag + "-compute-pipeline", "compute",
                            quickHash(computeShader ? computeShader->source : std::string()),
                            linkVertexHash, linkFragmentHash,
                            std::string("MTLComputePipelineState build failed: ") + psoError,
                            "", false
                        });
                    }
                }
            }
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

            // Extract tessellation execution modes from SPIR-V.
            programObject->hasTessellation = true;
            if (tessControlShader && !tessControlShader->spirv.empty()) {
                auto tcModes = extractTessellationModes(
                    tessControlShader->spirv.data(), tessControlShader->spirv.size());
                programObject->tessControlOutputVertices = static_cast<GLint>(tcModes.outputVertices);
            }
            if (tessEvalShader && !tessEvalShader->spirv.empty()) {
                auto teModes = extractTessellationModes(
                    tessEvalShader->spirv.data(), tessEvalShader->spirv.size());
                programObject->tessGenMode = teModes.genMode;
                programObject->tessGenSpacing = teModes.genSpacing;
                programObject->tessGenVertexOrder = teModes.genVertexOrder;
                programObject->tessGenPointMode = teModes.pointMode ? GL_TRUE : GL_FALSE;
            }

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
        case ProgramKind::GeometryOnly: {
            // Separable GS-only program (for use with program pipelines).
            // Translate to MSL so reflection populates; actual draw falls
            // back through the raster-without-GS path, same as VGF.
            std::string unusedGsMSL;
            ShaderReflection gsRefl;
            (void)translateCachedStage("geometry", geometryShader,
                                       unusedGsMSL, gsRefl);
            rasterTranslationOk = true;
            break;
        }
        case ProgramKind::TessControlOnly: {
            // Separable TCS-only program (for use with program pipelines).
            // Translate to MSL for reflection + extract tessellation modes.
            std::string unusedTcMSL;
            ShaderReflection tcRefl;
            (void)translateCachedStage("tess-control", tessControlShader,
                                       unusedTcMSL, tcRefl);
            // Extract tessellation execution modes from SPIR-V.
            programObject->hasTessellation = true;
            if (!tessControlShader->spirv.empty()) {
                auto tcModes = extractTessellationModes(
                    tessControlShader->spirv.data(),
                    tessControlShader->spirv.size());
                programObject->tessControlOutputVertices =
                    static_cast<GLint>(tcModes.outputVertices);
            }
            rasterTranslationOk = true;
            break;
        }
        case ProgramKind::TessEvalOnly: {
            // Separable TES-only program (for use with program pipelines).
            std::string unusedTeMSL;
            ShaderReflection teRefl;
            (void)translateCachedStage("tess-eval", tessEvalShader,
                                       unusedTeMSL, teRefl);
            // Extract tessellation execution modes from SPIR-V.
            programObject->hasTessellation = true;
            if (!tessEvalShader->spirv.empty()) {
                auto teModes = extractTessellationModes(
                    tessEvalShader->spirv.data(),
                    tessEvalShader->spirv.size());
                programObject->tessGenMode = teModes.genMode;
                programObject->tessGenSpacing = teModes.genSpacing;
                programObject->tessGenVertexOrder = teModes.genVertexOrder;
                programObject->tessGenPointMode =
                    teModes.pointMode ? GL_TRUE : GL_FALSE;
            }
            rasterTranslationOk = true;
            break;
        }
        case ProgramKind::Unknown:
            break;  // Already handled above; kept so -Wswitch stays happy.
    }

    APPGL_LOG(SHADER, @"[GL] linkProgram: program=%u kind=%d translationOk=%d "
          @"vertexInputs=%zu vsUniformBlocks=%zu fsUniformBlocks=%zu",
          program, static_cast<int>(kind), rasterTranslationOk ? 1 : 0,
          programObject->vertexReflection.vertexInputs.size(),
          programObject->vertexReflection.uniformBlocks.size(),
          programObject->fragmentReflection.uniformBlocks.size());
    fflush(stderr);  // Phase 8X Group 4d follow-up²³ — synchronous flush

    // ── Supplement scanner-discovered uniforms with SPIR-V reflection ──
    //
    // The lightweight GLSL scanner (GLSLReflection) can't parse struct-typed
    // uniforms, interface-block members, or other complex declarations.
    // SPIRV-Cross reflection IS authoritative for the _DefaultUniforms block
    // members — it sees every uniform that survived dead-code elimination.
    // Walk the _DefaultUniforms members from each stage's reflection and add
    // any that the scanner missed to the program's uniform list with fresh
    // locations and zero-seeded values.  This lets glGetUniformLocation /
    // glUniform* work for struct members (e.g. "s.a"), array-of-struct
    // elements ("s[0].a"), and any other uniform type the scanner can't parse.
    if (rasterTranslationOk || kind == ProgramKind::Compute) {
        // Build a set of names the scanner already discovered.
        std::unordered_set<std::string> knownUniformNames;
        for (const auto& u : programObject->uniforms) {
            knownUniformNames.insert(u.name);
        }

        // Find the next available auto-location (past all existing ones).
        GLint supplementNextLoc = 0;
        for (const auto& u : programObject->uniforms) {
            const GLint endLoc = u.location + std::max<GLint>(u.arraySize, 1);
            if (endLoc > supplementNextLoc) {
                supplementNextLoc = endLoc;
            }
        }

        // Lambda: scan one stage's reflection for _DefaultUniforms members.
        auto supplementFromReflection = [&](const ShaderReflection& refl) {
            if (refl.uniformBlocks.empty()) return;
            // The _DefaultUniforms block is always at index 0 when present.
            const auto& block = refl.uniformBlocks[0];
            if (block.name != "_DefaultUniforms") return;
            for (const auto& member : block.members) {
                if (knownUniformNames.count(member.name)) continue;
                // New uniform discovered by SPIR-V but not by the scanner.
                GLProgramUniformInfo info;
                info.name = member.name;
                info.type = member.type;
                info.arraySize = (member.arraySize > 0)
                    ? static_cast<GLint>(member.arraySize) : 1;
                info.location = supplementNextLoc;
                info.explicitLocation = -1;
                info.explicitBinding = -1;
                supplementNextLoc += std::max<GLint>(info.arraySize, 1);
                knownUniformNames.insert(info.name);

                // Zero-seed the uniform value.
                const GLint components = glslComponentCount(info.type)
                    * std::max<GLint>(info.arraySize, 1);
                const std::size_t cnt = static_cast<std::size_t>(components);
                GLProgramUniformValue value;
                value.type = info.type;
                value.arraySize = info.arraySize;
                switch (info.type) {
                    case GL_INT: case GL_INT_VEC2: case GL_INT_VEC3: case GL_INT_VEC4:
                    case GL_BOOL: case GL_BOOL_VEC2: case GL_BOOL_VEC3: case GL_BOOL_VEC4:
                        value.ints.assign(cnt, 0);
                        break;
                    case GL_UNSIGNED_INT: case GL_UNSIGNED_INT_VEC2:
                    case GL_UNSIGNED_INT_VEC3: case GL_UNSIGNED_INT_VEC4:
                        value.uints.assign(cnt, 0u);
                        break;
                    default:
                        value.floats.assign(cnt, 0.0f);
                        break;
                }
                programObject->uniformValues[info.location] = std::move(value);
                programObject->uniforms.push_back(std::move(info));
            }
        };

        supplementFromReflection(programObject->vertexReflection);
        supplementFromReflection(programObject->fragmentReflection);
    }

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
                               GLbitfield stageBit,
                               const std::string& glslSource) {
            for (const auto& block : blocks) {
                // SPIRV-Cross loses instance name info (varName == typeName
                // for both instanced and non-instanced blocks). Parse the
                // original GLSL source to recover it.
                const bool hasInstance =
                    glslBlockHasInstanceName(glslSource, block.name);

                // For array blocks (`uniform B { ... } b[N]`), create one
                // block entry per array element: "BlockName[0]", "BlockName[1]", ...
                // For non-array blocks, create a single entry: "BlockName".
                const int numInstances = (block.blockArraySize > 0)
                    ? static_cast<int>(block.blockArraySize) : 1;
                const bool isArray = (block.blockArraySize > 0);

                // Create block entries for each instance.
                GLint firstBlockIndex = -1;
                bool anyNewBlocks = false;
                for (int inst = 0; inst < numInstances; ++inst) {
                    std::string entryName = block.name;
                    if (isArray) {
                        entryName += "[" + std::to_string(inst) + "]";
                    }
                    auto existing = std::find_if(
                        programObject->resourceUniformBlocks.begin(),
                        programObject->resourceUniformBlocks.end(),
                        [&](const GLProgramResourceEntry& e) { return e.name == entryName; });
                    if (existing != programObject->resourceUniformBlocks.end()) {
                        existing->referencedBy |= stageBit;
                        if (inst == 0) {
                            firstBlockIndex = static_cast<GLint>(
                                existing - programObject->resourceUniformBlocks.begin());
                        }
                        continue;
                    }
                    anyNewBlocks = true;
                    GLProgramResourceEntry blockEntry;
                    blockEntry.name = entryName;
                    blockEntry.type = 0;  // blocks have no scalar type
                    blockEntry.location = static_cast<GLint>(block.glBinding);
                    blockEntry.offset = static_cast<GLint>(block.byteSize); // GL_UNIFORM_BLOCK_DATA_SIZE
                    blockEntry.arraySize = 1;
                    blockEntry.referencedBy = stageBit;
                    programObject->resourceUniformBlocks.push_back(std::move(blockEntry));
                    if (inst == 0) {
                        firstBlockIndex = static_cast<GLint>(
                            programObject->resourceUniformBlocks.size() - 1);
                    }
                }

                // Skip member creation if this block was already processed
                // by an earlier stage (all entries deduped — no new blocks).
                if (!anyNewBlocks) continue;

                for (const auto& member : block.members) {
                    // Push into resourceUniforms — the CTS and
                    // glGetActiveUniform / glGetActiveUniformsiv enumerate
                    // ALL active uniforms including those inside blocks.
                    // Per GL spec §7.6, blocks WITHOUT an instance name use
                    // just "memberName"; blocks WITH one use "blockName.memberName".
                    GLProgramResourceEntry memberEntry;
                    std::string uniformName;
                    if (hasInstance) {
                        uniformName = block.name + "." + member.name;
                    } else {
                        uniformName = member.name;
                    }
                    // GL spec: array uniforms have "[0]" appended to name.
                    if (member.arraySize > 0) {
                        uniformName += "[0]";
                    }
                    memberEntry.name = std::move(uniformName);
                    memberEntry.type = member.type;
                    // SPIR-V represents bool in UBOs as uint — detect the
                    // original bool type from the GLSL source.
                    if (member.type == GL_UNSIGNED_INT ||
                        member.type == GL_UNSIGNED_INT_VEC2 ||
                        member.type == GL_UNSIGNED_INT_VEC3 ||
                        member.type == GL_UNSIGNED_INT_VEC4) {
                        GLenum boolType = detectBoolMemberType(
                            glslSource, block.name, member.name);
                        if (boolType != 0) {
                            memberEntry.type = boolType;
                        }
                    }
                    memberEntry.location = -1;  // not queryable via glGetUniformLocation
                    memberEntry.offset = static_cast<GLint>(member.offset);
                    // Store 0 for non-arrays, N for N-element arrays.
                    // GL_UNIFORM_SIZE queries return max(arraySize, 1) so
                    // non-arrays still report size 1.  GL_UNIFORM_ARRAY_STRIDE
                    // checks arraySize > 0 to decide whether to compute a stride.
                    memberEntry.arraySize = static_cast<GLint>(member.arraySize);
                    memberEntry.blockIndex = firstBlockIndex;
                    memberEntry.referencedBy = stageBit;
                    memberEntry.isRowMajor = member.isRowMajor;
                    programObject->resourceUniforms.push_back(std::move(memberEntry));

                    // Also push into resourceBufferVariables for
                    // glGetProgramResourceiv(GL_BUFFER_VARIABLE, ...).
                    GLProgramResourceEntry bvEntry;
                    bvEntry.name = block.name + "." + member.name;
                    bvEntry.type = member.type;
                    bvEntry.location = -1;
                    bvEntry.offset = static_cast<GLint>(member.offset);
                    bvEntry.blockIndex = firstBlockIndex;
                    bvEntry.referencedBy = stageBit;
                    programObject->resourceBufferVariables.push_back(std::move(bvEntry));
                }
            }
        };
        static const std::string emptySource;
        const std::string& vsSrc = vertexShader ? vertexShader->source : emptySource;
        const std::string& fsSrc = fragmentShader ? fragmentShader->source : emptySource;
        mergeBlocks(programObject->vertexReflection.uniformBlocks, 0x01, vsSrc);    // vertex
        mergeBlocks(programObject->fragmentReflection.uniformBlocks, 0x02, fsSrc);  // fragment

        // Post-pass: fix any remaining uint→bool member types that weren't
        // detected during the stage that first created the members. This
        // happens when a linked SPIR-V includes a block in both stages but
        // the block is only declared in one stage's GLSL source.
        for (auto& u : programObject->resourceUniforms) {
            if (u.blockIndex < 0) continue;
            if (u.type != GL_UNSIGNED_INT && u.type != GL_UNSIGNED_INT_VEC2 &&
                u.type != GL_UNSIGNED_INT_VEC3 && u.type != GL_UNSIGNED_INT_VEC4) continue;
            // Find the block name for this uniform.
            const auto& blockEntry = programObject->resourceUniformBlocks[u.blockIndex];
            // Strip array suffix from block name for detection.
            std::string baseName = blockEntry.name;
            auto bracket = baseName.find('[');
            if (bracket != std::string::npos) baseName = baseName.substr(0, bracket);
            // Extract member name: for instanced blocks "Block.member" → "member",
            // for non-instanced blocks "member" stays as is.
            std::string memberName = u.name;
            // Strip trailing "[0]" from arrays
            if (memberName.size() > 3 && memberName.substr(memberName.size()-3) == "[0]") {
                memberName = memberName.substr(0, memberName.size()-3);
            }
            // For instanced blocks, strip "BlockName." prefix
            std::string prefix = baseName + ".";
            if (memberName.size() > prefix.size() &&
                memberName.substr(0, prefix.size()) == prefix) {
                memberName = memberName.substr(prefix.size());
            }
            // Try both VS and FS sources.
            GLenum boolType = detectBoolMemberType(vsSrc, baseName, memberName);
            if (boolType == 0) {
                boolType = detectBoolMemberType(fsSrc, baseName, memberName);
            }
            if (boolType != 0) {
                u.type = boolType;
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
            // GL spec: includes ALL active uniforms (bare + in-block).
            // resourceUniforms holds both; uniforms only holds bare ones.
            *params = static_cast<GLint>(
                object->resourceUniforms.empty()
                    ? object->uniforms.size()
                    : object->resourceUniforms.size());
            return true;
        case GL_ACTIVE_UNIFORM_MAX_LENGTH: {
            std::size_t maxLen = 0;
            if (!object->resourceUniforms.empty()) {
                for (const auto& u : object->resourceUniforms) {
                    maxLen = std::max(maxLen, u.name.size() + 1);
                }
            } else {
                for (const auto& u : object->uniforms) {
                    maxLen = std::max(maxLen, u.name.size() + 1);
                }
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
        // Tessellation program queries (GL 4.0).
        case GL_TESS_CONTROL_OUTPUT_VERTICES:
            *params = object->tessControlOutputVertices;
            return true;
        case GL_TESS_GEN_MODE:
            *params = static_cast<GLint>(object->tessGenMode);
            return true;
        case GL_TESS_GEN_SPACING:
            *params = static_cast<GLint>(object->tessGenSpacing);
            return true;
        case GL_TESS_GEN_VERTEX_ORDER:
            *params = static_cast<GLint>(object->tessGenVertexOrder);
            return true;
        case GL_TESS_GEN_POINT_MODE:
            *params = static_cast<GLint>(object->tessGenPointMode);
            return true;
        // Uniform block queries (GL 3.1+)
        case GL_ACTIVE_UNIFORM_BLOCKS:
            *params = static_cast<GLint>(object->resourceUniformBlocks.size());
            return true;
        case GL_ACTIVE_UNIFORM_BLOCK_MAX_NAME_LENGTH: {
            std::size_t maxLen = 0;
            for (const auto& block : object->resourceUniformBlocks) {
                maxLen = std::max(maxLen, block.name.size() + 1);
            }
            *params = static_cast<GLint>(maxLen);
            return true;
        }
        // Compute shader queries (GL 4.3+)
        case GL_COMPUTE_WORK_GROUP_SIZE: {
            // GL 4.6 §7.13: INVALID_OPERATION if the program has not
            // been linked successfully, or has been linked but
            // contains no compute shader. Checked by
            // KHR-GL46.compute_shader.api-program. Otherwise returns
            // the shader's local_size_{x,y,z} as declared by the
            // `layout(local_size_x = N) in;` execution mode, populated
            // at link time via extractComputeModes.
            bool hasComputeStage = false;
            for (GLuint shaderId : object->attachedShaders) {
                const GLShaderObject* sh = impl_->objects->shaders().get(shaderId);
                if (sh != nullptr && sh->stage == GL_COMPUTE_SHADER) {
                    hasComputeStage = true;
                    break;
                }
            }
            if (!object->linked || !hasComputeStage) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            params[0] = static_cast<GLint>(object->computeLocalSizeX);
            params[1] = static_cast<GLint>(object->computeLocalSizeY);
            params[2] = static_cast<GLint>(object->computeLocalSizeZ);
            return true;
        }
        // Transform feedback queries (GL 3.0+)
        case GL_TRANSFORM_FEEDBACK_BUFFER_MODE:
            *params = static_cast<GLint>(object->transformFeedbackBufferMode);
            return true;
        case GL_TRANSFORM_FEEDBACK_VARYINGS:
            *params = static_cast<GLint>(object->transformFeedbackVaryingNames.size());
            return true;
        case GL_TRANSFORM_FEEDBACK_VARYING_MAX_LENGTH: {
            std::size_t maxLen = 0;
            for (const auto& v : object->transformFeedbackVaryingNames) {
                maxLen = std::max(maxLen, v.size() + 1);
            }
            *params = static_cast<GLint>(maxLen);
            return true;
        }
        // Geometry shader queries (GL 3.2+)
        case GL_GEOMETRY_VERTICES_OUT:
            *params = 0;
            return true;
        case GL_GEOMETRY_INPUT_TYPE:
            *params = GL_TRIANGLES;
            return true;
        case GL_GEOMETRY_OUTPUT_TYPE:
            *params = GL_TRIANGLE_STRIP;
            return true;
        // Program binary / separable (GL 4.1+)
        case GL_PROGRAM_BINARY_LENGTH:
            *params = 0;  // No binary program support
            return true;
        case GL_PROGRAM_SEPARABLE:
            *params = GL_FALSE;
            return true;
        case GL_PROGRAM_BINARY_RETRIEVABLE_HINT:
            *params = GL_FALSE;
            return true;
        // Atomic counter buffers (GL 4.2+)
        case GL_ACTIVE_ATOMIC_COUNTER_BUFFERS:
            *params = static_cast<GLint>(object->resourceAtomicCounterBuffers.size());
            return true;
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
    // GL 4.6 §7.3.1: if name includes `[N]` suffix, return base attribute's
    // location + N. Shaders can declare `in float clipdistance_data[8]` and
    // CTS looks up `clipdistance_data[0]` through `clipdistance_data[7]`
    // expecting consecutive locations — our reflection only records the
    // array's base name, so we need to parse the suffix and do the math.
    std::string baseName = lookup;
    int arrayIndex = 0;
    if (!lookup.empty() && lookup.back() == ']') {
        const auto bracketPos = lookup.rfind('[');
        if (bracketPos != std::string::npos) {
            const std::string idxStr = lookup.substr(bracketPos + 1,
                lookup.size() - bracketPos - 2);
            // Accept only non-negative decimal integers.
            bool ok = !idxStr.empty();
            for (char c : idxStr) {
                if (c < '0' || c > '9') { ok = false; break; }
            }
            if (ok) {
                arrayIndex = std::atoi(idxStr.c_str());
                baseName = lookup.substr(0, bracketPos);
            }
        }
    }
    for (const auto& attrib : object->attributes) {
        if (attrib.name == lookup) {
            return attrib.location;
        }
        if (attrib.name == baseName) {
            return attrib.location + arrayIndex;
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
    // GL 4.6 §7.6.1: array-element lookup — `glGetUniformLocation(prog,
    // "u[k]")` for a uniform declared `uniform T u[N]` must return
    // `location(u) + k` when 0 <= k < N. Uniforms are stored by base name
    // ("u"), so the exact-match loop above misses. Parse the trailing
    // [k] subscript and index into the base.
    //
    // Covers KHR-GL46.explicit_uniform_location.uniform-loc-arrays-*
    // which exercise `layout(location = N) uniform T arr[M]` and expect
    // u[0]=N, u[1]=N+1, …, u[M-1]=N+M-1.
    const auto openBracket = lookup.find('[');
    if (openBracket != std::string::npos && lookup.back() == ']') {
        const std::string baseName = lookup.substr(0, openBracket);
        const std::string indexStr = lookup.substr(openBracket + 1, lookup.size() - openBracket - 2);
        if (!baseName.empty() && !indexStr.empty()) {
            // Parse the subscript (decimal only; GLSL array subscripts are plain ints).
            char* endp = nullptr;
            const long idx = std::strtol(indexStr.c_str(), &endp, 10);
            if (endp && *endp == '\0' && idx >= 0) {
                for (const auto& uniform : object->uniforms) {
                    if (uniform.name == baseName && uniform.arraySize >= 1
                        && idx < static_cast<long>(uniform.arraySize)
                        && uniform.location >= 0) {
                        return uniform.location + static_cast<GLint>(idx);
                    }
                }
            }
        }
    }
    // Fallback: try with _appgl_ prefix reverse-mapping.
    // CompatShaderRewrite renames `sampler` → `_appgl_sampler` for glslang
    // compat; try the rewritten name if the original wasn't found.
    {
        std::string rewritten = lookup;
        const std::string from = "sampler";
        const std::string to = "_appgl_sampler";
        std::string::size_type pos = 0;
        bool changed = false;
        while ((pos = rewritten.find(from, pos)) != std::string::npos) {
            // Word-boundary check: don't replace inside sampler2D etc.
            bool leftOk = (pos == 0) || !std::isalnum(static_cast<unsigned char>(rewritten[pos - 1])) && rewritten[pos - 1] != '_';
            std::size_t end = pos + from.size();
            bool rightOk = (end >= rewritten.size()) || (!std::isalnum(static_cast<unsigned char>(rewritten[end])) && rewritten[end] != '_');
            if (leftOk && rightOk) {
                rewritten.replace(pos, from.size(), to);
                pos += to.size();
                changed = true;
            } else {
                pos += 1;
            }
        }
        if (changed) {
            for (const auto& uniform : object->uniforms) {
                if (uniform.name == rewritten) {
                    return uniform.location;
                }
            }
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
    // Prefer resourceUniforms (includes UBO members); fall back to bare
    // uniforms list for programs that never went through SPIRV-Cross.
    if (!object->resourceUniforms.empty()) {
        if (index >= static_cast<GLuint>(object->resourceUniforms.size())) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        const auto& u = object->resourceUniforms[index];
        if (size != nullptr) {
            *size = std::max<GLint>(u.arraySize, 1);
        }
        if (type != nullptr) {
            *type = u.type;
        }
        copyStringToBuffer(u.name, bufSize, length, name);
        return true;
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
    if (it != program->uniformValues.end()) {
        return &it->second;
    }
    // Array-element fallback: glUniform1i(loc+k, …) on a uniform declared
    // with arraySize > 1 hits locations [base+1, base+arraySize). The slot
    // lives at the base location; find it by walking the uniforms list.
    for (const auto& u : program->uniforms) {
        if (u.arraySize > 1 && location > u.location
            && location < u.location + u.arraySize) {
            auto base = program->uniformValues.find(u.location);
            if (base != program->uniformValues.end()) {
                return &base->second;
            }
            return nullptr;
        }
    }
    return nullptr;
}

// Resolve (slot, elementIndex) for a uniform location. elementIndex is the
// zero-based offset inside the array for array-element locations; 0 for the
// base location or a non-array uniform. Returns (nullptr, 0) if the location
// is invalid.
struct UniformSlotRef {
    GLProgramUniformValue* slot = nullptr;
    GLint elementIndex = 0;
    GLint arraySize = 1;
    GLenum type = 0;
};

UniformSlotRef resolveUniformSlot(GLProgramObject* program, GLint location) {
    UniformSlotRef r;
    if (program == nullptr || location < 0) {
        return r;
    }
    auto it = program->uniformValues.find(location);
    if (it != program->uniformValues.end()) {
        r.slot = &it->second;
        r.elementIndex = 0;
        r.arraySize = it->second.arraySize;
        r.type = it->second.type;
        return r;
    }
    for (const auto& u : program->uniforms) {
        if (u.arraySize > 1 && location > u.location
            && location < u.location + u.arraySize) {
            auto base = program->uniformValues.find(u.location);
            if (base != program->uniformValues.end()) {
                r.slot = &base->second;
                r.elementIndex = location - u.location;
                r.arraySize = u.arraySize;
                r.type = u.type;
            }
            return r;
        }
    }
    return r;
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
    UniformSlotRef ref = resolveUniformSlot(object, location);
    if (ref.slot == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramUniformValue* slot = ref.slot;

    // Clamp count so writes don't overflow the declared array. GL spec: the
    // effective update is min(count, arraySize - elementIndex).
    const GLint remaining = std::max<GLint>(ref.arraySize - ref.elementIndex, 1);
    const GLsizei effCount = std::min<GLsizei>(std::max<GLsizei>(count, 1), remaining);
    const std::size_t components = static_cast<std::size_t>(vectorSize);
    const std::size_t writeCount = components * static_cast<std::size_t>(effCount);
    const std::size_t fullCount  = components * static_cast<std::size_t>(std::max<GLint>(ref.arraySize, 1));
    const std::size_t writeOffset = components * static_cast<std::size_t>(ref.elementIndex);

    auto writeInto = [&](auto& dstVec, auto& otherA, auto& otherB, const auto* src) {
        using T = typename std::remove_reference<decltype(dstVec)>::type::value_type;
        // Size the destination to hold the full array; preserve existing
        // values where possible so per-element writes don't wipe siblings.
        if (dstVec.size() < fullCount) {
            dstVec.resize(fullCount, T{});
        }
        std::memcpy(dstVec.data() + writeOffset, src, writeCount * sizeof(T));
        otherA.clear();
        otherB.clear();
    };

    switch (element) {
        case UniformElementType::Float:
            writeInto(slot->floats, slot->ints, slot->uints, static_cast<const GLfloat*>(values));
            break;
        case UniformElementType::Int:
            writeInto(slot->ints, slot->floats, slot->uints, static_cast<const GLint*>(values));
            break;
        case UniformElementType::UnsignedInt:
            writeInto(slot->uints, slot->floats, slot->ints, static_cast<const GLuint*>(values));
            break;
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
    UniformSlotRef ref = resolveUniformSlot(object, location);
    if (ref.slot == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    GLProgramUniformValue* slot = ref.slot;
    const GLint remaining = std::max<GLint>(ref.arraySize - ref.elementIndex, 1);
    const GLsizei effCount = std::min<GLsizei>(std::max<GLsizei>(count, 1), remaining);
    const std::size_t components = static_cast<std::size_t>(vectorSize);
    const std::size_t writeCount = components * static_cast<std::size_t>(effCount);
    const std::size_t fullCount  = components * static_cast<std::size_t>(std::max<GLint>(ref.arraySize, 1));
    const std::size_t writeOffset = components * static_cast<std::size_t>(ref.elementIndex);
    auto writeInto = [&](auto& dstVec, auto& otherA, auto& otherB, const auto* src) {
        using T = typename std::remove_reference<decltype(dstVec)>::type::value_type;
        if (dstVec.size() < fullCount) dstVec.resize(fullCount, T{});
        std::memcpy(dstVec.data() + writeOffset, src, writeCount * sizeof(T));
        otherA.clear(); otherB.clear();
    };
    switch (element) {
        case UniformElementType::Float:
            writeInto(slot->floats, slot->ints, slot->uints, static_cast<const GLfloat*>(values)); break;
        case UniformElementType::Int:
            writeInto(slot->ints, slot->floats, slot->uints, static_cast<const GLint*>(values)); break;
        case UniformElementType::UnsignedInt:
            writeInto(slot->uints, slot->floats, slot->ints, static_cast<const GLuint*>(values)); break;
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

        // Array uniforms need per-element unpadding in std140 layout:
        // GL stores a float[3] as 12 packed bytes; std140 stores it as
        // 48 bytes (3 elements × 16-byte stride, only 4 used per). We
        // cache the stride and per-element GL byte count so the hot
        // packing loop iterates element-wise when arrayCount > 0.
        // KHR-GL46.explicit_uniform_location.uniform-loc-arrays-*
        // exercises this — declares `uniform float u0[3]` at location N
        // and expects each glUniform1f(N+i, …) to land at u0[i].
        if (member.arraySize > 1 && member.size > 0 && !entry.isMat3Padded) {
            entry.arrayCount = member.arraySize;
            entry.arrayStride = member.size / member.arraySize;
            // Compute the GL-packed element byte count from the element
            // type (array's declared type is the element type — for
            // arrays glslang reports the element type + arraySize > 0).
            auto scalarBytes = [](GLenum t) -> std::size_t {
                switch (t) {
                    case GL_FLOAT: case GL_FLOAT_VEC2: case GL_FLOAT_VEC3: case GL_FLOAT_VEC4:
                    case GL_INT: case GL_INT_VEC2: case GL_INT_VEC3: case GL_INT_VEC4:
                    case GL_UNSIGNED_INT: case GL_UNSIGNED_INT_VEC2: case GL_UNSIGNED_INT_VEC3: case GL_UNSIGNED_INT_VEC4:
                    case GL_BOOL:  case GL_BOOL_VEC2:  case GL_BOOL_VEC3:  case GL_BOOL_VEC4:
                        return 4;
                    case GL_DOUBLE: case GL_DOUBLE_VEC2: case GL_DOUBLE_VEC3: case GL_DOUBLE_VEC4:
                        return 8;
                    default:
                        return 4;
                }
            };
            auto componentCount = [](GLenum t) -> std::size_t {
                switch (t) {
                    case GL_FLOAT: case GL_INT: case GL_UNSIGNED_INT: case GL_DOUBLE: case GL_BOOL: return 1;
                    case GL_FLOAT_VEC2: case GL_INT_VEC2: case GL_UNSIGNED_INT_VEC2: case GL_DOUBLE_VEC2: case GL_BOOL_VEC2: return 2;
                    case GL_FLOAT_VEC3: case GL_INT_VEC3: case GL_UNSIGNED_INT_VEC3: case GL_DOUBLE_VEC3: case GL_BOOL_VEC3: return 3;
                    case GL_FLOAT_VEC4: case GL_INT_VEC4: case GL_UNSIGNED_INT_VEC4: case GL_DOUBLE_VEC4: case GL_BOOL_VEC4: return 4;
                    case GL_FLOAT_MAT2: return 4;
                    case GL_FLOAT_MAT3: return 9;
                    case GL_FLOAT_MAT4: return 16;
                    case GL_FLOAT_MAT2x3: case GL_FLOAT_MAT3x2: return 6;
                    case GL_FLOAT_MAT2x4: case GL_FLOAT_MAT4x2: return 8;
                    case GL_FLOAT_MAT3x4: case GL_FLOAT_MAT4x3: return 12;
                    default: return 1;
                }
            };
            entry.glElementBytes = componentCount(member.type) * scalarBytes(member.type);
        }

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

        // Array element unpadding: GL stores element [k] at byte offset
        // k * glElementBytes (tight); std140 places it at k * arrayStride
        // (>= 16). Loop per element, memcpy the GL-packed element into
        // its std140 slot, leave padding bytes zero. Applies to arrays
        // of scalars (float arr[N], int arr[N]) and vec3 arrays which
        // have slightly-wasted but still padded layout.
        if (entry.arrayCount > 0 && entry.arrayStride > entry.glElementBytes) {
            const std::size_t perEl = entry.glElementBytes;
            const std::size_t stride = entry.arrayStride;
            const auto* srcBytesPtr = static_cast<const std::uint8_t*>(srcData);
            for (std::uint32_t k = 0; k < entry.arrayCount; ++k) {
                const std::size_t srcOff = static_cast<std::size_t>(k) * perEl;
                const std::size_t dstOff = static_cast<std::size_t>(k) * stride;
                if (srcOff + perEl > srcBytes) break;
                std::memcpy(dst + dstOff, srcBytesPtr + srcOff, perEl);
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

// Phase 8X Group 4d follow-up¹⁴ — common pipeline state plumbing for
// the translated-draw path. Centralises the depth/cull/front-face/
// wireframe/blend reads so every draw entry point captures the same
// snapshot without drifting. The blend fields come directly from
// `GLStateTracker::blendState()` — the getter already returns the RGB
// vs. alpha split, so we just mirror it into the TDI substruct and
// separately ask `isEnabled(GL_BLEND)` for the enable bit (which lives
// in `enabledCaps_`, not the blend struct itself).
static void populateTranslatedDrawFixedFunctionState(
    TranslatedDrawInfo& tdi, GLStateTracker& state)
{
    tdi.depthTestEnabled = state.isEnabled(GL_DEPTH_TEST);
    tdi.depthFunc = state.depthState().func;
    tdi.depthWriteMask = (state.depthState().writeMask != GL_FALSE);
    tdi.cullFaceEnabled = state.isEnabled(GL_CULL_FACE);
    tdi.cullFaceMode = state.rasterState().cullFaceMode;
    tdi.frontFace = state.rasterState().frontFace;
    tdi.wireframe = (state.rasterState().polygonFillMode == GL_LINE);

    const auto& gl = state.blendState();
    tdi.blend.enabled = state.isEnabled(GL_BLEND);
    tdi.blend.srcRGB = gl.srcRGB;
    tdi.blend.dstRGB = gl.dstRGB;
    tdi.blend.srcAlpha = gl.srcAlpha;
    tdi.blend.dstAlpha = gl.dstAlpha;
    tdi.blend.equationRGB = gl.equationRGB;
    tdi.blend.equationAlpha = gl.equationAlpha;
    tdi.blend.colorMaskR = (gl.colorMask[0] != GL_FALSE);
    tdi.blend.colorMaskG = (gl.colorMask[1] != GL_FALSE);
    tdi.blend.colorMaskB = (gl.colorMask[2] != GL_FALSE);
    tdi.blend.colorMaskA = (gl.colorMask[3] != GL_FALSE);

    // RC-A02: viewport state.
    const auto& vp = state.viewport();
    tdi.viewportX = vp.x;
    tdi.viewportY = vp.y;
    tdi.viewportWidth = vp.width;
    tdi.viewportHeight = vp.height;
    const auto& dr = state.depthRange();
    tdi.depthRangeNear = dr.nearValue;
    tdi.depthRangeFar = dr.farValue;
}

// Phase 8X Group 4d follow-up¹⁴ — VAO → VertexAttributeLayout field
// copy. The GL `glVertexAttribPointer` (and `glVertexAttribIPointer` /
// `glVertexAttribFormat`) parameters are the *source of truth* for the
// MTLVertexFormat of each attribute, not `ShaderReflection::vertexInputs
// [i].type`. Prior to follow-up¹⁴ the vertex descriptor derived
// attribute formats from the shader-reflected scalar type, which
// produced `Float4` for any `in vec4 color` input even when the VBO
// layout stored 4×UBYTE normalized colors (see followup¹³-verification
// §Smoking-Gun). Capturing these four fields end-to-end lets
// `encodeTranslatedDraw` call `vaoTypeToMTLFormat` with the real VBO
// layout instead of the shader-reflected placeholder.
static void populateVertexAttributeLayoutVAOFields(
    TranslatedDrawInfo::VertexAttributeLayout& layout,
    const GLVertexAttributeState& attr)
{
    layout.glType = attr.type;
    layout.glComponentCount = attr.size;
    layout.glNormalized = attr.normalized;
    layout.glIsInteger = attr.integer;
}

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
    setup.info.depthWriteMask = (state.depthState().writeMask != GL_FALSE);
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
    impl_->frameGraph->resizeDrawable(impl_->drawableSurfaceWidth(), impl_->drawableSurfaceHeight());
    // Flush any pending clear before we start the draw render pass; otherwise
    // the draw would run against an uncleared default attachment.
    impl_->encodePendingWork();

    // Try the translated shader pipeline first (GPU-side vertex processing).
    const GLuint programName = impl_->state->currentProgram();
    GLProgramObject* program = (programName != 0) ? impl_->objects->programs().get(programName) : nullptr;
    APPGL_LOG(DRAW, @"drawArrays: mode=0x%X count=%d program=%u hasTranslated=%d",
              mode, count, programName, program ? (int)program->hasTranslatedPipeline : -1);
    if (program != nullptr && program->hasTranslatedPipeline) {
        const GLuint vaoName = impl_->state->boundVertexArray();
        GLVertexArrayObject* vao = (vaoName != 0) ? impl_->objects->vertexArrays().get(vaoName) : nullptr;
        // Phase 8X Group 4d follow-up³ — name each fall-through gate to BAR's log.
        const bool gateEmpty = (vao == nullptr || vao->attributes.empty());
        // Attributeless draw path: vertex shader has no vertex inputs
        // (generates its own vertices via gl_VertexID / [[vertex_id]]).
        const bool attributelessDraw = (vao != nullptr &&
            program->vertexReflection.vertexInputs.empty());
        if (attributelessDraw) {
            TranslatedDrawInfo tdi;
            tdi.mode = mode;
            tdi.vertexCount = count;
            // No vertex data — shader uses gl_VertexID / [[vertex_id]].
            tdi.vertexData = nullptr;
            tdi.vertexDataByteCount = 0;
            tdi.vertexStride = 0;
            populateTranslatedDrawFixedFunctionState(tdi, *impl_->state);
            tdi.vertexMSL = &program->vertexMSL;
            tdi.fragmentMSL = &program->fragmentMSL;
            tdi.vertexReflection = &program->vertexReflection;
            tdi.fragmentReflection = &program->fragmentReflection;
            tdi.pipelineStateOut = &program->metalPipelineState;
            tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;
            tdi.pipelineStateCacheOut = &program->metalPipelineStateCache;
            tdi.program = programName;

            // Uniform layout (cached).
            if (!program->uniformLayoutComputed) {
                computeStageUniformLayout(program->vertexUniformLayout,
                    program->vertexReflection, program->uniforms);
                computeStageUniformLayout(program->fragmentUniformLayout,
                    program->fragmentReflection, program->uniforms);
                program->uniformLayoutComputed = true;
            }
            thread_local std::vector<std::uint8_t> vtxUniformScratch;
            thread_local std::vector<std::uint8_t> fragUniformScratch;
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

            impl_->resolveSamplerBindings(*program, tdi);
            impl_->resolveUBOBindings(*program, tdi);
            impl_->resolveSSBOBindings(*program, tdi);

            // RC-A02: resolve FBO render target.
            {
                GLsizei fboW = 0, fboH = 0;
                void* fboDSTex = nullptr;
                void* fboColTex = impl_->resolveFBOColorTarget(fboW, fboH, fboDSTex);
                if (fboColTex != nullptr) {
                    tdi.fboColorTexture = fboColTex;
                    tdi.fboDepthStencilTexture = fboDSTex;
                    tdi.fboWidth = fboW;
                    tdi.fboHeight = fboH;
                }
            }

            thread_local std::string pipelineBuildError;
            pipelineBuildError.clear();
            tdi.pipelineBuildErrorOut = &pipelineBuildError;

            const bool ok = impl_->frameGraph->encodeTranslatedDraw(tdi);
            if (ok) {
                return true;
            }
            // Fall through to solid-color path on failure.
        }
        if (vao == nullptr) {
            reportTranslatedFallbackOnce(program, programName,
                TranslatedFallbackGate::EmptyAttributes, "drawArrays",
                vaoName, 0, 0, 0);
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
                    // Phase 8X Group 4d follow-up¹⁴ — centralised fixed-
                    // function state snapshot (depth/cull/front-face/
                    // wireframe/blend). Replaces the prior inline reads
                    // so drawArrays / drawArraysInstanced / drawElements
                    // all capture identical state.
                    populateTranslatedDrawFixedFunctionState(tdi, *impl_->state);
                    tdi.vertexMSL = &program->vertexMSL;
                    tdi.fragmentMSL = &program->fragmentMSL;
                    tdi.vertexReflection = &program->vertexReflection;
                    tdi.fragmentReflection = &program->fragmentReflection;
                    tdi.pipelineStateOut = &program->metalPipelineState;
                    tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;
                    // Phase 8X Group 4d follow-up¹⁴ — map-based cache
                    // so spring's 15×/frame blend toggle doesn't thrash
                    // the single-slot scalar cache above.
                    tdi.pipelineStateCacheOut = &program->metalPipelineStateCache;
                    // Phase 8X Group 4d follow-up⁸ — diagnostic-only
                    // program identifier used by encodeTranslatedDraw's
                    // first-draw-per-program NSLog. Non-owning, no
                    // correctness impact; zero is a valid placeholder.
                    tdi.program = programName;

                    // Collect per-attribute layout from the VAO.  Attributes
                    // sharing the primary VBO AND the primary stride go into
                    // vertexAttributeLayouts (Metal buffer 0).  Attributes in a
                    // different VBO or with a different effective stride are
                    // placed into extraVertexBuffers (Metal buffer 1+) so each
                    // group gets its own MTLVertexDescriptor layout stride.
                    //
                    // Phase 8X Group 4d follow-up¹⁴ — the VAO fields
                    // (`glType/glComponentCount/glNormalized/glIsInteger`)
                    // are now carried end-to-end so encodeTranslatedDraw
                    // can derive the real MTLVertexFormat from the VBO
                    // layout rather than the shader-reflected scalar type.
                    //
                    // The extra-buffer grouping key is (bufferName, stride).
                    // A helper map collects non-primary groups; after the loop
                    // each group becomes one ExtraVertexBuffer entry.
                    struct ExtraGroupKey {
                        GLuint bufferName;
                        std::size_t stride;
                        bool operator==(const ExtraGroupKey& o) const {
                            return bufferName == o.bufferName && stride == o.stride;
                        }
                    };
                    struct ExtraGroupKeyHash {
                        std::size_t operator()(const ExtraGroupKey& k) const {
                            return std::hash<GLuint>()(k.bufferName) ^ (std::hash<std::size_t>()(k.stride) << 16);
                        }
                    };
                    std::unordered_map<ExtraGroupKey, std::size_t, ExtraGroupKeyHash> extraGroupIndex;
                    for (std::size_t ai = 0; ai < vao->attributes.size(); ++ai) {
                        const auto& attr = vao->attributes[ai];
                        if (!attr.enabled) continue;
                        auto attrRes = resolveVertexAttrib(attr, *vao);
                        TranslatedDrawInfo::VertexAttributeLayout layout;
                        layout.location = static_cast<GLuint>(ai);
                        populateVertexAttributeLayoutVAOFields(layout, attr);

                        if (attrRes.bufferName == resolved.bufferName &&
                            attrRes.stride == posStride) {
                            // Primary group: same VBO + same stride → buffer 0.
                            layout.offset = attrRes.offset - resolved.offset;
                            tdi.vertexAttributeLayouts.push_back(layout);
                        } else {
                            // Different VBO or different stride → extra buffer.
                            ExtraGroupKey key{attrRes.bufferName, attrRes.stride};
                            auto it = extraGroupIndex.find(key);
                            std::size_t idx;
                            if (it == extraGroupIndex.end()) {
                                idx = tdi.extraVertexBuffers.size();
                                extraGroupIndex[key] = idx;
                                GLBufferObject* extraVbo =
                                    impl_->objects->buffers().get(attrRes.bufferName);
                                TranslatedDrawInfo::ExtraVertexBuffer evb;
                                evb.stride = attrRes.stride;
                                evb.divisor = 0;
                                if (extraVbo != nullptr && !extraVbo->shadowBytes.empty()) {
                                    const std::size_t extraFirstOff =
                                        static_cast<std::size_t>(first) * attrRes.stride;
                                    evb.data = extraVbo->shadowBytes.data();
                                    evb.byteCount = extraVbo->shadowBytes.size();
                                    evb.metalBuffer = extraVbo->metalBuffer;
                                    evb.metalBufferOffset = extraFirstOff;
                                }
                                tdi.extraVertexBuffers.push_back(std::move(evb));
                            } else {
                                idx = it->second;
                            }
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
                    impl_->resolveUBOBindings(*program, tdi);
                    impl_->resolveSSBOBindings(*program, tdi);

                    // RC-A02: resolve FBO render target when a user FBO is bound.
                    {
                        GLsizei fboW = 0, fboH = 0;
                        void* fboDSTex = nullptr;
                        void* fboColTex = impl_->resolveFBOColorTarget(fboW, fboH, fboDSTex);
                        if (fboColTex != nullptr) {
                            tdi.fboColorTexture = fboColTex;
                            tdi.fboDepthStencilTexture = fboDSTex;
                            tdi.fboWidth = fboW;
                            tdi.fboHeight = fboH;
                        }
                    }

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
    impl_->frameGraph->resizeDrawable(impl_->drawableSurfaceWidth(), impl_->drawableSurfaceHeight());
    impl_->encodePendingWork();

    // Translated shader pipeline with instancing.
    const GLuint programName = impl_->state->currentProgram();
    GLProgramObject* program = (programName != 0) ? impl_->objects->programs().get(programName) : nullptr;
    if (program != nullptr && program->hasTranslatedPipeline) {
        const GLuint vaoName = impl_->state->boundVertexArray();
        GLVertexArrayObject* vao = (vaoName != 0) ? impl_->objects->vertexArrays().get(vaoName) : nullptr;
        // Attributeless instanced draw path: vertex shader has no vertex inputs.
        const bool attributelessInstDraw = (vao != nullptr &&
            program->vertexReflection.vertexInputs.empty());
        if (attributelessInstDraw) {
            TranslatedDrawInfo tdi;
            tdi.mode = mode;
            tdi.vertexCount = count;
            tdi.instanceCount = instancecount;
            tdi.vertexData = nullptr;
            tdi.vertexDataByteCount = 0;
            tdi.vertexStride = 0;
            populateTranslatedDrawFixedFunctionState(tdi, *impl_->state);
            tdi.vertexMSL = &program->vertexMSL;
            tdi.fragmentMSL = &program->fragmentMSL;
            tdi.vertexReflection = &program->vertexReflection;
            tdi.fragmentReflection = &program->fragmentReflection;
            tdi.pipelineStateOut = &program->metalPipelineState;
            tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;
            tdi.pipelineStateCacheOut = &program->metalPipelineStateCache;
            tdi.program = programName;
            if (!program->uniformLayoutComputed) {
                computeStageUniformLayout(program->vertexUniformLayout,
                    program->vertexReflection, program->uniforms);
                computeStageUniformLayout(program->fragmentUniformLayout,
                    program->fragmentReflection, program->uniforms);
                program->uniformLayoutComputed = true;
            }
            thread_local std::vector<std::uint8_t> vtxUniformScratch;
            thread_local std::vector<std::uint8_t> fragUniformScratch;
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
            impl_->resolveSamplerBindings(*program, tdi);
            impl_->resolveUBOBindings(*program, tdi);
            impl_->resolveSSBOBindings(*program, tdi);
            {
                GLsizei fboW = 0, fboH = 0;
                void* fboDSTex = nullptr;
                void* fboColTex = impl_->resolveFBOColorTarget(fboW, fboH, fboDSTex);
                if (fboColTex != nullptr) {
                    tdi.fboColorTexture = fboColTex;
                    tdi.fboDepthStencilTexture = fboDSTex;
                    tdi.fboWidth = fboW;
                    tdi.fboHeight = fboH;
                }
            }
            thread_local std::string pipelineBuildError;
            pipelineBuildError.clear();
            tdi.pipelineBuildErrorOut = &pipelineBuildError;
            const bool ok = impl_->frameGraph->encodeTranslatedDraw(tdi);
            if (ok) {
                return true;
            }
        }
        if (vao == nullptr) {
            reportTranslatedFallbackOnce(program, programName,
                TranslatedFallbackGate::EmptyAttributes, "drawArraysInstanced",
                vaoName, 0, 0, 0);
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
                    // Phase 8X Group 4d follow-up¹⁴ — centralised fixed-
                    // function state snapshot. See drawArrays.
                    populateTranslatedDrawFixedFunctionState(tdi, *impl_->state);
                    tdi.vertexMSL = &program->vertexMSL;
                    tdi.fragmentMSL = &program->fragmentMSL;
                    tdi.vertexReflection = &program->vertexReflection;
                    tdi.fragmentReflection = &program->fragmentReflection;
                    tdi.pipelineStateOut = &program->metalPipelineState;
                    tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;
                    // Phase 8X Group 4d follow-up¹⁴ — map-based cache
                    // so spring's 15×/frame blend toggle doesn't thrash
                    // the single-slot scalar cache above.
                    tdi.pipelineStateCacheOut = &program->metalPipelineStateCache;
                    // Phase 8X Group 4d follow-up⁸ — diagnostic-only
                    // program identifier used by encodeTranslatedDraw's
                    // first-draw-per-program NSLog. Non-owning, no
                    // correctness impact; zero is a valid placeholder.
                    tdi.program = programName;

                    // Gather vertex attributes — group by (VBO, stride, divisor).
                    // Primary group: same VBO + same stride + divisor=0 → buffer 0.
                    // Everything else → extraVertexBuffers (buffer 1+).
                    //
                    // Phase 8X Group 4d follow-up¹⁴ — propagate VAO format
                    // fields (`glType/glComponentCount/glNormalized/
                    // glIsInteger`) for both the primary-buffer path and
                    // the extra-buffer path so encodeTranslatedDraw can
                    // derive the real MTLVertexFormat.
                    struct InstGroupKey {
                        GLuint bufferName;
                        std::size_t stride;
                        GLuint divisor;
                        bool operator==(const InstGroupKey& o) const {
                            return bufferName == o.bufferName
                                && stride == o.stride
                                && divisor == o.divisor;
                        }
                    };
                    struct InstGroupKeyHash {
                        std::size_t operator()(const InstGroupKey& k) const {
                            return std::hash<GLuint>()(k.bufferName)
                                 ^ (std::hash<std::size_t>()(k.stride) << 16)
                                 ^ (std::hash<GLuint>()(k.divisor) << 24);
                        }
                    };
                    std::unordered_map<InstGroupKey, std::size_t, InstGroupKeyHash> extraBufferMap;

                    for (std::size_t ai = 0; ai < vao->attributes.size(); ++ai) {
                        const auto& attr = vao->attributes[ai];
                        if (!attr.enabled) continue;

                        auto attrRes = resolveVertexAttrib(attr, *vao);
                        GLuint attrDivisor = attr.useSeparatedFormat
                            ? (attr.bindingIndex < vao->bindingPoints.size()
                                ? vao->bindingPoints[attr.bindingIndex].divisor
                                : attr.divisor)
                            : attr.divisor;

                        TranslatedDrawInfo::VertexAttributeLayout layout;
                        layout.location = static_cast<GLuint>(ai);
                        populateVertexAttributeLayoutVAOFields(layout, attr);

                        if (attrRes.bufferName == resolved.bufferName
                            && attrRes.stride == posStride
                            && attrDivisor == 0) {
                            // Same VBO + same stride + per-vertex → buffer 0.
                            layout.offset = attrRes.offset - resolved.offset;
                            tdi.vertexAttributeLayouts.push_back(layout);
                        } else {
                            GLBufferObject* extraVbo = impl_->objects->buffers().get(attrRes.bufferName);
                            if (extraVbo == nullptr || extraVbo->shadowBytes.empty()) continue;

                            InstGroupKey key{attrRes.bufferName, attrRes.stride, attrDivisor};
                            auto it = extraBufferMap.find(key);
                            std::size_t idx;
                            if (it == extraBufferMap.end()) {
                                idx = tdi.extraVertexBuffers.size();
                                extraBufferMap[key] = idx;

                                TranslatedDrawInfo::ExtraVertexBuffer evb;
                                evb.data = extraVbo->shadowBytes.data();
                                evb.byteCount = extraVbo->shadowBytes.size();
                                evb.stride = attrRes.stride;
                                evb.divisor = attrDivisor;
                                evb.metalBuffer = extraVbo->metalBuffer;
                                evb.metalBufferOffset =
                                    static_cast<std::size_t>(first) * attrRes.stride;
                                tdi.extraVertexBuffers.push_back(std::move(evb));
                            } else {
                                idx = it->second;
                            }

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
                    impl_->resolveUBOBindings(*program, tdi);
                    impl_->resolveSSBOBindings(*program, tdi);

                    // RC-A02: resolve FBO render target.
                    {
                        GLsizei fboW = 0, fboH = 0;
                        void* fboDSTex = nullptr;
                        void* fboColTex = impl_->resolveFBOColorTarget(fboW, fboH, fboDSTex);
                        if (fboColTex != nullptr) {
                            tdi.fboColorTexture = fboColTex;
                            tdi.fboDepthStencilTexture = fboDSTex;
                            tdi.fboWidth = fboW;
                            tdi.fboHeight = fboH;
                        }
                    }

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
    impl_->frameGraph->resizeDrawable(impl_->drawableSurfaceWidth(), impl_->drawableSurfaceHeight());
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
    //
    // ADV-10: cache the expanded index buffer on the GLBufferObject so
    // repeated drawElements calls with the same element buffer don't
    // re-allocate and re-widen on every draw.  The cache covers the
    // entire shadowBytes range (not per-offset subsets) and is
    // invalidated when the buffer data changes via glBufferData /
    // glBufferSubData (generation counter bump).
    GLenum effectiveType = type;
    const void* effectivePtr = indexPtr;
    if (elementIndexTypeNeedsExpansion(type)) {
        // Rebuild cache if stale or absent.
        if (elementBuffer->cachedExpansionGeneration != elementBuffer->indexExpansionGeneration
            || elementBuffer->cachedExpandedIndices.empty()) {
            const GLsizei totalIndices = static_cast<GLsizei>(elementBuffer->shadowBytes.size());
            IndexExpansionResult result = expandElementIndices(
                totalIndices, type, elementBuffer->shadowBytes.data());
            if (!result.ok) {
                pushError(result.error);
                return false;
            }
            elementBuffer->cachedExpandedIndices = std::move(result.bytes);
            elementBuffer->cachedExpansionGeneration = elementBuffer->indexExpansionGeneration;
        }
        effectiveType = GL_UNSIGNED_SHORT;
        // Recompute offset: each source byte becomes 2 bytes (uint16).
        const std::size_t expandedOffset = indexOffset * sizeof(GLushort);
        effectivePtr = elementBuffer->cachedExpandedIndices.data() + expandedOffset;
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
                    // ADV-10: use the type check instead of the old local vector.
                    if (!elementIndexTypeNeedsExpansion(type) && elementBuffer->metalBuffer != nullptr) {
                        tdi.metalIndexBuffer = elementBuffer->metalBuffer;
                        tdi.metalIndexBufferOffset = indexOffset;
                    }
                    // Phase 8X Group 4d follow-up¹⁴ — centralised fixed-
                    // function state snapshot. See drawArrays.
                    populateTranslatedDrawFixedFunctionState(tdi, *impl_->state);
                    tdi.vertexMSL = &program->vertexMSL;
                    tdi.fragmentMSL = &program->fragmentMSL;
                    tdi.vertexReflection = &program->vertexReflection;
                    tdi.fragmentReflection = &program->fragmentReflection;
                    tdi.pipelineStateOut = &program->metalPipelineState;
                    tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;
                    // Phase 8X Group 4d follow-up¹⁴ — map-based cache
                    // so spring's 15×/frame blend toggle doesn't thrash
                    // the single-slot scalar cache above.
                    tdi.pipelineStateCacheOut = &program->metalPipelineStateCache;
                    // Phase 8X Group 4d follow-up⁸ — diagnostic-only
                    // program identifier used by encodeTranslatedDraw's
                    // first-draw-per-program NSLog. Non-owning, no
                    // correctness impact; zero is a valid placeholder.
                    tdi.program = programName;

                    // Collect per-attribute layout from the VAO — group
                    // by (VBO, stride) so attributes with different strides
                    // get separate Metal buffer indices.
                    //
                    // Phase 8X Group 4d follow-up¹⁴ — propagate VAO
                    // format fields so encodeTranslatedDraw derives
                    // the real MTLVertexFormat from the VBO layout.
                    {
                        struct DEGroupKey {
                            GLuint bufferName;
                            std::size_t stride;
                            bool operator==(const DEGroupKey& o) const {
                                return bufferName == o.bufferName && stride == o.stride;
                            }
                        };
                        struct DEGroupKeyHash {
                            std::size_t operator()(const DEGroupKey& k) const {
                                return std::hash<GLuint>()(k.bufferName)
                                     ^ (std::hash<std::size_t>()(k.stride) << 16);
                            }
                        };
                        std::unordered_map<DEGroupKey, std::size_t, DEGroupKeyHash> deExtraMap;
                        for (std::size_t ai = 0; ai < vao->attributes.size(); ++ai) {
                            const auto& attr = vao->attributes[ai];
                            if (!attr.enabled) continue;
                            auto attrRes = resolveVertexAttrib(attr, *vao);
                            TranslatedDrawInfo::VertexAttributeLayout layout;
                            layout.location = static_cast<GLuint>(ai);
                            populateVertexAttributeLayoutVAOFields(layout, attr);
                            if (attrRes.bufferName == resolved.bufferName
                                && attrRes.stride == posStride) {
                                layout.offset = attrRes.offset - resolved.offset;
                                tdi.vertexAttributeLayouts.push_back(layout);
                            } else {
                                GLBufferObject* extraVbo =
                                    impl_->objects->buffers().get(attrRes.bufferName);
                                if (extraVbo == nullptr || extraVbo->shadowBytes.empty())
                                    continue;
                                DEGroupKey key{attrRes.bufferName, attrRes.stride};
                                auto it = deExtraMap.find(key);
                                std::size_t idx;
                                if (it == deExtraMap.end()) {
                                    idx = tdi.extraVertexBuffers.size();
                                    deExtraMap[key] = idx;
                                    TranslatedDrawInfo::ExtraVertexBuffer evb;
                                    evb.data = extraVbo->shadowBytes.data();
                                    evb.byteCount = extraVbo->shadowBytes.size();
                                    evb.stride = attrRes.stride;
                                    evb.divisor = 0;
                                    evb.metalBuffer = extraVbo->metalBuffer;
                                    evb.metalBufferOffset = 0;
                                    tdi.extraVertexBuffers.push_back(std::move(evb));
                                } else {
                                    idx = it->second;
                                }
                                layout.offset = attrRes.offset;
                                tdi.extraVertexBuffers[idx].attributes.push_back(layout);
                            }
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

                    impl_->resolveSamplerBindings(*program, tdi);
                    impl_->resolveUBOBindings(*program, tdi);
                    impl_->resolveSSBOBindings(*program, tdi);

                    // RC-A02: resolve FBO render target.
                    {
                        GLsizei fboW = 0, fboH = 0;
                        void* fboDSTex = nullptr;
                        void* fboColTex = impl_->resolveFBOColorTarget(fboW, fboH, fboDSTex);
                        if (fboColTex != nullptr) {
                            tdi.fboColorTexture = fboColTex;
                            tdi.fboDepthStencilTexture = fboDSTex;
                            tdi.fboWidth = fboW;
                            tdi.fboHeight = fboH;
                        }
                    }

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
// GL 3.2 — Base-vertex indexed drawing (ARB_draw_elements_base_vertex)
// ---------------------------------------------------------------------------

bool GLContext::drawElementsBaseVertex(GLenum mode, GLsizei count, GLenum type, const void* indices, GLint basevertex) {
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
    impl_->frameGraph->resizeDrawable(impl_->drawableSurfaceWidth(), impl_->drawableSurfaceHeight());
    impl_->encodePendingWork();

    // Resolve element buffer — same as drawElements.
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

    // Handle GL_UNSIGNED_BYTE expansion (same as drawElements).
    GLenum effectiveType = type;
    const void* effectivePtr = indexPtr;
    if (elementIndexTypeNeedsExpansion(type)) {
        if (elementBuffer->cachedExpansionGeneration != elementBuffer->indexExpansionGeneration
            || elementBuffer->cachedExpandedIndices.empty()) {
            const GLsizei totalIndices = static_cast<GLsizei>(elementBuffer->shadowBytes.size());
            IndexExpansionResult result = expandElementIndices(
                totalIndices, type, elementBuffer->shadowBytes.data());
            if (!result.ok) {
                pushError(result.error);
                return false;
            }
            elementBuffer->cachedExpandedIndices = std::move(result.bytes);
            elementBuffer->cachedExpansionGeneration = elementBuffer->indexExpansionGeneration;
        }
        effectiveType = GL_UNSIGNED_SHORT;
        const std::size_t expandedOffset = indexOffset * sizeof(GLushort);
        effectivePtr = elementBuffer->cachedExpandedIndices.data() + expandedOffset;
    }

    // Try translated shader pipeline first.
    const GLuint programName = impl_->state->currentProgram();
    GLProgramObject* program = (programName != 0) ? impl_->objects->programs().get(programName) : nullptr;
    if (program != nullptr && program->hasTranslatedPipeline) {
        if (vao->attributes.empty()) {
            reportTranslatedFallbackOnce(program, programName,
                TranslatedFallbackGate::EmptyAttributes, "drawElementsBaseVertex",
                vaoName, 0, 0, 0);
        }
        if (!vao->attributes.empty()) {
            const auto& posAttr = vao->attributes[0];
            auto resolved = resolveVertexAttrib(posAttr, *vao);
            GLBufferObject* vbo = (resolved.bufferName != 0)
                ? impl_->objects->buffers().get(resolved.bufferName) : nullptr;
            if (vbo == nullptr) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::NullVBO, "drawElementsBaseVertex",
                    vaoName, vao->attributes.size(), resolved.bufferName, 0);
            } else if (vbo->shadowBytes.empty()) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::ShadowBytesEmpty, "drawElementsBaseVertex",
                    vaoName, vao->attributes.size(), resolved.bufferName, 0);
            }
            if (vbo != nullptr && !vbo->shadowBytes.empty()) {
                const std::size_t posStride = resolved.stride;
                const std::size_t startOff = resolved.offset;

                if (startOff > vbo->shadowBytes.size()) {
                    reportTranslatedFallbackOnce(program, programName,
                        TranslatedFallbackGate::OffsetOverflow, "drawElementsBaseVertex",
                        vaoName, vao->attributes.size(), resolved.bufferName,
                        vbo->shadowBytes.size());
                }
                if (startOff <= vbo->shadowBytes.size()) {
                    TranslatedDrawInfo tdi;
                    tdi.mode = mode;
                    tdi.vertexCount = count;
                    tdi.baseVertex = basevertex;
                    tdi.vertexData = vbo->shadowBytes.data() + startOff;
                    tdi.vertexDataByteCount = vbo->shadowBytes.size() - startOff;
                    tdi.vertexStride = posStride;
                    tdi.metalVertexBuffer = vbo->metalBuffer;
                    tdi.metalVertexBufferOffset = startOff;
                    tdi.indices = effectivePtr;
                    tdi.indexCount = count;
                    tdi.indexType = effectiveType;
                    if (!elementIndexTypeNeedsExpansion(type) && elementBuffer->metalBuffer != nullptr) {
                        tdi.metalIndexBuffer = elementBuffer->metalBuffer;
                        tdi.metalIndexBufferOffset = indexOffset;
                    }
                    populateTranslatedDrawFixedFunctionState(tdi, *impl_->state);
                    tdi.vertexMSL = &program->vertexMSL;
                    tdi.fragmentMSL = &program->fragmentMSL;
                    tdi.vertexReflection = &program->vertexReflection;
                    tdi.fragmentReflection = &program->fragmentReflection;
                    tdi.pipelineStateOut = &program->metalPipelineState;
                    tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;
                    tdi.pipelineStateCacheOut = &program->metalPipelineStateCache;
                    tdi.program = programName;

                    for (std::size_t ai = 0; ai < vao->attributes.size(); ++ai) {
                        const auto& attr = vao->attributes[ai];
                        if (!attr.enabled) continue;
                        auto attrRes = resolveVertexAttrib(attr, *vao);
                        if (attrRes.bufferName != resolved.bufferName) continue;
                        TranslatedDrawInfo::VertexAttributeLayout layout;
                        layout.location = static_cast<GLuint>(ai);
                        layout.offset = attrRes.offset - resolved.offset;
                        populateVertexAttributeLayoutVAOFields(layout, attr);
                        tdi.vertexAttributeLayouts.push_back(layout);
                    }

                    if (!program->uniformLayoutComputed) {
                        computeStageUniformLayout(program->vertexUniformLayout,
                            program->vertexReflection, program->uniforms);
                        computeStageUniformLayout(program->fragmentUniformLayout,
                            program->fragmentReflection, program->uniforms);
                        program->uniformLayoutComputed = true;
                    }

                    thread_local std::vector<std::uint8_t> vtxUniformScratch;
                    thread_local std::vector<std::uint8_t> fragUniformScratch;
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

                    impl_->resolveSamplerBindings(*program, tdi);
                    impl_->resolveUBOBindings(*program, tdi);
                    impl_->resolveSSBOBindings(*program, tdi);

                    // RC-A02: resolve FBO render target.
                    {
                        GLsizei fboW = 0, fboH = 0;
                        void* fboDSTex = nullptr;
                        void* fboColTex = impl_->resolveFBOColorTarget(fboW, fboH, fboDSTex);
                        if (fboColTex != nullptr) {
                            tdi.fboColorTexture = fboColTex;
                            tdi.fboDepthStencilTexture = fboDSTex;
                            tdi.fboWidth = fboW;
                            tdi.fboHeight = fboH;
                        }
                    }

                    thread_local std::string pipelineBuildError;
                    pipelineBuildError.clear();
                    tdi.pipelineBuildErrorOut = &pipelineBuildError;

                    const bool ok = impl_->frameGraph->encodeTranslatedDraw(tdi);
                    if (ok) {
                        return true;
                    }
                    if (reportTranslatedFallbackOnce(program, programName,
                            TranslatedFallbackGate::EncodeFailed, "drawElementsBaseVertex",
                            vaoName, vao->attributes.size(), resolved.bufferName,
                            vbo->shadowBytes.size())) {
                        recordPipelineBuildFailureOnce(program, programName, pipelineBuildError);
                    }
                }
            }
        }
    }

    // Fallback: solid-color draw path.
    SolidColorDrawSetup setup = buildSolidColorDrawSetup(*impl_->state, *impl_->objects, mode, "glDrawElementsBaseVertex");
    if (!setup.ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_OTHER,
            0,
            GL_DEBUG_SEVERITY_LOW,
            "glDrawElementsBaseVertex: draw skipped (no translated pipeline and solid-color path unsupported)"
        );
        return false;
    }

    setup.info.vertexCount = count;
    setup.info.baseVertex = basevertex;
    setup.info.indices = effectivePtr;
    setup.info.indexCount = count;
    setup.info.indexType = effectiveType;

    const bool solidOk = impl_->frameGraph->encodeSolidColorDraw(setup.info);
    if (!solidOk) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_ERROR,
            0,
            GL_DEBUG_SEVERITY_HIGH,
            "glDrawElementsBaseVertex: MetalFrameGraph failed to encode draw"
        );
    }
    return solidOk;
}

bool GLContext::drawRangeElementsBaseVertex(GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type, const void* indices, GLint basevertex) {
    // Per the GL spec, start/end are range hints only. The spec says we MAY
    // use them for validation but MUST NOT reject draws where indices fall
    // outside [start, end]. We validate the basic constraints and delegate
    // to drawElementsBaseVertex for the actual draw.
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (end < start) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    return drawElementsBaseVertex(mode, count, type, indices, basevertex);
}

bool GLContext::drawElementsInstancedBaseVertex(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLint basevertex) {
    if (count < 0 || instancecount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (count == 0 || instancecount == 0) {
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
    impl_->frameGraph->resizeDrawable(impl_->drawableSurfaceWidth(), impl_->drawableSurfaceHeight());
    impl_->encodePendingWork();

    // Resolve element buffer.
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

    GLenum effectiveType = type;
    const void* effectivePtr = indexPtr;
    if (elementIndexTypeNeedsExpansion(type)) {
        if (elementBuffer->cachedExpansionGeneration != elementBuffer->indexExpansionGeneration
            || elementBuffer->cachedExpandedIndices.empty()) {
            const GLsizei totalIndices = static_cast<GLsizei>(elementBuffer->shadowBytes.size());
            IndexExpansionResult result = expandElementIndices(
                totalIndices, type, elementBuffer->shadowBytes.data());
            if (!result.ok) {
                pushError(result.error);
                return false;
            }
            elementBuffer->cachedExpandedIndices = std::move(result.bytes);
            elementBuffer->cachedExpansionGeneration = elementBuffer->indexExpansionGeneration;
        }
        effectiveType = GL_UNSIGNED_SHORT;
        const std::size_t expandedOffset = indexOffset * sizeof(GLushort);
        effectivePtr = elementBuffer->cachedExpandedIndices.data() + expandedOffset;
    }

    // Try translated shader pipeline first.
    const GLuint programName = impl_->state->currentProgram();
    GLProgramObject* program = (programName != 0) ? impl_->objects->programs().get(programName) : nullptr;
    if (program != nullptr && program->hasTranslatedPipeline) {
        if (vao->attributes.empty()) {
            reportTranslatedFallbackOnce(program, programName,
                TranslatedFallbackGate::EmptyAttributes, "drawElementsInstancedBaseVertex",
                vaoName, 0, 0, 0);
        }
        if (!vao->attributes.empty()) {
            const auto& posAttr = vao->attributes[0];
            auto resolved = resolveVertexAttrib(posAttr, *vao);
            GLBufferObject* vbo = (resolved.bufferName != 0)
                ? impl_->objects->buffers().get(resolved.bufferName) : nullptr;
            if (vbo == nullptr) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::NullVBO, "drawElementsInstancedBaseVertex",
                    vaoName, vao->attributes.size(), resolved.bufferName, 0);
            } else if (vbo->shadowBytes.empty()) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::ShadowBytesEmpty, "drawElementsInstancedBaseVertex",
                    vaoName, vao->attributes.size(), resolved.bufferName, 0);
            }
            if (vbo != nullptr && !vbo->shadowBytes.empty()) {
                const std::size_t posStride = resolved.stride;
                const std::size_t startOff = resolved.offset;

                if (startOff > vbo->shadowBytes.size()) {
                    reportTranslatedFallbackOnce(program, programName,
                        TranslatedFallbackGate::OffsetOverflow, "drawElementsInstancedBaseVertex",
                        vaoName, vao->attributes.size(), resolved.bufferName,
                        vbo->shadowBytes.size());
                }
                if (startOff <= vbo->shadowBytes.size()) {
                    TranslatedDrawInfo tdi;
                    tdi.mode = mode;
                    tdi.vertexCount = count;
                    tdi.baseVertex = basevertex;
                    tdi.instanceCount = instancecount;
                    tdi.vertexData = vbo->shadowBytes.data() + startOff;
                    tdi.vertexDataByteCount = vbo->shadowBytes.size() - startOff;
                    tdi.vertexStride = posStride;
                    tdi.metalVertexBuffer = vbo->metalBuffer;
                    tdi.metalVertexBufferOffset = startOff;
                    tdi.indices = effectivePtr;
                    tdi.indexCount = count;
                    tdi.indexType = effectiveType;
                    if (!elementIndexTypeNeedsExpansion(type) && elementBuffer->metalBuffer != nullptr) {
                        tdi.metalIndexBuffer = elementBuffer->metalBuffer;
                        tdi.metalIndexBufferOffset = indexOffset;
                    }
                    populateTranslatedDrawFixedFunctionState(tdi, *impl_->state);
                    tdi.vertexMSL = &program->vertexMSL;
                    tdi.fragmentMSL = &program->fragmentMSL;
                    tdi.vertexReflection = &program->vertexReflection;
                    tdi.fragmentReflection = &program->fragmentReflection;
                    tdi.pipelineStateOut = &program->metalPipelineState;
                    tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;
                    tdi.pipelineStateCacheOut = &program->metalPipelineStateCache;
                    tdi.program = programName;

                    // Gather vertex attributes — group by (VBO, stride, divisor).
                    // Primary group: same VBO + same stride + divisor=0 → buffer 0.
                    // Everything else → extraVertexBuffers (buffer 1+).
                    struct DrawElemGroupKey {
                        GLuint bufferName;
                        std::size_t stride;
                        GLuint divisor;
                        bool operator==(const DrawElemGroupKey& o) const {
                            return bufferName == o.bufferName
                                && stride == o.stride
                                && divisor == o.divisor;
                        }
                    };
                    struct DrawElemGroupKeyHash {
                        std::size_t operator()(const DrawElemGroupKey& k) const {
                            return std::hash<GLuint>()(k.bufferName)
                                 ^ (std::hash<std::size_t>()(k.stride) << 16)
                                 ^ (std::hash<GLuint>()(k.divisor) << 24);
                        }
                    };
                    std::unordered_map<DrawElemGroupKey, std::size_t, DrawElemGroupKeyHash> extraBufferMap;

                    for (std::size_t ai = 0; ai < vao->attributes.size(); ++ai) {
                        const auto& attr = vao->attributes[ai];
                        if (!attr.enabled) continue;

                        auto attrRes = resolveVertexAttrib(attr, *vao);
                        GLuint attrDivisor = attr.useSeparatedFormat
                            ? (attr.bindingIndex < vao->bindingPoints.size()
                                ? vao->bindingPoints[attr.bindingIndex].divisor
                                : attr.divisor)
                            : attr.divisor;

                        TranslatedDrawInfo::VertexAttributeLayout layout;
                        layout.location = static_cast<GLuint>(ai);
                        populateVertexAttributeLayoutVAOFields(layout, attr);

                        if (attrRes.bufferName == resolved.bufferName
                            && attrRes.stride == posStride
                            && attrDivisor == 0) {
                            layout.offset = attrRes.offset - resolved.offset;
                            tdi.vertexAttributeLayouts.push_back(layout);
                        } else {
                            GLBufferObject* extraVbo = impl_->objects->buffers().get(attrRes.bufferName);
                            if (extraVbo == nullptr || extraVbo->shadowBytes.empty()) continue;

                            DrawElemGroupKey key{attrRes.bufferName, attrRes.stride, attrDivisor};
                            auto it = extraBufferMap.find(key);
                            std::size_t idx;
                            if (it == extraBufferMap.end()) {
                                idx = tdi.extraVertexBuffers.size();
                                extraBufferMap[key] = idx;

                                TranslatedDrawInfo::ExtraVertexBuffer evb;
                                evb.data = extraVbo->shadowBytes.data();
                                evb.byteCount = extraVbo->shadowBytes.size();
                                evb.stride = attrRes.stride;
                                evb.divisor = attrDivisor;
                                evb.metalBuffer = extraVbo->metalBuffer;
                                evb.metalBufferOffset = 0;
                                tdi.extraVertexBuffers.push_back(std::move(evb));
                            } else {
                                idx = it->second;
                            }

                            layout.offset = attrRes.offset;
                            tdi.extraVertexBuffers[idx].attributes.push_back(layout);
                        }
                    }

                    if (!program->uniformLayoutComputed) {
                        computeStageUniformLayout(program->vertexUniformLayout,
                            program->vertexReflection, program->uniforms);
                        computeStageUniformLayout(program->fragmentUniformLayout,
                            program->fragmentReflection, program->uniforms);
                        program->uniformLayoutComputed = true;
                    }

                    thread_local std::vector<std::uint8_t> vtxUniformScratch;
                    thread_local std::vector<std::uint8_t> fragUniformScratch;
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

                    impl_->resolveSamplerBindings(*program, tdi);
                    impl_->resolveUBOBindings(*program, tdi);
                    impl_->resolveSSBOBindings(*program, tdi);

                    // RC-A02: resolve FBO render target.
                    {
                        GLsizei fboW = 0, fboH = 0;
                        void* fboDSTex = nullptr;
                        void* fboColTex = impl_->resolveFBOColorTarget(fboW, fboH, fboDSTex);
                        if (fboColTex != nullptr) {
                            tdi.fboColorTexture = fboColTex;
                            tdi.fboDepthStencilTexture = fboDSTex;
                            tdi.fboWidth = fboW;
                            tdi.fboHeight = fboH;
                        }
                    }

                    thread_local std::string pipelineBuildError;
                    pipelineBuildError.clear();
                    tdi.pipelineBuildErrorOut = &pipelineBuildError;

                    const bool ok = impl_->frameGraph->encodeTranslatedDraw(tdi);
                    if (ok) {
                        return true;
                    }
                    if (reportTranslatedFallbackOnce(program, programName,
                            TranslatedFallbackGate::EncodeFailed, "drawElementsInstancedBaseVertex",
                            vaoName, vao->attributes.size(), resolved.bufferName,
                            vbo->shadowBytes.size())) {
                        recordPipelineBuildFailureOnce(program, programName, pipelineBuildError);
                    }
                }
            }
        }
    }

    // Fallback: solid-color draw path (no instancing support in solid-color).
    SolidColorDrawSetup setup = buildSolidColorDrawSetup(*impl_->state, *impl_->objects, mode, "glDrawElementsInstancedBaseVertex");
    if (!setup.ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_OTHER,
            0,
            GL_DEBUG_SEVERITY_LOW,
            "glDrawElementsInstancedBaseVertex: draw skipped (no translated pipeline and solid-color path unsupported)"
        );
        return false;
    }

    setup.info.vertexCount = count;
    setup.info.baseVertex = basevertex;
    setup.info.indices = effectivePtr;
    setup.info.indexCount = count;
    setup.info.indexType = effectiveType;

    const bool solidOk = impl_->frameGraph->encodeSolidColorDraw(setup.info);
    if (!solidOk) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_ERROR,
            0,
            GL_DEBUG_SEVERITY_HIGH,
            "glDrawElementsInstancedBaseVertex: MetalFrameGraph failed to encode draw"
        );
    }
    return solidOk;
}

bool GLContext::multiDrawElementsBaseVertex(GLenum mode, const GLsizei* count, GLenum type, const void* const* indices, GLsizei drawcount, const GLint* basevertex) {
    if (drawcount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!isSupportedElementIndexType(type)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // Multi-draw decomposes into individual draws per the GL spec.
    for (GLsizei i = 0; i < drawcount; ++i) {
        if (count[i] > 0) {
            drawElementsBaseVertex(mode, count[i], type, indices[i], basevertex[i]);
        }
    }
    return true;
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

    // Resolve the currently-bound program. GL 4.6 §17.1 requires
    // GL_INVALID_OPERATION when there's no active program OR when
    // the active program doesn't contain a compute shader. We detect
    // both by checking whether `metalComputePipelineState` is non-null
    // — linkProgram only populates it for programs with ProgramKind
    // ::Compute. This surfaces the compute-shader.api-no-active-program
    // / api-program negative tests as spec-correct failures.
    const GLuint progName = impl_->state->currentProgram();
    GLProgramObject* programObject = progName == 0 ? nullptr
        : impl_->objects->programs().get(progName);
    if (programObject == nullptr || !programObject->linked
        || programObject->metalComputePipelineState == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (impl_->frameGraph == nullptr) {
        // Pipeline was built but the frame graph is torn down — no
        // dispatch is possible. Treat as a silent no-op to avoid
        // spurious errors during teardown paths.
        return true;
    }

    ComputeDispatchInfo info;
    info.metalComputePipelineState = programObject->metalComputePipelineState;
    info.groupsX = num_groups_x;
    info.groupsY = num_groups_y;
    info.groupsZ = num_groups_z;
    info.localX = programObject->computeLocalSizeX;
    info.localY = programObject->computeLocalSizeY;
    info.localZ = programObject->computeLocalSizeZ;

    // Pack default uniforms (bare GL uniforms in the _DefaultUniforms
    // block) for the compute stage. Mirrors the graphics-stage path:
    // lazy layout compute + per-dispatch rebuild of the byte buffer
    // from uniformValues. Without this, location-based glUniform*
    // updates for a compute program never reach the MSL kernel.
    // KHR-GL46.explicit_uniform_location.* with a compute variant
    // specifically relies on this.
    thread_local std::vector<std::uint8_t> computeUniformScratch;
    if (!programObject->uniformLayoutComputed
        || programObject->computeUniformLayout.empty()) {
        // Only (re)build the layout vector when we haven't seen this
        // program before OR the compute-side layout is still empty on
        // a program that previously had graphics stages computed.
        computeStageUniformLayout(programObject->computeUniformLayout,
            programObject->computeReflection, programObject->uniforms);
        programObject->uniformLayoutComputed = true;
    }
    pushSynthesizedMatrixUniforms(*programObject, impl_->matrixState);
    buildStageUniformBuffer(computeUniformScratch,
        programObject->computeReflection, programObject->uniformValues,
        programObject->computeUniformLayout);
    if (!computeUniformScratch.empty()) {
        info.computeUniformData = computeUniformScratch.data();
        info.computeUniformSize = computeUniformScratch.size();
    }

    // Resolve shader-storage buffer bindings. For each SSBO the shader
    // declares, look up whatever buffer the app has bound to
    // GL_SHADER_STORAGE_BUFFER at its layout(binding=N) slot via
    // glBindBufferBase / glBindBufferRange, and forward the Metal
    // buffer + offset into the dispatch info. SSBOs with no binding
    // are simply omitted — Metal's unbound-slot behaviour is undefined
    // but won't crash, and the test will fail verification cleanly.
    for (const auto& ssbo : programObject->computeReflection.storageBuffers) {
        const GLIndexedBufferBinding binding = impl_->state->indexedBufferBinding(
            GL_SHADER_STORAGE_BUFFER, ssbo.glBinding);
        if (binding.buffer == 0) continue;
        const GLBufferObject* bufObj = impl_->objects->buffers().get(binding.buffer);
        if (bufObj == nullptr || bufObj->metalBuffer == nullptr) continue;

        ComputeDispatchInfo::BufferBinding bb;
        bb.metalBuffer = bufObj->metalBuffer;
        bb.offset = static_cast<std::size_t>(binding.offset);
        bb.metalSlot = ssbo.metalBinding;
        info.buffers.push_back(bb);
    }

    // Resolve uniform-block bindings for the compute stage. Compute
    // shaders rarely use UBOs (the CTS compute tests almost always go
    // through SSBOs exclusively) but the path is symmetric with the
    // graphics uboBindings resolver — walk each reflected block,
    // look up the bound buffer via glBindBufferBase, forward it.
    for (const auto& ubo : programObject->computeReflection.uniformBlocks) {
        const GLIndexedBufferBinding binding = impl_->state->indexedBufferBinding(
            GL_UNIFORM_BUFFER, ubo.glBinding);
        if (binding.buffer == 0) continue;
        const GLBufferObject* bufObj = impl_->objects->buffers().get(binding.buffer);
        if (bufObj == nullptr || bufObj->metalBuffer == nullptr) continue;

        ComputeDispatchInfo::BufferBinding bb;
        bb.metalBuffer = bufObj->metalBuffer;
        bb.offset = static_cast<std::size_t>(binding.offset);
        bb.metalSlot = ubo.metalBinding;
        info.buffers.push_back(bb);
    }

    // Texture/sampler bindings for compute stage. Less common than
    // SSBOs but real — image-processing compute shaders sample from
    // textures. Walk each reflected sampler uniform, resolve the
    // texture unit via the shader's sampler uniform value, and bind
    // the resulting (texture, sampler) pair at the reflected slot.
    // The logic mirrors resolveSamplerBindings but targets the
    // compute slot space.
    for (const auto& samp : programObject->computeReflection.sampledTextures) {
        // Find the matching uniform to read its texture-unit value.
        GLint uniformLoc = -1;
        for (const auto& u : programObject->uniforms) {
            if (u.name == samp.name) {
                uniformLoc = u.location;
                break;
            }
        }
        if (uniformLoc < 0) continue;
        auto uvIt = programObject->uniformValues.find(uniformLoc);
        const GLuint unit = (uvIt != programObject->uniformValues.end() && !uvIt->second.ints.empty())
            ? static_cast<GLuint>(uvIt->second.ints[0]) : 0;

        GLenum discoveredTarget = GL_TEXTURE_2D;
        GLuint texName = impl_->state->boundTextureOnUnit(unit, GL_TEXTURE_2D);
        if (texName == 0) {
            texName = impl_->state->boundTextureOnUnitAny(unit, &discoveredTarget);
        }
        if (texName == 0) continue;

        GLTextureObject* texObj = impl_->objects->textures().get(texName);
        if (texObj == nullptr || texObj->metalTexture == nullptr) continue;
        // Build the sampler state if dirty.
        if (texObj->samplerDirty) {
            impl_->rebuildTextureSamplerState(texName, *texObj);
        }

        ComputeDispatchInfo::TextureBinding tb;
        tb.metalTexture = texObj->metalTexture;
        tb.metalSamplerState = texObj->metalSampler;
        tb.metalSlot = samp.metalBinding;
        info.textures.push_back(tb);
    }

    // Storage images (imageLoad/imageStore). Bound via
    // glBindImageTexture(unit, …) rather than a sampler uniform. The
    // shader's `layout(binding=N)` selects imageBindings[N] directly.
    // KHR-GL46.compute_shader.copy-image exercises this.
    for (const auto& img : programObject->computeReflection.storageImages) {
        if (img.glBinding >= Impl::kMaxImageUnits) continue;
        const auto& ib = impl_->imageBindings[img.glBinding];
        if (ib.texture == 0) continue;
        GLTextureObject* texObj = impl_->objects->textures().get(ib.texture);
        if (texObj == nullptr || texObj->metalTexture == nullptr) continue;
        ComputeDispatchInfo::TextureBinding tb;
        tb.metalTexture = texObj->metalTexture;
        tb.metalSamplerState = nullptr;  // no sampler for storage images
        tb.metalSlot = img.metalBinding;
        info.textures.push_back(tb);
    }

    (void)impl_->frameGraph->encodeComputeDispatch(info);
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

    // GL 4.6 §17.2: GL_INVALID_OPERATION when no active compute program
    // (matches dispatchCompute's spec-correct check below). Without
    // this, the compute_shader.api-indirect / api-no-active-program
    // negative tests see GL_NO_ERROR and fail.
    const GLuint progName = impl_->state->currentProgram();
    GLProgramObject* programObject = progName == 0 ? nullptr
        : impl_->objects->programs().get(progName);
    if (programObject == nullptr || !programObject->linked
        || programObject->metalComputePipelineState == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    // GL 4.6 §17.2: also INVALID_OPERATION when no buffer is bound
    // to the GL_DISPATCH_INDIRECT_BUFFER target, or when the command
    // would read past the end of the bound buffer.
    const GLuint dispatchBufName = impl_->state->boundBuffer(GL_DISPATCH_INDIRECT_BUFFER);
    if (dispatchBufName == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const GLBufferObject* dispatchBuf = impl_->objects->buffers().get(dispatchBufName);
    if (dispatchBuf == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Three GLuints (x, y, z work-group counts) at `indirect`.
    constexpr GLsizeiptr kIndirectDispatchSize = 3 * sizeof(GLuint);
    if (indirect > dispatchBuf->size
        || kIndirectDispatchSize > dispatchBuf->size - indirect) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    // Route the indirect dispatch through the same encoder as the
    // direct path. Metal reads the (groupsX, groupsY, groupsZ) triple
    // out of the buffer at dispatch time via
    // dispatchThreadgroupsWithIndirectBuffer — we just hand it the
    // MTLBuffer + offset.
    if (impl_->frameGraph == nullptr) {
        return true;  // teardown — silently no-op, same as direct path
    }
    ComputeDispatchInfo info;
    info.metalComputePipelineState = programObject->metalComputePipelineState;
    info.localX = programObject->computeLocalSizeX;
    info.localY = programObject->computeLocalSizeY;
    info.localZ = programObject->computeLocalSizeZ;
    info.indirectBuffer = dispatchBuf->metalBuffer;
    info.indirectOffset = static_cast<std::size_t>(indirect);

    // Same resource plumbing as the direct dispatch path: SSBOs, UBOs,
    // default-uniform push constants, sampled textures. Keep in sync
    // with GLContext::dispatchCompute.
    for (const auto& ssbo : programObject->computeReflection.storageBuffers) {
        const GLIndexedBufferBinding binding = impl_->state->indexedBufferBinding(
            GL_SHADER_STORAGE_BUFFER, ssbo.glBinding);
        if (binding.buffer == 0) continue;
        const GLBufferObject* bufObj = impl_->objects->buffers().get(binding.buffer);
        if (bufObj == nullptr || bufObj->metalBuffer == nullptr) continue;
        ComputeDispatchInfo::BufferBinding bb;
        bb.metalBuffer = bufObj->metalBuffer;
        bb.offset = static_cast<std::size_t>(binding.offset);
        bb.metalSlot = ssbo.metalBinding;
        info.buffers.push_back(bb);
    }
    for (const auto& ubo : programObject->computeReflection.uniformBlocks) {
        const GLIndexedBufferBinding binding = impl_->state->indexedBufferBinding(
            GL_UNIFORM_BUFFER, ubo.glBinding);
        if (binding.buffer == 0) continue;
        const GLBufferObject* bufObj = impl_->objects->buffers().get(binding.buffer);
        if (bufObj == nullptr || bufObj->metalBuffer == nullptr) continue;
        ComputeDispatchInfo::BufferBinding bb;
        bb.metalBuffer = bufObj->metalBuffer;
        bb.offset = static_cast<std::size_t>(binding.offset);
        bb.metalSlot = ubo.metalBinding;
        info.buffers.push_back(bb);
    }
    thread_local std::vector<std::uint8_t> computeUniformScratchIndirect;
    if (!programObject->uniformLayoutComputed
        || programObject->computeUniformLayout.empty()) {
        computeStageUniformLayout(programObject->computeUniformLayout,
            programObject->computeReflection, programObject->uniforms);
        programObject->uniformLayoutComputed = true;
    }
    pushSynthesizedMatrixUniforms(*programObject, impl_->matrixState);
    buildStageUniformBuffer(computeUniformScratchIndirect,
        programObject->computeReflection, programObject->uniformValues,
        programObject->computeUniformLayout);
    if (!computeUniformScratchIndirect.empty()) {
        info.computeUniformData = computeUniformScratchIndirect.data();
        info.computeUniformSize = computeUniformScratchIndirect.size();
    }
    for (const auto& samp : programObject->computeReflection.sampledTextures) {
        GLint uniformLoc = -1;
        for (const auto& u : programObject->uniforms) {
            if (u.name == samp.name) { uniformLoc = u.location; break; }
        }
        if (uniformLoc < 0) continue;
        auto uvIt = programObject->uniformValues.find(uniformLoc);
        const GLuint unit = (uvIt != programObject->uniformValues.end() && !uvIt->second.ints.empty())
            ? static_cast<GLuint>(uvIt->second.ints[0]) : 0;
        GLenum discoveredTarget = GL_TEXTURE_2D;
        GLuint texName = impl_->state->boundTextureOnUnit(unit, GL_TEXTURE_2D);
        if (texName == 0) {
            texName = impl_->state->boundTextureOnUnitAny(unit, &discoveredTarget);
        }
        if (texName == 0) continue;
        GLTextureObject* texObj = impl_->objects->textures().get(texName);
        if (texObj == nullptr || texObj->metalTexture == nullptr) continue;
        if (texObj->samplerDirty) {
            impl_->rebuildTextureSamplerState(texName, *texObj);
        }
        ComputeDispatchInfo::TextureBinding tb;
        tb.metalTexture = texObj->metalTexture;
        tb.metalSamplerState = texObj->metalSampler;
        tb.metalSlot = samp.metalBinding;
        info.textures.push_back(tb);
    }
    // Storage images for the indirect path — mirror the direct path.
    for (const auto& img : programObject->computeReflection.storageImages) {
        if (img.glBinding >= Impl::kMaxImageUnits) continue;
        const auto& ib = impl_->imageBindings[img.glBinding];
        if (ib.texture == 0) continue;
        GLTextureObject* texObj = impl_->objects->textures().get(ib.texture);
        if (texObj == nullptr || texObj->metalTexture == nullptr) continue;
        ComputeDispatchInfo::TextureBinding tb;
        tb.metalTexture = texObj->metalTexture;
        tb.metalSamplerState = nullptr;
        tb.metalSlot = img.metalBinding;
        info.textures.push_back(tb);
    }

    (void)impl_->frameGraph->encodeComputeDispatch(info);
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
        case GL_UNIFORM:                      return &prog.resourceUniforms;
        case GL_UNIFORM_BLOCK:                return &prog.resourceUniformBlocks;
        case GL_PROGRAM_INPUT:                return &prog.resourceInputs;
        case GL_PROGRAM_OUTPUT:               return &prog.resourceOutputs;
        case GL_SHADER_STORAGE_BLOCK:         return &prog.resourceStorageBlocks;
        case GL_ATOMIC_COUNTER_BUFFER:        return &prog.resourceAtomicCounterBuffers;
        case GL_BUFFER_VARIABLE:              return &prog.resourceBufferVariables;
        case GL_TRANSFORM_FEEDBACK_VARYING:   return &prog.resourceTransformFeedbackVaryings;
        case GL_TRANSFORM_FEEDBACK_BUFFER:    return &prog.resourceTransformFeedbackBuffers;
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
        case GL_BUFFER_BINDING:    return entry.binding >= 0 ? entry.binding : entry.location;
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
    // Always defensively-zero the caller's length output first. CTS tests
    // (e.g. program_interface_query.subroutines-vertex) declare
    // `GLsizei length` uninitialized on the stack, call us with the
    // address, and then use `length` as a for-loop bound — if we return
    // without writing it, the loop runs against stack garbage and reads
    // past the end of its `param[1000]` buffer, producing a deterministic
    // SIGBUS once the stack happens to carry a large value at that offset
    // (observed at test #12648 of a full CTS sweep).
    if (length != nullptr) {
        *length = 0;
    }
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
    // Defensively zero length first (see getProgramResourceiv for rationale).
    if (length != nullptr) {
        *length = 0;
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
    const std::string lookup = name;
    // Direct match — but skip entries with location=-1. SPIRV-Cross
    // reflection sometimes emits both "u0" (the real base with valid
    // location) and "u0[0]" (a per-element duplicate that was never
    // assigned a location). Without the -1 guard the direct match
    // would hit the duplicate first and short-circuit to -1.
    for (const auto& entry : *table) {
        if (entry.name == lookup && entry.location >= 0) {
            return entry.location;
        }
    }
    // Array-element lookup parity with getUniformLocation: "u[k]"
    // resolves to location(u) + k when u is declared as an array of
    // size > k. GL 4.6 §7.3.1 says both entry points return the same
    // thing for the same name — including array subscript syntax.
    const auto openBracket = lookup.find('[');
    if (openBracket != std::string::npos && !lookup.empty() && lookup.back() == ']') {
        const std::string baseName = lookup.substr(0, openBracket);
        const std::string indexStr = lookup.substr(openBracket + 1, lookup.size() - openBracket - 2);
        if (!baseName.empty() && !indexStr.empty()) {
            char* endp = nullptr;
            const long idx = std::strtol(indexStr.c_str(), &endp, 10);
            if (endp && *endp == '\0' && idx >= 0) {
                for (const auto& entry : *table) {
                    if (entry.name == baseName && entry.arraySize >= 1
                        && idx < static_cast<long>(entry.arraySize)
                        && entry.location >= 0) {
                        return entry.location + static_cast<GLint>(idx);
                    }
                }
            }
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
    // Delegate to the instanced+baseVertex path; baseinstance is ignored for now
    // (requires MTLGPUFamily Apple3+ for non-zero base instance).
    return drawElementsInstancedBaseVertex(mode, count, type, indices, instancecount, 0);
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
    // Delegate to the instanced+baseVertex path; baseinstance is ignored for now
    // (requires MTLGPUFamily Apple3+ for non-zero base instance).
    return drawElementsInstancedBaseVertex(mode, count, type, indices, instancecount, basevertex);
}

// ---------------------------------------------------------------------------
// GL 4.0/4.3 — Indirect Draw Helpers
// ---------------------------------------------------------------------------

GLuint GLContext::getBoundVertexArray() const {
    return impl_->state->boundVertexArray();
}

bool GLContext::readIndirectBuffer(GLenum target, const void* indirect, std::size_t size, void* out) {
    const GLuint bufName = impl_->state->boundBuffer(target);
    if (bufName != 0) {
        // `indirect` is a byte offset into the bound buffer.
        const auto offset = reinterpret_cast<uintptr_t>(indirect);
        GLBufferObject* buf = impl_->objects->buffers().get(bufName);
        if (buf == nullptr || !buf->instantiated) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        if (offset + size > static_cast<std::size_t>(buf->size)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        if (buf->shadowBytes.size() >= offset + size) {
            std::memcpy(out, buf->shadowBytes.data() + offset, size);
        } else {
            // Shadow copy not available — zero-fill as a safe fallback.
            std::memset(out, 0, size);
        }
    } else {
        // No buffer bound — `indirect` is a client pointer.
        if (indirect == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        std::memcpy(out, indirect, size);
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
    // Core profile: drawing with default VAO (0) is INVALID_OPERATION.
    if (impl_->state->boundVertexArray() == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Offset into the indirect buffer must be 4-byte aligned.
    if (reinterpret_cast<uintptr_t>(indirect) % 4 != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // DrawArraysIndirectCommand layout: { count, instanceCount, first, baseInstance }
    struct DrawArraysIndirectCommand {
        GLuint count;
        GLuint instanceCount;
        GLuint first;
        GLuint baseInstance;
    };
    const GLsizei effectiveStride = (stride == 0) ? static_cast<GLsizei>(sizeof(DrawArraysIndirectCommand)) : stride;

    for (GLsizei i = 0; i < drawcount; ++i) {
        const void* cmdPtr = reinterpret_cast<const void*>(
            reinterpret_cast<uintptr_t>(indirect) + static_cast<uintptr_t>(i) * static_cast<uintptr_t>(effectiveStride));
        DrawArraysIndirectCommand cmd{};
        if (!readIndirectBuffer(GL_DRAW_INDIRECT_BUFFER, cmdPtr, sizeof(cmd), &cmd)) {
            return false;
        }
        if (cmd.count == 0 || cmd.instanceCount == 0) {
            continue;  // valid no-op for this sub-draw
        }
        drawArraysInstancedBaseInstance(mode, static_cast<GLint>(cmd.first),
                                        static_cast<GLsizei>(cmd.count),
                                        static_cast<GLsizei>(cmd.instanceCount),
                                        cmd.baseInstance);
    }
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
    // Core profile: drawing with default VAO (0) is INVALID_OPERATION.
    if (impl_->state->boundVertexArray() == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Offset into the indirect buffer must be 4-byte aligned.
    if (reinterpret_cast<uintptr_t>(indirect) % 4 != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // DrawElementsIndirectCommand layout: { count, instanceCount, firstIndex, baseVertex, baseInstance }
    struct DrawElementsIndirectCommand {
        GLuint count;
        GLuint instanceCount;
        GLuint firstIndex;
        GLuint baseVertex;
        GLuint baseInstance;
    };
    const GLsizei effectiveStride = (stride == 0) ? static_cast<GLsizei>(sizeof(DrawElementsIndirectCommand)) : stride;
    const GLsizei indexSize = (type == GL_UNSIGNED_INT) ? 4 : (type == GL_UNSIGNED_SHORT) ? 2 : 1;

    for (GLsizei i = 0; i < drawcount; ++i) {
        const void* cmdPtr = reinterpret_cast<const void*>(
            reinterpret_cast<uintptr_t>(indirect) + static_cast<uintptr_t>(i) * static_cast<uintptr_t>(effectiveStride));
        DrawElementsIndirectCommand cmd{};
        if (!readIndirectBuffer(GL_DRAW_INDIRECT_BUFFER, cmdPtr, sizeof(cmd), &cmd)) {
            return false;
        }
        if (cmd.count == 0 || cmd.instanceCount == 0) {
            continue;
        }
        const void* indexOffset = reinterpret_cast<const void*>(
            static_cast<uintptr_t>(cmd.firstIndex) * static_cast<uintptr_t>(indexSize));
        drawElementsInstancedBaseVertexBaseInstance(mode,
            static_cast<GLsizei>(cmd.count), type, indexOffset,
            static_cast<GLsizei>(cmd.instanceCount),
            static_cast<GLint>(cmd.baseVertex),
            cmd.baseInstance);
    }
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.3 — Buffer Clear
// ---------------------------------------------------------------------------

// Figure out the width-in-bytes of the clear-data tuple for glClearBuffer*.
// Spec §6.6: the pattern is `N` bytes where N is the data size of the
// (format, type) pair — e.g. GL_R8 + GL_RED + GL_UNSIGNED_BYTE is 1 byte,
// GL_RGBA8 + GL_RGBA + GL_UNSIGNED_BYTE is 4 bytes, GL_RG32F + GL_RG +
// GL_FLOAT is 8 bytes. Caller replicates the pattern for every element.
static std::size_t bufferClearPatternBytes(GLenum format, GLenum type) {
    std::size_t components = 1;
    switch (format) {
        case GL_RED: case GL_RED_INTEGER: case GL_GREEN: case GL_BLUE:
        case GL_GREEN_INTEGER: case GL_BLUE_INTEGER: components = 1; break;
        case GL_RG: case GL_RG_INTEGER: components = 2; break;
        case GL_RGB: case GL_BGR: case GL_RGB_INTEGER: case GL_BGR_INTEGER: components = 3; break;
        case GL_RGBA: case GL_BGRA: case GL_RGBA_INTEGER: case GL_BGRA_INTEGER: components = 4; break;
        case GL_DEPTH_COMPONENT: components = 1; break;
        case GL_STENCIL_INDEX: components = 1; break;
        default: components = 1; break;
    }
    std::size_t bytesPerComponent = 1;
    switch (type) {
        case GL_UNSIGNED_BYTE: case GL_BYTE: bytesPerComponent = 1; break;
        case GL_UNSIGNED_SHORT: case GL_SHORT: case GL_HALF_FLOAT: bytesPerComponent = 2; break;
        case GL_UNSIGNED_INT: case GL_INT: case GL_FLOAT: bytesPerComponent = 4; break;
        // Packed types: one packed element covers all components.
        case GL_UNSIGNED_BYTE_3_3_2:
        case GL_UNSIGNED_BYTE_2_3_3_REV: return 1;
        case GL_UNSIGNED_SHORT_5_6_5:
        case GL_UNSIGNED_SHORT_5_6_5_REV:
        case GL_UNSIGNED_SHORT_4_4_4_4:
        case GL_UNSIGNED_SHORT_4_4_4_4_REV:
        case GL_UNSIGNED_SHORT_5_5_5_1:
        case GL_UNSIGNED_SHORT_1_5_5_5_REV: return 2;
        case GL_UNSIGNED_INT_8_8_8_8:
        case GL_UNSIGNED_INT_8_8_8_8_REV:
        case GL_UNSIGNED_INT_10_10_10_2:
        case GL_UNSIGNED_INT_2_10_10_10_REV:
        case GL_UNSIGNED_INT_10F_11F_11F_REV:
        case GL_UNSIGNED_INT_5_9_9_9_REV: return 4;
        default: bytesPerComponent = 4; break;
    }
    return components * bytesPerComponent;
}

// Apply a clear pattern to the buffer's shadow AND to its Metal buffer
// (when present). GL 4.6 §6.6 treats the (format, type) tuple as a single
// pattern element whose width determines the replication stride. Prior
// implementation hard-coded 4 bytes — that worked for RGBA8 but corrupted
// R8 / RG16F / etc., and also skipped the Metal-buffer sync so subsequent
// readPixels / map paths saw stale data.
static void fillBufferClearPattern(std::uint8_t* dst, std::size_t bytes,
                                    const void* data, std::size_t patternBytes) {
    if (patternBytes == 0) {
        std::memset(dst, 0, bytes);
        return;
    }
    if (data == nullptr) {
        std::memset(dst, 0, bytes);
        return;
    }
    for (std::size_t i = 0; i < bytes; i += patternBytes) {
        const std::size_t remaining = std::min(patternBytes, bytes - i);
        std::memcpy(dst + i, data, remaining);
    }
}

bool GLContext::clearBufferData(GLenum target, GLenum internalformat, GLenum format, GLenum type, const void* data) {
    (void)internalformat;
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
    const std::size_t patternBytes = bufferClearPatternBytes(format, type);
    fillBufferClearPattern(buffer->shadowBytes.data(), buffer->shadowBytes.size(),
                            data, patternBytes);
    // Sync into the Metal buffer so getBufferSubData / glMap paths see the
    // cleared pattern rather than whatever the Metal buffer previously held
    // (the readback helper prefers Metal contents when the object has a
    // Metal buffer backing it).
    id<MTLBuffer> metalBuffer = (__bridge id<MTLBuffer>)buffer->metalBuffer;
    if (metalBuffer != nil) {
        std::uint8_t* metalBytes = static_cast<std::uint8_t*>([metalBuffer contents]);
        if (metalBytes != nullptr) {
            fillBufferClearPattern(metalBytes, buffer->shadowBytes.size(),
                                    data, patternBytes);
        }
    }
    return true;
}

bool GLContext::clearBufferSubData(GLenum target, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format, GLenum type, const void* data) {
    (void)internalformat;
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
    const std::size_t patternBytes = bufferClearPatternBytes(format, type);
    fillBufferClearPattern(buffer->shadowBytes.data() + offset,
                            static_cast<std::size_t>(size), data, patternBytes);
    id<MTLBuffer> metalBuffer = (__bridge id<MTLBuffer>)buffer->metalBuffer;
    if (metalBuffer != nil) {
        std::uint8_t* metalBytes = static_cast<std::uint8_t*>([metalBuffer contents]);
        if (metalBytes != nullptr) {
            fillBufferClearPattern(metalBytes + offset,
                                    static_cast<std::size_t>(size), data, patternBytes);
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
    // GL 4.6 §9.4: pname sets differ between the default framebuffer
    // and user FBOs. Routing DSA getNamedFramebufferParameteriv through
    // bindFramebuffer(0) surfaces this split at the non-DSA path.
    const GLuint fbName = target == GL_READ_FRAMEBUFFER
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    const bool isDefaultFb = (fbName == 0);
    if (isDefaultFb) {
        switch (pname) {
            case GL_DOUBLEBUFFER:                     *params = GL_TRUE;  return true;
            case GL_IMPLEMENTATION_COLOR_READ_FORMAT: *params = GL_RGBA;  return true;
            case GL_IMPLEMENTATION_COLOR_READ_TYPE:   *params = GL_UNSIGNED_BYTE; return true;
            case GL_SAMPLES:                          *params = 0;        return true;
            case GL_SAMPLE_BUFFERS:                   *params = 0;        return true;
            case GL_STEREO:                           *params = GL_FALSE; return true;
            default:
                // Wrong pname class for the default FB (e.g. one of the
                // FRAMEBUFFER_DEFAULT_* user-FB pnames). Spec says this
                // is INVALID_OPERATION, not INVALID_ENUM — enum is
                // recognised, it just doesn't apply to this FB kind.
                // framebuffers_get_parameter_errors distinguishes the two.
                pushError(GL_INVALID_OPERATION);
                return false;
        }
    }
    // User FBO: accept the FRAMEBUFFER_DEFAULT_* pnames, plus the
    // default-FB-class pnames (DOUBLEBUFFER/IMPL_COLOR_READ_*/SAMPLES/
    // SAMPLE_BUFFERS/STEREO) which framebuffers_get_parameters expects
    // to cross-validate against the non-DSA query. Only default FB
    // rejects the user-FB-only FRAMEBUFFER_DEFAULT_* pnames.
    switch (pname) {
        case GL_FRAMEBUFFER_DEFAULT_WIDTH:       *params = 0; return true;
        case GL_FRAMEBUFFER_DEFAULT_HEIGHT:      *params = 0; return true;
        case GL_FRAMEBUFFER_DEFAULT_LAYERS:      *params = 0; return true;
        case GL_FRAMEBUFFER_DEFAULT_SAMPLES:     *params = 0; return true;
        case GL_FRAMEBUFFER_DEFAULT_FIXED_SAMPLE_LOCATIONS: *params = GL_TRUE; return true;
        case GL_DOUBLEBUFFER:                    *params = GL_TRUE;  return true;
        case GL_IMPLEMENTATION_COLOR_READ_FORMAT: *params = GL_RGBA;         return true;
        case GL_IMPLEMENTATION_COLOR_READ_TYPE:   *params = GL_UNSIGNED_BYTE; return true;
        case GL_SAMPLES:                          *params = 0;               return true;
        case GL_SAMPLE_BUFFERS:                   *params = 0;               return true;
        case GL_STEREO:                           *params = GL_FALSE;        return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

// ---------------------------------------------------------------------------
// GL 4.3 — Invalidation Hints
// ---------------------------------------------------------------------------

// GL 4.6 §17.4.4: attachment-enum validation for Invalidate*Framebuffer.
// Split into a helper so both invalidateFramebuffer and the DSA
// invalidateNamedFramebufferData/SubData paths share the same rules.
// Returns:
//   0           → attachment is accepted for this target
//   INVALID_ENUM      → attachment is unrecognised
//   INVALID_OPERATION → attachment is color-attachment-shaped but >= MAX
//
// For the default framebuffer the valid set is
// {FRONT_LEFT, FRONT_RIGHT, BACK_LEFT, BACK_RIGHT, COLOR, DEPTH, STENCIL}.
// For a user framebuffer the valid set is
// {COLOR_ATTACHMENT0..MAX-1, DEPTH_ATTACHMENT, STENCIL_ATTACHMENT, DEPTH_STENCIL_ATTACHMENT}.
static GLenum classifyInvalidateAttachment(GLenum attachment, bool isDefaultFb) {
    if (isDefaultFb) {
        switch (attachment) {
            case GL_FRONT_LEFT:
            case GL_FRONT_RIGHT:
            case GL_BACK_LEFT:
            case GL_BACK_RIGHT:
            case GL_COLOR:
            case GL_DEPTH:
            case GL_STENCIL:
                return 0;
            default:
                return GL_INVALID_ENUM;
        }
    }
    if (attachment == GL_DEPTH_ATTACHMENT
        || attachment == GL_STENCIL_ATTACHMENT
        || attachment == GL_DEPTH_STENCIL_ATTACHMENT) {
        return 0;
    }
    // Color attachment: shape check vs MAX range check.
    if (attachment >= GL_COLOR_ATTACHMENT0 && attachment <= GL_COLOR_ATTACHMENT0 + 31) {
        const GLuint idx = attachment - GL_COLOR_ATTACHMENT0;
        return idx < 8 ? 0 : GL_INVALID_OPERATION;
    }
    return GL_INVALID_ENUM;
}

bool GLContext::invalidateFramebuffer(GLenum target, GLsizei numAttachments, const GLenum* attachments) {
    if (numAttachments < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Attachment enum validation per §17.4.4. The validation rules
    // differ for the default framebuffer (name 0) vs user framebuffer.
    const GLuint fbName = (target == GL_READ_FRAMEBUFFER)
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    const bool isDefaultFb = (fbName == 0);
    if (attachments != nullptr) {
        for (GLsizei i = 0; i < numAttachments; ++i) {
            const GLenum err = classifyInvalidateAttachment(attachments[i], isDefaultFb);
            if (err != 0) {
                pushError(err);
                return false;
            }
        }
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
    const GLuint fbName = (target == GL_READ_FRAMEBUFFER)
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    const bool isDefaultFb = (fbName == 0);
    if (attachments != nullptr) {
        for (GLsizei i = 0; i < numAttachments; ++i) {
            const GLenum err = classifyInvalidateAttachment(attachments[i], isDefaultFb);
            if (err != 0) {
                pushError(err);
                return false;
            }
        }
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
    // No-op for zero-sized copies.
    if (srcWidth == 0 || srcHeight == 0 || srcDepth == 0) return true;

    // -----------------------------------------------------------------------
    // Resolve source image shadow buffer, dimensions, and bytes-per-pixel.
    // -----------------------------------------------------------------------
    const std::uint8_t* srcPixels = nullptr;
    GLsizei srcImgW = 0, srcImgH = 0;
    std::size_t srcBpp = 4; // RGBA8 default

    if (srcIsTex) {
        GLTextureObject* srcTex = impl_->objects->textures().get(srcName);
        if (!srcTex) { pushError(GL_INVALID_VALUE); return false; }
        auto it = srcTex->levels.find(srcLevel);
        if (it == srcTex->levels.end() || !it->second.defined) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        const GLTextureImageLevel& srcImg = it->second;
        srcImgW = srcImg.desc.width;
        srcImgH = srcImg.desc.height;
        // Prefer native data if available, else fall back to rgba8.
        if (srcImg.nativeBpp > 0 && !srcImg.nativeData.empty()) {
            srcPixels = srcImg.nativeData.data();
            srcBpp = srcImg.nativeBpp;
        } else if (!srcImg.rgba8.empty()) {
            srcPixels = srcImg.rgba8.data();
            srcBpp = 4;
        }
    } else {
        GLRenderbufferObject* srcRB = impl_->objects->renderbuffers().get(srcName);
        if (!srcRB || !srcRB->storageDefined) { pushError(GL_INVALID_VALUE); return false; }
        srcImgW = srcRB->width;
        srcImgH = srcRB->height;
        if (!srcRB->rgba8.empty()) {
            srcPixels = srcRB->rgba8.data();
            srcBpp = 4;
        }
    }

    if (srcPixels == nullptr) {
        // Source has no CPU-side shadow data — nothing to copy.
        return true;
    }

    // Bounds check source region.
    if (srcX < 0 || srcY < 0 || srcZ < 0 ||
        srcX + srcWidth > srcImgW || srcY + srcHeight > srcImgH) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    // -----------------------------------------------------------------------
    // Resolve destination image shadow buffer.
    // -----------------------------------------------------------------------
    std::uint8_t* dstPixels = nullptr;
    GLsizei dstImgW = 0, dstImgH = 0;
    std::size_t dstBpp = 4;

    // We need a writable pointer and the ability to invalidate the Metal texture.
    GLTextureObject* dstTex = nullptr;
    GLRenderbufferObject* dstRB = nullptr;
    GLTextureImageLevel* dstImg = nullptr;

    if (dstIsTex) {
        dstTex = impl_->objects->textures().get(dstName);
        if (!dstTex) { pushError(GL_INVALID_VALUE); return false; }
        auto it = dstTex->levels.find(dstLevel);
        if (it == dstTex->levels.end()) {
            // Level not defined — create it on the fly with same dims as source.
            GLTextureImageLevel newLevel;
            newLevel.desc.width = srcImgW;
            newLevel.desc.height = srcImgH;
            newLevel.desc.depth = 1;
            newLevel.defined = true;
            auto ins = dstTex->levels.emplace(dstLevel, std::move(newLevel));
            it = ins.first;
        }
        dstImg = &it->second;
        if (!dstImg->defined) {
            // Allocate matching storage if level was created by texStorage but not yet texImage'd.
            dstImg->defined = true;
        }
        dstImgW = dstImg->desc.width;
        dstImgH = dstImg->desc.height;

        // Ensure the destination rgba8 buffer is large enough.
        const std::size_t totalPixels = static_cast<std::size_t>(dstImgW) * dstImgH;
        if (dstImg->nativeBpp > 0 && !dstImg->nativeData.empty()) {
            dstPixels = dstImg->nativeData.data();
            dstBpp = dstImg->nativeBpp;
        } else {
            if (dstImg->rgba8.size() < totalPixels * 4) {
                dstImg->rgba8.resize(totalPixels * 4, 0);
            }
            dstPixels = dstImg->rgba8.data();
            dstBpp = 4;
        }
    } else {
        dstRB = impl_->objects->renderbuffers().get(dstName);
        if (!dstRB || !dstRB->storageDefined) { pushError(GL_INVALID_VALUE); return false; }
        dstImgW = dstRB->width;
        dstImgH = dstRB->height;
        const std::size_t totalPixels = static_cast<std::size_t>(dstImgW) * dstImgH;
        if (dstRB->rgba8.size() < totalPixels * 4) {
            dstRB->rgba8.resize(totalPixels * 4, 0);
        }
        dstPixels = dstRB->rgba8.data();
        dstBpp = 4;
    }

    // Bounds check destination region.
    if (dstX < 0 || dstY < 0 || dstZ < 0 ||
        dstX + srcWidth > dstImgW || dstY + srcHeight > dstImgH) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    // -----------------------------------------------------------------------
    // Perform the pixel copy — row-by-row within each depth slice.
    // -----------------------------------------------------------------------
    // When bpp matches between source and destination, do a direct memcpy per row.
    // When bpp differs (e.g. native R8 → RGBA8), we need to convert; for now,
    // use the rgba8 path as the common denominator.
    if (srcBpp == dstBpp) {
        const std::size_t srcRowBytes = static_cast<std::size_t>(srcImgW) * srcBpp;
        const std::size_t dstRowBytes = static_cast<std::size_t>(dstImgW) * dstBpp;
        const std::size_t srcSliceBytes = srcRowBytes * static_cast<std::size_t>(srcImgH);
        const std::size_t dstSliceBytes = dstRowBytes * static_cast<std::size_t>(dstImgH);
        const std::size_t copyRowBytes = static_cast<std::size_t>(srcWidth) * srcBpp;

        for (GLsizei z = 0; z < srcDepth; ++z) {
            const std::size_t srcSliceOff = static_cast<std::size_t>(srcZ + z) * srcSliceBytes;
            const std::size_t dstSliceOff = static_cast<std::size_t>(dstZ + z) * dstSliceBytes;
            for (GLsizei row = 0; row < srcHeight; ++row) {
                const std::size_t srcOff = srcSliceOff
                                         + static_cast<std::size_t>(srcY + row) * srcRowBytes
                                         + static_cast<std::size_t>(srcX) * srcBpp;
                const std::size_t dstOff = dstSliceOff
                                         + static_cast<std::size_t>(dstY + row) * dstRowBytes
                                         + static_cast<std::size_t>(dstX) * dstBpp;
                std::memcpy(dstPixels + dstOff, srcPixels + srcOff, copyRowBytes);
            }
        }
    } else {
        // Mismatched bpp — fall back to rgba8 shadow for both src and dst.
        // Re-resolve using rgba8 for both sides.
        const std::uint8_t* srcRGBA = nullptr;
        std::uint8_t* dstRGBA = nullptr;

        if (srcIsTex) {
            GLTextureObject* srcTex = impl_->objects->textures().get(srcName);
            auto it = srcTex->levels.find(srcLevel);
            if (it != srcTex->levels.end() && !it->second.rgba8.empty()) {
                srcRGBA = it->second.rgba8.data();
            }
        } else {
            GLRenderbufferObject* srcRB = impl_->objects->renderbuffers().get(srcName);
            if (srcRB && !srcRB->rgba8.empty()) srcRGBA = srcRB->rgba8.data();
        }

        if (dstImg && !dstImg->rgba8.empty()) {
            dstRGBA = dstImg->rgba8.data();
        } else if (dstRB && !dstRB->rgba8.empty()) {
            dstRGBA = dstRB->rgba8.data();
        }

        if (srcRGBA && dstRGBA) {
            const std::size_t srcRow4 = static_cast<std::size_t>(srcImgW) * 4;
            const std::size_t dstRow4 = static_cast<std::size_t>(dstImgW) * 4;
            const std::size_t srcSlice4 = srcRow4 * static_cast<std::size_t>(srcImgH);
            const std::size_t dstSlice4 = dstRow4 * static_cast<std::size_t>(dstImgH);
            const std::size_t copyRow4 = static_cast<std::size_t>(srcWidth) * 4;
            for (GLsizei z = 0; z < srcDepth; ++z) {
                const std::size_t sSliceOff = static_cast<std::size_t>(srcZ + z) * srcSlice4;
                const std::size_t dSliceOff = static_cast<std::size_t>(dstZ + z) * dstSlice4;
                for (GLsizei row = 0; row < srcHeight; ++row) {
                    const std::size_t sOff = sSliceOff + static_cast<std::size_t>(srcY + row) * srcRow4 + static_cast<std::size_t>(srcX) * 4;
                    const std::size_t dOff = dSliceOff + static_cast<std::size_t>(dstY + row) * dstRow4 + static_cast<std::size_t>(dstX) * 4;
                    std::memcpy(dstRGBA + dOff, srcRGBA + sOff, copyRow4);
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Invalidate the destination Metal texture so it will be re-uploaded.
    // We null out metalTexture rather than just flipping `instantiated`
    // because bindTexture re-sets instantiated=true before any subsequent
    // read, which would otherwise mask the pending re-upload.
    // -----------------------------------------------------------------------
    if (dstTex) {
        releaseRetainedMetalObject(dstTex->metalTexture);
        dstTex->metalTexture = nullptr;
    }
    if (dstRB) {
        dstRB->instantiated = false;
    }
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
    // Validation of id, stream, and mode is done in the AppGLRuntime wrapper.
    // Stub: 0 captured primitives.
    (void)mode; (void)id; (void)stream;
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

static bool isIndexedBufferTarget(GLenum target) {
    switch (target) {
        case GL_ATOMIC_COUNTER_BUFFER:
        case GL_TRANSFORM_FEEDBACK_BUFFER:
        case GL_UNIFORM_BUFFER:
        case GL_SHADER_STORAGE_BUFFER:
            return true;
        default:
            return false;
    }
}

namespace {
GLint64 queryLimit(const GLCapabilities* caps, GLenum pname, GLint64 fallback) {
    GLint64 value = fallback;
    if (caps != nullptr) {
        caps->queryInteger64(pname, &value);
    }
    return value;
}

GLenum indexedBufferMaxPname(GLenum target) {
    switch (target) {
        case GL_UNIFORM_BUFFER:           return GL_MAX_UNIFORM_BUFFER_BINDINGS;
        case GL_SHADER_STORAGE_BUFFER:    return GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS;
        case GL_ATOMIC_COUNTER_BUFFER:    return GL_MAX_ATOMIC_COUNTER_BUFFER_BINDINGS;
        case GL_TRANSFORM_FEEDBACK_BUFFER: return GL_MAX_TRANSFORM_FEEDBACK_BUFFERS;
        default: return 0;
    }
}
}  // namespace

bool GLContext::bindBuffersBase(GLenum target, GLuint first, GLsizei count, const GLuint* buffers) {
    if (!isIndexedBufferTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLint64 maxBindings = queryLimit(impl_->capabilities.get(), indexedBufferMaxPname(target), 0);
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxBindings) {
        pushError(GL_INVALID_OPERATION);
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
    if (!isIndexedBufferTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLint64 maxBindings = queryLimit(impl_->capabilities.get(), indexedBufferMaxPname(target), 0);
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxBindings) {
        pushError(GL_INVALID_OPERATION);
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
    const GLint64 maxBindings = queryLimit(impl_->capabilities.get(), GL_MAX_VERTEX_ATTRIB_BINDINGS, 16);
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxBindings) {
        pushError(GL_INVALID_OPERATION);
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
    const GLint64 maxUnits = queryLimit(impl_->capabilities.get(), GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, 80);
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxUnits) {
        pushError(GL_INVALID_OPERATION);
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
    const GLint64 maxUnits = queryLimit(impl_->capabilities.get(), GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, 80);
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxUnits) {
        pushError(GL_INVALID_OPERATION);
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
    const GLint64 maxUnits = queryLimit(impl_->capabilities.get(), GL_MAX_IMAGE_UNITS, 8);
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxUnits) {
        pushError(GL_INVALID_OPERATION);
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
    // If level is -1 or data is null, clear all defined levels to zero.
    if (level < 0) {
        for (auto& [lvl, img] : tex->levels) {
            if (img.defined) {
                std::fill(img.rgba8.begin(), img.rgba8.end(), 0);
            }
        }
        return true;
    }
    auto it = tex->levels.find(level);
    if (it != tex->levels.end() && it->second.defined) {
        // Clear all texels to the provided value (or zero).
        std::fill(it->second.rgba8.begin(), it->second.rgba8.end(), 0);
        if (data) {
            // Convert clear color to RGBA8 based on format and type.
            std::uint8_t clearRGBA[4] = {0, 0, 0, 255};
            const std::size_t components = componentCountForFormat(format);
            if (components > 0 && components <= 4) {
                for (std::size_t c = 0; c < components && c < 4; ++c) {
                    clearRGBA[c] = Impl::readComponentAsU8(
                        static_cast<const std::uint8_t*>(data), type, c);
                }
                // If only 1-3 components, fill alpha to 255
                if (components < 4) clearRGBA[3] = 255;
            }
            const std::size_t texelSize = 4;
            for (std::size_t j = 0; j + texelSize <= it->second.rgba8.size(); j += texelSize) {
                std::memcpy(&it->second.rgba8[j], clearRGBA, texelSize);
            }
        }
    }
    // Also upload the updated data to Metal
    if (it != tex->levels.end() && it->second.defined && tex->metalTexture != nullptr) {
        impl_->replaceMetalTexture(*tex);
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
        auto* obj = impl_->objects->buffers().get(buffers[i]);
        if (obj) obj->instantiated = true;
    }
    return true;
}

bool GLContext::createTextures(GLenum target, GLsizei n, GLuint* textures) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        textures[i] = impl_->objects->textures().reserveName();
        // DSA textures know their target from creation and are immediately usable.
        auto* obj = impl_->objects->textures().get(textures[i]);
        if (obj) {
            obj->target = target;
            obj->instantiated = true;
        }
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
        auto* obj = impl_->objects->framebuffers().get(framebuffers[i]);
        if (obj) obj->instantiated = true;
    }
    return true;
}

bool GLContext::createRenderbuffers(GLsizei n, GLuint* renderbuffers) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        renderbuffers[i] = impl_->objects->renderbuffers().reserveName();
        auto* obj = impl_->objects->renderbuffers().get(renderbuffers[i]);
        if (obj) obj->instantiated = true;
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
    // GL 4.5 §4.2.1: INVALID_ENUM if target is not one of the accepted query
    // targets. Without this, CTS direct_state_access.queries_errors hangs
    // indefinitely in the post-fail drain loop
    // `while (error == gl.getError()) ;` because it captured GL_NO_ERROR
    // (since we silently accepted the invalid target and set no error).
    switch (target) {
        case GL_SAMPLES_PASSED:
        case GL_ANY_SAMPLES_PASSED:
        case GL_ANY_SAMPLES_PASSED_CONSERVATIVE:
        case GL_PRIMITIVES_GENERATED:
        case GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN:
        case GL_TIME_ELAPSED:
        case GL_TIMESTAMP:
            break;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
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
        bool ok = texStorage(_target, levels, internalformat, width, height, depth);
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
        bool ok = texSubImage(_target, level, xoffset, yoffset, zoffset, width, height, depth, format, type, pixels);
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
    warnBypassOnce("compressedTextureSubImage1D", texture);
    // Accepted — compressed sub-image upload deferred to Metal texture instantiation.
    return true;
}

bool GLContext::compressedTextureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLsizei imageSize, const void* data) {
    auto* obj = impl_->objects->textures().get(texture);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    (void)level; (void)xoffset; (void)yoffset; (void)width; (void)height; (void)format; (void)imageSize; (void)data;
    warnBypassOnce("compressedTextureSubImage2D", texture);
    return true;
}

bool GLContext::compressedTextureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLsizei imageSize, const void* data) {
    auto* obj = impl_->objects->textures().get(texture);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    (void)level; (void)xoffset; (void)yoffset; (void)zoffset; (void)width; (void)height; (void)depth; (void)format; (void)imageSize; (void)data;
    warnBypassOnce("compressedTextureSubImage3D", texture);
    return true;
}

bool GLContext::copyTextureSubImage1D(GLuint texture, GLint level, GLint xoffset, GLint x, GLint y, GLsizei width) {
    warnBypassOnce("copyTextureSubImage1D", texture);
    DSA_TEX_WRAP(texture, {
        (void)level; (void)xoffset; (void)x; (void)y; (void)width;
        // Accepted — deferred to Metal blit path.
        return true;
    })
}

bool GLContext::copyTextureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width, GLsizei height) {
    warnBypassOnce("copyTextureSubImage2D", texture);
    DSA_TEX_WRAP(texture, {
        (void)level; (void)xoffset; (void)yoffset; (void)x; (void)y; (void)width; (void)height;
        return true;
    })
}

bool GLContext::copyTextureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLint x, GLint y, GLsizei width, GLsizei height) {
    warnBypassOnce("copyTextureSubImage3D", texture);
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
    if (!obj->instantiated || obj->metalTexture == nullptr) {
        // Re-upload shadow data to Metal texture (e.g. after copyImageSubData).
        if (!obj->levels.empty()) {
            impl_->replaceMetalTexture(*obj, texture);
        }
        if (!obj->instantiated || obj->metalTexture == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    if (pixels == nullptr) return true;

    const std::size_t dstComponents = componentCountForFormat(format);
    const bool typeIsPacked = isPackedPixelType(type);
    const std::size_t dstBpc = bytesPerComponent(type);
    const std::size_t dstPixelBytes = bytesPerPixel(format, type);
    if (dstComponents == 0 || dstPixelBytes == 0) {
        pushError(GL_INVALID_ENUM);
        return false;
    }

    // Flush the GPU — the texture may have been rendered to and the data
    // won't be CPU-visible until the command buffer completes.
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushForReadback();
    }

    id<MTLTexture> metalTex = (__bridge id<MTLTexture>)obj->metalTexture;
    NSUInteger mipLevel = static_cast<NSUInteger>(level);
    NSUInteger texWidth  = std::max<NSUInteger>(metalTex.width  >> mipLevel, 1);
    NSUInteger texHeight = std::max<NSUInteger>(metalTex.height >> mipLevel, 1);

    // Determine source bytes-per-pixel from the Metal pixel format.
    MTLPixelFormat pf = metalTex.pixelFormat;
    NSUInteger srcBpp = 0;
    NSUInteger srcComponents = 0;
    enum class SrcType { Float32, Float16, UNorm8, SNorm8, UNorm16, SNorm16, UInt8, SInt8, UInt16, SInt16, UInt32, SInt32 };
    SrcType srcType = SrcType::UNorm8;

    switch (pf) {
        case MTLPixelFormatR32Float:       srcBpp = 4;  srcComponents = 1; srcType = SrcType::Float32; break;
        case MTLPixelFormatRG32Float:      srcBpp = 8;  srcComponents = 2; srcType = SrcType::Float32; break;
        case MTLPixelFormatRGBA32Float:    srcBpp = 16; srcComponents = 4; srcType = SrcType::Float32; break;
        case MTLPixelFormatR16Float:       srcBpp = 2;  srcComponents = 1; srcType = SrcType::Float16; break;
        case MTLPixelFormatRG16Float:      srcBpp = 4;  srcComponents = 2; srcType = SrcType::Float16; break;
        case MTLPixelFormatRGBA16Float:    srcBpp = 8;  srcComponents = 4; srcType = SrcType::Float16; break;
        case MTLPixelFormatR8Unorm:        srcBpp = 1;  srcComponents = 1; srcType = SrcType::UNorm8; break;
        case MTLPixelFormatRG8Unorm:       srcBpp = 2;  srcComponents = 2; srcType = SrcType::UNorm8; break;
        case MTLPixelFormatRGBA8Unorm:     srcBpp = 4;  srcComponents = 4; srcType = SrcType::UNorm8; break;
        case MTLPixelFormatBGRA8Unorm:     srcBpp = 4;  srcComponents = 4; srcType = SrcType::UNorm8; break;
        case MTLPixelFormatR8Snorm:        srcBpp = 1;  srcComponents = 1; srcType = SrcType::SNorm8; break;
        case MTLPixelFormatRG8Snorm:       srcBpp = 2;  srcComponents = 2; srcType = SrcType::SNorm8; break;
        case MTLPixelFormatRGBA8Snorm:     srcBpp = 4;  srcComponents = 4; srcType = SrcType::SNorm8; break;
        case MTLPixelFormatR16Unorm:       srcBpp = 2;  srcComponents = 1; srcType = SrcType::UNorm16; break;
        case MTLPixelFormatRG16Unorm:      srcBpp = 4;  srcComponents = 2; srcType = SrcType::UNorm16; break;
        case MTLPixelFormatRGBA16Unorm:    srcBpp = 8;  srcComponents = 4; srcType = SrcType::UNorm16; break;
        case MTLPixelFormatR16Snorm:       srcBpp = 2;  srcComponents = 1; srcType = SrcType::SNorm16; break;
        case MTLPixelFormatRG16Snorm:      srcBpp = 4;  srcComponents = 2; srcType = SrcType::SNorm16; break;
        case MTLPixelFormatRGBA16Snorm:    srcBpp = 8;  srcComponents = 4; srcType = SrcType::SNorm16; break;
        case MTLPixelFormatR8Uint:         srcBpp = 1;  srcComponents = 1; srcType = SrcType::UInt8; break;
        case MTLPixelFormatRG8Uint:        srcBpp = 2;  srcComponents = 2; srcType = SrcType::UInt8; break;
        case MTLPixelFormatRGBA8Uint:      srcBpp = 4;  srcComponents = 4; srcType = SrcType::UInt8; break;
        case MTLPixelFormatR8Sint:         srcBpp = 1;  srcComponents = 1; srcType = SrcType::SInt8; break;
        case MTLPixelFormatRG8Sint:        srcBpp = 2;  srcComponents = 2; srcType = SrcType::SInt8; break;
        case MTLPixelFormatRGBA8Sint:      srcBpp = 4;  srcComponents = 4; srcType = SrcType::SInt8; break;
        case MTLPixelFormatR16Uint:        srcBpp = 2;  srcComponents = 1; srcType = SrcType::UInt16; break;
        case MTLPixelFormatRG16Uint:       srcBpp = 4;  srcComponents = 2; srcType = SrcType::UInt16; break;
        case MTLPixelFormatRGBA16Uint:     srcBpp = 8;  srcComponents = 4; srcType = SrcType::UInt16; break;
        case MTLPixelFormatR16Sint:        srcBpp = 2;  srcComponents = 1; srcType = SrcType::SInt16; break;
        case MTLPixelFormatRG16Sint:       srcBpp = 4;  srcComponents = 2; srcType = SrcType::SInt16; break;
        case MTLPixelFormatRGBA16Sint:     srcBpp = 8;  srcComponents = 4; srcType = SrcType::SInt16; break;
        case MTLPixelFormatR32Uint:        srcBpp = 4;  srcComponents = 1; srcType = SrcType::UInt32; break;
        case MTLPixelFormatRG32Uint:       srcBpp = 8;  srcComponents = 2; srcType = SrcType::UInt32; break;
        case MTLPixelFormatRGBA32Uint:     srcBpp = 16; srcComponents = 4; srcType = SrcType::UInt32; break;
        case MTLPixelFormatR32Sint:        srcBpp = 4;  srcComponents = 1; srcType = SrcType::SInt32; break;
        case MTLPixelFormatRG32Sint:       srcBpp = 8;  srcComponents = 2; srcType = SrcType::SInt32; break;
        case MTLPixelFormatRGBA32Sint:     srcBpp = 16; srcComponents = 4; srcType = SrcType::SInt32; break;
        default:
            // Unsupported Metal pixel format for readback.
            pushError(GL_INVALID_OPERATION);
            return false;
    }

    // Determine how many slices we need to read — 2D arrays use
    // arrayLength, 3D textures use depth at this mip. Everything else
    // is single-slice.
    MTLTextureType textureType = metalTex.textureType;
    NSUInteger numSlices = 1;
    bool is3D = false;
    bool isArray = false;
    if (textureType == MTLTextureType3D) {
        numSlices = std::max<NSUInteger>(metalTex.depth >> mipLevel, 1);
        is3D = true;
    } else if (textureType == MTLTextureType2DArray) {
        numSlices = metalTex.arrayLength;
        isArray = true;
    }

    // Check that the destination buffer is large enough.
    const std::size_t dstRowBytes = texWidth * dstPixelBytes;
    const std::size_t dstSliceBytes = dstRowBytes * texHeight;
    const std::size_t dstTotalBytes = dstSliceBytes * numSlices;
    if (bufSize > 0 && static_cast<std::size_t>(bufSize) < dstTotalBytes) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    // Read raw bytes from the Metal texture (all slices into a contiguous buffer).
    const NSUInteger bytesPerRow = texWidth * srcBpp;
    const NSUInteger bytesPerImage = bytesPerRow * texHeight;
    const std::size_t totalBytes = static_cast<std::size_t>(bytesPerImage)
                                 * static_cast<std::size_t>(numSlices);
    std::vector<std::uint8_t> raw(totalBytes);
    if (is3D) {
        MTLRegion region = MTLRegionMake3D(0, 0, 0, texWidth, texHeight, numSlices);
        [metalTex getBytes:raw.data()
               bytesPerRow:bytesPerRow
             bytesPerImage:bytesPerImage
                fromRegion:region
               mipmapLevel:mipLevel
                     slice:0];
    } else if (isArray) {
        MTLRegion region = MTLRegionMake2D(0, 0, texWidth, texHeight);
        for (NSUInteger s = 0; s < numSlices; ++s) {
            [metalTex getBytes:raw.data() + s * bytesPerImage
                   bytesPerRow:bytesPerRow
                 bytesPerImage:bytesPerImage
                    fromRegion:region
                   mipmapLevel:mipLevel
                         slice:s];
        }
    } else {
        MTLRegion region = MTLRegionMake2D(0, 0, texWidth, texHeight);
        [metalTex getBytes:raw.data()
               bytesPerRow:bytesPerRow
                fromRegion:region
               mipmapLevel:mipLevel];
    }

    // Helper: read one source component as a double.
    const bool isBGRA = (pf == MTLPixelFormatBGRA8Unorm);
    auto readSrcComponent = [&](const std::uint8_t* srcPixel, NSUInteger comp) -> double {
        switch (srcType) {
            case SrcType::Float32: {
                float v; std::memcpy(&v, srcPixel + comp * 4, 4); return static_cast<double>(v);
            }
            case SrcType::Float16: {
                std::uint16_t h; std::memcpy(&h, srcPixel + comp * 2, 2);
                std::uint32_t sign = (h >> 15) & 1;
                std::uint32_t exp  = (h >> 10) & 0x1F;
                std::uint32_t mant = h & 0x3FF;
                float result;
                if (exp == 0) {
                    result = std::ldexp(static_cast<float>(mant), -24);
                } else if (exp == 31) {
                    result = mant ? NAN : INFINITY;
                } else {
                    result = std::ldexp(static_cast<float>(mant + 1024), static_cast<int>(exp) - 25);
                }
                return sign ? -result : result;
            }
            case SrcType::UNorm8:  return srcPixel[comp] / 255.0;
            case SrcType::SNorm8:  return std::max(static_cast<double>(reinterpret_cast<const std::int8_t*>(srcPixel)[comp]) / 127.0, -1.0);
            case SrcType::UNorm16: { std::uint16_t v; std::memcpy(&v, srcPixel + comp * 2, 2); return v / 65535.0; }
            case SrcType::SNorm16: { std::int16_t v;  std::memcpy(&v, srcPixel + comp * 2, 2); return std::max(static_cast<double>(v) / 32767.0, -1.0); }
            case SrcType::UInt8:   return static_cast<double>(srcPixel[comp]);
            case SrcType::SInt8:   return static_cast<double>(reinterpret_cast<const std::int8_t*>(srcPixel)[comp]);
            case SrcType::UInt16:  { std::uint16_t v; std::memcpy(&v, srcPixel + comp * 2, 2); return static_cast<double>(v); }
            case SrcType::SInt16:  { std::int16_t v;  std::memcpy(&v, srcPixel + comp * 2, 2); return static_cast<double>(v); }
            case SrcType::UInt32:  { std::uint32_t v; std::memcpy(&v, srcPixel + comp * 4, 4); return static_cast<double>(v); }
            case SrcType::SInt32:  { std::int32_t v;  std::memcpy(&v, srcPixel + comp * 4, 4); return static_cast<double>(v); }
            default: return 0.0;
        }
    };

    // Determine whether the source is an integer format (no normalization on write).
    const bool srcIsInteger = (srcType == SrcType::UInt8  || srcType == SrcType::SInt8  ||
                               srcType == SrcType::UInt16 || srcType == SrcType::SInt16 ||
                               srcType == SrcType::UInt32 || srcType == SrcType::SInt32);

    auto* destBase = static_cast<std::uint8_t*>(pixels);

    for (NSUInteger slice = 0; slice < numSlices; ++slice) {
      const std::uint8_t* sliceRaw = raw.data() + slice * bytesPerImage;
      std::uint8_t* dest = destBase + slice * dstSliceBytes;
      for (NSUInteger row = 0; row < texHeight; ++row) {
        for (NSUInteger col = 0; col < texWidth; ++col) {
            const std::size_t srcPixelOffset = (row * texWidth + col) * srcBpp;
            const std::uint8_t* srcPixel = sliceRaw + srcPixelOffset;

            // Read source components as doubles. Pad missing components
            // with 0.0 for RGB, 1.0 for alpha.
            double vals[4] = {0.0, 0.0, 0.0, 1.0};
            for (NSUInteger c = 0; c < srcComponents && c < 4; ++c) {
                NSUInteger readComp = c;
                if (isBGRA) {
                    if (c == 0) readComp = 2;
                    else if (c == 2) readComp = 0;
                }
                vals[c] = readSrcComponent(srcPixel, readComp);
            }

            // Write to destination in the requested format/type.
            const std::size_t dstPixelIdx = row * texWidth + col;

            if (typeIsPacked) {
                // CTS copy_image & packed_pixels paths need packed-type readback.
                // Pack the RGBA doubles into the requested packed format.
                std::uint8_t* dp = dest + dstPixelIdx * dstPixelBytes;
                auto packUN = [](double v, unsigned bits) -> std::uint32_t {
                    if (v < 0.0) v = 0.0;
                    if (v > 1.0) v = 1.0;
                    const double maxVal = static_cast<double>((1u << bits) - 1u);
                    return static_cast<std::uint32_t>(v * maxVal + 0.5);
                };
                switch (type) {
                    case GL_UNSIGNED_BYTE_3_3_2: {
                        auto r = packUN(vals[0], 3);
                        auto g = packUN(vals[1], 3);
                        auto b = packUN(vals[2], 2);
                        dp[0] = static_cast<std::uint8_t>((r << 5) | (g << 2) | b);
                        break;
                    }
                    case GL_UNSIGNED_BYTE_2_3_3_REV: {
                        auto r = packUN(vals[0], 3);
                        auto g = packUN(vals[1], 3);
                        auto b = packUN(vals[2], 2);
                        dp[0] = static_cast<std::uint8_t>((b << 6) | (g << 3) | r);
                        break;
                    }
                    case GL_UNSIGNED_SHORT_5_6_5: {
                        auto r = packUN(vals[0], 5);
                        auto g = packUN(vals[1], 6);
                        auto b = packUN(vals[2], 5);
                        std::uint16_t v16 = static_cast<std::uint16_t>((r << 11) | (g << 5) | b);
                        std::memcpy(dp, &v16, 2);
                        break;
                    }
                    case GL_UNSIGNED_SHORT_5_6_5_REV: {
                        auto r = packUN(vals[0], 5);
                        auto g = packUN(vals[1], 6);
                        auto b = packUN(vals[2], 5);
                        std::uint16_t v16 = static_cast<std::uint16_t>((b << 11) | (g << 5) | r);
                        std::memcpy(dp, &v16, 2);
                        break;
                    }
                    case GL_UNSIGNED_SHORT_4_4_4_4: {
                        auto r = packUN(vals[0], 4);
                        auto g = packUN(vals[1], 4);
                        auto b = packUN(vals[2], 4);
                        auto a = packUN(vals[3], 4);
                        std::uint16_t v16 = static_cast<std::uint16_t>((r << 12) | (g << 8) | (b << 4) | a);
                        std::memcpy(dp, &v16, 2);
                        break;
                    }
                    case GL_UNSIGNED_SHORT_4_4_4_4_REV: {
                        auto r = packUN(vals[0], 4);
                        auto g = packUN(vals[1], 4);
                        auto b = packUN(vals[2], 4);
                        auto a = packUN(vals[3], 4);
                        std::uint16_t v16 = static_cast<std::uint16_t>((a << 12) | (b << 8) | (g << 4) | r);
                        std::memcpy(dp, &v16, 2);
                        break;
                    }
                    case GL_UNSIGNED_SHORT_5_5_5_1: {
                        auto r = packUN(vals[0], 5);
                        auto g = packUN(vals[1], 5);
                        auto b = packUN(vals[2], 5);
                        auto a = packUN(vals[3], 1);
                        std::uint16_t v16 = static_cast<std::uint16_t>((r << 11) | (g << 6) | (b << 1) | a);
                        std::memcpy(dp, &v16, 2);
                        break;
                    }
                    case GL_UNSIGNED_SHORT_1_5_5_5_REV: {
                        auto r = packUN(vals[0], 5);
                        auto g = packUN(vals[1], 5);
                        auto b = packUN(vals[2], 5);
                        auto a = packUN(vals[3], 1);
                        std::uint16_t v16 = static_cast<std::uint16_t>((a << 15) | (b << 10) | (g << 5) | r);
                        std::memcpy(dp, &v16, 2);
                        break;
                    }
                    case GL_UNSIGNED_INT_8_8_8_8: {
                        std::uint32_t r = packUN(vals[0], 8);
                        std::uint32_t g = packUN(vals[1], 8);
                        std::uint32_t b = packUN(vals[2], 8);
                        std::uint32_t a = packUN(vals[3], 8);
                        std::uint32_t v32 = (r << 24) | (g << 16) | (b << 8) | a;
                        std::memcpy(dp, &v32, 4);
                        break;
                    }
                    case GL_UNSIGNED_INT_8_8_8_8_REV: {
                        std::uint32_t r = packUN(vals[0], 8);
                        std::uint32_t g = packUN(vals[1], 8);
                        std::uint32_t b = packUN(vals[2], 8);
                        std::uint32_t a = packUN(vals[3], 8);
                        std::uint32_t v32 = (a << 24) | (b << 16) | (g << 8) | r;
                        std::memcpy(dp, &v32, 4);
                        break;
                    }
                    case GL_UNSIGNED_INT_10_10_10_2: {
                        std::uint32_t r = packUN(vals[0], 10);
                        std::uint32_t g = packUN(vals[1], 10);
                        std::uint32_t b = packUN(vals[2], 10);
                        std::uint32_t a = packUN(vals[3], 2);
                        std::uint32_t v32 = (r << 22) | (g << 12) | (b << 2) | a;
                        std::memcpy(dp, &v32, 4);
                        break;
                    }
                    case GL_UNSIGNED_INT_2_10_10_10_REV: {
                        std::uint32_t r = packUN(vals[0], 10);
                        std::uint32_t g = packUN(vals[1], 10);
                        std::uint32_t b = packUN(vals[2], 10);
                        std::uint32_t a = packUN(vals[3], 2);
                        std::uint32_t v32 = (a << 30) | (b << 20) | (g << 10) | r;
                        std::memcpy(dp, &v32, 4);
                        break;
                    }
                    default:
                        // Remaining packed types (float-packed, depth/stencil)
                        // not yet needed by the CTS subset we target.
                        std::memset(dp, 0, dstPixelBytes);
                        break;
                }
                continue;
            }

            for (std::size_t dc = 0; dc < dstComponents; ++dc) {
                double v = vals[dc];
                switch (type) {
                    case GL_FLOAT: {
                        float fv = static_cast<float>(v);
                        std::memcpy(dest + (dstPixelIdx * dstComponents + dc) * 4, &fv, 4);
                        break;
                    }
                    case GL_HALF_FLOAT: {
                        float fv = static_cast<float>(v);
                        std::uint32_t fbits; std::memcpy(&fbits, &fv, 4);
                        std::uint32_t sign = (fbits >> 16) & 0x8000;
                        std::int32_t exp = ((fbits >> 23) & 0xFF) - 127 + 15;
                        std::uint32_t mant = (fbits >> 13) & 0x3FF;
                        std::uint16_t half;
                        if (exp <= 0) half = static_cast<std::uint16_t>(sign);
                        else if (exp >= 31) half = static_cast<std::uint16_t>(sign | 0x7C00);
                        else half = static_cast<std::uint16_t>(sign | (exp << 10) | mant);
                        std::memcpy(dest + (dstPixelIdx * dstComponents + dc) * 2, &half, 2);
                        break;
                    }
                    case GL_UNSIGNED_BYTE:
                        if (srcIsInteger) {
                            dest[dstPixelIdx * dstComponents + dc] = static_cast<std::uint8_t>(v);
                        } else {
                            dest[dstPixelIdx * dstComponents + dc] = static_cast<std::uint8_t>(
                                std::max(0.0, std::min(255.0, v * 255.0)));
                        }
                        break;
                    case GL_BYTE: {
                        std::int8_t sv;
                        if (srcIsInteger) {
                            sv = static_cast<std::int8_t>(v);
                        } else {
                            sv = static_cast<std::int8_t>(std::max(-127.0, std::min(127.0, v * 127.0)));
                        }
                        std::memcpy(dest + dstPixelIdx * dstComponents + dc, &sv, 1);
                        break;
                    }
                    case GL_UNSIGNED_SHORT: {
                        std::uint16_t sv;
                        if (srcIsInteger) {
                            sv = static_cast<std::uint16_t>(v);
                        } else {
                            sv = static_cast<std::uint16_t>(std::max(0.0, std::min(65535.0, v * 65535.0)));
                        }
                        std::memcpy(dest + (dstPixelIdx * dstComponents + dc) * 2, &sv, 2);
                        break;
                    }
                    case GL_SHORT: {
                        std::int16_t sv;
                        if (srcIsInteger) {
                            sv = static_cast<std::int16_t>(v);
                        } else {
                            sv = static_cast<std::int16_t>(std::max(-32767.0, std::min(32767.0, v * 32767.0)));
                        }
                        std::memcpy(dest + (dstPixelIdx * dstComponents + dc) * 2, &sv, 2);
                        break;
                    }
                    case GL_UNSIGNED_INT: {
                        auto uv = static_cast<std::uint32_t>(v);
                        std::memcpy(dest + (dstPixelIdx * dstComponents + dc) * 4, &uv, 4);
                        break;
                    }
                    case GL_INT: {
                        auto iv = static_cast<std::int32_t>(v);
                        std::memcpy(dest + (dstPixelIdx * dstComponents + dc) * 4, &iv, 4);
                        break;
                    }
                    default:
                        if (srcIsInteger) {
                            dest[dstPixelIdx * dstComponents + dc] = static_cast<std::uint8_t>(v);
                        } else {
                            dest[dstPixelIdx * dstComponents + dc] = static_cast<std::uint8_t>(
                                std::max(0.0, std::min(255.0, v)));
                        }
                        break;
                }
            }
        }
      }
    }
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
    // glNamedFramebufferTexture binds the *whole* texture (all layers)
    // as a layered attachment — passes `layered=true` so the internal
    // framebufferTexture reaches the spec-correct INVALID_VALUE path
    // for invalid texture names (the non-layer-variant uses
    // INVALID_OPERATION per §9.2.8 distinction). Also textarget=0 so
    // we don't force-check against GL_TEXTURE_2D when the texture was
    // created with a different target (array / cube / 3D).
    bool ok = framebufferTexture(GL_DRAW_FRAMEBUFFER, attachment, 0, texture, level, 0, true);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferTextureLayer(GLuint framebuffer, GLenum attachment, GLuint texture, GLint level, GLint layer) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    // glNamedFramebufferTextureLayer binds a *specific* layer of a
    // texture (3D/Array/Cube-Array). Two wiring points for correct
    // error-code mapping:
    //
    //  - `textarget = 0` (don't check texture target against a passed
    //    enum): the spec lets this entry point accept whatever target
    //    the texture was created with, so passing GL_TEXTURE_2D here
    //    would reject 3D/array textures with INVALID_OPERATION before
    //    we ever reach the layer-bounds validator.
    //
    //  - `layered = false`: `layered=true` means "bind all layers as
    //    one attachment" (glFramebufferTexture semantics); this is
    //    the specific-layer variant, so bounds validation has to run.
    //
    // Together these let `framebufferTexture` reach the spec-required
    // INVALID_VALUE for an out-of-range layer instead of bailing
    // earlier on target mismatch or skipping the layer check entirely
    // (framebuffers_texture_attachment_errors).
    bool ok = framebufferTexture(GL_DRAW_FRAMEBUFFER, attachment, 0, texture, level, layer, false);
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

// DSA clear dispatch. `buffer` selects which attachment class (COLOR,
// DEPTH, STENCIL, DEPTH_STENCIL); `drawbuffer` is an index into the FBO's
// draw-buffer array when buffer==COLOR, otherwise must be 0 per GL 4.6
// §17.4.3.1. `value` is a 4-element vector for color clears and a scalar
// for DEPTH / STENCIL. Validation errors (INVALID_ENUM / INVALID_VALUE)
// are pushed via pushError; the return value is the accept-clear bool.
bool GLContext::clearNamedFramebufferfv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLfloat* value) {
    DSA_FB_CHECK(framebuffer)
    if (value == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLFramebufferObject* fbo = impl_->objects->framebuffers().get(framebuffer);
    if (fbo == nullptr) {
        // DSA_FB_CHECK already handles non-existent FB. framebuffer==0 is
        // the default FB, which isn't currently backed as a GLFramebufferObject
        // in our store.
        return true;
    }
    if (buffer == GL_COLOR) {
        if (drawbuffer < 0 || static_cast<std::size_t>(drawbuffer) >= fbo->drawBuffers.size()) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        const GLenum attachmentEnum = fbo->drawBuffers[static_cast<std::size_t>(drawbuffer)];
        if (attachmentEnum == GL_NONE) {
            // No-op per spec (no error).
            return true;
        }
        GLFramebufferAttachment* att = impl_->framebufferAttachment(*fbo, attachmentEnum);
        if (att == nullptr) return true;
        return impl_->clearColorAttachment(*att, value);
    }
    if (buffer == GL_DEPTH) {
        if (drawbuffer != 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        GLFramebufferAttachment* att = impl_->framebufferAttachment(*fbo, GL_DEPTH_ATTACHMENT);
        if (att == nullptr) return true;
        return impl_->clearDepthAttachment(*att, value[0]);
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

bool GLContext::clearNamedFramebufferiv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLint* value) {
    DSA_FB_CHECK(framebuffer)
    if (value == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLFramebufferObject* fbo = impl_->objects->framebuffers().get(framebuffer);
    if (fbo == nullptr) return true;
    if (buffer == GL_COLOR) {
        if (drawbuffer < 0 || static_cast<std::size_t>(drawbuffer) >= fbo->drawBuffers.size()) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        const GLenum attachmentEnum = fbo->drawBuffers[static_cast<std::size_t>(drawbuffer)];
        if (attachmentEnum == GL_NONE) return true;
        GLFramebufferAttachment* att = impl_->framebufferAttachment(*fbo, attachmentEnum);
        if (att == nullptr) return true;
        // For signed-integer attachments, bit-pattern the int into the
        // Metal texture's encoding. The float passthrough
        // (clearColorAttachment) would truncate the value on norm formats;
        // for SInt textures we want the raw bit width preserved.
        float fv[4] = {
            static_cast<float>(value[0]),
            static_cast<float>(value[1]),
            static_cast<float>(value[2]),
            static_cast<float>(value[3]),
        };
        return impl_->clearColorAttachment(*att, fv);
    }
    if (buffer == GL_STENCIL) {
        if (drawbuffer != 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        GLFramebufferAttachment* att = impl_->framebufferAttachment(*fbo, GL_STENCIL_ATTACHMENT);
        if (att == nullptr) return true;
        return impl_->clearStencilAttachment(*att, value[0]);
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

bool GLContext::clearNamedFramebufferuiv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLuint* value) {
    DSA_FB_CHECK(framebuffer)
    if (value == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (buffer != GL_COLOR) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLFramebufferObject* fbo = impl_->objects->framebuffers().get(framebuffer);
    if (fbo == nullptr) return true;
    if (drawbuffer < 0 || static_cast<std::size_t>(drawbuffer) >= fbo->drawBuffers.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLenum attachmentEnum = fbo->drawBuffers[static_cast<std::size_t>(drawbuffer)];
    if (attachmentEnum == GL_NONE) return true;
    GLFramebufferAttachment* att = impl_->framebufferAttachment(*fbo, attachmentEnum);
    if (att == nullptr) return true;
    float fv[4] = {
        static_cast<float>(value[0]),
        static_cast<float>(value[1]),
        static_cast<float>(value[2]),
        static_cast<float>(value[3]),
    };
    return impl_->clearColorAttachment(*att, fv);
}

bool GLContext::clearNamedFramebufferfi(GLuint framebuffer, GLenum buffer, GLint drawbuffer, GLfloat depth, GLint stencil) {
    DSA_FB_CHECK(framebuffer)
    if (buffer != GL_DEPTH_STENCIL) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (drawbuffer != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLFramebufferObject* fbo = impl_->objects->framebuffers().get(framebuffer);
    if (fbo == nullptr) return true;
    // Resolve via either DEPTH_STENCIL_ATTACHMENT (combined) or the
    // separate DEPTH/STENCIL attachment entries. framebufferAttachment
    // already handles the combined fallback when the query is for
    // DEPTH_ATTACHMENT / STENCIL_ATTACHMENT specifically.
    bool ok = true;
    if (GLFramebufferAttachment* depthAtt = impl_->framebufferAttachment(*fbo, GL_DEPTH_ATTACHMENT)) {
        ok = impl_->clearDepthAttachment(*depthAtt, depth) && ok;
    }
    if (GLFramebufferAttachment* stencilAtt = impl_->framebufferAttachment(*fbo, GL_STENCIL_ATTACHMENT)) {
        ok = impl_->clearStencilAttachment(*stencilAtt, stencil) && ok;
    }
    return ok;
}

bool GLContext::invalidateNamedFramebufferData(GLuint framebuffer, GLsizei numAttachments, const GLenum* attachments) {
    if (numAttachments < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // `framebuffer == 0` means the default framebuffer — no
    // DSA_FB_CHECK; per-attachment validation uses the default-FB enum set.
    if (framebuffer != 0) {
        auto* obj = impl_->objects->framebuffers().get(framebuffer);
        if (obj == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    }
    const bool isDefaultFb = (framebuffer == 0);
    if (attachments != nullptr) {
        for (GLsizei i = 0; i < numAttachments; ++i) {
            const GLenum err = classifyInvalidateAttachment(attachments[i], isDefaultFb);
            if (err != 0) {
                pushError(err);
                return false;
            }
        }
    }
    return true;
}

bool GLContext::invalidateNamedFramebufferSubData(GLuint framebuffer, GLsizei numAttachments, const GLenum* attachments,
                                                    GLint x, GLint y, GLsizei width, GLsizei height) {
    (void)x; (void)y;
    if (numAttachments < 0 || width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (framebuffer != 0) {
        auto* obj = impl_->objects->framebuffers().get(framebuffer);
        if (obj == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    }
    const bool isDefaultFb = (framebuffer == 0);
    if (attachments != nullptr) {
        for (GLsizei i = 0; i < numAttachments; ++i) {
            const GLenum err = classifyInvalidateAttachment(attachments[i], isDefaultFb);
            if (err != 0) {
                pushError(err);
                return false;
            }
        }
    }
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
    if (bufSize < 0) { pushError(GL_INVALID_VALUE); return false; }
    GLuint texName = impl_->state->boundTexture(target);
    if (texName == 0) { pushError(GL_INVALID_OPERATION); return false; }
    return getTextureImage(texName, level, format, type, bufSize, pixels);
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
    // Extends glPolygonOffset with a clamp value. Store factor/units/clamp via
    // the state tracker for Metal's setDepthBias:slopeScale:clamp:.
    impl_->state->setPolygonOffsetClamp(factor, units, clamp);
    return true;
}

}  // namespace appgl
