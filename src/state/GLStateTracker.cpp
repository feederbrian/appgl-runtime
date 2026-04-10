#include "GLStateTracker.h"

#include "../objects/GLObjectStore.h"

namespace appgl {

GLStateTracker::GLStateTracker() = default;

void GLStateTracker::setViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    viewport_ = {x, y, width > 0 ? width : 1, height > 0 ? height : 1};
    markDirty(DirtyBit::ViewportScissor);
}

const GLViewportState& GLStateTracker::viewport() const {
    return viewport_;
}

void GLStateTracker::setClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    clear_.color[0] = red;
    clear_.color[1] = green;
    clear_.color[2] = blue;
    clear_.color[3] = alpha;
}

void GLStateTracker::setClearDepth(GLdouble depth) {
    clear_.depth = depth;
}

void GLStateTracker::setClearStencil(GLint stencil) {
    clear_.stencil = stencil;
}

const GLClearState& GLStateTracker::clearState() const {
    return clear_;
}

void GLStateTracker::enable(GLenum cap) {
    enabledCaps_.insert(cap);
    markDirty(DirtyBit::DepthStencilState);
    markDirty(DirtyBit::BlendState);
    markDirty(DirtyBit::RasterState);
}

void GLStateTracker::disable(GLenum cap) {
    enabledCaps_.erase(cap);
    markDirty(DirtyBit::DepthStencilState);
    markDirty(DirtyBit::BlendState);
    markDirty(DirtyBit::RasterState);
}

bool GLStateTracker::isEnabled(GLenum cap) const {
    return enabledCaps_.contains(cap);
}

void GLStateTracker::bindBuffer(GLenum target, GLuint object) {
    bufferBindings_[target] = object;
    markDirty(target == GL_ELEMENT_ARRAY_BUFFER ? DirtyBit::VertexInput : DirtyBit::Framebuffer);
}

GLuint GLStateTracker::boundBuffer(GLenum target) const {
    const auto found = bufferBindings_.find(target);
    return found == bufferBindings_.end() ? 0 : found->second;
}

void GLStateTracker::bindTexture(GLenum target, GLuint object) {
    textureUnits_[activeTextureUnit_].bindings[target] = object;
    markDirty(DirtyBit::Program);
}

GLuint GLStateTracker::boundTexture(GLenum target) const {
    const auto& unit = textureUnits_[activeTextureUnit_];
    const auto found = unit.bindings.find(target);
    return found == unit.bindings.end() ? 0 : found->second;
}

void GLStateTracker::setActiveTextureUnit(GLuint unit) {
    if (unit < textureUnits_.size()) {
        activeTextureUnit_ = unit;
    }
}

GLuint GLStateTracker::activeTextureUnit() const {
    return activeTextureUnit_;
}

void GLStateTracker::bindVertexArray(GLuint vao) {
    currentVertexArray_ = vao;
    markDirty(DirtyBit::VertexInput);
}

GLuint GLStateTracker::boundVertexArray() const {
    return currentVertexArray_;
}

void GLStateTracker::bindDrawFramebuffer(GLuint framebuffer) {
    drawFramebuffer_ = framebuffer;
    markDirty(DirtyBit::Framebuffer);
}

GLuint GLStateTracker::boundDrawFramebuffer() const {
    return drawFramebuffer_;
}

void GLStateTracker::bindReadFramebuffer(GLuint framebuffer) {
    readFramebuffer_ = framebuffer;
    markDirty(DirtyBit::Framebuffer);
}

GLuint GLStateTracker::boundReadFramebuffer() const {
    return readFramebuffer_;
}

void GLStateTracker::useProgram(GLuint program) {
    currentProgram_ = program;
    markDirty(DirtyBit::Program);
}

GLuint GLStateTracker::currentProgram() const {
    return currentProgram_;
}

void GLStateTracker::markDirty(DirtyBit bit) {
    dirtyMask_ |= static_cast<std::uint32_t>(bit);
}

bool GLStateTracker::isDirty(DirtyBit bit) const {
    return (dirtyMask_ & static_cast<std::uint32_t>(bit)) != 0;
}

void GLStateTracker::clearDirty(DirtyBit bit) {
    dirtyMask_ &= ~static_cast<std::uint32_t>(bit);
}

std::uint32_t GLStateTracker::dirtyMask() const {
    return dirtyMask_;
}

void GLStateTracker::applyDirtyStateForDraw(GLObjectStore& objects) {
    (void)objects;
    dirtyMask_ = 0;
}

}  // namespace appgl
