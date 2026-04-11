#include "GLStateTracker.h"

#include "../objects/GLObjectStore.h"

#include <algorithm>

namespace appgl {
namespace {

template <typename Destination, typename Source>
void writeScalar(Destination* out, Source value) {
    *out = static_cast<Destination>(value);
}

template <typename Source>
void writeScalar(GLboolean* out, Source value) {
    *out = value != 0 ? GL_TRUE : GL_FALSE;
}

template <typename Destination, typename Source>
void writeBooleanScalar(Destination* out, Source value) {
    *out = value ? GL_TRUE : GL_FALSE;
}

template <typename Destination>
void writeDepthRange(Destination* out, const GLDepthRangeState& range) {
    out[0] = static_cast<Destination>(range.nearValue);
    out[1] = static_cast<Destination>(range.farValue);
}

template <>
void writeDepthRange<GLboolean>(GLboolean* out, const GLDepthRangeState& range) {
    out[0] = range.nearValue != 0.0 ? GL_TRUE : GL_FALSE;
    out[1] = range.farValue != 0.0 ? GL_TRUE : GL_FALSE;
}

template <typename Destination>
void writeViewport(Destination* out, const GLViewportState& viewport) {
    out[0] = static_cast<Destination>(viewport.x);
    out[1] = static_cast<Destination>(viewport.y);
    out[2] = static_cast<Destination>(viewport.width);
    out[3] = static_cast<Destination>(viewport.height);
}

template <>
void writeViewport<GLboolean>(GLboolean* out, const GLViewportState& viewport) {
    out[0] = viewport.x != 0 ? GL_TRUE : GL_FALSE;
    out[1] = viewport.y != 0 ? GL_TRUE : GL_FALSE;
    out[2] = viewport.width != 0 ? GL_TRUE : GL_FALSE;
    out[3] = viewport.height != 0 ? GL_TRUE : GL_FALSE;
}

template <typename Destination>
void writeScissor(Destination* out, const GLScissorState& scissor) {
    out[0] = static_cast<Destination>(scissor.x);
    out[1] = static_cast<Destination>(scissor.y);
    out[2] = static_cast<Destination>(scissor.width);
    out[3] = static_cast<Destination>(scissor.height);
}

template <>
void writeScissor<GLboolean>(GLboolean* out, const GLScissorState& scissor) {
    out[0] = scissor.x != 0 ? GL_TRUE : GL_FALSE;
    out[1] = scissor.y != 0 ? GL_TRUE : GL_FALSE;
    out[2] = scissor.width != 0 ? GL_TRUE : GL_FALSE;
    out[3] = scissor.height != 0 ? GL_TRUE : GL_FALSE;
}

template <typename Destination>
void writeFloat4(Destination* out, const GLfloat* values) {
    out[0] = static_cast<Destination>(values[0]);
    out[1] = static_cast<Destination>(values[1]);
    out[2] = static_cast<Destination>(values[2]);
    out[3] = static_cast<Destination>(values[3]);
}

template <>
void writeFloat4<GLboolean>(GLboolean* out, const GLfloat* values) {
    out[0] = values[0] != 0.0f ? GL_TRUE : GL_FALSE;
    out[1] = values[1] != 0.0f ? GL_TRUE : GL_FALSE;
    out[2] = values[2] != 0.0f ? GL_TRUE : GL_FALSE;
    out[3] = values[3] != 0.0f ? GL_TRUE : GL_FALSE;
}

template <typename Destination>
void writeBoolean4(Destination* out, const std::array<GLboolean, 4>& values) {
    out[0] = static_cast<Destination>(values[0]);
    out[1] = static_cast<Destination>(values[1]);
    out[2] = static_cast<Destination>(values[2]);
    out[3] = static_cast<Destination>(values[3]);
}

template <typename Destination>
bool queryValue(
    GLenum pname,
    Destination* out,
    const GLViewportState& viewport,
    const GLScissorState& scissor,
    const GLDepthRangeState& depthRange,
    const GLClearState& clear,
    const GLBlendState& blend,
    const GLDepthState& depth,
    const GLStencilState& stencil,
    const GLRasterState& raster,
    const std::unordered_set<GLenum>& enabledCaps,
    const std::unordered_map<GLenum, GLuint>& bufferBindings,
    const std::unordered_map<GLenum, GLenum>& hints,
    GLuint activeTextureUnit,
    GLuint currentProgram,
    GLuint currentVertexArray,
    GLuint drawFramebuffer,
    GLuint readFramebuffer
) {
    if (out == nullptr) {
        return false;
    }

    const auto enabled = [&](GLenum cap) {
        return enabledCaps.contains(cap);
    };
    const auto boundBuffer = [&](GLenum target) {
        const auto found = bufferBindings.find(target);
        return found == bufferBindings.end() ? 0u : found->second;
    };
    if (pname >= GL_CLIP_DISTANCE0 && pname <= GL_CLIP_DISTANCE7) {
        writeBooleanScalar(out, enabled(pname));
        return true;
    }

    switch (pname) {
        case GL_VIEWPORT:
            writeViewport(out, viewport);
            return true;
        case GL_SCISSOR_BOX:
            writeScissor(out, scissor);
            return true;
        case GL_DEPTH_RANGE:
            writeDepthRange(out, depthRange);
            return true;
        case GL_COLOR_CLEAR_VALUE:
            writeFloat4(out, clear.color);
            return true;
        case GL_DEPTH_CLEAR_VALUE:
            writeScalar(out, clear.depth);
            return true;
        case GL_STENCIL_CLEAR_VALUE:
            writeScalar(out, clear.stencil);
            return true;
        case GL_BLEND:
        case GL_CULL_FACE:
        case GL_DEBUG_OUTPUT:
        case GL_DEBUG_OUTPUT_SYNCHRONOUS:
        case GL_DEPTH_TEST:
        case GL_DITHER:
        case GL_LINE_SMOOTH:
        case GL_POLYGON_OFFSET_LINE:
        case GL_POLYGON_OFFSET_POINT:
        case GL_POLYGON_OFFSET_FILL:
        case GL_POLYGON_SMOOTH:
        case GL_SAMPLE_COVERAGE:
        case GL_SCISSOR_TEST:
        case GL_STENCIL_TEST:
        case GL_MULTISAMPLE:
        case GL_RASTERIZER_DISCARD:
        case GL_FRAMEBUFFER_SRGB:
        case GL_PRIMITIVE_RESTART:
        case GL_PRIMITIVE_RESTART_FIXED_INDEX:
        case GL_TEXTURE_CUBE_MAP_SEAMLESS:
        case GL_PROGRAM_POINT_SIZE:
        case GL_SAMPLE_ALPHA_TO_COVERAGE:
        case GL_SAMPLE_ALPHA_TO_ONE:
        case GL_SAMPLE_MASK:
            writeBooleanScalar(out, enabled(pname));
            return true;
        case GL_BLEND_SRC:
        case GL_BLEND_SRC_RGB:
            writeScalar(out, blend.srcRGB);
            return true;
        case GL_BLEND_DST:
        case GL_BLEND_DST_RGB:
            writeScalar(out, blend.dstRGB);
            return true;
        case GL_BLEND_SRC_ALPHA:
            writeScalar(out, blend.srcAlpha);
            return true;
        case GL_BLEND_DST_ALPHA:
            writeScalar(out, blend.dstAlpha);
            return true;
        case GL_BLEND_EQUATION_RGB:
            writeScalar(out, blend.equationRGB);
            return true;
        case GL_BLEND_EQUATION_ALPHA:
            writeScalar(out, blend.equationAlpha);
            return true;
        case GL_BLEND_COLOR:
            writeFloat4(out, blend.color);
            return true;
        case GL_COLOR_WRITEMASK:
            writeBoolean4(out, blend.colorMask);
            return true;
        case GL_DEPTH_FUNC:
            writeScalar(out, depth.func);
            return true;
        case GL_DEPTH_WRITEMASK:
            writeBooleanScalar(out, depth.writeMask == GL_TRUE);
            return true;
        case GL_STENCIL_FUNC:
            writeScalar(out, stencil.front.func);
            return true;
        case GL_STENCIL_REF:
            writeScalar(out, stencil.front.ref);
            return true;
        case GL_STENCIL_VALUE_MASK:
            writeScalar(out, stencil.front.valueMask);
            return true;
        case GL_STENCIL_FAIL:
            writeScalar(out, stencil.front.fail);
            return true;
        case GL_STENCIL_PASS_DEPTH_FAIL:
            writeScalar(out, stencil.front.depthFail);
            return true;
        case GL_STENCIL_PASS_DEPTH_PASS:
            writeScalar(out, stencil.front.depthPass);
            return true;
        case GL_STENCIL_WRITEMASK:
            writeScalar(out, stencil.front.writeMask);
            return true;
        case GL_STENCIL_BACK_FUNC:
            writeScalar(out, stencil.back.func);
            return true;
        case GL_STENCIL_BACK_REF:
            writeScalar(out, stencil.back.ref);
            return true;
        case GL_STENCIL_BACK_VALUE_MASK:
            writeScalar(out, stencil.back.valueMask);
            return true;
        case GL_STENCIL_BACK_FAIL:
            writeScalar(out, stencil.back.fail);
            return true;
        case GL_STENCIL_BACK_PASS_DEPTH_FAIL:
            writeScalar(out, stencil.back.depthFail);
            return true;
        case GL_STENCIL_BACK_PASS_DEPTH_PASS:
            writeScalar(out, stencil.back.depthPass);
            return true;
        case GL_STENCIL_BACK_WRITEMASK:
            writeScalar(out, stencil.back.writeMask);
            return true;
        case GL_CULL_FACE_MODE:
            writeScalar(out, raster.cullFaceMode);
            return true;
        case GL_FRONT_FACE:
            writeScalar(out, raster.frontFace);
            return true;
        case GL_POLYGON_OFFSET_FACTOR:
            writeScalar(out, raster.polygonOffsetFactor);
            return true;
        case GL_POLYGON_OFFSET_UNITS:
            writeScalar(out, raster.polygonOffsetUnits);
            return true;
        case GL_LINE_WIDTH:
            writeScalar(out, raster.lineWidth);
            return true;
        case GL_POINT_SIZE:
            writeScalar(out, raster.pointSize);
            return true;
        case GL_FRAGMENT_SHADER_DERIVATIVE_HINT:
        case GL_LINE_SMOOTH_HINT:
        case GL_POLYGON_SMOOTH_HINT:
        case GL_TEXTURE_COMPRESSION_HINT: {
            const auto found = hints.find(pname);
            writeScalar(out, found == hints.end() ? GL_DONT_CARE : found->second);
            return true;
        }
        case GL_ACTIVE_TEXTURE:
            writeScalar(out, GL_TEXTURE0 + activeTextureUnit);
            return true;
        case GL_ARRAY_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_ARRAY_BUFFER));
            return true;
        case GL_ELEMENT_ARRAY_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_ELEMENT_ARRAY_BUFFER));
            return true;
        case GL_COPY_READ_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_COPY_READ_BUFFER));
            return true;
        case GL_COPY_WRITE_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_COPY_WRITE_BUFFER));
            return true;
        case GL_PIXEL_PACK_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_PIXEL_PACK_BUFFER));
            return true;
        case GL_PIXEL_UNPACK_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_PIXEL_UNPACK_BUFFER));
            return true;
        case GL_TRANSFORM_FEEDBACK_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_TRANSFORM_FEEDBACK_BUFFER));
            return true;
        case GL_UNIFORM_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_UNIFORM_BUFFER));
            return true;
        case GL_TEXTURE_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_TEXTURE_BUFFER));
            return true;
        case GL_DRAW_INDIRECT_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_DRAW_INDIRECT_BUFFER));
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_ATOMIC_COUNTER_BUFFER));
            return true;
        case GL_DISPATCH_INDIRECT_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_DISPATCH_INDIRECT_BUFFER));
            return true;
        case GL_SHADER_STORAGE_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_SHADER_STORAGE_BUFFER));
            return true;
        case GL_QUERY_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_QUERY_BUFFER));
            return true;
        case GL_PARAMETER_BUFFER_BINDING:
            writeScalar(out, boundBuffer(GL_PARAMETER_BUFFER));
            return true;
        case GL_CURRENT_PROGRAM:
            writeScalar(out, currentProgram);
            return true;
        case GL_VERTEX_ARRAY_BINDING:
            writeScalar(out, currentVertexArray);
            return true;
        case GL_DRAW_FRAMEBUFFER_BINDING:
            writeScalar(out, drawFramebuffer);
            return true;
        case GL_READ_FRAMEBUFFER_BINDING:
            writeScalar(out, readFramebuffer);
            return true;
        default:
            return false;
    }
}

}  // namespace

