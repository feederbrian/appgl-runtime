#include "AppGLRuntime.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <sstream>

#include "../../include/AppGL/AppGL.h"
#include "../loader/DispatchInstall.h"

namespace appgl {

namespace {
thread_local GLContext* gCurrentContext = nullptr;
constexpr const char* kBootstrapTestId = "bootstrap.clear-loop";
constexpr const char* kPhaseAStateTestId = "phase-a.state";

GLContext* requireCurrentContext(std::string_view functionName) {
    auto* context = Runtime::shared().currentContext();
    if (context == nullptr) {
        Runtime::shared().recordBootstrapTrace(
            std::string(functionName) + ": no current context"
        );
    }
    return context;
}

std::string formatFloat(GLfloat value) {
    std::ostringstream stream;
    stream.setf(std::ios::fixed);
    stream.precision(3);
    stream << value;
    return stream.str();
}
}  // namespace

Runtime& Runtime::shared() {
    static Runtime runtime;
    return runtime;
}

Runtime::Runtime() {
    initializeDispatch();
}

void Runtime::initializeDispatch() {
    installBootstrapDispatch(dispatch_, coverageStore_);
}

GLDispatchTable& Runtime::dispatch() {
    return dispatch_;
}

const GLDispatchTable& Runtime::dispatch() const {
    return dispatch_;
}

void Runtime::recordFunctionInvocation(FunctionId id, std::string_view functionName) {
    coverageStore_.recordCall(id);
    traceLog_.append(std::string(functionName));
}

void Runtime::recordBootstrapTrace(std::string message) {
    traceLog_.append(std::move(message));
}

void Runtime::recordUnimplemented(FunctionId id, std::string_view functionName) {
    coverageStore_.markStubbed(id, "Entry point exported, but backend work is not implemented yet.");
    coverageStore_.recordUnimplementedHit(id);
    traceLog_.append(std::string(functionName) + " -> stubbed");
    if (gCurrentContext != nullptr) {
        gCurrentContext->pushError(GL_INVALID_OPERATION);
        gCurrentContext->emitDebugMessage(
            GL_DEBUG_SOURCE_APPLICATION,
            GL_DEBUG_TYPE_ERROR,
            1,
            GL_DEBUG_SEVERITY_HIGH,
            std::string(functionName) + " is not implemented in AppGL yet."
        );
    }
}

void Runtime::makeCurrent(GLContext* context) {
    gCurrentContext = context;
    if (context != nullptr) {
        noteRenderer(context->rendererString());
        refreshCurrentContextClaimedVersion();
    }
}

GLContext* Runtime::currentContext() {
    return gCurrentContext;
}

std::string Runtime::claimedVersionString() const {
    return coverageStore_.highestFullyImplementedVersion();
}

void Runtime::refreshCurrentContextClaimedVersion() {
    if (gCurrentContext != nullptr) {
        gCurrentContext->setClaimedVersionString(claimedVersionString());
    }
}

void Runtime::noteRenderer(std::string renderer) {
    rendererString_ = std::move(renderer);
}

std::size_t Runtime::writeCoverageSnapshotJSON(char* out, std::size_t cap) {
    const std::string payload = coverageStore_.buildSnapshotJson(rendererString_, traceLog_.snapshot());
    const std::size_t required = payload.size() + 1;
    if (out == nullptr || cap == 0) {
        return required;
    }
    const std::size_t bytesToCopy = std::min(required - 1, cap - 1);
    std::memcpy(out, payload.data(), bytesToCopy);
    out[bytesToCopy] = '\0';
    return required;
}

CoverageStore& Runtime::coverageStore() {
    return coverageStore_;
}

TraceLog& Runtime::traceLog() {
    return traceLog_;
}

namespace impl {

void APIENTRY glClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    auto* context = requireCurrentContext("glClearColor");
    if (context == nullptr) {
        return;
    }
    context->setClearColor(red, green, blue, alpha);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glClearColor,
        kBootstrapTestId,
        "Animated clear loop drives the Metal-backed default framebuffer."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace(
        "glClearColor(" + formatFloat(red) + ", " + formatFloat(green) + ", " + formatFloat(blue) + ", " + formatFloat(alpha) + ")"
    );
}

void APIENTRY glClear(GLbitfield mask) {
    auto* context = requireCurrentContext("glClear");
    if (context == nullptr) {
        return;
    }
    context->clear(mask);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glClear,
        kBootstrapTestId,
        "Bootstrap clear path encodes a Metal render pass and presents it."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glClear(mask=" + std::to_string(mask) + ")");
}

void APIENTRY glClearDepth(GLdouble depth) {
    auto* context = requireCurrentContext("glClearDepth");
    if (context == nullptr) {
        return;
    }
    context->setClearDepth(depth);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glClearDepth,
        "phase-a.read-pixels",
        "Default framebuffer depth clear state is tracked."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glClearDepth(" + formatFloat(static_cast<GLfloat>(depth)) + ")");
}

void APIENTRY glClearStencil(GLint stencil) {
    auto* context = requireCurrentContext("glClearStencil");
    if (context == nullptr) {
        return;
    }
    context->setClearStencil(stencil);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glClearStencil,
        "phase-a.read-pixels",
        "Default framebuffer stencil clear state is tracked."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glClearStencil(" + std::to_string(stencil) + ")");
}

void APIENTRY glViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    auto* context = requireCurrentContext("glViewport");
    if (context == nullptr) {
        return;
    }
    context->setViewport(x, y, width, height);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glViewport,
        kBootstrapTestId,
        "Viewport updates drive the CAMetalLayer drawable size."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace(
        "glViewport(" + std::to_string(x) + ", " + std::to_string(y) + ", "
        + std::to_string(width) + ", " + std::to_string(height) + ")"
    );
}

