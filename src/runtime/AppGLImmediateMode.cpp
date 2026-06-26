// Hand-written compat-profile immediate-mode entry points.
//
// Phase 8X Group 4d follow-up¹⁷ — these entries were moved from the
// auto-generated `gl_fixed_function.gen.cpp` silent-stub path into this
// hand-written translation unit because Chobby's Chili UI renders every
// panel / border / button through OpenGL 1.x immediate mode
// (glBegin / glVertex* / glColor* / glTexCoord* / glMultiTexCoord* /
// glEnd), which the core profile stubs as error pushes. Without real
// implementations BAR reaches its main-menu state with an empty render
// target — audio plays, custom cursor shows, but no UI chrome appears.
//
// The names listed in `MANUAL_FIXED_FUNCTION_OVERRIDES` (see
// `tools/gen_from_registry/generate_from_registry.py`) are EXCLUDED
// from codegen stub emission so this TU can supply the real definitions
// without `multiple definition` link errors. Forward declarations in
// `gl_procaddress.gen.cpp` are still emitted, so engines that resolve
// names through `appglGetProcAddress` get a function pointer that lands
// here.
//
// The five methods on `GLContext` (`beginImmediate`, `immediateVertex`,
// `immediateColor`, `immediateTexCoord`, `endImmediate`) implement the
// actual capture state machine. This file is just a thin set of extern
// "C" trampolines that normalize the many GL variant arities (2f/3f/4f/
// 2fv/3fv/4fv/3ub/4ub/3ubv/4ubv) into the unified GLContext surface.
// That keeps the capture logic testable independently of the
// extern-C binding layer and parallels the pattern used by
// AppGLMatrixOverrides.cpp for the matrix stack entry points.
//
// `glLightModel*` is silently accepted as a no-op — BAR Chobby sets
// GL_LIGHT_MODEL_TWO_SIDE during its compat init but AppGL has no
// fixed-function lighting (compat shaders do their own lighting math
// on top of the matrix uniforms), so there is nothing to store and
// nothing downstream reads it. Advertising the entry points as
// well-formed no-ops is enough to keep the engine past its init
// phase — the alternative (a GL_INVALID_ENUM push from the generic
// stub) would get logged as a spec violation on every cold boot.

#include "../../include/AppGL/glcorearb.h"

#include "../context/GLContext.h"
#include "../runtime/AppGLProfile.h"
#include "AppGLRuntime.h"

#include <cmath>
#include <vector>

#ifndef GL_SHADE_MODEL
#define GL_SHADE_MODEL 0x0B54
#endif
#ifndef GL_FLAT
#define GL_FLAT 0x1D00
#endif
#ifndef GL_SMOOTH
#define GL_SMOOTH 0x1D01
#endif
#ifndef GL_COLOR_ARRAY
#define GL_COLOR_ARRAY 0x8076
#endif
#ifndef GL_TEXTURE_COORD_ARRAY
#define GL_TEXTURE_COORD_ARRAY 0x8078
#endif
#ifndef GL_RENDER
#define GL_RENDER 0x1C00
#endif
#ifndef GL_SELECT
#define GL_SELECT 0x1C02
#endif
#ifndef GL_FOG_START
#define GL_FOG_START 0x0B63
#endif
#ifndef GL_FOG_COLOR
#define GL_FOG_COLOR 0x0B66
#endif
#ifndef GL_COMPILE
#define GL_COMPILE 0x1300
#endif
#ifndef GL_COMPILE_AND_EXECUTE
#define GL_COMPILE_AND_EXECUTE 0x1301
#endif
#ifndef GL_FRONT_AND_BACK
#define GL_FRONT_AND_BACK 0x0408
#endif
#ifndef GL_AMBIENT_AND_DIFFUSE
#define GL_AMBIENT_AND_DIFFUSE 0x1602
#endif
#ifndef GL_AMBIENT
#define GL_AMBIENT 0x1200
#endif
#ifndef GL_DIFFUSE
#define GL_DIFFUSE 0x1201
#endif
#ifndef GL_SPECULAR
#define GL_SPECULAR 0x1202
#endif
#ifndef GL_POSITION
#define GL_POSITION 0x1203
#endif
#ifndef GL_SPOT_DIRECTION
#define GL_SPOT_DIRECTION 0x1204
#endif
#ifndef GL_LIGHT_MODEL_TWO_SIDE
#define GL_LIGHT_MODEL_TWO_SIDE 0x0B52
#endif
#ifndef GL_LIGHT_MODEL_AMBIENT
#define GL_LIGHT_MODEL_AMBIENT 0x0B53
#endif
#ifndef GL_CLIP_PLANE0
#define GL_CLIP_PLANE0 0x3000
#endif
#ifndef GL_TEXTURE_ENV
#define GL_TEXTURE_ENV 0x2300
#endif
#ifndef GL_TEXTURE_ENV_MODE
#define GL_TEXTURE_ENV_MODE 0x2200
#endif
#ifndef GL_TEXTURE_ENV_COLOR
#define GL_TEXTURE_ENV_COLOR 0x2201
#endif
#ifndef GL_S
#define GL_S 0x2000
#endif
#ifndef GL_T
#define GL_T 0x2001
#endif
#ifndef GL_R
#define GL_R 0x2002
#endif
#ifndef GL_Q
#define GL_Q 0x2003
#endif
#ifndef GL_TEXTURE_GEN_MODE
#define GL_TEXTURE_GEN_MODE 0x2500
#endif
#ifndef GL_ACCUM_BUFFER_BIT
#define GL_ACCUM_BUFFER_BIT 0x00000200
#endif
#ifndef GL_RED_SCALE
#define GL_RED_SCALE 0x0D14
#endif
#ifndef GL_RED_BIAS
#define GL_RED_BIAS 0x0D15
#endif
#ifndef GL_GREEN_SCALE
#define GL_GREEN_SCALE 0x0D18
#endif
#ifndef GL_GREEN_BIAS
#define GL_GREEN_BIAS 0x0D19
#endif
#ifndef GL_BLUE_SCALE
#define GL_BLUE_SCALE 0x0D1A
#endif
#ifndef GL_BLUE_BIAS
#define GL_BLUE_BIAS 0x0D1B
#endif
#ifndef GL_ALPHA_SCALE
#define GL_ALPHA_SCALE 0x0D1C
#endif
#ifndef GL_ALPHA_BIAS
#define GL_ALPHA_BIAS 0x0D1D
#endif

