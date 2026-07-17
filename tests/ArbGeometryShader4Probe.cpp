#include <AppGL/AppGL.h>

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>

namespace {

constexpr int kWideVaryingCount = 32;

int blockerFailures = 0;
int spillFlags = 0;

void row(std::string_view name,
         std::string_view status,
         long long got = 1,
         long long expected = 1) {
    std::printf("ROW\t%.*s\t%.*s\tgot=%lld\texpected=%lld\n",
                static_cast<int>(name.size()), name.data(),
                static_cast<int>(status.size()), status.data(),
                got, expected);
}

void blocker(std::string_view name,
             bool pass,
             long long got = 1,
             long long expected = 1) {
    row(name, pass ? "PASS" : "FAIL", got, expected);
    if (!pass) {
        ++blockerFailures;
    }
}

void spillOutcome(bool pass, std::string_view stage) {
    const char* status = pass ? "PASS" : "SPILL-FLAG";
    std::printf("ROW\tarb_geometry_shader4-wide-varying-gs-fs-near128"
                "\t%s\tstage=%.*s\n",
                status, static_cast<int>(stage.size()), stage.data());
    if (!pass) {
        ++spillFlags;
    }
}

void drainErrors() {
    while (glGetError() != GL_NO_ERROR) {
    }
}

void expectError(std::string_view name, GLenum expected) {
    const GLenum got = glGetError();
    blocker(name, got == expected, got, expected);
    drainErrors();
}

std::string shaderLog(GLuint shader) {
    GLint length = 0;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
    std::string log(static_cast<std::size_t>(std::max(length, 1)), '\0');
    GLsizei written = 0;
    glGetShaderInfoLog(shader, length, &written, log.data());
    log.resize(static_cast<std::size_t>(std::max<GLsizei>(written, 0)));
    return log;
}

std::string programLog(GLuint program) {
    GLint length = 0;
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, &length);
    std::string log(static_cast<std::size_t>(std::max(length, 1)), '\0');
    GLsizei written = 0;
    glGetProgramInfoLog(program, length, &written, log.data());
    log.resize(static_cast<std::size_t>(std::max<GLsizei>(written, 0)));
    return log;
}

GLuint compileRaw(GLenum stage, const std::string& source, bool& passed) {
    const GLuint shader = glCreateShader(stage);
    const char* sourcePointer = source.c_str();
    glShaderSource(shader, 1, &sourcePointer, nullptr);
    glCompileShader(shader);
    GLint status = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    passed = status == GL_TRUE;
    return shader;
}

GLuint compileShader(GLenum stage,
                     const std::string& source,
                     std::string_view name,
                     bool expected = true) {
    bool passed = false;
    const GLuint shader = compileRaw(stage, source, passed);
    const bool matched = passed == expected;
    blocker(name, matched, passed ? GL_TRUE : GL_FALSE,
            expected ? GL_TRUE : GL_FALSE);
    if (!matched) {
        const std::string log = shaderLog(shader);
        std::fprintf(stderr, "COMPILE_LOG[%.*s]=%s\n",
                     static_cast<int>(name.size()), name.data(), log.c_str());
    }
    return shader;
}

GLuint linkRequested(GLuint vertexShader,
                     GLuint geometryShader,
                     GLuint fragmentShader,
                     GLenum inputType,
                     GLenum outputType,
                     GLint verticesOut,
                     std::string_view name,
                     bool expected = true) {
    const GLuint program = glCreateProgram();
    if (vertexShader != 0) glAttachShader(program, vertexShader);
    if (geometryShader != 0) glAttachShader(program, geometryShader);
    if (fragmentShader != 0) glAttachShader(program, fragmentShader);
    glProgramParameteriARB(program, GL_GEOMETRY_INPUT_TYPE_ARB,
                          static_cast<GLint>(inputType));
    glProgramParameteriARB(program, GL_GEOMETRY_OUTPUT_TYPE_ARB,
                          static_cast<GLint>(outputType));
    glProgramParameteriARB(program, GL_GEOMETRY_VERTICES_OUT_ARB, verticesOut);
    glLinkProgram(program);
    GLint status = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &status);
    const bool passed = status == GL_TRUE;
    const bool matched = passed == expected;
    blocker(name, matched, status, expected ? GL_TRUE : GL_FALSE);
    if (!matched) {
        const std::string log = programLog(program);
        std::fprintf(stderr, "LINK_LOG[%.*s]=%s\n",
                     static_cast<int>(name.size()), name.data(), log.c_str());
    }
    return program;
}

void expectProgramValue(GLuint program,
                        GLenum parameter,
                        GLint expected,
                        std::string_view name) {
    GLint value = -999;
    glGetProgramiv(program, parameter, &value);
    blocker(name, value == expected, value, expected);
}

struct RenderTarget {
    GLuint framebuffer = 0;
    GLuint texture = 0;
    GLsizei width = 16;
    GLsizei height = 16;
    bool complete = false;
};

