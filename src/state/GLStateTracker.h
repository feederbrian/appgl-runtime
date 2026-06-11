#pragma once

#include <array>
#include <cstdint>
#include <unordered_map>
#include <unordered_set>

#include "../../include/AppGL/glcorearb.h"

namespace appgl {

class GLObjectStore;

enum class DirtyBit : std::uint32_t {
    BlendState = 1u << 0u,
    DepthStencilState = 1u << 1u,
    RasterState = 1u << 2u,
    VertexInput = 1u << 3u,
    Program = 1u << 4u,
    Framebuffer = 1u << 5u,
    ViewportScissor = 1u << 6u,
};

struct GLViewportState {
    GLint x = 0;
    GLint y = 0;
    GLsizei width = 1;
    GLsizei height = 1;
};

struct GLDepthRangeState {
    GLdouble nearValue = 0.0;
    GLdouble farValue = 1.0;
};

struct GLClearState {
    GLfloat color[4] = {0.08f, 0.10f, 0.16f, 1.0f};
    GLdouble depth = 1.0;
    GLint stencil = 0;
};

struct GLScissorState {
    GLint x = 0;
    GLint y = 0;
    GLsizei width = 1;
    GLsizei height = 1;
};

struct GLBlendPerTarget {
    GLenum srcRGB = GL_ONE;
    GLenum dstRGB = GL_ZERO;
    GLenum srcAlpha = GL_ONE;
    GLenum dstAlpha = GL_ZERO;
    GLenum equationRGB = GL_FUNC_ADD;
    GLenum equationAlpha = GL_FUNC_ADD;
};

struct GLBlendState {
    GLenum srcRGB = GL_ONE;
    GLenum dstRGB = GL_ZERO;
    GLenum srcAlpha = GL_ONE;
    GLenum dstAlpha = GL_ZERO;
    GLenum equationRGB = GL_FUNC_ADD;
    GLenum equationAlpha = GL_FUNC_ADD;
    GLfloat color[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    std::array<GLboolean, 4> colorMask = {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE};
    std::array<std::array<GLboolean, 4>, 8> indexedColorMasks{};
    std::array<GLBlendPerTarget, 8> indexedBlend{};
    GLfloat minSampleShading = 0.0f;
};

struct GLDepthState {
    GLenum func = GL_LESS;
    GLboolean writeMask = GL_TRUE;
};

struct GLStencilFaceState {
    GLenum func = GL_ALWAYS;
    GLint ref = 0;
    GLuint valueMask = ~0u;
    GLenum fail = GL_KEEP;
    GLenum depthFail = GL_KEEP;
    GLenum depthPass = GL_KEEP;
    GLuint writeMask = ~0u;
};

struct GLStencilState {
    GLStencilFaceState front;
    GLStencilFaceState back;
};

struct GLRasterState {
    GLenum cullFaceMode = GL_BACK;
    GLenum frontFace = GL_CCW;
    GLenum polygonFillMode = GL_FILL;   // GL_FILL, GL_LINE, or GL_POINT
    GLfloat polygonOffsetFactor = 0.0f;
    GLfloat polygonOffsetUnits = 0.0f;
    GLfloat polygonOffsetClamp = 0.0f;
    GLfloat lineWidth = 1.0f;
    GLfloat pointSize = 1.0f;
};

struct GLTextureUnitState {
    std::unordered_map<GLenum, GLuint> bindings;
    GLuint sampler = 0;
};

struct GLPixelStoreState {
    GLint packSwapBytes = GL_FALSE;
    GLint packLsbFirst = GL_FALSE;
    GLint packRowLength = 0;
    GLint packSkipRows = 0;
    GLint packSkipPixels = 0;
    GLint packAlignment = 4;
    GLint packImageHeight = 0;
    GLint packSkipImages = 0;
    GLint packCompressedBlockWidth = 0;
    GLint packCompressedBlockHeight = 0;
    GLint packCompressedBlockDepth = 0;
    GLint packCompressedBlockSize = 0;
    GLint unpackSwapBytes = GL_FALSE;
    GLint unpackLsbFirst = GL_FALSE;
    GLint unpackRowLength = 0;
    GLint unpackSkipRows = 0;
    GLint unpackSkipPixels = 0;
    GLint unpackAlignment = 4;
    GLint unpackImageHeight = 0;
    GLint unpackSkipImages = 0;
    GLint unpackCompressedBlockWidth = 0;
    GLint unpackCompressedBlockHeight = 0;
    GLint unpackCompressedBlockDepth = 0;
    GLint unpackCompressedBlockSize = 0;
};

struct GLTessellationState {
    GLint patchVertices = 3;
    GLfloat defaultOuterLevel[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    GLfloat defaultInnerLevel[2] = {1.0f, 1.0f};
};

struct GLIndexedBufferBinding {
    GLuint buffer = 0;
    GLintptr offset = 0;
    GLsizeiptr size = 0;
};

class GLStateTracker {
public:
    GLStateTracker();

