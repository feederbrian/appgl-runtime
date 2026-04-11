#include "MetalFrameGraph.h"

#include "../objects/GLObjectStore.h"
#include "../state/GLStateTracker.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

namespace appgl {

struct MetalFrameGraph::Impl {
    Impl(void* rawLayer, void* rawDevice, void* rawCommandQueue)
        : layer((__bridge CAMetalLayer*)rawLayer),
          device((__bridge id<MTLDevice>)rawDevice),
          commandQueue((__bridge id<MTLCommandQueue>)rawCommandQueue) {
        if (layer != nil && device != nil) {
            layer.device = device;
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.framebufferOnly = NO;
        }
        ensureDrawableResources();
    }

    void resize(GLsizei width, GLsizei height) {
        drawableWidth = width > 0 ? width : 1;
        drawableHeight = height > 0 ? height : 1;
        headlessReadbackRGBA.clear();
        hasHeadlessReadback = false;
        if (layer != nil) {
            layer.drawableSize = CGSizeMake(drawableWidth, drawableHeight);
        }
        invalidateTransientState();
        ensureDrawableResources();
    }

    void enableOffscreen(GLsizei width, GLsizei height) {
        usesOffscreenTarget = true;
        resize(width, height);
    }

    void encodeClear(
        GLbitfield mask,
        GLfloat clearRed,
        GLfloat clearGreen,
        GLfloat clearBlue,
        GLfloat clearAlpha,
        GLdouble clearDepth,
        GLint clearStencil
    ) {
        if (device == nil || commandQueue == nil) {
            storeHeadlessClear(mask, clearRed, clearGreen, clearBlue, clearAlpha);
            return;
        }

        ensureDrawableResources();
        if (usesOffscreenTarget) {
            currentDrawable = nil;
        } else {
            currentDrawable = [layer nextDrawable];
            if (currentDrawable == nil) {
                return;
            }
        }

        currentCommandBuffer = [commandQueue commandBuffer];
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].loadAction = (mask & GL_COLOR_BUFFER_BIT) ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(clearRed, clearGreen, clearBlue, clearAlpha);
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;

        if (depthStencilTexture != nil) {
            pass.depthAttachment.texture = depthStencilTexture;
            pass.depthAttachment.loadAction = (mask & GL_DEPTH_BUFFER_BIT) ? MTLLoadActionClear : MTLLoadActionLoad;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.depthAttachment.clearDepth = clearDepth;

            pass.stencilAttachment.texture = depthStencilTexture;
            pass.stencilAttachment.loadAction = (mask & GL_STENCIL_BUFFER_BIT) ? MTLLoadActionClear : MTLLoadActionLoad;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.clearStencil = clearStencil;
        }

        id<MTLRenderCommandEncoder> encoder = [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
        [encoder endEncoding];
        enqueueOffscreenClearUpload(mask, clearRed, clearGreen, clearBlue, clearAlpha);
        pendingPresent = true;
    }

