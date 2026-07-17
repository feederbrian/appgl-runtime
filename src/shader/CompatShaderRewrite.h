#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <string_view>

// GLenum is a plain uint32_t. Forward-declare rather than pulling in
// <AppGL/AppGL.h> so callers that don't already include it still compile.
typedef unsigned int GLenum;

namespace appgl {

// Compat-profile shader rewriter. Sits between `glShaderSource` and
// glslang. Glslang's SPIR-V backend hard-rejects `#version NNN
// compatibility`; it also rejects every `gl_*` fixed-function identifier
// (`gl_ModelViewMatrix`, `gl_NormalMatrix`, ...). BAR's shader corpus
// includes 100+ shaders that begin with `#version 150 compatibility` and
// reference the matrix family in the vertex stage. It ALSO includes
// `#version 120` / `#version 130` legacy desktop shaders (Spring's sky
// and deferred-model drawers) that reject at the glslang Vulkan client
// front-end with `Desktop shaders for Vulkan SPIR-V require version 140
// or higher`, and once that floor is lifted, need a much deeper set of
// identifier rewrites to satisfy the core-profile surface.
//
// This pass does the mechanical translation needed to get those shaders
// past glslang:
//
//   1. `#version NNN compatibility` is rewritten to `#version NNN core`
//      in-place (no line-number shift; same physical line).
//
//   2. `#version 100/110/120/130` is rewritten to `#version 330 core`
//      (Phase 8X Group 4d follow-up¹⁹). 330 core mates cleanly with the
//      `layout(location=N)` attribute / frag-output declarations the
//      rewriter emits for the pre-core attribute names, and unlocks the
//      modern `texture()` / `textureProj()` overloads that we rewrite
//      `texture2D` / `textureCube` to. `shadow2DProj` is routed through
//      a synthesized `appgl_shadow2DProj` wrapper instead (fw²¹) —
//      see the `rewroteShadow2DProj` flag comment for why a flat
//      rename is semantically wrong.
//
//   3. For every recognized fixed-function matrix identifier referenced
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
//   4. Phase 8X Group 4d follow-up¹⁹ — the legacy-attribute/varying/
//      frag-output/fog/light/sampler/clip-vertex family is handled via a
//      mix of preamble injection and in-place source-text token
//      rewriting. The signature was extended with a `GLenum stage`
//      argument because `varying` and `gl_TexCoord[]` have stage-
//      dependent behaviour (VS-side `varying` → `out`, FS-side `varying`
//      → `in`; VS-side `gl_TexCoord[8]` becomes an `out` array, FS-side
//      an `in` array). The stage argument is the GL_*_SHADER enum
//      (GL_VERTEX_SHADER / GL_FRAGMENT_SHADER / ...). Non-raster stages
//      are accepted and routed through the stage-independent rewrites
//      only.
//
//   5. After the preamble, a `#line 2` directive is injected so glslang
//      reports compile errors against the original source line numbers
//      rather than the post-rewrite line numbers. (`#version` stays on
//      its original line, so error messages on line 1 still point to
//      the right place.)

// Tracks which synthesized matrix uniforms got generated. Caller uses
// this to cache uniform locations on the program object so draw-time
// matrix push doesn't have to rescan the uniform table.
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

// Phase 8X Group 4d follow-up¹⁹ — legacy compat-profile feature usage,
// separate from the matrix family so downstream callers that only care
// about the matrix bind-path don't need to pattern-match 30 extra flags.
// All flags default to `false`; the rewriter sets them when the
// corresponding identifier is discovered in the original source.
struct LegacyCompatUsage {
    // Version-line rewrite kicked in for a pre-140 desktop version
    // (`#version 100/110/120/130`). Not set for `150 compatibility` —
    // that's the older, narrower rewrite covered by `wasCompatProfile`.
    bool upgradedVersion = false;
    // `varying` keyword appeared and was rewritten to `in`/`out`. The
    // exact in/out direction depends on the stage passed to the rewriter.
    bool hadVarying = false;
    // Stage-affecting attribute rewrites (vertex stage only).
    bool attrVertex = false;           // gl_Vertex -> layout(loc=0) in vec4 appgl_Vertex
    bool attrNormal = false;           // gl_Normal -> layout(loc=2) in vec3 appgl_Normal
    bool attrColor = false;            // gl_Color -> layout(loc=3) in vec4 appgl_Color
    std::array<bool, 8> attrMultiTexCoord = {};  // gl_MultiTexCoord[0..7] -> layout(loc=8+N)
    // Legacy vertex builtin. Lowered only for a callable `ftransform()`
    // in a legacy/compat source; plain identifiers in core GLSL are left
    // untouched. The lowering also forces attrVertex and the synthesized
    // model-view-projection matrix uniform.
    bool usesFtransform = false;
    // Frag-output rewrites (fragment stage only).
    bool fragColor = false;            // gl_FragColor -> layout(loc=0) out vec4 appgl_FragColor
    // Highest `gl_FragData[N]` index seen. -1 means `gl_FragData` was
    // not used. Ns of 0..7 emit an 8-slot array at location 0.
    int fragDataMax = -1;
    // gl_TexCoord[N] stage-bridged varying. The rewriter records the
    // highest N seen across stages; the preamble emits a matched
    // `appgl_TexCoord[max+1]` array on the VS `out` side and the FS
    // `in` side.
    int texCoordMax = -1;
    // gl_Fog.* field accesses. Each sub-field records whether the
    // corresponding flat uniform (`appgl_FogColor`, ...) should be
    // synthesized and mirrored from draw-time fixed-function state.
    bool usesFogColor = false;
    bool usesFogDensity = false;
    bool usesFogStart = false;
    bool usesFogEnd = false;
    bool usesFogScale = false;
    // gl_FogFragCoord stage-bridged varying. In geometry shaders the
    // input spelling is `gl_in[i].gl_FogFragCoord`, so track that
    // separately from plain read/write use.
    bool usesFogFragCoord = false;
    bool usesFogFragCoordInput = false;
    // Legacy color bridges. Vertex shaders may expose the front/back
    // primary and secondary colors independently; keep each output distinct
    // so transform feedback can capture the original compatibility names.
    bool usesFrontColor = false;
    bool usesBackColor = false;
    bool usesFrontSecondaryColor = false;
    bool usesBackSecondaryColor = false;
    // Fragment shaders read gl_Color as the interpolated front color.
    bool usesFragmentColor = false;
    // gl_TextureEnvColor[N] fixed-function texture environment color.
    // Runtime state is mirrored into appgl_TextureEnvColor[] at draw time.
    bool usesTextureEnvColor = false;
    // gl_LightModel.ambient fixed-function lighting model ambient color.
    bool usesLightModelAmbient = false;
    // gl_LightSource[*].* field accesses (unioned across all observed
    // subscripts). The preamble emits array uniforms for every used
    // field, sized to `kSynthesizedLightSourceCount`. Defaults are
    // NOT seeded via the initializer path (GLSL scalar/vector default-
    // initializer syntax doesn't cover arrays in the fw¹⁵ scanner), so
    // the uniforms come up as zero and produce unlit-black geometry.
    // This is a known deviation from GL 1.x default state (light 0 has
    // a white directional source) and is the first candidate to extend
    // in a follow-up round if BAR's model rendering comes up dark after
    // fw¹⁹ lands.
    bool usesLightAmbient = false;
    bool usesLightDiffuse = false;
    bool usesLightSpecular = false;
    bool usesLightPosition = false;
    bool usesLightHalfVector = false;
    bool usesLightSpotDirection = false;
    bool usesLightSpotExponent = false;
    bool usesLightSpotCutoff = false;
    bool usesLightSpotCosCutoff = false;
    bool usesLightConstantAttenuation = false;
    bool usesLightLinearAttenuation = false;
    bool usesLightQuadraticAttenuation = false;
    bool anyLight() const {
        return usesLightAmbient || usesLightDiffuse || usesLightSpecular ||
               usesLightPosition || usesLightHalfVector ||
               usesLightSpotDirection || usesLightSpotExponent ||
               usesLightSpotCutoff || usesLightSpotCosCutoff ||
               usesLightConstantAttenuation || usesLightLinearAttenuation ||
               usesLightQuadraticAttenuation;
    }
    // `gl_ClipVertex` appeared in VS. Rewritten to an `out`/`in` bridge
    // so the cross-stage interface stays balanced and glslang stops
    // rejecting the reference.
    bool usesClipVertex = false;
    // GLSL 1.30 compatibility vertex shader with no explicit legacy clip
    // output. The rewriter wraps main() and emits gl_ClipDistance[] from
    // gl_Position so enabled glClipPlane state reaches Metal clipping.
    bool synthesizesLegacyClipPlanes = false;
    // `texture2D(...)` call was rewritten to `texture(...)`.
    bool rewroteTexture2D = false;
    // `textureCube(...)` call was rewritten to `texture(...)`.
    bool rewroteTextureCube = false;
    // `shadow2DProj(...)` call was rewritten. fw¹⁹ flat-renamed to
    // core `textureProj(...)`, but that silently broke the return-
    // type contract on `sampler2DShadow` — legacy `shadow2DProj`
    // returns `vec4`, core `textureProj` returns `float`, and BAR's
    // `ModelFragProg.glsl` chains `.r` on the result which then
    // fails glslang's "scalar swizzle" check. fw²¹ retargets the
    // rename to `appgl_shadow2DProj(...)`, a preamble-synthesized
    // wrapper that keeps the legacy `vec4` return type. See
    // `rewriteCompatShader` section 5h.
    bool rewroteShadow2DProj = false;

