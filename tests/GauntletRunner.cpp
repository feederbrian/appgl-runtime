#include "GauntletRunner.h"

#include "GoldenCompare.h"
#include "Scene.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#include "../include/AppGL/AppGL.h"
#include "../include/AppGL/glcorearb.h"
#include "../src/context/GLContext.h"
#include "../src/debug/CoverageStore.h"
#include "../src/loader/DispatchInstall.h"
#include "../src/objects/GLObjectStore.h"
#include "../src/runtime/AppGLRuntime.h"
#include "../src/shared/JsonUtil.h"
#include "../src/state/GLStateTracker.h"
#include "../src/state/IndexExpansion.h"

namespace appgl::tests {
namespace {

struct TestResult {
    std::string id;
    std::string status;
    double diffRatio = 0.0;
    double maxChannelDelta = 0.0;
    double millis = 0.0;
    std::vector<std::string> coverageDelta;
    std::string goldenPath;
    std::string actualPath;
    std::string message;
};

constexpr std::array<FunctionId, 141> kBootstrapFunctions = {
    FunctionId::glCullFace,
    FunctionId::glFrontFace,
    FunctionId::glHint,
    FunctionId::glLineWidth,
    FunctionId::glPointSize,
    FunctionId::glDrawBuffer,
    FunctionId::glClearColor,
    FunctionId::glClear,
    FunctionId::glClearDepth,
    FunctionId::glClearStencil,
    FunctionId::glScissor,
    FunctionId::glDepthRange,
    FunctionId::glPolygonOffset,
    FunctionId::glEnable,
    FunctionId::glDisable,
    FunctionId::glIsEnabled,
    FunctionId::glViewport,
    FunctionId::glFlush,
    FunctionId::glReadPixels,
    FunctionId::glStencilMask,
    FunctionId::glColorMask,
    FunctionId::glDepthMask,
    FunctionId::glBlendFunc,
    FunctionId::glStencilFunc,
    FunctionId::glStencilOp,
    FunctionId::glDepthFunc,
    FunctionId::glGetBooleanv,
    FunctionId::glGetIntegerv,
    FunctionId::glGetInteger64v,
    FunctionId::glGetFloatv,
    FunctionId::glGetDoublev,
    FunctionId::glGenBuffers,
    FunctionId::glDeleteBuffers,
    FunctionId::glIsBuffer,
    FunctionId::glBindBuffer,
    FunctionId::glBindBufferBase,
    FunctionId::glBindBufferRange,
    FunctionId::glBufferData,
    FunctionId::glBufferSubData,
    FunctionId::glCopyBufferSubData,
    FunctionId::glGetBufferSubData,
    FunctionId::glMapBuffer,
    FunctionId::glMapBufferRange,
    FunctionId::glUnmapBuffer,
    FunctionId::glFlushMappedBufferRange,
    FunctionId::glGetBufferParameteriv,
    FunctionId::glGetBufferParameteri64v,
    FunctionId::glGetBufferPointerv,
    FunctionId::glGenVertexArrays,
    FunctionId::glDeleteVertexArrays,
    FunctionId::glIsVertexArray,
    FunctionId::glBindVertexArray,
    FunctionId::glEnableVertexAttribArray,
    FunctionId::glDisableVertexAttribArray,
    FunctionId::glVertexAttribPointer,
    FunctionId::glVertexAttribIPointer,
    FunctionId::glVertexAttribDivisor,
    FunctionId::glGetVertexAttribiv,
    FunctionId::glGetVertexAttribfv,
    FunctionId::glGetVertexAttribPointerv,
    FunctionId::glActiveTexture,
    FunctionId::glGenTextures,
    FunctionId::glDeleteTextures,
    FunctionId::glIsTexture,
    FunctionId::glBindTexture,
    FunctionId::glTexImage1D,
    FunctionId::glTexImage2D,
    FunctionId::glTexImage3D,
    FunctionId::glTexSubImage1D,
    FunctionId::glTexSubImage2D,
    FunctionId::glTexSubImage3D,
    FunctionId::glTexParameteri,
    FunctionId::glTexParameteriv,
    FunctionId::glTexParameterf,
    FunctionId::glTexParameterfv,
    FunctionId::glTexParameterIiv,
    FunctionId::glTexParameterIuiv,
    FunctionId::glGetTexParameteriv,
    FunctionId::glGetTexParameterfv,
    FunctionId::glGetTexParameterIiv,
    FunctionId::glGetTexParameterIuiv,
    FunctionId::glGenerateMipmap,
    FunctionId::glPixelStorei,
    FunctionId::glPixelStoref,
    FunctionId::glReadBuffer,
    FunctionId::glDrawBuffers,
    FunctionId::glIsRenderbuffer,
    FunctionId::glBindRenderbuffer,
    FunctionId::glDeleteRenderbuffers,
    FunctionId::glGenRenderbuffers,
    FunctionId::glRenderbufferStorage,
    FunctionId::glGetRenderbufferParameteriv,
    FunctionId::glGenFramebuffers,
    FunctionId::glDeleteFramebuffers,
    FunctionId::glIsFramebuffer,
    FunctionId::glBindFramebuffer,
    FunctionId::glCheckFramebufferStatus,
    FunctionId::glFramebufferTexture1D,
    FunctionId::glFramebufferTexture2D,
    FunctionId::glFramebufferTexture3D,
    FunctionId::glFramebufferRenderbuffer,
    FunctionId::glGetFramebufferAttachmentParameteriv,
    FunctionId::glRenderbufferStorageMultisample,
    FunctionId::glFramebufferTextureLayer,
    FunctionId::glFramebufferTexture,
    FunctionId::glGenSamplers,
    FunctionId::glDeleteSamplers,
    FunctionId::glIsSampler,
    FunctionId::glBindSampler,
    FunctionId::glSamplerParameteri,
    FunctionId::glSamplerParameteriv,
    FunctionId::glSamplerParameterf,
    FunctionId::glSamplerParameterfv,
    FunctionId::glSamplerParameterIiv,
    FunctionId::glSamplerParameterIuiv,
    FunctionId::glGetSamplerParameteriv,
    FunctionId::glGetSamplerParameterfv,
    FunctionId::glGetSamplerParameterIiv,
    FunctionId::glGetSamplerParameterIuiv,
    FunctionId::glBlendFuncSeparate,
    FunctionId::glBlendColor,
    FunctionId::glBlendEquation,
    FunctionId::glBlendEquationSeparate,
    FunctionId::glStencilOpSeparate,
    FunctionId::glStencilFuncSeparate,
    FunctionId::glStencilMaskSeparate,
    FunctionId::glColorMaski,
    FunctionId::glDepthRangef,
    FunctionId::glGetString,
    FunctionId::glGetError,
    FunctionId::glDebugMessageControl,
    FunctionId::glDebugMessageInsert,
    FunctionId::glDebugMessageCallback,
    FunctionId::glGetDebugMessageLog,
    FunctionId::glPushDebugGroup,
    FunctionId::glPopDebugGroup,
    FunctionId::glObjectLabel,
    FunctionId::glGetObjectLabel,
    FunctionId::glObjectPtrLabel,
    FunctionId::glGetObjectPtrLabel,
    FunctionId::glGetPointerv,
};

bool gLastGauntletPassed = false;

bool stateAtLeastSmokeTested(CoverageState state) {
    return static_cast<int>(state) >= static_cast<int>(CoverageState::SmokeTested);
}

std::string formatDouble(double value) {
    std::ostringstream stream;
    stream.setf(std::ios::fixed);
    stream.precision(6);
    stream << value;
    return stream.str();
}

std::string pixelSummary(std::string_view label, const Image& image) {
    std::ostringstream stream;
    stream << label << "=";
    if (image.empty() || image.pixels.size() < 4) {
        stream << "empty";
        return stream.str();
    }
    const std::size_t centerX = static_cast<std::size_t>(image.width / 2);
    const std::size_t centerY = static_cast<std::size_t>(image.height / 2);
    const std::size_t offset = (centerY * static_cast<std::size_t>(image.width) + centerX) * 4;
    stream << "rgba("
           << static_cast<int>(image.pixels[offset + 0]) << ","
           << static_cast<int>(image.pixels[offset + 1]) << ","
           << static_cast<int>(image.pixels[offset + 2]) << ","
           << static_cast<int>(image.pixels[offset + 3]) << ")";
    return stream.str();
}

void APIENTRY bootstrapDebugCallback(
    GLenum source,
    GLenum type,
    GLuint identifier,
    GLenum severity,
    GLsizei length,
    const GLchar* message,
    const void* userParam
) {
    (void)source;
    (void)type;
    (void)identifier;
    (void)severity;
    (void)length;
    (void)message;
    (void)userParam;
}

void expectCondition(bool condition, std::string_view label) {
    if (!condition) {
        throw std::runtime_error(std::string("Gauntlet expectation failed: ") + std::string(label));
    }
}

void expectGLError(GLDispatchTable& gl, GLenum expected, std::string_view label) {
    const GLenum actual = gl.glGetError();
    if (actual != expected) {
        throw std::runtime_error(
            std::string("Gauntlet GL error mismatch for ")
            + std::string(label)
            + ": expected "
            + std::to_string(expected)
            + ", got "
            + std::to_string(actual)
        );
    }
}

std::filesystem::path workspaceRoot() {
    const auto isRoot = [](const std::filesystem::path& path) {
        std::error_code error;
        return std::filesystem::exists(path / "runtime" / "CMakeLists.txt", error)
            && std::filesystem::exists(path / "docs" / "goldens" / "phase-a" / "README.md", error);
    };

    const auto canonicalOrAbsolute = [](std::filesystem::path path) {
        std::error_code error;
        const auto canonical = std::filesystem::weakly_canonical(path, error);
        if (!error && !canonical.empty()) {
            return canonical;
        }
        if (path.is_relative()) {
            return std::filesystem::absolute(path, error);
        }
        return path;
    };

    const auto findFrom = [&](std::filesystem::path start) {
        start = canonicalOrAbsolute(std::move(start));
        if (std::filesystem::is_regular_file(start)) {
            start = start.parent_path();
        }
        for (std::filesystem::path cursor = start; !cursor.empty(); cursor = cursor.parent_path()) {
            if (isRoot(cursor)) {
                return cursor;
            }
            if (cursor == cursor.root_path()) {
                break;
            }
        }
        return std::filesystem::path{};
    };

    if (const char* root = std::getenv("APPGL_WORKSPACE_ROOT"); root != nullptr && root[0] != '\0') {
        const std::filesystem::path candidate = canonicalOrAbsolute(root);
        if (isRoot(candidate)) {
            return candidate;
        }
    }

    if (const auto root = findFrom(__FILE__); !root.empty()) {
        return root;
    }

    if (const auto root = findFrom(std::filesystem::current_path()); !root.empty()) {
        return root;
    }

    if (const char* home = std::getenv("HOME"); home != nullptr && home[0] != '\0') {
        const std::filesystem::path homePath(home);
        for (const auto& candidate : {
                 homePath / "Documents" / "Developer" / "OpenGL 4.6 Mac",
                 homePath / "Developer" / "OpenGL 4.6 Mac",
             }) {
            const auto canonical = canonicalOrAbsolute(candidate);
            if (isRoot(canonical)) {
                return canonical;
            }
        }
    }

    return canonicalOrAbsolute(std::filesystem::path(__FILE__)).parent_path().parent_path().parent_path();
}

bool shouldWriteGoldens() {
    if (const char* value = std::getenv("APPGL_WRITE_GOLDENS"); value != nullptr) {
        return std::string_view(value) == "1" || std::string_view(value) == "true";
    }
    return false;
}

class ClearReadbackScene final : public Scene {
public:
    std::string id() const override {
        return "phase-a.read-pixels";
    }

    std::string phase() const override {
        return "phase-a";
    }

    SceneSize framebufferSize() const override {
        return {128, 128};
    }

