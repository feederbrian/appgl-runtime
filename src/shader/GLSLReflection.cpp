#include "GLSLReflection.h"

#include <cctype>
#include <cstdlib>
#include <string>
#include <unordered_map>

namespace appgl {

namespace {

struct TypeEntry {
    GLenum type;
    GLint components;
    const char* keyword;
};

const std::unordered_map<std::string, TypeEntry>& typeTable() {
    static const std::unordered_map<std::string, TypeEntry> table = {
        {"float", {GL_FLOAT, 1, "float"}},
        {"vec2", {GL_FLOAT_VEC2, 2, "vec2"}},
        {"vec3", {GL_FLOAT_VEC3, 3, "vec3"}},
        {"vec4", {GL_FLOAT_VEC4, 4, "vec4"}},
        {"int", {GL_INT, 1, "int"}},
        {"ivec2", {GL_INT_VEC2, 2, "ivec2"}},
        {"ivec3", {GL_INT_VEC3, 3, "ivec3"}},
        {"ivec4", {GL_INT_VEC4, 4, "ivec4"}},
        {"uint", {GL_UNSIGNED_INT, 1, "uint"}},
        {"uvec2", {GL_UNSIGNED_INT_VEC2, 2, "uvec2"}},
        {"uvec3", {GL_UNSIGNED_INT_VEC3, 3, "uvec3"}},
        {"uvec4", {GL_UNSIGNED_INT_VEC4, 4, "uvec4"}},
        {"bool", {GL_BOOL, 1, "bool"}},
        {"bvec2", {GL_BOOL_VEC2, 2, "bvec2"}},
        {"bvec3", {GL_BOOL_VEC3, 3, "bvec3"}},
        {"bvec4", {GL_BOOL_VEC4, 4, "bvec4"}},
        {"mat2", {GL_FLOAT_MAT2, 4, "mat2"}},
        {"mat3", {GL_FLOAT_MAT3, 9, "mat3"}},
        {"mat4", {GL_FLOAT_MAT4, 16, "mat4"}},
        {"sampler1D", {GL_SAMPLER_1D, 1, "sampler1D"}},
        {"sampler2D", {GL_SAMPLER_2D, 1, "sampler2D"}},
        {"sampler3D", {GL_SAMPLER_3D, 1, "sampler3D"}},
        {"samplerCube", {GL_SAMPLER_CUBE, 1, "samplerCube"}},
        {"sampler2DArray", {GL_SAMPLER_2D_ARRAY, 1, "sampler2DArray"}},
        {"sampler2DShadow", {GL_SAMPLER_2D_SHADOW, 1, "sampler2DShadow"}},
    };
    return table;
}

const TypeEntry* lookupType(const std::string& keyword) {
    auto it = typeTable().find(keyword);
    if (it == typeTable().end()) {
        return nullptr;
    }
    return &it->second;
}

// Strip line and block comments. Returns a copy with comments replaced by spaces
// to preserve token boundaries.
std::string stripComments(std::string_view source) {
    std::string out;
    out.reserve(source.size());
    std::size_t i = 0;
    while (i < source.size()) {
        if (i + 1 < source.size() && source[i] == '/' && source[i + 1] == '/') {
            i += 2;
            while (i < source.size() && source[i] != '\n') {
                ++i;
            }
        } else if (i + 1 < source.size() && source[i] == '/' && source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.size() && !(source[i] == '*' && source[i + 1] == '/')) {
                ++i;
            }
            i = std::min(source.size(), i + 2);
        } else {
            out.push_back(source[i++]);
        }
    }
    return out;
}

// Tokenize a single statement (already split on `;`). Returns whitespace-separated
// tokens, treating `(`, `)`, `[`, `]`, `,`, `=` as their own tokens.
std::vector<std::string> tokenize(std::string_view stmt) {
    std::vector<std::string> tokens;
    std::string current;
    auto flush = [&]() {
        if (!current.empty()) {
            tokens.push_back(std::move(current));
            current.clear();
        }
    };
    for (char c : stmt) {
        if (std::isspace(static_cast<unsigned char>(c))) {
            flush();
        } else if (c == '(' || c == ')' || c == '[' || c == ']' || c == ',' || c == '=') {
            flush();
            tokens.emplace_back(1, c);
        } else {
            current.push_back(c);
        }
    }
    flush();
    return tokens;
}

// Parse `layout(location = N)` and similar. Returns the explicit location if
// found, otherwise -1. The tokens vector is mutated to drop the layout block.
GLint extractLayoutLocation(std::vector<std::string>& tokens) {
    if (tokens.empty() || tokens.front() != "layout") {
        return -1;
    }
    if (tokens.size() < 3 || tokens[1] != "(") {
        return -1;
    }
    GLint location = -1;
    std::size_t i = 2;
    std::size_t depth = 1;
    while (i < tokens.size() && depth > 0) {
        if (tokens[i] == "(") {
            ++depth;
        } else if (tokens[i] == ")") {
            --depth;
            if (depth == 0) {
                ++i;
                break;
            }
        } else if (tokens[i] == "location" && i + 2 < tokens.size() && tokens[i + 1] == "=") {
            location = static_cast<GLint>(std::strtol(tokens[i + 2].c_str(), nullptr, 10));
        }
        ++i;
    }
    tokens.erase(tokens.begin(), tokens.begin() + static_cast<std::ptrdiff_t>(i));
    return location;
}

// After layout/qualifiers stripped, the remaining tokens are
// [qualifier] [precision] <type> <name> [[ <size> ]]
bool parseDeclTail(std::vector<std::string>& tokens, GLShaderDeclaration& out) {
    // Drop common precision qualifiers if present.
    while (!tokens.empty() && (tokens.front() == "highp" || tokens.front() == "mediump" || tokens.front() == "lowp")) {
        tokens.erase(tokens.begin());
    }
    if (tokens.size() < 2) {
        return false;
    }
    const TypeEntry* entry = lookupType(tokens[0]);
    if (entry == nullptr) {
        return false;
    }
    out.type = entry->type;
    out.name = tokens[1];
    out.arraySize = 1;
    // Strip trailing `[N]` baked into the name token (rare) or the next tokens.
    auto bracket = out.name.find('[');
    if (bracket != std::string::npos) {
        const auto end = out.name.find(']', bracket);
        if (end != std::string::npos) {
            const std::string sizeText = out.name.substr(bracket + 1, end - bracket - 1);
            if (!sizeText.empty()) {
                out.arraySize = static_cast<GLint>(std::strtol(sizeText.c_str(), nullptr, 10));
            }
        }
        out.name.erase(bracket);
    } else if (tokens.size() >= 5 && tokens[2] == "[") {
        out.arraySize = static_cast<GLint>(std::strtol(tokens[3].c_str(), nullptr, 10));
    }
    return !out.name.empty();
}

}  // namespace