    bool anyAttribute() const {
        if (attrVertex || attrNormal || attrColor) return true;
        for (bool used : attrMultiTexCoord) {
            if (used) return true;
        }
        return false;
    }
    bool any() const {
        return upgradedVersion || hadVarying || anyAttribute() ||
               fragColor || fragDataMax >= 0 || texCoordMax >= 0 ||
               usesFogColor || usesFogDensity || usesFogStart ||
               usesFogEnd || usesFogScale || usesFogFragCoord ||
               usesFogFragCoordInput || usesFrontColor || usesBackColor ||
               usesFrontSecondaryColor || usesBackSecondaryColor ||
               usesFragmentColor || usesTextureEnvColor ||
               usesLightModelAmbient || anyLight() ||
               usesClipVertex || synthesizesLegacyClipPlanes ||
               usesFtransform || rewroteTexture2D ||
               rewroteTextureCube || rewroteShadow2DProj;
    }
};

struct CompatShaderRewriteResult {
    // Rewritten source. If no rewrite was applied, equals the original.
    std::string source;
    // Which `appgl_*` matrix uniforms got synthesized into the rewritten
    // source. See the matrix-bind path in GLContext::linkProgram.
    SynthesizedMatrixUsage usage;
    // Phase 8X Group 4d follow-up¹⁹ — which of the non-matrix compat
    // features were exercised on this source. Callers may consult this
    // for diagnostics, but the preamble emission itself is
    // self-contained — no caller needs to act on these flags to get
    // correct behaviour.
    LegacyCompatUsage legacy;
    // True iff the original source carried `#version NNN compatibility`.
    bool wasCompatProfile = false;
    // True iff any rewrite was applied (version downgrade, preamble
    // injection, or both). When false, `source` matches the original
    // byte-for-byte and the caller can skip the rewrite-aware path.
    bool didRewrite = false;
};

enum class GeometryShader4DirectiveMode {
    Absent,
    Disable,
    Warn,
    Enable,
    Require,
};

struct GeometryShader4DirectiveState {
    GeometryShader4DirectiveMode mode = GeometryShader4DirectiveMode::Absent;
    bool present = false;

