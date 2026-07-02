#include "GLSLReflection.h"

#include <algorithm>
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
        // Non-square matrix types (GL 3.0+). Without entries here
        // the scanner dropped `mat2x3 d[2]` declarations and CTS
        // `program_interface_query.input-types` saw 7 active
        // inputs instead of the expected 8.
        {"mat2x2", {GL_FLOAT_MAT2, 4, "mat2x2"}},
        {"mat3x3", {GL_FLOAT_MAT3, 9, "mat3x3"}},
        {"mat4x4", {GL_FLOAT_MAT4, 16, "mat4x4"}},
        {"mat2x3", {GL_FLOAT_MAT2x3, 6, "mat2x3"}},
        {"mat2x4", {GL_FLOAT_MAT2x4, 8, "mat2x4"}},
        {"mat3x2", {GL_FLOAT_MAT3x2, 6, "mat3x2"}},
        {"mat3x4", {GL_FLOAT_MAT3x4, 12, "mat3x4"}},
        {"mat4x2", {GL_FLOAT_MAT4x2, 8, "mat4x2"}},
        {"mat4x3", {GL_FLOAT_MAT4x3, 12, "mat4x3"}},
        // Double-precision matrices (GL 4.0+).
        {"dmat2", {GL_DOUBLE_MAT2, 4, "dmat2"}},
        {"dmat3", {GL_DOUBLE_MAT3, 9, "dmat3"}},
        {"dmat4", {GL_DOUBLE_MAT4, 16, "dmat4"}},
        {"dmat2x3", {GL_DOUBLE_MAT2x3, 6, "dmat2x3"}},
        {"dmat2x4", {GL_DOUBLE_MAT2x4, 8, "dmat2x4"}},
        {"dmat3x2", {GL_DOUBLE_MAT3x2, 6, "dmat3x2"}},
        {"dmat3x4", {GL_DOUBLE_MAT3x4, 12, "dmat3x4"}},
        {"dmat4x2", {GL_DOUBLE_MAT4x2, 8, "dmat4x2"}},
        {"dmat4x3", {GL_DOUBLE_MAT4x3, 12, "dmat4x3"}},
        // Double-precision scalars/vectors (GL 4.0+).
        {"double", {GL_DOUBLE, 1, "double"}},
        {"dvec2", {GL_DOUBLE_VEC2, 2, "dvec2"}},
        {"dvec3", {GL_DOUBLE_VEC3, 3, "dvec3"}},
        {"dvec4", {GL_DOUBLE_VEC4, 4, "dvec4"}},
        // Float sampler types.
        {"sampler1D", {GL_SAMPLER_1D, 1, "sampler1D"}},
        {"sampler2D", {GL_SAMPLER_2D, 1, "sampler2D"}},
        {"sampler3D", {GL_SAMPLER_3D, 1, "sampler3D"}},
        {"samplerCube", {GL_SAMPLER_CUBE, 1, "samplerCube"}},
        {"sampler1DArray", {GL_SAMPLER_1D_ARRAY, 1, "sampler1DArray"}},
        {"sampler2DArray", {GL_SAMPLER_2D_ARRAY, 1, "sampler2DArray"}},
        {"sampler1DShadow", {GL_SAMPLER_1D_SHADOW, 1, "sampler1DShadow"}},
        {"sampler2DShadow", {GL_SAMPLER_2D_SHADOW, 1, "sampler2DShadow"}},
        {"sampler1DArrayShadow", {GL_SAMPLER_1D_ARRAY_SHADOW, 1, "sampler1DArrayShadow"}},
        {"sampler2DArrayShadow", {GL_SAMPLER_2D_ARRAY_SHADOW, 1, "sampler2DArrayShadow"}},
        {"samplerCubeShadow", {GL_SAMPLER_CUBE_SHADOW, 1, "samplerCubeShadow"}},
        {"sampler2DRect", {GL_SAMPLER_2D_RECT, 1, "sampler2DRect"}},
        {"sampler2DRectShadow", {GL_SAMPLER_2D_RECT_SHADOW, 1, "sampler2DRectShadow"}},
        {"samplerBuffer", {GL_SAMPLER_BUFFER, 1, "samplerBuffer"}},
        {"sampler2DMS", {GL_SAMPLER_2D_MULTISAMPLE, 1, "sampler2DMS"}},
        {"sampler2DMSArray", {GL_SAMPLER_2D_MULTISAMPLE_ARRAY, 1, "sampler2DMSArray"}},
        {"samplerCubeArray", {GL_SAMPLER_CUBE_MAP_ARRAY, 1, "samplerCubeArray"}},
        {"samplerCubeArrayShadow", {GL_SAMPLER_CUBE_MAP_ARRAY_SHADOW, 1, "samplerCubeArrayShadow"}},
        // Integer sampler types.
        {"isampler1D", {GL_INT_SAMPLER_1D, 1, "isampler1D"}},
        {"isampler2D", {GL_INT_SAMPLER_2D, 1, "isampler2D"}},
        {"isampler3D", {GL_INT_SAMPLER_3D, 1, "isampler3D"}},
        {"isamplerCube", {GL_INT_SAMPLER_CUBE, 1, "isamplerCube"}},
        {"isampler1DArray", {GL_INT_SAMPLER_1D_ARRAY, 1, "isampler1DArray"}},
        {"isampler2DArray", {GL_INT_SAMPLER_2D_ARRAY, 1, "isampler2DArray"}},
        {"isampler2DRect", {GL_INT_SAMPLER_2D_RECT, 1, "isampler2DRect"}},
        {"isamplerBuffer", {GL_INT_SAMPLER_BUFFER, 1, "isamplerBuffer"}},
        {"isampler2DMS", {GL_INT_SAMPLER_2D_MULTISAMPLE, 1, "isampler2DMS"}},
        {"isampler2DMSArray", {GL_INT_SAMPLER_2D_MULTISAMPLE_ARRAY, 1, "isampler2DMSArray"}},
        {"isamplerCubeArray", {GL_INT_SAMPLER_CUBE_MAP_ARRAY, 1, "isamplerCubeArray"}},
        // Unsigned integer sampler types.
        {"usampler1D", {GL_UNSIGNED_INT_SAMPLER_1D, 1, "usampler1D"}},
        {"usampler2D", {GL_UNSIGNED_INT_SAMPLER_2D, 1, "usampler2D"}},
        {"usampler3D", {GL_UNSIGNED_INT_SAMPLER_3D, 1, "usampler3D"}},
        {"usamplerCube", {GL_UNSIGNED_INT_SAMPLER_CUBE, 1, "usamplerCube"}},
        {"usampler1DArray", {GL_UNSIGNED_INT_SAMPLER_1D_ARRAY, 1, "usampler1DArray"}},
        {"usampler2DArray", {GL_UNSIGNED_INT_SAMPLER_2D_ARRAY, 1, "usampler2DArray"}},
        {"usampler2DRect", {GL_UNSIGNED_INT_SAMPLER_2D_RECT, 1, "usampler2DRect"}},
        {"usamplerBuffer", {GL_UNSIGNED_INT_SAMPLER_BUFFER, 1, "usamplerBuffer"}},
        {"usampler2DMS", {GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE, 1, "usampler2DMS"}},
        {"usampler2DMSArray", {GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY, 1, "usampler2DMSArray"}},
        {"usamplerCubeArray", {GL_UNSIGNED_INT_SAMPLER_CUBE_MAP_ARRAY, 1, "usamplerCubeArray"}},
        // Float image types (GL 4.2+ storage images for imageLoad/imageStore).
        // CTS KHR-GL46.shading_language_420pack expects `glGetUniformLocation`
        // to find these uniforms — without entries here the scanner treats
        // `uniform image2D uni_image` as an unknown token and drops it from
        // the program's uniforms table, so getUniformLocation returns -1.
        {"image1D",               {GL_IMAGE_1D, 1, "image1D"}},
        {"image2D",               {GL_IMAGE_2D, 1, "image2D"}},
        {"image3D",               {GL_IMAGE_3D, 1, "image3D"}},
        {"imageCube",             {GL_IMAGE_CUBE, 1, "imageCube"}},
        {"image2DRect",           {GL_IMAGE_2D_RECT, 1, "image2DRect"}},
        {"image1DArray",          {GL_IMAGE_1D_ARRAY, 1, "image1DArray"}},
        {"image2DArray",          {GL_IMAGE_2D_ARRAY, 1, "image2DArray"}},
        {"imageBuffer",           {GL_IMAGE_BUFFER, 1, "imageBuffer"}},
        {"imageCubeArray",        {GL_IMAGE_CUBE_MAP_ARRAY, 1, "imageCubeArray"}},
        {"image2DMS",             {GL_IMAGE_2D_MULTISAMPLE, 1, "image2DMS"}},
        {"image2DMSArray",        {GL_IMAGE_2D_MULTISAMPLE_ARRAY, 1, "image2DMSArray"}},
        // Integer image types.
        {"iimage1D",              {GL_INT_IMAGE_1D, 1, "iimage1D"}},
        {"iimage2D",              {GL_INT_IMAGE_2D, 1, "iimage2D"}},
        {"iimage3D",              {GL_INT_IMAGE_3D, 1, "iimage3D"}},
        {"iimageCube",            {GL_INT_IMAGE_CUBE, 1, "iimageCube"}},
        {"iimage2DRect",          {GL_INT_IMAGE_2D_RECT, 1, "iimage2DRect"}},
        {"iimage1DArray",         {GL_INT_IMAGE_1D_ARRAY, 1, "iimage1DArray"}},
        {"iimage2DArray",         {GL_INT_IMAGE_2D_ARRAY, 1, "iimage2DArray"}},
        {"iimageBuffer",          {GL_INT_IMAGE_BUFFER, 1, "iimageBuffer"}},
        {"iimageCubeArray",       {GL_INT_IMAGE_CUBE_MAP_ARRAY, 1, "iimageCubeArray"}},
        {"iimage2DMS",            {GL_INT_IMAGE_2D_MULTISAMPLE, 1, "iimage2DMS"}},
        {"iimage2DMSArray",       {GL_INT_IMAGE_2D_MULTISAMPLE_ARRAY, 1, "iimage2DMSArray"}},
        // Unsigned integer image types.
        {"uimage1D",              {GL_UNSIGNED_INT_IMAGE_1D, 1, "uimage1D"}},
        {"uimage2D",              {GL_UNSIGNED_INT_IMAGE_2D, 1, "uimage2D"}},
        {"uimage3D",              {GL_UNSIGNED_INT_IMAGE_3D, 1, "uimage3D"}},
        {"uimageCube",            {GL_UNSIGNED_INT_IMAGE_CUBE, 1, "uimageCube"}},
        {"uimage2DRect",          {GL_UNSIGNED_INT_IMAGE_2D_RECT, 1, "uimage2DRect"}},
        {"uimage1DArray",         {GL_UNSIGNED_INT_IMAGE_1D_ARRAY, 1, "uimage1DArray"}},
        {"uimage2DArray",         {GL_UNSIGNED_INT_IMAGE_2D_ARRAY, 1, "uimage2DArray"}},
        {"uimageBuffer",          {GL_UNSIGNED_INT_IMAGE_BUFFER, 1, "uimageBuffer"}},
        {"uimageCubeArray",       {GL_UNSIGNED_INT_IMAGE_CUBE_MAP_ARRAY, 1, "uimageCubeArray"}},
        {"uimage2DMS",            {GL_UNSIGNED_INT_IMAGE_2D_MULTISAMPLE, 1, "uimage2DMS"}},
        {"uimage2DMSArray",       {GL_UNSIGNED_INT_IMAGE_2D_MULTISAMPLE_ARRAY, 1, "uimage2DMSArray"}},
        // Atomic counter type.
        {"atomic_uint",           {GL_UNSIGNED_INT_ATOMIC_COUNTER, 1, "atomic_uint"}},
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

