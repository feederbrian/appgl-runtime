#include "SparseStorageImageEmulation.h"

#include "MultisampleStorageImageEmulation.h"
#include "SparseTextureAlloc.h"
#include "../ExtensionContext.h"
#include "../../objects/GLObjectStore.h"

#include <CoreFoundation/CoreFoundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <mutex>
#include <unordered_map>

namespace appgl::extensions::sparse_texture {
namespace {

struct SidecarState {
    SparseStorageImageSidecarInfo info;
};

struct ContextState {
    std::unordered_map<GLenum, bool> capabilityProbe;
    std::unordered_map<const GLTextureObject*, SidecarState> sidecars;
};

struct SidecarRequest {
    GLenum target = 0;
    GLenum internalFormat = 0;
    MTLPixelFormat pixelFormat = MTLPixelFormatInvalid;
    MTLTextureType textureType = MTLTextureType2D;
    NSUInteger width = 0;
    NSUInteger height = 0;
    NSUInteger depth = 0;
    NSUInteger layers = 0;
    NSUInteger levels = 0;
    NSUInteger arrayLength = 0;
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
#else
    (void)object;
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

MTLTextureType metalTextureTypeForTarget(GLenum target) {
    switch (target) {
        case GL_TEXTURE_2D:
        case GL_TEXTURE_RECTANGLE:
            return MTLTextureType2D;
        case GL_TEXTURE_3D:
            return MTLTextureType3D;
        case GL_TEXTURE_2D_ARRAY:
            return MTLTextureType2DArray;
        case GL_TEXTURE_CUBE_MAP:
            return MTLTextureTypeCube;
        case GL_TEXTURE_CUBE_MAP_ARRAY:
            return MTLTextureTypeCubeArray;
        default:
            return MTLTextureType2D;
    }
}

const char* probeSourceForTarget(GLenum target) {
    switch (target) {
        case GL_TEXTURE_2D:
        case GL_TEXTURE_RECTANGLE:
            return
                "#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "kernel void appgl_sparse_storage_sidecar_probe(\n"
                "    texture2d<float, access::write> sidecar [[texture(0)]],\n"
                "    uint2 gid [[thread_position_in_grid]]) {\n"
                "    sidecar.write(float4(1.0), gid);\n"
                "}\n";
        case GL_TEXTURE_2D_ARRAY:
            return
                "#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "kernel void appgl_sparse_storage_sidecar_probe(\n"
                "    texture2d_array<float, access::write> sidecar [[texture(0)]],\n"
                "    uint2 gid [[thread_position_in_grid]]) {\n"
                "    sidecar.write(float4(1.0), gid, 0);\n"
                "}\n";
        case GL_TEXTURE_3D:
            return
                "#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "kernel void appgl_sparse_storage_sidecar_probe(\n"
                "    texture3d<float, access::write> sidecar [[texture(0)]],\n"
                "    uint3 gid [[thread_position_in_grid]]) {\n"
                "    sidecar.write(float4(1.0), gid);\n"
                "}\n";
        case GL_TEXTURE_CUBE_MAP:
            return
                "#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "kernel void appgl_sparse_storage_sidecar_probe(\n"
                "    texturecube<float, access::write> sidecar [[texture(0)]],\n"
                "    uint2 gid [[thread_position_in_grid]]) {\n"
                "    sidecar.write(float4(1.0), gid, 0);\n"
                "}\n";
        case GL_TEXTURE_CUBE_MAP_ARRAY:
            return
                "#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "kernel void appgl_sparse_storage_sidecar_probe(\n"
                "    texturecube_array<float, access::write> sidecar [[texture(0)]],\n"
                "    uint2 gid [[thread_position_in_grid]]) {\n"
                "    sidecar.write(float4(1.0), gid, 0, 0);\n"
                "}\n";
        default:
            return nullptr;
    }
}

MTLTextureDescriptor* newProbeDescriptor(GLenum target) {
    MTLTextureDescriptor* desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = metalTextureTypeForTarget(target);
    desc.pixelFormat = MTLPixelFormatRGBA8Unorm;
    desc.width = 4;
    desc.height = 4;
    desc.depth = target == GL_TEXTURE_3D ? 4u : 1u;
    desc.arrayLength = target == GL_TEXTURE_2D_ARRAY ? 4u
        : (target == GL_TEXTURE_CUBE_MAP_ARRAY ? 2u : 1u);
    desc.mipmapLevelCount = 1;
    desc.sampleCount = 1;
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead |
                 MTLTextureUsageShaderWrite |
                 MTLTextureUsagePixelFormatView;
    desc.allowGPUOptimizedContents = NO;
    return desc;
}

bool probeSidecarCapability(id<MTLDevice> device, GLenum target) {
    if (device == nil || !isSparseStorageImageSidecarTarget(target)) {
        return false;
    }
    const char* source = probeSourceForTarget(target);
    if (source == nullptr) {
        return false;
    }

    MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
    options.languageVersion = MTLLanguageVersion2_4;

    NSError* libError = nil;
    id<MTLLibrary> library =
        [device newLibraryWithSource:[NSString stringWithUTF8String:source]
                              options:options
                                error:&libError];
    if (library == nil) {
        releaseObjectiveCObject(options);
        return false;
    }
    id<MTLFunction> function =
        [library newFunctionWithName:@"appgl_sparse_storage_sidecar_probe"];
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

    MTLTextureDescriptor* desc = newProbeDescriptor(target);
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

ContextState& contextStateForLocked(ExtensionContext& ctx) {
    return contextStates()[&ctx.context()];
}

bool requestForTexture(ExtensionContext& ctx,
                       const GLTextureObject& texture,
                       SidecarRequest& request) {
    if (!isSparseStorageImageSidecarTarget(texture.target) ||
        isMultisampleStorageImageTarget(texture.target) ||
        textureSparse(ctx, &texture) != GL_TRUE ||
        texture.metalTexture == nullptr) {
        return false;
    }

    id<MTLTexture> metalTexture =
        (__bridge id<MTLTexture>)texture.metalTexture;
    if (metalTexture == nil) {
        return false;
    }

    request.target = texture.target;
    request.internalFormat = texture.desc.internalFormat;
    request.pixelFormat = metalTexture.pixelFormat;
    request.textureType = metalTexture.textureType;
    request.width = metalTexture.width;
    request.height = metalTexture.height;
    request.depth = 1u;
    request.layers = 1u;
    request.levels = std::max<NSUInteger>(metalTexture.mipmapLevelCount, 1u);
    request.arrayLength = 1u;

    switch (texture.target) {
        case GL_TEXTURE_3D:
            request.depth = std::max<NSUInteger>(metalTexture.depth, 1u);
            break;
        case GL_TEXTURE_2D_ARRAY:
            request.arrayLength = std::max<NSUInteger>(metalTexture.arrayLength, 1u);
            request.layers = request.arrayLength;
            break;
        case GL_TEXTURE_CUBE_MAP:
            request.layers = 6u;
            break;
        case GL_TEXTURE_CUBE_MAP_ARRAY:
            request.arrayLength = std::max<NSUInteger>(metalTexture.arrayLength, 1u);
            request.layers = request.arrayLength * 6u;
            break;
        default:
            break;
    }

    return request.pixelFormat != MTLPixelFormatInvalid &&
           request.width > 0 &&
           request.height > 0 &&
           request.depth > 0 &&
           request.layers > 0 &&
           request.levels > 0 &&
           request.arrayLength > 0;
}

bool matchesRequest(const SparseStorageImageSidecarInfo& info,
                    const SidecarRequest& request) {
    return info.target == request.target &&
           info.internalFormat == request.internalFormat &&
           info.metalPixelFormat ==
               static_cast<std::uint64_t>(request.pixelFormat) &&
           info.metalTextureType ==
               static_cast<std::uint64_t>(request.textureType) &&
           info.width == static_cast<GLsizei>(request.width) &&
           info.height == static_cast<GLsizei>(request.height) &&
           info.depth == static_cast<GLsizei>(request.depth) &&
           info.layers == static_cast<GLsizei>(request.layers) &&
           info.levels == static_cast<GLsizei>(request.levels) &&
           info.arrayLength == static_cast<GLsizei>(request.arrayLength) &&
           info.metalTexture != nullptr;
}

SparseStorageImageSidecarInfo makeInfo(void* retainedTexture,
                                       const SidecarRequest& request) {
    SparseStorageImageSidecarInfo info;
    info.metalTexture = retainedTexture;
    info.target = request.target;
    info.internalFormat = request.internalFormat;
    info.metalPixelFormat = static_cast<std::uint64_t>(request.pixelFormat);
    info.metalTextureType = static_cast<std::uint64_t>(request.textureType);
    info.width = static_cast<GLsizei>(request.width);
    info.height = static_cast<GLsizei>(request.height);
    info.depth = static_cast<GLsizei>(request.depth);
    info.layers = static_cast<GLsizei>(request.layers);
    info.levels = static_cast<GLsizei>(request.levels);
    info.arrayLength = static_cast<GLsizei>(request.arrayLength);
    return info;
}

id<MTLTexture> createSidecarTexture(id<MTLDevice> device,
                                    const SidecarRequest& request) {
    if (device == nil) {
        return nil;
    }
    MTLTextureDescriptor* desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = request.textureType;
    desc.pixelFormat = request.pixelFormat;
    desc.width = request.width;
    desc.height = request.height;
    desc.depth = request.depth;
    desc.arrayLength = request.arrayLength;
    desc.mipmapLevelCount = request.levels;
    desc.sampleCount = 1;
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead |
                 MTLTextureUsageShaderWrite |
                 MTLTextureUsagePixelFormatView;
    desc.allowGPUOptimizedContents = NO;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    releaseObjectiveCObject(desc);
    return texture;
}

}  // namespace

bool isSparseStorageImageSidecarTarget(GLenum target) {
    switch (target) {
        case GL_TEXTURE_2D:
        case GL_TEXTURE_2D_ARRAY:
        case GL_TEXTURE_CUBE_MAP:
        case GL_TEXTURE_CUBE_MAP_ARRAY:
        case GL_TEXTURE_3D:
        case GL_TEXTURE_RECTANGLE:
            return true;
        default:
            return false;
    }
}

bool supportsSparseStorageImageSidecar(ExtensionContext& ctx, GLenum target) {
    if (!isSparseStorageImageSidecarTarget(target)) {
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(stateMutex());
        ContextState& state = contextStateForLocked(ctx);
        auto it = state.capabilityProbe.find(target);
        if (it != state.capabilityProbe.end()) {
            return it->second;
        }
    }

    const bool supported = probeSidecarCapability(metalDevice(ctx), target);

    std::lock_guard<std::mutex> lock(stateMutex());
    ContextState& state = contextStateForLocked(ctx);
    state.capabilityProbe[target] = supported;
    return supported;
}

bool ensureSparseStorageImageSidecar(ExtensionContext& ctx,
                                     GLTextureObject& texture,
                                     SparseStorageImageSidecarInfo* outInfo) {
    SidecarRequest request;
    if (!requestForTexture(ctx, texture, request)) {
        return false;
    }
    if (!supportsSparseStorageImageSidecar(ctx, request.target)) {
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(stateMutex());
        ContextState& state = contextStateForLocked(ctx);
        auto it = state.sidecars.find(&texture);
        if (it != state.sidecars.end() &&
            matchesRequest(it->second.info, request)) {
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
    SparseStorageImageSidecarInfo newInfo =
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

SparseStorageImageWriteBindingRoute resolveSparseStorageImageWriteBinding(
    ExtensionContext& ctx,
    GLTextureObject& texture,
    GLenum shaderImageTarget,
    SparseStorageImageSidecarInfo* outInfo) {
    if (!isSparseStorageImageSidecarTarget(shaderImageTarget)) {
        return SparseStorageImageWriteBindingRoute::NativeTexture;
    }
    if (textureSparse(ctx, &texture) != GL_TRUE) {
        return SparseStorageImageWriteBindingRoute::NativeTexture;
    }
    if (!isSparseStorageImageSidecarTarget(texture.target) ||
        isMultisampleStorageImageTarget(texture.target) ||
        texture.target != shaderImageTarget) {
        return SparseStorageImageWriteBindingRoute::SparseSidecarUnavailable;
    }

    SparseStorageImageSidecarInfo info;
    if (!ensureSparseStorageImageSidecar(ctx, texture, &info) ||
        info.metalTexture == nullptr) {
        return SparseStorageImageWriteBindingRoute::SparseSidecarUnavailable;
    }
    if (outInfo != nullptr) {
        *outInfo = info;
    }
    return SparseStorageImageWriteBindingRoute::SidecarTexture;
}

bool getSparseStorageImageSidecar(ExtensionContext& ctx,
                                  const GLTextureObject& texture,
                                  SparseStorageImageSidecarInfo& outInfo) {
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

void resetSparseStorageImageSidecar(ExtensionContext& ctx,
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

void destroySparseStorageImageSidecar(ExtensionContext& ctx,
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

void destroySparseStorageImageSidecars(ExtensionContext& ctx) {
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

}  // namespace appgl::extensions::sparse_texture
