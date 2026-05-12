#include "Fp64Translation.h"

#include <cmath>
#include <cstring>

namespace appgl::extensions::fp64 {
namespace {

std::uint32_t bitsFromFloat(float value) {
    std::uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

float floatFromBits(std::uint32_t bits) {
    float value = 0.0f;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

std::uint64_t bitsFromDouble(double value) {
    std::uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

}  // namespace

TranslationHelperInfo translationHelperInfo() {
    return {};
}

Df64TransportWords encodeDoubleToDf64Transport(double value) {
    const float hi = static_cast<float>(value);
    float lo = 0.0f;
    if (std::isfinite(value) && std::isfinite(hi)) {
        lo = static_cast<float>(value - static_cast<double>(hi));
    }
    return {bitsFromFloat(hi), bitsFromFloat(lo)};
}

double decodeDf64TransportToDouble(Df64TransportWords words) {
    const float hi = floatFromBits(words.hi);
    const float lo = floatFromBits(words.lo);
    return static_cast<double>(hi) + static_cast<double>(lo);
}

bool df64TransportRoundTripMatches(double value) {
    const Df64TransportWords words = encodeDoubleToDf64Transport(value);
    const double decoded = decodeDf64TransportToDouble(words);
    if (std::isnan(value) && std::isnan(decoded)) {
        return true;
    }
    return bitsFromDouble(decoded) == bitsFromDouble(value);
}

void encodeDoublesToDf64Transport(const double* values,
                                  std::size_t count,
                                  Df64TransportWords* outWords) {
    if (values == nullptr || outWords == nullptr) {
        return;
    }
    for (std::size_t i = 0; i < count; ++i) {
        outWords[i] = encodeDoubleToDf64Transport(values[i]);
    }
}

const char* mslHelperSource() {
    return R"MSL(
struct appgl_df64 {
    uint2 words;
};

inline appgl_df64 appgl_df64_from_words(uint lo, uint hi)
{
    appgl_df64 value;
    value.words = uint2(lo, hi);
    return value;
}

inline uint2 appgl_df64_words(appgl_df64 value)
{
    return value.words;
}

inline appgl_df64 appgl_df64_from_dd(float2 value)
{
    appgl_df64 packed;
    packed.words = as_type<uint2>(value);
    return packed;
}

inline float2 appgl_df64_to_dd(appgl_df64 value)
{
    return as_type<float2>(value.words);
}

inline float2 appgl_dd_quick_two_sum(float a, float b)
{
    const float s = a + b;
    const float e = b - (s - a);
    return float2(s, e);
}

inline float2 appgl_dd_two_sum(float a, float b)
{
    const float s = a + b;
    const float bb = s - a;
    const float e = (a - (s - bb)) + (b - bb);
    return float2(s, e);
}

inline float2 appgl_dd_two_prod(float a, float b)
{
    const float p = a * b;
    const float e = fma(a, b, -p);
    return float2(p, e);
}

inline float2 appgl_dd_add(float2 a, float2 b)
{
    const float2 s = appgl_dd_two_sum(a.x, b.x);
    const float e = s.y + a.y + b.y;
    return appgl_dd_quick_two_sum(s.x, e);
}

inline float2 appgl_dd_mul(float2 a, float2 b)
{
    const float2 p = appgl_dd_two_prod(a.x, b.x);
    const float e = p.y + (a.x * b.y) + (a.y * b.x);
    return appgl_dd_quick_two_sum(p.x, e);
}
)MSL";
}

const char* mslProbeSource() {
    return R"MSL(
#include <metal_stdlib>
using namespace metal;

struct appgl_df64 {
    uint2 words;
};

inline appgl_df64 appgl_df64_from_words(uint lo, uint hi)
{
    appgl_df64 value;
    value.words = uint2(lo, hi);
    return value;
}

inline appgl_df64 appgl_df64_from_dd(float2 value)
{
    appgl_df64 packed;
    packed.words = as_type<uint2>(value);
    return packed;
}

inline float2 appgl_dd_quick_two_sum(float a, float b)
{
    const float s = a + b;
    const float e = b - (s - a);
    return float2(s, e);
}

inline float2 appgl_dd_two_sum(float a, float b)
{
    const float s = a + b;
    const float bb = s - a;
    const float e = (a - (s - bb)) + (b - bb);
    return float2(s, e);
}

inline float2 appgl_dd_two_prod(float a, float b)
{
    const float p = a * b;
    const float e = fma(a, b, -p);
    return float2(p, e);
}

inline float2 appgl_dd_add(float2 a, float2 b)
{
    const float2 s = appgl_dd_two_sum(a.x, b.x);
    const float e = s.y + a.y + b.y;
    return appgl_dd_quick_two_sum(s.x, e);
}

inline float2 appgl_dd_mul(float2 a, float2 b)
{
    const float2 p = appgl_dd_two_prod(a.x, b.x);
    const float e = p.y + (a.x * b.y) + (a.y * b.x);
    return appgl_dd_quick_two_sum(p.x, e);
}

kernel void appgl_fp64_phase1_probe(device uint2* out [[buffer(0)]])
{
    const appgl_df64 transported = appgl_df64_from_words(0x3f800000u, 0u);
    const float2 a = float2(as_type<float>(transported.words.x), 0.125f);
    const float2 b = float2(2.0f, 0.25f);
    out[0] = appgl_df64_from_dd(appgl_dd_add(a, b)).words;
    out[1] = appgl_df64_from_dd(appgl_dd_mul(a, b)).words;
}
)MSL";
}

}  // namespace appgl::extensions::fp64