void APIENTRY glFlush(void) {
    auto* context = requireCurrentContext("glFlush");
    if (context == nullptr) {
        return;
    }
    context->flush();
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glFlush,
        kBootstrapTestId,
        "Bootstrap flush presents the pending CAMetalLayer drawable."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glFlush()");
}

void APIENTRY glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels) {
    auto* context = requireCurrentContext("glReadPixels");
    if (context == nullptr) {
        return;
    }
    context->readPixels(x, y, width, height, format, type, pixels);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glReadPixels,
        "phase-a.read-pixels",
        "RGBA/UNSIGNED_BYTE readback drives golden capture."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace(
        "glReadPixels(" + std::to_string(width) + "x" + std::to_string(height) + ")"
    );
}

void APIENTRY glGetIntegerv(GLenum pname, GLint* data) {
    auto* context = requireCurrentContext("glGetIntegerv");
    if (context == nullptr) {
        return;
    }
    (void)context->queryInteger(pname, data);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glGetIntegerv,
        "phase-a.capabilities",
        "Capability integer queries route through GLCapabilities."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glGetIntegerv(" + std::to_string(pname) + ")");
}

void APIENTRY glGetInteger64v(GLenum pname, GLint64* data) {
    auto* context = requireCurrentContext("glGetInteger64v");
    if (context == nullptr) {
        return;
    }
    (void)context->queryInteger64(pname, data);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glGetInteger64v,
        "phase-a.capabilities",
        "Capability integer64 queries route through GLCapabilities."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glGetInteger64v(" + std::to_string(pname) + ")");
}

void APIENTRY glGetFloatv(GLenum pname, GLfloat* data) {
    auto* context = requireCurrentContext("glGetFloatv");
    if (context == nullptr) {
        return;
    }
    (void)context->queryFloat(pname, data);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glGetFloatv,
        "phase-a.capabilities",
        "Capability float queries route through GLCapabilities."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glGetFloatv(" + std::to_string(pname) + ")");
}

