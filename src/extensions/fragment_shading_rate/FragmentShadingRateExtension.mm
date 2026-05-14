#include "FragmentShadingRateModule.h"

#include "../ExtensionContext.h"
#include "../../objects/GLObjectStore.h"
#include "../../state/GLStateTracker.h"

#include <algorithm>

namespace appgl::extensions::fragment_shading_rate {
namespace {

constexpr GLenum kSupportedRates[] = {
    GL_SHADING_RATE_1X1_PIXELS_EXT,
    GL_SHADING_RATE_1X2_PIXELS_EXT,
    GL_SHADING_RATE_2X1_PIXELS_EXT,
    GL_SHADING_RATE_2X2_PIXELS_EXT,
};

}  // namespace

bool getFragmentShadingRates(ExtensionContext& ctx,
                             GLsizei samples,
                             GLsizei maxCount,
                             GLsizei* count,
                             GLenum* shadingRates) {
    if (maxCount < 0) {
        ctx.pushError(GL_INVALID_VALUE,
                      "glGetFragmentShadingRatesEXT",
                      "maxCount must be non-negative");
        return false;
    }

    const bool supportedSampleCount = samples == 1 || samples == 4;
    const GLsizei availableCount = supportedSampleCount
        ? static_cast<GLsizei>(sizeof(kSupportedRates) / sizeof(kSupportedRates[0]))
        : 0;
    const GLsizei writeCount = shadingRates != nullptr ? std::min(maxCount, availableCount) : 0;
    for (GLsizei i = 0; i < writeCount; ++i) {
        shadingRates[i] = kSupportedRates[i];
    }
    if (count != nullptr) {
        *count = writeCount;
    }
    return true;
}

bool shadingRate(ExtensionContext& ctx, GLenum rate) {
    if (!isFragmentShadingRateEnum(rate)) {
        ctx.pushError(GL_INVALID_ENUM, "glShadingRateEXT", "rate is not a valid fragment shading rate");
        return false;
    }
    setDrawRate(ctx, rate);
    return true;
}

bool shadingRateCombinerOps(ExtensionContext& ctx, GLenum combinerOp0, GLenum combinerOp1) {
    if (!isFragmentShadingRateCombinerOp(combinerOp0)) {
        ctx.pushError(GL_INVALID_ENUM,
                      "glShadingRateCombinerOpsEXT",
                      "combinerOp0 is not a valid fragment shading rate combiner");
        return false;
    }
    if (!isFragmentShadingRateCombinerOp(combinerOp1)) {
        ctx.pushError(GL_INVALID_ENUM,
                      "glShadingRateCombinerOpsEXT",
                      "combinerOp1 is not a valid fragment shading rate combiner");
        return false;
    }
    if (combinerOp0 != GL_FRAGMENT_SHADING_RATE_COMBINER_OP_KEEP_EXT &&
        !isPrimitiveAvailable(ctx)) {
        ctx.pushError(GL_INVALID_OPERATION,
                      "glShadingRateCombinerOpsEXT",
                      "primitive fragment shading rate combinerOp0 is not supported");
        return false;
    }
    setCombinerOps(ctx, combinerOp0, combinerOp1);
    return true;
}

bool framebufferShadingRate(ExtensionContext& ctx,
                            GLenum target,
                            GLenum attachment,
                            GLuint texture,
                            GLint baseLayer,
                            GLsizei numLayers,
                            GLsizei texelWidth,
                            GLsizei texelHeight) {
    if (target != GL_FRAMEBUFFER && target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER) {
        ctx.pushError(GL_INVALID_ENUM, "glFramebufferShadingRateEXT", "target is not a framebuffer target");
        return false;
    }
    if (attachment != GL_SHADING_RATE_ATTACHMENT_EXT) {
        ctx.pushError(GL_INVALID_ENUM,
                      "glFramebufferShadingRateEXT",
                      "attachment is not GL_SHADING_RATE_ATTACHMENT_EXT");
        return false;
    }

    const GLuint framebuffer = target == GL_READ_FRAMEBUFFER
        ? ctx.state().boundReadFramebuffer()
        : ctx.state().boundDrawFramebuffer();
    if (framebuffer == 0) {
        ctx.pushError(GL_INVALID_OPERATION,
                      "glFramebufferShadingRateEXT",
                      "default framebuffer shading-rate attachment is not supported");
        return false;
    }
    if (ctx.objects().framebuffers().get(framebuffer) == nullptr) {
        ctx.pushError(GL_INVALID_OPERATION,
                      "glFramebufferShadingRateEXT",
                      "framebuffer target is not backed by a framebuffer object");
        return false;
    }

    if (texture == 0) {
        clearFramebufferAttachment(ctx, framebuffer);
        return true;
    }

    const GLTextureObject* textureObject = ctx.objects().textures().get(texture);
    if (textureObject == nullptr || !textureObject->instantiated || !textureObject->desc.immutable) {
        ctx.pushError(GL_INVALID_VALUE,
                      "glFramebufferShadingRateEXT",
                      "texture must name an immutable shading-rate texture");
        return false;
    }
    if (textureObject->target != GL_TEXTURE_2D && textureObject->target != GL_TEXTURE_2D_ARRAY) {
        ctx.pushError(GL_INVALID_OPERATION,
                      "glFramebufferShadingRateEXT",
                      "texture target is not valid for a shading-rate attachment");
        return false;
    }
    if (textureObject->desc.internalFormat != GL_R8UI) {
        ctx.pushError(GL_INVALID_OPERATION,
                      "glFramebufferShadingRateEXT",
                      "texture internal format is not GL_R8UI");
        return false;
    }

    constexpr GLsizei kAttachmentTexelWidth = 256;
    constexpr GLsizei kAttachmentTexelHeight = 256;
    constexpr GLsizei kAttachmentLayers = 1;
    if (baseLayer < 0 || baseLayer >= kAttachmentLayers) {
        ctx.pushError(GL_INVALID_VALUE,
                      "glFramebufferShadingRateEXT",
                      "baseLayer exceeds the supported attachment layer count");
        return false;
    }
    if (numLayers <= 0 || numLayers > kAttachmentLayers || baseLayer + numLayers > kAttachmentLayers) {
        ctx.pushError(GL_INVALID_VALUE,
                      "glFramebufferShadingRateEXT",
                      "numLayers exceeds the supported attachment layer count");
        return false;
    }
    if (texelWidth != kAttachmentTexelWidth || texelHeight != kAttachmentTexelHeight) {
        ctx.pushError(GL_INVALID_VALUE,
                      "glFramebufferShadingRateEXT",
                      "texel size must match the advertised shading-rate attachment granularity");
        return false;
    }

    setFramebufferAttachment(ctx, framebuffer, texture, baseLayer, numLayers, texelWidth, texelHeight);
    return true;
}

}  // namespace appgl::extensions::fragment_shading_rate
