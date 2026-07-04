#pragma once

#include "AppGLEnv.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>

namespace appgl {

constexpr int kAppGLCoreProfileBit = 0x00000001;
constexpr int kAppGLCompatibilityProfileBit = 0x00000002;

enum class AppGLCompatAdmissionMode {
    Off,
    Scoped,
    CompatVersion,
    Full,
    LegacyAlias,
};

enum class AppGLCompatSemanticTier {
    Core,
    BroadLegacy,
};

enum class AppGLCompatExtensionTier {
    Core,
    Admission,
    BroadLegacy,
};

enum class AppGLCompatRequestProfile {
    Unknown,
    Core,
    Compatibility,
};

enum class AppGLCompatFeature {
    LegacyTextureFormats,
    VaoZeroDraw,
    TextureZeroQueries,
    ClientArrays,
    ImmediateMode,
    AlphaTest,
    BitmapDrawPixels,
    GlslBuiltins,
    GpuShader4,
    PixelTransfer,
    DisplayLists,
};

struct CompatPolicy {
    AppGLCompatAdmissionMode admissionMode = AppGLCompatAdmissionMode::Off;
    AppGLCompatSemanticTier semanticTier = AppGLCompatSemanticTier::Core;
    AppGLCompatExtensionTier extensionTier = AppGLCompatExtensionTier::Core;
    int advertisedMajor = 4;
    int advertisedMinor = 6;
    int advertisedProfileMask = kAppGLCoreProfileBit;
    bool advertiseCompatProfile = false;
    bool advertiseArbCompatibility = false;
    bool advertiseGpuShader4 = false;
    AppGLCompatRequestProfile requestProfile = AppGLCompatRequestProfile::Unknown;
    std::string requestedSource = "default-off";
    std::string claimedVersionString = "4.6 AppGL core";
};

inline bool appglCompatLegacyAliasEnabled(const char* value) {
    return value != nullptr && value[0] != '0' && value[0] != '\0';
}

inline bool appglParseCompatVersion(const char* value, int& major, int& minor) {
    if (value == nullptr || value[0] == '\0') {
        return false;
    }
    char* afterMajor = nullptr;
    const long parsedMajor = std::strtol(value, &afterMajor, 10);
    if (afterMajor == value || afterMajor == nullptr || *afterMajor != '.') {
        return false;
    }
    char* afterMinor = nullptr;
    const long parsedMinor = std::strtol(afterMajor + 1, &afterMinor, 10);
    if (afterMinor == afterMajor + 1 || afterMinor == nullptr || *afterMinor != '\0') {
        return false;
    }
    if (parsedMajor < 1 || parsedMajor > 4 || parsedMinor < 0 || parsedMinor > 9) {
        return false;
    }
    if (parsedMajor == 4 && parsedMinor > 6) {
        return false;
    }
    major = static_cast<int>(parsedMajor);
    minor = static_cast<int>(parsedMinor);
    return true;
}

inline AppGLCompatRequestProfile appglParseCompatRequestProfile(const char* value) {
    if (value == nullptr || value[0] == '\0') {
        return AppGLCompatRequestProfile::Unknown;
    }
    if (std::strcmp(value, "core") == 0 ||
        std::strcmp(value, "core-profile") == 0 ||
        std::strcmp(value, "GLUT_CORE_PROFILE") == 0 ||
        std::strcmp(value, "GLUT_3_2_CORE_PROFILE") == 0) {
        return AppGLCompatRequestProfile::Core;
    }
    if (std::strcmp(value, "compat") == 0 ||
        std::strcmp(value, "compatibility") == 0 ||
        std::strcmp(value, "compatibility-profile") == 0 ||
        std::strcmp(value, "GLUT_COMPATIBILITY_PROFILE") == 0) {
        return AppGLCompatRequestProfile::Compatibility;
    }
    return AppGLCompatRequestProfile::Unknown;
}

inline std::string appglBuildClaimedVersionString(int major, int minor, bool compat) {
    char buffer[48];
    std::snprintf(buffer,
                  sizeof(buffer),
                  "%d.%d AppGL %s",
                  major,
                  minor,
                  compat ? "compatibility" : "core");
    return std::string(buffer);
}

inline void appglApplyCompatAdmission(CompatPolicy& policy,
                                      AppGLCompatAdmissionMode mode,
                                      int major,
                                      int minor,
                                      std::string source) {
    policy.admissionMode = mode;
    policy.extensionTier = AppGLCompatExtensionTier::Admission;
    policy.advertisedMajor = major;
    policy.advertisedMinor = minor;
    policy.advertisedProfileMask = kAppGLCompatibilityProfileBit;
    policy.advertiseCompatProfile = true;
    policy.advertiseArbCompatibility = true;
    policy.semanticTier = AppGLCompatSemanticTier::BroadLegacy;
    policy.extensionTier = AppGLCompatExtensionTier::BroadLegacy;
    policy.advertiseGpuShader4 = true;
    policy.requestedSource = std::move(source);
    policy.claimedVersionString = appglBuildClaimedVersionString(major, minor, true);
}

inline void appglApplyBroadLegacyCompat(CompatPolicy& policy,
                                        AppGLCompatAdmissionMode mode,
                                        std::string source) {
    appglApplyCompatAdmission(policy, mode, 4, 6, std::move(source));
}

inline CompatPolicy appglCompatPolicyFromEnv(const char* compatProfile,
                                             const char* compatAdmission,
                                             const char* compatVersion = nullptr,
                                             const char* compatRequestProfile = nullptr) {
    CompatPolicy policy;
    policy.requestProfile = appglParseCompatRequestProfile(compatRequestProfile);
    if (appglCompatLegacyAliasEnabled(compatProfile)) {
        appglApplyBroadLegacyCompat(policy,
                                    AppGLCompatAdmissionMode::LegacyAlias,
                                    "APPGL_COMPAT_PROFILE");
        policy.requestProfile = appglParseCompatRequestProfile(compatRequestProfile);
        return policy;
    }

    if (compatAdmission == nullptr ||
        compatAdmission[0] == '\0' ||
        std::strcmp(compatAdmission, "0") == 0 ||
        std::strcmp(compatAdmission, "off") == 0) {
        return policy;
    }

    if (policy.requestProfile == AppGLCompatRequestProfile::Core) {
        policy.requestedSource = "APPGL_COMPAT_REQUEST_PROFILE=core";
        return policy;
    }

    int overrideMajor = 4;
    int overrideMinor = 6;
    const bool hasVersionOverride =
        appglParseCompatVersion(compatVersion, overrideMajor, overrideMinor);

    if (std::strcmp(compatAdmission, "scoped") == 0 ||
        std::strncmp(compatAdmission, "scoped-", 7) == 0) {
        appglApplyCompatAdmission(policy,
                                  AppGLCompatAdmissionMode::Scoped,
                                  hasVersionOverride ? overrideMajor : 4,
                                  hasVersionOverride ? overrideMinor : 6,
                                  "APPGL_COMPAT_ADMISSION=scoped");
        return policy;
    }

    if (std::strncmp(compatAdmission, "compat-", 7) == 0) {
        int major = 4;
        int minor = 6;
        if (!appglParseCompatVersion(compatAdmission + 7, major, minor)) {
            return policy;
        }
        appglApplyCompatAdmission(policy,
                                  AppGLCompatAdmissionMode::CompatVersion,
                                  major,
                                  minor,
                                  std::string("APPGL_COMPAT_ADMISSION=") + compatAdmission);
        return policy;
    }

    if (std::strcmp(compatAdmission, "full") == 0) {
        appglApplyBroadLegacyCompat(policy,
                                    AppGLCompatAdmissionMode::Full,
                                    "APPGL_COMPAT_ADMISSION=full");
        if (hasVersionOverride) {
            policy.advertisedMajor = overrideMajor;
            policy.advertisedMinor = overrideMinor;
            policy.claimedVersionString =
                appglBuildClaimedVersionString(overrideMajor, overrideMinor, true);
        }
    }
    return policy;
}

inline const CompatPolicy& appglCurrentCompatPolicy() {
    static const CompatPolicy policy = appglCompatPolicyFromEnv(
        std::getenv("APPGL_COMPAT_PROFILE"),
        std::getenv("APPGL_COMPAT_ADMISSION"),
        std::getenv("APPGL_COMPAT_VERSION"),
        std::getenv("APPGL_COMPAT_REQUEST_PROFILE"));
    return policy;
}

inline bool appglAdvertiseCompatProfile(const CompatPolicy& policy) {
    return policy.advertiseCompatProfile;
}

inline bool appglAdvertiseCompatProfile() {
    return appglAdvertiseCompatProfile(appglCurrentCompatPolicy());
}

inline bool appglCompatProfileEnabled(const CompatPolicy& policy) {
    return policy.semanticTier == AppGLCompatSemanticTier::BroadLegacy;
}

inline bool appglCompatProfileEnabled() {
    return appglCompatProfileEnabled(appglCurrentCompatPolicy());
}

inline bool appglCompatVersionAtLeast(const CompatPolicy& policy, int major, int minor) {
    if (!policy.advertiseCompatProfile) {
        return false;
    }
    return policy.advertisedMajor > major ||
        (policy.advertisedMajor == major && policy.advertisedMinor >= minor);
}

inline bool appglCompatVersionAtLeast(int major, int minor) {
    return appglCompatVersionAtLeast(appglCurrentCompatPolicy(), major, minor);
}

inline bool appglCompatFeatureEnabled(const CompatPolicy& policy,
                                      AppGLCompatFeature feature) {
    if (feature == AppGLCompatFeature::GpuShader4) {
        return policy.advertiseGpuShader4;
    }
    return policy.semanticTier == AppGLCompatSemanticTier::BroadLegacy;
}

inline bool appglCompatFeatureEnabled(AppGLCompatFeature feature) {
    return appglCompatFeatureEnabled(appglCurrentCompatPolicy(), feature);
}

inline const char* appglClaimedVersionString(const CompatPolicy& policy) {
    return policy.claimedVersionString.c_str();
}

inline const char* appglClaimedVersionString() {
    return appglClaimedVersionString(appglCurrentCompatPolicy());
}

inline int appglContextProfileMask(const CompatPolicy& policy) {
    return policy.advertisedProfileMask;
}

inline int appglContextProfileMask() {
    return appglContextProfileMask(appglCurrentCompatPolicy());
}

}  // namespace appgl
