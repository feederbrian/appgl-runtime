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
#include "GLContextDrawIndirect.inc.mm"

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
