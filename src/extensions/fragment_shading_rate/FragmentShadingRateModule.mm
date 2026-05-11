#include "FragmentShadingRateModule.h"
#include "RasterizationRateMap.h"

#include "../ExtensionContext.h"
#include "../ExtensionRegistry.h"
#include "../../../include/AppGL/extensions/fragment_shading_rate.h"

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
    }
};

const Registrar kRegistrar;

}  // namespace

const char* extensionString() {
    return APPGL_EXTENSION_EXT_FRAGMENT_SHADING_RATE;
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
    return currentState(ctx).rate;
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

namespace {

bool isQueryPname(GLenum pname) {
    switch (pname) {
        case GL_SHADING_RATE_EXT:
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
    return pname == GL_SHADING_RATE_EXT ? static_cast<GLint64>(currentDrawRate(ctx)) : 0;
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
