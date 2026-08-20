// Hand-written fixed-function matrix entry points.
//
// The codegen normally emits a no-op `extern "C" APIENTRY` stub for every
// compat-profile entry into `gl_fixed_function.gen.cpp`. The names listed
// in `MANUAL_FIXED_FUNCTION_OVERRIDES` (see
// `tools/gen_from_registry/generate_from_registry.py`) are EXCLUDED from
// that emission so this translation unit can supply the real definitions
// without symbol collisions. Forward declarations in
// `gl_procaddress.gen.cpp` still live in codegen, so engines that resolve
// these names through `appglGetProcAddress` get a function pointer that
// lands here.
//
// Each entry point routes the call into the per-context
// `MatrixStateMirror` which the compat-shader rewriter
// (`shader/CompatShaderRewrite.h`) and the draw-time uniform pusher in
// `GLContext::draw*` rely on for synthesized `appgl_*` matrix uniforms.
// Errors (invalid enum, stack overflow/underflow) are pushed via
// `GLContext::pushError` so they appear both in the per-context glGetError
// queue AND the runtime ring buffer for external diagnostics.
//
// Why this lives in runtime/ rather than state/: the matrix mirror itself
// is a pure state machine with no Runtime dependency (so it can be unit
// tested in isolation). The entry points DO depend on Runtime + GLContext
// to look up the current context and push errors, so they live alongside
// the rest of the AppGL runtime translation units.

#include "../../include/AppGL/glcorearb.h"

#include "../context/GLContext.h"
#include "../state/GLStateTracker.h"
#include "../state/MatrixStateMirror.h"
#include "AppGLRuntime.h"

#ifndef GL_MAX_TEXTURE_COORDS
#define GL_MAX_TEXTURE_COORDS 0x8871
#endif

namespace {

// Convenience accessor — every matrix entry point starts with this lookup.
// Returns nullptr when there is no current context, in which case the entry
// point silently no-ops (matches the rest of the runtime: calls without a
// current context are dropped without crashing, and there is no spec-defined
// error to report — `glGetError` itself requires a current context).
appgl::GLContext* matrixContext() {
    return appgl::Runtime::shared().currentContext();
}

}  // namespace

extern "C" void APIENTRY glClientActiveTexture(GLenum texture) {
    auto* ctx = matrixContext();
    if (ctx == nullptr) {
        return;
    }
    GLint maxTextureCoords = 8;
    ctx->queryInteger(GL_MAX_TEXTURE_COORDS, &maxTextureCoords);
    if (maxTextureCoords <= 0) {
        maxTextureCoords = 8;
    }
    if (texture < GL_TEXTURE0 ||
        static_cast<GLint>(texture - GL_TEXTURE0) >= maxTextureCoords) {
        ctx->pushError(GL_INVALID_ENUM, "glClientActiveTexture",
                       "texture unit exceeds GL_MAX_TEXTURE_COORDS");
        return;
    }
    const GLuint unit = texture - GL_TEXTURE0;
    ctx->state().setActiveTextureUnit(unit);
    ctx->matrixState().setActiveTextureUnit(unit);
}

extern "C" void APIENTRY glMatrixMode(GLenum mode) {
    auto* ctx = matrixContext();
    if (ctx == nullptr) {
        return;
    }
    if (!ctx->matrixState().setMatrixMode(mode)) {
        ctx->pushError(GL_INVALID_ENUM, "glMatrixMode",
                       "mode is not GL_MODELVIEW, GL_PROJECTION, or GL_TEXTURE");
    }
}

extern "C" void APIENTRY glLoadIdentity(void) {
    auto* ctx = matrixContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->matrixState().loadIdentity();
}

extern "C" void APIENTRY glLoadMatrixf(const GLfloat* m) {
    auto* ctx = matrixContext();
    if (ctx == nullptr || m == nullptr) {
        return;
    }
    ctx->matrixState().loadMatrix(m);
}

