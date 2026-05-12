#include "Fp64Translation.h"

namespace appgl::extensions::fp64 {

TranslationHelperInfo translationHelperInfo() {
    return {};
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