GLSLReflectionResult reflectGLSL(std::string_view source, GLenum stage) {
    GLSLReflectionResult result;
    std::string cleaned = stripComments(source);
    // Drop preprocessor lines we don't act on.
    {
        std::string filtered;
        filtered.reserve(cleaned.size());
        std::size_t i = 0;
        while (i < cleaned.size()) {
            if (cleaned[i] == '#') {
                while (i < cleaned.size() && cleaned[i] != '\n') {
                    ++i;
                }
            } else {
                filtered.push_back(cleaned[i++]);
            }
        }
        cleaned = std::move(filtered);
    }

    std::size_t braceDepth = 0;
    std::size_t parenDepth = 0;
    std::string statement;
    auto processStatement = [&](std::string raw) {
        std::vector<std::string> tokens = tokenize(raw);
        if (tokens.empty()) {
            return;
        }
        GLint explicitLocation = extractLayoutLocation(tokens);
        if (tokens.empty()) {
            return;
        }
        // Drop additional qualifiers like `flat`, `smooth`, `centroid`, `noperspective`,
        // `invariant`, `precise`.
        while (!tokens.empty() && (tokens.front() == "flat" || tokens.front() == "smooth" ||
                                   tokens.front() == "centroid" || tokens.front() == "noperspective" ||
                                   tokens.front() == "invariant" || tokens.front() == "precise")) {
            tokens.erase(tokens.begin());
        }
        if (tokens.empty()) {
            return;
        }
        const std::string keyword = tokens.front();
        if (keyword != "uniform" && keyword != "in" && keyword != "out" &&
            keyword != "attribute" && keyword != "varying") {
            return;
        }
        tokens.erase(tokens.begin());
        GLShaderDeclaration decl;
        if (!parseDeclTail(tokens, decl)) {
            return;
        }
        decl.explicitLocation = explicitLocation;
        if (keyword == "uniform") {
            result.uniforms.push_back(std::move(decl));
        } else if (keyword == "in" || keyword == "attribute") {
            // Only treat as a vertex input when at the vertex stage; for fragment
            // stage `in` declarations are stage-interface varyings.
            if (stage == GL_VERTEX_SHADER) {
                result.inputs.push_back(std::move(decl));
            }
        } else if (keyword == "out" || keyword == "varying") {
            if (stage == GL_FRAGMENT_SHADER || stage == GL_VERTEX_SHADER) {
                result.outputs.push_back(std::move(decl));
            }
        }
    };

    for (char c : cleaned) {
        if (c == '{') {
            ++braceDepth;
            statement.clear();
            continue;
        }
        if (c == '}') {
            if (braceDepth > 0) {
                --braceDepth;
            }
            statement.clear();
            continue;
        }
        if (braceDepth > 0) {
            continue;
        }
        if (c == '(') {
            ++parenDepth;
        } else if (c == ')') {
            if (parenDepth > 0) {
                --parenDepth;
            }
        }
        if (c == ';' && parenDepth == 0) {
            processStatement(statement);
            statement.clear();
            continue;
        }
        statement.push_back(c);
    }

    return result;
}

GLint glslComponentCount(GLenum type) {
    for (const auto& [_, entry] : typeTable()) {
        if (entry.type == type) {
            return entry.components;
        }
    }
    return 1;
}

const char* glslTypeKeyword(GLenum type) {
    for (const auto& [_, entry] : typeTable()) {
        if (entry.type == type) {
            return entry.keyword;
        }
    }
    return "float";
}

}  // namespace appgl
