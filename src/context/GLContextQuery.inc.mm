// This file is textually included by GLContext.mm. Do not compile it directly.
// It contains GLContext query-domain method definitions split out for navigation only.

#if defined(APPGL_GLCONTEXT_QUERY_INDEXED)
bool GLContext::queryFloatIndexed(GLenum target, GLuint index, GLfloat* data) {
    if (data == nullptr) return false;
    // GL 4.1 §13.6.1 — viewport-array targets reject out-of-range
    // index with INVALID_VALUE. CTS `viewport_array.api_errors`
    // asserts `getFloati_v(GL_VIEWPORT, GL_MAX_VIEWPORTS, ...)`
    // raises INVALID_VALUE.
    if (target == GL_VIEWPORT || target == GL_SCISSOR_BOX || target == GL_DEPTH_RANGE) {
        if (static_cast<GLint64>(index) >= queryMaxViewports(impl_->capabilities.get())) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    // Array-state path (viewport[i], depthRange[i], etc.) lives on the state tracker.
    if (impl_->state->queryFloatIndexed(target, index, data)) return true;
    // Indexed buffer binding state: BINDING/START/SIZE cast to float per
    // GL spec. Needed by CTS shader_storage_buffer_object.basic-binding
    // which calls glGetFloati_v on the SSBO_BINDING/START/SIZE pnames.
    IndexedBufferPname ibp;
    if (lookupIndexedBufferPname(target, ibp)) {
        const auto b = impl_->state->indexedBufferBinding(ibp.target, index);
        switch (ibp.field) {
            case IndexedBufferPname::Buffer: *data = static_cast<GLfloat>(b.buffer); break;
            case IndexedBufferPname::Offset: *data = static_cast<GLfloat>(b.offset); break;
            case IndexedBufferPname::Size:   *data = static_cast<GLfloat>(b.size);   break;
        }
        return true;
    }
    // Fall through to capability/integer path for scalar caps queried
    // via the indexed API at index 0 (GL-spec leniency).
    if (index == 0) {
        GLfloat capValue = 0.0f;
        if (impl_->capabilities != nullptr && impl_->capabilities->queryFloat(target, &capValue)) {
            *data = capValue;
            return true;
        }
        GLint intValue = 0;
        if (impl_->state->queryInteger(target, &intValue)) {
            *data = static_cast<GLfloat>(intValue);
            return true;
        }
    }
    return false;
}

bool GLContext::queryDoubleIndexed(GLenum target, GLuint index, GLdouble* data) {
    if (data == nullptr) return false;
    if (target == GL_VIEWPORT || target == GL_SCISSOR_BOX || target == GL_DEPTH_RANGE) {
        if (static_cast<GLint64>(index) >= queryMaxViewports(impl_->capabilities.get())) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    if (impl_->state->queryDoubleIndexed(target, index, data)) return true;
    IndexedBufferPname ibp;
    if (lookupIndexedBufferPname(target, ibp)) {
        const auto b = impl_->state->indexedBufferBinding(ibp.target, index);
        switch (ibp.field) {
            case IndexedBufferPname::Buffer: *data = static_cast<GLdouble>(b.buffer); break;
            case IndexedBufferPname::Offset: *data = static_cast<GLdouble>(b.offset); break;
            case IndexedBufferPname::Size:   *data = static_cast<GLdouble>(b.size);   break;
        }
        return true;
    }
    if (index == 0) {
        GLint intValue = 0;
        if (impl_->state->queryInteger(target, &intValue)) {
            *data = static_cast<GLdouble>(intValue);
            return true;
        }
        if (impl_->capabilities != nullptr && impl_->capabilities->queryInteger(target, &intValue)) {
            *data = static_cast<GLdouble>(intValue);
            return true;
        }
    }
    return false;
}

bool GLContext::queryBooleanIndexed(GLenum target, GLuint index, GLboolean* data) {
    if (data == nullptr) return false;
    IndexedBufferPname ibp;
    if (lookupIndexedBufferPname(target, ibp)) {
        const auto b = impl_->state->indexedBufferBinding(ibp.target, index);
        GLint64 value = 0;
        switch (ibp.field) {
            case IndexedBufferPname::Buffer: value = b.buffer; break;
            case IndexedBufferPname::Offset: value = b.offset; break;
            case IndexedBufferPname::Size:   value = b.size;   break;
        }
        // GL spec: glGetBooleanv returns TRUE iff the integer value is non-zero.
        *data = (value != 0) ? GL_TRUE : GL_FALSE;
        return true;
    }
    // GL 4.2+ per-image-unit state — fall back to the indexed-integer
    // query so glGetBooleani_v returns TRUE iff the integer value is
    // non-zero. CTS `shader_image_load_store.basic-api-bind` queries
    // GL_IMAGE_BINDING_ACCESS via both forms and expects them to agree.
    // Without this, the boolean form returned GL_FALSE even when the
    // integer form reported the default GL_READ_ONLY (0x88B8 = 35000).
    GLint intValue = 0;
    if (queryIntegerIndexed(target, index, &intValue)) {
        *data = (intValue != 0) ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (index == 0) {
        if (impl_->state->queryInteger(target, &intValue)) {
            *data = (intValue != 0) ? GL_TRUE : GL_FALSE;
            return true;
        }
        if (impl_->capabilities != nullptr && impl_->capabilities->queryInteger(target, &intValue)) {
            *data = (intValue != 0) ? GL_TRUE : GL_FALSE;
            return true;
        }
    }
    return false;
}

#elif defined(APPGL_GLCONTEXT_QUERY_CORE)
bool GLContext::queryBoolean(GLenum pname, GLboolean* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH || pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = integerValue != 0 ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (pname == GL_SHADE_MODEL) {
        *data = impl_->fixedFunctionShadeModel != 0 ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (pname == GL_CURRENT_RASTER_POSITION_VALID) {
        *data = impl_->fixedFunctionRasterPositionValid ? GL_TRUE : GL_FALSE;
        return true;
    }
    // Transform feedback state — gluStateReset queries these via getBooleanv;
    // returning GL_INVALID_ENUM here aborts the reset and bleeds state across
    // CTS tests (active/paused/binding all default to GL_FALSE/0 since we
    // don't yet support TF execution).
    // CKPT85: route through per-bound-object getters so the
    // glGetIntegerv result reflects the currently-bound TF object's
    // state (the test inspectXFBState semantic). Pre-CKPT85 these
    // read the global flag, which lagged behind glBindTransformFeedback.
    if (pname == GL_TRANSFORM_FEEDBACK_ACTIVE) {
        *data = isTransformFeedbackActive() ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (pname == GL_TRANSFORM_FEEDBACK_PAUSED) {
        *data = isTransformFeedbackPaused() ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (pname == GL_TRANSFORM_FEEDBACK_BINDING) {
        *data = impl_->boundTransformFeedbackId != 0 ? GL_TRUE : GL_FALSE;
        return true;
    }
    // GL 4.4 §10.3.5 ARB_tessellation_shader: implementation-defined
    // boolean indicating whether glPrimitiveRestartIndex applies to
    // GL_PATCHES. We don't support tess + primitive-restart mixing
    // yet — return GL_FALSE so CTS `primitive_restart` skips the
    // GL_PATCHES branch instead of raising INVALID_ENUM and aborting.
    if (pname == GL_PRIMITIVE_RESTART_FOR_PATCHES_SUPPORTED) {
        *data = GL_FALSE;
        return true;
    }
    bool fragmentShadingRateHandled = false;
    if (!queryFragmentShadingRateBoolean(*this, pname, data, fragmentShadingRateHandled)) {
        return false;
    }
    if (fragmentShadingRateHandled) {
        return true;
    }
    if (impl_->state->queryBoolean(pname, data)) {
        return true;
    }
    GLint integerData[4] = {};
    if (impl_->capabilities != nullptr && impl_->capabilities->queryInteger(pname, integerData)) {
        data[0] = integerData[0] != 0 ? GL_TRUE : GL_FALSE;
        if (pname == GL_MAX_VIEWPORT_DIMS) {
            data[1] = integerData[1] != 0 ? GL_TRUE : GL_FALSE;
        }
        return true;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

bool GLContext::queryInteger(GLenum pname, GLint* data) {
    if (data == nullptr) {
        // Phase 8X Group 4d follow-up⁴ §6c — capture the pname so BAR can
        // name the steady-state firer instead of seeing a bare
        // <internal@GLContext.mm:LINE> entry. The internal call-site tag
        // is still synthesised (functionName left empty) so the file:line
        // breadcrumb survives.
        char pnameBuf[48];
        std::snprintf(pnameBuf, sizeof(pnameBuf),
            "queryInteger: pname=0x%04X data=nullptr",
            static_cast<unsigned>(pname));
        pushError(GL_INVALID_VALUE, "", pnameBuf);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH) {
        *data = static_cast<GLint>(impl_->debugGroupStack.size());
        return true;
    }
    if (pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        *data = impl_->debugMessages.empty()
            ? 0
            : static_cast<GLint>(impl_->debugMessages.front().message.size() + 1);
        return true;
    }
    if (pname == GL_SHADE_MODEL) {
        *data = static_cast<GLint>(impl_->fixedFunctionShadeModel);
        return true;
    }
    if (pname == GL_RENDER_MODE) {
        *data = static_cast<GLint>(impl_->selection.renderMode);
        return true;
    }
    if (pname == GL_NAME_STACK_DEPTH) {
        *data = static_cast<GLint>(impl_->selection.nameStack.size());
        return true;
    }
    if (pname == GL_MAX_NAME_STACK_DEPTH) {
        *data = GLContext::Impl::kMaxSelectNameStackDepth;
        return true;
    }
    if (pname == GL_SELECTION_BUFFER_SIZE) {
        *data = impl_->selection.bufferSize;
        return true;
    }
    if (pname == GL_CURRENT_RASTER_POSITION_VALID) {
        *data = impl_->fixedFunctionRasterPositionValid ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (pname == GL_CURRENT_RASTER_POSITION) {
        data[0] = static_cast<GLint>(std::lround(impl_->fixedFunctionRasterPosition[0]));
        data[1] = static_cast<GLint>(std::lround(impl_->fixedFunctionRasterPosition[1]));
        data[2] = static_cast<GLint>(std::lround(impl_->fixedFunctionRasterPosition[2]));
        data[3] = static_cast<GLint>(std::lround(impl_->fixedFunctionRasterPosition[3]));
        return true;
    }
    if (pname == GL_CURRENT_RASTER_COLOR) {
        for (int i = 0; i < 4; ++i) {
            data[i] = static_cast<GLint>(std::lround(impl_->fixedFunctionRasterColor[i]));
        }
        return true;
    }
    if (pname == GL_CURRENT_RASTER_SECONDARY_COLOR) {
        for (int i = 0; i < 4; ++i) {
            data[i] = static_cast<GLint>(std::lround(impl_->fixedFunctionRasterSecondaryColor[i]));
        }
        return true;
    }
    if (pname == GL_CURRENT_RASTER_TEXTURE_COORDS) {
        const GLuint unit = impl_->state->activeTextureUnit();
        const auto& coords = unit < Impl::kCompatRasterTextureUnits
            ? impl_->fixedFunctionRasterTexcoords[unit]
            : impl_->fixedFunctionRasterTexcoords[0];
        for (int i = 0; i < 4; ++i) {
            data[i] = static_cast<GLint>(std::lround(coords[i]));
        }
        return true;
    }
    if (pname == GL_CURRENT_RASTER_DISTANCE || pname == GL_CURRENT_RASTER_INDEX) {
        *data = 0;
        return true;
    }
    if (pname == GL_READ_BUFFER) {
        const GLuint framebufferName = impl_->state->boundReadFramebuffer();
        const GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
        *data = static_cast<GLint>(framebufferName != 0 && framebuffer != nullptr ? framebuffer->readBuffer : impl_->state->readBuffer());
        return true;
    }
    if (pname == GL_DRAW_BUFFER || (pname >= GL_DRAW_BUFFER0 && pname <= GL_DRAW_BUFFER7)) {
        const GLuint index = pname == GL_DRAW_BUFFER ? 0u : static_cast<GLuint>(pname - GL_DRAW_BUFFER0);
        const GLuint framebufferName = impl_->state->boundDrawFramebuffer();
        const GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
        *data = static_cast<GLint>(framebufferName != 0 && framebuffer != nullptr ? framebuffer->drawBuffers[index] : impl_->state->drawBuffer(index));
        return true;
    }
    if (pname == GL_TRANSFORM_FEEDBACK_ACTIVE) {
        // CKPT85: per-bound-object query (see queryBool path above).
        *data = isTransformFeedbackActive() ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (pname == GL_TRANSFORM_FEEDBACK_PAUSED) {
        *data = isTransformFeedbackPaused() ? GL_TRUE : GL_FALSE;
        return true;
    }
    if (pname == GL_TRANSFORM_FEEDBACK_BINDING) {
        *data = static_cast<GLint>(impl_->boundTransformFeedbackId);
        return true;
    }
    // GL 4.6 §22.3 — sample state follows the current read framebuffer.
    // Phase-3 default-FB MSAA is default-off; when opted in, only FB0
    // reports samples here. User FBO MSAA remains outside this slice.
    if (pname == GL_SAMPLE_BUFFERS) {
        *data = impl_->state->boundReadFramebuffer() == 0
            ? impl_->defaultFramebufferSampleBuffers()
            : 0;
        return true;
    }
    if (pname == GL_SAMPLES) {
        *data = impl_->state->boundReadFramebuffer() == 0
            ? impl_->defaultFramebufferSampleCount()
            : 0;
        return true;
    }
    if (pname == GL_DEPTH_BITS || pname == GL_STENCIL_BITS) {
        const GLuint fbName = impl_->state->boundReadFramebuffer();
        if (fbName == 0) {
            *data = pname == GL_DEPTH_BITS ? 24 : 8;
            return true;
        }
        GLint bits = 0;
        if (const GLFramebufferObject* fb = impl_->objects->framebuffers().get(fbName)) {
            const GLFramebufferAttachment* att = impl_->framebufferAttachment(
                *fb,
                pname == GL_DEPTH_BITS ? GL_DEPTH_ATTACHMENT : GL_STENCIL_ATTACHMENT);
            const auto info = att != nullptr
                ? impl_->framebufferAttachmentInfo(*att)
                : GLContext::Impl::AttachmentInfo{};
            if (info.complete) {
                if (pname == GL_DEPTH_BITS) {
                    if (info.internalFormat == GL_DEPTH_COMPONENT16) {
                        bits = 16;
                    } else if (info.internalFormat == GL_DEPTH_COMPONENT32 ||
                               info.internalFormat == GL_DEPTH_COMPONENT32F ||
                               info.internalFormat == GL_DEPTH32F_STENCIL8) {
                        bits = 32;
                    } else if (isDepthFormat(info.internalFormat)) {
                        bits = 24;
                    }
                } else if (isStencilFormat(info.internalFormat)) {
                    bits = 8;
                }
            }
        }
        *data = bits;
        return true;
    }
    // GL 4.6 §18.3: GL_IMPLEMENTATION_COLOR_READ_{TYPE,FORMAT} report
    // the implementation-preferred format/type pair for glReadPixels
    // on the current read framebuffer. Resolve from the bound read
    // FBO's color attachment; default framebuffer yields RGBA +
    // UNSIGNED_BYTE. Several CTS paths (notably the DSA
    // textures_buffer_* fuzz tests) drain these queries as part of
    // glReadPixels error-reporting, and a bare GL_INVALID_ENUM here
    // poisons the test's subsequent `gl.getError()` check.
    if (pname == GL_IMPLEMENTATION_COLOR_READ_TYPE
        || pname == GL_IMPLEMENTATION_COLOR_READ_FORMAT) {
        GLenum fmt = GL_RGBA;
        GLenum type = GL_UNSIGNED_BYTE;
        const GLuint fbName = impl_->state->boundReadFramebuffer();
        if (fbName != 0) {
            if (const GLFramebufferObject* fb = impl_->objects->framebuffers().get(fbName)) {
                const GLFramebufferAttachment* att = impl_->framebufferAttachment(*fb, fb->readBuffer);
                GLenum ifmt = 0;
                if (att != nullptr) {
                    if (att->kind == GLFramebufferAttachment::Kind::Renderbuffer) {
                        if (auto* rb = impl_->objects->renderbuffers().get(att->object)) {
                            ifmt = rb->internalFormat;
                        }
                    } else if (att->kind == GLFramebufferAttachment::Kind::Texture) {
                        if (auto* tex = impl_->objects->textures().get(att->object)) {
                            ifmt = tex->desc.internalFormat;
                        }
                    }
                }
                // Map internal format → (preferred read format, type).
                // Follows GL 4.6 Table 18.2's "valid combinations"
                // diagonal: integer formats yield *_INTEGER / matching
                // integer type; snorm/unorm yield base + BYTE/UBYTE;
                // float yields base + FLOAT.
                switch (ifmt) {
                    case GL_R8I:      fmt = GL_RED_INTEGER;  type = GL_BYTE;          break;
                    case GL_R8UI:     fmt = GL_RED_INTEGER;  type = GL_UNSIGNED_BYTE; break;
                    case GL_R16I:     fmt = GL_RED_INTEGER;  type = GL_SHORT;         break;
                    case GL_R16UI:    fmt = GL_RED_INTEGER;  type = GL_UNSIGNED_SHORT;break;
                    case GL_R32I:     fmt = GL_RED_INTEGER;  type = GL_INT;           break;
                    case GL_R32UI:    fmt = GL_RED_INTEGER;  type = GL_UNSIGNED_INT;  break;
                    case GL_RG8I:     fmt = GL_RG_INTEGER;   type = GL_BYTE;          break;
                    case GL_RG8UI:    fmt = GL_RG_INTEGER;   type = GL_UNSIGNED_BYTE; break;
                    case GL_RG16I:    fmt = GL_RG_INTEGER;   type = GL_SHORT;         break;
                    case GL_RG16UI:   fmt = GL_RG_INTEGER;   type = GL_UNSIGNED_SHORT;break;
                    case GL_RG32I:    fmt = GL_RG_INTEGER;   type = GL_INT;           break;
                    case GL_RG32UI:   fmt = GL_RG_INTEGER;   type = GL_UNSIGNED_INT;  break;
                    case GL_RGB8I:    fmt = GL_RGB_INTEGER;  type = GL_BYTE;          break;
                    case GL_RGB8UI:   fmt = GL_RGB_INTEGER;  type = GL_UNSIGNED_BYTE; break;
                    case GL_RGB16I:   fmt = GL_RGB_INTEGER;  type = GL_SHORT;         break;
                    case GL_RGB16UI:  fmt = GL_RGB_INTEGER;  type = GL_UNSIGNED_SHORT;break;
                    case GL_RGB32I:   fmt = GL_RGB_INTEGER;  type = GL_INT;           break;
                    case GL_RGB32UI:  fmt = GL_RGB_INTEGER;  type = GL_UNSIGNED_INT;  break;
                    case GL_RGBA8I:   fmt = GL_RGBA_INTEGER; type = GL_BYTE;          break;
                    case GL_RGBA8UI:  fmt = GL_RGBA_INTEGER; type = GL_UNSIGNED_BYTE; break;
                    case GL_RGBA16I:  fmt = GL_RGBA_INTEGER; type = GL_SHORT;         break;
                    case GL_RGBA16UI: fmt = GL_RGBA_INTEGER; type = GL_UNSIGNED_SHORT;break;
                    case GL_RGBA32I:  fmt = GL_RGBA_INTEGER; type = GL_INT;           break;
                    case GL_RGBA32UI: fmt = GL_RGBA_INTEGER; type = GL_UNSIGNED_INT;  break;
                    case GL_RGB10_A2UI: fmt = GL_RGBA_INTEGER; type = GL_UNSIGNED_INT_2_10_10_10_REV; break;
                    case GL_R16F: case GL_RG16F: case GL_RGB16F: case GL_RGBA16F:
                    case GL_R32F: case GL_RG32F: case GL_RGB32F: case GL_RGBA32F:
                        fmt = GL_RGBA; type = GL_FLOAT; break;
                    case GL_R8: case GL_R16: case GL_RG8: case GL_RG16:
                    case GL_RGB8: case GL_RGB16: case GL_RGBA8: case GL_RGBA16:
                    case GL_SRGB8: case GL_SRGB8_ALPHA8:
                    default:
                        fmt = GL_RGBA; type = GL_UNSIGNED_BYTE; break;
                }
            }
        }
        *data = static_cast<GLint>(pname == GL_IMPLEMENTATION_COLOR_READ_TYPE ? type : fmt);
        return true;
    }
    bool fragmentShadingRateHandled = false;
    if (!queryFragmentShadingRateInteger(*this, pname, data, fragmentShadingRateHandled)) {
        return false;
    }
    if (fragmentShadingRateHandled) {
        return true;
    }
    if (impl_->state->queryInteger(pname, data)) {
        return true;
    }
    if (impl_->capabilities == nullptr || !impl_->capabilities->queryInteger(pname, data)) {
        // Phase 8X Group 4d follow-up⁴ §6c — name the unknown pname in
        // the diagnostic ring so BAR can see WHICH enum its widget code
        // is querying. The previous bare `pushError(GL_INVALID_ENUM)`
        // produced a steady stream of untagged errorLog entries that
        // BAR-side tooling could only count, not act on.
        char pnameBuf[48];
        std::snprintf(pnameBuf, sizeof(pnameBuf),
            "queryInteger: pname=0x%04X unknown",
            static_cast<unsigned>(pname));
        pushError(GL_INVALID_ENUM, "", pnameBuf);
        return false;
    }
    return true;
}

bool GLContext::queryInteger64(GLenum pname, GLint64* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH || pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = static_cast<GLint64>(integerValue);
        return true;
    }
    if (pname == GL_SHADE_MODEL) {
        *data = static_cast<GLint64>(impl_->fixedFunctionShadeModel);
        return true;
    }
    if (pname == GL_RENDER_MODE || pname == GL_NAME_STACK_DEPTH ||
        pname == GL_MAX_NAME_STACK_DEPTH || pname == GL_SELECTION_BUFFER_SIZE ||
        pname == GL_CURRENT_RASTER_POSITION_VALID || pname == GL_CURRENT_RASTER_INDEX ||
        pname == GL_CURRENT_RASTER_DISTANCE) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = static_cast<GLint64>(integerValue);
        return true;
    }
    if (pname == GL_CURRENT_RASTER_POSITION ||
        pname == GL_CURRENT_RASTER_COLOR ||
        pname == GL_CURRENT_RASTER_SECONDARY_COLOR ||
        pname == GL_CURRENT_RASTER_TEXTURE_COORDS) {
        GLint integerValues[4] = {};
        if (!queryInteger(pname, integerValues)) {
            return false;
        }
        for (int i = 0; i < 4; ++i) {
            data[i] = static_cast<GLint64>(integerValues[i]);
        }
        return true;
    }
    bool fragmentShadingRateHandled = false;
    if (!queryFragmentShadingRateInteger64(*this, pname, data, fragmentShadingRateHandled)) {
        return false;
    }
    if (fragmentShadingRateHandled) {
        return true;
    }
    if (impl_->state->queryInteger64(pname, data)) {
        return true;
    }
    if (impl_->capabilities == nullptr || !impl_->capabilities->queryInteger64(pname, data)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::queryIntegerIndexed(GLenum pname, GLuint index, GLint* data) {
    // Indexed integer query (glGetIntegeri_v). Phase 8X Landing C 3a. Used
    // primarily for compute work-group count/size tuples where the GL spec
    // defines separate per-dimension values addressed by index 0/1/2.
    //
    // We still honour the bound-buffer index queries that live on the state
    // tracker (indexed buffer bindings, array-drawbuffer state). Capability
    // caps flow through GLCapabilities::queryIntegerIndexed which knows
    // about the x/y/z compute tuples and also serves scalar caps at
    // index 0 for GL-spec leniency.
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.3+ separated-format per-binding-point VAO state (§10.3.8).
    // `GL_VERTEX_BINDING_{STRIDE,DIVISOR,BUFFER,OFFSET}` are indexed by
    // binding point. CTS `vertex_attrib_binding.basic-state*` queries
    // all four; the 64-bit OFFSET form goes through queryInteger64Indexed.
    switch (pname) {
        case GL_VERTEX_BINDING_STRIDE:
        case GL_VERTEX_BINDING_DIVISOR:
        case GL_VERTEX_BINDING_BUFFER:
        case GL_VERTEX_BINDING_OFFSET: {
            GLVertexArrayObject* vao = impl_->currentVertexArray();
            if (vao == nullptr || index >= vao->bindingPoints.size()) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
            const auto& bp = vao->bindingPoints[index];
            if (pname == GL_VERTEX_BINDING_STRIDE)      *data = static_cast<GLint>(bp.stride);
            else if (pname == GL_VERTEX_BINDING_DIVISOR) *data = static_cast<GLint>(bp.divisor);
            else if (pname == GL_VERTEX_BINDING_BUFFER)  *data = static_cast<GLint>(bp.buffer);
            else                                         *data = static_cast<GLint>(bp.offset);
            return true;
        }
        // GL 4.2+ image load/store per-image-unit state (§8.26.1).
        // `index` is an image unit index in [0, MAX_IMAGE_UNITS).
        // CTS `multi_bind.functional_bind_image_textures` exercises
        // all six per-unit pnames after glBindImageTextures() calls.
        case GL_IMAGE_BINDING_NAME:
        case GL_IMAGE_BINDING_LEVEL:
        case GL_IMAGE_BINDING_LAYERED:
        case GL_IMAGE_BINDING_LAYER:
        case GL_IMAGE_BINDING_ACCESS:
        case GL_IMAGE_BINDING_FORMAT: {
            if (index >= impl_->imageBindings.size()) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
            const auto& ib = impl_->imageBindings[index];
            if (pname == GL_IMAGE_BINDING_NAME)         *data = static_cast<GLint>(ib.texture);
            else if (pname == GL_IMAGE_BINDING_LEVEL)   *data = ib.level;
            else if (pname == GL_IMAGE_BINDING_LAYERED) *data = ib.layered ? GL_TRUE : GL_FALSE;
            else if (pname == GL_IMAGE_BINDING_LAYER)   *data = ib.layer;
            else if (pname == GL_IMAGE_BINDING_ACCESS)  *data = static_cast<GLint>(ib.access);
            else                                        *data = static_cast<GLint>(ib.format);
            return true;
        }
        case GL_SAMPLE_MASK_VALUE:
            if (index != 0) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
            *data = static_cast<GLint>(impl_->state->sampleMask(index));
            return true;
        // GL 4.4+ per-texture-unit bindings for all sampler targets.
        // Indexed by texture-unit number in [0, MAX_COMBINED_TEXTURE_IMAGE_UNITS).
        // The non-indexed form of these queries returns the binding on
        // the currently active texture unit; the indexed form lets the
        // caller pick any unit without switching glActiveTexture first.
        // Used by CTS `multi_bind.functional_bind_textures`.
        case GL_TEXTURE_BINDING_1D:
        case GL_TEXTURE_BINDING_2D:
        case GL_TEXTURE_BINDING_3D:
        case GL_TEXTURE_BINDING_1D_ARRAY:
        case GL_TEXTURE_BINDING_2D_ARRAY:
        case GL_TEXTURE_BINDING_RECTANGLE:
        case GL_TEXTURE_BINDING_CUBE_MAP:
        case GL_TEXTURE_BINDING_CUBE_MAP_ARRAY:
        case GL_TEXTURE_BINDING_BUFFER:
        case GL_TEXTURE_BINDING_2D_MULTISAMPLE:
        case GL_TEXTURE_BINDING_2D_MULTISAMPLE_ARRAY:
        case GL_SAMPLER_BINDING: {
            // Map binding pname to the texture target being queried.
            GLenum target = 0;
            switch (pname) {
                case GL_TEXTURE_BINDING_1D:                    target = GL_TEXTURE_1D; break;
                case GL_TEXTURE_BINDING_2D:                    target = GL_TEXTURE_2D; break;
                case GL_TEXTURE_BINDING_3D:                    target = GL_TEXTURE_3D; break;
                case GL_TEXTURE_BINDING_1D_ARRAY:              target = GL_TEXTURE_1D_ARRAY; break;
                case GL_TEXTURE_BINDING_2D_ARRAY:              target = GL_TEXTURE_2D_ARRAY; break;
                case GL_TEXTURE_BINDING_RECTANGLE:             target = GL_TEXTURE_RECTANGLE; break;
                case GL_TEXTURE_BINDING_CUBE_MAP:              target = GL_TEXTURE_CUBE_MAP; break;
                case GL_TEXTURE_BINDING_CUBE_MAP_ARRAY:        target = GL_TEXTURE_CUBE_MAP_ARRAY; break;
                case GL_TEXTURE_BINDING_BUFFER:                target = GL_TEXTURE_BUFFER; break;
                case GL_TEXTURE_BINDING_2D_MULTISAMPLE:        target = GL_TEXTURE_2D_MULTISAMPLE; break;
                case GL_TEXTURE_BINDING_2D_MULTISAMPLE_ARRAY:  target = GL_TEXTURE_2D_MULTISAMPLE_ARRAY; break;
                case GL_SAMPLER_BINDING:                       target = GL_SAMPLER_BINDING; break;
            }
            if (pname == GL_SAMPLER_BINDING) {
                *data = static_cast<GLint>(impl_->state->boundSampler(index));
            } else {
                *data = static_cast<GLint>(impl_->state->boundTextureOnUnit(index, target));
            }
            return true;
        }
        // GL 4.1+ per-viewport arrays. CTS
        // `viewport_array.scissor_api` / `viewport_api` query
        // GL_VIEWPORT and GL_SCISSOR_BOX via glGetIntegeri_v — both
        // are spec-legal. Route through the state tracker's float
        // indexed query + cast. DEPTH_RANGE is float-only per
        // Table 22.5, so stays handled by queryFloatIndexed.
        case GL_VIEWPORT:
        case GL_SCISSOR_BOX: {
            // GL 4.1 §13.6.1: index >= MAX_VIEWPORTS raises
            // INVALID_VALUE (not INVALID_ENUM).
            if (static_cast<GLint64>(index) >= queryMaxViewports(impl_->capabilities.get())) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
            GLfloat fdata[4] = {};
            if (!impl_->state->queryFloatIndexed(pname, index, fdata)) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
            data[0] = static_cast<GLint>(fdata[0]);
            data[1] = static_cast<GLint>(fdata[1]);
            data[2] = static_cast<GLint>(fdata[2]);
            data[3] = static_cast<GLint>(fdata[3]);
            return true;
        }
    }
    if (impl_->capabilities != nullptr
        && impl_->capabilities->queryIntegerIndexed(pname, index, data)) {
        return true;
    }
    // Indexed buffer-binding state: BINDING / START / SIZE for all four
    // indexed targets. Lives on the state tracker, not the cap layer.
    IndexedBufferPname ibp;
    if (lookupIndexedBufferPname(pname, ibp)) {
        const auto b = impl_->state->indexedBufferBinding(ibp.target, index);
        switch (ibp.field) {
            case IndexedBufferPname::Buffer: *data = static_cast<GLint>(b.buffer); break;
            case IndexedBufferPname::Offset: *data = static_cast<GLint>(b.offset); break;
            case IndexedBufferPname::Size:   *data = static_cast<GLint>(b.size);   break;
        }
        return true;
    }
    // Fall back to the scalar state tracker path for state that has a
    // per-index representation (buffer binding stacks) — match the existing
    // queryInteger behaviour when no indexed handler exists.
    if (index == 0 && impl_->state->queryInteger(pname, data)) {
        return true;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

bool GLContext::queryInteger64Indexed(GLenum pname, GLuint index, GLint64* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.3+ separated-format — same per-binding queries as the
    // 32-bit form. `GL_VERTEX_BINDING_OFFSET` in particular is
    // documented as the 64-bit target since offsets can exceed
    // 2^31. Served directly from the VAO binding-point state.
    switch (pname) {
        case GL_VERTEX_BINDING_STRIDE:
        case GL_VERTEX_BINDING_DIVISOR:
        case GL_VERTEX_BINDING_BUFFER:
        case GL_VERTEX_BINDING_OFFSET: {
            GLVertexArrayObject* vao = impl_->currentVertexArray();
            if (vao == nullptr || index >= vao->bindingPoints.size()) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
            const auto& bp = vao->bindingPoints[index];
            if (pname == GL_VERTEX_BINDING_STRIDE)      *data = static_cast<GLint64>(bp.stride);
            else if (pname == GL_VERTEX_BINDING_DIVISOR) *data = static_cast<GLint64>(bp.divisor);
            else if (pname == GL_VERTEX_BINDING_BUFFER)  *data = static_cast<GLint64>(bp.buffer);
            else                                         *data = static_cast<GLint64>(bp.offset);
            return true;
        }
    }
    if (impl_->capabilities != nullptr
        && impl_->capabilities->queryInteger64Indexed(pname, index, data)) {
        return true;
    }
    IndexedBufferPname ibp;
    if (lookupIndexedBufferPname(pname, ibp)) {
        const auto b = impl_->state->indexedBufferBinding(ibp.target, index);
        switch (ibp.field) {
            case IndexedBufferPname::Buffer: *data = static_cast<GLint64>(b.buffer); break;
            case IndexedBufferPname::Offset: *data = static_cast<GLint64>(b.offset); break;
            case IndexedBufferPname::Size:   *data = static_cast<GLint64>(b.size);   break;
        }
        return true;
    }
    if (index == 0 && impl_->state->queryInteger64(pname, data)) {
        return true;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

bool GLContext::queryFloat(GLenum pname, GLfloat* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH || pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = static_cast<GLfloat>(integerValue);
        return true;
    }
    if (pname == GL_SHADE_MODEL) {
        *data = static_cast<GLfloat>(impl_->fixedFunctionShadeModel);
        return true;
    }
    if (pname == GL_CURRENT_RASTER_POSITION) {
        std::memcpy(data, impl_->fixedFunctionRasterPosition, 4 * sizeof(GLfloat));
        return true;
    }
    if (pname == GL_CURRENT_RASTER_COLOR) {
        std::memcpy(data, impl_->fixedFunctionRasterColor, 4 * sizeof(GLfloat));
        return true;
    }
    if (pname == GL_CURRENT_RASTER_SECONDARY_COLOR) {
        std::memcpy(data, impl_->fixedFunctionRasterSecondaryColor, 4 * sizeof(GLfloat));
        return true;
    }
    if (pname == GL_CURRENT_RASTER_TEXTURE_COORDS) {
        const GLuint unit = impl_->state->activeTextureUnit();
        const auto& coords = unit < Impl::kCompatRasterTextureUnits
            ? impl_->fixedFunctionRasterTexcoords[unit]
            : impl_->fixedFunctionRasterTexcoords[0];
        std::memcpy(data, coords.data(), 4 * sizeof(GLfloat));
        return true;
    }
    if (pname == GL_CURRENT_RASTER_POSITION_VALID ||
        pname == GL_CURRENT_RASTER_DISTANCE ||
        pname == GL_CURRENT_RASTER_INDEX) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = static_cast<GLfloat>(integerValue);
        return true;
    }
    bool fragmentShadingRateHandled = false;
    if (!queryFragmentShadingRateFloat(*this, pname, data, fragmentShadingRateHandled)) {
        return false;
    }
    if (fragmentShadingRateHandled) {
        return true;
    }
    if (impl_->state->queryFloat(pname, data)) {
        return true;
    }
    if (impl_->capabilities != nullptr && impl_->capabilities->queryFloat(pname, data)) {
        return true;
    }
    // GL spec: glGetFloatv must return any integer state cast to float
    // (e.g. GL_SHADER_STORAGE_BUFFER_BINDING). Fall through to the
    // integer path and cast. Note: we do NOT call queryInteger() here
    // because that pushes GL_INVALID_ENUM on miss — instead probe
    // state + caps directly.
    GLint intData[4] = {};
    if (impl_->state->queryInteger(pname, intData)) {
        *data = static_cast<GLfloat>(intData[0]);
        return true;
    }
    if (impl_->capabilities != nullptr && impl_->capabilities->queryInteger(pname, intData)) {
        *data = static_cast<GLfloat>(intData[0]);
        if (pname == GL_MAX_VIEWPORT_DIMS) {
            data[1] = static_cast<GLfloat>(intData[1]);
        }
        return true;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

bool GLContext::queryDouble(GLenum pname, GLdouble* data) {
    if (data == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_DEBUG_GROUP_STACK_DEPTH || pname == GL_DEBUG_NEXT_LOGGED_MESSAGE_LENGTH) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = static_cast<GLdouble>(integerValue);
        return true;
    }
    if (pname == GL_SHADE_MODEL) {
        *data = static_cast<GLdouble>(impl_->fixedFunctionShadeModel);
        return true;
    }
    if (pname == GL_CURRENT_RASTER_POSITION ||
        pname == GL_CURRENT_RASTER_COLOR ||
        pname == GL_CURRENT_RASTER_SECONDARY_COLOR ||
        pname == GL_CURRENT_RASTER_TEXTURE_COORDS) {
        GLfloat floatValues[4] = {};
        if (!queryFloat(pname, floatValues)) {
            return false;
        }
        for (int i = 0; i < 4; ++i) {
            data[i] = static_cast<GLdouble>(floatValues[i]);
        }
        return true;
    }
    if (pname == GL_CURRENT_RASTER_POSITION_VALID ||
        pname == GL_CURRENT_RASTER_DISTANCE ||
        pname == GL_CURRENT_RASTER_INDEX) {
        GLint integerValue = 0;
        if (!queryInteger(pname, &integerValue)) {
            return false;
        }
        *data = static_cast<GLdouble>(integerValue);
        return true;
    }
    bool fragmentShadingRateHandled = false;
    if (!queryFragmentShadingRateDouble(*this, pname, data, fragmentShadingRateHandled)) {
        return false;
    }
    if (fragmentShadingRateHandled) {
        return true;
    }
    if (impl_->state->queryDouble(pname, data)) {
        return true;
    }
    GLfloat floatData[4] = {};
    if (impl_->capabilities != nullptr && impl_->capabilities->queryFloat(pname, floatData)) {
        data[0] = static_cast<GLdouble>(floatData[0]);
        if (pname == GL_MAX_VIEWPORT_DIMS) {
            data[1] = static_cast<GLdouble>(floatData[1]);
        }
        return true;
    }
    // GL spec: glGetDoublev must return any integer state cast to
    // double (e.g. GL_SHADER_STORAGE_BUFFER_BINDING). Probe the
    // state-tracker integer path first, then caps. Don't call
    // queryInteger() directly because it pushes GL_INVALID_ENUM
    // on miss, which would fire before our own pushError below.
    GLint intData[4] = {};
    if (impl_->state->queryInteger(pname, intData)) {
        data[0] = static_cast<GLdouble>(intData[0]);
        return true;
    }
    if (impl_->capabilities != nullptr && impl_->capabilities->queryInteger(pname, intData)) {
        data[0] = static_cast<GLdouble>(intData[0]);
        if (pname == GL_MAX_VIEWPORT_DIMS) {
            data[1] = static_cast<GLdouble>(intData[1]);
        }
        return true;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

#elif defined(APPGL_GLCONTEXT_QUERY_TRACKING)
void GLContext::noteQueryBegan(GLenum target) {
    const int index = activeQueryTargetIndex(target);
    if (index < 0) {
        return;
    }
    auto& count = impl_->activeQueryTargetCounts[static_cast<std::size_t>(index)];
    if (count == 0) {
        impl_->activeQueryTargetMask |=
            (std::uint64_t{1} << static_cast<std::size_t>(index));
    }
    ++count;
}

void GLContext::noteQueryEnded(GLenum target) {
    const int index = activeQueryTargetIndex(target);
    if (index < 0) {
        return;
    }
    auto& count = impl_->activeQueryTargetCounts[static_cast<std::size_t>(index)];
    if (count == 0) {
        return;
    }
    --count;
    if (count == 0) {
        impl_->activeQueryTargetMask &=
            ~(std::uint64_t{1} << static_cast<std::size_t>(index));
    }
}

#elif defined(APPGL_GLCONTEXT_QUERY_CREATE)
bool GLContext::createQueries(GLenum target, GLsizei n, GLuint* ids) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    // GL 4.5 §4.2.1: INVALID_ENUM if target is not one of the accepted query
    // targets. Without this, CTS direct_state_access.queries_errors hangs
    // indefinitely in the post-fail drain loop
    // `while (error == gl.getError()) ;` because it captured GL_NO_ERROR
    // (since we silently accepted the invalid target and set no error).
    switch (target) {
        case GL_SAMPLES_PASSED:
        case GL_ANY_SAMPLES_PASSED:
        case GL_ANY_SAMPLES_PASSED_CONSERVATIVE:
        case GL_PRIMITIVES_GENERATED:
        case GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN:
        case GL_TIME_ELAPSED:
        case GL_TIMESTAMP:
            break;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
    for (GLsizei i = 0; i < n; ++i) {
        ids[i] = impl_->objects->queries().reserveName();
        auto* obj = impl_->objects->queries().get(ids[i]);
        if (obj) {
            obj->target = target;
            // DSA glCreateQueries creates fully-instantiated query
            // objects — glIsQuery returns TRUE immediately without
            // a subsequent glBeginQuery.
            obj->instantiated = true;
        }
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_QUERY_BUFFER_OBJECT)
bool GLContext::validateQueryBufferObjectGet(
    GLuint id, GLuint buffer, GLenum pname, GLintptr offset,
    std::size_t resultBytes) {
    auto* buf = impl_->objects->buffers().get(buffer);
    if (!buf) { pushError(GL_INVALID_OPERATION); return false; }
    auto* q = impl_->objects->queries().get(id);
    if (!q || !q->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (q->active) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    switch (pname) {
        case GL_QUERY_RESULT:
        case GL_QUERY_RESULT_AVAILABLE:
        case GL_QUERY_RESULT_NO_WAIT:
        case GL_QUERY_TARGET:
            break;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
    if (offset < 0 ||
        (resultBytes > 0 && (offset % static_cast<GLintptr>(resultBytes)) != 0)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (offset + static_cast<GLintptr>(resultBytes) > buf->size) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    return true;
}

// GL 4.5 §4.2.1: on success, glGetQueryBufferObject* writes the
// parameter value into the target buffer at `offset`. CTS
// `direct_state_access.queries_functional` then glMapBuffer's the
// QUERY_BUFFER and compares against expected values — so the write
// must actually happen (the prior stub only validated).
//
// Result semantic per pname (mirrors non-DSA glGetQueryObject*v):
//   GL_QUERY_RESULT / GL_QUERY_RESULT_NO_WAIT → query->result
//   GL_QUERY_RESULT_AVAILABLE → GL_FALSE when still active, else GL_TRUE
//   GL_QUERY_TARGET → query->target
// Result is cast to the caller's integer width (truncation is
// acceptable per spec — GL 4.5 §4.2.1 note: the counter is copied
// "as if" via the matching scalar write).
template <typename T>
bool GLContext::writeQueryBufferObject(GLuint id, GLuint buffer, GLenum pname, GLintptr offset) {
    if (!validateQueryBufferObjectGet(id, buffer, pname, offset, sizeof(T))) {
        return false;
    }
    auto* buf = impl_->objects->buffers().get(buffer);
    auto* q = impl_->objects->queries().get(id);
    if (!buf || !q) return false;
    GLuint64 raw = 0;
    switch (pname) {
        case GL_QUERY_RESULT:
        case GL_QUERY_RESULT_NO_WAIT:
            raw = q->result;
            break;
        case GL_QUERY_RESULT_AVAILABLE:
            raw = q->active ? GL_FALSE : GL_TRUE;
            break;
        case GL_QUERY_TARGET:
            raw = static_cast<GLuint64>(q->target);
            break;
        default:
            return false;
    }
    T value = static_cast<T>(raw);
    return impl_->writeBufferRange(*buf, offset, &value,
                                   static_cast<GLsizeiptr>(sizeof(T)));
}

bool GLContext::getQueryBufferObjectiv(GLuint id, GLuint buffer, GLenum pname, GLintptr offset) {
    return writeQueryBufferObject<GLint>(id, buffer, pname, offset);
}

bool GLContext::getQueryBufferObjectuiv(GLuint id, GLuint buffer, GLenum pname, GLintptr offset) {
    return writeQueryBufferObject<GLuint>(id, buffer, pname, offset);
}

bool GLContext::getQueryBufferObjecti64v(GLuint id, GLuint buffer, GLenum pname, GLintptr offset) {
    return writeQueryBufferObject<GLint64>(id, buffer, pname, offset);
}

bool GLContext::getQueryBufferObjectui64v(GLuint id, GLuint buffer, GLenum pname, GLintptr offset) {
    return writeQueryBufferObject<GLuint64>(id, buffer, pname, offset);
}

#elif defined(APPGL_GLCONTEXT_QUERY_CONDITIONAL_RENDER)
bool GLContext::beginConditionalRender(GLuint id, GLenum mode) {
    if (impl_->conditionalRenderMode != 0) {
        // Already active — GL 4.6 §2.3.3 requires INVALID_OPERATION.
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    switch (mode) {
        case GL_QUERY_WAIT:
        case GL_QUERY_NO_WAIT:
        case GL_QUERY_BY_REGION_WAIT:
        case GL_QUERY_BY_REGION_NO_WAIT:
        case GL_QUERY_WAIT_INVERTED:
        case GL_QUERY_NO_WAIT_INVERTED:
        case GL_QUERY_BY_REGION_WAIT_INVERTED:
        case GL_QUERY_BY_REGION_NO_WAIT_INVERTED:
            break;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
    auto* q = impl_->objects->queries().get(id);
    if (q == nullptr || !q->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // §2.3.3: if the query is currently active, INVALID_OPERATION.
    if (q->active) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // §2.3.3: accepted query targets for conditional render.
    switch (q->target) {
        case GL_SAMPLES_PASSED:
        case GL_ANY_SAMPLES_PASSED:
        case GL_ANY_SAMPLES_PASSED_CONSERVATIVE:
        case GL_PRIMITIVES_GENERATED:
        case GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN:
        case GL_TRANSFORM_FEEDBACK_OVERFLOW:
        case GL_TRANSFORM_FEEDBACK_STREAM_OVERFLOW:
            break;
        default:
            pushError(GL_INVALID_OPERATION);
            return false;
    }
    impl_->conditionalRenderQueryId = id;
    impl_->conditionalRenderMode = mode;
    return true;
}

void GLContext::endConditionalRender() {
    if (impl_->conditionalRenderMode == 0) {
        pushError(GL_INVALID_OPERATION);
        return;
    }
    impl_->conditionalRenderQueryId = 0;
    impl_->conditionalRenderMode = 0;
}

#else
#error "GLContextQuery.inc.mm included without a query section selector"
#endif
