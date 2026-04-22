#include "CompatShaderRewrite.h"

#include <AppGL/AppGL.h>

#include <cctype>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_set>

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

    // Preprocessor-level rewrite: `#define NAME defined(OTHER)` is a
    // glslang-error ("'defined' : cannot use in preprocessor expression
    // when expanded from macros") even though some drivers accept the
    // pattern. CTS
    // `shaders.preprocessor.conditional_inclusion.basic_2_{vertex,
    // fragment}` submits exactly this pattern and expects the shader
    // to compile. We pre-evaluate `defined(OTHER)` by scanning the rest
    // of the source for a matching `#define OTHER` (with no value or
    // any value). Result: `#define NAME 1` (OTHER defined anywhere in
    // source) or `#define NAME 0` (not defined). This matches the
    // implementation-defined semantics real GL drivers typically use.
    {
        std::string& src = result.source;
        std::size_t scan = 0;
        while (scan < src.size()) {
            std::size_t hash = src.find("#define", scan);
            if (hash == std::string::npos) break;
            // Skip the "#define" token + whitespace
            std::size_t p = hash + 7;
            while (p < src.size() && (src[p] == ' ' || src[p] == '\t')) ++p;
            // Parse the macro NAME
            std::size_t nameStart = p;
            while (p < src.size() &&
                   (std::isalnum(static_cast<unsigned char>(src[p])) || src[p] == '_')) {
                ++p;
            }
            if (p == nameStart) { scan = hash + 1; continue; }
            // Skip whitespace between NAME and replacement
            std::size_t bodyStart = p;
            while (bodyStart < src.size() && (src[bodyStart] == ' ' || src[bodyStart] == '\t')) {
                ++bodyStart;
            }
            // End of line = end of #define body
            std::size_t bodyEnd = bodyStart;
            while (bodyEnd < src.size() && src[bodyEnd] != '\n' && src[bodyEnd] != '\r') {
                ++bodyEnd;
            }
            std::string body = src.substr(bodyStart, bodyEnd - bodyStart);
            // Look for `defined(IDENT)` or `defined IDENT` (no parens) in body
            auto matchDefined = [](const std::string& b, std::string& other) -> bool {
                std::size_t dp = b.find("defined");
                if (dp == std::string::npos) return false;
                // Word-boundary
                if (dp > 0) {
                    char prev = b[dp - 1];
                    if (std::isalnum(static_cast<unsigned char>(prev)) || prev == '_') return false;
                }
                std::size_t ep = dp + 7;
                if (ep < b.size() &&
                    (std::isalnum(static_cast<unsigned char>(b[ep])) || b[ep] == '_')) {
                    return false;
                }
                // Skip whitespace
                while (ep < b.size() && (b[ep] == ' ' || b[ep] == '\t')) ++ep;
                // Optional `(`
                bool openParen = (ep < b.size() && b[ep] == '(');
                if (openParen) {
                    ++ep;
                    while (ep < b.size() && (b[ep] == ' ' || b[ep] == '\t')) ++ep;
                }
                // Identifier
                std::size_t idStart = ep;
                while (ep < b.size() &&
                       (std::isalnum(static_cast<unsigned char>(b[ep])) || b[ep] == '_')) {
                    ++ep;
                }
                if (ep == idStart) return false;
                other = b.substr(idStart, ep - idStart);
                return true;
            };
            std::string other;
            if (matchDefined(body, other)) {
                // Determine if `other` is defined elsewhere in source.
                // Simple scan: look for `#define OTHER` as a whole word.
                auto isOtherDefined = [&](const std::string& s) {
                    std::size_t cursor = 0;
                    while (cursor < s.size()) {
                        std::size_t dp = s.find("#define", cursor);
                        if (dp == std::string::npos) return false;
                        std::size_t q = dp + 7;
                        while (q < s.size() && (s[q] == ' ' || s[q] == '\t')) ++q;
                        std::size_t nameStart2 = q;
                        while (q < s.size() &&
                               (std::isalnum(static_cast<unsigned char>(s[q])) || s[q] == '_')) {
                            ++q;
                        }
                        std::string name2 = s.substr(nameStart2, q - nameStart2);
                        if (name2 == other) return true;
                        cursor = dp + 1;
                    }
                    return false;
                };
                const char* replacement = isOtherDefined(src) ? "1" : "0";
                // Rewrite the body in-place.
                src.replace(bodyStart, bodyEnd - bodyStart, replacement);
                result.didRewrite = true;
                scan = bodyStart + std::strlen(replacement);
                continue;
            }
            scan = bodyEnd;
        }
    }

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

    // ---- 2b. Strip GL_ARB extension directives unknown to glslang ---------
    // Under Vulkan-targeted compilation, some GL_ARB extensions exist as
    // core features in Vulkan/SPIR-V but glslang's Vulkan front-end
    // doesn't register them as known extension names. The `#extension`
    // directive then fails with "extension not supported." Comment out
    // only those directives — extensions that glslang DOES recognize
    // (like GL_ARB_compute_shader, GL_ARB_shader_image_load_store) must
    // be kept so glslang enables the corresponding functionality.
    {
        static const char* const kUnknownExtensions[] = {
            "GL_ARB_cull_distance",
        };
        bool strippedCullDistance = false;
        for (const char* ext : kUnknownExtensions) {
            std::string needle = std::string("#extension ") + ext;
            std::size_t pos = 0;
            while ((pos = result.source.find(needle, pos)) != std::string::npos) {
                // Comment out the entire line by replacing `#extension`
                // with `// xtension` (same length to preserve offsets).
                result.source.replace(pos, 10, "// xtensio");
                result.didRewrite = true;
                pos += 10;
                if (std::string(ext) == "GL_ARB_cull_distance") {
                    strippedCullDistance = true;
                }
            }
        }
        // When we strip #extension GL_ARB_cull_distance, the built-in
        // constants `gl_MaxCullDistances` and `gl_MaxCombinedClipAndCullDistances`
        // that come with the extension also disappear from glslang's known
        // identifiers. CTS's cull_distance.coverage test uses those built-ins
        // directly in its shader body, causing "undeclared identifier" errors.
        // Inject compat const substitutes at the top of the source (after
        // the #version line) so the shader compiles and samples the minimum
        // values the GL 4.5 spec guarantees (both are 8 per §23.4).
        if (strippedCullDistance) {
            // Use #define rather than `const int` declarations — the shader
            // still has subsequent `#extension` directives (GL_ARB_compute_shader
            // etc.), and GLSL requires all #extensions to precede any regular
            // declarations. Preprocessor defines are safe to emit before them.
            // GL 4.5 spec §23.4 guarantees both values are at least 8.
            const std::string compatDefines =
                "\n#define gl_MaxCullDistances 8\n"
                "#define gl_MaxCombinedClipAndCullDistances 8\n";
            std::size_t versionPos = result.source.find("#version");
            if (versionPos != std::string::npos) {
                std::size_t eol = result.source.find('\n', versionPos);
                if (eol != std::string::npos) {
                    result.source.insert(eol + 1, compatDefines);
                }
            } else {
                result.source.insert(0, compatDefines);
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
    // ---- 3b. Unconditional CTS fixups — run before early-return ----------
    // `sampler` is used as a plain variable name in CTS shaders (e.g.
    // `uniform usampler2DArray sampler;`). glslang rejects it as a
    // reserved word. Rename unconditionally regardless of compat rewrite.
    bool didSamplerFixup = false;
    if (containsIdentifier(result.source, "sampler")) {
        replaceIdentifier(result.source, "sampler", "_appgl_sampler");
        didSamplerFixup = true;
    }
    // RC-D23: strip ESSL precision qualifiers on sampler types.
    {
        std::size_t searchPos = 0;
        while (true) {
            const std::size_t pIdx = result.source.find("precision", searchPos);
            if (pIdx == std::string::npos) break;
            if (pIdx > 0 && isIdentChar(result.source[pIdx - 1])) {
                searchPos = pIdx + 1;
                continue;
            }
            std::size_t eol = result.source.find('\n', pIdx);
            if (eol == std::string::npos) eol = result.source.size();
            const std::string_view line(result.source.data() + pIdx, eol - pIdx);
            if (line.find("sampler") != std::string_view::npos ||
                line.find("Sampler") != std::string_view::npos ||
                line.find("_appgl_sampler") != std::string_view::npos) {
                result.source.insert(pIdx, "//");
                searchPos = eol + 2;
                didSamplerFixup = true;
            } else {
                searchPos = eol;
            }
        }
    }

    if (!didAnyRewrite && !didSamplerFixup) {
        return result;
    }
    result.didRewrite = true;

    // ---- 4. Source-text rewrites -----------------------------------------
    // Order matters: each identifier replacement must not create text
    // that later passes would recognize as a rewrite target.
    //
    //   - `texture2D(` → `texture(` and `textureCube(` → `texture(`
    //     replace function names. Neither collides with the identifier
    //     rewrites that follow.
    //
    //   - `shadow2DProj(` → `appgl_shadow2DProj(` (Phase 8X Group 4d
    //     follow-up²¹). fw¹⁹ flat-renamed `shadow2DProj` to the core
    //     `textureProj`, which silently broke the return-type contract:
    //     legacy `shadow2DProj(sampler2DShadow, vec4)` returns `vec4`
    //     (the hardware compare result replicated across channels),
    //     but core-3.30 `textureProj(sampler2DShadow, vec4)` returns a
    //     plain `float`. Any chained `.r`/`.x`/`.a` access after the
    //     rename then gets rejected by glslang as "scalar swizzle :
    //     not supported" (fw²⁰-verification §4 pinned it in Spring's
    //     `ModelFragProg.glsl` `USE_SHADOWS == 1` branch). Instead,
    //     fw²¹ routes call sites to a synthesized preamble helper
    //     `appgl_shadow2DProj(sampler2DShadow, vec4) -> vec4` that
    //     wraps `textureProj` and broadcasts the scalar result into a
    //     vec4, preserving the legacy return-type contract end-to-end.
    //     The substitution is routed ahead of `texture2D → texture`
    //     so the prefix-match order stays consistent for anyone
    //     reading the rewrites top-to-bottom.
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
    // fw²¹ — `shadow2DProj` is renamed to the synthesized helper
    // `appgl_shadow2DProj` (emitted in preamble section 5h), NOT the
    // core `textureProj`. See the docblock above for why the flat
    // rename is semantically wrong (return-type contract break on
    // `sampler2DShadow`). Routed first so the substitution is obvious
    // when reading the rewrites top-to-bottom.
    if (legacy.rewroteShadow2DProj) {
        replaceIdentifier(result.source, "shadow2DProj",
                          "appgl_shadow2DProj");
    }
    if (legacy.rewroteTexture2D) {
        replaceIdentifier(result.source, "texture2D", "texture");
    }
    if (legacy.rewroteTextureCube) {
        replaceIdentifier(result.source, "textureCube", "texture");
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
    // Phase 8X Group 4d follow-up²⁰ — fragment-output consolidation.
    //
    // Some shader corpora (Spring's `ModelFragProg.glsl`) have both
    // `gl_FragData[]` and `gl_FragColor` lexically present in a
    // `#if DEFERRED_MODE == 1 / #else` split. The rewriter scans
    // pre-preprocessor source text, so both usage flags fire even
    // though only one branch is live in any given program variant.
    // fw¹⁹ emitted two separate `layout(location = 0) out` decls
    // (one for `appgl_FragColor`, one for `appgl_FragData[N+1]`),
    // which glslang rejects with `'location' : overlapping use of
    // location 0`. fw²⁰ consolidates: when both forms are observed,
    // rewrite `gl_FragColor` to `appgl_FragData[0]` and emit only
    // the single array declaration. GL aliases `gl_FragColor ≡
    // gl_FragData[0]` at the spec level (ARB_draw_buffers / core
    // compat profile), so the consolidation is semantically
    // lossless — whichever preprocessor branch is live writes to
    // color attachment 0 exactly the same way in both shapes.
    const bool dualFragOutput =
        isFragment && legacy.fragColor && legacy.fragDataMax >= 0;
    if (dualFragOutput) {
        // Order: rewrite `gl_FragColor` first so the resulting
        // `appgl_FragData[0]` substring is written into the source
        // before the `gl_FragData` → `appgl_FragData` pass. The
        // word-boundary replace below is safe either way (the left
        // boundary of the `gl_FragData` substring inside
        // `appgl_FragData` is the identifier char `_`, so the
        // replace is rejected), but the explicit ordering keeps the
        // intent obvious to the next reader.
        replaceIdentifier(result.source, "gl_FragColor",
                          "appgl_FragData[0]");
        replaceIdentifier(result.source, "gl_FragData", "appgl_FragData");
    } else if (legacy.fragColor) {
        replaceIdentifier(result.source, "gl_FragColor", "appgl_FragColor");
    } else if (legacy.fragDataMax >= 0) {
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

    // ---- 4b. CTS fixups — (moved to section 3b above for unconditional
    // execution; sampler rename and precision strip run even for modern
    // core-profile shaders that skip the compat rewrite path) -----------

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

    // 5c. fw¹⁹ / fw²⁰ — fragment output declarations.
    //
    // Three shapes, selected by the (fragColor, fragDataMax) pair:
    //   - fragColor only: single `appgl_FragColor` decl.
    //   - fragData only:  single `appgl_FragData[N+1]` array decl.
    //   - both (fw²⁰):    consolidate to a single `appgl_FragData[M]`
    //                     array decl, where M = max(fragDataMax + 1, 1)
    //                     so index 0 is always valid for the
    //                     rewritten `gl_FragColor` → `appgl_FragData[0]`.
    if (isFragment) {
        const bool dualFrag =
            legacy.fragColor && legacy.fragDataMax >= 0;
        if (dualFrag) {
            // Consolidated array. `gl_FragColor` was rewritten to
            // `appgl_FragData[0]` in the source-text pass above, so
            // the array must include index 0 whether or not the
            // original `gl_FragData[<lit>]` subscripts covered it.
            int count = legacy.fragDataMax + 1;
            if (count < 1) count = 1;
            char buf[160];
            std::snprintf(buf, sizeof(buf),
                          "layout(location = 0) out vec4 appgl_FragData[%d];\n",
                          count);
            preamble.append(buf);
        } else if (legacy.fragColor) {
            preamble.append(
                "layout(location = 0) out vec4 appgl_FragColor;\n");
        } else if (legacy.fragDataMax >= 0) {
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

    // 5h. fw²¹ — `shadow2DProj` helper-function synthesis.
    //
    // Spring's `ModelFragProg.glsl` (ShadowedStandard / ShadowedDeferred
    // variants) calls `shadow2DProj(shadowTex, shadowVertexPos).r` on
    // a `sampler2DShadow`. Legacy `shadow2DProj` returns a `vec4` —
    // the hardware depth-compare result replicated across all four
    // channels — so the `.r` swizzle is legal under `#version 120`.
    // Core-3.30 `textureProj` on `sampler2DShadow` returns a scalar
    // `float` instead, so after fw¹⁹'s flat `shadow2DProj → textureProj`
    // rename, glslang hit `ERROR: 0:34: 'scalar swizzle' : not supported
    // for this version or the enabled extensions` on the two Shadowed*
    // variants (fw²⁰-verification §4).
    //
    // The fix is a thin preamble wrapper with the legacy return type:
    //
    //     vec4 appgl_shadow2DProj(sampler2DShadow s, vec4 p) {
    //         float v = textureProj(s, p);
    //         return vec4(v, v, v, v);
    //     }
    //
    // Call sites rewritten by section 4 now resolve to a genuine vec4,
    // so chained `.r`/`.x`/`.a` accesses continue to type-check. The
    // hardware depth compare still runs once per call — broadcasting a
    // scalar through a vec4 constructor is a no-op on Metal.
    //
    // Only `shadow2DProj` is observed in BAR's shader corpus this
    // round, so only that overload is synthesized. The sibling
    // legacy shadow overloads (`shadow2D` / `shadow2DLod` /
    // `shadow2DProjLod` / `shadowCube`) have the identical
    // return-type contract gap and would each be a ~5-line addition
    // to this block if they surface in a future round.
    if (legacy.rewroteShadow2DProj) {
        preamble.append(
            "vec4 appgl_shadow2DProj(sampler2DShadow s, vec4 p) {\n"
            "    float v = textureProj(s, p);\n"
            "    return vec4(v, v, v, v);\n"
            "}\n");
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

// ============================================================================
// Struct-member qualifier validation
// ============================================================================
// GLSL 4.60 §4.1.8: Only precision qualifiers (highp / mediump / lowp)
// are permitted on struct members. Glslang configured with Vulkan rules
// (as we do for SPIR-V generation) silently accepts forbidden qualifiers
// such as `layout(shared)`, `shared`, `coherent`, etc. CTS
// `shaders.negative.non_precision_qualifiers_in_struct_members` verifies
// the rule by deliberately submitting offending shaders and expecting
// `glGetShaderiv(GL_COMPILE_STATUS)` to return `GL_FALSE`. We run this
// pre-scan before handing the source to glslang so the compile fails
// with a spec-correct diagnostic.
//
// Approach:
//   1. Strip comments (line and block).
//   2. Walk character-by-character looking for the keyword `struct`
//      preceded and followed by non-identifier characters.
//   3. After `struct` consume an optional identifier then expect `{`.
//      (The unnamed `struct { ... }` form is also valid GLSL.)
//   4. Within the brace-balanced body, split by `;` to get member
//      declarations.
//   5. Tokenize each member declaration. Any leading token that is a
//      forbidden qualifier — or a `layout(...)` prefix — is a compile
//      error. The first such qualifier is reported.
bool validateStructMemberQualifiers(std::string_view source,
                                    std::string& errorMessage) {
    // ---- Step 1: strip comments --------------------------------------
    std::string code;
    code.reserve(source.size());
    for (std::size_t i = 0; i < source.size(); ) {
        if (i + 1 < source.size() && source[i] == '/' && source[i + 1] == '/') {
            // Line comment — consume until newline (keep the newline so
            // line-count is preserved for error reporting).
            while (i < source.size() && source[i] != '\n') {
                code.push_back(' ');  // replace with spaces to preserve column
                ++i;
            }
        } else if (i + 1 < source.size() && source[i] == '/' && source[i + 1] == '*') {
            // Block comment — consume until */. Preserve newlines so
            // line numbers in diagnostics stay stable.
            i += 2;
            while (i + 1 < source.size() && !(source[i] == '*' && source[i + 1] == '/')) {
                code.push_back(source[i] == '\n' ? '\n' : ' ');
                ++i;
            }
            if (i + 1 < source.size()) i += 2;  // skip */
        } else {
            code.push_back(source[i]);
            ++i;
        }
    }

    // ---- Step 2-5: scan for struct { ... } and validate members ------
    auto isIdent = [](unsigned char c) {
        return std::isalnum(c) || c == '_';
    };
    auto skipWs = [&](std::size_t& p) {
        while (p < code.size() && std::isspace(static_cast<unsigned char>(code[p]))) {
            ++p;
        }
    };
    auto readIdent = [&](std::size_t& p) -> std::string {
        skipWs(p);
        std::size_t start = p;
        while (p < code.size() && isIdent(static_cast<unsigned char>(code[p]))) {
            ++p;
        }
        return code.substr(start, p - start);
    };
    auto countLines = [&](std::size_t end) -> int {
        int n = 1;
        for (std::size_t i = 0; i < end && i < code.size(); ++i) {
            if (code[i] == '\n') ++n;
        }
        return n;
    };

    // Forbidden qualifier keywords. Precision qualifiers (highp, mediump,
    // lowp) are NOT in this set because they are the only qualifiers
    // permitted on struct members.
    static const std::unordered_set<std::string> kForbidden = {
        // Storage qualifiers
        "const", "in", "out", "attribute", "uniform", "varying",
        "buffer", "shared",
        // Interpolation qualifiers
        "smooth", "flat", "noperspective", "centroid", "sample",
        "patch",
        // Invariant / precise
        "invariant", "precise",
        // Memory qualifiers
        "coherent", "volatile", "restrict", "readonly", "writeonly",
    };

    const std::string kw = "struct";

    std::size_t pos = 0;
    while (pos < code.size()) {
        std::size_t sp = code.find(kw, pos);
        if (sp == std::string::npos) break;

        // Word-boundary check
        bool leftOk = (sp == 0) ||
                      !isIdent(static_cast<unsigned char>(code[sp - 1]));
        std::size_t endKw = sp + kw.size();
        bool rightOk = (endKw >= code.size()) ||
                       !isIdent(static_cast<unsigned char>(code[endKw]));
        if (!leftOk || !rightOk) {
            pos = sp + 1;
            continue;
        }

        std::size_t p = endKw;
        skipWs(p);
        // Optional identifier (struct name). The identifier might be
        // absent for an anonymous struct `struct { ... } x;`.
        (void)readIdent(p);
        skipWs(p);

        if (p >= code.size() || code[p] != '{') {
            // Not a struct definition body — could be a forward
            // declaration `struct Foo;` or a type reference in a
            // declaration `struct Foo f;`. Skip.
            pos = sp + 1;
            continue;
        }

        // Find matching close brace
        ++p;  // past '{'
        std::size_t bodyStart = p;
        int depth = 1;
        while (p < code.size() && depth > 0) {
            if (code[p] == '{') ++depth;
            else if (code[p] == '}') --depth;
            ++p;
        }
        if (depth != 0) break;  // unbalanced — let glslang report it
        std::size_t bodyEnd = p - 1;  // position of the matching '}'
        std::string body = code.substr(bodyStart, bodyEnd - bodyStart);

        // Split body by ';' (at depth 0 — members can use [] but not
        // nested braces in the declarator expressions we care about).
        std::size_t memStart = 0;
        while (memStart < body.size()) {
            std::size_t semi = body.find(';', memStart);
            if (semi == std::string::npos) break;
            std::string member = body.substr(memStart, semi - memStart);
            memStart = semi + 1;

            // Tokenize leading tokens: we only care about tokens BEFORE
            // the type. A "type" is the first identifier that is not a
            // known qualifier and not `layout`. The scan stops at the
            // first recognized-qualifier hit.
            std::size_t q = 0;
            auto skipWsM = [&](std::size_t& qq) {
                while (qq < member.size() &&
                       std::isspace(static_cast<unsigned char>(member[qq]))) {
                    ++qq;
                }
            };
            skipWsM(q);
            while (q < member.size()) {
                // Handle `layout(...)` token explicitly.
                if (q + 6 <= member.size() &&
                    member.compare(q, 6, "layout") == 0 &&
                    (q + 6 == member.size() ||
                     !isIdent(static_cast<unsigned char>(member[q + 6])))) {
                    // Find end of layout() parenthesis
                    std::size_t lp = q + 6;
                    skipWsM(lp);
                    // Assemble the reported qualifier — e.g.
                    // `layout(shared)`.
                    std::string reported = "layout";
                    if (lp < member.size() && member[lp] == '(') {
                        int pd = 1;
                        ++lp;
                        std::string inner;
                        while (lp < member.size() && pd > 0) {
                            if (member[lp] == '(') ++pd;
                            else if (member[lp] == ')') {
                                --pd;
                                if (pd == 0) break;
                            }
                            inner.push_back(member[lp]);
                            ++lp;
                        }
                        reported = "layout(" + inner + ")";
                    }
                    int line = countLines(bodyStart + memStart -
                                          (semi - (q)));  // rough
                    (void)line;
                    errorMessage =
                        "ERROR: 0:0: '" + reported +
                        "' : struct members cannot have layout qualifiers";
                    return false;
                }

                // Read next identifier token
                std::size_t idStart = q;
                while (q < member.size() &&
                       isIdent(static_cast<unsigned char>(member[q]))) {
                    ++q;
                }
                if (q == idStart) {
                    // Non-identifier character — bail, the rest is the
                    // type / declarator.
                    break;
                }
                std::string tok = member.substr(idStart, q - idStart);
                if (kForbidden.count(tok) != 0) {
                    errorMessage =
                        "ERROR: 0:0: '" + tok +
                        "' : struct members cannot have non-precision qualifiers";
                    return false;
                }
                // Not a forbidden qualifier. If it's also not `highp` /
                // `mediump` / `lowp`, treat it as the start of the type
                // and stop scanning this member.
                if (tok != "highp" && tok != "mediump" && tok != "lowp") {
                    break;
                }
                skipWsM(q);
            }
        }

        pos = p;  // continue after the struct body
    }

    errorMessage.clear();
    return true;
}

}  // namespace appgl
