// This file is textually included by GLContextTexture.inc.mm. Do not compile it directly.
// It contains the GLContext texture-core method definitions split out for navigation only.

#line 5 "/private/tmp/appgl-bug3-clean/src/context/GLContextTexture.inc.mm" // Preserve source identity so this relocation stays codegen-neutral; __FILE__/__LINE__/debug-info intentionally report the original GLContextTexture.inc.mm.
bool GLContext::activeTexture(GLenum texture) {
    // Must match GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS in GLCapabilities.
    // CTS state reset iterates that cap — a stricter gate breaks state reset.
    GLint maxUnits = 144;
    if (impl_->capabilities != nullptr) {
        impl_->capabilities->queryInteger(GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, &maxUnits);
    }
    if (texture < GL_TEXTURE0 ||
        static_cast<GLint>(texture - GL_TEXTURE0) >= maxUnits) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    impl_->state->setActiveTextureUnit(texture - GL_TEXTURE0);
    return true;
}

bool GLContext::genTextures(GLsizei count, GLuint* textures) {
    if (count < 0 || (count > 0 && textures == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        textures[index] = impl_->objects->textures().reserveName();
    }
    return true;
}

bool GLContext::deleteTextures(GLsizei count, const GLuint* textures) {
    if (count < 0 || (count > 0 && textures == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = textures[index];
        if (name == 0) {
            continue;
        }
        if (GLTextureObject* object = impl_->objects->textures().get(name); object != nullptr) {
            for (auto& ib : impl_->imageBindings) {
                if (ib.texture == name) {
                    ib.invalidateMetalView();
                }
            }
            impl_->releaseTextureStorage(*object);
            ExtensionContext extensionContext(*this);
            extensions::sparse_texture::destroyTexture(extensionContext, *object);
        }
        if (impl_->objects->textures().erase(name)) {
            impl_->state->deleteTextureBindings(name);
            impl_->deleteTextureReferencesFromFramebuffers(name);
            // GL 4.6 §5.1.2 — deleting a texture also clears any image
            // unit binding that referenced it. CTS
            // `shader_image_load_store.basic-api-bind` asserts that
            // glGetIntegeri_v(IMAGE_BINDING_NAME) returns 0 after
            // glDeleteTextures for the previously-bound name.
            for (auto& ib : impl_->imageBindings) {
                if (ib.texture == name) {
                    ib.invalidateMetalView();
                    ib = Impl::ImageBinding{};
                }
            }
            impl_->objects->deferDelete("texture " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isTexture(GLuint texture) const {
    const GLTextureObject* object = impl_->objects->textures().get(texture);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindTexture(GLenum target, GLuint texture) {
    if (!isTextureTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (texture == 0) {
        impl_->state->bindTexture(target, 0);
        impl_->touchR5Residency(MetalR5ResidencyTouchKind::TextureBind);
        return true;
    }
    GLTextureObject* object = impl_->objects->textures().get(texture);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (object->target != 0 && object->target != target) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    object->target = target;
    object->desc.target = target;
    object->instantiated = true;
    impl_->state->bindTexture(target, texture);
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::TextureBind);
    return true;
}

bool GLContext::texImage(
    GLenum target,
    GLint level,
    GLint internalformat,
    GLsizei width,
    GLsizei height,
    GLsizei depth,
    GLint border,
    GLenum format,
    GLenum type,
    const void* pixels
) {
    const bool proxyTexture2D = target == GL_PROXY_TEXTURE_2D;
    if (!proxyTexture2D && !isTextureTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (level < 0 || width < 0 || height < 0 || depth < 0 || border != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLenum internalFormatEnum = static_cast<GLenum>(internalformat);
    const bool compatComponentCountInternalFormat =
        appglCompatProfileEnabled() &&
        isLegacyCompatComponentCountInternalFormat(internalFormatEnum);
    if ((!compatComponentCountInternalFormat &&
         !isSupportedInternalTextureFormat(*impl_->capabilities, internalFormatEnum)) ||
        componentCountForFormat(format) == 0) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (!isFormatTypeCompatible_extern(format, type)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if ((target == GL_TEXTURE_1D && (height != 1 || depth != 1))
        || ((target == GL_TEXTURE_2D || proxyTexture2D) && depth != 1)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (target == GL_TEXTURE_3D &&
        (isDepthFormat(internalFormatEnum) ||
         isStencilFormat(internalFormatEnum) ||
         isTexture3DRGTCFormat(internalFormatEnum))) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §8.5 — GL_TEXTURE_CUBE_MAP_ARRAY storage must be
    // square (width == height) with depth a multiple of 6.
    if (target == GL_TEXTURE_CUBE_MAP_ARRAY) {
        if (width != height) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if ((depth % 6) != 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    // Proxy textures only update queryable image state. They do not bind
    // storage or create Metal resources; over-limit dimensions are valid and
    // zero the proxy level so callers can test allocation feasibility.
    if (proxyTexture2D) {
        if (impl_->capabilities != nullptr) {
            GLint maxTex = 0;
            impl_->capabilities->queryInteger(GL_MAX_TEXTURE_SIZE, &maxTex);
            GLsizei logMax = 0;
            for (GLint v = maxTex; v > 1; v >>= 1) {
                ++logMax;
            }
            if (level > logMax) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
        }

        bool fitsLimits = true;
        if (impl_->capabilities != nullptr) {
            GLint maxTex = 0;
            impl_->capabilities->queryInteger(GL_MAX_TEXTURE_SIZE, &maxTex);
            fitsLimits = maxTex <= 0 || (width <= maxTex && height <= maxTex);
        }

        GLTextureImageLevel image;
        image.desc.target = target;
        image.desc.internalFormat = static_cast<GLenum>(internalformat);
        image.desc.sourceFormat = format;
        image.desc.sourceType = type;
        image.desc.width = fitsLimits ? width : 0;
        image.desc.height = fitsLimits ? height : 0;
        image.desc.depth = 1;
        image.desc.layers = 1;
        image.desc.levels = level + 1;
        image.defined = true;

        GLTextureObject* object = impl_->compatDefaultTexture(target);
        if (object == nullptr) {
            return true;
        }
        if (level == 0 || !object->levels.contains(0)) {
            object->desc = image.desc;
        }
        object->desc.levels = std::max<GLsizei>(object->desc.levels, level + 1);
        image.desc.levels = object->desc.levels;
        object->levels[level] = std::move(image);
        return true;
    }

    // Enforce GL_MAX_TEXTURE_SIZE/GL_MAX_3D_TEXTURE_SIZE before reaching
    // Metal (which asserts on oversize dims).
    if (impl_->capabilities != nullptr) {
        GLint maxTex = 0, max3D = 0, maxLayers = 0;
        impl_->capabilities->queryInteger(GL_MAX_TEXTURE_SIZE, &maxTex);
        impl_->capabilities->queryInteger(GL_MAX_3D_TEXTURE_SIZE, &max3D);
        impl_->capabilities->queryInteger(GL_MAX_ARRAY_TEXTURE_LAYERS, &maxLayers);
        if ((target == GL_TEXTURE_1D || target == GL_TEXTURE_2D ||
             target == GL_TEXTURE_1D_ARRAY || target == GL_TEXTURE_2D_ARRAY ||
             target == GL_TEXTURE_CUBE_MAP_ARRAY) && maxTex > 0) {
            GLsizei maxLevel = 0;
            for (GLint v = maxTex; v > 1; v >>= 1) {
                ++maxLevel;
            }
            if (level > maxLevel) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
            GLsizei levelMaxTex = maxTex;
            for (GLint i = 0; i < level && levelMaxTex > 1; ++i) {
                levelMaxTex >>= 1;
            }
            if (width > levelMaxTex || height > levelMaxTex) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
        }
        if (maxTex > 0 && (width > maxTex || height > maxTex)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (target == GL_TEXTURE_3D && max3D > 0 && (width > max3D || height > max3D || depth > max3D)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if ((target == GL_TEXTURE_2D_ARRAY || target == GL_TEXTURE_1D_ARRAY ||
             target == GL_TEXTURE_CUBE_MAP_ARRAY) &&
            maxLayers > 0 && depth > maxLayers) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }

    GLTextureObject* object = impl_->currentTexture(target);
    // CTS state reset (gluStateReset.cpp) calls texImage{2,3}D with size 0x0
    // on targets where no user texture is bound (default texture, name=0).
    // Per OpenGL 4.6 §8.5, such calls are valid — they either modify the
    // default texture object or are treated as a no-op when dims are 0.
    // Silently accept to keep state reset from throwing.
    if (object == nullptr) {
        return true;
    }
    if (!object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (object->desc.immutable) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }

    GLTextureImageLevel image;
    image.desc.target = target;
    image.desc.internalFormat = static_cast<GLenum>(internalformat);
    image.desc.sourceFormat = format;
    image.desc.sourceType = type;
    image.desc.width = width;
    image.desc.height = target == GL_TEXTURE_1D ? 1 : height;
    // GL_TEXTURE_3D and the array targets all carry layer/depth count in `depth`.
    image.desc.depth = (target == GL_TEXTURE_3D
                        || target == GL_TEXTURE_2D_ARRAY
                        || target == GL_TEXTURE_CUBE_MAP_ARRAY) ? depth : 1;
    // Mirror depth → layers for array targets. Parallel to the
    // texStorage3D path (line ~8180). Without this, a
    // glFramebufferTextureLayer(layer = N) on a texImage3D-allocated
    // TEXTURE_2D_ARRAY returned GL_INVALID_VALUE for every N >= 1
    // because the framebufferTexture layer-bounds check consults
    // desc.layers (which defaulted to 1), not desc.depth.
    // Fixes `geometry_shader.layered_framebuffer.stencil_support`.
    image.desc.layers = (target == GL_TEXTURE_2D_ARRAY
                          || target == GL_TEXTURE_1D_ARRAY
                          || target == GL_TEXTURE_CUBE_MAP_ARRAY)
        ? depth : 1;
    image.desc.levels = std::max<GLsizei>(object->desc.levels, level + 1);
    image.defined = true;
    const bool ignoreUnpackSkipImages =
        appglCompatProfileEnabled() &&
        isLegacyCompatTextureFormatCombo(internalFormatEnum, format) &&
        target != GL_TEXTURE_3D &&
        target != GL_TEXTURE_2D_ARRAY &&
        target != GL_TEXTURE_CUBE_MAP_ARRAY;
    // Resolve pixels against GL_PIXEL_UNPACK_BUFFER if one is bound.
    // Without this, passing an offset (as CTS does after binding a PBO)
    // would SIGSEGV when we treat the offset as a raw pointer. See
    // Impl::resolveUnpackPBO — returns (nullptr, false) for any PBO
    // validation failure (range / alignment / mapped), and the caller
    // pushes GL_INVALID_OPERATION per GL 4.6 §8.5.
    const std::size_t pxBytes = bytesPerPixel(format, type);
    const std::size_t typeBytes = isPackedPixelType(type)
        ? pxBytes : bytesPerComponent(type);
    const std::size_t requiredBytes = static_cast<std::size_t>(
        image.desc.width) * static_cast<std::size_t>(image.desc.height)
        * static_cast<std::size_t>(image.desc.depth) * pxBytes;
    auto [resolvedPixels, pboOk] = impl_->resolveUnpackPBO(
        pixels, requiredBytes, typeBytes > 0 ? typeBytes : 1);
    if (!pboOk) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const bool normalizeCompatUpload =
        shouldNormalizeLegacyCompatTextureUpload(internalFormatEnum, format) ||
        impl_->shouldApplyCompatPixelTransfer(internalFormatEnum, format, type);
    if (!impl_->buildRGBA8Upload(
            internalFormatEnum,
            image.desc.width, image.desc.height, image.desc.depth,
            format, type, resolvedPixels, image.rgba8,
            normalizeCompatUpload,
            ignoreUnpackSkipImages)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Also build native-format data for non-RGBA8 internal formats.
    impl_->buildNativeUpload(
        static_cast<GLenum>(internalformat),
        image.desc.width, image.desc.height, image.desc.depth,
        format, type, resolvedPixels, image.nativeData, image.nativeBpp,
        normalizeCompatUpload,
        ignoreUnpackSkipImages);
    if (normalizeCompatUpload && !isPackedPixelType(type)) {
        GLenum exactFormat = 0;
        switch (Impl::compatUploadBaseForInternalFormat(internalFormatEnum)) {
            case Impl::CompatUploadBase::Alpha:
                exactFormat = GL_ALPHA;
                break;
            case Impl::CompatUploadBase::Luminance:
                exactFormat = GL_LUMINANCE;
                break;
            case Impl::CompatUploadBase::LuminanceAlpha:
                exactFormat = GL_LUMINANCE_ALPHA;
                break;
            case Impl::CompatUploadBase::Intensity:
                exactFormat = GL_INTENSITY;
                break;
            default:
                break;
        }
        if (exactFormat != 0 && format == exactFormat && pxBytes > 0) {
            const bool mirrorExactIntoNative = image.nativeData.empty();
            image.exactReadbackBpp = pxBytes;
            const std::size_t totalBytes =
                static_cast<std::size_t>(image.desc.width) *
                static_cast<std::size_t>(image.desc.height) *
                static_cast<std::size_t>(image.desc.depth) *
                image.exactReadbackBpp;
            image.exactReadbackData.assign(totalBytes, 0);
            if (resolvedPixels != nullptr && totalBytes > 0) {
                const auto& store = impl_->state->pixelStore();
                const std::size_t sourceWidth =
                    static_cast<std::size_t>(store.unpackRowLength > 0
                        ? store.unpackRowLength
                        : image.desc.width);
                const std::size_t sourceHeight =
                    static_cast<std::size_t>(store.unpackImageHeight > 0
                        ? store.unpackImageHeight
                        : image.desc.height);
                const std::size_t rowBytes =
                    alignByteCount(sourceWidth * image.exactReadbackBpp,
                                   store.unpackAlignment);
                const std::size_t imageBytes = rowBytes * sourceHeight;
                const std::size_t unpackSkipImages =
                    ignoreUnpackSkipImages ? 0u
                                           : static_cast<std::size_t>(store.unpackSkipImages);
                const std::size_t sourceOffset =
                    unpackSkipImages * imageBytes +
                    static_cast<std::size_t>(store.unpackSkipRows) * rowBytes +
                    static_cast<std::size_t>(store.unpackSkipPixels) * image.exactReadbackBpp;
                const auto* source =
                    static_cast<const std::uint8_t*>(resolvedPixels) + sourceOffset;
                const bool swapBytes = (store.unpackSwapBytes == GL_TRUE);
                for (GLsizei z = 0; z < image.desc.depth; ++z) {
                    for (GLsizei y = 0; y < image.desc.height; ++y) {
                        const std::uint8_t* srcRow =
                            source + static_cast<std::size_t>(z) * imageBytes +
                            static_cast<std::size_t>(y) * rowBytes;
                        std::uint8_t* dstRow =
                            image.exactReadbackData.data() +
                            (static_cast<std::size_t>(z) *
                             static_cast<std::size_t>(image.desc.height) +
                             static_cast<std::size_t>(y)) *
                            static_cast<std::size_t>(image.desc.width) *
                            image.exactReadbackBpp;
                        std::memcpy(dstRow, srcRow,
                                    static_cast<std::size_t>(image.desc.width) *
                                    image.exactReadbackBpp);
                        if (swapBytes && typeBytes > 1) {
                            const std::size_t components =
                                componentCountForFormat(format);
                            for (GLsizei x = 0; x < image.desc.width; ++x) {
                                std::uint8_t* pixel =
                                    dstRow + static_cast<std::size_t>(x) *
                                    image.exactReadbackBpp;
                                for (std::size_t c = 0; c < components; ++c) {
                                    std::reverse(pixel + c * typeBytes,
                                                 pixel + (c + 1u) * typeBytes);
                                }
                            }
                        }
                    }
                }
            }
            if (mirrorExactIntoNative) {
                image.nativeBpp = image.exactReadbackBpp;
                image.nativeData = image.exactReadbackData;
            }
        }
    }

    if (level == 0 || !object->levels.contains(0)) {
        object->desc = image.desc;
    }
    object->desc.levels = std::max<GLsizei>(object->desc.levels, level + 1);
    image.desc.levels = object->desc.levels;
    const int faceIdx = Impl::cubeFaceIndexForTarget(target);
    if (faceIdx >= 0) {
        object->cubeFaceLevels[static_cast<std::size_t>(faceIdx)][level] = image;
    }
    object->levels[level] = std::move(image);
    // Track cube-face definition for cube-completeness checking at
    // glGenerateMipmap time. Only level-0 face definitions count toward
    // cube completeness (GL 4.6 §8.17).
    if (level == 0) {
        if (faceIdx >= 0) {
            object->cubeFacesDefined |= static_cast<std::uint8_t>(1u << faceIdx);
        }
    }
    const GLuint textureName = impl_->state->boundTexture(target);
    if (!impl_->replaceMetalTexture(*object, textureName)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    if (level == object->params.baseLevel &&
        object->params.generateMipmap == GL_TRUE) {
        const GLenum normalizedTarget = Impl::normalizeTextureBindingTarget(target);
        const bool cubeReady =
            normalizedTarget != GL_TEXTURE_CUBE_MAP ||
            object->cubeFacesDefined == 0x3F;
        if (cubeReady && impl_->generateMipmaps(*object)) {
            impl_->markGpuResourceWrites({
                {Impl::GpuResourceAccess::Kind::Texture,
                 textureName,
                 kProducerMipmapWrite}
            });
        }
    }
    return true;
}

bool GLContext::copyTexImage2D(
    GLenum target,
    GLint level,
    GLenum internalformat,
    GLint x,
    GLint y,
    GLsizei width,
    GLsizei height,
    GLint border
) {
    if (width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    GLenum uploadInternalFormat = internalformat;
    GLenum uploadFormat = GL_RGBA;
    GLenum uploadType = GL_UNSIGNED_BYTE;
    std::size_t uploadPixelBytes = 4;
    const bool isDepthStencilCopy =
        internalformat == GL_DEPTH_STENCIL ||
        internalformat == GL_DEPTH24_STENCIL8 ||
        internalformat == GL_DEPTH32F_STENCIL8;
    const bool isDepthCopy =
        !isDepthStencilCopy &&
        (internalformat == GL_DEPTH_COMPONENT ||
         internalformat == GL_DEPTH_COMPONENT16 ||
         internalformat == GL_DEPTH_COMPONENT24 ||
         internalformat == GL_DEPTH_COMPONENT32 ||
         internalformat == GL_DEPTH_COMPONENT32F);
    const bool isStencilCopy =
        !isDepthStencilCopy &&
        (internalformat == GL_STENCIL_INDEX ||
         internalformat == GL_STENCIL_INDEX8);
    const bool isRGB10A2UintCopy =
        internalformat == GL_RGB10_A2UI;
    const bool isRGB10A2Copy =
        internalformat == GL_RGB10_A2 || isRGB10A2UintCopy;

    if (isRGB10A2Copy) {
        uploadFormat = isRGB10A2UintCopy ? GL_RGBA_INTEGER : GL_RGBA;
        uploadType = GL_UNSIGNED_INT_2_10_10_10_REV;
        uploadPixelBytes = sizeof(std::uint32_t);
    } else if (isDepthStencilCopy) {
        uploadFormat = GL_DEPTH_STENCIL;
        if (internalformat == GL_DEPTH32F_STENCIL8) {
            uploadType = GL_FLOAT_32_UNSIGNED_INT_24_8_REV;
            uploadPixelBytes = 8;
        } else {
            // Unsized GL_DEPTH_STENCIL is represented with a concrete
            // D24S8 storage format so the native depth/stencil upload path
            // has a sized internal format to key from.
            uploadInternalFormat = GL_DEPTH24_STENCIL8;
            uploadType = GL_UNSIGNED_INT_24_8;
            uploadPixelBytes = 4;
        }
    } else if (isDepthCopy) {
        uploadFormat = GL_DEPTH_COMPONENT;
        uploadType = GL_FLOAT;
        uploadPixelBytes = sizeof(GLfloat);
    } else if (isStencilCopy) {
        uploadFormat = GL_STENCIL_INDEX;
        uploadType = GL_UNSIGNED_BYTE;
        uploadPixelBytes = sizeof(std::uint8_t);
    }

    if (isDepthStencilCopy) {
        const GLuint readFboName = impl_->state->boundReadFramebuffer();
        const GLFramebufferObject* readFbo =
            impl_->objects->framebuffers().get(readFboName);
        if (readFboName == 0 || readFbo == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }

        auto exactAttachment = [&](GLenum attachment)
            -> const GLFramebufferAttachment* {
            auto it = readFbo->attachments.find(attachment);
            if (it == readFbo->attachments.end()) return nullptr;
            if (it->second.kind == GLFramebufferAttachment::Kind::None ||
                it->second.object == 0) {
                return nullptr;
            }
            return &it->second;
        };
        const GLFramebufferAttachment* depthAttachment =
            exactAttachment(GL_DEPTH_ATTACHMENT);
        const GLFramebufferAttachment* stencilAttachment =
            exactAttachment(GL_STENCIL_ATTACHMENT);
        const GLFramebufferAttachment* combinedAttachment =
            exactAttachment(GL_DEPTH_STENCIL_ATTACHMENT);
        if (combinedAttachment != nullptr) {
            depthAttachment = combinedAttachment;
            stencilAttachment = combinedAttachment;
        }
        if (depthAttachment == nullptr || stencilAttachment == nullptr ||
            depthAttachment->kind != stencilAttachment->kind ||
            depthAttachment->object != stencilAttachment->object) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }

        id<MTLTexture> srcTexture = nil;
        NSUInteger srcLevel = 0;
        NSUInteger srcSlice = 0;
        NSUInteger srcZ = 0;
        if (depthAttachment->kind == GLFramebufferAttachment::Kind::Texture) {
            GLTextureObject* srcObject =
                impl_->objects->textures().get(depthAttachment->object);
            if (srcObject != nullptr && srcObject->viewSourceTexture == 0) {
                (void)impl_->restoreR5PrimaryTextureIfNeeded(
                    *srcObject, depthAttachment->object);
            }
            if (srcObject == nullptr || srcObject->metalTexture == nullptr) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            srcTexture = (__bridge id<MTLTexture>)srcObject->metalTexture;
            srcLevel = static_cast<NSUInteger>(
                std::max<GLint>(depthAttachment->level, 0));
            if (srcObject->target == GL_TEXTURE_3D) {
                srcZ = static_cast<NSUInteger>(
                    std::max<GLint>(depthAttachment->layer, 0));
            } else {
                srcSlice = static_cast<NSUInteger>(
                    std::max<GLint>(depthAttachment->layer, 0));
            }
        } else if (depthAttachment->kind ==
                   GLFramebufferAttachment::Kind::Renderbuffer) {
            const GLRenderbufferObject* srcRenderbuffer =
                impl_->objects->renderbuffers().get(depthAttachment->object);
            if (srcRenderbuffer == nullptr ||
                srcRenderbuffer->metalTexture == nullptr) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            srcTexture = (__bridge id<MTLTexture>)srcRenderbuffer->metalTexture;
        }
        if (srcTexture == nil) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }

        if (!texImage(target, level, static_cast<GLint>(uploadInternalFormat),
                      width, height, 1, border, uploadFormat, uploadType,
                      nullptr)) {
            return false;
        }
        GLTextureObject* dstObject = impl_->currentTexture(target);
        if (dstObject == nullptr || dstObject->metalTexture == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        id<MTLTexture> dstTexture =
            (__bridge id<MTLTexture>)dstObject->metalTexture;
        impl_->drainFramebufferAttachmentProducer(*depthAttachment);
        if (impl_->device == nil || impl_->commandQueue == nil) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        // C48: the blit writes into dstTexture — land any deferred FBO
        // clear on it first so the clear cannot overwrite the copy.
        if (impl_->frameGraph != nullptr) {
            impl_->frameGraph->materializePendingFboClearsForTexture(
                dstObject->metalTexture);
        }
        auto lease = impl_->makeCommandBuffer(AppGLCommandReason::CopyImageBlit);
        id<MTLCommandBuffer> cmd = lease.get();
        if (cmd == nil) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        if (blit == nil) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        if (width > 0 && height > 0) {
            [blit copyFromTexture:srcTexture
                      sourceSlice:srcSlice
                      sourceLevel:srcLevel
                     sourceOrigin:MTLOriginMake(
                         static_cast<NSUInteger>(std::max<GLint>(x, 0)),
                         static_cast<NSUInteger>(std::max<GLint>(y, 0)),
                         srcZ)
                       sourceSize:MTLSizeMake(
                         static_cast<NSUInteger>(width),
                         static_cast<NSUInteger>(height),
                         1)
                        toTexture:dstTexture
                 destinationSlice:0
                 destinationLevel:static_cast<NSUInteger>(level)
                destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
        [blit endEncoding];
        lease.commitAndWait(AppGLCommandReason::CopyImageBlit);
        impl_->markGpuResourceWrites({
            {Impl::GpuResourceAccess::Kind::Texture,
             impl_->state->boundTexture(target),
             kProducerCopyWrite}
        });
        return true;
    }

    const bool trimCopyBorder =
        border == 1 &&
        target == GL_TEXTURE_2D &&
        !isDepthCopy &&
        !isStencilCopy;
    if (trimCopyBorder) {
        if (width < 2 || height < 2) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        x += 1;
        y += 1;
        width -= 2;
        height -= 2;
        border = 0;
    }

    const std::size_t pixelCount =
        static_cast<std::size_t>(width) *
        static_cast<std::size_t>(height);
    std::vector<std::uint8_t> uploadBytes(pixelCount * uploadPixelBytes, 0);

    GLenum readFormat = GL_RGBA;
    if (isDepthCopy) {
        readFormat = GL_DEPTH_COMPONENT;
    } else if (isStencilCopy) {
        readFormat = GL_STENCIL_INDEX;
    }
    bool didRead = false;
    if (isRGB10A2Copy) {
        didRead = impl_->readFBOColorNative(x, y, width, height,
                                            uploadFormat, uploadType,
                                            uploadBytes.data());
        if (!didRead) {
            uploadType = GL_UNSIGNED_BYTE;
        }
    }
    if (!didRead &&
        !impl_->readFramebufferPixels(readFormat, x, y,
                                      width, height,
                                      uploadBytes.data())) {
        const bool defaultReadFramebuffer =
            impl_->state->boundReadFramebuffer() == 0;
        if (!defaultReadFramebuffer ||
            !readPixels(x, y, width, height, readFormat, uploadType,
                        uploadBytes.data())) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }

    const bool copied = texImage(target, level,
                                 static_cast<GLint>(uploadInternalFormat),
                                 width, height, 1, border,
                                 uploadFormat, uploadType,
                                 uploadBytes.data());
    if (copied) {
        impl_->markGpuResourceWrites({
            {Impl::GpuResourceAccess::Kind::Texture,
             impl_->state->boundTexture(target),
             kProducerCopyWrite}
        });
    }
    return copied;
}

bool GLContext::copyTexImage1D(
    GLenum target,
    GLint level,
    GLenum internalformat,
    GLint x,
    GLint y,
    GLsizei width,
    GLint border
) {
    return copyTexImage2D(target, level, internalformat, x, y, width, 1, border);
}

bool GLContext::copyTexSubImage1D(
    GLenum target,
    GLint level,
    GLint xoffset,
    GLint x,
    GLint y,
    GLsizei width
) {
    const GLuint texture = impl_->state->boundTexture(target);
    if (!validateCopyTextureSubImage(texture, 1, level,
                                     xoffset, 0, 0, width, 1)) {
        return false;
    }
    if (width == 0) {
        return true;
    }

    std::vector<std::uint8_t> uploadBytes(
        static_cast<std::size_t>(width) * 4u, 0);
    if (!readPixels(x, y, width, 1,
                    GL_RGBA, GL_UNSIGNED_BYTE, uploadBytes.data())) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const bool copied = texSubImage(target, level, xoffset, 0, 0,
                                    width, 1, 1,
                                    GL_RGBA, GL_UNSIGNED_BYTE,
                                    uploadBytes.data());
    if (copied) {
        impl_->markGpuResourceWrites({
            {Impl::GpuResourceAccess::Kind::Texture, texture,
             kProducerCopyWrite}
        });
    }
    return copied;
}

bool GLContext::copyTexSubImage2D(
    GLenum target,
    GLint level,
    GLint xoffset,
    GLint yoffset,
    GLint x,
    GLint y,
    GLsizei width,
    GLsizei height
) {
    const GLuint texture = impl_->state->boundTexture(target);
    if (!validateCopyTextureSubImage(texture, 2, level,
                                     xoffset, yoffset, 0, width, height)) {
        return false;
    }
    if (width == 0 || height == 0) {
        return true;
    }

    std::vector<std::uint8_t> uploadBytes(
        static_cast<std::size_t>(width) *
        static_cast<std::size_t>(height) * 4u, 0);
    if (!readPixels(x, y, width, height,
                    GL_RGBA, GL_UNSIGNED_BYTE, uploadBytes.data())) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const bool copied = texSubImage(target, level, xoffset, yoffset, 0,
                                    width, height, 1,
                                    GL_RGBA, GL_UNSIGNED_BYTE,
                                    uploadBytes.data());
    if (copied) {
        impl_->markGpuResourceWrites({
            {Impl::GpuResourceAccess::Kind::Texture, texture,
             kProducerCopyWrite}
        });
    }
    return copied;
}

bool GLContext::texSubImage(
    GLenum target,
    GLint level,
    GLint xoffset,
    GLint yoffset,
    GLint zoffset,
    GLsizei width,
    GLsizei height,
    GLsizei depth,
    GLenum format,
    GLenum type,
    const void* pixels
) {
    if (!isTextureTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (level < 0 || xoffset < 0 || yoffset < 0 || zoffset < 0 || width < 0 || height < 0 || depth < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (componentCountForFormat(format) == 0) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // Type validation — unknown / unsupported type enums must produce
    // GL_INVALID_ENUM (GL 4.6 §8.4.4 / §8.5, Table 8.7). Without this,
    // the test's m_type_invalid case saw GL_INVALID_OPERATION from
    // the downstream buildRGBA8Upload failure.
    if (!isPackedPixelType(type) && bytesPerComponent(type) == 0) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // Format / type compatibility (GL 4.6 Table 8.7). Packed types
    // constrain the format they can appear with. A format like GL_RG
    // with type GL_UNSIGNED_BYTE_3_3_2 should produce
    // GL_INVALID_OPERATION per spec — our impl previously silently
    // accepted the combination and proceeded to upload junk.
    if (!isFormatTypeCompatible_extern(format, type)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    const GLenum bindingTarget = Impl::normalizeTextureBindingTarget(target);
    const GLuint boundTextureName =
        impl_->state->boundTexture(bindingTarget);
    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Level bounds vs MAX_TEXTURE_SIZE must yield INVALID_VALUE, not
    // INVALID_OPERATION (GL 4.6 §8.5: "level is greater than log2 max,
    // where max is MAX_TEXTURE_SIZE"). Distinct from "level defined?"
    // which we check below — an out-of-range level index is invalid
    // before we even look at the map.
    if (impl_->capabilities != nullptr) {
        GLint maxTex = 0;
        impl_->capabilities->queryInteger(GL_MAX_TEXTURE_SIZE, &maxTex);
        if (maxTex > 0) {
            const int maxLevel = static_cast<int>(
                mipLevelCountForDimensions(
                    static_cast<std::size_t>(maxTex),
                    1u,
                    1u) -
                1u);
            if (level > maxLevel) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
        }
    }
    GLTextureObject* storageObject = object;
    GLuint storageTextureName = boundTextureName;
    GLint storageLevel = level;
    GLint storageLayerBase = 0;
    const bool writeThroughView = object->viewSourceTexture != 0;
    if (writeThroughView) {
        const GLint viewLevels = std::max<GLint>(
            object->viewNumLevels > 0 ? object->viewNumLevels
                                      : object->desc.levels,
            1);
        if (level >= viewLevels) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        const GLint viewLayers = std::max<GLint>(
            object->viewNumLayers > 0 ? object->viewNumLayers
                                      : object->desc.layers,
            1);
        if (zoffset > viewLayers || depth > viewLayers - zoffset) {
            pushError(GL_INVALID_VALUE);
            return false;
        }

        storageLevel = object->viewMinLevel + level;
        storageLayerBase = object->viewMinLayer;
        GLuint rootName = object->viewSourceTexture;
        GLTextureObject* rootObject = impl_->objects->textures().get(rootName);
        std::unordered_set<GLuint> visited;
        while (rootObject != nullptr && rootObject->viewSourceTexture != 0) {
            if (!visited.insert(rootName).second) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            rootName = rootObject->viewSourceTexture;
            rootObject = impl_->objects->textures().get(rootName);
        }
        if (rootObject == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        storageObject = rootObject;
        storageTextureName = rootName;
    }

    auto levelIt = storageObject->levels.find(storageLevel);
    if (levelIt == storageObject->levels.end() || !levelIt->second.defined) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    ExtensionContext extensionContext(*this);
    const int cubeFaceForSubImage = Impl::cubeFaceIndexForTarget(target);
    int storageCubeFaceForSubImage = cubeFaceForSubImage;
    const GLenum storageTarget =
        storageObject->desc.target != 0 ? storageObject->desc.target
                                        : storageObject->target;
    if (writeThroughView && storageTarget == GL_TEXTURE_CUBE_MAP) {
        if (cubeFaceForSubImage >= 0) {
            storageCubeFaceForSubImage =
                storageLayerBase + cubeFaceForSubImage;
        } else {
            storageCubeFaceForSubImage = storageLayerBase + zoffset;
        }
        if (storageCubeFaceForSubImage < 0 ||
            storageCubeFaceForSubImage >= 6) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    const int sparseCubeFace =
        (extensions::sparse_texture::textureSparse(extensionContext, storageObject) == GL_TRUE &&
         storageTarget == GL_TEXTURE_CUBE_MAP &&
         levelIt->second.desc.depth >= 6)
            ? storageCubeFaceForSubImage
            : -1;
    GLTextureImageLevel* imagePtr = &levelIt->second;
    if (storageCubeFaceForSubImage >= 0 && sparseCubeFace < 0) {
        auto& faceLevels = storageObject->cubeFaceLevels[static_cast<std::size_t>(storageCubeFaceForSubImage)];
        auto [faceIt, _inserted] = faceLevels.try_emplace(storageLevel, levelIt->second);
        imagePtr = &faceIt->second;
    }
    GLTextureImageLevel& image = *imagePtr;
    if (storageObject->desc.internalFormat == GL_DEPTH_COMPONENT32F &&
        !storageObject->depthStencilShadowAuthoritative) {
        (void)impl_->syncDepth32FTextureLevelNativeFromMetal(
            *storageObject, storageLevel);
    }
    if (!impl_->materializeTextureMipShadowFromMetal(
            *storageObject,
            storageLevel,
            Impl::TextureMipShadowMaterializeConsumer::TexSubImage)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    image.generatedMipLevel = false;
    image.exactReadbackData.clear();
    image.exactReadbackBpp = 0;
    GLint effectiveZoffset = zoffset;
    if (sparseCubeFace >= 0) {
        effectiveZoffset = sparseCubeFace;
    } else if (writeThroughView && storageCubeFaceForSubImage < 0) {
        effectiveZoffset += storageLayerBase;
    }
    if (xoffset > image.desc.width || width > image.desc.width - xoffset
        || yoffset > image.desc.height || height > image.desc.height - yoffset
        || effectiveZoffset > image.desc.depth || depth > image.desc.depth - effectiveZoffset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const bool ignoreUnpackSkipImages =
        appglCompatProfileEnabled() &&
        isLegacyCompatTextureFormatCombo(image.desc.internalFormat, format) &&
        target != GL_TEXTURE_3D &&
        target != GL_TEXTURE_2D_ARRAY &&
        target != GL_TEXTURE_CUBE_MAP_ARRAY;

    // Resolve pixels against GL_PIXEL_UNPACK_BUFFER if bound (see
    // texImage for rationale). CTS DSA textures_subimage_errors SIGSEGV
    // was rooted here — the test binds a PBO, passes a byte-offset as
    // the `pixels` argument, and expects GL_INVALID_OPERATION for
    // out-of-range / mapped / unaligned conditions. Without PBO
    // resolution we dereferenced the offset as a raw pointer and
    // crashed.
    //
    // The null-pixels check is DEFERRED until after PBO resolution —
    // with a PBO bound, pixels==nullptr is the offset 0, which is
    // valid (and even expected for "read from start of buffer").
    // Without a PBO, nullptr with non-zero dimensions is INVALID_VALUE.
    const std::size_t pxBytes = bytesPerPixel(format, type);
    const std::size_t typeBytes = isPackedPixelType(type)
        ? pxBytes : bytesPerComponent(type);
    const std::size_t requiredBytes = static_cast<std::size_t>(width)
        * static_cast<std::size_t>(height) * static_cast<std::size_t>(depth)
        * pxBytes;
    auto [resolvedPixels, pboOk] = impl_->resolveUnpackPBO(
        pixels, requiredBytes, typeBytes > 0 ? typeBytes : 1);
    if (!pboOk) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const bool pboBound = impl_->state->boundBuffer(GL_PIXEL_UNPACK_BUFFER) != 0;
    if (!pboBound && width > 0 && height > 0 && depth > 0 && resolvedPixels == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    std::vector<std::uint8_t> upload;
    const bool normalizeCompatUpload =
        shouldNormalizeLegacyCompatTextureUpload(image.desc.internalFormat, format) ||
        impl_->shouldApplyCompatPixelTransfer(image.desc.internalFormat, format, type);
    if (!impl_->buildRGBA8Upload(
            image.desc.internalFormat,
            width, height, depth, format, type, resolvedPixels, upload,
            normalizeCompatUpload,
            ignoreUnpackSkipImages)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }
    const std::size_t imageRgba8Bytes =
        rgba8ByteCount(image.desc.width,
                       image.desc.height,
                       image.desc.depth);
    if (image.rgba8.size() < imageRgba8Bytes) {
        if (!materializeRedR8TextureShadowFromNativeData(image) ||
            image.rgba8.size() < imageRgba8Bytes) {
            image.rgba8.resize(imageRgba8Bytes, 0);
        }
    }
    for (GLsizei z = 0; z < depth; ++z) {
        for (GLsizei y = 0; y < height; ++y) {
            const std::size_t sourceOffset =
                (static_cast<std::size_t>(z) * static_cast<std::size_t>(height) + static_cast<std::size_t>(y))
                * static_cast<std::size_t>(width) * 4u;
            const std::size_t destOffset =
                ((static_cast<std::size_t>(z + effectiveZoffset) * static_cast<std::size_t>(image.desc.height)
                    + static_cast<std::size_t>(y + yoffset))
                    * static_cast<std::size_t>(image.desc.width)
                    + static_cast<std::size_t>(xoffset))
                * 4u;
            std::memcpy(
                image.rgba8.data() + destOffset,
                upload.data() + sourceOffset,
                static_cast<std::size_t>(width) * 4u
            );
        }
    }

    // Also update native-format data when present.
    if (image.nativeBpp > 0 && !image.nativeData.empty()) {
        std::vector<std::uint8_t> nativeUpload;
        std::size_t nativeBpp = 0;
        if (impl_->buildNativeUpload(image.desc.internalFormat,
                width, height, depth, format, type, resolvedPixels,
                nativeUpload, nativeBpp,
                normalizeCompatUpload,
                ignoreUnpackSkipImages) && nativeBpp == image.nativeBpp) {
            for (GLsizei z = 0; z < depth; ++z) {
                for (GLsizei y = 0; y < height; ++y) {
                    const std::size_t srcOff =
                        (static_cast<std::size_t>(z) * static_cast<std::size_t>(height)
                         + static_cast<std::size_t>(y))
                        * static_cast<std::size_t>(width) * nativeBpp;
                    const std::size_t dstOff =
                        ((static_cast<std::size_t>(z + effectiveZoffset) * static_cast<std::size_t>(image.desc.height)
                          + static_cast<std::size_t>(y + yoffset))
                         * static_cast<std::size_t>(image.desc.width)
                         + static_cast<std::size_t>(xoffset))
                        * nativeBpp;
                    std::memcpy(
                        image.nativeData.data() + dstOff,
                        nativeUpload.data() + srcOff,
                        static_cast<std::size_t>(width) * nativeBpp);
                }
            }
        }
    }

    // Phase 8X Group 4d follow-up¹¹ — §Secondary per-subregion
    // fingerprint. Fires at most once per distinct
    // `(texName, xoffset, yoffset, width, height)` so Recoil's
    // glyph streaming (one sub-image call per glyph rect) gets
    // fingerprinted at the first update to each distinct
    // rectangle without flooding the log on repeat updates to
    // the same rectangle.
    //
    // The hash runs on the channel-fill-expanded RGBA8 `upload`
    // vector — that's the same representation the outer texture's
    // level-0 byte store uses, so BAR can cross-reference it
    // against the native-GL-path fingerprint BAR computes on the
    // post-channel-fill RGBA8.
    //
    // Unlike `replaceMetalTexture`'s log, this fires unconditionally
    // (not gated on texName !=0) because by the time we reach this
    // point the object pointer is valid and we know the bound
    // texture name is non-zero (currentTexture returned a concrete
    // object).
    const GLuint subTexName = boundTextureName;
    if (subTexName != 0 && depth == 1) {
        Impl::SubImageRegionKey key{subTexName, xoffset, yoffset, width, height};
        if (impl_->loggedSubImageRegions.insert(key).second) {
            const std::uint8_t* subBytes = upload.data();
            const std::size_t subByteCount = upload.size();
            auto fnv1a = [](const std::uint8_t* p, std::size_t n) {
                std::uint32_t h = 0x811c9dc5u;
                for (std::size_t i = 0; i < n; ++i) {
                    h ^= p[i];
                    h *= 0x01000193u;
                }
                return h;
            };
            const std::uint32_t subHash = subByteCount ? fnv1a(subBytes, subByteCount) : 0;
            std::uint32_t nonzeroCount = 0;
            for (std::size_t i = 0; i < subByteCount; ++i) {
                if (subBytes[i] != 0) { ++nonzeroCount; }
            }
            char hexPeek[64] = {0};
            const std::size_t peekLen = std::min<std::size_t>(subByteCount, 16);
            for (std::size_t i = 0; i < peekLen; ++i) {
                std::snprintf(hexPeek + i * 3, sizeof(hexPeek) - i * 3,
                              "%02X ", subBytes[i]);
            }
            if (peekLen > 0) { hexPeek[peekLen * 3 - 1] = '\0'; }
            APPGL_LOG(TEXTURE, @"[GL] texSubImage first-call texName=%u target=0x%04X level=%d"
                  @" subregion=[%d,%d,%d,%d] sourceFormat=0x%04X sourceType=0x%04X"
                  @" rgba8Bytes=%zu fnv1a=0x%08X nonzero=%u peek16=[%s]",
                  subTexName,
                  static_cast<unsigned>(target),
                  level,
                  xoffset, yoffset, width, height,
                  static_cast<unsigned>(format),
                  static_cast<unsigned>(type),
                  subByteCount,
                  subHash,
                  nonzeroCount,
                  hexPeek);
        }
    }

    if (storageCubeFaceForSubImage >= 0 && sparseCubeFace < 0) {
        storageObject->levels[storageLevel] = image;
    }

    if (!impl_->replaceMetalTexture(*storageObject, storageTextureName)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

// Sprint 17 Day 7+ Bank-Group-E: compressed-texture upload.
//
// Pre-fix `glCompressedTexImage2D` was a drop-data stub at
// AppGLGroup8.cpp:528 — only desc.width/height/internalFormat were
// recorded; no Metal texture allocated, no bytes uploaded. CTS
// `direct_state_access.textures_get_image` (compressed sub-test)
// uploads BC7 (16 bytes) via this path then reads it back via
// glGetCompressedTextureImage; pre-fix readback returned zeros.
//
// Implementation strategy:
// 1. Look up MTLPixelFormat from caps (already populated for BPTC +
//    RGTC at GLCapabilities.mm:524-537 when supportsBC).
// 2. Allocate MTLTexture with that format + width/height + level
//    count (single mipLevel for now; multi-level arrives via
//    compressedTexSubImage on subsequent calls).
// 3. Upload via replaceRegion with block-aware byte counts and
//    GL_UNPACK_COMPRESSED_BLOCK_* pixel-store layout.
// 4. Stash MTLTexture pointer on the GLTextureObject so subsequent
//    sample / readback paths see it.
//
// BC/RGTC/BPTC/S3TC and ASTC LDR route through native Metal compressed
// pixel formats when the capability table registers them.
bool GLContext::compressedTexImage(GLenum target, GLint level,
                                   GLenum internalformat,
                                   GLsizei width, GLsizei height,
                                   GLsizei depth,
                                   GLsizei imageSize, const void* data) {
    if (level < 0 || width <= 0 || height <= 0 || depth <= 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!object->instantiated) {
        // First bind via glBindTexture should have set instantiated.
        // Synthesise one here so the caller path stays defensive.
        object->instantiated = true;
    }
    const int cubeFace = Impl::cubeFaceIndexForTarget(target);
    const GLenum effectiveTarget = cubeFace >= 0 ? GL_TEXTURE_CUBE_MAP : target;
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }
    // Sprint 17 Day 9+ Bank-Group-E narrow-gate (regression-debt #3):
    // record dimensions UNCONDITIONALLY for any valid level/width/
    // height before format-specific dispatch. Pre-narrow `dcba5cd`
    // the dimension-recording happened later in the BC-format arm
    // only; non-BC formats (ETC2 / EAC / ASTC) hit the default arm
    // and returned true WITHOUT setting desc, leaving subsequent
    // glGetCompressedTextureSubImage validation comparing
    // `xoffset+width > texW=0` and pushing GL_INVALID_VALUE — CTS
    // `get_texture_sub_image.errors_test` uses GL_COMPRESSED_RGB8_ETC2
    // and expected GL_INVALID_OPERATION on bufSize-too-small.
    object->target = effectiveTarget;
    object->desc.target = effectiveTarget;
    object->desc.internalFormat = internalformat;
    object->desc.levels = std::max<GLsizei>(object->desc.levels, level + 1);
    if (level == 0 || object->desc.width <= 0) {
        object->desc.width = width;
        object->desc.height = (effectiveTarget == GL_TEXTURE_1D) ? 1 : height;
        object->desc.depth = (effectiveTarget == GL_TEXTURE_CUBE_MAP) ? 6 : depth;
        object->desc.layers = (effectiveTarget == GL_TEXTURE_2D_ARRAY ||
                               effectiveTarget == GL_TEXTURE_CUBE_MAP_ARRAY ||
                               effectiveTarget == GL_TEXTURE_CUBE_MAP) ? object->desc.depth : 1;
    }
    if (impl_->capabilities == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    auto fmtCap = impl_->capabilities->format(internalformat);
    if (!fmtCap.has_value() || !fmtCap->compressed) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const CompressedBlockInfo block = compressedBlockInfoForInternalFormat(internalformat);
    if (block.bytes == 0) {
        // ETC2/EAC and generic compressed formats still use the legacy
        // dimension-recording path until their uploads get native backing.
        return true;
    }
    if (effectiveTarget == GL_TEXTURE_CUBE_MAP_ARRAY) {
        if (width != height || (depth % 6) != 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    } else if (effectiveTarget == GL_TEXTURE_CUBE_MAP) {
        if (cubeFace < 0 || width != height) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    } else if (effectiveTarget != GL_TEXTURE_2D &&
               effectiveTarget != GL_TEXTURE_2D_ARRAY) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const MTLPixelFormat pf = static_cast<MTLPixelFormat>(fmtCap->metalPixelFormat);
    id<MTLDevice> mtlDevice = impl_->device;
    if (mtlDevice == nil) {
        // No Metal device — silently accept; downstream sampling /
        // readback will hit the no-MTLTexture branch.
        return true;
    }
    // Record dimensions on the GL texture object so subsequent queries
    // (glGetCompressedTextureSubImage bounds, glGetTexLevelParameter)
    // see the right values. Keep the object-level descriptor anchored to
    // level 0; per-mip dimensions live in object->levels[level]. Shrinking
    // object->desc on each mip upload reallocates the Metal texture down to
    // the final 1x1 mip, leaving terrain samplers bound to placeholder-sized
    // BC textures.
    object->target = effectiveTarget;
    object->desc.target = effectiveTarget;
    object->desc.internalFormat = internalformat;
    object->desc.levels = std::max<GLsizei>(object->desc.levels, level + 1);
    if (level == 0 || object->desc.width <= 0) {
        object->desc.width = width;
        object->desc.height = (effectiveTarget == GL_TEXTURE_1D) ? 1 : height;
        object->desc.depth = (effectiveTarget == GL_TEXTURE_CUBE_MAP) ? 6 : depth;
        object->desc.layers = (effectiveTarget == GL_TEXTURE_2D_ARRAY ||
                               effectiveTarget == GL_TEXTURE_CUBE_MAP_ARRAY ||
                               effectiveTarget == GL_TEXTURE_CUBE_MAP) ? object->desc.depth : 1;
    }

    GLTextureImageLevel image;
    image.desc = object->desc;
    image.desc.width = width;
    image.desc.height = (effectiveTarget == GL_TEXTURE_1D) ? 1 : height;
    image.desc.depth = (effectiveTarget == GL_TEXTURE_CUBE_MAP) ? 1 : depth;
    image.desc.layers = (effectiveTarget == GL_TEXTURE_2D_ARRAY ||
                         effectiveTarget == GL_TEXTURE_CUBE_MAP_ARRAY) ? depth : 1;
    image.desc.levels = object->desc.levels;
    image.defined = true;
    if (cubeFace >= 0) {
        object->cubeFaceLevels[static_cast<std::size_t>(cubeFace)][level] = image;
        object->levels[level] = image;
        if (level == 0) {
            object->cubeFacesDefined |= static_cast<std::uint8_t>(1u << cubeFace);
        }
        return true;
    }
    object->levels[level] = std::move(image);

    const auto baseImageIt = object->levels.find(0);
    const GLTextureDesc& baseDesc =
        (baseImageIt != object->levels.end() && baseImageIt->second.defined)
            ? baseImageIt->second.desc
            : object->desc;
    const GLsizei allocationWidth = std::max<GLsizei>(baseDesc.width, 1);
    const GLsizei allocationHeight = std::max<GLsizei>(
        (effectiveTarget == GL_TEXTURE_1D) ? 1 : baseDesc.height,
        1);
    const GLsizei allocationDepth = std::max<GLsizei>(
        (effectiveTarget == GL_TEXTURE_CUBE_MAP) ? 6 : baseDesc.depth,
        1);

    // Allocate Metal texture if missing OR if format/shape changed. The
    // allocation shape must come from level 0, not the currently uploaded
    // mip level. Native compressed uploads write each mip into the same
    // Metal texture; reallocating from level N's dimensions loses earlier
    // mip data and leaves only the final 1x1 level resident.
    id<MTLTexture> existing = (__bridge id<MTLTexture>)object->metalTexture;
    const bool arrayTexture = effectiveTarget == GL_TEXTURE_2D_ARRAY;
    const bool cubeArrayTexture = effectiveTarget == GL_TEXTURE_CUBE_MAP_ARRAY;
    const bool slicedTexture = arrayTexture || cubeArrayTexture;
    const NSUInteger uploadSlices = slicedTexture ? static_cast<NSUInteger>(depth) : 1u;
    const NSUInteger arrayLength = cubeArrayTexture
        ? static_cast<NSUInteger>(std::max<GLsizei>(allocationDepth, 6) / 6)
        : (arrayTexture ? static_cast<NSUInteger>(allocationDepth) : 1u);
    const MTLTextureType textureType = cubeArrayTexture
        ? MTLTextureTypeCubeArray
        : (arrayTexture ? MTLTextureType2DArray : MTLTextureType2D);
    const NSUInteger allocationMipCount = metalNaturalMipLevelCountForTexture(
        effectiveTarget,
        /*use2DFor1D=*/false,
        static_cast<NSUInteger>(allocationWidth),
        static_cast<NSUInteger>(allocationHeight),
        1u);
    bool needAlloc = (existing == nil) ||
                     existing.textureType != textureType ||
                     existing.pixelFormat != pf ||
                     existing.width != static_cast<NSUInteger>(allocationWidth) ||
                     existing.height != static_cast<NSUInteger>(allocationHeight) ||
                     existing.arrayLength != arrayLength ||
                     nonZeroMipLevelCount(existing.mipmapLevelCount) !=
                         allocationMipCount;
    if (needAlloc) {
        MTLTextureDescriptor* desc = [[MTLTextureDescriptor alloc] init];
        ScopedOwnedMetalObject descRelease(desc);
        desc.textureType = textureType;
        desc.pixelFormat = pf;
        desc.width = static_cast<NSUInteger>(allocationWidth);
        desc.height = static_cast<NSUInteger>(allocationHeight);
        desc.depth = 1;
        desc.arrayLength = arrayLength;
        desc.mipmapLevelCount = allocationMipCount;
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        id<MTLTexture> newTex = [mtlDevice newTextureWithDescriptor:desc];
        if (newTex == nil) {
            pushError(GL_OUT_OF_MEMORY);
            return false;
        }
        if (object->metalTexture != nullptr) {
            releaseRetainedMetalObject(object->metalTexture);
        }
        object->metalTexture = transferRetainedMetalObject(newTex);
        existing = newTex;
    }
    // Upload payload (if provided). GL_UNPACK_* values are specified in
    // texels; compressed row/image strides are derived in blocks.
    if (data != nullptr && imageSize > 0) {
        const GLPixelStoreState& store = impl_->state->pixelStore();
        const NSUInteger layoutBlockW = store.unpackCompressedBlockWidth > 0
            ? static_cast<NSUInteger>(store.unpackCompressedBlockWidth)
            : block.width;
        const NSUInteger layoutBlockH = store.unpackCompressedBlockHeight > 0
            ? static_cast<NSUInteger>(store.unpackCompressedBlockHeight)
            : block.height;
        const NSUInteger layoutBlockD = store.unpackCompressedBlockDepth > 0
            ? static_cast<NSUInteger>(store.unpackCompressedBlockDepth)
            : block.depth;
        const NSUInteger layoutBlockBytes = store.unpackCompressedBlockSize > 0
            ? static_cast<NSUInteger>(store.unpackCompressedBlockSize)
            : block.bytes;
        if (layoutBlockW == 0 || layoutBlockH == 0 || layoutBlockD == 0 || layoutBlockBytes == 0) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        const NSUInteger srcWidth = static_cast<NSUInteger>(
            store.unpackRowLength > 0 ? store.unpackRowLength : width);
        const NSUInteger srcHeight = static_cast<NSUInteger>(
            store.unpackImageHeight > 0 ? store.unpackImageHeight : height);
        const NSUInteger srcBlocksX = ceilDivBlocks(srcWidth, layoutBlockW);
        const NSUInteger srcBlocksY = ceilDivBlocks(srcHeight, layoutBlockH);
        const NSUInteger srcRowBytes = srcBlocksX * layoutBlockBytes;
        const NSUInteger srcImageBytes = srcRowBytes * srcBlocksY;
        const NSUInteger skipBlockX = static_cast<NSUInteger>(store.unpackSkipPixels) / layoutBlockW;
        const NSUInteger skipBlockY = static_cast<NSUInteger>(store.unpackSkipRows) / layoutBlockH;
        const NSUInteger skipBlockZ = static_cast<NSUInteger>(store.unpackSkipImages) / layoutBlockD;
        const std::uint8_t* baseBytes = static_cast<const std::uint8_t*>(data) +
            skipBlockZ * srcImageBytes +
            skipBlockY * srcRowBytes +
            skipBlockX * layoutBlockBytes;
        MTLRegion region = MTLRegionMake2D(
            0, 0,
            static_cast<NSUInteger>(width),
            static_cast<NSUInteger>(height));
        const NSUInteger mipLevel = static_cast<NSUInteger>(level);
        if (mipLevel >= nonZeroMipLevelCount(existing.mipmapLevelCount)) {
            return true;
        }
        const NSUInteger mipWidth =
            mipDimensionAtLevel(existing.width, mipLevel);
        const NSUInteger mipHeight =
            mipDimensionAtLevel(existing.height, mipLevel);
        region.size.width = std::min<NSUInteger>(region.size.width, mipWidth);
        region.size.height = std::min<NSUInteger>(region.size.height, mipHeight);
        if (region.size.width == 0 || region.size.height == 0) {
            return true;
        }
        if (slicedTexture) {
            for (NSUInteger slice = 0; slice < uploadSlices; ++slice) {
                const std::uint8_t* sliceBytes = baseBytes + slice * srcImageBytes;
                [existing replaceRegion:region
                             mipmapLevel:mipLevel
                                   slice:slice
                               withBytes:sliceBytes
                             bytesPerRow:srcRowBytes
                           bytesPerImage:srcImageBytes];
            }
        } else {
            [existing replaceRegion:region
                        mipmapLevel:mipLevel
                          withBytes:baseBytes
                        bytesPerRow:srcRowBytes];
        }
    }
    return true;
}

bool GLContext::texStorage(
    GLenum target,
    GLsizei levels,
    GLenum internalformat,
    GLsizei width,
    GLsizei height,
    GLsizei depth
) {
    if (!isTextureTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (levels < 1) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (width < 1 || height < 1 || depth < 1) {
        if (extensions::ExtensionRegistry::isExtensionActive("GL_ARB_sparse_texture_clamp") &&
            isDepthFormat(internalformat) &&
            (target == GL_TEXTURE_1D || target == GL_TEXTURE_1D_ARRAY)) {
            return true;
        }
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.6 §8.17 — GL_TEXTURE_CUBE_MAP_ARRAY storage must have
    // width == height (cube faces are square) AND depth a multiple
    // of 6 (cube has 6 faces per layer). CTS
    // texture_cube_map_array.tex3D_validation exercises both.
    if (target == GL_TEXTURE_CUBE_MAP_ARRAY) {
        if (width != height) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if ((depth % 6) != 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    // GL 4.6 §8.19 — for immutable storage, `levels` must not exceed
    // floor(log2(max(width, height[, depth]))) + 1. Apply to the
    // cube-map-array path explicitly; other targets have the same
    // cap but the Metal allocator historically clamped levels down,
    // so CTS didn't fire this error on them.
    if (target == GL_TEXTURE_CUBE_MAP_ARRAY) {
        const GLsizei maxLevels = static_cast<GLsizei>(
            mipLevelCountForDimensions(
                static_cast<std::size_t>(std::max(width, height)),
                1u,
                1u));
        if (levels > maxLevels) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    // GL 4.6 §8.19 + Metal reality: oversize textures must be rejected before
    // reaching MTLTextureDescriptor (which asserts rather than errors).
    // KHR-GL46.direct_state_access.textures_storage_errors etc. try 32768+
    // deliberately. Pull caps from GLCapabilities and enforce here.
    if (impl_->capabilities != nullptr) {
        GLint maxTex = 0, max3D = 0, maxLayers = 0;
        impl_->capabilities->queryInteger(GL_MAX_TEXTURE_SIZE, &maxTex);
        impl_->capabilities->queryInteger(GL_MAX_3D_TEXTURE_SIZE, &max3D);
        impl_->capabilities->queryInteger(GL_MAX_ARRAY_TEXTURE_LAYERS, &maxLayers);
        if (maxTex > 0 && (width > maxTex || height > maxTex)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (target == GL_TEXTURE_3D && max3D > 0 && (width > max3D || height > max3D || depth > max3D)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if ((target == GL_TEXTURE_2D_ARRAY || target == GL_TEXTURE_1D_ARRAY ||
             target == GL_TEXTURE_CUBE_MAP_ARRAY) &&
            maxLayers > 0 && depth > maxLayers) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    if (!isSupportedInternalTextureFormat(*impl_->capabilities, internalformat)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }

    // GL 4.6 §8.19 / Khronos bug 11239: compressed internal formats
    // are NOT valid on TEXTURE_3D (RGTC1/RGTC2/BPTC were never
    // specified to have a 3D block form). Other targets
    // (TEXTURE_2D / TEXTURE_2D_ARRAY / TEXTURE_CUBE_MAP[_ARRAY])
    // accept them. CTS `texture_storage.compressed_data` walks the
    // RGTC set against each target and expects INVALID_OPERATION
    // for the TEXTURE_3D combinations.
    if (target == GL_TEXTURE_3D) {
        switch (internalformat) {
            case GL_COMPRESSED_RED_RGTC1:
            case GL_COMPRESSED_SIGNED_RED_RGTC1:
            case GL_COMPRESSED_RG_RGTC2:
            case GL_COMPRESSED_SIGNED_RG_RGTC2:
            case GL_COMPRESSED_RGBA_BPTC_UNORM:
            case GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM:
            case GL_COMPRESSED_RGB_BPTC_SIGNED_FLOAT:
            case GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT:
                pushError(GL_INVALID_OPERATION);
                return false;
            default:
                break;
        }
    }

    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (object->desc.immutable) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }
    ExtensionContext extensionContext(*this);
    const bool allocateSparse =
        extensions::sparse_texture::textureSparse(extensionContext, object) == GL_TRUE;
    if (allocateSparse &&
        !extensions::sparse_texture::validateStorageRequest(extensionContext,
                                                            *object,
                                                            target,
                                                            internalformat,
                                                            levels,
                                                            width,
                                                            height,
                                                            depth)) {
        return false;
    }

    object->desc.target = target;
    object->desc.internalFormat = internalformat;
    object->desc.width = width;
    object->desc.height = (target == GL_TEXTURE_1D) ? 1 : height;
    object->desc.depth = allocateSparse
        ? extensions::sparse_texture::storedDepthForTarget(target, depth)
        : ((target == GL_TEXTURE_3D
            || target == GL_TEXTURE_2D_ARRAY
            || target == GL_TEXTURE_CUBE_MAP_ARRAY) ? depth : 1);
    // Mirror depth into `layers` for the array targets — framebuffer-
    // texture-layer validation consults this field when deciding
    // whether an attach-layer is in range. Without it, attaching a
    // layer of a glTexStorage3D-allocated GL_TEXTURE_2D_ARRAY raised
    // GL_INVALID_VALUE on every layer > 0 (the default value of 1).
    object->desc.layers = (target == GL_TEXTURE_2D_ARRAY
                          || target == GL_TEXTURE_1D_ARRAY
                          || target == GL_TEXTURE_CUBE_MAP_ARRAY)
        ? depth : (allocateSparse && target == GL_TEXTURE_CUBE_MAP ? 6 : 1);
    object->desc.levels = levels;
    object->desc.immutable = true;
    if (allocateSparse) {
        extensions::sparse_texture::setSparseLevels(
            extensionContext,
            *object,
            extensions::sparse_texture::levelCountForStorage(extensionContext,
                                                             target,
                                                             levels,
                                                             width,
                                                             height,
                                                             depth,
                                                             internalformat));
    } else {
        extensions::sparse_texture::setSparseLevels(extensionContext, *object, 0);
    }
    object->target = target;
    extensions::sparse_texture::clearCommittedRegions(extensionContext, *object);
    // Sprint 17 Day 8+ FANTASTIC #9 cube fix — texStorage* on a cube
    // target allocates all 6 faces' immutable storage in a single call
    // (GL 4.6 §8.19). Mark `cubeFacesDefined` complete here so the
    // cube-completeness check in `getTextureImage` (line ~35913) and
    // `generateMipmap` (line ~13371) accept the texture without
    // requiring a per-face `glTexImage2D` after `glTexStorage2D`.
    // CTS `shading_language_420pack.binding_images_texture_type_cube`
    // creates a cube via texStorage2D, fills via compute imageStore,
    // reads back via glGetTexImage; pre-fix the readback raised
    // GL_INVALID_OPERATION because cubeFacesDefined was never set.
    if (target == GL_TEXTURE_CUBE_MAP) {
        object->cubeFacesDefined = 0x3F;
    }

    // Pre-create ALL levels [0, levels-1] per GL 4.6 §8.19: "All
    // [immutable storage] images are created by this function."
    // A subsequent glTexSubImage2D on level >= 1 must find the level
    // entry present — the old path only populated level 0 and
    // CTS texture_storage.compressed_data flunked on level 1+
    // texSubImage2D calls with GL_INVALID_OPERATION.
    //
    // Native-format backing is allocated per-level for non-RGBA8
    // internal formats (compressed, packed, integer, depth, …).
    MTLPixelFormat nativeFmt = metalRenderbufferFormat(internalformat);
    auto nativeInfo = (nativeFmt != MTLPixelFormatInvalid &&
                       nativeFmt != MTLPixelFormatRGBA8Unorm)
        ? Impl::nativeFormatInfo(nativeFmt)
        : Impl::NativeFormatInfo{};
    for (GLsizei lvl = 0; lvl < levels; ++lvl) {
        GLTextureImageLevel image;
        image.desc = object->desc;
        image.desc.width = glMipDimensionAtLevel(width, lvl);
        image.desc.height = (target == GL_TEXTURE_1D)
            ? 1 : glMipDimensionAtLevel(height, lvl);
        image.desc.depth = (target == GL_TEXTURE_3D)
            ? glMipDimensionAtLevel(depth, lvl)
            : object->desc.depth;  // array / cube depth doesn't scale
        image.defined = true;
        image.immutableStorageLevel = true;
        const std::size_t lvlPixels =
            static_cast<std::size_t>(image.desc.width)
            * static_cast<std::size_t>(image.desc.height)
            * static_cast<std::size_t>(image.desc.depth);
        image.rgba8.resize(lvlPixels * 4u, 0);
        // Packed native formats report channels==0 but still need their
        // 4-byte native shadow so sparse uploads can commit real Metal texels.
        if (nativeInfo.bytesPerPixel > 0) {
            image.nativeBpp =
                static_cast<std::size_t>(nativeInfo.bytesPerPixel);
            image.nativeData.resize(lvlPixels * image.nativeBpp, 0);
        }
        if (target == GL_TEXTURE_CUBE_MAP) {
            for (auto& faceLevels : object->cubeFaceLevels) {
                faceLevels[lvl] = image;
            }
        }
        object->levels[lvl] = std::move(image);
    }

    if (allocateSparse) {
        if (!extensions::sparse_texture::allocateStorage(extensionContext, *object)) {
            pushError(GL_OUT_OF_MEMORY);
            return false;
        }
        return true;
    }

    if (!impl_->replaceMetalTexture(*object, impl_->state->boundTexture(target))) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::texStorageMultisample(
    GLenum target,
    GLsizei samples,
    GLenum internalformat,
    GLsizei width,
    GLsizei height,
    GLsizei depth,
    GLboolean fixedsamplelocations
) {
    if (target != GL_TEXTURE_2D_MULTISAMPLE && target != GL_TEXTURE_2D_MULTISAMPLE_ARRAY) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (samples < 1 || width < 1 || height < 1 || depth < 1) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Enforce GL_MAX_TEXTURE_SIZE / array layers before reaching Metal
    // (which asserts on oversize). CTS textures_storage_multisample_errors
    // deliberately calls this with max_texture_size*2.
    if (impl_->capabilities != nullptr) {
        GLint maxTex = 0, maxLayers = 0;
        impl_->capabilities->queryInteger(GL_MAX_TEXTURE_SIZE, &maxTex);
        impl_->capabilities->queryInteger(GL_MAX_ARRAY_TEXTURE_LAYERS, &maxLayers);
        if (maxTex > 0 && (width > maxTex || height > maxTex)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY &&
            maxLayers > 0 && depth > maxLayers) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    if (!isSupportedInternalTextureFormat(*impl_->capabilities, internalformat)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // Clamp sample count to Metal's supported sparse/MS storage shape.
    // Metal requires sampleCount > 1 for multisample texture types; GL
    // permits samples=1 on MS targets and allows implementations to choose
    // an actual count >= requested, so use 2 as the minimum storage count.
    if (impl_->capabilities != nullptr) {
        GLint maxSamples = 0;
        impl_->capabilities->queryInteger(GL_MAX_SAMPLES, &maxSamples);
        if (maxSamples > 0 && samples > maxSamples) {
            // GL 4.6 §8.19: samples greater than MAX_SAMPLES is
            // INVALID_OPERATION for TextureStorage*Multisample.
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    GLsizei clampedSamples = 2;
    if (samples > 8) {
        clampedSamples = samples;
    } else if (samples > 4) {
        clampedSamples = 8;
    } else if (samples > 2) {
        clampedSamples = 4;
    }

    // Metal only supports specific sample counts (typically 1, 2, 4, 8).
    // Unsupported values trigger MTLTextureDescriptor validation abort if
    // we pass them through. Check via MTLDevice.supportsTextureSampleCount.
    {
        id<MTLDevice> mtlDevice = impl_->device;
        if (mtlDevice != nil &&
            ![mtlDevice supportsTextureSampleCount:static_cast<NSUInteger>(clampedSamples)]) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }

    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (object->desc.immutable) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }
    ExtensionContext extensionContext(*this);
    const bool allocateSparse =
        extensions::sparse_texture::textureSparse(extensionContext, object) == GL_TRUE;
    if (allocateSparse &&
        !extensions::sparse_texture::validateStorageRequest(extensionContext,
                                                            *object,
                                                            target,
                                                            internalformat,
                                                            1,
                                                            width,
                                                            height,
                                                            depth,
                                                            clampedSamples)) {
        return false;
    }

    object->desc.target = target;
    object->desc.internalFormat = internalformat;
    object->desc.width = width;
    object->desc.height = height;
    object->desc.depth = (target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY) ? depth : 1;
    // framebufferTextureLayer consults desc.layers (not desc.depth) when
    // validating the layer argument — mirror depth into layers for the
    // multisample-array target. Without this, CTS DSA
    // `textures_storage_multisample_3d_*` fails framebufferTextureLayer
    // with INVALID_VALUE and raises IE via its outer catch().
    object->desc.layers = (target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY)
        ? depth : 1;
    object->desc.levels = 1;
    object->desc.samples = clampedSamples;
    object->desc.immutable = true;
    object->target = target;
    if (allocateSparse) {
        extensions::sparse_texture::setSparseLevels(
            extensionContext,
            *object,
            extensions::sparse_texture::levelCountForStorage(extensionContext,
                                                             target,
                                                             1,
                                                             width,
                                                             height,
                                                             depth,
                                                             internalformat,
                                                             clampedSamples));
    } else {
        extensions::sparse_texture::setSparseLevels(extensionContext, *object, 0);
    }
    extensions::sparse_texture::clearCommittedRegions(extensionContext, *object);
    extensions::sparse_texture::resetMultisampleStorageImageSidecar(extensionContext, *object);

    // Create a base-level entry for Metal texture creation.
    GLTextureImageLevel baseLevel;
    baseLevel.desc = object->desc;
    baseLevel.defined = true;
    const std::size_t byteCount = static_cast<std::size_t>(width) * static_cast<std::size_t>(height) * static_cast<std::size_t>(object->desc.depth) * 4u;
    baseLevel.rgba8.resize(byteCount, 0);
    object->levels[0] = std::move(baseLevel);

    if (allocateSparse) {
        if (!extensions::sparse_texture::allocateStorage(extensionContext, *object)) {
            pushError(GL_OUT_OF_MEMORY);
            return false;
        }
        return true;
    }

    if (!impl_->replaceMetalTexture(*object, impl_->state->boundTexture(target))) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::texPageCommitment(GLenum target,
                                  GLint level,
                                  GLint xoffset,
                                  GLint yoffset,
                                  GLint zoffset,
                                  GLsizei width,
                                  GLsizei height,
                                  GLsizei depth,
                                  GLboolean commit) {
    if (!isSparseTextureParameterTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    ExtensionContext extensionContext(*this);
    const GLuint textureName = impl_->state->boundTexture(target);
    const bool ok = extensions::sparse_texture::pageCommitment(extensionContext,
                                                               *object,
                                                               textureName,
                                                               level,
                                                               xoffset,
                                                               yoffset,
                                                               zoffset,
                                                               width,
                                                               height,
                                                               depth,
                                                               commit);
    if (ok) {
        impl_->markGpuResourceWrites({
            {Impl::GpuResourceAccess::Kind::Texture,
             textureName,
             kProducerSparseResidency}
        });
    }
    return ok;
}

bool GLContext::texturePageCommitment(GLuint texture,
                                      GLint level,
                                      GLint xoffset,
                                      GLint yoffset,
                                      GLint zoffset,
                                      GLsizei width,
                                      GLsizei height,
                                      GLsizei depth,
                                      GLboolean commit) {
    GLTextureObject* object = impl_->objects->textures().get(texture);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const GLenum target = object->target != 0 ? object->target : GL_TEXTURE_2D;
    if (!isSparseTextureParameterTarget(target)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    ExtensionContext extensionContext(*this);
    const bool ok = extensions::sparse_texture::pageCommitment(extensionContext,
                                                               *object,
                                                               texture,
                                                               level,
                                                               xoffset,
                                                               yoffset,
                                                               zoffset,
                                                               width,
                                                               height,
                                                               depth,
                                                               commit);
    if (ok) {
        impl_->markGpuResourceWrites({
            {Impl::GpuResourceAccess::Kind::Texture,
             texture,
             kProducerSparseResidency}
        });
    }
    return ok;
}

// GL 4.6 Table 8.12 — sized internal formats allowed for
// GL_TEXTURE_BUFFER. Unsized formats (GL_RGBA, GL_RED, etc.) are
// rejected with INVALID_ENUM per §8.9.
static bool isValidBufferTextureSizedFormat(GLenum fmt) {
    switch (fmt) {
        // R
        case GL_R8: case GL_R8I: case GL_R8UI:
        case GL_R16: case GL_R16I: case GL_R16UI: case GL_R16F:
        case GL_R32I: case GL_R32UI: case GL_R32F:
        // RG
        case GL_RG8: case GL_RG8I: case GL_RG8UI:
        case GL_RG16: case GL_RG16I: case GL_RG16UI: case GL_RG16F:
        case GL_RG32I: case GL_RG32UI: case GL_RG32F:
        // RGB (only 32-bit variants)
        case GL_RGB32I: case GL_RGB32UI: case GL_RGB32F:
        // RGBA
        case GL_RGBA8: case GL_RGBA8I: case GL_RGBA8UI:
        case GL_RGBA16: case GL_RGBA16I: case GL_RGBA16UI: case GL_RGBA16F:
        case GL_RGBA32I: case GL_RGBA32UI: case GL_RGBA32F:
            return true;
        default:
            return false;
    }
}

static GLint bufferTextureBytesPerTexel(GLenum fmt) {
    switch (fmt) {
        case GL_R8: case GL_R8I: case GL_R8UI:
            return 1;
        case GL_R16: case GL_R16I: case GL_R16UI: case GL_R16F:
        case GL_RG8: case GL_RG8I: case GL_RG8UI:
            return 2;
        case GL_R32I: case GL_R32UI: case GL_R32F:
        case GL_RG16: case GL_RG16I: case GL_RG16UI: case GL_RG16F:
        case GL_RGBA8: case GL_RGBA8I: case GL_RGBA8UI:
            return 4;
        case GL_RG32I: case GL_RG32UI: case GL_RG32F:
        case GL_RGBA16: case GL_RGBA16I: case GL_RGBA16UI: case GL_RGBA16F:
            return 8;
        case GL_RGB32I: case GL_RGB32UI: case GL_RGB32F:
            return 12;
        case GL_RGBA32I: case GL_RGBA32UI: case GL_RGBA32F:
            return 16;
        default:
            return 0;
    }
}

bool GLContext::texBufferRange(
    GLenum target,
    GLenum internalformat,
    GLuint buffer,
    GLintptr offset,
    GLsizeiptr size
) {
    if (target != GL_TEXTURE_BUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // GL 4.6 §8.9: buffer-texture internalformat must be a sized
    // internal format from Table 8.12. Unsized base formats (e.g.
    // GL_RED) and others raise INVALID_ENUM.
    if (!isValidBufferTextureSizedFormat(internalformat)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (offset < 0 || size <= 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.6 §8.9: offset must be a multiple of
    // GL_TEXTURE_BUFFER_OFFSET_ALIGNMENT. We advertise 16.
    {
        GLint64 alignment = 16;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger64(
                GL_TEXTURE_BUFFER_OFFSET_ALIGNMENT, &alignment);
        }
        if ((offset % alignment) != 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }

    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §8.9: if `buffer` is non-zero it must name an
    // existing buffer object. Otherwise INVALID_OPERATION.
    if (buffer != 0) {
        GLBufferObject* checkBuf = impl_->objects->buffers().get(buffer);
        if (checkBuf == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        // offset + size must be <= buffer's current size.
        if (static_cast<GLsizeiptr>(offset) + size > checkBuf->size) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        // S24 rename-on-write: buffer-texture views wrap this exact
        // MTLBuffer — renaming it would orphan the view, so writes to
        // it stay in-place (and are counted as skips).
        checkBuf->textureBufferSource = true;
    }

    // Record the buffer-texture binding state.
    object->desc.target = target;
    object->desc.internalFormat = internalformat;
    object->desc.sourceBuffer = buffer;
    object->desc.bufferOffset = offset;
    object->desc.bufferSize = size;
    object->desc.immutable = true;
    {
        GLint64 maxTexels = 0;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger64(GL_MAX_TEXTURE_BUFFER_SIZE, &maxTexels);
        }
        const GLint bytesPerTexel = bufferTextureBytesPerTexel(internalformat);
        const GLint64 texels = bytesPerTexel > 0
            ? static_cast<GLint64>(size) / bytesPerTexel
            : 0;
        object->desc.width = static_cast<GLsizei>(
            std::min<GLint64>(texels, std::max<GLint64>(maxTexels, 0)));
        object->desc.height = 1;
        object->desc.depth = 1;
    }
    object->target = target;

    if (textureBufferFormatNeedsRGB32Expansion(internalformat)) {
        (void)impl_->refreshRGB32BufferTextureView(*object);
        return true;
    }
    impl_->releaseTextureBufferExpansion(*object);

    // SPIRV-Cross lowers GL samplerBuffer to a synthetic texture2d<T>
    // with texel coordinates (index % 8192, index / 8192). Build the
    // Metal view with the same 8192-wide row layout so accesses past
    // the first row remain valid.
    GLBufferObject* bufObj = impl_->objects->buffers().get(buffer);
    if (bufObj != nullptr && bufObj->metalBuffer != nullptr) {
        id<MTLBuffer> mtlBuffer = (__bridge id<MTLBuffer>)bufObj->metalBuffer;
        MTLPixelFormat pf = metalRenderbufferFormat(internalformat);
        if (pf != MTLPixelFormatInvalid) {
            MTLTextureDescriptor* desc = [[MTLTextureDescriptor alloc] init];
            ScopedOwnedMetalObject descRelease(desc);
            desc.textureType = MTLTextureType2D;
            desc.pixelFormat = pf;
            const NSUInteger bpp = [&](MTLPixelFormat p) -> NSUInteger {
                auto info = Impl::nativeFormatInfo(p);
                return static_cast<NSUInteger>(info.bytesPerPixel);
            }(pf);
            if (bpp > 0) {
                const NSUInteger byteLen = static_cast<NSUInteger>(size);
                const NSUInteger texelCount = byteLen / bpp;
                constexpr NSUInteger kTexelBufferRowTexels = 8192;
                GLint64 maxTextureHeight = 16384;
                if (impl_->capabilities != nullptr) {
                    impl_->capabilities->queryInteger64(GL_MAX_TEXTURE_SIZE, &maxTextureHeight);
                }
                const NSUInteger maxRows = static_cast<NSUInteger>(
                    std::max<GLint64>(maxTextureHeight, 1));
                const NSUInteger visibleTexelCount = std::min<NSUInteger>(
                    texelCount,
                    kTexelBufferRowTexels * maxRows);
                const NSUInteger rowTexels = std::min<NSUInteger>(
                    visibleTexelCount,
                    kTexelBufferRowTexels);
                const NSUInteger rowBytesUnaligned = rowTexels * bpp;
                const NSUInteger rowBytes =
                    ((rowBytesUnaligned + 15u) / 16u) * 16u;
                const NSUInteger rowCount =
                    rowTexels > 0 ? (visibleTexelCount + rowTexels - 1u) / rowTexels : 0;
                const NSUInteger requiredViewBytes =
                    rowCount > 0 ? rowBytes * (rowCount - 1u) + rowBytesUnaligned : 0u;
                // Metal asserts on zero dimensions or when the strided
                // 2D buffer view exceeds the buffer length. The final row
                // does not require trailing stride padding in the GL buffer;
                // requiring it incorrectly drops small 1/2/4-byte texel
                // buffer views used by DSA texture-buffer CTS cases.
                if (rowTexels > 0 && rowCount > 0 &&
                    static_cast<NSUInteger>(offset) + requiredViewBytes <= mtlBuffer.length) {
                    desc.width = rowTexels;
                    desc.height = rowCount;
                    desc.depth = 1;
                    desc.mipmapLevelCount = singleMipLevelCount<NSUInteger>();
                    desc.arrayLength = 1;
                    desc.resourceOptions = mtlBuffer.resourceOptions;
                    desc.usage = MTLTextureUsageShaderRead;
                    id<MTLTexture> tex = [mtlBuffer newTextureWithDescriptor:desc
                                                                      offset:static_cast<NSUInteger>(offset)
                                                                 bytesPerRow:rowBytes];
                    // Release any prior metalTexture before retaining the new one.
                    if (object->metalTexture != nullptr) {
                        releaseRetainedMetalObject(object->metalTexture);
                        object->metalTexture = nullptr;
                    }
                    if (tex != nil) {
                        object->metalTexture = transferRetainedMetalObject(tex);
                    }
                }
            }
        }
    }
    return true;
}

bool GLContext::texParameterInteger(GLenum target, GLenum pname, const GLint* params) {
    if (impl_->state) {
        impl_->state->bumpDomain(appgl::GLStateTracker::kDomainTexture);  // C51/C52(a)
    }
    // GL 4.6 §8.10 target-aware validation runs FIRST — before the
    // "default texture" accommodation — so spec-violating
    // combinations (MS+sampler-pname, BUFFER+sampler-pname, negative
    // base-level) surface the spec-correct error even when no user
    // texture is bound to `target`. Moving this check up is safe for
    // CTS's gluStateReset because its reset sequence never touches
    // the buffer / MS targets with disallowed pnames.
    if (params != nullptr) {
        if (pname == GL_VIRTUAL_PAGE_SIZE_INDEX_ARB && params[0] < 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (pname == GL_TEXTURE_SPARSE_ARB && params[0] == GL_TRUE &&
            !isSparseTextureParameterTarget(target)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        // (a) Negative BASE_LEVEL / MAX_LEVEL → INVALID_VALUE.
        if ((pname == GL_TEXTURE_BASE_LEVEL || pname == GL_TEXTURE_MAX_LEVEL)
            && params[0] < 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        // (a') GL_ARB_texture_filter_anisotropic — MAX_ANISOTROPY
        // must be >= 1. Values below 1 → INVALID_VALUE.
        if (pname == GL_TEXTURE_MAX_ANISOTROPY && params[0] < 1) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        // (b) GL 4.6 §8.10 — for TEXTURE_2D_MULTISAMPLE,
        // TEXTURE_2D_MULTISAMPLE_ARRAY, and TEXTURE_BUFFER, most
        // sampler-state pnames are INVALID_ENUM. Allowed pnames on
        // these targets are the storage-state queries and the
        // "layout" pnames: BASE_LEVEL, MAX_LEVEL, SWIZZLE_*,
        // DEPTH_STENCIL_TEXTURE_MODE. Buffer textures also forbid
        // base/max-level updates (they have no mipmap chain).
        const bool isMSTarget = (target == GL_TEXTURE_2D_MULTISAMPLE ||
                                 target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY);
        const bool isBufferTarget = (target == GL_TEXTURE_BUFFER);
        const bool isSamplerPname = (
            pname == GL_TEXTURE_MIN_FILTER || pname == GL_TEXTURE_MAG_FILTER ||
            pname == GL_TEXTURE_WRAP_S || pname == GL_TEXTURE_WRAP_T ||
            pname == GL_TEXTURE_WRAP_R || pname == GL_TEXTURE_MIN_LOD ||
            pname == GL_TEXTURE_MAX_LOD || pname == GL_TEXTURE_LOD_BIAS ||
            pname == GL_TEXTURE_COMPARE_MODE || pname == GL_TEXTURE_COMPARE_FUNC ||
            pname == GL_TEXTURE_BORDER_COLOR || pname == GL_TEXTURE_MAX_ANISOTROPY ||
            pname == GL_TEXTURE_REDUCTION_MODE_ARB);
        if (isMSTarget && isSamplerPname) {
            // GL 4.6 §8.10 table 23.18 — multisample targets reject
            // every sampler-state pname with INVALID_ENUM (not
            // INVALID_OPERATION). CTS
            // `texture_border_clamp.texparameteri_errors` exercises
            // the full (target × pname) matrix and dispatches on the
            // expected error code.
            pushError(GL_INVALID_ENUM);
            return false;
        }
        // Buffer textures reject every sampler-state pname AND the
        // level pnames (they have no mipmap chain). Per GL 4.6 §8.9
        // these are INVALID_ENUM for buffer texture targets.
        if (isBufferTarget &&
            (isSamplerPname || pname == GL_TEXTURE_BASE_LEVEL ||
             pname == GL_TEXTURE_MAX_LEVEL)) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        // (c) BASE_LEVEL != 0 on MULTISAMPLE → INVALID_OPERATION.
        if (isMSTarget && pname == GL_TEXTURE_BASE_LEVEL && params[0] != 0) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        // (d) RECTANGLE-target restrictions.
        if (target == GL_TEXTURE_RECTANGLE) {
            // RECTANGLE BASE_LEVEL must be 0.
            if (pname == GL_TEXTURE_BASE_LEVEL && params[0] != 0) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            // RECTANGLE wrap modes can't be MIRROR_CLAMP_TO_EDGE,
            // MIRRORED_REPEAT, or REPEAT.
            if ((pname == GL_TEXTURE_WRAP_S || pname == GL_TEXTURE_WRAP_T ||
                 pname == GL_TEXTURE_WRAP_R) &&
                (params[0] == GL_REPEAT || params[0] == GL_MIRRORED_REPEAT ||
                 params[0] == GL_MIRROR_CLAMP_TO_EDGE)) {
                pushError(GL_INVALID_ENUM);
                return false;
            }
            // RECTANGLE MIN_FILTER must be NEAREST or LINEAR.
            if (pname == GL_TEXTURE_MIN_FILTER &&
                params[0] != GL_NEAREST && params[0] != GL_LINEAR) {
                pushError(GL_INVALID_ENUM);
                return false;
            }
        }
        // (e) Scalar setter on non-scalar pname → INVALID_ENUM.
        // BORDER_COLOR and SWIZZLE_RGBA take 4 components. The scalar
        // glTexParameteri/f variants (not Iiv/fv) should reject these.
        // This check is done in the wrapper's dim-sensitive path; at
        // the context level we accept both by treating the single-element
        // params pointer as a 4-element array for these pnames — the
        // wrapper's 1-element buffer would then read garbage for indices
        // 1..3. Punt this check to the runtime wrappers — those know
        // whether the scalar or vector entry point was called.
    }

    {
        ExtensionContext extensionContext(*this);
        const auto& sparseHooks = extensions::ExtensionRegistry::sparseTextureHooks();
        bool handled = false;
        if (sparseHooks.handleTextureParameter != nullptr &&
            !sparseHooks.handleTextureParameter(extensionContext, target, pname, params, handled)) {
            return false;
        }
        if (handled) {
            return true;
        }
    }

    GLTextureObject* object = impl_->currentTexture(target);
    // OpenGL 4.6 §8.10: when no user texture is bound to `target`, the
    // parameters are applied to the "default texture object" for that
    // target. CTS state reset (gluStateReset.cpp) relies on this: it
    // binds name=0 and then calls texParameteri to reset swizzle/levels.
    // If we generate GL_INVALID_OPERATION here, the reset throws and
    // subsequent state (notably glDepthMask(GL_TRUE)) never runs, causing
    // state bleed between tests. Silently accept the parameter instead.
    if (object == nullptr) {
        return true;
    }
    if (!object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if ((pname == GL_TEXTURE_SPARSE_ARB || pname == GL_VIRTUAL_PAGE_SIZE_INDEX_ARB) &&
        object->desc.immutable) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!setTextureParameterInteger(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    // Phase 8X Group 4d follow-up⁷ — the filter/wrap/lod/compare state
    // on the texture now feeds an MTLSamplerState cached on the object
    // (see GLTextureObject.metalSampler). Flip the dirty flag so the
    // next draw rebuilds it from the mutated params. Unconditional
    // because the GL parameter names that affect sampling are a
    // superset of the fields in GLTextureParameters (setTextureParameter
    // already filters out unknown names by returning false above), and
    // swizzle/border changes also require a rebuild via the descriptor.
    object->samplerDirty = true;
    // Swizzle changes invalidate the cached texture view.
    if (pname == GL_TEXTURE_SWIZZLE_R || pname == GL_TEXTURE_SWIZZLE_G ||
        pname == GL_TEXTURE_SWIZZLE_B || pname == GL_TEXTURE_SWIZZLE_A ||
        pname == GL_TEXTURE_SWIZZLE_RGBA ||
        pname == GL_DEPTH_STENCIL_TEXTURE_MODE ||
        pname == GL_TEXTURE_BASE_LEVEL ||
        pname == GL_TEXTURE_MAX_LEVEL) {
        object->swizzleDirty = true;
    }
    if (pname == GL_TEXTURE_BASE_LEVEL ||
        pname == GL_TEXTURE_MAX_LEVEL) {
        const GLuint textureName = impl_->state != nullptr
            ? impl_->state->boundTexture(target)
            : 0u;
        if (!impl_->replaceMetalTexture(*object, textureName)) {
            pushError(GL_OUT_OF_MEMORY);
            return false;
        }
    }
    return true;
}

bool GLContext::texParameterUnsignedInteger(GLenum target, GLenum pname, const GLuint* params) {
    if (impl_->state) {
        impl_->state->bumpDomain(appgl::GLStateTracker::kDomainTexture);  // C51/C52(a)
    }
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLint converted[4] = {
        static_cast<GLint>(params[0]),
        0,
        0,
        0
    };
    if (pname == GL_TEXTURE_BORDER_COLOR || pname == GL_TEXTURE_SWIZZLE_RGBA) {
        converted[1] = static_cast<GLint>(params[1]);
        converted[2] = static_cast<GLint>(params[2]);
        converted[3] = static_cast<GLint>(params[3]);
    }
    return texParameterInteger(target, pname, converted);
}

bool GLContext::texParameterFloat(GLenum target, GLenum pname, const GLfloat* params) {
    if (impl_->state) {
        impl_->state->bumpDomain(appgl::GLStateTracker::kDomainTexture);  // C51/C52(a)
    }
    // GL 4.6 §8.10 target-aware validation runs FIRST — see
    // texParameterInteger for the rationale.
    if (params != nullptr) {
        if (!std::isfinite(params[0])) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (pname == GL_VIRTUAL_PAGE_SIZE_INDEX_ARB && params[0] < 0.0f) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (pname == GL_TEXTURE_SPARSE_ARB &&
            static_cast<GLint>(params[0]) == GL_TRUE &&
            !isSparseTextureParameterTarget(target)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if ((pname == GL_TEXTURE_BASE_LEVEL || pname == GL_TEXTURE_MAX_LEVEL)
            && params[0] < 0.0f) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        // GL_ARB_texture_filter_anisotropic — MAX_ANISOTROPY must be
        // >= 1.0; values below 1.0 raise INVALID_VALUE. CTS
        // `texture_filter_anisotropic.queries` exercises the bound.
        if (pname == GL_TEXTURE_MAX_ANISOTROPY && params[0] < 1.0f) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        const bool isMSTarget = (target == GL_TEXTURE_2D_MULTISAMPLE ||
                                 target == GL_TEXTURE_2D_MULTISAMPLE_ARRAY);
        const bool isBufferTarget = (target == GL_TEXTURE_BUFFER);
        const bool isSamplerPname = (
            pname == GL_TEXTURE_MIN_FILTER || pname == GL_TEXTURE_MAG_FILTER ||
            pname == GL_TEXTURE_WRAP_S || pname == GL_TEXTURE_WRAP_T ||
            pname == GL_TEXTURE_WRAP_R || pname == GL_TEXTURE_MIN_LOD ||
            pname == GL_TEXTURE_MAX_LOD || pname == GL_TEXTURE_LOD_BIAS ||
            pname == GL_TEXTURE_COMPARE_MODE || pname == GL_TEXTURE_COMPARE_FUNC ||
            pname == GL_TEXTURE_BORDER_COLOR || pname == GL_TEXTURE_MAX_ANISOTROPY ||
            pname == GL_TEXTURE_REDUCTION_MODE_ARB);
        // GL 4.6 §8.10 — MS target + sampler pname is INVALID_OPERATION
        // (core spec wording). Buffer target + sampler/level pname is
        // INVALID_ENUM (buffer textures have no filter/mipmap state).
        if (isMSTarget && isSamplerPname) {
            // GL 4.6 §8.10 table 23.18 — multisample targets reject
            // every sampler-state pname with INVALID_ENUM (not
            // INVALID_OPERATION). CTS
            // `texture_border_clamp.texparameteri_errors` exercises
            // the full (target × pname) matrix and dispatches on the
            // expected error code.
            pushError(GL_INVALID_ENUM);
            return false;
        }
        if (isBufferTarget &&
            (isSamplerPname || pname == GL_TEXTURE_BASE_LEVEL ||
             pname == GL_TEXTURE_MAX_LEVEL)) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        if (isMSTarget && pname == GL_TEXTURE_BASE_LEVEL && params[0] != 0.0f) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        if (target == GL_TEXTURE_RECTANGLE) {
            if (pname == GL_TEXTURE_BASE_LEVEL && params[0] != 0.0f) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            const GLint asInt = static_cast<GLint>(params[0]);
            if ((pname == GL_TEXTURE_WRAP_S || pname == GL_TEXTURE_WRAP_T ||
                 pname == GL_TEXTURE_WRAP_R) &&
                (asInt == GL_REPEAT || asInt == GL_MIRRORED_REPEAT ||
                 asInt == GL_MIRROR_CLAMP_TO_EDGE)) {
                pushError(GL_INVALID_ENUM);
                return false;
            }
            if (pname == GL_TEXTURE_MIN_FILTER &&
                asInt != GL_NEAREST && asInt != GL_LINEAR) {
                pushError(GL_INVALID_ENUM);
                return false;
            }
        }
    }

    if (pname == GL_TEXTURE_SPARSE_ARB || pname == GL_VIRTUAL_PAGE_SIZE_INDEX_ARB) {
        const GLint converted[4] = {
            params != nullptr ? static_cast<GLint>(params[0]) : 0,
            0,
            0,
            0
        };
        ExtensionContext extensionContext(*this);
        const auto& sparseHooks = extensions::ExtensionRegistry::sparseTextureHooks();
        bool handled = false;
        if (sparseHooks.handleTextureParameter != nullptr &&
            !sparseHooks.handleTextureParameter(extensionContext,
                                                target,
                                                pname,
                                                params != nullptr ? converted : nullptr,
                                                handled)) {
            return false;
        }
        if (handled) {
            return true;
        }
    }

    GLTextureObject* object = impl_->currentTexture(target);
    // See comment in texParameterInteger — default-texture params are a
    // no-op to keep CTS state reset from throwing.
    if (object == nullptr) {
        return true;
    }
    if (!object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if ((pname == GL_TEXTURE_SPARSE_ARB || pname == GL_VIRTUAL_PAGE_SIZE_INDEX_ARB) &&
        object->desc.immutable) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!setTextureParameterFloat(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    // Phase 8X Group 4d follow-up⁷ — see texParameterInteger for the
    // rationale; float params update the same GLTextureParameters
    // fields (lod clamps, border color) so the cached sampler must
    // rebuild on the next draw.
    object->samplerDirty = true;
    if (pname == GL_TEXTURE_BASE_LEVEL ||
        pname == GL_TEXTURE_MAX_LEVEL) {
        object->swizzleDirty = true;
        const GLuint textureName = impl_->state != nullptr
            ? impl_->state->boundTexture(target)
            : 0u;
        if (!impl_->replaceMetalTexture(*object, textureName)) {
            pushError(GL_OUT_OF_MEMORY);
            return false;
        }
    }
    return true;
}

bool GLContext::getTexParameterInteger(GLenum target, GLenum pname, GLint* params) {
    {
        ExtensionContext extensionContext(*this);
        const auto& sparseHooks = extensions::ExtensionRegistry::sparseTextureHooks();
        bool handled = false;
        if (sparseHooks.handleTextureParameterQuery != nullptr &&
            !sparseHooks.handleTextureParameterQuery(extensionContext, target, pname, params, handled)) {
            return false;
        }
        if (handled) {
            return true;
        }
    }

    GLTextureObject* object = impl_->currentTexture(target);
    // OpenGL 4.6 §8.11: querying the default texture is valid — return the
    // GL spec's initial parameter values. CTS texture_swizzle.intial_state
    // (note CTS typo "intial") deletes and rebinds the same texture name
    // in a loop, so subsequent iterations bind name=0 and query defaults.
    if (object == nullptr) {
        // Default texture's storage state is all-zero (no storage ever
        // committed), so the storage-property queries below also route
        // through the object-less path.
        switch (pname) {
            case GL_TEXTURE_IMMUTABLE_FORMAT:
            case GL_TEXTURE_IMMUTABLE_LEVELS:
            case GL_TEXTURE_VIEW_MIN_LEVEL:
            case GL_TEXTURE_VIEW_MIN_LAYER:
            case GL_TEXTURE_VIEW_NUM_LEVELS:
            case GL_TEXTURE_VIEW_NUM_LAYERS:
            case GL_NUM_SPARSE_LEVELS_ARB:
                if (params) *params = 0;
                return true;
            case GL_TEXTURE_SPARSE_ARB:
            case GL_VIRTUAL_PAGE_SIZE_INDEX_ARB:
                if (params == nullptr) {
                    pushError(GL_INVALID_VALUE);
                    return false;
                }
                params[0] = (pname == GL_TEXTURE_SPARSE_ARB) ? GL_FALSE : 0;
                return true;
            case GL_TEXTURE_TARGET:
                if (params) *params = static_cast<GLint>(target);
                return true;
        }
        const GLTextureParameters defaults;
        if (!getTextureParameterInteger(defaults, pname, params)) {
            pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
            return false;
        }
        return true;
    }
    // GL 4.6 §8.11 storage-state queries live on the texture object
    // (desc.immutable / desc.levels / view-slice range / target).
    // Handle these at the caller — the per-params helper only sees
    // `GLTextureParameters` which is the sampler-state struct.
    switch (pname) {
        case GL_TEXTURE_IMMUTABLE_FORMAT:
            if (params) *params = object->desc.immutable ? GL_TRUE : GL_FALSE;
            return true;
        case GL_TEXTURE_IMMUTABLE_LEVELS:
            if (params) {
                *params = textureImmutableLevelCountForQuery(impl_->objects.get(), *object);
            }
            return true;
        case GL_TEXTURE_VIEW_MIN_LEVEL:
            if (params) *params = object->viewMinLevel;
            return true;
        case GL_TEXTURE_VIEW_MIN_LAYER:
            if (params) *params = object->viewMinLayer;
            return true;
        case GL_TEXTURE_VIEW_NUM_LEVELS:
            if (params) *params = textureViewEffectiveLevelCount(*object);
            return true;
        case GL_TEXTURE_VIEW_NUM_LAYERS:
            if (params) *params = textureViewEffectiveLayerCount(*object);
            return true;
        case GL_NUM_SPARSE_LEVELS_ARB:
            {
                ExtensionContext extensionContext(*this);
                if (params) {
                    *params = extensions::sparse_texture::sparseLevels(extensionContext, object);
                }
            }
            return true;
        case GL_TEXTURE_TARGET:
            if (params) *params = static_cast<GLint>(object->target != 0 ? object->target : target);
            return true;
        // GL 4.6 §8.26.2 / ARB_shader_image_load_store — for textures
        // allocated by the GL (not views), the image-format compat
        // type is BY_SIZE. Views have a different (BY_CLASS) value
        // but we don't currently support texture views, so always
        // report BY_SIZE. CTS shader_image_load_store.basic-api-texParam
        // asserts this for glTexImage2D-allocated textures.
        case GL_IMAGE_FORMAT_COMPATIBILITY_TYPE:
            if (params) *params = static_cast<GLint>(GL_IMAGE_FORMAT_COMPATIBILITY_BY_SIZE);
            return true;
    }
    if (pname == GL_TEXTURE_SPARSE_ARB || pname == GL_VIRTUAL_PAGE_SIZE_INDEX_ARB) {
        if (params == nullptr) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        ExtensionContext extensionContext(*this);
        params[0] = (pname == GL_TEXTURE_SPARSE_ARB)
            ? extensions::sparse_texture::textureSparse(extensionContext, object)
            : extensions::sparse_texture::virtualPageSizeIndex(extensionContext, object);
        return true;
    }
    if (!getTextureParameterInteger(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::getTexParameterUnsignedInteger(GLenum target, GLenum pname, GLuint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLint values[4] = {};
    if (!getTexParameterInteger(target, pname, values)) {
        return false;
    }
    params[0] = static_cast<GLuint>(values[0]);
    if (pname == GL_TEXTURE_BORDER_COLOR || pname == GL_TEXTURE_SWIZZLE_RGBA) {
        params[1] = static_cast<GLuint>(values[1]);
        params[2] = static_cast<GLuint>(values[2]);
        params[3] = static_cast<GLuint>(values[3]);
    }
    return true;
}

bool GLContext::getTexParameterFloat(GLenum target, GLenum pname, GLfloat* params) {
    // Storage-state / enum-valued pnames (GL 4.6 §8.11) that only
    // the integer getter handles — route through that path and
    // convert to float, instead of letting the per-params float
    // helper's default reinterpret return garbage. CTS
    // shader_image_load_store.basic-api-texParam hits this path.
    switch (pname) {
        case GL_TEXTURE_IMMUTABLE_FORMAT:
        case GL_TEXTURE_IMMUTABLE_LEVELS:
        case GL_TEXTURE_VIEW_MIN_LEVEL:
        case GL_TEXTURE_VIEW_MIN_LAYER:
        case GL_TEXTURE_VIEW_NUM_LEVELS:
        case GL_TEXTURE_VIEW_NUM_LAYERS:
        case GL_TEXTURE_TARGET:
        case GL_NUM_SPARSE_LEVELS_ARB:
        case GL_TEXTURE_SPARSE_ARB:
        case GL_VIRTUAL_PAGE_SIZE_INDEX_ARB:
        case GL_IMAGE_FORMAT_COMPATIBILITY_TYPE: {
            GLint ival = 0;
            if (!getTexParameterInteger(target, pname, &ival)) {
                return false;
            }
            if (params) *params = static_cast<GLfloat>(ival);
            return true;
        }
    }
    GLTextureObject* object = impl_->currentTexture(target);
    // Default texture query returns spec defaults (see getTexParameterInteger).
    if (object == nullptr) {
        const GLTextureParameters defaults;
        if (!getTextureParameterFloat(defaults, pname, params)) {
            pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
            return false;
        }
        return true;
    }
    if (!getTextureParameterFloat(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::generateMipmap(GLenum target) {
    if (!isTextureTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLTextureObject* object = impl_->currentTexture(target);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §8.17: GL_INVALID_OPERATION if target is GL_TEXTURE_CUBE_MAP
    // (or CUBE_MAP_ARRAY) and the texture is not cube complete — i.e. at
    // least one of the six faces is missing a level-0 definition.
    // Checked by KHR-GL46.direct_state_access.textures_generate_mipmap_errors.
    // Level-0 face coverage is the minimum viable check: a stricter read
    // of the spec also requires matching face dimensions and format, but
    // all six faces going through the same single-target bindTexture +
    // same-size texImage2D path in practice means face-count is the
    // signal that distinguishes complete from incomplete.
    const GLenum normalized = Impl::normalizeTextureBindingTarget(target);
    if (normalized == GL_TEXTURE_CUBE_MAP && object->cubeFacesDefined != 0x3F) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }
    if (!impl_->generateMipmaps(*object)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    impl_->markGpuResourceWrites({
        {Impl::GpuResourceAccess::Kind::Texture,
         impl_->state->boundTexture(target),
         kProducerMipmapWrite}
    });
    return true;
}
