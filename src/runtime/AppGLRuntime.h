#pragma once

#include <cstddef>
#include <mutex>
#include <string>
#include <string_view>
#include <type_traits>
#include <unordered_set>

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
void APIENTRY glGenBuffers(GLsizei n, GLuint* buffers);
void APIENTRY glDeleteBuffers(GLsizei n, const GLuint* buffers);
GLboolean APIENTRY glIsBuffer(GLuint buffer);
void APIENTRY glBindBuffer(GLenum target, GLuint buffer);
void APIENTRY glBindBufferBase(GLenum target, GLuint index, GLuint buffer);
void APIENTRY glBindBufferRange(GLenum target, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size);
void APIENTRY glBufferData(GLenum target, GLsizeiptr size, const void* data, GLenum usage);
void APIENTRY glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data);
void APIENTRY glCopyBufferSubData(GLenum readTarget, GLenum writeTarget, GLintptr readOffset, GLintptr writeOffset, GLsizeiptr size);
void APIENTRY glGetBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, void* data);
void* APIENTRY glMapBuffer(GLenum target, GLenum access);
void* APIENTRY glMapBufferRange(GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield access);
GLboolean APIENTRY glUnmapBuffer(GLenum target);
void APIENTRY glFlushMappedBufferRange(GLenum target, GLintptr offset, GLsizeiptr length);
void APIENTRY glGetBufferParameteriv(GLenum target, GLenum pname, GLint* params);
void APIENTRY glGetBufferParameteri64v(GLenum target, GLenum pname, GLint64* params);
void APIENTRY glGetBufferPointerv(GLenum target, GLenum pname, void** params);
void APIENTRY glGenVertexArrays(GLsizei n, GLuint* arrays);
void APIENTRY glDeleteVertexArrays(GLsizei n, const GLuint* arrays);
GLboolean APIENTRY glIsVertexArray(GLuint array);
void APIENTRY glBindVertexArray(GLuint array);
void APIENTRY glEnableVertexAttribArray(GLuint index);
void APIENTRY glDisableVertexAttribArray(GLuint index);
void APIENTRY glVertexAttribPointer(GLuint index, GLint size, GLenum type, GLboolean normalized, GLsizei stride, const void* pointer);
void APIENTRY glVertexAttribIPointer(GLuint index, GLint size, GLenum type, GLsizei stride, const void* pointer);
void APIENTRY glVertexAttribDivisor(GLuint index, GLuint divisor);
// GL 4.3 — separated vertex format (ARB_vertex_attrib_binding).
void APIENTRY glBindVertexBuffer(GLuint bindingindex, GLuint buffer, GLintptr offset, GLsizei stride);
void APIENTRY glVertexAttribFormat(GLuint attribindex, GLint size, GLenum type, GLboolean normalized, GLuint relativeoffset);
void APIENTRY glVertexAttribIFormat(GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset);
void APIENTRY glVertexAttribLFormat(GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset);
void APIENTRY glVertexAttribBinding(GLuint attribindex, GLuint bindingindex);
void APIENTRY glVertexBindingDivisor(GLuint bindingindex, GLuint divisor);
void APIENTRY glGetVertexAttribiv(GLuint index, GLenum pname, GLint* params);
void APIENTRY glGetVertexAttribfv(GLuint index, GLenum pname, GLfloat* params);
void APIENTRY glGetVertexAttribPointerv(GLuint index, GLenum pname, void** pointer);
void APIENTRY glActiveTexture(GLenum texture);
void APIENTRY glGenTextures(GLsizei n, GLuint* textures);
void APIENTRY glDeleteTextures(GLsizei n, const GLuint* textures);
GLboolean APIENTRY glIsTexture(GLuint texture);
void APIENTRY glBindTexture(GLenum target, GLuint texture);
void APIENTRY glTexImage1D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLint border, GLenum format, GLenum type, const void* pixels);
void APIENTRY glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const void* pixels);
void APIENTRY glTexImage3D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLsizei depth, GLint border, GLenum format, GLenum type, const void* pixels);
void APIENTRY glTexSubImage1D(GLenum target, GLint level, GLint xoffset, GLsizei width, GLenum format, GLenum type, const void* pixels);
void APIENTRY glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const void* pixels);
void APIENTRY glTexSubImage3D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, const void* pixels);
void APIENTRY glTexParameteri(GLenum target, GLenum pname, GLint param);
void APIENTRY glTexParameteriv(GLenum target, GLenum pname, const GLint* params);
void APIENTRY glTexParameterf(GLenum target, GLenum pname, GLfloat param);
void APIENTRY glTexParameterfv(GLenum target, GLenum pname, const GLfloat* params);
void APIENTRY glTexParameterIiv(GLenum target, GLenum pname, const GLint* params);
void APIENTRY glTexParameterIuiv(GLenum target, GLenum pname, const GLuint* params);
void APIENTRY glGetTexParameteriv(GLenum target, GLenum pname, GLint* params);
void APIENTRY glGetTexParameterfv(GLenum target, GLenum pname, GLfloat* params);
void APIENTRY glGetTexParameterIiv(GLenum target, GLenum pname, GLint* params);
void APIENTRY glGetTexParameterIuiv(GLenum target, GLenum pname, GLuint* params);
void APIENTRY glGenerateMipmap(GLenum target);
void APIENTRY glTexStorage1D(GLenum target, GLsizei levels, GLenum internalformat, GLsizei width);
void APIENTRY glTexStorage2D(GLenum target, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height);
void APIENTRY glTexStorage3D(GLenum target, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth);
void APIENTRY glTexStorage2DMultisample(GLenum target, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLboolean fixedsamplelocations);
void APIENTRY glTexStorage3DMultisample(GLenum target, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth, GLboolean fixedsamplelocations);
void APIENTRY glTexPageCommitmentARB(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLboolean commit);
void APIENTRY glGetFragmentShadingRatesEXT(GLsizei samples, GLsizei maxCount, GLsizei* count, GLenum* shadingRates);
void APIENTRY glShadingRateEXT(GLenum rate);
void APIENTRY glShadingRateCombinerOpsEXT(GLenum combinerOp0, GLenum combinerOp1);
void APIENTRY glFramebufferShadingRateEXT(GLenum target, GLenum attachment, GLuint texture, GLint baseLayer, GLsizei numLayers, GLsizei texelWidth, GLsizei texelHeight);
void APIENTRY glTexBufferRange(GLenum target, GLenum internalformat, GLuint buffer, GLintptr offset, GLsizeiptr size);
void APIENTRY glPixelStorei(GLenum pname, GLint param);
void APIENTRY glPixelStoref(GLenum pname, GLfloat param);
void APIENTRY glDrawBuffer(GLenum buffer);
void APIENTRY glDrawBuffers(GLsizei n, const GLenum* buffers);
void APIENTRY glReadBuffer(GLenum buffer);
void APIENTRY glGenRenderbuffers(GLsizei n, GLuint* renderbuffers);
void APIENTRY glDeleteRenderbuffers(GLsizei n, const GLuint* renderbuffers);
GLboolean APIENTRY glIsRenderbuffer(GLuint renderbuffer);
void APIENTRY glBindRenderbuffer(GLenum target, GLuint renderbuffer);
void APIENTRY glRenderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height);
void APIENTRY glRenderbufferStorageMultisample(GLenum target, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height);
void APIENTRY glGetRenderbufferParameteriv(GLenum target, GLenum pname, GLint* params);
void APIENTRY glGenFramebuffers(GLsizei n, GLuint* framebuffers);
void APIENTRY glDeleteFramebuffers(GLsizei n, const GLuint* framebuffers);
GLboolean APIENTRY glIsFramebuffer(GLuint framebuffer);
void APIENTRY glBindFramebuffer(GLenum target, GLuint framebuffer);
GLenum APIENTRY glCheckFramebufferStatus(GLenum target);
void APIENTRY glFramebufferTexture1D(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level);
void APIENTRY glFramebufferTexture2D(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level);
void APIENTRY glFramebufferTexture3D(GLenum target, GLenum attachment, GLenum textarget, GLuint texture, GLint level, GLint zoffset);
void APIENTRY glFramebufferTexture(GLenum target, GLenum attachment, GLuint texture, GLint level);
void APIENTRY glFramebufferTextureLayer(GLenum target, GLenum attachment, GLuint texture, GLint level, GLint layer);
void APIENTRY glFramebufferRenderbuffer(GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer);
void APIENTRY glBlitFramebuffer(GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1, GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1, GLbitfield mask, GLenum filter);
void APIENTRY glGetFramebufferAttachmentParameteriv(GLenum target, GLenum attachment, GLenum pname, GLint* params);
void APIENTRY glGenSamplers(GLsizei count, GLuint* samplers);
void APIENTRY glDeleteSamplers(GLsizei count, const GLuint* samplers);
GLboolean APIENTRY glIsSampler(GLuint sampler);
void APIENTRY glBindSampler(GLuint unit, GLuint sampler);
void APIENTRY glSamplerParameteri(GLuint sampler, GLenum pname, GLint param);
void APIENTRY glSamplerParameteriv(GLuint sampler, GLenum pname, const GLint* param);
void APIENTRY glSamplerParameterf(GLuint sampler, GLenum pname, GLfloat param);
void APIENTRY glSamplerParameterfv(GLuint sampler, GLenum pname, const GLfloat* param);
void APIENTRY glSamplerParameterIiv(GLuint sampler, GLenum pname, const GLint* param);
void APIENTRY glSamplerParameterIuiv(GLuint sampler, GLenum pname, const GLuint* param);
void APIENTRY glGetSamplerParameteriv(GLuint sampler, GLenum pname, GLint* params);
void APIENTRY glGetSamplerParameterfv(GLuint sampler, GLenum pname, GLfloat* params);
void APIENTRY glGetSamplerParameterIiv(GLuint sampler, GLenum pname, GLint* params);
void APIENTRY glGetSamplerParameterIuiv(GLuint sampler, GLenum pname, GLuint* params);
void APIENTRY glEnable(GLenum cap);
void APIENTRY glDisable(GLenum cap);
GLboolean APIENTRY glIsEnabled(GLenum cap);
void APIENTRY glScissor(GLint x, GLint y, GLsizei width, GLsizei height);
void APIENTRY glDepthRange(GLdouble nearValue, GLdouble farValue);
void APIENTRY glDepthRangef(GLfloat nearValue, GLfloat farValue);
void APIENTRY glBlendFunc(GLenum srcFactor, GLenum dstFactor);
void APIENTRY glBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha);
void APIENTRY glBlendFunci(GLuint buf, GLenum src, GLenum dst);
void APIENTRY glBlendFuncSeparatei(GLuint buf, GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha);
void APIENTRY glBlendEquation(GLenum mode);
void APIENTRY glBlendEquationSeparate(GLenum modeRGB, GLenum modeAlpha);
void APIENTRY glBlendEquationi(GLuint buf, GLenum mode);
void APIENTRY glBlendEquationSeparatei(GLuint buf, GLenum modeRGB, GLenum modeAlpha);
void APIENTRY glBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
void APIENTRY glColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
void APIENTRY glColorMaski(GLuint index, GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
void APIENTRY glMinSampleShading(GLfloat value);
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
void APIENTRY glDebugMessageControl(GLenum source, GLenum type, GLenum severity, GLsizei count, const GLuint* ids, GLboolean enabled);
void APIENTRY glDebugMessageInsert(GLenum source, GLenum type, GLuint id, GLenum severity, GLsizei length, const GLchar* buf);
void APIENTRY glDebugMessageCallback(GLDEBUGPROC callback, const void* userParam);
GLuint APIENTRY glGetDebugMessageLog(GLuint count, GLsizei bufSize, GLenum* sources, GLenum* types, GLuint* ids, GLenum* severities, GLsizei* lengths, GLchar* messageLog);
void APIENTRY glPushDebugGroup(GLenum source, GLuint id, GLsizei length, const GLchar* message);
void APIENTRY glPopDebugGroup(void);
void APIENTRY glObjectLabel(GLenum identifier, GLuint name, GLsizei length, const GLchar* label);
void APIENTRY glGetObjectLabel(GLenum identifier, GLuint name, GLsizei bufSize, GLsizei* length, GLchar* label);
void APIENTRY glObjectPtrLabel(const void* ptr, GLsizei length, const GLchar* label);
void APIENTRY glGetObjectPtrLabel(const void* ptr, GLsizei bufSize, GLsizei* length, GLchar* label);
void APIENTRY glGetPointerv(GLenum pname, void** params);

// Group 6 — Shaders and Programs
GLuint APIENTRY glCreateShader(GLenum type);
void APIENTRY glDeleteShader(GLuint shader);
GLboolean APIENTRY glIsShader(GLuint shader);
void APIENTRY glShaderSource(GLuint shader, GLsizei count, const GLchar* const* strings, const GLint* length);
void APIENTRY glCompileShader(GLuint shader);
void APIENTRY glGetShaderiv(GLuint shader, GLenum pname, GLint* params);
void APIENTRY glGetShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* infoLog);
void APIENTRY glGetShaderSource(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* source);
GLuint APIENTRY glCreateProgram(void);
void APIENTRY glDeleteProgram(GLuint program);
GLboolean APIENTRY glIsProgram(GLuint program);
void APIENTRY glAttachShader(GLuint program, GLuint shader);
void APIENTRY glDetachShader(GLuint program, GLuint shader);
void APIENTRY glLinkProgram(GLuint program);
void APIENTRY glUseProgram(GLuint program);
void APIENTRY glValidateProgram(GLuint program);
void APIENTRY glGetProgramiv(GLuint program, GLenum pname, GLint* params);
void APIENTRY glGetProgramInfoLog(GLuint program, GLsizei bufSize, GLsizei* length, GLchar* infoLog);
void APIENTRY glGetAttachedShaders(GLuint program, GLsizei maxCount, GLsizei* count, GLuint* shaders);
void APIENTRY glBindAttribLocation(GLuint program, GLuint index, const GLchar* name);
GLint APIENTRY glGetAttribLocation(GLuint program, const GLchar* name);
void APIENTRY glGetActiveAttrib(GLuint program, GLuint index, GLsizei bufSize, GLsizei* length, GLint* size, GLenum* type, GLchar* name);
GLint APIENTRY glGetUniformLocation(GLuint program, const GLchar* name);
void APIENTRY glGetActiveUniform(GLuint program, GLuint index, GLsizei bufSize, GLsizei* length, GLint* size, GLenum* type, GLchar* name);
void APIENTRY glGetUniformfv(GLuint program, GLint location, GLfloat* params);
void APIENTRY glGetUniformiv(GLuint program, GLint location, GLint* params);
void APIENTRY glGetUniformuiv(GLuint program, GLint location, GLuint* params);
void APIENTRY glGetUniformdv(GLuint program, GLint location, GLdouble* params);
void APIENTRY glUniform1f(GLint location, GLfloat v0);
void APIENTRY glUniform2f(GLint location, GLfloat v0, GLfloat v1);
void APIENTRY glUniform3f(GLint location, GLfloat v0, GLfloat v1, GLfloat v2);
void APIENTRY glUniform4f(GLint location, GLfloat v0, GLfloat v1, GLfloat v2, GLfloat v3);
void APIENTRY glUniform1i(GLint location, GLint v0);
void APIENTRY glUniform2i(GLint location, GLint v0, GLint v1);
void APIENTRY glUniform3i(GLint location, GLint v0, GLint v1, GLint v2);
void APIENTRY glUniform4i(GLint location, GLint v0, GLint v1, GLint v2, GLint v3);
void APIENTRY glUniform1ui(GLint location, GLuint v0);
void APIENTRY glUniform2ui(GLint location, GLuint v0, GLuint v1);
void APIENTRY glUniform3ui(GLint location, GLuint v0, GLuint v1, GLuint v2);
void APIENTRY glUniform4ui(GLint location, GLuint v0, GLuint v1, GLuint v2, GLuint v3);
void APIENTRY glUniform1fv(GLint location, GLsizei count, const GLfloat* value);
void APIENTRY glUniform2fv(GLint location, GLsizei count, const GLfloat* value);
void APIENTRY glUniform3fv(GLint location, GLsizei count, const GLfloat* value);
void APIENTRY glUniform4fv(GLint location, GLsizei count, const GLfloat* value);
void APIENTRY glUniform1iv(GLint location, GLsizei count, const GLint* value);
void APIENTRY glUniform2iv(GLint location, GLsizei count, const GLint* value);
void APIENTRY glUniform3iv(GLint location, GLsizei count, const GLint* value);
void APIENTRY glUniform4iv(GLint location, GLsizei count, const GLint* value);
void APIENTRY glUniform1uiv(GLint location, GLsizei count, const GLuint* value);
void APIENTRY glUniform2uiv(GLint location, GLsizei count, const GLuint* value);
void APIENTRY glUniform3uiv(GLint location, GLsizei count, const GLuint* value);
void APIENTRY glUniform4uiv(GLint location, GLsizei count, const GLuint* value);
void APIENTRY glUniformMatrix2fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat* value);
void APIENTRY glUniformMatrix3fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat* value);
void APIENTRY glUniformMatrix4fv(GLint location, GLsizei count, GLboolean transpose, const GLfloat* value);
// GL 4.0 double-precision uniform setters (f64→f32 narrowing with CPU-side double shadow).
void APIENTRY glUniform1d(GLint location, GLdouble x);
void APIENTRY glUniform2d(GLint location, GLdouble x, GLdouble y);
void APIENTRY glUniform3d(GLint location, GLdouble x, GLdouble y, GLdouble z);
void APIENTRY glUniform4d(GLint location, GLdouble x, GLdouble y, GLdouble z, GLdouble w);
void APIENTRY glUniform1dv(GLint location, GLsizei count, const GLdouble* value);
void APIENTRY glUniform2dv(GLint location, GLsizei count, const GLdouble* value);
void APIENTRY glUniform3dv(GLint location, GLsizei count, const GLdouble* value);
void APIENTRY glUniform4dv(GLint location, GLsizei count, const GLdouble* value);
void APIENTRY glUniformMatrix2dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glUniformMatrix3dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glUniformMatrix4dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glUniformMatrix2x3dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glUniformMatrix2x4dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glUniformMatrix3x2dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glUniformMatrix3x4dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glUniformMatrix4x2dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glUniformMatrix4x3dv(GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glDrawArrays(GLenum mode, GLint first, GLsizei count);
void APIENTRY glDrawElements(GLenum mode, GLsizei count, GLenum type, const void* indices);
// GL 4.0 — tessellation patch parameters.
void APIENTRY glPatchParameteri(GLenum pname, GLint value);
void APIENTRY glPatchParameterfv(GLenum pname, const GLfloat* values);
// GL 4.0 — indexed queries.
void APIENTRY glBeginQueryIndexed(GLenum target, GLuint index, GLuint id);
void APIENTRY glEndQueryIndexed(GLenum target, GLuint index);
void APIENTRY glGetQueryIndexediv(GLenum target, GLuint index, GLenum pname, GLint* params);
// GL 4.1 — viewport/scissor/depth arrays.
void APIENTRY glViewportArrayv(GLuint first, GLsizei count, const GLfloat* v);
void APIENTRY glViewportIndexedf(GLuint index, GLfloat x, GLfloat y, GLfloat w, GLfloat h);
void APIENTRY glViewportIndexedfv(GLuint index, const GLfloat* v);
void APIENTRY glScissorArrayv(GLuint first, GLsizei count, const GLint* v);
void APIENTRY glScissorIndexed(GLuint index, GLint left, GLint bottom, GLsizei width, GLsizei height);
void APIENTRY glScissorIndexedv(GLuint index, const GLint* v);
void APIENTRY glDepthRangeArrayv(GLuint first, GLsizei count, const GLdouble* v);
void APIENTRY glDepthRangeIndexed(GLuint index, GLdouble n, GLdouble f);
void APIENTRY glGetFloati_v(GLenum target, GLuint index, GLfloat* data);
void APIENTRY glGetDoublei_v(GLenum target, GLuint index, GLdouble* data);
void APIENTRY glClearDepthf(GLfloat d);
// GL 4.1 — shader precision.
void APIENTRY glGetShaderPrecisionFormat(GLenum shadertype, GLenum precisiontype, GLint* range, GLint* precision);
// GL 4.1 — program uniforms (explicit program handle, 50 arities).
void APIENTRY glProgramUniform1i(GLuint program, GLint location, GLint v0);
void APIENTRY glProgramUniform1iv(GLuint program, GLint location, GLsizei count, const GLint* value);
void APIENTRY glProgramUniform1f(GLuint program, GLint location, GLfloat v0);
void APIENTRY glProgramUniform1fv(GLuint program, GLint location, GLsizei count, const GLfloat* value);
void APIENTRY glProgramUniform1d(GLuint program, GLint location, GLdouble x);
void APIENTRY glProgramUniform1dv(GLuint program, GLint location, GLsizei count, const GLdouble* value);
void APIENTRY glProgramUniform1ui(GLuint program, GLint location, GLuint v0);
void APIENTRY glProgramUniform1uiv(GLuint program, GLint location, GLsizei count, const GLuint* value);
void APIENTRY glProgramUniform2i(GLuint program, GLint location, GLint v0, GLint v1);
void APIENTRY glProgramUniform2iv(GLuint program, GLint location, GLsizei count, const GLint* value);
void APIENTRY glProgramUniform2f(GLuint program, GLint location, GLfloat v0, GLfloat v1);
void APIENTRY glProgramUniform2fv(GLuint program, GLint location, GLsizei count, const GLfloat* value);
void APIENTRY glProgramUniform2d(GLuint program, GLint location, GLdouble x, GLdouble y);
void APIENTRY glProgramUniform2dv(GLuint program, GLint location, GLsizei count, const GLdouble* value);
void APIENTRY glProgramUniform2ui(GLuint program, GLint location, GLuint v0, GLuint v1);
void APIENTRY glProgramUniform2uiv(GLuint program, GLint location, GLsizei count, const GLuint* value);
void APIENTRY glProgramUniform3i(GLuint program, GLint location, GLint v0, GLint v1, GLint v2);
void APIENTRY glProgramUniform3iv(GLuint program, GLint location, GLsizei count, const GLint* value);
void APIENTRY glProgramUniform3f(GLuint program, GLint location, GLfloat v0, GLfloat v1, GLfloat v2);
void APIENTRY glProgramUniform3fv(GLuint program, GLint location, GLsizei count, const GLfloat* value);
void APIENTRY glProgramUniform3d(GLuint program, GLint location, GLdouble x, GLdouble y, GLdouble z);
void APIENTRY glProgramUniform3dv(GLuint program, GLint location, GLsizei count, const GLdouble* value);
void APIENTRY glProgramUniform3ui(GLuint program, GLint location, GLuint v0, GLuint v1, GLuint v2);
void APIENTRY glProgramUniform3uiv(GLuint program, GLint location, GLsizei count, const GLuint* value);
void APIENTRY glProgramUniform4i(GLuint program, GLint location, GLint v0, GLint v1, GLint v2, GLint v3);
void APIENTRY glProgramUniform4iv(GLuint program, GLint location, GLsizei count, const GLint* value);
void APIENTRY glProgramUniform4f(GLuint program, GLint location, GLfloat v0, GLfloat v1, GLfloat v2, GLfloat v3);
void APIENTRY glProgramUniform4fv(GLuint program, GLint location, GLsizei count, const GLfloat* value);
void APIENTRY glProgramUniform4d(GLuint program, GLint location, GLdouble x, GLdouble y, GLdouble z, GLdouble w);
void APIENTRY glProgramUniform4dv(GLuint program, GLint location, GLsizei count, const GLdouble* value);
void APIENTRY glProgramUniform4ui(GLuint program, GLint location, GLuint v0, GLuint v1, GLuint v2, GLuint v3);
void APIENTRY glProgramUniform4uiv(GLuint program, GLint location, GLsizei count, const GLuint* value);
void APIENTRY glProgramUniformMatrix2fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value);
void APIENTRY glProgramUniformMatrix3fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value);
void APIENTRY glProgramUniformMatrix4fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value);
void APIENTRY glProgramUniformMatrix2dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glProgramUniformMatrix3dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glProgramUniformMatrix4dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glProgramUniformMatrix2x3fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value);
void APIENTRY glProgramUniformMatrix3x2fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value);
void APIENTRY glProgramUniformMatrix2x4fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value);
void APIENTRY glProgramUniformMatrix4x2fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value);
void APIENTRY glProgramUniformMatrix3x4fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value);
void APIENTRY glProgramUniformMatrix4x3fv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLfloat* value);
void APIENTRY glProgramUniformMatrix2x3dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glProgramUniformMatrix3x2dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glProgramUniformMatrix2x4dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glProgramUniformMatrix4x2dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glProgramUniformMatrix3x4dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
void APIENTRY glProgramUniformMatrix4x3dv(GLuint program, GLint location, GLsizei count, GLboolean transpose, const GLdouble* value);
// GL 4.1 — program/shader binary and release.
void APIENTRY glGetProgramBinary(GLuint program, GLsizei bufSize, GLsizei* length, GLenum* binaryFormat, void* binary);
void APIENTRY glProgramBinary(GLuint program, GLenum binaryFormat, const void* binary, GLsizei length);
void APIENTRY glProgramParameteri(GLuint program, GLenum pname, GLint value);
void APIENTRY glShaderBinary(GLsizei count, const GLuint* shaders, GLenum binaryformat, const void* binary, GLsizei length);
void APIENTRY glReleaseShaderCompiler(void);
// GL 4.1 — double-precision vertex attributes (f64→f32 narrowing with CPU-side double shadow).
void APIENTRY glVertexAttribL1d(GLuint index, GLdouble x);
void APIENTRY glVertexAttribL2d(GLuint index, GLdouble x, GLdouble y);
void APIENTRY glVertexAttribL3d(GLuint index, GLdouble x, GLdouble y, GLdouble z);
void APIENTRY glVertexAttribL4d(GLuint index, GLdouble x, GLdouble y, GLdouble z, GLdouble w);
void APIENTRY glVertexAttribL1dv(GLuint index, const GLdouble* v);
void APIENTRY glVertexAttribL2dv(GLuint index, const GLdouble* v);
void APIENTRY glVertexAttribL3dv(GLuint index, const GLdouble* v);
void APIENTRY glVertexAttribL4dv(GLuint index, const GLdouble* v);
void APIENTRY glVertexAttribLPointer(GLuint index, GLint size, GLenum type, GLsizei stride, const void* pointer);
void APIENTRY glGetVertexAttribLdv(GLuint index, GLenum pname, GLdouble* params);
// GL 4.1 — program pipeline objects (Group 9).
void APIENTRY glGenProgramPipelines(GLsizei n, GLuint* pipelines);
void APIENTRY glDeleteProgramPipelines(GLsizei n, const GLuint* pipelines);
GLboolean APIENTRY glIsProgramPipeline(GLuint pipeline);
void APIENTRY glBindProgramPipeline(GLuint pipeline);
void APIENTRY glUseProgramStages(GLuint pipeline, GLbitfield stages, GLuint program);
void APIENTRY glActiveShaderProgram(GLuint pipeline, GLuint program);
GLuint APIENTRY glCreateShaderProgramv(GLenum type, GLsizei count, const GLchar* const* strings);
void APIENTRY glValidateProgramPipeline(GLuint pipeline);
void APIENTRY glGetProgramPipelineiv(GLuint pipeline, GLenum pname, GLint* params);
void APIENTRY glGetProgramPipelineInfoLog(GLuint pipeline, GLsizei bufSize, GLsizei* length, GLchar* infoLog);
// GL 4.0 — subroutine uniforms (Group 3, stub-with-state).
GLint APIENTRY glGetSubroutineUniformLocation(GLuint program, GLenum shadertype, const GLchar* name);
GLuint APIENTRY glGetSubroutineIndex(GLuint program, GLenum shadertype, const GLchar* name);
void APIENTRY glGetActiveSubroutineUniformiv(GLuint program, GLenum shadertype, GLuint index, GLenum pname, GLint* values);
void APIENTRY glGetActiveSubroutineUniformName(GLuint program, GLenum shadertype, GLuint index, GLsizei bufsize, GLsizei* length, GLchar* name);
void APIENTRY glGetActiveSubroutineName(GLuint program, GLenum shadertype, GLuint index, GLsizei bufsize, GLsizei* length, GLchar* name);
void APIENTRY glUniformSubroutinesuiv(GLenum shadertype, GLsizei count, const GLuint* indices);
void APIENTRY glGetUniformSubroutineuiv(GLenum shadertype, GLint location, GLuint* params);
void APIENTRY glGetProgramStageiv(GLuint program, GLenum shadertype, GLenum pname, GLint* values);
// GL 4.0 — transform feedback objects (Group 4).
void APIENTRY glGenTransformFeedbacks(GLsizei n, GLuint* ids);
void APIENTRY glDeleteTransformFeedbacks(GLsizei n, const GLuint* ids);
GLboolean APIENTRY glIsTransformFeedback(GLuint id);
void APIENTRY glBindTransformFeedback(GLenum target, GLuint id);
void APIENTRY glPauseTransformFeedback(void);
void APIENTRY glResumeTransformFeedback(void);
void APIENTRY glDrawTransformFeedback(GLenum mode, GLuint id);
void APIENTRY glDrawTransformFeedbackStream(GLenum mode, GLuint id, GLuint stream);
// GL 4.0 — indirect drawing (Group 6).
void APIENTRY glDrawArraysIndirect(GLenum mode, const void* indirect);
void APIENTRY glDrawElementsIndirect(GLenum mode, GLenum type, const void* indirect);
// GL 4.2/4.3 — compute shaders and memory barriers.
void APIENTRY glMemoryBarrier(GLbitfield barriers);
void APIENTRY glDispatchCompute(GLuint num_groups_x, GLuint num_groups_y, GLuint num_groups_z);
void APIENTRY glDispatchComputeIndirect(GLintptr indirect);
// GL 4.2 — image load/store and atomic counters.
void APIENTRY glBindImageTexture(GLuint unit, GLuint texture, GLint level, GLboolean layered, GLint layer, GLenum access, GLenum format);
void APIENTRY glGetActiveAtomicCounterBufferiv(GLuint program, GLuint bufferIndex, GLenum pname, GLint* params);
// GL 4.3 — program resource introspection (ARB_program_interface_query).
void APIENTRY glGetProgramInterfaceiv(GLuint program, GLenum programInterface, GLenum pname, GLint* params);
void APIENTRY glGetProgramResourceiv(GLuint program, GLenum programInterface, GLuint index, GLsizei propCount, const GLenum* props, GLsizei count, GLsizei* length, GLint* params);
void APIENTRY glGetProgramResourceName(GLuint program, GLenum programInterface, GLuint index, GLsizei bufSize, GLsizei* length, GLchar* name);
GLuint APIENTRY glGetProgramResourceIndex(GLuint program, GLenum programInterface, const GLchar* name);
GLint APIENTRY glGetProgramResourceLocation(GLuint program, GLenum programInterface, const GLchar* name);
GLint APIENTRY glGetProgramResourceLocationIndex(GLuint program, GLenum programInterface, const GLchar* name);
// GL 4.3 — SSBO binding remapping.
void APIENTRY glShaderStorageBlockBinding(GLuint program, GLuint storageBlockIndex, GLuint storageBlockBinding);
// GL 4.2 — advanced instanced drawing with base instance.
void APIENTRY glDrawArraysInstancedBaseInstance(GLenum mode, GLint first, GLsizei count, GLsizei instancecount, GLuint baseinstance);
void APIENTRY glDrawElementsInstancedBaseInstance(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLuint baseinstance);
void APIENTRY glDrawElementsInstancedBaseVertexBaseInstance(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLint basevertex, GLuint baseinstance);
// GL 4.3 — multi-draw indirect.
void APIENTRY glMultiDrawArraysIndirect(GLenum mode, const void* indirect, GLsizei drawcount, GLsizei stride);
void APIENTRY glMultiDrawElementsIndirect(GLenum mode, GLenum type, const void* indirect, GLsizei drawcount, GLsizei stride);
// GL 4.3 — buffer clear.
void APIENTRY glClearBufferData(GLenum target, GLenum internalformat, GLenum format, GLenum type, const void* data);
void APIENTRY glClearBufferSubData(GLenum target, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format, GLenum type, const void* data);
// GL 4.3 — framebuffer parameters.
void APIENTRY glFramebufferParameteri(GLenum target, GLenum pname, GLint param);
void APIENTRY glGetFramebufferParameteriv(GLenum target, GLenum pname, GLint* params);
// GL 4.3 — invalidation hints.
void APIENTRY glInvalidateFramebuffer(GLenum target, GLsizei numAttachments, const GLenum* attachments);
void APIENTRY glInvalidateSubFramebuffer(GLenum target, GLsizei numAttachments, const GLenum* attachments, GLint x, GLint y, GLsizei width, GLsizei height);
void APIENTRY glInvalidateBufferData(GLuint buffer);
void APIENTRY glInvalidateBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr length);
// GL 4.3 — texture operations.
void APIENTRY glCopyImageSubData(GLuint srcName, GLenum srcTarget, GLint srcLevel, GLint srcX, GLint srcY, GLint srcZ,
                                  GLuint dstName, GLenum dstTarget, GLint dstLevel, GLint dstX, GLint dstY, GLint dstZ,
                                  GLsizei srcWidth, GLsizei srcHeight, GLsizei srcDepth);
