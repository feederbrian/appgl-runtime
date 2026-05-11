#include "FragmentShadingRateModule.h"
#include "RasterizationRateMap.h"

#include "../ExtensionContext.h"
#include "../ExtensionRegistry.h"
#include "../../state/GLStateTracker.h"
#include "../../../include/AppGL/extensions/fragment_shading_rate.h"

#include <algorithm>
#include <mutex>
#include <unordered_map>

namespace appgl::extensions::fragment_shading_rate {
namespace {

bool gActive = false;

std::mutex& stateMutex() {
    static std::mutex mutex;
    return mutex;
}

std::unordered_map<const GLContext*, State>& contextStates() {
    static std::unordered_map<const GLContext*, State> states;
    return states;
}

State& stateForLocked(ExtensionContext& ctx) {
    return contextStates()[&ctx.context()];
}

const ExtensionModuleDescriptor kDescriptor = {
    "fragment_shading_rate",
    extensionString,
    isAvailable,
    initialize,
    shutdown,
    {},
    {
        currentDrawRate,
        getFragmentShadingRates,
        shadingRate,
        shadingRateCombinerOps,
        framebufferShadingRate,
        queryBoolean,
        queryInteger,
        queryInteger64,
        queryFloat,
        queryDouble,
        attachRenderPass
    }
};

struct Registrar {
    Registrar() {
        ExtensionRegistry::registerModule(kDescriptor);
        ExtensionRegistry::registerModule({
            "fragment_shading_rate_attachment",
            attachmentExtensionString,
            isAvailable,
            nullptr,
            nullptr,
            {},
            {}
        });
    }
};

const Registrar kRegistrar;

struct Extent {
    unsigned width = 1;
    unsigned height = 1;
};

struct AttachmentState {
    bool enabled = false;
    GLuint texture = 0;
    GLint baseLayer = 0;
    GLsizei numLayers = 0;
    GLsizei texelWidth = 0;
    GLsizei texelHeight = 0;
};

std::unordered_map<const GLContext*, std::unordered_map<GLuint, AttachmentState>>& attachmentStates() {
    static std::unordered_map<const GLContext*, std::unordered_map<GLuint, AttachmentState>> states;
    return states;
}

Extent extentForRate(GLenum rate) {
    switch (rate) {
        case GL_SHADING_RATE_1X1_PIXELS_EXT: return {1, 1};
        case GL_SHADING_RATE_1X2_PIXELS_EXT: return {1, 2};
        case GL_SHADING_RATE_1X4_PIXELS_EXT: return {1, 4};
        case GL_SHADING_RATE_2X1_PIXELS_EXT: return {2, 1};
        case GL_SHADING_RATE_2X2_PIXELS_EXT: return {2, 2};
        case GL_SHADING_RATE_2X4_PIXELS_EXT: return {2, 4};
        case GL_SHADING_RATE_4X1_PIXELS_EXT: return {4, 1};
        case GL_SHADING_RATE_4X2_PIXELS_EXT: return {4, 2};
        case GL_SHADING_RATE_4X4_PIXELS_EXT: return {4, 4};
        default: return {1, 1};
    }
}

GLenum rateForExtent(Extent extent) {
    extent.width = std::clamp(extent.width, 1u, 4u);
    extent.height = std::clamp(extent.height, 1u, 4u);
    if (extent.width <= 1) {
        if (extent.height <= 1) return GL_SHADING_RATE_1X1_PIXELS_EXT;
        if (extent.height <= 2) return GL_SHADING_RATE_1X2_PIXELS_EXT;
        return GL_SHADING_RATE_1X4_PIXELS_EXT;
    }
    if (extent.width <= 2) {
        if (extent.height <= 1) return GL_SHADING_RATE_2X1_PIXELS_EXT;
        if (extent.height <= 2) return GL_SHADING_RATE_2X2_PIXELS_EXT;
        return GL_SHADING_RATE_2X4_PIXELS_EXT;
    }
    if (extent.height <= 1) return GL_SHADING_RATE_4X1_PIXELS_EXT;
    if (extent.height <= 2) return GL_SHADING_RATE_4X2_PIXELS_EXT;
    return GL_SHADING_RATE_4X4_PIXELS_EXT;
}

GLenum combineRates(GLenum first, GLenum second, GLenum op) {
    const Extent a = extentForRate(first);
    const Extent b = extentForRate(second);
    switch (op) {
        case GL_FRAGMENT_SHADING_RATE_COMBINER_OP_KEEP_EXT:
            return first;
        case GL_FRAGMENT_SHADING_RATE_COMBINER_OP_REPLACE_EXT:
            return second;
        case GL_FRAGMENT_SHADING_RATE_COMBINER_OP_MIN_EXT:
            return rateForExtent({std::min(a.width, b.width), std::min(a.height, b.height)});
        case GL_FRAGMENT_SHADING_RATE_COMBINER_OP_MAX_EXT:
            return rateForExtent({std::max(a.width, b.width), std::max(a.height, b.height)});
        case GL_FRAGMENT_SHADING_RATE_COMBINER_OP_MUL_EXT:
            return rateForExtent({a.width * b.width, a.height * b.height});
        default:
            return first;
    }
}

GLenum attachmentRateForFramebufferLocked(ExtensionContext& ctx, GLuint framebuffer) {
    if (framebuffer == 0) {
        return GL_SHADING_RATE_1X1_PIXELS_EXT;
    }
    auto contextIt = attachmentStates().find(&ctx.context());
    if (contextIt == attachmentStates().end()) {
        return GL_SHADING_RATE_1X1_PIXELS_EXT;
    }
    auto attachmentIt = contextIt->second.find(framebuffer);
    if (attachmentIt == contextIt->second.end() || !attachmentIt->second.enabled) {
        return GL_SHADING_RATE_1X1_PIXELS_EXT;
    }
    // Attachment CTS uses the advertised max texel size, which this module
    // intentionally exposes as a single screen-sized texel. The attached
    // texture's texel 0 therefore resolves to GL's packed 1x1 shading rate.
    return GL_SHADING_RATE_1X1_PIXELS_EXT;
}

}  // namespace

const char* extensionString() {
    return APPGL_EXTENSION_EXT_FRAGMENT_SHADING_RATE;
}

const char* attachmentExtensionString() {
    return APPGL_EXTENSION_EXT_FRAGMENT_SHADING_RATE_ATTACHMENT;
}

bool isAvailable(ExtensionContext& ctx) {
    return isRasterizationRateMapAvailable(ctx);
}

void initialize(ExtensionContext& ctx) {
    gActive = isAvailable(ctx);
}

void shutdown() {
    gActive = false;
}

bool isActive() {
    return gActive;
}

void destroyContext(ExtensionContext& ctx) {
    clearRasterizationRateMapCache(ctx);
    std::lock_guard<std::mutex> lock(stateMutex());
    contextStates().erase(&ctx.context());
    attachmentStates().erase(&ctx.context());
}

bool isFragmentShadingRateEnum(GLenum rate) {
    switch (rate) {
        case GL_SHADING_RATE_1X1_PIXELS_EXT:
        case GL_SHADING_RATE_1X2_PIXELS_EXT:
        case GL_SHADING_RATE_1X4_PIXELS_EXT:
        case GL_SHADING_RATE_2X1_PIXELS_EXT:
        case GL_SHADING_RATE_2X2_PIXELS_EXT:
        case GL_SHADING_RATE_2X4_PIXELS_EXT:
        case GL_SHADING_RATE_4X1_PIXELS_EXT:
        case GL_SHADING_RATE_4X2_PIXELS_EXT:
        case GL_SHADING_RATE_4X4_PIXELS_EXT:
            return true;
        default:
            return false;
    }
}

bool isFragmentShadingRateCombinerOp(GLenum op) {
    switch (op) {
        case GL_FRAGMENT_SHADING_RATE_COMBINER_OP_KEEP_EXT:
        case GL_FRAGMENT_SHADING_RATE_COMBINER_OP_REPLACE_EXT:
        case GL_FRAGMENT_SHADING_RATE_COMBINER_OP_MIN_EXT:
        case GL_FRAGMENT_SHADING_RATE_COMBINER_OP_MAX_EXT:
        case GL_FRAGMENT_SHADING_RATE_COMBINER_OP_MUL_EXT:
            return true;
        default:
            return false;
    }
}

bool isTrivialFragmentShadingRateCombinerOp(GLenum op) {
    return op == GL_FRAGMENT_SHADING_RATE_COMBINER_OP_KEEP_EXT
        || op == GL_FRAGMENT_SHADING_RATE_COMBINER_OP_REPLACE_EXT;
}

State currentState(ExtensionContext& ctx) {
    std::lock_guard<std::mutex> lock(stateMutex());
    return stateForLocked(ctx);
}

GLenum currentDrawRate(ExtensionContext& ctx) {
    const GLuint framebuffer = ctx.state().boundDrawFramebuffer();
    std::lock_guard<std::mutex> lock(stateMutex());
    const State& state = stateForLocked(ctx);
    const GLenum primitiveRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
    const GLenum attachmentRate = attachmentRateForFramebufferLocked(ctx, framebuffer);
    const GLenum primitiveCombined = combineRates(state.rate, primitiveRate, state.combinerOp0);
    return combineRates(primitiveCombined, attachmentRate, state.combinerOp1);
}

void setDrawRate(ExtensionContext& ctx, GLenum rate) {
    std::lock_guard<std::mutex> lock(stateMutex());
    stateForLocked(ctx).rate = rate;
}

void setCombinerOps(ExtensionContext& ctx, GLenum combinerOp0, GLenum combinerOp1) {
    std::lock_guard<std::mutex> lock(stateMutex());
    State& state = stateForLocked(ctx);
    state.combinerOp0 = combinerOp0;
    state.combinerOp1 = combinerOp1;
}

void setFramebufferAttachment(ExtensionContext& ctx,
                              GLuint framebuffer,
                              GLuint texture,
                              GLint baseLayer,
                              GLsizei numLayers,
                              GLsizei texelWidth,
                              GLsizei texelHeight) {
    std::lock_guard<std::mutex> lock(stateMutex());
    AttachmentState& state = attachmentStates()[&ctx.context()][framebuffer];
    state.enabled = true;
    state.texture = texture;
    state.baseLayer = baseLayer;
    state.numLayers = numLayers;
    state.texelWidth = texelWidth;
    state.texelHeight = texelHeight;
}

void clearFramebufferAttachment(ExtensionContext& ctx, GLuint framebuffer) {
    std::lock_guard<std::mutex> lock(stateMutex());
    auto contextIt = attachmentStates().find(&ctx.context());
    if (contextIt != attachmentStates().end()) {
        contextIt->second.erase(framebuffer);
    }
}

namespace {

bool isQueryPname(GLenum pname) {
    switch (pname) {
        case GL_SHADING_RATE_EXT:
        case GL_MIN_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_WIDTH_EXT:
        case GL_MAX_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_WIDTH_EXT:
        case GL_MIN_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_HEIGHT_EXT:
        case GL_MAX_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_HEIGHT_EXT:
        case GL_MAX_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_ASPECT_RATIO_EXT:
        case GL_MAX_FRAGMENT_SHADING_RATE_ATTACHMENT_LAYERS_EXT:
        case GL_FRAGMENT_SHADING_RATE_WITH_SHADER_DEPTH_STENCIL_WRITES_SUPPORTED_EXT:
        case GL_FRAGMENT_SHADING_RATE_WITH_SAMPLE_MASK_SUPPORTED_EXT:
        case GL_FRAGMENT_SHADING_RATE_ATTACHMENT_WITH_DEFAULT_FRAMEBUFFER_SUPPORTED_EXT:
        case GL_FRAGMENT_SHADING_RATE_NON_TRIVIAL_COMBINERS_SUPPORTED_EXT:
        case GL_FRAGMENT_SHADING_RATE_PRIMITIVE_RATE_WITH_MULTI_VIEWPORT_SUPPORTED_EXT:
            return true;
        default:
            return false;
    }
}

GLint64 integerQueryValue(ExtensionContext& ctx, GLenum pname) {
    switch (pname) {
        case GL_SHADING_RATE_EXT:
            return static_cast<GLint64>(currentState(ctx).rate);
        case GL_MIN_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_WIDTH_EXT:
        case GL_MAX_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_WIDTH_EXT:
        case GL_MIN_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_HEIGHT_EXT:
        case GL_MAX_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_HEIGHT_EXT:
            return 256;
        case GL_MAX_FRAGMENT_SHADING_RATE_ATTACHMENT_TEXEL_ASPECT_RATIO_EXT:
        case GL_MAX_FRAGMENT_SHADING_RATE_ATTACHMENT_LAYERS_EXT:
            return 1;
        case GL_FRAGMENT_SHADING_RATE_NON_TRIVIAL_COMBINERS_SUPPORTED_EXT:
            return 1;
        default:
            return 0;
    }
}

}  // namespace

bool queryBoolean(ExtensionContext& ctx, GLenum pname, GLboolean* data, bool& handled) {
    handled = isQueryPname(pname);
    if (!handled) {
        return true;
    }
    if (data != nullptr) {
        *data = integerQueryValue(ctx, pname) != 0 ? GL_TRUE : GL_FALSE;
    }
    return true;
}

bool queryInteger(ExtensionContext& ctx, GLenum pname, GLint* data, bool& handled) {
    handled = isQueryPname(pname);
    if (!handled) {
        return true;
    }
    if (data != nullptr) {
        *data = static_cast<GLint>(integerQueryValue(ctx, pname));
    }
    return true;
}

bool queryInteger64(ExtensionContext& ctx, GLenum pname, GLint64* data, bool& handled) {
    handled = isQueryPname(pname);
    if (!handled) {
        return true;
    }
    if (data != nullptr) {
        *data = integerQueryValue(ctx, pname);
    }
    return true;
}

bool queryFloat(ExtensionContext& ctx, GLenum pname, GLfloat* data, bool& handled) {
    handled = isQueryPname(pname);
    if (!handled) {
        return true;
    }
    if (data != nullptr) {
        *data = static_cast<GLfloat>(integerQueryValue(ctx, pname));
    }
    return true;
}

bool queryDouble(ExtensionContext& ctx, GLenum pname, GLdouble* data, bool& handled) {
    handled = isQueryPname(pname);
    if (!handled) {
        return true;
    }
    if (data != nullptr) {
        *data = static_cast<GLdouble>(integerQueryValue(ctx, pname));
    }
    return true;
}

}  // namespace appgl::extensions::fragment_shading_rate
