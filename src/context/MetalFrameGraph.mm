#include "MetalFrameGraph.h"

#include "../objects/GLObjectStore.h"
#include "../state/GLStateTracker.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// Diagnostic tracing — set to 1 to enable, 0 to silence.
#define APPGL_TRACE_FRAMEGRAPH 0

#if APPGL_TRACE_FRAMEGRAPH
#define FG_TRACE(fmt, ...) NSLog(@"[FG] " fmt, ##__VA_ARGS__)
#else
#define FG_TRACE(fmt, ...) ((void)0)
#endif

namespace appgl {

// Phase 8X Group 4d follow-up¹⁴ — shared Metal translation helpers.
//
// These replace the inline `glTypeToMTLFormat` lambda that used to
// live inside `encodeTranslatedDraw`. `vaoTypeToMTLFormat` is the
// source-of-truth format derivation for each vertex attribute — it
// reads the VAO's `glVertexAttribPointer` parameters (type + size +
// normalized + integer) and returns the matching MTLVertexFormat. The
// old path fell back on `ShaderReflection::vertexInputs[i].type`,
// which only told us the *scalar* type the shader declared
// (`Float4`, `Int4`, …) and blindly trusted it even when the VBO
// actually stored packed UBYTE colors. BAR followup¹³-verification
// §Smoking-Gun showed that is exactly what breaks spring's glyph-
// text draw: `in vec4 col` reflected as `Float4`, but the VBO held
// `glVertexAttribPointer(loc, 4, GL_UNSIGNED_BYTE, GL_TRUE, 24, …)`
// — 4 bytes, not 16, so the GPU reinterpreted 4 bytes of UBYTE4 + 12
// bytes of the next vertex as `float4` and produced NaN.
static MTLVertexFormat vaoTypeToMTLFormat(
    GLenum type, GLint components, GLboolean normalized, bool isInteger)
{
    const bool norm = (normalized == GL_TRUE);
    const int  cc   = components < 1 ? 1 : (components > 4 ? 4 : components);

    switch (type) {
        case GL_FLOAT:
            switch (cc) {
                case 1: return MTLVertexFormatFloat;
                case 2: return MTLVertexFormatFloat2;
                case 3: return MTLVertexFormatFloat3;
                default: return MTLVertexFormatFloat4;
            }
        case GL_HALF_FLOAT:
            switch (cc) {
                case 1: return MTLVertexFormatHalf;
                case 2: return MTLVertexFormatHalf2;
                case 3: return MTLVertexFormatHalf3;
                default: return MTLVertexFormatHalf4;
            }
        case GL_UNSIGNED_BYTE:
            if (isInteger) {
                switch (cc) {
                    case 1: return MTLVertexFormatUChar;
                    case 2: return MTLVertexFormatUChar2;
                    case 3: return MTLVertexFormatUChar3;
                    default: return MTLVertexFormatUChar4;
                }
            }
            if (norm) {
                switch (cc) {
                    case 1: return MTLVertexFormatUCharNormalized;
                    case 2: return MTLVertexFormatUChar2Normalized;
                    case 3: return MTLVertexFormatUChar3Normalized;
                    default: return MTLVertexFormatUChar4Normalized;
                }
            }
            // Metal has no float-cast UChar format, so we can't cleanly
            // represent an unnormalized unsigned byte attribute feeding a
            // float shader input. Fall back to the normalized form — the
            // GPU will divide by 255, which is what the shader author
            // almost certainly wanted if they didn't ask for integer.
            switch (cc) {
                case 1: return MTLVertexFormatUCharNormalized;
                case 2: return MTLVertexFormatUChar2Normalized;
                case 3: return MTLVertexFormatUChar3Normalized;
                default: return MTLVertexFormatUChar4Normalized;
            }
        case GL_BYTE:
            if (isInteger) {
                switch (cc) {
                    case 1: return MTLVertexFormatChar;
                    case 2: return MTLVertexFormatChar2;
                    case 3: return MTLVertexFormatChar3;
                    default: return MTLVertexFormatChar4;
                }
            }
            switch (cc) {
                case 1: return MTLVertexFormatCharNormalized;
                case 2: return MTLVertexFormatChar2Normalized;
                case 3: return MTLVertexFormatChar3Normalized;
                default: return MTLVertexFormatChar4Normalized;
            }
        case GL_UNSIGNED_SHORT:
            if (isInteger) {
                switch (cc) {
                    case 1: return MTLVertexFormatUShort;
                    case 2: return MTLVertexFormatUShort2;
                    case 3: return MTLVertexFormatUShort3;
                    default: return MTLVertexFormatUShort4;
                }
            }
            switch (cc) {
                case 1: return MTLVertexFormatUShortNormalized;
                case 2: return MTLVertexFormatUShort2Normalized;
                case 3: return MTLVertexFormatUShort3Normalized;
                default: return MTLVertexFormatUShort4Normalized;
            }
        case GL_SHORT:
            if (isInteger) {
                switch (cc) {
                    case 1: return MTLVertexFormatShort;
                    case 2: return MTLVertexFormatShort2;
                    case 3: return MTLVertexFormatShort3;
                    default: return MTLVertexFormatShort4;
                }
            }
            switch (cc) {
                case 1: return MTLVertexFormatShortNormalized;
                case 2: return MTLVertexFormatShort2Normalized;
                case 3: return MTLVertexFormatShort3Normalized;
                default: return MTLVertexFormatShort4Normalized;
            }
        case GL_UNSIGNED_INT:
            switch (cc) {
                case 1: return MTLVertexFormatUInt;
                case 2: return MTLVertexFormatUInt2;
                case 3: return MTLVertexFormatUInt3;
                default: return MTLVertexFormatUInt4;
            }
        case GL_INT:
            switch (cc) {
                case 1: return MTLVertexFormatInt;
                case 2: return MTLVertexFormatInt2;
                case 3: return MTLVertexFormatInt3;
                default: return MTLVertexFormatInt4;
            }
        default:
            return MTLVertexFormatFloat4;
    }
}

// Phase 8X Group 4d follow-up¹⁴ — GL → Metal blend factor / equation
// mapping. GL enum namespace is fragmented across separate color and
// alpha factors, but the Metal side uses a single `MTLBlendFactor`
// enum that covers both. We map the common factors and return
// `MTLBlendFactorZero` (the documented default) for anything we don't
// recognise.
static MTLBlendFactor glBlendFactorToMTL(GLenum f) {
    switch (f) {
        case GL_ZERO:                     return MTLBlendFactorZero;
        case GL_ONE:                      return MTLBlendFactorOne;
        case GL_SRC_COLOR:                return MTLBlendFactorSourceColor;
        case GL_ONE_MINUS_SRC_COLOR:      return MTLBlendFactorOneMinusSourceColor;
        case GL_DST_COLOR:                return MTLBlendFactorDestinationColor;
        case GL_ONE_MINUS_DST_COLOR:      return MTLBlendFactorOneMinusDestinationColor;
        case GL_SRC_ALPHA:                return MTLBlendFactorSourceAlpha;
        case GL_ONE_MINUS_SRC_ALPHA:      return MTLBlendFactorOneMinusSourceAlpha;
        case GL_DST_ALPHA:                return MTLBlendFactorDestinationAlpha;
        case GL_ONE_MINUS_DST_ALPHA:      return MTLBlendFactorOneMinusDestinationAlpha;
        case GL_CONSTANT_COLOR:           return MTLBlendFactorBlendColor;
        case GL_ONE_MINUS_CONSTANT_COLOR: return MTLBlendFactorOneMinusBlendColor;
        case GL_CONSTANT_ALPHA:           return MTLBlendFactorBlendAlpha;
        case GL_ONE_MINUS_CONSTANT_ALPHA: return MTLBlendFactorOneMinusBlendAlpha;
        case GL_SRC_ALPHA_SATURATE:       return MTLBlendFactorSourceAlphaSaturated;
        default:                          return MTLBlendFactorZero;
    }
}

static MTLBlendOperation glBlendEqToMTL(GLenum eq) {
    switch (eq) {
        case GL_FUNC_ADD:              return MTLBlendOperationAdd;
        case GL_FUNC_SUBTRACT:         return MTLBlendOperationSubtract;
        case GL_FUNC_REVERSE_SUBTRACT: return MTLBlendOperationReverseSubtract;
        case GL_MIN:                   return MTLBlendOperationMin;
        case GL_MAX:                   return MTLBlendOperationMax;
        default:                       return MTLBlendOperationAdd;
    }
}

// Phase 8X Group 4d follow-up¹⁴ — pipeline cache key. A 64-bit hash
// of the state tuple that drives pipeline creation. The key is
// stable across draws that share the same compiled program and the
// same effective pipeline descriptor, so a program that draws both
// an opaque first pass and an alpha-blended second pass keeps both
// pipelines hot without thrashing. The 64 bits are laid out as:
//
//   [63..56] colorFormat low 8 bits  (MTLPixelFormat fits)
//   [55..55] blend.enabled
//   [54..54] colorMaskA
//   [53..53] colorMaskB
//   [52..52] colorMaskG
//   [51..51] colorMaskR
//   [50..48] eqRGB   (3 bits; covers Add/Sub/RevSub/Min/Max)
//   [47..45] eqAlpha (3 bits)
//   [44..41] srcRGB low 4 bits of MTLBlendFactor
//   [40..37] dstRGB low 4 bits
//   [36..33] srcAlpha low 4 bits
//   [32..29] dstAlpha low 4 bits
//   [28..0]  per-attribute format tuple hash (FNV-1a over the active
//            vertexAttributeLayouts + extraVertexBuffers[*].attributes
//            `glType/glComponentCount/glNormalized/glIsInteger` fields)
//
// Collisions are not catastrophic — the worst case is a wrong
// pipeline gets reused, which shows up as a validation failure from
// Metal on the next draw and triggers a rebuild. But the hash is
// structured so the common toggles (opaque ↔ alpha-blended with
// identical geometry layout) always produce distinct keys.
static std::uint64_t computePipelineCacheKey(
    const TranslatedDrawInfo& info, MTLPixelFormat colorFormat)
{
    std::uint64_t key = 0;
    key |= static_cast<std::uint64_t>(colorFormat & 0xFF) << 56;
    key |= (info.blend.enabled    ? 1ULL : 0ULL) << 55;
    key |= (info.blend.colorMaskA ? 1ULL : 0ULL) << 54;
    key |= (info.blend.colorMaskB ? 1ULL : 0ULL) << 53;
    key |= (info.blend.colorMaskG ? 1ULL : 0ULL) << 52;
    key |= (info.blend.colorMaskR ? 1ULL : 0ULL) << 51;

    const std::uint64_t eqRGB = static_cast<std::uint64_t>(
        glBlendEqToMTL(info.blend.equationRGB)) & 0x7ULL;
    const std::uint64_t eqA = static_cast<std::uint64_t>(
        glBlendEqToMTL(info.blend.equationAlpha)) & 0x7ULL;
    key |= eqRGB << 48;
    key |= eqA   << 45;

    const std::uint64_t srcRGB = static_cast<std::uint64_t>(
        glBlendFactorToMTL(info.blend.srcRGB)) & 0xFULL;
    const std::uint64_t dstRGB = static_cast<std::uint64_t>(
        glBlendFactorToMTL(info.blend.dstRGB)) & 0xFULL;
    const std::uint64_t srcA = static_cast<std::uint64_t>(
        glBlendFactorToMTL(info.blend.srcAlpha)) & 0xFULL;
    const std::uint64_t dstA = static_cast<std::uint64_t>(
        glBlendFactorToMTL(info.blend.dstAlpha)) & 0xFULL;
    key |= srcRGB << 41;
    key |= dstRGB << 37;
    key |= srcA   << 33;
    key |= dstA   << 29;

    // FNV-1a over the per-attribute format tuple. 29 bits is enough
    // to discriminate the half-dozen distinct layouts BAR's draw
    // path sees in practice — grow if collisions show up.
    std::uint32_t hash = 2166136261u;
    auto mix = [&hash](std::uint32_t v) {
        hash ^= v;
        hash *= 16777619u;
    };
    auto hashLayout = [&](const TranslatedDrawInfo::VertexAttributeLayout& l) {
        mix(static_cast<std::uint32_t>(l.location));
        mix(static_cast<std::uint32_t>(l.offset));
        mix(static_cast<std::uint32_t>(l.glType));
        mix(static_cast<std::uint32_t>(l.glComponentCount));
        mix(static_cast<std::uint32_t>(l.glNormalized));
        mix(l.glIsInteger ? 1u : 0u);
    };
    for (const auto& l : info.vertexAttributeLayouts) {
        hashLayout(l);
    }
    for (const auto& evb : info.extraVertexBuffers) {
        mix(static_cast<std::uint32_t>(evb.stride));
        mix(static_cast<std::uint32_t>(evb.divisor));
        for (const auto& l : evb.attributes) {
            hashLayout(l);
        }
    }
    key |= static_cast<std::uint64_t>(hash & 0x1FFFFFFFu);
    return key;
}

struct MetalFrameGraph::Impl {
    Impl(void* rawLayer, void* rawDevice, void* rawCommandQueue)
        : layer((__bridge CAMetalLayer*)rawLayer),
          device((__bridge id<MTLDevice>)rawDevice),
          commandQueue((__bridge id<MTLCommandQueue>)rawCommandQueue) {
        if (layer != nil && device != nil) {
            layer.device = device;
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.framebufferOnly = NO;
            layer.displaySyncEnabled = NO;
        }
        ensureDrawableResources();
        acquireRingSlot();  // OPT-8: acquire initial ring buffer slot (slot 0)
    }