    void setViewport(GLint x, GLint y, GLsizei width, GLsizei height);
    const GLViewportState& viewport() const;

    void setScissor(GLint x, GLint y, GLsizei width, GLsizei height);
    const GLScissorState& scissor() const;

    void setDepthRange(GLdouble nearValue, GLdouble farValue);
    const GLDepthRangeState& depthRange() const;

    // Per-viewport-index state (GL 4.1 ARB_viewport_array).
    static constexpr std::size_t kMaxViewports = 16;
    void setViewportIndexed(GLuint index, GLfloat x, GLfloat y, GLfloat w, GLfloat h);
    void setViewportArray(GLuint first, GLsizei count, const GLfloat* v);
    void setScissorIndexed(GLuint index, GLint left, GLint bottom, GLsizei width, GLsizei height);
    void setScissorArray(GLuint first, GLsizei count, const GLint* v);
    void setDepthRangeIndexed(GLuint index, GLdouble nearVal, GLdouble farVal);
    void setDepthRangeArray(GLuint first, GLsizei count, const GLdouble* v);
    bool queryFloatIndexed(GLenum target, GLuint index, GLfloat* data) const;
    bool queryDoubleIndexed(GLenum target, GLuint index, GLdouble* data) const;
    // Sprint 15 Q3-Option-B Day 8 [metal-viewport-array]: bulk read
    // accessor for the kMaxViewports indexed-viewport array. Used by
    // MetalFrameGraph to bind multiple Metal viewports via
    // `setViewports:count:` when a draw uses gl_ViewportIndex routing.
    // Returns kMaxViewports (16) entries; caller decides how many to
    // pass to Metal based on draw-time program characteristics.
    struct IndexedViewportEntry {
        GLfloat x = 0;
        GLfloat y = 0;
        GLfloat width = 1;
        GLfloat height = 1;
        GLdouble depthNear = 0.0;
        GLdouble depthFar = 1.0;
    };
    void getViewportArray(IndexedViewportEntry* outArray,
                          std::size_t outCapacity,
                          std::size_t* outCount) const;
    // Sprint 16 Day 3 [viewport_array]: sister bulk read for the
    // indexed-scissor array. Mirrors getViewportArray; needed because
    // Metal's setScissorRects:count: must be matched 1:1 with
    // setViewports:count: when a draw uses gl_ViewportIndex routing.
    struct IndexedScissorEntry {
        GLint x = 0;
        GLint y = 0;
        GLsizei width = 1;
        GLsizei height = 1;
        bool enabled = false;
    };
    void getScissorArray(IndexedScissorEntry* outArray,
                         std::size_t outCapacity,
                         std::size_t* outCount) const;
    // Per-viewport SCISSOR_TEST state. GL 4.1 §17.3.2:
    //   Enable(SCISSOR_TEST)       → all slots TRUE
    //   Disable(SCISSOR_TEST)      → all slots FALSE
    //   Enablei(SCISSOR_TEST, i)   → slot i TRUE
    //   Disablei(SCISSOR_TEST, i)  → slot i FALSE
    //   IsEnabled(SCISSOR_TEST)    → slot 0
    //   IsEnabledi(SCISSOR_TEST,i) → slot i
    void setScissorTestIndexed(GLuint index, bool enabled);
    bool isScissorTestIndexedEnabled(GLuint index) const;

    // Tessellation state (GL 4.0).
    void setPatchParameteri(GLenum pname, GLint value);
    void setPatchParameterfv(GLenum pname, const GLfloat* values);
    const GLTessellationState& tessellationState() const;

    // Primitive-restart index (GL 3.1). Used by the drawElements
    // paths to skip restart indices when crediting
    // GL_VERTICES_SUBMITTED pipeline-stats queries, per GL 4.6 §22.3.
    void setPrimitiveRestartIndex(GLuint index);
    GLuint primitiveRestartIndex() const;

    // GL_ARB/KHR_parallel_shader_compile. Tracked for the query
    // round-trip; our compile path is synchronous so the stored
    // value has no backend effect.
    void setMaxShaderCompilerThreads(GLuint count);
    GLuint maxShaderCompilerThreads() const;

    void setClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
    void setClearDepth(GLdouble depth);
    void setClearStencil(GLint stencil);
    const GLClearState& clearState() const;

