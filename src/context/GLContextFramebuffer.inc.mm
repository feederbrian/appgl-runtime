// This file is textually included by GLContext.mm. Do not compile it directly.
// It contains GLContext framebuffer-domain method definitions split out for navigation only.

#if defined(APPGL_GLCONTEXT_FRAMEBUFFER_CORE)
bool GLContext::genRenderbuffers(GLsizei count, GLuint* renderbuffers) {
    if (count < 0 || (count > 0 && renderbuffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        renderbuffers[index] = impl_->objects->renderbuffers().reserveName();
    }
    return true;
}

bool GLContext::deleteRenderbuffers(GLsizei count, const GLuint* renderbuffers) {
    if (count < 0 || (count > 0 && renderbuffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = renderbuffers[index];
        if (name == 0) {
            continue;
        }
        if (GLRenderbufferObject* object = impl_->objects->renderbuffers().get(name); object != nullptr) {
            impl_->releaseRenderbufferStorage(*object);
        }
        if (impl_->objects->renderbuffers().erase(name)) {
            impl_->state->deleteRenderbufferBinding(name);
            impl_->deleteRenderbufferReferencesFromFramebuffers(name);
            impl_->objects->deferDelete("renderbuffer " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isRenderbuffer(GLuint renderbuffer) const {
    const GLRenderbufferObject* object = impl_->objects->renderbuffers().get(renderbuffer);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindRenderbuffer(GLenum target, GLuint renderbuffer) {
    if (target != GL_RENDERBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (renderbuffer != 0) {
        GLRenderbufferObject* object = impl_->objects->renderbuffers().get(renderbuffer);
        if (object == nullptr) {
            if (!appglCompatProfileEnabled()) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            object = impl_->objects->renderbuffers().insertAt(renderbuffer);
            if (object == nullptr) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
        }
        object->instantiated = true;
    }
    impl_->state->bindRenderbuffer(renderbuffer);
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::RenderbufferBind);
    return true;
}

bool GLContext::renderbufferStorage(GLenum target, GLenum internalformat, GLsizei width, GLsizei height, GLsizei samples) {
    if (target != GL_RENDERBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (width < 0 || height < 0 || samples < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.6 §9.2.4: INVALID_VALUE if width or height exceeds
    // GL_MAX_RENDERBUFFER_SIZE (matches Metal's texture size ceiling).
    if (impl_->capabilities != nullptr) {
        GLint maxRB = 0;
        impl_->capabilities->queryInteger(GL_MAX_RENDERBUFFER_SIZE, &maxRB);
        if (maxRB > 0 && (width > maxRB || height > maxRB)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    if (!isSupportedRenderbufferFormat(internalformat)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // RC-D18: Validate samples against GL_MAX_SAMPLES.
    //
    // GL 4.6 §9.2.4 (and the DSA glNamedRenderbufferStorageMultisample
    // entry) specify GL_INVALID_OPERATION — NOT GL_INVALID_VALUE — when
    // samples > MAX_SAMPLES. This is checked by
    // KHR-GL46.direct_state_access.renderbuffers_storage_multisample_errors.
    // Previously we returned GL_INVALID_VALUE here; the test happened to
    // pass anyway because the `supportsTextureSampleCount:` check below
    // preempted it when our advertised MAX_SAMPLES exceeded what Metal
    // could actually deliver. Correct both the primary check's error code
    // and the preempting behaviour now that MAX_SAMPLES matches Metal.
    //
    // Also normalise samples <= 1 to 0: a single sample is logically
    // non-multisample and avoids Metal rejecting sampleCount == 1 for
    // MTLTextureType2DMultisample on some GPU families.
    if (samples <= 1) {
        samples = 0;
    } else {
        GLint maxSamples = 0;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger(GL_MAX_SAMPLES, &maxSamples);
        }
        if (maxSamples > 0 && samples > maxSamples) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        // Metal only supports a sparse set of sample counts (typically
        // powers of two), while GL callers are allowed to request any
        // count up to GL_MAX_SAMPLES. Choose the next supported Metal
        // count so renderbuffer storage behaves like the texture-MS path:
        // the actual allocation has at least the requested samples, and
        // GL_RENDERBUFFER_SAMPLES reports that actual count.
        id<MTLDevice> mtlDevice = impl_->device;
        if (mtlDevice != nil &&
            ![mtlDevice supportsTextureSampleCount:
                static_cast<NSUInteger>(samples)]) {
            GLsizei chosenSamples = 0;
            for (NSUInteger candidate : {2u, 4u, 8u, 16u, 32u}) {
                if (candidate < static_cast<NSUInteger>(samples)) {
                    continue;
                }
                if ([mtlDevice supportsTextureSampleCount:candidate]) {
                    chosenSamples = static_cast<GLsizei>(candidate);
                    break;
                }
            }
            if (chosenSamples == 0) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            samples = chosenSamples;
        }
    }
    const GLuint name = impl_->state->boundRenderbuffer();
    GLRenderbufferObject* object = impl_->objects->renderbuffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }
    if (!impl_->replaceRenderbufferStorage(*object, internalformat, width, height, samples)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::getRenderbufferParameterInteger(GLenum target, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (target != GL_RENDERBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const GLuint name = impl_->state->boundRenderbuffer();
    const GLRenderbufferObject* object = impl_->objects->renderbuffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    const auto componentSize = [&](GLenum component) -> GLint {
        if (!object->storageDefined) {
            return 0;
        }
        switch (component) {
            case GL_RED:
                if (object->internalFormat == GL_R3_G3_B2) return 3;
                if (object->internalFormat == GL_RGB4 || object->internalFormat == GL_RGBA4) return 4;
                if (object->internalFormat == GL_RGB5 || object->internalFormat == GL_RGB5_A1 || object->internalFormat == GL_RGB565) return 5;
                if (object->internalFormat == GL_RGB10 || object->internalFormat == GL_RGB10_A2) return 10;
                if (object->internalFormat == GL_RGB12 || object->internalFormat == GL_RGBA12) return 12;
                if (object->internalFormat == GL_RGB16 || object->internalFormat == GL_RGBA16) return 16;
                return isColorFormat(object->internalFormat) ? 8 : 0;
            case GL_GREEN:
                if (object->internalFormat == GL_R3_G3_B2) return 3;
                if (object->internalFormat == GL_RGB4 || object->internalFormat == GL_RGBA4) return 4;
                if (object->internalFormat == GL_RGB5 || object->internalFormat == GL_RGB5_A1) return 5;
                if (object->internalFormat == GL_RGB565) return 6;
                if (object->internalFormat == GL_RGB10 || object->internalFormat == GL_RGB10_A2) return 10;
                if (object->internalFormat == GL_RGB12 || object->internalFormat == GL_RGBA12) return 12;
                if (object->internalFormat == GL_RGB16 || object->internalFormat == GL_RGBA16) return 16;
                return isColorFormat(object->internalFormat) ? 8 : 0;
            case GL_BLUE:
                if (object->internalFormat == GL_R3_G3_B2) return 2;
                if (object->internalFormat == GL_RGB4 || object->internalFormat == GL_RGBA4) return 4;
                if (object->internalFormat == GL_RGB5 || object->internalFormat == GL_RGB5_A1 || object->internalFormat == GL_RGB565) return 5;
                if (object->internalFormat == GL_RGB10 || object->internalFormat == GL_RGB10_A2) return 10;
                if (object->internalFormat == GL_RGB12 || object->internalFormat == GL_RGBA12) return 12;
                if (object->internalFormat == GL_RGB16 || object->internalFormat == GL_RGBA16) return 16;
                return isColorFormat(object->internalFormat) ? 8 : 0;
            case GL_ALPHA:
                if (object->internalFormat == GL_ALPHA4 ||
                    object->internalFormat == GL_LUMINANCE4_ALPHA4) return 4;
                if (object->internalFormat == GL_ALPHA8 ||
                    object->internalFormat == GL_LUMINANCE6_ALPHA2 ||
                    object->internalFormat == GL_LUMINANCE8_ALPHA8 ||
                    object->internalFormat == GL_LUMINANCE12_ALPHA4) return 8;
                if (object->internalFormat == GL_ALPHA12 ||
                    object->internalFormat == GL_LUMINANCE12_ALPHA12) return 12;
                if (object->internalFormat == GL_ALPHA16 ||
                    object->internalFormat == GL_LUMINANCE16_ALPHA16) return 16;
                if (object->internalFormat == GL_RGBA2) return 2;
                if (object->internalFormat == GL_RGBA4) return 4;
                if (object->internalFormat == GL_RGB5_A1) return 1;
                if (object->internalFormat == GL_RGB10_A2) return 2;
                if (object->internalFormat == GL_RGBA12) return 12;
                if (object->internalFormat == GL_RGBA16) return 16;
                return object->internalFormat == GL_RGBA || object->internalFormat == GL_RGBA8 ? 8 : 0;
            case GL_DEPTH:
                if (object->internalFormat == GL_DEPTH_COMPONENT16) {
                    return 16;
                }
                if (object->internalFormat == GL_DEPTH_COMPONENT24 || object->internalFormat == GL_DEPTH24_STENCIL8) {
                    return 24;
                }
                return isDepthFormat(object->internalFormat) ? 32 : 0;
            case GL_STENCIL:
                return isStencilFormat(object->internalFormat) ? 8 : 0;
            default:
                return 0;
        }
    };

    switch (pname) {
        case GL_RENDERBUFFER_WIDTH:
            params[0] = object->width;
            return true;
        case GL_RENDERBUFFER_HEIGHT:
            params[0] = object->height;
            return true;
        case GL_RENDERBUFFER_INTERNAL_FORMAT:
            params[0] = static_cast<GLint>(object->internalFormat);
            return true;
        case GL_RENDERBUFFER_RED_SIZE:
            params[0] = componentSize(GL_RED);
            return true;
        case GL_RENDERBUFFER_GREEN_SIZE:
            params[0] = componentSize(GL_GREEN);
            return true;
        case GL_RENDERBUFFER_BLUE_SIZE:
            params[0] = componentSize(GL_BLUE);
            return true;
        case GL_RENDERBUFFER_ALPHA_SIZE:
            params[0] = componentSize(GL_ALPHA);
            return true;
        case GL_RENDERBUFFER_DEPTH_SIZE:
            params[0] = componentSize(GL_DEPTH);
            return true;
        case GL_RENDERBUFFER_STENCIL_SIZE:
            params[0] = componentSize(GL_STENCIL);
            return true;
        case GL_RENDERBUFFER_SAMPLES:
            params[0] = object->samples;
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::genFramebuffers(GLsizei count, GLuint* framebuffers) {
    if (count < 0 || (count > 0 && framebuffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        framebuffers[index] = impl_->objects->framebuffers().reserveName();
    }
    return true;
}

bool GLContext::deleteFramebuffers(GLsizei count, const GLuint* framebuffers) {
    if (count < 0 || (count > 0 && framebuffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = framebuffers[index];
        if (name == 0) {
            continue;
        }
        if (GLFramebufferObject* fbo =
                impl_->objects->framebuffers().get(name)) {
            GLContext::Impl::GpuResourceReadSet attachmentReads;
            for (const auto& kv : fbo->attachments) {
                impl_->appendAttachmentRead(attachmentReads, kv.second);
            }
            impl_->drainPendingGpuProducers(attachmentReads);
        }
        if (impl_->objects->framebuffers().erase(name)) {
            impl_->state->deleteFramebufferBindings(name);
            impl_->objects->deferDelete("framebuffer " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isFramebuffer(GLuint framebuffer) const {
    const GLFramebufferObject* object = impl_->objects->framebuffers().get(framebuffer);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindFramebuffer(GLenum target, GLuint framebuffer) {
    if (target != GL_FRAMEBUFFER && target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (framebuffer != 0) {
        GLFramebufferObject* object = impl_->objects->framebuffers().get(framebuffer);
        if (object == nullptr) {
            if (!appglCompatProfileEnabled()) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            object = impl_->objects->framebuffers().insertAt(framebuffer);
            if (object == nullptr) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
        }
        object->instantiated = true;
    }
    if (target == GL_FRAMEBUFFER || target == GL_DRAW_FRAMEBUFFER) {
        impl_->state->bindDrawFramebuffer(framebuffer);
    }
    if (target == GL_FRAMEBUFFER || target == GL_READ_FRAMEBUFFER) {
        impl_->state->bindReadFramebuffer(framebuffer);
    }
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::FramebufferBind);
    return true;
}

GLenum GLContext::checkFramebufferStatus(GLenum target) const {
    if (target != GL_FRAMEBUFFER && target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
        return 0;
    }
    const GLuint name = target == GL_READ_FRAMEBUFFER
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    if (name == 0) {
        return impl_->frameGraph != nullptr && impl_->frameGraph->hasValidAttachments()
            ? GL_FRAMEBUFFER_COMPLETE
            : GL_FRAMEBUFFER_UNDEFINED;
    }
    const GLFramebufferObject* object = impl_->objects->framebuffers().get(name);
    if (object == nullptr || !object->instantiated) {
        // RC-D18: Per the GL spec, glCheckFramebufferStatus only generates
        // GL_INVALID_ENUM (for an invalid target). An incomplete or
        // non-existent framebuffer is signalled via the return value, not
        // via the error queue. Pushing GL_INVALID_OPERATION here was leaking
        // a stale error into subsequent calls.
        return GL_FRAMEBUFFER_UNDEFINED;
    }
    return impl_->framebufferStatus(*object);
}

// C52 value gate: the framebuffer-domain generation must advance exactly when
// stored attachment/drawbuffer state actually changes (99140ca's unconditional
// top-of-function bumps made the domain bust on every call, including
// value-identical re-attaches and error paths). Mutators below compare the
// stored record against the incoming one and bump only on a real change.
static bool c52AttachmentEquals(const GLFramebufferAttachment& a,
                                const GLFramebufferAttachment& b) {
    return a.kind == b.kind && a.object == b.object && a.level == b.level &&
           a.layer == b.layer && a.textureTarget == b.textureTarget &&
           a.layered == b.layered && a.multiview == b.multiview &&
           a.baseViewIndex == b.baseViewIndex && a.numViews == b.numViews;
}

bool GLContext::framebufferTexture(
    GLenum target,
    GLenum attachment,
    GLenum textarget,
    GLuint texture,
    GLint level,
    GLint layer,
    bool layered,
    FramebufferTextureNameError nameError) {
    if (target != GL_FRAMEBUFFER && target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (textarget != 0 && !isTextureTarget(textarget)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // GL 4.6 §9.2.8: attachment enum shape check split from MAX-range
    // check. Unrecognised attachment → INVALID_ENUM; color-attachment-
    // shaped but >= MAX_COLOR_ATTACHMENTS → INVALID_OPERATION. See
    // framebuffers_texture_attachment_errors.
    if (!isFramebufferAttachmentEnum(attachment)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (isColorAttachmentEnum(attachment) && !isColorAttachment(attachment)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (level < 0 || layer < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint framebufferName = target == GL_READ_FRAMEBUFFER
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebufferName == 0 || framebuffer == nullptr || !framebuffer->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    if (texture == 0) {
        if (impl_->frameGraph != nullptr) {
            impl_->frameGraph->flushParallelEncodeBoundary();
        }
        if (framebuffer->attachments.erase(attachment) > 0 && impl_->state) {
            // C52: detach removed a live attachment — real change.
            impl_->state->bumpDomain(appgl::GLStateTracker::kDomainFramebuffer);
        }
        return true;
    }

    // Invalid-texture-name errors are entry-point semantics, independent of
    // whether the resulting attachment is layered. Core Layer uses
    // INVALID_OPERATION; ARB_geometry_shader4 Whole/Layer/Face and core Whole
    // use INVALID_VALUE. A reserved but never instantiated texture name is
    // still not the name of an existing texture object and follows the same
    // entry-point policy.
    const GLTextureObject* textureObject = impl_->objects->textures().get(texture);
    if (textureObject == nullptr || !textureObject->instantiated) {
        pushError(nameError == FramebufferTextureNameError::InvalidValue
                      ? GL_INVALID_VALUE
                      : GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §9.2.8 / §8.18.1 textarget-vs-texture-target validation:
    // glFramebufferTexture2D with a cube-map face textarget
    // (GL_TEXTURE_CUBE_MAP_POSITIVE_X..NEGATIVE_Z) is valid when the
    // texture is a cube map. The face textarget specifies WHICH face
    // to attach; the texture's actual `target` is GL_TEXTURE_CUBE_MAP
    // (NOT the face enum). Sprint 17 Day 2 (CKPT237) [Probe E]:
    // pre-fix, a direct comparison `obj_target != textarget` rejected
    // every cube-map-face attach with GL_INVALID_OPERATION even though
    // the texture WAS a cube map. Surfaced post-Probe-C by
    // KHR-GL46.geometry_shader.layered_rendering.layered_rendering
    // iter-0 (CUBEMAP); pre-existing bug masked by the upstream
    // h2DM-5b crash that Probe C resolved (Item 14 cascade-uncovers
    // pattern).
    {
        const bool isCubeFaceTextarget =
            textarget == GL_TEXTURE_CUBE_MAP_POSITIVE_X ||
            textarget == GL_TEXTURE_CUBE_MAP_NEGATIVE_X ||
            textarget == GL_TEXTURE_CUBE_MAP_POSITIVE_Y ||
            textarget == GL_TEXTURE_CUBE_MAP_NEGATIVE_Y ||
            textarget == GL_TEXTURE_CUBE_MAP_POSITIVE_Z ||
            textarget == GL_TEXTURE_CUBE_MAP_NEGATIVE_Z;
        const bool textargetMatchesObj =
            textureObject->target == textarget ||
            (isCubeFaceTextarget &&
             textureObject->target == GL_TEXTURE_CUBE_MAP);
        if (textarget != 0 && !textargetMatchesObj) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    // GL 4.6 §9.2.8 attachability rules on texture target.
    //
    // - GL_TEXTURE_BUFFER is never attachable to a framebuffer (it's
    //   backed by a buffer object, not image storage). Applies to every
    //   entry point (FramebufferTexture / FramebufferTexture2D /
    //   FramebufferTextureLayer).
    // - The single-layer variant (FramebufferTextureLayer and
    //   NamedFramebufferTextureLayer) additionally rejects non-layered
    //   targets: TEXTURE_RECTANGLE, TEXTURE_2D, TEXTURE_CUBE_MAP, etc.
    //   — layer indexing is only meaningful for 3D / array /
    //   multisample-array.
    // - TEXTURE_2D_MULTISAMPLE is accepted by FramebufferTexture
    //   (layered attachment; sample-level layering) but not by
    //   FramebufferTextureLayer because there's no "layer" concept on
    //   single-sample MS (vs MS array).
    //
    // The Layer variant is identified by `textarget == 0 && !layered`
    // (callers: glFramebufferTextureLayer, glNamedFramebufferTextureLayer).
    // glFramebufferTexture{1,2,3}D pass a non-zero textarget and are
    // already bounded by the textarget-vs-object-target match check
    // above, so they must not be swept up in the layer-attachable check.
    if (textureObject->target == GL_TEXTURE_BUFFER) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const bool isLayerVariant = (!layered && textarget == 0);
    if (isLayerVariant) {
        const bool isLayerAttachableTarget =
            textureObject->target == GL_TEXTURE_3D ||
            textureObject->target == GL_TEXTURE_2D_ARRAY ||
            textureObject->target == GL_TEXTURE_1D_ARRAY ||
            textureObject->target == GL_TEXTURE_CUBE_MAP_ARRAY ||
            textureObject->target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY;
        if (!isLayerAttachableTarget) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    // Immutable textures pin a hard ceiling at desc.levels - 1. Mutable
    // textures may legally attach an as-yet undefined mip level; the attach
    // itself succeeds and framebuffer completeness reports
    // GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT until storage exists.
    if (textureObject->desc.immutable) {
        const GLsizei maxLevel = std::max<GLsizei>(textureObject->desc.levels, 1);
        if (level >= maxLevel) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    // GL 4.6 §9.2.8 — `glFramebufferTextureLayer` layer validation.
    // - Negative layer: INVALID_VALUE (handled at layer<0 branch above).
    // - `layer >= GL_MAX_3D_TEXTURE_SIZE` for 3D target: INVALID_VALUE.
    // - `layer >= GL_MAX_ARRAY_TEXTURE_LAYERS` for array target:
    //   INVALID_VALUE.
    // - `layer >= 6 * GL_MAX_CUBE_MAP_TEXTURE_SIZE` for cube-map-array:
    //   INVALID_VALUE.
    // - `layer` within the implementation cap but >= the specific
    //   texture's own layer count: attach succeeds, FB is incomplete.
    //
    // Used to reject `layer >= desc.layers` unconditionally, which
    // flunks CTS `texture_cube_map_array.fbo_incompleteness.*` (expects
    // the attach to succeed so it can verify FB status goes to
    // INCOMPLETE_ATTACHMENT). Now only the implementation-cap check
    // fires — this still catches the DSA `framebuffers_texture_
    // attachment_errors` case (which uses `GL_MAX_ARRAY_TEXTURE_LAYERS`
    // as the invalid layer value).
    if (!layered && impl_->capabilities != nullptr) {
        GLint maxForTarget = 0;
        switch (textureObject->target) {
            case GL_TEXTURE_3D:
                impl_->capabilities->queryInteger(GL_MAX_3D_TEXTURE_SIZE, &maxForTarget);
                break;
            case GL_TEXTURE_2D_ARRAY:
            case GL_TEXTURE_1D_ARRAY:
            case GL_TEXTURE_2D_MULTISAMPLE_ARRAY:
                impl_->capabilities->queryInteger(GL_MAX_ARRAY_TEXTURE_LAYERS, &maxForTarget);
                break;
            case GL_TEXTURE_CUBE_MAP_ARRAY: {
                // GL 4.6 Khronos man page: "layer is larger than
                // MAX_CUBE_MAP_TEXTURE_SIZE - 1". Despite the
                // `6 × MAX` formulation that appears in §3.8.3, the
                // actual CTS DSA test compares against
                // MAX_CUBE_MAP_TEXTURE_SIZE directly (not × 6).
                impl_->capabilities->queryInteger(GL_MAX_CUBE_MAP_TEXTURE_SIZE, &maxForTarget);
                break;
            }
            default:
                break;
        }
        if (maxForTarget > 0 && layer >= maxForTarget) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    if (attachment == GL_DEPTH_ATTACHMENT && !isDepthFormat(textureObject->desc.internalFormat)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (attachment == GL_STENCIL_ATTACHMENT && !isStencilFormat(textureObject->desc.internalFormat)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (isColorAttachment(attachment) && !isColorFormat(textureObject->desc.internalFormat)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    GLFramebufferAttachment stored;
    stored.kind = GLFramebufferAttachment::Kind::Texture;
    stored.object = texture;
    stored.level = level;
    // Sprint 17 Day 2 (CKPT237) [Probe G — cascade Sub-bug A]: when
    // glFramebufferTexture2D is called with a cube-map face textarget
    // (GL_TEXTURE_CUBE_MAP_POSITIVE_X..NEGATIVE_Z), the runtime
    // wrapper passes layer=0 because per GL 4.6 §9.2.8 the cube face
    // is encoded in textarget, not in layer. Pre-fix: stored.layer
    // was set to 0 for ALL cube-face attachments, losing the
    // face-index information; downstream consumers
    // (`resolveFBOColorTarget` populating `fboColorSlices` /
    // `readColorAttachmentPixels` computing `metalSlice`) saw layer=0
    // for every face and routed Metal slice 0 (POSITIVE_X coincidence)
    // for any face. Surfaced post-Probe-E during cascade
    // investigation (Probe F) as the architecturally-clean Sub-bug A
    // localization (Item 14 cascade pattern).
    //
    // Fix: derive stored.layer from textarget when it's a cube-face
    // enum via the existing `cubeFaceIndexForTarget` helper (returns
    // 0..5 for POSITIVE_X..NEGATIVE_Z, -1 otherwise). Non-cube-face
    // call sites fall through to the caller-supplied layer (existing
    // semantics preserved).
    {
        const int cubeFaceIdx = Impl::cubeFaceIndexForTarget(textarget);
        stored.layer = (cubeFaceIdx >= 0)
            ? static_cast<GLint>(cubeFaceIdx)
            : layer;
    }
    stored.textureTarget = textarget == 0 ? textureObject->target : textarget;
    // GL 4.6 §9.4.1 defines GL_FRAMEBUFFER_ATTACHMENT_LAYERED as
    // true only when the attachment was made with FramebufferTexture
    // *and* the texture target is one of the layered kinds
    // (2D_ARRAY / 3D / CUBE_MAP / CUBE_MAP_ARRAY / 2D_MULTISAMPLE_
    // ARRAY / 1D_ARRAY). A FramebufferTexture on a plain 2D texture
    // still attaches the whole texture, but per spec the query
    // returns FALSE because the attachment has a single layer.
    // Previously we stored the raw `layered` flag from the caller
    // (true for FramebufferTexture, false for FramebufferTextureLayer)
    // without consulting the target, so
    // `geometry_shader.layered_fbo.layered_fbo_attachments` saw
    // TRUE for the 2D / MS / depth attachments where the spec says
    // FALSE.
    const bool targetIsLayered =
        textureObject->target == GL_TEXTURE_1D_ARRAY ||
        textureObject->target == GL_TEXTURE_2D_ARRAY ||
        textureObject->target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY ||
        textureObject->target == GL_TEXTURE_3D ||
        textureObject->target == GL_TEXTURE_CUBE_MAP ||
        textureObject->target == GL_TEXTURE_CUBE_MAP_ARRAY;
    stored.layered = layered && targetIsLayered;
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }
    // C52 value gate: re-attaching an identical record is a no-op — skip the
    // store and the framebuffer-domain bump. The encode-boundary flush above
    // stays unconditional (today's behavior; it is encode-side machinery, not
    // generation noise — possible future lever, out of this gate's scope).
    {
        const auto found = framebuffer->attachments.find(attachment);
        if (found != framebuffer->attachments.end() &&
            c52AttachmentEquals(found->second, stored)) {
            return true;
        }
    }
    if (impl_->state) {
        impl_->state->bumpDomain(appgl::GLStateTracker::kDomainFramebuffer);
    }
    framebuffer->attachments[attachment] = stored;
    // Sprint 17 Day 1 (CKPT236) [A.2 narrow gate]: the binding-time
    // `wasRenderedTo` set originally added by Sprint 16 Day 17
    // (CKPT226) was over-broad — DSA multisample storage tests +
    // texture_barrier tests bind their textures as colour
    // attachments but do NOT render via the viewport-flipped Metal
    // write path, so unconditionally Y-flipping their readback
    // regresses 58 tests (54 DSA + 4 TB). The flag is now set in the
    // draw-encoding path (`encodeEmulatedGsDraw` and siblings) only
    // when `routeViewportIndex == true` — the precise condition
    // under which the GPU writes Y-flipped Metal-storage rows.
    return true;
}

bool GLContext::framebufferTextureMultiviewOVR(GLenum target,
                                               GLenum attachment,
                                               GLuint texture,
                                               GLint level,
                                               GLint baseViewIndex,
                                               GLsizei numViews) {
    if (texture != 0) {
        if (baseViewIndex < 0 || numViews <= 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (impl_->capabilities != nullptr) {
            GLint maxViews = 0;
            if (impl_->capabilities->queryInteger(GL_MAX_VIEWS_OVR, &maxViews) &&
                maxViews > 0 &&
                numViews > maxViews) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
            GLint maxArrayLayers = 0;
            if (impl_->capabilities->queryInteger(GL_MAX_ARRAY_TEXTURE_LAYERS,
                                                  &maxArrayLayers) &&
                maxArrayLayers > 0 &&
                static_cast<GLint64>(baseViewIndex) +
                    static_cast<GLint64>(numViews) >
                    static_cast<GLint64>(maxArrayLayers)) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
        }
        const GLTextureObject* textureObject = impl_->objects->textures().get(texture);
        if (textureObject != nullptr && textureObject->instantiated) {
            if (textureObject->target != GL_TEXTURE_2D_ARRAY) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
        }
    }
    const bool ok = framebufferTexture(
        target,
        attachment,
        0,
        texture,
        level,
        baseViewIndex,
        true,
        FramebufferTextureNameError::InvalidValue);
    if (!ok || texture == 0) {
        return ok;
    }
    const GLuint framebufferName = target == GL_READ_FRAMEBUFFER
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    if (GLFramebufferObject* framebuffer =
            impl_->objects->framebuffers().get(framebufferName)) {
        auto found = framebuffer->attachments.find(attachment);
        if (found != framebuffer->attachments.end()) {
            found->second.multiview = true;
            found->second.layered = false;
            found->second.baseViewIndex = baseViewIndex;
            found->second.numViews = numViews;
        }
    }
    return true;
}

bool GLContext::framebufferRenderbuffer(GLenum target, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer) {
    if (target != GL_FRAMEBUFFER && target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (renderbuffertarget != GL_RENDERBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // GL 4.6 §9.2.8 splits attachment validation into two error classes:
    // an unrecognised enum → INVALID_ENUM; a color-attachment-shaped
    // enum >= MAX_COLOR_ATTACHMENTS → INVALID_OPERATION.
    if (!isFramebufferAttachmentEnum(attachment)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (isColorAttachmentEnum(attachment) && !isColorAttachment(attachment)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const GLuint framebufferName = target == GL_READ_FRAMEBUFFER
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebufferName == 0 || framebuffer == nullptr || !framebuffer->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    if (renderbuffer == 0) {
        if (framebuffer->attachments.erase(attachment) > 0 && impl_->state) {
            // C52: detach removed a live attachment — real change.
            impl_->state->bumpDomain(appgl::GLStateTracker::kDomainFramebuffer);
        }
        return true;
    }

    const GLRenderbufferObject* renderbufferObject = impl_->objects->renderbuffers().get(renderbuffer);
    if (renderbufferObject == nullptr || !renderbufferObject->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (attachment == GL_DEPTH_ATTACHMENT && renderbufferObject->storageDefined && !isDepthFormat(renderbufferObject->internalFormat)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (attachment == GL_STENCIL_ATTACHMENT && renderbufferObject->storageDefined && !isStencilFormat(renderbufferObject->internalFormat)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (isColorAttachment(attachment) && renderbufferObject->storageDefined && !isColorFormat(renderbufferObject->internalFormat)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    GLFramebufferAttachment stored;
    stored.kind = GLFramebufferAttachment::Kind::Renderbuffer;
    stored.object = renderbuffer;
    // C52 value gate: identical re-attach is a no-op — no store, no bump.
    {
        const auto found = framebuffer->attachments.find(attachment);
        if (found != framebuffer->attachments.end() &&
            c52AttachmentEquals(found->second, stored)) {
            return true;
        }
    }
    if (impl_->state) {
        impl_->state->bumpDomain(appgl::GLStateTracker::kDomainFramebuffer);
    }
    framebuffer->attachments[attachment] = stored;
    return true;
}

bool GLContext::blitFramebuffer(GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1, GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1, GLbitfield mask, GLenum filter) {
    if (filter != GL_NEAREST && filter != GL_LINEAR) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const GLbitfield kSupportedMask = GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT;
    if ((mask & ~kSupportedMask) != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (impl_->boundReadFramebufferHasMultipleViews()) {
        pushError(GL_INVALID_FRAMEBUFFER_OPERATION);
        return false;
    }
    if (!impl_->blitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    return true;
}

static GLint framebufferAttachmentColorChannelSize(GLenum fmt, int channel) {
    auto channelIn = [channel](int count) -> bool {
        return channel >= 0 && channel < count;
    };
    switch (fmt) {
        case GL_ALPHA:
        case GL_ALPHA8:
            return channel == 3 ? 8 : 0;
        case GL_ALPHA4:
            return channel == 3 ? 4 : 0;
        case GL_ALPHA12:
            return channel == 3 ? 12 : 0;
        case GL_ALPHA16:
        case GL_ALPHA16F_ARB:
            return channel == 3 ? 16 : 0;
        case GL_ALPHA32F_ARB:
            return channel == 3 ? 32 : 0;
        case GL_LUMINANCE:
        case GL_LUMINANCE8:
            return 0;
        case GL_LUMINANCE4:
            return 0;
        case GL_LUMINANCE12:
            return 0;
        case GL_LUMINANCE16:
        case GL_LUMINANCE16F_ARB:
            return 0;
        case GL_LUMINANCE32F_ARB:
            return 0;
        case GL_LUMINANCE_ALPHA:
        case GL_LUMINANCE8_ALPHA8:
            return channel == 3 ? 8 : 0;
        case GL_LUMINANCE4_ALPHA4:
            return channel == 3 ? 4 : 0;
        case GL_LUMINANCE6_ALPHA2:
            return channel == 3 ? 2 : 0;
        case GL_LUMINANCE12_ALPHA4:
            return channel == 3 ? 4 : 0;
        case GL_LUMINANCE12_ALPHA12:
            return channel == 3 ? 12 : 0;
        case GL_LUMINANCE16_ALPHA16:
        case GL_LUMINANCE_ALPHA16F_ARB:
            return channel == 3 ? 16 : 0;
        case GL_LUMINANCE_ALPHA32F_ARB:
            return channel == 3 ? 32 : 0;
        case GL_INTENSITY:
        case GL_INTENSITY8:
        case GL_INTENSITY4:
        case GL_INTENSITY12:
        case GL_INTENSITY16:
        case GL_INTENSITY16F_ARB:
        case GL_INTENSITY32F_ARB:
            return 0;
        case 3:
            return channelIn(3) ? 8 : 0;
        case 4:
            return channelIn(4) ? 8 : 0;
        case GL_R8:
        case GL_R8_SNORM:
        case GL_R8I:
        case GL_R8UI:
            return channel == 0 ? 8 : 0;
        case GL_R16:
        case GL_R16_SNORM:
        case GL_R16I:
        case GL_R16UI:
        case GL_R16F:
            return channel == 0 ? 16 : 0;
        case GL_R32F:
        case GL_R32I:
        case GL_R32UI:
            return channel == 0 ? 32 : 0;
        case GL_RG8:
        case GL_RG8_SNORM:
        case GL_RG8I:
        case GL_RG8UI:
            return channelIn(2) ? 8 : 0;
        case GL_RG16:
        case GL_RG16_SNORM:
        case GL_RG16I:
        case GL_RG16UI:
        case GL_RG16F:
            return channelIn(2) ? 16 : 0;
        case GL_RG32F:
        case GL_RG32I:
        case GL_RG32UI:
            return channelIn(2) ? 32 : 0;
        case GL_RGB:
        case GL_RGB8:
        case GL_RGB8_SNORM:
        case GL_RGB8I:
        case GL_RGB8UI:
        case GL_SRGB:
        case GL_SRGB8:
        case GL_COMPRESSED_RGB:
        case GL_COMPRESSED_RGB_S3TC_DXT1_EXT:
            return channelIn(3) ? 8 : 0;
        case GL_RGB16:
        case GL_RGB16_SNORM:
        case GL_RGB16I:
        case GL_RGB16UI:
        case GL_RGB16F:
            return channelIn(3) ? 16 : 0;
        case GL_RGB32F:
        case GL_RGB32I:
        case GL_RGB32UI:
            return channelIn(3) ? 32 : 0;
        case GL_RGBA:
        case GL_RGBA8:
        case GL_RGBA8_SNORM:
        case GL_RGBA8I:
        case GL_RGBA8UI:
        case GL_SRGB_ALPHA:
        case GL_SRGB8_ALPHA8:
        case GL_COMPRESSED_RGBA:
        case GL_COMPRESSED_RGBA_S3TC_DXT1_EXT:
        case GL_COMPRESSED_RGBA_S3TC_DXT3_EXT:
        case GL_COMPRESSED_RGBA_S3TC_DXT5_EXT:
            return channelIn(4) ? 8 : 0;
        case GL_RGBA16:
        case GL_RGBA16_SNORM:
        case GL_RGBA16I:
        case GL_RGBA16UI:
        case GL_RGBA16F:
            return channelIn(4) ? 16 : 0;
        case GL_RGBA32F:
        case GL_RGBA32I:
        case GL_RGBA32UI:
            return channelIn(4) ? 32 : 0;
        case GL_RGB565:
            if (channel == 0 || channel == 2) return 5;
            if (channel == 1) return 6;
            return 0;
        case GL_RGB5_A1:
            return channelIn(3) ? 5 : (channel == 3 ? 1 : 0);
        case GL_RGBA4:
            return channelIn(4) ? 4 : 0;
        case GL_RGB10_A2:
        case GL_RGB10_A2UI:
            return channelIn(3) ? 10 : (channel == 3 ? 2 : 0);
        case GL_RGB10:
            return channelIn(3) ? 10 : 0;
        case GL_R11F_G11F_B10F:
            if (channel == 0 || channel == 1) return 11;
            if (channel == 2) return 10;
            return 0;
        case GL_RGB9_E5:
            return channelIn(3) ? 9 : 0;
        case GL_R3_G3_B2:
            if (channel == 0 || channel == 1) return 3;
            if (channel == 2) return 2;
            return 0;
        case GL_RGB4:
            return channelIn(3) ? 4 : 0;
        case GL_RGB5:
            return channelIn(3) ? 5 : 0;
        case GL_RGB12:
            return channelIn(3) ? 12 : 0;
        case GL_RGBA2:
            return channelIn(4) ? 2 : 0;
        case GL_RGBA12:
            return channelIn(4) ? 12 : 0;
        default:
            return isColorFormat(fmt) ? 8 : 0;
    }
}

static GLenum framebufferAttachmentComponentTypeForFormat(GLenum fmt) {
    switch (fmt) {
        case GL_R16F:
        case GL_RG16F:
        case GL_RGB16F:
        case GL_RGBA16F:
        case GL_R32F:
        case GL_RG32F:
        case GL_RGB32F:
        case GL_RGBA32F:
        case GL_R11F_G11F_B10F:
        case GL_RGB9_E5:
        case GL_ALPHA16F_ARB:
        case GL_ALPHA32F_ARB:
        case GL_LUMINANCE16F_ARB:
        case GL_LUMINANCE32F_ARB:
        case GL_LUMINANCE_ALPHA16F_ARB:
        case GL_LUMINANCE_ALPHA32F_ARB:
        case GL_INTENSITY16F_ARB:
        case GL_INTENSITY32F_ARB:
            return GL_FLOAT;
        case GL_R8I:
        case GL_RG8I:
        case GL_RGB8I:
        case GL_RGBA8I:
        case GL_R16I:
        case GL_RG16I:
        case GL_RGB16I:
        case GL_RGBA16I:
        case GL_R32I:
        case GL_RG32I:
        case GL_RGB32I:
        case GL_RGBA32I:
            return GL_INT;
        case GL_R8UI:
        case GL_RG8UI:
        case GL_RGB8UI:
        case GL_RGBA8UI:
        case GL_R16UI:
        case GL_RG16UI:
        case GL_RGB16UI:
        case GL_RGBA16UI:
        case GL_R32UI:
        case GL_RG32UI:
        case GL_RGB32UI:
        case GL_RGBA32UI:
        case GL_RGB10_A2UI:
            return GL_UNSIGNED_INT;
        case GL_R8_SNORM:
        case GL_RG8_SNORM:
        case GL_RGB8_SNORM:
        case GL_RGBA8_SNORM:
        case GL_R16_SNORM:
        case GL_RG16_SNORM:
        case GL_RGB16_SNORM:
        case GL_RGBA16_SNORM:
            return GL_SIGNED_NORMALIZED;
        default:
            return GL_UNSIGNED_NORMALIZED;
    }
}

bool GLContext::getFramebufferAttachmentParameterInteger(GLenum target, GLenum attachment, GLenum pname, GLint* params) const {
    if (params == nullptr) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_VALUE);
        return false;
    }
    if (target != GL_FRAMEBUFFER && target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
        return false;
    }

    const GLuint framebufferName = target == GL_READ_FRAMEBUFFER
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();

    // Default FB has its own attachment enum set per GL 4.6 §9.2.3:
    //   {FRONT_LEFT, FRONT_RIGHT, BACK_LEFT, BACK_RIGHT, DEPTH, STENCIL}
    // plus the standard COLOR_ATTACHMENTi / DEPTH_ATTACHMENT /
    // STENCIL_ATTACHMENT / DEPTH_STENCIL_ATTACHMENT subset (COLOR_ATTACHMENT0
    // aliases FRONT_LEFT per §9.2.9). framebuffers_get_attachment_parameters
    // queries the default set.
    const bool isDefaultFbAttachment = (attachment == GL_FRONT_LEFT
        || attachment == GL_FRONT_RIGHT
        || attachment == GL_BACK_LEFT
        || attachment == GL_BACK_RIGHT
        || attachment == GL_DEPTH
        || attachment == GL_STENCIL);
    if (framebufferName == 0) {
        if (!isDefaultFbAttachment && !isFramebufferAttachmentEnum(attachment)) {
            const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
            return false;
        }
        // On the default FB all requested attachments behave as if
        // implementation-provided: return GL_FRAMEBUFFER_DEFAULT for
        // OBJECT_TYPE, 0 for NAME/LEVEL/LAYER, and fixed component sizes
        // and component type for the color/depth/stencil queries so the
        // DSA cross-check against the legacy path agrees.
        const bool isColorAttachment = (attachment == GL_FRONT_LEFT
            || attachment == GL_FRONT_RIGHT
            || attachment == GL_BACK_LEFT
            || attachment == GL_BACK_RIGHT
            || (attachment >= GL_COLOR_ATTACHMENT0 && attachment < GL_COLOR_ATTACHMENT0 + 8));
        const bool isDepthSlot = (attachment == GL_DEPTH || attachment == GL_DEPTH_ATTACHMENT);
        const bool isStencilSlot = (attachment == GL_STENCIL || attachment == GL_STENCIL_ATTACHMENT);
        switch (pname) {
            case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE:
                params[0] = GL_FRAMEBUFFER_DEFAULT;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME:
            case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL:
            case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER:
                params[0] = 0;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE:
            case GL_FRAMEBUFFER_ATTACHMENT_GREEN_SIZE:
            case GL_FRAMEBUFFER_ATTACHMENT_BLUE_SIZE:
                params[0] = isColorAttachment ? 8 : 0;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE:
                params[0] = isColorAttachment ? 8 : 0;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE:
                params[0] = isDepthSlot ? 24 : 0;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE:
                params[0] = isStencilSlot ? 8 : 0;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE:
                if (isColorAttachment) { params[0] = GL_UNSIGNED_NORMALIZED; return true; }
                if (isDepthSlot)       { params[0] = GL_UNSIGNED_NORMALIZED; return true; }
                if (isStencilSlot)     { params[0] = GL_UNSIGNED_INT;        return true; }
                params[0] = GL_NONE;
                return true;
            case GL_FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING:
                params[0] = isColorAttachment ? GL_LINEAR : GL_NONE;
                return true;
            default:
                const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
                return false;
        }
    }

    // User FB path. Attachment enum validation splits shape/range so
    // COLOR_ATTACHMENTm with m >= MAX_COLOR_ATTACHMENTS returns
    // INVALID_OPERATION rather than INVALID_ENUM (matches
    // framebuffers_get_attachment_parameter_errors).
    if (!isFramebufferAttachmentEnum(attachment)) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
        return false;
    }
    if (isColorAttachmentEnum(attachment) && !isColorAttachment(attachment)) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_OPERATION);
        return false;
    }

    const GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebuffer == nullptr || !framebuffer->instantiated) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_OPERATION);
        return false;
    }
    auto sameFramebufferImage = [](const GLFramebufferAttachment& a,
                                   const GLFramebufferAttachment& b) {
        if (a.kind != b.kind || a.object != b.object) return false;
        if (a.kind == GLFramebufferAttachment::Kind::Texture) {
            return a.level == b.level &&
                   a.layer == b.layer &&
                   a.textureTarget == b.textureTarget &&
                   a.layered == b.layered &&
                   a.multiview == b.multiview &&
                   a.baseViewIndex == b.baseViewIndex &&
                   a.numViews == b.numViews;
        }
        return true;
    };

    GLFramebufferAttachment attachmentState;
    if (attachment == GL_DEPTH_STENCIL_ATTACHMENT) {
        const auto direct = framebuffer->attachments.find(GL_DEPTH_STENCIL_ATTACHMENT);
        if (direct != framebuffer->attachments.end()) {
            attachmentState = direct->second;
        } else {
            const auto depthIt = framebuffer->attachments.find(GL_DEPTH_ATTACHMENT);
            const auto stencilIt = framebuffer->attachments.find(GL_STENCIL_ATTACHMENT);
            const bool haveDepth = depthIt != framebuffer->attachments.end()
                && depthIt->second.kind != GLFramebufferAttachment::Kind::None
                && depthIt->second.object != 0;
            const bool haveStencil = stencilIt != framebuffer->attachments.end()
                && stencilIt->second.kind != GLFramebufferAttachment::Kind::None
                && stencilIt->second.object != 0;
            if (haveDepth && haveStencil) {
                if (!sameFramebufferImage(depthIt->second, stencilIt->second)) {
                    const_cast<GLContext*>(this)->pushError(GL_INVALID_OPERATION);
                    return false;
                }
                attachmentState = depthIt->second;
            }
        }
    } else if (attachment == GL_DEPTH_ATTACHMENT ||
               attachment == GL_STENCIL_ATTACHMENT) {
        if (const GLFramebufferAttachment* aliased =
                impl_->framebufferAttachment(*framebuffer, attachment)) {
            attachmentState = *aliased;
        }
    } else {
        const auto found = framebuffer->attachments.find(attachment);
        attachmentState = found == framebuffer->attachments.end()
            ? GLFramebufferAttachment{} : found->second;
    }
    const auto attachmentInfo = impl_->framebufferAttachmentInfo(attachmentState);

    // GL 4.6 §9.2.3: when the attachment object type is GL_NONE, only
    // FRAMEBUFFER_ATTACHMENT_OBJECT_NAME and
    // FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE are valid pnames. Anything
    // else → INVALID_OPERATION. Additionally
    // FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE with
    // DEPTH_STENCIL_ATTACHMENT → INVALID_OPERATION (a depth-stencil
    // attachment has two component types, so asking for one makes no
    // sense).
    const bool objectIsNone = (attachmentState.kind == GLFramebufferAttachment::Kind::None);
    if (objectIsNone
        && pname != GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME
        && pname != GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (pname == GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE
        && attachment == GL_DEPTH_STENCIL_ATTACHMENT) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_OPERATION);
        return false;
    }

    switch (pname) {
        case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE:
            params[0] = attachmentState.kind == GLFramebufferAttachment::Kind::Texture
                ? GL_TEXTURE
                : (attachmentState.kind == GLFramebufferAttachment::Kind::Renderbuffer ? GL_RENDERBUFFER : GL_NONE);
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME:
            params[0] = static_cast<GLint>(attachmentState.object);
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL:
        case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER:
        case GL_FRAMEBUFFER_ATTACHMENT_LAYERED:
        case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_NUM_VIEWS_OVR:
        case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_BASE_VIEW_INDEX_OVR:
            // GL 4.6 §9.2.3: these pnames are only valid when
            // FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE is GL_TEXTURE. For a
            // renderbuffer attachment they generate INVALID_ENUM.
            // (The ObjectType==None case is already handled above.)
            if (attachmentState.kind != GLFramebufferAttachment::Kind::Texture) {
                const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
                return false;
            }
            if (pname == GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL) {
                params[0] = attachmentState.level;
            } else if (pname == GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER) {
                params[0] = attachmentState.layer;
            } else if (pname == GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_NUM_VIEWS_OVR) {
                params[0] = attachmentState.multiview ? attachmentState.numViews : 0;
            } else if (pname == GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_BASE_VIEW_INDEX_OVR) {
                params[0] = attachmentState.multiview ? attachmentState.baseViewIndex : 0;
            } else {
                params[0] = attachmentState.layered ? GL_TRUE : GL_FALSE;
            }
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE:
            params[0] = attachmentInfo.complete
                ? framebufferAttachmentColorChannelSize(attachmentInfo.internalFormat, 0)
                : 0;
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_GREEN_SIZE:
            params[0] = attachmentInfo.complete
                ? framebufferAttachmentColorChannelSize(attachmentInfo.internalFormat, 1)
                : 0;
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_BLUE_SIZE:
            params[0] = attachmentInfo.complete
                ? framebufferAttachmentColorChannelSize(attachmentInfo.internalFormat, 2)
                : 0;
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE:
            params[0] = attachmentInfo.complete
                ? framebufferAttachmentColorChannelSize(attachmentInfo.internalFormat, 3)
                : 0;
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE:
            if (!attachmentInfo.complete || !isDepthFormat(attachmentInfo.internalFormat)) {
                params[0] = 0;
            } else if (attachmentInfo.internalFormat == GL_DEPTH_COMPONENT16) {
                params[0] = 16;
            } else if (attachmentInfo.internalFormat == GL_DEPTH_COMPONENT32 ||
                       attachmentInfo.internalFormat == GL_DEPTH_COMPONENT32F ||
                       attachmentInfo.internalFormat == GL_DEPTH32F_STENCIL8) {
                params[0] = 32;
            } else {
                params[0] = 24;
            }
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE:
            params[0] = attachmentInfo.complete && isStencilFormat(attachmentInfo.internalFormat) ? 8 : 0;
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE:
            // GL 4.6 §9.2.3: the component type of the color/depth data.
            // For UNORM color formats and fixed-point depth the answer is
            // GL_UNSIGNED_NORMALIZED; stencil is GL_UNSIGNED_INT. CTS
            // framebuffers_get_attachment_parameters cross-checks legacy
            // vs DSA and expects matching values on user FBOs.
            if (!attachmentInfo.complete) {
                params[0] = GL_NONE;
            } else if (attachmentInfo.internalFormat == GL_DEPTH_COMPONENT32F ||
                       attachmentInfo.internalFormat == GL_DEPTH32F_STENCIL8) {
                params[0] = GL_FLOAT;
            } else if (isStencilFormat(attachmentInfo.internalFormat)
                       && !isDepthFormat(attachmentInfo.internalFormat)
                       && !isColorFormat(attachmentInfo.internalFormat)) {
                params[0] = GL_UNSIGNED_INT;
            } else if (isColorFormat(attachmentInfo.internalFormat)) {
                params[0] = framebufferAttachmentComponentTypeForFormat(
                    attachmentInfo.internalFormat);
            } else {
                params[0] = GL_UNSIGNED_NORMALIZED;
            }
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING:
            // Only meaningful for color attachments; GL_LINEAR for plain
            // RGBA8 / RGBA16 / …, GL_SRGB for *_SRGB_* formats, GL_NONE
            // otherwise.
            if (!attachmentInfo.complete) {
                params[0] = GL_NONE;
            } else if (!isColorFormat(attachmentInfo.internalFormat)) {
                params[0] = GL_LINEAR;
            } else {
                const GLenum fmt = attachmentInfo.internalFormat;
                params[0] = (fmt == GL_SRGB || fmt == GL_SRGB8
                             || fmt == GL_SRGB_ALPHA || fmt == GL_SRGB8_ALPHA8
                             || fmt == GL_COMPRESSED_SRGB || fmt == GL_COMPRESSED_SRGB_ALPHA)
                             ? GL_SRGB : GL_LINEAR;
            }
            return true;
        case GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE:
            params[0] = (attachmentState.kind == GLFramebufferAttachment::Kind::Texture &&
                         attachmentState.textureTarget >= GL_TEXTURE_CUBE_MAP_POSITIVE_X &&
                         attachmentState.textureTarget <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z)
                ? attachmentState.textureTarget
                : 0;
            return true;
        default:
            const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::drawBuffer(GLenum buffer) {
    // glDrawBuffer (singular) has looser rules than glDrawBuffers: on
    // the default framebuffer it also accepts the combined tokens
    // (FRONT, BACK, LEFT, RIGHT, FRONT_AND_BACK). Route through the
    // single-buffer validator rather than forwarding to the plural
    // form which would reject combined tokens.
    const GLuint framebufferName = impl_->state->boundDrawFramebuffer();
    if (framebufferName == 0) {
        // Default framebuffer — accepts every §17.4.1 single-target
        // token including the combined ones.
        if (!isDefaultFramebufferBuffer(buffer)) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        return impl_->state->setDrawBuffers(1, &buffer);
    }
    GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebuffer == nullptr || !framebuffer->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // User FBO — only NONE and COLOR_ATTACHMENTi tokens accepted.
    // Combined tokens are a recognized enum shape but invalid here.
    if (buffer == GL_NONE || (isColorAttachmentEnum(buffer) && isColorAttachment(buffer))) {
        std::array<GLenum, 8> incoming;
        incoming.fill(GL_NONE);
        incoming[0] = buffer;
        // C52 value gate: identical draw-buffer set is a no-op — no bump.
        if (incoming != framebuffer->drawBuffers) {
            if (impl_->state) {
                impl_->state->bumpDomain(appgl::GLStateTracker::kDomainFramebuffer);
            }
            framebuffer->drawBuffers = incoming;
        }
        framebuffer->drawBuffersExplicit = true;
        return true;
    }
    if (isColorAttachmentEnum(buffer)) {
        // Color-attachment-shaped but >= MAX_COLOR_ATTACHMENTS.
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // `buffer` is a recognized default-FB token (FRONT, BACK, etc.) —
    // not legal on a user FBO per §17.4.1.
    if (isDefaultFramebufferBuffer(buffer)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

bool GLContext::drawBuffers(GLsizei count, const GLenum* buffers) {
    if (count < 0 || count > 8 || (count > 0 && buffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint framebufferName = impl_->state->boundDrawFramebuffer();
    if (framebufferName == 0) {
        // Default framebuffer, plural variant. Per GL 4.6 §17.4.1:
        //  - Valid in bufs: NONE, FRONT_LEFT/RIGHT, BACK_LEFT/RIGHT,
        //    BACK (must be alone).
        //  - COLOR_ATTACHMENTi on default framebuffer → INVALID_OPERATION
        //    (recognised enum shape but wrong FB kind).
        //  - FRONT, FRONT_AND_BACK, LEFT, RIGHT, etc. → INVALID_ENUM
        //    (accepted on singular glDrawBuffer but not the plural).
        //  - Anything else → INVALID_ENUM.
        for (GLsizei i = 0; i < count; ++i) {
            const GLenum b = buffers[i];
            const bool isSingleDefault = (b == GL_NONE || b == GL_FRONT_LEFT ||
                b == GL_FRONT_RIGHT || b == GL_BACK_LEFT || b == GL_BACK_RIGHT ||
                b == GL_BACK);
            if (!isSingleDefault) {
                if (isColorAttachmentEnum(b)) {
                    pushError(GL_INVALID_OPERATION);
                    return false;
                }
                pushError(GL_INVALID_ENUM);
                return false;
            }
            // BACK, if present, must be the sole entry.
            if (b == GL_BACK && count != 1) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
        }
        // Duplicate check: no non-NONE token may appear twice.
        for (GLsizei i = 0; i < count; ++i) {
            if (buffers[i] == GL_NONE) continue;
            for (GLsizei j = i + 1; j < count; ++j) {
                if (buffers[j] == buffers[i]) {
                    pushError(GL_INVALID_OPERATION);
                    return false;
                }
            }
        }
        return impl_->state->setDrawBuffers(count, buffers);
    }

    GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebuffer == nullptr || !framebuffer->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // User FBO (plural). CTS distinguishes two classes of invalid
    // tokens per GL 4.6 §17.4.1's prose and examples:
    //   - Combined tokens: FRONT, LEFT, RIGHT, FRONT_AND_BACK — never
    //     valid in the plural form on ANY framebuffer → INVALID_ENUM.
    //   - Single-target default-FB tokens: FRONT_LEFT, FRONT_RIGHT,
    //     BACK_LEFT, BACK_RIGHT, BACK — valid for default FB but wrong
    //     for a user FBO → INVALID_OPERATION.
    //   - COLOR_ATTACHMENTi with i >= MAX → INVALID_OPERATION.
    //   - Unrecognised enum → INVALID_OPERATION (matches the test's
    //     "anything other than NONE or COLOR_ATTACHMENTn" clause).
    auto isCombinedDefaultFBToken = [](GLenum b) {
        return b == GL_FRONT || b == GL_LEFT || b == GL_RIGHT ||
               b == GL_FRONT_AND_BACK;
    };
    auto isSingleDefaultFBToken = [](GLenum b) {
        return b == GL_FRONT_LEFT || b == GL_FRONT_RIGHT ||
               b == GL_BACK_LEFT  || b == GL_BACK_RIGHT  || b == GL_BACK;
    };
    for (GLsizei i = 0; i < count; ++i) {
        const GLenum b = buffers[i];
        if (b == GL_NONE) continue;
        if (isColorAttachmentEnum(b)) {
            if (!isColorAttachment(b)) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            continue;
        }
        if (isCombinedDefaultFBToken(b)) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        if (isSingleDefaultFBToken(b)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        // Truly unrecognised enum (e.g. GL_TRUE = 1, random garbage):
        // INVALID_ENUM per §17.4.1's "not an accepted value".
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // Duplicate check.
    for (GLsizei i = 0; i < count; ++i) {
        if (buffers[i] == GL_NONE) continue;
        for (GLsizei j = i + 1; j < count; ++j) {
            if (buffers[j] == buffers[i]) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
        }
    }
    std::array<GLenum, 8> incoming;
    incoming.fill(GL_NONE);
    for (GLsizei index = 0; index < count; ++index) {
        incoming[static_cast<std::size_t>(index)] = buffers[index];
    }
    // C52 value gate: identical draw-buffer set is a no-op — no bump.
    if (incoming != framebuffer->drawBuffers) {
        if (impl_->state) {
            impl_->state->bumpDomain(appgl::GLStateTracker::kDomainFramebuffer);
        }
        framebuffer->drawBuffers = incoming;
    }
    framebuffer->drawBuffersExplicit = true;
    return true;
}

bool GLContext::readBuffer(GLenum buffer) {
    const GLuint framebufferName = impl_->state->boundReadFramebuffer();
    if (framebufferName == 0) {
        // Default framebuffer: accepts §17.4.1 default-FB tokens plus
        // NONE. Anything else — including COLOR_ATTACHMENTi — is
        // INVALID_OPERATION when the enum is recognised but
        // inappropriate for the target, INVALID_ENUM when unrecognised.
        if (isDefaultFramebufferBuffer(buffer)) {
            return impl_->state->setReadBuffer(buffer);
        }
        if (isColorAttachmentEnum(buffer)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLFramebufferObject* framebuffer = impl_->objects->framebuffers().get(framebufferName);
    if (framebuffer == nullptr || !framebuffer->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // User FBO: NONE or COLOR_ATTACHMENTi (where i < MAX).
    if (buffer == GL_NONE) {
        framebuffer->readBuffer = buffer;
        framebuffer->readBufferExplicit = true;
        return true;
    }
    if (isColorAttachmentEnum(buffer)) {
        if (!isColorAttachment(buffer)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        framebuffer->readBuffer = buffer;
        framebuffer->readBufferExplicit = true;
        return true;
    }
    if (isDefaultFramebufferBuffer(buffer)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

#elif defined(APPGL_GLCONTEXT_FRAMEBUFFER_PARAMETERS)
bool GLContext::framebufferParameteri(GLenum target, GLenum pname, GLint param) {
    if (target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER && target != GL_FRAMEBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // GL 4.6 §9.2.1: FramebufferParameteri operates on the user FBO
    // currently bound at `target`. The default FB (name = 0) rejects
    // every FRAMEBUFFER_DEFAULT_* pname with INVALID_OPERATION because
    // its defaults are fixed by the window system.
    const GLuint fbName = target == GL_READ_FRAMEBUFFER
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    if (fbName == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLFramebufferObject* fb = impl_->objects->framebuffers().get(fbName);
    if (fb == nullptr || !fb->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Per-pname value-range guards. GL 4.6 §9.2.1 table 9.1: negative
    // widths/heights/layers/samples are INVALID_VALUE; upper bounds
    // match the matching implementation limits reported by caps.
    const auto rangeCheckCap = [&](GLenum capPname, GLint& storage) -> bool {
        GLint maxVal = 0;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger(capPname, &maxVal);
        }
        if (param < 0 || (maxVal > 0 && param > maxVal)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        storage = param;
        return true;
    };
    switch (pname) {
        case GL_FRAMEBUFFER_DEFAULT_WIDTH:
            return rangeCheckCap(GL_MAX_FRAMEBUFFER_WIDTH, fb->defaultWidth);
        case GL_FRAMEBUFFER_DEFAULT_HEIGHT:
            return rangeCheckCap(GL_MAX_FRAMEBUFFER_HEIGHT, fb->defaultHeight);
        case GL_FRAMEBUFFER_DEFAULT_LAYERS:
            return rangeCheckCap(GL_MAX_FRAMEBUFFER_LAYERS, fb->defaultLayers);
        case GL_FRAMEBUFFER_DEFAULT_SAMPLES:
            return rangeCheckCap(GL_MAX_FRAMEBUFFER_SAMPLES, fb->defaultSamples);
        case GL_FRAMEBUFFER_DEFAULT_FIXED_SAMPLE_LOCATIONS:
            fb->defaultFixedSampleLocations = param != 0 ? GL_TRUE : GL_FALSE;
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getFramebufferParameteriv(GLenum target, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (target != GL_DRAW_FRAMEBUFFER && target != GL_READ_FRAMEBUFFER && target != GL_FRAMEBUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // GL 4.6 §9.4: pname sets differ between the default framebuffer
    // and user FBOs. Routing DSA getNamedFramebufferParameteriv through
    // bindFramebuffer(0) surfaces this split at the non-DSA path.
    const GLuint fbName = target == GL_READ_FRAMEBUFFER
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    const bool isDefaultFb = (fbName == 0);
    if (isDefaultFb) {
        switch (pname) {
            case GL_READ_BUFFER:
                *params = impl_->state->readBuffer();
                return true;
            case GL_DRAW_BUFFER:
                *params = impl_->state->drawBuffer(0);
                return true;
            case GL_DRAW_BUFFER0:
            case GL_DRAW_BUFFER1:
            case GL_DRAW_BUFFER2:
            case GL_DRAW_BUFFER3:
            case GL_DRAW_BUFFER4:
            case GL_DRAW_BUFFER5:
            case GL_DRAW_BUFFER6:
            case GL_DRAW_BUFFER7:
                *params = impl_->state->drawBuffer(static_cast<GLuint>(pname - GL_DRAW_BUFFER0));
                return true;
            case GL_DOUBLEBUFFER:                     *params = GL_TRUE;  return true;
            case GL_STEREO:                           *params = GL_FALSE; return true;
            case GL_IMPLEMENTATION_COLOR_READ_FORMAT: *params = GL_RGBA;  return true;
            case GL_IMPLEMENTATION_COLOR_READ_TYPE:   *params = GL_UNSIGNED_BYTE; return true;
            case GL_SAMPLES:
                *params = impl_->defaultFramebufferSampleCount();
                return true;
            case GL_SAMPLE_BUFFERS:
                *params = impl_->defaultFramebufferSampleBuffers();
                return true;
            default:
                // Wrong pname class for the default FB (e.g. one of the
                // FRAMEBUFFER_DEFAULT_* user-FB pnames). Spec says this
                // is INVALID_OPERATION, not INVALID_ENUM — enum is
                // recognised, it just doesn't apply to this FB kind.
                // framebuffers_get_parameter_errors distinguishes the two.
                pushError(GL_INVALID_OPERATION);
                return false;
        }
    }
    // User FBO: accept the FRAMEBUFFER_DEFAULT_* pnames, plus the
    // default-FB-class pnames (DOUBLEBUFFER/IMPL_COLOR_READ_*/SAMPLES/
    // SAMPLE_BUFFERS/STEREO) which framebuffers_get_parameters expects
    // to cross-validate against the non-DSA query. Only default FB
    // rejects the user-FB-only FRAMEBUFFER_DEFAULT_* pnames.
    const GLFramebufferObject* fb = impl_->objects->framebuffers().get(fbName);
    if (pname == GL_READ_BUFFER) {
        *params = (fb != nullptr) ? fb->readBuffer : impl_->state->readBuffer();
        return true;
    }
    if (pname == GL_DRAW_BUFFER || (pname >= GL_DRAW_BUFFER0 && pname <= GL_DRAW_BUFFER7)) {
        const GLuint index = pname == GL_DRAW_BUFFER ? 0u : static_cast<GLuint>(pname - GL_DRAW_BUFFER0);
        *params = (fb != nullptr) ? fb->drawBuffers[index] : impl_->state->drawBuffer(index);
        return true;
    }
    switch (pname) {
        case GL_FRAMEBUFFER_DEFAULT_WIDTH:
            *params = (fb != nullptr) ? fb->defaultWidth : 0;
            return true;
        case GL_FRAMEBUFFER_DEFAULT_HEIGHT:
            *params = (fb != nullptr) ? fb->defaultHeight : 0;
            return true;
        case GL_FRAMEBUFFER_DEFAULT_LAYERS:
            *params = (fb != nullptr) ? fb->defaultLayers : 0;
            return true;
        case GL_FRAMEBUFFER_DEFAULT_SAMPLES:
            *params = (fb != nullptr) ? fb->defaultSamples : 0;
            return true;
        case GL_FRAMEBUFFER_DEFAULT_FIXED_SAMPLE_LOCATIONS:
            *params = (fb != nullptr) ? (GLint)fb->defaultFixedSampleLocations : GL_TRUE;
            return true;
        case GL_IMPLEMENTATION_COLOR_READ_FORMAT: *params = GL_RGBA;         return true;
        case GL_IMPLEMENTATION_COLOR_READ_TYPE:   *params = GL_UNSIGNED_BYTE; return true;
        case GL_SAMPLES:                          *params = 0;               return true;
        case GL_SAMPLE_BUFFERS:                   *params = 0;               return true;
        case GL_DOUBLEBUFFER:                    *params = GL_TRUE;         return true;
        case GL_STEREO:                          *params = GL_FALSE;        return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

#elif defined(APPGL_GLCONTEXT_FRAMEBUFFER_INVALIDATE)
bool GLContext::invalidateFramebuffer(GLenum target, GLsizei numAttachments, const GLenum* attachments) {
    if (numAttachments < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Attachment enum validation per §17.4.4. The validation rules
    // differ for the default framebuffer (name 0) vs user framebuffer.
    const GLuint fbName = (target == GL_READ_FRAMEBUFFER)
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    const bool isDefaultFb = (fbName == 0);
    if (attachments != nullptr) {
        for (GLsizei i = 0; i < numAttachments; ++i) {
            const GLenum err = classifyInvalidateAttachment(attachments[i], isDefaultFb);
            if (err != 0) {
                pushError(err);
                return false;
            }
        }
    }
    // Performance hint: signal that attachment contents can be discarded.
    // Maps to MTLStoreAction.dontCare in a future optimization pass.
    return true;
}

bool GLContext::invalidateSubFramebuffer(GLenum target, GLsizei numAttachments, const GLenum* attachments, GLint x, GLint y, GLsizei width, GLsizei height) {
    if (numAttachments < 0 || width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint fbName = (target == GL_READ_FRAMEBUFFER)
        ? impl_->state->boundReadFramebuffer()
        : impl_->state->boundDrawFramebuffer();
    const bool isDefaultFb = (fbName == 0);
    if (attachments != nullptr) {
        for (GLsizei i = 0; i < numAttachments; ++i) {
            const GLenum err = classifyInvalidateAttachment(attachments[i], isDefaultFb);
            if (err != 0) {
                pushError(err);
                return false;
            }
        }
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_FRAMEBUFFER_CREATE)
bool GLContext::createFramebuffers(GLsizei n, GLuint* framebuffers) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        framebuffers[i] = impl_->objects->framebuffers().reserveName();
        auto* obj = impl_->objects->framebuffers().get(framebuffers[i]);
        if (obj) obj->instantiated = true;
    }
    return true;
}

bool GLContext::createRenderbuffers(GLsizei n, GLuint* renderbuffers) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        renderbuffers[i] = impl_->objects->renderbuffers().reserveName();
        auto* obj = impl_->objects->renderbuffers().get(renderbuffers[i]);
        if (obj) obj->instantiated = true;
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_FRAMEBUFFER_DSA)
bool GLContext::namedFramebufferRenderbuffer(GLuint framebuffer, GLenum attachment, GLenum renderbuffertarget, GLuint renderbuffer) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = framebufferRenderbuffer(GL_DRAW_FRAMEBUFFER, attachment, renderbuffertarget, renderbuffer);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferTexture(GLuint framebuffer, GLenum attachment, GLuint texture, GLint level) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    // glNamedFramebufferTexture binds the *whole* texture (all layers)
    // as a layered attachment. The explicit InvalidValue policy preserves
    // whole-texture name semantics independently from `layered`; textarget=0
    // avoids forcing a target match for array / cube / 3D textures.
    bool ok = framebufferTexture(
        GL_DRAW_FRAMEBUFFER,
        attachment,
        0,
        texture,
        level,
        0,
        true,
        FramebufferTextureNameError::InvalidValue);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferTexture1DEXT(GLuint framebuffer, GLenum attachment, GLenum textarget, GLuint texture, GLint level) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = framebufferTexture(
        GL_DRAW_FRAMEBUFFER,
        attachment,
        textarget,
        texture,
        level,
        0,
        false,
        FramebufferTextureNameError::InvalidOperation);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferTexture2DEXT(GLuint framebuffer, GLenum attachment, GLenum textarget, GLuint texture, GLint level) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = framebufferTexture(
        GL_DRAW_FRAMEBUFFER,
        attachment,
        textarget,
        texture,
        level,
        0,
        false,
        FramebufferTextureNameError::InvalidOperation);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferTexture3DEXT(GLuint framebuffer, GLenum attachment, GLenum textarget, GLuint texture, GLint level, GLint zoffset) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = framebufferTexture(
        GL_DRAW_FRAMEBUFFER,
        attachment,
        textarget,
        texture,
        level,
        zoffset,
        false,
        FramebufferTextureNameError::InvalidOperation);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferTextureFaceEXT(GLuint framebuffer, GLenum attachment, GLuint texture, GLint level, GLenum face) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = framebufferTexture(
        GL_DRAW_FRAMEBUFFER,
        attachment,
        face,
        texture,
        level,
        0,
        false,
        FramebufferTextureNameError::InvalidOperation);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferTextureLayer(GLuint framebuffer, GLenum attachment, GLuint texture, GLint level, GLint layer) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    // glNamedFramebufferTextureLayer binds a *specific* layer of a
    // texture (3D/Array/Cube-Array). Three wiring points preserve its
    // validation semantics:
    //
    //  - `textarget = 0` (don't check texture target against a passed
    //    enum): the spec lets this entry point accept whatever target
    //    the texture was created with, so passing GL_TEXTURE_2D here
    //    would reject 3D/array textures with INVALID_OPERATION before
    //    we ever reach the layer-bounds validator.
    //
    //  - `layered = false`: `layered=true` means "bind all layers as
    //    one attachment" (glFramebufferTexture semantics); this is
    //    the specific-layer variant, so bounds validation has to run.
    //
    //  - `InvalidOperation`: a non-object texture name follows the core
    //    Layer rule rather than the ARB_geometry_shader4 Layer rule.
    //
    // Together these let `framebufferTexture` reach the spec-required
    // INVALID_VALUE for an out-of-range layer instead of bailing
    // earlier on target mismatch or skipping the layer check entirely
    // (framebuffers_texture_attachment_errors).
    bool ok = framebufferTexture(
        GL_DRAW_FRAMEBUFFER,
        attachment,
        0,
        texture,
        level,
        layer,
        false,
        FramebufferTextureNameError::InvalidOperation);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferTextureMultiviewOVR(GLuint framebuffer,
                                                    GLenum attachment,
                                                    GLuint texture,
                                                    GLint level,
                                                    GLint baseViewIndex,
                                                    GLsizei numViews) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = framebufferTextureMultiviewOVR(
        GL_DRAW_FRAMEBUFFER,
        attachment,
        texture,
        level,
        baseViewIndex,
        numViews);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferDrawBuffer(GLuint framebuffer, GLenum buf) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = drawBuffer(buf);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferDrawBuffers(GLuint framebuffer, GLsizei n, const GLenum* bufs) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = drawBuffers(n, bufs);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferReadBuffer(GLuint framebuffer, GLenum src) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundReadFramebuffer();
    bindFramebuffer(GL_READ_FRAMEBUFFER, framebuffer);
    bool ok = readBuffer(src);
    bindFramebuffer(GL_READ_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::namedFramebufferParameteri(GLuint framebuffer, GLenum pname, GLint param) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = framebufferParameteri(GL_DRAW_FRAMEBUFFER, pname, param);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::getNamedFramebufferParameteriv(GLuint framebuffer, GLenum pname, GLint* param) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = getFramebufferParameteriv(GL_DRAW_FRAMEBUFFER, pname, param);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

bool GLContext::getNamedFramebufferAttachmentParameteriv(GLuint framebuffer, GLenum attachment, GLenum pname, GLint* params) {
    DSA_FB_CHECK(framebuffer)
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    bool ok = getFramebufferAttachmentParameterInteger(GL_DRAW_FRAMEBUFFER, attachment, pname, params);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return ok;
}

GLenum GLContext::checkNamedFramebufferStatus(GLuint framebuffer, GLenum target) {
    if (framebuffer != 0 && !impl_->objects->framebuffers().get(framebuffer)) {
        pushError(GL_INVALID_OPERATION);
        return 0;
    }
    GLuint prev = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    GLenum status = checkFramebufferStatus(target);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prev);
    return status;
}

bool GLContext::blitNamedFramebuffer(GLuint readFB, GLuint drawFB,
                                      GLint srcX0, GLint srcY0, GLint srcX1, GLint srcY1,
                                      GLint dstX0, GLint dstY0, GLint dstX1, GLint dstY1,
                                      GLbitfield mask, GLenum filter) {
    if (readFB != 0 && !impl_->objects->framebuffers().get(readFB)) { pushError(GL_INVALID_OPERATION); return false; }
    if (drawFB != 0 && !impl_->objects->framebuffers().get(drawFB)) { pushError(GL_INVALID_OPERATION); return false; }
    GLuint prevRead = impl_->state->boundReadFramebuffer();
    GLuint prevDraw = impl_->state->boundDrawFramebuffer();
    bindFramebuffer(GL_READ_FRAMEBUFFER, readFB);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, drawFB);
    bool ok = blitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter);
    bindFramebuffer(GL_READ_FRAMEBUFFER, prevRead);
    bindFramebuffer(GL_DRAW_FRAMEBUFFER, prevDraw);
    return ok;
}

// DSA clear dispatch. `buffer` selects which attachment class (COLOR,
// DEPTH, STENCIL, DEPTH_STENCIL); `drawbuffer` is an index into the FBO's
// draw-buffer array when buffer==COLOR, otherwise must be 0 per GL 4.6
// §17.4.3.1. `value` is a 4-element vector for color clears and a scalar
// for DEPTH / STENCIL. Validation errors (INVALID_ENUM / INVALID_VALUE)
// are pushed via pushError; the return value is the accept-clear bool.
bool GLContext::clearNamedFramebufferfv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLfloat* value) {
    DSA_FB_CHECK(framebuffer)
    if (value == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLFramebufferObject* fbo = impl_->objects->framebuffers().get(framebuffer);
    if (fbo == nullptr) {
        // DSA_FB_CHECK already handles non-existent FB. framebuffer==0 is
        // the default FB, which isn't currently backed as a GLFramebufferObject
        // in our store.
        if (framebuffer == 0 && buffer == GL_COLOR) {
            if (drawbuffer != 0) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
            const GLClearState previousClear = impl_->state->clearState();
            impl_->state->setClearColor(value[0], value[1], value[2], value[3]);
            impl_->applyDefaultFramebufferColorClear();
            impl_->state->setClearColor(previousClear.color[0],
                                        previousClear.color[1],
                                        previousClear.color[2],
                                        previousClear.color[3]);
            return true;
        }
        if (framebuffer == 0 && buffer != GL_DEPTH) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        return true;
    }
    if (buffer == GL_COLOR) {
        if (drawbuffer < 0 || static_cast<std::size_t>(drawbuffer) >= fbo->drawBuffers.size()) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        const GLenum attachmentEnum = fbo->drawBuffers[static_cast<std::size_t>(drawbuffer)];
        if (attachmentEnum == GL_NONE) {
            // No-op per spec (no error).
            return true;
        }
        GLFramebufferAttachment* att = impl_->framebufferAttachment(*fbo, attachmentEnum);
        if (att == nullptr) return true;
        const bool ok = impl_->clearColorAttachment(*att, value, false);
        if (ok) {
            impl_->markFramebufferAttachmentWrite(*att,
                                                  kProducerClearWrite |
                                                  kProducerFboColorWrite);
        }
        return ok;
    }
    if (buffer == GL_DEPTH) {
        if (drawbuffer != 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        GLFramebufferAttachment* att = impl_->framebufferAttachment(*fbo, GL_DEPTH_ATTACHMENT);
        if (att == nullptr) return true;
        const bool ok = impl_->clearDepthAttachment(*att, value[0]);
        if (ok) {
            impl_->markFramebufferAttachmentWrite(*att,
                                                  kProducerClearWrite |
                                                  kProducerFboDepthStencilWrite);
        }
        return ok;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

bool GLContext::clearNamedFramebufferiv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLint* value) {
    DSA_FB_CHECK(framebuffer)
    if (value == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLFramebufferObject* fbo = impl_->objects->framebuffers().get(framebuffer);
    if (fbo == nullptr) return true;
    if (buffer == GL_COLOR) {
        if (drawbuffer < 0 || static_cast<std::size_t>(drawbuffer) >= fbo->drawBuffers.size()) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        const GLenum attachmentEnum = fbo->drawBuffers[static_cast<std::size_t>(drawbuffer)];
        if (attachmentEnum == GL_NONE) return true;
        GLFramebufferAttachment* att = impl_->framebufferAttachment(*fbo, attachmentEnum);
        if (att == nullptr) return true;
        // Integer-attachment fast path: raw-int write into nativeData
        // (no normalizedByte truncation). Falls back to the float
        // passthrough when the texture has no nativeData (RGBA8,
        // float-internal formats, etc.). CTS
        // `geometry_shader.layered_framebuffer.clear_call_support`
        // CLEAR_BUFFERIV subcase targets RGBA32I where the raw
        // int must survive.
        if (impl_->clearColorAttachmentInt(*att, value)) {
            impl_->markFramebufferAttachmentWrite(*att,
                                                  kProducerClearWrite |
                                                  kProducerFboColorWrite);
            return true;
        }
        float fv[4] = {
            static_cast<float>(value[0]),
            static_cast<float>(value[1]),
            static_cast<float>(value[2]),
            static_cast<float>(value[3]),
        };
        const bool ok = impl_->clearColorAttachment(*att, fv, false);
        if (ok) {
            impl_->markFramebufferAttachmentWrite(*att,
                                                  kProducerClearWrite |
                                                  kProducerFboColorWrite);
        }
        return ok;
    }
    if (buffer == GL_STENCIL) {
        if (drawbuffer != 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        GLFramebufferAttachment* att = impl_->framebufferAttachment(*fbo, GL_STENCIL_ATTACHMENT);
        if (att == nullptr) return true;
        const bool ok = impl_->clearStencilAttachment(*att, value[0]);
        if (ok) {
            impl_->markFramebufferAttachmentWrite(*att,
                                                  kProducerClearWrite |
                                                  kProducerFboDepthStencilWrite);
        }
        return ok;
    }
    pushError(GL_INVALID_ENUM);
    return false;
}

bool GLContext::clearNamedFramebufferuiv(GLuint framebuffer, GLenum buffer, GLint drawbuffer, const GLuint* value) {
    DSA_FB_CHECK(framebuffer)
    if (value == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (buffer != GL_COLOR) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLFramebufferObject* fbo = impl_->objects->framebuffers().get(framebuffer);
    if (fbo == nullptr) return true;
    if (drawbuffer < 0 || static_cast<std::size_t>(drawbuffer) >= fbo->drawBuffers.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLenum attachmentEnum = fbo->drawBuffers[static_cast<std::size_t>(drawbuffer)];
    if (attachmentEnum == GL_NONE) return true;
    GLFramebufferAttachment* att = impl_->framebufferAttachment(*fbo, attachmentEnum);
    if (att == nullptr) return true;
    // Unsigned-integer fast path — raw uint into nativeData.
    if (impl_->clearColorAttachmentUInt(*att, value)) {
        impl_->markFramebufferAttachmentWrite(*att,
                                              kProducerClearWrite |
                                              kProducerFboColorWrite);
        return true;
    }
    float fv[4] = {
        static_cast<float>(value[0]),
        static_cast<float>(value[1]),
        static_cast<float>(value[2]),
        static_cast<float>(value[3]),
    };
    const bool ok = impl_->clearColorAttachment(*att, fv, false);
    if (ok) {
        impl_->markFramebufferAttachmentWrite(*att,
                                              kProducerClearWrite |
                                              kProducerFboColorWrite);
    }
    return ok;
}

bool GLContext::clearNamedFramebufferfi(GLuint framebuffer, GLenum buffer, GLint drawbuffer, GLfloat depth, GLint stencil) {
    DSA_FB_CHECK(framebuffer)
    if (buffer != GL_DEPTH_STENCIL) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (drawbuffer != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLFramebufferObject* fbo = impl_->objects->framebuffers().get(framebuffer);
    if (fbo == nullptr) return true;
    // Resolve via either DEPTH_STENCIL_ATTACHMENT (combined) or the
    // separate DEPTH/STENCIL attachment entries. framebufferAttachment
    // already handles the combined fallback when the query is for
    // DEPTH_ATTACHMENT / STENCIL_ATTACHMENT specifically.
    bool ok = true;
    if (GLFramebufferAttachment* depthAtt = impl_->framebufferAttachment(*fbo, GL_DEPTH_ATTACHMENT)) {
        const bool depthOk = impl_->clearDepthAttachment(*depthAtt, depth);
        if (depthOk) {
            impl_->markFramebufferAttachmentWrite(*depthAtt,
                                                  kProducerClearWrite |
                                                  kProducerFboDepthStencilWrite);
        }
        ok = depthOk && ok;
    }
    if (GLFramebufferAttachment* stencilAtt = impl_->framebufferAttachment(*fbo, GL_STENCIL_ATTACHMENT)) {
        const bool stencilOk = impl_->clearStencilAttachment(*stencilAtt, stencil);
        if (stencilOk) {
            impl_->markFramebufferAttachmentWrite(*stencilAtt,
                                                  kProducerClearWrite |
                                                  kProducerFboDepthStencilWrite);
        }
        ok = stencilOk && ok;
    }
    return ok;
}

bool GLContext::invalidateNamedFramebufferData(GLuint framebuffer, GLsizei numAttachments, const GLenum* attachments) {
    if (numAttachments < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // `framebuffer == 0` means the default framebuffer — no
    // DSA_FB_CHECK; per-attachment validation uses the default-FB enum set.
    if (framebuffer != 0) {
        auto* obj = impl_->objects->framebuffers().get(framebuffer);
        if (obj == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    }
    const bool isDefaultFb = (framebuffer == 0);
    if (attachments != nullptr) {
        for (GLsizei i = 0; i < numAttachments; ++i) {
            const GLenum err = classifyInvalidateAttachment(attachments[i], isDefaultFb);
            if (err != 0) {
                pushError(err);
                return false;
            }
        }
    }
    return true;
}

bool GLContext::invalidateNamedFramebufferSubData(GLuint framebuffer, GLsizei numAttachments, const GLenum* attachments,
                                                    GLint x, GLint y, GLsizei width, GLsizei height) {
    (void)x; (void)y;
    if (numAttachments < 0 || width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (framebuffer != 0) {
        auto* obj = impl_->objects->framebuffers().get(framebuffer);
        if (obj == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    }
    const bool isDefaultFb = (framebuffer == 0);
    if (attachments != nullptr) {
        for (GLsizei i = 0; i < numAttachments; ++i) {
            const GLenum err = classifyInvalidateAttachment(attachments[i], isDefaultFb);
            if (err != 0) {
                pushError(err);
                return false;
            }
        }
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_FRAMEBUFFER_RENDERBUFFER_DSA)
bool GLContext::namedRenderbufferStorage(GLuint renderbuffer, GLenum internalformat, GLsizei width, GLsizei height) {
    auto* obj = impl_->objects->renderbuffers().get(renderbuffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    obj->instantiated = true;
    GLuint prev = impl_->state->boundRenderbuffer();
    impl_->state->bindRenderbuffer(renderbuffer);
    bool ok = renderbufferStorage(GL_RENDERBUFFER, internalformat, width, height, 0);
    impl_->state->bindRenderbuffer(prev);
    return ok;
}

bool GLContext::namedRenderbufferStorageMultisample(GLuint renderbuffer, GLsizei samples, GLenum internalformat, GLsizei width, GLsizei height) {
    auto* obj = impl_->objects->renderbuffers().get(renderbuffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    obj->instantiated = true;
    GLuint prev = impl_->state->boundRenderbuffer();
    impl_->state->bindRenderbuffer(renderbuffer);
    bool ok = renderbufferStorage(GL_RENDERBUFFER, internalformat, width, height, samples);
    impl_->state->bindRenderbuffer(prev);
    return ok;
}

bool GLContext::getNamedRenderbufferParameteriv(GLuint renderbuffer, GLenum pname, GLint* params) {
    auto* obj = impl_->objects->renderbuffers().get(renderbuffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    if (!obj->instantiated) {
        if (params == nullptr) { pushError(GL_INVALID_VALUE); return false; }
        switch (pname) {
            case GL_RENDERBUFFER_WIDTH:
            case GL_RENDERBUFFER_HEIGHT:
            case GL_RENDERBUFFER_RED_SIZE:
            case GL_RENDERBUFFER_GREEN_SIZE:
            case GL_RENDERBUFFER_BLUE_SIZE:
            case GL_RENDERBUFFER_ALPHA_SIZE:
            case GL_RENDERBUFFER_DEPTH_SIZE:
            case GL_RENDERBUFFER_STENCIL_SIZE:
            case GL_RENDERBUFFER_SAMPLES:
                params[0] = 0;
                return true;
            case GL_RENDERBUFFER_INTERNAL_FORMAT:
                params[0] = GL_RGBA;
                return true;
            default:
                pushError(GL_INVALID_ENUM);
                return false;
        }
    }
    GLuint prev = impl_->state->boundRenderbuffer();
    impl_->state->bindRenderbuffer(renderbuffer);
    bool ok = getRenderbufferParameterInteger(GL_RENDERBUFFER, pname, params);
    impl_->state->bindRenderbuffer(prev);
    return ok;
}

#else
#error "GLContextFramebuffer.inc.mm included without a framebuffer section selector"
#endif
