// This file is textually included by GLContext.mm. Do not compile it directly.
// It contains GLContext immediate-mode method definitions split out for navigation only.

#if defined(APPGL_GLCONTEXT_IMMEDIATE_MODE)
// Phase 8X Group 4d follow-up¹⁷ — immediate-mode entry points.
//
// See the block comment in GLContext.h alongside the declarations for
// the rationale. These five methods form a small state machine that
// captures `{position, color, texcoord}` tuples between glBegin/glEnd
// and drains them to a built-in Metal pipeline on glEnd. State lives
// in `impl_->immediate`. `currentColor` / `currentTexcoord` are
// per-vertex registers updated by glColor*/glTexCoord* without
// emitting a vertex; only glVertex* pushes into the capture vector.

#ifndef GL_CLAMP
#define GL_CLAMP 0x2900
#endif

namespace {

constexpr std::uint32_t kAppGLImmediateTextureBaseAlpha = 1u;
constexpr std::uint32_t kAppGLImmediateTextureBaseLuminance = 2u;
constexpr std::uint32_t kAppGLImmediateTextureBaseLuminanceAlpha = 3u;
constexpr std::uint32_t kAppGLImmediateTextureBaseIntensity = 4u;

std::uint32_t appglImmediateTextureBaseClass(GLenum internalFormat) {
    switch (internalFormat) {
        case GL_ALPHA:
        case GL_ALPHA4:
        case GL_ALPHA8:
        case GL_ALPHA12:
        case GL_ALPHA16:
            return kAppGLImmediateTextureBaseAlpha;
        case GL_LUMINANCE:
        case GL_LUMINANCE4:
        case GL_LUMINANCE8:
        case GL_LUMINANCE12:
        case GL_LUMINANCE16:
        case GL_SLUMINANCE8:
            return kAppGLImmediateTextureBaseLuminance;
        case GL_LUMINANCE_ALPHA:
        case GL_LUMINANCE4_ALPHA4:
        case GL_LUMINANCE6_ALPHA2:
        case GL_LUMINANCE8_ALPHA8:
        case GL_LUMINANCE12_ALPHA4:
        case GL_LUMINANCE12_ALPHA12:
        case GL_LUMINANCE16_ALPHA16:
        case GL_SLUMINANCE8_ALPHA8:
            return kAppGLImmediateTextureBaseLuminanceAlpha;
        case GL_INTENSITY:
        case GL_INTENSITY4:
        case GL_INTENSITY8:
        case GL_INTENSITY12:
        case GL_INTENSITY16:
            return kAppGLImmediateTextureBaseIntensity;
        default:
            return 0u;
    }
}

GLfloat appglImmediateTextureComponent(
    const std::array<GLfloat, 4>& color,
    GLint component
) {
    switch (component) {
        case GL_RED: return color[0];
        case GL_GREEN: return color[1];
        case GL_BLUE: return color[2];
        case GL_ALPHA: return color[3];
        case GL_ZERO: return 0.0f;
        case GL_ONE: return 1.0f;
        default: return color[0];
    }
}

std::array<GLfloat, 4> appglImmediateBaseBorderColor(
    GLenum internalFormat,
    const std::array<GLfloat, 4>& border
) {
    switch (internalFormat) {
        case GL_ALPHA:
        case GL_ALPHA4:
        case GL_ALPHA8:
        case GL_ALPHA12:
        case GL_ALPHA16:
            return {0.0f, 0.0f, 0.0f, border[3]};
        case GL_LUMINANCE:
        case GL_LUMINANCE4:
        case GL_LUMINANCE8:
        case GL_LUMINANCE12:
        case GL_LUMINANCE16:
            return {border[0], border[0], border[0], 1.0f};
        case GL_LUMINANCE_ALPHA:
        case GL_LUMINANCE4_ALPHA4:
        case GL_LUMINANCE6_ALPHA2:
        case GL_LUMINANCE8_ALPHA8:
        case GL_LUMINANCE12_ALPHA4:
        case GL_LUMINANCE12_ALPHA12:
        case GL_LUMINANCE16_ALPHA16:
            return {border[0], border[0], border[0], border[3]};
        case GL_INTENSITY:
        case GL_INTENSITY4:
        case GL_INTENSITY8:
        case GL_INTENSITY12:
        case GL_INTENSITY16:
            return {border[0], border[0], border[0], border[0]};
        case GL_RED:
        case GL_R8:
        case GL_R16:
        case GL_R16F:
        case GL_R32F:
        case GL_R8_SNORM:
        case GL_R16_SNORM:
            return {border[0], 0.0f, 0.0f, 1.0f};
        case GL_RG:
        case GL_RG8:
        case GL_RG16:
        case GL_RG16F:
        case GL_RG32F:
        case GL_RG8_SNORM:
        case GL_RG16_SNORM:
            return {border[0], border[1], 0.0f, 1.0f};
        default:
            break;
    }
    if (isDepthFormat(internalFormat)) {
        return {border[0], border[0], border[0], 1.0f};
    }
    if (isRGBFamilyWithoutAlpha(internalFormat)) {
        return {border[0], border[1], border[2], 1.0f};
    }
    return border;
}

std::array<GLfloat, 4> appglImmediateResolvedBorderColor(
    GLenum internalFormat,
    const GLTextureParameters& params
) {
    const std::array<GLfloat, 4> base =
        appglImmediateBaseBorderColor(internalFormat, params.borderColor);
    return {
        appglImmediateTextureComponent(base, params.swizzle[0]),
        appglImmediateTextureComponent(base, params.swizzle[1]),
        appglImmediateTextureComponent(base, params.swizzle[2]),
        appglImmediateTextureComponent(base, params.swizzle[3]),
    };
}

std::uint8_t appglImmediateMultiplyByte(std::uint8_t a, std::uint8_t b) {
    return static_cast<std::uint8_t>(
        (static_cast<unsigned>(a) * static_cast<unsigned>(b) + 127u) / 255u);
}

std::uint8_t appglImmediateSwizzleComponent(const std::uint8_t texel[4], GLint swizzle) {
    switch (swizzle) {
        case GL_RED: return texel[0];
        case GL_GREEN: return texel[1];
        case GL_BLUE: return texel[2];
        case GL_ALPHA: return texel[3];
        case GL_ONE: return 255u;
        case GL_ZERO:
        default:
            return 0u;
    }
}

void appglImmediateApplyTextureEnv(GLenum envMode,
                                   std::uint32_t textureBaseClass,
                                   const std::uint8_t incoming[4],
                                   const std::uint8_t sampled[4],
                                   std::uint8_t out[4]) {
    if (envMode == GL_REPLACE) {
        switch (textureBaseClass) {
            case kAppGLImmediateTextureBaseAlpha:
                out[0] = incoming[0];
                out[1] = incoming[1];
                out[2] = incoming[2];
                out[3] = sampled[3];
                return;
            case kAppGLImmediateTextureBaseLuminance:
                out[0] = sampled[0];
                out[1] = sampled[0];
                out[2] = sampled[0];
                out[3] = incoming[3];
                return;
            case kAppGLImmediateTextureBaseLuminanceAlpha:
                out[0] = sampled[0];
                out[1] = sampled[0];
                out[2] = sampled[0];
                out[3] = sampled[3];
                return;
            case kAppGLImmediateTextureBaseIntensity:
                out[0] = sampled[0];
                out[1] = sampled[0];
                out[2] = sampled[0];
                out[3] = sampled[0];
                return;
            default:
                std::memcpy(out, sampled, 4u);
                return;
        }
    }

    switch (textureBaseClass) {
        case kAppGLImmediateTextureBaseAlpha:
            out[0] = appglImmediateMultiplyByte(incoming[0], sampled[0]);
            out[1] = appglImmediateMultiplyByte(incoming[1], sampled[1]);
            out[2] = appglImmediateMultiplyByte(incoming[2], sampled[2]);
            out[3] = appglImmediateMultiplyByte(incoming[3], sampled[3]);
            return;
        case kAppGLImmediateTextureBaseLuminance:
            out[0] = appglImmediateMultiplyByte(incoming[0], sampled[0]);
            out[1] = appglImmediateMultiplyByte(incoming[1], sampled[0]);
            out[2] = appglImmediateMultiplyByte(incoming[2], sampled[0]);
            out[3] = incoming[3];
            return;
        case kAppGLImmediateTextureBaseLuminanceAlpha:
            out[0] = appglImmediateMultiplyByte(incoming[0], sampled[0]);
            out[1] = appglImmediateMultiplyByte(incoming[1], sampled[0]);
            out[2] = appglImmediateMultiplyByte(incoming[2], sampled[0]);
            out[3] = appglImmediateMultiplyByte(incoming[3], sampled[3]);
            return;
        case kAppGLImmediateTextureBaseIntensity:
            out[0] = appglImmediateMultiplyByte(incoming[0], sampled[0]);
            out[1] = appglImmediateMultiplyByte(incoming[1], sampled[0]);
            out[2] = appglImmediateMultiplyByte(incoming[2], sampled[0]);
            out[3] = appglImmediateMultiplyByte(incoming[3], sampled[0]);
            return;
        default:
            for (int c = 0; c < 4; ++c) {
                out[c] = appglImmediateMultiplyByte(incoming[c], sampled[c]);
            }
            return;
    }
}

GLsizei appglImmediateWrappedTexel(float coord,
                                   GLsizei extent,
                                   GLint wrapMode,
                                   bool& borderSample) {
    if (extent <= 0) {
        borderSample = true;
        return 0;
    }
    const GLint texel = static_cast<GLint>(
        std::floor(coord * static_cast<float>(extent)));
    auto positiveModulo = [](GLint value, GLint divisor) {
        GLint result = value % divisor;
        return result < 0 ? result + divisor : result;
    };
    switch (wrapMode) {
        case GL_REPEAT:
            return positiveModulo(texel, extent);
        case GL_MIRRORED_REPEAT: {
            const GLint period = extent * 2;
            GLint mirrored = positiveModulo(texel, period);
            if (mirrored >= extent) {
                mirrored = period - 1 - mirrored;
            }
            return mirrored;
        }
        case GL_CLAMP_TO_BORDER:
            if (texel < 0 || texel >= extent) {
                borderSample = true;
            }
            return std::clamp<GLint>(texel, 0, extent - 1);
        case GL_CLAMP:
        case GL_CLAMP_TO_EDGE:
        default:
            return std::clamp<GLint>(texel, 0, extent - 1);
    }
}

}  // namespace

static GLint appglRasterIntegerCoordinate(GLfloat value) {
    if (!std::isfinite(value)) {
        return 0;
    }
    return static_cast<GLint>(std::lround(value));
}

static void appglPixelZoomSpan(GLfloat a, GLfloat b, GLint& lo, GLint& hi) {
    constexpr GLfloat kPixelBoundaryEpsilon = 1.0e-4f;
    const GLfloat minV = std::min(a, b);
    const GLfloat maxV = std::max(a, b);
    lo = static_cast<GLint>(std::floor(minV + kPixelBoundaryEpsilon));
    hi = static_cast<GLint>(std::ceil(maxV - kPixelBoundaryEpsilon));
    if (hi < lo) {
        hi = lo;
    }
}

#ifndef GL_LINE_STIPPLE
#define GL_LINE_STIPPLE 0x0B24
#endif
#ifndef GL_COMPILE
#define GL_COMPILE 0x1300
#endif
#ifndef GL_COMPILE_AND_EXECUTE
#define GL_COMPILE_AND_EXECUTE 0x1301
#endif
#ifndef GL_2_BYTES
#define GL_2_BYTES 0x1407
#endif
#ifndef GL_3_BYTES
#define GL_3_BYTES 0x1408
#endif
#ifndef GL_4_BYTES
#define GL_4_BYTES 0x1409
#endif
#ifndef GL_FRONT
#define GL_FRONT 0x0404
#endif
#ifndef GL_BACK
#define GL_BACK 0x0405
#endif
#ifndef GL_FRONT_AND_BACK
#define GL_FRONT_AND_BACK 0x0408
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
#ifndef GL_EMISSION
#define GL_EMISSION 0x1600
#endif
#ifndef GL_SHININESS
#define GL_SHININESS 0x1601
#endif
#ifndef GL_AMBIENT_AND_DIFFUSE
#define GL_AMBIENT_AND_DIFFUSE 0x1602
#endif
#ifndef GL_COLOR_MATERIAL
#define GL_COLOR_MATERIAL 0x0B57
#endif
#ifndef GL_NORMAL_ARRAY
#define GL_NORMAL_ARRAY 0x8075
#endif
#ifndef GL_TEXTURE_COORD_ARRAY
#define GL_TEXTURE_COORD_ARRAY 0x8078
#endif
#ifndef GL_ACCUM_BUFFER_BIT
#define GL_ACCUM_BUFFER_BIT 0x00000200
#endif
#ifndef GL_RETURN
#define GL_RETURN 0x0102
#endif
#ifndef GL_FOG
#define GL_FOG 0x0B60
#endif
#ifndef GL_FOG_MODE
#define GL_FOG_MODE 0x0B65
#endif
#ifndef GL_FOG_DENSITY
#define GL_FOG_DENSITY 0x0B62
#endif
#ifndef GL_FOG_START
#define GL_FOG_START 0x0B63
#endif
#ifndef GL_FOG_END
#define GL_FOG_END 0x0B64
#endif
#ifndef GL_FOG_COLOR
#define GL_FOG_COLOR 0x0B66
#endif
#ifndef GL_EXP
#define GL_EXP 0x0800
#endif
#ifndef GL_EXP2
#define GL_EXP2 0x0801
#endif
#ifndef GL_LIGHTING
#define GL_LIGHTING 0x0B50
#endif
#ifndef GL_LIGHT0
#define GL_LIGHT0 0x4000
#endif
#ifndef GL_LIGHT7
#define GL_LIGHT7 0x4007
#endif
#ifndef GL_LIGHT_MODEL_AMBIENT
#define GL_LIGHT_MODEL_AMBIENT 0x0B53
#endif
#ifndef GL_LIGHT_MODEL_TWO_SIDE
#define GL_LIGHT_MODEL_TWO_SIDE 0x0B52
#endif
#ifndef GL_POSITION
#define GL_POSITION 0x1203
#endif
#ifndef GL_SPOT_DIRECTION
#define GL_SPOT_DIRECTION 0x1204
#endif
#ifndef GL_SPOT_EXPONENT
#define GL_SPOT_EXPONENT 0x1205
#endif
#ifndef GL_SPOT_CUTOFF
#define GL_SPOT_CUTOFF 0x1206
#endif
#ifndef GL_CONSTANT_ATTENUATION
#define GL_CONSTANT_ATTENUATION 0x1207
#endif
#ifndef GL_LINEAR_ATTENUATION
#define GL_LINEAR_ATTENUATION 0x1208
#endif
#ifndef GL_QUADRATIC_ATTENUATION
#define GL_QUADRATIC_ATTENUATION 0x1209
#endif
#ifndef GL_CLIP_PLANE0
#define GL_CLIP_PLANE0 0x3000
#endif
#ifndef GL_CLIP_PLANE7
#define GL_CLIP_PLANE7 0x3007
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
#ifndef GL_MODULATE
#define GL_MODULATE 0x2100
#endif
#ifndef GL_DECAL
#define GL_DECAL 0x2101
#endif
#ifndef GL_REPLACE
#define GL_REPLACE 0x1E01
#endif
#ifndef GL_TEXTURE_GEN_S
#define GL_TEXTURE_GEN_S 0x0C60
#endif
#ifndef GL_TEXTURE_GEN_T
#define GL_TEXTURE_GEN_T 0x0C61
#endif
#ifndef GL_TEXTURE_GEN_R
#define GL_TEXTURE_GEN_R 0x0C62
#endif
#ifndef GL_TEXTURE_GEN_Q
#define GL_TEXTURE_GEN_Q 0x0C63
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
#ifndef GL_OBJECT_LINEAR
#define GL_OBJECT_LINEAR 0x2401
#endif
#ifndef GL_EYE_LINEAR
#define GL_EYE_LINEAR 0x2400
#endif
#ifndef GL_OBJECT_PLANE
#define GL_OBJECT_PLANE 0x2501
#endif
#ifndef GL_EYE_PLANE
#define GL_EYE_PLANE 0x2502
#endif

void GLContext::setShadeModel(GLenum mode) {
    if (mode != GL_FLAT && mode != GL_SMOOTH) {
        pushError(GL_INVALID_ENUM, "glShadeModel",
                  "mode is not GL_FLAT or GL_SMOOTH");
        return;
    }
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::ShadeModel;
        command.enumValue = mode;
        impl_->displayLists.compileCommands.push_back(command);
        if (!impl_->displayLists.compileAndExecute) {
            return;
        }
    }
    impl_->fixedFunctionShadeModel = mode;
}

GLenum GLContext::shadeModel() const {
    return impl_->fixedFunctionShadeModel;
}

void GLContext::setRasterPosition(float x, float y, float z, float w) {
    const Matrix4 mvp = impl_->matrixState.modelViewProjection();
    float clip[4] = {};
    for (int row = 0; row < 4; ++row) {
        clip[row] =
            mvp.m[0 * 4 + row] * x +
            mvp.m[1 * 4 + row] * y +
            mvp.m[2 * 4 + row] * z +
            mvp.m[3 * 4 + row] * w;
    }
    if (clip[3] == 0.0f ||
        !std::isfinite(clip[0]) ||
        !std::isfinite(clip[1]) ||
        !std::isfinite(clip[2]) ||
        !std::isfinite(clip[3])) {
        impl_->fixedFunctionRasterPositionValid = false;
        return;
    }
    const float invW = 1.0f / clip[3];
    const float ndcX = clip[0] * invW;
    const float ndcY = clip[1] * invW;
    const float ndcZ = clip[2] * invW;
    if (ndcX < -1.0f || ndcX > 1.0f ||
        ndcY < -1.0f || ndcY > 1.0f ||
        ndcZ < -1.0f || ndcZ > 1.0f) {
        impl_->fixedFunctionRasterPositionValid = false;
        return;
    }
    const auto& vp = impl_->state->viewport();
    const auto& dr = impl_->state->depthRange();
    const float windowX = static_cast<float>(vp.x) +
        (ndcX + 1.0f) * 0.5f * static_cast<float>(vp.width);
    const float windowY = static_cast<float>(vp.y) +
        (ndcY + 1.0f) * 0.5f * static_cast<float>(vp.height);
    const float windowZ =
        static_cast<float>(dr.nearValue) +
        (ndcZ + 1.0f) * 0.5f *
            static_cast<float>(dr.farValue - dr.nearValue);
    impl_->fixedFunctionRasterX = appglRasterIntegerCoordinate(windowX);
    impl_->fixedFunctionRasterY = appglRasterIntegerCoordinate(windowY);
    impl_->fixedFunctionRasterZ = windowZ;
    impl_->fixedFunctionRasterPosition[0] = windowX;
    impl_->fixedFunctionRasterPosition[1] = windowY;
    impl_->fixedFunctionRasterPosition[2] = windowZ;
    impl_->fixedFunctionRasterPosition[3] = clip[3];
    std::memcpy(impl_->fixedFunctionRasterColor,
                impl_->immediate.currentColor,
                sizeof(impl_->fixedFunctionRasterColor));
    std::memcpy(impl_->fixedFunctionRasterSecondaryColor,
                impl_->fixedFunctionCurrentSecondaryColor,
                sizeof(impl_->fixedFunctionRasterSecondaryColor));
    impl_->fixedFunctionRasterTexcoords = impl_->fixedFunctionCurrentTexcoords;
    impl_->fixedFunctionRasterPositionValid = true;
}

void GLContext::setWindowRasterPosition(GLfloat x, GLfloat y, GLfloat z) {
    const GLfloat clampedZ = std::clamp(z, 0.0f, 1.0f);
    impl_->fixedFunctionRasterX = appglRasterIntegerCoordinate(x);
    impl_->fixedFunctionRasterY = appglRasterIntegerCoordinate(y);
    impl_->fixedFunctionRasterZ = clampedZ;
    impl_->fixedFunctionRasterPosition[0] = x;
    impl_->fixedFunctionRasterPosition[1] = y;
    impl_->fixedFunctionRasterPosition[2] = clampedZ;
    impl_->fixedFunctionRasterPosition[3] = 1.0f;
    std::memcpy(impl_->fixedFunctionRasterColor,
                impl_->immediate.currentColor,
                sizeof(impl_->fixedFunctionRasterColor));
    std::memcpy(impl_->fixedFunctionRasterSecondaryColor,
                impl_->fixedFunctionCurrentSecondaryColor,
                sizeof(impl_->fixedFunctionRasterSecondaryColor));
    impl_->fixedFunctionRasterTexcoords = impl_->fixedFunctionCurrentTexcoords;
    impl_->fixedFunctionRasterPositionValid = true;
}

void GLContext::setSecondaryColorCompat(GLfloat r, GLfloat g, GLfloat b) {
    impl_->fixedFunctionCurrentSecondaryColor[0] = r;
    impl_->fixedFunctionCurrentSecondaryColor[1] = g;
    impl_->fixedFunctionCurrentSecondaryColor[2] = b;
    impl_->fixedFunctionCurrentSecondaryColor[3] = 1.0f;
}

void GLContext::setLogicOp(GLenum opcode) {
    switch (opcode) {
        case GL_CLEAR:
        case GL_SET:
        case GL_COPY:
        case GL_COPY_INVERTED:
        case GL_NOOP:
        case GL_INVERT:
        case GL_AND:
        case GL_NAND:
        case GL_OR:
        case GL_NOR:
        case GL_XOR:
        case GL_EQUIV:
        case GL_AND_REVERSE:
        case GL_AND_INVERTED:
        case GL_OR_REVERSE:
        case GL_OR_INVERTED:
            impl_->fixedFunctionLogicOp = opcode;
            return;
        default:
            pushError(GL_INVALID_ENUM, "glLogicOp",
                      "opcode is not a valid color logic operation");
            return;
    }
}

void GLContext::setLineStipple(GLint factor, GLushort pattern) {
    impl_->fixedFunctionLineStippleFactor =
        std::clamp<GLint>(factor, 1, 256);
    impl_->fixedFunctionLineStipplePattern = pattern;
}

void GLContext::setFogFloat(GLenum pname, GLfloat value) {
    impl_->state->setFogFloat(pname, value);
    const GLfloat values[4] = {value, value, value, value};
    setFogFloatVector(pname, values);
}

void GLContext::setFogFloatVector(GLenum pname, const GLfloat* params) {
    if (params == nullptr) {
        return;
    }
    switch (pname) {
        case GL_FOG_MODE: {
            const GLenum mode = static_cast<GLenum>(params[0]);
            if (mode != GL_LINEAR && mode != GL_EXP && mode != GL_EXP2) {
                pushError(GL_INVALID_ENUM, "glFog", "mode is invalid");
                return;
            }
            impl_->fog.mode = mode;
            return;
        }
        case GL_FOG_DENSITY:
            if (params[0] < 0.0f || !std::isfinite(params[0])) {
                pushError(GL_INVALID_VALUE, "glFog", "density is invalid");
                return;
            }
            impl_->fog.density = params[0];
            return;
        case GL_FOG_START:
            impl_->fog.start = params[0];
            impl_->state->setFogFloat(pname, params[0]);
            return;
        case GL_FOG_END:
            impl_->fog.end = params[0];
            return;
        case GL_FOG_COLOR:
            impl_->fog.color[0] = params[0];
            impl_->fog.color[1] = params[1];
            impl_->fog.color[2] = params[2];
            impl_->fog.color[3] = params[3];
            return;
        default:
            pushError(GL_INVALID_ENUM, "glFog", "pname is invalid");
            return;
    }
}

void GLContext::setLightFloatCompat(GLenum light, GLenum pname, const GLfloat* params) {
    if (params == nullptr) {
        return;
    }
    if (light < GL_LIGHT0 || light > GL_LIGHT7) {
        pushError(GL_INVALID_ENUM, "glLight", "light is invalid");
        return;
    }
    auto& dst = impl_->lighting.lights[static_cast<std::size_t>(light - GL_LIGHT0)];
    auto copy4 = [&](float* out) {
        out[0] = params[0];
        out[1] = params[1];
        out[2] = params[2];
        out[3] = params[3];
    };
    switch (pname) {
        case GL_AMBIENT:
            copy4(dst.ambient);
            return;
        case GL_DIFFUSE:
            copy4(dst.diffuse);
            return;
        case GL_SPECULAR:
            copy4(dst.specular);
            return;
        case GL_POSITION:
            copy4(dst.position);
            return;
        case GL_SPOT_DIRECTION:
            dst.spotDirection[0] = params[0];
            dst.spotDirection[1] = params[1];
            dst.spotDirection[2] = params[2];
            return;
        case GL_SPOT_EXPONENT:
            dst.spotExponent = std::clamp(params[0], 0.0f, 128.0f);
            return;
        case GL_SPOT_CUTOFF:
            dst.spotCutoff = params[0] == 180.0f
                ? 180.0f
                : std::clamp(params[0], 0.0f, 90.0f);
            return;
        case GL_CONSTANT_ATTENUATION:
            dst.constantAttenuation = std::max(0.0f, params[0]);
            return;
        case GL_LINEAR_ATTENUATION:
            dst.linearAttenuation = std::max(0.0f, params[0]);
            return;
        case GL_QUADRATIC_ATTENUATION:
            dst.quadraticAttenuation = std::max(0.0f, params[0]);
            return;
        default:
            pushError(GL_INVALID_ENUM, "glLight", "pname is invalid");
            return;
    }
}

void GLContext::setLightModelFloatCompat(GLenum pname, const GLfloat* params) {
    if (params == nullptr) {
        return;
    }
    switch (pname) {
        case GL_LIGHT_MODEL_AMBIENT:
            impl_->lighting.modelAmbient[0] = params[0];
            impl_->lighting.modelAmbient[1] = params[1];
            impl_->lighting.modelAmbient[2] = params[2];
            impl_->lighting.modelAmbient[3] = params[3];
            return;
        case GL_LIGHT_MODEL_TWO_SIDE:
            impl_->lighting.twoSide = params[0] != 0.0f;
            return;
        default:
            pushError(GL_INVALID_ENUM, "glLightModel", "pname is invalid");
            return;
    }
}

void GLContext::setNormalCompat(GLfloat x, GLfloat y, GLfloat z) {
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::Normal;
        command.values[0] = x;
        command.values[1] = y;
        command.values[2] = z;
        impl_->displayLists.compileCommands.push_back(command);
        if (!impl_->displayLists.compileAndExecute) {
            return;
        }
    }
    impl_->lighting.currentNormal[0] = x;
    impl_->lighting.currentNormal[1] = y;
    impl_->lighting.currentNormal[2] = z;
}

void GLContext::setClipPlaneCompat(GLenum plane, const GLdouble* equation) {
    if (equation == nullptr) {
        return;
    }
    if (plane < GL_CLIP_PLANE0 || plane > GL_CLIP_PLANE7) {
        pushError(GL_INVALID_ENUM, "glClipPlane", "plane is invalid");
        return;
    }
    auto& dst = impl_->clipPlanes[static_cast<std::size_t>(plane - GL_CLIP_PLANE0)];
    dst[0] = equation[0];
    dst[1] = equation[1];
    dst[2] = equation[2];
    dst[3] = equation[3];
}

void GLContext::setTexEnvFloatCompat(GLenum target, GLenum pname, const GLfloat* params) {
    if (params == nullptr) {
        return;
    }
    if (target != GL_TEXTURE_ENV) {
        pushError(GL_INVALID_ENUM, "glTexEnv", "target is invalid");
        return;
    }
    switch (pname) {
        case GL_TEXTURE_ENV_MODE:
            impl_->texEnv.mode = static_cast<GLenum>(params[0]);
            return;
        case GL_TEXTURE_ENV_COLOR:
            impl_->texEnv.color[0] = params[0];
            impl_->texEnv.color[1] = params[1];
            impl_->texEnv.color[2] = params[2];
            impl_->texEnv.color[3] = params[3];
            return;
        default:
            return;
    }
}

void GLContext::setTexGenFloatCompat(GLenum coord, GLenum pname, const GLfloat* params) {
    if (params == nullptr) {
        return;
    }
    const auto coordIndex = [&]() -> int {
        switch (coord) {
            case GL_S: return 0;
            case GL_T: return 1;
            case GL_R: return 2;
            case GL_Q: return 3;
            default: return -1;
        }
    }();
    if (coordIndex < 0) {
        pushError(GL_INVALID_ENUM, "glTexGen", "coord is invalid");
        return;
    }
    auto& dst = impl_->texGen[static_cast<std::size_t>(coordIndex)];
    switch (pname) {
        case GL_TEXTURE_GEN_MODE:
            dst.mode = static_cast<GLenum>(params[0]);
            return;
        case GL_OBJECT_PLANE:
            dst.objectPlane[0] = params[0];
            dst.objectPlane[1] = params[1];
            dst.objectPlane[2] = params[2];
            dst.objectPlane[3] = params[3];
            return;
        case GL_EYE_PLANE:
            dst.eyePlane[0] = params[0];
            dst.eyePlane[1] = params[1];
            dst.eyePlane[2] = params[2];
            dst.eyePlane[3] = params[3];
            return;
        default:
            pushError(GL_INVALID_ENUM, "glTexGen", "pname is invalid");
            return;
    }
}

void GLContext::setAccumClearCompat(GLfloat red, GLfloat green, GLfloat blue, GLfloat alpha) {
    impl_->accumClearColor[0] = red;
    impl_->accumClearColor[1] = green;
    impl_->accumClearColor[2] = blue;
    impl_->accumClearColor[3] = alpha;
}

bool GLContext::accumCompat(GLenum op, GLfloat value) {
    if (op != GL_RETURN) {
        return true;
    }
    if (impl_->state->boundDrawFramebuffer() != 0) {
        return true;
    }
    impl_->ensureDefaultFramebufferShadow();
    const std::uint8_t rgba[4] = {
        normalizedByte(impl_->accumClearColor[0] * value),
        normalizedByte(impl_->accumClearColor[1] * value),
        normalizedByte(impl_->accumClearColor[2] * value),
        normalizedByte(impl_->accumClearColor[3] * value),
    };
    for (std::size_t i = 0; i + 3 < impl_->defaultFramebufferRGBA8.size(); i += 4) {
        std::memcpy(impl_->defaultFramebufferRGBA8.data() + i, rgba, 4u);
    }
    impl_->defaultFramebufferShadowValid = true;
    return true;
}

void GLContext::setPixelZoomCompat(GLfloat xfactor, GLfloat yfactor) {
    if (impl_->immediate.active) {
        pushError(GL_INVALID_OPERATION, "glPixelZoom",
                  "cannot change pixel zoom inside glBegin/glEnd");
        return;
    }
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::PixelZoom;
        command.values[0] = xfactor;
        command.values[1] = yfactor;
        impl_->displayLists.compileCommands.push_back(std::move(command));
        if (!impl_->displayLists.compileAndExecute) {
            return;
        }
    }
    impl_->fixedFunctionPixelZoomX = xfactor;
    impl_->fixedFunctionPixelZoomY = yfactor;
}

bool GLContext::bitmapCompat(GLsizei width,
                             GLsizei height,
                             GLfloat xorig,
                             GLfloat yorig,
                             GLfloat xmove,
                             GLfloat ymove,
                             const GLubyte* bitmap) {
    if (width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE, "glBitmap",
                  "width and height must be non-negative");
        return false;
    }
    if (impl_->immediate.active) {
        pushError(GL_INVALID_OPERATION, "glBitmap",
                  "cannot draw bitmap inside glBegin/glEnd");
        return false;
    }

    std::vector<std::uint8_t> mask(
        static_cast<std::size_t>(width) *
        static_cast<std::size_t>(height),
        0);
    if (bitmap != nullptr && width > 0 && height > 0) {
        const auto& store = impl_->state->pixelStore();
        const std::size_t sourceWidth =
            static_cast<std::size_t>(store.unpackRowLength > 0
                ? store.unpackRowLength
                : width);
        const std::size_t rowBytes =
            alignByteCount((sourceWidth + 7u) / 8u, store.unpackAlignment);
        const std::size_t skipRows =
            static_cast<std::size_t>(std::max<GLint>(store.unpackSkipRows, 0));
        const std::size_t skipPixels =
            static_cast<std::size_t>(std::max<GLint>(store.unpackSkipPixels, 0));
        const auto* source =
            static_cast<const std::uint8_t*>(bitmap) + skipRows * rowBytes;
        const bool lsbFirst = store.unpackLsbFirst == GL_TRUE;
        for (GLsizei y = 0; y < height; ++y) {
            const auto* row =
                source + static_cast<std::size_t>(y) * rowBytes;
            for (GLsizei x = 0; x < width; ++x) {
                const std::size_t bitIndex =
                    skipPixels + static_cast<std::size_t>(x);
                const std::uint8_t byte = row[bitIndex / 8u];
                const std::uint8_t bit =
                    lsbFirst
                        ? static_cast<std::uint8_t>((byte >> (bitIndex & 7u)) & 1u)
                        : static_cast<std::uint8_t>((byte >> (7u - (bitIndex & 7u))) & 1u);
                mask[static_cast<std::size_t>(y) *
                     static_cast<std::size_t>(width) +
                     static_cast<std::size_t>(x)] = bit;
            }
        }
    }

    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::Bitmap;
        command.width = width;
        command.height = height;
        command.values[0] = xorig;
        command.values[1] = yorig;
        command.values[2] = xmove;
        command.values[3] = ymove;
        command.bitmapMask = mask;
        impl_->displayLists.compileCommands.push_back(std::move(command));
        if (!impl_->displayLists.compileAndExecute) {
            return true;
        }
    }

    return bitmapMaskCompat(width, height, xorig, yorig, xmove, ymove, mask.data());
}

