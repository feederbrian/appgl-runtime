#include "MetalVertexDescriptorBuilder.h"

#include "../objects/GLObjectStore.h"

#include <CoreFoundation/CoreFoundation.h>
#import <Metal/Metal.h>

#include <cstdint>
#include <sstream>
#include <string>

namespace appgl {
namespace {

constexpr std::uint64_t kFnvOffset = 14695981039346656037ull;
constexpr std::uint64_t kFnvPrime = 1099511628211ull;

void* retainDescriptor(MTLVertexDescriptor* descriptor) {
    if (descriptor == nil) {
        return nullptr;
    }
#if __has_feature(objc_arc)
    return (__bridge_retained void*)descriptor;
#else
    return [descriptor retain];
#endif
}

MTLVertexFormat vectorFormat(
    GLint size,
    MTLVertexFormat scalar,
    MTLVertexFormat vector2,
    MTLVertexFormat vector3,
    MTLVertexFormat vector4
) {
    switch (size) {
        case 1:
            return scalar;
        case 2:
            return vector2;
        case 3:
            return vector3;
        case 4:
            return vector4;
        default:
            return MTLVertexFormatInvalid;
    }
}

MTLVertexFormat metalVertexFormat(const GLVertexAttributeState& attribute) {
    switch (attribute.type) {
        case GL_FLOAT:
            return vectorFormat(
                attribute.size,
                MTLVertexFormatFloat,
                MTLVertexFormatFloat2,
                MTLVertexFormatFloat3,
                MTLVertexFormatFloat4
            );
        case GL_HALF_FLOAT:
            return vectorFormat(
                attribute.size,
                MTLVertexFormatHalf,
                MTLVertexFormatHalf2,
                MTLVertexFormatHalf3,
                MTLVertexFormatHalf4
            );
        case GL_BYTE:
            if (attribute.normalized == GL_TRUE && !attribute.integer) {
                return vectorFormat(
                    attribute.size,
                    MTLVertexFormatCharNormalized,
                    MTLVertexFormatChar2Normalized,
                    MTLVertexFormatChar3Normalized,
                    MTLVertexFormatChar4Normalized
                );
            }
            return vectorFormat(
                attribute.size,
                MTLVertexFormatChar,
                MTLVertexFormatChar2,
                MTLVertexFormatChar3,
                MTLVertexFormatChar4
            );
        case GL_UNSIGNED_BYTE:
            if (attribute.normalized == GL_TRUE && !attribute.integer) {
                return vectorFormat(
                    attribute.size,
                    MTLVertexFormatUCharNormalized,
                    MTLVertexFormatUChar2Normalized,
                    MTLVertexFormatUChar3Normalized,
                    MTLVertexFormatUChar4Normalized
                );
            }
            return vectorFormat(
                attribute.size,
                MTLVertexFormatUChar,
                MTLVertexFormatUChar2,
                MTLVertexFormatUChar3,
                MTLVertexFormatUChar4
            );
        case GL_SHORT:
            if (attribute.normalized == GL_TRUE && !attribute.integer) {
                return vectorFormat(
                    attribute.size,
                    MTLVertexFormatShortNormalized,
                    MTLVertexFormatShort2Normalized,
                    MTLVertexFormatShort3Normalized,
                    MTLVertexFormatShort4Normalized
                );
            }
            return vectorFormat(
                attribute.size,
                MTLVertexFormatShort,
                MTLVertexFormatShort2,
                MTLVertexFormatShort3,
                MTLVertexFormatShort4
            );
        case GL_UNSIGNED_SHORT:
            if (attribute.normalized == GL_TRUE && !attribute.integer) {
                return vectorFormat(
                    attribute.size,
                    MTLVertexFormatUShortNormalized,
                    MTLVertexFormatUShort2Normalized,
                    MTLVertexFormatUShort3Normalized,
                    MTLVertexFormatUShort4Normalized
                );
            }
            return vectorFormat(
                attribute.size,
                MTLVertexFormatUShort,
                MTLVertexFormatUShort2,
                MTLVertexFormatUShort3,
                MTLVertexFormatUShort4
            );
        case GL_INT:
            return vectorFormat(
                attribute.size,
                MTLVertexFormatInt,
                MTLVertexFormatInt2,
                MTLVertexFormatInt3,
                MTLVertexFormatInt4
            );
        case GL_UNSIGNED_INT:
            return vectorFormat(
                attribute.size,
                MTLVertexFormatUInt,
                MTLVertexFormatUInt2,
                MTLVertexFormatUInt3,
                MTLVertexFormatUInt4
            );
        case GL_INT_2_10_10_10_REV:
            return attribute.size == 4 && attribute.normalized == GL_TRUE && !attribute.integer
                ? MTLVertexFormatInt1010102Normalized
                : MTLVertexFormatInvalid;
        case GL_UNSIGNED_INT_2_10_10_10_REV:
            return attribute.size == 4 && attribute.normalized == GL_TRUE && !attribute.integer
                ? MTLVertexFormatUInt1010102Normalized
                : MTLVertexFormatInvalid;
        default:
            return MTLVertexFormatInvalid;
    }
}

std::size_t componentByteSize(GLenum type) {
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
            return 4;
        case GL_DOUBLE:
            return 8;
        default:
            return 0;
    }
}

std::size_t attributeByteSize(const GLVertexAttributeState& attribute) {
    if (attribute.type == GL_INT_2_10_10_10_REV || attribute.type == GL_UNSIGNED_INT_2_10_10_10_REV) {
        return 4;
    }
    return componentByteSize(attribute.type) * static_cast<std::size_t>(attribute.size);
}

void hashValue(std::uint64_t& hash, std::uint64_t value) {
    for (std::size_t byteIndex = 0; byteIndex < sizeof(value); ++byteIndex) {
        hash ^= (value >> (byteIndex * 8u)) & 0xffu;
        hash *= kFnvPrime;
    }
}

std::string formatHash(std::uint64_t hash) {
    std::ostringstream stream;
    stream << std::hex << hash;
    return stream.str();
}

}  // namespace

