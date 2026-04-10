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
    dispatch.glGetIntegerv = &impl::glGetIntegerv;
    dispatch.glGetInteger64v = &impl::glGetInteger64v;
    dispatch.glGetFloatv = &impl::glGetFloatv;
    dispatch.glEnable = &impl::glEnable;
    dispatch.glDisable = &impl::glDisable;
    dispatch.glIsEnabled = &impl::glIsEnabled;
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
    coverage.markImplemented(FunctionId::glGetIntegerv, "Capability integer query routing is live.");
    coverage.markImplemented(FunctionId::glGetInteger64v, "Capability integer64 query routing is live.");
    coverage.markImplemented(FunctionId::glGetFloatv, "Capability float query routing is live.");
    coverage.markImplemented(FunctionId::glEnable, "Enable-state tracking is live.");
    coverage.markImplemented(FunctionId::glDisable, "Enable-state tracking is live.");
    coverage.markImplemented(FunctionId::glIsEnabled, "Enable-state query is live.");
    coverage.markImplemented(FunctionId::glGetString, "Bootstrap identity reporting is live.");
    coverage.markImplemented(FunctionId::glGetError, "Bootstrap per-context error FIFO is live.");
    coverage.markImplemented(FunctionId::glDebugMessageCallback, "Bootstrap debug callback plumbing is live.");
}

}  // namespace appgl
