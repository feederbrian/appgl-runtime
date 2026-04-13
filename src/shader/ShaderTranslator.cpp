#include "ShaderTranslator.h"

#ifdef APPGL_HAS_SHADER_COMPILER

#include <glslang/Public/ShaderLang.h>
#include <glslang/Public/ResourceLimits.h>
#include <SPIRV/GlslangToSpv.h>
#include <spirv_msl.hpp>

#include <mutex>

namespace appgl {
namespace {

std::once_flag g_glslangInitFlag;

void ensureGlslangInit() {
    std::call_once(g_glslangInitFlag, []() {
        glslang::InitializeProcess();
    });
}

EShLanguage glStageToEsh(GLenum stage) {
    switch (stage) {
        case GL_VERTEX_SHADER:          return EShLangVertex;
        case GL_FRAGMENT_SHADER:        return EShLangFragment;
        case GL_GEOMETRY_SHADER:        return EShLangGeometry;
        case GL_TESS_CONTROL_SHADER:    return EShLangTessControl;
        case GL_TESS_EVALUATION_SHADER: return EShLangTessEvaluation;
        case GL_COMPUTE_SHADER:         return EShLangCompute;
        default:                        return EShLangVertex;
    }
}

spv::ExecutionModel glStageToSpvModel(GLenum stage) {
    switch (stage) {
        case GL_VERTEX_SHADER:          return spv::ExecutionModelVertex;
        case GL_FRAGMENT_SHADER:        return spv::ExecutionModelFragment;
        case GL_GEOMETRY_SHADER:        return spv::ExecutionModelGeometry;
        case GL_TESS_CONTROL_SHADER:    return spv::ExecutionModelTessellationControl;
        case GL_TESS_EVALUATION_SHADER: return spv::ExecutionModelTessellationEvaluation;
        case GL_COMPUTE_SHADER:         return spv::ExecutionModelGLCompute;
        default:                        return spv::ExecutionModelVertex;
    }
}

GLenum spirvBaseTypeToGL(const spirv_cross::SPIRType& type) {
    using BT = spirv_cross::SPIRType::BaseType;
    if (type.basetype == BT::Float) {
        if (type.columns > 1) {
            // Matrix types
            if (type.columns == 2 && type.vecsize == 2) return GL_FLOAT_MAT2;
            if (type.columns == 3 && type.vecsize == 3) return GL_FLOAT_MAT3;
            if (type.columns == 4 && type.vecsize == 4) return GL_FLOAT_MAT4;
            return GL_FLOAT_MAT4;
        }
        switch (type.vecsize) {
            case 1: return GL_FLOAT;
            case 2: return GL_FLOAT_VEC2;
            case 3: return GL_FLOAT_VEC3;
            case 4: return GL_FLOAT_VEC4;
            default: return GL_FLOAT;
        }
    }
    if (type.basetype == BT::Int) {
        switch (type.vecsize) {
            case 1: return GL_INT;
            case 2: return GL_INT_VEC2;
            case 3: return GL_INT_VEC3;
            case 4: return GL_INT_VEC4;
            default: return GL_INT;
        }
    }
    if (type.basetype == BT::UInt) {
        switch (type.vecsize) {
            case 1: return GL_UNSIGNED_INT;
            case 2: return GL_UNSIGNED_INT_VEC2;
            case 3: return GL_UNSIGNED_INT_VEC3;
            case 4: return GL_UNSIGNED_INT_VEC4;
            default: return GL_UNSIGNED_INT;
        }
    }
    if (type.basetype == BT::Boolean) {
        switch (type.vecsize) {
            case 1: return GL_BOOL;
            case 2: return GL_BOOL_VEC2;
            case 3: return GL_BOOL_VEC3;
            case 4: return GL_BOOL_VEC4;
            default: return GL_BOOL;
        }
    }
    if (type.basetype == BT::SampledImage || type.basetype == BT::Image) {
        return GL_SAMPLER_2D;
    }
    return GL_FLOAT;
}

}  // namespace

std::vector<std::uint32_t> ShaderTranslator::compileGLSL(std::string_view source, GLenum stage, int version, std::string* log) const {
    ensureGlslangInit();

    EShLanguage eshStage = glStageToEsh(stage);
    glslang::TShader shader(eshStage);

    const char* sourcePtr = source.data();
    int sourceLen = static_cast<int>(source.size());
    shader.setStringsWithLengths(&sourcePtr, &sourceLen, 1);

    // Target Vulkan SPIR-V with relaxed rules so glslang accepts bare
    // uniforms from OpenGL GLSL. Bare uniforms are wrapped into a single
    // global uniform block (UBO) that SPIRV-Cross maps to a Metal buffer.
    shader.setEnvInput(glslang::EShSourceGlsl, eshStage, glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    shader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    shader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);
    shader.setEnvInputVulkanRulesRelaxed();
    shader.setAutoMapLocations(true);
    shader.setAutoMapBindings(true);
    shader.setGlobalUniformBlockName("_DefaultUniforms");
    shader.setGlobalUniformSet(0);
    shader.setGlobalUniformBinding(0);

    const TBuiltInResource* resources = GetDefaultResources();
    EShMessages messages = static_cast<EShMessages>(EShMsgSpvRules | EShMsgVulkanRules);

    if (!shader.parse(resources, version, false, messages)) {
        if (log != nullptr) {
            *log = shader.getInfoLog();
        }
        return {};
    }

    glslang::TProgram program;
    program.addShader(&shader);
    if (!program.link(messages)) {
        if (log != nullptr) {
            *log = program.getInfoLog();
        }
        return {};
    }

    std::vector<unsigned int> spirv;
    glslang::SpvOptions spvOptions;
    spvOptions.disableOptimizer = false;
    spvOptions.optimizeSize = true;
    glslang::GlslangToSpv(*program.getIntermediate(eshStage), spirv, &spvOptions);

    if (spirv.empty()) {
        if (log != nullptr) {
            *log = "SPIR-V generation produced empty output.";
        }
        return {};
    }

    if (log != nullptr) {
        *log = "ok";
    }

    return std::vector<std::uint32_t>(spirv.begin(), spirv.end());
}

std::string ShaderTranslator::spirvToMSL(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const {
    try {
        spirv_cross::CompilerMSL compiler(spirv, wordCount);

        spirv_cross::CompilerMSL::Options mslOpts;
        mslOpts.platform = spirv_cross::CompilerMSL::Options::macOS;
        mslOpts.set_msl_version(2, 1);
        mslOpts.enable_decoration_binding = true;
        compiler.set_msl_options(mslOpts);

        // Remap uniform buffers (UBOs + push constants) to Metal buffer slots.
        auto resources = compiler.get_shader_resources();
        for (auto& ubo : resources.uniform_buffers) {
            uint32_t glBinding = compiler.get_decoration(ubo.id, spv::DecorationBinding);
            spirv_cross::MSLResourceBinding binding;
            binding.stage = compiler.get_execution_model();
            binding.desc_set = compiler.get_decoration(ubo.id, spv::DecorationDescriptorSet);
            binding.binding = glBinding;
            binding.msl_buffer = bindings.uniformBufferBase + glBinding;
            compiler.add_msl_resource_binding(binding);
        }

        // Remap push-constant blocks (SPIRV-Cross treats default-block uniforms
        // as a push-constant buffer when coming from OpenGL GLSL).
        for (auto& pc : resources.push_constant_buffers) {
            spirv_cross::MSLResourceBinding binding;
            binding.stage = compiler.get_execution_model();
            binding.desc_set = spirv_cross::kPushConstDescSet;
            binding.binding = spirv_cross::kPushConstBinding;
            binding.msl_buffer = bindings.uniformBufferBase;
            compiler.add_msl_resource_binding(binding);
        }

        // Remap sampled images (combined image samplers).
        for (auto& img : resources.sampled_images) {
            uint32_t glBinding = compiler.get_decoration(img.id, spv::DecorationBinding);
            spirv_cross::MSLResourceBinding binding;
            binding.stage = compiler.get_execution_model();
            binding.desc_set = compiler.get_decoration(img.id, spv::DecorationDescriptorSet);
            binding.binding = glBinding;
            binding.msl_texture = bindings.textureBase + glBinding;
            binding.msl_sampler = bindings.samplerBase + glBinding;
            compiler.add_msl_resource_binding(binding);
        }

        std::string msl = compiler.compile();
        if (log != nullptr) {
            *log = "ok";
        }
        return msl;
    } catch (const spirv_cross::CompilerError& e) {
        if (log != nullptr) {
            *log = std::string("SPIRV-Cross error: ") + e.what();
        }
        return {};
    }
}

ShaderReflection ShaderTranslator::reflect(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const {
    ShaderReflection result;
    try {
        spirv_cross::Compiler compiler(spirv, wordCount);
        auto resources = compiler.get_shader_resources();

        // Vertex inputs (stage_inputs).
        for (auto& input : resources.stage_inputs) {
            ShaderReflection::VertexInput vi;
            vi.location = compiler.get_decoration(input.id, spv::DecorationLocation);
            vi.name = input.name;
            const auto& type = compiler.get_type(input.type_id);
            vi.type = spirvBaseTypeToGL(type);
            result.vertexInputs.push_back(std::move(vi));
        }

        // Uniform buffers.
        for (auto& ubo : resources.uniform_buffers) {
            ShaderReflection::ResourceBinding rb;
            rb.glBinding = compiler.get_decoration(ubo.id, spv::DecorationBinding);
            rb.metalBinding = bindings.uniformBufferBase + rb.glBinding;
            rb.name = ubo.name;
            const auto& type = compiler.get_type(ubo.base_type_id);
            rb.byteSize = compiler.get_declared_struct_size(type);

            // Enumerate struct members for per-stage uniform buffer packing.
            for (std::uint32_t mi = 0; mi < type.member_types.size(); ++mi) {
                ShaderReflection::UniformMember member;
                member.name = compiler.get_member_name(type.self, mi);
                member.offset = compiler.type_struct_member_offset(type, mi);
                member.size = compiler.get_declared_struct_member_size(type, mi);
                const auto& memberType = compiler.get_type(type.member_types[mi]);
                member.type = spirvBaseTypeToGL(memberType);
                rb.members.push_back(std::move(member));
            }

            result.uniformBlocks.push_back(std::move(rb));
        }

        // Push-constant blocks (default-block uniforms from OpenGL).
        for (auto& pc : resources.push_constant_buffers) {
            ShaderReflection::ResourceBinding rb;
            rb.glBinding = 0;
            rb.metalBinding = bindings.uniformBufferBase;
            rb.name = pc.name;
            const auto& type = compiler.get_type(pc.base_type_id);
            rb.byteSize = compiler.get_declared_struct_size(type);

            // Enumerate struct members so the draw path can build a
            // correctly-laid-out buffer for each shader stage.
            for (std::uint32_t mi = 0; mi < type.member_types.size(); ++mi) {
                ShaderReflection::UniformMember member;
                member.name = compiler.get_member_name(type.self, mi);
                member.offset = compiler.type_struct_member_offset(type, mi);
                member.size = compiler.get_declared_struct_member_size(type, mi);
                const auto& memberType = compiler.get_type(type.member_types[mi]);
                member.type = spirvBaseTypeToGL(memberType);
                rb.members.push_back(std::move(member));
            }

            result.uniformBlocks.push_back(std::move(rb));
        }

        // Sampled images.
        for (auto& img : resources.sampled_images) {
            ShaderReflection::ResourceBinding rb;
            rb.glBinding = compiler.get_decoration(img.id, spv::DecorationBinding);
            rb.metalBinding = bindings.textureBase + rb.glBinding;
            rb.name = img.name;
            result.sampledTextures.push_back(std::move(rb));
        }

        // Check for gl_PointSize usage.
        for (auto& builtin : resources.stage_outputs) {
            if (compiler.has_decoration(builtin.id, spv::DecorationBuiltIn)) {
                auto builtinType = static_cast<spv::BuiltIn>(compiler.get_decoration(builtin.id, spv::DecorationBuiltIn));
                if (builtinType == spv::BuiltInPointSize) {
                    result.usesPointSize = true;
                }
            }
        }

        if (log != nullptr) {
            *log = "ok";
        }
    } catch (const spirv_cross::CompilerError& e) {
        if (log != nullptr) {
            *log = std::string("SPIRV-Cross reflection error: ") + e.what();
        }
    }
    return result;
}

}  // namespace appgl

#else  // !APPGL_HAS_SHADER_COMPILER

namespace appgl {

std::vector<std::uint32_t> ShaderTranslator::compileGLSL(std::string_view source, GLenum stage, int version, std::string* log) const {
    (void)source;
    (void)stage;
    (void)version;
    if (log != nullptr) {
        *log = "Shader translator dependencies are vendored; GLSL compilation is not enabled in the bootstrap build yet.";
    }
    return {};
}

std::string ShaderTranslator::spirvToMSL(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const {
    (void)spirv;
    (void)wordCount;
    (void)bindings;
    if (log != nullptr) {
        *log = "SPIR-V to MSL translation is not enabled in the bootstrap build yet.";
    }
    return {};
}

ShaderReflection ShaderTranslator::reflect(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const {
    (void)spirv;
    (void)wordCount;
    (void)bindings;
    if (log != nullptr) {
        *log = "Shader reflection is not enabled in the bootstrap build yet.";
    }
    return {};
}

}  // namespace appgl

#endif  // APPGL_HAS_SHADER_COMPILER
