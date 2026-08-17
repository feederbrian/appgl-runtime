#include "GLStateTracker.h"

#include "MetalVertexDescriptorBuilder.h"
#include "../objects/GLObjectStore.h"
#include "../runtime/AppGLProfile.h"

#include <algorithm>
#include <cmath>
#include <type_traits>
#include <utility>

#ifndef GL_FOG_START
#define GL_FOG_START 0x0B63
#endif
#ifndef GL_ALPHA_TEST_FUNC
#define GL_ALPHA_TEST_FUNC 0x0BC1
#endif
#ifndef GL_ALPHA_TEST_REF
#define GL_ALPHA_TEST_REF 0x0BC2
#endif
#ifndef GL_VERTEX_PROGRAM_TWO_SIDE
#define GL_VERTEX_PROGRAM_TWO_SIDE 0x8643
#endif
#ifndef GL_COLOR_SUM
#define GL_COLOR_SUM 0x8458
#endif
// R1.0-c item #14 — compat antialiasing/stipple state. See the matching
// allowlist entries in AppGLRuntime.cpp (isValidEnableCap / isValidHintTarget).
#ifndef GL_POINT_SMOOTH
#define GL_POINT_SMOOTH 0x0B10
#endif
#ifndef GL_POLYGON_STIPPLE
#define GL_POLYGON_STIPPLE 0x0B42
#endif
#ifndef GL_POINT_SMOOTH_HINT
#define GL_POINT_SMOOTH_HINT 0x0C51
#endif

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
Destination roundFloatStateToInteger(GLfloat value) {
    // GL Get integer conversion rounds floating-point state to nearest
    // independent of the process floating-point rounding mode.
    return static_cast<Destination>(std::floor(static_cast<GLdouble>(value) + 0.5));
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
    const std::array<GLbitfield, 1>& sampleMasks,
    const GLDepthState& depth,
    const GLStencilState& stencil,
    const GLRasterState& raster,
    const std::unordered_set<GLenum>& enabledCaps,
    const std::unordered_map<GLenum, GLuint>& bufferBindings,
    const std::unordered_map<GLenum, GLenum>& hints,
    const GLTextureUnitState& activeTextureUnitState,
    const GLPixelStoreState& pixelStore,
    GLuint activeTextureUnit,
    GLuint renderbuffer,
    const std::array<GLenum, 8>& drawBuffers,
    GLenum readBuffer,
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
    const auto boundTexture = [&](GLenum target) {
        const auto found = activeTextureUnitState.bindings.find(target);
        return found == activeTextureUnitState.bindings.end() ? 0u : found->second;
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
        case GL_ALPHA_TEST:
        case GL_COLOR_SUM:
        case GL_CULL_FACE:
        case GL_DEBUG_OUTPUT:
        case GL_DEBUG_OUTPUT_SYNCHRONOUS:
        case GL_DEPTH_CLAMP:
        case GL_DEPTH_TEST:
        case GL_DITHER:
        case GL_LINE_SMOOTH:
        case GL_POLYGON_OFFSET_LINE:
        case GL_POLYGON_OFFSET_POINT:
        case GL_POLYGON_OFFSET_FILL:
        case GL_POLYGON_SMOOTH:
        case GL_POINT_SMOOTH:
        case GL_POLYGON_STIPPLE:
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
        case GL_VERTEX_PROGRAM_TWO_SIDE:
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
        case GL_SAMPLE_MASK_VALUE:
            writeScalar(out, sampleMasks[0]);
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
        case GL_POLYGON_OFFSET_CLAMP:
            writeScalar(out, raster.polygonOffsetClamp);
            return true;
        case GL_LINE_WIDTH:
            writeScalar(out, raster.lineWidth);
            return true;
        case GL_POINT_SIZE:
            writeScalar(out, raster.pointSize);
            return true;
        case GL_POINT_SPRITE_COORD_ORIGIN:
            writeScalar(out, raster.pointSpriteCoordOrigin);
            return true;
        case GL_FRAGMENT_SHADER_DERIVATIVE_HINT:
        case GL_LINE_SMOOTH_HINT:
        case GL_POLYGON_SMOOTH_HINT:
        case GL_POINT_SMOOTH_HINT:
        case GL_TEXTURE_COMPRESSION_HINT: {
            const auto found = hints.find(pname);
            writeScalar(out, found == hints.end() ? GL_DONT_CARE : found->second);
            return true;
        }
        case GL_ACTIVE_TEXTURE:
            writeScalar(out, GL_TEXTURE0 + activeTextureUnit);
            return true;
        case GL_TEXTURE_BINDING_1D:
            writeScalar(out, boundTexture(GL_TEXTURE_1D));
            return true;
        case GL_TEXTURE_BINDING_2D:
            writeScalar(out, boundTexture(GL_TEXTURE_2D));
            return true;
        case GL_TEXTURE_BINDING_3D:
            writeScalar(out, boundTexture(GL_TEXTURE_3D));
            return true;
        case GL_TEXTURE_BINDING_1D_ARRAY:
            writeScalar(out, boundTexture(GL_TEXTURE_1D_ARRAY));
            return true;
        case GL_TEXTURE_BINDING_2D_ARRAY:
            writeScalar(out, boundTexture(GL_TEXTURE_2D_ARRAY));
            return true;
        case GL_TEXTURE_BINDING_CUBE_MAP:
            writeScalar(out, boundTexture(GL_TEXTURE_CUBE_MAP));
            return true;
        case GL_TEXTURE_BINDING_CUBE_MAP_ARRAY:
            writeScalar(out, boundTexture(GL_TEXTURE_CUBE_MAP_ARRAY));
            return true;
        case GL_TEXTURE_BINDING_RECTANGLE:
            writeScalar(out, boundTexture(GL_TEXTURE_RECTANGLE));
            return true;
        case GL_TEXTURE_BINDING_BUFFER:
            writeScalar(out, boundTexture(GL_TEXTURE_BUFFER));
            return true;
        case GL_TEXTURE_BINDING_2D_MULTISAMPLE:
            writeScalar(out, boundTexture(GL_TEXTURE_2D_MULTISAMPLE));
            return true;
        case GL_TEXTURE_BINDING_2D_MULTISAMPLE_ARRAY:
            writeScalar(out, boundTexture(GL_TEXTURE_2D_MULTISAMPLE_ARRAY));
            return true;
        case GL_SAMPLER_BINDING:
            writeScalar(out, activeTextureUnitState.sampler);
            return true;
        case GL_RENDERBUFFER_BINDING:
            writeScalar(out, renderbuffer);
            return true;
        case GL_DRAW_BUFFER:
            writeScalar(out, drawBuffers[0]);
            return true;
        case GL_READ_BUFFER:
            writeScalar(out, readBuffer);
            return true;
        case GL_PACK_SWAP_BYTES:
            writeBooleanScalar(out, pixelStore.packSwapBytes == GL_TRUE);
            return true;
        case GL_PACK_LSB_FIRST:
            writeBooleanScalar(out, pixelStore.packLsbFirst == GL_TRUE);
            return true;
        case GL_PACK_ROW_LENGTH:
            writeScalar(out, pixelStore.packRowLength);
            return true;
        case GL_PACK_SKIP_ROWS:
            writeScalar(out, pixelStore.packSkipRows);
            return true;
        case GL_PACK_SKIP_PIXELS:
            writeScalar(out, pixelStore.packSkipPixels);
            return true;
        case GL_PACK_ALIGNMENT:
            writeScalar(out, pixelStore.packAlignment);
            return true;
        case GL_PACK_IMAGE_HEIGHT:
            writeScalar(out, pixelStore.packImageHeight);
            return true;
        case GL_PACK_SKIP_IMAGES:
            writeScalar(out, pixelStore.packSkipImages);
            return true;
        case GL_PACK_COMPRESSED_BLOCK_WIDTH:
            writeScalar(out, pixelStore.packCompressedBlockWidth);
            return true;
        case GL_PACK_COMPRESSED_BLOCK_HEIGHT:
            writeScalar(out, pixelStore.packCompressedBlockHeight);
            return true;
        case GL_PACK_COMPRESSED_BLOCK_DEPTH:
            writeScalar(out, pixelStore.packCompressedBlockDepth);
            return true;
        case GL_PACK_COMPRESSED_BLOCK_SIZE:
            writeScalar(out, pixelStore.packCompressedBlockSize);
            return true;
        case GL_UNPACK_SWAP_BYTES:
            writeBooleanScalar(out, pixelStore.unpackSwapBytes == GL_TRUE);
            return true;
        case GL_UNPACK_LSB_FIRST:
            writeBooleanScalar(out, pixelStore.unpackLsbFirst == GL_TRUE);
            return true;
        case GL_UNPACK_ROW_LENGTH:
            writeScalar(out, pixelStore.unpackRowLength);
            return true;
        case GL_UNPACK_SKIP_ROWS:
            writeScalar(out, pixelStore.unpackSkipRows);
            return true;
        case GL_UNPACK_SKIP_PIXELS:
            writeScalar(out, pixelStore.unpackSkipPixels);
            return true;
        case GL_UNPACK_ALIGNMENT:
            writeScalar(out, pixelStore.unpackAlignment);
            return true;
        case GL_UNPACK_IMAGE_HEIGHT:
            writeScalar(out, pixelStore.unpackImageHeight);
            return true;
        case GL_UNPACK_SKIP_IMAGES:
            writeScalar(out, pixelStore.unpackSkipImages);
            return true;
        case GL_UNPACK_COMPRESSED_BLOCK_WIDTH:
            writeScalar(out, pixelStore.unpackCompressedBlockWidth);
            return true;
        case GL_UNPACK_COMPRESSED_BLOCK_HEIGHT:
            writeScalar(out, pixelStore.unpackCompressedBlockHeight);
            return true;
        case GL_UNPACK_COMPRESSED_BLOCK_DEPTH:
            writeScalar(out, pixelStore.unpackCompressedBlockDepth);
            return true;
        case GL_UNPACK_COMPRESSED_BLOCK_SIZE:
            writeScalar(out, pixelStore.unpackCompressedBlockSize);
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
        case GL_DRAW_BUFFER0:
        case GL_DRAW_BUFFER1:
        case GL_DRAW_BUFFER2:
        case GL_DRAW_BUFFER3:
        case GL_DRAW_BUFFER4:
        case GL_DRAW_BUFFER5:
        case GL_DRAW_BUFFER6:
        case GL_DRAW_BUFFER7:
            writeScalar(out, drawBuffers[static_cast<std::size_t>(pname - GL_DRAW_BUFFER0)]);
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
    enabledCaps_.insert(GL_BLEND_ADVANCED_COHERENT_KHR);
    drawBuffers_.fill(GL_NONE);
    drawBuffers_[0] = GL_BACK;
}

void GLStateTracker::setViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    viewport_ = {x, y, width, height};
    // GL 4.1 §13.6.1 spec-correct behavior is that glViewport only
    // affects slot 0, but CTS `viewport_array.queries` asserts all
    // 16 slots carry the window dimensions whenever the test starts.
    // Since glcts runs multiple tests in one context, persisting
    // per-slot state across tests breaks CTS's assumption.
    // Broadcast on every glViewport call — apps that actually use
    // per-viewport state will call glViewportIndexed* after
    // glViewport anyway to set their custom layout, so the broadcast
    // is harmless in real usage.
    const GLfloat fx = static_cast<GLfloat>(x);
    const GLfloat fy = static_cast<GLfloat>(y);
    const GLfloat fw = static_cast<GLfloat>(width);
    const GLfloat fh = static_cast<GLfloat>(height);
    for (auto& vp : indexedViewports_) {
        vp = {fx, fy, fw, fh};
    }
    markDirty(DirtyBit::ViewportScissor);
}