void APIENTRY glTextureView(GLuint texture, GLenum target, GLuint origtexture, GLenum internalformat,
                             GLuint minlevel, GLuint numlevels, GLuint minlayer, GLuint numlayers);
void APIENTRY glInvalidateTexImage(GLuint texture, GLint level);
void APIENTRY glInvalidateTexSubImage(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
                                       GLsizei width, GLsizei height, GLsizei depth);
// GL 4.2 — transform feedback instanced draw.
void APIENTRY glDrawTransformFeedbackInstanced(GLenum mode, GLuint id, GLsizei instancecount);
void APIENTRY glDrawTransformFeedbackStreamInstanced(GLenum mode, GLuint id, GLuint stream, GLsizei instancecount);
// GL 4.2/4.3 — internal format query.
void APIENTRY glGetInternalformativ(GLenum target, GLenum internalformat, GLenum pname, GLsizei count, GLint* params);
void APIENTRY glGetInternalformati64v(GLenum target, GLenum internalformat, GLenum pname, GLsizei count, GLint64* params);
// GL 4.4 — immutable buffer storage.
void APIENTRY glBufferStorage(GLenum target, GLsizeiptr size, const void* data, GLbitfield flags);
// GL 4.4 — multi-bind.
void APIENTRY glBindBuffersBase(GLenum target, GLuint first, GLsizei count, const GLuint* buffers);
void APIENTRY glBindBuffersRange(GLenum target, GLuint first, GLsizei count, const GLuint* buffers,
                                  const GLintptr* offsets, const GLsizeiptr* sizes);
