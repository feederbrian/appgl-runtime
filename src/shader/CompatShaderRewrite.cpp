#include "CompatShaderRewrite.h"

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

// Locate the first `#version` directive and the index just past its
// terminating newline. Returns string::npos on failure.
//
// `outVersionStart` (when non-null) receives the offset of the `#`
// character. The caller uses this to scan the version line for the
// `compatibility` token.
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

}  // namespace

CompatShaderRewriteResult rewriteCompatShader(std::string_view source) {
    CompatShaderRewriteResult result;
    result.source.assign(source.begin(), source.end());

    // ---- 1. Identifier scan ----------------------------------------------
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

    // ---- 2. Version line — compat → core rewrite -------------------------
    std::size_t versionStart = std::string::npos;
    std::size_t versionEol = findVersionLineEnd(result.source, &versionStart);
    if (versionEol != std::string::npos) {
        const std::string_view versionLine(
            result.source.data() + versionStart, versionEol - versionStart);
        if (containsIdentifier(versionLine, "compatibility")) {
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
    // We inject when EITHER the original source was compat profile (so
    // the version downgrade alone is observable in `result.didRewrite`)
    // OR any matrix identifier was used (so the synthesized uniforms have
    // somewhere to go). The latter case also handles core-profile shaders
    // that accidentally reference legacy identifiers — we still synthesize
    // the uniforms so glslang stops choking on them.
    const bool needPreamble = result.usage.any();
    const bool didAnyRewrite = result.wasCompatProfile || needPreamble;
    if (!didAnyRewrite) {
        return result;
    }
    result.didRewrite = true;

    // ---- 4. Build preamble -----------------------------------------------
    std::string preamble;
    preamble.reserve(1024);

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

    // ---- 5. Inject preamble ----------------------------------------------
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
