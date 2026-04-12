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

    // Phase A Group 7 — minimal draw path.
    //
    // Until the full GLSL→SPIR-V→MSL pipeline ships (Group 6 left ShaderTranslator
    // stubbed because glslang/SPIRV-Cross are not yet linked into the Xcode
    // framework target), we use a single hand-written "solid color" MSL pipeline
    // that consumes one float3 position attribute and a single float4 uniform
    // color. This lets us exercise the Metal draw encoder path, vertex buffer
    // binding, depth-test state, and gauntlet golden round-trip end-to-end on
    // the one triangle test fixture. Future groups replace the fallback library
    // with the translated MSL from the active program.
    bool encodeSolidColorDraw(const MetalDrawInfo& info) {
        if (device == nil || commandQueue == nil) {
            return false;
        }
        if (info.vertexCount <= 0 || info.positions == nullptr || info.positionByteCount == 0) {
            return false;
        }
        if (info.mode != GL_TRIANGLES && info.mode != GL_TRIANGLE_STRIP) {
            return false;
        }
        if (info.positionComponents != 3) {
            return false;
        }

        ensureDrawableResources();
        if (!ensureSolidColorLibrary()) {
            return false;
        }
        if (!ensureSolidColorPipelineState(info)) {
            return false;
        }

        // If a prior clear is sitting unflushed in currentCommandBuffer, commit
        // and wait for it before starting the draw pass. encodeClear followed
        // by enqueueOffscreenClearUpload leaves the offscreen color texture
        // with a render-pass clear and a blit copy pending on the same command
        // buffer; chaining a second render-pass encoder that does
        // LoadActionLoad on that texture within the same command buffer does
        // not reliably observe the blit's writes on Apple-Silicon, and the
        // draw ends up sampling the Private texture's uninitialized magenta
        // sentinel. Splitting the command buffers forces the clear + blit to
        // land before the draw's load.
        if (currentCommandBuffer != nil) {
            [currentCommandBuffer commit];
            [currentCommandBuffer waitUntilCompleted];
            currentCommandBuffer = nil;
        }
        currentCommandBuffer = [commandQueue commandBuffer];
        if (currentCommandBuffer == nil) {
            return false;
        }

        if (!usesOffscreenTarget && currentDrawable == nil) {
            currentDrawable = [layer nextDrawable];
            if (currentDrawable == nil) {
                return false;
            }
        }

        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        if (colorTexture == nil) {
            return false;
        }

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (depthStencilTexture != nil) {
            pass.depthAttachment.texture = depthStencilTexture;
            pass.depthAttachment.loadAction = MTLLoadActionLoad;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.texture = depthStencilTexture;
            pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
        }

        id<MTLRenderCommandEncoder> encoder = [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
        if (encoder == nil) {
            return false;
        }
        [encoder setRenderPipelineState:solidColorPipelineState];

        if (depthStencilTexture != nil) {
            id<MTLDepthStencilState> dsState = depthStencilStateForDraw(info);
            if (dsState != nil) {
                [encoder setDepthStencilState:dsState];
            }
        }

        if (info.cullFaceEnabled) {
            [encoder setCullMode:(info.cullFaceMode == GL_FRONT ? MTLCullModeFront :
                                  info.cullFaceMode == GL_FRONT_AND_BACK ? MTLCullModeBack : MTLCullModeBack)];
        } else {
            [encoder setCullMode:MTLCullModeNone];
        }
        [encoder setFrontFacingWinding:info.frontFace == GL_CW ? MTLWindingClockwise : MTLWindingCounterClockwise];

        // Vertex positions are pushed as inline bytes (fits in Metal's 4KB limit
        // for every fixture we ship in Phase A). Attribute 0 lives in buffer 0.
        if (info.positionByteCount <= 4096) {
            [encoder setVertexBytes:info.positions length:info.positionByteCount atIndex:0];
        } else {
            id<MTLBuffer> vb = [device newBufferWithBytes:info.positions
                                                   length:info.positionByteCount
                                                  options:MTLResourceStorageModeShared];
            if (vb == nil) {
                [encoder endEncoding];
                return false;
            }
            [encoder setVertexBuffer:vb offset:0 atIndex:0];
        }
        // Uniform color lives in fragment buffer 0.
        [encoder setFragmentBytes:info.uniformColor length:sizeof(info.uniformColor) atIndex:0];

        const MTLPrimitiveType primitive = (info.mode == GL_TRIANGLE_STRIP)
            ? MTLPrimitiveTypeTriangleStrip
            : MTLPrimitiveTypeTriangle;

        if (info.indices != nullptr && info.indexCount > 0) {
            MTLIndexType metalIndexType = MTLIndexTypeUInt16;
            std::size_t bytesPerIndex = 2;
            switch (info.indexType) {
                case GL_UNSIGNED_INT:
                    metalIndexType = MTLIndexTypeUInt32;
                    bytesPerIndex = 4;
                    break;
                case GL_UNSIGNED_SHORT:
                    metalIndexType = MTLIndexTypeUInt16;
                    bytesPerIndex = 2;
                    break;
                default:
                    [encoder endEncoding];
                    return false;
            }
            const std::size_t indexBytes = static_cast<std::size_t>(info.indexCount) * bytesPerIndex;
            id<MTLBuffer> ib = [device newBufferWithBytes:info.indices
                                                    length:indexBytes
                                                   options:MTLResourceStorageModeShared];
            if (ib == nil) {
                [encoder endEncoding];
                return false;
            }
            [encoder drawIndexedPrimitives:primitive
                                indexCount:static_cast<NSUInteger>(info.indexCount)
                                 indexType:metalIndexType
                               indexBuffer:ib
                         indexBufferOffset:0];
        } else {
            [encoder drawPrimitives:primitive
                        vertexStart:static_cast<NSUInteger>(info.baseVertex)
                        vertexCount:static_cast<NSUInteger>(info.vertexCount)];
        }

        [encoder endEncoding];
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        pendingPresent = true;
        return true;
    }

    bool ensureSolidColorLibrary() {
        if (solidColorLibrary != nil) {
            return true;
        }
        NSString* source = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct AppGLVertexIn {
    float3 position [[attribute(0)]];
};

struct AppGLVertexOut {
    float4 position [[position]];
};

vertex AppGLVertexOut appgl_solid_vs(AppGLVertexIn in [[stage_in]]) {
    AppGLVertexOut out;
    out.position = float4(in.position, 1.0);
    return out;
}

fragment float4 appgl_solid_fs(constant float4& color [[buffer(0)]]) {
    return color;
}
)MSL";
        NSError* error = nil;
        solidColorLibrary = [device newLibraryWithSource:source options:nil error:&error];
        if (solidColorLibrary == nil) {
            return false;
        }
        solidColorVertexFn = [solidColorLibrary newFunctionWithName:@"appgl_solid_vs"];
        solidColorFragmentFn = [solidColorLibrary newFunctionWithName:@"appgl_solid_fs"];
        return solidColorVertexFn != nil && solidColorFragmentFn != nil;
    }

    bool ensureSolidColorPipelineState(const MetalDrawInfo& info) {
        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : nil;
        const MTLPixelFormat colorFormat = colorTexture != nil
            ? colorTexture.pixelFormat
            : MTLPixelFormatBGRA8Unorm;

        if (solidColorPipelineState != nil
            && solidColorPipelineColorFormat == colorFormat) {
            return true;
        }

        MTLVertexDescriptor* vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
        vertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;
        vertexDescriptor.attributes[0].offset = 0;
        vertexDescriptor.attributes[0].bufferIndex = 0;
        const NSUInteger stride = info.positionStride > 0
            ? info.positionStride
            : sizeof(float) * 3u;
        vertexDescriptor.layouts[0].stride = stride;
        vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        vertexDescriptor.layouts[0].stepRate = 1;

        MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = solidColorVertexFn;
        desc.fragmentFunction = solidColorFragmentFn;
        desc.vertexDescriptor = vertexDescriptor;
        desc.colorAttachments[0].pixelFormat = colorFormat;
        desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        desc.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

        NSError* error = nil;
        solidColorPipelineState = [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (solidColorPipelineState == nil) {
            return false;
        }
        solidColorPipelineColorFormat = colorFormat;
        return true;
    }

    id<MTLDepthStencilState> depthStencilStateForDraw(const MetalDrawInfo& info) {
        MTLDepthStencilDescriptor* desc = [[MTLDepthStencilDescriptor alloc] init];
        desc.depthWriteEnabled = info.depthTestEnabled;
        if (info.depthTestEnabled) {
            switch (info.depthFunc) {
                case GL_NEVER: desc.depthCompareFunction = MTLCompareFunctionNever; break;
                case GL_LESS: desc.depthCompareFunction = MTLCompareFunctionLess; break;
                case GL_EQUAL: desc.depthCompareFunction = MTLCompareFunctionEqual; break;
                case GL_LEQUAL: desc.depthCompareFunction = MTLCompareFunctionLessEqual; break;
                case GL_GREATER: desc.depthCompareFunction = MTLCompareFunctionGreater; break;
                case GL_NOTEQUAL: desc.depthCompareFunction = MTLCompareFunctionNotEqual; break;
                case GL_GEQUAL: desc.depthCompareFunction = MTLCompareFunctionGreaterEqual; break;
                case GL_ALWAYS: default: desc.depthCompareFunction = MTLCompareFunctionAlways; break;
            }
        } else {
            desc.depthCompareFunction = MTLCompareFunctionAlways;
        }
        return [device newDepthStencilStateWithDescriptor:desc];
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
    id<MTLLibrary> solidColorLibrary = nil;
    id<MTLFunction> solidColorVertexFn = nil;
    id<MTLFunction> solidColorFragmentFn = nil;
    id<MTLRenderPipelineState> solidColorPipelineState = nil;
    MTLPixelFormat solidColorPipelineColorFormat = MTLPixelFormatInvalid;
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

bool MetalFrameGraph::encodeSolidColorDraw(const MetalDrawInfo& info) {
    return impl_->encodeSolidColorDraw(info);
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