RenderTarget makeRenderTarget(std::string_view prefix) {
    RenderTarget target;
    glGenTextures(1, &target.texture);
    glBindTexture(GL_TEXTURE_2D, target.texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, target.width, target.height,
                 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glGenFramebuffers(1, &target.framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, target.texture, 0);
    const GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    target.complete = status == GL_FRAMEBUFFER_COMPLETE;
    blocker(std::string(prefix) + ".framebuffer-complete",
            target.complete, status, GL_FRAMEBUFFER_COMPLETE);
    expectError(std::string(prefix) + ".setup-error", GL_NO_ERROR);
    return target;
}

void destroyRenderTarget(RenderTarget& target) {
    if (target.framebuffer != 0) glDeleteFramebuffers(1, &target.framebuffer);
    if (target.texture != 0) glDeleteTextures(1, &target.texture);
    target = {};
}

bool drawAndFindColor(const RenderTarget& target,
                      GLenum primitive,
                      GLsizei count,
                      GLuint program,
                      bool bindProgram,
                      const std::array<unsigned char, 4>& expected,
                      unsigned char tolerance,
                      GLenum& drawError,
                      std::array<unsigned char, 4>* observed = nullptr) {
    glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer);
    glViewport(0, 0, target.width, target.height);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    drainErrors();
    if (bindProgram) {
        glUseProgram(program);
    }
    glDrawArrays(primitive, 0, count);
    drawError = glGetError();
    std::vector<unsigned char> pixels(
        static_cast<std::size_t>(target.width * target.height * 4), 0);
    glReadPixels(0, 0, target.width, target.height,
                 GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    const GLenum readError = glGetError();
    if (drawError != GL_NO_ERROR || readError != GL_NO_ERROR) {
        return false;
    }
    int bestScore = -1;
    for (std::size_t offset = 0; offset + 3 < pixels.size(); offset += 4) {
        const int score = static_cast<int>(pixels[offset + 0]) +
            static_cast<int>(pixels[offset + 1]) +
            static_cast<int>(pixels[offset + 2]) +
            static_cast<int>(pixels[offset + 3]);
        if (observed != nullptr && score > bestScore) {
            bestScore = score;
            std::copy_n(pixels.data() + offset, 4, observed->begin());
        }
        bool matched = true;
        for (std::size_t channel = 0; channel < expected.size(); ++channel) {
            const int delta = std::abs(
                static_cast<int>(pixels[offset + channel]) -
                static_cast<int>(expected[channel]));
            matched = matched && delta <= tolerance;
        }
        if (matched) {
            return true;
        }
    }
    return false;
}

bool extensionAdvertised() {
    GLint count = 0;
    glGetIntegerv(GL_NUM_EXTENSIONS, &count);
    for (GLint index = 0; index < count; ++index) {
        const char* extension = reinterpret_cast<const char*>(
            glGetStringi(GL_EXTENSIONS, static_cast<GLuint>(index)));
        if (extension != nullptr &&
            std::strcmp(extension, "GL_ARB_geometry_shader4") == 0) {
            return true;
        }
    }
    return false;
}

void runFramebufferSurfaceChecks() {
    GLuint framebuffer = 0;
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    expectError("fbo.bind-error", GL_NO_ERROR);

    GLuint reservedTexture = 0;
    glGenTextures(1, &reservedTexture);
    glFramebufferTextureLayer(
        GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, reservedTexture, 0, 0);
    expectError("fbo.core-layer-reserved-name-error", GL_INVALID_OPERATION);
    glFramebufferTextureLayerARB(
        GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, reservedTexture, 0, 0);
    expectError("fbo.arb-layer-reserved-name-error", GL_INVALID_VALUE);
    glFramebufferTextureARB(
        GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, reservedTexture, 0);
    expectError("fbo.arb-whole-reserved-name-error", GL_INVALID_VALUE);
    glFramebufferTextureFaceARB(
        GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, reservedTexture, 0,
        GL_TEXTURE_CUBE_MAP_POSITIVE_X);
    expectError("fbo.arb-face-reserved-name-error", GL_INVALID_VALUE);
    glFramebufferTextureFaceARB(
        GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, 0, 0, GL_TEXTURE_2D);
    expectError("fbo.arb-face-invalid-enum-error", GL_INVALID_ENUM);

    GLuint cube = 0;
    glGenTextures(1, &cube);
    glBindTexture(GL_TEXTURE_CUBE_MAP, cube);
    constexpr std::array<GLenum, 6> faces = {
        GL_TEXTURE_CUBE_MAP_POSITIVE_X,
        GL_TEXTURE_CUBE_MAP_NEGATIVE_X,
        GL_TEXTURE_CUBE_MAP_POSITIVE_Y,
        GL_TEXTURE_CUBE_MAP_NEGATIVE_Y,
        GL_TEXTURE_CUBE_MAP_POSITIVE_Z,
        GL_TEXTURE_CUBE_MAP_NEGATIVE_Z,
    };
    for (GLenum face : faces) {
        glTexImage2D(face, 0, GL_RGBA8, 4, 4, 0,
                     GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    }
    expectError("fbo.cube-storage-error", GL_NO_ERROR);
    glFramebufferTextureFaceARB(
        GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, cube, -1, faces.front());
    expectError("fbo.arb-face-invalid-level-error", GL_INVALID_VALUE);
    for (std::size_t index = 0; index < faces.size(); ++index) {
        glFramebufferTextureFaceARB(
            GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, cube, 0, faces[index]);
        expectError("fbo.arb-face-" + std::to_string(index) + "-attach-error",
                    GL_NO_ERROR);
        GLint attachedFace = 0;
        glGetFramebufferAttachmentParameteriv(
            GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE, &attachedFace);
        blocker("fbo.arb-face-" + std::to_string(index) + "-route",
                attachedFace == static_cast<GLint>(faces[index]),
                attachedFace, faces[index]);
        expectError("fbo.arb-face-" + std::to_string(index) + "-query-error",
                    GL_NO_ERROR);
    }

    GLuint arrayTexture = 0;
    glGenTextures(1, &arrayTexture);
    glBindTexture(GL_TEXTURE_2D_ARRAY, arrayTexture);
    glTexStorage3D(GL_TEXTURE_2D_ARRAY, 1, GL_RGBA8, 4, 4, 4);
    glFramebufferTextureLayerARB(
        GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, arrayTexture, 0, 2);
    expectError("fbo.arb-layer-valid-error", GL_NO_ERROR);
    GLint attachedLayer = -1;
    glGetFramebufferAttachmentParameteriv(
        GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
        GL_FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER, &attachedLayer);
    blocker("fbo.arb-layer-route", attachedLayer == 2, attachedLayer, 2);
    expectError("fbo.arb-layer-query-error", GL_NO_ERROR);

    glDeleteTextures(1, &arrayTexture);
    glDeleteTextures(1, &cube);
    glDeleteTextures(1, &reservedTexture);
    glDeleteFramebuffers(1, &framebuffer);
}

void runBlockingSemantics() {
    blocker("advertisement.present", extensionAdvertised());
    expectError("advertisement.enumeration-error", GL_NO_ERROR);

    GLint value = -1;
    glGetIntegerv(GL_MAX_GEOMETRY_VARYING_COMPONENTS_ARB, &value);
    blocker("cap.max-geometry-varying-components-arb", value == 128,
            value, 128);
    expectError("cap.max-geometry-varying-components-arb-error", GL_NO_ERROR);
    glGetIntegerv(GL_MAX_VERTEX_VARYING_COMPONENTS_ARB, &value);
    blocker("cap.max-vertex-varying-components-arb", value == 128,
            value, 128);
    expectError("cap.max-vertex-varying-components-arb-error", GL_NO_ERROR);

    const GLuint requestProgram = glCreateProgram();
    expectProgramValue(requestProgram, GL_GEOMETRY_INPUT_TYPE_ARB,
                       GL_TRIANGLES, "request.default-input");
    expectProgramValue(requestProgram, GL_GEOMETRY_OUTPUT_TYPE_ARB,
                       GL_TRIANGLE_STRIP, "request.default-output");
    expectProgramValue(requestProgram, GL_GEOMETRY_VERTICES_OUT_ARB,
                       0, "request.default-vertices-out");
    expectError("request.default-query-error", GL_NO_ERROR);
    glProgramParameteriARB(requestProgram, GL_GEOMETRY_INPUT_TYPE_ARB,
                          GL_LINES_ADJACENCY_ARB);
    glProgramParameteriARB(requestProgram, GL_GEOMETRY_OUTPUT_TYPE_ARB,
                          GL_POINTS);
    glProgramParameteriARB(requestProgram, GL_GEOMETRY_VERTICES_OUT_ARB, 7);
    expectError("request.valid-set-error", GL_NO_ERROR);
    expectProgramValue(requestProgram, GL_GEOMETRY_INPUT_TYPE_ARB,
                       GL_LINES_ADJACENCY_ARB, "request.updated-input");
    expectProgramValue(requestProgram, GL_GEOMETRY_OUTPUT_TYPE_ARB,
                       GL_POINTS, "request.updated-output");
    expectProgramValue(requestProgram, GL_GEOMETRY_VERTICES_OUT_ARB,
                       7, "request.updated-vertices-out");
    glGetProgramiv(requestProgram, GL_GEOMETRY_INPUT_TYPE, &value);
    expectError("query.core-linked-view-still-requires-link",
                GL_INVALID_OPERATION);
    expectProgramValue(requestProgram, GL_GEOMETRY_INPUT_TYPE_ARB,
                       GL_LINES_ADJACENCY_ARB,
                       "query.arb-request-survives-core-query");
    expectError("query.arb-request-after-core-query-error", GL_NO_ERROR);

    glProgramParameteriARB(requestProgram, GL_GEOMETRY_INPUT_TYPE_ARB,
                          GL_LINE_STRIP);
    expectError("request.invalid-input-error", GL_INVALID_VALUE);
    expectProgramValue(requestProgram, GL_GEOMETRY_INPUT_TYPE_ARB,
                       GL_LINES_ADJACENCY_ARB,
                       "request.invalid-input-preserves-state");
    glProgramParameteriARB(requestProgram, GL_GEOMETRY_VERTICES_OUT_ARB, 257);
    expectError("request.vertices-out-over-cap-error", GL_INVALID_VALUE);
    expectProgramValue(requestProgram, GL_GEOMETRY_VERTICES_OUT_ARB,
                       7, "request.vertices-out-over-cap-preserves-state");
    glProgramParameteriARB(requestProgram, 0xDEAD, 1);
    expectError("request.invalid-pname-error", GL_INVALID_ENUM);
    glProgramParameteriARB(0x7FFFFFFFu,
                          GL_GEOMETRY_VERTICES_OUT_ARB, 1);
    expectError("request.invalid-program-error", GL_INVALID_VALUE);

    const std::string vertexSource = R"GLSL(#version 130
void main() {
    if (gl_VertexID == 0) gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
    else if (gl_VertexID == 1) gl_Position = vec4(-0.5, -0.5, 0.0, 1.0);
    else gl_Position = vec4(0.5, -0.5, 0.0, 1.0);
}
)GLSL";
    const std::string fragmentSource = R"GLSL(#version 130
void main() { gl_FragColor = vec4(1.0); }
)GLSL";
    const std::string geometrySource = R"GLSL(#version 130
#extension GL_ARB_geometry_shader4 : require
flat varying out int observed_vertices;
void main() {
    observed_vertices = gl_VerticesIn;
    gl_Position = gl_PositionIn[0];
    gl_PointSize = 4.0;
    EmitVertex();
    EndPrimitive();
}
)GLSL";
    const std::string commentOnlySource = R"GLSL(#version 130
