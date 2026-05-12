#include "Fp64Module.h"

#include "Fp64StateBinding.h"
#include "../ExtensionContext.h"
#include "../ExtensionRegistry.h"
#include "../../../include/AppGL/extensions/fp64.h"

#import <Metal/Metal.h>

namespace appgl::extensions::fp64 {
namespace {

bool gActive = false;

const char* heldExtensionString() {
    return nullptr;
}

bool supportsAppleGpuFamily(ExtensionContext& ctx) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx.metalDevice();
    return device != nil && [device supportsFamily:MTLGPUFamilyApple7];
}

const ExtensionModuleDescriptor kDescriptor = {
    "fp64",
    heldExtensionString,
    isAvailable,
    initialize,
    shutdown,
    {},
    {}
};

struct Registrar {
    Registrar() {
        ExtensionRegistry::registerModule(kDescriptor);
    }
};

const Registrar kRegistrar;

}  // namespace

const char* extensionString() {
    return APPGL_EXTENSION_ARB_GPU_SHADER_FP64;
}

const char* vertexAttrib64BitExtensionString() {
    return APPGL_EXTENSION_ARB_VERTEX_ATTRIB_64BIT;
}

bool buildFlagEnabled() {
#if APPGL_FP64_EMULATION
    return true;
#else
    return false;
#endif
}

bool isAdvertisingHeld() {
    return true;
}

bool isAvailable(ExtensionContext& ctx) {
    return buildFlagEnabled() && supportsAppleGpuFamily(ctx);
}

void initialize(ExtensionContext& ctx) {
    gActive = isAvailable(ctx);
    resetContextBindingState(ctx, gActive);
}

void shutdown() {
    gActive = false;
    destroyAllContextBindingStates();
}

bool isActive() {
    return gActive;
}

}  // namespace appgl::extensions::fp64