    void beginRenderPass(GLStateTracker& state, GLObjectStore& objects) {
        (void)state;
        (void)objects;
        if (device == nil || commandQueue == nil) {
            return;
        }
        ensureDrawableResources();
        if (currentCommandBuffer == nil) {
            currentCommandBuffer = [commandQueue commandBuffer];
        }
        if (!usesOffscreenTarget) {
            currentDrawable = [layer nextDrawable];
            if (currentDrawable == nil) {
                return;
            }
        }

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        pass.depthAttachment.texture = depthStencilTexture;
        pass.depthAttachment.loadAction = MTLLoadActionLoad;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.stencilAttachment.texture = depthStencilTexture;
        pass.stencilAttachment.loadAction = MTLLoadActionLoad;
        pass.stencilAttachment.storeAction = MTLStoreActionStore;
        currentRenderEncoder = [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
    }

    void* renderEncoder() const {
        return (__bridge void*)currentRenderEncoder;
    }

    void endRenderPass() {
        if (currentRenderEncoder != nil) {
            [currentRenderEncoder endEncoding];
            currentRenderEncoder = nil;
            pendingPresent = true;
        }
    }

    void endFrame(GLObjectStore& objects) {
        endRenderPass();
        objects.drainDeferredDeletes();
        if (currentCommandBuffer != nil) {
            if (!usesOffscreenTarget && currentDrawable != nil) {
                [currentCommandBuffer presentDrawable:currentDrawable];
            }
            [currentCommandBuffer commit];
        }
        invalidateTransientState();
    }

    void present() {
        if (!pendingPresent || currentCommandBuffer == nil) {
            return;
        }
        if (!usesOffscreenTarget && currentDrawable != nil) {
            [currentCommandBuffer presentDrawable:currentDrawable];
        }
        [currentCommandBuffer commit];
        if (usesOffscreenTarget) {
            [currentCommandBuffer waitUntilCompleted];
        }
        invalidateTransientState();
    }

    bool copyPixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels) {
        if (outPixels == nullptr || width < 0 || height < 0) {
            return false;
        }
        if (width == 0 || height == 0) {
            return true;
        }
        if (device == nil || commandQueue == nil) {
            return copyHeadlessPixels(x, y, width, height, outPixels);
        }
        ensureDrawableResources();
        id<MTLTexture> sourceTexture = readbackSourceTexture != nil
            ? readbackSourceTexture
            : (usesOffscreenTarget ? offscreenColorTexture : nil);
        if (sourceTexture == nil) {
            return false;
        }
        const bool sourceIsBGRA = sourceTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;

        const NSUInteger sourceWidth = sourceTexture.width;
        const NSUInteger sourceHeight = sourceTexture.height;
        const NSUInteger packedRowBytes = sourceWidth * 4u;
        NSUInteger readbackRowBytes = packedRowBytes;
        const std::uint8_t* sourceBytes = nullptr;
        std::vector<std::uint8_t> directReadback;
        id<MTLBuffer> readbackBuffer = nil;

        const auto waitForQueue = [&]() -> bool {
            id<MTLCommandBuffer> fence = [commandQueue commandBuffer];
            if (fence == nil) {
                return false;
            }
            [fence commit];
            [fence waitUntilCompleted];
            return fence.status != MTLCommandBufferStatusError;
        };

        if (sourceTexture.storageMode == MTLStorageModeShared) {
            if (currentCommandBuffer != nil) {
                [currentCommandBuffer commit];
                [currentCommandBuffer waitUntilCompleted];
                if (currentCommandBuffer.status == MTLCommandBufferStatusError) {
                    invalidateTransientState();
                    return false;
                }
                invalidateTransientState();
            } else if (!waitForQueue()) {
                return false;
            }

            directReadback.assign(static_cast<std::size_t>(packedRowBytes * sourceHeight), 0);
            [sourceTexture getBytes:directReadback.data()
                        bytesPerRow:packedRowBytes
                         fromRegion:MTLRegionMake2D(0, 0, sourceWidth, sourceHeight)
                        mipmapLevel:0];
            sourceBytes = directReadback.data();
        } else {
            readbackRowBytes = alignBytesPerRow(packedRowBytes);
            readbackBuffer = [device newBufferWithLength:readbackRowBytes * sourceHeight
                                                 options:MTLResourceStorageModeShared];
            if (readbackBuffer == nil) {
                return false;
            }

            id<MTLCommandBuffer> commandBuffer = currentCommandBuffer != nil ? currentCommandBuffer : [commandQueue commandBuffer];
            if (commandBuffer == nil) {
                return false;
            }
            id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
            [blit copyFromTexture:sourceTexture
                      sourceSlice:0
                      sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(sourceWidth, sourceHeight, 1)
                         toBuffer:readbackBuffer
                destinationOffset:0
           destinationBytesPerRow:readbackRowBytes
         destinationBytesPerImage:readbackRowBytes * sourceHeight];
            [blit endEncoding];
            const bool consumedCurrentCommandBuffer = commandBuffer == currentCommandBuffer;
            [commandBuffer commit];
            [commandBuffer waitUntilCompleted];
            if (commandBuffer.status == MTLCommandBufferStatusError) {
                if (consumedCurrentCommandBuffer) {
                    invalidateTransientState();
                }
                return false;
            }
            if (consumedCurrentCommandBuffer) {
                invalidateTransientState();
            }
            sourceBytes = static_cast<const std::uint8_t*>([readbackBuffer contents]);
        }

        auto* bytes = static_cast<std::uint8_t*>(outPixels);
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint srcX = x + col;
                const GLint srcY = y + row;
                const std::size_t dstOffset = static_cast<std::size_t>(row * width + col) * 4;
                if (srcX < 0 || srcY < 0 || srcX >= static_cast<GLint>(sourceWidth) || srcY >= static_cast<GLint>(sourceHeight)) {
                    std::memset(bytes + dstOffset, 0, 4);
                    continue;
                }
                const std::size_t srcOffset = static_cast<std::size_t>(srcY) * static_cast<std::size_t>(readbackRowBytes)
                    + static_cast<std::size_t>(srcX) * 4u;
                if (sourceIsBGRA) {
                    bytes[dstOffset + 0] = sourceBytes[srcOffset + 2];
                    bytes[dstOffset + 1] = sourceBytes[srcOffset + 1];
                    bytes[dstOffset + 2] = sourceBytes[srcOffset + 0];
                    bytes[dstOffset + 3] = sourceBytes[srcOffset + 3];
                } else {
                    std::memcpy(bytes + dstOffset, sourceBytes + srcOffset, 4);
                }
            }
        }
        return true;
    }

    bool isReady() const {
        return device != nil && commandQueue != nil && depthStencilTexture != nil && (layer != nil || offscreenColorTexture != nil);
    }