bool GLContext::bitmapMaskCompat(GLsizei width,
                                 GLsizei height,
                                 GLfloat xorig,
                                 GLfloat yorig,
                                 GLfloat xmove,
                                 GLfloat ymove,
                                 const std::uint8_t* mask) {
    if (width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE, "glBitmap",
                  "width and height must be non-negative");
        return false;
    }
    if (impl_->immediate.active) {
        pushError(GL_INVALID_OPERATION, "glBitmap",
                  "cannot draw bitmap inside glBegin/glEnd");
        return false;
    }
    if (!impl_->fixedFunctionRasterPositionValid) {
        return true;
    }

    auto advanceRasterPosition = [&]() {
        impl_->fixedFunctionRasterPosition[0] += xmove;
        impl_->fixedFunctionRasterPosition[1] += ymove;
        impl_->fixedFunctionRasterX =
            appglRasterIntegerCoordinate(impl_->fixedFunctionRasterPosition[0]);
        impl_->fixedFunctionRasterY =
            appglRasterIntegerCoordinate(impl_->fixedFunctionRasterPosition[1]);
    };
    if (width == 0 || height == 0 ||
        mask == nullptr ||
        impl_->state->isEnabled(GL_RASTERIZER_DISCARD) ||
        impl_->shouldSkipDrawForConditionalRender()) {
        advanceRasterPosition();
        return true;
    }

    std::vector<std::uint8_t> mappedRGBA(
        static_cast<std::size_t>(width) *
        static_cast<std::size_t>(height) * 4u,
        0);
    for (GLsizei row = 0; row < height; ++row) {
        for (GLsizei col = 0; col < width; ++col) {
            const std::size_t maskIndex =
                static_cast<std::size_t>(row) *
                static_cast<std::size_t>(width) +
                static_cast<std::size_t>(col);
            const std::size_t dst = maskIndex * 4u;
            const std::uint8_t bit = mask[maskIndex] == 0 ? 0 : 1;
            mappedRGBA[dst + 0] = normalizedByte(impl_->compatPixelMapValue(0, bit));
            mappedRGBA[dst + 1] = normalizedByte(impl_->compatPixelMapValue(1, bit));
            mappedRGBA[dst + 2] = normalizedByte(impl_->compatPixelMapValue(2, bit));
            mappedRGBA[dst + 3] = normalizedByte(impl_->compatPixelMapValue(3, bit));
        }
    }

    const GLfloat zoomX = impl_->fixedFunctionPixelZoomX;
    const GLfloat zoomY = impl_->fixedFunctionPixelZoomY;
    if (zoomX == 0.0f || zoomY == 0.0f) {
        advanceRasterPosition();
        return true;
    }

    const auto& blend = impl_->state->blendState();
    const bool blendEnabled = impl_->state->isEnabled(GL_BLEND);
    auto blendFactor = [](GLenum factor,
                          int component,
                          const GLfloat src[4],
                          const GLfloat dst[4],
                          const GLfloat constant[4]) -> GLfloat {
        switch (factor) {
            case GL_ZERO: return 0.0f;
            case GL_ONE: return 1.0f;
            case GL_SRC_COLOR: return src[component];
            case GL_ONE_MINUS_SRC_COLOR: return 1.0f - src[component];
            case GL_DST_COLOR: return dst[component];
            case GL_ONE_MINUS_DST_COLOR: return 1.0f - dst[component];
            case GL_SRC_ALPHA: return src[3];
            case GL_ONE_MINUS_SRC_ALPHA: return 1.0f - src[3];
            case GL_DST_ALPHA: return dst[3];
            case GL_ONE_MINUS_DST_ALPHA: return 1.0f - dst[3];
            case GL_CONSTANT_COLOR: return constant[component];
            case GL_ONE_MINUS_CONSTANT_COLOR: return 1.0f - constant[component];
            case GL_CONSTANT_ALPHA: return constant[3];
            case GL_ONE_MINUS_CONSTANT_ALPHA: return 1.0f - constant[3];
            default: return 1.0f;
        }
    };
    auto applyBlend = [&](std::uint8_t rgba[4],
                          std::vector<std::uint8_t>& target,
                          std::size_t offset) {
        if (!blendEnabled) {
            return;
        }
        const GLfloat src[4] = {
            static_cast<GLfloat>(rgba[0]) / 255.0f,
            static_cast<GLfloat>(rgba[1]) / 255.0f,
            static_cast<GLfloat>(rgba[2]) / 255.0f,
            static_cast<GLfloat>(rgba[3]) / 255.0f,
        };
        const GLfloat dst[4] = {
            static_cast<GLfloat>(target[offset + 0]) / 255.0f,
            static_cast<GLfloat>(target[offset + 1]) / 255.0f,
            static_cast<GLfloat>(target[offset + 2]) / 255.0f,
            static_cast<GLfloat>(target[offset + 3]) / 255.0f,
        };
        GLfloat out[4] = {};
        for (int c = 0; c < 3; ++c) {
            const GLfloat sf = blendFactor(blend.srcRGB, c, src, dst, blend.color);
            const GLfloat df = blendFactor(blend.dstRGB, c, src, dst, blend.color);
            out[c] = src[c] * sf + dst[c] * df;
        }
        const GLfloat saf = blendFactor(blend.srcAlpha, 3, src, dst, blend.color);
        const GLfloat daf = blendFactor(blend.dstAlpha, 3, src, dst, blend.color);
        out[3] = src[3] * saf + dst[3] * daf;
        for (int c = 0; c < 4; ++c) {
            rgba[c] = normalizedByte(std::clamp(out[c], 0.0f, 1.0f));
        }
    };
    auto insideScissor = [&](GLint x, GLint y) -> bool {
        if (!impl_->state->isEnabled(GL_SCISSOR_TEST)) {
            return true;
        }
        const auto& sc = impl_->state->scissor();
        return x >= sc.x && y >= sc.y &&
               x < sc.x + sc.width &&
               y < sc.y + sc.height;
    };

    const GLfloat baseX = impl_->fixedFunctionRasterPosition[0] - xorig;
    const GLfloat baseY = impl_->fixedFunctionRasterPosition[1] - yorig;
    auto sourceColor = [&](GLsizei col, GLsizei row, std::uint8_t rgba[4]) {
        const std::size_t src =
            (static_cast<std::size_t>(row) *
             static_cast<std::size_t>(width) +
             static_cast<std::size_t>(col)) * 4u;
        for (int c = 0; c < 4; ++c) {
            const GLfloat mapped =
                static_cast<GLfloat>(mappedRGBA[src + static_cast<std::size_t>(c)]) /
                255.0f;
            rgba[c] = normalizedByte(
                impl_->fixedFunctionRasterColor[c] * mapped);
        }
    };
    auto destSpan = [](GLfloat a, GLfloat b, GLint& lo, GLint& hi) {
        appglPixelZoomSpan(a, b, lo, hi);
    };
    GLint touchedMinX = std::numeric_limits<GLint>::max();
    GLint touchedMinY = std::numeric_limits<GLint>::max();
    GLint touchedMaxX = std::numeric_limits<GLint>::min();
    GLint touchedMaxY = std::numeric_limits<GLint>::min();
    auto noteTouched = [&](GLint x, GLint y) {
        touchedMinX = std::min(touchedMinX, x);
        touchedMinY = std::min(touchedMinY, y);
        touchedMaxX = std::max(touchedMaxX, x);
        touchedMaxY = std::max(touchedMaxY, y);
    };
    auto paintToTarget = [&](std::vector<std::uint8_t>& target,
                             GLsizei targetWidth,
                             GLsizei targetHeight,
                             bool flipY,
                             std::size_t layerOffset) {
        const std::size_t targetBytes =
            static_cast<std::size_t>(targetWidth) *
            static_cast<std::size_t>(targetHeight) * 4u;
        if (target.size() < layerOffset + targetBytes) {
            target.resize(layerOffset + targetBytes, 0);
        }
        for (GLsizei row = 0; row < height; ++row) {
            for (GLsizei col = 0; col < width; ++col) {
                const std::size_t maskIndex =
                    static_cast<std::size_t>(row) *
                    static_cast<std::size_t>(width) +
                    static_cast<std::size_t>(col);
                if (mask[maskIndex] == 0) {
                    continue;
                }
                GLint x0 = 0;
                GLint x1 = 0;
                GLint y0 = 0;
                GLint y1 = 0;
                destSpan(baseX + static_cast<GLfloat>(col) * zoomX,
                         baseX + static_cast<GLfloat>(col + 1) * zoomX,
                         x0,
                         x1);
                destSpan(baseY + static_cast<GLfloat>(row) * zoomY,
                         baseY + static_cast<GLfloat>(row + 1) * zoomY,
                         y0,
                         y1);
                x0 = std::max<GLint>(x0, 0);
                y0 = std::max<GLint>(y0, 0);
                x1 = std::min<GLint>(x1, targetWidth);
                y1 = std::min<GLint>(y1, targetHeight);
                if (x0 >= x1 || y0 >= y1) {
                    continue;
                }
                std::uint8_t srcRGBA[4];
                sourceColor(col, row, srcRGBA);
                for (GLint y = y0; y < y1; ++y) {
                    if (!insideScissor(x0, y) && !insideScissor(x1 - 1, y)) {
                        bool rowVisible = false;
                        for (GLint x = x0; x < x1; ++x) {
                            if (insideScissor(x, y)) {
                                rowVisible = true;
                                break;
                            }
                        }
                        if (!rowVisible) {
                            continue;
                        }
                    }
                    const GLint storageY =
                        flipY ? (targetHeight - 1 - y) : y;
                    for (GLint x = x0; x < x1; ++x) {
                        if (!insideScissor(x, y)) {
                            continue;
                        }
                        const std::size_t offset =
                            layerOffset +
                            (static_cast<std::size_t>(storageY) *
                             static_cast<std::size_t>(targetWidth) +
                             static_cast<std::size_t>(x)) * 4u;
                        std::uint8_t outRGBA[4] = {
                            srcRGBA[0], srcRGBA[1], srcRGBA[2], srcRGBA[3]
                        };
                        applyBlend(outRGBA, target, offset);
                        for (int c = 0; c < 4; ++c) {
                            if (blend.colorMask[c] != GL_FALSE) {
                                target[offset + static_cast<std::size_t>(c)] =
                                    outRGBA[c];
                            }
                        }
                        if (blend.colorMask[0] != GL_FALSE ||
                            blend.colorMask[1] != GL_FALSE ||
                            blend.colorMask[2] != GL_FALSE ||
                            blend.colorMask[3] != GL_FALSE) {
                            noteTouched(x, y);
                        }
                    }
                }
            }
        }
    };

    bool ok = true;
    if (impl_->state->boundDrawFramebuffer() == 0) {
        impl_->ensureDefaultFramebufferShadow();
        impl_->materializeDefaultFbShadowClear();
        paintToTarget(impl_->defaultFramebufferRGBA8,
                      impl_->defaultFramebufferShadowWidth,
                      impl_->defaultFramebufferShadowHeight,
                      false,
                      0);
        impl_->defaultFramebufferShadowValid = true;
        if (impl_->frameGraph != nullptr && touchedMinX <= touchedMaxX &&
            touchedMinY <= touchedMaxY) {
            const GLsizei uploadWidth =
                static_cast<GLsizei>(touchedMaxX - touchedMinX + 1);
            const GLsizei uploadHeight =
                static_cast<GLsizei>(touchedMaxY - touchedMinY + 1);
            const std::size_t sourceRowBytes =
                static_cast<std::size_t>(impl_->defaultFramebufferShadowWidth) *
                4u;
            const std::size_t sourceOffset =
                static_cast<std::size_t>(touchedMinY) * sourceRowBytes +
                static_cast<std::size_t>(touchedMinX) * 4u;
            (void)impl_->frameGraph->writeDefaultColorRegion(
                touchedMinX,
                touchedMinY,
                uploadWidth,
                uploadHeight,
                impl_->defaultFramebufferRGBA8.data() + sourceOffset,
                sourceRowBytes);
        }
    } else {
        GLFramebufferObject* fbo =
            impl_->objects->framebuffers().get(impl_->state->boundDrawFramebuffer());
        if (fbo == nullptr) {
            ok = false;
        } else {
            const bool lowerLeft = impl_->state->clipOrigin() != GL_UPPER_LEFT;
            for (GLenum drawBuffer : fbo->drawBuffers) {
                if (drawBuffer == GL_NONE) {
                    continue;
                }
                const GLFramebufferAttachment* attachment =
                    impl_->framebufferAttachment(*fbo, drawBuffer);
                if (attachment == nullptr) {
                    continue;
                }
                if (attachment->kind == GLFramebufferAttachment::Kind::Texture) {
                    const auto resolved =
                        impl_->resolveTextureAttachmentStorage(*attachment);
                    GLTextureObject* texture = resolved.storageTexture;
                    if (!resolved.valid || texture == nullptr) {
                        continue;
                    }
                    auto levelIt = texture->levels.find(resolved.level);
                    if (levelIt == texture->levels.end() ||
                        !levelIt->second.defined) {
                        continue;
                    }
                    GLTextureImageLevel& image = levelIt->second;
                    const GLsizei targetWidth = std::max<GLsizei>(image.desc.width, 1);
                    const GLsizei targetHeight =
                        texture->target == GL_TEXTURE_1D
                            ? 1
                            : std::max<GLsizei>(image.desc.height, 1);
                    const GLint layer = std::max<GLint>(resolved.layer, 0);
                    const GLsizei depth = std::max<GLsizei>(image.desc.depth, 1);
                    if (layer >= depth) {
                        continue;
                    }
                    const std::size_t layerBytes =
                        static_cast<std::size_t>(targetWidth) *
                        static_cast<std::size_t>(targetHeight) * 4u;
                    paintToTarget(image.rgba8,
                                  targetWidth,
                                  targetHeight,
                                  lowerLeft,
                                  static_cast<std::size_t>(layer) * layerBytes);
                    texture->colorShadowAuthoritative = true;
                    if (lowerLeft) {
                        texture->wasFramebufferRenderedTo = true;
                    }
                    ok = impl_->replaceMetalTexture(*texture) && ok;
                } else if (attachment->kind == GLFramebufferAttachment::Kind::Renderbuffer) {
                    GLRenderbufferObject* rb =
                        impl_->objects->renderbuffers().get(attachment->object);
                    if (rb == nullptr || !rb->storageDefined ||
                        rb->width <= 0 || rb->height <= 0) {
                        continue;
                    }
                    impl_->materializeRenderbufferRGBA8Clear(*rb);
                    paintToTarget(rb->rgba8,
                                  rb->width,
                                  rb->height,
                                  lowerLeft,
                                  0);
                    rb->rgba8ShadowClearPending = false;
                    rb->colorShadowAuthoritative = true;
                    rb->framebufferReadbackYFlip = lowerLeft;
                    if (rb->metalTexture != nullptr) {
                        id<MTLTexture> metalTex =
                            (__bridge id<MTLTexture>)rb->metalTexture;
                        if (metalTex.sampleCount <= 1 &&
                            (metalTex.pixelFormat == MTLPixelFormatRGBA8Unorm ||
                             metalTex.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB)) {
                            if (impl_->frameGraph != nullptr) {
                                impl_->frameGraph->materializePendingFboClearsForTexture(
                                    rb->metalTexture);
                            }
                            MTLRegion fullRegion = MTLRegionMake2D(
                                0,
                                0,
                                static_cast<NSUInteger>(rb->width),
                                static_cast<NSUInteger>(rb->height));
                            [metalTex replaceRegion:fullRegion
                                        mipmapLevel:0
                                          withBytes:rb->rgba8.data()
                                        bytesPerRow:static_cast<NSUInteger>(rb->width) * 4u];
                        }
                    }
                }
            }
        }
    }

    advanceRasterPosition();
    return ok;
}

bool GLContext::drawPixelsCompat(GLsizei width,
                                 GLsizei height,
                                 GLenum format,
                                 GLenum type,
                                 const void* pixels) {
    if (width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE, "glDrawPixels", "width and height must be non-negative");
        return false;
    }
    if (width == 0 || height == 0 ||
        !impl_->fixedFunctionRasterPositionValid ||
        impl_->state->isEnabled(GL_RASTERIZER_DISCARD)) {
        return true;
    }
    const bool packedRGB =
        type == GL_UNSIGNED_BYTE_3_3_2 ||
        type == GL_UNSIGNED_BYTE_2_3_3_REV ||
        type == GL_UNSIGNED_SHORT_5_6_5 ||
        type == GL_UNSIGNED_SHORT_5_6_5_REV;
    const bool packedRGBA =
        type == GL_UNSIGNED_SHORT_4_4_4_4 ||
        type == GL_UNSIGNED_SHORT_4_4_4_4_REV ||
        type == GL_UNSIGNED_SHORT_5_5_5_1 ||
        type == GL_UNSIGNED_SHORT_1_5_5_5_REV ||
        type == GL_UNSIGNED_INT_8_8_8_8 ||
        type == GL_UNSIGNED_INT_8_8_8_8_REV ||
        type == GL_UNSIGNED_INT_10_10_10_2 ||
        type == GL_UNSIGNED_INT_2_10_10_10_REV;
    const bool packedDepthStencil =
        type == GL_UNSIGNED_INT_24_8 ||
        type == GL_FLOAT_32_UNSIGNED_INT_24_8_REV;
    if ((packedRGB && format != GL_RGB) ||
        (packedRGBA && format != GL_RGBA && format != GL_BGRA)) {
        pushError(GL_INVALID_OPERATION, "glDrawPixels",
                  "packed pixel type is incompatible with format");
        return false;
    }
    if ((packedDepthStencil && format != GL_DEPTH_STENCIL) ||
        (format == GL_DEPTH_STENCIL && !packedDepthStencil)) {
        pushError(GL_INVALID_OPERATION, "glDrawPixels",
                  "depth-stencil format requires a packed depth-stencil type");
        return false;
    }
    const auto componentCount = [&]() -> std::size_t {
        switch (format) {
            case GL_RED:
            case GL_GREEN:
            case GL_BLUE:
            case GL_ALPHA:
            case GL_LUMINANCE:
            case GL_DEPTH_COMPONENT:
            case GL_STENCIL_INDEX:
                return 1u;
            case GL_RG:
            case GL_LUMINANCE_ALPHA:
            case GL_DEPTH_STENCIL:
                return 2u;
            case GL_RGB:
            case GL_BGR:
                return 3u;
            case GL_RGBA:
            case GL_BGRA:
                return 4u;
            default:
                return 0u;
        }
    }();
    if (componentCount == 0u) {
        pushError(GL_INVALID_ENUM, "glDrawPixels", "format is invalid");
        return false;
    }
    const auto packedPixelBytes = [&]() -> std::size_t {
        switch (type) {
            case GL_UNSIGNED_BYTE_3_3_2:
            case GL_UNSIGNED_BYTE_2_3_3_REV:
                return 1u;
            case GL_UNSIGNED_SHORT_5_6_5:
            case GL_UNSIGNED_SHORT_5_6_5_REV:
            case GL_UNSIGNED_SHORT_4_4_4_4:
            case GL_UNSIGNED_SHORT_4_4_4_4_REV:
            case GL_UNSIGNED_SHORT_5_5_5_1:
            case GL_UNSIGNED_SHORT_1_5_5_5_REV:
                return 2u;
            case GL_UNSIGNED_INT_8_8_8_8:
            case GL_UNSIGNED_INT_8_8_8_8_REV:
            case GL_UNSIGNED_INT_10_10_10_2:
            case GL_UNSIGNED_INT_2_10_10_10_REV:
            case GL_UNSIGNED_INT_24_8:
                return 4u;
            case GL_FLOAT_32_UNSIGNED_INT_24_8_REV:
                return 8u;
            default:
                return 0u;
        }
    }();
    const std::size_t componentBytes = bytesPerComponent(type);
    if (packedPixelBytes == 0u && componentBytes == 0u) {
        pushError(GL_INVALID_ENUM, "glDrawPixels", "type is invalid");
        return false;
    }
    if (pixels == nullptr) {
        return true;
    }
    const GLfloat zoomX = impl_->fixedFunctionPixelZoomX;
    const GLfloat zoomY = impl_->fixedFunctionPixelZoomY;
    if (zoomX == 0.0f || zoomY == 0.0f) {
        return true;
    }
    const std::size_t pixelBytes =
        packedPixelBytes != 0u ? packedPixelBytes : componentCount * componentBytes;
    const auto& store = impl_->state->pixelStore();
    const bool swapBytes = (store.unpackSwapBytes == GL_TRUE);
    const std::size_t sourceWidth =
        static_cast<std::size_t>(store.unpackRowLength > 0 ? store.unpackRowLength : width);
    const std::size_t rowBytes =
        alignByteCount(sourceWidth * pixelBytes, store.unpackAlignment);
    const auto* source =
        static_cast<const std::uint8_t*>(pixels) +
        static_cast<std::size_t>(store.unpackSkipRows) * rowBytes +
        static_cast<std::size_t>(store.unpackSkipPixels) * pixelBytes;

    auto packedToU8 = [](std::uint32_t value, std::uint32_t maxValue) {
        return static_cast<std::uint8_t>(value * 255u / maxValue);
    };
    auto readColor = [&](const std::uint8_t* pixel, std::uint8_t rgba[4]) {
        rgba[0] = 0;
        rgba[1] = 0;
        rgba[2] = 0;
        rgba[3] = 255;
        if (packedPixelBytes != 0u) {
            if (type == GL_UNSIGNED_BYTE_3_3_2) {
                const std::uint8_t v = pixel[0];
                rgba[0] = packedToU8((v >> 5) & 0x7u, 7u);
                rgba[1] = packedToU8((v >> 2) & 0x7u, 7u);
                rgba[2] = packedToU8(v & 0x3u, 3u);
            } else if (type == GL_UNSIGNED_BYTE_2_3_3_REV) {
                const std::uint8_t v = pixel[0];
                rgba[0] = packedToU8(v & 0x7u, 7u);
                rgba[1] = packedToU8((v >> 3) & 0x7u, 7u);
                rgba[2] = packedToU8((v >> 6) & 0x3u, 3u);
            } else if (type == GL_UNSIGNED_SHORT_5_6_5 ||
                       type == GL_UNSIGNED_SHORT_5_6_5_REV) {
                const std::uint16_t v = Impl::readU16Value(pixel, swapBytes);
                if (type == GL_UNSIGNED_SHORT_5_6_5) {
                    rgba[0] = packedToU8((v >> 11) & 0x1fu, 31u);
                    rgba[1] = packedToU8((v >> 5) & 0x3fu, 63u);
                    rgba[2] = packedToU8(v & 0x1fu, 31u);
                } else {
                    rgba[0] = packedToU8(v & 0x1fu, 31u);
                    rgba[1] = packedToU8((v >> 5) & 0x3fu, 63u);
                    rgba[2] = packedToU8((v >> 11) & 0x1fu, 31u);
                }
            } else if (type == GL_UNSIGNED_SHORT_4_4_4_4 ||
                       type == GL_UNSIGNED_SHORT_4_4_4_4_REV ||
                       type == GL_UNSIGNED_SHORT_5_5_5_1 ||
                       type == GL_UNSIGNED_SHORT_1_5_5_5_REV) {
                const std::uint16_t v = Impl::readU16Value(pixel, swapBytes);
                if (type == GL_UNSIGNED_SHORT_4_4_4_4) {
                    rgba[0] = packedToU8((v >> 12) & 0xfu, 15u);
                    rgba[1] = packedToU8((v >> 8) & 0xfu, 15u);
                    rgba[2] = packedToU8((v >> 4) & 0xfu, 15u);
                    rgba[3] = packedToU8(v & 0xfu, 15u);
                } else if (type == GL_UNSIGNED_SHORT_4_4_4_4_REV) {
                    rgba[0] = packedToU8(v & 0xfu, 15u);
                    rgba[1] = packedToU8((v >> 4) & 0xfu, 15u);
                    rgba[2] = packedToU8((v >> 8) & 0xfu, 15u);
                    rgba[3] = packedToU8((v >> 12) & 0xfu, 15u);
                } else if (type == GL_UNSIGNED_SHORT_5_5_5_1) {
                    rgba[0] = packedToU8((v >> 11) & 0x1fu, 31u);
                    rgba[1] = packedToU8((v >> 6) & 0x1fu, 31u);
                    rgba[2] = packedToU8((v >> 1) & 0x1fu, 31u);
                    rgba[3] = (v & 0x1u) != 0 ? 255 : 0;
                } else {
                    rgba[0] = packedToU8(v & 0x1fu, 31u);
                    rgba[1] = packedToU8((v >> 5) & 0x1fu, 31u);
                    rgba[2] = packedToU8((v >> 10) & 0x1fu, 31u);
                    rgba[3] = ((v >> 15) & 0x1u) != 0 ? 255 : 0;
                }
            } else {
                const std::uint32_t v = Impl::readU32Value(pixel, swapBytes);
                if (type == GL_UNSIGNED_INT_8_8_8_8) {
                    rgba[0] = static_cast<std::uint8_t>((v >> 24) & 0xffu);
                    rgba[1] = static_cast<std::uint8_t>((v >> 16) & 0xffu);
                    rgba[2] = static_cast<std::uint8_t>((v >> 8) & 0xffu);
                    rgba[3] = static_cast<std::uint8_t>(v & 0xffu);
                } else if (type == GL_UNSIGNED_INT_8_8_8_8_REV) {
                    rgba[0] = static_cast<std::uint8_t>(v & 0xffu);
                    rgba[1] = static_cast<std::uint8_t>((v >> 8) & 0xffu);
                    rgba[2] = static_cast<std::uint8_t>((v >> 16) & 0xffu);
                    rgba[3] = static_cast<std::uint8_t>((v >> 24) & 0xffu);
                } else if (type == GL_UNSIGNED_INT_10_10_10_2) {
                    rgba[0] = packedToU8((v >> 22) & 0x3ffu, 1023u);
                    rgba[1] = packedToU8((v >> 12) & 0x3ffu, 1023u);
                    rgba[2] = packedToU8((v >> 2) & 0x3ffu, 1023u);
                    rgba[3] = packedToU8(v & 0x3u, 3u);
                } else {
                    rgba[0] = packedToU8(v & 0x3ffu, 1023u);
                    rgba[1] = packedToU8((v >> 10) & 0x3ffu, 1023u);
                    rgba[2] = packedToU8((v >> 20) & 0x3ffu, 1023u);
                    rgba[3] = packedToU8((v >> 30) & 0x3u, 3u);
                }
            }
            if (format == GL_BGRA) {
                std::swap(rgba[0], rgba[2]);
            }
            return;
        }
        switch (format) {
            case GL_RED:
                rgba[0] = Impl::readComponentAsU8(pixel, type, 0, swapBytes);
                break;
            case GL_GREEN:
                rgba[1] = Impl::readComponentAsU8(pixel, type, 0, swapBytes);
                break;
            case GL_BLUE:
                rgba[2] = Impl::readComponentAsU8(pixel, type, 0, swapBytes);
                break;
            case GL_ALPHA:
                rgba[3] = Impl::readComponentAsU8(pixel, type, 0, swapBytes);
                break;
            case GL_RG:
                rgba[0] = Impl::readComponentAsU8(pixel, type, 0, swapBytes);
                rgba[1] = Impl::readComponentAsU8(pixel, type, 1, swapBytes);
                break;
            case GL_RGB:
                rgba[0] = Impl::readComponentAsU8(pixel, type, 0, swapBytes);
                rgba[1] = Impl::readComponentAsU8(pixel, type, 1, swapBytes);
                rgba[2] = Impl::readComponentAsU8(pixel, type, 2, swapBytes);
                break;
            case GL_BGR:
                rgba[0] = Impl::readComponentAsU8(pixel, type, 2, swapBytes);
                rgba[1] = Impl::readComponentAsU8(pixel, type, 1, swapBytes);
                rgba[2] = Impl::readComponentAsU8(pixel, type, 0, swapBytes);
                break;
            case GL_RGBA:
                rgba[0] = Impl::readComponentAsU8(pixel, type, 0, swapBytes);
                rgba[1] = Impl::readComponentAsU8(pixel, type, 1, swapBytes);
                rgba[2] = Impl::readComponentAsU8(pixel, type, 2, swapBytes);
                rgba[3] = Impl::readComponentAsU8(pixel, type, 3, swapBytes);
                break;
            case GL_BGRA:
                rgba[0] = Impl::readComponentAsU8(pixel, type, 2, swapBytes);
                rgba[1] = Impl::readComponentAsU8(pixel, type, 1, swapBytes);
                rgba[2] = Impl::readComponentAsU8(pixel, type, 0, swapBytes);
                rgba[3] = Impl::readComponentAsU8(pixel, type, 3, swapBytes);
                break;
            case GL_LUMINANCE: {
                const auto lum = Impl::readComponentAsU8(pixel, type, 0, swapBytes);
                rgba[0] = lum;
                rgba[1] = lum;
                rgba[2] = lum;
                break;
            }
            case GL_LUMINANCE_ALPHA: {
                const auto lum = Impl::readComponentAsU8(pixel, type, 0, swapBytes);
                rgba[0] = lum;
                rgba[1] = lum;
                rgba[2] = lum;
                rgba[3] = Impl::readComponentAsU8(pixel, type, 1, swapBytes);
                break;
            }
            default:
                break;
        }
    };
    auto readScalar = [&](const std::uint8_t* pixel) -> GLfloat {
        switch (type) {
            case GL_BYTE: {
                const auto v = *reinterpret_cast<const GLbyte*>(pixel);
                return v == -128 ? -1.0f : static_cast<GLfloat>(v) / 127.0f;
            }
            case GL_UNSIGNED_BYTE:
                return static_cast<GLfloat>(*pixel) / 255.0f;
            case GL_SHORT: {
                std::uint16_t bits = Impl::readU16Value(pixel, swapBytes);
                GLshort v = 0;
                std::memcpy(&v, &bits, sizeof(v));
                return (2.0f * static_cast<GLfloat>(v) + 1.0f) / 65535.0f;
            }
            case GL_UNSIGNED_SHORT:
                return static_cast<GLfloat>(Impl::readU16Value(pixel, swapBytes)) / 65535.0f;
            case GL_INT: {
                std::uint32_t bits = Impl::readU32Value(pixel, swapBytes);
                GLint v = 0;
                std::memcpy(&v, &bits, sizeof(v));
                return static_cast<GLfloat>((2.0 * static_cast<double>(v) + 1.0) / 4294967294.0);
            }
            case GL_UNSIGNED_INT:
                return static_cast<GLfloat>(static_cast<double>(Impl::readU32Value(pixel, swapBytes)) / 4294967295.0);
            case GL_FLOAT: {
                std::uint32_t bits = Impl::readU32Value(pixel, swapBytes);
                GLfloat v = 0.0f;
                std::memcpy(&v, &bits, sizeof(v));
                return v;
            }
            default:
                return 0.0f;
        }
    };
    auto readStencilIndex = [&](const std::uint8_t* pixel) -> std::uint8_t {
        GLuint value = 0;
        switch (type) {
            case GL_BYTE: {
                const auto v = *reinterpret_cast<const GLbyte*>(pixel);
                value = static_cast<GLuint>(static_cast<GLint>(v));
                break;
            }
            case GL_UNSIGNED_BYTE:
                value = static_cast<GLuint>(*pixel);
                break;
            case GL_SHORT: {
                std::uint16_t bits = Impl::readU16Value(pixel, swapBytes);
                GLshort v = 0;
                std::memcpy(&v, &bits, sizeof(v));
                value = static_cast<GLuint>(static_cast<GLint>(v));
                break;
            }
            case GL_UNSIGNED_SHORT:
                value = static_cast<GLuint>(Impl::readU16Value(pixel, swapBytes));
                break;
            case GL_INT: {
                std::uint32_t bits = Impl::readU32Value(pixel, swapBytes);
                GLint v = 0;
                std::memcpy(&v, &bits, sizeof(v));
                value = static_cast<GLuint>(v);
                break;
            }
            case GL_UNSIGNED_INT:
                value = Impl::readU32Value(pixel, swapBytes);
                break;
            case GL_FLOAT: {
                std::uint32_t bits = Impl::readU32Value(pixel, swapBytes);
                GLfloat v = 0.0f;
                std::memcpy(&v, &bits, sizeof(v));
                value = std::isfinite(v) ? static_cast<GLuint>(v) : 0u;
                break;
            }
            default:
                value = 0u;
                break;
        }
        return static_cast<std::uint8_t>(value & 0xffu);
    };
    auto readDepthStencilDepth = [&](const std::uint8_t* pixel) -> GLfloat {
        if (type == GL_UNSIGNED_INT_24_8) {
            const std::uint32_t packed = Impl::readU32Value(pixel, swapBytes);
            const std::uint32_t depth24 = (packed >> 8) & 0x00ffffffu;
            return static_cast<GLfloat>(
                static_cast<double>(depth24) / static_cast<double>(0x00ffffffu));
        }
        if (type == GL_FLOAT_32_UNSIGNED_INT_24_8_REV) {
            const std::uint32_t bits = Impl::readU32Value(pixel, swapBytes);
            GLfloat depth = 0.0f;
            std::memcpy(&depth, &bits, sizeof(depth));
            return depth;
        }
        return 0.0f;
    };
    auto readDepthStencilStencil = [&](const std::uint8_t* pixel) -> std::uint8_t {
        if (type == GL_UNSIGNED_INT_24_8) {
            const std::uint32_t packed = Impl::readU32Value(pixel, swapBytes);
            return static_cast<std::uint8_t>(packed & 0xffu);
        }
        if (type == GL_FLOAT_32_UNSIGNED_INT_24_8_REV) {
            const std::uint32_t stencilSlot =
                Impl::readU32Value(pixel + sizeof(GLfloat), swapBytes);
            return static_cast<std::uint8_t>(stencilSlot & 0xffu);
        }
        return 0;
    };
    auto sampleCurrentTexture2D = [&](std::uint8_t rgba[4]) {
        if (!impl_->state->isEnabled(GL_TEXTURE_2D)) {
            return;
        }
        GLTextureObject* texture = impl_->currentTexture(GL_TEXTURE_2D);
        if (texture == nullptr) {
            return;
        }
        const GLint level = std::max<GLint>(texture->params.baseLevel, 0);
        const auto levelIt = texture->levels.find(level);
        if (levelIt == texture->levels.end() || !levelIt->second.defined) {
            return;
        }
        const GLTextureImageLevel& image = levelIt->second;
        const GLsizei texWidth = std::max<GLsizei>(image.desc.width, 1);
        const GLsizei texHeight = std::max<GLsizei>(image.desc.height, 1);
        const std::size_t required =
            static_cast<std::size_t>(texWidth) *
            static_cast<std::size_t>(texHeight) * 4u;
        if (image.rgba8.size() < required) {
            return;
        }
        auto clampTexel = [](float coord, GLsizei extent) -> GLsizei {
            const float scaled = coord * static_cast<float>(extent);
            const auto texel = static_cast<GLsizei>(std::floor(scaled));
            return std::clamp<GLsizei>(texel, 0, extent - 1);
        };
        const GLsizei tx = clampTexel(impl_->immediate.currentTexcoord[0], texWidth);
        const GLsizei ty = clampTexel(impl_->immediate.currentTexcoord[1], texHeight);
        const std::size_t texOffset =
            (static_cast<std::size_t>(ty) *
             static_cast<std::size_t>(texWidth) +
             static_cast<std::size_t>(tx)) * 4u;
        const std::uint8_t texel[4] = {
            image.rgba8[texOffset + 0],
            image.rgba8[texOffset + 1],
            image.rgba8[texOffset + 2],
            image.rgba8[texOffset + 3],
        };
        switch (impl_->texEnv.mode) {
            case GL_REPLACE:
                std::memcpy(rgba, texel, 4u);
                break;
            case GL_MODULATE:
            default:
                for (int c = 0; c < 4; ++c) {
                    rgba[c] = static_cast<std::uint8_t>(
                        (static_cast<unsigned>(rgba[c]) *
                         static_cast<unsigned>(texel[c]) + 127u) / 255u);
                }
                break;
        }
    };

    if (impl_->state->boundDrawFramebuffer() == 0 &&
        !impl_->resolveDefaultFramebufferMsaaColorIfNeeded()) {
        pushError(GL_INVALID_OPERATION, "glDrawPixels",
                  "failed to resolve default framebuffer MSAA color");
        return false;
    }

    if (format == GL_DEPTH_COMPONENT ||
        format == GL_STENCIL_INDEX ||
        format == GL_DEPTH_STENCIL) {
        impl_->ensureDefaultFramebufferDepthStencilShadow();
        if (format == GL_DEPTH_COMPONENT) {
            impl_->ensureDefaultFramebufferShadow();
            impl_->materializeDefaultFbShadowClear();
        }
    } else {
        impl_->ensureDefaultFramebufferShadow();
        impl_->materializeDefaultFbShadowClear();
    }
    const auto& blend = impl_->state->blendState();
    const bool blendEnabled = impl_->state->isEnabled(GL_BLEND);
    auto blendFactor = [](GLenum factor,
                          int component,
                          const GLfloat src[4],
                          const GLfloat dst[4],
                          const GLfloat constant[4]) -> GLfloat {
        switch (factor) {
            case GL_ZERO:
                return 0.0f;
            case GL_ONE:
                return 1.0f;
            case GL_SRC_COLOR:
                return src[component];
            case GL_ONE_MINUS_SRC_COLOR:
                return 1.0f - src[component];
            case GL_DST_COLOR:
                return dst[component];
            case GL_ONE_MINUS_DST_COLOR:
                return 1.0f - dst[component];
            case GL_SRC_ALPHA:
                return src[3];
            case GL_ONE_MINUS_SRC_ALPHA:
                return 1.0f - src[3];
            case GL_DST_ALPHA:
                return dst[3];
            case GL_ONE_MINUS_DST_ALPHA:
                return 1.0f - dst[3];
            case GL_CONSTANT_COLOR:
                return constant[component];
            case GL_ONE_MINUS_CONSTANT_COLOR:
                return 1.0f - constant[component];
            case GL_CONSTANT_ALPHA:
                return constant[3];
            case GL_ONE_MINUS_CONSTANT_ALPHA:
                return 1.0f - constant[3];
            default:
                return 1.0f;
        }
    };
	    auto applyBlend = [&](std::uint8_t rgba[4], std::size_t offset) {
	        if (!blendEnabled) {
	            return;
	        }
        GLfloat src[4] = {
            static_cast<GLfloat>(rgba[0]) / 255.0f,
            static_cast<GLfloat>(rgba[1]) / 255.0f,
            static_cast<GLfloat>(rgba[2]) / 255.0f,
            static_cast<GLfloat>(rgba[3]) / 255.0f,
        };
        GLfloat dst[4] = {
            static_cast<GLfloat>(impl_->defaultFramebufferRGBA8[offset + 0]) / 255.0f,
            static_cast<GLfloat>(impl_->defaultFramebufferRGBA8[offset + 1]) / 255.0f,
            static_cast<GLfloat>(impl_->defaultFramebufferRGBA8[offset + 2]) / 255.0f,
            static_cast<GLfloat>(impl_->defaultFramebufferRGBA8[offset + 3]) / 255.0f,
        };
        GLfloat out[4] = {};
        for (int c = 0; c < 3; ++c) {
            const GLfloat sf = blendFactor(blend.srcRGB, c, src, dst, blend.color);
            const GLfloat df = blendFactor(blend.dstRGB, c, src, dst, blend.color);
            out[c] = src[c] * sf + dst[c] * df;
        }
        const GLfloat saf = blendFactor(blend.srcAlpha, 3, src, dst, blend.color);
        const GLfloat daf = blendFactor(blend.dstAlpha, 3, src, dst, blend.color);
        out[3] = src[3] * saf + dst[3] * daf;
        for (int c = 0; c < 4; ++c) {
	            rgba[c] = normalizedByte(std::clamp(out[c], 0.0f, 1.0f));
	        }
	    };
		        auto depthPasses = [&](GLfloat incoming, GLfloat current) {
	        if (!impl_->state->isEnabled(GL_DEPTH_TEST)) {
	            return true;
	        }
	        switch (impl_->state->depthState().func) {
	            case GL_NEVER:    return false;
	            case GL_LESS:     return incoming < current;
	            case GL_LEQUAL:   return incoming <= current;
	            case GL_GREATER:  return incoming > current;
	            case GL_GEQUAL:   return incoming >= current;
	            case GL_EQUAL:    return incoming == current;
	            case GL_NOTEQUAL: return incoming != current;
	            case GL_ALWAYS:
	            default:          return true;
	        }
    };
        const auto& stencilFace = impl_->state->stencilState().front;
        const std::uint8_t stencilWriteMask =
            static_cast<std::uint8_t>(stencilFace.writeMask & 0xffu);
    auto insideScissor = [&](GLint dstX, GLint dstY) -> bool {
        if (!impl_->state->isEnabled(GL_SCISSOR_TEST)) {
            return true;
        }
        const auto& sc = impl_->state->scissor();
        return dstX >= sc.x && dstY >= sc.y &&
               dstX < sc.x + sc.width &&
               dstY < sc.y + sc.height;
    };
    GLint touchedMinX = std::numeric_limits<GLint>::max();
    GLint touchedMinY = std::numeric_limits<GLint>::max();
    GLint touchedMaxX = std::numeric_limits<GLint>::min();
    GLint touchedMaxY = std::numeric_limits<GLint>::min();
    auto noteTouched = [&](GLint dstX, GLint dstY) {
        touchedMinX = std::min(touchedMinX, dstX);
        touchedMinY = std::min(touchedMinY, dstY);
        touchedMaxX = std::max(touchedMaxX, dstX);
        touchedMaxY = std::max(touchedMaxY, dstY);
    };
    const GLsizei clipWidth = std::max<GLsizei>(
        impl_->defaultFramebufferShadowWidth,
        impl_->defaultFramebufferDepthStencilShadowWidth);
    const GLsizei clipHeight = std::max<GLsizei>(
        impl_->defaultFramebufferShadowHeight,
        impl_->defaultFramebufferDepthStencilShadowHeight);
    const GLfloat baseX = impl_->fixedFunctionRasterPosition[0];
    const GLfloat baseY = impl_->fixedFunctionRasterPosition[1];
    for (GLsizei row = 0; row < height; ++row) {
        const auto* srcRow = source + static_cast<std::size_t>(row) * rowBytes;
        GLint y0 = 0;
        GLint y1 = 0;
        appglPixelZoomSpan(baseY + static_cast<GLfloat>(row) * zoomY,
                           baseY + static_cast<GLfloat>(row + 1) * zoomY,
                           y0,
                           y1);
        y0 = std::max<GLint>(y0, 0);
        y1 = std::min<GLint>(y1, clipHeight);
        if (y0 >= y1) {
            continue;
        }
        for (GLsizei col = 0; col < width; ++col) {
            GLint x0 = 0;
            GLint x1 = 0;
            appglPixelZoomSpan(baseX + static_cast<GLfloat>(col) * zoomX,
                               baseX + static_cast<GLfloat>(col + 1) * zoomX,
                               x0,
                               x1);
            x0 = std::max<GLint>(x0, 0);
            x1 = std::min<GLint>(x1, clipWidth);
            if (x0 >= x1) {
                continue;
            }
            const auto* pixel = srcRow + static_cast<std::size_t>(col) * pixelBytes;
            for (GLint dstY = y0; dstY < y1; ++dstY) {
                for (GLint dstX = x0; dstX < x1; ++dstX) {
                    if (!insideScissor(dstX, dstY)) {
                        continue;
                    }
                    if (format == GL_DEPTH_STENCIL) {
                        if (dstX >= impl_->defaultFramebufferDepthStencilShadowWidth ||
                            dstY >= impl_->defaultFramebufferDepthStencilShadowHeight) {
                            continue;
                        }
                        const std::size_t offset =
                            static_cast<std::size_t>(dstY) *
                            static_cast<std::size_t>(impl_->defaultFramebufferDepthStencilShadowWidth) +
                            static_cast<std::size_t>(dstX);
                        const GLfloat incomingDepth =
                            std::clamp(readDepthStencilDepth(pixel), 0.0f, 1.0f);
                        if (!depthPasses(incomingDepth,
                                         impl_->defaultFramebufferDepth32[offset])) {
                            continue;
                        }
                        if (impl_->state->depthState().writeMask != GL_FALSE) {
                            impl_->defaultFramebufferDepth32[offset] = incomingDepth;
                        }
                        const std::uint8_t incomingStencil =
                            readDepthStencilStencil(pixel);
                        impl_->defaultFramebufferStencil8[offset] =
                            static_cast<std::uint8_t>(
                                (impl_->defaultFramebufferStencil8[offset] &
                                 ~stencilWriteMask) |
                                (incomingStencil & stencilWriteMask));
                        noteTouched(dstX, dstY);
                        continue;
                    }
                    if (format == GL_DEPTH_COMPONENT) {
                        if (dstX >= impl_->defaultFramebufferDepthStencilShadowWidth ||
                            dstY >= impl_->defaultFramebufferDepthStencilShadowHeight) {
                            continue;
                        }
                        const std::size_t offset =
                            static_cast<std::size_t>(dstY) *
                            static_cast<std::size_t>(impl_->defaultFramebufferDepthStencilShadowWidth) +
                            static_cast<std::size_t>(dstX);
                        const GLfloat incomingDepth =
                            std::clamp(readScalar(pixel), 0.0f, 1.0f);
                        if (!depthPasses(incomingDepth,
                                         impl_->defaultFramebufferDepth32[offset])) {
                            continue;
                        }
                        if (impl_->state->depthState().writeMask != GL_FALSE) {
                            impl_->defaultFramebufferDepth32[offset] = incomingDepth;
                        }
                        if (dstX < impl_->defaultFramebufferShadowWidth &&
                            dstY < impl_->defaultFramebufferShadowHeight) {
                            std::uint8_t rgba[4] = {
                                normalizedByte(impl_->immediate.currentColor[0]),
                                normalizedByte(impl_->immediate.currentColor[1]),
                                normalizedByte(impl_->immediate.currentColor[2]),
                                normalizedByte(impl_->immediate.currentColor[3]),
                            };
                            const std::size_t colorOffset =
                                (static_cast<std::size_t>(dstY) *
                                 static_cast<std::size_t>(impl_->defaultFramebufferShadowWidth) +
                                 static_cast<std::size_t>(dstX)) * 4u;
                            applyBlend(rgba, colorOffset);
                            if (blend.colorMask[0] != GL_FALSE) impl_->defaultFramebufferRGBA8[colorOffset + 0] = rgba[0];
                            if (blend.colorMask[1] != GL_FALSE) impl_->defaultFramebufferRGBA8[colorOffset + 1] = rgba[1];
                            if (blend.colorMask[2] != GL_FALSE) impl_->defaultFramebufferRGBA8[colorOffset + 2] = rgba[2];
                            if (blend.colorMask[3] != GL_FALSE) impl_->defaultFramebufferRGBA8[colorOffset + 3] = rgba[3];
                        }
                        noteTouched(dstX, dstY);
                        continue;
                    }
                    if (format == GL_STENCIL_INDEX) {
                        if (dstX >= impl_->defaultFramebufferDepthStencilShadowWidth ||
                            dstY >= impl_->defaultFramebufferDepthStencilShadowHeight) {
                            continue;
                        }
                        const std::size_t offset =
                            static_cast<std::size_t>(dstY) *
                            static_cast<std::size_t>(impl_->defaultFramebufferDepthStencilShadowWidth) +
                            static_cast<std::size_t>(dstX);
                        impl_->defaultFramebufferStencil8[offset] = readStencilIndex(pixel);
                        noteTouched(dstX, dstY);
                        continue;
                    }
                    if (dstX >= impl_->defaultFramebufferShadowWidth ||
                        dstY >= impl_->defaultFramebufferShadowHeight) {
                        continue;
                    }
                    std::uint8_t rgba[4];
                    readColor(pixel, rgba);
                    sampleCurrentTexture2D(rgba);
                    const std::size_t offset =
                        (static_cast<std::size_t>(dstY) *
                         static_cast<std::size_t>(impl_->defaultFramebufferShadowWidth) +
                         static_cast<std::size_t>(dstX)) * 4u;
                    applyBlend(rgba, offset);
                    if (blend.colorMask[0] != GL_FALSE) impl_->defaultFramebufferRGBA8[offset + 0] = rgba[0];
                    if (blend.colorMask[1] != GL_FALSE) impl_->defaultFramebufferRGBA8[offset + 1] = rgba[1];
                    if (blend.colorMask[2] != GL_FALSE) impl_->defaultFramebufferRGBA8[offset + 2] = rgba[2];
                    if (blend.colorMask[3] != GL_FALSE) impl_->defaultFramebufferRGBA8[offset + 3] = rgba[3];
                    noteTouched(dstX, dstY);
                }
            }
        }
    }
    const bool touchedPixels = touchedMinX <= touchedMaxX && touchedMinY <= touchedMaxY;
	    if (format == GL_DEPTH_STENCIL) {
	        impl_->defaultFramebufferDepthShadowValid = true;
	        impl_->defaultFramebufferStencilShadowValid = true;
	        if (impl_->state->boundDrawFramebuffer() == 0 &&
	            impl_->frameGraph != nullptr &&
                touchedPixels) {
	            const GLint minX = touchedMinX;
	            const GLint minY = touchedMinY;
	            const GLint maxX = touchedMaxX + 1;
	            const GLint maxY = touchedMaxY + 1;
	            if (minX < maxX && minY < maxY) {
	                const GLsizei uploadWidth = maxX - minX;
	                const GLsizei uploadHeight = maxY - minY;
	                std::vector<GLfloat> depthUpload(
	                    static_cast<std::size_t>(uploadWidth) *
	                    static_cast<std::size_t>(uploadHeight));
	                for (GLsizei row = 0; row < uploadHeight; ++row) {
	                    const std::size_t srcOffset =
	                        static_cast<std::size_t>(minY + row) *
	                        static_cast<std::size_t>(impl_->defaultFramebufferDepthStencilShadowWidth) +
	                        static_cast<std::size_t>(minX);
	                    const std::size_t dstOffset =
	                        static_cast<std::size_t>(row) *
	                        static_cast<std::size_t>(uploadWidth);
	                    std::memcpy(depthUpload.data() + dstOffset,
	                                impl_->defaultFramebufferDepth32.data() + srcOffset,
	                                static_cast<std::size_t>(uploadWidth) * sizeof(GLfloat));
	                }
	                const std::size_t firstOffset =
	                    static_cast<std::size_t>(minY) *
	                    static_cast<std::size_t>(impl_->defaultFramebufferDepthStencilShadowWidth) +
	                    static_cast<std::size_t>(minX);
	                const std::uint8_t stencilValue =
	                    impl_->defaultFramebufferStencil8[firstOffset];
	                bool uniformStencil = true;
	                for (GLsizei row = 0; row < uploadHeight && uniformStencil; ++row) {
	                    for (GLsizei col = 0; col < uploadWidth; ++col) {
	                        const std::size_t offset =
	                            static_cast<std::size_t>(minY + row) *
	                            static_cast<std::size_t>(impl_->defaultFramebufferDepthStencilShadowWidth) +
	                            static_cast<std::size_t>(minX + col);
	                        if (impl_->defaultFramebufferStencil8[offset] != stencilValue) {
	                            uniformStencil = false;
	                            break;
	                        }
	                    }
	                }
	                if (uniformStencil) {
	                    (void)impl_->frameGraph->writeDefaultDepthStencilRegion(
	                        minX, minY, uploadWidth, uploadHeight,
	                        depthUpload.data(), true, stencilValue, true);
	                }
	            }
	        }
	    } else if (format == GL_DEPTH_COMPONENT) {
	        impl_->defaultFramebufferDepthShadowValid = true;
	        impl_->defaultFramebufferShadowValid = true;
	        if (impl_->state->boundDrawFramebuffer() == 0 &&
	            impl_->frameGraph != nullptr &&
                touchedPixels) {
            const GLint minX = touchedMinX;
            const GLint minY = touchedMinY;
            const GLint maxX = touchedMaxX + 1;
            const GLint maxY = touchedMaxY + 1;
            if (minX < maxX && minY < maxY) {
                const GLsizei uploadWidth = maxX - minX;
                const GLsizei uploadHeight = maxY - minY;
                std::vector<GLfloat> depthUpload(
                    static_cast<std::size_t>(uploadWidth) *
                    static_cast<std::size_t>(uploadHeight));
                for (GLsizei row = 0; row < uploadHeight; ++row) {
                    const std::size_t srcOffset =
                        static_cast<std::size_t>(minY + row) *
                        static_cast<std::size_t>(impl_->defaultFramebufferDepthStencilShadowWidth) +
                        static_cast<std::size_t>(minX);
                    const std::size_t dstOffset =
                        static_cast<std::size_t>(row) *
                        static_cast<std::size_t>(uploadWidth);
                    std::memcpy(depthUpload.data() + dstOffset,
                                impl_->defaultFramebufferDepth32.data() + srcOffset,
                                static_cast<std::size_t>(uploadWidth) * sizeof(GLfloat));
                }
                (void)impl_->frameGraph->writeDefaultDepthStencilRegion(
                    minX, minY, uploadWidth, uploadHeight,
                    depthUpload.data(), true, 0, false);
            }
        }
    } else if (format == GL_STENCIL_INDEX) {
        impl_->defaultFramebufferStencilShadowValid = true;
        if (impl_->state->boundDrawFramebuffer() == 0 &&
            impl_->frameGraph != nullptr &&
            touchedPixels) {
            const GLint minX = touchedMinX;
            const GLint minY = touchedMinY;
            const GLint maxX = touchedMaxX + 1;
            const GLint maxY = touchedMaxY + 1;
            if (minX < maxX && minY < maxY) {
                const GLsizei uploadWidth = maxX - minX;
                const GLsizei uploadHeight = maxY - minY;
                const std::size_t firstOffset =
                    static_cast<std::size_t>(minY) *
                    static_cast<std::size_t>(impl_->defaultFramebufferDepthStencilShadowWidth) +
                    static_cast<std::size_t>(minX);
                const std::uint8_t stencilValue =
                    impl_->defaultFramebufferStencil8[firstOffset];
                bool uniformStencil = true;
                for (GLsizei row = 0; row < uploadHeight && uniformStencil; ++row) {
                    for (GLsizei col = 0; col < uploadWidth; ++col) {
                        const std::size_t offset =
                            static_cast<std::size_t>(minY + row) *
                            static_cast<std::size_t>(impl_->defaultFramebufferDepthStencilShadowWidth) +
                            static_cast<std::size_t>(minX + col);
                        if (impl_->defaultFramebufferStencil8[offset] != stencilValue) {
                            uniformStencil = false;
                            break;
                        }
                    }
                }
                if (uniformStencil) {
                    (void)impl_->frameGraph->writeDefaultDepthStencilRegion(
                        minX, minY, uploadWidth, uploadHeight,
                        nullptr, false, stencilValue, true);
                }
            }
        }
    } else {
        impl_->defaultFramebufferShadowValid = true;
    }
    return true;
}

