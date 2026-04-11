#include "GLContext.h"
#include "MetalFrameGraph.h"
#include "../caps/GLCapabilities.h"
#include "../objects/GLObjectStore.h"
#include "../state/GLStateTracker.h"
#include "../state/MetalVertexDescriptorBuilder.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <unordered_map>
#include <unordered_set>
#include <utility>
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

void* transferRetainedMetalObject(id object) {
    if (object == nil) {
        return nullptr;
    }
#if __has_feature(objc_arc)
    return (__bridge_retained void*)object;
#else
    return object;
#endif
}

void releaseRetainedMetalObject(void* object) {
    if (object == nullptr) {
        return;
    }
#if __has_feature(objc_arc)
    CFRelease(object);
#else
    [(id)object release];
#endif
}

id<MTLBuffer> metalBufferFromRaw(void* object) {
    if (object == nullptr) {
        return nil;
    }
#if __has_feature(objc_arc)
    return (__bridge id<MTLBuffer>)object;
#else
    return (id<MTLBuffer>)object;
#endif
}

MTLResourceOptions metalBufferOptionsForUsage(GLenum usage) {
    MTLResourceOptions options = MTLResourceStorageModeShared;
    switch (usage) {
        case GL_STREAM_DRAW:
        case GL_STATIC_DRAW:
        case GL_DYNAMIC_DRAW:
            options |= MTLResourceCPUCacheModeWriteCombined;
            break;
        default:
            break;
    }
    return options;
}

bool legacyMapAccessToFlags(GLenum access, GLbitfield* flags) {
    if (flags == nullptr) {
        return false;
    }
    switch (access) {
        case GL_READ_ONLY:
            *flags = GL_MAP_READ_BIT;
            return true;
        case GL_WRITE_ONLY:
            *flags = GL_MAP_WRITE_BIT;
            return true;
        case GL_READ_WRITE:
            *flags = GL_MAP_READ_BIT | GL_MAP_WRITE_BIT;
            return true;
        default:
            return false;
    }
}

GLenum legacyMapAccessFromFlags(GLbitfield access) {
    const bool readable = (access & GL_MAP_READ_BIT) != 0;
    const bool writable = (access & GL_MAP_WRITE_BIT) != 0;
    if (readable && !writable) {
        return GL_READ_ONLY;
    }
    if (!readable && writable) {
        return GL_WRITE_ONLY;
    }
    return GL_READ_WRITE;
}

bool mapAccessWrites(GLbitfield access) {
    return (access & GL_MAP_WRITE_BIT) != 0;
}

bool isSupportedMapBufferRangeAccess(GLbitfield access) {
    constexpr GLbitfield kSupportedAccessBits = GL_MAP_READ_BIT
        | GL_MAP_WRITE_BIT
        | GL_MAP_INVALIDATE_RANGE_BIT
        | GL_MAP_INVALIDATE_BUFFER_BIT
        | GL_MAP_FLUSH_EXPLICIT_BIT
        | GL_MAP_UNSYNCHRONIZED_BIT;
    if ((access & ~kSupportedAccessBits) != 0) {
        return false;
    }
    const bool readable = (access & GL_MAP_READ_BIT) != 0;
    const bool writable = (access & GL_MAP_WRITE_BIT) != 0;
    if (!readable && !writable) {
        return false;
    }
    if (readable && (access & (GL_MAP_INVALIDATE_RANGE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT | GL_MAP_UNSYNCHRONIZED_BIT)) != 0) {
        return false;
    }
    return (access & GL_MAP_FLUSH_EXPLICIT_BIT) == 0 || writable;
}

void resetBufferMapping(GLBufferObject& object) {
    object.mapped = false;
    object.mapAccess = GL_READ_WRITE;
    object.mapAccessFlags = 0;
    object.mapOffset = 0;
    object.mapLength = 0;
    object.mapPointer = nullptr;
}

void markVertexDescriptorDirty(GLVertexArrayObject& vertexArray) {
    vertexArray.vertexDescriptorDirty = true;
    vertexArray.vertexDescriptorError.clear();
}

}  // namespace

struct GLContext::Impl {
    ~Impl() {
        if (objects == nullptr) {
            return;
        }
        objects->buffers().forEach([&](GLuint, GLBufferObject& buffer) {
            releaseBufferStorage(buffer);
        });
        objects->vertexArrays().forEach([&](GLuint, GLVertexArrayObject& vertexArray) {
            releaseVertexDescriptor(vertexArray);
        });
    }

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

    void releaseBufferStorage(GLBufferObject& object) {
        releaseRetainedMetalObject(object.metalBuffer);
        object.metalBuffer = nullptr;
        object.size = 0;
        object.shadowBytes.clear();
        resetBufferMapping(object);
    }

