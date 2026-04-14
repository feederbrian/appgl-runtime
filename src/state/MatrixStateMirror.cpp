#include "MatrixStateMirror.h"

#include <cmath>
#include <cstring>

namespace appgl {

namespace {

// GL spec stack-depth minimums vs. what we provision. The spec floors are
// 32 modelview / 2 projection / 2 texture; we provision a touch above the
// floor on projection and a comfortable 16 on the texture stacks so BAR's
// in-game render path (which BAR's own engine logs hit ~6 deep on texture
// matrices) doesn't bump the ceiling.
constexpr std::size_t kMaxModelViewStackDepth = 32;
constexpr std::size_t kMaxProjectionStackDepth = 4;
constexpr std::size_t kMaxTextureStackDepth = 16;

inline std::size_t idx(std::size_t row, std::size_t col) {
    // Column-major: element (row, col) is at index col * 4 + row.
    return col * 4 + row;
}

Matrix4 makeTranslation(double x, double y, double z) {
    Matrix4 r = Matrix4::identity();
    r.m[idx(0, 3)] = static_cast<float>(x);
    r.m[idx(1, 3)] = static_cast<float>(y);
    r.m[idx(2, 3)] = static_cast<float>(z);
    return r;
}

Matrix4 makeScale(double x, double y, double z) {
    Matrix4 r = Matrix4::identity();
    r.m[idx(0, 0)] = static_cast<float>(x);
    r.m[idx(1, 1)] = static_cast<float>(y);
    r.m[idx(2, 2)] = static_cast<float>(z);
    return r;
}

Matrix4 makeRotation(double angleDeg, double x, double y, double z) {
    // Normalize axis. If the axis is degenerate (length ~0) GL says behavior
    // is undefined; we return identity, matching the safest no-op outcome.
    const double len = std::sqrt(x * x + y * y + z * z);
    if (len < 1e-9) {
        return Matrix4::identity();
    }
    const double nx = x / len;
    const double ny = y / len;
    const double nz = z / len;
    const double rad = angleDeg * (3.14159265358979323846 / 180.0);
    const double c = std::cos(rad);
    const double s = std::sin(rad);
    const double oc = 1.0 - c;

    Matrix4 r = Matrix4::identity();
    r.m[idx(0, 0)] = static_cast<float>(c + nx * nx * oc);
    r.m[idx(0, 1)] = static_cast<float>(nx * ny * oc - nz * s);
    r.m[idx(0, 2)] = static_cast<float>(nx * nz * oc + ny * s);
    r.m[idx(1, 0)] = static_cast<float>(ny * nx * oc + nz * s);
    r.m[idx(1, 1)] = static_cast<float>(c + ny * ny * oc);
    r.m[idx(1, 2)] = static_cast<float>(ny * nz * oc - nx * s);
    r.m[idx(2, 0)] = static_cast<float>(nz * nx * oc - ny * s);
    r.m[idx(2, 1)] = static_cast<float>(nz * ny * oc + nx * s);
    r.m[idx(2, 2)] = static_cast<float>(c + nz * nz * oc);
    return r;
}

Matrix4 makeOrtho(double l, double r, double b, double t, double n, double f) {
    // GL spec: glOrtho composes a column-major matrix with these entries.
    Matrix4 m = Matrix4::identity();
    m.m[idx(0, 0)] = static_cast<float>(2.0 / (r - l));
    m.m[idx(1, 1)] = static_cast<float>(2.0 / (t - b));
    m.m[idx(2, 2)] = static_cast<float>(-2.0 / (f - n));
    m.m[idx(0, 3)] = static_cast<float>(-(r + l) / (r - l));
    m.m[idx(1, 3)] = static_cast<float>(-(t + b) / (t - b));
    m.m[idx(2, 3)] = static_cast<float>(-(f + n) / (f - n));
    return m;
}

Matrix4 makeFrustum(double l, double r, double b, double t, double n, double f) {
    // GL spec: glFrustum builds a perspective-projection matrix.
    Matrix4 m;
    m.m.fill(0.0f);
    m.m[idx(0, 0)] = static_cast<float>(2.0 * n / (r - l));
    m.m[idx(1, 1)] = static_cast<float>(2.0 * n / (t - b));
    m.m[idx(0, 2)] = static_cast<float>((r + l) / (r - l));
    m.m[idx(1, 2)] = static_cast<float>((t + b) / (t - b));
    m.m[idx(2, 2)] = static_cast<float>(-(f + n) / (f - n));
    m.m[idx(2, 3)] = static_cast<float>(-(2.0 * f * n) / (f - n));
    m.m[idx(3, 2)] = -1.0f;
    return m;
}

}  // namespace

// ---------------------------------------------------------------------------
// Matrix4
// ---------------------------------------------------------------------------

Matrix4 Matrix4::identity() {
    return Matrix4{};
}

Matrix4 Matrix4::fromColumnMajor(const float* src) {
    Matrix4 r;
    if (src != nullptr) {
        std::memcpy(r.m.data(), src, sizeof(float) * 16);
    }
    return r;
}

Matrix4 Matrix4::fromColumnMajor(const double* src) {
    Matrix4 r;
    if (src != nullptr) {
        for (std::size_t i = 0; i < 16; ++i) {
            r.m[i] = static_cast<float>(src[i]);
        }
    }
    return r;
}

Matrix4 Matrix4::fromRowMajor(const float* src) {
    Matrix4 r;
    if (src != nullptr) {
        // Caller hands us row-major data; store column-major.
        for (std::size_t row = 0; row < 4; ++row) {
            for (std::size_t col = 0; col < 4; ++col) {
                r.m[idx(row, col)] = src[row * 4 + col];
            }
        }
    }
    return r;
}

Matrix4 Matrix4::fromRowMajor(const double* src) {
    Matrix4 r;
    if (src != nullptr) {
        for (std::size_t row = 0; row < 4; ++row) {
            for (std::size_t col = 0; col < 4; ++col) {
                r.m[idx(row, col)] = static_cast<float>(src[row * 4 + col]);
            }
        }
    }
    return r;
}

Matrix4 Matrix4::multiply(const Matrix4& a, const Matrix4& b) {
    Matrix4 out;
    for (std::size_t col = 0; col < 4; ++col) {
        for (std::size_t row = 0; row < 4; ++row) {
            float sum = 0.0f;
            for (std::size_t k = 0; k < 4; ++k) {
                sum += a.m[idx(row, k)] * b.m[idx(k, col)];
            }
            out.m[idx(row, col)] = sum;
        }
    }
    return out;
}

Matrix4 Matrix4::inverse() const {
    // 4x4 cofactor inversion. Operates on the column-major storage directly.
    // Source layout: m[col*4 + row]. We reuse the GLM/Mesa-style minor
    // expansion which is well-tested for affine + projection matrices.
    const float* a = m.data();
    float inv[16];

    inv[0] =  a[5]  * a[10] * a[15] - a[5]  * a[11] * a[14] -
              a[9]  * a[6]  * a[15] + a[9]  * a[7]  * a[14] +
              a[13] * a[6]  * a[11] - a[13] * a[7]  * a[10];
    inv[4] = -a[4]  * a[10] * a[15] + a[4]  * a[11] * a[14] +
              a[8]  * a[6]  * a[15] - a[8]  * a[7]  * a[14] -
              a[12] * a[6]  * a[11] + a[12] * a[7]  * a[10];
    inv[8] =  a[4]  * a[9]  * a[15] - a[4]  * a[11] * a[13] -
              a[8]  * a[5]  * a[15] + a[8]  * a[7]  * a[13] +
              a[12] * a[5]  * a[11] - a[12] * a[7]  * a[9];
    inv[12] = -a[4] * a[9]  * a[14] + a[4]  * a[10] * a[13] +
               a[8] * a[5]  * a[14] - a[8]  * a[6]  * a[13] -
               a[12] * a[5] * a[10] + a[12] * a[6]  * a[9];

    inv[1] = -a[1]  * a[10] * a[15] + a[1]  * a[11] * a[14] +
              a[9]  * a[2]  * a[15] - a[9]  * a[3]  * a[14] -
              a[13] * a[2]  * a[11] + a[13] * a[3]  * a[10];
    inv[5] =  a[0]  * a[10] * a[15] - a[0]  * a[11] * a[14] -
              a[8]  * a[2]  * a[15] + a[8]  * a[3]  * a[14] +
              a[12] * a[2]  * a[11] - a[12] * a[3]  * a[10];
    inv[9] = -a[0]  * a[9]  * a[15] + a[0]  * a[11] * a[13] +
              a[8]  * a[1]  * a[15] - a[8]  * a[3]  * a[13] -
              a[12] * a[1]  * a[11] + a[12] * a[3]  * a[9];
    inv[13] = a[0]  * a[9]  * a[14] - a[0]  * a[10] * a[13] -
              a[8]  * a[1]  * a[14] + a[8]  * a[2]  * a[13] +
              a[12] * a[1]  * a[10] - a[12] * a[2]  * a[9];

    inv[2] =  a[1]  * a[6]  * a[15] - a[1]  * a[7]  * a[14] -
              a[5]  * a[2]  * a[15] + a[5]  * a[3]  * a[14] +
              a[13] * a[2]  * a[7]  - a[13] * a[3]  * a[6];
    inv[6] = -a[0]  * a[6]  * a[15] + a[0]  * a[7]  * a[14] +
              a[4]  * a[2]  * a[15] - a[4]  * a[3]  * a[14] -
              a[12] * a[2]  * a[7]  + a[12] * a[3]  * a[6];
    inv[10] = a[0]  * a[5]  * a[15] - a[0]  * a[7]  * a[13] -
              a[4]  * a[1]  * a[15] + a[4]  * a[3]  * a[13] +
              a[12] * a[1]  * a[7]  - a[12] * a[3]  * a[5];
    inv[14] = -a[0] * a[5]  * a[14] + a[0]  * a[6]  * a[13] +
               a[4] * a[1]  * a[14] - a[4]  * a[2]  * a[13] -
               a[12] * a[1] * a[6]  + a[12] * a[2]  * a[5];

    inv[3] = -a[1]  * a[6]  * a[11] + a[1]  * a[7]  * a[10] +
              a[5]  * a[2]  * a[11] - a[5]  * a[3]  * a[10] -
              a[9]  * a[2]  * a[7]  + a[9]  * a[3]  * a[6];
    inv[7] =  a[0]  * a[6]  * a[11] - a[0]  * a[7]  * a[10] -
              a[4]  * a[2]  * a[11] + a[4]  * a[3]  * a[10] +
              a[8]  * a[2]  * a[7]  - a[8]  * a[3]  * a[6];
    inv[11] = -a[0] * a[5]  * a[11] + a[0]  * a[7]  * a[9] +
               a[4] * a[1]  * a[11] - a[4]  * a[3]  * a[9] -
               a[8] * a[1]  * a[7]  + a[8]  * a[3]  * a[5];
    inv[15] = a[0]  * a[5]  * a[10] - a[0]  * a[6]  * a[9] -
              a[4]  * a[1]  * a[10] + a[4]  * a[2]  * a[9] +
              a[8]  * a[1]  * a[6]  - a[8]  * a[2]  * a[5];

    const float det = a[0] * inv[0] + a[1] * inv[4] + a[2] * inv[8] + a[3] * inv[12];
    if (std::fabs(det) < 1e-20f) {
        // Singular — return identity. BAR's compat shaders never hand us
        // singular matrices in practice, so this path is purely defensive.
        return Matrix4::identity();
    }
    const float invDet = 1.0f / det;
    Matrix4 out;
    for (std::size_t i = 0; i < 16; ++i) {
        out.m[i] = inv[i] * invDet;
    }
    return out;
}

Matrix4 Matrix4::normalFromModelView() const {
    // Build the upper-left 3x3, invert + transpose, then store back into
    // a Matrix4 with the unused row/column zeroed. SPIRV-Cross's mat3
    // packing strips the padding when the synthesized uniform is declared
    // as `mat3 appgl_NormalMatrix`.
    //
    // We promote the 3x3 to a 4x4 by zeroing the translation column and
    // using the [3][3]=1 identity row, invert the 4x4, transpose, then
    // re-zero the unused row/column. Cheaper than writing a separate 3x3
    // inversion routine and produces identical results for affine
    // modelview matrices.
    Matrix4 padded = Matrix4::identity();
    padded.m[idx(0, 0)] = m[idx(0, 0)];
    padded.m[idx(0, 1)] = m[idx(0, 1)];
    padded.m[idx(0, 2)] = m[idx(0, 2)];
    padded.m[idx(1, 0)] = m[idx(1, 0)];
    padded.m[idx(1, 1)] = m[idx(1, 1)];
    padded.m[idx(1, 2)] = m[idx(1, 2)];
    padded.m[idx(2, 0)] = m[idx(2, 0)];
    padded.m[idx(2, 1)] = m[idx(2, 1)];
    padded.m[idx(2, 2)] = m[idx(2, 2)];

    Matrix4 inv = padded.inverse();

    Matrix4 out;
    out.m.fill(0.0f);
    // transpose: out(r,c) = inv(c,r)
    for (std::size_t row = 0; row < 3; ++row) {
        for (std::size_t col = 0; col < 3; ++col) {
            out.m[idx(row, col)] = inv.m[idx(col, row)];
        }
    }
    out.m[idx(3, 3)] = 1.0f;
    return out;
}

// ---------------------------------------------------------------------------
// MatrixStateMirror
// ---------------------------------------------------------------------------

MatrixStateMirror::MatrixStateMirror() {
    // Each stack starts with a single identity entry — matches the GL
    // spec: a freshly created context has the modelview, projection, and
    // texture stacks all containing one identity matrix.
    modelViewStack_.entries.push_back(Matrix4::identity());
    projectionStack_.entries.push_back(Matrix4::identity());
    for (auto& stack : textureStacks_) {
        stack.entries.push_back(Matrix4::identity());
    }
}

bool MatrixStateMirror::setMatrixMode(GLenum mode) {
    switch (mode) {
        case GL_MODELVIEW:
        case GL_PROJECTION:
        case GL_TEXTURE:
            mode_ = mode;
            return true;
        default:
            // Leave mode_ unchanged; caller pushes GL_INVALID_ENUM.
            return false;
    }
}

GLenum MatrixStateMirror::matrixMode() const {
    return mode_;
}

void MatrixStateMirror::setActiveTextureUnit(unsigned int unit) {
    if (unit >= kMaxTextureUnits) {
        // Clamp silently — the GL error for out-of-range glActiveTexture
        // is raised by the caller (glActiveTexture itself), not by the
        // matrix mirror. Clamping keeps the mirror from indexing OOB if
        // a caller forgets to validate first.
        unit = kMaxTextureUnits - 1;
    }
    activeTextureUnit_ = unit;
}

MatrixStateMirror::Stack& MatrixStateMirror::currentStack() {
    switch (mode_) {
        case GL_PROJECTION:
            return projectionStack_;
        case GL_TEXTURE:
            return textureStacks_[activeTextureUnit_];
        case GL_MODELVIEW:
        default:
            return modelViewStack_;
    }
}

const MatrixStateMirror::Stack& MatrixStateMirror::currentStack() const {
    switch (mode_) {
        case GL_PROJECTION:
            return projectionStack_;
        case GL_TEXTURE:
            return textureStacks_[activeTextureUnit_];
        case GL_MODELVIEW:
        default:
            return modelViewStack_;
    }
}

MatrixStateMirror::StackKind MatrixStateMirror::currentStackKind() const {
    switch (mode_) {
        case GL_PROJECTION:
            return StackKind::Projection;
        case GL_TEXTURE:
            return StackKind::Texture;
        case GL_MODELVIEW:
        default:
            return StackKind::ModelView;
    }
}

void MatrixStateMirror::loadIdentity() {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::identity());
    } else {
        stack.entries.back() = Matrix4::identity();
    }
}

