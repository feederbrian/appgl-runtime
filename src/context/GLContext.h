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

    // Per-viewport-index state (GL 4.1 ARB_viewport_array).
    void setViewportIndexed(GLuint index, GLfloat x, GLfloat y, GLfloat w, GLfloat h);
    void setViewportArray(GLuint first, GLsizei count, const GLfloat* v);
    void setScissorIndexed(GLuint index, GLint left, GLint bottom, GLsizei width, GLsizei height);
    void setScissorArray(GLuint first, GLsizei count, const GLint* v);
    void setDepthRangeIndexed(GLuint index, GLdouble nearVal, GLdouble farVal);
    void setDepthRangeArray(GLuint first, GLsizei count, const GLdouble* v);
    bool queryFloatIndexed(GLenum target, GLuint index, GLfloat* data);
    bool queryDoubleIndexed(GLenum target, GLuint index, GLdouble* data);

    // Tessellation state (GL 4.0).
    void setPatchParameteri(GLenum pname, GLint value);
    void setPatchParameterfv(GLenum pname, const GLfloat* values);

    // Shader precision query (GL 4.1).
    void getShaderPrecisionFormat(GLenum shadertype, GLenum precisiontype, GLint* range, GLint* precision);
    void setBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha);
    void setBlendFuncSeparatei(GLuint index, GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha);
    void setBlendEquationSeparate(GLenum equationRGB, GLenum equationAlpha);
    void setBlendEquationSeparatei(GLuint index, GLenum equationRGB, GLenum equationAlpha);
    void setBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
    void setColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
    void setColorMaski(GLuint index, GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
    void setMinSampleShading(GLfloat value);
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
    // GL 4.3 — separated vertex format (ARB_vertex_attrib_binding).
    bool bindVertexBuffer(GLuint bindingindex, GLuint buffer, GLintptr offset, GLsizei stride);
    bool vertexAttribFormat(GLuint attribindex, GLint size, GLenum type, GLboolean normalized, GLuint relativeoffset);
    bool vertexAttribIFormat(GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset);
    bool vertexAttribLFormat(GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset);
    bool vertexAttribBinding(GLuint attribindex, GLuint bindingindex);
    bool vertexBindingDivisor(GLuint bindingindex, GLuint divisor);
    // GL 4.1 — double-precision vertex attributes (f64→f32 narrowing).
    bool vertexAttribLPointer(GLuint index, GLint size, GLenum type, GLsizei stride, const void* pointer);
    bool setVertexAttribLImmediate(GLuint index, GLint count, const GLdouble* values);
    bool getVertexAttribLdv(GLuint index, GLenum pname, GLdouble* params);
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
    bool texStorage(GLenum target, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth);
    bool texStorageMultisample(GLenum target, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth, GLboolean fixedsamplelocations);
    bool texBufferRange(GLenum target, GLenum internalformat, GLuint buffer, GLintptr offset, GLsizeiptr size);
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

    GLuint createShader(GLenum stage);
    bool deleteShader(GLuint shader);
    bool isShader(GLuint shader) const;
    bool shaderSource(GLuint shader, GLsizei count, const GLchar* const* strings, const GLint* length);
    bool compileShader(GLuint shader);
    bool getShaderiv(GLuint shader, GLenum pname, GLint* params);
    bool getShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* infoLog);
    bool getShaderSource(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* source);

    GLuint createProgram();
    bool deleteProgram(GLuint program);
    bool isProgram(GLuint program) const;
    bool attachShader(GLuint program, GLuint shader);
    bool detachShader(GLuint program, GLuint shader);
    bool linkProgram(GLuint program);
    bool useProgram(GLuint program);
    bool validateProgram(GLuint program);
    bool getProgramiv(GLuint program, GLenum pname, GLint* params);
    bool getProgramInfoLog(GLuint program, GLsizei bufSize, GLsizei* length, GLchar* infoLog);
    bool getAttachedShaders(GLuint program, GLsizei maxCount, GLsizei* count, GLuint* shaders);
    bool bindAttribLocation(GLuint program, GLuint index, const GLchar* name);
    GLint getAttribLocation(GLuint program, const GLchar* name);
    bool getActiveAttrib(GLuint program, GLuint index, GLsizei bufSize, GLsizei* length, GLint* size, GLenum* type, GLchar* name);
    GLint getUniformLocation(GLuint program, const GLchar* name);
    bool getActiveUniform(GLuint program, GLuint index, GLsizei bufSize, GLsizei* length, GLint* size, GLenum* type, GLchar* name);
    bool getUniformfv(GLuint program, GLint location, GLfloat* params);
    bool getUniformiv(GLuint program, GLint location, GLint* params);
    bool getUniformuiv(GLuint program, GLint location, GLuint* params);
    bool getUniformdv(GLuint program, GLint location, GLdouble* params);

    enum class UniformElementType { Float, Int, UnsignedInt };
    bool setUniformScalarVector(GLint location, UniformElementType element, GLint vectorSize, GLsizei count, const void* values);
    bool setUniformMatrix(GLint location, GLint rows, GLint cols, GLsizei count, GLboolean transpose, const GLfloat* values);
    bool setUniformDouble(GLint location, GLint vectorSize, GLsizei count, const GLdouble* values);
    bool setUniformDoubleMatrix(GLint location, GLint rows, GLint cols, GLsizei count, GLboolean transpose, const GLdouble* values);
    // GL 4.1 — glProgramUniform* family: explicit program handle variants.
    bool setUniformScalarVectorForProgram(GLuint program, GLint location, UniformElementType element, GLint vectorSize, GLsizei count, const void* values);
    bool setUniformMatrixForProgram(GLuint program, GLint location, GLint rows, GLint cols, GLsizei count, GLboolean transpose, const GLfloat* values);
    bool setUniformDoubleForProgram(GLuint program, GLint location, GLint vectorSize, GLsizei count, const GLdouble* values);
    bool setUniformDoubleMatrixForProgram(GLuint program, GLint location, GLint rows, GLint cols, GLsizei count, GLboolean transpose, const GLdouble* values);

    // Phase A Group 7 — drawing. See MetalFrameGraph::encodeSolidColorDraw for
    // the minimal pipeline state we currently support. Additional draw variants
    // (instanced, base-vertex, multi-draw) ship in Group 8.
    bool drawArrays(GLenum mode, GLint first, GLsizei count);
    bool drawElements(GLenum mode, GLsizei count, GLenum type, const void* indices);

    // GL 4.2/4.3 — compute shaders and memory barriers.
    // Stubs: validate parameters and record state. Actual Metal compute encoding
    // will be wired when compute shader programs are created at link time.
    bool memoryBarrier(GLbitfield barriers);
    bool dispatchCompute(GLuint num_groups_x, GLuint num_groups_y, GLuint num_groups_z);
    bool dispatchComputeIndirect(GLintptr indirect);

    // GL 4.2 — image load/store.
    bool bindImageTexture(GLuint unit, GLuint texture, GLint level, GLboolean layered, GLint layer, GLenum access, GLenum format);

    // GL 4.2 — atomic counter buffer queries (stub returning sensible defaults).
    bool getActiveAtomicCounterBufferiv(GLuint program, GLuint bufferIndex, GLenum pname, GLint* params);

    // GL 4.3 — program resource introspection (ARB_program_interface_query).
    bool getProgramInterfaceiv(GLuint program, GLenum programInterface, GLenum pname, GLint* params);
    bool getProgramResourceiv(GLuint program, GLenum programInterface, GLuint index, GLsizei propCount, const GLenum* props, GLsizei count, GLsizei* length, GLint* params);
    bool getProgramResourceName(GLuint program, GLenum programInterface, GLuint index, GLsizei bufSize, GLsizei* length, GLchar* name);
    GLuint getProgramResourceIndex(GLuint program, GLenum programInterface, const GLchar* name);
    GLint getProgramResourceLocation(GLuint program, GLenum programInterface, const GLchar* name);
    GLint getProgramResourceLocationIndex(GLuint program, GLenum programInterface, const GLchar* name);

    // GL 4.3 — SSBO binding remapping.
    bool shaderStorageBlockBinding(GLuint program, GLuint storageBlockIndex, GLuint storageBlockBinding);

    // GL 4.2 — advanced instanced drawing with base instance.
    bool drawArraysInstancedBaseInstance(GLenum mode, GLint first, GLsizei count, GLsizei instancecount, GLuint baseinstance);
    bool drawElementsInstancedBaseInstance(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLuint baseinstance);
    bool drawElementsInstancedBaseVertexBaseInstance(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLint basevertex, GLuint baseinstance);

    // GL 4.3 — multi-draw indirect.
    bool multiDrawArraysIndirect(GLenum mode, const void* indirect, GLsizei drawcount, GLsizei stride);
    bool multiDrawElementsIndirect(GLenum mode, GLenum type, const void* indirect, GLsizei drawcount, GLsizei stride);

    // GL 4.3 — buffer clear.
    bool clearBufferData(GLenum target, GLenum internalformat, GLenum format, GLenum type, const void* data);
    bool clearBufferSubData(GLenum target, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format, GLenum type, const void* data);

    // GL 4.3 — framebuffer parameters.
    bool framebufferParameteri(GLenum target, GLenum pname, GLint param);
    bool getFramebufferParameteriv(GLenum target, GLenum pname, GLint* params);

    // GL 4.3 — invalidation hints.
    bool invalidateFramebuffer(GLenum target, GLsizei numAttachments, const GLenum* attachments);
    bool invalidateSubFramebuffer(GLenum target, GLsizei numAttachments, const GLenum* attachments, GLint x, GLint y, GLsizei width, GLsizei height);
    bool invalidateBufferData(GLuint buffer);
    bool invalidateBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr length);

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