    ~Impl() {
        // End any open render encoder before the autorelease pool reclaims it.
        // Without this, destroying a context with an in-flight render pass
        // triggers "Command encoder released without endEncoding".
        endRenderPass();
        if (currentCommandBuffer != nil) {
            [currentCommandBuffer commit];
            [currentCommandBuffer waitUntilCompleted];
            currentCommandBuffer = nil;
        }
        // OPT-8: Release any acquired ring slot to balance the semaphore.
        // All in-flight completion handlers have fired (Metal processes CBs
        // in commit order, and waitUntilCompleted on the last ensures all
        // prior CBs completed).
        if (ringSlotAcquired) {
            dispatch_semaphore_signal(frameSemaphore);
            ringSlotAcquired = false;
        }
    }

    void resize(GLsizei width, GLsizei height) {
        GLsizei newW = width > 0 ? width : 1;
        GLsizei newH = height > 0 ? height : 1;
        if (newW == drawableWidth && newH == drawableHeight) {
            return;  // No-op when size is unchanged.
        }
        drawableWidth = newW;
        drawableHeight = newH;
        headlessReadbackRGBA.clear();
        hasHeadlessReadback = false;
        if (layer != nil) {
            layer.drawableSize = CGSizeMake(drawableWidth, drawableHeight);
        }
        endRenderPass();
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

        FG_TRACE(@"encodeClear: enter (deferred)  encoder=%p cmdBuf=%p", currentRenderEncoder, currentCommandBuffer);

        // OPT-8: Acquire a ring buffer slot before any GPU work.
        acquireRingSlot();

        // Close any open render encoder and flush the prior command buffer.
        // This serves as a frame boundary: Metal can start executing the
        // previous frame's work while we set up the next one.  The pending
        // clear will be merged into the NEXT render pass as a load action,
        // eliminating the old separate clear-only render pass (OPT-4).
        endRenderPass();
        if (currentCommandBuffer != nil) {
            commitWithFrameSignal(currentCommandBuffer);  // OPT-8
            currentCommandBuffer = nil;
            currentDrawable = nil;
            pendingPresent = false;
            advanceRingBuffer();
            acquireRingSlot();  // OPT-8: acquire the next slot for this frame
        }
        ensureDrawableResources();

        // Store the clear parameters; they'll be consumed when the next
        // render pass opens (in encodeTranslatedDraw or encodeSolidColorDraw).
        hasPendingClear = true;
        pendingClearMask = mask;
        pendingClearColor = MTLClearColorMake(clearRed, clearGreen, clearBlue, clearAlpha);
        pendingClearDepth = clearDepth;
        pendingClearStencil = static_cast<std::uint32_t>(clearStencil);

        pendingPresent = true;
    }

    void beginRenderPass(GLStateTracker& state, GLObjectStore& objects) {
        (void)state;
        (void)objects;
        if (device == nil || commandQueue == nil) {
            return;
        }
        acquireRingSlot();  // OPT-8
        FG_TRACE(@"beginRenderPass: enter  encoder=%p cmdBuf=%p", currentRenderEncoder, currentCommandBuffer);
        endRenderPass();
        ensureDrawableResources();
        if (currentCommandBuffer == nil) {
            currentCommandBuffer = [commandQueue commandBuffer];
            attachErrorHandler(currentCommandBuffer, @"beginRenderPass");
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
        resetCachedEncoderState();
    }

    void* renderEncoder() const {
        return (__bridge void*)currentRenderEncoder;
    }

    void attachErrorHandler(id<MTLCommandBuffer> buf, NSString* label) {
#if APPGL_TRACE_FRAMEGRAPH
        buf.label = label;
        [buf addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            if (cb.status == MTLCommandBufferStatusError) {
                NSLog(@"[FG] *** COMMAND BUFFER ERROR *** label=%@ error=%@", cb.label, cb.error);
            }
        }];
#else
        (void)buf; (void)label;
#endif
    }

    void endRenderPass() {
        if (currentRenderEncoder != nil) {
            FG_TRACE(@"endRenderPass: ending encoder %p on cmdBuf %p", currentRenderEncoder, currentCommandBuffer);
            [currentRenderEncoder endEncoding];
            currentRenderEncoder = nil;
            pendingPresent = true;
        }
    }

    // Flush a deferred clear into a standalone render pass. Called by
    // copyPixels and present when a clear is pending but no draws occurred.
    void flushPendingClear() {
        if (!hasPendingClear || device == nil) return;

        ensureDrawableResources();
        if (currentCommandBuffer == nil) {
            currentCommandBuffer = [commandQueue commandBuffer];
            attachErrorHandler(currentCommandBuffer, @"flushClear");
            if (currentCommandBuffer == nil) { hasPendingClear = false; return; }
        }
        if (!usesOffscreenTarget && currentDrawable == nil) {
            currentDrawable = [layer nextDrawable];
            if (currentDrawable == nil) { hasPendingClear = false; return; }
        }

        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        if (colorTexture == nil) { hasPendingClear = false; return; }

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].loadAction = (pendingClearMask & GL_COLOR_BUFFER_BIT) ? MTLLoadActionClear : MTLLoadActionLoad;
        pass.colorAttachments[0].clearColor = pendingClearColor;
        if (depthStencilTexture != nil) {
            pass.depthAttachment.texture = depthStencilTexture;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.depthAttachment.loadAction = (pendingClearMask & GL_DEPTH_BUFFER_BIT) ? MTLLoadActionClear : MTLLoadActionLoad;
            pass.depthAttachment.clearDepth = pendingClearDepth;
            pass.stencilAttachment.texture = depthStencilTexture;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.loadAction = (pendingClearMask & GL_STENCIL_BUFFER_BIT) ? MTLLoadActionClear : MTLLoadActionLoad;
            pass.stencilAttachment.clearStencil = pendingClearStencil;
        }

        id<MTLRenderCommandEncoder> encoder = [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
        [encoder endEncoding];
        readbackSourceTexture = colorTexture;
        readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
        hasPendingClear = false;
        pendingPresent = true;
    }

