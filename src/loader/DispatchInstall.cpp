#include "DispatchInstall.h"

#include "../runtime/AppGLRuntime.h"

namespace appgl {

void installBootstrapDispatch(GLDispatchTable& dispatch, CoverageStore& coverage) {
    dispatch.glClearColor = &impl::glClearColor;
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
    dispatch.glEnable = &impl::glEnable;
    dispatch.glDisable = &impl::glDisable;
    dispatch.glIsEnabled = &impl::glIsEnabled;
    dispatch.glScissor = &impl::glScissor;
    dispatch.glDepthRange = &impl::glDepthRange;
    dispatch.glDepthRangef = &impl::glDepthRangef;
    dispatch.glBlendFunc = &impl::glBlendFunc;
    dispatch.glBlendFuncSeparate = &impl::glBlendFuncSeparate;
    dispatch.glBlendEquation = &impl::glBlendEquation;
    dispatch.glBlendEquationSeparate = &impl::glBlendEquationSeparate;
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
    dispatch.glDebugMessageCallback = &impl::glDebugMessageCallback;

    coverage.markImplemented(FunctionId::glClearColor, "Bootstrap clear-color plumbing is live.");
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
    coverage.markImplemented(FunctionId::glDebugMessageCallback, "Bootstrap debug callback plumbing is live.");
}

}  // namespace appgl