void APIENTRY glBindVertexBuffers(GLuint first, GLsizei count, const GLuint* buffers,
                                   const GLintptr* offsets, const GLsizei* strides);
void APIENTRY glBindTextures(GLuint first, GLsizei count, const GLuint* textures);
void APIENTRY glBindSamplers(GLuint first, GLsizei count, const GLuint* samplers);
void APIENTRY glBindImageTextures(GLuint first, GLsizei count, const GLuint* textures);
// GL 4.4 — texture clear.
void APIENTRY glClearTexImage(GLuint texture, GLint level, GLenum format, GLenum type, const void* data);
void APIENTRY glClearTexSubImage(GLuint texture, GLint level,
                                  GLint xoffset, GLint yoffset, GLint zoffset,
                                  GLsizei width, GLsizei height, GLsizei depth,
                                  GLenum format, GLenum type, const void* data);
// GL 4.5 — DSA object creation.
void APIENTRY glCreateBuffers(GLsizei n, GLuint* buffers);
void APIENTRY glCreateTextures(GLenum target, GLsizei n, GLuint* textures);
void APIENTRY glCreateSamplers(GLsizei n, GLuint* samplers);
void APIENTRY glCreateFramebuffers(GLsizei n, GLuint* framebuffers);
void APIENTRY glCreateRenderbuffers(GLsizei n, GLuint* renderbuffers);
void APIENTRY glCreateVertexArrays(GLsizei n, GLuint* arrays);
void APIENTRY glCreateTransformFeedbacks(GLsizei n, GLuint* ids);
void APIENTRY glCreateProgramPipelines(GLsizei n, GLuint* pipelines);
void APIENTRY glCreateQueries(GLenum target, GLsizei n, GLuint* ids);
// GL 4.5 — DSA buffer operations.
void APIENTRY glNamedBufferStorage(GLuint buffer, GLsizeiptr size, const void* data, GLbitfield flags);
void APIENTRY glNamedBufferData(GLuint buffer, GLsizeiptr size, const void* data, GLenum usage);
void APIENTRY glNamedBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr size, const void* data);
void APIENTRY glCopyNamedBufferSubData(GLuint readBuffer, GLuint writeBuffer, GLintptr readOffset, GLintptr writeOffset, GLsizeiptr size);
void* APIENTRY glMapNamedBuffer(GLuint buffer, GLenum access);
void* APIENTRY glMapNamedBufferRange(GLuint buffer, GLintptr offset, GLsizeiptr length, GLbitfield access);
GLboolean APIENTRY glUnmapNamedBuffer(GLuint buffer);
void APIENTRY glFlushMappedNamedBufferRange(GLuint buffer, GLintptr offset, GLsizeiptr length);
void APIENTRY glClearNamedBufferData(GLuint buffer, GLenum internalformat, GLenum format, GLenum type, const void* data);
void APIENTRY glClearNamedBufferSubData(GLuint buffer, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format, GLenum type, const void* data);
void APIENTRY glGetNamedBufferParameteriv(GLuint buffer, GLenum pname, GLint* params);
void APIENTRY glGetNamedBufferParameteri64v(GLuint buffer, GLenum pname, GLint64* params);
void APIENTRY glGetNamedBufferPointerv(GLuint buffer, GLenum pname, void** params);
void APIENTRY glGetNamedBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr size, void* data);
// GL 4.5 — DSA texture operations.
void APIENTRY glTextureStorage1D(GLuint texture, GLsizei levels, GLenum internalformat, GLsizei width);
void APIENTRY glTextureStorage2D(GLuint texture, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height);
void APIENTRY glTextureStorage3D(GLuint texture, GLsizei levels, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth);
void APIENTRY glTextureStorage2DMultisample(GLuint texture, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLboolean fixedsamplelocations);
void APIENTRY glTextureStorage3DMultisample(GLuint texture, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height, GLsizei depth, GLboolean fixedsamplelocations);
void APIENTRY glTextureSubImage1D(GLuint texture, GLint level, GLint xoffset, GLsizei width, GLenum format, GLenum type, const void* pixels);
void APIENTRY glTextureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const void* pixels);
void APIENTRY glTextureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type, const void* pixels);
void APIENTRY glTextureBuffer(GLuint texture, GLenum internalformat, GLuint buffer);
void APIENTRY glTextureBufferRange(GLuint texture, GLenum internalformat, GLuint buffer, GLintptr offset, GLsizeiptr size);
void APIENTRY glCompressedTextureSubImage1D(GLuint texture, GLint level, GLint xoffset, GLsizei width, GLenum format, GLsizei imageSize, const void* data);
void APIENTRY glCompressedTextureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLsizei imageSize, const void* data);
void APIENTRY glCompressedTextureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLsizei imageSize, const void* data);
void APIENTRY glCopyTextureSubImage1D(GLuint texture, GLint level, GLint xoffset, GLint x, GLint y, GLsizei width);
void APIENTRY glCopyTextureSubImage2D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width, GLsizei height);
void APIENTRY glCopyTextureSubImage3D(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLint x, GLint y, GLsizei width, GLsizei height);
void APIENTRY glTextureParameterf(GLuint texture, GLenum pname, GLfloat param);
void APIENTRY glTextureParameterfv(GLuint texture, GLenum pname, const GLfloat* param);
void APIENTRY glTextureParameteri(GLuint texture, GLenum pname, GLint param);
void APIENTRY glTextureParameteriv(GLuint texture, GLenum pname, const GLint* param);
void APIENTRY glTextureParameterIiv(GLuint texture, GLenum pname, const GLint* params);
void APIENTRY glTextureParameterIuiv(GLuint texture, GLenum pname, const GLuint* params);
void APIENTRY glTexturePageCommitmentEXT(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset, GLsizei width, GLsizei height, GLsizei depth, GLboolean commit);
void APIENTRY glGetTextureParameterfv(GLuint texture, GLenum pname, GLfloat* params);
void APIENTRY glGetTextureParameteriv(GLuint texture, GLenum pname, GLint* params);
void APIENTRY glGetTextureParameterIiv(GLuint texture, GLenum pname, GLint* params);
void APIENTRY glGetTextureParameterIuiv(GLuint texture, GLenum pname, GLuint* params);
void APIENTRY glGetTextureLevelParameterfv(GLuint texture, GLint level, GLenum pname, GLfloat* params);
void APIENTRY glGetTextureLevelParameteriv(GLuint texture, GLint level, GLenum pname, GLint* params);
void APIENTRY glGetTextureImage(GLuint texture, GLint level, GLenum format, GLenum type, GLsizei bufSize, void* pixels);
void APIENTRY glGetTextureSubImage(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
                                    GLsizei width, GLsizei height, GLsizei depth,
                                    GLenum format, GLenum type, GLsizei bufSize, void* pixels);