namespace {

// Every trampoline starts with this lookup. When no context is current
// we silently no-op (matches the rest of the runtime: drop the call
// instead of crashing, since there is no spec-defined error to report).
appgl::GLContext* immediateContext() {
    return appgl::Runtime::shared().currentContext();
}

}  // namespace

// ── glBegin / glEnd ──────────────────────────────────────────────────

extern "C" void APIENTRY glBegin(GLenum mode) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->beginImmediate(mode);
}

extern "C" void APIENTRY glEnd(void) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->endImmediate();
}

// ── Display lists ───────────────────────────────────────────────────

extern "C" void APIENTRY glNewList(GLuint list, GLenum mode) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->newListCompat(list, mode);
}

extern "C" void APIENTRY glEndList(void) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->endListCompat();
}

extern "C" void APIENTRY glCallList(GLuint list) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->callListCompat(list);
}

extern "C" void APIENTRY glCallLists(GLsizei n, GLenum type, const void* lists) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->callListsCompat(n, type, lists);
}

extern "C" void APIENTRY glDeleteLists(GLuint list, GLsizei range) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->deleteListsCompat(list, range);
}

extern "C" GLuint APIENTRY glGenLists(GLsizei range) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return 0;
    }
    return ctx->genListsCompat(range);
}

extern "C" GLboolean APIENTRY glIsList(GLuint list) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return GL_FALSE;
    }
    return ctx->isListCompat(list);
}

extern "C" void APIENTRY glListBase(GLuint base) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->listBaseCompat(base);
}

extern "C" void APIENTRY glShadeModel(GLenum mode) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setShadeModel(mode);
}

extern "C" void APIENTRY glPushAttrib(GLbitfield mask) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->pushAttribCompat(mask);
}

extern "C" void APIENTRY glPopAttrib(void) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->popAttribCompat();
}

extern "C" void APIENTRY glLineStipple(GLint factor, GLushort pattern) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setLineStipple(factor, pattern);
}

// ── Fixed-function material state ───────────────────────────────────

extern "C" void APIENTRY glColorMaterial(GLenum face, GLenum mode) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setColorMaterialCompat(face, mode);
}

extern "C" void APIENTRY glMaterialfv(GLenum face, GLenum pname, const GLfloat* params) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setMaterialFloatCompat(face, pname, params);
}

extern "C" void APIENTRY glMaterialf(GLenum face, GLenum pname, GLfloat param) {
    glMaterialfv(face, pname, &param);
}

extern "C" void APIENTRY glMaterialiv(GLenum face, GLenum pname, const GLint* params) {
    if (params == nullptr) {
        return;
    }
    const GLfloat converted[4] = {
        static_cast<GLfloat>(params[0]),
        static_cast<GLfloat>(params[1]),
        static_cast<GLfloat>(params[2]),
        static_cast<GLfloat>(params[3]),
    };
    glMaterialfv(face, pname, converted);
}

extern "C" void APIENTRY glMateriali(GLenum face, GLenum pname, GLint param) {
    const GLint values[4] = {param, param, param, param};
    glMaterialiv(face, pname, values);
}

extern "C" void APIENTRY glGetMaterialfv(GLenum face, GLenum pname, GLfloat* params) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->getMaterialFloatCompat(face, pname, params);
}

extern "C" void APIENTRY glGetMaterialiv(GLenum face, GLenum pname, GLint* params) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->getMaterialIntegerCompat(face, pname, params);
}

