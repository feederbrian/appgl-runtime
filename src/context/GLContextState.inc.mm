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
    if (!recordDisplayListClear(mask)) {
        return;
    }
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
    GLbitfield pendingBits = mask & ~GL_ACCUM_BUFFER_BIT;
    if ((mask & GL_DEPTH_BUFFER_BIT) != 0) {
        if (impl_->state->depthState().writeMask != GL_FALSE) {
            impl_->occlusionApproxDepthKnown = true;
            impl_->occlusionApproxDepth = static_cast<float>(
                std::clamp(impl_->state->clearState().depth, 0.0, 1.0));
        } else {
            pendingBits &= ~GL_DEPTH_BUFFER_BIT;
        }
    }
    const auto& clearState = impl_->state->clearState();
    if ((mask & GL_COLOR_BUFFER_BIT) != 0) {
        impl_->pendingClearColor = {
            clearState.color[0],
            clearState.color[1],
            clearState.color[2],
            clearState.color[3],
        };
    }
    if ((pendingBits & GL_DEPTH_BUFFER_BIT) != 0) {
        GLsizei minX = 0;
        GLsizei minY = 0;
        GLsizei maxX = 0;
        GLsizei maxY = 0;
        const bool scissorActive = impl_->state->isEnabled(GL_SCISSOR_TEST);
        if (scissorActive) {
            const GLScissorState& s = impl_->state->scissor();
            if (s.width > 0 && s.height > 0) {
                maxX = std::max<GLsizei>(0, s.x + s.width);
                maxY = std::max<GLsizei>(0, s.y + s.height);
            }
        }
        impl_->ensureDefaultFramebufferDepthStencilShadowAtLeast(maxX, maxY);
        const GLfloat depthValue =
            static_cast<GLfloat>(std::clamp(clearState.depth, 0.0, 1.0));
        if (scissorActive) {
            const GLScissorState& s = impl_->state->scissor();
            minX = std::max<GLsizei>(0, s.x);
            minY = std::max<GLsizei>(0, s.y);
            maxX = std::min<GLsizei>(
                impl_->defaultFramebufferDepthStencilShadowWidth,
                s.x + s.width);
            maxY = std::min<GLsizei>(
                impl_->defaultFramebufferDepthStencilShadowHeight,
                s.y + s.height);
            for (GLsizei y = minY; y < maxY; ++y) {
                std::fill(
                    impl_->defaultFramebufferDepth32.begin() +
                        static_cast<std::size_t>(y) *
                            static_cast<std::size_t>(
                                impl_->defaultFramebufferDepthStencilShadowWidth) +
                        static_cast<std::size_t>(minX),
                    impl_->defaultFramebufferDepth32.begin() +
                        static_cast<std::size_t>(y) *
                            static_cast<std::size_t>(
                                impl_->defaultFramebufferDepthStencilShadowWidth) +
                        static_cast<std::size_t>(maxX),
                    depthValue);
            }
        } else {
            std::fill(impl_->defaultFramebufferDepth32.begin(),
                      impl_->defaultFramebufferDepth32.end(),
                      depthValue);
        }
        impl_->defaultFramebufferDepthShadowValid = true;
        impl_->pendingClearDepth = clearState.depth;
    }
    if ((mask & GL_STENCIL_BUFFER_BIT) != 0) {
        GLsizei requiredWidth = 0;
        GLsizei requiredHeight = 0;
        const bool scissorActive = impl_->state->isEnabled(GL_SCISSOR_TEST);
        if (scissorActive) {
            const GLScissorState& s = impl_->state->scissor();
            if (s.width > 0 && s.height > 0) {
                requiredWidth = std::max<GLsizei>(0, s.x + s.width);
                requiredHeight = std::max<GLsizei>(0, s.y + s.height);
            }
        }
        impl_->ensureDefaultFramebufferDepthStencilShadowAtLeast(
            requiredWidth, requiredHeight);
        const std::uint8_t writeMask =
            static_cast<std::uint8_t>(impl_->state->stencilState().front.writeMask & 0xFFu);
        if (writeMask != 0) {
            const std::uint8_t clearStencil =
                static_cast<std::uint8_t>(clearState.stencil & 0xFF);
            GLsizei minX = 0;
            GLsizei minY = 0;
            GLsizei maxX = impl_->defaultFramebufferDepthStencilShadowWidth;
            GLsizei maxY = impl_->defaultFramebufferDepthStencilShadowHeight;
            if (scissorActive) {
                const GLScissorState& s = impl_->state->scissor();
                minX = std::max<GLsizei>(0, s.x);
                minY = std::max<GLsizei>(0, s.y);
                maxX = std::min<GLsizei>(
                    impl_->defaultFramebufferDepthStencilShadowWidth,
                    s.x + s.width);
                maxY = std::min<GLsizei>(
                    impl_->defaultFramebufferDepthStencilShadowHeight,
                    s.y + s.height);
            }
            for (GLsizei y = minY; y < maxY; ++y) {
                for (GLsizei x = minX; x < maxX; ++x) {
                    std::uint8_t& stencil =
                        impl_->defaultFramebufferStencil8[
                            static_cast<std::size_t>(y) *
                                static_cast<std::size_t>(
                                    impl_->defaultFramebufferDepthStencilShadowWidth) +
                            static_cast<std::size_t>(x)];
                    stencil = static_cast<std::uint8_t>(
                        (stencil & ~writeMask) | (clearStencil & writeMask));
                }
            }
            impl_->defaultFramebufferStencilShadowValid = true;
        }
        if (writeMask == 0xFFu) {
            impl_->pendingClearStencil = clearState.stencil;
        } else {
            pendingBits &= ~GL_STENCIL_BUFFER_BIT;
        }
    }
    // Accumulate mask bits so consecutive glClear calls (e.g. color then
    // depth) don't overwrite each other before the pending clear is flushed.
    // Values are captured per bit at glClear time so a later stencil-only
    // clear cannot change an older pending depth clear value.
    impl_->pendingMask |= pendingBits;
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
    // RC-A02: ensure the drawable covers the full viewport extent.
    impl_->ensureDefaultDrawableForViewportExtent();
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
    impl_->state->setPolygonMode(face, mode);
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
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::Enable;
        command.enumValue = cap;
        command.values[0] = enabled ? 1.0f : 0.0f;
        impl_->displayLists.compileCommands.push_back(command);
        if (!impl_->displayLists.compileAndExecute) {
            return;
        }
    }
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
