#pragma once

#include <deque>
#include <memory>
#include <source_location>
#include <string>
#include <string_view>

#include "../../include/AppGL/glcorearb.h"

namespace appgl {

class GLCapabilities;
class GLObjectStore;
class GLStateTracker;
class MatrixStateMirror;

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
    void setPolygonMode(GLenum face, GLenum mode);
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
    bool queryIntegerIndexed(GLenum pname, GLuint index, GLint* data);
    bool queryInteger64Indexed(GLenum pname, GLuint index, GLint64* data);
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
    bool drawArraysInstanced(GLenum mode, GLint first, GLsizei count, GLsizei instancecount);
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

    // GL 4.3 — texture operations.
    bool copyImageSubData(GLuint srcName, GLenum srcTarget, GLint srcLevel, GLint srcX, GLint srcY, GLint srcZ,
                          GLuint dstName, GLenum dstTarget, GLint dstLevel, GLint dstX, GLint dstY, GLint dstZ,
                          GLsizei srcWidth, GLsizei srcHeight, GLsizei srcDepth);
    bool textureView(GLuint texture, GLenum target, GLuint origtexture, GLenum internalformat,
                     GLuint minlevel, GLuint numlevels, GLuint minlayer, GLuint numlayers);
    bool invalidateTexImage(GLuint texture, GLint level);
    bool invalidateTexSubImage(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
                               GLsizei width, GLsizei height, GLsizei depth);

    // GL 4.2 — transform feedback instanced draw.
    bool drawTransformFeedbackInstanced(GLenum mode, GLuint id, GLsizei instancecount);
    bool drawTransformFeedbackStreamInstanced(GLenum mode, GLuint id, GLuint stream, GLsizei instancecount);

    // GL 4.2/4.3 — internal format query.
    bool getInternalformativ(GLenum target, GLenum internalformat, GLenum pname, GLsizei count, GLint* params);
    bool getInternalformati64v(GLenum target, GLenum internalformat, GLenum pname, GLsizei count, GLint64* params);

    // GL 4.4 — immutable buffer storage.
    bool bufferStorage(GLenum target, GLsizeiptr size, const void* data, GLbitfield flags);
    // GL 4.4 — multi-bind.
    bool bindBuffersBase(GLenum target, GLuint first, GLsizei count, const GLuint* buffers);
    bool bindBuffersRange(GLenum target, GLuint first, GLsizei count, const GLuint* buffers,
                          const GLintptr* offsets, const GLsizeiptr* sizes);
    bool bindVertexBuffers(GLuint first, GLsizei count, const GLuint* buffers,
                           const GLintptr* offsets, const GLsizei* strides);
    bool bindTextures(GLuint first, GLsizei count, const GLuint* textures);
    bool bindSamplers(GLuint first, GLsizei count, const GLuint* samplers);
    bool bindImageTextures(GLuint first, GLsizei count, const GLuint* textures);
    // GL 4.4 — texture clear.
    bool clearTexImage(GLuint texture, GLint level, GLenum format, GLenum type, const void* data);
    bool clearTexSubImage(GLuint texture, GLint level,
                          GLint xoffset, GLint yoffset, GLint zoffset,
                          GLsizei width, GLsizei height, GLsizei depth,
                          GLenum format, GLenum type, const void* data);

    // GL 4.5 — DSA object creation.
    bool createBuffers(GLsizei n, GLuint* buffers);
    bool createTextures(GLenum target, GLsizei n, GLuint* textures);
    bool createSamplers(GLsizei n, GLuint* samplers);
    bool createFramebuffers(GLsizei n, GLuint* framebuffers);
    bool createRenderbuffers(GLsizei n, GLuint* renderbuffers);
    bool createVertexArrays(GLsizei n, GLuint* arrays);
    bool createTransformFeedbacks(GLsizei n, GLuint* ids);
    bool createProgramPipelines(GLsizei n, GLuint* pipelines);
    bool createQueries(GLenum target, GLsizei n, GLuint* ids);

