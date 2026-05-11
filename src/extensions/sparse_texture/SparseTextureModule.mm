#include "SparseTextureModule.h"

#include "SparseTextureAlloc.h"
#include "SparseTextureBind.h"
#include "../ExtensionContext.h"
#include "../ExtensionRegistry.h"
#include "../../../include/AppGL/extensions/sparse_texture.h"

#import <Metal/Metal.h>

#include <algorithm>

namespace appgl::extensions::sparse_texture {
namespace {

bool gActive = false;

const ExtensionModuleDescriptor kDescriptor = {
    "sparse_texture",
    extensionString,
    isAvailable,
    initialize,
    shutdown,
    {
        handleTextureParameter,
        handleTextureParameterQuery,
        nullptr,
        uploadCommittedRegions,
        nullptr,
        handleInternalFormatQuery,
    },
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
    return APPGL_EXTENSION_ARB_SPARSE_TEXTURE;
}

bool isAvailable(ExtensionContext& ctx) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx.metalDevice();
    if (device == nil) {
        return false;
    }
    if (![device supportsFamily:MTLGPUFamilyApple7]) {
        return false;
    }
    if (@available(macOS 13.0, *)) {
        MTLHeapDescriptor* heapDesc = [[MTLHeapDescriptor alloc] init];
        heapDesc.type = MTLHeapTypeSparse;
        heapDesc.storageMode = MTLStorageModePrivate;
        heapDesc.size = std::max<NSUInteger>([device sparseTileSizeInBytes], 16384u);
        heapDesc.sparsePageSize = MTLSparsePageSize16;
        id<MTLHeap> heap = [device newHeapWithDescriptor:heapDesc];
        return heap != nil;
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

}  // namespace appgl::extensions::sparse_texture
