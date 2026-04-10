#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "../../include/AppGL/glcorearb.h"

namespace appgl {

struct BindingMap {
    std::uint32_t uniformBufferBase = 0;
    std::uint32_t storageBufferBase = 16;
    std::uint32_t vertexBufferBase = 32;
    std::uint32_t textureBase = 0;
    std::uint32_t samplerBase = 0;
};

struct ShaderReflection {
    struct VertexInput {
        GLuint location = 0;
        GLenum type = 0;
        std::string name;
    };

    struct ResourceBinding {
        GLuint glBinding = 0;
        std::uint32_t metalBinding = 0;
        std::size_t byteSize = 0;
        std::string name;
    };

    std::vector<VertexInput> vertexInputs;
    std::vector<ResourceBinding> uniformBlocks;
    std::vector<ResourceBinding> sampledTextures;
    bool usesPointSize = false;
};

class ShaderTranslator {
public:
    std::vector<std::uint32_t> compileGLSL(std::string_view source, GLenum stage, int version, std::string* log) const;
    std::string spirvToMSL(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const;
    ShaderReflection reflect(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const;
};

}  // namespace appgl
