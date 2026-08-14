#pragma once

#include "../runtime/AppGLFeatureFlags.h"

#include <array>
#include <cstddef>

namespace appgl::extensions {

inline constexpr std::size_t kExtensionAdvertisingFlagCount = 10;

struct ExtensionAdvertisingState {
    const char* extensionName = nullptr;
    const char* canonicalFlagName = nullptr;
    const char* environmentVariable = nullptr;
    feature_flags::BooleanFlagResolution resolution;
};

using ExtensionAdvertisingSnapshot =
    std::array<ExtensionAdvertisingState, kExtensionAdvertisingFlagCount>;

// Resolve the launch-time advertising controls once per process. The snapshot
// is also the audit surface used by the focused probe and conformance preflight.
const ExtensionAdvertisingSnapshot& extensionAdvertisingSnapshot();

}  // namespace appgl::extensions
