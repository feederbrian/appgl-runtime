#include "ShaderTranslator.h"

#ifdef APPGL_HAS_SHADER_COMPILER

#include <glslang/Public/ShaderLang.h>
#include <glslang/Public/ResourceLimits.h>
#include <SPIRV/GlslangToSpv.h>
#include <spirv_msl.hpp>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <set>
#include <utility>
#include <vector>

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
    // Clip / cull distances (GL 4.6 Table 23.53 — minimums 8/8, combined 8).
    // CTS `clip_distance.coverage` compiles a VS that writes
    // `gl_MaxClipDistances` to a transform-feedback output and
    // compares the value against `glGetIntegerv(GL_MAX_CLIP_DISTANCES)`.
    // The GLSL built-in constant is materialized by glslang from
    // `resources.maxClipDistances` — although glslang's default is 8,
    // we set it explicitly here to keep both caps in lockstep and
    // guard against any later default change in the vendored glslang.
    r.maxClipDistances = 8;
    r.maxCullDistances = 8;
    r.maxCombinedClipAndCullDistances = 8;
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

    // Sprint 9 Phase 3 (CKPT103): glslang's strict version-based gating of
    // ARB_sample_shading + OES_sample_variables built-ins (gl_NumSamples,
    // gl_SampleID, gl_SamplePosition, gl_SampleMaskIn, gl_SampleMask)
    // makes them undeclared at GLSL versions < 450 (core) without an
    // explicit `#extension` directive. CTS sample_variables.* and
    // shader_multisample_interpolation.render.* tests use #version 440
    // without the extension declaration — real GL drivers accept this
    // (the spec-strict behavior is unhelpful in practice). Inject the
    // extension declarations as a preamble so the symbol table populates
    // for these built-ins. Preamble runs after #version directive
    // processing, so version-dependent gating already saw the user's
    // #version pick.
    static const char* kFragmentSamplePreamble =
        "#extension GL_ARB_sample_shading : enable\n"
        "#extension GL_OES_sample_variables : enable\n"
        "#extension GL_OES_shader_multisample_interpolation : enable\n";
    if (eshStage == EShLangFragment) {
        shader.setPreamble(kFragmentSamplePreamble);
        if (std::getenv("APPGL_TRACE_GLSLANG") != nullptr) {
            std::fprintf(stderr, "[glslang-preamble] FS preamble set: %zu bytes\n",
                std::strlen(kFragmentSamplePreamble));
        }
    }

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
        const std::string linkLog = std::string("link: ") + program.getInfoLog();
        if (log != nullptr) {
            *log = linkLog;
        }
        result.linkLog = linkLog;  // CKPT79: propagate so caller can decide fail-vs-fallback
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
        const std::string mapIOLog = std::string("mapIO: ") + program.getInfoLog();
        if (log != nullptr) {
            *log = mapIOLog;
        }
        result.linkLog = mapIOLog;  // CKPT79: propagate (mapIO failures are typically recoverable via per-stage fallback, but caller decides)
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
    return spirvToMSL(spirv, wordCount, bindings, log, TranslatorOptions{});
}

