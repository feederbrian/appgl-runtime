#include "MultisampleStorageImageEmulation.h"

#include "../ExtensionContext.h"
#include "../../caps/GLCapabilities.h"
#include "../../context/TextureMipLevels.h"
#include "../../objects/GLObjectStore.h"

#include <CoreFoundation/CoreFoundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <limits>
#include <mutex>
#include <optional>
#include <unordered_map>

namespace appgl::extensions::sparse_texture {
namespace {

struct SidecarState {
    MultisampleStorageImageSidecarInfo info;
};

struct ContextState {
    std::optional<bool> capabilityProbe;
    std::unordered_map<const GLTextureObject*, SidecarState> sidecars;
};

std::mutex& stateMutex() {
    static std::mutex mutex;
    return mutex;
}

std::unordered_map<const GLContext*, ContextState>& contextStates() {
    static std::unordered_map<const GLContext*, ContextState> states;
    return states;
}

void releaseRetainedMetalObject(void* object) {
    if (object != nullptr) {
        CFRelease(object);
    }
}

void releaseObjectiveCObject(id object) {
#if !__has_feature(objc_arc)
    if (object != nil) {
        [object release];
    }
#endif
}

void* transferRetainedMetalObject(id object) {
    if (object == nil) {
        return nullptr;
    }
#if __has_feature(objc_arc)
    return (__bridge_retained void*)object;
#else
    return object;
#endif
}

id<MTLDevice> metalDevice(ExtensionContext& ctx) {
    return (__bridge id<MTLDevice>)ctx.metalDevice();
}

MTLPixelFormat metalPixelFormatForInternalFormat(ExtensionContext& ctx,
                                                 GLenum internalFormat) {
    const auto capability = ctx.capabilities().format(internalFormat);
    if (!capability.has_value()) {
        return MTLPixelFormatInvalid;
    }
    return static_cast<MTLPixelFormat>(capability->metalPixelFormat);
}

bool probeSidecarCapability(id<MTLDevice> device) {
    if (device == nil) {
        return false;
    }

    MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
    options.languageVersion = MTLLanguageVersion2_4;

    static constexpr const char* kProbeSource =
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "kernel void appgl_ms_sidecar_probe(\n"
        "    texture2d_array<float, access::read_write> sidecar [[texture(0)]],\n"
        "    uint2 gid [[thread_position_in_grid]]) {\n"
        "    float4 v = sidecar.read(gid, 0);\n"
        "    sidecar.write(v, gid, 0);\n"
        "}\n";

    NSError* libError = nil;
    id<MTLLibrary> library =
        [device newLibraryWithSource:[NSString stringWithUTF8String:kProbeSource]
                              options:options
                                error:&libError];
    if (library == nil) {
        releaseObjectiveCObject(options);
        return false;
    }
    id<MTLFunction> function =
        [library newFunctionWithName:@"appgl_ms_sidecar_probe"];
    if (function == nil) {
        releaseObjectiveCObject(library);
        releaseObjectiveCObject(options);
        return false;
    }
    NSError* psoError = nil;
    id<MTLComputePipelineState> pso =
        [device newComputePipelineStateWithFunction:function error:&psoError];
    if (pso == nil) {
        releaseObjectiveCObject(function);
        releaseObjectiveCObject(library);
        releaseObjectiveCObject(options);
        return false;
    }

    MTLTextureDescriptor* desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = MTLTextureType2DArray;
    desc.pixelFormat = MTLPixelFormatRGBA8Unorm;
    desc.width = 4;
    desc.height = 4;
    desc.depth = 1;
    desc.arrayLength = 4;
    desc.mipmapLevelCount = singleMipLevelCount<NSUInteger>();
    desc.sampleCount = 1;
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    const bool supported = texture != nil;
    releaseObjectiveCObject(texture);
    releaseObjectiveCObject(desc);
    releaseObjectiveCObject(pso);
    releaseObjectiveCObject(function);
    releaseObjectiveCObject(library);
    releaseObjectiveCObject(options);
    return supported;
}

struct SidecarRequest {
    GLenum target = 0;
    GLenum internalFormat = 0;
    MTLPixelFormat pixelFormat = MTLPixelFormatInvalid;
    NSUInteger width = 0;
    NSUInteger height = 0;
    NSUInteger layers = 0;
    NSUInteger samples = 0;
    NSUInteger arrayLength = 0;
};

bool requestForTexture(ExtensionContext& ctx,
                       const GLTextureObject& texture,
                       SidecarRequest& request) {
    if (!isMultisampleStorageImageTarget(texture.target)) {
        return false;
    }

    id<MTLTexture> metalTexture =
        (__bridge id<MTLTexture>)texture.metalTexture;
    if (metalTexture != nil) {
        const MTLTextureType type = metalTexture.textureType;
        if (type != MTLTextureType2DMultisample &&
            type != MTLTextureType2DMultisampleArray) {
            return false;
        }
        request.target = texture.target;
        request.internalFormat = texture.desc.internalFormat;
        request.pixelFormat = metalTexture.pixelFormat;
        request.width = metalTexture.width;
        request.height = metalTexture.height;
        request.layers = (type == MTLTextureType2DMultisampleArray)
            ? metalTexture.arrayLength : 1u;
        request.samples = std::max<NSUInteger>(metalTexture.sampleCount, 1u);
    } else {
        request.target = texture.target;
        request.internalFormat = texture.desc.internalFormat;
        request.pixelFormat =
            metalPixelFormatForInternalFormat(ctx, texture.desc.internalFormat);
        request.width = static_cast<NSUInteger>(
            std::max<GLsizei>(texture.desc.width, 0));
        request.height = static_cast<NSUInteger>(
            std::max<GLsizei>(texture.desc.height, 0));
        request.layers = texture.target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY
            ? static_cast<NSUInteger>(
                  std::max<GLsizei>(std::max(texture.desc.layers,
                                             texture.desc.depth),
                                    1))
            : 1u;
        request.samples = static_cast<NSUInteger>(
            std::max<GLsizei>(texture.desc.samples, 1));
    }

    if (request.pixelFormat == MTLPixelFormatInvalid ||
        request.width == 0 || request.height == 0 ||
        request.layers == 0 || request.samples == 0) {
        return false;
    }
    if (request.layers >
        std::numeric_limits<NSUInteger>::max() / request.samples) {
        return false;
    }
    request.arrayLength = request.layers * request.samples;
    return request.arrayLength > 0;
}

bool matchesRequest(const MultisampleStorageImageSidecarInfo& info,
                    const SidecarRequest& request) {
    return info.target == request.target &&
           info.internalFormat == request.internalFormat &&
           info.metalPixelFormat ==
               static_cast<std::uint64_t>(request.pixelFormat) &&
           info.width == static_cast<GLsizei>(request.width) &&
           info.height == static_cast<GLsizei>(request.height) &&
           info.layers == static_cast<GLsizei>(request.layers) &&
           info.samples == static_cast<GLsizei>(request.samples) &&
           info.arrayLength == static_cast<GLsizei>(request.arrayLength) &&
           info.metalTexture != nullptr;
}

MultisampleStorageImageSidecarInfo makeInfo(void* retainedTexture,
                                            const SidecarRequest& request) {
    MultisampleStorageImageSidecarInfo info;
    info.metalTexture = retainedTexture;
    info.target = request.target;
    info.internalFormat = request.internalFormat;
    info.metalPixelFormat = static_cast<std::uint64_t>(request.pixelFormat);
    info.width = static_cast<GLsizei>(request.width);
    info.height = static_cast<GLsizei>(request.height);
    info.layers = static_cast<GLsizei>(request.layers);
    info.samples = static_cast<GLsizei>(request.samples);
    info.arrayLength = static_cast<GLsizei>(request.arrayLength);
    return info;
}

id<MTLTexture> createSidecarTexture(id<MTLDevice> device,
                                    const SidecarRequest& request) {
    if (device == nil) {
        return nil;
    }
    MTLTextureDescriptor* desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = MTLTextureType2DArray;
    desc.pixelFormat = request.pixelFormat;
    desc.width = request.width;
    desc.height = request.height;
    desc.depth = 1;
    desc.arrayLength = request.arrayLength;
    desc.mipmapLevelCount = singleMipLevelCount<NSUInteger>();
    desc.sampleCount = 1;
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    desc.allowGPUOptimizedContents = NO;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    releaseObjectiveCObject(desc);
    return texture;
}

ContextState& contextStateForLocked(ExtensionContext& ctx) {
    return contextStates()[&ctx.context()];
}

}  // namespace

bool isMultisampleStorageImageTarget(GLenum target) {
    return target == GL_TEXTURE_2D_MULTISAMPLE ||
           target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY;
}

std::uint32_t multisampleStorageImageSidecarSlice(GLint layer,
                                                  GLint sample,
                                                  GLsizei samples) {
    const std::uint32_t safeLayer =
        static_cast<std::uint32_t>(std::max<GLint>(layer, 0));
    const std::uint32_t safeSample =
        static_cast<std::uint32_t>(std::max<GLint>(sample, 0));
    const std::uint32_t safeSamples =
        static_cast<std::uint32_t>(std::max<GLsizei>(samples, 1));
    return safeLayer * safeSamples + safeSample;
}

bool supportsMultisampleStorageImageSidecar(ExtensionContext& ctx) {
    {
        std::lock_guard<std::mutex> lock(stateMutex());
        ContextState& state = contextStateForLocked(ctx);
        if (state.capabilityProbe.has_value()) {
            return *state.capabilityProbe;
        }
    }

    const bool supported = probeSidecarCapability(metalDevice(ctx));

    std::lock_guard<std::mutex> lock(stateMutex());
    ContextState& state = contextStateForLocked(ctx);
    state.capabilityProbe = supported;
    return supported;
}

bool ensureMultisampleStorageImageSidecar(
    ExtensionContext& ctx,
    GLTextureObject& texture,
    MultisampleStorageImageSidecarInfo* outInfo) {
    SidecarRequest request;
    if (!requestForTexture(ctx, texture, request)) {
        return false;
    }
    if (!supportsMultisampleStorageImageSidecar(ctx)) {
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(stateMutex());
        ContextState& state = contextStateForLocked(ctx);
        auto it = state.sidecars.find(&texture);
        if (it != state.sidecars.end() && matchesRequest(it->second.info, request)) {
            if (outInfo != nullptr) {
                *outInfo = it->second.info;
            }
            return true;
        }
    }

    id<MTLTexture> sidecar = createSidecarTexture(metalDevice(ctx), request);
    if (sidecar == nil) {
        return false;
    }
    void* retainedSidecar = transferRetainedMetalObject(sidecar);
    MultisampleStorageImageSidecarInfo newInfo =
        makeInfo(retainedSidecar, request);

    std::lock_guard<std::mutex> lock(stateMutex());
    ContextState& state = contextStateForLocked(ctx);
    SidecarState& entry = state.sidecars[&texture];
    releaseRetainedMetalObject(entry.info.metalTexture);
    entry.info = newInfo;
    if (outInfo != nullptr) {
        *outInfo = entry.info;
    }
    return true;
}

bool getMultisampleStorageImageSidecar(
    ExtensionContext& ctx,
    const GLTextureObject& texture,
    MultisampleStorageImageSidecarInfo& outInfo) {
    std::lock_guard<std::mutex> lock(stateMutex());
    auto contextIt = contextStates().find(&ctx.context());
    if (contextIt == contextStates().end()) {
        return false;
    }
    auto sidecarIt = contextIt->second.sidecars.find(&texture);
    if (sidecarIt == contextIt->second.sidecars.end() ||
        sidecarIt->second.info.metalTexture == nullptr) {
        return false;
    }
    outInfo = sidecarIt->second.info;
    return true;
}

void resetMultisampleStorageImageSidecar(ExtensionContext& ctx,
                                         GLTextureObject& texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    auto contextIt = contextStates().find(&ctx.context());
    if (contextIt == contextStates().end()) {
        return;
    }
    auto sidecarIt = contextIt->second.sidecars.find(&texture);
    if (sidecarIt == contextIt->second.sidecars.end()) {
        return;
    }
    releaseRetainedMetalObject(sidecarIt->second.info.metalTexture);
    sidecarIt->second.info = {};
}

void destroyMultisampleStorageImageSidecar(ExtensionContext& ctx,
                                           GLTextureObject& texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    auto contextIt = contextStates().find(&ctx.context());
    if (contextIt == contextStates().end()) {
        return;
    }
    auto sidecarIt = contextIt->second.sidecars.find(&texture);
    if (sidecarIt == contextIt->second.sidecars.end()) {
        return;
    }
    releaseRetainedMetalObject(sidecarIt->second.info.metalTexture);
    contextIt->second.sidecars.erase(sidecarIt);
}

void destroyMultisampleStorageImageSidecars(ExtensionContext& ctx) {
    std::lock_guard<std::mutex> lock(stateMutex());
    auto contextIt = contextStates().find(&ctx.context());
    if (contextIt == contextStates().end()) {
        return;
    }
    for (auto& entry : contextIt->second.sidecars) {
        releaseRetainedMetalObject(entry.second.info.metalTexture);
    }
    contextStates().erase(contextIt);
}

MultisampleStorageImageSidecarInventory multisampleStorageImageSidecarInventory(
    const GLContext& context) {
    std::lock_guard<std::mutex> lock(stateMutex());
    MultisampleStorageImageSidecarInventory inventory;
    auto contextIt = contextStates().find(&context);
    if (contextIt == contextStates().end()) {
        return inventory;
    }
    for (const auto& entry : contextIt->second.sidecars) {
        const MultisampleStorageImageSidecarInfo& info = entry.second.info;
        if (info.metalTexture == nullptr) {
            continue;
        }
        ++inventory.sidecars;
        id<MTLResource> resource = (__bridge id<MTLResource>)info.metalTexture;
        if (resource != nil && [resource respondsToSelector:@selector(allocatedSize)]) {
            inventory.sidecarBytes += static_cast<std::uint64_t>(resource.allocatedSize);
        }
    }
    return inventory;
}

}  // namespace appgl::extensions::sparse_texture
