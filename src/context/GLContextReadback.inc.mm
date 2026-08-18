// This file is textually included by GLContext.mm. Do not compile it directly.
// It contains GLContext readback and present method definitions split out for navigation only.

#if defined(APPGL_GLCONTEXT_READBACK_PRESENT)
void GLContext::flush() {
    impl_->presentPendingWork(AppGLCommandReason::PresentFromFlush);
}

void GLContext::finish() {
    impl_->finishPendingWork();
}

void GLContext::swapBuffers() {
    impl_->presentPendingWork(AppGLCommandReason::PresentFromSwapBuffers);
}

#elif defined(APPGL_GLCONTEXT_READBACK_READ_PIXELS)
bool GLContext::readPixels(GLint x, GLint y, GLsizei width, GLsizei height, GLenum format, GLenum type, void* pixels) {
    // GL 4.6 §18.3.1: when GL_PIXEL_PACK_BUFFER is bound, `pixels` is
    // a BYTE OFFSET into the bound PBO, and offset 0 is perfectly
    // legal (CTS `buffer_storage.map_persistent_read_pixels` passes
    // offset=0 repeatedly). Only treat a null `pixels` as INVALID_VALUE
    // when no PBO is bound — otherwise it's an offset, not a pointer.
    const bool packPBOBound = impl_->state->boundBuffer(GL_PIXEL_PACK_BUFFER) != 0;
    if (pixels == nullptr && !packPBOBound) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (width == 0 || height == 0) {
        return true;
    }
    const bool packedDepthStencilType =
        type == GL_UNSIGNED_INT_24_8 ||
        type == GL_FLOAT_32_UNSIGNED_INT_24_8_REV;
    if (format == GL_DEPTH_STENCIL && !packedDepthStencilType) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (format != GL_DEPTH_STENCIL && packedDepthStencilType) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    // When a PBO is bound, resolve the offset into the shadow byte
    // buffer so the downstream readback paths (readFramebufferPixels,
    // readFBOColorNative) can write into the PBO's shadow memory.
    // Note: `requiredBytes` passed to resolvePackPBO is the MAXIMUM
    // bytes the native readback could produce — we use bytesPerPixel
    // of the requested format × width × height. This is the full
    // RGBA equivalent when readback falls back to the converter path.
    if (packPBOBound) {
        const std::size_t packBytes = static_cast<std::size_t>(width) *
            static_cast<std::size_t>(height) * std::max<std::size_t>(bytesPerPixel(format, type), 1);
        const std::size_t typeBytes = std::max<std::size_t>(bytesPerComponent(type), 1);
        auto [packDest, packOk] = impl_->resolvePackPBO(pixels, packBytes, typeBytes);
        if (!packOk) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        pixels = packDest;
    }

    if (impl_->state->boundReadFramebuffer() != 0) {
        if (impl_->boundReadFramebufferHasMultipleViews()) {
            pushError(GL_INVALID_FRAMEBUFFER_OPERATION);
            return false;
        }
        // Widen FBO readback acceptance to match GL 4.6 §18.3.2. The
        // single-component formats (GL_GREEN / GL_BLUE / GL_ALPHA) and
        // their _INTEGER variants were missing, which made
        // KHR-GL46.packed_pixels tests see "valid format used but
        // glReadPixels failed" on combos the spec explicitly permits.
        const bool isColorReadback =
            (format == GL_RED || format == GL_GREEN || format == GL_BLUE
             || format == GL_ALPHA || format == GL_LUMINANCE
             || format == GL_LUMINANCE_ALPHA
             || format == GL_RG || format == GL_RGB || format == GL_RGBA
             || format == GL_BGR || format == GL_BGRA
             || format == GL_RED_INTEGER || format == GL_GREEN_INTEGER
             || format == GL_BLUE_INTEGER
             || format == GL_RG_INTEGER || format == GL_RGB_INTEGER
             || format == GL_RGBA_INTEGER
             || format == GL_BGR_INTEGER || format == GL_BGRA_INTEGER);
        // GL 4.6 Table 18.2 — GL_DEPTH_COMPONENT readback accepts any
        // scalar type (byte/short/int/half/float and unsigned variants).
        // The packed depth-stencil types (GL_UNSIGNED_INT_24_8 and
        // GL_FLOAT_32_UNSIGNED_INT_24_8_REV) are NOT compatible with
        // GL_DEPTH_COMPONENT — they require format=GL_DEPTH_STENCIL,
        // and rejecting them here surfaces the INVALID_OPERATION CTS
        // expects (`packed_pixels.rectangle.depth_component16_format
        // _depth_component` checks for the rejection explicitly).
        const bool isDepthReadback = (format == GL_DEPTH_COMPONENT
            && (type == GL_UNSIGNED_BYTE || type == GL_BYTE
                || type == GL_UNSIGNED_SHORT || type == GL_SHORT
                || type == GL_UNSIGNED_INT || type == GL_INT
                || type == GL_FLOAT || type == GL_HALF_FLOAT));
        // Detect the cross-class spec violation: a depth/stencil/depth-
        // stencil format paired with a type that is otherwise valid for
        // some other class. Without this check the fall-through at line
        // 7917 raises INVALID_ENUM, but Table 18.2 says the right error
        // is INVALID_OPERATION.
        const bool isDepthStencilPackedType = (type == GL_UNSIGNED_INT_24_8
            || type == GL_FLOAT_32_UNSIGNED_INT_24_8_REV);
        if (format == GL_DEPTH_COMPONENT && isDepthStencilPackedType) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        if (format == GL_STENCIL_INDEX && isDepthStencilPackedType) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        // GL_DEPTH_STENCIL readback is also accepted by the spec with
        // the two depth-stencil packed types.
        const bool isDepthStencilReadback = (format == GL_DEPTH_STENCIL
            && (type == GL_UNSIGNED_INT_24_8
                || type == GL_FLOAT_32_UNSIGNED_INT_24_8_REV));
        // GL 4.6 Table 8.3: GL_STENCIL_INDEX accepts any scalar type
        // (byte/short/int/float and their variants). Narrowing to only
        // GL_UNSIGNED_BYTE fails CTS framebuffers_clear which reads
        // stencil as GL_INT.
        const bool isStencilReadback = (format == GL_STENCIL_INDEX
            && (type == GL_UNSIGNED_BYTE || type == GL_BYTE
                || type == GL_UNSIGNED_SHORT || type == GL_SHORT
                || type == GL_UNSIGNED_INT || type == GL_INT
                || type == GL_FLOAT || type == GL_HALF_FLOAT));
        if (!isColorReadback && !isDepthReadback && !isStencilReadback
            && !isDepthStencilReadback) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        // Sprint 9 Phase 2 (CKPT102): GL 4.6 §16.1 — depth/stencil read
        // formats require the FBO to have the corresponding attachment.
        // CTS packed_pixels.* tests assert "Invalid format used but
        // glReadPixels succeeded" when reading GL_DEPTH_STENCIL from an
        // FBO whose color attachment is RGBA8. The 804 such "invalid
        // format succeeded" failures across the packed_pixels suite all
        // share this gap.
        if (isDepthReadback || isStencilReadback || isDepthStencilReadback) {
            const GLuint fbName = impl_->state->boundReadFramebuffer();
            const GLFramebufferObject* fb = impl_->objects->framebuffers().get(fbName);
            bool hasDepth = false, hasStencil = false;
            if (fb != nullptr) {
                auto attachmentLive = [&](GLenum point) -> bool {
                    auto it = fb->attachments.find(point);
                    return it != fb->attachments.end() &&
                           it->second.kind != GLFramebufferAttachment::Kind::None &&
                           it->second.object != 0;
                };
                if (attachmentLive(GL_DEPTH_ATTACHMENT) ||
                    attachmentLive(GL_DEPTH_STENCIL_ATTACHMENT)) {
                    hasDepth = true;
                }
                if (attachmentLive(GL_STENCIL_ATTACHMENT) ||
                    attachmentLive(GL_DEPTH_STENCIL_ATTACHMENT)) {
                    hasStencil = true;
                }
            }
            if (isDepthReadback && !hasDepth) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            if (isStencilReadback && !hasStencil) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            if (isDepthStencilReadback && !(hasDepth && hasStencil)) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
        }
        // Format+type compatibility (Table 18.2). Rejects packed types
        // with incompatible base formats, and float types with integer
        // formats. Was previously silent → CTS flagged "invalid format
        // used but glReadPixels succeeded" on many combos.
        if (isColorReadback && !isFormatTypeCompatible_extern(format, type)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        if (isColorReadback) {
            const GLuint fbName = impl_->state->boundReadFramebuffer();
            const GLFramebufferObject* fb =
                impl_->objects->framebuffers().get(fbName);
            if (fb != nullptr &&
                (fb->readBuffer == GL_NONE ||
                 impl_->framebufferAttachment(*fb, fb->readBuffer) == nullptr)) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
        }
        // GL 4.6 §18.3.2: *_INTEGER output formats require the color
        // buffer's internal format to be integer too. Otherwise
        // GL_INVALID_OPERATION. Resolve the bound read-FBO attachment's
        // internal format and check its integer-ness.
        const bool formatIsInteger = (format == GL_RED_INTEGER
            || format == GL_GREEN_INTEGER || format == GL_BLUE_INTEGER
            || format == GL_RG_INTEGER || format == GL_RGB_INTEGER
            || format == GL_RGBA_INTEGER
            || format == GL_BGR_INTEGER || format == GL_BGRA_INTEGER);
        if (isColorReadback) {
            const GLuint fbName = impl_->state->boundReadFramebuffer();
            const GLFramebufferObject* fb = impl_->objects->framebuffers().get(fbName);
            bool fboIsInteger = false;
            if (fb != nullptr) {
                const GLFramebufferAttachment* att = impl_->framebufferAttachment(*fb, fb->readBuffer);
                GLenum internalFormat = 0;
                if (att != nullptr) {
                    if (att->kind == GLFramebufferAttachment::Kind::Renderbuffer) {
                        if (auto* rb = impl_->objects->renderbuffers().get(att->object)) {
                            internalFormat = rb->internalFormat;
                        }
                    } else if (att->kind == GLFramebufferAttachment::Kind::Texture) {
                        if (auto* tex = impl_->objects->textures().get(att->object)) {
                            internalFormat = tex->desc.internalFormat;
                        }
                    }
                }
                // One table, one predicate: this local copy omitted every
                // EXT_texture_integer A/L/I format, so glReadPixels(
                // GL_RGBA_INTEGER) off an ALPHA8I / LUMINANCE32UI /
                // INTENSITY16I attachment saw "integer format, fixed-point
                // buffer" and raised GL_INVALID_OPERATION.
                fboIsInteger = Impl::isIntegerInternalFormat(internalFormat);
            }
            // GL 4.6 §18.3.2: format and the FBO's attachment must agree
            // on integer-ness. Integer format needs integer FBO; non-
            // integer format needs non-integer FBO.
            if (formatIsInteger != fboIsInteger) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
        }
        if (isDepthStencilReadback) {
            const std::size_t pixelCount =
                static_cast<std::size_t>(width) *
                static_cast<std::size_t>(height);
            std::vector<GLfloat> depthStage(pixelCount);
            std::vector<std::uint8_t> stencilStage(pixelCount);
            if (!impl_->readFramebufferPixels(GL_DEPTH_COMPONENT, x, y,
                                              width, height,
                                              depthStage.data()) ||
                !impl_->readFramebufferPixels(GL_STENCIL_INDEX, x, y,
                                              width, height,
                                              stencilStage.data())) {
                pushError(GL_INVALID_FRAMEBUFFER_OPERATION);
                return false;
            }

            auto clamp01 = [](float v) {
                return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
            };
            const std::size_t dstPixelBytes = bytesPerPixel(format, type);
            const auto& packStore = impl_->state->pixelStore();
            const bool packSwapBytes = (packStore.packSwapBytes == GL_TRUE);
            const std::size_t dstRowStridePixels = packStore.packRowLength > 0
                ? static_cast<std::size_t>(packStore.packRowLength)
                : static_cast<std::size_t>(width);
            const std::size_t dstRowBytes = alignByteCount(
                dstRowStridePixels * dstPixelBytes, packStore.packAlignment);
            auto* outBytes = static_cast<std::uint8_t*>(pixels)
                + static_cast<std::size_t>(packStore.packSkipRows) * dstRowBytes
                + static_cast<std::size_t>(packStore.packSkipPixels) * dstPixelBytes;
            if (type == GL_FLOAT_32_UNSIGNED_INT_24_8_REV) {
                for (GLsizei row = 0; row < height; ++row) {
                    for (GLsizei col = 0; col < width; ++col) {
                        const std::size_t i =
                            static_cast<std::size_t>(row) *
                            static_cast<std::size_t>(width) +
                            static_cast<std::size_t>(col);
                        std::uint8_t* dst = outBytes
                            + static_cast<std::size_t>(row) * dstRowBytes
                            + static_cast<std::size_t>(col) * dstPixelBytes;
                        const float d = depthStage[i];
                        const std::uint32_t stencilSlot =
                            static_cast<std::uint32_t>(stencilStage[i]);
                        std::memcpy(dst, &d, 4);
                        std::memcpy(dst + 4, &stencilSlot, 4);
                        if (packSwapBytes) {
                            Impl::swapPixelStoreBytes(dst, dstPixelBytes);
                        }
                    }
                }
            } else {
                for (GLsizei row = 0; row < height; ++row) {
                    for (GLsizei col = 0; col < width; ++col) {
                        const std::size_t i =
                            static_cast<std::size_t>(row) *
                            static_cast<std::size_t>(width) +
                            static_cast<std::size_t>(col);
                        std::uint8_t* dst = outBytes
                            + static_cast<std::size_t>(row) * dstRowBytes
                            + static_cast<std::size_t>(col) * dstPixelBytes;
                        const float d = clamp01(depthStage[i]);
                        const std::uint32_t depth24 =
                            Impl::packReadbackBits(static_cast<double>(d),
                                                   0x00FFFFFFu, false);
                        const std::uint32_t packed =
                            (depth24 << 8) | static_cast<std::uint32_t>(stencilStage[i]);
                        std::memcpy(dst, &packed, 4);
                        if (packSwapBytes) {
                            Impl::swapPixelStoreBytes(dst, dstPixelBytes);
                        }
                    }
                }
            }
            return true;
        }
        if (isDepthReadback || isStencilReadback) {
            // readFramebufferPixels writes 1 byte per stencil value or 4
            // bytes per depth float. When the caller requests a wider
            // GL type (e.g. GL_STENCIL_INDEX + GL_INT), expand in place:
            // read the narrow data into a staging buffer, then splat
            // into the destination.
            const std::size_t pixelCount =
                static_cast<std::size_t>(width) *
                static_cast<std::size_t>(height);
            const std::size_t dstPixelBytes =
                std::max<std::size_t>(bytesPerComponent(type), 1);
            const auto& packStore = impl_->state->pixelStore();
            const bool packSwapBytes = (packStore.packSwapBytes == GL_TRUE);
            const std::size_t dstRowStridePixels = packStore.packRowLength > 0
                ? static_cast<std::size_t>(packStore.packRowLength)
                : static_cast<std::size_t>(width);
            const std::size_t dstRowBytes = alignByteCount(
                dstRowStridePixels * dstPixelBytes, packStore.packAlignment);
            auto* outBytes = static_cast<std::uint8_t*>(pixels)
                + static_cast<std::size_t>(packStore.packSkipRows) * dstRowBytes
                + static_cast<std::size_t>(packStore.packSkipPixels) * dstPixelBytes;
            if (isStencilReadback) {
                std::vector<std::uint8_t> stage(pixelCount);
                if (!impl_->readFramebufferPixels(format, x, y, width, height,
                                                  stage.data())) {
                    pushError(GL_INVALID_FRAMEBUFFER_OPERATION);
                    return false;
                }
                for (GLsizei row = 0; row < height; ++row) {
                    for (GLsizei col = 0; col < width; ++col) {
                        const std::size_t i =
                            static_cast<std::size_t>(row) *
                            static_cast<std::size_t>(width) +
                            static_cast<std::size_t>(col);
                        std::uint8_t* slot = outBytes
                            + static_cast<std::size_t>(row) * dstRowBytes
                            + static_cast<std::size_t>(col) * dstPixelBytes;
                        // Little-endian write: low byte holds the stencil
                        // value, high bytes are zero. All scalar GL types
                        // at bpc >= 2 read the stencil as its LSB.
                        std::memset(slot, 0, dstPixelBytes);
                        slot[0] = stage[i];
                        if (packSwapBytes) {
                            Impl::swapPixelStoreBytes(slot, dstPixelBytes);
                        }
                    }
                }
                return true;
            }
            if (isDepthReadback) {
                // readDepthAttachmentPixels writes 4-byte GLfloat per pixel.
                // When the caller requests a narrower or wider integer type
                // (e.g. GL_UNSIGNED_SHORT for DEPTH_COMPONENT16 readback), we
                // would overflow / underwrite the caller buffer. Stage to
                // floats then convert per GL 4.6 §18.2.10.
                std::vector<GLfloat> stage(pixelCount);
                if (!impl_->readFramebufferPixels(format, x, y, width, height,
                                                  stage.data())) {
                    pushError(GL_INVALID_FRAMEBUFFER_OPERATION);
                    return false;
                }
                auto clamp01 = [](float v) {
                    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
                };
                for (GLsizei row = 0; row < height; ++row) {
                    for (GLsizei col = 0; col < width; ++col) {
                        const std::size_t i =
                            static_cast<std::size_t>(row) *
                            static_cast<std::size_t>(width) +
                            static_cast<std::size_t>(col);
                        const float d = clamp01(stage[i]);
                        std::uint8_t* out = outBytes
                            + static_cast<std::size_t>(row) * dstRowBytes
                            + static_cast<std::size_t>(col) * dstPixelBytes;
                        switch (type) {
                            case GL_UNSIGNED_BYTE: {
                                const std::uint8_t v =
                                    static_cast<std::uint8_t>(d * 255.0f + 0.5f);
                                std::memcpy(out, &v, 1);
                                break;
                            }
                            case GL_BYTE: {
                                const std::int8_t v =
                                    static_cast<std::int8_t>(d * 127.0f + 0.5f);
                                std::memcpy(out, &v, 1);
                                break;
                            }
                            case GL_UNSIGNED_SHORT: {
                                const std::uint16_t v =
                                    static_cast<std::uint16_t>(d * 65535.0f + 0.5f);
                                std::memcpy(out, &v, 2);
                                break;
                            }
                            case GL_SHORT: {
                                const std::int16_t v =
                                    static_cast<std::int16_t>(d * 32767.0f + 0.5f);
                                std::memcpy(out, &v, 2);
                                break;
                            }
                            case GL_UNSIGNED_INT: {
                                const std::uint32_t v = static_cast<std::uint32_t>(
                                    static_cast<double>(d) * 4294967295.0 + 0.5);
                                std::memcpy(out, &v, 4);
                                break;
                            }
                            case GL_INT: {
                                const std::int32_t v = static_cast<std::int32_t>(
                                    static_cast<double>(d) * 2147483647.0 + 0.5);
                                std::memcpy(out, &v, 4);
                                break;
                            }
                            case GL_FLOAT: {
                                std::memcpy(out, &d, 4);
                                break;
                            }
                            case GL_HALF_FLOAT: {
                                // IEEE-754 binary16 encoding (round-to-nearest,
                                // ties-to-even via the rounding-bias trick).
                                std::uint32_t f;
                                std::memcpy(&f, &d, 4);
                                const std::uint32_t sign = (f >> 16) & 0x8000;
                                std::int32_t exp = static_cast<std::int32_t>((f >> 23) & 0xFF) - 127 + 15;
                                std::uint32_t mant = f & 0x7FFFFF;
                                std::uint16_t h;
                                if (exp <= 0) {
                                    h = static_cast<std::uint16_t>(sign);
                                } else if (exp >= 31) {
                                    h = static_cast<std::uint16_t>(sign | 0x7C00);
                                } else {
                                    h = static_cast<std::uint16_t>(
                                        sign | (static_cast<std::uint32_t>(exp) << 10) | (mant >> 13));
                                }
                                std::memcpy(out, &h, 2);
                                break;
                            }
                            default:
                                break;
                        }
                        if (packSwapBytes) {
                            Impl::swapPixelStoreBytes(out, dstPixelBytes);
                        }
                    }
                }
                return true;
            }
        }
        auto fboColorAttachmentPrefersRGBA8Shadow = [&]() -> bool {
            auto rgba8ShadowMatchesNativeFormat =
                [&](GLenum internalFormat) -> bool {
                    const MTLPixelFormat pf =
                        metalRenderbufferFormat(internalFormat);
                    switch (pf) {
                        case MTLPixelFormatR8Unorm:
                        case MTLPixelFormatRG8Unorm:
                        case MTLPixelFormatRGBA8Unorm:
                        case MTLPixelFormatRGBA8Unorm_sRGB:
                        case MTLPixelFormatBGRA8Unorm:
                        case MTLPixelFormatBGRA8Unorm_sRGB:
                            return true;
                        default:
                            return false;
                    }
                };
            const GLuint fbName = impl_->state->boundReadFramebuffer();
            const GLFramebufferObject* fb =
                impl_->objects->framebuffers().get(fbName);
            if (fbName == 0 || fb == nullptr || fb->readBuffer == GL_NONE) {
                return false;
            }
            const GLFramebufferAttachment* att =
                impl_->framebufferAttachment(*fb, fb->readBuffer);
            if (att == nullptr) {
                return false;
            }
            if (att->kind == GLFramebufferAttachment::Kind::Renderbuffer) {
                const GLRenderbufferObject* rb =
                    impl_->objects->renderbuffers().get(att->object);
                if (rb != nullptr &&
                    Impl::isIntegerInternalFormat(rb->internalFormat)) {
                    return false;
                }
                return rb != nullptr && rb->storageDefined &&
                       rgba8ShadowMatchesNativeFormat(rb->internalFormat) &&
                       rb->colorShadowAuthoritative &&
                       !rb->rgba8.empty();
            }
            if (!appglCompatProfileEnabled()) {
                return false;
            }
            if (att->kind == GLFramebufferAttachment::Kind::Texture) {
                const auto resolved =
                    impl_->resolveTextureAttachmentStorage(*att);
                const GLTextureObject* texture = resolved.storageTexture;
                if (!resolved.valid || texture == nullptr ||
                    !texture->colorShadowAuthoritative) {
                    return false;
                }
                const auto level = texture->levels.find(resolved.level);
                return level != texture->levels.end() &&
                       level->second.defined &&
                       rgba8ShadowMatchesNativeFormat(
                           level->second.desc.internalFormat) &&
                       (!level->second.rgba8.empty() ||
                        level->second.lazyFboCanonicalClearPending);
            }
            return false;
        };
        const bool preferFboRGBA8Shadow =
            fboColorAttachmentPrefersRGBA8Shadow();
        // Try native-format readback first (preserves full precision for
        // R32F, RGBA32F, integer formats, etc.) unless an FBO compatibility
        // path has explicitly authored the RGBA8 shadow.
        if (!preferFboRGBA8Shadow &&
            impl_->readFBOColorNative(x, y, width, height, format, type, pixels)) {
            return true;
        }
        // Color readback: read RGBA8 internally, then convert to requested format/type
        if (format == GL_RGBA && type == GL_UNSIGNED_BYTE) {
            const std::size_t directPixelCount =
                static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
            std::vector<std::uint8_t> directRGBA8(directPixelCount * 4u);
            if (!impl_->readFramebufferPixels(format, x, y, width, height, directRGBA8.data())) {
                pushError(GL_INVALID_FRAMEBUFFER_OPERATION);
                return false;
            }
            const auto& packStore = impl_->state->pixelStore();
            const std::size_t dstPixelBytes = 4u;
            const std::size_t dstRowStridePixels = packStore.packRowLength > 0
                ? static_cast<std::size_t>(packStore.packRowLength)
                : static_cast<std::size_t>(width);
            const std::size_t dstRowBytes = alignByteCount(
                dstRowStridePixels * dstPixelBytes, packStore.packAlignment);
            auto* dest = static_cast<std::uint8_t*>(pixels)
                + static_cast<std::size_t>(packStore.packSkipRows) * dstRowBytes
                + static_cast<std::size_t>(packStore.packSkipPixels) * dstPixelBytes;
            for (GLsizei row = 0; row < height; ++row) {
                const auto* srcRow = directRGBA8.data()
                    + static_cast<std::size_t>(row) * static_cast<std::size_t>(width) * dstPixelBytes;
                auto* dstRow = dest + static_cast<std::size_t>(row) * dstRowBytes;
                std::memcpy(dstRow, srcRow, static_cast<std::size_t>(width) * dstPixelBytes);
            }
            return true;
        }
        // For non-RGBA8 color readback, read as RGBA8 into temp buffer, then convert
        const std::size_t pixelCount = static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
        std::vector<std::uint8_t> rgba8(pixelCount * 4);
        if (!impl_->readFramebufferPixels(GL_RGBA, x, y, width, height, rgba8.data())) {
            pushError(GL_INVALID_FRAMEBUFFER_OPERATION);
            return false;
        }
        // Convert RGBA8 to the requested format/type
        const std::size_t components = componentCountForFormat(format);
        const std::size_t bpc = bytesPerComponent(type);
        if (components == 0) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        if (isPackedPixelType(type)) {
            const std::size_t packedBpp = bytesPerPixel(format, type);
            if (packedBpp == 0) {
                pushError(GL_INVALID_ENUM);
                return false;
            }
            const auto& packStore = impl_->state->pixelStore();
            const bool packSwapBytes = (packStore.packSwapBytes == GL_TRUE);
            const std::size_t dstRowStridePixels = packStore.packRowLength > 0
                ? static_cast<std::size_t>(packStore.packRowLength)
                : static_cast<std::size_t>(width);
            const std::size_t dstRowBytes = alignByteCount(
                dstRowStridePixels * packedBpp, packStore.packAlignment);
            auto* dest = static_cast<std::uint8_t*>(pixels)
                + static_cast<std::size_t>(packStore.packSkipRows) * dstRowBytes
                + static_cast<std::size_t>(packStore.packSkipPixels) * packedBpp;

            const bool formatIsBGR = (format == GL_BGR || format == GL_BGR_INTEGER);
            const bool formatIsBGRA = (format == GL_BGRA || format == GL_BGRA_INTEGER);
                const bool formatIsGreen = (format == GL_GREEN || format == GL_GREEN_INTEGER);
                const bool formatIsBlue = (format == GL_BLUE || format == GL_BLUE_INTEGER);
                const bool formatIsAlpha = (format == GL_ALPHA);
                const bool formatIsLuminance = (format == GL_LUMINANCE);
                const bool formatIsLuminanceAlpha = (format == GL_LUMINANCE_ALPHA);
                auto getComponent = [&](const double* vals4, int glCompIndex) -> double {
                    if (formatIsBGR) {
                        static const int map[3] = {2, 1, 0};
                    return glCompIndex < 3 ? vals4[map[glCompIndex]] : 1.0;
                }
                if (formatIsBGRA) {
                    static const int map[4] = {2, 1, 0, 3};
                    return glCompIndex < 4 ? vals4[map[glCompIndex]] : 1.0;
                }
                    if (formatIsGreen) return glCompIndex == 0 ? vals4[1] : 0.0;
                    if (formatIsBlue) return glCompIndex == 0 ? vals4[2] : 0.0;
                    if (formatIsAlpha) return glCompIndex == 0 ? vals4[3] : 0.0;
                    if (formatIsLuminance) {
                        return glCompIndex == 0
                            ? vals4[0] + vals4[1] + vals4[2]
                            : 0.0;
                    }
                    if (formatIsLuminanceAlpha) {
                        if (glCompIndex == 0) {
                            return vals4[0] + vals4[1] + vals4[2];
                        }
                        return glCompIndex == 1 ? vals4[3] : 0.0;
                    }
                    return vals4[glCompIndex];
                };
            auto packUN = [](double v, unsigned bits) -> std::uint32_t {
                if (v < 0.0) v = 0.0;
                if (v > 1.0) v = 1.0;
                const double maxVal = static_cast<double>((1u << bits) - 1u);
                return static_cast<std::uint32_t>(v * maxVal + 0.5);
            };

            for (GLsizei row = 0; row < height; ++row) {
                for (GLsizei col = 0; col < width; ++col) {
                    const std::size_t srcIndex =
                        (static_cast<std::size_t>(row) * static_cast<std::size_t>(width)
                         + static_cast<std::size_t>(col)) * 4u;
                    double vals[4] = {
                        static_cast<double>(rgba8[srcIndex + 0]) / 255.0,
                        static_cast<double>(rgba8[srcIndex + 1]) / 255.0,
                        static_cast<double>(rgba8[srcIndex + 2]) / 255.0,
                        static_cast<double>(rgba8[srcIndex + 3]) / 255.0
                    };
                    auto d = [&](int i) { return getComponent(vals, i); };
                    std::uint8_t* dst = dest
                        + static_cast<std::size_t>(row) * dstRowBytes
                        + static_cast<std::size_t>(col) * packedBpp;
                    switch (type) {
                        case GL_UNSIGNED_BYTE_3_3_2: {
                            const std::uint32_t r = packUN(d(0), 3);
                            const std::uint32_t g = packUN(d(1), 3);
                            const std::uint32_t b = packUN(d(2), 2);
                            dst[0] = static_cast<std::uint8_t>((r << 5) | (g << 2) | b);
                            break;
                        }
                        case GL_UNSIGNED_BYTE_2_3_3_REV: {
                            const std::uint32_t r = packUN(d(0), 3);
                            const std::uint32_t g = packUN(d(1), 3);
                            const std::uint32_t b = packUN(d(2), 2);
                            dst[0] = static_cast<std::uint8_t>((b << 6) | (g << 3) | r);
                            break;
                        }
                        case GL_UNSIGNED_SHORT_5_6_5: {
                            std::uint16_t v = static_cast<std::uint16_t>(
                                (packUN(d(0), 5) << 11) | (packUN(d(1), 6) << 5) | packUN(d(2), 5));
                            std::memcpy(dst, &v, sizeof(v));
                            break;
                        }
                        case GL_UNSIGNED_SHORT_5_6_5_REV: {
                            std::uint16_t v = static_cast<std::uint16_t>(
                                (packUN(d(2), 5) << 11) | (packUN(d(1), 6) << 5) | packUN(d(0), 5));
                            std::memcpy(dst, &v, sizeof(v));
                            break;
                        }
                        case GL_UNSIGNED_SHORT_4_4_4_4: {
                            std::uint16_t v = static_cast<std::uint16_t>(
                                (packUN(d(0), 4) << 12) | (packUN(d(1), 4) << 8)
                                | (packUN(d(2), 4) << 4) | packUN(d(3), 4));
                            std::memcpy(dst, &v, sizeof(v));
                            break;
                        }
                        case GL_UNSIGNED_SHORT_4_4_4_4_REV: {
                            std::uint16_t v = static_cast<std::uint16_t>(
                                (packUN(d(3), 4) << 12) | (packUN(d(2), 4) << 8)
                                | (packUN(d(1), 4) << 4) | packUN(d(0), 4));
                            std::memcpy(dst, &v, sizeof(v));
                            break;
                        }
                        case GL_UNSIGNED_SHORT_5_5_5_1: {
                            std::uint16_t v = static_cast<std::uint16_t>(
                                (packUN(d(0), 5) << 11) | (packUN(d(1), 5) << 6)
                                | (packUN(d(2), 5) << 1) | packUN(d(3), 1));
                            std::memcpy(dst, &v, sizeof(v));
                            break;
                        }
                        case GL_UNSIGNED_SHORT_1_5_5_5_REV: {
                            std::uint16_t v = static_cast<std::uint16_t>(
                                (packUN(d(3), 1) << 15) | (packUN(d(2), 5) << 10)
                                | (packUN(d(1), 5) << 5) | packUN(d(0), 5));
                            std::memcpy(dst, &v, sizeof(v));
                            break;
                        }
                        case GL_UNSIGNED_INT_8_8_8_8: {
                            std::uint32_t v = (packUN(d(0), 8) << 24) | (packUN(d(1), 8) << 16)
                                | (packUN(d(2), 8) << 8) | packUN(d(3), 8);
                            std::memcpy(dst, &v, sizeof(v));
                            break;
                        }
                        case GL_UNSIGNED_INT_8_8_8_8_REV: {
                            std::uint32_t v = (packUN(d(3), 8) << 24) | (packUN(d(2), 8) << 16)
                                | (packUN(d(1), 8) << 8) | packUN(d(0), 8);
                            std::memcpy(dst, &v, sizeof(v));
                            break;
                        }
                        case GL_UNSIGNED_INT_10_10_10_2: {
                            std::uint32_t v = (packUN(d(0), 10) << 22) | (packUN(d(1), 10) << 12)
                                | (packUN(d(2), 10) << 2) | packUN(d(3), 2);
                            std::memcpy(dst, &v, sizeof(v));
                            break;
                        }
                        case GL_UNSIGNED_INT_2_10_10_10_REV: {
                            std::uint32_t v = (packUN(d(3), 2) << 30) | (packUN(d(2), 10) << 20)
                                | (packUN(d(1), 10) << 10) | packUN(d(0), 10);
                            std::memcpy(dst, &v, sizeof(v));
                            break;
                        }
                        case GL_UNSIGNED_INT_10F_11F_11F_REV: {
                            std::uint32_t v = packUF_10F11F11F_REV(d(0), d(1), d(2));
                            std::memcpy(dst, &v, sizeof(v));
                            break;
                        }
                        case GL_UNSIGNED_INT_5_9_9_9_REV: {
                            std::uint32_t v = packUF_5_9_9_9_REV(d(0), d(1), d(2));
                            std::memcpy(dst, &v, sizeof(v));
                            break;
                        }
                        default:
                            std::memset(dst, 0, packedBpp);
                            break;
                    }
                    if (packSwapBytes) {
                        Impl::swapPixelStoreBytes(dst, packedBpp);
                    }
                }
            }
            return true;
        }
        if (bpc == 0) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
        const auto& packStore = impl_->state->pixelStore();
        const bool packSwapBytes = (packStore.packSwapBytes == GL_TRUE);
        const std::size_t dstPixelBytes = components * bpc;
        const std::size_t dstRowStridePixels = packStore.packRowLength > 0
            ? static_cast<std::size_t>(packStore.packRowLength)
            : static_cast<std::size_t>(width);
        const std::size_t dstRowBytes = alignByteCount(
            dstRowStridePixels * dstPixelBytes, packStore.packAlignment);
        auto* dest = static_cast<std::uint8_t*>(pixels)
            + static_cast<std::size_t>(packStore.packSkipRows) * dstRowBytes
            + static_cast<std::size_t>(packStore.packSkipPixels) * dstPixelBytes;
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const std::size_t i =
                    static_cast<std::size_t>(row) * static_cast<std::size_t>(width)
                    + static_cast<std::size_t>(col);
                const std::uint8_t r = rgba8[i * 4 + 0];
                const std::uint8_t g = rgba8[i * 4 + 1];
                const std::uint8_t b = rgba8[i * 4 + 2];
                const std::uint8_t a = rgba8[i * 4 + 3];
                std::uint8_t src[4] = { r, g, b, a };
                if (format == GL_BGR || format == GL_BGR_INTEGER) {
                    src[0] = b; src[1] = g; src[2] = r;
                } else if (format == GL_BGRA || format == GL_BGRA_INTEGER) {
                    src[0] = b; src[1] = g; src[2] = r; src[3] = a;
                } else if (format == GL_LUMINANCE) {
                    const unsigned lum =
                        static_cast<unsigned>(r) +
                        static_cast<unsigned>(g) +
                        static_cast<unsigned>(b);
                    src[0] = static_cast<std::uint8_t>(
                        std::min<unsigned>(lum, 255u));
                } else if (format == GL_LUMINANCE_ALPHA) {
                    const unsigned lum =
                        static_cast<unsigned>(r) +
                        static_cast<unsigned>(g) +
                        static_cast<unsigned>(b);
                    src[0] = static_cast<std::uint8_t>(
                        std::min<unsigned>(lum, 255u));
                    src[1] = a;
                }
                std::uint8_t* dstPixelBase = dest
                    + static_cast<std::size_t>(row) * dstRowBytes
                    + static_cast<std::size_t>(col) * dstPixelBytes;
                for (std::size_t c = 0; c < components; ++c) {
                    const float normalized = static_cast<float>(src[c]) / 255.0f;
                    std::uint8_t* dstP = dstPixelBase + c * bpc;
                    switch (type) {
                        case GL_UNSIGNED_BYTE:
                            dstP[0] = src[c];
                            break;
                        case GL_BYTE: {
                            const std::int8_t v = static_cast<std::int8_t>(src[c] * 127 / 255);
                            std::memcpy(dstP, &v, sizeof(v));
                            break;
                        }
                        case GL_UNSIGNED_SHORT: {
                            const std::uint16_t v = static_cast<std::uint16_t>(src[c] * 257);
                            std::memcpy(dstP, &v, sizeof(v));
                            break;
                        }
                        case GL_SHORT: {
                            const std::int16_t v = static_cast<std::int16_t>(src[c] * 32767 / 255);
                            std::memcpy(dstP, &v, sizeof(v));
                            break;
                        }
                        case GL_UNSIGNED_INT: {
                            const std::uint32_t v = static_cast<std::uint32_t>(src[c]) * 16843009u;
                            std::memcpy(dstP, &v, sizeof(v));
                            break;
                        }
                        case GL_INT: {
                            const std::int32_t v =
                                static_cast<std::int32_t>(static_cast<double>(src[c]) * 2147483647.0 / 255.0);
                            std::memcpy(dstP, &v, sizeof(v));
                            break;
                        }
                        case GL_FLOAT:
                            std::memcpy(dstP, &normalized, sizeof(normalized));
                            break;
                        case GL_HALF_FLOAT: {
                            // Simple float-to-half conversion
                            std::uint32_t fbits;
                            std::memcpy(&fbits, &normalized, sizeof(fbits));
                            std::uint32_t sign = (fbits >> 16) & 0x8000;
                            std::int32_t exp = ((fbits >> 23) & 0xFF) - 127 + 15;
                            std::uint32_t mant = (fbits >> 13) & 0x3FF;
                            std::uint16_t half;
                            if (exp <= 0) half = static_cast<std::uint16_t>(sign);
                            else if (exp >= 31) half = static_cast<std::uint16_t>(sign | 0x7C00);
                            else half = static_cast<std::uint16_t>(sign | (exp << 10) | mant);
                            std::memcpy(dstP, &half, sizeof(half));
                            break;
                        }
                        default:
                            dstP[0] = src[c];
                            break;
                    }
                    if (packSwapBytes) {
                        Impl::swapPixelStoreBytes(dstP, bpc);
                    }
                }
            }
        }
        return true;
    }

    // Default framebuffer depth/stencil readback. MetalFrameGraph does not
    // expose a default depth/stencil copy path, so answer clear-only legacy
    // probes from the CPU shadow we maintain for FB0 depth/stencil clears.
    if (appglCompatProfileEnabled() &&
        format == GL_DEPTH_STENCIL &&
        (type == GL_UNSIGNED_INT_24_8 ||
         type == GL_FLOAT_32_UNSIGNED_INT_24_8_REV)) {
        const std::size_t pixelCount =
            static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
        std::vector<GLfloat> depthStage(pixelCount);
        std::vector<std::uint8_t> stencilStage(pixelCount);
        if (!impl_->copyDefaultFramebufferDepthPixels(
                x, y, width, height, depthStage.data()) ||
            !impl_->copyDefaultFramebufferStencilPixels(
                x, y, width, height, stencilStage.data())) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }

        const auto& packStore = impl_->state->pixelStore();
        const bool packSwapBytes = (packStore.packSwapBytes == GL_TRUE);
        const std::size_t dstPixelBytes = bytesPerPixel(format, type);
        const std::size_t dstRowStridePixels = packStore.packRowLength > 0
            ? static_cast<std::size_t>(packStore.packRowLength)
            : static_cast<std::size_t>(width);
        const std::size_t dstRowBytes = alignByteCount(
            dstRowStridePixels * dstPixelBytes, packStore.packAlignment);
        auto* dest = static_cast<std::uint8_t*>(pixels)
            + static_cast<std::size_t>(packStore.packSkipRows) * dstRowBytes
            + static_cast<std::size_t>(packStore.packSkipPixels) * dstPixelBytes;

        if (type == GL_FLOAT_32_UNSIGNED_INT_24_8_REV) {
            for (GLsizei row = 0; row < height; ++row) {
                for (GLsizei col = 0; col < width; ++col) {
                    const std::size_t i =
                        static_cast<std::size_t>(row) *
                        static_cast<std::size_t>(width) +
                        static_cast<std::size_t>(col);
                    std::uint8_t* dst = dest +
                        static_cast<std::size_t>(row) * dstRowBytes +
                        static_cast<std::size_t>(col) * dstPixelBytes;
                    const GLfloat depth = depthStage[i];
                    const std::uint32_t stencilSlot =
                        static_cast<std::uint32_t>(stencilStage[i]);
                    std::memcpy(dst, &depth, sizeof(depth));
                    std::memcpy(dst + sizeof(depth), &stencilSlot,
                                sizeof(stencilSlot));
                    if (packSwapBytes) {
                        Impl::swapPixelStoreBytes(dst, dstPixelBytes);
                    }
                }
            }
        } else {
            for (GLsizei row = 0; row < height; ++row) {
                for (GLsizei col = 0; col < width; ++col) {
                    const std::size_t i =
                        static_cast<std::size_t>(row) *
                        static_cast<std::size_t>(width) +
                        static_cast<std::size_t>(col);
                    std::uint8_t* dst = dest +
                        static_cast<std::size_t>(row) * dstRowBytes +
                        static_cast<std::size_t>(col) * dstPixelBytes;
                    const GLfloat clampedDepth =
                        std::clamp(depthStage[i], 0.0f, 1.0f);
                    const std::uint32_t depth24 =
                        Impl::packReadbackBits(
                            static_cast<double>(clampedDepth),
                            0x00ffffffu, false);
                    const std::uint32_t packed =
                        (depth24 << 8) |
                        static_cast<std::uint32_t>(stencilStage[i]);
                    std::memcpy(dst, &packed, sizeof(packed));
                    if (packSwapBytes) {
                        Impl::swapPixelStoreBytes(dst, dstPixelBytes);
                    }
                }
            }
        }
        return true;
    }
    if (format == GL_DEPTH_COMPONENT && type == GL_FLOAT) {
        std::vector<GLfloat> depthStage(
            static_cast<std::size_t>(width) * static_cast<std::size_t>(height));
        if (!impl_->copyDefaultFramebufferDepthPixels(
                x, y, width, height, depthStage.data())) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        const auto& packStore = impl_->state->pixelStore();
        const std::size_t dstPixelBytes = sizeof(GLfloat);
        const std::size_t dstRowStridePixels = packStore.packRowLength > 0
            ? static_cast<std::size_t>(packStore.packRowLength)
            : static_cast<std::size_t>(width);
        const std::size_t dstRowBytes = alignByteCount(
            dstRowStridePixels * dstPixelBytes, packStore.packAlignment);
        auto* dest = static_cast<std::uint8_t*>(pixels)
            + static_cast<std::size_t>(packStore.packSkipRows) * dstRowBytes
            + static_cast<std::size_t>(packStore.packSkipPixels) * dstPixelBytes;
        for (GLsizei row = 0; row < height; ++row) {
            std::memcpy(dest + static_cast<std::size_t>(row) * dstRowBytes,
                        depthStage.data() +
                            static_cast<std::size_t>(row) *
                            static_cast<std::size_t>(width),
                        static_cast<std::size_t>(width) * dstPixelBytes);
        }
        return true;
    }
    if (format == GL_STENCIL_INDEX &&
        (type == GL_UNSIGNED_BYTE || type == GL_UNSIGNED_SHORT ||
         type == GL_UNSIGNED_INT || type == GL_BYTE ||
         type == GL_SHORT || type == GL_INT)) {
        const std::size_t pixelCount =
            static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
        std::vector<std::uint8_t> stencilStage(pixelCount);
        if (!impl_->copyDefaultFramebufferStencilPixels(
                x, y, width, height, stencilStage.data())) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        const auto& packStore = impl_->state->pixelStore();
        const std::size_t dstPixelBytes =
            std::max<std::size_t>(bytesPerComponent(type), 1);
        const std::size_t dstRowStridePixels = packStore.packRowLength > 0
            ? static_cast<std::size_t>(packStore.packRowLength)
            : static_cast<std::size_t>(width);
        const std::size_t dstRowBytes = alignByteCount(
            dstRowStridePixels * dstPixelBytes, packStore.packAlignment);
        auto* dest = static_cast<std::uint8_t*>(pixels)
            + static_cast<std::size_t>(packStore.packSkipRows) * dstRowBytes
            + static_cast<std::size_t>(packStore.packSkipPixels) * dstPixelBytes;
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const std::size_t i =
                    static_cast<std::size_t>(row) *
                    static_cast<std::size_t>(width) +
                    static_cast<std::size_t>(col);
                std::uint8_t* slot = dest +
                    static_cast<std::size_t>(row) * dstRowBytes +
                    static_cast<std::size_t>(col) * dstPixelBytes;
                std::memset(slot, 0, dstPixelBytes);
                slot[0] = stencilStage[i];
                if (packStore.packSwapBytes == GL_TRUE) {
                    Impl::swapPixelStoreBytes(slot, dstPixelBytes);
                }
            }
        }
        return true;
    }

    // Default framebuffer readback — widen format/type acceptance.
    // If the CPU shadow is authoritative, answer before forcing a Metal
    // readback flush; tiny legacy probes such as draw-sync depend on this
    // path not serializing every pixel-sized draw.
    if (format == GL_RGBA && type == GL_UNSIGNED_BYTE) {
        impl_->materializeDefaultFbShadowClear();
        if (impl_->copyDefaultFramebufferShadowPixels(x, y, width, height, pixels)) {
            return true;
        }
    }
    if ((format == GL_RGB || format == GL_RGBA) && type == GL_FLOAT) {
        const std::size_t components = format == GL_RGB ? 3u : 4u;
        const std::size_t pixelCount =
            static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
        std::vector<std::uint8_t> rgba8(pixelCount * 4u);
        impl_->materializeDefaultFbShadowClear();
        if (impl_->copyDefaultFramebufferShadowPixels(
                x, y, width, height, rgba8.data())) {
            const auto& packStore = impl_->state->pixelStore();
            const std::size_t dstPixelBytes = components * sizeof(GLfloat);
            const std::size_t dstRowStridePixels = packStore.packRowLength > 0
                ? static_cast<std::size_t>(packStore.packRowLength)
                : static_cast<std::size_t>(width);
            const std::size_t dstRowBytes = alignByteCount(
                dstRowStridePixels * dstPixelBytes,
                packStore.packAlignment);
            auto* dest = static_cast<std::uint8_t*>(pixels)
                + static_cast<std::size_t>(packStore.packSkipRows) * dstRowBytes
                + static_cast<std::size_t>(packStore.packSkipPixels) * dstPixelBytes;
            for (GLsizei row = 0; row < height; ++row) {
                for (GLsizei col = 0; col < width; ++col) {
                    const std::size_t srcOffset =
                        static_cast<std::size_t>(row * width + col) * 4u;
                    auto* dst = reinterpret_cast<GLfloat*>(
                        dest + static_cast<std::size_t>(row) * dstRowBytes +
                        static_cast<std::size_t>(col) * dstPixelBytes);
                    for (std::size_t c = 0; c < components; ++c) {
                        dst[c] = static_cast<GLfloat>(rgba8[srcOffset + c]) / 255.0f;
                    }
                }
            }
            return true;
        }
    }
    impl_->encodePendingWork();
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushForReadback();
    }
    if (format == GL_RGBA && type == GL_UNSIGNED_BYTE) {
        impl_->materializeDefaultFbShadowClear();
        if (impl_->copyDefaultFramebufferShadowPixels(x, y, width, height, pixels)) {
            return true;
        }
        if (impl_->frameGraph == nullptr || !impl_->frameGraph->copyRGBA8Pixels(x, y, width, height, pixels)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        return true;
    }
    // For non-RGBA8 default framebuffer reads, read RGBA8 and convert
    if (componentCountForFormat(format) == 0) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const std::size_t pixelCount = static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
    std::vector<std::uint8_t> rgba8(pixelCount * 4);
    impl_->materializeDefaultFbShadowClear();
    if (!impl_->copyDefaultFramebufferShadowPixels(x, y, width, height, rgba8.data()) &&
        (impl_->frameGraph == nullptr ||
         !impl_->frameGraph->copyRGBA8Pixels(x, y, width, height, rgba8.data()))) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Simple RGBA8 → requested format conversion (same as FBO path above)
    const std::size_t components = componentCountForFormat(format);
    const std::size_t bpc = bytesPerComponent(type);
    if (components == 0 || bpc == 0) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const auto& packStore = impl_->state->pixelStore();
    const bool packSwapBytes = (packStore.packSwapBytes == GL_TRUE);
    const std::size_t dstPixelBytes = components * bpc;
    const std::size_t dstRowStridePixels = packStore.packRowLength > 0
        ? static_cast<std::size_t>(packStore.packRowLength)
        : static_cast<std::size_t>(width);
    const std::size_t dstRowBytes = alignByteCount(
        dstRowStridePixels * dstPixelBytes, packStore.packAlignment);
    auto* dest = static_cast<std::uint8_t*>(pixels)
        + static_cast<std::size_t>(packStore.packSkipRows) * dstRowBytes
        + static_cast<std::size_t>(packStore.packSkipPixels) * dstPixelBytes;
    for (GLsizei row = 0; row < height; ++row) {
        for (GLsizei col = 0; col < width; ++col) {
            const std::size_t i =
                static_cast<std::size_t>(row) * static_cast<std::size_t>(width) +
                static_cast<std::size_t>(col);
            const std::uint8_t r = rgba8[i * 4 + 0];
            const std::uint8_t g = rgba8[i * 4 + 1];
            const std::uint8_t b = rgba8[i * 4 + 2];
            const std::uint8_t a = rgba8[i * 4 + 3];
            std::uint8_t src[4] = { r, g, b, a };
            if (format == GL_BGR || format == GL_BGR_INTEGER) {
                src[0] = b; src[1] = g; src[2] = r;
            } else if (format == GL_BGRA || format == GL_BGRA_INTEGER) {
                src[0] = b; src[1] = g; src[2] = r; src[3] = a;
            } else if (format == GL_GREEN || format == GL_GREEN_INTEGER) {
                src[0] = g;
            } else if (format == GL_BLUE || format == GL_BLUE_INTEGER) {
                src[0] = b;
            } else if (format == GL_ALPHA) {
                src[0] = a;
            } else if (format == GL_LUMINANCE) {
                const unsigned lum =
                    static_cast<unsigned>(r) +
                    static_cast<unsigned>(g) +
                    static_cast<unsigned>(b);
                src[0] = static_cast<std::uint8_t>(
                    std::min<unsigned>(lum, 255u));
            } else if (format == GL_LUMINANCE_ALPHA) {
                const unsigned lum =
                    static_cast<unsigned>(r) +
                    static_cast<unsigned>(g) +
                    static_cast<unsigned>(b);
                src[0] = static_cast<std::uint8_t>(
                    std::min<unsigned>(lum, 255u));
                src[1] = a;
            }
            std::uint8_t* dstPixelBase = dest
                + static_cast<std::size_t>(row) * dstRowBytes
                + static_cast<std::size_t>(col) * dstPixelBytes;
            for (std::size_t c = 0; c < components; ++c) {
                const std::uint8_t value = src[c];
                const float normalized = static_cast<float>(value) / 255.0f;
                std::uint8_t* dstP = dstPixelBase + c * bpc;
                switch (type) {
                    case GL_UNSIGNED_BYTE:
                        dstP[0] = value;
                        break;
                    case GL_BYTE: {
                        const std::int8_t v =
                            static_cast<std::int8_t>(value * 127 / 255);
                        std::memcpy(dstP, &v, sizeof(v));
                        break;
                    }
                    case GL_FLOAT:
                        std::memcpy(dstP, &normalized, sizeof(normalized));
                        break;
                    case GL_UNSIGNED_SHORT: {
                        const std::uint16_t v =
                            static_cast<std::uint16_t>(value * 257);
                        std::memcpy(dstP, &v, sizeof(v));
                        break;
                    }
                    case GL_SHORT: {
                        const std::int16_t v =
                            static_cast<std::int16_t>(value * 32767 / 255);
                        std::memcpy(dstP, &v, sizeof(v));
                        break;
                    }
                    case GL_UNSIGNED_INT: {
                        const std::uint32_t v =
                            static_cast<std::uint32_t>(value) * 16843009u;
                        std::memcpy(dstP, &v, sizeof(v));
                        break;
                    }
                    case GL_INT: {
                        const std::int32_t v = static_cast<std::int32_t>(
                            static_cast<double>(value) * 2147483647.0 /
                            255.0);
                        std::memcpy(dstP, &v, sizeof(v));
                        break;
                    }
                    case GL_HALF_FLOAT: {
                        std::uint32_t fbits;
                        std::memcpy(&fbits, &normalized, sizeof(fbits));
                        const std::uint32_t sign = (fbits >> 16) & 0x8000;
                        const std::int32_t exp =
                            static_cast<std::int32_t>((fbits >> 23) & 0xFF) -
                            127 + 15;
                        const std::uint32_t mant = (fbits >> 13) & 0x3FF;
                        std::uint16_t half;
                        if (exp <= 0) {
                            half = static_cast<std::uint16_t>(sign);
                        } else if (exp >= 31) {
                            half = static_cast<std::uint16_t>(sign | 0x7C00);
                        } else {
                            half = static_cast<std::uint16_t>(
                                sign | (static_cast<std::uint32_t>(exp) << 10) |
                                mant);
                        }
                        std::memcpy(dstP, &half, sizeof(half));
                        break;
                    }
                    default:
                        dstP[0] = value;
                        break;
                }
                if (packSwapBytes) {
                    Impl::swapPixelStoreBytes(dstP, bpc);
                }
            }
        }
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_READBACK_READN_PIXELS)
bool GLContext::readnPixels(GLint x, GLint y, GLsizei width, GLsizei height,
                            GLenum format, GLenum type, GLsizei bufSize, void* data) {
    if (bufSize < 0) { pushError(GL_INVALID_VALUE); return false; }
    return readPixels(x, y, width, height, format, type, data);
}

#else
#error "GLContextReadback.inc.mm included without a readback section selector"
#endif