// ── Fixed-function fog state ────────────────────────────────────────

extern "C" void APIENTRY glFogf(GLenum pname, GLfloat param) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setFogFloat(pname, param);
}

extern "C" void APIENTRY glFogfv(GLenum pname, const GLfloat* params) {
    if (params == nullptr) {
        return;
    }
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setFogFloatVector(pname, params);
}

extern "C" void APIENTRY glFogi(GLenum pname, GLint param) {
    glFogf(pname, static_cast<GLfloat>(param));
}

extern "C" void APIENTRY glFogiv(GLenum pname, const GLint* params) {
    if (params == nullptr) {
        return;
    }
    if (pname != GL_FOG_COLOR) {
        glFogi(pname, params[0]);
        return;
    }
    const GLfloat converted[4] = {
        static_cast<GLfloat>(params[0]),
        static_cast<GLfloat>(params[1]),
        static_cast<GLfloat>(params[2]),
        static_cast<GLfloat>(params[3]),
    };
    glFogfv(pname, converted);
}

// ── GL_SELECT / name stack ──────────────────────────────────────────

extern "C" void APIENTRY glSelectBuffer(GLsizei size, GLuint* buffer) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->selectBufferCompat(size, buffer);
}

extern "C" GLint APIENTRY glRenderMode(GLenum mode) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return 0;
    }
    return ctx->renderModeCompat(mode);
}

extern "C" void APIENTRY glInitNames(void) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->initNamesCompat();
}

extern "C" void APIENTRY glPushName(GLuint name) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->pushNameCompat(name);
}

extern "C" void APIENTRY glPopName(void) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->popNameCompat();
}

extern "C" void APIENTRY glLoadName(GLuint name) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->loadNameCompat(name);
}

extern "C" void APIENTRY glVertexPointer(GLint size,
                                         GLenum type,
                                         GLsizei stride,
                                         const void* pointer) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    (void)ctx->setLegacyClientArrayPointer(GL_VERTEX_ARRAY, size, type, stride, pointer);
}

extern "C" void APIENTRY glColorPointer(GLint size,
                                        GLenum type,
                                        GLsizei stride,
                                        const void* pointer) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    (void)ctx->setLegacyClientArrayPointer(GL_COLOR_ARRAY, size, type, stride, pointer);
}

extern "C" void APIENTRY glTexCoordPointer(GLint size,
                                           GLenum type,
                                           GLsizei stride,
                                           const void* pointer) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    (void)ctx->setLegacyClientArrayPointer(GL_TEXTURE_COORD_ARRAY, size, type, stride, pointer);
}

extern "C" void APIENTRY glEnableClientState(GLenum array) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    (void)ctx->setLegacyClientArrayEnabled(array, true);
}

extern "C" void APIENTRY glDisableClientState(GLenum array) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    (void)ctx->setLegacyClientArrayEnabled(array, false);
}

// ── Raster pixel position / copy ─────────────────────────────────────

extern "C" void APIENTRY glRasterPos2d(GLdouble x, GLdouble y) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setRasterPosition(static_cast<float>(x),
                           static_cast<float>(y),
                           0.0f,
                           1.0f);
}

extern "C" void APIENTRY glRasterPos2dv(const GLdouble* v) {
    if (v == nullptr) {
        return;
    }
    glRasterPos2d(v[0], v[1]);
}

extern "C" void APIENTRY glRasterPos2f(GLfloat x, GLfloat y) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setRasterPosition(x, y, 0.0f, 1.0f);
}

extern "C" void APIENTRY glRasterPos2fv(const GLfloat* v) {
    if (v == nullptr) {
        return;
    }
    glRasterPos2f(v[0], v[1]);
}

extern "C" void APIENTRY glRasterPos2i(GLint x, GLint y) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setRasterPosition(static_cast<float>(x),
                           static_cast<float>(y),
                           0.0f,
                           1.0f);
}

extern "C" void APIENTRY glRasterPos2iv(const GLint* v) {
    if (v == nullptr) {
        return;
    }
    glRasterPos2i(v[0], v[1]);
}

extern "C" void APIENTRY glRasterPos2s(GLshort x, GLshort y) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setRasterPosition(static_cast<float>(x),
                           static_cast<float>(y),
                           0.0f,
                           1.0f);
}

extern "C" void APIENTRY glRasterPos2sv(const GLshort* v) {
    if (v == nullptr) {
        return;
    }
    glRasterPos2s(v[0], v[1]);
}

extern "C" void APIENTRY glRasterPos3d(GLdouble x, GLdouble y, GLdouble z) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setRasterPosition(static_cast<float>(x),
                           static_cast<float>(y),
                           static_cast<float>(z),
                           1.0f);
}

extern "C" void APIENTRY glRasterPos3dv(const GLdouble* v) {
    if (v == nullptr) {
        return;
    }
    glRasterPos3d(v[0], v[1], v[2]);
}

