#include "IndexExpansion.h"

#include <cstring>

namespace appgl {

bool isSupportedElementIndexType(GLenum type) {
    return type == GL_UNSIGNED_BYTE || type == GL_UNSIGNED_SHORT || type == GL_UNSIGNED_INT;
}

bool elementIndexTypeNeedsExpansion(GLenum type) {
    return type == GL_UNSIGNED_BYTE;
}

std::size_t elementIndexTypeByteSize(GLenum type) {
    switch (type) {
        case GL_UNSIGNED_BYTE:
            return sizeof(GLubyte);
        case GL_UNSIGNED_SHORT:
            return sizeof(GLushort);
        case GL_UNSIGNED_INT:
            return sizeof(GLuint);
        default:
            return 0;
    }
}

IndexExpansionResult expandElementIndices(GLsizei count, GLenum type, const void* indices) {
    IndexExpansionResult result;
    result.sourceType = type;
    result.outputType = type;

    if (count < 0) {
        result.error = GL_INVALID_VALUE;
        result.message = "index count must be non-negative";
        return result;
    }

    if (!isSupportedElementIndexType(type)) {
        result.error = GL_INVALID_ENUM;
        result.message = "index type must be GL_UNSIGNED_BYTE, GL_UNSIGNED_SHORT, or GL_UNSIGNED_INT";
        return result;
    }

    if (count > 0 && indices == nullptr) {
        result.error = GL_INVALID_VALUE;
        result.message = "index data pointer is null";
        return result;
    }

    result.ok = true;
    if (count == 0) {
        return result;
    }

    if (elementIndexTypeNeedsExpansion(type)) {
        result.outputType = GL_UNSIGNED_SHORT;
        result.bytes.resize(static_cast<std::size_t>(count) * sizeof(GLushort));
        const auto* source = static_cast<const GLubyte*>(indices);
        auto* expanded = reinterpret_cast<GLushort*>(result.bytes.data());
        for (GLsizei index = 0; index < count; ++index) {
            expanded[index] = static_cast<GLushort>(source[index]);
        }
        return result;
    }

    const std::size_t bytesPerIndex = elementIndexTypeByteSize(type);
    result.bytes.resize(static_cast<std::size_t>(count) * bytesPerIndex);
    std::memcpy(result.bytes.data(), indices, result.bytes.size());
    return result;
}

}  // namespace appgl