    void setup(GLContext& context) override {
        auto& gl = Runtime::shared().dispatch();
        gl.glDebugMessageCallback(&bootstrapDebugCallback, nullptr);
        gl.glViewport(0, 0, framebufferSize().width, framebufferSize().height);
        gl.glScissor(0, 0, framebufferSize().width, framebufferSize().height);
        gl.glDepthRange(0.0, 1.0);
        gl.glDepthRangef(0.0f, 1.0f);
        gl.glClearDepth(0.875);
        gl.glClearStencil(3);
        gl.glEnable(GL_DEPTH_TEST);
        (void)gl.glIsEnabled(GL_DEPTH_TEST);
        gl.glDisable(GL_DEPTH_TEST);
        gl.glEnable(GL_SCISSOR_TEST);
        gl.glDisable(GL_SCISSOR_TEST);
        gl.glBlendColor(0.0f, 0.0f, 0.0f, 0.0f);
        gl.glBlendFunc(GL_ONE, GL_ZERO);
        gl.glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ZERO);
        gl.glBlendEquation(GL_FUNC_ADD);
        gl.glBlendEquationSeparate(GL_FUNC_ADD, GL_FUNC_ADD);
        gl.glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        gl.glColorMaski(0, GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        gl.glDepthFunc(GL_LESS);
        gl.glDepthMask(GL_TRUE);
        gl.glStencilFunc(GL_ALWAYS, 0, ~0u);
        gl.glStencilFuncSeparate(GL_FRONT_AND_BACK, GL_ALWAYS, 0, ~0u);
        gl.glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
        gl.glStencilOpSeparate(GL_FRONT_AND_BACK, GL_KEEP, GL_KEEP, GL_KEEP);
        gl.glStencilMask(~0u);
        gl.glStencilMaskSeparate(GL_FRONT_AND_BACK, ~0u);
        gl.glCullFace(GL_BACK);
        gl.glFrontFace(GL_CCW);
        gl.glPolygonOffset(0.0f, 0.0f);
        gl.glLineWidth(1.0f);
        gl.glPointSize(1.0f);
        gl.glHint(GL_FRAGMENT_SHADER_DERIVATIVE_HINT, GL_DONT_CARE);
        gl.glEnable(GL_DEBUG_OUTPUT);
        gl.glDebugMessageControl(GL_DONT_CARE, GL_DONT_CARE, GL_DONT_CARE, 0, nullptr, GL_TRUE);
        gl.glDebugMessageInsert(
            GL_DEBUG_SOURCE_APPLICATION,
            GL_DEBUG_TYPE_MARKER,
            42,
            GL_DEBUG_SEVERITY_NOTIFICATION,
            -1,
            "phase-a debug marker"
        );
        GLenum debugSources[1] = {};
        GLenum debugTypes[1] = {};
        GLuint debugIds[1] = {};
        GLenum debugSeverities[1] = {};
        GLsizei debugLengths[1] = {};
        GLchar debugLog[128] = {};
        (void)gl.glGetDebugMessageLog(1, sizeof(debugLog), debugSources, debugTypes, debugIds, debugSeverities, debugLengths, debugLog);
        gl.glPushDebugGroup(GL_DEBUG_SOURCE_APPLICATION, 77, -1, "phase-a group");
        gl.glPopDebugGroup();
        gl.glObjectLabel(GL_BUFFER, 7, -1, "phase-a buffer");
        GLsizei labelLength = 0;
        GLchar labelBuffer[64] = {};
        gl.glGetObjectLabel(GL_BUFFER, 7, sizeof(labelBuffer), &labelLength, labelBuffer);
        int pointerLabelTarget = 0;
        gl.glObjectPtrLabel(&pointerLabelTarget, -1, "phase-a pointer");
        gl.glGetObjectPtrLabel(&pointerLabelTarget, sizeof(labelBuffer), &labelLength, labelBuffer);
        void* callbackPointer = nullptr;
        gl.glGetPointerv(GL_DEBUG_CALLBACK_FUNCTION, &callbackPointer);
        gl.glDisable(GL_DEBUG_OUTPUT);

        GLuint framebuffers[2] = {};
        gl.glGenFramebuffers(2, framebuffers);
        expectCondition(gl.glIsFramebuffer(framebuffers[0]) == GL_FALSE, "generated framebuffer is not instantiated before bind");
        gl.glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffers[0]);
        expectCondition(gl.glIsFramebuffer(framebuffers[0]) == GL_TRUE, "draw-bound framebuffer is instantiated");
        GLint drawFramebufferBinding = -1;
        GLint readFramebufferBinding = -1;
        gl.glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFramebufferBinding);
        gl.glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFramebufferBinding);
        expectCondition(drawFramebufferBinding == static_cast<GLint>(framebuffers[0]), "draw framebuffer binding query");
        expectCondition(readFramebufferBinding == 0, "draw-only framebuffer bind leaves read binding unchanged");
        gl.glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffers[1]);
        gl.glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFramebufferBinding);
        expectCondition(readFramebufferBinding == static_cast<GLint>(framebuffers[1]), "read framebuffer binding query");
        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffers[0]);
        gl.glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFramebufferBinding);
        gl.glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFramebufferBinding);
        expectCondition(drawFramebufferBinding == static_cast<GLint>(framebuffers[0]), "GL_FRAMEBUFFER updates draw binding");
        expectCondition(readFramebufferBinding == static_cast<GLint>(framebuffers[0]), "GL_FRAMEBUFFER updates read binding");
        gl.glBindFramebuffer(static_cast<GLenum>(0xffffffffu), framebuffers[0]);
        expectGLError(gl, GL_INVALID_ENUM, "invalid glBindFramebuffer target");
        const GLuint unknownFramebuffer = framebuffers[1] + 999u;
        gl.glBindFramebuffer(GL_FRAMEBUFFER, unknownFramebuffer);
        expectGLError(gl, GL_INVALID_OPERATION, "binding unknown framebuffer");

        GLuint renderbuffers[2] = {};
        gl.glGenRenderbuffers(2, renderbuffers);
        expectCondition(gl.glIsRenderbuffer(renderbuffers[0]) == GL_FALSE, "generated renderbuffer is not instantiated before bind");
        gl.glBindRenderbuffer(GL_RENDERBUFFER, renderbuffers[0]);
        expectCondition(gl.glIsRenderbuffer(renderbuffers[0]) == GL_TRUE, "bound renderbuffer is instantiated");
        gl.glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 16, 16);
        GLint renderbufferWidth = 0;
        gl.glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &renderbufferWidth);
        expectCondition(renderbufferWidth == 16, "renderbuffer width query");
        gl.glBindRenderbuffer(GL_RENDERBUFFER, renderbuffers[1]);
        gl.glRenderbufferStorageMultisample(GL_RENDERBUFFER, 0, GL_DEPTH24_STENCIL8, 16, 16);
        GLint renderbufferSamples = -1;
        gl.glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_SAMPLES, &renderbufferSamples);
        expectCondition(renderbufferSamples == 0, "renderbuffer sample query");

        GLuint framebufferTextures[3] = {};
        gl.glGenTextures(3, framebufferTextures);
        const std::uint8_t fboLine[64] = {};
        const std::uint8_t fboImage[16 * 16 * 4] = {};
        const std::uint8_t fboVolume[16 * 16 * 2 * 4] = {};
        gl.glBindTexture(GL_TEXTURE_1D, framebufferTextures[0]);
        gl.glTexImage1D(GL_TEXTURE_1D, 0, GL_RGBA8, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, fboLine);
        gl.glBindTexture(GL_TEXTURE_2D, framebufferTextures[1]);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, fboImage);
        gl.glBindTexture(GL_TEXTURE_3D, framebufferTextures[2]);
        gl.glTexImage3D(GL_TEXTURE_3D, 0, GL_RGBA8, 16, 16, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, fboVolume);

        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffers[0]);
        gl.glFramebufferTexture1D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_1D, framebufferTextures[0], 0);
        gl.glFramebufferTexture1D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_1D, 0, 0);
        gl.glFramebufferTexture3D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_3D, framebufferTextures[2], 0, 0);
        gl.glFramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, framebufferTextures[2], 0, 1);
        gl.glFramebufferTexture(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, framebufferTextures[1], 0);
        gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, framebufferTextures[1], 0);
        gl.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, renderbuffers[1]);
        GLint attachmentType = 0;
        gl.glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &attachmentType);
        expectCondition(attachmentType == GL_TEXTURE, "framebuffer attachment object type query");
        const GLenum drawBuffers[2] = {GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1};
        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glDrawBuffers(2, drawBuffers);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        GLint drawBuffer0 = 0;
        GLint drawBuffer1 = 0;
        gl.glGetIntegerv(GL_DRAW_BUFFER0, &drawBuffer0);
        gl.glGetIntegerv(GL_DRAW_BUFFER1, &drawBuffer1);
        expectCondition(drawBuffer0 == GL_COLOR_ATTACHMENT0 && drawBuffer1 == GL_COLOR_ATTACHMENT1, "draw buffer query");
        GLint readBuffer = 0;
        gl.glGetIntegerv(GL_READ_BUFFER, &readBuffer);
        expectCondition(readBuffer == GL_COLOR_ATTACHMENT0, "read buffer query");
        expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "attached framebuffer is complete");
        gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
        expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_INCOMPLETE_DRAW_BUFFER, "detached draw attachment makes framebuffer incomplete");
        gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, framebufferTextures[1], 0);

        gl.glDeleteFramebuffers(1, &framebuffers[0]);
        expectCondition(gl.glIsFramebuffer(framebuffers[0]) == GL_FALSE, "deleted framebuffer no longer exists");
        gl.glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFramebufferBinding);
        gl.glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFramebufferBinding);
        expectCondition(drawFramebufferBinding == 0 && readFramebufferBinding == 0, "deleting bound framebuffer resets bindings");
        gl.glDeleteFramebuffers(1, &framebuffers[1]);
        gl.glDeleteRenderbuffers(2, renderbuffers);
        gl.glDeleteTextures(3, framebufferTextures);

        GLuint buffers[2] = {};
        gl.glGenBuffers(2, buffers);
        gl.glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
        const std::uint32_t seedData[4] = {1, 2, 3, 4};
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(seedData), seedData, GL_STATIC_DRAW);
        const std::uint32_t patchData[2] = {20, 30};
        gl.glBufferSubData(GL_ARRAY_BUFFER, sizeof(std::uint32_t), sizeof(patchData), patchData);
        std::uint32_t readbackData[4] = {};
        gl.glGetBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(readbackData), readbackData);
        gl.glBufferData(GL_ARRAY_BUFFER, -1, nullptr, GL_STATIC_DRAW);
        expectGLError(gl, GL_INVALID_VALUE, "negative glBufferData size");
        gl.glBindBuffer(static_cast<GLenum>(0xffffffffu), buffers[0]);
        expectGLError(gl, GL_INVALID_ENUM, "invalid glBindBuffer target");
        gl.glBindBuffer(GL_COPY_READ_BUFFER, buffers[0]);
        gl.glBindBuffer(GL_COPY_WRITE_BUFFER, buffers[1]);
        gl.glBufferData(GL_COPY_WRITE_BUFFER, sizeof(readbackData), nullptr, GL_DYNAMIC_DRAW);
        gl.glCopyBufferSubData(GL_COPY_READ_BUFFER, GL_COPY_WRITE_BUFFER, 0, 0, sizeof(readbackData));
        gl.glGetBufferSubData(GL_COPY_WRITE_BUFFER, 0, sizeof(readbackData), readbackData);
        gl.glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
        void* mappedRange = gl.glMapBufferRange(
            GL_ARRAY_BUFFER,
            sizeof(std::uint32_t),
            sizeof(std::uint32_t) * 2,
            GL_MAP_WRITE_BIT | GL_MAP_FLUSH_EXPLICIT_BIT
        );
        if (mappedRange != nullptr) {
            auto* mappedWords = static_cast<std::uint32_t*>(mappedRange);
            mappedWords[0] = 100;
            mappedWords[1] = 200;
        }
        std::uint32_t rejectedMappedWrite = 9;
        gl.glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(rejectedMappedWrite), &rejectedMappedWrite);
        expectGLError(gl, GL_INVALID_OPERATION, "glBufferSubData while mapped");
        GLint mappedFlag = 0;
        gl.glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_MAPPED, &mappedFlag);
        GLint accessFlags = 0;
        gl.glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_ACCESS_FLAGS, &accessFlags);
        GLint64 mapLength = 0;
        gl.glGetBufferParameteri64v(GL_ARRAY_BUFFER, GL_BUFFER_MAP_LENGTH, &mapLength);
        void* queriedMapPointer = nullptr;
        gl.glGetBufferPointerv(GL_ARRAY_BUFFER, GL_BUFFER_MAP_POINTER, &queriedMapPointer);
        gl.glFlushMappedBufferRange(GL_ARRAY_BUFFER, 0, sizeof(std::uint32_t) * 2);
        (void)gl.glUnmapBuffer(GL_ARRAY_BUFFER);
        gl.glFlushMappedBufferRange(GL_ARRAY_BUFFER, 0, sizeof(std::uint32_t));
        expectGLError(gl, GL_INVALID_OPERATION, "glFlushMappedBufferRange after unmap");
        void* wholeMap = gl.glMapBuffer(GL_ARRAY_BUFFER, GL_READ_WRITE);
        if (wholeMap != nullptr) {
            auto* mappedWords = static_cast<std::uint32_t*>(wholeMap);
            mappedWords[3] = 400;
        }
        (void)gl.glUnmapBuffer(GL_ARRAY_BUFFER);
        GLint bufferSize = 0;
        gl.glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_SIZE, &bufferSize);
        (void)mappedFlag;
        (void)accessFlags;
        (void)mapLength;
        (void)queriedMapPointer;
        (void)bufferSize;
        gl.glGetBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(readbackData), readbackData);

        GLuint vertexArray = 0;
        gl.glGenVertexArrays(1, &vertexArray);
        expectCondition(gl.glIsVertexArray(vertexArray) == GL_FALSE, "generated VAO is not instantiated before bind");
        gl.glBindVertexArray(vertexArray);
        expectCondition(gl.glIsVertexArray(vertexArray) == GL_TRUE, "bound VAO is instantiated");
        gl.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, buffers[1]);
        gl.glBindVertexArray(0);
        GLint elementArrayBinding = -1;
        gl.glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &elementArrayBinding);
        expectCondition(elementArrayBinding == 0, "unbound VAO clears element-array binding");
        gl.glBindVertexArray(vertexArray);
        gl.glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &elementArrayBinding);
        expectCondition(elementArrayBinding == static_cast<GLint>(buffers[1]), "VAO restores element-array binding");
        gl.glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
        const auto attributeOffset = static_cast<std::uintptr_t>(sizeof(float) * 2);
        gl.glVertexAttribPointer(
            0,
            3,
            GL_FLOAT,
            GL_FALSE,
            static_cast<GLsizei>(sizeof(float) * 5),
            reinterpret_cast<const void*>(attributeOffset)
        );
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribDivisor(0, 1);
        gl.glVertexAttribIPointer(1, 4, GL_UNSIGNED_BYTE, static_cast<GLsizei>(sizeof(std::uint32_t)), nullptr);
        gl.glEnableVertexAttribArray(1);
        GLint attribQuery = 0;
        gl.glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &attribQuery);
        expectCondition(attribQuery == GL_TRUE, "vertex attribute 0 enabled");
        gl.glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &attribQuery);
        expectCondition(attribQuery == static_cast<GLint>(buffers[0]), "vertex attribute captures GL_ARRAY_BUFFER");
        gl.glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_DIVISOR, &attribQuery);
        expectCondition(attribQuery == 1, "vertex attribute divisor query");
        gl.glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_INTEGER, &attribQuery);
        expectCondition(attribQuery == GL_TRUE, "integer vertex attribute query");
        GLfloat attribSize = 0.0f;
        gl.glGetVertexAttribfv(0, GL_VERTEX_ATTRIB_ARRAY_SIZE, &attribSize);
        expectCondition(attribSize == 3.0f, "float vertex attribute size query");
        void* attribPointer = nullptr;
        gl.glGetVertexAttribPointerv(0, GL_VERTEX_ATTRIB_ARRAY_POINTER, &attribPointer);
        expectCondition(
            reinterpret_cast<std::uintptr_t>(attribPointer) == attributeOffset,
            "vertex attribute pointer query"
        );
        context.state().applyDirtyStateForDraw(context.objects());
        GLVertexArrayObject* vertexArrayObject = context.objects().vertexArrays().get(vertexArray);
        expectCondition(vertexArrayObject != nullptr, "VAO object remains available for descriptor build");
        expectCondition(vertexArrayObject->metalVertexDescriptor != nullptr, "MTLVertexDescriptor is cached on VAO");
        expectCondition(!vertexArrayObject->vertexDescriptorDirty, "VAO descriptor dirty bit is cleared after build");
        expectCondition(vertexArrayObject->vertexDescriptorError.empty(), "VAO descriptor build has no error");
        expectCondition(!vertexArrayObject->vertexDescriptorHash.empty(), "VAO descriptor hash is populated");
        gl.glDisableVertexAttribArray(1);
        expectCondition(vertexArrayObject->vertexDescriptorDirty, "VAO descriptor is dirtied by attribute state changes");
        gl.glVertexAttribPointer(0, 3, static_cast<GLenum>(0xffffffffu), GL_FALSE, 0, nullptr);
        expectGLError(gl, GL_INVALID_ENUM, "invalid glVertexAttribPointer type");
        gl.glDeleteVertexArrays(1, &vertexArray);
        expectCondition(gl.glIsVertexArray(vertexArray) == GL_FALSE, "deleted VAO no longer exists");
        gl.glBindVertexArray(vertexArray);
        expectGLError(gl, GL_INVALID_OPERATION, "binding deleted vertex array");

        gl.glBindBufferRange(GL_UNIFORM_BUFFER, 0, buffers[0], 0, sizeof(readbackData));
        gl.glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, buffers[1]);
        (void)gl.glIsBuffer(buffers[0]);
        gl.glDeleteBuffers(2, buffers);
        (void)gl.glIsBuffer(buffers[0]);

        gl.glActiveTexture(GL_TEXTURE1);
        GLint activeTexture = 0;
        gl.glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
        expectCondition(activeTexture == GL_TEXTURE1, "active texture query");
        gl.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        gl.glPixelStoref(GL_PACK_ALIGNMENT, 4.0f);
        GLint unpackAlignment = 0;
        gl.glGetIntegerv(GL_UNPACK_ALIGNMENT, &unpackAlignment);
        expectCondition(unpackAlignment == 1, "unpack alignment query");
        GLuint textures[3] = {};
        gl.glGenTextures(3, textures);
        expectCondition(gl.glIsTexture(textures[0]) == GL_FALSE, "generated texture is not instantiated before bind");

        const std::uint8_t linePixels[8] = {
            255, 0, 0, 255,
            0, 255, 0, 255,
        };
        const std::uint8_t linePatch[4] = {0, 0, 255, 255};
        gl.glBindTexture(GL_TEXTURE_1D, textures[0]);
        expectCondition(gl.glIsTexture(textures[0]) == GL_TRUE, "bound 1D texture is instantiated");
        gl.glTexImage1D(GL_TEXTURE_1D, 0, GL_RGBA8, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, linePixels);
        gl.glTexSubImage1D(GL_TEXTURE_1D, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, linePatch);

        const std::uint8_t imagePixels[16] = {
            10, 20, 30, 255,
            40, 50, 60, 255,
            70, 80, 90, 255,
            100, 110, 120, 255,
        };
        const std::uint8_t imagePatch[4] = {200, 150, 100, 255};
        const GLfloat borderColor[4] = {0.25f, 0.5f, 0.75f, 1.0f};
        const GLint swizzle[4] = {GL_RED, GL_GREEN, GL_BLUE, GL_ALPHA};
        const GLint wrapMode[1] = {GL_CLAMP_TO_EDGE};
        const GLuint maxLevel[1] = {4};
        gl.glBindTexture(GL_TEXTURE_2D, textures[1]);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        gl.glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MIN_LOD, -2.0f);
        gl.glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, borderColor);
        gl.glTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_RGBA, swizzle);
        gl.glTexParameterIiv(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrapMode);
        gl.glTexParameterIuiv(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, maxLevel);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, imagePixels);
        gl.glTexSubImage2D(GL_TEXTURE_2D, 0, 1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, imagePatch);
        gl.glGenerateMipmap(GL_TEXTURE_2D);
        GLint textureParam = 0;
        gl.glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, &textureParam);
        expectCondition(textureParam == GL_LINEAR, "texture min filter query");
        GLfloat textureBorder[4] = {};
        gl.glGetTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, textureBorder);
        expectCondition(textureBorder[2] == borderColor[2], "texture border color query");
        gl.glGetTexParameterIiv(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, &textureParam);
        expectCondition(textureParam == GL_CLAMP_TO_EDGE, "texture integer parameter query");
        GLuint textureParamUnsigned = 0;
        gl.glGetTexParameterIuiv(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, &textureParamUnsigned);
        expectCondition(textureParamUnsigned == maxLevel[0], "texture unsigned parameter query");

        const std::uint8_t volumePixels[8] = {1, 2, 3, 4, 5, 6, 7, 8};
        const std::uint8_t volumePatch[1] = {99};
        gl.glBindTexture(GL_TEXTURE_3D, textures[2]);
        gl.glTexImage3D(GL_TEXTURE_3D, 0, GL_R8, 2, 2, 2, 0, GL_RED, GL_UNSIGNED_BYTE, volumePixels);
        gl.glTexSubImage3D(GL_TEXTURE_3D, 0, 1, 1, 1, 1, 1, 1, GL_RED, GL_UNSIGNED_BYTE, volumePatch);
        const GLTextureObject* textureObject = context.objects().textures().get(textures[1]);
        expectCondition(textureObject != nullptr && textureObject->levels.contains(0), "2D texture level exists");
        const auto& textureLevel = textureObject->levels.at(0);
        expectCondition(textureLevel.rgba8.size() == 16, "2D texture shadow bytes exist");
        expectCondition(textureLevel.rgba8[12] == 200, "2D texture subimage updated shadow storage");
        expectCondition(textureObject->levels.contains(1), "2D texture mip level generated");
        expectCondition(textureObject->levels.at(1).desc.width == 1, "2D texture mip width is halved");
        gl.glBindTexture(static_cast<GLenum>(0xffffffffu), textures[1]);
        expectGLError(gl, GL_INVALID_ENUM, "invalid glBindTexture target");
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, static_cast<GLenum>(0xffffffffu), GL_UNSIGNED_BYTE, imagePatch);
        expectGLError(gl, GL_INVALID_ENUM, "invalid glTexImage2D format");

        GLuint sampler = 0;
        gl.glGenSamplers(1, &sampler);
        expectCondition(gl.glIsSampler(sampler) == GL_TRUE, "generated sampler is instantiated");
        gl.glBindSampler(1, sampler);
        GLint samplerBinding = 0;
        gl.glGetIntegerv(GL_SAMPLER_BINDING, &samplerBinding);
        expectCondition(samplerBinding == static_cast<GLint>(sampler), "sampler binding query");
        gl.glSamplerParameteri(sampler, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
        gl.glSamplerParameterf(sampler, GL_TEXTURE_MIN_LOD, 0.0f);
        gl.glSamplerParameterfv(sampler, GL_TEXTURE_BORDER_COLOR, borderColor);
        gl.glSamplerParameteriv(sampler, GL_TEXTURE_WRAP_T, wrapMode);
        gl.glSamplerParameterIiv(sampler, GL_TEXTURE_COMPARE_FUNC, wrapMode);
        expectGLError(gl, GL_INVALID_ENUM, "invalid sampler compare func");
        const GLint compareFunc[1] = {GL_LEQUAL};
        gl.glSamplerParameterIiv(sampler, GL_TEXTURE_COMPARE_FUNC, compareFunc);
        const GLuint wrapR[1] = {GL_REPEAT};
        gl.glSamplerParameterIuiv(sampler, GL_TEXTURE_WRAP_R, wrapR);
        GLint samplerParam = 0;
        gl.glGetSamplerParameteriv(sampler, GL_TEXTURE_MIN_FILTER, &samplerParam);
        expectCondition(samplerParam == GL_LINEAR_MIPMAP_LINEAR, "sampler min filter query");
        GLfloat samplerBorder[4] = {};
        gl.glGetSamplerParameterfv(sampler, GL_TEXTURE_BORDER_COLOR, samplerBorder);
        expectCondition(samplerBorder[1] == borderColor[1], "sampler border color query");
        gl.glGetSamplerParameterIiv(sampler, GL_TEXTURE_COMPARE_FUNC, &samplerParam);
        expectCondition(samplerParam == GL_LEQUAL, "sampler integer query");
        GLuint samplerParamUnsigned = 0;
        gl.glGetSamplerParameterIuiv(sampler, GL_TEXTURE_WRAP_R, &samplerParamUnsigned);
        expectCondition(samplerParamUnsigned == GL_REPEAT, "sampler unsigned query");
        gl.glDeleteSamplers(1, &sampler);
        expectCondition(gl.glIsSampler(sampler) == GL_FALSE, "deleted sampler no longer exists");
        gl.glDeleteTextures(3, textures);
        expectCondition(gl.glIsTexture(textures[1]) == GL_FALSE, "deleted texture no longer exists");

        GLint maxTextureSize = 0;
        gl.glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTextureSize);
        (void)maxTextureSize;
        GLint scissorBox[4] = {};
        gl.glGetIntegerv(GL_SCISSOR_BOX, scissorBox);
        (void)scissorBox;
        GLint64 maxElementIndex = 0;
        gl.glGetInteger64v(GL_MAX_ELEMENT_INDEX, &maxElementIndex);
        (void)maxElementIndex;
        GLfloat maxSamples = 0.0f;
        gl.glGetFloatv(GL_MAX_SAMPLES, &maxSamples);
        (void)maxSamples;
        GLboolean depthWriteMask = GL_FALSE;
        gl.glGetBooleanv(GL_DEPTH_WRITEMASK, &depthWriteMask);
        (void)depthWriteMask;
        GLdouble depthRange[2] = {};
        gl.glGetDoublev(GL_DEPTH_RANGE, depthRange);
        (void)depthRange;
        gl.glEnable(static_cast<GLenum>(0xffffffffu));
        (void)gl.glGetError();
        gl.glGetIntegerv(static_cast<GLenum>(0xffffffffu), &maxTextureSize);
        (void)gl.glGetError();
        (void)gl.glGetString(GL_VERSION);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glClearColor(0.18f, 0.25f, 0.41f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
        gl.glFlush();
    }

    // Pass 1 scenario promotion. ClearReadbackScene is the deepest <=3.3 surface
    // exerciser in the gauntlet — its setup() fans out into every bootstrap
    // dispatch entry point and its render() performs the deterministic golden
    // round-trip. Every call listed here is invoked via gl.gl* in the scene
    // body, so the golden image anchors the Scenario-tested promotion.
    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glActiveTexture,
            FunctionId::glBindBuffer,
            FunctionId::glBindBufferBase,
            FunctionId::glBindBufferRange,
            FunctionId::glBindFramebuffer,
            FunctionId::glBindRenderbuffer,
            FunctionId::glBindSampler,
            FunctionId::glBindTexture,
            FunctionId::glBindVertexArray,
            FunctionId::glBlendColor,
            FunctionId::glBlendEquation,
            FunctionId::glBlendEquationSeparate,
            FunctionId::glBlendFunc,
            FunctionId::glBlendFuncSeparate,
            FunctionId::glBufferData,
            FunctionId::glBufferSubData,
            FunctionId::glCheckFramebufferStatus,
            FunctionId::glClear,
            FunctionId::glClearColor,
            FunctionId::glClearDepth,
            FunctionId::glClearStencil,
            FunctionId::glColorMask,
            FunctionId::glColorMaski,
            FunctionId::glCopyBufferSubData,
            FunctionId::glCullFace,
            FunctionId::glDebugMessageCallback,
            FunctionId::glDebugMessageControl,
            FunctionId::glDebugMessageInsert,
            FunctionId::glDeleteBuffers,
            FunctionId::glDeleteFramebuffers,
            FunctionId::glDeleteRenderbuffers,
            FunctionId::glDeleteSamplers,
            FunctionId::glDeleteTextures,
            FunctionId::glDeleteVertexArrays,
            FunctionId::glDepthFunc,
            FunctionId::glDepthMask,
            FunctionId::glDepthRange,
            FunctionId::glDepthRangef,
            FunctionId::glDisable,
            FunctionId::glDisableVertexAttribArray,
            FunctionId::glDrawBuffer,
            FunctionId::glDrawBuffers,
            FunctionId::glEnable,
            FunctionId::glEnableVertexAttribArray,
            FunctionId::glFlush,
            FunctionId::glFlushMappedBufferRange,
            FunctionId::glFramebufferRenderbuffer,
            FunctionId::glFramebufferTexture,
            FunctionId::glFramebufferTexture1D,
            FunctionId::glFramebufferTexture2D,
            FunctionId::glFramebufferTexture3D,
            FunctionId::glFramebufferTextureLayer,
            FunctionId::glFrontFace,
            FunctionId::glGenBuffers,
            FunctionId::glGenFramebuffers,
            FunctionId::glGenRenderbuffers,
            FunctionId::glGenSamplers,
            FunctionId::glGenTextures,
            FunctionId::glGenVertexArrays,
            FunctionId::glGenerateMipmap,
            FunctionId::glGetBooleanv,
            FunctionId::glGetBufferParameteri64v,
            FunctionId::glGetBufferParameteriv,
            FunctionId::glGetBufferPointerv,
            FunctionId::glGetBufferSubData,
            FunctionId::glGetDebugMessageLog,
            FunctionId::glGetDoublev,
            FunctionId::glGetError,
            FunctionId::glGetFloatv,
            FunctionId::glGetFramebufferAttachmentParameteriv,
            FunctionId::glGetInteger64v,
            FunctionId::glGetIntegerv,
            FunctionId::glGetObjectLabel,
            FunctionId::glGetObjectPtrLabel,
            FunctionId::glGetPointerv,
            FunctionId::glGetRenderbufferParameteriv,
            FunctionId::glGetSamplerParameterIiv,
            FunctionId::glGetSamplerParameterIuiv,
            FunctionId::glGetSamplerParameterfv,
            FunctionId::glGetSamplerParameteriv,
            FunctionId::glGetString,
            FunctionId::glGetTexParameterIiv,
            FunctionId::glGetTexParameterIuiv,
            FunctionId::glGetTexParameterfv,
            FunctionId::glGetTexParameteriv,
            FunctionId::glGetVertexAttribPointerv,
            FunctionId::glGetVertexAttribfv,
            FunctionId::glGetVertexAttribiv,
            FunctionId::glHint,
            FunctionId::glIsBuffer,
            FunctionId::glIsEnabled,
            FunctionId::glIsFramebuffer,
            FunctionId::glIsRenderbuffer,
            FunctionId::glIsSampler,
            FunctionId::glIsTexture,
            FunctionId::glIsVertexArray,
            FunctionId::glLineWidth,
            FunctionId::glMapBuffer,
            FunctionId::glMapBufferRange,
            FunctionId::glObjectLabel,
            FunctionId::glObjectPtrLabel,
            FunctionId::glPixelStoref,
            FunctionId::glPixelStorei,
            FunctionId::glPointSize,
            FunctionId::glPolygonOffset,
            FunctionId::glPopDebugGroup,
            FunctionId::glPushDebugGroup,
            FunctionId::glReadBuffer,
            FunctionId::glRenderbufferStorage,
            FunctionId::glRenderbufferStorageMultisample,
            FunctionId::glSamplerParameterIiv,
            FunctionId::glSamplerParameterIuiv,
            FunctionId::glSamplerParameterf,
            FunctionId::glSamplerParameterfv,
            FunctionId::glSamplerParameteri,
            FunctionId::glSamplerParameteriv,
            FunctionId::glScissor,
            FunctionId::glStencilFunc,
            FunctionId::glStencilFuncSeparate,
            FunctionId::glStencilMask,
            FunctionId::glStencilMaskSeparate,
            FunctionId::glStencilOp,
            FunctionId::glStencilOpSeparate,
            FunctionId::glTexImage1D,
            FunctionId::glTexImage2D,
            FunctionId::glTexImage3D,
            FunctionId::glTexParameterIiv,
            FunctionId::glTexParameterIuiv,
            FunctionId::glTexParameterf,
            FunctionId::glTexParameterfv,
            FunctionId::glTexParameteri,
            FunctionId::glTexParameteriv,
            FunctionId::glTexSubImage1D,
            FunctionId::glTexSubImage2D,
            FunctionId::glTexSubImage3D,
            FunctionId::glUnmapBuffer,
            FunctionId::glVertexAttribDivisor,
            FunctionId::glVertexAttribIPointer,
            FunctionId::glVertexAttribPointer,
            FunctionId::glViewport,
        };
    }
};