void MatrixStateMirror::loadMatrix(const float* m) {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::fromColumnMajor(m));
    } else {
        stack.entries.back() = Matrix4::fromColumnMajor(m);
    }
}

void MatrixStateMirror::loadMatrix(const double* m) {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::fromColumnMajor(m));
    } else {
        stack.entries.back() = Matrix4::fromColumnMajor(m);
    }
}

void MatrixStateMirror::loadTransposeMatrix(const float* m) {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::fromRowMajor(m));
    } else {
        stack.entries.back() = Matrix4::fromRowMajor(m);
    }
}

void MatrixStateMirror::loadTransposeMatrix(const double* m) {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::fromRowMajor(m));
    } else {
        stack.entries.back() = Matrix4::fromRowMajor(m);
    }
}

void MatrixStateMirror::multMatrix(const float* m) {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::fromColumnMajor(m));
        return;
    }
    Matrix4 rhs = Matrix4::fromColumnMajor(m);
    stack.entries.back() = Matrix4::multiply(stack.entries.back(), rhs);
}

void MatrixStateMirror::multMatrix(const double* m) {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::fromColumnMajor(m));
        return;
    }
    Matrix4 rhs = Matrix4::fromColumnMajor(m);
    stack.entries.back() = Matrix4::multiply(stack.entries.back(), rhs);
}

