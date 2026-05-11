#include "RasterizationRateMap.h"

#include "../ExtensionContext.h"

#import <Metal/Metal.h>

#include <mutex>
#include <unordered_map>

namespace appgl::extensions::fragment_shading_rate {
namespace {

struct RasterizationRateMapCache {
    id<MTLRasterizationRateMap> map = nil;
    NSUInteger width = 0;
    NSUInteger height = 0;
    GLenum rate = GL_SHADING_RATE_1X1_PIXELS_EXT;
};

std::mutex& cacheMutex() {
    static std::mutex mutex;
    return mutex;
}

std::unordered_map<const GLContext*, RasterizationRateMapCache>& contextCaches() {
    static std::unordered_map<const GLContext*, RasterizationRateMapCache> caches;
    return caches;
}

bool fragmentShadingRateQuality(GLenum rate, float& horizontal, float& vertical) {
    unsigned width = 1;
    unsigned height = 1;
    switch (rate) {
        case GL_SHADING_RATE_1X1_PIXELS_EXT: width = 1; height = 1; break;
        case GL_SHADING_RATE_1X2_PIXELS_EXT: width = 1; height = 2; break;
        case GL_SHADING_RATE_1X4_PIXELS_EXT: width = 1; height = 4; break;
        case GL_SHADING_RATE_2X1_PIXELS_EXT: width = 2; height = 1; break;
        case GL_SHADING_RATE_2X2_PIXELS_EXT: width = 2; height = 2; break;
        case GL_SHADING_RATE_2X4_PIXELS_EXT: width = 2; height = 4; break;
        case GL_SHADING_RATE_4X1_PIXELS_EXT: width = 4; height = 1; break;
        case GL_SHADING_RATE_4X2_PIXELS_EXT: width = 4; height = 2; break;
        case GL_SHADING_RATE_4X4_PIXELS_EXT: width = 4; height = 4; break;
        default:
            return false;
    }
    horizontal = 1.0f / static_cast<float>(width);
    vertical = 1.0f / static_cast<float>(height);
    return true;
}

id<MTLRasterizationRateMap> rasterizationRateMapForFragmentShadingRate(
    ExtensionContext& ctx,
    GLenum rate,
    NSUInteger width,
    NSUInteger height
) {
    float horizontalQuality = 1.0f;
    float verticalQuality = 1.0f;
    if (!fragmentShadingRateQuality(rate, horizontalQuality, verticalQuality)) {
        return nil;
    }
    if (rate == GL_SHADING_RATE_1X1_PIXELS_EXT || width == 0 || height == 0) {
        return nil;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx.metalDevice();
    if (device == nil) {
        return nil;
    }

    if (@available(macOS 10.15.4, *)) {
        if (![device supportsRasterizationRateMapWithLayerCount:1]) {
            return nil;
        }
        std::lock_guard<std::mutex> lock(cacheMutex());
        RasterizationRateMapCache& cache = contextCaches()[&ctx.context()];
        if (cache.map != nil &&
            cache.width == width &&
            cache.height == height &&
            cache.rate == rate) {
            return cache.map;
        }

        const MTLSize sampleCount = MTLSizeMake(2, 2, 0);
        const float horizontalSamples[2] = {horizontalQuality, horizontalQuality};
        const float verticalSamples[2] = {verticalQuality, verticalQuality};
        MTLRasterizationRateLayerDescriptor* layer =
            [[MTLRasterizationRateLayerDescriptor alloc]
                initWithSampleCount:sampleCount
                         horizontal:horizontalSamples
                           vertical:verticalSamples];
        MTLRasterizationRateMapDescriptor* desc =
            [MTLRasterizationRateMapDescriptor
                rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(width, height, 0)
                                                       layer:layer];
        desc.label = @"AppGL GL_EXT_fragment_shading_rate";
        id<MTLRasterizationRateMap> map = [device newRasterizationRateMapWithDescriptor:desc];
        if (map == nil) {
            return nil;
        }
        cache.map = map;
        cache.width = width;
        cache.height = height;
        cache.rate = rate;
        return cache.map;
    }
    return nil;
}

}  // namespace

bool isRasterizationRateMapAvailable(ExtensionContext& ctx) {
    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx.metalDevice();
    if (device == nil) {
        return false;
    }
    if (@available(macOS 10.15.4, *)) {
        return [device supportsRasterizationRateMapWithLayerCount:1];
    }
    return false;
}

void attachRenderPass(ExtensionContext& ctx,
                      void* renderPassDescriptor,
                      GLenum rate,
                      void* colorTexture,
                      std::size_t renderTargetLayerCount) {
    MTLRenderPassDescriptor* pass = (__bridge MTLRenderPassDescriptor*)renderPassDescriptor;
    id<MTLTexture> texture = (__bridge id<MTLTexture>)colorTexture;
    if (pass == nil || texture == nil || renderTargetLayerCount > 1) {
        return;
    }
    if (@available(macOS 10.15.4, *)) {
        id<MTLRasterizationRateMap> map =
            rasterizationRateMapForFragmentShadingRate(ctx, rate, texture.width, texture.height);
        if (map != nil) {
            pass.rasterizationRateMap = map;
        }
    }
}

void clearRasterizationRateMapCache(ExtensionContext& ctx) {
    std::lock_guard<std::mutex> lock(cacheMutex());
    contextCaches().erase(&ctx.context());
}

}  // namespace appgl::extensions::fragment_shading_rate