// GLSL line continuations are processed before comments. The reflection scanner
// must mirror that order or a source fragment like `// text \` + newline leaves
// the post-newline comment text as apparent code and can hide the next
// declaration from the statement parser.
std::string spliceLineContinuations(std::string_view source) {
    std::string out;
    out.reserve(source.size());
    for (std::size_t i = 0; i < source.size();) {
        if (source[i] == '\\' && i + 1 < source.size()) {
            if (source[i + 1] == '\n') {
                i += 2;
                continue;
            }
            if (source[i + 1] == '\r') {
                i += (i + 2 < source.size() && source[i + 2] == '\n') ? 3 : 2;
                continue;
            }
        }
        out.push_back(source[i++]);
    }
    return out;
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
// tokens, treating `(`, `)`, `[`, `]`, `{`, `}`, `,`, `=` as their own tokens.
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
        } else if (c == '(' || c == ')' || c == '[' || c == ']' ||
                   c == '{' || c == '}' || c == ',' || c == '=') {
            flush();
            tokens.emplace_back(1, c);
        } else {
            current.push_back(c);
        }
    }
    flush();
    return tokens;
}

// RC-D06 / RC-D08: extracted layout qualifiers from a `layout(...)` block.
struct LayoutQualifiers {
    GLint location = -1;  // layout(location = N), -1 = unspecified
    GLint binding  = -1;  // layout(binding  = N), -1 = unspecified
    // Dual-source-blend color-index from `layout(index = N)`.
    // Valid on fragment outputs per GL 4.6 §15.2; 0 = primary
    // color (default), 1 = second color for dual-source blending.
    // -1 = unspecified.
    GLint index    = -1;
    // Byte offset inside the atomic-counter buffer from
    // `layout(offset = N)` on an `atomic_uint` uniform. Required
    // for GL_ATOMIC_COUNTER_BUFFER introspection
    // (BUFFER_DATA_SIZE, ACTIVE_VARIABLES). -1 = unspecified
    // (GLSL treats that as "append after previous counter in the
    // same binding"; we default to 0 when first-seen in a binding).
    GLint offset   = -1;
    // Image format qualifier — `layout(rgba32f)` etc. on an image
    // load/store uniform. Stored as internal-format GLenum. 0 =
    // unspecified. Cross-stage link consistency compares this.
    GLenum imageFormat = 0;
};

