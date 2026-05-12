#pragma once

#include <cstddef>
#include <cstdint>

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

struct Df64TransportWords {
    // Matches appgl_df64_from_dd(float2(hi, lo)) in the MSL helper:
    // uint2.x carries the high float bits and uint2.y carries the residual.
    std::uint32_t hi = 0;
    std::uint32_t lo = 0;
};

Df64TransportWords encodeDoubleToDf64Transport(double value);
double decodeDf64TransportToDouble(Df64TransportWords words);
bool df64TransportRoundTripMatches(double value);
void encodeDoublesToDf64Transport(const double* values,
                                  std::size_t count,
                                  Df64TransportWords* outWords);

}  // namespace appgl::extensions::fp64