GLStateTracker::GLStateTracker() {
    for (auto& mask : blend_.indexedColorMasks) {
        mask = {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE};
    }
}

void GLStateTracker::setViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    viewport_ = {x, y, width, height};
    markDirty(DirtyBit::ViewportScissor);
}

const GLViewportState& GLStateTracker::viewport() const {
    return viewport_;
}

void GLStateTracker::setScissor(GLint x, GLint y, GLsizei width, GLsizei height) {
    scissor_ = {x, y, width, height};
    markDirty(DirtyBit::ViewportScissor);
}

const GLScissorState& GLStateTracker::scissor() const {
    return scissor_;
}

void GLStateTracker::setDepthRange(GLdouble nearValue, GLdouble farValue) {
    depthRange_.nearValue = std::clamp(nearValue, 0.0, 1.0);
    depthRange_.farValue = std::clamp(farValue, 0.0, 1.0);
    markDirty(DirtyBit::DepthStencilState);
}

const GLDepthRangeState& GLStateTracker::depthRange() const {
    return depthRange_;
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

void GLStateTracker::setBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha) {
    blend_.srcRGB = srcRGB;
    blend_.dstRGB = dstRGB;
    blend_.srcAlpha = srcAlpha;
    blend_.dstAlpha = dstAlpha;
    markDirty(DirtyBit::BlendState);
}