// Map a GLSL image format keyword (`rgba32f`, `rgba16f`, `rgba8`,
// `rg32ui`, ...) to its internal-format GLenum. Covers GL 4.2
// Table 3.16 — the canonical 42-entry set that `layout(FORMAT)` on
// image load/store uniforms can name. Returns 0 for unrecognised
// tokens so the layout-qualifier parser can leave the field
// unspecified without false-positive matches.
GLenum imageFormatEnumForKeyword(const std::string& kw) {
    static const std::unordered_map<std::string, GLenum> table = {
        // Float (GL 4.2 Table 3.16)
        {"rgba32f", GL_RGBA32F},
        {"rgba16f", GL_RGBA16F},
        {"rg32f",   GL_RG32F},
        {"rg16f",   GL_RG16F},
        {"r11f_g11f_b10f", GL_R11F_G11F_B10F},
        {"r32f",    GL_R32F},
        {"r16f",    GL_R16F},
        // Signed int
        {"rgba32i", GL_RGBA32I},
        {"rgba16i", GL_RGBA16I},
        {"rgba8i",  GL_RGBA8I},
        {"rg32i",   GL_RG32I},
        {"rg16i",   GL_RG16I},
        {"rg8i",    GL_RG8I},
        {"r32i",    GL_R32I},
        {"r16i",    GL_R16I},
        {"r8i",     GL_R8I},
        // Unsigned int
        {"rgba32ui", GL_RGBA32UI},
        {"rgba16ui", GL_RGBA16UI},
        {"rgba8ui",  GL_RGBA8UI},
        {"rgb10_a2ui", GL_RGB10_A2UI},
        {"rg32ui",   GL_RG32UI},
        {"rg16ui",   GL_RG16UI},
        {"rg8ui",    GL_RG8UI},
        {"r32ui",    GL_R32UI},
        {"r16ui",    GL_R16UI},
        {"r8ui",     GL_R8UI},
        // Unorm
        {"rgba16",   GL_RGBA16},
        {"rgb10_a2", GL_RGB10_A2},
        {"rgba8",    GL_RGBA8},
        {"rg16",     GL_RG16},
        {"rg8",      GL_RG8},
        {"r16",      GL_R16},
        {"r8",       GL_R8},
        // Snorm
        {"rgba16_snorm", GL_RGBA16_SNORM},
        {"rgba8_snorm",  GL_RGBA8_SNORM},
        {"rg16_snorm",   GL_RG16_SNORM},
        {"rg8_snorm",    GL_RG8_SNORM},
        {"r16_snorm",    GL_R16_SNORM},
        {"r8_snorm",     GL_R8_SNORM},
    };
    auto it = table.find(kw);
    return (it != table.end()) ? it->second : 0;
}

// Parse `layout(location = N, binding = M)` and similar.  Returns the
// explicit location and binding if found, otherwise -1 for each.  The
// tokens vector is mutated to drop the layout block.
LayoutQualifiers extractLayoutQualifiers(std::vector<std::string>& tokens) {
    LayoutQualifiers result;
    if (tokens.empty() || tokens.front() != "layout") {
        return result;
    }
    if (tokens.size() < 3 || tokens[1] != "(") {
        return result;
    }
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
        } else if (i + 2 < tokens.size() && tokens[i + 1] == "=") {
            // GL 4.6 §4.10 permits the integer literal in a layout
            // qualifier to use any of the standard integer notations:
            // decimal (42), octal (052), or hexadecimal (0x2a). Base 0
            // lets strtol auto-detect from the prefix. Hard-coding base
            // 10 was failing KHR-GL46.explicit_uniform_location.uniform-loc-nondecimal
            // which declares `layout(location = 0xa)` and `layout(location = 010)`.
            if (tokens[i] == "location") {
                result.location = static_cast<GLint>(std::strtol(tokens[i + 2].c_str(), nullptr, 0));
            } else if (tokens[i] == "binding") {
                result.binding = static_cast<GLint>(std::strtol(tokens[i + 2].c_str(), nullptr, 0));
            } else if (tokens[i] == "index") {
                result.index = static_cast<GLint>(std::strtol(tokens[i + 2].c_str(), nullptr, 0));
            } else if (tokens[i] == "offset") {
                result.offset = static_cast<GLint>(std::strtol(tokens[i + 2].c_str(), nullptr, 0));
            }
        } else {
            // Bare token (no `= value`) — check for image format
            // qualifier like `rgba32f`, `r11f_g11f_b10f`, etc. These
            // are the only layout qualifiers that don't use the
            // `name = value` pattern inside `layout(...)`. Other
            // bare tokens (std140, row_major, triangles, ...) are
            // ignored here.
            GLenum fmt = imageFormatEnumForKeyword(tokens[i]);
            if (fmt != 0) {
                result.imageFormat = fmt;
            }
        }
        ++i;
    }
    tokens.erase(tokens.begin(), tokens.begin() + static_cast<std::ptrdiff_t>(i));
    return result;
}

// Phase 8X Group 4d follow-up¹⁵ — scalar kind routing for default-value
// initializer parsing. Samplers route through the integer path because a
// `uniform sampler2D tex = 0;` style initializer (if we ever saw one) would
// be interpreted as a texture-unit index, matching how glUniform1i sets
// sampler uniforms in practice.
enum class UniformScalarKind { Float, Int, UInt };