MetalVertexDescriptorBuildResult buildMetalVertexDescriptor(const GLVertexArrayObject& vertexArray) {
    MetalVertexDescriptorBuildResult result;
    MTLVertexDescriptor* descriptor = [MTLVertexDescriptor vertexDescriptor];
    if (descriptor == nil) {
        result.error = "MTLVertexDescriptor allocation failed.";
        return result;
    }

    std::uint64_t hash = kFnvOffset;
    for (std::size_t index = 0; index < vertexArray.attributes.size(); ++index) {
        const auto& attribute = vertexArray.attributes[index];
        if (!attribute.enabled) {
            continue;
        }

        const MTLVertexFormat format = metalVertexFormat(attribute);
        if (format == MTLVertexFormatInvalid) {
            result.error = "Unsupported vertex attribute format at index " + std::to_string(index) + ".";
            return result;
        }

        const std::size_t stride = attribute.stride > 0 ? static_cast<std::size_t>(attribute.stride) : attributeByteSize(attribute);
        descriptor.attributes[index].format = format;
        descriptor.attributes[index].offset = static_cast<NSUInteger>(attribute.pointer);
        descriptor.attributes[index].bufferIndex = static_cast<NSUInteger>(index);
        descriptor.layouts[index].stride = static_cast<NSUInteger>(stride);
        descriptor.layouts[index].stepFunction = attribute.divisor == 0 ? MTLVertexStepFunctionPerVertex : MTLVertexStepFunctionPerInstance;
        descriptor.layouts[index].stepRate = attribute.divisor == 0 ? 1 : static_cast<NSUInteger>(attribute.divisor);

        hashValue(hash, static_cast<std::uint64_t>(index));
        hashValue(hash, static_cast<std::uint64_t>(format));
        hashValue(hash, static_cast<std::uint64_t>(attribute.pointer));
        hashValue(hash, static_cast<std::uint64_t>(stride));
        hashValue(hash, static_cast<std::uint64_t>(attribute.divisor));
        hashValue(hash, attribute.integer ? 1u : 0u);
    }

    result.hash = formatHash(hash);
    result.descriptor = retainDescriptor(descriptor);
    return result;
}

void releaseMetalVertexDescriptor(void* descriptor) {
    if (descriptor == nullptr) {
        return;
    }
#if __has_feature(objc_arc)
    CFRelease(descriptor);
#else
    [(id)descriptor release];
#endif
}

}  // namespace appgl
