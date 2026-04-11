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
    GLfloat polygonOffsetFactor = 0.0f;
    GLfloat polygonOffsetUnits = 0.0f;
    GLfloat lineWidth = 1.0f;
    GLfloat pointSize = 1.0f;
};

struct GLTextureUnitState {
    std::unordered_map<GLenum, GLuint> bindings;
    GLuint sampler = 0;
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

    void setClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
    void setClearDepth(GLdouble depth);
    void setClearStencil(GLint stencil);
    const GLClearState& clearState() const;

    void setBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha);
    void setBlendEquationSeparate(GLenum equationRGB, GLenum equationAlpha);
    void setBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
    void setColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
    void setColorMaski(GLuint index, GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha);
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
    void setPolygonOffset(GLfloat factor, GLfloat units);
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

    void setActiveTextureUnit(GLuint unit);
    GLuint activeTextureUnit() const;

    void bindVertexArray(GLuint vao);
    GLuint boundVertexArray() const;
    void bindDrawFramebuffer(GLuint framebuffer);
    GLuint boundDrawFramebuffer() const;
    void bindReadFramebuffer(GLuint framebuffer);
    GLuint boundReadFramebuffer() const;
    void useProgram(GLuint program);
    GLuint currentProgram() const;

    void markDirty(DirtyBit bit);
    bool isDirty(DirtyBit bit) const;
    void clearDirty(DirtyBit bit);
    std::uint32_t dirtyMask() const;

    void applyDirtyStateForDraw(GLObjectStore& objects);

private:
    static constexpr std::size_t kMaxTextureUnits = 32;
    static constexpr std::size_t kMaxDrawBuffers = 8;
    static constexpr std::size_t kMaxIndexedBufferBindings = 32;

    GLViewportState viewport_;
    GLDepthRangeState depthRange_;
    GLClearState clear_;
    GLScissorState scissor_;
    GLBlendState blend_;
    GLDepthState depth_;
    GLStencilState stencil_;
    GLRasterState raster_;
    std::unordered_map<GLenum, GLenum> hints_;
    std::unordered_set<GLenum> enabledCaps_;
    std::unordered_map<GLenum, GLuint> bufferBindings_;
    std::unordered_map<GLenum, std::array<GLIndexedBufferBinding, kMaxIndexedBufferBindings>> indexedBufferBindings_;
    std::array<GLTextureUnitState, kMaxTextureUnits> textureUnits_;
    GLuint activeTextureUnit_ = 0;
    GLuint currentProgram_ = 0;
    GLuint currentVertexArray_ = 0;
    GLuint drawFramebuffer_ = 0;
    GLuint readFramebuffer_ = 0;
    std::uint32_t dirtyMask_ = 0xffffffffu;
};

}  // namespace appgl