bool matrixShape(GLenum type, GLint& cols, GLint& rows) {
    switch (type) {
        case GL_FLOAT_MAT2:
        case GL_DOUBLE_MAT2:
            cols = 2;
            rows = 2;
            return true;
        case GL_FLOAT_MAT3:
        case GL_DOUBLE_MAT3:
            cols = 3;
            rows = 3;
            return true;
        case GL_FLOAT_MAT4:
        case GL_DOUBLE_MAT4:
            cols = 4;
            rows = 4;
            return true;
        case GL_FLOAT_MAT2x3:
        case GL_DOUBLE_MAT2x3:
            cols = 2;
            rows = 3;
            return true;
        case GL_FLOAT_MAT2x4:
        case GL_DOUBLE_MAT2x4:
            cols = 2;
            rows = 4;
            return true;
        case GL_FLOAT_MAT3x2:
        case GL_DOUBLE_MAT3x2:
            cols = 3;
            rows = 2;
            return true;
        case GL_FLOAT_MAT3x4:
        case GL_DOUBLE_MAT3x4:
            cols = 3;
            rows = 4;
            return true;
        case GL_FLOAT_MAT4x2:
        case GL_DOUBLE_MAT4x2:
            cols = 4;
            rows = 2;
            return true;
        case GL_FLOAT_MAT4x3:
        case GL_DOUBLE_MAT4x3:
            cols = 4;
            rows = 3;
            return true;
        default:
            return false;
    }
}

UniformScalarKind scalarKindForType(GLenum type) {
    switch (type) {
        case GL_FLOAT:
        case GL_FLOAT_VEC2:
        case GL_FLOAT_VEC3:
        case GL_FLOAT_VEC4:
        case GL_FLOAT_MAT2:
        case GL_FLOAT_MAT3:
        case GL_FLOAT_MAT4:
        case GL_FLOAT_MAT2x3:
        case GL_FLOAT_MAT2x4:
        case GL_FLOAT_MAT3x2:
        case GL_FLOAT_MAT3x4:
        case GL_FLOAT_MAT4x2:
        case GL_FLOAT_MAT4x3:
            return UniformScalarKind::Float;
        case GL_UNSIGNED_INT:
        case GL_UNSIGNED_INT_VEC2:
        case GL_UNSIGNED_INT_VEC3:
        case GL_UNSIGNED_INT_VEC4:
            return UniformScalarKind::UInt;
        default:
            // GL_INT*, GL_BOOL*, all sampler types.
            return UniformScalarKind::Int;
    }
}

// Phase 8X Group 4d follow-up¹⁵ — parse a GLSL 4.20 uniform default-value
// initializer of the form
//   = <numeric-literal>
//   = <typeword> ( <num-list> )
//   = <typeword> [ <array-size> ] ( <num-list> )
// where scalar/vector <num-list> is one comma-separated numeric literal
// (scalar broadcast) or exactly `components` comma-separated numeric literals.
// Array constructors must provide exactly one element's worth of components per
// array entry; unsized arrays infer their size from the initializer. On recognition,
// populates whichever of `out.defaultFloats` / `defaultInts` / `defaultUints`
// matches the declared variable's scalar kind. On any unrecognized token the
// function bails out silently, leaving the default vectors empty so
// linkProgram falls back to zero-seeding.
//
bool parseNumericDefaultLiteral(const std::string& tok, double& outValue) {
    if (tok.empty()) {
        return false;
    }
    const char first = tok[0];
    if (first != '-' && first != '+' && first != '.' &&
        !std::isdigit(static_cast<unsigned char>(first))) {
        return false;
    }

    std::string literal = tok;
    while (!literal.empty()) {
        const char c = literal.back();
        if (c == 'u' || c == 'U' || c == 'l' || c == 'L' || c == 'f' || c == 'F') {
            literal.pop_back();
        } else {
            break;
        }
    }
    if (literal.empty() || literal == "+" || literal == "-") {
        return false;
    }

    char* endp = nullptr;
    const double floatValue = std::strtod(literal.c_str(), &endp);
    if (endp != literal.c_str() && *endp == '\0') {
        outValue = floatValue;
        return true;
    }

    if (literal.front() == '-') {
        endp = nullptr;
        const long long intValue = std::strtoll(literal.c_str(), &endp, 0);
        if (endp != literal.c_str() && *endp == '\0') {
            outValue = static_cast<double>(intValue);
            return true;
        }
    } else {
        endp = nullptr;
        const unsigned long long uintValue = std::strtoull(literal.c_str(), &endp, 0);
        if (endp != literal.c_str() && *endp == '\0') {
            outValue = static_cast<double>(uintValue);
            return true;
        }
    }

    return false;
}

bool findMatchingToken(const std::vector<std::string>& tokens,
                       std::size_t openIndex,
                       const char* openToken,
                       const char* closeToken,
                       std::size_t limit,
                       std::size_t& closeIndex) {
    if (openIndex >= tokens.size() || tokens[openIndex] != openToken) {
        return false;
    }
    std::size_t depth = 1;
    closeIndex = openIndex + 1;
    while (closeIndex < limit && closeIndex < tokens.size()) {
        if (tokens[closeIndex] == openToken) {
            ++depth;
        } else if (tokens[closeIndex] == closeToken) {
            --depth;
            if (depth == 0) {
                return true;
            }
        }
        ++closeIndex;
    }
    return false;
}

bool parseArraySuffix(const std::vector<std::string>& tokens,
                      std::size_t openIndex,
                      std::size_t& closeIndex,
                      GLint& arraySize) {
    if (!findMatchingToken(tokens, openIndex, "[", "]", tokens.size(), closeIndex)) {
        return false;
    }
    arraySize = 0;
    if (closeIndex == openIndex + 1) {
        return true;
    }
    if (closeIndex == openIndex + 2) {
        char* endp = nullptr;
        const long value = std::strtol(tokens[openIndex + 1].c_str(), &endp, 10);
        if (endp != tokens[openIndex + 1].c_str() && *endp == '\0' && value > 0) {
            arraySize = static_cast<GLint>(value);
        }
    }
    return true;
}

