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
    std::uint32_t textureBase = 0;         // [ 0..48) — sampled textures (GL_MAX_TEXTURE_IMAGE_UNITS)
    std::uint32_t samplerBase = 0;         // sampler state slots track textureBase 1:1
    // Storage images (imageLoad/imageStore) must live in a Metal
    // texture-slot range DISJOINT from sampled textures, otherwise a
    // shader with both `sampler2D s` at glBinding 0 and `image2D i` at
    // glBinding 0 (the GL binding namespaces are independent) lands
    // both at MSL `texture2d<T>[[texture(0)]]`. Metal only exposes one
    // texture slot pool per stage, so we partition it: slots 0..47 for
    // sampled, 48..55 for storage images (GL_MAX_IMAGE_UNITS = 8,
    // advertised in GLCapabilities.mm). Apple7+ supports 128 texture
    // arguments per stage, so 48+8=56 sits well inside the budget.
    // Fixes `shading_language_420pack.binding_samplers_texture_type_*`
    // and `layout_location.image_*` variants that declared colliding
    // glBindings.
    std::uint32_t storageImageBase = 48;
};

// Compute pipelines have no vertex inputs, so the low 16 Metal buffer
// slots (normally reserved for VBOs on graphics pipelines) are free.
// This lets us give compute SSBOs 16 slots — comfortably above the GL
// 4.3 spec floor of GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS ≥ 8. The
// default-uniform push-constant stays at slot 16 to match the
// hardcoded `atIndex:16` in MetalFrameGraph::encodeComputeDispatch,
// and user UBOs stack above it at [17..30).
inline BindingMap makeComputeBindingMap() {
    BindingMap m;
    m.storageBufferBase = 0;   // [ 0..16) — SSBOs: 16 slots (spec floor 8)
    m.uniformBufferBase = 16;  // [16..31) — default uniform (16) + UBOs (17..30)
    m.vertexBufferBase = 0;    // unused for compute
    return m;
}

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
        bool isRowMajor = false;  // SPIR-V DecorationRowMajor for matrices
        std::uint32_t arraySize = 0; // >0 if the member is an array (element count)
        // True if the GLSL declaration was an array — including
        // unbounded-array SSBO members (`vec4 data[];`) where
        // `arraySize` stays 0. GL 4.6 §7.3.1 says such members
        // report their resource name with the "[0]" suffix, so
        // we need this flag to distinguish them from non-array
        // members. Sized arrays have arraySize > 0 AND isArray.
        bool isArray = false;
        // Byte stride between consecutive array elements
        // (`GL_ARRAY_STRIDE`). For non-array members, 0. SPIR-V's
        // DecorationArrayStride on the member slot maps 1:1.
        GLint arrayStride = 0;
        // Byte stride between matrix columns (row_major) or rows
        // (column_major) (`GL_MATRIX_STRIDE`). For non-matrix
        // members, 0.
        GLint matrixStride = 0;
        // GL 4.6 §7.3.1 `GL_TOP_LEVEL_ARRAY_SIZE`: for an SSBO
        // buffer variable, the array size of the top-level block
        // member that contains it. `buffer B { UU a[3]; }` has
        // every leaf of `a[i].…` reporting top_level=3;
        // `buffer B { mat4 b; }` has b reporting 1.
        // Default 1 (non-array / scalar top).
        GLint topLevelArraySize = 1;
        // GL 4.6 §7.3.1 `GL_TOP_LEVEL_ARRAY_STRIDE`: byte stride
        // between consecutive top-level array elements. Non-zero
        // only when the member is inside a top-level array. CTS
        // `top-level-array` asserts > 0 for a multi-dim SSBO leaf.
        GLint topLevelArrayStride = 0;
    };

    struct ResourceBinding {
        GLuint glBinding = 0;
        std::uint32_t metalBinding = 0;
        std::size_t byteSize = 0;
        std::string name;               // block type name (always)
        bool hasInstanceName = false;    // true if GLSL had an instance name
        std::uint32_t blockArraySize = 0; // >0 for `uniform B { ... } b[N]` arrays
        // True when SPIRV-Cross's `get_active_interface_variables()`
        // identifies this block's variable as live in the shader body
        // (an OpAccessChain / OpLoad reaches it). False for declared-
        // but-unused blocks — used by
        // `glGetProgramResourceiv(…REFERENCED_BY_*_SHADER)` to gate
        // the per-stage referenced bit so unused blocks don't look
        // used.
        bool active = true;
        std::vector<UniformMember> members;
    };

    std::vector<VertexInput> vertexInputs;
    std::vector<ResourceBinding> uniformBlocks;
    std::vector<ResourceBinding> sampledTextures;
    // Shader-storage buffer objects (GL 4.3+). Populated for every stage
    // but primarily consumed by the compute-dispatch path, which binds
    // them against GL_SHADER_STORAGE_BUFFER indexed bindings.
    std::vector<ResourceBinding> storageBuffers;
    // Storage images (imageLoad/imageStore). Separate from sampledTextures
    // because the GL binding model differs — these are bound via
    // glBindImageTexture(unit, tex, …) and the dispatch-time resolver
    // reads the texture unit's imageBindings[] slot directly, not a
    // sampler uniform value.
    std::vector<ResourceBinding> storageImages;
    bool usesPointSize = false;
};