void MatrixStateMirror::multTransposeMatrix(const float* m) {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::fromRowMajor(m));
        return;
    }
    Matrix4 rhs = Matrix4::fromRowMajor(m);
    stack.entries.back() = Matrix4::multiply(stack.entries.back(), rhs);
}

void MatrixStateMirror::multTransposeMatrix(const double* m) {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::fromRowMajor(m));
        return;
    }
    Matrix4 rhs = Matrix4::fromRowMajor(m);
    stack.entries.back() = Matrix4::multiply(stack.entries.back(), rhs);
}

bool MatrixStateMirror::pushMatrix() {
    Stack& stack = currentStack();
    std::size_t cap = 0;
    switch (currentStackKind()) {
        case StackKind::ModelView:
            cap = kMaxModelViewStackDepth;
            break;
        case StackKind::Projection:
            cap = kMaxProjectionStackDepth;
            break;
        case StackKind::Texture:
            cap = kMaxTextureStackDepth;
            break;
    }
    if (stack.entries.size() >= cap) {
        // Caller pushes GL_STACK_OVERFLOW; stack contents unchanged.
        return false;
    }
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::identity());
        return true;
    }
    stack.entries.push_back(stack.entries.back());
    return true;
}

bool MatrixStateMirror::popMatrix() {
    Stack& stack = currentStack();
    if (stack.entries.size() <= 1) {
        // Caller pushes GL_STACK_UNDERFLOW; stack contents unchanged.
        return false;
    }
    stack.entries.pop_back();
    return true;
}