// #extension GL_ARB_geometry_shader4 : require
void main() { gl_Position = vec4(0.0); EmitVertex(); }
)GLSL";
    const std::string disabledSource = R"GLSL(#version 130
#extension GL_ARB_geometry_shader4 : disable
void main() { gl_Position = vec4(0.0); EmitVertex(); }
)GLSL";
    const std::string enabledSource = R"GLSL(#version 130
#extension GL_ARB_geometry_shader4 : enable
void main() { gl_Position = gl_PositionIn[0]; EmitVertex(); EndPrimitive(); }
)GLSL";
    const std::string warnedSource = R"GLSL(#version 130
#extension GL_ARB_geometry_shader4 : warn
void main() { gl_Position = gl_PositionIn[0]; EmitVertex(); EndPrimitive(); }
)GLSL";

    const GLuint vertexShader = compileShader(
        GL_VERTEX_SHADER, vertexSource, "compile.vertex");
    const GLuint fragmentShader = compileShader(
        GL_FRAGMENT_SHADER, fragmentSource, "compile.fragment");
    const GLuint geometryShader = compileShader(
        GL_GEOMETRY_SHADER, geometrySource, "compile.directive-require");
    const GLuint commentOnlyShader = compileShader(
        GL_GEOMETRY_SHADER, commentOnlySource,
        "compile.comment-does-not-activate", false);
    const GLuint disabledShader = compileShader(
        GL_GEOMETRY_SHADER, disabledSource,
        "compile.directive-disable-does-not-activate", false);
    const GLuint enabledShader = compileShader(
        GL_GEOMETRY_SHADER, enabledSource, "compile.directive-enable");
    const GLuint warnedShader = compileShader(
        GL_GEOMETRY_SHADER, warnedSource, "compile.directive-warn");

    GLint sourceLength = 0;
    glGetShaderiv(geometryShader, GL_SHADER_SOURCE_LENGTH, &sourceLength);
    std::string originalSource(
        static_cast<std::size_t>(std::max(sourceLength, 1)), '\0');
    GLsizei written = 0;
    glGetShaderSource(geometryShader, sourceLength, &written,
                      originalSource.data());
    blocker("source.original-before-links",
            originalSource.find("GL_ARB_geometry_shader4 : require") !=
                std::string::npos);

    const GLuint triangleProgram = linkRequested(
        vertexShader, geometryShader, fragmentShader,
        GL_TRIANGLES, GL_POINTS, 1, "link.shared-triangles");
    expectProgramValue(triangleProgram, GL_GEOMETRY_INPUT_TYPE,
                       GL_TRIANGLES, "query.shared-triangles-input");
    expectProgramValue(triangleProgram, GL_GEOMETRY_OUTPUT_TYPE,
                       GL_POINTS, "query.shared-triangles-output");
    expectProgramValue(triangleProgram, GL_GEOMETRY_VERTICES_OUT,
                       1, "query.shared-triangles-count");

    const GLuint adjacencyProgram = linkRequested(
        vertexShader, geometryShader, fragmentShader,
        GL_LINES_ADJACENCY_ARB, GL_LINE_STRIP, 3,
        "link.shared-lines-adjacency");
    expectProgramValue(adjacencyProgram, GL_GEOMETRY_INPUT_TYPE,
                       GL_LINES_ADJACENCY_ARB,
                       "query.shared-lines-adjacency-input");
    expectProgramValue(adjacencyProgram, GL_GEOMETRY_OUTPUT_TYPE,
                       GL_LINE_STRIP,
                       "query.shared-lines-adjacency-output");
    expectProgramValue(adjacencyProgram, GL_GEOMETRY_VERTICES_OUT,
                       3, "query.shared-lines-adjacency-count");

    originalSource.assign(
        static_cast<std::size_t>(std::max(sourceLength, 1)), '\0');
    glGetShaderSource(geometryShader, sourceLength, &written,
                      originalSource.data());
    blocker("source.original-after-links",
            originalSource.find("GL_ARB_geometry_shader4 : require") !=
                std::string::npos);
    GLint shaderStatus = GL_FALSE;
    glGetShaderiv(geometryShader, GL_COMPILE_STATUS, &shaderStatus);
    blocker("source.shared-compile-status-stable",
            shaderStatus == GL_TRUE, shaderStatus, GL_TRUE);

    const std::string sourceLayoutGeometry = R"GLSL(#version 130