void GLContext::pushAttribCompat(GLbitfield mask) {
    Impl::CompatAttribSnapshot snapshot;
    if ((mask & GL_CURRENT_BIT) != 0) {
        snapshot.hasCurrentColor = true;
        std::memcpy(snapshot.currentColor,
                    impl_->immediate.currentColor,
                    sizeof(snapshot.currentColor));
    }
    impl_->compatAttribStack.push_back(snapshot);
}

void GLContext::popAttribCompat() {
    if (impl_->compatAttribStack.empty()) {
        pushError(GL_STACK_UNDERFLOW, "glPopAttrib", "attribute stack is empty");
        return;
    }
    const auto snapshot = impl_->compatAttribStack.back();
    impl_->compatAttribStack.pop_back();
    if (snapshot.hasCurrentColor) {
        immediateColor(snapshot.currentColor[0],
                       snapshot.currentColor[1],
                       snapshot.currentColor[2],
                       snapshot.currentColor[3]);
    }
}

void GLContext::setColorMaterialCompat(GLenum face, GLenum mode) {
    switch (face) {
        case GL_FRONT:
        case GL_BACK:
        case GL_FRONT_AND_BACK:
            break;
        default:
            pushError(GL_INVALID_ENUM, "glColorMaterial", "face is invalid");
            return;
    }
    switch (mode) {
        case GL_AMBIENT:
        case GL_DIFFUSE:
        case GL_SPECULAR:
        case GL_EMISSION:
        case GL_AMBIENT_AND_DIFFUSE:
            break;
        default:
            pushError(GL_INVALID_ENUM, "glColorMaterial", "mode is invalid");
            return;
    }
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::ColorMaterial;
        command.enumValue = face;
        command.enumValue2 = mode;
        impl_->displayLists.compileCommands.push_back(command);
        if (!impl_->displayLists.compileAndExecute) {
            return;
        }
    }
    impl_->material.colorMaterialFace = face;
    impl_->material.colorMaterialMode = mode;
}

void GLContext::setMaterialFloatCompat(GLenum face, GLenum pname, const GLfloat* params) {
    if (params == nullptr) {
        return;
    }
    if (face != GL_FRONT && face != GL_BACK && face != GL_FRONT_AND_BACK) {
        pushError(GL_INVALID_ENUM, "glMaterialfv", "face is invalid");
        return;
    }
    switch (pname) {
        case GL_AMBIENT:
        case GL_DIFFUSE:
        case GL_SPECULAR:
        case GL_EMISSION:
        case GL_AMBIENT_AND_DIFFUSE:
        case GL_SHININESS:
            break;
        default:
            pushError(GL_INVALID_ENUM, "glMaterialfv", "pname is invalid");
            return;
    }
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::Material;
        command.enumValue = face;
        command.enumValue2 = pname;
        command.values[0] = params[0];
        command.values[1] = params[1];
        command.values[2] = params[2];
        command.values[3] = params[3];
        impl_->displayLists.compileCommands.push_back(command);
        if (!impl_->displayLists.compileAndExecute) {
            return;
        }
    }

    if (impl_->state->isEnabled(GL_COLOR_MATERIAL)) {
        const GLenum mode = impl_->material.colorMaterialMode;
        const bool colorSlot =
            mode == pname ||
            (mode == GL_AMBIENT_AND_DIFFUSE &&
             (pname == GL_AMBIENT || pname == GL_DIFFUSE || pname == GL_AMBIENT_AND_DIFFUSE));
        if (colorSlot) {
            return;
        }
    }

    const auto writeSlot = [&](Impl::FixedFunctionMaterial& material) {
        const auto write4 = [&](float* dst) {
            dst[0] = params[0];
            dst[1] = params[1];
            dst[2] = params[2];
            dst[3] = params[3];
        };
        switch (pname) {
            case GL_AMBIENT:
                write4(material.ambient);
                break;
            case GL_DIFFUSE:
                write4(material.diffuse);
                break;
            case GL_SPECULAR:
                write4(material.specular);
                break;
            case GL_EMISSION:
                write4(material.emission);
                break;
            case GL_AMBIENT_AND_DIFFUSE:
                write4(material.ambient);
                write4(material.diffuse);
                break;
            case GL_SHININESS:
                material.shininess = params[0];
                break;
            default:
                break;
        }
    };
    if (face == GL_FRONT || face == GL_FRONT_AND_BACK) {
        writeSlot(impl_->material.front);
    }
    if (face == GL_BACK || face == GL_FRONT_AND_BACK) {
        writeSlot(impl_->material.back);
    }
}

void GLContext::getMaterialFloatCompat(GLenum face, GLenum pname, GLfloat* params) const {
    if (params == nullptr) {
        return;
    }
    if (face != GL_FRONT && face != GL_BACK) {
        const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM, "glGetMaterialfv", "face is invalid");
        return;
    }
    const auto& material = face == GL_BACK ? impl_->material.back : impl_->material.front;
    const float* src = nullptr;
    switch (pname) {
        case GL_AMBIENT:
            src = material.ambient;
            break;
        case GL_DIFFUSE:
            src = material.diffuse;
            break;
        case GL_SPECULAR:
            src = material.specular;
            break;
        case GL_EMISSION:
            src = material.emission;
            break;
        case GL_SHININESS:
            params[0] = material.shininess;
            return;
        default:
            const_cast<GLContext*>(this)->pushError(GL_INVALID_ENUM, "glGetMaterialfv", "pname is invalid");
            return;
    }
    params[0] = src[0];
    params[1] = src[1];
    params[2] = src[2];
    params[3] = src[3];
}

void GLContext::getMaterialIntegerCompat(GLenum face, GLenum pname, GLint* params) const {
    if (params == nullptr) {
        return;
    }
    GLfloat values[4] = {};
    getMaterialFloatCompat(face, pname, values);
    params[0] = static_cast<GLint>(values[0]);
    if (pname != GL_SHININESS) {
        params[1] = static_cast<GLint>(values[1]);
        params[2] = static_cast<GLint>(values[2]);
        params[3] = static_cast<GLint>(values[3]);
    }
}

void GLContext::selectBufferCompat(GLsizei size, GLuint* buffer) {
    if (size < 0) {
        pushError(GL_INVALID_VALUE, "glSelectBuffer",
                  "size must be non-negative");
        return;
    }
    if (impl_->selection.renderMode == GL_SELECT) {
        pushError(GL_INVALID_OPERATION, "glSelectBuffer",
                  "cannot change select buffer while in GL_SELECT mode");
        return;
    }
    auto& sel = impl_->selection;
    sel.buffer = buffer;
    sel.bufferSize = size;
    sel.writeOffset = 0;
    sel.hitCount = 0;
    sel.overflow = false;
    sel.pendingHit = false;
    sel.pendingNames.clear();
    sel.pendingMinZ = 0xffffffffu;
    sel.pendingMaxZ = 0u;
}

void GLContext::flushSelectHitCompat() {
    auto& sel = impl_->selection;
    if (!sel.pendingHit) {
        return;
    }
    const GLsizei nameCount =
        static_cast<GLsizei>(sel.pendingNames.size());
    const GLsizei required = 3 + nameCount;
    if (sel.buffer == nullptr ||
        sel.writeOffset < 0 ||
        required < 0 ||
        sel.writeOffset > sel.bufferSize ||
        required > sel.bufferSize - sel.writeOffset) {
        sel.overflow = true;
    } else {
        GLuint* out = sel.buffer + sel.writeOffset;
        out[0] = static_cast<GLuint>(nameCount);
        out[1] = sel.pendingMinZ;
        out[2] = sel.pendingMaxZ;
        for (GLsizei i = 0; i < nameCount; ++i) {
            out[3 + i] = sel.pendingNames[static_cast<std::size_t>(i)];
        }
        sel.writeOffset += required;
    }
    ++sel.hitCount;
    sel.pendingHit = false;
    sel.pendingNames.clear();
    sel.pendingMinZ = 0xffffffffu;
    sel.pendingMaxZ = 0u;
}

void GLContext::recordSelectHitCompat(GLuint minDepth, GLuint maxDepth) {
    auto& sel = impl_->selection;
    if (sel.renderMode != GL_SELECT) {
        return;
    }
    if (minDepth > maxDepth) {
        std::swap(minDepth, maxDepth);
    }
    if (sel.pendingHit && sel.pendingNames == sel.nameStack) {
        sel.pendingMinZ = std::min(sel.pendingMinZ, minDepth);
        sel.pendingMaxZ = std::max(sel.pendingMaxZ, maxDepth);
        return;
    }
    flushSelectHitCompat();
    sel.pendingHit = true;
    sel.pendingNames = sel.nameStack;
    sel.pendingMinZ = minDepth;
    sel.pendingMaxZ = maxDepth;
}

GLint GLContext::renderModeCompat(GLenum mode) {
    if (mode != GL_RENDER && mode != GL_SELECT && mode != GL_FEEDBACK) {
        pushError(GL_INVALID_ENUM, "glRenderMode",
                  "mode is not GL_RENDER, GL_SELECT, or GL_FEEDBACK");
        return 0;
    }
    auto& sel = impl_->selection;
    const GLenum previous = sel.renderMode;
    GLint result = 0;
    if (previous == GL_SELECT) {
        flushSelectHitCompat();
        result = sel.overflow ? -sel.hitCount : sel.hitCount;
    }
    sel.renderMode = mode;
    if (mode == GL_SELECT) {
        sel.writeOffset = 0;
        sel.hitCount = 0;
        sel.overflow = false;
        sel.pendingHit = false;
        sel.pendingNames.clear();
        sel.pendingMinZ = 0xffffffffu;
        sel.pendingMaxZ = 0u;
    }
    return result;
}

void GLContext::initNamesCompat() {
    if (impl_->selection.renderMode == GL_SELECT) {
        flushSelectHitCompat();
    }
    impl_->selection.nameStack.clear();
}

void GLContext::pushNameCompat(GLuint name) {
    auto& sel = impl_->selection;
    if (sel.renderMode == GL_SELECT) {
        flushSelectHitCompat();
    }
    if (sel.nameStack.size() >=
        static_cast<std::size_t>(Impl::kMaxSelectNameStackDepth)) {
        pushError(GL_STACK_OVERFLOW, "glPushName",
                  "select name stack is full");
        return;
    }
    sel.nameStack.push_back(name);
}

void GLContext::popNameCompat() {
    auto& sel = impl_->selection;
    if (sel.renderMode == GL_SELECT) {
        flushSelectHitCompat();
    }
    if (sel.nameStack.empty()) {
        pushError(GL_STACK_UNDERFLOW, "glPopName",
                  "select name stack is empty");
        return;
    }
    sel.nameStack.pop_back();
}

void GLContext::loadNameCompat(GLuint name) {
    auto& sel = impl_->selection;
    if (sel.renderMode == GL_SELECT) {
        flushSelectHitCompat();
    }
    if (sel.nameStack.empty()) {
        pushError(GL_INVALID_OPERATION, "glLoadName",
                  "select name stack is empty");
        return;
    }
    sel.nameStack.back() = name;
}

bool GLContext::copyPixelsCompat(GLint x,
                                 GLint y,
                                 GLsizei width,
                                 GLsizei height,
                                 GLenum type) {
    if (width < 0 || height < 0) {
        pushError(GL_INVALID_VALUE, "glCopyPixels",
                  "width and height must be non-negative");
        return false;
    }
    if (type != GL_COLOR && type != GL_DEPTH &&
        type != GL_STENCIL && type != GL_DEPTH_STENCIL) {
        pushError(GL_INVALID_ENUM, "glCopyPixels",
                  "type is not GL_COLOR, GL_DEPTH, GL_STENCIL, or GL_DEPTH_STENCIL");
        return false;
    }
    if (width == 0 || height == 0 || !impl_->fixedFunctionRasterPositionValid) {
        return true;
    }
    const GLfloat zoomX = impl_->fixedFunctionPixelZoomX;
    const GLfloat zoomY = impl_->fixedFunctionPixelZoomY;
    if (zoomX == 0.0f || zoomY == 0.0f) {
        return true;
    }

    if (type != GL_COLOR && impl_->state->boundReadFramebuffer() == 0 &&
        impl_->state->boundDrawFramebuffer() == 0) {
        const bool copyDepth =
            type == GL_DEPTH || type == GL_DEPTH_STENCIL;
        const bool copyStencil =
            type == GL_STENCIL || type == GL_DEPTH_STENCIL;
        impl_->ensureDefaultFramebufferDepthStencilShadow();
        if ((copyDepth && !impl_->defaultFramebufferDepthShadowValid) ||
            (copyStencil && !impl_->defaultFramebufferStencilShadowValid)) {
            return true;
        }

        const std::size_t pixelCount =
            static_cast<std::size_t>(width) *
            static_cast<std::size_t>(height);
        std::vector<GLfloat> sourceDepth;
        std::vector<std::uint8_t> sourceStencil;
        if (copyDepth) {
            sourceDepth.resize(pixelCount);
            if (!impl_->copyDefaultFramebufferDepthPixels(
                    x, y, width, height, sourceDepth.data())) {
                return true;
            }
        }
        if (copyStencil) {
            sourceStencil.resize(pixelCount);
            if (!impl_->copyDefaultFramebufferStencilPixels(
                    x, y, width, height, sourceStencil.data())) {
                return true;
            }
        }

        auto insideScissor = [&](GLint dstX, GLint dstY) -> bool {
            if (!impl_->state->isEnabled(GL_SCISSOR_TEST)) {
                return true;
            }
            const auto& sc = impl_->state->scissor();
            return dstX >= sc.x && dstY >= sc.y &&
                   dstX < sc.x + sc.width &&
                   dstY < sc.y + sc.height;
        };

        auto depthPasses = [&](GLfloat incoming, GLfloat current) {
            if (!impl_->state->isEnabled(GL_DEPTH_TEST)) {
                return true;
            }
            switch (impl_->state->depthState().func) {
                case GL_NEVER:    return false;
                case GL_LESS:     return incoming < current;
                case GL_LEQUAL:   return incoming <= current;
                case GL_GREATER:  return incoming > current;
                case GL_GEQUAL:   return incoming >= current;
                case GL_EQUAL:    return incoming == current;
                case GL_NOTEQUAL: return incoming != current;
                case GL_ALWAYS:
                default:          return true;
            }
        };

        const auto& stencilFace = impl_->state->stencilState().front;
        const std::uint8_t stencilWriteMask =
            static_cast<std::uint8_t>(stencilFace.writeMask & 0xffu);
        const bool depthWrite =
            copyDepth && impl_->state->depthState().writeMask != GL_FALSE;
        GLint touchedMinX = std::numeric_limits<GLint>::max();
        GLint touchedMinY = std::numeric_limits<GLint>::max();
        GLint touchedMaxX = std::numeric_limits<GLint>::min();
        GLint touchedMaxY = std::numeric_limits<GLint>::min();
        auto noteTouched = [&](GLint dstX, GLint dstY) {
            touchedMinX = std::min(touchedMinX, dstX);
            touchedMinY = std::min(touchedMinY, dstY);
            touchedMaxX = std::max(touchedMaxX, dstX);
            touchedMaxY = std::max(touchedMaxY, dstY);
        };
        const GLfloat baseX = impl_->fixedFunctionRasterPosition[0];
        const GLfloat baseY = impl_->fixedFunctionRasterPosition[1];
        for (GLsizei srcY = 0; srcY < height; ++srcY) {
            GLint y0 = 0;
            GLint y1 = 0;
            appglPixelZoomSpan(baseY + static_cast<GLfloat>(srcY) * zoomY,
                               baseY + static_cast<GLfloat>(srcY + 1) * zoomY,
                               y0,
                               y1);
            y0 = std::max<GLint>(y0, 0);
            y1 = std::min<GLint>(
                y1,
                impl_->defaultFramebufferDepthStencilShadowHeight);
            if (y0 >= y1) {
                continue;
            }
            for (GLsizei srcX = 0; srcX < width; ++srcX) {
                GLint x0 = 0;
                GLint x1 = 0;
                appglPixelZoomSpan(baseX + static_cast<GLfloat>(srcX) * zoomX,
                                   baseX + static_cast<GLfloat>(srcX + 1) * zoomX,
                                   x0,
                                   x1);
                x0 = std::max<GLint>(x0, 0);
                x1 = std::min<GLint>(
                    x1,
                    impl_->defaultFramebufferDepthStencilShadowWidth);
                if (x0 >= x1) {
                    continue;
                }
                const std::size_t srcOffset =
                    static_cast<std::size_t>(srcY) *
                    static_cast<std::size_t>(width) +
                    static_cast<std::size_t>(srcX);
                for (GLint dstY = y0; dstY < y1; ++dstY) {
                    for (GLint dstX = x0; dstX < x1; ++dstX) {
                        if (!insideScissor(dstX, dstY)) {
                            continue;
                        }
                        const std::size_t dstOffset =
                            static_cast<std::size_t>(dstY) *
                            static_cast<std::size_t>(
                                impl_->defaultFramebufferDepthStencilShadowWidth) +
                            static_cast<std::size_t>(dstX);

                        bool depthPassed = true;
                        if (copyDepth) {
                            depthPassed = depthPasses(
                                sourceDepth[srcOffset],
                                impl_->defaultFramebufferDepth32[dstOffset]);
                            if (depthPassed && depthWrite) {
                                impl_->defaultFramebufferDepth32[dstOffset] =
                                    sourceDepth[srcOffset];
                            }
                        }
                        if (copyStencil && depthPassed) {
                            impl_->defaultFramebufferStencil8[dstOffset] =
                                static_cast<std::uint8_t>(
                                    (impl_->defaultFramebufferStencil8[dstOffset] &
                                     ~stencilWriteMask) |
                                    (sourceStencil[srcOffset] & stencilWriteMask));
                        }
                        if (depthPassed) {
                            noteTouched(dstX, dstY);
                        }
                    }
                }
            }
        }

        if (copyDepth) {
            impl_->defaultFramebufferDepthShadowValid = true;
        }
        if (copyStencil) {
            impl_->defaultFramebufferStencilShadowValid = true;
        }
        const bool touchedPixels = touchedMinX <= touchedMaxX &&
                                  touchedMinY <= touchedMaxY;
        if (impl_->frameGraph != nullptr && touchedPixels) {
            const GLint minX = touchedMinX;
            const GLint minY = touchedMinY;
            const GLint maxX = touchedMaxX + 1;
            const GLint maxY = touchedMaxY + 1;
            const GLsizei uploadWidth = maxX - minX;
            const GLsizei uploadHeight = maxY - minY;
            std::vector<GLfloat> depthUpload;
            if (copyDepth) {
                depthUpload.resize(
                    static_cast<std::size_t>(uploadWidth) *
                    static_cast<std::size_t>(uploadHeight));
                for (GLsizei row = 0; row < uploadHeight; ++row) {
                    const std::size_t srcOffset =
                        static_cast<std::size_t>(minY + row) *
                        static_cast<std::size_t>(
                            impl_->defaultFramebufferDepthStencilShadowWidth) +
                        static_cast<std::size_t>(minX);
                    const std::size_t dstOffset =
                        static_cast<std::size_t>(row) *
                        static_cast<std::size_t>(uploadWidth);
                    std::memcpy(depthUpload.data() + dstOffset,
                                impl_->defaultFramebufferDepth32.data() +
                                    srcOffset,
                                static_cast<std::size_t>(uploadWidth) *
                                    sizeof(GLfloat));
                }
            }
            bool uniformStencil = copyStencil;
            std::uint8_t stencilValue = 0;
            if (copyStencil) {
                const std::size_t firstOffset =
                    static_cast<std::size_t>(minY) *
                    static_cast<std::size_t>(
                        impl_->defaultFramebufferDepthStencilShadowWidth) +
                    static_cast<std::size_t>(minX);
                stencilValue = impl_->defaultFramebufferStencil8[firstOffset];
                for (GLsizei row = 0; row < uploadHeight && uniformStencil; ++row) {
                    for (GLsizei col = 0; col < uploadWidth; ++col) {
                        const std::size_t offset =
                            static_cast<std::size_t>(minY + row) *
                            static_cast<std::size_t>(
                                impl_->defaultFramebufferDepthStencilShadowWidth) +
                            static_cast<std::size_t>(minX + col);
                        if (impl_->defaultFramebufferStencil8[offset] !=
                            stencilValue) {
                            uniformStencil = false;
                            break;
                        }
                    }
                }
            }
            if (!copyStencil || uniformStencil) {
                (void)impl_->frameGraph->writeDefaultDepthStencilRegion(
                    minX, minY, uploadWidth, uploadHeight,
                    copyDepth ? depthUpload.data() : nullptr,
                    copyDepth, stencilValue, copyStencil);
            }
        }
        return true;
    }

    if (type != GL_COLOR) {
        return true;
    }
    if (impl_->state->isEnabled(GL_BLEND) ||
        impl_->state->isEnabled(GL_DEPTH_TEST) ||
        impl_->state->isEnabled(GL_STENCIL_TEST)) {
        return true;
    }
    const bool logicOpEnabled = impl_->state->isEnabled(GL_COLOR_LOGIC_OP);
    if (logicOpEnabled &&
        impl_->fixedFunctionLogicOp != GL_COPY &&
        impl_->fixedFunctionLogicOp != GL_XOR) {
        return true;
    }

    const GLBlendState& blend = impl_->state->blendState();
    if (blend.colorMask[0] == GL_FALSE &&
        blend.colorMask[1] == GL_FALSE &&
        blend.colorMask[2] == GL_FALSE &&
        blend.colorMask[3] == GL_FALSE) {
        return true;
    }

    const bool readDefaultFramebuffer =
        impl_->state->boundReadFramebuffer() == 0;
    const bool drawDefaultFramebuffer =
        impl_->state->boundDrawFramebuffer() == 0;
    if (!readDefaultFramebuffer || !drawDefaultFramebuffer) {
        const bool fullColorMask =
            blend.colorMask[0] != GL_FALSE &&
            blend.colorMask[1] != GL_FALSE &&
            blend.colorMask[2] != GL_FALSE &&
            blend.colorMask[3] != GL_FALSE;
        if (!fullColorMask ||
            (logicOpEnabled && impl_->fixedFunctionLogicOp != GL_COPY) ||
            impl_->boundReadFramebufferHasMultipleViews()) {
            return true;
        }

        GLint dstX0 = 0;
        GLint dstX1 = 0;
        GLint dstY0 = 0;
        GLint dstY1 = 0;
        const GLfloat baseX = impl_->fixedFunctionRasterPosition[0];
        const GLfloat baseY = impl_->fixedFunctionRasterPosition[1];
        appglPixelZoomSpan(baseX,
                           baseX + static_cast<GLfloat>(width) * zoomX,
                           dstX0,
                           dstX1);
        appglPixelZoomSpan(baseY,
                           baseY + static_cast<GLfloat>(height) * zoomY,
                           dstY0,
                           dstY1);
        if (dstX0 == dstX1 || dstY0 == dstY1) {
            return true;
        }
        (void)impl_->blitFramebuffer(x, y, x + width, y + height,
                                      dstX0, dstY0, dstX1, dstY1,
                                      GL_COLOR_BUFFER_BIT, GL_NEAREST);
        return true;
    }

    impl_->materializeDefaultFbShadowClear();
    std::vector<std::uint8_t> source(
        static_cast<std::size_t>(width) *
        static_cast<std::size_t>(height) * 4u);
    bool sourceFromShadow = impl_->copyDefaultFramebufferShadowPixels(
        x, y, width, height, source.data());
    if (!sourceFromShadow) {
        impl_->encodePendingWork();
        if (impl_->frameGraph == nullptr) {
            return true;
        }
        impl_->frameGraph->flushForReadback();
        if (!impl_->frameGraph->copyRGBA8Pixels(
                x, y, width, height, source.data())) {
            return true;
        }
    }

    impl_->ensureDefaultFramebufferShadow();
    impl_->materializeDefaultFbShadowClear();
    if (!sourceFromShadow) {
        for (GLsizei srcRow = 0; srcRow < height; ++srcRow) {
            const GLint shadowY = y + srcRow;
            if (shadowY < 0 ||
                shadowY >= impl_->defaultFramebufferShadowHeight) {
                continue;
            }
            for (GLsizei srcCol = 0; srcCol < width; ++srcCol) {
                const GLint shadowX = x + srcCol;
                if (shadowX < 0 ||
                    shadowX >= impl_->defaultFramebufferShadowWidth) {
                    continue;
                }
                const std::size_t srcOffset =
                    (static_cast<std::size_t>(srcRow) *
                     static_cast<std::size_t>(width) +
                     static_cast<std::size_t>(srcCol)) * 4u;
                const std::size_t shadowOffset =
                    (static_cast<std::size_t>(shadowY) *
                     static_cast<std::size_t>(impl_->defaultFramebufferShadowWidth) +
                     static_cast<std::size_t>(shadowX)) * 4u;
                std::memcpy(impl_->defaultFramebufferRGBA8.data() + shadowOffset,
                            source.data() + srcOffset,
                            4u);
            }
        }
    }
    auto insideScissor = [&](GLint dstX, GLint dstY) -> bool {
        if (!impl_->state->isEnabled(GL_SCISSOR_TEST)) {
            return true;
        }
        const auto& sc = impl_->state->scissor();
        return dstX >= sc.x && dstY >= sc.y &&
               dstX < sc.x + sc.width &&
               dstY < sc.y + sc.height;
    };

    const GLfloat baseX = impl_->fixedFunctionRasterPosition[0];
    const GLfloat baseY = impl_->fixedFunctionRasterPosition[1];
    bool touchedPixels = false;
    for (GLsizei srcY = 0; srcY < height; ++srcY) {
        GLint y0 = 0;
        GLint y1 = 0;
        appglPixelZoomSpan(baseY + static_cast<GLfloat>(srcY) * zoomY,
                           baseY + static_cast<GLfloat>(srcY + 1) * zoomY,
                           y0,
                           y1);
        y0 = std::max<GLint>(y0, 0);
        y1 = std::min<GLint>(y1, impl_->defaultFramebufferShadowHeight);
        if (y0 >= y1) {
            continue;
        }
        for (GLsizei srcX = 0; srcX < width; ++srcX) {
            GLint x0 = 0;
            GLint x1 = 0;
            appglPixelZoomSpan(baseX + static_cast<GLfloat>(srcX) * zoomX,
                               baseX + static_cast<GLfloat>(srcX + 1) * zoomX,
                               x0,
                               x1);
            x0 = std::max<GLint>(x0, 0);
            x1 = std::min<GLint>(x1, impl_->defaultFramebufferShadowWidth);
            if (x0 >= x1) {
                continue;
            }
            const std::size_t srcOffset =
                (static_cast<std::size_t>(srcY) *
                 static_cast<std::size_t>(width) +
                 static_cast<std::size_t>(srcX)) * 4u;
            for (GLint dstY = y0; dstY < y1; ++dstY) {
                for (GLint dstX = x0; dstX < x1; ++dstX) {
                    if (!insideScissor(dstX, dstY)) {
                        continue;
                    }
                    const std::size_t dstOffset =
                        (static_cast<std::size_t>(dstY) *
                         static_cast<std::size_t>(impl_->defaultFramebufferShadowWidth) +
                         static_cast<std::size_t>(dstX)) * 4u;
                    for (int c = 0; c < 4; ++c) {
                        if (blend.colorMask[c] != GL_FALSE) {
                            const std::uint8_t src =
                                source[srcOffset + static_cast<std::size_t>(c)];
                            const std::uint8_t dst =
                                impl_->defaultFramebufferRGBA8[
                                    dstOffset + static_cast<std::size_t>(c)];
                            const std::uint8_t out =
                                logicOpEnabled && impl_->fixedFunctionLogicOp == GL_XOR
                                    ? static_cast<std::uint8_t>(src ^ dst)
                                    : src;
                            impl_->defaultFramebufferRGBA8[
                                dstOffset + static_cast<std::size_t>(c)] =
                                out;
                        }
                    }
                    touchedPixels = true;
                }
            }
        }
    }
    if (!touchedPixels) {
        return true;
    }
    impl_->defaultFramebufferShadowValid = true;
    return true;
}