    bool active() const {
        return mode == GeometryShader4DirectiveMode::Warn ||
               mode == GeometryShader4DirectiveMode::Enable ||
               mode == GeometryShader4DirectiveMode::Require;
    }
};

struct GeometryShader4SourceLayout {
    bool hasInputType = false;
    GLenum inputType = 0;
    bool hasOutputType = false;
    GLenum outputType = 0;
    bool hasVerticesOut = false;
    int verticesOut = 0;
    bool valid = true;
    std::string diagnostic;
};

// Link-local effective geometry state. Source layout declarations win over
// the program's ARB request state independently for each property.
struct GeometryShader4LinkPlan {
    bool active = false;
    GLenum inputType = 0;
    GLenum outputType = 0;
    int verticesOut = 0;
    int verticesIn = 0;
    // Standalone compile can widen private legacy built-in arrays so
    // topology-dependent bounds remain link errors. Zero uses verticesIn.
    int materializedInputCapacity = 0;
    bool inputFromSource = false;
    bool outputFromSource = false;
    bool verticesOutFromSource = false;
};

struct GeometryShader4LegacyInputUsage {
    bool clipVertex = false;
    bool frontColor = false;
    bool backColor = false;
    bool frontSecondaryColor = false;
    bool backSecondaryColor = false;
    bool texCoord = false;
    bool fogFragCoord = false;

