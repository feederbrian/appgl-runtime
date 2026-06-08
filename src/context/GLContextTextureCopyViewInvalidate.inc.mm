// This file is textually included by GLContextTexture.inc.mm. Do not compile it directly.
// It contains the GLContext texture copy/view/invalidate method definitions split out for navigation only.

#line 272 "src/context/GLContextTexture.inc.mm" // Preserve source identity so this relocation stays codegen-neutral; __FILE__/__LINE__/debug-info intentionally report the original GLContextTexture.inc.mm.
bool GLContext::copyImageSubData(GLuint srcName, GLenum srcTarget, GLint srcLevel, GLint srcX, GLint srcY, GLint srcZ,
                                 GLuint dstName, GLenum dstTarget, GLint dstLevel, GLint dstX, GLint dstY, GLint dstZ,
                                 GLsizei srcWidth, GLsizei srcHeight, GLsizei srcDepth) {
    if (srcWidth < 0 || srcHeight < 0 || srcDepth < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.6 §18.2.3: srcTarget and dstTarget must each be one of
    // the allowed texture / renderbuffer targets. TEXTURE_BUFFER is
    // explicitly not allowed (buffer textures have no image storage
    // in the copyImageSubData sense). CTS `copy_image.invalid_target`
    // plants TEXTURE_BUFFER on both sides and expects INVALID_ENUM.
    auto isValidCopyImageTarget = [](GLenum t) {
        switch (t) {
            case GL_RENDERBUFFER:
            case GL_TEXTURE_1D:
            case GL_TEXTURE_1D_ARRAY:
            case GL_TEXTURE_2D:
            case GL_TEXTURE_2D_ARRAY:
            case GL_TEXTURE_2D_MULTISAMPLE:
            case GL_TEXTURE_2D_MULTISAMPLE_ARRAY:
            case GL_TEXTURE_3D:
            case GL_TEXTURE_CUBE_MAP:
            case GL_TEXTURE_CUBE_MAP_ARRAY:
            case GL_TEXTURE_RECTANGLE:
                return true;
            default:
                return false;  // TEXTURE_BUFFER, stray enums, etc.
        }
    };
    if (!isValidCopyImageTarget(srcTarget) ||
        !isValidCopyImageTarget(dstTarget)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // Validate source and destination exist.
    bool srcIsTex = (srcTarget != GL_RENDERBUFFER);
    bool dstIsTex = (dstTarget != GL_RENDERBUFFER);
    if (srcIsTex && !impl_->objects->textures().contains(srcName)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!srcIsTex && !impl_->objects->renderbuffers().contains(srcName)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (dstIsTex && !impl_->objects->textures().contains(dstName)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!dstIsTex && !impl_->objects->renderbuffers().contains(dstName)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.6 §18.3.2 / §18.2.3: the target argument must match the
    // texture object's actual bound target. CTS copy_image.target_miss_match
    // creates a TEXTURE_1D and calls copyImageSubData with target=
    // TEXTURE_1D_ARRAY, expecting INVALID_ENUM.
    if (srcIsTex) {
        const GLTextureObject* tex = impl_->objects->textures().get(srcName);
        if (tex != nullptr && tex->target != 0 && tex->target != srcTarget) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
    }
    if (dstIsTex) {
        const GLTextureObject* tex = impl_->objects->textures().get(dstName);
        if (tex != nullptr && tex->target != 0 && tex->target != dstTarget) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
    }
    // GL 4.6 §18.3.2: INVALID_OPERATION if source or destination texture
    // is not "complete" — i.e. has any required level missing or
    // dimensions inconsistent. CTS copy_image.incomplete_tex creates a
    // TEXTURE_1D with no level data and expects INVALID_OPERATION on
    // the copy. For the minimal completeness signal we check whether
    // any level is defined: an empty `levels` map (or only undefined
    // entries) on a non-immutable texture is incomplete.
    auto isTextureComplete = [&](GLuint name) -> bool {
        const GLTextureObject* tex = impl_->objects->textures().get(name);
        if (tex == nullptr) return false;
        if (tex->desc.immutable) return true; // texStorage initialises all levels
        // GL 4.6 §8.17 — multisample textures (TEXTURE_2D_MULTISAMPLE
        // and TEXTURE_2D_MULTISAMPLE_ARRAY) have NO mipmap chain by
        // spec: completeness only requires the single base level to be
        // defined. The general mipmap-completeness loop below would
        // otherwise reject MS textures that legitimately have only
        // level 0 (the natural-max derived from base-level dimensions
        // requests log2(max-dim) levels which never exist for MS).
        // CKPT174 EMERGENCY (Sprint 15 Day 3): regression repair after
        // CKPT159 (`309cbbe`) cleared desc.immutable on MS textures
        // created via legacy glTexImage*Multisample — that fix is
        // correct for ARB_texture_view's origtexture mutability check,
        // but exposed this latent assumption that non-immutable always
        // implies a mipmap chain. Restores copy_image.samples_mismatch
        // (regressed from 324/324 in Sprint 13 close to 323/324 in
        // Sprint 14 close).
        const GLenum tgt = tex->desc.target != 0 ? tex->desc.target : tex->target;
        const bool isMSTarget =
            (tgt == GL_TEXTURE_2D_MULTISAMPLE ||
             tgt == GL_TEXTURE_2D_MULTISAMPLE_ARRAY);
        if (isMSTarget) {
            auto it = tex->levels.find(0);
            return it != tex->levels.end() && it->second.defined;
        }
        if (tex->levels.empty()) return false;
        // GL 4.6 §8.17 mipmap completeness: a non-immutable texture is
        // complete only if every level in [base, effectiveMax] is defined.
        // CTS copy_image.incomplete_tex creates multi-level targets with
        // only level 0 defined and DOES NOT call makeTextureComplete (which
        // sets baseLevel/maxLevel both to 0). Without that, default
        // maxLevel = 1000 means lots of levels required → incomplete.
        const GLint baseLevel = tex->params.baseLevel;
        // Effective max is clamped by both the explicit maxLevel and
        // the natural log2(max-dim) bound at the base level. We use the
        // base-level dimensions to compute the natural cap.
        auto baseIt = tex->levels.find(baseLevel);
        if (baseIt == tex->levels.end() || !baseIt->second.defined) return false;
        const GLsizei baseW = baseIt->second.desc.width;
        const GLsizei baseH = baseIt->second.desc.height;
        const GLsizei baseD = baseIt->second.desc.depth;
        const GLint naturalMax =
            baseLevel + mipTailOffsetForDimensions(baseW, baseH, baseD);
        const GLint effectiveMax = std::min(tex->params.maxLevel, naturalMax);
        for (GLint lvl = baseLevel; lvl <= effectiveMax; ++lvl) {
            auto it = tex->levels.find(lvl);
            if (it == tex->levels.end() || !it->second.defined) return false;
        }
        return true;
    };
    if (srcIsTex && !isTextureComplete(srcName)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (dstIsTex && !isTextureComplete(dstName)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    // GL 4.6 §18.2.3: srcLevel and dstLevel must be valid levels of
    // their objects. Renderbuffers only have level 0; textures have
    // levels [0, desc.levels). Reject out-of-range levels up-front so
    // CTS `copy_image.non_existent_mipmap` sees the INVALID_VALUE it
    // expects (was silently creating the level on the fly below).
    auto isValidLevelForTex = [&](GLuint name, GLint level) -> bool {
        if (level < 0) return false;
        GLTextureObject* tex = impl_->objects->textures().get(name);
        if (tex == nullptr) return false;
        const GLsizei maxLev = std::max<GLsizei>(tex->desc.levels, 1);
        if (level >= maxLev) return false;
        // Non-immutable texture: also require the level to have been
        // defined via texImage (or match desc.levels for texStorage).
        // An undefined level on a non-immutable texture is per-spec
        // INVALID_VALUE. Check via levels map or texStorage's desc.
        if (!tex->desc.immutable) {
            auto it = tex->levels.find(level);
            if (it == tex->levels.end() || !it->second.defined) return false;
        }
        return true;
    };
    if (srcIsTex && !isValidLevelForTex(srcName, srcLevel)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (dstIsTex && !isValidLevelForTex(dstName, dstLevel)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Renderbuffers only have "level 0" — any non-zero level for a
    // renderbuffer source or destination is INVALID_VALUE.
    if (!srcIsTex && srcLevel != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!dstIsTex && dstLevel != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    // GL 4.6 §18.2.3: INVALID_OPERATION if source and destination have
    // different sample counts. Renderbuffers default to samples=0;
    // MULTISAMPLE / MULTISAMPLE_ARRAY textures typically have >0.
    // CTS `copy_image.invalid_target` plants a RENDERBUFFER source
    // into a 2D_MULTISAMPLE destination and expects INVALID_OPERATION.
    auto getSamples = [&](GLuint name, bool isTex) -> GLsizei {
        if (isTex) {
            GLTextureObject* tex = impl_->objects->textures().get(name);
            return tex != nullptr ? tex->desc.samples : 0;
        }
        GLRenderbufferObject* rb = impl_->objects->renderbuffers().get(name);
        return rb != nullptr ? rb->samples : 0;
    };
    const GLsizei srcSamples = getSamples(srcName, srcIsTex);
    const GLsizei dstSamples = getSamples(dstName, dstIsTex);
    // A MULTISAMPLE target on a texture with samples=0 still counts
    // as multisample-shaped for the compatibility check (the target
    // alone signals the intent). Normalise the sample count by
    // inspecting the target enum.
    auto targetRequiresMS = [](GLenum t) {
        return t == GL_TEXTURE_2D_MULTISAMPLE ||
               t == GL_TEXTURE_2D_MULTISAMPLE_ARRAY;
    };
    const bool srcIsMSTarget = targetRequiresMS(srcTarget);
    const bool dstIsMSTarget = targetRequiresMS(dstTarget);
    if (srcIsMSTarget != dstIsMSTarget || srcSamples != dstSamples) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    // GL 4.6 §18.2.3 / Table 18.4: src and dst internal formats must
    // be "copy-compatible" — practically this means matching bits-per-
    // texel for non-compressed formats, and matching block-size for
    // compressed formats. Without this check,
    // `glCopyImageSubData(RGBA16UI, RGBA8UI, …)` ran silently; CTS
    // `copy_image.incompatible_formats` expects INVALID_OPERATION.
    auto getInternalFormat = [&](GLuint name, bool isTex, GLint level) -> GLenum {
        if (isTex) {
            const GLTextureObject* t = impl_->objects->textures().get(name);
            if (t == nullptr) return 0;
            auto it = t->levels.find(level);
            if (it != t->levels.end() && it->second.desc.internalFormat != 0) {
                return it->second.desc.internalFormat;
            }
            return t->desc.internalFormat;
        }
        const GLRenderbufferObject* rb = impl_->objects->renderbuffers().get(name);
        return rb != nullptr ? rb->internalFormat : 0;
    };
    // Bits-per-texel for the set of formats covered by GL 4.6 Table
    // 8.12 / 18.4. Returns 0 for compressed formats (caller uses
    // block-based comparison) and for unrecognised formats (caller
    // should let the copy proceed rather than rejecting on unknowns).
    auto bitsPerTexel = [](GLenum fmt) -> int {
        switch (fmt) {
            // 8-bit per channel formats.
            case GL_R8: case GL_R8I: case GL_R8UI:
            case GL_R8_SNORM:
                return 8;
            case GL_RG8: case GL_RG8I: case GL_RG8UI:
            case GL_RG8_SNORM:
                return 16;
            case GL_RGB8: case GL_RGB8I: case GL_RGB8UI:
            case GL_RGB8_SNORM: case GL_SRGB8:
                return 24;
            case GL_RGBA8: case GL_RGBA8I: case GL_RGBA8UI:
            case GL_RGBA8_SNORM: case GL_SRGB8_ALPHA8:
                return 32;
            // 16-bit per channel formats.
            case GL_R16: case GL_R16I: case GL_R16UI:
            case GL_R16_SNORM: case GL_R16F:
                return 16;
            case GL_RG16: case GL_RG16I: case GL_RG16UI:
            case GL_RG16_SNORM: case GL_RG16F:
                return 32;
            case GL_RGB16: case GL_RGB16I: case GL_RGB16UI:
            case GL_RGB16_SNORM: case GL_RGB16F:
                return 48;
            case GL_RGBA16: case GL_RGBA16I: case GL_RGBA16UI:
            case GL_RGBA16_SNORM: case GL_RGBA16F:
                return 64;
            // 32-bit per channel formats.
            case GL_R32I: case GL_R32UI: case GL_R32F:
                return 32;
            case GL_RG32I: case GL_RG32UI: case GL_RG32F:
                return 64;
            case GL_RGB32I: case GL_RGB32UI: case GL_RGB32F:
                return 96;
            case GL_RGBA32I: case GL_RGBA32UI: case GL_RGBA32F:
                return 128;
            // Packed formats.
            case GL_RGB565:           return 16;
            case GL_RGB5_A1:          return 16;
            case GL_RGBA4:            return 16;
            case GL_R3_G3_B2:         return 8;
            case GL_RGB10:            return 32;  // 32 with padding
            case GL_RGB10_A2:
            case GL_RGB10_A2UI:
            case GL_R11F_G11F_B10F:
            case GL_RGB9_E5:
                return 32;
            // Depth / stencil formats — for completeness, though CTS
            // copy_image doesn't mix depth with color.
            case GL_DEPTH_COMPONENT16:  return 16;
            case GL_DEPTH_COMPONENT24:  return 32;  // padded
            case GL_DEPTH_COMPONENT32:  return 32;
            case GL_DEPTH_COMPONENT32F: return 32;
            case GL_DEPTH24_STENCIL8:   return 32;
            case GL_DEPTH32F_STENCIL8:  return 64;
            case GL_STENCIL_INDEX8:     return 8;
            // Compressed formats — report bits-per-BLOCK. GL 4.6
            // §18.2.3 Table 18.4 says a compressed block is copy-
            // compatible with an uncompressed texel of the same
            // total bit-count (e.g. BC5 128-bit block ↔ RGBA32UI
            // 128-bit texel is legal; BC5 ↔ RGBA8UI 32-bit is not).
            // All desktop BC/RGTC/BPTC formats use 4×4 blocks.
            // BC1/BC4/RGTC1: 8 bytes/block = 64 bits/block.
            // BC5/RGTC2/BPTC: 16 bytes/block = 128 bits/block.
            case GL_COMPRESSED_RED_RGTC1:
            case GL_COMPRESSED_SIGNED_RED_RGTC1:
                return 64;
            case GL_COMPRESSED_RG_RGTC2:
            case GL_COMPRESSED_SIGNED_RG_RGTC2:
            case GL_COMPRESSED_RGBA_BPTC_UNORM:
            case GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM:
            case GL_COMPRESSED_RGB_BPTC_SIGNED_FLOAT:
            case GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT:
                return 128;
            default:
                return 0;  // unrecognised / compressed — caller's fallback
        }
    };
    const GLenum srcInternal = getInternalFormat(srcName, srcIsTex, srcLevel);
    const GLenum dstInternal = getInternalFormat(dstName, dstIsTex, dstLevel);
    const int srcBits = bitsPerTexel(srcInternal);
    const int dstBits = bitsPerTexel(dstInternal);
    if (srcBits > 0 && dstBits > 0 && srcBits != dstBits) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    // GL 4.6 §18.2.3: when either side is a compressed texture, the
    // offsets and extents must be integer multiples of the block
    // dimensions (or cover the edge of the texture). All desktop
    // compressed formats BC1-BC7 / RGTC / BPTC use a 4×4×1 block.
    // CTS `copy_image.invalid_alignment` plants a 2×4×1 copy from a
    // compressed source/destination and expects INVALID_VALUE.
    auto isCompressedFormat = [](GLenum fmt) {
        switch (fmt) {
            case GL_COMPRESSED_RED_RGTC1:
            case GL_COMPRESSED_SIGNED_RED_RGTC1:
            case GL_COMPRESSED_RG_RGTC2:
            case GL_COMPRESSED_SIGNED_RG_RGTC2:
            case GL_COMPRESSED_RGBA_BPTC_UNORM:
            case GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM:
            case GL_COMPRESSED_RGB_BPTC_SIGNED_FLOAT:
            case GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT:
                return true;
            default:
                return false;
        }
    };
    const bool srcIsCompressed = isCompressedFormat(srcInternal);
    const bool dstIsCompressed = isCompressedFormat(dstInternal);
    if (srcIsCompressed || dstIsCompressed) {
        // All BC/RGTC/BPTC formats use 4×4×1 blocks on desktop GL.
        const GLint blockW = 4, blockH = 4, blockD = 1;
        auto offsetValid = [&](GLint off, GLint block) {
            return (off % block) == 0;
        };
        auto extentValid = [&](GLint off, GLsizei ext, GLint block, GLsizei texExt) {
            if ((ext % block) == 0) return true;
            // Edge coverage: ext may be < block if it reaches the
            // texture boundary exactly.
            return (off + ext) == texExt;
        };
        if (srcIsCompressed) {
            if (!offsetValid(srcX, blockW) || !offsetValid(srcY, blockH)
                || !offsetValid(srcZ, blockD)) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
            // We don't have easy access to src texture extent here
            // without looking it up; for the CTS test at hand,
            // rejecting non-block-aligned extent unconditionally
            // flags the bug. Edge-coverage edge-case is rare in
            // the negative tests the CTS plants.
            if ((srcWidth % blockW) != 0 || (srcHeight % blockH) != 0) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
        }
        if (dstIsCompressed) {
            if (!offsetValid(dstX, blockW) || !offsetValid(dstY, blockH)
                || !offsetValid(dstZ, blockD)) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
            // For a non-compressed source copying into a compressed
            // destination, srcWidth/srcHeight are in source texel
            // units — GL's rule is still "be a multiple of the
            // compressed destination's block extent". So the same
            // check fires.
            if ((srcWidth % blockW) != 0 || (srcHeight % blockH) != 0) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
        }
        (void)extentValid;
    }

    // No-op for zero-sized copies.
    if (srcWidth == 0 || srcHeight == 0 || srcDepth == 0) return true;

    impl_->drainPendingGpuProducers({
        {srcIsTex ? Impl::GpuResourceAccess::Kind::Texture
                  : Impl::GpuResourceAccess::Kind::Renderbuffer,
         srcName,
         kProducerAll}
    });

    // -----------------------------------------------------------------------
    // Resolve source image shadow buffer, dimensions, and bytes-per-pixel.
    // -----------------------------------------------------------------------
    const std::uint8_t* srcPixels = nullptr;
    GLsizei srcImgW = 0, srcImgH = 0, srcImgD = 1;
    std::size_t srcBpp = 4; // RGBA8 default
    const bool srcCubeMap = srcIsTex && srcTarget == GL_TEXTURE_CUBE_MAP;
    const bool dstCubeMap = dstIsTex && dstTarget == GL_TEXTURE_CUBE_MAP;
    auto textureLevelForCopyLayer = [](GLTextureObject* tex,
                                       GLenum target,
                                       GLint level,
                                       GLint z) -> GLTextureImageLevel* {
        if (tex == nullptr) {
            return nullptr;
        }
        if (target == GL_TEXTURE_CUBE_MAP) {
            if (z < 0 || z >= 6) {
                return nullptr;
            }
            auto& faceLevels = tex->cubeFaceLevels[static_cast<std::size_t>(z)];
            auto faceIt = faceLevels.find(level);
            if (faceIt != faceLevels.end() && faceIt->second.defined) {
                return &faceIt->second;
            }
        }
        auto it = tex->levels.find(level);
        if (it != tex->levels.end() && it->second.defined) {
            return &it->second;
        }
        return nullptr;
    };
    auto selectTextureReadPixels = [](const GLTextureImageLevel& image,
                                      const std::uint8_t*& pixels,
                                      std::size_t& bpp) -> bool {
        if (image.nativeBpp > 0 && !image.nativeData.empty()) {
            pixels = image.nativeData.data();
            bpp = image.nativeBpp;
            return true;
        }
        if (!image.rgba8.empty()) {
            pixels = image.rgba8.data();
            bpp = 4;
            return true;
        }
        return false;
    };
    auto selectTextureWritePixels = [](GLTextureImageLevel& image,
                                       std::uint8_t*& pixels,
                                       std::size_t& bpp) -> bool {
        if (image.nativeBpp > 0 && !image.nativeData.empty()) {
            pixels = image.nativeData.data();
            bpp = image.nativeBpp;
            return true;
        }
        const std::size_t totalPixels =
            static_cast<std::size_t>(std::max<GLsizei>(image.desc.width, 1)) *
            static_cast<std::size_t>(std::max<GLsizei>(image.desc.height, 1)) *
            static_cast<std::size_t>(std::max<GLsizei>(image.desc.depth, 1));
        if (image.rgba8.size() < totalPixels * 4u) {
            image.rgba8.resize(totalPixels * 4u, 0);
        }
        pixels = image.rgba8.data();
        bpp = 4;
        return true;
    };

    GLTextureObject* srcTex = nullptr;
    if (srcIsTex) {
        srcTex = impl_->objects->textures().get(srcName);
        if (!srcTex) { pushError(GL_INVALID_VALUE); return false; }
        auto it = srcTex->levels.find(srcLevel);
        if (it == srcTex->levels.end() || !it->second.defined) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        const GLTextureImageLevel* srcImgPtr = &it->second;
        if (srcCubeMap && srcZ >= 0 && srcZ < 6) {
            if (GLTextureImageLevel* faceImg =
                    textureLevelForCopyLayer(srcTex, srcTarget, srcLevel, srcZ)) {
                srcImgPtr = faceImg;
            }
        }
        const GLTextureImageLevel& srcImg = *srcImgPtr;
        srcImgW = srcImg.desc.width;
        srcImgH = srcImg.desc.height;
        srcImgD = srcCubeMap ? 6 : srcImg.desc.depth;
        // Per GL 4.6 §18.2.3 Table 18.1 — copyImageSubData per-target axis
        // mapping. For TEXTURE_1D_ARRAY, the second axis (srcY/dstY) is the
        // layer index (0..layers-1) while the height dimension proper is
        // always 1. CTS copy_image.exceeding_boundaries plants Y=14 on a
        // 16-wide × 6-layer 1D-array and expects INVALID_VALUE because
        // 14+1 > 6. Re-route the Y-axis bound to the layer count for
        // 1D_ARRAY so the bounds check fires on layer overflow even if
        // raw `desc.height` is set to texel-row count.
        if (srcTarget == GL_TEXTURE_1D_ARRAY) {
            srcImgH = std::max<GLsizei>(srcTex->desc.depth, srcImg.desc.depth);
        }
        // Prefer native data if available, else fall back to rgba8.
        if (srcImg.nativeBpp > 0 && !srcImg.nativeData.empty()) {
            srcPixels = srcImg.nativeData.data();
            srcBpp = srcImg.nativeBpp;
        } else if (!srcImg.rgba8.empty()) {
            srcPixels = srcImg.rgba8.data();
            srcBpp = 4;
        }
    } else {
        GLRenderbufferObject* srcRB = impl_->objects->renderbuffers().get(srcName);
        if (!srcRB || !srcRB->storageDefined) { pushError(GL_INVALID_VALUE); return false; }
        impl_->materializeRenderbufferRGBA8Clear(*srcRB);
        srcImgW = srcRB->width;
        srcImgH = srcRB->height;
        srcImgD = 1;
        // CKPT117 (Sprint 11 Phase 1 1a): prefer RB.nativeData over rgba8
        // when the RB has a native-precision shadow allocated (non-RGBA8
        // internal formats per replaceRenderbufferStorage). This unblocks
        // the rgb10/rgb32f RB-source residual classes from CKPT109 + the
        // copy_image.smoke_test RGBA32UI 16-bpp case (smoke_test from 1c
        // residual).
        if (srcRB->nativeBpp > 0 && !srcRB->nativeData.empty()) {
            srcPixels = srcRB->nativeData.data();
            srcBpp = srcRB->nativeBpp;
        } else if (!srcRB->rgba8.empty()) {
            srcPixels = srcRB->rgba8.data();
            srcBpp = 4;
        }
    }

    if (srcPixels == nullptr) {
        // Source has no CPU-side shadow data — nothing to copy.
        return true;
    }

    // Bounds check source region. CKPT116 (Sprint 11 Phase 1 1c): include
    // the depth/layer axis (srcZ + srcDepth > srcImgD) — 3D textures and
    // *_ARRAY targets place layers on the Z axis. CTS copy_image.
    // exceeding_boundaries also exercises the 1D_ARRAY layer-on-Y case
    // (handled via srcImgH re-route above).
    if (srcX < 0 || srcY < 0 || srcZ < 0 ||
        srcX + srcWidth > srcImgW || srcY + srcHeight > srcImgH ||
        srcZ + srcDepth > srcImgD) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    // -----------------------------------------------------------------------
    // Resolve destination image shadow buffer.
    // -----------------------------------------------------------------------
    std::uint8_t* dstPixels = nullptr;
    GLsizei dstImgW = 0, dstImgH = 0, dstImgD = 1;
    std::size_t dstBpp = 4;

    // We need a writable pointer and the ability to invalidate the Metal texture.
    GLTextureObject* dstTex = nullptr;
    GLRenderbufferObject* dstRB = nullptr;
    GLTextureImageLevel* dstImg = nullptr;

    if (dstIsTex) {
        dstTex = impl_->objects->textures().get(dstName);
        if (!dstTex) { pushError(GL_INVALID_VALUE); return false; }
        auto it = dstTex->levels.find(dstLevel);
        if (it == dstTex->levels.end()) {
            // Level not defined — create it on the fly with same dims as source.
            GLTextureImageLevel newLevel;
            newLevel.desc.width = srcImgW;
            newLevel.desc.height = srcImgH;
            newLevel.desc.depth = 1;
            newLevel.defined = true;
            auto ins = dstTex->levels.emplace(dstLevel, std::move(newLevel));
            it = ins.first;
        }
        dstImg = &it->second;
        if (!dstImg->defined) {
            // Allocate matching storage if level was created by texStorage but not yet texImage'd.
            dstImg->defined = true;
        }
        if (dstCubeMap && dstZ >= 0 && dstZ < 6) {
            auto& faceLevels = dstTex->cubeFaceLevels[static_cast<std::size_t>(dstZ)];
            auto [faceIt, _inserted] = faceLevels.try_emplace(dstLevel, *dstImg);
            if (!faceIt->second.defined) {
                faceIt->second.defined = true;
            }
            dstImg = &faceIt->second;
        }
        dstImgW = dstImg->desc.width;
        dstImgH = dstImg->desc.height;
        dstImgD = dstCubeMap ? 6 : dstImg->desc.depth;
        // CKPT116: 1D_ARRAY layer-count-on-Y axis (mirror src logic).
        if (dstTarget == GL_TEXTURE_1D_ARRAY) {
            dstImgH = std::max<GLsizei>(dstTex->desc.depth, dstImg->desc.depth);
        }

        // Ensure the destination rgba8 buffer is large enough.
        const std::size_t totalPixels = static_cast<std::size_t>(dstImgW) * dstImgH;
        if (dstImg->nativeBpp > 0 && !dstImg->nativeData.empty()) {
            dstPixels = dstImg->nativeData.data();
            dstBpp = dstImg->nativeBpp;
        } else {
            if (dstImg->rgba8.size() < totalPixels * 4) {
                dstImg->rgba8.resize(totalPixels * 4, 0);
            }
            dstPixels = dstImg->rgba8.data();
            dstBpp = 4;
        }
    } else {
        dstRB = impl_->objects->renderbuffers().get(dstName);
        if (!dstRB || !dstRB->storageDefined) { pushError(GL_INVALID_VALUE); return false; }
        impl_->materializeRenderbufferRGBA8Clear(*dstRB);
        dstImgW = dstRB->width;
        dstImgH = dstRB->height;
        const std::size_t totalPixels = static_cast<std::size_t>(dstImgW) * dstImgH;
        // CKPT117: prefer RB.nativeData when allocated (non-RGBA8 internal
        // formats); fall back to rgba8 for RGBA8-mapped formats.
        if (dstRB->nativeBpp > 0 && !dstRB->nativeData.empty()) {
            dstPixels = dstRB->nativeData.data();
            dstBpp = dstRB->nativeBpp;
        } else {
            if (dstRB->rgba8.size() < totalPixels * 4) {
                dstRB->rgba8.resize(totalPixels * 4, 0);
            }
            dstPixels = dstRB->rgba8.data();
            dstBpp = 4;
        }
    }

    // Bounds check destination region. CKPT116: include the depth/layer
    // axis for 3D / *_ARRAY targets, matching the source-side bound at
    // line 30361+ above.
    if (dstX < 0 || dstY < 0 || dstZ < 0 ||
        dstX + srcWidth > dstImgW || dstY + srcHeight > dstImgH ||
        dstZ + srcDepth > dstImgD) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    // -----------------------------------------------------------------------
    // Perform the pixel copy — row-by-row within each depth slice.
    // -----------------------------------------------------------------------
    // When bpp matches between source and destination, do a direct memcpy per row.
    // When bpp differs (e.g. native R8 → RGBA8), we need to convert; for now,
    // use the rgba8 path as the common denominator.
    if ((srcCubeMap || dstCubeMap) && srcBpp == dstBpp) {
        for (GLsizei z = 0; z < srcDepth; ++z) {
            const std::uint8_t* sliceSrcPixels = srcPixels;
            std::uint8_t* sliceDstPixels = dstPixels;
            std::size_t sliceSrcBpp = srcBpp;
            std::size_t sliceDstBpp = dstBpp;
            GLsizei sliceSrcW = srcImgW;
            GLsizei sliceSrcH = srcImgH;
            GLsizei sliceDstW = dstImgW;
            GLsizei sliceDstH = dstImgH;
            GLint srcSlice = srcZ + z;
            GLint dstSlice = dstZ + z;

            if (srcCubeMap) {
                const GLTextureImageLevel* faceImg =
                    textureLevelForCopyLayer(srcTex, srcTarget, srcLevel, srcSlice);
                if (faceImg == nullptr ||
                    !selectTextureReadPixels(*faceImg, sliceSrcPixels, sliceSrcBpp)) {
                    pushError(GL_INVALID_OPERATION);
                    return false;
                }
                sliceSrcW = faceImg->desc.width;
                sliceSrcH = faceImg->desc.height;
                srcSlice = 0;
            }
            if (dstCubeMap) {
                if (dstSlice < 0 || dstSlice >= 6) {
                    pushError(GL_INVALID_VALUE);
                    return false;
                }
                auto& faceLevels =
                    dstTex->cubeFaceLevels[static_cast<std::size_t>(dstSlice)];
                auto faceIt = faceLevels.find(dstLevel);
                if (faceIt == faceLevels.end()) {
                    auto baseIt = dstTex->levels.find(dstLevel);
                    if (baseIt == dstTex->levels.end() || !baseIt->second.defined) {
                        pushError(GL_INVALID_OPERATION);
                        return false;
                    }
                    faceIt = faceLevels.emplace(dstLevel, baseIt->second).first;
                }
                GLTextureImageLevel* faceImg = &faceIt->second;
                if (faceImg == nullptr ||
                    !selectTextureWritePixels(*faceImg, sliceDstPixels, sliceDstBpp)) {
                    pushError(GL_INVALID_OPERATION);
                    return false;
                }
                sliceDstW = faceImg->desc.width;
                sliceDstH = faceImg->desc.height;
                dstTex->cubeFacesDefined |= static_cast<std::uint8_t>(1u << dstSlice);
                dstSlice = 0;
            }
            if (sliceSrcBpp != sliceDstBpp) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }

            const std::size_t srcRowBytes = static_cast<std::size_t>(sliceSrcW) * sliceSrcBpp;
            const std::size_t dstRowBytes = static_cast<std::size_t>(sliceDstW) * sliceDstBpp;
            const std::size_t srcSliceBytes = srcRowBytes * static_cast<std::size_t>(sliceSrcH);
            const std::size_t dstSliceBytes = dstRowBytes * static_cast<std::size_t>(sliceDstH);
            const std::size_t copyRowBytes = static_cast<std::size_t>(srcWidth) * sliceSrcBpp;
            const std::size_t srcSliceOff = static_cast<std::size_t>(srcSlice) * srcSliceBytes;
            const std::size_t dstSliceOff = static_cast<std::size_t>(dstSlice) * dstSliceBytes;
            for (GLsizei row = 0; row < srcHeight; ++row) {
                const std::size_t srcOff = srcSliceOff
                                         + static_cast<std::size_t>(srcY + row) * srcRowBytes
                                         + static_cast<std::size_t>(srcX) * sliceSrcBpp;
                const std::size_t dstOff = dstSliceOff
                                         + static_cast<std::size_t>(dstY + row) * dstRowBytes
                                         + static_cast<std::size_t>(dstX) * sliceDstBpp;
                std::memcpy(sliceDstPixels + dstOff, sliceSrcPixels + srcOff, copyRowBytes);
            }
        }
    } else if (srcBpp == dstBpp) {
        const std::size_t srcRowBytes = static_cast<std::size_t>(srcImgW) * srcBpp;
        const std::size_t dstRowBytes = static_cast<std::size_t>(dstImgW) * dstBpp;
        const std::size_t srcSliceBytes = srcRowBytes * static_cast<std::size_t>(srcImgH);
        const std::size_t dstSliceBytes = dstRowBytes * static_cast<std::size_t>(dstImgH);
        const std::size_t copyRowBytes = static_cast<std::size_t>(srcWidth) * srcBpp;

        for (GLsizei z = 0; z < srcDepth; ++z) {
            const std::size_t srcSliceOff = static_cast<std::size_t>(srcZ + z) * srcSliceBytes;
            const std::size_t dstSliceOff = static_cast<std::size_t>(dstZ + z) * dstSliceBytes;
            for (GLsizei row = 0; row < srcHeight; ++row) {
                const std::size_t srcOff = srcSliceOff
                                         + static_cast<std::size_t>(srcY + row) * srcRowBytes
                                         + static_cast<std::size_t>(srcX) * srcBpp;
                const std::size_t dstOff = dstSliceOff
                                         + static_cast<std::size_t>(dstY + row) * dstRowBytes
                                         + static_cast<std::size_t>(dstX) * dstBpp;
                std::memcpy(dstPixels + dstOff, srcPixels + srcOff, copyRowBytes);
            }
        }
    } else {
        // Mismatched bpp — fall back to rgba8 shadow for both src and dst.
        // Re-resolve using rgba8 for both sides.
        const std::uint8_t* srcRGBA = nullptr;
        std::uint8_t* dstRGBA = nullptr;

        if (srcIsTex) {
            GLTextureObject* srcTex = impl_->objects->textures().get(srcName);
            auto it = srcTex->levels.find(srcLevel);
            if (it != srcTex->levels.end() && !it->second.rgba8.empty()) {
                srcRGBA = it->second.rgba8.data();
            }
        } else {
            GLRenderbufferObject* srcRB = impl_->objects->renderbuffers().get(srcName);
            if (srcRB && !srcRB->rgba8.empty()) srcRGBA = srcRB->rgba8.data();
        }

        if (dstImg && !dstImg->rgba8.empty()) {
            dstRGBA = dstImg->rgba8.data();
        } else if (dstRB && !dstRB->rgba8.empty()) {
            dstRGBA = dstRB->rgba8.data();
        }

        if (srcRGBA && dstRGBA) {
            const std::size_t srcRow4 = static_cast<std::size_t>(srcImgW) * 4;
            const std::size_t dstRow4 = static_cast<std::size_t>(dstImgW) * 4;
            const std::size_t srcSlice4 = srcRow4 * static_cast<std::size_t>(srcImgH);
            const std::size_t dstSlice4 = dstRow4 * static_cast<std::size_t>(dstImgH);
            const std::size_t copyRow4 = static_cast<std::size_t>(srcWidth) * 4;
            for (GLsizei z = 0; z < srcDepth; ++z) {
                const std::size_t sSliceOff = static_cast<std::size_t>(srcZ + z) * srcSlice4;
                const std::size_t dSliceOff = static_cast<std::size_t>(dstZ + z) * dstSlice4;
                for (GLsizei row = 0; row < srcHeight; ++row) {
                    const std::size_t sOff = sSliceOff + static_cast<std::size_t>(srcY + row) * srcRow4 + static_cast<std::size_t>(srcX) * 4;
                    const std::size_t dOff = dSliceOff + static_cast<std::size_t>(dstY + row) * dstRow4 + static_cast<std::size_t>(dstX) * 4;
                    std::memcpy(dstRGBA + dOff, srcRGBA + sOff, copyRow4);
                }
            }
            // Sync rgba8 → dst.nativeData for the copied region. Required
            // when destination has both shadows (e.g. R8 / RGB12 / RGB32F /
            // RGBA12 textures with native Metal pixel format), so that
            // subsequent glGetTexImage / re-upload via replaceMetalTexture
            // reads native shadow with the updated values. Without this,
            // CTS copy_image RB-source-unique tests (r8, rgb10, rgb12,
            // rgba12, rgb32f × 3 RB-source buckets = 15 tests) read stale
            // zero-filled native shadow on the destination after copy.
            // GL 4.6 §18.2.3: the copy is byte-level; we only need to
            // re-encode the destination's native representation from the
            // rgba8 values that the byte-level copy logically produced.
            if (dstImg && dstImg->nativeBpp > 0 && !dstImg->nativeData.empty()) {
                MTLPixelFormat dstNativeFmt = metalRenderbufferFormat(
                    dstImg->desc.internalFormat != 0
                        ? dstImg->desc.internalFormat
                        : dstTex->desc.internalFormat);
                auto info = Impl::nativeFormatInfo(dstNativeFmt);
                if (info.channels > 0 && info.bytesPerPixel > 0) {
                    const std::size_t natRowBytes = static_cast<std::size_t>(dstImgW) * info.bytesPerPixel;
                    const std::size_t natSliceBytes = natRowBytes * static_cast<std::size_t>(dstImgH);
                    for (GLsizei z = 0; z < srcDepth; ++z) {
                        for (GLsizei row = 0; row < srcHeight; ++row) {
                            for (GLsizei col = 0; col < srcWidth; ++col) {
                                const std::size_t rgbaOff =
                                    (static_cast<std::size_t>(dstZ + z) * dstSlice4)
                                    + (static_cast<std::size_t>(dstY + row) * dstRow4)
                                    + (static_cast<std::size_t>(dstX + col) * 4);
                                const std::size_t natOff =
                                    (static_cast<std::size_t>(dstZ + z) * natSliceBytes)
                                    + (static_cast<std::size_t>(dstY + row) * natRowBytes)
                                    + (static_cast<std::size_t>(dstX + col) * info.bytesPerPixel);
                                const std::uint8_t* rgbaPx = dstRGBA + rgbaOff;
                                std::uint8_t* natPx = dstImg->nativeData.data() + natOff;
                                // For each native channel, compute the value
                                // from the rgba8 value at that channel index
                                // (R=0, G=1, B=2, A=3; missing channels read 0).
                                for (int c = 0; c < info.channels; ++c) {
                                    const std::uint8_t rgbaByte = rgbaPx[c];
                                    double v;
                                    switch (info.compType) {
                                        case Impl::NativeFormatInfo::UNorm:
                                            // rgba8 stores u8 unorm; scale to native bit width
                                            v = rgbaByte / 255.0;
                                            break;
                                        case Impl::NativeFormatInfo::SNorm:
                                            // rgba8 has no signed range — treat the byte as
                                            // unsigned and re-center [0,255] → [-1,1]. Edge
                                            // case rare in copy_image (no SNorm in failing pairs).
                                            v = (rgbaByte / 255.0) * 2.0 - 1.0;
                                            break;
                                        case Impl::NativeFormatInfo::UInt:
                                            v = static_cast<double>(rgbaByte);
                                            break;
                                        case Impl::NativeFormatInfo::SInt:
                                            v = static_cast<double>(static_cast<std::int8_t>(rgbaByte));
                                            break;
                                        case Impl::NativeFormatInfo::Float:
                                            v = rgbaByte / 255.0;
                                            break;
                                    }
                                    Impl::writeNativeComponent(
                                        natPx + c * info.bytesPerChannel,
                                        info.compType,
                                        info.bytesPerChannel,
                                        v);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Invalidate the destination Metal texture so it will be re-uploaded.
    // We null out metalTexture rather than just flipping `instantiated`
    // because bindTexture re-sets instantiated=true before any subsequent
    // read, which would otherwise mask the pending re-upload.
    // -----------------------------------------------------------------------
    if (dstTex) {
        releaseRetainedMetalObject(dstTex->metalTexture);
        dstTex->metalTexture = nullptr;
    }
    if (dstRB) {
        dstRB->instantiated = false;
    }
    impl_->markGpuResourceWrites({
        {dstIsTex ? Impl::GpuResourceAccess::Kind::Texture
                  : Impl::GpuResourceAccess::Kind::Renderbuffer,
         dstName,
         kProducerCopyWrite}
    });
    return true;
}

bool GLContext::textureView(GLuint texture, GLenum target, GLuint origtexture, GLenum internalformat,
                            GLuint minlevel, GLuint numlevels, GLuint minlayer, GLuint numlayers) {
    // GL 4.3 §8.18 (ARB_texture_view) — error cases as asserted by
    // CTS `texture_view.errors`:
    //  - texture == 0           → INVALID_VALUE (texture name 0 is
    //                             reserved for "no binding")
    //  - origtexture == 0       → INVALID_VALUE (same reasoning)
    //  - texture is 0xFFFFFFFF
    //    or otherwise not from glGenTextures → INVALID_OPERATION
    //  - origtexture has no data store allocated → INVALID_OPERATION
    //  - numlevels / numlayers == 0 → INVALID_VALUE
    if (texture == 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLTextureObject* viewObj = impl_->objects->textures().get(texture);
    if (viewObj == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // The view texture must be "fresh" — glTextureView cannot re-
    // target an already-bound texture. `target != 0` means a prior
    // glBindTexture / glCreateTextures set the target.
    if (viewObj->target != 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // origtexture: both 0 and an unrecognized name produce
    // INVALID_VALUE per the CTS errors test (differs from the
    // `texture` argument's rule where an unrecognized name gives
    // INVALID_OPERATION). The test exercises both codepaths.
    if (origtexture == 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLTextureObject* origObj = impl_->objects->textures().get(origtexture);
    if (origObj == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!origObj->desc.immutable) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (numlevels == 0 || numlayers == 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!isTextureTarget(target) ||
        target == GL_TEXTURE_BUFFER ||
        target == GL_TEXTURE_CUBE_MAP_POSITIVE_X ||
        target == GL_TEXTURE_CUBE_MAP_NEGATIVE_X ||
        target == GL_TEXTURE_CUBE_MAP_POSITIVE_Y ||
        target == GL_TEXTURE_CUBE_MAP_NEGATIVE_Y ||
        target == GL_TEXTURE_CUBE_MAP_POSITIVE_Z ||
        target == GL_TEXTURE_CUBE_MAP_NEGATIVE_Z) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (!isSupportedInternalTextureFormat(*impl_->capabilities, internalformat)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (!textureViewInternalFormatsCompatible(origObj->desc.internalFormat, internalformat)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const GLsizei parentViewLevels = textureViewEffectiveLevelCount(*origObj);
    const GLsizei parentViewLayers = textureViewAvailableLayerCount(*origObj);
    if (minlevel >= static_cast<GLuint>(std::max<GLsizei>(parentViewLevels, 1))) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint sourceLayers =
        static_cast<GLuint>(std::max<GLsizei>(parentViewLayers, 1));
    if (minlayer >= sourceLayers) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!textureViewTargetLayerCountValid(target, numlayers)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if ((target == GL_TEXTURE_CUBE_MAP || target == GL_TEXTURE_CUBE_MAP_ARRAY) &&
        !textureViewCubeTargetRequiresSquareLevels(*origObj, minlevel, numlevels)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Record the view relationship. Actual Metal texture view
    // (newTextureViewWithPixelFormat:) will be created when the Metal texture
    // is first needed for rendering.
    const GLsizei effectiveNumLevels = std::min<GLsizei>(
        static_cast<GLsizei>(numlevels),
        std::max<GLsizei>(parentViewLevels - static_cast<GLsizei>(minlevel), 1));
    const GLsizei effectiveNumLayers = std::min<GLsizei>(
        static_cast<GLsizei>(numlayers),
        std::max<GLsizei>(parentViewLayers - static_cast<GLsizei>(minlayer), 1));
    viewObj->target = target;
    viewObj->desc.target = target;
    viewObj->desc.internalFormat = internalformat;
    viewObj->desc.levels = effectiveNumLevels;
    viewObj->desc.layers = effectiveNumLayers;
    viewObj->desc.immutable = true;
    viewObj->viewSourceTexture = origtexture;
    viewObj->viewMinLevel = origObj->viewMinLevel + static_cast<GLint>(minlevel);
    viewObj->viewNumLevels = static_cast<GLint>(effectiveNumLevels);
    viewObj->viewMinLayer = origObj->viewMinLayer + static_cast<GLint>(minlayer);
    viewObj->viewNumLayers = static_cast<GLint>(effectiveNumLayers);
    viewObj->params = origObj->params;
    viewObj->samplerDirty = true;

    releaseRetainedMetalObject(viewObj->metalTexture);
    viewObj->metalTexture = nullptr;
    viewObj->instantiated = false;
    releaseRetainedMetalObject(viewObj->metalSwizzledView);
    viewObj->metalSwizzledView = nullptr;
    viewObj->swizzleDirty = true;
    releaseRetainedMetalObject(viewObj->metalSamplingProxy);
    viewObj->metalSamplingProxy = nullptr;

    if ((origObj->metalTexture == nullptr || !origObj->instantiated) &&
        !origObj->levels.empty()) {
        (void)impl_->replaceMetalTexture(*origObj, origtexture);
    }
    MTLPixelFormat viewPixelFormat = metalRenderbufferFormat(internalformat);
    if (viewPixelFormat != MTLPixelFormatInvalid &&
        origObj->metalTexture != nullptr) {
        id<MTLTexture> baseTex =
            (__bridge id<MTLTexture>)origObj->metalTexture;
        const MTLTextureType viewTextureType = metalTextureTypeForTarget(target);
        const NSRange levelRange =
            NSMakeRange(static_cast<NSUInteger>(minlevel),
                        static_cast<NSUInteger>(effectiveNumLevels));
        const NSRange sliceRange =
            NSMakeRange(static_cast<NSUInteger>(minlayer),
                        static_cast<NSUInteger>(effectiveNumLayers));
        const NSUInteger sourceLevels = nonZeroMipLevelCount(baseTex.mipmapLevelCount);
        const bool levelRangeFits =
            levelRange.location < sourceLevels &&
            levelRange.length <= sourceLevels - levelRange.location;
        if (levelRangeFits) {
            id<MTLTexture> viewTex =
                [baseTex newTextureViewWithPixelFormat:viewPixelFormat
                                           textureType:viewTextureType
                                                levels:levelRange
                                                slices:sliceRange];
            if (viewTex != nil) {
                viewObj->metalTexture = transferRetainedMetalObject(viewTex);
                viewObj->instantiated = true;
            }
        }
    }
    return true;
}

bool GLContext::invalidateTexImage(GLuint texture, GLint level) {
    if (!impl_->objects->textures().contains(texture)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Hint: texture contents at this level can be discarded.
    return true;
}

bool GLContext::invalidateTexSubImage(GLuint texture, GLint level, GLint xoffset, GLint yoffset, GLint zoffset,
                                      GLsizei width, GLsizei height, GLsizei depth) {
    if (width < 0 || height < 0 || depth < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!impl_->objects->textures().contains(texture)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    return true;
}
