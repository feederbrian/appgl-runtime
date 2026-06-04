#include "SparseTextureAlloc.h"

#include "MultisampleStorageImageEmulation.h"
#include "SparseStorageImageEmulation.h"
#include "../ExtensionContext.h"
#include "../../caps/GLCapabilities.h"
#include "../../context/GLContext.h"
#include "../../context/MetalCommandSubmission.h"
#include "../../objects/GLObjectStore.h"

#include <CoreFoundation/CoreFoundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <mutex>
#include <unordered_map>

namespace appgl::extensions::sparse_texture {

namespace {

struct TextureState {
    GLint sparse = GL_FALSE;
    GLint virtualPageSizeIndex = 0;
    GLsizei sparseLevels = 0;
    void* sparseHeap = nullptr;
    std::vector<CommittedRegion> committedRegions;
};

struct ContextState {
    std::unordered_map<const GLTextureObject*, TextureState> textures;
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

TextureState& stateForLocked(ExtensionContext& ctx, const GLTextureObject& texture) {
    return contextStates()[&ctx.context()].textures[&texture];
}

TextureState* findStateLocked(ExtensionContext& ctx, const GLTextureObject* texture) {
    if (texture == nullptr) {
        return nullptr;
    }
    auto contextIt = contextStates().find(&ctx.context());
    if (contextIt == contextStates().end()) {
        return nullptr;
    }
    auto textureIt = contextIt->second.textures.find(texture);
    if (textureIt == contextIt->second.textures.end()) {
        return nullptr;
    }
    return &textureIt->second;
}

void releaseTextureStorage(TextureState& state) {
    releaseRetainedMetalObject(state.sparseHeap);
    state.sparseHeap = nullptr;
    state.committedRegions.clear();
    state.sparseLevels = 0;
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

id<MTLCommandQueue> metalCommandQueue(ExtensionContext& ctx) {
    return (__bridge id<MTLCommandQueue>)ctx.metalCommandQueue();
}

MetalCommandSubmission* metalCommandSubmission(ExtensionContext& ctx) {
    return static_cast<MetalCommandSubmission*>(ctx.metalCommandSubmission());
}

MTLTextureType metalTextureTypeForTarget(GLenum target) {
    switch (target) {
        case GL_TEXTURE_2D:
        case GL_TEXTURE_RECTANGLE:
            return MTLTextureType2D;
        case GL_TEXTURE_2D_MULTISAMPLE:
            return MTLTextureType2DMultisample;
        case GL_TEXTURE_3D:
            return MTLTextureType3D;
        case GL_TEXTURE_2D_ARRAY:
            return MTLTextureType2DArray;
        case GL_TEXTURE_2D_MULTISAMPLE_ARRAY:
            return MTLTextureType2DMultisampleArray;
        case GL_TEXTURE_CUBE_MAP:
            return MTLTextureTypeCube;
        case GL_TEXTURE_CUBE_MAP_ARRAY:
            return MTLTextureTypeCubeArray;
        default:
            return MTLTextureType2D;
    }
}

MTLPixelFormat metalPixelFormatForInternalFormat(ExtensionContext& ctx, GLenum internalformat) {
    const auto capability = ctx.capabilities().format(internalformat);
    if (!capability.has_value()) {
        return MTLPixelFormatInvalid;
    }
    return static_cast<MTLPixelFormat>(capability->metalPixelFormat);
}

NSUInteger sparseTileSampleCount(GLenum target, GLsizei samples) {
    if (!isMultisampleStorageImageTarget(target)) {
        return 1u;
    }
    return static_cast<NSUInteger>(std::max<GLsizei>(samples, 2));
}

MTLSize sparsePageSizeForFormat(ExtensionContext& ctx,
                                GLenum target,
                                GLenum internalformat,
                                GLsizei samples = 1) {
    id<MTLDevice> device = metalDevice(ctx);
    if (device == nil || !isAllocationTarget(target)) {
        return MTLSizeMake(0, 0, 0);
    }
    const MTLPixelFormat pixelFormat = metalPixelFormatForInternalFormat(ctx, internalformat);
    if (pixelFormat == MTLPixelFormatInvalid) {
        return MTLSizeMake(0, 0, 0);
    }
    MTLSize tile = [device sparseTileSizeWithTextureType:metalTextureTypeForTarget(target)
                                             pixelFormat:pixelFormat
                                             sampleCount:sparseTileSampleCount(target, samples)];
    if (tile.width == 0 || tile.height == 0) {
        return MTLSizeMake(0, 0, 0);
    }
    return MTLSizeMake(tile.width, tile.height, std::max<NSUInteger>(tile.depth, 1));
}

NSUInteger divRoundUp(NSUInteger value, NSUInteger divisor) {
    return divisor == 0 ? 0 : (value + divisor - 1) / divisor;
}

std::size_t safeDimension(GLsizei value) {
    return static_cast<std::size_t>(std::max<GLsizei>(value, 1));
}

MTLSparsePageSize sparseHeapPageSizeForDevice(id<MTLDevice> device) {
    if (device == nil) {
        return MTLSparsePageSize16;
    }
    const NSUInteger pageBytes = [device sparseTileSizeInBytes];
    if (pageBytes >= 262144u) {
        return MTLSparsePageSize256;
    }
    if (pageBytes >= 65536u) {
        return MTLSparsePageSize64;
    }
    return MTLSparsePageSize16;
}

NSUInteger physicalPageEstimate(const GLTextureObject& texture, const MTLSize& page) {
    NSUInteger totalPages = 0;
    for (const auto& [levelIndex, image] : texture.levels) {
        (void)levelIndex;
        if (!image.defined) {
            continue;
        }
        const NSUInteger pageX = std::max<NSUInteger>(page.width, 1u);
        const NSUInteger pageY = std::max<NSUInteger>(page.height, 1u);
        const NSUInteger pageZ = std::max<NSUInteger>(page.depth, 1u);
        const NSUInteger tilesX =
            divRoundUp(static_cast<NSUInteger>(safeDimension(image.desc.width)), pageX);
        const NSUInteger tilesY =
            divRoundUp(static_cast<NSUInteger>(safeDimension(image.desc.height)), pageY);
        const NSUInteger imageDepth = static_cast<NSUInteger>(safeDimension(image.desc.depth));
        const NSUInteger tilesZ = texture.target == GL_TEXTURE_3D
            ? divRoundUp(imageDepth, pageZ)
            : (targetUsesSlices(texture.target) ? imageDepth : 1u);
        totalPages += std::max<NSUInteger>(tilesX * tilesY * tilesZ, 1u);
    }
    return std::max<NSUInteger>(totalPages, 1u);
}

bool blitUpload2DRegion(ExtensionContext& ctx,
                        id<MTLTexture> destination,
                        id<MTLBlitCommandEncoder> blit,
                        const std::uint8_t* bytes,
                        NSUInteger bytesPerRow,
                        NSUInteger bytesPerImage,
                        const MTLRegion& region,
                        NSUInteger mipLevel,
                        NSUInteger slice,
                        std::size_t sourceBpp) {
    if (destination == nil || blit == nil || bytes == nullptr) {
        return false;
    }
    id<MTLDevice> device = metalDevice(ctx);
    if (device == nil) {
        return false;
    }
    const MTLPixelFormat pf = destination.pixelFormat;
    const bool isDepthStencil =
        pf == MTLPixelFormatDepth32Float_Stencil8 ||
        pf == MTLPixelFormatDepth24Unorm_Stencil8;
    if (!isDepthStencil) {
        id<MTLBuffer> staging = [device newBufferWithBytes:bytes
                                                    length:bytesPerImage
                                                   options:MTLResourceStorageModeShared];
        if (staging == nil) {
            return false;
        }
        [blit copyFromBuffer:staging
                sourceOffset:0
           sourceBytesPerRow:bytesPerRow
         sourceBytesPerImage:bytesPerImage
                  sourceSize:region.size
                   toTexture:destination
            destinationSlice:slice
            destinationLevel:mipLevel
           destinationOrigin:region.origin];
        return true;
    }

    const NSUInteger width = region.size.width;
    const NSUInteger height = region.size.height;
    const NSUInteger srcRowStride =
        bytesPerRow != 0 ? bytesPerRow : width * static_cast<NSUInteger>(sourceBpp);
    const NSUInteger depthBpp = 4;
    const NSUInteger depthRowBytes = width * depthBpp;
    const NSUInteger depthImageBytes = depthRowBytes * height;
    const NSUInteger stencilRowBytes = width;
    const NSUInteger stencilImageBytes = stencilRowBytes * height;
    std::vector<std::uint8_t> depthBytes(depthImageBytes, 0);
    std::vector<std::uint8_t> stencilBytes(stencilImageBytes, 0);
    for (NSUInteger row = 0; row < height; ++row) {
        const auto* srcRow = bytes + static_cast<std::size_t>(row * srcRowStride);
        auto* dstDepthRow = depthBytes.data() + static_cast<std::size_t>(row * depthRowBytes);
        auto* dstStencilRow = stencilBytes.data() + static_cast<std::size_t>(row * stencilRowBytes);
        for (NSUInteger col = 0; col < width; ++col) {
            const auto* src = srcRow + static_cast<std::size_t>(col * sourceBpp);
            if (pf == MTLPixelFormatDepth32Float_Stencil8) {
                std::memcpy(dstDepthRow + static_cast<std::size_t>(col * depthBpp), src, depthBpp);
                dstStencilRow[col] = sourceBpp > 4 ? src[4] : 0;
            } else {
                std::uint32_t packed = 0;
                std::memcpy(&packed, src, std::min<std::size_t>(sourceBpp, sizeof(packed)));
                const std::uint32_t depth24 = packed & 0x00FFFFFFu;
                std::memcpy(dstDepthRow + static_cast<std::size_t>(col * depthBpp),
                            &depth24,
                            sizeof(depth24));
                dstStencilRow[col] = static_cast<std::uint8_t>((packed >> 24) & 0xFFu);
            }
        }
    }

    id<MTLBuffer> depthStaging = [device newBufferWithBytes:depthBytes.data()
                                                     length:depthImageBytes
                                                    options:MTLResourceStorageModeShared];
    id<MTLBuffer> stencilStaging = [device newBufferWithBytes:stencilBytes.data()
                                                       length:stencilImageBytes
                                                      options:MTLResourceStorageModeShared];
    if (depthStaging == nil || stencilStaging == nil) {
        return false;
    }
    [blit copyFromBuffer:depthStaging
            sourceOffset:0
       sourceBytesPerRow:depthRowBytes
     sourceBytesPerImage:depthImageBytes
              sourceSize:region.size
               toTexture:destination
        destinationSlice:slice
        destinationLevel:mipLevel
       destinationOrigin:region.origin
                 options:MTLBlitOptionDepthFromDepthStencil];
    [blit copyFromBuffer:stencilStaging
            sourceOffset:0
       sourceBytesPerRow:stencilRowBytes
     sourceBytesPerImage:stencilImageBytes
              sourceSize:region.size
               toTexture:destination
        destinationSlice:slice
        destinationLevel:mipLevel
       destinationOrigin:region.origin
                 options:MTLBlitOptionStencilFromDepthStencil];
    return true;
}

bool regionsOverlap(const CommittedRegion& a, const CommittedRegion& b) {
    if (a.level != b.level) {
        return false;
    }
    const bool xOverlap =
        a.xoffset < b.xoffset + b.width && b.xoffset < a.xoffset + a.width;
    const bool yOverlap =
        a.yoffset < b.yoffset + b.height && b.yoffset < a.yoffset + a.height;
    const bool zOverlap =
        a.zoffset < b.zoffset + b.depth && b.zoffset < a.zoffset + a.depth;
    return xOverlap && yOverlap && zOverlap;
}

bool updateTextureMapping(ExtensionContext& ctx,
                          GLTextureObject& textureObject,
                          const CommittedRegion& region,
                          bool commit) {
    id<MTLCommandQueue> commandQueue = metalCommandQueue(ctx);
    if (commandQueue == nil || textureObject.metalTexture == nullptr) {
        return false;
    }
    id<MTLTexture> texture = (__bridge id<MTLTexture>)textureObject.metalTexture;
    if (texture == nil || ![texture isSparse]) {
        return false;
    }
    const MTLSize page =
        sparsePageSizeForFormat(ctx,
                                textureObject.target,
                                textureObject.desc.internalFormat,
                                textureObject.desc.samples);
    if (page.width == 0 || page.height == 0) {
        return false;
    }
    if (region.width == 0 || region.height == 0 || region.depth == 0) {
        return true;
    }

    MetalCommandSubmission* submission = metalCommandSubmission(ctx);
    auto lease = submission != nullptr
        ? submission->makeCommandBuffer(AppGLCommandReason::SparseResidency)
        : MetalCommandBufferLease{};
    id<MTLCommandBuffer> cmd = lease.get();
    if (cmd == nil) {
        return false;
    }
    id<MTLResourceStateCommandEncoder> encoder = [cmd resourceStateCommandEncoder];
    if (encoder == nil) {
        return false;
    }

    const MTLSparseTextureMappingMode mode =
        commit ? MTLSparseTextureMappingModeMap : MTLSparseTextureMappingModeUnmap;
    const NSUInteger pageX = std::max<NSUInteger>(page.width, 1u);
    const NSUInteger pageY = std::max<NSUInteger>(page.height, 1u);
    const NSUInteger pageZ = std::max<NSUInteger>(page.depth, 1u);
    const NSUInteger tileX = static_cast<NSUInteger>(region.xoffset) / pageX;
    const NSUInteger tileY = static_cast<NSUInteger>(region.yoffset) / pageY;
    const NSUInteger tilesW = divRoundUp(static_cast<NSUInteger>(region.width), pageX);
    const NSUInteger tilesH = divRoundUp(static_cast<NSUInteger>(region.height), pageY);

    if (textureObject.target == GL_TEXTURE_3D) {
        const NSUInteger tileZ = static_cast<NSUInteger>(region.zoffset) / pageZ;
        const NSUInteger tilesD = divRoundUp(static_cast<NSUInteger>(region.depth), pageZ);
        const MTLRegion tileRegion = MTLRegionMake3D(tileX, tileY, tileZ, tilesW, tilesH, tilesD);
        [encoder updateTextureMapping:texture
                                  mode:mode
                                region:tileRegion
                              mipLevel:static_cast<NSUInteger>(region.level)
                                 slice:0];
    } else if (targetUsesSlices(textureObject.target)) {
        const GLint endSlice = region.zoffset + region.depth;
        for (GLint slice = region.zoffset; slice < endSlice; ++slice) {
            const MTLRegion tileRegion = MTLRegionMake2D(tileX, tileY, tilesW, tilesH);
            [encoder updateTextureMapping:texture
                                      mode:mode
                                    region:tileRegion
                                  mipLevel:static_cast<NSUInteger>(region.level)
                                     slice:static_cast<NSUInteger>(slice)];
        }
    } else {
        const MTLRegion tileRegion = MTLRegionMake2D(tileX, tileY, tilesW, tilesH);
        [encoder updateTextureMapping:texture
                                  mode:mode
                                region:tileRegion
                              mipLevel:static_cast<NSUInteger>(region.level)
                                 slice:0];
    }

    [encoder endEncoding];
    return lease.commitAndWait(AppGLCommandReason::SparseResidency);
}

}  // namespace

bool isAllocationTarget(GLenum target) {
    switch (target) {
        case GL_TEXTURE_2D:
        case GL_TEXTURE_2D_ARRAY:
        case GL_TEXTURE_CUBE_MAP:
        case GL_TEXTURE_CUBE_MAP_ARRAY:
        case GL_TEXTURE_3D:
        case GL_TEXTURE_RECTANGLE:
        case GL_TEXTURE_2D_MULTISAMPLE:
        case GL_TEXTURE_2D_MULTISAMPLE_ARRAY:
            return true;
        default:
            return false;
    }
}

bool targetUsesSlices(GLenum target) {
    return target == GL_TEXTURE_2D_ARRAY ||
           target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY ||
           target == GL_TEXTURE_CUBE_MAP ||
           target == GL_TEXTURE_CUBE_MAP_ARRAY;
}

GLsizei storedDepthForTarget(GLenum target, GLsizei depth) {
    switch (target) {
        case GL_TEXTURE_3D:
        case GL_TEXTURE_2D_ARRAY:
        case GL_TEXTURE_2D_MULTISAMPLE_ARRAY:
        case GL_TEXTURE_CUBE_MAP_ARRAY:
            return std::max<GLsizei>(depth, 1);
        case GL_TEXTURE_CUBE_MAP:
            return 6;
        default:
            return 1;
    }
}

GLint textureSparse(ExtensionContext& ctx, const GLTextureObject* texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, texture);
    return state != nullptr ? state->sparse : GL_FALSE;
}

void setTextureSparse(ExtensionContext& ctx, GLTextureObject& texture, GLint value) {
    std::lock_guard<std::mutex> lock(stateMutex());
    stateForLocked(ctx, texture).sparse = value;
    texture.sparseTexture = (value == GL_TRUE);
}

GLint virtualPageSizeIndex(ExtensionContext& ctx, const GLTextureObject* texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, texture);
    return state != nullptr ? state->virtualPageSizeIndex : 0;
}

void setVirtualPageSizeIndex(ExtensionContext& ctx, GLTextureObject& texture, GLint value) {
    std::lock_guard<std::mutex> lock(stateMutex());
    stateForLocked(ctx, texture).virtualPageSizeIndex = value;
}

GLsizei sparseLevels(ExtensionContext& ctx, const GLTextureObject* texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, texture);
    return state != nullptr ? state->sparseLevels : 0;
}

