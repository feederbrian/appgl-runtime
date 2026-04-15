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
#include "AppGLRuntime.h"

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

// ── glLightModel* (silent no-op — AppGL has no fixed-function lighting) ──

extern "C" void APIENTRY glLightModelf(GLenum /*pname*/, GLfloat /*param*/) {
    // BAR Chobby sets GL_LIGHT_MODEL_TWO_SIDE at compat init; nothing
    // downstream reads it. Accepting it as a no-op keeps the engine's
    // spec-violation log clean.
}

extern "C" void APIENTRY glLightModelfv(GLenum /*pname*/, const GLfloat* /*params*/) {
    // See glLightModelf.
}

extern "C" void APIENTRY glLightModeli(GLenum /*pname*/, GLint /*param*/) {
    // See glLightModelf.
}

extern "C" void APIENTRY glLightModeliv(GLenum /*pname*/, const GLint* /*params*/) {
    // See glLightModelf.
}
