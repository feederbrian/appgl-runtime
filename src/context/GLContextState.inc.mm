// This file is textually included by GLContext.mm. Do not compile it directly.
// It contains GLContext fixed-state-domain method definitions split out for navigation only.

#if defined(APPGL_GLCONTEXT_STATE_CLEAR_VIEWPORT)
void GLContext::setClearColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    impl_->state->setClearColor(red, green, blue, alpha);
}

void GLContext::setClearDepth(GLdouble depth) {
    impl_->state->setClearDepth(depth);
}

void GLContext::setClearStencil(GLint stencil) {
    impl_->state->setClearStencil(stencil);
}

void GLContext::clear(GLbitfield mask) {
    if (impl_->state->boundDrawFramebuffer() != 0) {
        if (!impl_->clearBoundFramebuffer(mask)) {
            pushError(GL_INVALID_FRAMEBUFFER_OPERATION);
        } else if ((mask & GL_DEPTH_BUFFER_BIT) != 0) {
            impl_->occlusionApproxDepthKnown = true;
            impl_->occlusionApproxDepth = static_cast<float>(
                std::clamp(impl_->state->clearState().depth, 0.0, 1.0));
        }
        return;
    }
    if ((mask & GL_COLOR_BUFFER_BIT) != 0) {
        impl_->applyDefaultFramebufferColorClear();
    }
    if ((mask & GL_DEPTH_BUFFER_BIT) != 0) {
        impl_->occlusionApproxDepthKnown = true;
        impl_->occlusionApproxDepth = static_cast<float>(
            std::clamp(impl_->state->clearState().depth, 0.0, 1.0));
    }
    // Accumulate mask bits so consecutive glClear calls (e.g. color then
    // depth) don't overwrite each other before the pending clear is flushed.
    impl_->pendingMask |= mask;
    impl_->pendingClear = (impl_->pendingMask & (GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT)) != 0;
}

void GLContext::setViewport(GLint x, GLint y, GLsizei width, GLsizei height) {
    // GL 4.1 §13.6.1: negative width or height raises INVALID_VALUE.
    if (width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    impl_->viewportX = x;
    impl_->viewportY = y;
    impl_->viewportWidth = width > 0 ? width : 1;
    impl_->viewportHeight = height > 0 ? height : 1;
    impl_->state->setViewport(x, y, width, height);
    if (impl_->frameGraph != nullptr) {
        // RC-A02: ensure the drawable covers the full viewport extent.
        impl_->frameGraph->resizeDrawable(impl_->drawableSurfaceWidth(), impl_->drawableSurfaceHeight());
    }
}

void GLContext::setScissor(GLint x, GLint y, GLsizei width, GLsizei height) {
    if (width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    impl_->state->setScissor(x, y, width, height);
}

void GLContext::setDepthRange(GLdouble nearValue, GLdouble farValue) {
    impl_->state->setDepthRange(nearValue, farValue);
}

#elif defined(APPGL_GLCONTEXT_STATE_VIEWPORT_ARRAY)
void GLContext::setViewportIndexed(GLuint index, GLfloat x, GLfloat y, GLfloat w, GLfloat h) {
    if (static_cast<GLint64>(index) >= queryMaxViewports(impl_->capabilities.get())) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    if (w < 0.0f || h < 0.0f) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    impl_->state->setViewportIndexed(index, x, y, w, h);
}

void GLContext::setViewportArray(GLuint first, GLsizei count, const GLfloat* v) {
    if (count < 0) { pushError(GL_INVALID_VALUE); return; }
    const GLint64 maxVp = queryMaxViewports(impl_->capabilities.get());
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxVp) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    // Per-entry negative-dimension check — reject any entry with
    // w<0 or h<0. Spec is all-or-nothing: on any invalid entry,
    // INVALID_VALUE is generated and no slot is updated.
    if (v != nullptr) {
        for (GLsizei i = 0; i < count; ++i) {
            if (v[i * 4 + 2] < 0.0f || v[i * 4 + 3] < 0.0f) {
                pushError(GL_INVALID_VALUE);
                return;
            }
        }
    }
    impl_->state->setViewportArray(first, count, v);
}

void GLContext::setScissorIndexed(GLuint index, GLint left, GLint bottom, GLsizei width, GLsizei height) {
    if (static_cast<GLint64>(index) >= queryMaxViewports(impl_->capabilities.get())) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    if (width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    impl_->state->setScissorIndexed(index, left, bottom, width, height);
}

void GLContext::setScissorArray(GLuint first, GLsizei count, const GLint* v) {
    if (count < 0) { pushError(GL_INVALID_VALUE); return; }
    const GLint64 maxVp = queryMaxViewports(impl_->capabilities.get());
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxVp) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    if (v != nullptr) {
        for (GLsizei i = 0; i < count; ++i) {
            if (v[i * 4 + 2] < 0 || v[i * 4 + 3] < 0) {
                pushError(GL_INVALID_VALUE);
                return;
            }
        }
    }
    impl_->state->setScissorArray(first, count, v);
}

void GLContext::setDepthRangeIndexed(GLuint index, GLdouble nearVal, GLdouble farVal) {
    if (static_cast<GLint64>(index) >= queryMaxViewports(impl_->capabilities.get())) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    impl_->state->setDepthRangeIndexed(index, nearVal, farVal);
}

void GLContext::setDepthRangeArray(GLuint first, GLsizei count, const GLdouble* v) {
    if (count < 0) { pushError(GL_INVALID_VALUE); return; }
    const GLint64 maxVp = queryMaxViewports(impl_->capabilities.get());
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxVp) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    impl_->state->setDepthRangeArray(first, count, v);
}