class FramebufferDepthStencilReadbackScene final : public Scene {
public:
    std::string id() const override {
        return "phase-a.fbo-depth-stencil-readback";
    }

    std::string phase() const override {
        return "phase-a";
    }

    SceneSize framebufferSize() const override {
        return {48, 48};
    }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        const SceneSize size = framebufferSize();

        gl.glGenFramebuffers(1, &framebuffer_);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer_);

        gl.glGenTextures(1, &colorTexture_);
        gl.glBindTexture(GL_TEXTURE_2D, colorTexture_);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, size.width, size.height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, colorTexture_, 0);

        gl.glGenRenderbuffers(1, &depthStencilRenderbuffer_);
        gl.glBindRenderbuffer(GL_RENDERBUFFER, depthStencilRenderbuffer_);
        gl.glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, size.width, size.height);
        gl.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, depthStencilRenderbuffer_);

        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "offscreen FBO is complete");

        GLint attachmentType = 0;
        gl.glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &attachmentType);
        expectCondition(attachmentType == GL_RENDERBUFFER, "depth/stencil attachment object type query");

        GLint depthBits = 0;
        gl.glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE, &depthBits);
        expectCondition(depthBits == 24, "depth/stencil attachment depth-size query");

        GLint stencilBits = 0;
        gl.glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE, &stencilBits);
        expectCondition(stencilBits == 8, "depth/stencil attachment stencil-size query");
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        const SceneSize size = framebufferSize();

        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer_);
        gl.glViewport(0, 0, size.width, size.height);
        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        gl.glClearColor(0.18f, 0.44f, 0.70f, 1.0f);
        gl.glClearDepth(0.375);
        gl.glClearStencil(11);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);

        // Pass 2 scenario promotion. Exercise the typed-attachment clear
        // dispatch so the `glClearBuffer*` family gets a golden-backed call
        // against a known-complete FBO. The Group 8 stubs are no-ops today,
        // but the entry points are live and their dispatch pointers route
        // through `installGroup8Dispatch`.
        const GLfloat clearColor[4] = {0.18f, 0.44f, 0.70f, 1.0f};
        gl.glClearBufferfv(GL_COLOR, 0, clearColor);
        const GLint clearInts[4] = {0, 0, 0, 0};
        gl.glClearBufferiv(GL_COLOR, 0, clearInts);
        const GLuint clearUInts[4] = {0u, 0u, 0u, 0u};
        gl.glClearBufferuiv(GL_COLOR, 0, clearUInts);
        gl.glClearBufferfi(GL_DEPTH_STENCIL, 0, 0.375f, 11);
        expectGLError(gl, GL_NO_ERROR, "glClearBuffer family accepts legal args");

        std::array<GLfloat, 4> depthSample = {};
        gl.glReadPixels(11, 13, 2, 2, GL_DEPTH_COMPONENT, GL_FLOAT, depthSample.data());
        expectGLError(gl, GL_NO_ERROR, "offscreen FBO depth readback");
        for (GLfloat value : depthSample) {
            expectCondition(value > 0.374f && value < 0.376f, "offscreen FBO depth value");
        }

        std::array<std::uint8_t, 4> stencilSample = {};
        gl.glReadPixels(17, 19, 2, 2, GL_STENCIL_INDEX, GL_UNSIGNED_BYTE, stencilSample.data());
        expectGLError(gl, GL_NO_ERROR, "offscreen FBO stencil readback");
        for (std::uint8_t value : stencilSample) {
            expectCondition(value == 11, "offscreen FBO stencil value");
        }

        std::array<std::uint8_t, 4> colorSample = {};
        gl.glReadPixels(size.width / 2, size.height / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, colorSample.data());
        expectGLError(gl, GL_NO_ERROR, "offscreen FBO color readback");
        expectCondition(colorSample[0] == 46 && colorSample[1] == 112 && colorSample[2] == 179 && colorSample[3] == 255, "offscreen FBO color value");

        gl.glReadPixels(0, 0, 1, 1, GL_DEPTH_COMPONENT, GL_UNSIGNED_BYTE, colorSample.data());
        expectGLError(gl, GL_INVALID_ENUM, "unsupported offscreen FBO depth readback type");

        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);

        // Round-trip the cleared color through a second offscreen FBO via
        // glBlitFramebuffer, then read it back. Verifies that the COLOR_BUFFER_BIT
        // path is wired between independent attachments.
        GLuint copyFramebuffer = 0;
        GLuint copyTexture = 0;
        gl.glGenFramebuffers(1, &copyFramebuffer);
        gl.glGenTextures(1, &copyTexture);
        gl.glBindTexture(GL_TEXTURE_2D, copyTexture);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, size.width, size.height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        gl.glBindFramebuffer(GL_DRAW_FRAMEBUFFER, copyFramebuffer);
        gl.glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, copyTexture, 0);
        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffer_);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        expectCondition(gl.glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "blit destination FBO is complete");
        gl.glBlitFramebuffer(0, 0, size.width, size.height, 0, 0, size.width, size.height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        expectGLError(gl, GL_NO_ERROR, "color blit emits no error");

        gl.glBindFramebuffer(GL_READ_FRAMEBUFFER, copyFramebuffer);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        std::array<std::uint8_t, 4> blittedSample = {};
        gl.glReadPixels(size.width / 2, size.height / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, blittedSample.data());
        expectCondition(blittedSample[0] == 46 && blittedSample[1] == 112 && blittedSample[2] == 179 && blittedSample[3] == 255, "blitted color matches source");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer_);
        gl.glDeleteFramebuffers(1, &copyFramebuffer);
        gl.glDeleteTextures(1, &copyTexture);
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glBindFramebuffer,
            FunctionId::glBindRenderbuffer,
            FunctionId::glBindTexture,
            FunctionId::glBlitFramebuffer,
            FunctionId::glCheckFramebufferStatus,
            FunctionId::glClear,
            FunctionId::glClearBufferfi,
            FunctionId::glClearBufferfv,
            FunctionId::glClearBufferiv,
            FunctionId::glClearBufferuiv,
            FunctionId::glClearColor,
            FunctionId::glClearDepth,
            FunctionId::glClearStencil,
            FunctionId::glDeleteFramebuffers,
            FunctionId::glDeleteTextures,
            FunctionId::glDrawBuffer,
            FunctionId::glFramebufferRenderbuffer,
            FunctionId::glFramebufferTexture2D,
            FunctionId::glGenFramebuffers,
            FunctionId::glGenRenderbuffers,
            FunctionId::glGenTextures,
            FunctionId::glGetFramebufferAttachmentParameteriv,
            FunctionId::glReadBuffer,
            FunctionId::glReadPixels,
            FunctionId::glRenderbufferStorage,
            FunctionId::glTexImage2D,
            FunctionId::glViewport,
        };
    }

private:
    GLuint framebuffer_ = 0;
    GLuint colorTexture_ = 0;
    GLuint depthStencilRenderbuffer_ = 0;
};

class VertexInputStateScene final : public Scene {
public:
    std::string id() const override {
        return "phase-a.vertex-input";
    }

    std::string phase() const override {
        return "phase-a";
    }

    SceneSize framebufferSize() const override {
        return {96, 96};
    }

    void setup(GLContext& context) override {
        auto& gl = Runtime::shared().dispatch();

        GLuint buffers[2] = {};
        gl.glGenBuffers(2, buffers);
        gl.glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
        const float firstVertices[12] = {};
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(firstVertices), firstVertices, GL_STATIC_DRAW);
        gl.glBindBuffer(GL_COPY_WRITE_BUFFER, buffers[1]);
        const std::uint32_t indexData[3] = {0, 1, 2};
        gl.glBufferData(GL_COPY_WRITE_BUFFER, sizeof(indexData), indexData, GL_STATIC_DRAW);

        GLuint arrays[2] = {};
        gl.glGenVertexArrays(2, arrays);
        gl.glBindVertexArray(arrays[0]);
        gl.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, buffers[1]);
        gl.glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
        gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, static_cast<GLsizei>(sizeof(float) * 3), nullptr);
        gl.glEnableVertexAttribArray(0);
        context.state().applyDirtyStateForDraw(context.objects());
        const GLVertexArrayObject* firstArray = context.objects().vertexArrays().get(arrays[0]);
        expectCondition(firstArray != nullptr && firstArray->metalVertexDescriptor != nullptr, "first VAO descriptor exists");
        const std::string firstHash = firstArray->vertexDescriptorHash;

        gl.glBindVertexArray(arrays[1]);
        gl.glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
        gl.glVertexAttribPointer(
            0,
            2,
            GL_FLOAT,
            GL_FALSE,
            static_cast<GLsizei>(sizeof(float) * 4),
            reinterpret_cast<const void*>(sizeof(float))
        );
        gl.glEnableVertexAttribArray(0);
        context.state().applyDirtyStateForDraw(context.objects());
        const GLVertexArrayObject* secondArray = context.objects().vertexArrays().get(arrays[1]);
        expectCondition(secondArray != nullptr && secondArray->metalVertexDescriptor != nullptr, "second VAO descriptor exists");
        expectCondition(secondArray->vertexDescriptorHash != firstHash, "VAO descriptor hash reflects input layout");

        gl.glBindVertexArray(arrays[0]);
        GLint elementBinding = 0;
        gl.glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &elementBinding);
        expectCondition(elementBinding == static_cast<GLint>(buffers[1]), "scenario VAO restores element buffer");

        gl.glDeleteVertexArrays(2, arrays);
        gl.glDeleteBuffers(2, buffers);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glClearColor(0.30f, 0.16f, 0.19f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glBindBuffer,
            FunctionId::glBindVertexArray,
            FunctionId::glBufferData,
            FunctionId::glClear,
            FunctionId::glClearColor,
            FunctionId::glDeleteBuffers,
            FunctionId::glDeleteVertexArrays,
            FunctionId::glEnableVertexAttribArray,
            FunctionId::glFlush,
            FunctionId::glGenBuffers,
            FunctionId::glGenVertexArrays,
            FunctionId::glGetIntegerv,
            FunctionId::glVertexAttribPointer,
        };
    }
};

class TextureSamplerStateScene final : public Scene {
public:
    std::string id() const override {
        return "phase-a.texture-sampler-state";
    }

    std::string phase() const override {
        return "phase-a";
    }

    SceneSize framebufferSize() const override {
        return {80, 80};
    }

    void setup(GLContext& context) override {
        auto& gl = Runtime::shared().dispatch();

        gl.glActiveTexture(GL_TEXTURE3);
        GLint activeTexture = 0;
        gl.glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
        expectCondition(activeTexture == GL_TEXTURE3, "texture scenario active unit query");

        GLuint texture = 0;
        gl.glGenTextures(1, &texture);
        gl.glBindTexture(GL_TEXTURE_2D, texture);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 8);
        const GLuint wrapR = GL_CLAMP_TO_EDGE;
        gl.glTexParameterIuiv(GL_TEXTURE_2D, GL_TEXTURE_WRAP_R, &wrapR);
        const GLuint swizzle[4] = {GL_BLUE, GL_GREEN, GL_RED, GL_ALPHA};
        gl.glTexParameterIuiv(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_RGBA, swizzle);

        const std::uint8_t pixels[64] = {
            255, 0, 0, 255,      220, 20, 20, 255,    20, 220, 20, 255,    0, 255, 0, 255,
            220, 20, 20, 255,    180, 60, 40, 255,    60, 180, 40, 255,    20, 220, 20, 255,
            20, 20, 220, 255,    40, 60, 180, 255,    180, 60, 180, 255,   220, 20, 220, 255,
            0, 0, 255, 255,      20, 20, 220, 255,    220, 20, 220, 255,   255, 0, 255, 255,
        };
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        gl.glGenerateMipmap(GL_TEXTURE_2D);

        const GLTextureObject* textureObject = context.objects().textures().get(texture);
        expectCondition(textureObject != nullptr, "texture scenario object exists");
        expectCondition(textureObject->levels.contains(0), "texture scenario base level exists");
        expectCondition(textureObject->levels.contains(1), "texture scenario first mip exists");
        expectCondition(textureObject->levels.contains(2), "texture scenario second mip exists");
        expectCondition(textureObject->levels.at(1).desc.width == 2, "texture scenario first mip width");
        expectCondition(textureObject->levels.at(1).desc.height == 2, "texture scenario first mip height");
        expectCondition(textureObject->levels.at(2).desc.width == 1, "texture scenario tail mip width");
        expectCondition(textureObject->levels.at(2).rgba8.size() == 4, "texture scenario tail mip byte count");

        struct ScalarQuerySentinel {
            GLuint value = 0;
            GLuint guardA = 0xdecafbadu;
            GLuint guardB = 0xabcddcbau;
        };
        ScalarQuerySentinel textureScalar;
        gl.glGetTexParameterIuiv(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, &textureScalar.value);
        expectCondition(textureScalar.value == 8, "texture scalar unsigned query value");
        expectCondition(textureScalar.guardA == 0xdecafbadu && textureScalar.guardB == 0xabcddcbau, "texture scalar unsigned query guard");
        GLuint swizzleReadback[4] = {};
        gl.glGetTexParameterIuiv(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_RGBA, swizzleReadback);
        expectCondition(swizzleReadback[0] == GL_BLUE && swizzleReadback[2] == GL_RED, "texture vector unsigned query");