extern "C" void APIENTRY glRasterPos3f(GLfloat x, GLfloat y, GLfloat z) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setRasterPosition(x, y, z, 1.0f);
}

extern "C" void APIENTRY glRasterPos3fv(const GLfloat* v) {
    if (v == nullptr) {
        return;
    }
    glRasterPos3f(v[0], v[1], v[2]);
}

extern "C" void APIENTRY glRasterPos3i(GLint x, GLint y, GLint z) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setRasterPosition(static_cast<float>(x),
                           static_cast<float>(y),
                           static_cast<float>(z),
                           1.0f);
}

extern "C" void APIENTRY glRasterPos3iv(const GLint* v) {
    if (v == nullptr) {
        return;
    }
    glRasterPos3i(v[0], v[1], v[2]);
}

extern "C" void APIENTRY glRasterPos3s(GLshort x, GLshort y, GLshort z) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setRasterPosition(static_cast<float>(x),
                           static_cast<float>(y),
                           static_cast<float>(z),
                           1.0f);
}

extern "C" void APIENTRY glRasterPos3sv(const GLshort* v) {
    if (v == nullptr) {
        return;
    }
    glRasterPos3s(v[0], v[1], v[2]);
}

extern "C" void APIENTRY glRasterPos4d(GLdouble x, GLdouble y, GLdouble z, GLdouble w) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setRasterPosition(static_cast<float>(x),
                           static_cast<float>(y),
                           static_cast<float>(z),
                           static_cast<float>(w));
}

extern "C" void APIENTRY glRasterPos4dv(const GLdouble* v) {
    if (v == nullptr) {
        return;
    }
    glRasterPos4d(v[0], v[1], v[2], v[3]);
}

extern "C" void APIENTRY glRasterPos4f(GLfloat x, GLfloat y, GLfloat z, GLfloat w) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setRasterPosition(x, y, z, w);
}

extern "C" void APIENTRY glRasterPos4fv(const GLfloat* v) {
    if (v == nullptr) {
        return;
    }
    glRasterPos4f(v[0], v[1], v[2], v[3]);
}

extern "C" void APIENTRY glRasterPos4i(GLint x, GLint y, GLint z, GLint w) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setRasterPosition(static_cast<float>(x),
                           static_cast<float>(y),
                           static_cast<float>(z),
                           static_cast<float>(w));
}

extern "C" void APIENTRY glRasterPos4iv(const GLint* v) {
    if (v == nullptr) {
        return;
    }
    glRasterPos4i(v[0], v[1], v[2], v[3]);
}

extern "C" void APIENTRY glRasterPos4s(GLshort x, GLshort y, GLshort z, GLshort w) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setRasterPosition(static_cast<float>(x),
                           static_cast<float>(y),
                           static_cast<float>(z),
                           static_cast<float>(w));
}

extern "C" void APIENTRY glRasterPos4sv(const GLshort* v) {
    if (v == nullptr) {
        return;
    }
    glRasterPos4s(v[0], v[1], v[2], v[3]);
}

extern "C" void APIENTRY glWindowPos2i(GLint x, GLint y) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setWindowRasterPosition(static_cast<GLfloat>(x),
                                 static_cast<GLfloat>(y));
}

extern "C" void APIENTRY glWindowPos2iv(const GLint* v) {
    if (v == nullptr) {
        return;
    }
    glWindowPos2i(v[0], v[1]);
}

extern "C" void APIENTRY glWindowPos2f(GLfloat x, GLfloat y) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setWindowRasterPosition(x, y);
}

extern "C" void APIENTRY glWindowPos2fv(const GLfloat* v) {
    if (v == nullptr) {
        return;
    }
    glWindowPos2f(v[0], v[1]);
}

extern "C" void APIENTRY glWindowPos2d(GLdouble x, GLdouble y) {
    glWindowPos2f(static_cast<GLfloat>(x), static_cast<GLfloat>(y));
}

extern "C" void APIENTRY glWindowPos2dv(const GLdouble* v) {
    if (v == nullptr) {
        return;
    }
    glWindowPos2d(v[0], v[1]);
}

extern "C" void APIENTRY glWindowPos2s(GLshort x, GLshort y) {
    glWindowPos2i(x, y);
}

extern "C" void APIENTRY glWindowPos2sv(const GLshort* v) {
    if (v == nullptr) {
        return;
    }
    glWindowPos2s(v[0], v[1]);
}

extern "C" void APIENTRY glWindowPos3f(GLfloat x, GLfloat y, GLfloat z) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setWindowRasterPosition(x, y, z);
}

extern "C" void APIENTRY glWindowPos3fv(const GLfloat* v) {
    if (v == nullptr) {
        return;
    }
    glWindowPos3f(v[0], v[1], v[2]);
}

extern "C" void APIENTRY glWindowPos3d(GLdouble x, GLdouble y, GLdouble z) {
    glWindowPos3f(static_cast<GLfloat>(x),
                  static_cast<GLfloat>(y),
                  static_cast<GLfloat>(z));
}