    void releaseVertexDescriptor(GLVertexArrayObject& vertexArray) {
        releaseMetalVertexDescriptor(vertexArray.metalVertexDescriptor);
        vertexArray.metalVertexDescriptor = nullptr;
        vertexArray.vertexDescriptorHash.clear();
        vertexArray.vertexDescriptorError.clear();
        vertexArray.vertexDescriptorDirty = true;
    }

    bool replaceBufferStorage(GLBufferObject& object, GLsizeiptr size, const void* data, GLenum usage) {
        std::vector<std::uint8_t> shadowBytes(static_cast<std::size_t>(size), 0);
        if (data != nullptr && size > 0) {
            std::memcpy(shadowBytes.data(), data, static_cast<std::size_t>(size));
        }

        void* retainedMetalBuffer = nullptr;
        if (size > 0 && device != nil) {
            id<MTLBuffer> metalBuffer =
                [device newBufferWithLength:static_cast<NSUInteger>(size) options:metalBufferOptionsForUsage(usage)];
            if (metalBuffer == nil) {
                return false;
            }
            std::memcpy([metalBuffer contents], shadowBytes.data(), static_cast<std::size_t>(size));
            retainedMetalBuffer = transferRetainedMetalObject(metalBuffer);
        }

        releaseBufferStorage(object);
        object.size = size;
        object.usage = usage;
        object.shadowBytes = std::move(shadowBytes);
        object.metalBuffer = retainedMetalBuffer;
        resetBufferMapping(object);
        return true;
    }

    std::uint8_t* mutableBufferContents(GLBufferObject& object) {
        id<MTLBuffer> metalBuffer = metalBufferFromRaw(object.metalBuffer);
        if (metalBuffer != nil) {
            return static_cast<std::uint8_t*>([metalBuffer contents]);
        }
        return object.shadowBytes.empty() ? nullptr : object.shadowBytes.data();
    }

    const std::uint8_t* readableBufferContents(const GLBufferObject& object) const {
        id<MTLBuffer> metalBuffer = metalBufferFromRaw(object.metalBuffer);
        if (metalBuffer != nil) {
            return static_cast<const std::uint8_t*>([metalBuffer contents]);
        }
        return object.shadowBytes.empty() ? nullptr : object.shadowBytes.data();
    }

    void syncShadowFromMetal(GLBufferObject& object, GLintptr offset, GLsizeiptr length) {
        if (length <= 0 || object.metalBuffer == nullptr || object.shadowBytes.empty()) {
            return;
        }
        const std::uint8_t* contents = readableBufferContents(object);
        if (contents == nullptr) {
            return;
        }
        std::memcpy(
            object.shadowBytes.data() + static_cast<std::size_t>(offset),
            contents + static_cast<std::size_t>(offset),
            static_cast<std::size_t>(length)
        );
    }

    void syncMetalFromShadow(GLBufferObject& object, GLintptr offset, GLsizeiptr length) {
        if (length <= 0 || object.metalBuffer == nullptr || object.shadowBytes.empty()) {
            return;
        }
        std::uint8_t* contents = mutableBufferContents(object);
        if (contents == nullptr) {
            return;
        }
        std::memcpy(
            contents + static_cast<std::size_t>(offset),
            object.shadowBytes.data() + static_cast<std::size_t>(offset),
            static_cast<std::size_t>(length)
        );
    }

    GLVertexArrayObject* vertexArray(GLuint name) {
        GLVertexArrayObject* object = objects->vertexArrays().get(name);
        if (object != nullptr && object->attributes.empty()) {
            objects->initializeVertexArray(*object);
        }
        return object;
    }

    GLVertexArrayObject* currentVertexArray() {
        const GLuint name = state->boundVertexArray();
        if (name == 0) {
            return nullptr;
        }
        return vertexArray(name);
    }