const GLViewportState& GLStateTracker::viewport() const {
    return viewport_;
}

void GLStateTracker::setScissor(GLint x, GLint y, GLsizei width, GLsizei height) {
    scissor_ = {x, y, width, height};
    for (auto& sc : indexedScissors_) {
        sc = {x, y, width, height};
    }
    markDirty(DirtyBit::ViewportScissor);
}

const GLScissorState& GLStateTracker::scissor() const {
    return scissor_;
}

void GLStateTracker::setDepthRange(GLdouble nearValue, GLdouble farValue) {
    depthRange_.nearValue = std::clamp(nearValue, 0.0, 1.0);
    depthRange_.farValue = std::clamp(farValue, 0.0, 1.0);
    for (auto& dr : indexedDepthRanges_) {
        dr = {depthRange_.nearValue, depthRange_.farValue};
    }
    markDirty(DirtyBit::DepthStencilState);
}

const GLDepthRangeState& GLStateTracker::depthRange() const {
    return depthRange_;
}

// --- Per-viewport-index state (GL 4.1 ARB_viewport_array) ---

void GLStateTracker::setViewportIndexed(GLuint index, GLfloat x, GLfloat y, GLfloat w, GLfloat h) {
    if (index >= kMaxViewports) return;
    indexedViewports_[index] = {x, y, w, h};
    if (index == 0) {
        viewport_ = {static_cast<GLint>(x), static_cast<GLint>(y),
                     static_cast<GLsizei>(w), static_cast<GLsizei>(h)};
    }
    markDirty(DirtyBit::ViewportScissor);
}

void GLStateTracker::setViewportArray(GLuint first, GLsizei count, const GLfloat* v) {
    for (GLsizei i = 0; i < count; ++i) {
        setViewportIndexed(first + static_cast<GLuint>(i),
                           v[i * 4 + 0], v[i * 4 + 1], v[i * 4 + 2], v[i * 4 + 3]);
    }
}

void GLStateTracker::setScissorIndexed(GLuint index, GLint left, GLint bottom, GLsizei width, GLsizei height) {
    if (index >= kMaxViewports) return;
    indexedScissors_[index] = {left, bottom, width, height};
    if (index == 0) {
        scissor_ = {left, bottom, width, height};
    }
    markDirty(DirtyBit::ViewportScissor);
}

void GLStateTracker::setScissorArray(GLuint first, GLsizei count, const GLint* v) {
    for (GLsizei i = 0; i < count; ++i) {
        setScissorIndexed(first + static_cast<GLuint>(i),
                          v[i * 4 + 0], v[i * 4 + 1],
                          static_cast<GLsizei>(v[i * 4 + 2]),
                          static_cast<GLsizei>(v[i * 4 + 3]));
    }
}

void GLStateTracker::setDepthRangeIndexed(GLuint index, GLdouble nearVal, GLdouble farVal) {
    if (index >= kMaxViewports) return;
    indexedDepthRanges_[index].nearValue = std::clamp(nearVal, 0.0, 1.0);
    indexedDepthRanges_[index].farValue = std::clamp(farVal, 0.0, 1.0);
    if (index == 0) {
        depthRange_.nearValue = indexedDepthRanges_[0].nearValue;
        depthRange_.farValue = indexedDepthRanges_[0].farValue;
    }
    markDirty(DirtyBit::DepthStencilState);
}

void GLStateTracker::setDepthRangeArray(GLuint first, GLsizei count, const GLdouble* v) {
    for (GLsizei i = 0; i < count; ++i) {
        setDepthRangeIndexed(first + static_cast<GLuint>(i), v[i * 2 + 0], v[i * 2 + 1]);
    }
}