extern "C" void APIENTRY glLoadMatrixd(const GLdouble* m) {
    auto* ctx = matrixContext();
    if (ctx == nullptr || m == nullptr) {
        return;
    }
    ctx->matrixState().loadMatrix(m);
}

extern "C" void APIENTRY glLoadTransposeMatrixf(const GLfloat* m) {
    auto* ctx = matrixContext();
    if (ctx == nullptr || m == nullptr) {
        return;
    }
    ctx->matrixState().loadTransposeMatrix(m);
}

extern "C" void APIENTRY glLoadTransposeMatrixd(const GLdouble* m) {
    auto* ctx = matrixContext();
    if (ctx == nullptr || m == nullptr) {
        return;
    }
    ctx->matrixState().loadTransposeMatrix(m);
}

extern "C" void APIENTRY glMultMatrixf(const GLfloat* m) {
    auto* ctx = matrixContext();
    if (ctx == nullptr || m == nullptr) {
        return;
    }
    ctx->matrixState().multMatrix(m);
}

extern "C" void APIENTRY glMultMatrixd(const GLdouble* m) {
    auto* ctx = matrixContext();
    if (ctx == nullptr || m == nullptr) {
        return;
    }
    ctx->matrixState().multMatrix(m);
}

extern "C" void APIENTRY glMultTransposeMatrixf(const GLfloat* m) {
    auto* ctx = matrixContext();
    if (ctx == nullptr || m == nullptr) {
        return;
    }
    ctx->matrixState().multTransposeMatrix(m);
}

extern "C" void APIENTRY glMultTransposeMatrixd(const GLdouble* m) {
    auto* ctx = matrixContext();
    if (ctx == nullptr || m == nullptr) {
        return;
    }
    ctx->matrixState().multTransposeMatrix(m);
}

extern "C" void APIENTRY glPushMatrix(void) {
    auto* ctx = matrixContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->pushMatrixCompat();
}

extern "C" void APIENTRY glPopMatrix(void) {
    auto* ctx = matrixContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->popMatrixCompat();
}

extern "C" void APIENTRY glTranslatef(GLfloat x, GLfloat y, GLfloat z) {
    auto* ctx = matrixContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->matrixState().translate(static_cast<double>(x),
                                 static_cast<double>(y),
                                 static_cast<double>(z));
}

extern "C" void APIENTRY glTranslated(GLdouble x, GLdouble y, GLdouble z) {
    auto* ctx = matrixContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->matrixState().translate(x, y, z);
}

extern "C" void APIENTRY glRotatef(GLfloat angle, GLfloat x, GLfloat y, GLfloat z) {
    auto* ctx = matrixContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->matrixState().rotate(static_cast<double>(angle),
                              static_cast<double>(x),
                              static_cast<double>(y),
                              static_cast<double>(z));
}

extern "C" void APIENTRY glRotated(GLdouble angle, GLdouble x, GLdouble y, GLdouble z) {
    auto* ctx = matrixContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->matrixState().rotate(angle, x, y, z);
}

extern "C" void APIENTRY glScalef(GLfloat x, GLfloat y, GLfloat z) {
    auto* ctx = matrixContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->matrixState().scale(static_cast<double>(x),
                             static_cast<double>(y),
                             static_cast<double>(z));
}

extern "C" void APIENTRY glScaled(GLdouble x, GLdouble y, GLdouble z) {
    auto* ctx = matrixContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->matrixState().scale(x, y, z);
}

extern "C" void APIENTRY glOrtho(GLdouble left, GLdouble right, GLdouble bottom,
                                  GLdouble top, GLdouble zNear, GLdouble zFar) {
    auto* ctx = matrixContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->matrixState().ortho(left, right, bottom, top, zNear, zFar);
}

extern "C" void APIENTRY glFrustum(GLdouble left, GLdouble right, GLdouble bottom,
                                    GLdouble top, GLdouble zNear, GLdouble zFar) {
    auto* ctx = matrixContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->matrixState().frustum(left, right, bottom, top, zNear, zFar);
}