    // GL 4.5 — DSA buffer operations.
    bool namedBufferStorage(GLuint buffer, GLsizeiptr size, const void* data, GLbitfield flags);
    bool namedBufferData(GLuint buffer, GLsizeiptr size, const void* data, GLenum usage);
    bool namedBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr size, const void* data);
    bool copyNamedBufferSubData(GLuint readBuffer, GLuint writeBuffer, GLintptr readOffset, GLintptr writeOffset, GLsizeiptr size);
    bool mapNamedBuffer(GLuint buffer, GLenum access, void** result);
    bool mapNamedBufferRange(GLuint buffer, GLintptr offset, GLsizeiptr length, GLbitfield access, void** result);
    bool unmapNamedBuffer(GLuint buffer, GLboolean* result);
    bool flushMappedNamedBufferRange(GLuint buffer, GLintptr offset, GLsizeiptr length);
    bool clearNamedBufferData(GLuint buffer, GLenum internalformat, GLenum format, GLenum type, const void* data);
    bool clearNamedBufferSubData(GLuint buffer, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format, GLenum type, const void* data);
    bool getNamedBufferParameteriv(GLuint buffer, GLenum pname, GLint* params);
    bool getNamedBufferParameteri64v(GLuint buffer, GLenum pname, GLint64* params);
    bool getNamedBufferPointerv(GLuint buffer, GLenum pname, void** params);
    bool getNamedBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr size, void* data);

    // GL 4.5 — DSA texture operations.
    bool textureStorage1D(GLuint texture, GLsizei levels, GLenum internalformat, GLsizei width);
    bool textureStorage2D(GLuint texture, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height);
    bool textureStorage3D(GLuint texture, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth);
    bool textureStorage2DMultisample(GLuint texture, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLboolean fixedsamplelocations);
    bool textureStorage3DMultisample(GLuint texture, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth, GLboolean fixedsamplelocations);
    bool textureSubImage1D(GLuint texture, GLint level, GLint xoffset, GLsizei width, GLenum format, GLenum type, const void* pixels);
    bool textureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const void* pixels);
    bool textureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, const void* pixels);
    bool textureBuffer(GLuint texture, GLenum internalformat, GLuint buffer);
    bool textureBufferRange(GLuint texture, GLenum internalformat, GLuint buffer, GLintptr offset, GLsizeiptr size);
    bool compressedTextureSubImage1D(GLuint texture, GLint level, GLint xoffset, GLsizei width, GLenum format, GLsizei imageSize, const void* data);
    bool compressedTextureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLsizei imageSize, const void* data);
    bool compressedTextureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLsizei imageSize, const void* data);
    bool copyTextureSubImage1D(GLuint texture, GLint level, GLint xoffset, GLint x, GLint y, GLsizei width);
    bool copyTextureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width, GLsizei height);
    bool copyTextureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLint x, GLint y, GLsizei width, GLsizei height);
    bool textureParameterf(GLuint texture, GLenum pname, GLfloat param);
    bool textureParameterfv(GLuint texture, GLenum pname, const GLfloat* param);
    bool textureParameteri(GLuint texture, GLenum pname, GLint param);
    bool textureParameteriv(GLuint texture, GLenum pname, const GLint* param);
    bool textureParameterIiv(GLuint texture, GLenum pname, const GLint* params);
    bool textureParameterIuiv(GLuint texture, GLenum pname, const GLuint* params);
    bool getTextureParameterfv(GLuint texture, GLenum pname, GLfloat* params);
    bool getTextureParameteriv(GLuint texture, GLenum pname, GLint* params);
    bool getTextureParameterIiv(GLuint texture, GLenum pname, GLint* params);
    bool getTextureParameterIuiv(GLuint texture, GLenum pname, GLuint* params);
    bool getTextureLevelParameterfv(GLuint texture, GLint level, GLenum pname, GLfloat* params);
    bool getTextureLevelParameteriv(GLuint texture, GLint level, GLenum pname, GLint* params);
    bool getTextureImage(GLuint texture, GLint level, GLenum format, GLenum type, GLsizei bufSize, void* pixels);
    bool getTextureSubImage(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
                            GLsizei width, GLsizei height, GLsizei depth,
                            GLenum format, GLenum type, GLsizei bufSize, void* pixels);
    bool getCompressedTextureImage(GLuint texture, GLint level, GLsizei bufSize, void* pixels);
    bool getCompressedTextureSubImage(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
                                      GLsizei width, GLsizei height, GLsizei depth,
                                      GLsizei bufSize, void* pixels);
    bool generateTextureMipmap(GLuint texture);
    bool bindTextureUnit(GLuint unit, GLuint texture);

    // GL 4.5 — DSA framebuffer operations.
    bool namedFramebufferRenderbuffer(GLuint framebuffer, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer);
    bool namedFramebufferTexture(GLuint framebuffer, GLenum attachment, GLuint texture, GLint level);
    bool namedFramebufferTextureLayer(GLuint framebuffer, GLenum attachment, GLuint texture, GLint level, GLint layer);
    bool namedFramebufferDrawBuffer(GLuint framebuffer, GLenum buf);
    bool namedFramebufferDrawBuffers(GLuint framebuffer, GLsizei n, const GLenum* bufs);
    bool namedFramebufferReadBuffer(GLuint framebuffer, GLenum src);
    bool namedFramebufferParameteri(GLuint framebuffer, GLenum pname, GLint param);
    bool getNamedFramebufferParameteriv(GLuint framebuffer, GLenum pname, GLint* param);
    bool getNamedFramebufferAttachmentParameteriv(GLuint framebuffer, GLenum attachment, GLenum pname, GLint* params);
    GLenum checkNamedFramebufferStatus(GLuint framebuffer, GLenum target);
    bool blitNamedFramebuffer(GLuint readFramebuffer, GLuint drawFramebuffer,
                              GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1,
                              GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1,
                              GLbitfield mask, GLenum filter);
    bool clearNamedFramebufferfv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLfloat* value);
    bool clearNamedFramebufferiv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLint* value);
    bool clearNamedFramebufferuiv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLuint* value);
    bool clearNamedFramebufferfi(GLuint framebuffer, GLenum buffer, GLint drawbuffer, GLfloat depth, GLint stencil);
    bool invalidateNamedFramebufferData(GLuint framebuffer, GLsizei numAttachments, const GLenum* attachments);
    bool invalidateNamedFramebufferSubData(GLuint framebuffer, GLsizei numAttachments, const GLenum* attachments,
                                            GLint x, GLint y, GLsizei width, GLsizei height);
    // GL 4.5 — DSA renderbuffer operations.
    bool namedRenderbufferStorage(GLuint renderbuffer, GLenum internalformat, GLsizei width, GLsizei height);
    bool namedRenderbufferStorageMultisample(GLuint renderbuffer, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height);
    bool getNamedRenderbufferParameteriv(GLuint renderbuffer, GLenum pname, GLint* params);
    // GL 4.5 — DSA vertex array operations.
    bool vertexArrayAttribFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLboolean normalized, GLuint relativeoffset);
    bool vertexArrayAttribIFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset);
    bool vertexArrayAttribLFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset);
    bool vertexArrayAttribBinding(GLuint vaobj, GLuint attribindex, GLuint bindingindex);
    bool vertexArrayBindingDivisor(GLuint vaobj, GLuint bindingindex, GLuint divisor);
    bool vertexArrayVertexBuffer(GLuint vaobj, GLuint bindingindex, GLuint buffer, GLintptr offset, GLsizei stride);
    bool vertexArrayVertexBuffers(GLuint vaobj, GLuint first, GLsizei count, const GLuint* buffers, const GLintptr* offsets, const GLsizei* strides);
    bool vertexArrayElementBuffer(GLuint vaobj, GLuint buffer);
    bool enableVertexArrayAttrib(GLuint vaobj, GLuint index);
    bool disableVertexArrayAttrib(GLuint vaobj, GLuint index);
    bool getVertexArrayiv(GLuint vaobj, GLenum pname, GLint* param);
    bool getVertexArrayIndexediv(GLuint vaobj, GLuint index, GLenum pname, GLint* param);
    bool getVertexArrayIndexed64iv(GLuint vaobj, GLuint index, GLenum pname, GLint64* param);
    // GL 4.5 — DSA transform feedback operations.
    bool transformFeedbackBufferBase(GLuint xfb, GLuint index, GLuint buffer);
    bool transformFeedbackBufferRange(GLuint xfb, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size);
    bool getTransformFeedbackiv(GLuint xfb, GLenum pname, GLint* param);
    bool getTransformFeedbacki_v(GLuint xfb, GLenum pname, GLuint index, GLint* param);
    bool getTransformFeedbacki64_v(GLuint xfb, GLenum pname, GLuint index, GLint64* param);

    // GL 4.5 — ClipControl, robustness, barriers, query buffer objects.
    bool clipControl(GLenum origin, GLenum depth);
    GLenum getGraphicsResetStatus();
    bool readnPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, GLsizei bufSize, void* data);
    bool getnUniformfv(GLuint program, GLint location, GLsizei bufSize, GLfloat* params);
    bool getnUniformiv(GLuint program, GLint location, GLsizei bufSize, GLint* params);
    bool getnUniformuiv(GLuint program, GLint location, GLsizei bufSize, GLuint* params);
    bool getnUniformdv(GLuint program, GLint location, GLsizei bufSize, GLdouble* params);
    bool getnTexImage(GLenum target, GLint level, GLenum format, GLenum type, GLsizei bufSize, void* pixels);
    bool getnCompressedTexImage(GLenum target, GLint lod, GLsizei bufSize, void* pixels);
    bool memoryBarrierByRegion(GLbitfield barriers);
    bool textureBarrier();
    bool getQueryBufferObjectiv(GLuint id, GLuint buffer, GLenum pname, GLintptr offset);
    bool getQueryBufferObjectuiv(GLuint id, GLuint buffer, GLenum pname, GLintptr offset);
    bool getQueryBufferObjecti64v(GLuint id, GLuint buffer, GLenum pname, GLintptr offset);
    bool getQueryBufferObjectui64v(GLuint id, GLuint buffer, GLenum pname, GLintptr offset);

    // GL 4.6 — Indirect count draws, SPIR-V specialization, polygon offset clamp.
    bool multiDrawArraysIndirectCount(GLenum mode, const void* indirect, GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride);
    bool multiDrawElementsIndirectCount(GLenum mode, GLenum type, const void* indirect, GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride);
    bool specializeShader(GLuint shader, const GLchar* pEntryPoint, GLuint numSpecializationConstants, const GLuint* pConstantIndex, const GLuint* pConstantValue);
    bool polygonOffsetClamp(GLfloat factor, GLfloat units, GLfloat clamp);

    // Push a GL error onto the context-level error queue (drained by
    // glGetError) and simultaneously mirror the record into the runtime
    // error ring buffer so external diagnostics tooling can see every
    // raised error — not just the ones that route through the runtime's
    // recordValidationError helper. functionName and message are
    // optional; when functionName is empty the ring-buffer record is
    // tagged as `<internal@<file>:<line>>` using std::source_location
    // captured at the call site, so external diagnostics tooling can
    // name the call site even when the deep GLContext.mm code path
    // doesn't supply its own function name (Phase 8X Group 4d follow-up
    // §3a — BAR identified the steady-state untagged GL_INVALID_ENUM
    // entries and asked for a file:line breadcrumb so they can be
    // diagnosed from the BAR side without source greps). Landing C 3g
    // wired the original cross-feed.
    void pushError(GLenum error,
                   std::string_view functionName = std::string_view{},
                   std::string_view message = std::string_view{},
                   std::source_location loc = std::source_location::current());
    GLenum popError();

    const GLubyte* getString(GLenum name);
    const std::string& rendererString() const;
    void setClaimedVersionString(std::string value);
    GLCapabilities& capabilities();
    GLObjectStore& objects();
    GLStateTracker& state();

    // Per-context fixed-function matrix mirror. Compat-profile entry
    // points (glMatrixMode / glLoadIdentity / glLoadMatrix* / glMult* /
    // glPushMatrix / glPopMatrix / glTranslate* / glRotate* / glScale*
    // / glOrtho / glFrustum) route through this mirror, and the draw
    // path reads from it to push synthesized `appgl_*` matrix uniforms
    // (created by the compat-shader rewriter) into the per-program
    // uniform value buffer at draw time.
    MatrixStateMirror& matrixState();
    const MatrixStateMirror& matrixState() const;

    // Benchmark instrumentation — pipeline cache metrics.
    struct PipelineCacheMetrics {
        std::uint64_t hits = 0;
        std::uint64_t misses = 0;
        double cumulativeBuildMillis = 0.0;
    };
    PipelineCacheMetrics pipelineCacheMetrics() const;
    void resetPipelineCacheMetrics();
    std::uint64_t metalAllocatedBytes() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace appgl
