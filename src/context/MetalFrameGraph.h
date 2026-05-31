#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "../../include/AppGL/glcorearb.h"
#include "AppGLCommandReasons.h"
#include "AppGLSubmissionGroups.h"
#include "../shader/ShaderTranslator.h"
#include "../state/MatrixStateMirror.h"

#ifdef __OBJC__
@class CAMetalLayer;
@protocol MTLDevice;
@protocol MTLCommandQueue;
@protocol MTLTexture;
#endif

namespace appgl {

class GLContext;
class GLObjectStore;
class GLStateTracker;
class MetalCommandSubmission;

// Describes a single draw call. Phase A Group 7 delivers a minimal draw path:
// one vertex attribute (vec3 position at attribute 0) and one fragment uniform
// (vec4 color). Later groups extend this to cover the full vertex/fragment
// resource table once the real GLSL→MSL translator lands.
struct MetalDrawInfo {
    GLenum mode = 0;
    GLsizei vertexCount = 0;
    GLsizei baseVertex = 0;
    // Raw vertex buffer bytes (already at the attribute start offset).
    const void* positions = nullptr;
    std::size_t positionByteCount = 0;
    std::size_t positionStride = 0;
    GLint positionComponents = 3;
    // Indexed draws: nullptr for glDrawArrays.
    const void* indices = nullptr;
    GLsizei indexCount = 0;
    GLenum indexType = 0;
    // Uniforms.
    GLfloat uniformColor[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    // Pipeline state toggles.
    bool depthTestEnabled = false;
    GLenum depthFunc = GL_LESS;
    bool depthWriteMask = true;
    bool cullFaceEnabled = false;
    GLenum cullFaceMode = GL_BACK;
    GLenum frontFace = GL_CCW;
    bool wireframe = false;
    std::uint32_t sampleMask = 0xFFFFFFFFu;
    GLenum fragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
    // Sprint 7 Phase 1 #11 (CKPT57): GL_STENCIL_TEST + glStencilFunc /
    // glStencilOp / glStencilMask plumb-through. Default state matches
    // GL spec: test disabled, ALWAYS compare, all-KEEP ops, full masks.
    // Per-face: front/back drawn separately because GL allows asymmetric
    // stencil state via glStencil*Separate. When stencilTestEnabled is
    // false, depthStencilStateForDraw leaves the descriptor's
    // frontFaceStencil/backFaceStencil at Metal defaults (Always +
    // Keep), which is the correct behaviour per GL 4.6 §17.3.5
    // ("if there is no stencil buffer, or if the stencil test is not
    // enabled, the stencil test always passes").
    bool stencilTestEnabled = false;
    GLenum stencilFrontFunc = GL_ALWAYS;
    GLint stencilFrontRef = 0;
    GLuint stencilFrontValueMask = 0xFFFFFFFFu;
    GLenum stencilFrontFail = GL_KEEP;
    GLenum stencilFrontDepthFail = GL_KEEP;
    GLenum stencilFrontDepthPass = GL_KEEP;
    GLuint stencilFrontWriteMask = 0xFFFFFFFFu;
    GLenum stencilBackFunc = GL_ALWAYS;
    GLint stencilBackRef = 0;
    GLuint stencilBackValueMask = 0xFFFFFFFFu;
    GLenum stencilBackFail = GL_KEEP;
    GLenum stencilBackDepthFail = GL_KEEP;
    GLenum stencilBackDepthPass = GL_KEEP;
    GLuint stencilBackWriteMask = 0xFFFFFFFFu;
    // Diagnostic string that identifies the caller for error messages.
    std::string debugLabel;
};

struct TranslatedDrawPlanShaderSlots {
    bool vertexMslUsesArgBuf = false;
    bool fragmentMslUsesArgBuf = false;
    bool vertexHasSSBOSizeBuffer = false;
    bool fragmentHasSSBOSizeBuffer = false;
    bool fragmentNeedsFragCoordParams = false;
    bool fragmentNeedsGlNumSamplesArgBuf = false;
    bool vertexNeedsFragmentShadingRateState = false;
    bool vertexUsesMultiviewViewMask = false;
    bool fragmentUsesMultiviewViewMask = false;
    std::int32_t vertexClipControlYSignSlot = -1;
    std::int32_t vertexReductionModesSlot = -1;
    std::int32_t vertexLodBiasesSlot = -1;
    std::int32_t vertexBorderClampModesSlot = -1;
    std::int32_t vertexBorderClampColorsSlot = -1;
    std::int32_t vertexImplicitLodBiasCorrectionSlot = -1;
    std::int32_t fragmentReductionModesSlot = -1;
    std::int32_t fragmentLodBiasesSlot = -1;
    std::int32_t fragmentBorderClampModesSlot = -1;
    std::int32_t fragmentBorderClampColorsSlot = -1;
    std::int32_t fragmentImplicitLodBiasCorrectionSlot = -1;
};

struct TranslatedDrawPlan {
    bool valid = false;
    std::uint64_t generation = 0;
    std::uint64_t pipelineCacheKey = 0;
    std::uint32_t colorFormat = 0;
    std::uint32_t attachmentSampleCount = 1;
    bool forcePerSampleFS = false;
    bool hasFragmentStage = false;
    bool vertexUsesArgumentBuffer = false;
    bool fragmentUsesArgumentBuffer = false;
    bool useArgumentBuffers = false;
    bool vertexNeedsSSBOSizeBuffer = false;
    bool fragmentNeedsSSBOSizeBuffer = false;
    bool fragmentNeedsFragCoordParams = false;
    bool fragmentNeedsGlNumSamplesArgBuf = false;
    bool vertexNeedsFragmentShadingRateState = false;
    bool clipControlShaderYFixup = false;
    bool clipControlInvertsWinding = false;
    bool vertexUsesMultiviewViewMask = false;
    bool fragmentUsesMultiviewViewMask = false;
    TranslatedDrawPlanShaderSlots shaderSlots;
};

// Describes a draw call using a translated (GLSL→MSL) shader pipeline.
struct TranslatedDrawInfo {
    AppGLSubmissionGroup submissionGroup;
    AppGLSubmissionGroupKind fallbackSubgroupKind =
        AppGLSubmissionGroupKind::None;

    GLenum mode = 0;
    GLsizei vertexCount = 0;
    GLsizei baseVertex = 0;

    // Raw vertex buffer bytes at the attribute start offset.
    // Used as fallback when metalVertexBuffer is null (headless / no VBO).
    const void* vertexData = nullptr;
    std::size_t vertexDataByteCount = 0;
    std::size_t vertexStride = 0;

    // Direct Metal buffer binding (OPT-5).  When non-null the pre-uploaded
    // VBO Metal buffer is bound directly, bypassing the ring-buffer memcpy.
    void* metalVertexBuffer = nullptr;
    std::size_t metalVertexBufferOffset = 0;
    GLuint glVertexBuffer = 0;

    // Per-attribute layout within the interleaved vertex buffer.  Each entry
    // describes one enabled vertex attribute's location and its byte offset
    // within a single stride.  When non-empty, all attributes map to Metal
    // buffer index 0 with these offsets; when empty, the legacy single-
    // attribute (position-only, offset 0) behaviour is used.
    //
    // Phase 8X Group 4d follow-up¹⁴ — the GL VAO record fields
    // (`glType/glComponentCount/glNormalized/glIsInteger`) are the
    // *source of truth* for the MTLVertexFormat of each attribute, not
    // the shader-reflected scalar type. Before follow-up¹⁴ the vertex
    // descriptor derived attribute formats from `ShaderReflection::
    // vertexInputs[i].type` (always `Float4`/`Float3`/etc.), which
    // produced a structural `MTLVertexFormatFloat4` entry for any
    // `in vec4 color` input even when the VBO layout stored 4×UBYTE
    // normalized colors. The GPU then reinterpreted 4 bytes of
    // UBYTE4 + 12 bytes of the next vertex as `float4`, producing the
    // NaN-smeared glyph text BAR diagnosed in followup¹³-verification
    // §Smoking-Gun. The fix is to carry the VAO's `glVertexAttribPointer`
    // parameters end-to-end and derive the Metal format from
    // `vaoTypeToMTLFormat(glType, glComponentCount, glNormalized,
    // glIsInteger)` at encode time.
    struct VertexAttributeLayout {
        GLuint location = 0;
        std::size_t offset = 0;
        // VAO-derived format hints (follow-up¹⁴). Defaults match the
        // pre-follow-up¹⁴ shader-reflected `Float4` assumption so that
        // call sites which have not yet been updated keep working.
        GLenum glType = GL_FLOAT;
        GLint glComponentCount = 4;
        GLboolean glNormalized = GL_FALSE;
        bool glIsInteger = false;
    };
    std::vector<VertexAttributeLayout> vertexAttributeLayouts;

    // Additional vertex buffer bindings for multi-VBO setups (e.g. per-instance
    // attribute buffers with glVertexAttribDivisor).  Buffer index 0 is the
    // primary vertexData above; these start at Metal buffer index 1.
    struct ExtraVertexBuffer {
        const void* data = nullptr;
        std::size_t byteCount = 0;
        std::size_t stride = 0;
        GLuint divisor = 0;  // 0=per-vertex, 1+=per-instance
        std::vector<VertexAttributeLayout> attributes;
        std::vector<std::uint8_t> ownedData;
        bool constantStep = false;
        // Direct Metal buffer binding (OPT-5).
        void* metalBuffer = nullptr;
        std::size_t metalBufferOffset = 0;
        GLuint glBuffer = 0;
    };
    std::vector<ExtraVertexBuffer> extraVertexBuffers;

    // Instanced draws.
    GLsizei instanceCount = 1;
    GLuint baseInstance = 0;

    // Indexed draws (nullptr for glDrawArrays).
    const void* indices = nullptr;
    GLsizei indexCount = 0;
    GLenum indexType = 0;

