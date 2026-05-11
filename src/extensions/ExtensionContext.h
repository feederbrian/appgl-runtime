#pragma once

#include <source_location>
#include <string_view>

#include "../../include/AppGL/glcorearb.h"

namespace appgl {

class GLCapabilities;
class GLContext;
class GLObjectStore;
class GLStateTracker;
struct GLTextureObject;

class ExtensionContext {
public:
    explicit ExtensionContext(GLContext& context);

    GLContext& context();
    const GLContext& context() const;

    void* metalDevice() const;
    void* metalCommandQueue() const;

    GLCapabilities& capabilities();
    const GLCapabilities& capabilities() const;
    GLObjectStore& objects();
    const GLObjectStore& objects() const;
    GLStateTracker& state();
    const GLStateTracker& state() const;

    void pushError(GLenum error,
                   std::string_view functionName = std::string_view{},
                   std::string_view message = std::string_view{},
                   std::source_location loc = std::source_location::current());

    GLTextureObject* currentTexture(GLenum target);
    bool replaceMetalTexture(GLTextureObject& texture, GLuint textureName = 0);

private:
    GLContext* context_ = nullptr;
};

}  // namespace appgl
