#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "../../include/AppGL/glcorearb.h"

namespace appgl {

inline constexpr std::uint32_t kTextureReductionModeSampleYFlipBit = 0x80000000u;
inline constexpr std::uint32_t kTextureReductionModeMask = 0x7fffffffu;

// Metal exposes 31 buffer slots per shader stage (indices 0..30). Vertex
// buffers must live in the low half so they fit MTLVertexDescriptor's
// bufferIndex range, with uniform/storage buffers stacked above them. This
// must stay in lockstep with kVertexBufferBase in MetalVertexDescriptorBuilder.mm.
struct BindingMap {
    std::uint32_t vertexBufferBase = 0;    // [ 0..16) — VBOs
    std::uint32_t uniformBufferBase = 16;  // [16..28) — UBOs
    std::uint32_t storageBufferBase = 28;  // [28..30) — SSBOs (GL 4.3+, deferred)
    // Direct Metal buffer slot for GL atomic counter binding 0. Graphics
    // keeps the legacy range, while compute repacks it around SSBO/UBO use.
    std::uint32_t atomicCounterBufferBase = 22;
    std::uint32_t multisampleStorageImageSampleBuffer = 30;
    // SPIRV-Cross emulates image atomics on pre-MSL-3.1 storage images
    // with a secondary `device atomic_* [[buffer(N)]]` argument. Keep the
    // small direct-binding CTS path out of vertex-buffer slot 0 and away
    // from the SSBO tail; active image-atomic users are packed densely.
    std::uint32_t storageImageAtomicBufferBase = 24;
    std::uint32_t textureBase = 0;         // [ 0..48) — sampled textures (GL_MAX_TEXTURE_IMAGE_UNITS)
    std::uint32_t samplerBase = 0;         // sampler state slots track textureBase 1:1
    // Storage images (imageLoad/imageStore) must live in a Metal
    // texture-slot range DISJOINT from sampled textures, otherwise a
    // shader with both `sampler2D s` at glBinding 0 and `image2D i` at
    // glBinding 0 (the GL binding namespaces are independent) lands
    // both at MSL `texture2d<T>[[texture(0)]]`. Metal only exposes one
    // texture slot pool per stage, so we partition it: slots 0..47 for
    // sampled, 48..63 for storage images (GL_MAX_IMAGE_UNITS = 16,
    // advertised in GLCapabilities.mm). Apple7+ supports 128 texture
    // arguments per stage, so 48+16=64 sits well inside the budget.
    // Fixes `shading_language_420pack.binding_samplers_texture_type_*`
    // and `layout_location.image_*` variants that declared colliding
    // glBindings.
    std::uint32_t storageImageBase = 48;
};

// Compute pipelines have no vertex inputs, so the low Metal buffer slots
// (normally reserved for VBOs on graphics pipelines) are free. SSBOs still
// allocate sequentially from slot 0; the CTS max-resource path pairs the GL
// minimum of 8 SSBOs with 8 atomic counter buffers, so compute reserves
// atomics at [8..16), the default-uniform push constant at 16, and UBOs
// above it at [17..30).
inline BindingMap makeComputeBindingMap() {
    BindingMap m;
    m.storageBufferBase = 0;   // SSBOs start at the low compute slots
    m.atomicCounterBufferBase = 8;  // [ 8..16) — atomic counter buffers
    m.uniformBufferBase = 16;  // [16..31) — default uniform (16) + UBOs (17..30)
    m.vertexBufferBase = 0;    // unused for compute
    m.multisampleStorageImageSampleBuffer = 30;
    return m;
}

struct ShaderReflection {
    struct VertexInput {
        GLuint location = 0;
        GLuint sourceLocation = 0;
        GLenum type = 0;
        std::string name;
        bool containsFp64 = false;
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
        bool containsFp64 = false;
    };