bool GLContext::setLegacyClientArrayPointer(GLenum array,
                                            GLint size,
                                            GLenum type,
                                            GLsizei stride,
                                            const void* pointer) {
    Impl::LegacyClientArray* state = nullptr;
    GLint minSize = 0;
    GLint maxSize = 0;
    const char* label = nullptr;
    switch (array) {
        case GL_VERTEX_ARRAY:
            state = &impl_->legacyVertexArray;
            minSize = 2;
            maxSize = 4;
            label = "glVertexPointer";
            break;
        case GL_COLOR_ARRAY:
            state = &impl_->legacyColorArray;
            minSize = 3;
            maxSize = 4;
            label = "glColorPointer";
            break;
        case GL_TEXTURE_COORD_ARRAY:
            state = &impl_->legacyTexCoordArray;
            minSize = 1;
            maxSize = 4;
            label = "glTexCoordPointer";
            break;
        default:
            pushError(GL_INVALID_ENUM, "glClientArrayPointer",
                      "array is not GL_VERTEX_ARRAY, GL_COLOR_ARRAY, or GL_TEXTURE_COORD_ARRAY");
            return false;
    }
    if (size < minSize || size > maxSize) {
        pushError(GL_INVALID_VALUE, label, "array size is outside the supported compat range");
        return false;
    }
    if (stride < 0) {
        pushError(GL_INVALID_VALUE, label, "stride must be non-negative");
        return false;
    }
    state->size = size;
    state->type = type;
    state->stride = stride;
    state->pointer = pointer;
    state->bufferName = impl_->state->boundBuffer(GL_ARRAY_BUFFER);
    return true;
}

bool GLContext::setLegacyClientArrayEnabled(GLenum array, bool enabled) {
    switch (array) {
        case GL_VERTEX_ARRAY:
            impl_->legacyVertexArray.enabled = enabled;
            return true;
        case GL_COLOR_ARRAY:
            impl_->legacyColorArray.enabled = enabled;
            return true;
        case GL_TEXTURE_COORD_ARRAY:
            impl_->legacyTexCoordArray.enabled = enabled;
            return true;
        case GL_NORMAL_ARRAY:
            // Accepted as a no-op for legacy fixed-function tests that
            // deliberately bind an unused normal array.
            return true;
        default:
            pushError(GL_INVALID_ENUM, enabled ? "glEnableClientState" : "glDisableClientState",
                      "array is not GL_VERTEX_ARRAY, GL_COLOR_ARRAY, GL_TEXTURE_COORD_ARRAY, or GL_NORMAL_ARRAY");
            return false;
    }
}

bool GLContext::isLegacyClientArrayEnabled(GLenum array) const {
    switch (array) {
        case GL_VERTEX_ARRAY:
            return impl_->legacyVertexArray.enabled;
        case GL_COLOR_ARRAY:
            return impl_->legacyColorArray.enabled;
        case GL_TEXTURE_COORD_ARRAY:
            return impl_->legacyTexCoordArray.enabled;
        default:
            return false;
    }
}

void GLContext::pushMatrixCompat() {
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::PushMatrix;
        impl_->displayLists.compileCommands.push_back(command);
        if (!impl_->displayLists.compileAndExecute) {
            return;
        }
    }
    if (!matrixState().pushMatrix()) {
        pushError(GL_STACK_OVERFLOW, "glPushMatrix",
                  "matrix stack would exceed maximum depth");
    }
}

void GLContext::popMatrixCompat() {
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::PopMatrix;
        impl_->displayLists.compileCommands.push_back(command);
        if (!impl_->displayLists.compileAndExecute) {
            return;
        }
    }
    if (!matrixState().popMatrix()) {
        pushError(GL_STACK_UNDERFLOW, "glPopMatrix",
                  "matrix stack would underflow below the implicit identity entry");
    }
}

void GLContext::beginImmediate(GLenum mode) {
    switch (mode) {
        case GL_TRIANGLES:
        case GL_TRIANGLE_STRIP:
        case GL_TRIANGLE_FAN:
        case GL_QUADS:
        case GL_QUAD_STRIP:
        case GL_POLYGON:
        case GL_LINES:
        case GL_LINE_STRIP:
        case GL_LINE_LOOP:
        case GL_POINTS:
            break;
        default:
            if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
                Impl::DisplayListCommand command;
                command.kind = Impl::DisplayListCommand::Kind::InvalidBegin;
                command.enumValue = mode;
                impl_->displayLists.compileCommands.push_back(command);
                impl_->immediate.suppressNextInvalidEnd = true;
            }
            pushError(GL_INVALID_ENUM);
            return;
    }
    if (impl_->immediate.active) {
        // Nested glBegin is invalid in the GL spec.
        pushError(GL_INVALID_OPERATION);
        return;
    }
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::Begin;
        command.enumValue = mode;
        impl_->displayLists.compileCommands.push_back(command);
    }
    impl_->immediate.active = true;
    impl_->immediate.suppressNextInvalidEnd = false;
    impl_->immediate.mode = mode;
    impl_->immediate.vertices.clear();
    impl_->immediate.materialSnapshots.clear();
}

void GLContext::immediateVertex(float x, float y, float z, float w) {
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::Vertex;
        command.values[0] = x;
        command.values[1] = y;
        command.values[2] = z;
        command.values[3] = w;
        impl_->displayLists.compileCommands.push_back(command);
        if (!impl_->displayLists.compileAndExecute) {
            return;
        }
    }
    if (!impl_->immediate.active) {
        // glVertex* outside glBegin/glEnd is silently ignored per GL 1.x.
        // During list compilation it must still be recorded for replay.
        return;
    }
    Impl::ImmediateModeVertex v;
    v.position[0] = x;
    v.position[1] = y;
    v.position[2] = z;
    v.position[3] = w;
    v.color[0] = impl_->immediate.currentColor[0];
    v.color[1] = impl_->immediate.currentColor[1];
    v.color[2] = impl_->immediate.currentColor[2];
    v.color[3] = impl_->immediate.currentColor[3];
    v.texcoord[0] = impl_->immediate.currentTexcoord[0];
    v.texcoord[1] = impl_->immediate.currentTexcoord[1];
    v.texcoord[2] = impl_->immediate.currentTexcoord[2];
    v.texcoord[3] = impl_->immediate.currentTexcoord[3];
    impl_->immediate.vertices.push_back(v);

    Impl::ImmediateModeMaterialSnapshot materialSnapshot;
    materialSnapshot.valid = true;
    std::memcpy(materialSnapshot.frontAmbient,
                impl_->material.front.ambient,
                sizeof(materialSnapshot.frontAmbient));
    std::memcpy(materialSnapshot.frontDiffuse,
                impl_->material.front.diffuse,
                sizeof(materialSnapshot.frontDiffuse));
    std::memcpy(materialSnapshot.frontSpecular,
                impl_->material.front.specular,
                sizeof(materialSnapshot.frontSpecular));
    std::memcpy(materialSnapshot.frontEmission,
                impl_->material.front.emission,
                sizeof(materialSnapshot.frontEmission));
    std::memcpy(materialSnapshot.backAmbient,
                impl_->material.back.ambient,
                sizeof(materialSnapshot.backAmbient));
    std::memcpy(materialSnapshot.backDiffuse,
                impl_->material.back.diffuse,
                sizeof(materialSnapshot.backDiffuse));
    std::memcpy(materialSnapshot.backSpecular,
                impl_->material.back.specular,
                sizeof(materialSnapshot.backSpecular));
    std::memcpy(materialSnapshot.backEmission,
                impl_->material.back.emission,
                sizeof(materialSnapshot.backEmission));
    impl_->immediate.materialSnapshots.push_back(materialSnapshot);
}

void GLContext::immediateColor(float r, float g, float b, float a) {
    // Per GL 1.x spec, glColor* is valid outside begin/end and simply
    // updates the current color register; it's read by the next glVertex*
    // inside a begin/end pair.
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::Color;
        command.values[0] = r;
        command.values[1] = g;
        command.values[2] = b;
        command.values[3] = a;
        impl_->displayLists.compileCommands.push_back(command);
        if (!impl_->displayLists.compileAndExecute) {
            return;
        }
    }
    impl_->immediate.currentColor[0] = r;
    impl_->immediate.currentColor[1] = g;
    impl_->immediate.currentColor[2] = b;
    impl_->immediate.currentColor[3] = a;
    if (impl_->state->isEnabled(GL_COLOR_MATERIAL)) {
        const GLenum face = impl_->material.colorMaterialFace;
        const GLenum mode = impl_->material.colorMaterialMode;
        const auto write4 = [&](float* dst) {
            dst[0] = r;
            dst[1] = g;
            dst[2] = b;
            dst[3] = a;
        };
        const auto applyTo = [&](Impl::FixedFunctionMaterial& material) {
            switch (mode) {
                case GL_AMBIENT:
                    write4(material.ambient);
                    break;
                case GL_DIFFUSE:
                    write4(material.diffuse);
                    break;
                case GL_SPECULAR:
                    write4(material.specular);
                    break;
                case GL_EMISSION:
                    write4(material.emission);
                    break;
                case GL_AMBIENT_AND_DIFFUSE:
                    write4(material.ambient);
                    write4(material.diffuse);
                    break;
                default:
                    break;
            }
        };
        if (face == GL_FRONT || face == GL_FRONT_AND_BACK) {
            applyTo(impl_->material.front);
        }
        if (face == GL_BACK || face == GL_FRONT_AND_BACK) {
            applyTo(impl_->material.back);
        }
    }
}

void GLContext::immediateTexCoord(unsigned int unit, float s, float t, float r, float q) {
    if (unit < Impl::kCompatRasterTextureUnits) {
        impl_->fixedFunctionCurrentTexcoords[unit] = {s, t, r, q};
    }
    // Only texture unit 0 is captured for the built-in immediate-mode
    // pipeline (Chobby/Chili UI only uses unit 0). Multi-texturing on
    // other units is silently ignored — this matches the single-
    // sampler pipeline we build in MetalFrameGraph.
    if (unit != 0) {
        return;
    }
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::TexCoord;
        command.values[0] = s;
        command.values[1] = t;
        command.values[2] = r;
        command.values[3] = q;
        impl_->displayLists.compileCommands.push_back(command);
        if (!impl_->displayLists.compileAndExecute) {
            return;
        }
    }
    impl_->immediate.currentTexcoord[0] = s;
    impl_->immediate.currentTexcoord[1] = t;
    impl_->immediate.currentTexcoord[2] = r;
    impl_->immediate.currentTexcoord[3] = q;
}