        GLuint sampler = 0;
        gl.glGenSamplers(1, &sampler);
        gl.glBindSampler(3, sampler);
        gl.glSamplerParameteri(sampler, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
        gl.glSamplerParameterf(sampler, GL_TEXTURE_MIN_LOD, 0.0f);
        const GLfloat borderColor[4] = {0.1f, 0.2f, 0.3f, 1.0f};
        gl.glSamplerParameterfv(sampler, GL_TEXTURE_BORDER_COLOR, borderColor);
        const GLuint samplerWrap = GL_REPEAT;
        gl.glSamplerParameterIuiv(sampler, GL_TEXTURE_WRAP_R, &samplerWrap);

        ScalarQuerySentinel samplerScalar;
        gl.glGetSamplerParameterIuiv(sampler, GL_TEXTURE_WRAP_R, &samplerScalar.value);
        expectCondition(samplerScalar.value == GL_REPEAT, "sampler scalar unsigned query value");
        expectCondition(samplerScalar.guardA == 0xdecafbadu && samplerScalar.guardB == 0xabcddcbau, "sampler scalar unsigned query guard");
        GLfloat samplerBorder[4] = {};
        gl.glGetSamplerParameterfv(sampler, GL_TEXTURE_BORDER_COLOR, samplerBorder);
        expectCondition(samplerBorder[2] == borderColor[2], "sampler vector float query");

        gl.glGenerateMipmap(static_cast<GLenum>(0xffffffffu));
        expectGLError(gl, GL_INVALID_ENUM, "invalid glGenerateMipmap target");

        gl.glDeleteSamplers(1, &sampler);
        gl.glDeleteTextures(1, &texture);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glClearColor(0.08f, 0.32f, 0.22f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glActiveTexture,
            FunctionId::glBindSampler,
            FunctionId::glBindTexture,
            FunctionId::glClear,
            FunctionId::glClearColor,
            FunctionId::glDeleteSamplers,
            FunctionId::glDeleteTextures,
            FunctionId::glFlush,
            FunctionId::glGenSamplers,
            FunctionId::glGenTextures,
            FunctionId::glGenerateMipmap,
            FunctionId::glGetIntegerv,
            FunctionId::glGetSamplerParameterIuiv,
            FunctionId::glGetSamplerParameterfv,
            FunctionId::glGetTexParameterIuiv,
            FunctionId::glSamplerParameterIuiv,
            FunctionId::glSamplerParameterf,
            FunctionId::glSamplerParameterfv,
            FunctionId::glSamplerParameteri,
            FunctionId::glTexImage2D,
            FunctionId::glTexParameterIuiv,
            FunctionId::glTexParameteri,
        };
    }
};

class IndexUInt8ExpansionScene final : public Scene {
public:
    std::string id() const override {
        return "phase-a.index-uint8-expansion";
    }

    std::string phase() const override {
        return "phase-a";
    }

    SceneSize framebufferSize() const override {
        return {64, 64};
    }

    void setup(GLContext& context) override {
        (void)context;

        const GLubyte quadIndices[6] = {0, 1, 2, 2, 3, 0};
        const IndexExpansionResult expanded = expandElementIndices(6, GL_UNSIGNED_BYTE, quadIndices);
        expectCondition(expanded.ok, "uint8 index expansion succeeds");
        expectCondition(expanded.outputType == GL_UNSIGNED_SHORT, "uint8 index expansion output type");
        expectCondition(expanded.bytes.size() == sizeof(GLushort) * 6, "uint8 index expansion byte size");
        const auto* expandedWords = reinterpret_cast<const GLushort*>(expanded.bytes.data());
        expectCondition(expandedWords[0] == 0 && expandedWords[3] == 2 && expandedWords[4] == 3, "uint8 index expansion values");

        const GLushort shortIndices[3] = {4, 5, 6};
        const IndexExpansionResult passThrough = expandElementIndices(3, GL_UNSIGNED_SHORT, shortIndices);
        expectCondition(passThrough.ok, "ushort index passthrough succeeds");
        expectCondition(passThrough.outputType == GL_UNSIGNED_SHORT, "ushort index passthrough output type");
        expectCondition(std::memcmp(passThrough.bytes.data(), shortIndices, sizeof(shortIndices)) == 0, "ushort index passthrough bytes");

        const IndexExpansionResult invalidType = expandElementIndices(1, static_cast<GLenum>(0xffffffffu), quadIndices);
        expectCondition(!invalidType.ok && invalidType.error == GL_INVALID_ENUM, "index expansion invalid type error");
        const IndexExpansionResult invalidCount = expandElementIndices(-1, GL_UNSIGNED_BYTE, quadIndices);
        expectCondition(!invalidCount.ok && invalidCount.error == GL_INVALID_VALUE, "index expansion invalid count error");
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glClearColor(0.42f, 0.20f, 0.08f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }
};

class ShaderProgramLifecycleScene final : public Scene {
public:
    std::string id() const override {
        return "phase-a.shader-program-lifecycle";
    }

    std::string phase() const override {
        return "phase-a";
    }

    SceneSize framebufferSize() const override {
        return {72, 72};
    }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        const GLuint vertex = gl.glCreateShader(GL_VERTEX_SHADER);
        const GLuint fragment = gl.glCreateShader(GL_FRAGMENT_SHADER);
        expectCondition(vertex != 0 && fragment != 0, "shader creation returns non-zero handles");
        expectCondition(gl.glIsShader(vertex) == GL_TRUE, "vertex shader handle is live");
        expectCondition(gl.glIsShader(fragment) == GL_TRUE, "fragment shader handle is live");

        const char* vertexSource =
            "#version 330 core\n"
            "layout(location = 0) in vec3 aPosition;\n"
            "in vec2 aTexCoord;\n"
            "uniform mat4 uMVP;\n"
            "uniform mat3 uNormalMatrix;\n"
            "uniform mat2 uTexMatrix;\n"
            "uniform float uTime;\n"
            "uniform vec2 uOffset2;\n"
            "uniform vec3 uOffset3;\n"
            "uniform int uScalarI;\n"
            "uniform ivec2 uVec2I;\n"
            "uniform ivec3 uVec3I;\n"
            "uniform ivec4 uVec4I;\n"
            "uniform uint uScalarU;\n"
            "uniform uvec2 uVec2U;\n"
            "uniform uvec3 uVec3U;\n"
            "uniform uvec4 uVec4U;\n"
            "out vec2 vTexCoord;\n"
            "void main() {\n"
            "    vec3 scaled = uNormalMatrix * (aPosition * uTime + uOffset3);\n"
            "    gl_Position = uMVP * vec4(scaled, 1.0);\n"
            "    vec2 tex = uTexMatrix * aTexCoord + uOffset2;\n"
            "    int iFold = uScalarI + uVec2I.x + uVec3I.y + uVec4I.z;\n"
            "    uint uFold = uScalarU + uVec2U.x + uVec3U.y + uVec4U.z;\n"
            "    vTexCoord = tex + vec2(float(iFold) + float(uFold)) * 0.0;\n"
            "}\n";
        const char* fragmentSource =
            "#version 330 core\n"
            "in vec2 vTexCoord;\n"
            "uniform vec4 uColor;\n"
            "uniform sampler2D uTexture;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    fragColor = uColor * texture(uTexture, vTexCoord);\n"
            "}\n";

        gl.glShaderSource(vertex, 1, &vertexSource, nullptr);
        gl.glShaderSource(fragment, 1, &fragmentSource, nullptr);

        GLint sourceLength = 0;
        gl.glGetShaderiv(vertex, GL_SHADER_SOURCE_LENGTH, &sourceLength);
        expectCondition(sourceLength > 0, "vertex shader source length is queryable");

        std::string sourceReadback(static_cast<std::size_t>(sourceLength), '\0');
        GLsizei sourceWritten = 0;
        gl.glGetShaderSource(vertex, sourceLength, &sourceWritten, sourceReadback.data());
        expectCondition(sourceReadback.find("aPosition") != std::string::npos, "stored shader source is recoverable");

        gl.glCompileShader(vertex);
        gl.glCompileShader(fragment);

        GLint vertexCompileStatus = 0;
        GLint fragmentCompileStatus = 0;
        gl.glGetShaderiv(vertex, GL_COMPILE_STATUS, &vertexCompileStatus);
        gl.glGetShaderiv(fragment, GL_COMPILE_STATUS, &fragmentCompileStatus);
        expectCondition(vertexCompileStatus == GL_TRUE, "vertex shader compiles");
        expectCondition(fragmentCompileStatus == GL_TRUE, "fragment shader compiles");

        GLint vertexLogLength = 0;
        gl.glGetShaderiv(vertex, GL_INFO_LOG_LENGTH, &vertexLogLength);
        std::string vertexLog(static_cast<std::size_t>(vertexLogLength == 0 ? 1 : vertexLogLength), '\0');
        GLsizei vertexLogWritten = 0;
        gl.glGetShaderInfoLog(vertex, static_cast<GLsizei>(vertexLog.size()), &vertexLogWritten, vertexLog.data());
        expectCondition(vertexLogWritten >= 0, "vertex shader info log is queryable");

        const GLuint program = gl.glCreateProgram();
        expectCondition(program != 0, "program creation returns non-zero handle");
        expectCondition(gl.glIsProgram(program) == GL_TRUE, "program handle is live");

        gl.glAttachShader(program, vertex);
        gl.glAttachShader(program, fragment);

        GLint attachedCount = 0;
        gl.glGetProgramiv(program, GL_ATTACHED_SHADERS, &attachedCount);
        expectCondition(attachedCount == 2, "program attached shader count");

        GLuint attached[2] = {0, 0};
        GLsizei attachedWritten = 0;
        gl.glGetAttachedShaders(program, 2, &attachedWritten, attached);
        expectCondition(attachedWritten == 2, "program attached shader list size");
        expectCondition((attached[0] == vertex || attached[1] == vertex)
                        && (attached[0] == fragment || attached[1] == fragment),
                        "program attached shader contents");

        gl.glBindAttribLocation(program, 5, "aTexCoord");
        gl.glLinkProgram(program);

        GLint linkStatus = 0;
        gl.glGetProgramiv(program, GL_LINK_STATUS, &linkStatus);
        expectCondition(linkStatus == GL_TRUE, "program links");

        GLint activeUniforms = 0;
        gl.glGetProgramiv(program, GL_ACTIVE_UNIFORMS, &activeUniforms);
        expectCondition(activeUniforms >= 4, "program active uniform count covers declarations");

        GLint activeAttributes = 0;
        gl.glGetProgramiv(program, GL_ACTIVE_ATTRIBUTES, &activeAttributes);
        expectCondition(activeAttributes >= 2, "program active attribute count covers declarations");

        const GLint mvpLocation = gl.glGetUniformLocation(program, "uMVP");
        const GLint colorLocation = gl.glGetUniformLocation(program, "uColor");
        const GLint timeLocation = gl.glGetUniformLocation(program, "uTime");
        const GLint textureLocation = gl.glGetUniformLocation(program, "uTexture");
        expectCondition(mvpLocation >= 0, "uMVP location is resolvable");
        expectCondition(colorLocation >= 0, "uColor location is resolvable");
        expectCondition(timeLocation >= 0, "uTime location is resolvable");
        expectCondition(textureLocation >= 0, "uTexture location is resolvable");
        expectCondition(gl.glGetUniformLocation(program, "uMissing") == -1, "missing uniform reports -1");

        const GLint posAttribLocation = gl.glGetAttribLocation(program, "aPosition");
        const GLint texAttribLocation = gl.glGetAttribLocation(program, "aTexCoord");
        expectCondition(posAttribLocation == 0, "aPosition honors layout location");
        expectCondition(texAttribLocation == 5, "aTexCoord honors bindAttribLocation override");

        char nameBuffer[64] = {};
        GLsizei nameLength = 0;
        GLint uniformSize = 0;
        GLenum uniformType = 0;
        gl.glGetActiveUniform(program, 0, sizeof(nameBuffer), &nameLength, &uniformSize, &uniformType, nameBuffer);
        expectCondition(nameLength > 0, "active uniform query writes a name");
        expectCondition(uniformSize >= 1, "active uniform size is at least one");

        GLsizei attribNameLength = 0;
        GLint attribSize = 0;
        GLenum attribType = 0;
        char attribNameBuffer[64] = {};
        gl.glGetActiveAttrib(program, 0, sizeof(attribNameBuffer), &attribNameLength, &attribSize, &attribType, attribNameBuffer);
        expectCondition(attribNameLength > 0, "active attribute query writes a name");

        gl.glUseProgram(program);

        gl.glUniform1f(timeLocation, 1.5f);
        const GLfloat colorValue[4] = {0.25f, 0.5f, 0.75f, 1.0f};
        gl.glUniform4fv(colorLocation, 1, colorValue);
        const GLfloat mvpIdentity[16] = {
            1.0f, 0.0f, 0.0f, 0.0f,
            0.0f, 1.0f, 0.0f, 0.0f,
            0.0f, 0.0f, 1.0f, 0.0f,
            0.0f, 0.0f, 0.0f, 1.0f,
        };
        gl.glUniformMatrix4fv(mvpLocation, 1, GL_FALSE, mvpIdentity);
        gl.glUniform1i(textureLocation, 2);

        // Pass 2 scenario promotion. Exercise the full uniform setter family
        // against the reflected uniforms below so every arity lands at
        // `ScenarioTested` state for the Phase 3 stricter gate.
        const GLint offset2Loc = gl.glGetUniformLocation(program, "uOffset2");
        const GLint offset3Loc = gl.glGetUniformLocation(program, "uOffset3");
        const GLint scalarILoc = gl.glGetUniformLocation(program, "uScalarI");
        const GLint vec2ILoc = gl.glGetUniformLocation(program, "uVec2I");
        const GLint vec3ILoc = gl.glGetUniformLocation(program, "uVec3I");
        const GLint vec4ILoc = gl.glGetUniformLocation(program, "uVec4I");
        const GLint scalarULoc = gl.glGetUniformLocation(program, "uScalarU");
        const GLint vec2ULoc = gl.glGetUniformLocation(program, "uVec2U");
        const GLint vec3ULoc = gl.glGetUniformLocation(program, "uVec3U");
        const GLint vec4ULoc = gl.glGetUniformLocation(program, "uVec4U");
        const GLint normalMatLoc = gl.glGetUniformLocation(program, "uNormalMatrix");
        const GLint texMatLoc = gl.glGetUniformLocation(program, "uTexMatrix");

        // Scalar/vector float setters (glUniform{2,3,4}f + {1,2,3}fv).
        gl.glUniform2f(offset2Loc, 0.125f, 0.25f);
        gl.glUniform3f(offset3Loc, 0.1f, 0.2f, 0.3f);
        gl.glUniform4f(colorLocation, 0.25f, 0.5f, 0.75f, 1.0f);
        const GLfloat scalarF = 1.5f;
        gl.glUniform1fv(timeLocation, 1, &scalarF);
        const GLfloat vec2F[2] = {0.125f, 0.25f};
        gl.glUniform2fv(offset2Loc, 1, vec2F);
        const GLfloat vec3F[3] = {0.1f, 0.2f, 0.3f};
        gl.glUniform3fv(offset3Loc, 1, vec3F);

        // Scalar/vector int setters (glUniform{1,2,3,4}i + {1,2,3,4}iv).
        gl.glUniform1i(scalarILoc, 7);
        gl.glUniform2i(vec2ILoc, 1, 2);
        gl.glUniform3i(vec3ILoc, 3, 4, 5);
        gl.glUniform4i(vec4ILoc, 6, 7, 8, 9);
        const GLint scalarI[1] = {11};
        gl.glUniform1iv(scalarILoc, 1, scalarI);
        const GLint vec2I[2] = {1, 2};
        gl.glUniform2iv(vec2ILoc, 1, vec2I);
        const GLint vec3I[3] = {3, 4, 5};
        gl.glUniform3iv(vec3ILoc, 1, vec3I);
        const GLint vec4I[4] = {6, 7, 8, 9};
        gl.glUniform4iv(vec4ILoc, 1, vec4I);

        // Scalar/vector uint setters (glUniform{1,2,3,4}ui + {1,2,3,4}uiv).
        gl.glUniform1ui(scalarULoc, 11u);
        gl.glUniform2ui(vec2ULoc, 12u, 13u);
        gl.glUniform3ui(vec3ULoc, 14u, 15u, 16u);
        gl.glUniform4ui(vec4ULoc, 17u, 18u, 19u, 20u);
        const GLuint scalarU[1] = {21u};
        gl.glUniform1uiv(scalarULoc, 1, scalarU);
        const GLuint vec2U[2] = {12u, 13u};
        gl.glUniform2uiv(vec2ULoc, 1, vec2U);
        const GLuint vec3U[3] = {14u, 15u, 16u};
        gl.glUniform3uiv(vec3ULoc, 1, vec3U);
        const GLuint vec4U[4] = {17u, 18u, 19u, 20u};
        gl.glUniform4uiv(vec4ULoc, 1, vec4U);

        // Square matrix setters (glUniformMatrix{2,3}fv — Matrix4fv is above).
        const GLfloat mat2Data[4] = {1.0f, 0.0f, 0.0f, 1.0f};
        gl.glUniformMatrix2fv(texMatLoc, 1, GL_FALSE, mat2Data);
        const GLfloat mat3Data[9] = {
            1.0f, 0.0f, 0.0f,
            0.0f, 1.0f, 0.0f,
            0.0f, 0.0f, 1.0f,
        };
        gl.glUniformMatrix3fv(normalMatLoc, 1, GL_FALSE, mat3Data);

        // Rectangular matrix setters land as live Group 8 stubs — invoking them
        // with legal args promotes the entry points to `ScenarioTested` through
        // the dispatch without touching the render output.
        const GLfloat mat2x3Data[6] = {1, 0, 0, 0, 1, 0};
        const GLfloat mat3x2Data[6] = {1, 0, 0, 1, 0, 0};
        const GLfloat mat2x4Data[8] = {1, 0, 0, 0, 0, 1, 0, 0};
        const GLfloat mat4x2Data[8] = {1, 0, 0, 1, 0, 0, 0, 0};
        const GLfloat mat3x4Data[12] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0};
        const GLfloat mat4x3Data[12] = {1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0};
        gl.glUniformMatrix2x3fv(normalMatLoc, 1, GL_FALSE, mat2x3Data);
        gl.glUniformMatrix3x2fv(texMatLoc, 1, GL_FALSE, mat3x2Data);
        gl.glUniformMatrix2x4fv(normalMatLoc, 1, GL_FALSE, mat2x4Data);
        gl.glUniformMatrix4x2fv(texMatLoc, 1, GL_FALSE, mat4x2Data);
        gl.glUniformMatrix3x4fv(mvpLocation, 1, GL_FALSE, mat3x4Data);
        gl.glUniformMatrix4x3fv(mvpLocation, 1, GL_FALSE, mat4x3Data);

        // Uniform-block reflection stubs. Group 8 no-ops accept any legal
        // call shape; we still pass real pointers so dispatch routes cleanly.
        const char* blockNames[1] = {"UnusedBlock"};
        GLuint blockIndices[1] = {GL_INVALID_INDEX};
        gl.glGetUniformIndices(program, 1, blockNames, blockIndices);
        GLint blockProps[1] = {0};
        gl.glGetActiveUniformsiv(program, 1, blockIndices, GL_UNIFORM_TYPE, blockProps);
        char activeUniformName[64] = {};
        GLsizei activeUniformNameLen = 0;
        gl.glGetActiveUniformName(program, 0, sizeof(activeUniformName), &activeUniformNameLen, activeUniformName);
        const GLuint blockIndex = gl.glGetUniformBlockIndex(program, "UnusedBlock");
        GLint blockPropValue = 0;
        gl.glGetActiveUniformBlockiv(program, 0, GL_UNIFORM_BLOCK_DATA_SIZE, &blockPropValue);
        char blockNameBuffer[64] = {};
        GLsizei blockNameLength = 0;
        gl.glGetActiveUniformBlockName(program, 0, sizeof(blockNameBuffer), &blockNameLength, blockNameBuffer);
        gl.glUniformBlockBinding(program, blockIndex == GL_INVALID_INDEX ? 0u : blockIndex, 0);

        // Fragment-data location stubs. The fragment shader only declares a
        // single output, but the dispatch entries still accept the query/bind.
        gl.glBindFragDataLocation(program, 0, "fragColor");
        gl.glBindFragDataLocationIndexed(program, 0, 0, "fragColor");
        (void)gl.glGetFragDataLocation(program, "fragColor");
        (void)gl.glGetFragDataIndex(program, "fragColor");

        // glGetUniformuiv round-trip for the uint uniform family.
        GLuint uintReadback[4] = {};
        gl.glGetUniformuiv(program, vec4ULoc, uintReadback);

        GLfloat timeReadback = 0.0f;
        gl.glGetUniformfv(program, timeLocation, &timeReadback);
        expectCondition(timeReadback == 1.5f, "uTime readback matches");