void APIENTRY glGetCompressedTextureImage(GLuint texture, GLint level, GLsizei bufSize, void* pixels);
void APIENTRY glGetCompressedTextureSubImage(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
                                              GLsizei width, GLsizei height, GLsizei depth,
                                              GLsizei bufSize, void* pixels);
void APIENTRY glGenerateTextureMipmap(GLuint texture);
void APIENTRY glBindTextureUnit(GLuint unit, GLuint texture);
// Pass C — DSA framebuffer / renderbuffer / vertex array / transform feedback (38 functions)
void APIENTRY glNamedFramebufferRenderbuffer(GLuint framebuffer, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer);
void APIENTRY glNamedFramebufferTexture(GLuint framebuffer, GLenum attachment, GLuint texture, GLint level);
void APIENTRY glNamedFramebufferTextureLayer(GLuint framebuffer, GLenum attachment, GLuint texture, GLint level, GLint layer);
void APIENTRY glNamedFramebufferDrawBuffer(GLuint framebuffer, GLenum buf);
void APIENTRY glNamedFramebufferDrawBuffers(GLuint framebuffer, GLsizei n, const GLenum* bufs);
void APIENTRY glNamedFramebufferReadBuffer(GLuint framebuffer, GLenum src);
void APIENTRY glNamedFramebufferParameteri(GLuint framebuffer, GLenum pname, GLint param);
void APIENTRY glGetNamedFramebufferParameteriv(GLuint framebuffer, GLenum pname, GLint* param);
void APIENTRY glGetNamedFramebufferAttachmentParameteriv(GLuint framebuffer, GLenum attachment, GLenum pname, GLint* params);
GLenum APIENTRY glCheckNamedFramebufferStatus(GLuint framebuffer, GLenum target);
void APIENTRY glBlitNamedFramebuffer(GLuint readFramebuffer, GLuint drawFramebuffer,
                                     GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1,
                                     GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1,
                                     GLbitfield mask, GLenum filter);
