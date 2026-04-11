#include "GLContext.h"
#include "MetalFrameGraph.h"
#include "../caps/GLCapabilities.h"
#include "../objects/GLObjectStore.h"
#include "../state/GLStateTracker.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace appgl {
namespace {

constexpr std::size_t kMaxDebugMessages = 64;
constexpr std::size_t kMaxDebugMessageLength = 1024;
constexpr std::size_t kMaxDebugGroupDepth = 64;

struct DebugMessageRecord {
    GLenum source = GL_DEBUG_SOURCE_APPLICATION;
    GLenum type = GL_DEBUG_TYPE_OTHER;
    GLuint id = 0;
    GLenum severity = GL_DEBUG_SEVERITY_NOTIFICATION;
    std::string message;
};

struct DebugControlRule {
    GLenum source = GL_DONT_CARE;
    GLenum type = GL_DONT_CARE;
    GLenum severity = GL_DONT_CARE;
    std::unordered_set<GLuint> ids;
    bool hasIds = false;
    bool enabled = true;
};

std::uint64_t objectLabelKey(GLenum identifier, GLuint name) {
    return (static_cast<std::uint64_t>(identifier) << 32u) | static_cast<std::uint64_t>(name);
}

bool matchesDebugField(GLenum rule, GLenum value) {
    return rule == GL_DONT_CARE || rule == value;
}

bool debugRuleMatches(const DebugControlRule& rule, const DebugMessageRecord& message) {
    if (!matchesDebugField(rule.source, message.source)
        || !matchesDebugField(rule.type, message.type)
        || !matchesDebugField(rule.severity, message.severity)) {
        return false;
    }
    return !rule.hasIds || rule.ids.contains(message.id);
}

std::string trimDebugMessage(std::string_view message) {
    const std::size_t maxPayload = kMaxDebugMessageLength > 0 ? kMaxDebugMessageLength - 1 : 0;
    const std::size_t count = std::min(message.size(), maxPayload);
    return std::string(message.substr(0, count));
}

void copyLabelString(std::string_view value, GLsizei bufSize, GLsizei* length, GLchar* label) {
    if (length != nullptr) {
        *length = static_cast<GLsizei>(value.size());
    }
    if (label == nullptr || bufSize <= 0) {
        return;
    }

    const std::size_t writable = static_cast<std::size_t>(bufSize - 1);
    const std::size_t copied = std::min(value.size(), writable);
    if (copied > 0) {
        std::memcpy(label, value.data(), copied);
    }
    label[copied] = '\0';
}

}  // namespace

struct GLContext::Impl {
    Impl(void* rawLayer, GLsizei initialWidth, GLsizei initialHeight, bool offscreen) {
        layer = (__bridge CAMetalLayer*)rawLayer;
        device = MTLCreateSystemDefaultDevice();
        if (layer != nil && device != nil) {
            layer.device = device;
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.framebufferOnly = NO;
            layer.contentsGravity = kCAGravityResizeAspect;
            const CGSize bounds = layer.bounds.size;
            viewportWidth = initialWidth > 0 ? initialWidth : static_cast<GLsizei>(bounds.width > 0.0 ? bounds.width : 1.0);
            viewportHeight = initialHeight > 0 ? initialHeight : static_cast<GLsizei>(bounds.height > 0.0 ? bounds.height : 1.0);
            layer.drawableSize = CGSizeMake(viewportWidth, viewportHeight);
        } else {
            viewportWidth = initialWidth > 0 ? initialWidth : viewportWidth;
            viewportHeight = initialHeight > 0 ? initialHeight : viewportHeight;
        }
        if (device != nil) {
            commandQueue = [device newCommandQueue];
            rendererString = "AppGL on Metal (" + std::string([[device name] UTF8String]) + ")";
        } else {
            rendererString = "AppGL on Metal (No Metal Device)";
        }
        frameGraph = std::make_unique<MetalFrameGraph>((__bridge void*)layer, (__bridge void*)device, (__bridge void*)commandQueue);
        capabilities = std::make_unique<GLCapabilities>((__bridge void*)device);
        objects = std::make_unique<GLObjectStore>();
        state = std::make_unique<GLStateTracker>();
        if (frameGraph != nullptr) {
            frameGraph->resizeDrawable(viewportWidth, viewportHeight);
            if (offscreen) {
                frameGraph->enableOffscreenDrawable(viewportWidth, viewportHeight);
            }
        }
        state->setViewport(viewportX, viewportY, viewportWidth, viewportHeight);
        extensionsString = capabilities != nullptr ? capabilities->extensionString() : "";
    }