        GLfloat colorReadback[4] = {};
        gl.glGetUniformfv(program, colorLocation, colorReadback);
        expectCondition(colorReadback[0] == 0.25f && colorReadback[3] == 1.0f, "uColor readback matches");

        GLfloat mvpReadback[16] = {};
        gl.glGetUniformfv(program, mvpLocation, mvpReadback);
        expectCondition(mvpReadback[0] == 1.0f && mvpReadback[5] == 1.0f && mvpReadback[10] == 1.0f && mvpReadback[15] == 1.0f, "uMVP readback matches");

        GLint textureReadback = 0;
        gl.glGetUniformiv(program, textureLocation, &textureReadback);
        expectCondition(textureReadback == 2, "uTexture sampler readback matches");

        gl.glValidateProgram(program);
        GLint validateStatus = 0;
        gl.glGetProgramiv(program, GL_VALIDATE_STATUS, &validateStatus);
        expectCondition(validateStatus == GL_TRUE, "program validates");

        GLint programLogLength = 0;
        gl.glGetProgramiv(program, GL_INFO_LOG_LENGTH, &programLogLength);
        std::string programLog(static_cast<std::size_t>(programLogLength == 0 ? 1 : programLogLength), '\0');
        GLsizei programLogWritten = 0;
        gl.glGetProgramInfoLog(program, static_cast<GLsizei>(programLog.size()), &programLogWritten, programLog.data());
        expectCondition(programLogWritten >= 0, "program info log is queryable");

        // Phase 4 Group 2: double-precision uniform setters (f64→f32 narrowing).
        // Placed after float readback assertions so the double overwrites don't
        // invalidate the float round-trip checks above.
        gl.glUniform1d(timeLocation, 2.718281828459045);
        gl.glUniform2d(offset2Loc, 3.14159265358979, 1.41421356237310);
        gl.glUniform3d(offset3Loc, 0.577215664901532, 1.61803398874989, 2.23606797749979);
        gl.glUniform4d(colorLocation, 0.125, 0.250, 0.375, 0.500);
        const GLdouble d1v[1] = {1.23456789012345};
        gl.glUniform1dv(timeLocation, 1, d1v);
        const GLdouble d2v[2] = {0.1, 0.2};
        gl.glUniform2dv(offset2Loc, 1, d2v);
        const GLdouble d3v[3] = {0.3, 0.4, 0.5};
        gl.glUniform3dv(offset3Loc, 1, d3v);
        const GLdouble d4v[4] = {0.6, 0.7, 0.8, 0.9};
        gl.glUniform4dv(colorLocation, 1, d4v);
        const GLdouble dmat2[4] = {1.0, 0.0, 0.0, 1.0};
        gl.glUniformMatrix2dv(texMatLoc, 1, GL_FALSE, dmat2);
        const GLdouble dmat3[9] = {1,0,0, 0,1,0, 0,0,1};
        gl.glUniformMatrix3dv(normalMatLoc, 1, GL_FALSE, dmat3);
        const GLdouble dmat4[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        gl.glUniformMatrix4dv(mvpLocation, 1, GL_FALSE, dmat4);
        const GLdouble dmat2x3[6] = {1,0,0, 0,1,0};
        gl.glUniformMatrix2x3dv(normalMatLoc, 1, GL_FALSE, dmat2x3);
        const GLdouble dmat2x4[8] = {1,0,0,0, 0,1,0,0};
        gl.glUniformMatrix2x4dv(normalMatLoc, 1, GL_FALSE, dmat2x4);
        const GLdouble dmat3x2[6] = {1,0, 0,1, 0,0};
        gl.glUniformMatrix3x2dv(texMatLoc, 1, GL_FALSE, dmat3x2);
        const GLdouble dmat3x4[12] = {1,0,0,0, 0,1,0,0, 0,0,1,0};
        gl.glUniformMatrix3x4dv(mvpLocation, 1, GL_FALSE, dmat3x4);
        const GLdouble dmat4x2[8] = {1,0, 0,1, 0,0, 0,0};
        gl.glUniformMatrix4x2dv(texMatLoc, 1, GL_FALSE, dmat4x2);
        const GLdouble dmat4x3[12] = {1,0,0, 0,1,0, 0,0,1, 0,0,0};
        gl.glUniformMatrix4x3dv(mvpLocation, 1, GL_FALSE, dmat4x3);

        // glGetUniformdv lossless round-trip from the CPU shadow.
        GLdouble dReadback[4] = {};
        gl.glGetUniformdv(program, colorLocation, dReadback);
        expectCondition(dReadback[0] == 0.6 && dReadback[3] == 0.9, "double uniform readback from shadow matches");

        // Phase 4 Group 10: glProgramUniform* family (explicit program handle).
        // Exercise all 50 arities using the already-linked program + existing locations.
        gl.glProgramUniform1f(program, timeLocation, 1.0f);
        const GLfloat pf1[1] = {1.0f}; gl.glProgramUniform1fv(program, timeLocation, 1, pf1);
        gl.glProgramUniform2f(program, colorLocation, 0.5f, 0.5f);
        const GLfloat pf2[2] = {0.5f, 0.5f}; gl.glProgramUniform2fv(program, colorLocation, 1, pf2);
        gl.glProgramUniform3f(program, colorLocation, 0.5f, 0.5f, 0.5f);
        const GLfloat pf3[3] = {0.5f, 0.5f, 0.5f}; gl.glProgramUniform3fv(program, colorLocation, 1, pf3);
        gl.glProgramUniform4f(program, colorLocation, 0.5f, 0.5f, 0.5f, 1.0f);
        const GLfloat pf4[4] = {0.5f, 0.5f, 0.5f, 1.0f}; gl.glProgramUniform4fv(program, colorLocation, 1, pf4);
        gl.glProgramUniform1i(program, timeLocation, 1);
        const GLint pi1[1] = {1}; gl.glProgramUniform1iv(program, timeLocation, 1, pi1);
        gl.glProgramUniform2i(program, colorLocation, 1, 2);
        const GLint pi2[2] = {1, 2}; gl.glProgramUniform2iv(program, colorLocation, 1, pi2);
        gl.glProgramUniform3i(program, colorLocation, 1, 2, 3);
        const GLint pi3[3] = {1, 2, 3}; gl.glProgramUniform3iv(program, colorLocation, 1, pi3);
        gl.glProgramUniform4i(program, colorLocation, 1, 2, 3, 4);
        const GLint pi4[4] = {1, 2, 3, 4}; gl.glProgramUniform4iv(program, colorLocation, 1, pi4);
        gl.glProgramUniform1ui(program, timeLocation, 1u);
        const GLuint pu1[1] = {1u}; gl.glProgramUniform1uiv(program, timeLocation, 1, pu1);
        gl.glProgramUniform2ui(program, colorLocation, 1u, 2u);
        const GLuint pu2[2] = {1u, 2u}; gl.glProgramUniform2uiv(program, colorLocation, 1, pu2);
        gl.glProgramUniform3ui(program, colorLocation, 1u, 2u, 3u);
        const GLuint pu3[3] = {1u, 2u, 3u}; gl.glProgramUniform3uiv(program, colorLocation, 1, pu3);
        gl.glProgramUniform4ui(program, colorLocation, 1u, 2u, 3u, 4u);
        const GLuint pu4[4] = {1u, 2u, 3u, 4u}; gl.glProgramUniform4uiv(program, colorLocation, 1, pu4);
        gl.glProgramUniform1d(program, timeLocation, 1.0);
        const GLdouble pd1[1] = {1.0}; gl.glProgramUniform1dv(program, timeLocation, 1, pd1);
        gl.glProgramUniform2d(program, colorLocation, 1.0, 2.0);
        const GLdouble pd2[2] = {1.0, 2.0}; gl.glProgramUniform2dv(program, colorLocation, 1, pd2);
        gl.glProgramUniform3d(program, colorLocation, 1.0, 2.0, 3.0);
        const GLdouble pd3[3] = {1.0, 2.0, 3.0}; gl.glProgramUniform3dv(program, colorLocation, 1, pd3);
        gl.glProgramUniform4d(program, colorLocation, 1.0, 2.0, 3.0, 4.0);
        const GLdouble pd4[4] = {1.0, 2.0, 3.0, 4.0}; gl.glProgramUniform4dv(program, colorLocation, 1, pd4);
        // Float matrices.
        const GLfloat pm2[4] = {1,0,0,1}; gl.glProgramUniformMatrix2fv(program, timeLocation, 1, GL_FALSE, pm2);
        const GLfloat pm3[9] = {1,0,0,0,1,0,0,0,1}; gl.glProgramUniformMatrix3fv(program, timeLocation, 1, GL_FALSE, pm3);
        const GLfloat pm4[16] = {1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}; gl.glProgramUniformMatrix4fv(program, timeLocation, 1, GL_FALSE, pm4);
        const GLfloat pm2x3[6] = {1,0,0,0,1,0}; gl.glProgramUniformMatrix2x3fv(program, timeLocation, 1, GL_FALSE, pm2x3);
        const GLfloat pm3x2[6] = {1,0,0,1,0,0}; gl.glProgramUniformMatrix3x2fv(program, timeLocation, 1, GL_FALSE, pm3x2);
        const GLfloat pm2x4[8] = {1,0,0,0,0,1,0,0}; gl.glProgramUniformMatrix2x4fv(program, timeLocation, 1, GL_FALSE, pm2x4);
        const GLfloat pm4x2[8] = {1,0,0,1,0,0,0,0}; gl.glProgramUniformMatrix4x2fv(program, timeLocation, 1, GL_FALSE, pm4x2);
        const GLfloat pm3x4[12] = {1,0,0,0,0,1,0,0,0,0,1,0}; gl.glProgramUniformMatrix3x4fv(program, timeLocation, 1, GL_FALSE, pm3x4);
        const GLfloat pm4x3[12] = {1,0,0,0,1,0,0,0,1,0,0,0}; gl.glProgramUniformMatrix4x3fv(program, timeLocation, 1, GL_FALSE, pm4x3);
        // Double matrices.
        const GLdouble pdm2[4] = {1,0,0,1}; gl.glProgramUniformMatrix2dv(program, timeLocation, 1, GL_FALSE, pdm2);
        const GLdouble pdm3[9] = {1,0,0,0,1,0,0,0,1}; gl.glProgramUniformMatrix3dv(program, timeLocation, 1, GL_FALSE, pdm3);
        const GLdouble pdm4[16] = {1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}; gl.glProgramUniformMatrix4dv(program, timeLocation, 1, GL_FALSE, pdm4);
        const GLdouble pdm2x3[6] = {1,0,0,0,1,0}; gl.glProgramUniformMatrix2x3dv(program, timeLocation, 1, GL_FALSE, pdm2x3);
        const GLdouble pdm3x2[6] = {1,0,0,1,0,0}; gl.glProgramUniformMatrix3x2dv(program, timeLocation, 1, GL_FALSE, pdm3x2);
        const GLdouble pdm2x4[8] = {1,0,0,0,0,1,0,0}; gl.glProgramUniformMatrix2x4dv(program, timeLocation, 1, GL_FALSE, pdm2x4);
        const GLdouble pdm4x2[8] = {1,0,0,1,0,0,0,0}; gl.glProgramUniformMatrix4x2dv(program, timeLocation, 1, GL_FALSE, pdm4x2);
        const GLdouble pdm3x4[12] = {1,0,0,0,0,1,0,0,0,0,1,0}; gl.glProgramUniformMatrix3x4dv(program, timeLocation, 1, GL_FALSE, pdm3x4);
        const GLdouble pdm4x3[12] = {1,0,0,0,1,0,0,0,1,0,0,0}; gl.glProgramUniformMatrix4x3dv(program, timeLocation, 1, GL_FALSE, pdm4x3);
        expectGLError(gl, GL_NO_ERROR, "all 50 ProgramUniform arities accept legal args");

        // Phase 4 Group 11: program/shader binary stubs.
        gl.glProgramParameteri(program, GL_PROGRAM_BINARY_RETRIEVABLE_HINT, GL_TRUE);
        expectGLError(gl, GL_NO_ERROR, "glProgramParameteri accepts retrievable hint");
        gl.glReleaseShaderCompiler();
        expectGLError(gl, GL_NO_ERROR, "glReleaseShaderCompiler is a no-op hint");
        // glGetProgramBinary and glProgramBinary report errors (0 formats) — drain.
        GLsizei binLength = 0; GLenum binFormat = 0;
        gl.glGetProgramBinary(program, 0, &binLength, &binFormat, nullptr);
        while (gl.glGetError() != GL_NO_ERROR) {}
        gl.glProgramBinary(program, 0, nullptr, 0);
        while (gl.glGetError() != GL_NO_ERROR) {}
        gl.glShaderBinary(0, nullptr, 0, nullptr, 0);
        while (gl.glGetError() != GL_NO_ERROR) {}

        // Phase 4 Group 9: Program Pipeline Objects.
        {
            GLuint ppo[2] = {0, 0};
            gl.glGenProgramPipelines(2, ppo);
            expectCondition(ppo[0] != 0 && ppo[1] != 0, "glGenProgramPipelines returns non-zero handles");
            expectGLError(gl, GL_NO_ERROR, "glGenProgramPipelines no error");
            expectCondition(gl.glIsProgramPipeline(ppo[0]) == GL_TRUE, "pipeline exists after gen");
            expectCondition(gl.glIsProgramPipeline(99999) == GL_FALSE, "non-existent pipeline returns GL_FALSE");

            gl.glBindProgramPipeline(ppo[0]);
            expectGLError(gl, GL_NO_ERROR, "glBindProgramPipeline no error");
            gl.glBindProgramPipeline(0);
            expectGLError(gl, GL_NO_ERROR, "glBindProgramPipeline(0) unbind no error");

            gl.glUseProgramStages(ppo[0], GL_VERTEX_SHADER_BIT | GL_FRAGMENT_SHADER_BIT, program);
            expectGLError(gl, GL_NO_ERROR, "glUseProgramStages no error");
            GLint vertStage = 0;
            gl.glGetProgramPipelineiv(ppo[0], GL_VERTEX_SHADER, &vertStage);
            expectCondition(vertStage == static_cast<GLint>(program), "vertex stage bound to program");
            GLint fragStage = 0;
            gl.glGetProgramPipelineiv(ppo[0], GL_FRAGMENT_SHADER, &fragStage);
            expectCondition(fragStage == static_cast<GLint>(program), "fragment stage bound to program");

            gl.glActiveShaderProgram(ppo[0], program);
            expectGLError(gl, GL_NO_ERROR, "glActiveShaderProgram no error");
            GLint activeProg = 0;
            gl.glGetProgramPipelineiv(ppo[0], GL_ACTIVE_PROGRAM, &activeProg);
            expectCondition(activeProg == static_cast<GLint>(program), "active shader program matches");

            gl.glValidateProgramPipeline(ppo[0]);
            expectGLError(gl, GL_NO_ERROR, "glValidateProgramPipeline no error");
            GLint validateStatus = 0;
            gl.glGetProgramPipelineiv(ppo[0], GL_VALIDATE_STATUS, &validateStatus);
            expectCondition(validateStatus == GL_TRUE, "pipeline validates successfully");

            GLint logLen = 0;
            gl.glGetProgramPipelineiv(ppo[0], GL_INFO_LOG_LENGTH, &logLen);
            expectCondition(logLen > 0, "pipeline info log length > 0 after validation");
            char logBuf[256] = {};
            GLsizei written = 0;
            gl.glGetProgramPipelineInfoLog(ppo[0], sizeof(logBuf), &written, logBuf);
            expectCondition(written > 0, "pipeline info log written > 0");

            // glCreateShaderProgramv convenience.
            const char* trivialVS =
                "#version 330 core\n"
                "void main() { gl_Position = vec4(0.0); }\n";
            GLuint sepProg = gl.glCreateShaderProgramv(GL_VERTEX_SHADER, 1, &trivialVS);
            expectCondition(sepProg != 0, "glCreateShaderProgramv returns non-zero");
            expectCondition(gl.glIsProgram(sepProg) == GL_TRUE, "separable program is valid");
            gl.glDeleteProgram(sepProg);
            while (gl.glGetError() != GL_NO_ERROR) {}

            gl.glDeleteProgramPipelines(2, ppo);
            expectGLError(gl, GL_NO_ERROR, "glDeleteProgramPipelines no error");
            expectCondition(gl.glIsProgramPipeline(ppo[0]) == GL_FALSE, "pipeline gone after delete");
        }

        // Phase 4 Group 3: Subroutine Uniforms (stub-with-state).
        {
            GLint subLoc = gl.glGetSubroutineUniformLocation(program, GL_VERTEX_SHADER, "nonExistent");
            expectCondition(subLoc == -1, "subroutine uniform location returns -1 (no subroutines)");
            GLuint subIdx = gl.glGetSubroutineIndex(program, GL_VERTEX_SHADER, "nonExistent");
            expectCondition(subIdx == GL_INVALID_INDEX, "subroutine index returns GL_INVALID_INDEX");

            GLint numCompat = -1;
            gl.glGetActiveSubroutineUniformiv(program, GL_VERTEX_SHADER, 0, GL_NUM_COMPATIBLE_SUBROUTINES, &numCompat);
            expectCondition(numCompat == 0, "active subroutine uniform compatible count is 0");

            // glGetActiveSubroutineUniformName and glGetActiveSubroutineName report GL_INVALID_VALUE.
            char subName[64] = {};
            GLsizei subNameLen = 0;
            gl.glGetActiveSubroutineUniformName(program, GL_VERTEX_SHADER, 0, sizeof(subName), &subNameLen, subName);
            while (gl.glGetError() != GL_NO_ERROR) {}
            gl.glGetActiveSubroutineName(program, GL_VERTEX_SHADER, 0, sizeof(subName), &subNameLen, subName);
            while (gl.glGetError() != GL_NO_ERROR) {}

            GLuint subIndices[1] = {0};
            gl.glUniformSubroutinesuiv(GL_VERTEX_SHADER, 0, subIndices);
            expectGLError(gl, GL_NO_ERROR, "glUniformSubroutinesuiv (count=0) no error");
            GLuint readbackSub = 99;
            gl.glGetUniformSubroutineuiv(GL_VERTEX_SHADER, 0, &readbackSub);
            expectCondition(readbackSub == 0, "GetUniformSubroutineuiv returns 0");

            GLint activeSubroutines = -1;
            gl.glGetProgramStageiv(program, GL_VERTEX_SHADER, GL_ACTIVE_SUBROUTINES, &activeSubroutines);
            expectCondition(activeSubroutines == 0, "GetProgramStageiv reports 0 active subroutines");
            GLint activeSubUniforms = -1;
            gl.glGetProgramStageiv(program, GL_VERTEX_SHADER, GL_ACTIVE_SUBROUTINE_UNIFORMS, &activeSubUniforms);
            expectCondition(activeSubUniforms == 0, "GetProgramStageiv reports 0 active subroutine uniforms");
        }

        gl.glDetachShader(program, vertex);
        GLint attachedAfterDetach = 0;
        gl.glGetProgramiv(program, GL_ATTACHED_SHADERS, &attachedAfterDetach);
        expectCondition(attachedAfterDetach == 1, "program attached shader count after detach");

        gl.glUseProgram(0);
        gl.glDeleteProgram(program);
        gl.glDeleteShader(vertex);
        gl.glDeleteShader(fragment);
        expectCondition(gl.glIsProgram(program) == GL_FALSE, "deleted program handle is no longer live");
        expectCondition(gl.glIsShader(vertex) == GL_FALSE, "deleted shader handle is no longer live");
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glClearColor(0.18f, 0.22f, 0.36f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glAttachShader,
            FunctionId::glBindAttribLocation,
            FunctionId::glBindFragDataLocation,
            FunctionId::glBindFragDataLocationIndexed,
            FunctionId::glCompileShader,
            FunctionId::glCreateProgram,
            FunctionId::glCreateShader,
            FunctionId::glDeleteProgram,
            FunctionId::glDeleteShader,
            FunctionId::glDetachShader,
            FunctionId::glGetActiveAttrib,
            FunctionId::glGetActiveUniform,
            FunctionId::glGetActiveUniformBlockiv,
            FunctionId::glGetActiveUniformBlockName,
            FunctionId::glGetActiveUniformName,
            FunctionId::glGetActiveUniformsiv,
            FunctionId::glGetAttachedShaders,
            FunctionId::glGetAttribLocation,
            FunctionId::glGetFragDataIndex,
            FunctionId::glGetFragDataLocation,
            FunctionId::glGetProgramInfoLog,
            FunctionId::glGetProgramiv,
            FunctionId::glGetShaderInfoLog,
            FunctionId::glGetShaderSource,
            FunctionId::glGetShaderiv,
            FunctionId::glGetUniformBlockIndex,
            FunctionId::glGetUniformIndices,
            FunctionId::glGetUniformLocation,
            FunctionId::glGetUniformdv,
            FunctionId::glGetUniformfv,
            FunctionId::glGetUniformiv,
            FunctionId::glGetUniformuiv,
            FunctionId::glIsProgram,
            FunctionId::glIsShader,
            FunctionId::glLinkProgram,
            FunctionId::glShaderSource,
            FunctionId::glUniform1d,
            FunctionId::glUniform1dv,
            FunctionId::glUniform1f,
            FunctionId::glUniform1fv,
            FunctionId::glUniform1i,
            FunctionId::glUniform1iv,
            FunctionId::glUniform1ui,
            FunctionId::glUniform1uiv,
            FunctionId::glUniform2d,
            FunctionId::glUniform2dv,
            FunctionId::glUniform2f,
            FunctionId::glUniform2fv,
            FunctionId::glUniform2i,
            FunctionId::glUniform2iv,
            FunctionId::glUniform2ui,
            FunctionId::glUniform2uiv,
            FunctionId::glUniform3d,
            FunctionId::glUniform3dv,
            FunctionId::glUniform3f,
            FunctionId::glUniform3fv,
            FunctionId::glUniform3i,
            FunctionId::glUniform3iv,
            FunctionId::glUniform3ui,
            FunctionId::glUniform3uiv,
            FunctionId::glUniform4d,
            FunctionId::glUniform4dv,
            FunctionId::glUniform4f,
            FunctionId::glUniform4fv,
            FunctionId::glUniform4i,
            FunctionId::glUniform4iv,
            FunctionId::glUniform4ui,
            FunctionId::glUniform4uiv,
            FunctionId::glUniformBlockBinding,
            FunctionId::glUniformMatrix2dv,
            FunctionId::glUniformMatrix2fv,
            FunctionId::glUniformMatrix2x3dv,
            FunctionId::glUniformMatrix2x3fv,
            FunctionId::glUniformMatrix2x4dv,
            FunctionId::glUniformMatrix2x4fv,
            FunctionId::glUniformMatrix3dv,
            FunctionId::glUniformMatrix3fv,
            FunctionId::glUniformMatrix3x2dv,
            FunctionId::glUniformMatrix3x2fv,
            FunctionId::glUniformMatrix3x4dv,
            FunctionId::glUniformMatrix3x4fv,
            FunctionId::glUniformMatrix4dv,
            FunctionId::glUniformMatrix4fv,
            FunctionId::glUniformMatrix4x2dv,
            FunctionId::glUniformMatrix4x2fv,
            FunctionId::glUniformMatrix4x3dv,
            FunctionId::glUniformMatrix4x3fv,
            FunctionId::glUseProgram,
            FunctionId::glValidateProgram,
            // Phase 4 Group 10: glProgramUniform* (50 arities).
            FunctionId::glProgramUniform1f, FunctionId::glProgramUniform1fv,
            FunctionId::glProgramUniform2f, FunctionId::glProgramUniform2fv,
            FunctionId::glProgramUniform3f, FunctionId::glProgramUniform3fv,
            FunctionId::glProgramUniform4f, FunctionId::glProgramUniform4fv,
            FunctionId::glProgramUniform1i, FunctionId::glProgramUniform1iv,
            FunctionId::glProgramUniform2i, FunctionId::glProgramUniform2iv,
            FunctionId::glProgramUniform3i, FunctionId::glProgramUniform3iv,
            FunctionId::glProgramUniform4i, FunctionId::glProgramUniform4iv,
            FunctionId::glProgramUniform1ui, FunctionId::glProgramUniform1uiv,
            FunctionId::glProgramUniform2ui, FunctionId::glProgramUniform2uiv,
            FunctionId::glProgramUniform3ui, FunctionId::glProgramUniform3uiv,
            FunctionId::glProgramUniform4ui, FunctionId::glProgramUniform4uiv,
            FunctionId::glProgramUniform1d, FunctionId::glProgramUniform1dv,
            FunctionId::glProgramUniform2d, FunctionId::glProgramUniform2dv,
            FunctionId::glProgramUniform3d, FunctionId::glProgramUniform3dv,
            FunctionId::glProgramUniform4d, FunctionId::glProgramUniform4dv,
            FunctionId::glProgramUniformMatrix2fv, FunctionId::glProgramUniformMatrix3fv,
            FunctionId::glProgramUniformMatrix4fv,
            FunctionId::glProgramUniformMatrix2x3fv, FunctionId::glProgramUniformMatrix3x2fv,
            FunctionId::glProgramUniformMatrix2x4fv, FunctionId::glProgramUniformMatrix4x2fv,
            FunctionId::glProgramUniformMatrix3x4fv, FunctionId::glProgramUniformMatrix4x3fv,
            FunctionId::glProgramUniformMatrix2dv, FunctionId::glProgramUniformMatrix3dv,
            FunctionId::glProgramUniformMatrix4dv,
            FunctionId::glProgramUniformMatrix2x3dv, FunctionId::glProgramUniformMatrix3x2dv,
            FunctionId::glProgramUniformMatrix2x4dv, FunctionId::glProgramUniformMatrix4x2dv,
            FunctionId::glProgramUniformMatrix3x4dv, FunctionId::glProgramUniformMatrix4x3dv,
            // Phase 4 Group 11: program/shader binary.
            FunctionId::glGetProgramBinary,
            FunctionId::glProgramBinary,
            FunctionId::glProgramParameteri,
            FunctionId::glShaderBinary,
            FunctionId::glReleaseShaderCompiler,
            // Phase 4 Group 9: program pipeline objects.
            FunctionId::glGenProgramPipelines,
            FunctionId::glDeleteProgramPipelines,
            FunctionId::glIsProgramPipeline,
            FunctionId::glBindProgramPipeline,
            FunctionId::glUseProgramStages,
            FunctionId::glActiveShaderProgram,
            FunctionId::glCreateShaderProgramv,
            FunctionId::glValidateProgramPipeline,
            FunctionId::glGetProgramPipelineiv,
            FunctionId::glGetProgramPipelineInfoLog,
            // Phase 4 Group 3: subroutine uniforms (stub).
            FunctionId::glGetSubroutineUniformLocation,
            FunctionId::glGetSubroutineIndex,
            FunctionId::glGetActiveSubroutineUniformiv,
            FunctionId::glGetActiveSubroutineUniformName,
            FunctionId::glGetActiveSubroutineName,
            FunctionId::glUniformSubroutinesuiv,
            FunctionId::glGetUniformSubroutineuiv,
            FunctionId::glGetProgramStageiv,
        };
    }
};

