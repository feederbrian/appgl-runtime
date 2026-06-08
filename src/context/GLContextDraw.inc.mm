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
#include "GLContextDrawIndirectCountHelpers.inc.mm"

#elif defined(APPGL_GLCONTEXT_DRAW_INDIRECT_COUNT)
#include "GLContextDrawIndirectCount.inc.mm"

#else
#error "GLContextDraw.inc.mm included without a draw section selector"
#endif
