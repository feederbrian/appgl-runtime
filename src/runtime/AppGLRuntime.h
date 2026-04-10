#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <type_traits>

#include "../../include/AppGL/glcorearb.h"
#include "../context/GLContext.h"
#include "../debug/CoverageStore.h"
#include "../debug/TraceLog.h"
#include "../generated/gl_dispatch.gen.h"

namespace appgl {

namespace impl {
void APIENTRY glClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
void APIENTRY glClear(GLbitfield mask);
void APIENTRY glClearDepth(GLdouble depth);
void APIENTRY glClearStencil(GLint stencil);
void APIENTRY glViewport(GLint x, GLint y, GLsizei width, GLsizei height);
void APIENTRY glFlush(void);
void APIENTRY glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels);
void APIENTRY glGetIntegerv(GLenum pname, GLint* data);
void APIENTRY glGetInteger64v(GLenum pname, GLint64* data);
void APIENTRY glGetFloatv(GLenum pname, GLfloat* data);
void APIENTRY glEnable(GLenum cap);
void APIENTRY glDisable(GLenum cap);
GLboolean APIENTRY glIsEnabled(GLenum cap);
const GLubyte* APIENTRY glGetString(GLenum name);
GLenum APIENTRY glGetError(void);
void APIENTRY glDebugMessageCallback(GLDEBUGPROC callback, const void* userParam);
}  // namespace impl

class Runtime {
public:
    static Runtime& shared();

    GLDispatchTable& dispatch();
    const GLDispatchTable& dispatch() const;

    void recordFunctionInvocation(FunctionId id, std::string_view functionName);
    void recordBootstrapTrace(std::string message);
    void recordUnimplemented(FunctionId id, std::string_view functionName);

    void makeCurrent(GLContext* context);
    GLContext* currentContext();
    std::string claimedVersionString() const;
    void refreshCurrentContextClaimedVersion();

    void noteRenderer(std::string renderer);
    std::size_t writeCoverageSnapshotJSON(char* out, std::size_t cap);

    CoverageStore& coverageStore();
    TraceLog& traceLog();

private:
    Runtime();
    void initializeDispatch();

    GLDispatchTable dispatch_;
    CoverageStore coverageStore_;
    TraceLog traceLog_;
    std::string rendererString_ = "AppGL on Metal";
};

template <typename ReturnType>
inline ReturnType unimplementedReturn(FunctionId id, const char* functionName) {
    Runtime::shared().recordUnimplemented(id, functionName);
    if constexpr (std::is_void_v<ReturnType>) {
        return;
    } else if constexpr (std::is_pointer_v<ReturnType>) {
        return nullptr;
    } else {
        return static_cast<ReturnType>(0);
    }
}

}  // namespace appgl
