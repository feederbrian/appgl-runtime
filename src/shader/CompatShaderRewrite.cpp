#include "CompatShaderRewrite.h"

#include "../runtime/AppGLProfile.h"

#include <AppGL/AppGL.h>

#include <cctype>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_set>
#include <vector>

namespace appgl {

namespace {

std::string maskCommentsAndStrings(std::string_view source);
std::string_view trimAscii(std::string_view text);

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

bool replaceFunctionIdentifier(std::string& src,
                               std::string_view from,
                               std::string_view to) {
    bool didReplace = false;
    std::size_t pos = 0;
    while (true) {
        const std::size_t found = src.find(from, pos);
        if (found == std::string::npos) {
            return didReplace;
        }
        const bool leftOk = (found == 0) || !isIdentChar(src[found - 1]);
        const std::size_t end = found + from.size();
        const bool rightOk = (end >= src.size()) || !isIdentChar(src[end]);
        if (!leftOk || !rightOk) {
            pos = found + 1;
            continue;
        }
        std::size_t call = end;
        while (call < src.size() &&
               std::isspace(static_cast<unsigned char>(src[call]))) {
            ++call;
        }
        if (call < src.size() && src[call] == '(') {
            src.replace(found, from.size(), to);
            didReplace = true;
            pos = found + to.size();
        } else {
            pos = found + 1;
        }
    }
}

bool isPreprocessorDirectiveLine(const std::string& src, std::size_t pos) {
    std::size_t lineStart = src.rfind('\n', pos);
    lineStart = (lineStart == std::string::npos) ? 0 : lineStart + 1;
    while (lineStart < src.size() &&
           (src[lineStart] == ' ' || src[lineStart] == '\t' ||
            src[lineStart] == '\r')) {
        ++lineStart;
    }
    return lineStart < src.size() && src[lineStart] == '#';
}

std::size_t skipPreprocessorDirective(const std::string& src,
                                      std::size_t pos) {
    while (pos < src.size()) {
        std::size_t eol = src.find('\n', pos);
        if (eol == std::string::npos) {
            return src.size();
        }
        std::size_t last = eol;
        while (last > pos &&
               (src[last - 1] == ' ' || src[last - 1] == '\t' ||
                src[last - 1] == '\r')) {
            --last;
        }
        const bool continued = last > pos && src[last - 1] == '\\';
        pos = eol + 1;
        if (!continued) {
            return pos;
        }
    }
    return pos;
}

std::size_t skipStringLiteral(const std::string& src, std::size_t pos) {
    const char quote = src[pos];
    ++pos;
    while (pos < src.size()) {
        if (src[pos] == '\\' && pos + 1 < src.size()) {
            pos += 2;
            continue;
        }
        if (src[pos] == quote) {
            return pos + 1;
        }
        ++pos;
    }
    return pos;
}

std::size_t skipLineComment(const std::string& src, std::size_t pos) {
    const std::size_t eol = src.find('\n', pos);
    return (eol == std::string::npos) ? src.size() : eol + 1;
}

std::size_t skipBlockComment(const std::string& src, std::size_t pos) {
    const std::size_t end = src.find("*/", pos + 2);
    return (end == std::string::npos) ? src.size() : end + 2;
}

bool containsCodeIdentifier(const std::string& src, std::string_view needle) {
    if (needle.empty() || src.size() < needle.size()) {
        return false;
    }
    std::size_t pos = 0;
    while (pos < src.size()) {
        if (isPreprocessorDirectiveLine(src, pos)) {
            pos = skipPreprocessorDirective(src, pos);
            continue;
        }
        if (src.compare(pos, 2, "//") == 0) {
            pos = skipLineComment(src, pos);
            continue;
        }
        if (src.compare(pos, 2, "/*") == 0) {
            pos = skipBlockComment(src, pos);
            continue;
        }
        if (src[pos] == '"' || src[pos] == '\'') {
            pos = skipStringLiteral(src, pos);
            continue;
        }
        if (src.compare(pos, needle.size(), needle) == 0) {
            const bool leftOk = (pos == 0) || !isIdentChar(src[pos - 1]);
            const std::size_t end = pos + needle.size();
            const bool rightOk =
                (end >= src.size()) || !isIdentChar(src[end]);
            if (leftOk && rightOk) {
                return true;
            }
        }
        ++pos;
    }
    return false;
}

bool replaceCodeIdentifier(std::string& src,
                           std::string_view from,
                           std::string_view to) {
    bool didReplace = false;
    std::size_t pos = 0;
    while (pos < src.size()) {
        if (isPreprocessorDirectiveLine(src, pos)) {
            pos = skipPreprocessorDirective(src, pos);
            continue;
        }
        if (src.compare(pos, 2, "//") == 0) {
            pos = skipLineComment(src, pos);
            continue;
        }
        if (src.compare(pos, 2, "/*") == 0) {
            pos = skipBlockComment(src, pos);
            continue;
        }
        if (src[pos] == '"' || src[pos] == '\'') {
            pos = skipStringLiteral(src, pos);
            continue;
        }
        if (src.compare(pos, from.size(), from) == 0) {
            const bool leftOk = (pos == 0) || !isIdentChar(src[pos - 1]);
            const std::size_t end = pos + from.size();
            const bool rightOk =
                (end >= src.size()) || !isIdentChar(src[end]);
            if (leftOk && rightOk) {
                src.replace(pos, from.size(), to);
                didReplace = true;
                pos += to.size();
                continue;
            }
        }
        ++pos;
    }
    return didReplace;
}

std::size_t findCodeFunctionIdentifier(const std::string& src,
                                       std::string_view name,
                                       std::size_t pos = 0) {
    while (pos < src.size()) {
        if (isPreprocessorDirectiveLine(src, pos)) {
            pos = skipPreprocessorDirective(src, pos);
            continue;
        }
        if (src.compare(pos, 2, "//") == 0) {
            pos = skipLineComment(src, pos);
            continue;
        }
        if (src.compare(pos, 2, "/*") == 0) {
            pos = skipBlockComment(src, pos);
            continue;
        }
        if (src[pos] == '"' || src[pos] == '\'') {
            pos = skipStringLiteral(src, pos);
            continue;
        }
        if (src.compare(pos, name.size(), name) != 0) {
            ++pos;
            continue;
        }
        const bool leftOk = (pos == 0) || !isIdentChar(src[pos - 1]);
        const std::size_t end = pos + name.size();
        const bool rightOk =
            (end >= src.size()) || !isIdentChar(src[end]);
        if (!leftOk || !rightOk) {
            ++pos;
            continue;
        }
        std::size_t call = end;
        while (call < src.size() &&
               std::isspace(static_cast<unsigned char>(src[call]))) {
            ++call;
        }
        if (call < src.size() && src[call] == '(') {
            return pos;
        }
        ++pos;
    }
    return std::string::npos;
}

bool containsCodeFunctionIdentifier(const std::string& src,
                                    std::string_view name) {
    return findCodeFunctionIdentifier(src, name) != std::string::npos;
}

bool replaceCodeFunctionIdentifier(std::string& src,
                                   std::string_view from,
                                   std::string_view to) {
    bool didReplace = false;
    std::size_t pos = 0;
    while (true) {
        const std::size_t found =
            findCodeFunctionIdentifier(src, from, pos);
        if (found == std::string::npos) {
            return didReplace;
        }
        src.replace(found, from.size(), to);
        didReplace = true;
        pos = found + to.size();
    }
}

bool replaceCodeUnsignedInt(std::string& src) {
    static constexpr std::string_view kUnsigned = "unsigned";
    static constexpr std::string_view kInt = "int";
    bool didReplace = false;
    std::size_t pos = 0;
    while (pos < src.size()) {
        if (isPreprocessorDirectiveLine(src, pos)) {
            pos = skipPreprocessorDirective(src, pos);
            continue;
        }
        if (src.compare(pos, 2, "//") == 0) {
            pos = skipLineComment(src, pos);
            continue;
        }
        if (src.compare(pos, 2, "/*") == 0) {
            pos = skipBlockComment(src, pos);
            continue;
        }
        if (src[pos] == '"' || src[pos] == '\'') {
            pos = skipStringLiteral(src, pos);
            continue;
        }
        if (src.compare(pos, kUnsigned.size(), kUnsigned) != 0) {
            ++pos;
            continue;
        }
        const bool leftOk = (pos == 0) || !isIdentChar(src[pos - 1]);
        const std::size_t unsignedEnd = pos + kUnsigned.size();
        const bool unsignedRightOk =
            (unsignedEnd >= src.size()) || !isIdentChar(src[unsignedEnd]);
        if (!leftOk || !unsignedRightOk) {
            ++pos;
            continue;
        }
        std::size_t intStart = unsignedEnd;
        while (intStart < src.size() &&
               (src[intStart] == ' ' || src[intStart] == '\t' ||
                src[intStart] == '\r')) {
            ++intStart;
        }
        if (intStart == unsignedEnd ||
            src.compare(intStart, kInt.size(), kInt) != 0) {
            pos = unsignedEnd;
            continue;
        }
        const std::size_t intEnd = intStart + kInt.size();
        const bool intRightOk =
            (intEnd >= src.size()) || !isIdentChar(src[intEnd]);
        if (!intRightOk) {
            pos = unsignedEnd;
            continue;
        }
        src.replace(pos, intEnd - pos, "uint");
        didReplace = true;
        pos += std::strlen("uint");
    }
    return didReplace;
}

struct GpuShader4ShadowWrapper {
    const char* legacyName;
    const char* helperName;
    const char* commonSource;
    const char* fragmentSource;
    bool coreLegacyWithoutGpuShader4 = false;
};

static const GpuShader4ShadowWrapper kGpuShader4ShadowWrappers[] = {
    {
        "shadow1D",
        "appgl_gpu_shader4_shadow1D",
        "vec4 appgl_gpu_shader4_shadow1D(sampler1DShadow s, vec3 p) {\n"
        "    return vec4(vec3(texture(s, p)), 1.0);\n"
        "}\n",
        "vec4 appgl_gpu_shader4_shadow1D(sampler1DShadow s, vec3 p, float bias) {\n"
        "    return vec4(vec3(texture(s, p, bias)), 1.0);\n"
        "}\n",
        true,
    },
    {
        "shadow2D",
        "appgl_gpu_shader4_shadow2D",
        "vec4 appgl_gpu_shader4_shadow2D(sampler2DShadow s, vec3 p) {\n"
        "    return vec4(vec3(texture(s, p)), 1.0);\n"
        "}\n",
        "vec4 appgl_gpu_shader4_shadow2D(sampler2DShadow s, vec3 p, float bias) {\n"
        "    return vec4(vec3(texture(s, p, bias)), 1.0);\n"
        "}\n",
        true,
    },
    {
        "shadowCube",
        "appgl_gpu_shader4_shadowCube",
        "vec4 appgl_gpu_shader4_shadowCube(samplerCubeShadow s, vec4 p) {\n"
        "    return vec4(texture(s, p));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow1DProj",
        "appgl_gpu_shader4_shadow1DProj",
        "vec4 appgl_gpu_shader4_shadow1DProj(sampler1DShadow s, vec4 p) {\n"
        "    return vec4(textureProjLod(s, p, 0.0));\n"
        "}\n",
        "vec4 appgl_gpu_shader4_shadow1DProj(sampler1DShadow s, vec4 p, float bias) {\n"
        "    return vec4(textureProj(s, p, bias));\n"
        "}\n",
    },
    {
        "shadow2DProj",
        "appgl_gpu_shader4_shadow2DProj",
        "vec4 appgl_gpu_shader4_shadow2DProj(sampler2DShadow s, vec4 p) {\n"
        "    return vec4(textureProjLod(s, p, 0.0));\n"
        "}\n",
        "vec4 appgl_gpu_shader4_shadow2DProj(sampler2DShadow s, vec4 p, float bias) {\n"
        "    return vec4(textureProj(s, p, bias));\n"
        "}\n",
    },
    {
        "shadow1DOffset",
        "appgl_gpu_shader4_shadow1DOffset",
        "vec4 appgl_gpu_shader4_shadow1DOffset(sampler1DShadow s, vec3 p, int offset) {\n"
        "    return vec4(textureLod(s, p, 0.0));\n"
        "}\n",
        "vec4 appgl_gpu_shader4_shadow1DOffset(sampler1DShadow s, vec3 p, int offset, float bias) {\n"
        "    return vec4(texture(s, p, bias));\n"
        "}\n",
    },
    {
        "shadow2DOffset",
        "appgl_gpu_shader4_shadow2DOffset",
        "vec4 appgl_gpu_shader4_shadow2DOffset(sampler2DShadow s, vec3 p, ivec2 offset) {\n"
        "    return vec4(textureLod(s, p, 0.0));\n"
        "}\n",
        "vec4 appgl_gpu_shader4_shadow2DOffset(sampler2DShadow s, vec3 p, ivec2 offset, float bias) {\n"
        "    return vec4(texture(s, p, bias));\n"
        "}\n",
    },
    {
        "shadow1DProjOffset",
        "appgl_gpu_shader4_shadow1DProjOffset",
        "vec4 appgl_gpu_shader4_shadow1DProjOffset(sampler1DShadow s, vec4 p, int offset) {\n"
        "    return vec4(textureProjLod(s, p, 0.0));\n"
        "}\n",
        "vec4 appgl_gpu_shader4_shadow1DProjOffset(sampler1DShadow s, vec4 p, int offset, float bias) {\n"
        "    return vec4(textureProj(s, p, bias));\n"
        "}\n",
    },
    {
        "shadow2DProjOffset",
        "appgl_gpu_shader4_shadow2DProjOffset",
        "vec4 appgl_gpu_shader4_shadow2DProjOffset(sampler2DShadow s, vec4 p, ivec2 offset) {\n"
        "    return vec4(textureProjLod(s, p, 0.0));\n"
        "}\n",
        "vec4 appgl_gpu_shader4_shadow2DProjOffset(sampler2DShadow s, vec4 p, ivec2 offset, float bias) {\n"
        "    return vec4(textureProj(s, p, bias));\n"
        "}\n",
    },
    {
        "shadow1DArray",
        "appgl_gpu_shader4_shadow1DArray",
        "vec4 appgl_gpu_shader4_shadow1DArray(sampler1DArrayShadow s, vec3 p) {\n"
        "    return vec4(texture(s, p));\n"
        "}\n",
        "vec4 appgl_gpu_shader4_shadow1DArray(sampler1DArrayShadow s, vec3 p, float bias) {\n"
        "    return vec4(texture(s, p, bias));\n"
        "}\n",
    },
    {
        "shadow2DArray",
        "appgl_gpu_shader4_shadow2DArray",
        "vec4 appgl_gpu_shader4_shadow2DArray(sampler2DArrayShadow s, vec4 p) {\n"
        "    return vec4(texture(s, p));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DRect",
        "appgl_gpu_shader4_shadow2DRect",
        "vec4 appgl_gpu_shader4_shadow2DRect(sampler2DRectShadow s, vec3 p) {\n"
        "    return vec4(texture(s, p));\n"
        "}\n",
        nullptr,
        // ARB_texture_rectangle (not just EXT_gpu_shader4) adds this builtin
        // to GLSL 1.10/1.20, so it has to be wrapped on the plain legacy path
        // as well — see the sibling comment on `isLegacyDesktopTextureAlias`.
        true,
    },
    {
        "shadow2DRectProj",
        "appgl_gpu_shader4_shadow2DRectProj",
        "vec4 appgl_gpu_shader4_shadow2DRectProj(sampler2DRectShadow s, vec4 p) {\n"
        "    return vec4(textureProj(s, p));\n"
        "}\n",
        nullptr,
        true,
    },
    {
        "shadow1DArrayOffset",
        "appgl_gpu_shader4_shadow1DArrayOffset",
        "vec4 appgl_gpu_shader4_shadow1DArrayOffset(sampler1DArrayShadow s, vec3 p, int offset) {\n"
        "    return vec4(texture(s, p));\n"
        "}\n",
        "vec4 appgl_gpu_shader4_shadow1DArrayOffset(sampler1DArrayShadow s, vec3 p, int offset, float bias) {\n"
        "    return vec4(texture(s, p, bias));\n"
        "}\n",
    },
    {
        "shadow2DArrayOffset",
        "appgl_gpu_shader4_shadow2DArrayOffset",
        "vec4 appgl_gpu_shader4_shadow2DArrayOffset(sampler2DArrayShadow s, vec4 p, ivec2 offset) {\n"
        "    return vec4(texture(s, p));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DRectOffset",
        "appgl_gpu_shader4_shadow2DRectOffset",
        "vec4 appgl_gpu_shader4_shadow2DRectOffset(sampler2DRectShadow s, vec3 p, ivec2 offset) {\n"
        "    return vec4(texture(s, p));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DRectProjOffset",
        "appgl_gpu_shader4_shadow2DRectProjOffset",
        "vec4 appgl_gpu_shader4_shadow2DRectProjOffset(sampler2DRectShadow s, vec4 p, ivec2 offset) {\n"
        "    return vec4(textureProj(s, p));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow1DLod",
        "appgl_gpu_shader4_shadow1DLod",
        "vec4 appgl_gpu_shader4_shadow1DLod(sampler1DShadow s, vec3 p, float lod) {\n"
        "    return vec4(textureLod(s, p, lod));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DLod",
        "appgl_gpu_shader4_shadow2DLod",
        "vec4 appgl_gpu_shader4_shadow2DLod(sampler2DShadow s, vec3 p, float lod) {\n"
        "    return vec4(textureLod(s, p, lod));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow1DProjLod",
        "appgl_gpu_shader4_shadow1DProjLod",
        "vec4 appgl_gpu_shader4_shadow1DProjLod(sampler1DShadow s, vec4 p, float lod) {\n"
        "    return vec4(textureProjLod(s, p, lod));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DProjLod",
        "appgl_gpu_shader4_shadow2DProjLod",
        "vec4 appgl_gpu_shader4_shadow2DProjLod(sampler2DShadow s, vec4 p, float lod) {\n"
        "    return vec4(textureProjLod(s, p, lod));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow1DLodOffset",
        "appgl_gpu_shader4_shadow1DLodOffset",
        "vec4 appgl_gpu_shader4_shadow1DLodOffset(sampler1DShadow s, vec3 p, float lod, int offset) {\n"
        "    return vec4(textureLod(s, p, lod));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DLodOffset",
        "appgl_gpu_shader4_shadow2DLodOffset",
        "vec4 appgl_gpu_shader4_shadow2DLodOffset(sampler2DShadow s, vec3 p, float lod, ivec2 offset) {\n"
        "    return vec4(textureLod(s, p, lod));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow1DProjLodOffset",
        "appgl_gpu_shader4_shadow1DProjLodOffset",
        "vec4 appgl_gpu_shader4_shadow1DProjLodOffset(sampler1DShadow s, vec4 p, float lod, int offset) {\n"
        "    return vec4(textureProjLod(s, p, lod));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DProjLodOffset",
        "appgl_gpu_shader4_shadow2DProjLodOffset",
        "vec4 appgl_gpu_shader4_shadow2DProjLodOffset(sampler2DShadow s, vec4 p, float lod, ivec2 offset) {\n"
        "    return vec4(textureProjLod(s, p, lod));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow1DArrayLod",
        "appgl_gpu_shader4_shadow1DArrayLod",
        "vec4 appgl_gpu_shader4_shadow1DArrayLod(sampler1DArrayShadow s, vec3 p, float lod) {\n"
        "    return vec4(textureLod(s, p, lod));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow1DArrayLodOffset",
        "appgl_gpu_shader4_shadow1DArrayLodOffset",
        "vec4 appgl_gpu_shader4_shadow1DArrayLodOffset(sampler1DArrayShadow s, vec3 p, float lod, int offset) {\n"
        "    return vec4(textureLod(s, p, lod));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow1DGrad",
        "appgl_gpu_shader4_shadow1DGrad",
        "vec4 appgl_gpu_shader4_shadow1DGrad(sampler1DShadow s, vec3 p, float dPdx, float dPdy) {\n"
        "    return vec4(textureGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow1DProjGrad",
        "appgl_gpu_shader4_shadow1DProjGrad",
        "vec4 appgl_gpu_shader4_shadow1DProjGrad(sampler1DShadow s, vec4 p, float dPdx, float dPdy) {\n"
        "    return vec4(textureProjGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DGrad",
        "appgl_gpu_shader4_shadow2DGrad",
        "vec4 appgl_gpu_shader4_shadow2DGrad(sampler2DShadow s, vec3 p, vec2 dPdx, vec2 dPdy) {\n"
        "    return vec4(textureGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DProjGrad",
        "appgl_gpu_shader4_shadow2DProjGrad",
        "vec4 appgl_gpu_shader4_shadow2DProjGrad(sampler2DShadow s, vec4 p, vec2 dPdx, vec2 dPdy) {\n"
        "    return vec4(textureProjGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadowCubeGrad",
        "appgl_gpu_shader4_shadowCubeGrad",
        "vec4 appgl_gpu_shader4_shadowCubeGrad(samplerCubeShadow s, vec4 p, vec3 dPdx, vec3 dPdy) {\n"
        "    return vec4(textureGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow1DGradOffset",
        "appgl_gpu_shader4_shadow1DGradOffset",
        "vec4 appgl_gpu_shader4_shadow1DGradOffset(sampler1DShadow s, vec3 p, float dPdx, float dPdy, int offset) {\n"
        "    return vec4(textureGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow1DProjGradOffset",
        "appgl_gpu_shader4_shadow1DProjGradOffset",
        "vec4 appgl_gpu_shader4_shadow1DProjGradOffset(sampler1DShadow s, vec4 p, float dPdx, float dPdy, int offset) {\n"
        "    return vec4(textureProjGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DGradOffset",
        "appgl_gpu_shader4_shadow2DGradOffset",
        "vec4 appgl_gpu_shader4_shadow2DGradOffset(sampler2DShadow s, vec3 p, vec2 dPdx, vec2 dPdy, ivec2 offset) {\n"
        "    return vec4(textureGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DProjGradOffset",
        "appgl_gpu_shader4_shadow2DProjGradOffset",
        "vec4 appgl_gpu_shader4_shadow2DProjGradOffset(sampler2DShadow s, vec4 p, vec2 dPdx, vec2 dPdy, ivec2 offset) {\n"
        "    return vec4(textureProjGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow1DArrayGrad",
        "appgl_gpu_shader4_shadow1DArrayGrad",
        "vec4 appgl_gpu_shader4_shadow1DArrayGrad(sampler1DArrayShadow s, vec3 p, float dPdx, float dPdy) {\n"
        "    return vec4(textureGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DArrayGrad",
        "appgl_gpu_shader4_shadow2DArrayGrad",
        "vec4 appgl_gpu_shader4_shadow2DArrayGrad(sampler2DArrayShadow s, vec4 p, vec2 dPdx, vec2 dPdy) {\n"
        "    return vec4(textureGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DRectGrad",
        "appgl_gpu_shader4_shadow2DRectGrad",
        "vec4 appgl_gpu_shader4_shadow2DRectGrad(sampler2DRectShadow s, vec3 p, vec2 dPdx, vec2 dPdy) {\n"
        "    return vec4(textureGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DRectProjGrad",
        "appgl_gpu_shader4_shadow2DRectProjGrad",
        "vec4 appgl_gpu_shader4_shadow2DRectProjGrad(sampler2DRectShadow s, vec4 p, vec2 dPdx, vec2 dPdy) {\n"
        "    return vec4(textureProjGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow1DArrayGradOffset",
        "appgl_gpu_shader4_shadow1DArrayGradOffset",
        "vec4 appgl_gpu_shader4_shadow1DArrayGradOffset(sampler1DArrayShadow s, vec3 p, float dPdx, float dPdy, int offset) {\n"
        "    return vec4(textureGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DArrayGradOffset",
        "appgl_gpu_shader4_shadow2DArrayGradOffset",
        "vec4 appgl_gpu_shader4_shadow2DArrayGradOffset(sampler2DArrayShadow s, vec4 p, vec2 dPdx, vec2 dPdy, ivec2 offset) {\n"
        "    return vec4(textureGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DRectGradOffset",
        "appgl_gpu_shader4_shadow2DRectGradOffset",
        "vec4 appgl_gpu_shader4_shadow2DRectGradOffset(sampler2DRectShadow s, vec3 p, vec2 dPdx, vec2 dPdy, ivec2 offset) {\n"
        "    return vec4(textureGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
    {
        "shadow2DRectProjGradOffset",
        "appgl_gpu_shader4_shadow2DRectProjGradOffset",
        "vec4 appgl_gpu_shader4_shadow2DRectProjGradOffset(sampler2DRectShadow s, vec4 p, vec2 dPdx, vec2 dPdy, ivec2 offset) {\n"
        "    return vec4(textureProjGrad(s, p, dPdx, dPdy));\n"
        "}\n",
        nullptr,
    },
};

struct GpuShader4TextureAlias {
    const char* legacyName;
    const char* coreName;
};

static const GpuShader4TextureAlias kGpuShader4TextureAliases[] = {
    {"textureSize1D", "textureSize"},
    {"textureSize2D", "textureSize"},
    {"textureSize3D", "textureSize"},
    {"textureSizeCube", "textureSize"},
    {"textureSize1DArray", "textureSize"},
    {"textureSize2DArray", "textureSize"},
    {"textureSize2DRect", "textureSize"},
    {"textureSizeBuffer", "textureSize"},

    {"texelFetch1DArrayOffset", "texelFetchOffset"},
    {"texelFetch2DArrayOffset", "texelFetchOffset"},
    {"texelFetch2DRectOffset", "texelFetchOffset"},
    {"texelFetch1DOffset", "texelFetchOffset"},
    {"texelFetch2DOffset", "texelFetchOffset"},
    {"texelFetch3DOffset", "texelFetchOffset"},
    {"texelFetch1DArray", "texelFetch"},
    {"texelFetch2DArray", "texelFetch"},
    {"texelFetch2DRect", "texelFetch"},
    {"texelFetchBuffer", "texelFetch"},
    {"texelFetch1D", "texelFetch"},
    {"texelFetch2D", "texelFetch"},
    {"texelFetch3D", "texelFetch"},

    {"texture2DRectProjGradOffset", "textureProjGradOffset"},
    {"texture1DProjGradOffset", "textureProjGradOffset"},
    {"texture2DProjGradOffset", "textureProjGradOffset"},
    {"texture3DProjGradOffset", "textureProjGradOffset"},
    {"texture1DProjLodOffset", "textureProjLodOffset"},
    {"texture2DProjLodOffset", "textureProjLodOffset"},
    {"texture3DProjLodOffset", "textureProjLodOffset"},
    {"texture2DRectProjOffset", "textureProjOffset"},
    {"texture1DProjOffset", "textureProjOffset"},
    {"texture2DProjOffset", "textureProjOffset"},
    {"texture3DProjOffset", "textureProjOffset"},
    {"texture2DRectProjGrad", "textureProjGrad"},
    {"texture1DProjGrad", "textureProjGrad"},
    {"texture2DProjGrad", "textureProjGrad"},
    {"texture3DProjGrad", "textureProjGrad"},
    {"texture1DProjLod", "textureProjLod"},
    {"texture2DProjLod", "textureProjLod"},
    {"texture3DProjLod", "textureProjLod"},
    {"texture2DRectProj", "textureProj"},
    {"texture1DProj", "textureProj"},
    {"texture2DProj", "textureProj"},
    {"texture3DProj", "textureProj"},

    {"texture1DArrayGradOffset", "textureGradOffset"},
    {"texture2DArrayGradOffset", "textureGradOffset"},
    {"texture2DRectGradOffset", "textureGradOffset"},
    {"texture1DGradOffset", "textureGradOffset"},
    {"texture2DGradOffset", "textureGradOffset"},
    {"texture3DGradOffset", "textureGradOffset"},
    {"texture1DArrayLodOffset", "textureLodOffset"},
    {"texture2DArrayLodOffset", "textureLodOffset"},
    {"texture1DLodOffset", "textureLodOffset"},
    {"texture2DLodOffset", "textureLodOffset"},
    {"texture3DLodOffset", "textureLodOffset"},
    {"texture1DArrayOffset", "textureOffset"},
    {"texture2DArrayOffset", "textureOffset"},
    {"texture2DRectOffset", "textureOffset"},
    {"texture1DOffset", "textureOffset"},
    {"texture2DOffset", "textureOffset"},
    {"texture3DOffset", "textureOffset"},
    {"texture1DArrayGrad", "textureGrad"},
    {"texture2DArrayGrad", "textureGrad"},
    {"texture2DRectGrad", "textureGrad"},
    {"texture1DGrad", "textureGrad"},
    {"texture2DGrad", "textureGrad"},
    {"texture3DGrad", "textureGrad"},
    {"textureCubeGrad", "textureGrad"},
    {"texture1DArrayLod", "textureLod"},
    {"texture2DArrayLod", "textureLod"},
    {"texture1DLod", "textureLod"},
    {"texture2DLod", "textureLod"},
    {"texture3DLod", "textureLod"},
    {"textureCubeLod", "textureLod"},
    {"texture1DArray", "texture"},
    {"texture2DArray", "texture"},
    {"texture2DRect", "texture"},
    {"texture1D", "texture"},
    {"texture2D", "texture"},
    {"texture3D", "texture"},
    {"textureCube", "texture"},
};

bool startsWith(std::string_view text, std::string_view prefix) {
    return text.size() >= prefix.size() &&
           text.substr(0, prefix.size()) == prefix;
}

// This list is exactly the set of legacy texture builtins whose spelling
// collides with a glslang *type* keyword once the front end is driven with
// Vulkan client semantics, which is how we drive it
// (`ShaderTranslator.cpp:7489` sets `EShClientVulkan`). In that mode
// `Scan.cpp:1757-1763` promotes TEXTURE1D / TEXTURE2DRECT / TEXTURE1DARRAY
// (and `:1621-1632` TEXTURE2D / TEXTURECUBE / TEXTURE2DARRAY / TEXTURE3D)
// from identifiers to separate-image type keywords, while
// `Initialize.cpp:1780-1827` withholds the matching legacy *functions*
// because they sit behind `if (spvVersion.spv == 0)`. A legacy call such as
// `texture2DRect(tex, uv)` therefore parses as a constructor for an opaque
// image type, and glslang reports
// "'sampler/image' : cannot construct this type".
// `texture2D`/`textureCube` are renamed by the section-4 source rewrite
// below; every other colliding spelling has to be renamed here.
bool isLegacyDesktopTextureAlias(std::string_view legacyName) {
    return startsWith(legacyName, "texture1DArray") ||
           startsWith(legacyName, "texture2DArray") ||
           startsWith(legacyName, "texture2DRect") ||
           startsWith(legacyName, "texture1D") ||
           startsWith(legacyName, "texture3D");
}

bool replaceLegacyDesktopTextureCalls(std::string& src) {
    bool didReplace = false;
    for (const auto& alias : kGpuShader4TextureAliases) {
        if (!isLegacyDesktopTextureAlias(alias.legacyName) ||
            !containsIdentifier(src, alias.legacyName)) {
            continue;
        }
        didReplace =
            replaceCodeFunctionIdentifier(src, alias.legacyName, alias.coreName) ||
            didReplace;
    }
    return didReplace;
}

const char* legacyTextureAliasCoreName(std::string_view legacyName) {
    for (const auto& alias : kGpuShader4TextureAliases) {
        if (legacyName == alias.legacyName) {
            return alias.coreName;
        }
    }
    return nullptr;
}

bool rewriteLegacyTextureAliasMacros(std::string& src) {
    bool didRewrite = false;
    std::size_t lineStart = 0;
    while (lineStart < src.size()) {
        std::size_t lineEnd = src.find('\n', lineStart);
        if (lineEnd == std::string::npos) {
            lineEnd = src.size();
        }
        std::size_t contentEnd = lineEnd;
        if (contentEnd > lineStart && src[contentEnd - 1] == '\r') {
            --contentEnd;
        }

        std::size_t p = lineStart;
        while (p < contentEnd && (src[p] == ' ' || src[p] == '\t')) {
            ++p;
        }
        if (p >= contentEnd || src.compare(p, 7, "#define") != 0) {
            if (lineEnd == src.size()) break;
            lineStart = lineEnd + 1;
            continue;
        }
        p += 7;
        if (p >= contentEnd || (src[p] != ' ' && src[p] != '\t')) {
            if (lineEnd == src.size()) break;
            lineStart = lineEnd + 1;
            continue;
        }
        while (p < contentEnd && (src[p] == ' ' || src[p] == '\t')) {
            ++p;
        }

        const std::size_t nameStart = p;
        while (p < contentEnd && isIdentChar(src[p])) {
            ++p;
        }
        if (p == nameStart ||
            p >= contentEnd ||
            (src[p] != ' ' && src[p] != '\t')) {
            if (lineEnd == src.size()) break;
            lineStart = lineEnd + 1;
            continue;
        }
        while (p < contentEnd && (src[p] == ' ' || src[p] == '\t')) {
            ++p;
        }

        const std::size_t valueStart = p;
        while (p < contentEnd && isIdentChar(src[p])) {
            ++p;
        }
        if (p == valueStart) {
            if (lineEnd == src.size()) break;
            lineStart = lineEnd + 1;
            continue;
        }
        const std::size_t valueEnd = p;
        while (p < contentEnd && (src[p] == ' ' || src[p] == '\t')) {
            ++p;
        }
        if (p != contentEnd) {
            if (lineEnd == src.size()) break;
            lineStart = lineEnd + 1;
            continue;
        }

        const std::string_view value(src.data() + valueStart,
                                     valueEnd - valueStart);
        const char* replacement = legacyTextureAliasCoreName(value);
        if (!replacement) {
            if (lineEnd == src.size()) break;
            lineStart = lineEnd + 1;
            continue;
        }

        const std::size_t oldLen = valueEnd - valueStart;
        const std::size_t newLen = std::strlen(replacement);
        src.replace(valueStart, oldLen, replacement);
        didRewrite = true;
        if (newLen >= oldLen) {
            lineEnd += (newLen - oldLen);
        } else {
            lineEnd -= (oldLen - newLen);
        }
        if (lineEnd == src.size()) break;
        lineStart = lineEnd + 1;
    }
    return didRewrite;
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

bool rewriteFogFragCoordInputAccess(std::string& src) {
    bool didReplace = false;
    std::size_t pos = 0;
    while (true) {
        const std::size_t found = src.find("gl_in", pos);
        if (found == std::string::npos) {
            return didReplace;
        }
        const bool leftOk = (found == 0) || !isIdentChar(src[found - 1]);
        const std::size_t nameEnd = found + 5;
        const bool rightOk =
            (nameEnd >= src.size()) || !isIdentChar(src[nameEnd]);
        if (!leftOk || !rightOk) {
            pos = found + 1;
            continue;
        }

        std::size_t p = nameEnd;
        while (p < src.size() &&
               std::isspace(static_cast<unsigned char>(src[p]))) {
            ++p;
        }
        if (p >= src.size() || src[p] != '[') {
            pos = nameEnd;
            continue;
        }
        const std::size_t bracketStart = p;
        int depth = 0;
        while (p < src.size()) {
            if (src[p] == '[') {
                ++depth;
            } else if (src[p] == ']') {
                --depth;
                if (depth == 0) {
                    ++p;
                    break;
                }
            }
            ++p;
        }
        if (depth != 0) {
            pos = nameEnd;
            continue;
        }
        const std::size_t bracketEnd = p;
        while (p < src.size() &&
               std::isspace(static_cast<unsigned char>(src[p]))) {
            ++p;
        }
        if (p >= src.size() || src[p] != '.') {
            pos = bracketEnd;
            continue;
        }
        ++p;
        while (p < src.size() &&
               std::isspace(static_cast<unsigned char>(src[p]))) {
            ++p;
        }
        constexpr std::string_view kFogFragCoord = "gl_FogFragCoord";
        if (p + kFogFragCoord.size() > src.size() ||
            src.compare(p, kFogFragCoord.size(), kFogFragCoord) != 0) {
            pos = p;
            continue;
        }
        const std::size_t coordEnd = p + kFogFragCoord.size();
        if (coordEnd < src.size() && isIdentChar(src[coordEnd])) {
            pos = coordEnd;
            continue;
        }

        std::string replacement = "appgl_FogFragCoordIn";
        replacement.append(src, bracketStart, bracketEnd - bracketStart);
        src.replace(found, coordEnd - found, replacement);
        pos = found + replacement.size();
        didReplace = true;
    }
}

bool containsFogFragCoordInputAccess(std::string_view src) {
    std::string scratch(src);
    return rewriteFogFragCoordInputAccess(scratch);
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

// R1.0-b item #15 — `__VERSION__` fidelity across a `#version` promotion.
//
// GLSL 4.60 §3.3: "__VERSION__ will substitute a decimal integer
// reflecting the version number of the OpenGL Shading Language", and the
// version in question is the one the shader itself declares: "The
// language version a shader is written to is specified by `#version
// number profile_opt` where number must be a version of the language,
// following the same convention as __VERSION__ above." The same section
// makes the binding normative for compilation: "Shader compile-time
// errors must still be given strictly based on the version declared (or
// defaulted to) within each shader."
//
// This rewriter promotes several sources to a higher `#version` so
// glslang's Vulkan front-end accepts them (the pre-140 floor upgrade to
// `#version 330 core`, the 420 line-continuation floor, the stripped-ARB
// 430/460 upgrades). glslang reports `__VERSION__` as the version it
// PARSED —
//   third_party/glslang/glslang/MachineIndependent/preprocessor/Pp.cpp:1248
//     case PpAtomVersionMacro: ppToken->ival = parseContext.version;
// — and that case is handled in MacroExpand BEFORE any user macro lookup,
// so a shader cannot restore the value with `#define` / `#undef` either.
// glslang's `setOverrideVersion` is no escape: ShaderLang.cpp:898-899
// assigns the override straight into the same `version` field the macro
// reads. Substituting the declared number back into the macro's ordinary
// references is therefore the only repair available above glslang, and it
// belongs beside the promotion that created the discrepancy.
//
// Occurrences that NAME the macro rather than READ it are left alone;
// substituting there would turn a legal directive into a syntax error:
//   - the operand of `defined` / `defined(...)`
//   - the NAME operand of `#define` / `#undef` / `#ifdef` / `#ifndef`
// Only the name is off limits on a `#define` line: a `#define V
// __VERSION__` BODY reads the macro, so it must still be substituted or
// the promoted number reaches the conditional through the alias.
bool substituteDeclaredVersionMacro(std::string& src, int declaredVersion) {
    static constexpr std::string_view kMacro = "__VERSION__";
    const std::string replacement = std::to_string(declaredVersion);
    bool didReplace = false;
    std::size_t pos = 0;
    while (true) {
        const std::size_t found = src.find(kMacro, pos);
        if (found == std::string::npos) {
            break;
        }
        const std::size_t end = found + kMacro.size();
        const bool leftOk = (found == 0) || !isIdentChar(src[found - 1]);
        const bool rightOk = (end >= src.size()) || !isIdentChar(src[end]);
        if (!leftOk || !rightOk) {
            pos = found + 1;
            continue;
        }

        std::size_t bol = 0;
        if (found > 0) {
            const std::size_t nl = src.rfind('\n', found - 1);
            bol = (nl == std::string::npos) ? 0 : nl + 1;
        }

        bool skip = false;
        // `#define NAME` / `#undef NAME` / `#ifdef NAME` / `#ifndef NAME`
        // — only the NAME token itself.
        std::size_t d = bol;
        while (d < found && (src[d] == ' ' || src[d] == '\t')) {
            ++d;
        }
        if (d < found && src[d] == '#') {
            ++d;
            while (d < found && (src[d] == ' ' || src[d] == '\t')) {
                ++d;
            }
            std::size_t kwEnd = d;
            while (kwEnd < found && isIdentChar(src[kwEnd])) {
                ++kwEnd;
            }
            const std::string_view keyword(src.data() + d, kwEnd - d);
            if (keyword == "define" || keyword == "undef" ||
                keyword == "ifdef" || keyword == "ifndef") {
                std::size_t nameStart = kwEnd;
                while (nameStart < found &&
                       (src[nameStart] == ' ' || src[nameStart] == '\t')) {
                    ++nameStart;
                }
                if (nameStart == found) {
                    skip = true;
                }
            }
        }
        if (!skip) {
            // `defined __VERSION__` / `defined ( __VERSION__ )`
            std::size_t b = found;
            while (b > bol && (src[b - 1] == ' ' || src[b - 1] == '\t')) {
                --b;
            }
            if (b > bol && src[b - 1] == '(') {
                --b;
                while (b > bol && (src[b - 1] == ' ' || src[b - 1] == '\t')) {
                    --b;
                }
            }
            const std::size_t wordEnd = b;
            while (b > bol && isIdentChar(src[b - 1])) {
                --b;
            }
            if (std::string_view(src.data() + b, wordEnd - b) == "defined") {
                skip = true;
            }
        }
        if (skip) {
            pos = end;
            continue;
        }

        src.replace(found, kMacro.size(), replacement);
        pos = found + replacement.size();
        didReplace = true;
    }
    return didReplace;
}

// A source without #version uses desktop GLSL 1.10 semantics. Explicit
// compatibility profiles and pre-1.50 desktop versions likewise expose the
// fixed-function builtin surface. Core-profile sources must never acquire a
// synthetic ftransform definition merely because that token appears in user
// code.
bool usesLegacyCompatProfile(const std::string& source) {
    std::size_t versionStart = std::string::npos;
    const std::size_t versionEol =
        findVersionLineEnd(source, &versionStart);
    if (versionEol == std::string::npos) {
        return true;
    }

    const std::string_view versionLine(
        source.data() + versionStart, versionEol - versionStart);
    if (containsIdentifier(versionLine, "compatibility")) {
        return true;
    }
    if (containsIdentifier(versionLine, "core")) {
        return false;
    }
    const int versionNumber = parseVersionNumber(versionLine);
    return versionNumber > 0 && versionNumber < 150;
}

bool parseExtensionDirective(std::string_view line,
                             std::string_view& extension,
                             std::string_view& behavior) {
    line = trimAscii(line);
    if (line.empty() || line.front() != '#') {
        return false;
    }
    std::size_t pos = 1;
    while (pos < line.size() &&
           std::isspace(static_cast<unsigned char>(line[pos]))) {
        ++pos;
    }
    const std::size_t directiveStart = pos;
    while (pos < line.size() && isIdentChar(line[pos])) {
        ++pos;
    }
    if (line.substr(directiveStart, pos - directiveStart) != "extension") {
        return false;
    }
    while (pos < line.size() &&
           std::isspace(static_cast<unsigned char>(line[pos]))) {
        ++pos;
    }
    const std::size_t extensionStart = pos;
    while (pos < line.size() && isIdentChar(line[pos])) {
        ++pos;
    }
    if (extensionStart == pos) {
        return false;
    }
    extension = line.substr(extensionStart, pos - extensionStart);
    while (pos < line.size() &&
           std::isspace(static_cast<unsigned char>(line[pos]))) {
        ++pos;
    }
    if (pos >= line.size() || line[pos] != ':') {
        return false;
    }
    ++pos;
    while (pos < line.size() &&
           std::isspace(static_cast<unsigned char>(line[pos]))) {
        ++pos;
    }
    const std::size_t behaviorStart = pos;
    while (pos < line.size() && isIdentChar(line[pos])) {
        ++pos;
    }
    if (behaviorStart == pos) {
        return false;
    }
    behavior = line.substr(behaviorStart, pos - behaviorStart);
    return trimAscii(line.substr(pos)).empty();
}

bool effectiveArbCompatibilityEnabled(const std::string& source) {
    // Ordered extension-state evaluation. A later disable wins, and
    // `#extension all : disable` clears the state just like the frontend.
    const std::string masked = maskCommentsAndStrings(source);
    bool enabled = false;
    std::size_t lineStart = 0;
    while (lineStart < masked.size()) {
        const std::size_t newline = masked.find('\n', lineStart);
        const std::size_t lineEnd =
            newline == std::string::npos ? masked.size() : newline;
        std::string_view extension;
        std::string_view behavior;
        if (parseExtensionDirective(
                std::string_view(masked).substr(
                    lineStart, lineEnd - lineStart),
                extension, behavior)) {
            if (extension == "all" && behavior == "disable") {
                enabled = false;
            } else if (extension == "GL_ARB_compatibility") {
                enabled = behavior == "enable" || behavior == "require" ||
                          behavior == "warn";
            }
        }
        if (newline == std::string::npos) break;
        lineStart = newline + 1;
    }
    return enabled;
}

// The conventional primary/secondary color built-ins have a narrower
// language gate than several older compatibility shims in this file. Bare
// GLSL 1.40+ only regains them through an effective GL_ARB_compatibility
// directive; an explicit 1.50+ compatibility profile exposes them directly.
// ES and explicit core profiles never expose this surface.
bool usesLegacyColorBuiltinProfile(const std::string& source) {
    std::size_t versionStart = std::string::npos;
    const std::size_t versionEol = findVersionLineEnd(source, &versionStart);
    if (versionEol == std::string::npos) {
        return true;  // desktop GLSL 1.10 default
    }

    const std::string_view versionLine(
        source.data() + versionStart, versionEol - versionStart);
    const int versionNumber = parseVersionNumber(versionLine);
    if (versionNumber == 100 || containsIdentifier(versionLine, "es") ||
        containsIdentifier(versionLine, "core")) {
        return false;
    }
    if (versionNumber >= 150 &&
        containsIdentifier(versionLine, "compatibility")) {
        return true;
    }
    if (versionNumber >= 110 && versionNumber <= 130) {
        return true;
    }
    if (versionNumber < 140) {
        return false;
    }
    return effectiveArbCompatibilityEnabled(source);
}

bool stripArbCompatibilityDirectives(std::string& source) {
    const std::string masked = maskCommentsAndStrings(source);
    bool changed = false;
    std::size_t lineStart = 0;
    while (lineStart < masked.size()) {
        const std::size_t newline = masked.find('\n', lineStart);
        const std::size_t lineEnd =
            newline == std::string::npos ? masked.size() : newline;
        std::size_t pos = lineStart;
        while (pos < lineEnd &&
               std::isspace(static_cast<unsigned char>(masked[pos]))) {
            ++pos;
        }
        std::string_view extension;
        std::string_view behavior;
        if (parseExtensionDirective(
                std::string_view(masked).substr(pos, lineEnd - pos),
                extension, behavior) &&
            extension == "GL_ARB_compatibility") {
            // Same-width comment marker preserves all following offsets.
            source.replace(pos, 2, "//");
            changed = true;
        }
        if (newline == std::string::npos) break;
        lineStart = newline + 1;
    }
    return changed;
}

std::string_view trimAscii(std::string_view text) {
    while (!text.empty() &&
           std::isspace(static_cast<unsigned char>(text.front()))) {
        text.remove_prefix(1);
    }
    while (!text.empty() &&
           std::isspace(static_cast<unsigned char>(text.back()))) {
        text.remove_suffix(1);
    }
    return text;
}

std::size_t lineEndAfter(std::string_view source, std::size_t lineStart) {
    const std::size_t eol = source.find('\n', lineStart);
    return eol == std::string_view::npos ? source.size() : eol + 1;
}

bool readIdentifier(std::string_view source,
                    std::size_t& pos,
                    std::string_view* out = nullptr) {
    if (pos >= source.size() || !isIdentChar(source[pos])) {
        return false;
    }
    const std::size_t begin = pos;
    while (pos < source.size() && isIdentChar(source[pos])) {
        ++pos;
    }
    if (out != nullptr) {
        *out = source.substr(begin, pos - begin);
    }
    return true;
}

bool skipWhitespaceAndComments(std::string_view source, std::size_t& pos) {
    while (pos < source.size()) {
        if (std::isspace(static_cast<unsigned char>(source[pos]))) {
            ++pos;
            continue;
        }
        if (pos + 1 < source.size() && source[pos] == '/' && source[pos + 1] == '/') {
            pos += 2;
            while (pos < source.size() && source[pos] != '\n') {
                ++pos;
            }
            continue;
        }
        if (pos + 1 < source.size() && source[pos] == '/' && source[pos + 1] == '*') {
            const std::size_t close = source.find("*/", pos + 2);
            if (close == std::string_view::npos) {
                return false;
            }
            pos = close + 2;
            continue;
        }
        break;
    }
    return true;
}

bool sourceHasWordAt(std::string_view source,
                     std::size_t pos,
                     std::string_view word) {
    if (pos + word.size() > source.size() ||
        source.compare(pos, word.size(), word) != 0) {
        return false;
    }
    const bool leftOk = (pos == 0) || !isIdentChar(source[pos - 1]);
    const std::size_t end = pos + word.size();
    const bool rightOk = (end >= source.size()) || !isIdentChar(source[end]);
    return leftOk && rightOk;
}

bool consumeExtensionLine(std::string_view source, std::size_t& pos) {
    if (pos >= source.size() || source[pos] != '#') {
        return false;
    }
    std::size_t p = pos + 1;
    while (p < source.size() &&
           (source[p] == ' ' || source[p] == '\t')) {
        ++p;
    }
    if (!sourceHasWordAt(source, p, "extension")) {
        return false;
    }
    pos = lineEndAfter(source, pos);
    return true;
}

bool consumePrecisionDeclaration(std::string_view source, std::size_t& pos) {
    if (!sourceHasWordAt(source, pos, "precision")) {
        return false;
    }
    pos += std::strlen("precision");
    if (!skipWhitespaceAndComments(source, pos)) {
        return false;
    }
    std::string_view qualifier;
    if (!readIdentifier(source, pos, &qualifier) ||
        (qualifier != "lowp" && qualifier != "mediump" && qualifier != "highp")) {
        return false;
    }
    if (!skipWhitespaceAndComments(source, pos)) {
        return false;
    }
    std::string_view typeName;
    if (!readIdentifier(source, pos, &typeName)) {
        return false;
    }
    if (!skipWhitespaceAndComments(source, pos)) {
        return false;
    }
    if (pos >= source.size() || source[pos] != ';') {
        return false;
    }
    ++pos;
    return true;
}

bool isOnlyEsPrecisionPreamble(std::string_view source) {
    std::size_t pos = 0;
    bool sawPreambleItem = false;
    while (true) {
        if (!skipWhitespaceAndComments(source, pos)) {
            return false;
        }
        if (pos >= source.size()) {
            return sawPreambleItem;
        }
        if (consumeExtensionLine(source, pos)) {
            sawPreambleItem = true;
            continue;
        }
        if (consumePrecisionDeclaration(source, pos)) {
            sawPreambleItem = true;
            continue;
        }
        return false;
    }
}

bool isEsVersionLine(std::string_view versionLine) {
    if (parseVersionNumber(versionLine) < 300) {
        return false;
    }
    const std::string_view trimmed = trimAscii(versionLine);
    std::size_t pos = trimmed.find("#version");
    if (pos == std::string_view::npos) {
        return false;
    }
    pos += std::strlen("#version");
    while (pos < trimmed.size() &&
           std::isspace(static_cast<unsigned char>(trimmed[pos]))) {
        ++pos;
    }
    while (pos < trimmed.size() &&
           std::isdigit(static_cast<unsigned char>(trimmed[pos]))) {
        ++pos;
    }
    while (pos < trimmed.size() &&
           std::isspace(static_cast<unsigned char>(trimmed[pos]))) {
        ++pos;
    }
    return sourceHasWordAt(trimmed, pos, "es");
}

bool sourceUsesEsProfile(std::string_view source) {
    const std::size_t version = source.find("#version");
    if (version == std::string_view::npos) {
        return false;
    }
    const std::size_t versionEnd = lineEndAfter(source, version);
    return isEsVersionLine(trimAscii(source.substr(version, versionEnd - version)));
}

void normalizeDuplicatedEsVersionPreamble(std::string& source) {
    const std::size_t firstVersion = source.find("#version");
    if (firstVersion == std::string::npos) {
        return;
    }

    std::size_t firstLineEnd = lineEndAfter(source, firstVersion);
    const std::string_view firstLine =
        trimAscii(std::string_view(source).substr(firstVersion,
                                                  firstLineEnd - firstVersion));
    if (!isEsVersionLine(firstLine)) {
        return;
    }

    std::size_t search = firstVersion + std::strlen("#version");
    while (true) {
        const std::size_t secondVersion = source.find("#version", search);
        if (secondVersion == std::string::npos) {
            return;
        }

        const std::size_t secondLineEnd = lineEndAfter(source, secondVersion);
        const std::string_view secondLine =
            trimAscii(std::string_view(source).substr(
                secondVersion, secondLineEnd - secondVersion));
        if (secondLine == firstLine) {
            const std::string_view between =
                std::string_view(source).substr(firstLineEnd,
                                                secondVersion - firstLineEnd);
            if (isOnlyEsPrecisionPreamble(between)) {
                source.replace(secondVersion,
                               secondLineEnd - secondVersion,
                               "\n");
                firstLineEnd = lineEndAfter(source, firstVersion);
                search = firstLineEnd;
                continue;
            }
        }
        search = secondVersion + std::strlen("#version");
    }
}

bool isOpaquePrecisionType(std::string_view word) {
    return
        word == "sampler1D" || word == "sampler2D" ||
        word == "sampler3D" || word == "samplerCube" ||
        word == "sampler1DArray" || word == "sampler2DArray" ||
        word == "sampler1DShadow" || word == "sampler2DShadow" ||
        word == "sampler1DArrayShadow" ||
        word == "sampler2DArrayShadow" ||
        word == "samplerCubeShadow" ||
        word == "sampler2DRect" || word == "sampler2DRectShadow" ||
        word == "samplerBuffer" ||
        word == "sampler2DMS" || word == "sampler2DMSArray" ||
        word == "samplerCubeArray" ||
        word == "samplerCubeArrayShadow" ||
        word == "isampler1D" || word == "isampler2D" ||
        word == "isampler3D" || word == "isamplerCube" ||
        word == "isampler1DArray" || word == "isampler2DArray" ||
        word == "isampler2DRect" || word == "isamplerBuffer" ||
        word == "isampler2DMS" || word == "isampler2DMSArray" ||
        word == "isamplerCubeArray" ||
        word == "usampler1D" || word == "usampler2D" ||
        word == "usampler3D" || word == "usamplerCube" ||
        word == "usampler1DArray" || word == "usampler2DArray" ||
        word == "usampler2DRect" || word == "usamplerBuffer" ||
        word == "usampler2DMS" || word == "usampler2DMSArray" ||
        word == "usamplerCubeArray" ||
        word == "image1D" || word == "image2D" ||
        word == "image3D" || word == "image2DRect" ||
        word == "imageCube" || word == "imageBuffer" ||
        word == "image1DArray" || word == "image2DArray" ||
        word == "imageCubeArray" ||
        word == "image2DMS" || word == "image2DMSArray" ||
        word == "iimage1D" || word == "iimage2D" ||
        word == "iimage3D" || word == "iimage2DRect" ||
        word == "iimageCube" || word == "iimageBuffer" ||
        word == "iimage1DArray" || word == "iimage2DArray" ||
        word == "iimageCubeArray" ||
        word == "iimage2DMS" || word == "iimage2DMSArray" ||
        word == "uimage1D" || word == "uimage2D" ||
        word == "uimage3D" || word == "uimage2DRect" ||
        word == "uimageCube" || word == "uimageBuffer" ||
        word == "uimage1DArray" || word == "uimage2DArray" ||
        word == "uimageCubeArray" ||
        word == "uimage2DMS" || word == "uimage2DMSArray";
}

void qualifyEsOpaqueUniforms(std::string& source) {
    if (!sourceUsesEsProfile(source)) {
        return;
    }

    bool lineComment = false;
    bool blockComment = false;
    std::size_t pos = 0;
    while (pos < source.size()) {
        if (lineComment) {
            if (source[pos] == '\n') {
                lineComment = false;
            }
            ++pos;
            continue;
        }
        if (blockComment) {
            if (pos + 1 < source.size() &&
                source[pos] == '*' && source[pos + 1] == '/') {
                pos += 2;
                blockComment = false;
            } else {
                ++pos;
            }
            continue;
        }
        if (pos + 1 < source.size() &&
            source[pos] == '/' && source[pos + 1] == '/') {
            pos += 2;
            lineComment = true;
            continue;
        }
        if (pos + 1 < source.size() &&
            source[pos] == '/' && source[pos + 1] == '*') {
            pos += 2;
            blockComment = true;
            continue;
        }
        if (!sourceHasWordAt(source, pos, "uniform")) {
            ++pos;
            continue;
        }

        std::size_t probe = pos + std::strlen("uniform");
        if (!skipWhitespaceAndComments(source, probe)) {
            pos = probe;
            continue;
        }

        std::string_view word;
        const std::size_t wordStart = probe;
        if (!readIdentifier(source, probe, &word)) {
            pos = probe;
            continue;
        }
        if (word == "lowp" || word == "mediump" || word == "highp") {
            pos = probe;
            continue;
        }
        if (isOpaquePrecisionType(word)) {
            source.insert(wordStart, "highp ");
            pos = wordStart + std::strlen("highp ") + word.size();
            continue;
        }
        pos = probe;
    }
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

std::string maskCommentsAndStrings(std::string_view source) {
    std::string masked(source);
    bool lineComment = false;
    bool blockComment = false;
    char quote = '\0';
    for (std::size_t i = 0; i < masked.size(); ++i) {
        const char c = source[i];
        const char next = i + 1 < source.size() ? source[i + 1] : '\0';
        if (lineComment) {
            if (c == '\n') {
                lineComment = false;
            } else {
                masked[i] = ' ';
            }
            continue;
        }
        if (blockComment) {
            if (c == '*' && next == '/') {
                masked[i] = masked[i + 1] = ' ';
                ++i;
                blockComment = false;
            } else if (c != '\n') {
                masked[i] = ' ';
            }
            continue;
        }
        if (quote != '\0') {
            if (c == '\\' && i + 1 < source.size()) {
                masked[i] = masked[i + 1] = ' ';
                ++i;
            } else {
                if (c == quote) {
                    quote = '\0';
                }
                if (c != '\n') {
                    masked[i] = ' ';
                }
            }
            continue;
        }
        if (c == '/' && next == '/') {
            masked[i] = masked[i + 1] = ' ';
            ++i;
            lineComment = true;
        } else if (c == '/' && next == '*') {
            masked[i] = masked[i + 1] = ' ';
            ++i;
            blockComment = true;
        } else if (c == '"' || c == '\'') {
            masked[i] = ' ';
            quote = c;
        }
    }
    return masked;
}

struct IndexedInterfaceMemberAccess {
    std::size_t begin = 0;
    std::size_t end = 0;
    std::size_t subscriptOpen = 0;
    std::size_t subscriptClose = 0;
};

bool findIndexedInterfaceMemberAccess(
    const std::string& source,
    std::string_view interfaceName,
    std::string_view memberName,
    IndexedInterfaceMemberAccess& access,
    std::size_t searchFrom = 0)
{
    const std::string clean = maskCommentsAndStrings(source);
    std::size_t pos = searchFrom;
    while ((pos = clean.find(interfaceName, pos)) != std::string::npos) {
        if (!sourceHasWordAt(clean, pos, interfaceName) ||
            isPreprocessorDirectiveLine(clean, pos)) {
            ++pos;
            continue;
        }
        std::size_t cursor = pos + interfaceName.size();
        while (cursor < clean.size() &&
               std::isspace(static_cast<unsigned char>(clean[cursor]))) {
            ++cursor;
        }
        if (cursor >= clean.size() || clean[cursor] != '[') {
            pos += interfaceName.size();
            continue;
        }
        const std::size_t open = cursor;
        int depth = 1;
        ++cursor;
        while (cursor < clean.size() && depth > 0) {
            if (clean[cursor] == '[') {
                ++depth;
            } else if (clean[cursor] == ']') {
                --depth;
            }
            ++cursor;
        }
        if (depth != 0) {
            return false;
        }
        const std::size_t close = cursor - 1;
        while (cursor < clean.size() &&
               std::isspace(static_cast<unsigned char>(clean[cursor]))) {
            ++cursor;
        }
        if (cursor >= clean.size() || clean[cursor] != '.') {
            pos += interfaceName.size();
            continue;
        }
        ++cursor;
        while (cursor < clean.size() &&
               std::isspace(static_cast<unsigned char>(clean[cursor]))) {
            ++cursor;
        }
        if (!sourceHasWordAt(clean, cursor, memberName)) {
            pos += interfaceName.size();
            continue;
        }
        access = {pos, cursor + memberName.size(), open, close};
        return true;
    }
    return false;
}

bool containsIndexedInterfaceMemberAccess(
    const std::string& source,
    std::string_view interfaceName,
    std::string_view memberName)
{
    IndexedInterfaceMemberAccess access;
    return findIndexedInterfaceMemberAccess(
        source, interfaceName, memberName, access);
}

bool rewriteIndexedInterfaceMemberAccess(
    std::string& source,
    std::string_view interfaceName,
    std::string_view memberName,
    std::string_view replacementArray)
{
    bool changed = false;
    IndexedInterfaceMemberAccess access;
    while (findIndexedInterfaceMemberAccess(
               source, interfaceName, memberName, access)) {
        std::string replacement(replacementArray);
        replacement.append(source,
                           access.subscriptOpen,
                           access.subscriptClose - access.subscriptOpen + 1);
        source.replace(access.begin, access.end - access.begin, replacement);
        changed = true;
    }
    return changed;
}

bool containsUnqualifiedCodeIdentifier(const std::string& source,
                                       std::string_view identifier) {
    const std::string clean = maskCommentsAndStrings(source);
    std::size_t pos = 0;
    while ((pos = clean.find(identifier, pos)) != std::string::npos) {
        if (!sourceHasWordAt(clean, pos, identifier) ||
            isPreprocessorDirectiveLine(clean, pos)) {
            ++pos;
            continue;
        }
        std::size_t before = pos;
        while (before > 0 &&
               std::isspace(static_cast<unsigned char>(clean[before - 1]))) {
            --before;
        }
        if (before == 0 || clean[before - 1] != '.') {
            return true;
        }
        pos += identifier.size();
    }
    return false;
}

std::string legacyColorTransportName(std::string_view baseName,
                                     std::string_view destination) {
    std::string name(baseName);
    name.append("To").append(destination);
    return name;
}

struct GeometryShader4DirectiveRecord {
    std::size_t hash = 0;
    std::size_t lineEnd = 0;
    GeometryShader4DirectiveMode mode = GeometryShader4DirectiveMode::Absent;
};

std::vector<GeometryShader4DirectiveRecord> collectGeometryShader4Directives(
    std::string_view source)
{
    const std::string masked = maskCommentsAndStrings(source);
    std::vector<GeometryShader4DirectiveRecord> records;
    std::size_t lineStart = 0;
    while (lineStart < masked.size()) {
        const std::size_t newline = masked.find('\n', lineStart);
        const std::size_t lineEnd = newline == std::string::npos
            ? masked.size() : newline;
        std::size_t pos = lineStart;
        while (pos < lineEnd &&
               (masked[pos] == ' ' || masked[pos] == '\t' ||
                masked[pos] == '\r')) {
            ++pos;
        }
        if (pos < lineEnd && masked[pos] == '#') {
            const std::size_t hash = pos++;
            while (pos < lineEnd &&
                   (masked[pos] == ' ' || masked[pos] == '\t')) {
                ++pos;
            }
            std::string_view directive;
            if (readIdentifier(masked, pos, &directive) &&
                directive == "extension") {
                while (pos < lineEnd &&
                       std::isspace(static_cast<unsigned char>(masked[pos]))) {
                    ++pos;
                }
                std::string_view extension;
                if (readIdentifier(masked, pos, &extension) &&
                    extension == "GL_ARB_geometry_shader4") {
                    while (pos < lineEnd &&
                           std::isspace(static_cast<unsigned char>(masked[pos]))) {
                        ++pos;
                    }
                    if (pos < lineEnd && masked[pos] == ':') {
                        ++pos;
                        while (pos < lineEnd &&
                               std::isspace(static_cast<unsigned char>(masked[pos]))) {
                            ++pos;
                        }
                        std::string_view behavior;
                        if (readIdentifier(masked, pos, &behavior)) {
                            GeometryShader4DirectiveMode mode =
                                GeometryShader4DirectiveMode::Absent;
                            if (behavior == "disable") {
                                mode = GeometryShader4DirectiveMode::Disable;
                            } else if (behavior == "warn") {
                                mode = GeometryShader4DirectiveMode::Warn;
                            } else if (behavior == "enable") {
                                mode = GeometryShader4DirectiveMode::Enable;
                            } else if (behavior == "require") {
                                mode = GeometryShader4DirectiveMode::Require;
                            }
                            if (mode != GeometryShader4DirectiveMode::Absent) {
                                records.push_back({hash, lineEnd, mode});
                            }
                        }
                    }
                }
            }
        }
        if (newline == std::string::npos) {
            break;
        }
        lineStart = newline + 1;
    }
    return records;
}

std::size_t geometryShader4PreambleOffset(const std::string& source) {
    const std::string masked = maskCommentsAndStrings(source);
    std::size_t pos = 0;
    while (pos < masked.size()) {
        while (pos < masked.size() &&
               std::isspace(static_cast<unsigned char>(masked[pos]))) {
            ++pos;
        }
        if (pos >= masked.size() || masked[pos] != '#') {
            break;
        }
        const std::size_t eol = source.find('\n', pos);
        pos = eol == std::string::npos ? source.size() : eol + 1;
    }
    return pos;
}

bool replaceGeometryShader4VaryingStorage(std::string& source) {
    bool changed = false;
    std::size_t pos = 0;
    while (pos < source.size()) {
        if (isPreprocessorDirectiveLine(source, pos)) {
            pos = skipPreprocessorDirective(source, pos);
            continue;
        }
        if (source.compare(pos, 2, "//") == 0) {
            pos = skipLineComment(source, pos);
            continue;
        }
        if (source.compare(pos, 2, "/*") == 0) {
            pos = skipBlockComment(source, pos);
            continue;
        }
        if (source[pos] == '"' || source[pos] == '\'') {
            pos = skipStringLiteral(source, pos);
            continue;
        }
        if (!sourceHasWordAt(source, pos, "varying")) {
            ++pos;
            continue;
        }
        std::size_t next = pos + std::strlen("varying");
        if (!skipWhitespaceAndComments(source, next) ||
            (!sourceHasWordAt(source, next, "in") &&
             !sourceHasWordAt(source, next, "out"))) {
            pos += std::strlen("varying");
            continue;
        }
        source.replace(pos, std::strlen("varying"),
                       std::strlen("varying"), ' ');
        changed = true;
        pos = next;
    }
    return changed;
}

bool findGlobalStorageDeclaration(const std::string& clean,
                                  std::size_t identifierPos,
                                  std::size_t& statementStart,
                                  std::size_t& semicolon) {
    int braceDepth = 0;
    statementStart = 0;
    for (std::size_t pos = 0; pos < identifierPos;) {
        if (isPreprocessorDirectiveLine(clean, pos)) {
            const std::size_t next = skipPreprocessorDirective(clean, pos);
            if (next > identifierPos) {
                return false;
            }
            if (braceDepth == 0) {
                statementStart = next;
            }
            pos = next;
            continue;
        }

        if (clean[pos] == '{') {
            if (braceDepth == 0) {
                statementStart = pos + 1;
            }
            ++braceDepth;
        } else if (clean[pos] == '}') {
            if (braceDepth == 0) {
                return false;
            }
            --braceDepth;
            if (braceDepth == 0) {
                statementStart = pos + 1;
            }
        } else if (clean[pos] == ';' && braceDepth == 0) {
            statementStart = pos + 1;
        }
        ++pos;
    }
    if (braceDepth != 0) {
        return false;
    }

    int parenDepth = 0;
    int bracketDepth = 0;
    bool hasStorageQualifier = false;
    bool hasAssignmentBeforeIdentifier = false;
    for (std::size_t pos = statementStart; pos < clean.size();) {
        if (isPreprocessorDirectiveLine(clean, pos)) {
            return false;
        }

        const char c = clean[pos];
        if (c == '(') {
            ++parenDepth;
        } else if (c == ')') {
            if (parenDepth == 0) {
                return false;
            }
            --parenDepth;
        } else if (c == '[') {
            ++bracketDepth;
        } else if (c == ']') {
            if (bracketDepth == 0) {
                return false;
            }
            --bracketDepth;
        } else if (c == '{' || c == '}') {
            return false;
        }

        const bool atTopLevel = parenDepth == 0 && bracketDepth == 0;
        if (pos < identifierPos && atTopLevel) {
            if (c == '=') {
                hasAssignmentBeforeIdentifier = true;
            }
            hasStorageQualifier = hasStorageQualifier ||
                sourceHasWordAt(clean, pos, "varying") ||
                sourceHasWordAt(clean, pos, "attribute") ||
                sourceHasWordAt(clean, pos, "in") ||
                sourceHasWordAt(clean, pos, "out");
        }
        if (pos == identifierPos &&
            (!atTopLevel || !hasStorageQualifier ||
             hasAssignmentBeforeIdentifier)) {
            return false;
        }
        if (pos > identifierPos && c == ';' && atTopLevel) {
            semicolon = pos;
            return true;
        }
        ++pos;
    }
    return false;
}

bool eraseGlobalStorageDeclaration(std::string& source,
                                   const char* identifier) {
    const std::string clean = maskCommentsAndStrings(source);
    std::size_t pos = 0;
    while ((pos = clean.find(identifier, pos)) != std::string::npos) {
        if (!sourceHasWordAt(clean, pos, identifier)) {
            ++pos;
            continue;
        }
        std::size_t statementStart = 0;
        std::size_t semicolon = 0;
        if (!findGlobalStorageDeclaration(clean, pos, statementStart,
                                          semicolon)) {
            pos += std::strlen(identifier);
            continue;
        }
        for (std::size_t i = statementStart; i <= semicolon; ++i) {
            if (source[i] != '\n') source[i] = ' ';
        }
        return true;
    }
    return false;
}

std::string globalStorageInterpolationQualifier(
    const std::string& source,
    const char* identifier)
{
    const std::string clean = maskCommentsAndStrings(source);
    std::size_t pos = 0;
    while ((pos = clean.find(identifier, pos)) != std::string::npos) {
        if (!sourceHasWordAt(clean, pos, identifier)) {
            ++pos;
            continue;
        }
        std::size_t statementStart = 0;
        std::size_t semicolon = 0;
        if (!findGlobalStorageDeclaration(clean, pos, statementStart,
                                          semicolon)) {
            pos += std::strlen(identifier);
            continue;
        }
        const std::string_view statement(
            clean.data() + statementStart, semicolon - statementStart);
        // A legacy color may carry one interpolation qualifier. Preserve
        // exactly the semantic qualifier; storage and type are rebuilt by
        // the internal front/back declarations.
        for (const char* qualifier : {"flat", "smooth", "noperspective"}) {
            if (containsIdentifier(statement, qualifier)) {
                return qualifier;
            }
        }
        return {};
    }
    return {};
}

bool parseSimpleGeometryShader4Integer(std::string_view expression,
                                       int& value);

int provisionalGeometryShader4VerticesIn(std::string_view source) {
    const std::string clean = maskCommentsAndStrings(source);
    std::size_t pos = 0;
    while ((pos = clean.find("varying", pos)) != std::string::npos) {
        if (!sourceHasWordAt(clean, pos, "varying")) {
            ++pos;
            continue;
        }
        std::size_t scan = pos + std::strlen("varying");
        while (scan < clean.size() &&
               std::isspace(static_cast<unsigned char>(clean[scan]))) {
            ++scan;
        }
        if (!sourceHasWordAt(clean, scan, "in")) {
            pos += std::strlen("varying");
            continue;
        }
        const std::size_t semicolon = clean.find(';', scan);
        const std::size_t open = clean.find('[', scan);
        if (open == std::string::npos ||
            (semicolon != std::string::npos && open > semicolon)) {
            pos += std::strlen("varying");
            continue;
        }
        const std::size_t close = clean.find(']', open + 1);
        if (close == std::string::npos) break;
        const std::string_view extent = trimAscii(
            std::string_view(clean).substr(open + 1, close - open - 1));
        if (extent.empty()) return 6;
        int parsed = 0;
        if (parseSimpleGeometryShader4Integer(extent, parsed) &&
            (parsed == 1 || parsed == 2 || parsed == 3 ||
             parsed == 4 || parsed == 6)) {
            return parsed;
        }
        pos = close + 1;
    }
    return 3;
}

GLenum geometryShader4InputTypeForVertexCount(int vertices) {
    switch (vertices) {
        case 1: return GL_POINTS;
        case 2: return GL_LINES;
        case 4: return GL_LINES_ADJACENCY;
        case 6: return GL_TRIANGLES_ADJACENCY;
        default: return GL_TRIANGLES;
    }
}

bool parseSimpleGeometryShader4Integer(std::string_view expression,
                                       int& value) {
    expression = trimAscii(expression);
    int sign = 1;
    if (!expression.empty() && (expression.front() == '+' || expression.front() == '-')) {
        if (expression.front() == '-') sign = -1;
        expression.remove_prefix(1);
        expression = trimAscii(expression);
    }
    if (expression.empty()) return false;
    int base = 0;
    if (expression.substr(0, std::strlen("gl_MaxClipDistances")) ==
        "gl_MaxClipDistances") {
        base = 8;
        expression.remove_prefix(std::strlen("gl_MaxClipDistances"));
    } else {
        std::size_t digits = 0;
        while (digits < expression.size() &&
               std::isdigit(static_cast<unsigned char>(expression[digits]))) {
            ++digits;
        }
        if (digits == 0) return false;
        base = std::atoi(std::string(expression.substr(0, digits)).c_str());
        expression.remove_prefix(digits);
    }
    expression = trimAscii(expression);
    if (!expression.empty()) {
        const char op = expression.front();
        if (op != '+' && op != '-') return false;
        expression.remove_prefix(1);
        expression = trimAscii(expression);
        std::size_t digits = 0;
        while (digits < expression.size() &&
               std::isdigit(static_cast<unsigned char>(expression[digits]))) {
            ++digits;
        }
        if (digits == 0 || !trimAscii(expression.substr(digits)).empty()) {
            return false;
        }
        const int rhs = std::atoi(std::string(expression.substr(0, digits)).c_str());
        base = op == '+' ? base + rhs : base - rhs;
    }
    value = sign * base;
    return true;
}

struct GeometryShader4ClipDistanceDecl {
    bool present = false;
    std::size_t storagePos = std::string::npos;
    int outerSize = 0;
    int innerSize = 0;
};

GeometryShader4ClipDistanceDecl findGeometryShader4ClipDistanceDecl(
    const std::string& source)
{
    GeometryShader4ClipDistanceDecl result;
    const std::string clean = maskCommentsAndStrings(source);
    std::size_t name = 0;
    while ((name = clean.find("gl_ClipDistanceIn", name)) != std::string::npos) {
        if (!sourceHasWordAt(clean, name, "gl_ClipDistanceIn")) {
            ++name;
            continue;
        }
        std::size_t stmtStart = name;
        while (stmtStart > 0 && clean[stmtStart - 1] != ';' &&
               clean[stmtStart - 1] != '{' && clean[stmtStart - 1] != '}') {
            --stmtStart;
        }
        std::size_t scan = stmtStart;
        std::size_t inPos = std::string::npos;
        bool sawFloat = false;
        while (scan < name) {
            while (scan < name && !isIdentChar(clean[scan])) ++scan;
            const std::size_t begin = scan;
            while (scan < name && isIdentChar(clean[scan])) ++scan;
            if (begin == scan) break;
            const std::string_view token(clean.data() + begin, scan - begin);
            if (token == "in") inPos = begin;
            if (token == "float") sawFloat = true;
        }
        if (inPos == std::string::npos || !sawFloat) {
            name += std::strlen("gl_ClipDistanceIn");
            continue;
        }
        std::size_t p = name + std::strlen("gl_ClipDistanceIn");
        while (p < clean.size() && std::isspace(static_cast<unsigned char>(clean[p]))) ++p;
        int dimensions[2] = {0, 0};
        bool ok = true;
        for (int dim = 0; dim < 2; ++dim) {
            if (p >= clean.size() || clean[p] != '[') { ok = false; break; }
            const std::size_t close = clean.find(']', p + 1);
            if (close == std::string::npos ||
                !parseSimpleGeometryShader4Integer(
                    std::string_view(clean).substr(p + 1, close - p - 1),
                    dimensions[dim])) {
                ok = false;
                break;
            }
            p = close + 1;
            while (p < clean.size() && std::isspace(static_cast<unsigned char>(clean[p]))) ++p;
        }
        if (ok) {
            result.present = true;
            result.storagePos = inPos;
            result.outerSize = dimensions[0];
            result.innerSize = dimensions[1];
        }
        return result;
    }
    return result;
}

bool validateImplicitGeometryShader4ClipDistanceAccess(
    const std::string& source, std::string& diagnostic)
{
    const std::string clean = maskCommentsAndStrings(source);
    std::size_t pos = 0;
    while ((pos = clean.find("gl_ClipDistanceIn", pos)) != std::string::npos) {
        if (!sourceHasWordAt(clean, pos, "gl_ClipDistanceIn")) {
            ++pos;
            continue;
        }
        std::size_t p = pos + std::strlen("gl_ClipDistanceIn");
        while (p < clean.size() && std::isspace(static_cast<unsigned char>(clean[p]))) ++p;
        if (p >= clean.size() || clean[p] != '[') {
            diagnostic = "implicit gl_ClipDistanceIn requires constant two-dimensional indexing";
            return false;
        }
        const std::size_t outerClose = clean.find(']', p + 1);
        if (outerClose == std::string::npos) return false;
        p = outerClose + 1;
        while (p < clean.size() && std::isspace(static_cast<unsigned char>(clean[p]))) ++p;
        if (p >= clean.size() || clean[p] != '[') {
            diagnostic = "implicit gl_ClipDistanceIn has an unsized inner array";
            return false;
        }
        const std::size_t innerClose = clean.find(']', p + 1);
        int innerIndex = 0;
        if (innerClose == std::string::npos ||
            !parseSimpleGeometryShader4Integer(
                std::string_view(clean).substr(p + 1, innerClose - p - 1),
                innerIndex)) {
            diagnostic = "implicit gl_ClipDistanceIn requires a constant inner index";
            return false;
        }
        if (innerIndex < 0 || innerIndex >= 8) {
            diagnostic = "gl_ClipDistanceIn inner index exceeds gl_MaxClipDistances";
            return false;
        }
        pos = innerClose + 1;
    }
    return true;
}

}  // namespace

GeometryShader4DirectiveState scanGeometryShader4Directive(
    std::string_view source)
{
    GeometryShader4DirectiveState result;
    for (const auto& record : collectGeometryShader4Directives(source)) {
        result.present = true;
        result.mode = record.mode;
    }
    return result;
}

GeometryShader4SourceLayout parseGeometryShader4SourceLayout(
    std::string_view source)
{
    GeometryShader4SourceLayout result;
    const std::string clean = maskCommentsAndStrings(source);
    auto fail = [&](const std::string& message) {
        result.valid = false;
        result.diagnostic = message;
    };
    auto setInput = [&](GLenum value) {
        if (result.hasInputType && result.inputType != value) {
            fail("conflicting geometry shader input layout declarations");
        } else {
            result.hasInputType = true;
            result.inputType = value;
        }
    };
    auto setOutput = [&](GLenum value) {
        if (result.hasOutputType && result.outputType != value) {
            fail("conflicting geometry shader output layout declarations");
        } else {
            result.hasOutputType = true;
            result.outputType = value;
        }
    };
    std::size_t pos = 0;
    while (result.valid &&
           (pos = clean.find("layout", pos)) != std::string::npos) {
        if (!sourceHasWordAt(clean, pos, "layout")) {
            ++pos;
            continue;
        }
        std::size_t open = pos + std::strlen("layout");
        while (open < clean.size() &&
               std::isspace(static_cast<unsigned char>(clean[open]))) ++open;
        if (open >= clean.size() || clean[open] != '(') {
            pos += std::strlen("layout");
            continue;
        }
        int depth = 1;
        std::size_t close = open + 1;
        while (close < clean.size() && depth > 0) {
            if (clean[close] == '(') ++depth;
            else if (clean[close] == ')') --depth;
            ++close;
        }
        if (depth != 0) {
            fail("unterminated geometry shader layout declaration");
            break;
        }
        const std::size_t closeParen = close - 1;
        std::size_t storage = close;
        while (storage < clean.size() &&
               std::isspace(static_cast<unsigned char>(clean[storage]))) ++storage;
        const bool isInput = sourceHasWordAt(clean, storage, "in");
        const bool isOutput = sourceHasWordAt(clean, storage, "out");
        if (!isInput && !isOutput) {
            pos = close;
            continue;
        }
        std::string_view inner(clean.data() + open + 1,
                               closeParen - open - 1);
        std::size_t itemStart = 0;
        while (itemStart <= inner.size() && result.valid) {
            const std::size_t comma = inner.find(',', itemStart);
            std::string_view item = trimAscii(inner.substr(
                itemStart, comma == std::string_view::npos
                    ? inner.size() - itemStart : comma - itemStart));
            const std::size_t equals = item.find('=');
            const std::string_view name = trimAscii(item.substr(0, equals));
            if (isInput) {
                if (name == "points") setInput(GL_POINTS);
                else if (name == "lines") setInput(GL_LINES);
                else if (name == "lines_adjacency") setInput(GL_LINES_ADJACENCY);
                else if (name == "triangles") setInput(GL_TRIANGLES);
                else if (name == "triangles_adjacency") setInput(GL_TRIANGLES_ADJACENCY);
            }
            if (isOutput) {
                if (name == "points") setOutput(GL_POINTS);
                else if (name == "line_strip") setOutput(GL_LINE_STRIP);
                else if (name == "triangle_strip") setOutput(GL_TRIANGLE_STRIP);
                else if (name == "max_vertices") {
                    int parsed = 0;
                    if (equals == std::string_view::npos ||
                        !parseSimpleGeometryShader4Integer(
                            item.substr(equals + 1), parsed) || parsed <= 0) {
                        fail("invalid geometry shader max_vertices layout");
                    } else if (result.hasVerticesOut &&
                               result.verticesOut != parsed) {
                        fail("conflicting geometry shader max_vertices declarations");
                    } else {
                        result.hasVerticesOut = true;
                        result.verticesOut = parsed;
                    }
                }
            }
            if (comma == std::string_view::npos) break;
            itemStart = comma + 1;
        }
        pos = close;
    }
    return result;
}

GeometryShader4RewriteResult rewriteGeometryShader4Source(
    std::string_view source,
    const GeometryShader4LinkPlan& plan)
{
    GeometryShader4RewriteResult result;
    result.source.assign(source.begin(), source.end());
    result.directive = scanGeometryShader4Directive(source);
    if (!result.directive.active() || !plan.active) {
        return result;
    }
    if (plan.verticesIn <= 0 || plan.verticesOut <= 0) {
        result.valid = false;
        result.diagnostic = "ARB geometry shader link plan has zero effective vertices";
        return result;
    }
    int effectiveVerticesIn = plan.verticesIn;
    GLenum effectiveInputType = plan.inputType;
    if (plan.materializedInputCapacity > plan.verticesIn &&
        !plan.inputFromSource) {
        effectiveVerticesIn = provisionalGeometryShader4VerticesIn(source);
        effectiveInputType = geometryShader4InputTypeForVertexCount(
            effectiveVerticesIn);
    }
    const int materializedInputCapacity =
        plan.materializedInputCapacity > 0
            ? plan.materializedInputCapacity
            : effectiveVerticesIn;

    const GeometryShader4SourceLayout layout =
        parseGeometryShader4SourceLayout(source);
    if (!layout.valid) {
        result.valid = false;
        result.diagnostic = layout.diagnostic;
        return result;
    }

    for (const auto& record : collectGeometryShader4Directives(result.source)) {
        if (record.hash + 1 < record.lineEnd) {
            result.source[record.hash] = '/';
            result.source[record.hash + 1] = '/';
        }
    }

    const std::string masked = maskCommentsAndStrings(result.source);
    std::size_t version = 0;
    bool replacedVersion = false;
    while ((version = masked.find('#', version)) != std::string::npos) {
        std::size_t p = version + 1;
        while (p < masked.size() &&
               (masked[p] == ' ' || masked[p] == '\t')) ++p;
        if (sourceHasWordAt(masked, p, "version")) {
            const std::size_t eol = result.source.find('\n', version);
            const std::size_t end = eol == std::string::npos
                ? result.source.size() : eol;
            result.source.replace(version, end - version, "#version 460 core");
            replacedVersion = true;
            break;
        }
        ++version;
    }
    if (!replacedVersion) {
        result.source.insert(0, "#version 460 core\n");
    }

    replaceGeometryShader4VaryingStorage(result.source);
    replaceCodeIdentifier(result.source, "gl_VerticesIn",
                          std::to_string(effectiveVerticesIn));

    const bool usesPositionIn =
        containsCodeIdentifier(result.source, "gl_PositionIn");
    const bool usesPointSizeIn =
        containsCodeIdentifier(result.source, "gl_PointSizeIn");
    const bool usesClipVertexIn =
        containsCodeIdentifier(result.source, "gl_ClipVertexIn");
    const bool usesFrontColorIn =
        containsCodeIdentifier(result.source, "gl_FrontColorIn");
    const bool usesBackColorIn =
        containsCodeIdentifier(result.source, "gl_BackColorIn");
    const bool usesFrontSecondaryColorIn =
        containsCodeIdentifier(result.source, "gl_FrontSecondaryColorIn");
    const bool usesBackSecondaryColorIn =
        containsCodeIdentifier(result.source, "gl_BackSecondaryColorIn");
    const bool usesTexCoordIn =
        containsCodeIdentifier(result.source, "gl_TexCoordIn");
    const bool usesFogFragCoordIn =
        containsCodeIdentifier(result.source, "gl_FogFragCoordIn");
    const bool usesClipDistanceIn =
        containsCodeIdentifier(result.source, "gl_ClipDistanceIn");
    result.legacyInputs.clipVertex = usesClipVertexIn;
    result.legacyInputs.frontColor = usesFrontColorIn;
    result.legacyInputs.backColor = usesBackColorIn;
    result.legacyInputs.frontSecondaryColor = usesFrontSecondaryColorIn;
    result.legacyInputs.backSecondaryColor = usesBackSecondaryColorIn;
    result.legacyInputs.texCoord = usesTexCoordIn;
    result.legacyInputs.fogFragCoord = usesFogFragCoordIn;

    const GeometryShader4ClipDistanceDecl clipDecl =
        findGeometryShader4ClipDistanceDecl(result.source);
    int clipDistanceWidth = 8;
    if (clipDecl.present) {
        clipDistanceWidth = clipDecl.innerSize;
        if (clipDecl.outerSize != effectiveVerticesIn) {
            result.valid = false;
            result.diagnostic =
                "gl_ClipDistanceIn outer dimension differs from gl_VerticesIn";
            return result;
        }
        if (clipDistanceWidth <= 0 || clipDistanceWidth > 8) {
            result.valid = false;
            result.diagnostic =
                "gl_ClipDistanceIn width exceeds gl_MaxClipDistances";
            return result;
        }
        result.source.replace(clipDecl.storagePos, 2, "  ");
    } else if (usesClipDistanceIn &&
               !validateImplicitGeometryShader4ClipDistanceAccess(
                   result.source, result.diagnostic)) {
        result.valid = false;
        return result;
    }

    if (usesClipDistanceIn) {
        eraseGlobalStorageDeclaration(result.source, "gl_ClipDistance");
    }
    if (usesTexCoordIn) {
        eraseGlobalStorageDeclaration(result.source, "gl_TexCoordIn");
    }

    if (usesPositionIn) {
        replaceCodeIdentifier(result.source, "gl_PositionIn",
                              "appgl_PositionIn");
    }
    if (usesPointSizeIn) {
        replaceCodeIdentifier(result.source, "gl_PointSizeIn",
                              "appgl_PointSizeIn");
    }
    if (usesClipDistanceIn) {
        replaceCodeIdentifier(result.source, "gl_ClipDistanceIn",
                              "appgl_ClipDistanceIn");
    }
    if (usesClipVertexIn) {
        replaceCodeIdentifier(result.source, "gl_ClipVertexIn",
                              "appgl_ClipVertexIn");
    }
    if (usesFrontColorIn) {
        replaceCodeIdentifier(result.source, "gl_FrontColorIn",
                              "appgl_FrontColorIn");
    }
    if (usesBackColorIn) {
        replaceCodeIdentifier(result.source, "gl_BackColorIn",
                              "appgl_BackColorIn");
    }
    if (usesFrontSecondaryColorIn) {
        replaceCodeIdentifier(result.source, "gl_FrontSecondaryColorIn",
                              "appgl_FrontSecondaryColorIn");
    }
    if (usesBackSecondaryColorIn) {
        replaceCodeIdentifier(result.source, "gl_BackSecondaryColorIn",
                              "appgl_BackSecondaryColorIn");
    }
    if (usesTexCoordIn) {
        replaceCodeIdentifier(result.source, "gl_TexCoordIn",
                              "appgl_TexCoordIn");
    }
    if (usesFogFragCoordIn) {
        replaceCodeIdentifier(result.source, "gl_FogFragCoordIn",
                              "appgl_FogFragCoordIn");
    }

    // Legacy extension texture entry points became the unified core texture
    // family. Keep this list explicit so only code tokens in ARB geometry
    // sources are changed; comments and similarly named helpers stay intact.
    constexpr std::pair<const char*, const char*> textureAliases[] = {
        {"texture1DGradARB", "textureGrad"},
        {"texture1DProjGradARB", "textureProjGrad"},
        {"texture2DGradARB", "textureGrad"},
        {"texture2DProjGradARB", "textureProjGrad"},
        {"texture3DGradARB", "textureGrad"},
        {"texture3DProjGradARB", "textureProjGrad"},
        {"textureCubeGradARB", "textureGrad"},
        {"shadow1DGradARB", "textureGrad"},
        {"shadow1DProjGradARB", "textureProjGrad"},
        {"shadow2DGradARB", "textureGrad"},
        {"shadow2DProjGradARB", "textureProjGrad"},
        {"texture2DRect", "texture"},
        {"texture2DRectProj", "textureProj"},
        {"shadow2DRect", "texture"},
        {"shadow2DRectProj", "textureProj"},
        {"texture1DArray", "texture"},
        {"texture1DArrayLod", "textureLod"},
        {"texture2DArray", "texture"},
        {"texture2DArrayLod", "textureLod"},
        {"shadow1DArray", "texture"},
        {"shadow1DArrayLod", "textureLod"},
        {"shadow2DArray", "texture"},
    };
    for (const auto& [legacyName, coreName] : textureAliases) {
        replaceCodeIdentifier(result.source, legacyName, coreName);
    }
    replaceCodeIdentifier(result.source, "gl_MaxVaryingFloats", "128");

    // Core GLSL removed several fixed-function uniforms that were legal in
    // ARB geometry shaders. Existing matrix/fog/light-source names flow
    // through rewriteCompatShader; declare the remaining aggregate surfaces
    // only when this geometry source actually references them.
    std::string geometryCompatibilityPreamble;
    if (result.source.find("gl_DepthRange.") != std::string::npos) {
        replaceLiteral(result.source, "gl_DepthRange.near",
                       "appgl_DepthRangeNear");
        replaceLiteral(result.source, "gl_DepthRange.far",
                       "appgl_DepthRangeFar");
        replaceLiteral(result.source, "gl_DepthRange.diff",
                       "appgl_DepthRangeDiff");
        geometryCompatibilityPreamble +=
            "uniform float appgl_DepthRangeNear;\n"
            "uniform float appgl_DepthRangeFar;\n"
            "uniform float appgl_DepthRangeDiff;\n";
    }
    auto bridgeUniform = [&](const char* legacyName,
                             const char* replacement,
                             const char* declaration) {
        if (!containsCodeIdentifier(result.source, legacyName)) return false;
        replaceCodeIdentifier(result.source, legacyName, replacement);
        geometryCompatibilityPreamble += declaration;
        return true;
    };
    replaceCodeIdentifier(result.source, "gl_ModelViewMatrixInverseTranspose",
                          "transpose(gl_ModelViewMatrixInverse)");
    replaceCodeIdentifier(result.source, "gl_ProjectionMatrixInverseTranspose",
                          "transpose(gl_ProjectionMatrixInverse)");
    replaceCodeIdentifier(result.source,
                          "gl_ModelViewProjectionMatrixInverseTranspose",
                          "transpose(gl_ModelViewProjectionMatrixInverse)");
    replaceCodeIdentifier(result.source, "gl_ModelViewMatrixTranspose",
                          "transpose(gl_ModelViewMatrix)");
    replaceCodeIdentifier(result.source, "gl_ProjectionMatrixTranspose",
                          "transpose(gl_ProjectionMatrix)");
    replaceCodeIdentifier(result.source, "gl_ModelViewProjectionMatrixTranspose",
                          "transpose(gl_ModelViewProjectionMatrix)");
    bridgeUniform("gl_TextureMatrixInverseTranspose",
                  "appgl_TextureMatrixInverseTranspose",
                  "uniform mat4 appgl_TextureMatrixInverseTranspose[8];\n");
    bridgeUniform("gl_TextureMatrixTranspose", "appgl_TextureMatrixTranspose",
                  "uniform mat4 appgl_TextureMatrixTranspose[8];\n");
    bridgeUniform("gl_TextureMatrixInverse", "appgl_TextureMatrixInverse",
                  "uniform mat4 appgl_TextureMatrixInverse[8];\n");
    bridgeUniform("gl_NormalScale", "appgl_NormalScale",
                  "uniform float appgl_NormalScale;\n");
    bridgeUniform("gl_ClipPlane", "appgl_ClipPlane",
                  "uniform vec4 appgl_ClipPlane[8];\n");
    if (bridgeUniform("gl_Point", "appgl_Point",
                      "uniform AppGLPointParameters appgl_Point;\n")) {
        geometryCompatibilityPreamble.insert(
            0,
            "struct AppGLPointParameters { float size; float sizeMin; "
            "float sizeMax; float fadeThresholdSize; "
            "float distanceConstantAttenuation; "
            "float distanceLinearAttenuation; "
            "float distanceQuadraticAttenuation; };\n");
    }
    const bool usesFrontMaterial = containsCodeIdentifier(
        result.source, "gl_FrontMaterial");
    const bool usesBackMaterial = containsCodeIdentifier(
        result.source, "gl_BackMaterial");
    if (usesFrontMaterial || usesBackMaterial) {
        geometryCompatibilityPreamble +=
            "struct AppGLMaterialParameters { vec4 emission; vec4 ambient; "
            "vec4 diffuse; vec4 specular; float shininess; };\n";
        if (usesFrontMaterial) {
            replaceCodeIdentifier(result.source, "gl_FrontMaterial",
                                  "appgl_FrontMaterial");
            geometryCompatibilityPreamble +=
                "uniform AppGLMaterialParameters appgl_FrontMaterial;\n";
        }
        if (usesBackMaterial) {
            replaceCodeIdentifier(result.source, "gl_BackMaterial",
                                  "appgl_BackMaterial");
            geometryCompatibilityPreamble +=
                "uniform AppGLMaterialParameters appgl_BackMaterial;\n";
        }
    }
    const bool usesFrontLightModelProduct = containsCodeIdentifier(
        result.source, "gl_FrontLightModelProduct");
    const bool usesBackLightModelProduct = containsCodeIdentifier(
        result.source, "gl_BackLightModelProduct");
    if (usesFrontLightModelProduct || usesBackLightModelProduct) {
        geometryCompatibilityPreamble +=
            "struct AppGLLightModelProducts { vec4 sceneColor; };\n";
        if (usesFrontLightModelProduct) {
            replaceCodeIdentifier(result.source, "gl_FrontLightModelProduct",
                                  "appgl_FrontLightModelProduct");
            geometryCompatibilityPreamble +=
                "uniform AppGLLightModelProducts appgl_FrontLightModelProduct;\n";
        }
        if (usesBackLightModelProduct) {
            replaceCodeIdentifier(result.source, "gl_BackLightModelProduct",
                                  "appgl_BackLightModelProduct");
            geometryCompatibilityPreamble +=
                "uniform AppGLLightModelProducts appgl_BackLightModelProduct;\n";
        }
    }
    const bool usesFrontLightProduct = containsCodeIdentifier(
        result.source, "gl_FrontLightProduct");
    const bool usesBackLightProduct = containsCodeIdentifier(
        result.source, "gl_BackLightProduct");
    if (usesFrontLightProduct || usesBackLightProduct) {
        geometryCompatibilityPreamble +=
            "struct AppGLLightProducts { vec4 ambient; vec4 diffuse; "
            "vec4 specular; };\n";
        if (usesFrontLightProduct) {
            replaceCodeIdentifier(result.source, "gl_FrontLightProduct",
                                  "appgl_FrontLightProduct");
            geometryCompatibilityPreamble +=
                "uniform AppGLLightProducts appgl_FrontLightProduct[8];\n";
        }
        if (usesBackLightProduct) {
            replaceCodeIdentifier(result.source, "gl_BackLightProduct",
                                  "appgl_BackLightProduct");
            geometryCompatibilityPreamble +=
                "uniform AppGLLightProducts appgl_BackLightProduct[8];\n";
        }
    }
    bridgeUniform("gl_EyePlaneS", "appgl_EyePlaneS",
                  "uniform vec4 appgl_EyePlaneS[8];\n");
    bridgeUniform("gl_EyePlaneT", "appgl_EyePlaneT",
                  "uniform vec4 appgl_EyePlaneT[8];\n");
    bridgeUniform("gl_EyePlaneR", "appgl_EyePlaneR",
                  "uniform vec4 appgl_EyePlaneR[8];\n");
    bridgeUniform("gl_EyePlaneQ", "appgl_EyePlaneQ",
                  "uniform vec4 appgl_EyePlaneQ[8];\n");
    bridgeUniform("gl_ObjectPlaneS", "appgl_ObjectPlaneS",
                  "uniform vec4 appgl_ObjectPlaneS[8];\n");
    bridgeUniform("gl_ObjectPlaneT", "appgl_ObjectPlaneT",
                  "uniform vec4 appgl_ObjectPlaneT[8];\n");
    bridgeUniform("gl_ObjectPlaneR", "appgl_ObjectPlaneR",
                  "uniform vec4 appgl_ObjectPlaneR[8];\n");
    bridgeUniform("gl_ObjectPlaneQ", "appgl_ObjectPlaneQ",
                  "uniform vec4 appgl_ObjectPlaneQ[8];\n");

    auto inputToken = [](GLenum type) -> const char* {
        switch (type) {
            case GL_POINTS: return "points";
            case GL_LINES: return "lines";
            case GL_LINES_ADJACENCY: return "lines_adjacency";
            case GL_TRIANGLES: return "triangles";
            case GL_TRIANGLES_ADJACENCY: return "triangles_adjacency";
            default: return nullptr;
        }
    };
    auto outputToken = [](GLenum type) -> const char* {
        switch (type) {
            case GL_POINTS: return "points";
            case GL_LINE_STRIP: return "line_strip";
            case GL_TRIANGLE_STRIP: return "triangle_strip";
            default: return nullptr;
        }
    };
    const char* inToken = inputToken(effectiveInputType);
    const char* outToken = outputToken(plan.outputType);
    if (inToken == nullptr || outToken == nullptr) {
        result.valid = false;
        result.diagnostic = "invalid ARB geometry shader primitive request";
        return result;
    }

    std::string preamble = std::move(geometryCompatibilityPreamble);
    if (!layout.hasInputType) {
        preamble += "layout(" + std::string(inToken) + ") in;\n";
    }
    if (!layout.hasOutputType) {
        preamble += "layout(" + std::string(outToken) + ") out;\n";
    }
    if (!layout.hasVerticesOut) {
        preamble += "layout(max_vertices = " +
                    std::to_string(plan.verticesOut) + ") out;\n";
    }
    if (usesClipDistanceIn) {
        preamble += "in gl_PerVertex {\n";
        preamble += "    vec4 gl_Position;\n";
        preamble += "    float gl_PointSize;\n";
        preamble += "    float gl_ClipDistance[" +
                    std::to_string(clipDistanceWidth) + "];\n";
        preamble += "} gl_in[];\n";
        preamble += "out gl_PerVertex {\n";
        preamble += "    vec4 gl_Position;\n";
        preamble += "    float gl_PointSize;\n";
        preamble += "    float gl_ClipDistance[" +
                    std::to_string(clipDistanceWidth) + "];\n";
        preamble += "};\n";
    }
    if (usesPositionIn) {
        preamble += "vec4 appgl_PositionIn[" +
                    std::to_string(materializedInputCapacity) + "];\n";
    }
    if (usesPointSizeIn) {
        preamble += "float appgl_PointSizeIn[" +
                    std::to_string(materializedInputCapacity) + "];\n";
    }
    if (usesClipDistanceIn && !clipDecl.present) {
        preamble += "float appgl_ClipDistanceIn[" +
                    std::to_string(effectiveVerticesIn) + "][" +
                    std::to_string(clipDistanceWidth) + "];\n";
    }
    if (usesClipVertexIn) {
        preamble += "in vec4 appgl_ClipVertexFromVS[];\n";
        preamble += "vec4 appgl_ClipVertexIn[" +
                    std::to_string(materializedInputCapacity) + "];\n";
    }
    if (usesFrontColorIn) {
        preamble += "in vec4 appgl_FrontColorFromVS[];\n";
        preamble += "vec4 appgl_FrontColorIn[" +
                    std::to_string(materializedInputCapacity) + "];\n";
    }
    if (usesBackColorIn) {
        preamble += "in vec4 appgl_BackColorFromVS[];\n";
        preamble += "vec4 appgl_BackColorIn[" +
                    std::to_string(materializedInputCapacity) + "];\n";
    }
    if (usesFrontSecondaryColorIn) {
        preamble += "in vec4 appgl_FrontSecondaryColorFromVS[];\n";
        preamble += "vec4 appgl_FrontSecondaryColorIn[" +
                    std::to_string(materializedInputCapacity) + "];\n";
    }
    if (usesBackSecondaryColorIn) {
        preamble += "in vec4 appgl_BackSecondaryColorFromVS[];\n";
        preamble += "vec4 appgl_BackSecondaryColorIn[" +
                    std::to_string(materializedInputCapacity) + "];\n";
    }
    if (usesTexCoordIn) {
        preamble += "in vec4 appgl_TexCoordFromVS[][8];\n";
        preamble += "vec4 appgl_TexCoordIn[" +
                    std::to_string(materializedInputCapacity) + "][8];\n";
    }
    if (usesFogFragCoordIn) {
        preamble += "in float appgl_FogFragCoordFromVS[];\n";
        preamble += "float appgl_FogFragCoordIn[" +
                    std::to_string(materializedInputCapacity) + "];\n";
    }

    result.source.insert(geometryShader4PreambleOffset(result.source), preamble);

    if (usesPositionIn || usesPointSizeIn || usesClipDistanceIn ||
        usesClipVertexIn || usesFrontColorIn || usesBackColorIn ||
        usesFrontSecondaryColorIn || usesBackSecondaryColorIn ||
        usesTexCoordIn || usesFogFragCoordIn) {
        if (!replaceCodeFunctionIdentifier(
                result.source, "main", "appgl_ArbGeometryShader4Main")) {
            result.valid = false;
            result.diagnostic = "ARB geometry shader has no main entry point";
            return result;
        }
        result.source += "\nvoid main() {\n";
        result.source += "    for (int appgl_i = 0; appgl_i < " +
                         std::to_string(effectiveVerticesIn) + "; ++appgl_i) {\n";
        if (usesPositionIn) {
            result.source +=
                "        appgl_PositionIn[appgl_i] = gl_in[appgl_i].gl_Position;\n";
        }
        if (usesPointSizeIn) {
            result.source +=
                "        appgl_PointSizeIn[appgl_i] = gl_in[appgl_i].gl_PointSize;\n";
        }
        if (usesClipDistanceIn) {
            result.source += "        for (int appgl_j = 0; appgl_j < " +
                             std::to_string(clipDistanceWidth) +
                             "; ++appgl_j) {\n";
            result.source +=
                "            appgl_ClipDistanceIn[appgl_i][appgl_j] = "
                "gl_in[appgl_i].gl_ClipDistance[appgl_j];\n";
            result.source += "        }\n";
        }
        if (usesClipVertexIn) {
            result.source +=
                "        appgl_ClipVertexIn[appgl_i] = "
                "appgl_ClipVertexFromVS[appgl_i];\n";
        }
        if (usesFrontColorIn) {
            result.source +=
                "        appgl_FrontColorIn[appgl_i] = "
                "appgl_FrontColorFromVS[appgl_i];\n";
        }
        if (usesBackColorIn) {
            result.source +=
                "        appgl_BackColorIn[appgl_i] = "
                "appgl_BackColorFromVS[appgl_i];\n";
        }
        if (usesFrontSecondaryColorIn) {
            result.source +=
                "        appgl_FrontSecondaryColorIn[appgl_i] = "
                "appgl_FrontSecondaryColorFromVS[appgl_i];\n";
        }
        if (usesBackSecondaryColorIn) {
            result.source +=
                "        appgl_BackSecondaryColorIn[appgl_i] = "
                "appgl_BackSecondaryColorFromVS[appgl_i];\n";
        }
        if (usesTexCoordIn) {
            result.source +=
                "        for (int appgl_tc = 0; appgl_tc < 8; ++appgl_tc) {\n";
            result.source +=
                "            appgl_TexCoordIn[appgl_i][appgl_tc] = "
                "appgl_TexCoordFromVS[appgl_i][appgl_tc];\n";
            result.source += "        }\n";
        }
        if (usesFogFragCoordIn) {
            result.source +=
                "        appgl_FogFragCoordIn[appgl_i] = "
                "appgl_FogFragCoordFromVS[appgl_i];\n";
        }
        result.source += "    }\n";
        result.source += "    appgl_ArbGeometryShader4Main();\n";
        result.source += "}\n";
    }
    result.didRewrite = true;
    return result;
}

std::string rewriteGeometryShader4VertexTransport(
    std::string_view normalizedVertexSource,
    const GeometryShader4LegacyInputUsage& usage)
{
    std::string result(normalizedVertexSource);
    if (usage.clipVertex) {
        replaceIdentifier(result, "appgl_ClipVertex",
                          "appgl_ClipVertexFromVS");
    }
    if (usage.frontColor) {
        replaceIdentifier(result, "appgl_FrontColor",
                          "appgl_FrontColorFromVS");
    }
    if (usage.backColor) {
        replaceIdentifier(result, "appgl_BackColor",
                          "appgl_BackColorFromVS");
    }
    if (usage.frontSecondaryColor) {
        replaceIdentifier(result, "appgl_FrontSecondaryColor",
                          "appgl_FrontSecondaryColorFromVS");
    }
    if (usage.backSecondaryColor) {
        replaceIdentifier(result, "appgl_BackSecondaryColor",
                          "appgl_BackSecondaryColorFromVS");
    }
    if (usage.texCoord) {
        replaceIdentifier(result, "appgl_TexCoord",
                          "appgl_TexCoordFromVS");
    }
    if (usage.fogFragCoord) {
        replaceIdentifier(result, "appgl_FogFragCoord",
                          "appgl_FogFragCoordFromVS");
    }
    return result;
}

namespace {

bool findCompatColorOutputDeclaration(std::string& source,
                                      const char* name,
                                      std::size_t& statementStart,
                                      std::size_t& semicolon)
{
    const std::string clean = maskCommentsAndStrings(source);
    std::size_t pos = 0;
    while ((pos = clean.find(name, pos)) != std::string::npos) {
        if (!sourceHasWordAt(clean, pos, name)) {
            ++pos;
            continue;
        }
        if (!findGlobalStorageDeclaration(clean, pos, statementStart,
                                          semicolon)) {
            pos += std::strlen(name);
            continue;
        }
        const std::string_view statement(
            clean.data() + statementStart, semicolon - statementStart);
        if (containsIdentifier(statement, "out")) {
            return true;
        }
        pos += std::strlen(name);
    }
    return false;
}

void ensureCompatColorProducerOutputsImpl(
    std::string& rewrittenProducerSource,
    bool primary,
    bool secondary,
    std::string_view primaryInterpolationQualifier,
    std::string_view secondaryInterpolationQualifier,
    const CompatColorInterfaceLocations& locations)
{
    std::string declarations;
    auto ensureOutput = [&](std::string_view qualifier,
                            const char* name,
                            int location) {
        std::size_t statementStart = 0;
        std::size_t semicolon = 0;
        if (findCompatColorOutputDeclaration(
                rewrittenProducerSource, name, statementStart, semicolon)) {
            if (location >= 0) {
                const std::string clean =
                    maskCommentsAndStrings(rewrittenProducerSource);
                const std::string_view statement(
                    clean.data() + statementStart,
                    semicolon - statementStart);
                if (!containsIdentifier(statement, "location")) {
                    std::size_t insertAt = statementStart;
                    while (insertAt < semicolon &&
                           std::isspace(static_cast<unsigned char>(
                               rewrittenProducerSource[insertAt]))) {
                        ++insertAt;
                    }
                    rewrittenProducerSource.insert(
                        insertAt,
                        "layout(location = " + std::to_string(location) +
                            ") ");
                }
            }
            return;
        }
        if (location >= 0) {
            declarations.append("layout(location = ")
                .append(std::to_string(location))
                .append(") ");
        }
        if (!qualifier.empty()) {
            declarations.append(qualifier).append(" ");
        }
        declarations.append("out vec4 ").append(name).append(";\n");
    };
    if (primary) {
        ensureOutput(primaryInterpolationQualifier, "appgl_FrontColor",
                     locations.frontColor);
        ensureOutput(primaryInterpolationQualifier, "appgl_BackColor",
                     locations.backColor);
    }
    if (secondary) {
        ensureOutput(secondaryInterpolationQualifier,
                     "appgl_FrontSecondaryColor",
                     locations.frontSecondaryColor);
        ensureOutput(secondaryInterpolationQualifier,
                     "appgl_BackSecondaryColor",
                     locations.backSecondaryColor);
    }
    if (declarations.empty()) {
        return;
    }
    rewrittenProducerSource.insert(
        geometryShader4PreambleOffset(rewrittenProducerSource), declarations);
}

} // namespace

void ensureCompatColorProducerOutputs(
    std::string& rewrittenProducerSource,
    bool primary,
    bool secondary,
    std::string_view primaryInterpolationQualifier,
    std::string_view secondaryInterpolationQualifier,
    const CompatColorInterfaceLocations& locations)
{
    ensureCompatColorProducerOutputsImpl(
        rewrittenProducerSource, primary, secondary,
        primaryInterpolationQualifier,
        secondaryInterpolationQualifier, locations);
}

CompatShaderRewriteResult rewriteCompatShader(std::string_view source,
                                              GLenum stage,
                                              CompatShaderRewriteMode mode) {
    CompatShaderRewriteResult result;
    result.source.assign(source.begin(), source.end());
    normalizeDuplicatedEsVersionPreamble(result.source);
    qualifyEsOpaqueUniforms(result.source);

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
    const bool isGeometry = (stage == GL_GEOMETRY_SHADER);
    const bool isTessControl = (stage == GL_TESS_CONTROL_SHADER);
    const bool isTessEvaluation = (stage == GL_TESS_EVALUATION_SHADER);
    const bool isArbGeometryShader4LinkView =
        mode == CompatShaderRewriteMode::ArbGeometryShader4LinkView;
    const bool isArbGeometryStage =
        isGeometry && isArbGeometryShader4LinkView;
    const bool isStandardGeometryStage =
        isGeometry && !isArbGeometryShader4LinkView;
    const bool hasGpuShader4Directive =
        result.source.find("GL_EXT_gpu_shader4") != std::string::npos;
    const bool legacyColorBuiltinsLegal =
        isArbGeometryStage || usesLegacyColorBuiltinProfile(result.source);

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
    legacy.usesFtransform =
        isVertex && usesLegacyCompatProfile(result.source) &&
        containsCodeFunctionIdentifier(result.source, "ftransform");
    if (legacy.usesFtransform) {
        result.usage.modelViewProjection = true;
    }
    if (isVertex || isArbGeometryStage) {
        std::size_t originalVersionStart = std::string::npos;
        const std::size_t originalVersionEnd =
            findVersionLineEnd(result.source, &originalVersionStart);
        const int originalVersion =
            originalVersionEnd == std::string::npos
                ? -1
                : parseVersionNumber(std::string_view(result.source).substr(
                      originalVersionStart,
                      originalVersionEnd - originalVersionStart));
        const bool hasExplicitClipOutput =
            containsCodeIdentifier(result.source, "gl_ClipVertex") ||
            containsCodeIdentifier(result.source, "gl_ClipDistance");
        legacy.synthesizesLegacyClipPlanes =
            appglCompatProfileEnabled() &&
            originalVersion == 130 && !hasExplicitClipOutput;
        if (isVertex) {
            legacy.attrVertex = legacy.usesFtransform ||
                                containsIdentifier(source, "gl_Vertex");
            legacy.attrNormal = containsIdentifier(source, "gl_Normal");
            legacy.attrColor =
                legacyColorBuiltinsLegal &&
                containsCodeIdentifier(result.source, "gl_Color");
            legacy.attrSecondaryColor =
                legacyColorBuiltinsLegal &&
                containsCodeIdentifier(result.source, "gl_SecondaryColor");
            scanMultiTexCoord(source, legacy.attrMultiTexCoord);
        }
        legacy.usesClipVertex = containsIdentifier(source, "gl_ClipVertex");
    }
    if (isFragment) {
        legacy.fragColor = containsCodeIdentifier(result.source, "gl_FragColor");
        legacy.fragDataMax = scanFragDataMax(source);
        legacy.usesFragmentColor =
            legacyColorBuiltinsLegal &&
            containsCodeIdentifier(result.source, "gl_Color");
        legacy.usesFragmentSecondaryColor =
            legacyColorBuiltinsLegal &&
            containsCodeIdentifier(result.source, "gl_SecondaryColor");
        if (legacy.usesFragmentColor) {
            legacy.fragmentColorInterpolationQualifier =
                globalStorageInterpolationQualifier(result.source,
                                                    "gl_Color");
        }
        if (legacy.usesFragmentSecondaryColor) {
            legacy.fragmentSecondaryColorInterpolationQualifier =
                globalStorageInterpolationQualifier(result.source,
                                                    "gl_SecondaryColor");
        }
    }
    legacy.texCoordMax = scanTexCoordMax(source);
    // gl_Fog.* field accesses — individual scan per field so the
    // preamble declares only what's used.
    legacy.usesFogColor   = (source.find("gl_Fog.color")   != std::string_view::npos);
    legacy.usesFogDensity = (source.find("gl_Fog.density") != std::string_view::npos);
    legacy.usesFogStart   = (source.find("gl_Fog.start")   != std::string_view::npos);
    legacy.usesFogEnd     = (source.find("gl_Fog.end")     != std::string_view::npos);
    legacy.usesFogScale   = (source.find("gl_Fog.scale")   != std::string_view::npos);
    legacy.usesFogFragCoord = containsIdentifier(source, "gl_FogFragCoord");
    legacy.usesFogFragCoordInput =
        isGeometry && containsFogFragCoordInputAccess(source);
    if (legacyColorBuiltinsLegal &&
        (isStandardGeometryStage || isTessControl || isTessEvaluation)) {
        legacy.usesFrontColorInput = containsIndexedInterfaceMemberAccess(
            result.source, "gl_in", "gl_FrontColor");
        legacy.usesBackColorInput = containsIndexedInterfaceMemberAccess(
            result.source, "gl_in", "gl_BackColor");
        legacy.usesFrontSecondaryColorInput =
            containsIndexedInterfaceMemberAccess(
                result.source, "gl_in", "gl_FrontSecondaryColor");
        legacy.usesBackSecondaryColorInput =
            containsIndexedInterfaceMemberAccess(
                result.source, "gl_in", "gl_BackSecondaryColor");
    }
    if (legacyColorBuiltinsLegal && isTessControl) {
        legacy.usesFrontColor = containsIndexedInterfaceMemberAccess(
            result.source, "gl_out", "gl_FrontColor");
        legacy.usesBackColor = containsIndexedInterfaceMemberAccess(
            result.source, "gl_out", "gl_BackColor");
        legacy.usesFrontSecondaryColor =
            containsIndexedInterfaceMemberAccess(
                result.source, "gl_out", "gl_FrontSecondaryColor");
        legacy.usesBackSecondaryColor =
            containsIndexedInterfaceMemberAccess(
                result.source, "gl_out", "gl_BackSecondaryColor");
    } else if (legacyColorBuiltinsLegal &&
               (isVertex || isArbGeometryStage ||
                isStandardGeometryStage || isTessEvaluation)) {
        legacy.usesFrontColor = containsUnqualifiedCodeIdentifier(
            result.source, "gl_FrontColor");
        legacy.usesBackColor = containsUnqualifiedCodeIdentifier(
            result.source, "gl_BackColor");
        legacy.usesFrontSecondaryColor = containsUnqualifiedCodeIdentifier(
            result.source, "gl_FrontSecondaryColor");
        legacy.usesBackSecondaryColor = containsUnqualifiedCodeIdentifier(
            result.source, "gl_BackSecondaryColor");
    }
    if (legacy.usesFrontColor || legacy.usesBackColor ||
        legacy.usesFrontSecondaryColor || legacy.usesBackSecondaryColor) {
        if (legacy.usesFrontColor) {
            legacy.frontColorInterpolationQualifier =
                globalStorageInterpolationQualifier(result.source,
                                                    "gl_FrontColor");
        }
        if (legacy.usesBackColor) {
            legacy.backColorInterpolationQualifier =
                globalStorageInterpolationQualifier(result.source,
                                                    "gl_BackColor");
        }
        if (legacy.usesFrontSecondaryColor) {
            legacy.frontSecondaryColorInterpolationQualifier =
                globalStorageInterpolationQualifier(
                    result.source, "gl_FrontSecondaryColor");
        }
        if (legacy.usesBackSecondaryColor) {
            legacy.backSecondaryColorInterpolationQualifier =
                globalStorageInterpolationQualifier(
                    result.source, "gl_BackSecondaryColor");
        }
    }
    legacy.usesTextureEnvColor =
        containsIdentifier(source, "gl_TextureEnvColor");
    legacy.usesLightModelAmbient =
        (source.find("gl_LightModel.ambient") != std::string_view::npos);
    scanLightSourceFields(source, legacy);
    legacy.rewroteTexture2D = containsIdentifier(source, "texture2D");
    legacy.rewroteTextureCube = containsIdentifier(source, "textureCube");
    legacy.rewroteShadow2DProj = containsIdentifier(source, "shadow2DProj");
    const bool needsExplicitLocationPreamble =
        (isVertex &&
         (legacy.attrVertex || legacy.attrNormal || legacy.attrColor ||
          legacy.attrSecondaryColor ||
          legacy.attrMultiTexCoord[0] || legacy.attrMultiTexCoord[1] ||
          legacy.attrMultiTexCoord[2] || legacy.attrMultiTexCoord[3] ||
          legacy.attrMultiTexCoord[4] || legacy.attrMultiTexCoord[5] ||
          legacy.attrMultiTexCoord[6] || legacy.attrMultiTexCoord[7])) ||
        (isFragment && (legacy.fragColor || legacy.fragDataMax >= 0));

    // ---- 2. Version line — compat/pre-140 → core 330 rewrite -------------
    std::size_t versionStart = std::string::npos;
    std::size_t versionEol = findVersionLineEnd(result.source, &versionStart);
    if (versionEol != std::string::npos) {
        const std::string_view versionLine(
            result.source.data() + versionStart, versionEol - versionStart);
        const int versionNumber = parseVersionNumber(versionLine);
        const bool isCompat = containsIdentifier(versionLine, "compatibility");
        // fw¹⁹ version-floor upgrade: glslang's Vulkan client front-end
        // rejects any desktop shader below `#version 140`. Separately,
        // the synthesized legacy attribute / fragment-output preamble
        // uses explicit `layout(location=...)` qualifiers, which desktop
        // GLSL accepts as core at 330. Upgrade only when the emitted
        // preamble actually needs those qualifiers so unrelated #version
        // 140/150 shaders keep their original frontend surface.
        const bool needsLineContinuationFloor =
            versionNumber > 0 && versionNumber < 420 &&
            result.source.find("\\\n") != std::string::npos &&
            (legacy.usesFrontColor || legacy.usesBackColor ||
             legacy.usesFrontSecondaryColor ||
             legacy.usesBackSecondaryColor ||
             legacy.usesFrontColorInput || legacy.usesBackColorInput ||
             legacy.usesFrontSecondaryColorInput ||
             legacy.usesBackSecondaryColorInput);
        const bool needsFloorUpgrade =
            versionNumber > 0 &&
            ((versionNumber < 140 && !isCompat) ||
             (hasGpuShader4Directive && versionNumber < 150) ||
             (needsExplicitLocationPreamble && versionNumber < 330) ||
             needsLineContinuationFloor);
        if (needsFloorUpgrade) {
            legacy.upgradedVersion = true;
            // Glslang exposes preprocessor line continuations to its Vulkan
            // frontend only at GLSL 4.20+. Piglit's compatibility TES uses
            // a multiline INTERP_QUAD macro, so select that frontend floor
            // when legacy colors and a continued directive occur together;
            // ordinary legacy inputs continue to use the 3.30 floor.
            const std::string_view replacement =
                needsLineContinuationFloor
                    ? "#version 420 core"
                    : "#version 330 core";
            const std::size_t lineLen = versionEol - versionStart;
            result.source.replace(versionStart, lineLen, replacement);
            versionEol = versionStart + replacement.size();
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
    if (legacy.attrColor || legacy.attrSecondaryColor ||
        legacy.usesFrontColor || legacy.usesBackColor ||
        legacy.usesFrontSecondaryColor || legacy.usesBackSecondaryColor ||
        legacy.usesFrontColorInput || legacy.usesBackColorInput ||
        legacy.usesFrontSecondaryColorInput ||
        legacy.usesBackSecondaryColorInput ||
        legacy.usesFragmentColor || legacy.usesFragmentSecondaryColor) {
        (void)stripArbCompatibilityDirectives(result.source);
    }

    // GLSL 1.30 compatibility exposes gl_MaxClipPlanes, but glslang's
    // Vulkan front-end reports the legacy constant as zero. AppGL exposes
    // eight legacy clip planes, matching its clip-distance capacity.
    if (containsIdentifier(source, "gl_MaxClipPlanes") &&
        result.source.find("#define gl_MaxClipPlanes") == std::string::npos) {
        const std::string compatDefine = "#define gl_MaxClipPlanes 8\n";
        const std::size_t versionPos = result.source.find("#version");
        if (versionPos != std::string::npos) {
            const std::size_t eol = result.source.find('\n', versionPos);
            const std::size_t insertAt =
                eol == std::string::npos ? result.source.size() : eol + 1;
            result.source.insert(insertAt, compatDefine);
        } else {
            result.source.insert(0, compatDefine);
        }
        result.didRewrite = true;
    }

    // ---- 2b. Strip extension directives unknown to glslang ----------------
    // Under Vulkan-targeted compilation, some GL_ARB extensions exist as
    // core features in Vulkan/SPIR-V but glslang's Vulkan front-end
    // doesn't register them as known extension names. The `#extension`
    // directive then fails with "extension not supported." Comment out
    // only those directives — extensions that glslang DOES recognize
    // (like GL_ARB_compute_shader, GL_ARB_shader_image_load_store) must
    // be kept so glslang enables the corresponding functionality.
    {
        static const char* const kUnknownExtensions[] = {
            "GL_ARB_arrays_of_arrays",
            "GL_ARB_cull_distance",
            "GL_ARB_shader_" "subroutine",
            "GL_ARB_texture_query_levels",
            "GL_EXT_gpu_shader4",
        };
        bool strippedArraysOfArrays = false;
        bool strippedCullDistance = false;
        bool strippedTextureQueryLevels = false;
        bool strippedGpuShader4 = false;
        for (const char* ext : kUnknownExtensions) {
            std::string needle = std::string("#extension ") + ext;
            std::size_t pos = 0;
            while ((pos = result.source.find(needle, pos)) != std::string::npos) {
                // Comment out the entire line by replacing `#extension`
                // with `// xtension` (same length to preserve offsets).
                result.source.replace(pos, 10, "// xtensio");
                result.didRewrite = true;
                pos += 10;
                if (std::string(ext) == "GL_ARB_arrays_of_arrays") {
                    strippedArraysOfArrays = true;
                } else if (std::string(ext) == "GL_ARB_cull_distance") {
                    strippedCullDistance = true;
                } else if (std::string(ext) == "GL_ARB_texture_query_levels") {
                    strippedTextureQueryLevels = true;
                } else if (std::string(ext) == "GL_EXT_gpu_shader4") {
                    strippedGpuShader4 = true;
                }
            }
        }
        (void)strippedGpuShader4;
        if (strippedArraysOfArrays) {
            // Glslang's Vulkan front-end does not recognize the ARB token,
            // and after we comment out the directive it still gates
            // arrays-of-arrays syntax on GLSL 4.30. Upgrade the frontend
            // view only; AppGL still exposes the original GL extension.
            std::size_t versionPos = result.source.find("#version");
            if (versionPos != std::string::npos) {
                std::size_t eol = result.source.find('\n', versionPos);
                if (eol != std::string::npos) {
                    const std::string_view versionLine(
                        result.source.data() + versionPos,
                        eol - versionPos);
                    const int versionNumber = parseVersionNumber(versionLine);
                    if (versionNumber > 0 && versionNumber < 430) {
                        const std::size_t lineLen = eol - versionPos;
                        const std::string newLine = "#version 430 core";
                        result.source.replace(versionPos, lineLen, newLine);
                    }
                }
            }
        }
        if (strippedTextureQueryLevels) {
            // Glslang's Vulkan front-end does not know the ARB extension
            // token, but textureQueryLevels is accepted as core GLSL 4.30.
            // CTS uses #version 400 + the extension; upgrade that frontend
            // view while preserving the original GL-facing extension advert.
            std::size_t versionPos = result.source.find("#version");
            if (versionPos != std::string::npos) {
                std::size_t eol = result.source.find('\n', versionPos);
                if (eol != std::string::npos) {
                    const std::string_view versionLine(
                        result.source.data() + versionPos,
                        eol - versionPos);
                    const int versionNumber = parseVersionNumber(versionLine);
                    if (versionNumber > 0 && versionNumber < 430) {
                        const std::size_t lineLen = eol - versionPos;
                        const std::string newLine = "#version 430 core";
                        result.source.replace(versionPos, lineLen, newLine);
                    }
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
            // Sprint 17 Day 9+ R13 sub-bank items 7+8: when the source
            // declares `#extension GL_ARB_cull_distance` and we strip
            // it (because glslang's Vulkan front-end doesn't recognize
            // the extension token), the user's `in float gl_CullDistance
            // [N];` / `out float gl_CullDistance[N];` redeclarations
            // and any direct `gl_CullDistance[i]` reads in the shader
            // body lose glslang's built-in identifier — under
            // `#version 150` (or any pre-450) gl_CullDistance is
            // unknown without the extension, so glslang reports
            // "identifiers starting with gl_ are reserved" on the
            // redeclaration line. Upgrade `#version` to 460 so
            // gl_CullDistance is accepted as a core built-in (added
            // GLSL 4.5). The 460 target matches the rest of AppGL's
            // SPIR-V translation context (max GL we advertise) and
            // keeps the Vulkan front-end happy. Surfaces:
            // `cull_distance.functional_test_item_7_*` (24F) +
            // `cull_distance.functional_test_item_8_*_points` (8F).
            std::size_t versionPos = result.source.find("#version");
            if (versionPos != std::string::npos) {
                std::size_t eol = result.source.find('\n', versionPos);
                if (eol != std::string::npos) {
                    const std::string_view versionLine(
                        result.source.data() + versionPos,
                        eol - versionPos);
                    const int versionNumber = parseVersionNumber(versionLine);
                    if (versionNumber > 0 && versionNumber < 450) {
                        // Replace `#version <N>` (and any optional
                        // profile token; the test sources use just
                        // `#version 150`) with `#version 460 core`.
                        const std::size_t lineLen = eol - versionPos;
                        const std::string newLine = "#version 460 core";
                        result.source.replace(versionPos, lineLen, newLine);
                        // Adjust eol to the new line length so the
                        // `compatDefines` insert below lands at the
                        // right offset.
                        eol = versionPos + newLine.size();
                    }
                }
            }
            // Use #define rather than `const int` declarations — the shader
            // still has subsequent `#extension` directives (GL_ARB_compute_shader
            // etc.), and GLSL requires all #extensions to precede any regular
            // declarations. Preprocessor defines are safe to emit before them.
            // GL 4.5 spec §23.4 guarantees both values are at least 8.
            const std::string compatDefines =
                "\n#define gl_MaxCullDistances 8\n"
                "#define gl_MaxCombinedClipAndCullDistances 8\n";
            std::size_t versionPos2 = result.source.find("#version");
            if (versionPos2 != std::string::npos) {
                std::size_t eol2 = result.source.find('\n', versionPos2);
                if (eol2 != std::string::npos) {
                    result.source.insert(eol2 + 1, compatDefines);
                }
            } else {
                result.source.insert(0, compatDefines);
            }
        }
    }

    // ---- 2c. GL_KHR_blend_equation_advanced front-end shim --------------
    //
    // AppGL implements the extension's draw-time semantics outside SPIR-V:
    // the fragment shader qualifier is metadata for validation, not a value
    // that needs to survive into MSL. Glslang's Vulkan front-end does not
    // reliably accept the KHR directive/layout vocabulary, so keep the GLSL
    // preprocessor contract (`GL_KHR_blend_equation_advanced == 1`) and strip
    // the extension-only declarations before translation.
    bool didAdvancedBlendFixup = false;
    const bool hasAdvancedBlendSyntax =
        result.source.find("GL_KHR_blend_equation_advanced") !=
            std::string::npos ||
        result.source.find("blend_support_") != std::string::npos;
    if (hasAdvancedBlendSyntax) {
        const std::string defineLine =
            "#ifndef GL_KHR_blend_equation_advanced\n"
            "#define GL_KHR_blend_equation_advanced 1\n"
            "#endif\n";
        if (result.source.find("#define GL_KHR_blend_equation_advanced") ==
            std::string::npos) {
            std::size_t insertAt = 0;
            const std::size_t versionPos = result.source.find("#version");
            if (versionPos != std::string::npos) {
                const std::size_t eol = result.source.find('\n', versionPos);
                insertAt = (eol == std::string::npos) ? result.source.size() : eol + 1;
            }
            result.source.insert(insertAt, defineLine);
            didAdvancedBlendFixup = true;
        }

        std::size_t pos = 0;
        while ((pos = result.source.find("#extension GL_KHR_blend_equation_advanced", pos)) !=
               std::string::npos) {
            result.source.replace(pos, 10, "// xtensio");
            didAdvancedBlendFixup = true;
            pos += 10;
        }

        pos = 0;
        while ((pos = result.source.find("blend_support_", pos)) != std::string::npos) {
            std::size_t lineStart = result.source.rfind('\n', pos);
            lineStart = (lineStart == std::string::npos) ? 0 : lineStart + 1;
            std::size_t lineEnd = result.source.find('\n', pos);
            if (lineEnd == std::string::npos) lineEnd = result.source.size();
            const std::string_view line(
                result.source.data() + lineStart, lineEnd - lineStart);
            if (line.find("layout") != std::string_view::npos &&
                line.find("out") != std::string_view::npos) {
                result.source.insert(lineStart, "//");
                didAdvancedBlendFixup = true;
                pos = lineEnd + 2;
            } else {
                pos += sizeof("blend_support_") - 1;
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
        result.wasCompatProfile || legacy.upgradedVersion || needPreamble ||
        didAdvancedBlendFixup;
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

    bool didGpuShader4TruncateFixup = false;
    if (hasGpuShader4Directive && containsIdentifier(result.source, "truncate")) {
        didGpuShader4TruncateFixup =
            replaceFunctionIdentifier(result.source, "truncate", "trunc");
    }
    bool didGpuShader4LexicalFixup = false;
    if (hasGpuShader4Directive) {
        if (isVertex && containsIdentifier(result.source, "attribute")) {
            didGpuShader4LexicalFixup =
                replaceCodeIdentifier(result.source, "attribute", "in");
        }
        if (containsIdentifier(result.source, "unsigned")) {
            didGpuShader4LexicalFixup =
                replaceCodeUnsignedInt(result.source) || didGpuShader4LexicalFixup;
        }
    }
    bool didGpuShader4ShadowFixup = false;
    std::string gpuShader4ShadowPreamble;
    if (result.source.find("shadow") != std::string::npos) {
        for (const auto& wrapper : kGpuShader4ShadowWrappers) {
            if (!hasGpuShader4Directive &&
                !wrapper.coreLegacyWithoutGpuShader4) {
                continue;
            }
            if (!containsIdentifier(result.source, wrapper.legacyName)) {
                continue;
            }
            bool replaced = false;
            if (!hasGpuShader4Directive) {
                // Legacy Piglit shaders commonly route these two builtins
                // through an object-like macro (`#define textureInst
                // shadow1D`). The code-only call rewriter deliberately skips
                // preprocessor lines, so rewrite the complete identifier for
                // this narrowly approved pair before adding the wrapper.
                replaceIdentifier(result.source,
                                  wrapper.legacyName,
                                  wrapper.helperName);
                replaced = true;
            } else {
                replaced = replaceCodeFunctionIdentifier(result.source,
                                                         wrapper.legacyName,
                                                         wrapper.helperName);
            }
            if (replaced) {
                gpuShader4ShadowPreamble.append(wrapper.commonSource);
                if (isFragment && wrapper.fragmentSource) {
                    gpuShader4ShadowPreamble.append(wrapper.fragmentSource);
                }
                didGpuShader4ShadowFixup = true;
            }
        }
    }
    bool didGpuShader4TextureAliasFixup = false;
    if (hasGpuShader4Directive &&
        (result.source.find("texture") != std::string::npos ||
         result.source.find("texelFetch") != std::string::npos)) {
        for (const auto& alias : kGpuShader4TextureAliases) {
            if (!containsIdentifier(result.source, alias.legacyName)) {
                continue;
            }
            didGpuShader4TextureAliasFixup =
                replaceCodeFunctionIdentifier(result.source,
                                              alias.legacyName,
                                              alias.coreName) ||
                didGpuShader4TextureAliasFixup;
        }
    }
    const bool legacyTextureAliasPath =
        result.wasCompatProfile || legacy.upgradedVersion ||
        versionEol == std::string::npos;
    bool didLegacyDesktopTextureAliasFixup = false;
    if (legacyTextureAliasPath && result.source.find("texture") != std::string::npos) {
        didLegacyDesktopTextureAliasFixup =
            replaceLegacyDesktopTextureCalls(result.source);
    }
    bool didLegacyTextureAliasMacroFixup = false;
    if (legacyTextureAliasPath &&
        result.source.find("#define") != std::string::npos &&
        result.source.find("texture") != std::string::npos) {
        didLegacyTextureAliasMacroFixup =
            rewriteLegacyTextureAliasMacros(result.source);
    }

    // ---- 3c. `__VERSION__` fidelity across a `#version` promotion --------
    // Every version-changing site above (the pre-140 floor upgrade to
    // `#version 330 core`, the 420 line-continuation floor, the
    // stripped-ARB 430/460 upgrades) leaves glslang reporting the
    // REWRITTEN number from `__VERSION__`. Compare the version the shader
    // DECLARED against the version actually present now, and restore the
    // declared one in the macro's ordinary references. This runs last so
    // it sees the final `#version`, whichever site produced it.
    //
    // Deliberately out of scope: a source that declared no `#version` at
    // all. GLSL 4.60 §3.3 says such a shader targets 1.10, but nothing
    // here rewrites it — ShaderTranslator::compileGLSL supplies glslang's
    // default version instead, so the discrepancy is not this rewriter's
    // to repair and no measured row exercises it.
    bool didVersionMacroFixup = false;
    if (result.source.find("__VERSION__") != std::string::npos) {
        const std::string originalSource(source.begin(), source.end());
        std::size_t declaredStart = std::string::npos;
        const std::size_t declaredEol =
            findVersionLineEnd(originalSource, &declaredStart);
        std::size_t currentStart = std::string::npos;
        const std::size_t currentEol =
            findVersionLineEnd(result.source, &currentStart);
        if (declaredEol != std::string::npos &&
            currentEol != std::string::npos) {
            const int declaredVersion = parseVersionNumber(std::string_view(
                originalSource.data() + declaredStart,
                declaredEol - declaredStart));
            const int currentVersion = parseVersionNumber(std::string_view(
                result.source.data() + currentStart,
                currentEol - currentStart));
            if (declaredVersion > 0 && currentVersion > 0 &&
                currentVersion != declaredVersion) {
                didVersionMacroFixup = substituteDeclaredVersionMacro(
                    result.source, declaredVersion);
            }
        }
    }

    if (!didAnyRewrite && !didSamplerFixup && !didGpuShader4TruncateFixup &&
        !didGpuShader4LexicalFixup && !didGpuShader4ShadowFixup &&
        !didGpuShader4TextureAliasFixup &&
        !didLegacyDesktopTextureAliasFixup &&
        !didLegacyTextureAliasMacroFixup &&
        !didVersionMacroFixup) {
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
        if (isArbGeometryShader4LinkView && legacy.texCoordMax >= 0) {
            eraseGlobalStorageDeclaration(result.source, "gl_TexCoord");
        }
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
        (void)eraseGlobalStorageDeclaration(result.source, "gl_Color");
        replaceCodeIdentifier(result.source, "gl_Color", "appgl_Color");
    }
    if (legacy.attrSecondaryColor) {
        (void)eraseGlobalStorageDeclaration(result.source,
                                            "gl_SecondaryColor");
        replaceCodeIdentifier(result.source,
                              "gl_SecondaryColor",
                              "appgl_SecondaryColor");
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
    if (legacy.usesFogFragCoordInput) {
        rewriteFogFragCoordInputAccess(result.source);
    }
    if (legacy.usesFogFragCoord) {
        replaceIdentifier(result.source,
                          "gl_FogFragCoord",
                          "appgl_FogFragCoord");
    }

    // Standard GS/TCS/TES compatibility colors live as gl_in[] / gl_out[]
    // members. Vulkan-targeted glslang omits those legacy gl_PerVertex
    // members, so carry them through ordinary, stage-specific varying
    // arrays. Distinct boundary names avoid an illegal same-scope in/out
    // declaration collision in TCS and GS sources.
    const char* colorInputDestination = nullptr;
    if (isStandardGeometryStage) {
        colorInputDestination = "Geometry";
    } else if (isTessControl) {
        colorInputDestination = "TessControl";
    } else if (isTessEvaluation) {
        colorInputDestination = "TessEvaluation";
    }
    auto rewriteColorInput = [&](bool used,
                                 const char* legacyName,
                                 const char* internalBase) {
        if (!used || colorInputDestination == nullptr) return;
        const std::string transport = legacyColorTransportName(
            internalBase, colorInputDestination);
        (void)rewriteIndexedInterfaceMemberAccess(
            result.source, "gl_in", legacyName, transport);
    };
    rewriteColorInput(legacy.usesFrontColorInput,
                      "gl_FrontColor", "appgl_FrontColor");
    rewriteColorInput(legacy.usesBackColorInput,
                      "gl_BackColor", "appgl_BackColor");
    rewriteColorInput(legacy.usesFrontSecondaryColorInput,
                      "gl_FrontSecondaryColor",
                      "appgl_FrontSecondaryColor");
    rewriteColorInput(legacy.usesBackSecondaryColorInput,
                      "gl_BackSecondaryColor",
                      "appgl_BackSecondaryColor");

    auto rewriteTessControlColorOutput = [&](bool used,
                                             const char* legacyName,
                                             const char* internalBase) {
        if (!used || !isTessControl) return;
        const std::string transport = legacyColorTransportName(
            internalBase, "TessEvaluation");
        (void)rewriteIndexedInterfaceMemberAccess(
            result.source, "gl_out", legacyName, transport);
    };
    rewriteTessControlColorOutput(legacy.usesFrontColor,
                                  "gl_FrontColor", "appgl_FrontColor");
    rewriteTessControlColorOutput(legacy.usesBackColor,
                                  "gl_BackColor", "appgl_BackColor");
    rewriteTessControlColorOutput(legacy.usesFrontSecondaryColor,
                                  "gl_FrontSecondaryColor",
                                  "appgl_FrontSecondaryColor");
    rewriteTessControlColorOutput(legacy.usesBackSecondaryColor,
                                  "gl_BackSecondaryColor",
                                  "appgl_BackSecondaryColor");

    if (legacy.usesFrontColor) {
        (void)eraseGlobalStorageDeclaration(result.source, "gl_FrontColor");
        replaceCodeIdentifier(result.source,
                              "gl_FrontColor", "appgl_FrontColor");
    }
    if (legacy.usesBackColor) {
        (void)eraseGlobalStorageDeclaration(result.source, "gl_BackColor");
        replaceCodeIdentifier(result.source,
                              "gl_BackColor", "appgl_BackColor");
    }
    if (legacy.usesFrontSecondaryColor) {
        (void)eraseGlobalStorageDeclaration(result.source,
                                            "gl_FrontSecondaryColor");
        replaceCodeIdentifier(result.source,
                              "gl_FrontSecondaryColor",
                              "appgl_FrontSecondaryColor");
    }
    if (legacy.usesBackSecondaryColor) {
        (void)eraseGlobalStorageDeclaration(result.source,
                                            "gl_BackSecondaryColor");
        replaceCodeIdentifier(result.source,
                              "gl_BackSecondaryColor",
                              "appgl_BackSecondaryColor");
    }
    if (legacy.usesFragmentColor) {
        (void)eraseGlobalStorageDeclaration(result.source, "gl_Color");
        replaceCodeIdentifier(result.source,
                              "gl_Color",
                              "appgl_LegacyColorValue()");
    }
    if (legacy.usesFragmentSecondaryColor) {
        (void)eraseGlobalStorageDeclaration(result.source,
                                            "gl_SecondaryColor");
        replaceCodeIdentifier(result.source,
                              "gl_SecondaryColor",
                              "appgl_LegacySecondaryColorValue()");
    }
    if (legacy.anyLight()) {
        rewriteLightSourceSubscripts(result.source);
    }
    if (legacy.usesLightModelAmbient) {
        replaceLiteral(result.source,
                       "gl_LightModel.ambient",
                       "appgl_LightModelAmbient");
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
    preamble.append(gpuShader4ShadowPreamble);

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
    if (legacy.synthesizesLegacyClipPlanes) {
        char buf[160];
        std::snprintf(buf, sizeof(buf),
                      "uniform vec4 %s[%u];\n",
                      SUN::kLegacyClipPlanes,
                      kSynthesizedLegacyClipPlaneCount);
        preamble.append(buf);
    }

    // 5b. fw¹⁹ — legacy attribute declarations (vertex stage only).
    // Location indices follow the NVIDIA-era conventional attribute
    // aliasing: 0 = Vertex/position, 2 = Normal, 3 = primary Color,
    // 4 = SecondaryColor, 8+N =
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
        if (legacy.attrSecondaryColor) {
            addLayoutAttrib(4, "vec4", "appgl_SecondaryColor");
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

    // 5b.1. GLSL compatibility builtin. Keep the original call spelling and
    // provide a function-like macro only for legacy vertex sources. This
    // preserves ordinary identifiers named `ftransform` in core shaders.
    if (legacy.usesFtransform) {
        preamble.append(
            "#define ftransform() "
            "(appgl_ModelViewProjectionMatrix * appgl_Vertex)\n");
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
        } else if (isArbGeometryStage) {
            std::snprintf(buf, sizeof(buf),
                          "out vec4 appgl_TexCoord[%u];\n"
                          "#define gl_TexCoord appgl_TexCoord\n",
                          count);
            preamble.append(buf);
        }
    }

    // 5d.1. gl_FogFragCoord is a legacy stage varying.
    if (legacy.usesFogFragCoord) {
        if (isVertex) {
            preamble.append("out float appgl_FogFragCoord;\n");
        } else if (isGeometry) {
            if (legacy.usesFogFragCoordInput) {
                preamble.append("in float appgl_FogFragCoordIn[];\n");
            }
            preamble.append("out float appgl_FogFragCoord;\n");
        } else if (isFragment) {
            preamble.append("in float appgl_FogFragCoord;\n");
        }
    }

    std::vector<std::pair<std::string, std::string>>
        legacyColorFanoutAssignments;
    auto appendColorOutput = [&](const std::string& qualifier,
                                 std::string_view name) {
        if (!qualifier.empty()) {
            preamble.append(qualifier).append(" ");
        }
        preamble.append("out vec4 ").append(name).append(";\n");
    };
    auto appendColorArray = [&](const char* storage,
                                const std::string& qualifier,
                                const std::string& name) {
        if (!qualifier.empty()) {
            preamble.append(qualifier).append(" ");
        }
        preamble.append(storage)
            .append(" vec4 ")
            .append(name)
            .append("[];\n");
    };
    auto appendLegacyColorTransport =
        [&](bool usesOutput,
            bool usesInput,
            const std::string& qualifier,
            const char* baseName) {
            if (usesInput && colorInputDestination != nullptr) {
                appendColorArray(
                    "in", qualifier,
                    legacyColorTransportName(baseName,
                                             colorInputDestination));
            }
            if (!usesOutput) {
                return;
            }
            if (isTessControl) {
                appendColorArray(
                    "out", qualifier,
                    legacyColorTransportName(baseName,
                                             "TessEvaluation"));
                return;
            }
            if (!(isVertex || isArbGeometryStage ||
                  isStandardGeometryStage || isTessEvaluation)) {
                return;
            }

            appendColorOutput(qualifier, baseName);
            auto addFanout = [&](const char* destination) {
                const std::string transport =
                    legacyColorTransportName(baseName, destination);
                appendColorOutput(qualifier, transport);
                legacyColorFanoutAssignments.emplace_back(
                    transport, baseName);
            };
            if (isVertex) {
                // The next active stage is only known at link time. Emit
                // every legal VS boundary; unused outputs are harmless.
                addFanout("Geometry");
                addFanout("TessControl");
                // Tessellation control is optional in a tessellation
                // program, so a VS can feed TES directly.
                addFanout("TessEvaluation");
            } else if (isTessEvaluation) {
                addFanout("Geometry");
            }
        };
    appendLegacyColorTransport(
        legacy.usesFrontColor, legacy.usesFrontColorInput,
        legacy.frontColorInterpolationQualifier, "appgl_FrontColor");
    appendLegacyColorTransport(
        legacy.usesBackColor, legacy.usesBackColorInput,
        legacy.backColorInterpolationQualifier, "appgl_BackColor");
    appendLegacyColorTransport(
        legacy.usesFrontSecondaryColor,
        legacy.usesFrontSecondaryColorInput,
        legacy.frontSecondaryColorInterpolationQualifier,
        "appgl_FrontSecondaryColor");
    appendLegacyColorTransport(
        legacy.usesBackSecondaryColor,
        legacy.usesBackSecondaryColorInput,
        legacy.backSecondaryColorInterpolationQualifier,
        "appgl_BackSecondaryColor");
    if (isFragment &&
        (legacy.usesFragmentColor || legacy.usesFragmentSecondaryColor)) {
        auto appendColorInput = [&](const std::string& qualifier,
                                    const char* name) {
            if (!qualifier.empty()) {
                preamble.append(qualifier).append(" ");
            }
            preamble.append("in vec4 ").append(name).append(";\n");
        };
        if (legacy.usesFragmentColor) {
            appendColorInput(legacy.fragmentColorInterpolationQualifier,
                             "appgl_FrontColor");
            appendColorInput(legacy.fragmentColorInterpolationQualifier,
                             "appgl_BackColor");
        }
        if (legacy.usesFragmentSecondaryColor) {
            appendColorInput(
                legacy.fragmentSecondaryColorInterpolationQualifier,
                "appgl_FrontSecondaryColor");
            appendColorInput(
                legacy.fragmentSecondaryColorInterpolationQualifier,
                "appgl_BackSecondaryColor");
        }
        preamble.append("uniform int ")
            .append(SUN::kVertexProgramTwoSide)
            .append(";\n");
        if (legacy.usesFragmentColor) {
            preamble.append(
                "vec4 appgl_LegacyColorValue() { return "
                "(appgl_VertexProgramTwoSide != 0 && !gl_FrontFacing) ? "
                "appgl_BackColor : appgl_FrontColor; }\n");
        }
        if (legacy.usesFragmentSecondaryColor) {
            preamble.append(
                "vec4 appgl_LegacySecondaryColorValue() { return "
                "(appgl_VertexProgramTwoSide != 0 && !gl_FrontFacing) ? "
                "appgl_BackSecondaryColor : appgl_FrontSecondaryColor; }\n");
        }
    }

    // 5e. fw¹⁹/R05-2 — fog uniforms. Declaration initializers preserve
    // the GL 1.x defaults until draw-time fixed-function state is pushed
    // through the synthesized-uniform path.
    if (legacy.usesFogColor) {
        preamble.append("uniform vec4 ")
            .append(SUN::kFogColor)
            .append(" = vec4(0.0, 0.0, 0.0, 0.0);\n");
    }
    if (legacy.usesFogDensity) {
        preamble.append("uniform float ")
            .append(SUN::kFogDensity)
            .append(" = 1.0;\n");
    }
    if (legacy.usesFogStart) {
        preamble.append("uniform float ")
            .append(SUN::kFogStart)
            .append(" = 0.0;\n");
    }
    if (legacy.usesFogEnd) {
        preamble.append("uniform float ")
            .append(SUN::kFogEnd)
            .append(" = 1.0;\n");
    }
    if (legacy.usesFogScale) {
        preamble.append("uniform float ")
            .append(SUN::kFogScale)
            .append(" = 1.0;\n");
    }

    if (legacy.usesTextureEnvColor) {
        char buf[176];
        std::snprintf(buf, sizeof(buf),
                      "uniform vec4 %s[%u];\n#define gl_TextureEnvColor %s\n",
                      SUN::kTextureEnvColor,
                      kSynthesizedTextureEnvColorCount,
                      SUN::kTextureEnvColor);
        preamble.append(buf);
    }
    if (legacy.usesLightModelAmbient) {
        preamble.append("uniform vec4 appgl_LightModelAmbient;\n");
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
        } else if (isArbGeometryStage) {
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
    // whitespace before `#version`) and after the contiguous initial
    // `#extension` block (GLSL requires extension directives to precede
    // declarations). After the preamble we emit `#line N` so glslang's
    // error reporting maps the next user line to its original line number
    // despite the inserted preamble lines.
    if (versionEol != std::string::npos) {
        std::size_t insertAt = versionEol;
        if (insertAt < result.source.size() &&
            result.source[insertAt] == '\n') {
            insertAt += 1;
        }
        while (insertAt < result.source.size()) {
            const std::size_t lineEnd =
                result.source.find('\n', insertAt);
            const std::size_t boundedLineEnd =
                lineEnd == std::string::npos
                    ? result.source.size()
                    : lineEnd;
            const std::string_view line = trimAscii(
                std::string_view(result.source).substr(
                    insertAt, boundedLineEnd - insertAt));
            std::string_view extension;
            std::string_view behavior;
            const bool isExtension =
                parseExtensionDirective(line, extension, behavior);
            // GL_ARB_compatibility directives are replaced with a
            // same-width line comment before this pass. Continue past
            // that comment, and past any later extension directives, so
            // synthesized declarations never split the directive block.
            if (!line.empty() && line.substr(0, 2) != "//" &&
                !isExtension) {
                break;
            }
            if (lineEnd == std::string::npos) {
                insertAt = result.source.size();
                break;
            }
            insertAt = lineEnd + 1;
        }
        unsigned int originalLine = 1;
        for (std::size_t i = 0; i < insertAt; ++i) {
            if (result.source[i] == '\n') {
                ++originalLine;
            }
        }
        std::string injected;
        char lineDirective[32];
        std::snprintf(lineDirective, sizeof(lineDirective),
                      "#line %u\n", originalLine);
        injected.reserve(preamble.size() + std::strlen(lineDirective));
        injected.append(preamble);
        injected.append(lineDirective);
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

    if (!legacyColorFanoutAssignments.empty() &&
        replaceCodeFunctionIdentifier(
            result.source, "main", "appgl_LegacyColorMain")) {
        result.source.append("\nvoid main() {\n");
        result.source.append("    appgl_LegacyColorMain();\n");
        for (const auto& assignment : legacyColorFanoutAssignments) {
            result.source.append("    ")
                .append(assignment.first)
                .append(" = ")
                .append(assignment.second)
                .append(";\n");
        }
        result.source.append("}\n");
    }

    if (legacy.synthesizesLegacyClipPlanes &&
        replaceCodeFunctionIdentifier(
            result.source, "main", "appgl_LegacyClipMain")) {
        result.source.append("\nvoid main() {\n");
        result.source.append("    appgl_LegacyClipMain();\n");
        for (unsigned int i = 0;
             i < kSynthesizedLegacyClipPlaneCount;
             ++i) {
            result.source.append("    gl_ClipDistance[")
                .append(std::to_string(i))
                .append("] = dot(gl_Position, ")
                .append(SUN::kLegacyClipPlanes)
                .append("[")
                .append(std::to_string(i))
                .append("]);\n");
        }
        result.source.append("}\n");
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
