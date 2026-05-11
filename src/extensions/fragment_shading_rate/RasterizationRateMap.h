#pragma once

#include <cstddef>

#include "../../../include/AppGL/glcorearb.h"

namespace appgl {
class ExtensionContext;
}

namespace appgl::extensions::fragment_shading_rate {

bool isRasterizationRateMapAvailable(ExtensionContext& ctx);
void attachRenderPass(ExtensionContext& ctx,
                      void* renderPassDescriptor,
                      GLenum rate,
                      void* colorTexture,
                      std::size_t renderTargetLayerCount);
void clearRasterizationRateMapCache(ExtensionContext& ctx);

}  // namespace appgl::extensions::fragment_shading_rate