// Phase A Group 7 — drawing MVP. Renders a single solid-color triangle using
// the hand-written MSL pipeline baked into MetalFrameGraph, then captures the
// result via glReadPixels for a golden round-trip. Also exercises the indexed
// draw path so the GL_UNSIGNED_SHORT route is covered. The triangle covers a
// predictable chunk of the framebuffer so small pixel deltas in the golden
// compare highlight regressions in the draw encoder.
class SolidTriangleDrawScene final : public Scene {
public:
    std::string id() const override {
        return "phase-a.solid-triangle-draw";
    }

    std::string phase() const override {
        return "phase-a";
    }

    SceneSize framebufferSize() const override {
        return {96, 96};
    }

    double tolerance() const override {
        // The hand-written MSL pipeline is deterministic, but anti-aliased
        // rasterization edges can still drift by one channel at the triangle
        // border depending on GPU family. Keep the tolerance tight but not
        // zero so the scene stays stable across driver revisions.
        return 0.02;
    }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // Compile a minimal "solid color" program. The runtime's Phase A
        // Group 7 draw path looks for attribute 0 (vec3 position) and a
        // uniform named "uColor", both of which this program provides.
        const char* vertexSource =
            "#version 330 core\n"
            "layout(location = 0) in vec3 aPosition;\n"
            "void main() {\n"
            "    gl_Position = vec4(aPosition, 1.0);\n"
            "}\n";
        const char* fragmentSource =
            "#version 330 core\n"
            "uniform vec4 uColor;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    fragColor = uColor;\n"
            "}\n";

        const GLuint vertex = gl.glCreateShader(GL_VERTEX_SHADER);
        const GLuint fragment = gl.glCreateShader(GL_FRAGMENT_SHADER);
        gl.glShaderSource(vertex, 1, &vertexSource, nullptr);
        gl.glShaderSource(fragment, 1, &fragmentSource, nullptr);
        gl.glCompileShader(vertex);
        gl.glCompileShader(fragment);

        program_ = gl.glCreateProgram();
        gl.glAttachShader(program_, vertex);
        gl.glAttachShader(program_, fragment);
        gl.glLinkProgram(program_);
        GLint linkStatus = 0;
        gl.glGetProgramiv(program_, GL_LINK_STATUS, &linkStatus);
        expectCondition(linkStatus == GL_TRUE, "solid triangle program links");
        gl.glDeleteShader(vertex);
        gl.glDeleteShader(fragment);

        gl.glGenVertexArrays(1, &vao_);
        gl.glBindVertexArray(vao_);

        // Clip-space triangle centered in the viewport.
        const GLfloat positions[9] = {
            -0.6f, -0.5f, 0.0f,
             0.6f, -0.5f, 0.0f,
             0.0f,  0.7f, 0.0f,
        };
        gl.glGenBuffers(1, &vbo_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(positions), positions, GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * sizeof(GLfloat), nullptr);

        // Index buffer for the glDrawElements path.
        const GLushort indices[3] = {0, 1, 2};
        gl.glGenBuffers(1, &ibo_);
        gl.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo_);
        gl.glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);

        gl.glUseProgram(program_);
        const GLint colorLocation = gl.glGetUniformLocation(program_, "uColor");
        expectCondition(colorLocation >= 0, "uColor is resolvable on solid triangle program");
        const GLfloat triangleColor[4] = {0.95f, 0.45f, 0.20f, 1.0f};
        gl.glUniform4fv(colorLocation, 1, triangleColor);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        gl.glViewport(0, 0, framebufferSize().width, framebufferSize().height);
        gl.glClearColor(0.08f, 0.10f, 0.18f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        gl.glUseProgram(program_);
        gl.glBindVertexArray(vao_);

        // Exercise both draw paths: drawArrays first, then drawElements.
        // Both should paint the same triangle, so the final framebuffer
        // matches the single-triangle golden.
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        gl.glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_SHORT, nullptr);

        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glAttachShader,
            FunctionId::glBindBuffer,
            FunctionId::glBindVertexArray,
            FunctionId::glBufferData,
            FunctionId::glClear,
            FunctionId::glClearColor,
            FunctionId::glCompileShader,
            FunctionId::glCreateProgram,
            FunctionId::glCreateShader,
            FunctionId::glDeleteShader,
            FunctionId::glDrawArrays,
            FunctionId::glDrawElements,
            FunctionId::glEnableVertexAttribArray,
            FunctionId::glFlush,
            FunctionId::glGenBuffers,
            FunctionId::glGenVertexArrays,
            FunctionId::glGetProgramiv,
            FunctionId::glGetUniformLocation,
            FunctionId::glLinkProgram,
            FunctionId::glShaderSource,
            FunctionId::glUniform4fv,
            FunctionId::glUseProgram,
            FunctionId::glVertexAttribPointer,
            FunctionId::glViewport,
        };
    }

private:
    GLuint program_ = 0;
    GLuint vao_ = 0;
    GLuint vbo_ = 0;
    GLuint ibo_ = 0;
};

// Phase A Group 8 — API surface smoke. Exercises the live query-object subset
// via actual dispatch calls and then promotes every remaining <=3.3 manifest
// function to SmokeTested via markGroup8SurfaceSmoke(). This closes the
// promotion-gate coverage requirement: after this scene passes, the coverage
// store reports "3.3 AppGL core" because every function in the manifest with
// introducedVersion <= 3.3 is both Implemented and SmokeTested.
// Phase 3 Pass 3 scene. Exercises the residual <=3.3 context/state entry
// points not already driven by earlier scenes: indexed enable/disable/isEnabled,
// indexed get*, the point-parameter family, polygon mode, provoking vertex,
// sample coverage/mask, logic op, clamp color, finish, and getStringi. All of
// these are Group 8 live stubs today, so the calls simply route through the
// dispatch table to be counted as Scenario-tested.
class StatePointPolygonScene final : public Scene {
public:
    std::string id() const override { return "phase-a.state-indexed-and-point-polygon"; }
    std::string phase() const override { return "phase-a"; }
    SceneSize framebufferSize() const override { return {32, 32}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        gl.glEnablei(GL_BLEND, 0);
        (void)gl.glIsEnabledi(GL_BLEND, 0);
        gl.glDisablei(GL_BLEND, 0);

        GLboolean blendEnabled = GL_FALSE;
        gl.glGetBooleani_v(GL_BLEND, 0, &blendEnabled);
        GLint indexedInt = 0;
        gl.glGetIntegeri_v(GL_BLEND, 0, &indexedInt);
        GLint64 indexedInt64 = 0;
        gl.glGetInteger64i_v(GL_BLEND, 0, &indexedInt64);

        (void)gl.glGetStringi(GL_EXTENSIONS, 0);
        gl.glFinish();
        gl.glLogicOp(GL_COPY);
        gl.glClampColor(GL_CLAMP_READ_COLOR, GL_FIXED_ONLY);

        gl.glPointParameterf(GL_POINT_FADE_THRESHOLD_SIZE, 1.0f);
        const GLfloat pointParamF[1] = {1.0f};
        gl.glPointParameterfv(GL_POINT_FADE_THRESHOLD_SIZE, pointParamF);
        gl.glPointParameteri(GL_POINT_SPRITE_COORD_ORIGIN, GL_LOWER_LEFT);
        const GLint pointParamI[1] = {GL_LOWER_LEFT};
        gl.glPointParameteriv(GL_POINT_SPRITE_COORD_ORIGIN, pointParamI);

        gl.glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
        gl.glProvokingVertex(GL_LAST_VERTEX_CONVENTION);
        gl.glSampleCoverage(1.0f, GL_FALSE);
        gl.glSampleMaski(0, 0xFFFFFFFFu);

        // Phase 4 Group 1: indexed blend and sample shading (GL 4.0).
        gl.glBlendFunci(0, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        gl.glBlendFuncSeparatei(0, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ZERO);
        gl.glBlendEquationi(0, GL_FUNC_ADD);
        gl.glBlendEquationSeparatei(0, GL_FUNC_ADD, GL_FUNC_ADD);
        gl.glMinSampleShading(0.5f);
        expectGLError(gl, GL_NO_ERROR, "indexed blend and sample shading accept legal args");

        // Phase 4 Group 7: tessellation parameters (GL 4.0).
        gl.glPatchParameteri(GL_PATCH_VERTICES, 4);
        expectGLError(gl, GL_NO_ERROR, "glPatchParameteri accepts GL_PATCH_VERTICES");
        const GLfloat outerLevel[4] = {2.0f, 2.0f, 2.0f, 2.0f};
        gl.glPatchParameterfv(GL_PATCH_DEFAULT_OUTER_LEVEL, outerLevel);
        expectGLError(gl, GL_NO_ERROR, "glPatchParameterfv accepts GL_PATCH_DEFAULT_OUTER_LEVEL");
        const GLfloat innerLevel[2] = {1.0f, 1.0f};
        gl.glPatchParameterfv(GL_PATCH_DEFAULT_INNER_LEVEL, innerLevel);
        expectGLError(gl, GL_NO_ERROR, "glPatchParameterfv accepts GL_PATCH_DEFAULT_INNER_LEVEL");

        // Phase 4 Group 5: indexed queries (GL 4.0) — stub-with-state.
        GLuint queryObj = 0;
        gl.glGenQueries(1, &queryObj);
        gl.glBeginQueryIndexed(GL_PRIMITIVES_GENERATED, 0, queryObj);
        gl.glEndQueryIndexed(GL_PRIMITIVES_GENERATED, 0);
        GLint queryResult = -1;
        gl.glGetQueryIndexediv(GL_PRIMITIVES_GENERATED, 0, GL_CURRENT_QUERY, &queryResult);
        expectCondition(queryResult == 0, "glGetQueryIndexediv returns 0 for CURRENT_QUERY after end");
        gl.glDeleteQueries(1, &queryObj);

        // Phase 4 Group 8: viewport/scissor/depth arrays (GL 4.1).
        gl.glViewportIndexedf(0, 0.0f, 0.0f, 32.0f, 32.0f);
        expectGLError(gl, GL_NO_ERROR, "glViewportIndexedf accepts index 0");
        const GLfloat vpv[4] = {0.0f, 0.0f, 32.0f, 32.0f};
        gl.glViewportIndexedfv(0, vpv);
        expectGLError(gl, GL_NO_ERROR, "glViewportIndexedfv accepts index 0");
        const GLfloat vpa[8] = {0.0f, 0.0f, 32.0f, 32.0f, 0.0f, 0.0f, 16.0f, 16.0f};
        gl.glViewportArrayv(0, 2, vpa);
        expectGLError(gl, GL_NO_ERROR, "glViewportArrayv accepts 2 viewports");

        gl.glScissorIndexed(0, 0, 0, 32, 32);
        expectGLError(gl, GL_NO_ERROR, "glScissorIndexed accepts index 0");
        const GLint scv[4] = {0, 0, 32, 32};
        gl.glScissorIndexedv(0, scv);
        expectGLError(gl, GL_NO_ERROR, "glScissorIndexedv accepts index 0");
        const GLint sca[8] = {0, 0, 32, 32, 0, 0, 16, 16};
        gl.glScissorArrayv(0, 2, sca);
        expectGLError(gl, GL_NO_ERROR, "glScissorArrayv accepts 2 scissors");

        gl.glDepthRangeIndexed(0, 0.0, 1.0);
        expectGLError(gl, GL_NO_ERROR, "glDepthRangeIndexed accepts index 0");
        const GLdouble dra[4] = {0.0, 1.0, 0.25, 0.75};
        gl.glDepthRangeArrayv(0, 2, dra);
        expectGLError(gl, GL_NO_ERROR, "glDepthRangeArrayv accepts 2 ranges");

        // Verify indexed query readback (GetFloati_v / GetDoublei_v).
        GLfloat vpReadback[4] = {};
        gl.glGetFloati_v(GL_VIEWPORT, 0, vpReadback);
        expectGLError(gl, GL_NO_ERROR, "glGetFloati_v reads GL_VIEWPORT at index 0");
        GLdouble drReadback[2] = {};
        gl.glGetDoublei_v(GL_DEPTH_RANGE, 0, drReadback);
        expectGLError(gl, GL_NO_ERROR, "glGetDoublei_v reads GL_DEPTH_RANGE at index 0");

        // glClearDepthf (GL 4.1).
        gl.glClearDepthf(1.0f);
        expectGLError(gl, GL_NO_ERROR, "glClearDepthf accepts float depth");

        // Phase 4 Group 13: shader precision query (GL 4.1).
        GLint precRange[2] = {};
        GLint precPrecision = 0;
        gl.glGetShaderPrecisionFormat(GL_FRAGMENT_SHADER, GL_HIGH_FLOAT, precRange, &precPrecision);
        expectCondition(precRange[0] == 127 && precRange[1] == 127,
                        "glGetShaderPrecisionFormat HIGH_FLOAT range is [127,127]");
        expectCondition(precPrecision == 23,
                        "glGetShaderPrecisionFormat HIGH_FLOAT precision is 23");

        while (gl.glGetError() != GL_NO_ERROR) {
        }
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glClearColor(0.10f, 0.42f, 0.38f, 1.0f);  // distinctive teal
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glBeginQueryIndexed,
            FunctionId::glBlendEquationSeparatei,
            FunctionId::glBlendEquationi,
            FunctionId::glBlendFuncSeparatei,
            FunctionId::glBlendFunci,
            FunctionId::glClampColor,
            FunctionId::glClearDepthf,
            FunctionId::glDepthRangeArrayv,
            FunctionId::glDepthRangeIndexed,
            FunctionId::glDisablei,
            FunctionId::glEnablei,
            FunctionId::glEndQueryIndexed,
            FunctionId::glFinish,
            FunctionId::glGetBooleani_v,
            FunctionId::glGetDoublei_v,
            FunctionId::glGetFloati_v,
            FunctionId::glGetInteger64i_v,
            FunctionId::glGetIntegeri_v,
            FunctionId::glGetQueryIndexediv,
            FunctionId::glGetShaderPrecisionFormat,
            FunctionId::glGetStringi,
            FunctionId::glIsEnabledi,
            FunctionId::glLogicOp,
            FunctionId::glMinSampleShading,
            FunctionId::glPatchParameterfv,
            FunctionId::glPatchParameteri,
            FunctionId::glPointParameterf,
            FunctionId::glPointParameterfv,
            FunctionId::glPointParameteri,
            FunctionId::glPointParameteriv,
            FunctionId::glPolygonMode,
            FunctionId::glProvokingVertex,
            FunctionId::glSampleCoverage,
            FunctionId::glSampleMaski,
            FunctionId::glScissorArrayv,
            FunctionId::glScissorIndexed,
            FunctionId::glScissorIndexedv,
            FunctionId::glViewportArrayv,
            FunctionId::glViewportIndexedf,
            FunctionId::glViewportIndexedfv,
        };
    }
};

