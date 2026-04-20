#include "ShaderTranslator.h"

#ifdef APPGL_HAS_SHADER_COMPILER

#include <glslang/Public/ShaderLang.h>
#include <glslang/Public/ResourceLimits.h>
#include <SPIRV/GlslangToSpv.h>
#include <spirv_msl.hpp>

#include <atomic>
#include <cstdio>
#include <cstdlib>
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
            // Matrix types — columns × vecsize (rows).
            // GL uses "matCxR" naming where C = columns, R = rows.
            if (type.columns == 2 && type.vecsize == 2) return GL_FLOAT_MAT2;
            if (type.columns == 2 && type.vecsize == 3) return GL_FLOAT_MAT2x3;
            if (type.columns == 2 && type.vecsize == 4) return GL_FLOAT_MAT2x4;
            if (type.columns == 3 && type.vecsize == 2) return GL_FLOAT_MAT3x2;
            if (type.columns == 3 && type.vecsize == 3) return GL_FLOAT_MAT3;
            if (type.columns == 3 && type.vecsize == 4) return GL_FLOAT_MAT3x4;
            if (type.columns == 4 && type.vecsize == 2) return GL_FLOAT_MAT4x2;
            if (type.columns == 4 && type.vecsize == 3) return GL_FLOAT_MAT4x3;
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

