#include "FragmentShadingRateModule.h"

#include "../ExtensionContext.h"

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
    if (!isTrivialFragmentShadingRateCombinerOp(combinerOp0)) {
        ctx.pushError(GL_INVALID_OPERATION,
                      "glShadingRateCombinerOpsEXT",
                      "non-trivial fragment shading rate combinerOp0 is not supported");
        return false;
    }
    if (!isTrivialFragmentShadingRateCombinerOp(combinerOp1)) {
        ctx.pushError(GL_INVALID_OPERATION,
                      "glShadingRateCombinerOpsEXT",
                      "non-trivial fragment shading rate combinerOp1 is not supported");
        return false;
    }
    if (combinerOp0 != GL_FRAGMENT_SHADING_RATE_COMBINER_OP_KEEP_EXT) {
        ctx.pushError(GL_INVALID_OPERATION,
                      "glShadingRateCombinerOpsEXT",
                      "primitive fragment shading rate combinerOp0 is not supported");
        return false;
    }
    if (combinerOp1 != GL_FRAGMENT_SHADING_RATE_COMBINER_OP_KEEP_EXT) {
        ctx.pushError(GL_INVALID_OPERATION,
                      "glShadingRateCombinerOpsEXT",
                      "attachment fragment shading rate combinerOp1 is not supported");
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
    (void)texture;
    (void)baseLayer;
    (void)numLayers;
    (void)texelWidth;
    (void)texelHeight;
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
    ctx.pushError(GL_INVALID_OPERATION,
                  "glFramebufferShadingRateEXT",
                  "GL_EXT_fragment_shading_rate_attachment is not advertised or implemented");
    return false;
}

}  // namespace appgl::extensions::fragment_shading_rate
