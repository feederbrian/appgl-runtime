// This file is textually included by GLContextDraw.inc.mm. Do not compile it directly.
// It contains the GLContext draw base-vertex method definitions split out for navigation only.

#line 935 "/private/tmp/appgl-bug3-clean/src/context/GLContextDraw.inc.mm" // Preserve source identity so this relocation stays codegen-neutral; __FILE__/__LINE__/debug-info intentionally report the original GLContextDraw.inc.mm.
bool GLContext::drawElementsBaseVertex(GLenum mode, GLsizei count, GLenum type, const void* indices, GLint basevertex, GLuint drawID, bool forceDrawPrepReset) {
    // GL 4.6 §10.5: mode must be a valid primitive-assembly enum.
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
    if (!impl_->state->validateForDraw()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §2.3.3 — conditional render predicate.
    if (impl_->shouldSkipDrawForConditionalRender()) {
        return true;
    }
    if (isTransformFeedbackActive()) {
        return drawElementsInstancedBaseVertex(
            mode, count, type, indices, 1, basevertex, 0, drawID,
            forceDrawPrepReset);
    }
    // GL 4.6 §22.1 / §22.3 — pipeline-stats counter update for
    // non-GS indexed draws. GS path is handled via
    // writeGsXfbAndCheckDiscard below.
    {
        const GLuint progName = impl_->state->currentProgram();
        const GLProgramObject* p = progName != 0
            ? impl_->objects->programs().get(progName)
            : nullptr;
        if (p == nullptr || !p->gsPresent) {
            const GLsizei restartSkip = impl_->countRestartIndices(type, indices, count);
            impl_->updatePrimitiveCountersForNonGsDraw(mode, count, 1, restartSkip);
        }
    }

    if (impl_->frameGraph == nullptr) {
        return false;
    }
    impl_->ensureDefaultDrawableForViewportExtent();
    impl_->encodePendingWork();

    // Resolve element buffer — same as drawElements.
    const GLuint vaoName = impl_->state->boundVertexArray();
    GLVertexArrayObject* vao = (vaoName != 0) ? impl_->objects->vertexArrays().get(vaoName) : nullptr;
    if (vao == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const GLuint elementBufferName = vao->elementArrayBuffer;
    if (elementBufferName == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLBufferObject* elementBuffer = impl_->objects->buffers().get(elementBufferName);
    if (elementBuffer == nullptr || elementBuffer->shadowBytes.empty()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    const std::size_t indexOffset = reinterpret_cast<std::uintptr_t>(indices);
    if (indexOffset > elementBuffer->shadowBytes.size()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const void* indexPtr = elementBuffer->shadowBytes.data() + indexOffset;

    // Handle GL_UNSIGNED_BYTE expansion (same as drawElements).
    GLenum effectiveType = type;
    const void* effectivePtr = indexPtr;
    if (elementIndexTypeNeedsExpansion(type)) {
        const bool expansionCacheHit =
            elementBuffer->cachedExpansionGeneration == elementBuffer->indexExpansionGeneration &&
            !elementBuffer->cachedExpandedIndices.empty();
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
        const std::size_t expandedOffset = indexOffset * sizeof(GLushort);
        effectivePtr = elementBuffer->cachedExpandedIndices.data() + expandedOffset;
        impl_->touchR5ExpandedIndexCache(*elementBuffer);
        logIndexExpansionCostClass(
            "drawElementsBaseVertex", elementBufferName, type, effectiveType,
            static_cast<GLsizei>(elementBuffer->shadowBytes.size()),
            elementBuffer->cachedExpandedIndices.size(), expansionCacheHit,
            elementBuffer->cachedExpansionGeneration);
    }

    // Try translated shader pipeline first.
    // GL 4.6 §7.4 — prefer glUseProgram's program; fall back to the
    // active program pipeline's VS+FS merged onto its VS container
    // when only a pipeline is bound. Covers the CTS VAB tests that
    // drive separable programs through glCreateShaderProgramv +
    // glUseProgramStages without ever calling glUseProgram.
    GLuint programName = impl_->state->currentProgram();
    GLProgramObject* program = impl_->resolveDrawProgram(programName);

    // GS emul hook for base-vertex indexed draws (drawRangeElements
    // funnels here too).
    if (program != nullptr && program->geometryEmulated && count > 0) {
        const bool dcr4eExactNoLegacy =
            dcr4eRequiresExactCpuGsNoLegacyFallback(
                program, mode, isTransformFeedbackActive());
        std::vector<std::uint32_t> idx32(static_cast<std::size_t>(count));
        if (effectiveType == GL_UNSIGNED_INT) {
            const std::uint32_t* src32 = static_cast<const std::uint32_t*>(effectivePtr);
            std::memcpy(idx32.data(), src32, count * sizeof(std::uint32_t));
        } else if (effectiveType == GL_UNSIGNED_SHORT) {
            const std::uint16_t* src16 = static_cast<const std::uint16_t*>(effectivePtr);
            for (GLsizei i = 0; i < count; ++i) idx32[i] = src16[i];
        } else {
            idx32.clear();
        }
        if (!idx32.empty()) {
            if (basevertex != 0) {
                for (auto& v : idx32) v = static_cast<std::uint32_t>(
                    static_cast<std::int32_t>(v) + basevertex);
            }
            appgl::EmulatedDraw ed = appgl::emulateGeometryDraw(
                *program, *vao, *impl_->objects, *impl_->state,
                mode, count, /*first=*/0, idx32.data());
            if (ed.ok) {
                if (impl_->writeGsXfbAndCheckDiscard(*program, ed)) return true;
                if (ed.vertexCount == 0) return true;
                if (!program->geometryEmulatedTransformFeedbackOnly &&
                    impl_->encodeEmulatedGsDraw(*program, programName, ed)) return true;
                if (!program->geometryEmulatedTransformFeedbackOnly &&
                    dcr4eExactNoLegacy) {
                    appgl::AppGLSubmissionGroup fallbackGroup;
                    impl_->declareCpuGsFallbackSubmissionGroup(fallbackGroup);
                    return true;
                }
            } else if (dcr4eExactNoLegacy) {
                appgl::AppGLSubmissionGroup fallbackGroup;
                impl_->declareCpuGsFallbackSubmissionGroup(fallbackGroup);
                return true;
            }
        }
    }

    if (program != nullptr && program->hasTranslatedPipeline) {
        if (vao->attributes.empty()) {
            reportTranslatedFallbackOnce(program, programName,
                TranslatedFallbackGate::EmptyAttributes, "drawElementsBaseVertex",
                vaoName, 0, 0, 0);
        }
        if (!vao->attributes.empty()) {
            bool vaoLayoutCacheHit = false;
            const auto& vaoLayout =
                cachedVertexArrayLayout(
                    *vao, false, &vaoLayoutCacheHit,
                    false, true, &impl_->coldPathProfile);
            GLBufferObject* vbo = (vaoLayout.primaryBufferName != 0)
                ? impl_->objects->buffers().get(vaoLayout.primaryBufferName)
                : nullptr;
            if (vbo == nullptr) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::NullVBO, "drawElementsBaseVertex",
                    vaoName, vao->attributes.size(), vaoLayout.primaryBufferName, 0);
            } else if (vbo->shadowBytes.empty()) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::ShadowBytesEmpty, "drawElementsBaseVertex",
                    vaoName, vao->attributes.size(), vaoLayout.primaryBufferName, 0);
            }
            if (vbo != nullptr && !vbo->shadowBytes.empty()) {
                const std::size_t posStride = vaoLayout.primaryStride;
                const std::size_t startOff = vaoLayout.primaryBaseOffset;

                if (startOff > vbo->shadowBytes.size()) {
                    reportTranslatedFallbackOnce(program, programName,
                        TranslatedFallbackGate::OffsetOverflow, "drawElementsBaseVertex",
                        vaoName, vao->attributes.size(), vaoLayout.primaryBufferName,
                        vbo->shadowBytes.size());
                }
                if (startOff <= vbo->shadowBytes.size()) {
                    TranslatedDrawInfo& tdi = reusableTranslatedDrawInfo();
                    tdi.mode = mode;
                    tdi.vertexCount = count;
                    tdi.baseVertex = basevertex;
                    tdi.shaderBaseVertex = basevertex;
                    tdi.vertexData = vbo->shadowBytes.data() + startOff;
                    tdi.vertexDataByteCount = vbo->shadowBytes.size() - startOff;
                    tdi.vertexStride = posStride;
                    tdi.metalVertexBuffer = vbo->metalBuffer;
                    if (impl_->frameGraph != nullptr) {
                        vbo->liveBindSubmitIndex =
                            impl_->frameGraph->openCommandBufferSubmitIndex();
                    }
                    tdi.metalVertexBufferOffset = startOff;
                    tdi.glVertexBuffer = vaoLayout.primaryBufferName;
                    tdi.indices = effectivePtr;
                    tdi.indexCount = count;
                    tdi.indexType = effectiveType;
                    tdi.glIndexBuffer = elementBufferName;
                    if (!elementIndexTypeNeedsExpansion(type) && elementBuffer->metalBuffer != nullptr) {
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
                    tdi.program = programName;
                    tdi.pipelineEmulationFragmentProgram =
                        program->pipelineEmulationFragmentProgram;

                    applyCachedVertexArrayLayout(
                        vaoLayout, *impl_->objects, tdi, 0,
                        false, false, &impl_->coldPathProfile,
                        impl_->frameGraph.get());

                    logStateResolveCostClass(
                        "drawElementsBaseVertex", programName, vaoName,
                        tdi, vao->attributes.size(), vaoLayoutCacheHit);
                    const double bindingConstructionUniformPackUs =
                        impl_->prepareBindingConstructionUniformBuffers(
                            *program, programName, drawID, tdi,
                            "drawElementsBaseVertex");

                    impl_->resolveBindingConstructionForTranslatedDraw(
                        *program, tdi, bindingConstructionUniformPackUs);

                    // RC-A02: resolve FBO render target.
                    {
                        GLsizei fboW = 0, fboH = 0;
                        void* fboDSTex = nullptr;
                        std::uint32_t fboDSSlice = 0;
                        std::uint32_t fboDSLevel = 0;
                        std::array<void*, 7> extraColTex = {};
                        std::array<std::uint32_t, 8> colSlices = {};
                        std::array<std::uint32_t, 8> colLevels = {};
                        void* fboColTex = impl_->resolveFBOColorTarget(
                            fboW, fboH, fboDSTex, nullptr,
                            &extraColTex, &colSlices, &colLevels,
                            &fboDSSlice, &fboDSLevel);
                        if (fboColTex != nullptr || fboDSTex != nullptr) {
                            tdi.fboColorTexture = fboColTex;
                            tdi.fboAdditionalColorTextures = extraColTex;
                            tdi.fboColorSlices = colSlices;
                            tdi.fboColorLevels = colLevels;
                            tdi.fboDepthStencilTexture = fboDSTex;
                            tdi.fboDepthStencilSlice = fboDSSlice;
                            tdi.fboDepthStencilLevel = fboDSLevel;
                            tdi.fboWidth = fboW;
                            tdi.fboHeight = fboH;
                        }
                    }

                    thread_local std::string pipelineBuildError;
                    pipelineBuildError.clear();
                    tdi.pipelineBuildErrorOut = &pipelineBuildError;

                    const TranslatedDrawPreflightSnapshot preflight =
                        makeTranslatedDrawPreflightSnapshot(
                            vaoName, vao,
                            /*genericVertexAttributesPrepared=*/false);
                    const bool ok = impl_->encodeTranslatedDrawAndMarkFbo(
                        tdi, &preflight);
                    if (ok) {
                        return true;
                    }
                    if (reportTranslatedFallbackOnce(program, programName,
                            TranslatedFallbackGate::EncodeFailed, "drawElementsBaseVertex",
                            vaoName, vao->attributes.size(), vaoLayout.primaryBufferName,
                            vbo->shadowBytes.size())) {
                        recordPipelineBuildFailureOnce(program, programName, pipelineBuildError);
                    }
                }
            }
        }
    }

    // Fallback: solid-color draw path.
    SolidColorDrawSetup setup = buildSolidColorDrawSetup(
        *impl_->state,
        *impl_->objects,
        mode,
        "glDrawElementsBaseVertex",
        GL_SHADING_RATE_1X1_PIXELS_EXT
    );
    if (!setup.ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_OTHER,
            0,
            GL_DEBUG_SEVERITY_LOW,
            "glDrawElementsBaseVertex: draw skipped (no translated pipeline and solid-color path unsupported)"
        );
        return false;
    }

    setup.info.vertexCount = count;
    setup.info.baseVertex = basevertex;
    setup.info.indices = effectivePtr;
    setup.info.indexCount = count;
    setup.info.indexType = effectiveType;

    const bool solidOk = impl_->frameGraph->encodeSolidColorDraw(setup.info);
    if (solidOk) {
        impl_->markBoundDrawFramebufferWrites();
    }
    if (solidOk && impl_->state->boundDrawFramebuffer() == 0) {
        impl_->invalidateDefaultFramebufferShadow();
    }
    if (!solidOk) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_ERROR,
            0,
            GL_DEBUG_SEVERITY_HIGH,
            "glDrawElementsBaseVertex: MetalFrameGraph failed to encode draw"
        );
    }
    return solidOk;
}

