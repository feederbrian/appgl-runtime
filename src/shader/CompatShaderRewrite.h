#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace appgl {

// Compat-profile shader rewriter. Sits between `glShaderSource` and
// glslang. Glslang's SPIR-V backend hard-rejects `#version NNN
// compatibility`; it also rejects every `gl_*` fixed-function identifier
// (`gl_ModelViewMatrix`, `gl_NormalMatrix`, ...). BAR's shader corpus
// includes 100+ shaders that begin with `#version 150 compatibility` and
// reference the matrix family in the vertex stage.
//
// This pass does the minimum mechanical translation needed to get those
// shaders past glslang:
//
//   1. `#version NNN compatibility` is rewritten to `#version NNN core`
//      in-place (no line-number shift; same physical line).
//
//   2. For every recognized fixed-function matrix identifier referenced
//      by the original source, a synthesized `appgl_*` uniform is
//      prepended to the source after the `#version` line, paired with
//      a `#define gl_X appgl_X` so the user's references resolve
//      cleanly through the preprocessor:
//
//          uniform mat4 appgl_ModelViewProjectionMatrix;
//          #define gl_ModelViewProjectionMatrix appgl_ModelViewProjectionMatrix
//
//      The synthesized uniforms then get picked up by AppGL's existing
//      reflection scanner just like any other user-declared uniform.
//      They land in `programObject->uniforms` at link time and the
//      draw-time uniform push reads `appgl_*` values from the per-context
//      MatrixStateMirror.
//
//   3. After the preamble, a `#line 2` directive is injected so glslang
//      reports compile errors against the original source line numbers
//      rather than the post-rewrite line numbers. (`#version` stays on
//      its original line, so error messages on line 1 still point to
//      the right place.)
//
// Identifiers NOT covered by this initial landing (gl_Vertex, gl_Color,
// gl_Normal, gl_FragColor, gl_FrontColor, gl_TexCoord, gl_LightSource,
// gl_Fog, gl_ClipVertex, ...) are deferred to a follow-up landing once
// BAR's in-game render path needs them. The Phase 8X target shader
// (BAR's `Icons2DVS.glsl` / `IconsFS.glsl` combo for the select menu)
// only references `gl_ModelViewProjectionMatrix`, so the matrix family
// alone is enough to unblock the smoke test.

struct SynthesizedMatrixUsage {
    bool modelView = false;
    bool projection = false;
    bool modelViewProjection = false;
    bool modelViewInverse = false;
    bool projectionInverse = false;
    bool modelViewProjectionInverse = false;
    bool normal = false;
    bool texture = false;  // gl_TextureMatrix[i] -> appgl_TextureMatrix[i]

    bool any() const {
        return modelView || projection || modelViewProjection ||
               modelViewInverse || projectionInverse || modelViewProjectionInverse ||
               normal || texture;
    }
};

struct CompatShaderRewriteResult {
    // Rewritten source. If no rewrite was applied, equals the original.
    std::string source;
    // Which `appgl_*` uniforms got synthesized into the rewritten source.
    SynthesizedMatrixUsage usage;
    // True iff the original source carried `#version NNN compatibility`.
    bool wasCompatProfile = false;
    // True iff any rewrite was applied (version downgrade, preamble
    // injection, or both). When false, `source` matches the original
    // byte-for-byte and the caller can skip the rewrite-aware path.
    bool didRewrite = false;
};

// Names of the synthesized uniforms. Hand-coded constexpr strings so the
// link-time path can match by name without having to know the rewriter's
// internal table. Kept in a namespace so callers don't accidentally pull
// the names into the global ns via a `using` directive.
namespace SynthesizedUniformNames {
inline constexpr const char* kModelViewMatrix =
    "appgl_ModelViewMatrix";
inline constexpr const char* kProjectionMatrix =
    "appgl_ProjectionMatrix";
inline constexpr const char* kModelViewProjectionMatrix =
    "appgl_ModelViewProjectionMatrix";
inline constexpr const char* kModelViewMatrixInverse =
    "appgl_ModelViewMatrixInverse";
inline constexpr const char* kProjectionMatrixInverse =
    "appgl_ProjectionMatrixInverse";
inline constexpr const char* kModelViewProjectionMatrixInverse =
    "appgl_ModelViewProjectionMatrixInverse";
inline constexpr const char* kNormalMatrix =
    "appgl_NormalMatrix";
inline constexpr const char* kTextureMatrix =
    "appgl_TextureMatrix";  // mat4[8] array
}  // namespace SynthesizedUniformNames

// Length of the synthesized texture matrix array. Matches
// MatrixStateMirror::kMaxTextureUnits.
inline constexpr unsigned int kSynthesizedTextureMatrixCount = 8;

// Apply the compat-shader rewrite. Returns the rewritten source plus a
// usage descriptor that the link-time path uses to cache uniform
// locations on the program object. Safe to call on any GLSL source —
// non-compat shaders that don't reference any fixed-function matrix
// identifier come back unchanged with `didRewrite == false`.
CompatShaderRewriteResult rewriteCompatShader(std::string_view source);

}  // namespace appgl