    // Direct Metal index buffer binding (OPT-5).
    void* metalIndexBuffer = nullptr;
    std::size_t metalIndexBufferOffset = 0;
    GLuint glIndexBuffer = 0;

    // Per-stage uniform data laid out to match the SPIRV-Cross-generated
    // push-constant struct.  Each stage gets its own buffer because the
    // vertex and fragment stages may declare different subsets of the
    // program's bare uniforms, producing different struct layouts.
    // Non-owning: the caller keeps the backing storage alive until
    // encodeTranslatedDraw returns (typically thread-local scratch buffers).
    const std::uint8_t* vertexUniformData = nullptr;
    std::size_t vertexUniformSize = 0;
    const std::uint8_t* fragmentUniformData = nullptr;
    std::size_t fragmentUniformSize = 0;

    // Phase 8X Group 4d follow-up⁷ — per-draw texture/sampler binding
    // plumbing. Prior to this round, `encodeTranslatedDraw` bound zero
    // MTLTexture / MTLSamplerState objects to the render encoder: the
    // shader translator correctly emitted `[[texture(N)]]` /
    // `[[sampler(N)]]` arguments on the fragment stage and the reflection
    // carried the binding indices, but nothing ever wired the GL
    // texture-unit state through to the Metal encoder calls. The
    // fragment shader's `texture.sample(sampler, uv)` therefore read
    // from an unbound slot (undefined on Apple Silicon, typically zero
    // on Mac2-family) — this is the structural root cause of the
    // "smeared / double-exposed" glyph artifact BAR captured in
    // followup⁶ verification §Visual.
    //
    // Both vectors are non-owning; `metalTexture` / `metalSamplerState`
    // must outlive the encode call. GLContext::drawArrays (and its
    // instanced / indexed siblings) populate these vectors right after
    // the uniform buffer push by walking the program's fragment (and
    // vertex) sampler uniforms, resolving each one to its bound texture
    // object via the GL texture-unit state, and snapping pointers to
    // the cached MTLTexture / MTLSamplerState on the texture object
    // (lazily rebuilt via `rebuildTextureSamplerState`).
    //
    // `metalSlot` is the SPIRV-Cross `[[texture(N)]]` / `[[sampler(N)]]`
    // slot from `ShaderReflection::sampledTextures[i].metalBinding`,
    // which is `BindingMap::textureBase + glBinding = glBinding` under
    // the default BindingMap. The encoder uses the same slot for both
    // the texture and the sampler state, matching SPIRV-Cross's MSL
    // output pattern where sampled images are decomposed into parallel
    // `[[texture(N)]]` / `[[sampler(N)]]` arguments.
    struct TextureBinding {
        std::uint32_t metalSlot = 0;
        void* metalTexture = nullptr;       // id<MTLTexture>
        void* metalSamplerState = nullptr;  // id<MTLSamplerState>
        // Non-owning backing buffer for buffer-texture MTLTexture views.
        void* textureBufferBackingMetalBuffer = nullptr; // id<MTLBuffer>
        void* imageAtomicMetalBuffer = nullptr; // id<MTLBuffer>
        std::size_t imageAtomicBufferOffset = 0;
        std::uint32_t imageAtomicBufferSlot = 0xFFFFFFFFu;
        std::uint32_t reductionMode = GL_WEIGHTED_AVERAGE_ARB;
        float lodBias = 0.0f;
        std::uint32_t borderClampMask = 0;
        std::array<std::int32_t, 4> borderColor = {0, 0, 0, 0};
    };
    std::vector<TextureBinding> fragmentTextures;
    std::vector<TextureBinding> vertexTextures;

    // Phase 8X Group 4d follow-up⁸ — diagnostic-only GL program name,
    // populated by GLContext::drawArrays / drawArraysInstanced /
    // drawElements alongside the other tdi fields. Used exclusively by
    // the first-draw-per-program NSLog in `encodeTranslatedDraw` so
    // BAR-side grep can correlate binding output back to the program
    // identity they already see in their `drawArrays` instrumentation.
    // Not used for any correctness decision — leaving it at 0 is safe
    // (the log will read "program=0" for that draw). Non-owning.
    GLuint program = 0;
    // Non-zero when a separable program pipeline spliced a fragment stage
    // onto this program container. The Phase-2 structural key uses this to
    // distinguish same-container/different-fragment-program recipes without
    // hashing shader source text on every draw.
    GLuint pipelineEmulationFragmentProgram = 0;
    // True when the draw is fed by SSO program-pipeline state or by active
    // subroutine-uniform state. Until those hidden inputs are part of the
    // structural key, the Phase-2 plan cache routes the draw through the
    // direct encoder path.
    bool pipelineOrSubroutinePlanCacheUnsafe = false;

    // Pipeline state toggles.
    bool depthTestEnabled = false;
    GLenum depthFunc = GL_LESS;
    bool depthWriteMask = true;
    bool cullFaceEnabled = false;
    GLenum cullFaceMode = GL_BACK;
    GLenum frontFace = GL_CCW;
    bool wireframe = false;
    // GL_SAMPLE_MASK dynamic raster state. When GL_SAMPLE_MASK is disabled
    // this stays all-ones; otherwise GLContext snapshots glSampleMaski(0).
    std::uint32_t sampleMask = 0xFFFFFFFFu;
    // Sprint 7 Phase 1 #11 (CKPT57): per-draw stencil state mirroring
    // GL_STENCIL_TEST + glStencil[Func|Op|Mask][Separate]. Threaded
    // through populateTranslatedDrawFixedFunctionState and consumed by
    // depthStencilStateForDraw at MetalFrameGraph.mm:4278. Enables
    // KHR-GL46.tessellation_shader.single.primitive_coverage's two-
    // phase stencil-replace + stencil-notequal pattern (and any other
    // CTS test that depends on stencil-test correctness).
    bool stencilTestEnabled = false;
    GLenum stencilFrontFunc = GL_ALWAYS;
    GLint stencilFrontRef = 0;
    GLuint stencilFrontValueMask = 0xFFFFFFFFu;
    GLenum stencilFrontFail = GL_KEEP;
    GLenum stencilFrontDepthFail = GL_KEEP;
    GLenum stencilFrontDepthPass = GL_KEEP;
    GLuint stencilFrontWriteMask = 0xFFFFFFFFu;
    GLenum stencilBackFunc = GL_ALWAYS;
    GLint stencilBackRef = 0;
    GLuint stencilBackValueMask = 0xFFFFFFFFu;
    GLenum stencilBackFail = GL_KEEP;
    GLenum stencilBackDepthFail = GL_KEEP;
    GLenum stencilBackDepthPass = GL_KEEP;
    GLuint stencilBackWriteMask = 0xFFFFFFFFu;

    // GL 4.6 §14.6.5 / GL_ARB_polygon_offset_clamp — depth bias for
    // polygon offset. Plumbed so the render encoder can call
    // setDepthBias:slopeScale:clamp: before each draw. `enabled`
    // mirrors GL_POLYGON_OFFSET_{FILL,LINE,POINT}; when disabled,
    // Metal gets zero-bias.
    bool polygonOffsetEnabled = false;
    GLfloat polygonOffsetFactor = 0.0f;
    GLfloat polygonOffsetUnits = 0.0f;
    GLfloat polygonOffsetClamp = 0.0f;

    // GL_RASTERIZER_DISCARD: when true, Metal pipeline has
    // rasterizationEnabled=NO — the VS runs for side effects (SSBO
    // writes, transform feedback) but no fragment shader stage is
    // required. This lets SPIRV-Cross's `vertex void main0` (emitted
    // for VS-only shaders with no gl_Position assignment, common in
    // SSBO-write-only VS tests) build as a valid Metal pipeline.
    bool rasterizerDiscard = false;

    // Phase 6-1d: GL 4.0 / ARB_sample_shading state snapshot. When
    // `sampleShadingEnabled` is true AND the color attachment is MS,
    // the fragment shader must run per-sample with at least
    // `minSampleShading * sampleCount` unique invocations per pixel.
    // Metal doesn't have a direct "force N samples per pixel" knob —
    // per-sample invocation triggers automatically when the FS reads
    // `[[sample_id]]` or `[[sample_position]]`. For GL_SAMPLE_SHADING
    // to work on shaders that don't already read gl_SampleID, a
    // future phase (6-1e+) will either rewrite the FS MSL to inject
    // a `[[sample_id]]` read OR post-process SPIRV-Cross output to
    // add the attribute. This field makes the state available at
    // pipeline-build time.
    bool sampleShadingEnabled = false;
    float minSampleShading = 0.0f;
    GLenum fragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
    struct FragmentShadingRateShaderState {
        std::uint32_t apiRate = 0;
        std::uint32_t attachmentRate = 0;
        std::uint32_t combinerOp0 = 0;
        std::uint32_t combinerOp1 = 0;
    };
    FragmentShadingRateShaderState fragmentShadingRateShaderState;

    // RC-A02: viewport state.  Plumbed from glViewport so Metal's render
    // encoder receives the correct viewport rectangle.
    GLint viewportX = 0;
    GLint viewportY = 0;
    GLsizei viewportWidth = 0;
    GLsizei viewportHeight = 0;
    GLdouble depthRangeNear = 0.0;
    GLdouble depthRangeFar = 1.0;
    // Sprint 15 Q3-Option-B Day 8 [metal-viewport-array]: per-viewport-
    // index array (GL 4.1 ARB_viewport_array). When `viewportArrayCount
    // > 1` the encoder binds all entries via `setViewports:count:`
    // instead of the single-viewport `setViewport:`. Required for any
    // shader that writes gl_ViewportIndex (per-primitive viewport
    // selection). When `viewportArrayCount <= 1`, the single-viewport
    // path is used. Each entry gives an independent rectangle + depth
    // range; SPIRV-Cross emits `[[viewport_array_index]]` on the VS or
    // mesh-shader output to drive the selection.
    static constexpr std::size_t kMaxDrawViewports = 16;
    struct ViewportEntry {
        GLfloat originX = 0.0f;
        GLfloat originY = 0.0f;
        GLfloat width = 0.0f;
        GLfloat height = 0.0f;
        GLdouble depthNear = 0.0;
        GLdouble depthFar = 1.0;
    };
    ViewportEntry viewportArray[kMaxDrawViewports] = {};
    std::size_t viewportArrayCount = 0;

