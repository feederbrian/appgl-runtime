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

struct GLTextureUnitState {
    std::unordered_map<GLenum, GLuint> bindings;
    GLuint sampler = 0;
};

class GLStateTracker {
public:
    GLStateTracker();

    void setViewport(GLint x, GLint y, GLsizei width, GLsizei height);
    const GLViewportState& viewport() const;

    void setClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha);
    void setClearDepth(GLdouble depth);
    void setClearStencil(GLint stencil);
    const GLClearState& clearState() const;

    void enable(GLenum cap);
    void disable(GLenum cap);
    bool isEnabled(GLenum cap) const;

    void bindBuffer(GLenum target, GLuint object);
    GLuint boundBuffer(GLenum target) const;
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

    GLViewportState viewport_;
    GLDepthRangeState depthRange_;
    GLClearState clear_;
    std::unordered_set<GLenum> enabledCaps_;
    std::unordered_map<GLenum, GLuint> bufferBindings_;
    std::array<GLTextureUnitState, kMaxTextureUnits> textureUnits_;
    GLuint activeTextureUnit_ = 0;
    GLuint currentProgram_ = 0;
    GLuint currentVertexArray_ = 0;
    GLuint drawFramebuffer_ = 0;
    GLuint readFramebuffer_ = 0;
    std::uint32_t dirtyMask_ = 0xffffffffu;
};

}  // namespace appgl
