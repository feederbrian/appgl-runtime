#pragma once

#include "../debug/CoverageStore.h"
#include "../generated/gl_dispatch.gen.h"

namespace appgl {

void installBootstrapDispatch(GLDispatchTable& dispatch, CoverageStore& coverage);

}  // namespace appgl