extern "C" void APIENTRY glWindowPos3dv(const GLdouble* v) {
    if (v == nullptr) {
        return;
    }
    glWindowPos3d(v[0], v[1], v[2]);
}

extern "C" void APIENTRY glWindowPos3i(GLint x, GLint y, GLint z) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setWindowRasterPosition(static_cast<GLfloat>(x),
                                 static_cast<GLfloat>(y),
                                 static_cast<GLfloat>(z));
}

extern "C" void APIENTRY glWindowPos3iv(const GLint* v) {
    if (v == nullptr) {
        return;
    }
    glWindowPos3i(v[0], v[1], v[2]);
}

extern "C" void APIENTRY glWindowPos3s(GLshort x, GLshort y, GLshort z) {
    glWindowPos3i(x, y, z);
}

extern "C" void APIENTRY glWindowPos3sv(const GLshort* v) {
    if (v == nullptr) {
        return;
    }
    glWindowPos3s(v[0], v[1], v[2]);
}

extern "C" void APIENTRY glCopyPixels(GLint x,
                                      GLint y,
                                      GLsizei width,
                                      GLsizei height,
                                      GLenum type) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    (void)ctx->copyPixelsCompat(x, y, width, height, type);
}

extern "C" void APIENTRY glClearAccum(GLfloat red,
                                      GLfloat green,
                                      GLfloat blue,
                                      GLfloat alpha) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setAccumClearCompat(red, green, blue, alpha);
}

extern "C" void APIENTRY glAccum(GLenum op, GLfloat value) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    (void)ctx->accumCompat(op, value);
}

extern "C" void APIENTRY glDrawPixels(GLsizei width,
                                      GLsizei height,
                                      GLenum format,
                                      GLenum type,
                                      const void* pixels) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    (void)ctx->drawPixelsCompat(width, height, format, type, pixels);
}

extern "C" void APIENTRY glPixelMapfv(GLenum map,
                                      GLsizei mapsize,
                                      const GLfloat* values) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    (void)ctx->pixelMapCompat(map, mapsize, values);
}

extern "C" void APIENTRY glPixelMapuiv(GLenum map,
                                       GLsizei mapsize,
                                       const GLuint* values) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || mapsize < 0 || values == nullptr) {
        return;
    }
    std::vector<GLfloat> converted(static_cast<std::size_t>(mapsize));
    for (GLsizei i = 0; i < mapsize; ++i) {
        converted[static_cast<std::size_t>(i)] = static_cast<GLfloat>(values[i]);
    }
    (void)ctx->pixelMapCompat(map, mapsize, converted.data());
}

extern "C" void APIENTRY glPixelMapusv(GLenum map,
                                       GLsizei mapsize,
                                       const GLushort* values) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || mapsize < 0 || values == nullptr) {
        return;
    }
    std::vector<GLfloat> converted(static_cast<std::size_t>(mapsize));
    for (GLsizei i = 0; i < mapsize; ++i) {
        converted[static_cast<std::size_t>(i)] = static_cast<GLfloat>(values[i]);
    }
    (void)ctx->pixelMapCompat(map, mapsize, converted.data());
}

extern "C" void APIENTRY glPixelTransferf(GLenum pname, GLfloat param) {
    if (!appgl::appglCompatProfileEnabled()) {
        appgl::Runtime::shared().recordFixedFunctionStub("glPixelTransferf");
        return;
    }
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    (void)ctx->pixelTransferCompat(pname, param);
}

extern "C" void APIENTRY glPixelTransferi(GLenum pname, GLint param) {
    if (!appgl::appglCompatProfileEnabled()) {
        appgl::Runtime::shared().recordFixedFunctionStub("glPixelTransferi");
        return;
    }
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    (void)ctx->pixelTransferCompat(pname, static_cast<GLfloat>(param));
}

extern "C" void APIENTRY glClipPlane(GLenum plane, const GLdouble* equation) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setClipPlaneCompat(plane, equation);
}

extern "C" void APIENTRY glNormal3f(GLfloat x, GLfloat y, GLfloat z) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setNormalCompat(x, y, z);
}

extern "C" void APIENTRY glNormal3fv(const GLfloat* v) {
    if (v == nullptr) {
        return;
    }
    glNormal3f(v[0], v[1], v[2]);
}

extern "C" void APIENTRY glNormal3d(GLdouble x, GLdouble y, GLdouble z) {
    glNormal3f(static_cast<GLfloat>(x),
               static_cast<GLfloat>(y),
               static_cast<GLfloat>(z));
}

extern "C" void APIENTRY glNormal3dv(const GLdouble* v) {
    if (v == nullptr) {
        return;
    }
    glNormal3d(v[0], v[1], v[2]);
}

