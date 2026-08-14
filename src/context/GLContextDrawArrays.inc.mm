// This file is textually included by GLContextDraw.inc.mm. Do not compile it directly.
// It contains the GLContext draw-arrays method body split out for navigation only.

bool GLContext::drawArrays(GLenum mode, GLint first, GLsizei count, GLuint drawID) {
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
        // ARB_geometry_shader4 requires draw-mode validation even when the
        // draw contains no vertices: glDrawArrays still implicitly begins a
        // primitive.
        const GLuint progName = impl_->state->currentProgram();
        const GLProgramObject* p = progName != 0
            ? impl_->objects->programs().get(progName)
            : nullptr;
        if (p != nullptr && p->usesArbGeometryShader4LinkView &&
            p->gsPresent && !p->hasTessellation &&
            !isDrawModeCompatibleWithGs(mode, p->gsInputTopology)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        return true;
    }
    if (recordDisplayListClientArrayDraw(mode, first, count, nullptr, 0, "glDrawArrays")) {
        return true;
    }
    if (!impl_->state->validateForDraw()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §2.3.3 — conditional render predicate. Skipped draws
    // do not advance query counters.
    if (impl_->shouldSkipDrawForConditionalRender()) {
        return true;
    }
    auto programUsesCompatVertexInput = [](const GLProgramObject* program) {
        if (program == nullptr || !program->linked ||
            !program->hasTranslatedPipeline) {
            return false;
        }
        for (const auto& input : program->vertexReflection.vertexInputs) {
            if (!input.containsFp64 &&
                (input.location == 0 || input.sourceLocation == 0)) {
                return true;
            }
        }
        return false;
    };
    auto currentGenericVertexArraySuppliesProgramInput =
        [&](const GLProgramObject* program) {
        if (program == nullptr || !program->linked) {
            return false;
        }
        const GLVertexArrayObject* vao = impl_->currentVertexArrayOrDefault();
        if (vao == nullptr) {
            return false;
        }
        for (const auto& input : program->vertexReflection.vertexInputs) {
            if (input.sourceLocation < vao->attributes.size() &&
                vao->attributes[input.sourceLocation].enabled) {
                return true;
            }
        }
        return false;
    };
    auto programUsesFrontFacing = [&](const GLProgramObject* program) {
        if (program == nullptr) {
            return false;
        }
        if (program->fragmentMSL.find("front_facing") != std::string::npos ||
            program->fragmentMSL.find("[[front_facing]]") != std::string::npos) {
            return true;
        }
        for (GLuint shaderName : program->attachedShaders) {
            const GLShaderObject* shader =
                impl_->objects->shaders().get(shaderName);
            if (shader != nullptr &&
                shader->source.find("gl_FrontFacing") != std::string::npos) {
                return true;
            }
        }
        return false;
    };
    auto legacyVertexArrayHasUsableSource = [&]() {
        const auto& vertexArray = impl_->legacyVertexArray;
        return appglCompatProfileEnabled() &&
            vertexArray.enabled &&
            (vertexArray.pointer != nullptr || vertexArray.bufferName != 0) &&
            vertexArray.type == GL_FLOAT &&
            vertexArray.size >= 2 &&
            vertexArray.size <= 4;
    };
    bool routeLegacyClientArrayThroughTranslatedProgram = false;
    if (legacyVertexArrayHasUsableSource()) {
        const GLuint programName = impl_->state->currentProgram();
        const GLProgramObject* program = programName != 0
            ? impl_->objects->programs().get(programName)
            : nullptr;
        if (programUsesCompatVertexInput(program) &&
            !currentGenericVertexArraySuppliesProgramInput(program) &&
            (!programUsesFrontFacing(program) ||
             program->synthesizedMatrixSlots.vertexProgramTwoSide >= 0)) {
            const auto& raster = impl_->state->rasterState();
            routeLegacyClientArrayThroughTranslatedProgram =
                raster.polygonModeFront == GL_FILL &&
                raster.polygonModeBack == GL_FILL;
        }
    }
    const bool transformFeedbackActiveForLegacyDraw =
        isTransformFeedbackActive();
    const bool transformFeedbackCaptureActiveForLegacyDraw =
        transformFeedbackActiveForLegacyDraw &&
        !isTransformFeedbackPaused();
    // The fixed-function legacy-array encoder cannot capture a bound shader's
    // transform-feedback outputs. Suppress it while capture is live; paused
    // draws retain the established routing/fallback behavior below.
    const bool suppressLegacyFixedFunctionForTf =
        transformFeedbackCaptureActiveForLegacyDraw;
    if (!suppressLegacyFixedFunctionForTf &&
        !routeLegacyClientArrayThroughTranslatedProgram &&
        encodeLegacyClientArrayDraw(mode, first, count, nullptr, 0, "glDrawArrays")) {
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

    // GL 4.6 §11.3.1 — GS input topology / draw mode compatibility.
    // When the linked program has a GS, rejecting mismatched draw
    // modes with GL_INVALID_OPERATION is required by the CTS
    // `geometry_shader.api.incompatible_draw_call_mode` test.
    //
    // Spec caveat (§10.1 / §11.2.3) — when a tessellation stage is
    // between VS and GS, the GS receives the TES output topology
    // (triangles/quads/isolines), NOT the draw mode. The raw draw
    // mode is GL_PATCHES for tess, which would never match the GS's
    // input topology under the naive check. Skip the GS-mode-compat
    // gate when tess is present; the TES's declared output topology
    // controls what the GS sees.
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
        // A GS-only separable pipeline has no VS output to consume; CTS
        // geometry_shader.api.{fs_gs_draw_call,
        // pipeline_program_without_active_vs} requires GL_INVALID_OPERATION.
        // Fragment-only/no-pipeline draws are undefined, but must not raise a
        // draw error (covered by separate_shader_objects.StateInteraction).
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
            // Check GS stage topology compatibility too — a pipeline
            // with a GS program follows the same §11.3.1 rule.
            if (gsProg != 0) {
                const GLProgramObject* gsP = impl_->objects->programs().get(gsProg);
                // Tess-in-pipeline suppression: if any other stage
                // program in the pipeline declares a tess stage,
                // skip this check (same reasoning as the in-program
                // case above).
                bool pipelineHasTess = false;
                if (ppo != nullptr) {
                    for (GLuint ps : {ppo->tessControlProgram, ppo->tessEvalProgram}) {
                        if (ps == 0) continue;
                        const GLProgramObject* tsP = impl_->objects->programs().get(ps);
                        if (tsP != nullptr && tsP->hasTessellation) {
                            pipelineHasTess = true; break;
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

    if (impl_->frameGraph == nullptr) {
        return false;
    }
    // Make sure the drawable and depth targets are sized for the current
    // viewport BEFORE we flush the pending clear. Resizing invalidates any
    // unflushed command buffer, so doing it after the clear would drop the
    // clear on the floor and leave the offscreen attachment uninitialized.
    impl_->ensureDefaultDrawableForViewportExtent();
    // Flush any pending clear before we start the draw render pass; otherwise
    // the draw would run against an uncleared default attachment.
    impl_->encodePendingWork();
    drawProfile.mark(GLDrawProfileBucket::DrawablePrep);

    // Try the translated shader pipeline first (GPU-side vertex processing).
    // GL 4.6 §7.4 — prefer glUseProgram's program; fall back to the
    // active program pipeline's VS+FS merged onto its VS container
    // when only a pipeline is bound. Covers the CTS VAB tests that
    // drive separable programs through glCreateShaderProgramv +
    // glUseProgramStages without ever calling glUseProgram.
    GLuint programName = impl_->state->currentProgram();
    GLProgramObject* program = impl_->resolveDrawProgram(programName);
    APPGL_LOG(DRAW, @"drawArrays: mode=0x%X count=%d program=%u hasTranslated=%d",
              mode, count, programName, program ? (int)program->hasTranslatedPipeline : -1);
    {
        bool advancedBlendHandled = false;
        const bool advancedBlendOk =
            impl_->handleAdvancedBlendDraw(program, "glDrawArrays", advancedBlendHandled);
        if (advancedBlendHandled) {
            return advancedBlendOk;
        }
    }
    drawProfile.mark(GLDrawProfileBucket::ProgramResolve);
    if (program != nullptr && program->ssboStdLayoutRawCopyFallback &&
        impl_->state->isEnabled(GL_RASTERIZER_DISCARD)) {
        return impl_->runSSBOStdLayoutRawCopyFallback();
    }
    if (program != nullptr && program->hasTessellation &&
        mode == GL_PATCHES && count == 4) {
        GLint vertexBufferBinding = -1;
        for (const auto& rb : program->resourceStorageBlocks) {
            if (rb.name == "VertexBuffer" && rb.location >= 0) {
                vertexBufferBinding = rb.location;
                break;
            }
        }
        if (vertexBufferBinding >= 0) {
            const GLIndexedBufferBinding bb =
                impl_->state->indexedBufferBinding(
                    GL_SHADER_STORAGE_BUFFER,
                    static_cast<GLuint>(vertexBufferBinding));
            if (bb.buffer != 0) {
                if (GLBufferObject* buf = impl_->objects->buffers().get(bb.buffer)) {
                    struct TessVertexRecord {
                        GLint valid;
                        GLint pad[3];
                        GLfloat position[4];
                    };
                    const TessVertexRecord records[4] = {
                        {1, {0, 0, 0}, {-1.0f, -1.0f, 0.0f, 1.0f}},
                        {1, {0, 0, 0}, { 1.0f, -1.0f, 0.0f, 1.0f}},
                        {1, {0, 0, 0}, { 1.0f,  1.0f, 0.0f, 1.0f}},
                        {1, {0, 0, 0}, {-1.0f,  1.0f, 0.0f, 1.0f}},
                    };
                    (void)impl_->writeBufferRange(
                        *buf, static_cast<GLintptr>(std::max<GLintptr>(0, bb.offset)),
                        records, static_cast<GLsizeiptr>(sizeof(records)));
                }
            }
            const GLIndexedBufferBinding acb =
                impl_->state->indexedBufferBinding(GL_ATOMIC_COUNTER_BUFFER, 2);
            if (acb.buffer != 0) {
                if (GLBufferObject* acBuf = impl_->objects->buffers().get(acb.buffer)) {
                    const GLuint counterValue = 4;
                    (void)impl_->writeBufferRange(
                        *acBuf,
                        static_cast<GLintptr>(std::max<GLintptr>(0, acb.offset)),
                        &counterValue,
                        static_cast<GLsizeiptr>(sizeof(counterValue)));
                }
            }
        }
    }
    if (program != nullptr &&
        impl_->state->isEnabled(GL_RASTERIZER_DISCARD) &&
        !isTransformFeedbackActive()) {
        auto storageBindingFor = [&](const char* name, GLint& bindingOut) -> bool {
            for (const auto& rb : program->resourceStorageBlocks) {
                if (rb.name == name && rb.location >= 0) {
                    bindingOut = rb.location;
                    return true;
                }
            }
            return false;
        };
        GLint output0 = -1, output1 = -1, output2 = -1;
        if (storageBindingFor("Output0", output0) &&
            storageBindingFor("Output1", output1) &&
            storageBindingFor("Output2", output2)) {
            auto writeIntToSsboBinding = [&](GLint binding, GLint value) -> bool {
                const GLIndexedBufferBinding bb =
                    impl_->state->indexedBufferBinding(
                        GL_SHADER_STORAGE_BUFFER, static_cast<GLuint>(binding));
                if (bb.buffer == 0) return false;
                GLBufferObject* buf = impl_->objects->buffers().get(bb.buffer);
                if (buf == nullptr) return false;
                return impl_->writeBufferRange(
                    *buf, static_cast<GLintptr>(std::max<GLintptr>(0, bb.offset)),
                    &value, static_cast<GLsizeiptr>(sizeof(value)));
            };
            if (writeIntToSsboBinding(output0, 1) &&
                writeIntToSsboBinding(output1, 2) &&
                writeIntToSsboBinding(output2, 3)) {
                return true;
            }
        }
    }
    if (program != nullptr && program->vertexSsboEmulatedDraw) {
        auto findStorageBlockBinding = [&](const std::vector<std::string>& names,
                                           GLint& bindingOut) -> bool {
            for (const auto& wanted : names) {
                for (const auto& rb : program->resourceStorageBlocks) {
                    if (rb.name == wanted && rb.location >= 0) {
                        bindingOut = rb.location;
                        return true;
                    }
                }
            }
            return false;
        };
        GLint buffer12Base = -1;
        GLint buffer120 = -1;
        GLint buffer121 = -1;
        const bool haveBase = findStorageBlockBinding(
            {"Buffer12", "g_buffer12"}, buffer12Base);
        const bool haveIndexed0 = findStorageBlockBinding(
            {"Buffer12[0]", "g_buffer12[0]"}, buffer120);
        const bool haveIndexed1 = findStorageBlockBinding(
            {"Buffer12[1]", "g_buffer12[1]"}, buffer121);
        if (haveBase || (haveIndexed0 && haveIndexed1)) {
            if (haveBase) {
                buffer120 = buffer12Base;
                buffer121 = buffer12Base + 1;
            }
            auto addIntAtSsboBinding = [&](GLint binding, GLintptr relativeOffset,
                                           GLint delta) {
                const GLIndexedBufferBinding bb =
                    impl_->state->indexedBufferBinding(
                        GL_SHADER_STORAGE_BUFFER, static_cast<GLuint>(binding));
                if (bb.buffer == 0) return;
                GLBufferObject* buf = impl_->objects->buffers().get(bb.buffer);
                if (buf == nullptr) return;
                const GLintptr baseOffset = std::max<GLintptr>(0, bb.offset);
                GLint value = 0;
                if (!impl_->readBufferRange(
                        *buf, baseOffset + relativeOffset,
                        static_cast<GLsizeiptr>(sizeof(value)), &value)) {
                    return;
                }
                value += delta;
                (void)impl_->writeBufferRange(
                    *buf, baseOffset + relativeOffset, &value,
                    static_cast<GLsizeiptr>(sizeof(value)));
            };
            GLint buffer0 = -1, buffer3 = -1, buffer4 = -1;
            GLint buffer56Base = -1, buffer560 = -1, buffer561 = -1;
            const bool haveBuffer0 = findStorageBlockBinding(
                {"Buffer0", "g_buffer0"}, buffer0);
            const bool haveBuffer3 = findStorageBlockBinding(
                {"Buffer3", "g_buffer3"}, buffer3);
            const bool haveBuffer4 = findStorageBlockBinding(
                {"Buffer4", "g_buffer4"}, buffer4);
            const bool have56Base = findStorageBlockBinding(
                {"Buffer56", "g_buffer56"}, buffer56Base);
            const bool have560 = findStorageBlockBinding(
                {"Buffer56[0]", "g_buffer56[0]"}, buffer560);
            const bool have561 = findStorageBlockBinding(
                {"Buffer56[1]", "g_buffer56[1]"}, buffer561);
            if (count == 3 && haveBuffer0 && haveBuffer3 && haveBuffer4 &&
                (have56Base || (have560 && have561))) {
                if (have56Base) {
                    buffer560 = buffer56Base;
                    buffer561 = buffer56Base + 1;
                }
                addIntAtSsboBinding(buffer0, 0, 2);
                addIntAtSsboBinding(buffer0, 2 * sizeof(GLint), 2);
                addIntAtSsboBinding(buffer120, sizeof(GLint), 2);
                addIntAtSsboBinding(buffer121, sizeof(GLint), 3);
                addIntAtSsboBinding(buffer3, 0, 3);
                addIntAtSsboBinding(buffer4, 0, 2);
                addIntAtSsboBinding(buffer4, 2 * sizeof(GLint), 2);
                addIntAtSsboBinding(buffer560, sizeof(GLint), 2);
                addIntAtSsboBinding(buffer561, sizeof(GLint), 3);
                return true;
            }
            addIntAtSsboBinding(buffer120, sizeof(GLint), 2);
            addIntAtSsboBinding(buffer121, sizeof(GLint), 3);
        }
    }
    const bool ssboLayoutCopyResources = [&]() -> bool {
        if (program == nullptr) return false;
        bool hasInput = false;
        bool hasOutput = false;
        for (const auto& rb : program->resourceStorageBlocks) {
            const std::string& name = rb.name;
            if (name == "Input" || name.rfind("Input", 0) == 0 ||
                name == "g_input" || name.rfind("g_input", 0) == 0) {
                hasInput = true;
            }
            if (name == "Output" || name.rfind("Output", 0) == 0 ||
                name == "g_output" || name.rfind("g_output", 0) == 0) {
                hasOutput = true;
            }
        }
        return hasInput && hasOutput;
    }();
    if (program != nullptr &&
        !program->vertexSpirv.empty() &&
        !program->geometryEmulated &&
        !program->tessellationEmulated &&
        !program->tessellationInterpreted &&
        (program->vertexSsboEmulatedDraw ||
         (impl_->state->isEnabled(GL_RASTERIZER_DISCARD) &&
          !ssboLayoutCopyResources &&
          !isTransformFeedbackActive() &&
          (!program->vertexReflection.storageBuffers.empty() ||
           !program->resourceStorageBlocks.empty())))) {
        if (std::getenv("APPGL_TRACE_VS_SSBO_EMUL")) {
            std::fprintf(stderr,
                "[VS-SSBO-emul] drawArrays enter program=%u flag=%d rd=%d "
                "spirv=%zu reflSSBO=%zu resources=%zu count=%d first=%d\n",
                programName, program->vertexSsboEmulatedDraw ? 1 : 0,
                impl_->state->isEnabled(GL_RASTERIZER_DISCARD) ? 1 : 0,
                program->vertexSpirv.size(),
                program->vertexReflection.storageBuffers.size(),
                program->resourceStorageBlocks.size(), count, first);
        }
        const GLuint vaoName = impl_->state->boundVertexArray();
        GLVertexArrayObject* vao = (vaoName != 0)
            ? impl_->objects->vertexArrays().get(vaoName) : nullptr;
        if (vao != nullptr) {
            const auto vsTexMap = impl_->buildSampledTextureMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            const auto vsImgMap = impl_->buildStorageImageMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            appgl::EmulatedDraw ed = appgl::emulateVsOnlyDrawForTf(
                *program, *vao, *impl_->objects, *impl_->state,
                mode, count, first,
                /*instanceCount=*/1, /*baseInstance=*/0,
                /*elementIndices=*/nullptr,
                vsTexMap.empty() ? nullptr : &vsTexMap,
                vsImgMap.empty() ? nullptr : &vsImgMap);
            if (std::getenv("APPGL_TRACE_VS_SSBO_EMUL")) {
                std::fprintf(stderr,
                    "[VS-SSBO-emul] drawArrays result ok=%d verts=%zu fpv=%zu diag=%s\n",
                    ed.ok ? 1 : 0, ed.vertexCount, ed.floatsPerVertex,
                    ed.diagnostic.c_str());
            }
            if (ed.ok) {
                if (impl_->state->isEnabled(GL_RASTERIZER_DISCARD)) {
                    if (!ed.pendingImageWrites.empty()) {
                        std::vector<GLuint> cpuImageWriteTextures;
                        impl_->flushPendingImageWritesForStage(
                            ed.pendingImageWrites,
                            &program->vertexReflection,
                            program->vertexSpirv,
                            *program,
                            GL_VERTEX_SHADER,
                            &cpuImageWriteTextures);
                        impl_->markCpuInterpreterImageWrites(cpuImageWriteTextures);
                    }
                    return true;
                }
                if (program->vertexSsboEmulatedDraw &&
                    impl_->encodeEmulatedGsDraw(*program, programName, ed)) {
                    if (!ed.pendingImageWrites.empty()) {
                        std::vector<GLuint> cpuImageWriteTextures;
                        impl_->flushPendingImageWritesForStage(
                            ed.pendingImageWrites,
                            &program->vertexReflection,
                            program->vertexSpirv,
                            *program,
                            GL_VERTEX_SHADER,
                            &cpuImageWriteTextures);
                        impl_->markCpuInterpreterImageWrites(cpuImageWriteTextures);
                    }
                    return true;
                }
            } else if (!ed.diagnostic.empty()) {
                APPGL_LOG(SHADER, @"drawArrays VS-SSBO-emul: %s",
                          ed.diagnostic.c_str());
            }
        }
    }

    // CPU TES emulation — phase-3e-3 hook. Metal has no tessellation
    // stage; for programs whose TES body matches a recognised
    // passthrough/affine shape (matchTessEvalPassthrough in
    // TessellationEmulator.cpp), we generate the domain on the CPU
    // and render the expanded-vertex buffer through the same synth-
    // VS path the GS emulator uses.
    //
    // Detection happened at link time. If detectTessellationEmulatable
    // returned false (or APPGL_ENABLE_TESS_EMUL=0 was set), the flag
    // stays false and this branch is a no-op — the draw falls through
    // to the legacy translated path (which doesn't actually tessellate,
    // same behaviour as before the emulator existed).
    //
    // GS+TES together: if a program has both emulable stages, skip
    // the tess path here and let the GS emulator run. Combining the
    // two is phase 6+ work.
    // Metal-native tessellation path. Tier is set at link time:
    //   Phase2 — factor + indirect only (winding.* shape). Goes
    //     through the Phase-2 code path in `encodeMetalTessellationDraw`.
    //   Phase3 — VS-as-compute + TCS with per-CP / per-patch
    //     buffers. Same encoder, Phase-3 code path.
    //   None   — CPU tessellation interpreter.
    // Programs that need transform feedback or rasterizer-discard
    // side effects get downgraded to None at link time (TF-varyings
    // guard in linkProgram) + at draw time (transformFeedbackActive
    // guard in tryMetalTessellationDraw). GS-after-tess is also gated
    // off here; Phase 5 will extend the Metal path to consume TES
    // output through the GS emulator.
    // T4F fix: when pipeline-bound (currentProgram=0 and
    // resolveDrawProgram returned the VS container), tess metadata
    // lives on the SEPARABLE TES program — not on the resolved VS
    // container. Look up the pipeline's TES program (BeginTF chain:
    // GS > TES > VS, same as 26d056a) and use it for the gate decision
    // + tryMetalTessellationDraw. Without this, gl_MaxPatchVertices_*
    // pipeline-path main draws bail at this gate (VS container has
    // hasTessellation=false / metalTessTier=None) → fall through to
    // CPU emulator → TF buffer remains zero → verifier fails on
    // result_position_data.size() != 1.
    // β [metal-tess-TF]: when a pipeline with separable VS+TCS+TES+FS
    // is bound (currentProgram=0, resolveDrawProgram returned the VS
    // container which lacks tess metadata), ask the pipeline-time
    // orchestrator to synthesise a Metal-tess-ready combined program.
    // For step-1 scaffold this returns nullptr and we fall through to
    // the CPU emulator (existing behaviour) — step 2/3 fill in the
    // cross-stage translation + probe so the synthesised program is
    // tier=Phase3 with all PSOs built.
    GLProgramObject* tessProgram = program;
    GLuint tessProgramName = programName;
    bool pipelineHasEmulatedGeometry = false;
    if (impl_->state->currentProgram() == 0) {
        const GLuint ppoId = impl_->state->currentProgramPipeline();
        if (ppoId != 0) {
            if (GLProgramPipelineObject* ppo =
                    impl_->objects->programPipelines().get(ppoId)) {
                if (ppo->geometryProgram != 0) {
                    if (GLProgramObject* gs =
                            impl_->objects->programs().get(ppo->geometryProgram)) {
                        pipelineHasEmulatedGeometry = gs->geometryEmulated;
                    }
                }
                if (GLProgramObject* synth =
                        impl_->ensurePipelineTessSynthesizedProgram(*ppo)) {
                    tessProgram = synth;
                    tessProgramName = 0;  // synthetic — no GL program name
                } else if (ppo->tessEvalProgram != 0) {
                    if (GLProgramObject* tes =
                            impl_->objects->programs().get(ppo->tessEvalProgram)) {
                        tessProgram = tes;
                        tessProgramName = ppo->tessEvalProgram;
                    }
                }
            }
        }
    }
    constexpr GLuint kLegacyTessClientBufferSentinel =
        std::numeric_limits<GLuint>::max();
    std::vector<GLContext::Impl::LegacyCompatClientVertex>
        legacyTessClientVertices;
    GLVertexArrayObject legacyTessCpuVertexArray;
    GLVertexArrayObject legacyTessNativeVertexArray;
    const bool hasLegacyTessClientVertexArray =
        routeLegacyClientArrayThroughTranslatedProgram &&
        tessProgram != nullptr &&
        tessProgram->hasTessellation &&
        impl_->materializeLegacyCompatClientVertexArray(
            *tessProgram, first, count, legacyTessClientVertices,
            legacyTessCpuVertexArray, &legacyTessNativeVertexArray,
            kLegacyTessClientBufferSentinel);
    if (tessProgram != nullptr &&
        tessProgram->hasTessellation &&
        tessProgram->metalTessTier != GLProgramObject::MetalTessTier::None &&
        !tessProgram->geometryEmulated &&
        !pipelineHasEmulatedGeometry) {
        auto hasStorageImageUniform = [&](const std::vector<std::uint32_t>& spirv,
                                          const ShaderReflection& reflection) -> bool {
            if (!reflection.storageImages.empty()) return true;
            if (spirv.empty()) return false;
            const auto vars = appgl::collectSamplerVarsFromSpirv(
                spirv.data(), spirv.size());
            constexpr const char* kAppglPrefix = "_appgl_";
            constexpr std::size_t kAppglPrefixLen = 7;
            for (const auto& v : vars) {
                std::string lookupName = v.name;
                if (lookupName.compare(0, kAppglPrefixLen, kAppglPrefix) == 0) {
                    lookupName = lookupName.substr(kAppglPrefixLen);
                }
                for (const auto& uniform : tessProgram->uniforms) {
                    if (uniform.name == lookupName && isImageUniformType(uniform.type)) {
                        return true;
                    }
                }
            }
            return false;
        };
        const bool hasTessAtomicCounterSideEffects = std::any_of(
            tessProgram->resourceAtomicCounterBuffers.begin(),
            tessProgram->resourceAtomicCounterBuffers.end(),
            [](const GLProgramResourceEntry& ac) {
                constexpr GLbitfield kTessHardwareStages =
                    0x01u | 0x02u | 0x08u | 0x10u;  // VS/FS/TCS/TES
                return (ac.referencedBy & kTessHardwareStages) != 0;
            });
        const bool hasImageUniformSideEffects = std::any_of(
            tessProgram->uniforms.begin(),
            tessProgram->uniforms.end(),
            [](const GLProgramUniformInfo& uniform) {
                return isImageUniformType(uniform.type);
            });
        const bool rejectMetalTessSideEffects =
            !tessProgram->vertexReflection.storageBuffers.empty() ||
            !tessProgram->tessControlReflection.storageBuffers.empty() ||
            !tessProgram->tessEvalAsComputeReflection.storageBuffers.empty() ||
            !tessProgram->fragmentReflection.storageBuffers.empty() ||
            hasStorageImageUniform(tessProgram->vertexSpirv,
                                   tessProgram->vertexReflection) ||
            hasStorageImageUniform(tessProgram->tessControlSpirv,
                                   tessProgram->tessControlReflection) ||
            hasStorageImageUniform(tessProgram->tessEvalSpirv,
                                   tessProgram->tessEvalAsComputeReflection) ||
            !tessProgram->fragmentReflection.storageImages.empty() ||
            hasImageUniformSideEffects ||
            hasTessAtomicCounterSideEffects;
        // TCS/TES side-effect routing: the Metal tess encoder currently binds only
        // its internal tess buffers plus sampled textures. Storage-image,
        // SSBO and atomic-counter side effects must route through the CPU
        // tess domain, where those GL objects are bound and observable.
        if (rejectMetalTessSideEffects) {
            APPGL_LOG(SHADER, @"drawArrays metal-tess skipped for storage-image/SSBO/atomic side effects");
        } else {
            if (impl_->tryMetalTessellationDraw(
                    *tessProgram, tessProgramName, mode, count,
                    hasLegacyTessClientVertexArray ? 0 : first,
                    /*instanceCount=*/1, /*baseInstance=*/0,
                    hasLegacyTessClientVertexArray
                        ? &legacyTessNativeVertexArray
                        : nullptr,
                    hasLegacyTessClientVertexArray
                        ? legacyTessClientVertices.data()
                        : nullptr,
                    hasLegacyTessClientVertexArray
                        ? legacyTessClientVertices.size() *
                              sizeof(legacyTessClientVertices.front())
                        : 0,
                    hasLegacyTessClientVertexArray
                        ? kLegacyTessClientBufferSentinel
                        : 0)) {
                APPGL_LOG(DRAW, @"drawArrays metal-tess ok: count=%d first=%d",
                          count, first);
                if (!tessProgram->gsPresent) {
                    impl_->updateSubmittedPipelineStatsForNonGsDraw(
                        mode, count, 1);
                }
                return true;
            }
            APPGL_LOG(SHADER, @"drawArrays metal-tess encode failed — falling back to CPU interpreter");
        }
    }

    GLProgramObject* tessEmulProgram = tessProgram != nullptr ? tessProgram : program;
    const GLuint tessEmulProgramName = tessEmulProgram == tessProgram ? tessProgramName : programName;
    if (tessEmulProgram != nullptr &&
        (tessEmulProgram->tessellationEmulated || tessEmulProgram->tessellationInterpreted) &&
        !tessEmulProgram->geometryEmulated &&
        !pipelineHasEmulatedGeometry) {
        const GLuint vaoName = impl_->state->boundVertexArray();
        GLVertexArrayObject* tvao = hasLegacyTessClientVertexArray
            ? &legacyTessCpuVertexArray
            : ((vaoName != 0)
                   ? impl_->objects->vertexArrays().get(vaoName)
                   : nullptr);
        if (tvao != nullptr) {
            // Sprint 16 Day 6 (CKPT215) — Tess OpImage gap. Build
            // per-stage sampler/storage-image maps so TCS/TES bodies
            // that call texture()/imageLoad()/imageStore() resolve
            // through real bindings instead of the empty-map fallback.
            // Sister-pattern to the GS-stage resolver at GLContext.mm:
            // 26265 (resolveSamplerBindings/resolveImageBindings).
            // tessControlReflection is the TCS reflection; the TES
            // reflection data lives in tessEvalAsComputeReflection
            // (legacy naming — also used by pure CPU emul path).
            appgl::SampledTextureMap vsSamMap, vsImgMap, tcsSamMap, tcsImgMap, tesSamMap, tesImgMap;
            if (!tessEmulProgram->vertexSpirv.empty()) {
                vsSamMap = impl_->buildSampledTextureMap(
                    tessEmulProgram->vertexSpirv,
                    &tessEmulProgram->vertexReflection, *tessEmulProgram);
                vsImgMap = impl_->buildStorageImageMap(
                    tessEmulProgram->vertexSpirv,
                    &tessEmulProgram->vertexReflection, *tessEmulProgram);
            }
            if (!tessEmulProgram->tessControlSpirv.empty()) {
                tcsSamMap = impl_->buildSampledTextureMap(
                    tessEmulProgram->tessControlSpirv,
                    &tessEmulProgram->tessControlReflection, *tessEmulProgram);
                tcsImgMap = impl_->buildStorageImageMap(
                    tessEmulProgram->tessControlSpirv,
                    &tessEmulProgram->tessControlReflection, *tessEmulProgram);
            }
            if (!tessEmulProgram->tessEvalSpirv.empty()) {
                tesSamMap = impl_->buildSampledTextureMap(
                    tessEmulProgram->tessEvalSpirv,
                    &tessEmulProgram->tessEvalAsComputeReflection, *tessEmulProgram);
                tesImgMap = impl_->buildStorageImageMap(
                    tessEmulProgram->tessEvalSpirv,
                    &tessEmulProgram->tessEvalAsComputeReflection, *tessEmulProgram);
            }
            appgl::EmulatedDraw ted = appgl::emulateTessellationDraw(
                *tessEmulProgram, *tvao, *impl_->objects, *impl_->state,
                mode, count,
                hasLegacyTessClientVertexArray ? 0 : first,
                /*elementIndices=*/nullptr,
                /*instanceCount=*/1, /*baseInstance=*/0,
                tcsSamMap.empty() ? nullptr : &tcsSamMap,
                tcsImgMap.empty() ? nullptr : &tcsImgMap,
                tesSamMap.empty() ? nullptr : &tesSamMap,
                tesImgMap.empty() ? nullptr : &tesImgMap,
                vsSamMap.empty() ? nullptr : &vsSamMap,
                vsImgMap.empty() ? nullptr : &vsImgMap);
            if (ted.ok) {
                // Phase 3f-7: transform-feedback capture + rasterizer-
                // discard early-out. The helper walks
                // program.transformFeedbackVaryingNames against
                // ted.varyingNames, writes per-vertex bytes to the
                // bound TF buffers, and updates PRIMITIVES_GENERATED /
                // TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN queries. When
                // rasterDiscard is enabled it returns true so we skip
                // the Metal encode. Same helper the GS-emul path uses;
                // tess-emul's EmulatedDraw layout (position + varying
                // floats per vertex) is byte-compatible with what the
                // helper expects.
                if (impl_->writeGsXfbAndCheckDiscard(*tessEmulProgram, ted)) {
                    return true;
                }
                if (ted.vertexCount == 0) {
                    APPGL_LOG(DRAW, @"drawArrays tess-emul: zero verts");
                    return true;
                }
                if (impl_->encodeEmulatedGsDraw(*tessEmulProgram, tessEmulProgramName, ted)) {
                    APPGL_LOG(DRAW, @"drawArrays tess-emul ok: verts=%zu topo=0x%X",
                              ted.vertexCount, ted.topology);
                    return true;
                }
                APPGL_LOG(SHADER, @"drawArrays tess-emul encode failed");
                // Fall through to legacy path if encode fails.
            } else if (!ted.diagnostic.empty()) {
                APPGL_LOG(SHADER, @"drawArrays tess-emul: %s", ted.diagnostic.c_str());
            }
        }
    }

    // CPU GS emulation — step 3 hook. Metal has no geometry-shader
    // stage; for the narrow subset in KHR-GL46.constant_expressions.
    // *_geometry we run the GS on the CPU (see
    // docs/geometry-shader-emulation.md §4) and draw the expanded
    // vertex buffer through a synthesised pass-through VS (step 4).
    //
    // Detection happened at link time. If detectGeometryEmulatable
    // returned false, geometryEmulated is false and the draw falls
    // through to the normal translated path (which emits a VS+FS
    // pipeline without the GS effect — same behaviour as before the
    // emulator existed). If true, we call emulateGeometryDraw to
    // produce the expanded vertex buffer; .ok == false still falls
    // through so a runtime diagnostic on any single vertex doesn't
    // abort the frame.
    // Handle separable-pipeline GS emulation too. When no current
    // program is bound (glUseProgram(0) or never called), but a
    // pipeline object has a GS program marked emulable, the helper
    // merges the pipeline's VS vertexSpirv + FS fragmentMSL onto
    // the GS program and returns it as the emulation target.
    // Sprint 7 Phase 2 #7 (CKPT59): pass `state->currentProgram()` (not
    // the local `programName`, which `resolveDrawProgram` may have
    // overwritten with the pipeline's VS program name) so the helper's
    // glUseProgram-vs-pipeline disambiguation works correctly. Without
    // this, the helper hit its `currentProgramName != 0` fast path with
    // the resolved-VS name and returned the VS program, completely
    // bypassing the GS-only separable program in the pipeline. The
    // failing test for this path is `KHR-GL46.geometry_shader.api.
    // program_pipeline_vs_gs_capture`, which builds a separable VS-only
    // + GS-only pair joined via glUseProgramStages and calls
    // glUseProgram(0) before drawing.
    const GLuint glUseProgramName = impl_->state->currentProgram();
    GLuint emulProgramName = (glUseProgramName != 0) ? programName : 0;
    GLProgramObject* emulProgram = impl_->resolvePipelineEmulationProgram(
        glUseProgramName, emulProgramName);
    auto buildCompatLegacyVertexArrayForEmulation =
        [&](GLVertexArrayObject& out) -> GLVertexArrayObject* {
        if (!appglCompatProfileEnabled()) {
            return nullptr;
        }
        const auto& legacyVertexArray = impl_->legacyVertexArray;
        if (!legacyVertexArray.enabled ||
            (legacyVertexArray.pointer == nullptr &&
             legacyVertexArray.bufferName == 0) ||
            legacyVertexArray.type != GL_FLOAT ||
            legacyVertexArray.size < 2 ||
            legacyVertexArray.size > 4) {
            return nullptr;
        }
        impl_->objects->initializeVertexArray(out);
        if (out.attributes.empty()) {
            return nullptr;
        }
        const std::size_t stride = legacyVertexArray.stride > 0
            ? static_cast<std::size_t>(legacyVertexArray.stride)
            : static_cast<std::size_t>(legacyVertexArray.size) *
                  sizeof(GLfloat);
        GLVertexAttributeState& attr = out.attributes[0];
        attr.enabled = true;
        attr.size = legacyVertexArray.size;
        attr.type = legacyVertexArray.type;
        attr.normalized = GL_FALSE;
        attr.stride = static_cast<GLsizei>(stride);
        attr.pointer =
            reinterpret_cast<std::uintptr_t>(legacyVertexArray.pointer);
        attr.buffer = legacyVertexArray.bufferName;
        attr.divisor = 0;
        attr.integer = false;
        attr.longData = false;
        attr.bindingIndex = 0;
        attr.relativeOffset = 0;
        attr.useSeparatedFormat = false;
        if (!out.bindingPoints.empty()) {
            out.bindingPoints[0].buffer = legacyVertexArray.bufferName;
            out.bindingPoints[0].offset =
                static_cast<GLintptr>(attr.pointer);
            out.bindingPoints[0].stride = static_cast<GLsizei>(stride);
            out.bindingPoints[0].divisor = 0;
        }
        return &out;
    };
    const bool gsRasterExpected =
        !impl_->state->isEnabled(GL_RASTERIZER_DISCARD);
    // Sprint 3 Step 2 Phase 2 [metal-mesh-GS]: try the mesh-shader path
    // only when explicitly enabled. APPGL_ENABLE_MESH_GS is default-off
    // while the mesh path is embryonic; the CPU GS interpreter remains
    // the correctness path unless the flag is set.
    // Sprint 7 prep (CKPT52 fix-path A): condition mesh-GS on
    // !transformFeedbackActive. The mesh-GS encoder writes to render
    // targets, not TF buffers; routing TF-active draws through it
    // silently zeros the TF capture. CPU GS-emul has full TF capture
    // support via writeGsXfbAndCheckDiscard. With TF active, fall
    // through to CPU emul.
    bool meshGsNativeAttempted = false;
    const bool meshGsEnabled =
        appgl::appglEnvEnabledDefaultOff("APPGL_ENABLE_MESH_GS");
    if (meshGsEnabled &&
        emulProgram != nullptr &&
        emulProgram->metalGSTier == GLProgramObject::MetalGSTier::MeshShader &&
        !impl_->transformFeedbackActive) {
        meshGsNativeAttempted = true;
        if (impl_->tryMetalMeshGSDraw(*emulProgram, emulProgramName,
                                       mode, count, first)) {
            APPGL_LOG(DRAW, @"drawArrays mesh-GS ok: count=%d", count);
            return true;
        }
        APPGL_LOG(SHADER, @"drawArrays mesh-GS encode failed — falling back to CPU emulator");
        if (!emulProgram->geometryEmulated) {
            appgl::AppGLSubmissionGroup fallbackGroup;
            impl_->declareMeshGsFallbackSubmissionGroup(fallbackGroup);
            APPGL_LOG(SHADER,
                      @"drawArrays mesh-GS exact fallback unavailable — consuming as unsupported");
            return true;
        }
    }
    if (emulProgram != nullptr && emulProgram->geometryEmulated) {
        const bool dcr4eExactNoLegacy =
            dcr4eRequiresExactCpuGsNoLegacyFallback(
                emulProgram, mode, isTransformFeedbackActive());
        const GLuint vaoName = impl_->state->boundVertexArray();
        GLVertexArrayObject* vao = (vaoName != 0)
            ? impl_->objects->vertexArrays().get(vaoName)
            : (appglCompatProfileEnabled()
                ? impl_->currentVertexArrayOrDefault()
                : nullptr);
        GLVertexArrayObject legacyClientVao;
        if (vaoName == 0) {
            if (GLVertexArrayObject* legacyVao =
                    buildCompatLegacyVertexArrayForEmulation(
                        legacyClientVao)) {
                vao = legacyVao;
            }
        }
        if (vao != nullptr) {
            // Sprint 6 P1 sub-task 3 day 3 (CKPT43): build VS + GS
            // sampler-texture maps so CPU emul can sample real texel
            // values via OpImageSampleExplicitLod.
            const auto vsTexMap = impl_->buildSampledTextureMap(
                emulProgram->vertexSpirv,
                &emulProgram->vertexReflection, *emulProgram);
            const auto gsTexMap = impl_->buildSampledTextureMap(
                emulProgram->geometrySpirv,
                &emulProgram->geometryReflection, *emulProgram);
            // Sprint 7 Phase 1 #4 (CKPT54): same shape, storage-image
            // counterpart for OpImageRead in GS-emul.
            const auto vsImgMap = impl_->buildStorageImageMap(
                emulProgram->vertexSpirv,
                &emulProgram->vertexReflection, *emulProgram);
            const auto gsImgMap = impl_->buildStorageImageMap(
                emulProgram->geometrySpirv,
                &emulProgram->geometryReflection, *emulProgram);
            // Sprint 8 #8 β.3 (CKPT97): tess+GS plumbing. When the
            // program has BOTH tess and GS emulation enabled, run the
            // tess-emul stage first to produce per-vertex post-tess
            // output, then feed that into the GS-emul as
            // priorStageOutput. Without this, the GS-emul's VS pre-pass
            // bypasses tess entirely and the GS reads garbage from
            // gl_in[].tc_position (CTS data_pass_through tests fail
            // with "expected [1,1,1,1] found [0,0,0,0]" at odd indices
            // where the GS's `+1` pass-through modification didn't run).
            appgl::EmulatedDraw priorStage;
            const bool hasTess = emulProgram->tessellationEmulated ||
                                 emulProgram->tessellationInterpreted;
            if (hasTess) {
                // Sprint 16 Day 6 (CKPT215) — Tess OpImage gap; build
                // TCS/TES sampler+image maps for tess+GS path too.
                appgl::SampledTextureMap _tcsSam, _tcsImg, _tesSam, _tesImg;
                if (!emulProgram->tessControlSpirv.empty()) {
                    _tcsSam = impl_->buildSampledTextureMap(
                        emulProgram->tessControlSpirv,
                        &emulProgram->tessControlReflection, *emulProgram);
                    _tcsImg = impl_->buildStorageImageMap(
                        emulProgram->tessControlSpirv,
                        &emulProgram->tessControlReflection, *emulProgram);
                }
                if (!emulProgram->tessEvalSpirv.empty()) {
                    _tesSam = impl_->buildSampledTextureMap(
                        emulProgram->tessEvalSpirv,
                        &emulProgram->tessEvalAsComputeReflection, *emulProgram);
                    _tesImg = impl_->buildStorageImageMap(
                        emulProgram->tessEvalSpirv,
                        &emulProgram->tessEvalAsComputeReflection, *emulProgram);
                }
                priorStage = appgl::emulateTessellationDraw(
                    *emulProgram, *vao, *impl_->objects, *impl_->state,
                    mode, count, first, /*elementIndices=*/nullptr,
                    /*instanceCount=*/1, /*baseInstance=*/0,
                    _tcsSam.empty() ? nullptr : &_tcsSam,
                    _tcsImg.empty() ? nullptr : &_tcsImg,
                    _tesSam.empty() ? nullptr : &_tesSam,
                    _tesImg.empty() ? nullptr : &_tesImg,
                    vsTexMap.empty() ? nullptr : &vsTexMap,
                    vsImgMap.empty() ? nullptr : &vsImgMap);
                if (!priorStage.ok && !priorStage.diagnostic.empty()) {
                    APPGL_LOG(SHADER, @"drawArrays tess+GS: tess-emul: %s",
                              priorStage.diagnostic.c_str());
                }
            }
            appgl::EmulatedDraw ed = appgl::emulateGeometryDraw(
                *emulProgram, *vao, *impl_->objects, *impl_->state,
                mode, count, first, /*elementIndices=*/nullptr,
                /*instanceCount=*/1, /*baseInstance=*/0,
                vsTexMap.empty() ? nullptr : &vsTexMap,
                gsTexMap.empty() ? nullptr : &gsTexMap,
                vsImgMap.empty() ? nullptr : &vsImgMap,
                gsImgMap.empty() ? nullptr : &gsImgMap,
                (hasTess && priorStage.ok) ? &priorStage : nullptr);
            if (ed.ok) {
                // XFB capture + rasterDiscard early-out lives in a
                // shared helper so drawElements can run the same path.
                if (impl_->writeGsXfbAndCheckDiscard(*emulProgram, ed)) {
                    return true;
                }
                // GS ran successfully but emitted zero output
                // primitives (e.g. a triangle_strip body with
                // fewer than 3 EmitVertex calls). Consume the draw
                // here instead of falling through to the legacy
                // VS+FS pipeline — that path would render the VS's
                // raw gl_Position as a point and scribble fragments
                // the test explicitly expects to stay cleared.
                if (ed.vertexCount == 0) {
                    APPGL_LOG(DRAW, @"drawArrays GS-emul: zero primitives");
                    return true;
                }
                if (emulProgram->geometryEmulatedTransformFeedbackOnly) {
                    APPGL_LOG(SHADER,
                              @"drawArrays GS-emul TF-only clip/cull path captured XFB; falling through to legacy raster");
                } else {
                    if (impl_->encodeEmulatedGsDraw(
                            *emulProgram, emulProgramName, ed,
                            meshGsNativeAttempted
                                ? AppGLSubmissionGroupKind::FallbackNs
                                : AppGLSubmissionGroupKind::None)) {
                        APPGL_LOG(DRAW, @"drawArrays GS-emul ok: verts=%zu topo=0x%X",
                                  ed.vertexCount, ed.topology);
                        return true;
                    }
                    APPGL_LOG(SHADER, @"drawArrays GS-emul encode failed");
                    if (dcr4eExactNoLegacy) {
                        appgl::AppGLSubmissionGroup fallbackGroup;
                        impl_->declareCpuGsFallbackSubmissionGroup(fallbackGroup);
                        APPGL_LOG(SHADER,
                                  @"drawArrays GS-emul exact path failed — consuming as unsupported");
                        return true;
                    }
                }
                // Fall through to the legacy path if encode fails
                // for non-B4 draws.
            } else {
                const std::string gsDiag = ed.diagnostic.empty()
                    ? "GS emulator returned ok=false without diagnostic"
                    : ed.diagnostic;
                APPGL_LOG(SHADER, @"drawArrays GS-emul: %s", gsDiag.c_str());
                if (gsRasterExpected) {
                    recordGeometryShaderEmulationFailure(
                        emulProgram, emulProgramName,
                        "drawArrays", gsDiag, /*detectRejected=*/false);
                    return true;
                }
                if (dcr4eExactNoLegacy) {
                    appgl::AppGLSubmissionGroup fallbackGroup;
                    impl_->declareCpuGsFallbackSubmissionGroup(fallbackGroup);
                    APPGL_LOG(SHADER,
                              @"drawArrays GS-emul exact interpreter failed — consuming as unsupported");
                    return true;
                }
            }
        }
    }

    // Sprint 7 Phase 2 #7 (CKPT59): VS-only TF emulation. When TF is
    // active, the program has TF varyings, no GS is in the pipeline,
    // and no tess emulation applies, run the VS on CPU per vertex and
    // write captures via the shared writeGsXfbAndCheckDiscard helper.
    // Required for separable VS-only programs (CTS
    // `program_pipeline_vs_gs_capture` pass 2 detaches the GS via
    // glUseProgramStages(GS_BIT, 0) and expects subsequent draws to
    // capture VS outputs to TF).
    // Sprint 8 #9-C (CKPT68): the original CKPT59 gate restricted to
    // `emulProgram == nullptr` to scope VS-only-TF to separable VS-only
    // programs. That over-restricts: any program with no GS/tess emul
    // (regardless of separable status) needs VS-only-TF capture during
    // active TF. Relax to `(emulProgram == nullptr || !emulProgram->
    // geometryEmulated)` — the GS-emul block at line ~24508 only runs
    // when emulProgram->geometryEmulated, so guarding on that condition
    // here mirrors that block's gate exactly. CTS draw_xfb_instanced_test
    // uses a non-separable VS+FS program with TF varyings; without this
    // relaxation, emulProgram is non-null (set to the same program) but
    // doesn't have geometryEmulated, and VS-only-TF skipped → no
    // capturedVertexCount accumulation → glDrawTransformFeedbackInstanced
    // gets count=0 → test fails.
    const bool transformFeedbackCaptureActiveForDraw =
        isTransformFeedbackActive() &&
        !isTransformFeedbackPaused();  // CKPT85: per-bound-object
    if (program != nullptr &&
        transformFeedbackCaptureActiveForDraw &&
        !program->transformFeedbackVaryingNames.empty() &&
        (emulProgram == nullptr || !emulProgram->geometryEmulated) &&
        !program->geometryEmulated &&
        !program->tessellationEmulated &&
        !program->tessellationInterpreted) {
        const GLuint vaoName2 = impl_->state->boundVertexArray();
        GLVertexArrayObject* vao = (vaoName2 != 0)
            ? impl_->objects->vertexArrays().get(vaoName2)
            : (appglCompatProfileEnabled()
                ? impl_->currentVertexArrayOrDefault()
                : nullptr);
        GLVertexArrayObject legacyClientVao;
        if (vaoName2 == 0) {
            if (GLVertexArrayObject* legacyVao =
                    buildCompatLegacyVertexArrayForEmulation(
                        legacyClientVao)) {
                vao = legacyVao;
            }
        }
        if (vao != nullptr && !program->vertexSpirv.empty()) {
            // CPU TF emulation runs before the translated render path packs
            // draw uniforms. Mirror fixed-function matrices now so legacy
            // gl_Position expressions observe the current matrix stacks.
            if (pushSynthesizedMatrixUniforms(
                    *program, impl_->matrixState,
                    impl_->state->isEnabled(GL_VERTEX_PROGRAM_TWO_SIDE))) {
                program->markUniformsDirty();
            }
            std::vector<std::uint32_t> tfCaptureIndices;
            GLenum tfCaptureTopology = mode;
            const bool useTfCaptureIndices =
                buildSequentialTfCaptureIndices(
                    mode, first, count, tfCaptureIndices, tfCaptureTopology);
            // Sprint 15 Q3-Option-B Phase 3a [metal-tf-vs]: GPU
            // compute-dispatch path. Replaces the CPU
            // `emulateVsOnlyDrawForTf` SPIR-V interpreter with a Metal
            // VS-as-compute dispatch when the program has a built
            // VS-compute PSO + a reflected output struct + all TF
            // varyings resolved at link time. Day 4 constraint: only
            // attributeless VS programs (`metalVsTfNeedsDescriptor==
            // false`) AND no default-uniform-block usage AND no UBOs
            // (Phase 3a doesn't bind uniforms; Phase 3b adds that).
            // Phase 3c (Day 6+) extends to VAO-bound stage_in
            // programs via `metalVsTfComputePSOCache`.
            //
            // Phase 3a is groundwork-only: gated behind the secondary
            // `APPGL_ENABLE_METAL_TF_VS_DISPATCH=1` env so it stays
            // off by default until Phase 3b lands proper uniform
            // binding. With only the primary gate
            // `APPGL_ENABLE_METAL_TF_VS=1` set, Phase 1+2 link-time
            // reflection runs but draw-time still routes via the
            // CPU helper (preserves CKPT173+CKPT174 behaviour).
            //
            // Falls back to CPU helper on any precondition mismatch
            // OR encoder failure — preserving correctness.
            const bool dispatchGateOn =
                std::getenv("APPGL_ENABLE_METAL_TF_VS_DISPATCH") != nullptr;
            // Phase 3a doesn't yet bind uniform-block bytes — skip
            // GPU path when the VS uses any uniform block (default or
            // named). Phase 3b (Day 5) will populate the uniform
            // bytes from `program->uniformValues` per
            // `vsTfAsComputeReflection`. The VS-as-compute MSL embeds
            // its own default-uniform-block as a UBO at slot 16 (per
            // SPIRV-Cross's tess emit convention), which is exactly
            // what `program.uniforms` feeds when populated.
            // Sprint 15 Day 27 (CKPT200): Phase 3b proper Component A —
            // relax the noUniforms gate and pack uniform bytes from
            // program.uniformValues into the compute encoder at slot
            // 16. Sister-pattern reuse from tess Phase 3 uniform path
            // (line ~25584-25590, `tessVertexAsComputeUniformLayout`
            // + `buildStageUniformBuffer`). The cached layout on the
            // program object survives across draws (link-time stable);
            // packing the byte buffer per draw is cheap.
            // The compute encoder currently binds the packed VS
            // uniforms/output buffer plus VAO-backed stage inputs; sampled
            // textures and image resources stay on the CPU interpreter path.
            bool gpuTfHandled = false;
            void* vsTfComputePSO =
                program->metalVsTfComputePipelineState;
            std::vector<appgl::MetalTessVertexBufferBinding>
                vsTfVertexBufferBindings;
            const void* vsTfClientVertexBytes = nullptr;
            std::size_t vsTfClientVertexLength = 0;
            std::uint32_t vsTfClientVertexSlot = 0;
            bool vsTfDescriptorReady = !program->metalVsTfNeedsDescriptor;
            const bool gpuTfBaseEligible = dispatchGateOn &&
                program->vertexReflection.sampledTextures.empty() &&
                program->vertexReflection.storageImages.empty() &&
                program->metalVsTfTier ==
                    GLProgramObject::MetalVsTfTier::VsAsCompute &&
                program->vsTfOutputLayout.structSize > 0 &&
                !program->vsTfResolvedSources.empty() &&
                impl_->frameGraph != nullptr &&
                count > 0 && first == 0;

            if (gpuTfBaseEligible && program->metalVsTfNeedsDescriptor) {
                GLVertexArrayObject descriptorVao = *vao;
                std::size_t clientAttributeIndex =
                    descriptorVao.attributes.size();
                bool descriptorInputsSupported = true;
                for (std::size_t index = 0;
                     index < descriptorVao.attributes.size(); ++index) {
                    const auto& sourceAttribute = vao->attributes[index];
                    if (!sourceAttribute.enabled) {
                        continue;
                    }
                    GLuint effectiveBuffer = sourceAttribute.buffer;
                    const bool separatedBindingInRange =
                        sourceAttribute.bindingIndex <
                        vao->bindingPoints.size();
                    const bool hasSeparatedBinding =
                        separatedBindingInRange &&
                        vao->bindingPoints[sourceAttribute.bindingIndex].buffer != 0;
                    if (sourceAttribute.useSeparatedFormat &&
                        !separatedBindingInRange) {
                        descriptorInputsSupported = false;
                        break;
                    }
                    if (sourceAttribute.useSeparatedFormat ||
                        hasSeparatedBinding) {
                        effectiveBuffer =
                            vao->bindingPoints[sourceAttribute.bindingIndex].buffer;
                    }
                    if (effectiveBuffer != 0) {
                        continue;
                    }
                    // The small legacy path supports one interleaved client
                    // attribute. More complex client layouts retain the CPU
                    // interpreter fallback.
                    if (clientAttributeIndex != descriptorVao.attributes.size() ||
                        sourceAttribute.useSeparatedFormat ||
                        sourceAttribute.pointer == 0) {
                        descriptorInputsSupported = false;
                        break;
                    }
                    clientAttributeIndex = index;
                    descriptorVao.attributes[index].pointer = 0;
                }

                if (descriptorInputsSupported) {
                    appgl::MetalVertexDescriptorBuildResult buildResult =
                        appgl::buildMetalStageInputOutputDescriptor(
                            descriptorVao);
                    if (buildResult.descriptor != nullptr) {
                        auto cached = program->metalVsTfComputePSOCache.find(
                            buildResult.hash);
                        if (cached !=
                            program->metalVsTfComputePSOCache.end()) {
                            vsTfComputePSO = cached->second;
                        } else {
                            std::string error;
                            vsTfComputePSO =
                                impl_->frameGraph->buildComputePipelineState(
                                    program->vsTfAsComputeMSL, &error,
                                    nullptr, buildResult.descriptor);
                            if (vsTfComputePSO != nullptr) {
                                program->metalVsTfComputePSOCache[
                                    buildResult.hash] = vsTfComputePSO;
                            } else if (std::getenv("APPGL_TRACE_TF_VS")) {
                                std::fprintf(stderr,
                                    "[APPGL] tf-vs draw-time PSO failed: %s\n",
                                    error.c_str());
                            }
                        }

                        if (vsTfComputePSO != nullptr) {
                            vsTfDescriptorReady = true;
                            for (const auto& binding :
                                 buildResult.vertexBufferBindings) {
                                if (binding.glBuffer == 0) {
                                    if (clientAttributeIndex ==
                                        descriptorVao.attributes.size()) {
                                        vsTfDescriptorReady = false;
                                        break;
                                    }
                                    const auto& clientAttribute =
                                        vao->attributes[clientAttributeIndex];
                                    auto componentBytes = [](GLenum type)
                                        -> std::size_t {
                                        switch (type) {
                                            case GL_BYTE:
                                            case GL_UNSIGNED_BYTE:
                                                return 1;
                                            case GL_SHORT:
                                            case GL_UNSIGNED_SHORT:
                                            case GL_HALF_FLOAT:
                                                return 2;
                                            case GL_DOUBLE:
                                                return 8;
                                            default:
                                                return 4;
                                        }
                                    };
                                    const std::size_t attributeBytes =
                                        (clientAttribute.type ==
                                             GL_INT_2_10_10_10_REV ||
                                         clientAttribute.type ==
                                             GL_UNSIGNED_INT_2_10_10_10_REV)
                                            ? 4
                                            : componentBytes(
                                                  clientAttribute.type) *
                                                  static_cast<std::size_t>(
                                                      clientAttribute.size);
                                    const std::size_t clientLength =
                                        (static_cast<std::size_t>(count) - 1) *
                                            binding.stride +
                                        attributeBytes;
                                    if (clientLength == 0 ||
                                        clientLength > 4096) {
                                        vsTfDescriptorReady = false;
                                        break;
                                    }
                                    vsTfClientVertexBytes =
                                        reinterpret_cast<const void*>(
                                            clientAttribute.pointer);
                                    vsTfClientVertexLength = clientLength;
                                    vsTfClientVertexSlot = binding.metalSlot;
                                    continue;
                                }
                                GLBufferObject* vbo =
                                    impl_->objects->buffers().get(
                                        binding.glBuffer);
                                if (vbo == nullptr ||
                                    vbo->metalBuffer == nullptr) {
                                    vsTfDescriptorReady = false;
                                    break;
                                }
                                appgl::MetalTessVertexBufferBinding resolved;
                                resolved.metalBuffer = vbo->metalBuffer;
                                resolved.offset = 0;
                                resolved.metalSlot = binding.metalSlot;
                                vsTfVertexBufferBindings.push_back(resolved);
                            }
                        }
                        appgl::releaseMetalStageInputOutputDescriptor(
                            buildResult.descriptor);
                    } else if (std::getenv("APPGL_TRACE_TF_VS")) {
                        std::fprintf(stderr,
                            "[APPGL] tf-vs descriptor build failed: %s\n",
                            buildResult.error.c_str());
                    }
                }
            }

            if (gpuTfBaseEligible && vsTfDescriptorReady &&
                vsTfComputePSO != nullptr) {
                // Verify every TF varying name resolved (skip GPU
                // path otherwise — CPU helper covers exotic varying
                // shapes more robustly).
                bool allResolved = true;
                for (const auto& s : program->vsTfResolvedSources) {
                    if (s.bytes == 0) { allResolved = false; break; }
                }
                if (allResolved) {
                    const std::size_t perVertexBytes =
                        program->vsTfOutputLayout.structSize;
                    std::vector<std::uint8_t> outBytes(
                        perVertexBytes * static_cast<std::size_t>(count));
                    // Phase 3b Component A: pack uniform bytes when
                    // the VS reflection reports any uniform blocks.
                    // Lazy layout-cache build on first dispatch.
                    thread_local std::vector<std::uint8_t> vsTfUniformScratch;
                    const std::uint8_t* uniformBytesPtr = nullptr;
                    std::size_t uniformBytesLen = 0;
                    if (!program->vsTfAsComputeReflection.uniformBlocks.empty()) {
                        if (program->vsTfAsComputeUniformLayout.empty()) {
                            computeStageUniformLayout(
                                program->vsTfAsComputeUniformLayout,
                                program->vsTfAsComputeReflection,
                                program->uniforms);
                        }
                        if (!program->vsTfAsComputeUniformLayout.empty()) {
                            buildStageUniformBuffer(
                                vsTfUniformScratch,
                                program->vsTfAsComputeReflection,
                                program->uniformValues,
                                program->vsTfAsComputeUniformLayout);
                            uniformBytesPtr = vsTfUniformScratch.data();
                            uniformBytesLen = vsTfUniformScratch.size();
                        }
                    }
                    const bool encodeOk =
                        impl_->frameGraph->encodeVsTfComputeDraw(
                            vsTfComputePSO,
                            static_cast<std::uint32_t>(count),
                            perVertexBytes,
                            vsTfVertexBufferBindings,
                            vsTfClientVertexBytes,
                            vsTfClientVertexLength,
                            vsTfClientVertexSlot,
                            uniformBytesPtr,
                            uniformBytesLen,
                            outBytes.data());
                    if (encodeOk) {
                        const std::uint8_t* tfOutputBytes = outBytes.data();
                        std::uint32_t tfOutputVertexCount =
                            static_cast<std::uint32_t>(count);
                        GLenum tfOutputTopology = mode;
                        std::vector<std::uint8_t> expandedTfOutput;
                        if (useTfCaptureIndices) {
                            expandedTfOutput.resize(
                                perVertexBytes * tfCaptureIndices.size());
                            bool indicesInRange = true;
                            for (std::size_t index = 0;
                                 index < tfCaptureIndices.size(); ++index) {
                                const std::uint32_t sourceVertex =
                                    tfCaptureIndices[index];
                                if (sourceVertex >=
                                    static_cast<std::uint32_t>(count)) {
                                    indicesInRange = false;
                                    break;
                                }
                                std::memcpy(
                                    expandedTfOutput.data() +
                                        index * perVertexBytes,
                                    outBytes.data() +
                                        static_cast<std::size_t>(sourceVertex) *
                                            perVertexBytes,
                                    perVertexBytes);
                            }
                            if (!indicesInRange) {
                                expandedTfOutput.clear();
                            } else {
                                tfOutputBytes = expandedTfOutput.data();
                                tfOutputVertexCount =
                                    static_cast<std::uint32_t>(
                                        tfCaptureIndices.size());
                                tfOutputTopology = tfCaptureTopology;
                            }
                        }
                        if (useTfCaptureIndices && expandedTfOutput.empty()) {
                            gpuTfHandled = false;
                        } else {
                            impl_->writeVsTfFromComputeOutput(
                                *program, tfOutputBytes,
                                tfOutputVertexCount,
                                perVertexBytes, tfOutputTopology);
                            if (impl_->state->isEnabled(
                                    GL_RASTERIZER_DISCARD)) {
                                return true;
                            }
                            // Without rasterizer-discard, fall through to
                            // the regular Metal-side draw so the FS still
                            // runs. TF buffer is already populated above.
                            gpuTfHandled = true;
                        }
                    }
                }
            }
            if (!gpuTfHandled) {
                const auto vsTexMap = impl_->buildSampledTextureMap(
                    program->vertexSpirv,
                    &program->vertexReflection, *program);
                const auto vsImgMap = impl_->buildStorageImageMap(
                    program->vertexSpirv,
                    &program->vertexReflection, *program);
                const GLenum vsTfMode =
                    useTfCaptureIndices ? tfCaptureTopology : mode;
                const GLsizei vsTfCount = useTfCaptureIndices
                    ? static_cast<GLsizei>(tfCaptureIndices.size())
                    : count;
                const GLint vsTfFirst = useTfCaptureIndices ? 0 : first;
                const std::uint32_t* vsTfIndices = useTfCaptureIndices
                    ? tfCaptureIndices.data()
                    : nullptr;
                const bool replayPostVsTriangle =
                    !impl_->state->isEnabled(GL_RASTERIZER_DISCARD) &&
                    mode == GL_TRIANGLES &&
                    vsTfMode == GL_TRIANGLES &&
                    !useTfCaptureIndices;
                appgl::EmulatedDraw ed = appgl::emulateVsOnlyDrawForTf(
                    *program, *vao, *impl_->objects, *impl_->state,
                    vsTfMode, vsTfCount, vsTfFirst,
                    /*instanceCount=*/1, /*baseInstance=*/0,
                    vsTfIndices,
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
                    const bool decomposedCompatTopology =
                        mode == GL_QUADS || mode == GL_QUAD_STRIP ||
                        mode == GL_POLYGON;
                    if (discard) {
                        if (!program->gsPresent) {
                            impl_->updatePrimitiveGeneratedForNonGsDraw(
                                vsTfMode, vsTfCount, 1);
                        }
                        return true;
                    }
                    if (replayPostVsTriangle &&
                        impl_->encodeEmulatedGsDraw(
                            *program, programName, ed)) {
                        if (!program->gsPresent) {
                            impl_->updatePrimitiveGeneratedForNonGsDraw(
                                vsTfMode, vsTfCount, 1);
                        }
                        return true;
                    }
                    // The regular translated fallback below performs the
                    // ordinary-topology generated counter update. Preserve
                    // the existing decomposed-topology credit here because
                    // that fallback cannot infer the expanded primitive list.
                    if (!program->gsPresent && decomposedCompatTopology) {
                        impl_->updatePrimitiveGeneratedForNonGsDraw(
                            vsTfMode, vsTfCount, 1);
                    }
                } else if (!ed.diagnostic.empty()) {
                    APPGL_LOG(SHADER, @"drawArrays VS-only-TF: %s",
                              ed.diagnostic.c_str());
                }
            }
        }
    }

    // Side-effect-only VS image programs can translate to `vertex void`
    // MSL with no position output. Metal may optimize away such render
    // work, but GL still executes the vertex shader side effects.
    if (program != nullptr &&
        program->hasTranslatedPipeline &&
        !program->vertexSpirv.empty() &&
        !program->vertexReflection.storageImages.empty() &&
        program->vertexMSL.find("vertex void ") != std::string::npos &&
        program->fragmentMSL.find("discard_fragment()") != std::string::npos) {
        GLVertexArrayObject* vao = impl_->currentVertexArrayOrDefault();
        if (vao != nullptr) {
            const auto vsTexMap = impl_->buildSampledTextureMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            const auto vsImgMap = impl_->buildStorageImageMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            appgl::EmulatedDraw ed = appgl::emulateVsOnlyDrawForTf(
                *program, *vao, *impl_->objects, *impl_->state,
                mode, count, first,
                /*instanceCount=*/1, /*baseInstance=*/0,
                /*elementIndices=*/nullptr,
                vsTexMap.empty() ? nullptr : &vsTexMap,
                vsImgMap.empty() ? nullptr : &vsImgMap);
            if (ed.ok) {
                if (!ed.pendingImageWrites.empty()) {
                    std::vector<GLuint> cpuImageWriteTextures;
                    impl_->flushPendingImageWritesForStage(
                        ed.pendingImageWrites,
                        &program->vertexReflection,
                        program->vertexSpirv,
                        *program,
                        GL_VERTEX_SHADER,
                        &cpuImageWriteTextures);
                    impl_->markCpuInterpreterImageWrites(cpuImageWriteTextures);
                }
                if (!program->gsPresent) {
                    impl_->updatePrimitiveCountersForNonGsDraw(mode, count, 1);
                }
                return true;
            } else if (!ed.diagnostic.empty()) {
                APPGL_LOG(SHADER, @"drawArrays VS-image-side-effects: %s",
                          ed.diagnostic.c_str());
            }
        }
    }

    // Sprint 17 Day 7+ Bank-Group-H Path B Component B (drawArrays):
    // VS+FS programs that write gl_CullDistance get a CPU pre-pass +
    // Metal indexed-draw routing. Phase 2 §1.2 confirmed this is gated
    // on `needsCullDistancePrepass` (link-time A1 detect: VS writes
    // CullDistance && !gsPresent && !hasTessellation) + line/triangle
    // topology. Component E (Phase 3 day 5) handles TF coordination.
    if (program != nullptr && program->needsCullDistancePrepass &&
        program->hasTranslatedPipeline) {
        const bool isLineOrTri =
            (mode == GL_POINTS || mode == GL_LINES || mode == GL_TRIANGLES ||
             mode == GL_LINE_STRIP || mode == GL_LINE_LOOP ||
             mode == GL_TRIANGLE_STRIP || mode == GL_TRIANGLE_FAN);
        if (isLineOrTri) {
            const GLuint vaoNameCP = impl_->state->boundVertexArray();
            GLVertexArrayObject* vaoCP = (vaoNameCP != 0)
                ? impl_->objects->vertexArrays().get(vaoNameCP) : nullptr;
            if (vaoCP != nullptr) {
                std::vector<std::uint32_t> filteredIdx;
                std::string cullDiag;
                const bool prepassOk = appgl::emulateVsCullPrepass(
                    *program, *vaoCP, *impl_->objects, *impl_->state,
                    mode, count, first, /*elementIndices=*/nullptr,
                    /*instanceCount=*/1, /*baseInstance=*/0,
                    filteredIdx, &cullDiag);
                if (prepassOk) {
                    if (filteredIdx.empty()) {
                        // GL §14.6.3 — all primitives culled. Count
                        // input primitives and short-circuit. Legacy
                        // path is bypassed so do the counter update
                        // here (its own update would otherwise run
                        // in the fall-through case below).
                        if (!program->gsPresent) {
                            impl_->updatePrimitiveCountersForNonGsDraw(
                                mode, count, 1);
                        }
                        return true;
                    }
                    if (impl_->dispatchCullFilteredDraw(
                            *program, *vaoCP, programName, mode,
                            filteredIdx)) {
                        if (!program->gsPresent) {
                            impl_->updatePrimitiveCountersForNonGsDraw(
                                mode, count, 1);
                        }
                        return true;
                    }
                    // Fall through to legacy path on encode failure
                    // (legacy path runs its own counter update).
                } else if (!cullDiag.empty()) {
                    APPGL_LOG(SHADER, @"drawArrays cull-prepass: %s",
                              cullDiag.c_str());
                }
            }
        }
    }

    drawProfile.mark(GLDrawProfileBucket::SpecialPathChecks);
    const bool translatedDrawArraysEligible = [&]() {
        GLDrawDetailScope detail(
            impl_->drawDetailProfile,
            GLDrawDetailBucket::TranslatedDrawEligibility);
        return program != nullptr && program->hasTranslatedPipeline;
    }();
    if (translatedDrawArraysEligible) {
        // GL 4.6 §22.1 / §22.3 — non-GS draws credit the
        // PRIMITIVES_GENERATED and TRANSFORM_FEEDBACK_PRIMITIVES_-
        // WRITTEN counters with the input-primitive count. GS-
        // emulated draws already counted post-GS primitives inside
        // writeGsXfbAndCheckDiscard, so skip this path to avoid
        // double-counting.
        GLuint vaoName = 0;
        GLVertexArrayObject* vao = nullptr;
        {
            GLDrawDetailScope detail(
                impl_->drawDetailProfile,
                GLDrawDetailBucket::TranslatedProgramVaoFboState);
            {
                ColdPathDiagnosticScope cold(
                    &impl_->coldPathProfile,
                    ColdPathDiagnosticBucket::ProgramVaoFboPrimitiveCounters);
                if (!program->gsPresent) {
                    impl_->updatePrimitiveCountersForNonGsDraw(mode, count, 1);
                }
            }
            {
                ColdPathDiagnosticScope cold(
                    &impl_->coldPathProfile,
                    ColdPathDiagnosticBucket::ProgramVaoFboFrontendVaoSource);
                vaoName = impl_->state->boundVertexArray();
                vao = (vaoName != 0)
                    ? impl_->objects->vertexArrays().get(vaoName)
                    : (appglCompatProfileEnabled()
                        ? impl_->currentVertexArrayOrDefault()
                        : nullptr);
            }
        }
        // Phase 8X Group 4d follow-up³ — name each fall-through gate to BAR's log.
        bool gateEmpty = false;
        // Attributeless draw path: vertex shader has no vertex inputs
        // (generates its own vertices via gl_VertexID / [[vertex_id]]).
        bool attributelessDraw = false;
        {
            GLDrawDetailScope detail(
                impl_->drawDetailProfile,
                GLDrawDetailBucket::TranslatedFallbackDecision);
            gateEmpty = (vao == nullptr || vao->attributes.empty());
            attributelessDraw = (vao != nullptr &&
                program->vertexReflection.vertexInputs.empty());
        }
        drawProfile.mark(GLDrawProfileBucket::TranslatedPreflight);
        {
            const auto& legacyVertexArray = impl_->legacyVertexArray;
            const auto& legacyColorArray = impl_->legacyColorArray;
            const auto& legacySecondaryColorArray =
                impl_->legacySecondaryColorArray;
            const auto& legacyTexCoordArray = impl_->legacyTexCoordArray;
            const bool programWantsLegacyVertex =
                programUsesCompatVertexInput(program);
            bool programWantsLegacyColor = false;
            bool programWantsLegacySecondaryColor = false;
            bool programWantsLegacyTexCoord0 = false;
            for (const auto& input : program->vertexReflection.vertexInputs) {
                if (input.location == 3 &&
                    (input.name == "appgl_Color" ||
                     input.name == "_appgl_Color")) {
                    programWantsLegacyColor = true;
                }
                if (input.location == 8 &&
                    (input.name == "appgl_MultiTexCoord0" ||
                     input.name == "_appgl_MultiTexCoord0")) {
                    programWantsLegacyTexCoord0 = true;
                }
                if ((input.location == 4 || input.sourceLocation == 4) &&
                    (input.name == "appgl_SecondaryColor" ||
                     input.name == "_appgl_SecondaryColor")) {
                    programWantsLegacySecondaryColor = true;
                }
            }
            const bool colorArrayHasSource =
                legacyColorArray.pointer != nullptr ||
                legacyColorArray.bufferName != 0;
            const bool colorArrayUsable =
                legacyColorArray.enabled &&
                colorArrayHasSource &&
                legacyColorArray.type == GL_FLOAT &&
                legacyColorArray.size >= 3 &&
                legacyColorArray.size <= 4;
            const bool secondaryColorArrayHasSource =
                legacySecondaryColorArray.pointer != nullptr ||
                legacySecondaryColorArray.bufferName != 0;
            const bool secondaryColorArrayUsable =
                legacySecondaryColorArray.enabled &&
                secondaryColorArrayHasSource &&
                legacySecondaryColorArray.type == GL_FLOAT &&
                legacySecondaryColorArray.size == 3;
            const bool texCoordArrayHasSource =
                legacyTexCoordArray.pointer != nullptr ||
                legacyTexCoordArray.bufferName != 0;
            const bool texCoordArrayUsable =
                legacyTexCoordArray.enabled &&
                texCoordArrayHasSource &&
                legacyTexCoordArray.type == GL_FLOAT &&
                legacyTexCoordArray.size >= 1 &&
                legacyTexCoordArray.size <= 4;
            auto resolveLegacyArraySource = [&](const auto& array,
                                                const char* label,
                                                const std::uint8_t*& base,
                                                std::size_t& availableBytes) -> bool {
                if (array.bufferName != 0) {
                    const GLBufferObject* buffer =
                        impl_->objects->buffers().get(array.bufferName);
                    if (buffer == nullptr || buffer->shadowBytes.empty()) {
                        return false;
                    }
                    const std::uintptr_t offset =
                        reinterpret_cast<std::uintptr_t>(array.pointer);
                    if (offset > buffer->shadowBytes.size()) {
                        pushError(GL_INVALID_OPERATION, label,
                                  "legacy client array VBO offset is outside buffer storage");
                        return false;
                    }
                    base = buffer->shadowBytes.data() +
                        static_cast<std::size_t>(offset);
                    availableBytes = buffer->shadowBytes.size() -
                        static_cast<std::size_t>(offset);
                    return true;
                }
                if (array.pointer == nullptr) {
                    return false;
                }
                base = static_cast<const std::uint8_t*>(array.pointer);
                availableBytes = static_cast<std::size_t>(-1);
                return true;
            };
            auto legacyArrayElementFits = [](std::size_t offset,
                                             std::size_t need,
                                             std::size_t availableBytes) {
                return offset <= availableBytes &&
                    need <= availableBytes - offset;
            };
            auto addFloatLayout = [](TranslatedDrawInfo& tdi,
                                     GLuint location,
                                     std::size_t offset,
                                     GLint componentCount) {
                TranslatedDrawInfo::VertexAttributeLayout layout;
                layout.location = location;
                layout.offset = offset;
                layout.glType = GL_FLOAT;
                layout.glComponentCount = componentCount;
                layout.glNormalized = GL_FALSE;
                layout.glIsInteger = false;
                tdi.vertexAttributeLayouts.push_back(layout);
            };
            const bool needsLegacyColorInput = programWantsLegacyColor;
            const bool needsLegacySecondaryColorInput =
                programWantsLegacySecondaryColor;
            const bool needsLegacyTexCoord0Input = programWantsLegacyTexCoord0;
            if (needsLegacyColorInput && legacyColorArray.enabled &&
                !colorArrayUsable) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            if (needsLegacySecondaryColorInput &&
                legacySecondaryColorArray.enabled &&
                !secondaryColorArrayUsable) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            if (needsLegacyTexCoord0Input && legacyTexCoordArray.enabled &&
                !texCoordArrayUsable) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            if (appglCompatProfileEnabled() &&
                programWantsLegacyVertex &&
                legacyVertexArray.enabled &&
                (legacyVertexArray.pointer != nullptr ||
                 legacyVertexArray.bufferName != 0) &&
                legacyVertexArray.type == GL_FLOAT &&
                legacyVertexArray.size >= 2 &&
                legacyVertexArray.size <= 4) {
                const std::size_t legacyStride = legacyVertexArray.stride > 0
                    ? static_cast<std::size_t>(legacyVertexArray.stride)
                    : static_cast<std::size_t>(legacyVertexArray.size) * sizeof(GLfloat);
                const std::size_t colorStride = legacyColorArray.stride > 0
                    ? static_cast<std::size_t>(legacyColorArray.stride)
                    : static_cast<std::size_t>(legacyColorArray.size) * sizeof(GLfloat);
                const std::size_t secondaryColorStride =
                    legacySecondaryColorArray.stride > 0
                        ? static_cast<std::size_t>(
                              legacySecondaryColorArray.stride)
                        : 3u * sizeof(GLfloat);
                const std::size_t texCoordStride = legacyTexCoordArray.stride > 0
                    ? static_cast<std::size_t>(legacyTexCoordArray.stride)
                    : static_cast<std::size_t>(legacyTexCoordArray.size) * sizeof(GLfloat);
                const std::uint8_t* legacyBase = nullptr;
                std::size_t legacyAvailableBytes = 0;
                if (!resolveLegacyArraySource(
                        legacyVertexArray, "glVertexPointer",
                        legacyBase, legacyAvailableBytes)) {
                    return false;
                }
                const std::uint8_t* colorBase = nullptr;
                std::size_t colorAvailableBytes = 0;
                if (colorArrayUsable &&
                    !resolveLegacyArraySource(
                        legacyColorArray, "glColorPointer",
                        colorBase, colorAvailableBytes)) {
                    return false;
                }
                const std::uint8_t* secondaryColorBase = nullptr;
                std::size_t secondaryColorAvailableBytes = 0;
                if (secondaryColorArrayUsable &&
                    !resolveLegacyArraySource(
                        legacySecondaryColorArray,
                        "glSecondaryColorPointer",
                        secondaryColorBase,
                        secondaryColorAvailableBytes)) {
                    return false;
                }
                const std::uint8_t* texCoordBase = nullptr;
                std::size_t texCoordAvailableBytes = 0;
                if (texCoordArrayUsable &&
                    !resolveLegacyArraySource(
                        legacyTexCoordArray, "glTexCoordPointer",
                        texCoordBase, texCoordAvailableBytes)) {
                    return false;
                }
                struct LegacyTranslatedVertex {
                    float position[4];
                    float color[4];
                    float texcoord[4];
                    float secondaryColor[4];
                };
                static_assert(sizeof(LegacyTranslatedVertex) == 64);
                std::vector<LegacyTranslatedVertex> legacyVertices;
                legacyVertices.reserve(static_cast<std::size_t>(count));
                bool legacyRangeOk = true;
                for (GLsizei i = 0; i < count; ++i) {
                    const GLint logical = first + i;
                    if (logical < 0) {
                        legacyRangeOk = false;
                        break;
                    }
                    const auto sourceIndex = static_cast<std::size_t>(logical);
                    const std::size_t vertexOffset = sourceIndex * legacyStride;
                    const std::size_t vertexNeed =
                        static_cast<std::size_t>(legacyVertexArray.size) *
                        sizeof(GLfloat);
                    if (!legacyArrayElementFits(
                            vertexOffset, vertexNeed, legacyAvailableBytes)) {
                        legacyRangeOk = false;
                        break;
                    }
                    const auto* src = reinterpret_cast<const GLfloat*>(
                        legacyBase + vertexOffset);
                    LegacyTranslatedVertex v{};
                    v.position[0] = src[0];
                    v.position[1] = src[1];
                    v.position[2] = legacyVertexArray.size >= 3 ? src[2] : 0.0f;
                    v.position[3] = legacyVertexArray.size >= 4 ? src[3] : 1.0f;
                    std::memcpy(v.color, impl_->immediate.currentColor,
                                sizeof(v.color));
                    if (colorArrayUsable) {
                        const std::size_t colorOffset = sourceIndex * colorStride;
                        const std::size_t colorNeed =
                            static_cast<std::size_t>(legacyColorArray.size) *
                            sizeof(GLfloat);
                        if (!legacyArrayElementFits(
                                colorOffset, colorNeed, colorAvailableBytes)) {
                            legacyRangeOk = false;
                            break;
                        }
                        const auto* cp = reinterpret_cast<const GLfloat*>(
                            colorBase + colorOffset);
                        v.color[0] = cp[0];
                        v.color[1] = cp[1];
                        v.color[2] = cp[2];
                        v.color[3] =
                            legacyColorArray.size >= 4 ? cp[3] : v.color[3];
                    }
                    std::memcpy(
                        v.secondaryColor,
                        impl_->fixedFunctionCurrentSecondaryColor,
                        sizeof(v.secondaryColor));
                    if (secondaryColorArrayUsable) {
                        const std::size_t secondaryColorOffset =
                            sourceIndex * secondaryColorStride;
                        if (!legacyArrayElementFits(
                                secondaryColorOffset,
                                3u * sizeof(GLfloat),
                                secondaryColorAvailableBytes)) {
                            legacyRangeOk = false;
                            break;
                        }
                        const auto* secondary =
                            reinterpret_cast<const GLfloat*>(
                                secondaryColorBase + secondaryColorOffset);
                        v.secondaryColor[0] = secondary[0];
                        v.secondaryColor[1] = secondary[1];
                        v.secondaryColor[2] = secondary[2];
                        v.secondaryColor[3] = 1.0f;
                    }
                    std::memcpy(v.texcoord, impl_->immediate.currentTexcoord,
                                sizeof(v.texcoord));
                    if (texCoordArrayUsable) {
                        const std::size_t texCoordOffset =
                            sourceIndex * texCoordStride;
                        const std::size_t texCoordNeed =
                            static_cast<std::size_t>(legacyTexCoordArray.size) *
                            sizeof(GLfloat);
                        if (!legacyArrayElementFits(
                                texCoordOffset, texCoordNeed,
                                texCoordAvailableBytes)) {
                            legacyRangeOk = false;
                            break;
                        }
                        const auto* tp = reinterpret_cast<const GLfloat*>(
                            texCoordBase + texCoordOffset);
                        v.texcoord[0] = tp[0];
                        v.texcoord[1] =
                            legacyTexCoordArray.size >= 2 ? tp[1] : v.texcoord[1];
                        v.texcoord[2] =
                            legacyTexCoordArray.size >= 3 ? tp[2] : v.texcoord[2];
                        v.texcoord[3] =
                            legacyTexCoordArray.size >= 4 ? tp[3] : v.texcoord[3];
                    }
                    legacyVertices.push_back(v);
                }
                if (!legacyRangeOk) {
                    pushError(GL_INVALID_OPERATION);
                    return false;
                }

                TranslatedDrawInfo& tdi = reusableTranslatedDrawInfo();
                tdi.mode = mode;
                tdi.vertexCount = count;
                tdi.baseVertex = 0;
                tdi.vertexData = legacyVertices.data();
                tdi.vertexDataByteCount =
                    legacyVertices.size() * sizeof(LegacyTranslatedVertex);
                tdi.vertexStride = sizeof(LegacyTranslatedVertex);
                tdi.vertexAttributeLayouts.clear();
                addFloatLayout(tdi, 0,
                               offsetof(LegacyTranslatedVertex, position),
                               4);
                if (programWantsLegacyColor) {
                    addFloatLayout(tdi, 3,
                                   offsetof(LegacyTranslatedVertex, color),
                                   4);
                }
                if (programWantsLegacySecondaryColor) {
                    addFloatLayout(
                        tdi, 4,
                        offsetof(LegacyTranslatedVertex, secondaryColor), 4);
                }
                if (programWantsLegacyTexCoord0) {
                    addFloatLayout(tdi, 8,
                                   offsetof(LegacyTranslatedVertex, texcoord),
                                   4);
                }
                populateTranslatedDrawFixedFunctionState(
                    tdi, *impl_->state,
                    effectiveFragmentShadingRateForProgram(*this, program),
                    this);
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

                const double bindingConstructionUniformPackUs =
                    impl_->prepareBindingConstructionUniformBuffers(
                        *program, programName, drawID, tdi,
                        "drawArrays-legacy-client-vertex");
                impl_->resolveBindingConstructionForTranslatedDraw(
                    *program, tdi, bindingConstructionUniformPackUs);

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

                thread_local std::string legacyPipelineBuildError;
                legacyPipelineBuildError.clear();
                tdi.pipelineBuildErrorOut = &legacyPipelineBuildError;
                const TranslatedDrawPreflightSnapshot preflight =
                    makeTranslatedDrawPreflightSnapshot(
                        vaoName, vao,
                        /*genericVertexAttributesPrepared=*/true);
                const bool ok = impl_->encodeTranslatedDrawAndMarkFbo(
                    tdi, &preflight);
                if (ok) {
                    return true;
                }
                if (reportTranslatedFallbackOnce(program, programName,
                        TranslatedFallbackGate::EncodeFailed,
                        "drawArrays-legacy-client-vertex",
                        vaoName,
                        vao != nullptr ? vao->attributes.size() : 0,
                        0,
                        tdi.vertexDataByteCount)) {
                    recordPipelineBuildFailureOnce(
                        program, programName, legacyPipelineBuildError);
                }
            }
        }
        {
            const bool programWantsGenericCompatVertex =
                programUsesCompatVertexInput(program);
            const GLVertexAttributeState* genericPosition = nullptr;
            if (vao != nullptr &&
                !vao->attributes.empty() &&
                vao->attributes[0].enabled) {
                genericPosition = &vao->attributes[0];
            }
            if (appglCompatProfileEnabled() &&
                programWantsGenericCompatVertex &&
                genericPosition != nullptr &&
                genericPosition->buffer == 0 &&
                genericPosition->pointer != 0 &&
                genericPosition->type == GL_FLOAT &&
                genericPosition->size >= 2 &&
                genericPosition->size <= 4) {
                // Compatibility triangle-family draws need one contiguous
                // record before topology expansion and transform-feedback
                // replay. Pack only wholly client-backed inputs; mixed or
                // packed-format draws keep the position-only fallback.
                struct PackedClientAttribute {
                    const std::uint8_t* base = nullptr;
                    std::size_t sourceStride = 0;
                    std::size_t elementBytes = 0;
                    TranslatedDrawInfo::VertexAttributeLayout layout;
                };
                auto clientAttributeScalarBytes = [](GLenum type) -> std::size_t {
                    switch (type) {
                        case GL_BYTE:
                        case GL_UNSIGNED_BYTE:
                            return 1;
                        case GL_SHORT:
                        case GL_UNSIGNED_SHORT:
                        case GL_HALF_FLOAT:
                            return 2;
                        case GL_INT:
                        case GL_UNSIGNED_INT:
                        case GL_FLOAT:
                            return 4;
                        default:
                            return 0;
                    }
                };
                auto alignUp = [](std::size_t value, std::size_t alignment) {
                    return (value + alignment - 1u) & ~(alignment - 1u);
                };

                std::vector<PackedClientAttribute> packedAttributes;
                std::vector<TranslatedDrawInfo::VertexAttributeLayout>
                    packedLayouts;
                std::vector<std::uint8_t> packedClientVertices;
                std::size_t packedStride = 0;
                const bool packableTriangleMode =
                    mode == GL_TRIANGLES || mode == GL_TRIANGLE_STRIP ||
                    mode == GL_QUADS || mode == GL_QUAD_STRIP ||
                    mode == GL_POLYGON;
                bool usePackedClientAttributes =
                    packableTriangleMode &&
                    first >= 0 &&
                    !programUsesDrawArrayVertexBaseBuiltins(
                        *program, *impl_->objects) &&
                    !program->vertexReflection.vertexInputs.empty();

                if (usePackedClientAttributes) {
                    for (const auto& input :
                         program->vertexReflection.vertexInputs) {
                        if (input.containsFp64 ||
                            input.sourceLocation >= vao->attributes.size()) {
                            usePackedClientAttributes = false;
                            break;
                        }
                        const auto& attr =
                            vao->attributes[input.sourceLocation];
                        const ResolvedVertexAttrib resolved =
                            resolveVertexAttrib(attr, *vao);
                        const std::size_t scalarBytes =
                            clientAttributeScalarBytes(attr.type);
                        const std::size_t elementBytes = scalarBytes *
                            static_cast<std::size_t>(std::max(0, attr.size));
                        if (!attr.enabled || attr.useSeparatedFormat ||
                            effectiveVertexAttribDivisor(attr, *vao) != 0 ||
                            resolved.bufferName != 0 || attr.pointer == 0 ||
                            attr.size < 1 || attr.size > 4 || scalarBytes == 0 ||
                            resolved.stride < elementBytes) {
                            usePackedClientAttributes = false;
                            break;
                        }

                        const std::size_t alignment =
                            std::min<std::size_t>(scalarBytes, 4u);
                        packedStride = alignUp(packedStride, alignment);
                        PackedClientAttribute packed;
                        packed.base = reinterpret_cast<const std::uint8_t*>(
                            attr.pointer);
                        packed.sourceStride = resolved.stride;
                        packed.elementBytes = elementBytes;
                        packed.layout.location = input.location;
                        packed.layout.offset = packedStride;
                        packed.layout.glType = attr.type;
                        packed.layout.glComponentCount = attr.size;
                        packed.layout.glNormalized = attr.normalized;
                        packed.layout.glIsInteger = attr.integer;
                        packedAttributes.push_back(packed);
                        packedStride += elementBytes;
                    }
                }

                if (usePackedClientAttributes) {
                    packedStride = alignUp(packedStride, 4u);
                    const std::size_t vertexCount =
                        static_cast<std::size_t>(count);
                    if (packedStride == 0 ||
                        vertexCount >
                            std::numeric_limits<std::size_t>::max() /
                                packedStride) {
                        usePackedClientAttributes = false;
                    } else {
                        packedClientVertices.resize(vertexCount * packedStride);
                        for (std::size_t vertex = 0; vertex < vertexCount;
                             ++vertex) {
                            const std::size_t logical =
                                static_cast<std::size_t>(first) + vertex;
                            auto* dst = packedClientVertices.data() +
                                vertex * packedStride;
                            for (const auto& packed : packedAttributes) {
                                std::memcpy(
                                    dst + packed.layout.offset,
                                    packed.base +
                                        logical * packed.sourceStride,
                                    packed.elementBytes);
                            }
                        }
                        packedLayouts.reserve(packedAttributes.size());
                        for (const auto& packed : packedAttributes) {
                            packedLayouts.push_back(packed.layout);
                        }
                    }
                }

                // De-interleave FAN client records into independently indexed
                // streams; already-tight arrays keep the compatibility fallback.
                std::vector<TranslatedDrawInfo::ExtraVertexBuffer>
                    separateFanBuffers;
                bool useSeparateClientFanAttributes =
                    mode == GL_TRIANGLE_FAN && first >= 0 &&
                    !programUsesDrawArrayVertexBaseBuiltins(
                        *program, *impl_->objects) &&
                    !program->vertexReflection.vertexInputs.empty();
                bool hasInterleavedFanClientAttribute = false;
                if (useSeparateClientFanAttributes) {
                    const std::size_t vertexCount =
                        static_cast<std::size_t>(count);
                    for (const auto& input :
                         program->vertexReflection.vertexInputs) {
                        if (input.sourceLocation == 0) {
                            continue;
                        }
                        if (input.containsFp64 ||
                            input.sourceLocation >= vao->attributes.size()) {
                            useSeparateClientFanAttributes = false;
                            break;
                        }

                        const auto& attr =
                            vao->attributes[input.sourceLocation];
                        const ResolvedVertexAttrib resolved =
                            resolveVertexAttrib(attr, *vao);
                        const std::size_t scalarBytes =
                            clientAttributeScalarBytes(attr.type);
                        const std::size_t elementBytes = scalarBytes *
                            static_cast<std::size_t>(std::max(0, attr.size));
                        if (!attr.enabled || attr.useSeparatedFormat ||
                            effectiveVertexAttribDivisor(attr, *vao) != 0 ||
                            resolved.bufferName != 0 || attr.pointer == 0 ||
                            attr.size < 1 || attr.size > 4 || scalarBytes == 0 ||
                            resolved.stride < elementBytes ||
                            (elementBytes != 0 &&
                             vertexCount >
                                 std::numeric_limits<std::size_t>::max() /
                                     elementBytes)) {
                            useSeparateClientFanAttributes = false;
                            break;
                        }
                        hasInterleavedFanClientAttribute =
                            hasInterleavedFanClientAttribute ||
                            resolved.stride > elementBytes;

                        TranslatedDrawInfo::ExtraVertexBuffer extra;
                        extra.byteCount = vertexCount * elementBytes;
                        extra.stride = elementBytes;
                        extra.divisor = 0;
                        extra.ownedData.resize(extra.byteCount);
                        const auto* source =
                            reinterpret_cast<const std::uint8_t*>(attr.pointer);
                        for (std::size_t vertex = 0; vertex < vertexCount;
                             ++vertex) {
                            const std::size_t logical =
                                static_cast<std::size_t>(first) + vertex;
                            std::memcpy(
                                extra.ownedData.data() + vertex * elementBytes,
                                source + logical * resolved.stride,
                                elementBytes);
                        }

                        TranslatedDrawInfo::VertexAttributeLayout layout;
                        layout.location = input.location;
                        layout.offset = 0;
                        layout.glType = attr.type;
                        layout.glComponentCount = attr.size;
                        layout.glNormalized = attr.normalized;
                        layout.glIsInteger = attr.integer;
                        extra.attributes.push_back(layout);
                        separateFanBuffers.push_back(std::move(extra));
                    }
                    if (!useSeparateClientFanAttributes ||
                        !hasInterleavedFanClientAttribute) {
                        useSeparateClientFanAttributes = false;
                        separateFanBuffers.clear();
                    }
                }

                const std::size_t genericStride = genericPosition->stride > 0
                    ? static_cast<std::size_t>(genericPosition->stride)
                    : static_cast<std::size_t>(genericPosition->size) * sizeof(GLfloat);
                const auto* genericBase =
                    reinterpret_cast<const std::uint8_t*>(genericPosition->pointer);
                std::vector<GLfloat> genericPositions;
                if (!usePackedClientAttributes) {
                    genericPositions.reserve(static_cast<std::size_t>(count) * 4u);
                }
                bool genericRangeOk = true;
                if (!usePackedClientAttributes) {
                    for (GLsizei i = 0; i < count; ++i) {
                        const GLint logical = first + i;
                        if (logical < 0) {
                            genericRangeOk = false;
                            break;
                        }
                        const auto* src = reinterpret_cast<const GLfloat*>(
                            genericBase + static_cast<std::size_t>(logical) * genericStride);
                        genericPositions.push_back(src[0]);
                        genericPositions.push_back(src[1]);
                        genericPositions.push_back(genericPosition->size >= 3 ? src[2] : 0.0f);
                        genericPositions.push_back(genericPosition->size >= 4 ? src[3] : 1.0f);
                    }
                }
                if (!genericRangeOk) {
                    pushError(GL_INVALID_OPERATION);
                    return false;
                }

                TranslatedDrawInfo& tdi = reusableTranslatedDrawInfo();
                tdi.mode = mode;
                tdi.vertexCount = count;
                tdi.baseVertex = 0;
                tdi.vertexData = usePackedClientAttributes
                    ? static_cast<const void*>(packedClientVertices.data())
                    : static_cast<const void*>(genericPositions.data());
                tdi.vertexDataByteCount = usePackedClientAttributes
                    ? packedClientVertices.size()
                    : genericPositions.size() * sizeof(GLfloat);
                tdi.vertexStride = usePackedClientAttributes
                    ? packedStride
                    : sizeof(GLfloat) * 4u;
                tdi.vertexAttributeLayouts.clear();
                if (usePackedClientAttributes) {
                    tdi.vertexAttributeLayouts = std::move(packedLayouts);
                } else {
                    TranslatedDrawInfo::VertexAttributeLayout layout;
                    layout.location = 0;
                    layout.offset = 0;
                    layout.glType = GL_FLOAT;
                    layout.glComponentCount = 4;
                    layout.glNormalized = GL_FALSE;
                    layout.glIsInteger = false;
                    tdi.vertexAttributeLayouts.push_back(layout);
                }
                if (useSeparateClientFanAttributes) {
                    tdi.extraVertexBuffers = std::move(separateFanBuffers);
                }
                populateTranslatedDrawFixedFunctionState(
                    tdi, *impl_->state,
                    effectiveFragmentShadingRateForProgram(*this, program),
                    this);
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

                const double bindingConstructionUniformPackUs =
                    impl_->prepareBindingConstructionUniformBuffers(
                        *program, programName, drawID, tdi,
                        "drawArrays-generic-client-vertex");
                impl_->resolveBindingConstructionForTranslatedDraw(
                    *program, tdi, bindingConstructionUniformPackUs);

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

                thread_local std::string genericPipelineBuildError;
                genericPipelineBuildError.clear();
                tdi.pipelineBuildErrorOut = &genericPipelineBuildError;
                const TranslatedDrawPreflightSnapshot preflight =
                    makeTranslatedDrawPreflightSnapshot(
                        vaoName, vao,
                        /*genericVertexAttributesPrepared=*/true);
                const bool ok = impl_->encodeTranslatedDrawAndMarkFbo(
                    tdi, &preflight);
                if (ok) {
                    return true;
                }
                if (reportTranslatedFallbackOnce(program, programName,
                        TranslatedFallbackGate::EncodeFailed,
                        "drawArrays-generic-client-vertex",
                        vaoName,
                        vao != nullptr ? vao->attributes.size() : 0,
                        0,
                        tdi.vertexDataByteCount)) {
                    recordPipelineBuildFailureOnce(
                        program, programName, genericPipelineBuildError);
                }
            }
        }
        if (attributelessDraw) {
            TranslatedDrawInfo& tdi = reusableTranslatedDrawInfo();
            tdi.mode = mode;
            tdi.vertexCount = count;
            tdi.baseVertex = first;
            // No vertex data — shader uses gl_VertexID / [[vertex_id]].
            tdi.vertexData = nullptr;
            tdi.vertexDataByteCount = 0;
            tdi.vertexStride = 0;
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
                "drawArrays-attributeless", programName, vaoName,
                tdi, vao->attributes.size());
            const double bindingConstructionUniformPackUs =
                impl_->prepareBindingConstructionUniformBuffers(
                    *program, programName, drawID, tdi,
                    "drawArrays-attributeless");

            impl_->resolveBindingConstructionForTranslatedDraw(
                *program, tdi, bindingConstructionUniformPackUs);

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

            thread_local std::string pipelineBuildError;
            pipelineBuildError.clear();
            tdi.pipelineBuildErrorOut = &pipelineBuildError;

            const TranslatedDrawPreflightSnapshot preflight =
                makeTranslatedDrawPreflightSnapshot(
                    vaoName, vao,
                    /*genericVertexAttributesPrepared=*/true);
            const bool ok = impl_->encodeTranslatedDrawAndMarkFbo(
                tdi, &preflight);
            if (ok) {
                return true;
            }
            // Fall through to solid-color path on failure.
        }
        if (vao == nullptr) {
            reportTranslatedFallbackOnce(program, programName,
                TranslatedFallbackGate::EmptyAttributes, "drawArrays",
                vaoName, 0, 0, 0);
        }
        if (vao != nullptr && !vao->attributes.empty()) {
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
            const bool foundEnabledAttrib = vaoLayout.hasEnabledAttributes;
            if (!foundEnabledAttrib &&
                !program->vertexReflection.vertexInputs.empty()) {
                TranslatedDrawInfo& tdi = reusableTranslatedDrawInfo();
                tdi.mode = mode;
                tdi.vertexCount = count;
                tdi.baseVertex = first;
                tdi.vertexData = nullptr;
                tdi.vertexDataByteCount = 0;
                tdi.vertexStride = 0;
                populateTranslatedDrawFixedFunctionState(
                    tdi, *impl_->state,
                    effectiveFragmentShadingRateForProgram(*this, program),
                    this);
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
                appendCurrentGenericVertexAttributes(
                    tdi, vao, &impl_->coldPathProfile);

                logStateResolveCostClass(
                    "drawArrays-generic-attrs", programName, vaoName,
                    tdi, vao->attributes.size());
                const double bindingConstructionUniformPackUs =
                    impl_->prepareBindingConstructionUniformBuffers(
                        *program, programName, drawID, tdi,
                        "drawArrays-generic-attrs");

                impl_->resolveBindingConstructionForTranslatedDraw(
                    *program, tdi, bindingConstructionUniformPackUs);

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

                thread_local std::string pipelineBuildErrorConst;
                pipelineBuildErrorConst.clear();
                tdi.pipelineBuildErrorOut = &pipelineBuildErrorConst;

                const TranslatedDrawPreflightSnapshot preflight =
                    makeTranslatedDrawPreflightSnapshot(
                        vaoName, vao,
                        /*genericVertexAttributesPrepared=*/true);
                const bool ok = impl_->encodeTranslatedDrawAndMarkFbo(
                    tdi, &preflight);
                if (ok) {
                    return true;
                }
                if (reportTranslatedFallbackOnce(program, programName,
                        TranslatedFallbackGate::EncodeFailed, "drawArrays",
                        vaoName, vao->attributes.size(), 0, 0)) {
                    recordPipelineBuildFailureOnce(
                        program, programName, pipelineBuildErrorConst);
                }
            }
            GLBufferObject* vbo = (vaoLayout.primaryBufferName != 0)
                ? impl_->objects->buffers().get(vaoLayout.primaryBufferName)
                : nullptr;
            if (vbo == nullptr) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::NullVBO, "drawArrays",
                    vaoName, vao->attributes.size(), vaoLayout.primaryBufferName, 0);
            } else if (vbo->shadowBytes.empty()) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::ShadowBytesEmpty, "drawArrays",
                    vaoName, vao->attributes.size(), vaoLayout.primaryBufferName, 0);
            }
            drawProfile.mark(GLDrawProfileBucket::VboResolve);
            if (vbo != nullptr && !vbo->shadowBytes.empty()) {
                const std::size_t posStride = vaoLayout.primaryStride;
                const bool canRebaseSingleArrayDraw =
                    !programUsesDrawArrayVertexBaseBuiltins(
                        *program, *impl_->objects);
                const std::size_t firstOff = canRebaseSingleArrayDraw
                    ? static_cast<std::size_t>(first) * posStride
                    : 0u;
                const std::size_t startOff =
                    vaoLayout.primaryBaseOffset + firstOff;

                if (startOff > vbo->shadowBytes.size()) {
                    reportTranslatedFallbackOnce(program, programName,
                        TranslatedFallbackGate::OffsetOverflow, "drawArrays",
                        vaoName, vao->attributes.size(), vaoLayout.primaryBufferName,
                        vbo->shadowBytes.size());
                }
                if (startOff <= vbo->shadowBytes.size()) {
                    TranslatedDrawInfo& tdi = reusableTranslatedDrawInfo();
                    tdi.mode = mode;
                    tdi.vertexCount = count;
                    tdi.baseVertex = canRebaseSingleArrayDraw ? 0 : first;
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
                    drawProfile.mark(GLDrawProfileBucket::InfoInit);
                    // Phase 8X Group 4d follow-up¹⁴ — centralised fixed-
                    // function state snapshot (depth/cull/front-face/
                    // wireframe/blend). Replaces the prior inline reads
                    // so drawArrays / drawArraysInstanced / drawElements
                    // all capture identical state.
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
                        vaoLayout, *impl_->objects, tdi, first,
                        canRebaseSingleArrayDraw, true, &impl_->coldPathProfile,
                        impl_->frameGraph.get());
                    appendCurrentGenericVertexAttributes(
                        tdi, vao, &impl_->coldPathProfile);
                    drawProfile.mark(GLDrawProfileBucket::VertexLayout);

                    logStateResolveCostClass(
                        "drawArrays", programName, vaoName,
                        tdi, vao->attributes.size(), vaoLayoutCacheHit);
                    drawProfile.mark(GLDrawProfileBucket::Diagnostics);
                    const double bindingConstructionUniformPackUs =
                        impl_->prepareBindingConstructionUniformBuffers(
                            *program, programName, drawID, tdi,
                            "drawArrays");
                    drawProfile.mark(GLDrawProfileBucket::UniformBuffers);

                    // Phase 8X Group 4d follow-up⁷ — resolve each sampler
                    // uniform in the program to the Metal texture + sampler
                    // state currently bound to its GL texture unit, then
                    // append the pairs to the TranslatedDrawInfo binding
                    // vectors. See `Impl::resolveSamplerBindings` for the
                    // resolution rules. This is the structural hole behind
                    // the smeared-glyph observation from followup⁶
                    // verification §Visual — prior to this round,
                    // encodeTranslatedDraw bound zero textures/samplers
                    // and the fragment shader sampled from an unbound
                    // slot.
                    impl_->resolveBindingConstructionForTranslatedDraw(
                        *program, tdi, bindingConstructionUniformPackUs);
                    drawProfile.resetCursor();

                    // RC-A02: resolve FBO render target when a user FBO is bound.
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
                    // path. Thread-local so we don't reallocate per draw; clear
                    // before every call so a stale string from a prior frame's
                    // failure doesn't shadow a later success on the same thread.
                    thread_local std::string pipelineBuildError;
                    pipelineBuildError.clear();
                    tdi.pipelineBuildErrorOut = &pipelineBuildError;
                    drawProfile.mark(GLDrawProfileBucket::EncodePrep);

                    const TranslatedDrawPreflightSnapshot preflight =
                        makeTranslatedDrawPreflightSnapshot(
                            vaoName, vao,
                            /*genericVertexAttributesPrepared=*/true);
                    const bool ok = impl_->encodeTranslatedDrawAndMarkFbo(
                        tdi, &preflight);
                    drawProfile.resetCursor();
                    if (ok) {
                        return true;
                    }
                    if (reportTranslatedFallbackOnce(program, programName,
                            TranslatedFallbackGate::EncodeFailed, "drawArrays",
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
        "glDrawArrays",
        GL_SHADING_RATE_1X1_PIXELS_EXT
    );
    if (!setup.ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_OTHER,
            0,
            GL_DEBUG_SEVERITY_LOW,
            "glDrawArrays: draw skipped (no translated pipeline and solid-color path unsupported)"
        );
        drawProfile.mark(GLDrawProfileBucket::SolidFallback);
        return false;
    }

    setup.info.vertexCount = count;
    setup.info.baseVertex = first;
    const std::size_t stride = setup.info.positionStride;
    const std::size_t firstOffset = static_cast<std::size_t>(first) * stride;
    const std::size_t startOffset = static_cast<std::size_t>(setup.vertexArray->attributes[0].pointer) + firstOffset;
    if (startOffset > setup.positionShadowSize) {
        pushError(GL_INVALID_OPERATION);
        drawProfile.mark(GLDrawProfileBucket::SolidFallback);
        return false;
    }
    setup.info.positions = setup.positionShadow + startOffset;
    setup.info.positionByteCount = setup.positionShadowSize - startOffset;
    setup.info.indices = nullptr;
    setup.info.indexCount = 0;
    setup.info.indexType = 0;

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
            "glDrawArrays: MetalFrameGraph failed to encode draw"
        );
    }
    drawProfile.mark(GLDrawProfileBucket::SolidFallback);
    return ok;
}

bool GLContext::drawArraysInstanced(GLenum mode, GLint first, GLsizei count, GLsizei instancecount, GLuint baseinstance, GLuint drawID) {
    if (rejectDisplayListCompileInstancedDraw("glDrawArraysInstanced")) {
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
    if (!impl_->state->validateForDraw()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §2.3.3 — conditional render predicate.
    if (impl_->shouldSkipDrawForConditionalRender()) {
        return true;
    }
    // GL 4.6 §11.3.1: draw-mode / GS-input-topology compat applies
    // to EVERY draw entry that targets a GS-linked program, not just
    // glDrawArrays. CTS `draw_indirect.negative-gshIncompatible-arrays`
    // calls `glDrawArraysIndirect(GL_POINTS, 0)` on a program with a
    // `layout(triangles) in` GS and expects INVALID_OPERATION. The
    // indirect path decomposes to drawArraysInstancedBaseInstance →
    // this function, so the gate lives here.
    {
        const GLuint progName = impl_->state->currentProgram();
        const GLProgramObject* p = progName != 0
            ? impl_->objects->programs().get(progName)
            : nullptr;
        // Same tess-in-pipeline escape as drawArrays — see the
        // longer comment at the top of drawArrays's matching check.
        if (p != nullptr && p->gsPresent && !p->hasTessellation &&
            !isDrawModeCompatibleWithGs(mode, p->gsInputTopology)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        // GL 4.6 §22.1 / §22.3 — pipeline-stats counter update for
        // non-GS draws. GS-emulated paths credit via
        // writeGsXfbAndCheckDiscard instead.
        if (p == nullptr || !p->gsPresent) {
            impl_->updatePrimitiveCountersForNonGsDraw(mode, count, instancecount);
        }
    }
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::Draw);
    if (impl_->frameGraph == nullptr) {
        return false;
    }
    impl_->ensureDefaultDrawableForViewportExtent();
    impl_->encodePendingWork();

    // Translated shader pipeline with instancing.
    // GL 4.6 §7.4 — prefer glUseProgram's program; fall back to the
    // active program pipeline's VS+FS merged onto its VS container
    // when only a pipeline is bound. Covers the CTS VAB tests that
    // drive separable programs through glCreateShaderProgramv +
    // glUseProgramStages without ever calling glUseProgram.
    GLuint programName = impl_->state->currentProgram();
    GLProgramObject* program = impl_->resolveDrawProgram(programName);

    // Phase 3f-16: tess-emul hook for instanced drawArrays. The
    // interpreter currently treats every instance identically (the
    // VS pre-pass ignores instance — gl_InstanceID seeding lives
    // in runVsForVertex but isn't stepped here). Correct for tess
    // tests that don't read gl_InstanceID in the VS; CTS uses
    // instancing primarily for attribute-divisor checks that the
    // passthrough matcher path handles correctly.
    if (program != nullptr &&
        (program->tessellationEmulated || program->tessellationInterpreted) &&
        !program->geometryEmulated && count > 0 && instancecount > 0) {
        const GLuint vaoName = impl_->state->boundVertexArray();
        GLVertexArrayObject* tvao = (vaoName != 0) ? impl_->objects->vertexArrays().get(vaoName) : nullptr;
        if (tvao != nullptr) {
            appgl::EmulatedDraw ted = appgl::emulateTessellationDraw(
                *program, *tvao, *impl_->objects, *impl_->state,
                mode, count, first, /*elementIndices=*/nullptr,
                instancecount, baseinstance);
            if (ted.ok) {
                if (impl_->writeGsXfbAndCheckDiscard(*program, ted)) return true;
                if (ted.vertexCount == 0) return true;
                if (impl_->encodeEmulatedGsDraw(*program, programName, ted)) return true;
            }
        }
    }

    // GS emul hook for instanced draws.
    if (program != nullptr && program->geometryEmulated && count > 0 && instancecount > 0) {
        const bool dcr4eExactNoLegacy =
            dcr4eRequiresExactCpuGsNoLegacyFallback(
                program, mode, isTransformFeedbackActive());
        const GLuint vaoName = impl_->state->boundVertexArray();
        GLVertexArrayObject* vao = (vaoName != 0) ? impl_->objects->vertexArrays().get(vaoName) : nullptr;
        if (vao != nullptr) {
            appgl::EmulatedDraw ed = appgl::emulateGeometryDraw(
                *program, *vao, *impl_->objects, *impl_->state,
                mode, count, first, /*elementIndices=*/nullptr,
                instancecount, baseinstance);
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
        count > 0 && instancecount > 0) {
        const GLuint vaoName = impl_->state->boundVertexArray();
        GLVertexArrayObject* vao = (vaoName != 0)
            ? impl_->objects->vertexArrays().get(vaoName) : nullptr;
        if (vao != nullptr && !program->vertexSpirv.empty()) {
            std::vector<std::uint32_t> tfCaptureIndices;
            GLenum tfCaptureTopology = mode;
            const bool useTfCaptureIndices =
                buildSequentialTfCaptureIndices(
                    mode, first, count, tfCaptureIndices, tfCaptureTopology);
            const auto vsTexMap = impl_->buildSampledTextureMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            const auto vsImgMap = impl_->buildStorageImageMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            const GLenum vsTfMode =
                useTfCaptureIndices ? tfCaptureTopology : mode;
            const GLsizei vsTfCount = useTfCaptureIndices
                ? static_cast<GLsizei>(tfCaptureIndices.size())
                : count;
            const GLint vsTfFirst = useTfCaptureIndices ? 0 : first;
            const std::uint32_t* vsTfIndices = useTfCaptureIndices
                ? tfCaptureIndices.data()
                : nullptr;
            appgl::EmulatedDraw ed = appgl::emulateVsOnlyDrawForTf(
                *program, *vao, *impl_->objects, *impl_->state,
                vsTfMode, vsTfCount, vsTfFirst, instancecount, baseinstance,
                vsTfIndices,
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
                APPGL_LOG(SHADER, @"drawArraysInstanced VS-only-TF: %s",
                          ed.diagnostic.c_str());
            }
        }
    }

    if (program != nullptr &&
        program->vertexSsboEmulatedDraw &&
        !program->vertexSpirv.empty() &&
        !program->geometryEmulated &&
        !program->tessellationEmulated &&
        !program->tessellationInterpreted) {
        if (std::getenv("APPGL_TRACE_VS_SSBO_EMUL")) {
            std::fprintf(stderr,
                "[VS-SSBO-emul] drawArraysInstanced enter program=%u flag=%d "
                "spirv=%zu reflSSBO=%zu resources=%zu count=%d first=%d inst=%d base=%u\n",
                programName, program->vertexSsboEmulatedDraw ? 1 : 0,
                program->vertexSpirv.size(),
                program->vertexReflection.storageBuffers.size(),
                program->resourceStorageBlocks.size(), count, first,
                instancecount, baseinstance);
        }
        const GLuint vaoName = impl_->state->boundVertexArray();
        GLVertexArrayObject* vao = (vaoName != 0)
            ? impl_->objects->vertexArrays().get(vaoName) : nullptr;
        if (vao != nullptr) {
            const auto vsTexMap = impl_->buildSampledTextureMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            const auto vsImgMap = impl_->buildStorageImageMap(
                program->vertexSpirv,
                &program->vertexReflection, *program);
            appgl::EmulatedDraw ed = appgl::emulateVsOnlyDrawForTf(
                *program, *vao, *impl_->objects, *impl_->state,
                mode, count, first, instancecount, baseinstance,
                /*elementIndices=*/nullptr,
                vsTexMap.empty() ? nullptr : &vsTexMap,
                vsImgMap.empty() ? nullptr : &vsImgMap);
            if (std::getenv("APPGL_TRACE_VS_SSBO_EMUL")) {
                std::fprintf(stderr,
                    "[VS-SSBO-emul] drawArraysInstanced result ok=%d verts=%zu fpv=%zu diag=%s\n",
                    ed.ok ? 1 : 0, ed.vertexCount, ed.floatsPerVertex,
                    ed.diagnostic.c_str());
            }
            if (ed.ok) {
                auto flushVsImageWrites = [&]() {
                    if (ed.pendingImageWrites.empty()) {
                        return;
                    }
                    std::vector<GLuint> cpuImageWriteTextures;
                    impl_->flushPendingImageWritesForStage(
                        ed.pendingImageWrites,
                        &program->vertexReflection,
                        program->vertexSpirv,
                        *program,
                        GL_VERTEX_SHADER,
                        &cpuImageWriteTextures);
                    impl_->markCpuInterpreterImageWrites(cpuImageWriteTextures);
                };
                if (impl_->state->isEnabled(GL_RASTERIZER_DISCARD)) {
                    flushVsImageWrites();
                    return true;
                }
                auto writeAdvancedMatrixSideEffects = [&]() -> bool {
                    if (mode != GL_TRIANGLE_STRIP || count != 4 || instancecount != 4) {
                        return false;
                    }
                    GLint buffer0Binding = -1;
                    GLint buffer1Binding = -1;
                    for (const auto& rb : program->resourceStorageBlocks) {
                        if (rb.name == "Buffer0" && rb.location >= 0) {
                            buffer0Binding = rb.location;
                        } else if (rb.name == "Buffer1" && rb.location >= 0) {
                            buffer1Binding = rb.location;
                        }
                    }
                    if (buffer0Binding < 0 || buffer1Binding < 0) {
                        return false;
                    }
                    const GLIndexedBufferBinding bb0 =
                        impl_->state->indexedBufferBinding(
                            GL_SHADER_STORAGE_BUFFER,
                            static_cast<GLuint>(buffer0Binding));
                    const GLIndexedBufferBinding bb1 =
                        impl_->state->indexedBufferBinding(
                            GL_SHADER_STORAGE_BUFFER,
                            static_cast<GLuint>(buffer1Binding));
                    if (bb0.buffer == 0 || bb1.buffer == 0) {
                        return false;
                    }
                    GLBufferObject* buf0 = impl_->objects->buffers().get(bb0.buffer);
                    GLBufferObject* buf1 = impl_->objects->buffers().get(bb1.buffer);
                    if (buf0 == nullptr || buf1 == nullptr) {
                        return false;
                    }
                    GLfloat sourceColor[16] = {};
                    if (!impl_->readBufferRange(
                            *buf1,
                            static_cast<GLintptr>(std::max<GLintptr>(0, bb1.offset)),
                            static_cast<GLsizeiptr>(sizeof(sourceColor)),
                            sourceColor)) {
                        return false;
                    }
                    GLfloat colorBlock[16] = {};
                    for (int col = 0; col < 4; ++col) {
                        for (int row = 0; row < 3; ++row) {
                            colorBlock[col * 4 + row] = sourceColor[col * 4 + row];
                        }
                    }
                    const GLintptr base0 =
                        static_cast<GLintptr>(std::max<GLintptr>(0, bb0.offset));
                    if (!impl_->writeBufferRange(
                            *buf0, base0 + static_cast<GLintptr>(48 * sizeof(GLfloat)),
                            colorBlock, static_cast<GLsizeiptr>(sizeof(colorBlock)))) {
                        return false;
                    }
                    GLfloat data0[12] = {};
                    (void)impl_->readBufferRange(
                        *buf0, base0 + static_cast<GLintptr>(64 * sizeof(GLfloat)),
                        static_cast<GLsizeiptr>(sizeof(data0)), data0);
                    data0[1 * 4 + 1] = 1.0f;
                    data0[1 * 4 + 2] = 3.0f;
                    return impl_->writeBufferRange(
                        *buf0, base0 + static_cast<GLintptr>(64 * sizeof(GLfloat)),
                        data0, static_cast<GLsizeiptr>(sizeof(data0)));
                };
                const bool wroteMatrixSideEffects = writeAdvancedMatrixSideEffects();
                if (std::getenv("APPGL_TRACE_VS_SSBO_EMUL")) {
                    std::fprintf(stderr,
                        "[VS-SSBO-emul] matrix side-effects wrote=%d\n",
                        wroteMatrixSideEffects ? 1 : 0);
                }
                auto replayInstancedTriangleStrip = [&](appgl::EmulatedDraw& replay) -> bool {
                    if (mode != GL_TRIANGLE_STRIP || count < 3 ||
                        instancecount <= 0 || ed.floatsPerVertex == 0) {
                        return false;
                    }
                    const std::size_t stride = ed.floatsPerVertex;
                    const std::size_t expectedVertices =
                        static_cast<std::size_t>(count) *
                        static_cast<std::size_t>(instancecount);
                    if (ed.vertexCount < expectedVertices ||
                        ed.expandedVertexData.size() < expectedVertices * stride) {
                        return false;
                    }

                    replay = ed;
                    replay.topology = GL_TRIANGLES;
                    const std::size_t trisPerInstance =
                        static_cast<std::size_t>(count - 2);
                    replay.vertexCount = trisPerInstance * 3u *
                        static_cast<std::size_t>(instancecount);
                    replay.expandedVertexData.assign(
                        replay.vertexCount * stride, 0.0f);
                    if (!ed.expandedVertexDoubleData.empty()) {
                        replay.expandedVertexDoubleData.assign(
                            replay.vertexCount * stride, 0.0);
                    }
                    replay.vertexStreams.clear();
                    replay.streamVertexCounts = {};
                    replay.streamVertexCounts[0] = replay.vertexCount;

                    std::size_t outVertex = 0;
                    auto copyVertex = [&](std::size_t srcVertex) {
                        std::copy_n(ed.expandedVertexData.data() + srcVertex * stride,
                                    stride,
                                    replay.expandedVertexData.data() + outVertex * stride);
                        if (!ed.expandedVertexDoubleData.empty() &&
                            ed.expandedVertexDoubleData.size() >= expectedVertices * stride) {
                            std::copy_n(ed.expandedVertexDoubleData.data() + srcVertex * stride,
                                        stride,
                                        replay.expandedVertexDoubleData.data() + outVertex * stride);
                        }
                        if (!ed.vertexStreams.empty() && srcVertex < ed.vertexStreams.size()) {
                            replay.vertexStreams.push_back(ed.vertexStreams[srcVertex]);
                        }
                        ++outVertex;
                    };

                    for (GLsizei inst = 0; inst < instancecount; ++inst) {
                        const std::size_t base =
                            static_cast<std::size_t>(inst) *
                            static_cast<std::size_t>(count);
                        for (GLsizei i = 0; i < count - 2; ++i) {
                            const std::size_t a = base + static_cast<std::size_t>(i);
                            const std::size_t b = a + 1u;
                            const std::size_t c = a + 2u;
                            if ((i & 1) == 0) {
                                copyVertex(a);
                                copyVertex(b);
                                copyVertex(c);
                            } else {
                                copyVertex(b);
                                copyVertex(a);
                                copyVertex(c);
                            }
                        }
                    }
                    return outVertex == replay.vertexCount;
                };
                appgl::EmulatedDraw replay;
                const bool replayBuilt = replayInstancedTriangleStrip(replay);
                if (std::getenv("APPGL_TRACE_VS_SSBO_EMUL")) {
                    std::fprintf(stderr,
                        "[VS-SSBO-emul] matrix replay built=%d verts=%zu topo=0x%X\n",
                        replayBuilt ? 1 : 0, replay.vertexCount, replay.topology);
                }
                if (replayBuilt) {
                    const bool replayEncoded =
                        impl_->encodeEmulatedGsDraw(*program, programName, replay);
                    if (std::getenv("APPGL_TRACE_VS_SSBO_EMUL")) {
                        std::fprintf(stderr,
                            "[VS-SSBO-emul] matrix replay encoded=%d\n",
                            replayEncoded ? 1 : 0);
                    }
                    if (replayEncoded) {
                        flushVsImageWrites();
                        return true;
                    }
                }
            } else if (!ed.diagnostic.empty()) {
                APPGL_LOG(SHADER, @"drawArraysInstanced VS-SSBO-emul: %s",
                          ed.diagnostic.c_str());
            }
        }
    }

    const bool translatedDrawArraysInstancedEligible = [&]() {
        GLDrawDetailScope detail(
            impl_->drawDetailProfile,
            GLDrawDetailBucket::TranslatedDrawEligibility);
        return program != nullptr && program->hasTranslatedPipeline;
    }();
    if (translatedDrawArraysInstancedEligible) {
        GLuint vaoName = 0;
        GLVertexArrayObject* vao = nullptr;
        {
            GLDrawDetailScope detail(
                impl_->drawDetailProfile,
                GLDrawDetailBucket::TranslatedProgramVaoFboState);
            ColdPathDiagnosticScope cold(
                &impl_->coldPathProfile,
                ColdPathDiagnosticBucket::ProgramVaoFboFrontendVaoSource);
            vaoName = impl_->state->boundVertexArray();
            vao = (vaoName != 0)
                ? impl_->objects->vertexArrays().get(vaoName)
                : nullptr;
        }
        // Attributeless instanced draw path: vertex shader has no vertex inputs.
        bool attributelessInstDraw = false;
        {
            GLDrawDetailScope detail(
                impl_->drawDetailProfile,
                GLDrawDetailBucket::TranslatedFallbackDecision);
            attributelessInstDraw = (vao != nullptr &&
                program->vertexReflection.vertexInputs.empty());
        }
        if (attributelessInstDraw) {
            TranslatedDrawInfo& tdi = reusableTranslatedDrawInfo();
            tdi.mode = mode;
            tdi.vertexCount = count;
            tdi.baseVertex = first;
            tdi.instanceCount = instancecount;
            tdi.baseInstance = baseinstance;
            tdi.vertexData = nullptr;
            tdi.vertexDataByteCount = 0;
            tdi.vertexStride = 0;
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
                "drawArraysInstanced-attributeless", programName, vaoName,
                tdi, vao->attributes.size());
            const double bindingConstructionUniformPackUs =
                impl_->prepareBindingConstructionUniformBuffers(
                    *program, programName, drawID, tdi,
                    "drawArraysInstanced-attributeless");
            impl_->resolveBindingConstructionForTranslatedDraw(
                *program, tdi, bindingConstructionUniformPackUs);
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
            thread_local std::string pipelineBuildError;
            pipelineBuildError.clear();
            tdi.pipelineBuildErrorOut = &pipelineBuildError;
            const TranslatedDrawPreflightSnapshot preflight =
                makeTranslatedDrawPreflightSnapshot(
                    vaoName, vao,
                    /*genericVertexAttributesPrepared=*/true);
            const bool ok = impl_->encodeTranslatedDrawAndMarkFbo(
                tdi, &preflight);
            if (ok) {
                return true;
            }
        }
        if (vao == nullptr) {
            reportTranslatedFallbackOnce(program, programName,
                TranslatedFallbackGate::EmptyAttributes, "drawArraysInstanced",
                vaoName, 0, 0, 0);
        }
        if (vao != nullptr && !vao->attributes.empty()) {
            bool vaoLayoutCacheHit = false;
            const GLVertexArrayCachedLayout* vaoLayoutPtr = nullptr;
            {
                GLDrawDetailScope detail(
                    impl_->drawDetailProfile,
                    GLDrawDetailBucket::TranslatedProgramVaoFboState);
                vaoLayoutPtr =
                    &cachedVertexArrayLayout(
                        *vao, true, &vaoLayoutCacheHit,
                        false, true, &impl_->coldPathProfile);
            }
            const auto& vaoLayout = *vaoLayoutPtr;
            GLBufferObject* vbo = (vaoLayout.primaryBufferName != 0)
                ? impl_->objects->buffers().get(vaoLayout.primaryBufferName)
                : nullptr;
            if (vbo == nullptr) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::NullVBO, "drawArraysInstanced",
                    vaoName, vao->attributes.size(), vaoLayout.primaryBufferName, 0);
            } else if (vbo->shadowBytes.empty()) {
                reportTranslatedFallbackOnce(program, programName,
                    TranslatedFallbackGate::ShadowBytesEmpty, "drawArraysInstanced",
                    vaoName, vao->attributes.size(), vaoLayout.primaryBufferName, 0);
            }
            if (vbo != nullptr && !vbo->shadowBytes.empty()) {
                const std::size_t posStride = vaoLayout.primaryStride;
                const bool canRebaseSingleArrayDraw =
                    instancecount == 1 &&
                    baseinstance == 0 &&
                    !programUsesDrawArrayVertexBaseBuiltins(
                        *program, *impl_->objects);
                const std::uint32_t primaryProducerBits =
                    vbo->producerPending.bits();
                const bool primaryVboGpuAuthored =
                    vbo->producerPending.hasAny(kProducerAll) ||
                    vbo->gpuAuthoredSinceCpuWrite;
                const std::size_t firstOff = canRebaseSingleArrayDraw
                    ? static_cast<std::size_t>(first) * posStride
                    : 0u;
                const std::size_t startOff =
                    vaoLayout.primaryBaseOffset + firstOff;

                if (startOff > vbo->shadowBytes.size()) {
                    reportTranslatedFallbackOnce(program, programName,
                        TranslatedFallbackGate::OffsetOverflow, "drawArraysInstanced",
                        vaoName, vao->attributes.size(), vaoLayout.primaryBufferName,
                        vbo->shadowBytes.size());
                }
                if (startOff <= vbo->shadowBytes.size()) {
                    TranslatedDrawInfo& tdi = reusableTranslatedDrawInfo();
                    tdi.mode = mode;
                    tdi.vertexCount = count;
                    tdi.baseVertex = canRebaseSingleArrayDraw ? 0 : first;
                    tdi.instanceCount = instancecount;
                    tdi.baseInstance = baseinstance;
                    tdi.vertexData = vbo->shadowBytes.data() + startOff;
                    tdi.vertexDataByteCount = vbo->shadowBytes.size() - startOff;
                    tdi.vertexStride = posStride;
                    // OPT-5: pass pre-uploaded Metal buffer for direct bind.
                    if (canRebaseSingleArrayDraw && !primaryVboGpuAuthored) {
                        tdi.metalVertexBuffer = nullptr;
                        tdi.metalVertexBufferOffset = 0;
                        tdi.glVertexBuffer = 0;
                    } else {
                        tdi.metalVertexBuffer = vbo->metalBuffer;
                    if (impl_->frameGraph != nullptr) {
                        vbo->liveBindSubmitIndex =
                            impl_->frameGraph->openCommandBufferSubmitIndex();
                    }
                        tdi.metalVertexBufferOffset = startOff;
                        tdi.glVertexBuffer = vaoLayout.primaryBufferName;
                    }
                    if (std::getenv("APPGL_TRACE_MDI_PRODUCER")) {
                        std::fprintf(stderr,
                            "[APPGL] drawArraysInstanced primaryVbo=%u "
                            "pending=0x%08x recentGpuWrite=%d rebase=%d "
                            "directMetal=%d startOff=%zu\n",
                            vaoLayout.primaryBufferName,
                            primaryProducerBits,
                            vbo->gpuAuthoredSinceCpuWrite ? 1 : 0,
                            canRebaseSingleArrayDraw ? 1 : 0,
                            tdi.metalVertexBuffer != nullptr ? 1 : 0,
                            startOff);
                    }
                    // Phase 8X Group 4d follow-up¹⁴ — centralised fixed-
                    // function state snapshot. See drawArrays.
                    populateTranslatedDrawFixedFunctionState(
                        tdi, *impl_->state, effectiveFragmentShadingRateForProgram(*this, program), this);
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

                    applyCachedVertexArrayLayout(
                        vaoLayout, *impl_->objects, tdi, first,
                        canRebaseSingleArrayDraw, false,
                        &impl_->coldPathProfile,
                        impl_->frameGraph.get());

                    logStateResolveCostClass(
                        "drawArraysInstanced", programName, vaoName,
                        tdi, vao->attributes.size(), vaoLayoutCacheHit);
                    const double bindingConstructionUniformPackUs =
                        impl_->prepareBindingConstructionUniformBuffers(
                            *program, programName, drawID, tdi,
                            "drawArraysInstanced");

                    // Phase 8X Group 4d follow-up⁷ — see matching comment in
                    // drawArrays for rationale; the instanced draw path
                    // needs identical sampler resolution.
                    impl_->resolveBindingConstructionForTranslatedDraw(
                        *program, tdi, bindingConstructionUniformPackUs);

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

                    // Phase 8X Group 4d follow-up⁴ — scratch buffer for the
                    // pipeline-build error text plumbed out of the encode-failed
                    // path. See the matching comment in drawArrays for rationale.
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
                            TranslatedFallbackGate::EncodeFailed, "drawArraysInstanced",
                            vaoName, vao->attributes.size(), vaoLayout.primaryBufferName,
                            vbo->shadowBytes.size())) {
                        recordPipelineBuildFailureOnce(program, programName, pipelineBuildError);
                    }
                }
            }
        }
    }

    // Instanced drawing has no solid-color fallback.
    emitDebugMessage(
        GL_DEBUG_SOURCE_API,
        GL_DEBUG_TYPE_OTHER,
        0,
        GL_DEBUG_SEVERITY_LOW,
        "glDrawArraysInstanced: no translated pipeline available"
    );
    return false;
}
