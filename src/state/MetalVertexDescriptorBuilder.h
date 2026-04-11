#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "../../include/AppGL/glcorearb.h"

namespace appgl {

struct GLVertexArrayObject;

// Metal vertex buffer slot assignment for one (GL buffer, stride) pair.
// At draw time, the named GL buffer must be bound at offset 0 to `metalSlot`.
struct GLVertexBufferBinding {
    GLuint glBuffer = 0;
    std::uint32_t metalSlot = 0;
    std::uint32_t stride = 0;
};

struct MetalVertexDescriptorBuildResult {
    void* descriptor = nullptr;
    std::string hash;
    std::string error;
    std::vector<GLVertexBufferBinding> vertexBufferBindings;
};

MetalVertexDescriptorBuildResult buildMetalVertexDescriptor(const GLVertexArrayObject& vertexArray);
void releaseMetalVertexDescriptor(void* descriptor);

}  // namespace appgl
