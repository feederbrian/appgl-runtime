#pragma once

namespace appgl::extensions::fp64 {

enum class HelperSubstrate {
    HandPortedInlineDoubleDouble,
};

struct TranslationHelperInfo {
    HelperSubstrate substrate = HelperSubstrate::HandPortedInlineDoubleDouble;
    bool vendorsThirdPartyCode = false;
    bool emitsMslDouble = false;
};

TranslationHelperInfo translationHelperInfo();
const char* mslHelperSource();
const char* mslProbeSource();

}  // namespace appgl::extensions::fp64
