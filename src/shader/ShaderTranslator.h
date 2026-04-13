#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "../../include/AppGL/glcorearb.h"

namespace appgl {

// Metal exposes 31 buffer slots per shader stage (indices 0..30). Vertex
// buffers must live in the low half so they fit MTLVertexDescriptor's
// bufferIndex range, with uniform/storage buffers stacked above them. This
// must stay in lockstep with kVertexBufferBase in MetalVertexDescriptorBuilder.mm.
struct BindingMap {
    std::uint32_t vertexBufferBase = 0;    // [ 0..16) — VBOs
    std::uint32_t uniformBufferBase = 16;  // [16..28) — UBOs
    std::uint32_t storageBufferBase = 28;  // [28..30) — SSBOs (GL 4.3+, deferred)
    std::uint32_t textureBase = 0;
    std::uint32_t samplerBase = 0;
};

struct ShaderReflection {
    struct VertexInput {
        GLuint location = 0;
        GLenum type = 0;
        std::string name;
    };

    // Describes one member inside a UBO / push-constant block.  The offset
    // and size follow the GPU-side std140 / Metal buffer layout, which may
    // differ from the tightly packed GL uniform values (e.g. mat3 = 48
    // bytes on the GPU vs. 36 bytes in GL, vec3 columns padded to 16).
    struct UniformMember {
        std::string name;
        std::size_t offset = 0;   // byte offset within the struct
        std::size_t size = 0;     // byte size (includes column padding)
        GLenum type = 0;          // GL type (GL_FLOAT_MAT4, GL_FLOAT_VEC3…)
    };

    struct ResourceBinding {
        GLuint glBinding = 0;
        std::uint32_t metalBinding = 0;
        std::size_t byteSize = 0;
        std::string name;
        std::vector<UniformMember> members;
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