    struct ResourceBinding {
        GLuint glBinding = 0;
        GLint uniformLocation = -1;
        GLenum glType = 0;
        std::uint32_t arraySize = 1;
        std::uint32_t metalBinding = 0;
        std::size_t byteSize = 0;
        std::string name;               // block type name (always)
        bool hasInstanceName = false;    // true if GLSL had an instance name
        std::uint32_t blockArraySize = 0; // >0 for `uniform B { ... } b[N]` arrays
        // Sprint 8 B Cluster F F1 Day 2 (CKPT74): tracks whether the
        // GLSL source had an explicit `layout(binding=N)` qualifier on
        // this block (true) vs glslang auto-assigned the binding
        // value (false). Required for correct block-array binding
        // semantics — explicit bindings consume consecutive slots
        // (b[0]=N, b[1]=N+1, ...), implicit bindings default to 0
        // for ALL instances. Pre-CKPT74: all instances of a block
        // array got the same binding value. CTS layout_binding.
        // block_layout_binding_block.binding_array_size hits this.
        bool hasExplicitBinding = false;
        // True when SPIRV-Cross's `get_active_interface_variables()`
        // identifies this block's variable as live in the shader body
        // (an OpAccessChain / OpLoad reaches it). False for declared-
        // but-unused blocks — used by
        // `glGetProgramResourceiv(…REFERENCED_BY_*_SHADER)` to gate
        // the per-stage referenced bit so unused blocks don't look
        // used.
        bool active = true;
        bool multisampleStorageImage = false;
        bool multisampleStorageImageArray = false;
        GLenum storageImageTarget = 0;
        bool storageImageNonWritable = false;
        bool storageImageNonReadable = false;
        bool storageBufferWritten = false;
        std::uint32_t metalAtomicBufferBinding = 0xFFFFFFFFu;
        bool sparseStorageImageRead = false;
        bool sparseStorageImageWrite = false;
        bool containsFp64 = false;
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
    bool usesFragmentShadingRateBuiltins = false;
    bool usesFp64 = false;
    bool fp64TranslationActive = false;
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
    // Sprint 8 B Cluster F F1 Day 7 (CKPT79): link error log captured
    // for fail-propagation decisions. When `program.link()` fails with
    // a GL-spec-violation error (cross-stage binding mismatch, location
    // mismatch, etc.), the caller (GLContext::linkProgram) inspects
    // this log to decide whether to fail glLinkProgram outright or
    // fall back to per-stage SPIR-V translation. Empty on success.
    std::string linkLog;
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
    // Sprint 18 Item42: SSBO graphics-stage Option A argbuf. Force Metal
    // argument-buffer emission for this stage even when the global debug
    // env gate is unset. Used by graphics programs whose SSBO footprint can
    // exceed Metal's direct buffer-index budget.
    bool forceArgumentBuffers = false;

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

    // Sprint 20 Decision F: link-time runtime gate for AppGL df64
    // lowering. GLContext sets this from Fp64Module::isAvailable() for
    // the current Metal device; ShaderTranslator independently detects
    // whether the SPIR-V module declares any 64-bit float types.
    bool fp64EmulationAvailable = false;

    // Sprint 17 Day 7+ Bank-Group-H Phase 6-2-r Path B Component A2.
    // When true, the gl_CullDistance → [[clip_distance]] HW-slot
    // routing at ShaderTranslator.cpp:1562-1700 is suppressed for the
    // emitted MSL. Used for VS+FS programs flagged with
    // `needsCullDistancePrepass=true` — the CPU pre-pass at
    // `emulateVsCullPrepass` evaluates GL §14.6.3 per-primitive cull
    // and filters the draw, so the residual per-fragment clip from
    // the cull→clip routing must be disabled to avoid over-clipping
    // 0th vertex pixels on non-tested cull channels (Phase 2
    // empirical confirmed via CTS test design at glcCullDistance.cpp
    // :2236-2246 — 0th vertex always negative on non-tested
    // channels, would trigger unwanted [[clip_distance]] discard).
    bool disableCullDistanceClipRouting = false;

    // Sprint 18 Bank D-3 (`textures_bind_unit`): source-level
    // gl_FragCoord origin convention for fragment translation. The
    // glslang Vulkan target can tag fragment SPIR-V as OriginUpperLeft
    // even for GL-default source, so the translator must not use that
    // execution mode as the GL convention authority.
    bool fragmentCoordOriginUpperLeft = false;

    // Phase 3B.5 [metal-tess-TF]: per-patch control-point count to plumb
    // into SPIRV-Cross's TES compilation so the emitted
    //   gl_in = &spvIn[gl_PrimitiveID * N];
    // stride resolves to the linked TCS's `layout(vertices = N) out;`
    // instead of defaulting to 0 (which collapses every patch to the
    // buffer origin). Only meaningful for TES stages — ignored otherwise.
    std::uint32_t tesePatchVertices = 0;

    // Sprint 5 Phase 1 [metal-tess-TF]: Path L Class 2A — use the
    // full-precision tess level shadow buffer. When true, SPIRV-Cross's
    // TES emission reads gl_TessLevelOuter/Inner from
    // `spvTessLevelFull[primId * stride + idx]` (slot 23) instead of
    // half-precision `spvTessLevel[*].edgeTessellationFactor[idx]` (slot
    // 26). TCS emission ALSO writes to spvTessLevelFull alongside the
    // existing half-precision write (Path L extension at SPIRV-Cross
    // fork commit 635380d). Avoids half-precision rounding error on
    // tess level read-back tests like `tc2te.gl_tessLevel`.
    bool useFullPrecisionTessLevelBuffer = false;