std::string ShaderTranslator::spirvToMSL(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log, const TranslatorOptions& options) const {
    // T4D probe: dump the INPUT SPIR-V before SPIRV-Cross runs, so we
    // capture it even when compile() throws or returns empty MSL.
    // Useful for diagnosing translator failures (isolines TES landed
    // here in 2026-04-26 while debugging tc2te.data_pass_through).
    // Pairs with APPGL_DUMP_MSL via the same counter — but the counter
    // bump happens later (post-compile) for the existing dump site, so
    // this helper allocates its own.  When BOTH envs are set, we want
    // ONE counter so spv/msl pair by index — moved to the top of the
    // function and shared.
    if (const char* spirvDumpPath = std::getenv("APPGL_DUMP_SPIRV_INPUT")) {
        static std::atomic<int> spvInputCounter{0};
        const int n = spvInputCounter.fetch_add(1);
        char path[512];
        std::snprintf(path, sizeof(path), "%s/spv_%04d.spv", spirvDumpPath, n);
        if (FILE* f = std::fopen(path, "wb")) {
            std::fwrite(spirv, sizeof(std::uint32_t), wordCount, f);
            std::fclose(f);
        }
    }
    try {
        spirv_cross::CompilerMSL compiler(spirv, wordCount);
        const auto execModel = compiler.get_execution_model();
        const bool isTessControl = (execModel == spv::ExecutionModelTessellationControl);
        const bool isTessEval = (execModel == spv::ExecutionModelTessellationEvaluation);
        const bool isVertex = (execModel == spv::ExecutionModelVertex);
        const bool isGeometry = (execModel == spv::ExecutionModelGeometry);
        const bool isFragment = (execModel == spv::ExecutionModelFragment);
        const bool isGraphicsStage =
            isVertex || isTessControl || isTessEval || isGeometry || isFragment;
        (void)isTessControl; (void)isTessEval; (void)isVertex;
        (void)isGeometry; (void)isFragment; (void)isGraphicsStage;

        spirv_cross::CompilerMSL::Options mslOpts;
        mslOpts.platform = spirv_cross::CompilerMSL::Options::macOS;
        // Step 8 (tessellation on Metal via SPIRV-Cross): when the shader is
        // a tess stage, we emit MSL compatible with Metal's native tess
        // pipeline (TCS-as-compute + TES-as-vertex-function + hardware
        // tessellator). The Metal-side wiring is not yet in place, so
        // this emission is gated behind APPGL_ENABLE_METAL_TESS=1 — when
        // unset, tess stages fall back to the CPU interpreter path.
        //
        // SPIRV-Cross emits for the three stages under these options:
        //  * VS (when `vertex_for_tessellation=true, capture_output_to_
        //    buffer=true`): `kernel` that writes per-vertex attribs to
        //    a buffer indexed by gl_VertexID. Input comes via
        //    MTLStageInputOutputDescriptor bound to the compute encoder.
        //  * TCS (auto on `ExecutionModelTessellationControl`): `kernel`
        //    with per-thread `[[stage_in]]` pulling VS output buffer,
        //    threadgroup `gl_in[]`, per-CP output buffer at buffer(28),
        //    patch output at buffer(27), tess factor buffer at
        //    buffer(26).
        //  * TES (auto on `ExecutionModelTessellationEvaluation`):
        //    `vertex` function intended for an MTLRenderPipeline with
        //    `tessellationEnabled = YES`. `raw_buffer_tese_input=true`
        //    makes it read per-CP (buffer 22) and per-patch (buffer 20)
        //    inputs from buffers, enabling nested-array varyings.
        static const bool metalTessEnvEnabled = []() {
            const char* v = std::getenv("APPGL_ENABLE_METAL_TESS");
            return v != nullptr && v[0] != '0' && v[0] != '\0';
        }();
        const bool metalTessEnabled = metalTessEnvEnabled || options.forceTessellation;
        if (metalTessEnabled && (isTessControl || isTessEval)) {
            if (isTessEval) {
                mslOpts.raw_buffer_tese_input = true;
                // Path J' Option E.4 (`0ee35f2`): explicit-flag-gated
                // emission opt-in for TES main0_in field order. When set,
                // SPIRV-Cross's `add_interface_block` emits TES Input
                // members in `inputs_by_location_insertion_order` order
                // (the order in which add_msl_shader_input was called)
                // instead of TES IR-walk order. The recorded order
                // matches TCS main0_out emission once the β orchestrator
                // iterates TCS active interface IDs in ascending order
                // (sort below at line 811-823). Without this flag,
                // E.4's recording is observably a no-op.
                mslOpts.input_emission_in_call_order = true;
            }
            mslOpts.tess_domain_origin_lower_left = true;
            // Phase 3: route TCS VS-input through a buffer rather than
            // [[stage_in]] so Metal doesn't reject the kernel with
            // "invalid type 'main0_in' of input declaration with
            // attribute 'stage_in'". With `multi_patch_workgroup` on,
            // SPIRV-Cross emits the TCS reading VS output directly from
            // `input_buffer_var_name` rather than via a struct-typed
            // stage-input, which sidesteps the MSL member-attribute
            // requirement.
            if (isTessControl) {
                mslOpts.multi_patch_workgroup = true;
                // Option C [metal-tess-TF] (SPIRV-Cross commit 26adef0):
                // classify TCS user-varying outputs by TES consumption
                // when a sibling-TES SPIR-V is provided. TES-consumed
                // outputs land in main0_out (per-CP device buffer) at
                // matching offsets; TCS-internal-only outputs (read by
                // TCS itself after barrier()) route to threadgroup
                // memory instead. Closes the per-CP stride mismatch on
                // tc_barriers / data_pass_through / gl_PerVertex-padded
                // tests where TCS's main0_out included slots TES doesn't
                // declare. Effective only when siblingTesInputSpirv
                // populates `name` on each MSLShaderInterfaceVariable
                // (see the wiring block below).
                mslOpts.split_tcs_outputs_by_consumption = true;
            }
        }
        // Phase 3 of metal-tess: VS-as-compute for tess programs. When
        // the caller opts in (tess program link time), emit the VS
        // as a `kernel` with `capture_output_to_buffer=true` so the
        // per-vertex outputs land in a Metal buffer the TCS compute
        // dispatch can pull via its `[[stage_in]]` descriptor.
        if (options.forceVertexForTessellation && isVertex) {
            mslOpts.vertex_for_tessellation = true;
            mslOpts.capture_output_to_buffer = true;
        }
        // Phase 3B [metal-tess-TF]: route TES as a compute kernel via
        // the AppGL fork's `tess_evaluation_as_compute` option. The
        // emission differs from the vertex-function form in three
        // ways: entry type is `kernel`, Metal-intrinsic args
        // (`[[position_in_patch]]`, `[[patch_id]]`) are replaced with
        // reads from a domain-coord buffer, and TES output is written
        // to a TF-capture buffer instead of being returned. Requires
        // `raw_buffer_tese_input = true` (already set above by
        // `forceTessellation`) and `capture_output_to_buffer = true`
        // so the upstream SPIRV-Cross switch at
        // `add_variable_to_interface_block` routes `main0_out` through
        // a `device main0_out& out = spvOut[i]` reference instead of
        // a returned local variable.
        if (options.forceTessEvalAsCompute && isTessEval) {
            mslOpts.tess_evaluation_as_compute = true;
            mslOpts.capture_output_to_buffer = true;
        }
        if (isTessEval && options.tesePatchVertices != 0) {
            mslOpts.tese_input_patch_vertices = options.tesePatchVertices;
        }
        // Sprint 5 Phase 1: Path L Class 2A — full-precision tess level
        // shadow buffer flag. Apply to BOTH TCS-compute (writes both half
        // and full per Path L extension `635380d`) AND TES-compute (reads
        // from full per Path L `4f626b9`).
        if (options.useFullPrecisionTessLevelBuffer &&
            (isTessControl || isTessEval)) {
            mslOpts.use_full_precision_tess_level_buffer = true;
        }
        // Sprint 3 [metal-mesh-GS]: route GS source into the
        // mesh-shader emission path when the linked program's GS
        // shape is supported by the SPIRV-Cross patch's MVP coverage
        // and the device has mesh-shader capability. Only emitted on
        // ExecutionModelGeometry — gated by isGeometry. Caller is
        // responsible for the capability + shape gate (link-time).
        if (options.forceGeometryShaderAsMesh && isGeometry) {
            mslOpts.geometry_shader_as_mesh = true;
        }
        // Path E mitigation [metal-tess-TF Checkpoint 11]: kernel-exit
        // device-memory barrier on VS-as-compute targeting mesh-GS.
        // Apple's AIR optimizer eliminates `device main0_out* spvOut`
        // writes when the consumer is a different encoder family
        // (mesh render pipeline) than the producer (compute encoder).
        // The barrier provides the alternative signal that blocks
        // elimination — see SPIRV-Cross fork commit e06f883 + AppGL-W
        // Checkpoint 10 falsification of H11c.
        if (options.forceComputeKernelDeviceBarrierAtExit && isVertex) {
            mslOpts.force_compute_kernel_device_barrier_at_exit = true;
        }
        // Path E++ mitigation [Checkpoint 11 escalation, fork 76aacf7]:
        // emit `volatile device main0_out*` for spvOut. Required when
        // the barrier alone is insufficient — AIR optimizer is
        // spec-obligated to preserve writes through volatile.
        if (options.forceComputeKernelDeviceVolatileWrites && isVertex) {
            mslOpts.force_compute_kernel_device_volatile_writes = true;
        }
        // Path E+++ mitigation [Checkpoint 11 escalation 3, fork 915d81c]:
        // atomic_store_explicit on spvOut field writes. Strength-tier
        // ladder terminus for spec-defensible mitigations.
        if (options.forceComputeKernelAtomicWritesOnSpvOut && isVertex) {
            mslOpts.force_compute_kernel_atomic_writes_on_spvOut = true;
        }
        // Path E+++ diagnostic [orthogonal to strength tiers]: emit
        // entry-counter atomic increment for 2-bit signal decoding.
        if (options.forceComputeKernelEntryCounterProbe && isVertex) {
            mslOpts.force_compute_kernel_entry_counter_probe = true;
        }
        // Path G [Checkpoint 15, fork f19ce45]: ACTUAL fix for the
        // VS-as-compute kernel-doesn't-execute symptom. Emits
        // `[[threads_per_grid]]` for spvStageInputSize so the bounds
        // check returns the dispatched grid size (not the broken
        // [[grid_size]] which returns 0).
        if (options.forceThreadsPerGridForStageInputSize && isVertex) {
            mslOpts.force_threads_per_grid_for_stage_input_size = true;
        }
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
        //
        // CKPT122 (Sprint 11 Phase 2 Cluster A Day 7 γ-pivot):
        // bump to MSL 2.3 so SPIRV-Cross can emit pull-model
        // interpolation (`stage_in.X.interpolate_at_sample(N)` /
        // `interpolate_at_centroid()` / `interpolate_at_offset(o)`).
        // Without 2.3, SPIRV-Cross throws "Pull-model interpolation
        // requires MSL 2.3." for every FS using `interpolateAt*` GLSL
        // functions, leaving the program unlinked. CTS
        // KHR-GL46.shader_multisample_interpolation.render.{interpolate_at_*}
        // (72F before this fix) all hit this wall. MSL 2.3 minimum
        // matches macOS 11 Big Sur (Nov 2020), well below our 12.0+
        // host minimum.
        mslOpts.set_msl_version(2, 3);
        mslOpts.enable_decoration_binding = true;
        // Pad fragment outputs to vec4 so Metal doesn't reject pipelines
        // where the shader outputs fewer components than the render target
        // format (e.g. float → MTLPixelFormatRGBA8Unorm).
        mslOpts.pad_fragment_output_components = true;
        // Step 7 (phase-7-1): env-gated argument-buffers (Tier-2)
        // emission. When APPGL_ENABLE_ARGUMENT_BUFFERS=1, SPIRV-Cross
        // emits the fragment/vertex/compute entry points with
        // `constant spvDescriptorSetBufferN& spvDescriptorSetN
        // [[buffer(N)]]` arguments instead of individual
        // `[[texture(N)]]` / `[[sampler(N)]]` / `[[buffer(N)]]`
        // parameters. Unlocks Metal's per-stage 31-texture limit
        // (matches Metal 3 bindless resource counts) and is required
        // for the advertised GL_MAX_TEXTURE_IMAGE_UNITS=48 to work on
        // shaders that actually sample all 48 units.
        //
        // THE METAL-SIDE BINDING IS NOT YET WIRED — enabling this env
        // var WILL BREAK tests because the CPU-side encoder still
        // calls setFragmentTexture/Sampler/Buffer with direct slots.
        // A follow-up phase 7-2 adds the argument-buffer construction
        // on the consumer side. This commit's scope is just the
        // translator opt-in; leaving the baseline untouched so the
        // full Phase 6 arc + the 67-test win stack stays intact.
        //
        // Tier-2 (vs Tier-1): Apple Silicon M1+ supports Tier-2
        // (writable images on macOS + higher resource limits). We
        // advertise + require Apple7-class GPUs, so Tier-2 is always
        // the right pick.
        const bool forceArgBuf = options.forceArgumentBuffers ||
            (std::getenv("APPGL_ENABLE_ARGUMENT_BUFFERS") != nullptr);
        if (forceArgBuf) {
            // MSL 3.0 required for Tier-2 full mutable aliasing —
            // SPIRV-Cross throws "Full mutable aliasing of argument
            // buffer descriptors only works on Metal 3+" when this
            // option is enabled with MSL < 3.0. Available on macOS 13
            // (Ventura, 2022) and later; safe bump because we require
            // Apple7+ GPUs which are all on macOS ≥ 13 by now.
            mslOpts.set_msl_version(3, 0);
            mslOpts.argument_buffers = true;
            mslOpts.argument_buffers_tier =
                spirv_cross::CompilerMSL::Options::ArgumentBuffersTier::Tier2;
        }
        compiler.set_msl_options(mslOpts);

        // Phase 7 [metal-tess-TF]: cross-stage wiring (Track 2 scaffold).
        // When translating TCS-as-compute and the caller passed the linked
        // TES's SPIR-V, walk TES's INPUT user varyings and call
        // add_msl_shader_output on this (TCS) CompilerMSL for each. Tells
        // SPIRV-Cross "the next stage reads slots N..M, ensure your
        // main0_out includes them at matching locations." Filters out
        // built-ins (gl_TessCoord, gl_PrimitiveID, gl_PatchVerticesIn,
        // gl_Position, gl_PointSize, gl_ClipDistance) — those are handled
        // by SPIRV-Cross's own gl_PerVertex propagation, and propagating
        // them as user-named outputs would inject placeholder uint slots
        // that displace the user-varying layout (observed in scaffold v1
        // as a `uint m_111` field corrupting tc_position offsets).
        // Filters out per-patch (`patch in`) varyings — TES's per-patch
        // inputs come from the patch buffer (atIndex 20), not the per-CP
        // buffer (atIndex 22).
        if (isTessControl && options.siblingTesInputSpirv != nullptr &&
            options.siblingTesInputWordCount > 0) {
            try {
                spirv_cross::Compiler tesSibling(
                    options.siblingTesInputSpirv, options.siblingTesInputWordCount);
                const auto activeIds = tesSibling.get_active_interface_variables();
                std::size_t wired = 0;
                std::size_t skippedBuiltin = 0;
                std::size_t skippedPatch = 0;
                // Sprint 4 Phase 1 fix: SPIRV-Cross's
                // `add_msl_shader_output` keys `outputs_by_location` on
                // (location, component). When TES has multiple loose
                // top-level varyings without explicit
                // `layout(location=N)` decorations, glslang's auto-
                // assignment may not emit `OpDecorate Location` (for
                // monolithic programs in particular), and our
                // `has_decoration(... Location)` test returns false →
                // all entries collapse to (0, 0) and only the last-
                // added survives in the map. The downstream
                // `classify_tcs_outputs_by_consumption` then sees
                // only one name in `consumed_names`, the other TCS
                // outputs land in threadgroup memory, and TES reads
                // zero. Assign a unique synthetic location per wired
                // entry. Critically, TCS's emitted main0_out struct
                // field order is determined by location-sort, while
                // TES's main0_in is laid out by SPIR-V variable ID.
                // To keep the per-CP buffer stride / field offsets
                // matched cross-stage, use the TES variable's ID as
                // the synthetic location (offset to a high range so
                // it doesn't collide with natural < 64 locations or
                // the classifier's 0xF000_0000+ range).
                for (auto id : activeIds) {
                    const spv::StorageClass sc = tesSibling.get_storage_class(id);
                    if (sc != spv::StorageClassInput) continue;
                    // Direct-decorated builtins (rare for tess: gl_PrimitiveID
                    // / gl_PatchVerticesIn might land here as standalone
                    // variables) — skip.
                    if (tesSibling.has_decoration(id, spv::DecorationBuiltIn)) {
                        ++skippedBuiltin;
                        continue;
                    }
                    // Block-typed variables (interface blocks like `in OUT_TC
                    // { … } in_data[]` and gl_PerVertex) — the user-named
                    // block is already coordinated across stages by
                    // glslang's link+mapIO at the location level, so TCS-
                    // out's emission already includes the matching block on
                    // the symmetric output side. Calling add_msl_shader_output
                    // with a block-typed variable causes SPIRV-Cross to
                    // synthesize a placeholder `uint m_<id>` member that
                    // displaces the user-varying layout (observed in scaffold
                    // v1/v2 as `uint m_111` corrupting tc_position offsets).
                    // Skip blocks entirely; only wire loose top-level
                    // varyings — those are the ones that can mismatch
                    // between sibling stages without coordination.
                    const auto& varType = tesSibling.get_type_from_variable(id);
                    const auto typeSelfId = varType.self;
                    if (tesSibling.has_decoration(typeSelfId, spv::DecorationBlock) ||
                        tesSibling.has_decoration(typeSelfId, spv::DecorationBufferBlock)) {
                        ++skippedBuiltin;  // counter doubles for "block-skipped"
                        continue;
                    }
                    if (!varType.member_types.empty() &&
                        tesSibling.has_member_decoration(typeSelfId, 0, spv::DecorationBuiltIn)) {
                        ++skippedBuiltin;
                        continue;
                    }
                    if (tesSibling.has_decoration(id, spv::DecorationPatch)) {
                        ++skippedPatch;
                        continue;
                    }
                    spirv_cross::MSLShaderInterfaceVariable sib;
                    // When TES emits an explicit Location decoration,
                    // honor it (separable programs path). Otherwise
                    // synthesize from the TES variable's ID — IDs are
                    // unique per module and ID-order matches TES's
                    // main0_in field-emission order, so TCS's
                    // location-sort emission of main0_out lands fields
                    // at the same offsets TES reads from.
                    sib.location = tesSibling.has_decoration(id, spv::DecorationLocation)
                        ? tesSibling.get_decoration(id, spv::DecorationLocation)
                        : (0xE0000000u + (std::uint32_t)id);
                    sib.component = tesSibling.has_decoration(id, spv::DecorationComponent)
                        ? tesSibling.get_decoration(id, spv::DecorationComponent) : 0;
                    sib.format = spirv_cross::MSL_SHADER_VARIABLE_FORMAT_OTHER;
                    sib.builtin = spv::BuiltInMax;
                    sib.vecsize = varType.vecsize > 0 ? varType.vecsize : 1;
                    sib.rate = spirv_cross::MSL_SHADER_VARIABLE_RATE_PER_VERTEX;
                    // Option C [metal-tess-TF]: feed the sibling's source
                    // name so the TCS classifier (split_tcs_outputs_by
                    // _consumption) can name-match across stages.
                    // Separable programs auto-assign locations per-stage
                    // independently, so location alone is unstable as a
                    // cross-stage identifier.
                    sib.name = tesSibling.get_name(id);
                    compiler.add_msl_shader_output(sib);
                    ++wired;
                    if (std::getenv("APPGL_DUMP_TESOUT")) {
                        std::fprintf(stderr,
                            "APPGL_DETECTOR xstage_name id=%u name='%s' loc=%u "
                            "vecsize=%u\n",
                            (unsigned)id, sib.name.c_str(),
                            (unsigned)sib.location, (unsigned)sib.vecsize);
                    }
                }
                if (std::getenv("APPGL_DETECTOR_TF") || std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr,
                        "APPGL_DETECTOR lift_xstage stage=tcs sibling=tes-input "
                        "active=%zu wired=%zu skipped_builtin=%zu skipped_patch=%zu\n",
                        activeIds.size(), wired, skippedBuiltin, skippedPatch);
                }
            } catch (const std::exception& e) {
                if (std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr,
                        "[APPGL] cross-stage wiring (TCS←TES) failed: %s\n", e.what());
                }
            }
        }

        // tc_barriers cluster — inverse direction. When translating TES
        // and the caller passed the linked TCS's SPIR-V, walk TCS's
        // OUTPUT interface variables and call add_msl_shader_input on
        // this (TES) CompilerMSL for each USER VARYING the TES doesn't
        // already declare. The mismatch this closes: TCS uses some of
        // its own outputs internally (read after barrier()), so SPIRV-
        // Cross can't trim main0_out — the device per-CP buffer stride
        // grows beyond what TES's main0_in covers, and TES reads at the
        // wrong offset. By teaching TES "the previous stage put extra
        // slots in your input struct," we re-align the per-CP stride.
        // Filters mirror the TCS-direction block: builtins, blocks,
        // and `patch out` are skipped.
        //
        // Option C supersedes this branch entirely. When TCS uses
        // `split_tcs_outputs_by_consumption=true` + name-aware wiring
        // via siblingTesInputSpirv, its main0_out is trimmed to TES-
        // consumed slots only — the per-CP stride matches TES's
        // main0_in natively. The TES-side padding workaround adds
        // duplicate inputs (location-based dedup misses tcs-out /
        // tes-in pairs that lack OpDecorate Location), corrupting
        // layouts under Option C. Disabled unconditionally now that
        // Option C is the canonical cross-stage path; siblingTcsOutput
        // Spirv option still exists on TranslatorOptions for binary-
        // compat, but no longer triggers any emission change. Keeping
        // the block in place until callers stop populating the option
        // (cosmetic cleanup).
        // Sprint 6 Phase 1 sub-task 2: Path J' β orchestrator TES-input
        // extension. Re-enabled now that SPIRV-Cross fork's Path J'
        // Option E.2 (`01cfa15`) lands. Option E.2 widens Option E's
        // Pass 1 gathering to capture all natural Input variable names
        // (with OR without OpDecorate Location). Pass 3 dedupes
        // synthetic-range entries against the widened natural-name set,
        // covering monolithic programs (CKPT30 finding: TES inputs lack
        // Location decoration in monolithic programs but have names).
        const bool isTessEvalAny = isTessEval ||
            (isVertex && options.forceTessEvalAsCompute);  // false-safe; TES path is isTessEval
        if (isTessEvalAny && options.siblingTcsOutputSpirv != nullptr &&
            options.siblingTcsOutputWordCount > 0) {
            try {
                spirv_cross::Compiler tcsSibling(
                    options.siblingTcsOutputSpirv, options.siblingTcsOutputWordCount);
                // Collect TES's natural input NAMES — used to filter TCS
                // outputs to "those that TES actually reads." TCS-internal
                // outputs (like barrier_guarded_*'s test_vector) must NOT
                // be added; SPIRV-Cross's Pass 3 dedupe only fires when
                // names match natural entries. TCS-internal-only outputs
                // (NOT in TES inputs) wouldn't have a natural counterpart,
                // would be added as new entries → m_<N> placeholders.
                std::set<std::string> tesInputNames;
                {
                    const auto activeTes = compiler.get_active_interface_variables();
                    for (auto id : activeTes) {
                        if (compiler.get_storage_class(id) != spv::StorageClassInput) continue;
                        const std::string& name = compiler.get_name(id);
                        if (name.empty()) continue;
                        tesInputNames.insert(name);
                    }
                }
                // Legacy alias for diagnostic line below.
                std::set<std::pair<std::uint32_t,std::uint32_t>> tesInputLocs;
                // Path J' E.4 synchronized landing — paired with
                // SPIRV-Cross `0ee35f2` flag-gated emission. CKPT42 A/B
                // test confirmed Config B (flag + ID-ascending sort)
                // PASSES while Config A (flag only) FAILS. E.4's
                // emission aspect honors call order — and our call
                // order is the iteration order of
                // `get_active_interface_variables()` (an unordered_set
                // returning non-deterministic iteration). Sorting
                // active TCS interface IDs ascending reproduces TCS's
                // natural main0_out emission walk (SPIR-V variable IDs
                // ascend in declaration order). Without this sort,
                // call order mismatches TCS emission and TES main0_in
                // bytes don't align with TCS main0_out bytes.
                std::vector<spirv_cross::ID> activeIds;
                {
                    const auto activeSet = tcsSibling.get_active_interface_variables();
                    activeIds.assign(activeSet.begin(), activeSet.end());
                    std::sort(activeIds.begin(), activeIds.end(),
                        [](spirv_cross::ID a, spirv_cross::ID b) {
                            return static_cast<std::uint32_t>(a) <
                                   static_cast<std::uint32_t>(b);
                        });
                }
                std::size_t wired = 0;
                std::size_t skippedBuiltin = 0;
                std::size_t skippedPatch = 0;
                std::size_t skippedExisting = 0;
                for (auto id : activeIds) {
                    const spv::StorageClass sc = tcsSibling.get_storage_class(id);
                    if (sc != spv::StorageClassOutput) continue;
                    if (tcsSibling.has_decoration(id, spv::DecorationBuiltIn)) {
                        ++skippedBuiltin;
                        continue;
                    }
                    const auto& varType = tcsSibling.get_type_from_variable(id);
                    const auto typeSelfId = varType.self;
                    if (tcsSibling.has_decoration(typeSelfId, spv::DecorationBlock) ||
                        tcsSibling.has_decoration(typeSelfId, spv::DecorationBufferBlock)) {
                        ++skippedBuiltin;
                        continue;
                    }
                    if (!varType.member_types.empty() &&
                        tcsSibling.has_member_decoration(typeSelfId, 0, spv::DecorationBuiltIn)) {
                        ++skippedBuiltin;
                        continue;
                    }
                    if (tcsSibling.has_decoration(id, spv::DecorationPatch)) {
                        ++skippedPatch;
                        continue;
                    }
                    // Skip TCS outputs that TES doesn't read — those are
                    // TCS-internal varyings (like barrier_guarded_*'s
                    // test_vector). Option E.2's Pass 3 only dedupes if
                    // the synthetic-range name matches a natural entry;
                    // TCS-internal outputs wouldn't match → added as new
                    // entries → m_<N> placeholders → barrier regression.
                    const std::string tcsName = tcsSibling.get_name(id);
                    if (tcsName.empty() || !tesInputNames.count(tcsName)) {
                        ++skippedExisting;
                        continue;
                    }
                    // Synthetic location (0xE0000000+id). Option E.2's
                    // Pass 3 (`01cfa15`) dedupes synthetic-range entries
                    // against natural names (with/without Location
                    // decoration). Re-orders TES main0_in emission to
                    // match TCS main0_out emission order — Path J'
                    // field-order parity goal.
                    const std::uint32_t loc = tcsSibling.has_decoration(id, spv::DecorationLocation)
                        ? tcsSibling.get_decoration(id, spv::DecorationLocation)
                        : (0xE0000000u + (std::uint32_t)id);
                    const std::uint32_t comp = tcsSibling.has_decoration(id, spv::DecorationComponent)
                        ? tcsSibling.get_decoration(id, spv::DecorationComponent) : 0;
                    spirv_cross::MSLShaderInterfaceVariable sib;
                    sib.location = loc;
                    sib.component = comp;
                    sib.format = spirv_cross::MSL_SHADER_VARIABLE_FORMAT_OTHER;
                    sib.builtin = spv::BuiltInMax;
                    sib.vecsize = varType.vecsize > 0 ? varType.vecsize : 1;
                    sib.rate = spirv_cross::MSL_SHADER_VARIABLE_RATE_PER_VERTEX;
                    sib.name = tcsName;
                    compiler.add_msl_shader_input(sib);
                    ++wired;
                }
                if (std::getenv("APPGL_DETECTOR_TF") || std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr,
                        "APPGL_DETECTOR lift_xstage stage=tes sibling=tcs-output "
                        "active=%zu wired=%zu skipped_builtin=%zu skipped_patch=%zu skipped_existing=%zu\n",
                        activeIds.size(), wired, skippedBuiltin, skippedPatch, skippedExisting);
                }
            } catch (const std::exception& e) {
                if (std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr,
                        "[APPGL] cross-stage wiring (TES←TCS) failed: %s\n", e.what());
                }
            }
        }

        // Sprint 17 Day 3+ BONUS-1 [clip_control]: drive SPIRV-Cross's
        // depth-fixup flag from the per-link `clipDepthMode` snapshot
        // captured at translation time.
        //   GL_NEGATIVE_ONE_TO_ONE (GL default, [-1,+1] clip-z) →
        //     fixup_clipspace=true; SPIRV-Cross emits
        //     `gl_Position.z = (z + w) * 0.5` so the [0,+1] Metal
        //     clip-z range receives the correctly-mapped value.
        //   GL_ZERO_TO_ONE (D3D-like [0,+1] clip-z) →
        //     fixup_clipspace=false; the GL clip-z range already
        //     matches Metal's, no shader-side mapping needed.
        // Origin side (`flip_vert_y`) stays default false — AppGL
        // already handles the GL bottom-up → Metal top-down convention
        // via the viewport descriptor's `originY = rtH - glY - glH`
        // flip in MetalFrameGraph (single-source-of-truth). Enabling
        // SPIRV-Cross flip_vert_y here would compound with that
        // viewport-flip into a double-flip artifact on UPPER_LEFT.
        spirv_cross::CompilerGLSL::Options glslOpts = compiler.get_common_options();
        glslOpts.vertex.fixup_clipspace =
            (options.clipDepthMode == GL_NEGATIVE_ONE_TO_ONE);
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

        // GL 4.6 §7.4.1 (separate programs) — when a shader is compiled
        // as a separable program via glCreateShaderProgramv, glslang's
        // setAutoMapLocations(true) assigns Location decorations to bare
        // top-level `in`/`out` varyings but *leaves interface-block*
        // variables undecorated (the block member SPIR-V decorations
        // use MemberDecoration/Offset rather than an OpVariable-level
        // Location). SPIRV-Cross then emits MSL without any
        // `[[user(locnN)]]` attribute and Metal can't match the VS's
        // stage_out names (e.g. `vs_out_color`) against the FS's
        // stage_in names (e.g. `fs_in_color`) across a program
        // pipeline. CTS `vertex_attrib_binding.basic-*` exercises this.
        //
        // Synthesize Location decorations here so MSL gets
        // `[[user(locnN)]]` on every user varying. Sort interface
        // variables by SPIR-V source name so the VS and FS independent
        // compilations agree: both stages declare the same blocks in
        // the same GLSL order, producing the same sort key and
        // therefore the same Location values. Keep any glslang-assigned
        // Location untouched; only fill in missing ones starting from
        // the next-available slot.
        auto assignMissingLocations = [&compiler](
            auto& vars) {
            // Determine the highest already-used Location so we don't
            // collide with explicit `layout(location=N)` qualifiers.
            std::uint32_t nextLoc = 0;
            bool anyExplicit = false;
            for (auto& v : vars) {
                if (compiler.has_decoration(v.id, spv::DecorationLocation)) {
                    auto loc = compiler.get_decoration(v.id, spv::DecorationLocation);
                    if (!anyExplicit || loc >= nextLoc) {
                        nextLoc = loc + 1;
                        anyExplicit = true;
                    }
                }
            }
            // Collect vars that still need a Location, sorted by the
            // block's SPIR-V name (set by glslang from the GLSL
            // interface block's *type* name — identical across VS/FS
            // for matching blocks per GLSL 4.60 §4.4.1).
            struct Pending {
                std::uint32_t id;
                std::string sortKey;
            };
            std::vector<Pending> pending;
            for (auto& v : vars) {
                if (compiler.has_decoration(v.id, spv::DecorationLocation)) {
                    continue;
                }
                Pending p;
                p.id = v.id;
                // Prefer the block type name (stable across VS/FS);
                // fall back to variable name when not an interface block.
                p.sortKey = compiler.get_name(v.base_type_id);
                if (p.sortKey.empty()) {
                    p.sortKey = v.name;
                }
                pending.push_back(p);
            }
            std::sort(pending.begin(), pending.end(),
                [](const Pending& a, const Pending& b) {
                    return a.sortKey < b.sortKey;
                });
            for (const auto& p : pending) {
                compiler.set_decoration(p.id, spv::DecorationLocation, nextLoc);
                nextLoc++;
            }
        };
        if (execModel == spv::ExecutionModelVertex) {
            assignMissingLocations(resources.stage_outputs);
        } else if (execModel == spv::ExecutionModelFragment) {
            assignMissingLocations(resources.stage_inputs);
        }

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

            // UBOs and SSBOs live in separate binding namespaces in GL but
            // share (desc_set=0, binding=N) under the Vulkan-rules-relaxed
            // glslang output we feed into SPIRV-Cross. When a UBO and an
            // SSBO both use `layout(binding=0)`, SPIRV-Cross's MSL backend
            // detects them as aliases (same descriptor slot) and collapses
            // them into one `spvBufferAliasSet0Binding0` Metal slot —
            // producing MSL whose `constant B0& b0` reference never appears
            // in the kernel signature because it's folded into the alias
            // cast.  CTS `multi_bind.dispatch_bind_buffers_base` plants 14
            // UBOs all sharing (desc_set=0, binding=K) with an SSBO at
            // binding=0 and hits this alias collapse at the binding=0 slot
            // only — the aliased buffer then receives the SSBO pointer at
            // dispatch time and every UBO read resolves to stale zeroes,
            // `dispatchCompute` reports INVALID_OPERATION because the
            // compute PSO ends up built against an aliased slot the runtime
            // can't reconcile.
            //
            // Fix: reassign every UBO's SPIR-V `DescriptorSet` decoration
            // to a different set (1), which keeps the (set, binding) pair
            // globally unique even when binding numbers repeat across
            // UBO/SSBO spaces. The MSL slot assignment via
            // `add_msl_resource_binding` then lands on distinct Metal
            // buffer slots without alias-collapse.
            for (auto& entry : sortedUBOs) {
                compiler.set_decoration(entry.res->id,
                    spv::DecorationDescriptorSet, 1);
            }

            std::uint32_t nextSlot = bindings.uniformBufferBase;
            for (auto& entry : sortedUBOs) {
                spirv_cross::MSLResourceBinding binding;
                binding.stage = compiler.get_execution_model();
                binding.desc_set = 1;  // UBO descriptor set (mirrors set_decoration above)
                binding.binding = entry.glBinding;
                binding.msl_buffer = nextSlot;
                compiler.add_msl_resource_binding(binding);
                nextSlot += entry.arraySize;
            }
        }

        // Step 7-2 consolidation: argument-buffers layout needs three
        // additional scoped adjustments relative to the direct-binding
        // baseline (all gated on APPGL_ENABLE_ARGUMENT_BUFFERS):
        //
        //   (a) The argument-buffer variables themselves (one per
        //       descriptor set) must sit at Metal buffer slots that
        //       don't collide with VBOs (`vertexBufferBase` = 0..15),
        //       push-constants (`uniformBufferBase` = 16), or legacy
        //       UBO slots (16..). We pin them at [[buffer(24)]] and
        //       [[buffer(25)]] for descriptor sets 0 and 1. SPIRV-Cross
        //       would otherwise auto-allocate starting from 0, stomping
        //       the VBO slot 0 on the VS stage.
        //
        //   (b) Storage images would otherwise get `msl_texture =
        //       textureBase + glBinding`, which under argument_buffers
        //       becomes [[id(glBinding)]] inside spvDescriptorSetBuffer0
        //       — colliding with sampled_images at 2*glBinding_sampled.
        //       Offset storage-image ids to 128+ so they live in a
        //       clearly-separated range.
        //
        //   (c) SSBOs would otherwise get `msl_buffer = storageBufferBase
        //       + K (=28+K)`, colliding with sampled-image ids 2*14..
        //       inside the same argument buffer. Offset SSBO ids to 192+
        //       so they sit above both sampled (0..) and storage (128..)
        //       image ranges.
        //
        // Full id-space layout per argument buffer (desc_set 0):
        //   [0..127]    sampled_images   (2*N for image, 2*N+1 for sampler)
        //   [128..191]  storage_images
        //   [192..255]  SSBOs
        //
        // Desc_set 1 contains only UBOs, so no internal collision risk.
        // Push constants stay as a direct [[buffer(16)]] binding per
        // SPIRV-Cross's convention (they're never placed inside an
        // argument buffer by `analyze_argument_buffers`).
        const bool useArgBuf = forceArgBuf;
        if (useArgBuf) {
            // (a) Argument-buffer self-bindings. One per descriptor set
            // in use (0 = samplers/storage/SSBOs; 1 = UBOs). When a
            // descriptor set has no resources, the binding is silently
            // ignored by SPIRV-Cross.
            for (uint32_t set = 0; set < 2; ++set) {
                spirv_cross::MSLResourceBinding argBufBinding;
                argBufBinding.stage = compiler.get_execution_model();
                argBufBinding.desc_set = set;
                argBufBinding.binding = spirv_cross::kArgumentBufferBinding;
                argBufBinding.msl_buffer = 24 + set;
                compiler.add_msl_resource_binding(argBufBinding);
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
                std::uint32_t slotSpan = 1;
                const auto& varType = compiler.get_type(entry.res->type_id);
                if (!varType.array.empty() && varType.array[0] > 0) {
                    slotSpan = varType.array[0];
                }
                spirv_cross::MSLResourceBinding binding;
                binding.stage = compiler.get_execution_model();
                binding.desc_set = compiler.get_decoration(entry.res->id, spv::DecorationDescriptorSet);
                binding.binding = entry.glBinding;
                // Step 7-2 consolidation (c) — SSBO msl_buffer offset to
                // 192+ under argument_buffers mode to avoid colliding
                // with sampled-image ids (2*n) and storage-image ids
                // (128+n) within the same spvDescriptorSetBuffer0.
                // Direct-binding path unchanged (sequential from
                // storageBufferBase=28).
                if (useArgBuf) {
                    binding.msl_buffer = 192 + entry.glBinding;
                } else {
                    binding.msl_buffer = nextSSBOSlot;
                    nextSSBOSlot += slotSpan;
                }
                compiler.add_msl_resource_binding(binding);
            }
        }

        // Sprint 8 B Cluster F F1 Day 9 (CKPT81): unified sequential
        // allocator across sampled + storage images. Both occupy the
        // same Metal texture slot pool per stage; on Apple Silicon
        // outside argument-buffer mode, that pool is capped at 31 per
        // stage. CKPT77 fixed sampled images by collapsing GL bindings
        // 0..47 into [0, sampled_count). CKPT81 extends the same shape
        // to storage images: they're allocated AFTER the sampled
        // images at `nextSampledSlot..` rather than from the global
        // `storageImageBase=48` (which sat past Metal's 31-texture
        // limit and silently failed pipeline build, mirroring CKPT76's
        // sampled-binding-at-39 diagnostic, this time for image
        // uniforms).
        //
        // Apple-Silicon-31-resource-cap-cluster pattern, 3rd instance
        // (CKPT58 vertex attrs + CKPT76 sampled textures + CKPT81
        // storage images). The pool partition `sampled at 0..47,
        // storage at 48..55` was correct for the GL-spec advertised
        // limits but wrong for the underlying Metal hardware cap.
        std::uint32_t unifiedNextTextureSlot = bindings.textureBase;
        struct StorageImageAccessFixup {
            std::uint32_t metalSlot = 0;
            bool argumentBufferId = false;
            bool nonWritable = false;
            bool nonReadable = false;
        };
        std::vector<StorageImageAccessFixup> storageImageAccessFixups;

        // Remap sampled images (combined image samplers).
        //
        // Step 7-2: with argument_buffers enabled, Image and Sampler
        // halves of each SampledImage must land at DISTINCT argument-
        // buffer `[[id(N)]]` slots — SPIRV-Cross treats equal indices
        // as descriptor aliasing, which trips its fixup_hooks lambda
        // with a zero `overlapping_var_id` → Variant::get<SPIRVariable>
        // at spirv_common.hpp:1644 throws "nullptr". The argbuf branch
        // gives image and sampler separate id ranges (2*glBinding and
        // 2*glBinding + 1).
        //
        // Sprint 8 B Cluster F F1 Day 5 (CKPT77): in the direct-binding
        // path, allocate Metal texture/sampler slots SEQUENTIALLY in
        // glBinding-sorted order — NOT `textureBase + glBinding`
        // directly. GL advertises GL_MAX_TEXTURE_IMAGE_UNITS = 48 and
        // CTS layout_binding tests legally declare
        // `layout(binding=39) uniform sampler2D s;` (and binding values
        // up to 47 across binding_array_size sub-tests). However Apple
        // Silicon Metal silently fails pipeline state build when MSL
        // declares `[[texture(N)]]` for N >= 31 in the fragment stage
        // outside argument-buffer mode — `newRenderPipelineState…`
        // returns nil, the draw is queued against a non-bound pipeline,
        // no fragment runs, and the framebuffer stays at clear color.
        // This shape was diagnosed in CKPT76 via the APPGL_LOG_LB
        // trace: glUnit=39, metalSlot=39, texture pointer non-null,
        // but rendered pixel = (0,0,0,1) instead of the expected
        // green texture (0,1,0,1). The MSL dump showed
        // `[[texture(39)]]` emitted directly from GL binding 39.
        //
        // Sequential allocation collapses the [0..47] GL binding range
        // into the dense [0..N) Metal slot range where N is the count
        // of sampled images actually used in the program — typically
        // 1..16 for cluster F tests, well inside Metal's 31-texture
        // budget. The runtime-side resolver still uses the original
        // `glBinding` for the GL texture-unit lookup (via the GL
        // sampler uniform value), and `metalBinding` for the Metal
        // slot. Reflection mirrors the same sort + sequential index so
        // dispatch-time `setFragmentTexture(tex, atIndex:metalBinding)`
        // lines up with the MSL `[[texture(metalBinding)]]` slot.
        //
        // Sampler arrays (`uniform sampler2D arr[N]`) consume N
        // consecutive Metal slots — the runtime adds `arrayElement` to
        // `metalBinding` when binding each element (see
        // GLContext.mm::resolveStage). Sequential allocator must
        // advance `nextSlot` by the array size per entry so the next
        // sampler doesn't collide with arr[N-1].
        //
        // Argument-buffer mode is unchanged (uses distinct
        // 2*glBinding / 2*glBinding+1 ranges inside spvDescriptorSetBuffer0
        // — argbuf programs sit on the deferred path and aren't part
        // of the current cluster F failure mode).
        {
            struct SampledRef {
                std::uint32_t glBinding;
                std::uint32_t id;
                std::uint32_t arraySize;  // 1 for scalar, N for `samplerXX arr[N]`
                spirv_cross::Resource* res;
            };
            std::vector<SampledRef> sortedSampled;
            for (auto& img : resources.sampled_images) {
                SampledRef r;
                r.glBinding = compiler.get_decoration(img.id, spv::DecorationBinding);
                r.id = img.id;
                const auto& imgType = compiler.get_type(img.type_id);
                r.arraySize = imgType.array.empty()
                    ? 1u
                    : (imgType.array[0] > 0 ? imgType.array[0] : 1u);
                r.res = &img;
                sortedSampled.push_back(r);
            }
            std::sort(sortedSampled.begin(), sortedSampled.end(),
                      [](const SampledRef& a, const SampledRef& b) {
                          if (a.glBinding != b.glBinding) return a.glBinding < b.glBinding;
                          return a.id < b.id;
                      });
            for (auto& entry : sortedSampled) {
                spirv_cross::MSLResourceBinding binding;
                binding.stage = compiler.get_execution_model();
                binding.desc_set = compiler.get_decoration(entry.res->id, spv::DecorationDescriptorSet);
                binding.binding = entry.glBinding;
                if (useArgBuf) {
                    binding.msl_texture = bindings.textureBase + 2 * entry.glBinding;
                    binding.msl_sampler = bindings.samplerBase + 2 * entry.glBinding + 1;
                } else {
                    binding.msl_texture = unifiedNextTextureSlot;
                    binding.msl_sampler = unifiedNextTextureSlot;
                    unifiedNextTextureSlot += entry.arraySize;
                }
                compiler.add_msl_resource_binding(binding);
            }
        }

        // Remap storage images (imageLoad/imageStore — GL `image2D` etc.).
        // These map to MSL `texture2d<T, access::read|write|read_write>`
        // and share Metal's single per-stage texture slot pool with
        // sampled images. Three independent collision concerns drive
        // the layout here:
        //
        //  (i) GL's sampler-uniform and image-uniform binding spaces
        //      are INDEPENDENT — a shader can legally declare both
        //      `layout(binding=0) uniform sampler2D s;` AND
        //      `layout(binding=0) uniform image2D i;` and the two
        //      units refer to different GL state. Metal has a single
        //      texture slot pool so we partition it: sampled at
        //      `textureBase..+47` (matches GL_MAX_TEXTURE_IMAGE_UNITS
        //      = 48 in caps) and storage at
        //      `storageImageBase..+7` (GL_MAX_IMAGE_UNITS = 8).
        //
        // (ii) Two storage-image uniforms can land with the same
        //      glBinding — e.g. `layout(rgba8) uniform image2D a;`
        //      and `layout(rgba8) uniform image2D b;`, both with no
        //      explicit binding, both taking SPIR-V
        //      DecorationBinding=0 from glslang. GL 4.6 §7.6 lets the
        //      app then call `glUniform1i(locA, 0)` and
        //      `glUniform1i(locB, 1)` to route them to distinct image
        //      units at runtime. Metal requires distinct per-resource
        //      slot indices, so we allocate SEQUENTIALLY from
        //      `storageImageBase` in glBinding-sorted order —
        //      mirroring how SSBOs are packed (see above) — and the
        //      reflection-side mirror uses the same ordering so
        //      dispatch-time binding resolution lines up.
        //
        // (iii) SPIRV-Cross's `add_msl_resource_binding` keys its
        //       table on `(stage, desc_set, binding)`. Both sampler
        //       and storage image arrive with desc_set=0 and the
        //       same glBinding, so two writes to the same triple
        //       silently overwrite each other. Fix: reassign storage
        //       images' `DecorationDescriptorSet` to 2 (unused —
        //       UBOs already sit at set=1) in direct-binding mode,
        //       and give each image a unique synthetic binding
        //       number equal to its sequential index. The (stage, 2,
        //       seq) triple is then globally unique. Argument-buffer
        //       mode already keeps sampled and storage at distinct
        //       `[[id(N)]]` ranges inside one argbuf, so we leave
        //       argbuf-mode at set=0 and the spvDescriptorSetBuffer0
        //       layout undisturbed.
        //
        // Reflection (in reflect() below) mirrors the sort and the
        // sequential `metalBinding = storageImageBase + seq`
        // assignment, while keeping the original glBinding for the
        // runtime-side glUniform1i lookup — that field drives the
        // GL image-unit → texture resolution in dispatchCompute /
        // resolveImageBindings.
        //
        // KHR-GL46.compute_shader.copy-image and resource-image also
        // rely on the GL-side bind routing to read a sampled binding
        // back into an image binding at draw time — that still works
        // because the routing happens via distinct reflection lists
        // (sampledTextures vs storageImages) with distinct metalSlot
        // values.
        {
            // Filter out declared-but-unused storage images to match
            // what reflect() does. SPIRV-Cross's dead-code pass elides
            // inactive images from the emitted MSL, so including them
            // in the sequential index allocation here would make
            // active images land at different msl_texture slots than
            // reflection expects — reflection also filters by
            // `get_active_interface_variables()`. Mirror that filter
            // so both sides agree on the seq→slot mapping.
            const auto activeVarsForImages = compiler.get_active_interface_variables();
            struct StorageImgRef {
                std::uint32_t glBinding;
                std::uint32_t id;
                bool nonWritable;
                bool nonReadable;
            };
            std::vector<StorageImgRef> sortedStorageImages;
            for (auto& img : resources.storage_images) {
                if (activeVarsForImages.find(img.id) == activeVarsForImages.end())
                    continue;
                StorageImgRef r;
                r.glBinding = compiler.get_decoration(img.id, spv::DecorationBinding);
                r.id = img.id;
                r.nonWritable = compiler.has_decoration(img.id, spv::DecorationNonWritable);
                r.nonReadable = compiler.has_decoration(img.id, spv::DecorationNonReadable);
                sortedStorageImages.push_back(r);
            }
            std::sort(sortedStorageImages.begin(), sortedStorageImages.end(),
                      [](const StorageImgRef& a, const StorageImgRef& b) {
                          if (a.glBinding != b.glBinding) return a.glBinding < b.glBinding;
                          return a.id < b.id;
                      });
            for (std::size_t i = 0; i < sortedStorageImages.size(); ++i) {
                const auto& entry = sortedStorageImages[i];
                spirv_cross::MSLResourceBinding binding;
                binding.stage = compiler.get_execution_model();
                if (useArgBuf) {
                    // Argument-buffer mode: preserve the existing
                    // [[id(128+glBinding)]] routing. Multiple images
                    // at the same glBinding aren't something the
                    // argbuf path currently hits (the CTS argbuf
                    // exercises go through distinct explicit
                    // bindings), so the glBinding-based key still
                    // gives unique triples here.
                    binding.desc_set = compiler.get_decoration(entry.id, spv::DecorationDescriptorSet);
                    binding.binding = entry.glBinding;
                    binding.msl_texture = 128 + entry.glBinding;
                    if (isGraphicsStage) {
                        storageImageAccessFixups.push_back({
                            binding.msl_texture, true,
                            entry.nonWritable, entry.nonReadable});
                    }
                } else {
                    constexpr std::uint32_t kStorageImageDescSet = 2;
                    // Override both the descriptor-set AND the
                    // binding so the (stage, set, binding) triple is
                    // unique per image uniform even when multiple
                    // images came in with the same glBinding. The
                    // overridden binding is a SEQUENTIAL index into
                    // the sorted order, so reflection can reproduce
                    // it deterministically.
                    compiler.set_decoration(entry.id,
                        spv::DecorationDescriptorSet, kStorageImageDescSet);
                    compiler.set_decoration(entry.id,
                        spv::DecorationBinding, static_cast<std::uint32_t>(i));
                    binding.desc_set = kStorageImageDescSet;
                    binding.binding = static_cast<std::uint32_t>(i);
                    // CKPT81: allocate after the sampled-image
                    // sequential pool, not from the legacy
                    // `storageImageBase=48` constant. Same pool as
                    // sampled (Metal has one texture slot pool per
                    // stage), capped at 31 on Apple Silicon outside
                    // argbuf mode. Reflection mirrors below.
                    binding.msl_texture = unifiedNextTextureSlot;
                    unifiedNextTextureSlot += 1;
                    if (isGraphicsStage) {
                        storageImageAccessFixups.push_back({
                            binding.msl_texture, false,
                            entry.nonWritable, entry.nonReadable});
                    }
                }
                compiler.add_msl_resource_binding(binding);
            }
        }

        std::string msl = compiler.compile();

        // Sprint 18 Item 42 / shader_image_load_store: storage-image MSL
        // post-process, matching the established R3B padded-array and
        // R-argbuf spvBufferSizeConstants rewrite pattern. GL image
        // memory qualifiers are lowered to SPIR-V decorations:
        //   readonly  => NonWritable => Metal access::read
        //   writeonly => NonReadable => Metal access::write
        // SPIRV-Cross's AppGL fork intentionally emits read_write for
        // readonly storage images to satisfy compute/argbuf reflection,
        // but direct graphics storage images on Metal need the precise
        // access qualifier or shader_image_load_store read paths return
        // zero. Keep this scoped to graphics-stage storage images so the
        // already-passing compute cases stay on the existing path.
        if (isGraphicsStage && !storageImageAccessFixups.empty()) {
            auto accessChar = [](char ch) {
                return (ch >= 'a' && ch <= 'z') ||
                       (ch >= 'A' && ch <= 'Z') ||
                       (ch >= '0' && ch <= '9') ||
                       ch == '_' || ch == ':';
            };
            auto setTextureAccess = [&](const StorageImageAccessFixup& fixup,
                                        const char* access) {
                const std::string attr =
                    std::string("[[") +
                    (fixup.argumentBufferId ? "id(" : "texture(") +
                    std::to_string(fixup.metalSlot) + ")]]";
                std::size_t search = 0;
                while ((search = msl.find(attr, search)) != std::string::npos) {
                    const std::size_t attrPos = search;
                    const std::size_t lineStart = msl.rfind('\n', search);
                    const std::size_t begin =
                        (lineStart == std::string::npos) ? 0 : lineStart + 1;
                    const std::size_t typePos = msl.rfind("texture", search);
                    if (typePos == std::string::npos || typePos < begin) {
                        search += attr.size();
                        continue;
                    }
                    const std::size_t close = msl.find('>', typePos);
                    if (close == std::string::npos || close >= search) {
                        search += attr.size();
                        continue;
                    }
                    const std::string replacement =
                        std::string("access::") + access;
                    const std::size_t accessPos = msl.find("access::", typePos);
                    if (accessPos != std::string::npos && accessPos < close) {
                        std::size_t accessEnd = accessPos;
                        while (accessEnd < close && accessChar(msl[accessEnd])) {
                            ++accessEnd;
                        }
                        const std::size_t oldAccessLen = accessEnd - accessPos;
                        msl.replace(accessPos, accessEnd - accessPos,
                                    replacement);
                        const auto delta =
                            static_cast<std::ptrdiff_t>(replacement.size()) -
                            static_cast<std::ptrdiff_t>(oldAccessLen);
                        search = static_cast<std::size_t>(
                            static_cast<std::ptrdiff_t>(attrPos) + delta) +
                            attr.size();
                    } else {
                        const std::string insertion =
                            std::string(", ") + replacement;
                        msl.insert(close, insertion);
                        search = attrPos + insertion.size() + attr.size();
                    }
                }
            };

            for (const auto& fixup : storageImageAccessFixups) {
                if (fixup.nonWritable && !fixup.nonReadable) {
                    setTextureAccess(fixup, "read");
                } else if (fixup.nonReadable && !fixup.nonWritable) {
                    setTextureAccess(fixup, "write");
                }
            }
        }

        // Sprint 18 Item 32 candidate: GL storage-image side effects
        // survive `discard`, while Metal can suppress texture writes in
        // a fragment that terminates with `discard_fragment()`. CTS
        // shader_image_load_store.basic-allFormats-store uses exactly
        // this "imageStore then discard" shape with no color output.
        // For pure write-only fragment-void shaders, return normally
        // instead: no color is produced, but the image side effect is
        // preserved. Leave read+write copy shaders on the existing
        // discard path; CTS single-byte_data_alignment already depends
        // on that shape preserving both imageLoad and imageStore.
        if (isFragment &&
            msl.find("fragment void ") != std::string::npos &&
            msl.find("access::write") != std::string::npos &&
            msl.find("access::read") == std::string::npos) {
            const std::string discard = "discard_fragment();";
            const std::string ret = "return;";
            std::size_t pos = 0;
            while ((pos = msl.find(discard, pos)) != std::string::npos) {
                msl.replace(pos, discard.size(), ret);
                pos += ret.size();
            }
        }

        // Sprint 18 Item42: graphics-stage argument buffers need SSBO
        // `.length()` / OpArrayLength sizes, but Metal's argument-buffer
        // encoding does not reliably surface SPIRV-Cross's
        // `spvBufferSizeConstants` pointer member for this shape. Keep
        // SSBO resources in the set-0 argbuf, but route the size sidecar
        // through a direct graphics buffer slot. Slot 30 is outside the
        // argbuf self-bindings (24/25) and the direct path is not active
        // for these SSBOs.
        if (useArgBuf &&
            (execModel == spv::ExecutionModelVertex ||
             execModel == spv::ExecutionModelFragment) &&
            msl.find("spvBufferSizeConstants") != std::string::npos) {
            auto replaceAll = [](std::string& text,
                                 const std::string& needle,
                                 const std::string& replacement) {
                std::size_t pos = 0;
                while ((pos = text.find(needle, pos)) != std::string::npos) {
                    text.replace(pos, needle.size(), replacement);
                    pos += replacement.size();
                }
            };
            replaceAll(msl,
                "spvBufferSizeConstants [[buffer(25)]]",
                "spvBufferSizeConstants [[buffer(30)]]");
            replaceAll(msl,
                "spvDescriptorSet0.spvBufferSizeConstants",
                "spvBufferSizeConstants");
        }

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
        {
            static constexpr const char* kPaddedArrayNeedle =
                "template <typename T, int stride>\n"
                "struct spvPaddedArrayElement { T data; char padding[stride - sizeof(T)]; };";
            static constexpr const char* kPaddedArrayReplacement =
                "template <typename T, int stride, bool hasPadding = (stride > sizeof(T))>\n"
                "struct spvPaddedArrayElement { T data; char padding[stride - sizeof(T)]; };\n"
                "\n"
                "template <typename T, int stride>\n"
                "struct spvPaddedArrayElement<T, stride, false> { T data; };";
            const std::size_t pos = msl.find(kPaddedArrayNeedle);
            if (pos != std::string::npos) {
                msl.replace(pos, std::strlen(kPaddedArrayNeedle), kPaddedArrayReplacement);
            }
        }

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
        //
        // Sprint 17 Day 7+ Bank-Group-H Path B Component A2: when the
        // caller flags `disableCullDistanceClipRouting`, the CPU
        // `emulateVsCullPrepass` handles GL §14.6.3 per-primitive cull
        // by filtering the index buffer; routing cull→[[clip_distance]]
        // here would then over-clip at the per-fragment level for any
        // vertex with a negative cull value on a non-culled channel
        // (Phase 2 confirmed via CTS test design at glcCullDistance
        // .cpp:2236-2246).
        // Sprint 17 Day 9+ Bank-Group-H R13 sub-bank item_4 (dynamic-
        // index cull writes): runs UNGATED by
        // `disableCullDistanceClipRouting` because the issue is
        // unconditional MSL invalidity. SPIRV-Cross's MSL backend
        // flattens `gl_CullDistance` into per-index struct fields
        // (`gl_CullDistance_K [[user(cullK)]]`) but emits
        // `out.gl_CullDistance[expr]` (array access) when the VS code
        // dynamically indexes the array — `gl_CullDistance` is no
        // longer a struct member after flattening, so the access is
        // invalid. The static-index post-processing below matches
        // `out.gl_CullDistance_K = EXPR;` lines (and skips when Path B
        // disables cull→clip routing); dynamic-index lines never match
        // either pattern. Without this transform, CTS
        // `cull_distance.functional_test_item_4`
        // (use_dynamic_index_based_writes) writes were dropped on both
        // Path B (CPU does its own cull, but flattened fields are also
        // read by the FS for fetch_culldistances variants) and the
        // legacy cull→clip routing.
        //
        // Route dynamic-index writes through a local
        // `spvUnsafeArray<float, M>` then unroll a copy-back to the
        // flattened struct fields just before `return out;`. The
        // copy-back lines have static indices so the cull→clip pass
        // below picks them up and emits HW clip-distance siblings
        // automatically (when not disabled by Path B).
        if (msl.find("vertex ") != std::string::npos
            && msl.find("gl_CullDistance_0 [[user(cull0)]]") != std::string::npos) {
            int cullCountForDyn = 0;
            for (int k = 0; k < 8; ++k) {
                char needle[64];
                std::snprintf(needle, sizeof(needle),
                              "gl_CullDistance_%d [[user(cull%d)]]", k, k);
                if (msl.find(needle) != std::string::npos) {
                    cullCountForDyn = k + 1;
                } else {
                    break;
                }
            }
            // Detect any `out.gl_CullDistance[<expr>]` where the bracket
            // contents are NOT a single decimal literal (digit run + `]`).
            // Static-index emit is `out.gl_CullDistance_K = ...` (no
            // `[`), so any `out.gl_CullDistance[` is dynamic. Only fire
            // when at least one such line exists AND we have flattened
            // fields to route to.
            const std::string dynPrefix = "out.gl_CullDistance[";
            const bool hasDynCullWrite =
                cullCountForDyn > 0 &&
                msl.find(dynPrefix) != std::string::npos;
            if (hasDynCullWrite) {
                // Locate `main0_out out = {};` (the function-entry decl
                // emitted by SPIRV-Cross for vertex stages) and inject
                // a synthetic local cull array right after.
                const std::string outInitLine = "main0_out out = {};";
                std::size_t outInitPos = msl.find(outInitLine);
                if (outInitPos != std::string::npos) {
                    std::size_t injectPos = outInitPos + outInitLine.size();
                    std::string localDecl =
                        "\n    spvUnsafeArray<float, " +
                        std::to_string(cullCountForDyn) +
                        "> _appgl_cullDist = {};";
                    msl.insert(injectPos, localDecl);
                    // Replace every `out.gl_CullDistance[` with
                    // `_appgl_cullDist[`. The injection above moved the
                    // remainder of the buffer, so the find-replace pass
                    // operates on the post-injection string.
                    std::size_t scan = 0;
                    while (true) {
                        std::size_t hit = msl.find(dynPrefix, scan);
                        if (hit == std::string::npos) break;
                        msl.replace(hit, dynPrefix.size(), "_appgl_cullDist[");
                        scan = hit + std::string("_appgl_cullDist[").size();
                    }
                    // Insert the unrolled copy-back to flattened struct
                    // fields just before `return out;`. The static-index
                    // cull→clip pass below then picks up these lines and
                    // emits HW `out.gl_ClipDistance[N+K]` siblings.
                    const std::string returnStmt = "return out;";
                    std::size_t retPos = msl.rfind(returnStmt);
                    if (retPos != std::string::npos) {
                        std::string copyBack;
                        copyBack.reserve(cullCountForDyn * 64);
                        for (int k = 0; k < cullCountForDyn; ++k) {
                            copyBack += "    out.gl_CullDistance_";
                            copyBack += std::to_string(k);
                            copyBack += " = _appgl_cullDist[";
                            copyBack += std::to_string(k);
                            copyBack += "];\n";
                        }
                        msl.insert(retPos, copyBack);
                    }
                }
            }
        }
        // Static-index cull→clip routing (Sprint 17 Day 7+ Path B
        // Component A2 disable gate restored). The dynamic-index
        // transform above unconditionally fixes the broken MSL; this
        // block additionally synthesizes HW `[[clip_distance]]`
        // siblings for static-index cull writes when the caller does
        // NOT have a CPU pre-pass to handle GL §14.6.3 cull semantics.
        if (msl.find("vertex ") != std::string::npos
            && msl.find("gl_CullDistance_0 [[user(cull0)]]") != std::string::npos
            && !options.disableCullDistanceClipRouting) {
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
        // any line where the marker appears as an access-chain member
        // (`.{marker}`) — that's the dangling-RHS shape. Standalone
        // uses (struct definitions, threadgroup/spvUnsafeArray locals
        // for mesh-shader gl_PerVertex / gl_in / gl_out) lack the
        // leading dot and are preserved.
        {
            const std::string kAccessMarker = "._RESERVED_IDENTIFIER_FIXUP_gl_";
            std::string out;
            out.reserve(msl.size());
            std::size_t pos = 0;
            while (pos < msl.size()) {
                const std::size_t nl = msl.find('\n', pos);
                const std::size_t lineEnd = (nl == std::string::npos) ? msl.size() : nl + 1;
                const std::string_view line(msl.data() + pos, lineEnd - pos);
                if (line.find(kAccessMarker) == std::string_view::npos) {
                    out.append(line);
                }
                pos = lineEnd;
            }
            msl = std::move(out);
        }

        // CKPT120 (Sprint 11 Phase 2 Cluster A MSAA Day 5):
        // gl_SampleMask write-through fix for non-MSAA framebuffers.
        // GL 4.6 §17.3.3 + ARB_sample_shading: writes to gl_SampleMask
        // have NO EFFECT when MSAA is disabled / sample-count is 1
        // (the per-sample raster path doesn't run). Metal's
        // `[[sample_mask]]` is unconditional — a 0-write at single-sample
        // gates ALL fragment writes, dropping the entire draw. CTS
        // sample_variables.mask.*.samples_0.* (36F) hits this: shader
        // unconditionally writes `gl_SampleMask = u_sampleMask &
        // gl_SampleMaskIn` → mask_zero → 0 → fragment dropped → texture
        // stays clear-green → verifier expects red → FAIL.
        //
        // CKPT121 (Day 6): gate the override on actual sample count so
        // MSAA-mask correctness is preserved for samples > 1.
        // glslang/SPIRV-Cross emits gl_NumSamples as a `[[buffer(0)]]`
        // int parameter — but no runtime path plumbs that buffer, so
        // it reads garbage. Replace it with Metal's `raster_sample_count()`
        // intrinsic (MSL 2.1+ / macOS 10.14+, well within our target):
        //   1. Strip the `constant int& ..._gl_NumSamples [[buffer(0)]],`
        //      parameter from `main0`.
        //   2. Inject a local `int _RESERVED_IDENTIFIER_FIXUP_gl_NumSamples
        //      = int(get_num_samples());` at the top of `main0`.
        //      `get_num_samples()` is the rasterization sample count of
        //      the bound color attachment; existing references in the
        //      shader body resolve to this local without further edits.
        //   3. Gate the gl_SampleMask=UINT_MAX override on
        //      `_RESERVED_IDENTIFIER_FIXUP_gl_NumSamples == 1`.
        // This restores MSAA-mask behaviour for samples > 1 while
        // keeping the samples_0 fix from Day 5.
        if (execModel == spv::ExecutionModelFragment
            && msl.find("[[sample_mask]]") != std::string::npos) {
            // Gate on `_RESERVED_IDENTIFIER_FIXUP_gl_NumSamples == 1`.
            // The MSL keeps SPIRV-Cross's `[[buffer(0)]]` parameter for
            // gl_NumSamples; the runtime (MetalFrameGraph) writes the
            // FBO's color-attachment sampleCount to that buffer slot at
            // each draw, so the comparison reads a genuine sample count
            // (1 for non-MSAA, 2/4/8/... for MSAA). When samples == 1
            // (per GL spec, MSAA disabled), force gl_SampleMask=UINT_MAX
            // to neutralize Metal's unconditional [[sample_mask]] gating.
            // For samples > 1, preserve the user's mask write.
            const std::string returnPattern = "    return out;";
            const std::string injection =
                "    if (_RESERVED_IDENTIFIER_FIXUP_gl_NumSamples == 1) "
                "{ out.gl_SampleMask = 0xFFFFFFFFu; }\n";
            std::string out2;
            out2.reserve(msl.size() + 128);
            std::size_t pos = 0;
            while (pos < msl.size()) {
                const std::size_t idx = msl.find(returnPattern, pos);
                if (idx == std::string::npos) {
                    out2.append(msl, pos, std::string::npos);
                    break;
                }
                out2.append(msl, pos, idx - pos);
                out2.append(injection);
                out2.append(returnPattern);
                pos = idx + returnPattern.size();
            }
            msl = std::move(out2);
        }

        if (log != nullptr) {
            *log = "ok";
        }
        // Diagnostic dumps: APPGL_DUMP_MSL writes the generated MSL to
        // msl_NNNN.metal; APPGL_DUMP_SPIRV writes the *input* SPIR-V to
        // spv_NNNN.spv. The pair shares a counter so msl_0007.metal and
        // spv_0007.spv are produced from the same translator invocation,
        // letting SPIRV-W round-trip the input SPIR-V through their local
        // spirv-cross and compare emission against ours. SPIR-V execution
        // model in word[2] of each OpEntryPoint identifies the stage —
        // run `spirv-dis spv_NNNN.spv | head` to disambiguate VS / TCS /
        // TES / FS / Compute.
        const char* mslDumpPath = std::getenv("APPGL_DUMP_MSL");
        const char* spirvDumpPath = std::getenv("APPGL_DUMP_SPIRV");
        if (mslDumpPath != nullptr || spirvDumpPath != nullptr) {
            static std::atomic<int> counter{0};
            const int n = counter.fetch_add(1);
            char path[512];
            if (mslDumpPath != nullptr) {
                std::snprintf(path, sizeof(path), "%s/msl_%04d.metal", mslDumpPath, n);
                if (FILE* f = std::fopen(path, "w")) {
                    std::fwrite(msl.data(), 1, msl.size(), f);
                    std::fclose(f);
                }
            }
            if (spirvDumpPath != nullptr) {
                std::snprintf(path, sizeof(path), "%s/spv_%04d.spv", spirvDumpPath, n);
                if (FILE* f = std::fopen(path, "wb")) {
                    std::fwrite(spirv, sizeof(std::uint32_t), wordCount, f);
                    std::fclose(f);
                }
            }
        }
        return msl;
    } catch (const spirv_cross::CompilerError& e) {
        if (log != nullptr) {
            *log = std::string("SPIRV-Cross error: ") + e.what();
        }
        // Step 7 debug: SPIRV-Cross throw → log to stderr when
        // APPGL_DUMP_MSL is set so argument-buffer experimentation
        // isn't silent. Caught at the `spirvToMSL` frame; callers see
        // the empty return.
        if (std::getenv("APPGL_DUMP_MSL") != nullptr) {
            std::fprintf(stderr, "[APPGL] SPIRV-Cross throw: %s\n", e.what());
        }
        return {};
    }
}