    void deleteBufferReferencesFromVertexArrays(GLuint buffer) {
        objects->vertexArrays().forEach([&](GLuint, GLVertexArrayObject& vertexArray) {
            if (vertexArray.elementArrayBuffer == buffer) {
                vertexArray.elementArrayBuffer = 0;
            }
            for (auto& attribute : vertexArray.attributes) {
                if (attribute.buffer == buffer) {
                    attribute.buffer = 0;
                    markVertexDescriptorDirty(vertexArray);
                }
            }
        });
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

bool GLContext::genBuffers(GLsizei count, GLuint* buffers) {
    if (count < 0 || (count > 0 && buffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        buffers[index] = impl_->objects->buffers().reserveName();
    }
    return true;
}

bool GLContext::deleteBuffers(GLsizei count, const GLuint* buffers) {
    if (count < 0 || (count > 0 && buffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = buffers[index];
        if (name == 0) {
            continue;
        }
        if (GLBufferObject* object = impl_->objects->buffers().get(name); object != nullptr) {
            impl_->releaseBufferStorage(*object);
        }
        if (impl_->objects->buffers().erase(name)) {
            impl_->state->deleteBufferBindings(name);
            impl_->deleteBufferReferencesFromVertexArrays(name);
            impl_->objects->deferDelete("buffer " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isBuffer(GLuint buffer) const {
    const GLBufferObject* object = impl_->objects->buffers().get(buffer);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindBuffer(GLenum target, GLuint buffer) {
    if (buffer == 0) {
        impl_->state->bindBuffer(target, 0);
        if (target == GL_ELEMENT_ARRAY_BUFFER) {
            if (GLVertexArrayObject* vertexArray = impl_->currentVertexArray(); vertexArray != nullptr) {
                vertexArray->elementArrayBuffer = 0;
            }
        }
        return true;
    }
    GLBufferObject* object = impl_->objects->buffers().get(buffer);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    object->instantiated = true;
    impl_->state->bindBuffer(target, buffer);
    if (target == GL_ELEMENT_ARRAY_BUFFER) {
        if (GLVertexArrayObject* vertexArray = impl_->currentVertexArray(); vertexArray != nullptr) {
            vertexArray->elementArrayBuffer = buffer;
        }
    }
    return true;
}

bool GLContext::bindBufferRange(GLenum target, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    if (buffer == 0) {
        impl_->state->bindIndexedBuffer(target, index, 0, 0, 0);
        return true;
    }
    if (offset < 0 || size < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLBufferObject* object = impl_->objects->buffers().get(buffer);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    object->instantiated = true;
    impl_->state->bindIndexedBuffer(target, index, buffer, offset, size);
    return true;
}

bool GLContext::bindBufferBase(GLenum target, GLuint index, GLuint buffer) {
    GLsizeiptr size = 0;
    if (buffer != 0) {
        GLBufferObject* object = impl_->objects->buffers().get(buffer);
        if (object == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        object->instantiated = true;
        size = object->size;
    }
    impl_->state->bindIndexedBuffer(target, index, buffer, 0, size);
    return true;
}

bool GLContext::bufferData(GLenum target, GLsizeiptr size, const void* data, GLenum usage) {
    if (size < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (object->mapped) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!impl_->replaceBufferStorage(*object, size, data, usage)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::bufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data) {
    if (offset < 0 || size < 0 || (size > 0 && data == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || object->mapped) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (offset > object->size || size > object->size - offset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (size > 0) {
        std::memcpy(
            object->shadowBytes.data() + static_cast<std::size_t>(offset),
            data,
            static_cast<std::size_t>(size)
        );
        impl_->syncMetalFromShadow(*object, offset, size);
    }
    return true;
}

bool GLContext::copyBufferSubData(
    GLenum readTarget,
    GLenum writeTarget,
    GLintptr readOffset,
    GLintptr writeOffset,
    GLsizeiptr size
) {
    if (readOffset < 0 || writeOffset < 0 || size < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint readName = impl_->state->boundBuffer(readTarget);
    const GLuint writeName = impl_->state->boundBuffer(writeTarget);
    GLBufferObject* readObject = impl_->objects->buffers().get(readName);
    GLBufferObject* writeObject = impl_->objects->buffers().get(writeName);
    if (readName == 0 || writeName == 0 || readObject == nullptr || writeObject == nullptr
        || !readObject->instantiated || !writeObject->instantiated || readObject->mapped || writeObject->mapped) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (readOffset > readObject->size || size > readObject->size - readOffset
        || writeOffset > writeObject->size || size > writeObject->size - writeOffset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (readName == writeName) {
        const GLintptr readEnd = readOffset + size;
        const GLintptr writeEnd = writeOffset + size;
        if (size > 0 && readOffset < writeEnd && writeOffset < readEnd) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    if (size > 0) {
        const std::uint8_t* readBytes = impl_->readableBufferContents(*readObject);
        if (readBytes == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        std::memcpy(
            writeObject->shadowBytes.data() + static_cast<std::size_t>(writeOffset),
            readBytes + static_cast<std::size_t>(readOffset),
            static_cast<std::size_t>(size)
        );
        impl_->syncMetalFromShadow(*writeObject, writeOffset, size);
    }
    return true;
}

bool GLContext::getBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, void* data) {
    if (offset < 0 || size < 0 || (size > 0 && data == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || object->mapped) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (offset > object->size || size > object->size - offset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (size > 0) {
        const std::uint8_t* bytes = impl_->readableBufferContents(*object);
        if (bytes == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        std::memcpy(data, bytes + static_cast<std::size_t>(offset), static_cast<std::size_t>(size));
    }
    return true;
}

void* GLContext::mapBuffer(GLenum target, GLenum access) {
    GLbitfield flags = 0;
    if (!legacyMapAccessToFlags(access, &flags)) {
        pushError(GL_INVALID_ENUM);
        return nullptr;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || object->mapped || object->size <= 0) {
        pushError(GL_INVALID_OPERATION);
        return nullptr;
    }
    void* pointer = mapBufferRange(target, 0, object->size, flags);
    if (pointer != nullptr) {
        object->mapAccess = access;
    }
    return pointer;
}

void* GLContext::mapBufferRange(GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield access) {
    if (offset < 0 || length < 0) {
        pushError(GL_INVALID_VALUE);
        return nullptr;
    }
    if (!isSupportedMapBufferRangeAccess(access)) {
        pushError(GL_INVALID_VALUE);
        return nullptr;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || object->mapped) {
        pushError(GL_INVALID_OPERATION);
        return nullptr;
    }
    if (length == 0 || object->size <= 0) {
        pushError(GL_INVALID_OPERATION);
        return nullptr;
    }
    if (offset > object->size || length > object->size - offset) {
        pushError(GL_INVALID_VALUE);
        return nullptr;
    }

    std::uint8_t* contents = impl_->mutableBufferContents(*object);
    if (contents == nullptr) {
        pushError(GL_OUT_OF_MEMORY);
        return nullptr;
    }

    object->mapped = true;
    object->mapAccess = legacyMapAccessFromFlags(access);
    object->mapAccessFlags = access;
    object->mapOffset = offset;
    object->mapLength = length;
    object->mapPointer = contents + static_cast<std::size_t>(offset);
    return object->mapPointer;
}

GLboolean GLContext::unmapBuffer(GLenum target) {
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || !object->mapped) {
        pushError(GL_INVALID_OPERATION);
        return GL_FALSE;
    }
    if (mapAccessWrites(object->mapAccessFlags)) {
        impl_->syncShadowFromMetal(*object, object->mapOffset, object->mapLength);
    }
    resetBufferMapping(*object);
    return GL_TRUE;
}

bool GLContext::flushMappedBufferRange(GLenum target, GLintptr offset, GLsizeiptr length) {
    if (offset < 0 || length < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || !object->mapped
        || (object->mapAccessFlags & GL_MAP_FLUSH_EXPLICIT_BIT) == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (offset > object->mapLength || length > object->mapLength - offset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (mapAccessWrites(object->mapAccessFlags)) {
        impl_->syncShadowFromMetal(*object, object->mapOffset + offset, length);
    }
    return true;
}

bool GLContext::getBufferParameterInteger(GLenum target, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLint64 value = 0;
    if (!getBufferParameterInteger64(target, pname, &value)) {
        return false;
    }
    *params = static_cast<GLint>(value);
    return true;
}

bool GLContext::getBufferParameterInteger64(GLenum target, GLenum pname, GLint64* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    switch (pname) {
        case GL_BUFFER_SIZE:
            *params = object->size;
            return true;
        case GL_BUFFER_USAGE:
            *params = object->usage;
            return true;
        case GL_BUFFER_ACCESS:
            *params = object->mapAccess;
            return true;
        case GL_BUFFER_ACCESS_FLAGS:
            *params = object->mapped ? object->mapAccessFlags : 0;
            return true;
        case GL_BUFFER_MAPPED:
            *params = object->mapped ? GL_TRUE : GL_FALSE;
            return true;
        case GL_BUFFER_MAP_OFFSET:
            *params = object->mapped ? object->mapOffset : 0;
            return true;
        case GL_BUFFER_MAP_LENGTH:
            *params = object->mapped ? object->mapLength : 0;
            return true;
        case GL_BUFFER_IMMUTABLE_STORAGE:
            *params = GL_FALSE;
            return true;
        case GL_BUFFER_STORAGE_FLAGS:
            *params = 0;
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getBufferPointer(GLenum target, GLenum pname, void** params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname != GL_BUFFER_MAP_POINTER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    *params = object->mapped ? object->mapPointer : nullptr;
    return true;
}

bool GLContext::genVertexArrays(GLsizei count, GLuint* arrays) {
    if (count < 0 || (count > 0 && arrays == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = impl_->objects->vertexArrays().reserveName();
        arrays[index] = name;
        if (GLVertexArrayObject* object = impl_->objects->vertexArrays().get(name); object != nullptr) {
            impl_->objects->initializeVertexArray(*object);
        }
    }
    return true;
}

bool GLContext::deleteVertexArrays(GLsizei count, const GLuint* arrays) {
    if (count < 0 || (count > 0 && arrays == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = arrays[index];
        if (name == 0) {
            continue;
        }
        if (GLVertexArrayObject* object = impl_->objects->vertexArrays().get(name); object != nullptr) {
            impl_->releaseVertexDescriptor(*object);
        }
        if (impl_->objects->vertexArrays().erase(name)) {
            if (impl_->state->boundVertexArray() == name) {
                impl_->state->bindVertexArray(0);
                impl_->state->bindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
            }
            impl_->objects->deferDelete("vertex array " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isVertexArray(GLuint array) const {
    const GLVertexArrayObject* object = impl_->objects->vertexArrays().get(array);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindVertexArray(GLuint array) {
    if (array == 0) {
        impl_->state->bindVertexArray(0);
        impl_->state->bindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
        return true;
    }
    GLVertexArrayObject* object = impl_->vertexArray(array);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    object->instantiated = true;
    impl_->state->bindVertexArray(array);
    impl_->state->bindBuffer(GL_ELEMENT_ARRAY_BUFFER, object->elementArrayBuffer);
    return true;
}

bool GLContext::enableVertexAttribArray(GLuint index, bool enabled) {
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    vertexArray->attributes[index].enabled = enabled;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribPointer(
    GLuint index,
    GLint size,
    GLenum type,
    GLboolean normalized,
    GLsizei stride,
    const void* pointer
) {
    if (size < 1 || size > 4 || stride < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    const GLuint buffer = impl_->state->boundBuffer(GL_ARRAY_BUFFER);
    if (buffer == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    auto& attribute = vertexArray->attributes[index];
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = normalized;
    attribute.stride = stride;
    attribute.pointer = reinterpret_cast<std::uintptr_t>(pointer);
    attribute.buffer = buffer;
    attribute.integer = false;
    attribute.longData = false;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribIPointer(GLuint index, GLint size, GLenum type, GLsizei stride, const void* pointer) {
    if (size < 1 || size > 4 || stride < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    const GLuint buffer = impl_->state->boundBuffer(GL_ARRAY_BUFFER);
    if (buffer == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    auto& attribute = vertexArray->attributes[index];
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = GL_FALSE;
    attribute.stride = stride;
    attribute.pointer = reinterpret_cast<std::uintptr_t>(pointer);
    attribute.buffer = buffer;
    attribute.integer = true;
    attribute.longData = false;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribDivisor(GLuint index, GLuint divisor) {
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    vertexArray->attributes[index].divisor = divisor;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::getVertexAttribInteger(GLuint index, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    const auto& attribute = vertexArray->attributes[index];
    switch (pname) {
        case GL_VERTEX_ATTRIB_ARRAY_ENABLED:
            params[0] = attribute.enabled ? GL_TRUE : GL_FALSE;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_SIZE:
            params[0] = attribute.size;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_STRIDE:
            params[0] = attribute.stride;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_TYPE:
            params[0] = static_cast<GLint>(attribute.type);
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_NORMALIZED:
            params[0] = attribute.normalized;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING:
            params[0] = static_cast<GLint>(attribute.buffer);
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_INTEGER:
            params[0] = attribute.integer ? GL_TRUE : GL_FALSE;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_DIVISOR:
            params[0] = static_cast<GLint>(attribute.divisor);
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_LONG:
            params[0] = attribute.longData ? GL_TRUE : GL_FALSE;
            return true;
        case GL_CURRENT_VERTEX_ATTRIB:
            params[0] = 0;
            params[1] = 0;
            params[2] = 0;
            params[3] = 1;
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getVertexAttribFloat(GLuint index, GLenum pname, GLfloat* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_CURRENT_VERTEX_ATTRIB) {
        params[0] = 0.0f;
        params[1] = 0.0f;
        params[2] = 0.0f;
        params[3] = 1.0f;
        return true;
    }

    GLint values[4] = {};
    if (!getVertexAttribInteger(index, pname, values)) {
        return false;
    }
    params[0] = static_cast<GLfloat>(values[0]);
    return true;
}

bool GLContext::getVertexAttribPointer(GLuint index, GLenum pname, void** pointer) {
    if (pointer == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname != GL_VERTEX_ATTRIB_ARRAY_POINTER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    *pointer = reinterpret_cast<void*>(vertexArray->attributes[index].pointer);
    return true;
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
