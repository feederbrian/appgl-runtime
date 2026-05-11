#pragma once

#include <cstdint>

#include "../../../include/AppGL/glcorearb.h"

namespace appgl {
class ExtensionContext;
struct GLTextureObject;
}

namespace appgl::extensions::sparse_texture {

struct SparseStorageImageSidecarInfo {
    void* metalTexture = nullptr;
    GLenum target = 0;
    GLenum internalFormat = 0;
    std::uint64_t metalPixelFormat = 0;
    std::uint64_t metalTextureType = 0;
    GLsizei width = 0;
    GLsizei height = 0;
    GLsizei depth = 0;
    GLsizei layers = 0;
    GLsizei levels = 0;
    GLsizei arrayLength = 0;
};

enum class SparseStorageImageWriteBindingRoute {
    NativeTexture,
    SidecarTexture,
    SparseSidecarUnavailable,
};

bool isSparseStorageImageSidecarTarget(GLenum target);
bool supportsSparseStorageImageSidecar(ExtensionContext& ctx, GLenum target);

bool ensureSparseStorageImageSidecar(ExtensionContext& ctx,
                                     GLTextureObject& texture,
                                     SparseStorageImageSidecarInfo* outInfo = nullptr);
SparseStorageImageWriteBindingRoute resolveSparseStorageImageWriteBinding(
    ExtensionContext& ctx,
    GLTextureObject& texture,
    GLenum shaderImageTarget,
    SparseStorageImageSidecarInfo* outInfo = nullptr);
bool getSparseStorageImageSidecar(ExtensionContext& ctx,
                                  const GLTextureObject& texture,
                                  SparseStorageImageSidecarInfo& outInfo);

void resetSparseStorageImageSidecar(ExtensionContext& ctx,
                                    GLTextureObject& texture);
void destroySparseStorageImageSidecar(ExtensionContext& ctx,
                                      GLTextureObject& texture);
void destroySparseStorageImageSidecars(ExtensionContext& ctx);

}  // namespace appgl::extensions::sparse_texture
