#pragma once

#include <array>
#include <cstddef>
#include <vector>

#include "../../include/AppGL/glcorearb.h"

// glcorearb.h is the *core-profile* registry header — it omits the
// GL 1.x matrix-mode enums that the compat-profile mirror needs to
// switch between the modelview, projection, and texture stacks. The
// values come straight from gl.xml's `<enum value="0x1700" name="GL_MODELVIEW"/>`
// triplet. They're defined unconditionally here (with `#ifndef` guards
// in case a future runtime header pulls in compat enums) because the
// mirror cannot live without them and we'd rather keep the local
// definition self-contained than push the compat dependency outward.
#ifndef GL_MODELVIEW
#define GL_MODELVIEW 0x1700
#endif
#ifndef GL_PROJECTION
#define GL_PROJECTION 0x1701
#endif
#ifndef GL_TEXTURE
#define GL_TEXTURE 0x1702
#endif

namespace appgl {

// Per-context mirror of the GL fixed-function matrix stack. Compat-profile
// shaders reference `gl_ModelViewMatrix`, `gl_ProjectionMatrix`,
// `gl_ModelViewProjectionMatrix`, `gl_NormalMatrix`, and the corresponding
// inverse forms. Core-profile glslang refuses to compile those identifiers,
// so AppGL's compat-shader rewriter (`shader/CompatShaderRewrite.h`) replaces
// them with synthesized `appgl_*` uniforms whose values come from this
// mirror at draw time.
//
// All matrices are stored column-major (matches both OpenGL and Metal).
// The stack depth limits match the GL spec minimums (32 for modelview,
// 2 for projection, 16 per texture stack — we go 16 to be safe).
//
// The mirror is a pure state machine — it does NOT report GL errors.
// `setMatrixMode`, `pushMatrix`, and `popMatrix` return a bool so the
// caller (the corresponding `extern "C" APIENTRY` entry point in
// `runtime/AppGLMatrixOverrides.cpp`) can route GL_INVALID_ENUM /
// GL_STACK_OVERFLOW / GL_STACK_UNDERFLOW through the per-context
// glGetError queue and the runtime ring buffer in one shot via
// `GLContext::pushError`. Keeping the error reporting at the entry
// point means the mirror has no `Runtime::shared()` dependency and is
// trivially unit-testable in isolation.
//
// The mirror is intentionally minimal — it does not cover lighting, fog,
// or texcoord generation state. Those land in a follow-up landing once
// BAR's in-game render path needs them. For the current Phase 8X target
// (BAR's select-menu Icons2DVS shader) only the modelview/projection
// matrix combo is needed; the rest of the API is here for completeness
// so the next landing doesn't need a second runtime touch-up.

struct Matrix4 {
    std::array<float, 16> m{
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
    };

    static Matrix4 identity();
    static Matrix4 fromColumnMajor(const float* src);
    static Matrix4 fromColumnMajor(const double* src);
    // Transpose-input loaders for glLoadTransposeMatrix*.
    static Matrix4 fromRowMajor(const float* src);
    static Matrix4 fromRowMajor(const double* src);

    // Column-major matrix-matrix multiply (`out = a * b`, both 4x4).
    static Matrix4 multiply(const Matrix4& a, const Matrix4& b);
    // 4x4 inverse. Returns the inverse on success; returns an identity-marker
    // (with `singular = true`) when the input is non-invertible (det ~= 0).
    // BAR's compat shaders only ever feed in well-conditioned model/view
    // /projection matrices, so the singular path is conservative.
    Matrix4 inverse() const;

    // 3x3 normal matrix derived from the upper-left 3x3 of a modelview
    // matrix: `transpose(inverse(M))`. Stored as a Matrix4 with the
    // unused row/column zeroed; the synthesized GLSL uniform is declared
    // as `mat3` and SPIRV-Cross strips the padding when packing the
    // push-constant buffer.
    Matrix4 normalFromModelView() const;
};

class MatrixStateMirror {
public:
    // Default mode is GL_MODELVIEW (matches the GL spec — every context
    // starts with modelview as the active stack).
    MatrixStateMirror();

    // glMatrixMode(mode). Accepts GL_MODELVIEW, GL_PROJECTION, GL_TEXTURE.
    // Returns false (and leaves the active mode unchanged) when `mode` is
    // not one of the three accepted enums; the caller is expected to push a
    // GL_INVALID_ENUM via `GLContext::pushError` in that case. Texture
    // matrices follow the *currently active* texture unit set by
    // `setActiveTextureUnit` (which the runtime calls from `glActiveTexture`).
    bool setMatrixMode(GLenum mode);
    GLenum matrixMode() const;

    // Routed through from `glActiveTexture` so texture-matrix mode tracks
    // the right stack. Index 0 = GL_TEXTURE0.
    void setActiveTextureUnit(unsigned int unit);

    // glLoadIdentity, glLoadMatrix*, glMultMatrix*, push/pop.
    void loadIdentity();
    void loadMatrix(const float* m);     // column-major
    void loadMatrix(const double* m);    // column-major
    void loadTransposeMatrix(const float* m);
    void loadTransposeMatrix(const double* m);
    void multMatrix(const float* m);
    void multMatrix(const double* m);
    void multTransposeMatrix(const float* m);
    void multTransposeMatrix(const double* m);
    // Push/pop return false when they would breach the spec stack-depth
    // bounds (GL_STACK_OVERFLOW on push past the depth ceiling, or
    // GL_STACK_UNDERFLOW on pop of the implicit identity entry). The state
    // is left unchanged on a false return so the caller can synthesize the
    // GL error without worrying about a half-applied side effect.
    bool pushMatrix();
    bool popMatrix();

    // Affine helpers (translate / rotate / scale) and projection helpers
    // (ortho / frustum). All compose into the current top-of-stack via
    // post-multiply, matching the GL spec.
    void translate(double x, double y, double z);
    void rotate(double angleDeg, double x, double y, double z);
    void scale(double x, double y, double z);
    void ortho(double left, double right, double bottom, double top, double nearVal, double farVal);
    void frustum(double left, double right, double bottom, double top, double nearVal, double farVal);

    // Read accessors used by the draw path / compat-shader uniform push.
    // Inverse + MVP forms are computed on demand; nothing is cached, but
    // BAR's draw cadence (~1k draws/frame max) makes the cost trivial.
    Matrix4 modelView() const;
    Matrix4 projection() const;
    Matrix4 modelViewProjection() const;
    Matrix4 modelViewInverse() const;
    Matrix4 projectionInverse() const;
    Matrix4 modelViewProjectionInverse() const;
    Matrix4 normalMatrix() const;
    Matrix4 textureMatrix(unsigned int unit) const;

    // For diagnostic / introspection paths — depth of the active stack.
    std::size_t stackDepth() const;

    // Maximum number of texture matrix stacks tracked. Matches the GL
    // spec minimum of 2 but we provision 8 to cover BAR's worst case.
    static constexpr unsigned int kMaxTextureUnits = 8;

private:
    enum class StackKind { ModelView, Projection, Texture };

    struct Stack {
        std::vector<Matrix4> entries;
    };

    Stack& currentStack();
    const Stack& currentStack() const;
    StackKind currentStackKind() const;

    GLenum mode_ = GL_MODELVIEW;
    unsigned int activeTextureUnit_ = 0;
    Stack modelViewStack_;
    Stack projectionStack_;
    std::array<Stack, kMaxTextureUnits> textureStacks_;
};

}  // namespace appgl
