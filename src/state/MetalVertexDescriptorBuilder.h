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

// Mirrors `buildMetalVertexDescriptor` but produces an
// `MTLStageInputOutputDescriptor` (used for `kernel` functions with
// `[[stage_in]]` parameters — i.e. VS-as-compute when SPIRV-Cross
// emits `forceVertexForTessellation=true` MSL).
//
// MTLAttributeFormat / MTLAttributeDescriptor / MTLBufferLayoutDescriptor
// mirror the vertex versions (most enums share values, ABI-compatible
// where they overlap). The step function defaults to
// MTLStepFunctionThreadPositionInGridX so dispatch-thread index drives
// per-vertex attribute fetch.
//
// `vertexBufferBindings` returned in the result identifies which GL
// buffers must be bound to which Metal slot at compute encode time —
// reused by the encoder via the same flow as the graphics path.
MetalVertexDescriptorBuildResult buildMetalStageInputOutputDescriptor(const GLVertexArrayObject& vertexArray);
void releaseMetalStageInputOutputDescriptor(void* descriptor);

}  // namespace appgl