    // Sprint 17 Day 3+ BONUS-1 / Sprint 21 A-2 [clip_control]: per-draw
    // origin snapshot. Legacy paths use it to choose the Metal viewport
    // origin; translated vertex shaders use an injected draw-time Y sign
    // so the viewport rectangle stays fixed while the clip origin flips
    // the mapping inside it.
    GLenum clipOrigin = GL_LOWER_LEFT;
    // The injected Y-sign parameter is deliberately inert unless the
    // draw target is on the renderbuffer-backed clip-control path. Texture
    // FBOs and the default framebuffer keep the legacy viewport/readback
    // orientation contract.
    bool clipControlYSignFixupEnabled = false;
    // True only when the caller knows this draw used a GL Y-up producer path
    // under LOWER_LEFT clip origin, so texture readback must undo that
    // viewport Y-flip. Ordinary FBO draws leave this false.
    bool markColorAttachmentReadbackFlip = false;

    // GL 4.6 §14.5.1 / GL_SCISSOR_TEST. When enabled, fragments outside
    // the box are discarded. Metal has no separate "scissor enabled"
    // flag — `setScissorRect:` always applies. To mirror the GL
    // convention, the pipeline translator sets the scissor rect to the
    // viewport when the test is disabled (identity match) and to the
    // app's rect when enabled. Zero-dimension scissors are clamped to
    // 1x1 at position (width, height) outside the viewport so no
    // fragments fall inside — this covers the CTS
    // `viewport_array.scissor_zero_dimension` expectation that all
    // fragments be discarded. `scissorValid` is false when the rect is
    // entirely outside the render target (e.g. width=0 or fully
    // off-screen negative origin) — the encoder then sets a 1x1 rect
    // outside the target instead of calling through with a Metal-invalid
    // descriptor.
    bool scissorTestEnabled = false;
    GLint scissorX = 0;
    GLint scissorY = 0;
    GLsizei scissorWidth = 0;
    GLsizei scissorHeight = 0;
    // Sprint 16 Day 3 [viewport_array]: per-index scissor rect array,
    // sister to viewportArray. Required because Metal pairs viewport
    // and scissor by index — a `setViewports:count:N` MUST be matched
    // with `setScissorRects:count:N` (or the unset scissor slots
    // default to (0,0,0,0) and clip every fragment at viewports 1..N-1).
    // When `viewportArrayCount > 1` the encoder uses these N entries;
    // otherwise the single-rect `scissor*` fields above apply.
    struct ScissorEntry {
        GLint x = 0;
        GLint y = 0;
        GLsizei width = 0;
        GLsizei height = 0;
        bool enabled = false;   // per-slot SCISSOR_TEST (glEnablei)
    };
    ScissorEntry scissorArray[kMaxDrawViewports] = {};

    // Phase 8X Group 4d follow-up¹⁴ — blend state plumbing.
    //
    // Before follow-up¹⁴ the pipeline descriptor's
    // `colorAttachments[0]` was left at Metal's defaults
    // (`blendingEnabled=NO, src=One, dst=Zero, op=Add, writeMask=All`),
    // which made *every* draw opaque on the GPU side regardless of
    // what the GL state tracker had recorded via `glEnable(GL_BLEND)` +
    // `glBlendFunc(...)`. BAR diagnosed this in followup¹³-verification
    // §Candidate-1 as the cause of the smeared-text overlay for
    // programs that relied on premultiplied-alpha over-compositing.
    //
    // `GLContext::drawArrays` (and the other draw entry points) now
    // reads `state->blendState()` + `state->isEnabled(GL_BLEND)` into
    // this substruct, and `encodeTranslatedDraw` applies it to the
    // pipeline color attachment descriptor before
    // `newRenderPipelineStateWithDescriptor`. The pipeline cache key
    // is also extended to include these fields so a program that
    // toggles blend mid-frame rebuilds its pipeline correctly instead
    // of reusing a stale one.
    //
    // Defaults match `MTLRenderPipelineColorAttachmentDescriptor`'s
    // documented defaults so that a zero-initialised TranslatedDrawInfo
    // still produces a valid opaque pipeline.
    struct BlendState {
        bool enabled = false;
        GLenum srcRGB = GL_ONE;
        GLenum dstRGB = GL_ZERO;
        GLenum srcAlpha = GL_ONE;
        GLenum dstAlpha = GL_ZERO;
        GLenum equationRGB = GL_FUNC_ADD;
        GLenum equationAlpha = GL_FUNC_ADD;
        bool colorMaskR = true;
        bool colorMaskG = true;
        bool colorMaskB = true;
        bool colorMaskA = true;
    };
    BlendState blend;

    // Uniform Buffer Object bindings.  Resolved from the GL state by
    // GLContext::drawArrays at draw time, then bound to the Metal encoder
    // by encodeTranslatedDraw. Each entry pairs a Metal [[buffer(N)]] slot
    // with a pointer to the CPU-side buffer data. The data lifetime is the
    // GLBufferObject's backing store, which outlives the encode call.
    struct UBOBinding {
        std::uint32_t metalSlot = 0;
        const void* data = nullptr;
        std::size_t size = 0;
        void* metalBuffer = nullptr;  // raw retained Metal buffer for >4KB UBOs
        std::size_t metalBufferOffset = 0;
        GLuint glBufferName = 0;
        bool isVertex = false;    // bind to vertex stage
        bool isFragment = false;  // bind to fragment stage
    };
    std::vector<UBOBinding> uboBindings;

    // Shader Storage Buffer Object bindings for graphics stages.
    // GL 4.3+ lets vertex/fragment/geometry/tess shaders declare
    // `layout(binding=N) buffer X` and access the underlying MTLBuffer
    // as `device T* x [[buffer(metalSlot)]]`. Compute already has its
    // own dispatch-time resolver; this is the graphics-stage analog
    // bound by encodeTranslatedDraw.
    struct SSBOBinding {
        std::uint32_t metalSlot = 0;
        void* metalBuffer = nullptr;
        GLuint glBufferName = 0;
        std::size_t offset = 0;
        // Effective bound byte range. Used by the Sprint 18 Item42
        // graphics argbuf sidecar for SSBO `.length()` / OpArrayLength.
        std::size_t size = 0;
        bool isVertex = false;
        bool isFragment = false;
    };
    std::vector<SSBOBinding> ssboBindings;

    // Atomic counter buffers for graphics stages. Direct MSL uses the
    // GL atomic-counter binding index; argument-buffer MSL uses the
    // translator-assigned argbuf id carried here.
    struct AtomicCounterBinding {
        std::uint32_t metalSlot = 0;
        void* metalBuffer = nullptr;
        GLuint glBufferName = 0;
        std::size_t offset = 0;
        bool isVertex = false;
        bool isFragment = false;
    };
    std::vector<AtomicCounterBinding> atomicCounterBindings;

    std::vector<GLuint> sampledTextureNames;
    std::vector<GLuint> readImageTextureNames;
    std::vector<GLuint> writtenImageTextureNames;

    // Translated MSL + reflection (borrowed from GLProgramObject).
    const std::string* vertexMSL = nullptr;
    const std::string* fragmentMSL = nullptr;
    const ShaderReflection* vertexReflection = nullptr;
    const ShaderReflection* fragmentReflection = nullptr;

    // Pipeline state cache (stored on GLProgramObject, updated by MetalFrameGraph).
    void** pipelineStateOut = nullptr;
    std::uint32_t* pipelineColorFormatOut = nullptr;

    // Phase 8X Group 4d follow-up¹⁴ — map-based pipeline cache.
    // Non-owning pointer to the `GLProgramObject::metalPipelineStateCache`
    // unordered_map. When non-null, `encodeTranslatedDraw` hashes
    // (shader MSL, colorFormat, blend tuple, per-attribute format
    // tuple) into a 64-bit key and looks it up here first. On hit the mapped
    // `id<MTLRenderPipelineState>` is used. On miss the new pipeline
    // is built and inserted, with the old `pipelineStateOut` scalar
    // slot also updated so the first-draw-per-program diagnostic
    // bookkeeping keeps working.
    std::unordered_map<std::uint64_t, void*>* pipelineStateCacheOut = nullptr;

    // Phase 2 / Lever A Slice 2: optional structural state-resolve recipe.
    // On a plan hit, encodeTranslatedDraw uses this payload to skip
    // re-deriving the pipeline cache key and translated-MSL helper slots.
    // Dynamic resource pointers, uniform bytes, hazard tracking, and command
    // emission still come from this draw's live TranslatedDrawInfo.
    const TranslatedDrawPlan* translatedPlan = nullptr;
    TranslatedDrawPlan* translatedPlanOut = nullptr;
    std::string* translatedPlanRejectReasonOut = nullptr;