#elif defined(APPGL_GLCONTEXT_STATE_TESSELLATION_PATCH)
void GLContext::setPatchParameteri(GLenum pname, GLint value) {
    impl_->state->setPatchParameteri(pname, value);
}

void GLContext::setPatchParameterfv(GLenum pname, const GLfloat* values) {
    impl_->state->setPatchParameterfv(pname, values);
}

#elif defined(APPGL_GLCONTEXT_STATE_FIXED_FUNCTION)
void GLContext::setBlendFuncSeparate(GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha) {
    impl_->state->setBlendFuncSeparate(srcRGB, dstRGB, srcAlpha, dstAlpha);
}

void GLContext::setBlendFuncSeparatei(GLuint index, GLenum srcRGB, GLenum dstRGB, GLenum srcAlpha, GLenum dstAlpha) {
    impl_->state->setBlendFuncSeparatei(index, srcRGB, dstRGB, srcAlpha, dstAlpha);
}

void GLContext::setBlendEquationSeparate(GLenum equationRGB, GLenum equationAlpha) {
    impl_->state->setBlendEquationSeparate(equationRGB, equationAlpha);
}

void GLContext::setBlendEquationSeparatei(GLuint index, GLenum equationRGB, GLenum equationAlpha) {
    impl_->state->setBlendEquationSeparatei(index, equationRGB, equationAlpha);
}

void GLContext::setBlendColor(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    impl_->state->setBlendColor(red, green, blue, alpha);
}

void GLContext::setColorMask(GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha) {
    impl_->state->setColorMask(red, green, blue, alpha);
}

void GLContext::setColorMaski(GLuint index, GLboolean red, GLboolean green, GLboolean blue, GLboolean alpha) {
    impl_->state->setColorMaski(index, red, green, blue, alpha);
}

void GLContext::setMinSampleShading(GLfloat value) {
    impl_->state->setMinSampleShading(value);
}

void GLContext::setDepthFunc(GLenum func) {
    impl_->state->setDepthFunc(func);
}

void GLContext::setDepthMask(GLboolean flag) {
    impl_->state->setDepthMask(flag);
}

void GLContext::setStencilFuncSeparate(GLenum face, GLenum func, GLint ref, GLuint mask) {
    impl_->state->setStencilFuncSeparate(face, func, ref, mask);
}

void GLContext::setStencilOpSeparate(GLenum face, GLenum fail, GLenum depthFail, GLenum depthPass) {
    impl_->state->setStencilOpSeparate(face, fail, depthFail, depthPass);
}

void GLContext::setStencilMaskSeparate(GLenum face, GLuint mask) {
    impl_->state->setStencilMaskSeparate(face, mask);
}

void GLContext::setCullFace(GLenum mode) {
    impl_->state->setCullFace(mode);
}

void GLContext::setFrontFace(GLenum mode) {
    impl_->state->setFrontFace(mode);
}

void GLContext::setPolygonMode(GLenum face, GLenum mode) {
    (void)face;  // Metal doesn't distinguish front/back fill modes
    impl_->state->setPolygonFillMode(mode);
}

void GLContext::setPolygonOffset(GLfloat factor, GLfloat units) {
    impl_->state->setPolygonOffset(factor, units);
}

void GLContext::setLineWidth(GLfloat width) {
    impl_->state->setLineWidth(width);
}

void GLContext::setPointSize(GLfloat size) {
    impl_->state->setPointSize(size);
}

void GLContext::setHint(GLenum target, GLenum mode) {
    impl_->state->setHint(target, mode);
}

#elif defined(APPGL_GLCONTEXT_STATE_ENABLE)
void GLContext::setEnabled(GLenum cap, bool enabled) {
    if (enabled) {
        impl_->state->enable(cap);
    } else {
        impl_->state->disable(cap);
    }
}

bool GLContext::isEnabled(GLenum cap) const {
    return impl_->state->isEnabled(cap);
}

#elif defined(APPGL_GLCONTEXT_STATE_CLIP_CONTROL)
bool GLContext::clipControl(GLenum origin, GLenum depth) {
    if (origin != GL_LOWER_LEFT && origin != GL_UPPER_LEFT) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (depth != GL_NEGATIVE_ONE_TO_ONE && depth != GL_ZERO_TO_ONE) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    impl_->state->setClipOrigin(origin);
    impl_->state->setClipDepthMode(depth);
    return true;
}

#elif defined(APPGL_GLCONTEXT_STATE_POLYGON_OFFSET_CLAMP)
bool GLContext::polygonOffsetClamp(GLfloat factor, GLfloat units, GLfloat clamp) {
    // Extends glPolygonOffset with a clamp value. Store factor/units/clamp via
    // the state tracker for Metal's setDepthBias:slopeScale:clamp:.
    impl_->state->setPolygonOffsetClamp(factor, units, clamp);
    return true;
}

#else
#error "GLContextState.inc.mm included without a state section selector"
#endif
