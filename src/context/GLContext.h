#pragma once

#include <deque>
#include <memory>
#include <string>
#include <string_view>

#include "../../include/AppGL/glcorearb.h"

namespace appgl {

class GLCapabilities;
class GLObjectStore;
class GLStateTracker;

class GLContext {
public:
    explicit GLContext(void* layer);
    GLContext(GLsizei offscreenWidth, GLsizei offscreenHeight);
    ~GLContext();

    GLContext(const GLContext&) = delete;
    GLContext& operator=(const GLContext&) = delete;

    void setClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
    void setClearDepth(GLdouble depth);
    void setClearStencil(GLint stencil);
    void clear(GLbitfield mask);
    void setViewport(GLint x, GLint y, GLsizei width, GLsizei height);
    void setScissor(GLint x, GLint y, GLsizei width, GLsizei height);
    void setDepthRange(GLdouble nearValue, GLdouble farValue);
    void setBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha);
    void setBlendEquationSeparate(GLenum equationRGB, GLenum equationAlpha);
    void setBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
    void setColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
    void setColorMaski(GLuint index, GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
    void setDepthFunc(GLenum func);
    void setDepthMask(GLboolean flag);
    void setStencilFuncSeparate(GLenum face, GLenum func, GLint ref, GLuint mask);
    void setStencilOpSeparate(GLenum face, GLenum fail, GLenum depthFail, GLenum depthPass);
    void setStencilMaskSeparate(GLenum face, GLuint mask);
    void setCullFace(GLenum mode);
    void setFrontFace(GLenum mode);
    void setPolygonOffset(GLfloat factor, GLfloat units);
    void setLineWidth(GLfloat width);
    void setPointSize(GLfloat size);
    void setHint(GLenum target, GLenum mode);
    void flush();
    void swapBuffers();
    void readPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels);
    bool queryBoolean(GLenum pname, GLboolean* data);
    bool queryInteger(GLenum pname, GLint* data);
    bool queryInteger64(GLenum pname, GLint64* data);
    bool queryFloat(GLenum pname, GLfloat* data);
    bool queryDouble(GLenum pname, GLdouble* data);
    void setEnabled(GLenum cap, bool enabled);
    bool isEnabled(GLenum cap) const;

    void setDebugCallback(GLDEBUGPROC callback, const void* userParam);
    void emitDebugMessage(GLenum source, GLenum type, GLuint id, GLenum severity, std::string_view message);
    void setDebugMessageControl(GLenum source, GLenum type, GLenum severity, GLsizei count, const GLuint* ids, GLboolean enabled);
    void insertDebugMessage(GLenum source, GLenum type, GLuint id, GLenum severity, std::string_view message);
    GLuint getDebugMessageLog(
        GLuint count,
        GLsizei bufSize,
        GLenum* sources,
        GLenum* types,
        GLuint* ids,
        GLenum* severities,
        GLsizei* lengths,
        GLchar* messageLog
    );
    void pushDebugGroup(GLenum source, GLuint id, std::string_view message);
    bool popDebugGroup();
    void setObjectLabel(GLenum identifier, GLuint name, std::string_view label);
    void getObjectLabel(GLenum identifier, GLuint name, GLsizei bufSize, GLsizei* length, GLchar* label);
    void setObjectPtrLabel(const void* ptr, std::string_view label);
    void getObjectPtrLabel(const void* ptr, GLsizei bufSize, GLsizei* length, GLchar* label);
    bool getPointer(GLenum pname, void** params);

    void pushError(GLenum error);
    GLenum popError();

    const GLubyte* getString(GLenum name);
    const std::string& rendererString() const;
    void setClaimedVersionString(std::string value);
    GLCapabilities& capabilities();
    GLObjectStore& objects();
    GLStateTracker& state();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace appgl