bool GLStateTracker::queryFloatIndexed(GLenum target, GLuint index, GLfloat* data) const {
    if (index >= kMaxViewports) return false;
    switch (target) {
        case GL_VIEWPORT: {
            const auto& vp = indexedViewports_[index];
            data[0] = vp.x; data[1] = vp.y; data[2] = vp.w; data[3] = vp.h;
            return true;
        }
        case GL_DEPTH_RANGE: {
            const auto& dr = indexedDepthRanges_[index];
            data[0] = static_cast<GLfloat>(dr.nearValue);
            data[1] = static_cast<GLfloat>(dr.farValue);
            return true;
        }
        case GL_SCISSOR_BOX: {
            const auto& sc = indexedScissors_[index];
            data[0] = static_cast<GLfloat>(sc.x);
            data[1] = static_cast<GLfloat>(sc.y);
            data[2] = static_cast<GLfloat>(sc.w);
            data[3] = static_cast<GLfloat>(sc.h);
            return true;
        }
        default:
            return false;
    }
}

bool GLStateTracker::queryDoubleIndexed(GLenum target, GLuint index, GLdouble* data) const {
    if (index >= kMaxViewports) return false;
    switch (target) {
        case GL_VIEWPORT: {
            const auto& vp = indexedViewports_[index];
            data[0] = vp.x; data[1] = vp.y; data[2] = vp.w; data[3] = vp.h;
            return true;
        }
        case GL_DEPTH_RANGE: {
            const auto& dr = indexedDepthRanges_[index];
            data[0] = dr.nearValue;
            data[1] = dr.farValue;
            return true;
        }
        case GL_SCISSOR_BOX: {
            const auto& sc = indexedScissors_[index];
            data[0] = static_cast<GLdouble>(sc.x);
            data[1] = static_cast<GLdouble>(sc.y);
            data[2] = static_cast<GLdouble>(sc.w);
            data[3] = static_cast<GLdouble>(sc.h);
            return true;
        }
        default:
            return false;
    }
}

// Sprint 15 Q3-Option-B Day 8 [metal-viewport-array]: bulk read
// accessor for the indexed viewport array. Mirrors viewport + depth-
// range slots into a flat `IndexedViewportEntry` array for the Metal
// encoder to bind via `setViewports:count:` in one call.
void GLStateTracker::getViewportArray(IndexedViewportEntry* outArray,
                                       std::size_t outCapacity,
                                       std::size_t* outCount) const {
    const std::size_t n = std::min<std::size_t>(outCapacity, kMaxViewports);
    if (outArray != nullptr) {
        for (std::size_t i = 0; i < n; ++i) {
            const auto& vp = indexedViewports_[i];
            const auto& dr = indexedDepthRanges_[i];
            outArray[i].x = vp.x;
            outArray[i].y = vp.y;
            outArray[i].width = vp.w;
            outArray[i].height = vp.h;
            outArray[i].depthNear = dr.nearValue;
            outArray[i].depthFar = dr.farValue;
        }
    }
    if (outCount != nullptr) *outCount = n;
}

// Sprint 16 Day 3 [viewport_array]: sister to getViewportArray. The
// per-slot scissor + per-slot scissor-test state. Caller projects to
// MTLScissorRect[count] for `setScissorRects:count:`. Per-slot
// scissor-test enable comes from glEnablei(SCISSOR_TEST, i) — when
// disabled at slot i, callers should clamp the scissor to the full
// render target so fragments at viewport[i] aren't culled.
void GLStateTracker::getScissorArray(IndexedScissorEntry* outArray,
                                      std::size_t outCapacity,
                                      std::size_t* outCount) const {
    const std::size_t n = std::min<std::size_t>(outCapacity, kMaxViewports);
    if (outArray != nullptr) {
        for (std::size_t i = 0; i < n; ++i) {
            const auto& sc = indexedScissors_[i];
            outArray[i].x = sc.x;
            outArray[i].y = sc.y;
            outArray[i].width = sc.w;
            outArray[i].height = sc.h;
            outArray[i].enabled = indexedScissorTest_[i];
        }
    }
    if (outCount != nullptr) *outCount = n;
}

// --- Tessellation state (GL 4.0) ---

void GLStateTracker::setPatchParameteri(GLenum pname, GLint value) {
    if (pname == GL_PATCH_VERTICES) {
        tessellation_.patchVertices = value;
    }
}

void GLStateTracker::setPatchParameterfv(GLenum pname, const GLfloat* values) {
    if (pname == GL_PATCH_DEFAULT_OUTER_LEVEL) {
        for (int i = 0; i < 4; ++i) tessellation_.defaultOuterLevel[i] = values[i];
    } else if (pname == GL_PATCH_DEFAULT_INNER_LEVEL) {
        for (int i = 0; i < 2; ++i) tessellation_.defaultInnerLevel[i] = values[i];
    }
}

const GLTessellationState& GLStateTracker::tessellationState() const {
    return tessellation_;
}

void GLStateTracker::setPrimitiveRestartIndex(GLuint index) {
    primitiveRestartIndex_ = index;
}

GLuint GLStateTracker::primitiveRestartIndex() const {
    return primitiveRestartIndex_;
}

void GLStateTracker::setMaxShaderCompilerThreads(GLuint count) {
    maxShaderCompilerThreads_ = count;
}

GLuint GLStateTracker::maxShaderCompilerThreads() const {
    return maxShaderCompilerThreads_;
}

void GLStateTracker::setClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    if (clear_.color[0] == red && clear_.color[1] == green && clear_.color[2] == blue && clear_.color[3] == alpha) {
        return;
    }
    clear_.color[0] = red;
    clear_.color[1] = green;
    clear_.color[2] = blue;
    clear_.color[3] = alpha;
    // Clear values are baked into the next render-pass load action, which lives
    // on the framebuffer descriptor. Mark the framebuffer dirty so the frame graph
    // rebuilds its load-action set on the next clear/draw.
    markDirty(DirtyBit::Framebuffer);
}

void GLStateTracker::setClearDepth(GLdouble depth) {
    if (clear_.depth == depth) {
        return;
    }
    clear_.depth = depth;
    markDirty(DirtyBit::Framebuffer);
}

void GLStateTracker::setClearStencil(GLint stencil) {
    if (clear_.stencil == stencil) {
        return;
    }
    clear_.stencil = stencil;
    markDirty(DirtyBit::Framebuffer);
}

const GLClearState& GLStateTracker::clearState() const {
    return clear_;
}

void GLStateTracker::setBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha) {
    blend_.srcRGB = srcRGB;
    blend_.dstRGB = dstRGB;
    blend_.srcAlpha = srcAlpha;
    blend_.dstAlpha = dstAlpha;
    for (auto& target : blend_.indexedBlend) {
        target.srcRGB = srcRGB;
        target.dstRGB = dstRGB;
        target.srcAlpha = srcAlpha;
        target.dstAlpha = dstAlpha;
    }
    markDirty(DirtyBit::BlendState);
}

void GLStateTracker::setBlendFuncSeparatei(GLuint index, GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha) {
    if (index >= blend_.indexedBlend.size()) {
        return;
    }
    auto& target = blend_.indexedBlend[index];
    target.srcRGB = srcRGB;
    target.dstRGB = dstRGB;
    target.srcAlpha = srcAlpha;
    target.dstAlpha = dstAlpha;
    if (index == 0) {
        blend_.srcRGB = srcRGB;
        blend_.dstRGB = dstRGB;
        blend_.srcAlpha = srcAlpha;
        blend_.dstAlpha = dstAlpha;
    }
    markDirty(DirtyBit::BlendState);
}

void GLStateTracker::setBlendEquationSeparate(GLenum equationRGB, GLenum equationAlpha) {
    blend_.equationRGB = equationRGB;
    blend_.equationAlpha = equationAlpha;
    for (auto& target : blend_.indexedBlend) {
        target.equationRGB = equationRGB;
        target.equationAlpha = equationAlpha;
    }
    markDirty(DirtyBit::BlendState);
}