    void encodePendingWork() {
        if (!pendingClear || frameGraph == nullptr) {
            return;
        }

        frameGraph->resizeDrawable(viewportWidth, viewportHeight);
        frameGraph->encodeDefaultFramebufferClear(
            pendingMask,
            state->clearState().color[0],
            state->clearState().color[1],
            state->clearState().color[2],
            state->clearState().color[3],
            state->clearState().depth,
            state->clearState().stencil
        );
        pendingClear = false;
    }

    void presentPendingWork() {
        encodePendingWork();
        if (frameGraph != nullptr) {
            frameGraph->present();
        }
    }

    bool debugMessageEnabled(const DebugMessageRecord& message) const {
        for (auto cursor = debugControlRules.rbegin(); cursor != debugControlRules.rend(); ++cursor) {
            if (debugRuleMatches(*cursor, message)) {
                return cursor->enabled;
            }
        }
        return true;
    }

    void enqueueDebugMessage(DebugMessageRecord message) {
        if (!debugMessageEnabled(message)) {
            return;
        }
        message.message = trimDebugMessage(message.message);
        debugMessages.push_back(message);
        while (debugMessages.size() > kMaxDebugMessages) {
            debugMessages.pop_front();
        }

        if (debugCallback != nullptr) {
            debugCallback(
                message.source,
                message.type,
                message.id,
                message.severity,
                static_cast<GLsizei>(message.message.size()),
                message.message.c_str(),
                debugUserParam
            );
        }
    }

    CAMetalLayer* layer = nil;
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> commandQueue = nil;
    std::unique_ptr<MetalFrameGraph> frameGraph;
    std::unique_ptr<GLCapabilities> capabilities;
    std::unique_ptr<GLObjectStore> objects;
    std::unique_ptr<GLStateTracker> state;
    GLbitfield pendingMask = GL_COLOR_BUFFER_BIT;
    bool pendingClear = true;
    GLint viewportX = 0;
    GLint viewportY = 0;
    GLsizei viewportWidth = 1280;
    GLsizei viewportHeight = 720;
    GLDEBUGPROC debugCallback = nullptr;
    const void* debugUserParam = nullptr;
    std::deque<DebugMessageRecord> debugMessages;
    std::vector<DebugControlRule> debugControlRules;
    std::vector<DebugMessageRecord> debugGroupStack;
    std::unordered_map<std::uint64_t, std::string> objectLabels;
    std::unordered_map<const void*, std::string> pointerLabels;
    std::deque<GLenum> errors;
    std::string vendorString = "AppGL";
    std::string rendererString = "AppGL on Metal";
    std::string versionString;
    std::string shadingLanguageVersion = "3.30 AppGL bootstrap";
    std::string extensionsString;
};

GLContext::GLContext(void* layer)
    : impl_(std::make_unique<Impl>(layer, 1280, 720, false)) {
}

GLContext::GLContext(GLsizei offscreenWidth, GLsizei offscreenHeight)
    : impl_(std::make_unique<Impl>(nullptr, offscreenWidth, offscreenHeight, true)) {
}

GLContext::~GLContext() = default;

void GLContext::setClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    impl_->state->setClearColor(red, green, blue, alpha);
}

void GLContext::setClearDepth(GLdouble depth) {
    impl_->state->setClearDepth(depth);
}

void GLContext::setClearStencil(GLint stencil) {
    impl_->state->setClearStencil(stencil);
}

void GLContext::clear(GLbitfield mask) {
    impl_->pendingMask = mask;
    impl_->pendingClear = (mask & (GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT)) != 0;
}

void GLContext::setViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    impl_->viewportX = x;
    impl_->viewportY = y;
    impl_->viewportWidth = width > 0 ? width : 1;
    impl_->viewportHeight = height > 0 ? height : 1;
    impl_->state->setViewport(x, y, width, height);
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->resizeDrawable(impl_->viewportWidth, impl_->viewportHeight);
    }
}