bool collectInitializerValues(const std::vector<std::string>& tokens,
                              std::size_t begin,
                              std::size_t end,
                              std::vector<double>& outValues) {
    for (std::size_t i = begin; i < end && i < tokens.size();) {
        const std::string& tok = tokens[i];
        if (tok.empty() || tok == "," || tok == "(" || tok == ")" ||
            tok == "[" || tok == "]" || tok == "{" || tok == "}") {
            ++i;
            continue;
        }

        const TypeEntry* ctorType = lookupType(tok);
        if (ctorType != nullptr) {
            std::size_t callIndex = i + 1;
            if (callIndex < end && tokens[callIndex] == "[") {
                std::size_t closeBracket = callIndex;
                GLint ignoredArraySize = 0;
                if (!parseArraySuffix(tokens, callIndex, closeBracket, ignoredArraySize)) {
                    return false;
                }
                callIndex = closeBracket + 1;
            }
            if (callIndex < end && tokens[callIndex] == "(") {
                std::size_t closeParen = callIndex;
                if (!findMatchingToken(tokens, callIndex, "(", ")", end, closeParen)) {
                    return false;
                }
                std::vector<double> nested;
                if (!collectInitializerValues(tokens, callIndex + 1, closeParen, nested) ||
                    nested.empty()) {
                    return false;
                }
                if (nested.size() == 1u && ctorType->components > 1) {
                    GLint matrixCols = 0;
                    GLint matrixRows = 0;
                    if (matrixShape(ctorType->type, matrixCols, matrixRows)) {
                        std::vector<double> diagonalMatrix(
                            static_cast<std::size_t>(ctorType->components), 0.0);
                        const GLint diagonalCount = std::min(matrixCols, matrixRows);
                        for (GLint diagonal = 0; diagonal < diagonalCount; ++diagonal) {
                            diagonalMatrix[static_cast<std::size_t>(
                                diagonal * matrixRows + diagonal)] = nested[0];
                        }
                        outValues.insert(outValues.end(),
                                         diagonalMatrix.begin(),
                                         diagonalMatrix.end());
                    } else {
                        outValues.insert(outValues.end(),
                                         static_cast<std::size_t>(ctorType->components),
                                         nested[0]);
                    }
                } else if (nested.size() == static_cast<std::size_t>(ctorType->components)) {
                    outValues.insert(outValues.end(), nested.begin(), nested.end());
                } else {
                    return false;
                }
                i = closeParen + 1;
                continue;
            }
            return false;
        }

        double value = 0.0;
        if (!parseNumericDefaultLiteral(tok, value)) {
            return false;
        }
        outValues.push_back(value);
        ++i;
    }
    return true;
}

void parseDefaultInitializer(
    const std::vector<std::string>& tokens,
    std::size_t exprStart,
    const TypeEntry& varEntry,
    GLShaderDeclaration& out
) {
    const GLint components = varEntry.components;
    if (components <= 0) {
        return;
    }

    // Find the argument list range [argBegin, argEnd).
    std::size_t argBegin = exprStart;
    std::size_t argEnd = tokens.size();

    // Constructor forms: `<typeword> ( ... )` and
    // `<typeword> [ <array-size> ] ( ... )`. Skip the type/array wrapper and
    // scan forward to the matching close paren.
    std::size_t openParen = tokens.size();
    if (exprStart + 1 < tokens.size() && tokens[exprStart + 1] == "(") {
        openParen = exprStart + 1;
    } else if (exprStart + 2 < tokens.size() && tokens[exprStart + 1] == "[") {
        std::size_t closeBracket = exprStart + 2;
        std::size_t bracketDepth = 1;
        while (closeBracket < tokens.size() && bracketDepth > 0) {
            if (tokens[closeBracket] == "[") {
                ++bracketDepth;
            } else if (tokens[closeBracket] == "]") {
                --bracketDepth;
                if (bracketDepth == 0) {
                    break;
                }
            }
            ++closeBracket;
        }
        if (closeBracket + 1 < tokens.size() && tokens[closeBracket + 1] == "(") {
            openParen = closeBracket + 1;
        }
    }
    if (openParen < tokens.size()) {
        argBegin = openParen + 1;
        std::size_t depth = 1;
        argEnd = argBegin;
        while (argEnd < tokens.size() && depth > 0) {
            if (tokens[argEnd] == "(") {
                ++depth;
            } else if (tokens[argEnd] == ")") {
                --depth;
                if (depth == 0) {
                    break;
                }
            }
            ++argEnd;
        }
    }

    // Collect numeric literals from the argument range, skipping punctuation.
    // Constructor calls nested inside array constructors are flattened, with
    // scalar vector constructors broadcast to the declared component width.
    std::vector<double> values;
    values.reserve(static_cast<std::size_t>(components) *
                   static_cast<std::size_t>(std::max<GLint>(out.arraySize, 1)));
    if (!collectInitializerValues(tokens, argBegin, argEnd, values)) {
        return;
    }
    if (values.empty()) {
        return;
    }

    std::size_t expectedComponents = static_cast<std::size_t>(components);
    if (out.isArray) {
        if (out.arraySize <= 0) {
            if (values.size() % static_cast<std::size_t>(components) != 0) {
                return;
            }
            out.arraySize = static_cast<GLint>(
                values.size() / static_cast<std::size_t>(components));
            if (out.arraySize <= 0) {
                return;
            }
        }
        expectedComponents = static_cast<std::size_t>(components) *
                             static_cast<std::size_t>(out.arraySize);
    } else if (values.size() == 1 && components > 1) {
        // Scalar broadcast: `vec4(1.0)` -> {1,1,1,1}. Array constructors do
        // not use this path because they must provide one value per element.
        values.resize(static_cast<std::size_t>(components), values[0]);
    }
    if (values.size() != expectedComponents) {
        return;
    }

    switch (scalarKindForType(varEntry.type)) {
        case UniformScalarKind::Float:
            out.defaultFloats.reserve(expectedComponents);
            for (double v : values) {
                out.defaultFloats.push_back(static_cast<GLfloat>(v));
            }
            break;
        case UniformScalarKind::Int:
            out.defaultInts.reserve(expectedComponents);
            for (double v : values) {
                out.defaultInts.push_back(static_cast<GLint>(v));
            }
            break;
        case UniformScalarKind::UInt:
            out.defaultUints.reserve(expectedComponents);
            for (double v : values) {
                out.defaultUints.push_back(static_cast<GLuint>(v));
            }
            break;
    }
}

