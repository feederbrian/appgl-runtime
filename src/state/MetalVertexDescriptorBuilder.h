#pragma once

#include <string>

namespace appgl {

struct GLVertexArrayObject;

struct MetalVertexDescriptorBuildResult {
    void* descriptor = nullptr;
    std::string hash;
    std::string error;
};

MetalVertexDescriptorBuildResult buildMetalVertexDescriptor(const GLVertexArrayObject& vertexArray);
void releaseMetalVertexDescriptor(void* descriptor);

}  // namespace appgl