    // Step 7-4: MTLFunction cache slots. Under APPGL_ENABLE_ARGUMENT_BUFFERS
    // the argbuf-encoder path needs the MTLFunction for
    // `newArgumentEncoderWithBufferIndex:`. Pre-7-4 we forced a
    // pipeline-cache miss on every draw so vertFn/fragFn stayed in
    // the build-branch scope — expensive. Now, populated once on
    // first build and reused for every subsequent draw. Input
    // `metalVertexFunction` (read by encodeTranslatedDraw) comes
    // from GLProgramObject; output `metalVertexFunctionOut` (written
    // on the first build branch) is a pointer to the same slot for
    // retaining the newly-created MTLFunction. Parallel pair for
    // fragment.
    void* metalVertexFunction = nullptr;         // id<MTLFunction>
    void* metalFragmentFunction = nullptr;       // id<MTLFunction>
    void** metalVertexFunctionOut = nullptr;     // &programObject->metalVertexFunction
    void** metalFragmentFunctionOut = nullptr;   // &programObject->metalFragmentFunction

    // Phase 8X Group 4d follow-up⁴ — pipeline-build failure surfacing.
    //
    // Non-owning. When non-null, encodeTranslatedDraw populates this string
    // on each of the five Metal-side failure paths (newLibraryWithSource for
    // vertex/fragment, newFunctionWithName for vertex/fragment, and
    // newRenderPipelineStateWithDescriptor) before returning false. The
    // first token in the populated string identifies the failing stage so
    // BAR-side tooling can grep-aggregate by stage name even though the
    // record stores the full text. On a successful build path the string
    // is left untouched. On the early-return paths above the build branch
    // (device==nil / bad vertex data / empty MSL) the string is also left
    // untouched, since none of those produce an NSError to surface — the
    // existing translatedFallbackGatesReported bitmask is already enough
    // signal to name them. Only the encode-failed gate (which runs the
    // actual Metal calls) populates this field.
    //
    // The caller (GLContext::drawArrays / drawArraysInstanced /
    // drawElements) inspects the string after the false return and pushes
    // it to Runtime::recordShaderTranslation as a `pipeline-build`
    // ShaderTranslationRecord, gated by the existing first-time-per-program
    // EncodeFailed bit so the record fires once per program rather than
    // once per draw.
    std::string* pipelineBuildErrorOut = nullptr;

    // FBO render target override.  When non-null, encodeTranslatedDraw
    // renders into this texture instead of the default framebuffer's
    // drawable/offscreen texture.  The caller (GLContext::drawArrays etc.)
    // resolves the bound draw-framebuffer's color attachment Metal texture
    // and sets this field; nullptr means draw to default framebuffer.
    void* fboColorTexture = nullptr;       // id<MTLTexture>
    // Multi-Render-Target (MRT) extra color attachments beyond
    // `fboColorTexture`. Index i here corresponds to GL
    // `GL_COLOR_ATTACHMENT(i+1)` when the bound FBO enumerates
    // `GL_COLOR_ATTACHMENT0` through its drawBuffers array. Null
    // entries are ignored. Metal pipeline colorAttachments[i+1]
    // gets the pixelFormat inferred from the texture.
    // CTS `draw_buffers.draw_buffers_1` exercises up to 8
    // simultaneous attachments; the length of this array matches
    // the `GLFramebufferObject::drawBuffers[8]` shape minus the
    // slot-0 entry already carried by `fboColorTexture`.
    std::array<void*, 7> fboAdditionalColorTextures = {};
    void* fboDepthStencilTexture = nullptr; // id<MTLTexture> or nil
    GLsizei fboWidth = 0;
    GLsizei fboHeight = 0;
    // Attachment-less user FBO (ARB_framebuffer_no_attachments). GL
    // still rasterizes against the framebuffer default dimensions, so
    // Metal needs a private dummy color target to host the render pass.
    bool fboAttachmentless = false;
    std::uint32_t fboDefaultLayers = 0;
    // Layered rendering: when non-zero, the color attachment is a
    // layered texture (2D_ARRAY / 2D_MS_ARRAY / 3D / CUBE / CUBE_
    // ARRAY) and `renderTargetArrayLength` on the MTLRenderPass
    // descriptor should be set to this value so the raster
    // routes primitives to the slice named by
    // `[[render_target_array_index]]`. When 0, the attachment is
    // either non-layered or attached as a single slice via
    // framebufferTextureLayer, and layered output is disabled.
    std::uint32_t fboColorArrayLength = 0;
    // Sprint 17 Day 1 (CKPT236) [Probe A 2DMSArray clamp]: maximum
    // gl_Layer value emitted by the GS for this draw. Applied by
    // `encodeTranslatedDraw` when the colour attachment is
    // `MTLTextureType2DMultisampleArray` to clamp
    // `pass.renderTargetArrayLength` to `min(fboColorArrayLength,
    // maxEmittedLayer + 1)` instead of the texture's full
    // arrayLength. Apple Silicon's AGX driver asserts
    // `slice < getNumSlices()` when rTAL is set to the full
    // arrayLength on MS-array layered draws — Codex Sprint 17 Day 1
    // forensics h2DM-3 verdict; Clerk-validated. Zero when not a
    // layered GS-emul draw OR when GS doesn't write gl_Layer (in
    // which case fboColorArrayLength itself is also zero).
    std::uint32_t maxEmittedLayer = 0;
    // Phase 6-5: per-attachment slice index for FramebufferTextureLayer
    // attachments. When the app calls `glFramebufferTextureLayer(FBO,
    // COLOR_ATTACHMENT0 + i, tex, 0, layer)`, Metal's equivalent is
    // `pass.colorAttachments[i].slice = layer`. Without this, every
    // slot defaults to slice 0 and per-layer rendering silently
    // collapses onto layer 0. Index 0 corresponds to
    // `fboColorTexture` (Metal slot 0); indices 1..7 correspond to
    // `fboAdditionalColorTextures[0..6]` (Metal slots 1..7).
    // Non-layered attachments (FramebufferTexture / FramebufferTexture2D)
    // leave their slot at 0.
    std::array<std::uint32_t, 8> fboColorSlices = {};
    // Per-attachment mip level. OpenGL framebufferTexture* attaches a
    // specific texture level; Metal defaults color attachments to level 0.
    std::array<std::uint32_t, 8> fboColorLevels = {};
    // Depth/stencil texture attachment slice and mip level for
    // framebufferTextureLayer. Whole-texture layered attachments keep
    // slice 0 and use renderTargetArrayLength routing.
    std::uint32_t fboDepthStencilSlice = 0;
    std::uint32_t fboDepthStencilLevel = 0;
};

// Phase 8X Group 4d follow-up¹⁷ — describes a single immediate-mode
// draw captured between `glBegin` and `glEnd`.
//
// The vertex layout is fixed: `{float position[4], float color[4],
// float texcoord[2]}` = 40 bytes. `vertices` points at a contiguous
// array of that tuple type (owned by the caller — `GLContext::endImmediate`
// passes its capture vector directly, and the frame graph copies the
// bytes into the triple-buffered ring before returning). `vertexStride`
// is always `sizeof(float) * 10` but is carried explicitly so the Metal
// vertex descriptor can be built from the struct without magic numbers.
//
// `mvp` is the projection * modelview matrix snapshot at glEnd time;
// it's pushed as a vertex-stage constant because no shader program is
// active on this path. `metalTexture` is the id<MTLTexture> bound to
// GL_TEXTURE_2D on unit 0 (resolved by the caller), or nullptr if no
// texture is bound; the frame graph picks the untextured pipeline in
// that case.
struct ImmediateDrawInfo {
    GLenum mode = 0;
    const void* vertices = nullptr;
    std::size_t vertexCount = 0;
    std::size_t vertexStride = 0;
    Matrix4 mvp = Matrix4::identity();
    void* metalTexture = nullptr;  // id<MTLTexture> or nullptr
    GLenum fragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
};

// Compute dispatch descriptor. Populated by GLContext::dispatchCompute
// from the currently-bound program + SSBO indexed bindings + texture
// units; consumed by MetalFrameGraph::encodeComputeDispatch which owns
// the MTLComputeCommandEncoder lifecycle.
struct ComputeDispatchInfo {
    AppGLSubmissionGroup submissionGroup;

    void* metalComputePipelineState = nullptr; // id<MTLComputePipelineState>
    // Step 7-3 compute follow-up: id<MTLFunction> for the compute
    // entry point, used by `encodeComputeDispatch` to call
    // `newArgumentEncoderWithBufferIndex:` when APPGL_ENABLE_ARGUMENT_
    // BUFFERS is set. Left null outside argbuf mode.
    void* metalComputeFunction = nullptr;     // id<MTLFunction>
    std::uint32_t groupsX = 1;
    std::uint32_t groupsY = 1;
    std::uint32_t groupsZ = 1;
    std::uint32_t localX = 1;
    std::uint32_t localY = 1;
    std::uint32_t localZ = 1;
    bool needsSSBOSizeBuffer = false;

    struct BufferBinding {
        void* metalBuffer = nullptr; // id<MTLBuffer>
        std::size_t offset = 0;
        std::size_t size = 0;
        std::uint32_t metalSlot = 0;
        // Compute argument-buffer descriptor set: 0 for SSBOs, 1 for UBOs.
        std::uint32_t descriptorSet = 0;
    };
    // All non-argument buffers to bind: SSBOs at `storageBufferBase+N`,
    // UBOs and the default-uniform push-constant buffer below them.
    std::vector<BufferBinding> buffers;

    struct TextureBinding {
        void* metalTexture = nullptr;      // id<MTLTexture>
        void* metalSamplerState = nullptr; // id<MTLSamplerState>
        // Non-owning backing buffer for buffer-texture MTLTexture views.
        void* textureBufferBackingMetalBuffer = nullptr; // id<MTLBuffer>
        void* imageAtomicMetalBuffer = nullptr; // id<MTLBuffer>
        std::size_t imageAtomicBufferOffset = 0;
        std::uint32_t imageAtomicBufferSlot = 0xFFFFFFFFu;
        std::uint32_t metalSlot = 0;
    };
    std::vector<TextureBinding> textures;