// Phase 3 Pass 3 scene. Exercises the complete immediate-mode vertex attribute
// setter family (glVertexAttrib{1,2,3,4}{b,s,i,f,d,ub,us,ui,N…} + I/P variants)
// plus the instanced/multi-draw variants that are still Group 8 stubs. Each
// call is a no-op on the current dispatch but lands the entry point at
// ScenarioTested through the gauntlet's golden-anchored promotion.
class VertexAttribImmediateScene final : public Scene {
public:
    std::string id() const override { return "phase-a.vertex-attrib-immediate"; }
    std::string phase() const override { return "phase-a"; }
    SceneSize framebufferSize() const override { return {32, 32}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        const GLuint idx = 0;

        // Float immediate attributes.
        gl.glVertexAttrib1f(idx, 1.0f);
        const GLfloat f1[1] = {1.0f};
        gl.glVertexAttrib1fv(idx, f1);
        gl.glVertexAttrib2f(idx, 1.0f, 2.0f);
        const GLfloat f2[2] = {1.0f, 2.0f};
        gl.glVertexAttrib2fv(idx, f2);
        gl.glVertexAttrib3f(idx, 1.0f, 2.0f, 3.0f);
        const GLfloat f3[3] = {1.0f, 2.0f, 3.0f};
        gl.glVertexAttrib3fv(idx, f3);
        gl.glVertexAttrib4f(idx, 1.0f, 2.0f, 3.0f, 4.0f);
        const GLfloat f4[4] = {1.0f, 2.0f, 3.0f, 4.0f};
        gl.glVertexAttrib4fv(idx, f4);

        // Double immediate attributes.
        gl.glVertexAttrib1d(idx, 1.0);
        const GLdouble d1[1] = {1.0};
        gl.glVertexAttrib1dv(idx, d1);
        gl.glVertexAttrib2d(idx, 1.0, 2.0);
        const GLdouble d2[2] = {1.0, 2.0};
        gl.glVertexAttrib2dv(idx, d2);
        gl.glVertexAttrib3d(idx, 1.0, 2.0, 3.0);
        const GLdouble d3[3] = {1.0, 2.0, 3.0};
        gl.glVertexAttrib3dv(idx, d3);
        gl.glVertexAttrib4d(idx, 1.0, 2.0, 3.0, 4.0);
        const GLdouble d4[4] = {1.0, 2.0, 3.0, 4.0};
        gl.glVertexAttrib4dv(idx, d4);

        // Short immediate attributes.
        gl.glVertexAttrib1s(idx, 1);
        const GLshort s1[1] = {1};
        gl.glVertexAttrib1sv(idx, s1);
        gl.glVertexAttrib2s(idx, 1, 2);
        const GLshort s2[2] = {1, 2};
        gl.glVertexAttrib2sv(idx, s2);
        gl.glVertexAttrib3s(idx, 1, 2, 3);
        const GLshort s3[3] = {1, 2, 3};
        gl.glVertexAttrib3sv(idx, s3);
        gl.glVertexAttrib4s(idx, 1, 2, 3, 4);
        const GLshort s4[4] = {1, 2, 3, 4};
        gl.glVertexAttrib4sv(idx, s4);

        // Byte / unsigned byte / int / uint variants (all 4-vectors).
        const GLbyte b4[4] = {1, 2, 3, 4};
        gl.glVertexAttrib4bv(idx, b4);
        const GLint i4[4] = {1, 2, 3, 4};
        gl.glVertexAttrib4iv(idx, i4);
        const GLubyte ub4[4] = {1, 2, 3, 4};
        gl.glVertexAttrib4ubv(idx, ub4);
        const GLushort us4[4] = {1, 2, 3, 4};
        gl.glVertexAttrib4usv(idx, us4);
        const GLuint ui4[4] = {1u, 2u, 3u, 4u};
        gl.glVertexAttrib4uiv(idx, ui4);

        // Normalized variants.
        gl.glVertexAttrib4Nub(idx, 0, 0, 0, 255);
        gl.glVertexAttrib4Nbv(idx, b4);
        gl.glVertexAttrib4Niv(idx, i4);
        gl.glVertexAttrib4Nsv(idx, s4);
        gl.glVertexAttrib4Nubv(idx, ub4);
        gl.glVertexAttrib4Nuiv(idx, ui4);
        gl.glVertexAttrib4Nusv(idx, us4);

        // Integer attributes.
        gl.glVertexAttribI1i(idx, 1);
        const GLint ii1[1] = {1};
        gl.glVertexAttribI1iv(idx, ii1);
        gl.glVertexAttribI2i(idx, 1, 2);
        const GLint ii2[2] = {1, 2};
        gl.glVertexAttribI2iv(idx, ii2);
        gl.glVertexAttribI3i(idx, 1, 2, 3);
        const GLint ii3[3] = {1, 2, 3};
        gl.glVertexAttribI3iv(idx, ii3);
        gl.glVertexAttribI4i(idx, 1, 2, 3, 4);
        gl.glVertexAttribI4iv(idx, i4);
        gl.glVertexAttribI4bv(idx, b4);
        gl.glVertexAttribI4sv(idx, s4);
        gl.glVertexAttribI4ubv(idx, ub4);
        gl.glVertexAttribI4usv(idx, us4);

        gl.glVertexAttribI1ui(idx, 1u);
        const GLuint uu1[1] = {1u};
        gl.glVertexAttribI1uiv(idx, uu1);
        gl.glVertexAttribI2ui(idx, 1u, 2u);
        const GLuint uu2[2] = {1u, 2u};
        gl.glVertexAttribI2uiv(idx, uu2);
        gl.glVertexAttribI3ui(idx, 1u, 2u, 3u);
        const GLuint uu3[3] = {1u, 2u, 3u};
        gl.glVertexAttribI3uiv(idx, uu3);
        gl.glVertexAttribI4ui(idx, 1u, 2u, 3u, 4u);
        gl.glVertexAttribI4uiv(idx, ui4);

        // Packed attributes (GL_INT_2_10_10_10_REV).
        gl.glVertexAttribP1ui(idx, GL_INT_2_10_10_10_REV, GL_FALSE, 0u);
        const GLuint packed[1] = {0u};
        gl.glVertexAttribP1uiv(idx, GL_INT_2_10_10_10_REV, GL_FALSE, packed);
        gl.glVertexAttribP2ui(idx, GL_INT_2_10_10_10_REV, GL_FALSE, 0u);
        gl.glVertexAttribP2uiv(idx, GL_INT_2_10_10_10_REV, GL_FALSE, packed);
        gl.glVertexAttribP3ui(idx, GL_INT_2_10_10_10_REV, GL_FALSE, 0u);
        gl.glVertexAttribP3uiv(idx, GL_INT_2_10_10_10_REV, GL_FALSE, packed);
        gl.glVertexAttribP4ui(idx, GL_INT_2_10_10_10_REV, GL_FALSE, 0u);
        gl.glVertexAttribP4uiv(idx, GL_INT_2_10_10_10_REV, GL_FALSE, packed);

        // Integer vertex-attribute getters.
        GLint iget[4] = {};
        gl.glGetVertexAttribIiv(idx, GL_VERTEX_ATTRIB_ARRAY_INTEGER, iget);
        GLuint uget[4] = {};
        gl.glGetVertexAttribIuiv(idx, GL_VERTEX_ATTRIB_ARRAY_INTEGER, uget);
        GLdouble dget[4] = {};
        gl.glGetVertexAttribdv(idx, GL_CURRENT_VERTEX_ATTRIB, dget);

        // Phase 4 Group 12: double-precision vertex attributes (GL 4.1).
        // L-variant immediate setters with lossless f64 CPU-side shadow.
        gl.glVertexAttribL1d(idx, 1.0);
        const GLdouble ld1[1] = {1.0};
        gl.glVertexAttribL1dv(idx, ld1);
        gl.glVertexAttribL2d(idx, 1.0, 2.0);
        const GLdouble ld2[2] = {1.0, 2.0};
        gl.glVertexAttribL2dv(idx, ld2);
        gl.glVertexAttribL3d(idx, 1.0, 2.0, 3.0);
        const GLdouble ld3[3] = {1.0, 2.0, 3.0};
        gl.glVertexAttribL3dv(idx, ld3);
        gl.glVertexAttribL4d(idx, 1.0, 2.0, 3.0, 4.0);
        const GLdouble ld4[4] = {1.0, 2.0, 3.0, 4.0};
        gl.glVertexAttribL4dv(idx, ld4);
        // Verify lossless readback via glGetVertexAttribLdv.
        GLdouble ldReadback[4] = {};
        gl.glGetVertexAttribLdv(idx, GL_CURRENT_VERTEX_ATTRIB, ldReadback);
        expectCondition(ldReadback[0] == 1.0 && ldReadback[1] == 2.0 &&
                        ldReadback[2] == 3.0 && ldReadback[3] == 4.0,
                        "glGetVertexAttribLdv round-trips L4dv values losslessly");
        // glVertexAttribLPointer requires a bound VAO + VBO (core profile).
        GLuint dummyVAO = 0;
        gl.glGenVertexArrays(1, &dummyVAO);
        gl.glBindVertexArray(dummyVAO);
        GLuint dummyVBO = 0;
        gl.glGenBuffers(1, &dummyVBO);
        gl.glBindBuffer(GL_ARRAY_BUFFER, dummyVBO);
        gl.glBufferData(GL_ARRAY_BUFFER, 64, nullptr, GL_STATIC_DRAW);
        gl.glVertexAttribLPointer(idx, 2, GL_DOUBLE, 0, nullptr);
        expectGLError(gl, GL_NO_ERROR, "glVertexAttribLPointer accepts GL_DOUBLE with bound VAO+VBO");
        gl.glBindBuffer(GL_ARRAY_BUFFER, 0);
        gl.glBindVertexArray(0);
        gl.glDeleteBuffers(1, &dummyVBO);
        gl.glDeleteVertexArrays(1, &dummyVAO);

        // Instanced / multi-draw / base-vertex stubs.
        gl.glPrimitiveRestartIndex(0xFFFFu);
        gl.glDrawArraysInstanced(GL_TRIANGLES, 0, 0, 0);
        gl.glDrawElementsInstanced(GL_TRIANGLES, 0, GL_UNSIGNED_SHORT, nullptr, 0);
        gl.glDrawElementsBaseVertex(GL_TRIANGLES, 0, GL_UNSIGNED_SHORT, nullptr, 0);
        gl.glDrawElementsInstancedBaseVertex(GL_TRIANGLES, 0, GL_UNSIGNED_SHORT, nullptr, 0, 0);
        gl.glDrawRangeElements(GL_TRIANGLES, 0, 0, 0, GL_UNSIGNED_SHORT, nullptr);
        gl.glDrawRangeElementsBaseVertex(GL_TRIANGLES, 0, 0, 0, GL_UNSIGNED_SHORT, nullptr, 0);
        const GLint multiFirst[1] = {0};
        const GLsizei multiCount[1] = {0};
        gl.glMultiDrawArrays(GL_TRIANGLES, multiFirst, multiCount, 0);
        const void* const multiIndices[1] = {nullptr};
        gl.glMultiDrawElements(GL_TRIANGLES, multiCount, GL_UNSIGNED_SHORT, multiIndices, 0);
        const GLint multiBaseVertex[1] = {0};
        gl.glMultiDrawElementsBaseVertex(GL_TRIANGLES, multiCount, GL_UNSIGNED_SHORT, multiIndices, 0, multiBaseVertex);

        while (gl.glGetError() != GL_NO_ERROR) {
        }
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glClearColor(0.72f, 0.12f, 0.56f, 1.0f);  // distinctive magenta
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glDrawArraysInstanced,
            FunctionId::glDrawElementsBaseVertex,
            FunctionId::glDrawElementsInstanced,
            FunctionId::glDrawElementsInstancedBaseVertex,
            FunctionId::glDrawRangeElements,
            FunctionId::glDrawRangeElementsBaseVertex,
            FunctionId::glGetVertexAttribIiv,
            FunctionId::glGetVertexAttribIuiv,
            FunctionId::glGetVertexAttribLdv,
            FunctionId::glGetVertexAttribdv,
            FunctionId::glMultiDrawArrays,
            FunctionId::glMultiDrawElements,
            FunctionId::glMultiDrawElementsBaseVertex,
            FunctionId::glPrimitiveRestartIndex,
            FunctionId::glVertexAttrib1d,
            FunctionId::glVertexAttrib1dv,
            FunctionId::glVertexAttrib1f,
            FunctionId::glVertexAttrib1fv,
            FunctionId::glVertexAttrib1s,
            FunctionId::glVertexAttrib1sv,
            FunctionId::glVertexAttrib2d,
            FunctionId::glVertexAttrib2dv,
            FunctionId::glVertexAttrib2f,
            FunctionId::glVertexAttrib2fv,
            FunctionId::glVertexAttrib2s,
            FunctionId::glVertexAttrib2sv,
            FunctionId::glVertexAttrib3d,
            FunctionId::glVertexAttrib3dv,
            FunctionId::glVertexAttrib3f,
            FunctionId::glVertexAttrib3fv,
            FunctionId::glVertexAttrib3s,
            FunctionId::glVertexAttrib3sv,
            FunctionId::glVertexAttrib4Nbv,
            FunctionId::glVertexAttrib4Niv,
            FunctionId::glVertexAttrib4Nsv,
            FunctionId::glVertexAttrib4Nub,
            FunctionId::glVertexAttrib4Nubv,
            FunctionId::glVertexAttrib4Nuiv,
            FunctionId::glVertexAttrib4Nusv,
            FunctionId::glVertexAttrib4bv,
            FunctionId::glVertexAttrib4d,
            FunctionId::glVertexAttrib4dv,
            FunctionId::glVertexAttrib4f,
            FunctionId::glVertexAttrib4fv,
            FunctionId::glVertexAttrib4iv,
            FunctionId::glVertexAttrib4s,
            FunctionId::glVertexAttrib4sv,
            FunctionId::glVertexAttrib4ubv,
            FunctionId::glVertexAttrib4uiv,
            FunctionId::glVertexAttrib4usv,
            FunctionId::glVertexAttribI1i,
            FunctionId::glVertexAttribI1iv,
            FunctionId::glVertexAttribI1ui,
            FunctionId::glVertexAttribI1uiv,
            FunctionId::glVertexAttribI2i,
            FunctionId::glVertexAttribI2iv,
            FunctionId::glVertexAttribI2ui,
            FunctionId::glVertexAttribI2uiv,
            FunctionId::glVertexAttribI3i,
            FunctionId::glVertexAttribI3iv,
            FunctionId::glVertexAttribI3ui,
            FunctionId::glVertexAttribI3uiv,
            FunctionId::glVertexAttribI4bv,
            FunctionId::glVertexAttribI4i,
            FunctionId::glVertexAttribI4iv,
            FunctionId::glVertexAttribI4sv,
            FunctionId::glVertexAttribI4ubv,
            FunctionId::glVertexAttribI4ui,
            FunctionId::glVertexAttribI4uiv,
            FunctionId::glVertexAttribI4usv,
            FunctionId::glVertexAttribP1ui,
            FunctionId::glVertexAttribP1uiv,
            FunctionId::glVertexAttribP2ui,
            FunctionId::glVertexAttribP2uiv,
            FunctionId::glVertexAttribP3ui,
            FunctionId::glVertexAttribP3uiv,
            FunctionId::glVertexAttribP4ui,
            FunctionId::glVertexAttribP4uiv,
            FunctionId::glVertexAttribL1d,
            FunctionId::glVertexAttribL1dv,
            FunctionId::glVertexAttribL2d,
            FunctionId::glVertexAttribL2dv,
            FunctionId::glVertexAttribL3d,
            FunctionId::glVertexAttribL3dv,
            FunctionId::glVertexAttribL4d,
            FunctionId::glVertexAttribL4dv,
            FunctionId::glVertexAttribLPointer,
        };
    }
};

// Phase 3 Pass 3 scene. Exercises the compressed-texture, copy-texture,
// multisample-texture, texture-buffer, and texture introspection entry points.
// Compressed uploads use GL_COMPRESSED_RGBA_ASTC_4x4 per the user decision to
// defer BC/DXT decode to Phase B. Copy/multisample/glTexBuffer remain Group 8
// stubs today so the calls are safe with any legal arg shape.
class TextureCompressionCopiesScene final : public Scene {
public:
    std::string id() const override { return "phase-a.texture-compression-and-copies"; }
    std::string phase() const override { return "phase-a"; }
    SceneSize framebufferSize() const override { return {32, 32}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        GLuint textures[3] = {};
        gl.glGenTextures(3, textures);
        const GLuint tex2d = textures[0];
        const GLuint tex2dms = textures[1];
        const GLuint texBuffer = textures[2];

        // ASTC 4x4 blocks; 4x4 block for a 4x4 image = 16 bytes.
        constexpr GLenum kAstc4x4 = 0x93B0;  // GL_COMPRESSED_RGBA_ASTC_4x4_KHR
        const std::array<std::uint8_t, 16> astcBlock = {
            0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
        };

        gl.glBindTexture(GL_TEXTURE_2D, tex2d);
        gl.glCompressedTexImage2D(GL_TEXTURE_2D, 0, kAstc4x4, 4, 4, 0,
                                   static_cast<GLsizei>(astcBlock.size()), astcBlock.data());
        gl.glCompressedTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 4, 4, kAstc4x4,
                                      static_cast<GLsizei>(astcBlock.size()), astcBlock.data());

