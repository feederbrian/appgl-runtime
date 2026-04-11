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
    bool readPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels);
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

    bool genBuffers(GLsizei count, GLuint* buffers);
    bool deleteBuffers(GLsizei count, const GLuint* buffers);
    bool isBuffer(GLuint buffer) const;
    bool bindBuffer(GLenum target, GLuint buffer);
    bool bindBufferBase(GLenum target, GLuint index, GLuint buffer);
    bool bindBufferRange(GLenum target, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size);
    bool bufferData(GLenum target, GLsizeiptr size, const void* data, GLenum usage);
    bool bufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data);
    bool copyBufferSubData(GLenum readTarget, GLenum writeTarget, GLintptr readOffset, GLintptr writeOffset, GLsizeiptr size);
    bool getBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, void* data);
    void* mapBuffer(GLenum target, GLenum access);
    void* mapBufferRange(GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield access);
    GLboolean unmapBuffer(GLenum target);
    bool flushMappedBufferRange(GLenum target, GLintptr offset, GLsizeiptr length);
    bool getBufferParameterInteger(GLenum target, GLenum pname, GLint* params);
    bool getBufferParameterInteger64(GLenum target, GLenum pname, GLint64* params);
    bool getBufferPointer(GLenum target, GLenum pname, void** params);
    bool genVertexArrays(GLsizei count, GLuint* arrays);
    bool deleteVertexArrays(GLsizei count, const GLuint* arrays);
    bool isVertexArray(GLuint array) const;
    bool bindVertexArray(GLuint array);
    bool enableVertexAttribArray(GLuint index, bool enabled);
    bool vertexAttribPointer(GLuint index, GLint size, GLenum type, GLboolean normalized, GLsizei stride, const void* pointer);
    bool vertexAttribIPointer(GLuint index, GLint size, GLenum type, GLsizei stride, const void* pointer);
    bool vertexAttribDivisor(GLuint index, GLuint divisor);
    bool getVertexAttribInteger(GLuint index, GLenum pname, GLint* params);
    bool getVertexAttribFloat(GLuint index, GLenum pname, GLfloat* params);
    bool getVertexAttribPointer(GLuint index, GLenum pname, void** pointer);
    bool activeTexture(GLenum texture);
    bool genTextures(GLsizei count, GLuint* textures);
    bool deleteTextures(GLsizei count, const GLuint* textures);
    bool isTexture(GLuint texture) const;
    bool bindTexture(GLenum target, GLuint texture);
    bool texImage(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLsizei depth, GLint border, GLenum format, GLenum type, const void* pixels);
    bool texSubImage(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, const void* pixels);
    bool texParameterInteger(GLenum target, GLenum pname, const GLint* params);
    bool texParameterUnsignedInteger(GLenum target, GLenum pname, const GLuint* params);
    bool texParameterFloat(GLenum target, GLenum pname, const GLfloat* params);
    bool getTexParameterInteger(GLenum target, GLenum pname, GLint* params);
    bool getTexParameterUnsignedInteger(GLenum target, GLenum pname, GLuint* params);
    bool getTexParameterFloat(GLenum target, GLenum pname, GLfloat* params);
    bool generateMipmap(GLenum target);
    bool pixelStore(GLenum pname, GLint value);
    bool genRenderbuffers(GLsizei count, GLuint* renderbuffers);
    bool deleteRenderbuffers(GLsizei count, const GLuint* renderbuffers);
    bool isRenderbuffer(GLuint renderbuffer) const;
    bool bindRenderbuffer(GLenum target, GLuint renderbuffer);
    bool renderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height, GLsizei samples);
    bool getRenderbufferParameterInteger(GLenum target, GLenum pname, GLint* params);
    bool genFramebuffers(GLsizei count, GLuint* framebuffers);
    bool deleteFramebuffers(GLsizei count, const GLuint* framebuffers);
    bool isFramebuffer(GLuint framebuffer) const;
    bool bindFramebuffer(GLenum target, GLuint framebuffer);
    GLenum checkFramebufferStatus(GLenum target) const;
    bool framebufferTexture(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level, GLint layer, bool layered);
    bool framebufferRenderbuffer(GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer);
    bool blitFramebuffer(GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1, GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1, GLbitfield mask, GLenum filter);
    bool getFramebufferAttachmentParameterInteger(GLenum target, GLenum attachment, GLenum pname, GLint* params) const;
    bool drawBuffer(GLenum buffer);
    bool drawBuffers(GLsizei count, const GLenum* buffers);
    bool readBuffer(GLenum buffer);
    bool genSamplers(GLsizei count, GLuint* samplers);
    bool deleteSamplers(GLsizei count, const GLuint* samplers);
    bool isSampler(GLuint sampler) const;
    bool bindSampler(GLuint unit, GLuint sampler);
    bool samplerParameterInteger(GLuint sampler, GLenum pname, const GLint* params);
    bool samplerParameterUnsignedInteger(GLuint sampler, GLenum pname, const GLuint* params);
    bool samplerParameterFloat(GLuint sampler, GLenum pname, const GLfloat* params);
    bool getSamplerParameterInteger(GLuint sampler, GLenum pname, GLint* params);
    bool getSamplerParameterUnsignedInteger(GLuint sampler, GLenum pname, GLuint* params);
    bool getSamplerParameterFloat(GLuint sampler, GLenum pname, GLfloat* params);

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