// Clone glslang's default TBuiltInResource and overwrite the limits
// that the CTS KHR-GL46.limits tests cross-check between
// glGetIntegerv(GL_MAX_*) on the CPU side and the GLSL built-in
// constants (gl_MaxVertexAttribs, gl_MaxDrawBuffers, …) that glslang
// materialises inside compiled shaders. Without matching values the
// tests flag the mismatch and fail.
//
// Values must match GLCapabilities.mm's `integerLimits_` table. Kept
// in lockstep manually — the per-category tests will surface any drift.
static TBuiltInResource makeAppGLBuiltInResources() {
    TBuiltInResource r = *GetDefaultResources();
    // Vertex stage.
    r.maxVertexAttribs = 32;
    r.maxVertexUniformComponents = 4096;
    r.maxVertexUniformVectors = 1024;        // components / 4
    // Per-stage texture-image-unit limits must match
    // GLCapabilities.mm's GL_MAX_*_TEXTURE_IMAGE_UNITS = 48 (bumped
    // in 4245d6b). CTS KHR-GL46.limits.max_*_texture_image_units
    // cross-checks the GLSL built-in gl_MaxVertex/Tess/Geom/Compute/-
    // TextureImageUnits against the GL advertised value; they must
    // agree. Previously 16 vs advertised-48 made 6 tests fail.
    r.maxVertexTextureImageUnits = 48;
    r.maxVertexOutputComponents = 128;
    r.maxVertexOutputVectors = 32;
    r.maxVertexAtomicCounters = 0;
    r.maxVertexAtomicCounterBuffers = 0;
    r.maxVertexImageUniforms = 8;
    // Fragment stage.
    r.maxFragmentUniformComponents = 4096;
    r.maxFragmentUniformVectors = 1024;
    r.maxFragmentInputComponents = 128;
    r.maxFragmentInputVectors = 32;
    r.maxFragmentAtomicCounters = 8;
    r.maxFragmentAtomicCounterBuffers = 1;
    r.maxFragmentImageUniforms = 8;
    // Combined / pipeline.
    r.maxTextureImageUnits = 48;            // per-stage fragment tex units
    r.maxCombinedTextureImageUnits = 80;
    r.maxDrawBuffers = 8;
    r.maxVaryingComponents = 128;
    r.maxVaryingVectors = 32;
    r.maxCombinedImageUniforms = 48;
    r.maxCombinedShaderOutputResources = 48;
    // Atomic counters. CTS gl4cLimitsTests.cpp:236 insists on at least
    // 4 bindings; we advertise 8 to match GL_MAX_ATOMIC_COUNTER_BUFFER_
    // BINDINGS in GLCapabilities.mm.
    r.maxAtomicCounterBindings = 8;
    r.maxAtomicCounterBufferSize = 32;
    r.maxTessControlAtomicCounters = 0;
    r.maxTessEvaluationAtomicCounters = 0;
    r.maxGeometryAtomicCounters = 0;
    r.maxCombinedAtomicCounters = 8;
    r.maxCombinedAtomicCounterBuffers = 1;
    // Image uniforms per tess / geometry.
    r.maxTessControlImageUniforms = 8;
    r.maxTessEvaluationImageUniforms = 8;
    r.maxGeometryImageUniforms = 8;
    // Per-stage tess / geometry texture image units (match GL advert
    // per 4245d6b).
    r.maxTessControlTextureImageUnits = 48;
    r.maxTessEvaluationTextureImageUnits = 48;
    r.maxGeometryTextureImageUnits = 48;
    // Compute stage.
    r.maxComputeAtomicCounterBuffers = 8;
    r.maxComputeAtomicCounters = 8;
    r.maxComputeImageUniforms = 8;
    r.maxComputeTextureImageUnits = 48;
    return r;
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

    // AppGL built-in-resource overrides: match the CPU-side caps
    // reported by GLCapabilities.mm so CTS limits tests (which
    // compare GLSL gl_Max* constants against glGetIntegerv) pass.
    static const TBuiltInResource appglResources = makeAppGLBuiltInResources();
    const TBuiltInResource* resources = &appglResources;
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

LinkedProgramSpirv ShaderTranslator::compileGLSLProgram(
    std::string_view vertexSource, std::string_view fragmentSource,
    int version, std::string* log) const {
    LinkedProgramSpirv result;
    ensureGlslangInit();

    glslang::TShader vsShader(EShLangVertex);
    glslang::TShader fsShader(EShLangFragment);

    // Configure both shaders identically to the per-stage `compileGLSL`
    // path so glslang sees the same dialect / target / global-uniform
    // settings for both halves of the program. The only thing different
    // about this path is that both shaders are eventually attached to the
    // SAME `glslang::TProgram` so the cross-stage interface matcher can
    // see vertex outputs and fragment inputs together.
    //
    // Critical: glslang::TShader::setStringsWithLengths stores the
    // POINTERS we pass in (not the strings) and dereferences them at
    // parse() time. The `sourcePtr` / `sourceLen` locals must therefore
    // outlive the parse() call below — keeping them in this function's
    // stack frame rather than a nested helper lambda is required. (An
    // earlier draft used a configureShader lambda; glslang then read
    // dangling stack memory after the lambda returned, yielding parse
    // errors like `'Ä' : unexpected token` and link errors like
    // `Missing entry point`.)
    const char* vsSourcePtr = vertexSource.data();
    const int vsSourceLen = static_cast<int>(vertexSource.size());
    const char* fsSourcePtr = fragmentSource.data();
    const int fsSourceLen = static_cast<int>(fragmentSource.size());

    vsShader.setStringsWithLengths(&vsSourcePtr, &vsSourceLen, 1);
    vsShader.setEnvInput(glslang::EShSourceGlsl, EShLangVertex,
                         glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    vsShader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    vsShader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);
    vsShader.setEnvInputVulkanRulesRelaxed();
    vsShader.setAutoMapLocations(true);
    vsShader.setAutoMapBindings(true);
    vsShader.setGlobalUniformBlockName("_DefaultUniforms");
    vsShader.setGlobalUniformSet(0);
    vsShader.setGlobalUniformBinding(0);
    fsShader.setStringsWithLengths(&fsSourcePtr, &fsSourceLen, 1);
    fsShader.setEnvInput(glslang::EShSourceGlsl, EShLangFragment,
                         glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    fsShader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
    fsShader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);
    fsShader.setEnvInputVulkanRulesRelaxed();
    fsShader.setAutoMapLocations(true);
    fsShader.setAutoMapBindings(true);
    fsShader.setGlobalUniformBlockName("_DefaultUniforms");
    fsShader.setGlobalUniformSet(0);
    fsShader.setGlobalUniformBinding(0);
    // AppGL built-in-resource overrides: match the CPU-side caps
    // reported by GLCapabilities.mm so CTS limits tests (which
    // compare GLSL gl_Max* constants against glGetIntegerv) pass.
    static const TBuiltInResource appglResources = makeAppGLBuiltInResources();
    const TBuiltInResource* resources = &appglResources;
    EShMessages messages = static_cast<EShMessages>(EShMsgSpvRules | EShMsgVulkanRules);

    if (!vsShader.parse(resources, version, false, messages)) {
        if (log != nullptr) {
            *log = std::string("vertex parse: ") + vsShader.getInfoLog();
        }
        return result;
    }
    if (!fsShader.parse(resources, version, false, messages)) {
        if (log != nullptr) {
            *log = std::string("fragment parse: ") + fsShader.getInfoLog();
        }
        return result;
    }

    glslang::TProgram program;
    program.addShader(&vsShader);
    program.addShader(&fsShader);

    if (!program.link(messages)) {
        if (log != nullptr) {
            *log = std::string("link: ") + program.getInfoLog();
        }
        return result;
    }

    // Run cross-stage IO mapping so glslang's default GLSL IO resolver
    // assigns matching `DecorationLocation` values to vertex outputs and
    // fragment inputs that share a name. The resolver walks the pipeline
    // in-order, sees both stages because we attached them to the same
    // TProgram above, and produces a coherent location table — which is
    // exactly what BAR observed missing in the followup⁴ Metal NSErrors.
    //
    // Without this pass, varyings in the SPIR-V come out either
    // unlocated or with per-stage-independent locations, and SPIRV-Cross
    // emits the mangled `m_NN_<name>` member form without `[[user(locN)]]`
    // attributes — which Metal rejects at `MTLRenderPipelineState`
    // creation time with a varying-mismatch error.
    if (!program.mapIO()) {
        if (log != nullptr) {
            *log = std::string("mapIO: ") + program.getInfoLog();
        }
        return result;
    }

    glslang::SpvOptions spvOptions;
    spvOptions.disableOptimizer = false;
    spvOptions.optimizeSize = true;

    std::vector<unsigned int> vsSpirv;
    std::vector<unsigned int> fsSpirv;
    glslang::GlslangToSpv(*program.getIntermediate(EShLangVertex), vsSpirv, &spvOptions);
    glslang::GlslangToSpv(*program.getIntermediate(EShLangFragment), fsSpirv, &spvOptions);

    if (vsSpirv.empty() || fsSpirv.empty()) {
        if (log != nullptr) {
            *log = "GlslangToSpv produced empty output for at least one stage";
        }
        return result;
    }

    result.vertexSpirv.assign(vsSpirv.begin(), vsSpirv.end());
    result.fragmentSpirv.assign(fsSpirv.begin(), fsSpirv.end());
    result.linkSucceeded = true;
    if (log != nullptr) {
        *log = "ok";
    }
    return result;
}

std::string ShaderTranslator::spirvToMSL(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const {
    try {
        spirv_cross::CompilerMSL compiler(spirv, wordCount);

        spirv_cross::CompilerMSL::Options mslOpts;
        mslOpts.platform = spirv_cross::CompilerMSL::Options::macOS;
        // MSL 2.2 (macOS 10.15+, 2019) required for:
        //   - `[[primitive_id]]` in fragment shaders on macOS — without it
        //     SPIRV-Cross throws `PrimitiveId on macOS requires MSL 2.2`
        //     and the FS translation returns empty. That made
        //     `geometry_shader.primitive_counter.primitive_id_from_fragment`
        //     render the clear color because the pipeline had no FS.
        //   - `[[barycentric]]` inputs (relevant for future GLSL_EXT_
        //     fragment_shader_barycentric support).
        // We're safe to bump: 10.15 is below every macOS version we
        // support as a host (12.0+), so every target platform has a
        // Metal driver ≥ MSL 2.2. Keep an eye on Apple-platform
        // regressions via the CTS sweep if we ever go back to 10.14
        // testing.
        mslOpts.set_msl_version(2, 2);
        mslOpts.enable_decoration_binding = true;
        // Pad fragment outputs to vec4 so Metal doesn't reject pipelines
        // where the shader outputs fewer components than the render target
        // format (e.g. float → MTLPixelFormatRGBA8Unorm).
        mslOpts.pad_fragment_output_components = true;
        compiler.set_msl_options(mslOpts);

        spirv_cross::CompilerGLSL::Options glslOpts = compiler.get_common_options();
        glslOpts.vertex.fixup_clipspace = true;
        compiler.set_common_options(glslOpts);

        // Remap uniform buffers (UBOs + push constants) to Metal buffer slots.
        // UBO arrays occupy consecutive Metal buffer indices, so we compute
        // a running offset rather than using uniformBufferBase + glBinding
        // (which would overlap when array sizes > 1).
        //
        // IMPORTANT: filter to only ACTIVE UBOs. In linked SPIR-V, an
        // unused UBO may share the same binding number as an active one
        // (glslang assigns binding=0 to dead variables). If we register
        // both with add_msl_resource_binding, the inactive one's slot
        // overwrites the active one's (keyed by desc_set+binding),
        // causing a Metal buffer slot mismatch at draw time.
        auto resources = compiler.get_shader_resources();
        auto activeVars = compiler.get_active_interface_variables();
        {
            // Sort by GL binding to get a deterministic assignment order
            // that matches between spirvToMSL and reflect.
            struct UBOEntry { std::uint32_t glBinding; spirv_cross::Resource* res; std::uint32_t arraySize; };
            std::vector<UBOEntry> sortedUBOs;
            for (auto& ubo : resources.uniform_buffers) {
                // Skip UBOs not actively referenced in this stage.
                if (activeVars.find(ubo.id) == activeVars.end()) continue;
                UBOEntry e;
                e.glBinding = compiler.get_decoration(ubo.id, spv::DecorationBinding);
                e.res = &ubo;
                const auto& varType = compiler.get_type(ubo.type_id);
                e.arraySize = (!varType.array.empty() && varType.array[0] > 0) ? varType.array[0] : 1;
                sortedUBOs.push_back(e);
            }
            std::sort(sortedUBOs.begin(), sortedUBOs.end(),
                      [](const UBOEntry& a, const UBOEntry& b) { return a.glBinding < b.glBinding; });

            std::uint32_t nextSlot = bindings.uniformBufferBase;
            for (auto& entry : sortedUBOs) {
                spirv_cross::MSLResourceBinding binding;
                binding.stage = compiler.get_execution_model();
                binding.desc_set = compiler.get_decoration(entry.res->id, spv::DecorationDescriptorSet);
                binding.binding = entry.glBinding;
                binding.msl_buffer = nextSlot;
                compiler.add_msl_resource_binding(binding);
                nextSlot += entry.arraySize;
            }
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

        // Remap shader-storage buffer objects (GL 4.3+). Assign Metal
        // buffer slots SEQUENTIALLY from `storageBufferBase` in
        // glBinding-sorted order — NOT `storageBufferBase + glBinding`
        // directly. GL permits bindings up to GL_MAX_SHADER_STORAGE_
        // BUFFER_BINDINGS (spec minimum 8), but Metal only exposes
        // 31 total buffer slots per stage of which we've reserved a
        // handful for SSBOs. Sequential allocation lets a shader
        // declare `layout(binding=7) buffer X` without us overflowing
        // Metal's slot budget — the reflection path mirrors this
        // ordering so dispatch-time bindings line up.
        //
        // Covers KHR-GL46.compute_shader.one-work-group which
        // iterates through bindings 0..7 over several sub-dispatches.
        {
            struct SSBORef { std::uint32_t glBinding; spirv_cross::Resource* res; };
            std::vector<SSBORef> sortedSSBOs;
            for (auto& ssbo : resources.storage_buffers) {
                SSBORef r;
                r.glBinding = compiler.get_decoration(ssbo.id, spv::DecorationBinding);
                r.res = &ssbo;
                sortedSSBOs.push_back(r);
            }
            std::sort(sortedSSBOs.begin(), sortedSSBOs.end(),
                      [](const SSBORef& a, const SSBORef& b) { return a.glBinding < b.glBinding; });
            std::uint32_t nextSSBOSlot = bindings.storageBufferBase;
            for (auto& entry : sortedSSBOs) {
                spirv_cross::MSLResourceBinding binding;
                binding.stage = compiler.get_execution_model();
                binding.desc_set = compiler.get_decoration(entry.res->id, spv::DecorationDescriptorSet);
                binding.binding = entry.glBinding;
                binding.msl_buffer = nextSSBOSlot++;
                compiler.add_msl_resource_binding(binding);
            }
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

        // Remap storage images (imageLoad/imageStore — GL `image2D` etc.).
        // These map to MSL `texture2d<T, access::read|write|read_write>`
        // and use the same textureBase slot space as sampled images.
        // KHR-GL46.compute_shader.copy-image and resource-image rely on
        // this routing to read a sampled binding back into an image
        // binding at draw time.
        for (auto& img : resources.storage_images) {
            uint32_t glBinding = compiler.get_decoration(img.id, spv::DecorationBinding);
            spirv_cross::MSLResourceBinding binding;
            binding.stage = compiler.get_execution_model();
            binding.desc_set = compiler.get_decoration(img.id, spv::DecorationDescriptorSet);
            binding.binding = glBinding;
            binding.msl_texture = bindings.textureBase + glBinding;
            compiler.add_msl_resource_binding(binding);
        }

        std::string msl = compiler.compile();

        // Runtime-sized array handling for SSBOs: SPIRV-Cross emits MSL
        // with `[65536]` for trailing `OpTypeRuntimeArray` members
        // (configured via backend.unsized_array_fallback_literal in the
        // patched third_party/SPIRV-Cross). The "1" default — which the
        // upstream MSL backend previously used — caused Apple GPUs to
        // silently drop `device T&` writes past index 0 under reference
        // semantics. Only actual runtime arrays get the large fallback;
        // fixed-size `[1]` members (e.g. `struct sC { uint3 mA[1]; };`)
        // keep their declared size because they take the `else if(size)`
        // branch in CompilerGLSL::to_array_size.

        // gl_ClipDistance / gl_CullDistance array-to-flattened rewrite:
        // SPIRV-Cross's MSL backend declares ClipDistance/CullDistance as
        // split individual `[[user(clipN)]]` / `[[user(cullN)]]` outputs
        // on `main0_out` (see CompilerMSL::entry_point_args around
        // BuiltInClipDistance/BuiltInCullDistance). But function-body
        // access chains like `out.gl_CullDistance[0] = ...` still
        // reference the unsplit array member that no longer exists on
        // the struct, causing MSL compilation to fail with:
        //   error: no member named 'gl_CullDistance' in 'main0_out'
        //
        // CTS KHR-GL46.cull_distance.* (201 tests) all trip on this.
        // Rewrite the literal access-chain pattern to the split name:
        //   out.gl_CullDistance[N] → out.gl_CullDistance_N
        //   out.gl_ClipDistance[N] → out.gl_ClipDistance_N
        // for N in [0..15] (gl_MaxCullDistances + gl_MaxClipDistances
        // are each 8 per GL spec, but grow the window to 16 so any
        // vendor extension or test that crosses the floor still matches).
        {
            std::string out;
            out.reserve(msl.size());
            const auto rewriteOne = [&out](const std::string& s, const char* arrayName) {
                std::string pattern = std::string(".") + arrayName + "[";
                std::size_t pos = 0;
                while (pos < s.size()) {
                    const std::size_t idx = s.find(pattern, pos);
                    if (idx == std::string::npos) {
                        out.append(s, pos, std::string::npos);
                        return;
                    }
                    out.append(s, pos, idx - pos);
                    // Parse the N in `[N]`.
                    const std::size_t numStart = idx + pattern.size();
                    std::size_t numEnd = numStart;
                    while (numEnd < s.size() && s[numEnd] >= '0' && s[numEnd] <= '9') ++numEnd;
                    if (numEnd == numStart || numEnd >= s.size() || s[numEnd] != ']') {
                        // Not a literal integer subscript — bail without rewriting this instance.
                        out.append(s, idx, pattern.size());
                        pos = idx + pattern.size();
                        continue;
                    }
                    out.append(".");
                    out.append(arrayName);
                    out.append("_");
                    out.append(s, numStart, numEnd - numStart);
                    pos = numEnd + 1;  // skip ']'
                }
            };
            rewriteOne(msl, "gl_CullDistance");
            msl = std::move(out);
            // Intentionally do NOT rewrite `gl_ClipDistance[N]`. Unlike
            // CullDistance, Metal has a hardware `[[clip_distance]]`
            // attribute which SPIRV-Cross emits on `main0_out` under the
            // exact unsplit name `gl_ClipDistance`. SPIRV-Cross's own
            // output *writes both* the split user-varying
            // (`out.gl_ClipDistance_N = EXPR;`) and the hardware copy-back
            // (`out.gl_ClipDistance[N] = out.gl_ClipDistance_N;`) in the
            // emitted function body. Rewriting the hardware write to
            // `out.gl_ClipDistance_N = out.gl_ClipDistance_N;` made it a
            // no-op, leaving the `[[clip_distance]]` array uninitialised —
            // Metal then read garbage (typically negative) and clipped
            // every pixel. That was the root cause of CTS
            // clip_distance.functional + cull_distance.functional_*
            // (~400 tests) all reporting "vertex unexpectedly clipped".
        }

        // [[point_size]] for point primitives is handled purely through
        // `MTLRenderPipelineDescriptor.inputPrimitiveTopology = Point`
        // — Metal defaults point_size to 1.0 in that mode when the VS
        // doesn't write it. A prior iteration of this file injected
        // `out.gl_PointSize = 1.0;` into every VS MSL body, but that
        // caused `AGXMetalG13X Error Domain Code=3: "Vertex shader
        // writes point size but inputPrimitiveTopology is
        // MTLPrimitiveTopologyClassTriangle"` for every triangle /
        // line draw in the suite (all `shaders.arrays.*`, many of
        // `pixelstoragemodes.*`, etc. — 4k+ regressions on sweep s17).
        // Removed unconditionally.

        // gl_CullDistance → [[clip_distance]] routing (vertex stages only).
        //
        // Metal has no `[[cull_distance]]` attribute. GL 4.6 §14.6.3 cull
        // semantics are per-primitive — "discard the whole primitive iff
        // ∃ channel i such that ALL vertices have cull_distance[i] < 0" —
        // and can only be exactly emulated through a compute pre-pass
        // that sees every vertex of a primitive before rasterization
        // (deferred). The pragmatic quick-fix is to route each cull
        // channel into an extra `[[clip_distance]]` slot, which gives
        // correct behaviour for two of three cases:
        //   - all-positive on a channel → primitive drawn (matches cull)
        //   - all-negative on a channel → primitive discarded (matches)
        //   - mixed-sign on a channel   → per-pixel clip instead of full
        //     draw. Over-clips on triangles/lines with mixed-sign cull
        //     channels. Exact for points (1-vertex primitives).
        //
        // SPIRV-Cross emits `gl_CullDistance_K [[user(cullK)]]` user
        // varyings for cull distances — they carry the value as plain
        // interpolated data but don't drive HW culling. We post-process:
        //   1. Count `gl_CullDistance_K` declarations in main0_out (M).
        //   2. Locate `float gl_ClipDistance [[clip_distance]] [N];` and
        //      resize to [N+M]. If absent (0-clip shader), insert with
        //      size [M].
        //   3. For each `out.gl_CullDistance_K = EXPR;` statement, append
        //      a sibling `out.gl_ClipDistance[N+K] = EXPR;` so the HW
        //      clip array sees the cull value.
        // Only applied to vertex shaders (MSL `vertex main0_out main0(`).
        // Fragment/compute stages have no rasterizer clipping and don't
        // declare `[[clip_distance]]` at all.
        if (msl.find("vertex ") != std::string::npos
            && msl.find("gl_CullDistance_0 [[user(cull0)]]") != std::string::npos) {
            // Count cull distances (gl_CullDistance_0 through _7).
            int cullCount = 0;
            for (int k = 0; k < 8; ++k) {
                char needle[64];
                std::snprintf(needle, sizeof(needle),
                              "gl_CullDistance_%d [[user(cull%d)]]", k, k);
                if (msl.find(needle) != std::string::npos) {
                    cullCount = k + 1;
                } else {
                    break;
                }
            }
            if (cullCount > 0) {
                // Find the HW clip-distance declaration and extract N.
                // Pattern: `float gl_ClipDistance [[clip_distance]] [N];`
                int clipCount = 0;
                const std::string clipDeclPrefix = "float gl_ClipDistance [[clip_distance]] [";
                std::size_t clipDeclPos = msl.find(clipDeclPrefix);
                if (clipDeclPos != std::string::npos) {
                    // Parse N between '[' and ']'.
                    std::size_t nStart = clipDeclPos + clipDeclPrefix.size();
                    std::size_t nEnd = nStart;
                    while (nEnd < msl.size() && msl[nEnd] >= '0' && msl[nEnd] <= '9') ++nEnd;
                    if (nEnd > nStart && nEnd < msl.size() && msl[nEnd] == ']') {
                        clipCount = std::stoi(msl.substr(nStart, nEnd - nStart));
                        // Resize in place by rewriting the size digits.
                        const int newSize = clipCount + cullCount;
                        if (newSize <= 8) {   // Metal HW clip cap is 8 total
                            std::string newSizeStr = std::to_string(newSize);
                            msl.replace(nStart, nEnd - nStart, newSizeStr);
                        } else {
                            clipCount = -1;   // Skip if we'd overflow.
                        }
                    }
                } else {
                    // No HW clip distance. Insert a fresh declaration
                    // before the first `gl_CullDistance_0` declaration.
                    const std::string firstCullDecl = "float gl_CullDistance_0 [[user(cull0)]];";
                    std::size_t insertPos = msl.find(firstCullDecl);
                    if (insertPos != std::string::npos && cullCount <= 8) {
                        std::string newDecl = "float gl_ClipDistance [[clip_distance]] ["
                            + std::to_string(cullCount) + "];\n    ";
                        msl.insert(insertPos, newDecl);
                        clipCount = 0;
                    } else {
                        clipCount = -1;   // Skip.
                    }
                }

                if (clipCount >= 0) {
                    // For each cull write (`out.gl_CullDistance_K = EXPR;`)
                    // append a sibling HW clip write at slot clipCount+K.
                    std::string rebuilt;
                    rebuilt.reserve(msl.size() + cullCount * 64);
                    std::size_t pos = 0;
                    while (pos < msl.size()) {
                        const std::size_t nl = msl.find('\n', pos);
                        const std::size_t lineEnd = (nl == std::string::npos) ? msl.size() : nl + 1;
                        rebuilt.append(msl, pos, lineEnd - pos);
                        // Check for `out.gl_CullDistance_K = EXPR;`.
                        const std::string_view line(msl.data() + pos, lineEnd - pos);
                        const std::string cullLhs = "out.gl_CullDistance_";
                        std::size_t lhsPos = line.find(cullLhs);
                        if (lhsPos != std::string_view::npos) {
                            // Parse K.
                            std::size_t kStart = lhsPos + cullLhs.size();
                            std::size_t kEnd = kStart;
                            while (kEnd < line.size() && line[kEnd] >= '0' && line[kEnd] <= '9') ++kEnd;
                            if (kEnd > kStart && kEnd < line.size()) {
                                int k = std::stoi(std::string(line.substr(kStart, kEnd - kStart)));
                                if (k < cullCount) {
                                    // Find " = " and the trailing ";".
                                    std::size_t eqPos = line.find(" = ", kEnd);
                                    std::size_t semiPos = line.rfind(';', line.size() - 1);
                                    if (eqPos != std::string_view::npos
                                        && semiPos != std::string_view::npos
                                        && semiPos > eqPos + 3) {
                                        std::string rhs(line.substr(eqPos + 3, semiPos - (eqPos + 3)));
                                        // Preserve the leading whitespace.
                                        std::size_t wsEnd = 0;
                                        while (wsEnd < line.size()
                                               && (line[wsEnd] == ' ' || line[wsEnd] == '\t')) {
                                            ++wsEnd;
                                        }
                                        std::string prefix(line.substr(0, wsEnd));
                                        rebuilt.append(prefix);
                                        rebuilt.append("out.gl_ClipDistance[");
                                        rebuilt.append(std::to_string(clipCount + k));
                                        rebuilt.append("] = ");
                                        rebuilt.append(rhs);
                                        rebuilt.append(";\n");
                                    }
                                }
                            }
                        }
                        pos = lineEnd;
                    }
                    msl = std::move(rebuilt);
                }
            }
        }

        // SPIRV-Cross's "copy internal per-vertex block to split user(N)
        // outputs" pass sometimes leaves dangling references to a SPIR-V
        // variable ID that's never emitted as a local (observed as
        // `_NN._RESERVED_IDENTIFIER_FIXUP_gl_CullDistance[K]` on the RHS
        // of the redundant copy-back writes). The immediately-preceding
        // statements already wrote the correct values to the split
        // outputs (e.g. `out.gl_CullDistance_0 = culldistance_data[0];`),
        // so the reserved-identifier copy-back is a duplicate that only
        // fails because its source variable was optimized away. Strip
        // any line containing that prefix — the earlier write is the
        // real one and carries the user's intended value.
        {
            const std::string kMarker = "_RESERVED_IDENTIFIER_FIXUP_gl_";
            std::string out;
            out.reserve(msl.size());
            std::size_t pos = 0;
            while (pos < msl.size()) {
                const std::size_t nl = msl.find('\n', pos);
                const std::size_t lineEnd = (nl == std::string::npos) ? msl.size() : nl + 1;
                const std::string_view line(msl.data() + pos, lineEnd - pos);
                if (line.find(kMarker) == std::string_view::npos) {
                    out.append(line);
                }
                pos = lineEnd;
            }
            msl = std::move(out);
        }

        if (log != nullptr) {
            *log = "ok";
        }
        // Diagnostic dump: if APPGL_DUMP_MSL is set to a directory path,
        // write the generated MSL for every translated shader to
        // msl_NNNN.metal. Used for debugging SPIRV-Cross output (std140
        // matrix stride, runtime-array declarations, rasterizer-discard
        // vertex-void shapes) against failing CTS tests.
        if (const char* dumpPath = std::getenv("APPGL_DUMP_MSL")) {
            static std::atomic<int> counter{0};
            const int n = counter.fetch_add(1);
            char path[512];
            std::snprintf(path, sizeof(path), "%s/msl_%04d.metal", dumpPath, n);
            if (FILE* f = std::fopen(path, "w")) {
                std::fwrite(msl.data(), 1, msl.size(), f);
                std::fclose(f);
            }
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

        // Vertex inputs (stage_inputs). SPIR-V assigns one OpDecorate
        // Location per input, but SPIRV-Cross MSL EXPANDS arrays into
        // N individual `[[attribute(K)]]` slots (one per element).
        // The reflection's .location must match the EXPANDED MSL slot
        // numbers so getAttribLocation("arr[K]") resolves to the real
        // Metal attribute — otherwise a later non-array input ends up
        // colliding with an earlier array's element slots. For example:
        //   in float clipdistance_data[1];  // SPIR-V loc 0 → MSL attr 0
        //   in float culldistance_data[8];  // SPIR-V loc 1 → MSL attr 1..8
        //   in vec2 position;               // SPIR-V loc 2 → MSL attr 9
        // Pre-fix, position was reported at location 2 and CTS's
        // vertexAttribPointer(getAttribLocation("position"), …) wrote
        // into Metal attribute 2 which is actually culldistance_data_1.
        //
        // Re-derive the expanded locations by sorting inputs by their
        // SPIR-V Location and walking them, accumulating per-array
        // slot counts so each subsequent input starts after the
        // previous one's full size.
        struct InputEntry {
            spirv_cross::Resource* res;
            std::uint32_t spirvLocation;
            std::uint32_t slotCount;
        };
        std::vector<InputEntry> sortedInputs;
        sortedInputs.reserve(resources.stage_inputs.size());
        for (auto& input : resources.stage_inputs) {
            InputEntry e;
            e.res = &input;
            e.spirvLocation = compiler.get_decoration(input.id, spv::DecorationLocation);
            const auto& type = compiler.get_type(input.type_id);
            // Array inputs: each outer-dimension element consumes one
            // location slot. Non-array inputs consume 1. Matrices and
            // dvec3/dvec4 technically consume multiple slots but are
            // unlikely in vertex-attribute declarations (GL 4.6 spec
            // restricts vertex attributes to scalar/vector/dvec).
            e.slotCount = (!type.array.empty() && type.array[0] > 0)
                ? static_cast<std::uint32_t>(type.array[0]) : 1u;
            sortedInputs.push_back(e);
        }
        std::sort(sortedInputs.begin(), sortedInputs.end(),
                  [](const InputEntry& a, const InputEntry& b) {
                      return a.spirvLocation < b.spirvLocation;
                  });
        // Walk in SPIR-V location order; emit MSL-remapped locations so
        // each array takes contiguous slots and the next input starts
        // after the previous input's final slot. Array inputs emit one
        // VertexInput per element — this matches SPIRV-Cross MSL
        // output, where `in float arr[8]` becomes 8 separate
        // `[[attribute(N..N+7)]]` declarations. The pipeline builder
        // in MetalFrameGraph.mm iterates `vertexInputs` and sets
        // `vertexDescriptor.attributes[input.location].format`, so
        // missing per-element entries would leave Metal attributes
        // 2..8 unset even with a correctly-bound VAO.
        std::uint32_t nextMslLocation = 0;
        for (auto& entry : sortedInputs) {
            if (entry.spirvLocation > nextMslLocation) {
                nextMslLocation = entry.spirvLocation;
            }
            const auto& type = compiler.get_type(entry.res->type_id);
            const GLenum glType = spirvBaseTypeToGL(type);
            for (std::uint32_t slot = 0; slot < entry.slotCount; ++slot) {
                ShaderReflection::VertexInput vi;
                vi.location = nextMslLocation + slot;
                vi.name = entry.slotCount > 1
                    ? (entry.res->name + "[" + std::to_string(slot) + "]")
                    : entry.res->name;
                vi.type = glType;
                result.vertexInputs.push_back(std::move(vi));
            }
            nextMslLocation += entry.slotCount;
        }

        // Uniform buffers — two-pass approach:
        //  Pass 1: compute Metal slot assignments for ACTIVE UBOs only,
        //          matching spirvToMSL (which must skip inactive UBOs to
        //          avoid binding-collision with add_msl_resource_binding).
        //  Pass 2: emit ResourceBindings for ALL UBOs (active + inactive)
        //          so that declared-but-unused blocks still appear in the
        //          program's uniform block list (CTS queries them).
        auto activeVars = compiler.get_active_interface_variables();
        {
            struct UBORef { std::uint32_t glBinding; std::uint32_t arraySize;
                            spirv_cross::Resource* res; bool active; };
            std::vector<UBORef> sortedUBOs;
            for (auto& ubo : resources.uniform_buffers) {
                UBORef r;
                r.glBinding = compiler.get_decoration(ubo.id, spv::DecorationBinding);
                const auto& vt = compiler.get_type(ubo.type_id);
                r.arraySize = (!vt.array.empty() && vt.array[0] > 0) ? vt.array[0] : 1;
                r.res = &ubo;
                r.active = (activeVars.find(ubo.id) != activeVars.end());
                sortedUBOs.push_back(r);
            }
            // Sort active UBOs first (by glBinding), inactive last.
            std::sort(sortedUBOs.begin(), sortedUBOs.end(),
                      [](const UBORef& a, const UBORef& b) {
                          if (a.active != b.active) return a.active > b.active;
                          return a.glBinding < b.glBinding;
                      });

            // Assign Metal slots to ACTIVE UBOs with running offset
            // (matching spirvToMSL). Inactive UBOs get a dummy slot (30)
            // — data bound there is harmless (Metal ignores unmatched slots).
            std::uint32_t nextSlot = bindings.uniformBufferBase;
            for (auto& entry : sortedUBOs) {
                auto& ubo = *entry.res;
            ShaderReflection::ResourceBinding rb;
            rb.glBinding = entry.glBinding;
            rb.active = entry.active;
            if (entry.active) {
                rb.metalBinding = nextSlot;
                nextSlot += entry.arraySize;
            } else {
                rb.metalBinding = 30; // dummy — not in the Metal shader
            }
            // Use the block TYPE name for introspection. The variable name
            // (ubo.name) is the instance name when present, or the type name
            // when the block has no instance name.
            const auto& uboType = compiler.get_type(ubo.base_type_id);
            const std::string typeName = compiler.get_name(uboType.self);
            rb.name = typeName.empty() ? ubo.name : typeName;
            rb.hasInstanceName = (!typeName.empty() && ubo.name != typeName);
            const auto& type = compiler.get_type(ubo.base_type_id);
            rb.byteSize = compiler.get_declared_struct_size(type);
            // entry.arraySize is 1 for non-arrays AND for 1-element arrays.
            // Distinguish them by checking the SPIR-V variable type directly.
            {
                const auto& varType = compiler.get_type(ubo.type_id);
                if (!varType.array.empty()) {
                    rb.blockArraySize = entry.arraySize; // true array (even if [1])
                }
            }

            // Enumerate struct members for per-stage uniform buffer packing.
            // Struct members are recursively flattened: for a member
            // `S s;` where S has fields `a`, `b`, the output contains
            // entries named `s.a`, `s.b` with offsets relative to the
            // UBO base, not the struct base.
            std::function<void(const spirv_cross::SPIRType&, const std::string&, std::size_t)>
                flattenMembers = [&](const spirv_cross::SPIRType& parentType,
                                     const std::string& prefix,
                                     std::size_t baseOffset) {
                for (std::uint32_t mi = 0; mi < parentType.member_types.size(); ++mi) {
                    const auto& memberType = compiler.get_type(parentType.member_types[mi]);
                    std::string memberName = compiler.get_member_name(parentType.self, mi);
                    std::size_t memberOffset = baseOffset +
                        compiler.type_struct_member_offset(parentType, mi);

                    // Recurse into nested struct members.
                    if (memberType.basetype == spirv_cross::SPIRType::Struct &&
                        memberType.columns == 1 && memberType.array.empty()) {
                        std::string childPrefix = prefix.empty()
                            ? memberName : (prefix + "." + memberName);
                        flattenMembers(memberType, childPrefix, memberOffset);
                        continue;
                    }
                    // Recurse into arrays of structs.
                    if (memberType.basetype == spirv_cross::SPIRType::Struct &&
                        !memberType.array.empty() && memberType.array[0] > 0) {
                        std::size_t elemStride = compiler.get_declared_struct_member_size(parentType, mi)
                            / memberType.array[0];
                        for (std::uint32_t ai = 0; ai < memberType.array[0]; ++ai) {
                            std::string elemPrefix = (prefix.empty() ? memberName : (prefix + "." + memberName))
                                + "[" + std::to_string(ai) + "]";
                            flattenMembers(memberType, elemPrefix,
                                           memberOffset + ai * elemStride);
                        }
                        continue;
                    }

                    ShaderReflection::UniformMember member;
                    member.name = prefix.empty()
                        ? memberName : (prefix + "." + memberName);
                    member.offset = memberOffset;
                    member.size = compiler.get_declared_struct_member_size(parentType, mi);
                    member.type = spirvBaseTypeToGL(memberType);
                    // Detect row_major decoration on matrix members.
                    // A block-level `layout(row_major)` causes SPIRV-Cross
                    // to decorate each matrix member via
                    // DecorationColMajor=false, so only DecorationRowMajor
                    // reliably signals row_major on the member.
                    if (memberType.columns > 1) {
                        member.isRowMajor = compiler.has_member_decoration(
                            parentType.self, mi, spv::DecorationRowMajor);
                    }
                    // Detect array members.
                    if (!memberType.array.empty()) {
                        member.isArray = true;
                        if (memberType.array[0] > 0) {
                            member.arraySize = memberType.array[0];
                        }
                    }
                    // Block-member strides.
                    if (compiler.has_member_decoration(parentType.self, mi,
                            spv::DecorationArrayStride)) {
                        member.arrayStride = static_cast<GLint>(
                            compiler.get_member_decoration(parentType.self, mi,
                                spv::DecorationArrayStride));
                    }
                    if (compiler.has_member_decoration(parentType.self, mi,
                            spv::DecorationMatrixStride)) {
                        member.matrixStride = static_cast<GLint>(
                            compiler.get_member_decoration(parentType.self, mi,
                                spv::DecorationMatrixStride));
                    }
                    rb.members.push_back(std::move(member));
                }
            };
            flattenMembers(type, "", 0);

            // Ensure byteSize covers all flattened members. SPIRV-Cross's
            // get_declared_struct_size can undercount for the last member
            // of a struct (it omits trailing padding — e.g., uvec4 reported
            // as 12 bytes instead of 16). Compute the true member extent
            // from the GL type's component count × 4 bytes.
            for (const auto& m : rb.members) {
                // Compute scalar component count from the GL type.
                std::size_t memberExtent = m.size;  // default fallback
                switch (m.type) {
                    case GL_FLOAT: case GL_INT: case GL_UNSIGNED_INT: case GL_BOOL:
                        memberExtent = 4; break;
                    case GL_FLOAT_VEC2: case GL_INT_VEC2: case GL_UNSIGNED_INT_VEC2: case GL_BOOL_VEC2:
                        memberExtent = 8; break;
                    case GL_FLOAT_VEC3: case GL_INT_VEC3: case GL_UNSIGNED_INT_VEC3: case GL_BOOL_VEC3:
                        memberExtent = 12; break;
                    case GL_FLOAT_VEC4: case GL_INT_VEC4: case GL_UNSIGNED_INT_VEC4: case GL_BOOL_VEC4:
                        memberExtent = 16; break;
                    // Matrices: cols × 16 (each column is vec4-padded in std140)
                    case GL_FLOAT_MAT2:   memberExtent = 2 * 16; break;
                    case GL_FLOAT_MAT3:   memberExtent = 3 * 16; break;
                    case GL_FLOAT_MAT4:   memberExtent = 4 * 16; break;
                    case GL_FLOAT_MAT2x3: memberExtent = 2 * 16; break;
                    case GL_FLOAT_MAT2x4: memberExtent = 2 * 16; break;
                    case GL_FLOAT_MAT3x2: memberExtent = 3 * 16; break;
                    case GL_FLOAT_MAT3x4: memberExtent = 3 * 16; break;
                    case GL_FLOAT_MAT4x2: memberExtent = 4 * 16; break;
                    case GL_FLOAT_MAT4x3: memberExtent = 4 * 16; break;
                    default: break;
                }
                // For arrays, total extent = arraySize × stride (stride = vec4-aligned element)
                if (m.arraySize > 0) {
                    // Each array element is rounded up to vec4 alignment (16 bytes)
                    std::size_t elemAligned = (memberExtent + 15) & ~std::size_t(15);
                    memberExtent = m.arraySize * elemAligned;
                }
                std::size_t memberEnd = m.offset + memberExtent;
                if (memberEnd > rb.byteSize) {
                    rb.byteSize = (memberEnd + 15) & ~std::size_t(15);
                }
            }

            result.uniformBlocks.push_back(std::move(rb));
            } // end for sortedUBOs
        } // end UBO block

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
                // Detect array members. Default-uniform arrays need this
                // so computeStageUniformLayout's arrayCount/arrayStride/
                // glElementBytes path expands GL-packed values into
                // std140-padded slots (e.g. `uniform uint g_uint_value[8]`
                // writes 32 bytes from the GL side but the MSL struct
                // lays it out as `uint4[8]` = 128 bytes). Mirrors the
                // named-UBO block above; missing from the push-constant
                // path caused the entire SSBO basic-atomic-* cluster to
                // read stale zeros via uniform[i] accesses after the
                // first element.
                if (!memberType.array.empty() && memberType.array[0] > 0) {
                    member.arraySize = memberType.array[0];
                }
                // Detect row_major decoration on matrix members (same
                // as the named-UBO path) so matrix-row iteration in
                // the packing loop uses the correct stride.
                if (memberType.columns > 1) {
                    member.isRowMajor = compiler.has_member_decoration(
                        type.self, mi, spv::DecorationRowMajor);
                }
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

        // Storage images (imageLoad/imageStore targets). Distinct from
        // sampled textures because the GL binding model differs: storage
        // images are bound via glBindImageTexture(unit, tex, …), not via
        // a sampler uniform that names a texture unit. Dispatch-time
        // binding resolution iterates this list separately and looks up
        // imageBindings[glBinding] rather than a uniform value.
        for (auto& img : resources.storage_images) {
            ShaderReflection::ResourceBinding rb;
            rb.glBinding = compiler.get_decoration(img.id, spv::DecorationBinding);
            rb.metalBinding = bindings.textureBase + rb.glBinding;
            rb.name = img.name;
            result.storageImages.push_back(std::move(rb));
        }

        // Shader-storage buffer objects (GL 4.3+). Metal side: SSBOs live
        // in buffer slots above UBOs. Sequential allocation in glBinding-
        // sorted order, matching spirvToMSL's MSLResourceBinding setup
        // — a shader with `layout(binding=7)` gets Metal slot
        // storageBufferBase+1 (2nd in sorted order) even though the GL
        // binding is 7, because Metal only has 31 buffer slots total.
        //
        // First: collect and sort SSBOs by glBinding to match spirvToMSL.
        std::vector<std::pair<std::uint32_t, spirv_cross::Resource*>> sortedSSBOs;
        auto ssboActive = compiler.get_active_interface_variables();
        for (auto& ssbo : resources.storage_buffers) {
            sortedSSBOs.emplace_back(
                compiler.get_decoration(ssbo.id, spv::DecorationBinding), &ssbo);
        }
        std::sort(sortedSSBOs.begin(), sortedSSBOs.end(),
                  [](auto& a, auto& b) { return a.first < b.first; });
        std::uint32_t nextSSBOSlot = bindings.storageBufferBase;
        for (auto& ssboEntry : sortedSSBOs) {
            auto& ssbo = *ssboEntry.second;
            ShaderReflection::ResourceBinding rb;
            rb.glBinding = ssboEntry.first;
            rb.metalBinding = nextSSBOSlot++;
            rb.active = (ssboActive.find(ssbo.id) != ssboActive.end());
            const auto& ssboType = compiler.get_type(ssbo.base_type_id);
            const std::string typeName = compiler.get_name(ssboType.self);
            rb.name = typeName.empty() ? ssbo.name : typeName;
            rb.hasInstanceName = (!typeName.empty() && ssbo.name != typeName);
            // Block-array dimension: `buffer B { ... } e[2];` → 2.
            // Parallel to the UBO reflection path above. Drives the
            // per-instance block-entry expansion in mergeStorageBlocks.
            {
                const auto& varType = compiler.get_type(ssbo.type_id);
                if (!varType.array.empty()) {
                    rb.blockArraySize = varType.array[0];
                }
            }
            // byteSize may be zero if the block contains a trailing
            // unbounded array (common for SSBOs) — callers must not
            // rely on it for draw-time binding size.
            try {
                rb.byteSize = compiler.get_declared_struct_size(ssboType);
            } catch (...) {
                rb.byteSize = 0;
            }
            // Recursively flatten struct members. GL 4.6 §7.3.1.1:
            // each scalar/vector/matrix leaf is a separate buffer
            // variable. For `buffer B { UU a[3]; mat4 b; }`, UU
            // containing `U a;` containing `vec4 b;`, the flat
            // output contains "a[0].a.b", "a[0].a.c", etc. alongside
            // "b". CTS `program_interface_query.ssb-types` exercises
            // the nested case.
            // `topLevelArraySize` plumbed through recursion so every
            // nested leaf reports the GL 4.6 §7.3.1
            // GL_TOP_LEVEL_ARRAY_SIZE of its outermost block member.
            // Default 1 (scalar top). Set when we enter an array-of-
            // struct at the TOP LEVEL only (isTopLevel=true) so that
            // deeper arrays don't overwrite it.
            std::function<void(const spirv_cross::SPIRType&, const std::string&, std::size_t, GLint, bool)>
                flattenSSBO = [&](const spirv_cross::SPIRType& parentType,
                                   const std::string& prefix,
                                   std::size_t baseOffset,
                                   GLint topLevelArraySize,
                                   bool isTopLevel) {
                for (std::uint32_t mi = 0; mi < parentType.member_types.size(); ++mi) {
                    const auto& memberType = compiler.get_type(parentType.member_types[mi]);
                    std::string memberName = compiler.get_member_name(parentType.self, mi);
                    std::size_t memberOffset = baseOffset;
                    try {
                        memberOffset += compiler.type_struct_member_offset(parentType, mi);
                    } catch (...) { /* unbounded-tail member — stays at baseOffset */ }

                    // Compute this member's effective top-level size:
                    // - at the top level, it's the member's own array
                    //   size (or 1 if not an array).
                    // - unbounded top-level arrays (`data[]`) report
                    //   1 per GL 4.6 §7.3.1 ("If the top-level member
                    //   is an unsized array, the value returned is 1").
                    // - below the top level, inherit the incoming value.
                    GLint effTopLevel = topLevelArraySize;
                    if (isTopLevel) {
                        if (memberType.array.empty()) {
                            effTopLevel = 1;
                        } else if (memberType.array[0] > 0) {
                            effTopLevel = static_cast<GLint>(memberType.array[0]);
                        } else {
                            effTopLevel = 1;  // unbounded top-level array
                        }
                    }

                    // Recurse into nested struct members.
                    if (memberType.basetype == spirv_cross::SPIRType::Struct &&
                        memberType.columns == 1 && memberType.array.empty()) {
                        std::string childPrefix = prefix.empty()
                            ? memberName : (prefix + "." + memberName);
                        flattenSSBO(memberType, childPrefix, memberOffset, effTopLevel, false);
                        continue;
                    }
                    // Recurse into arrays of structs.
                    if (memberType.basetype == spirv_cross::SPIRType::Struct &&
                        !memberType.array.empty() && memberType.array[0] > 0) {
                        std::size_t elemStride = 0;
                        try {
                            elemStride = compiler.get_declared_struct_member_size(parentType, mi)
                                / memberType.array[0];
                        } catch (...) {}
                        for (std::uint32_t ai = 0; ai < memberType.array[0]; ++ai) {
                            std::string elemPrefix = (prefix.empty() ? memberName : (prefix + "." + memberName))
                                + "[" + std::to_string(ai) + "]";
                            flattenSSBO(memberType, elemPrefix, memberOffset + ai * elemStride,
                                        effTopLevel, false);
                        }
                        continue;
                    }

                    ShaderReflection::UniformMember member;
                    member.name = prefix.empty()
                        ? memberName : (prefix + "." + memberName);
                    member.offset = memberOffset;
                    try {
                        member.size = compiler.get_declared_struct_member_size(parentType, mi);
                    } catch (...) {
                        member.size = 0;  // unbounded tail
                    }
                    member.type = spirvBaseTypeToGL(memberType);
                    member.topLevelArraySize = effTopLevel;
                    // Row-major decoration (matrix members only).
                    if (memberType.columns > 1) {
                        member.isRowMajor = compiler.has_member_decoration(
                            parentType.self, mi, spv::DecorationRowMajor);
                    }
                    if (!memberType.array.empty()) {
                        member.isArray = true;
                        member.arraySize = memberType.array[0];  // 0 for unbounded
                    }
                    if (compiler.has_member_decoration(parentType.self, mi,
                            spv::DecorationArrayStride)) {
                        member.arrayStride = static_cast<GLint>(
                            compiler.get_member_decoration(parentType.self, mi,
                                spv::DecorationArrayStride));
                    }
                    if (compiler.has_member_decoration(parentType.self, mi,
                            spv::DecorationMatrixStride)) {
                        member.matrixStride = static_cast<GLint>(
                            compiler.get_member_decoration(parentType.self, mi,
                                spv::DecorationMatrixStride));
                    }
                    rb.members.push_back(std::move(member));
                }
            };
            flattenSSBO(ssboType, "", 0, 1, true);
            result.storageBuffers.push_back(std::move(rb));
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

ComputeExecutionModes extractComputeModes(const std::uint32_t* spirv, std::size_t wordCount) {
    ComputeExecutionModes modes;
    if (!spirv || wordCount < 5) return modes;
    try {
        spirv_cross::Compiler compiler(spirv, wordCount);
        // Extract local_size_x/y/z from ExecutionModeLocalSize — the only
        // reliable source for compute-shader thread group dimensions on
        // the Metal side. glslang emits this decoration for every compute
        // shader; if it somehow isn't present, the (1,1,1) defaults
        // above keep dispatchThreadgroups from receiving a zero size.
        const auto& bitset = compiler.get_execution_mode_bitset();
        if (bitset.get(spv::ExecutionModeLocalSize)) {
            modes.localSizeX = std::max<std::uint32_t>(1,
                compiler.get_execution_mode_argument(spv::ExecutionModeLocalSize, 0));
            modes.localSizeY = std::max<std::uint32_t>(1,
                compiler.get_execution_mode_argument(spv::ExecutionModeLocalSize, 1));
            modes.localSizeZ = std::max<std::uint32_t>(1,
                compiler.get_execution_mode_argument(spv::ExecutionModeLocalSize, 2));
        }
    } catch (...) {}
    return modes;
}

TessellationModes extractTessellationModes(const std::uint32_t* spirv, std::size_t wordCount) {
    TessellationModes modes;
    if (!spirv || wordCount < 5) return modes;
    try {
        spirv_cross::Compiler compiler(spirv, wordCount);
        auto& bitset = compiler.get_execution_mode_bitset();

        // TCS: output vertices
        if (bitset.get(spv::ExecutionModeOutputVertices)) {
            modes.outputVertices = static_cast<int>(
                compiler.get_execution_mode_argument(spv::ExecutionModeOutputVertices));
        }

        // TES: primitive mode
        if (bitset.get(spv::ExecutionModeTriangles))
            modes.genMode = GL_TRIANGLES;
        else if (bitset.get(spv::ExecutionModeQuads))
            modes.genMode = GL_QUADS;
        else if (bitset.get(spv::ExecutionModeIsolines))
            modes.genMode = GL_ISOLINES;

        // TES: spacing
        if (bitset.get(spv::ExecutionModeSpacingEqual))
            modes.genSpacing = GL_EQUAL;
        else if (bitset.get(spv::ExecutionModeSpacingFractionalEven))
            modes.genSpacing = GL_FRACTIONAL_EVEN;
        else if (bitset.get(spv::ExecutionModeSpacingFractionalOdd))
            modes.genSpacing = GL_FRACTIONAL_ODD;

        // TES: vertex ordering
        if (bitset.get(spv::ExecutionModeVertexOrderCw))
            modes.genVertexOrder = GL_CW;
        else
            modes.genVertexOrder = GL_CCW;

        // TES: point mode
        modes.pointMode = bitset.get(spv::ExecutionModePointMode);
    } catch (...) {}
    return modes;
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

LinkedProgramSpirv ShaderTranslator::compileGLSLProgram(
    std::string_view vertexSource, std::string_view fragmentSource,
    int version, std::string* log) const {
    (void)vertexSource;
    (void)fragmentSource;
    (void)version;
    if (log != nullptr) {
        *log = "Cross-stage GLSL link is not enabled in the bootstrap build yet.";
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

TessellationModes extractTessellationModes(const std::uint32_t*, std::size_t) {
    return {};
}

ComputeExecutionModes extractComputeModes(const std::uint32_t*, std::size_t) {
    return {};
}

}  // namespace appgl

#endif  // APPGL_HAS_SHADER_COMPILER