#extension GL_ARB_geometry_shader4 : enable
layout(lines) in;
layout(line_strip, max_vertices = 2) out;
void main() {
    gl_Position = gl_PositionIn[0]; EmitVertex();
    gl_Position = gl_PositionIn[1]; EmitVertex();
    EndPrimitive();
}
)GLSL";
    const GLuint layoutShader = compileShader(
        GL_GEOMETRY_SHADER, sourceLayoutGeometry, "compile.source-layout");
    const GLuint layoutProgram = linkRequested(
        vertexShader, layoutShader, fragmentShader,
        GL_POINTS, GL_POINTS, 1, "link.source-layout-wins");
    expectProgramValue(layoutProgram, GL_GEOMETRY_INPUT_TYPE_ARB,
                       GL_POINTS, "query.source-request-input-preserved");
    expectProgramValue(layoutProgram, GL_GEOMETRY_OUTPUT_TYPE_ARB,
                       GL_POINTS, "query.source-request-output-preserved");
    expectProgramValue(layoutProgram, GL_GEOMETRY_VERTICES_OUT_ARB,
                       1, "query.source-request-count-preserved");
    expectProgramValue(layoutProgram, GL_GEOMETRY_INPUT_TYPE,
                       GL_LINES, "query.source-input-wins");
    expectProgramValue(layoutProgram, GL_GEOMETRY_OUTPUT_TYPE,
                       GL_LINE_STRIP, "query.source-output-wins");
    expectProgramValue(layoutProgram, GL_GEOMETRY_VERTICES_OUT,
                       2, "query.source-count-wins");

    const std::string mismatchGeometry = R"GLSL(#version 130
