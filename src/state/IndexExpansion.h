#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "../../include/AppGL/glcorearb.h"

namespace appgl {

struct IndexExpansionResult {
    bool ok = false;
    GLenum error = GL_NO_ERROR;
    GLenum sourceType = 0;
    GLenum outputType = 0;
    std::vector<std::uint8_t> bytes;
    std::string message;
};

bool isSupportedElementIndexType(GLenum type);
bool elementIndexTypeNeedsExpansion(GLenum type);
std::size_t elementIndexTypeByteSize(GLenum type);
IndexExpansionResult expandElementIndices(GLsizei count, GLenum type, const void* indices);

}  // namespace appgl
