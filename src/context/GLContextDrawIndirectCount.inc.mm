// This file is textually included by GLContextDraw.inc.mm. Do not compile it directly.
// It contains the GLContext indirect-count wrapper definitions split out for navigation only.

#line 206 "/private/tmp/appgl-bug3-clean/src/context/GLContextDraw.inc.mm" // Preserve source identity so this relocation stays codegen-neutral; __FILE__/__LINE__/debug-info intentionally report the original GLContextDraw.inc.mm.
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