#extension GL_ARB_geometry_shader4 : enable
varying in float mismatch[3];
void main() {
    gl_Position = gl_PositionIn[0] + vec4(mismatch[0]);
    EmitVertex();
}
)GLSL";
    const GLuint mismatchShader = compileShader(
        GL_GEOMETRY_SHADER, mismatchGeometry,
        "compile.explicit-input-provisional");
    const GLuint mismatchProgram = linkRequested(
        vertexShader, mismatchShader, fragmentShader,
        GL_LINES, GL_POINTS, 1, "link.explicit-input-mismatch", false);

    const std::string builtinVertex = R"GLSL(#version 130
void main() {
    gl_Position = gl_Vertex;
    gl_PointSize = 1.0;
    gl_ClipVertex = gl_Position;
    gl_FrontColor = vec4(1.0);
    gl_BackColor = vec4(1.0);
    gl_FrontSecondaryColor = vec4(0.0);
    gl_BackSecondaryColor = vec4(0.0);
    gl_TexCoord[0] = vec4(0.0);
    gl_FogFragCoord = 0.0;
}
)GLSL";
    const std::string builtinGeometry = R"GLSL(#version 130
#extension GL_ARB_geometry_shader4 : warn
void main() {
    float keep = gl_PointSizeIn[0] + gl_ClipVertexIn[0].x +
        gl_FrontColorIn[0].x + gl_BackColorIn[0].x +
        gl_FrontSecondaryColorIn[0].x + gl_BackSecondaryColorIn[0].x +
        gl_TexCoordIn[0][0].x + gl_FogFragCoordIn[0] +
        float(gl_PrimitiveIDIn + gl_VerticesIn);
    gl_Position = gl_PositionIn[0] + vec4(keep * 0.0);
    gl_PointSize = 1.0;
    gl_ClipVertex = gl_Position;
    gl_FrontColor = vec4(1.0);
    gl_BackColor = vec4(1.0);
    gl_FrontSecondaryColor = vec4(0.0);
    gl_BackSecondaryColor = vec4(0.0);
    gl_TexCoord[0] = vec4(0.0);
    gl_FogFragCoord = 0.0;
    EmitVertex(); EndPrimitive();
}
)GLSL";
    const GLuint builtinVertexShader = compileShader(
        GL_VERTEX_SHADER, builtinVertex, "compile.all-builtins-vertex");
    const GLuint builtinGeometryShader = compileShader(
        GL_GEOMETRY_SHADER, builtinGeometry, "compile.all-builtins-geometry");
    const GLuint builtinProgram = linkRequested(
        builtinVertexShader, builtinGeometryShader, fragmentShader,
        GL_TRIANGLES, GL_POINTS, 1, "link.all-builtins");

    GLuint vertexArray = 0;
    glGenVertexArrays(1, &vertexArray);
    glBindVertexArray(vertexArray);
    glEnable(GL_PROGRAM_POINT_SIZE);
    RenderTarget target = makeRenderTarget("relink");
    GLenum drawError = GL_NO_ERROR;
    const bool initialDraw = target.complete && drawAndFindColor(
        target, GL_TRIANGLES, 3, triangleProgram, true,
        {255, 255, 255, 255}, 2, drawError);
    blocker("relink.initial-executable-drawable", initialDraw,
            drawError, GL_NO_ERROR);

    glProgramParameteriARB(triangleProgram,
                          GL_GEOMETRY_VERTICES_OUT_ARB, 0);
    glLinkProgram(triangleProgram);
    expectProgramValue(triangleProgram, GL_LINK_STATUS, GL_FALSE,
                       "relink.failed-status");
    expectProgramValue(triangleProgram, GL_GEOMETRY_VERTICES_OUT_ARB, 0,
                       "relink.request-retained");
    expectProgramValue(triangleProgram, GL_GEOMETRY_INPUT_TYPE,
                       GL_TRIANGLES, "relink.prior-input-retained");
    expectProgramValue(triangleProgram, GL_GEOMETRY_OUTPUT_TYPE,
                       GL_POINTS, "relink.prior-output-retained");
    expectProgramValue(triangleProgram, GL_GEOMETRY_VERTICES_OUT,
                       1, "relink.prior-count-retained");
    const bool retainedDraw = target.complete && drawAndFindColor(
        target, GL_TRIANGLES, 3, triangleProgram, false,
        {255, 255, 255, 255}, 2, drawError);
    blocker("relink.prior-executable-drawable-after-failure",
            retainedDraw, drawError, GL_NO_ERROR);
    glUseProgram(0);
    destroyRenderTarget(target);
    glDeleteVertexArrays(1, &vertexArray);

    runFramebufferSurfaceChecks();

    glDeleteProgram(builtinProgram);
    glDeleteProgram(mismatchProgram);
    glDeleteProgram(layoutProgram);
    glDeleteProgram(adjacencyProgram);
    glDeleteProgram(triangleProgram);
    glDeleteProgram(requestProgram);
    glDeleteShader(builtinGeometryShader);
    glDeleteShader(builtinVertexShader);
    glDeleteShader(mismatchShader);
    glDeleteShader(layoutShader);
    glDeleteShader(warnedShader);
    glDeleteShader(enabledShader);
    glDeleteShader(disabledShader);
    glDeleteShader(commentOnlyShader);
    glDeleteShader(geometryShader);
    glDeleteShader(fragmentShader);
    glDeleteShader(vertexShader);
}