// Compute shader execution modes extracted from SPIR-V.
struct ComputeExecutionModes {
    std::uint32_t localSizeX = 1;
    std::uint32_t localSizeY = 1;
    std::uint32_t localSizeZ = 1;
};

// Phase 8X Group 4d follow-up⁵ — output of `compileGLSLProgram`. Both
// blobs come from a single `glslang::TProgram::link()` + `mapIO()` pass,
// so cross-stage varying interface variables get coordinated SPIR-V
// `DecorationLocation` values even when the original GLSL source carries
// no explicit `layout(location=N)` qualifiers on the varyings. This is
// required for SPIRV-Cross to subsequently emit matching `[[user(locN)]]`
// Metal attributes on `main0_out` (vertex) and `main0_in` (fragment).
//
// Why this matters: when each stage is compiled through its own private
// TProgram (the per-stage `compileGLSL` path used at glCompileShader time),
// glslang's auto-location pass runs over each stage in isolation. Even
// though the assignment algorithm is deterministic per-stage, the resulting
// vertex-output and fragment-input locations only match by accident — and
// SPIRV-Cross's de-duplicating member-name mangler then emits structs like
// `main0_out { float4 m_27_color; }` (vertex) vs `main0_in { float4
// m_31_color; }` (fragment) where the member-id prefix differs and the
// `[[user(locN)]]` attributes are either missing or mismatched. Metal then
// rejects the pipeline at `MTLRenderPipelineState` creation time with a
// "vertex output ... does not match fragment input" error. See BAR's
// `phase-8x-group-4d-followup4-verification.md` for the captured NSError
// text and the per-program failure shape.
struct LinkedProgramSpirv {
    std::vector<std::uint32_t> vertexSpirv;
    std::vector<std::uint32_t> fragmentSpirv;
    bool linkSucceeded = false;
};

// Tessellation execution mode properties extracted from SPIR-V.
struct TessellationModes {
    int outputVertices = 0;           // from TCS ExecutionModeOutputVertices
    GLenum genMode = GL_TRIANGLES;    // GL_TRIANGLES, GL_QUADS, GL_ISOLINES (from TES)
    GLenum genSpacing = GL_EQUAL;     // GL_EQUAL, GL_FRACTIONAL_EVEN, GL_FRACTIONAL_ODD
    GLenum genVertexOrder = GL_CCW;   // GL_CCW, GL_CW
    bool pointMode = false;
};

// Extract tessellation execution modes from compiled SPIR-V for a TCS or TES stage.
TessellationModes extractTessellationModes(const std::uint32_t* spirv, std::size_t wordCount);

// Extract compute-shader `layout(local_size_x/y/z = N) in;` values from
// SPIR-V. Returns (1,1,1) if the shader lacks the decoration (which
// means the application is using default thread group dimensions —
// glslang always emits the decoration for compute, but defensive floor
// keeps dispatchThreadgroups from getting a zero size).
ComputeExecutionModes extractComputeModes(const std::uint32_t* spirv, std::size_t wordCount);

// Per-call overrides for `spirvToMSL`. Default-constructed options reproduce
// the env-driven behaviour that predated Phase 1 of the Metal tess pipeline;
// callers that need tess-stage MSL regardless of the `APPGL_ENABLE_METAL_TESS`
// env gate (e.g. link-time tess-program translation) set `forceTessellation`.
struct TranslatorOptions {
    // When true, SPIRV-Cross tess options are applied to TCS/TES stages
    // even if APPGL_ENABLE_METAL_TESS is unset. No effect on non-tess
    // stages. Env gate still forces the options on when set — this field
    // only UPGRADES the decision from "off by default" to "on for this
    // call".
    bool forceTessellation = false;

