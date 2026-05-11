#pragma once

#include <cstdint>

#include "../../../include/AppGL/glcorearb.h"

namespace appgl {
class ExtensionContext;
struct GLTextureObject;
}

namespace appgl::extensions::sparse_texture {

struct MultisampleStorageImageSidecarInfo {
    void* metalTexture = nullptr;
    GLenum target = 0;
    GLenum internalFormat = 0;
    std::uint64_t metalPixelFormat = 0;
    GLsizei width = 0;
    GLsizei height = 0;
    GLsizei layers = 0;
    GLsizei samples = 0;
    GLsizei arrayLength = 0;
};

bool isMultisampleStorageImageTarget(GLenum target);
std::uint32_t multisampleStorageImageSidecarSlice(GLint layer,
                                                  GLint sample,
                                                  GLsizei samples);

bool supportsMultisampleStorageImageSidecar(ExtensionContext& ctx);

bool ensureMultisampleStorageImageSidecar(ExtensionContext& ctx,
                                          GLTextureObject& texture,
                                          MultisampleStorageImageSidecarInfo* outInfo = nullptr);
bool getMultisampleStorageImageSidecar(ExtensionContext& ctx,
                                       const GLTextureObject& texture,
                                       MultisampleStorageImageSidecarInfo& outInfo);

void resetMultisampleStorageImageSidecar(ExtensionContext& ctx,
                                         GLTextureObject& texture);
void destroyMultisampleStorageImageSidecar(ExtensionContext& ctx,
                                           GLTextureObject& texture);
void destroyMultisampleStorageImageSidecars(ExtensionContext& ctx);

}  // namespace appgl::extensions::sparse_texture
