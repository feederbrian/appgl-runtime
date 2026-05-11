#include "DispatchInstall.h"

#include "../runtime/AppGLRuntime.h"

namespace appgl {

void installBootstrapDispatch(GLDispatchTable& dispatch, CoverageStore& coverage) {
    dispatch.glClearColor = &impl::glClearColor;
    dispatch.glDrawBuffer = &impl::glDrawBuffer;
    dispatch.glClear = &impl::glClear;
    dispatch.glClearDepth = &impl::glClearDepth;
    dispatch.glClearStencil = &impl::glClearStencil;
    dispatch.glViewport = &impl::glViewport;
    dispatch.glFlush = &impl::glFlush;
    dispatch.glReadPixels = &impl::glReadPixels;
    dispatch.glGetBooleanv = &impl::glGetBooleanv;
    dispatch.glGetIntegerv = &impl::glGetIntegerv;
    dispatch.glGetInteger64v = &impl::glGetInteger64v;
    dispatch.glGetFloatv = &impl::glGetFloatv;
    dispatch.glGetDoublev = &impl::glGetDoublev;
    dispatch.glGenBuffers = &impl::glGenBuffers;
    dispatch.glDeleteBuffers = &impl::glDeleteBuffers;
    dispatch.glIsBuffer = &impl::glIsBuffer;
    dispatch.glBindBuffer = &impl::glBindBuffer;
    dispatch.glBindBufferBase = &impl::glBindBufferBase;
    dispatch.glBindBufferRange = &impl::glBindBufferRange;
    dispatch.glBufferData = &impl::glBufferData;
    dispatch.glBufferSubData = &impl::glBufferSubData;
    dispatch.glCopyBufferSubData = &impl::glCopyBufferSubData;
    dispatch.glGetBufferSubData = &impl::glGetBufferSubData;
    dispatch.glMapBuffer = &impl::glMapBuffer;
    dispatch.glMapBufferRange = &impl::glMapBufferRange;
    dispatch.glUnmapBuffer = &impl::glUnmapBuffer;
    dispatch.glFlushMappedBufferRange = &impl::glFlushMappedBufferRange;
    dispatch.glGetBufferParameteriv = &impl::glGetBufferParameteriv;
    dispatch.glGetBufferParameteri64v = &impl::glGetBufferParameteri64v;
    dispatch.glGetBufferPointerv = &impl::glGetBufferPointerv;
    dispatch.glGenVertexArrays = &impl::glGenVertexArrays;
    dispatch.glDeleteVertexArrays = &impl::glDeleteVertexArrays;
    dispatch.glIsVertexArray = &impl::glIsVertexArray;
    dispatch.glBindVertexArray = &impl::glBindVertexArray;
    dispatch.glEnableVertexAttribArray = &impl::glEnableVertexAttribArray;
    dispatch.glDisableVertexAttribArray = &impl::glDisableVertexAttribArray;
    dispatch.glVertexAttribPointer = &impl::glVertexAttribPointer;
    dispatch.glVertexAttribIPointer = &impl::glVertexAttribIPointer;
    dispatch.glVertexAttribDivisor = &impl::glVertexAttribDivisor;
    // GL 4.3 — separated vertex format (ARB_vertex_attrib_binding).
    dispatch.glBindVertexBuffer = &impl::glBindVertexBuffer;
    dispatch.glVertexAttribFormat = &impl::glVertexAttribFormat;
    dispatch.glVertexAttribIFormat = &impl::glVertexAttribIFormat;
    dispatch.glVertexAttribLFormat = &impl::glVertexAttribLFormat;
    dispatch.glVertexAttribBinding = &impl::glVertexAttribBinding;
    dispatch.glVertexBindingDivisor = &impl::glVertexBindingDivisor;
    dispatch.glGetVertexAttribiv = &impl::glGetVertexAttribiv;
    dispatch.glGetVertexAttribfv = &impl::glGetVertexAttribfv;
    dispatch.glGetVertexAttribPointerv = &impl::glGetVertexAttribPointerv;
    dispatch.glActiveTexture = &impl::glActiveTexture;
    dispatch.glGenTextures = &impl::glGenTextures;
    dispatch.glDeleteTextures = &impl::glDeleteTextures;
    dispatch.glIsTexture = &impl::glIsTexture;
    dispatch.glBindTexture = &impl::glBindTexture;
    dispatch.glTexImage1D = &impl::glTexImage1D;
    dispatch.glTexImage2D = &impl::glTexImage2D;
    dispatch.glTexImage3D = &impl::glTexImage3D;
    dispatch.glTexSubImage1D = &impl::glTexSubImage1D;
    dispatch.glTexSubImage2D = &impl::glTexSubImage2D;
    dispatch.glTexSubImage3D = &impl::glTexSubImage3D;
    dispatch.glTexParameteri = &impl::glTexParameteri;
    dispatch.glTexParameteriv = &impl::glTexParameteriv;
    dispatch.glTexParameterf = &impl::glTexParameterf;
    dispatch.glTexParameterfv = &impl::glTexParameterfv;
    dispatch.glTexParameterIiv = &impl::glTexParameterIiv;
    dispatch.glTexParameterIuiv = &impl::glTexParameterIuiv;
    dispatch.glGetTexParameteriv = &impl::glGetTexParameteriv;
    dispatch.glGetTexParameterfv = &impl::glGetTexParameterfv;
    dispatch.glGetTexParameterIiv = &impl::glGetTexParameterIiv;
    dispatch.glGetTexParameterIuiv = &impl::glGetTexParameterIuiv;
    dispatch.glGenerateMipmap = &impl::glGenerateMipmap;
    dispatch.glTexStorage1D = &impl::glTexStorage1D;
    dispatch.glTexStorage2D = &impl::glTexStorage2D;
    dispatch.glTexStorage3D = &impl::glTexStorage3D;
    dispatch.glTexStorage2DMultisample = &impl::glTexStorage2DMultisample;
    dispatch.glTexStorage3DMultisample = &impl::glTexStorage3DMultisample;
    dispatch.glTexPageCommitmentARB = &impl::glTexPageCommitmentARB;
    dispatch.glTexBufferRange = &impl::glTexBufferRange;
    dispatch.glPixelStorei = &impl::glPixelStorei;
    dispatch.glPixelStoref = &impl::glPixelStoref;
    dispatch.glReadBuffer = &impl::glReadBuffer;
    dispatch.glDrawBuffers = &impl::glDrawBuffers;
    dispatch.glIsRenderbuffer = &impl::glIsRenderbuffer;
    dispatch.glBindRenderbuffer = &impl::glBindRenderbuffer;
    dispatch.glDeleteRenderbuffers = &impl::glDeleteRenderbuffers;
    dispatch.glGenRenderbuffers = &impl::glGenRenderbuffers;
    dispatch.glRenderbufferStorage = &impl::glRenderbufferStorage;
    dispatch.glGetRenderbufferParameteriv = &impl::glGetRenderbufferParameteriv;
    dispatch.glGenFramebuffers = &impl::glGenFramebuffers;
    dispatch.glDeleteFramebuffers = &impl::glDeleteFramebuffers;
    dispatch.glIsFramebuffer = &impl::glIsFramebuffer;
    dispatch.glBindFramebuffer = &impl::glBindFramebuffer;
    dispatch.glCheckFramebufferStatus = &impl::glCheckFramebufferStatus;
    dispatch.glFramebufferTexture1D = &impl::glFramebufferTexture1D;
    dispatch.glFramebufferTexture2D = &impl::glFramebufferTexture2D;
    dispatch.glFramebufferTexture3D = &impl::glFramebufferTexture3D;
    dispatch.glFramebufferRenderbuffer = &impl::glFramebufferRenderbuffer;
    dispatch.glBlitFramebuffer = &impl::glBlitFramebuffer;
    dispatch.glGetFramebufferAttachmentParameteriv = &impl::glGetFramebufferAttachmentParameteriv;
    dispatch.glRenderbufferStorageMultisample = &impl::glRenderbufferStorageMultisample;
    dispatch.glFramebufferTextureLayer = &impl::glFramebufferTextureLayer;
    dispatch.glFramebufferTexture = &impl::glFramebufferTexture;
    dispatch.glGenSamplers = &impl::glGenSamplers;
    dispatch.glDeleteSamplers = &impl::glDeleteSamplers;
    dispatch.glIsSampler = &impl::glIsSampler;
    dispatch.glBindSampler = &impl::glBindSampler;
    dispatch.glSamplerParameteri = &impl::glSamplerParameteri;
    dispatch.glSamplerParameteriv = &impl::glSamplerParameteriv;
    dispatch.glSamplerParameterf = &impl::glSamplerParameterf;
    dispatch.glSamplerParameterfv = &impl::glSamplerParameterfv;
    dispatch.glSamplerParameterIiv = &impl::glSamplerParameterIiv;
    dispatch.glSamplerParameterIuiv = &impl::glSamplerParameterIuiv;
    dispatch.glGetSamplerParameteriv = &impl::glGetSamplerParameteriv;
    dispatch.glGetSamplerParameterfv = &impl::glGetSamplerParameterfv;
    dispatch.glGetSamplerParameterIiv = &impl::glGetSamplerParameterIiv;
    dispatch.glGetSamplerParameterIuiv = &impl::glGetSamplerParameterIuiv;
    dispatch.glEnable = &impl::glEnable;
    dispatch.glDisable = &impl::glDisable;
    dispatch.glIsEnabled = &impl::glIsEnabled;
    dispatch.glScissor = &impl::glScissor;
    dispatch.glDepthRange = &impl::glDepthRange;
    dispatch.glDepthRangef = &impl::glDepthRangef;
    dispatch.glBlendFunc = &impl::glBlendFunc;
    dispatch.glBlendFuncSeparate = &impl::glBlendFuncSeparate;
    dispatch.glBlendFunci = &impl::glBlendFunci;
    dispatch.glBlendFuncSeparatei = &impl::glBlendFuncSeparatei;
    dispatch.glBlendEquation = &impl::glBlendEquation;
    dispatch.glBlendEquationSeparate = &impl::glBlendEquationSeparate;
    dispatch.glBlendEquationi = &impl::glBlendEquationi;
    dispatch.glBlendEquationSeparatei = &impl::glBlendEquationSeparatei;
    dispatch.glMinSampleShading = &impl::glMinSampleShading;
    dispatch.glBlendColor = &impl::glBlendColor;
    dispatch.glColorMask = &impl::glColorMask;
    dispatch.glColorMaski = &impl::glColorMaski;
    dispatch.glDepthFunc = &impl::glDepthFunc;
    dispatch.glDepthMask = &impl::glDepthMask;
    dispatch.glStencilFunc = &impl::glStencilFunc;
    dispatch.glStencilFuncSeparate = &impl::glStencilFuncSeparate;
    dispatch.glStencilOp = &impl::glStencilOp;
    dispatch.glStencilOpSeparate = &impl::glStencilOpSeparate;
    dispatch.glStencilMask = &impl::glStencilMask;
    dispatch.glStencilMaskSeparate = &impl::glStencilMaskSeparate;
    dispatch.glCullFace = &impl::glCullFace;
    dispatch.glFrontFace = &impl::glFrontFace;
    dispatch.glPolygonOffset = &impl::glPolygonOffset;
    dispatch.glLineWidth = &impl::glLineWidth;
    dispatch.glPointSize = &impl::glPointSize;
    dispatch.glHint = &impl::glHint;
    dispatch.glGetString = &impl::glGetString;
    dispatch.glGetError = &impl::glGetError;
    dispatch.glDebugMessageControl = &impl::glDebugMessageControl;
    dispatch.glDebugMessageInsert = &impl::glDebugMessageInsert;
    dispatch.glDebugMessageCallback = &impl::glDebugMessageCallback;
    dispatch.glGetDebugMessageLog = &impl::glGetDebugMessageLog;
    dispatch.glPushDebugGroup = &impl::glPushDebugGroup;
    dispatch.glPopDebugGroup = &impl::glPopDebugGroup;
    dispatch.glObjectLabel = &impl::glObjectLabel;
    dispatch.glGetObjectLabel = &impl::glGetObjectLabel;
    dispatch.glObjectPtrLabel = &impl::glObjectPtrLabel;
    dispatch.glGetObjectPtrLabel = &impl::glGetObjectPtrLabel;
    dispatch.glGetPointerv = &impl::glGetPointerv;

    dispatch.glCreateShader = &impl::glCreateShader;
    dispatch.glDeleteShader = &impl::glDeleteShader;
    dispatch.glIsShader = &impl::glIsShader;
    dispatch.glShaderSource = &impl::glShaderSource;
    dispatch.glCompileShader = &impl::glCompileShader;
    dispatch.glGetShaderiv = &impl::glGetShaderiv;
    dispatch.glGetShaderInfoLog = &impl::glGetShaderInfoLog;
    dispatch.glGetShaderSource = &impl::glGetShaderSource;
    dispatch.glCreateProgram = &impl::glCreateProgram;
    dispatch.glDeleteProgram = &impl::glDeleteProgram;
    dispatch.glIsProgram = &impl::glIsProgram;
    dispatch.glAttachShader = &impl::glAttachShader;
    dispatch.glDetachShader = &impl::glDetachShader;
    dispatch.glLinkProgram = &impl::glLinkProgram;
    dispatch.glUseProgram = &impl::glUseProgram;
    dispatch.glValidateProgram = &impl::glValidateProgram;
    dispatch.glGetProgramiv = &impl::glGetProgramiv;
    dispatch.glGetProgramInfoLog = &impl::glGetProgramInfoLog;
    dispatch.glGetAttachedShaders = &impl::glGetAttachedShaders;
    dispatch.glBindAttribLocation = &impl::glBindAttribLocation;
    dispatch.glGetAttribLocation = &impl::glGetAttribLocation;
    dispatch.glGetActiveAttrib = &impl::glGetActiveAttrib;
    dispatch.glGetUniformLocation = &impl::glGetUniformLocation;
    dispatch.glGetActiveUniform = &impl::glGetActiveUniform;
    dispatch.glGetUniformfv = &impl::glGetUniformfv;
    dispatch.glGetUniformiv = &impl::glGetUniformiv;
    dispatch.glGetUniformuiv = &impl::glGetUniformuiv;
    dispatch.glUniform1f = &impl::glUniform1f;
    dispatch.glUniform2f = &impl::glUniform2f;
    dispatch.glUniform3f = &impl::glUniform3f;
    dispatch.glUniform4f = &impl::glUniform4f;
    dispatch.glUniform1i = &impl::glUniform1i;
    dispatch.glUniform2i = &impl::glUniform2i;
    dispatch.glUniform3i = &impl::glUniform3i;
    dispatch.glUniform4i = &impl::glUniform4i;
    dispatch.glUniform1ui = &impl::glUniform1ui;
    dispatch.glUniform2ui = &impl::glUniform2ui;
    dispatch.glUniform3ui = &impl::glUniform3ui;
    dispatch.glUniform4ui = &impl::glUniform4ui;
    dispatch.glUniform1fv = &impl::glUniform1fv;
    dispatch.glUniform2fv = &impl::glUniform2fv;
    dispatch.glUniform3fv = &impl::glUniform3fv;
    dispatch.glUniform4fv = &impl::glUniform4fv;
    dispatch.glUniform1iv = &impl::glUniform1iv;
    dispatch.glUniform2iv = &impl::glUniform2iv;
    dispatch.glUniform3iv = &impl::glUniform3iv;
    dispatch.glUniform4iv = &impl::glUniform4iv;
    dispatch.glUniform1uiv = &impl::glUniform1uiv;
    dispatch.glUniform2uiv = &impl::glUniform2uiv;
    dispatch.glUniform3uiv = &impl::glUniform3uiv;
    dispatch.glUniform4uiv = &impl::glUniform4uiv;
    dispatch.glUniformMatrix2fv = &impl::glUniformMatrix2fv;
    dispatch.glUniformMatrix3fv = &impl::glUniformMatrix3fv;
    dispatch.glUniformMatrix4fv = &impl::glUniformMatrix4fv;
    // GL 4.0 double-precision uniform setters (f64→f32 narrowing).
    dispatch.glGetUniformdv = &impl::glGetUniformdv;
    dispatch.glUniform1d = &impl::glUniform1d;
    dispatch.glUniform2d = &impl::glUniform2d;
    dispatch.glUniform3d = &impl::glUniform3d;
    dispatch.glUniform4d = &impl::glUniform4d;
    dispatch.glUniform1dv = &impl::glUniform1dv;
    dispatch.glUniform2dv = &impl::glUniform2dv;
    dispatch.glUniform3dv = &impl::glUniform3dv;
    dispatch.glUniform4dv = &impl::glUniform4dv;
    dispatch.glUniformMatrix2dv = &impl::glUniformMatrix2dv;
    dispatch.glUniformMatrix3dv = &impl::glUniformMatrix3dv;
    dispatch.glUniformMatrix4dv = &impl::glUniformMatrix4dv;
    dispatch.glUniformMatrix2x3dv = &impl::glUniformMatrix2x3dv;
    dispatch.glUniformMatrix2x4dv = &impl::glUniformMatrix2x4dv;
    dispatch.glUniformMatrix3x2dv = &impl::glUniformMatrix3x2dv;
    dispatch.glUniformMatrix3x4dv = &impl::glUniformMatrix3x4dv;
    dispatch.glUniformMatrix4x2dv = &impl::glUniformMatrix4x2dv;
    dispatch.glUniformMatrix4x3dv = &impl::glUniformMatrix4x3dv;
    dispatch.glDrawArrays = &impl::glDrawArrays;
    dispatch.glDrawElements = &impl::glDrawElements;
    // GL 4.0 — tessellation patch parameters (Group 7).
    dispatch.glPatchParameteri = &impl::glPatchParameteri;
    dispatch.glPatchParameterfv = &impl::glPatchParameterfv;
    // GL 4.0 — indexed queries (Group 5).
    dispatch.glBeginQueryIndexed = &impl::glBeginQueryIndexed;
    dispatch.glEndQueryIndexed = &impl::glEndQueryIndexed;
    dispatch.glGetQueryIndexediv = &impl::glGetQueryIndexediv;
    // GL 4.1 — viewport/scissor/depth arrays (Group 8).
    dispatch.glViewportArrayv = &impl::glViewportArrayv;
    dispatch.glViewportIndexedf = &impl::glViewportIndexedf;
    dispatch.glViewportIndexedfv = &impl::glViewportIndexedfv;
    dispatch.glScissorArrayv = &impl::glScissorArrayv;
    dispatch.glScissorIndexed = &impl::glScissorIndexed;
    dispatch.glScissorIndexedv = &impl::glScissorIndexedv;
    dispatch.glDepthRangeArrayv = &impl::glDepthRangeArrayv;
    dispatch.glDepthRangeIndexed = &impl::glDepthRangeIndexed;
    dispatch.glGetFloati_v = &impl::glGetFloati_v;
    dispatch.glGetDoublei_v = &impl::glGetDoublei_v;
    dispatch.glClearDepthf = &impl::glClearDepthf;
    // GL 4.1 — program uniforms (Group 10, 50 arities).
    dispatch.glProgramUniform1i = &impl::glProgramUniform1i;
    dispatch.glProgramUniform1iv = &impl::glProgramUniform1iv;
    dispatch.glProgramUniform1f = &impl::glProgramUniform1f;
    dispatch.glProgramUniform1fv = &impl::glProgramUniform1fv;
    dispatch.glProgramUniform1d = &impl::glProgramUniform1d;
    dispatch.glProgramUniform1dv = &impl::glProgramUniform1dv;
    dispatch.glProgramUniform1ui = &impl::glProgramUniform1ui;
    dispatch.glProgramUniform1uiv = &impl::glProgramUniform1uiv;
    dispatch.glProgramUniform2i = &impl::glProgramUniform2i;
    dispatch.glProgramUniform2iv = &impl::glProgramUniform2iv;
    dispatch.glProgramUniform2f = &impl::glProgramUniform2f;
    dispatch.glProgramUniform2fv = &impl::glProgramUniform2fv;
    dispatch.glProgramUniform2d = &impl::glProgramUniform2d;
    dispatch.glProgramUniform2dv = &impl::glProgramUniform2dv;
    dispatch.glProgramUniform2ui = &impl::glProgramUniform2ui;
    dispatch.glProgramUniform2uiv = &impl::glProgramUniform2uiv;
    dispatch.glProgramUniform3i = &impl::glProgramUniform3i;
    dispatch.glProgramUniform3iv = &impl::glProgramUniform3iv;
    dispatch.glProgramUniform3f = &impl::glProgramUniform3f;
    dispatch.glProgramUniform3fv = &impl::glProgramUniform3fv;
    dispatch.glProgramUniform3d = &impl::glProgramUniform3d;
    dispatch.glProgramUniform3dv = &impl::glProgramUniform3dv;
    dispatch.glProgramUniform3ui = &impl::glProgramUniform3ui;
    dispatch.glProgramUniform3uiv = &impl::glProgramUniform3uiv;
    dispatch.glProgramUniform4i = &impl::glProgramUniform4i;
    dispatch.glProgramUniform4iv = &impl::glProgramUniform4iv;
    dispatch.glProgramUniform4f = &impl::glProgramUniform4f;
    dispatch.glProgramUniform4fv = &impl::glProgramUniform4fv;
    dispatch.glProgramUniform4d = &impl::glProgramUniform4d;
    dispatch.glProgramUniform4dv = &impl::glProgramUniform4dv;
    dispatch.glProgramUniform4ui = &impl::glProgramUniform4ui;
    dispatch.glProgramUniform4uiv = &impl::glProgramUniform4uiv;
    dispatch.glProgramUniformMatrix2fv = &impl::glProgramUniformMatrix2fv;
    dispatch.glProgramUniformMatrix3fv = &impl::glProgramUniformMatrix3fv;
    dispatch.glProgramUniformMatrix4fv = &impl::glProgramUniformMatrix4fv;
    dispatch.glProgramUniformMatrix2dv = &impl::glProgramUniformMatrix2dv;
    dispatch.glProgramUniformMatrix3dv = &impl::glProgramUniformMatrix3dv;
    dispatch.glProgramUniformMatrix4dv = &impl::glProgramUniformMatrix4dv;
    dispatch.glProgramUniformMatrix2x3fv = &impl::glProgramUniformMatrix2x3fv;
    dispatch.glProgramUniformMatrix3x2fv = &impl::glProgramUniformMatrix3x2fv;
    dispatch.glProgramUniformMatrix2x4fv = &impl::glProgramUniformMatrix2x4fv;
    dispatch.glProgramUniformMatrix4x2fv = &impl::glProgramUniformMatrix4x2fv;
    dispatch.glProgramUniformMatrix3x4fv = &impl::glProgramUniformMatrix3x4fv;
    dispatch.glProgramUniformMatrix4x3fv = &impl::glProgramUniformMatrix4x3fv;
    dispatch.glProgramUniformMatrix2x3dv = &impl::glProgramUniformMatrix2x3dv;
    dispatch.glProgramUniformMatrix3x2dv = &impl::glProgramUniformMatrix3x2dv;
    dispatch.glProgramUniformMatrix2x4dv = &impl::glProgramUniformMatrix2x4dv;
    dispatch.glProgramUniformMatrix4x2dv = &impl::glProgramUniformMatrix4x2dv;
    dispatch.glProgramUniformMatrix3x4dv = &impl::glProgramUniformMatrix3x4dv;
    dispatch.glProgramUniformMatrix4x3dv = &impl::glProgramUniformMatrix4x3dv;
    // GL 4.1 — program/shader binary (Group 11).
    dispatch.glGetProgramBinary = &impl::glGetProgramBinary;
    dispatch.glProgramBinary = &impl::glProgramBinary;
    dispatch.glProgramParameteri = &impl::glProgramParameteri;
    dispatch.glShaderBinary = &impl::glShaderBinary;
    dispatch.glReleaseShaderCompiler = &impl::glReleaseShaderCompiler;
    // GL 4.1 — double-precision vertex attributes (Group 12).
    dispatch.glVertexAttribL1d = &impl::glVertexAttribL1d;
    dispatch.glVertexAttribL2d = &impl::glVertexAttribL2d;
    dispatch.glVertexAttribL3d = &impl::glVertexAttribL3d;
    dispatch.glVertexAttribL4d = &impl::glVertexAttribL4d;
    dispatch.glVertexAttribL1dv = &impl::glVertexAttribL1dv;
    dispatch.glVertexAttribL2dv = &impl::glVertexAttribL2dv;
    dispatch.glVertexAttribL3dv = &impl::glVertexAttribL3dv;
    dispatch.glVertexAttribL4dv = &impl::glVertexAttribL4dv;
    dispatch.glVertexAttribLPointer = &impl::glVertexAttribLPointer;
    dispatch.glGetVertexAttribLdv = &impl::glGetVertexAttribLdv;
    // GL 4.1 — shader precision (Group 13).
    dispatch.glGetShaderPrecisionFormat = &impl::glGetShaderPrecisionFormat;
    // GL 4.1 — program pipeline objects (Group 9).
    dispatch.glGenProgramPipelines = &impl::glGenProgramPipelines;
    dispatch.glDeleteProgramPipelines = &impl::glDeleteProgramPipelines;
    dispatch.glIsProgramPipeline = &impl::glIsProgramPipeline;
    dispatch.glBindProgramPipeline = &impl::glBindProgramPipeline;
    dispatch.glUseProgramStages = &impl::glUseProgramStages;
    dispatch.glActiveShaderProgram = &impl::glActiveShaderProgram;
    dispatch.glCreateShaderProgramv = &impl::glCreateShaderProgramv;
    dispatch.glValidateProgramPipeline = &impl::glValidateProgramPipeline;
    dispatch.glGetProgramPipelineiv = &impl::glGetProgramPipelineiv;
    dispatch.glGetProgramPipelineInfoLog = &impl::glGetProgramPipelineInfoLog;
    // GL 4.0 — subroutine uniforms (Group 3, stub-with-state).
    dispatch.glGetSubroutineUniformLocation = &impl::glGetSubroutineUniformLocation;
    dispatch.glGetSubroutineIndex = &impl::glGetSubroutineIndex;
    dispatch.glGetActiveSubroutineUniformiv = &impl::glGetActiveSubroutineUniformiv;
    dispatch.glGetActiveSubroutineUniformName = &impl::glGetActiveSubroutineUniformName;
    dispatch.glGetActiveSubroutineName = &impl::glGetActiveSubroutineName;
    dispatch.glUniformSubroutinesuiv = &impl::glUniformSubroutinesuiv;
    dispatch.glGetUniformSubroutineuiv = &impl::glGetUniformSubroutineuiv;
    dispatch.glGetProgramStageiv = &impl::glGetProgramStageiv;
    // GL 4.0 — transform feedback objects (Group 4).
    dispatch.glGenTransformFeedbacks = &impl::glGenTransformFeedbacks;
    dispatch.glDeleteTransformFeedbacks = &impl::glDeleteTransformFeedbacks;
    dispatch.glIsTransformFeedback = &impl::glIsTransformFeedback;
    dispatch.glBindTransformFeedback = &impl::glBindTransformFeedback;
    dispatch.glPauseTransformFeedback = &impl::glPauseTransformFeedback;
    dispatch.glResumeTransformFeedback = &impl::glResumeTransformFeedback;
    dispatch.glDrawTransformFeedback = &impl::glDrawTransformFeedback;
    dispatch.glDrawTransformFeedbackStream = &impl::glDrawTransformFeedbackStream;
    // GL 4.0 — indirect drawing (Group 6).
    dispatch.glDrawArraysIndirect = &impl::glDrawArraysIndirect;
    dispatch.glDrawElementsIndirect = &impl::glDrawElementsIndirect;
    // GL 4.2/4.3 — compute shaders and memory barriers.
    dispatch.glMemoryBarrier = &impl::glMemoryBarrier;
    dispatch.glDispatchCompute = &impl::glDispatchCompute;
    dispatch.glDispatchComputeIndirect = &impl::glDispatchComputeIndirect;
    // GL 4.2 — image load/store and atomic counters.
    dispatch.glBindImageTexture = &impl::glBindImageTexture;
    dispatch.glGetActiveAtomicCounterBufferiv = &impl::glGetActiveAtomicCounterBufferiv;
    // GL 4.3 — program resource introspection (ARB_program_interface_query).
    dispatch.glGetProgramInterfaceiv = &impl::glGetProgramInterfaceiv;
    dispatch.glGetProgramResourceiv = &impl::glGetProgramResourceiv;
    dispatch.glGetProgramResourceName = &impl::glGetProgramResourceName;
    dispatch.glGetProgramResourceIndex = &impl::glGetProgramResourceIndex;
    dispatch.glGetProgramResourceLocation = &impl::glGetProgramResourceLocation;
    dispatch.glGetProgramResourceLocationIndex = &impl::glGetProgramResourceLocationIndex;
    // GL 4.3 — SSBO binding remapping.
    dispatch.glShaderStorageBlockBinding = &impl::glShaderStorageBlockBinding;
    // GL 4.2 — advanced instanced drawing with base instance.
    dispatch.glDrawArraysInstancedBaseInstance = &impl::glDrawArraysInstancedBaseInstance;
    dispatch.glDrawElementsInstancedBaseInstance = &impl::glDrawElementsInstancedBaseInstance;
    dispatch.glDrawElementsInstancedBaseVertexBaseInstance = &impl::glDrawElementsInstancedBaseVertexBaseInstance;
    // GL 4.3 — multi-draw indirect.
    dispatch.glMultiDrawArraysIndirect = &impl::glMultiDrawArraysIndirect;
    dispatch.glMultiDrawElementsIndirect = &impl::glMultiDrawElementsIndirect;
    // GL 4.3 — buffer clear.
    dispatch.glClearBufferData = &impl::glClearBufferData;
    dispatch.glClearBufferSubData = &impl::glClearBufferSubData;
    // GL 4.3 — framebuffer parameters.
    dispatch.glFramebufferParameteri = &impl::glFramebufferParameteri;
    dispatch.glGetFramebufferParameteriv = &impl::glGetFramebufferParameteriv;
    // GL 4.3 — invalidation hints.
    dispatch.glInvalidateFramebuffer = &impl::glInvalidateFramebuffer;
    dispatch.glInvalidateSubFramebuffer = &impl::glInvalidateSubFramebuffer;
    dispatch.glInvalidateBufferData = &impl::glInvalidateBufferData;
    dispatch.glInvalidateBufferSubData = &impl::glInvalidateBufferSubData;
    // GL 4.3 — texture operations.
    dispatch.glCopyImageSubData = &impl::glCopyImageSubData;
    dispatch.glTextureView = &impl::glTextureView;
    dispatch.glInvalidateTexImage = &impl::glInvalidateTexImage;
    dispatch.glInvalidateTexSubImage = &impl::glInvalidateTexSubImage;
    // GL 4.2 — transform feedback instanced draw.
    dispatch.glDrawTransformFeedbackInstanced = &impl::glDrawTransformFeedbackInstanced;
    dispatch.glDrawTransformFeedbackStreamInstanced = &impl::glDrawTransformFeedbackStreamInstanced;
    // GL 4.2/4.3 — internal format query.
    dispatch.glGetInternalformativ = &impl::glGetInternalformativ;
    dispatch.glGetInternalformati64v = &impl::glGetInternalformati64v;
    coverage.markImplemented(FunctionId::glTexPageCommitmentARB,
                             "ARB_sparse_texture commitment entry point is wired; Metal sparse mapping deferred.");

    coverage.markImplemented(FunctionId::glClearColor, "Bootstrap clear-color plumbing is live.");
    coverage.markImplemented(FunctionId::glDrawBuffer, "Single draw-buffer state tracking is live.");
    coverage.markImplemented(FunctionId::glClear, "Bootstrap Metal clear path is live.");
    coverage.markImplemented(FunctionId::glClearDepth, "Default framebuffer depth clear state is live.");
    coverage.markImplemented(FunctionId::glClearStencil, "Default framebuffer stencil clear state is live.");
    coverage.markImplemented(FunctionId::glViewport, "Bootstrap viewport path is live.");
    coverage.markImplemented(FunctionId::glFlush, "Bootstrap flush path is live.");
    coverage.markImplemented(FunctionId::glReadPixels, "RGBA/UNSIGNED_BYTE readback is live for gauntlet captures.");
    coverage.markImplemented(FunctionId::glGetBooleanv, "Boolean state/capability query routing is live.");
    coverage.markImplemented(FunctionId::glGetIntegerv, "Capability integer query routing is live.");
    coverage.markImplemented(FunctionId::glGetInteger64v, "Capability integer64 query routing is live.");
    coverage.markImplemented(FunctionId::glGetFloatv, "Capability float query routing is live.");
    coverage.markImplemented(FunctionId::glGetDoublev, "Double state/capability query routing is live.");
    coverage.markImplemented(FunctionId::glGenBuffers, "Buffer name generation is live.");
    coverage.markImplemented(FunctionId::glDeleteBuffers, "Buffer deletion is live.");
    coverage.markImplemented(FunctionId::glIsBuffer, "Buffer object query is live.");
    coverage.markImplemented(FunctionId::glBindBuffer, "Generic buffer binding is live.");
    coverage.markImplemented(FunctionId::glBindBufferBase, "Indexed buffer-base binding is live.");
    coverage.markImplemented(FunctionId::glBindBufferRange, "Indexed buffer-range binding is live.");
    coverage.markImplemented(FunctionId::glBufferData, "Buffer storage allocation is live.");
    coverage.markImplemented(FunctionId::glBufferSubData, "Buffer subdata update is live.");
    coverage.markImplemented(FunctionId::glCopyBufferSubData, "Buffer copy is live.");
    coverage.markImplemented(FunctionId::glGetBufferSubData, "Buffer readback is live.");
    coverage.markImplemented(FunctionId::glMapBuffer, "Whole-buffer mapping is live.");
    coverage.markImplemented(FunctionId::glMapBufferRange, "Mapped buffer ranges are live.");
    coverage.markImplemented(FunctionId::glUnmapBuffer, "Mapped buffer unmap is live.");
    coverage.markImplemented(FunctionId::glFlushMappedBufferRange, "Explicit mapped-range flush is live.");
    coverage.markImplemented(FunctionId::glGetBufferParameteriv, "Buffer parameter query is live.");
    coverage.markImplemented(FunctionId::glGetBufferParameteri64v, "Buffer parameter query is live.");
    coverage.markImplemented(FunctionId::glGetBufferPointerv, "Mapped buffer pointer query is live.");
    coverage.markImplemented(FunctionId::glGenVertexArrays, "Vertex-array name generation is live.");
    coverage.markImplemented(FunctionId::glDeleteVertexArrays, "Vertex-array deletion is live.");
    coverage.markImplemented(FunctionId::glIsVertexArray, "Vertex-array object query is live.");
    coverage.markImplemented(FunctionId::glBindVertexArray, "Vertex-array binding is live.");
    coverage.markImplemented(FunctionId::glEnableVertexAttribArray, "Vertex attribute enable state is live.");
    coverage.markImplemented(FunctionId::glDisableVertexAttribArray, "Vertex attribute disable state is live.");
    coverage.markImplemented(FunctionId::glVertexAttribPointer, "Floating-point vertex attribute pointer state is live.");
    coverage.markImplemented(FunctionId::glVertexAttribIPointer, "Integer vertex attribute pointer state is live.");
    coverage.markImplemented(FunctionId::glVertexAttribDivisor, "Vertex attribute divisor state is live.");
    // GL 4.3 — separated vertex format (ARB_vertex_attrib_binding).
    coverage.markImplemented(FunctionId::glBindVertexBuffer, "Separated vertex format binding point buffer/offset/stride is live.");
    coverage.markImplemented(FunctionId::glVertexAttribFormat, "Separated floating-point vertex attribute format is live.");
    coverage.markImplemented(FunctionId::glVertexAttribIFormat, "Separated integer vertex attribute format is live.");
    coverage.markImplemented(FunctionId::glVertexAttribLFormat, "Separated double-precision vertex attribute format is live.");
    coverage.markImplemented(FunctionId::glVertexAttribBinding, "Vertex attribute to binding point association is live.");
    coverage.markImplemented(FunctionId::glVertexBindingDivisor, "Separated vertex format binding point divisor is live.");
    coverage.markImplemented(FunctionId::glGetVertexAttribiv, "Integer vertex attribute state query is live.");
    coverage.markImplemented(FunctionId::glGetVertexAttribfv, "Float vertex attribute state query is live.");
    coverage.markImplemented(FunctionId::glGetVertexAttribPointerv, "Vertex attribute pointer query is live.");
    coverage.markImplemented(FunctionId::glActiveTexture, "Active texture unit tracking is live.");
    coverage.markImplemented(FunctionId::glGenTextures, "Texture name generation is live.");
    coverage.markImplemented(FunctionId::glDeleteTextures, "Texture deletion is live.");
    coverage.markImplemented(FunctionId::glIsTexture, "Texture object query is live.");
    coverage.markImplemented(FunctionId::glBindTexture, "Texture binding is live.");
    coverage.markImplemented(FunctionId::glTexImage1D, "1D texture allocation/upload is live.");
    coverage.markImplemented(FunctionId::glTexImage2D, "2D texture allocation/upload is live.");
    coverage.markImplemented(FunctionId::glTexImage3D, "3D texture allocation/upload is live.");
    coverage.markImplemented(FunctionId::glTexSubImage1D, "1D texture subimage upload is live.");
    coverage.markImplemented(FunctionId::glTexSubImage2D, "2D texture subimage upload is live.");
    coverage.markImplemented(FunctionId::glTexSubImage3D, "3D texture subimage upload is live.");
    coverage.markImplemented(FunctionId::glTexParameteri, "Texture integer parameter state is live.");
    coverage.markImplemented(FunctionId::glTexParameteriv, "Texture integer parameter state is live.");
    coverage.markImplemented(FunctionId::glTexParameterf, "Texture float parameter state is live.");
    coverage.markImplemented(FunctionId::glTexParameterfv, "Texture float-vector parameter state is live.");
    coverage.markImplemented(FunctionId::glTexParameterIiv, "Texture integer-vector parameter state is live.");
    coverage.markImplemented(FunctionId::glTexParameterIuiv, "Texture unsigned integer-vector parameter state is live.");
    coverage.markImplemented(FunctionId::glGetTexParameteriv, "Texture integer parameter queries are live.");
    coverage.markImplemented(FunctionId::glGetTexParameterfv, "Texture float parameter queries are live.");
    coverage.markImplemented(FunctionId::glGetTexParameterIiv, "Texture integer parameter queries are live.");
    coverage.markImplemented(FunctionId::glGetTexParameterIuiv, "Texture unsigned parameter queries are live.");
    coverage.markImplemented(FunctionId::glGenerateMipmap, "Texture mipmap generation is live for Phase A texture storage.");
    coverage.markImplemented(FunctionId::glTexStorage1D, "1D immutable texture storage is live.");
    coverage.markImplemented(FunctionId::glTexStorage2D, "2D immutable texture storage is live.");
    coverage.markImplemented(FunctionId::glTexStorage3D, "3D immutable texture storage is live.");
    coverage.markImplemented(FunctionId::glTexStorage2DMultisample, "2D multisample immutable texture storage is live.");
    coverage.markImplemented(FunctionId::glTexStorage3DMultisample, "3D multisample immutable texture storage is live.");
    coverage.markImplemented(FunctionId::glTexBufferRange, "Buffer-texture range binding is live.");
    coverage.markImplemented(FunctionId::glPixelStorei, "Integer pixel-store state is live.");
    coverage.markImplemented(FunctionId::glPixelStoref, "Float pixel-store state is live.");
    coverage.markImplemented(FunctionId::glReadBuffer, "Read-buffer state tracking is live.");
    coverage.markImplemented(FunctionId::glDrawBuffers, "MRT draw-buffer state tracking is live.");
    coverage.markImplemented(FunctionId::glIsRenderbuffer, "Renderbuffer object query is live.");
    coverage.markImplemented(FunctionId::glBindRenderbuffer, "Renderbuffer binding is live.");
    coverage.markImplemented(FunctionId::glDeleteRenderbuffers, "Renderbuffer deletion is live.");
    coverage.markImplemented(FunctionId::glGenRenderbuffers, "Renderbuffer name generation is live.");
    coverage.markImplemented(FunctionId::glRenderbufferStorage, "Renderbuffer storage allocation is live.");
    coverage.markImplemented(FunctionId::glGetRenderbufferParameteriv, "Renderbuffer parameter query is live.");
    coverage.markImplemented(FunctionId::glGenFramebuffers, "Framebuffer name generation is live.");
    coverage.markImplemented(FunctionId::glDeleteFramebuffers, "Framebuffer deletion is live.");
    coverage.markImplemented(FunctionId::glIsFramebuffer, "Framebuffer object query is live.");
    coverage.markImplemented(FunctionId::glBindFramebuffer, "Framebuffer read/draw binding is live.");
    coverage.markImplemented(FunctionId::glCheckFramebufferStatus, "Framebuffer completeness checks are live.");
    coverage.markImplemented(FunctionId::glFramebufferTexture1D, "1D texture framebuffer attachments are live.");
    coverage.markImplemented(FunctionId::glFramebufferTexture2D, "2D texture framebuffer attachments are live.");
    coverage.markImplemented(FunctionId::glFramebufferTexture3D, "3D texture framebuffer attachments are live.");
    coverage.markImplemented(FunctionId::glFramebufferRenderbuffer, "Renderbuffer framebuffer attachments are live.");
    coverage.markImplemented(FunctionId::glBlitFramebuffer, "CPU-shadowed framebuffer blits are live for color/depth/stencil masks (1:1 nearest).");
    coverage.markImplemented(FunctionId::glGetFramebufferAttachmentParameteriv, "Framebuffer attachment queries are live.");
    coverage.markImplemented(FunctionId::glRenderbufferStorageMultisample, "Multisample renderbuffer storage is live.");
    coverage.markImplemented(FunctionId::glFramebufferTextureLayer, "Layered texture framebuffer attachments are live.");
    coverage.markImplemented(FunctionId::glFramebufferTexture, "Whole-texture framebuffer attachments are live.");
    coverage.markImplemented(FunctionId::glGenSamplers, "Sampler name generation is live.");
    coverage.markImplemented(FunctionId::glDeleteSamplers, "Sampler deletion is live.");
    coverage.markImplemented(FunctionId::glIsSampler, "Sampler object query is live.");
    coverage.markImplemented(FunctionId::glBindSampler, "Texture-unit sampler binding is live.");
    coverage.markImplemented(FunctionId::glSamplerParameteri, "Sampler integer parameter state is live.");
    coverage.markImplemented(FunctionId::glSamplerParameteriv, "Sampler integer-vector parameter state is live.");
    coverage.markImplemented(FunctionId::glSamplerParameterf, "Sampler float parameter state is live.");
    coverage.markImplemented(FunctionId::glSamplerParameterfv, "Sampler float-vector parameter state is live.");
    coverage.markImplemented(FunctionId::glSamplerParameterIiv, "Sampler integer-vector parameter state is live.");
    coverage.markImplemented(FunctionId::glSamplerParameterIuiv, "Sampler unsigned integer-vector parameter state is live.");
    coverage.markImplemented(FunctionId::glGetSamplerParameteriv, "Sampler integer parameter queries are live.");
    coverage.markImplemented(FunctionId::glGetSamplerParameterfv, "Sampler float parameter queries are live.");
    coverage.markImplemented(FunctionId::glGetSamplerParameterIiv, "Sampler integer parameter queries are live.");
    coverage.markImplemented(FunctionId::glGetSamplerParameterIuiv, "Sampler unsigned parameter queries are live.");
    coverage.markImplemented(FunctionId::glEnable, "Enable-state tracking is live.");
    coverage.markImplemented(FunctionId::glDisable, "Enable-state tracking is live.");
    coverage.markImplemented(FunctionId::glIsEnabled, "Enable-state query is live.");
    coverage.markImplemented(FunctionId::glScissor, "Scissor-box tracking is live.");
    coverage.markImplemented(FunctionId::glDepthRange, "Depth-range tracking is live.");
    coverage.markImplemented(FunctionId::glDepthRangef, "Depth-range float alias is live.");
    coverage.markImplemented(FunctionId::glBlendFunc, "Blend function tracking is live.");
    coverage.markImplemented(FunctionId::glBlendFuncSeparate, "Separate blend function tracking is live.");
    coverage.markImplemented(FunctionId::glBlendEquation, "Blend equation tracking is live.");
    coverage.markImplemented(FunctionId::glBlendEquationSeparate, "Separate blend equation tracking is live.");
    coverage.markImplemented(FunctionId::glBlendColor, "Constant blend color tracking is live.");
    coverage.markImplemented(FunctionId::glColorMask, "Color write-mask tracking is live.");
    coverage.markImplemented(FunctionId::glColorMaski, "Indexed color write-mask tracking is live.");
    coverage.markImplemented(FunctionId::glDepthFunc, "Depth compare tracking is live.");
    coverage.markImplemented(FunctionId::glDepthMask, "Depth write-mask tracking is live.");
    coverage.markImplemented(FunctionId::glStencilFunc, "Stencil compare tracking is live.");
    coverage.markImplemented(FunctionId::glStencilFuncSeparate, "Separate stencil compare tracking is live.");
    coverage.markImplemented(FunctionId::glStencilOp, "Stencil operation tracking is live.");
    coverage.markImplemented(FunctionId::glStencilOpSeparate, "Separate stencil operation tracking is live.");
    coverage.markImplemented(FunctionId::glStencilMask, "Stencil write-mask tracking is live.");
    coverage.markImplemented(FunctionId::glStencilMaskSeparate, "Separate stencil write-mask tracking is live.");
    coverage.markImplemented(FunctionId::glCullFace, "Cull-face tracking is live.");
    coverage.markImplemented(FunctionId::glFrontFace, "Front-face winding tracking is live.");
    coverage.markImplemented(FunctionId::glPolygonOffset, "Polygon offset tracking is live.");
    coverage.markImplemented(FunctionId::glLineWidth, "Line-width tracking is live.");
    coverage.markImplemented(FunctionId::glPointSize, "Point-size tracking is live.");
    coverage.markImplemented(FunctionId::glHint, "Hint-state tracking is live.");
    coverage.markImplemented(FunctionId::glGetString, "Bootstrap identity reporting is live.");
    coverage.markImplemented(FunctionId::glGetError, "Bootstrap per-context error FIFO is live.");
    coverage.markImplemented(FunctionId::glDebugMessageControl, "Debug message filtering is live.");
    coverage.markImplemented(FunctionId::glDebugMessageInsert, "Debug message insertion is live.");
    coverage.markImplemented(FunctionId::glDebugMessageCallback, "Debug callback plumbing is live.");
    coverage.markImplemented(FunctionId::glGetDebugMessageLog, "Debug message log retrieval is live.");
    coverage.markImplemented(FunctionId::glPushDebugGroup, "Debug group push is live.");
    coverage.markImplemented(FunctionId::glPopDebugGroup, "Debug group pop is live.");
    coverage.markImplemented(FunctionId::glObjectLabel, "Debug object labels are live.");
    coverage.markImplemented(FunctionId::glGetObjectLabel, "Debug object-label queries are live.");
    coverage.markImplemented(FunctionId::glObjectPtrLabel, "Debug pointer labels are live.");
    coverage.markImplemented(FunctionId::glGetObjectPtrLabel, "Debug pointer-label queries are live.");
    coverage.markImplemented(FunctionId::glGetPointerv, "Debug pointer queries are live.");

    coverage.markImplemented(FunctionId::glCreateShader, "Shader objects are created with a stage tag.");
    coverage.markImplemented(FunctionId::glDeleteShader, "Shader objects are removed from the object store.");
    coverage.markImplemented(FunctionId::glIsShader, "Shader existence queries are live.");
    coverage.markImplemented(FunctionId::glShaderSource, "Shader source strings are stored.");
    coverage.markImplemented(FunctionId::glCompileShader, "Shader source is reflected for declarations.");
    coverage.markImplemented(FunctionId::glGetShaderiv, "Shader integer queries are live.");
    coverage.markImplemented(FunctionId::glGetShaderInfoLog, "Shader compile logs are queryable.");
    coverage.markImplemented(FunctionId::glGetShaderSource, "Stored shader source is queryable.");
    coverage.markImplemented(FunctionId::glCreateProgram, "Program objects are created in the object store.");
    coverage.markImplemented(FunctionId::glDeleteProgram, "Program objects are removed and unbound on delete.");
    coverage.markImplemented(FunctionId::glIsProgram, "Program existence queries are live.");
    coverage.markImplemented(FunctionId::glAttachShader, "Shader attachments are tracked per program.");
    coverage.markImplemented(FunctionId::glDetachShader, "Shader attachments are removable.");
    coverage.markImplemented(FunctionId::glLinkProgram, "Program link merges shader reflections.");
    coverage.markImplemented(FunctionId::glUseProgram, "Current program is tracked in the state mirror.");
    coverage.markImplemented(FunctionId::glValidateProgram, "Program validation status is tracked.");
    coverage.markImplemented(FunctionId::glGetProgramiv, "Program integer queries are live.");
    coverage.markImplemented(FunctionId::glGetProgramInfoLog, "Program info logs are queryable.");
    coverage.markImplemented(FunctionId::glGetAttachedShaders, "Attached shader names are enumerable.");
    coverage.markImplemented(FunctionId::glBindAttribLocation, "Pre-link attribute location requests are honored.");
    coverage.markImplemented(FunctionId::glGetAttribLocation, "Vertex attribute locations are queryable post-link.");
    coverage.markImplemented(FunctionId::glGetActiveAttrib, "Active vertex attribute reflection is live.");
    coverage.markImplemented(FunctionId::glGetUniformLocation, "Uniform locations are queryable post-link.");
    coverage.markImplemented(FunctionId::glGetActiveUniform, "Active uniform reflection is live.");
    coverage.markImplemented(FunctionId::glGetUniformfv, "Uniform float readback is live.");
    coverage.markImplemented(FunctionId::glGetUniformiv, "Uniform integer readback is live.");
    coverage.markImplemented(FunctionId::glGetUniformuiv, "Uniform unsigned integer readback is live.");
    coverage.markImplemented(FunctionId::glUniform1f, "Float scalar uniforms are live.");
    coverage.markImplemented(FunctionId::glUniform2f, "Float vec2 uniforms are live.");
    coverage.markImplemented(FunctionId::glUniform3f, "Float vec3 uniforms are live.");
    coverage.markImplemented(FunctionId::glUniform4f, "Float vec4 uniforms are live.");
    coverage.markImplemented(FunctionId::glUniform1i, "Int scalar uniforms are live.");
    coverage.markImplemented(FunctionId::glUniform2i, "Int vec2 uniforms are live.");
    coverage.markImplemented(FunctionId::glUniform3i, "Int vec3 uniforms are live.");
    coverage.markImplemented(FunctionId::glUniform4i, "Int vec4 uniforms are live.");
    coverage.markImplemented(FunctionId::glUniform1ui, "Unsigned scalar uniforms are live.");
    coverage.markImplemented(FunctionId::glUniform2ui, "uvec2 uniforms are live.");
    coverage.markImplemented(FunctionId::glUniform3ui, "uvec3 uniforms are live.");
    coverage.markImplemented(FunctionId::glUniform4ui, "uvec4 uniforms are live.");
    coverage.markImplemented(FunctionId::glUniform1fv, "Float scalar uniform arrays are live.");
    coverage.markImplemented(FunctionId::glUniform2fv, "vec2 uniform arrays are live.");
    coverage.markImplemented(FunctionId::glUniform3fv, "vec3 uniform arrays are live.");
    coverage.markImplemented(FunctionId::glUniform4fv, "vec4 uniform arrays are live.");
    coverage.markImplemented(FunctionId::glUniform1iv, "Int scalar uniform arrays are live.");
    coverage.markImplemented(FunctionId::glUniform2iv, "ivec2 uniform arrays are live.");
    coverage.markImplemented(FunctionId::glUniform3iv, "ivec3 uniform arrays are live.");
    coverage.markImplemented(FunctionId::glUniform4iv, "ivec4 uniform arrays are live.");
    coverage.markImplemented(FunctionId::glUniform1uiv, "uint scalar uniform arrays are live.");
    coverage.markImplemented(FunctionId::glUniform2uiv, "uvec2 uniform arrays are live.");
    coverage.markImplemented(FunctionId::glUniform3uiv, "uvec3 uniform arrays are live.");
    coverage.markImplemented(FunctionId::glUniform4uiv, "uvec4 uniform arrays are live.");
    coverage.markImplemented(FunctionId::glUniformMatrix2fv, "mat2 uniforms are live.");
    coverage.markImplemented(FunctionId::glUniformMatrix3fv, "mat3 uniforms are live.");
    coverage.markImplemented(FunctionId::glUniformMatrix4fv, "mat4 uniforms are live.");
    coverage.markImplemented(FunctionId::glDrawArrays, "Solid-color draw path (Phase A Group 7 MVP).");
    coverage.markImplemented(FunctionId::glDrawElements, "Solid-color indexed draw path (Phase A Group 7 MVP).");
    // Phase 4 Pass A — GL 4.0/4.1 state-only additions.
    coverage.markImplemented(FunctionId::glPatchParameteri, "Tessellation patch vertex count state tracked.");
    coverage.markImplemented(FunctionId::glPatchParameterfv, "Tessellation default outer/inner levels tracked.");
    coverage.markImplemented(FunctionId::glBeginQueryIndexed, "Indexed query begin stub (CPU-only).");
    coverage.markImplemented(FunctionId::glEndQueryIndexed, "Indexed query end stub (CPU-only).");
    coverage.markImplemented(FunctionId::glGetQueryIndexediv, "Indexed query get stub returns defaults.");
    coverage.markImplemented(FunctionId::glViewportArrayv, "Per-viewport-index array state tracked.");
    coverage.markImplemented(FunctionId::glViewportIndexedf, "Per-viewport-index state tracked.");
    coverage.markImplemented(FunctionId::glViewportIndexedfv, "Per-viewport-index state tracked.");
    coverage.markImplemented(FunctionId::glScissorArrayv, "Per-scissor-index array state tracked.");
    coverage.markImplemented(FunctionId::glScissorIndexed, "Per-scissor-index state tracked.");
    coverage.markImplemented(FunctionId::glScissorIndexedv, "Per-scissor-index state tracked.");
    coverage.markImplemented(FunctionId::glDepthRangeArrayv, "Per-depth-range-index array state tracked.");
    coverage.markImplemented(FunctionId::glDepthRangeIndexed, "Per-depth-range-index state tracked.");
    coverage.markImplemented(FunctionId::glGetFloati_v, "Indexed float state query returns tracked values.");
    coverage.markImplemented(FunctionId::glGetDoublei_v, "Indexed double state query returns tracked values.");
    coverage.markImplemented(FunctionId::glClearDepthf, "Float-precision depth clear state tracked.");
    // Phase 4 Pass C — GL 4.1 program uniforms (Group 10, 50 arities) + binary/release (Group 11, 5).
    coverage.markImplemented(FunctionId::glProgramUniform1i, "ProgramUniform1i (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform1iv, "ProgramUniform1iv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform1f, "ProgramUniform1f (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform1fv, "ProgramUniform1fv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform1d, "ProgramUniform1d (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniform1dv, "ProgramUniform1dv (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniform1ui, "ProgramUniform1ui (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform1uiv, "ProgramUniform1uiv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform2i, "ProgramUniform2i (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform2iv, "ProgramUniform2iv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform2f, "ProgramUniform2f (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform2fv, "ProgramUniform2fv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform2d, "ProgramUniform2d (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniform2dv, "ProgramUniform2dv (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniform2ui, "ProgramUniform2ui (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform2uiv, "ProgramUniform2uiv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform3i, "ProgramUniform3i (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform3iv, "ProgramUniform3iv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform3f, "ProgramUniform3f (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform3fv, "ProgramUniform3fv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform3d, "ProgramUniform3d (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniform3dv, "ProgramUniform3dv (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniform3ui, "ProgramUniform3ui (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform3uiv, "ProgramUniform3uiv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform4i, "ProgramUniform4i (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform4iv, "ProgramUniform4iv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform4f, "ProgramUniform4f (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform4fv, "ProgramUniform4fv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform4d, "ProgramUniform4d (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniform4dv, "ProgramUniform4dv (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniform4ui, "ProgramUniform4ui (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniform4uiv, "ProgramUniform4uiv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix2fv, "ProgramUniformMatrix2fv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix3fv, "ProgramUniformMatrix3fv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix4fv, "ProgramUniformMatrix4fv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix2dv, "ProgramUniformMatrix2dv (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix3dv, "ProgramUniformMatrix3dv (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix4dv, "ProgramUniformMatrix4dv (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix2x3fv, "ProgramUniformMatrix2x3fv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix3x2fv, "ProgramUniformMatrix3x2fv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix2x4fv, "ProgramUniformMatrix2x4fv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix4x2fv, "ProgramUniformMatrix4x2fv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix3x4fv, "ProgramUniformMatrix3x4fv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix4x3fv, "ProgramUniformMatrix4x3fv (explicit program).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix2x3dv, "ProgramUniformMatrix2x3dv (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix3x2dv, "ProgramUniformMatrix3x2dv (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix2x4dv, "ProgramUniformMatrix2x4dv (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix4x2dv, "ProgramUniformMatrix4x2dv (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix3x4dv, "ProgramUniformMatrix3x4dv (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glProgramUniformMatrix4x3dv, "ProgramUniformMatrix4x3dv (explicit program, f64→f32).");
    coverage.markImplemented(FunctionId::glGetProgramBinary, "ProgramBinary stub (0 formats, GL_INVALID_OPERATION).");
    coverage.markImplemented(FunctionId::glProgramBinary, "ProgramBinary stub (0 formats, GL_INVALID_ENUM).");
    coverage.markImplemented(FunctionId::glProgramParameteri, "ProgramParameteri accepts hints (no effect).");
    coverage.markImplemented(FunctionId::glShaderBinary, "ShaderBinary stub (0 formats, GL_INVALID_ENUM).");
    coverage.markImplemented(FunctionId::glReleaseShaderCompiler, "ReleaseShaderCompiler hint (no-op).");
    coverage.markImplemented(FunctionId::glVertexAttribL1d, "Double vertex attrib immediate (L1d) stored with CPU-side shadow.");
    coverage.markImplemented(FunctionId::glVertexAttribL2d, "Double vertex attrib immediate (L2d) stored with CPU-side shadow.");
    coverage.markImplemented(FunctionId::glVertexAttribL3d, "Double vertex attrib immediate (L3d) stored with CPU-side shadow.");
    coverage.markImplemented(FunctionId::glVertexAttribL4d, "Double vertex attrib immediate (L4d) stored with CPU-side shadow.");
    coverage.markImplemented(FunctionId::glVertexAttribL1dv, "Double vertex attrib immediate (L1dv) stored with CPU-side shadow.");
    coverage.markImplemented(FunctionId::glVertexAttribL2dv, "Double vertex attrib immediate (L2dv) stored with CPU-side shadow.");
    coverage.markImplemented(FunctionId::glVertexAttribL3dv, "Double vertex attrib immediate (L3dv) stored with CPU-side shadow.");
    coverage.markImplemented(FunctionId::glVertexAttribL4dv, "Double vertex attrib immediate (L4dv) stored with CPU-side shadow.");
    coverage.markImplemented(FunctionId::glVertexAttribLPointer, "Double-precision vertex attribute pointer (f64→f32 narrowing at draw).");
    coverage.markImplemented(FunctionId::glGetVertexAttribLdv, "Double vertex attrib readback from CPU-side shadow.");
    coverage.markImplemented(FunctionId::glGetShaderPrecisionFormat, "Shader precision query returns Metal-appropriate ranges.");
    // GL 4.1 — program pipeline objects (Group 9).
    coverage.markImplemented(FunctionId::glGenProgramPipelines, "Program pipeline name generation.");
    coverage.markImplemented(FunctionId::glDeleteProgramPipelines, "Program pipeline deletion.");
    coverage.markImplemented(FunctionId::glIsProgramPipeline, "Program pipeline existence query.");
    coverage.markImplemented(FunctionId::glBindProgramPipeline, "Program pipeline binding (state-tracked).");
    coverage.markImplemented(FunctionId::glUseProgramStages, "UseProgramStages stage assignment (state-tracked).");
    coverage.markImplemented(FunctionId::glActiveShaderProgram, "ActiveShaderProgram sets default uniform target.");
    coverage.markImplemented(FunctionId::glCreateShaderProgramv, "CreateShaderProgramv convenience (create+compile+link).");
    coverage.markImplemented(FunctionId::glValidateProgramPipeline, "ValidateProgramPipeline (always passes, stub).");
    coverage.markImplemented(FunctionId::glGetProgramPipelineiv, "GetProgramPipelineiv returns pipeline state.");
    coverage.markImplemented(FunctionId::glGetProgramPipelineInfoLog, "GetProgramPipelineInfoLog returns validation log.");
    // GL 4.0 — subroutine uniforms (Group 3, stub-with-state).
    coverage.markImplemented(FunctionId::glGetSubroutineUniformLocation, "Subroutine uniform location stub (always -1).");
    coverage.markImplemented(FunctionId::glGetSubroutineIndex, "Subroutine index stub (always GL_INVALID_INDEX).");
    coverage.markImplemented(FunctionId::glGetActiveSubroutineUniformiv, "Active subroutine uniform query stub (0 subroutines).");
    coverage.markImplemented(FunctionId::glGetActiveSubroutineUniformName, "Active subroutine uniform name stub (GL_INVALID_VALUE).");
    coverage.markImplemented(FunctionId::glGetActiveSubroutineName, "Active subroutine name stub (GL_INVALID_VALUE).");
    coverage.markImplemented(FunctionId::glUniformSubroutinesuiv, "UniformSubroutinesuiv stub (no-op).");
    coverage.markImplemented(FunctionId::glGetUniformSubroutineuiv, "GetUniformSubroutineuiv stub (returns 0).");
    coverage.markImplemented(FunctionId::glGetProgramStageiv, "GetProgramStageiv reports 0 subroutines.");
    // GL 4.0 — transform feedback objects (Group 4).
    coverage.markImplemented(FunctionId::glGenTransformFeedbacks, "Transform feedback object name generation.");
    coverage.markImplemented(FunctionId::glDeleteTransformFeedbacks, "Transform feedback object deletion.");
    coverage.markImplemented(FunctionId::glIsTransformFeedback, "Transform feedback object existence query.");
    coverage.markImplemented(FunctionId::glBindTransformFeedback, "Transform feedback object binding (state-tracked).");
    coverage.markImplemented(FunctionId::glPauseTransformFeedback, "PauseTransformFeedback (state-tracked).");
    coverage.markImplemented(FunctionId::glResumeTransformFeedback, "ResumeTransformFeedback (state-tracked).");
    coverage.markImplemented(FunctionId::glDrawTransformFeedback, "DrawTransformFeedback stub (0 primitives).");
    coverage.markImplemented(FunctionId::glDrawTransformFeedbackStream, "DrawTransformFeedbackStream stub (0 primitives).");
    // GL 4.0 — indirect drawing (Group 6).
    coverage.markImplemented(FunctionId::glDrawArraysIndirect, "DrawArraysIndirect stub (accepted, no draw).");
    coverage.markImplemented(FunctionId::glDrawElementsIndirect, "DrawElementsIndirect stub (accepted, no draw).");
    // GL 4.2/4.3 — compute shaders and memory barriers.
    coverage.markImplemented(FunctionId::glMemoryBarrier, "MemoryBarrier validated no-op (Metal handles ordering implicitly).");
    coverage.markImplemented(FunctionId::glDispatchCompute, "DispatchCompute stub (validated, compute pipeline not yet wired).");
    coverage.markImplemented(FunctionId::glDispatchComputeIndirect, "DispatchComputeIndirect stub (validated, compute pipeline not yet wired).");
    // GL 4.2 — image load/store and atomic counters.
    coverage.markImplemented(FunctionId::glBindImageTexture, "Image unit binding state tracked for load/store shaders.");
    coverage.markImplemented(FunctionId::glGetActiveAtomicCounterBufferiv, "Atomic counter buffer query returns sensible defaults (no native atomic counters on Metal).");
    // GL 4.3 — program resource introspection (ARB_program_interface_query).
    coverage.markImplemented(FunctionId::glGetProgramInterfaceiv, "Program interface query returns active resource counts from reflection tables.");
    coverage.markImplemented(FunctionId::glGetProgramResourceiv, "Program resource property query returns reflection data.");
    coverage.markImplemented(FunctionId::glGetProgramResourceName, "Program resource name query returns reflected names.");
    coverage.markImplemented(FunctionId::glGetProgramResourceIndex, "Program resource index lookup by name.");
    coverage.markImplemented(FunctionId::glGetProgramResourceLocation, "Program resource location lookup by name.");
    coverage.markImplemented(FunctionId::glGetProgramResourceLocationIndex, "Program resource location index (dual-source blending).");
    // GL 4.3 — SSBO binding remapping.
    coverage.markImplemented(FunctionId::glShaderStorageBlockBinding, "SSBO block binding remapping tracked on program object.");
    // GL 4.2 — advanced instanced drawing with base instance.
    coverage.markImplemented(FunctionId::glDrawArraysInstancedBaseInstance, "DrawArraysInstancedBaseInstance stub (validated, Metal instancing ready).");
    coverage.markImplemented(FunctionId::glDrawElementsInstancedBaseInstance, "DrawElementsInstancedBaseInstance stub (validated, Metal instancing ready).");
    coverage.markImplemented(FunctionId::glDrawElementsInstancedBaseVertexBaseInstance, "DrawElementsInstancedBaseVertexBaseInstance stub (validated).");
    // GL 4.3 — multi-draw indirect.
    coverage.markImplemented(FunctionId::glMultiDrawArraysIndirect, "MultiDrawArraysIndirect stub (validated, indirect buffer not yet read).");
    coverage.markImplemented(FunctionId::glMultiDrawElementsIndirect, "MultiDrawElementsIndirect stub (validated, indirect buffer not yet read).");
    // GL 4.3 — buffer clear.
    coverage.markImplemented(FunctionId::glClearBufferData, "Buffer data cleared with pattern fill.");
    coverage.markImplemented(FunctionId::glClearBufferSubData, "Buffer sub-range cleared with pattern fill.");
    // GL 4.3 — framebuffer parameters.
    coverage.markImplemented(FunctionId::glFramebufferParameteri, "Framebuffer default parameter hint accepted.");
    coverage.markImplemented(FunctionId::glGetFramebufferParameteriv, "Framebuffer default parameter query returns defaults.");
    // GL 4.3 — invalidation hints.
    coverage.markImplemented(FunctionId::glInvalidateFramebuffer, "Framebuffer invalidation hint accepted.");
    coverage.markImplemented(FunctionId::glInvalidateSubFramebuffer, "Sub-framebuffer invalidation hint accepted.");
    coverage.markImplemented(FunctionId::glInvalidateBufferData, "Buffer data invalidation hint accepted.");
    coverage.markImplemented(FunctionId::glInvalidateBufferSubData, "Buffer sub-data invalidation hint accepted.");
    // GL 4.3 — texture operations.
    coverage.markImplemented(FunctionId::glCopyImageSubData, "CopyImageSubData stub (validated, Metal blit copy deferred).");
    coverage.markImplemented(FunctionId::glTextureView, "TextureView relationship recorded (Metal view creation deferred).");
    coverage.markImplemented(FunctionId::glInvalidateTexImage, "Texture image invalidation hint accepted.");
    coverage.markImplemented(FunctionId::glInvalidateTexSubImage, "Texture sub-image invalidation hint accepted.");
    // GL 4.2 — transform feedback instanced draw.
    coverage.markImplemented(FunctionId::glDrawTransformFeedbackInstanced, "DrawTransformFeedbackInstanced stub (0 captured prims).");
    coverage.markImplemented(FunctionId::glDrawTransformFeedbackStreamInstanced, "DrawTransformFeedbackStreamInstanced stub (0 captured prims).");
    // GL 4.2/4.3 — internal format query.
    coverage.markImplemented(FunctionId::glGetInternalformativ, "Internal format query returns Metal-appropriate capabilities.");
    coverage.markImplemented(FunctionId::glGetInternalformati64v, "Internal format i64 query returns Metal-appropriate capabilities.");

    // Phase 6 Pass A — GL 4.4: immutable buffer storage.
    dispatch.glBufferStorage = &impl::glBufferStorage;
    coverage.markImplemented(FunctionId::glBufferStorage, "Immutable buffer storage with validation.");
    // GL 4.4 — multi-bind.
    dispatch.glBindBuffersBase = &impl::glBindBuffersBase;
    dispatch.glBindBuffersRange = &impl::glBindBuffersRange;
    dispatch.glBindVertexBuffers = &impl::glBindVertexBuffers;
    dispatch.glBindTextures = &impl::glBindTextures;
    dispatch.glBindSamplers = &impl::glBindSamplers;
    dispatch.glBindImageTextures = &impl::glBindImageTextures;
    coverage.markImplemented(FunctionId::glBindBuffersBase, "Batch buffer base binding.");
    coverage.markImplemented(FunctionId::glBindBuffersRange, "Batch buffer range binding.");
    coverage.markImplemented(FunctionId::glBindVertexBuffers, "Batch vertex buffer binding.");
    coverage.markImplemented(FunctionId::glBindTextures, "Batch texture binding.");
    coverage.markImplemented(FunctionId::glBindSamplers, "Batch sampler binding.");
    coverage.markImplemented(FunctionId::glBindImageTextures, "Batch image texture binding.");
    // GL 4.4 — texture clear.
    dispatch.glClearTexImage = &impl::glClearTexImage;
    dispatch.glClearTexSubImage = &impl::glClearTexSubImage;
    coverage.markImplemented(FunctionId::glClearTexImage, "Texture image cleared.");
    coverage.markImplemented(FunctionId::glClearTexSubImage, "Texture sub-image cleared.");
    // GL 4.5 — DSA object creation.
    dispatch.glCreateBuffers = &impl::glCreateBuffers;
    dispatch.glCreateTextures = &impl::glCreateTextures;
    dispatch.glCreateSamplers = &impl::glCreateSamplers;
    dispatch.glCreateFramebuffers = &impl::glCreateFramebuffers;
    dispatch.glCreateRenderbuffers = &impl::glCreateRenderbuffers;
    dispatch.glCreateVertexArrays = &impl::glCreateVertexArrays;
    dispatch.glCreateTransformFeedbacks = &impl::glCreateTransformFeedbacks;
    dispatch.glCreateProgramPipelines = &impl::glCreateProgramPipelines;
    dispatch.glCreateQueries = &impl::glCreateQueries;
    coverage.markImplemented(FunctionId::glCreateBuffers, "DSA buffer creation.");
    coverage.markImplemented(FunctionId::glCreateTextures, "DSA texture creation.");
    coverage.markImplemented(FunctionId::glCreateSamplers, "DSA sampler creation.");
    coverage.markImplemented(FunctionId::glCreateFramebuffers, "DSA framebuffer creation.");
    coverage.markImplemented(FunctionId::glCreateRenderbuffers, "DSA renderbuffer creation.");
    coverage.markImplemented(FunctionId::glCreateVertexArrays, "DSA vertex array creation.");
    coverage.markImplemented(FunctionId::glCreateTransformFeedbacks, "DSA transform feedback creation.");
    coverage.markImplemented(FunctionId::glCreateProgramPipelines, "DSA program pipeline creation.");
    coverage.markImplemented(FunctionId::glCreateQueries, "DSA query creation.");

    // Phase 6 Pass B — GL 4.5 DSA buffer operations (14).
    dispatch.glNamedBufferStorage = &impl::glNamedBufferStorage;
    dispatch.glNamedBufferData = &impl::glNamedBufferData;
    dispatch.glNamedBufferSubData = &impl::glNamedBufferSubData;
    dispatch.glCopyNamedBufferSubData = &impl::glCopyNamedBufferSubData;
    dispatch.glMapNamedBuffer = &impl::glMapNamedBuffer;
    dispatch.glMapNamedBufferRange = &impl::glMapNamedBufferRange;
    dispatch.glUnmapNamedBuffer = &impl::glUnmapNamedBuffer;
    dispatch.glFlushMappedNamedBufferRange = &impl::glFlushMappedNamedBufferRange;
    dispatch.glClearNamedBufferData = &impl::glClearNamedBufferData;
    dispatch.glClearNamedBufferSubData = &impl::glClearNamedBufferSubData;
    dispatch.glGetNamedBufferParameteriv = &impl::glGetNamedBufferParameteriv;
    dispatch.glGetNamedBufferParameteri64v = &impl::glGetNamedBufferParameteri64v;
    dispatch.glGetNamedBufferPointerv = &impl::glGetNamedBufferPointerv;
    dispatch.glGetNamedBufferSubData = &impl::glGetNamedBufferSubData;
    coverage.markImplemented(FunctionId::glNamedBufferStorage, "DSA immutable buffer storage.");
    coverage.markImplemented(FunctionId::glNamedBufferData, "DSA buffer data upload.");
    coverage.markImplemented(FunctionId::glNamedBufferSubData, "DSA buffer sub-data.");
    coverage.markImplemented(FunctionId::glCopyNamedBufferSubData, "DSA buffer copy.");
    coverage.markImplemented(FunctionId::glMapNamedBuffer, "DSA buffer map.");
    coverage.markImplemented(FunctionId::glMapNamedBufferRange, "DSA buffer range map.");
    coverage.markImplemented(FunctionId::glUnmapNamedBuffer, "DSA buffer unmap.");
    coverage.markImplemented(FunctionId::glFlushMappedNamedBufferRange, "DSA mapped buffer flush.");
    coverage.markImplemented(FunctionId::glClearNamedBufferData, "DSA buffer clear.");
    coverage.markImplemented(FunctionId::glClearNamedBufferSubData, "DSA buffer sub-range clear.");
    coverage.markImplemented(FunctionId::glGetNamedBufferParameteriv, "DSA buffer parameter query.");
    coverage.markImplemented(FunctionId::glGetNamedBufferParameteri64v, "DSA buffer i64 parameter query.");
    coverage.markImplemented(FunctionId::glGetNamedBufferPointerv, "DSA buffer pointer query.");
    coverage.markImplemented(FunctionId::glGetNamedBufferSubData, "DSA buffer sub-data readback.");
    // Phase 6 Pass B — GL 4.5 DSA texture operations (34).
    dispatch.glTextureStorage1D = &impl::glTextureStorage1D;
    dispatch.glTextureStorage2D = &impl::glTextureStorage2D;
    dispatch.glTextureStorage3D = &impl::glTextureStorage3D;
    dispatch.glTextureStorage2DMultisample = &impl::glTextureStorage2DMultisample;
    dispatch.glTextureStorage3DMultisample = &impl::glTextureStorage3DMultisample;
    dispatch.glTextureSubImage1D = &impl::glTextureSubImage1D;
    dispatch.glTextureSubImage2D = &impl::glTextureSubImage2D;
    dispatch.glTextureSubImage3D = &impl::glTextureSubImage3D;
    dispatch.glTextureBuffer = &impl::glTextureBuffer;
    dispatch.glTextureBufferRange = &impl::glTextureBufferRange;
    dispatch.glCompressedTextureSubImage1D = &impl::glCompressedTextureSubImage1D;
    dispatch.glCompressedTextureSubImage2D = &impl::glCompressedTextureSubImage2D;
    dispatch.glCompressedTextureSubImage3D = &impl::glCompressedTextureSubImage3D;
    dispatch.glCopyTextureSubImage1D = &impl::glCopyTextureSubImage1D;
    dispatch.glCopyTextureSubImage2D = &impl::glCopyTextureSubImage2D;
    dispatch.glCopyTextureSubImage3D = &impl::glCopyTextureSubImage3D;
    dispatch.glTextureParameterf = &impl::glTextureParameterf;
    dispatch.glTextureParameterfv = &impl::glTextureParameterfv;
    dispatch.glTextureParameteri = &impl::glTextureParameteri;
    dispatch.glTextureParameteriv = &impl::glTextureParameteriv;
    dispatch.glTextureParameterIiv = &impl::glTextureParameterIiv;
    dispatch.glTextureParameterIuiv = &impl::glTextureParameterIuiv;
    dispatch.glTexturePageCommitmentEXT = &impl::glTexturePageCommitmentEXT;
    dispatch.glGetTextureParameterfv = &impl::glGetTextureParameterfv;
    dispatch.glGetTextureParameteriv = &impl::glGetTextureParameteriv;
    dispatch.glGetTextureParameterIiv = &impl::glGetTextureParameterIiv;
    dispatch.glGetTextureParameterIuiv = &impl::glGetTextureParameterIuiv;
    dispatch.glGetTextureLevelParameterfv = &impl::glGetTextureLevelParameterfv;
    dispatch.glGetTextureLevelParameteriv = &impl::glGetTextureLevelParameteriv;
    dispatch.glGetTextureImage = &impl::glGetTextureImage;
    dispatch.glGetTextureSubImage = &impl::glGetTextureSubImage;
    dispatch.glGetCompressedTextureImage = &impl::glGetCompressedTextureImage;
    dispatch.glGetCompressedTextureSubImage = &impl::glGetCompressedTextureSubImage;
    dispatch.glGenerateTextureMipmap = &impl::glGenerateTextureMipmap;
    dispatch.glBindTextureUnit = &impl::glBindTextureUnit;
    for (auto id : {FunctionId::glTextureStorage1D, FunctionId::glTextureStorage2D, FunctionId::glTextureStorage3D,
                    FunctionId::glTextureStorage2DMultisample, FunctionId::glTextureStorage3DMultisample,
                    FunctionId::glTextureSubImage1D, FunctionId::glTextureSubImage2D, FunctionId::glTextureSubImage3D,
                    FunctionId::glTextureBuffer, FunctionId::glTextureBufferRange,
                    FunctionId::glCompressedTextureSubImage1D, FunctionId::glCompressedTextureSubImage2D, FunctionId::glCompressedTextureSubImage3D,
                    FunctionId::glCopyTextureSubImage1D, FunctionId::glCopyTextureSubImage2D, FunctionId::glCopyTextureSubImage3D,
                    FunctionId::glTextureParameterf, FunctionId::glTextureParameterfv,
                    FunctionId::glTextureParameteri, FunctionId::glTextureParameteriv,
                    FunctionId::glTextureParameterIiv, FunctionId::glTextureParameterIuiv,
                    FunctionId::glTexturePageCommitmentEXT,
                    FunctionId::glGetTextureParameterfv, FunctionId::glGetTextureParameteriv,
                    FunctionId::glGetTextureParameterIiv, FunctionId::glGetTextureParameterIuiv,
                    FunctionId::glGetTextureLevelParameterfv, FunctionId::glGetTextureLevelParameteriv,
                    FunctionId::glGetTextureImage, FunctionId::glGetTextureSubImage,
                    FunctionId::glGetCompressedTextureImage, FunctionId::glGetCompressedTextureSubImage,
                    FunctionId::glGenerateTextureMipmap, FunctionId::glBindTextureUnit}) {
        coverage.markImplemented(id, "DSA texture wrapper.");
    }

    // Pass C — DSA framebuffer / renderbuffer (20 functions)
    dispatch.glNamedFramebufferRenderbuffer = &impl::glNamedFramebufferRenderbuffer;
    dispatch.glNamedFramebufferTexture = &impl::glNamedFramebufferTexture;
    dispatch.glNamedFramebufferTextureLayer = &impl::glNamedFramebufferTextureLayer;
    dispatch.glNamedFramebufferDrawBuffer = &impl::glNamedFramebufferDrawBuffer;
    dispatch.glNamedFramebufferDrawBuffers = &impl::glNamedFramebufferDrawBuffers;
    dispatch.glNamedFramebufferReadBuffer = &impl::glNamedFramebufferReadBuffer;
    dispatch.glNamedFramebufferParameteri = &impl::glNamedFramebufferParameteri;
    dispatch.glGetNamedFramebufferParameteriv = &impl::glGetNamedFramebufferParameteriv;
    dispatch.glGetNamedFramebufferAttachmentParameteriv = &impl::glGetNamedFramebufferAttachmentParameteriv;
    dispatch.glCheckNamedFramebufferStatus = &impl::glCheckNamedFramebufferStatus;
    dispatch.glBlitNamedFramebuffer = &impl::glBlitNamedFramebuffer;
    dispatch.glClearNamedFramebufferfv = &impl::glClearNamedFramebufferfv;
    dispatch.glClearNamedFramebufferiv = &impl::glClearNamedFramebufferiv;
    dispatch.glClearNamedFramebufferuiv = &impl::glClearNamedFramebufferuiv;
    dispatch.glClearNamedFramebufferfi = &impl::glClearNamedFramebufferfi;
    dispatch.glInvalidateNamedFramebufferData = &impl::glInvalidateNamedFramebufferData;
    dispatch.glInvalidateNamedFramebufferSubData = &impl::glInvalidateNamedFramebufferSubData;
    dispatch.glNamedRenderbufferStorage = &impl::glNamedRenderbufferStorage;
    dispatch.glNamedRenderbufferStorageMultisample = &impl::glNamedRenderbufferStorageMultisample;
    dispatch.glGetNamedRenderbufferParameteriv = &impl::glGetNamedRenderbufferParameteriv;
    for (auto id : {FunctionId::glNamedFramebufferRenderbuffer, FunctionId::glNamedFramebufferTexture,
                    FunctionId::glNamedFramebufferTextureLayer, FunctionId::glNamedFramebufferDrawBuffer,
                    FunctionId::glNamedFramebufferDrawBuffers, FunctionId::glNamedFramebufferReadBuffer,
                    FunctionId::glNamedFramebufferParameteri, FunctionId::glGetNamedFramebufferParameteriv,
                    FunctionId::glGetNamedFramebufferAttachmentParameteriv, FunctionId::glCheckNamedFramebufferStatus,
                    FunctionId::glBlitNamedFramebuffer, FunctionId::glClearNamedFramebufferfv,
                    FunctionId::glClearNamedFramebufferiv, FunctionId::glClearNamedFramebufferuiv,
                    FunctionId::glClearNamedFramebufferfi, FunctionId::glInvalidateNamedFramebufferData,
                    FunctionId::glInvalidateNamedFramebufferSubData,
                    FunctionId::glNamedRenderbufferStorage, FunctionId::glNamedRenderbufferStorageMultisample,
                    FunctionId::glGetNamedRenderbufferParameteriv}) {
        coverage.markImplemented(id, "DSA framebuffer/renderbuffer wrapper.");
    }

    // Pass C — DSA vertex array (13 functions)
    dispatch.glVertexArrayAttribFormat = &impl::glVertexArrayAttribFormat;
    dispatch.glVertexArrayAttribIFormat = &impl::glVertexArrayAttribIFormat;
    dispatch.glVertexArrayAttribLFormat = &impl::glVertexArrayAttribLFormat;
    dispatch.glVertexArrayAttribBinding = &impl::glVertexArrayAttribBinding;
    dispatch.glVertexArrayBindingDivisor = &impl::glVertexArrayBindingDivisor;
    dispatch.glVertexArrayVertexBuffer = &impl::glVertexArrayVertexBuffer;
    dispatch.glVertexArrayVertexBuffers = &impl::glVertexArrayVertexBuffers;
    dispatch.glVertexArrayElementBuffer = &impl::glVertexArrayElementBuffer;
    dispatch.glEnableVertexArrayAttrib = &impl::glEnableVertexArrayAttrib;
    dispatch.glDisableVertexArrayAttrib = &impl::glDisableVertexArrayAttrib;
    dispatch.glGetVertexArrayiv = &impl::glGetVertexArrayiv;
    dispatch.glGetVertexArrayIndexediv = &impl::glGetVertexArrayIndexediv;
    dispatch.glGetVertexArrayIndexed64iv = &impl::glGetVertexArrayIndexed64iv;
    for (auto id : {FunctionId::glVertexArrayAttribFormat, FunctionId::glVertexArrayAttribIFormat,
                    FunctionId::glVertexArrayAttribLFormat, FunctionId::glVertexArrayAttribBinding,
                    FunctionId::glVertexArrayBindingDivisor, FunctionId::glVertexArrayVertexBuffer,
                    FunctionId::glVertexArrayVertexBuffers, FunctionId::glVertexArrayElementBuffer,
                    FunctionId::glEnableVertexArrayAttrib, FunctionId::glDisableVertexArrayAttrib,
                    FunctionId::glGetVertexArrayiv, FunctionId::glGetVertexArrayIndexediv,
                    FunctionId::glGetVertexArrayIndexed64iv}) {
        coverage.markImplemented(id, "DSA vertex array wrapper.");
    }

    // Pass C — DSA transform feedback (5 functions)
    dispatch.glTransformFeedbackBufferBase = &impl::glTransformFeedbackBufferBase;
    dispatch.glTransformFeedbackBufferRange = &impl::glTransformFeedbackBufferRange;
    dispatch.glGetTransformFeedbackiv = &impl::glGetTransformFeedbackiv;
    dispatch.glGetTransformFeedbacki_v = &impl::glGetTransformFeedbacki_v;
    dispatch.glGetTransformFeedbacki64_v = &impl::glGetTransformFeedbacki64_v;
    for (auto id : {FunctionId::glTransformFeedbackBufferBase, FunctionId::glTransformFeedbackBufferRange,
                    FunctionId::glGetTransformFeedbackiv, FunctionId::glGetTransformFeedbacki_v,
                    FunctionId::glGetTransformFeedbacki64_v}) {
        coverage.markImplemented(id, "DSA transform feedback wrapper.");
    }

    // Pass D — ClipControl, robustness, barriers (11 functions)
    dispatch.glClipControl = &impl::glClipControl;
    dispatch.glGetGraphicsResetStatus = &impl::glGetGraphicsResetStatus;
    dispatch.glReadnPixels = &impl::glReadnPixels;
    dispatch.glGetnUniformfv = &impl::glGetnUniformfv;
    dispatch.glGetnUniformiv = &impl::glGetnUniformiv;
    dispatch.glGetnUniformuiv = &impl::glGetnUniformuiv;
    dispatch.glGetnUniformdv = &impl::glGetnUniformdv;
    dispatch.glGetnTexImage = &impl::glGetnTexImage;
    dispatch.glGetnCompressedTexImage = &impl::glGetnCompressedTexImage;
    dispatch.glMemoryBarrierByRegion = &impl::glMemoryBarrierByRegion;
    dispatch.glTextureBarrier = &impl::glTextureBarrier;
    for (auto id : {FunctionId::glClipControl, FunctionId::glGetGraphicsResetStatus,
                    FunctionId::glReadnPixels, FunctionId::glGetnUniformfv,
                    FunctionId::glGetnUniformiv, FunctionId::glGetnUniformuiv,
                    FunctionId::glGetnUniformdv, FunctionId::glGetnTexImage,
                    FunctionId::glGetnCompressedTexImage, FunctionId::glMemoryBarrierByRegion,
                    FunctionId::glTextureBarrier}) {
        coverage.markImplemented(id, "GL 4.5 ClipControl / robustness / barrier.");
    }

    // Pass D — Query buffer objects (4 functions)
    dispatch.glGetQueryBufferObjectiv = &impl::glGetQueryBufferObjectiv;
    dispatch.glGetQueryBufferObjectuiv = &impl::glGetQueryBufferObjectuiv;
    dispatch.glGetQueryBufferObjecti64v = &impl::glGetQueryBufferObjecti64v;
    dispatch.glGetQueryBufferObjectui64v = &impl::glGetQueryBufferObjectui64v;
    for (auto id : {FunctionId::glGetQueryBufferObjectiv, FunctionId::glGetQueryBufferObjectuiv,
                    FunctionId::glGetQueryBufferObjecti64v, FunctionId::glGetQueryBufferObjectui64v}) {
        coverage.markImplemented(id, "Query buffer object stub.");
    }

    // Pass E — GL 4.6 (4 functions)
    dispatch.glMultiDrawArraysIndirectCount = &impl::glMultiDrawArraysIndirectCount;
    dispatch.glMultiDrawElementsIndirectCount = &impl::glMultiDrawElementsIndirectCount;
    dispatch.glSpecializeShader = &impl::glSpecializeShader;
    dispatch.glPolygonOffsetClamp = &impl::glPolygonOffsetClamp;
    for (auto id : {FunctionId::glMultiDrawArraysIndirectCount, FunctionId::glMultiDrawElementsIndirectCount,
                    FunctionId::glSpecializeShader, FunctionId::glPolygonOffsetClamp}) {
        coverage.markImplemented(id, "GL 4.6 entry point.");
    }

    // Phase A Group 8: wire the remaining <=3.3 entry points so the dispatch
    // table has no unimplementedReturn<> fallback for any manifest function in
    // the promotion-gate window. Queries are live; everything else ships as a
    // minimal no-op stub until a dedicated scenario lights it up.
    installGroup8Dispatch(dispatch, coverage);
}

}  // namespace appgl
