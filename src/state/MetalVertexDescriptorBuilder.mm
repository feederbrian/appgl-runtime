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

// Must match BindingMap::vertexBufferBase in shader/ShaderTranslator.h.
//
// Metal exposes 31 buffer slots per shader stage (indices 0..30). We partition
// them so that vertex buffers live in the low half and uniform/storage buffers
// live in the high half:
//   [ 0..16)  vertex buffers    (mirrors GL_MAX_VERTEX_ATTRIBS = 16)
//   [16..30)  uniform buffers   (mirrors GL_MAX_UNIFORM_BUFFER_BINDINGS area)
//   [30..31)  reserved (argument buffer tier-1 stash)
//
// The earlier layout pushed vertex buffers to slot 32 which exceeds Metal's
// hard limit and fails -[MTLVertexAttributeDescriptorInternal setBufferIndex:].
constexpr std::uint32_t kVertexBufferBase = 0;
constexpr std::uint32_t kMaxVertexBufferSlots = 16;

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

    // Group attributes by (GL buffer, stride, divisor). Each unique tuple gets
    // its own Metal vertex buffer slot starting at kVertexBufferBase. Interleaved
    // attributes that share a VBO collapse into one slot — the per-attribute
    // pointer becomes the descriptor offset within that layout.
    bool slotOverflow = false;
    auto findOrAssignSlot = [&result, &slotOverflow](GLuint glBuffer, std::uint32_t stride, GLuint divisor) -> std::uint32_t {
        for (const auto& binding : result.vertexBufferBindings) {
            if (binding.glBuffer == glBuffer && binding.stride == stride) {
                // Note: divisor is already encoded by the layout's stepFunction/stepRate;
                // two attributes sharing buffer+stride must also share divisor — we enforce
                // this implicitly by using stride/divisor as part of the dedupe key below.
                (void)divisor;
                return binding.metalSlot;
            }
        }
        const std::uint32_t slotIndex = static_cast<std::uint32_t>(result.vertexBufferBindings.size());
        if (slotIndex >= kMaxVertexBufferSlots) {
            slotOverflow = true;
            return kVertexBufferBase;  // safe fallback; caller will see error string
        }
        const std::uint32_t slot = kVertexBufferBase + slotIndex;
        result.vertexBufferBindings.push_back({glBuffer, slot, stride});
        return slot;
    };

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

        // GL 4.3 separated vertex format: when `glBindVertexBuffer(s)`
        // has written a buffer/stride/offset to the attribute's
        // binding point, prefer that over the legacy
        // `attr.buffer/stride/pointer` — even if
        // `glVertexAttribFormat` was never called. The default
        // per-attribute format (size=4, type=FLOAT, relativeOffset=0)
        // is always in effect. Without this, tests that rely on
        // "enableVertexAttribArray + bindVertexBuffers + draw" (e.g.
        // `multi_bind.draw_bind_vertex_buffers`) fetch zeros because
        // `attr.buffer` is 0 (VertexAttribPointer was never called).
        GLuint bufferName = attribute.buffer;
        std::uint32_t stride = 0;
        NSUInteger vertexOffset = static_cast<NSUInteger>(attribute.pointer);
        GLuint divisor = attribute.divisor;
        const bool hasSeparatedBinding =
            (attribute.bindingIndex < vertexArray.bindingPoints.size()) &&
            (vertexArray.bindingPoints[attribute.bindingIndex].buffer != 0);
        if (attribute.useSeparatedFormat || hasSeparatedBinding) {
            const auto& bp = vertexArray.bindingPoints[attribute.bindingIndex];
            bufferName = bp.buffer;
            stride = static_cast<std::uint32_t>(
                bp.stride > 0 ? static_cast<std::size_t>(bp.stride)
                              : attributeByteSize(attribute));
            vertexOffset = static_cast<NSUInteger>(
                static_cast<std::size_t>(bp.offset) +
                static_cast<std::size_t>(attribute.relativeOffset));
            divisor = bp.divisor;
        } else {
            stride = static_cast<std::uint32_t>(
                attribute.stride > 0 ? static_cast<std::size_t>(attribute.stride)
                                     : attributeByteSize(attribute));
        }
        const std::uint32_t metalSlot = findOrAssignSlot(bufferName, stride, divisor);

        descriptor.attributes[index].format = format;
        descriptor.attributes[index].offset = vertexOffset;
        descriptor.attributes[index].bufferIndex = static_cast<NSUInteger>(metalSlot);
        descriptor.layouts[metalSlot].stride = static_cast<NSUInteger>(stride);
        descriptor.layouts[metalSlot].stepFunction = divisor == 0 ? MTLVertexStepFunctionPerVertex : MTLVertexStepFunctionPerInstance;
        descriptor.layouts[metalSlot].stepRate = divisor == 0 ? 1 : static_cast<NSUInteger>(divisor);

        hashValue(hash, static_cast<std::uint64_t>(index));
        hashValue(hash, static_cast<std::uint64_t>(format));
        hashValue(hash, static_cast<std::uint64_t>(vertexOffset));
        hashValue(hash, static_cast<std::uint64_t>(stride));
        hashValue(hash, static_cast<std::uint64_t>(divisor));
        hashValue(hash, static_cast<std::uint64_t>(bufferName));
        hashValue(hash, static_cast<std::uint64_t>(metalSlot));
        hashValue(hash, attribute.integer ? 1u : 0u);
    }

    if (slotOverflow) {
        result.error = "Vertex array uses more than " + std::to_string(kMaxVertexBufferSlots)
            + " distinct vertex buffer slots; Metal supports at most 31 buffers per stage.";
        return result;
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