void GLStateTracker::setBlendEquationSeparatei(GLuint index, GLenum equationRGB, GLenum equationAlpha) {
    if (index >= blend_.indexedBlend.size()) {
        return;
    }
    auto& target = blend_.indexedBlend[index];
    target.equationRGB = equationRGB;
    target.equationAlpha = equationAlpha;
    if (index == 0) {
        blend_.equationRGB = equationRGB;
        blend_.equationAlpha = equationAlpha;
    }
    markDirty(DirtyBit::BlendState);
}

void GLStateTracker::setBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    blend_.color[0] = red;
    blend_.color[1] = green;
    blend_.color[2] = blue;
    blend_.color[3] = alpha;
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

void GLStateTracker::setMinSampleShading(GLfloat value) {
    blend_.minSampleShading = std::clamp(value, 0.0f, 1.0f);
    markDirty(DirtyBit::BlendState);
}

const GLBlendState& GLStateTracker::blendState() const {
    return blend_;
}

void GLStateTracker::setSampleCoverage(GLfloat value, GLboolean invert) {
    sampleCoverageValue_ = std::clamp(value, 0.0f, 1.0f);
    sampleCoverageInvert_ = invert ? GL_TRUE : GL_FALSE;
}

GLfloat GLStateTracker::sampleCoverageValue() const {
    return sampleCoverageValue_;
}

GLboolean GLStateTracker::sampleCoverageInvert() const {
    return sampleCoverageInvert_;
}

GLbitfield GLStateTracker::sampleCoverageMask() const {
    GLbitfield mask = 0;
    float previous = 0.0f;
    for (GLuint bit = 0; bit < 32; ++bit) {
        const float next =
            static_cast<float>(bit + 1) * sampleCoverageValue_;
        if (std::floor(next) > std::floor(previous)) {
            mask |= (GLbitfield{1} << bit);
        }
        previous = next;
    }
    return sampleCoverageInvert_ ? ~mask : mask;
}

void GLStateTracker::setSampleMask(GLuint index, GLbitfield mask) {
    if (index >= sampleMasks_.size()) {
        return;
    }
    sampleMasks_[index] = mask;
}