extern "C" void APIENTRY glNormal3i(GLint x, GLint y, GLint z) {
    glNormal3f(static_cast<GLfloat>(x),
               static_cast<GLfloat>(y),
               static_cast<GLfloat>(z));
}

extern "C" void APIENTRY glNormal3iv(const GLint* v) {
    if (v == nullptr) {
        return;
    }
    glNormal3i(v[0], v[1], v[2]);
}

extern "C" void APIENTRY glNormal3s(GLshort x, GLshort y, GLshort z) {
    glNormal3f(static_cast<GLfloat>(x),
               static_cast<GLfloat>(y),
               static_cast<GLfloat>(z));
}

extern "C" void APIENTRY glNormal3sv(const GLshort* v) {
    if (v == nullptr) {
        return;
    }
    glNormal3s(v[0], v[1], v[2]);
}

extern "C" void APIENTRY glNormal3b(GLbyte x, GLbyte y, GLbyte z) {
    glNormal3f(static_cast<GLfloat>(x),
               static_cast<GLfloat>(y),
               static_cast<GLfloat>(z));
}

extern "C" void APIENTRY glNormal3bv(const GLbyte* v) {
    if (v == nullptr) {
        return;
    }
    glNormal3b(v[0], v[1], v[2]);
}

extern "C" void APIENTRY glLightfv(GLenum light, GLenum pname, const GLfloat* params) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setLightFloatCompat(light, pname, params);
}

extern "C" void APIENTRY glLightf(GLenum light, GLenum pname, GLfloat param) {
    const GLfloat values[4] = {param, param, param, param};
    glLightfv(light, pname, values);
}

extern "C" void APIENTRY glLightiv(GLenum light, GLenum pname, const GLint* params) {
    if (params == nullptr) {
        return;
    }
    if (pname != GL_AMBIENT &&
        pname != GL_DIFFUSE &&
        pname != GL_SPECULAR &&
        pname != GL_POSITION &&
        pname != GL_SPOT_DIRECTION) {
        const GLfloat value = static_cast<GLfloat>(params[0]);
        glLightfv(light, pname, &value);
        return;
    }
    const GLfloat values[4] = {
        static_cast<GLfloat>(params[0]),
        static_cast<GLfloat>(params[1]),
        static_cast<GLfloat>(params[2]),
        static_cast<GLfloat>(params[3]),
    };
    glLightfv(light, pname, values);
}

extern "C" void APIENTRY glLighti(GLenum light, GLenum pname, GLint param) {
    const GLfloat values[4] = {
        static_cast<GLfloat>(param),
        static_cast<GLfloat>(param),
        static_cast<GLfloat>(param),
        static_cast<GLfloat>(param),
    };
    glLightfv(light, pname, values);
}

extern "C" void APIENTRY glTexEnvfv(GLenum target, GLenum pname, const GLfloat* params) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setTexEnvFloatCompat(target, pname, params);
}

extern "C" void APIENTRY glTexEnvf(GLenum target, GLenum pname, GLfloat param) {
    const GLfloat values[4] = {param, param, param, param};
    glTexEnvfv(target, pname, values);
}

extern "C" void APIENTRY glTexEnviv(GLenum target, GLenum pname, const GLint* params) {
    if (params == nullptr) {
        return;
    }
    if (pname != GL_TEXTURE_ENV_COLOR) {
        const GLfloat value = static_cast<GLfloat>(params[0]);
        glTexEnvfv(target, pname, &value);
        return;
    }
    const GLfloat values[4] = {
        static_cast<GLfloat>(params[0]),
        static_cast<GLfloat>(params[1]),
        static_cast<GLfloat>(params[2]),
        static_cast<GLfloat>(params[3]),
    };
    glTexEnvfv(target, pname, values);
}

extern "C" void APIENTRY glTexEnvi(GLenum target, GLenum pname, GLint param) {
    const GLfloat values[4] = {
        static_cast<GLfloat>(param),
        static_cast<GLfloat>(param),
        static_cast<GLfloat>(param),
        static_cast<GLfloat>(param),
    };
    glTexEnvfv(target, pname, values);
}

extern "C" void APIENTRY glTexGenfv(GLenum coord, GLenum pname, const GLfloat* params) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setTexGenFloatCompat(coord, pname, params);
}

extern "C" void APIENTRY glTexGenf(GLenum coord, GLenum pname, GLfloat param) {
    const GLfloat values[4] = {param, param, param, param};
    glTexGenfv(coord, pname, values);
}

extern "C" void APIENTRY glTexGendv(GLenum coord, GLenum pname, const GLdouble* params) {
    if (params == nullptr) {
        return;
    }
    if (pname == GL_TEXTURE_GEN_MODE) {
        const GLfloat value = static_cast<GLfloat>(params[0]);
        glTexGenfv(coord, pname, &value);
        return;
    }
    const GLfloat values[4] = {
        static_cast<GLfloat>(params[0]),
        static_cast<GLfloat>(params[1]),
        static_cast<GLfloat>(params[2]),
        static_cast<GLfloat>(params[3]),
    };
    glTexGenfv(coord, pname, values);
}