void GLContext::setScissor(GLint x, GLint y, GLsizei width, GLsizei height) {
    impl_->state->setScissor(x, y, width, height);
}

void GLContext::setDepthRange(GLdouble nearValue, GLdouble farValue) {
    impl_->state->setDepthRange(nearValue, farValue);
}

void GLContext::setBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha) {
    impl_->state->setBlendFuncSeparate(srcRGB, dstRGB, srcAlpha, dstAlpha);
}

void GLContext::setBlendEquationSeparate(GLenum equationRGB, GLenum equationAlpha) {
    impl_->state->setBlendEquationSeparate(equationRGB, equationAlpha);
}

void GLContext::setBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    impl_->state->setBlendColor(red, green, blue, alpha);
}

void GLContext::setColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha) {
    impl_->state->setColorMask(red, green, blue, alpha);
}

void GLContext::setColorMaski(GLuint index, GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha) {
    impl_->state->setColorMaski(index, red, green, blue, alpha);
}

void GLContext::setDepthFunc(GLenum func) {
    impl_->state->setDepthFunc(func);
}

void GLContext::setDepthMask(GLboolean flag) {
    impl_->state->setDepthMask(flag);
}

void GLContext::setStencilFuncSeparate(GLenum face, GLenum func, GLint ref, GLuint mask) {
    impl_->state->setStencilFuncSeparate(face, func, ref, mask);
}

void GLContext::setStencilOpSeparate(GLenum face, GLenum fail, GLenum depthFail, GLenum depthPass) {
    impl_->state->setStencilOpSeparate(face, fail, depthFail, depthPass);
}

void GLContext::setStencilMaskSeparate(GLenum face, GLuint mask) {
    impl_->state->setStencilMaskSeparate(face, mask);
}

void GLContext::setCullFace(GLenum mode) {
    impl_->state->setCullFace(mode);
}

void GLContext::setFrontFace(GLenum mode) {
    impl_->state->setFrontFace(mode);
}

void GLContext::setPolygonOffset(GLfloat factor, GLfloat units) {
    impl_->state->setPolygonOffset(factor, units);
}

void GLContext::setLineWidth(GLfloat width) {
    impl_->state->setLineWidth(width);
}

void GLContext::setPointSize(GLfloat size) {
    impl_->state->setPointSize(size);
}

void GLContext::setHint(GLenum target, GLenum mode) {
    impl_->state->setHint(target, mode);
}

void GLContext::flush() {
    impl_->presentPendingWork();
}

void GLContext::swapBuffers() {
    impl_->presentPendingWork();
}

