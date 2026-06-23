#pragma once

#include "AppGLEnv.h"

namespace appgl {

inline bool appglCompatProfileEnabled() {
    return appglEnvEnabledDefaultOff("APPGL_COMPAT_PROFILE");
}

inline const char* appglClaimedVersionString() {
    return appglCompatProfileEnabled()
        ? "4.6 AppGL compatibility"
        : "4.6 AppGL core";
}

inline int appglContextProfileMask() {
    return appglCompatProfileEnabled()
        ? 0x00000002  // GL_CONTEXT_COMPATIBILITY_PROFILE_BIT
        : 0x00000001; // GL_CONTEXT_CORE_PROFILE_BIT
}

}  // namespace appgl
