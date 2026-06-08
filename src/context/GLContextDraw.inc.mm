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
#include "GLContextDrawTransformFeedback.inc.mm"

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
