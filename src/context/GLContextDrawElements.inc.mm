// This file is textually included by GLContextDraw.inc.mm. Do not compile it directly.
// It contains the GLContext drawElements method body split out for navigation only.

#line 8 "/private/tmp/appgl-bug3-clean/src/context/GLContextDraw.inc.mm" // Preserve source identity so this relocation stays codegen-neutral; __FILE__/__LINE__/debug-info intentionally report the original GLContextDraw.inc.mm.
bool GLContext::drawElements(GLenum mode, GLsizei count, GLenum type, const void* indices, GLuint drawID) {
    GLDrawProfileScope drawProfile(impl_->drawPathProfile);
    if (!isValidDrawMode(mode)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (count == 0) {
        return true;
    }
    if (!isSupportedElementIndexType(type)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (recordDisplayListClientArrayDraw(mode, 0, count, indices, type, "glDrawElements")) {
        return true;
    }
    if (!impl_->state->validateForDraw()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §2.3.3 — conditional render predicate.
    if (impl_->shouldSkipDrawForConditionalRender()) {
        return true;
    }
    const GLuint currentProgramNameForLegacyTf = impl_->state->currentProgram();
    const GLProgramObject* currentProgramForLegacyTf =
        currentProgramNameForLegacyTf != 0
            ? impl_->objects->programs().get(currentProgramNameForLegacyTf)
            : nullptr;
    const bool requiresTranslatedLegacyTfCapture =
        isTransformFeedbackActive() &&
        currentProgramForLegacyTf != nullptr &&
        currentProgramForLegacyTf->linked &&
        currentProgramForLegacyTf->hasTranslatedPipeline &&
        !currentProgramForLegacyTf->transformFeedbackVaryingNames.empty();
    const bool routeLegacyClientArrayThroughTranslatedProgram = [&]() {
        if (requiresTranslatedLegacyTfCapture ||
            currentProgramForLegacyTf == nullptr ||
            !currentProgramForLegacyTf->linked ||
            !currentProgramForLegacyTf->hasTranslatedPipeline ||
            currentProgramForLegacyTf->hasTessellation ||
            currentProgramForLegacyTf->gsPresent ||
            !programAttachedShaderSourceUsesToken(
                *currentProgramForLegacyTf, *impl_->objects, "gl_VertexID")) {
            return false;
        }
        const auto& vertexArray = impl_->legacyVertexArray;
        if (!vertexArray.enabled ||
            (vertexArray.pointer == nullptr && vertexArray.bufferName == 0) ||
            vertexArray.type != GL_FLOAT ||
            vertexArray.size < 2 || vertexArray.size > 4) {
            return false;
        }
        bool hasPositionInput = false;
        for (const auto& input :
             currentProgramForLegacyTf->vertexReflection.vertexInputs) {
            const GLuint location = input.location;
            const GLuint sourceLocation = input.sourceLocation;
            const bool supportedLocation =
                location == 0 || location == 1 || location == 3 || location == 8 ||
                sourceLocation == 0 || sourceLocation == 1 ||
                sourceLocation == 3 || sourceLocation == 8;
            if (input.containsFp64 || !supportedLocation) {
                return false;
            }
            hasPositionInput = hasPositionInput ||
                location == 0 || sourceLocation == 0;
        }
        if (!hasPositionInput) {
            return false;
        }
        const GLVertexArrayObject* currentVao =
            impl_->currentVertexArrayOrDefault();
        if (currentVao != nullptr) {
            for (const auto& input :
                 currentProgramForLegacyTf->vertexReflection.vertexInputs) {
                if (input.sourceLocation < currentVao->attributes.size() &&
                    currentVao->attributes[input.sourceLocation].enabled) {
                    return false;
                }
            }
        }
        const auto& raster = impl_->state->rasterState();
        return raster.polygonModeFront == GL_FILL &&
            raster.polygonModeBack == GL_FILL;
    }();
    if (!requiresTranslatedLegacyTfCapture &&
        !routeLegacyClientArrayThroughTranslatedProgram &&
        encodeLegacyClientArrayDraw(mode, 0, count, indices, type,
                                    "glDrawElements")) {
        return true;
    }
    if (!impl_->validateCurrentProgramPipelineForDraw()) {
        return false;
    }
    auto currentProgramMultiviewNumViews = [&]() -> GLsizei {
        const GLuint programName = impl_->state->currentProgram();
        if (programName != 0) {
            const GLProgramObject* program =
                impl_->objects->programs().get(programName);
            return (program != nullptr && program->linked)
                ? std::max<GLsizei>(program->ovrMultiviewNumViews, 0)
                : 0;
        }
        const GLuint pipelineName =
            impl_->state->currentProgramPipeline();
        const GLProgramPipelineObject* pipeline = pipelineName != 0
            ? impl_->objects->programPipelines().get(pipelineName)
            : nullptr;
        if (pipeline == nullptr || pipeline->vertexProgram == 0) {
            return 0;
        }
        const GLProgramObject* vertexProgram =
            impl_->objects->programs().get(pipeline->vertexProgram);
        return (vertexProgram != nullptr && vertexProgram->linked)
            ? std::max<GLsizei>(vertexProgram->ovrMultiviewNumViews, 0)
            : 0;
    };
    auto drawFramebufferMultiviewNumViews = [&]() -> GLsizei {
        const GLuint framebufferName =
            impl_->state->boundDrawFramebuffer();
        if (framebufferName == 0) {
            return 0;
        }
        const GLFramebufferObject* framebuffer =
            impl_->objects->framebuffers().get(framebufferName);
        if (framebuffer == nullptr || !framebuffer->instantiated) {
            return 0;
        }
        GLsizei viewCount = 0;
        for (const auto& [attachmentPoint, attachment] :
             framebuffer->attachments) {
            (void)attachmentPoint;
            if (attachment.multiview &&
                attachment.kind == GLFramebufferAttachment::Kind::Texture &&
                attachment.object != 0) {
                viewCount = std::max<GLsizei>(
                    viewCount, std::max<GLsizei>(attachment.numViews, 0));
            }
        }
        return viewCount;
    };
    {
        const GLsizei shaderViews = currentProgramMultiviewNumViews();
        const GLsizei framebufferViews = drawFramebufferMultiviewNumViews();
        if (shaderViews != framebufferViews &&
            (shaderViews > 1 || framebufferViews > 1)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    {
        const GLuint progName = impl_->state->currentProgram();
        const GLuint pipelineName = impl_->state->currentProgramPipeline();
        const GLProgramObject* p = nullptr;
        if (progName != 0) {
            p = impl_->objects->programs().get(progName);
        }
        if (p != nullptr && p->gsPresent && !p->hasTessellation &&
            !isDrawModeCompatibleWithGs(mode, p->gsInputTopology)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        if (progName == 0) {
            const GLProgramPipelineObject* ppo = (pipelineName != 0)
                ? impl_->objects->programPipelines().get(pipelineName)
                : nullptr;
            const GLuint vsProg = ppo ? ppo->vertexProgram : 0;
            const GLuint gsProg = ppo ? ppo->geometryProgram : 0;
            if (gsProg != 0 && vsProg == 0) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            if (mode == GL_PATCHES && ppo != nullptr) {
                const bool hasTcs = ppo->tessControlProgram != 0;
                const bool hasTes = ppo->tessEvalProgram != 0;
                if (hasTcs && !hasTes) {
                    pushError(GL_INVALID_OPERATION);
                    return false;
                }
            }
            if (gsProg != 0) {
                const GLProgramObject* gsP = impl_->objects->programs().get(gsProg);
                bool pipelineHasTess = false;
                if (ppo != nullptr) {
                    for (GLuint ps : {ppo->tessControlProgram, ppo->tessEvalProgram}) {
                        if (ps == 0) continue;
                        const GLProgramObject* tsP = impl_->objects->programs().get(ps);
                        if (tsP != nullptr && tsP->hasTessellation) {
                            pipelineHasTess = true;
                            break;
                        }
                    }
                }
                if (gsP != nullptr && gsP->gsPresent && !pipelineHasTess &&
                    !isDrawModeCompatibleWithGs(mode, gsP->gsInputTopology)) {
                    pushError(GL_INVALID_OPERATION);
                    return false;
                }
            }
        }
    }
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::Draw);
    drawProfile.mark(GLDrawProfileBucket::Validation);
    // GL 4.6 §22.1 / §22.3 — pipeline-stats counter update for non-GS
    // indexed draws. GS path is handled by writeGsXfbAndCheckDiscard.
    // Sprint 8 #9-A (CKPT67): VS-only TF capture path (CKPT59 helper)
    // also calls writeGsXfbAndCheckDiscard which advances queries
    // with TF-buffer-bounded primsWritten. Skip the unconditional
    // pre-update when the VS-only-TF helper will engage downstream
    // (transformFeedbackActive + TF varyings + no GS/tess emul) so
    // the bounded primsWritten doesn't double-count atop the
    // unbounded `count`-based pre-update.
    {
        const GLuint progName = impl_->state->currentProgram();
        const GLProgramObject* p = progName != 0
            ? impl_->objects->programs().get(progName)
            : nullptr;
        const bool willHitVsOnlyTf =
            p != nullptr &&
            isTransformFeedbackActive() &&  // CKPT85: per-bound-object
            !p->transformFeedbackVaryingNames.empty() &&
            !p->geometryEmulated &&
            !p->tessellationEmulated &&
            !p->tessellationInterpreted;
        if ((p == nullptr || !p->gsPresent) && !willHitVsOnlyTf) {
            const GLsizei restartSkip = impl_->countRestartIndices(type, indices, count);
            impl_->updatePrimitiveCountersForNonGsDraw(mode, count, 1, restartSkip);
        }
    }

    if (impl_->frameGraph == nullptr) {
        return false;
    }
    // Size the drawable before flushing the clear — see glDrawArrays for the
    // rationale.
    impl_->ensureDefaultDrawableForViewportExtent();
    impl_->encodePendingWork();
    drawProfile.mark(GLDrawProfileBucket::DrawablePrep);

    // Resolve element buffer early — needed by both translated and solid paths.
    GLuint vaoName = 0;
    GLVertexArrayObject* vao = nullptr;
    GLuint elementBufferName = 0;
    GLenum effectiveType = type;
    const void* effectivePtr = nullptr;
    GLBufferObject* elementBuffer = nullptr;
    std::size_t indexOffset = 0;
    {
        GLDrawDetailScope detail(
            impl_->drawDetailProfile,
            GLDrawDetailBucket::TranslatedIndexRangeValidation);
        vaoName = impl_->state->boundVertexArray();
        vao = (vaoName != 0)
            ? impl_->objects->vertexArrays().get(vaoName)
            : (appglCompatProfileEnabled()
                ? impl_->currentVertexArrayOrDefault()
                : nullptr);
        if (vao == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        elementBufferName = vao->elementArrayBuffer;

        // Sprint 7 #9 (CKPT65): GL 2.x compatibility — when no
        // GL_ELEMENT_ARRAY_BUFFER is bound, the `indices` parameter is a
        // client-side pointer to `count` indices in CPU memory (not a
        // buffer offset). Materialize the data into a thread-local scratch
        // buffer, applying GL_UNSIGNED_BYTE→GL_UNSIGNED_SHORT promotion
        // the same way the buffer-bound path does. CTS
        // `transform_feedback.{capture,query,discard}_vertex_*` tests use
        // this pattern with a stack-allocated GLuint[] passed directly to
        // glDrawElements.
        thread_local std::vector<std::uint8_t> clientIndexScratch;
        if (elementBufferName == 0) {
            if (count > 0 && indices == nullptr) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            if (count > 0) {
                IndexExpansionResult result = expandElementIndices(count, type, indices);
                if (!result.ok) {
                    pushError(result.error);
                    return false;
                }
                clientIndexScratch = std::move(result.bytes);
                effectivePtr = clientIndexScratch.data();
                effectiveType = result.outputType;
                if (elementIndexTypeNeedsExpansion(type)) {
                    logIndexExpansionCostClass(
                        "drawElements-client", 0, type, effectiveType, count,
                        clientIndexScratch.size(), false, 0);
                }
            }
            // elementBuffer stays nullptr; indexOffset stays 0. Downstream
            // Metal-buffer-pass-through gates on `elementBuffer != nullptr`
            // so the client-side path naturally falls into the
            // CPU-staging-buffer branch.
        } else {
            elementBuffer = impl_->objects->buffers().get(elementBufferName);
            if (elementBuffer == nullptr || elementBuffer->shadowBytes.empty()) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }

            indexOffset = reinterpret_cast<std::uintptr_t>(indices);
            if (indexOffset > elementBuffer->shadowBytes.size()) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            const void* indexPtr = elementBuffer->shadowBytes.data() + indexOffset;

            // GL_UNSIGNED_BYTE is not supported natively by Metal; expandElementIndices
            // promotes to GL_UNSIGNED_SHORT. For UINT16/UINT32 we can pass through.
            //
            // ADV-10: cache the expanded index buffer on the GLBufferObject so
            // repeated drawElements calls with the same element buffer don't
            // re-allocate and re-widen on every draw.  The cache covers the
            // entire shadowBytes range (not per-offset subsets) and is
            // invalidated when the buffer data changes via glBufferData /
            // glBufferSubData (generation counter bump).
            effectivePtr = indexPtr;
            if (elementIndexTypeNeedsExpansion(type)) {
                const bool expansionCacheHit =
                    elementBuffer->cachedExpansionGeneration == elementBuffer->indexExpansionGeneration &&
                    !elementBuffer->cachedExpandedIndices.empty();
                // Rebuild cache if stale or absent.
                if (!expansionCacheHit) {
                    const GLsizei totalIndices = static_cast<GLsizei>(elementBuffer->shadowBytes.size());
                    IndexExpansionResult result = expandElementIndices(
                        totalIndices, type, elementBuffer->shadowBytes.data());
                    if (!result.ok) {
                        pushError(result.error);
                        return false;
                    }
                    elementBuffer->cachedExpandedIndices = std::move(result.bytes);
                    elementBuffer->cachedExpansionGeneration = elementBuffer->indexExpansionGeneration;
                    impl_->noteR5ExpandedIndexCacheRebuilt(*elementBuffer);
                }
                effectiveType = GL_UNSIGNED_SHORT;
                // Recompute offset: each source byte becomes 2 bytes (uint16).
                const std::size_t expandedOffset = indexOffset * sizeof(GLushort);
                effectivePtr = elementBuffer->cachedExpandedIndices.data() + expandedOffset;
                impl_->touchR5ExpandedIndexCache(*elementBuffer);
                logIndexExpansionCostClass(
                    "drawElements", elementBufferName, type, effectiveType,
                    static_cast<GLsizei>(elementBuffer->shadowBytes.size()),
                    elementBuffer->cachedExpandedIndices.size(), expansionCacheHit,
                    elementBuffer->cachedExpansionGeneration);
            }
        }
    }

    // Try the translated shader pipeline first (GPU-side vertex processing).
    // GL 4.6 §7.4 — prefer glUseProgram's program; fall back to the
    // active program pipeline's VS+FS merged onto its VS container
    // when only a pipeline is bound. Covers the CTS VAB tests that
    // drive separable programs through glCreateShaderProgramv +
    // glUseProgramStages without ever calling glUseProgram.
    GLuint programName = impl_->state->currentProgram();
    GLProgramObject* program = impl_->resolveDrawProgram(programName);
    const bool gsRasterExpected =
        !impl_->state->isEnabled(GL_RASTERIZER_DISCARD);
    {
        bool advancedBlendHandled = false;
        const bool advancedBlendOk =
            impl_->handleAdvancedBlendDraw(program, "glDrawElements", advancedBlendHandled);
        if (advancedBlendHandled) {
            return advancedBlendOk;
        }
    }
    if (impl_->state->boundDrawFramebuffer() == 0) {
        impl_->invalidateDefaultFramebufferShadow();
    }
    drawProfile.mark(GLDrawProfileBucket::ProgramResolve);

    std::vector<std::uint32_t> primitiveRestartIndices;
    GLenum drawElementsMode = mode;
    GLsizei drawElementsCount = count;
    GLenum drawElementsIndexType = effectiveType;
    const void* drawElementsIndexPtr = effectivePtr;
    const bool usePrimitiveRestartIndices = buildPrimitiveRestartExpandedElements(
        mode, type, effectiveType, effectivePtr, count, *impl_->state,
        primitiveRestartIndices, drawElementsMode);
    if (usePrimitiveRestartIndices) {
        drawElementsCount = static_cast<GLsizei>(primitiveRestartIndices.size());
        drawElementsIndexType = GL_UNSIGNED_INT;
        drawElementsIndexPtr = primitiveRestartIndices.empty()
            ? nullptr
            : primitiveRestartIndices.data();
        if (drawElementsCount == 0) {
            return true;
        }
    }
    if (routeLegacyClientArrayThroughTranslatedProgram) {
        if (impl_->encodeLegacyClientArrayTranslatedProgramDraw(
                drawElementsMode,
                drawElementsIndexPtr,
                drawElementsCount,
                drawElementsIndexType,
                "drawElements-legacy-logical-vertex-id")) {
            return true;
        }
        if (encodeLegacyClientArrayDraw(
                drawElementsMode, 0, drawElementsCount,
                drawElementsIndexPtr, drawElementsIndexType,
                "glDrawElements-translated-fallback")) {
            return true;
        }
    }
    std::vector<std::uint32_t> gsPrimitiveRestartIndices;
    GLenum gsDrawElementsMode = mode;
    GLsizei gsDrawElementsCount = count;
    GLenum gsDrawElementsIndexType = effectiveType;
    const void* gsDrawElementsIndexPtr = effectivePtr;
    const bool useGsPrimitiveRestartIndices =
        program != nullptr && program->geometryEmulated &&
        buildGsPrimitiveRestartExpandedElements(
            mode, type, effectiveType, effectivePtr, count, *impl_->state,
            gsPrimitiveRestartIndices, gsDrawElementsMode);
    if (useGsPrimitiveRestartIndices) {
        gsDrawElementsCount = static_cast<GLsizei>(gsPrimitiveRestartIndices.size());
        gsDrawElementsIndexType = GL_UNSIGNED_INT;
        gsDrawElementsIndexPtr = gsPrimitiveRestartIndices.empty()
            ? nullptr
            : gsPrimitiveRestartIndices.data();
        if (gsDrawElementsCount == 0) {
            return true;
        }
    }

    // Phase 3f-16: CPU TES emulation hook for drawElements. Mirrors
    // the drawArrays block but feeds the resolved index buffer into
    // emulateTessellationDraw so the VS pre-pass reads the indexed
    // VBO slots. Same short-circuit shape: rasterDiscard /
    // zero-vertex / encode. On ok=false (interpreter bailed per
    // 3f-15 or classifier rejected) we fall through to the GS-emul
    // path below, which in turn falls through to the legacy
    // translated pipeline.
    if (program != nullptr &&
        (program->tessellationEmulated || program->tessellationInterpreted) &&
        !program->geometryEmulated && count > 0) {
        std::vector<std::uint32_t> idx32;
        if (effectiveType == GL_UNSIGNED_INT) {
            idx32.assign(count, 0);
            std::memcpy(idx32.data(), effectivePtr, count * sizeof(std::uint32_t));
        } else if (effectiveType == GL_UNSIGNED_SHORT) {
            idx32.assign(count, 0);
            const std::uint16_t* src16 =
                static_cast<const std::uint16_t*>(effectivePtr);
            for (GLsizei i = 0; i < count; ++i) idx32[i] = src16[i];
        }
        impl_->compactRestartIndicesForPatchTess(type, idx32);
        if (!idx32.empty()) {
            const GLsizei tessCount = static_cast<GLsizei>(idx32.size());
            appgl::EmulatedDraw ted = appgl::emulateTessellationDraw(
                *program, *vao, *impl_->objects, *impl_->state,
                mode, tessCount, /*first=*/0, idx32.data());
            if (ted.ok) {
                if (impl_->writeGsXfbAndCheckDiscard(*program, ted)) return true;
                if (ted.vertexCount == 0) return true;
                if (impl_->encodeEmulatedGsDraw(*program, programName, ted)) return true;
            }
        }
    }

    // CPU GS emulation hook — mirrors drawArrays, but resolves
    // indices through the element buffer so vertex `i` reads VBO
    // slot `elementIndices[i]` instead of `first + i`. Scoped to
    // the TF-capture / rasterizer-discard case for now (that's
    // what KHR-GL46.geometry_shader.adjacency.*_indiced and the
    // primitive_counter tests exercise); a drawElements GS-emul
    // encode path with synthesised pass-through VS is a follow-up.
    if (program != nullptr && program->geometryEmulated && gsDrawElementsCount > 0) {
        const bool dcr4eExactNoLegacy =
            dcr4eRequiresExactCpuGsNoLegacyFallback(
                program, gsDrawElementsMode, isTransformFeedbackActive());
        // Resolve effectivePtr (uint16 / uint32) into a uint32 vector
        // scoped to this draw. Small allocation cost — CTS draws
        // never exceed a few hundred indices.
        std::vector<std::uint32_t> idx32(static_cast<std::size_t>(gsDrawElementsCount));
        if (gsDrawElementsIndexType == GL_UNSIGNED_INT) {
            const std::uint32_t* src32 =
                static_cast<const std::uint32_t*>(gsDrawElementsIndexPtr);
            std::memcpy(
                idx32.data(), src32,
                static_cast<std::size_t>(gsDrawElementsCount) * sizeof(std::uint32_t));
        } else if (gsDrawElementsIndexType == GL_UNSIGNED_SHORT) {
            const std::uint16_t* src16 =
                static_cast<const std::uint16_t*>(gsDrawElementsIndexPtr);
            for (GLsizei i = 0; i < gsDrawElementsCount; ++i) idx32[i] = src16[i];
        } else {
            // GL_UNSIGNED_BYTE never reaches here — elementIndex-
            // TypeNeedsExpansion promotes it to uint16 above.
            // Any other type falls through to the legacy draw path.
            idx32.clear();
        }

        if (!idx32.empty()) {
            const auto vsTexMap = impl_->buildSampledTextureMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            const auto gsTexMap = impl_->buildSampledTextureMap(
                program->geometrySpirv,
                &program->geometryReflection, *program);
            const auto vsImgMap = impl_->buildStorageImageMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            const auto gsImgMap = impl_->buildStorageImageMap(
                program->geometrySpirv,
                &program->geometryReflection, *program);
            appgl::EmulatedDraw priorStage;
            const bool hasTess = program->tessellationEmulated ||
                                 program->tessellationInterpreted;
            if (hasTess) {
                appgl::SampledTextureMap tcsSamMap, tcsImgMap;
                appgl::SampledTextureMap tesSamMap, tesImgMap;
                if (!program->tessControlSpirv.empty()) {
                    tcsSamMap = impl_->buildSampledTextureMap(
                        program->tessControlSpirv,
                        &program->tessControlReflection, *program);
                    tcsImgMap = impl_->buildStorageImageMap(
                        program->tessControlSpirv,
                        &program->tessControlReflection, *program);
                }
                if (!program->tessEvalSpirv.empty()) {
                    tesSamMap = impl_->buildSampledTextureMap(
                        program->tessEvalSpirv,
                        &program->tessEvalAsComputeReflection, *program);
                    tesImgMap = impl_->buildStorageImageMap(
                        program->tessEvalSpirv,
                        &program->tessEvalAsComputeReflection, *program);
                }
                std::vector<std::uint32_t> tessIdx32 = idx32;
                impl_->compactRestartIndicesForPatchTess(type, tessIdx32);
                if (!tessIdx32.empty()) {
                    const GLsizei tessCount =
                        static_cast<GLsizei>(tessIdx32.size());
                    priorStage = appgl::emulateTessellationDraw(
                        *program, *vao, *impl_->objects, *impl_->state,
                        gsDrawElementsMode, tessCount, /*first=*/0, tessIdx32.data(),
                        /*instanceCount=*/1, /*baseInstance=*/0,
                        tcsSamMap.empty() ? nullptr : &tcsSamMap,
                        tcsImgMap.empty() ? nullptr : &tcsImgMap,
                        tesSamMap.empty() ? nullptr : &tesSamMap,
                        tesImgMap.empty() ? nullptr : &tesImgMap,
                        vsTexMap.empty() ? nullptr : &vsTexMap,
                        vsImgMap.empty() ? nullptr : &vsImgMap);
                    if (!priorStage.ok && !priorStage.diagnostic.empty()) {
                        APPGL_LOG(SHADER, @"drawElements tess+GS: tess-emul: %s",
                                  priorStage.diagnostic.c_str());
                    }
                }
            }
            appgl::EmulatedDraw ed = appgl::emulateGeometryDraw(
                *program, *vao, *impl_->objects, *impl_->state,
                gsDrawElementsMode, gsDrawElementsCount, /*first=*/0, idx32.data(),
                /*instanceCount=*/1, /*baseInstance=*/0,
                vsTexMap.empty() ? nullptr : &vsTexMap,
                gsTexMap.empty() ? nullptr : &gsTexMap,
                vsImgMap.empty() ? nullptr : &vsImgMap,
                gsImgMap.empty() ? nullptr : &gsImgMap,
                (hasTess && priorStage.ok) ? &priorStage : nullptr);
            if (ed.ok) {
                if (impl_->writeGsXfbAndCheckDiscard(*program, ed)) {
                    return true;
                }
                if (ed.vertexCount == 0) return true;
                if (program->geometryEmulatedTransformFeedbackOnly) {
                    APPGL_LOG(SHADER,
                              @"drawElements GS-emul TF-only clip/cull path captured XFB; falling through to legacy raster");
                } else {
                    // Non-discard path — the expanded vertex buffer is
                    // already flat, so the encode is identical to
                    // drawArrays. This covers CTS rendering tests that
                    // use DRAW_ELEMENTS* variants.
                    if (impl_->encodeEmulatedGsDraw(*program, programName, ed)) {
                        return true;
                    }
                    if (dcr4eExactNoLegacy) {
                        appgl::AppGLSubmissionGroup fallbackGroup;
                        impl_->declareCpuGsFallbackSubmissionGroup(fallbackGroup);
                        return true;
                    }
                }
            } else {
                const std::string gsDiag = ed.diagnostic.empty()
                    ? "GS emulator returned ok=false without diagnostic"
                    : ed.diagnostic;
                APPGL_LOG(SHADER, @"drawElements GS-emul: %s", gsDiag.c_str());
                if (gsRasterExpected) {
                    recordGeometryShaderEmulationFailure(
                        program, programName,
                        "drawElements", gsDiag, /*detectRejected=*/false);
                    return true;
                }
                if (dcr4eExactNoLegacy) {
                    appgl::AppGLSubmissionGroup fallbackGroup;
                    impl_->declareCpuGsFallbackSubmissionGroup(fallbackGroup);
                    return true;
                }
            }
        }
    }

    // Sprint 7 #9 (CKPT65): VS-only TF emulation for drawElements,
    // mirroring the drawArrays hook at GLContext.mm:24590 (CKPT59).
    // When TF is active, the program has TF varyings, no GS in pipeline,
    // and no tess emulation applies, run the VS on CPU per indexed
    // vertex and write captures via the shared writeGsXfbAndCheckDiscard
    // helper. Required for CTS `transform_feedback.{capture,query,
    // discard}_vertex_*` tests which use client-side index arrays
    // with `glDrawElements` to drive TF capture without a bound
    // GL_ELEMENT_ARRAY_BUFFER.
    if (program != nullptr &&
        isTransformFeedbackActive() &&  // CKPT85: per-bound-object
        !program->transformFeedbackVaryingNames.empty() &&
        !program->geometryEmulated &&
        !program->tessellationEmulated &&
        !program->tessellationInterpreted &&
        drawElementsCount > 0 &&
        drawElementsIndexPtr != nullptr) {
        GLVertexArrayObject legacyClientVao;
        GLVertexArrayObject* tfVao = vao;
        if (impl_->state->boundVertexArray() == 0 &&
            appglCompatProfileEnabled()) {
            const auto& legacyVertexArray = impl_->legacyVertexArray;
            if (legacyVertexArray.enabled &&
                (legacyVertexArray.pointer != nullptr ||
                 legacyVertexArray.bufferName != 0) &&
                legacyVertexArray.type == GL_FLOAT &&
                legacyVertexArray.size >= 2 &&
                legacyVertexArray.size <= 4) {
                impl_->objects->initializeVertexArray(legacyClientVao);
                if (!legacyClientVao.attributes.empty()) {
                    const std::size_t stride = legacyVertexArray.stride > 0
                        ? static_cast<std::size_t>(legacyVertexArray.stride)
                        : static_cast<std::size_t>(legacyVertexArray.size) *
                              sizeof(GLfloat);
                    GLVertexAttributeState& attr = legacyClientVao.attributes[0];
                    attr.enabled = true;
                    attr.size = legacyVertexArray.size;
                    attr.type = legacyVertexArray.type;
                    attr.normalized = GL_FALSE;
                    attr.stride = static_cast<GLsizei>(stride);
                    attr.pointer = reinterpret_cast<std::uintptr_t>(
                        legacyVertexArray.pointer);
                    attr.buffer = legacyVertexArray.bufferName;
                    attr.divisor = 0;
                    attr.integer = false;
                    attr.longData = false;
                    attr.bindingIndex = 0;
                    attr.relativeOffset = 0;
                    attr.useSeparatedFormat = false;
                    if (!legacyClientVao.bindingPoints.empty()) {
                        legacyClientVao.bindingPoints[0].buffer =
                            legacyVertexArray.bufferName;
                        legacyClientVao.bindingPoints[0].offset =
                            static_cast<GLintptr>(attr.pointer);
                        legacyClientVao.bindingPoints[0].stride =
                            static_cast<GLsizei>(stride);
                        legacyClientVao.bindingPoints[0].divisor = 0;
                    }
                    tfVao = &legacyClientVao;
                }
            }
        }
        if (pushSynthesizedMatrixUniforms(*program, impl_->matrixState)) {
            program->markUniformsDirty();
        }
        // Resolve the post-primitive-restart drawElements stream
        // (uint16 / uint32) into a uint32 vector matching the
        // emulateVsOnlyDrawForTf elementIndices param shape.
        // Primitive-restart expansion above may already have split
        // strips/fans into list topology, which is exactly the stream
        // GL transform feedback captures after primitive assembly.
        //
        // Small allocation cost — CTS draws never exceed a few
        // hundred indices for these tests.
        std::vector<std::uint32_t> idx32(static_cast<std::size_t>(drawElementsCount));
        if (drawElementsIndexType == GL_UNSIGNED_INT) {
            std::memcpy(idx32.data(), drawElementsIndexPtr,
                        static_cast<std::size_t>(drawElementsCount) *
                            sizeof(std::uint32_t));
        } else if (drawElementsIndexType == GL_UNSIGNED_SHORT) {
            const std::uint16_t* src16 =
                static_cast<const std::uint16_t*>(drawElementsIndexPtr);
            for (GLsizei i = 0; i < drawElementsCount; ++i) idx32[i] = src16[i];
        } else {
            idx32.clear();
        }
        // Sprint 7 #9 (CKPT65): topology-decompose strip / loop / fan
        // input into discrete-primitive vertex streams for TF capture.
        // GL 4.6 §13.2: TF captures one entry per re-assembled
        // primitive vertex. So GL_LINE_LOOP with 4 indices captures
        // 8 verts (4 segs × 2 endpoints), GL_LINE_STRIP with 4 captures
        // 6, GL_TRIANGLE_STRIP / _FAN with 4 captures 6, etc. POINTS /
        // LINES / TRIANGLES are already discrete and pass through.
        std::vector<std::uint32_t> capIdx;
        if (!idx32.empty()) {
            const std::size_t n = idx32.size();
            switch (drawElementsMode) {
                case GL_POINTS:
                case GL_LINES:
                case GL_TRIANGLES:
                    capIdx = idx32;
                    break;
                case GL_LINE_STRIP:
                    if (n >= 2) {
                        capIdx.reserve(2 * (n - 1));
                        for (std::size_t i = 0; i + 1 < n; ++i) {
                            capIdx.push_back(idx32[i]);
                            capIdx.push_back(idx32[i + 1]);
                        }
                    }
                    break;
                case GL_LINE_LOOP:
                    if (n >= 2) {
                        capIdx.reserve(2 * n);
                        for (std::size_t i = 0; i < n; ++i) {
                            capIdx.push_back(idx32[i]);
                            capIdx.push_back(idx32[(i + 1) % n]);
                        }
                    }
                    break;
                case GL_TRIANGLE_STRIP:
                    if (n >= 3) {
                        capIdx.reserve(3 * (n - 2));
                        for (std::size_t i = 0; i + 2 < n; ++i) {
                            // GL 4.6 §10.1.12 strip alternation: even
                            // tri (i, i+1, i+2); odd tri (i+1, i, i+2)
                            // so consistent winding survives strip
                            // decomposition.
                            if ((i & 1u) == 0u) {
                                capIdx.push_back(idx32[i]);
                                capIdx.push_back(idx32[i + 1]);
                                capIdx.push_back(idx32[i + 2]);
                            } else {
                                capIdx.push_back(idx32[i + 1]);
                                capIdx.push_back(idx32[i]);
                                capIdx.push_back(idx32[i + 2]);
                            }
                        }
                    }
                    break;
                case GL_TRIANGLE_FAN:
                    if (n >= 3) {
                        capIdx.reserve(3 * (n - 2));
                        for (std::size_t i = 1; i + 1 < n; ++i) {
                            capIdx.push_back(idx32[0]);
                            capIdx.push_back(idx32[i]);
                            capIdx.push_back(idx32[i + 1]);
                        }
                    }
                    break;
                default:
                    capIdx.clear();
                    break;
            }
        }
        if (!capIdx.empty() && tfVao != nullptr && !program->vertexSpirv.empty()) {
            // The reassembled discrete-primitive topology fed to
            // writeGsXfbAndCheckDiscard via EmulatedDraw.topology.
            const GLenum capTopology =
                (drawElementsMode == GL_POINTS) ? GL_POINTS :
                (drawElementsMode == GL_LINES ||
                 drawElementsMode == GL_LINE_STRIP ||
                 drawElementsMode == GL_LINE_LOOP) ? GL_LINES :
                GL_TRIANGLES;
            const bool replayPostVsTriangle =
                !impl_->state->isEnabled(GL_RASTERIZER_DISCARD) &&
                capTopology == GL_TRIANGLES;
            const auto vsTexMap = impl_->buildSampledTextureMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            const auto vsImgMap = impl_->buildStorageImageMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            appgl::EmulatedDraw ed = appgl::emulateVsOnlyDrawForTf(
                *program, *tfVao, *impl_->objects, *impl_->state,
                capTopology, static_cast<GLsizei>(capIdx.size()), /*first=*/0,
                /*instanceCount=*/1, /*baseInstance=*/0,
                capIdx.data(),
                vsTexMap.empty() ? nullptr : &vsTexMap,
                vsImgMap.empty() ? nullptr : &vsImgMap,
                replayPostVsTriangle);
            if (ed.ok) {
                bool discard = false;
                if (appgl::vsOnlyTfTimingEnabled()) {
                    const std::uint64_t t0 = appgl::vsOnlyTfTimingNowNs();
                    discard = impl_->writeGsXfbAndCheckDiscard(*program, ed);
                    appgl::recordVsOnlyTfWriteDurationNs(
                        appgl::vsOnlyTfTimingNowNs() - t0);
                } else {
                    discard = impl_->writeGsXfbAndCheckDiscard(*program, ed);
                }
                if (!program->gsPresent) {
                    impl_->updatePrimitiveGeneratedForNonGsDraw(
                        capTopology, static_cast<GLsizei>(capIdx.size()), 1);
                }
                if (discard) {
                    return true;
                }
                if (replayPostVsTriangle) {
                    // Rasterize the already evaluated post-VS triangle
                    // stream. Line/point replay remains deferred and uses
                    // the established translated/legacy fallback below.
                    if (impl_->encodeEmulatedGsDraw(
                            *program, programName, ed)) {
                        return true;
                    }
                }
                // Preserve the regular translated/legacy fallback if replay
                // is out of scope or unavailable for this program shape.
            } else if (!ed.diagnostic.empty()) {
                APPGL_LOG(SHADER, @"drawElements VS-only-TF: %s",
                          ed.diagnostic.c_str());
            }
        }
    }

    // Sprint 17 Day 7+ Bank-Group-H Path B Component B (drawElements):
    // sister of drawArrays B branch. Expand effectivePtr to UINT32 and
    // route through emulateVsCullPrepass + dispatchCullFilteredDraw.
    if (program != nullptr && program->needsCullDistancePrepass &&
        program->hasTranslatedPipeline && vao != nullptr &&
        count > 0 && effectivePtr != nullptr) {
        const bool isLineOrTriDE =
            (mode == GL_POINTS || mode == GL_LINES || mode == GL_TRIANGLES ||
             mode == GL_LINE_STRIP || mode == GL_LINE_LOOP ||
             mode == GL_TRIANGLE_STRIP || mode == GL_TRIANGLE_FAN);
        if (isLineOrTriDE) {
            std::vector<std::uint32_t> cpIdx32(static_cast<std::size_t>(count));
            bool idxOk = true;
            if (effectiveType == GL_UNSIGNED_INT) {
                std::memcpy(cpIdx32.data(), effectivePtr,
                            static_cast<std::size_t>(count) * sizeof(std::uint32_t));
            } else if (effectiveType == GL_UNSIGNED_SHORT) {
                const std::uint16_t* src16 =
                    static_cast<const std::uint16_t*>(effectivePtr);
                for (GLsizei i = 0; i < count; ++i) cpIdx32[i] = src16[i];
            } else if (effectiveType == GL_UNSIGNED_BYTE) {
                const std::uint8_t* src8 =
                    static_cast<const std::uint8_t*>(effectivePtr);
                for (GLsizei i = 0; i < count; ++i) cpIdx32[i] = src8[i];
            } else {
                idxOk = false;
            }
            if (idxOk) {
                std::vector<std::uint32_t> filteredIdx;
                std::string cullDiag;
                const bool prepassOk = appgl::emulateVsCullPrepass(
                    *program, *vao, *impl_->objects, *impl_->state,
                    mode, count, /*first=*/0, cpIdx32.data(),
                    /*instanceCount=*/1, /*baseInstance=*/0,
                    filteredIdx, &cullDiag);
                if (prepassOk) {
                    if (filteredIdx.empty()) {
                        if (!program->gsPresent &&
                            !impl_->transformFeedbackActive) {
                            impl_->updatePrimitiveCountersForNonGsDraw(
                                mode, count, 1);
                        }
                        return true;
                    }
                    if (impl_->dispatchCullFilteredDraw(
                            *program, *vao, programName, mode,
                            filteredIdx)) {
                        if (!program->gsPresent &&
                            !impl_->transformFeedbackActive) {
                            impl_->updatePrimitiveCountersForNonGsDraw(
                                mode, count, 1);
                        }
                        return true;
                    }
                } else if (!cullDiag.empty()) {
                    APPGL_LOG(SHADER, @"drawElements cull-prepass: %s",
                              cullDiag.c_str());
                }
            }
        }
    }

    // Sprint 8 #9-A (CKPT67): attribute-less drawElements path. Mirror
    // of the drawArrays attribute-less path at line ~24670. CTS
    // `transform_feedback.{capture,query}_vertex_*` tests use a VS
    // that reads only `gl_VertexID` (no per-vertex inputs) and call
    // glDrawElements with client-side index arrays. Without this
    // hook the existing `vao->attributes.empty()` branch in the
    // hasTranslatedPipeline block records a fallback diagnostic and
    // skips the encode entirely — pixels stay at zero-init.
    // Gate mirrors drawArrays attributeless path at line ~24670:
    // shader-reflection-based, not VAO-attributes-based. Our VAO
    // initialization resizes `attributes` to `count` default-
    // constructed (disabled) entries, so `vao->attributes.empty()`
    // returns false even when nothing is actually bound. The shader
    // reflection's `vertexInputs.empty()` is the correct indicator
    // for an attribute-less draw.
    const bool translatedDrawElementsEligible = [&]() {
        GLDrawDetailScope detail(
            impl_->drawDetailProfile,
            GLDrawDetailBucket::TranslatedDrawEligibility);
        return program != nullptr && program->hasTranslatedPipeline;
    }();
    bool translatedDrawElementsAttributelessEligible = false;
    {
        GLDrawDetailScope detail(
            impl_->drawDetailProfile,
            GLDrawDetailBucket::TranslatedFallbackDecision);
        translatedDrawElementsAttributelessEligible =
            translatedDrawElementsEligible &&
            vao != nullptr &&
            program->vertexReflection.vertexInputs.empty() &&
            count > 0 && effectivePtr != nullptr;
    }
    if (translatedDrawElementsAttributelessEligible) {
        TranslatedDrawInfo& tdi = reusableTranslatedDrawInfo();
        tdi.mode = drawElementsMode;
        tdi.vertexCount = drawElementsCount;
        tdi.vertexData = nullptr;
        tdi.vertexDataByteCount = 0;
        tdi.vertexStride = 0;
        // Index data — CPU-side scratch from client-side index array
        // OR shadow-bytes from bound element buffer. encodeTranslated
        // Draw's `info.indices != nullptr && info.indexCount > 0`
        // gate stages it into a Metal ring buffer.
        tdi.indices = drawElementsIndexPtr;
        tdi.indexCount = drawElementsCount;
        tdi.indexType = drawElementsIndexType;
        tdi.glIndexBuffer = elementBufferName;
        if (!usePrimitiveRestartIndices &&
            elementBuffer != nullptr && !elementIndexTypeNeedsExpansion(type) &&
            elementBuffer->metalBuffer != nullptr) {
            tdi.metalIndexBuffer = elementBuffer->metalBuffer;
            if (impl_->frameGraph != nullptr) {
                elementBuffer->liveBindSubmitIndex =
                    impl_->frameGraph->openCommandBufferSubmitIndex();
            }
            tdi.metalIndexBufferOffset = indexOffset;
        }
        populateTranslatedDrawFixedFunctionState(
            tdi, *impl_->state, effectiveFragmentShadingRateForProgram(*this, program), this);
        assignTranslatedDrawProgramMsl(tdi, *program);
        tdi.vertexReflection = &program->vertexReflection;
        tdi.fragmentReflection = &program->fragmentReflection;
        tdi.pipelineStateOut = &program->metalPipelineState;
        tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;
        tdi.pipelineStateCacheOut = &program->metalPipelineStateCache;
        tdi.pipelineStateCacheLastUseOut =
            &program->metalPipelineStateCacheLastUse;
        tdi.pipelineStateCacheHighWaterOut =
            &program->metalPipelineStateCacheHighWater;
        tdi.pipelineStateCacheHitsOut = &program->metalPipelineStateCacheHits;
        tdi.pipelineStateCacheMissesOut =
            &program->metalPipelineStateCacheMisses;
        tdi.pipelineStateCacheEvictionsOut =
            &program->metalPipelineStateCacheEvictions;
        tdi.metalVertexFunction = program->metalVertexFunction;
        tdi.metalFragmentFunction = program->metalFragmentFunction;
        tdi.metalVertexFunctionOut = &program->metalVertexFunction;
        tdi.metalFragmentFunctionOut = &program->metalFragmentFunction;
        tdi.program = programName;
        tdi.pipelineEmulationFragmentProgram =
            program->pipelineEmulationFragmentProgram;

        logStateResolveCostClass(
            "drawElements-attributeless", programName, vaoName,
            tdi, vao->attributes.size());
        const double bindingConstructionUniformPackUs =
            impl_->prepareBindingConstructionUniformBuffers(
                *program, programName, drawID, tdi,
                "drawElements-attributeless");

        impl_->resolveBindingConstructionForTranslatedDraw(
            *program, tdi, bindingConstructionUniformPackUs);

        // FBO render target.
        {
            GLsizei fboW = 0, fboH = 0;
            void* fboDSTex = nullptr;
            std::uint32_t fboArrayLen = 0;
            std::uint32_t fboDSSlice = 0;
            std::uint32_t fboDSLevel = 0;
            std::array<void*, 7> extraColTex = {};
            std::array<std::uint32_t, 8> colSlices = {};
            std::array<std::uint32_t, 8> colLevels = {};
            std::array<TranslatedDrawInfo::FboColorAlphaMode, 8> colAlphaModes = {};
            void* fboColTex = impl_->resolveFBOColorTarget(
                fboW, fboH, fboDSTex, &fboArrayLen,
                &extraColTex, &colSlices, &colLevels,
                &colAlphaModes,
                &fboDSSlice, &fboDSLevel);
            if (fboColTex != nullptr || fboDSTex != nullptr ||
                std::any_of(extraColTex.begin(), extraColTex.end(),
                            [](void* tex) { return tex != nullptr; })) {
                tdi.fboColorTexture = fboColTex;
                tdi.fboAdditionalColorTextures = extraColTex;
                tdi.fboColorSlices = colSlices;
                tdi.fboColorLevels = colLevels;
                tdi.fboColorAlphaModes = colAlphaModes;
                tdi.fboColorArrayLength = fboArrayLen;
                tdi.fboDepthStencilTexture = fboDSTex;
                tdi.fboDepthStencilSlice = fboDSSlice;
                tdi.fboDepthStencilLevel = fboDSLevel;
                tdi.fboWidth = fboW;
                tdi.fboHeight = fboH;
            }
        }

        thread_local std::string pipelineBuildErrorDE;
        pipelineBuildErrorDE.clear();
        tdi.pipelineBuildErrorOut = &pipelineBuildErrorDE;

        const TranslatedDrawPreflightSnapshot preflight =
            makeTranslatedDrawPreflightSnapshot(
                vaoName, vao,
                /*genericVertexAttributesPrepared=*/true);
        const bool ok = impl_->encodeTranslatedDrawAndMarkFbo(
            tdi, &preflight);
        if (ok) {
            // Sprint 8 #9-A (CKPT67): primitive counter update is
            // handled by the VS-only-TF helper at the earlier hook
            // point (line ~25655) when transform feedback is active.
            // For non-TF draws on this attributeless path, mirror
            // drawArrays' attributeless-success path: update counters
            // here. CTS `query_vertex_*` tests have TF active during
            // the query, so the VS-only-TF helper already advanced
            // GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN; advancing
            // here AGAIN would double-count. Gate accordingly.
            if (!program->gsPresent && !impl_->transformFeedbackActive) {
                impl_->updatePrimitiveCountersForNonGsDraw(mode, count, 1);
            }
            return true;
        }
        // Fall through to solid-color path on failure.
    }
    drawProfile.mark(GLDrawProfileBucket::SpecialPathChecks);
    if (translatedDrawElementsEligible) {
        // Phase 8X Group 4d follow-up³ — name each fall-through gate to BAR's log.
        drawProfile.mark(GLDrawProfileBucket::TranslatedPreflight);
        bool attributesEmpty = false;
        {
            GLDrawDetailScope detail(
                impl_->drawDetailProfile,
                GLDrawDetailBucket::TranslatedFallbackDecision);
            attributesEmpty = vao->attributes.empty();
            if (attributesEmpty) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::EmptyAttributes, "drawElements",
                    vaoName, 0, 0, 0);
            }
        }
        if (!attributesEmpty) {
            bool vaoLayoutCacheHit = false;
            const GLVertexArrayCachedLayout* vaoLayoutPtr = nullptr;
            {
                GLDrawDetailScope detail(
                    impl_->drawDetailProfile,
                    GLDrawDetailBucket::TranslatedProgramVaoFboState);
                vaoLayoutPtr =
                    &cachedVertexArrayLayout(
                        *vao, false, &vaoLayoutCacheHit,
                        false, true, &impl_->coldPathProfile);
            }
            const auto& vaoLayout = *vaoLayoutPtr;
            drawProfile.mark(GLDrawProfileBucket::VaoLayout);
            GLBufferObject* vbo = (vaoLayout.primaryBufferName != 0)
                ? impl_->objects->buffers().get(vaoLayout.primaryBufferName)
                : nullptr;
            if (vbo == nullptr) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::NullVBO, "drawElements",
                    vaoName, vao->attributes.size(), vaoLayout.primaryBufferName, 0);
            } else if (vbo->shadowBytes.empty()) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::ShadowBytesEmpty, "drawElements",
                    vaoName, vao->attributes.size(), vaoLayout.primaryBufferName, 0);
            }
            drawProfile.mark(GLDrawProfileBucket::VboResolve);
            if (vbo != nullptr && !vbo->shadowBytes.empty()) {
                const std::size_t posStride = vaoLayout.primaryStride;
                const std::size_t startOff = vaoLayout.primaryBaseOffset;

                if (startOff > vbo->shadowBytes.size()) {
                    reportTranslatedFallbackOnce(program, programName,
                        TranslatedFallbackGate::OffsetOverflow, "drawElements",
                        vaoName, vao->attributes.size(), vaoLayout.primaryBufferName,
                        vbo->shadowBytes.size());
                }
                if (startOff <= vbo->shadowBytes.size()) {
                    TranslatedDrawInfo& tdi = reusableTranslatedDrawInfo();
                    tdi.mode = drawElementsMode;
                    tdi.vertexCount = drawElementsCount;
                    tdi.vertexData = vbo->shadowBytes.data() + startOff;
                    tdi.vertexDataByteCount = vbo->shadowBytes.size() - startOff;
                    tdi.vertexStride = posStride;
                    // OPT-5: pass pre-uploaded Metal buffer for direct bind.
                    tdi.metalVertexBuffer = vbo->metalBuffer;
                    if (impl_->frameGraph != nullptr) {
                        vbo->liveBindSubmitIndex =
                            impl_->frameGraph->openCommandBufferSubmitIndex();
                    }
                    tdi.metalVertexBufferOffset = startOff;
                    tdi.glVertexBuffer = vaoLayout.primaryBufferName;
                    tdi.indices = drawElementsIndexPtr;
                    tdi.indexCount = drawElementsCount;
                    tdi.indexType = drawElementsIndexType;
                    tdi.glIndexBuffer = elementBufferName;
                    drawProfile.mark(GLDrawProfileBucket::InfoInit);
                    // OPT-5: pass Metal index buffer when indices weren't
                    // expanded (UINT16/UINT32 pass-through from element VBO).
                    // ADV-10: use the type check instead of the old local vector.
                    if (!usePrimitiveRestartIndices &&
                        elementBuffer != nullptr &&
                        !elementIndexTypeNeedsExpansion(type) &&
                        elementBuffer->metalBuffer != nullptr) {
                        tdi.metalIndexBuffer = elementBuffer->metalBuffer;
                        if (impl_->frameGraph != nullptr) {
                            elementBuffer->liveBindSubmitIndex =
                                impl_->frameGraph->openCommandBufferSubmitIndex();
                        }
                        tdi.metalIndexBufferOffset = indexOffset;
                    }
                    // Phase 8X Group 4d follow-up¹⁴ — centralised fixed-
                    // function state snapshot. See drawArrays.
                    populateTranslatedDrawFixedFunctionState(
                        tdi, *impl_->state, effectiveFragmentShadingRateForProgram(*this, program), this);
                    drawProfile.mark(GLDrawProfileBucket::FixedFunctionState);
                    assignTranslatedDrawProgramMsl(tdi, *program);
                    tdi.vertexReflection = &program->vertexReflection;
                    tdi.fragmentReflection = &program->fragmentReflection;
                    tdi.pipelineStateOut = &program->metalPipelineState;
                    tdi.pipelineColorFormatOut = &program->metalPipelineColorFormat;
                    // Phase 8X Group 4d follow-up¹⁴ — map-based cache
                    // so spring's 15×/frame blend toggle doesn't thrash
                    // the single-slot scalar cache above.
                    tdi.pipelineStateCacheOut = &program->metalPipelineStateCache;
                    tdi.pipelineStateCacheLastUseOut =
                        &program->metalPipelineStateCacheLastUse;
                    tdi.pipelineStateCacheHighWaterOut =
                        &program->metalPipelineStateCacheHighWater;
                    tdi.pipelineStateCacheHitsOut =
                        &program->metalPipelineStateCacheHits;
                    tdi.pipelineStateCacheMissesOut =
                        &program->metalPipelineStateCacheMisses;
                    tdi.pipelineStateCacheEvictionsOut =
                        &program->metalPipelineStateCacheEvictions;
                    tdi.metalVertexFunction = program->metalVertexFunction;
                    tdi.metalFragmentFunction = program->metalFragmentFunction;
                    tdi.metalVertexFunctionOut = &program->metalVertexFunction;
                    tdi.metalFragmentFunctionOut = &program->metalFragmentFunction;
                    // Phase 8X Group 4d follow-up⁸ — diagnostic-only
                    // program identifier used by encodeTranslatedDraw's
                    // first-draw-per-program NSLog. Non-owning, no
                    // correctness impact; zero is a valid placeholder.
                    tdi.program = programName;
                    tdi.pipelineEmulationFragmentProgram =
                        program->pipelineEmulationFragmentProgram;
                    drawProfile.mark(GLDrawProfileBucket::ShaderState);

                    applyCachedVertexArrayLayout(
                        vaoLayout, *impl_->objects, tdi, 0,
                        false, false, &impl_->coldPathProfile,
                        impl_->frameGraph.get());
                    drawProfile.mark(GLDrawProfileBucket::VertexLayout);

                    logStateResolveCostClass(
                        "drawElements", programName, vaoName,
                        tdi, vao->attributes.size(), vaoLayoutCacheHit);
                    drawProfile.mark(GLDrawProfileBucket::Diagnostics);
                    const double bindingConstructionUniformPackUs =
                        impl_->prepareBindingConstructionUniformBuffers(
                            *program, programName, drawID, tdi,
                            "drawElements");
                    drawProfile.mark(GLDrawProfileBucket::UniformBuffers);

                    impl_->resolveBindingConstructionForTranslatedDraw(
                        *program, tdi, bindingConstructionUniformPackUs);
                    drawProfile.resetCursor();

                    // RC-A02: resolve FBO render target.
                    {
                        GLsizei fboW = 0, fboH = 0;
                        void* fboDSTex = nullptr;
                        std::uint32_t fboArrayLen = 0;
                        std::uint32_t fboDSSlice = 0;
                        std::uint32_t fboDSLevel = 0;
                        std::array<void*, 7> extraColTex = {};
                        std::array<std::uint32_t, 8> colSlices = {};
                        std::array<std::uint32_t, 8> colLevels = {};
                        std::array<TranslatedDrawInfo::FboColorAlphaMode, 8> colAlphaModes = {};
                        void* fboColTex = impl_->resolveFBOColorTarget(
                            fboW, fboH, fboDSTex, &fboArrayLen,
                            &extraColTex, &colSlices, &colLevels,
                            &colAlphaModes,
                            &fboDSSlice, &fboDSLevel);
                        if (fboColTex != nullptr || fboDSTex != nullptr ||
                            std::any_of(extraColTex.begin(), extraColTex.end(),
                                        [](void* tex) { return tex != nullptr; })) {
                            tdi.fboColorTexture = fboColTex;
                            tdi.fboAdditionalColorTextures = extraColTex;
                            tdi.fboColorSlices = colSlices;
                            tdi.fboColorLevels = colLevels;
                            tdi.fboColorAlphaModes = colAlphaModes;
                            tdi.fboColorArrayLength = fboArrayLen;
                            tdi.fboDepthStencilTexture = fboDSTex;
                            tdi.fboDepthStencilSlice = fboDSSlice;
                            tdi.fboDepthStencilLevel = fboDSLevel;
                            tdi.fboWidth = fboW;
                            tdi.fboHeight = fboH;
                        }
                    }
                    drawProfile.mark(GLDrawProfileBucket::FboResolve);

                    // Phase 8X Group 4d follow-up⁴ — scratch buffer for the
                    // pipeline-build error text plumbed out of the encode-failed
                    // path. See the matching comment in drawArrays for rationale.
                    thread_local std::string pipelineBuildError;
                    pipelineBuildError.clear();
                    tdi.pipelineBuildErrorOut = &pipelineBuildError;
                    drawProfile.mark(GLDrawProfileBucket::EncodePrep);

                    const TranslatedDrawPreflightSnapshot preflight =
                        makeTranslatedDrawPreflightSnapshot(
                            vaoName, vao,
                            /*genericVertexAttributesPrepared=*/false);
                    const bool ok = impl_->encodeTranslatedDrawAndMarkFbo(
                        tdi, &preflight);
                    drawProfile.resetCursor();
                    if (ok) {
                        return true;
                    }
                    if (reportTranslatedFallbackOnce(program, programName,
                            TranslatedFallbackGate::EncodeFailed, "drawElements",
                            vaoName, vao->attributes.size(), vaoLayout.primaryBufferName,
                            vbo->shadowBytes.size())) {
                        recordPipelineBuildFailureOnce(program, programName, pipelineBuildError);
                    }
                    // Fall through to solid-color path on failure.
                }
            }
        }
    }

    // Fallback: solid-color draw path (hardcoded appgl_solid pipeline).
    SolidColorDrawSetup setup = buildSolidColorDrawSetup(
        *impl_->state,
        *impl_->objects,
        mode,
        "glDrawElements",
        GL_SHADING_RATE_1X1_PIXELS_EXT
    );
    if (!setup.ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_OTHER,
            0,
            GL_DEBUG_SEVERITY_LOW,
            "glDrawElements: draw skipped (no translated pipeline and solid-color path unsupported)"
        );
        drawProfile.mark(GLDrawProfileBucket::SolidFallback);
        return false;
    }

    setup.info.vertexCount = drawElementsCount;
    setup.info.baseVertex = 0;
    setup.info.indices = drawElementsIndexPtr;
    setup.info.indexCount = drawElementsCount;
    setup.info.indexType = drawElementsIndexType;

    const bool ok = impl_->frameGraph->encodeSolidColorDraw(setup.info);
    if (ok) {
        impl_->markBoundDrawFramebufferWrites();
    }
    if (!ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_ERROR,
            0,
            GL_DEBUG_SEVERITY_HIGH,
            "glDrawElements: MetalFrameGraph failed to encode draw"
        );
    }
    drawProfile.mark(GLDrawProfileBucket::SolidFallback);
    return ok;
}