// After layout/qualifiers stripped, the remaining tokens are
// [qualifier] [precision] <type> <name> [[ <size> ]] [ = <initializer> ]
bool parseDeclTail(std::vector<std::string>& tokens, GLShaderDeclaration& out) {
    // Drop common precision qualifiers if present.
    while (!tokens.empty() && (tokens.front() == "highp" || tokens.front() == "mediump" || tokens.front() == "lowp")) {
        tokens.erase(tokens.begin());
    }
    // GL 4.6 §4.3 interpolation qualifiers that may precede the type
    // on `in` / `out` declarations: `flat`, `noperspective`, `smooth`,
    // `centroid`, `sample`, `invariant`, `patch`. Drop any that appear
    // before the type keyword so `flat int outFoo;` still parses.
    // CTS `texture_buffer.texture_buffer_texture_buffer_range` declares
    // `out flat int outTextureSize;` and was silently dropped without
    // this; the TF varying scan then rejected the program.
    while (!tokens.empty() &&
           (tokens.front() == "flat" || tokens.front() == "noperspective" ||
            tokens.front() == "smooth" || tokens.front() == "centroid" ||
            tokens.front() == "sample" || tokens.front() == "invariant" ||
            tokens.front() == "patch" ||
            tokens.front() == "readonly" || tokens.front() == "writeonly" ||
            tokens.front() == "coherent" || tokens.front() == "volatile" ||
            tokens.front() == "restrict")) {
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
    out.arraySize = 1;
    out.isArray = false;
    out.arrayDimensions.clear();
    std::size_t nameIdx = 1;
    if (nameIdx < tokens.size() && tokens[nameIdx] == "[") {
        std::size_t closeBracket = nameIdx;
        GLint arraySize = 0;
        if (!parseArraySuffix(tokens, nameIdx, closeBracket, arraySize)) {
            return false;
        }
        out.arraySize = arraySize;
        out.isArray = true;
        out.arrayDimensions.push_back(arraySize);
        nameIdx = closeBracket + 1;
    }
    if (nameIdx >= tokens.size()) {
        return false;
    }
    out.name = tokens[nameIdx];
    // Strip trailing `[N]` baked into the name token (rare) or the next tokens.
    // `postNameIdx` is the first token after the name (and its optional [N]
    // suffix) — the default-initializer scan below picks up from here.
    std::size_t postNameIdx = nameIdx + 1;
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
        out.isArray = true;
        out.arrayDimensions.push_back(out.arraySize);
    } else if (postNameIdx < tokens.size() && tokens[postNameIdx] == "[") {
        // GL 4.6 §4.3: `T name [N]` is a sized array; `T name []`
        // is an unsized array (arraySize stays 0, allowed for
        // SSBO trailing members and runtime-sized arrays). The
        // distinction lets the atomic_uint rejection at link/
        // compile time fire on `atomic_uint ac[];`.
        const bool hadArrayBeforeName = out.isArray;
        bool sawPostNameArray = false;
        while (postNameIdx < tokens.size() && tokens[postNameIdx] == "[") {
            std::size_t closeBracket = postNameIdx;
            GLint suffixArraySize = 0;
            if (!parseArraySuffix(tokens, postNameIdx, closeBracket, suffixArraySize)) {
                return false;
            }
            if (!sawPostNameArray && !hadArrayBeforeName) {
                out.arraySize = suffixArraySize;
            }
            out.arrayDimensions.push_back(suffixArraySize);
            out.isArray = true;
            sawPostNameArray = true;
            postNameIdx = closeBracket + 1;
        }
    }
    if (out.name.empty()) {
        return false;
    }
    // Phase 8X Group 4d follow-up¹⁵ — scan for `= <initializer>` after the
    // name/array-suffix. Scalar/vector uniforms and flat numeric array
    // constructors receive defaults; unsupported forms silently zero-seed.
    if (postNameIdx < tokens.size() && tokens[postNameIdx] == "=") {
        parseDefaultInitializer(tokens, postNameIdx + 1, *entry, out);
    }
    return true;
}

}  // namespace

