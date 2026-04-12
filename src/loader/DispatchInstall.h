#pragma once

#include "../debug/CoverageStore.h"
#include "../generated/gl_dispatch.gen.h"

namespace appgl {

void installBootstrapDispatch(GLDispatchTable& dispatch, CoverageStore& coverage);

// Wires the Phase A Group 8 residual <=3.3 surface (stubs + live query objects).
// Called at the end of installBootstrapDispatch so the bootstrap call sites
// remain grouped and the Group 8 file stays the single source of truth for
// the remaining 3.3 manifest gap. Also marks every Group 8 FunctionId as
// Implemented so the coverage store matches dispatch reality.
void installGroup8Dispatch(GLDispatchTable& dispatch, CoverageStore& coverage);

// Promotes every Phase A Group 8 FunctionId from Implemented to SmokeTested.
// Must only be called from a gauntlet scene that owns the api-surface-smoke
// test ID — runtime code outside the gauntlet should not call this.
void markGroup8SurfaceSmoke();

}  // namespace appgl