void GLStateTracker::setBlendEquationSeparate(GLenum equationRGB, GLenum equationAlpha) {
    blend_.equationRGB = equationRGB;
    blend_.equationAlpha = equationAlpha;
    markDirty(DirtyBit::BlendState);
}

void GLStateTracker::setBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    blend_.color[0] = std::clamp(red, 0.0f, 1.0f);
    blend_.color[1] = std::clamp(green, 0.0f, 1.0f);
    blend_.color[2] = std::clamp(blue, 0.0f, 1.0f);
    blend_.color[3] = std::clamp(alpha, 0.0f, 1.0f);
    markDirty(DirtyBit::BlendState);
}

void GLStateTracker::setColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha) {
    blend_.colorMask = {red, green, blue, alpha};
    for (auto& mask : blend_.indexedColorMasks) {
        mask = blend_.colorMask;
    }
    markDirty(DirtyBit::BlendState);
}

void GLStateTracker::setColorMaski(GLuint index, GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha) {
    if (index >= blend_.indexedColorMasks.size()) {
        return;
    }
    blend_.indexedColorMasks[index] = {red, green, blue, alpha};
    if (index == 0) {
        blend_.colorMask = blend_.indexedColorMasks[index];
    }
    markDirty(DirtyBit::BlendState);
}