private:
    void ensureDrawableResources() {
        if (device == nil) {
            return;
        }

        if (drawableWidth <= 0 || drawableHeight <= 0) {
            if (layer != nil) {
                const CGSize bounds = layer.bounds.size;
                drawableWidth = bounds.width > 0.0 ? static_cast<GLsizei>(bounds.width) : 1;
                drawableHeight = bounds.height > 0.0 ? static_cast<GLsizei>(bounds.height) : 1;
            } else {
                drawableWidth = 1;
                drawableHeight = 1;
            }
        }

        if (layer != nil) {
            layer.drawableSize = CGSizeMake(drawableWidth, drawableHeight);
        }

        const bool needsDepthRebuild =
            depthStencilTexture == nil
            || depthStencilTexture.width != static_cast<NSUInteger>(drawableWidth)
            || depthStencilTexture.height != static_cast<NSUInteger>(drawableHeight);

        if (needsDepthRebuild) {
            MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                                                                   width:static_cast<NSUInteger>(drawableWidth)
                                                                                                  height:static_cast<NSUInteger>(drawableHeight)
                                                                                               mipmapped:NO];
            descriptor.storageMode = MTLStorageModePrivate;
            descriptor.usage = MTLTextureUsageRenderTarget;
            depthStencilTexture = [device newTextureWithDescriptor:descriptor];
        }

        const bool needsOffscreenRebuild =
            usesOffscreenTarget
            && (offscreenColorTexture == nil
                || offscreenColorTexture.width != static_cast<NSUInteger>(drawableWidth)
                || offscreenColorTexture.height != static_cast<NSUInteger>(drawableHeight));
        if (needsOffscreenRebuild) {
            MTLTextureDescriptor* colorDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                       width:static_cast<NSUInteger>(drawableWidth)
                                                                                                      height:static_cast<NSUInteger>(drawableHeight)
                                                                                                   mipmapped:NO];
            colorDescriptor.storageMode = MTLStorageModePrivate;
            colorDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            offscreenColorTexture = [device newTextureWithDescriptor:colorDescriptor];
        }
    }

    NSUInteger alignBytesPerRow(NSUInteger byteCount) const {
        constexpr NSUInteger kMetalBufferAlignment = 256;
        return ((byteCount + kMetalBufferAlignment - 1u) / kMetalBufferAlignment) * kMetalBufferAlignment;
    }

    std::uint8_t normalizedByte(GLfloat value) const {
        const GLfloat clamped = std::clamp(value, 0.0f, 1.0f);
        return static_cast<std::uint8_t>(clamped * 255.0f + 0.5f);
    }

    void storeHeadlessClear(GLbitfield mask, GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
        if ((mask & GL_COLOR_BUFFER_BIT) == 0) {
            return;
        }

        const std::size_t width = static_cast<std::size_t>(drawableWidth > 0 ? drawableWidth : 1);
        const std::size_t height = static_cast<std::size_t>(drawableHeight > 0 ? drawableHeight : 1);
        headlessReadbackRGBA.assign(width * height * 4u, 0);
        const std::uint8_t rgba[4] = {
            normalizedByte(red),
            normalizedByte(green),
            normalizedByte(blue),
            normalizedByte(alpha),
        };
        for (std::size_t offset = 0; offset < headlessReadbackRGBA.size(); offset += 4u) {
            std::memcpy(headlessReadbackRGBA.data() + offset, rgba, 4);
        }
        hasHeadlessReadback = true;
    }

    bool copyHeadlessPixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels) const {
        if (!hasHeadlessReadback) {
            return false;
        }
        const auto sourceWidth = drawableWidth > 0 ? drawableWidth : 1;
        const auto sourceHeight = drawableHeight > 0 ? drawableHeight : 1;
        auto* bytes = static_cast<std::uint8_t*>(outPixels);
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint srcX = x + col;
                const GLint srcY = y + row;
                const std::size_t dstOffset = static_cast<std::size_t>(row * width + col) * 4u;
                if (srcX < 0 || srcY < 0 || srcX >= sourceWidth || srcY >= sourceHeight) {
                    std::memset(bytes + dstOffset, 0, 4);
                    continue;
                }
                const std::size_t srcOffset = (static_cast<std::size_t>(srcY) * static_cast<std::size_t>(sourceWidth)
                    + static_cast<std::size_t>(srcX)) * 4u;
                std::memcpy(bytes + dstOffset, headlessReadbackRGBA.data() + srcOffset, 4);
            }
        }
        return true;
    }

    void enqueueOffscreenClearUpload(GLbitfield mask, GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
        if (!usesOffscreenTarget || (mask & GL_COLOR_BUFFER_BIT) == 0 || offscreenColorTexture == nil || currentCommandBuffer == nil) {
            return;
        }

        const NSUInteger width = offscreenColorTexture.width;
        const NSUInteger height = offscreenColorTexture.height;
        const NSUInteger packedRowBytes = width * 4u;
        const NSUInteger rowBytes = alignBytesPerRow(packedRowBytes);
        id<MTLBuffer> staging = [device newBufferWithLength:rowBytes * height options:MTLResourceStorageModeShared];
        if (staging == nil) {
            return;
        }

        const std::uint8_t rgba[4] = {
            normalizedByte(red),
            normalizedByte(green),
            normalizedByte(blue),
            normalizedByte(alpha),
        };
        auto* bytes = static_cast<std::uint8_t*>([staging contents]);
        for (NSUInteger row = 0; row < height; ++row) {
            std::uint8_t* rowStart = bytes + row * rowBytes;
            for (NSUInteger col = 0; col < width; ++col) {
                std::memcpy(rowStart + col * 4u, rgba, 4);
            }
        }

        id<MTLBlitCommandEncoder> blit = [currentCommandBuffer blitCommandEncoder];
        [blit copyFromBuffer:staging
                sourceOffset:0
           sourceBytesPerRow:rowBytes
         sourceBytesPerImage:rowBytes * height
                  sourceSize:MTLSizeMake(width, height, 1)
                   toTexture:offscreenColorTexture
            destinationSlice:0
            destinationLevel:0
           destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        readbackSourceTexture = offscreenColorTexture;
        readbackSourceIsBGRA = false;
    }

    void invalidateTransientState() {
        currentRenderEncoder = nil;
        currentCommandBuffer = nil;
        currentDrawable = nil;
        pendingPresent = false;
    }

    CAMetalLayer* layer = nil;
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> commandQueue = nil;
    id<MTLTexture> depthStencilTexture = nil;
    id<MTLTexture> offscreenColorTexture = nil;
    id<MTLTexture> readbackSourceTexture = nil;
    id<MTLCommandBuffer> currentCommandBuffer = nil;
    id<MTLRenderCommandEncoder> currentRenderEncoder = nil;
    id<CAMetalDrawable> currentDrawable = nil;
    std::vector<std::uint8_t> headlessReadbackRGBA;
    GLsizei drawableWidth = 1;
    GLsizei drawableHeight = 1;
    bool usesOffscreenTarget = false;
    bool pendingPresent = false;
    bool readbackSourceIsBGRA = false;
    bool hasHeadlessReadback = false;
};