    // Default-uniform push-constant bytes for the compute stage.
    // Bound at Metal buffer index 16 (same slot as graphics stages).
    // Populated by GLContext::dispatchCompute from the packed uniform
    // layout so bare `uniform vec4 u0;` style declarations reach
    // location-based glUniform* updates.
    const void* computeUniformData = nullptr;
    std::size_t computeUniformSize = 0;
    const void* multisampleStorageImageSampleCounts = nullptr;
    std::size_t multisampleStorageImageSampleCountBytes = 0;
    std::uint32_t multisampleStorageImageSampleCountSlot = 30;

    // Indirect dispatch: when indirectBuffer != nullptr the work-group
    // counts (groupsX/Y/Z above) are ignored and Metal reads them from
    // `indirectBuffer + indirectOffset` at dispatch time. Three GLuints
    // in GPU-native order (matching GL_DISPATCH_INDIRECT_BUFFER layout).
    void* indirectBuffer = nullptr;  // id<MTLBuffer>
    std::size_t indirectOffset = 0;
};

// Metal-native tessellation draw descriptor (Phase 2 of the metal-tess
// project). Populated by the tess-capable drawArrays / drawElements path
// in GLContext from (a) the linked program's cached MSL + TCS compute
// PSO and (b) the current GL state snapshot. Consumed by
// `encodeMetalTessellationDraw`, which owns the 3-encoder dance:
//   compute(TCS) → tessellator (hardware) → render(drawPatches, TES+FS).
//
// Phase-2 scope: no VS outputs, no TCS user CP output, no TES user
// varyings beyond gl_Position. Future phases extend this struct with
// stage-input buffer descriptors + per-CP / per-patch output bindings.
// T4I [metal-tess-TF]: when the VS-as-compute MSL declares
// `[[stage_in]]`, the caller resolves each VAO buffer slot to an
// MTLBuffer + offset and passes the bindings here so the encoder
// can call `setBuffer:offset:atIndex:` before the VS-compute
// dispatch. `metalSlot` matches the descriptor's
// `attributes[*].bufferIndex`; offset is the absolute byte offset
// into the MTLBuffer.
struct MetalTessVertexBufferBinding {
    void* metalBuffer = nullptr;      // id<MTLBuffer>, non-owning
    std::uint64_t offset = 0;
    std::uint32_t metalSlot = 0;
};

struct MetalTessDrawInfo {
    AppGLSubmissionGroup submissionGroup;

    // TCS compute pipeline state (retained by the program; not a
    // transfer). Set by the caller from
    // GLProgramObject::metalTessControlPipelineState.
    void* tessControlPipelineState = nullptr;  // id<MTLComputePipelineState>
    // Phase 3: VS-as-compute pipeline state. When non-null, the
    // encoder runs a VS compute dispatch before the TCS and binds
    // per-CP / per-patch / VS-output buffers for the TCS + render
	    // encoders. When null, the encoder takes the Phase 2 path
	    // (factor + indirect only).
	    void* vertexComputePipelineState = nullptr;  // id<MTLComputePipelineState>
	    // Targeted fallback for TF-only tessellation draws whose VS-compute
	    // PSO cannot be built because Metal rejected an empty stage_in
	    // descriptor. The encoder allocates the Phase-3 handoff buffers,
	    // skips the VS dispatch, and seeds a zeroed VS-output buffer.
	    bool forcePhase3Buffers = false;
    // Phase 3B.4 [metal-tess-TF]: TES-as-compute pipeline state.
    // When non-null, the encoder can extend the compute chain with a
    // domain-point generator dispatch + a TES-as-compute dispatch whose
    // output feeds TF, point-mode replay, query accounting, or tess
    // render-verification paths. When null, the encoder uses the existing
    // TES-as-vertex-function render path.
    void* tessEvalComputePipelineState = nullptr;  // id<MTLComputePipelineState>
    // True when correctness requires the TES-compute sidecar for this draw
    // (active tess TF, point-mode replay, or active tess query accounting).
    // Optional render-verification uses may still run below the encoder's
    // soft allocation cap.
    bool tessEvalComputeRequired = false;
    // Reflected size of TES-as-compute `main0_out`. The encoder sizes the
    // Shared-storage spvOut buffer from this stride so wide TES output structs
    // do not overrun the Phase 3 legacy slot size.
    std::size_t tessEvalOutputStrideBytes = 256;

    // Phase 3B.5 [metal-tess-TF]: encoder out-params used by the TF
    // write path in `tryMetalTessellationDraw`. After the TES-compute
    // dispatch the encoder writes the generated vertex count into
    // `*outGeneratedVertCount` and an id<MTLBuffer> handle for the
    // Shared-storage TES output buffer into `*outTesComputeOutBuf`.
    // Caller reads the buffer bytes and deposits them into the bound
    // GL_TRANSFORM_FEEDBACK_BUFFER per the program's TF layout. Both
    // pointers are optional — null = no write-back (the encoder allocates
    // everything locally and lets the compute dispatches run for coverage /
    // query accounting only).
    std::uint32_t* outGeneratedVertCount = nullptr;
    void** outTesComputeOutBuf = nullptr;  // id<MTLBuffer>*

    // Phase 3B.6 [metal-tess-TF]: default-uniform block bytes for
    // each compute stage. Bound at Metal buffer slot 16 (the
    // `_DefaultUniforms` slot SPIRV-Cross's translator uses for
    // bare GL uniforms). Caller packs via buildStageUniformBuffer
    // against the matching stage reflection; non-owning views that
    // must outlive the encode call. Any of the three may be null
    // if the program has no uniforms in that stage.
    const void* tessControlUniformData = nullptr;
    std::size_t tessControlUniformSize = 0;
    const void* tessVertexAsComputeUniformData = nullptr;
    std::size_t tessVertexAsComputeUniformSize = 0;
    const void* tessEvalAsComputeUniformData = nullptr;
    std::size_t tessEvalAsComputeUniformSize = 0;
    // Fragment-stage default-uniform block for the tess render pass.
    // SPIRV-Cross emits bare FS uniforms as `_DefaultUniforms` at
    // [[buffer(16)]], the same convention used by translated draws.
    const void* fragmentUniformData = nullptr;
    std::size_t fragmentUniformSize = 0;

    // Sampled texture/sampler bindings for tessellation stages. Slots
    // match SPIRV-Cross's [[texture(N)]] / [[sampler(N)]] arguments.
    std::vector<TranslatedDrawInfo::TextureBinding> tessControlTextures;
    std::vector<TranslatedDrawInfo::TextureBinding> tessVertexAsComputeTextures;
    std::vector<TranslatedDrawInfo::TextureBinding> tessEvalTextures;
    std::vector<TranslatedDrawInfo::TextureBinding> fragmentTextures;

    // Cached MSL sources for rebuilding the render pipeline on FBO
    // format changes. Non-owning; must outlive the encode call.
    const std::string* tessControlMSL = nullptr;
    const std::string* tessVertexAsComputeMSL = nullptr;
    const std::string* tessEvalAsComputeMSL = nullptr;
    const std::string* tessEvalMSL = nullptr;
    const std::string* fragmentMSL = nullptr;

    // Tessellation parameters from GL state + TES/TCS execution modes.
    GLsizei patchCount = 0;                   // count / patchVertices
    GLsizei patchVertices = 3;                // GL_PATCH_VERTICES
    GLsizei tessControlOutputVertices = 0;    // TCS `layout(vertices=N)`
    GLenum genMode = GL_TRIANGLES;            // TES gen mode (TRIANGLES/QUADS/ISOLINES)
    GLenum genSpacing = GL_EQUAL;             // TES spacing
    GLenum genVertexOrder = GL_CCW;           // TES vertex-order
    bool pointMode = false;                   // TES point_mode (Phase 4)

    GLsizei instanceCount = 1;
    GLuint baseInstance = 0;