    void setBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha);
    void setBlendFuncSeparatei(GLuint index, GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha);
    void setBlendEquationSeparate(GLenum equationRGB, GLenum equationAlpha);
    void setBlendEquationSeparatei(GLuint index, GLenum equationRGB, GLenum equationAlpha);
    void setBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
    void setColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
    void setColorMaski(GLuint index, GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
    void setMinSampleShading(GLfloat value);
    const GLBlendState& blendState() const;
    void setSampleMask(GLuint index, GLbitfield mask);
    GLbitfield sampleMask(GLuint index) const;

    void setDepthFunc(GLenum func);
    void setDepthMask(GLboolean flag);
    const GLDepthState& depthState() const;

    void setStencilFuncSeparate(GLenum face, GLenum func, GLint ref, GLuint mask);
    void setStencilOpSeparate(GLenum face, GLenum fail, GLenum depthFail, GLenum depthPass);
    void setStencilMaskSeparate(GLenum face, GLuint mask);
    const GLStencilState& stencilState() const;

    void setCullFace(GLenum mode);
    void setFrontFace(GLenum mode);
    void setPolygonFillMode(GLenum mode);
    void setPolygonOffset(GLfloat factor, GLfloat units);
    void setPolygonOffsetClamp(GLfloat factor, GLfloat units, GLfloat clamp);
    void setLineWidth(GLfloat width);
    void setPointSize(GLfloat size);
    void setHint(GLenum target, GLenum mode);
    const GLRasterState& rasterState() const;

    void enable(GLenum cap);
    void disable(GLenum cap);
    bool isEnabled(GLenum cap) const;

    bool queryBoolean(GLenum pname, GLboolean* out) const;
    bool queryInteger(GLenum pname, GLint* out) const;
    bool queryInteger64(GLenum pname, GLint64* out) const;
    bool queryFloat(GLenum pname, GLfloat* out) const;
    bool queryDouble(GLenum pname, GLdouble* out) const;

    void bindBuffer(GLenum target, GLuint object);
    GLuint boundBuffer(GLenum target) const;
    void bindIndexedBuffer(GLenum target, GLuint index, GLuint object, GLintptr offset, GLsizeiptr size);
    GLIndexedBufferBinding indexedBufferBinding(GLenum target, GLuint index) const;
    void deleteBufferBindings(GLuint object);
    void bindTexture(GLenum target, GLuint object);
    GLuint boundTexture(GLenum target) const;
    // Phase 8X Group 4d follow-up⁷ — explicit-unit accessor used by the
    // draw-time sampler resolution path to read texture bindings from
    // units other than the active `glActiveTexture` pointer.
    GLuint boundTextureOnUnit(GLuint unit, GLenum target) const;
    // Any-target variant: returns the first non-zero texture bound to
    // `unit` across any target, along with its target via *outTarget.
    // Used by the draw-time sampler binding path when the shader's
    // sampler type can't be recovered from reflection (e.g. sampler2DArray,
    // samplerCube, usampler2D — any non-plain-2D binding).
    GLuint boundTextureOnUnitAny(GLuint unit, GLenum* outTarget) const;
    void deleteTextureBindings(GLuint object);
    void bindRenderbuffer(GLuint object);
    GLuint boundRenderbuffer() const;
    void deleteRenderbufferBinding(GLuint object);

    void setActiveTextureUnit(GLuint unit);
    GLuint activeTextureUnit() const;
    void bindSampler(GLuint unit, GLuint object);
    GLuint boundSampler(GLuint unit) const;
    void deleteSamplerBindings(GLuint object);

    void setPixelStore(GLenum pname, GLint value);
    const GLPixelStoreState& pixelStore() const;

    void bindVertexArray(GLuint vao);
    GLuint boundVertexArray() const;
    void bindDrawFramebuffer(GLuint framebuffer);
    GLuint boundDrawFramebuffer() const;
    void bindReadFramebuffer(GLuint framebuffer);
    GLuint boundReadFramebuffer() const;
    void deleteFramebufferBindings(GLuint framebuffer);
    bool setDrawBuffers(GLsizei count, const GLenum* buffers);
    GLenum drawBuffer(GLuint index) const;
    bool setReadBuffer(GLenum buffer);
    GLenum readBuffer() const;
    void useProgram(GLuint program);
    GLuint currentProgram() const;
    // GL 4.1 separable program pipelines (glBindProgramPipeline).
    // Stored here rather than in glBindProgramPipeline's entry-point
    // impl so drawArrays / drawElements can consult it when
    // `currentProgram() == 0` (a program pipeline supplies the
    // program stages instead of a single linked program). Returns
    // 0 when no pipeline is bound.
    void setCurrentProgramPipeline(GLuint pipeline);
    GLuint currentProgramPipeline() const;

    // GL 4.5 ClipControl state.
    void setClipOrigin(GLenum origin);
    GLenum clipOrigin() const;
    void setClipDepthMode(GLenum depth);
    GLenum clipDepthMode() const;

    void markDirty(DirtyBit bit);
    // C51 draw-prep memo: monotonic generation — bumped by every dirty
    // marking AND by binding mutators outside the DirtyBit system
    // (texture/sampler/indexed-buffer/VAO/program binds, plus explicit
    // context-side bumps for texture/sampler parameter edits). A
    // matching generation means no state-derived draw-prep input changed.
    std::uint64_t stateGeneration() const { return stateGeneration_; }
    void bumpStateGeneration() { ++stateGeneration_; }
    bool isDirty(DirtyBit bit) const;
    void clearDirty(DirtyBit bit);
    std::uint32_t dirtyMask() const;

    // Returns true if a draw command may proceed under the current state. In core
    // profile this rejects VAO 0 (the default vertex array) — bound by spec to be
    // GL_INVALID_OPERATION since 3.2 core. The caller is responsible for translating
    // a false return into the appropriate GL error and skipping applyDirtyStateForDraw.
    bool validateForDraw() const;

    void applyDirtyStateForDraw(GLObjectStore& objects);

private:
    // Matches advertised GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS (144) so
    // texture + sampler bindings at indices 0..143 all reach live
    // state slots. CTS `multi_bind.functional_bind_samplers`
    // probes index 48; prior 48-slot cap made queries past the
    // 48th unit return zero.
    static constexpr std::size_t kMaxTextureUnits = 144;
    static constexpr std::size_t kMaxDrawBuffers = 8;
    // Matches advertised GL_MAX_UNIFORM_BUFFER_BINDINGS (84) +
    // headroom for the other indexed buffer targets (TFB, SSBO,
    // atomic-counter). CTS `multi_bind.functional_bind_buffers_*`
    // probes UBO index 32 — the previous 32-slot cap left those
    // slots unreachable.
    static constexpr std::size_t kMaxIndexedBufferBindings = 96;

    GLViewportState viewport_;
    GLDepthRangeState depthRange_;
    GLClearState clear_;
    GLScissorState scissor_;
    // Per-viewport-index arrays for GL 4.1.
    struct IndexedViewport { GLfloat x = 0, y = 0, w = 1, h = 1; };
    struct IndexedScissor { GLint x = 0, y = 0; GLsizei w = 1, h = 1; };
    std::array<IndexedViewport, kMaxViewports> indexedViewports_{};
    std::array<IndexedScissor, kMaxViewports> indexedScissors_{};
    std::array<GLDepthRangeState, kMaxViewports> indexedDepthRanges_{};
    // Per-viewport SCISSOR_TEST enable bits (GL 4.1 §17.3.2). The
    // non-indexed `glEnable(SCISSOR_TEST)` is spec-equivalent to
    // setting every slot true; `glEnablei(SCISSOR_TEST, i)` sets
    // only slot i. Initial state per spec: all slots FALSE.
    std::array<bool, kMaxViewports> indexedScissorTest_{};
    GLTessellationState tessellation_;
    GLuint primitiveRestartIndex_ = 0;
    // GL_ARB/KHR_parallel_shader_compile. Our compile path is
    // synchronous so this is purely a round-trippable setting.
    // Initial value 0 — a consistent non-negative integer that
    // casts identically through every get query flavour. Spec
    // technically allows 0xFFFFFFFF (unlimited) but the CTS
    // `parallel_shader_compile.simple_queries` test's
    // cross-query-type comparison breaks on the GLint/GLfloat
    // casts of that value.
    GLuint maxShaderCompilerThreads_ = 0;
    GLBlendState blend_;
    std::array<GLbitfield, 1> sampleMasks_ = {~0u};
    GLDepthState depth_;
    GLStencilState stencil_;
    GLRasterState raster_;
    std::unordered_map<GLenum, GLenum> hints_;
    std::unordered_set<GLenum> enabledCaps_;
    std::unordered_map<GLenum, GLuint> bufferBindings_;
    std::unordered_map<GLenum, std::array<GLIndexedBufferBinding, kMaxIndexedBufferBindings>> indexedBufferBindings_;
    std::array<GLTextureUnitState, kMaxTextureUnits> textureUnits_;
    GLPixelStoreState pixelStore_;
    GLuint activeTextureUnit_ = 0;
    GLuint renderbuffer_ = 0;
    std::array<GLenum, kMaxDrawBuffers> drawBuffers_;
    GLenum readBuffer_ = GL_BACK;
    GLuint currentProgram_ = 0;
    GLuint currentProgramPipeline_ = 0;
    GLuint currentVertexArray_ = 0;
    GLuint drawFramebuffer_ = 0;
    GLuint readFramebuffer_ = 0;
    std::uint32_t dirtyMask_ = 0xffffffffu;
    std::uint64_t stateGeneration_ = 1;
    GLenum clipOrigin_ = GL_LOWER_LEFT;
    GLenum clipDepthMode_ = GL_NEGATIVE_ONE_TO_ONE;
};

}  // namespace appgl