struct WideSources {
    std::string vertex;
    std::string geometry;
    std::string fragment;
};

WideSources makeWideSources(int varyingCount) {
    WideSources sources;
    sources.vertex = R"GLSL(#version 130
void main() {
    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
    gl_PointSize = 4.0;
}
)GLSL";
    sources.geometry =
        "#version 130\n"
        "#extension GL_ARB_geometry_shader4 : require\n"
        "uniform vec4 uWideSeed;\n";
    sources.fragment = "#version 130\n";
    for (int index = 0; index < varyingCount; ++index) {
        const std::string name = "f2Wide" + std::to_string(index);
        sources.geometry += "varying out vec4 " + name + ";\n";
        sources.fragment += "varying vec4 " + name + ";\n";
    }
    sources.geometry += "void main() {\n";
    for (int index = 0; index < varyingCount; ++index) {
        const std::string name = "f2Wide" + std::to_string(index);
        sources.geometry +=
            "    " + name + " = uWideSeed + vec4(float(gl_PrimitiveIDIn) * " +
            std::to_string(index + 1) + ".0e-5);\n";
    }
    sources.geometry +=
        "    gl_Position = gl_PositionIn[0];\n"
        "    gl_PointSize = 4.0;\n"
        "    EmitVertex();\n"
        "    EndPrimitive();\n"
        "}\n";
    sources.fragment += "void main() {\n    vec4 checksum = vec4(0.0);\n";
    for (int index = 0; index < varyingCount; ++index) {
        sources.fragment +=
            "    checksum += f2Wide" + std::to_string(index) + ";\n";
    }
    sources.fragment += "    gl_FragColor = checksum / " +
        std::to_string(varyingCount) + ".0;\n}\n";
    return sources;
}

