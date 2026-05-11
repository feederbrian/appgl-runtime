#include "ExtensionContext.h"

#include "../context/GLContext.h"

namespace appgl {

ExtensionContext::ExtensionContext(GLContext& context)
    : context_(&context) {}

GLContext& ExtensionContext::context() {
    return *context_;
}

const GLContext& ExtensionContext::context() const {
    return *context_;
}

void* ExtensionContext::metalDevice() const {
    return context_->extensionMetalDevice();
}

void* ExtensionContext::metalCommandQueue() const {
    return context_->extensionMetalCommandQueue();
}

GLCapabilities& ExtensionContext::capabilities() {
    return context_->capabilities();
}

const GLCapabilities& ExtensionContext::capabilities() const {
    return context_->capabilities();
}

GLObjectStore& ExtensionContext::objects() {
    return context_->objects();
}

const GLObjectStore& ExtensionContext::objects() const {
    return context_->objects();
}

GLStateTracker& ExtensionContext::state() {
    return context_->state();
}

const GLStateTracker& ExtensionContext::state() const {
    return context_->state();
}

void ExtensionContext::pushError(GLenum error,
                                 std::string_view functionName,
                                 std::string_view message,
                                 std::source_location loc) {
    context_->pushError(error, functionName, message, loc);
}

GLTextureObject* ExtensionContext::currentTexture(GLenum target) {
    return context_->extensionCurrentTexture(target);
}

bool ExtensionContext::replaceMetalTexture(GLTextureObject& texture, GLuint textureName) {
    return context_->extensionReplaceMetalTexture(texture, textureName);
}

}  // namespace appgl
