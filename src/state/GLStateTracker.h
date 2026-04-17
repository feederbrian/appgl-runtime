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
    GLint unpackSwapBytes = GL_FALSE;
    GLint unpackLsbFirst = GL_FALSE;
    GLint unpackRowLength = 0;
    GLint unpackSkipRows = 0;
    GLint unpackSkipPixels = 0;
    GLint unpackAlignment = 4;
    GLint unpackImageHeight = 0;
    GLint unpackSkipImages = 0;
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

    // Tessellation state (GL 4.0).
    void setPatchParameteri(GLenum pname, GLint value);
    void setPatchParameterfv(GLenum pname, const GLfloat* values);
    const GLTessellationState& tessellationState() const;

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

    // GL 4.5 ClipControl state.
    void setClipOrigin(GLenum origin);
    GLenum clipOrigin() const;
    void setClipDepthMode(GLenum depth);
    GLenum clipDepthMode() const;

    void markDirty(DirtyBit bit);
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
    static constexpr std::size_t kMaxTextureUnits = 32;
    static constexpr std::size_t kMaxDrawBuffers = 8;
    static constexpr std::size_t kMaxIndexedBufferBindings = 32;

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
    GLTessellationState tessellation_;
    GLBlendState blend_;
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
    GLuint currentVertexArray_ = 0;
    GLuint drawFramebuffer_ = 0;
    GLuint readFramebuffer_ = 0;
    std::uint32_t dirtyMask_ = 0xffffffffu;
    GLenum clipOrigin_ = GL_LOWER_LEFT;
    GLenum clipDepthMode_ = GL_NEGATIVE_ONE_TO_ONE;
};

}  // namespace appgl