struct VaryingPipelineResult {
    bool passed = false;
    std::string stage;
    std::array<unsigned char, 4> observed = {0, 0, 0, 0};
};

VaryingPipelineResult runVaryingPipeline(int varyingCount,
                                         std::string_view prefix,
                                         bool spillProbe) {
    const WideSources sources = makeWideSources(varyingCount);
    const auto stageRow = [&](std::string_view stage,
                              bool passed,
                              long long got = 1,
                              long long expected = 1) {
        const std::string name = std::string(prefix) + "." +
            std::string(stage);
        if (spillProbe) {
            row(name, passed ? "PASS" : "SPILL-FLAG", got, expected);
        } else {
            blocker(name, passed, got, expected);
        }
    };

    int geometryDeclarations = 0;
    int fragmentConsumers = 0;
    for (int index = 0; index < varyingCount; ++index) {
        const std::string name = "f2Wide" + std::to_string(index);
        geometryDeclarations +=
            sources.geometry.find("varying out vec4 " + name + ";") !=
            std::string::npos;
        fragmentConsumers +=
            sources.fragment.find("checksum += " + name + ";") !=
            std::string::npos;
    }
    blocker(std::string(prefix) + ".generator.geometry-vec4-count",
            geometryDeclarations == varyingCount,
            geometryDeclarations, varyingCount);
    blocker(std::string(prefix) + ".generator.fragment-consumer-count",
            fragmentConsumers == varyingCount,
            fragmentConsumers, varyingCount);
    if (geometryDeclarations != varyingCount ||
        fragmentConsumers != varyingCount) {
        return {false, "generator", {0, 0, 0, 0}};
    }

    bool vertexCompiled = false;
    bool geometryCompiled = false;
    bool fragmentCompiled = false;
    const GLuint vertexShader = compileRaw(
        GL_VERTEX_SHADER, sources.vertex, vertexCompiled);
    const GLuint geometryShader = compileRaw(
        GL_GEOMETRY_SHADER, sources.geometry, geometryCompiled);
    const GLuint fragmentShader = compileRaw(
        GL_FRAGMENT_SHADER, sources.fragment, fragmentCompiled);
    stageRow("compile.vertex", vertexCompiled,
             vertexCompiled ? 1 : 0, 1);
    stageRow("compile.geometry", geometryCompiled,
             geometryCompiled ? 1 : 0, 1);
    stageRow("compile.fragment", fragmentCompiled,
             fragmentCompiled ? 1 : 0, 1);
    if (!vertexCompiled || !geometryCompiled || !fragmentCompiled) {
        if (!vertexCompiled) {
            std::fprintf(stderr, "%.*s_COMPILE_LOG[vertex]=%s\n",
                         static_cast<int>(prefix.size()), prefix.data(),
                         shaderLog(vertexShader).c_str());
        }
        if (!geometryCompiled) {
            std::fprintf(stderr, "%.*s_COMPILE_LOG[geometry]=%s\n",
                         static_cast<int>(prefix.size()), prefix.data(),
                         shaderLog(geometryShader).c_str());
        }
        if (!fragmentCompiled) {
            std::fprintf(stderr, "%.*s_COMPILE_LOG[fragment]=%s\n",
                         static_cast<int>(prefix.size()), prefix.data(),
                         shaderLog(fragmentShader).c_str());
        }
        glDeleteShader(fragmentShader);
        glDeleteShader(geometryShader);
        glDeleteShader(vertexShader);
        return {false, "compile", {0, 0, 0, 0}};
    }

    const GLuint program = glCreateProgram();
    glAttachShader(program, vertexShader);
    glAttachShader(program, geometryShader);
    glAttachShader(program, fragmentShader);
    glProgramParameteriARB(program, GL_GEOMETRY_INPUT_TYPE_ARB, GL_POINTS);
    glProgramParameteriARB(program, GL_GEOMETRY_OUTPUT_TYPE_ARB, GL_POINTS);
    glProgramParameteriARB(program, GL_GEOMETRY_VERTICES_OUT_ARB, 1);
    glLinkProgram(program);
    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    stageRow("link", linked == GL_TRUE, linked, GL_TRUE);
    if (linked != GL_TRUE) {
        std::fprintf(stderr, "%.*s_LINK_LOG=%s\n",
                     static_cast<int>(prefix.size()), prefix.data(),
                     programLog(program).c_str());
        glDeleteProgram(program);
        glDeleteShader(fragmentShader);
        glDeleteShader(geometryShader);
        glDeleteShader(vertexShader);
        return {false, "link", {0, 0, 0, 0}};
    }

    glUseProgram(program);
    const GLint seedLocation = glGetUniformLocation(program, "uWideSeed");
    stageRow("uniform-reflection", seedLocation >= 0,
             seedLocation >= 0 ? 1 : 0, 1);
    if (seedLocation < 0) {
        glUseProgram(0);
        glDeleteProgram(program);
        glDeleteShader(fragmentShader);
        glDeleteShader(geometryShader);
        glDeleteShader(vertexShader);
        return {false, "uniform-reflection", {0, 0, 0, 0}};
    }
    glUniform4f(seedLocation, 0.25f, 0.5f, 0.75f, 1.0f);

    GLuint vertexArray = 0;
    glGenVertexArrays(1, &vertexArray);
    glBindVertexArray(vertexArray);
    glEnable(GL_PROGRAM_POINT_SIZE);
    RenderTarget target = makeRenderTarget(prefix);
    GLenum drawError = GL_NO_ERROR;
    std::array<unsigned char, 4> observed = {0, 0, 0, 0};
    const bool colorFound = target.complete && drawAndFindColor(
        target, GL_POINTS, 1, program, false,
        {64, 128, 191, 255}, 4, drawError, &observed);
    stageRow("draw-error", drawError == GL_NO_ERROR,
             drawError, GL_NO_ERROR);
    stageRow("readback-checksum", colorFound,
             colorFound ? 1 : 0, 1);
    std::string failureStage;
    if (!target.complete) {
        failureStage = "framebuffer";
    } else if (drawError != GL_NO_ERROR) {
        failureStage = "pipeline-draw";
    } else if (!colorFound) {
        failureStage = "readback";
        std::fprintf(stderr,
                     "%.*s_READBACK expected=64,128,191,255 observed=%u,%u,%u,%u\n",
                     static_cast<int>(prefix.size()), prefix.data(),
                     observed[0], observed[1], observed[2], observed[3]);
    }

    glUseProgram(0);
    destroyRenderTarget(target);
    glDeleteVertexArrays(1, &vertexArray);
    glDeleteProgram(program);
    glDeleteShader(fragmentShader);
    glDeleteShader(geometryShader);
    glDeleteShader(vertexShader);
    if (!failureStage.empty()) {
        return {false, failureStage, observed};
    }
    return {true, "compile-link-pipeline-draw-readback", observed};
}