void APIENTRY glClearNamedFramebufferfv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLfloat* value);
void APIENTRY glClearNamedFramebufferiv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLint* value);
void APIENTRY glClearNamedFramebufferuiv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLuint* value);
void APIENTRY glClearNamedFramebufferfi(GLuint framebuffer, GLenum buffer, GLint drawbuffer, GLfloat depth, GLint stencil);
void APIENTRY glInvalidateNamedFramebufferData(GLuint framebuffer, GLsizei numAttachments, const GLenum* attachments);
void APIENTRY glInvalidateNamedFramebufferSubData(GLuint framebuffer, GLsizei numAttachments, const GLenum* attachments,
                                                   GLint x, GLint y, GLsizei width, GLsizei height);
void APIENTRY glNamedRenderbufferStorage(GLuint renderbuffer, GLenum internalformat, GLsizei width, GLsizei height);
void APIENTRY glNamedRenderbufferStorageMultisample(GLuint renderbuffer, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height);
void APIENTRY glGetNamedRenderbufferParameteriv(GLuint renderbuffer, GLenum pname, GLint* params);
void APIENTRY glVertexArrayAttribFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLboolean normalized, GLuint relativeoffset);
void APIENTRY glVertexArrayAttribIFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset);
void APIENTRY glVertexArrayAttribLFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset);
void APIENTRY glVertexArrayAttribBinding(GLuint vaobj, GLuint attribindex, GLuint bindingindex);
void APIENTRY glVertexArrayBindingDivisor(GLuint vaobj, GLuint bindingindex, GLuint divisor);
void APIENTRY glVertexArrayVertexBuffer(GLuint vaobj, GLuint bindingindex, GLuint buffer, GLintptr offset, GLsizei stride);
void APIENTRY glVertexArrayVertexBuffers(GLuint vaobj, GLuint first, GLsizei count, const GLuint* buffers, const GLintptr* offsets, const GLsizei* strides);
void APIENTRY glVertexArrayElementBuffer(GLuint vaobj, GLuint buffer);
void APIENTRY glEnableVertexArrayAttrib(GLuint vaobj, GLuint index);
void APIENTRY glDisableVertexArrayAttrib(GLuint vaobj, GLuint index);
void APIENTRY glGetVertexArrayiv(GLuint vaobj, GLenum pname, GLint* param);
void APIENTRY glGetVertexArrayIndexediv(GLuint vaobj, GLuint index, GLenum pname, GLint* param);
void APIENTRY glGetVertexArrayIndexed64iv(GLuint vaobj, GLuint index, GLenum pname, GLint64* param);
void APIENTRY glTransformFeedbackBufferBase(GLuint xfb, GLuint index, GLuint buffer);
void APIENTRY glTransformFeedbackBufferRange(GLuint xfb, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size);
void APIENTRY glGetTransformFeedbackiv(GLuint xfb, GLenum pname, GLint* param);
void APIENTRY glGetTransformFeedbacki_v(GLuint xfb, GLenum pname, GLuint index, GLint* param);
void APIENTRY glGetTransformFeedbacki64_v(GLuint xfb, GLenum pname, GLuint index, GLint64* param);
// Pass D — ClipControl, robustness, barriers, query buffer objects (15 functions)
void APIENTRY glClipControl(GLenum origin, GLenum depth);
GLenum APIENTRY glGetGraphicsResetStatus(void);
void APIENTRY glReadnPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, GLsizei bufSize, void* data);
void APIENTRY glGetnUniformfv(GLuint program, GLint location, GLsizei bufSize, GLfloat* params);
void APIENTRY glGetnUniformiv(GLuint program, GLint location, GLsizei bufSize, GLint* params);
void APIENTRY glGetnUniformuiv(GLuint program, GLint location, GLsizei bufSize, GLuint* params);
void APIENTRY glGetnUniformdv(GLuint program, GLint location, GLsizei bufSize, GLdouble* params);
void APIENTRY glGetnTexImage(GLenum target, GLint level, GLenum format, GLenum type, GLsizei bufSize, void* pixels);
void APIENTRY glGetnCompressedTexImage(GLenum target, GLint lod, GLsizei bufSize, void* pixels);
void APIENTRY glMemoryBarrierByRegion(GLbitfield barriers);
void APIENTRY glTextureBarrier(void);
void APIENTRY glGetQueryBufferObjectiv(GLuint id, GLuint buffer, GLenum pname, GLintptr offset);
void APIENTRY glGetQueryBufferObjectuiv(GLuint id, GLuint buffer, GLenum pname, GLintptr offset);
void APIENTRY glGetQueryBufferObjecti64v(GLuint id, GLuint buffer, GLenum pname, GLintptr offset);
void APIENTRY glGetQueryBufferObjectui64v(GLuint id, GLuint buffer, GLenum pname, GLintptr offset);
// Pass E — GL 4.6 (4 functions)
void APIENTRY glMultiDrawArraysIndirectCount(GLenum mode, const void* indirect, GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride);
void APIENTRY glMultiDrawElementsIndirectCount(GLenum mode, GLenum type, const void* indirect, GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride);
void APIENTRY glSpecializeShader(GLuint shader, const GLchar* pEntryPoint, GLuint numSpecializationConstants, const GLuint* pConstantIndex, const GLuint* pConstantValue);
void APIENTRY glPolygonOffsetClamp(GLfloat factor, GLfloat units, GLfloat clamp);
}  // namespace impl