extern "C" void APIENTRY glTexGend(GLenum coord, GLenum pname, GLdouble param) {
    const GLfloat values[4] = {
        static_cast<GLfloat>(param),
        static_cast<GLfloat>(param),
        static_cast<GLfloat>(param),
        static_cast<GLfloat>(param),
    };
    glTexGenfv(coord, pname, values);
}

extern "C" void APIENTRY glTexGeniv(GLenum coord, GLenum pname, const GLint* params) {
    if (params == nullptr) {
        return;
    }
    if (pname == GL_TEXTURE_GEN_MODE) {
        const GLfloat value = static_cast<GLfloat>(params[0]);
        glTexGenfv(coord, pname, &value);
        return;
    }
    const GLfloat values[4] = {
        static_cast<GLfloat>(params[0]),
        static_cast<GLfloat>(params[1]),
        static_cast<GLfloat>(params[2]),
        static_cast<GLfloat>(params[3]),
    };
    glTexGenfv(coord, pname, values);
}

extern "C" void APIENTRY glTexGeni(GLenum coord, GLenum pname, GLint param) {
    const GLfloat values[4] = {
        static_cast<GLfloat>(param),
        static_cast<GLfloat>(param),
        static_cast<GLfloat>(param),
        static_cast<GLfloat>(param),
    };
    glTexGenfv(coord, pname, values);
}

// ── glVertex* ────────────────────────────────────────────────────────

extern "C" void APIENTRY glVertex2f(GLfloat x, GLfloat y) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->immediateVertex(x, y, 0.0f, 1.0f);
}

extern "C" void APIENTRY glVertex2fv(const GLfloat* v) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || v == nullptr) {
        return;
    }
    ctx->immediateVertex(v[0], v[1], 0.0f, 1.0f);
}

extern "C" void APIENTRY glVertex3f(GLfloat x, GLfloat y, GLfloat z) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->immediateVertex(x, y, z, 1.0f);
}

extern "C" void APIENTRY glVertex3fv(const GLfloat* v) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || v == nullptr) {
        return;
    }
    ctx->immediateVertex(v[0], v[1], v[2], 1.0f);
}

extern "C" void APIENTRY glVertex4f(GLfloat x, GLfloat y, GLfloat z, GLfloat w) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->immediateVertex(x, y, z, w);
}

extern "C" void APIENTRY glVertex4fv(const GLfloat* v) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || v == nullptr) {
        return;
    }
    ctx->immediateVertex(v[0], v[1], v[2], v[3]);
}

// ── glColor* ─────────────────────────────────────────────────────────

extern "C" void APIENTRY glColor3f(GLfloat r, GLfloat g, GLfloat b) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->immediateColor(r, g, b, 1.0f);
}

extern "C" void APIENTRY glColor3fv(const GLfloat* v) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || v == nullptr) {
        return;
    }
    ctx->immediateColor(v[0], v[1], v[2], 1.0f);
}

extern "C" void APIENTRY glColor4f(GLfloat r, GLfloat g, GLfloat b, GLfloat a) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->immediateColor(r, g, b, a);
}

extern "C" void APIENTRY glColor4fv(const GLfloat* v) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || v == nullptr) {
        return;
    }
    ctx->immediateColor(v[0], v[1], v[2], v[3]);
}

extern "C" void APIENTRY glSecondaryColor3f(GLfloat red, GLfloat green, GLfloat blue) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setSecondaryColorCompat(red, green, blue);
}

extern "C" void APIENTRY glSecondaryColor3fv(const GLfloat* v) {
    if (v == nullptr) {
        return;
    }
    glSecondaryColor3f(v[0], v[1], v[2]);
}

// glColor3ub / glColor4ub — 0..255 byte channels, normalized to 0..1.
// The 1/255 constant is computed at compile time.
extern "C" void APIENTRY glColor3ub(GLubyte r, GLubyte g, GLubyte b) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    constexpr float kInv = 1.0f / 255.0f;
    ctx->immediateColor(r * kInv, g * kInv, b * kInv, 1.0f);
}

extern "C" void APIENTRY glColor3ubv(const GLubyte* v) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || v == nullptr) {
        return;
    }
    constexpr float kInv = 1.0f / 255.0f;
    ctx->immediateColor(v[0] * kInv, v[1] * kInv, v[2] * kInv, 1.0f);
}

extern "C" void APIENTRY glColor4ub(GLubyte r, GLubyte g, GLubyte b, GLubyte a) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    constexpr float kInv = 1.0f / 255.0f;
    ctx->immediateColor(r * kInv, g * kInv, b * kInv, a * kInv);
}

extern "C" void APIENTRY glColor4ubv(const GLubyte* v) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || v == nullptr) {
        return;
    }
    constexpr float kInv = 1.0f / 255.0f;
    ctx->immediateColor(v[0] * kInv, v[1] * kInv, v[2] * kInv, v[3] * kInv);
}