    // Solid-color fallback draw path.
    //
    // Hand-written "solid color" MSL pipeline consuming one float3 position
    // attribute and a single float4 uniform color. Used as a fallback when the
    // active program has no translated MSL (e.g. program 0 or translation
    // failure). The primary draw path is encodeTranslatedDraw(), which uses
    // the GLSL→SPIR-V→MSL pipeline output cached on GLProgramObject.
    bool encodeSolidColorDraw(const MetalDrawInfo& info) {
        FG_TRACE(@"encodeSolidColorDraw: enter  mode=0x%X verts=%d encoder=%p cmdBuf=%p",
                 info.mode, info.vertexCount, currentRenderEncoder, currentCommandBuffer);
        if (device == nil || commandQueue == nil) {
            return false;
        }
        acquireRingSlot();  // OPT-8
        if (info.vertexCount <= 0 || info.positions == nullptr || info.positionByteCount == 0) {
            return false;
        }
        if (info.mode != GL_TRIANGLES && info.mode != GL_TRIANGLE_STRIP) {
            FG_TRACE(@"encodeSolidColorDraw: unsupported mode 0x%X, returning false", info.mode);
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

        // Close any open render encoder before starting the solid-color pass.
        endRenderPass();

        // Reuse the current command buffer if one exists, otherwise create new.
        if (currentCommandBuffer == nil) {
            currentCommandBuffer = [commandQueue commandBuffer];
            attachErrorHandler(currentCommandBuffer, @"solidColorDraw");
            if (currentCommandBuffer == nil) {
                return false;
            }
        }

        if (!usesOffscreenTarget && currentDrawable == nil) {
            currentDrawable = [layer nextDrawable];
            if (currentDrawable == nil) {
                FG_TRACE(@"encodeSolidColorDraw: nextDrawable returned nil!");
                return false;
            }
        }

        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
        if (colorTexture == nil) {
            return false;
        }

        // Merge any pending clear into this render pass's load action (OPT-4).
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = colorTexture;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (hasPendingClear && (pendingClearMask & GL_COLOR_BUFFER_BIT)) {
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor = pendingClearColor;
        } else {
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }
        if (depthStencilTexture != nil) {
            pass.depthAttachment.texture = depthStencilTexture;
            pass.depthAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.texture = depthStencilTexture;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            if (hasPendingClear && (pendingClearMask & GL_DEPTH_BUFFER_BIT)) {
                pass.depthAttachment.loadAction = MTLLoadActionClear;
                pass.depthAttachment.clearDepth = pendingClearDepth;
            } else {
                pass.depthAttachment.loadAction = MTLLoadActionLoad;
            }
            if (hasPendingClear && (pendingClearMask & GL_STENCIL_BUFFER_BIT)) {
                pass.stencilAttachment.loadAction = MTLLoadActionClear;
                pass.stencilAttachment.clearStencil = pendingClearStencil;
            } else {
                pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            }
        }
        hasPendingClear = false;

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
        [encoder setTriangleFillMode:info.wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];

        // Vertex positions are pushed as inline bytes (fits in Metal's 4KB limit
        // for every fixture we ship in Phase A). Attribute 0 lives in buffer 0.
        if (info.positionByteCount <= 4096) {
            [encoder setVertexBytes:info.positions length:info.positionByteCount atIndex:0];
        } else {
            auto alloc = ringSuballocate(info.positions, info.positionByteCount);
            if (alloc.buffer == nil) {
                [encoder endEncoding];
                return false;
            }
            [encoder setVertexBuffer:alloc.buffer offset:alloc.offset atIndex:0];
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
            auto iAlloc = ringSuballocate(info.indices, indexBytes);
            if (iAlloc.buffer == nil) {
                [encoder endEncoding];
                return false;
            }
            [encoder drawIndexedPrimitives:primitive
                                indexCount:static_cast<NSUInteger>(info.indexCount)
                                 indexType:metalIndexType
                               indexBuffer:iAlloc.buffer
                         indexBufferOffset:iAlloc.offset];
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

    bool encodeTranslatedDraw(TranslatedDrawInfo& info) {
        FG_TRACE(@"encodeTranslatedDraw: enter  mode=0x%X verts=%d instances=%d encoder=%p cmdBuf=%p",
                 info.mode, info.vertexCount, info.instanceCount, currentRenderEncoder, currentCommandBuffer);
        if (device == nil || commandQueue == nil) {
            return false;
        }
        acquireRingSlot();  // OPT-8
        if (info.vertexCount <= 0 || info.vertexData == nullptr || info.vertexDataByteCount == 0) {
            FG_TRACE(@"encodeTranslatedDraw: bad vertex data, returning false");
            return false;
        }
        if (info.vertexMSL == nullptr || info.fragmentMSL == nullptr ||
            info.vertexMSL->empty() || info.fragmentMSL->empty()) {
            FG_TRACE(@"encodeTranslatedDraw: no MSL source, returning false");
            return false;
        }

        ensureDrawableResources();

        // Lazily create the MTLRenderPipelineState from translated MSL.
        id<MTLTexture> colorTexture = usesOffscreenTarget ? offscreenColorTexture : nil;
        const MTLPixelFormat colorFormat = colorTexture != nil
            ? colorTexture.pixelFormat
            : MTLPixelFormatBGRA8Unorm;

        // Phase 8X Group 4d follow-up¹⁴ — map-based cache lookup.
        // The cache key encodes (colorFormat, blend tuple, per-
        // attribute format tuple) so a program that draws with
        // distinct blend modes or distinct VBO layouts keeps
        // multiple pipelines hot instead of thrashing on every
        // `glEnable(GL_BLEND)` ping-pong.
        const std::uint64_t pipelineCacheKey =
            computePipelineCacheKey(info, colorFormat);

        id<MTLRenderPipelineState> pipelineState = nil;
        if (info.pipelineStateCacheOut != nullptr) {
            auto it = info.pipelineStateCacheOut->find(pipelineCacheKey);
            if (it != info.pipelineStateCacheOut->end() && it->second != nullptr) {
                pipelineState = (__bridge id<MTLRenderPipelineState>)(it->second);
                ++pipelineCacheHits;
            }
        }
        // Legacy scalar cache kept as a fallback for the first-draw
        // diagnostic bookkeeping (`pipelineStateOut` is still read by
        // BAR tooling) — only honoured when the map path is missing,
        // which never happens in the current draw builders.
        if (pipelineState == nil && info.pipelineStateCacheOut == nullptr &&
            info.pipelineStateOut != nullptr && *info.pipelineStateOut != nullptr &&
            info.pipelineColorFormatOut != nullptr &&
            *info.pipelineColorFormatOut == static_cast<std::uint32_t>(colorFormat)) {
            pipelineState = (__bridge id<MTLRenderPipelineState>)(*info.pipelineStateOut);
            ++pipelineCacheHits;
        }
        if (pipelineState == nil) {
            // Phase 8X Group 4d follow-up⁴ — every entry into the build branch
            // bumps `pipelineBuildAttempts`, separately from the success-only
            // `pipelineCacheMisses` counter. This lets BAR-side tooling
            // distinguish "never tried" (attempts==0) from "tried and failed
            // every time" (attempts>0, failures==attempts, misses==0). Prior
            // to this round, the {hits:0, misses:0} state was ambiguous.
            ++pipelineBuildAttempts;
            const auto buildStart = std::chrono::steady_clock::now();

            // Phase 8X Group 4d follow-up⁴ — local helper for the five
            // Metal-side failure paths below. Captures the NSError
            // description AND a stage tag ("vertex-library",
            // "fragment-library", "vertex-function", "fragment-function",
            // "pipeline-state") into the caller-supplied output string so
            // GLContext can route it into the diagnostic ring as a
            // `pipeline-build` ShaderTranslationRecord. The first token in
            // the string is always the stage tag, so BAR can grep-aggregate
            // by failing stage even though the record stores the full text.
            //
            // The build-failure counter is bumped once per failure path so
            // PipelineCacheMetrics::buildFailures stays in lockstep with
            // the number of populated records (modulo first-time gating on
            // the GLContext side).
            auto recordBuildFailure = [&info, this](const char* stageTag, NSError* err) {
                ++pipelineBuildFailures;
                if (info.pipelineBuildErrorOut == nullptr) {
                    return;
                }
                std::string& out = *info.pipelineBuildErrorOut;
                out.assign(stageTag);
                out.append(": ");
                if (err != nil) {
                    NSString* desc = [err localizedDescription];
                    if (desc != nil) {
                        out.append([desc UTF8String] ? [desc UTF8String] : "(nil description)");
                    } else {
                        out.append("(nil description)");
                    }
                } else {
                    out.append("(nil error)");
                }
            };

            // Compile vertex MSL.
            NSError* error = nil;
            NSString* vertSrc = [NSString stringWithUTF8String:info.vertexMSL->c_str()];
            id<MTLLibrary> vertLib = [device newLibraryWithSource:vertSrc options:nil error:&error];
            if (vertLib == nil) {
                FG_TRACE(@"encodeTranslatedDraw: newLibraryWithSource(vertex) failed: %@", error);
                recordBuildFailure("vertex-library", error);
                return false;
            }
            // SPIRV-Cross names the entry points "main0" by default.
            id<MTLFunction> vertFn = [vertLib newFunctionWithName:@"main0"];
            if (vertFn == nil) {
                FG_TRACE(@"encodeTranslatedDraw: newFunctionWithName(vertex,main0) failed");
                recordBuildFailure("vertex-function", nil);
                return false;
            }

            // Compile fragment MSL.
            error = nil;  // reset before the next failable Metal call
            NSString* fragSrc = [NSString stringWithUTF8String:info.fragmentMSL->c_str()];
            id<MTLLibrary> fragLib = [device newLibraryWithSource:fragSrc options:nil error:&error];
            if (fragLib == nil) {
                FG_TRACE(@"encodeTranslatedDraw: newLibraryWithSource(fragment) failed: %@", error);
                recordBuildFailure("fragment-library", error);
                return false;
            }
            id<MTLFunction> fragFn = [fragLib newFunctionWithName:@"main0"];
            if (fragFn == nil) {
                FG_TRACE(@"encodeTranslatedDraw: newFunctionWithName(fragment,main0) failed");
                recordBuildFailure("fragment-function", nil);
                return false;
            }

            // Build vertex descriptor from reflection data.  Primary vertex
            // attributes (buffer 0) are per-vertex.  Extra vertex buffers
            // (buffer 1+) may use per-instance stepping (glVertexAttribDivisor).
            MTLVertexDescriptor* vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];

            // Helper: map shader-reflected scalar type to MTLVertexFormat.
            // Phase 8X Group 4d follow-up¹⁴ — ONLY used as a fallback
            // when the VAO record is missing (`glType == 0`). The
            // primary path now reads `vaoTypeToMTLFormat` from the
            // caller-supplied layout, so the Float4/UByte4 mismatch
            // BAR diagnosed in followup¹³ is impossible to reach
            // without a draw builder that forgot to propagate the
            // VAO fields.
            auto glTypeToMTLFormatFallback = [](GLenum type) -> MTLVertexFormat {
                switch (type) {
                    case GL_FLOAT:      return MTLVertexFormatFloat;
                    case GL_FLOAT_VEC2: return MTLVertexFormatFloat2;
                    case GL_FLOAT_VEC3: return MTLVertexFormatFloat3;
                    case GL_FLOAT_VEC4: return MTLVertexFormatFloat4;
                    case GL_INT:        return MTLVertexFormatInt;
                    case GL_INT_VEC2:   return MTLVertexFormatInt2;
                    case GL_INT_VEC3:   return MTLVertexFormatInt3;
                    case GL_INT_VEC4:   return MTLVertexFormatInt4;
                    default:            return MTLVertexFormatFloat3;
                }
            };

            if (info.vertexReflection != nullptr) {
                for (const auto& input : info.vertexReflection->vertexInputs) {
                    // Determine which Metal buffer this attribute lives in.
                    NSUInteger metalBuf = 0;
                    NSUInteger attrOffset = 0;
                    const TranslatedDrawInfo::VertexAttributeLayout* matched = nullptr;

                    // Check primary (buffer 0) attributes first.
                    for (const auto& layout : info.vertexAttributeLayouts) {
                        if (layout.location == input.location) {
                            metalBuf = 0;
                            attrOffset = static_cast<NSUInteger>(layout.offset);
                            matched = &layout;
                            break;
                        }
                    }

                    // Check extra vertex buffers (buffer 1+).
                    if (matched == nullptr) {
                        for (std::size_t ei = 0; ei < info.extraVertexBuffers.size(); ++ei) {
                            for (const auto& layout : info.extraVertexBuffers[ei].attributes) {
                                if (layout.location == input.location) {
                                    metalBuf = static_cast<NSUInteger>(ei + 1);
                                    attrOffset = static_cast<NSUInteger>(layout.offset);
                                    matched = &layout;
                                    break;
                                }
                            }
                            if (matched != nullptr) break;
                        }
                    }

                    // Phase 8X Group 4d follow-up¹⁴ — derive the Metal
                    // vertex format from the VAO record (the real VBO
                    // layout) rather than the shader-reflected scalar
                    // type. The fallback branch only runs when the
                    // draw builder failed to propagate VAO fields,
                    // which would indicate a plumbing bug; it preserves
                    // the pre-follow-up¹⁴ behavior for safety.
                    MTLVertexFormat format;
                    if (matched != nullptr && matched->glType != 0) {
                        format = vaoTypeToMTLFormat(
                            matched->glType,
                            matched->glComponentCount,
                            matched->glNormalized,
                            matched->glIsInteger);
                    } else {
                        format = glTypeToMTLFormatFallback(input.type);
                    }

                    vertexDescriptor.attributes[input.location].format = format;
                    vertexDescriptor.attributes[input.location].offset = attrOffset;
                    vertexDescriptor.attributes[input.location].bufferIndex = metalBuf;
                }
            }

            // Buffer 0 layout: primary per-vertex data.
            const NSUInteger stride = info.vertexStride > 0
                ? info.vertexStride
                : sizeof(float) * 3u;
            vertexDescriptor.layouts[0].stride = stride;
            vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
            vertexDescriptor.layouts[0].stepRate = 1;

            // Extra buffer layouts (1+): per-instance or additional per-vertex.
            for (std::size_t ei = 0; ei < info.extraVertexBuffers.size(); ++ei) {
                const auto& evb = info.extraVertexBuffers[ei];
                NSUInteger metalBuf = static_cast<NSUInteger>(ei + 1);
                vertexDescriptor.layouts[metalBuf].stride = static_cast<NSUInteger>(evb.stride);
                if (evb.divisor > 0) {
                    vertexDescriptor.layouts[metalBuf].stepFunction = MTLVertexStepFunctionPerInstance;
                    vertexDescriptor.layouts[metalBuf].stepRate = static_cast<NSUInteger>(evb.divisor);
                } else {
                    vertexDescriptor.layouts[metalBuf].stepFunction = MTLVertexStepFunctionPerVertex;
                    vertexDescriptor.layouts[metalBuf].stepRate = 1;
                }
            }

            MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
            desc.vertexFunction = vertFn;
            desc.fragmentFunction = fragFn;
            desc.vertexDescriptor = vertexDescriptor;
            desc.colorAttachments[0].pixelFormat = colorFormat;
            desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            desc.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

            // Phase 8X Group 4d follow-up¹⁴ — apply the GL blend
            // state to the Metal pipeline color attachment. Before
            // follow-up¹⁴ the descriptor was left at Metal's defaults
            // (`blendingEnabled=NO, src=One, dst=Zero, op=Add,
            // writeMask=All`), so every translated draw was opaque
            // regardless of `glEnable(GL_BLEND) + glBlendFunc(...)`.
            // BAR followup¹³-verification §Candidate-1 traced that
            // as the reason spring's semi-transparent glyph overlay
            // composited as a solid rectangle instead of mixing with
            // the background. The cache key (above) already includes
            // the blend tuple, so a program that uses the same
            // shader with two different blend modes builds two
            // distinct pipelines and keeps both hot.
            MTLRenderPipelineColorAttachmentDescriptor* colorDesc = desc.colorAttachments[0];
            colorDesc.blendingEnabled = info.blend.enabled ? YES : NO;
            colorDesc.sourceRGBBlendFactor        = glBlendFactorToMTL(info.blend.srcRGB);
            colorDesc.destinationRGBBlendFactor   = glBlendFactorToMTL(info.blend.dstRGB);
            colorDesc.sourceAlphaBlendFactor      = glBlendFactorToMTL(info.blend.srcAlpha);
            colorDesc.destinationAlphaBlendFactor = glBlendFactorToMTL(info.blend.dstAlpha);
            colorDesc.rgbBlendOperation           = glBlendEqToMTL(info.blend.equationRGB);
            colorDesc.alphaBlendOperation         = glBlendEqToMTL(info.blend.equationAlpha);
            MTLColorWriteMask writeMask = MTLColorWriteMaskNone;
            if (info.blend.colorMaskR) writeMask |= MTLColorWriteMaskRed;
            if (info.blend.colorMaskG) writeMask |= MTLColorWriteMaskGreen;
            if (info.blend.colorMaskB) writeMask |= MTLColorWriteMaskBlue;
            if (info.blend.colorMaskA) writeMask |= MTLColorWriteMaskAlpha;
            colorDesc.writeMask = writeMask;

            // Phase 8X Group 4d follow-up¹³ — one-shot per-program
            // diagnostic dump of the Metal pipeline descriptor shape.
            // Covers BAR followup¹²-verification §Candidate 1 (blend
            // state — did the translated-draw pipeline inherit GL
            // blend enable / src / dst / equation, or is it sitting on
            // Metal's default-off blend?) and §Candidate 2 (vertex
            // descriptor format — did `col` arrive as
            // MTLVertexFormatUChar4Normalized or as Float4? and do
            // the offsets/bufferIndex match the VBO layout peek dumped
            // at the first-draw site?). Both dumps fire from here
            // because the descriptor objects go out of scope after
            // newRenderPipelineStateWithDescriptor; macOS has no
            // runtime reflection API to walk a compiled
            // MTLRenderPipelineState. Gated by
            // `loggedPipelineBuildPrograms` so the dump fires exactly
            // once per GL program name per MetalFrameGraph instance
            // (GLContext) — builds are cached on GLProgramObject so a
            // program hits this branch at most once in the cache-miss
            // path anyway; the explicit set protects against theoretical
            // cache-invalidation cases.
            //
            // Format strings match the Metal header names so BAR can
            // grep for them directly against
            // reference/OpenGL-Refpages/gl4/glBlendFunc.xml +
            // glVertexAttribPointer.xml semantics. No decoding tables
            // here — raw enum values are emitted alongside a short
            // symbolic name for the common cases so the log stays
            // self-describing without a lookup table.
            if (info.program != 0 &&
                loggedPipelineBuildPrograms.insert(info.program).second) {
                auto vertexFormatName = [](MTLVertexFormat f) -> const char* {
                    switch (f) {
                        case MTLVertexFormatInvalid:          return "Invalid";
                        case MTLVertexFormatFloat:            return "Float";
                        case MTLVertexFormatFloat2:           return "Float2";
                        case MTLVertexFormatFloat3:           return "Float3";
                        case MTLVertexFormatFloat4:           return "Float4";
                        case MTLVertexFormatInt:              return "Int";
                        case MTLVertexFormatInt2:             return "Int2";
                        case MTLVertexFormatInt3:             return "Int3";
                        case MTLVertexFormatInt4:             return "Int4";
                        case MTLVertexFormatUInt:             return "UInt";
                        case MTLVertexFormatUInt2:            return "UInt2";
                        case MTLVertexFormatUInt3:            return "UInt3";
                        case MTLVertexFormatUInt4:            return "UInt4";
                        case MTLVertexFormatUChar:            return "UChar";
                        case MTLVertexFormatUChar2:           return "UChar2";
                        case MTLVertexFormatUChar3:           return "UChar3";
                        case MTLVertexFormatUChar4:           return "UChar4";
                        case MTLVertexFormatUCharNormalized:  return "UCharNormalized";
                        case MTLVertexFormatUChar2Normalized: return "UChar2Normalized";
                        case MTLVertexFormatUChar3Normalized: return "UChar3Normalized";
                        case MTLVertexFormatUChar4Normalized: return "UChar4Normalized";
                        case MTLVertexFormatChar:             return "Char";
                        case MTLVertexFormatChar2:            return "Char2";
                        case MTLVertexFormatChar3:            return "Char3";
                        case MTLVertexFormatChar4:            return "Char4";
                        case MTLVertexFormatCharNormalized:   return "CharNormalized";
                        case MTLVertexFormatChar2Normalized:  return "Char2Normalized";
                        case MTLVertexFormatChar3Normalized:  return "Char3Normalized";
                        case MTLVertexFormatChar4Normalized:  return "Char4Normalized";
                        case MTLVertexFormatUShort:           return "UShort";
                        case MTLVertexFormatUShort2:          return "UShort2";
                        case MTLVertexFormatUShort3:          return "UShort3";
                        case MTLVertexFormatUShort4:          return "UShort4";
                        case MTLVertexFormatUShortNormalized: return "UShortNormalized";
                        case MTLVertexFormatUShort2Normalized:return "UShort2Normalized";
                        case MTLVertexFormatUShort3Normalized:return "UShort3Normalized";
                        case MTLVertexFormatUShort4Normalized:return "UShort4Normalized";
                        case MTLVertexFormatShort:            return "Short";
                        case MTLVertexFormatShort2:           return "Short2";
                        case MTLVertexFormatShort3:           return "Short3";
                        case MTLVertexFormatShort4:           return "Short4";
                        case MTLVertexFormatShortNormalized:  return "ShortNormalized";
                        case MTLVertexFormatShort2Normalized: return "Short2Normalized";
                        case MTLVertexFormatShort3Normalized: return "Short3Normalized";
                        case MTLVertexFormatShort4Normalized: return "Short4Normalized";
                        case MTLVertexFormatHalf:             return "Half";
                        case MTLVertexFormatHalf2:            return "Half2";
                        case MTLVertexFormatHalf3:            return "Half3";
                        case MTLVertexFormatHalf4:            return "Half4";
                        default:                              return "Other";
                    }
                };
                auto stepFunctionName = [](MTLVertexStepFunction f) -> const char* {
                    switch (f) {
                        case MTLVertexStepFunctionConstant:             return "Constant";
                        case MTLVertexStepFunctionPerVertex:            return "PerVertex";
                        case MTLVertexStepFunctionPerInstance:          return "PerInstance";
                        case MTLVertexStepFunctionPerPatch:             return "PerPatch";
                        case MTLVertexStepFunctionPerPatchControlPoint: return "PerPatchControlPoint";
                        default:                                         return "Unknown";
                    }
                };
                auto blendFactorName = [](MTLBlendFactor f) -> const char* {
                    switch (f) {
                        case MTLBlendFactorZero:                     return "Zero";
                        case MTLBlendFactorOne:                      return "One";
                        case MTLBlendFactorSourceColor:              return "SourceColor";
                        case MTLBlendFactorOneMinusSourceColor:      return "OneMinusSourceColor";
                        case MTLBlendFactorSourceAlpha:              return "SourceAlpha";
                        case MTLBlendFactorOneMinusSourceAlpha:      return "OneMinusSourceAlpha";
                        case MTLBlendFactorDestinationColor:         return "DestinationColor";
                        case MTLBlendFactorOneMinusDestinationColor: return "OneMinusDestinationColor";
                        case MTLBlendFactorDestinationAlpha:         return "DestinationAlpha";
                        case MTLBlendFactorOneMinusDestinationAlpha: return "OneMinusDestinationAlpha";
                        case MTLBlendFactorSourceAlphaSaturated:     return "SourceAlphaSaturated";
                        case MTLBlendFactorBlendColor:               return "BlendColor";
                        case MTLBlendFactorOneMinusBlendColor:       return "OneMinusBlendColor";
                        case MTLBlendFactorBlendAlpha:               return "BlendAlpha";
                        case MTLBlendFactorOneMinusBlendAlpha:       return "OneMinusBlendAlpha";
                        default:                                     return "Other";
                    }
                };
                auto blendOpName = [](MTLBlendOperation op) -> const char* {
                    switch (op) {
                        case MTLBlendOperationAdd:             return "Add";
                        case MTLBlendOperationSubtract:        return "Subtract";
                        case MTLBlendOperationReverseSubtract: return "ReverseSubtract";
                        case MTLBlendOperationMin:             return "Min";
                        case MTLBlendOperationMax:             return "Max";
                        default:                               return "Other";
                    }
                };

                NSLog(@"[GL] pipeline-build first-build program=%u"
                      @" colorFormat=0x%lX depthFormat=0x%lX",
                      info.program,
                      (unsigned long)desc.colorAttachments[0].pixelFormat,
                      (unsigned long)desc.depthAttachmentPixelFormat);

                // Vertex descriptor: walk attributes 0..15 and layouts
                // 0..15. A slot with MTLVertexFormatInvalid is either
                // unused or reserved by the attribute-layout map; we
                // emit those at a lower verbosity by suppressing them
                // unless every slot is Invalid.
                NSLog(@"[GL]   vertexDescriptor attributes:");
                std::size_t nonInvalidAttrs = 0;
                for (NSUInteger i = 0; i < 16; ++i) {
                    MTLVertexAttributeDescriptor* a = vertexDescriptor.attributes[i];
                    if (a.format == MTLVertexFormatInvalid) {
                        continue;
                    }
                    ++nonInvalidAttrs;
                    NSLog(@"[GL]     attr[%lu] format=MTLVertexFormat%s(%lu)"
                          @" offset=%lu bufferIndex=%lu",
                          (unsigned long)i,
                          vertexFormatName(a.format),
                          (unsigned long)a.format,
                          (unsigned long)a.offset,
                          (unsigned long)a.bufferIndex);
                }
                if (nonInvalidAttrs == 0) {
                    NSLog(@"[GL]     (no attributes set — vertex stage runs without vertex descriptor input)");
                }
                NSLog(@"[GL]   vertexDescriptor layouts:");
                std::size_t nonEmptyLayouts = 0;
                for (NSUInteger i = 0; i < 16; ++i) {
                    MTLVertexBufferLayoutDescriptor* l = vertexDescriptor.layouts[i];
                    if (l.stride == 0) {
                        continue;
                    }
                    ++nonEmptyLayouts;
                    NSLog(@"[GL]     layout[%lu] stride=%lu"
                          @" stepFunction=MTLVertexStepFunction%s(%lu)"
                          @" stepRate=%lu",
                          (unsigned long)i,
                          (unsigned long)l.stride,
                          stepFunctionName(l.stepFunction),
                          (unsigned long)l.stepFunction,
                          (unsigned long)l.stepRate);
                }
                if (nonEmptyLayouts == 0) {
                    NSLog(@"[GL]     (no layouts set — stride=0 on every slot)");
                }

                // Color attachment 0 blend state. BAR §Candidate 1.
                // Phase 8X Group 4d follow-up¹⁴ — the descriptor now
                // carries the GL blend state snapshot from the draw
                // site (`GLStateTracker::blendState()` +
                // `isEnabled(GL_BLEND)`), so these values reflect the
                // live pipeline rather than the MTLRenderPipeline-
                // ColorAttachmentDescriptor defaults. The annotation
                // flipped from `gl-plumbed=no` to `gl-plumbed=yes`
                // as the verification signal for BAR's follow-up¹³
                // memo. Apple's defaults (blendingEnabled=NO,
                // src=One, dst=Zero, op=Add, writeMask=All) are
                // still what you'd see for an opaque draw that
                // runs with `glDisable(GL_BLEND)`.
                MTLRenderPipelineColorAttachmentDescriptor* ca = desc.colorAttachments[0];
                NSLog(@"[GL]   colorAttachment[0].blendingEnabled=%d (gl-plumbed=yes)",
                      ca.blendingEnabled ? 1 : 0);
                NSLog(@"[GL]   colorAttachment[0].rgb   src=%s(%lu) dst=%s(%lu) op=%s(%lu)",
                      blendFactorName(ca.sourceRGBBlendFactor),
                      (unsigned long)ca.sourceRGBBlendFactor,
                      blendFactorName(ca.destinationRGBBlendFactor),
                      (unsigned long)ca.destinationRGBBlendFactor,
                      blendOpName(ca.rgbBlendOperation),
                      (unsigned long)ca.rgbBlendOperation);
                NSLog(@"[GL]   colorAttachment[0].alpha src=%s(%lu) dst=%s(%lu) op=%s(%lu)",
                      blendFactorName(ca.sourceAlphaBlendFactor),
                      (unsigned long)ca.sourceAlphaBlendFactor,
                      blendFactorName(ca.destinationAlphaBlendFactor),
                      (unsigned long)ca.destinationAlphaBlendFactor,
                      blendOpName(ca.alphaBlendOperation),
                      (unsigned long)ca.alphaBlendOperation);
                NSLog(@"[GL]   colorAttachment[0].writeMask=0x%lX (all=0xF)",
                      (unsigned long)ca.writeMask);
                NSLog(@"[GL] pipeline-build first-build program=%u END", info.program);
            }

            error = nil;  // reset before the final failable Metal call
            pipelineState = [device newRenderPipelineStateWithDescriptor:desc error:&error];
            if (pipelineState == nil) {
                FG_TRACE(@"encodeTranslatedDraw: newRenderPipelineStateWithDescriptor failed: %@", error);
                recordBuildFailure("pipeline-state", error);
                return false;
            }

            const auto buildEnd = std::chrono::steady_clock::now();
            pipelineCumulativeBuildMs += std::chrono::duration<double, std::milli>(buildEnd - buildStart).count();
            ++pipelineCacheMisses;

            // Phase 8X Group 4d follow-up¹⁴ — insert into the
            // map-based cache first. The old scalar
            // {pipelineStateOut, pipelineColorFormatOut} pair is
            // still populated so the first-draw diagnostic bookkeeping
            // (and the leak-on-relink reset in `linkProgram`) keeps
            // seeing the most-recently-built pipeline in the same
            // slot it has always read from.
            if (info.pipelineStateCacheOut != nullptr) {
                void* retained = (void*)CFBridgingRetain(pipelineState);
                auto inserted = info.pipelineStateCacheOut->emplace(pipelineCacheKey, retained);
                if (!inserted.second) {
                    // Key collided with an existing entry — release the
                    // old one and swap in the new. Shouldn't happen in
                    // normal operation because the cache miss path is
                    // only reached when the lookup failed.
                    if (inserted.first->second != nullptr) {
                        CFRelease(inserted.first->second);
                    }
                    inserted.first->second = retained;
                }
            }
            if (info.pipelineStateOut != nullptr) {
                // The scalar slot is a secondary mirror of the most
                // recently built pipeline. Release the previous
                // occupant and retain afresh so the scalar cache
                // stays balanced even when the map path also holds
                // an entry.
                if (*info.pipelineStateOut != nullptr) {
                    CFRelease(*info.pipelineStateOut);
                }
                *info.pipelineStateOut = (void*)CFBridgingRetain(pipelineState);
            }
            if (info.pipelineColorFormatOut != nullptr) {
                *info.pipelineColorFormatOut = static_cast<std::uint32_t>(colorFormat);
            }
        }

        // Ensure a render encoder is open. Subsequent draws reuse the same
        // encoder without any GPU sync.
        if (currentRenderEncoder == nil) {
            FG_TRACE(@"encodeTranslatedDraw: opening new render pass (prior cmdBuf=%p pendingClear=%d)",
                     currentCommandBuffer, hasPendingClear);
            // Reuse the current command buffer if one exists (e.g. from a
            // prior solid-color draw), otherwise create a new one.
            if (currentCommandBuffer == nil) {
                currentCommandBuffer = [commandQueue commandBuffer];
                attachErrorHandler(currentCommandBuffer, @"translatedDraw");
                if (currentCommandBuffer == nil) {
                    return false;
                }
            }

            if (!usesOffscreenTarget && currentDrawable == nil) {
                currentDrawable = [layer nextDrawable];
                if (currentDrawable == nil) {
                    return false;
                }
            }

            colorTexture = usesOffscreenTarget ? offscreenColorTexture : currentDrawable.texture;
            if (colorTexture == nil) {
                return false;
            }

            // Ensure depth/stencil texture matches color attachment dimensions.
            // A mismatch here triggers Metal validation assertions on draw.
            if (depthStencilTexture != nil &&
                (depthStencilTexture.width != colorTexture.width ||
                 depthStencilTexture.height != colorTexture.height)) {
                NSLog(@"[FG] depth/color size MISMATCH: depth=%lux%lu color=%lux%lu — rebuilding depth",
                      (unsigned long)depthStencilTexture.width,
                      (unsigned long)depthStencilTexture.height,
                      (unsigned long)colorTexture.width,
                      (unsigned long)colorTexture.height);
                MTLTextureDescriptor* dd = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                width:colorTexture.width
                                               height:colorTexture.height
                                            mipmapped:NO];
                dd.storageMode = MTLStorageModePrivate;
                dd.usage = MTLTextureUsageRenderTarget;
                depthStencilTexture = [device newTextureWithDescriptor:dd];
                drawableWidth = static_cast<GLsizei>(colorTexture.width);
                drawableHeight = static_cast<GLsizei>(colorTexture.height);
            }

            // Build the render pass, merging any pending clear into the load
            // action so clear+draws share a single render pass (OPT-4).
            MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = colorTexture;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            if (hasPendingClear && (pendingClearMask & GL_COLOR_BUFFER_BIT)) {
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].clearColor = pendingClearColor;
            } else {
                pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            }
            if (depthStencilTexture != nil) {
                pass.depthAttachment.texture = depthStencilTexture;
                pass.depthAttachment.storeAction = MTLStoreActionStore;
                pass.stencilAttachment.texture = depthStencilTexture;
                pass.stencilAttachment.storeAction = MTLStoreActionStore;
                if (hasPendingClear && (pendingClearMask & GL_DEPTH_BUFFER_BIT)) {
                    pass.depthAttachment.loadAction = MTLLoadActionClear;
                    pass.depthAttachment.clearDepth = pendingClearDepth;
                } else {
                    pass.depthAttachment.loadAction = MTLLoadActionLoad;
                }
                if (hasPendingClear && (pendingClearMask & GL_STENCIL_BUFFER_BIT)) {
                    pass.stencilAttachment.loadAction = MTLLoadActionClear;
                    pass.stencilAttachment.clearStencil = pendingClearStencil;
                } else {
                    pass.stencilAttachment.loadAction = MTLLoadActionLoad;
                }
            }
            hasPendingClear = false;

            currentRenderEncoder = [currentCommandBuffer renderCommandEncoderWithDescriptor:pass];
            if (currentRenderEncoder == nil) {
                return false;
            }
            readbackSourceTexture = colorTexture;
            readbackSourceIsBGRA = colorTexture.pixelFormat == MTLPixelFormatBGRA8Unorm;
            resetCachedEncoderState();
        }

        // Encode the draw into the shared render encoder.
        // OPT-6: skip redundant state calls when consecutive draws share
        // the same pipeline / depth-stencil / raster state.
        if (pipelineState != cachedPipelineState) {
            [currentRenderEncoder setRenderPipelineState:pipelineState];
            cachedPipelineState = pipelineState;
        }

        if (depthStencilTexture != nil) {
            MetalDrawInfo fakeInfo;
            fakeInfo.depthTestEnabled = info.depthTestEnabled;
            fakeInfo.depthFunc = info.depthFunc;
            id<MTLDepthStencilState> dsState = depthStencilStateForDraw(fakeInfo);
            if (dsState != nil && dsState != cachedDepthStencilState) {
                [currentRenderEncoder setDepthStencilState:dsState];
                cachedDepthStencilState = dsState;
            }
        }

        const MTLCullMode desiredCull = info.cullFaceEnabled
            ? (info.cullFaceMode == GL_FRONT ? MTLCullModeFront : MTLCullModeBack)
            : MTLCullModeNone;
        if (desiredCull != cachedCullMode) {
            [currentRenderEncoder setCullMode:desiredCull];
            cachedCullMode = desiredCull;
        }
        const MTLWinding desiredWinding = info.frontFace == GL_CW ? MTLWindingClockwise : MTLWindingCounterClockwise;
        if (desiredWinding != cachedFrontFaceWinding) {
            [currentRenderEncoder setFrontFacingWinding:desiredWinding];
            cachedFrontFaceWinding = desiredWinding;
        }
        const MTLTriangleFillMode desiredFill = info.wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill;
        if (desiredFill != cachedFillMode) {
            [currentRenderEncoder setTriangleFillMode:desiredFill];
            cachedFillMode = desiredFill;
        }

        // Bind vertex data at buffer index 0.
        // OPT-5: when the VBO has a pre-uploaded Metal buffer, bind it
        // directly — zero memcpy.  Otherwise fall back to the ring buffer
        // sub-allocation path (OPT-1).
        if (info.metalVertexBuffer != nullptr) {
            id<MTLBuffer> mtlBuf = (__bridge id<MTLBuffer>)info.metalVertexBuffer;
            [currentRenderEncoder setVertexBuffer:mtlBuf
                                           offset:static_cast<NSUInteger>(info.metalVertexBufferOffset)
                                          atIndex:0];
        } else {
            auto alloc = ringSuballocate(info.vertexData, info.vertexDataByteCount);
            if (alloc.buffer == nil) {
                return false;
            }
            [currentRenderEncoder setVertexBuffer:alloc.buffer offset:alloc.offset atIndex:0];
        }

        // Bind extra vertex buffers (buffer index 1+) — e.g. per-instance
        // attribute data from glVertexAttribDivisor.
        for (std::size_t ei = 0; ei < info.extraVertexBuffers.size(); ++ei) {
            const auto& evb = info.extraVertexBuffers[ei];
            if (evb.metalBuffer != nullptr) {
                id<MTLBuffer> mtlBuf = (__bridge id<MTLBuffer>)evb.metalBuffer;
                [currentRenderEncoder setVertexBuffer:mtlBuf
                                               offset:static_cast<NSUInteger>(evb.metalBufferOffset)
                                              atIndex:static_cast<NSUInteger>(ei + 1)];
            } else {
                auto alloc = ringSuballocate(evb.data, evb.byteCount);
                if (alloc.buffer == nil) {
                    return false;
                }
                [currentRenderEncoder setVertexBuffer:alloc.buffer
                                               offset:alloc.offset
                                              atIndex:static_cast<NSUInteger>(ei + 1)];
            }
        }

        // Bind per-stage uniform buffers at Metal buffer index 16.
        // Each stage has its own push-constant struct layout (they may
        // declare different subsets of the program's bare GL uniforms).
        if (info.vertexUniformData != nullptr && info.vertexUniformSize > 0) {
            [currentRenderEncoder setVertexBytes:info.vertexUniformData
                                          length:info.vertexUniformSize
                                         atIndex:16];
        }
        if (info.fragmentUniformData != nullptr && info.fragmentUniformSize > 0) {
            [currentRenderEncoder setFragmentBytes:info.fragmentUniformData
                                            length:info.fragmentUniformSize
                                           atIndex:16];
        }

        // Phase 8X Group 4d follow-up⁷ — bind textures and samplers for
        // this draw. GLContext::drawArrays / drawArraysInstanced /
        // drawElements populates `info.fragmentTextures` and
        // `info.vertexTextures` by walking the program's sampler uniforms,
        // resolving each one through the GL texture-unit state, and
        // snapping pointers to the cached MTLTexture / MTLSamplerState on
        // the texture object. A slot with a nullptr texture or sampler is
        // skipped silently — that means the GL app bound a sampler
        // uniform that points at an empty texture unit, which on the GL
        // side would sample a 1×1×1 default texture. Metal has no such
        // default so the slot stays unbound and the shader gets whatever
        // the driver leaves there. Most engines bind a real texture
        // before drawing anything that samples it, so the "null slot"
        // case is only expected for debug paths that we don't care about
        // in the smoke run. BAR's select-menu fragment shaders sample
        // one texture per draw (the glyph atlas page), so every call
        // here populates one binding in `fragmentTextures`.
        //
        // Phase 8X Group 4d follow-up⁸ — diagnostic instrumentation for
        // BAR's followup⁷ verification "byte-identical screenshot"
        // finding. The binding fix landed structurally clean (gauntlet
        // green, no regressions) but produced zero pixel-level change in
        // the select-menu render. Three hypotheses (BAR followup⁷ §Visual):
        //   A. bindings are emitted but all metalTexture/metalSamplerState
        //      pointers are nullptr, so every entry hits the skip-guard
        //      below and the encoder stays in the unbound state.
        //   B. `resolveSamplerBindings` finds zero reflection entries so
        //      `fragmentTextures` is empty on arrival — see matching log
        //      in `GLContext::Impl::resolveSamplerBindings`.
        //   C. BAR's text rendering runs through a program that never
        //      reaches this encoder (fall-through to solid-color path
        //      before the translated gate).
        // This one-shot-per-program log distinguishes A from B and C:
        //   - if this line never logs for programs 5/6/8/10 → hypothesis C
        //   - if it logs with sizes (0/0) → hypothesis B (zero bindings
        //     arrived on the tdi; check resolve log)
        //   - if it logs with sizes > 0 and hasTexture=0 or hasSampler=0 →
        //     hypothesis A (bindings arrived but were null)
        //   - if it logs with sizes > 0 and hasTexture=1 hasSampler=1 →
        //     bindings are real but pixels are still unchanged; means
        //     the issue is downstream of binding (shader texture coord,
        //     missing color-attachment write, etc.)
        // Keyed on info.program so the log fires exactly once per GL
        // program name per MetalFrameGraph instance (one per
        // GLContext). Single-threaded GL context means no mutex is
        // needed. See `loggedBindingPrograms` on Impl for the
        // multi-context rationale.
        {
            if (info.program != 0 &&
                loggedBindingPrograms.insert(info.program).second) {
                NSLog(@"[GL] encodeTranslatedDraw first-draw program=%u"
                      @" fragmentTextures.size=%zu vertexTextures.size=%zu",
                      info.program,
                      info.fragmentTextures.size(),
                      info.vertexTextures.size());
                for (std::size_t i = 0; i < info.fragmentTextures.size(); ++i) {
                    const auto& b = info.fragmentTextures[i];
                    NSLog(@"[GL]   frag[%zu] slot=%u hasTexture=%d hasSampler=%d",
                          i,
                          static_cast<unsigned>(b.metalSlot),
                          b.metalTexture != nullptr ? 1 : 0,
                          b.metalSamplerState != nullptr ? 1 : 0);
                }
                for (std::size_t i = 0; i < info.vertexTextures.size(); ++i) {
                    const auto& b = info.vertexTextures[i];
                    NSLog(@"[GL]   vert[%zu] slot=%u hasTexture=%d hasSampler=%d",
                          i,
                          static_cast<unsigned>(b.metalSlot),
                          b.metalTexture != nullptr ? 1 : 0,
                          b.metalSamplerState != nullptr ? 1 : 0);
                }

                // Phase 8X Group 4d follow-up¹⁰ — §Secondary VBO peek
                // for BAR's Theory A/B split. Dump the first 32 bytes
                // of the vertex data, the stride, and the attribute
                // layout list so BAR can decide whether the UVs on
                // programs 8/10 are tightly inside `[0, 1)` (Theory A
                // out — REPEAT wrap doesn't matter) or whether
                // they're scrambled / out-of-range (Theory B hint —
                // VBO upload bug, or Recoil-side vertex data problem).
                //
                // The peek reads from `info.vertexData` when non-null
                // (CPU scratch path) or from the Metal buffer's CPU-
                // visible contents when the draw path bound a shared-
                // storage MTLBuffer directly (OPT-5 path). Private-
                // storage buffers are not readable from CPU so we
                // silently skip the hex dump in that case — BAR can
                // still see the stride and layout list to cross-check
                // against native GL's vertex array setup.
                //
                // Also dumps the attribute layout list so BAR knows
                // which byte offsets inside the stride hold `uv`
                // attributes — UI quad VBOs typically have something
                // like (pos.xy, uv.xy) packed tight or
                // (pos.xyz, uv.xy, color.rgba) in a 36-byte stride.
                NSLog(@"[GL]   vbo stride=%zu vertexDataByteCount=%zu"
                      @" metalBuf=%d extraBufs=%zu attrLayouts=%zu",
                      info.vertexStride,
                      info.vertexDataByteCount,
                      info.metalVertexBuffer != nullptr ? 1 : 0,
                      info.extraVertexBuffers.size(),
                      info.vertexAttributeLayouts.size());
                for (std::size_t i = 0; i < info.vertexAttributeLayouts.size(); ++i) {
                    const auto& a = info.vertexAttributeLayouts[i];
                    NSLog(@"[GL]     attr[%zu] location=%u offset=%zu",
                          i, a.location, a.offset);
                }

                // Resolve a CPU pointer to the start of the vertex
                // stream we're about to encode.
                const std::uint8_t* peekPtr = nullptr;
                if (info.vertexData != nullptr) {
                    peekPtr = static_cast<const std::uint8_t*>(info.vertexData);
                } else if (info.metalVertexBuffer != nullptr) {
                    id<MTLBuffer> mtlBuf = (__bridge id<MTLBuffer>)info.metalVertexBuffer;
                    // storageMode shared/managed → contents is a
                    // valid CPU pointer. Private is nil/garbage.
                    if ([mtlBuf storageMode] == MTLStorageModeShared ||
                        [mtlBuf storageMode] == MTLStorageModeManaged) {
                        const std::uint8_t* base =
                            static_cast<const std::uint8_t*>([mtlBuf contents]);
                        if (base != nullptr) {
                            peekPtr = base + info.metalVertexBufferOffset;
                        }
                    }
                }

                if (peekPtr != nullptr) {
                    // Peek 32 bytes — enough to cover a full 32-byte
                    // stride (pos.xyz + uv.xy + color.rgba layouts) or
                    // two 16-byte stride quads (pos.xy + uv.xy). BAR
                    // can decode by stride; the stride is on the
                    // preceding line.
                    const std::size_t peekLen = 32;
                    char hexBuf[128];
                    char floatBuf[128];
                    for (std::size_t i = 0; i < peekLen; ++i) {
                        std::snprintf(hexBuf + i * 3, sizeof(hexBuf) - i * 3,
                                      "%02X ", peekPtr[i]);
                    }
                    hexBuf[peekLen * 3 - 1] = '\0';
                    // Also interpret as 8 floats for quick visual
                    // sanity-check of position/UV ranges.
                    float asFloats[8];
                    std::memcpy(asFloats, peekPtr, sizeof(asFloats));
                    std::snprintf(floatBuf, sizeof(floatBuf),
                        "%.3f %.3f %.3f %.3f %.3f %.3f %.3f %.3f",
                        asFloats[0], asFloats[1], asFloats[2], asFloats[3],
                        asFloats[4], asFloats[5], asFloats[6], asFloats[7]);
                    NSLog(@"[GL]     vbo peek32 hex=[%s]", hexBuf);
                    NSLog(@"[GL]     vbo peek32 f32=[%s]", floatBuf);
                } else {
                    NSLog(@"[GL]     vbo peek32 skip=private-or-null");
                }
            }
        }
        for (const auto& binding : info.fragmentTextures) {
            if (binding.metalTexture == nullptr || binding.metalSamplerState == nullptr) {
                continue;
            }
            id<MTLTexture> tex = (__bridge id<MTLTexture>)binding.metalTexture;
            id<MTLSamplerState> smp = (__bridge id<MTLSamplerState>)binding.metalSamplerState;
            [currentRenderEncoder setFragmentTexture:tex
                                             atIndex:static_cast<NSUInteger>(binding.metalSlot)];
            [currentRenderEncoder setFragmentSamplerState:smp
                                                  atIndex:static_cast<NSUInteger>(binding.metalSlot)];
        }
        for (const auto& binding : info.vertexTextures) {
            if (binding.metalTexture == nullptr || binding.metalSamplerState == nullptr) {
                continue;
            }
            id<MTLTexture> tex = (__bridge id<MTLTexture>)binding.metalTexture;
            id<MTLSamplerState> smp = (__bridge id<MTLSamplerState>)binding.metalSamplerState;
            [currentRenderEncoder setVertexTexture:tex
                                           atIndex:static_cast<NSUInteger>(binding.metalSlot)];
            [currentRenderEncoder setVertexSamplerState:smp
                                                atIndex:static_cast<NSUInteger>(binding.metalSlot)];
        }

        const MTLPrimitiveType primitive = (info.mode == GL_TRIANGLE_STRIP)
            ? MTLPrimitiveTypeTriangleStrip
            : (info.mode == GL_LINES ? MTLPrimitiveTypeLine
                : (info.mode == GL_LINE_STRIP ? MTLPrimitiveTypeLineStrip
                    : MTLPrimitiveTypeTriangle));

        if (info.indices != nullptr && info.indexCount > 0) {
            MTLIndexType metalIndexType = MTLIndexTypeUInt16;
            std::size_t bytesPerIndex = 2;
            if (info.indexType == GL_UNSIGNED_INT) {
                metalIndexType = MTLIndexTypeUInt32;
                bytesPerIndex = 4;
            }

            // OPT-5: use direct Metal index buffer when available.
            id<MTLBuffer> idxBuffer = nil;
            NSUInteger idxOffset = 0;
            if (info.metalIndexBuffer != nullptr) {
                idxBuffer = (__bridge id<MTLBuffer>)info.metalIndexBuffer;
                idxOffset = static_cast<NSUInteger>(info.metalIndexBufferOffset);
            } else {
                const std::size_t indexBytes = static_cast<std::size_t>(info.indexCount) * bytesPerIndex;
                auto iAlloc = ringSuballocate(info.indices, indexBytes);
                if (iAlloc.buffer == nil) {
                    return false;
                }
                idxBuffer = iAlloc.buffer;
                idxOffset = iAlloc.offset;
            }

            if (info.instanceCount > 1) {
                [currentRenderEncoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(info.indexCount)
                                     indexType:metalIndexType
                                   indexBuffer:idxBuffer
                             indexBufferOffset:idxOffset
                                 instanceCount:static_cast<NSUInteger>(info.instanceCount)
                                    baseVertex:0
                                  baseInstance:static_cast<NSUInteger>(info.baseInstance)];
            } else {
                [currentRenderEncoder drawIndexedPrimitives:primitive
                                    indexCount:static_cast<NSUInteger>(info.indexCount)
                                     indexType:metalIndexType
                                   indexBuffer:idxBuffer
                             indexBufferOffset:idxOffset];
            }
        } else {
            if (info.instanceCount > 1) {
                [currentRenderEncoder drawPrimitives:primitive
                            vertexStart:0
                            vertexCount:static_cast<NSUInteger>(info.vertexCount)
                          instanceCount:static_cast<NSUInteger>(info.instanceCount)
                           baseInstance:static_cast<NSUInteger>(info.baseInstance)];
            } else {
                [currentRenderEncoder drawPrimitives:primitive
                            vertexStart:0
                            vertexCount:static_cast<NSUInteger>(info.vertexCount)];
            }
        }

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
        // Cache key: pack (depthTestEnabled, depthFunc) into a single uint32.
        // The state space is tiny (~16 combinations), so after the first frame
        // this is a pure hash-table lookup with zero Metal allocations.
        const std::uint32_t key = (info.depthTestEnabled ? 0x10000u : 0u)
                                | (static_cast<std::uint32_t>(info.depthFunc) & 0xFFFFu);

        auto it = depthStencilCache.find(key);
        if (it != depthStencilCache.end()) {
            return it->second;
        }

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

        id<MTLDepthStencilState> state = [device newDepthStencilStateWithDescriptor:desc];
        depthStencilCache[key] = state;
        return state;
    }