class Runtime {
public:
    static Runtime& shared();

    GLDispatchTable& dispatch();
    const GLDispatchTable& dispatch() const;

    void recordFunctionInvocation(FunctionId id, std::string_view functionName);
    void recordBootstrapTrace(std::string message);
    void recordUnimplemented(FunctionId id, std::string_view functionName);

    // Landing C 3e: fixed-function compat-profile entry points (matrix
    // stack, immediate mode, display lists, glBegin/glEnd, ...) resolve
    // to no-op stubs that call this. The stubs don't have a FunctionId
    // (they're not part of AppGL's core 4.6 manifest) so we can't route
    // through recordUnimplemented. Instead we push a diagnostic-only
    // error record with errorEnum = 0, letting the ring-buffer dedupe
    // suppress per-frame spam while still surfacing the stub name so
    // tooling can flag which legacy calls a client is touching.
    void recordFixedFunctionStub(std::string_view functionName);

    void makeCurrent(GLContext* context);
    GLContext* currentContext();

    // Context liveness tracking. Every GLContext registers itself in construction
    // and unregisters in destruction. Callers that want to inspect the current
    // context from another thread (e.g. the diagnostics JSON refresh) can hold
    // contextMutex() for the duration of the access, guaranteeing that an
    // unregister cannot race with the read.
    void registerContext(GLContext* context);
    void unregisterContext(GLContext* context);
    bool isContextLiveLocked(GLContext* context) const;
    std::mutex& contextMutex();
    std::string claimedVersionString() const;
    void refreshCurrentContextClaimedVersion();

