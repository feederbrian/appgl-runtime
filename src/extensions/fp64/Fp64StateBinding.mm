#include "Fp64StateBinding.h"

#include "../ExtensionContext.h"

#include <mutex>
#include <unordered_map>

namespace appgl::extensions::fp64 {
namespace {

std::mutex& bindingStateMutex() {
    static std::mutex mutex;
    return mutex;
}

std::unordered_map<const GLContext*, BindingState>& bindingStates() {
    static std::unordered_map<const GLContext*, BindingState> states;
    return states;
}

}  // namespace

void resetContextBindingState(ExtensionContext& ctx, bool moduleAvailable) {
    std::lock_guard<std::mutex> lock(bindingStateMutex());
    BindingState& state = bindingStates()[&ctx.context()];
    state = {};
    state.moduleAvailable = moduleAvailable;
}

BindingState bindingStateSnapshot(ExtensionContext& ctx) {
    std::lock_guard<std::mutex> lock(bindingStateMutex());
    const auto it = bindingStates().find(&ctx.context());
    if (it == bindingStates().end()) {
        return {};
    }
    return it->second;
}

void recordDoubleUniformBacking(ExtensionContext& ctx, std::size_t bytes) {
    std::lock_guard<std::mutex> lock(bindingStateMutex());
    BindingState& state = bindingStates()[&ctx.context()];
    state.doubleUniformBackingEnabled = true;
    state.doubleUniformBytes += bytes;
}

void recordDoubleSsboBacking(ExtensionContext& ctx, std::size_t bytes) {
    std::lock_guard<std::mutex> lock(bindingStateMutex());
    BindingState& state = bindingStates()[&ctx.context()];
    state.doubleSsboBackingEnabled = true;
    state.doubleSsboBytes += bytes;
}

void recordDoubleVertexAttribBacking(ExtensionContext& ctx, std::size_t bytes) {
    std::lock_guard<std::mutex> lock(bindingStateMutex());
    BindingState& state = bindingStates()[&ctx.context()];
    state.doubleVertexAttribBackingEnabled = true;
    state.doubleVertexAttribBytes += bytes;
}

void destroyContextBindingState(ExtensionContext& ctx) {
    std::lock_guard<std::mutex> lock(bindingStateMutex());
    bindingStates().erase(&ctx.context());
}

void destroyAllContextBindingStates() {
    std::lock_guard<std::mutex> lock(bindingStateMutex());
    bindingStates().clear();
}

}  // namespace appgl::extensions::fp64
