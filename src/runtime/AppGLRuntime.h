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
void APIENTRY glGetBooleanv(GLenum pname, GLboolean* data);
void APIENTRY glGetIntegerv(GLenum pname, GLint* data);
void APIENTRY glGetInteger64v(GLenum pname, GLint64* data);
void APIENTRY glGetFloatv(GLenum pname, GLfloat* data);
void APIENTRY glGetDoublev(GLenum pname, GLdouble* data);
void APIENTRY glEnable(GLenum cap);
void APIENTRY glDisable(GLenum cap);
GLboolean APIENTRY glIsEnabled(GLenum cap);
void APIENTRY glScissor(GLint x, GLint y, GLsizei width, GLsizei height);
void APIENTRY glDepthRange(GLdouble nearValue, GLdouble farValue);
void APIENTRY glDepthRangef(GLfloat nearValue, GLfloat farValue);
void APIENTRY glBlendFunc(GLenum srcFactor, GLenum dstFactor);
void APIENTRY glBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha);
void APIENTRY glBlendEquation(GLenum mode);
void APIENTRY glBlendEquationSeparate(GLenum modeRGB, GLenum modeAlpha);
void APIENTRY glBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
void APIENTRY glColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
void APIENTRY glColorMaski(GLuint index, GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
void APIENTRY glDepthFunc(GLenum func);
void APIENTRY glDepthMask(GLboolean flag);
void APIENTRY glStencilFunc(GLenum func, GLint ref, GLuint mask);
void APIENTRY glStencilFuncSeparate(GLenum face, GLenum func, GLint ref, GLuint mask);
void APIENTRY glStencilOp(GLenum fail, GLenum depthFail, GLenum depthPass);
void APIENTRY glStencilOpSeparate(GLenum face, GLenum fail, GLenum depthFail, GLenum depthPass);
void APIENTRY glStencilMask(GLuint mask);
void APIENTRY glStencilMaskSeparate(GLenum face, GLuint mask);
void APIENTRY glCullFace(GLenum mode);
void APIENTRY glFrontFace(GLenum mode);
void APIENTRY glPolygonOffset(GLfloat factor, GLfloat units);
void APIENTRY glLineWidth(GLfloat width);
void APIENTRY glPointSize(GLfloat size);
void APIENTRY glHint(GLenum target, GLenum mode);
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
