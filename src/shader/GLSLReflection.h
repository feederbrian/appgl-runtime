#pragma once

#include <string>
#include <string_view>
#include <vector>

#include "../../include/AppGL/glcorearb.h"
#include "../objects/GLObjectStore.h"

namespace appgl {

// Lightweight GLSL source reflector. Phase 6 ships with this built-in scanner so
// shader/program lifecycle entry points have meaningful reflection metadata
// without depending on the vendored glslang/SPIRV-Cross build (which the Xcode
// framework target does not yet link). The scanner recognizes top-level
// `uniform`, `in`, `out`, `attribute`, and `varying` declarations with optional
// `layout(location = N)` qualifiers and optional bracket array sizing.
//
// Limitations (intentional, the gauntlet uses well-formed minimal sources):
//   - No preprocessor expansion beyond stripping `#version` / `#extension` lines.
//   - No struct types, no interface blocks, no nested arrays.
//   - Comments and string content are stripped before tokenization.
struct GLSLReflectionResult {
    std::vector<GLShaderDeclaration> uniforms;
    std::vector<GLShaderDeclaration> inputs;
    std::vector<GLShaderDeclaration> outputs;
    std::string log;
    bool ok = true;
};

GLSLReflectionResult reflectGLSL(std::string_view source, GLenum stage);

// Returns 1 (scalar), 2..4 (vector), or 4/9/16 (matrix) for the GL uniform type
// enum. Used by the uniform setters to size the value buffer per location.
GLint glslComponentCount(GLenum type);

// Returns the canonical GLSL keyword for a uniform/attribute type enum.
const char* glslTypeKeyword(GLenum type);

}  // namespace appgl