void GLContext::readPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels) {
    if (pixels == nullptr) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    if (width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    if (format != GL_RGBA || type != GL_UNSIGNED_BYTE) {
        pushError(GL_INVALID_ENUM);
        return;
    }
    impl_->encodePendingWork();
    if (impl_->frameGraph == nullptr || !impl_->frameGraph->copyRGBA8Pixels(x, y, width, height, pixels)) {
        pushError(GL_INVALID_OPERATION);
    }
}

bool GLContext::queryBoolean(GLenum pname, GLboolean* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH || pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = integerValue != 0 ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (impl_->state->queryBoolean(pname, data)) {
        return true;
    }
    GLint integerData[4] = {};
    if (impl_->capabilities != nullptr && impl_->capabilities->queryInteger(pname, integerData)) {
        data[0] = integerData[0] != 0 ? GL_TRUE : GL_FALSE;
        if (pname == GL_MAX_VIEWPORT_DIMS) {
            data[1] = integerData[1] != 0 ? GL_TRUE : GL_FALSE;
        }
        return true;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

bool GLContext::queryInteger(GLenum pname, GLint* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH) {
        *data = static_cast<GLint>(impl_->debugGroupStack.size());
        return true;
    }
    if (pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        *data = impl_->debugMessages.empty()
            ? 0
            : static_cast<GLint>(impl_->debugMessages.front().message.size() + 1);
        return true;
    }
    if (impl_->state->queryInteger(pname, data)) {
        return true;
    }
    if (impl_->capabilities == nullptr || !impl_->capabilities->queryInteger(pname, data)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::queryInteger64(GLenum pname, GLint64* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH || pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = static_cast<GLint64>(integerValue);
        return true;
    }
    if (impl_->state->queryInteger64(pname, data)) {
        return true;
    }
    if (impl_->capabilities == nullptr || !impl_->capabilities->queryInteger64(pname, data)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::queryFloat(GLenum pname, GLfloat* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH || pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = static_cast<GLfloat>(integerValue);
        return true;
    }
    if (impl_->state->queryFloat(pname, data)) {
        return true;
    }
    if (impl_->capabilities == nullptr || !impl_->capabilities->queryFloat(pname, data)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::queryDouble(GLenum pname, GLdouble* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH || pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = static_cast<GLdouble>(integerValue);
        return true;
    }
    if (impl_->state->queryDouble(pname, data)) {
        return true;
    }
    GLfloat floatData[4] = {};
    if (impl_->capabilities != nullptr && impl_->capabilities->queryFloat(pname, floatData)) {
        data[0] = static_cast<GLdouble>(floatData[0]);
        if (pname == GL_MAX_VIEWPORT_DIMS) {
            data[1] = static_cast<GLdouble>(floatData[1]);
        }
        return true;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

void GLContext::setEnabled(GLenum cap, bool enabled) {
    if (enabled) {
        impl_->state->enable(cap);
    } else {
        impl_->state->disable(cap);
    }
}

bool GLContext::isEnabled(GLenum cap) const {
    return impl_->state->isEnabled(cap);
}

void GLContext::setDebugCallback(GLDEBUGPROC callback, const void* userParam) {
    impl_->debugCallback = callback;
    impl_->debugUserParam = userParam;
}

void GLContext::emitDebugMessage(
    GLenum source,
    GLenum type,
    GLuint id,
    GLenum severity,
    std::string_view message
) {
    impl_->enqueueDebugMessage({source, type, id, severity, std::string(message)});
}

void GLContext::setDebugMessageControl(
    GLenum source,
    GLenum type,
    GLenum severity,
    GLsizei count,
    const GLuint* ids,
    GLboolean enabled
) {
    DebugControlRule rule;
    rule.source = source;
    rule.type = type;
    rule.severity = severity;
    rule.enabled = enabled == GL_TRUE;
    rule.hasIds = count > 0;
    for (GLsizei index = 0; index < count; ++index) {
        rule.ids.insert(ids[index]);
    }
    impl_->debugControlRules.push_back(std::move(rule));
}

void GLContext::insertDebugMessage(
    GLenum source,
    GLenum type,
    GLuint id,
    GLenum severity,
    std::string_view message
) {
    emitDebugMessage(source, type, id, severity, message);
}

GLuint GLContext::getDebugMessageLog(
    GLuint count,
    GLsizei bufSize,
    GLenum* sources,
    GLenum* types,
    GLuint* ids,
    GLenum* severities,
    GLsizei* lengths,
    GLchar* messageLog
) {
    if (bufSize < 0) {
        pushError(GL_INVALID_VALUE);
        return 0;
    }

    GLuint delivered = 0;
    GLsizei usedBytes = 0;
    while (delivered < count && !impl_->debugMessages.empty()) {
        const DebugMessageRecord& message = impl_->debugMessages.front();
        const GLsizei requiredBytes = static_cast<GLsizei>(message.message.size() + 1);
        if (messageLog != nullptr && usedBytes + requiredBytes > bufSize) {
            break;
        }

        if (sources != nullptr) {
            sources[delivered] = message.source;
        }
        if (types != nullptr) {
            types[delivered] = message.type;
        }
        if (ids != nullptr) {
            ids[delivered] = message.id;
        }
        if (severities != nullptr) {
            severities[delivered] = message.severity;
        }
        if (lengths != nullptr) {
            lengths[delivered] = requiredBytes;
        }
        if (messageLog != nullptr) {
            std::memcpy(messageLog + usedBytes, message.message.c_str(), static_cast<std::size_t>(requiredBytes));
            usedBytes += requiredBytes;
        }

        impl_->debugMessages.pop_front();
        ++delivered;
    }
    return delivered;
}

void GLContext::pushDebugGroup(GLenum source, GLuint id, std::string_view message) {
    if (impl_->debugGroupStack.size() >= kMaxDebugGroupDepth) {
        pushError(GL_STACK_OVERFLOW);
        return;
    }
    DebugMessageRecord record{source, GL_DEBUG_TYPE_PUSH_GROUP, id, GL_DEBUG_SEVERITY_NOTIFICATION, std::string(message)};
    impl_->debugGroupStack.push_back(record);
    impl_->enqueueDebugMessage(record);
}

bool GLContext::popDebugGroup() {
    if (impl_->debugGroupStack.empty()) {
        pushError(GL_STACK_UNDERFLOW);
        return false;
    }
    DebugMessageRecord record = impl_->debugGroupStack.back();
    impl_->debugGroupStack.pop_back();
    record.type = GL_DEBUG_TYPE_POP_GROUP;
    impl_->enqueueDebugMessage(std::move(record));
    return true;
}

void GLContext::setObjectLabel(GLenum identifier, GLuint name, std::string_view label) {
    const std::uint64_t key = objectLabelKey(identifier, name);
    if (label.empty()) {
        impl_->objectLabels.erase(key);
        return;
    }
    impl_->objectLabels[key] = trimDebugMessage(label);
}

void GLContext::getObjectLabel(GLenum identifier, GLuint name, GLsizei bufSize, GLsizei* length, GLchar* label) {
    if (bufSize < 0) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    const auto found = impl_->objectLabels.find(objectLabelKey(identifier, name));
    const std::string_view value = found == impl_->objectLabels.end() ? std::string_view{} : std::string_view(found->second);
    copyLabelString(value, bufSize, length, label);
}

void GLContext::setObjectPtrLabel(const void* ptr, std::string_view label) {
    if (label.empty()) {
        impl_->pointerLabels.erase(ptr);
        return;
    }
    impl_->pointerLabels[ptr] = trimDebugMessage(label);
}

void GLContext::getObjectPtrLabel(const void* ptr, GLsizei bufSize, GLsizei* length, GLchar* label) {
    if (bufSize < 0) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    const auto found = impl_->pointerLabels.find(ptr);
    const std::string_view value = found == impl_->pointerLabels.end() ? std::string_view{} : std::string_view(found->second);
    copyLabelString(value, bufSize, length, label);
}

bool GLContext::getPointer(GLenum pname, void** params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    switch (pname) {
        case GL_DEBUG_CALLBACK_FUNCTION:
            *params = reinterpret_cast<void*>(impl_->debugCallback);
            return true;
        case GL_DEBUG_CALLBACK_USER_PARAM:
            *params = const_cast<void*>(impl_->debugUserParam);
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

void GLContext::pushError(GLenum error) {
    impl_->errors.push_back(error);
}

GLenum GLContext::popError() {
    if (impl_->errors.empty()) {
        return GL_NO_ERROR;
    }
    const GLenum error = impl_->errors.front();
    impl_->errors.pop_front();
    return error;
}

const GLubyte* GLContext::getString(GLenum name) {
    switch (name) {
        case GL_VENDOR:
            return reinterpret_cast<const GLubyte*>(impl_->vendorString.c_str());
        case GL_RENDERER:
            return reinterpret_cast<const GLubyte*>(impl_->rendererString.c_str());
        case GL_VERSION:
            return reinterpret_cast<const GLubyte*>(impl_->versionString.c_str());
        case GL_SHADING_LANGUAGE_VERSION:
            return reinterpret_cast<const GLubyte*>(impl_->shadingLanguageVersion.c_str());
        case GL_EXTENSIONS:
            return reinterpret_cast<const GLubyte*>(impl_->extensionsString.c_str());
        default:
            pushError(GL_INVALID_ENUM);
            return nullptr;
    }
}

const std::string& GLContext::rendererString() const {
    return impl_->rendererString;
}

void GLContext::setClaimedVersionString(std::string value) {
    impl_->versionString = value.empty() ? "3.0 AppGL bootstrap" : std::move(value);
}

GLCapabilities& GLContext::capabilities() {
    return *impl_->capabilities;
}

GLObjectStore& GLContext::objects() {
    return *impl_->objects;
}

GLStateTracker& GLContext::state() {
    return *impl_->state;
}

}  // namespace appgl