    // Phase 3 of the metal-tess project: when true, the VS translator
    // emits the vertex shader as a Metal compute kernel that captures
    // per-vertex output into a buffer at
    // `msl_options.shader_output_buffer_index` (buffer 28 in the
    // default layout). Requires the translated stage to be
    // ExecutionModelVertex; no effect on other stages. Pairs with
    // `forceTessellation` on the TCS / TES translation so the full
    // pipeline can run on Metal's native tessellator. Encoded by
    // MetalFrameGraph as a pre-TCS compute dispatch that seeds the
    // TCS's `[[stage_in]]` descriptor.
    bool forceVertexForTessellation = false;

    // Phase 3B groundwork [metal-tess-TF]: request a TES-as-compute
    // emission so the MSL body can run in a compute dispatch instead of
    // the Metal tessellator's `[[patch(...)]] vertex` function. The
    // compute form produces output vertices from a pre-computed domain
    // -coord buffer (written by a separate domain-point generator
    // kernel) rather than from Metal's built-in `[[position_in_patch]]`.
    // Consumers capture the output directly into the bound transform-
    // feedback buffer.
    //
    // Until SPIRV-Cross is fork-patched to honour this flag (Phase
    // 3B.2), setting it produces the same MSL as
    // `forceTessellation=true` — the translation call is wired but
    // the emission is unchanged. Probing / pipeline-state build stays
    // optional and errors out cleanly downstream.
    bool forceTessEvalAsCompute = false;

    // Phase 3B.5 [metal-tess-TF]: per-patch control-point count to plumb
    // into SPIRV-Cross's TES compilation so the emitted
    //   gl_in = &spvIn[gl_PrimitiveID * N];
    // stride resolves to the linked TCS's `layout(vertices = N) out;`
    // instead of defaulting to 0 (which collapses every patch to the
    // buffer origin). Only meaningful for TES stages — ignored otherwise.
    std::uint32_t tesePatchVertices = 0;
};

// Phase 3B.5 [metal-tess-TF]: stage-output struct layout. Populated for
// TES-as-compute programs so the transform-feedback writer can locate
// each GL-declared TF varying by name inside SPIRV-Cross's emitted
// `main0_out` struct and deposit the bytes at the right TF-buffer
// offset.
struct StageOutputLayout {
    // Byte size of the full struct in MSL memory layout. Matches the
    // stride between consecutive per-vertex output slots in the
    // TES-compute output buffer.
    std::size_t structSize = 0;
    struct Member {
        std::string name;          // SPIRV-Cross-emitted member name
                                   // (matches the GLSL out-variable name
                                   // for user varyings; "gl_Position"
                                   // for the position builtin).
        std::size_t offset = 0;    // byte offset inside the MSL struct
        std::size_t size = 0;      // byte size in MSL memory (padded:
                                   // vec3 → 16, the extra 4 bytes are
                                   // padding that MSL reads but GL
                                   // doesn't write to TF).
        std::size_t glPackedBytes = 0; // byte size in GL's TF layout
                                   // (tightly packed: vec3 → 12,
                                   // float[4] → 16, etc.). What the TF
                                   // writer copies to the GL-side
                                   // GL_TRANSFORM_FEEDBACK_BUFFER.
        bool isBuiltIn = false;
        std::uint32_t builtIn = 0; // spv::BuiltIn enum when isBuiltIn
    };
    std::vector<Member> members;
};

class ShaderTranslator {
public:
    std::vector<std::uint32_t> compileGLSL(std::string_view source, GLenum stage, int version, std::string* log) const;
    std::string spirvToMSL(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const;
    std::string spirvToMSL(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log, const TranslatorOptions& options) const;
    ShaderReflection reflect(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const;
    // Phase 3B.5: reflect the TES output struct layout under the same
    // MSL options used by the TES-as-compute translation. Returns
    // `structSize == 0` + empty `members` on failure (or when the
    // stage has no outputs to reflect).
    StageOutputLayout reflectStageOutputLayout(const std::uint32_t* spirv, std::size_t wordCount, const TranslatorOptions& options) const;

    // Phase 8X Group 4d follow-up⁵ — link-time co-compile entry point.
    // Re-parses both vertex and fragment GLSL into a single
    // `glslang::TProgram` and runs `link()` followed by `mapIO()` so the
    // cross-stage varying interface gets coordinated location decorations.
    // Returns `linkSucceeded == false` on any failure (parse, link, or IO
    // map) with `log` populated with the failing stage tag and glslang's
    // info log; callers may then fall back to the per-stage cached SPIR-V
    // path that `compileShader` already produced via `compileGLSL`.
    LinkedProgramSpirv compileGLSLProgram(std::string_view vertexSource,
                                           std::string_view fragmentSource,
                                           int version,
                                           std::string* log) const;
};

}  // namespace appgl