void setSparseLevels(ExtensionContext& ctx, GLTextureObject& texture, GLsizei levels) {
    std::lock_guard<std::mutex> lock(stateMutex());
    stateForLocked(ctx, texture).sparseLevels = levels;
}

bool validateStorageRequest(ExtensionContext& ctx,
                            const GLTextureObject& texture,
                            GLenum target,
                            GLenum internalformat,
                            GLsizei levels,
                            GLsizei width,
                            GLsizei height,
                            GLsizei depth,
                            GLsizei samples) {
    if (!isAllocationTarget(target)) {
        ctx.pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (target == GL_TEXTURE_CUBE_MAP && width != height) {
        ctx.pushError(GL_INVALID_VALUE);
        return false;
    }

    const MTLSize page = sparsePageSizeForFormat(ctx, target, internalformat, samples);
    const GLint pageCount = (page.width > 0 && page.height > 0) ? 1 : 0;
    const GLint pageSizeIndex = virtualPageSizeIndex(ctx, &texture);
    if (pageSizeIndex < 0 || pageSizeIndex >= pageCount) {
        ctx.pushError(GL_INVALID_OPERATION);
        return false;
    }

    GLint maxSparse = 0;
    GLint maxSparse3D = 0;
    GLint maxSparseLayers = 0;
    ctx.capabilities().queryInteger(GL_MAX_SPARSE_TEXTURE_SIZE_ARB, &maxSparse);
    ctx.capabilities().queryInteger(GL_MAX_SPARSE_3D_TEXTURE_SIZE_ARB, &maxSparse3D);
    ctx.capabilities().queryInteger(GL_MAX_SPARSE_ARRAY_TEXTURE_LAYERS_ARB, &maxSparseLayers);
    if (maxSparse <= 0 || maxSparse3D <= 0 || maxSparseLayers <= 0) {
        ctx.pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (width > maxSparse || height > maxSparse) {
        ctx.pushError(GL_INVALID_VALUE);
        return false;
    }
    if (target == GL_TEXTURE_3D &&
        (width > maxSparse3D || height > maxSparse3D || depth > maxSparse3D)) {
        ctx.pushError(GL_INVALID_VALUE);
        return false;
    }
    if ((target == GL_TEXTURE_2D_ARRAY ||
         target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY ||
         target == GL_TEXTURE_CUBE_MAP_ARRAY) &&
        depth > maxSparseLayers) {
        ctx.pushError(GL_INVALID_VALUE);
        return false;
    }

    auto pageAligned = [](GLsizei extent, NSUInteger pageExtent) {
        return pageExtent <= 1u || (extent % static_cast<GLsizei>(pageExtent)) == 0;
    };
    if (!pageAligned(width, page.width) || !pageAligned(height, page.height)) {
        ctx.pushError(GL_INVALID_VALUE);
        return false;
    }
    const bool depthMustAlign =
        target == GL_TEXTURE_3D ||
        target == GL_TEXTURE_2D_ARRAY ||
        target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY ||
        target == GL_TEXTURE_CUBE_MAP_ARRAY;
    if (depthMustAlign && !pageAligned(depth, page.depth)) {
        ctx.pushError(GL_INVALID_VALUE);
        return false;
    }

    GLint fullArrayCubeMipmaps = 0;
    ctx.capabilities().queryInteger(GL_SPARSE_TEXTURE_FULL_ARRAY_CUBE_MIPMAPS_ARB,
                                    &fullArrayCubeMipmaps);
    const bool needsFullArrayCube =
        fullArrayCubeMipmaps == 0 &&
        levels > 1 &&
        (target == GL_TEXTURE_2D_ARRAY ||
         target == GL_TEXTURE_CUBE_MAP ||
         target == GL_TEXTURE_CUBE_MAP_ARRAY);
    if (needsFullArrayCube) {
        const GLsizei sparseLevelCount =
            levelCountForStorage(ctx,
                                 target,
                                 levels,
                                 width,
                                 height,
                                 depth,
                                 internalformat,
                                 samples);
        const std::uint64_t levelScale = sparseLevelCount >= 63
            ? std::numeric_limits<std::uint64_t>::max()
            : (1ull << static_cast<unsigned>(sparseLevelCount - 1));
        const std::uint64_t requiredX =
            static_cast<std::uint64_t>(page.width) * levelScale;
        const std::uint64_t requiredY =
            static_cast<std::uint64_t>(page.height) * levelScale;
        if (requiredX == 0 || requiredY == 0 ||
            static_cast<std::uint64_t>(width) % requiredX != 0 ||
            static_cast<std::uint64_t>(height) % requiredY != 0) {
            ctx.pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    return true;
}

GLsizei levelCountForStorage(ExtensionContext& ctx,
                             GLenum target,
                             GLsizei levels,
                             GLsizei width,
                             GLsizei height,
                             GLsizei depth,
                             GLenum internalformat,
                             GLsizei samples) {
    const MTLSize page = sparsePageSizeForFormat(ctx, target, internalformat, samples);
    const GLsizei pageX = static_cast<GLsizei>(std::max<NSUInteger>(page.width, 1u));
    const GLsizei pageY = static_cast<GLsizei>(std::max<NSUInteger>(page.height, 1u));
    const GLsizei pageZ = static_cast<GLsizei>(std::max<NSUInteger>(page.depth, 1u));
    GLsizei count = 0;
    for (GLsizei level = 0; level < levels; ++level) {
        const GLsizei levelWidth = std::max<GLsizei>(1, width >> level);
        const GLsizei levelHeight = std::max<GLsizei>(1, height >> level);
        const GLsizei levelDepth = target == GL_TEXTURE_3D
            ? std::max<GLsizei>(1, depth >> level)
            : storedDepthForTarget(target, depth);
        if (levelWidth < pageX || levelHeight < pageY || levelDepth < pageZ) {
            break;
        }
        ++count;
    }
    return std::max<GLsizei>(count, 1);
}

bool allocateStorage(ExtensionContext& ctx, GLTextureObject& textureObject) {
    id<MTLDevice> device = metalDevice(ctx);
    if (device == nil) {
        return false;
    }
    const MTLPixelFormat format =
        metalPixelFormatForInternalFormat(ctx, textureObject.desc.internalFormat);
    if (format == MTLPixelFormatInvalid) {
        return false;
    }
    const GLsizei sparseSamples =
        isMultisampleStorageImageTarget(textureObject.target)
            ? std::max<GLsizei>(textureObject.desc.samples, 2)
            : 1;
    const MTLSize page =
        sparsePageSizeForFormat(ctx,
                                textureObject.target,
                                textureObject.desc.internalFormat,
                                sparseSamples);
    if (page.width == 0 || page.height == 0) {
        return false;
    }

    MTLTextureDescriptor* textureDesc = [[MTLTextureDescriptor alloc] init];
    textureDesc.textureType = metalTextureTypeForTarget(textureObject.target);
    const bool isMSTarget = isMultisampleStorageImageTarget(textureObject.target);
    const bool srgbMSNeedsLinearStorage =
        isMSTarget &&
        (textureObject.desc.internalFormat == GL_SRGB8 ||
         textureObject.desc.internalFormat == GL_SRGB8_ALPHA8);
    textureDesc.pixelFormat = srgbMSNeedsLinearStorage ? MTLPixelFormatRGBA8Unorm : format;
    textureDesc.width = static_cast<NSUInteger>(textureObject.desc.width);
    textureDesc.height = static_cast<NSUInteger>(textureObject.desc.height);
    textureDesc.depth = static_cast<NSUInteger>(
        textureObject.target == GL_TEXTURE_3D ? textureObject.desc.depth : 1);
    if (textureObject.target == GL_TEXTURE_2D_ARRAY) {
        textureDesc.arrayLength = static_cast<NSUInteger>(textureObject.desc.depth);
    } else if (textureObject.target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY) {
        textureDesc.arrayLength =
            static_cast<NSUInteger>(std::max<GLsizei>(textureObject.desc.depth, 1));
    } else if (textureObject.target == GL_TEXTURE_CUBE_MAP_ARRAY) {
        textureDesc.arrayLength =
            static_cast<NSUInteger>(std::max<GLsizei>(textureObject.desc.depth, 6) / 6);
    }
    textureDesc.mipmapLevelCount = isMSTarget ? 1u : static_cast<NSUInteger>(
        std::max<GLsizei>(textureObject.desc.levels, 1));
    textureDesc.sampleCount = isMSTarget ? static_cast<NSUInteger>(sparseSamples) : 1u;
    if (isMSTarget && textureObject.desc.samples < static_cast<GLsizei>(sparseSamples)) {
        textureObject.desc.samples = static_cast<GLsizei>(sparseSamples);
    }
    textureDesc.usage = isMSTarget
        ? (MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget)
        : MTLTextureUsageShaderRead;
    if (srgbMSNeedsLinearStorage) {
        textureDesc.usage |= MTLTextureUsagePixelFormatView;
    }
    textureDesc.storageMode = MTLStorageModePrivate;
    textureDesc.allowGPUOptimizedContents = NO;

    const NSUInteger pageBytes =
        std::max<NSUInteger>([device sparseTileSizeInBytes], 16384u);
    const NSUInteger estimatedPages = physicalPageEstimate(textureObject, page);
    MTLHeapDescriptor* heapDesc = [[MTLHeapDescriptor alloc] init];
    heapDesc.type = MTLHeapTypeSparse;
    heapDesc.storageMode = MTLStorageModePrivate;
    heapDesc.size = std::max<NSUInteger>(estimatedPages * pageBytes, pageBytes);
    if (@available(macOS 13.0, *)) {
        heapDesc.sparsePageSize = sparseHeapPageSizeForDevice(device);
    }

    id<MTLHeap> heap = [device newHeapWithDescriptor:heapDesc];
    if (heap == nil) {
        return false;
    }
    id<MTLTexture> texture = [heap newTextureWithDescriptor:textureDesc];
    if (texture == nil || ![texture isSparse]) {
        releaseRetainedMetalObject(transferRetainedMetalObject(heap));
        if (texture != nil) {
            releaseRetainedMetalObject(transferRetainedMetalObject(texture));
        }
        return false;
    }

    releaseRetainedMetalObject(textureObject.metalTexture);
    textureObject.metalTexture = nullptr;
    releaseRetainedMetalObject(textureObject.metalSwizzledView);
    textureObject.metalSwizzledView = nullptr;
    textureObject.swizzleDirty = true;
    releaseRetainedMetalObject(textureObject.metalSamplingProxy);
    textureObject.metalSamplingProxy = nullptr;
    replaceSparseHeap(ctx, textureObject, transferRetainedMetalObject(heap));
    textureObject.metalTexture = transferRetainedMetalObject(texture);
    if (texture.firstMipmapInTail > 0) {
        setSparseLevels(ctx,
                        textureObject,
                        std::min<GLsizei>(sparseLevels(ctx, &textureObject),
                                          static_cast<GLsizei>(texture.firstMipmapInTail)));
    }
    textureObject.instantiated = true;
    return true;
}

void* sparseHeap(ExtensionContext& ctx, const GLTextureObject& texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, &texture);
    return state != nullptr ? state->sparseHeap : nullptr;
}

void replaceSparseHeap(ExtensionContext& ctx, GLTextureObject& texture, void* retainedHeap) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState& state = stateForLocked(ctx, texture);
    releaseRetainedMetalObject(state.sparseHeap);
    state.sparseHeap = retainedHeap;
}

std::vector<CommittedRegion>& committedRegions(ExtensionContext& ctx, GLTextureObject& texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    return stateForLocked(ctx, texture).committedRegions;
}

const std::vector<CommittedRegion>& committedRegions(ExtensionContext& ctx,
                                                     const GLTextureObject& texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, &texture);
    static const std::vector<CommittedRegion> empty;
    return state != nullptr ? state->committedRegions : empty;
}

void clearCommittedRegions(ExtensionContext& ctx, GLTextureObject& texture) {
    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, &texture);
    if (state != nullptr) {
        state->committedRegions.clear();
    }
}