    void noteRenderer(std::string renderer);
    std::size_t writeCoverageSnapshotJSON(char* out, std::size_t cap);
    std::size_t writeDiagnosticsJSON(char* out, std::size_t cap);
    // Lightweight end-of-frame diagnostics poll. Emits pipeline cache metrics,
    // shader translation log, and error log only — no object-store walk, no
    // byte accounting. Designed to be safe to call every frame from an engine
    // integration hook without paying the O(N) inventory cost of the full
    // diagnostics dump. The locks held are: contextMutex_ (briefly, to read
    // pipeline metrics), then released; translationMutex_; errorLogMutex_.
    // Lock ordering is not nested, so this entry point cannot deadlock against
    // any entry point that takes those locks in a different order.
    std::size_t writeLiveDiagnosticsJSON(char* out, std::size_t cap);

    CoverageStore& coverageStore();
    TraceLog& traceLog();

    // Shader translation diagnostics. Called from GLContext::linkProgram() and
    // GLContext::compileShader().
    //
    // `sourceHash` carries the per-stage source hash for compile-stage and
    // per-stage link records, and is intentionally empty for whole-program
    // failure records (e.g. "no shaders attached") that don't have a single
    // stage to point at.
    //
    // `vertexSourceHash` / `fragmentSourceHash` are populated on every
    // link-stage record produced by linkProgram for a raster program (vertex,
    // fragment, vertex+fragment, vertex+geometry+fragment, vertex+tess+fragment),
    // so a single stage record is self-contained: BAR-side tooling can map a
    // vertex-stage record to its predecessor compile-stage record by hash
    // without searching backwards through the ring (which can wrap and evict
    // the compile entry before the link record lands). They stay empty for
    // compile-stage records (which are pushed before the program-level link
    // call where the pairing is established) and for compute-only programs
    // (no raster pair).
    struct ShaderTranslationRecord {
        std::string id;       // e.g. "program-3-vertex"
        std::string stage;    // "vertex" or "fragment"
        std::string sourceHash;
        std::string vertexSourceHash;
        std::string fragmentSourceHash;
        std::string glslangLog;
        std::string mslPreview; // first ~200 chars of MSL
        bool success = false;
    };
    void recordShaderTranslation(ShaderTranslationRecord record);

