// This file is textually included by GLContextDraw.inc.mm. Do not compile it directly.
// It contains the GLContext transform-feedback draw method definitions split out for navigation only.

#line 19 "/private/tmp/appgl-bug3-clean/src/context/GLContextDraw.inc.mm" // Preserve source identity so this relocation stays codegen-neutral; __FILE__/__LINE__/debug-info intentionally report the original GLContextDraw.inc.mm.
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