void MatrixStateMirror::translate(double x, double y, double z) {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::identity());
    }
    stack.entries.back() =
        Matrix4::multiply(stack.entries.back(), makeTranslation(x, y, z));
}

void MatrixStateMirror::rotate(double angleDeg, double x, double y, double z) {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::identity());
    }
    stack.entries.back() =
        Matrix4::multiply(stack.entries.back(), makeRotation(angleDeg, x, y, z));
}

void MatrixStateMirror::scale(double x, double y, double z) {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::identity());
    }
    stack.entries.back() =
        Matrix4::multiply(stack.entries.back(), makeScale(x, y, z));
}

void MatrixStateMirror::ortho(double left, double right, double bottom, double top,
                              double nearVal, double farVal) {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::identity());
    }
    stack.entries.back() = Matrix4::multiply(
        stack.entries.back(), makeOrtho(left, right, bottom, top, nearVal, farVal));
}

void MatrixStateMirror::frustum(double left, double right, double bottom, double top,
                                double nearVal, double farVal) {
    Stack& stack = currentStack();
    if (stack.entries.empty()) {
        stack.entries.push_back(Matrix4::identity());
    }
    stack.entries.back() = Matrix4::multiply(
        stack.entries.back(), makeFrustum(left, right, bottom, top, nearVal, farVal));
}