    // Sprint 5 Phase 1 — Phase 3 gate widening signal: TCS was
    // synthesized at link time (TES-only program). Encoder uses this to
    // host-populate `factorBufFull` from glPatchParameterfv state per
    // draw, overriding synth TCS's 1.0 defaults. Without this override,
    // gl_tessLevel TES iters fail because synth defaults don't match
    // user-set glPatchParameterfv values.
    bool tessControlSynthesized = false;
    // glPatchParameterfv state snapshot at draw time. Used only when
    // tessControlSynthesized is true. Layout: outer[0..3] + inner[0..1].
    float defaultOuterLevel[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    float defaultInnerLevel[2] = {1.0f, 1.0f};

    // T4I [metal-tess-TF]: per-VAO vertex buffer bindings for VS-as-
    // compute when the PSO uses `[[stage_in]]`. Empty for the
    // no-descriptor path (the encoder skips buffer binding when this
    // is empty and `vertexComputePipelineState` is the program's
    // unconditional one). Populated by `tryMetalTessellationDraw`
    // after building the descriptor + lookup-or-building the cached
    // VS-compute PSO from the bound VAO.
    std::vector<MetalTessVertexBufferBinding> vertexComputeBufferBindings;

    // Per-program identifier — diagnostic only.
    GLuint program = 0;

    // Pipeline state toggles (mirrors TranslatedDrawInfo's subset used
    // for the tess render pipeline). Phase 2 wires just the essentials:
    // viewport/scissor/cull/front-face/color+depth format.
    bool cullFaceEnabled = false;
    GLenum cullFaceMode = GL_BACK;
    GLenum frontFace = GL_CCW;
    std::uint32_t sampleMask = 0xFFFFFFFFu;

    bool depthTestEnabled = false;
    GLenum depthFunc = GL_LESS;
    bool depthWriteMask = true;

    // Sprint 7 Phase 1 #11 (CKPT57): per-draw stencil state for the
    // tess-Phase-2 render encoder path. Same shape as TranslatedDrawInfo
    // — per-face stencil func/ref/masks/ops + global enable.
    bool stencilTestEnabled = false;
    GLenum stencilFrontFunc = GL_ALWAYS;
    GLint stencilFrontRef = 0;
    GLuint stencilFrontValueMask = 0xFFFFFFFFu;
    GLenum stencilFrontFail = GL_KEEP;
    GLenum stencilFrontDepthFail = GL_KEEP;
    GLenum stencilFrontDepthPass = GL_KEEP;
    GLuint stencilFrontWriteMask = 0xFFFFFFFFu;
    GLenum stencilBackFunc = GL_ALWAYS;
    GLint stencilBackRef = 0;
    GLuint stencilBackValueMask = 0xFFFFFFFFu;
    GLenum stencilBackFail = GL_KEEP;
    GLenum stencilBackDepthFail = GL_KEEP;
    GLenum stencilBackDepthPass = GL_KEEP;
    GLuint stencilBackWriteMask = 0xFFFFFFFFu;

    // Viewport / scissor.
    GLint viewportX = 0;
    GLint viewportY = 0;
    GLsizei viewportWidth = 0;
    GLsizei viewportHeight = 0;
    GLdouble depthRangeNear = 0.0;
    GLdouble depthRangeFar = 1.0;
    TranslatedDrawInfo::ViewportEntry viewportArray[TranslatedDrawInfo::kMaxDrawViewports] = {};
    std::size_t viewportArrayCount = 0;

    bool scissorTestEnabled = false;
    GLint scissorX = 0;
    GLint scissorY = 0;
    GLsizei scissorWidth = 0;
    GLsizei scissorHeight = 0;
    TranslatedDrawInfo::ScissorEntry scissorArray[TranslatedDrawInfo::kMaxDrawViewports] = {};
    std::size_t scissorArrayCount = 0;
    GLenum clipOrigin = GL_LOWER_LEFT;

    // Framebuffer attachments. Mirrors the FBO handling in
    // TranslatedDrawInfo. When `fboColorTexture` is non-null the render
    // pass targets that texture (FBO draw); otherwise it targets the
    // default framebuffer (drawable or offscreen). Phase 2 supports
    // single-color-attachment FBOs only; MRT lands in a later phase.
    // Pixel formats are read from the MTLTextures inside the encoder.
    void* fboColorTexture = nullptr;          // id<MTLTexture>
    void* fboDepthStencilTexture = nullptr;   // id<MTLTexture>
    std::uint32_t fboColorArrayLength = 0;

    // Clear-state propagation: when true, the render pass begins with
    // LoadActionClear using these values. Matches the pending-clear
    // plumb-through the standard translated draw path uses.
    bool pendingClearColor = false;
    GLfloat clearColor[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    bool pendingClearDepth = false;
    GLfloat clearDepth = 1.0f;
    bool pendingClearStencil = false;
    GLint clearStencil = 0;

    // Set by the encoder only when a tess render pass actually
    // reaches drawPatches. Compute-only TF/rasterizer-discard paths
    // leave FBO producer state untouched.
    bool didRender = false;
};

class MetalFrameGraph {
public:
    MetalFrameGraph(GLContext* context,
                    void* layer,
                    void* device,
                    void* commandQueue,
                    MetalCommandSubmission* commandSubmission);
    ~MetalFrameGraph();

    MetalFrameGraph(const MetalFrameGraph&) = delete;
    MetalFrameGraph& operator=(const MetalFrameGraph&) = delete;

    void resizeDrawable(GLsizei width, GLsizei height);
    void enableOffscreenDrawable(GLsizei width, GLsizei height);
    void encodeDefaultFramebufferClear(
        GLbitfield mask,
        GLfloat clearRed,
        GLfloat clearGreen,
        GLfloat clearBlue,
        GLfloat clearAlpha,
        GLdouble clearDepth,
        GLint clearStencil
    );
    void beginRenderPassForCurrentFramebuffer(GLStateTracker& state, GLObjectStore& objects);
    void* currentRenderEncoder() const;
    void endRenderPass();
    // Encodes a single draw call against the current default framebuffer using
    // the prebaked "solid color" pipeline state. Phase A Group 7 MVP. Returns
    // true on success. If the provided layout cannot be handled the caller is
    // expected to fall back to a no-op and record a debug message.
    bool encodeSolidColorDraw(const MetalDrawInfo& info);
    // Encodes a draw call using a translated GLSL→MSL pipeline. The pipeline
    // state is lazily created on first use and cached on the program object.
    bool encodeTranslatedDraw(TranslatedDrawInfo& info);
    // Phase 8X Group 4d follow-up¹⁷ — encodes a single compat-profile
    // immediate-mode draw (glBegin/glVertex*/glEnd) using one of two
    // built-in pipelines (textured-and-vertex-color or vertex-color-
    // only). The vertex data is memcpy'd into the frame-graph's
    // triple-buffered ring before the encode. Returns true on success
    // or false if the pipeline state could not be built.
    bool encodeImmediateModeDraw(const ImmediateDrawInfo& info);

    // Layered-texture clear helpers. Issue an empty render pass with
    // `MTLLoadActionClear` on the supplied MTLTexture, using
    // `arrayLength > 0` to target all slices of a layered attachment.
    // Used by clearDepthAttachment / clearStencilAttachment / the
    // color path to make `glClear` on a texture-backed FBO
    // attachment actually land on the Metal side. Without this
    // path the Metal texture keeps its previous contents (typically
    // zeros from creation) and the subsequent draw's depth test
    // compares against junk.
    // `tex`           — id<MTLTexture> as void* (CFBridgingRetain not
    //                   required; we just use it for the pass).
    // `arrayLength`   — 0 for non-layered, >0 for layered (matches
    //                   the attachment's MTLRenderPassDescriptor
    //                   renderTargetArrayLength).
    // Color clears carry the full RGBA; depth uses `depth` (0-1);
    // stencil uses the low byte of `stencil`.
    bool clearLayeredTextureDepth(void* tex, std::uint32_t arrayLength, float depth);
    bool clearLayeredTextureStencil(void* tex, std::uint32_t arrayLength, std::uint32_t stencil);
    bool clearLayeredTextureColor(void* tex, std::uint32_t arrayLength, const float rgba[4],
                                  std::uint32_t level = 0, std::uint32_t slice = 0);
    bool clearTextureDepth(void* tex, std::uint32_t level, std::uint32_t slice,
                           std::uint32_t arrayLength, float depth);
    bool clearTextureStencil(void* tex, std::uint32_t level, std::uint32_t slice,
                             std::uint32_t arrayLength, std::uint32_t stencil);
    bool writeMultisampleDepthStencilRegion(void* tex, GLint x, GLint y,
                                            GLsizei width, GLsizei height,
                                            const GLfloat* depthPixels,
                                            bool writeDepth,
                                            std::uint8_t stencilValue,
                                            bool writeStencil);

    // Compile a compute shader's MSL source into a retained
    // MTLComputePipelineState and return it as a type-erased void*
    // (callers CFBridgingRelease via releaseRetainedMetalObject at
    // program delete / relink). Returns nullptr on build failure and
    // populates `outError` with the NSError localizedDescription if
    // provided.
    void* buildComputePipelineState(const std::string& msl, std::string* outError,
                                     void** outFunction = nullptr,
                                     void* stageInputOutputDescriptor = nullptr);

    // Sprint 15 Q3-Option-B Phase 3a [metal-tf-vs]: dispatch a VS-as-
    // compute kernel (built via Phase 1's `forceVertexForTessellation`
    // emission) and capture per-vertex output struct bytes into a
    // Shared MTLBuffer. Used by VS+FS+TF programs (no GS, no tess) to
    // replace the CPU `emulateVsOnlyDrawForTf` SPIR-V interpreter with
    // a Metal-native compute dispatch.
    //
    // `vsComputePSO` — retained id<MTLComputePipelineState> from the
    //   program's `metalVsTfComputePipelineState` (built at link time).
    // `vertexCount` — per-vertex dispatch count (gridSize.x).
    // `perVertexBytes` — size of the per-vertex output struct (matches
    //   `program.vsTfOutputLayout.structSize`).
    // `uniformBytes` / `uniformLength` — VS uniform-block bytes (bound
    //   at `[[buffer(16)]]`); pass nullptr/0 if the VS uses no uniforms.
    // `outBytes` — caller-provided buffer (size >= vertexCount *
    //   perVertexBytes); receives the captured per-vertex output.
    // Returns true on success, false on any Metal failure (caller
    // should fall back to CPU `emulateVsOnlyDrawForTf`).
    //
    // Day 4 Phase 3a: handles attributeless VS programs (PSO built
    // without MTLStageInputOutputDescriptor — i.e.
    // `program.metalVsTfNeedsDescriptor == false`). Phase 3c (Day 6+)
    // will extend this to VAO-bound stage-input programs via
    // per-VAO PSO + buffer binding plumbing.
    bool encodeVsTfComputeDraw(void* vsComputePSO,
                               std::uint32_t vertexCount,
                               std::size_t perVertexBytes,
                               const void* uniformBytes,
                               std::size_t uniformLength,
                               std::uint8_t* outBytes);

    // Sprint 3 [metal-mesh-GS]: compile MSL source into a retained
    // id<MTLFunction> (no pipeline state). Used for the mesh-shader
    // path where the render PSO build is FBO-format-keyed and
    // therefore deferred to draw time, but the function compile cost
    // can be paid once at link time. Returns nullptr on failure;
    // populates `outError` with the NSError description.
    void* compileMSLFunction(const std::string& msl, std::string* outError);

    // Metal-native tessellation pipeline probe (Phase 1 of the metal-tess
    // project). Given SPIRV-Cross-emitted MSL for a tess program's three
    // stages (TCS compute kernel, TES vertex function with `[[patch(...)]]`
    // attribute, FS fragment function), validate that:
    //   1. TCS MSL compiles via `[device newLibraryWithSource:]` and the
    //      compute pipeline state builds from it.
    //   2. TES + FS MSL compiles and a tessellation-enabled render
    //      pipeline descriptor (`tessellationPartitionMode`,
    //      `tessellationOutputWindingOrder`, `tessellationFactorFormat =
    //      .half`) accepts both functions at
    //      `newRenderPipelineStateWithDescriptor:error:` time.
    //
    // No encoded state is wired to a draw call — the probe is a build-time
    // smoke test for Phase 1. The compute PSO is retained and returned
    // via `outComputePipelineState` (CFBridgingRelease at release time)
    // so Phase 2 can reuse it without rebuilding; the render PSO is
    // release-on-return because it is color-format-keyed and will be
    // rebuilt at draw time against the actual FBO format. `outError` is
    // populated with the first failure's description.
    //
    // `genMode`, `genSpacing`, `genVertexOrder` come from the TES
    // execution modes (`tessGenMode`, `tessGenSpacing`,
    // `tessGenVertexOrder` on the program object). They map to Metal
    // tess pipeline fields per GL 4.6 §11.2.2 / Metal docs.
    struct TessPipelineProbeResult {
        bool computeOk = false;
        bool renderOk = false;
        bool vertexComputeOk = false;    // Phase 3 — true iff VS-as-compute
                                         // PSO built (only attempted when
                                         // vsComputeMSL is non-empty).
        bool tessEvalComputeOk = false;  // Phase 3B.4 [metal-tess-TF]
        // T4I [metal-tess-TF]: when true, the VS-as-compute MSL needs
        // a MTLStageInputOutputDescriptor to build (i.e. uses
        // `[[stage_in]]`). Encoder builds the PSO at draw time from
        // the bound VAO. Distinct from `vertexComputeOk` which
        // indicates a no-descriptor PSO was already built here.
        bool vertexComputeNeedsDescriptor = false;
        std::string diagnostic;          // empty on full success
        void* computePipelineState = nullptr;            // TCS compute PSO (retained)
        void* vertexComputePipelineState = nullptr;      // VS compute PSO (retained)
        void* tessEvalComputePipelineState = nullptr;    // TES-compute PSO (retained)
    };
    // Phase 3: `vsComputeMSL` (empty for non-Phase-3 probes) is the
    // VS-as-compute MSL emitted with `vertex_for_tessellation +
    // capture_output_to_buffer`. When provided, the probe also builds a
    // MTLComputePipelineState for it and retains it as
    // `vertexComputePipelineState`. No MTLStageInputOutputDescriptor is
    // attached yet — programs whose VS reads attributes ([[stage_in]])
    // will fail pipeline-state creation; they fall through to the CPU
    // interpreter path via the same handleability gate that catches TCS
    // buffer bindings.
    //
    // Phase 3B.4 [metal-tess-TF]: `tesComputeMSL` is the TES-as-compute
    // MSL emitted with `tess_evaluation_as_compute = true`. When
    // non-empty the probe also builds its PSO so the Phase-3B encode
    // path can dispatch it.
    TessPipelineProbeResult probeTessellationPipeline(
        const std::string& tcsMSL,
        const std::string& tesMSL,
        const std::string& fsMSL,
        GLenum genMode,
        GLenum genSpacing,
        GLenum genVertexOrder,
        const std::string& vsComputeMSL = "",
        const std::string& tesComputeMSL = "");

    // Metal-native tessellation draw encoder (Phase 2 of the metal-tess
    // project). Uses the currently-bound framebuffer (same as
    // `encodeTranslatedDraw`), runs the TCS compute dispatch, then
    // begins a render pass whose vertex function is the TES and whose
    // fragment function is the program's FS, and issues `drawPatches`
    // with a tess factor buffer populated by the TCS.
    //
    // Returns true on success; false on any encode failure (the caller
    // falls through to the CPU tess interpreter path). On failure a
    // diagnostic is recorded via `recordShaderTranslation`.
    bool encodeMetalTessellationDraw(MetalTessDrawInfo& info);

    // -------------------------------------------------------------
    // Sprint 3 [metal-mesh-GS] — DESIGN PRIMER (no impl yet)
    // -------------------------------------------------------------
    // Geometry shader execution via Metal's `[[mesh]]` / `[[object]]`
    // stage pair. The CPU GS interpreter remains in tree as fallback
    // for chips without mesh shader support (`Apple1-6`); chips with
    // `MTLGPUFamilyMetal3` AND `MTLGPUFamilyApple7` route here.
    //
    // SPIRV-Cross emits the GS as an MSL `[[mesh, max_total_threads_per_threadgroup(N)]]`
    // function that writes vertices/primitives into an `mesh<V, P,
    // MaxV, MaxP, primitive_type> output` parameter via
    // `output.set_vertex(i, v)`, `output.set_primitive(i, p)`,
    // `output.set_index(i, idx)`, and `output.set_primitive_count(K)`
    // for variable-count emission. GS's `EmitVertex` / `EndPrimitive`
    // map to mesh-stage's per-threadgroup primitive emission;
    // `gl_Layer` per primitive maps to `[[render_target_array_index]]`
    // on the per-primitive output struct.
    //
    // `MTLMeshRenderPipelineDescriptor` (macOS 13+) holds:
    //   - `objectFunction` (optional kickoff stage; non-null when GS
    //     amplification needs a per-input-primitive object dispatch
    //     before the mesh stage)
    //   - `meshFunction` (the GS, post-SPIRV-Cross translation)
    //   - `fragmentFunction` (the FS, unchanged from existing render
    //     pipeline)
    //   - `payloadMemoryLength` (bytes object→mesh data passing)
    //   - `maxTotalThreadsPerObjectThreadgroup`,
    //     `maxTotalThreadsPerMeshThreadgroup`,
    //     `maxTotalThreadgroupsPerMeshGrid`
    //   - Standard color/depth/stencil attachment descriptors
    //
    // Encoder API (on `id<MTLRenderCommandEncoder>`):
    //   - `setObjectBuffer:offset:atIndex:` (object stage, optional)
    //   - `setMeshBuffer:offset:atIndex:` (mesh stage)
    //   - `drawMeshThreadgroups:threadsPerObjectThreadgroup:threadsPerMeshThreadgroup:`
    //     for count-based dispatch
    //   - `drawMeshThreads:threadsPerObjectThreadgroup:threadsPerMeshThreadgroup:`
    //     for thread-based dispatch
    //   - Indirect variants exist on both
    //
    // Translation problem mapping (GS → mesh):
    //   - GS input topology (points/lines/triangles + adjacency) →
    //     mesh stage reads VS-output buffer; adjacency primitives are
    //     reconstructed per-threadgroup since Metal mesh shaders only
    //     support `point/line/triangle` output topology natively
    //     (no native adjacency variants — defer adjacency tests to
    //     CPU GS interpreter via selective routing)
    //   - GS `EmitVertex()` → `output.set_vertex(emitCount, struct)`;
    //     emitCount counter incremented per call
    //   - GS `EndPrimitive()` → `output.set_index(...)` finalizes the
    //     primitive, primitiveCount incremented
    //   - GS `gl_Layer` → `[[render_target_array_index]]` on
    //     per-primitive output struct
    //   - GS `gl_Position` → mesh stage's per-vertex output struct
    //     `[[position]]` field
    //   - GS streams 0-3 — Metal mesh shaders have ONE output stream;
    //     no native streams support. CTS GS section has zero stream
    //     tests (verified Phase 0), so this is moot for Sprint 3.
    //
    // No `encodeMetalGSDraw` declared yet — wire when SPIRV-W's first
    // emission patch produces consumable MSL. See Sprint 3 phasing in
    // `specs-worker-docs/SPRINT-3-KICKOFF.md` and Phase 0 findings in
    // `specs-worker-docs/crossworker/SPRINT-3-PHASE-0-FINDINGS-2026-04-27.md`.

    // Sprint 3 Step 2 Phase 2 [metal-mesh-GS]: mesh-shader draw encoder.
    // Drives the GS-as-mesh path for programs with
    // `metalGSTier == MeshShader`. The flow:
    //
    //   (1) VS-as-compute pre-pass — uses the program's cached
    //       `metalGSVsComputePipelineState` (Phase 2 Checkpoint 1)
    //       to dispatch one VS thread per draw vertex, writing the
    //       per-vertex outputs into `vsOutputBuffer` at
    //       `[[buffer(28)]]` (Phase-3 metal-tess slot convention).
    //   (2) Mesh render-pipeline build — MTLMeshRenderPipelineDescriptor
    //       with `meshFunction` (cached on program) +
    //       `fragmentFunction` (translated from the program's FS) +
    //       attachment formats from the bound FBO. Cached
    //       FBO-format-keyed on the program object via
    //       `metalGSMeshPipelineState`.
    //   (3) Render-pass encode — bind `vsOutputBuffer` at
    //       `[[buffer(22)]]` (matches Path A's `spvVsOutputs`),
    //       call `drawMeshThreadgroups:primitiveCount object/mesh`
    //       per Apple's mesh shader sample patterns.
    //
    // Returns false on any encode failure so the caller can fall back
    // to the existing CPU GS interpreter path. Envelope: input
    // topology = points/lines/triangles (no adjacency), output
    // topology = points/line_strip/triangle_strip, max_vertices ≤ 3
    // (Phase 2 MVP — Phase 2.5 widening gated pending pixel-diff
    // characterization of layered_rendering conversion shape).
    // Programs outside this envelope have `metalGSTier != MeshShader`
    // (rejected at link-time gate, GLContext.mm:19097) and never
    // reach this encoder.
    struct MetalMeshGSDrawInfo {
        AppGLSubmissionGroup submissionGroup;

        // Stage PSOs / functions (retained void* — caller owns the
        // refcount; encoder borrows for the duration of the call).
        void* vertexComputePipelineState = nullptr;
        void* meshFunction = nullptr;
        void* fragmentFunction = nullptr;
        // Cached mesh render pipeline (FBO-format-keyed) — read-then-
        // write slot on the program object. nullptr ⇒ encoder builds
        // and stores; non-null ⇒ encoder uses cached PSO.
        void** meshPipelineStateInOut = nullptr;
        // Draw shape.
        std::uint32_t vertexCount = 0;            // VS dispatch range
        std::uint32_t primitiveCount = 0;         // mesh threadgroup count
        std::uint32_t inputVerticesPerPrimitive = 1;  // 1=points, 2=lines, 3=triangles
        // Mesh-output topology (from GS layout). Populates the
        // pipeline descriptor's `meshTopologyClass`.
        std::uint32_t outputTopologyMTLPrimitiveType = 0;  // MTLPrimitiveTypePoint/Line/Triangle
        // Per-vertex VS output stride. Conservative upper bound is
        // fine — VS-compute writes its actual main0_out struct, mesh
        // function reads matching main0_in struct (same struct from
        // SPIRV-Cross's perspective). Overallocation costs memory only.
        std::uint32_t vsOutputStrideBytes = 256;
        // Per-stage default-uniform-block bytes (push-constant
        // equivalent). Each stage has an independently-translated MSL
        // and SPIRV-Cross emits its own struct layout, so the same
        // GL-side uniform values produce DIFFERENT bytes per stage.
        // Bound at [[buffer(16)]] on each stage.
        const void* vsUniformData = nullptr;
        std::size_t vsUniformSize = 0;
        const void* meshUniformData = nullptr;
        std::size_t meshUniformSize = 0;
        const void* fsUniformData = nullptr;
        std::size_t fsUniformSize = 0;
        std::vector<MetalTessVertexBufferBinding> vertexComputeBufferBindings;
        std::vector<TranslatedDrawInfo::TextureBinding> meshTextures;
        std::vector<TranslatedDrawInfo::TextureBinding> fragmentTextures;
        // Fragment shaders rewritten to synthesize OpenGL lower-left
        // gl_FragCoord.y need the same slot-15 params as translated draws.
        bool fragmentNeedsFragCoordParams = false;
        // FBO state (matches encodeTranslatedDraw's fboColorTexture /
        // fboDepthStencilTexture / etc.).
        void* fboColorTexture = nullptr;
        void* fboDepthStencilTexture = nullptr;
        std::uint32_t fboWidth = 0;
        std::uint32_t fboHeight = 0;
        // Phase 2.5 — layered FBO support. When non-zero, the mesh
        // function writes `gl_Layer` and the render pass routes per-
        // primitive output to the matching attachment slice via
        // `[[render_target_array_index]]`. Mirrors legacy
        // encodeTranslatedDraw's fboColorArrayLength (line 2092).
        std::uint32_t fboColorArrayLength = 0;
        // Sprint 17 Day 1 (CKPT236) [Probe A 2DMSArray clamp]: max
        // emitted gl_Layer for this mesh draw. See TranslatedDrawInfo's
        // identical field for full rationale (Codex h2DM-3 verdict).
        std::uint32_t maxEmittedLayer = 0;
        // GL render state — mirrors TranslatedDrawInfo's pipeline
        // toggles. Applied to the mesh-render encoder before
        // drawMeshThreadgroups so the mesh-shader path produces
        // pixels at the same coordinates with the same masks /
        // depth-test behavior as the legacy VS+FS path. Without
        // these, viewport defaults to FBO-full-size and depth/blend
        // state is whatever Metal defaults to (which may not match
        // GL's current state).
        bool depthTestEnabled = false;
        std::uint32_t depthFunc = 0;        // GLenum
        bool depthWriteMask = true;
        // Sprint 7 Phase 1 #11 (CKPT57): mesh-GS render encoder also
        // honors GL stencil state. Same shape as TranslatedDrawInfo,
        // sized as uint32 to match the rest of this struct's GLenum
        // packing convention.
        bool stencilTestEnabled = false;
        std::uint32_t stencilFrontFunc = 0x0207;   // GL_ALWAYS
        std::int32_t stencilFrontRef = 0;
        std::uint32_t stencilFrontValueMask = 0xFFFFFFFFu;
        std::uint32_t stencilFrontFail = 0x1E00;   // GL_KEEP
        std::uint32_t stencilFrontDepthFail = 0x1E00;
        std::uint32_t stencilFrontDepthPass = 0x1E00;
        std::uint32_t stencilFrontWriteMask = 0xFFFFFFFFu;
        std::uint32_t stencilBackFunc = 0x0207;
        std::int32_t stencilBackRef = 0;
        std::uint32_t stencilBackValueMask = 0xFFFFFFFFu;
        std::uint32_t stencilBackFail = 0x1E00;
        std::uint32_t stencilBackDepthFail = 0x1E00;
        std::uint32_t stencilBackDepthPass = 0x1E00;
        std::uint32_t stencilBackWriteMask = 0xFFFFFFFFu;
        bool cullFaceEnabled = false;
        std::uint32_t cullFaceMode = 0;     // GLenum (GL_BACK default)
        std::uint32_t frontFace = 0;        // GLenum (GL_CCW default)
        bool wireframe = false;
        std::uint32_t sampleMask = 0xFFFFFFFFu;
        bool polygonOffsetEnabled = false;
        float polygonOffsetFactor = 0.0f;
        float polygonOffsetUnits = 0.0f;
        float polygonOffsetClamp = 0.0f;
        std::int32_t viewportX = 0;
        std::int32_t viewportY = 0;
        std::int32_t viewportWidth = 0;
        std::int32_t viewportHeight = 0;
        double depthRangeNear = 0.0;
        double depthRangeFar = 1.0;
        bool scissorTestEnabled = false;
        std::int32_t scissorX = 0;
        std::int32_t scissorY = 0;
        std::int32_t scissorWidth = 0;
        std::int32_t scissorHeight = 0;
        // Sprint 17 Day 3+ BONUS-1 [clip_control]: mesh-GS-path mirror
        // of TranslatedDrawInfo::clipOrigin. Drives viewport-Y-flip
        // gate in `encodeMetalMeshGSDraw`. See TranslatedDrawInfo's
        // identical field for full rationale.
        std::uint32_t clipOrigin = 0x8CA1;  // GL_LOWER_LEFT
        // Diagnostic. Used by callers in error-path logging.
        std::string diagnostic;
    };
    bool encodeMetalMeshGSDraw(MetalMeshGSDrawInfo& info);

    // Encode + commit + wait a single compute dispatch. This creates a
    // fresh command buffer + compute encoder, binds the pipeline and
    // the caller-supplied buffer / texture bindings, issues
    // dispatchThreadgroups with the given group and local dimensions,
    // and waits for completion before returning. The wait matches GL's
    // memory-barrier semantics for single-dispatch tests (CTS's
    // shader_bitfield_operation / constant_expressions / SSBO tests
    // all map a subsequent bufferRange on the SSBO and expect the
    // compute writes to be visible).
    bool encodeComputeDispatch(ComputeDispatchInfo& info);
    void endFrame(GLObjectStore& objects);
    void present(AppGLCommandReason reason = AppGLCommandReason::PresentPendingWork);
    bool finish();
    bool copyRGBA8Pixels(GLint x, GLint y, GLsizei width, GLsizei height, void* outPixels);
    // Ends any open render encoder and commits/waits the current command
    // buffer so GPU-rendered texture data can be read back by the CPU.
    // Called before FBO readback to ensure data written by prior draws is
    // visible to [MTLTexture getBytes:].
    void flushForReadback();
    bool hasValidAttachments() const;

    // Pipeline cache metrics for benchmarking.
    //
    // `hits` and `misses` retain their original meanings: a hit is a draw
    // where the cached MTLRenderPipelineState on the program object was
    // reused; a miss is a draw where the build branch ran AND succeeded
    // (so the new state is now cached). `misses` is therefore equivalent
    // to "successful first-time builds", which is what most miss-counter
    // consumers expect.
    //
    // Phase 8X Group 4d follow-up⁴ adds two attempt/failure counters so
    // BAR-side tooling can distinguish "never tried to build" (attempts==0)
    // from "tried every time and failed every time" (attempts>0,
    // failures==attempts, misses==0). Pre-this-round the {hits=0, misses=0}
    // metric was ambiguous between those two states, which sent the
    // previous diagnosis round chasing a non-issue.
    //
    // Invariant after every draw: `attempts == misses + failures`.
    struct PipelineCacheMetrics {
        std::uint64_t hits = 0;
        std::uint64_t misses = 0;             // successful first-time builds
        std::uint64_t buildAttempts = 0;      // every entry into the build branch
        std::uint64_t buildFailures = 0;      // builds that returned false
        double cumulativeBuildMillis = 0.0;
    };
    PipelineCacheMetrics pipelineCacheMetrics() const;
    void resetPipelineCacheMetrics();

    // Metal device allocated memory (bytes).  Returns 0 if device unavailable.
    std::uint64_t metalAllocatedBytes() const;
    std::uint64_t mslLibraryCacheEntries() const;
    struct InternalMetalResourceInventory {
        std::uint64_t bufferCount = 0;
        std::uint64_t bufferBytes = 0;
        std::uint64_t textureCount = 0;
        std::uint64_t textureBytes = 0;
        std::uint64_t drawableCount = 0;
        std::uint64_t drawableTextureBytes = 0;
        std::uint64_t samplerCount = 0;
        std::uint64_t renderPipelineCount = 0;
        std::uint64_t computePipelineCount = 0;
        std::uint64_t functionCount = 0;
        std::uint64_t libraryCount = 0;
        std::uint64_t depthStencilStateCount = 0;
        std::uint64_t binaryArchiveCount = 0;
    };
    InternalMetalResourceInventory internalMetalResourceInventory() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace appgl