const GLBlendState& GLStateTracker::blendState() const {
    return blend_;
}

void GLStateTracker::setDepthFunc(GLenum func) {
    depth_.func = func;
    markDirty(DirtyBit::DepthStencilState);
}

void GLStateTracker::setDepthMask(GLboolean flag) {
    depth_.writeMask = flag;
    markDirty(DirtyBit::DepthStencilState);
}

const GLDepthState& GLStateTracker::depthState() const {
    return depth_;
}

void GLStateTracker::setStencilFuncSeparate(GLenum face, GLenum func, GLint ref, GLuint mask) {
    auto apply = [&](GLStencilFaceState& state) {
        state.func = func;
        state.ref = ref;
        state.valueMask = mask;
    };
    if (face == GL_FRONT || face == GL_FRONT_AND_BACK) {
        apply(stencil_.front);
    }
    if (face == GL_BACK || face == GL_FRONT_AND_BACK) {
        apply(stencil_.back);
    }
    markDirty(DirtyBit::DepthStencilState);
}

void GLStateTracker::setStencilOpSeparate(GLenum face, GLenum fail, GLenum depthFail, GLenum depthPass) {
    auto apply = [&](GLStencilFaceState& state) {
        state.fail = fail;
        state.depthFail = depthFail;
        state.depthPass = depthPass;
    };
    if (face == GL_FRONT || face == GL_FRONT_AND_BACK) {
        apply(stencil_.front);
    }
    if (face == GL_BACK || face == GL_FRONT_AND_BACK) {
        apply(stencil_.back);
    }
    markDirty(DirtyBit::DepthStencilState);
}

void GLStateTracker::setStencilMaskSeparate(GLenum face, GLuint mask) {
    if (face == GL_FRONT || face == GL_FRONT_AND_BACK) {
        stencil_.front.writeMask = mask;
    }
    if (face == GL_BACK || face == GL_FRONT_AND_BACK) {
        stencil_.back.writeMask = mask;
    }
    markDirty(DirtyBit::DepthStencilState);
}

const GLStencilState& GLStateTracker::stencilState() const {
    return stencil_;
}

void GLStateTracker::setCullFace(GLenum mode) {
    raster_.cullFaceMode = mode;
    markDirty(DirtyBit::RasterState);
}

void GLStateTracker::setFrontFace(GLenum mode) {
    raster_.frontFace = mode;
    markDirty(DirtyBit::RasterState);
}

void GLStateTracker::setPolygonOffset(GLfloat factor, GLfloat units) {
    raster_.polygonOffsetFactor = factor;
    raster_.polygonOffsetUnits = units;
    markDirty(DirtyBit::RasterState);
}