Matrix4 MatrixStateMirror::modelView() const {
    if (modelViewStack_.entries.empty()) {
        return Matrix4::identity();
    }
    return modelViewStack_.entries.back();
}

Matrix4 MatrixStateMirror::projection() const {
    if (projectionStack_.entries.empty()) {
        return Matrix4::identity();
    }
    return projectionStack_.entries.back();
}

Matrix4 MatrixStateMirror::modelViewProjection() const {
    // Column-major: gl_Position = MVP * vertex == projection * (modelview * vertex).
    return Matrix4::multiply(projection(), modelView());
}

Matrix4 MatrixStateMirror::modelViewInverse() const {
    return modelView().inverse();
}

Matrix4 MatrixStateMirror::projectionInverse() const {
    return projection().inverse();
}

Matrix4 MatrixStateMirror::modelViewProjectionInverse() const {
    return modelViewProjection().inverse();
}

Matrix4 MatrixStateMirror::normalMatrix() const {
    return modelView().normalFromModelView();
}

Matrix4 MatrixStateMirror::textureMatrix(unsigned int unit) const {
    if (unit >= kMaxTextureUnits) {
        return Matrix4::identity();
    }
    const Stack& stack = textureStacks_[unit];
    if (stack.entries.empty()) {
        return Matrix4::identity();
    }
    return stack.entries.back();
}

std::size_t MatrixStateMirror::stackDepth() const {
    return currentStack().entries.size();
}

}  // namespace appgl
