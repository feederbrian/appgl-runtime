// This file is textually included by GLContextTexture.inc.mm. Do not compile it directly.
// It contains the GLContext texture bind-image method definitions split out for navigation only.

#line 9 "/private/tmp/appgl-bug3-clean/src/context/GLContextTexture.inc.mm" // Preserve source identity so this relocation stays codegen-neutral; __FILE__/__LINE__/debug-info intentionally report the original GLContextTexture.inc.mm.
bool GLContext::bindImageTexture(GLuint unit, GLuint texture, GLint level, GLboolean layered, GLint layer, GLenum access, GLenum format) {
    if (unit >= Impl::kMaxImageUnits) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (texture != 0 && impl_->objects->textures().get(texture) == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (level < 0 || layer < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (access != GL_READ_ONLY && access != GL_WRITE_ONLY && access != GL_READ_WRITE) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Validate format — accept the common image load/store formats.
    switch (format) {
        case GL_RGBA32F:
        case GL_RGBA16F:
        case GL_RG32F:
        case GL_RG16F:
        case GL_R11F_G11F_B10F:
        case GL_R32F:
        case GL_R16F:
        case GL_RGBA32UI:
        case GL_RGBA16UI:
        case GL_RGB10_A2UI:
        case GL_RGBA8UI:
        case GL_RG32UI:
        case GL_RG16UI:
        case GL_RG8UI:
        case GL_R32UI:
        case GL_R16UI:
        case GL_R8UI:
        case GL_RGBA32I:
        case GL_RGBA16I:
        case GL_RGBA8I:
        case GL_RG32I:
        case GL_RG16I:
        case GL_RG8I:
        case GL_R32I:
        case GL_R16I:
        case GL_R8I:
        case GL_RGBA16:
        case GL_RGB10_A2:
        case GL_RGBA8:
        case GL_RG16:
        case GL_RG8:
        case GL_R16:
        case GL_R8:
        case GL_RGBA16_SNORM:
        case GL_RGBA8_SNORM:
        case GL_RG16_SNORM:
        case GL_RG8_SNORM:
        case GL_R16_SNORM:
        case GL_R8_SNORM:
            break;
        default:
            pushError(GL_INVALID_VALUE);
            return false;
    }

    auto& binding = impl_->imageBindings[unit];
    // Sprint 18 Bucket 3 / CKPT119: invalidate the cached image view if
    // the binding identity changes. The image format is part of the
    // identity because native storage images may need a PixelFormatView
    // even when the mip level is zero.
    const bool cachedViewChanged =
        (binding.metalLevelView != nullptr ||
         binding.sparseSidecarLevelView != nullptr) &&
        (binding.cachedViewTexture != texture ||
         binding.cachedViewLevel != level ||
         binding.cachedViewFormat != format ||
         binding.cachedViewLayered != layered ||
         binding.cachedViewLayer != layer);
    const bool layer3DSidecarChanged =
        binding.layer3DSidecarTexture != nullptr &&
        (binding.layer3DSidecarSourceTexture != texture ||
         binding.layer3DSidecarLevel != level ||
         binding.layer3DSidecarFormat != format ||
         binding.layer3DSidecarLayer != layer);
    if (cachedViewChanged || layer3DSidecarChanged) {
        impl_->flushImageBinding3DLayerSidecar(binding);
        binding.invalidateMetalView();
    }
    binding.texture = texture;
    binding.level = level;
    binding.layered = layered;
    binding.layer = layer;
    binding.access = access;
    binding.format = format;
    if (texture != 0 && access != GL_READ_ONLY) {
        if (GLTextureObject* object = impl_->objects->textures().get(texture)) {
            ExtensionContext extensionContext(*this);
            (void)extensions::sparse_texture::ensureSparseStorageImageSidecar(
                extensionContext, *object);
        }
    }
    return true;
}
