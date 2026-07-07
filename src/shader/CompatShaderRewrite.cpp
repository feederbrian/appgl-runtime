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

bool replaceCodeFunctionIdentifier(std::string& src,
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
        if (src.compare(pos, from.size(), from) != 0) {
            ++pos;
            continue;
        }
        const bool leftOk = (pos == 0) || !isIdentChar(src[pos - 1]);
        const std::size_t end = pos + from.size();
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
            src.replace(pos, from.size(), to);
            didReplace = true;
            pos += to.size();
        } else {
            ++pos;
        }
    }
    return didReplace;
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
};

static const GpuShader4ShadowWrapper kGpuShader4ShadowWrappers[] = {
    {
        "shadow1D",
        "appgl_gpu_shader4_shadow1D",
        "vec4 appgl_gpu_shader4_shadow1D(sampler1DShadow s, vec3 p) {\n"
        "    return vec4(textureLod(s, p, 0.0));\n"
        "}\n",
        "vec4 appgl_gpu_shader4_shadow1D(sampler1DShadow s, vec3 p, float bias) {\n"
        "    return vec4(texture(s, p, bias));\n"
        "}\n",
    },
    {
        "shadow2D",
        "appgl_gpu_shader4_shadow2D",
        "vec4 appgl_gpu_shader4_shadow2D(sampler2DShadow s, vec3 p) {\n"
        "    return vec4(textureLod(s, p, 0.0));\n"
        "}\n",
        "vec4 appgl_gpu_shader4_shadow2D(sampler2DShadow s, vec3 p, float bias) {\n"
        "    return vec4(texture(s, p, bias));\n"
        "}\n",
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
    },
    {
        "shadow2DRectProj",
        "appgl_gpu_shader4_shadow2DRectProj",
        "vec4 appgl_gpu_shader4_shadow2DRectProj(sampler2DRectShadow s, vec4 p) {\n"
        "    return vec4(textureProj(s, p));\n"
        "}\n",
        nullptr,
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

}  // namespace

CompatShaderRewriteResult rewriteCompatShader(std::string_view source,
                                              GLenum stage) {
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
    const bool hasGpuShader4Directive =
        result.source.find("GL_EXT_gpu_shader4") != std::string::npos;

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
        legacy.fragColor = containsCodeIdentifier(result.source, "gl_FragColor");
        legacy.fragDataMax = scanFragDataMax(source);
        legacy.usesFragmentColor = containsIdentifier(source, "gl_Color");
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
    if (isVertex) {
        legacy.usesFrontColor = containsIdentifier(source, "gl_FrontColor");
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
        const bool needsFloorUpgrade =
            versionNumber > 0 &&
            ((versionNumber < 140 && !isCompat) ||
             (hasGpuShader4Directive && versionNumber < 150) ||
             (needsExplicitLocationPreamble && versionNumber < 330));
        if (needsFloorUpgrade) {
            legacy.upgradedVersion = true;
            // Replace the entire version line with `#version 330 core`
            // regardless of the original profile token.
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
    if (hasGpuShader4Directive &&
        result.source.find("shadow") != std::string::npos) {
        for (const auto& wrapper : kGpuShader4ShadowWrappers) {
            if (!containsIdentifier(result.source, wrapper.legacyName)) {
                continue;
            }
            if (replaceCodeFunctionIdentifier(result.source,
                                              wrapper.legacyName,
                                              wrapper.helperName)) {
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

    if (!didAnyRewrite && !didSamplerFixup && !didGpuShader4TruncateFixup &&
        !didGpuShader4LexicalFixup && !didGpuShader4ShadowFixup &&
        !didGpuShader4TextureAliasFixup) {
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
    if (legacy.usesFogFragCoordInput) {
        rewriteFogFragCoordInputAccess(result.source);
    }
    if (legacy.usesFogFragCoord) {
        replaceIdentifier(result.source,
                          "gl_FogFragCoord",
                          "appgl_FogFragCoord");
    }
    if (legacy.usesFrontColor) {
        replaceIdentifier(result.source, "gl_FrontColor", "appgl_FrontColor");
    }
    if (legacy.usesFragmentColor) {
        replaceIdentifier(result.source, "gl_Color", "appgl_FrontColor");
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

    if (legacy.usesFrontColor && isVertex) {
        preamble.append("out vec4 appgl_FrontColor;\n");
    }
    if (legacy.usesFragmentColor && isFragment) {
        preamble.append("in vec4 appgl_FrontColor;\n");
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
            std::size_t lineStart = insertAt;
            while (lineStart < result.source.size() &&
                   (result.source[lineStart] == ' ' ||
                    result.source[lineStart] == '\t')) {
                ++lineStart;
            }
            if (result.source.compare(lineStart, 10, "#extension") != 0) {
                break;
            }
            std::size_t lineEnd = result.source.find('\n', lineStart);
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
