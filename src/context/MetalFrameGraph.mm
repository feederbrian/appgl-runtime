#include "MetalFrameGraph.h"

#include "../objects/GLObjectStore.h"
#include "../state/GLStateTracker.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
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
        updateReadbackMirror(mask, clearRed, clearGreen, clearBlue, clearAlpha);
        if (device == nil || commandQueue == nil) {
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
        pass.colorAttachments[0].texture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        pass.colorAttachments[0].loadAction = (mask & GL_COLOR_BUFFER_BIT) ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(clearRed, clearGreen, clearBlue, clearAlpha);

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
        pass.colorAttachments[0].texture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
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
        invalidateTransientState();
    }

    bool copyPixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels) {
        if (outPixels == nullptr || width < 0 || height < 0) {
            return false;
        }
        ensureReadbackMirror();
        auto* bytes = static_cast<std::uint8_t*>(outPixels);
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const GLint srcX = x + col;
                const GLint srcY = y + row;
                const std::size_t dstOffset = static_cast<std::size_t>(row * width + col) * 4;
                if (srcX < 0 || srcY < 0 || srcX >= drawableWidth || srcY >= drawableHeight) {
                    std::memset(bytes + dstOffset, 0, 4);
                    continue;
                }
                const std::size_t srcOffset = static_cast<std::size_t>(srcY * drawableWidth + srcX) * 4;
                std::memcpy(bytes + dstOffset, readbackRGBA.data() + srcOffset, 4);
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
        ensureReadbackMirror();
    }

    void ensureReadbackMirror() {
        const std::size_t required = static_cast<std::size_t>(std::max(drawableWidth, 1)) * static_cast<std::size_t>(std::max(drawableHeight, 1)) * 4;
        if (readbackRGBA.size() != required) {
            readbackRGBA.assign(required, 0);
        }
    }

    void updateReadbackMirror(GLbitfield mask, GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
        ensureReadbackMirror();
        if ((mask & GL_COLOR_BUFFER_BIT) == 0) {
            return;
        }

        const auto toByte = [](GLfloat value) {
            const GLfloat clamped = std::clamp(value, 0.0f, 1.0f);
            return static_cast<std::uint8_t>(clamped * 255.0f + 0.5f);
        };
        const std::uint8_t rgba[4] = {toByte(red), toByte(green), toByte(blue), toByte(alpha)};
        for (std::size_t offset = 0; offset < readbackRGBA.size(); offset += 4) {
            std::memcpy(readbackRGBA.data() + offset, rgba, 4);
        }
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
    id<MTLCommandBuffer> currentCommandBuffer = nil;
    id<MTLRenderCommandEncoder> currentRenderEncoder = nil;
    id<CAMetalDrawable> currentDrawable = nil;
    GLsizei drawableWidth = 1;
    GLsizei drawableHeight = 1;
    std::vector<std::uint8_t> readbackRGBA;
    bool usesOffscreenTarget = false;
    bool pendingPresent = false;
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
