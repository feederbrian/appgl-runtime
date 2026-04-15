#include "CompatShaderRewrite.h"

#include <AppGL/AppGL.h>

#include <cctype>
#include <cstdio>
#include <cstring>

namespace appgl {

namespace {

bool isIdentChar(char c) {
    return std::isalnum(static_cast<unsigned char>(c)) || c == '_';
}

// Returns true iff `needle` appears in `hay` as a complete word — not
// surrounded by other identifier characters on either side. This is what
// distinguishes `gl_ModelViewMatrix` from `gl_ModelViewMatrixInverse` and
// `gl_ModelViewProjectionMatrix` (which differs at position 12, but the
// word-boundary check catches the trailing `Inverse` form regardless).
bool containsIdentifier(std::string_view hay, std::string_view needle) {
    if (needle.empty() || hay.size() < needle.size()) {
        return false;
    }
    std::size_t pos = 0;
    while (true) {
        const std::size_t found = hay.find(needle, pos);
        if (found == std::string_view::npos) {
            return false;
        }
        const bool leftOk = (found == 0) || !isIdentChar(hay[found - 1]);
        const std::size_t end = found + needle.size();
        const bool rightOk = (end >= hay.size()) || !isIdentChar(hay[end]);
        if (leftOk && rightOk) {
            return true;
        }
        pos = found + 1;
    }
}

// Replace every word-boundary occurrence of `from` with `to` in `src`.
// Word-boundary match prevents e.g. `gl_Vertex` from being rewritten
// inside `gl_VertexID`. Used for rewriting the pre-core identifier
// aliases (`gl_Vertex` → `appgl_Vertex`, `varying` → `in`/`out`, etc.)
// once their corresponding `#define` / preamble declarations have been
// committed to the scan flags.
void replaceIdentifier(std::string& src,
                       std::string_view from,
                       std::string_view to) {
    std::size_t pos = 0;
    while (true) {
        const std::size_t found = src.find(from, pos);
        if (found == std::string::npos) {
            return;
        }
        const bool leftOk = (found == 0) || !isIdentChar(src[found - 1]);
        const std::size_t end = found + from.size();
        const bool rightOk = (end >= src.size()) || !isIdentChar(src[end]);
        if (leftOk && rightOk) {
            src.replace(found, from.size(), to);
            pos = found + to.size();
        } else {
            pos = found + 1;
        }
    }
}

// Replace every literal occurrence of `from` with `to`. Used for
// dotted field-access rewrites (`gl_Fog.color` → `appgl_FogColor`)
// where the leading and trailing boundaries are already partly
// non-identifier characters and a straight substring match is
// unambiguous.
void replaceLiteral(std::string& src,
                    std::string_view from,
                    std::string_view to) {
    std::size_t pos = 0;
    while (true) {
        const std::size_t found = src.find(from, pos);
        if (found == std::string::npos) {
            return;
        }
        src.replace(found, from.size(), to);
        pos = found + to.size();
    }
}

// Locate the first `#version` directive and the index just past its
// terminating newline. Returns string::npos on failure.
//
// `outVersionStart` (when non-null) receives the offset of the `#`
// character. The caller uses this to scan the version line for the
// `compatibility` token and/or the `100/110/120/130` number for the
// fw¹⁹ version-floor upgrade.
std::size_t findVersionLineEnd(const std::string& source,
                               std::size_t* outVersionStart) {
    const std::size_t pos = source.find("#version");
    if (pos == std::string::npos) {
        return std::string::npos;
    }
    if (outVersionStart != nullptr) {
        *outVersionStart = pos;
    }
    std::size_t eol = source.find('\n', pos);
    if (eol == std::string::npos) {
        eol = source.size();
    }
    return eol;
}

// Parse the numeric version token inside a `#version NNN [profile]`
// line. Returns the integer version (e.g. 120, 150) on success, or -1
// if no numeric token follows `#version`. Used by the fw¹⁹ version-
// floor upgrade path to decide whether a source needs bumping.
int parseVersionNumber(std::string_view versionLine) {
    const std::size_t kw = versionLine.find("#version");
    if (kw == std::string_view::npos) {
        return -1;
    }
    std::size_t i = kw + 8;  // length of "#version"
    while (i < versionLine.size() && std::isspace(static_cast<unsigned char>(versionLine[i]))) {
        ++i;
    }
    if (i >= versionLine.size() || !std::isdigit(static_cast<unsigned char>(versionLine[i]))) {
        return -1;
    }
    int value = 0;
    while (i < versionLine.size() && std::isdigit(static_cast<unsigned char>(versionLine[i]))) {
        value = value * 10 + (versionLine[i] - '0');
        ++i;
    }
    return value;
}

// Scan for every literal subscript `gl_MultiTexCoord<N>` (N in 0..7)
// and record usage. The `[i]` subscript form is not used by
// `gl_MultiTexCoord` in legacy GLSL — each slot is its own named
// identifier — so a whole-word scan is enough.
void scanMultiTexCoord(std::string_view source,
                       std::array<bool, 8>& out) {
    for (unsigned int i = 0; i < 8; ++i) {
        char name[24];
        std::snprintf(name, sizeof(name), "gl_MultiTexCoord%u", i);
        if (containsIdentifier(source, name)) {
            out[i] = true;
        }
    }
}

// Scan `gl_FragData[N]` subscripts and return the highest literal N
// seen, or -1 if the identifier isn't used. Non-literal subscripts
// produce a max of 7 (the safe upper bound — GL_MAX_DRAW_BUFFERS is 8)
// so dynamic indices still get a large-enough array emitted.
int scanFragDataMax(std::string_view source) {
    int maxIdx = -1;
    std::size_t pos = 0;
    while (true) {
        const std::size_t found = source.find("gl_FragData", pos);
        if (found == std::string_view::npos) {
            return maxIdx;
        }
        const bool leftOk = (found == 0) || !isIdentChar(source[found - 1]);
        const std::size_t end = found + 11;  // len("gl_FragData")
        if (!leftOk || end >= source.size()) {
            pos = found + 1;
            continue;
        }
        // Skip whitespace between identifier and `[`.
        std::size_t j = end;
        while (j < source.size() && std::isspace(static_cast<unsigned char>(source[j]))) {
            ++j;
        }
        if (j >= source.size() || source[j] != '[') {
            pos = found + 1;
            continue;
        }
        ++j;
        while (j < source.size() && std::isspace(static_cast<unsigned char>(source[j]))) {
            ++j;
        }
        // Literal numeric subscript?
        if (j < source.size() && std::isdigit(static_cast<unsigned char>(source[j]))) {
            int value = 0;
            while (j < source.size() && std::isdigit(static_cast<unsigned char>(source[j]))) {
                value = value * 10 + (source[j] - '0');
                ++j;
            }
            if (value > maxIdx) {
                maxIdx = value;
            }
        } else {
            // Non-literal subscript — fall back to the max draw-buffer
            // count so the rewriter emits a fully-sized array.
            if (maxIdx < 7) {
                maxIdx = 7;
            }
        }
        pos = found + 1;
    }
}

// Scan `gl_TexCoord[N]` subscripts and return the highest literal N
// plus one (so the caller can size an array directly), or -1 if the
// identifier isn't used. Non-literal subscripts size the array to 8.
int scanTexCoordMax(std::string_view source) {
    int maxIdx = -1;
    std::size_t pos = 0;
    while (true) {
        const std::size_t found = source.find("gl_TexCoord", pos);
        if (found == std::string_view::npos) {
            return maxIdx;
        }
        const bool leftOk = (found == 0) || !isIdentChar(source[found - 1]);
        const std::size_t end = found + 11;  // len("gl_TexCoord")
        if (!leftOk || end >= source.size()) {
            pos = found + 1;
            continue;
        }
        // Must be followed by `[` (possibly with whitespace) — otherwise
        // this is `gl_TexCoordFoo` or similar. The word-boundary left
        // check already rules out `_gl_TexCoord`.
        std::size_t j = end;
        while (j < source.size() && std::isspace(static_cast<unsigned char>(source[j]))) {
            ++j;
        }
        if (j >= source.size() || source[j] != '[') {
            pos = found + 1;
            continue;
        }
        ++j;
        while (j < source.size() && std::isspace(static_cast<unsigned char>(source[j]))) {
            ++j;
        }
        if (j < source.size() && std::isdigit(static_cast<unsigned char>(source[j]))) {
            int value = 0;
            while (j < source.size() && std::isdigit(static_cast<unsigned char>(source[j]))) {
                value = value * 10 + (source[j] - '0');
                ++j;
            }
            if (value > maxIdx) {
                maxIdx = value;
            }
        } else {
            if (maxIdx < 7) {
                maxIdx = 7;
            }
        }
        pos = found + 1;
    }
}

// Scan `gl_LightSource[*].<field>` field accesses and union-set
// `usesLight<Field>` flags. Subscripts are not extracted — the preamble
// emits fixed-size arrays for every used field, so any subscript shape
// (literal, identifier, expression) plugs into the `[expr]` form of the
// rewritten text unchanged. The only thing the rewriter needs to know is
// *which* fields were referenced so only those arrays get declared.
//
// Fields checked (from fw¹⁸-verification §4.2, plus the standard compat
// subset Spring's ModelFragProg samples): ambient, diffuse, specular,
// position, halfVector, spotDirection, spotExponent, spotCutoff,
// spotCosCutoff, constantAttenuation, linearAttenuation,
// quadraticAttenuation.
void scanLightSourceFields(std::string_view source, LegacyCompatUsage& out) {
    struct FieldEntry {
        const char* name;
        bool LegacyCompatUsage::* flag;
    };
    static const FieldEntry kFields[] = {
        {"ambient",              &LegacyCompatUsage::usesLightAmbient},
        {"diffuse",              &LegacyCompatUsage::usesLightDiffuse},
        {"specular",             &LegacyCompatUsage::usesLightSpecular},
        {"position",             &LegacyCompatUsage::usesLightPosition},
        {"halfVector",           &LegacyCompatUsage::usesLightHalfVector},
        {"spotDirection",        &LegacyCompatUsage::usesLightSpotDirection},
        {"spotExponent",         &LegacyCompatUsage::usesLightSpotExponent},
        {"spotCutoff",           &LegacyCompatUsage::usesLightSpotCutoff},
        {"spotCosCutoff",        &LegacyCompatUsage::usesLightSpotCosCutoff},
        {"constantAttenuation",  &LegacyCompatUsage::usesLightConstantAttenuation},
        {"linearAttenuation",    &LegacyCompatUsage::usesLightLinearAttenuation},
        {"quadraticAttenuation", &LegacyCompatUsage::usesLightQuadraticAttenuation},
    };
    std::size_t pos = 0;
    while (true) {
        const std::size_t found = source.find("gl_LightSource", pos);
        if (found == std::string_view::npos) {
            return;
        }
        const bool leftOk = (found == 0) || !isIdentChar(source[found - 1]);
        if (!leftOk) {
            pos = found + 1;
            continue;
        }
        // Advance past `gl_LightSource [whitespace] [`.
        std::size_t j = found + 14;  // len("gl_LightSource")
        while (j < source.size() && std::isspace(static_cast<unsigned char>(source[j]))) {
            ++j;
        }
        if (j >= source.size() || source[j] != '[') {
            pos = found + 1;
            continue;
        }
        ++j;
        // Skip past the subscript expression, balancing nested brackets.
        int depth = 1;
        while (j < source.size() && depth > 0) {
            if (source[j] == '[') {
                ++depth;
            } else if (source[j] == ']') {
                --depth;
                if (depth == 0) {
                    ++j;
                    break;
                }
            }
            ++j;
        }
        while (j < source.size() && std::isspace(static_cast<unsigned char>(source[j]))) {
            ++j;
        }
        if (j >= source.size() || source[j] != '.') {
            pos = found + 1;
            continue;
        }
        ++j;
        while (j < source.size() && std::isspace(static_cast<unsigned char>(source[j]))) {
            ++j;
        }
        const std::size_t fieldStart = j;
        while (j < source.size() && isIdentChar(source[j])) {
            ++j;
        }
        const std::string_view field = source.substr(fieldStart, j - fieldStart);
        for (const auto& entry : kFields) {
            if (field == entry.name) {
                out.*(entry.flag) = true;
                break;
            }
        }
        pos = found + 1;
    }
}

// Emit a declaration block for every scanned light-source field into
// `preamble`. Each field becomes a fixed-size array uniform sized to
// `kSynthesizedLightSourceCount`; references of the form
// `gl_LightSource[<expr>].<field>` are rewritten to
// `appgl_LightSource<Field>[<expr>]` in the source body, so the array
// subscript carries through the original (possibly dynamic) expression.
//
// Defaults are NOT seeded here — fw¹⁵'s default-initializer scanner
// skips array uniforms, and the fw¹⁹ rewriter deliberately follows the
// same pattern to keep the shape of new compat features matching the
// existing matrix path. This means the zero-initialized GL state will
// produce black lighting until a follow-up round adds a seed-at-link-
// time hook for the fw¹⁹ light/fog uniforms. The fw¹⁹ handoff to BAR
// calls out the risk explicitly.
void emitLightSourceDecls(std::string& preamble, const LegacyCompatUsage& use) {
    auto emit = [&](const char* glslType, const char* fieldName) {
        char buf[160];
        std::snprintf(buf, sizeof(buf),
                      "uniform %s appgl_LightSource%s[%u];\n",
                      glslType, fieldName, kSynthesizedLightSourceCount);
        preamble.append(buf);
    };
    if (use.usesLightAmbient)              emit("vec4",  "Ambient");
    if (use.usesLightDiffuse)              emit("vec4",  "Diffuse");
    if (use.usesLightSpecular)             emit("vec4",  "Specular");
    if (use.usesLightPosition)             emit("vec4",  "Position");
    if (use.usesLightHalfVector)           emit("vec4",  "HalfVector");
    if (use.usesLightSpotDirection)        emit("vec3",  "SpotDirection");
    if (use.usesLightSpotExponent)         emit("float", "SpotExponent");
    if (use.usesLightSpotCutoff)           emit("float", "SpotCutoff");
    if (use.usesLightSpotCosCutoff)        emit("float", "SpotCosCutoff");
    if (use.usesLightConstantAttenuation)  emit("float", "ConstantAttenuation");
    if (use.usesLightLinearAttenuation)    emit("float", "LinearAttenuation");
    if (use.usesLightQuadraticAttenuation) emit("float", "QuadraticAttenuation");
}

// Rewrite `gl_LightSource[<subscript>].<field>` occurrences to
// `appgl_LightSource<Field>[<subscript>]`. The subscript expression is
// copied byte-for-byte so dynamic indices (e.g. `BASE_MODEL_LIGHT + i`)
// carry through unchanged. Unknown fields — any field name not in the
// scan table — are left alone and will fall out as a glslang compile
// error, which is strictly better than silently dropping a reference.
void rewriteLightSourceSubscripts(std::string& src) {
    struct FieldEntry {
        const char* name;
        const char* rewriteSuffix;
    };
    static const FieldEntry kFields[] = {
        {"ambient",              "Ambient"},
        {"diffuse",              "Diffuse"},
        {"specular",             "Specular"},
        {"position",             "Position"},
        {"halfVector",           "HalfVector"},
        {"spotDirection",        "SpotDirection"},
        {"spotExponent",         "SpotExponent"},
        {"spotCutoff",           "SpotCutoff"},
        {"spotCosCutoff",        "SpotCosCutoff"},
        {"constantAttenuation",  "ConstantAttenuation"},
        {"linearAttenuation",    "LinearAttenuation"},
        {"quadraticAttenuation", "QuadraticAttenuation"},
    };
    std::size_t pos = 0;
    while (true) {
        const std::size_t found = src.find("gl_LightSource", pos);
        if (found == std::string::npos) {
            return;
        }
        const bool leftOk = (found == 0) || !isIdentChar(src[found - 1]);
        if (!leftOk) {
            pos = found + 1;
            continue;
        }
        std::size_t j = found + 14;
        while (j < src.size() && std::isspace(static_cast<unsigned char>(src[j]))) {
            ++j;
        }
        if (j >= src.size() || src[j] != '[') {
            pos = found + 1;
            continue;
        }
        const std::size_t subscriptOpen = j;
        ++j;
        int depth = 1;
        while (j < src.size() && depth > 0) {
            if (src[j] == '[') ++depth;
            else if (src[j] == ']') {
                --depth;
                if (depth == 0) { ++j; break; }
            }
            ++j;
        }
        const std::size_t subscriptClose = j;  // index just past `]`
        std::size_t k = subscriptClose;
        while (k < src.size() && std::isspace(static_cast<unsigned char>(src[k]))) {
            ++k;
        }
        if (k >= src.size() || src[k] != '.') {
            pos = found + 1;
            continue;
        }
        ++k;
        while (k < src.size() && std::isspace(static_cast<unsigned char>(src[k]))) {
            ++k;
        }
        const std::size_t fieldStart = k;
        while (k < src.size() && isIdentChar(src[k])) {
            ++k;
        }
        const std::string_view field(src.data() + fieldStart, k - fieldStart);
        const char* suffix = nullptr;
        for (const auto& entry : kFields) {
            if (field == entry.name) {
                suffix = entry.rewriteSuffix;
                break;
            }
        }
        if (suffix == nullptr) {
            pos = found + 1;
            continue;
        }
        // Extract the subscript text (exclusive of the surrounding `[]`)
        // and construct the rewritten expression. The subscript text may
        // contain anything — identifiers, numeric literals, arithmetic —
        // and is copied verbatim.
        const std::string subscript(src,
                                    subscriptOpen + 1,
                                    (subscriptClose - 1) - (subscriptOpen + 1));
        std::string replacement;
        replacement.reserve(32 + subscript.size());
        replacement.append("appgl_LightSource");
        replacement.append(suffix);
        replacement.push_back('[');
        replacement.append(subscript);
        replacement.push_back(']');
        const std::size_t totalLen = k - found;
        src.replace(found, totalLen, replacement);
        pos = found + replacement.size();
    }
}

}  // namespace

CompatShaderRewriteResult rewriteCompatShader(std::string_view source,
                                              GLenum stage) {
    CompatShaderRewriteResult result;
    result.source.assign(source.begin(), source.end());

    const bool isVertex = (stage == GL_VERTEX_SHADER);
    const bool isFragment = (stage == GL_FRAGMENT_SHADER);

    // ---- 1. Identifier scan (against the ORIGINAL, unrewritten source) ---
    // Scan the original source for matrix-family fixed-function builtins.
    // Word-boundary matching means a shader that uses both
    // `gl_ModelViewMatrix` AND `gl_ModelViewMatrixInverse` correctly sets
    // both flags (the bare form is detected at its standalone occurrence,
    // the Inverse form at its own).
    result.usage.modelView =
        containsIdentifier(source, "gl_ModelViewMatrix");
    result.usage.projection =
        containsIdentifier(source, "gl_ProjectionMatrix");
    result.usage.modelViewProjection =
        containsIdentifier(source, "gl_ModelViewProjectionMatrix");
    result.usage.modelViewInverse =
        containsIdentifier(source, "gl_ModelViewMatrixInverse");
    result.usage.projectionInverse =
        containsIdentifier(source, "gl_ProjectionMatrixInverse");
    result.usage.modelViewProjectionInverse =
        containsIdentifier(source, "gl_ModelViewProjectionMatrixInverse");
    result.usage.normal =
        containsIdentifier(source, "gl_NormalMatrix");
    result.usage.texture =
        containsIdentifier(source, "gl_TextureMatrix");

    // Phase 8X Group 4d follow-up¹⁹ — legacy compat feature scans. Each
    // scan operates on the original source (pre-rewrite) so the later
    // source-text rewrites don't race the detection.
    LegacyCompatUsage& legacy = result.legacy;
    legacy.hadVarying = containsIdentifier(source, "varying");
    if (isVertex) {
        legacy.attrVertex = containsIdentifier(source, "gl_Vertex");
        legacy.attrNormal = containsIdentifier(source, "gl_Normal");
        legacy.attrColor = containsIdentifier(source, "gl_Color");
        scanMultiTexCoord(source, legacy.attrMultiTexCoord);
        legacy.usesClipVertex = containsIdentifier(source, "gl_ClipVertex");
    }
    if (isFragment) {
        legacy.fragColor = containsIdentifier(source, "gl_FragColor");
        legacy.fragDataMax = scanFragDataMax(source);
    }
    legacy.texCoordMax = scanTexCoordMax(source);
    // gl_Fog.* field accesses — individual scan per field so the
    // preamble declares only what's used.
    legacy.usesFogColor   = (source.find("gl_Fog.color")   != std::string_view::npos);
    legacy.usesFogDensity = (source.find("gl_Fog.density") != std::string_view::npos);
    legacy.usesFogStart   = (source.find("gl_Fog.start")   != std::string_view::npos);
    legacy.usesFogEnd     = (source.find("gl_Fog.end")     != std::string_view::npos);
    legacy.usesFogScale   = (source.find("gl_Fog.scale")   != std::string_view::npos);
    scanLightSourceFields(source, legacy);
    legacy.rewroteTexture2D = containsIdentifier(source, "texture2D");
    legacy.rewroteTextureCube = containsIdentifier(source, "textureCube");
    legacy.rewroteShadow2DProj = containsIdentifier(source, "shadow2DProj");

    // ---- 2. Version line — compat/pre-140 → core 330 rewrite -------------
    std::size_t versionStart = std::string::npos;
    std::size_t versionEol = findVersionLineEnd(result.source, &versionStart);
    if (versionEol != std::string::npos) {
        const std::string_view versionLine(
            result.source.data() + versionStart, versionEol - versionStart);
        const int versionNumber = parseVersionNumber(versionLine);
        const bool isCompat = containsIdentifier(versionLine, "compatibility");
        // fw¹⁹ version-floor upgrade: glslang's Vulkan client front-end
        // rejects any desktop shader below `#version 140`, so any
        // `#version 100/110/120/130` needs to be rewritten. The chosen
        // upgrade target is `#version 330 core` because 330 is the
        // lowest version that unlocks explicit `layout(location=...)`
        // qualifiers and the unified `texture()`/`textureProj()` sampler
        // overloads — both of which the rewriter relies on when
        // emitting preamble declarations for the legacy attribute and
        // texture-sampler names.
        const bool needsFloorUpgrade =
            (versionNumber > 0 && versionNumber < 140 && !isCompat);
        if (needsFloorUpgrade) {
            legacy.upgradedVersion = true;
            // Replace the entire version line with `#version 330 core`
            // regardless of the original profile token — pre-140
            // desktop sources have no profile qualifier of their own.
            static constexpr const char kReplacement[] = "#version 330 core";
            constexpr std::size_t kReplacementLen = sizeof(kReplacement) - 1;
            const std::size_t lineLen = versionEol - versionStart;
            result.source.replace(versionStart, lineLen, kReplacement);
            // Adjust versionEol: the line now has a fixed known length.
            versionEol = versionStart + kReplacementLen;
        } else if (isCompat) {
            result.wasCompatProfile = true;
            // Replace `compatibility` with `core` in-place. Same physical
            // line, so glslang error messages on line 1 still point at
            // the version directive correctly.
            const std::size_t compatPos =
                result.source.find("compatibility", versionStart);
            constexpr std::size_t kCompatLen =
                sizeof("compatibility") - 1;
            constexpr std::size_t kCoreLen = sizeof("core") - 1;
            if (compatPos != std::string::npos && compatPos < versionEol) {
                result.source.replace(compatPos, kCompatLen, "core");
                // The string shrank by (kCompatLen - kCoreLen) bytes,
                // so the EOL index moves back by the same amount.
                versionEol -= (kCompatLen - kCoreLen);
            }
        }
    }

    // ---- 3. Decide whether to inject preamble ----------------------------
    // We inject when EITHER the original source was compat profile, OR
    // the fw¹⁹ version-floor upgrade triggered, OR any matrix identifier
    // was used, OR any legacy compat feature was exercised. All four
    // paths mean the preamble has something to contribute.
    const bool needPreamble = result.usage.any() || legacy.any();
    const bool didAnyRewrite =
        result.wasCompatProfile || legacy.upgradedVersion || needPreamble;
    if (!didAnyRewrite) {
        return result;
    }
    result.didRewrite = true;

    // ---- 4. Source-text rewrites -----------------------------------------
    // Order matters: each identifier replacement must not create text
    // that later passes would recognize as a rewrite target.
    //
    //   - `texture2D(` → `texture(`, `textureCube(` → `texture(`, and
    //     `shadow2DProj(` → `textureProj(` all replace function names.
    //     None of these collide with each other or with the identifier
    //     rewrites that follow.
    //
    //   - `varying` is an unqualified storage class; we rewrite it to
    //     `in` (FS) or `out` (VS) via a word-boundary replace. Non-raster
    //     stages (compute/etc.) leave `varying` alone — they're compile
    //     errors for a different reason and we don't need to second-
    //     guess glslang there.
    //
    //   - `gl_Vertex`/`gl_Normal`/`gl_Color`/`gl_MultiTexCoordN` are
    //     rewritten to their `appgl_*` forms via word-boundary replace.
    //     The preamble will then declare them as `layout(location=N) in`
    //     attributes so Spring's existing `glVertexAttribPointer` calls
    //     bind to the right slot.
    //
    //   - `gl_FragColor`/`gl_FragData[N]` are rewritten to `appgl_*`
    //     forms. The preamble declares matching `out` variables.
    //
    //   - `gl_TexCoord[N]` is left alone at the identifier level; the
    //     preamble `#define gl_TexCoord appgl_TexCoord` expands it.
    //
    //   - `gl_Fog.color` etc. are literal-substring rewrites to
    //     `appgl_FogColor` (etc.). Literal rather than identifier
    //     because `gl_Fog` alone is not meaningful (the dot suffix is
    //     what makes the reference).
    //
    //   - `gl_LightSource[i].field` is parsed and rewritten by
    //     `rewriteLightSourceSubscripts` which handles arbitrary
    //     subscript expressions.
    //
    //   - `gl_ClipVertex` is rewritten to `appgl_ClipVertex` (a
    //     stage-bridged `out` in VS / `in` in FS).
    if (legacy.rewroteTexture2D) {
        replaceIdentifier(result.source, "texture2D", "texture");
    }
    if (legacy.rewroteTextureCube) {
        replaceIdentifier(result.source, "textureCube", "texture");
    }
    if (legacy.rewroteShadow2DProj) {
        replaceIdentifier(result.source, "shadow2DProj", "textureProj");
    }
    if (legacy.hadVarying) {
        if (isVertex) {
            replaceIdentifier(result.source, "varying", "out");
        } else if (isFragment) {
            replaceIdentifier(result.source, "varying", "in");
        }
    }
    if (legacy.attrVertex) {
        replaceIdentifier(result.source, "gl_Vertex", "appgl_Vertex");
    }
    if (legacy.attrNormal) {
        replaceIdentifier(result.source, "gl_Normal", "appgl_Normal");
    }
    if (legacy.attrColor) {
        replaceIdentifier(result.source, "gl_Color", "appgl_Color");
    }
    for (unsigned int i = 0; i < 8; ++i) {
        if (legacy.attrMultiTexCoord[i]) {
            char from[24];
            char to[24];
            std::snprintf(from, sizeof(from), "gl_MultiTexCoord%u", i);
            std::snprintf(to, sizeof(to), "appgl_MultiTexCoord%u", i);
            replaceIdentifier(result.source, from, to);
        }
    }
    if (legacy.fragColor) {
        replaceIdentifier(result.source, "gl_FragColor", "appgl_FragColor");
    }
    if (legacy.fragDataMax >= 0) {
        replaceIdentifier(result.source, "gl_FragData", "appgl_FragData");
    }
    if (legacy.usesClipVertex) {
        replaceIdentifier(result.source, "gl_ClipVertex", "appgl_ClipVertex");
    }
    // Fog field rewrites use literal substring because the dot-suffix
    // disambiguates the boundary — `gl_Fog` alone is not a valid
    // reference in compat GLSL.
    if (legacy.usesFogColor) {
        replaceLiteral(result.source, "gl_Fog.color", "appgl_FogColor");
    }
    if (legacy.usesFogDensity) {
        replaceLiteral(result.source, "gl_Fog.density", "appgl_FogDensity");
    }
    if (legacy.usesFogStart) {
        replaceLiteral(result.source, "gl_Fog.start", "appgl_FogStart");
    }
    if (legacy.usesFogEnd) {
        replaceLiteral(result.source, "gl_Fog.end", "appgl_FogEnd");
    }
    if (legacy.usesFogScale) {
        replaceLiteral(result.source, "gl_Fog.scale", "appgl_FogScale");
    }
    if (legacy.anyLight()) {
        rewriteLightSourceSubscripts(result.source);
    }
    // The version line rewrite may have moved versionEol, but the
    // text rewrites above operate on bytes AFTER the version line
    // (identifier scans are body-scoped in practice, and even if they
    // weren't, the version line doesn't contain any rewrite target).
    // We still need to recompute the insertion point below because
    // `replaceIdentifier` has shifted the trailing bytes around.
    {
        std::size_t newVersionStart = std::string::npos;
        versionEol = findVersionLineEnd(result.source, &newVersionStart);
        versionStart = newVersionStart;
    }

    // ---- 5. Build preamble -----------------------------------------------
    std::string preamble;
    preamble.reserve(2048);

    auto addUniform = [&preamble](const char* glName,
                                  const char* applName,
                                  const char* glslType) {
        preamble.append("uniform ")
            .append(glslType)
            .append(" ")
            .append(applName)
            .append(";\n");
        preamble.append("#define ")
            .append(glName)
            .append(" ")
            .append(applName)
            .append("\n");
    };

    // 5a. Matrix-family uniforms (existing fw-7 behaviour).
    namespace SUN = SynthesizedUniformNames;
    if (result.usage.modelView) {
        addUniform("gl_ModelViewMatrix", SUN::kModelViewMatrix, "mat4");
    }
    if (result.usage.projection) {
        addUniform("gl_ProjectionMatrix", SUN::kProjectionMatrix, "mat4");
    }
    if (result.usage.modelViewProjection) {
        addUniform("gl_ModelViewProjectionMatrix",
                   SUN::kModelViewProjectionMatrix, "mat4");
    }
    if (result.usage.modelViewInverse) {
        addUniform("gl_ModelViewMatrixInverse",
                   SUN::kModelViewMatrixInverse, "mat4");
    }
    if (result.usage.projectionInverse) {
        addUniform("gl_ProjectionMatrixInverse",
                   SUN::kProjectionMatrixInverse, "mat4");
    }
    if (result.usage.modelViewProjectionInverse) {
        addUniform("gl_ModelViewProjectionMatrixInverse",
                   SUN::kModelViewProjectionMatrixInverse, "mat4");
    }
    if (result.usage.normal) {
        // Normal matrix is mat3 in GLSL — see the comment block in
        // MatrixStateMirror::Matrix4::normalFromModelView() for why we
        // still store it as a Matrix4 internally.
        addUniform("gl_NormalMatrix", SUN::kNormalMatrix, "mat3");
    }
    if (result.usage.texture) {
        // gl_TextureMatrix is an array indexed by texture unit. Declare
        // a fixed-size mat4 array; the `#define` lets `gl_TextureMatrix[i]`
        // expand to `appgl_TextureMatrix[i]` so subscript expressions
        // translate cleanly.
        char buf[160];
        std::snprintf(buf, sizeof(buf),
                      "uniform mat4 %s[%u];\n#define gl_TextureMatrix %s\n",
                      SUN::kTextureMatrix,
                      kSynthesizedTextureMatrixCount,
                      SUN::kTextureMatrix);
        preamble.append(buf);
    }

    // 5b. fw¹⁹ — legacy attribute declarations (vertex stage only).
    // Location indices follow the NVIDIA-era conventional attribute
    // aliasing: 0 = Vertex/position, 2 = Normal, 3 = Color, 8+N =
    // MultiTexCoord[N]. Spring's compat shaders were written against
    // this convention, and Spring's own `glVertexAttribPointer` calls
    // bind data into matching numeric indices (the fw¹⁸-verification
    // memo §7.3 flagged the scheme as an open question; fw¹⁹ commits
    // to the NVIDIA convention explicitly and BAR-W's next verification
    // pass will surface any mismatch as wrong-position geometry).
    auto addLayoutAttrib = [&preamble](unsigned int location,
                                       const char* glslType,
                                       const char* applName) {
        char buf[160];
        std::snprintf(buf, sizeof(buf),
                      "layout(location = %u) in %s %s;\n",
                      location, glslType, applName);
        preamble.append(buf);
    };
    if (isVertex) {
        if (legacy.attrVertex) {
            addLayoutAttrib(0, "vec4", "appgl_Vertex");
        }
        if (legacy.attrNormal) {
            addLayoutAttrib(2, "vec3", "appgl_Normal");
        }
        if (legacy.attrColor) {
            addLayoutAttrib(3, "vec4", "appgl_Color");
        }
        for (unsigned int i = 0; i < 8; ++i) {
            if (legacy.attrMultiTexCoord[i]) {
                char applName[32];
                std::snprintf(applName, sizeof(applName),
                              "appgl_MultiTexCoord%u", i);
                addLayoutAttrib(8 + i, "vec4", applName);
            }
        }
    }

    // 5c. fw¹⁹ — fragment output declarations.
    if (isFragment) {
        if (legacy.fragColor) {
            preamble.append(
                "layout(location = 0) out vec4 appgl_FragColor;\n");
        }
        if (legacy.fragDataMax >= 0) {
            // Emit an array at location 0. Consecutive indices cover
            // the range [0, fragDataMax] inclusive — the spec says
            // arrayed frag outputs consume sequential locations.
            const int count = legacy.fragDataMax + 1;
            char buf[160];
            std::snprintf(buf, sizeof(buf),
                          "layout(location = 0) out vec4 appgl_FragData[%d];\n",
                          count);
            preamble.append(buf);
        }
    }

    // 5d. fw¹⁹ — gl_TexCoord[] stage bridge. VS emits an `out` array,
    // FS emits a matching `in` array. We don't know at rewrite time
    // which stages share a program, so we always emit an 8-slot array
    // regardless of the highest subscript observed — this is correct
    // even if the VS and FS disagree on which slots they touch, because
    // the interface matcher matches on declared size, not on slot usage.
    if (legacy.texCoordMax >= 0) {
        const unsigned int count = 8;
        char buf[160];
        if (isVertex) {
            std::snprintf(buf, sizeof(buf),
                          "out vec4 appgl_TexCoord[%u];\n"
                          "#define gl_TexCoord appgl_TexCoord\n",
                          count);
            preamble.append(buf);
        } else if (isFragment) {
            std::snprintf(buf, sizeof(buf),
                          "in vec4 appgl_TexCoord[%u];\n"
                          "#define gl_TexCoord appgl_TexCoord\n",
                          count);
            preamble.append(buf);
        }
    }

    // 5e. fw¹⁹ — fog uniforms with GL 1.x spec defaults. fw¹⁵'s uniform
    // default-initializer scanner picks these up and seeds the link-time
    // uniform-value table, so the shader sees the same default fog
    // state a vendor compat driver would expose at boot (clear-color
    // fog, density 1, linear [0,1]). Spring may change these via glFog*
    // calls which we currently silently drop — if fw¹⁹ verification
    // shows fog rendering wrong, the next round adds a state-mirror
    // capture path for glFog*.
    if (legacy.usesFogColor) {
        preamble.append(
            "uniform vec4 appgl_FogColor = vec4(0.0, 0.0, 0.0, 0.0);\n");
    }
    if (legacy.usesFogDensity) {
        preamble.append(
            "uniform float appgl_FogDensity = 1.0;\n");
    }
    if (legacy.usesFogStart) {
        preamble.append(
            "uniform float appgl_FogStart = 0.0;\n");
    }
    if (legacy.usesFogEnd) {
        preamble.append(
            "uniform float appgl_FogEnd = 1.0;\n");
    }
    if (legacy.usesFogScale) {
        preamble.append(
            "uniform float appgl_FogScale = 1.0;\n");
    }

    // 5f. fw¹⁹ — light-source array declarations. Only fields that were
    // referenced in the source get declared; unused fields stay out of
    // the uniform table to keep the UBO compact.
    if (legacy.anyLight()) {
        emitLightSourceDecls(preamble, legacy);
    }

    // 5g. fw¹⁹ — gl_ClipVertex bridge. The VS assigns it (e.g.
    // `gl_ClipVertex = gl_ModelViewMatrix * gl_Vertex;`) and may re-read
    // it locally or export it as a varying. Core-profile GLSL dropped
    // `gl_ClipVertex` entirely, so we substitute a plain `out` varying
    // on the VS side and a matched `in` on the FS side. The
    // cross-stage interface matcher is happy with the balanced decl
    // pair; Metal's pipeline-state validator doesn't mind an unused
    // varying.
    if (legacy.usesClipVertex) {
        if (isVertex) {
            preamble.append("out vec4 appgl_ClipVertex;\n");
        } else if (isFragment) {
            preamble.append("in vec4 appgl_ClipVertex;\n");
        }
    }

    // ---- 6. Inject preamble ----------------------------------------------
    // The preamble must come AFTER `#version` (GLSL forbids any non-
    // whitespace before `#version`). After the preamble we emit `#line 2`
    // so glslang's error reporting maps the user's line 2 to its original
    // line number despite the inserted preamble lines.
    if (versionEol != std::string::npos) {
        std::size_t insertAt = versionEol;
        if (insertAt < result.source.size() &&
            result.source[insertAt] == '\n') {
            insertAt += 1;
        }
        std::string injected;
        injected.reserve(preamble.size() + 16);
        injected.append(preamble);
        injected.append("#line 2\n");
        result.source.insert(insertAt, injected);
    } else {
        // No `#version` line in the original. The fallback version
        // (currently 330) gets applied by ShaderTranslator::compileGLSL.
        // We can prepend the preamble at the very start; `#line 1`
        // afterwards keeps error messages pointing at the original
        // user-visible first line.
        std::string injected;
        injected.reserve(preamble.size() + 16);
        injected.append(preamble);
        injected.append("#line 1\n");
        result.source.insert(0, injected);
    }

    return result;
}

}  // namespace appgl