bool uploadCommittedRegions(ExtensionContext& ctx,
                            GLTextureObject& textureObject,
                            GLuint textureName,
                            bool& handled) {
    handled = false;
    if (textureSparse(ctx, &textureObject) != GL_TRUE || !textureObject.desc.immutable) {
        return true;
    }
    handled = true;
    id<MTLTexture> sparseTexture = (__bridge id<MTLTexture>)textureObject.metalTexture;
    if (sparseTexture == nil) {
        return true;
    }
    if (isMultisampleStorageImageTarget(textureObject.target)) {
        textureObject.instantiated = true;
        (void)textureName;
        return true;
    }
    const auto& regions = committedRegions(ctx, textureObject);
    if (regions.empty()) {
        textureObject.instantiated = true;
        return true;
    }

    id<MTLCommandQueue> commandQueue = metalCommandQueue(ctx);
    if (commandQueue == nil) {
        return false;
    }
    MetalCommandSubmission* submission = metalCommandSubmission(ctx);
    auto blitLease = submission != nullptr
        ? submission->makeCommandBuffer(AppGLCommandReason::SparseResidency)
        : MetalCommandBufferLease{};
    id<MTLCommandBuffer> blitCmdBuf = blitLease.get();
    if (blitCmdBuf == nil) {
        return false;
    }
    id<MTLBlitCommandEncoder> blitEnc = [blitCmdBuf blitCommandEncoder];
    if (blitEnc == nil) {
        return false;
    }

    const bool useNativePath = sparseTexture.pixelFormat != MTLPixelFormatRGBA8Unorm;
    bool ok = true;
    auto uploadCommitted2DSlice = [&](const GLTextureImageLevel& image,
                                      const std::uint8_t* source,
                                      std::size_t bpp,
                                      const CommittedRegion& committed,
                                      GLsizei sourceZ,
                                      NSUInteger destinationSlice,
                                      NSUInteger destinationZ) -> bool {
        const GLsizei imageW = static_cast<GLsizei>(safeDimension(image.desc.width));
        const GLsizei imageH = static_cast<GLsizei>(safeDimension(image.desc.height));
        if (source == nullptr || bpp == 0 || imageW <= 0 || imageH <= 0) {
            return true;
        }
        if (committed.xoffset >= imageW || committed.yoffset >= imageH) {
            return true;
        }
        const GLsizei copyW = std::min<GLsizei>(committed.width, imageW - committed.xoffset);
        const GLsizei copyH = std::min<GLsizei>(committed.height, imageH - committed.yoffset);
        if (copyW <= 0 || copyH <= 0) {
            return true;
        }
        const std::size_t tightRowBytes = static_cast<std::size_t>(copyW) * bpp;
        std::vector<std::uint8_t> tight(tightRowBytes * static_cast<std::size_t>(copyH), 0);
        for (GLsizei row = 0; row < copyH; ++row) {
            const std::size_t srcOffset =
                ((static_cast<std::size_t>(sourceZ) * static_cast<std::size_t>(imageH)
                  + static_cast<std::size_t>(committed.yoffset + row))
                 * static_cast<std::size_t>(imageW)
                 + static_cast<std::size_t>(committed.xoffset))
                * bpp;
            std::memcpy(tight.data() + static_cast<std::size_t>(row) * tightRowBytes,
                        source + srcOffset,
                        tightRowBytes);
        }
        const MTLRegion destinationRegion =
            textureObject.target == GL_TEXTURE_3D
                ? MTLRegionMake3D(static_cast<NSUInteger>(committed.xoffset),
                                  static_cast<NSUInteger>(committed.yoffset),
                                  destinationZ,
                                  static_cast<NSUInteger>(copyW),
                                  static_cast<NSUInteger>(copyH),
                                  1)
                : MTLRegionMake2D(static_cast<NSUInteger>(committed.xoffset),
                                  static_cast<NSUInteger>(committed.yoffset),
                                  static_cast<NSUInteger>(copyW),
                                  static_cast<NSUInteger>(copyH));
        return blitUpload2DRegion(ctx,
                                  sparseTexture,
                                  blitEnc,
                                  tight.data(),
                                  static_cast<NSUInteger>(tightRowBytes),
                                  static_cast<NSUInteger>(tight.size()),
                                  destinationRegion,
                                  static_cast<NSUInteger>(committed.level),
                                  textureObject.target == GL_TEXTURE_3D ? 0 : destinationSlice,
                                  bpp);
    };

    for (const CommittedRegion& committed : regions) {
        const auto levelIt = textureObject.levels.find(committed.level);
        if (levelIt == textureObject.levels.end() || !levelIt->second.defined) {
            continue;
        }
        const GLTextureImageLevel& image = levelIt->second;
        const std::uint8_t* source = nullptr;
        std::size_t bpp = 4;
        if (useNativePath && image.nativeBpp > 0 && !image.nativeData.empty()) {
            source = image.nativeData.data();
            bpp = image.nativeBpp;
        } else if (useNativePath) {
            continue;
        } else if (!image.rgba8.empty()) {
            source = image.rgba8.data();
            bpp = 4;
        } else {
            continue;
        }

        const GLsizei imageDepth = static_cast<GLsizei>(safeDimension(image.desc.depth));
        if (textureObject.target == GL_TEXTURE_3D) {
            const GLsizei endZ = std::min<GLsizei>(committed.zoffset + committed.depth, imageDepth);
            for (GLsizei z = committed.zoffset; z < endZ && ok; ++z) {
                ok = uploadCommitted2DSlice(image, source, bpp, committed,
                                            z, 0u, static_cast<NSUInteger>(z));
            }
        } else if (targetUsesSlices(textureObject.target)) {
            const GLsizei endSlice =
                std::min<GLsizei>(committed.zoffset + committed.depth, imageDepth);
            for (GLsizei slice = committed.zoffset; slice < endSlice && ok; ++slice) {
                ok = uploadCommitted2DSlice(image,
                                            source,
                                            bpp,
                                            committed,
                                            slice,
                                            static_cast<NSUInteger>(slice),
                                            0u);
            }
        } else if (ok) {
            ok = uploadCommitted2DSlice(image, source, bpp, committed, 0, 0u, 0u);
        }
        if (!ok) {
            break;
        }
    }
    [blitEnc endEncoding];
    const bool completed = blitLease.commitAndWait(AppGLCommandReason::SparseResidency);
    textureObject.instantiated = true;
    (void)textureName;
    return ok && completed;
}