    // Phase 7 [metal-tess-TF]: cross-stage interface wiring (Track 2,
    // scaffold). When translating TCS-as-compute, set these to the
    // linked TES's SPIR-V so spirvToMSL can walk TES's INPUT interface
    // variables and call CompilerMSL::add_msl_shader_output for each
    // USER VARYING. Tells SPIRV-Cross "the next stage reads these slots,
    // ensure your main0_out includes them at matching locations." Closes
    // the per-CP buffer stride mismatch on shapes where TCS doesn't write
    // all the user varyings TES reads (cluster A / C from SPIRV-W's
    // analysis). Builtins are filtered out — they're handled by SPIRV-
    // Cross's own gl_PerVertex propagation. No effect on non-TCS stages.
    const std::uint32_t* siblingTesInputSpirv = nullptr;
    std::size_t siblingTesInputWordCount = 0;

    // Inverse-direction sibling for the tc_barriers cluster: when
    // translating TES (vertex form OR as-compute) and the caller passed
    // the linked TCS's SPIR-V, walk TCS's OUTPUT interface variables
    // (loose top-level non-builtin non-patch varyings) and call
    // CompilerMSL::add_msl_shader_input for each USER VARYING the TES
    // does NOT itself declare. Tells SPIRV-Cross "the previous stage
    // emits extra slots at offsets X/Y/Z, pad your main0_in struct so
    // device-buffer reads find your declared inputs at the same byte
    // offsets the TCS wrote them." Closes the symmetric mismatch where
    // TCS uses its own outputs internally (after barrier()) and so
    // SPIRV-Cross can't trim main0_out down to just TES-relevant slots
    // — the per-CP stride grows beyond what TES expects. Builtins,
    // blocks, and `patch out` variables are filtered for the same
    // reason as the TCS direction. No effect on non-TES stages.
    const std::uint32_t* siblingTcsOutputSpirv = nullptr;
    std::size_t siblingTcsOutputWordCount = 0;

    // Sprint 3 [metal-mesh-GS]: when true, the geometry-shader
    // translator path emits MSL targeting Metal's `[[mesh]]` stage
    // (mesh-shader execution model) instead of the upstream's
    // non-functional vertex-form GS emission. Pairs with the
    // SPIRV-Cross fork patch
    // `third_party/patches/spirv-cross-msl-geometry-shader-as-mesh.patch`
    // which adds `msl_options.geometry_shader_as_mesh`. The patched
    // emission routes `OpEmitVertex` / `OpEndPrimitive` / `OpStore`
    // into mesh-shader infrastructure (`spvMesh.set_vertex` /
    // `set_primitive` / `set_index` / `set_primitive_count`).
    //
    // Only meaningful when `ExecutionModelGeometry` is the current
    // stage AND the device supports `MTLGPUFamilyMetal3` +
    // `MTLGPUFamilyApple7` (probed via
    // `GLCapabilities::meshShaderSupported()`). Caller resolves the
    // gate at link time + sets this flag accordingly. Programs whose
    // GS shape exceeds the patch's MVP coverage (adjacency, streams,
    // max_vertices > 3) keep this false and fall back to the existing
    // CPU GS interpreter path.
    bool forceGeometryShaderAsMesh = false;
    // Sprint 3 Phase 2 Checkpoint 11 [metal-tess-TF]: emit a kernel-exit
    // `threadgroup_barrier(mem_flags::mem_device)` on VS-as-compute
    // when the consumer is a different encoder family (mesh-render
    // pipeline, NOT another compute kernel). Path E mitigation for the
    // cross-encoder-family AIR liveness gap surfaced at Checkpoint 10.
    // OFF by default — preserves byte-identity on tess→tess consumption
    // (98 GENUINE_PASS invariant). Only set to true on the VS-compute
    // translation that feeds mesh-GS.
    bool forceComputeKernelDeviceBarrierAtExit = false;
    // Sprint 3 Phase 2 Checkpoint 11 escalation [metal-tess-TF]: emit
    // `volatile device main0_out*` for the spvOut buffer parameter (and
    // the propagated reference bindings — SPIRV-W's audit, fork commit
    // 76aacf7) on VS-as-compute targeting mesh-pipeline. Path E++
    // mitigation; supersedes Path E barrier as the load-bearing
    // mitigation when the barrier alone is insufficient (CKPT11 Step 1
    // empirical finding). Spec-mandated rather than empirical: AIR
    // optimizer is contractually obligated to preserve writes through
    // volatile pointers. OFF by default; only set on mesh-GS path.
    bool forceComputeKernelDeviceVolatileWrites = false;
    // Sprint 3 Phase 2 Checkpoint 11 escalation 3 [metal-tess-TF]:
    // emit `atomic_store_explicit(..., memory_order_relaxed)` on every
    // spvOut field write (fork commit 915d81c). Tier 3 of the
    // strength-tier ladder — non-eliminable per Apple's atomic-op
    // contract. Heaviest spec-defensible mitigation. Pairs with
    // `forceComputeKernelEntryCounterProbe` for 2-bit signal decoding
    // when atomic still doesn't deliver. OFF by default.
    bool forceComputeKernelAtomicWritesOnSpvOut = false;
    // Sprint 3 Phase 2 Checkpoint 11 diagnostic [metal-tess-TF]: emit
    // a `device atomic_uint*` counter binding at slot 27 that the
    // kernel atomically increments on entry. Distinguishes "kernel
    // doesn't execute" (counter==0) from "kernel runs but writes are
    // eliminated" (counter>0 but spvOut sentinel-preserved).
    // Orthogonal to the strength-tier mitigations.
    bool forceComputeKernelEntryCounterProbe = false;
    // Sprint 3 Phase 2 Checkpoint 14/15 [metal-tess-TF]: emit
    // `[[threads_per_grid]]` instead of `[[grid_size]]` for the
    // bounds-check size parameter (`spvStageInputSize`) on VS-as-
    // compute kernels. Path G mitigation (fork commit f19ce45) — the
    // ACTUAL fix for the kernel-doesn't-execute symptom CKPT11/12/13
    // chased through the strength-tier ladder. Apple's [[grid_size]]
    // returns (0,0,0) for compute kernels dispatched via either
    // dispatchThreads or dispatchThreadgroups on M1 Max — the bounds
    // check then fires for all threads → silent kernel skip.
    // [[threads_per_grid]] returns the dispatched size correctly.
    bool forceThreadsPerGridForStageInputSize = false;