bool GLContext::drawRangeElementsBaseVertex(GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type, const void* indices, GLint basevertex) {
    // Per the GL spec, start/end are range hints only. The spec says we MAY
    // use them for validation but MUST NOT reject draws where indices fall
    // outside [start, end]. We validate the basic constraints and delegate
    // to drawElementsBaseVertex for the actual draw.
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (end < start) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    return drawElementsBaseVertex(mode, count, type, indices, basevertex);
}

bool GLContext::drawElementsInstancedBaseVertex(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLint basevertex, GLuint baseinstance, GLuint drawID, bool forceDrawPrepReset) {
    if (rejectDisplayListCompileInstancedDraw("glDrawElementsInstancedBaseVertex")) {
        return false;
    }
    if (!isValidDrawMode(mode)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (count < 0 || instancecount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (count == 0 || instancecount == 0) {
        return true;
    }
    if (!isSupportedElementIndexType(type)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (!impl_->state->validateForDraw()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §2.3.3 — conditional render predicate.
    if (impl_->shouldSkipDrawForConditionalRender()) {
        return true;
    }
    // GL 4.6 §11.3.1: draw-mode / GS-input-topology compat. See
    // drawArraysInstanced for the rationale — the drawElements
    // indirect path lands here so the gate must live at this level
    // to catch `draw_indirect.negative-gshIncompatible-elements`.
    {
        const GLuint progName = impl_->state->currentProgram();
        const GLProgramObject* p = progName != 0
            ? impl_->objects->programs().get(progName)
            : nullptr;
        // Tess-in-pipeline escape — see drawArrays for rationale.
        if (p != nullptr && p->gsPresent && !p->hasTessellation &&
            !isDrawModeCompatibleWithGs(mode, p->gsInputTopology)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        // GL 4.6 §22.1 / §22.3 — pipeline-stats counter update.
        if (p == nullptr || !p->gsPresent) {
            const GLsizei restartSkip = impl_->countRestartIndices(type, indices, count);
            impl_->updatePrimitiveCountersForNonGsDraw(mode, count, instancecount, restartSkip);
        }
    }
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::Draw);

    if (impl_->frameGraph == nullptr) {
        return false;
    }
    impl_->ensureDefaultDrawableForViewportExtent();
    impl_->encodePendingWork();

    // Resolve element buffer.
    const GLuint vaoName = impl_->state->boundVertexArray();
    GLVertexArrayObject* vao = (vaoName != 0) ? impl_->objects->vertexArrays().get(vaoName) : nullptr;
    if (vao == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const GLuint elementBufferName = vao->elementArrayBuffer;
    if (elementBufferName == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLBufferObject* elementBuffer = impl_->objects->buffers().get(elementBufferName);
    if (elementBuffer == nullptr || elementBuffer->shadowBytes.empty()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    const std::size_t indexOffset = reinterpret_cast<std::uintptr_t>(indices);
    if (indexOffset > elementBuffer->shadowBytes.size()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const void* indexPtr = elementBuffer->shadowBytes.data() + indexOffset;

    GLenum effectiveType = type;
    const void* effectivePtr = indexPtr;
    if (elementIndexTypeNeedsExpansion(type)) {
        const bool expansionCacheHit =
            elementBuffer->cachedExpansionGeneration == elementBuffer->indexExpansionGeneration &&
            !elementBuffer->cachedExpandedIndices.empty();
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
        const std::size_t expandedOffset = indexOffset * sizeof(GLushort);
        effectivePtr = elementBuffer->cachedExpandedIndices.data() + expandedOffset;
        impl_->touchR5ExpandedIndexCache(*elementBuffer);
        logIndexExpansionCostClass(
            "drawElementsInstancedBaseVertex", elementBufferName,
            type, effectiveType,
            static_cast<GLsizei>(elementBuffer->shadowBytes.size()),
            elementBuffer->cachedExpandedIndices.size(), expansionCacheHit,
            elementBuffer->cachedExpansionGeneration);
    }

    // Try translated shader pipeline first.
    // GL 4.6 §7.4 — prefer glUseProgram's program; fall back to the
    // active program pipeline's VS+FS merged onto its VS container
    // when only a pipeline is bound. Covers the CTS VAB tests that
    // drive separable programs through glCreateShaderProgramv +
    // glUseProgramStages without ever calling glUseProgram.
    GLuint programName = impl_->state->currentProgram();
    GLProgramObject* program = impl_->resolveDrawProgram(programName);

    // Phase 3f-16: tess-emul for instanced indexed draws. Mirrors
    // the GS path below; the only shared code is the idx32 expand
    // + optional basevertex bias. Kept as a separate block so the
    // passthrough/interpreter precedence over GS-emul (they're
    // mutually exclusive via !geometryEmulated) is preserved.
    if (program != nullptr &&
        (program->tessellationEmulated || program->tessellationInterpreted) &&
        !program->geometryEmulated && count > 0 && instancecount > 0) {
        std::vector<std::uint32_t> tidx32;
        if (effectiveType == GL_UNSIGNED_INT) {
            tidx32.assign(count, 0);
            std::memcpy(tidx32.data(), effectivePtr, count * sizeof(std::uint32_t));
        } else if (effectiveType == GL_UNSIGNED_SHORT) {
            tidx32.assign(count, 0);
            const std::uint16_t* src16 =
                static_cast<const std::uint16_t*>(effectivePtr);
            for (GLsizei i = 0; i < count; ++i) tidx32[i] = src16[i];
        }
        impl_->compactRestartIndicesForPatchTess(type, tidx32);
        if (!tidx32.empty()) {
            if (basevertex != 0) {
                for (auto& v : tidx32) v = static_cast<std::uint32_t>(
                    static_cast<std::int32_t>(v) + basevertex);
            }
            const GLsizei tessCount = static_cast<GLsizei>(tidx32.size());
            appgl::EmulatedDraw ted = appgl::emulateTessellationDraw(
                *program, *vao, *impl_->objects, *impl_->state,
                mode, tessCount, /*first=*/0, tidx32.data(),
                instancecount, baseinstance);
            if (ted.ok) {
                if (impl_->writeGsXfbAndCheckDiscard(*program, ted)) return true;
                if (ted.vertexCount == 0) return true;
                if (impl_->encodeEmulatedGsDraw(*program, programName, ted)) return true;
            }
        }
    }

    // GS emul hook for instanced indexed draws. See drawElements
    // and drawArraysInstanced for the sibling paths.
    if (program != nullptr && program->geometryEmulated && count > 0 && instancecount > 0) {
        const bool dcr4eExactNoLegacy =
            dcr4eRequiresExactCpuGsNoLegacyFallback(
                program, mode, isTransformFeedbackActive());
        std::vector<std::uint32_t> idx32(static_cast<std::size_t>(count));
        if (effectiveType == GL_UNSIGNED_INT) {
            const std::uint32_t* src32 = static_cast<const std::uint32_t*>(effectivePtr);
            std::memcpy(idx32.data(), src32, count * sizeof(std::uint32_t));
        } else if (effectiveType == GL_UNSIGNED_SHORT) {
            const std::uint16_t* src16 = static_cast<const std::uint16_t*>(effectivePtr);
            for (GLsizei i = 0; i < count; ++i) idx32[i] = src16[i];
        } else {
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
                    if (basevertex != 0) {
                        for (auto& v : tessIdx32) {
                            v = static_cast<std::uint32_t>(
                                static_cast<std::int32_t>(v) + basevertex);
                        }
                    }
                    const GLsizei tessCount =
                        static_cast<GLsizei>(tessIdx32.size());
                    priorStage = appgl::emulateTessellationDraw(
                        *program, *vao, *impl_->objects, *impl_->state,
                        mode, tessCount, /*first=*/0, tessIdx32.data(),
                        instancecount, baseinstance,
                        tcsSamMap.empty() ? nullptr : &tcsSamMap,
                        tcsImgMap.empty() ? nullptr : &tcsImgMap,
                        tesSamMap.empty() ? nullptr : &tesSamMap,
                        tesImgMap.empty() ? nullptr : &tesImgMap,
                        vsTexMap.empty() ? nullptr : &vsTexMap,
                        vsImgMap.empty() ? nullptr : &vsImgMap);
                    if (!priorStage.ok && !priorStage.diagnostic.empty()) {
                        APPGL_LOG(SHADER,
                                  @"drawElementsInstancedBaseVertex tess+GS: tess-emul: %s",
                                  priorStage.diagnostic.c_str());
                    }
                }
            }

            std::vector<std::uint32_t> geomIdx32 = idx32;
            // basevertex applied per GL 4.6 §10.6.3: each element
            // index gets `basevertex` added before VBO fetch.
            if (basevertex != 0) {
                for (auto& v : geomIdx32) {
                    v = static_cast<std::uint32_t>(
                        static_cast<std::int32_t>(v) + basevertex);
                }
            }
            appgl::EmulatedDraw ed = appgl::emulateGeometryDraw(
                *program, *vao, *impl_->objects, *impl_->state,
                mode, count, /*first=*/0, geomIdx32.data(),
                instancecount, baseinstance,
                vsTexMap.empty() ? nullptr : &vsTexMap,
                gsTexMap.empty() ? nullptr : &gsTexMap,
                vsImgMap.empty() ? nullptr : &vsImgMap,
                gsImgMap.empty() ? nullptr : &gsImgMap,
                (hasTess && priorStage.ok) ? &priorStage : nullptr);
            if (ed.ok) {
                if (impl_->writeGsXfbAndCheckDiscard(*program, ed)) return true;
                if (ed.vertexCount == 0) return true;
                if (!program->geometryEmulatedTransformFeedbackOnly &&
                    impl_->encodeEmulatedGsDraw(*program, programName, ed)) return true;
                if (!program->geometryEmulatedTransformFeedbackOnly &&
                    dcr4eExactNoLegacy) {
                    appgl::AppGLSubmissionGroup fallbackGroup;
                    impl_->declareCpuGsFallbackSubmissionGroup(fallbackGroup);
                    return true;
                }
            } else if (dcr4eExactNoLegacy) {
                appgl::AppGLSubmissionGroup fallbackGroup;
                impl_->declareCpuGsFallbackSubmissionGroup(fallbackGroup);
                return true;
            }
        }
    }

    if (program != nullptr &&
        isTransformFeedbackActive() &&
        !program->transformFeedbackVaryingNames.empty() &&
        !program->geometryEmulated &&
        !program->tessellationEmulated &&
        !program->tessellationInterpreted &&
        count > 0 && instancecount > 0 &&
        effectivePtr != nullptr) {
        std::vector<std::uint32_t> idx32(static_cast<std::size_t>(count));
        if (effectiveType == GL_UNSIGNED_INT) {
            std::memcpy(idx32.data(), effectivePtr, count * sizeof(std::uint32_t));
        } else if (effectiveType == GL_UNSIGNED_SHORT) {
            const std::uint16_t* src16 =
                static_cast<const std::uint16_t*>(effectivePtr);
            for (GLsizei i = 0; i < count; ++i) idx32[i] = src16[i];
        } else {
            idx32.clear();
        }
        if (!idx32.empty() && basevertex != 0) {
            for (auto& v : idx32) {
                v = static_cast<std::uint32_t>(
                    static_cast<std::int32_t>(v) + basevertex);
            }
        }

        std::vector<std::uint32_t> capIdx;
        if (!idx32.empty()) {
            const std::size_t n = idx32.size();
            switch (mode) {
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
        if (!capIdx.empty() && !program->vertexSpirv.empty()) {
            const GLenum capTopology =
                (mode == GL_POINTS) ? GL_POINTS :
                (mode == GL_LINES || mode == GL_LINE_STRIP || mode == GL_LINE_LOOP) ? GL_LINES :
                GL_TRIANGLES;
            const auto vsTexMap = impl_->buildSampledTextureMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            const auto vsImgMap = impl_->buildStorageImageMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            appgl::EmulatedDraw ed = appgl::emulateVsOnlyDrawForTf(
                *program, *vao, *impl_->objects, *impl_->state,
                capTopology, static_cast<GLsizei>(capIdx.size()), /*first=*/0,
                instancecount, baseinstance,
                capIdx.data(),
                vsTexMap.empty() ? nullptr : &vsTexMap,
                vsImgMap.empty() ? nullptr : &vsImgMap);
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
                if (discard) {
                    return true;
                }
            } else if (!ed.diagnostic.empty()) {
                APPGL_LOG(SHADER, @"drawElementsInstancedBaseVertex VS-only-TF: %s",
                          ed.diagnostic.c_str());
            }
        }
    }

    if (program != nullptr && program->hasTranslatedPipeline) {
        if (vao->attributes.empty()) {
            reportTranslatedFallbackOnce(program, programName,
                TranslatedFallbackGate::EmptyAttributes, "drawElementsInstancedBaseVertex",
                vaoName, 0, 0, 0);
        }
        if (!vao->attributes.empty()) {
            bool vaoLayoutCacheHit = false;
            const auto& vaoLayout =
                cachedVertexArrayLayout(
                    *vao, true, &vaoLayoutCacheHit,
                    true, false, &impl_->coldPathProfile);
            GLBufferObject* vbo = (vaoLayout.primaryBufferName != 0)
                ? impl_->objects->buffers().get(vaoLayout.primaryBufferName)
                : nullptr;
            if (vbo == nullptr) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::NullVBO, "drawElementsInstancedBaseVertex",
                    vaoName, vao->attributes.size(), vaoLayout.primaryBufferName, 0);
            } else if (vbo->shadowBytes.empty()) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::ShadowBytesEmpty, "drawElementsInstancedBaseVertex",
                    vaoName, vao->attributes.size(), vaoLayout.primaryBufferName, 0);
            }
            if (vbo != nullptr && !vbo->shadowBytes.empty()) {
                const std::size_t posStride = vaoLayout.primaryStride;
                const std::size_t startOff = vaoLayout.primaryBaseOffset;

                if (startOff > vbo->shadowBytes.size()) {
                    reportTranslatedFallbackOnce(program, programName,
                        TranslatedFallbackGate::OffsetOverflow, "drawElementsInstancedBaseVertex",
                        vaoName, vao->attributes.size(), vaoLayout.primaryBufferName,
                        vbo->shadowBytes.size());
                }
                if (startOff <= vbo->shadowBytes.size()) {
                    // C51 draw-prep memo: identical generation key =>
                    // reuse the persistent tdi's prepared blocks. The
                    // SSO/subroutine hazard recomputes EVERY draw and is
                    // never memoized (S23 lesson).
                    bool memoHit = false;
                    bool memoHazard = false;
                    bool memoHazardComputed = false;
                    if (forceDrawPrepReset) {
                        impl_->drawPrepMemo.valid = false;
                    } else if (impl_->drawPrepMemoEnabled()) {
                        const bool hazard =
                            currentDrawHasProgramPipelineOrSubroutinePlanCacheHazard(
                                impl_->state.get(), impl_->objects.get());
                        memoHazard = hazard;
                        memoHazardComputed = true;
                        auto& memo = impl_->drawPrepMemo;
                        const std::uint64_t stateGen = impl_->state->stateGeneration();
                        const GLuint drawFbo = impl_->state->boundDrawFramebuffer();
                        if (memo.valid && !hazard &&
                            memo.stateGen == stateGen &&
                            memo.program == programName &&
                            memo.programExecGen == program->executableGeneration &&
                            memo.pipelineEmuFrag == program->pipelineEmulationFragmentProgram &&
                            memo.vao == vaoName &&
                            memo.vaoAttribGen == vao->attribGeneration &&
                            memo.drawFbo == drawFbo) {
                            memoHit = true;
                            ++impl_->prepMemoHits;
                        } else {
                            ++impl_->prepMemoMisses;
                            if (memo.valid) {
                                if (hazard) ++impl_->prepMemoBustsHazard;
                                else if (memo.stateGen != stateGen) {
                                    ++impl_->prepMemoBustsStateGen;
                                    // C52(a): bust topology — every domain
                                    // that advanced since the snapshot.
                                    for (unsigned d = 0; d < appgl::GLStateTracker::kDomainCount; ++d) {
                                        if (impl_->state->domainGeneration(d) != memo.domainGens[d]) {
                                            ++impl_->prepMemoBustsByDomain[d];
                                        }
                                    }
                                }
                                else if (memo.program != programName ||
                                         memo.programExecGen != program->executableGeneration ||
                                         memo.pipelineEmuFrag != program->pipelineEmulationFragmentProgram)
                                    ++impl_->prepMemoBustsProgram;
                                else if (memo.vao != vaoName ||
                                         memo.vaoAttribGen != vao->attribGeneration)
                                    ++impl_->prepMemoBustsVao;
                                else ++impl_->prepMemoBustsFbo;
                            }
                            memo.valid = !hazard;
                            memo.stateGen = stateGen;
                            for (unsigned d = 0; d < appgl::GLStateTracker::kDomainCount; ++d) {
                                memo.domainGens[d] = impl_->state->domainGeneration(d);
                            }
                            memo.program = programName;
                            memo.programExecGen = program->executableGeneration;
                            memo.pipelineEmuFrag = program->pipelineEmulationFragmentProgram;
                            memo.vao = vaoName;
                            memo.vaoAttribGen = vao->attribGeneration;
                            memo.drawFbo = drawFbo;
                        }
                    }
                    TranslatedDrawInfo& tdi = reusableTranslatedDrawInfo(/*reset=*/!memoHit);
                    tdi.prepMemoHit = memoHit;  // C51 lever 2 input
                    tdi.hazardPrecomputed = memoHazardComputed;
                    tdi.hazardPrecomputedValue = memoHazard;
                    tdi.mode = mode;
                    tdi.vertexCount = count;
                    tdi.baseVertex = basevertex;
                    tdi.shaderBaseVertex = basevertex;
                    tdi.instanceCount = instancecount;
                    tdi.baseInstance = baseinstance;
                    tdi.vertexData = vbo->shadowBytes.data() + startOff;
                    tdi.vertexDataByteCount = vbo->shadowBytes.size() - startOff;
                    tdi.vertexStride = posStride;
                    tdi.metalVertexBuffer = vbo->metalBuffer;
                    if (impl_->frameGraph != nullptr) {
                        vbo->liveBindSubmitIndex =
                            impl_->frameGraph->openCommandBufferSubmitIndex();
                    }
                    tdi.metalVertexBufferOffset = startOff;
                    tdi.glVertexBuffer = vaoLayout.primaryBufferName;
                    tdi.indices = effectivePtr;
                    tdi.indexCount = count;
                    tdi.indexType = effectiveType;
                    tdi.glIndexBuffer = elementBufferName;
                    // C51: conditionally-set per-draw fields MUST reset
                    // before their conditional on the no-reset (memo HIT)
                    // path — a ubyte-index draw after a direct-index draw
                    // otherwise inherits the previous draw's stale Metal
                    // index buffer (the basevertex 5-case sweep catch).
                    tdi.metalIndexBuffer = nullptr;
                    tdi.metalIndexBufferOffset = 0;
                    if (!elementIndexTypeNeedsExpansion(type) && elementBuffer->metalBuffer != nullptr) {
                        tdi.metalIndexBuffer = elementBuffer->metalBuffer;
                        if (impl_->frameGraph != nullptr) {
                            elementBuffer->liveBindSubmitIndex =
                                impl_->frameGraph->openCommandBufferSubmitIndex();
                        }
                        tdi.metalIndexBufferOffset = indexOffset;
                    }
                    if (!memoHit) {
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
                    tdi.program = programName;
                    tdi.pipelineEmulationFragmentProgram =
                        program->pipelineEmulationFragmentProgram;

                    applyCachedVertexArrayLayout(
                        vaoLayout, *impl_->objects, tdi, 0,
                        false, false, &impl_->coldPathProfile,
                        impl_->frameGraph.get());

                    logStateResolveCostClass(
                        "drawElementsInstancedBaseVertex", programName, vaoName,
                        tdi, vao->attributes.size(), vaoLayoutCacheHit);
                    }  // !memoHit — prepared blocks reused on hit
                    const double bindingConstructionUniformPackUs =
                        impl_->prepareBindingConstructionUniformBuffers(
                            *program, programName, drawID, tdi,
                            "drawElementsInstancedBaseVertex");

                    if (memoHit) {
                        // Sampler resolve always runs (producer drains /
                        // coherence carve-out); its push vectors must not
                        // accumulate across reuse.
                        tdi.fragmentTextures.clear();
                        tdi.vertexTextures.clear();
                        // Stage C: resolveSamplerBindings ALSO appends
                        // per-draw to sampledTextureNames — without this
                        // clear the vector grows across hits and the
                        // wrapper's marking loops go O(n^2) per frame
                        // (the Gate-1 residual: +4.6us/draw on textured
                        // warm arms, invisible on untextured quads).
                        tdi.sampledTextureNames.clear();
                        impl_->resolveSamplerBindings(*program, tdi);
                    } else {
                        impl_->resolveBindingConstructionForTranslatedDraw(
                            *program, tdi, bindingConstructionUniformPackUs);
                    }

                    // RC-A02: resolve FBO render target.
                    if (!memoHit) {
                        GLsizei fboW = 0, fboH = 0;
                        void* fboDSTex = nullptr;
                        std::uint32_t fboDSSlice = 0;
                        std::uint32_t fboDSLevel = 0;
                        std::array<void*, 7> extraColTex = {};
                        std::array<std::uint32_t, 8> colSlices = {};
                        std::array<std::uint32_t, 8> colLevels = {};
                        void* fboColTex = impl_->resolveFBOColorTarget(
                            fboW, fboH, fboDSTex, nullptr,
                            &extraColTex, &colSlices, &colLevels,
                            &fboDSSlice, &fboDSLevel);
                        if (fboColTex != nullptr || fboDSTex != nullptr) {
                            tdi.fboColorTexture = fboColTex;
                            tdi.fboAdditionalColorTextures = extraColTex;
                            tdi.fboColorSlices = colSlices;
                            tdi.fboColorLevels = colLevels;
                            tdi.fboDepthStencilTexture = fboDSTex;
                            tdi.fboDepthStencilSlice = fboDSSlice;
                            tdi.fboDepthStencilLevel = fboDSLevel;
                            tdi.fboWidth = fboW;
                            tdi.fboHeight = fboH;
                        }
                    }

                    thread_local std::string pipelineBuildError;
                    pipelineBuildError.clear();
                    tdi.pipelineBuildErrorOut = &pipelineBuildError;

                    const TranslatedDrawPreflightSnapshot preflight =
                        makeTranslatedDrawPreflightSnapshot(
                            vaoName, vao,
                            /*genericVertexAttributesPrepared=*/false);
                    const bool ok = impl_->encodeTranslatedDrawAndMarkFbo(
                        tdi, &preflight);
                    if (ok) {
                        return true;
                    }
                    if (reportTranslatedFallbackOnce(program, programName,
                            TranslatedFallbackGate::EncodeFailed, "drawElementsInstancedBaseVertex",
                            vaoName, vao->attributes.size(), vaoLayout.primaryBufferName,
                            vbo->shadowBytes.size())) {
                        recordPipelineBuildFailureOnce(program, programName, pipelineBuildError);
                    }
                }
            }
        }
    }

    // Fallback: solid-color draw path (no instancing support in solid-color).
    SolidColorDrawSetup setup = buildSolidColorDrawSetup(
        *impl_->state,
        *impl_->objects,
        mode,
        "glDrawElementsInstancedBaseVertex",
        GL_SHADING_RATE_1X1_PIXELS_EXT
    );
    if (!setup.ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_OTHER,
            0,
            GL_DEBUG_SEVERITY_LOW,
            "glDrawElementsInstancedBaseVertex: draw skipped (no translated pipeline and solid-color path unsupported)"
        );
        return false;
    }

    setup.info.vertexCount = count;
    setup.info.baseVertex = basevertex;
    setup.info.indices = effectivePtr;
    setup.info.indexCount = count;
    setup.info.indexType = effectiveType;

    const bool solidOk = impl_->frameGraph->encodeSolidColorDraw(setup.info);
    if (solidOk) {
        impl_->markBoundDrawFramebufferWrites();
    }
    if (solidOk && impl_->state->boundDrawFramebuffer() == 0) {
        impl_->invalidateDefaultFramebufferShadow();
    }
    if (!solidOk) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_ERROR,
            0,
            GL_DEBUG_SEVERITY_HIGH,
            "glDrawElementsInstancedBaseVertex: MetalFrameGraph failed to encode draw"
        );
    }
    return solidOk;
}

