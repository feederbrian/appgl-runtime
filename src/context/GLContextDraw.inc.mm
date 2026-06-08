// This file is textually included by GLContext.mm. Do not compile it directly.
// It contains GLContext draw-domain method definitions split out for navigation only.

#if defined(APPGL_GLCONTEXT_DRAW_ARRAYS)
#include "GLContextDrawArrays.inc.mm"

#elif defined(APPGL_GLCONTEXT_DRAW_ELEMENTS)
#include "GLContextDrawElements.inc.mm"

#elif defined(APPGL_GLCONTEXT_DRAW_BASE_VERTEX)
bool GLContext::drawElementsBaseVertex(GLenum mode, GLsizei count, GLenum type, const void* indices, GLint basevertex, GLuint drawID) {
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
            mode, count, type, indices, 1, basevertex, 0, drawID);
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
    impl_->frameGraph->resizeDrawable(impl_->drawableSurfaceWidth(), impl_->drawableSurfaceHeight());
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
                if (impl_->encodeEmulatedGsDraw(*program, programName, ed)) return true;
                if (dcr4eExactNoLegacy) {
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
                    tdi.metalVertexBufferOffset = startOff;
                    tdi.glVertexBuffer = vaoLayout.primaryBufferName;
                    tdi.indices = effectivePtr;
                    tdi.indexCount = count;
                    tdi.indexType = effectiveType;
                    tdi.glIndexBuffer = elementBufferName;
                    if (!elementIndexTypeNeedsExpansion(type) && elementBuffer->metalBuffer != nullptr) {
                        tdi.metalIndexBuffer = elementBuffer->metalBuffer;
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
                    tdi.metalVertexFunction = program->metalVertexFunction;
                    tdi.metalFragmentFunction = program->metalFragmentFunction;
                    tdi.metalVertexFunctionOut = &program->metalVertexFunction;
                    tdi.metalFragmentFunctionOut = &program->metalFragmentFunction;
                    tdi.program = programName;
                    tdi.pipelineEmulationFragmentProgram =
                        program->pipelineEmulationFragmentProgram;

                    applyCachedVertexArrayLayout(
                        vaoLayout, *impl_->objects, tdi, 0,
                        false, false, &impl_->coldPathProfile);

                    logStateResolveCostClass(
                        "drawElementsBaseVertex", programName, vaoName,
                        tdi, vao->attributes.size(), vaoLayoutCacheHit);
                    prepareTranslatedDrawUniformBuffers(
                        *program, programName, impl_->matrixState, drawID, tdi,
                        "drawElementsBaseVertex");

                    impl_->resolveSamplerBindings(*program, tdi);
                    impl_->resolveUBOBindings(*program, tdi);
                    impl_->resolveSSBOBindings(*program, tdi);
                    impl_->resolveImageBindings(*program, tdi);

                    // RC-A02: resolve FBO render target.
                    {
                        GLsizei fboW = 0, fboH = 0;
                        void* fboDSTex = nullptr;
                        std::array<void*, 7> extraColTex = {};
                        std::array<std::uint32_t, 8> colSlices = {};
                        std::array<std::uint32_t, 8> colLevels = {};
                        void* fboColTex = impl_->resolveFBOColorTarget(
                            fboW, fboH, fboDSTex, nullptr,
                            &extraColTex, &colSlices, &colLevels);
                        if (fboColTex != nullptr || fboDSTex != nullptr) {
                            tdi.fboColorTexture = fboColTex;
                            tdi.fboAdditionalColorTextures = extraColTex;
                            tdi.fboColorSlices = colSlices;
                            tdi.fboColorLevels = colLevels;
                            tdi.fboDepthStencilTexture = fboDSTex;
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

bool GLContext::drawElementsInstancedBaseVertex(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLint basevertex, GLuint baseinstance, GLuint drawID) {
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
    impl_->frameGraph->resizeDrawable(impl_->drawableSurfaceWidth(), impl_->drawableSurfaceHeight());
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
                if (impl_->encodeEmulatedGsDraw(*program, programName, ed)) return true;
                if (dcr4eExactNoLegacy) {
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
                    TranslatedDrawInfo& tdi = reusableTranslatedDrawInfo();
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
                    tdi.metalVertexBufferOffset = startOff;
                    tdi.glVertexBuffer = vaoLayout.primaryBufferName;
                    tdi.indices = effectivePtr;
                    tdi.indexCount = count;
                    tdi.indexType = effectiveType;
                    tdi.glIndexBuffer = elementBufferName;
                    if (!elementIndexTypeNeedsExpansion(type) && elementBuffer->metalBuffer != nullptr) {
                        tdi.metalIndexBuffer = elementBuffer->metalBuffer;
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
                    tdi.metalVertexFunction = program->metalVertexFunction;
                    tdi.metalFragmentFunction = program->metalFragmentFunction;
                    tdi.metalVertexFunctionOut = &program->metalVertexFunction;
                    tdi.metalFragmentFunctionOut = &program->metalFragmentFunction;
                    tdi.program = programName;
                    tdi.pipelineEmulationFragmentProgram =
                        program->pipelineEmulationFragmentProgram;

                    applyCachedVertexArrayLayout(
                        vaoLayout, *impl_->objects, tdi, 0,
                        false, false, &impl_->coldPathProfile);

                    logStateResolveCostClass(
                        "drawElementsInstancedBaseVertex", programName, vaoName,
                        tdi, vao->attributes.size(), vaoLayoutCacheHit);
                    prepareTranslatedDrawUniformBuffers(
                        *program, programName, impl_->matrixState, drawID, tdi,
                        "drawElementsInstancedBaseVertex");

                    impl_->resolveSamplerBindings(*program, tdi);
                    impl_->resolveUBOBindings(*program, tdi);
                    impl_->resolveSSBOBindings(*program, tdi);
                    impl_->resolveImageBindings(*program, tdi);

                    // RC-A02: resolve FBO render target.
                    {
                        GLsizei fboW = 0, fboH = 0;
                        void* fboDSTex = nullptr;
                        std::array<void*, 7> extraColTex = {};
                        std::array<std::uint32_t, 8> colSlices = {};
                        std::array<std::uint32_t, 8> colLevels = {};
                        void* fboColTex = impl_->resolveFBOColorTarget(
                            fboW, fboH, fboDSTex, nullptr,
                            &extraColTex, &colSlices, &colLevels);
                        if (fboColTex != nullptr || fboDSTex != nullptr) {
                            tdi.fboColorTexture = fboColTex;
                            tdi.fboAdditionalColorTextures = extraColTex;
                            tdi.fboColorSlices = colSlices;
                            tdi.fboColorLevels = colLevels;
                            tdi.fboDepthStencilTexture = fboDSTex;
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
    for (GLsizei i = 0; i < drawcount; ++i) {
        if (count[i] > 0) {
            drawElementsBaseVertex(mode, count[i], type, indices[i],
                                   basevertex[i], static_cast<GLuint>(i));
        }
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_DRAW_BASE_INSTANCE)
bool GLContext::drawArraysInstancedBaseInstance(GLenum mode, GLint first, GLsizei count, GLsizei instancecount, GLuint baseinstance, GLuint drawID) {
    if (count < 0 || instancecount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (count == 0 || instancecount == 0) {
        return true; // valid no-op
    }
    return drawArraysInstanced(mode, first, count, instancecount, baseinstance, drawID);
}

bool GLContext::drawElementsInstancedBaseInstance(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLuint baseinstance, GLuint drawID) {
    if (count < 0 || instancecount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (type != GL_UNSIGNED_BYTE && type != GL_UNSIGNED_SHORT && type != GL_UNSIGNED_INT) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (count == 0 || instancecount == 0) {
        return true;
    }
    return drawElementsInstancedBaseVertex(mode, count, type, indices,
                                           instancecount, 0, baseinstance, drawID);
}

bool GLContext::drawElementsInstancedBaseVertexBaseInstance(GLenum mode, GLsizei count, GLenum type, const void* indices, GLsizei instancecount, GLint basevertex, GLuint baseinstance, GLuint drawID) {
    if (count < 0 || instancecount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (type != GL_UNSIGNED_BYTE && type != GL_UNSIGNED_SHORT && type != GL_UNSIGNED_INT) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (count == 0 || instancecount == 0) {
        return true;
    }
    return drawElementsInstancedBaseVertex(mode, count, type, indices,
                                           instancecount, basevertex,
                                           baseinstance, drawID);
}

#elif defined(APPGL_GLCONTEXT_DRAW_INDIRECT)
GLuint GLContext::getBoundVertexArray() const {
    return impl_->state->boundVertexArray();
}

bool GLContext::readIndirectBuffer(GLenum target, const void* indirect, std::size_t size, void* out) {
    const GLuint bufName = impl_->state->boundBuffer(target);
    if (bufName != 0) {
        // `indirect` is a byte offset into the bound buffer.
        const auto offset = reinterpret_cast<uintptr_t>(indirect);
        GLBufferObject* buf = impl_->objects->buffers().get(bufName);
        if (buf == nullptr || !buf->instantiated) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        if (offset + size > static_cast<std::size_t>(buf->size)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        if (!impl_->readBufferRange(
                *buf,
                static_cast<GLintptr>(offset),
                static_cast<GLsizeiptr>(size),
                out)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    } else {
        // No buffer bound — `indirect` is a client pointer.
        if (indirect == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        std::memcpy(out, indirect, size);
    }
    return true;
}

// ---------------------------------------------------------------------------
// GL 4.3 — Multi-Draw Indirect
// ---------------------------------------------------------------------------

bool GLContext::multiDrawArraysIndirect(GLenum mode, const void* indirect, GLsizei drawcount, GLsizei stride) {
    if (drawcount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (stride != 0 && stride < 16) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Core profile: drawing with default VAO (0) is INVALID_OPERATION.
    if (impl_->state->boundVertexArray() == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Offset into the indirect buffer must be 4-byte aligned.
    if (reinterpret_cast<uintptr_t>(indirect) % 4 != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // DrawArraysIndirectCommand layout: { count, instanceCount, first, baseInstance }
    struct DrawArraysIndirectCommand {
        GLuint count;
        GLuint instanceCount;
        GLuint first;
        GLuint baseInstance;
    };
    const GLsizei effectiveStride = (stride == 0) ? static_cast<GLsizei>(sizeof(DrawArraysIndirectCommand)) : stride;
    const GLuint indirectBuf = impl_->state->boundBuffer(GL_DRAW_INDIRECT_BUFFER);
    GLBufferObject* indirectObject =
        indirectBuf != 0 ? impl_->objects->buffers().get(indirectBuf) : nullptr;
    const std::uint32_t indirectProducerBits =
        indirectObject != nullptr ? indirectObject->producerPending.bits() : 0u;
    const bool indirectBufferHasGpuProducer =
        indirectObject != nullptr &&
        (indirectObject->producerPending.hasAny(kProducerAll) ||
         indirectObject->gpuAuthoredSinceCpuWrite);
    if (std::getenv("APPGL_TRACE_MDI_PRODUCER")) {
        std::fprintf(stderr,
            "[APPGL] mdi-arrays indirectBuf=%u drawcount=%d stride=%d "
            "pending=0x%08x recentGpuWrite=%d guard=%d\n",
            indirectBuf, drawcount, stride, indirectProducerBits,
            indirectObject != nullptr && indirectObject->gpuAuthoredSinceCpuWrite ? 1 : 0,
            indirectBufferHasGpuProducer ? 1 : 0);
    }

    // GL 4.6 §10.5: pre-validate the indirect-buffer range. See
    // multiDrawElementsIndirect for the full rationale — the check
    // must fire BEFORE any sub-draw so we don't push a cascade of
    // per-draw errors when the buffer has stack-garbage trailer bytes.
    if (drawcount > 0) {
        if (indirectObject != nullptr) {
            const uintptr_t offset = reinterpret_cast<uintptr_t>(indirect);
            const uintptr_t strideBytes = static_cast<uintptr_t>(effectiveStride);
            const uintptr_t commandBytes = static_cast<uintptr_t>(sizeof(DrawArraysIndirectCommand));
            const uintptr_t lastCommandIndex = static_cast<uintptr_t>(drawcount - 1);
            if (lastCommandIndex > (std::numeric_limits<uintptr_t>::max() - offset) / strideBytes) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            const uintptr_t lastCommandOffset = offset + lastCommandIndex * strideBytes;
            const uintptr_t bufferSize = static_cast<uintptr_t>(indirectObject->size);
            if (lastCommandOffset > bufferSize ||
                commandBytes > bufferSize - lastCommandOffset) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
        }
    }
    std::vector<DrawArraysIndirectCommand> commands;
    commands.reserve(static_cast<std::size_t>(std::max<GLsizei>(drawcount, 0)));
    bool canCoalesceContiguous = drawcount > 0;
    GLuint coalescedFirst = 0;
    GLuint coalescedEnd = 0;
    for (GLsizei i = 0; i < drawcount; ++i) {
        const void* cmdPtr = reinterpret_cast<const void*>(
            reinterpret_cast<uintptr_t>(indirect) + static_cast<uintptr_t>(i) * static_cast<uintptr_t>(effectiveStride));
        DrawArraysIndirectCommand cmd{};
        if (!readIndirectBuffer(GL_DRAW_INDIRECT_BUFFER, cmdPtr, sizeof(cmd), &cmd)) {
            return false;
        }
        if (cmd.count == 0 || cmd.instanceCount == 0) {
            canCoalesceContiguous = false;
        } else if (cmd.instanceCount != 1 || cmd.baseInstance != 0) {
            canCoalesceContiguous = false;
        } else if (i == 0) {
            coalescedFirst = cmd.first;
            coalescedEnd = cmd.first + cmd.count;
            if (coalescedEnd < cmd.first) {
                canCoalesceContiguous = false;
            }
        } else if (canCoalesceContiguous && cmd.first == coalescedEnd) {
            coalescedEnd += cmd.count;
            if (coalescedEnd < cmd.first) {
                canCoalesceContiguous = false;
            }
        } else {
            canCoalesceContiguous = false;
        }
        commands.push_back(cmd);
    }

    const bool bypassSamplerRecipeForSparseMdi =
        impl_->currentDrawStateReferencesSparseBuffer(indirectBuf);
    struct ScopedSparseMdiSamplerRecipeBypass {
        GLContext::Impl& impl;
        bool previous = false;
        ScopedSparseMdiSamplerRecipeBypass(GLContext::Impl& target, bool enable)
            : impl(target), previous(target.samplerRecipeCacheBypassForSparseMdi) {
            if (enable) {
                impl.samplerRecipeCacheBypassForSparseMdi = true;
            }
        }
        ~ScopedSparseMdiSamplerRecipeBypass() {
            impl.samplerRecipeCacheBypassForSparseMdi = previous;
        }
    } sparseMdiSamplerRecipeBypass(*impl_, bypassSamplerRecipeForSparseMdi);
    if (bypassSamplerRecipeForSparseMdi &&
        std::getenv("APPGL_TRACE_MDI_PRODUCER")) {
        std::fprintf(stderr,
            "[APPGL] mdi-arrays sampler-recipe bypass reason=sparse-buffer\n");
    }

    // Live layer-backed presents reuse one render encoder for the full
    // frame. On that path, Apple AGX currently fails to make per-subdraw
    // vertex range rebinding observable for VBO-backed MDI walls. When the
    // commands are exactly one CPU-authored contiguous, non-instanced
    // independent-primitive array range and the shader has no draw/primitive
    // ID dependency, the GL-visible result is identical to one drawArrays over
    // the combined range and avoids the fragile per-command encoder state. A
    // GPU-produced indirect buffer must take the per-command path: the first
    // read below drains the producer token, so sampling the pending state before
    // the reads preserves the hazard-aware exclusion.
    const bool canUseCoalescedPath =
        canCoalesceContiguous &&
        !indirectBufferHasGpuProducer &&
        isCoalescibleArrayPrimitiveMode(mode);
    if (std::getenv("APPGL_TRACE_MDI_PRODUCER")) {
        std::fprintf(stderr,
            "[APPGL] mdi-arrays coalesce canContiguous=%d "
            "gpuGuard=%d primitiveMode=%d use=%d\n",
            canCoalesceContiguous ? 1 : 0,
            indirectBufferHasGpuProducer ? 1 : 0,
            isCoalescibleArrayPrimitiveMode(mode) ? 1 : 0,
            canUseCoalescedPath ? 1 : 0);
    }
    if (canUseCoalescedPath) {
        GLuint programName = impl_->state->currentProgram();
        GLProgramObject* program = impl_->resolveDrawProgram(programName);
        const GLuint coalescedCount = coalescedEnd - coalescedFirst;
        if (program != nullptr &&
            !programUsesDrawOrPrimitiveIDDependency(*program, *impl_->objects) &&
            coalescedCount <= static_cast<GLuint>(std::numeric_limits<GLsizei>::max())) {
            return drawArrays(mode,
                              static_cast<GLint>(coalescedFirst),
                              static_cast<GLsizei>(coalescedCount),
                              0);
        }
    }

    for (GLsizei i = 0; i < drawcount; ++i) {
        const auto& cmd = commands[static_cast<std::size_t>(i)];
        if (cmd.count == 0 || cmd.instanceCount == 0) {
            continue;  // valid no-op for this sub-draw
        }
        drawArraysInstancedBaseInstance(mode, static_cast<GLint>(cmd.first),
                                        static_cast<GLsizei>(cmd.count),
                                        static_cast<GLsizei>(cmd.instanceCount),
                                        cmd.baseInstance,
                                        static_cast<GLuint>(i));
    }
    return true;
}

bool GLContext::multiDrawElementsIndirect(GLenum mode, GLenum type, const void* indirect, GLsizei drawcount, GLsizei stride) {
    if (drawcount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (type != GL_UNSIGNED_BYTE && type != GL_UNSIGNED_SHORT && type != GL_UNSIGNED_INT) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (stride != 0 && stride < 20) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Core profile: drawing with default VAO (0) is INVALID_OPERATION.
    if (impl_->state->boundVertexArray() == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Offset into the indirect buffer must be 4-byte aligned.
    if (reinterpret_cast<uintptr_t>(indirect) % 4 != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // DrawElementsIndirectCommand layout: { count, instanceCount, firstIndex, baseVertex, baseInstance }
    struct DrawElementsIndirectCommand {
        GLuint count;
        GLuint instanceCount;
        GLuint firstIndex;
        GLuint baseVertex;
        GLuint baseInstance;
    };
    const GLsizei effectiveStride = (stride == 0) ? static_cast<GLsizei>(sizeof(DrawElementsIndirectCommand)) : stride;
    const GLsizei indexSize = (type == GL_UNSIGNED_INT) ? 4 : (type == GL_UNSIGNED_SHORT) ? 2 : 1;
    const GLuint indirectBuf = impl_->state->boundBuffer(GL_DRAW_INDIRECT_BUFFER);
    GLBufferObject* indirectObject =
        indirectBuf != 0 ? impl_->objects->buffers().get(indirectBuf) : nullptr;

    // GL 4.6 §10.5: the INVALID_OPERATION check for "reading beyond
    // the end of the draw-indirect buffer" must fire BEFORE any
    // sub-draw is issued. Otherwise a partial loop can push a
    // cascade of per-draw errors (e.g. a garbage cmd at i=N-1
    // followed by the OOB at i=N), leaving the error queue with
    // more than one entry and breaking spec-exact error tests.
    if (drawcount > 0) {
        if (indirectObject != nullptr) {
            const uintptr_t offset = reinterpret_cast<uintptr_t>(indirect);
            const uintptr_t strideBytes = static_cast<uintptr_t>(effectiveStride);
            const uintptr_t commandBytes = static_cast<uintptr_t>(sizeof(DrawElementsIndirectCommand));
            const uintptr_t lastCommandIndex = static_cast<uintptr_t>(drawcount - 1);
            if (lastCommandIndex > (std::numeric_limits<uintptr_t>::max() - offset) / strideBytes) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            const uintptr_t lastCommandOffset = offset + lastCommandIndex * strideBytes;
            const uintptr_t bufferSize = static_cast<uintptr_t>(indirectObject->size);
            if (lastCommandOffset > bufferSize ||
                commandBytes > bufferSize - lastCommandOffset) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
        }
    }
    const bool bypassSamplerRecipeForSparseMdi =
        impl_->currentDrawStateReferencesSparseBuffer(indirectBuf);
    struct ScopedSparseMdiSamplerRecipeBypass {
        GLContext::Impl& impl;
        bool previous = false;
        ScopedSparseMdiSamplerRecipeBypass(GLContext::Impl& target, bool enable)
            : impl(target), previous(target.samplerRecipeCacheBypassForSparseMdi) {
            if (enable) {
                impl.samplerRecipeCacheBypassForSparseMdi = true;
            }
        }
        ~ScopedSparseMdiSamplerRecipeBypass() {
            impl.samplerRecipeCacheBypassForSparseMdi = previous;
        }
    } sparseMdiSamplerRecipeBypass(*impl_, bypassSamplerRecipeForSparseMdi);
    if (bypassSamplerRecipeForSparseMdi &&
        std::getenv("APPGL_TRACE_MDI_PRODUCER")) {
        std::fprintf(stderr,
            "[APPGL] mdi-elements sampler-recipe bypass reason=sparse-buffer\n");
    }
    std::vector<DrawElementsIndirectCommand> commands;
    commands.reserve(static_cast<std::size_t>(drawcount));
    for (GLsizei i = 0; i < drawcount; ++i) {
        const void* cmdPtr = reinterpret_cast<const void*>(
            reinterpret_cast<uintptr_t>(indirect) + static_cast<uintptr_t>(i) * static_cast<uintptr_t>(effectiveStride));
        DrawElementsIndirectCommand cmd{};
        if (!readIndirectBuffer(GL_DRAW_INDIRECT_BUFFER, cmdPtr, sizeof(cmd), &cmd)) {
            return false;
        }
        commands.push_back(cmd);
    }
    for (GLsizei i = 0; i < drawcount; ++i) {
        const auto& cmd = commands[static_cast<std::size_t>(i)];
        if (cmd.count == 0 || cmd.instanceCount == 0) {
            continue;
        }
        const void* indexOffset = reinterpret_cast<const void*>(
            static_cast<uintptr_t>(cmd.firstIndex) * static_cast<uintptr_t>(indexSize));
        drawElementsInstancedBaseVertexBaseInstance(mode,
            static_cast<GLsizei>(cmd.count), type, indexOffset,
            static_cast<GLsizei>(cmd.instanceCount),
            static_cast<GLint>(cmd.baseVertex),
            cmd.baseInstance,
            static_cast<GLuint>(i));
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_DRAW_TRANSFORM_FEEDBACK)
bool GLContext::drawTransformFeedback(GLenum mode, GLuint id) {
    GLTransformFeedbackObject* tfObj = impl_->objects->transformFeedbacks().get(id);
    if (tfObj == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Sprint 18 Bank D-2/G Mechanism 3: non-instanced
    // DrawTransformFeedback is equivalent to DrawArrays(mode, 0,
    // completedCount). Keep it separate from the Instanced helper so
    // public DrawTransformFeedbackInstanced(..., 1) continues through
    // the existing drawArraysInstanced path.
    GLsizei vertexCount = tfObj->lastCompletedVertexCount[0];
    if (APPGL_DCR_SENTINEL_HOOK("APPGL_DCR4E_FORCE_STREAM_REPLAY_ZERO_COUNT")) {
        vertexCount = 0;
    }
    appgl::AppGLSubmissionGroup replayGroup;
    impl_->declareStreamReplaySubmissionGroup(replayGroup, id, 0u, vertexCount);
    if (vertexCount <= 0) {
        return true;
    }
    return drawArrays(mode, 0, vertexCount);
}

bool GLContext::drawTransformFeedbackStream(GLenum mode, GLuint id, GLuint stream) {
    GLTransformFeedbackObject* tfObj = impl_->objects->transformFeedbacks().get(id);
    if (tfObj == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const std::size_t streamIdx =
        (stream < GLTransformFeedbackObject::kMaxTransformFeedbackStreams)
            ? static_cast<std::size_t>(stream) : 0u;
    // Sprint 18 Bank D-2/G Mechanism 3: same non-instanced
    // DrawArrays routing as drawTransformFeedback(), but using the
    // completed count for the requested stream.
    GLsizei vertexCount = tfObj->lastCompletedVertexCount[streamIdx];
    if (APPGL_DCR_SENTINEL_HOOK("APPGL_DCR4E_FORCE_STREAM_REPLAY_ZERO_COUNT")) {
        vertexCount = 0;
    }
    appgl::AppGLSubmissionGroup replayGroup;
    impl_->declareStreamReplaySubmissionGroup(replayGroup, id, stream, vertexCount);
    if (vertexCount <= 0) {
        return true;
    }
    return drawArrays(mode, 0, vertexCount);
}

bool GLContext::drawTransformFeedbackInstanced(GLenum mode, GLuint id, GLsizei instancecount) {
    if (instancecount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLTransformFeedbackObject* tfObj = impl_->objects->transformFeedbacks().get(id);
    if (tfObj == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Sprint 8 #9-C (CKPT68): GL 4.6 §10.5 — DrawTransformFeedbackInstanced
    // is equivalent to DrawArraysInstanced(mode, 0, count, instancecount)
    // where `count` is the number of vertices captured during the most
    // recent EndTransformFeedback.
    //
    // Sprint 18 Bank D-2/G: read the last-completed snapshot, not the
    // current-session accumulator. CTS draw_xfb_feedbackk_test begins a
    // new capture on the same object and then draws the previous capture
    // via glDrawTransformFeedback; glBeginTransformFeedback correctly
    // reset capturedVertexCount for the new session, so the draw source
    // has to be lastCompletedVertexCount.
    //
    // CKPT94 #9-C foundation: per-stream array (gl_MaxTransformFeedbackStreams
    // ≥ 4). Non-Stream variant always reads stream 0 per GL 4.6 §10.5 (the
    // non-Stream entry point is implicitly stream 0). Multi-stream
    // accumulators are added Day 23 via GS-emul EmitStreamVertex routing.
    GLsizei vertexCount = tfObj->lastCompletedVertexCount[0];
    if (APPGL_DCR_SENTINEL_HOOK("APPGL_DCR4E_FORCE_STREAM_REPLAY_ZERO_COUNT")) {
        vertexCount = 0;
    }
    appgl::AppGLSubmissionGroup replayGroup;
    impl_->declareStreamReplaySubmissionGroup(replayGroup, id, 0u, vertexCount);
    if (vertexCount <= 0 || instancecount == 0) {
        return true;  // zero-vertex / zero-instance draw is a no-op success
    }
    return drawArraysInstanced(mode, 0, vertexCount, instancecount);
}

bool GLContext::drawTransformFeedbackStreamInstanced(GLenum mode, GLuint id, GLuint stream, GLsizei instancecount) {
    if (instancecount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLTransformFeedbackObject* tfObj = impl_->objects->transformFeedbacks().get(id);
    if (tfObj == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Sprint 8 #9-C remainder (CKPT94 foundation): the stream parameter
    // selects which captured vertex stream to draw from. Sprint 18 Bank
    // D-2/G keeps the DrawTransformFeedbackStream{,Instanced} source in
    // the same last-completed snapshot used by the non-Stream variant;
    // capturedVertexCount remains the in-progress accumulator.
    //
    // Day 23 adds GS-emul EmitStreamVertex routing that populates streams
    // 1..3 during capture; until then capturedVertexCount[1..3] stay at
    // their zero-init values, and the test's stream=0 read continues to
    // work for non-stream-using callers.
    const std::size_t streamIdx =
        (stream < GLTransformFeedbackObject::kMaxTransformFeedbackStreams)
            ? static_cast<std::size_t>(stream) : 0u;
    GLsizei vertexCount = tfObj->lastCompletedVertexCount[streamIdx];
    if (APPGL_DCR_SENTINEL_HOOK("APPGL_DCR4E_FORCE_STREAM_REPLAY_ZERO_COUNT")) {
        vertexCount = 0;
    }
    appgl::AppGLSubmissionGroup replayGroup;
    impl_->declareStreamReplaySubmissionGroup(replayGroup, id, stream, vertexCount);
    if (vertexCount <= 0 || instancecount == 0) {
        return true;
    }
    return drawArraysInstanced(mode, 0, vertexCount, instancecount);
}

#elif defined(APPGL_GLCONTEXT_DRAW_INDIRECT_COUNT_HELPERS)
bool GLContext::validateIndirectCount(GLintptr drawcount, GLsizei maxdrawcount) {
    if (maxdrawcount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (drawcount < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // drawcount is a byte offset; must be a multiple of sizeof(GLsizei)=4.
    if ((drawcount % 4) != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint paramBuffer =
        impl_->state->boundBuffer(GL_PARAMETER_BUFFER);
    if (paramBuffer == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLBufferObject* bo = impl_->objects->buffers().get(paramBuffer);
    if (bo == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // The parameter buffer must contain at least
    // drawcount + 4 (one GLsizei) bytes — enough to read the
    // sub-draw count. Note: the spec does NOT require space for
    // the full maxdrawcount entries; only the count itself.
    if (drawcount + static_cast<GLintptr>(sizeof(GLsizei)) >
        static_cast<GLintptr>(bo->size)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    return true;
}

bool GLContext::resolveIndirectDrawCount(GLintptr drawcount, GLsizei maxdrawcount, GLsizei& actualDrawcount) {
    actualDrawcount = 0;
    if (!validateIndirectCount(drawcount, maxdrawcount)) {
        return false;
    }
    const GLuint paramBuffer =
        impl_->state->boundBuffer(GL_PARAMETER_BUFFER);
    GLBufferObject* bo = impl_->objects->buffers().get(paramBuffer);
    if (bo == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    GLuint rawDrawcount = 0;
    if (!impl_->readBufferRange(
            *bo,
            drawcount,
            static_cast<GLsizeiptr>(sizeof(rawDrawcount)),
            &rawDrawcount)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const GLuint clamped =
        std::min<GLuint>(rawDrawcount, static_cast<GLuint>(maxdrawcount));
    actualDrawcount = static_cast<GLsizei>(clamped);
    return true;
}

#elif defined(APPGL_GLCONTEXT_DRAW_INDIRECT_COUNT)
bool GLContext::multiDrawArraysIndirectCount(GLenum mode, const void* indirect,
                                              GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride) {
    GLsizei actualDrawcount = 0;
    if (!resolveIndirectDrawCount(drawcount, maxdrawcount, actualDrawcount)) return false;
    return multiDrawArraysIndirect(mode, indirect, actualDrawcount, stride);
}

bool GLContext::multiDrawElementsIndirectCount(GLenum mode, GLenum type, const void* indirect,
                                                GLintptr drawcount, GLsizei maxdrawcount, GLsizei stride) {
    GLsizei actualDrawcount = 0;
    if (!resolveIndirectDrawCount(drawcount, maxdrawcount, actualDrawcount)) return false;
    return multiDrawElementsIndirect(mode, type, indirect, actualDrawcount, stride);
}

#else
#error "GLContextDraw.inc.mm included without a draw section selector"
#endif