    void endFrame(GLObjectStore& objects) {
        endRenderPass();
        objects.drainDeferredDeletes();
        if (currentCommandBuffer != nil) {
            if (!usesOffscreenTarget && currentDrawable != nil) {
                [currentCommandBuffer presentDrawable:currentDrawable];
            }
            commitWithFrameSignal(currentCommandBuffer);  // OPT-8
            invalidateTransientState();
            advanceRingBuffer();
        } else {
            invalidateTransientState();
        }
    }

    void present() {
        FG_TRACE(@"present: enter  pendingPresent=%d encoder=%p cmdBuf=%p drawable=%p",
                 pendingPresent, currentRenderEncoder, currentCommandBuffer, currentDrawable);
        // Flush any deferred clear that wasn't consumed by a draw call.
        if (hasPendingClear) {
            flushPendingClear();
        }
        if (!pendingPresent || currentCommandBuffer == nil) {
            return;
        }
        endRenderPass();
        if (!usesOffscreenTarget && currentDrawable != nil) {
            [currentCommandBuffer presentDrawable:currentDrawable];
        }
        // OPT-8: async commit — the completion handler signals the frame
        // semaphore, allowing the CPU to encode the next frame while the GPU
        // processes this one.  Replaces the old waitUntilCompleted which
        // serialised CPU and GPU completely for offscreen targets.
        commitWithFrameSignal(currentCommandBuffer);
        invalidateTransientState();
        advanceRingBuffer();
    }