bool GLContext::multiDrawArrays(GLenum mode, const GLint* first, const GLsizei* count, GLsizei drawcount) {
    if (!isValidDrawMode(mode)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (drawcount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (drawcount > 0 && (first == nullptr || count == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei i = 0; i < drawcount; ++i) {
        if (count[i] < 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    for (GLsizei i = 0; i < drawcount; ++i) {
        if (count[i] > 0) {
            drawArrays(mode, first[i], count[i], static_cast<GLuint>(i));
        }
    }
    return true;
}

bool GLContext::multiDrawElements(GLenum mode, const GLsizei* count, GLenum type, const void* const* indices, GLsizei drawcount) {
    if (!isValidDrawMode(mode)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (drawcount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!isSupportedElementIndexType(type)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (drawcount > 0 && (count == nullptr || indices == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei i = 0; i < drawcount; ++i) {
        if (count[i] < 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    for (GLsizei i = 0; i < drawcount; ++i) {
        if (count[i] > 0) {
            drawElements(mode, count[i], type, indices[i], static_cast<GLuint>(i));
        }
    }
    return true;
}

bool GLContext::multiDrawElementsBaseVertex(GLenum mode, const GLsizei* count, GLenum type, const void* const* indices, GLsizei drawcount, const GLint* basevertex) {
    if (!isValidDrawMode(mode)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (drawcount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!isSupportedElementIndexType(type)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // GL 4.6 §10.5: per-sub-draw count must be non-negative. Check
    // ALL entries up-front so an out-of-bounds value doesn't silently
    // drop some sub-draws before the error is reported. CTS
    // `draw_elements_base_vertex_tests.invalid_count_argument` asserts
    // INVALID_VALUE.
    if (count != nullptr) {
        for (GLsizei i = 0; i < drawcount; ++i) {
            if (count[i] < 0) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
        }
    }
    // Multi-draw decomposes into individual draws per the GL spec.
    const bool sparseMultiDrawState =
        impl_->currentDrawStateReferencesSparseBuffer(/*indirectBufferName=*/0);
    for (GLsizei i = 0; i < drawcount; ++i) {
        if (count[i] > 0) {
            const bool forceDrawPrepReset =
                sparseMultiDrawState ||
                drawcount > 1 ||
                static_cast<GLuint>(i) != 0 ||
                basevertex[i] != 0;
            drawElementsBaseVertex(mode, count[i], type, indices[i],
                                   basevertex[i], static_cast<GLuint>(i),
                                   forceDrawPrepReset);
        }
    }
    return true;
}