MetalFrameGraph::MetalFrameGraph(void* layer, void* device, void* commandQueue)
    : impl_(std::make_unique<Impl>(layer, device, commandQueue)) {
}

MetalFrameGraph::~MetalFrameGraph() = default;

void MetalFrameGraph::resizeDrawable(GLsizei width, GLsizei height) {
    impl_->resize(width, height);
}

void MetalFrameGraph::enableOffscreenDrawable(GLsizei width, GLsizei height) {
    impl_->enableOffscreen(width, height);
}

void MetalFrameGraph::encodeDefaultFramebufferClear(
    GLbitfield mask,
    GLfloat clearRed,
    GLfloat clearGreen,
    GLfloat clearBlue,
    GLfloat clearAlpha,
    GLdouble clearDepth,
    GLint clearStencil
) {
    impl_->encodeClear(mask, clearRed, clearGreen, clearBlue, clearAlpha, clearDepth, clearStencil);
}

void MetalFrameGraph::beginRenderPassForCurrentFramebuffer(GLStateTracker& state, GLObjectStore& objects) {
    impl_->beginRenderPass(state, objects);
}

void* MetalFrameGraph::currentRenderEncoder() const {
    return impl_->renderEncoder();
}

void MetalFrameGraph::endRenderPass() {
    impl_->endRenderPass();
}

void MetalFrameGraph::endFrame(GLObjectStore& objects) {
    impl_->endFrame(objects);
}

void MetalFrameGraph::present() {
    impl_->present();
}

bool MetalFrameGraph::copyRGBA8Pixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels) {
    return impl_->copyPixels(x, y, width, height, outPixels);
}

bool MetalFrameGraph::hasValidAttachments() const {
    return impl_->isReady();
}

}  // namespace appgl