bool pageCommitment(ExtensionContext& ctx,
                    GLTextureObject& textureObject,
                    GLuint textureName,
                    GLint level,
                    GLint xoffset,
                    GLint yoffset,
                    GLint zoffset,
                    GLsizei width,
                    GLsizei height,
                    GLsizei depth,
                    GLboolean commit) {
    if (level < 0 || xoffset < 0 || yoffset < 0 || zoffset < 0 ||
        width < 0 || height < 0 || depth < 0) {
        ctx.pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!textureObject.desc.immutable || textureSparse(ctx, &textureObject) != GL_TRUE) {
        ctx.pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (textureObject.metalTexture == nullptr) {
        ctx.pushError(GL_INVALID_OPERATION);
        return false;
    }
    id<MTLTexture> texture = (__bridge id<MTLTexture>)textureObject.metalTexture;
    if (texture == nil || ![texture isSparse]) {
        ctx.pushError(GL_INVALID_OPERATION);
        return false;
    }
    auto levelIt = textureObject.levels.find(level);
    if (levelIt == textureObject.levels.end() || !levelIt->second.defined) {
        ctx.pushError(GL_INVALID_OPERATION);
        return false;
    }
    const GLTextureImageLevel& image = levelIt->second;
    const GLsizei levelWidth = static_cast<GLsizei>(safeDimension(image.desc.width));
    const GLsizei levelHeight = static_cast<GLsizei>(safeDimension(image.desc.height));
    const GLsizei levelDepth = static_cast<GLsizei>(safeDimension(image.desc.depth));
    if (xoffset > levelWidth || width > levelWidth - xoffset ||
        yoffset > levelHeight || height > levelHeight - yoffset ||
        zoffset > levelDepth || depth > levelDepth - zoffset) {
        ctx.pushError(GL_INVALID_OPERATION);
        return false;
    }

    const MTLSize page =
        sparsePageSizeForFormat(ctx,
                                textureObject.target,
                                textureObject.desc.internalFormat,
                                textureObject.desc.samples);
    if (page.width == 0 || page.height == 0) {
        ctx.pushError(GL_INVALID_OPERATION);
        return false;
    }
    auto offsetAligned = [](GLint offset, NSUInteger pageExtent) {
        return pageExtent <= 1u || (offset % static_cast<GLint>(pageExtent)) == 0;
    };
    if (!offsetAligned(xoffset, page.width) ||
        !offsetAligned(yoffset, page.height) ||
        !offsetAligned(zoffset, page.depth)) {
        ctx.pushError(GL_INVALID_VALUE);
        return false;
    }
    auto sizeAlignedOrEdge = [](GLint offset,
                                GLsizei size,
                                GLsizei extent,
                                NSUInteger pageExtent) {
        if (size == 0 || pageExtent <= 1u) {
            return true;
        }
        if ((size % static_cast<GLsizei>(pageExtent)) == 0) {
            return true;
        }
        return offset + size == extent;
    };
    if (!sizeAlignedOrEdge(xoffset, width, levelWidth, page.width) ||
        !sizeAlignedOrEdge(yoffset, height, levelHeight, page.height) ||
        !sizeAlignedOrEdge(zoffset, depth, levelDepth, page.depth)) {
        ctx.pushError(GL_INVALID_OPERATION);
        return false;
    }

    CommittedRegion region;
    region.level = level;
    region.xoffset = xoffset;
    region.yoffset = yoffset;
    region.zoffset = zoffset;
    region.width = width;
    region.height = height;
    region.depth = depth;
    if (!updateTextureMapping(ctx, textureObject, region, commit == GL_TRUE)) {
        ctx.pushError(GL_INVALID_OPERATION);
        return false;
    }

    auto& regions = committedRegions(ctx, textureObject);
    if (commit == GL_TRUE) {
        const bool alreadyTracked =
            std::any_of(regions.begin(),
                        regions.end(),
                        [&](const CommittedRegion& existing) {
                            return existing.level == region.level &&
                                   existing.xoffset == region.xoffset &&
                                   existing.yoffset == region.yoffset &&
                                   existing.zoffset == region.zoffset &&
                                   existing.width == region.width &&
                                   existing.height == region.height &&
                                   existing.depth == region.depth;
                        });
        if (!alreadyTracked) {
            regions.push_back(region);
        }
    } else {
        regions.erase(
            std::remove_if(regions.begin(),
                           regions.end(),
                           [&](const CommittedRegion& existing) {
                               return regionsOverlap(existing, region);
                           }),
            regions.end());
    }

    if (commit == GL_TRUE && !ctx.replaceMetalTexture(textureObject, textureName)) {
        ctx.pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

void resetStorage(ExtensionContext& ctx, GLTextureObject& texture) {
    resetMultisampleStorageImageSidecar(ctx, texture);
    resetSparseStorageImageSidecar(ctx, texture);

    std::lock_guard<std::mutex> lock(stateMutex());
    TextureState* state = findStateLocked(ctx, &texture);
    if (state != nullptr) {
        releaseTextureStorage(*state);
    }
}

void destroyTexture(ExtensionContext& ctx, GLTextureObject& texture) {
    destroyMultisampleStorageImageSidecar(ctx, texture);
    destroySparseStorageImageSidecar(ctx, texture);

    std::lock_guard<std::mutex> lock(stateMutex());
    auto contextIt = contextStates().find(&ctx.context());
    if (contextIt == contextStates().end()) {
        return;
    }
    auto textureIt = contextIt->second.textures.find(&texture);
    if (textureIt == contextIt->second.textures.end()) {
        return;
    }
    releaseTextureStorage(textureIt->second);
    contextIt->second.textures.erase(textureIt);
}

void destroyContext(ExtensionContext& ctx) {
    destroyMultisampleStorageImageSidecars(ctx);
    destroySparseStorageImageSidecars(ctx);

    std::lock_guard<std::mutex> lock(stateMutex());
    auto contextIt = contextStates().find(&ctx.context());
    if (contextIt == contextStates().end()) {
        return;
    }
    for (auto& [texture, state] : contextIt->second.textures) {
        (void)texture;
        releaseTextureStorage(state);
    }
    contextStates().erase(contextIt);
}

SparseTextureMemoryInventory sparseTextureMemoryInventory(const GLContext& context) {
    std::lock_guard<std::mutex> lock(stateMutex());
    SparseTextureMemoryInventory inventory;
    auto contextIt = contextStates().find(&context);
    if (contextIt == contextStates().end()) {
        return inventory;
    }
    for (const auto& entry : contextIt->second.textures) {
        const TextureState& state = entry.second;
        ++inventory.textureStates;
        inventory.committedRegions += state.committedRegions.size();
        if (state.sparseHeap != nullptr) {
            ++inventory.sparseHeaps;
            id<MTLHeap> heap = (__bridge id<MTLHeap>)state.sparseHeap;
            if (heap != nil) {
                inventory.sparseHeapBytes += static_cast<std::uint64_t>(heap.size);
            }
        }
    }
    return inventory;
}

}  // namespace appgl::extensions::sparse_texture