    // Sprint 17 Day 3+ BONUS-1 [clip_control]: per-link clip_control
    // depth-mode snapshot. Drives SPIRV-Cross's `vertex.fixup_clipspace`
    // flag in `spirvToMSL`:
    //   GL_NEGATIVE_ONE_TO_ONE (GL traditional [-1,+1]) → fixup=true
    //     (emit `gl_Position.z = (z + w) * 0.5` for Metal [0,+1]).
    //   GL_ZERO_TO_ONE (D3D-like [0,+1])               → fixup=false
    //     (already Metal-compatible; no shader-side adjustment).
    //
    // Default GL_NEGATIVE_ONE_TO_ONE preserves pre-BONUS-1 behaviour
    // (fixup_clipspace was hardcoded to true). Caller (linkProgram /
    // synth-MSL site) overrides with `state->clipDepthMode()` so each
    // program captures the depth mode in effect at link time.
    //
    // Origin side (`GL_LOWER_LEFT` vs `GL_UPPER_LEFT`) is not encoded
    // as a link-time value, but some renderbuffer-backed clip-control
    // draws need an optional draw-time Y-sign parameter so
    // MetalFrameGraph can keep the viewport rectangle fixed and flip
    // the mapping inside it. Off by default so ordinary texture/default
    // framebuffer programs keep the legacy viewport/readback contract.
    bool enableClipControlYSignFixup = false;
    GLenum clipDepthMode = GL_NEGATIVE_ONE_TO_ONE;
    std::string spirvEntryPointName;
    std::unordered_map<std::uint32_t, std::uint32_t> specializationConstants;
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
        std::uint8_t baseType = 0; // 0=float, 1=int, 2=uint
        bool isBuiltIn = false;
        std::uint32_t builtIn = 0; // spv::BuiltIn enum when isBuiltIn
    };
    std::vector<Member> members;
};

struct StageOutputComponentCount {
    std::uint64_t userComponents = 0;
    bool valid = false;
};

class ShaderTranslator {
public:
    std::vector<std::uint32_t> compileGLSL(std::string_view source, GLenum stage, int version, std::string* log) const;
    std::vector<std::uint32_t> compileGLSLStageProgram(const std::vector<std::string>& sources, GLenum stage, int version, std::string* log) const;
    std::string spirvToMSL(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const;
    std::string spirvToMSL(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log, const TranslatorOptions& options) const;
    ShaderReflection reflect(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log) const;
    ShaderReflection reflect(const std::uint32_t* spirv, std::size_t wordCount, const BindingMap& bindings, std::string* log, const TranslatorOptions& options) const;
    // Phase 3B.5: reflect the TES output struct layout under the same
    // MSL options used by the TES-as-compute translation. Returns
    // `structSize == 0` + empty `members` on failure (or when the
    // stage has no outputs to reflect).
    StageOutputLayout reflectStageOutputLayout(const std::uint32_t* spirv, std::size_t wordCount, const TranslatorOptions& options) const;
    StageOutputComponentCount reflectStageOutputComponentCount(
        const std::uint32_t* spirv, std::size_t wordCount) const;

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