void GLStateTracker::setLineWidth(GLfloat width) {
    raster_.lineWidth = width;
    markDirty(DirtyBit::RasterState);
}

void GLStateTracker::setPointSize(GLfloat size) {
    raster_.pointSize = size;
    markDirty(DirtyBit::RasterState);
}

void GLStateTracker::setHint(GLenum target, GLenum mode) {
    hints_[target] = mode;
}

const GLRasterState& GLStateTracker::rasterState() const {
    return raster_;
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

bool GLStateTracker::queryBoolean(GLenum pname, GLboolean* out) const {
    return queryValue(
        pname,
        out,
        viewport_,
        scissor_,
        depthRange_,
        clear_,
        blend_,
        depth_,
        stencil_,
        raster_,
        enabledCaps_,
        bufferBindings_,
        hints_,
        activeTextureUnit_,
        currentProgram_,
        currentVertexArray_,
        drawFramebuffer_,
        readFramebuffer_
    );
}

bool GLStateTracker::queryInteger(GLenum pname, GLint* out) const {
    return queryValue(
        pname,
        out,
        viewport_,
        scissor_,
        depthRange_,
        clear_,
        blend_,
        depth_,
        stencil_,
        raster_,
        enabledCaps_,
        bufferBindings_,
        hints_,
        activeTextureUnit_,
        currentProgram_,
        currentVertexArray_,
        drawFramebuffer_,
        readFramebuffer_
    );
}

bool GLStateTracker::queryInteger64(GLenum pname, GLint64* out) const {
    return queryValue(
        pname,
        out,
        viewport_,
        scissor_,
        depthRange_,
        clear_,
        blend_,
        depth_,
        stencil_,
        raster_,
        enabledCaps_,
        bufferBindings_,
        hints_,
        activeTextureUnit_,
        currentProgram_,
        currentVertexArray_,
        drawFramebuffer_,
        readFramebuffer_
    );
}

bool GLStateTracker::queryFloat(GLenum pname, GLfloat* out) const {
    return queryValue(
        pname,
        out,
        viewport_,
        scissor_,
        depthRange_,
        clear_,
        blend_,
        depth_,
        stencil_,
        raster_,
        enabledCaps_,
        bufferBindings_,
        hints_,
        activeTextureUnit_,
        currentProgram_,
        currentVertexArray_,
        drawFramebuffer_,
        readFramebuffer_
    );
}

bool GLStateTracker::queryDouble(GLenum pname, GLdouble* out) const {
    return queryValue(
        pname,
        out,
        viewport_,
        scissor_,
        depthRange_,
        clear_,
        blend_,
        depth_,
        stencil_,
        raster_,
        enabledCaps_,
        bufferBindings_,
        hints_,
        activeTextureUnit_,
        currentProgram_,
        currentVertexArray_,
        drawFramebuffer_,
        readFramebuffer_
    );
}

void GLStateTracker::bindBuffer(GLenum target, GLuint object) {
    bufferBindings_[target] = object;
    markDirty(target == GL_ELEMENT_ARRAY_BUFFER ? DirtyBit::VertexInput : DirtyBit::Framebuffer);
}

GLuint GLStateTracker::boundBuffer(GLenum target) const {
    const auto found = bufferBindings_.find(target);
    return found == bufferBindings_.end() ? 0 : found->second;
}

void GLStateTracker::bindIndexedBuffer(GLenum target, GLuint index, GLuint object, GLintptr offset, GLsizeiptr size) {
    auto& bindings = indexedBufferBindings_[target];
    if (index >= bindings.size()) {
        return;
    }
    bindings[index] = {object, offset, size};
    bindBuffer(target, object);
}

GLIndexedBufferBinding GLStateTracker::indexedBufferBinding(GLenum target, GLuint index) const {
    const auto found = indexedBufferBindings_.find(target);
    if (found == indexedBufferBindings_.end() || index >= found->second.size()) {
        return {};
    }
    return found->second[index];
}

void GLStateTracker::deleteBufferBindings(GLuint object) {
    if (object == 0) {
        return;
    }
    for (auto& [target, boundObject] : bufferBindings_) {
        (void)target;
        if (boundObject == object) {
            boundObject = 0;
        }
    }
    for (auto& [target, bindings] : indexedBufferBindings_) {
        (void)target;
        for (auto& binding : bindings) {
            if (binding.buffer == object) {
                binding = {};
            }
        }
    }
    markDirty(DirtyBit::VertexInput);
    markDirty(DirtyBit::Program);
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
