#include "Fp64Module.h"

#include "Fp64StateBinding.h"
#include "../ExtensionContext.h"
#include "../ExtensionRegistry.h"
#include "../../../include/AppGL/extensions/fp64.h"
#include "../../runtime/AppGLFeatureFlags.h"

#include <cstdlib>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

namespace appgl::extensions::fp64 {
namespace {

bool gActive = false;

bool forceAdvertiseForMeasurement() {
    const char* value = std::getenv("APPGL_DF64_FORCE_ADVERTISE");
    return feature_flags::parseBoolean(value != nullptr ? value : "", true)
        .value_or(value != nullptr);
}

const char* advertisedGpuShaderFp64ExtensionString() {
    return APPGL_EXTENSION_ARB_GPU_SHADER_FP64;
}

const char* advertisedVertexAttrib64BitExtensionString() {
    return APPGL_EXTENSION_ARB_VERTEX_ATTRIB_64BIT;
}

bool supportsAppleGpuFamily(ExtensionContext& ctx) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx.metalDevice();
    return device != nil && [device supportsFamily:MTLGPUFamilyApple7];
}

const ExtensionModuleDescriptor kDescriptor = {
    "fp64",
    advertisedGpuShaderFp64ExtensionString,
    isAvailable,
    initialize,
    shutdown,
    {},
    {}
};

const ExtensionModuleDescriptor kVertexAttrib64BitDescriptor = {
    "vertex_attrib_64bit",
    advertisedVertexAttrib64BitExtensionString,
    isAvailable,
    nullptr,
    nullptr,
    {},
    {}
};

struct Registrar {
    Registrar() {
        ExtensionRegistry::registerModule(kDescriptor);
        ExtensionRegistry::registerModule(kVertexAttrib64BitDescriptor);
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

bool runtimeFlagEnabled() {
    static const feature_flags::BooleanFlagResolution resolution =
        feature_flags::resolveBooleanFlag(
            "f64-emulation",
            {
                "fp64-emulation",
                "gpu-shader-fp64",
                "vertex-attrib-64bit",
            },
            {
                "APPGL_ENABLE_FP64_EMULATION",
                "APPGL_ENABLE_GPU_SHADER_FP64",
                "APPGL_ENABLE_VERTEX_ATTRIB_64BIT",
            },
            buildFlagEnabled());
    return resolution.enabled;
}

bool isAdvertisingHeld() {
    return false;
}

bool shaderTranslationSupported(ExtensionContext& ctx) {
    return supportsAppleGpuFamily(ctx) || forceAdvertiseForMeasurement();
}

bool isAvailable(ExtensionContext& ctx) {
    return runtimeFlagEnabled() && shaderTranslationSupported(ctx);
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