    bool any() const {
        return clipVertex || frontColor || backColor ||
               frontSecondaryColor || backSecondaryColor ||
               texCoord || fogFragCoord;
    }
};

struct GeometryShader4RewriteResult {
    std::string source;
    GeometryShader4DirectiveState directive;
    GeometryShader4LegacyInputUsage legacyInputs;
    bool didRewrite = false;
    bool valid = true;
    std::string diagnostic;
};

// Structured ARB_geometry_shader4 source handling. These helpers recognize
// only real preprocessing directives and code tokens; comments, strings, and
// identifier substrings do not activate or rewrite the compatibility path.
GeometryShader4DirectiveState scanGeometryShader4Directive(
    std::string_view source);
GeometryShader4SourceLayout parseGeometryShader4SourceLayout(
    std::string_view source);
GeometryShader4RewriteResult rewriteGeometryShader4Source(
    std::string_view source,
    const GeometryShader4LinkPlan& plan);
std::string rewriteGeometryShader4VertexTransport(
    std::string_view normalizedVertexSource,
    const GeometryShader4LegacyInputUsage& usage);

// Names of the synthesized matrix uniforms. Hand-coded constexpr strings
// so the link-time path can match by name without having to know the
// rewriter's internal table. Kept in a namespace so callers don't
// accidentally pull the names into the global ns via a `using` directive.
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
inline constexpr const char* kTextureEnvColor =
    "appgl_TextureEnvColor";  // vec4[8] array
inline constexpr const char* kLightModelAmbient =
    "appgl_LightModelAmbient";
inline constexpr const char* kFogColor =
    "appgl_FogColor";
inline constexpr const char* kFogDensity =
    "appgl_FogDensity";
inline constexpr const char* kFogStart =
    "appgl_FogStart";
inline constexpr const char* kFogEnd =
    "appgl_FogEnd";
inline constexpr const char* kFogScale =
    "appgl_FogScale";
inline constexpr const char* kLegacyClipPlanes =
    "appgl_LegacyClipPlanes";  // vec4[8] array
}  // namespace SynthesizedUniformNames

// Length of the synthesized texture matrix array. Matches
// MatrixStateMirror::kMaxTextureUnits.
inline constexpr unsigned int kSynthesizedTextureMatrixCount = 8;

// Length of the synthesized texture environment color array. Mirrors the
// legacy gl_TextureEnvColor[N] surface and matches the texture-matrix count.
inline constexpr unsigned int kSynthesizedTextureEnvColorCount = 8;

// GL compatibility exposes eight legacy user clip planes.
inline constexpr unsigned int kSynthesizedLegacyClipPlaneCount = 8;

// Phase 8X Group 4d follow-up¹⁹ — length of the synthesized light-source
// array uniform. Matches the GL 1.x `GL_MAX_LIGHTS` minimum (8) and the
// spring model-drawer slot count the fw¹⁸ verification memo reported.
inline constexpr unsigned int kSynthesizedLightSourceCount = 8;

// Apply the compat-shader rewrite. Returns the rewritten source plus a
// usage descriptor that the link-time path uses to cache uniform
// locations on the program object. Safe to call on any GLSL source —
// non-compat shaders that don't reference any fixed-function identifier
// come back unchanged with `didRewrite == false`.
//
// `stage` is the GL shader stage enum (GL_VERTEX_SHADER /
// GL_FRAGMENT_SHADER / GL_GEOMETRY_SHADER / GL_TESS_*_SHADER /
// GL_COMPUTE_SHADER). Affects the direction of `varying` rewrites and
// the `out`/`in` side of stage-bridged arrays.
enum class CompatShaderRewriteMode {
    Default,
    ArbGeometryShader4LinkView,
};

CompatShaderRewriteResult rewriteCompatShader(std::string_view source,
                                              GLenum stage,
                                              CompatShaderRewriteMode mode =
                                                  CompatShaderRewriteMode::Default);

// Pre-glslang validation: GLSL 4.60 §4.1.8 allows ONLY precision
// qualifiers (highp/mediump/lowp) on struct members. Everything else
// — storage (in/out/uniform/buffer/shared), layout(...), interpolation
// (smooth/flat/noperspective in/out), invariant, precise, memory
// (coherent/volatile/restrict/readonly/writeonly) — is forbidden.
// Glslang under Vulkan-relaxed rules silently accepts some of these,
// so we enforce the rule ourselves before handing the source to
// glslang. Returns true if OK, or false + populates `errorMessage`
// with a glslang-style diagnostic (ready to surface via
// getShaderInfoLog).
bool validateStructMemberQualifiers(std::string_view source,
                                    std::string& errorMessage);

}  // namespace appgl