    bool copyPixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels) {
        FG_TRACE(@"copyPixels: enter  encoder=%p cmdBuf=%p", currentRenderEncoder, currentCommandBuffer);
        if (outPixels == nullptr || width < 0 || height < 0) {
            return false;
        }
        if (width == 0 || height == 0) {
            return true;
        }
        if (device == nil || commandQueue == nil) {
            return copyHeadlessPixels(x, y, width, height, outPixels);
        }
        // Flush any deferred clear before readback.
        if (hasPendingClear) {
            flushPendingClear();
        }
        // Close any open render encoder before we commit the command buffer
        // for readback — otherwise Metal asserts on uncommitted encoder.
        endRenderPass();
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
                // OPT-8: GPU finished synchronously — release the ring slot
                // so the semaphore stays balanced (no completion handler here).
                if (ringSlotAcquired) {
                    dispatch_semaphore_signal(frameSemaphore);
                    ringSlotAcquired = false;
                }
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
            // OPT-8: release ring slot if we consumed the current CB synchronously.
            if (consumedCurrentCommandBuffer && ringSlotAcquired) {
                dispatch_semaphore_signal(frameSemaphore);
                ringSlotAcquired = false;
            }
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

    // Benchmark metric accessors.
    std::uint64_t getPipelineCacheHits() const { return pipelineCacheHits; }
    std::uint64_t getPipelineCacheMisses() const { return pipelineCacheMisses; }
    std::uint64_t getPipelineBuildAttempts() const { return pipelineBuildAttempts; }
    std::uint64_t getPipelineBuildFailures() const { return pipelineBuildFailures; }
    double getPipelineBuildMs() const { return pipelineCumulativeBuildMs; }
    void resetMetrics() {
        pipelineCacheHits = 0;
        pipelineCacheMisses = 0;
        pipelineBuildAttempts = 0;
        pipelineBuildFailures = 0;
        pipelineCumulativeBuildMs = 0.0;
    }
    std::uint64_t getMetalAllocatedBytes() const {
        if (device != nil && [device respondsToSelector:@selector(currentAllocatedSize)]) {
            return static_cast<std::uint64_t>(device.currentAllocatedSize);
        }
        return 0;
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
        // Ensure the render encoder is properly ended before we drop it.
        endRenderPass();
        currentCommandBuffer = nil;
        currentDrawable = nil;
        pendingPresent = false;
        hasPendingClear = false;
        resetCachedEncoderState();
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

    // Deferred clear state (OPT-4). Stored by encodeClear(), consumed by
    // the next render pass that opens in encodeTranslatedDraw or
    // encodeSolidColorDraw. Flushed standalone by copyPixels/present
    // if no draw occurs between clear and readback/present.
    bool hasPendingClear = false;
    GLbitfield pendingClearMask = 0;
    MTLClearColor pendingClearColor = MTLClearColorMake(0, 0, 0, 0);
    double pendingClearDepth = 1.0;
    std::uint32_t pendingClearStencil = 0;

    // Depth/stencil state cache — keyed by packed (depthTestEnabled, depthFunc).
    // The state space is tiny (~16 combinations); after warmup every draw is
    // a pure hash-table hit with zero Metal allocations.
    std::unordered_map<std::uint32_t, id<MTLDepthStencilState>> depthStencilCache;

    // Phase 8X Group 4d follow-up⁸ — per-context dedup for the
    // first-draw-per-program binding diagnostic NSLog in
    // `encodeTranslatedDraw`. Lives on the Impl rather than as a
    // function-local static so multi-context test runs (gauntlet
    // phase-a/c/d/7) don't cross-pollute: each GLContext owns its own
    // MetalFrameGraph and therefore its own set, and each scene's
    // program=1 gets logged exactly once. Under single-context
    // workloads (BAR/Recoil) the behavior is identical to a static set
    // but without the cross-run leak.
    std::unordered_set<GLuint> loggedBindingPrograms;

    // Phase 8X Group 4d follow-up¹³ — per-context dedup for the
    // first-build-per-program pipeline diagnostic NSLog. Fires once
    // per GL program name per MetalFrameGraph instance at the pipeline
    // build path (just before newRenderPipelineStateWithDescriptor),
    // where we still have a live MTLRenderPipelineDescriptor +
    // MTLVertexDescriptor in scope. BAR followup¹²-verification
    // §Candidate 1 (blend state) and §Candidate 2 (MTLVertexDescriptor
    // format mismatch) both need the actual Metal-side descriptor
    // values — we can't reconstruct them from `info` at the first-draw
    // logging site because the descriptor is gone once
    // newRenderPipelineStateWithDescriptor returns. Pipeline builds
    // are cached on GLProgramObject so this fires exactly once per
    // program per process (matching the existing `loggedBindingPrograms`
    // granularity and the `loggedSamplerResolvePrograms` one on
    // GLContext's Impl). Keyed on info.program.
    std::unordered_set<GLuint> loggedPipelineBuildPrograms;

    // ── Encoder state deduplication (OPT-6) ──
    // Track what was last set on the current render encoder. Skip redundant
    // Metal API calls when consecutive draws share the same state — typical
    // for batches of objects using the same shader/material.  Reset to
    // sentinel values whenever a new render encoder is created.
    id<MTLRenderPipelineState> cachedPipelineState = nil;
    id<MTLDepthStencilState> cachedDepthStencilState = nil;
    MTLCullMode cachedCullMode = static_cast<MTLCullMode>(0xFFFFFFFF);
    MTLWinding cachedFrontFaceWinding = static_cast<MTLWinding>(0xFFFFFFFF);
    MTLTriangleFillMode cachedFillMode = static_cast<MTLTriangleFillMode>(0xFFFFFFFF);

    void resetCachedEncoderState() {
        cachedPipelineState = nil;
        cachedDepthStencilState = nil;
        cachedCullMode = static_cast<MTLCullMode>(0xFFFFFFFF);
        cachedFrontFaceWinding = static_cast<MTLWinding>(0xFFFFFFFF);
        cachedFillMode = static_cast<MTLTriangleFillMode>(0xFFFFFFFF);
    }

    // ── Ring buffer for per-draw vertex/index data (OPT-1) ──
    // Triple-buffered: 3 large MTLBuffers rotate each frame. Within a frame,
    // sub-allocations bump a write offset with 256-byte alignment. This
    // eliminates per-draw [device newBufferWithBytes:] calls — the dominant
    // per-draw overhead (~15-20µs each).
    static constexpr int kRingBufferCount = 3;
    static constexpr std::size_t kRingBufferSize = 16 * 1024 * 1024; // 16 MB
    static constexpr std::size_t kRingBufferAlign = 256;

    // OPT-8: Semaphore-based frame pacing.  Initialized to kRingBufferCount
    // so the CPU can fill up to 3 ring slots before blocking.  Each frame
    // waits (acquireRingSlot) before writing, and the GPU completion handler
    // signals when it finishes the command buffer for that slot.  This
    // overlaps CPU encoding with GPU rendering — the key optimization that
    // replaces the old waitUntilCompleted serialisation.
    dispatch_semaphore_t frameSemaphore = dispatch_semaphore_create(kRingBufferCount);
    bool ringSlotAcquired = false;

    id<MTLBuffer> ringBuffers[kRingBufferCount] = { nil, nil, nil };
    int ringBufferIndex = 0;
    std::size_t ringBufferOffset = 0;

    void ensureRingBuffers() {
        if (ringBuffers[0] != nil) return;
        for (int i = 0; i < kRingBufferCount; ++i) {
            ringBuffers[i] = [device newBufferWithLength:kRingBufferSize
                                                 options:MTLResourceStorageModeShared];
        }
    }

    // Sub-allocate from the active ring buffer. Returns the buffer and the
    // byte offset of the allocation. Copies |byteCount| bytes from |src|.
    // If the ring buffer is full, falls back to a one-off allocation.
    struct RingAlloc {
        id<MTLBuffer> buffer;
        std::size_t offset;
    };

    RingAlloc ringSuballocate(const void* src, std::size_t byteCount) {
        ensureRingBuffers();
        const std::size_t aligned = (byteCount + kRingBufferAlign - 1) & ~(kRingBufferAlign - 1);
        id<MTLBuffer> active = ringBuffers[ringBufferIndex];

        if (active != nil && ringBufferOffset + byteCount <= kRingBufferSize) {
            // Fast path: bump-allocate from ring buffer.
            std::memcpy(static_cast<std::uint8_t*>([active contents]) + ringBufferOffset,
                        src, byteCount);
            std::size_t thisOffset = ringBufferOffset;
            ringBufferOffset += aligned;
            return { active, thisOffset };
        }

        // Overflow fallback: single draw exceeds remaining space.
        id<MTLBuffer> fallback = [device newBufferWithBytes:src
                                                      length:byteCount
                                                     options:MTLResourceStorageModeShared];
        return { fallback, 0 };
    }

    // OPT-8: Acquire the current ring buffer slot, blocking if all slots
    // are in-flight with the GPU.  Idempotent within a frame — only waits
    // once per ring-buffer generation.
    void acquireRingSlot() {
        if (!ringSlotAcquired) {
            dispatch_semaphore_wait(frameSemaphore, DISPATCH_TIME_FOREVER);
            ringSlotAcquired = true;
        }
    }

    // OPT-8: Commit a command buffer with a completion handler that signals
    // the frame semaphore when the GPU finishes.  Use this (instead of raw
    // [cb commit]) whenever the commit releases a ring buffer slot.
    void commitWithFrameSignal(id<MTLCommandBuffer> cb) {
        dispatch_semaphore_t sem = frameSemaphore;
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
            dispatch_semaphore_signal(sem);
        }];
        [cb commit];
    }