void runWideVaryingProbe() {
    const VaryingPipelineResult control = runVaryingPipeline(
        31, "f2.control-124-components", false);
    blocker("f2.control-124-components.instrument-valid", control.passed);
    if (!control.passed) {
        return;
    }

    const VaryingPipelineResult wide = runVaryingPipeline(
        kWideVaryingCount, "f2", true);
    spillOutcome(wide.passed, wide.stage);
}

enum class Mode {
    All,
    BlockersOnly,
    F2Only,
};

Mode parseMode(int argc, char** argv) {
    if (argc < 2) return Mode::All;
    if (std::strcmp(argv[1], "--blockers-only") == 0) {
        return Mode::BlockersOnly;
    }
    if (std::strcmp(argv[1], "--f2-only") == 0) {
        return Mode::F2Only;
    }
    std::fprintf(stderr,
                 "usage: %s [--blockers-only|--f2-only]\n", argv[0]);
    std::exit(64);
}

}  // namespace

int main(int argc, char** argv) {
    const Mode mode = parseMode(argc, argv);
    const std::array<std::pair<const char*, AppGLProc>, 4> procedures = {{
        {"glProgramParameteriARB", appglGetProcAddress("glProgramParameteriARB")},
        {"glFramebufferTextureARB", appglGetProcAddress("glFramebufferTextureARB")},
        {"glFramebufferTextureLayerARB", appglGetProcAddress("glFramebufferTextureLayerARB")},
        {"glFramebufferTextureFaceARB", appglGetProcAddress("glFramebufferTextureFaceARB")},
    }};
    for (const auto& [name, procedure] : procedures) {
        blocker(std::string("proc.") + name, procedure != nullptr);
    }

    AppGLContext* context = appglCreateOffscreenContext(32, 32);
    blocker("context.offscreen", context != nullptr);
    if (context != nullptr) {
        appglMakeCurrent(context);
        drainErrors();
        if (mode != Mode::F2Only) {
            runBlockingSemantics();
        }
        if (mode != Mode::BlockersOnly) {
            runWideVaryingProbe();
        }
        appglMakeCurrent(nullptr);
        appglDestroyContext(context);
    }

    const char* status = blockerFailures != 0
        ? "FAIL"
        : (spillFlags != 0 ? "SPILL-FLAG" : "PASS");
    std::printf("SUMMARY\t%s\tblocker_failures=%d\tspill_flags=%d\n",
                status, blockerFailures, spillFlags);
    if (blockerFailures != 0) return 1;
    if (spillFlags != 0) return 2;
    return 0;
}
