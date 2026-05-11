#pragma once

#include <cstddef>
#include <string>
#include <string_view>

#include "../glcorearb.h"

namespace appgl {

class ExtensionContext;
struct GLTextureObject;

namespace extensions {

struct SparseTextureHooks {
    bool (*handleTextureParameter)(ExtensionContext& ctx,
                                   GLenum target,
                                   GLenum pname,
                                   const GLint* params,
                                   bool& handled) = nullptr;
    bool (*handleTextureStorage)(ExtensionContext& ctx,
                                 GLenum target,
                                 GLsizei levels,
                                 GLenum internalformat,
                                 GLsizei width,
                                 GLsizei height,
                                 GLsizei depth,
                                 bool& handled) = nullptr;
    bool (*handleTextureUpload)(ExtensionContext& ctx,
                                GLTextureObject& texture,
                                GLuint textureName,
                                bool& handled) = nullptr;
    bool (*handleTextureReadback)(ExtensionContext& ctx,
                                  GLTextureObject& texture,
                                  bool& handled) = nullptr;
    bool (*handleInternalFormatQuery)(ExtensionContext& ctx,
                                      GLenum target,
                                      GLenum internalformat,
                                      GLenum pname,
                                      GLsizei count,
                                      GLint* params,
                                      bool& handled) = nullptr;
};

struct FragmentShadingRateHooks {
    GLenum (*currentDrawRate)(ExtensionContext& ctx) = nullptr;
    void (*attachRenderPass)(ExtensionContext& ctx,
                             void* renderPassDescriptor,
                             GLenum rate,
                             void* colorTexture,
                             std::size_t renderTargetLayerCount) = nullptr;
};

struct ExtensionModuleDescriptor {
    const char* moduleName = nullptr;
    const char* (*extensionString)() = nullptr;
    bool (*isAvailable)(ExtensionContext& ctx) = nullptr;
    void (*initialize)(ExtensionContext& ctx) = nullptr;
    void (*shutdown)() = nullptr;
    SparseTextureHooks sparseTextureHooks;
    FragmentShadingRateHooks fragmentShadingRateHooks;
};

class ExtensionRegistry {
public:
    static void registerModule(const ExtensionModuleDescriptor& descriptor);
    static void initializeAll(ExtensionContext& ctx);
    static void shutdownAll();

    static std::size_t extensionCount();
    static const char* extensionAt(std::size_t index);
    static const std::string& extensionString();
    static bool isExtensionActive(std::string_view extensionName);

    static const SparseTextureHooks& sparseTextureHooks();
    static const FragmentShadingRateHooks& fragmentShadingRateHooks();
};

}  // namespace extensions
}  // namespace appgl