GLSLReflectionResult reflectGLSL(std::string_view source, GLenum stage) {
    GLSLReflectionResult result;
    std::string spliced = spliceLineContinuations(source);
    std::string cleaned = stripComments(spliced);
    // First pass: capture `#define NAME INTEGER_LITERAL[u]` so we can
    // substitute NAME into the rest of the source before dropping
    // preprocessor lines. CTS `limits.max_uniform_components` builds
    // the GS via string concatenation:
    //   "${VERSION}...#define NUMBER_OF_UNIFORMS "  (preamble)
    // + "256u"                                       (runtime value)
    // + "uniform ivec4 uni_array[NUMBER_OF_UNIFORMS];"  (body)
    // Our old scanner dropped the `#define` unconditionally and left
    // `uni_array[NUMBER_OF_UNIFORMS]` unsubstituted, so
    // `parseDeclTail` read arraySize as 1 (strtol("NUMBER_OF_UNIFORMS")
    // = 0 → max(0, 1)). Then `glUniform4iv(loc, 256, data)` clamped
    // effCount to remaining = ref.arraySize = 1 and stored only 4
    // ints instead of 1024. Capture macros first, then substitute.
    std::unordered_map<std::string, std::string> defines;
    {
        std::size_t i = 0;
        while (i < cleaned.size()) {
            if (cleaned[i] == '#') {
                // Skip any whitespace between '#' and the directive name.
                std::size_t hashEnd = i + 1;
                while (hashEnd < cleaned.size() &&
                       (cleaned[hashEnd] == ' ' || cleaned[hashEnd] == '\t')) {
                    ++hashEnd;
                }
                const bool isDefine = (hashEnd + 7 <= cleaned.size() &&
                                       cleaned.compare(hashEnd, 7, "define ") == 0);
                if (isDefine) {
                    // Parse `#define NAME VALUE` on this line. Accept
                    // only identifier + integer-literal (optionally with
                    // trailing 'u' for unsigned). Reject function-like
                    // macros (` NAME(`) and multi-token values.
                    std::size_t p = hashEnd + 7;
                    while (p < cleaned.size() && (cleaned[p] == ' ' || cleaned[p] == '\t')) ++p;
                    std::size_t nameStart = p;
                    while (p < cleaned.size() &&
                           ((cleaned[p] >= 'A' && cleaned[p] <= 'Z') ||
                            (cleaned[p] >= 'a' && cleaned[p] <= 'z') ||
                            (cleaned[p] >= '0' && cleaned[p] <= '9') ||
                            cleaned[p] == '_')) ++p;
                    const std::string name = cleaned.substr(nameStart, p - nameStart);
                    if (p < cleaned.size() && cleaned[p] == '(') {
                        // Function-like macro — skip.
                    } else if (!name.empty()) {
                        while (p < cleaned.size() && (cleaned[p] == ' ' || cleaned[p] == '\t')) ++p;
                        std::size_t valStart = p;
                        while (p < cleaned.size() && cleaned[p] != '\n') ++p;
                        std::string value(cleaned.data() + valStart, p - valStart);
                        // Strip trailing whitespace.
                        while (!value.empty() &&
                               (value.back() == ' ' || value.back() == '\t' || value.back() == '\r')) {
                            value.pop_back();
                        }
                        // Strip trailing 'u'/'U' suffix on integer literals.
                        if (!value.empty() && (value.back() == 'u' || value.back() == 'U')) {
                            value.pop_back();
                        }
                        // Only accept pure integer-literal values — other
                        // macro shapes (expressions, strings) aren't used
                        // by any CTS shader we care about.
                        bool allDigit = !value.empty();
                        for (char c : value) {
                            if (!(c >= '0' && c <= '9')) { allDigit = false; break; }
                        }
                        if (allDigit) {
                            defines[name] = value;
                        }
                    }
                }
                while (i < cleaned.size() && cleaned[i] != '\n') ++i;
            } else {
                ++i;
            }
        }
    }
    // Substitute macros. Walk the cleaned source, replace identifiers
    // that match a define with the value. Bounded to identifier-boundary
    // tokens so we don't accidentally rewrite a partial match inside a
    // longer name.
    if (!defines.empty()) {
        std::string rewritten;
        rewritten.reserve(cleaned.size());
        std::size_t i = 0;
        auto isIdStart = [](char c) {
            return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
        };
        auto isIdCont = [](char c) {
            return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                   (c >= '0' && c <= '9') || c == '_';
        };
        while (i < cleaned.size()) {
            if (isIdStart(cleaned[i])) {
                std::size_t start = i;
                while (i < cleaned.size() && isIdCont(cleaned[i])) ++i;
                std::string tok(cleaned.data() + start, i - start);
                auto it = defines.find(tok);
                if (it != defines.end()) {
                    rewritten += it->second;
                } else {
                    rewritten += tok;
                }
            } else {
                rewritten.push_back(cleaned[i++]);
            }
        }
        cleaned = std::move(rewritten);
    }
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
    std::size_t initializerBraceDepth = 0;
    std::size_t parenDepth = 0;
    std::string statement;
    auto statementLooksLikeUniformInitializer = [](const std::string& text) {
        if (text.find('=') == std::string::npos) {
            return false;
        }
        constexpr const char* kUniform = "uniform";
        std::size_t pos = 0;
        while ((pos = text.find(kUniform, pos)) != std::string::npos) {
            const bool leftOk = (pos == 0) ||
                !(std::isalnum(static_cast<unsigned char>(text[pos - 1])) ||
                  text[pos - 1] == '_');
            const std::size_t end = pos + 7;
            const bool rightOk = (end >= text.size()) ||
                !(std::isalnum(static_cast<unsigned char>(text[end])) ||
                  text[end] == '_');
            if (leftOk && rightOk) {
                return true;
            }
            pos = end;
        }
        return false;
    };
    auto processStatement = [&](std::string raw) {
        std::vector<std::string> tokens = tokenize(raw);
        if (tokens.empty()) {
            return;
        }
        // Merge a per-layout-block result into the accumulator. Later
        // blocks override earlier ones per GLSL 4.2 §4.4 ("multiple
        // layout-qualifier-id forms of a uniform... are allowed; any
        // such repeated or redundant qualifier is taken as the last
        // one"). Unspecified fields on the new block leave the
        // accumulator intact so a series of single-value qualifiers
        // composes correctly. CTS
        // `shading_language_420pack.qualifier_override_layout`
        // declares `in layout(location = 3) layout(location = 2) vec4
        // in_vs_test` and expects location = 2.
        auto mergeLayout = [](LayoutQualifiers& acc, const LayoutQualifiers& q) {
            if (q.location >= 0)     acc.location = q.location;
            if (q.binding  >= 0)     acc.binding  = q.binding;
            if (q.index    >= 0)     acc.index    = q.index;
            if (q.offset   >= 0)     acc.offset   = q.offset;
            if (q.imageFormat != 0)  acc.imageFormat = q.imageFormat;
        };
        LayoutQualifiers layoutQ;
        // Parse all LEADING layout blocks (before any in/out/uniform).
        // Guard against infinite loops when extractLayoutQualifiers
        // early-returns without erasing the "layout" token (e.g. a
        // malformed `layout` statement without a following `(`, as
        // emitted by CTS CommonBug_ReservedNames when the reserved
        // word IS "layout"). Without the size-decrease guard the
        // outer processStatement would hang on such shaders and burn
        // 100% CPU in string-compare loops — reflectGLSL CPU time
        // grows without bound for a single malformed shader.
        while (!tokens.empty() && tokens.front() == "layout") {
            const std::size_t before = tokens.size();
            LayoutQualifiers one = extractLayoutQualifiers(tokens);
            mergeLayout(layoutQ, one);
            if (tokens.size() >= before) break;
        }
        if (tokens.empty()) {
            return;
        }
        // Drop additional qualifiers like `flat`, `smooth`, `centroid`, `noperspective`,
        // `invariant`, `precise`, `highp`/`mediump`/`lowp` (precision), and the
        // GL 4.2+ image-memory qualifiers `readonly`/`writeonly`/`coherent`/
        // `volatile`/`restrict`. Without the image-memory list, a declaration
        // like `writeonly uniform image2D uni_image;` leaves `writeonly` at
        // tokens[0] — the subsequent `uniform` check fails and the scanner
        // silently drops the image uniform, making glGetUniformLocation
        // return -1 (CTS shading_language_420pack sees "Uniform not available").
        //
        // Also handle interleaved `layout(...)` blocks between the storage
        // keyword and subsequent qualifiers: `in layout(location = 2)
        // smooth vec4 x` is legal and stores location = 2.
        auto dropAuxQualifiers = [&]() {
            while (!tokens.empty() && (tokens.front() == "flat" || tokens.front() == "smooth" ||
                                       tokens.front() == "centroid" || tokens.front() == "noperspective" ||
                                       tokens.front() == "invariant" || tokens.front() == "precise" ||
                                       tokens.front() == "highp" || tokens.front() == "mediump" ||
                                       tokens.front() == "lowp" ||
                                       tokens.front() == "readonly" || tokens.front() == "writeonly" ||
                                       tokens.front() == "coherent" || tokens.front() == "volatile" ||
                                       tokens.front() == "restrict" ||
                                       tokens.front() == "patch" || tokens.front() == "sample")) {
                tokens.erase(tokens.begin());
            }
        };
        dropAuxQualifiers();
        // CTS `shading_language_420pack.qualifier_order_uniform_test_id_2`
        // uses `highp layout(location=N) uniform layout(location=N) vec4 u`.
        // After dropping the precision qualifier, the pre-storage layout
        // block becomes leading; consume it before looking for `uniform`.
        while (!tokens.empty() && tokens.front() == "layout") {
            const std::size_t before = tokens.size();
            LayoutQualifiers one = extractLayoutQualifiers(tokens);
            mergeLayout(layoutQ, one);
            if (tokens.size() >= before) break;
            dropAuxQualifiers();
        }
        if (tokens.empty()) {
            return;
        }
        const std::string keyword = tokens.front();
        if (keyword != "uniform" && keyword != "in" && keyword != "out" &&
            keyword != "attribute" && keyword != "varying" &&
            keyword != "VERTEX_INPUT" && keyword != "VERTEX_OUTPUT") {
            return;
        }
        tokens.erase(tokens.begin());
        // Parse TRAILING layout blocks (after the storage keyword).
        // GLSL syntax: `in layout(location = 2) vec4 x;` or
        // `in layout(location = 3) layout(location = 2) vec4 x;`.
        // Same size-decrease guard as the leading-layout loop above.
        while (!tokens.empty() && tokens.front() == "layout") {
            const std::size_t before = tokens.size();
            LayoutQualifiers one = extractLayoutQualifiers(tokens);
            mergeLayout(layoutQ, one);
            if (tokens.size() >= before) break;
        }
        // Drop any interpolation/precision qualifiers that come AFTER
        // the storage+layout block (e.g. `in layout(...) smooth vec4 x`).
        dropAuxQualifiers();
        GLShaderDeclaration decl;
        if (!parseDeclTail(tokens, decl)) {
            return;
        }
        decl.explicitLocation = layoutQ.location;
        decl.explicitBinding  = layoutQ.binding;
        decl.explicitIndex    = layoutQ.index;
        decl.explicitOffset   = layoutQ.offset;
        decl.imageFormat      = layoutQ.imageFormat;

        // Save the GL type for any additional comma-separated declarations.
        const GLenum declaredType = decl.type;

        // Helper to add a declaration to the appropriate result list.
        auto addDecl = [&](GLShaderDeclaration d) {
            if (keyword == "uniform") {
                result.uniforms.push_back(std::move(d));
            } else if (keyword == "in" || keyword == "attribute" ||
                       keyword == "VERTEX_INPUT") {
                // GL 4.6 §4.3.4: `in` is valid in every stage. The
                // VS reads external vertex attributes; every later
                // stage reads outputs from the stage ahead of it.
                // We record all of them so the link-time varying-
                // type check (GLContext.mm) can compare producer
                // outputs to consumer inputs. Previous behaviour
                // recorded only VS inputs and silently dropped GS /
                // TCS / TES / FS input declarations — that made
                // `linking.vs_gs_variable_type_mismatch` and its
                // cousins unable to find the consumer-side
                // declaration and skipped the mismatch check.
                if (stage == GL_VERTEX_SHADER ||
                    stage == GL_FRAGMENT_SHADER ||
                    stage == GL_GEOMETRY_SHADER ||
                    stage == GL_TESS_CONTROL_SHADER ||
                    stage == GL_TESS_EVALUATION_SHADER) {
                    result.inputs.push_back(std::move(d));
                }
            } else if (keyword == "out" || keyword == "varying" ||
                       keyword == "VERTEX_OUTPUT") {
                if (stage == GL_FRAGMENT_SHADER || stage == GL_VERTEX_SHADER ||
                    stage == GL_GEOMETRY_SHADER || stage == GL_TESS_EVALUATION_SHADER ||
                    stage == GL_TESS_CONTROL_SHADER) {
                    result.outputs.push_back(std::move(d));
                }
            }
        };

        addDecl(std::move(decl));

        // Handle comma-separated additional declarations in the same statement,
        // e.g. "uniform int a, b, c;" or "in vec3 pos, norm;".
        // After parseDeclTail, tokens[0] = type, tokens[1] = first name.
        // Scan past the first declaration's optional array suffix and initializer
        // to find commas introducing additional variable names.
        std::size_t pos = 2;
        // Skip array suffix [N] if present as separate tokens.
        if (pos < tokens.size() && tokens[pos] == "[") {
            while (pos < tokens.size() && tokens[pos] != "]") {
                ++pos;
            }
            if (pos < tokens.size()) {
                ++pos; // skip ']'
            }
        }
        // Skip initializer = expr (respecting nested parens).
        if (pos < tokens.size() && tokens[pos] == "=") {
            ++pos;
            std::size_t depth = 0;
            while (pos < tokens.size()) {
                if (tokens[pos] == "(") {
                    ++depth;
                } else if (tokens[pos] == ")") {
                    if (depth > 0) --depth;
                } else if (tokens[pos] == "," && depth == 0) {
                    break;
                }
                ++pos;
            }
        }
        // Parse additional comma-separated variable declarations.
        while (pos < tokens.size() && tokens[pos] == ",") {
            ++pos; // skip comma
            if (pos >= tokens.size()) {
                break;
            }
            GLShaderDeclaration extra;
            extra.type     = declaredType;
            extra.name     = tokens[pos];
            extra.arraySize = 1;
            extra.explicitLocation = -1;
            extra.explicitBinding  = -1;
            ++pos;
            // Handle bracket embedded in name token (e.g. "arr[4]").
            auto bracket = extra.name.find('[');
            if (bracket != std::string::npos) {
                auto end = extra.name.find(']', bracket);
                if (end != std::string::npos) {
                    std::string sizeText = extra.name.substr(bracket + 1, end - bracket - 1);
                    if (!sizeText.empty()) {
                        extra.arraySize = static_cast<GLint>(
                            std::strtol(sizeText.c_str(), nullptr, 10));
                    }
                }
                extra.name.erase(bracket);
            } else if (pos < tokens.size() && tokens[pos] == "[") {
                ++pos; // skip '['
                if (pos < tokens.size()) {
                    extra.arraySize = static_cast<GLint>(
                        std::strtol(tokens[pos].c_str(), nullptr, 10));
                    ++pos;
                }
                if (pos < tokens.size() && tokens[pos] == "]") {
                    ++pos;
                }
            }
            if (extra.name.empty()) {
                break;
            }
            // Skip initializer for this extra variable.
            if (pos < tokens.size() && tokens[pos] == "=") {
                ++pos;
                std::size_t depth = 0;
                while (pos < tokens.size()) {
                    if (tokens[pos] == "(") {
                        ++depth;
                    } else if (tokens[pos] == ")") {
                        if (depth > 0) --depth;
                    } else if (tokens[pos] == "," && depth == 0) {
                        break;
                    }
                    ++pos;
                }
            }
            addDecl(std::move(extra));
        }
    };

    for (char c : cleaned) {
        if (initializerBraceDepth > 0) {
            statement.push_back(c);
            if (c == '{') {
                ++initializerBraceDepth;
            } else if (c == '}') {
                --initializerBraceDepth;
            }
            continue;
        }
        if (c == '{') {
            if (braceDepth == 0 && statementLooksLikeUniformInitializer(statement)) {
                initializerBraceDepth = 1;
                statement.push_back(c);
                continue;
            }
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
