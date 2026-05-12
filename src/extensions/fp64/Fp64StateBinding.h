#pragma once

#include <cstddef>

namespace appgl {
class ExtensionContext;
}

namespace appgl::extensions::fp64 {

struct BindingState {
    bool moduleAvailable = false;
    bool doubleUniformBackingEnabled = false;
    bool doubleSsboBackingEnabled = false;
    bool doubleVertexAttribBackingEnabled = false;
    std::size_t doubleUniformBytes = 0;
    std::size_t doubleSsboBytes = 0;
    std::size_t doubleVertexAttribBytes = 0;
};

void resetContextBindingState(ExtensionContext& ctx, bool moduleAvailable);
BindingState bindingStateSnapshot(ExtensionContext& ctx);
void destroyContextBindingState(ExtensionContext& ctx);
void destroyAllContextBindingStates();

}  // namespace appgl::extensions::fp64