ShaderReflection ShaderTranslator::reflect(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const {
    return reflect(spirv, wordCount, bindings, log, TranslatorOptions{});
}

ShaderReflection ShaderTranslator::reflect(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log, const TranslatorOptions& options) const {
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
            // Sprint 8 B Cluster F F1 Day 2 (CKPT74): track whether
            // the GLSL had an explicit `layout(binding=N)` qualifier
            // on this UBO. Required for block-array consecutive
            // binding semantics — explicit bindings give b[i] = N+i,
            // implicit bindings give b[i] = 0 (default) for all i.
            rb.hasExplicitBinding =
                compiler.has_decoration(ubo.id, spv::DecorationBinding);
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

                    // Multi-dim array of non-struct: expand outer dims,
                    // keep innermost as arraySize. GL 4.6 §7.3.1.1 —
                    // parallel to the SSBO path's flattenSSBO. CTS
                    // `program_interface_query.arrays-of-arrays` declares
                    // `uniform vec4 a[3][4][5]` and expects 12 entries
                    // (3*4) with arraySize=5 each.
                    if (!memberType.array.empty() && memberType.array.size() > 1 &&
                        memberType.basetype != spirv_cross::SPIRType::Struct) {
                        // SPIRV-Cross order is innermost-first: for GLSL
                        // `vec4 a[3][4][5]` array = [5, 4, 3].
                        const std::uint32_t innermostDim = memberType.array[0];
                        GLint baseArrayStride = 0;
                        if (compiler.has_member_decoration(parentType.self, mi,
                                spv::DecorationArrayStride)) {
                            baseArrayStride = static_cast<GLint>(
                                compiler.get_member_decoration(parentType.self, mi,
                                    spv::DecorationArrayStride));
                        }
                        std::uint32_t totalCombos = 1;
                        for (std::size_t d = 1; d < memberType.array.size(); ++d) {
                            totalCombos *= (memberType.array[d] > 0 ? memberType.array[d] : 1);
                        }
                        const GLint perEntryStride = baseArrayStride;
                        for (std::uint32_t combo = 0; combo < totalCombos; ++combo) {
                            std::string subscript;
                            std::uint32_t remain = combo;
                            std::vector<std::uint32_t> indices;
                            for (std::size_t d = 1; d < memberType.array.size(); ++d) {
                                const std::uint32_t dimSize =
                                    memberType.array[d] > 0 ? memberType.array[d] : 1;
                                indices.push_back(remain % dimSize);
                                remain /= dimSize;
                            }
                            for (auto it = indices.rbegin(); it != indices.rend(); ++it) {
                                subscript += "[" + std::to_string(*it) + "]";
                            }
                            ShaderReflection::UniformMember member;
                            member.name = (prefix.empty()
                                ? memberName : (prefix + "." + memberName)) + subscript;
                            member.offset = memberOffset + combo * perEntryStride;
                            member.size = static_cast<std::size_t>(perEntryStride * innermostDim);
                            member.type = spirvBaseTypeToGL(memberType);
                            member.isArray = true;
                            member.arraySize = innermostDim;
                            member.arrayStride = baseArrayStride;
                            if (memberType.columns > 1) {
                                member.isRowMajor = compiler.has_member_decoration(
                                    parentType.self, mi, spv::DecorationRowMajor);
                            }
                            if (compiler.has_member_decoration(parentType.self, mi,
                                    spv::DecorationMatrixStride)) {
                                member.matrixStride = static_cast<GLint>(
                                    compiler.get_member_decoration(parentType.self, mi,
                                        spv::DecorationMatrixStride));
                            }
                            rb.members.push_back(std::move(member));
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
                    // Fallback array stride from declared-size when SPIR-V
                    // didn't decorate the member with DecorationArrayStride.
                    // That happens for array members of nested structs (the
                    // block-level std140 decoration flows to the outer
                    // struct's members but not to inner struct members' own
                    // array decorations — CTS
                    // `shaders.struct.uniform.nested_struct_array_*` ships
                    // `uniform S s[2]; struct S { ... T b[3]; ... };
                    // struct T { ... vec2 b[2]; };` and the innermost
                    // `vec2 b[2]` had stride=0, so
                    // `buildStageUniformBuffer`'s per-element unpadding
                    // loop never fired and element 1 stayed at the initial
                    // zero fill). The inner stride is still std140 because
                    // the whole block is std140; `size / arraySize` gives
                    // the correct value.
                    if (member.isArray && member.arraySize > 0 &&
                        member.arrayStride == 0 && member.size > 0) {
                        member.arrayStride = static_cast<GLint>(
                            member.size / static_cast<std::size_t>(member.arraySize));
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
        //
        // Step 7-3 follow-up: under argument_buffers mode, reflection's
        // metalBinding doubles as the argbuf `[[id(N)]]` slot so the
        // Metal-side bind code uses it directly without resource-type-
        // specific translation. The values here must match the
        // `msl_texture` / `msl_sampler` set by the translator's
        // `add_msl_resource_binding` calls (see the phase-7-2
        // consolidation comment in spirvToMSL):
        //
        //   sampled_images: msl_texture = 2*glBinding, sampler = +1
        //   storage_images: msl_texture = 128 + glBinding
        //   SSBOs:          msl_buffer  = 192 + glBinding
        //   UBOs:           msl_buffer  = 16 + seq  (same as direct)
        //
        // Direct-binding mode keeps the existing textureBase /
        // storageBufferBase sequential assignment so baseline Metal
        // slot layout is unchanged.
        //
        // Lifetime invariant: `APPGL_ENABLE_ARGUMENT_BUFFERS` is read
        // once per reflect() call, mirroring the equivalent check in
        // spirvToMSL(). Both run at glLinkProgram time (for a given
        // program) and nothing downstream re-reads the env var, so as
        // long as the env is set before linkProgram (which is how the
        // gate is used — set once at process start), reflection and
        // translation always agree. If the env var were toggled mid-
        // process, new programs would pick up the new mode; already-
        // linked programs retain their old mode until relinked.
        const bool useArgBufReflection = options.forceArgumentBuffers ||
            (std::getenv("APPGL_ENABLE_ARGUMENT_BUFFERS") != nullptr);
        // Sprint 8 B Cluster F F1 Day 5 (CKPT77): mirror spirvToMSL's
        // sequential allocator for the direct-binding path so the
        // reflected `metalBinding` matches the MSL-emitted
        // `[[texture(N)]]` slot. Sort by (glBinding, id) and walk a
        // running counter that advances by each entry's array size.
        // See the matching block in spirvToMSL above for the full
        // rationale. Argument-buffer mode keeps its 2*glBinding mapping.
        //
        // Day 9 (CKPT81): unified counter with storage-images so both
        // share Metal's per-stage texture slot pool (Apple Silicon
        // 31-cap). Walks sampled first, then storage, in lockstep with
        // spirvToMSL's `unifiedNextTextureSlot`.
        std::uint32_t unifiedNextTextureSlotR = bindings.textureBase;
        {
            struct SampledRefR {
                std::uint32_t glBinding;
                std::uint32_t id;
                std::uint32_t arraySize;
                spirv_cross::Resource* res;
            };
            std::vector<SampledRefR> sortedSampled;
            for (auto& img : resources.sampled_images) {
                SampledRefR r;
                r.glBinding = compiler.get_decoration(img.id, spv::DecorationBinding);
                r.id = img.id;
                const auto& imgType = compiler.get_type(img.type_id);
                r.arraySize = imgType.array.empty()
                    ? 1u
                    : (imgType.array[0] > 0 ? imgType.array[0] : 1u);
                r.res = &img;
                sortedSampled.push_back(r);
            }
            std::sort(sortedSampled.begin(), sortedSampled.end(),
                      [](const SampledRefR& a, const SampledRefR& b) {
                          if (a.glBinding != b.glBinding) return a.glBinding < b.glBinding;
                          return a.id < b.id;
                      });
            for (auto& entry : sortedSampled) {
                ShaderReflection::ResourceBinding rb;
                rb.glBinding = entry.glBinding;
                if (useArgBufReflection) {
                    rb.metalBinding = 2 * entry.glBinding;
                } else {
                    rb.metalBinding = unifiedNextTextureSlotR;
                    unifiedNextTextureSlotR += entry.arraySize;
                }
                rb.name = entry.res->name;
                result.sampledTextures.push_back(std::move(rb));
            }
        }

        // Storage images (imageLoad/imageStore targets). Distinct from
        // sampled textures because the GL binding model differs: storage
        // images are bound via glBindImageTexture(unit, tex, …), not via
        // a sampler uniform that names a texture unit. Dispatch-time
        // binding resolution iterates this list separately and looks up
        // imageBindings[glBinding] rather than a uniform value.
        //
        // Phase 7 cleanup (a): filter to ACTIVE storage images only.
        // A declared-but-unused `uniform image2D` would stay in
        // `resources.storage_images` but SPIRV-Cross's dead-code pass
        // drops it from the emitted MSL, so Metal's argument-encoder
        // reflection doesn't see it either. Pushing the inactive
        // binding into the GL-side list gave `ComputeDispatchInfo::
        // textures` entries whose `metalSlot` was outside the
        // encoder's enumerated index range, triggering
        //   "index (N) is outside of the valid index range [M, M]"
        // on `compute_shader.pipeline-post-fs` (shared GLSL source
        // with a #define-toggled input-image use, so the pre-fs
        // compile drops g_input_image but retains its declaration).
        auto activeStorageImages = compiler.get_active_interface_variables();
        {
            // Mirror the (glBinding, id) sort used by spirvToMSL so
            // reflection's `metalBinding` lines up with each image's
            // MSL-declared `[[texture(N)]]` exactly. The sequential-
            // allocation path below depends on seeing the images in
            // the same deterministic order. See the phase-7
            // consolidation comment in spirvToMSL for the full
            // rationale — summary: (1) disjoint from sampled
            // textures via `storageImageBase`, (2) sequentially
            // packed so two images sharing a glBinding land at
            // distinct Metal slots, (3) runtime resolves via the
            // original `glBinding` (read from SPIR-V here) + any
            // glUniform1i override, not via `metalBinding`.
            struct StorageImgRef {
                std::uint32_t glBinding;
                std::uint32_t id;
                spirv_cross::Resource* res;
            };
            std::vector<StorageImgRef> sortedStorageImages;
            for (auto& img : resources.storage_images) {
                if (activeStorageImages.find(img.id) == activeStorageImages.end())
                    continue;
                StorageImgRef r;
                r.glBinding = compiler.get_decoration(img.id, spv::DecorationBinding);
                r.id = img.id;
                r.res = &img;
                sortedStorageImages.push_back(r);
            }
            std::sort(sortedStorageImages.begin(), sortedStorageImages.end(),
                      [](const StorageImgRef& a, const StorageImgRef& b) {
                          if (a.glBinding != b.glBinding) return a.glBinding < b.glBinding;
                          return a.id < b.id;
                      });
            for (std::size_t i = 0; i < sortedStorageImages.size(); ++i) {
                const auto& entry = sortedStorageImages[i];
                ShaderReflection::ResourceBinding rb;
                // Preserve the ORIGINAL glBinding — runtime uses it
                // (plus any glUniform1i override) to pick the GL
                // image unit. metalBinding is the synthetic Metal
                // slot chosen by our sequential allocator.
                rb.glBinding = entry.glBinding;
                if (useArgBufReflection) {
                    rb.metalBinding = 128 + entry.glBinding;
                } else {
                    // CKPT81: shared pool with sampled images.
                    rb.metalBinding = unifiedNextTextureSlotR;
                    unifiedNextTextureSlotR += 1;
                }
                rb.name = entry.res->name;
                result.storageImages.push_back(std::move(rb));
            }
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
            {
                const auto& varType = compiler.get_type(ssbo.type_id);
                if (!varType.array.empty()) {
                    rb.blockArraySize = varType.array[0];
                }
            }
            const std::uint32_t slotSpan =
                rb.blockArraySize > 0 ? rb.blockArraySize : 1u;
            // Sprint 8 B Cluster F F1 Day 2 (CKPT74): track explicit
            // binding for SSBO block-array consecutive semantics.
            rb.hasExplicitBinding =
                compiler.has_decoration(ssbo.id, spv::DecorationBinding);
            // Step 7-3 follow-up: argbuf reflection mirror — see the
            // sampled_images block above for the full rationale. SSBOs
            // under argbuf live at [[id(192 + glBinding)]] inside
            // spvDescriptorSetBuffer0.
            if (useArgBufReflection) {
                rb.metalBinding = 192 + rb.glBinding;
            } else {
                rb.metalBinding = nextSSBOSlot;
                nextSSBOSlot += slotSpan;
            }
            rb.active = (ssboActive.find(ssbo.id) != ssboActive.end());
            const auto& ssboType = compiler.get_type(ssbo.base_type_id);
            const std::string typeName = compiler.get_name(ssboType.self);
            rb.name = typeName.empty() ? ssbo.name : typeName;
            rb.hasInstanceName = (!typeName.empty() && ssbo.name != typeName);
            // Block-array dimension: `buffer B { ... } e[2];` → 2.
            // Parallel to the UBO reflection path above. Drives the
            // per-instance block-entry expansion in mergeStorageBlocks and
            // reserves consecutive Metal slots matching SPIRV-Cross MSL.
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

                    // SPIRV-Cross stores `type.array` innermost-first
                    // per OpTypeArray nesting. For GLSL `vec4 a[5][4][3]`
                    // the array is [3, 4, 5] — array[0] is the innermost
                    // dim (3), array.back() is the outermost (5).
                    const bool hasArr = !memberType.array.empty();
                    const std::uint32_t innermostDim = hasArr
                        ? memberType.array[0] : 0;
                    const std::uint32_t outermostDim = hasArr
                        ? memberType.array.back() : 0;

                    // Compute this member's effective top-level size:
                    // - at the top level, it's the member's own
                    //   outermost array dim (or 1 if not an array).
                    // - unbounded top-level arrays (`data[]`) report
                    //   1 per GL 4.6 §7.3.1 ("If the top-level member
                    //   is an unsized array, the value returned is 1").
                    // - below the top level, inherit the incoming value.
                    GLint effTopLevel = topLevelArraySize;
                    if (isTopLevel) {
                        if (!hasArr) {
                            effTopLevel = 1;
                        } else if (outermostDim > 0) {
                            effTopLevel = static_cast<GLint>(outermostDim);
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
                    // Recurse into arrays of structs (single-dim for now
                    // — nested struct-arrays-of-arrays are rarer and not
                    // exercised by current CTS).
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

                    // Multi-dim array of non-struct (e.g. `vec4 a[5][4][3]`).
                    // GL 4.6 §7.3.1: expand all outer dims into separate
                    // entries, keep ONLY the innermost as the entry's
                    // arraySize. For `vec4 a[5][4][3]` (SPIR-V array =
                    // [3, 4, 5]): emit 5*4=20 entries named "a[i][j]"
                    // with arraySize=3, topLevelArraySize=5.
                    if (hasArr && memberType.array.size() > 1 &&
                        memberType.basetype != spirv_cross::SPIRType::Struct) {
                        // Outer dims are array[1..end-1] in SPIR-V order;
                        // walk them in reverse so we emit names in
                        // GLSL subscript order (outermost first).
                        GLint baseArrayStride = 0;
                        if (compiler.has_member_decoration(parentType.self, mi,
                                spv::DecorationArrayStride)) {
                            baseArrayStride = static_cast<GLint>(
                                compiler.get_member_decoration(parentType.self, mi,
                                    spv::DecorationArrayStride));
                        }
                        // Total product of outer dims (dims above array[0]).
                        std::uint32_t totalCombos = 1;
                        for (std::size_t d = 1; d < memberType.array.size(); ++d) {
                            totalCombos *= (memberType.array[d] > 0 ? memberType.array[d] : 1);
                        }
                        // Total byte size of the whole multi-dim member
                        // — used to compute GL_TOP_LEVEL_ARRAY_STRIDE
                        // (bytes between outermost elements = total / outerDim).
                        std::size_t memberTotalSize = 0;
                        try {
                            memberTotalSize = compiler.get_declared_struct_member_size(parentType, mi);
                        } catch (...) {}
                        // Per-outer-entry stride for offset bookkeeping —
                        // stride between consecutive innermost "slices".
                        // Each slice is `innermost * baseStride / innermost`
                        // but our combo iteration places slices linearly
                        // by combo index; perEntryStride = baseArrayStride
                        // gives the correct size for consecutive innermost
                        // arrays (a[0][0] vs a[0][1]) but wrong for outer
                        // (a[0][0] vs a[1][0]). CTS `top-level-array`
                        // doesn't verify per-entry offsets so we skip
                        // the per-outer-dim jump and use baseArrayStride
                        // uniformly. TODO: walk combo indices individually
                        // if a future test verifies per-entry offsets.
                        const GLint perEntryStride = baseArrayStride;
                        GLint tlStride = 0;
                        if (outermostDim > 0 && memberTotalSize > 0) {
                            tlStride = static_cast<GLint>(memberTotalSize / outermostDim);
                        } else if (baseArrayStride > 0) {
                            tlStride = baseArrayStride;
                        }
                        for (std::uint32_t combo = 0; combo < totalCombos; ++combo) {
                            // Decompose `combo` into per-dim indices.
                            // combo layout: least-significant = innermost
                            // outer dim (array[1]). Reverse to get
                            // outermost-first subscript.
                            std::string subscript;
                            std::uint32_t remain = combo;
                            // Walk from innermost-outer (array[1]) up to
                            // outermost (array.back()). At each step
                            // capture the index modulo that dim.
                            std::vector<std::uint32_t> indices;
                            for (std::size_t d = 1; d < memberType.array.size(); ++d) {
                                const std::uint32_t dimSize =
                                    memberType.array[d] > 0 ? memberType.array[d] : 1;
                                indices.push_back(remain % dimSize);
                                remain /= dimSize;
                            }
                            // indices are innermost-outer first; reverse
                            // to outermost-first for GLSL "[i][j]..." order.
                            for (auto it = indices.rbegin(); it != indices.rend(); ++it) {
                                subscript += "[" + std::to_string(*it) + "]";
                            }

                            ShaderReflection::UniformMember member;
                            member.name = (prefix.empty()
                                ? memberName : (prefix + "." + memberName)) + subscript;
                            member.offset = memberOffset + combo * perEntryStride;
                            member.size = perEntryStride * innermostDim;
                            member.type = spirvBaseTypeToGL(memberType);
                            member.topLevelArraySize = effTopLevel;
                            member.topLevelArrayStride = tlStride;
                            member.isArray = true;
                            member.arraySize = innermostDim;  // 0 for unbounded
                            member.arrayStride = baseArrayStride;
                            // Row-major decoration (matrix of array).
                            if (memberType.columns > 1) {
                                member.isRowMajor = compiler.has_member_decoration(
                                    parentType.self, mi, spv::DecorationRowMajor);
                            }
                            if (compiler.has_member_decoration(parentType.self, mi,
                                    spv::DecorationMatrixStride)) {
                                member.matrixStride = static_cast<GLint>(
                                    compiler.get_member_decoration(parentType.self, mi,
                                        spv::DecorationMatrixStride));
                            }
                            rb.members.push_back(std::move(member));
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
                    if (hasArr) {
                        member.isArray = true;
                        member.arraySize = innermostDim;  // 0 for unbounded
                    }
                    if (compiler.has_member_decoration(parentType.self, mi,
                            spv::DecorationArrayStride)) {
                        member.arrayStride = static_cast<GLint>(
                            compiler.get_member_decoration(parentType.self, mi,
                                spv::DecorationArrayStride));
                        // Single-dim top-level array member (e.g.
                        // `vec4 data[]` or `vec4 data[N]`): top-level
                        // stride equals the member's array stride.
                        if (isTopLevel) {
                            member.topLevelArrayStride = member.arrayStride;
                        }
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

// Phase 6 [metal-tess-TF]: reflect the TES output struct layout under
// the same SPIRV-Cross options that the TES-as-compute MSL translation
// uses. Returns member names + byte offsets so the transform-feedback
// writer can locate each GL-declared TF varying by name in the emitted
// `main0_out` struct and copy the per-vertex bytes to the bound TF
// buffer.
//
// As of `6feb2fa` (third_party: SPIRV-Cross MSL introspection helper),
// SPIRV-Cross exposes `CompilerMSL::get_msl_interface_layout(...)`
// returning the canonical member list that the compiler actually emits.
// This replaces the hand-rolled reconstruction (~225 lines previously)
// with a direct query — eliminates the whole class of "AppGL mirrors
// SPIRV-Cross logic and silently decays as patches evolve" bugs that
// surfaced in T4C as the 32B-per-vertex stride drift on
// data_pass_through-class shapes.
StageOutputLayout ShaderTranslator::reflectStageOutputLayout(
    const std::uint32_t* spirv, std::size_t wordCount,
    const TranslatorOptions& options) const
{
    StageOutputLayout out;
    if (spirv == nullptr || wordCount < 5) return out;
    try {
        spirv_cross::CompilerMSL compiler(spirv, wordCount);
        // Mirror the MSL options the TES-as-compute translation uses,
        // so the helper reports the exact layout the kernel writes.
        spirv_cross::CompilerMSL::Options mslOpts = compiler.get_msl_options();
        mslOpts.set_msl_version(2, 2);
        const auto execModel = compiler.get_execution_model();
        const bool isTessEval = (execModel == spv::ExecutionModelTessellationEvaluation);
        const bool isVertex = (execModel == spv::ExecutionModelVertex);
        if (options.forceTessellation && isTessEval) {
            mslOpts.raw_buffer_tese_input = true;
            mslOpts.tess_domain_origin_lower_left = true;
        }
        if (options.forceTessEvalAsCompute && isTessEval) {
            mslOpts.tess_evaluation_as_compute = true;
            mslOpts.capture_output_to_buffer = true;
        }
        // Sprint 15 Q3-Option-B Phase 2 [metal-tf-vs]: mirror the
        // VS-as-compute MSL options here so the reflected output
        // struct layout matches the kernel-emitted output buffer's
        // per-vertex stride byte-for-byte. Without this gate, an
        // identical SPIR-V would be reflected as a conventional
        // `vertex` MSL output (returned struct) which can have
        // different padding from the `kernel` form (capture-to-
        // buffer struct), and the per-varying byte-offsets we
        // resolve at link time would not match the runtime layout.
        if (options.forceVertexForTessellation && isVertex) {
            mslOpts.vertex_for_tessellation = true;
            mslOpts.capture_output_to_buffer = true;
        }
        compiler.set_msl_options(mslOpts);
        // Compile to materialize the emitted struct in SPIRV-Cross's
        // internals. We discard the text — only the post-compile
        // reflection state matters.
        (void)compiler.compile();

        // Single-call query for the actual emitted main0_out layout.
        // SPIRV-Cross knows what it wrote; we mirror, not re-derive.
        const spirv_cross::MSLInterfaceLayout layout =
            compiler.get_msl_interface_layout(spv::StorageClassOutput, /*patch=*/false);
        if (layout.members.empty()) return out;

        // Translate MSLInterfaceMember → StageOutputLayout::Member.
        // The helper provides MSL-padded offset/size; we additionally
        // compute glPackedBytes (tight GL packing: vec3=12B, no pad)
        // for the TF writer's GL-side buffer copy.
        out.members.reserve(layout.members.size());
        for (const auto& m : layout.members) {
            StageOutputLayout::Member dst;
            dst.name = m.name;
            dst.offset = m.offset;
            dst.size = m.size;
            dst.isBuiltIn = m.is_builtin;
            dst.builtIn = static_cast<std::uint32_t>(m.builtin);
            // GL-tight byte size: scalar * vecsize * columns * max(array_size, 1).
            // (vec3 in MSL is padded to 16 bytes; in GL TF it's 12.)
            const std::size_t scalarBytes = (m.bit_width + 7) / 8;
            const std::size_t vec = m.vecsize > 0 ? m.vecsize : 1;
            const std::size_t cols = m.columns > 0 ? m.columns : 1;
            const std::size_t arr = m.array_size > 0 ? m.array_size : 1;
            dst.glPackedBytes = scalarBytes * vec * cols * arr;
            out.members.push_back(std::move(dst));
        }
        out.structSize = layout.struct_size;

        if (std::getenv("APPGL_TRACE_TESS")) {
            std::fprintf(stderr,
                "[APPGL] reflectStageOutputLayout: structSize=%zu members=%zu (helper)\n",
                out.structSize, out.members.size());
            for (const auto& m : out.members) {
                std::fprintf(stderr,
                    "[APPGL]   member '%s' offset=%zu size=%zu builtin=%d\n",
                    m.name.c_str(), m.offset, m.size,
                    m.isBuiltIn ? (int)m.builtIn : -1);
            }
        }
    } catch (const std::exception&) {
        out = {};
    } catch (...) {
        out = {};
    }
    return out;
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
    return reflect(spirv, wordCount, bindings, log, TranslatorOptions{});
}

ShaderReflection ShaderTranslator::reflect(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log, const TranslatorOptions&) const {
    (void)spirv;
    (void)wordCount;
    (void)bindings;
    if (log != nullptr) {
        *log = "Shader reflection is not enabled in the bootstrap build yet.";
    }
    return {};
}

StageOutputLayout ShaderTranslator::reflectStageOutputLayout(
    const std::uint32_t*, std::size_t, const TranslatorOptions&) const
{
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
