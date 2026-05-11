#include "FragmentShadingRateModule.h"

#include "../ExtensionContext.h"
#include "../ExtensionRegistry.h"
#include "../../../include/AppGL/extensions/fragment_shading_rate.h"

#import <Metal/Metal.h>

namespace appgl::extensions::fragment_shading_rate {
namespace {

bool gActive = false;

const ExtensionModuleDescriptor kDescriptor = {
    "fragment_shading_rate",
    extensionString,
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
    return APPGL_EXTENSION_EXT_FRAGMENT_SHADING_RATE;
}

bool isAvailable(ExtensionContext& ctx) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx.metalDevice();
    if (device == nil) {
        return false;
    }
    if (@available(macOS 10.15.4, *)) {
        return [device supportsRasterizationRateMapWithLayerCount:1];
    }
    return false;
}

void initialize(ExtensionContext& ctx) {
    gActive = isAvailable(ctx);
}

void shutdown() {
    gActive = false;
}

bool isActive() {
    return gActive;
}

}  // namespace appgl::extensions::fragment_shading_rate
