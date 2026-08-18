#include "ExtensionAdvertising.h"

namespace appgl::extensions {
namespace {

ExtensionAdvertisingState resolveAdvertisingFlag(const char* extensionName,
                                                  const char* canonicalFlagName,
                                                  const char* environmentVariable,
                                                  bool buildDefault = false) {
    return {
        extensionName,
        canonicalFlagName,
        environmentVariable,
        feature_flags::resolveBooleanFlag(
            canonicalFlagName,
            {},
            {environmentVariable},
            buildDefault),
    };
}

}  // namespace

const ExtensionAdvertisingSnapshot& extensionAdvertisingSnapshot() {
    static const ExtensionAdvertisingSnapshot snapshot = {{
        resolveAdvertisingFlag(
            "GL_ARB_viewport_array",
            "advertise-arb-viewport-array",
            "APPGL_ADVERTISE_ARB_VIEWPORT_ARRAY"),
        resolveAdvertisingFlag(
            "GL_ARB_blend_func_extended",
            "advertise-arb-blend-func-extended",
            "APPGL_ADVERTISE_ARB_BLEND_FUNC_EXTENDED"),
        resolveAdvertisingFlag(
            "GL_ARB_clear_texture",
            "advertise-arb-clear-texture",
            "APPGL_ADVERTISE_ARB_CLEAR_TEXTURE"),
        resolveAdvertisingFlag(
            "GL_ARB_sync",
            "advertise-arb-sync",
            "APPGL_ADVERTISE_ARB_SYNC"),
        resolveAdvertisingFlag(
            "GL_ARB_texture_multisample",
            "advertise-arb-texture-multisample",
            "APPGL_ADVERTISE_ARB_TEXTURE_MULTISAMPLE"),
        resolveAdvertisingFlag(
            "GL_ARB_texture_rectangle",
            "advertise-arb-texture-rectangle",
            "APPGL_ADVERTISE_ARB_TEXTURE_RECTANGLE"),
        resolveAdvertisingFlag(
            "GL_ARB_framebuffer_sRGB",
            "advertise-arb-framebuffer-srgb",
            "APPGL_ADVERTISE_ARB_FRAMEBUFFER_SRGB"),
        resolveAdvertisingFlag(
            "GL_EXT_texture_array",
            "advertise-ext-texture-array",
            "APPGL_ADVERTISE_EXT_TEXTURE_ARRAY"),
        resolveAdvertisingFlag(
            "GL_ARB_copy_image",
            "advertise-arb-copy-image",
            "APPGL_ADVERTISE_ARB_COPY_IMAGE"),
        resolveAdvertisingFlag(
            "GL_ARB_texture_rg",
            "advertise-arb-texture-rg",
            "APPGL_ADVERTISE_ARB_TEXTURE_RG"),
        resolveAdvertisingFlag(
            "GL_ARB_direct_state_access",
            "advertise-arb-direct-state-access",
            "APPGL_ADVERTISE_ARB_DIRECT_STATE_ACCESS"),
        // Default TRUE: GL_EXT_direct_state_access used to live in
        // kBaseExtensions unconditionally. Moving it here keeps the default
        // advertisement byte-identical while making de-advertisement
        // measurable from a launch flag.
        resolveAdvertisingFlag(
            "GL_EXT_direct_state_access",
            "advertise-ext-direct-state-access",
            "APPGL_ADVERTISE_EXT_DIRECT_STATE_ACCESS",
            true),
    }};
    return snapshot;
}

}  // namespace appgl::extensions
