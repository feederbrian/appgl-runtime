// This file is textually included by GLContextTexture.inc.mm. Do not compile it directly.
// It contains the GLContext texture multibind method definitions split out for navigation only.

#line 13 "/private/tmp/appgl-bug3-clean/src/context/GLContextTexture.inc.mm" // Preserve source identity so this relocation stays codegen-neutral; __FILE__/__LINE__/debug-info intentionally report the original GLContextTexture.inc.mm.
bool GLContext::bindTextures(GLuint first, GLsizei count, const GLuint* textures) {
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLint64 maxUnits = queryLimit(impl_->capabilities.get(), GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, 80);
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxUnits) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.4 §6.1.1 / ARB_multi_bind — per-entry semantics: an
    // invalid (non-zero, non-existent) texture name raises
    // INVALID_OPERATION and the corresponding unit is unmodified;
    // other valid entries still bind. Also per spec, ACTIVE_TEXTURE
    // is NOT modified — which our prior impl broke by cycling
    // `setActiveTextureUnit` inside the loop without restoring.
    const GLuint savedActiveUnit = impl_->state->activeTextureUnit();
    bool anyInvalid = false;
    for (GLsizei i = 0; i < count; ++i) {
        GLuint tex = textures ? textures[i] : 0;
        GLuint unit = first + static_cast<GLuint>(i);
        impl_->state->setActiveTextureUnit(unit);
        if (tex == 0) {
            // Unbind every target on this unit (multi-bind unbinds
            // regardless of previously-bound target).
            unbindAllTextureTargetsOnActiveUnit(*impl_->state);
            impl_->touchR5Residency(MetalR5ResidencyTouchKind::TextureBind);
            continue;
        }
        auto* obj = impl_->objects->textures().get(tex);
        if (obj == nullptr) {
            anyInvalid = true;
            continue;
        }
        GLenum target = obj->target != 0 ? obj->target : GL_TEXTURE_2D;
        impl_->state->bindTexture(target, tex);
        impl_->touchR5Residency(MetalR5ResidencyTouchKind::TextureBind);
    }
    impl_->state->setActiveTextureUnit(savedActiveUnit);
    if (anyInvalid) pushError(GL_INVALID_OPERATION);
    return true;
}

bool GLContext::bindSamplers(GLuint first, GLsizei count, const GLuint* samplers) {
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLint64 maxUnits = queryLimit(impl_->capabilities.get(), GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, 80);
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxUnits) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.4 §6.1.1 / ARB_multi_bind — per-entry semantics.
    bool anyInvalid = false;
    for (GLsizei i = 0; i < count; ++i) {
        GLuint sampler = samplers ? samplers[i] : 0;
        if (sampler != 0 && !impl_->objects->samplers().contains(sampler)) {
            anyInvalid = true;
            continue;
        }
        bindSampler(first + static_cast<GLuint>(i), sampler);
    }
    if (anyInvalid) pushError(GL_INVALID_OPERATION);
    return true;
}

bool GLContext::bindImageTextures(GLuint first, GLsizei count, const GLuint* textures) {
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLint64 maxUnits = queryLimit(impl_->capabilities.get(), GL_MAX_IMAGE_UNITS, 8);
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxUnits) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.4 ARB_multi_bind / §8.22 — glBindImageTextures uses
    // per-entry semantics: each invalid <textures> entry generates
    // INVALID_OPERATION and that unit's binding is *unmodified*;
    // other valid entries still get bound. Write each unit directly
    // to avoid the per-unit bindImageTexture format whitelist, which
    // is stricter than what the multi-bind spec implies (all
    // texture-storage-eligible formats are OK here).
    bool anyInvalid = false;
    for (GLsizei i = 0; i < count; ++i) {
        GLuint tex = textures ? textures[i] : 0;
        GLuint unit = first + static_cast<GLuint>(i);
        if (unit >= impl_->imageBindings.size()) break;
        auto& binding = impl_->imageBindings[unit];
        if (tex == 0) {
            impl_->flushImageBinding3DLayerSidecar(binding);
            binding.invalidateMetalView();
            binding.texture = 0;
            binding.level = 0;
            binding.layered = GL_FALSE;
            binding.layer = 0;
            binding.access = GL_READ_ONLY;
            binding.format = GL_RGBA8;
            continue;
        }
        auto* obj = impl_->objects->textures().get(tex);
        if (obj == nullptr) {
            // Invalid entry — INVALID_OPERATION, unit unmodified.
            anyInvalid = true;
            continue;
        }
        // CTS `multi_bind.errors_bind_image_textures` plants a texture
        // whose storage was never successfully allocated (texStorage2D
        // with height=0 → INVALID_VALUE) and asserts INVALID_OPERATION
        // here. Our textures store internalFormat only after a
        // successful storage/image call — a 0 means storage was never
        // provided. Functional tests (same texture via proper
        // InitStorage) always end up with a non-zero format.
        GLenum fmt = obj->desc.internalFormat;
        if (fmt == 0) {
            anyInvalid = true;
            continue;
        }
        const bool cachedViewChanged =
            binding.metalLevelView != nullptr &&
            (binding.cachedViewTexture != tex ||
             binding.cachedViewLevel != 0 ||
             binding.cachedViewFormat != fmt);
        const bool layer3DSidecarChanged =
            binding.layer3DSidecarTexture != nullptr &&
            (binding.layer3DSidecarSourceTexture != tex ||
             binding.layer3DSidecarLevel != 0 ||
             binding.layer3DSidecarFormat != fmt);
        if (cachedViewChanged || layer3DSidecarChanged) {
            impl_->flushImageBinding3DLayerSidecar(binding);
            binding.invalidateMetalView();
        }
        binding.texture = tex;
        binding.level = 0;
        binding.layered = GL_TRUE;
        binding.layer = 0;
        binding.access = GL_READ_WRITE;
        binding.format = fmt;
        {
            ExtensionContext extensionContext(*this);
            (void)extensions::sparse_texture::ensureSparseStorageImageSidecar(
                extensionContext, *obj);
        }
    }
    if (anyInvalid) {
        pushError(GL_INVALID_OPERATION);
    }
    return true;
}