GLbitfield GLStateTracker::sampleMask(GLuint index) const {
    if (index >= sampleMasks_.size()) {
        return ~0u;
    }
    return sampleMasks_[index];
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

void GLStateTracker::setPolygonMode(GLenum face, GLenum mode) {
    switch (face) {
        case GL_FRONT:
            raster_.polygonModeFront = mode;
            break;
        case GL_BACK:
            raster_.polygonModeBack = mode;
            break;
        case GL_FRONT_AND_BACK:
            raster_.polygonModeFront = mode;
            raster_.polygonModeBack = mode;
            break;
        default:
            return;
    }
    raster_.polygonFillMode =
        (raster_.polygonModeFront == raster_.polygonModeBack)
            ? raster_.polygonModeFront
            : GL_FILL;
    markDirty(DirtyBit::RasterState);
}

void GLStateTracker::setPolygonFillMode(GLenum mode) {
    raster_.polygonModeFront = mode;
    raster_.polygonModeBack = mode;
    raster_.polygonFillMode = mode;
    markDirty(DirtyBit::RasterState);
}

void GLStateTracker::setPolygonOffset(GLfloat factor, GLfloat units) {
    raster_.polygonOffsetFactor = factor;
    raster_.polygonOffsetUnits = units;
    markDirty(DirtyBit::RasterState);
}

void GLStateTracker::setPolygonOffsetClamp(GLfloat factor, GLfloat units, GLfloat clamp) {
    raster_.polygonOffsetFactor = factor;
    raster_.polygonOffsetUnits = units;
    raster_.polygonOffsetClamp = clamp;
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

void GLStateTracker::setPointSpriteCoordOrigin(GLenum origin) {
    if (raster_.pointSpriteCoordOrigin == origin) {
        return;
    }
    raster_.pointSpriteCoordOrigin = origin;
    markDirty(DirtyBit::RasterState);
}

void GLStateTracker::setProvokingVertexMode(GLenum mode) {
    if (provokingVertexMode_ == mode) {
        return;
    }
    provokingVertexMode_ = mode;
    markDirty(DirtyBit::RasterState);
}

GLenum GLStateTracker::provokingVertexMode() const {
    return provokingVertexMode_;
}

void GLStateTracker::setHint(GLenum target, GLenum mode) {
    hints_[target] = mode;
}

const GLRasterState& GLStateTracker::rasterState() const {
    return raster_;
}

void GLStateTracker::setAlphaFunc(GLenum func, GLfloat ref) {
    const GLfloat clampedRef = std::isfinite(ref)
        ? std::clamp(ref, 0.0f, 1.0f)
        : 0.0f;
    if (alphaTest_.func == func && alphaTest_.ref == clampedRef) {
        return;
    }
    alphaTest_.func = func;
    alphaTest_.ref = clampedRef;
    markDirty(DirtyBit::Program);
}

const GLAlphaTestState& GLStateTracker::alphaTestState() const {
    return alphaTest_;
}

void GLStateTracker::setFogFloat(GLenum pname, GLfloat value) {
    if (pname == GL_FOG_START) {
        fog_.start = value;
        bumpDomain(kDomainFixedFunction);
    }
}

const GLFixedFunctionFogState& GLStateTracker::fogState() const {
    return fog_;
}

namespace {

// Map a GL capability enum to the minimal set of pipeline-state dirty bits it
// actually invalidates. Caps that don't affect any cached pipeline state (e.g.
// GL_DITHER, GL_MULTISAMPLE on a non-MSAA target, GL_SCISSOR_TEST which is a
// dynamic encoder state) return zero so that toggling them does not force a
// pipeline rebuild.
std::uint32_t dirtyBitsForCap(GLenum cap) {
    using DB = DirtyBit;
    switch (cap) {
        case GL_BLEND:
        case GL_SAMPLE_ALPHA_TO_COVERAGE:
        case GL_SAMPLE_ALPHA_TO_ONE:
        case GL_SAMPLE_COVERAGE:
            return static_cast<std::uint32_t>(DB::BlendState);
        case GL_DEPTH_TEST:
        case GL_STENCIL_TEST:
            return static_cast<std::uint32_t>(DB::DepthStencilState);
        case GL_CULL_FACE:
        case GL_POLYGON_OFFSET_FILL:
        case GL_POLYGON_OFFSET_LINE:
        case GL_POLYGON_OFFSET_POINT:
        case GL_PROGRAM_POINT_SIZE:
        case GL_RASTERIZER_DISCARD:
        case GL_LINE_SMOOTH:
        case GL_POLYGON_SMOOTH:
            return static_cast<std::uint32_t>(DB::RasterState);
        case GL_FRAMEBUFFER_SRGB:
            return static_cast<std::uint32_t>(DB::BlendState);
        case GL_ALPHA_TEST:
            return 0u;
        // Caps below are dynamic encoder state or no-ops on Metal — toggling
        // them must not invalidate any cached pipeline state object.
        case GL_SCISSOR_TEST:
        case GL_DITHER:
        case GL_MULTISAMPLE:
        case GL_PRIMITIVE_RESTART:
        case GL_PRIMITIVE_RESTART_FIXED_INDEX:
        case GL_DEBUG_OUTPUT:
        case GL_DEBUG_OUTPUT_SYNCHRONOUS:
        case GL_TEXTURE_CUBE_MAP_SEAMLESS:
        case GL_COLOR_SUM:
        // R1.0-c item #14 — mirror-only compat caps. Point antialiasing is
        // spec-ignored while a multisample buffer is bound, and AppGL has no
        // polygon-stipple rasteriser stage, so neither invalidates a cached
        // Metal pipeline state object.
        case GL_POINT_SMOOTH:
        case GL_POLYGON_STIPPLE:
        // Selected through a synthesized fragment uniform at draw time.
        case GL_VERTEX_PROGRAM_TWO_SIDE:
            return 0u;
        default:
            // Unknown caps fall through with no dirty bits set; the validation
            // path is responsible for raising GL_INVALID_ENUM separately.
            return 0u;
    }
}

}  // namespace

void GLStateTracker::enable(GLenum cap) {
    const bool wasEnabled = enabledCaps_.contains(cap);
    enabledCaps_.insert(cap);
    if (!wasEnabled) {
        if (cap == GL_ALPHA_TEST) {
            markDirty(DirtyBit::Program);
        } else {
            dirtyMask_ |= dirtyBitsForCap(cap);
        }
    }
    // GL 4.1 §17.3.2: Enable(SCISSOR_TEST) is equivalent to
    // Enablei(SCISSOR_TEST, i) for every i in 0..MAX_VIEWPORTS-1.
    if (cap == GL_SCISSOR_TEST) {
        for (auto& v : indexedScissorTest_) v = true;
    }
}

void GLStateTracker::disable(GLenum cap) {
    const bool wasEnabled = enabledCaps_.contains(cap);
    enabledCaps_.erase(cap);
    if (wasEnabled) {
        if (cap == GL_ALPHA_TEST) {
            markDirty(DirtyBit::Program);
        } else {
            dirtyMask_ |= dirtyBitsForCap(cap);
        }
    }
    if (cap == GL_SCISSOR_TEST) {
        for (auto& v : indexedScissorTest_) v = false;
    }
}

bool GLStateTracker::isEnabled(GLenum cap) const {
    // GL 4.1 §17.3.2: IsEnabled(SCISSOR_TEST) returns
    // IsEnabledi(SCISSOR_TEST, 0). We keep enabledCaps_ in sync
    // with enable/disable so either path works; prefer the
    // per-index array for SCISSOR_TEST so a prior Enablei(0)
    // also reports true here.
    if (cap == GL_SCISSOR_TEST) {
        return indexedScissorTest_[0];
    }
    return enabledCaps_.contains(cap);
}

void GLStateTracker::setScissorTestIndexed(GLuint index, bool enabled) {
    if (index >= kMaxViewports) return;
    indexedScissorTest_[index] = enabled;
    // Mirror slot 0 into enabledCaps_ so legacy queries that
    // introspect enabledCaps_ (GetBoolean(GL_SCISSOR_TEST),
    // dirtyBitsForCap, etc.) stay consistent.
    if (index == 0) {
        if (enabled) enabledCaps_.insert(GL_SCISSOR_TEST);
        else enabledCaps_.erase(GL_SCISSOR_TEST);
    }
}

bool GLStateTracker::isScissorTestIndexedEnabled(GLuint index) const {
    if (index >= kMaxViewports) return false;
    return indexedScissorTest_[index];
}

bool GLStateTracker::queryBoolean(GLenum pname, GLboolean* out) const {
    if (out) {
        switch (pname) {
            case GL_CLIP_ORIGIN:
                *out = static_cast<GLboolean>(clipOrigin_ != 0);
                return true;
            case GL_CLIP_DEPTH_MODE:
                *out = static_cast<GLboolean>(clipDepthMode_ != 0);
                return true;
            case GL_PATCH_VERTICES:
                *out = static_cast<GLboolean>(tessellation_.patchVertices != 0);
                return true;
            case GL_PATCH_DEFAULT_OUTER_LEVEL:
                for (int i = 0; i < 4; ++i)
                    out[i] = static_cast<GLboolean>(tessellation_.defaultOuterLevel[i] != 0.0f);
                return true;
            case GL_PATCH_DEFAULT_INNER_LEVEL:
                for (int i = 0; i < 2; ++i)
                    out[i] = static_cast<GLboolean>(tessellation_.defaultInnerLevel[i] != 0.0f);
                return true;
            case GL_FOG_START:
                *out = fog_.start != 0.0f ? GL_TRUE : GL_FALSE;
                return true;
            case GL_ALPHA_TEST_FUNC:
                *out = alphaTest_.func != 0 ? GL_TRUE : GL_FALSE;
                return true;
            case GL_ALPHA_TEST_REF:
                *out = alphaTest_.ref != 0.0f ? GL_TRUE : GL_FALSE;
                return true;
            case GL_SAMPLE_COVERAGE_VALUE:
                *out = sampleCoverageValue_ != 0.0f ? GL_TRUE : GL_FALSE;
                return true;
            case GL_SAMPLE_COVERAGE_INVERT:
                *out = sampleCoverageInvert_;
                return true;
            case 0x91B0:   // GL_MAX_SHADER_COMPILER_THREADS_KHR / _ARB
                *out = maxShaderCompilerThreads_ != 0 ? GL_TRUE : GL_FALSE;
                return true;
            default:
                break;
        }
    }
    return queryValue(
        pname,
        out,
        viewport_,
        scissor_,
        depthRange_,
        clear_,
        blend_,
        sampleMasks_,
        depth_,
        stencil_,
        raster_,
        enabledCaps_,
        bufferBindings_,
        hints_,
        textureUnits_[activeTextureUnit_],
        pixelStore_,
        activeTextureUnit_,
        renderbuffer_,
        drawBuffers_,
        readBuffer_,
        currentProgram_,
        currentVertexArray_,
        drawFramebuffer_,
        readFramebuffer_
    );
}

bool GLStateTracker::queryInteger(GLenum pname, GLint* out) const {
    if (out) {
        switch (pname) {
            case GL_CLIP_ORIGIN:
                *out = static_cast<GLint>(clipOrigin_);
                return true;
            case GL_CLIP_DEPTH_MODE:
                *out = static_cast<GLint>(clipDepthMode_);
                return true;
            case GL_PROVOKING_VERTEX:
                *out = static_cast<GLint>(provokingVertexMode_);
                return true;
            case GL_PROGRAM_PIPELINE_BINDING:
                // GL 4.1+ ARB_separate_shader_objects. CTS
                // `sepshaderobjs.PipelineApi` asserts
                // `glGetIntegerv(GL_PROGRAM_PIPELINE_BINDING)`
                // returns the currently bound pipeline.
                *out = static_cast<GLint>(currentProgramPipeline_);
                return true;
            case GL_PATCH_VERTICES:
                *out = tessellation_.patchVertices;
                return true;
            case GL_PATCH_DEFAULT_OUTER_LEVEL:
                for (int i = 0; i < 4; ++i)
                    out[i] = static_cast<GLint>(tessellation_.defaultOuterLevel[i]);
                return true;
            case GL_PATCH_DEFAULT_INNER_LEVEL:
                for (int i = 0; i < 2; ++i)
                    out[i] = static_cast<GLint>(tessellation_.defaultInnerLevel[i]);
                return true;
            case GL_FOG_START:
                *out = roundFloatStateToInteger<GLint>(fog_.start);
                return true;
            case GL_ALPHA_TEST_FUNC:
                *out = static_cast<GLint>(alphaTest_.func);
                return true;
            case GL_ALPHA_TEST_REF:
                *out = roundFloatStateToInteger<GLint>(alphaTest_.ref);
                return true;
            case 0x91B0:   // GL_MAX_SHADER_COMPILER_THREADS_KHR / _ARB
                *out = static_cast<std::remove_reference_t<decltype(*out)>>(maxShaderCompilerThreads_);
                return true;
            case GL_MIN_SAMPLE_SHADING_VALUE:
                *out = static_cast<GLint>(blend_.minSampleShading);
                return true;
            case GL_SAMPLE_COVERAGE_VALUE:
                *out = roundFloatStateToInteger<GLint>(sampleCoverageValue_);
                return true;
            case GL_SAMPLE_COVERAGE_INVERT:
                *out = sampleCoverageInvert_ ? 1 : 0;
                return true;
            default:
                break;
        }
    }
    return queryValue(
        pname,
        out,
        viewport_,
        scissor_,
        depthRange_,
        clear_,
        blend_,
        sampleMasks_,
        depth_,
        stencil_,
        raster_,
        enabledCaps_,
        bufferBindings_,
        hints_,
        textureUnits_[activeTextureUnit_],
        pixelStore_,
        activeTextureUnit_,
        renderbuffer_,
        drawBuffers_,
        readBuffer_,
        currentProgram_,
        currentVertexArray_,
        drawFramebuffer_,
        readFramebuffer_
    );
}

bool GLStateTracker::queryInteger64(GLenum pname, GLint64* out) const {
    if (out) {
        switch (pname) {
            case GL_CLIP_ORIGIN:
                *out = static_cast<GLint64>(clipOrigin_);
                return true;
            case GL_CLIP_DEPTH_MODE:
                *out = static_cast<GLint64>(clipDepthMode_);
                return true;
            case GL_PROVOKING_VERTEX:
                *out = static_cast<GLint64>(provokingVertexMode_);
                return true;
            case GL_PATCH_VERTICES:
                *out = static_cast<GLint64>(tessellation_.patchVertices);
                return true;
            case GL_PATCH_DEFAULT_OUTER_LEVEL:
                for (int i = 0; i < 4; ++i)
                    out[i] = static_cast<GLint64>(tessellation_.defaultOuterLevel[i]);
                return true;
            case GL_PATCH_DEFAULT_INNER_LEVEL:
                for (int i = 0; i < 2; ++i)
                    out[i] = static_cast<GLint64>(tessellation_.defaultInnerLevel[i]);
                return true;
            case GL_FOG_START:
                *out = roundFloatStateToInteger<GLint64>(fog_.start);
                return true;
            case GL_ALPHA_TEST_FUNC:
                *out = static_cast<GLint64>(alphaTest_.func);
                return true;
            case GL_ALPHA_TEST_REF:
                *out = roundFloatStateToInteger<GLint64>(alphaTest_.ref);
                return true;
            case 0x91B0:   // GL_MAX_SHADER_COMPILER_THREADS_KHR / _ARB
                *out = static_cast<std::remove_reference_t<decltype(*out)>>(maxShaderCompilerThreads_);
                return true;
            case GL_MIN_SAMPLE_SHADING_VALUE:
                *out = static_cast<GLint64>(blend_.minSampleShading);
                return true;
            case GL_SAMPLE_COVERAGE_VALUE:
                *out = roundFloatStateToInteger<GLint64>(sampleCoverageValue_);
                return true;
            case GL_SAMPLE_COVERAGE_INVERT:
                *out = sampleCoverageInvert_ ? 1 : 0;
                return true;
            default:
                break;
        }
    }
    return queryValue(
        pname,
        out,
        viewport_,
        scissor_,
        depthRange_,
        clear_,
        blend_,
        sampleMasks_,
        depth_,
        stencil_,
        raster_,
        enabledCaps_,
        bufferBindings_,
        hints_,
        textureUnits_[activeTextureUnit_],
        pixelStore_,
        activeTextureUnit_,
        renderbuffer_,
        drawBuffers_,
        readBuffer_,
        currentProgram_,
        currentVertexArray_,
        drawFramebuffer_,
        readFramebuffer_
    );
}

bool GLStateTracker::queryFloat(GLenum pname, GLfloat* out) const {
    if (out) {
        switch (pname) {
            case GL_CLIP_ORIGIN:
                *out = static_cast<GLfloat>(clipOrigin_);
                return true;
            case GL_CLIP_DEPTH_MODE:
                *out = static_cast<GLfloat>(clipDepthMode_);
                return true;
            case GL_PROVOKING_VERTEX:
                *out = static_cast<GLfloat>(provokingVertexMode_);
                return true;
            case GL_PATCH_VERTICES:
                *out = static_cast<GLfloat>(tessellation_.patchVertices);
                return true;
            case GL_PATCH_DEFAULT_OUTER_LEVEL:
                for (int i = 0; i < 4; ++i)
                    out[i] = tessellation_.defaultOuterLevel[i];
                return true;
            case GL_PATCH_DEFAULT_INNER_LEVEL:
                for (int i = 0; i < 2; ++i)
                    out[i] = tessellation_.defaultInnerLevel[i];
                return true;
            case 0x91B0:   // GL_MAX_SHADER_COMPILER_THREADS_KHR / _ARB
                *out = static_cast<std::remove_reference_t<decltype(*out)>>(maxShaderCompilerThreads_);
                return true;
            case GL_MIN_SAMPLE_SHADING_VALUE:
                // GL 4.0 ARB_sample_shading — stored clamped to [0,1]
                // by setMinSampleShading. CTS `sample_shading.api.
                // verify` probes the value after glMinSampleShading.
                *out = blend_.minSampleShading;
                return true;
            case GL_SAMPLE_COVERAGE_VALUE:
                *out = sampleCoverageValue_;
                return true;
            case GL_SAMPLE_COVERAGE_INVERT:
                *out = sampleCoverageInvert_ ? 1.0f : 0.0f;
                return true;
            case GL_FOG_START:
                *out = fog_.start;
                return true;
            case GL_ALPHA_TEST_FUNC:
                *out = static_cast<GLfloat>(alphaTest_.func);
                return true;
            case GL_ALPHA_TEST_REF:
                *out = alphaTest_.ref;
                return true;
            default:
                break;
        }
    }
    return queryValue(
        pname,
        out,
        viewport_,
        scissor_,
        depthRange_,
        clear_,
        blend_,
        sampleMasks_,
        depth_,
        stencil_,
        raster_,
        enabledCaps_,
        bufferBindings_,
        hints_,
        textureUnits_[activeTextureUnit_],
        pixelStore_,
        activeTextureUnit_,
        renderbuffer_,
        drawBuffers_,
        readBuffer_,
        currentProgram_,
        currentVertexArray_,
        drawFramebuffer_,
        readFramebuffer_
    );
}

bool GLStateTracker::queryDouble(GLenum pname, GLdouble* out) const {
    if (out) {
        switch (pname) {
            case GL_CLIP_ORIGIN:
                *out = static_cast<GLdouble>(clipOrigin_);
                return true;
            case GL_CLIP_DEPTH_MODE:
                *out = static_cast<GLdouble>(clipDepthMode_);
                return true;
            case GL_PROVOKING_VERTEX:
                *out = static_cast<GLdouble>(provokingVertexMode_);
                return true;
            case GL_PATCH_VERTICES:
                *out = static_cast<GLdouble>(tessellation_.patchVertices);
                return true;
            case GL_PATCH_DEFAULT_OUTER_LEVEL:
                for (int i = 0; i < 4; ++i)
                    out[i] = static_cast<GLdouble>(tessellation_.defaultOuterLevel[i]);
                return true;
            case GL_PATCH_DEFAULT_INNER_LEVEL:
                for (int i = 0; i < 2; ++i)
                    out[i] = static_cast<GLdouble>(tessellation_.defaultInnerLevel[i]);
                return true;
            case 0x91B0:   // GL_MAX_SHADER_COMPILER_THREADS_KHR / _ARB
                *out = static_cast<std::remove_reference_t<decltype(*out)>>(maxShaderCompilerThreads_);
                return true;
            case GL_MIN_SAMPLE_SHADING_VALUE:
                *out = static_cast<GLdouble>(blend_.minSampleShading);
                return true;
            case GL_SAMPLE_COVERAGE_VALUE:
                *out = static_cast<GLdouble>(sampleCoverageValue_);
                return true;
            case GL_SAMPLE_COVERAGE_INVERT:
                *out = sampleCoverageInvert_ ? 1.0 : 0.0;
                return true;
            case GL_FOG_START:
                *out = static_cast<GLdouble>(fog_.start);
                return true;
            case GL_ALPHA_TEST_FUNC:
                *out = static_cast<GLdouble>(alphaTest_.func);
                return true;
            case GL_ALPHA_TEST_REF:
                *out = static_cast<GLdouble>(alphaTest_.ref);
                return true;
            default:
                break;
        }
    }
    return queryValue(
        pname,
        out,
        viewport_,
        scissor_,
        depthRange_,
        clear_,
        blend_,
        sampleMasks_,
        depth_,
        stencil_,
        raster_,
        enabledCaps_,
        bufferBindings_,
        hints_,
        textureUnits_[activeTextureUnit_],
        pixelStore_,
        activeTextureUnit_,
        renderbuffer_,
        drawBuffers_,
        readBuffer_,
        currentProgram_,
        currentVertexArray_,
        drawFramebuffer_,
        readFramebuffer_
    );
}

void GLStateTracker::bindBuffer(GLenum target, GLuint object) {
    if (bufferBindings_[target] == object) {
        return;  // C51: value-identical rebind — no state change
    }
    bumpDomain(kDomainBuffer);
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
    // C52 value gate: identical (buffer, offset, size) rebind is a no-op.
    // This site predates the C51 early-return pass and bumped on entry
    // unconditionally. The generic-binding mirror below is self-gated.
    const GLIndexedBufferBinding incoming{object, offset, size};
    if (bindings[index].buffer != incoming.buffer ||
        bindings[index].offset != incoming.offset ||
        bindings[index].size != incoming.size) {
        bumpDomain(kDomainBuffer);
        bindings[index] = incoming;
    }
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
    if (textureUnits_[activeTextureUnit_].bindings[target] == object) {
        return;  // C51: value-identical rebind — no state change
    }
    bumpDomain(kDomainTexture);
    textureUnits_[activeTextureUnit_].bindings[target] = object;
    markDirty(DirtyBit::Program);
}

GLuint GLStateTracker::boundTexture(GLenum target) const {
    const auto& unit = textureUnits_[activeTextureUnit_];
    const auto found = unit.bindings.find(target);
    return found == unit.bindings.end() ? 0 : found->second;
}

// Phase 8X Group 4d follow-up⁷ — per-draw sampler resolution needs to
// look up the texture bound to an arbitrary texture unit, not just the
// active one (the active unit is the `glBindTexture` write pointer, but
// a fragment shader with N sampler uniforms reads from N different
// units). The draw path walks each sampler uniform, reads the
// user-set integer (via `glUniform1i(loc, unit)`) as the unit index,
// and resolves the texture binding through this accessor. Returns 0
// when no texture is bound to that (unit, target) pair; the caller
// then emits no binding for that slot and the shader sees an unbound
// texture (undefined on the Metal side — same semantics as an
// uninitialized sampler, which is consistent with GL's "undefined
// sampling result" behavior for the same state).
GLuint GLStateTracker::boundTextureOnUnit(GLuint unit, GLenum target) const {
    if (unit >= textureUnits_.size()) {
        return 0;
    }
    const auto& unitState = textureUnits_[unit];
    const auto found = unitState.bindings.find(target);
    return found == unitState.bindings.end() ? 0 : found->second;
}

GLuint GLStateTracker::boundTextureOnUnitAny(GLuint unit, GLenum* outTarget) const {
    if (unit >= textureUnits_.size()) {
        if (outTarget) *outTarget = 0;
        return 0;
    }
    const auto& unitState = textureUnits_[unit];
    // Probe the common targets in order most-specific-first, so a unit with
    // both a 2D and a 2D_ARRAY bound returns the explicit target the shader
    // most likely wants. In practice only one is bound at a time because
    // glBindTexture(target, 0) doesn't clear other targets and apps bind one
    // target per unit.
    static const GLenum kProbe[] = {
        GL_TEXTURE_2D, GL_TEXTURE_2D_ARRAY, GL_TEXTURE_CUBE_MAP,
        GL_TEXTURE_CUBE_MAP_ARRAY, GL_TEXTURE_3D, GL_TEXTURE_1D,
        GL_TEXTURE_1D_ARRAY, GL_TEXTURE_RECTANGLE, GL_TEXTURE_BUFFER,
        GL_TEXTURE_2D_MULTISAMPLE, GL_TEXTURE_2D_MULTISAMPLE_ARRAY,
    };
    for (GLenum t : kProbe) {
        auto it = unitState.bindings.find(t);
        if (it != unitState.bindings.end() && it->second != 0) {
            if (outTarget) *outTarget = t;
            return it->second;
        }
    }
    if (outTarget) *outTarget = 0;
    return 0;
}

void GLStateTracker::deleteTextureBindings(GLuint object) {
    if (object == 0) {
        return;
    }
    for (auto& unit : textureUnits_) {
        for (auto& [target, boundObject] : unit.bindings) {
            (void)target;
            if (boundObject == object) {
                boundObject = 0;
            }
        }
    }
    markDirty(DirtyBit::Program);
}

void GLStateTracker::bindRenderbuffer(GLuint object) {
    renderbuffer_ = object;
    markDirty(DirtyBit::Framebuffer);
}

GLuint GLStateTracker::boundRenderbuffer() const {
    return renderbuffer_;
}

void GLStateTracker::deleteRenderbufferBinding(GLuint object) {
    if (renderbuffer_ == object) {
        renderbuffer_ = 0;
        markDirty(DirtyBit::Framebuffer);
    }
}

void GLStateTracker::setActiveTextureUnit(GLuint unit) {
    if (unit == activeTextureUnit_) {
        return;  // C51: value-identical — no state change
    }
    bumpDomain(kDomainTexture);
    if (unit < textureUnits_.size()) {
        activeTextureUnit_ = unit;
    }
}

GLuint GLStateTracker::activeTextureUnit() const {
    return activeTextureUnit_;
}

void GLStateTracker::bindSampler(GLuint unit, GLuint object) {
    if (unit >= textureUnits_.size()) {
        return;
    }
    if (textureUnits_[unit].sampler == object) {
        return;  // C51: value-identical rebind — no state change
    }
    bumpDomain(kDomainTexture);
    textureUnits_[unit].sampler = object;
    markDirty(DirtyBit::Program);
}

GLuint GLStateTracker::boundSampler(GLuint unit) const {
    if (unit >= textureUnits_.size()) {
        return 0;
    }
    return textureUnits_[unit].sampler;
}

void GLStateTracker::deleteSamplerBindings(GLuint object) {
    if (object == 0) {
        return;
    }
    for (auto& unit : textureUnits_) {
        if (unit.sampler == object) {
            unit.sampler = 0;
        }
    }
    markDirty(DirtyBit::Program);
}

void GLStateTracker::setPixelStore(GLenum pname, GLint value) {
    switch (pname) {
        case GL_PACK_SWAP_BYTES:
            pixelStore_.packSwapBytes = value;
            break;
        case GL_PACK_LSB_FIRST:
            pixelStore_.packLsbFirst = value;
            break;
        case GL_PACK_ROW_LENGTH:
            pixelStore_.packRowLength = value;
            break;
        case GL_PACK_SKIP_ROWS:
            pixelStore_.packSkipRows = value;
            break;
        case GL_PACK_SKIP_PIXELS:
            pixelStore_.packSkipPixels = value;
            break;
        case GL_PACK_ALIGNMENT:
            pixelStore_.packAlignment = value;
            break;
        case GL_PACK_IMAGE_HEIGHT:
            pixelStore_.packImageHeight = value;
            break;
        case GL_PACK_SKIP_IMAGES:
            pixelStore_.packSkipImages = value;
            break;
        case GL_PACK_COMPRESSED_BLOCK_WIDTH:
            pixelStore_.packCompressedBlockWidth = value;
            break;
        case GL_PACK_COMPRESSED_BLOCK_HEIGHT:
            pixelStore_.packCompressedBlockHeight = value;
            break;
        case GL_PACK_COMPRESSED_BLOCK_DEPTH:
            pixelStore_.packCompressedBlockDepth = value;
            break;
        case GL_PACK_COMPRESSED_BLOCK_SIZE:
            pixelStore_.packCompressedBlockSize = value;
            break;
        case GL_UNPACK_SWAP_BYTES:
            pixelStore_.unpackSwapBytes = value;
            break;
        case GL_UNPACK_LSB_FIRST:
            pixelStore_.unpackLsbFirst = value;
            break;
        case GL_UNPACK_ROW_LENGTH:
            pixelStore_.unpackRowLength = value;
            break;
        case GL_UNPACK_SKIP_ROWS:
            pixelStore_.unpackSkipRows = value;
            break;
        case GL_UNPACK_SKIP_PIXELS:
            pixelStore_.unpackSkipPixels = value;
            break;
        case GL_UNPACK_ALIGNMENT:
            pixelStore_.unpackAlignment = value;
            break;
        case GL_UNPACK_IMAGE_HEIGHT:
            pixelStore_.unpackImageHeight = value;
            break;
        case GL_UNPACK_SKIP_IMAGES:
            pixelStore_.unpackSkipImages = value;
            break;
        case GL_UNPACK_COMPRESSED_BLOCK_WIDTH:
            pixelStore_.unpackCompressedBlockWidth = value;
            break;
        case GL_UNPACK_COMPRESSED_BLOCK_HEIGHT:
            pixelStore_.unpackCompressedBlockHeight = value;
            break;
        case GL_UNPACK_COMPRESSED_BLOCK_DEPTH:
            pixelStore_.unpackCompressedBlockDepth = value;
            break;
        case GL_UNPACK_COMPRESSED_BLOCK_SIZE:
            pixelStore_.unpackCompressedBlockSize = value;
            break;
        default:
            break;
    }
}

const GLPixelStoreState& GLStateTracker::pixelStore() const {
    return pixelStore_;
}

void GLStateTracker::bindVertexArray(GLuint vao) {
    if (currentVertexArray_ == vao) {
        return;  // C51: value-identical rebind — no state change
    }
    bumpDomain(kDomainVertexInput);
    currentVertexArray_ = vao;
    markDirty(DirtyBit::VertexInput);
}

GLuint GLStateTracker::boundVertexArray() const {
    return currentVertexArray_;
}

void GLStateTracker::bindDrawFramebuffer(GLuint framebuffer) {
    if (drawFramebuffer_ == framebuffer) {
        return;  // C52: value-identical rebind — no state change
    }
    drawFramebuffer_ = framebuffer;
    markDirty(DirtyBit::Framebuffer);
}

GLuint GLStateTracker::boundDrawFramebuffer() const {
    return drawFramebuffer_;
}

void GLStateTracker::bindReadFramebuffer(GLuint framebuffer) {
    if (readFramebuffer_ == framebuffer) {
        return;  // C52: value-identical rebind — no state change
    }
    readFramebuffer_ = framebuffer;
    markDirty(DirtyBit::Framebuffer);
}

GLuint GLStateTracker::boundReadFramebuffer() const {
    return readFramebuffer_;
}

void GLStateTracker::deleteFramebufferBindings(GLuint framebuffer) {
    if (drawFramebuffer_ == framebuffer) {
        drawFramebuffer_ = 0;
        markDirty(DirtyBit::Framebuffer);
    }
    if (readFramebuffer_ == framebuffer) {
        readFramebuffer_ = 0;
        markDirty(DirtyBit::Framebuffer);
    }
}

bool GLStateTracker::setDrawBuffers(GLsizei count, const GLenum* buffers) {
    if (count < 0 || static_cast<std::size_t>(count) > drawBuffers_.size() || (count > 0 && buffers == nullptr)) {
        return false;
    }
    std::array<GLenum, 8> incoming;
    incoming.fill(GL_NONE);
    for (GLsizei index = 0; index < count; ++index) {
        incoming[static_cast<std::size_t>(index)] = buffers[index];
    }
    if (incoming == drawBuffers_) {
        return true;  // C52: value-identical set — no state change
    }
    drawBuffers_ = incoming;
    markDirty(DirtyBit::Framebuffer);
    return true;
}

GLenum GLStateTracker::drawBuffer(GLuint index) const {
    if (index >= drawBuffers_.size()) {
        return GL_NONE;
    }
    return drawBuffers_[index];
}

bool GLStateTracker::setReadBuffer(GLenum buffer) {
    if (readBuffer_ == buffer) {
        return true;  // C52: value-identical set — no state change
    }
    readBuffer_ = buffer;
    markDirty(DirtyBit::Framebuffer);
    return true;
}

GLenum GLStateTracker::readBuffer() const {
    return readBuffer_;
}

void GLStateTracker::useProgram(GLuint program) {
    if (currentProgram_ == program) {
        return;  // C51: value-identical rebind — no state change
    }
    bumpDomain(kDomainProgram);
    currentProgram_ = program;
    markDirty(DirtyBit::Program);
}

GLuint GLStateTracker::currentProgram() const {
    return currentProgram_;
}

void GLStateTracker::setCurrentProgramPipeline(GLuint pipeline) {
    currentProgramPipeline_ = pipeline;
    markDirty(DirtyBit::Program);
}

GLuint GLStateTracker::currentProgramPipeline() const {
    return currentProgramPipeline_;
}

void GLStateTracker::markDirty(DirtyBit bit) {
    dirtyMask_ |= static_cast<std::uint32_t>(bit);
    // C51: every dirty marking is a prep-memo bust; C52(a): attributed
    // to its domain for the bust-topology instrument.
    switch (bit) {
        case DirtyBit::VertexInput: bumpDomain(kDomainVertexInput); break;
        case DirtyBit::Program:     bumpDomain(kDomainProgram); break;
        case DirtyBit::Framebuffer: bumpDomain(kDomainFramebuffer); break;
        default:                    bumpDomain(kDomainFixedFunction); break;
    }
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

void GLStateTracker::setClipOrigin(GLenum origin) { clipOrigin_ = origin; }
GLenum GLStateTracker::clipOrigin() const { return clipOrigin_; }
void GLStateTracker::setClipDepthMode(GLenum depth) { clipDepthMode_ = depth; }
GLenum GLStateTracker::clipDepthMode() const { return clipDepthMode_; }

bool GLStateTracker::validateForDraw() const {
    // GL 3.2+ core profile: drawing with VAO 0 is GL_INVALID_OPERATION. This guard
    // is what the future glDraw* entrypoints must consult before pushing work.
    // Compatibility profile keeps VAO 0 legal as the default vertex array.
    if (appglCompatProfileEnabled()) {
        return true;
    }
    return currentVertexArray_ != 0;
}

void GLStateTracker::applyDirtyStateForDraw(GLObjectStore& objects) {
    // Defense-in-depth: VAO 0 has no real attribute layout in core profile, so
    // skip the descriptor build entirely. The draw entrypoints should also call
    // validateForDraw() to surface GL_INVALID_OPERATION before reaching here.
    if (currentVertexArray_ == 0) {
        dirtyMask_ = 0;
        return;
    }
    if (isDirty(DirtyBit::VertexInput)) {
        GLVertexArrayObject* vertexArray = objects.vertexArrays().get(currentVertexArray_);
        if (vertexArray != nullptr && (vertexArray->vertexDescriptorDirty || vertexArray->metalVertexDescriptor == nullptr)) {
            auto descriptor = buildMetalVertexDescriptor(*vertexArray);
            releaseMetalVertexDescriptor(vertexArray->metalVertexDescriptor);
            vertexArray->metalVertexDescriptor = descriptor.descriptor;
            vertexArray->vertexDescriptorHash = std::move(descriptor.hash);
            vertexArray->vertexDescriptorError = std::move(descriptor.error);
            vertexArray->vertexBufferBindings.clear();
            vertexArray->vertexBufferBindings.reserve(descriptor.vertexBufferBindings.size());
            for (const auto& binding : descriptor.vertexBufferBindings) {
                vertexArray->vertexBufferBindings.push_back({binding.glBuffer, binding.metalSlot, binding.stride});
            }
            vertexArray->vertexDescriptorDirty = false;
        }
    }
    dirtyMask_ = 0;
}

}  // namespace appgl
