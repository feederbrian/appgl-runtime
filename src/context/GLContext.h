#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <source_location>
#include <string>
#include <string_view>
#include <vector>

#include "../../include/AppGL/glcorearb.h"
#include "AppGLCommandReasons.h"
#include "MetalMemoryPressure.h"
#include "MetalResourceResidency.h"

namespace appgl {

class GLCapabilities;
class GLObjectStore;
class GLStateTracker;
class MatrixStateMirror;
struct GLProgramObject;
struct GLTextureObject;

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
    bool queryBooleanIndexed(GLenum target, GLuint index, GLboolean* data);

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
    void finish();
    void swapBuffers();
    AppGLCommandSubmissionDebugCounters commandSubmissionDebugCounters() const;
    bool readPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels);
    bool queryBoolean(GLenum pname, GLboolean* data);
    bool queryInteger(GLenum pname, GLint* data);
    bool queryInteger64(GLenum pname, GLint64* data);
    bool queryIntegerIndexed(GLenum pname, GLuint index, GLint* data);
    bool queryInteger64Indexed(GLenum pname, GLuint index, GLint64* data);
    bool queryFloat(GLenum pname, GLfloat* data);
    bool queryDouble(GLenum pname, GLdouble* data);
    bool getFragmentShadingRatesEXT(GLsizei samples, GLsizei maxCount, GLsizei* count, GLenum* shadingRates);
    bool shadingRateEXT(GLenum rate);
    bool shadingRateCombinerOpsEXT(GLenum combinerOp0, GLenum combinerOp1);
    bool framebufferShadingRateEXT(GLenum target,
                                   GLenum attachment,
                                   GLuint texture,
                                   GLint baseLayer,
                                   GLsizei numLayers,
                                   GLsizei texelWidth,
                                   GLsizei texelHeight);
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
    bool setVertexAttribImmediate(GLuint index, GLint count, const GLdouble* values);
    bool setVertexAttribIImmediate(GLuint index, const GLint* values, bool isUnsigned);
    bool setVertexAttribLImmediate(GLuint index, GLint count, const GLdouble* values);
    bool getVertexAttribLdv(GLuint index, GLenum pname, GLdouble* params);
    bool activeTexture(GLenum texture);
    bool genTextures(GLsizei count, GLuint* textures);
    bool deleteTextures(GLsizei count, const GLuint* textures);
    bool isTexture(GLuint texture) const;
    bool bindTexture(GLenum target, GLuint texture);
    bool texImage(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLsizei depth, GLint border, GLenum format, GLenum type, const void* pixels);
    bool copyTexImage2D(GLenum target, GLint level, GLenum internalformat, GLint x, GLint y, GLsizei width, GLsizei height, GLint border);
    bool texSubImage(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, const void* pixels);
    // Sprint 17 Day 7+ Bank-Group-E: compressed texture upload.
    // Allocates a Metal texture with the matching MTLPixelFormat (per
    // GLCapabilities format table) and uploads the user payload via
    // replaceRegion with compressed-block pixel-store layout.
    bool compressedTexImage(GLenum target, GLint level, GLenum internalformat,
                            GLsizei width, GLsizei height, GLsizei depth,
                            GLsizei imageSize, const void* data);
    bool texParameterInteger(GLenum target, GLenum pname, const GLint* params);
    bool texParameterUnsignedInteger(GLenum target, GLenum pname, const GLuint* params);
    bool texParameterFloat(GLenum target, GLenum pname, const GLfloat* params);
    bool getTexParameterInteger(GLenum target, GLenum pname, GLint* params);
    bool getTexParameterUnsignedInteger(GLenum target, GLenum pname, GLuint* params);
    bool getTexParameterFloat(GLenum target, GLenum pname, GLfloat* params);
    bool generateMipmap(GLenum target);
    bool texStorage(GLenum target, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth);
    bool texStorageMultisample(GLenum target, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth, GLboolean fixedsamplelocations);
    bool texPageCommitment(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLboolean commit);
    bool texturePageCommitment(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLboolean commit);
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
    bool framebufferTextureMultiviewOVR(GLenum target, GLenum attachment, GLuint texture, GLint level, GLint baseViewIndex, GLsizei numViews);
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
    void finalizeDeletedProgramIfUnused(GLuint program);
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
    bool drawArrays(GLenum mode, GLint first, GLsizei count, GLuint drawID = 0);
    bool drawArraysInstanced(GLenum mode, GLint first, GLsizei count, GLsizei instancecount, GLuint baseinstance = 0, GLuint drawID = 0);
    bool drawElements(GLenum mode, GLsizei count, GLenum type, const void* indices, GLuint drawID = 0);

    // GL 3.2 — base-vertex indexed drawing (ARB_draw_elements_base_vertex).
    bool drawElementsBaseVertex(GLenum mode, GLsizei count, GLenum type, const void* indices, GLint basevertex, GLuint drawID = 0);
    bool drawRangeElementsBaseVertex(GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type, const void* indices, GLint basevertex);
    bool drawElementsInstancedBaseVertex(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLint basevertex, GLuint baseinstance = 0, GLuint drawID = 0);
    bool multiDrawArrays(GLenum mode, const GLint* first, const GLsizei* count, GLsizei drawcount);
    bool multiDrawElements(GLenum mode, const GLsizei* count, GLenum type, const void* const* indices, GLsizei drawcount);
    bool multiDrawElementsBaseVertex(GLenum mode, const GLsizei* count, GLenum type, const void* const* indices, GLsizei drawcount, const GLint* basevertex);

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
    bool drawArraysInstancedBaseInstance(GLenum mode, GLint first, GLsizei count, GLsizei instancecount, GLuint baseinstance, GLuint drawID = 0);
    bool drawElementsInstancedBaseInstance(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLuint baseinstance, GLuint drawID = 0);
    bool drawElementsInstancedBaseVertexBaseInstance(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLint basevertex, GLuint baseinstance, GLuint drawID = 0);

    // GL 4.0/4.3 — indirect draw helpers.
    // Reads `size` bytes from the bound GL_DRAW_INDIRECT_BUFFER at byte offset
    // `indirect`, or from the client pointer if no buffer is bound.  Returns
    // false and pushes GL_INVALID_OPERATION on out-of-bounds reads.
    bool readIndirectBuffer(GLenum target, const void* indirect, std::size_t size, void* out);

    // Query the currently-bound vertex array object name (for validation).
    GLuint getBoundVertexArray() const;

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

    // GL 4.0/4.2 — transform feedback draw.
    bool drawTransformFeedback(GLenum mode, GLuint id);
    bool drawTransformFeedbackStream(GLenum mode, GLuint id, GLuint stream);
    bool drawTransformFeedbackInstanced(GLenum mode, GLuint id, GLsizei instancecount);
    bool drawTransformFeedbackStreamInstanced(GLenum mode, GLuint id, GLuint stream, GLsizei instancecount);

    // GL 4.2/4.3 — internal format query.
    bool getInternalformativ(GLenum target, GLenum internalformat, GLenum pname, GLsizei count, GLint* params);
    bool getInternalformati64v(GLenum target, GLenum internalformat, GLenum pname, GLsizei count, GLint64* params);

    // GL 4.4 — immutable buffer storage.
    bool bufferStorage(GLenum target, GLsizeiptr size, const void* data, GLbitfield flags);
    bool bufferPageCommitment(GLenum target, GLintptr offset, GLsizeiptr size, GLboolean commit);
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
    bool deleteProgramPipelines(GLsizei n, const GLuint* pipelines);
    bool createQueries(GLenum target, GLsizei n, GLuint* ids);

    // GL 4.5 — DSA buffer operations.
    bool namedBufferStorage(GLuint buffer, GLsizeiptr size, const void* data, GLbitfield flags);
    bool namedBufferPageCommitment(GLuint buffer, GLintptr offset, GLsizeiptr size, GLboolean commit);
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
    // Bank-Group-F shared helper: blit from current READ_FRAMEBUFFER's
    // attachment named by `srcReadBuffer` into the destination texture.
    // For 3D destinations, `zoffset` selects the destination layer.
    bool blitReadFBOToTextureSubImage(GLuint dstTextureName, GLint level,
                                      GLint xoffset, GLint yoffset, GLint zoffset,
                                      GLint x, GLint y, GLsizei width, GLsizei height,
                                      GLenum srcReadBuffer);
    // Shared GL 4.6 §8.6 validation for the three copyTextureSubImage
    // variants (effective-target check, level ≥ 0, offset/size ≥ 0,
    // bounds). `dim` ∈ {1, 2, 3} selects the per-variant constraints.
    bool validateCopyTextureSubImage(
        GLuint texture, int dim, GLint level,
        GLint xoffset, GLint yoffset, GLint zoffset,
        GLsizei width, GLsizei height);
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
    bool getTextureLevelParameteriv(GLuint texture, GLint level, GLenum pname, GLint* params,
                                    GLenum requestTarget = 0);
    bool getTextureImage(GLuint texture, GLint level, GLenum format,
                         GLenum type, GLsizei bufSize, void* pixels,
                         GLenum requestTarget = 0);
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
    bool namedFramebufferTextureMultiviewOVR(GLuint framebuffer, GLenum attachment, GLuint texture, GLint level, GLint baseViewIndex, GLsizei numViews);
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
    // Shared validator for the four glGetQueryBufferObject* entry points —
    // enforces GL 4.5 §4.2 query-buffer-read error ordering (id-valid,
    // not-active, pname in accepted set, offset in-range and aligned).
    bool validateQueryBufferObjectGet(
        GLuint id, GLuint buffer, GLenum pname, GLintptr offset,
        std::size_t resultBytes);
    // Shared writer for the four flavors — resolves the query and buffer
    // after validation, extracts the pname-specific GLuint64 result, and
    // stores it at `offset` as T (GLint/GLuint/GLint64/GLuint64). Defined
    // in GLContext.mm (only instantiated from the four entry points
    // below, which are themselves defined in that TU).
    template <typename T>
    bool writeQueryBufferObject(GLuint id, GLuint buffer, GLenum pname, GLintptr offset);

    // GL 3.0 / GL 4.5 ARB_conditional_render_inverted — begin/end a
    // conditional draw block keyed on an occlusion query result. mode is
    // one of GL_QUERY_{WAIT,NO_WAIT,BY_REGION_WAIT,BY_REGION_NO_WAIT}
    // and the _INVERTED variants. While active, the draw path
    // consults the bound query and skips draws whose predicate matches.
    bool beginConditionalRender(GLuint id, GLenum mode);
    void endConditionalRender();

    // GL 4.6 — Indirect count draws, SPIR-V specialization, polygon offset clamp.
    bool multiDrawArraysIndirectCount(GLenum mode, const void* indirect, GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride);
    bool multiDrawElementsIndirectCount(GLenum mode, GLenum type, const void* indirect, GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride);
    // Common validation for the two IndirectCount entries — checks
    // drawcount alignment, PARAMETER_BUFFER binding, and buffer-size
    // bounds. Returns false (with pushError) on any violation.
    bool validateIndirectCount(GLintptr drawcount, GLsizei maxdrawcount);
    bool resolveIndirectDrawCount(
        GLintptr drawcount, GLsizei maxdrawcount, GLsizei& actualDrawcount);
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
    bool claimedVersionStringSeeded() const;
    GLCapabilities& capabilities();
    const GLCapabilities& capabilities() const;
    GLObjectStore& objects();
    const GLObjectStore& objects() const;
    GLStateTracker& state();
    const GLStateTracker& state() const;
    void noteQueryBegan(GLenum target);
    void noteQueryEnded(GLenum target);

    // Decision H4 extension facade: ExtensionContext exposes these instead
    // of letting modules reach through GLContext internals directly.
    void* extensionMetalDevice() const;
    void* extensionMetalCommandQueue() const;
    void* extensionMetalCommandSubmission() const;
    GLTextureObject* extensionCurrentTexture(GLenum target);
    bool extensionReplaceMetalTexture(GLTextureObject& texture, GLuint textureName = 0);

    // Per-context fixed-function matrix mirror. Compat-profile entry
    // points (glMatrixMode / glLoadIdentity / glLoadMatrix* / glMult* /
    // glPushMatrix / glPopMatrix / glTranslate* / glRotate* / glScale*
    // / glOrtho / glFrustum) route through this mirror, and the draw
    // path reads from it to push synthesized `appgl_*` matrix uniforms
    // (created by the compat-shader rewriter) into the per-program
    // uniform value buffer at draw time.
    MatrixStateMirror& matrixState();
    const MatrixStateMirror& matrixState() const;

    // Compat-profile immediate-mode geometry capture.
    //
    // Phase 8X Group 4d follow-up¹⁷ — Chobby's Chili UI draws every
    // panel, border and button through OpenGL 1.x immediate mode
    // (`glBegin` / `glVertex*` / `glColor*` / `glTexCoord*` /
    // `glMultiTexCoord*` / `glEnd`), which the core profile stubs as
    // error pushes. The hand-written compat entry points in
    // `AppGLImmediateMode.cpp` route into these five methods. They
    // implement a small capture state machine: `beginImmediate` starts
    // a batch in `GL_TRIANGLES` / `GL_TRIANGLE_STRIP` / `GL_TRIANGLE_FAN`
    // / `GL_QUADS` / `GL_LINES` / `GL_LINE_STRIP` / `GL_LINE_LOOP`;
    // `immediateColor` and `immediateTexCoord` update per-vertex
    // registers without emitting anything; `immediateVertex` pushes one
    // `{pos,color,texcoord}` tuple onto the capture buffer; `endImmediate`
    // expands `GL_QUADS` to triangles CPU-side (core Metal has no quads),
    // uploads the vertex data into the frame-graph's triple-buffered
    // ring, resolves the active texture (if any) on unit 0 for the
    // textured-or-untextured pipeline choice, and dispatches
    // `encodeImmediateModeDraw`. The mode and the captured state are all
    // read from the matrix mirror (MVP = proj · modelview) so no
    // synthesized uniforms are needed.
    void beginImmediate(GLenum mode);
    void immediateVertex(float x, float y, float z, float w);
    void immediateColor(float r, float g, float b, float a);
    void immediateTexCoord(unsigned int unit, float s, float t, float r, float q);
    void endImmediate();

    // Benchmark instrumentation — pipeline cache metrics.
    //
    // Phase 8X Group 4d follow-up⁴ — `buildAttempts` and `buildFailures`
    // are surfaced alongside `hits`/`misses` so BAR-side tooling can
    // disambiguate {hits:0,misses:0} between "translated path never
    // reached encodeTranslatedDraw's build branch" (attempts==0) and
    // "build branch ran every time and Metal rejected the result every
    // time" (attempts>0, failures==attempts). Invariant after every draw:
    // buildAttempts == misses + buildFailures.
    struct PipelineCacheMetrics {
        std::uint64_t hits = 0;
        std::uint64_t misses = 0;
        std::uint64_t buildAttempts = 0;
        std::uint64_t buildFailures = 0;
        double cumulativeBuildMillis = 0.0;
    };
    PipelineCacheMetrics pipelineCacheMetrics() const;
    void resetPipelineCacheMetrics();
    std::uint64_t metalAllocatedBytes() const;

    struct MetalResourceInventory {
        struct TextureShadowHotspot {
            GLuint name = 0;
            GLenum target = 0;
            GLuint viewSourceTexture = 0;
            std::uint64_t shadowBytes = 0;
            std::uint64_t rgba8Bytes = 0;
            std::uint64_t nativeBytes = 0;
            std::uint64_t metalBytes = 0;
            std::uint64_t swizzledViewBytes = 0;
            std::uint64_t samplingProxyBytes = 0;
            std::uint64_t imageLevels = 0;
            std::uint64_t shadowImages = 0;
            std::uint64_t definedImages = 0;
            std::uint64_t cubeFaceImages = 0;
            std::uint64_t largestImageBytes = 0;
            GLint minLevel = 0;
            GLint maxLevel = 0;
            GLint largestLevel = 0;
            GLenum internalFormat = 0;
            GLenum sourceFormat = 0;
            GLenum sourceType = 0;
            GLsizei width = 0;
            GLsizei height = 0;
            GLsizei depth = 0;
            GLsizei layers = 0;
            GLsizei samples = 0;
            std::uint64_t producerPendingBits = 0;
            std::uint8_t instantiated = 0;
            std::uint8_t hasMetalTexture = 0;
            std::uint8_t hasSwizzledView = 0;
            std::uint8_t hasSamplingProxy = 0;
            std::uint8_t wasViewportRenderedTo = 0;
            std::uint8_t wasFramebufferRenderedTo = 0;
            std::uint8_t colorShadowAuthoritative = 0;
            std::uint8_t depthStencilShadowAuthoritative = 0;
            std::uint8_t sparseTexture = 0;
        };

        struct MallocZoneSummary {
            std::string name;
            std::uint64_t bytesInUse = 0;
            std::uint64_t blocksInUse = 0;
            std::uint64_t maxBytesInUse = 0;
            std::uint64_t allocatedBytes = 0;
            std::uint64_t isDefaultZone = 0;
        };

        struct RenderPsoProgramHotspot {
            GLuint program = 0;
            std::uint64_t renderPsoLive = 0;
            std::uint64_t renderPsoHighWater = 0;
            std::uint64_t renderPsoHits = 0;
            std::uint64_t renderPsoMisses = 0;
            std::uint64_t renderPsoEvictions = 0;
            std::uint64_t renderPsoGlobalEvictions = 0;
            std::uint64_t renderPsoLastUseMin = 0;
            std::uint64_t renderPsoLastUseMax = 0;
            std::uint64_t renderPsoScalarMirrorPresent = 0;
            std::uint64_t gsPassThroughPsoLive = 0;
            std::uint64_t gsPassThroughPsoHighWater = 0;
            std::uint64_t gsPassThroughPsoHits = 0;
            std::uint64_t gsPassThroughPsoMisses = 0;
            std::uint64_t gsPassThroughPsoEvictions = 0;
            std::uint64_t gsPassThroughPsoGlobalEvictions = 0;
            std::uint64_t gsPassThroughPsoLastUseMin = 0;
            std::uint64_t gsPassThroughPsoLastUseMax = 0;
            std::uint64_t gsPassThroughPsoScalarMirrorPresent = 0;
            std::string vertexSourceHash;
            std::string fragmentSourceHash;
        };

        struct Depth32FReadbackDiagnostics {
            std::uint64_t readbackCalls = 0;
            std::uint64_t readbackDepth32FCalls = 0;
            std::uint64_t readbackDepth32FS8Calls = 0;
            std::uint64_t readbackRawBytes = 0;
            std::uint64_t readbackRawMaxBytes = 0;
            std::uint64_t readbackStagingCalls = 0;
            std::uint64_t readbackStagingBytes = 0;
            std::uint64_t readbackStagingMaxBytes = 0;
            std::uint64_t readbackConsumerSyncCalls = 0;
            std::uint64_t readbackConsumerRgba8SubImageCalls = 0;
            std::uint64_t readbackConsumerAttachmentCalls = 0;
            std::uint64_t readbackConsumerOtherCalls = 0;
            std::uint64_t syncCalls = 0;
            std::uint64_t syncSuccesses = 0;
            std::uint64_t syncFailures = 0;
            std::uint64_t syncNativeBytes = 0;
            std::uint64_t syncNativeMaxBytes = 0;
            std::uint64_t syncDepthValueBytes = 0;
            std::uint64_t syncDepthValueMaxBytes = 0;
            std::uint64_t syncSlices = 0;
            std::uint64_t rgba8SubImageCalls = 0;
            std::uint64_t rgba8SubImageSuccesses = 0;
            std::uint64_t rgba8SubImageFailures = 0;
            std::uint64_t rgba8SubImageOutputBytes = 0;
            std::uint64_t rgba8SubImageDepthValueBytes = 0;
            std::uint64_t rgba8SubImageSlices = 0;
        };

        std::uint64_t deviceAllocatedBytes = 0;
        std::uint64_t bufferCount = 0;
        std::uint64_t bufferBytes = 0;
        std::uint64_t textureCount = 0;
        std::uint64_t textureBytes = 0;
        std::uint64_t genericTextureCount = 0;
        std::uint64_t genericTextureBytes = 0;
        std::uint64_t renderbufferTextureCount = 0;
        std::uint64_t renderbufferTextureBytes = 0;
        std::uint64_t textureViewCount = 0;
        std::uint64_t textureViewBytes = 0;
        std::uint64_t samplerCount = 0;
        std::uint64_t bufferStorageObjects = 0;
        std::uint64_t bufferMetalObjects = 0;
        std::uint64_t bufferReservedOnlyObjects = 0;
        std::uint64_t textureInstantiatedObjects = 0;
        std::uint64_t textureDefinedObjects = 0;
        std::uint64_t textureViewObjects = 0;
        std::uint64_t textureSparseObjects = 0;
        std::uint64_t textureReservedOnlyObjects = 0;
        std::uint64_t renderPipelineCount = 0;
        std::uint64_t computePipelineCount = 0;
        std::uint64_t functionCount = 0;
        std::uint64_t libraryCacheEntries = 0;
        std::uint64_t genericTextureLevelImages = 0;
        std::uint64_t genericTextureLevelBytes = 0;
        std::uint64_t cubeFaceLevelImages = 0;
        std::uint64_t cubeFaceLevelBytes = 0;
        std::uint64_t expandedIndexBuffers = 0;
        std::uint64_t expandedIndexBytes = 0;
        std::uint64_t fp64SidecarBuffers = 0;
        std::uint64_t fp64Sidecars = 0;
        std::uint64_t fp64SidecarCpuBytes = 0;
        std::uint64_t fp64SidecarMetalBuffers = 0;
        std::uint64_t fp64SidecarMetalBufferBytes = 0;
        std::uint64_t fp64SidecarMaxGeneration = 0;
        std::uint64_t textureBufferExpansionMetalBuffers = 0;
        std::uint64_t textureBufferExpansionMetalBufferBytes = 0;
        std::uint64_t imageAtomicSidecars = 0;
        std::uint64_t imageAtomicSidecarBytes = 0;
        std::uint64_t imageAtomicDirtySidecars = 0;
        std::uint64_t imageAtomicSidecarMetalBuffers = 0;
        std::uint64_t imageAtomicSidecarMetalBufferBytes = 0;
        std::uint64_t sparseBufferObjects = 0;
        std::uint64_t sparseBufferPageTableBytes = 0;
        std::uint64_t sparseBufferCommittedPages = 0;
        std::uint64_t sparseBufferCommittedBytes = 0;
        std::uint64_t sparseTextureStates = 0;
        std::uint64_t sparseTextureHeaps = 0;
        std::uint64_t sparseTextureHeapBytes = 0;
        std::uint64_t sparseTextureCommittedRegions = 0;
        std::uint64_t sparseStorageImageSidecars = 0;
        std::uint64_t sparseStorageImageSidecarBytes = 0;
        std::uint64_t multisampleStorageImageSidecars = 0;
        std::uint64_t multisampleStorageImageSidecarBytes = 0;
        std::uint64_t frameGraphBufferCount = 0;
        std::uint64_t frameGraphBufferBytes = 0;
        std::uint64_t frameGraphTextureCount = 0;
        std::uint64_t frameGraphTextureBytes = 0;
        std::uint64_t frameGraphDrawableCount = 0;
        std::uint64_t frameGraphDrawableTextureBytes = 0;
        std::uint64_t frameGraphDrawableAcquireCalls = 0;
        std::uint64_t frameGraphDrawableAcquireHits = 0;
        std::uint64_t frameGraphDrawableAcquireSuccesses = 0;
        std::uint64_t frameGraphDrawableAcquireFailures = 0;
        std::uint64_t frameGraphDrawablePresentCalls = 0;
        std::uint64_t frameGraphPresentCalls = 0;
        std::uint64_t prepMemoHits = 0;
        std::uint64_t prepMemoPlanKeyReuses = 0;
        std::array<std::uint64_t, 6> prepMemoBustsByDomain{};
        // C52 value-gating: raw per-domain state generations (indices match
        // GLStateTracker::StateDomain). Observation-only — lets probes assert
        // that value-identical mutator calls do NOT advance a domain.
        std::array<std::uint64_t, 6> stateDomainGenerations{};
        // C52 flicker fix: count of in-place texture uploads that were
        // hazard-routed as ordered in-CB blits (open command buffer had
        // draws sampling the destination texture).
        std::uint64_t orderedTextureUploads = 0;
        // C52 sampler-resolve cache (APPGL_ENABLE_SAMPLER_RESOLVE_CACHE).
        std::uint64_t samplerResolveCacheHits = 0;
        std::uint64_t samplerResolveCacheMisses = 0;
        std::uint64_t samplerResolveCacheBusts = 0;
        std::uint64_t samplerResolveCacheBypasses = 0;
        std::uint64_t prepMemoMisses = 0;
        std::uint64_t prepMemoBusts = 0;
        std::uint64_t shadowClearsDeferred = 0;
        std::uint64_t shadowClearsCoalesced = 0;
        std::uint64_t shadowClearsMaterialized = 0;
        std::uint64_t shadowClearMaterializeBytes = 0;
        std::uint64_t bufferRenames = 0;
        std::uint64_t bufferRenameBytes = 0;
        std::uint64_t bufferRenameSkips = 0;
        std::uint64_t bufferRenameKeepalives = 0;
        std::uint64_t bufferBoundaryFlushesForced = 0;
        std::uint64_t bufferBoundaryFlushesNarrowed = 0;
        std::uint64_t frameGraphFboClearsDeferred = 0;
        std::uint64_t frameGraphFboClearsFolded = 0;
        std::uint64_t frameGraphFboClearsMaterialized = 0;
        std::uint64_t frameGraphFboClearsCoalesced = 0;
        std::uint64_t frameGraphEncoderOpensFboDraw = 0;
        std::uint64_t frameGraphEncoderOpensDefaultFb = 0;
        std::uint64_t frameGraphEncoderClosesFboTargetChange = 0;
        std::uint64_t frameGraphEncoderClosesShadingRateChange = 0;
        std::uint64_t frameGraphEncoderClosesViewportRequestInvalidate = 0;
        std::uint64_t frameGraphEncoderClosesReadback = 0;
        std::uint64_t frameGraphEncoderClosesCommandBufferCommit = 0;
        std::uint64_t frameGraphEncoderClosesClear = 0;
        std::uint64_t frameGraphEncoderClosesFboDrawTail = 0;
        std::uint64_t frameGraphTranslatedDrawEncodeCalls = 0;
        std::uint64_t frameGraphPassDescriptorBuilds = 0;
        std::uint64_t frameGraphPassDescriptorBuildUsTotal = 0;
        std::uint64_t frameGraphFboPassContinuations = 0;
        std::uint64_t frameGraphFboPassSignatureMisses = 0;
        std::uint64_t frameGraphPresentFromFlushCalls = 0;
        std::uint64_t frameGraphPresentFromSwapBuffersCalls = 0;
        std::uint64_t frameGraphPresentInternalCalls = 0;
        std::uint64_t frameGraphPresentPendingTrueCalls = 0;
        std::uint64_t frameGraphPresentPendingFalseCalls = 0;
        std::uint64_t frameGraphPresentCommandBufferPresentCalls = 0;
        std::uint64_t frameGraphPresentCommandBufferNilCalls = 0;
        std::uint64_t frameGraphCommandBuffersCommitted = 0;
        std::uint64_t frameGraphPresentNoWorkReturns = 0;
        std::uint64_t frameGraphPresentCommitAttempts = 0;
        std::uint64_t frameGraphPresentCommitSuccesses = 0;
        std::uint64_t frameGraphPresentCommitFailures = 0;
        std::uint64_t frameGraphDrawableNilAfterPresent = 0;
        std::uint64_t frameGraphDrawableResizeCalls = 0;
        std::uint64_t frameGraphDrawableResizeNoops = 0;
        std::uint64_t frameGraphDrawableResizeGrowOnlySkips = 0;
        std::uint64_t frameGraphDrawableResizeDepthTextureReleases = 0;
        std::uint64_t frameGraphDrawableResizeOffscreenTextureReleases = 0;
        std::uint64_t frameGraphDrawableResizeLastRequestedWidth = 0;
        std::uint64_t frameGraphDrawableResizeLastRequestedHeight = 0;
        std::uint64_t frameGraphDrawableResizeLastEffectiveWidth = 0;
        std::uint64_t frameGraphDrawableResizeLastEffectiveHeight = 0;
        std::uint64_t frameGraphDrawableRetainCalls = 0;
        std::uint64_t frameGraphDrawableReleaseCalls = 0;
        std::uint64_t frameGraphDrawableLiveRetains = 0;
        std::uint64_t frameGraphDrawablePeakLiveRetains = 0;
        std::uint64_t frameGraphRenderEncoderOpenCalls = 0;
        std::uint64_t frameGraphRenderEncoderReleaseCalls = 0;
        std::uint64_t frameGraphRenderEncoderLiveRetains = 0;
        std::uint64_t frameGraphRenderEncoderPeakLiveRetains = 0;
        std::uint64_t frameGraphCurrentDrawablePresent = 0;
        std::uint64_t frameGraphCurrentDrawableTextureBytes = 0;
        std::uint64_t frameGraphCurrentDrawableWidth = 0;
        std::uint64_t frameGraphCurrentDrawableHeight = 0;
        std::uint64_t frameGraphCurrentDrawablePixelFormat = 0;
        std::uint64_t frameGraphCurrentDrawableStorageMode = 0;
        std::uint64_t frameGraphCurrentDrawableUsage = 0;
        std::uint64_t frameGraphCurrentDrawableSampleCount = 0;
        std::uint64_t frameGraphObservedDrawableTextures = 0;
        std::uint64_t frameGraphObservedDrawableTexturePeak = 0;
        std::uint64_t frameGraphObservedDrawableTextureBytes = 0;
        std::uint64_t frameGraphObservedDrawableTextureBytesPeak = 0;
        std::uint64_t frameGraphObservedDrawableTextureLimit = 0;
        std::uint64_t frameGraphObservedDrawableTextureTruncated = 0;
        std::uint64_t frameGraphLayerDrawableWidth = 0;
        std::uint64_t frameGraphLayerDrawableHeight = 0;
        std::uint64_t frameGraphLayerPixelFormat = 0;
        std::uint64_t frameGraphLayerFramebufferOnly = 0;
        std::uint64_t frameGraphLayerMaximumDrawableCount = 0;
        std::uint64_t frameGraphLayerMaximumDrawableCountAvailable = 0;
        std::uint64_t frameGraphLayerDisplaySyncEnabled = 0;
        std::uint64_t frameGraphLayerDisplaySyncEnabledAvailable = 0;
        std::uint64_t frameGraphDepthStencilTextureBytes = 0;
        std::uint64_t frameGraphDepthStencilTextureWidth = 0;
        std::uint64_t frameGraphDepthStencilTextureHeight = 0;
        std::uint64_t frameGraphDepthStencilTextureSampleCount = 0;
        std::uint64_t frameGraphDepthStencilTexturePixelFormat = 0;
        std::uint64_t frameGraphDepthStencilRebuilds = 0;
        std::uint64_t frameGraphDepthStencilReleases = 0;
        std::uint64_t frameGraphDepthStencilAllocatedBytes = 0;
        std::uint64_t frameGraphDepthStencilRebuildsFromEnsure = 0;
        std::uint64_t frameGraphDepthStencilRebuildsFromColorSizeMismatch = 0;
        std::uint64_t frameGraphDepthStencilRebuildsFromSampleMismatch = 0;
        std::uint64_t frameGraphOffscreenColorTextureBytes = 0;
        std::uint64_t frameGraphOffscreenColorTextureWidth = 0;
        std::uint64_t frameGraphOffscreenColorTextureHeight = 0;
        std::uint64_t frameGraphOffscreenColorTextureSampleCount = 0;
        std::uint64_t frameGraphOffscreenColorTexturePixelFormat = 0;
        std::uint64_t frameGraphOffscreenColorRebuilds = 0;
        std::uint64_t frameGraphOffscreenColorReleases = 0;
        std::uint64_t frameGraphOffscreenColorAllocatedBytes = 0;
        std::uint64_t frameGraphDummyColorTextureAllocations = 0;
        std::uint64_t frameGraphDummyColorTextureAllocatedBytes = 0;
        std::uint64_t frameGraphDummyColorTextureCacheHits = 0;
        std::uint64_t frameGraphDummyColorTextureCacheTextures = 0;
        std::uint64_t frameGraphDummyColorTextureCacheBytes = 0;
        std::uint64_t frameGraphSamplerCount = 0;
        std::uint64_t frameGraphRenderPipelineCount = 0;
        std::uint64_t frameGraphComputePipelineCount = 0;
        std::uint64_t frameGraphFunctionCount = 0;
        std::uint64_t frameGraphLibraryCount = 0;
        std::uint64_t frameGraphDepthStencilStateCount = 0;
        std::uint64_t frameGraphBinaryArchiveCount = 0;
        std::uint64_t frameGraphRingBufferCount = 0;
        std::uint64_t frameGraphRingBufferBytes = 0;
        std::uint64_t frameGraphRingFallbackAllocations = 0;
        std::uint64_t frameGraphRingFallbackBytes = 0;
        std::uint64_t frameGraphRingFallbackMaxBytes = 0;
        std::uint64_t cacheLimitMslLibraryEntries = 0;
        std::uint64_t cacheLimitTranslatedDrawPlans = 0;
        std::uint64_t cacheLimitTranslatedDrawMSLSlots = 0;
        std::uint64_t cacheLimitTranslatedSampleMaskSlots = 0;
        std::uint64_t cacheLimitRenderPsoTotal = 0;
        std::uint64_t cacheLimitRenderPsoPerProgram = 0;
        std::uint64_t cacheLimitGsPassThroughPsoPerProgram = 0;
        std::uint64_t cacheLimitTessVertexComputePsoPerProgram = 0;
        std::uint64_t cacheLimitVsTfComputePsoPerProgram = 0;
        std::uint64_t cacheLimitGsVsComputePsoPerProgram = 0;
        std::uint64_t cacheEvictionsMslLibraries = 0;
        std::uint64_t cacheEvictionsTranslatedDrawMSLSlots = 0;
        std::uint64_t cacheEvictionsTranslatedSampleMaskSlots = 0;
        std::uint64_t cacheEvictionsRenderPsoGlobal = 0;
        std::uint64_t cacheEvictionsRenderPso = 0;
        std::uint64_t cacheEvictionsGsPassThroughPso = 0;
        std::uint64_t cacheEvictionsTessVertexComputePso = 0;
        std::uint64_t cacheEvictionsVsTfComputePso = 0;
        std::uint64_t cacheEvictionsGsVsComputePso = 0;
        std::uint64_t mslLibraryCacheSourceBytes = 0;
        std::uint64_t mslLibraryCacheSourceKeyBytes = 0;
        std::uint64_t mslLibraryCompileTransientSourceBytes = 0;
        std::uint64_t mslLibraryCacheHits = 0;
        std::uint64_t mslLibraryCacheMisses = 0;
        std::uint64_t mslLibrarySourceNSStringCreations = 0;
        std::uint64_t cacheLiveMslLibraries = 0;
        std::uint64_t cacheLiveTranslatedDrawMSLSlots = 0;
        std::uint64_t cacheLiveTranslatedSampleMaskSlots = 0;
        std::uint64_t cacheLiveTranslatedDrawPlans = 0;
        std::uint64_t cacheLiveTranslatedDrawPlanBuckets = 0;
        std::uint64_t cacheLiveTranslatedDrawPlanApproxBytes = 0;
        std::uint64_t cacheLiveRenderPsoTotal = 0;
        std::uint64_t cacheHighWaterRenderPsoTotal = 0;
        std::uint64_t cacheLiveRenderPso = 0;
        std::uint64_t cacheLiveGsPassThroughPso = 0;
        std::uint64_t cacheLiveTessVertexComputePso = 0;
        std::uint64_t cacheLiveVsTfComputePso = 0;
        std::uint64_t cacheLiveGsVsComputePso = 0;
        std::uint64_t renderPsoProgramHotspotLimit = 0;
        std::uint64_t renderPsoProgramHotspotRows = 0;
        std::uint64_t renderPsoProgramHotspotsTruncated = 0;
        MetalMemoryPressureInputs pressure;
        AppGLCommandSubmissionDebugCounters commandBuffers;
        // S25 Rung-1 pacing instruments (probe-facing subset; the full
        // per-ms histogram and per-reason boundary maps ride only the
        // periodic diagnostics JSONL).
        std::uint64_t pacingFrames = 0;
        double pacingFrameTimeUsTotal = 0.0;
        double pacingFrameTimeUsSquaredTotal = 0.0;
        double pacingFrameTimeUsMax = 0.0;
        double pacingInterPresentGapUsStdDev = 0.0;
        double pacingInterPresentGapUsCoV = 0.0;
        std::uint64_t pacingHitch25 = 0;
        std::uint64_t pacingHitch50 = 0;
        std::uint64_t pacingHitch100 = 0;
        double pacingDrawableWaitUs = 0.0;
        std::uint64_t pacingDrawableWaitCount = 0;
        std::uint64_t parallelTranslatedDraws = 0;
        std::uint64_t parallelCandidateDraws = 0;
        std::uint64_t parallelEncodedDraws = 0;
        std::uint64_t parallelDescriptorEncodedDraws = 0;
        std::uint64_t parallelFboBoundaryDraws = 0;
        std::uint64_t parallelBatchCount = 0;
        std::uint64_t parallelMaxBatchSize = 0;
        // S25 commit B: copy-headroom shadow probe subset.
        bool copyHeadroomEnabled = false;
        std::uint64_t copyHeadroomFb0Draws = 0;
        std::uint64_t copyHeadroomFb0FillSuccesses = 0;
        double copyHeadroomFb0FillUsTotal = 0.0;
        std::uint64_t copyHeadroomFb0Retains = 0;
        std::uint64_t copyHeadroomFboDraws = 0;
        std::uint64_t copyHeadroomFboUniformBytes = 0;
        std::uint64_t copyHeadroomArenaDrains = 0;
        std::uint64_t copyHeadroomArenaLive = 0;
        // S25 W2: record-plan memo subset.
        std::uint64_t w2PlanMemoHits = 0;
        std::uint64_t w2PlanMemoMisses = 0;
        std::uint64_t w2PlanMemoBuildFails = 0;
        std::uint64_t w2PlanMemoEvictions = 0;
        std::uint64_t w2PlanMemoSize = 0;
        std::uint64_t w2PlanMemoPeak = 0;
        std::uint64_t w2PlanVerifyMismatches = 0;
        // S25 Lever-G: bounded default-uniform generation bind cache.
        std::uint64_t defaultUniformGenerationBindCacheLookups = 0;
        std::uint64_t defaultUniformGenerationBindCacheHits = 0;
        std::uint64_t defaultUniformGenerationBindCacheActiveHits = 0;
        std::uint64_t defaultUniformGenerationBindCacheRebinds = 0;
        std::uint64_t defaultUniformGenerationBindCacheMisses = 0;
        std::uint64_t defaultUniformGenerationBindCacheStores = 0;
        std::uint64_t defaultUniformGenerationBindCacheEvictions = 0;
        std::uint64_t defaultUniformGenerationBindCacheLiveEntries = 0;
        std::uint64_t defaultUniformGenerationBindCachePeakEntries = 0;
        std::uint64_t defaultUniformGenerationBindCacheCapacity = 0;
        std::uint64_t defaultUniformGenerationBindCacheActiveInvalidations = 0;
        std::uint64_t defaultUniformGenerationBindCacheResetInvalidations = 0;
        std::uint64_t defaultUniformGenerationBindCacheResetInvalidatedEntries = 0;
        std::uint64_t defaultUniformGenerationBindCacheObsDraws = 0;
        std::uint64_t defaultUniformGenerationBindCacheObsBindSkipHits = 0;
        std::uint64_t defaultUniformGenerationBindCacheObsGenerationHits = 0;
        std::uint64_t defaultUniformGenerationBindCacheObsHashFreeRebindHits = 0;
        std::uint64_t defaultUniformGenerationBindCacheObsMisses = 0;
        std::uint64_t defaultUniformGenerationBindCacheObsHashesSkippedOnMiss = 0;
        std::uint64_t defaultUniformGenerationBindCacheObsHashesRun = 0;
        MetalResourceResidencySummary residency;
        MetalHostCacheSummary hostCaches;
        Depth32FReadbackDiagnostics depth32fReadback;
        MetalR5ResidencyDryRunSummary r5DryRun;
        MetalR5ResidencyTouchSummary r5Touches;
        MetalR5ResidencyOrderingSummary r5Ordering;
        MetalR5EvictionSummary r5Eviction;
        MetalR8HeapSegmentationSummary r8HeapSegmentation;
        std::vector<ResourceResidencyRecord> residencyRows;
        std::vector<ResourceResidencyRecord> r5OrderingCandidates;
        std::vector<MetalR8HeapBucketSummary> r8HeapBuckets;
        std::uint64_t textureShadowHotspotLimit = 0;
        std::uint64_t textureShadowHotspotRows = 0;
        std::uint64_t textureShadowHotspotsTruncated = 0;
        std::vector<TextureShadowHotspot> topTextureShadows;
        std::uint64_t mallocZoneLimit = 0;
        std::uint64_t mallocZoneRows = 0;
        std::uint64_t mallocZonesTruncated = 0;
        std::vector<MallocZoneSummary> topMallocZones;
        std::vector<RenderPsoProgramHotspot> topRenderPsoPrograms;
    };
    MetalResourceInventory metalResourceInventory() const;
    // C52 opt-pass instrument: JSON snapshot of the per-draw profilers
    // ({"gl":...} for APPGL_GL_DRAW_PROFILE, {"submit":...} for
    // APPGL_DRAW_PROFILE); "" when neither is enabled or no draws ran.
    // Their stderr dumps are teardown-gated and real apps may never tear
    // down — the diagnostics JSONL emits this instead.
    std::string drawProfileDiagnosticsJson() const;
    // S25 Rung-1 instruments: always-on frame-pacing + parallel-encode
    // share JSON for the periodic diagnostics JSONL ("" only when no
    // frame graph exists). Probe-facing typed subset rides
    // MetalResourceInventory.pacing*/parallel* instead.
    std::string framePacingDiagnosticsJson() const;
    std::uint64_t evictR5DerivedCachesForTesting(std::uint64_t budget);

    // Transform feedback active state tracking (for CTS api_errors_test).
    bool isTransformFeedbackActive() const;
    void setTransformFeedbackActive(bool active);
    bool isTransformFeedbackPaused() const;
    void setTransformFeedbackPaused(bool paused);
    GLenum transformFeedbackPrimitiveMode() const;
    void setTransformFeedbackPrimitiveMode(GLenum mode);
    GLuint boundTransformFeedback() const;
    void setBoundTransformFeedback(GLuint id);

    // Currently bound draw framebuffer (0 = default). Exposed so
    // legacy non-DSA entry points (e.g. glClearBufferfv) can route
    // to the DSA equivalents (e.g. clearNamedFramebufferfv) by
    // passing this as the named-framebuffer argument.
    GLuint boundDrawFramebuffer() const;

private:
    GLProgramObject* validateProgramUniformTarget(GLuint program);

    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace appgl