    // Monotonic lifetime counter of how many shader translation records have
    // been pushed since process start, and a read-only snapshot of the bounded
    // ring buffer that stores the most recent entries. Used by the gauntlet
    // diagnostics tests to assert that recordShaderTranslation fires on every
    // link attempt.
    //
    // `shaderTranslationCount()` is a lifetime push counter, *not* the size of
    // the ring — the ring is capped at 32 entries so tests that compare
    // "before vs. after" counts get a meaningful delta even after the ring
    // has wrapped. Callers that want the current ring size should use
    // `shaderTranslationSnapshot().size()` instead.
    //
    // The snapshot is a copy (taken under the lock) so callers don't need to
    // worry about the ring mutating under them while they iterate.
    std::uint64_t shaderTranslationCount();
    std::vector<ShaderTranslationRecord> shaderTranslationSnapshot();

    // Error log. A ring buffer of recent GL error events (validation failures,
    // unimplemented-entry-point hits, backend errors). Surfaced in the diagnostic
    // JSON so external tooling can diagnose AppGL-internal problems — the
    // engine-facing glGetError() queue only carries enums, not context.
    //
    // Consecutive duplicate entries collapse into a single record with a bumped
    // `count` field so spammy stub paths cannot wipe the ring in one frame.
    struct ErrorRecord {
        std::string function;
        GLenum errorEnum = 0;
        std::string message;
        std::uint64_t count = 1;
    };
    void recordError(ErrorRecord record);

    // Monotonic lifetime counter of recordError() calls, and a read-only
    // snapshot of the 64-entry ring buffer. Used by the gauntlet Landing C
    // 3g assertions that verify raised errors actually reach the ring
    // buffer — not just the per-context glGetError queue.
    //
    // `errorLogCount()` returns the *event* count, not the ring size. Every
    // recordError() call bumps the counter, including the dedupe path that
    // only bumps the back entry's `count` field without appending a new
    // record. Two distinct failure modes would otherwise break a
    // "after > before" assertion on `errorLogSnapshot().size()`:
    //   - Ring saturation: push + erase leaves the size unchanged.
    //   - Dedupe collapse: same function + errorEnum as the back entry
    //     merges into it without growing the ring at all.
    // A lifetime event counter is robust to both. Callers that genuinely
    // want the current ring size should use errorLogSnapshot().size().
    //
    // The snapshot is a copy taken under errorLogMutex_ so callers don't
    // have to worry about concurrent mutation.
    std::uint64_t errorLogCount();
    std::vector<ErrorRecord> errorLogSnapshot();

    // Last-known object-store inventory for the most recently destroyed context.
    // Captured inside unregisterContext() so post-mortem diagnostics dumps (fired
    // from DestroyWindowAndContext on the engine side) can report what the
    // context actually held just before teardown instead of a ream of zeros.
    struct InventorySnapshot {
        bool valid = false;
        std::size_t buffers = 0;
        std::size_t textures = 0;
        std::size_t samplers = 0;
        std::size_t renderbuffers = 0;
        std::size_t framebuffers = 0;
        std::size_t vertexArrays = 0;
        std::size_t shaders = 0;
        std::size_t programs = 0;
        std::size_t queries = 0;
        std::size_t syncs = 0;
        std::size_t transformFeedbacks = 0;
        std::uint64_t bufferBytes = 0;
        std::uint64_t textureBytes = 0;
        std::uint64_t renderbufferBytes = 0;
        std::uint64_t pipelineCacheHits = 0;
        std::uint64_t pipelineCacheMisses = 0;
        // Phase 8X Group 4d follow-up⁴ — split the build counters so the
        // {hits:0,misses:0} state is unambiguous between "never tried to
        // build" (attempts==0) and "tried every time and failed every time"
        // (attempts>0, failures==attempts, misses==0). Invariant after every
        // draw: attempts == misses + failures.
        std::uint64_t pipelineBuildAttempts = 0;
        std::uint64_t pipelineBuildFailures = 0;
        double pipelineCumulativeBuildMillis = 0.0;
    };

private:
    Runtime();
    void initializeDispatch();
    // Must be called with contextMutex_ held, and with `context` still pointing
    // at a live, fully-constructed GLContext. Refreshes lastKnownInventory_.
    void snapshotContextInventoryLocked(GLContext* context);

    GLDispatchTable dispatch_;
    CoverageStore coverageStore_;
    TraceLog traceLog_;
    std::string rendererString_ = "AppGL on Metal";
    mutable std::mutex contextMutex_;
    std::unordered_set<GLContext*> liveContexts_;
    std::mutex translationMutex_;
    std::vector<ShaderTranslationRecord> shaderTranslations_;
    std::uint64_t shaderTranslationsEverPushed_ = 0;
    std::mutex errorLogMutex_;
    std::vector<ErrorRecord> errorLog_;
    std::uint64_t errorLogEventsObserved_ = 0;
    InventorySnapshot lastKnownInventory_;
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