void GLContext::endImmediate() {
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        if (impl_->immediate.suppressNextInvalidEnd) {
            impl_->immediate.suppressNextInvalidEnd = false;
            return;
        }
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::End;
        impl_->displayLists.compileCommands.push_back(command);
        if (!impl_->displayLists.compileAndExecute) {
            impl_->immediate.active = false;
            impl_->immediate.suppressNextInvalidEnd = false;
            impl_->immediate.vertices.clear();
            impl_->immediate.materialSnapshots.clear();
            return;
        }
    }
    if (!impl_->immediate.active) {
        pushError(GL_INVALID_OPERATION);
        return;
    }
    impl_->immediate.active = false;

    const GLenum mode = impl_->immediate.mode;
    auto& captured = impl_->immediate.vertices;
    auto& capturedMaterials = impl_->immediate.materialSnapshots;
    if (captured.empty()) {
        return;
    }

    const Matrix4 mvp = impl_->matrixState.modelViewProjection();
    auto recordSelectPrimitives = [&](GLenum primitiveMode,
                                      const Impl::ImmediateModeVertex* verts,
                                      std::size_t count) {
        if (verts == nullptr || count == 0 ||
            impl_->selection.renderMode != GL_SELECT) {
            return;
        }
        struct SelectVertex {
            float x = 0.0f;
            float y = 0.0f;
            float z = 0.0f;
            bool ok = false;
        };
        const auto& dr = impl_->state->depthRange();
        auto toSelectVertex = [&](const Impl::ImmediateModeVertex& src) {
            SelectVertex out;
            float clip[4] = {};
            for (int row = 0; row < 4; ++row) {
                clip[row] =
                    mvp.m[0 * 4 + row] * src.position[0] +
                    mvp.m[1 * 4 + row] * src.position[1] +
                    mvp.m[2 * 4 + row] * src.position[2] +
                    mvp.m[3 * 4 + row] * src.position[3];
            }
            if (clip[3] == 0.0f ||
                !std::isfinite(clip[0]) ||
                !std::isfinite(clip[1]) ||
                !std::isfinite(clip[2]) ||
                !std::isfinite(clip[3])) {
                return out;
            }
            const float invW = 1.0f / clip[3];
            out.x = clip[0] * invW;
            out.y = clip[1] * invW;
            out.z = clip[2] * invW;
            out.ok = true;
            return out;
        };
        auto depthToUint = [&](float ndcZ) {
            const double windowZ =
                static_cast<double>(dr.nearValue) +
                (static_cast<double>(ndcZ) + 1.0) * 0.5 *
                    static_cast<double>(dr.farValue - dr.nearValue);
            const double clamped = std::clamp(windowZ, 0.0, 1.0);
            return static_cast<GLuint>(
                std::llround(clamped * 4294967294.0));
        };
        auto recordPrimitive = [&](std::initializer_list<const Impl::ImmediateModeVertex*> primitive) {
            float minX = std::numeric_limits<float>::infinity();
            float minY = std::numeric_limits<float>::infinity();
            float minZ = std::numeric_limits<float>::infinity();
            float maxX = -std::numeric_limits<float>::infinity();
            float maxY = -std::numeric_limits<float>::infinity();
            float maxZ = -std::numeric_limits<float>::infinity();
            for (const auto* v : primitive) {
                if (v == nullptr) {
                    return;
                }
                const SelectVertex sv = toSelectVertex(*v);
                if (!sv.ok) {
                    return;
                }
                minX = std::min(minX, sv.x);
                minY = std::min(minY, sv.y);
                minZ = std::min(minZ, sv.z);
                maxX = std::max(maxX, sv.x);
                maxY = std::max(maxY, sv.y);
                maxZ = std::max(maxZ, sv.z);
            }
            if (minX > 1.0f || maxX < -1.0f ||
                minY > 1.0f || maxY < -1.0f ||
                minZ > 1.0f || maxZ < -1.0f) {
                return;
            }
            recordSelectHitCompat(depthToUint(minZ), depthToUint(maxZ));
        };

        switch (primitiveMode) {
            case GL_POINTS:
                for (std::size_t i = 0; i < count; ++i) {
                    recordPrimitive({&verts[i]});
                }
                break;
            case GL_LINES:
                for (std::size_t i = 0; i + 1 < count; i += 2) {
                    recordPrimitive({&verts[i], &verts[i + 1]});
                }
                break;
            case GL_LINE_STRIP:
                for (std::size_t i = 0; i + 1 < count; ++i) {
                    recordPrimitive({&verts[i], &verts[i + 1]});
                }
                break;
            case GL_LINE_LOOP:
                for (std::size_t i = 0; i + 1 < count; ++i) {
                    recordPrimitive({&verts[i], &verts[i + 1]});
                }
                if (count > 2) {
                    recordPrimitive({&verts[count - 1], &verts[0]});
                }
                break;
            case GL_TRIANGLES:
                for (std::size_t i = 0; i + 2 < count; i += 3) {
                    recordPrimitive({&verts[i], &verts[i + 1], &verts[i + 2]});
                }
                break;
            case GL_TRIANGLE_STRIP:
                for (std::size_t i = 0; i + 2 < count; ++i) {
                    recordPrimitive({&verts[i], &verts[i + 1], &verts[i + 2]});
                }
                break;
            case GL_TRIANGLE_FAN:
                for (std::size_t i = 1; i + 1 < count; ++i) {
                    recordPrimitive({&verts[0], &verts[i], &verts[i + 1]});
                }
                break;
            case GL_QUADS:
                for (std::size_t i = 0; i + 3 < count; i += 4) {
                    recordPrimitive({&verts[i], &verts[i + 1],
                                     &verts[i + 2], &verts[i + 3]});
                }
                break;
            case GL_QUAD_STRIP:
                for (std::size_t i = 0; i + 3 < count; i += 2) {
                    recordPrimitive({&verts[i], &verts[i + 1],
                                     &verts[i + 3], &verts[i + 2]});
                }
                break;
            case GL_POLYGON:
                if (count >= 3) {
                    float minX = std::numeric_limits<float>::infinity();
                    float minY = std::numeric_limits<float>::infinity();
                    float minZ = std::numeric_limits<float>::infinity();
                    float maxX = -std::numeric_limits<float>::infinity();
                    float maxY = -std::numeric_limits<float>::infinity();
                    float maxZ = -std::numeric_limits<float>::infinity();
                    bool ok = true;
                    for (std::size_t i = 0; i < count; ++i) {
                        const SelectVertex sv = toSelectVertex(verts[i]);
                        if (!sv.ok) {
                            ok = false;
                            break;
                        }
                        minX = std::min(minX, sv.x);
                        minY = std::min(minY, sv.y);
                        minZ = std::min(minZ, sv.z);
                        maxX = std::max(maxX, sv.x);
                        maxY = std::max(maxY, sv.y);
                        maxZ = std::max(maxZ, sv.z);
                    }
                    if (ok &&
                        !(minX > 1.0f || maxX < -1.0f ||
                          minY > 1.0f || maxY < -1.0f ||
                          minZ > 1.0f || maxZ < -1.0f)) {
                        recordSelectHitCompat(depthToUint(minZ),
                                              depthToUint(maxZ));
                    }
                }
                break;
            default:
                break;
        }
    };
    if (impl_->selection.renderMode == GL_SELECT) {
        recordSelectPrimitives(mode, captured.data(), captured.size());
        return;
    }
    if (impl_->frameGraph == nullptr) {
        return;
    }

    std::vector<Impl::ImmediateModeVertex> expanded;
    std::vector<Impl::ImmediateModeVertex> screenExpanded;
    std::vector<Impl::ImmediateModeVertex> lineStippleSource;
    GLenum lineStippleMode = 0;
    const bool lineStippleShadowCandidate =
        impl_->state->boundDrawFramebuffer() == 0 &&
        impl_->state->isEnabled(GL_LINE_STIPPLE) &&
        !impl_->state->isEnabled(GL_COLOR_LOGIC_OP) &&
        !impl_->state->isEnabled(GL_DEPTH_TEST) &&
        !impl_->state->isEnabled(GL_STENCIL_TEST) &&
        (!impl_->state->isEnabled(GL_TEXTURE_2D) ||
         impl_->state->boundTextureOnUnit(0, GL_TEXTURE_2D) == 0) &&
        (!impl_->state->isEnabled(GL_TEXTURE_1D) ||
         impl_->state->boundTextureOnUnit(0, GL_TEXTURE_1D) == 0) &&
        (mode == GL_LINES || mode == GL_LINE_STRIP || mode == GL_LINE_LOOP) &&
        captured.size() > 1;
    if (lineStippleShadowCandidate) {
        lineStippleSource = captured;
        lineStippleMode = mode;
    }
    const Impl::ImmediateModeVertex* drawVerts = captured.data();
    std::size_t drawCount = captured.size();
    const bool haveCapturedMaterials =
        capturedMaterials.size() == captured.size();
    const Impl::ImmediateModeMaterialSnapshot* drawMaterials =
        haveCapturedMaterials ? capturedMaterials.data() : nullptr;
    GLenum drawMode = mode;
    Matrix4 drawMvp = mvp;
    const bool flat = (impl_->fixedFunctionShadeModel == GL_FLAT);
    std::vector<Impl::ImmediateModeMaterialSnapshot> expandedMaterials;
    auto materialAt = [&](std::size_t index) -> const Impl::ImmediateModeMaterialSnapshot* {
        return drawMaterials != nullptr ? &drawMaterials[index] : nullptr;
    };
    auto appendExpandedMaterial =
        [&](const Impl::ImmediateModeMaterialSnapshot* material) {
            if (drawMaterials != nullptr) {
                expandedMaterials.push_back(material != nullptr
                    ? *material
                    : Impl::ImmediateModeMaterialSnapshot{});
            }
        };
    auto appendTriangle = [&](const Impl::ImmediateModeVertex& a,
                              const Impl::ImmediateModeVertex& b,
                              const Impl::ImmediateModeVertex& c,
                              const Impl::ImmediateModeVertex& provoking,
                              const Impl::ImmediateModeMaterialSnapshot* ma,
                              const Impl::ImmediateModeMaterialSnapshot* mb,
                              const Impl::ImmediateModeMaterialSnapshot* mc,
                              const Impl::ImmediateModeMaterialSnapshot* mp) {
        Impl::ImmediateModeVertex ta = a;
        Impl::ImmediateModeVertex tb = b;
        Impl::ImmediateModeVertex tc = c;
        const auto* outMa = ma;
        const auto* outMb = mb;
        const auto* outMc = mc;
        if (flat) {
            std::memcpy(ta.color, provoking.color, sizeof(ta.color));
            std::memcpy(tb.color, provoking.color, sizeof(tb.color));
            std::memcpy(tc.color, provoking.color, sizeof(tc.color));
            outMa = mp;
            outMb = mp;
            outMc = mp;
        }
        expanded.push_back(ta);
        expanded.push_back(tb);
        expanded.push_back(tc);
        appendExpandedMaterial(outMa);
        appendExpandedMaterial(outMb);
        appendExpandedMaterial(outMc);
    };
    auto appendLine = [&](const Impl::ImmediateModeVertex& a,
                          const Impl::ImmediateModeVertex& b,
                          const Impl::ImmediateModeVertex& provoking,
                          const Impl::ImmediateModeMaterialSnapshot* ma,
                          const Impl::ImmediateModeMaterialSnapshot* mb,
                          const Impl::ImmediateModeMaterialSnapshot* mp) {
        Impl::ImmediateModeVertex ta = a;
        Impl::ImmediateModeVertex tb = b;
        const auto* outMa = ma;
        const auto* outMb = mb;
        if (flat) {
            std::memcpy(ta.color, provoking.color, sizeof(ta.color));
            std::memcpy(tb.color, provoking.color, sizeof(tb.color));
            outMa = mp;
            outMb = mp;
        }
        expanded.push_back(ta);
        expanded.push_back(tb);
        appendExpandedMaterial(outMa);
        appendExpandedMaterial(outMb);
    };
    const auto& rasterStateForPolygonMode = impl_->state->rasterState();
    auto polygonIsFrontFacing = [&](const Impl::ImmediateModeVertex* verts,
                                    std::size_t count) {
        double twiceArea = 0.0;
        for (std::size_t i = 0; i < count; ++i) {
            const auto& a = verts[i];
            const auto& b = verts[(i + 1) % count];
            twiceArea += static_cast<double>(a.position[0]) * b.position[1] -
                         static_cast<double>(b.position[0]) * a.position[1];
        }
        const bool ccw = twiceArea >= 0.0;
        return rasterStateForPolygonMode.frontFace == GL_CW ? !ccw : ccw;
    };
    auto polygonModeForFace = [&](bool frontFacing) {
        return frontFacing
            ? rasterStateForPolygonMode.polygonModeFront
            : rasterStateForPolygonMode.polygonModeBack;
    };
    auto polygonFaceCulled = [&](bool frontFacing) {
        if (!impl_->state->isEnabled(GL_CULL_FACE)) {
            return false;
        }
        switch (rasterStateForPolygonMode.cullFaceMode) {
            case GL_FRONT:
                return frontFacing;
            case GL_BACK:
                return !frontFacing;
            case GL_FRONT_AND_BACK:
                return true;
            default:
                return false;
        }
    };
    switch (mode) {
        case GL_TRIANGLES:
            if (flat) {
                expanded.reserve((captured.size() / 3) * 3);
                for (std::size_t i = 0; i + 2 < captured.size(); i += 3) {
                    appendTriangle(captured[i + 0], captured[i + 1], captured[i + 2], captured[i + 2],
                                   materialAt(i + 0), materialAt(i + 1), materialAt(i + 2), materialAt(i + 2));
                }
                drawVerts = expanded.data();
                if (drawMaterials != nullptr) {
                    drawMaterials = expandedMaterials.data();
                }
                drawCount = expanded.size();
            }
            drawMode = GL_TRIANGLES;
            break;
        case GL_TRIANGLE_STRIP:
            if (captured.size() >= 3) {
                expanded.reserve((captured.size() - 2) * 3);
                for (std::size_t i = 0; i + 2 < captured.size(); ++i) {
                    appendTriangle(captured[i + 0], captured[i + 1], captured[i + 2], captured[i + 2],
                                   materialAt(i + 0), materialAt(i + 1), materialAt(i + 2), materialAt(i + 2));
                }
                drawVerts = expanded.data();
                if (drawMaterials != nullptr) {
                    drawMaterials = expandedMaterials.data();
                }
                drawCount = expanded.size();
                drawMode = GL_TRIANGLES;
            }
            break;
        case GL_TRIANGLE_FAN:
            if (captured.size() >= 3) {
                expanded.reserve((captured.size() - 2) * 3);
                for (std::size_t i = 1; i + 1 < captured.size(); ++i) {
                    appendTriangle(captured[0], captured[i], captured[i + 1], captured[i + 1],
                                   materialAt(0), materialAt(i), materialAt(i + 1), materialAt(i + 1));
                }
                drawVerts = expanded.data();
                if (drawMaterials != nullptr) {
                    drawMaterials = expandedMaterials.data();
                }
                drawCount = expanded.size();
                drawMode = GL_TRIANGLES;
            }
            break;
        case GL_QUADS:
            expanded.reserve((captured.size() / 4) * 6);
            for (std::size_t i = 0; i + 3 < captured.size(); i += 4) {
                appendTriangle(captured[i + 0], captured[i + 1], captured[i + 2], captured[i + 3],
                               materialAt(i + 0), materialAt(i + 1), materialAt(i + 2), materialAt(i + 3));
                appendTriangle(captured[i + 0], captured[i + 2], captured[i + 3], captured[i + 3],
                               materialAt(i + 0), materialAt(i + 2), materialAt(i + 3), materialAt(i + 3));
            }
            drawVerts = expanded.data();
            if (drawMaterials != nullptr) {
                drawMaterials = expandedMaterials.data();
            }
            drawCount = expanded.size();
            drawMode = GL_TRIANGLES;
            break;
        case GL_QUAD_STRIP:
            if (captured.size() >= 4) {
                expanded.reserve(((captured.size() - 2) / 2) * 6);
                for (std::size_t i = 0; i + 3 < captured.size(); i += 2) {
                    appendTriangle(captured[i + 0], captured[i + 1], captured[i + 3], captured[i + 3],
                                   materialAt(i + 0), materialAt(i + 1), materialAt(i + 3), materialAt(i + 3));
                    appendTriangle(captured[i + 0], captured[i + 3], captured[i + 2], captured[i + 3],
                                   materialAt(i + 0), materialAt(i + 3), materialAt(i + 2), materialAt(i + 3));
                }
                drawVerts = expanded.data();
                if (drawMaterials != nullptr) {
                    drawMaterials = expandedMaterials.data();
                }
                drawCount = expanded.size();
                drawMode = GL_TRIANGLES;
            }
            break;
        case GL_POLYGON:
            if (captured.size() >= 3) {
                const bool frontFacing =
                    polygonIsFrontFacing(captured.data(), captured.size());
                if (polygonFaceCulled(frontFacing)) {
                    drawCount = 0;
                    drawMode = GL_TRIANGLES;
                    break;
                }
                switch (polygonModeForFace(frontFacing)) {
                    case GL_LINE:
                        expanded.reserve(captured.size() * 2);
                        for (std::size_t i = 0; i + 1 < captured.size(); ++i) {
                            appendLine(captured[i], captured[i + 1], captured[0],
                                       materialAt(i), materialAt(i + 1), materialAt(0));
                        }
                        appendLine(captured.back(), captured.front(), captured[0],
                                   materialAt(captured.size() - 1), materialAt(0), materialAt(0));
                        drawVerts = expanded.data();
                        if (drawMaterials != nullptr) {
                            drawMaterials = expandedMaterials.data();
                        }
                        drawCount = expanded.size();
                        drawMode = GL_LINES;
                        break;
                    case GL_POINT:
                        drawVerts = captured.data();
                        drawCount = captured.size();
                        drawMode = GL_POINTS;
                        break;
                    case GL_FILL:
                    default:
                        expanded.reserve((captured.size() - 2) * 3);
                        for (std::size_t i = 1; i + 1 < captured.size(); ++i) {
                            appendTriangle(captured[0], captured[i], captured[i + 1], captured[0],
                                           materialAt(0), materialAt(i), materialAt(i + 1), materialAt(0));
                        }
                        drawVerts = expanded.data();
                        if (drawMaterials != nullptr) {
                            drawMaterials = expandedMaterials.data();
                        }
                        drawCount = expanded.size();
                        drawMode = GL_TRIANGLES;
                        break;
                }
            }
            break;
        case GL_LINES:
            if (flat) {
                expanded.reserve((captured.size() / 2) * 2);
                for (std::size_t i = 0; i + 1 < captured.size(); i += 2) {
                    appendLine(captured[i], captured[i + 1], captured[i + 1],
                               materialAt(i), materialAt(i + 1), materialAt(i + 1));
                }
                drawVerts = expanded.data();
                if (drawMaterials != nullptr) {
                    drawMaterials = expandedMaterials.data();
                }
                drawCount = expanded.size();
            }
            drawMode = GL_LINES;
            break;
        case GL_LINE_STRIP:
            if (flat && captured.size() >= 2) {
                expanded.reserve((captured.size() - 1) * 2);
                for (std::size_t i = 0; i + 1 < captured.size(); ++i) {
                    appendLine(captured[i], captured[i + 1], captured[i + 1],
                               materialAt(i), materialAt(i + 1), materialAt(i + 1));
                }
                drawVerts = expanded.data();
                if (drawMaterials != nullptr) {
                    drawMaterials = expandedMaterials.data();
                }
                drawCount = expanded.size();
                drawMode = GL_LINES;
            }
            break;
        case GL_LINE_LOOP:
            if (captured.size() >= 2) {
                expanded.reserve(captured.size() * 2);
                for (std::size_t i = 0; i + 1 < captured.size(); ++i) {
                    appendLine(captured[i], captured[i + 1], captured[i + 1],
                               materialAt(i), materialAt(i + 1), materialAt(i + 1));
                }
                appendLine(captured.back(), captured.front(), captured.front(),
                           materialAt(captured.size() - 1), materialAt(0), materialAt(0));
                drawVerts = expanded.data();
                if (drawMaterials != nullptr) {
                    drawMaterials = expandedMaterials.data();
                }
                drawCount = expanded.size();
                drawMode = GL_LINES;
            }
            break;
        default:
            break;
    }
    std::vector<Impl::ImmediateModeVertex> fixedFunctionVertices;
    auto compatClipRejects = [&](const Impl::ImmediateModeVertex& v) {
        for (GLenum plane = GL_CLIP_PLANE0; plane <= GL_CLIP_PLANE7; ++plane) {
            if (!impl_->state->isEnabled(plane)) {
                continue;
            }
            const auto& eq = impl_->clipPlanes[static_cast<std::size_t>(plane - GL_CLIP_PLANE0)];
            const double d =
                eq[0] * static_cast<double>(v.position[0]) +
                eq[1] * static_cast<double>(v.position[1]) +
                eq[2] * static_cast<double>(v.position[2]) +
                eq[3] * static_cast<double>(v.position[3]);
            if (d < 0.0) {
                return true;
            }
        }
        return false;
    };
    auto triangleFrontFacing = [&](const Impl::ImmediateModeVertex& a,
                                   const Impl::ImmediateModeVertex& b,
                                   const Impl::ImmediateModeVertex& c) {
        const Impl::ImmediateModeVertex tri[3] = {a, b, c};
        return polygonIsFrontFacing(tri, 3);
    };
    auto applyCompatVertexState = [&](Impl::ImmediateModeVertex v,
                                      bool frontFacing,
                                      const Impl::ImmediateModeMaterialSnapshot* materialSnapshot) {
        const auto applyTexGenCoord = [&](GLenum cap, std::size_t index) {
            if (!impl_->state->isEnabled(cap) || index >= 2) {
                return;
            }
            const auto& coord = impl_->texGen[index];
            const float* plane = coord.mode == GL_OBJECT_LINEAR
                ? coord.objectPlane
                : coord.eyePlane;
            v.texcoord[index] =
                plane[0] * v.position[0] +
                plane[1] * v.position[1] +
                plane[2] * v.position[2] +
                plane[3] * v.position[3];
        };
        applyTexGenCoord(GL_TEXTURE_GEN_S, 0);
        applyTexGenCoord(GL_TEXTURE_GEN_T, 1);

        if (impl_->state->isEnabled(GL_LIGHTING)) {
            const bool useBackMaterial = impl_->lighting.twoSide && !frontFacing;
            const auto& liveMaterial = useBackMaterial
                ? impl_->material.back
                : impl_->material.front;
            Impl::FixedFunctionMaterial capturedMaterial;
            const auto* materialPtr = &liveMaterial;
            if (materialSnapshot != nullptr && materialSnapshot->valid) {
                const auto copy4 = [](float* dst, const float* src) {
                    std::memcpy(dst, src, sizeof(float) * 4);
                };
                if (useBackMaterial) {
                    copy4(capturedMaterial.ambient, materialSnapshot->backAmbient);
                    copy4(capturedMaterial.diffuse, materialSnapshot->backDiffuse);
                    copy4(capturedMaterial.specular, materialSnapshot->backSpecular);
                    copy4(capturedMaterial.emission, materialSnapshot->backEmission);
                } else {
                    copy4(capturedMaterial.ambient, materialSnapshot->frontAmbient);
                    copy4(capturedMaterial.diffuse, materialSnapshot->frontDiffuse);
                    copy4(capturedMaterial.specular, materialSnapshot->frontSpecular);
                    copy4(capturedMaterial.emission, materialSnapshot->frontEmission);
                }
                materialPtr = &capturedMaterial;
            }
            const auto& material = *materialPtr;
            float out[4] = {material.emission[0],
                            material.emission[1],
                            material.emission[2],
                            material.diffuse[3]};
            const bool useVertexColorMaterial =
                impl_->state->isEnabled(GL_COLOR_MATERIAL) &&
                impl_->material.colorMaterialMode == GL_AMBIENT_AND_DIFFUSE;
            if (useVertexColorMaterial) {
                const auto& light = impl_->lighting.lights[0];
                const float gain[3] = {
                    light.ambient[0] + light.diffuse[0],
                    light.ambient[1] + light.diffuse[1],
                    light.ambient[2] + light.diffuse[2],
                };
                for (int c = 0; c < 3; ++c) {
                    out[c] = v.color[c] * std::max(1.0f, gain[c]);
                }
                out[3] = v.color[3];
            } else {
                for (int c = 0; c < 3; ++c) {
                    out[c] += material.ambient[c] *
                        impl_->lighting.modelAmbient[c];
                }
                for (std::size_t i = 0; i < impl_->lighting.lights.size(); ++i) {
                    if (!impl_->state->isEnabled(GL_LIGHT0 + static_cast<GLenum>(i))) {
                        continue;
                    }
                    const auto& light = impl_->lighting.lights[i];
                    float spot = 1.0f;
                    if (light.spotCutoff < 180.0f) {
                        const float lx = -light.position[0];
                        const float ly = -light.position[1];
                        const float lz = -light.position[2];
                        const float llen = std::sqrt(lx * lx + ly * ly + lz * lz);
                        const float dlen = std::sqrt(
                            light.spotDirection[0] * light.spotDirection[0] +
                            light.spotDirection[1] * light.spotDirection[1] +
                            light.spotDirection[2] * light.spotDirection[2]);
                        if (llen > 0.0f && dlen > 0.0f) {
                            spot =
                                (lx / llen) * (light.spotDirection[0] / dlen) +
                                (ly / llen) * (light.spotDirection[1] / dlen) +
                                (lz / llen) * (light.spotDirection[2] / dlen);
                            constexpr float kPi = 3.14159265358979323846f;
                            const float cutoffCos =
                                std::cos(light.spotCutoff * kPi / 180.0f);
                            spot = spot >= cutoffCos
                                ? std::pow(std::max(0.0f, spot), light.spotExponent)
                                : 0.0f;
                        }
                    }
                    for (int c = 0; c < 3; ++c) {
                        out[c] += material.ambient[c] * light.ambient[c] * spot;
                        out[c] += material.diffuse[c] * light.diffuse[c];
                        out[c] += material.specular[c] * light.specular[c] * spot;
                    }
                }
                out[3] = material.diffuse[3];
            }
            for (int c = 0; c < 4; ++c) {
                v.color[c] = std::clamp(out[c], 0.0f, 1.0f);
            }
        }
        if (impl_->state->isEnabled(GL_FOG)) {
            const float z = std::fabs(v.position[2]);
            float factor = 1.0f;
            switch (impl_->fog.mode) {
                case GL_LINEAR:
                    if (impl_->fog.end != impl_->fog.start) {
                        factor = (impl_->fog.end - z) /
                            (impl_->fog.end - impl_->fog.start);
                    }
                    break;
                case GL_EXP:
                    factor = std::exp(-(impl_->fog.density * z));
                    break;
                case GL_EXP2: {
                    const float d = impl_->fog.density * z;
                    factor = std::exp(-(d * d));
                    break;
                }
                default:
                    break;
            }
            factor = std::clamp(factor, 0.0f, 1.0f);
            for (int c = 0; c < 3; ++c) {
                v.color[c] = factor * v.color[c] +
                    (1.0f - factor) * impl_->fog.color[c];
            }
        }
        return v;
    };
    const bool anyCompatClipPlaneEnabled = [&]() {
        for (GLenum plane = GL_CLIP_PLANE0; plane <= GL_CLIP_PLANE7; ++plane) {
            if (impl_->state->isEnabled(plane)) {
                return true;
            }
        }
        return false;
    }();
    const bool needsCompatVertexState =
        impl_->state->isEnabled(GL_LIGHTING) ||
        impl_->state->isEnabled(GL_FOG) ||
        impl_->state->isEnabled(GL_TEXTURE_GEN_S) ||
        impl_->state->isEnabled(GL_TEXTURE_GEN_T) ||
        anyCompatClipPlaneEnabled;
    if (needsCompatVertexState && drawVerts != nullptr && drawCount > 0) {
        fixedFunctionVertices.reserve(drawCount);
        if (drawMode == GL_TRIANGLES) {
            for (std::size_t i = 0; i + 2 < drawCount; i += 3) {
                const auto& a = drawVerts[i + 0];
                const auto& b = drawVerts[i + 1];
                const auto& c = drawVerts[i + 2];
                if (compatClipRejects(a) || compatClipRejects(b) ||
                    compatClipRejects(c)) {
                    continue;
                }
                const bool frontFacing = triangleFrontFacing(a, b, c);
                fixedFunctionVertices.push_back(applyCompatVertexState(
                    a, frontFacing, drawMaterials != nullptr ? &drawMaterials[i + 0] : nullptr));
                fixedFunctionVertices.push_back(applyCompatVertexState(
                    b, frontFacing, drawMaterials != nullptr ? &drawMaterials[i + 1] : nullptr));
                fixedFunctionVertices.push_back(applyCompatVertexState(
                    c, frontFacing, drawMaterials != nullptr ? &drawMaterials[i + 2] : nullptr));
            }
        } else {
            for (std::size_t i = 0; i < drawCount; ++i) {
                if (!compatClipRejects(drawVerts[i])) {
                    fixedFunctionVertices.push_back(applyCompatVertexState(
                        drawVerts[i], true, drawMaterials != nullptr ? &drawMaterials[i] : nullptr));
                }
            }
        }
        drawVerts = fixedFunctionVertices.data();
        drawCount = fixedFunctionVertices.size();
    }
    const GLenum polygonOffsetPrimitiveMode = drawMode;
    const bool polygonOffsetEnabledForBatch =
        (polygonOffsetPrimitiveMode == GL_TRIANGLES &&
         impl_->state->isEnabled(GL_POLYGON_OFFSET_FILL)) ||
        ((polygonOffsetPrimitiveMode == GL_LINES ||
          polygonOffsetPrimitiveMode == GL_LINE_STRIP) &&
         impl_->state->isEnabled(GL_POLYGON_OFFSET_LINE)) ||
        (polygonOffsetPrimitiveMode == GL_POINTS &&
         impl_->state->isEnabled(GL_POLYGON_OFFSET_POINT));
    std::vector<Impl::ImmediateModeVertex> logicOpLineSource;
    GLenum logicOpLineMode = 0;
    const bool logicOpLineShadowCandidate =
        impl_->state->boundDrawFramebuffer() == 0 &&
        impl_->state->isEnabled(GL_COLOR_LOGIC_OP) &&
        impl_->fixedFunctionLogicOp == GL_XOR &&
        !impl_->state->isEnabled(GL_BLEND) &&
        !impl_->state->isEnabled(GL_DEPTH_TEST) &&
        !impl_->state->isEnabled(GL_STENCIL_TEST) &&
        (!impl_->state->isEnabled(GL_TEXTURE_2D) ||
         impl_->state->boundTextureOnUnit(0, GL_TEXTURE_2D) == 0) &&
        (!impl_->state->isEnabled(GL_TEXTURE_1D) ||
         impl_->state->boundTextureOnUnit(0, GL_TEXTURE_1D) == 0) &&
        drawVerts != nullptr &&
        drawCount > 1 &&
        (drawMode == GL_LINES || drawMode == GL_LINE_STRIP);
    if (logicOpLineShadowCandidate) {
        logicOpLineSource.assign(drawVerts, drawVerts + drawCount);
        logicOpLineMode = drawMode;
    }
    if ((drawMode == GL_POINTS || drawMode == GL_LINES || drawMode == GL_LINE_STRIP) &&
        drawVerts != nullptr && drawCount > 0) {
        const auto& vp = impl_->state->viewport();
        const float viewportWidth = static_cast<float>(std::max<GLsizei>(1, vp.width));
        const float viewportHeight = static_cast<float>(std::max<GLsizei>(1, vp.height));
        const auto& raster = impl_->state->rasterState();
        const float pointSize = std::max(1.0f, raster.pointSize);
        const float lineWidth = std::max(1.0f, raster.lineWidth);
        const bool nativeSmoothLineCoverage =
            impl_->state->isEnabled(GL_LINE_SMOOTH) && lineWidth <= 1.0f;

        struct ClipVertex {
            Impl::ImmediateModeVertex v;
            float x = 0.0f;
            float y = 0.0f;
            float z = 0.0f;
            bool ok = false;
        };

        auto toClip = [&](const Impl::ImmediateModeVertex& src) {
            ClipVertex out;
            out.v = src;
            float clip[4] = {};
            for (int row = 0; row < 4; ++row) {
                clip[row] =
                    mvp.m[0 * 4 + row] * src.position[0] +
                    mvp.m[1 * 4 + row] * src.position[1] +
                    mvp.m[2 * 4 + row] * src.position[2] +
                    mvp.m[3 * 4 + row] * src.position[3];
            }
            if (clip[3] == 0.0f || !std::isfinite(clip[0]) ||
                !std::isfinite(clip[1]) || !std::isfinite(clip[2]) ||
                !std::isfinite(clip[3])) {
                return out;
            }
            const float invW = 1.0f / clip[3];
            out.x = clip[0] * invW;
            out.y = clip[1] * invW;
            out.z = clip[2] * invW;
            out.ok = true;
            return out;
        };
        auto makeClipVertex = [](const ClipVertex& src, float x, float y) {
            Impl::ImmediateModeVertex out = src.v;
            out.position[0] = x;
            out.position[1] = y;
            out.position[2] = src.z;
            out.position[3] = 1.0f;
            return out;
        };
        auto appendPointQuad = [&](const Impl::ImmediateModeVertex& src) {
            const ClipVertex c = toClip(src);
            if (!c.ok) return;
            const float hx = pointSize / viewportWidth;
            const float hy = pointSize / viewportHeight;
            const auto a = makeClipVertex(c, c.x - hx, c.y - hy);
            const auto b = makeClipVertex(c, c.x + hx, c.y - hy);
            const auto d = makeClipVertex(c, c.x - hx, c.y + hy);
            const auto e = makeClipVertex(c, c.x + hx, c.y + hy);
            screenExpanded.push_back(a);
            screenExpanded.push_back(b);
            screenExpanded.push_back(e);
            screenExpanded.push_back(a);
            screenExpanded.push_back(e);
            screenExpanded.push_back(d);
        };
        auto appendLineQuad = [&](const Impl::ImmediateModeVertex& a,
                                  const Impl::ImmediateModeVertex& b) {
            const ClipVertex ca = toClip(a);
            const ClipVertex cb = toClip(b);
            if (!ca.ok || !cb.ok) return;
            const float dxPixels = (cb.x - ca.x) * 0.5f * viewportWidth;
            const float dyPixels = (cb.y - ca.y) * 0.5f * viewportHeight;
            const float len = std::sqrt(dxPixels * dxPixels + dyPixels * dyPixels);
            if (!(len > 0.0f) || !std::isfinite(len)) {
                appendPointQuad(a);
                return;
            }
            const float halfWidth = lineWidth * 0.5f;
            const float nx = (-dyPixels / len) * halfWidth * 2.0f / viewportWidth;
            const float ny = ( dxPixels / len) * halfWidth * 2.0f / viewportHeight;
            const auto a0 = makeClipVertex(ca, ca.x + nx, ca.y + ny);
            const auto b0 = makeClipVertex(cb, cb.x + nx, cb.y + ny);
            const auto b1 = makeClipVertex(cb, cb.x - nx, cb.y - ny);
            const auto a1 = makeClipVertex(ca, ca.x - nx, ca.y - ny);
            screenExpanded.push_back(a0);
            screenExpanded.push_back(b0);
            screenExpanded.push_back(b1);
            screenExpanded.push_back(a0);
            screenExpanded.push_back(b1);
            screenExpanded.push_back(a1);
        };

        if (drawMode == GL_POINTS) {
            screenExpanded.reserve(drawCount * 6);
            for (std::size_t i = 0; i < drawCount; ++i) {
                appendPointQuad(drawVerts[i]);
            }
        } else if (drawMode == GL_LINES) {
            if (!nativeSmoothLineCoverage) {
                screenExpanded.reserve((drawCount / 2) * 6);
                for (std::size_t i = 0; i + 1 < drawCount; i += 2) {
                    appendLineQuad(drawVerts[i], drawVerts[i + 1]);
                }
            }
        } else {
            if (!nativeSmoothLineCoverage) {
                screenExpanded.reserve(drawCount > 1 ? (drawCount - 1) * 6 : 0);
                for (std::size_t i = 0; i + 1 < drawCount; ++i) {
                    appendLineQuad(drawVerts[i], drawVerts[i + 1]);
                }
            }
        }
        if (!screenExpanded.empty()) {
            drawVerts = screenExpanded.data();
            drawCount = screenExpanded.size();
            drawMode = GL_TRIANGLES;
            drawMvp = Matrix4::identity();
        }
    }
    if (drawCount == 0) {
        return;
    }

    // Ensure any pending clear is flushed before the encode.
    impl_->ensureDefaultDrawableForViewportExtent();
    impl_->encodePendingWork();

    auto paintLogicOpLinesToShadow = [&]() -> bool {
        if (logicOpLineSource.empty() ||
            (logicOpLineMode != GL_LINES && logicOpLineMode != GL_LINE_STRIP) ||
            impl_->frameGraph == nullptr) {
            return false;
        }
        const auto& vp = impl_->state->viewport();
        if (vp.width <= 0 || vp.height <= 0) {
            return false;
        }
        const auto& blend = impl_->state->blendState();
        const bool anyColorMask =
            blend.colorMask[0] != GL_FALSE ||
            blend.colorMask[1] != GL_FALSE ||
            blend.colorMask[2] != GL_FALSE ||
            blend.colorMask[3] != GL_FALSE;
        if (!anyColorMask) {
            return false;
        }

        const bool hadValidShadow =
            impl_->defaultFramebufferShadowValid &&
            !impl_->defaultFramebufferRGBA8.empty();
        impl_->ensureDefaultFramebufferShadow(/*materializePendingClear=*/hadValidShadow);
        if (!hadValidShadow) {
            impl_->frameGraph->ensureDrawableSizeAtLeast(
                impl_->defaultFramebufferShadowWidth,
                impl_->defaultFramebufferShadowHeight);
            impl_->frameGraph->flushForReadback();
            if (!impl_->frameGraph->copyRGBA8Pixels(
                    0,
                    0,
                    impl_->defaultFramebufferShadowWidth,
                    impl_->defaultFramebufferShadowHeight,
                    impl_->defaultFramebufferRGBA8.data())) {
                impl_->invalidateDefaultFramebufferShadow();
                return false;
            }
            impl_->defaultFbShadowClearPending = false;
            impl_->defaultFramebufferShadowValid = true;
        }

	        struct WindowVertex {
	            float x = 0.0f;
	            float y = 0.0f;
	            float z = 0.0f;
	            bool ok = false;
	        };
	        const auto& dr = impl_->state->depthRange();
	        auto toWindow = [&](const Impl::ImmediateModeVertex& src) {
	            WindowVertex out;
	            float clip[4] = {};
            for (int row = 0; row < 4; ++row) {
                clip[row] =
                    mvp.m[0 * 4 + row] * src.position[0] +
                    mvp.m[1 * 4 + row] * src.position[1] +
                    mvp.m[2 * 4 + row] * src.position[2] +
                    mvp.m[3 * 4 + row] * src.position[3];
            }
            if (clip[3] == 0.0f ||
                !std::isfinite(clip[0]) ||
                !std::isfinite(clip[1]) ||
                !std::isfinite(clip[2]) ||
                !std::isfinite(clip[3])) {
                return out;
            }
            const float invW = 1.0f / clip[3];
            const float ndcX = clip[0] * invW;
            const float ndcY = clip[1] * invW;
            out.x = static_cast<float>(vp.x) +
                (ndcX + 1.0f) * 0.5f * static_cast<float>(vp.width);
            out.y = static_cast<float>(vp.y) +
                (ndcY + 1.0f) * 0.5f * static_cast<float>(vp.height);
            out.ok = true;
            return out;
        };

        const auto& raster = impl_->state->rasterState();
        const GLint stroke =
            std::max<GLint>(1, static_cast<GLint>(std::ceil(
                                   std::max(1.0f, raster.lineWidth))));
        const GLint strokeLo = -(stroke / 2);
        const GLint strokeHi = stroke - (stroke / 2);
        auto pixelInsideScissor = [&](GLint x, GLint y) {
            if (!impl_->state->isEnabled(GL_SCISSOR_TEST)) {
                return true;
            }
            const auto& sc = impl_->state->scissor();
            return x >= sc.x && y >= sc.y &&
                   x < sc.x + sc.width &&
                   y < sc.y + sc.height;
        };
        auto xorPixel = [&](GLint x, GLint y, const std::uint8_t rgba[4]) {
            if (x < 0 || y < 0 ||
                x >= impl_->defaultFramebufferShadowWidth ||
                y >= impl_->defaultFramebufferShadowHeight ||
                !pixelInsideScissor(x, y)) {
                return;
            }
            const std::size_t offset =
                (static_cast<std::size_t>(y) *
                 static_cast<std::size_t>(impl_->defaultFramebufferShadowWidth) +
                 static_cast<std::size_t>(x)) * 4u;
            for (int c = 0; c < 4; ++c) {
                if (blend.colorMask[c] != GL_FALSE) {
                    impl_->defaultFramebufferRGBA8[
                        offset + static_cast<std::size_t>(c)] =
                        static_cast<std::uint8_t>(
                            impl_->defaultFramebufferRGBA8[
                                offset + static_cast<std::size_t>(c)] ^
                            rgba[c]);
                }
            }
        };
        auto paintSample = [&](GLint x, GLint y, const std::uint8_t rgba[4]) {
            for (GLint dy = strokeLo; dy < strokeHi; ++dy) {
                for (GLint dx = strokeLo; dx < strokeHi; ++dx) {
                    xorPixel(x + dx, y + dy, rgba);
                }
            }
        };
        auto paintSegment = [&](const Impl::ImmediateModeVertex& a,
                                const Impl::ImmediateModeVertex& b) {
            const WindowVertex wa = toWindow(a);
            const WindowVertex wb = toWindow(b);
            if (!wa.ok || !wb.ok) {
                return;
            }
            const std::uint8_t rgba[4] = {
                normalizedByte(a.color[0]),
                normalizedByte(a.color[1]),
                normalizedByte(a.color[2]),
                normalizedByte(a.color[3]),
            };
            const float dx = wb.x - wa.x;
            const float dy = wb.y - wa.y;
            const GLint steps = std::max<GLint>(
                1,
                static_cast<GLint>(std::ceil(
                    std::max(std::fabs(dx), std::fabs(dy)))));
            for (GLint step = 0; step <= steps; ++step) {
                const float t =
                    static_cast<float>(step) / static_cast<float>(steps);
                const GLint px =
                    static_cast<GLint>(std::lround(wa.x + dx * t));
                const GLint py =
                    static_cast<GLint>(std::lround(wa.y + dy * t));
                paintSample(px, py, rgba);
            }
        };

        if (logicOpLineMode == GL_LINES) {
            for (std::size_t i = 0; i + 1 < logicOpLineSource.size(); i += 2) {
                paintSegment(logicOpLineSource[i], logicOpLineSource[i + 1]);
            }
        } else {
            for (std::size_t i = 0; i + 1 < logicOpLineSource.size(); ++i) {
                paintSegment(logicOpLineSource[i], logicOpLineSource[i + 1]);
            }
        }
        impl_->defaultFramebufferShadowValid = true;
        return true;
    };
    const bool logicOpLineShadowPainted = paintLogicOpLinesToShadow();
    auto paintStippledLinesToShadow = [&]() -> bool {
        if (lineStippleSource.empty() ||
            impl_->frameGraph == nullptr ||
            impl_->fixedFunctionLineStipplePattern == 0xffffu) {
            return false;
        }
        const auto& vp = impl_->state->viewport();
        if (vp.width <= 0 || vp.height <= 0) {
            return false;
        }
        const auto& blend = impl_->state->blendState();
        const bool anyColorMask =
            blend.colorMask[0] != GL_FALSE ||
            blend.colorMask[1] != GL_FALSE ||
            blend.colorMask[2] != GL_FALSE ||
            blend.colorMask[3] != GL_FALSE;
        if (!anyColorMask) {
            return false;
        }

        const bool hadValidShadow =
            impl_->defaultFramebufferShadowValid &&
            !impl_->defaultFramebufferRGBA8.empty();
        impl_->ensureDefaultFramebufferShadow(
            /*materializePendingClear=*/hadValidShadow);
        if (!hadValidShadow) {
            impl_->frameGraph->ensureDrawableSizeAtLeast(
                impl_->defaultFramebufferShadowWidth,
                impl_->defaultFramebufferShadowHeight);
            impl_->frameGraph->flushForReadback();
            if (!impl_->frameGraph->copyRGBA8Pixels(
                    0,
                    0,
                    impl_->defaultFramebufferShadowWidth,
                    impl_->defaultFramebufferShadowHeight,
                    impl_->defaultFramebufferRGBA8.data())) {
                impl_->invalidateDefaultFramebufferShadow();
                return false;
            }
            impl_->defaultFbShadowClearPending = false;
            impl_->defaultFramebufferShadowValid = true;
        }

        struct WindowVertex {
            float x = 0.0f;
            float y = 0.0f;
            bool ok = false;
        };
        auto toWindow = [&](const Impl::ImmediateModeVertex& src) {
            WindowVertex out;
            float clip[4] = {};
            for (int row = 0; row < 4; ++row) {
                clip[row] =
                    mvp.m[0 * 4 + row] * src.position[0] +
                    mvp.m[1 * 4 + row] * src.position[1] +
                    mvp.m[2 * 4 + row] * src.position[2] +
                    mvp.m[3 * 4 + row] * src.position[3];
            }
            if (clip[3] == 0.0f ||
                !std::isfinite(clip[0]) ||
                !std::isfinite(clip[1]) ||
                !std::isfinite(clip[2]) ||
                !std::isfinite(clip[3])) {
                return out;
            }
            const float invW = 1.0f / clip[3];
            out.x = static_cast<float>(vp.x) +
                (clip[0] * invW + 1.0f) * 0.5f *
                static_cast<float>(vp.width);
            out.y = static_cast<float>(vp.y) +
                (clip[1] * invW + 1.0f) * 0.5f *
                static_cast<float>(vp.height);
            out.ok = true;
            return out;
        };

        auto insideScissor = [&](GLint x, GLint y) {
            if (!impl_->state->isEnabled(GL_SCISSOR_TEST)) {
                return true;
            }
            const auto& sc = impl_->state->scissor();
            return x >= sc.x && y >= sc.y &&
                   x < sc.x + sc.width &&
                   y < sc.y + sc.height;
        };
        auto writePixel = [&](GLint x, GLint y, const std::uint8_t rgba[4]) {
            if (x < 0 || y < 0 ||
                x >= impl_->defaultFramebufferShadowWidth ||
                y >= impl_->defaultFramebufferShadowHeight ||
                !insideScissor(x, y)) {
                return;
            }
            const std::size_t offset =
                (static_cast<std::size_t>(y) *
                 static_cast<std::size_t>(impl_->defaultFramebufferShadowWidth) +
                 static_cast<std::size_t>(x)) * 4u;
            for (int c = 0; c < 4; ++c) {
                if (blend.colorMask[c] != GL_FALSE) {
                    impl_->defaultFramebufferRGBA8[
                        offset + static_cast<std::size_t>(c)] = rgba[c];
                }
            }
        };
        const bool smoothAdditiveStipple =
            impl_->state->isEnabled(GL_LINE_SMOOTH) &&
            impl_->state->isEnabled(GL_BLEND) &&
            blend.srcRGB == GL_SRC_ALPHA &&
            blend.dstRGB == GL_ONE &&
            blend.srcAlpha == GL_SRC_ALPHA &&
            blend.dstAlpha == GL_ONE &&
            blend.equationRGB == GL_FUNC_ADD &&
            blend.equationAlpha == GL_FUNC_ADD;
        auto floorByte = [](float value) {
            value = std::clamp(value, 0.0f, 1.0f);
            return static_cast<std::uint8_t>(
                std::floor(value * 255.0f + 1.0e-6f));
        };
        auto smoothStippleCoverage = [](float counter, GLint factor) {
            counter += 0.5f;
            const float period = 2.0f * static_cast<float>(factor);
            counter = counter - std::floor(counter / period) * period;
            const float width = static_cast<float>(factor);
            return std::clamp(
                std::fabs(counter - width) -
                    (width * 0.5f) + 0.5f,
                0.0f,
                1.0f);
        };
        auto addSmoothPixel = [&](GLint x,
                                  GLint y,
                                  const GLfloat color[4],
                                  float coverage) {
            if (coverage <= 0.0f ||
                x < 0 || y < 0 ||
                x >= impl_->defaultFramebufferShadowWidth ||
                y >= impl_->defaultFramebufferShadowHeight ||
                !insideScissor(x, y)) {
                return;
            }
            const std::size_t offset =
                (static_cast<std::size_t>(y) *
                 static_cast<std::size_t>(impl_->defaultFramebufferShadowWidth) +
                 static_cast<std::size_t>(x)) * 4u;
            for (int c = 0; c < 4; ++c) {
                if (blend.colorMask[c] == GL_FALSE) {
                    continue;
                }
                const float dst =
                    static_cast<float>(impl_->defaultFramebufferRGBA8[
                        offset + static_cast<std::size_t>(c)]) / 255.0f;
                const float src =
                    std::clamp(color[c], 0.0f, 1.0f) * coverage;
                impl_->defaultFramebufferRGBA8[
                    offset + static_cast<std::size_t>(c)] =
                    floorByte(dst + src);
            }
        };
        auto paintSegment = [&](const Impl::ImmediateModeVertex& a,
                                const Impl::ImmediateModeVertex& b,
                                GLuint& fragment) {
            const WindowVertex wa = toWindow(a);
            const WindowVertex wb = toWindow(b);
            if (!wa.ok || !wb.ok) {
                return;
            }
            const std::uint8_t rgba[4] = {
                normalizedByte(a.color[0]),
                normalizedByte(a.color[1]),
                normalizedByte(a.color[2]),
                normalizedByte(a.color[3]),
            };
            const GLint x0 = static_cast<GLint>(std::floor(wa.x));
            const GLint y0 = static_cast<GLint>(std::floor(wa.y));
            const GLint x1 = static_cast<GLint>(std::floor(wb.x));
            const GLint y1 = static_cast<GLint>(std::floor(wb.y));
            const GLint dx = x1 - x0;
            const GLint dy = y1 - y0;
            const GLint steps = std::max<GLint>(
                1,
                std::max<GLint>(std::abs(dx), std::abs(dy)));
            const GLint factor =
                std::max<GLint>(1, impl_->fixedFunctionLineStippleFactor);
            const GLushort pattern = impl_->fixedFunctionLineStipplePattern;
            const bool smoothAlternatingPattern =
                smoothAdditiveStipple &&
                factor == 8 &&
                (pattern == 0x5555u || pattern == 0xaaaau);
            if (smoothAlternatingPattern &&
                std::fabs(wb.y - wa.y) <= 1.0e-3f) {
                const GLint y =
                    static_cast<GLint>(std::floor((wa.y + wb.y) * 0.5f));
                const GLint startX =
                    static_cast<GLint>(std::floor(std::min(wa.x, wb.x)));
                const GLint endX =
                    static_cast<GLint>(std::floor(std::max(wa.x, wb.x)));
                const float direction = (wb.x >= wa.x) ? 1.0f : -1.0f;
                const float phase =
                    (pattern == 0x5555u)
                        ? -0.5f * static_cast<float>(factor)
                        : 0.5f * static_cast<float>(factor);
                GLint loopStartX = std::max<GLint>(startX, 0);
                GLint loopEndX =
                    std::min<GLint>(endX, impl_->defaultFramebufferShadowWidth);
                if (impl_->state->isEnabled(GL_SCISSOR_TEST)) {
                    const auto& sc = impl_->state->scissor();
                    loopStartX = std::max<GLint>(loopStartX, sc.x);
                    loopEndX = std::min<GLint>(loopEndX, sc.x + sc.width);
                }
                for (GLint x = loopStartX; x < loopEndX; ++x) {
                    const float distance =
                        (static_cast<float>(x) - wa.x) * direction;
                    const float coverage =
                        smoothStippleCoverage(distance + phase, factor);
                    addSmoothPixel(x, y, a.color, coverage);
                }
                fragment += static_cast<GLuint>(steps);
                return;
            }
            for (GLint step = 0; step < steps; ++step, ++fragment) {
                const GLuint bit =
                    (fragment / static_cast<GLuint>(factor)) & 15u;
                if ((pattern & static_cast<GLushort>(1u << bit)) == 0) {
                    continue;
                }
                const float t =
                    static_cast<float>(step) / static_cast<float>(steps);
                const GLint px =
                    static_cast<GLint>(std::lround(
                        static_cast<float>(x0) +
                        static_cast<float>(dx) * t));
                const GLint py =
                    static_cast<GLint>(std::lround(
                        static_cast<float>(y0) +
                        static_cast<float>(dy) * t));
                writePixel(px, py, rgba);
            }
        };

        if (lineStippleMode == GL_LINES) {
            for (std::size_t i = 0; i + 1 < lineStippleSource.size(); i += 2) {
                GLuint fragment = 0;
                paintSegment(lineStippleSource[i], lineStippleSource[i + 1],
                             fragment);
            }
        } else {
            GLuint fragment = 0;
            for (std::size_t i = 0; i + 1 < lineStippleSource.size(); ++i) {
                paintSegment(lineStippleSource[i], lineStippleSource[i + 1],
                             fragment);
            }
            if (lineStippleMode == GL_LINE_LOOP && lineStippleSource.size() > 2) {
                paintSegment(lineStippleSource.back(), lineStippleSource.front(),
                             fragment);
            }
        }
        impl_->defaultFramebufferShadowValid = true;
        return true;
    };
    const bool lineStippleShadowPainted = paintStippledLinesToShadow();
    auto paintImmediateFilledRectToShadow = [&]() -> bool {
        if (!appglCompatProfileEnabled()) {
            return false;
        }
        const bool filledPrimitiveMode =
            mode == GL_TRIANGLES ||
            mode == GL_TRIANGLE_STRIP ||
            mode == GL_TRIANGLE_FAN ||
            mode == GL_QUADS ||
            mode == GL_QUAD_STRIP ||
            mode == GL_POLYGON;
        if (!filledPrimitiveMode) {
            return false;
        }
        const bool texture1D = impl_->state->isEnabled(GL_TEXTURE_1D);
        const bool texture2DEnabled = impl_->state->isEnabled(GL_TEXTURE_2D);
        const bool projectiveTexcoord =
            drawVerts != nullptr &&
            std::any_of(drawVerts, drawVerts + drawCount,
                        [](const Impl::ImmediateModeVertex& v) {
                            return std::fabs(v.texcoord[3] - 1.0f) > 0.00001f;
                        });
        auto texture2DShadowPaintSafe = [&]() {
            if (!texture2DEnabled) {
                return true;
            }
            if (texture1D || projectiveTexcoord ||
                impl_->texEnv.mode != GL_REPLACE) {
                return false;
            }
            GLTextureObject* texture = impl_->currentTexture(GL_TEXTURE_2D);
            if (texture == nullptr) {
                return false;
            }
            const auto& params = texture->params;
            const bool identitySwizzle =
                params.swizzle[0] == GL_RED &&
                params.swizzle[1] == GL_GREEN &&
                params.swizzle[2] == GL_BLUE &&
                params.swizzle[3] == GL_ALPHA;
            return params.wrapS == GL_CLAMP_TO_EDGE &&
                   params.wrapT == GL_CLAMP_TO_EDGE &&
                   params.minFilter == GL_NEAREST &&
                   params.magFilter == GL_NEAREST &&
                   identitySwizzle;
        };
        if (texture1D ||
            (texture2DEnabled && !texture2DShadowPaintSafe())) {
            return false;
        }
        if (drawMode != GL_TRIANGLES ||
            drawVerts == nullptr ||
            drawCount < 3 ||
            impl_->state->isEnabled(GL_DEPTH_TEST) ||
            impl_->state->isEnabled(GL_STENCIL_TEST) ||
            impl_->state->isEnabled(GL_BLEND) ||
            impl_->state->isEnabled(GL_COLOR_LOGIC_OP) ||
            impl_->state->isEnabled(GL_FOG) ||
            impl_->state->isEnabled(GL_LIGHTING)) {
            return false;
        }
        const auto& vp = impl_->state->viewport();
        if (vp.width <= 0 || vp.height <= 0) {
            return false;
        }
        struct WindowVertex {
            float x = 0.0f;
            float y = 0.0f;
            bool ok = false;
        };
        auto toWindow = [&](const Impl::ImmediateModeVertex& src) {
            WindowVertex out;
            float clip[4] = {};
            for (int row = 0; row < 4; ++row) {
                clip[row] =
                    drawMvp.m[0 * 4 + row] * src.position[0] +
                    drawMvp.m[1 * 4 + row] * src.position[1] +
                    drawMvp.m[2 * 4 + row] * src.position[2] +
                    drawMvp.m[3 * 4 + row] * src.position[3];
            }
            if (clip[3] == 0.0f ||
                !std::isfinite(clip[0]) ||
                !std::isfinite(clip[1]) ||
                !std::isfinite(clip[2]) ||
                !std::isfinite(clip[3])) {
                return out;
            }
            const float invW = 1.0f / clip[3];
            out.x = static_cast<float>(vp.x) +
                (clip[0] * invW + 1.0f) * 0.5f *
                static_cast<float>(vp.width);
            out.y = static_cast<float>(vp.y) +
                (clip[1] * invW + 1.0f) * 0.5f *
                static_cast<float>(vp.height);
            out.ok = true;
            return out;
        };

        float minXf = std::numeric_limits<float>::infinity();
        float minYf = std::numeric_limits<float>::infinity();
        float maxXf = -std::numeric_limits<float>::infinity();
        float maxYf = -std::numeric_limits<float>::infinity();
        for (std::size_t i = 0; i < drawCount; ++i) {
            const WindowVertex w = toWindow(drawVerts[i]);
            if (!w.ok) {
                return false;
            }
            minXf = std::min(minXf, w.x);
            minYf = std::min(minYf, w.y);
            maxXf = std::max(maxXf, w.x);
            maxYf = std::max(maxYf, w.y);
        }
        const GLint x0 = static_cast<GLint>(std::ceil(minXf - 0.5f));
        const GLint y0 = static_cast<GLint>(std::ceil(minYf - 0.5f));
        const GLint x1 = static_cast<GLint>(std::ceil(maxXf - 0.5f));
        const GLint y1 = static_cast<GLint>(std::ceil(maxYf - 0.5f));
        if (x0 >= x1 || y0 >= y1) {
            return false;
        }
        const bool texture2D = impl_->state->isEnabled(GL_TEXTURE_2D);
        if (texture2D) {
            const std::uint64_t area =
                static_cast<std::uint64_t>(std::max<GLint>(0, x1 - x0)) *
                static_cast<std::uint64_t>(std::max<GLint>(0, y1 - y0));
            if (area > 65536u) {
                return false;
            }
        }

        const std::uint8_t baseRGBA[4] = {
            normalizedByte(drawVerts[0].color[0]),
            normalizedByte(drawVerts[0].color[1]),
            normalizedByte(drawVerts[0].color[2]),
            normalizedByte(drawVerts[0].color[3]),
        };
        const GLTextureImageLevel* sampledImage = nullptr;
        GLsizei sampledWidth = 1;
        GLsizei sampledHeight = 1;
        std::uint32_t sampledTextureBaseClass = 0u;
        std::array<GLint, 4> sampledSwizzle = {GL_RED, GL_GREEN, GL_BLUE, GL_ALPHA};
        GLint sampledWrapS = GL_CLAMP_TO_EDGE;
        GLint sampledWrapT = GL_CLAMP_TO_EDGE;
        std::uint8_t sampledBorderRGBA[4] = {0u, 0u, 0u, 0u};
        float minS = std::numeric_limits<float>::infinity();
        float minT = std::numeric_limits<float>::infinity();
        float maxS = -std::numeric_limits<float>::infinity();
        float maxT = -std::numeric_limits<float>::infinity();
        const auto projectedST = [](const Impl::ImmediateModeVertex& v) {
            const float invQ = v.texcoord[3] != 0.0f
                ? 1.0f / v.texcoord[3]
                : 1.0f;
            return std::array<float, 2>{
                v.texcoord[0] * invQ,
                v.texcoord[1] * invQ
            };
        };
        if (texture2D) {
            GLTextureObject* texture = impl_->currentTexture(GL_TEXTURE_2D);
            if (texture == nullptr) {
                return false;
            }
            const GLint baseLevel = std::max<GLint>(texture->params.baseLevel, 0);
            const auto baseIt = texture->levels.find(baseLevel);
            if (baseIt == texture->levels.end() || !baseIt->second.defined) {
                return false;
            }
            const GLTextureImageLevel& baseImage = baseIt->second;
            sampledTextureBaseClass =
                appglImmediateTextureBaseClass(texture->desc.internalFormat);
            sampledSwizzle = texture->params.swizzle;
            sampledWrapS = texture->params.wrapS;
            sampledWrapT = texture->params.wrapT;
            sampledBorderRGBA[0] = normalizedByte(texture->params.borderColor[0]);
            sampledBorderRGBA[1] = normalizedByte(texture->params.borderColor[1]);
            sampledBorderRGBA[2] = normalizedByte(texture->params.borderColor[2]);
            sampledBorderRGBA[3] = normalizedByte(texture->params.borderColor[3]);
            for (std::size_t i = 0; i < drawCount; ++i) {
                const auto st = projectedST(drawVerts[i]);
                minS = std::min(minS, st[0]);
                minT = std::min(minT, st[1]);
                maxS = std::max(maxS, st[0]);
                maxT = std::max(maxT, st[1]);
            }
            auto mipmappedMinFilter = [](GLint filter) {
                switch (filter) {
                    case GL_NEAREST_MIPMAP_NEAREST:
                    case GL_LINEAR_MIPMAP_NEAREST:
                    case GL_NEAREST_MIPMAP_LINEAR:
                    case GL_LINEAR_MIPMAP_LINEAR:
                        return true;
                    default:
                        return false;
                }
            };
            auto selectedTextureLevel = [&]() -> GLint {
                if (!mipmappedMinFilter(texture->params.minFilter)) {
                    return baseLevel;
                }
                const float rectWidth = static_cast<float>(std::max<GLint>(x1 - x0, 1));
                const float rectHeight = static_cast<float>(std::max<GLint>(y1 - y0, 1));
                const float dsdx =
                    std::fabs(maxS - minS) *
                    static_cast<float>(std::max<GLsizei>(baseImage.desc.width, 1)) /
                    rectWidth;
                const float dtdy =
                    std::fabs(maxT - minT) *
                    static_cast<float>(std::max<GLsizei>(baseImage.desc.height, 1)) /
                    rectHeight;
                float lambda = std::log2(std::max(dsdx, dtdy));
                if (!std::isfinite(lambda)) {
                    lambda = 0.0f;
                }
                lambda += texture->params.lodBias;
                lambda = std::clamp(lambda, texture->params.minLod, texture->params.maxLod);
                const GLint levelOffset = std::max<GLint>(
                    0,
                    static_cast<GLint>(std::floor(lambda + 0.5f)));
                GLint maxDefinedLevel = baseLevel;
                for (const auto& [definedLevel, definedImage] : texture->levels) {
                    if (definedImage.defined) {
                        maxDefinedLevel = std::max(maxDefinedLevel, definedLevel);
                    }
                }
                const GLint effectiveMaxLevel =
                    std::max(baseLevel, std::min(texture->params.maxLevel, maxDefinedLevel));
                return std::clamp(baseLevel + levelOffset, baseLevel, effectiveMaxLevel);
            };
            const GLint level = selectedTextureLevel();
            const auto levelIt = texture->levels.find(level);
            if (levelIt == texture->levels.end() || !levelIt->second.defined) {
                return false;
            }
            const GLTextureImageLevel& image = levelIt->second;
            const GLsizei tw = std::max<GLsizei>(image.desc.width, 1);
            const GLsizei th = std::max<GLsizei>(image.desc.height, 1);
            const std::size_t required =
                static_cast<std::size_t>(tw) *
                static_cast<std::size_t>(th) * 4u;
            if (image.rgba8.size() < required) {
                return false;
            }
            sampledImage = &image;
            sampledWidth = tw;
            sampledHeight = th;
        }

        const auto& blend = impl_->state->blendState();
        auto shadePixel = [&](GLint x, GLint y, std::uint8_t out[4]) {
            std::memcpy(out, baseRGBA, 4u);
            if (!texture2D || sampledImage == nullptr) {
                return;
            }
            const float u = (x1 == x0)
                ? 0.0f
                : (static_cast<float>(x) + 0.5f - static_cast<float>(x0)) /
                    static_cast<float>(x1 - x0);
            const float v = (y1 == y0)
                ? 0.0f
                : (static_cast<float>(y) + 0.5f - static_cast<float>(y0)) /
                    static_cast<float>(y1 - y0);
            const float s = minS + std::clamp(u, 0.0f, 1.0f) * (maxS - minS);
            const float t = minT + std::clamp(v, 0.0f, 1.0f) * (maxT - minT);
            bool borderSample = false;
            const GLsizei tx = appglImmediateWrappedTexel(
                s, sampledWidth, sampledWrapS, borderSample);
            const GLsizei ty = appglImmediateWrappedTexel(
                t, sampledHeight, sampledWrapT, borderSample);
            const std::size_t texOffset =
                (static_cast<std::size_t>(ty) *
                 static_cast<std::size_t>(sampledWidth) +
                 static_cast<std::size_t>(tx)) * 4u;
            const std::uint8_t storageTexel[4] = {
                borderSample ? sampledBorderRGBA[0] : sampledImage->rgba8[texOffset + 0],
                borderSample ? sampledBorderRGBA[1] : sampledImage->rgba8[texOffset + 1],
                borderSample ? sampledBorderRGBA[2] : sampledImage->rgba8[texOffset + 2],
                borderSample ? sampledBorderRGBA[3] : sampledImage->rgba8[texOffset + 3],
            };
            const std::uint8_t texel[4] = {
                appglImmediateSwizzleComponent(storageTexel, sampledSwizzle[0]),
                appglImmediateSwizzleComponent(storageTexel, sampledSwizzle[1]),
                appglImmediateSwizzleComponent(storageTexel, sampledSwizzle[2]),
                appglImmediateSwizzleComponent(storageTexel, sampledSwizzle[3]),
            };
            appglImmediateApplyTextureEnv(
                impl_->texEnv.mode, sampledTextureBaseClass, baseRGBA, texel, out);
        };
        auto insideScissor = [&](GLint x, GLint y) {
            if (!impl_->state->isEnabled(GL_SCISSOR_TEST)) {
                return true;
            }
            const auto& sc = impl_->state->scissor();
            return x >= sc.x && y >= sc.y &&
                   x < sc.x + sc.width &&
                   y < sc.y + sc.height;
        };
        auto writeDefaultPixel = [&](GLint x, GLint y) {
            if (x < 0 || y < 0 ||
                x >= impl_->defaultFramebufferShadowWidth ||
                y >= impl_->defaultFramebufferShadowHeight ||
                !insideScissor(x, y)) {
                return;
            }
            const std::size_t offset =
                (static_cast<std::size_t>(y) *
                 static_cast<std::size_t>(impl_->defaultFramebufferShadowWidth) +
                 static_cast<std::size_t>(x)) * 4u;
            std::uint8_t rgba[4];
            shadePixel(x, y, rgba);
            for (int c = 0; c < 4; ++c) {
                if (blend.colorMask[c] != GL_FALSE) {
                    impl_->defaultFramebufferRGBA8[offset + static_cast<std::size_t>(c)] =
                        rgba[c];
                }
            }
        };

        if (impl_->state->boundDrawFramebuffer() == 0) {
            const bool hadValidShadow =
                impl_->defaultFramebufferShadowValid &&
                !impl_->defaultFramebufferRGBA8.empty();
            impl_->ensureDefaultFramebufferShadow(
                /*materializePendingClear=*/hadValidShadow);
            if (!hadValidShadow) {
                impl_->materializeDefaultFbShadowClear();
            }
            for (GLint y = y0; y < y1; ++y) {
                for (GLint x = x0; x < x1; ++x) {
                    writeDefaultPixel(x, y);
                }
            }
            impl_->defaultFramebufferShadowValid = true;
            return true;
        }

        GLFramebufferObject* fbo =
            impl_->objects->framebuffers().get(impl_->state->boundDrawFramebuffer());
        if (fbo == nullptr) {
            return false;
        }
        const bool lowerLeft = impl_->state->clipOrigin() != GL_UPPER_LEFT;
        bool painted = false;
        for (GLenum drawBuffer : fbo->drawBuffers) {
            if (drawBuffer == GL_NONE) {
                continue;
            }
            const GLFramebufferAttachment* attachment =
                impl_->framebufferAttachment(*fbo, drawBuffer);
            if (attachment == nullptr) {
                continue;
            }
            if (attachment->kind == GLFramebufferAttachment::Kind::Renderbuffer) {
                GLRenderbufferObject* rb =
                    impl_->objects->renderbuffers().get(attachment->object);
                if (rb == nullptr || !rb->storageDefined ||
                    rb->width <= 0 || rb->height <= 0) {
                    continue;
                }
                const GLint px0 = std::max<GLint>(0, x0);
                const GLint py0 = std::max<GLint>(0, y0);
                const GLint px1 = std::min<GLint>(rb->width, x1);
                const GLint py1 = std::min<GLint>(rb->height, y1);
                const std::size_t bytes =
                    static_cast<std::size_t>(rb->width) *
                    static_cast<std::size_t>(rb->height) * 4u;
                if (rb->rgba8.size() < bytes) {
                    rb->rgba8.assign(bytes, 0);
                }
                for (GLint y = py0; y < py1; ++y) {
                    const GLint sy = lowerLeft ? (rb->height - 1 - y) : y;
                    for (GLint x = px0; x < px1; ++x) {
                        if (!insideScissor(x, y)) {
                            continue;
                        }
                        const std::size_t offset =
                            (static_cast<std::size_t>(sy) *
                             static_cast<std::size_t>(rb->width) +
                             static_cast<std::size_t>(x)) * 4u;
                        std::uint8_t rgba[4];
                        shadePixel(x, y, rgba);
                        for (int c = 0; c < 4; ++c) {
                            if (blend.colorMask[c] != GL_FALSE) {
                                rb->rgba8[offset + static_cast<std::size_t>(c)] =
                                    rgba[c];
                            }
                        }
                    }
                }
                rb->rgba8ShadowClearPending = false;
                rb->colorShadowAuthoritative = true;
                rb->framebufferReadbackYFlip = lowerLeft;
                painted = true;
            } else if (attachment->kind == GLFramebufferAttachment::Kind::Texture) {
                const auto resolved =
                    impl_->resolveTextureAttachmentStorage(*attachment);
                GLTextureObject* texture = resolved.storageTexture;
                if (!resolved.valid || texture == nullptr) {
                    continue;
                }
                auto level = texture->levels.find(resolved.level);
                if (level == texture->levels.end() || !level->second.defined) {
                    continue;
                }
                GLTextureImageLevel& image = level->second;
                const GLsizei tw = std::max<GLsizei>(image.desc.width, 1);
                const GLsizei th = texture->target == GL_TEXTURE_1D
                    ? 1
                    : std::max<GLsizei>(image.desc.height, 1);
                const GLint px0 = std::max<GLint>(0, x0);
                const GLint py0 = std::max<GLint>(0, y0);
                const GLint px1 = std::min<GLint>(tw, x1);
                const GLint py1 = std::min<GLint>(th, y1);
                const GLint layer = std::max<GLint>(resolved.layer, 0);
                const GLsizei depth = std::max<GLsizei>(image.desc.depth, 1);
                if (layer >= depth) {
                    continue;
                }
                const std::size_t layerBytes =
                    static_cast<std::size_t>(tw) *
                    static_cast<std::size_t>(th) * 4u;
                const std::size_t bytes =
                    layerBytes * static_cast<std::size_t>(depth);
                if (image.rgba8.size() < bytes) {
                    image.rgba8.assign(bytes, 0);
                }
                for (GLint y = py0; y < py1; ++y) {
                    const GLint sy = lowerLeft ? (th - 1 - y) : y;
                    for (GLint x = px0; x < px1; ++x) {
                        if (!insideScissor(x, y)) {
                            continue;
                        }
                        const std::size_t offset =
                            static_cast<std::size_t>(layer) * layerBytes +
                            (static_cast<std::size_t>(sy) *
                             static_cast<std::size_t>(tw) +
                             static_cast<std::size_t>(x)) * 4u;
                        std::uint8_t rgba[4];
                        shadePixel(x, y, rgba);
                        for (int c = 0; c < 4; ++c) {
                            if (blend.colorMask[c] != GL_FALSE) {
                                image.rgba8[offset + static_cast<std::size_t>(c)] =
                                    rgba[c];
                            }
                        }
                    }
                }
                texture->colorShadowAuthoritative = true;
                if (lowerLeft) {
                    texture->wasFramebufferRenderedTo = true;
                }
                painted = true;
            }
        }
        return painted;
    };

    void* fixedFunctionSamplerState = nullptr;
    GLenum fixedFunctionTextureInternalFormat = 0;
    GLenum fixedFunctionTextureTarget = 0;
    GLTextureParameters fixedFunctionTextureParams;
    bool fixedFunctionTextureParamsValid = false;
    auto resolveFixedFunctionTexture = [&]() -> void* {
        for (GLenum target : {GL_TEXTURE_2D, GL_TEXTURE_1D}) {
            if (!impl_->state->isEnabled(target)) {
                continue;
            }
            const GLuint texName = impl_->state->boundTextureOnUnit(0, target);
            GLTextureObject* tex = impl_->currentTexture(target);
            if (tex == nullptr || tex->metalTexture == nullptr) {
                continue;
            }
            if (!impl_->sampledTextureCompleteForSampler(*tex, tex->params)) {
                continue;
            }
            if (impl_->rebuildTextureSamplerState(texName, *tex)) {
                fixedFunctionSamplerState = tex->metalSampler;
            }
            fixedFunctionTextureInternalFormat = tex->desc.internalFormat;
            fixedFunctionTextureTarget = target;
            fixedFunctionTextureParams = tex->params;
            fixedFunctionTextureParamsValid = true;
            return impl_->resolveSwizzledTexture(*tex);
        }
        fixedFunctionTextureTarget = 0;
        fixedFunctionTextureParamsValid = false;
        return nullptr;
    };

    if (impl_->encodeImmediateTranslatedProgramDraw(
            drawMode,
            drawVerts,
            drawCount,
            sizeof(Impl::ImmediateModeVertex),
            "glEnd-immediate-translated")) {
        return;
    }

    ImmediateDrawInfo info;
    info.mode = drawMode;
    info.vertices = drawVerts;
    info.vertexCount = drawCount;
    info.vertexStride = sizeof(Impl::ImmediateModeVertex);
    info.mvp = drawMvp;
    info.metalTexture = resolveFixedFunctionTexture();
    info.metalSamplerState = fixedFunctionSamplerState;
    info.textureTarget = fixedFunctionTextureTarget;
    if (fixedFunctionTextureParamsValid) {
        info.textureWrapS = fixedFunctionTextureParams.wrapS;
        info.textureWrapT = fixedFunctionTextureParams.wrapT;
        info.textureMinFilter = fixedFunctionTextureParams.minFilter;
        info.textureMagFilter = fixedFunctionTextureParams.magFilter;
        info.textureBorderColor = appglImmediateResolvedBorderColor(
            fixedFunctionTextureInternalFormat,
            fixedFunctionTextureParams);
    }
    if (appglCompatProfileEnabled()) {
        const std::uint32_t textureBaseClass =
            appglImmediateTextureBaseClass(fixedFunctionTextureInternalFormat);
        if (textureBaseClass != 0u) {
            info.textureEnvMode = impl_->texEnv.mode;
            info.textureBaseClass = textureBaseClass;
        }
    }
    info.fragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
    {
        GLsizei fboW = 0;
        GLsizei fboH = 0;
        void* fboDSTex = nullptr;
        void* fboColTex = impl_->resolveFBOColorTarget(fboW, fboH, fboDSTex);
        info.fboColorTexture = fboColTex;
        info.fboDepthStencilTexture = fboDSTex;
        info.fboWidth = fboW;
        info.fboHeight = fboH;
        const auto& vp = impl_->state->viewport();
        info.viewportX = vp.x;
        info.viewportY = vp.y;
        info.viewportWidth = vp.width;
        info.viewportHeight = vp.height;
        const auto& dr = impl_->state->depthRange();
        info.depthRangeNear = dr.nearValue;
        info.depthRangeFar = dr.farValue;
        info.depthTestEnabled = impl_->state->isEnabled(GL_DEPTH_TEST);
        info.depthFunc = impl_->state->depthState().func;
        info.depthWriteMask = (impl_->state->depthState().writeMask != GL_FALSE);
        {
            const auto& stencil = impl_->state->stencilState();
            info.stencilTestEnabled = impl_->state->isEnabled(GL_STENCIL_TEST);
            info.stencilFrontFunc = stencil.front.func;
            info.stencilFrontRef = stencil.front.ref;
            info.stencilFrontValueMask = stencil.front.valueMask;
            info.stencilFrontFail = stencil.front.fail;
            info.stencilFrontDepthFail = stencil.front.depthFail;
            info.stencilFrontDepthPass = stencil.front.depthPass;
            info.stencilFrontWriteMask = stencil.front.writeMask;
            info.stencilBackFunc = stencil.back.func;
            info.stencilBackRef = stencil.back.ref;
            info.stencilBackValueMask = stencil.back.valueMask;
            info.stencilBackFail = stencil.back.fail;
            info.stencilBackDepthFail = stencil.back.depthFail;
            info.stencilBackDepthPass = stencil.back.depthPass;
            info.stencilBackWriteMask = stencil.back.writeMask;
        }
        info.polygonOffsetEnabled = polygonOffsetEnabledForBatch;
        info.polygonOffsetFactor = rasterStateForPolygonMode.polygonOffsetFactor;
        info.polygonOffsetUnits = rasterStateForPolygonMode.polygonOffsetUnits;
        info.polygonOffsetClamp = rasterStateForPolygonMode.polygonOffsetClamp;
        const auto& glBlend = impl_->state->blendState();
        info.blend.enabled = impl_->state->isEnabled(GL_BLEND);
        info.blend.srcRGB = glBlend.srcRGB;
        info.blend.dstRGB = glBlend.dstRGB;
        info.blend.srcAlpha = glBlend.srcAlpha;
        info.blend.dstAlpha = glBlend.dstAlpha;
        info.blend.equationRGB = glBlend.equationRGB;
        info.blend.equationAlpha = glBlend.equationAlpha;
        info.blend.colorMaskR = (glBlend.colorMask[0] != GL_FALSE);
        info.blend.colorMaskG = (glBlend.colorMask[1] != GL_FALSE);
        info.blend.colorMaskB = (glBlend.colorMask[2] != GL_FALSE);
        info.blend.colorMaskA = (glBlend.colorMask[3] != GL_FALSE);
        info.scissorTestEnabled = impl_->state->isEnabled(GL_SCISSOR_TEST);
        const auto& sc = impl_->state->scissor();
        info.scissorX = sc.x;
        info.scissorY = sc.y;
        info.scissorWidth = sc.width;
        info.scissorHeight = sc.height;
    }

    const bool ok = impl_->frameGraph->encodeImmediateModeDraw(info);
    bool filledRectShadowPainted = false;
    if (ok) {
        impl_->markBoundDrawFramebufferWrites();
        filledRectShadowPainted = paintImmediateFilledRectToShadow();
    }
    if (ok && impl_->state->boundDrawFramebuffer() == 0 &&
        !logicOpLineShadowPainted &&
        !lineStippleShadowPainted &&
        !filledRectShadowPainted) {
        impl_->invalidateDefaultFramebufferShadow();
    }
    if (!ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_ERROR,
            0,
            GL_DEBUG_SEVERITY_HIGH,
            "glEnd: MetalFrameGraph failed to encode immediate-mode draw"
        );
    }
}