    void advanceRingBuffer() {
        ringBufferIndex = (ringBufferIndex + 1) % kRingBufferCount;
        ringBufferOffset = 0;
        ringSlotAcquired = false;  // OPT-8: next frame must re-acquire
    }

    // Pipeline cache metrics (for benchmark instrumentation).
    //
    // Phase 8X Group 4d follow-up⁴ — `pipelineBuildAttempts` /
    // `pipelineBuildFailures` are added so the {hits, misses} pair stays
    // a clean cache-effectiveness signal while the new pair tells BAR
    // whether the build branch is even being entered (and how often it's
    // failing). Invariant: `attempts == misses + failures` for every draw.
    std::uint64_t pipelineCacheHits = 0;
    std::uint64_t pipelineCacheMisses = 0;
    std::uint64_t pipelineBuildAttempts = 0;
    std::uint64_t pipelineBuildFailures = 0;
    double pipelineCumulativeBuildMs = 0.0;
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

bool MetalFrameGraph::encodeTranslatedDraw(TranslatedDrawInfo& info) {
    return impl_->encodeTranslatedDraw(info);
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

MetalFrameGraph::PipelineCacheMetrics MetalFrameGraph::pipelineCacheMetrics() const {
    PipelineCacheMetrics m;
    m.hits = impl_->getPipelineCacheHits();
    m.misses = impl_->getPipelineCacheMisses();
    m.buildAttempts = impl_->getPipelineBuildAttempts();
    m.buildFailures = impl_->getPipelineBuildFailures();
    m.cumulativeBuildMillis = impl_->getPipelineBuildMs();
    return m;
}

void MetalFrameGraph::resetPipelineCacheMetrics() {
    impl_->resetMetrics();
}

std::uint64_t MetalFrameGraph::metalAllocatedBytes() const {
    return impl_->getMetalAllocatedBytes();
}

}  // namespace appgl