void APIENTRY glEnable(GLenum cap) {
    auto* context = requireCurrentContext("glEnable");
    if (context == nullptr) {
        return;
    }
    context->setEnabled(cap, true);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glEnable,
        kPhaseAStateTestId,
        "Enable-state mirror updates canonical GL state."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glEnable(" + std::to_string(cap) + ")");
}

void APIENTRY glDisable(GLenum cap) {
    auto* context = requireCurrentContext("glDisable");
    if (context == nullptr) {
        return;
    }
    context->setEnabled(cap, false);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glDisable,
        kPhaseAStateTestId,
        "Enable-state mirror updates canonical GL state."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glDisable(" + std::to_string(cap) + ")");
}

GLboolean APIENTRY glIsEnabled(GLenum cap) {
    auto* context = requireCurrentContext("glIsEnabled");
    if (context == nullptr) {
        return GL_FALSE;
    }
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glIsEnabled,
        kPhaseAStateTestId,
        "Enable-state mirror answers canonical GL state queries."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glIsEnabled(" + std::to_string(cap) + ")");
    return context->isEnabled(cap) ? GL_TRUE : GL_FALSE;
}

const GLubyte* APIENTRY glGetString(GLenum name) {
    auto* context = requireCurrentContext("glGetString");
    if (context == nullptr) {
        return nullptr;
    }
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glGetString,
        kBootstrapTestId,
        "AppGL reports conservative bootstrap identity strings."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    return context->getString(name);
}

GLenum APIENTRY glGetError(void) {
    auto* context = Runtime::shared().currentContext();
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glGetError,
        kBootstrapTestId,
        "Bootstrap runtime maintains a per-context error FIFO."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    if (context == nullptr) {
        return GL_NO_ERROR;
    }
    return context->popError();
}

void APIENTRY glDebugMessageCallback(GLDEBUGPROC callback, const void* userParam) {
    auto* context = requireCurrentContext("glDebugMessageCallback");
    if (context == nullptr) {
        return;
    }
    context->setDebugCallback(callback, userParam);
    Runtime::shared().coverageStore().markSmokeTested(
        FunctionId::glDebugMessageCallback,
        kBootstrapTestId,
        "Bootstrap debug callback receives unsupported-entry-point diagnostics."
    );
    Runtime::shared().refreshCurrentContextClaimedVersion();
    Runtime::shared().recordBootstrapTrace("glDebugMessageCallback(callback)");
}

}  // namespace impl

}  // namespace appgl

extern "C" AppGLContext* appglCreateContextForLayer(void* layer) {
    auto* context = new appgl::GLContext(layer);
    appgl::Runtime::shared().noteRenderer(context->rendererString());
    context->setClaimedVersionString(appgl::Runtime::shared().claimedVersionString());
    return reinterpret_cast<AppGLContext*>(context);
}

extern "C" AppGLContext* appglCreateOffscreenContext(int width, int height) {
    auto* context = new appgl::GLContext(width, height);
    appgl::Runtime::shared().noteRenderer(context->rendererString());
    context->setClaimedVersionString(appgl::Runtime::shared().claimedVersionString());
    return reinterpret_cast<AppGLContext*>(context);
}

extern "C" void appglDestroyContext(AppGLContext* context) {
    delete reinterpret_cast<appgl::GLContext*>(context);
}

extern "C" void appglMakeCurrent(AppGLContext* context) {
    appgl::Runtime::shared().makeCurrent(reinterpret_cast<appgl::GLContext*>(context));
}

extern "C" void appglSwapBuffers(AppGLContext* context) {
    if (context == nullptr) {
        return;
    }
    reinterpret_cast<appgl::GLContext*>(context)->swapBuffers();
}

extern "C" std::size_t appglCoverageSnapshotJSON(char* out, std::size_t cap) {
    return appgl::Runtime::shared().writeCoverageSnapshotJSON(out, cap);
}