void GLContext::newListCompat(GLuint list, GLenum mode) {
    if (list == 0) {
        pushError(GL_INVALID_VALUE, "glNewList", "list name 0 is invalid");
        return;
    }
    if (mode != GL_COMPILE && mode != GL_COMPILE_AND_EXECUTE) {
        pushError(GL_INVALID_ENUM, "glNewList",
                  "mode is not GL_COMPILE or GL_COMPILE_AND_EXECUTE");
        return;
    }
    if (impl_->displayLists.compiling || impl_->immediate.active) {
        pushError(GL_INVALID_OPERATION, "glNewList",
                  "cannot begin a display list while compiling a list or inside glBegin/glEnd");
        return;
    }
    auto& state = impl_->displayLists;
    state.compiling = true;
    state.compileAndExecute = mode == GL_COMPILE_AND_EXECUTE;
    state.currentList = list;
    state.compileCommands.clear();
}

void GLContext::endListCompat() {
    auto& state = impl_->displayLists;
    if (!state.compiling) {
        pushError(GL_INVALID_OPERATION, "glEndList",
                  "no display list is currently being compiled");
        return;
    }
    state.lists[state.currentList].commands = state.compileCommands;
    state.compiling = false;
    state.compileAndExecute = false;
    state.currentList = 0;
    state.compileCommands.clear();
    impl_->immediate.active = false;
    impl_->immediate.suppressNextInvalidEnd = false;
    impl_->immediate.vertices.clear();
    impl_->immediate.materialSnapshots.clear();
}

void GLContext::callListCompat(GLuint list) {
    auto& state = impl_->displayLists;
    if (state.compiling && !state.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::CallList;
        command.list = list;
        state.compileCommands.push_back(command);
        if (!state.compileAndExecute) {
            return;
        }
    }

    const auto found = state.lists.find(list);
    if (found == state.lists.end()) {
        return;
    }
    if (state.replayDepth >= 32) {
        pushError(GL_INVALID_OPERATION, "glCallList",
                  "display list recursion limit reached");
        return;
    }

    const bool previousReplaying = state.replaying;
    state.replaying = true;
    ++state.replayDepth;
    for (const auto& command : found->second.commands) {
        switch (command.kind) {
            case Impl::DisplayListCommand::Kind::Clear:
                clear(static_cast<GLbitfield>(command.enumValue));
                break;
            case Impl::DisplayListCommand::Kind::Begin:
                beginImmediate(command.enumValue);
                break;
            case Impl::DisplayListCommand::Kind::End:
                endImmediate();
                break;
            case Impl::DisplayListCommand::Kind::Vertex:
                immediateVertex(command.values[0],
                                command.values[1],
                                command.values[2],
                                command.values[3]);
                break;
            case Impl::DisplayListCommand::Kind::Color:
                immediateColor(command.values[0],
                               command.values[1],
                               command.values[2],
                               command.values[3]);
                break;
            case Impl::DisplayListCommand::Kind::TexCoord:
                immediateTexCoord(0,
                                  command.values[0],
                                  command.values[1],
                                  command.values[2],
                                  command.values[3]);
                break;
            case Impl::DisplayListCommand::Kind::Enable:
                setEnabled(command.enumValue, command.values[0] != 0.0f);
                break;
            case Impl::DisplayListCommand::Kind::CallList:
                callListCompat(command.list);
                break;
            case Impl::DisplayListCommand::Kind::Bitmap:
                (void)bitmapMaskCompat(command.width,
                                       command.height,
                                       command.values[0],
                                       command.values[1],
                                       command.values[2],
                                       command.values[3],
                                       command.bitmapMask.data());
                break;
            case Impl::DisplayListCommand::Kind::PixelZoom:
                setPixelZoomCompat(command.values[0], command.values[1]);
                break;
            case Impl::DisplayListCommand::Kind::InvalidBegin:
                pushError(GL_INVALID_ENUM, "glBegin",
                          "mode is not a valid primitive mode");
                break;
            case Impl::DisplayListCommand::Kind::ShadeModel:
                setShadeModel(command.enumValue);
                break;
            case Impl::DisplayListCommand::Kind::Normal:
                setNormalCompat(command.values[0], command.values[1], command.values[2]);
                break;
            case Impl::DisplayListCommand::Kind::ColorMaterial:
                setColorMaterialCompat(command.enumValue, command.enumValue2);
                break;
            case Impl::DisplayListCommand::Kind::Material:
                setMaterialFloatCompat(command.enumValue, command.enumValue2, command.values);
                break;
            case Impl::DisplayListCommand::Kind::PushMatrix:
                pushMatrixCompat();
                break;
            case Impl::DisplayListCommand::Kind::PopMatrix:
                popMatrixCompat();
                break;
            case Impl::DisplayListCommand::Kind::DrawClientArrays:
                if (impl_->immediate.active) {
                    pushError(GL_INVALID_OPERATION,
                              command.enumValue2 != 0 ? "glRect" : "glDrawArrays",
                              "display-list draw command is illegal inside glBegin/glEnd");
                    break;
                }
                if (!command.drawClientArrayValid ||
                    command.drawVertices.empty()) {
                    break;
                }
                beginImmediate(command.enumValue);
                if (!impl_->immediate.active) {
                    break;
                }
                for (const auto& vertex : command.drawVertices) {
                    if (command.drawClientArrayHasColor) {
                        immediateColor(vertex.color[0], vertex.color[1],
                                       vertex.color[2], vertex.color[3]);
                    }
                    if (command.drawClientArrayHasTexCoord) {
                        immediateTexCoord(0, vertex.texcoord[0],
                                          vertex.texcoord[1],
                                          vertex.texcoord[2],
                                          vertex.texcoord[3]);
                    }
                    immediateVertex(vertex.position[0], vertex.position[1],
                                    vertex.position[2], vertex.position[3]);
                }
                endImmediate();
                break;
            case Impl::DisplayListCommand::Kind::DrawArraysCall:
                drawArrays(command.enumValue, command.first, command.count, 0);
                break;
            case Impl::DisplayListCommand::Kind::DrawElementsCall: {
                const void* indexPtr = command.drawIndices.empty()
                    ? reinterpret_cast<const void*>(command.indexOffset)
                    : command.drawIndices.data();
                drawElements(command.enumValue, command.count,
                             command.enumValue2, indexPtr, 0);
                break;
            }
            case Impl::DisplayListCommand::Kind::UniformScalarVector: {
                const void* values = nullptr;
                switch (command.uniformElement) {
                    case UniformElementType::Float:
                        values = command.uniformFloats.data();
                        break;
                    case UniformElementType::Int:
                        values = command.uniformInts.data();
                        break;
                    case UniformElementType::UnsignedInt:
                        values = command.uniformUInts.data();
                        break;
                }
                setUniformScalarVector(command.location,
                                       command.uniformElement,
                                       command.vectorSize,
                                       command.count,
                                       values);
                break;
            }
            case Impl::DisplayListCommand::Kind::UniformMatrix:
                setUniformMatrix(command.location,
                                 command.rows,
                                 command.cols,
                                 command.count,
                                 command.transpose,
                                 command.uniformFloats.data());
                break;
            case Impl::DisplayListCommand::Kind::UniformDouble:
                setUniformDouble(command.location,
                                 command.vectorSize,
                                 command.count,
                                 command.uniformDoubles.data());
                break;
            case Impl::DisplayListCommand::Kind::UniformDoubleMatrix:
                setUniformDoubleMatrix(command.location,
                                       command.rows,
                                       command.cols,
                                       command.count,
                                       command.transpose,
                                       command.uniformDoubles.data());
                break;
            case Impl::DisplayListCommand::Kind::ProgramUniformScalarVector: {
                const void* values = nullptr;
                switch (command.uniformElement) {
                    case UniformElementType::Float:
                        values = command.uniformFloats.data();
                        break;
                    case UniformElementType::Int:
                        values = command.uniformInts.data();
                        break;
                    case UniformElementType::UnsignedInt:
                        values = command.uniformUInts.data();
                        break;
                }
                setUniformScalarVectorForProgram(command.program,
                                                 command.location,
                                                 command.uniformElement,
                                                 command.vectorSize,
                                                 command.count,
                                                 values);
                break;
            }
            case Impl::DisplayListCommand::Kind::ProgramUniformMatrix:
                setUniformMatrixForProgram(command.program,
                                           command.location,
                                           command.rows,
                                           command.cols,
                                           command.count,
                                           command.transpose,
                                           command.uniformFloats.data());
                break;
            case Impl::DisplayListCommand::Kind::ProgramUniformDouble:
                setUniformDoubleForProgram(command.program,
                                           command.location,
                                           command.vectorSize,
                                           command.count,
                                           command.uniformDoubles.data());
                break;
            case Impl::DisplayListCommand::Kind::ProgramUniformDoubleMatrix:
                setUniformDoubleMatrixForProgram(command.program,
                                                 command.location,
                                                 command.rows,
                                                 command.cols,
                                                 command.count,
                                                 command.transpose,
                                                 command.uniformDoubles.data());
                break;
            case Impl::DisplayListCommand::Kind::UseProgramStages:
                useProgramStages(command.pipeline,
                                 command.stages,
                                 command.program);
                break;
            case Impl::DisplayListCommand::Kind::UniformBlockBinding:
                uniformBlockBinding(command.program,
                                    command.uniformBlockIndex,
                                    command.uniformBlockBinding);
                break;
        }
    }
    --state.replayDepth;
    state.replaying = previousReplaying;
}

void GLContext::rectCompat(GLfloat x1, GLfloat y1, GLfloat x2, GLfloat y2) {
    auto makeRectCommand = [&]() {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::DrawClientArrays;
        command.enumValue = GL_QUADS;
        command.enumValue2 = 1;
        command.drawClientArrayValid = true;
        command.drawVertices.resize(4);
        command.drawVertices[0].position[0] = x1;
        command.drawVertices[0].position[1] = y1;
        command.drawVertices[0].position[2] = 0.0f;
        command.drawVertices[0].position[3] = 1.0f;
        command.drawVertices[1].position[0] = x2;
        command.drawVertices[1].position[1] = y1;
        command.drawVertices[1].position[2] = 0.0f;
        command.drawVertices[1].position[3] = 1.0f;
        command.drawVertices[2].position[0] = x2;
        command.drawVertices[2].position[1] = y2;
        command.drawVertices[2].position[2] = 0.0f;
        command.drawVertices[2].position[3] = 1.0f;
        command.drawVertices[3].position[0] = x1;
        command.drawVertices[3].position[1] = y2;
        command.drawVertices[3].position[2] = 0.0f;
        command.drawVertices[3].position[3] = 1.0f;
        return command;
    };

    auto emitRect = [&]() {
        if (impl_->immediate.active) {
            pushError(GL_INVALID_OPERATION, "glRect",
                      "glRect is illegal inside glBegin/glEnd");
            return;
        }
        beginImmediate(GL_QUADS);
        if (!impl_->immediate.active) {
            return;
        }
        immediateVertex(x1, y1, 0.0f, 1.0f);
        immediateVertex(x2, y1, 0.0f, 1.0f);
        immediateVertex(x2, y2, 0.0f, 1.0f);
        immediateVertex(x1, y2, 0.0f, 1.0f);
        endImmediate();
    };

    auto& state = impl_->displayLists;
    if (state.compiling && !state.replaying) {
        state.compileCommands.push_back(makeRectCommand());
        if (!state.compileAndExecute) {
            return;
        }
        const bool previousReplaying = state.replaying;
        state.replaying = true;
        emitRect();
        state.replaying = previousReplaying;
        return;
    }

    emitRect();
}

void GLContext::callListsCompat(GLsizei n, GLenum type, const void* lists) {
    if (n < 0) {
        pushError(GL_INVALID_VALUE, "glCallLists", "n must be non-negative");
        return;
    }
    if (n == 0) {
        return;
    }
    if (lists == nullptr) {
        pushError(GL_INVALID_VALUE, "glCallLists",
                  "lists must not be null when n is positive");
        return;
    }
    const auto fetch = [&](GLsizei index, GLuint& out) -> bool {
        switch (type) {
            case GL_BYTE:
                out = static_cast<GLuint>(static_cast<const GLbyte*>(lists)[index]);
                return true;
            case GL_UNSIGNED_BYTE:
                out = static_cast<const GLubyte*>(lists)[index];
                return true;
            case GL_SHORT:
                out = static_cast<GLuint>(static_cast<const GLshort*>(lists)[index]);
                return true;
            case GL_UNSIGNED_SHORT:
                out = static_cast<const GLushort*>(lists)[index];
                return true;
            case GL_INT:
                out = static_cast<GLuint>(static_cast<const GLint*>(lists)[index]);
                return true;
            case GL_UNSIGNED_INT:
                out = static_cast<const GLuint*>(lists)[index];
                return true;
            case GL_FLOAT:
                out = static_cast<GLuint>(static_cast<const GLfloat*>(lists)[index]);
                return true;
            case GL_2_BYTES: {
                const auto* bytes = static_cast<const GLubyte*>(lists) + index * 2;
                out = (static_cast<GLuint>(bytes[0]) << 8u) | bytes[1];
                return true;
            }
            case GL_3_BYTES: {
                const auto* bytes = static_cast<const GLubyte*>(lists) + index * 3;
                out = (static_cast<GLuint>(bytes[0]) << 16u) |
                      (static_cast<GLuint>(bytes[1]) << 8u) |
                      bytes[2];
                return true;
            }
            case GL_4_BYTES: {
                const auto* bytes = static_cast<const GLubyte*>(lists) + index * 4;
                out = (static_cast<GLuint>(bytes[0]) << 24u) |
                      (static_cast<GLuint>(bytes[1]) << 16u) |
                      (static_cast<GLuint>(bytes[2]) << 8u) |
                      bytes[3];
                return true;
            }
            default:
                return false;
        }
    };
    for (GLsizei i = 0; i < n; ++i) {
        GLuint offset = 0;
        if (!fetch(i, offset)) {
            pushError(GL_INVALID_ENUM, "glCallLists",
                      "type is not a valid display-list index type");
            return;
        }
        callListCompat(impl_->displayLists.listBase + offset);
    }
}

void GLContext::deleteListsCompat(GLuint list, GLsizei range) {
    if (range < 0) {
        pushError(GL_INVALID_VALUE, "glDeleteLists", "range must be non-negative");
        return;
    }
    for (GLsizei i = 0; i < range; ++i) {
        impl_->displayLists.lists.erase(list + static_cast<GLuint>(i));
    }
}

GLuint GLContext::genListsCompat(GLsizei range) {
    if (range < 0) {
        pushError(GL_INVALID_VALUE, "glGenLists", "range must be non-negative");
        return 0;
    }
    if (range == 0) {
        return 0;
    }
    auto& state = impl_->displayLists;
    GLuint candidate = std::max<GLuint>(state.nextGeneratedList, 1);
    while (candidate <= std::numeric_limits<GLuint>::max() - static_cast<GLuint>(range)) {
        bool available = true;
        for (GLsizei i = 0; i < range; ++i) {
            if (state.lists.find(candidate + static_cast<GLuint>(i)) != state.lists.end()) {
                available = false;
                candidate += static_cast<GLuint>(i) + 1u;
                break;
            }
        }
        if (available) {
            state.nextGeneratedList = candidate + static_cast<GLuint>(range);
            return candidate;
        }
    }
    return 0;
}

GLboolean GLContext::isListCompat(GLuint list) const {
    return impl_->displayLists.lists.find(list) != impl_->displayLists.lists.end()
        ? GL_TRUE
        : GL_FALSE;
}

void GLContext::listBaseCompat(GLuint base) {
    impl_->displayLists.listBase = base;
}

bool GLContext::recordDisplayListClear(GLbitfield mask) {
    if (impl_->displayLists.compiling && !impl_->displayLists.replaying) {
        Impl::DisplayListCommand command;
        command.kind = Impl::DisplayListCommand::Kind::Clear;
        command.enumValue = static_cast<GLenum>(mask);
        impl_->displayLists.compileCommands.push_back(command);
    }
    return !(impl_->displayLists.compiling &&
             !impl_->displayLists.replaying &&
             !impl_->displayLists.compileAndExecute);
}

bool GLContext::recordDisplayListUniformScalarVector(GLint location,
                                                     UniformElementType element,
                                                     GLint vectorSize,
                                                     GLsizei count,
                                                     const void* values) {
    if (!impl_->displayLists.compiling || impl_->displayLists.replaying) {
        return false;
    }

    Impl::DisplayListCommand command;
    command.kind = Impl::DisplayListCommand::Kind::UniformScalarVector;
    command.location = location;
    command.uniformElement = element;
    command.vectorSize = vectorSize;
    command.count = count;
    const auto elementCount =
        static_cast<std::size_t>(vectorSize) *
        static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    switch (element) {
        case UniformElementType::Float: {
            const auto* src = static_cast<const GLfloat*>(values);
            command.uniformFloats.assign(src, src + elementCount);
            break;
        }
        case UniformElementType::Int: {
            const auto* src = static_cast<const GLint*>(values);
            command.uniformInts.assign(src, src + elementCount);
            break;
        }
        case UniformElementType::UnsignedInt: {
            const auto* src = static_cast<const GLuint*>(values);
            command.uniformUInts.assign(src, src + elementCount);
            break;
        }
    }
    impl_->displayLists.compileCommands.push_back(std::move(command));
    return !impl_->displayLists.compileAndExecute;
}

bool GLContext::recordDisplayListUniformMatrix(GLint location,
                                               GLint rows,
                                               GLint cols,
                                               GLsizei count,
                                               GLboolean transpose,
                                               const GLfloat* values) {
    if (!impl_->displayLists.compiling || impl_->displayLists.replaying) {
        return false;
    }

    Impl::DisplayListCommand command;
    command.kind = Impl::DisplayListCommand::Kind::UniformMatrix;
    command.location = location;
    command.rows = rows;
    command.cols = cols;
    command.count = count;
    command.transpose = transpose;
    const auto elementCount =
        static_cast<std::size_t>(rows) *
        static_cast<std::size_t>(cols) *
        static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    command.uniformFloats.assign(values, values + elementCount);
    impl_->displayLists.compileCommands.push_back(std::move(command));
    return !impl_->displayLists.compileAndExecute;
}

bool GLContext::recordDisplayListUniformDouble(GLint location,
                                               GLint vectorSize,
                                               GLsizei count,
                                               const GLdouble* values) {
    if (!impl_->displayLists.compiling || impl_->displayLists.replaying) {
        return false;
    }

    Impl::DisplayListCommand command;
    command.kind = Impl::DisplayListCommand::Kind::UniformDouble;
    command.location = location;
    command.vectorSize = vectorSize;
    command.count = count;
    const auto elementCount =
        static_cast<std::size_t>(vectorSize) *
        static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    command.uniformDoubles.assign(values, values + elementCount);
    impl_->displayLists.compileCommands.push_back(std::move(command));
    return !impl_->displayLists.compileAndExecute;
}

bool GLContext::recordDisplayListUniformDoubleMatrix(GLint location,
                                                     GLint rows,
                                                     GLint cols,
                                                     GLsizei count,
                                                     GLboolean transpose,
                                                     const GLdouble* values) {
    if (!impl_->displayLists.compiling || impl_->displayLists.replaying) {
        return false;
    }

    Impl::DisplayListCommand command;
    command.kind = Impl::DisplayListCommand::Kind::UniformDoubleMatrix;
    command.location = location;
    command.rows = rows;
    command.cols = cols;
    command.count = count;
    command.transpose = transpose;
    const auto elementCount =
        static_cast<std::size_t>(rows) *
        static_cast<std::size_t>(cols) *
        static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    command.uniformDoubles.assign(values, values + elementCount);
    impl_->displayLists.compileCommands.push_back(std::move(command));
    return !impl_->displayLists.compileAndExecute;
}

bool GLContext::recordDisplayListProgramUniformScalarVector(GLuint program,
                                                            GLint location,
                                                            UniformElementType element,
                                                            GLint vectorSize,
                                                            GLsizei count,
                                                            const void* values) {
    if (!impl_->displayLists.compiling || impl_->displayLists.replaying) {
        return false;
    }

    Impl::DisplayListCommand command;
    command.kind = Impl::DisplayListCommand::Kind::ProgramUniformScalarVector;
    command.program = program;
    command.location = location;
    command.uniformElement = element;
    command.vectorSize = vectorSize;
    command.count = count;
    const auto elementCount =
        static_cast<std::size_t>(vectorSize) *
        static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    switch (element) {
        case UniformElementType::Float: {
            const auto* src = static_cast<const GLfloat*>(values);
            command.uniformFloats.assign(src, src + elementCount);
            break;
        }
        case UniformElementType::Int: {
            const auto* src = static_cast<const GLint*>(values);
            command.uniformInts.assign(src, src + elementCount);
            break;
        }
        case UniformElementType::UnsignedInt: {
            const auto* src = static_cast<const GLuint*>(values);
            command.uniformUInts.assign(src, src + elementCount);
            break;
        }
    }
    impl_->displayLists.compileCommands.push_back(std::move(command));
    return !impl_->displayLists.compileAndExecute;
}