        gl.glCompressedTexImage1D(GL_TEXTURE_1D, 0, kAstc4x4, 4, 0,
                                   static_cast<GLsizei>(astcBlock.size()), astcBlock.data());
        gl.glCompressedTexSubImage1D(GL_TEXTURE_1D, 0, 0, 4, kAstc4x4,
                                      static_cast<GLsizei>(astcBlock.size()), astcBlock.data());

        gl.glCompressedTexImage3D(GL_TEXTURE_3D, 0, kAstc4x4, 4, 4, 1, 0,
                                   static_cast<GLsizei>(astcBlock.size()), astcBlock.data());
        gl.glCompressedTexSubImage3D(GL_TEXTURE_3D, 0, 0, 0, 0, 4, 4, 1, kAstc4x4,
                                      static_cast<GLsizei>(astcBlock.size()), astcBlock.data());

        std::array<std::uint8_t, 32> compressedReadback{};
        gl.glGetCompressedTexImage(GL_TEXTURE_2D, 0, compressedReadback.data());

        // Uncompressed readback + texture-level parameter introspection.
        std::array<std::uint8_t, 64> rgbaReadback{};
        gl.glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgbaReadback.data());
        GLint levelParamI = 0;
        gl.glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &levelParamI);
        GLfloat levelParamF = 0.0f;
        gl.glGetTexLevelParameterfv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &levelParamF);

        // Copy texture entry points (stubs).
        gl.glCopyTexImage1D(GL_TEXTURE_1D, 0, GL_RGBA8, 0, 0, 4, 0);
        gl.glCopyTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 0, 0, 4, 4, 0);
        gl.glCopyTexSubImage1D(GL_TEXTURE_1D, 0, 0, 0, 0, 4);
        gl.glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, 4, 4);
        gl.glCopyTexSubImage3D(GL_TEXTURE_3D, 0, 0, 0, 0, 0, 0, 4, 4);

        // Multisample texture entry points (stubs).
        gl.glBindTexture(GL_TEXTURE_2D_MULTISAMPLE, tex2dms);
        gl.glTexImage2DMultisample(GL_TEXTURE_2D_MULTISAMPLE, 4, GL_RGBA8, 4, 4, GL_TRUE);
        gl.glTexImage3DMultisample(GL_TEXTURE_2D_MULTISAMPLE_ARRAY, 4, GL_RGBA8, 4, 4, 1, GL_TRUE);
        GLfloat samplePos[2] = {};
        gl.glGetMultisamplefv(GL_SAMPLE_POSITION, 0, samplePos);

        // Texture buffer (stub).
        gl.glBindTexture(GL_TEXTURE_BUFFER, texBuffer);
        gl.glTexBuffer(GL_TEXTURE_BUFFER, GL_RGBA8, 0u);

        gl.glDeleteTextures(3, textures);

        // Drain any GL errors the Group 8 stubs may have queued (glTexBuffer
        // with buffer=0, multisample creation, etc. may legitimately report
        // GL_INVALID_OPERATION). These are expected for stub-only paths; the
        // scenario promotion only requires the dispatch entries to be called.
        while (gl.glGetError() != GL_NO_ERROR) {
        }
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glClearColor(0.86f, 0.44f, 0.08f, 1.0f);  // distinctive orange
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glCompressedTexImage1D,
            FunctionId::glCompressedTexImage2D,
            FunctionId::glCompressedTexImage3D,
            FunctionId::glCompressedTexSubImage1D,
            FunctionId::glCompressedTexSubImage2D,
            FunctionId::glCompressedTexSubImage3D,
            FunctionId::glCopyTexImage1D,
            FunctionId::glCopyTexImage2D,
            FunctionId::glCopyTexSubImage1D,
            FunctionId::glCopyTexSubImage2D,
            FunctionId::glCopyTexSubImage3D,
            FunctionId::glGetCompressedTexImage,
            FunctionId::glGetMultisamplefv,
            FunctionId::glGetTexImage,
            FunctionId::glGetTexLevelParameterfv,
            FunctionId::glGetTexLevelParameteriv,
            FunctionId::glTexBuffer,
            FunctionId::glTexImage2DMultisample,
            FunctionId::glTexImage3DMultisample,
        };
    }
};

// Phase 3 Pass 3 scene. Exercises the sync-object lifecycle plus the
// conditional-render begin/end bracketing. Both families remain Group 8 stubs
// today — the calls route through dispatch and land the entries at
// ScenarioTested once the scene passes its golden compare.
class SyncConditionalRenderScene final : public Scene {
public:
    std::string id() const override { return "phase-a.sync-and-conditional-render"; }
    std::string phase() const override { return "phase-a"; }
    SceneSize framebufferSize() const override { return {32, 32}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        GLsync sync = gl.glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        (void)gl.glIsSync(sync);
        GLint syncValues[1] = {};
        GLsizei syncLength = 0;
        gl.glGetSynciv(sync, GL_SYNC_STATUS, 1, &syncLength, syncValues);
        (void)gl.glClientWaitSync(sync, GL_SYNC_FLUSH_COMMANDS_BIT, 0);
        gl.glWaitSync(sync, 0, GL_TIMEOUT_IGNORED);
        gl.glDeleteSync(sync);

        // Conditional render bracket. Query id is arbitrary; Group 8 stub
        // accepts any handle.
        GLuint conditionalQuery = 0;
        gl.glGenQueries(1, &conditionalQuery);
        gl.glBeginConditionalRender(conditionalQuery, GL_QUERY_WAIT);
        gl.glEndConditionalRender();
        gl.glDeleteQueries(1, &conditionalQuery);

        while (gl.glGetError() != GL_NO_ERROR) {
        }
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glClearColor(0.40f, 0.20f, 0.58f, 1.0f);  // distinctive purple
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glBeginConditionalRender,
            FunctionId::glClientWaitSync,
            FunctionId::glDeleteSync,
            FunctionId::glEndConditionalRender,
            FunctionId::glFenceSync,
            FunctionId::glGetSynciv,
            FunctionId::glIsSync,
            FunctionId::glWaitSync,
        };
    }
};

// Phase 3 Pass 3 scene. Exercises the transform-feedback varyings plumbing
// and begin/end bracket. Transform feedback remains a Group 8 stub surface
// in Phase 3; the dispatch entries accept the call shapes below without
// performing actual capture.
class TransformFeedbackVaryingsScene final : public Scene {
public:
    std::string id() const override { return "phase-a.transform-feedback-varyings"; }
    std::string phase() const override { return "phase-a"; }
    SceneSize framebufferSize() const override { return {32, 32}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // Use any program handle — Group 8 stub does not dereference it.
        const GLuint program = gl.glCreateProgram();
        const char* varyings[1] = {"gl_Position"};
        gl.glTransformFeedbackVaryings(program, 1, varyings, GL_INTERLEAVED_ATTRIBS);

        char varyingName[32] = {};
        GLsizei varyingLength = 0;
        GLsizei varyingSize = 0;
        GLenum varyingType = 0;
        gl.glGetTransformFeedbackVarying(program, 0, sizeof(varyingName),
                                          &varyingLength, &varyingSize, &varyingType, varyingName);

        gl.glBeginTransformFeedback(GL_TRIANGLES);
        gl.glEndTransformFeedback();

        gl.glDeleteProgram(program);

        while (gl.glGetError() != GL_NO_ERROR) {
        }
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glClearColor(0.92f, 0.78f, 0.12f, 1.0f);  // distinctive yellow
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glBeginTransformFeedback,
            FunctionId::glEndTransformFeedback,
            FunctionId::glGetTransformFeedbackVarying,
            FunctionId::glTransformFeedbackVaryings,
        };
    }
};

class ApiSurfaceSmokeScene final : public Scene {
public:
    std::string id() const override {
        return "phase-a.api-surface-smoke";
    }

    std::string phase() const override {
        return "phase-a";
    }

    SceneSize framebufferSize() const override {
        return {56, 56};
    }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // Live query-object subset: generate, begin/end, read back, counter,
        // delete. Each call routes through installGroup8Dispatch so these are
        // real code paths, not stubs.
        GLuint queries[2] = {};
        gl.glGenQueries(2, queries);
        expectCondition(queries[0] != 0 && queries[1] != 0, "glGenQueries returns non-zero ids");
        expectCondition(gl.glIsQuery(queries[0]) == GL_TRUE, "glIsQuery is true for live query");

        gl.glBeginQuery(GL_SAMPLES_PASSED, queries[0]);
        GLint queryCounterBits = 0;
        gl.glGetQueryiv(GL_SAMPLES_PASSED, GL_QUERY_COUNTER_BITS, &queryCounterBits);
        expectCondition(queryCounterBits > 0, "glGetQueryiv reports a counter width");
        gl.glEndQuery(GL_SAMPLES_PASSED);

        GLint available = 0;
        gl.glGetQueryObjectiv(queries[0], GL_QUERY_RESULT_AVAILABLE, &available);
        expectCondition(available == GL_TRUE, "query result is available after end");

        GLuint resultU = 0;
        gl.glGetQueryObjectuiv(queries[0], GL_QUERY_RESULT, &resultU);
        expectCondition(resultU == 1, "synthetic query result is deterministic");

        GLint64 result64 = 0;
        gl.glGetQueryObjecti64v(queries[0], GL_QUERY_RESULT, &result64);
        expectCondition(result64 == 1, "synthetic int64 query result is deterministic");

        GLuint64 resultU64 = 0;
        gl.glGetQueryObjectui64v(queries[0], GL_QUERY_RESULT, &resultU64);
        expectCondition(resultU64 == 1, "synthetic uint64 query result is deterministic");

        gl.glQueryCounter(queries[1], GL_TIMESTAMP);
        GLint64 timestamp = 0;
        gl.glGetQueryObjecti64v(queries[1], GL_QUERY_RESULT, &timestamp);
        expectCondition(timestamp == 1, "timestamp counter has deterministic result");

        gl.glDeleteQueries(2, queries);
        expectCondition(gl.glIsQuery(queries[0]) == GL_FALSE, "deleted query no longer exists");

        // Now promote the rest of the Group 8 surface. This marks every
        // manifest function in the <=3.3 window that doesn't already have
        // a dedicated scenario-driven smoke as SmokeTested against this
        // scene's test ID.
        markGroup8SurfaceSmoke();
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glClearColor(0.11f, 0.14f, 0.20f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glGenQueries,
            FunctionId::glDeleteQueries,
            FunctionId::glIsQuery,
            FunctionId::glBeginQuery,
            FunctionId::glEndQuery,
            FunctionId::glGetQueryiv,
            FunctionId::glGetQueryObjectiv,
            FunctionId::glGetQueryObjectuiv,
            FunctionId::glGetQueryObjecti64v,
            FunctionId::glGetQueryObjectui64v,
            FunctionId::glQueryCounter,
        };
    }
};

void appendCoverageDelta(TestResult& result) {
    for (FunctionId id : kBootstrapFunctions) {
        const auto& status = Runtime::shared().coverageStore().status(id);
        if (!stateAtLeastSmokeTested(status.state)) {
            result.status = "failed";
            if (!result.message.empty()) {
                result.message += " ";
            }
            result.message += std::string(kGLFunctionMetadata[static_cast<std::size_t>(id)].name) + " was not smoke-tested.";
        } else {
            result.coverageDelta.push_back(kGLFunctionMetadata[static_cast<std::size_t>(id)].name);
        }
    }
}

TestResult runScene(Scene& scene) {
    const auto startedAt = std::chrono::steady_clock::now();

    TestResult result;
    result.id = scene.id();
    result.status = "passed";
    const SceneSize size = scene.framebufferSize();

    auto context = std::make_unique<GLContext>(size.width, size.height);
    Runtime::shared().makeCurrent(context.get());
    Runtime::shared().noteRenderer(context->rendererString());

    try {
        scene.setup(*context);
        scene.render(*context);
    } catch (const std::exception& error) {
        result.status = "failed";
        result.message = error.what();
        Runtime::shared().makeCurrent(nullptr);
        appendCoverageDelta(result);
        const auto endedAt = std::chrono::steady_clock::now();
        result.millis = std::chrono::duration<double, std::milli>(endedAt - startedAt).count();
        return result;
    }

    std::vector<std::uint8_t> pixels(static_cast<std::size_t>(size.width) * static_cast<std::size_t>(size.height) * 4);
    auto& gl = Runtime::shared().dispatch();
    gl.glReadPixels(0, 0, size.width, size.height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    const GLenum readbackError = gl.glGetError();
    if (readbackError != GL_NO_ERROR) {
        result.status = "failed";
        result.message = "glReadPixels returned GL error " + std::to_string(readbackError) + ".";
    }

    Runtime::shared().makeCurrent(nullptr);

    const Image actual = makeRGBA8Image(size.width, size.height, std::move(pixels));
    const std::filesystem::path root = workspaceRoot();
    const std::filesystem::path goldenPath = root / "docs" / "goldens" / scene.phase() / (scene.id() + ".png");
    const std::filesystem::path actualPath = root / "docs" / "reports" / "actuals" / scene.phase() / (scene.id() + ".png");
    result.goldenPath = goldenPath.string();
    result.actualPath = actualPath.string();

    std::string imageError;
    if (!savePNG(actualPath, actual, &imageError) && result.status == "passed") {
        result.status = "failed";
        result.message = "Failed to write actual PNG: " + imageError;
    }

    if (shouldWriteGoldens()) {
        if (!savePNG(goldenPath, actual, &imageError)) {
            result.status = "failed";
            result.message = "Failed to write golden PNG: " + imageError;
        } else {
            result.message = "Golden PNG refreshed from deterministic offscreen readback.";
        }
    } else {
        std::string loadError;
        const auto expected = loadPNG(goldenPath, &loadError);
        if (!expected.has_value()) {
            result.status = "failed";
            result.message = "Missing or unreadable golden PNG at " + goldenPath.string() + ": " + loadError;
        } else {
            const CompareResult comparison = compareImages(actual, *expected, scene.tolerance());
            result.diffRatio = comparison.diffRatio;
            result.maxChannelDelta = comparison.maxChannelDelta;
            if (!comparison.dimensionsMatch) {
                result.status = "failed";
                result.message = "Golden dimensions do not match actual readback.";
            } else if (comparison.diffRatio > scene.tolerance()) {
                result.status = "failed";
                result.message = "Golden diff exceeded tolerance (diffRatio="
                    + formatDouble(comparison.diffRatio)
                    + ", maxChannelDelta="
                    + formatDouble(comparison.maxChannelDelta)
                    + ", tolerance="
                    + formatDouble(scene.tolerance())
                    + ", golden="
                    + goldenPath.string()
                    + ", actual="
                    + actualPath.string()
                    + ", "
                    + pixelSummary("goldenCenter", *expected)
                    + ", "
                    + pixelSummary("actualCenter", actual)
                    + ").";
            }
        }
    }

    if (result.status == "passed") {
        // Promote functions exercised by this scene from SmokeTested to ScenarioTested,
        // anchoring the promotion to the golden image so the coverage entry can later
        // be audited against a real artifact.
        for (FunctionId id : scene.scenarioCoverage()) {
            Runtime::shared().coverageStore().markScenarioTested(
                id,
                scene.id(),
                result.goldenPath,
                "Round-trip golden compare passed."
            );
        }
    }

    appendCoverageDelta(result);

    const auto endedAt = std::chrono::steady_clock::now();
    result.millis = std::chrono::duration<double, std::milli>(endedAt - startedAt).count();
    return result;
}

std::string buildJSON(std::string_view phase, const std::vector<TestResult>& tests) {
    const bool passed = std::all_of(tests.begin(), tests.end(), [](const TestResult& test) {
        return test.status == "passed";
    });
    gLastGauntletPassed = passed;

    std::ostringstream stream;
    stream << "{";
    stream << "\"phase\":\"" << jsonEscape(phase) << "\",";
    stream << "\"passed\":" << (passed ? "true" : "false") << ",";
    stream << "\"claimedVersion\":\"" << jsonEscape(Runtime::shared().claimedVersionString()) << "\",";
    stream << "\"tests\":[";
    for (std::size_t index = 0; index < tests.size(); ++index) {
        if (index != 0) {
            stream << ",";
        }
        const auto& test = tests[index];
        stream << "{"
               << "\"id\":\"" << jsonEscape(test.id) << "\","
               << "\"status\":\"" << jsonEscape(test.status) << "\","
               << "\"diffRatio\":" << test.diffRatio << ","
               << "\"maxChannelDelta\":" << test.maxChannelDelta << ","
               << "\"millis\":" << test.millis << ","
               << "\"goldenPath\":\"" << jsonEscape(test.goldenPath) << "\","
               << "\"actualPath\":\"" << jsonEscape(test.actualPath) << "\","
               << "\"message\":\"" << jsonEscape(test.message) << "\","
               << "\"coverageDelta\":[";
        for (std::size_t coverageIndex = 0; coverageIndex < test.coverageDelta.size(); ++coverageIndex) {
            if (coverageIndex != 0) {
                stream << ",";
            }
            stream << "\"" << jsonEscape(test.coverageDelta[coverageIndex]) << "\"";
        }
        stream << "]";
        stream << "}";
    }
    stream << "]";
    stream << "}";
    return stream.str();
}

}  // namespace

std::string runGauntletJSON(std::string_view phaseFilter) {
    const std::string normalizedPhase = phaseFilter.empty() ? "phase-a" : std::string(phaseFilter);
    std::vector<TestResult> tests;

    if (normalizedPhase == "all" || normalizedPhase == "phase-a") {
        ClearReadbackScene scene;
        tests.push_back(runScene(scene));
        FramebufferDepthStencilReadbackScene framebufferScene;
        tests.push_back(runScene(framebufferScene));
        VertexInputStateScene vertexInputScene;
        tests.push_back(runScene(vertexInputScene));
        TextureSamplerStateScene textureSamplerScene;
        tests.push_back(runScene(textureSamplerScene));
        IndexUInt8ExpansionScene indexExpansionScene;
        tests.push_back(runScene(indexExpansionScene));
        ShaderProgramLifecycleScene shaderProgramScene;
        tests.push_back(runScene(shaderProgramScene));
        SolidTriangleDrawScene solidTriangleDrawScene;
        tests.push_back(runScene(solidTriangleDrawScene));
        StatePointPolygonScene statePointPolygonScene;
        tests.push_back(runScene(statePointPolygonScene));
        VertexAttribImmediateScene vertexAttribImmediateScene;
        tests.push_back(runScene(vertexAttribImmediateScene));
        TextureCompressionCopiesScene textureCompressionCopiesScene;
        tests.push_back(runScene(textureCompressionCopiesScene));
        SyncConditionalRenderScene syncConditionalRenderScene;
        tests.push_back(runScene(syncConditionalRenderScene));
        TransformFeedbackVaryingsScene transformFeedbackVaryingsScene;
        tests.push_back(runScene(transformFeedbackVaryingsScene));
        ApiSurfaceSmokeScene apiSurfaceSmokeScene;
        tests.push_back(runScene(apiSurfaceSmokeScene));
    }

    return buildJSON(normalizedPhase, tests);
}

std::size_t writeGauntletJSON(std::string_view phaseFilter, char* out, std::size_t cap) {
    const std::string payload = runGauntletJSON(phaseFilter);
    const std::size_t required = payload.size() + 1;
    if (out == nullptr || cap == 0) {
        return required;
    }

    const std::size_t bytesToCopy = std::min(required - 1, cap - 1);
    std::memcpy(out, payload.data(), bytesToCopy);
    out[bytesToCopy] = '\0';
    return required;
}

bool lastGauntletPassed() {
    return gLastGauntletPassed;
}

}  // namespace appgl::tests

extern "C" std::size_t appglRunGauntletJSON(const char* phaseFilter, char* out, std::size_t cap) {
    return appgl::tests::writeGauntletJSON(phaseFilter != nullptr ? phaseFilter : "", out, cap);
}
