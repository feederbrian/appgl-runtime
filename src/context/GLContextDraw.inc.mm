// This file is textually included by GLContext.mm. Do not compile it directly.
// It contains GLContext draw-domain method definitions split out for navigation only.

#if defined(APPGL_GLCONTEXT_DRAW_ARRAYS)
#include "GLContextDrawArrays.inc.mm"

#elif defined(APPGL_GLCONTEXT_DRAW_ELEMENTS)
#include "GLContextDrawElements.inc.mm"

#elif defined(APPGL_GLCONTEXT_DRAW_BASE_VERTEX)
#include "GLContextDrawBaseVertex.inc.mm"

#elif defined(APPGL_GLCONTEXT_DRAW_BASE_INSTANCE)
#include "GLContextDrawBaseInstance.inc.mm"

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