bool GLContext::recordDisplayListProgramUniformMatrix(GLuint program,
                                                      GLint location,
                                                      GLint rows,
                                                      GLint cols,
                                                      GLsizei count,
                                                      GLboolean transpose,
                                                      const GLfloat* values) {
    if (!impl_->displayLists.compiling || impl_->displayLists.replaying) {
        return false;
    }

    Impl::DisplayListCommand command;
    command.kind = Impl::DisplayListCommand::Kind::ProgramUniformMatrix;
    command.program = program;
    command.location = location;
    command.rows = rows;
    command.cols = cols;
    command.count = count;
    command.transpose = transpose;
    const auto elementCount =
        static_cast<std::size_t>(rows) *
        static_cast<std::size_t>(cols) *
        static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    command.uniformFloats.assign(values, values + elementCount);
    impl_->displayLists.compileCommands.push_back(std::move(command));
    return !impl_->displayLists.compileAndExecute;
}

bool GLContext::recordDisplayListProgramUniformDouble(GLuint program,
                                                      GLint location,
                                                      GLint vectorSize,
                                                      GLsizei count,
                                                      const GLdouble* values) {
    if (!impl_->displayLists.compiling || impl_->displayLists.replaying) {
        return false;
    }

    Impl::DisplayListCommand command;
    command.kind = Impl::DisplayListCommand::Kind::ProgramUniformDouble;
    command.program = program;
    command.location = location;
    command.vectorSize = vectorSize;
    command.count = count;
    const auto elementCount =
        static_cast<std::size_t>(vectorSize) *
        static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    command.uniformDoubles.assign(values, values + elementCount);
    impl_->displayLists.compileCommands.push_back(std::move(command));
    return !impl_->displayLists.compileAndExecute;
}

bool GLContext::recordDisplayListProgramUniformDoubleMatrix(GLuint program,
                                                            GLint location,
                                                            GLint rows,
                                                            GLint cols,
                                                            GLsizei count,
                                                            GLboolean transpose,
                                                            const GLdouble* values) {
    if (!impl_->displayLists.compiling || impl_->displayLists.replaying) {
        return false;
    }

    Impl::DisplayListCommand command;
    command.kind = Impl::DisplayListCommand::Kind::ProgramUniformDoubleMatrix;
    command.program = program;
    command.location = location;
    command.rows = rows;
    command.cols = cols;
    command.count = count;
    command.transpose = transpose;
    const auto elementCount =
        static_cast<std::size_t>(rows) *
        static_cast<std::size_t>(cols) *
        static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    command.uniformDoubles.assign(values, values + elementCount);
    impl_->displayLists.compileCommands.push_back(std::move(command));
    return !impl_->displayLists.compileAndExecute;
}

bool GLContext::recordDisplayListUseProgramStages(GLuint pipeline,
                                                  GLbitfield stages,
                                                  GLuint program) {
    if (!impl_->displayLists.compiling || impl_->displayLists.replaying) {
        return false;
    }

    Impl::DisplayListCommand command;
    command.kind = Impl::DisplayListCommand::Kind::UseProgramStages;
    command.pipeline = pipeline;
    command.stages = stages;
    command.program = program;
    impl_->displayLists.compileCommands.push_back(command);
    return !impl_->displayLists.compileAndExecute;
}

bool GLContext::recordDisplayListUniformBlockBinding(GLuint program,
                                                     GLuint uniformBlockIndex,
                                                     GLuint uniformBlockBinding) {
    if (!impl_->displayLists.compiling || impl_->displayLists.replaying) {
        return false;
    }

    Impl::DisplayListCommand command;
    command.kind = Impl::DisplayListCommand::Kind::UniformBlockBinding;
    command.program = program;
    command.uniformBlockIndex = uniformBlockIndex;
    command.uniformBlockBinding = uniformBlockBinding;
    impl_->displayLists.compileCommands.push_back(command);
    return !impl_->displayLists.compileAndExecute;
}

bool GLContext::recordDisplayListClientArrayDraw(GLenum mode,
                                                 GLint first,
                                                 GLsizei count,
                                                 const void* indices,
                                                 GLenum indexType,
                                                 const char* debugLabel) {
    if (!impl_->displayLists.compiling || impl_->displayLists.replaying) {
        return false;
    }

    Impl::DisplayListCommand command;
    command.kind = Impl::DisplayListCommand::Kind::DrawClientArrays;
    command.enumValue = mode;
    bool legacyCaptureAttempted = false;

    if (appglCompatProfileEnabled() && count > 0) {
        const auto& vertexArray = impl_->legacyVertexArray;
        const auto& colorArray = impl_->legacyColorArray;
        const auto& texCoordArray = impl_->legacyTexCoordArray;
        const bool colorArrayHasSource =
            colorArray.pointer != nullptr || colorArray.bufferName != 0;
        const bool colorArrayUsable =
            colorArray.enabled &&
            colorArrayHasSource &&
            colorArray.type == GL_FLOAT &&
            colorArray.size >= 3 && colorArray.size <= 4;
        const bool texCoordArrayHasSource =
            texCoordArray.pointer != nullptr || texCoordArray.bufferName != 0;
        const bool texCoordArrayUsable =
            texCoordArray.enabled &&
            texCoordArrayHasSource &&
            texCoordArray.type == GL_FLOAT &&
            texCoordArray.size >= 1 && texCoordArray.size <= 4;

        if (vertexArray.enabled &&
            (vertexArray.pointer != nullptr || vertexArray.bufferName != 0) &&
            vertexArray.type == GL_FLOAT &&
            vertexArray.size >= 2 && vertexArray.size <= 4) {
            legacyCaptureAttempted = true;
            const std::uint8_t* indexBase = nullptr;
            std::size_t indexAvailableBytes = 0;
            std::size_t indexSize = 0;
            bool indexSourceOk = true;
            if (indexType != 0) {
                switch (indexType) {
                    case GL_UNSIGNED_BYTE:
                        indexSize = sizeof(GLubyte);
                        break;
                    case GL_UNSIGNED_SHORT:
                        indexSize = sizeof(GLushort);
                        break;
                    case GL_UNSIGNED_INT:
                        indexSize = sizeof(GLuint);
                        break;
                    default:
                        indexSourceOk = false;
                        break;
                }
                if (indexSourceOk) {
                    const GLuint vaoName = impl_->state->boundVertexArray();
                    const GLVertexArrayObject* vao = vaoName != 0
                        ? impl_->objects->vertexArrays().get(vaoName)
                        : nullptr;
                    const GLuint elementBufferName =
                        vao != nullptr ? vao->elementArrayBuffer : 0;
                    if (elementBufferName != 0) {
                        const GLBufferObject* elementBuffer =
                            impl_->objects->buffers().get(elementBufferName);
                        if (elementBuffer == nullptr ||
                            elementBuffer->shadowBytes.empty()) {
                            indexSourceOk = false;
                        } else {
                            const std::uintptr_t offset =
                                reinterpret_cast<std::uintptr_t>(indices);
                            if (offset > elementBuffer->shadowBytes.size()) {
                                pushError(GL_INVALID_OPERATION,
                                          debugLabel ? debugLabel : "glDrawElements",
                                          "element array buffer offset is outside buffer storage");
                                indexSourceOk = false;
                            } else {
                                indexBase = elementBuffer->shadowBytes.data() +
                                    static_cast<std::size_t>(offset);
                                indexAvailableBytes =
                                    elementBuffer->shadowBytes.size() -
                                    static_cast<std::size_t>(offset);
                            }
                        }
                    } else if (indices != nullptr) {
                        indexBase = static_cast<const std::uint8_t*>(indices);
                        indexAvailableBytes = static_cast<std::size_t>(-1);
                    } else {
                        pushError(GL_INVALID_OPERATION,
                                  debugLabel ? debugLabel : "glDrawElements",
                                  "client element indices are null");
                        indexSourceOk = false;
                    }
                }
            }

            const std::size_t vertexStride = vertexArray.stride > 0
                ? static_cast<std::size_t>(vertexArray.stride)
                : static_cast<std::size_t>(vertexArray.size) * sizeof(GLfloat);
            const std::size_t colorStride = colorArray.stride > 0
                ? static_cast<std::size_t>(colorArray.stride)
                : static_cast<std::size_t>(colorArray.size) * sizeof(GLfloat);
            const std::size_t texCoordStride = texCoordArray.stride > 0
                ? static_cast<std::size_t>(texCoordArray.stride)
                : static_cast<std::size_t>(texCoordArray.size) * sizeof(GLfloat);

            auto resolveArraySource = [&](const Impl::LegacyClientArray& array,
                                          const char* label,
                                          const std::uint8_t*& base,
                                          std::size_t& availableBytes) -> bool {
                if (array.bufferName != 0) {
                    const GLBufferObject* buffer =
                        impl_->objects->buffers().get(array.bufferName);
                    if (buffer == nullptr || buffer->shadowBytes.empty()) {
                        return false;
                    }
                    const std::uintptr_t offset =
                        reinterpret_cast<std::uintptr_t>(array.pointer);
                    if (offset > buffer->shadowBytes.size()) {
                        pushError(GL_INVALID_OPERATION, label,
                                  "legacy client array VBO offset is outside buffer storage");
                        return false;
                    }
                    base = buffer->shadowBytes.data() + static_cast<std::size_t>(offset);
                    availableBytes = buffer->shadowBytes.size() - static_cast<std::size_t>(offset);
                    return true;
                }
                if (array.pointer == nullptr) {
                    return false;
                }
                base = static_cast<const std::uint8_t*>(array.pointer);
                availableBytes = static_cast<std::size_t>(-1);
                return true;
            };

            const std::uint8_t* vertexBase = nullptr;
            std::size_t vertexAvailableBytes = 0;
            bool captureOk = indexSourceOk &&
                resolveArraySource(vertexArray, "glVertexPointer",
                                   vertexBase, vertexAvailableBytes);
            const std::uint8_t* colorBase = nullptr;
            std::size_t colorAvailableBytes = 0;
            if (captureOk && colorArrayUsable) {
                captureOk = resolveArraySource(colorArray, "glColorPointer",
                                               colorBase, colorAvailableBytes);
            }
            const std::uint8_t* texCoordBase = nullptr;
            std::size_t texCoordAvailableBytes = 0;
            if (captureOk && texCoordArrayUsable) {
                captureOk = resolveArraySource(texCoordArray, "glTexCoordPointer",
                                               texCoordBase, texCoordAvailableBytes);
            }

            auto indexAt = [&](GLsizei i, GLuint& out) -> bool {
                if (indexType == 0) {
                    const GLint logical = first + i;
                    if (logical < 0) {
                        return false;
                    }
                    out = static_cast<GLuint>(logical);
                    return true;
                }
                const std::size_t indexOffset =
                    static_cast<std::size_t>(i) * indexSize;
                if (indexOffset > indexAvailableBytes ||
                    indexSize > indexAvailableBytes - indexOffset) {
                    return false;
                }
                const auto* indexPtr = indexBase + indexOffset;
                switch (indexType) {
                    case GL_UNSIGNED_BYTE:
                        out = *reinterpret_cast<const GLubyte*>(indexPtr);
                        return true;
                    case GL_UNSIGNED_SHORT:
                        out = *reinterpret_cast<const GLushort*>(indexPtr);
                        return true;
                    case GL_UNSIGNED_INT:
                        out = *reinterpret_cast<const GLuint*>(indexPtr);
                        return true;
                    default:
                        return false;
                }
            };

            if (captureOk) {
                command.drawVertices.reserve(static_cast<std::size_t>(count));
                for (GLsizei i = 0; i < count; ++i) {
                    GLuint srcIndex = 0;
                    if (!indexAt(i, srcIndex)) {
                        captureOk = false;
                        break;
                    }
                    const std::size_t vertexOffset =
                        static_cast<std::size_t>(srcIndex) * vertexStride;
                    const std::size_t vertexNeed =
                        static_cast<std::size_t>(vertexArray.size) * sizeof(GLfloat);
                    if (vertexOffset > vertexAvailableBytes ||
                        vertexNeed > vertexAvailableBytes - vertexOffset) {
                        captureOk = false;
                        break;
                    }
                    const auto* vp =
                        reinterpret_cast<const GLfloat*>(vertexBase + vertexOffset);

                    const GLfloat* cp = nullptr;
                    if (colorArrayUsable) {
                        const std::size_t colorOffset =
                            static_cast<std::size_t>(srcIndex) * colorStride;
                        const std::size_t colorNeed =
                            static_cast<std::size_t>(colorArray.size) * sizeof(GLfloat);
                        if (colorOffset > colorAvailableBytes ||
                            colorNeed > colorAvailableBytes - colorOffset) {
                            captureOk = false;
                            break;
                        }
                        cp = reinterpret_cast<const GLfloat*>(colorBase + colorOffset);
                    }

                    const GLfloat* tp = nullptr;
                    if (texCoordArrayUsable) {
                        const std::size_t texCoordOffset =
                            static_cast<std::size_t>(srcIndex) * texCoordStride;
                        const std::size_t texCoordNeed =
                            static_cast<std::size_t>(texCoordArray.size) * sizeof(GLfloat);
                        if (texCoordOffset > texCoordAvailableBytes ||
                            texCoordNeed > texCoordAvailableBytes - texCoordOffset) {
                            captureOk = false;
                            break;
                        }
                        tp = reinterpret_cast<const GLfloat*>(texCoordBase + texCoordOffset);
                    }

                    Impl::ImmediateModeVertex v{};
                    v.position[0] = vp[0];
                    v.position[1] = vp[1];
                    v.position[2] = vertexArray.size >= 3 ? vp[2] : 0.0f;
                    v.position[3] = vertexArray.size >= 4 ? vp[3] : 1.0f;
                    if (cp != nullptr) {
                        v.color[0] = cp[0];
                        v.color[1] = cp[1];
                        v.color[2] = cp[2];
                        v.color[3] = colorArray.size >= 4 ? cp[3] : 1.0f;
                    }
                    if (tp != nullptr) {
                        v.texcoord[0] = tp[0];
                        v.texcoord[1] = texCoordArray.size >= 2 ? tp[1] : 0.0f;
                        v.texcoord[2] = texCoordArray.size >= 3 ? tp[2] : 0.0f;
                        v.texcoord[3] = texCoordArray.size >= 4 ? tp[3] : 1.0f;
                    }
                    command.drawVertices.push_back(v);
                }
            }

            if (captureOk) {
                command.drawClientArrayValid = true;
                command.drawClientArrayHasColor = colorArrayUsable;
                command.drawClientArrayHasTexCoord = texCoordArrayUsable;
            } else {
                command.drawVertices.clear();
            }
        }
    }

    if (!legacyCaptureAttempted) {
        Impl::DisplayListCommand replayCommand;
        replayCommand.kind = (indexType == 0)
            ? Impl::DisplayListCommand::Kind::DrawArraysCall
            : Impl::DisplayListCommand::Kind::DrawElementsCall;
        replayCommand.enumValue = mode;
        replayCommand.enumValue2 = indexType;
        replayCommand.first = first;
        replayCommand.count = count;

        if (indexType != 0) {
            std::size_t indexSize = 0;
            switch (indexType) {
                case GL_UNSIGNED_BYTE:
                    indexSize = sizeof(GLubyte);
                    break;
                case GL_UNSIGNED_SHORT:
                    indexSize = sizeof(GLushort);
                    break;
                case GL_UNSIGNED_INT:
                    indexSize = sizeof(GLuint);
                    break;
                default:
                    return false;
            }

            const GLuint vaoName = impl_->state->boundVertexArray();
            const GLVertexArrayObject* vao = vaoName != 0
                ? impl_->objects->vertexArrays().get(vaoName)
                : nullptr;
            const GLuint elementBufferName =
                vao != nullptr ? vao->elementArrayBuffer : 0;
            if (elementBufferName != 0) {
                replayCommand.indexOffset =
                    reinterpret_cast<std::uintptr_t>(indices);
            } else {
                if (indices == nullptr) {
                    return false;
                }
                const auto byteCount =
                    static_cast<std::size_t>(count) * indexSize;
                replayCommand.drawIndices.resize(byteCount);
                std::memcpy(replayCommand.drawIndices.data(), indices, byteCount);
            }
        }

        impl_->displayLists.compileCommands.push_back(std::move(replayCommand));
        return !impl_->displayLists.compileAndExecute;
    }

    impl_->displayLists.compileCommands.push_back(std::move(command));
    return !impl_->displayLists.compileAndExecute;
}

bool GLContext::rejectDisplayListCompileInstancedDraw(const char* debugLabel) {
    if (!impl_->displayLists.compiling || impl_->displayLists.replaying) {
        return false;
    }
    pushError(GL_INVALID_OPERATION,
              debugLabel ? debugLabel : "glDrawArraysInstanced",
              "instanced draw commands are invalid during display list compilation");
    return true;
}