// ── glTexCoord* (single-unit convenience — routes to unit 0) ─────────

extern "C" void APIENTRY glTexCoord2f(GLfloat s, GLfloat t) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->immediateTexCoord(0u, s, t, 0.0f, 1.0f);
}

extern "C" void APIENTRY glTexCoord2fv(const GLfloat* v) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || v == nullptr) {
        return;
    }
    ctx->immediateTexCoord(0u, v[0], v[1], 0.0f, 1.0f);
}

extern "C" void APIENTRY glTexCoord3f(GLfloat s, GLfloat t, GLfloat r) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->immediateTexCoord(0u, s, t, r, 1.0f);
}

extern "C" void APIENTRY glTexCoord3fv(const GLfloat* v) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || v == nullptr) {
        return;
    }
    ctx->immediateTexCoord(0u, v[0], v[1], v[2], 1.0f);
}

extern "C" void APIENTRY glTexCoord4f(GLfloat s, GLfloat t, GLfloat r, GLfloat q) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->immediateTexCoord(0u, s, t, r, q);
}

extern "C" void APIENTRY glTexCoord4fv(const GLfloat* v) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || v == nullptr) {
        return;
    }
    ctx->immediateTexCoord(0u, v[0], v[1], v[2], v[3]);
}

// ── glMultiTexCoord* (explicit-unit form) ────────────────────────────

namespace {

// GL_TEXTURE0..GL_TEXTURE31 → 0..31. Values outside that range are
// silently dropped — the capture state only tracks unit 0 anyway, so
// anything else is already a no-op; we still validate the enum to
// keep diagnostic logs clean.
unsigned int multiTextureUnitIndex(GLenum target) {
    if (target < GL_TEXTURE0 || target > GL_TEXTURE0 + 31u) {
        return 32u;  // sentinel → GLContext::immediateTexCoord ignores non-zero
    }
    return static_cast<unsigned int>(target - GL_TEXTURE0);
}

}  // namespace

extern "C" void APIENTRY glMultiTexCoord2f(GLenum target, GLfloat s, GLfloat t) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->immediateTexCoord(multiTextureUnitIndex(target), s, t, 0.0f, 1.0f);
}

extern "C" void APIENTRY glMultiTexCoord2fv(GLenum target, const GLfloat* v) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || v == nullptr) {
        return;
    }
    ctx->immediateTexCoord(multiTextureUnitIndex(target), v[0], v[1], 0.0f, 1.0f);
}

extern "C" void APIENTRY glMultiTexCoord3f(GLenum target, GLfloat s, GLfloat t, GLfloat r) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->immediateTexCoord(multiTextureUnitIndex(target), s, t, r, 1.0f);
}

extern "C" void APIENTRY glMultiTexCoord3fv(GLenum target, const GLfloat* v) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || v == nullptr) {
        return;
    }
    ctx->immediateTexCoord(multiTextureUnitIndex(target), v[0], v[1], v[2], 1.0f);
}

extern "C" void APIENTRY glMultiTexCoord4f(GLenum target, GLfloat s, GLfloat t, GLfloat r, GLfloat q) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->immediateTexCoord(multiTextureUnitIndex(target), s, t, r, q);
}

extern "C" void APIENTRY glMultiTexCoord4fv(GLenum target, const GLfloat* v) {
    auto* ctx = immediateContext();
    if (ctx == nullptr || v == nullptr) {
        return;
    }
    ctx->immediateTexCoord(multiTextureUnitIndex(target), v[0], v[1], v[2], v[3]);
}

// ── glLightModel* ────────────────────────────────────────────────────

extern "C" void APIENTRY glLightModelfv(GLenum pname, const GLfloat* params) {
    auto* ctx = immediateContext();
    if (ctx == nullptr) {
        return;
    }
    ctx->setLightModelFloatCompat(pname, params);
}

extern "C" void APIENTRY glLightModelf(GLenum pname, GLfloat param) {
    const GLfloat values[4] = {param, param, param, param};
    glLightModelfv(pname, values);
}

extern "C" void APIENTRY glLightModeliv(GLenum pname, const GLint* params) {
    if (params == nullptr) {
        return;
    }
    if (pname == GL_LIGHT_MODEL_TWO_SIDE) {
        const GLfloat value = static_cast<GLfloat>(params[0]);
        glLightModelfv(pname, &value);
        return;
    }
    const GLfloat values[4] = {
        static_cast<GLfloat>(params[0]),
        static_cast<GLfloat>(params[1]),
        static_cast<GLfloat>(params[2]),
        static_cast<GLfloat>(params[3]),
    };
    glLightModelfv(pname, values);
}

extern "C" void APIENTRY glLightModeli(GLenum pname, GLint param) {
    const GLfloat value = static_cast<GLfloat>(param);
    glLightModelfv(pname, &value);
}