bool GLContext::encodeLegacyClientArrayDraw(GLenum mode,
                                            GLint first,
                                            GLsizei count,
                                            const void* indices,
                                            GLenum indexType,
                                            const char* debugLabel) {
    if (!appglCompatProfileEnabled() || count <= 0) {
        return false;
    }
    (void)debugLabel;
    const auto& vertexArray = impl_->legacyVertexArray;
    const auto& colorArray = impl_->legacyColorArray;
    const auto& texCoordArray = impl_->legacyTexCoordArray;
    const bool colorArrayHasSource =
        colorArray.pointer != nullptr || colorArray.bufferName != 0;
    const bool colorArrayUsable =
        colorArray.enabled &&
        colorArrayHasSource &&
        colorArray.type == GL_FLOAT &&
        colorArray.size >= 3 && colorArray.size <= 4;
    const bool texCoordArrayHasSource =
        texCoordArray.pointer != nullptr || texCoordArray.bufferName != 0;
    const bool texCoordArrayUsable =
        texCoordArray.enabled &&
        texCoordArrayHasSource &&
        texCoordArray.type == GL_FLOAT &&
        texCoordArray.size >= 1 && texCoordArray.size <= 4;
    bool synthesizeFacingColors = false;
    if (!colorArrayUsable) {
        const GLuint programName = impl_->state->currentProgram();
        const GLProgramObject* program = programName != 0
            ? impl_->objects->programs().get(programName)
            : nullptr;
        if (program != nullptr) {
            if (program->fragmentMSL.find("front_facing") != std::string::npos ||
                program->fragmentMSL.find("[[front_facing]]") != std::string::npos) {
                synthesizeFacingColors = true;
            }
            for (GLuint shaderName : program->attachedShaders) {
                if (synthesizeFacingColors) {
                    break;
                }
                const GLShaderObject* shader = impl_->objects->shaders().get(shaderName);
                if (shader != nullptr &&
                    shader->source.find("gl_FrontFacing") != std::string::npos) {
                    synthesizeFacingColors = true;
                    break;
                }
            }
        }
    }
    if (!vertexArray.enabled ||
        (vertexArray.pointer == nullptr && vertexArray.bufferName == 0) ||
        vertexArray.type != GL_FLOAT ||
        vertexArray.size < 2 || vertexArray.size > 4) {
        return false;
    }
    if (indexType != 0 && indices == nullptr) {
        pushError(GL_INVALID_OPERATION, debugLabel ? debugLabel : "glDrawElements",
                  "client element indices are null");
        return false;
    }

    void* fixedFunctionSamplerState = nullptr;
    GLenum fixedFunctionTextureInternalFormat = 0;
    GLenum fixedFunctionTextureTarget = 0;
    GLTextureParameters fixedFunctionTextureParams;
    bool fixedFunctionTextureParamsValid = false;
    auto resolveFixedFunctionTexture = [&]() -> void* {
        for (GLenum target : {GL_TEXTURE_2D, GL_TEXTURE_1D}) {
            if (!impl_->state->isEnabled(target)) {
                continue;
            }
            const GLuint texName = impl_->state->boundTextureOnUnit(0, target);
            GLTextureObject* tex = impl_->currentTexture(target);
            if (tex == nullptr || tex->metalTexture == nullptr) {
                continue;
            }
            if (!impl_->sampledTextureCompleteForSampler(*tex, tex->params)) {
                continue;
            }
            if (impl_->rebuildTextureSamplerState(texName, *tex)) {
                fixedFunctionSamplerState = tex->metalSampler;
            }
            fixedFunctionTextureInternalFormat = tex->desc.internalFormat;
            fixedFunctionTextureTarget = target;
            fixedFunctionTextureParams = tex->params;
            fixedFunctionTextureParamsValid = true;
            return impl_->resolveSwizzledTexture(*tex);
        }
        fixedFunctionTextureTarget = 0;
        fixedFunctionTextureParamsValid = false;
        return nullptr;
    };

    const std::size_t vertexStride = vertexArray.stride > 0
        ? static_cast<std::size_t>(vertexArray.stride)
        : static_cast<std::size_t>(vertexArray.size) * sizeof(GLfloat);
    const std::size_t colorStride = colorArray.stride > 0
        ? static_cast<std::size_t>(colorArray.stride)
        : static_cast<std::size_t>(colorArray.size) * sizeof(GLfloat);
    const std::size_t texCoordStride = texCoordArray.stride > 0
        ? static_cast<std::size_t>(texCoordArray.stride)
        : static_cast<std::size_t>(texCoordArray.size) * sizeof(GLfloat);
    auto resolveArraySource = [&](const Impl::LegacyClientArray& array,
                                  const char* label,
                                  const std::uint8_t*& base,
                                  std::size_t& availableBytes) -> bool {
        if (array.bufferName != 0) {
            const GLBufferObject* buffer =
                impl_->objects->buffers().get(array.bufferName);
            if (buffer == nullptr || buffer->shadowBytes.empty()) {
                return false;
            }
            const std::uintptr_t offset =
                reinterpret_cast<std::uintptr_t>(array.pointer);
            if (offset > buffer->shadowBytes.size()) {
                pushError(GL_INVALID_OPERATION, label, "legacy client array VBO offset is outside buffer storage");
                return false;
            }
            base = buffer->shadowBytes.data() + static_cast<std::size_t>(offset);
            availableBytes = buffer->shadowBytes.size() - static_cast<std::size_t>(offset);
            return true;
        }
        if (array.pointer == nullptr) {
            return false;
        }
        base = static_cast<const std::uint8_t*>(array.pointer);
        availableBytes = static_cast<std::size_t>(-1);
        return true;
    };
    const std::uint8_t* vertexBase = nullptr;
    std::size_t vertexAvailableBytes = 0;
    if (!resolveArraySource(vertexArray, "glVertexPointer", vertexBase, vertexAvailableBytes)) {
        return false;
    }
    const std::uint8_t* colorBase = nullptr;
    std::size_t colorAvailableBytes = 0;
    if (colorArrayUsable &&
        !resolveArraySource(colorArray, "glColorPointer", colorBase, colorAvailableBytes)) {
        return false;
    }
    const std::uint8_t* texCoordBase = nullptr;
    std::size_t texCoordAvailableBytes = 0;
    if (texCoordArrayUsable &&
        !resolveArraySource(texCoordArray, "glTexCoordPointer", texCoordBase, texCoordAvailableBytes)) {
        return false;
    }

    auto indexAt = [&](GLsizei i, GLuint& out) -> bool {
        if (indexType == 0) {
            const GLint logical = first + i;
            if (logical < 0) {
                return false;
            }
            out = static_cast<GLuint>(logical);
            return true;
        }
        switch (indexType) {
            case GL_UNSIGNED_BYTE:
                out = static_cast<const GLubyte*>(indices)[i];
                return true;
            case GL_UNSIGNED_SHORT:
                out = static_cast<const GLushort*>(indices)[i];
                return true;
            case GL_UNSIGNED_INT:
                out = static_cast<const GLuint*>(indices)[i];
                return true;
            default:
                return false;
        }
    };

    std::vector<Impl::ImmediateModeVertex> source;
    source.reserve(static_cast<std::size_t>(count));
    for (GLsizei i = 0; i < count; ++i) {
        GLuint srcIndex = 0;
        if (!indexAt(i, srcIndex)) {
            return false;
        }
        const std::size_t vertexOffset =
            static_cast<std::size_t>(srcIndex) * vertexStride;
        const std::size_t vertexNeed =
            static_cast<std::size_t>(vertexArray.size) * sizeof(GLfloat);
        if (vertexOffset > vertexAvailableBytes ||
            vertexNeed > vertexAvailableBytes - vertexOffset) {
            return false;
        }
        const auto* vp = reinterpret_cast<const GLfloat*>(vertexBase + vertexOffset);
        const GLfloat* cp = nullptr;
        if (colorArrayUsable) {
            const std::size_t colorOffset =
                static_cast<std::size_t>(srcIndex) * colorStride;
            const std::size_t colorNeed =
                static_cast<std::size_t>(colorArray.size) * sizeof(GLfloat);
            if (colorOffset > colorAvailableBytes ||
                colorNeed > colorAvailableBytes - colorOffset) {
                return false;
            }
            cp = reinterpret_cast<const GLfloat*>(colorBase + colorOffset);
        }
        const GLfloat* tp = nullptr;
        if (texCoordArrayUsable) {
            const std::size_t texCoordOffset =
                static_cast<std::size_t>(srcIndex) * texCoordStride;
            const std::size_t texCoordNeed =
                static_cast<std::size_t>(texCoordArray.size) * sizeof(GLfloat);
            if (texCoordOffset > texCoordAvailableBytes ||
                texCoordNeed > texCoordAvailableBytes - texCoordOffset) {
                return false;
            }
            tp = reinterpret_cast<const GLfloat*>(texCoordBase + texCoordOffset);
        }
        Impl::ImmediateModeVertex v{};
        v.position[0] = vp[0];
        v.position[1] = vp[1];
        v.position[2] = vertexArray.size >= 3 ? vp[2] : 0.0f;
        v.position[3] = vertexArray.size >= 4 ? vp[3] : 1.0f;
        v.color[0] = cp != nullptr ? cp[0] : impl_->immediate.currentColor[0];
        v.color[1] = cp != nullptr ? cp[1] : impl_->immediate.currentColor[1];
        v.color[2] = cp != nullptr ? cp[2] : impl_->immediate.currentColor[2];
        v.color[3] = (cp != nullptr && colorArray.size >= 4)
            ? cp[3]
            : impl_->immediate.currentColor[3];
        v.texcoord[0] = tp != nullptr ? tp[0] : impl_->immediate.currentTexcoord[0];
        v.texcoord[1] = (tp != nullptr && texCoordArray.size >= 2)
            ? tp[1]
            : impl_->immediate.currentTexcoord[1];
        v.texcoord[2] = (tp != nullptr && texCoordArray.size >= 3)
            ? tp[2]
            : impl_->immediate.currentTexcoord[2];
        v.texcoord[3] = (tp != nullptr && texCoordArray.size >= 4)
            ? tp[3]
            : impl_->immediate.currentTexcoord[3];
        source.push_back(v);
    }

    auto recordSelectPrimitives = [&](GLenum primitiveMode,
                                      const Impl::ImmediateModeVertex* verts,
                                      std::size_t vertexCount) {
        if (verts == nullptr || vertexCount == 0 ||
            impl_->selection.renderMode != GL_SELECT) {
            return;
        }
        const Matrix4 mvp = impl_->matrixState.modelViewProjection();
        const auto& dr = impl_->state->depthRange();
        struct SelectVertex {
            float x = 0.0f;
            float y = 0.0f;
            float z = 0.0f;
            bool ok = false;
        };
        auto toSelectVertex = [&](const Impl::ImmediateModeVertex& src) {
            SelectVertex out;
            float clip[4] = {};
            for (int row = 0; row < 4; ++row) {
                clip[row] =
                    mvp.m[0 * 4 + row] * src.position[0] +
                    mvp.m[1 * 4 + row] * src.position[1] +
                    mvp.m[2 * 4 + row] * src.position[2] +
                    mvp.m[3 * 4 + row] * src.position[3];
            }
            if (clip[3] == 0.0f ||
                !std::isfinite(clip[0]) ||
                !std::isfinite(clip[1]) ||
                !std::isfinite(clip[2]) ||
                !std::isfinite(clip[3])) {
                return out;
            }
            const float invW = 1.0f / clip[3];
            out.x = clip[0] * invW;
            out.y = clip[1] * invW;
            out.z = clip[2] * invW;
            out.ok = true;
            return out;
        };
        auto depthToUint = [&](float ndcZ) {
            const double windowZ =
                static_cast<double>(dr.nearValue) +
                (static_cast<double>(ndcZ) + 1.0) * 0.5 *
                    static_cast<double>(dr.farValue - dr.nearValue);
            const double clamped = std::clamp(windowZ, 0.0, 1.0);
            return static_cast<GLuint>(
                std::llround(clamped * 4294967294.0));
        };
        auto recordPrimitive = [&](std::initializer_list<const Impl::ImmediateModeVertex*> primitive) {
            float minX = std::numeric_limits<float>::infinity();
            float minY = std::numeric_limits<float>::infinity();
            float minZ = std::numeric_limits<float>::infinity();
            float maxX = -std::numeric_limits<float>::infinity();
            float maxY = -std::numeric_limits<float>::infinity();
            float maxZ = -std::numeric_limits<float>::infinity();
            for (const auto* v : primitive) {
                if (v == nullptr) {
                    return;
                }
                const SelectVertex sv = toSelectVertex(*v);
                if (!sv.ok) {
                    return;
                }
                minX = std::min(minX, sv.x);
                minY = std::min(minY, sv.y);
                minZ = std::min(minZ, sv.z);
                maxX = std::max(maxX, sv.x);
                maxY = std::max(maxY, sv.y);
                maxZ = std::max(maxZ, sv.z);
            }
            if (minX > 1.0f || maxX < -1.0f ||
                minY > 1.0f || maxY < -1.0f ||
                minZ > 1.0f || maxZ < -1.0f) {
                return;
            }
            recordSelectHitCompat(depthToUint(minZ), depthToUint(maxZ));
        };

        switch (primitiveMode) {
            case GL_POINTS:
                for (std::size_t i = 0; i < vertexCount; ++i) {
                    recordPrimitive({&verts[i]});
                }
                break;
            case GL_LINES:
                for (std::size_t i = 0; i + 1 < vertexCount; i += 2) {
                    recordPrimitive({&verts[i], &verts[i + 1]});
                }
                break;
            case GL_LINE_STRIP:
                for (std::size_t i = 0; i + 1 < vertexCount; ++i) {
                    recordPrimitive({&verts[i], &verts[i + 1]});
                }
                break;
            case GL_LINE_LOOP:
                for (std::size_t i = 0; i + 1 < vertexCount; ++i) {
                    recordPrimitive({&verts[i], &verts[i + 1]});
                }
                if (vertexCount > 2) {
                    recordPrimitive({&verts[vertexCount - 1], &verts[0]});
                }
                break;
            case GL_TRIANGLES:
                for (std::size_t i = 0; i + 2 < vertexCount; i += 3) {
                    recordPrimitive({&verts[i], &verts[i + 1], &verts[i + 2]});
                }
                break;
            case GL_TRIANGLE_STRIP:
                for (std::size_t i = 0; i + 2 < vertexCount; ++i) {
                    recordPrimitive({&verts[i], &verts[i + 1], &verts[i + 2]});
                }
                break;
            case GL_TRIANGLE_FAN:
                for (std::size_t i = 1; i + 1 < vertexCount; ++i) {
                    recordPrimitive({&verts[0], &verts[i], &verts[i + 1]});
                }
                break;
            case GL_QUADS:
                for (std::size_t i = 0; i + 3 < vertexCount; i += 4) {
                    recordPrimitive({&verts[i], &verts[i + 1],
                                     &verts[i + 2], &verts[i + 3]});
                }
                break;
            case GL_QUAD_STRIP:
                for (std::size_t i = 0; i + 3 < vertexCount; i += 2) {
                    recordPrimitive({&verts[i], &verts[i + 1],
                                     &verts[i + 3], &verts[i + 2]});
                }
                break;
            case GL_POLYGON:
                if (vertexCount >= 3) {
                    float minX = std::numeric_limits<float>::infinity();
                    float minY = std::numeric_limits<float>::infinity();
                    float minZ = std::numeric_limits<float>::infinity();
                    float maxX = -std::numeric_limits<float>::infinity();
                    float maxY = -std::numeric_limits<float>::infinity();
                    float maxZ = -std::numeric_limits<float>::infinity();
                    bool ok = true;
                    for (std::size_t i = 0; i < vertexCount; ++i) {
                        const SelectVertex sv = toSelectVertex(verts[i]);
                        if (!sv.ok) {
                            ok = false;
                            break;
                        }
                        minX = std::min(minX, sv.x);
                        minY = std::min(minY, sv.y);
                        minZ = std::min(minZ, sv.z);
                        maxX = std::max(maxX, sv.x);
                        maxY = std::max(maxY, sv.y);
                        maxZ = std::max(maxZ, sv.z);
                    }
                    if (ok &&
                        !(minX > 1.0f || maxX < -1.0f ||
                          minY > 1.0f || maxY < -1.0f ||
                          minZ > 1.0f || maxZ < -1.0f)) {
                        recordSelectHitCompat(depthToUint(minZ),
                                              depthToUint(maxZ));
                    }
                }
                break;
            default:
                break;
        }
    };
    if (impl_->selection.renderMode == GL_SELECT) {
        recordSelectPrimitives(mode, source.data(), source.size());
        return true;
    }
    if (impl_->frameGraph == nullptr) {
        return false;
    }

    auto& fillVertices = impl_->legacyClientArrayVertices;
    fillVertices.clear();
    std::vector<Impl::ImmediateModeVertex> lineVertices;
    std::vector<Impl::ImmediateModeVertex> pointVertices;
    const bool flat = (impl_->fixedFunctionShadeModel == GL_FLAT);
    auto appendTriangle = [&](const Impl::ImmediateModeVertex& a,
                              const Impl::ImmediateModeVertex& b,
                              const Impl::ImmediateModeVertex& c,
                              const Impl::ImmediateModeVertex& provoking) {
        Impl::ImmediateModeVertex ta = a;
        Impl::ImmediateModeVertex tb = b;
        Impl::ImmediateModeVertex tc = c;
        if (flat) {
            std::memcpy(ta.color, provoking.color, sizeof(ta.color));
            std::memcpy(tb.color, provoking.color, sizeof(tb.color));
            std::memcpy(tc.color, provoking.color, sizeof(tc.color));
        }
        fillVertices.push_back(ta);
        fillVertices.push_back(tb);
        fillVertices.push_back(tc);
    };
    auto appendLine = [&](const Impl::ImmediateModeVertex& a,
                          const Impl::ImmediateModeVertex& b,
                          const Impl::ImmediateModeVertex& provoking) {
        Impl::ImmediateModeVertex ta = a;
        Impl::ImmediateModeVertex tb = b;
        if (flat) {
            std::memcpy(ta.color, provoking.color, sizeof(ta.color));
            std::memcpy(tb.color, provoking.color, sizeof(tb.color));
        }
        lineVertices.push_back(ta);
        lineVertices.push_back(tb);
    };
    auto appendPoint = [&](const Impl::ImmediateModeVertex& a,
                           const Impl::ImmediateModeVertex& provoking) {
        Impl::ImmediateModeVertex ta = a;
        if (flat) {
            std::memcpy(ta.color, provoking.color, sizeof(ta.color));
        }
        pointVertices.push_back(ta);
    };
    const auto& raster = impl_->state->rasterState();
    auto polygonIsFrontFacing = [&](const Impl::ImmediateModeVertex* verts,
                                    std::size_t n) {
        double twiceArea = 0.0;
        for (std::size_t i = 0; i < n; ++i) {
            const auto& a = verts[i];
            const auto& b = verts[(i + 1) % n];
            twiceArea += static_cast<double>(a.position[0]) * b.position[1] -
                         static_cast<double>(b.position[0]) * a.position[1];
        }
        const bool ccw = twiceArea >= 0.0;
        return raster.frontFace == GL_CW ? !ccw : ccw;
    };
    auto polygonFaceCulled = [&](bool frontFacing) {
        if (!impl_->state->isEnabled(GL_CULL_FACE)) {
            return false;
        }
        switch (raster.cullFaceMode) {
            case GL_FRONT:
                return frontFacing;
            case GL_BACK:
                return !frontFacing;
            case GL_FRONT_AND_BACK:
                return true;
            default:
                return false;
        }
    };
    auto appendPolygon = [&](const Impl::ImmediateModeVertex* verts,
                             std::size_t n,
                             const Impl::ImmediateModeVertex& provoking) {
        if (n < 3) {
            return;
        }
        const bool frontFacing = polygonIsFrontFacing(verts, n);
        if (polygonFaceCulled(frontFacing)) {
            return;
        }
        const GLenum polygonMode = frontFacing
            ? raster.polygonModeFront
            : raster.polygonModeBack;
        auto withFacingColor = [&](Impl::ImmediateModeVertex v) {
            if (synthesizeFacingColors) {
                const bool frontColor = frontFacing;
                v.color[0] = frontColor ? 1.0f : 0.0f;
                v.color[1] = frontColor ? 0.0f : 1.0f;
                v.color[2] = 0.0f;
                v.color[3] = 1.0f;
            }
            return v;
        };
        switch (polygonMode) {
            case GL_LINE:
                lineVertices.reserve(lineVertices.size() + n * 2);
                for (std::size_t i = 0; i + 1 < n; ++i) {
                    appendLine(withFacingColor(verts[i]),
                               withFacingColor(verts[i + 1]),
                               withFacingColor(provoking));
                }
                appendLine(withFacingColor(verts[n - 1]),
                           withFacingColor(verts[0]),
                           withFacingColor(provoking));
                break;
            case GL_POINT:
                pointVertices.reserve(pointVertices.size() + n);
                for (std::size_t i = 0; i < n; ++i) {
                    appendPoint(withFacingColor(verts[i]), withFacingColor(provoking));
                }
                break;
            case GL_FILL:
            default:
                fillVertices.reserve(fillVertices.size() + (n - 2) * 3);
                for (std::size_t i = 1; i + 1 < n; ++i) {
                    appendTriangle(withFacingColor(verts[0]),
                                   withFacingColor(verts[i]),
                                   withFacingColor(verts[i + 1]),
                                   withFacingColor(provoking));
                }
                break;
        }
    };
    auto withNonPolygonFacingColor = [&](Impl::ImmediateModeVertex v) {
        if (synthesizeFacingColors) {
            v.color[0] = 1.0f;
            v.color[1] = 0.0f;
            v.color[2] = 0.0f;
            v.color[3] = 1.0f;
        }
        return v;
    };

    switch (mode) {
        case GL_POINTS:
            pointVertices.reserve(source.size());
            for (const auto& v : source) {
                const auto front = withNonPolygonFacingColor(v);
                appendPoint(front, front);
            }
            break;
        case GL_LINES:
            lineVertices.reserve((source.size() / 2) * 2);
            for (std::size_t i = 0; i + 1 < source.size(); i += 2) {
                appendLine(withNonPolygonFacingColor(source[i]),
                           withNonPolygonFacingColor(source[i + 1]),
                           withNonPolygonFacingColor(source[i + 1]));
            }
            break;
        case GL_LINE_STRIP:
            if (source.size() >= 2) {
                lineVertices.reserve((source.size() - 1) * 2);
                for (std::size_t i = 0; i + 1 < source.size(); ++i) {
                    appendLine(withNonPolygonFacingColor(source[i]),
                               withNonPolygonFacingColor(source[i + 1]),
                               withNonPolygonFacingColor(source[i + 1]));
                }
            }
            break;
        case GL_LINE_LOOP:
            if (source.size() >= 2) {
                lineVertices.reserve(source.size() * 2);
                for (std::size_t i = 0; i + 1 < source.size(); ++i) {
                    appendLine(withNonPolygonFacingColor(source[i]),
                               withNonPolygonFacingColor(source[i + 1]),
                               withNonPolygonFacingColor(source[i + 1]));
                }
                appendLine(withNonPolygonFacingColor(source.back()),
                           withNonPolygonFacingColor(source.front()),
                           withNonPolygonFacingColor(source.front()));
            }
            break;
        case GL_TRIANGLES:
            for (std::size_t i = 0; i + 2 < source.size(); i += 3) {
                appendPolygon(&source[i], 3, source[i + 2]);
            }
            break;
        case GL_TRIANGLE_STRIP:
            if (source.size() >= 3) {
                for (std::size_t i = 0; i + 2 < source.size(); ++i) {
                    const Impl::ImmediateModeVertex tri[3] = {
                        source[i + 0], source[i + 1], source[i + 2]
                    };
                    appendPolygon(tri, 3, source[i + 2]);
                }
            }
            break;
        case GL_TRIANGLE_FAN:
            if (source.size() >= 3) {
                for (std::size_t i = 1; i + 1 < source.size(); ++i) {
                    const Impl::ImmediateModeVertex tri[3] = {
                        source[0], source[i], source[i + 1]
                    };
                    appendPolygon(tri, 3, source[i + 1]);
                }
            }
            break;
        case GL_QUADS:
            for (std::size_t i = 0; i + 3 < source.size(); i += 4) {
                appendPolygon(&source[i], 4, source[i + 3]);
            }
            break;
        case GL_QUAD_STRIP:
            if (source.size() >= 4) {
                for (std::size_t i = 0; i + 3 < source.size(); i += 2) {
                    const Impl::ImmediateModeVertex quad[4] = {
                        source[i + 0], source[i + 1],
                        source[i + 3], source[i + 2]
                    };
                    appendPolygon(quad, 4, source[i + 3]);
                }
            }
            break;
        case GL_POLYGON:
            if (source.size() >= 3) {
                appendPolygon(source.data(), source.size(), source[0]);
            }
            break;
        default:
            return false;
    }
    const bool needsCompatClientArrayState =
        impl_->state->isEnabled(GL_LIGHTING) ||
        impl_->state->isEnabled(GL_FOG) ||
        impl_->state->isEnabled(GL_TEXTURE_GEN_S) ||
        impl_->state->isEnabled(GL_TEXTURE_GEN_T);
    if (needsCompatClientArrayState) {
        auto applyCompatClientArrayState = [&](Impl::ImmediateModeVertex& v) {
            const auto applyTexGenCoord = [&](GLenum cap, std::size_t index) {
                if (!impl_->state->isEnabled(cap) || index >= 2) {
                    return;
                }
                const auto& coord = impl_->texGen[index];
                const float* plane = coord.mode == GL_OBJECT_LINEAR
                    ? coord.objectPlane
                    : coord.eyePlane;
                v.texcoord[index] =
                    plane[0] * v.position[0] +
                    plane[1] * v.position[1] +
                    plane[2] * v.position[2] +
                    plane[3] * v.position[3];
            };
            applyTexGenCoord(GL_TEXTURE_GEN_S, 0);
            applyTexGenCoord(GL_TEXTURE_GEN_T, 1);
            if (impl_->state->isEnabled(GL_LIGHTING)) {
                auto material = impl_->material.front;
                if (impl_->state->isEnabled(GL_COLOR_MATERIAL)) {
                    const GLenum mode = impl_->material.colorMaterialMode;
                    const auto writeVertexColor = [&](float* dst) {
                        dst[0] = v.color[0];
                        dst[1] = v.color[1];
                        dst[2] = v.color[2];
                        dst[3] = v.color[3];
                    };
                    switch (mode) {
                        case GL_AMBIENT:
                            writeVertexColor(material.ambient);
                            break;
                        case GL_DIFFUSE:
                            writeVertexColor(material.diffuse);
                            break;
                        case GL_SPECULAR:
                            writeVertexColor(material.specular);
                            break;
                        case GL_EMISSION:
                            writeVertexColor(material.emission);
                            break;
                        case GL_AMBIENT_AND_DIFFUSE:
                            writeVertexColor(material.ambient);
                            writeVertexColor(material.diffuse);
                            break;
                        default:
                            break;
                    }
                }
                float out[4] = {
                    material.emission[0],
                    material.emission[1],
                    material.emission[2],
                    material.diffuse[3],
                };
                for (int c = 0; c < 3; ++c) {
                    out[c] += material.ambient[c] *
                        impl_->lighting.modelAmbient[c];
                }
                for (std::size_t i = 0; i < impl_->lighting.lights.size(); ++i) {
                    if (!impl_->state->isEnabled(GL_LIGHT0 + static_cast<GLenum>(i))) {
                        continue;
                    }
                    const auto& light = impl_->lighting.lights[i];
                    for (int c = 0; c < 3; ++c) {
                        out[c] += material.ambient[c] * light.ambient[c];
                        out[c] += material.diffuse[c] * light.diffuse[c];
                        out[c] += material.specular[c] * light.specular[c];
                    }
                }
                out[3] = material.diffuse[3];
                for (int c = 0; c < 4; ++c) {
                    v.color[c] = std::clamp(out[c], 0.0f, 1.0f);
                }
            }
            if (impl_->state->isEnabled(GL_FOG)) {
                const float z = std::fabs(v.position[2]);
                float factor = 1.0f;
                switch (impl_->fog.mode) {
                    case GL_LINEAR:
                        if (impl_->fog.end != impl_->fog.start) {
                            factor = (impl_->fog.end - z) /
                                (impl_->fog.end - impl_->fog.start);
                        }
                        break;
                    case GL_EXP:
                        factor = std::exp(-(impl_->fog.density * z));
                        break;
                    case GL_EXP2: {
                        const float d = impl_->fog.density * z;
                        factor = std::exp(-(d * d));
                        break;
                    }
                    default:
                        break;
                }
                factor = std::clamp(factor, 0.0f, 1.0f);
                for (int c = 0; c < 3; ++c) {
                    v.color[c] = factor * v.color[c] +
                        (1.0f - factor) * impl_->fog.color[c];
                }
            }
        };
        for (auto& v : fillVertices) {
            applyCompatClientArrayState(v);
        }
        for (auto& v : lineVertices) {
            applyCompatClientArrayState(v);
        }
        for (auto& v : pointVertices) {
            applyCompatClientArrayState(v);
        }
    }
    if (fillVertices.empty() && lineVertices.empty() && pointVertices.empty()) {
        return true;
    }
    impl_->ensureDefaultDrawableForViewportExtent();
    impl_->encodePendingWork();

    auto encodeBatch = [&](GLenum batchMode,
                           const std::vector<Impl::ImmediateModeVertex>& vertices) {
        if (vertices.empty()) {
            return true;
        }
        std::vector<Impl::ImmediateModeVertex> screenExpanded;
        const Impl::ImmediateModeVertex* batchVerts = vertices.data();
        std::size_t batchCount = vertices.size();
        GLenum encodeMode = batchMode;
        Matrix4 encodeMvp = impl_->matrixState.modelViewProjection();
        if (batchMode == GL_POINTS || batchMode == GL_LINES) {
            const auto& vp = impl_->state->viewport();
            const float viewportWidth = static_cast<float>(std::max<GLsizei>(1, vp.width));
            const float viewportHeight = static_cast<float>(std::max<GLsizei>(1, vp.height));
            const float pointSize = std::max(1.0f, raster.pointSize);
            const float lineWidth = std::max(1.0f, raster.lineWidth);
            struct ClipVertex {
                Impl::ImmediateModeVertex v;
                float x = 0.0f;
                float y = 0.0f;
                float z = 0.0f;
                bool ok = false;
            };
            auto toClip = [&](const Impl::ImmediateModeVertex& src) {
                ClipVertex out;
                out.v = src;
                float clip[4] = {};
                for (int row = 0; row < 4; ++row) {
                    clip[row] =
                        encodeMvp.m[0 * 4 + row] * src.position[0] +
                        encodeMvp.m[1 * 4 + row] * src.position[1] +
                        encodeMvp.m[2 * 4 + row] * src.position[2] +
                        encodeMvp.m[3 * 4 + row] * src.position[3];
                }
                if (clip[3] == 0.0f || !std::isfinite(clip[0]) ||
                    !std::isfinite(clip[1]) || !std::isfinite(clip[2]) ||
                    !std::isfinite(clip[3])) {
                    return out;
                }
                const float invW = 1.0f / clip[3];
                out.x = clip[0] * invW;
                out.y = clip[1] * invW;
                out.z = clip[2] * invW;
                out.ok = true;
                return out;
            };
            auto makeClipVertex = [](const ClipVertex& src, float x, float y) {
                Impl::ImmediateModeVertex out = src.v;
                out.position[0] = x;
                out.position[1] = y;
                out.position[2] = src.z;
                out.position[3] = 1.0f;
                return out;
            };
            auto appendPointQuad = [&](const Impl::ImmediateModeVertex& src) {
                const ClipVertex c = toClip(src);
                if (!c.ok) {
                    return;
                }
                const float hx = pointSize / viewportWidth;
                const float hy = pointSize / viewportHeight;
                const auto a = makeClipVertex(c, c.x - hx, c.y - hy);
                const auto b = makeClipVertex(c, c.x + hx, c.y - hy);
                const auto d = makeClipVertex(c, c.x - hx, c.y + hy);
                const auto e = makeClipVertex(c, c.x + hx, c.y + hy);
                screenExpanded.push_back(a);
                screenExpanded.push_back(b);
                screenExpanded.push_back(e);
                screenExpanded.push_back(a);
                screenExpanded.push_back(e);
                screenExpanded.push_back(d);
            };
            auto appendLineQuad = [&](const Impl::ImmediateModeVertex& a,
                                      const Impl::ImmediateModeVertex& b) {
                const ClipVertex ca = toClip(a);
                const ClipVertex cb = toClip(b);
                if (!ca.ok || !cb.ok) {
                    return;
                }
                const float dxPixels = (cb.x - ca.x) * 0.5f * viewportWidth;
                const float dyPixels = (cb.y - ca.y) * 0.5f * viewportHeight;
                const float len = std::sqrt(dxPixels * dxPixels + dyPixels * dyPixels);
                if (!(len > 0.0f) || !std::isfinite(len)) {
                    appendPointQuad(a);
                    return;
                }
                const float halfWidth = lineWidth * 0.5f;
                const float nx = (-dyPixels / len) * halfWidth * 2.0f / viewportWidth;
                const float ny = ( dxPixels / len) * halfWidth * 2.0f / viewportHeight;
                const auto a0 = makeClipVertex(ca, ca.x + nx, ca.y + ny);
                const auto b0 = makeClipVertex(cb, cb.x + nx, cb.y + ny);
                const auto b1 = makeClipVertex(cb, cb.x - nx, cb.y - ny);
                const auto a1 = makeClipVertex(ca, ca.x - nx, ca.y - ny);
                screenExpanded.push_back(a0);
                screenExpanded.push_back(b0);
                screenExpanded.push_back(b1);
                screenExpanded.push_back(a0);
                screenExpanded.push_back(b1);
                screenExpanded.push_back(a1);
            };
            if (batchMode == GL_POINTS) {
                screenExpanded.reserve(vertices.size() * 6);
                for (const auto& src : vertices) {
                    appendPointQuad(src);
                }
            } else {
                screenExpanded.reserve((vertices.size() / 2) * 6);
                for (std::size_t i = 0; i + 1 < vertices.size(); i += 2) {
                    appendLineQuad(vertices[i], vertices[i + 1]);
                }
            }
            batchVerts = screenExpanded.data();
            batchCount = screenExpanded.size();
            encodeMode = GL_TRIANGLES;
            encodeMvp = Matrix4::identity();
        }
        if (batchCount == 0) {
            return true;
        }
        ImmediateDrawInfo info;
        info.mode = encodeMode;
        info.vertices = batchVerts;
        info.vertexCount = batchCount;
        info.vertexStride = sizeof(Impl::ImmediateModeVertex);
        info.mvp = encodeMvp;
        info.metalTexture = resolveFixedFunctionTexture();
        info.metalSamplerState = fixedFunctionSamplerState;
        info.textureTarget = fixedFunctionTextureTarget;
        if (fixedFunctionTextureParamsValid) {
            info.textureWrapS = fixedFunctionTextureParams.wrapS;
            info.textureWrapT = fixedFunctionTextureParams.wrapT;
            info.textureMinFilter = fixedFunctionTextureParams.minFilter;
            info.textureMagFilter = fixedFunctionTextureParams.magFilter;
            info.textureBorderColor = appglImmediateResolvedBorderColor(
                fixedFunctionTextureInternalFormat,
                fixedFunctionTextureParams);
        }
        if (appglCompatProfileEnabled()) {
            const std::uint32_t textureBaseClass =
                appglImmediateTextureBaseClass(fixedFunctionTextureInternalFormat);
            if (textureBaseClass != 0u) {
                info.textureEnvMode = impl_->texEnv.mode;
                info.textureBaseClass = textureBaseClass;
            }
        }
        info.fragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;
        GLsizei fboW = 0;
        GLsizei fboH = 0;
        void* fboDSTex = nullptr;
        void* fboColTex = impl_->resolveFBOColorTarget(fboW, fboH, fboDSTex);
        info.fboColorTexture = fboColTex;
        info.fboDepthStencilTexture = fboDSTex;
        info.fboWidth = fboW;
        info.fboHeight = fboH;
        const auto& vp = impl_->state->viewport();
        info.viewportX = vp.x;
        info.viewportY = vp.y;
        info.viewportWidth = vp.width;
        info.viewportHeight = vp.height;
        const auto& dr = impl_->state->depthRange();
        info.depthRangeNear = dr.nearValue;
        info.depthRangeFar = dr.farValue;
        info.depthTestEnabled = impl_->state->isEnabled(GL_DEPTH_TEST);
        info.depthFunc = impl_->state->depthState().func;
        info.depthWriteMask = (impl_->state->depthState().writeMask != GL_FALSE);
        {
            const auto& stencil = impl_->state->stencilState();
            info.stencilTestEnabled = impl_->state->isEnabled(GL_STENCIL_TEST);
            info.stencilFrontFunc = stencil.front.func;
            info.stencilFrontRef = stencil.front.ref;
            info.stencilFrontValueMask = stencil.front.valueMask;
            info.stencilFrontFail = stencil.front.fail;
            info.stencilFrontDepthFail = stencil.front.depthFail;
            info.stencilFrontDepthPass = stencil.front.depthPass;
            info.stencilFrontWriteMask = stencil.front.writeMask;
            info.stencilBackFunc = stencil.back.func;
            info.stencilBackRef = stencil.back.ref;
            info.stencilBackValueMask = stencil.back.valueMask;
            info.stencilBackFail = stencil.back.fail;
            info.stencilBackDepthFail = stencil.back.depthFail;
            info.stencilBackDepthPass = stencil.back.depthPass;
            info.stencilBackWriteMask = stencil.back.writeMask;
        }
        info.polygonOffsetEnabled =
            (batchMode == GL_TRIANGLES &&
             impl_->state->isEnabled(GL_POLYGON_OFFSET_FILL)) ||
            (batchMode == GL_LINES &&
             impl_->state->isEnabled(GL_POLYGON_OFFSET_LINE)) ||
            (batchMode == GL_POINTS &&
             impl_->state->isEnabled(GL_POLYGON_OFFSET_POINT));
        info.polygonOffsetFactor = raster.polygonOffsetFactor;
        info.polygonOffsetUnits = raster.polygonOffsetUnits;
        info.polygonOffsetClamp = raster.polygonOffsetClamp;
        const auto& glBlend = impl_->state->blendState();
        info.blend.enabled = impl_->state->isEnabled(GL_BLEND);
        info.blend.srcRGB = glBlend.srcRGB;
        info.blend.dstRGB = glBlend.dstRGB;
        info.blend.srcAlpha = glBlend.srcAlpha;
        info.blend.dstAlpha = glBlend.dstAlpha;
        info.blend.equationRGB = glBlend.equationRGB;
        info.blend.equationAlpha = glBlend.equationAlpha;
        info.blend.colorMaskR = (glBlend.colorMask[0] != GL_FALSE);
        info.blend.colorMaskG = (glBlend.colorMask[1] != GL_FALSE);
        info.blend.colorMaskB = (glBlend.colorMask[2] != GL_FALSE);
        info.blend.colorMaskA = (glBlend.colorMask[3] != GL_FALSE);
        info.scissorTestEnabled = impl_->state->isEnabled(GL_SCISSOR_TEST);
        const auto& sc = impl_->state->scissor();
        info.scissorX = sc.x;
        info.scissorY = sc.y;
        info.scissorWidth = sc.width;
        info.scissorHeight = sc.height;
        return impl_->frameGraph->encodeImmediateModeDraw(info);
    };

    auto paintSimpleRectToShadow = [&]() -> bool {
	        if ((mode != GL_TRIANGLE_STRIP && mode != GL_TRIANGLE_FAN) ||
	            source.size() != 4 ||
	            colorArrayUsable ||
	            fillVertices.empty() ||
	            !lineVertices.empty() ||
	            !pointVertices.empty() ||
	            impl_->state->isEnabled(GL_BLEND) ||
	            resolveFixedFunctionTexture() != nullptr) {
	            return false;
	        }
        const auto& blend = impl_->state->blendState();
	        if (blend.colorMask[0] == GL_FALSE ||
	            blend.colorMask[1] == GL_FALSE ||
	            blend.colorMask[2] == GL_FALSE ||
	            blend.colorMask[3] == GL_FALSE) {
	            return false;
	        }
	        const bool stencilTestEnabled =
	            impl_->state->isEnabled(GL_STENCIL_TEST);
	        const bool depthTestEnabled =
	            impl_->state->isEnabled(GL_DEPTH_TEST);
	        if (depthTestEnabled) {
	            if (impl_->state->boundDrawFramebuffer() != 0) {
	                return false;
	            }
	            impl_->ensureDefaultFramebufferDepthStencilShadow();
	            if (!impl_->defaultFramebufferDepthShadowValid) {
	                return false;
	            }
	        }
	        if (stencilTestEnabled) {
	            if (impl_->state->boundDrawFramebuffer() != 0) {
	                return false;
	            }
	            impl_->ensureDefaultFramebufferDepthStencilShadow();
	            if (!impl_->defaultFramebufferStencilShadowValid) {
	                return false;
	            }
	        }

	        const Matrix4 mvp = impl_->matrixState.modelViewProjection();
	        const auto& vp = impl_->state->viewport();
	        const auto& dr = impl_->state->depthRange();
        if (vp.width <= 0 || vp.height <= 0) {
            return false;
        }

	        struct WindowVertex {
	            float x = 0.0f;
	            float y = 0.0f;
	            float z = 0.0f;
	            bool ok = false;
	        };
        auto toWindow = [&](const Impl::ImmediateModeVertex& src) {
            WindowVertex out;
            float clip[4] = {};
            for (int row = 0; row < 4; ++row) {
                clip[row] =
                    mvp.m[0 * 4 + row] * src.position[0] +
                    mvp.m[1 * 4 + row] * src.position[1] +
                    mvp.m[2 * 4 + row] * src.position[2] +
                    mvp.m[3 * 4 + row] * src.position[3];
            }
	            if (clip[3] == 0.0f ||
	                !std::isfinite(clip[0]) ||
	                !std::isfinite(clip[1]) ||
	                !std::isfinite(clip[2]) ||
	                !std::isfinite(clip[3])) {
	                return out;
	            }
	            const float invW = 1.0f / clip[3];
	            const float ndcX = clip[0] * invW;
	            const float ndcY = clip[1] * invW;
	            const float ndcZ = clip[2] * invW;
	            out.x = static_cast<float>(vp.x) +
	                (ndcX + 1.0f) * 0.5f * static_cast<float>(vp.width);
	            out.y = static_cast<float>(vp.y) +
	                (ndcY + 1.0f) * 0.5f * static_cast<float>(vp.height);
	            out.z = static_cast<float>(
	                static_cast<double>(dr.nearValue) +
	                (static_cast<double>(ndcZ) + 1.0) * 0.5 *
	                    static_cast<double>(dr.farValue - dr.nearValue));
	            out.ok = true;
	            return out;
	        };

        WindowVertex wv[4];
        float minX = std::numeric_limits<float>::infinity();
        float minY = std::numeric_limits<float>::infinity();
        float maxX = -std::numeric_limits<float>::infinity();
        float maxY = -std::numeric_limits<float>::infinity();
        for (std::size_t i = 0; i < source.size(); ++i) {
            wv[i] = toWindow(source[i]);
            if (!wv[i].ok) {
                return false;
            }
            minX = std::min(minX, wv[i].x);
            minY = std::min(minY, wv[i].y);
            maxX = std::max(maxX, wv[i].x);
            maxY = std::max(maxY, wv[i].y);
        }

        GLint x0 = std::max<GLint>(
            vp.x,
            static_cast<GLint>(std::ceil(minX - 0.5f)));
        GLint y0 = std::max<GLint>(
            vp.y,
            static_cast<GLint>(std::ceil(minY - 0.5f)));
        GLint x1 = std::min<GLint>(
            vp.x + vp.width,
            static_cast<GLint>(std::ceil(maxX - 0.5f)));
        GLint y1 = std::min<GLint>(
            vp.y + vp.height,
            static_cast<GLint>(std::ceil(maxY - 0.5f)));
        if (impl_->state->isEnabled(GL_SCISSOR_TEST)) {
            const auto& sc = impl_->state->scissor();
            x0 = std::max<GLint>(x0, sc.x);
            y0 = std::max<GLint>(y0, sc.y);
            x1 = std::min<GLint>(x1, sc.x + sc.width);
            y1 = std::min<GLint>(y1, sc.y + sc.height);
        }
        if (x0 >= x1 || y0 >= y1) {
            return false;
        }
        const Impl::ImmediateModeVertex& colorVertex =
            !fillVertices.empty() ? fillVertices[0] : source[0];
        const std::uint8_t rgba[4] = {
            normalizedByte(colorVertex.color[0]),
            normalizedByte(colorVertex.color[1]),
            normalizedByte(colorVertex.color[2]),
            normalizedByte(colorVertex.color[3]),
        };
	        float depthA = 0.0f;
	        float depthB = 0.0f;
	        float depthC = wv[0].z;
	        bool hasDepthPlane = false;
	        for (int a = 0; a < 4 && !hasDepthPlane; ++a) {
	            for (int b = a + 1; b < 4 && !hasDepthPlane; ++b) {
	                for (int c = b + 1; c < 4 && !hasDepthPlane; ++c) {
	                    const float denom =
	                        wv[a].x * (wv[b].y - wv[c].y) +
	                        wv[b].x * (wv[c].y - wv[a].y) +
	                        wv[c].x * (wv[a].y - wv[b].y);
	                    if (std::fabs(denom) <= 1.0e-6f) {
	                        continue;
	                    }
	                    depthA = (wv[a].z * (wv[b].y - wv[c].y) +
	                              wv[b].z * (wv[c].y - wv[a].y) +
	                              wv[c].z * (wv[a].y - wv[b].y)) / denom;
	                    depthB = (wv[a].x * (wv[b].z - wv[c].z) +
	                              wv[b].x * (wv[c].z - wv[a].z) +
	                              wv[c].x * (wv[a].z - wv[b].z)) / denom;
	                    depthC = (wv[a].x * (wv[b].y * wv[c].z - wv[c].y * wv[b].z) +
	                              wv[b].x * (wv[c].y * wv[a].z - wv[a].y * wv[c].z) +
	                              wv[c].x * (wv[a].y * wv[b].z - wv[b].y * wv[a].z)) / denom;
	                    hasDepthPlane = true;
	                }
	            }
	        }
	        auto incomingDepthAt = [&](GLint gx, GLint gy) {
	            const float px = static_cast<float>(gx) + 0.5f;
	            const float py = static_cast<float>(gy) + 0.5f;
	            const float z = hasDepthPlane
	                ? depthA * px + depthB * py + depthC
	                : depthC;
	            return std::clamp(z, 0.0f, 1.0f);
	        };
	        auto depthPasses = [&](GLfloat incoming, GLfloat current) {
	            if (!depthTestEnabled) {
	                return true;
	            }
	            switch (impl_->state->depthState().func) {
	                case GL_NEVER:    return false;
	                case GL_LESS:     return incoming < current;
	                case GL_LEQUAL:   return incoming <= current;
	                case GL_GREATER:  return incoming > current;
	                case GL_GEQUAL:   return incoming >= current;
	                case GL_EQUAL:    return incoming == current;
	                case GL_NOTEQUAL: return incoming != current;
	                case GL_ALWAYS:
	                default:          return true;
	            }
	        };
		        auto stencilPasses = [&](GLint gx, GLint gy) {
		            if (!stencilTestEnabled) {
		                return true;
		            }
	            if (gx < 0 || gy < 0 ||
	                gx >= impl_->defaultFramebufferDepthStencilShadowWidth ||
	                gy >= impl_->defaultFramebufferDepthStencilShadowHeight) {
	                return false;
	            }
	            const auto& face = impl_->state->stencilState().front;
	            const GLuint mask = face.valueMask & 0xffu;
	            const GLuint ref = static_cast<GLuint>(face.ref) & 0xffu;
	            const std::size_t stencilOffset =
	                static_cast<std::size_t>(gy) *
	                static_cast<std::size_t>(impl_->defaultFramebufferDepthStencilShadowWidth) +
	                static_cast<std::size_t>(gx);
	            const GLuint value =
	                static_cast<GLuint>(impl_->defaultFramebufferStencil8[stencilOffset]) & 0xffu;
	            const GLuint maskedRef = ref & mask;
	            const GLuint maskedValue = value & mask;
	            switch (face.func) {
	                case GL_NEVER:    return false;
	                case GL_LESS:     return maskedRef < maskedValue;
	                case GL_LEQUAL:   return maskedRef <= maskedValue;
	                case GL_GREATER:  return maskedRef > maskedValue;
	                case GL_GEQUAL:   return maskedRef >= maskedValue;
	                case GL_EQUAL:    return maskedRef == maskedValue;
	                case GL_NOTEQUAL: return maskedRef != maskedValue;
	                case GL_ALWAYS:
		                default:          return true;
		            }
		        };
		        auto applyStencilOp = [&](std::uint8_t current, GLenum op) {
		            const auto& face = impl_->state->stencilState().front;
		            const std::uint8_t ref =
		                static_cast<std::uint8_t>(face.ref & 0xff);
		            switch (op) {
		                case GL_KEEP:
		                    return current;
		                case GL_ZERO:
		                    return static_cast<std::uint8_t>(0);
		                case GL_REPLACE:
		                    return ref;
		                case GL_INCR:
		                    return current == 0xffu
		                        ? current
		                        : static_cast<std::uint8_t>(current + 1u);
		                case GL_DECR:
		                    return current == 0u
		                        ? current
		                        : static_cast<std::uint8_t>(current - 1u);
		                case GL_INCR_WRAP:
		                    return static_cast<std::uint8_t>(current + 1u);
		                case GL_DECR_WRAP:
		                    return static_cast<std::uint8_t>(current - 1u);
		                case GL_INVERT:
		                    return static_cast<std::uint8_t>(~current);
		                default:
		                    return current;
		            }
		        };

	        if (impl_->state->boundDrawFramebuffer() == 0) {
            if (!impl_->defaultFramebufferShadowValid ||
                impl_->defaultFramebufferRGBA8.empty()) {
                impl_->ensureDefaultFramebufferShadow();
            } else {
                impl_->materializeDefaultFbShadowClear();
            }
            const GLint px0 = std::max<GLint>(0, x0);
            const GLint py0 = std::max<GLint>(0, y0);
            const GLint px1 = std::min<GLint>(
                impl_->defaultFramebufferShadowWidth, x1);
            const GLint py1 = std::min<GLint>(
                impl_->defaultFramebufferShadowHeight, y1);
            if (px0 >= px1 || py0 >= py1) {
                return false;
	            }
		            for (GLint gy = py0; gy < py1; ++gy) {
		                for (GLint gx = px0; gx < px1; ++gx) {
		                    const bool needsDepthStencil =
		                        depthTestEnabled || stencilTestEnabled;
		                    if (needsDepthStencil &&
		                        (gx >= impl_->defaultFramebufferDepthStencilShadowWidth ||
		                         gy >= impl_->defaultFramebufferDepthStencilShadowHeight)) {
		                        continue;
		                    }
		                    const std::size_t dsOffset =
		                        needsDepthStencil
		                            ? static_cast<std::size_t>(gy) *
		                                  static_cast<std::size_t>(
		                                      impl_->defaultFramebufferDepthStencilShadowWidth) +
		                                  static_cast<std::size_t>(gx)
		                            : 0u;
		                    bool stencilPassed = true;
		                    if (stencilTestEnabled) {
		                        stencilPassed = stencilPasses(gx, gy);
		                        if (!stencilPassed) {
		                            const auto& face =
		                                impl_->state->stencilState().front;
		                            const std::uint8_t writeMask =
		                                static_cast<std::uint8_t>(
		                                    face.writeMask & 0xffu);
		                            const std::uint8_t updated =
		                                applyStencilOp(
		                                    impl_->defaultFramebufferStencil8[dsOffset],
		                                    face.fail);
		                            impl_->defaultFramebufferStencil8[dsOffset] =
		                                static_cast<std::uint8_t>(
		                                    (impl_->defaultFramebufferStencil8[dsOffset] &
		                                     ~writeMask) |
		                                    (updated & writeMask));
		                            continue;
		                        }
		                    }
		                    bool depthPassed = true;
		                    const GLfloat incomingDepth = incomingDepthAt(gx, gy);
		                    if (depthTestEnabled) {
		                        depthPassed = depthPasses(
		                            incomingDepth,
		                            impl_->defaultFramebufferDepth32[dsOffset]);
		                    }
		                    if (stencilTestEnabled) {
		                        const auto& face =
		                            impl_->state->stencilState().front;
		                        const std::uint8_t writeMask =
		                            static_cast<std::uint8_t>(
		                                face.writeMask & 0xffu);
		                        const std::uint8_t updated =
		                            applyStencilOp(
		                                impl_->defaultFramebufferStencil8[dsOffset],
		                                depthPassed ? face.depthPass
		                                            : face.depthFail);
		                        impl_->defaultFramebufferStencil8[dsOffset] =
		                            static_cast<std::uint8_t>(
		                                (impl_->defaultFramebufferStencil8[dsOffset] &
		                                 ~writeMask) |
		                                (updated & writeMask));
		                    }
		                    if (!depthPassed) {
		                        continue;
		                    }
		                    if (depthTestEnabled &&
		                        impl_->state->depthState().writeMask != GL_FALSE) {
		                        impl_->defaultFramebufferDepth32[dsOffset] =
		                            incomingDepth;
		                    }
		                    const std::size_t offset =
		                        (static_cast<std::size_t>(gy) *
		                         static_cast<std::size_t>(impl_->defaultFramebufferShadowWidth) +
                         static_cast<std::size_t>(gx)) * 4u;
                    std::memcpy(impl_->defaultFramebufferRGBA8.data() + offset,
                                rgba,
                                4u);
                }
	            }
	            impl_->defaultFramebufferShadowValid = true;
	            if (depthTestEnabled) {
	                impl_->defaultFramebufferDepthShadowValid = true;
	            }
	            if (stencilTestEnabled) {
	                impl_->defaultFramebufferStencilShadowValid = true;
	            }
	            return true;
	        }

        GLFramebufferObject* fbo =
            impl_->objects->framebuffers().get(impl_->state->boundDrawFramebuffer());
        if (fbo == nullptr) {
            return false;
        }
        const bool lowerLeft = impl_->state->clipOrigin() != GL_UPPER_LEFT;
        bool painted = false;
        for (GLenum drawBuffer : fbo->drawBuffers) {
            if (drawBuffer == GL_NONE) {
                continue;
            }
            const GLFramebufferAttachment* attachment =
                impl_->framebufferAttachment(*fbo, drawBuffer);
            if (attachment == nullptr) {
                continue;
            }
            if (attachment->kind == GLFramebufferAttachment::Kind::Renderbuffer) {
                GLRenderbufferObject* rb =
                    impl_->objects->renderbuffers().get(attachment->object);
                if (rb == nullptr || !rb->storageDefined ||
                    rb->width <= 0 || rb->height <= 0) {
                    continue;
                }
                const GLint px0 = std::max<GLint>(0, x0);
                const GLint py0 = std::max<GLint>(0, y0);
                const GLint px1 = std::min<GLint>(rb->width, x1);
                const GLint py1 = std::min<GLint>(rb->height, y1);
                if (px0 >= px1 || py0 >= py1) {
                    continue;
                }
                const std::size_t bytes =
                    static_cast<std::size_t>(rb->width) *
                    static_cast<std::size_t>(rb->height) * 4u;
                if (rb->rgba8.size() < bytes) {
                    rb->rgba8.assign(bytes, 0);
                }
                for (GLint gy = py0; gy < py1; ++gy) {
                    const GLint sy = lowerLeft ? (rb->height - 1 - gy) : gy;
                    for (GLint gx = px0; gx < px1; ++gx) {
                        const std::size_t offset =
                            (static_cast<std::size_t>(sy) *
                             static_cast<std::size_t>(rb->width) +
                             static_cast<std::size_t>(gx)) * 4u;
                        std::memcpy(rb->rgba8.data() + offset, rgba, 4u);
                    }
                }
                rb->rgba8ShadowClearPending = false;
                rb->colorShadowAuthoritative = true;
                rb->framebufferReadbackYFlip = lowerLeft;
                painted = true;
            } else if (attachment->kind == GLFramebufferAttachment::Kind::Texture) {
                const auto resolved =
                    impl_->resolveTextureAttachmentStorage(*attachment);
                GLTextureObject* texture = resolved.storageTexture;
                if (!resolved.valid || texture == nullptr) {
                    continue;
                }
                auto level = texture->levels.find(resolved.level);
                if (level == texture->levels.end() || !level->second.defined) {
                    continue;
                }
                GLTextureImageLevel& image = level->second;
                const GLsizei tw = std::max<GLsizei>(image.desc.width, 1);
                const GLsizei th = texture->target == GL_TEXTURE_1D
                    ? 1
                    : std::max<GLsizei>(image.desc.height, 1);
                const GLint px0 = std::max<GLint>(0, x0);
                const GLint py0 = std::max<GLint>(0, y0);
                const GLint px1 = std::min<GLint>(tw, x1);
                const GLint py1 = std::min<GLint>(th, y1);
                if (px0 >= px1 || py0 >= py1) {
                    continue;
                }
                const GLint layer = std::max<GLint>(resolved.layer, 0);
                const GLsizei depth = std::max<GLsizei>(image.desc.depth, 1);
                if (layer >= depth) {
                    continue;
                }
                const std::size_t layerBytes =
                    static_cast<std::size_t>(tw) *
                    static_cast<std::size_t>(th) * 4u;
                const std::size_t bytes =
                    layerBytes * static_cast<std::size_t>(depth);
                if (image.rgba8.size() < bytes) {
                    image.rgba8.assign(bytes, 0);
                }
                for (GLint gy = py0; gy < py1; ++gy) {
                    const GLint sy = lowerLeft ? (th - 1 - gy) : gy;
                    for (GLint gx = px0; gx < px1; ++gx) {
                        const std::size_t offset =
                            static_cast<std::size_t>(layer) * layerBytes +
                            (static_cast<std::size_t>(sy) *
                             static_cast<std::size_t>(tw) +
                             static_cast<std::size_t>(gx)) * 4u;
                        std::memcpy(image.rgba8.data() + offset, rgba, 4u);
                    }
                }
                texture->colorShadowAuthoritative = true;
                if (lowerLeft) {
                    texture->wasFramebufferRenderedTo = true;
                }
                painted = true;
            }
        }
        return painted;
    };

    const bool ok = encodeBatch(GL_TRIANGLES, fillVertices) &&
                    encodeBatch(GL_LINES, lineVertices) &&
                    encodeBatch(GL_POINTS, pointVertices);
    bool shadowPainted = false;
    if (ok) {
        impl_->markBoundDrawFramebufferWrites();
        shadowPainted = paintSimpleRectToShadow();
    }
    if (ok && impl_->state->boundDrawFramebuffer() == 0 && !shadowPainted) {
        impl_->invalidateDefaultFramebufferShadow();
    }
    if (!ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_ERROR,
            0,
            GL_DEBUG_SEVERITY_HIGH,
            "legacy client-array fixed-function draw failed to encode"
        );
    }
    return ok;
}

#else
#error "GLContextImmediate.inc.mm included without an immediate-mode section selector"
#endif
