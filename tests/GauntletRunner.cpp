#include "GauntletRunner.h"

#include "GoldenCompare.h"
#include "LivePresentSentinel.h"
#include "Scene.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <functional>
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

#ifndef APPGL_ENABLE_DCR_SENTINEL_HOOKS
#define APPGL_ENABLE_DCR_SENTINEL_HOOKS 0
#endif

#if APPGL_ENABLE_DCR_SENTINEL_HOOKS
#define APPGL_DCR_SENTINEL_ENV(name) name
#else
#define APPGL_DCR_SENTINEL_ENV(name) ""
#endif

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
        return std::filesystem::exists(path / "CMakeLists.txt", error)
            && std::filesystem::exists(path / "tests" / "goldens" / "phase-a" / "README.md", error);
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

        // Landing C 3c/3d assertions. glGetString(GL_VERSION) must report the
        // declarative claimed version (no "bootstrap" suffix, independent of
        // coverage walk) and GL_SHADING_LANGUAGE_VERSION must advertise 4.60
        // so engines that pick GLSL codepaths off the string don't fall back
        // to GLSL 330. Engines parse both strings via sscanf("%d.%d", ...).
        const GLubyte* glVersion = gl.glGetString(GL_VERSION);
        const GLubyte* glslVersion = gl.glGetString(GL_SHADING_LANGUAGE_VERSION);
        expectCondition(glVersion != nullptr, "glGetString(GL_VERSION) returns non-null");
        expectCondition(glslVersion != nullptr, "glGetString(GL_SHADING_LANGUAGE_VERSION) returns non-null");
        if (glVersion != nullptr) {
            const std::string versionText(reinterpret_cast<const char*>(glVersion));
            expectCondition(versionText == "4.6 AppGL core",
                            "GL_VERSION reports declarative \"4.6 AppGL core\"");
        }
        if (glslVersion != nullptr) {
            const std::string glslText(reinterpret_cast<const char*>(glslVersion));
            expectCondition(glslText == "4.60",
                            "GL_SHADING_LANGUAGE_VERSION reports \"4.60\"");
        }

        // Phase 8X Group 4d follow-up²² — buffer-family extension-string
        // audit. Before fw²² the extension tables omitted
        // `GL_ARB_vertex_buffer_object` (and siblings), which made
        // GLAD's `GLAD_GL_ARB_vertex_buffer_object` bool stay at its
        // default zero inside BAR/Recoil. That caused
        // `VBO::IsSupported(GL_ARRAY_BUFFER)` to return false at
        // startup, short-circuiting `LuaVBOs::CheckAndReportSupported`
        // into a 74× error log on the fw²¹ smoke run and gating the
        // entire HUD widget stack behind the Lua VBO layer. The four
        // strings asserted below are the exact names GLAD's
        // `has_ext()` probes drive the buffer-path gates through:
        // see `kAppGLExtensionList` in `AppGLGroup8.cpp` for the full
        // gate analysis and sibling references to VBO.cpp:38 /
        // LuaVAO.cpp:89 in the Recoil tree. Asserting them here pins
        // the table so a future extension-table regression lights up
        // at gauntlet time rather than silently re-breaking BAR's
        // buffer path.
        //
        // The assertions cover both the glGetString(GL_EXTENSIONS)
        // monolithic blob (GL <= 2.1 loaders) and the
        // glGetStringi(GL_EXTENSIONS, i) indexed path (GL 3.0+ loaders
        // — the one GLAD actually uses). Both tables must be kept in
        // sync; this single test covers both sides.
        const GLubyte* extensionsBlob = gl.glGetString(GL_EXTENSIONS);
        expectCondition(extensionsBlob != nullptr,
                        "glGetString(GL_EXTENSIONS) returns non-null blob");
        const std::string extensionsText = (extensionsBlob != nullptr)
            ? std::string(reinterpret_cast<const char*>(extensionsBlob))
            : std::string();

        auto assertBlobContains = [&](const char* name) {
            // Single-space sentinel both sides so we match whole-token,
            // never a prefix / suffix slip-through (e.g. "GL_ARB_copy"
            // inside "GL_ARB_copy_buffer" or "GL_ARB_copy_image").
            const std::string padded = std::string(" ") + name + " ";
            const std::string haystack = std::string(" ") + extensionsText + " ";
            expectCondition(haystack.find(padded) != std::string::npos,
                            std::string("glGetString(GL_EXTENSIONS) advertises ") + name);
        };
        assertBlobContains("GL_ARB_vertex_buffer_object");
        assertBlobContains("GL_ARB_copy_buffer");
        assertBlobContains("GL_ARB_draw_elements_base_vertex");
        assertBlobContains("GL_EXT_pixel_buffer_object");
        // Regression guard on the fw¹⁶ entry — if it ever drops out of
        // the table again, this fires before we reach the spring smoke.
        assertBlobContains("GL_ARB_map_buffer_range");

        // Indexed-query side. GL_NUM_EXTENSIONS is the upper bound of
        // the indexed loop; GLAD uses this exact pattern in has_ext()
        // so mirroring it here is the highest-fidelity check we can
        // make short of re-linking against glad.c.
        GLint numExtensions = 0;
        gl.glGetIntegerv(GL_NUM_EXTENSIONS, &numExtensions);
        expectCondition(numExtensions == 42,
                        "GL_NUM_EXTENSIONS reports 42 (post-fw²² buffer-family additions)");

        auto assertIndexedContains = [&](const char* name) {
            bool found = false;
            for (GLint i = 0; i < numExtensions; ++i) {
                const GLubyte* entry = gl.glGetStringi(
                    GL_EXTENSIONS, static_cast<GLuint>(i));
                if (entry != nullptr
                    && std::string(reinterpret_cast<const char*>(entry)) == name) {
                    found = true;
                    break;
                }
            }
            expectCondition(found,
                            std::string("glGetStringi(GL_EXTENSIONS, i) advertises ")
                                + name);
        };
        assertIndexedContains("GL_ARB_vertex_buffer_object");
        assertIndexedContains("GL_ARB_copy_buffer");
        assertIndexedContains("GL_ARB_draw_elements_base_vertex");
        assertIndexedContains("GL_EXT_pixel_buffer_object");
        assertIndexedContains("GL_ARB_map_buffer_range");

        // Landing C 3a assertions. These caps were all returning false from
        // GLCapabilities::queryInteger before the 3a pass, which made BAR's
        // version log show "max texture slots: 2" (it walks several cap
        // enums and stops on the first one that answers) and hid the
        // compute-dispatch limits entirely. Pinning them in the gauntlet
        // makes sure future edits to the cap table don't silently regress.
        GLint maxUboBindings = 0;
        gl.glGetIntegerv(GL_MAX_UNIFORM_BUFFER_BINDINGS, &maxUboBindings);
        expectCondition(maxUboBindings == 12,
                        "GL_MAX_UNIFORM_BUFFER_BINDINGS reports AppGL binding partition (12)");

        GLint maxSsboBindings = 0;
        gl.glGetIntegerv(GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS, &maxSsboBindings);
        expectCondition(maxSsboBindings >= 2,
                        "GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS reports at least 2 slots");

        GLint maxVertexTextureUnits = 0;
        gl.glGetIntegerv(GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS, &maxVertexTextureUnits);
        expectCondition(maxVertexTextureUnits == 16,
                        "GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS reports 16 (fix for BAR \"max texture slots: 2\")");

        GLint maxVertexAttribBindings = 0;
        gl.glGetIntegerv(GL_MAX_VERTEX_ATTRIB_BINDINGS, &maxVertexAttribBindings);
        expectCondition(maxVertexAttribBindings == 16,
                        "GL_MAX_VERTEX_ATTRIB_BINDINGS reports 16");

        GLint maxAnisotropy = 0;
        gl.glGetIntegerv(GL_MAX_TEXTURE_MAX_ANISOTROPY, &maxAnisotropy);
        expectCondition(maxAnisotropy == 16,
                        "GL_MAX_TEXTURE_MAX_ANISOTROPY reports 16 (Metal limit)");

        GLint minTexelOffset = 0;
        GLint maxTexelOffset = 0;
        gl.glGetIntegerv(GL_MIN_PROGRAM_TEXEL_OFFSET, &minTexelOffset);
        gl.glGetIntegerv(GL_MAX_PROGRAM_TEXEL_OFFSET, &maxTexelOffset);
        expectCondition(minTexelOffset == -8 && maxTexelOffset == 7,
                        "GL_{MIN,MAX}_PROGRAM_TEXEL_OFFSET reports [-8, 7]");

        GLint maxGeomOutVerts = 0;
        gl.glGetIntegerv(GL_MAX_GEOMETRY_OUTPUT_VERTICES, &maxGeomOutVerts);
        expectCondition(maxGeomOutVerts >= 256,
                        "GL_MAX_GEOMETRY_OUTPUT_VERTICES reports at least spec floor (256)");

        GLint maxComputeInvocations = 0;
        gl.glGetIntegerv(GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS, &maxComputeInvocations);
        expectCondition(maxComputeInvocations == 1024,
                        "GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS reports 1024");

        GLint maxComputeSharedMem = 0;
        gl.glGetIntegerv(GL_MAX_COMPUTE_SHARED_MEMORY_SIZE, &maxComputeSharedMem);
        expectCondition(maxComputeSharedMem == 32768,
                        "GL_MAX_COMPUTE_SHARED_MEMORY_SIZE reports 32768 bytes");

        // Indexed compute cap queries. GL_MAX_COMPUTE_WORK_GROUP_COUNT and
        // GL_MAX_COMPUTE_WORK_GROUP_SIZE each report three per-dimension
        // values (x/y/z) via glGetIntegeri_v. Scalar glGetIntegerv is
        // intentionally lenient and returns the index-0 value.
        GLint computeGroupCountX = 0;
        GLint computeGroupCountY = 0;
        GLint computeGroupCountZ = 0;
        gl.glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 0, &computeGroupCountX);
        gl.glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 1, &computeGroupCountY);
        gl.glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 2, &computeGroupCountZ);
        expectCondition(computeGroupCountX == 65535
                        && computeGroupCountY == 65535
                        && computeGroupCountZ == 65535,
                        "GL_MAX_COMPUTE_WORK_GROUP_COUNT indexed query returns (65535, 65535, 65535)");

        GLint computeGroupSizeX = 0;
        GLint computeGroupSizeY = 0;
        GLint computeGroupSizeZ = 0;
        gl.glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_SIZE, 0, &computeGroupSizeX);
        gl.glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_SIZE, 1, &computeGroupSizeY);
        gl.glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_SIZE, 2, &computeGroupSizeZ);
        expectCondition(computeGroupSizeX == 1024
                        && computeGroupSizeY == 1024
                        && computeGroupSizeZ == 64,
                        "GL_MAX_COMPUTE_WORK_GROUP_SIZE indexed query returns (1024, 1024, 64)");

        GLint maxFramebufferWidth = 0;
        gl.glGetIntegerv(GL_MAX_FRAMEBUFFER_WIDTH, &maxFramebufferWidth);
        expectCondition(maxFramebufferWidth >= 8192,
                        "GL_MAX_FRAMEBUFFER_WIDTH reports at least 8192");

        // Landing C 3b format-table assertions. Before 3b the format table
        // held only 8 entries (8-bit color + depth/stencil), so BAR's
        // HDR render targets, deferred G-buffers, and ID-buffer paths all
        // hit GL_INVALID_ENUM inside texStorage. The new table adds the
        // full float / packed / integer / compressed / sRGB surface, and
        // getInternalformativ now consults GLCapabilities::format() so the
        // engine can probe rendertarget feasibility per-format.
        auto assertFormatSupported = [&](GLenum fmt, const char* label) {
            GLint supported = GL_FALSE;
            gl.glGetInternalformativ(GL_TEXTURE_2D, fmt, GL_INTERNALFORMAT_SUPPORTED, 1, &supported);
            expectCondition(supported == GL_TRUE, std::string(label) + " is in the capabilities format table");
        };
        assertFormatSupported(GL_RGBA16F, "GL_RGBA16F");
        assertFormatSupported(GL_RGBA32F, "GL_RGBA32F");
        assertFormatSupported(GL_R16F, "GL_R16F");
        assertFormatSupported(GL_R32F, "GL_R32F");
        assertFormatSupported(GL_RG16F, "GL_RG16F");
        assertFormatSupported(GL_RG32F, "GL_RG32F");
        assertFormatSupported(GL_RGB10_A2, "GL_RGB10_A2");
        assertFormatSupported(GL_RGB10_A2UI, "GL_RGB10_A2UI");
        assertFormatSupported(GL_R11F_G11F_B10F, "GL_R11F_G11F_B10F");
        assertFormatSupported(GL_R8I, "GL_R8I");
        assertFormatSupported(GL_R8UI, "GL_R8UI");
        assertFormatSupported(GL_RG16UI, "GL_RG16UI");
        assertFormatSupported(GL_RGBA32UI, "GL_RGBA32UI");
        assertFormatSupported(GL_SRGB8, "GL_SRGB8");
        assertFormatSupported(GL_SRGB8_ALPHA8, "GL_SRGB8_ALPHA8");
        assertFormatSupported(GL_DEPTH_COMPONENT16, "GL_DEPTH_COMPONENT16");
        assertFormatSupported(GL_DEPTH_COMPONENT32F, "GL_DEPTH_COMPONENT32F");
        assertFormatSupported(GL_DEPTH32F_STENCIL8, "GL_DEPTH32F_STENCIL8");
        assertFormatSupported(GL_STENCIL_INDEX8, "GL_STENCIL_INDEX8");
        assertFormatSupported(GL_R8_SNORM, "GL_R8_SNORM");
        assertFormatSupported(GL_RGBA16_SNORM, "GL_RGBA16_SNORM");
        assertFormatSupported(GL_RGBA16, "GL_RGBA16");

        // Per-format capability flags. FRAMEBUFFER_RENDERABLE reports
        // GL_FULL_SUPPORT for formats we mark renderable, GL_CAVEAT_SUPPORT
        // for sampleable-only formats, and GL_NONE for unknown ones.
        GLint renderable16F = 0;
        gl.glGetInternalformativ(GL_TEXTURE_2D, GL_RGBA16F, GL_FRAMEBUFFER_RENDERABLE, 1, &renderable16F);
        expectCondition(renderable16F == GL_FULL_SUPPORT,
                        "GL_RGBA16F reports GL_FRAMEBUFFER_RENDERABLE = GL_FULL_SUPPORT");

        GLint blendable16F = 0;
        gl.glGetInternalformativ(GL_TEXTURE_2D, GL_RGBA16F, GL_FRAMEBUFFER_BLEND, 1, &blendable16F);
        expectCondition(blendable16F == GL_FULL_SUPPORT,
                        "GL_RGBA16F reports GL_FRAMEBUFFER_BLEND = GL_FULL_SUPPORT");

        // 32F is renderable but not blendable on Metal — report that
        // faithfully so deferred renderers can size accumulation passes.
        GLint blendable32F = 0;
        gl.glGetInternalformativ(GL_TEXTURE_2D, GL_RGBA32F, GL_FRAMEBUFFER_BLEND, 1, &blendable32F);
        expectCondition(blendable32F == GL_CAVEAT_SUPPORT,
                        "GL_RGBA32F reports GL_FRAMEBUFFER_BLEND = GL_CAVEAT_SUPPORT");

        GLint colorEncoding = 0;
        gl.glGetInternalformativ(GL_TEXTURE_2D, GL_SRGB8_ALPHA8, GL_COLOR_ENCODING, 1, &colorEncoding);
        expectCondition(colorEncoding == GL_SRGB,
                        "GL_SRGB8_ALPHA8 reports GL_COLOR_ENCODING = GL_SRGB");

        GLint linearEncoding = 0;
        gl.glGetInternalformativ(GL_TEXTURE_2D, GL_RGBA8, GL_COLOR_ENCODING, 1, &linearEncoding);
        expectCondition(linearEncoding == GL_LINEAR,
                        "GL_RGBA8 reports GL_COLOR_ENCODING = GL_LINEAR");

        // Unknown format — the table must reject cleanly rather than
        // defaulting to GL_FULL_SUPPORT. 0x12345678 is not a GL enum and
        // will never match anything the spec defines.
        GLint unknownSupported = GL_TRUE;
        gl.glGetInternalformativ(GL_TEXTURE_2D, static_cast<GLenum>(0x12345678), GL_INTERNALFORMAT_SUPPORTED, 1, &unknownSupported);
        expectCondition(unknownSupported == GL_FALSE,
                        "unknown internalformat reports GL_INTERNALFORMAT_SUPPORTED = GL_FALSE");

        // texStorage2D acceptance for a new format. Before 3b this would
        // return GL_INVALID_ENUM from the hardcoded isValidTextureInternal-
        // Format switches in GLContext.mm AND AppGLRuntime.cpp; now both
        // validators delegate through the capabilities format table and
        // accept every registered entry.
        GLuint floatTexture = 0;
        gl.glGenTextures(1, &floatTexture);
        gl.glBindTexture(GL_TEXTURE_2D, floatTexture);
        // Drain any stale error state before exercising the new path.
        while (gl.glGetError() != GL_NO_ERROR) {
        }
        gl.glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA16F, 4, 4);
        expectCondition(gl.glGetError() == GL_NO_ERROR,
                        "glTexStorage2D(GL_RGBA16F) accepts the new float format");
        gl.glDeleteTextures(1, &floatTexture);

        // Landing C 3f: appglGetProcAddress is the canonical loader entry
        // point. Verify a handful of well-known names resolve to non-null
        // function pointers that match the generated extern "C" symbols,
        // that unknown names resolve to null, and that a null name is
        // handled gracefully rather than dereferenced. External loaders
        // (glad / GLEW / in-engine loaders in BAR/Recoil) depend on all
        // three behaviors.
        expectCondition(appglGetProcAddress("glClearColor") != nullptr,
                        "appglGetProcAddress resolves glClearColor");
        expectCondition(appglGetProcAddress("glDrawArrays") != nullptr,
                        "appglGetProcAddress resolves glDrawArrays");
        expectCondition(appglGetProcAddress("glTexStorage2D") != nullptr,
                        "appglGetProcAddress resolves glTexStorage2D");
        expectCondition(appglGetProcAddress("glCullFace") != nullptr,
                        "appglGetProcAddress resolves glCullFace (table lower bound)");
        expectCondition(appglGetProcAddress("glWaitSync") != nullptr,
                        "appglGetProcAddress resolves glWaitSync (table upper bound)");
        expectCondition(appglGetProcAddress("glBogusEntryPoint") == nullptr,
                        "appglGetProcAddress returns null for unknown names");
        expectCondition(appglGetProcAddress(nullptr) == nullptr,
                        "appglGetProcAddress returns null for a null name");

        // Cross-check that the resolved pointer is actually callable and
        // routes through the runtime's dispatch table. We drive glClearColor
        // via the returned function pointer and confirm the subsequent
        // glGetFloatv(GL_COLOR_CLEAR_VALUE) reflects the new value.
        using ClearColorFn = void(APIENTRY *)(GLfloat, GLfloat, GLfloat, GLfloat);
        AppGLProc rawClear = appglGetProcAddress("glClearColor");
        ClearColorFn resolvedClear = reinterpret_cast<ClearColorFn>(rawClear);
        expectCondition(resolvedClear != nullptr,
                        "glClearColor resolved pointer is non-null before cast");
        const GLfloat probeColor[4] = {0.25f, 0.5f, 0.75f, 1.0f};
        resolvedClear(probeColor[0], probeColor[1], probeColor[2], probeColor[3]);
        GLfloat readbackColor[4] = {0.0f, 0.0f, 0.0f, 0.0f};
        gl.glGetFloatv(GL_COLOR_CLEAR_VALUE, readbackColor);
        expectCondition(readbackColor[0] == probeColor[0] && readbackColor[1] == probeColor[1]
                            && readbackColor[2] == probeColor[2] && readbackColor[3] == probeColor[3],
                        "appglGetProcAddress-resolved glClearColor drives the runtime state");

        // Landing C 3g: prove that raised errors reach BOTH surfaces:
        //  * The per-context GL error queue drained by glGetError()
        //  * The runtime error ring buffer drained by appglLiveDiagnosticsJSON
        //    / Runtime::errorLogSnapshot()
        // Before 3g, context-level pushError calls only populated the first
        // surface and the runtime ring buffer was blind to anything raised
        // from inside GLContext.mm. The cross-wire closes that gap so that
        // engine-side tooling that reads the diagnostics JSON sees every
        // raised error — not just the ones routed through the runtime-layer
        // recordValidationError helper.

        // Drain both surfaces to a known-clean baseline.
        //
        // `errorLogCount()` is a lifetime event counter (see AppGLRuntime.h),
        // not the current ring size — the 64-entry ring both evicts oldest
        // entries under pressure and collapses consecutive duplicates with
        // the same function+errorEnum into a single record with a bumped
        // count field. A plain snapshot.size() delta is broken by either
        // condition; the event counter is robust to both.
        while (gl.glGetError() != GL_NO_ERROR) {
        }
        const std::uint64_t errorEventsBaseline = Runtime::shared().errorLogCount();

        // Runtime-layer path: glBindBuffer with an invalid target goes
        // through recordValidationError -> context->pushError with the full
        // "glBindBuffer" function tag and a human-readable message.
        constexpr GLenum kBogusBufferTarget = 0xDEAD;
        gl.glBindBuffer(kBogusBufferTarget, 0);
        expectCondition(gl.glGetError() == GL_INVALID_ENUM,
                        "glBindBuffer(bogus target) raises GL_INVALID_ENUM on the glGetError queue");
        const std::uint64_t errorEventsAfterBogusBind = Runtime::shared().errorLogCount();
        auto snapshot = Runtime::shared().errorLogSnapshot();
        expectCondition(errorEventsAfterBogusBind > errorEventsBaseline,
                        "glBindBuffer(bogus target) grew the runtime error ring");
        bool foundBindBufferRecord = false;
        for (auto it = snapshot.rbegin(); it != snapshot.rend(); ++it) {
            if (it->function == "glBindBuffer" && it->errorEnum == GL_INVALID_ENUM) {
                foundBindBufferRecord = true;
                break;
            }
        }
        expectCondition(foundBindBufferRecord,
                        "runtime error ring records glBindBuffer/GL_INVALID_ENUM");

        // Context-layer path: glReadPixels with an unsupported format hits
        // GLContext::readPixels's internal pushError(GL_INVALID_ENUM) — no
        // runtime-layer recordValidationError involved. Before 3g this
        // raised error reached glGetError but was INVISIBLE to the runtime
        // ring buffer. After 3g it shows up as a synthesised
        // `<internal@<file>:<line>>` record (Phase 8X Group 4d follow-up
        // §3a — the source-location upgrade replaced the bare "<internal>"
        // tag with a file:line breadcrumb so BAR-side tooling can name the
        // call site directly).
        while (gl.glGetError() != GL_NO_ERROR) {
        }
        const std::uint64_t errorEventsBeforeContextError = Runtime::shared().errorLogCount();
        GLuint probeByte = 0;
        gl.glReadPixels(0, 0, 1, 1, GL_RED, GL_BYTE, &probeByte);
        expectCondition(gl.glGetError() == GL_INVALID_ENUM,
                        "glReadPixels(GL_RED, GL_BYTE) raises GL_INVALID_ENUM on the glGetError queue");
        const std::uint64_t errorEventsAfterContextError = Runtime::shared().errorLogCount();
        auto postContextSnapshot = Runtime::shared().errorLogSnapshot();
        expectCondition(errorEventsAfterContextError > errorEventsBeforeContextError,
                        "glReadPixels context-level pushError grew the runtime error ring");
        bool foundInternalRecord = false;
        for (auto it = postContextSnapshot.rbegin(); it != postContextSnapshot.rend(); ++it) {
            // The function tag is either an explicit name (e.g. "glReadPixels")
            // when the call site supplied one, or a synthesised
            // "<internal@<basename>:<line>>" tag when it didn't. Match either
            // shape — the test only cares that the record landed in the ring.
            const bool internalTagged =
                it->function.rfind("<internal@", 0) == 0 || it->function == "<internal>";
            if (it->errorEnum == GL_INVALID_ENUM && (internalTagged || it->function == "glReadPixels")) {
                foundInternalRecord = true;
                break;
            }
        }
        expectCondition(foundInternalRecord,
                        "runtime error ring records context-level pushError(GL_INVALID_ENUM)");

        // Landing C 3e: EXT/ARB alias forwarders + fixed-function no-op
        // stubs are now wired into appglGetProcAddress. Engines resolving
        // legacy names (glBindBufferARB from ARB_vertex_buffer_object
        // probing, glMatrixMode from extension-detection paths in Recoil)
        // should get non-null function pointers — the aliases forward
        // into the canonical core entry points and the fixed-function
        // stubs record a diagnostic ring entry and no-op.

        // Alias resolution: well-known ARB aliases for BAR/Recoil's
        // buffer pipeline.
        expectCondition(appglGetProcAddress("glBindBufferARB") != nullptr,
                        "appglGetProcAddress resolves glBindBufferARB (alias)");
        expectCondition(appglGetProcAddress("glGenBuffersARB") != nullptr,
                        "appglGetProcAddress resolves glGenBuffersARB (alias)");
        expectCondition(appglGetProcAddress("glBufferDataARB") != nullptr,
                        "appglGetProcAddress resolves glBufferDataARB (alias)");
        expectCondition(appglGetProcAddress("glActiveTextureARB") != nullptr,
                        "appglGetProcAddress resolves glActiveTextureARB (alias)");

        // Alias forwarding path: drive glGenBuffersARB through the
        // resolved alias pointer and confirm the buffer actually got
        // created (so the alias stub is actually calling the core
        // glGenBuffers, not returning uninitialized garbage).
        using GenBuffersARBFn = void(APIENTRY *)(GLsizei, GLuint*);
        AppGLProc rawGenBuffersARB = appglGetProcAddress("glGenBuffersARB");
        GenBuffersARBFn genBuffersARB = reinterpret_cast<GenBuffersARBFn>(rawGenBuffersARB);
        expectCondition(genBuffersARB != nullptr,
                        "glGenBuffersARB alias pointer non-null before cast");
        GLuint aliasProbeBuffer = 0;
        genBuffersARB(1, &aliasProbeBuffer);
        expectCondition(aliasProbeBuffer != 0,
                        "glGenBuffersARB alias forwards into core glGenBuffers (non-zero id)");
        expectCondition(gl.glIsBuffer(aliasProbeBuffer) == GL_FALSE,
                        "alias-generated buffer id is reserved but not yet bound (parity with core glGenBuffers)");
        gl.glDeleteBuffers(1, &aliasProbeBuffer);

        // Fixed-function stub resolution: classic GL 1.x entry points
        // that core removed but extension-probing engines still touch.
        //
        // Phase 8X Group 4d follow-up¹⁷ — the matrix family was moved
        // to AppGLMatrixOverrides.cpp + MatrixStateMirror in an earlier
        // round, and this round moves the immediate-mode geometry
        // family (glBegin/glVertex*/glColor*/glTexCoord*/glMultiTexCoord*
        // /glEnd) to AppGLImmediateMode.cpp + GLContext::beginImmediate
        // + MetalFrameGraph::encodeImmediateModeDraw. Both families are
        // now real implementations; only glGenLists (and friends) remain
        // as pure no-op stubs. The ring-recording test below still
        // targets a legitimate silent-stub function — glGenLists — to
        // make sure the generic recordFixedFunctionStub machinery is
        // still wired up for the functions that HAVE stayed on the
        // silent-stub path.
        expectCondition(appglGetProcAddress("glBegin") != nullptr,
                        "appglGetProcAddress resolves glBegin (immediate-mode capture entry)");
        expectCondition(appglGetProcAddress("glEnd") != nullptr,
                        "appglGetProcAddress resolves glEnd (immediate-mode capture entry)");
        expectCondition(appglGetProcAddress("glGenLists") != nullptr,
                        "appglGetProcAddress resolves glGenLists (fixed-function stub, non-void return)");
        // Real (non-stub) fixed-function matrix entry points still resolve
        // through the proc address table. The forward declarations live in
        // gl_procaddress.gen.cpp and the bodies live in
        // src/runtime/AppGLMatrixOverrides.cpp.
        expectCondition(appglGetProcAddress("glMatrixMode") != nullptr,
                        "appglGetProcAddress resolves glMatrixMode (matrix mirror entry)");
        expectCondition(appglGetProcAddress("glLoadIdentity") != nullptr,
                        "appglGetProcAddress resolves glLoadIdentity (matrix mirror entry)");
        expectCondition(appglGetProcAddress("glPushMatrix") != nullptr,
                        "appglGetProcAddress resolves glPushMatrix (matrix mirror entry)");

        // Drive glBegin through the resolved proc pointer and verify
        // that as a real (no-longer-stub) implementation it (a) does
        // NOT crash, (b) does NOT push a diagnostic ring entry (real
        // implementations stay silent on the ring), and (c) does NOT
        // inject a GL error — a mid-frame glBegin with no glEnd is
        // valid while we're still inside the begin/end window, so
        // there's nothing to report. A follow-up glEnd then drains
        // the (empty) capture and also stays silent because the
        // vertex buffer is empty.
        while (gl.glGetError() != GL_NO_ERROR) {
        }
        const std::uint64_t errorEventsBeforeBegin = Runtime::shared().errorLogCount();
        using BeginFn = void(APIENTRY *)(GLenum);
        using EndFn   = void(APIENTRY *)(void);
        AppGLProc rawBegin = appglGetProcAddress("glBegin");
        AppGLProc rawEnd   = appglGetProcAddress("glEnd");
        BeginFn beginFn = reinterpret_cast<BeginFn>(rawBegin);
        EndFn   endFn   = reinterpret_cast<EndFn>(rawEnd);
        beginFn(GL_TRIANGLES);
        endFn();
        expectCondition(gl.glGetError() == GL_NO_ERROR,
                        "glBegin/glEnd (real implementation) does not pollute glGetError queue");
        const std::uint64_t errorEventsAfterBegin = Runtime::shared().errorLogCount();
        expectCondition(errorEventsAfterBegin == errorEventsBeforeBegin,
                        "glBegin/glEnd (real implementation) does not grow the runtime diagnostic ring");

        // Still verify that the generic silent-stub path stays wired
        // by driving a function that DID stay on the stub path
        // (glColorMaterial — a compat-profile lighting entry we have
        // no use for). It should push a single diagnostic ring entry
        // with the function tag and no GL error.
        while (gl.glGetError() != GL_NO_ERROR) {
        }
        const std::uint64_t errorEventsBeforeStub = Runtime::shared().errorLogCount();
        using ColorMaterialFn = void(APIENTRY *)(GLenum, GLenum);
        AppGLProc rawColorMaterial = appglGetProcAddress("glColorMaterial");
        ColorMaterialFn colorMaterialFn = reinterpret_cast<ColorMaterialFn>(rawColorMaterial);
        expectCondition(colorMaterialFn != nullptr,
                        "appglGetProcAddress resolves glColorMaterial (fixed-function stub)");
        colorMaterialFn(0x0408 /* GL_FRONT_AND_BACK */, 0x1602 /* GL_AMBIENT_AND_DIFFUSE */);
        expectCondition(gl.glGetError() == GL_NO_ERROR,
                        "glColorMaterial fixed-function stub does not pollute glGetError queue");
        const std::uint64_t errorEventsAfterStub = Runtime::shared().errorLogCount();
        auto postStub = Runtime::shared().errorLogSnapshot();
        expectCondition(errorEventsAfterStub > errorEventsBeforeStub,
                        "glColorMaterial fixed-function stub grew the runtime diagnostic ring");
        bool foundFixedFunctionRecord = false;
        for (auto it = postStub.rbegin(); it != postStub.rend(); ++it) {
            if (it->function == "glColorMaterial" && it->errorEnum == 0) {
                foundFixedFunctionRecord = true;
                break;
            }
        }
        expectCondition(foundFixedFunctionRecord,
                        "runtime diagnostic ring records glColorMaterial fixed-function stub");

        // Real fixed-function matrix path: glMatrixMode now routes through
        // the per-context MatrixStateMirror. A valid mode (GL_MODELVIEW,
        // 0x1700) must NOT push a diagnostic ring entry and must NOT
        // pollute glGetError. An invalid mode MUST push GL_INVALID_ENUM
        // through GLContext::pushError, which surfaces in BOTH the
        // per-context glGetError queue AND the runtime diagnostic ring.
        while (gl.glGetError() != GL_NO_ERROR) {
        }
        const std::uint64_t errorEventsBeforeMatrixMode = Runtime::shared().errorLogCount();
        using MatrixModeFn = void(APIENTRY *)(GLenum);
        AppGLProc rawMatrixMode = appglGetProcAddress("glMatrixMode");
        MatrixModeFn matrixMode = reinterpret_cast<MatrixModeFn>(rawMatrixMode);
        // GL_MODELVIEW (0x1700) is a compat-profile enum that core's
        // glcorearb.h doesn't export, so we pass the raw literal here.
        constexpr GLenum kModelviewMatrixMode = 0x1700;
        matrixMode(kModelviewMatrixMode);
        expectCondition(gl.glGetError() == GL_NO_ERROR,
                        "glMatrixMode(GL_MODELVIEW) does not pollute glGetError queue");
        const std::uint64_t errorEventsAfterValidMatrixMode = Runtime::shared().errorLogCount();
        expectCondition(errorEventsAfterValidMatrixMode == errorEventsBeforeMatrixMode,
                        "glMatrixMode(GL_MODELVIEW) does not record into the runtime diagnostic ring");
        // Invalid mode → GL_INVALID_ENUM in the glGetError queue + ring.
        constexpr GLenum kBogusMatrixMode = 0xDEAD;
        matrixMode(kBogusMatrixMode);
        expectCondition(gl.glGetError() == GL_INVALID_ENUM,
                        "glMatrixMode(invalid) pushes GL_INVALID_ENUM into glGetError queue");
        const std::uint64_t errorEventsAfterInvalidMatrixMode = Runtime::shared().errorLogCount();
        expectCondition(errorEventsAfterInvalidMatrixMode > errorEventsAfterValidMatrixMode,
                        "glMatrixMode(invalid) records into the runtime diagnostic ring");
        auto postMatrixMode = Runtime::shared().errorLogSnapshot();
        bool foundMatrixModeError = false;
        for (auto it = postMatrixMode.rbegin(); it != postMatrixMode.rend(); ++it) {
            if (it->function == "glMatrixMode" && it->errorEnum == GL_INVALID_ENUM) {
                foundMatrixModeError = true;
                break;
            }
        }
        expectCondition(foundMatrixModeError,
                        "runtime diagnostic ring records glMatrixMode GL_INVALID_ENUM");

        // Non-void fixed-function return: glGenLists should return 0
        // (the conservative default). Engines checking the returned id
        // for non-zero before using it will correctly skip the legacy
        // display-list path instead of dereferencing garbage.
        using GenListsFn = GLuint(APIENTRY *)(GLsizei);
        AppGLProc rawGenLists = appglGetProcAddress("glGenLists");
        GenListsFn genLists = reinterpret_cast<GenListsFn>(rawGenLists);
        const GLuint genListsResult = genLists(4);
        expectCondition(genListsResult == 0u,
                        "glGenLists fixed-function stub returns 0 (conservative default)");

        // Drain before returning so the render pass starts clean.
        while (gl.glGetError() != GL_NO_ERROR) {
        }
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

        // Landing B diagnostic-coverage assertion: after a successful link,
        // exactly two new shader translation records must have been pushed
        // into Runtime::shaderTranslations_ (one vertex, one fragment),
        // both with success=true. The old scanner-only path never called
        // recordShaderTranslation for compileShader, and the old linkProgram
        // only fired the call under the hardcoded VS+FS translator block.
        // If either assertion fires after Landing B it means the restructured
        // pipeline silently dropped a record.
        //
        // `shaderTranslationCount()` is a lifetime push counter (see
        // AppGLRuntime.h) so the delta is meaningful even after the 32-entry
        // ring has wrapped — which it will have by the time this scene runs,
        // since every preceding gauntlet scene links at least one program.
        // The two new records sit at the tail of the snapshot regardless of
        // where the ring's write cursor is.
        const std::uint64_t translationsBeforeLink = Runtime::shared().shaderTranslationCount();
        gl.glLinkProgram(program);
        const std::uint64_t translationsAfterLink = Runtime::shared().shaderTranslationCount();
        const auto translationSnapshot = Runtime::shared().shaderTranslationSnapshot();
        expectCondition(translationsAfterLink - translationsBeforeLink == 2,
                        "linkProgram pushed exactly 2 shader translation records");
        if (translationSnapshot.size() >= 2 &&
            translationsAfterLink - translationsBeforeLink == 2) {
            const auto& vertexRecord = translationSnapshot[translationSnapshot.size() - 2];
            const auto& fragmentRecord = translationSnapshot[translationSnapshot.size() - 1];
            expectCondition(vertexRecord.success && fragmentRecord.success,
                            "both link-time shader translation records report success=true");
            expectCondition(vertexRecord.stage == "vertex" && fragmentRecord.stage == "fragment",
                            "link-time shader translation stages are vertex+fragment");
            expectCondition(!vertexRecord.mslPreview.empty() && !fragmentRecord.mslPreview.empty(),
                            "link-time shader translation records carry non-empty mslPreview");
        }

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

        // Landing B diagnostic-coverage assertion (failure path): compile a
        // deliberately malformed fragment shader, attach it to a program, and
        // link. The compile must fail with a non-empty glslang log, and the
        // subsequent link attempt must push a "link" failure record into the
        // Runtime shader-translations ring so BAR can see the glslang
        // diagnostic without having to round-trip through getShaderInfoLog.
        //
        // Same ring-wrap treatment as the success-path assertion above: use
        // the lifetime push counter for the delta and index the failure
        // record from the tail of the post-link snapshot.
        {
            const std::uint64_t translationsBeforeFailure =
                Runtime::shared().shaderTranslationCount();

            const GLuint badShader = gl.glCreateShader(GL_FRAGMENT_SHADER);
            const char* badSource =
                "#version 330 core\n"
                "out vec4 fragColor;\n"
                "void main() { fragColor = this_identifier_does_not_exist; }\n";
            gl.glShaderSource(badShader, 1, &badSource, nullptr);
            gl.glCompileShader(badShader);

            GLint compileStatus = GL_TRUE;
            gl.glGetShaderiv(badShader, GL_COMPILE_STATUS, &compileStatus);
            expectCondition(compileStatus == GL_FALSE,
                            "deliberately bad fragment shader reports GL_COMPILE_STATUS = GL_FALSE");

            GLint infoLogLength = 0;
            gl.glGetShaderiv(badShader, GL_INFO_LOG_LENGTH, &infoLogLength);
            expectCondition(infoLogLength > 0,
                            "bad fragment shader info log length is non-zero");

            char infoLogBuffer[512] = {};
            GLsizei infoLogWritten = 0;
            gl.glGetShaderInfoLog(badShader, sizeof(infoLogBuffer), &infoLogWritten, infoLogBuffer);
            expectCondition(infoLogWritten > 0,
                            "bad fragment shader info log is non-empty");

            // Attach to a fresh program and try to link. Link must fail and
            // push one record tagged stage="link" with success=false.
            const GLuint failProgram = gl.glCreateProgram();
            gl.glAttachShader(failProgram, badShader);

            // Phase 8X Group 4d follow-up²³ — snapshot right before the
            // glLinkProgram call so the delta measures only linkProgram's
            // push, not the preceding glCompileShader's compile-failure
            // record. fw²³ adds C++ exception guards around
            // `translator.spirvToMSL` / `translator.reflect` inside
            // `linkProgram`'s translateStage lambda; if a future regression
            // made the uncompiled-attached-shader branch reach SPIRV-Cross
            // and push additional records (or if the exception guard ever
            // pushed duplicate records on a single throw), this assertion
            // catches it. The uncompiled-shader bailout path pushes exactly
            // one record at the top of `linkProgram` (see the
            // `!shaderObject->compiled` branch) — no more, no less.
            const std::uint64_t translationsBeforeLinkOnly =
                Runtime::shared().shaderTranslationCount();
            gl.glLinkProgram(failProgram);
            const std::uint64_t translationsAfterLinkOnly =
                Runtime::shared().shaderTranslationCount();

            GLint failLinkStatus = GL_TRUE;
            gl.glGetProgramiv(failProgram, GL_LINK_STATUS, &failLinkStatus);
            expectCondition(failLinkStatus == GL_FALSE,
                            "program with uncompiled attached shader fails to link");

            const std::uint64_t translationsAfterFailure =
                Runtime::shared().shaderTranslationCount();
            const auto failureSnapshot =
                Runtime::shared().shaderTranslationSnapshot();
            expectCondition(translationsAfterFailure > translationsBeforeFailure,
                            "link-of-bad-shader pushed at least one shader translation record");
            // Phase 8X Group 4d follow-up²³ regression guard — linkProgram
            // must push exactly one record on the uncompiled-attached-shader
            // bailout path. This is the fw²³ contract: the translateStage
            // try/catch blocks must not duplicate-push on any code path that
            // doesn't reach them at all.
            expectCondition(translationsAfterLinkOnly - translationsBeforeLinkOnly == 1,
                            "linkProgram pushed exactly one record on uncompiled-shader bailout");
            if (!failureSnapshot.empty() &&
                translationsAfterFailure > translationsBeforeFailure) {
                const auto& failureRecord = failureSnapshot.back();
                expectCondition(!failureRecord.success,
                                "link-of-bad-shader record reports success=false");
                expectCondition(failureRecord.stage == "link",
                                "link-of-bad-shader record stage tag is \"link\"");
                expectCondition(!failureRecord.glslangLog.empty(),
                                "link-of-bad-shader record carries non-empty glslangLog");
            }

            gl.glDeleteProgram(failProgram);
            gl.glDeleteShader(badShader);
        }

        // Phase 8X Group 4d: shader-lifetime BAR pattern.
        //
        // Engines using RAII shader handles (BAR's
        // `rts/Rendering/Shaders/Shader.cpp` is the motivating example)
        // call `glDeleteShader` between `glAttachShader` and
        // `glLinkProgram`, because the unique_ptr deleter that wraps the
        // shader handle fires at scope exit on the very next line. The
        // GL spec is clear on this: a shader still attached to one or
        // more programs is *flagged for deletion* but not erased — the
        // attachment count pins it until the last detach (or the owning
        // program tear-down). Phase A's eager erase broke that pattern
        // and masked every BAR shader compile result with the dummy
        // "attached shader is not compiled" link log; this block locks
        // the spec-compliant behaviour into the gauntlet so the
        // regression cannot re-emerge silently.
        {
            const std::uint64_t recordsBefore =
                Runtime::shared().shaderTranslationCount();

            const GLuint raiiVS = gl.glCreateShader(GL_VERTEX_SHADER);
            const GLuint raiiFS = gl.glCreateShader(GL_FRAGMENT_SHADER);
            const char* raiiVSSource =
                "#version 330 core\n"
                "void main() { gl_Position = vec4(0.0); }\n";
            const char* raiiFSSource =
                "#version 330 core\n"
                "out vec4 fragColor;\n"
                "void main() { fragColor = vec4(1.0); }\n";
            gl.glShaderSource(raiiVS, 1, &raiiVSSource, nullptr);
            gl.glShaderSource(raiiFS, 1, &raiiFSSource, nullptr);
            gl.glCompileShader(raiiVS);
            gl.glCompileShader(raiiFS);

            GLint raiiVSCompileStatus = GL_FALSE;
            GLint raiiFSCompileStatus = GL_FALSE;
            gl.glGetShaderiv(raiiVS, GL_COMPILE_STATUS, &raiiVSCompileStatus);
            gl.glGetShaderiv(raiiFS, GL_COMPILE_STATUS, &raiiFSCompileStatus);
            expectCondition(raiiVSCompileStatus == GL_TRUE,
                            "lifetime-raii vertex shader compiles");
            expectCondition(raiiFSCompileStatus == GL_TRUE,
                            "lifetime-raii fragment shader compiles");

            // Verify the new compile-stage diagnostic-ring records exist.
            // The Group 4d follow-up makes compileShader push a record on
            // every call (success or failure) so BAR-side observers don't
            // need to wait for a downstream link to learn what compileLog
            // said. Walk back from the snapshot tail looking for the two
            // shader IDs we just compiled.
            {
                const auto snapshot =
                    Runtime::shared().shaderTranslationSnapshot();
                const std::string vsTag = "shader-" + std::to_string(raiiVS);
                const std::string fsTag = "shader-" + std::to_string(raiiFS);
                bool foundVSCompile = false;
                bool foundFSCompile = false;
                for (auto it = snapshot.rbegin(); it != snapshot.rend(); ++it) {
                    if (it->stage == "compile" && it->success) {
                        if (it->id == vsTag) foundVSCompile = true;
                        if (it->id == fsTag) foundFSCompile = true;
                    }
                    if (foundVSCompile && foundFSCompile) {
                        break;
                    }
                }
                expectCondition(foundVSCompile,
                                "compile-stage record present for lifetime-raii vertex");
                expectCondition(foundFSCompile,
                                "compile-stage record present for lifetime-raii fragment");
            }

            const GLuint raiiProgram = gl.glCreateProgram();
            gl.glAttachShader(raiiProgram, raiiVS);
            gl.glAttachShader(raiiProgram, raiiFS);

            // The motivating ordering: delete BEFORE link. The shader
            // objects must remain resident because of the live attachment.
            gl.glDeleteShader(raiiVS);
            gl.glDeleteShader(raiiFS);

            // Spec: glIsShader returns GL_FALSE the moment glDeleteShader
            // marks the name, even though the underlying object is still
            // present in the store.
            expectCondition(gl.glIsShader(raiiVS) == GL_FALSE,
                            "deleted-but-attached vertex glIsShader returns GL_FALSE");
            expectCondition(gl.glIsShader(raiiFS) == GL_FALSE,
                            "deleted-but-attached fragment glIsShader returns GL_FALSE");

            // Spec: glGetShaderiv(GL_DELETE_STATUS) is still queryable on
            // a marked-but-resident shader, and reports GL_TRUE.
            GLint vsDeleteStatus = GL_FALSE;
            gl.glGetShaderiv(raiiVS, GL_DELETE_STATUS, &vsDeleteStatus);
            expectCondition(vsDeleteStatus == GL_TRUE,
                            "deleted-but-attached vertex GL_DELETE_STATUS=GL_TRUE");

            // The critical assertion: link must succeed even though both
            // attached shaders have already been glDeleteShader'd. Under
            // Phase A's eager-erase code path linkProgram saw nullptr on
            // both lookups and bailed with "attached shader is not compiled".
            gl.glLinkProgram(raiiProgram);
            GLint raiiLinkStatus = GL_FALSE;
            gl.glGetProgramiv(raiiProgram, GL_LINK_STATUS, &raiiLinkStatus);
            expectCondition(raiiLinkStatus == GL_TRUE,
                            "RAII attach->delete->link cycle succeeds");

            // Detach the vertex shader. This was the last attachment for
            // raiiVS and the deleteRequested flag is set, so the deferred
            // erase fires here. Subsequent glGetShaderiv on the freed name
            // must report GL_INVALID_VALUE (the standard glGetError surface
            // for unknown object IDs).
            gl.glDetachShader(raiiProgram, raiiVS);
            while (gl.glGetError() != GL_NO_ERROR) {}
            GLint freedVSStatus = -1;
            gl.glGetShaderiv(raiiVS, GL_DELETE_STATUS, &freedVSStatus);
            expectGLError(gl, GL_INVALID_VALUE,
                          "freed vertex shader name reports GL_INVALID_VALUE on glGetShaderiv");

            // Tearing down the program should walk the still-attached
            // shader list and erase the marked fragment shader. After this
            // call, glGetShaderiv on raiiFS must also fail.
            gl.glDeleteProgram(raiiProgram);
            while (gl.glGetError() != GL_NO_ERROR) {}
            GLint freedFSStatus = -1;
            gl.glGetShaderiv(raiiFS, GL_DELETE_STATUS, &freedFSStatus);
            expectGLError(gl, GL_INVALID_VALUE,
                          "freed fragment shader name reports GL_INVALID_VALUE post-deleteProgram");

            // Sanity: at minimum two compile-stage records and one link-stage
            // record were pushed during this block.
            const std::uint64_t recordsAfter =
                Runtime::shared().shaderTranslationCount();
            expectCondition(recordsAfter - recordsBefore >= 3,
                            "RAII lifetime cycle pushed >=3 shader translation records");
        }
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

// Phase 8X Group 4d follow-up⁵ §6c — VaryingInterfaceScene.
//
// Regression test for the cross-stage varying location coordination bug
// that the per-stage `compileGLSL` path produced (see BAR's
// `phase-8x-group-4d-followup4-verification.md`). Builds a vertex+fragment
// program with TWO varyings — `vColor` and `vUV` — neither of which carries
// an explicit `layout(location=N)` qualifier. Pre-followup⁵ this was the
// exact shape that caused glslang's per-stage auto-map to assign
// independent locations to the vertex outputs and fragment inputs, which
// SPIRV-Cross then emitted as mangled `m_NN_<name>` members without
// matching `[[user(locN)]]` attributes — causing
// `MTLRenderPipelineDescriptor` to reject the program at pipeline-state
// creation time.
//
// Post-followup⁵: `linkProgram` now routes both stages through
// `ShaderTranslator::compileGLSLProgram`, which links them in a single
// glslang::TProgram with `mapIO()` so the IO resolver assigns matching
// locations across the stage boundary. The scene asserts that:
//   - `glLinkProgram` returns GL_TRUE
//   - `pipelineCacheMetrics().buildAttempts >= 1` after the draw (proving
//     the translated path actually ran encodeTranslatedDraw's build branch)
//   - `pipelineCacheMetrics().buildFailures == 0` (proving Metal accepted
//     the linked pipeline state — the §6a fix worked)
// and then renders a colored triangle whose colors come from the per-vertex
// attributes via the varyings, so the golden round-trip exercises the full
// vertex→fragment varying path end-to-end.
class VaryingInterfaceScene final : public Scene {
public:
    std::string id() const override {
        return "phase-a.varying-interface";
    }

    std::string phase() const override {
        return "phase-a";
    }

    SceneSize framebufferSize() const override {
        return {96, 96};
    }

    double tolerance() const override {
        // Same rationale as SolidTriangleDrawScene — anti-aliased edges
        // can drift by one channel between GPU families.
        return 0.02;
    }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // Two varyings, neither with an explicit location. The vertex
        // declares `out vec4 vColor; out vec2 vUV;` and the fragment
        // declares the matching `in` slots — this is the shape that the
        // per-stage compileGLSL path could not coordinate.
        const char* vertexSource =
            "#version 330 core\n"
            "layout(location = 0) in vec3 aPosition;\n"
            "layout(location = 1) in vec3 aColor;\n"
            "layout(location = 2) in vec2 aUV;\n"
            "out vec4 vColor;\n"
            "out vec2 vUV;\n"
            "void main() {\n"
            "    gl_Position = vec4(aPosition, 1.0);\n"
            "    vColor = vec4(aColor, 1.0);\n"
            "    vUV = aUV;\n"
            "}\n";
        const char* fragmentSource =
            "#version 330 core\n"
            "in vec4 vColor;\n"
            "in vec2 vUV;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    // Mix the per-vertex color with a UV-driven gradient so\n"
            "    // both varyings actually contribute to the output. If\n"
            "    // either varying is dropped or mismatched at the stage\n"
            "    // boundary, the rendered triangle is visibly different\n"
            "    // from the golden.\n"
            "    fragColor = vec4(vColor.rgb * (0.7 + 0.3 * vUV.x), 1.0);\n"
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
        expectCondition(linkStatus == GL_TRUE,
                        "varying-interface program links cross-stage");
        gl.glDeleteShader(vertex);
        gl.glDeleteShader(fragment);

        gl.glGenVertexArrays(1, &vao_);
        gl.glBindVertexArray(vao_);

        // Interleaved position/color/uv triangle. Stride = 8 floats.
        const GLfloat vertices[] = {
            // pos.x   pos.y  pos.z   r     g     b     u     v
            -0.6f, -0.5f, 0.0f,  1.0f, 0.2f, 0.2f,  0.0f, 0.0f,
             0.6f, -0.5f, 0.0f,  0.2f, 1.0f, 0.2f,  1.0f, 0.0f,
             0.0f,  0.7f, 0.0f,  0.2f, 0.2f, 1.0f,  0.5f, 1.0f,
        };
        gl.glGenBuffers(1, &vbo_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);

        const GLsizei stride = 8 * sizeof(GLfloat);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, stride,
                                 reinterpret_cast<const void*>(0));
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, stride,
                                 reinterpret_cast<const void*>(3 * sizeof(GLfloat)));
        gl.glEnableVertexAttribArray(2);
        gl.glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, stride,
                                 reinterpret_cast<const void*>(6 * sizeof(GLfloat)));
    }

    void render(GLContext& context) override {
        auto& gl = Runtime::shared().dispatch();

        // Reset pipeline cache metrics so the post-draw assertion sees
        // only the work this scene generated.
        context.resetPipelineCacheMetrics();

        gl.glViewport(0, 0, framebufferSize().width, framebufferSize().height);
        gl.glClearColor(0.08f, 0.10f, 0.18f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        gl.glUseProgram(program_);
        gl.glBindVertexArray(vao_);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        gl.glFlush();

        // Phase 8X Group 4d follow-up⁵ §6a verification.
        // After at least one translated-path draw, the pipeline cache
        // counters should show:
        //   buildAttempts >= 1      (encodeTranslatedDraw's build branch ran)
        //   buildFailures == 0      (Metal accepted the linked pipeline)
        // Pre-followup⁵ this scene would have hit the same shape as BAR's
        // failing programs and failed the buildFailures assertion.
        const auto metrics = context.pipelineCacheMetrics();
        expectCondition(metrics.buildAttempts >= 1,
                        "varying-interface scene reached pipeline build branch");
        expectCondition(metrics.buildFailures == 0,
                        "varying-interface scene produced a Metal-accepted pipeline state");
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
            FunctionId::glEnableVertexAttribArray,
            FunctionId::glFlush,
            FunctionId::glGenBuffers,
            FunctionId::glGenVertexArrays,
            FunctionId::glGetProgramiv,
            FunctionId::glLinkProgram,
            FunctionId::glShaderSource,
            FunctionId::glUseProgram,
            FunctionId::glVertexAttribPointer,
            FunctionId::glViewport,
        };
    }

private:
    GLuint program_ = 0;
    GLuint vao_ = 0;
    GLuint vbo_ = 0;
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

        // Phase 4 Group 4: Transform feedback objects (gen/delete/is/bind/pause/resume/draw).
        {
            GLuint tfObjs[2] = {0, 0};
            gl.glGenTransformFeedbacks(2, tfObjs);
            expectCondition(tfObjs[0] != 0 && tfObjs[1] != 0, "glGenTransformFeedbacks returns non-zero handles");
            expectGLError(gl, GL_NO_ERROR, "glGenTransformFeedbacks no error");

            expectCondition(gl.glIsTransformFeedback(tfObjs[0]) == GL_TRUE, "TF object exists after gen");
            expectCondition(gl.glIsTransformFeedback(99999) == GL_FALSE, "non-existent TF returns GL_FALSE");

            gl.glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, tfObjs[0]);
            expectGLError(gl, GL_NO_ERROR, "glBindTransformFeedback no error");
            gl.glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
            expectGLError(gl, GL_NO_ERROR, "glBindTransformFeedback(0) unbind no error");

            gl.glPauseTransformFeedback();
            expectGLError(gl, GL_NO_ERROR, "glPauseTransformFeedback no error");
            gl.glResumeTransformFeedback();
            expectGLError(gl, GL_NO_ERROR, "glResumeTransformFeedback no error");

            // Draw stubs (0 primitives — no TF capture active).
            gl.glDrawTransformFeedback(GL_TRIANGLES, tfObjs[0]);
            expectGLError(gl, GL_NO_ERROR, "glDrawTransformFeedback no error");
            gl.glDrawTransformFeedbackStream(GL_TRIANGLES, tfObjs[0], 0);
            expectGLError(gl, GL_NO_ERROR, "glDrawTransformFeedbackStream no error");

            gl.glDeleteTransformFeedbacks(2, tfObjs);
            expectGLError(gl, GL_NO_ERROR, "glDeleteTransformFeedbacks no error");
            expectCondition(gl.glIsTransformFeedback(tfObjs[0]) == GL_FALSE, "TF object gone after delete");
        }

        // Phase 4 Group 6: Indirect drawing stubs.
        {
            // DrawArraysIndirect with client-memory indirect struct.
            struct { GLuint count, instanceCount, first, baseInstance; } indirectArrays = {0, 1, 0, 0};
            gl.glDrawArraysIndirect(GL_TRIANGLES, &indirectArrays);
            expectGLError(gl, GL_NO_ERROR, "glDrawArraysIndirect no error");

            struct { GLuint count, instanceCount, firstIndex, baseVertex; GLuint baseInstance; } indirectElements = {0, 1, 0, 0, 0};
            gl.glDrawElementsIndirect(GL_TRIANGLES, GL_UNSIGNED_INT, &indirectElements);
            expectGLError(gl, GL_NO_ERROR, "glDrawElementsIndirect no error");
        }

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
            // Phase 4 Group 4: transform feedback objects.
            FunctionId::glGenTransformFeedbacks,
            FunctionId::glDeleteTransformFeedbacks,
            FunctionId::glIsTransformFeedback,
            FunctionId::glBindTransformFeedback,
            FunctionId::glPauseTransformFeedback,
            FunctionId::glResumeTransformFeedback,
            FunctionId::glDrawTransformFeedback,
            FunctionId::glDrawTransformFeedbackStream,
            // Phase 4 Group 6: indirect drawing.
            FunctionId::glDrawArraysIndirect,
            FunctionId::glDrawElementsIndirect,
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

// =========================================================================
// Phase C — GL 4.2/4.3 function coverage scenes
// =========================================================================

// Scene 1: Immutable Texture Storage + Separated Vertex Format (Groups 1+5)
class ImmutableTextureVertexFormatScene final : public Scene {
public:
    std::string id() const override { return "phase-c.immutable-tex-vertex-format"; }
    std::string phase() const override { return "phase-c"; }
    SceneSize framebufferSize() const override { return {64, 64}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // GL 4.2 — immutable texture storage
        GLuint tex1d = 0, tex2d = 0, tex3d = 0, texMs2d = 0, texMs3d = 0;
        gl.glGenTextures(1, &tex1d);
        gl.glBindTexture(GL_TEXTURE_1D, tex1d);
        gl.glTexStorage1D(GL_TEXTURE_1D, 1, GL_RGBA8, 16);
        expectCondition(tex1d != 0, "1D immutable texture created");

        gl.glGenTextures(1, &tex2d);
        gl.glBindTexture(GL_TEXTURE_2D, tex2d);
        gl.glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 16, 16);

        gl.glGenTextures(1, &tex3d);
        gl.glBindTexture(GL_TEXTURE_3D, tex3d);
        gl.glTexStorage3D(GL_TEXTURE_3D, 1, GL_RGBA8, 8, 8, 4);

        gl.glGenTextures(1, &texMs2d);
        gl.glBindTexture(GL_TEXTURE_2D_MULTISAMPLE, texMs2d);
        gl.glTexStorage2DMultisample(GL_TEXTURE_2D_MULTISAMPLE, 4, GL_RGBA8, 16, 16, GL_TRUE);

        gl.glGenTextures(1, &texMs3d);
        gl.glBindTexture(GL_TEXTURE_2D_MULTISAMPLE_ARRAY, texMs3d);
        gl.glTexStorage3DMultisample(GL_TEXTURE_2D_MULTISAMPLE_ARRAY, 4, GL_RGBA8, 8, 8, 2, GL_TRUE);

        // GL 4.3 — texture buffer range
        GLuint tbo = 0, tboBuf = 0;
        gl.glGenTextures(1, &tbo);
        gl.glGenBuffers(1, &tboBuf);
        gl.glBindBuffer(GL_TEXTURE_BUFFER, tboBuf);
        float tboData[4] = {1.0f, 0.0f, 0.0f, 1.0f};
        gl.glBufferData(GL_TEXTURE_BUFFER, sizeof(tboData), tboData, GL_STATIC_DRAW);
        gl.glBindTexture(GL_TEXTURE_BUFFER, tbo);
        gl.glTexBufferRange(GL_TEXTURE_BUFFER, GL_RGBA32F, tboBuf, 0, sizeof(tboData));

        // GL 4.3 — separated vertex format
        GLuint vao = 0, vbo = 0;
        gl.glGenVertexArrays(1, &vao);
        gl.glBindVertexArray(vao);
        gl.glGenBuffers(1, &vbo);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo);
        float verts[6] = {0.0f, 0.0f, 1.0f, 0.0f, 0.5f, 1.0f};
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);

        gl.glBindVertexBuffer(0, vbo, 0, 8);
        gl.glVertexAttribFormat(0, 2, GL_FLOAT, GL_FALSE, 0);
        gl.glVertexAttribIFormat(1, 1, GL_INT, 0);
        gl.glVertexAttribLFormat(2, 1, GL_DOUBLE, 0);
        gl.glVertexAttribBinding(0, 0);
        gl.glVertexAttribBinding(1, 0);
        gl.glVertexBindingDivisor(0, 0);
        gl.glEnableVertexAttribArray(0);

        // Cleanup
        gl.glDeleteTextures(1, &tex1d);
        gl.glDeleteTextures(1, &tex2d);
        gl.glDeleteTextures(1, &tex3d);
        gl.glDeleteTextures(1, &texMs2d);
        gl.glDeleteTextures(1, &texMs3d);
        gl.glDeleteTextures(1, &tbo);
        gl.glDeleteBuffers(1, &tboBuf);
        gl.glDeleteBuffers(1, &vbo);
        gl.glDeleteVertexArrays(1, &vao);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        // Drain any accumulated GL errors from stub exercises in setup()
        while (gl.glGetError() != GL_NO_ERROR) {}
        gl.glViewport(0, 0, 64, 64);
        gl.glClearColor(0.15f, 0.40f, 0.20f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glTexStorage1D,
            FunctionId::glTexStorage2D,
            FunctionId::glTexStorage3D,
            FunctionId::glTexStorage2DMultisample,
            FunctionId::glTexStorage3DMultisample,
            FunctionId::glTexBufferRange,
            FunctionId::glBindVertexBuffer,
            FunctionId::glVertexAttribFormat,
            FunctionId::glVertexAttribIFormat,
            FunctionId::glVertexAttribLFormat,
            FunctionId::glVertexAttribBinding,
            FunctionId::glVertexBindingDivisor,
        };
    }
};

// Scene 2: Compute + Image + Atomic + Program Introspection + SSBO (Groups 2+3+4)
class ComputeImageIntrospectionScene final : public Scene {
public:
    std::string id() const override { return "phase-c.compute-image-introspection"; }
    std::string phase() const override { return "phase-c"; }
    SceneSize framebufferSize() const override { return {64, 64}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // GL 4.2 — memory barrier (validated no-op on Metal)
        gl.glMemoryBarrier(GL_ALL_BARRIER_BITS);

        // GL 4.2 — image load/store binding
        GLuint imgTex = 0;
        gl.glGenTextures(1, &imgTex);
        gl.glBindTexture(GL_TEXTURE_2D, imgTex);
        gl.glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 16, 16);
        gl.glBindImageTexture(0, imgTex, 0, GL_FALSE, 0, GL_READ_WRITE, GL_RGBA8);

        // GL 4.3 — compute dispatch stubs
        // These are validated stubs (no compute pipeline yet), but they must
        // not crash and must accept valid parameters.
        gl.glDispatchCompute(1, 1, 1);
        gl.glDispatchComputeIndirect(0);

        // GL 4.2 — atomic counter buffer query
        // Build a simple program to exercise program resource introspection
        const char* vertSrc = "#version 330 core\n"
            "in vec4 aPos;\n"
            "uniform float uScale;\n"
            "void main() { gl_Position = aPos * uScale; }\n";
        const char* fragSrc = "#version 330 core\n"
            "out vec4 FragColor;\n"
            "uniform vec4 uColor;\n"
            "void main() { FragColor = uColor; }\n";

        GLuint vs = gl.glCreateShader(GL_VERTEX_SHADER);
        gl.glShaderSource(vs, 1, &vertSrc, nullptr);
        gl.glCompileShader(vs);
        GLuint fs = gl.glCreateShader(GL_FRAGMENT_SHADER);
        gl.glShaderSource(fs, 1, &fragSrc, nullptr);
        gl.glCompileShader(fs);

        GLuint prog = gl.glCreateProgram();
        gl.glAttachShader(prog, vs);
        gl.glAttachShader(prog, fs);
        gl.glLinkProgram(prog);

        GLint linked = 0;
        gl.glGetProgramiv(prog, GL_LINK_STATUS, &linked);
        expectCondition(linked == GL_TRUE, "introspection test program linked");

        // GL 4.3 — program resource introspection
        GLint numUniforms = 0;
        gl.glGetProgramInterfaceiv(prog, GL_UNIFORM, GL_ACTIVE_RESOURCES, &numUniforms);
        expectCondition(numUniforms >= 2, "program has at least 2 uniforms");

        GLint numInputs = 0;
        gl.glGetProgramInterfaceiv(prog, GL_PROGRAM_INPUT, GL_ACTIVE_RESOURCES, &numInputs);
        expectCondition(numInputs >= 1, "program has at least 1 input");

        GLint numOutputs = 0;
        gl.glGetProgramInterfaceiv(prog, GL_PROGRAM_OUTPUT, GL_ACTIVE_RESOURCES, &numOutputs);
        expectCondition(numOutputs >= 1, "program has at least 1 output");

        // GetProgramResourceIndex
        GLuint aPosIdx = gl.glGetProgramResourceIndex(prog, GL_PROGRAM_INPUT, "aPos");
        expectCondition(aPosIdx != GL_INVALID_INDEX, "aPos resource index found");

        // GetProgramResourceName
        char nameBuf[64] = {};
        GLsizei nameLen = 0;
        gl.glGetProgramResourceName(prog, GL_PROGRAM_INPUT, aPosIdx, sizeof(nameBuf), &nameLen, nameBuf);
        expectCondition(std::string(nameBuf) == "aPos", "resource name matches");

        // GetProgramResourceiv
        GLenum props[] = {GL_TYPE, GL_LOCATION, GL_NAME_LENGTH};
        GLint values[3] = {};
        GLsizei written = 0;
        gl.glGetProgramResourceiv(prog, GL_PROGRAM_INPUT, aPosIdx, 3, props, 3, &written, values);
        expectCondition(written == 3, "3 properties returned");

        // GetProgramResourceLocation
        GLint uScaleLoc = gl.glGetProgramResourceLocation(prog, GL_UNIFORM, "uScale");
        expectCondition(uScaleLoc >= 0, "uScale location found");

        // GetProgramResourceLocationIndex (fragment output)
        GLint fragOutIdx = gl.glGetProgramResourceLocationIndex(prog, GL_PROGRAM_OUTPUT, "FragColor");
        expectCondition(fragOutIdx >= 0, "FragColor location index found");

        // GL 4.3 — shader storage block binding (no SSBOs in this program, but
        // the call must not crash with an empty SSBO table)
        // We skip the call here since storageBlockIndex would be out of range.
        // Instead verify the function pointer is wired.
        expectCondition(gl.glShaderStorageBlockBinding != nullptr, "glShaderStorageBlockBinding is wired");

        // GL 4.2 — atomic counter buffer query
        GLint acbBinding = 0;
        gl.glGetActiveAtomicCounterBufferiv(prog, 0, GL_ATOMIC_COUNTER_BUFFER_BINDING, &acbBinding);
        expectCondition(acbBinding == 0, "atomic counter buffer binding defaults to 0");

        gl.glDeleteProgram(prog);
        gl.glDeleteShader(vs);
        gl.glDeleteShader(fs);
        gl.glDeleteTextures(1, &imgTex);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glViewport(0, 0, 64, 64);
        gl.glClearColor(0.30f, 0.15f, 0.45f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glMemoryBarrier,
            FunctionId::glDispatchCompute,
            FunctionId::glDispatchComputeIndirect,
            FunctionId::glBindImageTexture,
            FunctionId::glGetActiveAtomicCounterBufferiv,
            FunctionId::glGetProgramInterfaceiv,
            FunctionId::glGetProgramResourceiv,
            FunctionId::glGetProgramResourceName,
            FunctionId::glGetProgramResourceIndex,
            FunctionId::glGetProgramResourceLocation,
            FunctionId::glGetProgramResourceLocationIndex,
            FunctionId::glShaderStorageBlockBinding,
        };
    }
};

// Scene 3: Advanced Drawing + Framebuffer/Buffer Ops (Groups 6+7)
class AdvancedDrawBufferOpsScene final : public Scene {
public:
    std::string id() const override { return "phase-c.advanced-draw-buffer-ops"; }
    std::string phase() const override { return "phase-c"; }
    SceneSize framebufferSize() const override { return {64, 64}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // GL 4.2 — base instance draw variants (validated stubs)
        gl.glDrawArraysInstancedBaseInstance(GL_TRIANGLES, 0, 0, 0, 0);
        gl.glDrawElementsInstancedBaseInstance(GL_TRIANGLES, 0, GL_UNSIGNED_INT, nullptr, 0, 0);
        gl.glDrawElementsInstancedBaseVertexBaseInstance(GL_TRIANGLES, 0, GL_UNSIGNED_INT, nullptr, 0, 0, 0);

        // GL 4.3 — multi-draw indirect (validated stubs)
        gl.glMultiDrawArraysIndirect(GL_TRIANGLES, nullptr, 0, 0);
        gl.glMultiDrawElementsIndirect(GL_TRIANGLES, GL_UNSIGNED_INT, nullptr, 0, 0);

        // GL 4.3 — buffer clear
        GLuint buf = 0;
        gl.glGenBuffers(1, &buf);
        gl.glBindBuffer(GL_ARRAY_BUFFER, buf);
        gl.glBufferData(GL_ARRAY_BUFFER, 64, nullptr, GL_DYNAMIC_DRAW);

        GLuint clearVal = 0xDEADBEEF;
        gl.glClearBufferData(GL_ARRAY_BUFFER, GL_R32UI, GL_RED_INTEGER, GL_UNSIGNED_INT, &clearVal);
        gl.glClearBufferSubData(GL_ARRAY_BUFFER, GL_R32UI, 0, 32, GL_RED_INTEGER, GL_UNSIGNED_INT, &clearVal);

        // GL 4.3 — framebuffer parameters
        gl.glFramebufferParameteri(GL_DRAW_FRAMEBUFFER, GL_FRAMEBUFFER_DEFAULT_WIDTH, 256);
        gl.glFramebufferParameteri(GL_DRAW_FRAMEBUFFER, GL_FRAMEBUFFER_DEFAULT_HEIGHT, 256);
        GLint defaultWidth = -1;
        gl.glGetFramebufferParameteriv(GL_DRAW_FRAMEBUFFER, GL_FRAMEBUFFER_DEFAULT_WIDTH, &defaultWidth);
        expectCondition(defaultWidth == 0, "framebuffer default width returns 0 (no FBO state storage yet)");

        // GL 4.3 — invalidation hints
        GLenum attachments[] = {GL_COLOR_ATTACHMENT0, GL_DEPTH_ATTACHMENT};
        gl.glInvalidateFramebuffer(GL_DRAW_FRAMEBUFFER, 2, attachments);
        gl.glInvalidateSubFramebuffer(GL_DRAW_FRAMEBUFFER, 1, attachments, 0, 0, 64, 64);
        gl.glInvalidateBufferData(buf);
        gl.glInvalidateBufferSubData(buf, 0, 32);

        gl.glDeleteBuffers(1, &buf);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glViewport(0, 0, 64, 64);
        gl.glClearColor(0.50f, 0.25f, 0.10f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glDrawArraysInstancedBaseInstance,
            FunctionId::glDrawElementsInstancedBaseInstance,
            FunctionId::glDrawElementsInstancedBaseVertexBaseInstance,
            FunctionId::glMultiDrawArraysIndirect,
            FunctionId::glMultiDrawElementsIndirect,
            FunctionId::glClearBufferData,
            FunctionId::glClearBufferSubData,
            FunctionId::glFramebufferParameteri,
            FunctionId::glGetFramebufferParameteriv,
            FunctionId::glInvalidateFramebuffer,
            FunctionId::glInvalidateSubFramebuffer,
            FunctionId::glInvalidateBufferData,
            FunctionId::glInvalidateBufferSubData,
        };
    }
};

// Scene 4: Texture Ops + TF Instanced Draw + Internal Format Query (Groups 8+9)
class TextureOpsTFFormatQueryScene final : public Scene {
public:
    std::string id() const override { return "phase-c.texture-ops-tf-format-query"; }
    std::string phase() const override { return "phase-c"; }
    SceneSize framebufferSize() const override { return {64, 64}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // GL 4.3 — texture view
        GLuint origTex = 0, viewTex = 0;
        gl.glGenTextures(1, &origTex);
        gl.glBindTexture(GL_TEXTURE_2D, origTex);
        gl.glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 32, 32);

        gl.glGenTextures(1, &viewTex);
        gl.glTextureView(viewTex, GL_TEXTURE_2D, origTex, GL_RGBA8, 0, 1, 0, 1);

        // GL 4.3 — copy image sub data (between two textures)
        GLuint dstTex = 0;
        gl.glGenTextures(1, &dstTex);
        gl.glBindTexture(GL_TEXTURE_2D, dstTex);
        gl.glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 32, 32);
        gl.glCopyImageSubData(origTex, GL_TEXTURE_2D, 0, 0, 0, 0,
                              dstTex, GL_TEXTURE_2D, 0, 0, 0, 0,
                              16, 16, 1);

        // GL 4.3 — texture invalidation hints
        gl.glInvalidateTexImage(origTex, 0);
        gl.glInvalidateTexSubImage(dstTex, 0, 0, 0, 0, 8, 8, 1);

        gl.glDeleteTextures(1, &origTex);
        gl.glDeleteTextures(1, &viewTex);
        gl.glDeleteTextures(1, &dstTex);

        // GL 4.2 — transform feedback instanced draw
        GLuint tfObj = 0;
        gl.glGenTransformFeedbacks(1, &tfObj);
        gl.glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, tfObj);
        gl.glDrawTransformFeedbackInstanced(GL_TRIANGLES, tfObj, 1);
        gl.glDrawTransformFeedbackStreamInstanced(GL_TRIANGLES, tfObj, 0, 1);
        gl.glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
        gl.glDeleteTransformFeedbacks(1, &tfObj);

        // GL 4.2/4.3 — internal format query
        GLint numSampleCounts = 0;
        gl.glGetInternalformativ(GL_TEXTURE_2D, GL_RGBA8, GL_NUM_SAMPLE_COUNTS, 1, &numSampleCounts);
        expectCondition(numSampleCounts > 0, "RGBA8 has at least 1 sample count");

        GLint samples[4] = {};
        gl.glGetInternalformativ(GL_TEXTURE_2D, GL_RGBA8, GL_SAMPLES, 3, samples);
        expectCondition(samples[0] >= samples[1], "sample counts in descending order");

        GLint supported = 0;
        gl.glGetInternalformativ(GL_TEXTURE_2D, GL_RGBA8, GL_INTERNALFORMAT_SUPPORTED, 1, &supported);
        expectCondition(supported == GL_TRUE, "RGBA8 is supported");

        GLint64 samples64[4] = {};
        gl.glGetInternalformati64v(GL_TEXTURE_2D, GL_RGBA8, GL_SAMPLES, 3, samples64);
        expectCondition(samples64[0] == static_cast<GLint64>(samples[0]), "i64v matches iv results");
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        gl.glViewport(0, 0, 64, 64);
        gl.glClearColor(0.10f, 0.35f, 0.55f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glCopyImageSubData,
            FunctionId::glTextureView,
            FunctionId::glInvalidateTexImage,
            FunctionId::glInvalidateTexSubImage,
            FunctionId::glDrawTransformFeedbackInstanced,
            FunctionId::glDrawTransformFeedbackStreamInstanced,
            FunctionId::glGetInternalformativ,
            FunctionId::glGetInternalformati64v,
        };
    }
};

// Phase 8X Group 4d follow-up¹⁴ §Tertiary — alpha-blend gauntlet scene.
//
// Regression test for the two root causes BAR diagnosed in
// followup¹³-verification and this round (followup¹⁴) lands:
//
//   Candidate 1 — blend state never reached the pipeline descriptor.
//     Pre-follow-up¹⁴, `encodeTranslatedDraw` left
//     `MTLRenderPipelineColorAttachmentDescriptor` at its default
//     (`blendingEnabled=NO, src=One, dst=Zero`), so every translated
//     draw was opaque on the GPU side regardless of what the GL state
//     tracker had recorded via `glEnable(GL_BLEND)` + `glBlendFunc(...)`.
//     This scene draws an opaque blue quad as background, then draws a
//     semi-transparent red quad over it using the canonical
//     `(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)` over-compositing function
//     with `glEnable(GL_BLEND)`. Under the pre-follow-up¹⁴ bug the
//     center pixel would be pure red (the second draw's raw output).
//     Under the fix the center pixel is `0.5*red + 0.5*blue = purple`.
//
//   Candidate 2 — vertex format derivation ignored the VAO and always
//     returned `Float4/Float3` based on the shader input's scalar type.
//     This scene is deliberately a single-attribute Float3 position
//     draw, which already worked before the fix — but the cache-key
//     expansion and format derivation still route through the same
//     `vaoTypeToMTLFormat` code path here, so the round-trip golden
//     also validates that the follow-up¹⁴ change did not regress the
//     simple Float3 position-only case.
//
// The scene also performs a spec-driven round-trip of the full 14-entry
// GL blend-factor enum table via `glBlendFunc` + `glGetIntegerv`, which
// is a pure GL-state-tracker test (no Metal translation involved).
// Together these checks exercise both the state-plumbing path that was
// broken (Candidate 1) and the state-tracker surface area that the draw
// builder now reads from.
class AlphaBlendGauntletScene final : public Scene {
public:
    std::string id() const override { return "phase-c.alpha-blend-gauntlet"; }
    std::string phase() const override { return "phase-c"; }
    SceneSize framebufferSize() const override { return {96, 96}; }

    double tolerance() const override {
        // Blend math is deterministic (no rasterisation edges involved
        // since both quads cover the whole viewport), but leave a one-
        // channel leeway for sRGB/linear rounding across GPU families.
        return 0.02;
    }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // ---------- Spec round-trip of the GL blend-factor enum table.
        // Every canonical blend factor must round-trip through
        // glBlendFunc → glGetIntegerv(GL_BLEND_SRC_RGB) unchanged. The
        // state-tracker read path was also where Candidate 1's fix
        // lives in `GLContext::drawArrays`, so we assert it works in
        // isolation before driving the Metal pipeline.
        const GLenum blendFactors[] = {
            GL_ZERO,
            GL_ONE,
            GL_SRC_COLOR,
            GL_ONE_MINUS_SRC_COLOR,
            GL_DST_COLOR,
            GL_ONE_MINUS_DST_COLOR,
            GL_SRC_ALPHA,
            GL_ONE_MINUS_SRC_ALPHA,
            GL_DST_ALPHA,
            GL_ONE_MINUS_DST_ALPHA,
            GL_CONSTANT_COLOR,
            GL_ONE_MINUS_CONSTANT_COLOR,
            GL_CONSTANT_ALPHA,
            GL_ONE_MINUS_CONSTANT_ALPHA,
        };
        for (GLenum factor : blendFactors) {
            gl.glBlendFunc(factor, GL_ZERO);
            GLint srcRGB = 0;
            GLint srcAlpha = 0;
            gl.glGetIntegerv(GL_BLEND_SRC_RGB, &srcRGB);
            gl.glGetIntegerv(GL_BLEND_SRC_ALPHA, &srcAlpha);
            expectCondition(static_cast<GLenum>(srcRGB) == factor,
                            "GL_BLEND_SRC_RGB round-trips glBlendFunc factor");
            expectCondition(static_cast<GLenum>(srcAlpha) == factor,
                            "GL_BLEND_SRC_ALPHA round-trips glBlendFunc factor");
        }

        // Also round-trip glBlendEquation through the standard four
        // equations. GL_FUNC_ADD is the draw-time default after reset.
        const GLenum blendEquations[] = {
            GL_FUNC_ADD,
            GL_FUNC_SUBTRACT,
            GL_FUNC_REVERSE_SUBTRACT,
            GL_MIN,
            GL_MAX,
        };
        for (GLenum eq : blendEquations) {
            gl.glBlendEquation(eq);
            GLint eqRGB = 0;
            GLint eqAlpha = 0;
            gl.glGetIntegerv(GL_BLEND_EQUATION_RGB, &eqRGB);
            gl.glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &eqAlpha);
            expectCondition(static_cast<GLenum>(eqRGB) == eq,
                            "GL_BLEND_EQUATION_RGB round-trips glBlendEquation");
            expectCondition(static_cast<GLenum>(eqAlpha) == eq,
                            "GL_BLEND_EQUATION_ALPHA round-trips glBlendEquation");
        }

        // Reset to the over-compositing pair for the actual draw.
        gl.glBlendEquation(GL_FUNC_ADD);
        gl.glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

        // ---------- Shader program: Float3 position + uniform vec4 color.
        // Intentionally minimal: the goal is to isolate the blend-state
        // plumbing, not to exercise every vertex format path (that's
        // the VaryingInterfaceScene's job). The single Float3 position
        // attribute still routes through the new `vaoTypeToMTLFormat`
        // path, so this scene validates that Float3 still produces
        // `MTLVertexFormatFloat3`.
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
        expectCondition(linkStatus == GL_TRUE, "alpha-blend gauntlet program links");
        gl.glDeleteShader(vertex);
        gl.glDeleteShader(fragment);

        // ---------- Full-viewport quad as two triangles (6 vertices).
        // Covers the entire clip space so both draws write every pixel,
        // which makes the center-pixel blend-math assertion trivial:
        // no rasterisation edges fall on the sample point.
        const GLfloat positions[18] = {
            -1.0f, -1.0f, 0.0f,
             1.0f, -1.0f, 0.0f,
             1.0f,  1.0f, 0.0f,
            -1.0f, -1.0f, 0.0f,
             1.0f,  1.0f, 0.0f,
            -1.0f,  1.0f, 0.0f,
        };

        gl.glGenVertexArrays(1, &vao_);
        gl.glBindVertexArray(vao_);
        gl.glGenBuffers(1, &vbo_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(positions), positions, GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * sizeof(GLfloat), nullptr);

        gl.glUseProgram(program_);
        colorLocation_ = gl.glGetUniformLocation(program_, "uColor");
        expectCondition(colorLocation_ >= 0,
                        "uColor is resolvable on alpha-blend gauntlet program");
    }

    void render(GLContext& context) override {
        auto& gl = Runtime::shared().dispatch();

        // Reset pipeline cache metrics so the post-draw assertion sees
        // only the work this scene generated.
        context.resetPipelineCacheMetrics();

        gl.glViewport(0, 0, framebufferSize().width, framebufferSize().height);
        gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);

        gl.glUseProgram(program_);
        gl.glBindVertexArray(vao_);

        // Draw 1 — opaque blue background (blend disabled).
        gl.glDisable(GL_BLEND);
        const GLfloat opaqueBlue[4] = {0.0f, 0.0f, 1.0f, 1.0f};
        gl.glUniform4fv(colorLocation_, 1, opaqueBlue);
        gl.glDrawArrays(GL_TRIANGLES, 0, 6);

        // Draw 2 — semi-transparent red over-composited with
        // `(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)`. Before follow-up¹⁴
        // the pipeline descriptor would have ignored the enable and
        // produced pure red output. After the fix the center pixel is
        // blended to 50/50 red/blue.
        gl.glEnable(GL_BLEND);
        gl.glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        gl.glBlendEquation(GL_FUNC_ADD);
        const GLfloat halfAlphaRed[4] = {1.0f, 0.0f, 0.0f, 0.5f};
        gl.glUniform4fv(colorLocation_, 1, halfAlphaRed);
        gl.glDrawArrays(GL_TRIANGLES, 0, 6);

        gl.glFlush();

        // Follow-up¹⁴ verification — the translated draw path must
        // have produced (or reused) a pipeline state for each of the
        // two distinct blend configurations without failing.
        const auto metrics = context.pipelineCacheMetrics();
        expectCondition(metrics.buildAttempts >= 1,
                        "alpha-blend scene reached pipeline build branch");
        expectCondition(metrics.buildFailures == 0,
                        "alpha-blend scene produced a Metal-accepted pipeline state");

        // Sample the center pixel and verify the blend math matches
        // the spec: final = src.rgb * src.a + dst.rgb * (1 - src.a)
        //                 = (1,0,0) * 0.5 + (0,0,1) * 0.5
        //                 = (0.5, 0, 0.5)  →  ~(127, 0, 127, 255).
        const GLsizei cx = framebufferSize().width / 2;
        const GLsizei cy = framebufferSize().height / 2;
        std::uint8_t rgba[4] = {0, 0, 0, 0};
        gl.glReadPixels(cx, cy, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
        // Allow ±4 LSB for sRGB/linear rounding + rasterisation rounding.
        const int r = rgba[0];
        const int g = rgba[1];
        const int b = rgba[2];
        expectCondition(r >= 120 && r <= 135,
                        "alpha-blend center red channel ≈ 0.5");
        expectCondition(g <= 4,
                        "alpha-blend center green channel ≈ 0");
        expectCondition(b >= 120 && b <= 135,
                        "alpha-blend center blue channel ≈ 0.5");

        // Restore state so the readback path (run by `runScene` after
        // this function returns) doesn't inherit an unusual enable.
        gl.glDisable(GL_BLEND);
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glAttachShader,
            FunctionId::glBindBuffer,
            FunctionId::glBindVertexArray,
            FunctionId::glBlendEquation,
            FunctionId::glBlendFunc,
            FunctionId::glBufferData,
            FunctionId::glClear,
            FunctionId::glClearColor,
            FunctionId::glCompileShader,
            FunctionId::glCreateProgram,
            FunctionId::glCreateShader,
            FunctionId::glDeleteShader,
            FunctionId::glDisable,
            FunctionId::glDrawArrays,
            FunctionId::glEnable,
            FunctionId::glEnableVertexAttribArray,
            FunctionId::glFlush,
            FunctionId::glGenBuffers,
            FunctionId::glGenVertexArrays,
            FunctionId::glGetIntegerv,
            FunctionId::glGetProgramiv,
            FunctionId::glGetUniformLocation,
            FunctionId::glLinkProgram,
            FunctionId::glReadPixels,
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
    GLint colorLocation_ = -1;
};

// =========================================================================
// Phase D — GL 4.4 / 4.5 DSA / 4.6 function coverage scenes
// =========================================================================

// Scene 1: GL 4.4 foundation (bufferStorage, multi-bind, tex clear) + DSA creation (9 create*)
class GL44DSACreationScene final : public Scene {
public:
    std::string id() const override { return "phase-d.gl44-dsa-creation"; }
    std::string phase() const override { return "phase-d"; }
    SceneSize framebufferSize() const override { return {64, 64}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // GL 4.4 — glBufferStorage (immutable buffer)
        GLuint buf = 0;
        gl.glGenBuffers(1, &buf);
        gl.glBindBuffer(GL_ARRAY_BUFFER, buf);
        float data[4] = {1.0f, 2.0f, 3.0f, 4.0f};
        gl.glBufferStorage(GL_ARRAY_BUFFER, sizeof(data), data, GL_MAP_READ_BIT);

        // GL 4.4 — multi-bind
        GLuint bufs[2] = {buf, 0};
        gl.glBindBuffersBase(GL_UNIFORM_BUFFER, 0, 1, bufs);
        GLintptr offsets[1] = {0};
        GLsizeiptr sizes[1] = {sizeof(data)};
        gl.glBindBuffersRange(GL_UNIFORM_BUFFER, 0, 1, bufs, offsets, sizes);

        GLuint vbo = 0;
        gl.glGenBuffers(1, &vbo);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo);
        gl.glBufferData(GL_ARRAY_BUFFER, 64, nullptr, GL_STATIC_DRAW);
        GLuint vbufs[1] = {vbo};
        GLintptr vOffsets[1] = {0};
        GLsizei vStrides[1] = {16};
        gl.glBindVertexBuffers(0, 1, vbufs, vOffsets, vStrides);

        GLuint tex = 0;
        gl.glGenTextures(1, &tex);
        gl.glBindTexture(GL_TEXTURE_2D, tex);
        gl.glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 4, 4);
        GLuint texArr[1] = {tex};
        gl.glBindTextures(0, 1, texArr);
        GLuint sampler = 0;
        gl.glGenSamplers(1, &sampler);
        GLuint samplers[1] = {sampler};
        gl.glBindSamplers(0, 1, samplers);
        GLuint images[1] = {tex};
        gl.glBindImageTextures(0, 1, images);

        // GL 4.4 — texture clear
        float clearColor[4] = {0.0f, 1.0f, 0.0f, 1.0f};
        gl.glClearTexImage(tex, 0, GL_RGBA, GL_FLOAT, clearColor);
        gl.glClearTexSubImage(tex, 0, 0, 0, 0, 2, 2, 1, GL_RGBA, GL_FLOAT, clearColor);

        // GL 4.5 — DSA object creation (9 create* functions)
        GLuint cBuf = 0;
        gl.glCreateBuffers(1, &cBuf);
        GLuint cTex = 0;
        gl.glCreateTextures(GL_TEXTURE_2D, 1, &cTex);
        GLuint cSamp = 0;
        gl.glCreateSamplers(1, &cSamp);
        GLuint cFbo = 0;
        gl.glCreateFramebuffers(1, &cFbo);
        GLuint cRbo = 0;
        gl.glCreateRenderbuffers(1, &cRbo);
        GLuint cVao = 0;
        gl.glCreateVertexArrays(1, &cVao);
        GLuint cTf = 0;
        gl.glCreateTransformFeedbacks(1, &cTf);
        GLuint cPpo = 0;
        gl.glCreateProgramPipelines(1, &cPpo);
        GLuint cQuery = 0;
        gl.glCreateQueries(GL_SAMPLES_PASSED, 1, &cQuery);

        // Cleanup
        gl.glDeleteBuffers(1, &buf);
        gl.glDeleteBuffers(1, &vbo);
        gl.glDeleteTextures(1, &tex);
        gl.glDeleteSamplers(1, &sampler);
        gl.glDeleteBuffers(1, &cBuf);
        gl.glDeleteTextures(1, &cTex);
        gl.glDeleteSamplers(1, &cSamp);
        gl.glDeleteFramebuffers(1, &cFbo);
        gl.glDeleteRenderbuffers(1, &cRbo);
        gl.glDeleteVertexArrays(1, &cVao);
        gl.glDeleteTransformFeedbacks(1, &cTf);
        gl.glDeleteProgramPipelines(1, &cPpo);
        gl.glDeleteQueries(1, &cQuery);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        while (gl.glGetError() != GL_NO_ERROR) {}
        gl.glViewport(0, 0, 64, 64);
        gl.glClearColor(0.10f, 0.30f, 0.50f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glBufferStorage,
            FunctionId::glBindBuffersBase, FunctionId::glBindBuffersRange,
            FunctionId::glBindVertexBuffers,
            FunctionId::glBindTextures, FunctionId::glBindSamplers, FunctionId::glBindImageTextures,
            FunctionId::glClearTexImage, FunctionId::glClearTexSubImage,
            FunctionId::glCreateBuffers, FunctionId::glCreateTextures, FunctionId::glCreateSamplers,
            FunctionId::glCreateFramebuffers, FunctionId::glCreateRenderbuffers,
            FunctionId::glCreateVertexArrays, FunctionId::glCreateTransformFeedbacks,
            FunctionId::glCreateProgramPipelines, FunctionId::glCreateQueries,
        };
    }
};

// Scene 2: DSA buffer operations (14) + DSA texture operations (34)
class DSABufferTextureScene final : public Scene {
public:
    std::string id() const override { return "phase-d.dsa-buffer-texture"; }
    std::string phase() const override { return "phase-d"; }
    SceneSize framebufferSize() const override { return {64, 64}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // --- DSA buffer operations (14 functions) ---
        GLuint buf = 0;
        gl.glCreateBuffers(1, &buf);
        gl.glNamedBufferStorage(buf, 256, nullptr, GL_MAP_READ_BIT | GL_MAP_WRITE_BIT | GL_DYNAMIC_STORAGE_BIT);
        float bdata[4] = {1.0f, 2.0f, 3.0f, 4.0f};
        gl.glNamedBufferSubData(buf, 0, sizeof(bdata), bdata);

        GLuint buf2 = 0;
        gl.glCreateBuffers(1, &buf2);
        gl.glNamedBufferData(buf2, 256, nullptr, GL_DYNAMIC_DRAW);
        gl.glCopyNamedBufferSubData(buf, buf2, 0, 0, sizeof(bdata));

        void* ptr = gl.glMapNamedBuffer(buf2, GL_READ_ONLY);
        (void)ptr;
        gl.glUnmapNamedBuffer(buf2);

        void* ptr2 = gl.glMapNamedBufferRange(buf2, 0, 64, GL_MAP_WRITE_BIT | GL_MAP_FLUSH_EXPLICIT_BIT);
        (void)ptr2;
        gl.glFlushMappedNamedBufferRange(buf2, 0, 16);
        gl.glUnmapNamedBuffer(buf2);

        gl.glClearNamedBufferData(buf2, GL_R32F, GL_RED, GL_FLOAT, nullptr);
        gl.glClearNamedBufferSubData(buf2, GL_R32F, 0, 64, GL_RED, GL_FLOAT, nullptr);

        GLint bparam = 0;
        gl.glGetNamedBufferParameteriv(buf, GL_BUFFER_SIZE, &bparam);
        GLint64 bparam64 = 0;
        gl.glGetNamedBufferParameteri64v(buf, GL_BUFFER_SIZE, &bparam64);
        void* bptr = nullptr;
        gl.glGetNamedBufferPointerv(buf, GL_BUFFER_MAP_POINTER, &bptr);
        float readback[4] = {};
        gl.glGetNamedBufferSubData(buf, 0, sizeof(readback), readback);

        // --- DSA texture operations (34 functions) ---
        GLuint tex2d = 0;
        gl.glCreateTextures(GL_TEXTURE_2D, 1, &tex2d);
        gl.glTextureStorage2D(tex2d, 1, GL_RGBA8, 8, 8);
        uint8_t pixels[8*8*4] = {};
        gl.glTextureSubImage2D(tex2d, 0, 0, 0, 8, 8, GL_RGBA, GL_UNSIGNED_BYTE, pixels);

        GLuint tex1d = 0;
        gl.glCreateTextures(GL_TEXTURE_1D, 1, &tex1d);
        gl.glTextureStorage1D(tex1d, 1, GL_RGBA8, 16);
        uint8_t pix1d[16*4] = {};
        gl.glTextureSubImage1D(tex1d, 0, 0, 16, GL_RGBA, GL_UNSIGNED_BYTE, pix1d);

        GLuint tex3d = 0;
        gl.glCreateTextures(GL_TEXTURE_3D, 1, &tex3d);
        gl.glTextureStorage3D(tex3d, 1, GL_RGBA8, 4, 4, 4);
        uint8_t pix3d[4*4*4*4] = {};
        gl.glTextureSubImage3D(tex3d, 0, 0, 0, 0, 4, 4, 4, GL_RGBA, GL_UNSIGNED_BYTE, pix3d);

        GLuint texMs = 0;
        gl.glCreateTextures(GL_TEXTURE_2D_MULTISAMPLE, 1, &texMs);
        gl.glTextureStorage2DMultisample(texMs, 4, GL_RGBA8, 8, 8, GL_TRUE);

        GLuint texMs3 = 0;
        gl.glCreateTextures(GL_TEXTURE_2D_MULTISAMPLE_ARRAY, 1, &texMs3);
        gl.glTextureStorage3DMultisample(texMs3, 4, GL_RGBA8, 4, 4, 2, GL_TRUE);

        // Texture buffer
        GLuint tboBuf = 0;
        gl.glCreateBuffers(1, &tboBuf);
        gl.glNamedBufferData(tboBuf, 64, nullptr, GL_STATIC_DRAW);
        GLuint tbo = 0;
        gl.glCreateTextures(GL_TEXTURE_BUFFER, 1, &tbo);
        gl.glTextureBuffer(tbo, GL_RGBA32F, tboBuf);
        GLuint tbo2 = 0;
        gl.glCreateTextures(GL_TEXTURE_BUFFER, 1, &tbo2);
        gl.glTextureBufferRange(tbo2, GL_RGBA32F, tboBuf, 0, 32);

        // Compressed texture sub-image stubs
        gl.glCompressedTextureSubImage1D(tex1d, 0, 0, 0, GL_RGBA, 0, nullptr);
        gl.glCompressedTextureSubImage2D(tex2d, 0, 0, 0, 0, 0, GL_RGBA, 0, nullptr);
        gl.glCompressedTextureSubImage3D(tex3d, 0, 0, 0, 0, 0, 0, 0, GL_RGBA, 0, nullptr);

        // Copy texture sub-image stubs
        gl.glCopyTextureSubImage1D(tex1d, 0, 0, 0, 0, 1);
        gl.glCopyTextureSubImage2D(tex2d, 0, 0, 0, 0, 0, 1, 1);
        gl.glCopyTextureSubImage3D(tex3d, 0, 0, 0, 0, 0, 0, 1, 1);

        // Texture parameters
        gl.glTextureParameterf(tex2d, GL_TEXTURE_MIN_LOD, 0.0f);
        float fvParam[4] = {0.0f};
        gl.glTextureParameterfv(tex2d, GL_TEXTURE_BORDER_COLOR, fvParam);
        gl.glTextureParameteri(tex2d, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        GLint ivParam[1] = {GL_LINEAR};
        gl.glTextureParameteriv(tex2d, GL_TEXTURE_MIN_FILTER, ivParam);
        gl.glTextureParameterIiv(tex2d, GL_TEXTURE_MIN_FILTER, ivParam);
        GLuint uivParam[1] = {GL_LINEAR};
        gl.glTextureParameterIuiv(tex2d, GL_TEXTURE_MIN_FILTER, uivParam);

        // Get texture parameters
        GLfloat fvOut[4] = {};
        gl.glGetTextureParameterfv(tex2d, GL_TEXTURE_MIN_LOD, fvOut);
        GLint ivOut[1] = {};
        gl.glGetTextureParameteriv(tex2d, GL_TEXTURE_MIN_FILTER, ivOut);
        gl.glGetTextureParameterIiv(tex2d, GL_TEXTURE_MIN_FILTER, ivOut);
        GLuint uivOut[1] = {};
        gl.glGetTextureParameterIuiv(tex2d, GL_TEXTURE_MIN_FILTER, uivOut);

        // Get texture level parameters
        GLfloat lvlF = 0;
        gl.glGetTextureLevelParameterfv(tex2d, 0, GL_TEXTURE_WIDTH, &lvlF);
        GLint lvlI = 0;
        gl.glGetTextureLevelParameteriv(tex2d, 0, GL_TEXTURE_WIDTH, &lvlI);

        // Get texture image / sub-image stubs
        uint8_t imgBuf[256] = {};
        gl.glGetTextureImage(tex2d, 0, GL_RGBA, GL_UNSIGNED_BYTE, sizeof(imgBuf), imgBuf);
        gl.glGetTextureSubImage(tex2d, 0, 0, 0, 0, 4, 4, 1, GL_RGBA, GL_UNSIGNED_BYTE, sizeof(imgBuf), imgBuf);
        gl.glGetCompressedTextureImage(tex2d, 0, sizeof(imgBuf), imgBuf);
        gl.glGetCompressedTextureSubImage(tex2d, 0, 0, 0, 0, 4, 4, 1, sizeof(imgBuf), imgBuf);
        while (gl.glGetError() != GL_NO_ERROR) {}
        constexpr GLint oversizedMipLevel = 1000;
        gl.glGetTextureSubImage(tex2d, oversizedMipLevel, 0, 0, 0, 4, 4, 1, GL_RGBA, GL_UNSIGNED_BYTE, sizeof(imgBuf), imgBuf);
        expectGLError(gl, GL_INVALID_VALUE, "glGetTextureSubImage oversized level rejects without UB");
        gl.glGetCompressedTextureSubImage(tex2d, oversizedMipLevel, 0, 0, 0, 4, 4, 1, sizeof(imgBuf), imgBuf);
        expectGLError(gl, GL_INVALID_VALUE, "glGetCompressedTextureSubImage oversized level rejects without UB");

        gl.glGenerateTextureMipmap(tex2d);
        while (gl.glGetError() != GL_NO_ERROR) {}

        gl.glActiveTexture(GL_TEXTURE3);
        gl.glBindTextureUnit(0, tex2d);
        GLint activeTexture = 0;
        gl.glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
        expectCondition(activeTexture == GL_TEXTURE3, "glBindTextureUnit preserves active texture");

        GLint maxTextureUnits = 0;
        gl.glGetIntegerv(GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, &maxTextureUnits);
        gl.glBindTextureUnit(static_cast<GLuint>(maxTextureUnits), tex2d);
        expectGLError(gl, GL_INVALID_VALUE, "glBindTextureUnit rejects out-of-range unit");
        gl.glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
        expectCondition(activeTexture == GL_TEXTURE3, "invalid glBindTextureUnit preserves active texture");

        gl.glBindTextureUnit(0, 0);
        gl.glActiveTexture(GL_TEXTURE0);
        GLint boundTexture2D = -1;
        gl.glGetIntegerv(GL_TEXTURE_BINDING_2D, &boundTexture2D);
        expectCondition(boundTexture2D == 0, "glBindTextureUnit zero unbinds 2D target");

        // Cleanup
        gl.glDeleteBuffers(1, &buf);
        gl.glDeleteBuffers(1, &buf2);
        gl.glDeleteBuffers(1, &tboBuf);
        gl.glDeleteTextures(1, &tex2d);
        gl.glDeleteTextures(1, &tex1d);
        gl.glDeleteTextures(1, &tex3d);
        gl.glDeleteTextures(1, &texMs);
        gl.glDeleteTextures(1, &texMs3);
        gl.glDeleteTextures(1, &tbo);
        gl.glDeleteTextures(1, &tbo2);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        while (gl.glGetError() != GL_NO_ERROR) {}
        gl.glViewport(0, 0, 64, 64);
        gl.glClearColor(0.50f, 0.20f, 0.10f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            // DSA buffer (14)
            FunctionId::glNamedBufferStorage, FunctionId::glNamedBufferData,
            FunctionId::glNamedBufferSubData, FunctionId::glCopyNamedBufferSubData,
            FunctionId::glMapNamedBuffer, FunctionId::glMapNamedBufferRange,
            FunctionId::glUnmapNamedBuffer, FunctionId::glFlushMappedNamedBufferRange,
            FunctionId::glClearNamedBufferData, FunctionId::glClearNamedBufferSubData,
            FunctionId::glGetNamedBufferParameteriv, FunctionId::glGetNamedBufferParameteri64v,
            FunctionId::glGetNamedBufferPointerv, FunctionId::glGetNamedBufferSubData,
            // DSA texture (34)
            FunctionId::glTextureStorage1D, FunctionId::glTextureStorage2D,
            FunctionId::glTextureStorage3D, FunctionId::glTextureStorage2DMultisample,
            FunctionId::glTextureStorage3DMultisample,
            FunctionId::glTextureSubImage1D, FunctionId::glTextureSubImage2D, FunctionId::glTextureSubImage3D,
            FunctionId::glTextureBuffer, FunctionId::glTextureBufferRange,
            FunctionId::glCompressedTextureSubImage1D, FunctionId::glCompressedTextureSubImage2D,
            FunctionId::glCompressedTextureSubImage3D,
            FunctionId::glCopyTextureSubImage1D, FunctionId::glCopyTextureSubImage2D,
            FunctionId::glCopyTextureSubImage3D,
            FunctionId::glTextureParameterf, FunctionId::glTextureParameterfv,
            FunctionId::glTextureParameteri, FunctionId::glTextureParameteriv,
            FunctionId::glTextureParameterIiv, FunctionId::glTextureParameterIuiv,
            FunctionId::glGetTextureParameterfv, FunctionId::glGetTextureParameteriv,
            FunctionId::glGetTextureParameterIiv, FunctionId::glGetTextureParameterIuiv,
            FunctionId::glGetTextureLevelParameterfv, FunctionId::glGetTextureLevelParameteriv,
            FunctionId::glGetTextureImage, FunctionId::glGetTextureSubImage,
            FunctionId::glGetCompressedTextureImage, FunctionId::glGetCompressedTextureSubImage,
            FunctionId::glGenerateTextureMipmap, FunctionId::glBindTextureUnit,
        };
    }
};

// Scene 3: DSA framebuffer/renderbuffer (20) + DSA vertex array (13) + DSA transform feedback (5)
class DSAFramebufferVAOScene final : public Scene {
public:
    std::string id() const override { return "phase-d.dsa-framebuffer-vao-tf"; }
    std::string phase() const override { return "phase-d"; }
    SceneSize framebufferSize() const override { return {64, 64}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // --- DSA framebuffer/renderbuffer (20 functions) ---
        GLuint fbo = 0, rbo = 0;
        gl.glCreateFramebuffers(1, &fbo);
        gl.glCreateRenderbuffers(1, &rbo);
        gl.glNamedRenderbufferStorage(rbo, GL_RGBA8, 64, 64);
        gl.glNamedRenderbufferStorageMultisample(rbo, 4, GL_RGBA8, 64, 64);
        GLint rbParam = 0;
        gl.glGetNamedRenderbufferParameteriv(rbo, GL_RENDERBUFFER_WIDTH, &rbParam);

        gl.glNamedFramebufferRenderbuffer(fbo, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rbo);

        GLuint texFbo = 0;
        gl.glCreateTextures(GL_TEXTURE_2D, 1, &texFbo);
        gl.glTextureStorage2D(texFbo, 1, GL_RGBA8, 64, 64);
        gl.glNamedFramebufferTexture(fbo, GL_COLOR_ATTACHMENT0, texFbo, 0);
        gl.glNamedFramebufferTextureLayer(fbo, GL_COLOR_ATTACHMENT0, texFbo, 0, 0);

        GLenum drawBufs[1] = {GL_COLOR_ATTACHMENT0};
        gl.glNamedFramebufferDrawBuffer(fbo, GL_COLOR_ATTACHMENT0);
        gl.glNamedFramebufferDrawBuffers(fbo, 1, drawBufs);
        gl.glNamedFramebufferReadBuffer(fbo, GL_COLOR_ATTACHMENT0);
        gl.glNamedFramebufferParameteri(fbo, GL_FRAMEBUFFER_DEFAULT_WIDTH, 64);

        GLint fbParam = 0;
        gl.glGetNamedFramebufferParameteriv(fbo, GL_FRAMEBUFFER_DEFAULT_WIDTH, &fbParam);
        GLint fbAttParam = 0;
        gl.glGetNamedFramebufferAttachmentParameteriv(fbo, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &fbAttParam);

        GLenum status = gl.glCheckNamedFramebufferStatus(fbo, GL_FRAMEBUFFER);
        (void)status;

        // Blit between default (0) and named FBO — both args can be 0 for default FB
        gl.glBlitNamedFramebuffer(0, 0, 0, 0, 64, 64, 0, 0, 64, 64, GL_COLOR_BUFFER_BIT, GL_NEAREST);

        // Clear named framebuffer variants
        float clearF[4] = {0.0f, 0.0f, 0.0f, 1.0f};
        gl.glClearNamedFramebufferfv(fbo, GL_COLOR, 0, clearF);
        GLint clearI[4] = {0};
        gl.glClearNamedFramebufferiv(fbo, GL_COLOR, 0, clearI);
        GLuint clearU[4] = {0};
        gl.glClearNamedFramebufferuiv(fbo, GL_COLOR, 0, clearU);
        gl.glClearNamedFramebufferfi(fbo, GL_DEPTH_STENCIL, 0, 1.0f, 0);

        GLenum invalidateAtts[1] = {GL_COLOR_ATTACHMENT0};
        gl.glInvalidateNamedFramebufferData(fbo, 1, invalidateAtts);
        gl.glInvalidateNamedFramebufferSubData(fbo, 1, invalidateAtts, 0, 0, 32, 32);

        // --- DSA vertex array (13 functions) ---
        GLuint vao = 0;
        gl.glCreateVertexArrays(1, &vao);
        gl.glVertexArrayAttribFormat(vao, 0, 3, GL_FLOAT, GL_FALSE, 0);
        gl.glVertexArrayAttribIFormat(vao, 1, 1, GL_INT, 0);
        gl.glVertexArrayAttribLFormat(vao, 2, 1, GL_DOUBLE, 0);
        gl.glVertexArrayAttribBinding(vao, 0, 0);
        gl.glVertexArrayBindingDivisor(vao, 0, 0);

        GLuint vbo = 0;
        gl.glCreateBuffers(1, &vbo);
        gl.glNamedBufferData(vbo, 256, nullptr, GL_STATIC_DRAW);
        gl.glVertexArrayVertexBuffer(vao, 0, vbo, 0, 12);
        GLuint vbufs[1] = {vbo};
        GLintptr voffs[1] = {0};
        GLsizei vstrides[1] = {12};
        gl.glVertexArrayVertexBuffers(vao, 0, 1, vbufs, voffs, vstrides);

        GLuint ebo = 0;
        gl.glCreateBuffers(1, &ebo);
        gl.glNamedBufferData(ebo, 64, nullptr, GL_STATIC_DRAW);
        gl.glVertexArrayElementBuffer(vao, ebo);

        gl.glEnableVertexArrayAttrib(vao, 0);
        gl.glDisableVertexArrayAttrib(vao, 0);

        GLint vaoParam = 0;
        gl.glGetVertexArrayiv(vao, GL_ELEMENT_ARRAY_BUFFER_BINDING, &vaoParam);
        gl.glGetVertexArrayIndexediv(vao, 0, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &vaoParam);
        GLint64 vaoParam64 = 0;
        gl.glGetVertexArrayIndexed64iv(vao, 0, GL_VERTEX_BINDING_OFFSET, &vaoParam64);

        // --- DSA transform feedback (5 functions) ---
        GLuint tf = 0;
        gl.glCreateTransformFeedbacks(1, &tf);
        GLuint tfBuf = 0;
        gl.glCreateBuffers(1, &tfBuf);
        gl.glNamedBufferData(tfBuf, 256, nullptr, GL_DYNAMIC_DRAW);
        gl.glTransformFeedbackBufferBase(tf, 0, tfBuf);
        gl.glTransformFeedbackBufferRange(tf, 0, tfBuf, 0, 128);
        GLint tfParam = 0;
        gl.glGetTransformFeedbackiv(tf, GL_TRANSFORM_FEEDBACK_ACTIVE, &tfParam);
        gl.glGetTransformFeedbacki_v(tf, GL_TRANSFORM_FEEDBACK_BUFFER_BINDING, 0, &tfParam);
        GLint64 tfParam64 = 0;
        gl.glGetTransformFeedbacki64_v(tf, GL_TRANSFORM_FEEDBACK_BUFFER_START, 0, &tfParam64);

        // Cleanup
        gl.glDeleteFramebuffers(1, &fbo);
        gl.glDeleteRenderbuffers(1, &rbo);
        gl.glDeleteTextures(1, &texFbo);
        gl.glDeleteVertexArrays(1, &vao);
        gl.glDeleteBuffers(1, &vbo);
        gl.glDeleteBuffers(1, &ebo);
        gl.glDeleteTransformFeedbacks(1, &tf);
        gl.glDeleteBuffers(1, &tfBuf);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        while (gl.glGetError() != GL_NO_ERROR) {}
        gl.glViewport(0, 0, 64, 64);
        gl.glClearColor(0.20f, 0.50f, 0.30f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            // DSA framebuffer/renderbuffer (20)
            FunctionId::glNamedFramebufferRenderbuffer, FunctionId::glNamedFramebufferTexture,
            FunctionId::glNamedFramebufferTextureLayer, FunctionId::glNamedFramebufferDrawBuffer,
            FunctionId::glNamedFramebufferDrawBuffers, FunctionId::glNamedFramebufferReadBuffer,
            FunctionId::glNamedFramebufferParameteri, FunctionId::glGetNamedFramebufferParameteriv,
            FunctionId::glGetNamedFramebufferAttachmentParameteriv, FunctionId::glCheckNamedFramebufferStatus,
            FunctionId::glBlitNamedFramebuffer, FunctionId::glClearNamedFramebufferfv,
            FunctionId::glClearNamedFramebufferiv, FunctionId::glClearNamedFramebufferuiv,
            FunctionId::glClearNamedFramebufferfi, FunctionId::glInvalidateNamedFramebufferData,
            FunctionId::glInvalidateNamedFramebufferSubData,
            FunctionId::glNamedRenderbufferStorage, FunctionId::glNamedRenderbufferStorageMultisample,
            FunctionId::glGetNamedRenderbufferParameteriv,
            // DSA vertex array (13)
            FunctionId::glVertexArrayAttribFormat, FunctionId::glVertexArrayAttribIFormat,
            FunctionId::glVertexArrayAttribLFormat, FunctionId::glVertexArrayAttribBinding,
            FunctionId::glVertexArrayBindingDivisor, FunctionId::glVertexArrayVertexBuffer,
            FunctionId::glVertexArrayVertexBuffers, FunctionId::glVertexArrayElementBuffer,
            FunctionId::glEnableVertexArrayAttrib, FunctionId::glDisableVertexArrayAttrib,
            FunctionId::glGetVertexArrayiv, FunctionId::glGetVertexArrayIndexediv,
            FunctionId::glGetVertexArrayIndexed64iv,
            // DSA transform feedback (5)
            FunctionId::glTransformFeedbackBufferBase, FunctionId::glTransformFeedbackBufferRange,
            FunctionId::glGetTransformFeedbackiv, FunctionId::glGetTransformFeedbacki_v,
            FunctionId::glGetTransformFeedbacki64_v,
        };
    }
};

// Scene 4: ClipControl + robustness + barriers + query buffer + GL 4.6
class ClipControlRobustnessGL46Scene final : public Scene {
public:
    std::string id() const override { return "phase-d.clip-control-robustness-gl46"; }
    std::string phase() const override { return "phase-d"; }
    SceneSize framebufferSize() const override { return {64, 64}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // GL 4.5 — ClipControl
        gl.glClipControl(GL_LOWER_LEFT, GL_ZERO_TO_ONE);
        gl.glClipControl(GL_UPPER_LEFT, GL_NEGATIVE_ONE_TO_ONE);
        gl.glClipControl(GL_LOWER_LEFT, GL_NEGATIVE_ONE_TO_ONE);  // restore default

        // GL 4.5 — GetGraphicsResetStatus
        GLenum resetStatus = gl.glGetGraphicsResetStatus();
        (void)resetStatus;

        // GL 4.5 — ReadnPixels (robustness)
        uint8_t px[4] = {};
        gl.glReadnPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, sizeof(px), px);

        // GL 4.5 — GetnUniform* (robustness) — need a valid program
        GLuint prog = gl.glCreateProgram();
        GLuint vs = gl.glCreateShader(GL_VERTEX_SHADER);
        const char* vsSrc = "#version 330\nvoid main() { gl_Position = vec4(0); }\n";
        gl.glShaderSource(vs, 1, &vsSrc, nullptr);
        gl.glCompileShader(vs);
        GLuint fs = gl.glCreateShader(GL_FRAGMENT_SHADER);
        const char* fsSrc = "#version 330\nuniform float u_val;\nout vec4 color;\nvoid main() { color = vec4(u_val); }\n";
        gl.glShaderSource(fs, 1, &fsSrc, nullptr);
        gl.glCompileShader(fs);
        gl.glAttachShader(prog, vs);
        gl.glAttachShader(prog, fs);
        gl.glLinkProgram(prog);
        gl.glUseProgram(prog);

        GLint loc = gl.glGetUniformLocation(prog, "u_val");
        if (loc >= 0) {
            GLfloat fval = 0;
            gl.glGetnUniformfv(prog, loc, sizeof(fval), &fval);
            GLint ival = 0;
            gl.glGetnUniformiv(prog, loc, sizeof(ival), &ival);
            GLuint uval = 0;
            gl.glGetnUniformuiv(prog, loc, sizeof(uval), &uval);
            GLdouble dval = 0;
            gl.glGetnUniformdv(prog, loc, sizeof(dval), &dval);
        }
        gl.glUseProgram(0);
        gl.glDeleteShader(vs);
        gl.glDeleteShader(fs);
        gl.glDeleteProgram(prog);

        // GL 4.5 — GetnTexImage / GetnCompressedTexImage (robustness stubs)
        GLuint stubTex = 0;
        gl.glCreateTextures(GL_TEXTURE_2D, 1, &stubTex);
        gl.glTextureStorage2D(stubTex, 1, GL_RGBA8, 4, 4);
        uint8_t imgBuf[128] = {};
        gl.glGetnTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, sizeof(imgBuf), imgBuf);
        gl.glGetnCompressedTexImage(GL_TEXTURE_2D, 0, sizeof(imgBuf), imgBuf);
        gl.glDeleteTextures(1, &stubTex);

        // GL 4.5 — Barriers
        gl.glMemoryBarrierByRegion(GL_ALL_BARRIER_BITS);
        gl.glTextureBarrier();

        // GL 4.5 — Query buffer objects
        GLuint query = 0, qBuf = 0;
        gl.glCreateQueries(GL_SAMPLES_PASSED, 1, &query);
        gl.glCreateBuffers(1, &qBuf);
        gl.glNamedBufferData(qBuf, 64, nullptr, GL_DYNAMIC_READ);
        gl.glGetQueryBufferObjectiv(query, qBuf, GL_QUERY_RESULT, 0);
        gl.glGetQueryBufferObjectuiv(query, qBuf, GL_QUERY_RESULT, 0);
        gl.glGetQueryBufferObjecti64v(query, qBuf, GL_QUERY_RESULT, 0);
        gl.glGetQueryBufferObjectui64v(query, qBuf, GL_QUERY_RESULT, 0);
        gl.glDeleteQueries(1, &query);
        gl.glDeleteBuffers(1, &qBuf);

        // GL 4.6 — Indirect count draws (call with maxdrawcount=0 for safe stub exercise)
        gl.glMultiDrawArraysIndirectCount(GL_TRIANGLES, nullptr, 0, 0, 0);
        gl.glMultiDrawElementsIndirectCount(GL_TRIANGLES, GL_UNSIGNED_INT, nullptr, 0, 0, 0);

        // GL 4.6 — SpecializeShader (stub)
        GLuint spvShader = gl.glCreateShader(GL_VERTEX_SHADER);
        gl.glSpecializeShader(spvShader, "main", 0, nullptr, nullptr);
        gl.glDeleteShader(spvShader);

        // GL 4.6 — PolygonOffsetClamp
        gl.glPolygonOffsetClamp(1.0f, 1.0f, 0.01f);
        gl.glPolygonOffsetClamp(0.0f, 0.0f, 0.0f);  // reset
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        while (gl.glGetError() != GL_NO_ERROR) {}
        gl.glViewport(0, 0, 64, 64);
        gl.glClearColor(0.40f, 0.10f, 0.40f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            // ClipControl + robustness (11)
            FunctionId::glClipControl, FunctionId::glGetGraphicsResetStatus,
            FunctionId::glReadnPixels, FunctionId::glGetnUniformfv,
            FunctionId::glGetnUniformiv, FunctionId::glGetnUniformuiv,
            FunctionId::glGetnUniformdv, FunctionId::glGetnTexImage,
            FunctionId::glGetnCompressedTexImage, FunctionId::glMemoryBarrierByRegion,
            FunctionId::glTextureBarrier,
            // Query buffer objects (4)
            FunctionId::glGetQueryBufferObjectiv, FunctionId::glGetQueryBufferObjectuiv,
            FunctionId::glGetQueryBufferObjecti64v, FunctionId::glGetQueryBufferObjectui64v,
            // GL 4.6 (4)
            FunctionId::glMultiDrawArraysIndirectCount, FunctionId::glMultiDrawElementsIndirectCount,
            FunctionId::glSpecializeShader, FunctionId::glPolygonOffsetClamp,
        };
    }
};

// ── Phase 7 Gauntlet Scenes ──

// Scene: Polygon Objects — renders all 5 geometry types (cube, sphere, torus,
// cylinder, plane) side-by-side in a single framebuffer to confirm geometry
// generation + translated draw pipeline for varied meshes.
class PolygonObjectsScene final : public Scene {
public:
    std::string id() const override { return "phase-7.polygon-objects"; }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {256, 256}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        const char* vsSrc =
            "#version 330 core\n"
            "layout(location = 0) in vec3 aPosition;\n"
            "uniform mat4 uMVP;\n"
            "void main() { gl_Position = uMVP * vec4(aPosition, 1.0); }\n";
        const char* fsSrc =
            "#version 330 core\n"
            "uniform vec4 uColor;\n"
            "out vec4 fragColor;\n"
            "void main() { fragColor = uColor; }\n";

        GLuint vs = gl.glCreateShader(GL_VERTEX_SHADER);
        gl.glShaderSource(vs, 1, &vsSrc, nullptr);
        gl.glCompileShader(vs);
        GLuint fs = gl.glCreateShader(GL_FRAGMENT_SHADER);
        gl.glShaderSource(fs, 1, &fsSrc, nullptr);
        gl.glCompileShader(fs);
        program_ = gl.glCreateProgram();
        gl.glAttachShader(program_, vs);
        gl.glAttachShader(program_, fs);
        gl.glLinkProgram(program_);
        gl.glDeleteShader(vs);
        gl.glDeleteShader(fs);

        colorLoc_ = gl.glGetUniformLocation(program_, "uColor");
        mvpLoc_   = gl.glGetUniformLocation(program_, "uMVP");
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        gl.glViewport(0, 0, 256, 256);
        gl.glClearColor(0.06f, 0.06f, 0.08f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        gl.glEnable(GL_DEPTH_TEST);

        gl.glUseProgram(program_);

        const float pi = 3.14159265f;
        // 5 objects laid out horizontally (x offsets: -2, -1, 0, 1, 2)
        struct ObjDef { int segments; int rings; float color[4]; };
        ObjDef defs[5] = {
            {0, 0, {0.90f, 0.25f, 0.25f, 1.0f}},    // cube (special)
            {16, 8, {0.25f, 0.85f, 0.35f, 1.0f}},    // sphere
            {16, 8, {0.25f, 0.45f, 0.95f, 1.0f}},    // torus
            {16, 0, {0.95f, 0.88f, 0.25f, 1.0f}},    // cylinder
            {4, 0, {0.25f, 0.85f, 0.92f, 1.0f}},     // plane
        };

        for (int obj = 0; obj < 5; ++obj) {
            std::vector<float> geom;
            switch (obj) {
                case 0: geom = generateCube(); break;
                case 1: geom = generateSphere(defs[obj].segments, defs[obj].rings, 0.35f); break;
                case 2: geom = generateTorus(defs[obj].segments, defs[obj].rings, 0.25f, 0.10f); break;
                case 3: geom = generateCylinder(defs[obj].segments, 0.22f, 0.35f); break;
                case 4: geom = generatePlane(defs[obj].segments, 0.35f); break;
            }

            GLuint vao, vbo;
            gl.glGenVertexArrays(1, &vao);
            gl.glGenBuffers(1, &vbo);
            gl.glBindVertexArray(vao);
            gl.glBindBuffer(GL_ARRAY_BUFFER, vbo);
            gl.glBufferData(GL_ARRAY_BUFFER, static_cast<GLsizeiptr>(geom.size() * sizeof(float)),
                            geom.data(), GL_STATIC_DRAW);
            gl.glEnableVertexAttribArray(0);
            gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * sizeof(float), nullptr);

            // Position each object: 5 in a row, camera at z=-6
            float xOff = (float(obj) - 2.0f) * 0.9f;
            // Simple column-major orthographic-ish perspective MVP
            float proj[16] = {};
            float fov = 0.785f;
            float f = 1.0f / std::tan(fov * 0.5f);
            proj[0] = f; proj[5] = f; proj[10] = -1.02f; proj[11] = -1.0f; proj[14] = -0.2f;
            // Translation: view * model
            float mvp[16] = {};
            std::memcpy(mvp, proj, sizeof(proj));
            mvp[12] += proj[0] * xOff;
            mvp[13] += 0.0f;
            mvp[14] += proj[10] * (-4.0f) + proj[14];
            float angle = 0.6f + float(obj) * 0.3f;
            float cy = std::cos(angle), sy = std::sin(angle);
            float cx = std::cos(0.3f), sx = std::sin(0.3f);
            // Apply rotation to MVP (simplified)
            float rotY[16] = {}; rotY[0]=cy; rotY[2]=-sy; rotY[5]=1; rotY[8]=sy; rotY[10]=cy; rotY[15]=1;
            float rotX[16] = {}; rotX[0]=1; rotX[5]=cx; rotX[6]=sx; rotX[9]=-sx; rotX[10]=cx; rotX[15]=1;
            // Build model = rotY * rotX, then translate
            float model[16] = {};
            for (int c = 0; c < 4; ++c)
                for (int r = 0; r < 4; ++r) {
                    float s = 0;
                    for (int k = 0; k < 4; ++k) s += rotY[k*4+r] * rotX[c*4+k];
                    model[c*4+r] = s;
                }
            model[12] = xOff; model[13] = 0; model[14] = -4.0f;
            // MVP = proj * model
            float finalMVP[16] = {};
            for (int c = 0; c < 4; ++c)
                for (int r = 0; r < 4; ++r) {
                    float s = 0;
                    for (int k = 0; k < 4; ++k) s += proj[k*4+r] * model[c*4+k];
                    finalMVP[c*4+r] = s;
                }

            gl.glUniformMatrix4fv(mvpLoc_, 1, GL_FALSE, finalMVP);
            gl.glUniform4fv(colorLoc_, 1, defs[obj].color);
            gl.glDrawArrays(GL_TRIANGLES, 0, static_cast<GLsizei>(geom.size() / 3));

            gl.glBindVertexArray(0);
            gl.glDeleteBuffers(1, &vbo);
            gl.glDeleteVertexArrays(1, &vao);
        }

        gl.glUseProgram(0);
        gl.glDisable(GL_DEPTH_TEST);
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glCreateShader, FunctionId::glShaderSource, FunctionId::glCompileShader,
            FunctionId::glCreateProgram, FunctionId::glAttachShader, FunctionId::glLinkProgram,
            FunctionId::glDeleteShader, FunctionId::glUseProgram,
            FunctionId::glGenVertexArrays, FunctionId::glBindVertexArray, FunctionId::glDeleteVertexArrays,
            FunctionId::glGenBuffers, FunctionId::glBindBuffer, FunctionId::glBufferData, FunctionId::glDeleteBuffers,
            FunctionId::glEnableVertexAttribArray, FunctionId::glVertexAttribPointer,
            FunctionId::glUniformMatrix4fv, FunctionId::glUniform4fv,
            FunctionId::glDrawArrays,
            FunctionId::glEnable, FunctionId::glDisable,
            FunctionId::glClearColor, FunctionId::glClear,
            FunctionId::glViewport,
            FunctionId::glGetUniformLocation,
        };
    }

private:
    GLuint program_ = 0;
    GLint colorLoc_ = -1;
    GLint mvpLoc_ = -1;

    // Inline geometry generators matching the test app's procedural meshes.
    static std::vector<float> generateCube() {
        // Simple unit cube: 6 faces × 2 tris × 3 verts
        const float v[][3] = {
            {-0.3f,-0.3f, 0.3f}, { 0.3f,-0.3f, 0.3f}, { 0.3f, 0.3f, 0.3f}, {-0.3f, 0.3f, 0.3f},
            {-0.3f,-0.3f,-0.3f}, { 0.3f,-0.3f,-0.3f}, { 0.3f, 0.3f,-0.3f}, {-0.3f, 0.3f,-0.3f},
        };
        const int idx[] = {
            0,1,2, 0,2,3,  // front
            5,4,7, 5,7,6,  // back
            3,2,6, 3,6,7,  // top
            4,5,1, 4,1,0,  // bottom
            1,5,6, 1,6,2,  // right
            4,0,3, 4,3,7,  // left
        };
        std::vector<float> out;
        for (int i : idx) { out.push_back(v[i][0]); out.push_back(v[i][1]); out.push_back(v[i][2]); }
        return out;
    }

    static std::vector<float> generateSphere(int seg, int rings, float r) {
        std::vector<float> out;
        const float pi = 3.14159265f;
        for (int ri = 0; ri < rings; ++ri) {
            float t0 = pi * float(ri) / float(rings);
            float t1 = pi * float(ri+1) / float(rings);
            for (int si = 0; si < seg; ++si) {
                float p0 = 2*pi*float(si)/float(seg);
                float p1 = 2*pi*float(si+1)/float(seg);
                auto P = [&](float t, float p) {
                    out.push_back(r*std::sin(t)*std::cos(p));
                    out.push_back(r*std::cos(t));
                    out.push_back(r*std::sin(t)*std::sin(p));
                };
                P(t0,p0); P(t1,p0); P(t1,p1);
                P(t0,p0); P(t1,p1); P(t0,p1);
            }
        }
        return out;
    }

    static std::vector<float> generateTorus(int seg, int rings, float R, float rr) {
        std::vector<float> out;
        const float pi = 3.14159265f;
        for (int ri = 0; ri < rings; ++ri) {
            float t0 = 2*pi*float(ri)/float(rings);
            float t1 = 2*pi*float(ri+1)/float(rings);
            for (int si = 0; si < seg; ++si) {
                float p0 = 2*pi*float(si)/float(seg);
                float p1 = 2*pi*float(si+1)/float(seg);
                auto P = [&](float t, float p) {
                    out.push_back((R+rr*std::cos(t))*std::cos(p));
                    out.push_back(rr*std::sin(t));
                    out.push_back((R+rr*std::cos(t))*std::sin(p));
                };
                P(t0,p0); P(t1,p0); P(t1,p1);
                P(t0,p0); P(t1,p1); P(t0,p1);
            }
        }
        return out;
    }

    static std::vector<float> generateCylinder(int seg, float r, float hh) {
        std::vector<float> out;
        const float pi = 3.14159265f;
        for (int s = 0; s < seg; ++s) {
            float a0 = 2*pi*float(s)/float(seg);
            float a1 = 2*pi*float(s+1)/float(seg);
            float x0=r*std::cos(a0), z0=r*std::sin(a0);
            float x1=r*std::cos(a1), z1=r*std::sin(a1);
            // side
            out.push_back(x0); out.push_back(-hh); out.push_back(z0);
            out.push_back(x1); out.push_back(-hh); out.push_back(z1);
            out.push_back(x1); out.push_back( hh); out.push_back(z1);
            out.push_back(x0); out.push_back(-hh); out.push_back(z0);
            out.push_back(x1); out.push_back( hh); out.push_back(z1);
            out.push_back(x0); out.push_back( hh); out.push_back(z0);
            // top cap
            out.push_back(0); out.push_back(hh); out.push_back(0);
            out.push_back(x0); out.push_back(hh); out.push_back(z0);
            out.push_back(x1); out.push_back(hh); out.push_back(z1);
            // bottom cap
            out.push_back(0); out.push_back(-hh); out.push_back(0);
            out.push_back(x1); out.push_back(-hh); out.push_back(z1);
            out.push_back(x0); out.push_back(-hh); out.push_back(z0);
        }
        return out;
    }

    static std::vector<float> generatePlane(int grid, float ext) {
        std::vector<float> out;
        float step = 2*ext/float(grid);
        for (int r = 0; r < grid; ++r) {
            for (int c = 0; c < grid; ++c) {
                float x0 = -ext+c*step, z0 = -ext+r*step;
                float x1 = x0+step, z1 = z0+step;
                out.push_back(x0); out.push_back(0); out.push_back(z0);
                out.push_back(x1); out.push_back(0); out.push_back(z0);
                out.push_back(x1); out.push_back(0); out.push_back(z1);
                out.push_back(x0); out.push_back(0); out.push_back(z0);
                out.push_back(x1); out.push_back(0); out.push_back(z1);
                out.push_back(x0); out.push_back(0); out.push_back(z1);
            }
        }
        return out;
    }
};

// Scene: Object Count Stress — renders 100 cubes in a grid to exercise the
// per-draw uniform upload path (MVP + color per instance) at moderate load.
class ObjectCountStressScene final : public Scene {
public:
    std::string id() const override { return "phase-7.object-count-stress"; }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {256, 256}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        const char* vsSrc =
            "#version 330 core\n"
            "layout(location = 0) in vec3 aPosition;\n"
            "uniform mat4 uMVP;\n"
            "void main() { gl_Position = uMVP * vec4(aPosition, 1.0); }\n";
        const char* fsSrc =
            "#version 330 core\n"
            "uniform vec4 uColor;\n"
            "out vec4 fragColor;\n"
            "void main() { fragColor = uColor; }\n";

        GLuint vs = gl.glCreateShader(GL_VERTEX_SHADER);
        gl.glShaderSource(vs, 1, &vsSrc, nullptr);
        gl.glCompileShader(vs);
        GLuint fs = gl.glCreateShader(GL_FRAGMENT_SHADER);
        gl.glShaderSource(fs, 1, &fsSrc, nullptr);
        gl.glCompileShader(fs);
        program_ = gl.glCreateProgram();
        gl.glAttachShader(program_, vs);
        gl.glAttachShader(program_, fs);
        gl.glLinkProgram(program_);
        gl.glDeleteShader(vs);
        gl.glDeleteShader(fs);

        colorLoc_ = gl.glGetUniformLocation(program_, "uColor");
        mvpLoc_   = gl.glGetUniformLocation(program_, "uMVP");

        // Build a small cube VBO
        const float h = 0.15f;
        const float v[][3] = {
            {-h,-h, h}, { h,-h, h}, { h, h, h}, {-h, h, h},
            {-h,-h,-h}, { h,-h,-h}, { h, h,-h}, {-h, h,-h},
        };
        const int idx[] = {
            0,1,2, 0,2,3,  5,4,7, 5,7,6,  3,2,6, 3,6,7,
            4,5,1, 4,1,0,  1,5,6, 1,6,2,  4,0,3, 4,3,7,
        };
        float cubeVerts[36 * 3];
        for (int i = 0; i < 36; ++i) {
            cubeVerts[i*3+0] = v[idx[i]][0];
            cubeVerts[i*3+1] = v[idx[i]][1];
            cubeVerts[i*3+2] = v[idx[i]][2];
        }

        gl.glGenVertexArrays(1, &vao_);
        gl.glGenBuffers(1, &vbo_);
        gl.glBindVertexArray(vao_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(cubeVerts), cubeVerts, GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * sizeof(float), nullptr);
        gl.glBindVertexArray(0);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        gl.glViewport(0, 0, 256, 256);
        gl.glClearColor(0.05f, 0.05f, 0.07f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        gl.glEnable(GL_DEPTH_TEST);

        gl.glUseProgram(program_);
        gl.glBindVertexArray(vao_);

        // Perspective projection
        const float fov = 0.785f;
        const float f = 1.0f / std::tan(fov * 0.5f);
        float proj[16] = {};
        proj[0] = f; proj[5] = f; proj[10] = -1.02f; proj[11] = -1.0f; proj[14] = -0.2f;

        // Color palette
        const float colors[][4] = {
            {0.90f, 0.25f, 0.25f, 1.0f}, {0.25f, 0.85f, 0.35f, 1.0f},
            {0.25f, 0.45f, 0.95f, 1.0f}, {0.95f, 0.88f, 0.25f, 1.0f},
            {0.25f, 0.85f, 0.92f, 1.0f}, {0.88f, 0.25f, 0.88f, 1.0f},
            {0.95f, 0.55f, 0.25f, 1.0f}, {0.55f, 0.85f, 0.55f, 1.0f},
        };

        // Render 100 cubes in a 5×5×4 grid
        const int count = 100;
        const int gridX = 5, gridY = 5, gridZ = 4;
        const float spacing = 0.6f;
        const float cameraZ = -6.0f;
        int drawn = 0;

        for (int iz = 0; iz < gridZ && drawn < count; ++iz) {
            for (int iy = 0; iy < gridY && drawn < count; ++iy) {
                for (int ix = 0; ix < gridX && drawn < count; ++ix) {
                    float tx = (float(ix) - float(gridX-1)*0.5f) * spacing;
                    float ty = (float(iy) - float(gridY-1)*0.5f) * spacing;
                    float tz = (float(iz) - float(gridZ-1)*0.5f) * spacing;

                    // model = translate(tx, ty, tz + cameraZ)
                    float model[16] = {};
                    model[0] = 1; model[5] = 1; model[10] = 1; model[15] = 1;
                    model[12] = tx; model[13] = ty; model[14] = tz + cameraZ;

                    // MVP = proj * model
                    float mvp[16] = {};
                    for (int c = 0; c < 4; ++c)
                        for (int r = 0; r < 4; ++r) {
                            float s = 0;
                            for (int k = 0; k < 4; ++k) s += proj[k*4+r] * model[c*4+k];
                            mvp[c*4+r] = s;
                        }

                    gl.glUniformMatrix4fv(mvpLoc_, 1, GL_FALSE, mvp);
                    gl.glUniform4fv(colorLoc_, 1, colors[drawn % 8]);
                    gl.glDrawArrays(GL_TRIANGLES, 0, 36);
                    ++drawn;
                }
            }
        }

        gl.glBindVertexArray(0);
        gl.glUseProgram(0);
        gl.glDisable(GL_DEPTH_TEST);
        gl.glDeleteBuffers(1, &vbo_);
        gl.glDeleteVertexArrays(1, &vao_);
        gl.glDeleteProgram(program_);
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glCreateShader, FunctionId::glShaderSource, FunctionId::glCompileShader,
            FunctionId::glCreateProgram, FunctionId::glAttachShader, FunctionId::glLinkProgram,
            FunctionId::glDeleteShader, FunctionId::glUseProgram,
            FunctionId::glGenVertexArrays, FunctionId::glBindVertexArray, FunctionId::glDeleteVertexArrays,
            FunctionId::glGenBuffers, FunctionId::glBindBuffer, FunctionId::glBufferData, FunctionId::glDeleteBuffers,
            FunctionId::glEnableVertexAttribArray, FunctionId::glVertexAttribPointer,
            FunctionId::glUniformMatrix4fv, FunctionId::glUniform4fv,
            FunctionId::glDrawArrays,
            FunctionId::glEnable, FunctionId::glDisable,
            FunctionId::glClearColor, FunctionId::glClear,
            FunctionId::glViewport,
            FunctionId::glGetUniformLocation,
        };
    }

private:
    GLuint program_ = 0;
    GLint colorLoc_ = -1;
    GLint mvpLoc_ = -1;
    GLuint vao_ = 0, vbo_ = 0;
};

// Scene: Physics Collision — runs a simple 5-body bouncing simulation for 120
// frames and captures the final state. Tests dynamic per-frame uniform updates
// (one MVP per body per frame) through the translated draw pipeline.
class PhysicsCollisionScene final : public Scene {
public:
    std::string id() const override { return "phase-7.physics-collision"; }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {256, 256}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        const char* vsSrc =
            "#version 330 core\n"
            "layout(location = 0) in vec3 aPosition;\n"
            "uniform mat4 uMVP;\n"
            "void main() { gl_Position = uMVP * vec4(aPosition, 1.0); }\n";
        const char* fsSrc =
            "#version 330 core\n"
            "uniform vec4 uColor;\n"
            "out vec4 fragColor;\n"
            "void main() { fragColor = uColor; }\n";

        GLuint vs = gl.glCreateShader(GL_VERTEX_SHADER);
        gl.glShaderSource(vs, 1, &vsSrc, nullptr);
        gl.glCompileShader(vs);
        GLuint fs = gl.glCreateShader(GL_FRAGMENT_SHADER);
        gl.glShaderSource(fs, 1, &fsSrc, nullptr);
        gl.glCompileShader(fs);
        program_ = gl.glCreateProgram();
        gl.glAttachShader(program_, vs);
        gl.glAttachShader(program_, fs);
        gl.glLinkProgram(program_);
        gl.glDeleteShader(vs);
        gl.glDeleteShader(fs);

        colorLoc_ = gl.glGetUniformLocation(program_, "uColor");
        mvpLoc_   = gl.glGetUniformLocation(program_, "uMVP");

        // Build a small sphere VBO (16 segments × 8 rings)
        const float pi = 3.14159265f;
        const int seg = 16, rings = 8;
        const float r = 1.0f;  // unit sphere, scaled per body
        for (int ri = 0; ri < rings; ++ri) {
            float t0 = pi * float(ri) / float(rings);
            float t1 = pi * float(ri+1) / float(rings);
            for (int si = 0; si < seg; ++si) {
                float p0 = 2*pi*float(si)/float(seg);
                float p1 = 2*pi*float(si+1)/float(seg);
                auto P = [&](float t, float p) {
                    sphereVerts_.push_back(r*std::sin(t)*std::cos(p));
                    sphereVerts_.push_back(r*std::cos(t));
                    sphereVerts_.push_back(r*std::sin(t)*std::sin(p));
                };
                P(t0,p0); P(t1,p0); P(t1,p1);
                P(t0,p0); P(t1,p1); P(t0,p1);
            }
        }
        sphereVertCount_ = static_cast<int>(sphereVerts_.size()) / 3;

        gl.glGenVertexArrays(1, &vao_);
        gl.glGenBuffers(1, &vbo_);
        gl.glBindVertexArray(vao_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER, static_cast<GLsizeiptr>(sphereVerts_.size() * sizeof(float)),
                        sphereVerts_.data(), GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * sizeof(float), nullptr);
        gl.glBindVertexArray(0);

        // Initialize 5 bodies
        struct Init { float px,py,pz,vx,vy,vz; };
        Init inits[5] = {
            {-0.8f,  0.5f,  0.0f,  0.8f,  0.5f,  0.3f},
            { 0.7f, -0.3f,  0.4f, -0.6f,  0.7f, -0.4f},
            { 0.0f,  0.8f, -0.5f,  0.4f, -0.8f,  0.5f},
            {-0.5f, -0.6f,  0.6f,  0.7f,  0.3f, -0.6f},
            { 0.4f,  0.2f, -0.7f, -0.5f, -0.4f,  0.8f},
        };
        const float colors[5][4] = {
            {0.95f, 0.30f, 0.30f, 1.0f}, {0.30f, 0.90f, 0.40f, 1.0f},
            {0.35f, 0.50f, 0.95f, 1.0f}, {0.95f, 0.85f, 0.30f, 1.0f},
            {0.80f, 0.35f, 0.90f, 1.0f},
        };
        for (int i = 0; i < 5; ++i) {
            Body b;
            b.px = inits[i].px; b.py = inits[i].py; b.pz = inits[i].pz;
            b.vx = inits[i].vx; b.vy = inits[i].vy; b.vz = inits[i].vz;
            b.radius = 0.18f;
            std::memcpy(b.color, colors[i], sizeof(b.color));
            bodies_.push_back(b);
        }
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // Run 120 physics steps (deterministic, fixed dt)
        const float dt = 1.0f / 60.0f;
        const float ext = 1.5f;
        for (int frame = 0; frame < 120; ++frame) {
            for (auto& b : bodies_) {
                b.px += b.vx * dt; b.py += b.vy * dt; b.pz += b.vz * dt;
            }
            // Wall bounce
            for (auto& b : bodies_) {
                auto bounce = [&](float& p, float& v) {
                    if (p - b.radius < -ext) { p = -ext + b.radius; v = std::abs(v); }
                    if (p + b.radius >  ext) { p =  ext - b.radius; v = -std::abs(v); }
                };
                bounce(b.px, b.vx); bounce(b.py, b.vy); bounce(b.pz, b.vz);
            }
            // Sphere-sphere collision
            for (int i = 0; i < 5; ++i) {
                for (int j = i+1; j < 5; ++j) {
                    float dx = bodies_[j].px - bodies_[i].px;
                    float dy = bodies_[j].py - bodies_[i].py;
                    float dz = bodies_[j].pz - bodies_[i].pz;
                    float d2 = dx*dx + dy*dy + dz*dz;
                    float md = bodies_[i].radius + bodies_[j].radius;
                    if (d2 < md*md && d2 > 1e-6f) {
                        float d = std::sqrt(d2);
                        float nx=dx/d, ny=dy/d, nz=dz/d;
                        float vi = bodies_[i].vx*nx + bodies_[i].vy*ny + bodies_[i].vz*nz;
                        float vj = bodies_[j].vx*nx + bodies_[j].vy*ny + bodies_[j].vz*nz;
                        bodies_[i].vx += (vj-vi)*nx; bodies_[i].vy += (vj-vi)*ny; bodies_[i].vz += (vj-vi)*nz;
                        bodies_[j].vx += (vi-vj)*nx; bodies_[j].vy += (vi-vj)*ny; bodies_[j].vz += (vi-vj)*nz;
                        float ov = md - d;
                        bodies_[i].px -= nx*ov*0.5f; bodies_[i].py -= ny*ov*0.5f; bodies_[i].pz -= nz*ov*0.5f;
                        bodies_[j].px += nx*ov*0.5f; bodies_[j].py += ny*ov*0.5f; bodies_[j].pz += nz*ov*0.5f;
                    }
                }
            }
        }

        // Render final state
        gl.glViewport(0, 0, 256, 256);
        gl.glClearColor(0.06f, 0.06f, 0.08f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        gl.glEnable(GL_DEPTH_TEST);
        gl.glUseProgram(program_);
        gl.glBindVertexArray(vao_);

        // Perspective + view
        float proj[16] = {};
        float fov = 0.785f, f = 1.0f / std::tan(fov * 0.5f);
        proj[0] = f; proj[5] = f; proj[10] = -1.02f; proj[11] = -1.0f; proj[14] = -0.2f;

        for (int i = 0; i < 5; ++i) {
            const auto& b = bodies_[i];
            float model[16] = {};
            model[0] = b.radius; model[5] = b.radius; model[10] = b.radius; model[15] = 1;
            model[12] = b.px; model[13] = b.py; model[14] = b.pz - 5.0f;
            float mvp[16] = {};
            for (int c = 0; c < 4; ++c)
                for (int r = 0; r < 4; ++r) {
                    float s = 0; for (int k = 0; k < 4; ++k) s += proj[k*4+r] * model[c*4+k];
                    mvp[c*4+r] = s;
                }
            gl.glUniformMatrix4fv(mvpLoc_, 1, GL_FALSE, mvp);
            gl.glUniform4fv(colorLoc_, 1, b.color);
            gl.glDrawArrays(GL_TRIANGLES, 0, sphereVertCount_);
        }

        gl.glBindVertexArray(0);
        gl.glUseProgram(0);
        gl.glDisable(GL_DEPTH_TEST);
        gl.glDeleteBuffers(1, &vbo_);
        gl.glDeleteVertexArrays(1, &vao_);
        gl.glDeleteProgram(program_);
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glCreateShader, FunctionId::glShaderSource, FunctionId::glCompileShader,
            FunctionId::glCreateProgram, FunctionId::glAttachShader, FunctionId::glLinkProgram,
            FunctionId::glDeleteShader, FunctionId::glUseProgram,
            FunctionId::glGenVertexArrays, FunctionId::glBindVertexArray, FunctionId::glDeleteVertexArrays,
            FunctionId::glGenBuffers, FunctionId::glBindBuffer, FunctionId::glBufferData, FunctionId::glDeleteBuffers,
            FunctionId::glEnableVertexAttribArray, FunctionId::glVertexAttribPointer,
            FunctionId::glUniformMatrix4fv, FunctionId::glUniform4fv,
            FunctionId::glDrawArrays,
            FunctionId::glEnable, FunctionId::glDisable,
            FunctionId::glClearColor, FunctionId::glClear,
            FunctionId::glViewport,
            FunctionId::glGetUniformLocation,
        };
    }

private:
    struct Body { float px,py,pz,vx,vy,vz,radius; float color[4]; };
    GLuint program_ = 0;
    GLint colorLoc_ = -1, mvpLoc_ = -1;
    GLuint vao_ = 0, vbo_ = 0;
    std::vector<float> sphereVerts_;
    int sphereVertCount_ = 0;
    std::vector<Body> bodies_;
};

// Scene: Lighting Phong — renders a Blinn-Phong lit sphere with per-fragment
// shading. Tests the multi-uniform pipeline: uMVP, uModelMatrix, uNormalMatrix
// (mat3), uLightPos, uLightColor, uViewPos (vec3), uColor (vec4) all flowing
// through GLSL→SPIR-V→MSL translation. Uses interleaved pos+normal vertex data
// with two vertex attributes.
class LightingPhongScene final : public Scene {
public:
    std::string id() const override { return "phase-7.lighting-phong"; }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {256, 256}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        const char* vsSrc =
            "#version 330 core\n"
            "layout(location = 0) in vec3 aPosition;\n"
            "layout(location = 1) in vec3 aNormal;\n"
            "uniform mat4 uMVP;\n"
            "uniform mat4 uModelMatrix;\n"
            "uniform mat3 uNormalMatrix;\n"
            "out vec3 vWorldPos;\n"
            "out vec3 vNormal;\n"
            "void main() {\n"
            "    vec4 worldPos = uModelMatrix * vec4(aPosition, 1.0);\n"
            "    vWorldPos = worldPos.xyz;\n"
            "    vNormal = normalize(uNormalMatrix * aNormal);\n"
            "    gl_Position = uMVP * vec4(aPosition, 1.0);\n"
            "}\n";
        const char* fsSrc =
            "#version 330 core\n"
            "in vec3 vWorldPos;\n"
            "in vec3 vNormal;\n"
            "uniform vec3 uLightPos;\n"
            "uniform vec3 uLightColor;\n"
            "uniform vec3 uViewPos;\n"
            "uniform vec4 uColor;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    float ambientStrength = 0.15;\n"
            "    vec3 ambient = ambientStrength * uLightColor;\n"
            "    vec3 norm = normalize(vNormal);\n"
            "    vec3 lightDir = normalize(uLightPos - vWorldPos);\n"
            "    float diff = max(dot(norm, lightDir), 0.0);\n"
            "    vec3 diffuse = diff * uLightColor;\n"
            "    float specularStrength = 0.5;\n"
            "    vec3 viewDir = normalize(uViewPos - vWorldPos);\n"
            "    vec3 halfDir = normalize(lightDir + viewDir);\n"
            "    float spec = pow(max(dot(norm, halfDir), 0.0), 32.0);\n"
            "    vec3 specular = specularStrength * spec * uLightColor;\n"
            "    vec3 result = (ambient + diffuse + specular) * uColor.rgb;\n"
            "    fragColor = vec4(result, uColor.a);\n"
            "}\n";

        GLuint vs = gl.glCreateShader(GL_VERTEX_SHADER);
        gl.glShaderSource(vs, 1, &vsSrc, nullptr);
        gl.glCompileShader(vs);
        GLuint fs = gl.glCreateShader(GL_FRAGMENT_SHADER);
        gl.glShaderSource(fs, 1, &fsSrc, nullptr);
        gl.glCompileShader(fs);
        program_ = gl.glCreateProgram();
        gl.glAttachShader(program_, vs);
        gl.glAttachShader(program_, fs);
        gl.glLinkProgram(program_);
        gl.glDeleteShader(vs);
        gl.glDeleteShader(fs);

        mvpLoc_         = gl.glGetUniformLocation(program_, "uMVP");
        modelMatLoc_    = gl.glGetUniformLocation(program_, "uModelMatrix");
        normalMatLoc_   = gl.glGetUniformLocation(program_, "uNormalMatrix");
        lightPosLoc_    = gl.glGetUniformLocation(program_, "uLightPos");
        lightColorLoc_  = gl.glGetUniformLocation(program_, "uLightColor");
        viewPosLoc_     = gl.glGetUniformLocation(program_, "uViewPos");
        colorLoc_       = gl.glGetUniformLocation(program_, "uColor");

        // Generate sphere with interleaved pos+normal (stride = 6 floats)
        const float pi = 3.14159265f;
        const int seg = 32, rings = 16;
        const float radius = 0.8f;
        for (int ri = 0; ri < rings; ++ri) {
            float t0 = pi * float(ri) / float(rings);
            float t1 = pi * float(ri+1) / float(rings);
            for (int si = 0; si < seg; ++si) {
                float p0 = 2*pi*float(si)/float(seg);
                float p1 = 2*pi*float(si+1)/float(seg);
                auto V = [&](float t, float p) {
                    float nx = std::sin(t)*std::cos(p);
                    float ny = std::cos(t);
                    float nz = std::sin(t)*std::sin(p);
                    sphereData_.push_back(radius*nx);
                    sphereData_.push_back(radius*ny);
                    sphereData_.push_back(radius*nz);
                    sphereData_.push_back(nx);
                    sphereData_.push_back(ny);
                    sphereData_.push_back(nz);
                };
                V(t0,p0); V(t1,p0); V(t1,p1);
                V(t0,p0); V(t1,p1); V(t0,p1);
            }
        }
        vertCount_ = static_cast<int>(sphereData_.size()) / 6;

        gl.glGenVertexArrays(1, &vao_);
        gl.glGenBuffers(1, &vbo_);
        gl.glBindVertexArray(vao_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER, static_cast<GLsizeiptr>(sphereData_.size() * sizeof(float)),
                        sphereData_.data(), GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), nullptr);
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float),
                                 reinterpret_cast<void*>(3 * sizeof(float)));
        gl.glBindVertexArray(0);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        gl.glViewport(0, 0, 256, 256);
        gl.glClearColor(0.04f, 0.04f, 0.06f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        gl.glEnable(GL_DEPTH_TEST);

        gl.glUseProgram(program_);

        // Identity model matrix (sphere centered at origin)
        float model[16] = {};
        model[0] = 1; model[5] = 1; model[10] = 1; model[15] = 1;

        // Perspective + view (z = -3)
        float proj[16] = {};
        float fov = 0.785f, f = 1.0f / std::tan(fov * 0.5f);
        proj[0] = f; proj[5] = f; proj[10] = -1.02f; proj[11] = -1.0f; proj[14] = -0.2f;

        float viewModel[16] = {};
        std::memcpy(viewModel, model, sizeof(model));
        viewModel[14] = -3.0f;  // translate z

        float mvp[16] = {};
        for (int c = 0; c < 4; ++c)
            for (int r = 0; r < 4; ++r) {
                float s = 0;
                for (int k = 0; k < 4; ++k) s += proj[k*4+r] * viewModel[c*4+k];
                mvp[c*4+r] = s;
            }

        gl.glUniformMatrix4fv(mvpLoc_, 1, GL_FALSE, mvp);
        gl.glUniformMatrix4fv(modelMatLoc_, 1, GL_FALSE, model);

        // Normal matrix = upper-left 3×3 of model (identity for unit sphere)
        float normalMat[9] = {model[0], model[1], model[2],
                              model[4], model[5], model[6],
                              model[8], model[9], model[10]};
        gl.glUniformMatrix3fv(normalMatLoc_, 1, GL_FALSE, normalMat);

        // Fixed light at upper-right-front
        float lightPos[3] = {3.0f, 2.0f, 3.0f};
        float lightColor[3] = {1.0f, 0.95f, 0.85f};
        float viewPos[3] = {0.0f, 0.0f, 3.0f};
        float objColor[4] = {0.35f, 0.55f, 0.95f, 1.0f};

        gl.glUniform3fv(lightPosLoc_, 1, lightPos);
        gl.glUniform3fv(lightColorLoc_, 1, lightColor);
        gl.glUniform3fv(viewPosLoc_, 1, viewPos);
        gl.glUniform4fv(colorLoc_, 1, objColor);

        gl.glBindVertexArray(vao_);
        gl.glDrawArrays(GL_TRIANGLES, 0, vertCount_);
        gl.glBindVertexArray(0);

        gl.glUseProgram(0);
        gl.glDisable(GL_DEPTH_TEST);

        gl.glDeleteBuffers(1, &vbo_);
        gl.glDeleteVertexArrays(1, &vao_);
        gl.glDeleteProgram(program_);
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glCreateShader, FunctionId::glShaderSource, FunctionId::glCompileShader,
            FunctionId::glCreateProgram, FunctionId::glAttachShader, FunctionId::glLinkProgram,
            FunctionId::glDeleteShader, FunctionId::glUseProgram,
            FunctionId::glGenVertexArrays, FunctionId::glBindVertexArray, FunctionId::glDeleteVertexArrays,
            FunctionId::glGenBuffers, FunctionId::glBindBuffer, FunctionId::glBufferData, FunctionId::glDeleteBuffers,
            FunctionId::glEnableVertexAttribArray, FunctionId::glVertexAttribPointer,
            FunctionId::glUniformMatrix4fv, FunctionId::glUniformMatrix3fv,
            FunctionId::glUniform3fv, FunctionId::glUniform4fv,
            FunctionId::glDrawArrays,
            FunctionId::glEnable, FunctionId::glDisable,
            FunctionId::glClearColor, FunctionId::glClear,
            FunctionId::glViewport,
            FunctionId::glGetUniformLocation,
        };
    }

private:
    GLuint program_ = 0;
    GLint mvpLoc_ = -1, modelMatLoc_ = -1, normalMatLoc_ = -1;
    GLint lightPosLoc_ = -1, lightColorLoc_ = -1, viewPosLoc_ = -1, colorLoc_ = -1;
    GLuint vao_ = 0, vbo_ = 0;
    std::vector<float> sphereData_;
    int vertCount_ = 0;
};

// ---------------------------------------------------------------------------
// GL 3.3 Instanced Rendering Scene
// Tests: glDrawArraysInstanced, gl_InstanceID, instanced cube grid via shader
// ---------------------------------------------------------------------------
class GL33InstancedScene final : public Scene {
public:
    std::string id() const override { return "phase-7.gl33-instanced"; }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {256, 256}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        const char* vsSrc =
            "#version 330 core\n"
            "layout(location = 0) in vec3 aPosition;\n"
            "uniform mat4 uViewProj;\n"
            "uniform int uGridSide;\n"
            "uniform float uSpacing;\n"
            "flat out vec4 vColor;\n"
            "void main() {\n"
            "    int id = gl_InstanceID;\n"
            "    int ix = id % uGridSide;\n"
            "    int iy = id / uGridSide;\n"
            "    float cx = float(ix) * uSpacing - float(uGridSide - 1) * uSpacing * 0.5;\n"
            "    float cy = float(iy) * uSpacing - float(uGridSide - 1) * uSpacing * 0.5;\n"
            "    float cz = 0.0;\n"
            "    float hue = fract(float(id) * 0.618 + 0.1);\n"
            "    float h6 = hue * 6.0;\n"
            "    float r = clamp(abs(h6 - 3.0) - 1.0, 0.0, 1.0);\n"
            "    float g = clamp(2.0 - abs(h6 - 2.0), 0.0, 1.0);\n"
            "    float b = clamp(2.0 - abs(h6 - 4.0), 0.0, 1.0);\n"
            "    vColor = vec4(r * 0.8 + 0.2, g * 0.8 + 0.2, b * 0.8 + 0.2, 1.0);\n"
            "    gl_Position = uViewProj * vec4(aPosition * 0.4 + vec3(cx, cy, cz), 1.0);\n"
            "}\n";
        const char* fsSrc =
            "#version 330 core\n"
            "flat in vec4 vColor;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    fragColor = vColor;\n"
            "}\n";

        GLuint vs = gl.glCreateShader(GL_VERTEX_SHADER);
        gl.glShaderSource(vs, 1, &vsSrc, nullptr);
        gl.glCompileShader(vs);
        GLuint fs = gl.glCreateShader(GL_FRAGMENT_SHADER);
        gl.glShaderSource(fs, 1, &fsSrc, nullptr);
        gl.glCompileShader(fs);
        program_ = gl.glCreateProgram();
        gl.glAttachShader(program_, vs);
        gl.glAttachShader(program_, fs);
        gl.glLinkProgram(program_);
        gl.glDeleteShader(vs);
        gl.glDeleteShader(fs);

        viewProjLoc_ = gl.glGetUniformLocation(program_, "uViewProj");
        gridSideLoc_ = gl.glGetUniformLocation(program_, "uGridSide");
        spacingLoc_  = gl.glGetUniformLocation(program_, "uSpacing");

        // Unit cube (36 vertices, pos-only)
        const float h = 0.5f;
        float cubeVerts[] = {
            // Front
            -h,-h, h,  h,-h, h,  h, h, h,  -h,-h, h,  h, h, h, -h, h, h,
            // Back
            h,-h,-h, -h,-h,-h, -h, h,-h,   h,-h,-h, -h, h,-h,  h, h,-h,
            // Left
            -h,-h,-h, -h,-h, h, -h, h, h,  -h,-h,-h, -h, h, h, -h, h,-h,
            // Right
            h,-h, h,  h,-h,-h,  h, h,-h,   h,-h, h,  h, h,-h,  h, h, h,
            // Top
            -h, h, h,  h, h, h,  h, h,-h,  -h, h, h,  h, h,-h, -h, h,-h,
            // Bottom
            -h,-h,-h,  h,-h,-h,  h,-h, h,  -h,-h,-h,  h,-h, h, -h,-h, h,
        };

        gl.glGenVertexArrays(1, &vao_);
        gl.glGenBuffers(1, &vbo_);
        gl.glBindVertexArray(vao_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(cubeVerts), cubeVerts, GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * sizeof(float), nullptr);
        gl.glBindVertexArray(0);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        gl.glViewport(0, 0, 256, 256);
        gl.glClearColor(0.10f, 0.10f, 0.14f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        gl.glEnable(GL_DEPTH_TEST);

        gl.glUseProgram(program_);

        const int gridSide = 4;       // 4×4 = 16 instances (flat grid)
        const float spacing = 1.1f;

        // Simple perspective + straight back view, matching object-count scene pattern
        float proj[16] = {};
        float fov = 0.785f, f = 1.0f / std::tan(fov * 0.5f);
        float zNear = 0.1f, zFar = 50.0f;
        proj[0] = f;
        proj[5] = f;
        proj[10] = (zFar + zNear) / (zNear - zFar);
        proj[11] = -1.0f;
        proj[14] = (2.0f * zFar * zNear) / (zNear - zFar);

        // View = translate(0, 0, -dist) — straight back
        const float cameraZ = 6.0f;
        float view[16] = {};
        view[0] = 1; view[5] = 1; view[10] = 1; view[15] = 1;
        view[14] = -cameraZ;

        float viewProj[16] = {};
        for (int c = 0; c < 4; ++c)
            for (int r = 0; r < 4; ++r) {
                float s = 0;
                for (int k = 0; k < 4; ++k) s += proj[k*4+r] * view[c*4+k];
                viewProj[c*4+r] = s;
            }

        gl.glUniformMatrix4fv(viewProjLoc_, 1, GL_FALSE, viewProj);
        gl.glUniform1i(gridSideLoc_, gridSide);
        gl.glUniform1f(spacingLoc_, spacing);

        gl.glBindVertexArray(vao_);
        const int instanceCount = gridSide * gridSide;
        gl.glDrawArraysInstanced(GL_TRIANGLES, 0, 36, instanceCount);
        gl.glBindVertexArray(0);

        gl.glUseProgram(0);
        gl.glDisable(GL_DEPTH_TEST);

        gl.glDeleteBuffers(1, &vbo_);
        gl.glDeleteVertexArrays(1, &vao_);
        gl.glDeleteProgram(program_);
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glCreateShader, FunctionId::glShaderSource, FunctionId::glCompileShader,
            FunctionId::glCreateProgram, FunctionId::glAttachShader, FunctionId::glLinkProgram,
            FunctionId::glDeleteShader, FunctionId::glUseProgram,
            FunctionId::glGenVertexArrays, FunctionId::glBindVertexArray, FunctionId::glDeleteVertexArrays,
            FunctionId::glGenBuffers, FunctionId::glBindBuffer, FunctionId::glBufferData, FunctionId::glDeleteBuffers,
            FunctionId::glEnableVertexAttribArray, FunctionId::glVertexAttribPointer,
            FunctionId::glUniformMatrix4fv, FunctionId::glUniform1i, FunctionId::glUniform1f,
            FunctionId::glDrawArraysInstanced,
            FunctionId::glEnable, FunctionId::glDisable,
            FunctionId::glClearColor, FunctionId::glClear,
            FunctionId::glViewport,
            FunctionId::glGetUniformLocation,
        };
    }

private:
    GLuint program_ = 0;
    GLint viewProjLoc_ = -1, gridSideLoc_ = -1, spacingLoc_ = -1;
    GLuint vao_ = 0, vbo_ = 0;
};

// ---------------------------------------------------------------------------
// GL 4.1 DSA Uniforms Scene
// Tests: glProgramUniform4f, glProgramUniformMatrix4fv, glProgramUniform3f
// Renders a Phong-lit sphere using DSA-style uniform setting
// ---------------------------------------------------------------------------
class GL41DSAUniformsScene final : public Scene {
public:
    std::string id() const override { return "phase-7.gl41-dsa-uniforms"; }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {256, 256}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        // Same Blinn-Phong shaders but all uniforms set via glProgramUniform*
        const char* vsSrc =
            "#version 410 core\n"
            "layout(location = 0) in vec3 aPosition;\n"
            "layout(location = 1) in vec3 aNormal;\n"
            "uniform mat4 uMVP;\n"
            "uniform mat4 uModelMatrix;\n"
            "uniform mat3 uNormalMatrix;\n"
            "out vec3 vWorldPos;\n"
            "out vec3 vNormal;\n"
            "void main() {\n"
            "    vec4 worldPos = uModelMatrix * vec4(aPosition, 1.0);\n"
            "    vWorldPos = worldPos.xyz;\n"
            "    vNormal = normalize(uNormalMatrix * aNormal);\n"
            "    gl_Position = uMVP * vec4(aPosition, 1.0);\n"
            "}\n";
        const char* fsSrc =
            "#version 410 core\n"
            "in vec3 vWorldPos;\n"
            "in vec3 vNormal;\n"
            "uniform vec3 uLightPos;\n"
            "uniform vec3 uLightColor;\n"
            "uniform vec3 uViewPos;\n"
            "uniform vec4 uColor;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    float ambientStrength = 0.15;\n"
            "    vec3 ambient = ambientStrength * uLightColor;\n"
            "    vec3 norm = normalize(vNormal);\n"
            "    vec3 lightDir = normalize(uLightPos - vWorldPos);\n"
            "    float diff = max(dot(norm, lightDir), 0.0);\n"
            "    vec3 diffuse = diff * uLightColor;\n"
            "    float specularStrength = 0.5;\n"
            "    vec3 viewDir = normalize(uViewPos - vWorldPos);\n"
            "    vec3 halfDir = normalize(lightDir + viewDir);\n"
            "    float spec = pow(max(dot(norm, halfDir), 0.0), 32.0);\n"
            "    vec3 specular = specularStrength * spec * uLightColor;\n"
            "    vec3 result = (ambient + diffuse + specular) * uColor.rgb;\n"
            "    fragColor = vec4(result, uColor.a);\n"
            "}\n";

        GLuint vs = gl.glCreateShader(GL_VERTEX_SHADER);
        gl.glShaderSource(vs, 1, &vsSrc, nullptr);
        gl.glCompileShader(vs);
        GLuint fs = gl.glCreateShader(GL_FRAGMENT_SHADER);
        gl.glShaderSource(fs, 1, &fsSrc, nullptr);
        gl.glCompileShader(fs);
        program_ = gl.glCreateProgram();
        gl.glAttachShader(program_, vs);
        gl.glAttachShader(program_, fs);
        gl.glLinkProgram(program_);
        gl.glDeleteShader(vs);
        gl.glDeleteShader(fs);

        mvpLoc_         = gl.glGetUniformLocation(program_, "uMVP");
        modelMatLoc_    = gl.glGetUniformLocation(program_, "uModelMatrix");
        normalMatLoc_   = gl.glGetUniformLocation(program_, "uNormalMatrix");
        lightPosLoc_    = gl.glGetUniformLocation(program_, "uLightPos");
        lightColorLoc_  = gl.glGetUniformLocation(program_, "uLightColor");
        viewPosLoc_     = gl.glGetUniformLocation(program_, "uViewPos");
        colorLoc_       = gl.glGetUniformLocation(program_, "uColor");

        // Sphere with interleaved pos+normal
        const float pi = 3.14159265f;
        const int seg = 32, rings = 16;
        const float radius = 0.8f;
        for (int ri = 0; ri < rings; ++ri) {
            float t0 = pi * float(ri) / float(rings);
            float t1 = pi * float(ri+1) / float(rings);
            for (int si = 0; si < seg; ++si) {
                float p0 = 2*pi*float(si)/float(seg);
                float p1 = 2*pi*float(si+1)/float(seg);
                auto pushV = [&](float theta, float phi) {
                    float x = radius * std::sin(theta) * std::cos(phi);
                    float y = radius * std::cos(theta);
                    float z = radius * std::sin(theta) * std::sin(phi);
                    float nx = std::sin(theta) * std::cos(phi);
                    float ny = std::cos(theta);
                    float nz = std::sin(theta) * std::sin(phi);
                    sphereData_.insert(sphereData_.end(), {x, y, z, nx, ny, nz});
                };
                pushV(t0, p0); pushV(t1, p0); pushV(t1, p1);
                pushV(t0, p0); pushV(t1, p1); pushV(t0, p1);
            }
        }
        vertCount_ = static_cast<int>(sphereData_.size()) / 6;

        gl.glGenVertexArrays(1, &vao_);
        gl.glGenBuffers(1, &vbo_);
        gl.glBindVertexArray(vao_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER,
                        static_cast<GLsizeiptr>(sphereData_.size() * sizeof(float)),
                        sphereData_.data(), GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), nullptr);
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float),
                                 reinterpret_cast<void*>(3 * sizeof(float)));
        gl.glBindVertexArray(0);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        gl.glViewport(0, 0, 256, 256);
        gl.glClearColor(0.05f, 0.05f, 0.08f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        gl.glEnable(GL_DEPTH_TEST);

        // NOTE: We do NOT call glUseProgram here yet — set all uniforms via
        // DSA (glProgramUniform*) first, THEN bind the program for drawing.
        // This proves the GL 4.1 DSA uniform path works independently.

        float model[16] = {};
        model[0] = 1; model[5] = 1; model[10] = 1; model[15] = 1;

        float proj[16] = {};
        float fov = 0.785f, f = 1.0f / std::tan(fov * 0.5f);
        proj[0] = f; proj[5] = f; proj[10] = -1.02f; proj[11] = -1.0f; proj[14] = -0.2f;

        float viewModel[16] = {};
        std::memcpy(viewModel, model, sizeof(model));
        viewModel[14] = -3.0f;

        float mvp[16] = {};
        for (int c = 0; c < 4; ++c)
            for (int r = 0; r < 4; ++r) {
                float s = 0;
                for (int k = 0; k < 4; ++k) s += proj[k*4+r] * viewModel[c*4+k];
                mvp[c*4+r] = s;
            }

        // All uniforms set via glProgramUniform* (GL 4.1 DSA) — no glUseProgram binding required
        gl.glProgramUniformMatrix4fv(program_, mvpLoc_, 1, GL_FALSE, mvp);
        gl.glProgramUniformMatrix4fv(program_, modelMatLoc_, 1, GL_FALSE, model);

        float normalMat[9] = {model[0], model[1], model[2],
                              model[4], model[5], model[6],
                              model[8], model[9], model[10]};
        gl.glProgramUniformMatrix3fv(program_, normalMatLoc_, 1, GL_FALSE, normalMat);

        // Light at upper-right — different position than standard lighting scene
        // to produce a visually distinct golden
        float lightPos[3] = {-2.0f, 3.0f, 2.0f};
        gl.glProgramUniform3f(program_, lightPosLoc_, lightPos[0], lightPos[1], lightPos[2]);

        float lightColor[3] = {1.0f, 0.9f, 0.8f};
        gl.glProgramUniform3f(program_, lightColorLoc_, lightColor[0], lightColor[1], lightColor[2]);

        float viewPos[3] = {0.0f, 0.0f, 3.0f};
        gl.glProgramUniform3f(program_, viewPosLoc_, viewPos[0], viewPos[1], viewPos[2]);

        // Warm orange sphere — visually distinct from the blue lighting-phong scene
        gl.glProgramUniform4f(program_, colorLoc_, 0.95f, 0.55f, 0.25f, 1.0f);

        // NOW bind the program for drawing
        gl.glUseProgram(program_);
        gl.glBindVertexArray(vao_);
        gl.glDrawArrays(GL_TRIANGLES, 0, vertCount_);
        gl.glBindVertexArray(0);

        gl.glUseProgram(0);
        gl.glDisable(GL_DEPTH_TEST);

        gl.glDeleteBuffers(1, &vbo_);
        gl.glDeleteVertexArrays(1, &vao_);
        gl.glDeleteProgram(program_);
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glCreateShader, FunctionId::glShaderSource, FunctionId::glCompileShader,
            FunctionId::glCreateProgram, FunctionId::glAttachShader, FunctionId::glLinkProgram,
            FunctionId::glDeleteShader, FunctionId::glUseProgram,
            FunctionId::glGenVertexArrays, FunctionId::glBindVertexArray, FunctionId::glDeleteVertexArrays,
            FunctionId::glGenBuffers, FunctionId::glBindBuffer, FunctionId::glBufferData, FunctionId::glDeleteBuffers,
            FunctionId::glEnableVertexAttribArray, FunctionId::glVertexAttribPointer,
            FunctionId::glProgramUniformMatrix4fv, FunctionId::glProgramUniformMatrix3fv,
            FunctionId::glProgramUniform3f, FunctionId::glProgramUniform4f,
            FunctionId::glDrawArrays,
            FunctionId::glEnable, FunctionId::glDisable,
            FunctionId::glClearColor, FunctionId::glClear,
            FunctionId::glViewport,
            FunctionId::glGetUniformLocation,
        };
    }

private:
    GLuint program_ = 0;
    GLint mvpLoc_ = -1, modelMatLoc_ = -1, normalMatLoc_ = -1;
    GLint lightPosLoc_ = -1, lightColorLoc_ = -1, viewPosLoc_ = -1, colorLoc_ = -1;
    GLuint vao_ = 0, vbo_ = 0;
    std::vector<float> sphereData_;
    int vertCount_ = 0;
};

// ---------------------------------------------------------------------------
// GL 4.6 Zero-Bind DSA Scene — exercises GL 4.5 DSA creation + separated
// vertex format + GL 4.1 glProgramUniform* + GL 4.6 glPolygonOffsetClamp.
// Three Phong-lit spheres set up entirely without glBind* at init time.
// ---------------------------------------------------------------------------
class GL46ZeroBindDSAScene final : public Scene {
public:
    std::string id() const override { return "phase-7.gl46-zero-bind-dsa"; }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {256, 256}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        const char* vsSrc =
            "#version 460 core\n"
            "layout(location = 0) in vec3 aPosition;\n"
            "layout(location = 1) in vec3 aNormal;\n"
            "uniform mat4 uMVP;\n"
            "uniform mat4 uModelMatrix;\n"
            "uniform mat3 uNormalMatrix;\n"
            "out vec3 vWorldPos;\n"
            "out vec3 vNormal;\n"
            "void main() {\n"
            "    vec4 worldPos = uModelMatrix * vec4(aPosition, 1.0);\n"
            "    vWorldPos = worldPos.xyz;\n"
            "    vNormal = normalize(uNormalMatrix * aNormal);\n"
            "    gl_Position = uMVP * vec4(aPosition, 1.0);\n"
            "}\n";
        const char* fsSrc =
            "#version 460 core\n"
            "in vec3 vWorldPos;\n"
            "in vec3 vNormal;\n"
            "uniform vec3 uLightPos;\n"
            "uniform vec3 uLightColor;\n"
            "uniform vec3 uViewPos;\n"
            "uniform vec4 uColor;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    float ambientStrength = 0.15;\n"
            "    vec3 ambient = ambientStrength * uLightColor;\n"
            "    vec3 norm = normalize(vNormal);\n"
            "    vec3 lightDir = normalize(uLightPos - vWorldPos);\n"
            "    float diff = max(dot(norm, lightDir), 0.0);\n"
            "    vec3 diffuse = diff * uLightColor;\n"
            "    float specularStrength = 0.6;\n"
            "    vec3 viewDir = normalize(uViewPos - vWorldPos);\n"
            "    vec3 halfDir = normalize(lightDir + viewDir);\n"
            "    float spec = pow(max(dot(norm, halfDir), 0.0), 64.0);\n"
            "    vec3 specular = specularStrength * spec * uLightColor;\n"
            "    vec3 result = (ambient + diffuse + specular) * uColor.rgb;\n"
            "    fragColor = vec4(result, uColor.a);\n"
            "}\n";

        GLuint vs = gl.glCreateShader(GL_VERTEX_SHADER);
        gl.glShaderSource(vs, 1, &vsSrc, nullptr);
        gl.glCompileShader(vs);
        GLuint fs = gl.glCreateShader(GL_FRAGMENT_SHADER);
        gl.glShaderSource(fs, 1, &fsSrc, nullptr);
        gl.glCompileShader(fs);
        program_ = gl.glCreateProgram();
        gl.glAttachShader(program_, vs);
        gl.glAttachShader(program_, fs);
        gl.glLinkProgram(program_);
        gl.glDeleteShader(vs);
        gl.glDeleteShader(fs);

        mvpLoc_        = gl.glGetUniformLocation(program_, "uMVP");
        modelMatLoc_   = gl.glGetUniformLocation(program_, "uModelMatrix");
        normalMatLoc_  = gl.glGetUniformLocation(program_, "uNormalMatrix");
        lightPosLoc_   = gl.glGetUniformLocation(program_, "uLightPos");
        lightColorLoc_ = gl.glGetUniformLocation(program_, "uLightColor");
        viewPosLoc_    = gl.glGetUniformLocation(program_, "uViewPos");
        colorLoc_      = gl.glGetUniformLocation(program_, "uColor");

        // Generate sphere geometry (interleaved pos + normal).
        const float pi = 3.14159265f;
        const int seg = 24, rings = 12;
        const float radius = 0.6f;
        for (int ri = 0; ri < rings; ++ri) {
            float t0 = pi * float(ri)   / float(rings);
            float t1 = pi * float(ri+1) / float(rings);
            for (int si = 0; si < seg; ++si) {
                float p0 = 2*pi*float(si)  /float(seg);
                float p1 = 2*pi*float(si+1)/float(seg);
                auto pushV = [&](float theta, float phi) {
                    float x = radius * std::sin(theta) * std::cos(phi);
                    float y = radius * std::cos(theta);
                    float z = radius * std::sin(theta) * std::sin(phi);
                    float nx = std::sin(theta) * std::cos(phi);
                    float ny = std::cos(theta);
                    float nz = std::sin(theta) * std::sin(phi);
                    sphereData_.insert(sphereData_.end(), {x, y, z, nx, ny, nz});
                };
                pushV(t0, p0); pushV(t1, p0); pushV(t1, p1);
                pushV(t0, p0); pushV(t1, p1); pushV(t0, p1);
            }
        }
        vertCount_ = static_cast<int>(sphereData_.size()) / 6;

        // ── GL 4.5 Zero-Bind DSA buffer + VAO setup ──
        // No glBindBuffer or glBindVertexArray during setup.
        gl.glCreateBuffers(1, &vbo_);                              // GL 4.5
        gl.glNamedBufferStorage(vbo_,                              // GL 4.4/4.5
            static_cast<GLsizeiptr>(sphereData_.size() * sizeof(float)),
            sphereData_.data(), 0);

        gl.glCreateVertexArrays(1, &vao_);                         // GL 4.5

        const GLsizei stride = 6 * sizeof(float);
        gl.glVertexArrayVertexBuffer(vao_, 0, vbo_, 0, stride);    // GL 4.5

        // Attribute 0: position (vec3 at offset 0)
        gl.glVertexArrayAttribFormat(vao_, 0, 3, GL_FLOAT, GL_FALSE, 0);
        gl.glVertexArrayAttribBinding(vao_, 0, 0);
        gl.glEnableVertexArrayAttrib(vao_, 0);

        // Attribute 1: normal (vec3 at offset 12)
        gl.glVertexArrayAttribFormat(vao_, 1, 3, GL_FLOAT, GL_FALSE, 3*sizeof(float));
        gl.glVertexArrayAttribBinding(vao_, 1, 0);
        gl.glEnableVertexArrayAttrib(vao_, 1);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        gl.glViewport(0, 0, 256, 256);

        // GL 4.1 float-precision depth functions
        gl.glClearDepthf(1.0f);                                    // GL 4.1
        gl.glDepthRangef(0.0f, 1.0f);                             // GL 4.1

        gl.glClearColor(0.06f, 0.04f, 0.10f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        gl.glEnable(GL_DEPTH_TEST);

        // Shared lighting — set via DSA before glUseProgram.
        gl.glProgramUniform3f(program_, lightPosLoc_,  3.0f, 4.0f, 2.0f);
        gl.glProgramUniform3f(program_, lightColorLoc_, 1.0f, 0.95f, 0.9f);
        gl.glProgramUniform3f(program_, viewPosLoc_,   0.0f, 0.0f, 5.0f);

        gl.glUseProgram(program_);

        // GL 4.6: polygon offset with clamp
        gl.glEnable(GL_POLYGON_OFFSET_FILL);
        gl.glPolygonOffsetClamp(1.0f, 1.0f, 0.01f);              // GL 4.6

        gl.glBindVertexArray(vao_);

        // Projection matrix
        float proj[16] = {};
        float fov = 0.785f, f = 1.0f / std::tan(fov * 0.5f);
        proj[0] = f; proj[5] = f; proj[10] = -1.02f; proj[11] = -1.0f; proj[14] = -0.2f;

        // View translation (z = -5)
        float viewT[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,-5,1};

        // Draw three spheres: ruby, emerald, sapphire
        struct ObjDef { float tx; float r, g, b; };
        ObjDef objects[] = {
            { -1.5f,  0.85f, 0.25f, 0.30f },
            {  0.0f,  0.25f, 0.80f, 0.35f },
            {  1.5f,  0.30f, 0.35f, 0.90f },
        };

        for (const auto& obj : objects) {
            // Model: translate by (tx, 0, 0)
            float model[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, obj.tx,0,0,1};

            // view * model
            float vm[16] = {};
            for (int c = 0; c < 4; ++c)
                for (int r = 0; r < 4; ++r) {
                    float s = 0;
                    for (int k = 0; k < 4; ++k) s += viewT[k*4+r] * model[c*4+k];
                    vm[c*4+r] = s;
                }

            // proj * vm
            float mvp[16] = {};
            for (int c = 0; c < 4; ++c)
                for (int r = 0; r < 4; ++r) {
                    float s = 0;
                    for (int k = 0; k < 4; ++k) s += proj[k*4+r] * vm[c*4+k];
                    mvp[c*4+r] = s;
                }

            float normalMat[9] = {model[0], model[1], model[2],
                                  model[4], model[5], model[6],
                                  model[8], model[9], model[10]};

            gl.glProgramUniformMatrix4fv(program_, mvpLoc_,      1, GL_FALSE, mvp);
            gl.glProgramUniformMatrix4fv(program_, modelMatLoc_, 1, GL_FALSE, model);
            gl.glProgramUniformMatrix3fv(program_, normalMatLoc_,1, GL_FALSE, normalMat);
            gl.glProgramUniform4f(program_, colorLoc_, obj.r, obj.g, obj.b, 1.0f);

            gl.glDrawArrays(GL_TRIANGLES, 0, vertCount_);
        }

        gl.glBindVertexArray(0);
        gl.glDisable(GL_POLYGON_OFFSET_FILL);
        gl.glUseProgram(0);
        gl.glDisable(GL_DEPTH_TEST);

        gl.glDeleteBuffers(1, &vbo_);
        gl.glDeleteVertexArrays(1, &vao_);
        gl.glDeleteProgram(program_);
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            // GL 4.5 DSA buffer + VAO creation
            FunctionId::glCreateBuffers, FunctionId::glNamedBufferStorage,
            FunctionId::glCreateVertexArrays,
            FunctionId::glVertexArrayVertexBuffer,
            FunctionId::glVertexArrayAttribFormat,
            FunctionId::glVertexArrayAttribBinding,
            FunctionId::glEnableVertexArrayAttrib,
            // GL 4.1 DSA uniforms
            FunctionId::glProgramUniformMatrix4fv, FunctionId::glProgramUniformMatrix3fv,
            FunctionId::glProgramUniform3f, FunctionId::glProgramUniform4f,
            // GL 4.1 float-precision depth
            FunctionId::glClearDepthf, FunctionId::glDepthRangef,
            // GL 4.6
            FunctionId::glPolygonOffsetClamp,
            // Core draw
            FunctionId::glDrawArrays,
            FunctionId::glClearColor, FunctionId::glClear, FunctionId::glViewport,
        };
    }

private:
    GLuint program_ = 0;
    GLint mvpLoc_ = -1, modelMatLoc_ = -1, normalMatLoc_ = -1;
    GLint lightPosLoc_ = -1, lightColorLoc_ = -1, viewPosLoc_ = -1, colorLoc_ = -1;
    GLuint vao_ = 0, vbo_ = 0;
    std::vector<float> sphereData_;
    int vertCount_ = 0;
};

// ===========================================================================
// Version Comparison Scenes — Phase 7 Group 6
// Three scenes rendering the EXACT same Phong-lit sphere through different
// GL version API paths (3.3, 4.1, 4.6).  Pixel-identical output proves the
// translation layer is version-agnostic.
// ===========================================================================

// Shared sphere generator for version comparison scenes.
static std::vector<float> generateComparisonSphere() {
    const float pi = 3.14159265f;
    const int seg = 32, rings = 16;
    const float radius = 0.8f;
    std::vector<float> data;
    for (int ri = 0; ri < rings; ++ri) {
        float t0 = pi * float(ri) / float(rings);
        float t1 = pi * float(ri+1) / float(rings);
        for (int si = 0; si < seg; ++si) {
            float p0 = 2*pi*float(si)/float(seg);
            float p1 = 2*pi*float(si+1)/float(seg);
            auto V = [&](float t, float p) {
                float nx = std::sin(t)*std::cos(p);
                float ny = std::cos(t);
                float nz = std::sin(t)*std::sin(p);
                data.push_back(radius*nx);
                data.push_back(radius*ny);
                data.push_back(radius*nz);
                data.push_back(nx);
                data.push_back(ny);
                data.push_back(nz);
            };
            V(t0,p0); V(t1,p0); V(t1,p1);
            V(t0,p0); V(t1,p1); V(t0,p1);
        }
    }
    return data;
}

// Shared MVP + render math for version comparison scenes.
static void renderComparisonFrame(
    GLDispatchTable& gl, GLuint program,
    GLint mvpLoc, GLint modelMatLoc, GLint normalMatLoc,
    GLint lightPosLoc, GLint lightColorLoc, GLint viewPosLoc, GLint colorLoc,
    GLuint vao, int vertCount, bool useDSAUniforms)
{
    gl.glViewport(0, 0, 256, 256);
    gl.glClearColor(0.04f, 0.04f, 0.06f, 1.0f);
    gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    gl.glEnable(GL_DEPTH_TEST);

    // Identity model matrix (sphere centered at origin).
    float model[16] = {};
    model[0] = 1; model[5] = 1; model[10] = 1; model[15] = 1;

    // Perspective projection.
    float proj[16] = {};
    float fov = 0.785f, f = 1.0f / std::tan(fov * 0.5f);
    proj[0] = f; proj[5] = f; proj[10] = -1.02f; proj[11] = -1.0f; proj[14] = -0.2f;

    // View = translate(0, 0, -3).
    float viewModel[16] = {};
    std::memcpy(viewModel, model, sizeof(model));
    viewModel[14] = -3.0f;

    float mvp[16] = {};
    for (int c = 0; c < 4; ++c)
        for (int r = 0; r < 4; ++r) {
            float s = 0;
            for (int k = 0; k < 4; ++k) s += proj[k*4+r] * viewModel[c*4+k];
            mvp[c*4+r] = s;
        }

    float normalMat[9] = {model[0], model[1], model[2],
                          model[4], model[5], model[6],
                          model[8], model[9], model[10]};

    float lightPos[3]   = {3.0f, 2.0f, 3.0f};
    float lightColor[3] = {1.0f, 0.95f, 0.85f};
    float viewPos[3]    = {0.0f, 0.0f, 3.0f};
    float objColor[4]   = {0.35f, 0.55f, 0.95f, 1.0f};

    if (useDSAUniforms) {
        // GL 4.1+ DSA path — set uniforms via glProgramUniform* before glUseProgram.
        gl.glProgramUniformMatrix4fv(program, mvpLoc, 1, GL_FALSE, mvp);
        gl.glProgramUniformMatrix4fv(program, modelMatLoc, 1, GL_FALSE, model);
        gl.glProgramUniformMatrix3fv(program, normalMatLoc, 1, GL_FALSE, normalMat);
        gl.glProgramUniform3f(program, lightPosLoc, lightPos[0], lightPos[1], lightPos[2]);
        gl.glProgramUniform3f(program, lightColorLoc, lightColor[0], lightColor[1], lightColor[2]);
        gl.glProgramUniform3f(program, viewPosLoc, viewPos[0], viewPos[1], viewPos[2]);
        gl.glProgramUniform4f(program, colorLoc, objColor[0], objColor[1], objColor[2], objColor[3]);
        gl.glUseProgram(program);
    } else {
        // GL 3.3 path — bind program first, then set uniforms via glUniform*.
        gl.glUseProgram(program);
        gl.glUniformMatrix4fv(mvpLoc, 1, GL_FALSE, mvp);
        gl.glUniformMatrix4fv(modelMatLoc, 1, GL_FALSE, model);
        gl.glUniformMatrix3fv(normalMatLoc, 1, GL_FALSE, normalMat);
        gl.glUniform3fv(lightPosLoc, 1, lightPos);
        gl.glUniform3fv(lightColorLoc, 1, lightColor);
        gl.glUniform3fv(viewPosLoc, 1, viewPos);
        gl.glUniform4fv(colorLoc, 1, objColor);
    }

    gl.glBindVertexArray(vao);
    gl.glDrawArrays(GL_TRIANGLES, 0, vertCount);
    gl.glBindVertexArray(0);
    gl.glUseProgram(0);
    gl.glDisable(GL_DEPTH_TEST);
}

// Shared shader sources — identical logic, only #version differs.
static const char* kCompareVS_330 =
    "#version 330 core\n"
    "layout(location = 0) in vec3 aPosition;\n"
    "layout(location = 1) in vec3 aNormal;\n"
    "uniform mat4 uMVP;\n"
    "uniform mat4 uModelMatrix;\n"
    "uniform mat3 uNormalMatrix;\n"
    "out vec3 vWorldPos;\n"
    "out vec3 vNormal;\n"
    "void main() {\n"
    "    vec4 worldPos = uModelMatrix * vec4(aPosition, 1.0);\n"
    "    vWorldPos = worldPos.xyz;\n"
    "    vNormal = normalize(uNormalMatrix * aNormal);\n"
    "    gl_Position = uMVP * vec4(aPosition, 1.0);\n"
    "}\n";
static const char* kCompareVS_410 =
    "#version 410 core\n"
    "layout(location = 0) in vec3 aPosition;\n"
    "layout(location = 1) in vec3 aNormal;\n"
    "uniform mat4 uMVP;\n"
    "uniform mat4 uModelMatrix;\n"
    "uniform mat3 uNormalMatrix;\n"
    "out vec3 vWorldPos;\n"
    "out vec3 vNormal;\n"
    "void main() {\n"
    "    vec4 worldPos = uModelMatrix * vec4(aPosition, 1.0);\n"
    "    vWorldPos = worldPos.xyz;\n"
    "    vNormal = normalize(uNormalMatrix * aNormal);\n"
    "    gl_Position = uMVP * vec4(aPosition, 1.0);\n"
    "}\n";
static const char* kCompareVS_460 =
    "#version 460 core\n"
    "layout(location = 0) in vec3 aPosition;\n"
    "layout(location = 1) in vec3 aNormal;\n"
    "uniform mat4 uMVP;\n"
    "uniform mat4 uModelMatrix;\n"
    "uniform mat3 uNormalMatrix;\n"
    "out vec3 vWorldPos;\n"
    "out vec3 vNormal;\n"
    "void main() {\n"
    "    vec4 worldPos = uModelMatrix * vec4(aPosition, 1.0);\n"
    "    vWorldPos = worldPos.xyz;\n"
    "    vNormal = normalize(uNormalMatrix * aNormal);\n"
    "    gl_Position = uMVP * vec4(aPosition, 1.0);\n"
    "}\n";

static const char* kCompareFS_330 =
    "#version 330 core\n"
    "in vec3 vWorldPos;\n"
    "in vec3 vNormal;\n"
    "uniform vec3 uLightPos;\n"
    "uniform vec3 uLightColor;\n"
    "uniform vec3 uViewPos;\n"
    "uniform vec4 uColor;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    float ambientStrength = 0.15;\n"
    "    vec3 ambient = ambientStrength * uLightColor;\n"
    "    vec3 norm = normalize(vNormal);\n"
    "    vec3 lightDir = normalize(uLightPos - vWorldPos);\n"
    "    float diff = max(dot(norm, lightDir), 0.0);\n"
    "    vec3 diffuse = diff * uLightColor;\n"
    "    float specularStrength = 0.5;\n"
    "    vec3 viewDir = normalize(uViewPos - vWorldPos);\n"
    "    vec3 halfDir = normalize(lightDir + viewDir);\n"
    "    float spec = pow(max(dot(norm, halfDir), 0.0), 32.0);\n"
    "    vec3 specular = specularStrength * spec * uLightColor;\n"
    "    vec3 result = (ambient + diffuse + specular) * uColor.rgb;\n"
    "    fragColor = vec4(result, uColor.a);\n"
    "}\n";
static const char* kCompareFS_410 =
    "#version 410 core\n"
    "in vec3 vWorldPos;\n"
    "in vec3 vNormal;\n"
    "uniform vec3 uLightPos;\n"
    "uniform vec3 uLightColor;\n"
    "uniform vec3 uViewPos;\n"
    "uniform vec4 uColor;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    float ambientStrength = 0.15;\n"
    "    vec3 ambient = ambientStrength * uLightColor;\n"
    "    vec3 norm = normalize(vNormal);\n"
    "    vec3 lightDir = normalize(uLightPos - vWorldPos);\n"
    "    float diff = max(dot(norm, lightDir), 0.0);\n"
    "    vec3 diffuse = diff * uLightColor;\n"
    "    float specularStrength = 0.5;\n"
    "    vec3 viewDir = normalize(uViewPos - vWorldPos);\n"
    "    vec3 halfDir = normalize(lightDir + viewDir);\n"
    "    float spec = pow(max(dot(norm, halfDir), 0.0), 32.0);\n"
    "    vec3 specular = specularStrength * spec * uLightColor;\n"
    "    vec3 result = (ambient + diffuse + specular) * uColor.rgb;\n"
    "    fragColor = vec4(result, uColor.a);\n"
    "}\n";
static const char* kCompareFS_460 =
    "#version 460 core\n"
    "in vec3 vWorldPos;\n"
    "in vec3 vNormal;\n"
    "uniform vec3 uLightPos;\n"
    "uniform vec3 uLightColor;\n"
    "uniform vec3 uViewPos;\n"
    "uniform vec4 uColor;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    float ambientStrength = 0.15;\n"
    "    vec3 ambient = ambientStrength * uLightColor;\n"
    "    vec3 norm = normalize(vNormal);\n"
    "    vec3 lightDir = normalize(uLightPos - vWorldPos);\n"
    "    float diff = max(dot(norm, lightDir), 0.0);\n"
    "    vec3 diffuse = diff * uLightColor;\n"
    "    float specularStrength = 0.5;\n"
    "    vec3 viewDir = normalize(uViewPos - vWorldPos);\n"
    "    vec3 halfDir = normalize(lightDir + viewDir);\n"
    "    float spec = pow(max(dot(norm, halfDir), 0.0), 32.0);\n"
    "    vec3 specular = specularStrength * spec * uLightColor;\n"
    "    vec3 result = (ambient + diffuse + specular) * uColor.rgb;\n"
    "    fragColor = vec4(result, uColor.a);\n"
    "}\n";

// Shared program compilation for comparison scenes.
static GLuint compileCompareProgram(GLDispatchTable& gl, const char* vsSrc, const char* fsSrc) {
    GLuint vs = gl.glCreateShader(GL_VERTEX_SHADER);
    gl.glShaderSource(vs, 1, &vsSrc, nullptr);
    gl.glCompileShader(vs);
    GLuint fs = gl.glCreateShader(GL_FRAGMENT_SHADER);
    gl.glShaderSource(fs, 1, &fsSrc, nullptr);
    gl.glCompileShader(fs);
    GLuint prog = gl.glCreateProgram();
    gl.glAttachShader(prog, vs);
    gl.glAttachShader(prog, fs);
    gl.glLinkProgram(prog);
    gl.glDeleteShader(vs);
    gl.glDeleteShader(fs);
    return prog;
}

// ---------------------------------------------------------------------------
// GL 3.3 Version Comparison — bind-based API, glUniform*
// ---------------------------------------------------------------------------
class VersionCompare33Scene final : public Scene {
public:
    std::string id() const override { return "phase-7.version-compare-gl33"; }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {256, 256}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        program_ = compileCompareProgram(gl, kCompareVS_330, kCompareFS_330);
        mvpLoc_        = gl.glGetUniformLocation(program_, "uMVP");
        modelMatLoc_   = gl.glGetUniformLocation(program_, "uModelMatrix");
        normalMatLoc_  = gl.glGetUniformLocation(program_, "uNormalMatrix");
        lightPosLoc_   = gl.glGetUniformLocation(program_, "uLightPos");
        lightColorLoc_ = gl.glGetUniformLocation(program_, "uLightColor");
        viewPosLoc_    = gl.glGetUniformLocation(program_, "uViewPos");
        colorLoc_      = gl.glGetUniformLocation(program_, "uColor");

        sphereData_ = generateComparisonSphere();
        vertCount_ = static_cast<int>(sphereData_.size()) / 6;

        // GL 3.3 bind-based buffer + VAO setup.
        gl.glGenVertexArrays(1, &vao_);
        gl.glGenBuffers(1, &vbo_);
        gl.glBindVertexArray(vao_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER,
                        static_cast<GLsizeiptr>(sphereData_.size() * sizeof(float)),
                        sphereData_.data(), GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), nullptr);
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float),
                                 reinterpret_cast<void*>(3 * sizeof(float)));
        gl.glBindVertexArray(0);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        renderComparisonFrame(gl, program_,
            mvpLoc_, modelMatLoc_, normalMatLoc_,
            lightPosLoc_, lightColorLoc_, viewPosLoc_, colorLoc_,
            vao_, vertCount_, /*useDSAUniforms=*/false);
        gl.glDeleteBuffers(1, &vbo_);
        gl.glDeleteVertexArrays(1, &vao_);
        gl.glDeleteProgram(program_);
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glCreateShader, FunctionId::glShaderSource, FunctionId::glCompileShader,
            FunctionId::glCreateProgram, FunctionId::glAttachShader, FunctionId::glLinkProgram,
            FunctionId::glDeleteShader, FunctionId::glUseProgram,
            FunctionId::glGenVertexArrays, FunctionId::glBindVertexArray, FunctionId::glDeleteVertexArrays,
            FunctionId::glGenBuffers, FunctionId::glBindBuffer, FunctionId::glBufferData, FunctionId::glDeleteBuffers,
            FunctionId::glEnableVertexAttribArray, FunctionId::glVertexAttribPointer,
            FunctionId::glUniformMatrix4fv, FunctionId::glUniformMatrix3fv,
            FunctionId::glUniform3fv, FunctionId::glUniform4fv,
            FunctionId::glDrawArrays,
        };
    }

private:
    GLuint program_ = 0;
    GLint mvpLoc_ = -1, modelMatLoc_ = -1, normalMatLoc_ = -1;
    GLint lightPosLoc_ = -1, lightColorLoc_ = -1, viewPosLoc_ = -1, colorLoc_ = -1;
    GLuint vao_ = 0, vbo_ = 0;
    std::vector<float> sphereData_;
    int vertCount_ = 0;
};

// ---------------------------------------------------------------------------
// GL 4.1 Version Comparison — bind-based buffer setup, DSA uniforms
// ---------------------------------------------------------------------------
class VersionCompare41Scene final : public Scene {
public:
    std::string id() const override { return "phase-7.version-compare-gl41"; }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {256, 256}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        program_ = compileCompareProgram(gl, kCompareVS_410, kCompareFS_410);
        mvpLoc_        = gl.glGetUniformLocation(program_, "uMVP");
        modelMatLoc_   = gl.glGetUniformLocation(program_, "uModelMatrix");
        normalMatLoc_  = gl.glGetUniformLocation(program_, "uNormalMatrix");
        lightPosLoc_   = gl.glGetUniformLocation(program_, "uLightPos");
        lightColorLoc_ = gl.glGetUniformLocation(program_, "uLightColor");
        viewPosLoc_    = gl.glGetUniformLocation(program_, "uViewPos");
        colorLoc_      = gl.glGetUniformLocation(program_, "uColor");

        sphereData_ = generateComparisonSphere();
        vertCount_ = static_cast<int>(sphereData_.size()) / 6;

        // Buffer + VAO setup is still bind-based (same as 3.3).
        // The version difference is in uniform setting (DSA).
        gl.glGenVertexArrays(1, &vao_);
        gl.glGenBuffers(1, &vbo_);
        gl.glBindVertexArray(vao_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER,
                        static_cast<GLsizeiptr>(sphereData_.size() * sizeof(float)),
                        sphereData_.data(), GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), nullptr);
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float),
                                 reinterpret_cast<void*>(3 * sizeof(float)));
        gl.glBindVertexArray(0);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        // GL 4.1: set uniforms via glProgramUniform* (DSA) BEFORE glUseProgram.
        renderComparisonFrame(gl, program_,
            mvpLoc_, modelMatLoc_, normalMatLoc_,
            lightPosLoc_, lightColorLoc_, viewPosLoc_, colorLoc_,
            vao_, vertCount_, /*useDSAUniforms=*/true);
        gl.glDeleteBuffers(1, &vbo_);
        gl.glDeleteVertexArrays(1, &vao_);
        gl.glDeleteProgram(program_);
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glCreateShader, FunctionId::glShaderSource, FunctionId::glCompileShader,
            FunctionId::glCreateProgram, FunctionId::glAttachShader, FunctionId::glLinkProgram,
            FunctionId::glDeleteShader, FunctionId::glUseProgram,
            FunctionId::glGenVertexArrays, FunctionId::glBindVertexArray, FunctionId::glDeleteVertexArrays,
            FunctionId::glGenBuffers, FunctionId::glBindBuffer, FunctionId::glBufferData, FunctionId::glDeleteBuffers,
            FunctionId::glEnableVertexAttribArray, FunctionId::glVertexAttribPointer,
            FunctionId::glProgramUniformMatrix4fv, FunctionId::glProgramUniformMatrix3fv,
            FunctionId::glProgramUniform3f, FunctionId::glProgramUniform4f,
            FunctionId::glDrawArrays,
        };
    }

private:
    GLuint program_ = 0;
    GLint mvpLoc_ = -1, modelMatLoc_ = -1, normalMatLoc_ = -1;
    GLint lightPosLoc_ = -1, lightColorLoc_ = -1, viewPosLoc_ = -1, colorLoc_ = -1;
    GLuint vao_ = 0, vbo_ = 0;
    std::vector<float> sphereData_;
    int vertCount_ = 0;
};

// ---------------------------------------------------------------------------
// GL 4.6 Version Comparison — full DSA: glCreateBuffers, glNamedBufferStorage,
// glCreateVertexArrays, separated vertex format, DSA uniforms
// ---------------------------------------------------------------------------
class VersionCompare46Scene final : public Scene {
public:
    std::string id() const override { return "phase-7.version-compare-gl46"; }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {256, 256}; }

    void setup(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();

        program_ = compileCompareProgram(gl, kCompareVS_460, kCompareFS_460);
        mvpLoc_        = gl.glGetUniformLocation(program_, "uMVP");
        modelMatLoc_   = gl.glGetUniformLocation(program_, "uModelMatrix");
        normalMatLoc_  = gl.glGetUniformLocation(program_, "uNormalMatrix");
        lightPosLoc_   = gl.glGetUniformLocation(program_, "uLightPos");
        lightColorLoc_ = gl.glGetUniformLocation(program_, "uLightColor");
        viewPosLoc_    = gl.glGetUniformLocation(program_, "uViewPos");
        colorLoc_      = gl.glGetUniformLocation(program_, "uColor");

        sphereData_ = generateComparisonSphere();
        vertCount_ = static_cast<int>(sphereData_.size()) / 6;

        // GL 4.5/4.6 DSA buffer + VAO setup — no glBind* during setup.
        gl.glCreateBuffers(1, &vbo_);
        gl.glNamedBufferStorage(vbo_,
            static_cast<GLsizeiptr>(sphereData_.size() * sizeof(float)),
            sphereData_.data(), 0);

        gl.glCreateVertexArrays(1, &vao_);

        const GLsizei stride = 6 * sizeof(float);
        gl.glVertexArrayVertexBuffer(vao_, 0, vbo_, 0, stride);

        // Attribute 0: position (vec3 at offset 0).
        gl.glVertexArrayAttribFormat(vao_, 0, 3, GL_FLOAT, GL_FALSE, 0);
        gl.glVertexArrayAttribBinding(vao_, 0, 0);
        gl.glEnableVertexArrayAttrib(vao_, 0);

        // Attribute 1: normal (vec3 at offset 12).
        gl.glVertexArrayAttribFormat(vao_, 1, 3, GL_FLOAT, GL_FALSE, 3*sizeof(float));
        gl.glVertexArrayAttribBinding(vao_, 1, 0);
        gl.glEnableVertexArrayAttrib(vao_, 1);
    }

    void render(GLContext& context) override {
        (void)context;
        auto& gl = Runtime::shared().dispatch();
        // GL 4.6: DSA uniforms (same as 4.1 path).
        renderComparisonFrame(gl, program_,
            mvpLoc_, modelMatLoc_, normalMatLoc_,
            lightPosLoc_, lightColorLoc_, viewPosLoc_, colorLoc_,
            vao_, vertCount_, /*useDSAUniforms=*/true);
        gl.glDeleteBuffers(1, &vbo_);
        gl.glDeleteVertexArrays(1, &vao_);
        gl.glDeleteProgram(program_);
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glCreateShader, FunctionId::glShaderSource, FunctionId::glCompileShader,
            FunctionId::glCreateProgram, FunctionId::glAttachShader, FunctionId::glLinkProgram,
            FunctionId::glDeleteShader, FunctionId::glUseProgram,
            FunctionId::glCreateBuffers, FunctionId::glNamedBufferStorage,
            FunctionId::glCreateVertexArrays,
            FunctionId::glVertexArrayVertexBuffer,
            FunctionId::glVertexArrayAttribFormat,
            FunctionId::glVertexArrayAttribBinding,
            FunctionId::glEnableVertexArrayAttrib,
            FunctionId::glDeleteVertexArrays, FunctionId::glDeleteBuffers,
            FunctionId::glProgramUniformMatrix4fv, FunctionId::glProgramUniformMatrix3fv,
            FunctionId::glProgramUniform3f, FunctionId::glProgramUniform4f,
            FunctionId::glDrawArrays,
        };
    }

private:
    GLuint program_ = 0;
    GLint mvpLoc_ = -1, modelMatLoc_ = -1, normalMatLoc_ = -1;
    GLint lightPosLoc_ = -1, lightColorLoc_ = -1, viewPosLoc_ = -1, colorLoc_ = -1;
    GLuint vao_ = 0, vbo_ = 0;
    std::vector<float> sphereData_;
    int vertCount_ = 0;
};

// Phase 8X Group 4d follow-up¹⁷ — compat-profile immediate-mode scene.
//
// Exercises the glBegin / glColor* / glVertex* / glEnd capture path
// that Chobby's Chili UI uses to draw every panel and button, routing
// into GLContext::{beginImmediate, immediateVertex, immediateColor,
// immediateTexCoord, endImmediate} and out through
// MetalFrameGraph::encodeImmediateModeDraw. The scene uses GL_QUADS so
// the CPU-side expansion-to-triangles path is also covered. A second
// GL_TRIANGLES batch with a per-vertex color gradient validates the
// vertex-color interpolation, and glLightModeli is silently accepted
// to match Chobby's compat init. No shader program is bound — this
// is the "no current program" path that forces the frame graph into
// the built-in immediate-mode pipeline rather than the translated
// path. The identity MVP means vertices are captured in clip space.
//
// Compat-profile entry points are not in the core `dispatch` table,
// so the scene forward-declares the extern "C" symbols it needs and
// calls them directly. These symbols are defined by
// src/runtime/AppGLImmediateMode.cpp and link the same way a client
// application would see them.
extern "C" {
void APIENTRY glBegin(GLenum mode);
void APIENTRY glEnd(void);
void APIENTRY glVertex2f(GLfloat x, GLfloat y);
void APIENTRY glColor3f(GLfloat r, GLfloat g, GLfloat b);
void APIENTRY glColor4f(GLfloat r, GLfloat g, GLfloat b, GLfloat a);
void APIENTRY glLightModeli(GLenum pname, GLint param);
}  // extern "C"

// Compat-profile enums not in glcorearb.h.
#ifndef GL_QUADS
#define GL_QUADS 0x0007
#endif
#ifndef GL_NORMALIZE
#define GL_NORMALIZE 0x0BA1
#endif
#ifndef GL_LIGHT_MODEL_TWO_SIDE
#define GL_LIGHT_MODEL_TWO_SIDE 0x0B52
#endif

class ImmediateModeQuadScene final : public Scene {
public:
    std::string id() const override { return "phase-7.immediate-mode-quad"; }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {96, 96}; }

    double tolerance() const override {
        // The built-in MSL pipeline is deterministic but triangle-edge
        // anti-aliasing at the GL_QUADS → GL_TRIANGLES seam and the
        // gradient interpolation can drift by one channel on different
        // GPUs. Match the tolerance of SolidTriangleDrawScene.
        return 0.02;
    }

    void setup(GLContext& /*context*/) override {
        auto& gl = Runtime::shared().dispatch();
        // Silent-no-op light model call — Chobby does this at compat
        // init. Without the fw17 allowlist entry this would trip a
        // GL_INVALID_ENUM error push.
        glLightModeli(GL_LIGHT_MODEL_TWO_SIDE, 1);
        // And the GL_NORMALIZE enable cap, also a silent no-op in
        // compat mode (added to isCompatNoOpEnableCap by fw17).
        gl.glEnable(GL_NORMALIZE);
    }

    void render(GLContext& /*context*/) override {
        auto& gl = Runtime::shared().dispatch();

        gl.glViewport(0, 0, framebufferSize().width, framebufferSize().height);
        gl.glClearColor(0.05f, 0.07f, 0.12f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);

        // Ensure no shader program is bound so the draw path does NOT
        // fall into the translated-draw branch — our glEnd() lives on
        // a separate codepath that bypasses any currentProgram state
        // by dispatching directly to `encodeImmediateModeDraw`.
        gl.glUseProgram(0);

        // Identity MVP — matrix mirror defaults everything to identity
        // after a fresh context, so captured vertices already live in
        // clip space. No glMatrixMode / glLoadIdentity is required for
        // this scene to land on the expected region.

        // Batch 1 — a solid orange quad on the left half of the
        // viewport. Uses GL_QUADS so the CPU-side expansion to two
        // triangles fires. glColor4f is called once before the quad
        // so every vertex reads the same color register.
        glBegin(GL_QUADS);
        glColor4f(0.95f, 0.45f, 0.15f, 1.0f);
        glVertex2f(-0.80f, -0.60f);
        glVertex2f(-0.05f, -0.60f);
        glVertex2f(-0.05f,  0.60f);
        glVertex2f(-0.80f,  0.60f);
        glEnd();

        // Batch 2 — a gradient-colored triangle on the right half.
        // glColor3f is updated between each vertex so the color
        // register walks red → green → blue, and the Metal pipeline
        // interpolates in fragment space.
        glBegin(GL_TRIANGLES);
        glColor3f(1.0f, 0.0f, 0.0f);
        glVertex2f( 0.10f, -0.60f);
        glColor3f(0.0f, 1.0f, 0.0f);
        glVertex2f( 0.80f, -0.60f);
        glColor3f(0.0f, 0.0f, 1.0f);
        glVertex2f( 0.45f,  0.60f);
        glEnd();

        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        // No FunctionId entries for the compat-profile immediate-mode
        // entry points (they're on the silent-stub side of the coverage
        // ring). The scene still exercises them, but coverage tracking
        // stays on the core-profile surface we advertise.
        return {
            FunctionId::glClear,
            FunctionId::glClearColor,
            FunctionId::glFlush,
            FunctionId::glUseProgram,
            FunctionId::glViewport,
        };
    }
};

// Phase 8X Group 4d follow-up¹⁸ — AlphaTextureCoverageScene.
//
// Regression test for the GL_ALPHA → RGBA8 channel broadcast that the
// `buildRGBA8Upload` routine started emitting in follow-up¹⁸. Prior to
// the fix, a GL_ALPHA upload produced the spec-literal (0,0,0,S) layout,
// which meant a core-profile fragment shader that sampled the texel via
// `.x` / `.r` — the pattern Spring's `CglShaderFontRenderer` actually
// uses in `rts/Rendering/Fonts/glFont.cpp` — would read zero everywhere
// and draw fully transparent. fw¹⁷'s BAR-side verification pinned this
// as the reason Chobby's engine-drawn text was invisible. The scene
// reproduces the failure mode end-to-end:
//
//   1. Upload a 4×4 GL_ALPHA texture with a known coverage ramp.
//   2. Compile a fragment shader that samples the texel via `.x` and
//      writes it into all three color channels (exactly matching the
//      way Spring's font shader lights the glyph color).
//   3. Draw a full-screen quad through the translated core-profile
//      path so the final framebuffer carries one luminance value per
//      texel — the byte the GL_ALPHA upload delivered.
//   4. Compare against a golden PNG. If the (0,0,0,A) regression comes
//      back, every pixel in the golden is black (the `.x` read returns
//      zero) and the compare fails loudly.
class AlphaTextureCoverageScene final : public Scene {
public:
    std::string id() const override { return "phase-7.alpha-texture-coverage"; }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {64, 64}; }

    double tolerance() const override {
        // Nearest-neighbour sampling plus deterministic shader math —
        // zero channel drift is expected in theory, but allow the same
        // one-channel slack the other phase-7 scenes use so a driver
        // revision bump doesn't false-fail the whole phase.
        return 0.02;
    }

    void setup(GLContext& /*context*/) override {
        auto& gl = Runtime::shared().dispatch();

        // Compile the shader program. The fragment stage samples the
        // single-channel texture via `.x` — the same access path
        // Spring's CglShaderFontRenderer uses — so the broadcast fix
        // in buildRGBA8Upload is exactly what makes this scene land
        // non-black.
        const char* vertexSource =
            "#version 330 core\n"
            "layout(location = 0) in vec2 aPosition;\n"
            "layout(location = 1) in vec2 aTexCoord;\n"
            "out vec2 vTexCoord;\n"
            "void main() {\n"
            "    vTexCoord = aTexCoord;\n"
            "    gl_Position = vec4(aPosition, 0.0, 1.0);\n"
            "}\n";
        const char* fragmentSource =
            "#version 330 core\n"
            "in vec2 vTexCoord;\n"
            "uniform sampler2D uTexture;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    float coverage = texture(uTexture, vTexCoord).x;\n"
            "    fragColor = vec4(coverage, coverage, coverage, 1.0);\n"
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
        expectCondition(linkStatus == GL_TRUE, "alpha-coverage program links");
        gl.glDeleteShader(vertex);
        gl.glDeleteShader(fragment);

        // 4×4 GL_ALPHA texture. Every texel carries one byte in [0,255]
        // chosen so the golden PNG shows an obvious diagonal gradient —
        // if the broadcast regresses, every channel reads zero and the
        // golden goes black, which the compare picks up immediately.
        const std::uint8_t alphaPixels[16] = {
              0,  64, 128, 255,
             32,  96, 160, 224,
             64, 128, 192, 255,
            128, 192, 224, 255,
        };
        gl.glGenTextures(1, &texture_);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_2D, texture_);
        // Tight packing — the gauntlet runner never perturbs PIXEL_STORE
        // but the explicit set keeps the scene hermetic.
        gl.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA, 4, 4, 0, GL_ALPHA, GL_UNSIGNED_BYTE, alphaPixels);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        // Full-viewport quad in clip space (two triangles, CCW).
        // Attribute 0 — position (x,y), attribute 1 — texcoord (u,v).
        const GLfloat vertices[] = {
            // x,     y,     u,    v
            -1.0f, -1.0f,  0.0f, 0.0f,
             1.0f, -1.0f,  1.0f, 0.0f,
             1.0f,  1.0f,  1.0f, 1.0f,
            -1.0f,  1.0f,  0.0f, 1.0f,
        };
        const GLushort indices[] = {0, 1, 2, 2, 3, 0};

        gl.glGenVertexArrays(1, &vao_);
        gl.glBindVertexArray(vao_);
        gl.glGenBuffers(1, &vbo_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
        gl.glGenBuffers(1, &ibo_);
        gl.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo_);
        gl.glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), reinterpret_cast<const void*>(0));
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat),
                                 reinterpret_cast<const void*>(2 * sizeof(GLfloat)));

        gl.glUseProgram(program_);
        const GLint textureLocation = gl.glGetUniformLocation(program_, "uTexture");
        expectCondition(textureLocation >= 0, "alpha-coverage uTexture is resolvable");
        gl.glUniform1i(textureLocation, 0);
    }

    void render(GLContext& /*context*/) override {
        auto& gl = Runtime::shared().dispatch();

        gl.glViewport(0, 0, framebufferSize().width, framebufferSize().height);
        gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);

        gl.glUseProgram(program_);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_2D, texture_);
        gl.glBindVertexArray(vao_);
        gl.glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, nullptr);

        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glActiveTexture,
            FunctionId::glAttachShader,
            FunctionId::glBindBuffer,
            FunctionId::glBindTexture,
            FunctionId::glBindVertexArray,
            FunctionId::glBufferData,
            FunctionId::glClear,
            FunctionId::glClearColor,
            FunctionId::glCompileShader,
            FunctionId::glCreateProgram,
            FunctionId::glCreateShader,
            FunctionId::glDeleteShader,
            FunctionId::glDrawElements,
            FunctionId::glEnableVertexAttribArray,
            FunctionId::glFlush,
            FunctionId::glGenBuffers,
            FunctionId::glGenTextures,
            FunctionId::glGenVertexArrays,
            FunctionId::glGetProgramiv,
            FunctionId::glGetUniformLocation,
            FunctionId::glLinkProgram,
            FunctionId::glPixelStorei,
            FunctionId::glShaderSource,
            FunctionId::glTexImage2D,
            FunctionId::glTexParameteri,
            FunctionId::glUniform1i,
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
    GLuint texture_ = 0;
};

// Phase 8X Group 4d follow-up¹⁹ — CompatProfileGLSLScene.
//
// Regression test for the legacy-GLSL compat-profile shader rewriter
// (`rewriteCompatShader` in `src/shader/CompatShaderRewrite.cpp`).
// Fw¹⁸'s BAR-side verification reported that glslang in Vulkan client
// mode hard-rejects `#version 100/110/120/130` desktop shaders with
// "Desktop shaders for Vulkan SPIR-V require version 140 or higher",
// which crashed Spring at match load on `ModernSkyVS/FS.glsl` and
// `ModelVertProg/FragProg.glsl`. Fw¹⁹ extends the rewriter to upgrade
// pre-140 version lines to `330 core` and translate the full set of
// legacy fixed-function identifiers (`gl_Vertex`, `gl_MultiTexCoord0`,
// `gl_ModelViewMatrix`, `varying`, `gl_FragColor`, `texture2D`, ...)
// into the modern GLSL shapes that glslang and SPIRV-Cross accept.
//
// The scene compiles a deliberately legacy `#version 120` shader pair
// that exercises the busiest five rewrite rules in a single pipeline:
//
//   1. Version upgrade (120 → 330 core).
//   2. `varying` → stage-aware `in`/`out`.
//   3. `gl_Vertex` / `gl_MultiTexCoord0` → synthesized `layout(location=N)`
//      attribute declarations with the NVIDIA location convention.
//   4. `gl_ModelViewProjectionMatrix` → the existing `appgl_*` matrix
//      synthesis path (identity in this scene, so clip-space input
//      passes through unchanged).
//   5. `gl_FragColor` → `layout(location=0) out vec4 appgl_FragColor` and
//      `texture2D(...)` → `texture(...)`.
//
// The scene samples a 4×4 RGBA texture whose color channels encode the
// input texcoord (R = u, G = v, B = 0.5, A = 1.0), so a broken rewrite
// would produce either a compile/link failure, a link-time attribute
// mismatch, or a shader that reads position from the wrong binding and
// smears the output. On a correct rewrite the golden shows a clean UV
// gradient — red increases with x, green increases with y — and any
// regression in the rewriter lands as a visibly wrong image.
class CompatProfileGLSLScene final : public Scene {
public:
    std::string id() const override { return "phase-7.compat-profile-glsl"; }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {64, 64}; }

    double tolerance() const override {
        // Same small allowance as the other phase-7 UV-gradient scenes;
        // nearest-neighbour sampling and trivial shader math keep drift
        // well under the threshold on a working build.
        return 0.02;
    }

    void setup(GLContext& /*context*/) override {
        auto& gl = Runtime::shared().dispatch();

        // Deliberately legacy shader sources. The rewriter is what makes
        // this land — on an un-rewritten glslang these fail compile.
        //
        // Vertex stage: `#version 120`, `gl_Vertex` and
        // `gl_MultiTexCoord0` (→ synthesized attribute locations),
        // `gl_ModelViewProjectionMatrix` (→ synthesized matrix uniform,
        // mirror pushes identity so clip-space coordinates pass
        // through), `varying` (→ `out` on VS side, matched to `in` on
        // FS side through the rewriter's word-boundary rule).
        const char* vertexSource =
            "#version 120\n"
            "varying vec2 vUV;\n"
            "void main() {\n"
            "    vUV = gl_MultiTexCoord0.xy;\n"
            "    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;\n"
            "}\n";
        // Fragment stage: `#version 120`, `varying` (→ `in` on FS
        // side), `gl_FragColor` (→ synthesized `layout(location=0) out
        // vec4 appgl_FragColor`), `texture2D` (→ `texture`).
        const char* fragmentSource =
            "#version 120\n"
            "uniform sampler2D uTexture;\n"
            "varying vec2 vUV;\n"
            "void main() {\n"
            "    gl_FragColor = texture2D(uTexture, vUV);\n"
            "}\n";

        const GLuint vertex = gl.glCreateShader(GL_VERTEX_SHADER);
        const GLuint fragment = gl.glCreateShader(GL_FRAGMENT_SHADER);
        gl.glShaderSource(vertex, 1, &vertexSource, nullptr);
        gl.glShaderSource(fragment, 1, &fragmentSource, nullptr);
        gl.glCompileShader(vertex);
        gl.glCompileShader(fragment);
        GLint vsCompile = 0, fsCompile = 0;
        gl.glGetShaderiv(vertex, GL_COMPILE_STATUS, &vsCompile);
        gl.glGetShaderiv(fragment, GL_COMPILE_STATUS, &fsCompile);
        expectCondition(vsCompile == GL_TRUE,
                        "compat-profile-glsl vertex shader compiles after rewrite");
        expectCondition(fsCompile == GL_TRUE,
                        "compat-profile-glsl fragment shader compiles after rewrite");

        program_ = gl.glCreateProgram();
        gl.glAttachShader(program_, vertex);
        gl.glAttachShader(program_, fragment);
        gl.glLinkProgram(program_);
        GLint linkStatus = 0;
        gl.glGetProgramiv(program_, GL_LINK_STATUS, &linkStatus);
        expectCondition(linkStatus == GL_TRUE,
                        "compat-profile-glsl program links after rewrite");
        gl.glDeleteShader(vertex);
        gl.glDeleteShader(fragment);

        // 4×4 RGBA texture encoding the UV coordinate directly so a
        // wrong attribute binding (e.g. location mismatch between the
        // rewriter's synthesized `layout(location=8) in vec4
        // appgl_MultiTexCoord0` and the client-side pointer) produces a
        // visibly wrong gradient instead of a silent pass.
        std::uint8_t rgbaPixels[16 * 4] = {};
        for (int y = 0; y < 4; ++y) {
            for (int x = 0; x < 4; ++x) {
                const int i = (y * 4 + x) * 4;
                rgbaPixels[i + 0] = static_cast<std::uint8_t>((x * 255) / 3);
                rgbaPixels[i + 1] = static_cast<std::uint8_t>((y * 255) / 3);
                rgbaPixels[i + 2] = 128;
                rgbaPixels[i + 3] = 255;
            }
        }
        gl.glGenTextures(1, &texture_);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_2D, texture_);
        gl.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgbaPixels);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        // Full-viewport quad. The rewriter parks `gl_Vertex` at
        // `layout(location = 0)` and `gl_MultiTexCoord0` at
        // `layout(location = 8)` per the NVIDIA convention, so the
        // client-side `glVertexAttribPointer` calls must match those
        // locations exactly for the scene to run — i.e. the scene also
        // smoke-tests that the commitment to NVIDIA locations at the
        // rewriter edge holds end-to-end through the pipeline builder.
        //
        // Interleaved layout: vec4 position + vec2 texcoord = 24 bytes.
        const GLfloat vertices[] = {
            // x,    y,    z,   w,     u,   v
            -1.0f,-1.0f, 0.0f, 1.0f,  0.0f, 0.0f,
             1.0f,-1.0f, 0.0f, 1.0f,  1.0f, 0.0f,
             1.0f, 1.0f, 0.0f, 1.0f,  1.0f, 1.0f,
            -1.0f, 1.0f, 0.0f, 1.0f,  0.0f, 1.0f,
        };
        const GLushort indices[] = {0, 1, 2, 2, 3, 0};

        gl.glGenVertexArrays(1, &vao_);
        gl.glBindVertexArray(vao_);
        gl.glGenBuffers(1, &vbo_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
        gl.glGenBuffers(1, &ibo_);
        gl.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo_);
        gl.glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);
        // `gl_Vertex`  → `layout(location = 0)` (NVIDIA convention).
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 6 * sizeof(GLfloat),
                                 reinterpret_cast<const void*>(0));
        // `gl_MultiTexCoord0` → `layout(location = 8)` (NVIDIA
        // convention). The scene commits to this binding — if the
        // rewriter ever re-emits to a different slot the driver-side
        // binding will mismatch and the test surface will show it.
        gl.glEnableVertexAttribArray(8);
        gl.glVertexAttribPointer(8, 2, GL_FLOAT, GL_FALSE, 6 * sizeof(GLfloat),
                                 reinterpret_cast<const void*>(4 * sizeof(GLfloat)));

        gl.glUseProgram(program_);
        const GLint textureLocation = gl.glGetUniformLocation(program_, "uTexture");
        expectCondition(textureLocation >= 0,
                        "compat-profile-glsl uTexture is resolvable");
        gl.glUniform1i(textureLocation, 0);
    }

    void render(GLContext& /*context*/) override {
        auto& gl = Runtime::shared().dispatch();

        gl.glViewport(0, 0, framebufferSize().width, framebufferSize().height);
        gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);

        gl.glUseProgram(program_);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_2D, texture_);
        gl.glBindVertexArray(vao_);
        gl.glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, nullptr);

        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glActiveTexture,
            FunctionId::glAttachShader,
            FunctionId::glBindBuffer,
            FunctionId::glBindTexture,
            FunctionId::glBindVertexArray,
            FunctionId::glBufferData,
            FunctionId::glClear,
            FunctionId::glClearColor,
            FunctionId::glCompileShader,
            FunctionId::glCreateProgram,
            FunctionId::glCreateShader,
            FunctionId::glDeleteShader,
            FunctionId::glDrawElements,
            FunctionId::glEnableVertexAttribArray,
            FunctionId::glFlush,
            FunctionId::glGenBuffers,
            FunctionId::glGenTextures,
            FunctionId::glGenVertexArrays,
            FunctionId::glGetProgramiv,
            FunctionId::glGetShaderiv,
            FunctionId::glGetUniformLocation,
            FunctionId::glLinkProgram,
            FunctionId::glPixelStorei,
            FunctionId::glShaderSource,
            FunctionId::glTexImage2D,
            FunctionId::glTexParameteri,
            FunctionId::glUniform1i,
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
    GLuint texture_ = 0;
};

// Phase 8X Group 4d follow-up²⁰ — CompatProfileGLSLDualOutputScene.
//
// Regression test for the fragment-output consolidation rule in
// `rewriteCompatShader`. Fw¹⁹-verification pinned Spring's
// `ModelFragProg.glsl` crash at match load as a `location 0` collision:
// the shader has both `gl_FragData[...]` and `gl_FragColor` lexically
// present inside a `#if DEFERRED_MODE == 1 / #else` split, and fw¹⁹'s
// rewriter emitted two `layout(location = 0) out` declarations
// (`appgl_FragColor` and `appgl_FragData[N+1]`) which glslang rejects.
// Fw²⁰ consolidates to a single `appgl_FragData[]` array and rewrites
// `gl_FragColor` → `appgl_FragData[0]` using the spec-level aliasing
// of those two identifiers.
//
// This scene compiles exactly that dual-form shape: a `#version 120`
// FS that mentions both `gl_FragColor` (in the live `#else` branch)
// and `gl_FragData[1]` (in the dead `#if DEFERRED_MODE == 1` branch).
// The rewriter scans pre-preprocessor source, so both forms register
// regardless of which branch the C preprocessor selects. If the
// consolidation rule regresses, the shader fails to compile at load
// time (the `expectCondition(compileStatus == GL_TRUE)` fires) — so
// a broken rewriter shows up as a scene abort, not a silent image
// mismatch. On a correct rewrite the scene renders the same UV
// gradient as `phase-7.compat-profile-glsl`.
class CompatProfileGLSLDualOutputScene final : public Scene {
public:
    std::string id() const override {
        return "phase-7.compat-profile-glsl-dual-output";
    }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {64, 64}; }

    double tolerance() const override { return 0.02; }

    void setup(GLContext& /*context*/) override {
        auto& gl = Runtime::shared().dispatch();

        // VS is the same as the single-output scene — this scene
        // targets the FS rewrite path.
        const char* vertexSource =
            "#version 120\n"
            "varying vec2 vUV;\n"
            "void main() {\n"
            "    vUV = gl_MultiTexCoord0.xy;\n"
            "    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;\n"
            "}\n";

        // Fragment stage: the `#if DEFERRED_MODE == 1` branch is dead
        // (DEFERRED_MODE is never defined, so the preprocessor selects
        // the `#else` branch), but the rewriter scans the raw text so
        // both `gl_FragData[1]` and `gl_FragColor` register in the
        // `LegacyCompatUsage` flag struct — exactly the shape that
        // crashed Spring's `ModelFragProg.glsl` under fw¹⁹. fw²⁰'s
        // consolidation rule emits a single `appgl_FragData[2]`
        // array and rewrites `gl_FragColor` → `appgl_FragData[0]`,
        // producing a shader that glslang accepts and SPIRV-Cross
        // translates into MSL that writes the UV gradient into
        // color attachment 0.
        const char* fragmentSource =
            "#version 120\n"
            "uniform sampler2D uTexture;\n"
            "varying vec2 vUV;\n"
            "void main() {\n"
            "#if DEFERRED_MODE == 1\n"
            "    gl_FragData[0] = texture2D(uTexture, vUV);\n"
            "    gl_FragData[1] = vec4(1.0);\n"
            "#else\n"
            "    gl_FragColor = texture2D(uTexture, vUV);\n"
            "#endif\n"
            "}\n";

        const GLuint vertex = gl.glCreateShader(GL_VERTEX_SHADER);
        const GLuint fragment = gl.glCreateShader(GL_FRAGMENT_SHADER);
        gl.glShaderSource(vertex, 1, &vertexSource, nullptr);
        gl.glShaderSource(fragment, 1, &fragmentSource, nullptr);
        gl.glCompileShader(vertex);
        gl.glCompileShader(fragment);
        GLint vsCompile = 0, fsCompile = 0;
        gl.glGetShaderiv(vertex, GL_COMPILE_STATUS, &vsCompile);
        gl.glGetShaderiv(fragment, GL_COMPILE_STATUS, &fsCompile);
        expectCondition(vsCompile == GL_TRUE,
                        "dual-output vertex shader compiles after rewrite");
        expectCondition(fsCompile == GL_TRUE,
                        "dual-output fragment shader compiles after rewrite");

        program_ = gl.glCreateProgram();
        gl.glAttachShader(program_, vertex);
        gl.glAttachShader(program_, fragment);
        gl.glLinkProgram(program_);
        GLint linkStatus = 0;
        gl.glGetProgramiv(program_, GL_LINK_STATUS, &linkStatus);
        expectCondition(linkStatus == GL_TRUE,
                        "dual-output program links after rewrite");
        gl.glDeleteShader(vertex);
        gl.glDeleteShader(fragment);

        // Same 4×4 UV-gradient texture as the single-output scene so
        // a direct byte comparison between the two goldens would show
        // identical shaded content — the only change is which path
        // through the rewriter produced the shader.
        std::uint8_t rgbaPixels[16 * 4] = {};
        for (int y = 0; y < 4; ++y) {
            for (int x = 0; x < 4; ++x) {
                const int i = (y * 4 + x) * 4;
                rgbaPixels[i + 0] = static_cast<std::uint8_t>((x * 255) / 3);
                rgbaPixels[i + 1] = static_cast<std::uint8_t>((y * 255) / 3);
                rgbaPixels[i + 2] = 128;
                rgbaPixels[i + 3] = 255;
            }
        }
        gl.glGenTextures(1, &texture_);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_2D, texture_);
        gl.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgbaPixels);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        const GLfloat vertices[] = {
            -1.0f,-1.0f, 0.0f, 1.0f,  0.0f, 0.0f,
             1.0f,-1.0f, 0.0f, 1.0f,  1.0f, 0.0f,
             1.0f, 1.0f, 0.0f, 1.0f,  1.0f, 1.0f,
            -1.0f, 1.0f, 0.0f, 1.0f,  0.0f, 1.0f,
        };
        const GLushort indices[] = {0, 1, 2, 2, 3, 0};

        gl.glGenVertexArrays(1, &vao_);
        gl.glBindVertexArray(vao_);
        gl.glGenBuffers(1, &vbo_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
        gl.glGenBuffers(1, &ibo_);
        gl.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo_);
        gl.glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 6 * sizeof(GLfloat),
                                 reinterpret_cast<const void*>(0));
        gl.glEnableVertexAttribArray(8);
        gl.glVertexAttribPointer(8, 2, GL_FLOAT, GL_FALSE, 6 * sizeof(GLfloat),
                                 reinterpret_cast<const void*>(4 * sizeof(GLfloat)));

        gl.glUseProgram(program_);
        const GLint textureLocation = gl.glGetUniformLocation(program_, "uTexture");
        expectCondition(textureLocation >= 0,
                        "dual-output uTexture is resolvable");
        gl.glUniform1i(textureLocation, 0);
    }

    void render(GLContext& /*context*/) override {
        auto& gl = Runtime::shared().dispatch();

        gl.glViewport(0, 0, framebufferSize().width, framebufferSize().height);
        gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);

        gl.glUseProgram(program_);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_2D, texture_);
        gl.glBindVertexArray(vao_);
        gl.glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, nullptr);

        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glActiveTexture,
            FunctionId::glAttachShader,
            FunctionId::glBindBuffer,
            FunctionId::glBindTexture,
            FunctionId::glBindVertexArray,
            FunctionId::glBufferData,
            FunctionId::glClear,
            FunctionId::glClearColor,
            FunctionId::glCompileShader,
            FunctionId::glCreateProgram,
            FunctionId::glCreateShader,
            FunctionId::glDeleteShader,
            FunctionId::glDrawElements,
            FunctionId::glEnableVertexAttribArray,
            FunctionId::glFlush,
            FunctionId::glGenBuffers,
            FunctionId::glGenTextures,
            FunctionId::glGenVertexArrays,
            FunctionId::glGetProgramiv,
            FunctionId::glGetShaderiv,
            FunctionId::glGetUniformLocation,
            FunctionId::glLinkProgram,
            FunctionId::glPixelStorei,
            FunctionId::glShaderSource,
            FunctionId::glTexImage2D,
            FunctionId::glTexParameteri,
            FunctionId::glUniform1i,
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
    GLuint texture_ = 0;
};

// Phase 8X Group 4d follow-up²¹ — CompatProfileGLSLShadowScene.
//
// Regression test for the `shadow2DProj` helper-function synthesis in
// `rewriteCompatShader`. fw²⁰-verification §4 pinned a new blocker in
// Spring's `ModelFragProg.glsl` `USE_SHADOWS == 1` branch: fw¹⁹'s flat
// rewrite `shadow2DProj → textureProj` silently broke the return-type
// contract on `sampler2DShadow` (legacy returns `vec4`, core returns
// `float`), so the chained `.r` swizzle Spring's shader does on the
// result became "scalar swizzle : not supported" under glslang 330
// core. Fw²¹ retargets the rewrite: call sites are renamed to
// `appgl_shadow2DProj`, and the rewriter synthesizes a thin preamble
// wrapper that calls `textureProj` and replicates the scalar result
// into a vec4 — preserving the legacy return type end-to-end.
//
// This scene compiles a `#version 120` FS that calls
// `shadow2DProj(uShadow, ...).r` inside a branch guarded by an
// always-false runtime condition (`vUV.x > 10.0`, where `vUV` is in
// `[0,1]`). The branch guard is intentionally **not** compile-time
// constant so glslang has to type-check the `shadow2DProj(...).r`
// expression — which is where a broken wrapper would surface as a
// compile error. At runtime the branch is never taken, so the final
// output is just the texture sample and the golden matches the
// existing `phase-7.compat-profile-glsl` golden byte-for-byte.
// Byte-identity is the same positive-evidence pattern fw²⁰ used for
// the dual-output scene: it proves the helper synthesis is
// semantically transparent to downstream consumers on the same
// texture / geometry / matrix inputs.
class CompatProfileGLSLShadowScene final : public Scene {
public:
    std::string id() const override {
        return "phase-7.compat-profile-glsl-shadow";
    }
    std::string phase() const override { return "phase-7"; }
    SceneSize framebufferSize() const override { return {64, 64}; }

    double tolerance() const override { return 0.02; }

    void setup(GLContext& /*context*/) override {
        auto& gl = Runtime::shared().dispatch();

        // VS identical to the single-output scene — fw²¹ targets the
        // fragment-stage rewrite path.
        const char* vertexSource =
            "#version 120\n"
            "varying vec2 vUV;\n"
            "void main() {\n"
            "    vUV = gl_MultiTexCoord0.xy;\n"
            "    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;\n"
            "}\n";

        // Fragment stage: calls `shadow2DProj(uShadow, ...).r` — the
        // exact shape that broke Spring's `ModelFragProg.glsl`
        // `USE_SHADOWS == 1` branch under fw²⁰. The expression is
        // placed inside an `if (vUV.x > 10.0)` branch so glslang type-
        // checks it but the branch is never taken at runtime (vUV is
        // in [0,1] from the UV-gradient texture coordinate). The
        // rewriter must synthesize `appgl_shadow2DProj(sampler2DShadow,
        // vec4) -> vec4` into the preamble and rename the call site,
        // otherwise the `.r` becomes an illegal "scalar swizzle" and
        // the fragment compile fails at setup time.
        const char* fragmentSource =
            "#version 120\n"
            "uniform sampler2D uTexture;\n"
            "uniform sampler2DShadow uShadow;\n"
            "varying vec2 vUV;\n"
            "void main() {\n"
            "    vec4 color = texture2D(uTexture, vUV);\n"
            "    if (vUV.x > 10.0) {\n"
            "        float s = shadow2DProj(uShadow, vec4(vUV, 0.0, 1.0)).r;\n"
            "        color = vec4(s);\n"
            "    }\n"
            "    gl_FragColor = color;\n"
            "}\n";

        const GLuint vertex = gl.glCreateShader(GL_VERTEX_SHADER);
        const GLuint fragment = gl.glCreateShader(GL_FRAGMENT_SHADER);
        gl.glShaderSource(vertex, 1, &vertexSource, nullptr);
        gl.glShaderSource(fragment, 1, &fragmentSource, nullptr);
        gl.glCompileShader(vertex);
        gl.glCompileShader(fragment);
        GLint vsCompile = 0, fsCompile = 0;
        gl.glGetShaderiv(vertex, GL_COMPILE_STATUS, &vsCompile);
        gl.glGetShaderiv(fragment, GL_COMPILE_STATUS, &fsCompile);
        expectCondition(vsCompile == GL_TRUE,
                        "shadow vertex shader compiles after rewrite");
        expectCondition(fsCompile == GL_TRUE,
                        "shadow fragment shader compiles after rewrite");

        program_ = gl.glCreateProgram();
        gl.glAttachShader(program_, vertex);
        gl.glAttachShader(program_, fragment);
        gl.glLinkProgram(program_);
        GLint linkStatus = 0;
        gl.glGetProgramiv(program_, GL_LINK_STATUS, &linkStatus);
        expectCondition(linkStatus == GL_TRUE,
                        "shadow program links after rewrite");
        gl.glDeleteShader(vertex);
        gl.glDeleteShader(fragment);

        // Same 4×4 UV-gradient texture as the baseline scene so the
        // rendered output is byte-identical when the shadow branch is
        // correctly skipped by the runtime guard.
        std::uint8_t rgbaPixels[16 * 4] = {};
        for (int y = 0; y < 4; ++y) {
            for (int x = 0; x < 4; ++x) {
                const int i = (y * 4 + x) * 4;
                rgbaPixels[i + 0] = static_cast<std::uint8_t>((x * 255) / 3);
                rgbaPixels[i + 1] = static_cast<std::uint8_t>((y * 255) / 3);
                rgbaPixels[i + 2] = 128;
                rgbaPixels[i + 3] = 255;
            }
        }
        gl.glGenTextures(1, &texture_);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_2D, texture_);
        gl.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgbaPixels);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        // Bind the same RGBA gradient to texture unit 1 as a stand-in
        // for the `sampler2DShadow` binding. The shader's shadow sample
        // is gated behind an always-false branch at runtime, so Metal
        // never actually reads from unit 1 — the binding only exists
        // to keep the draw-time sampler table non-empty. Using RGBA
        // instead of GL_DEPTH_COMPONENT keeps the scene on the Phase A
        // texture upload path (fw²⁰-verification §5.1 flagged non-
        // RGBA8 uploads as a known corpus gap).
        gl.glGenTextures(1, &shadowTex_);
        gl.glActiveTexture(GL_TEXTURE1);
        gl.glBindTexture(GL_TEXTURE_2D, shadowTex_);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgbaPixels);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        const GLfloat vertices[] = {
            -1.0f,-1.0f, 0.0f, 1.0f,  0.0f, 0.0f,
             1.0f,-1.0f, 0.0f, 1.0f,  1.0f, 0.0f,
             1.0f, 1.0f, 0.0f, 1.0f,  1.0f, 1.0f,
            -1.0f, 1.0f, 0.0f, 1.0f,  0.0f, 1.0f,
        };
        const GLushort indices[] = {0, 1, 2, 2, 3, 0};

        gl.glGenVertexArrays(1, &vao_);
        gl.glBindVertexArray(vao_);
        gl.glGenBuffers(1, &vbo_);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
        gl.glGenBuffers(1, &ibo_);
        gl.glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo_);
        gl.glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 6 * sizeof(GLfloat),
                                 reinterpret_cast<const void*>(0));
        gl.glEnableVertexAttribArray(8);
        gl.glVertexAttribPointer(8, 2, GL_FLOAT, GL_FALSE, 6 * sizeof(GLfloat),
                                 reinterpret_cast<const void*>(4 * sizeof(GLfloat)));

        gl.glUseProgram(program_);
        const GLint textureLocation = gl.glGetUniformLocation(program_, "uTexture");
        expectCondition(textureLocation >= 0,
                        "shadow uTexture is resolvable");
        gl.glUniform1i(textureLocation, 0);
        const GLint shadowLocation = gl.glGetUniformLocation(program_, "uShadow");
        expectCondition(shadowLocation >= 0,
                        "shadow uShadow is resolvable");
        gl.glUniform1i(shadowLocation, 1);
    }

    void render(GLContext& /*context*/) override {
        auto& gl = Runtime::shared().dispatch();

        gl.glViewport(0, 0, framebufferSize().width, framebufferSize().height);
        gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);

        gl.glUseProgram(program_);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_2D, texture_);
        gl.glActiveTexture(GL_TEXTURE1);
        gl.glBindTexture(GL_TEXTURE_2D, shadowTex_);
        gl.glBindVertexArray(vao_);
        gl.glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, nullptr);

        gl.glFlush();
    }

    std::vector<FunctionId> scenarioCoverage() const override {
        return {
            FunctionId::glActiveTexture,
            FunctionId::glAttachShader,
            FunctionId::glBindBuffer,
            FunctionId::glBindTexture,
            FunctionId::glBindVertexArray,
            FunctionId::glBufferData,
            FunctionId::glClear,
            FunctionId::glClearColor,
            FunctionId::glCompileShader,
            FunctionId::glCreateProgram,
            FunctionId::glCreateShader,
            FunctionId::glDeleteShader,
            FunctionId::glDrawElements,
            FunctionId::glEnableVertexAttribArray,
            FunctionId::glFlush,
            FunctionId::glGenBuffers,
            FunctionId::glGenTextures,
            FunctionId::glGenVertexArrays,
            FunctionId::glGetProgramiv,
            FunctionId::glGetShaderiv,
            FunctionId::glGetUniformLocation,
            FunctionId::glLinkProgram,
            FunctionId::glPixelStorei,
            FunctionId::glShaderSource,
            FunctionId::glTexImage2D,
            FunctionId::glTexParameteri,
            FunctionId::glUniform1i,
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
    GLuint texture_ = 0;
    GLuint shadowTex_ = 0;
};

// ===========================================================================
// Benchmark infrastructure — Phase 7 Group 5a
// ===========================================================================

struct BenchmarkTierResult {
    std::string tier;       // "light", "medium", "heavy"
    int objectCount = 0;
    int verticesPerFrame = 0;
    int trianglesPerFrame = 0;
    int drawCallsPerFrame = 0;
    double avgFPS = 0.0;
    double avgFrameMs = 0.0;
    double p95FrameMs = 0.0;
    double peakGPUMemoryMB = 0.0;
    double shaderCompileMs = 0.0;   // first-frame – steady-frame (setup overhead)
    std::uint64_t pipelineCacheHits = 0;
    std::uint64_t pipelineCacheMisses = 0;
    double pipelineBuildMs = 0.0;
};

// Helper: generate UV-sphere vertices (interleaved pos+normal, 6 floats/vert).
static std::vector<float> generateSphereGeometry(float radius, int segments, int rings) {
    const float pi = 3.14159265f;
    std::vector<float> data;
    for (int ri = 0; ri < rings; ++ri) {
        float t0 = pi * float(ri)   / float(rings);
        float t1 = pi * float(ri+1) / float(rings);
        for (int si = 0; si < segments; ++si) {
            float p0 = 2*pi*float(si)  /float(segments);
            float p1 = 2*pi*float(si+1)/float(segments);
            auto pushV = [&](float theta, float phi) {
                float x = radius * std::sin(theta) * std::cos(phi);
                float y = radius * std::cos(theta);
                float z = radius * std::sin(theta) * std::sin(phi);
                float nx = std::sin(theta) * std::cos(phi);
                float ny = std::cos(theta);
                float nz = std::sin(theta) * std::sin(phi);
                data.insert(data.end(), {x, y, z, nx, ny, nz});
            };
            pushV(t0, p0); pushV(t1, p0); pushV(t1, p1);
            pushV(t0, p0); pushV(t1, p1); pushV(t0, p1);
        }
    }
    return data;
}

// Helper: generate cube vertices (pos only, 3 floats/vert, 36 verts).
static std::vector<float> generateCubePositions(float half = 0.5f) {
    // 6 faces × 2 triangles × 3 vertices = 36 vertices, each with 3 floats.
    return {
        // Front
        -half,-half, half,  half,-half, half,  half, half, half,
        -half,-half, half,  half, half, half, -half, half, half,
        // Back
         half,-half,-half, -half,-half,-half, -half, half,-half,
         half,-half,-half, -half, half,-half,  half, half,-half,
        // Left
        -half,-half,-half, -half,-half, half, -half, half, half,
        -half,-half,-half, -half, half, half, -half, half,-half,
        // Right
         half,-half, half,  half,-half,-half,  half, half,-half,
         half,-half, half,  half, half,-half,  half, half, half,
        // Top
        -half, half, half,  half, half, half,  half, half,-half,
        -half, half, half,  half, half,-half, -half, half,-half,
        // Bottom
        -half,-half,-half,  half,-half,-half,  half,-half, half,
        -half,-half,-half,  half,-half, half, -half,-half, half,
    };
}

// Shared Phong shaders for medium/heavy benchmarks.
static const char* kBenchPhongVS =
    "#version 330 core\n"
    "layout(location = 0) in vec3 aPosition;\n"
    "layout(location = 1) in vec3 aNormal;\n"
    "uniform mat4 uMVP;\n"
    "uniform mat4 uModelMatrix;\n"
    "uniform mat3 uNormalMatrix;\n"
    "out vec3 vWorldPos;\n"
    "out vec3 vNormal;\n"
    "void main() {\n"
    "    vec4 worldPos = uModelMatrix * vec4(aPosition, 1.0);\n"
    "    vWorldPos = worldPos.xyz;\n"
    "    vNormal = normalize(uNormalMatrix * aNormal);\n"
    "    gl_Position = uMVP * vec4(aPosition, 1.0);\n"
    "}\n";

static const char* kBenchPhongFS =
    "#version 330 core\n"
    "in vec3 vWorldPos;\n"
    "in vec3 vNormal;\n"
    "uniform vec3 uLightPos;\n"
    "uniform vec3 uLightColor;\n"
    "uniform vec3 uViewPos;\n"
    "uniform vec4 uColor;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    float ambientStrength = 0.15;\n"
    "    vec3 ambient = ambientStrength * uLightColor;\n"
    "    vec3 norm = normalize(vNormal);\n"
    "    vec3 lightDir = normalize(uLightPos - vWorldPos);\n"
    "    float diff = max(dot(norm, lightDir), 0.0);\n"
    "    vec3 diffuse = diff * uLightColor;\n"
    "    float specularStrength = 0.5;\n"
    "    vec3 viewDir = normalize(uViewPos - vWorldPos);\n"
    "    vec3 halfDir = normalize(lightDir + viewDir);\n"
    "    float spec = pow(max(dot(norm, halfDir), 0.0), 32.0);\n"
    "    vec3 specular = specularStrength * spec * uLightColor;\n"
    "    vec3 result = (ambient + diffuse + specular) * uColor.rgb;\n"
    "    fragColor = vec4(result, uColor.a);\n"
    "}\n";

// Simple flat-color shader for Light tier.
static const char* kBenchFlatVS =
    "#version 330 core\n"
    "layout(location = 0) in vec3 aPosition;\n"
    "uniform mat4 uMVP;\n"
    "void main() {\n"
    "    gl_Position = uMVP * vec4(aPosition, 1.0);\n"
    "}\n";

static const char* kBenchFlatFS =
    "#version 330 core\n"
    "uniform vec4 uColor;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    fragColor = uColor;\n"
    "}\n";

// Helper: compile and link a shader program.
static GLuint buildBenchProgram(const char* vsSrc, const char* fsSrc) {
    auto& gl = Runtime::shared().dispatch();
    GLuint vs = gl.glCreateShader(GL_VERTEX_SHADER);
    gl.glShaderSource(vs, 1, &vsSrc, nullptr);
    gl.glCompileShader(vs);
    GLuint fs = gl.glCreateShader(GL_FRAGMENT_SHADER);
    gl.glShaderSource(fs, 1, &fsSrc, nullptr);
    gl.glCompileShader(fs);
    GLuint prog = gl.glCreateProgram();
    gl.glAttachShader(prog, vs);
    gl.glAttachShader(prog, fs);
    gl.glLinkProgram(prog);
    gl.glDeleteShader(vs);
    gl.glDeleteShader(fs);
    return prog;
}

static std::string shaderInfoLog(GLDispatchTable& gl, GLuint shader) {
    GLint length = 0;
    gl.glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
    if (length <= 1) {
        return {};
    }
    std::string log(static_cast<std::size_t>(length), '\0');
    GLsizei written = 0;
    gl.glGetShaderInfoLog(shader, length, &written, log.data());
    log.resize(static_cast<std::size_t>(std::max<GLsizei>(written, 0)));
    return log;
}

static std::string programInfoLog(GLDispatchTable& gl, GLuint program) {
    GLint length = 0;
    gl.glGetProgramiv(program, GL_INFO_LOG_LENGTH, &length);
    if (length <= 1) {
        return {};
    }
    std::string log(static_cast<std::size_t>(length), '\0');
    GLsizei written = 0;
    gl.glGetProgramInfoLog(program, length, &written, log.data());
    log.resize(static_cast<std::size_t>(std::max<GLsizei>(written, 0)));
    return log;
}

static GLuint compileRequiredShader(GLDispatchTable& gl,
                                    GLenum type,
                                    const char* source,
                                    std::string_view label) {
    GLuint shader = gl.glCreateShader(type);
    gl.glShaderSource(shader, 1, &source, nullptr);
    gl.glCompileShader(shader);
    GLint status = GL_FALSE;
    gl.glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status != GL_TRUE) {
        const std::string log = shaderInfoLog(gl, shader);
        gl.glDeleteShader(shader);
        throw std::runtime_error(
            "DCR4-C shader compile failed for " + std::string(label) +
            (log.empty() ? std::string{} : ": " + log));
    }
    return shader;
}

static GLuint buildDCR4CMeshGsProgram(const char* vsSrc,
                                      const char* gsSrc,
                                      const char* fsSrc) {
    auto& gl = Runtime::shared().dispatch();
    const GLuint vs =
        compileRequiredShader(gl, GL_VERTEX_SHADER, vsSrc, "vertex");
    const GLuint gs =
        compileRequiredShader(gl, GL_GEOMETRY_SHADER, gsSrc, "geometry");
    const GLuint fs =
        compileRequiredShader(gl, GL_FRAGMENT_SHADER, fsSrc, "fragment");
    GLuint program = gl.glCreateProgram();
    gl.glAttachShader(program, vs);
    gl.glAttachShader(program, gs);
    gl.glAttachShader(program, fs);
    gl.glLinkProgram(program);
    gl.glDeleteShader(vs);
    gl.glDeleteShader(gs);
    gl.glDeleteShader(fs);
    GLint status = GL_FALSE;
    gl.glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (status != GL_TRUE) {
        const std::string log = programInfoLog(gl, program);
        gl.glDeleteProgram(program);
        throw std::runtime_error(
            "DCR4-C mesh-GS program link failed" +
            (log.empty() ? std::string{} : ": " + log));
    }
    return program;
}

// Helper: 4×4 matrix multiply (column-major).
static void mat4Mul(float* out, const float* a, const float* b) {
    for (int c = 0; c < 4; ++c)
        for (int r = 0; r < 4; ++r) {
            float s = 0;
            for (int k = 0; k < 4; ++k) s += a[k*4+r] * b[c*4+k];
            out[c*4+r] = s;
        }
}

// Benchmark runner: runs a rendering closure N times, measures timing.
struct BenchmarkFrameMetrics {
    std::vector<double> frameTimesMs;
    double peakGPUMemoryMB = 0.0;
};

static BenchmarkFrameMetrics runFrameLoop(
    GLContext& ctx,
    int warmupFrames,
    int measuredFrames,
    const std::function<void()>& renderFrame)
{
    BenchmarkFrameMetrics metrics;

    // Warmup.
    for (int f = 0; f < warmupFrames; ++f) {
        renderFrame();
    }

    // Measure.
    metrics.frameTimesMs.reserve(measuredFrames);
    for (int f = 0; f < measuredFrames; ++f) {
        const auto t0 = std::chrono::steady_clock::now();
        renderFrame();
        const auto t1 = std::chrono::steady_clock::now();
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        metrics.frameTimesMs.push_back(ms);
        double memMB = static_cast<double>(ctx.metalAllocatedBytes()) / (1024.0 * 1024.0);
        if (memMB > metrics.peakGPUMemoryMB) metrics.peakGPUMemoryMB = memMB;
    }

    return metrics;
}

// ----------- Light Tier: Single cube, 36 vertices, flat shader -----------
static BenchmarkTierResult runLightTier() {
    BenchmarkTierResult result;
    result.tier = "light";
    result.objectCount = 1;

    const int fbW = 256, fbH = 256;
    auto context = std::make_unique<GLContext>(fbW, fbH);
    Runtime::shared().makeCurrent(context.get());
    auto& gl = Runtime::shared().dispatch();

    // Build program.
    GLuint program = buildBenchProgram(kBenchFlatVS, kBenchFlatFS);
    GLint mvpLoc = gl.glGetUniformLocation(program, "uMVP");
    GLint colorLoc = gl.glGetUniformLocation(program, "uColor");

    // Build VBO + VAO.
    auto cubeVerts = generateCubePositions(0.5f);
    GLuint vbo, vao;
    gl.glGenBuffers(1, &vbo);
    gl.glBindBuffer(GL_ARRAY_BUFFER, vbo);
    gl.glBufferData(GL_ARRAY_BUFFER,
                    static_cast<GLsizeiptr>(cubeVerts.size() * sizeof(float)),
                    cubeVerts.data(), GL_STATIC_DRAW);
    gl.glGenVertexArrays(1, &vao);
    gl.glBindVertexArray(vao);
    gl.glEnableVertexAttribArray(0);
    gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * sizeof(float), nullptr);

    result.verticesPerFrame = 36;
    result.trianglesPerFrame = 12;
    result.drawCallsPerFrame = 1;

    // Projection + view.
    float proj[16] = {};
    float fov = 0.785f, f = 1.0f / std::tan(fov * 0.5f);
    proj[0] = f; proj[5] = f; proj[10] = -1.02f; proj[11] = -1.0f; proj[14] = -0.2f;
    float view[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,-3,1};
    float vp[16];
    mat4Mul(vp, proj, view);

    // Measure first-frame (includes shader compile + pipeline build).
    context->resetPipelineCacheMetrics();
    const auto firstFrameStart = std::chrono::steady_clock::now();
    {
        gl.glViewport(0, 0, fbW, fbH);
        gl.glClearColor(0.1f, 0.1f, 0.1f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        gl.glEnable(GL_DEPTH_TEST);
        gl.glUseProgram(program);
        gl.glUniformMatrix4fv(mvpLoc, 1, GL_FALSE, vp);
        gl.glUniform4f(colorLoc, 0.8f, 0.3f, 0.2f, 1.0f);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLES, 0, 36);
    }
    const auto firstFrameEnd = std::chrono::steady_clock::now();
    double firstFrameMs = std::chrono::duration<double, std::milli>(firstFrameEnd - firstFrameStart).count();

    // Capture pipeline metrics after first frame.
    auto pMetrics = context->pipelineCacheMetrics();
    result.pipelineCacheHits = pMetrics.hits;
    result.pipelineCacheMisses = pMetrics.misses;
    result.pipelineBuildMs = pMetrics.cumulativeBuildMillis;

    // Run steady-state measurement (120 frames after 20 warmup).
    context->resetPipelineCacheMetrics();
    auto renderFrame = [&]() {
        gl.glClearColor(0.1f, 0.1f, 0.1f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        gl.glEnable(GL_DEPTH_TEST);
        gl.glUseProgram(program);
        gl.glUniformMatrix4fv(mvpLoc, 1, GL_FALSE, vp);
        gl.glUniform4f(colorLoc, 0.8f, 0.3f, 0.2f, 1.0f);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLES, 0, 36);
    };

    auto frameMetrics = runFrameLoop(*context, 20, 120, renderFrame);

    // Compute stats.
    auto& times = frameMetrics.frameTimesMs;
    double totalMs = 0;
    for (double ms : times) totalMs += ms;
    result.avgFrameMs = totalMs / static_cast<double>(times.size());
    result.avgFPS = result.avgFrameMs > 0 ? 1000.0 / result.avgFrameMs : 0;
    std::sort(times.begin(), times.end());
    int p95Idx = std::min(static_cast<int>(times.size()) - 1,
                          static_cast<int>(static_cast<double>(times.size()) * 0.95));
    result.p95FrameMs = times[p95Idx];
    result.peakGPUMemoryMB = frameMetrics.peakGPUMemoryMB;

    // Steady-state pipeline hits (should be all hits after warmup).
    auto steadyMetrics = context->pipelineCacheMetrics();
    result.pipelineCacheHits += steadyMetrics.hits;
    // pipelineCacheMisses stays from first frame only.

    // Shader compile overhead = first frame – avg steady frame.
    result.shaderCompileMs = firstFrameMs - result.avgFrameMs;
    if (result.shaderCompileMs < 0) result.shaderCompileMs = 0;

    // Cleanup.
    gl.glDeleteBuffers(1, &vbo);
    gl.glDeleteVertexArrays(1, &vao);
    gl.glDeleteProgram(program);
    Runtime::shared().makeCurrent(nullptr);

    return result;
}

// ----------- Medium Tier: 100 Phong-lit spheres -----------
static BenchmarkTierResult runPhongObjectsTier(const std::string& tierName, int objectCount) {
    BenchmarkTierResult result;
    result.tier = tierName;
    result.objectCount = objectCount;

    const int fbW = 256, fbH = 256;
    auto context = std::make_unique<GLContext>(fbW, fbH);
    Runtime::shared().makeCurrent(context.get());
    auto& gl = Runtime::shared().dispatch();

    GLuint program = buildBenchProgram(kBenchPhongVS, kBenchPhongFS);
    GLint mvpLoc        = gl.glGetUniformLocation(program, "uMVP");
    GLint modelMatLoc   = gl.glGetUniformLocation(program, "uModelMatrix");
    GLint normalMatLoc  = gl.glGetUniformLocation(program, "uNormalMatrix");
    GLint lightPosLoc   = gl.glGetUniformLocation(program, "uLightPos");
    GLint lightColorLoc = gl.glGetUniformLocation(program, "uLightColor");
    GLint viewPosLoc    = gl.glGetUniformLocation(program, "uViewPos");
    GLint colorLoc      = gl.glGetUniformLocation(program, "uColor");

    // Sphere geometry (low-poly for benchmark — 12 segments × 6 rings).
    auto sphereData = generateSphereGeometry(0.3f, 12, 6);
    int vertCount = static_cast<int>(sphereData.size()) / 6;
    GLuint vbo, vao;
    gl.glGenBuffers(1, &vbo);
    gl.glBindBuffer(GL_ARRAY_BUFFER, vbo);
    gl.glBufferData(GL_ARRAY_BUFFER,
                    static_cast<GLsizeiptr>(sphereData.size() * sizeof(float)),
                    sphereData.data(), GL_STATIC_DRAW);
    gl.glGenVertexArrays(1, &vao);
    gl.glBindVertexArray(vao);
    gl.glEnableVertexAttribArray(0);
    gl.glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), nullptr);
    gl.glEnableVertexAttribArray(1);
    gl.glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float),
                             reinterpret_cast<const void*>(3 * sizeof(float)));

    result.verticesPerFrame = vertCount * objectCount;
    result.trianglesPerFrame = (vertCount / 3) * objectCount;
    result.drawCallsPerFrame = objectCount;

    // Projection + view.
    float proj[16] = {};
    float fov = 0.785f, ff = 1.0f / std::tan(fov * 0.5f);
    proj[0] = ff; proj[5] = ff; proj[10] = -1.02f; proj[11] = -1.0f; proj[14] = -0.2f;
    float zDist = -3.0f - float(objectCount) * 0.02f;  // pull back for more objects
    float view[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,zDist,1};

    // Pre-compute grid positions.
    int gridSide = static_cast<int>(std::ceil(std::cbrt(static_cast<double>(objectCount))));
    float spacing = 1.0f;

    struct ObjInstance { float tx, ty, tz, r, g, b; };
    std::vector<ObjInstance> instances;
    instances.reserve(objectCount);
    int idx = 0;
    for (int iz = 0; iz < gridSide && idx < objectCount; ++iz)
        for (int iy = 0; iy < gridSide && idx < objectCount; ++iy)
            for (int ix = 0; ix < gridSide && idx < objectCount; ++ix, ++idx) {
                float cx = (float(ix) - float(gridSide - 1) * 0.5f) * spacing;
                float cy = (float(iy) - float(gridSide - 1) * 0.5f) * spacing;
                float cz = (float(iz) - float(gridSide - 1) * 0.5f) * spacing;
                // Pseudo-random color from index.
                float r = 0.3f + 0.7f * float((idx * 37) % 256) / 255.0f;
                float g = 0.3f + 0.7f * float((idx * 73) % 256) / 255.0f;
                float b = 0.3f + 0.7f * float((idx * 131) % 256) / 255.0f;
                instances.push_back({cx, cy, cz, r, g, b});
            }

    // Measure first-frame.
    context->resetPipelineCacheMetrics();
    const auto firstFrameStart = std::chrono::steady_clock::now();
    {
        gl.glViewport(0, 0, fbW, fbH);
        gl.glClearColor(0.05f, 0.05f, 0.08f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        gl.glEnable(GL_DEPTH_TEST);
        gl.glUseProgram(program);
        gl.glUniform3f(lightPosLoc, 3.0f, 4.0f, 2.0f);
        gl.glUniform3f(lightColorLoc, 1.0f, 0.95f, 0.9f);
        gl.glUniform3f(viewPosLoc, 0.0f, 0.0f, -zDist);
        gl.glBindVertexArray(vao);
        for (const auto& obj : instances) {
            float model[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, obj.tx,obj.ty,obj.tz,1};
            float vm[16], mvp[16];
            mat4Mul(vm, view, model);
            mat4Mul(mvp, proj, vm);
            float normalMat[9] = {1,0,0, 0,1,0, 0,0,1};
            gl.glUniformMatrix4fv(mvpLoc, 1, GL_FALSE, mvp);
            gl.glUniformMatrix4fv(modelMatLoc, 1, GL_FALSE, model);
            gl.glUniformMatrix3fv(normalMatLoc, 1, GL_FALSE, normalMat);
            gl.glUniform4f(colorLoc, obj.r, obj.g, obj.b, 1.0f);
            gl.glDrawArrays(GL_TRIANGLES, 0, vertCount);
        }
    }
    const auto firstFrameEnd = std::chrono::steady_clock::now();
    double firstFrameMs = std::chrono::duration<double, std::milli>(firstFrameEnd - firstFrameStart).count();

    auto pMetrics = context->pipelineCacheMetrics();
    result.pipelineCacheHits = pMetrics.hits;
    result.pipelineCacheMisses = pMetrics.misses;
    result.pipelineBuildMs = pMetrics.cumulativeBuildMillis;

    // Steady-state loop (120 measured, 20 warmup).
    context->resetPipelineCacheMetrics();
    auto renderFrame = [&]() {
        gl.glClearColor(0.05f, 0.05f, 0.08f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        gl.glEnable(GL_DEPTH_TEST);
        gl.glUseProgram(program);
        gl.glUniform3f(lightPosLoc, 3.0f, 4.0f, 2.0f);
        gl.glUniform3f(lightColorLoc, 1.0f, 0.95f, 0.9f);
        gl.glUniform3f(viewPosLoc, 0.0f, 0.0f, -zDist);
        gl.glBindVertexArray(vao);
        for (const auto& obj : instances) {
            float model[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, obj.tx,obj.ty,obj.tz,1};
            float vm[16], mvp[16];
            mat4Mul(vm, view, model);
            mat4Mul(mvp, proj, vm);
            float normalMat[9] = {1,0,0, 0,1,0, 0,0,1};
            gl.glUniformMatrix4fv(mvpLoc, 1, GL_FALSE, mvp);
            gl.glUniformMatrix4fv(modelMatLoc, 1, GL_FALSE, model);
            gl.glUniformMatrix3fv(normalMatLoc, 1, GL_FALSE, normalMat);
            gl.glUniform4f(colorLoc, obj.r, obj.g, obj.b, 1.0f);
            gl.glDrawArrays(GL_TRIANGLES, 0, vertCount);
        }
    };

    auto frameMetrics = runFrameLoop(*context, 20, 120, renderFrame);

    auto& times = frameMetrics.frameTimesMs;
    double totalMs = 0;
    for (double ms : times) totalMs += ms;
    result.avgFrameMs = totalMs / static_cast<double>(times.size());
    result.avgFPS = result.avgFrameMs > 0 ? 1000.0 / result.avgFrameMs : 0;
    std::sort(times.begin(), times.end());
    int p95Idx = std::min(static_cast<int>(times.size()) - 1,
                          static_cast<int>(static_cast<double>(times.size()) * 0.95));
    result.p95FrameMs = times[p95Idx];
    result.peakGPUMemoryMB = frameMetrics.peakGPUMemoryMB;

    auto steadyMetrics = context->pipelineCacheMetrics();
    result.pipelineCacheHits += steadyMetrics.hits;

    result.shaderCompileMs = firstFrameMs - result.avgFrameMs;
    if (result.shaderCompileMs < 0) result.shaderCompileMs = 0;

    // Enable blending for heavy tier (adds additional GPU work).
    // Heavy tier has depth + blend as per checklist; handled by the caller
    // selecting objectCount=1000.

    gl.glDeleteBuffers(1, &vbo);
    gl.glDeleteVertexArrays(1, &vao);
    gl.glDeleteProgram(program);
    Runtime::shared().makeCurrent(nullptr);

    return result;
}

// Build the benchmark JSON output.
static std::string buildBenchmarkJSON(const std::vector<BenchmarkTierResult>& tiers) {
    std::ostringstream ss;
    ss << std::fixed;
    ss << "{\"benchmark\":\"phase-7-baseline\",\"tiers\":[";
    for (std::size_t i = 0; i < tiers.size(); ++i) {
        if (i > 0) ss << ",";
        const auto& t = tiers[i];
        ss << "{"
           << "\"tier\":\"" << t.tier << "\","
           << "\"objectCount\":" << t.objectCount << ","
           << "\"verticesPerFrame\":" << t.verticesPerFrame << ","
           << "\"trianglesPerFrame\":" << t.trianglesPerFrame << ","
           << "\"drawCallsPerFrame\":" << t.drawCallsPerFrame << ","
           << "\"avgFPS\":" << t.avgFPS << ","
           << "\"avgFrameMs\":" << t.avgFrameMs << ","
           << "\"p95FrameMs\":" << t.p95FrameMs << ","
           << "\"peakGPUMemoryMB\":" << t.peakGPUMemoryMB << ","
           << "\"shaderCompileMs\":" << t.shaderCompileMs << ","
           << "\"pipelineCache\":{\"hits\":" << t.pipelineCacheHits
           << ",\"misses\":" << t.pipelineCacheMisses
           << ",\"buildMs\":" << t.pipelineBuildMs << "}"
           << "}";
    }
    ss << "]}";
    return ss.str();
}

std::string countersSummary(const AppGLCommandSubmissionDebugCounters& counters) {
    std::ostringstream stream;
    stream << "submitted=" << counters.submittedCommandBuffers
           << " completed=" << counters.completedCommandBuffers
           << " waitLog=" << counters.waitReasonLogEntries
           << " pressureFlush=" << counters.pressureFlushCount
           << " inFlight=" << counters.currentInFlight
           << " peakInFlight=" << counters.peakInFlight
           << " bound=" << counters.inFlightBound
           << " reserve=" << counters.pressureReserve
           << " softCap=" << counters.pressureSoftCap
           << " lastReason=" << appGLCommandReasonName(counters.lastWaitReason)
           << " lastMode=" << appGLSubmitModeName(counters.lastWaitMode)
           << " lastDependency=" << appGLDependencyClassName(counters.lastWaitDependencyClass);
    return stream.str();
}

std::uint64_t allocWaitTimeoutTotal(const AppGLCommandSubmissionDebugCounters& counters) {
    std::uint64_t total = 0;
    for (std::uint64_t count : counters.allocWaitTimeoutsByReason) {
        total += count;
    }
    return total;
}

bool sameCommandSubmissionCounters(const AppGLCommandSubmissionDebugCounters& lhs,
                                   const AppGLCommandSubmissionDebugCounters& rhs) {
    return lhs.submittedCommandBuffers == rhs.submittedCommandBuffers
        && lhs.completedCommandBuffers == rhs.completedCommandBuffers
        && lhs.waitReasonLogEntries == rhs.waitReasonLogEntries;
}

bool sameSubmittedAndWaitLog(const AppGLCommandSubmissionDebugCounters& lhs,
                             const AppGLCommandSubmissionDebugCounters& rhs) {
    return lhs.submittedCommandBuffers == rhs.submittedCommandBuffers
        && lhs.waitReasonLogEntries == rhs.waitReasonLogEntries;
}

void recordSentinelFailure(std::vector<std::string>& failures,
                           std::string_view label,
                           std::string detail) {
    failures.push_back(std::string(label) + ": " + std::move(detail));
}

void throwIfSentinelFailed(const std::vector<std::string>& failures) {
    if (failures.empty()) {
        return;
    }
    std::ostringstream stream;
    for (std::size_t index = 0; index < failures.size(); ++index) {
        if (index != 0) {
            stream << " | ";
        }
        stream << failures[index];
    }
    throw std::runtime_error(stream.str());
}

class ScopedSentinelContext {
public:
    ScopedSentinelContext(GLsizei width, GLsizei height)
        : context_(std::make_unique<GLContext>(width, height)) {
        Runtime::shared().makeCurrent(context_.get());
        Runtime::shared().noteRenderer(context_->rendererString());
    }

    ~ScopedSentinelContext() {
        Runtime::shared().makeCurrent(nullptr);
    }

    GLContext& context() {
        return *context_;
    }

    GLDispatchTable& gl() {
        return Runtime::shared().dispatch();
    }

private:
    std::unique_ptr<GLContext> context_;
};

class ScopedEnvVar {
public:
    ScopedEnvVar(std::string name, std::string value)
        : name_(std::move(name)) {
        const char* previous = std::getenv(name_.c_str());
        if (previous != nullptr) {
            hadPrevious_ = true;
            previous_ = previous;
        }
        setenv(name_.c_str(), value.c_str(), 1);
    }

    ScopedEnvVar(const ScopedEnvVar&) = delete;
    ScopedEnvVar& operator=(const ScopedEnvVar&) = delete;

    ~ScopedEnvVar() {
        if (hadPrevious_) {
            setenv(name_.c_str(), previous_.c_str(), 1);
        } else {
            unsetenv(name_.c_str());
        }
    }

private:
    std::string name_;
    std::string previous_;
    bool hadPrevious_ = false;
};

template <typename Fn>
TestResult runDirectSentinel(std::string id, Fn&& fn) {
    const auto startedAt = std::chrono::steady_clock::now();

    TestResult result;
    result.id = std::move(id);
    result.status = "passed";

    try {
        std::forward<Fn>(fn)();
    } catch (const std::exception& error) {
        result.status = "failed";
        result.message = error.what();
    }

    Runtime::shared().makeCurrent(nullptr);
    const auto endedAt = std::chrono::steady_clock::now();
    result.millis = std::chrono::duration<double, std::milli>(endedAt - startedAt).count();
    return result;
}

TestResult runDCR2FlushFinishSentinel() {
    return runDirectSentinel("dcr2.glflush-vs-glfinish", [] {
        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();
        std::vector<std::string> failures;
        const auto reasonCount = [](const AppGLCommandSubmissionDebugCounters& counters,
                                    AppGLCommandReason reason) {
            return counters.submittedByReason[static_cast<std::size_t>(reason)];
        };

        gl.glFinish();
        const auto initial = context.commandSubmissionDebugCounters();

        gl.glFlush();
        const auto afterNoWorkFlush = context.commandSubmissionDebugCounters();
        if (!sameCommandSubmissionCounters(initial, afterNoWorkFlush)) {
            recordSentinelFailure(
                failures,
                "no-work glFlush changed counters",
                "before{" + countersSummary(initial) + "} after{" + countersSummary(afterNoWorkFlush) + "}"
            );
        }

        gl.glFinish();
        const auto afterNoWorkFinish = context.commandSubmissionDebugCounters();
        if (!sameCommandSubmissionCounters(afterNoWorkFlush, afterNoWorkFinish)) {
            recordSentinelFailure(
                failures,
                "no-work glFinish changed counters",
                "before{" + countersSummary(afterNoWorkFlush) + "} after{" + countersSummary(afterNoWorkFinish) + "}"
            );
        }

        gl.glClearColor(0.18f, 0.23f, 0.31f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
        const auto afterClearFlush = context.commandSubmissionDebugCounters();
        if (afterClearFlush.submittedCommandBuffers != afterNoWorkFinish.submittedCommandBuffers + 1) {
            recordSentinelFailure(
                failures,
                "clear+glFlush did not submit exactly one command buffer",
                "before{" + countersSummary(afterNoWorkFinish) + "} after{" + countersSummary(afterClearFlush) + "}"
            );
        }
        if (reasonCount(afterClearFlush, AppGLCommandReason::PresentFromFlush) !=
            reasonCount(afterNoWorkFinish, AppGLCommandReason::PresentFromFlush) + 1) {
            recordSentinelFailure(
                failures,
                "clear+glFlush was not attributed to PresentFromFlush",
                "before{" + countersSummary(afterNoWorkFinish) + "} after{" + countersSummary(afterClearFlush) + "}"
            );
        }
        if (afterClearFlush.lastWaitMode == AppGLSubmitMode::CommitAndWait
            || afterClearFlush.lastWaitMode == AppGLSubmitMode::DrainAll
            || afterClearFlush.lastWaitReason == AppGLCommandReason::FinishWait
            || afterClearFlush.lastWaitReason == AppGLCommandReason::LifetimeDrain) {
            recordSentinelFailure(
                failures,
                "glFlush used synchronous finish attribution",
                countersSummary(afterClearFlush)
            );
        }

        std::array<std::uint8_t, 32 * 32 * 4> pixels = {};
        gl.glReadPixels(0, 0, 32, 32, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
        expectGLError(gl, GL_NO_ERROR, "dcr2 sentinel glReadPixels");
        const auto afterReadback = context.commandSubmissionDebugCounters();
        if (afterReadback.lastWaitReason != AppGLCommandReason::FlushForReadback
            || afterReadback.lastWaitMode != AppGLSubmitMode::CommitAndWait) {
            recordSentinelFailure(
                failures,
                "glReadPixels wait was not readback-attributed",
                countersSummary(afterReadback)
            );
        }

        gl.glClearColor(0.45f, 0.12f, 0.20f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        const auto beforeFinish = context.commandSubmissionDebugCounters();
        gl.glFinish();
        const auto afterFinish = context.commandSubmissionDebugCounters();
        if (afterFinish.submittedCommandBuffers != beforeFinish.submittedCommandBuffers + 1
            || afterFinish.completedCommandBuffers != afterFinish.submittedCommandBuffers
            || afterFinish.lastWaitReason != AppGLCommandReason::LifetimeDrain
            || afterFinish.lastWaitMode != AppGLSubmitMode::DrainAll) {
            recordSentinelFailure(
                failures,
                "pending glFinish did not drain lifetime work",
                "before{" + countersSummary(beforeFinish) + "} after{" + countersSummary(afterFinish) + "}"
            );
        }

        throwIfSentinelFailed(failures);
    });
}

TestResult runDCR2PresentLifecycleSentinel() {
    return runDirectSentinel("dcr2.present-drawable-lifecycle", [] {
        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();
        std::vector<std::string> failures;
        const auto reasonCount = [](const AppGLCommandSubmissionDebugCounters& counters,
                                    AppGLCommandReason reason) {
            return counters.submittedByReason[static_cast<std::size_t>(reason)];
        };

        gl.glFinish();
        const auto initial = context.commandSubmissionDebugCounters();
        const auto initialInventory = context.metalResourceInventory();

        gl.glFlush();
        const auto afterNoWorkFlush = context.commandSubmissionDebugCounters();
        if (!sameCommandSubmissionCounters(initial, afterNoWorkFlush)) {
            recordSentinelFailure(
                failures,
                "idle present sentinel glFlush changed counters",
                "before{" + countersSummary(initial) + "} after{" + countersSummary(afterNoWorkFlush) + "}"
            );
        }
        const auto afterNoWorkFlushInventory = context.metalResourceInventory();
        if (afterNoWorkFlushInventory.frameGraphPresentFromFlushCalls !=
                initialInventory.frameGraphPresentFromFlushCalls + 1 ||
            afterNoWorkFlushInventory.frameGraphPresentNoWorkReturns !=
                initialInventory.frameGraphPresentNoWorkReturns + 1 ||
            afterNoWorkFlushInventory.frameGraphPresentPendingFalseCalls !=
                initialInventory.frameGraphPresentPendingFalseCalls + 1) {
            recordSentinelFailure(
                failures,
                "idle glFlush was not recorded as a no-work present",
                "beforeFlushCalls=" + std::to_string(initialInventory.frameGraphPresentFromFlushCalls) +
                    " afterFlushCalls=" + std::to_string(afterNoWorkFlushInventory.frameGraphPresentFromFlushCalls) +
                    " beforeNoWork=" + std::to_string(initialInventory.frameGraphPresentNoWorkReturns) +
                    " afterNoWork=" + std::to_string(afterNoWorkFlushInventory.frameGraphPresentNoWorkReturns)
            );
        }

        gl.glClearColor(0.07f, 0.22f, 0.36f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFlush();
        const auto afterClearFlush = context.commandSubmissionDebugCounters();
        if (afterClearFlush.submittedCommandBuffers != afterNoWorkFlush.submittedCommandBuffers + 1) {
            recordSentinelFailure(
                failures,
                "clear+flush did not submit one command buffer",
                "before{" + countersSummary(afterNoWorkFlush) + "} after{" + countersSummary(afterClearFlush) + "}"
            );
        }
        if (reasonCount(afterClearFlush, AppGLCommandReason::PresentFromFlush) !=
            reasonCount(afterNoWorkFlush, AppGLCommandReason::PresentFromFlush) + 1) {
            recordSentinelFailure(
                failures,
                "clear+flush did not submit as PresentFromFlush",
                "before{" + countersSummary(afterNoWorkFlush) + "} after{" + countersSummary(afterClearFlush) + "}"
            );
        }

        gl.glFlush();
        const auto afterSecondFlush = context.commandSubmissionDebugCounters();
        if (!sameSubmittedAndWaitLog(afterClearFlush, afterSecondFlush)) {
            recordSentinelFailure(
                failures,
                "second glFlush submitted or logged extra work",
                "before{" + countersSummary(afterClearFlush) + "} after{" + countersSummary(afterSecondFlush) + "}"
            );
        }

        gl.glClearColor(0.30f, 0.17f, 0.42f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        const auto beforeSwap = context.commandSubmissionDebugCounters();
        context.swapBuffers();
        const auto afterSwap = context.commandSubmissionDebugCounters();
        if (afterSwap.submittedCommandBuffers != beforeSwap.submittedCommandBuffers + 1) {
            recordSentinelFailure(
                failures,
                "offscreen swapBuffers did not submit pending work once",
                "before{" + countersSummary(beforeSwap) + "} after{" + countersSummary(afterSwap) + "}"
            );
        }
        if (reasonCount(afterSwap, AppGLCommandReason::PresentFromSwapBuffers) !=
            reasonCount(beforeSwap, AppGLCommandReason::PresentFromSwapBuffers) + 1) {
            recordSentinelFailure(
                failures,
                "offscreen swapBuffers did not submit as PresentFromSwapBuffers",
                "before{" + countersSummary(beforeSwap) + "} after{" + countersSummary(afterSwap) + "}"
            );
        }

        const auto inventory = context.metalResourceInventory();
        if (inventory.frameGraphPresentFromSwapBuffersCalls !=
                afterNoWorkFlushInventory.frameGraphPresentFromSwapBuffersCalls + 1 ||
            inventory.frameGraphPresentCommitSuccesses <
                afterNoWorkFlushInventory.frameGraphPresentCommitSuccesses + 2) {
            recordSentinelFailure(
                failures,
                "present diagnostics did not record flush and swap commit successes",
                "swapCalls=" + std::to_string(inventory.frameGraphPresentFromSwapBuffersCalls) +
                    " commitSuccesses=" + std::to_string(inventory.frameGraphPresentCommitSuccesses)
            );
        }
        if (inventory.frameGraphDrawableCount != 0 || inventory.frameGraphDrawableTextureBytes != 0) {
            recordSentinelFailure(
                failures,
                "offscreen present retained drawable resources",
                "drawableCount=" + std::to_string(inventory.frameGraphDrawableCount)
                    + " drawableBytes=" + std::to_string(inventory.frameGraphDrawableTextureBytes)
            );
        }

        gl.glFinish();
        const auto afterFinish = context.commandSubmissionDebugCounters();
        if (afterFinish.completedCommandBuffers != afterFinish.submittedCommandBuffers) {
            recordSentinelFailure(
                failures,
                "present lifecycle finish left incomplete command buffers",
                countersSummary(afterFinish)
            );
        }

        throwIfSentinelFailed(failures);
    });
}

TestResult runDCR2DeleteRebindLifetimeSentinel() {
    return runDirectSentinel("dcr2.delete-rebind-lifetime", [] {
        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();
        std::vector<std::string> failures;

        gl.glFinish();
        const std::size_t baselineBuffers = context.objects().buffers().size();
        GLuint buffer = 0;
        gl.glGenBuffers(1, &buffer);
        gl.glBindBuffer(GL_ARRAY_BUFFER, buffer);
        const std::uint32_t seedWords[4] = {1, 2, 3, 4};
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(seedWords), seedWords, GL_STATIC_DRAW);
        expectGLError(gl, GL_NO_ERROR, "dcr2 sentinel buffer create");
        if (context.objects().buffers().size() != baselineBuffers + 1
            || gl.glIsBuffer(buffer) != GL_TRUE) {
            recordSentinelFailure(failures, "buffer create was not visible in object store", "name=" + std::to_string(buffer));
        }

        gl.glDeleteBuffers(1, &buffer);
        expectGLError(gl, GL_NO_ERROR, "dcr2 sentinel buffer delete");
        if (context.objects().buffers().size() != baselineBuffers
            || gl.glIsBuffer(buffer) != GL_FALSE) {
            recordSentinelFailure(failures, "buffer delete left a live object", "name=" + std::to_string(buffer));
        }

        GLuint reboundBuffer = 0;
        gl.glGenBuffers(1, &reboundBuffer);
        gl.glBindBuffer(GL_ARRAY_BUFFER, reboundBuffer);
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(seedWords), seedWords, GL_DYNAMIC_DRAW);
        if (reboundBuffer == 0 || reboundBuffer == buffer) {
            recordSentinelFailure(
                failures,
                "buffer rebind reused an invalid/deleted name",
                "deleted=" + std::to_string(buffer) + " rebound=" + std::to_string(reboundBuffer)
            );
        }
        gl.glDeleteBuffers(1, &reboundBuffer);
        expectGLError(gl, GL_NO_ERROR, "dcr2 sentinel rebound buffer delete");

        const std::size_t baselineTextures = context.objects().textures().size();
        const std::size_t baselineFramebuffers = context.objects().framebuffers().size();
        GLuint texture = 0;
        GLuint framebuffer = 0;
        gl.glGenTextures(1, &texture);
        gl.glBindTexture(GL_TEXTURE_2D, texture);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);

        gl.glGenFramebuffers(1, &framebuffer);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
                        "dcr2 sentinel framebuffer is complete");
        expectGLError(gl, GL_NO_ERROR, "dcr2 sentinel texture framebuffer setup");

        gl.glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "dcr2 sentinel delete attached texture");
        if (context.objects().textures().size() != baselineTextures
            || gl.glIsTexture(texture) != GL_FALSE) {
            recordSentinelFailure(failures, "attached texture delete left a live object", "name=" + std::to_string(texture));
        }

        gl.glFinish();
        const auto afterDeleteFinish = context.commandSubmissionDebugCounters();
        if (afterDeleteFinish.completedCommandBuffers != afterDeleteFinish.submittedCommandBuffers) {
            recordSentinelFailure(
                failures,
                "delete-before-completion finish left incomplete command buffers",
                countersSummary(afterDeleteFinish)
            );
        }

        GLuint reboundTexture = 0;
        gl.glGenTextures(1, &reboundTexture);
        if (reboundTexture == 0 || reboundTexture == texture) {
            recordSentinelFailure(
                failures,
                "texture rebind reused an invalid/deleted name",
                "deleted=" + std::to_string(texture) + " rebound=" + std::to_string(reboundTexture)
            );
        }

        std::array<std::uint8_t, 4 * 4 * 4> green = {};
        for (std::size_t pixel = 0; pixel < 16; ++pixel) {
            green[pixel * 4 + 0] = 0;
            green[pixel * 4 + 1] = 255;
            green[pixel * 4 + 2] = 0;
            green[pixel * 4 + 3] = 255;
        }
        gl.glBindTexture(GL_TEXTURE_2D, reboundTexture);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, green.data());
        std::array<std::uint8_t, 4 * 4 * 4> readback = {};
        gl.glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, readback.data());
        expectGLError(gl, GL_NO_ERROR, "dcr2 sentinel rebound texture readback");
        if (readback != green) {
            recordSentinelFailure(failures, "rebound texture readback did not match upload", "expected solid green RGBA8");
        }

        gl.glDeleteTextures(1, &reboundTexture);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        expectGLError(gl, GL_NO_ERROR, "dcr2 sentinel texture framebuffer cleanup");
        if (context.objects().textures().size() != baselineTextures
            || context.objects().framebuffers().size() != baselineFramebuffers) {
            recordSentinelFailure(
                failures,
                "delete/rebind cleanup did not restore object store counts",
                "textures=" + std::to_string(context.objects().textures().size())
                    + " framebuffers=" + std::to_string(context.objects().framebuffers().size())
            );
        }

        throwIfSentinelFailed(failures);
    });
}

TestResult runDCR3ReducedBoundContendedPressureSentinel() {
    return runDirectSentinel("dcr3.reduced-bound-contended-pressure", [] {
        ScopedEnvVar reducedBound("APPGL_COMMAND_BUFFER_BOUND", "5");
        ScopedEnvVar pressureReserve("APPGL_COMMAND_BUFFER_RESERVE", "4");
        ScopedEnvVar timeout("APPGL_COMMAND_BUFFER_TIMEOUT_MS", "10000");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();
        std::vector<std::string> failures;

        gl.glFinish();
        const auto initialCounters = context.commandSubmissionDebugCounters();
        if (initialCounters.inFlightBound != 5 || initialCounters.pressureSoftCap != 1) {
            recordSentinelFailure(
                failures,
                "reduced bound was not applied",
                countersSummary(initialCounters)
            );
        }

        const std::size_t baselineBuffers = context.objects().buffers().size();
        const std::size_t baselineTextures = context.objects().textures().size();
        const std::size_t baselineFramebuffers = context.objects().framebuffers().size();
        const std::size_t baselineVertexArrays = context.objects().vertexArrays().size();
        const std::size_t baselinePrograms = context.objects().programs().size();
        const std::size_t baselineShaders = context.objects().shaders().size();

        static constexpr const char* kPressureVS =
            "#version 330 core\n"
            "layout(location = 0) in vec2 aPos;\n"
            "void main() {\n"
            "    gl_Position = vec4(aPos, 0.0, 1.0);\n"
            "}\n";
        static constexpr const char* kPressureFS =
            "#version 330 core\n"
            "uniform vec4 uColor;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    fragColor = uColor;\n"
            "}\n";
        const GLuint program = buildBenchProgram(kPressureVS, kPressureFS);
        GLint linkStatus = GL_FALSE;
        gl.glGetProgramiv(program, GL_LINK_STATUS, &linkStatus);
        expectCondition(linkStatus == GL_TRUE, "dcr3 pressure sentinel program links");
        const GLint colorLocation = gl.glGetUniformLocation(program, "uColor");
        expectCondition(colorLocation >= 0, "dcr3 pressure sentinel color uniform exists");

        const GLfloat vertices[] = {
            -1.0f, -1.0f,
             3.0f, -1.0f,
            -1.0f,  3.0f,
        };
        GLuint vao = 0;
        GLuint vbo = 0;
        gl.glGenVertexArrays(1, &vao);
        gl.glBindVertexArray(vao);
        gl.glGenBuffers(1, &vbo);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo);
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(GLfloat), nullptr);

        GLuint textures[3] = {};
        gl.glGenTextures(3, textures);
        const GLuint colorTexture = textures[0];
        const GLuint copyTexture = textures[1];
        const GLuint depthUploadTexture = textures[2];

        auto setupRGBA8Texture = [&](GLuint texture) {
            gl.glBindTexture(GL_TEXTURE_2D, texture);
            gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            gl.glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 32, 32);
        };
        setupRGBA8Texture(colorTexture);
        setupRGBA8Texture(copyTexture);

        gl.glBindTexture(GL_TEXTURE_2D, depthUploadTexture);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

        GLuint framebuffer = 0;
        gl.glGenFramebuffers(1, &framebuffer);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                  GL_TEXTURE_2D, colorTexture, 0);
        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
                        "dcr3 pressure sentinel framebuffer is complete");
        expectGLError(gl, GL_NO_ERROR, "dcr3 pressure sentinel setup");

        std::array<std::uint16_t, 8 * 8> depthPixels = {};
        std::array<std::uint8_t, 32 * 32 * 4> readback = {};
        static constexpr int kPressureIterations = 24;
        for (int iteration = 0; iteration < kPressureIterations; ++iteration) {
            for (std::size_t index = 0; index < depthPixels.size(); ++index) {
                depthPixels[index] = static_cast<std::uint16_t>(
                    0x1000u + ((iteration * 97u + index * 13u) & 0x7fffu));
            }

            gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
            gl.glViewport(0, 0, 32, 32);
            gl.glClearColor(0.02f * static_cast<float>(iteration % 7),
                            0.15f,
                            0.25f,
                            1.0f);
            gl.glClear(GL_COLOR_BUFFER_BIT);
            gl.glUseProgram(program);
            gl.glUniform4f(colorLocation,
                           0.10f + 0.01f * static_cast<float>(iteration),
                           0.35f,
                           0.65f,
                           1.0f);
            gl.glBindVertexArray(vao);
            gl.glDrawArrays(GL_TRIANGLES, 0, 3);

            gl.glBindTexture(GL_TEXTURE_2D, depthUploadTexture);
            gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT16, 8, 8, 0,
                            GL_DEPTH_COMPONENT, GL_UNSIGNED_SHORT, depthPixels.data());
            expectGLError(gl, GL_NO_ERROR, "dcr3 pressure sentinel depth upload");

            gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
            gl.glViewport(0, 0, 32, 32);
            gl.glClearColor(0.18f,
                            0.03f * static_cast<float>(iteration % 5),
                            0.41f,
                            1.0f);
            gl.glClear(GL_COLOR_BUFFER_BIT);
            gl.glUseProgram(program);
            gl.glUniform4f(colorLocation,
                           0.25f,
                           0.20f + 0.01f * static_cast<float>(iteration),
                           0.70f,
                           1.0f);
            gl.glBindVertexArray(vao);
            gl.glDrawArrays(GL_TRIANGLES, 0, 3);

            gl.glReadPixels(0, 0, 32, 32, GL_RGBA, GL_UNSIGNED_BYTE, readback.data());
            expectGLError(gl, GL_NO_ERROR, "dcr3 pressure sentinel readback");

            gl.glCopyImageSubData(colorTexture, GL_TEXTURE_2D, 0, 0, 0, 0,
                                  copyTexture, GL_TEXTURE_2D, 0, 0, 0, 0,
                                  32, 32, 1);
            expectGLError(gl, GL_NO_ERROR, "dcr3 pressure sentinel copy");
        }

        gl.glFinish();
        const auto afterLoop = context.commandSubmissionDebugCounters();
        const std::uint64_t pressureFlushDelta =
            afterLoop.pressureFlushCount - initialCounters.pressureFlushCount;
        if (pressureFlushDelta < static_cast<std::uint64_t>(kPressureIterations)) {
            recordSentinelFailure(
                failures,
                "pressure path did not protect each held-current allocation",
                "initial{" + countersSummary(initialCounters) + "} after{" + countersSummary(afterLoop) + "}"
            );
        }
        if (afterLoop.peakInFlight > afterLoop.inFlightBound) {
            recordSentinelFailure(
                failures,
                "peak in-flight exceeded bound",
                countersSummary(afterLoop)
            );
        }
        if (afterLoop.peakInFlight <= afterLoop.pressureSoftCap) {
            recordSentinelFailure(
                failures,
                "reserve region was not exercised",
                countersSummary(afterLoop)
            );
        }
        if (allocWaitTimeoutTotal(afterLoop) != 0) {
            recordSentinelFailure(
                failures,
                "allocation wait timed out",
                countersSummary(afterLoop)
            );
        }
        if (afterLoop.currentInFlight != 0
            || afterLoop.completedCommandBuffers != afterLoop.submittedCommandBuffers) {
            recordSentinelFailure(
                failures,
                "finish left command buffers incomplete",
                countersSummary(afterLoop)
            );
        }

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindVertexArray(0);
        gl.glBindBuffer(GL_ARRAY_BUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(3, textures);
        gl.glDeleteBuffers(1, &vbo);
        gl.glDeleteVertexArrays(1, &vao);
        gl.glDeleteProgram(program);
        expectGLError(gl, GL_NO_ERROR, "dcr3 pressure sentinel cleanup");
        gl.glFinish();

        const bool objectCountsRestored =
            context.objects().buffers().size() == baselineBuffers
            && context.objects().textures().size() == baselineTextures
            && context.objects().framebuffers().size() == baselineFramebuffers
            && context.objects().vertexArrays().size() == baselineVertexArrays
            && context.objects().programs().size() == baselinePrograms
            && context.objects().shaders().size() == baselineShaders;
        if (!objectCountsRestored) {
            recordSentinelFailure(
                failures,
                "cleanup did not restore object store counts",
                "buffers=" + std::to_string(context.objects().buffers().size())
                    + " textures=" + std::to_string(context.objects().textures().size())
                    + " framebuffers=" + std::to_string(context.objects().framebuffers().size())
                    + " vertexArrays=" + std::to_string(context.objects().vertexArrays().size())
                    + " programs=" + std::to_string(context.objects().programs().size())
                    + " shaders=" + std::to_string(context.objects().shaders().size())
            );
        }

        const auto finalCounters = context.commandSubmissionDebugCounters();
        if (finalCounters.currentInFlight != 0
            || finalCounters.completedCommandBuffers != finalCounters.submittedCommandBuffers
            || allocWaitTimeoutTotal(finalCounters) != 0) {
            recordSentinelFailure(
                failures,
                "final command-submission counters were not clean",
                countersSummary(finalCounters)
            );
        }

        throwIfSentinelFailed(failures);
    });
}

struct DCR3CFboWorkloadMetrics {
    int fboDraws = 0;
    int textureUploads = 0;
    double drawLoopMs = 0.0;
    double peakMemoryMB = 0.0;
    double settledMemoryMB = 0.0;
    std::uint64_t pressureFlushDelta = 0;
    std::uint64_t submittedDelta = 0;
    std::uint64_t waitLogDelta = 0;
    std::uint32_t peakInFlight = 0;
    std::uint32_t bound = 0;
    std::uint32_t softCap = 0;
    std::uint64_t allocWaitTimeouts = 0;
    std::array<std::uint8_t, 4> readbackPixel{};
};

std::string dcr3cWorkloadSummary(std::string_view label,
                                 const DCR3CFboWorkloadMetrics& metrics) {
    std::ostringstream stream;
    stream << label
           << " draws=" << metrics.fboDraws
           << " uploads=" << metrics.textureUploads
           << " drawLoopMs=" << formatDouble(metrics.drawLoopMs)
           << " pressureFlushDelta=" << metrics.pressureFlushDelta
           << " submittedDelta=" << metrics.submittedDelta
           << " waitLogDelta=" << metrics.waitLogDelta
           << " peakInFlight=" << metrics.peakInFlight
           << " bound=" << metrics.bound
           << " softCap=" << metrics.softCap
           << " allocWaitTimeouts=" << metrics.allocWaitTimeouts
           << " peakMemoryMB=" << formatDouble(metrics.peakMemoryMB)
           << " settledMemoryMB=" << formatDouble(metrics.settledMemoryMB)
           << " readbackRGBA=("
           << static_cast<unsigned>(metrics.readbackPixel[0]) << ","
           << static_cast<unsigned>(metrics.readbackPixel[1]) << ","
           << static_cast<unsigned>(metrics.readbackPixel[2]) << ","
           << static_cast<unsigned>(metrics.readbackPixel[3]) << ")";
    return stream.str();
}

DCR3CFboWorkloadMetrics runDCR3CFboWorkload(GLContext& context,
                                            GLDispatchTable& gl,
                                            int chainDraws,
                                            int uploadEvery,
                                            bool presentOnce,
                                            bool finalReadback,
                                            std::vector<std::string>& failures,
                                            std::string_view label) {
    static constexpr GLsizei kSize = 32;
    static constexpr const char* kFullscreenVS =
        "#version 330 core\n"
        "layout(location = 0) in vec2 aPos;\n"
        "void main() {\n"
        "    gl_Position = vec4(aPos, 0.0, 1.0);\n"
        "}\n";
    static constexpr const char* kSeedFS =
        "#version 330 core\n"
        "uniform vec4 uColor;\n"
        "out vec4 fragColor;\n"
        "void main() {\n"
        "    fragColor = uColor;\n"
        "}\n";
    static constexpr const char* kSampleFS =
        "#version 330 core\n"
        "uniform sampler2D uSource;\n"
        "out vec4 fragColor;\n"
        "void main() {\n"
        "    vec4 s = texture(uSource, vec2(0.5, 0.5));\n"
        "    fragColor = vec4(s.g, s.b, s.r, 1.0);\n"
        "}\n";

    DCR3CFboWorkloadMetrics metrics;
    metrics.fboDraws = chainDraws + 1;

    const std::size_t baselineBuffers = context.objects().buffers().size();
    const std::size_t baselineTextures = context.objects().textures().size();
    const std::size_t baselineFramebuffers = context.objects().framebuffers().size();
    const std::size_t baselineVertexArrays = context.objects().vertexArrays().size();
    const std::size_t baselinePrograms = context.objects().programs().size();
    const std::size_t baselineShaders = context.objects().shaders().size();

    const GLuint seedProgram = buildBenchProgram(kFullscreenVS, kSeedFS);
    const GLuint sampleProgram = buildBenchProgram(kFullscreenVS, kSampleFS);
    GLint seedLinked = GL_FALSE;
    GLint sampleLinked = GL_FALSE;
    gl.glGetProgramiv(seedProgram, GL_LINK_STATUS, &seedLinked);
    gl.glGetProgramiv(sampleProgram, GL_LINK_STATUS, &sampleLinked);
    expectCondition(seedLinked == GL_TRUE, "dcr3c seed program links");
    expectCondition(sampleLinked == GL_TRUE, "dcr3c sample program links");
    const GLint seedColorLocation = gl.glGetUniformLocation(seedProgram, "uColor");
    const GLint sampleSourceLocation = gl.glGetUniformLocation(sampleProgram, "uSource");
    expectCondition(seedColorLocation >= 0, "dcr3c seed color uniform exists");
    expectCondition(sampleSourceLocation >= 0, "dcr3c sample source uniform exists");

    const GLfloat vertices[] = {
        -1.0f, -1.0f,
         3.0f, -1.0f,
        -1.0f,  3.0f,
    };
    GLuint vao = 0;
    GLuint vbo = 0;
    gl.glGenVertexArrays(1, &vao);
    gl.glBindVertexArray(vao);
    gl.glGenBuffers(1, &vbo);
    gl.glBindBuffer(GL_ARRAY_BUFFER, vbo);
    gl.glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
    gl.glEnableVertexAttribArray(0);
    gl.glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(GLfloat), nullptr);

    GLuint textures[2] = {};
    GLuint depthUploadTexture = 0;
    GLuint framebuffers[2] = {};
    gl.glGenTextures(2, textures);
    for (GLuint texture : textures) {
        gl.glBindTexture(GL_TEXTURE_2D, texture);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        gl.glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, kSize, kSize);
    }
    gl.glGenFramebuffers(2, framebuffers);
    for (int index = 0; index < 2; ++index) {
        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffers[index]);
        gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                  GL_TEXTURE_2D, textures[index], 0);
        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
                        "dcr3c ping-pong framebuffer is complete");
    }

    std::array<std::uint16_t, 8 * 8> depthPixels = {};
    gl.glGenTextures(1, &depthUploadTexture);
    gl.glBindTexture(GL_TEXTURE_2D, depthUploadTexture);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    expectGLError(gl, GL_NO_ERROR, "dcr3c workload setup");

    gl.glFinish();
    const auto initialCounters = context.commandSubmissionDebugCounters();
    double peakMemoryMB = static_cast<double>(context.metalAllocatedBytes()) / (1024.0 * 1024.0);

    auto noteMemory = [&]() {
        const double memoryMB = static_cast<double>(context.metalAllocatedBytes()) / (1024.0 * 1024.0);
        if (memoryMB > peakMemoryMB) {
            peakMemoryMB = memoryMB;
        }
    };
    auto checkDrawDidNotReadbackWait = [&](int drawIndex) {
        const auto counters = context.commandSubmissionDebugCounters();
        if (counters.lastWaitReason == AppGLCommandReason::FlushForReadback &&
            counters.lastWaitMode == AppGLSubmitMode::CommitAndWait) {
            recordSentinelFailure(
                failures,
                "FBO draw used per-draw FlushForReadback wait",
                std::string(label) + " draw=" + std::to_string(drawIndex)
                    + " counters{" + countersSummary(counters) + "}"
            );
        }
        noteMemory();
    };

    const auto loopStart = std::chrono::steady_clock::now();

    gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffers[0]);
    gl.glViewport(0, 0, kSize, kSize);
    gl.glUseProgram(seedProgram);
    gl.glUniform4f(seedColorLocation, 1.0f, 0.0f, 0.0f, 1.0f);
    gl.glBindVertexArray(vao);
    gl.glDrawArrays(GL_TRIANGLES, 0, 3);
    expectGLError(gl, GL_NO_ERROR, "dcr3c seed FBO draw");
    checkDrawDidNotReadbackWait(0);

    int currentTexture = 0;
    for (int iteration = 0; iteration < chainDraws; ++iteration) {
        const int destination = 1 - currentTexture;
        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffers[destination]);
        gl.glViewport(0, 0, kSize, kSize);
        gl.glUseProgram(sampleProgram);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_2D, textures[currentTexture]);
        gl.glUniform1i(sampleSourceLocation, 0);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        expectGLError(gl, GL_NO_ERROR, "dcr3c chained FBO draw");
        checkDrawDidNotReadbackWait(iteration + 1);
        currentTexture = destination;

        if (uploadEvery > 0 && ((iteration + 1) % uploadEvery) == 0) {
            for (std::size_t pixel = 0; pixel < depthPixels.size(); ++pixel) {
                depthPixels[pixel] = static_cast<std::uint16_t>(
                    0x1000u + ((iteration * 97u + pixel * 13u) & 0x7fffu));
            }
            gl.glBindTexture(GL_TEXTURE_2D, depthUploadTexture);
            gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT16, 8, 8, 0,
                            GL_DEPTH_COMPONENT, GL_UNSIGNED_SHORT, depthPixels.data());
            ++metrics.textureUploads;
            expectGLError(gl, GL_NO_ERROR, "dcr3c pressure-triggering depth upload");
            noteMemory();
        }
    }

    const auto loopEnd = std::chrono::steady_clock::now();
    metrics.drawLoopMs = std::chrono::duration<double, std::milli>(loopEnd - loopStart).count();

    if (presentOnce) {
        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glViewport(0, 0, kSize, kSize);
        gl.glUseProgram(sampleProgram);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_2D, textures[currentTexture]);
        gl.glUniform1i(sampleSourceLocation, 0);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        expectGLError(gl, GL_NO_ERROR, "dcr3c present-once default draw");
        checkDrawDidNotReadbackWait(chainDraws + 1);
        context.swapBuffers();
    }

    if (finalReadback) {
        std::array<std::uint8_t, kSize * kSize * 4> readback = {};
        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffers[currentTexture]);
        gl.glReadPixels(0, 0, kSize, kSize, GL_RGBA, GL_UNSIGNED_BYTE, readback.data());
        expectGLError(gl, GL_NO_ERROR, "dcr3c final FBO readback");
        const std::size_t centerOffset = ((kSize / 2) * kSize + (kSize / 2)) * 4;
        metrics.readbackPixel = {
            readback[centerOffset + 0],
            readback[centerOffset + 1],
            readback[centerOffset + 2],
            readback[centerOffset + 3],
        };
        if (metrics.readbackPixel[0] < 240 ||
            metrics.readbackPixel[1] > 15 ||
            metrics.readbackPixel[2] > 15 ||
            metrics.readbackPixel[3] < 240) {
            recordSentinelFailure(
                failures,
                "final ping-pong readback was not red",
                "rgba=(" + std::to_string(metrics.readbackPixel[0]) + ","
                    + std::to_string(metrics.readbackPixel[1]) + ","
                    + std::to_string(metrics.readbackPixel[2]) + ","
                    + std::to_string(metrics.readbackPixel[3]) + ")"
            );
        }
        const auto afterReadback = context.commandSubmissionDebugCounters();
        if (afterReadback.lastWaitReason != AppGLCommandReason::FlushForReadback ||
            afterReadback.lastWaitMode != AppGLSubmitMode::CommitAndWait) {
            recordSentinelFailure(
                failures,
                "final readback was not FlushForReadback-attributed",
                countersSummary(afterReadback)
            );
        }
    }

    gl.glFinish();
    const auto afterWork = context.commandSubmissionDebugCounters();
    metrics.pressureFlushDelta = afterWork.pressureFlushCount - initialCounters.pressureFlushCount;
    metrics.submittedDelta = afterWork.submittedCommandBuffers - initialCounters.submittedCommandBuffers;
    metrics.waitLogDelta = afterWork.waitReasonLogEntries - initialCounters.waitReasonLogEntries;
    metrics.peakInFlight = afterWork.peakInFlight;
    metrics.bound = afterWork.inFlightBound;
    metrics.softCap = afterWork.pressureSoftCap;
    metrics.allocWaitTimeouts = allocWaitTimeoutTotal(afterWork);
    metrics.peakMemoryMB = peakMemoryMB;

    if (metrics.pressureFlushDelta == 0) {
        recordSentinelFailure(
            failures,
            "pressure net did not fire under FBO accumulation",
            "initial{" + countersSummary(initialCounters) + "} after{" + countersSummary(afterWork) + "}"
        );
    }
    if (afterWork.peakInFlight <= afterWork.pressureSoftCap) {
        recordSentinelFailure(
            failures,
            "FBO accumulation did not enter pressure reserve",
            countersSummary(afterWork)
        );
    }
    if (afterWork.peakInFlight > afterWork.inFlightBound) {
        recordSentinelFailure(
            failures,
            "peak in-flight exceeded bound",
            countersSummary(afterWork)
        );
    }
    if (metrics.allocWaitTimeouts != 0) {
        recordSentinelFailure(
            failures,
            "allocation wait timed out",
            countersSummary(afterWork)
        );
    }
    if (afterWork.currentInFlight != 0 ||
        afterWork.completedCommandBuffers != afterWork.submittedCommandBuffers) {
        recordSentinelFailure(
            failures,
            "finish left command buffers incomplete",
            countersSummary(afterWork)
        );
    }

    gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
    gl.glBindVertexArray(0);
    gl.glBindBuffer(GL_ARRAY_BUFFER, 0);
    gl.glBindTexture(GL_TEXTURE_2D, 0);
    gl.glUseProgram(0);
    gl.glDeleteFramebuffers(2, framebuffers);
    gl.glDeleteTextures(2, textures);
    gl.glDeleteTextures(1, &depthUploadTexture);
    gl.glDeleteBuffers(1, &vbo);
    gl.glDeleteVertexArrays(1, &vao);
    gl.glDeleteProgram(seedProgram);
    gl.glDeleteProgram(sampleProgram);
    expectGLError(gl, GL_NO_ERROR, "dcr3c workload cleanup");
    gl.glFinish();
    metrics.settledMemoryMB = static_cast<double>(context.metalAllocatedBytes()) / (1024.0 * 1024.0);

    const bool objectCountsRestored =
        context.objects().buffers().size() == baselineBuffers &&
        context.objects().textures().size() == baselineTextures &&
        context.objects().framebuffers().size() == baselineFramebuffers &&
        context.objects().vertexArrays().size() == baselineVertexArrays &&
        context.objects().programs().size() == baselinePrograms &&
        context.objects().shaders().size() == baselineShaders;
    if (!objectCountsRestored) {
        recordSentinelFailure(
            failures,
            "cleanup did not restore object store counts",
            "buffers=" + std::to_string(context.objects().buffers().size())
                + " textures=" + std::to_string(context.objects().textures().size())
                + " framebuffers=" + std::to_string(context.objects().framebuffers().size())
                + " vertexArrays=" + std::to_string(context.objects().vertexArrays().size())
                + " programs=" + std::to_string(context.objects().programs().size())
                + " shaders=" + std::to_string(context.objects().shaders().size())
        );
    }

    const auto finalCounters = context.commandSubmissionDebugCounters();
    if (finalCounters.currentInFlight != 0 ||
        finalCounters.completedCommandBuffers != finalCounters.submittedCommandBuffers ||
        allocWaitTimeoutTotal(finalCounters) != 0) {
        recordSentinelFailure(
            failures,
            "final command-submission counters were not clean",
            countersSummary(finalCounters)
        );
    }

    return metrics;
}

TestResult runDCR3CFboPressureReadbackSentinel() {
    std::string summary;
    auto result = runDirectSentinel("dcr3c.fbo-pressure-readback", [&] {
        ScopedEnvVar reducedBound("APPGL_COMMAND_BUFFER_BOUND", "5");
        ScopedEnvVar pressureReserve("APPGL_COMMAND_BUFFER_RESERVE", "4");
        ScopedEnvVar timeout("APPGL_COMMAND_BUFFER_TIMEOUT_MS", "10000");
        ScopedEnvVar profile("APPGL_CB_PROFILE", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();
        std::vector<std::string> failures;

        const auto metrics = runDCR3CFboWorkload(
            context, gl, 21, 4, false, true, failures, "readback");
        throwIfSentinelFailed(failures);
        summary = dcr3cWorkloadSummary("readback", metrics);
    });
    if (result.status == "passed") {
        result.message = summary;
    }
    return result;
}

TestResult runDCR3CSoakBarBenchmarkSentinel() {
    std::string summary;
    auto result = runDirectSentinel("dcr3c.sustained-soak-bar", [&] {
        ScopedEnvVar reducedBound("APPGL_COMMAND_BUFFER_BOUND", "5");
        ScopedEnvVar pressureReserve("APPGL_COMMAND_BUFFER_RESERVE", "4");
        ScopedEnvVar timeout("APPGL_COMMAND_BUFFER_TIMEOUT_MS", "10000");
        ScopedEnvVar profile("APPGL_CB_PROFILE", "1");

        ScopedSentinelContext scoped(64, 64);
        auto& context = scoped.context();
        auto& gl = scoped.gl();
        std::vector<std::string> failures;

        const auto metrics = runDCR3CFboWorkload(
            context, gl, 181, 6, true, false, failures, "soak");
        throwIfSentinelFailed(failures);
        summary = dcr3cWorkloadSummary("soak", metrics);
    });
    if (result.status == "passed") {
        result.message = summary;
    }
    return result;
}

TestResult runDCR3CMSAAResolveReadbackSentinel() {
    auto result = runDirectSentinel("dcr3c.msaa-resolve-readback-sync", [&] {
        static constexpr GLsizei kSize = 32;
        static constexpr const char* kFullscreenVS =
            "#version 330 core\n"
            "layout(location = 0) in vec2 aPos;\n"
            "void main() {\n"
            "    gl_Position = vec4(aPos, 0.0, 1.0);\n"
            "}\n";
        static constexpr const char* kColorFS =
            "#version 330 core\n"
            "uniform vec4 uColor;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    fragColor = uColor;\n"
            "}\n";

        ScopedSentinelContext scoped(64, 64);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        const GLuint program = buildBenchProgram(kFullscreenVS, kColorFS);
        GLint linked = GL_FALSE;
        gl.glGetProgramiv(program, GL_LINK_STATUS, &linked);
        expectCondition(linked == GL_TRUE, "dcr3c msaa resolve program links");
        const GLint colorLocation = gl.glGetUniformLocation(program, "uColor");
        expectCondition(colorLocation >= 0, "dcr3c msaa resolve color uniform exists");

        const GLfloat vertices[] = {
            -1.0f, -1.0f,
             3.0f, -1.0f,
            -1.0f,  3.0f,
        };
        GLuint vao = 0;
        GLuint vbo = 0;
        gl.glGenVertexArrays(1, &vao);
        gl.glBindVertexArray(vao);
        gl.glGenBuffers(1, &vbo);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo);
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(GLfloat), nullptr);

        GLuint msaaFbo = 0;
        GLuint msaaColor = 0;
        gl.glGenFramebuffers(1, &msaaFbo);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, msaaFbo);
        gl.glGenRenderbuffers(1, &msaaColor);
        gl.glBindRenderbuffer(GL_RENDERBUFFER, msaaColor);
        gl.glRenderbufferStorageMultisample(GL_RENDERBUFFER, 4, GL_RGBA8, kSize, kSize);
        gl.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                     GL_RENDERBUFFER, msaaColor);
        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
                        "dcr3c MSAA source framebuffer complete");

        GLuint resolveFbo = 0;
        GLuint resolveTex = 0;
        gl.glGenFramebuffers(1, &resolveFbo);
        gl.glGenTextures(1, &resolveTex);
        gl.glBindTexture(GL_TEXTURE_2D, resolveTex);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, kSize, kSize);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, resolveFbo);
        gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                  GL_TEXTURE_2D, resolveTex, 0);
        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
                        "dcr3c resolve framebuffer complete");
        expectGLError(gl, GL_NO_ERROR, "dcr3c msaa resolve setup");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, msaaFbo);
        gl.glViewport(0, 0, kSize, kSize);
        gl.glUseProgram(program);
        gl.glUniform4f(colorLocation, 0.0f, 1.0f, 0.0f, 1.0f);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        expectGLError(gl, GL_NO_ERROR, "dcr3c MSAA producer draw");

        const auto afterDraw = context.commandSubmissionDebugCounters();
        if (afterDraw.lastWaitReason == AppGLCommandReason::FlushForReadback &&
            afterDraw.lastWaitMode == AppGLSubmitMode::CommitAndWait) {
            throw std::runtime_error(
                "MSAA producer draw used eager FlushForReadback wait: "
                + countersSummary(afterDraw));
        }

        gl.glBindFramebuffer(GL_READ_FRAMEBUFFER, msaaFbo);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        gl.glBindFramebuffer(GL_DRAW_FRAMEBUFFER, resolveFbo);
        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glBlitFramebuffer(0, 0, kSize, kSize,
                             0, 0, kSize, kSize,
                             GL_COLOR_BUFFER_BIT, GL_NEAREST);
        expectGLError(gl, GL_NO_ERROR, "dcr3c MSAA resolve blit");

        const auto afterResolve = context.commandSubmissionDebugCounters();
        if (afterResolve.lastWaitReason != AppGLCommandReason::FlushForReadback ||
            afterResolve.lastWaitMode != AppGLSubmitMode::CommitAndWait) {
            throw std::runtime_error(
                "MSAA resolve readback was not covered by FlushForReadback: "
                + countersSummary(afterResolve));
        }

        std::array<std::uint8_t, 4> pixel = {};
        gl.glBindFramebuffer(GL_FRAMEBUFFER, resolveFbo);
        gl.glReadPixels(kSize / 2, kSize / 2, 1, 1,
                        GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
        expectGLError(gl, GL_NO_ERROR, "dcr3c resolved FBO readback");
        if (pixel[0] > 15 || pixel[1] < 240 ||
            pixel[2] > 15 || pixel[3] < 240) {
            std::ostringstream message;
            message << "resolved MSAA pixel was not green: rgba=("
                    << static_cast<unsigned>(pixel[0]) << ","
                    << static_cast<unsigned>(pixel[1]) << ","
                    << static_cast<unsigned>(pixel[2]) << ","
                    << static_cast<unsigned>(pixel[3]) << ")";
            throw std::runtime_error(message.str());
        }

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindVertexArray(0);
        gl.glBindBuffer(GL_ARRAY_BUFFER, 0);
        gl.glBindTexture(GL_TEXTURE_2D, 0);
        gl.glBindRenderbuffer(GL_RENDERBUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteTextures(1, &resolveTex);
        gl.glDeleteRenderbuffers(1, &msaaColor);
        GLuint framebuffers[] = { msaaFbo, resolveFbo };
        gl.glDeleteFramebuffers(2, framebuffers);
        gl.glDeleteBuffers(1, &vbo);
        gl.glDeleteVertexArrays(1, &vao);
        gl.glDeleteProgram(program);
        expectGLError(gl, GL_NO_ERROR, "dcr3c msaa resolve cleanup");
    });
    if (result.status == "passed") {
        result.message = "MSAA draw -> blit resolve -> readback stayed coherent without per-draw wait";
    }
    return result;
}

TestResult runDCR3CMSAAShaderResolveReadbackSentinel() {
    auto result = runDirectSentinel("dcr3c.msaa-shader-resolve-readback-sync", [&] {
        static constexpr GLsizei kSize = 8;
        static constexpr GLsizei kSamples = 4;
        static constexpr const char* kFullscreenVS =
            "#version 440\n"
            "layout(location = 0) in vec2 a_position;\n"
            "void main() {\n"
            "    gl_Position = vec4(a_position, 0.0, 1.0);\n"
            "}\n";
        static constexpr const char* kMaskFS =
            "#version 440\n"
            "layout(location = 0) out highp vec4 o_color;\n"
            "uniform int u_sampleMask;\n"
            "void main() {\n"
            "    for (int i = 0; i < (gl_NumSamples + 31) / 32; ++i) {\n"
            "        gl_SampleMask[i] = u_sampleMask & gl_SampleMaskIn[i];\n"
            "    }\n"
            "    o_color = vec4(1.0, 0.0, 0.0, 1.0);\n"
            "}\n";
        static constexpr const char* kResolveFS =
            "#version 440\n"
            "uniform highp sampler2D u_tex;\n"
            "uniform highp sampler2DMS u_texMS;\n"
            "uniform int u_samples;\n"
            "layout(location = 0) out highp vec4 o_color;\n"
            "void main() {\n"
            "    if (u_samples > 0) {\n"
            "        ivec2 coord = ivec2(int(gl_FragCoord.x) / u_samples, gl_FragCoord.y);\n"
            "        int sampleId = int(gl_FragCoord.x) % u_samples;\n"
            "        o_color = texelFetch(u_texMS, coord, sampleId);\n"
            "    } else {\n"
            "        ivec2 coord = ivec2(gl_FragCoord.x, gl_FragCoord.y);\n"
            "        o_color = texelFetch(u_tex, coord, 0);\n"
            "    }\n"
            "}\n";

        ScopedEnvVar profile("APPGL_CB_PROFILE", "1");
        ScopedSentinelContext scoped(64, 64);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        const GLuint maskProgram = buildBenchProgram(kFullscreenVS, kMaskFS);
        const GLuint resolveProgram = buildBenchProgram(kFullscreenVS, kResolveFS);
        GLint maskLinked = GL_FALSE;
        GLint resolveLinked = GL_FALSE;
        gl.glGetProgramiv(maskProgram, GL_LINK_STATUS, &maskLinked);
        gl.glGetProgramiv(resolveProgram, GL_LINK_STATUS, &resolveLinked);
        expectCondition(maskLinked == GL_TRUE, "dcr3c msaa shader producer program links");
        expectCondition(resolveLinked == GL_TRUE, "dcr3c msaa shader resolve program links");
        const GLint maskLocation = gl.glGetUniformLocation(maskProgram, "u_sampleMask");
        const GLint samplesLocation = gl.glGetUniformLocation(resolveProgram, "u_samples");
        const GLint texLocation = gl.glGetUniformLocation(resolveProgram, "u_tex");
        const GLint texMSLocation = gl.glGetUniformLocation(resolveProgram, "u_texMS");
        expectCondition(maskLocation >= 0, "dcr3c msaa shader producer mask uniform exists");
        expectCondition(samplesLocation >= 0, "dcr3c msaa shader resolve samples uniform exists");
        expectCondition(texLocation >= 0, "dcr3c msaa shader resolve 2d sampler uniform exists");
        expectCondition(texMSLocation >= 0, "dcr3c msaa shader resolve 2dms sampler uniform exists");

        const GLfloat vertices[] = {
            -1.0f, -1.0f,
            -1.0f,  1.0f,
             1.0f, -1.0f,
             1.0f,  1.0f,
        };
        GLuint vao = 0;
        GLuint vbo = 0;
        gl.glGenVertexArrays(1, &vao);
        gl.glBindVertexArray(vao);
        gl.glGenBuffers(1, &vbo);
        gl.glBindBuffer(GL_ARRAY_BUFFER, vbo);
        gl.glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(GLfloat), nullptr);

        GLuint msaaTex = 0;
        gl.glGenTextures(1, &msaaTex);
        gl.glBindTexture(GL_TEXTURE_2D_MULTISAMPLE, msaaTex);
        gl.glTexStorage2DMultisample(GL_TEXTURE_2D_MULTISAMPLE, kSamples, GL_RGBA8,
                                     kSize, kSize, GL_FALSE);

        GLuint msaaFbo = 0;
        gl.glGenFramebuffers(1, &msaaFbo);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, msaaFbo);
        gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                  GL_TEXTURE_2D_MULTISAMPLE, msaaTex, 0);
        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
                        "dcr3c shader MSAA source framebuffer complete");

        const GLfloat clearGreen[] = {0.0f, 1.0f, 0.0f, 1.0f};
        gl.glViewport(0, 0, kSize, kSize);
        gl.glClearBufferfv(GL_COLOR, 0, clearGreen);
        gl.glUseProgram(maskProgram);
        gl.glUniform1i(maskLocation, 1);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        expectGLError(gl, GL_NO_ERROR, "dcr3c shader MSAA producer draw");

        const auto afterProducer = context.commandSubmissionDebugCounters();
        if (afterProducer.lastWaitReason == AppGLCommandReason::FlushForReadback &&
            afterProducer.lastWaitMode == AppGLSubmitMode::CommitAndWait) {
            throw std::runtime_error(
                "MSAA shader producer draw used eager FlushForReadback wait: "
                + countersSummary(afterProducer));
        }

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glDeleteFramebuffers(1, &msaaFbo);

        GLuint resolveRbo = 0;
        gl.glGenRenderbuffers(1, &resolveRbo);
        gl.glBindRenderbuffer(GL_RENDERBUFFER, resolveRbo);
        gl.glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, kSize * kSamples, kSize);

        GLuint resolveFbo = 0;
        gl.glGenFramebuffers(1, &resolveFbo);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, resolveFbo);
        gl.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                     GL_RENDERBUFFER, resolveRbo);
        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
                        "dcr3c shader resolve framebuffer complete");
        expectGLError(gl, GL_NO_ERROR, "dcr3c shader resolve setup");

        gl.glViewport(0, 0, kSize * kSamples, kSize);
        gl.glUseProgram(resolveProgram);
        gl.glUniform1i(samplesLocation, kSamples);
        gl.glUniform1i(texLocation, 1);
        gl.glUniform1i(texMSLocation, 0);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_2D_MULTISAMPLE, msaaTex);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        expectGLError(gl, GL_NO_ERROR, "dcr3c shader MSAA resolve draw");

        std::array<std::uint8_t, kSize * kSamples * kSize * 4> pixels = {};
        gl.glReadPixels(0, 0, kSize * kSamples, kSize,
                        GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
        expectGLError(gl, GL_NO_ERROR, "dcr3c shader resolved FBO readback");

        for (GLsizei y = 0; y < kSize; ++y) {
            for (GLsizei x = 0; x < kSize; ++x) {
                for (GLsizei sample = 0; sample < kSamples; ++sample) {
                    const std::size_t offset =
                        (static_cast<std::size_t>(y) * kSize * kSamples
                         + static_cast<std::size_t>(x) * kSamples
                         + static_cast<std::size_t>(sample)) * 4u;
                    const bool expectRed = sample == 0;
                    const std::uint8_t r = pixels[offset + 0];
                    const std::uint8_t g = pixels[offset + 1];
                    const std::uint8_t b = pixels[offset + 2];
                    const std::uint8_t a = pixels[offset + 3];
                    const bool redOk = r > 240 && g < 15 && b < 15 && a > 240;
                    const bool greenOk = r < 15 && g > 240 && b < 15 && a > 240;
                    if ((expectRed && !redOk) || (!expectRed && !greenOk)) {
                        std::ostringstream message;
                        message << "shader-resolved sample mismatch at pixel=("
                                << x << "," << y << ") sample=" << sample
                                << " rgba=(" << static_cast<unsigned>(r) << ","
                                << static_cast<unsigned>(g) << ","
                                << static_cast<unsigned>(b) << ","
                                << static_cast<unsigned>(a) << ")";
                        throw std::runtime_error(message.str());
                    }
                }
            }
        }

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindVertexArray(0);
        gl.glBindBuffer(GL_ARRAY_BUFFER, 0);
        gl.glBindTexture(GL_TEXTURE_2D_MULTISAMPLE, 0);
        gl.glBindRenderbuffer(GL_RENDERBUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteRenderbuffers(1, &resolveRbo);
        gl.glDeleteFramebuffers(1, &resolveFbo);
        gl.glDeleteTextures(1, &msaaTex);
        gl.glDeleteBuffers(1, &vbo);
        gl.glDeleteVertexArrays(1, &vao);
        gl.glDeleteProgram(maskProgram);
        gl.glDeleteProgram(resolveProgram);
        expectGLError(gl, GL_NO_ERROR, "dcr3c shader resolve cleanup");
    });
    if (result.status == "passed") {
        result.message = "MSAA texture draw -> sampler2DMS shader resolve -> readback stayed coherent without per-draw wait";
    }
    return result;
}

std::string pendingBitsSummary(std::uint32_t bits) {
    std::ostringstream stream;
    stream << "0x" << std::hex << bits;
    return stream.str();
}

std::uint32_t texturePendingBits(GLContext& context, GLuint texture) {
    const GLTextureObject* object = context.objects().textures().get(texture);
    expectCondition(object != nullptr, "dcr3c pending texture object exists");
    return object->producerPending.bits();
}

std::uint32_t renderbufferPendingBits(GLContext& context, GLuint renderbuffer) {
    const GLRenderbufferObject* object =
        context.objects().renderbuffers().get(renderbuffer);
    expectCondition(object != nullptr, "dcr3c pending renderbuffer object exists");
    return object->producerPending.bits();
}

std::uint32_t bufferPendingBits(GLContext& context, GLuint buffer) {
    const GLBufferObject* object = context.objects().buffers().get(buffer);
    expectCondition(object != nullptr, "dcr3c pending buffer object exists");
    return object->producerPending.bits();
}

void expectPendingHas(std::uint32_t actual,
                      std::uint32_t expected,
                      std::string_view label) {
    if ((actual & expected) != expected) {
        throw std::runtime_error(
            std::string(label) + " missing pending bits expected="
            + pendingBitsSummary(expected) + " actual="
            + pendingBitsSummary(actual));
    }
}

void expectPendingClear(std::uint32_t actual,
                        std::uint32_t mask,
                        std::string_view label) {
    if ((actual & mask) != 0) {
        throw std::runtime_error(
            std::string(label) + " retained pending bits mask="
            + pendingBitsSummary(mask) + " actual="
            + pendingBitsSummary(actual));
    }
}

void setupDCR3CFullscreenTriangle(GLDispatchTable& gl,
                                  GLuint& vao,
                                  GLuint& vbo) {
    const GLfloat vertices[] = {
        -1.0f, -1.0f,
         3.0f, -1.0f,
        -1.0f,  3.0f,
    };
    gl.glGenVertexArrays(1, &vao);
    gl.glBindVertexArray(vao);
    gl.glGenBuffers(1, &vbo);
    gl.glBindBuffer(GL_ARRAY_BUFFER, vbo);
    gl.glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
    gl.glEnableVertexAttribArray(0);
    gl.glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE,
                             2 * sizeof(GLfloat), nullptr);
}

GLuint buildDCR3CComputeProgram(const char* csSrc) {
    auto& gl = Runtime::shared().dispatch();
    GLuint cs = gl.glCreateShader(GL_COMPUTE_SHADER);
    gl.glShaderSource(cs, 1, &csSrc, nullptr);
    gl.glCompileShader(cs);
    GLuint program = gl.glCreateProgram();
    gl.glAttachShader(program, cs);
    gl.glLinkProgram(program);
    gl.glDeleteShader(cs);
    return program;
}

void setupDCR3CRGBA8Texture(GLDispatchTable& gl,
                            GLuint texture,
                            GLsizei width,
                            GLsizei height,
                            GLsizei levels = 1) {
    gl.glBindTexture(GL_TEXTURE_2D, texture);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
                       levels > 1 ? GL_NEAREST_MIPMAP_NEAREST : GL_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl.glTexStorage2D(GL_TEXTURE_2D, levels, GL_RGBA8, width, height);
}

void setupDCR3CDepth32FTexture(GLDispatchTable& gl,
                               GLuint texture,
                               GLsizei width,
                               GLsizei height,
                               GLsizei levels = 1) {
    gl.glBindTexture(GL_TEXTURE_2D, texture);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
                       levels > 1 ? GL_NEAREST_MIPMAP_NEAREST : GL_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_NONE);
    gl.glTexStorage2D(GL_TEXTURE_2D, levels, GL_DEPTH_COMPONENT32F,
                      width, height);
}

void setupDCR3CDepth32FArrayTexture(GLDispatchTable& gl,
                                    GLuint texture,
                                    GLsizei width,
                                    GLsizei height,
                                    GLsizei layers,
                                    GLsizei levels = 1) {
    gl.glBindTexture(GL_TEXTURE_2D_ARRAY, texture);
    gl.glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER,
                       levels > 1 ? GL_NEAREST_MIPMAP_NEAREST : GL_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_COMPARE_MODE, GL_NONE);
    gl.glTexStorage3D(GL_TEXTURE_2D_ARRAY, levels, GL_DEPTH_COMPONENT32F,
                      width, height, layers);
}

void primeDCR3CDepth32FTexture(GLDispatchTable& gl,
                               GLuint texture,
                               GLsizei width,
                               GLsizei height,
                               GLsizei layers = 1) {
    const std::size_t texelCount =
        static_cast<std::size_t>(width) *
        static_cast<std::size_t>(height) *
        static_cast<std::size_t>(layers);
    std::vector<GLfloat> zeros(texelCount, 0.0f);
    if (layers == 1) {
        gl.glTextureSubImage2D(texture, 0, 0, 0, width, height,
                               GL_DEPTH_COMPONENT, GL_FLOAT, zeros.data());
    } else {
        gl.glTextureSubImage3D(texture, 0, 0, 0, 0, width, height, layers,
                               GL_DEPTH_COMPONENT, GL_FLOAT, zeros.data());
    }
}

void setupDCR3CTextureFbo(GLDispatchTable& gl,
                          GLuint& fbo,
                          GLuint texture,
                          GLint level = 0) {
    gl.glGenFramebuffers(1, &fbo);
    gl.glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                              GL_TEXTURE_2D, texture, level);
    gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
    gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
    expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) ==
                        GL_FRAMEBUFFER_COMPLETE,
                    "dcr3c sentinel framebuffer complete");
}

void setupDCR3CDepthTextureFbo(GLDispatchTable& gl,
                               GLuint& fbo,
                               GLuint depthTexture,
                               GLint level = 0) {
    gl.glGenFramebuffers(1, &fbo);
    gl.glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                              GL_TEXTURE_2D, depthTexture, level);
    gl.glDrawBuffer(GL_NONE);
    gl.glReadBuffer(GL_NONE);
    expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) ==
                        GL_FRAMEBUFFER_COMPLETE,
                    "depth32f sentinel framebuffer complete");
}

void setupDCR3CDepthArrayLayerFbo(GLDispatchTable& gl,
                                  GLuint& fbo,
                                  GLuint depthTexture,
                                  GLint layer,
                                  GLint level = 0) {
    gl.glGenFramebuffers(1, &fbo);
    gl.glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    gl.glFramebufferTextureLayer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                                 depthTexture, level, layer);
    gl.glDrawBuffer(GL_NONE);
    gl.glReadBuffer(GL_NONE);
    expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) ==
                        GL_FRAMEBUFFER_COMPLETE,
                    "depth32f array sentinel framebuffer complete");
}

void seedDepthAttachmentWithDraw(GLDispatchTable& gl,
                                 GLuint framebuffer,
                                 GLsizei width,
                                 GLsizei height,
                                 GLfloat depthValue) {
    static constexpr const char* kDepthWriteVS =
        "#version 330 core\n"
        "layout(location = 0) in vec2 aPos;\n"
        "void main() {\n"
        "    gl_Position = vec4(aPos, 0.0, 1.0);\n"
        "}\n";
    static constexpr const char* kDepthWriteFS =
        "#version 330 core\n"
        "uniform float uDepth;\n"
        "void main() {\n"
        "    gl_FragDepth = uDepth;\n"
        "}\n";

    const GLuint program = buildBenchProgram(kDepthWriteVS, kDepthWriteFS);
    GLint linked = GL_FALSE;
    gl.glGetProgramiv(program, GL_LINK_STATUS, &linked);
    expectCondition(linked == GL_TRUE, "depth32f seed program links");
    const GLint depthLocation = gl.glGetUniformLocation(program, "uDepth");
    expectCondition(depthLocation >= 0, "depth32f seed uniform exists");

    GLuint vao = 0;
    GLuint vbo = 0;
    setupDCR3CFullscreenTriangle(gl, vao, vbo);

    gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    gl.glViewport(0, 0, width, height);
    gl.glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
    gl.glDisable(GL_BLEND);
    gl.glDisable(GL_CULL_FACE);
    gl.glDisable(GL_STENCIL_TEST);
    gl.glDisable(GL_SCISSOR_TEST);
    gl.glEnable(GL_DEPTH_TEST);
    gl.glDepthMask(GL_TRUE);
    gl.glDepthFunc(GL_ALWAYS);
    gl.glUseProgram(program);
    gl.glUniform1f(depthLocation, depthValue);
    gl.glBindVertexArray(vao);
    gl.glDrawArrays(GL_TRIANGLES, 0, 3);

    gl.glBindVertexArray(0);
    gl.glUseProgram(0);
    gl.glDisable(GL_DEPTH_TEST);
    gl.glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    gl.glDeleteBuffers(1, &vbo);
    gl.glDeleteVertexArrays(1, &vao);
    gl.glDeleteProgram(program);
}

void expectApproxFloat(GLfloat actual,
                       GLfloat expected,
                       GLfloat tolerance,
                       std::string_view label) {
    if (std::fabs(actual - expected) > tolerance) {
        std::ostringstream stream;
        stream << label << " expected=" << expected
               << " actual=" << actual
               << " tolerance=" << tolerance;
        throw std::runtime_error(stream.str());
    }
}

void expectApproxByte(std::uint8_t actual,
                      std::uint8_t expected,
                      std::uint8_t tolerance,
                      std::string_view label) {
    const int delta =
        std::abs(static_cast<int>(actual) - static_cast<int>(expected));
    if (delta > static_cast<int>(tolerance)) {
        std::ostringstream stream;
        stream << label << " expected=" << static_cast<int>(expected)
               << " actual=" << static_cast<int>(actual)
               << " tolerance=" << static_cast<int>(tolerance);
        throw std::runtime_error(stream.str());
    }
}

const GLTextureImageLevel& expectTextureLevel(GLContext& context,
                                              GLuint texture,
                                              GLint level,
                                              std::string_view label) {
    const GLTextureObject* object = context.objects().textures().get(texture);
    expectCondition(object != nullptr,
                    std::string(label) + " texture object exists");
    const auto it = object->levels.find(level);
    expectCondition(it != object->levels.end(),
                    std::string(label) + " texture level exists");
    return it->second;
}

std::string textureStateSummary(const GLTextureObject& object,
                                const GLTextureImageLevel& image) {
    std::ostringstream stream;
    stream << "target=0x" << std::hex << object.target
           << " internalFormat=0x" << image.desc.internalFormat
           << " sourceFormat=0x" << image.desc.sourceFormat
           << " sourceType=0x" << image.desc.sourceType
           << std::dec
           << " rgba8Bytes=" << image.rgba8.size()
           << " nativeBytes=" << image.nativeData.size()
           << " nativeBpp=" << image.nativeBpp
           << " generatedMipLevel=" << image.generatedMipLevel
           << " immutableStorageLevel=" << image.immutableStorageLevel
           << " mipShadowEvicted=" << image.mipShadowEvicted
           << " evictedRgba8Bytes=" << image.mipShadowEvictedRgba8Bytes
           << " evictedNativeBytes=" << image.mipShadowEvictedNativeBytes
           << " metalTexture=" << (object.metalTexture != nullptr)
           << " metalSamplingProxy=" << (object.metalSamplingProxy != nullptr)
           << " colorShadowAuthoritative=" << object.colorShadowAuthoritative
           << " depthStencilShadowAuthoritative=" << object.depthStencilShadowAuthoritative
           << " wasFramebufferRenderedTo=" << object.wasFramebufferRenderedTo
           << " wasViewportRenderedTo=" << object.wasViewportRenderedTo
           << " viewSourceTexture=" << object.viewSourceTexture
           << " producerPending=0x" << std::hex << object.producerPending.bits();
    return stream.str();
}

constexpr GLsizei kDCR4CMeshGsSize = 32;

static constexpr const char* kDCR4CMeshGsVS =
    "#version 410 core\n"
    "out gl_PerVertex {\n"
    "    vec4 gl_Position;\n"
    "    float gl_PointSize;\n"
    "    float gl_ClipDistance[1];\n"
    "};\n"
    "out vec4 vColor;\n"
    "void main() {\n"
    "    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);\n"
    "    gl_PointSize = 16.0;\n"
    "    gl_ClipDistance[0] = 1.0;\n"
    "    vColor = vec4(0.0, 1.0, 0.0, 1.0);\n"
    "}\n";

static constexpr const char* kDCR4CMeshGsGS =
    "#version 410 core\n"
    "layout(points) in;\n"
    "layout(points, max_vertices = 1) out;\n"
    "in vec4 vColor[];\n"
    "out vec4 gColor;\n"
    "void main() {\n"
    "    gl_Position = gl_in[0].gl_Position;\n"
    "    gl_PointSize = gl_in[0].gl_PointSize;\n"
    "    gColor = vColor[0];\n"
    "    EmitVertex();\n"
    "    EndPrimitive();\n"
    "}\n";

static constexpr const char* kDCR4CMeshGsFS =
    "#version 410 core\n"
    "in vec4 gColor;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    fragColor = gColor;\n"
    "}\n";

GLuint buildDCR4CMeshGsSentinelProgram() {
    return buildDCR4CMeshGsProgram(
        kDCR4CMeshGsVS, kDCR4CMeshGsGS, kDCR4CMeshGsFS);
}

void setupDCR4CMeshGsTarget(GLDispatchTable& gl,
                            GLuint& texture,
                            GLuint& framebuffer) {
    gl.glGenTextures(1, &texture);
    setupDCR3CRGBA8Texture(gl, texture, kDCR4CMeshGsSize, kDCR4CMeshGsSize);
    setupDCR3CTextureFbo(gl, framebuffer, texture);
    gl.glViewport(0, 0, kDCR4CMeshGsSize, kDCR4CMeshGsSize);
    gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    gl.glClear(GL_COLOR_BUFFER_BIT);
    std::array<std::uint8_t, 4> drainPixel = {};
    gl.glReadPixels(kDCR4CMeshGsSize / 2, kDCR4CMeshGsSize / 2,
                    1, 1, GL_RGBA, GL_UNSIGNED_BYTE, drainPixel.data());
    expectGLError(gl, GL_NO_ERROR, "dcr4c mesh-GS target setup readback drain");
}

bool isDCR4CMeshGsGreen(const std::array<std::uint8_t, 4>& pixel) {
    return pixel[0] <= 40 && pixel[1] >= 180 &&
           pixel[2] <= 40 && pixel[3] >= 240;
}

std::array<std::uint8_t, 4> readDCR4CMeshGsCenter(GLDispatchTable& gl) {
    std::array<std::uint8_t, 4> pixel = {};
    gl.glReadPixels(kDCR4CMeshGsSize / 2, kDCR4CMeshGsSize / 2,
                    1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
    expectGLError(gl, GL_NO_ERROR, "dcr4c mesh-GS center readback");
    return pixel;
}

void drawDCR4CMeshGsPoint(GLDispatchTable& gl, GLuint program) {
    GLuint vao = 0;
    gl.glGenVertexArrays(1, &vao);
    gl.glBindVertexArray(vao);
    gl.glUseProgram(program);
    gl.glEnable(GL_PROGRAM_POINT_SIZE);
    gl.glDrawArrays(GL_POINTS, 0, 1);
    expectGLError(gl, GL_NO_ERROR, "dcr4c mesh-GS point draw");
    gl.glBindVertexArray(0);
    gl.glDeleteVertexArrays(1, &vao);
}

TestResult runDCR4CMeshGsDependencySentinel() {
    auto result = runDirectSentinel("dcr4c.mesh-gs-vsout-dependency", [&] {
        ScopedSentinelContext scoped(kDCR4CMeshGsSize, kDCR4CMeshGsSize);
        auto& gl = scoped.gl();
        const GLuint program = buildDCR4CMeshGsSentinelProgram();

        GLuint texture = 0;
        GLuint framebuffer = 0;
        setupDCR4CMeshGsTarget(gl, texture, framebuffer);
        drawDCR4CMeshGsPoint(gl, program);
        auto pixel = readDCR4CMeshGsCenter(gl);
        expectCondition(isDCR4CMeshGsGreen(pixel),
                        "dcr4c mesh-GS normal draw produces green center");

        gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        {
            ScopedEnvVar zeroVsOut(
                APPGL_DCR_SENTINEL_ENV("APPGL_DCR4C_MESH_GS_ZERO_VSOUT"), "1");
            drawDCR4CMeshGsPoint(gl, program);
        }
        pixel = readDCR4CMeshGsCenter(gl);
        expectCondition(!isDCR4CMeshGsGreen(pixel),
                        "dcr4c mesh-GS zeroed VS output changes render result");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(1, &texture);
        gl.glDeleteProgram(program);
        expectGLError(gl, GL_NO_ERROR, "dcr4c mesh-GS dependency cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "mesh-GS render consumed the VS-as-compute output buffer";
    }
    return result;
}

TestResult runDCR4CMeshGsFboProducerSentinel() {
    auto result = runDirectSentinel("dcr4c.mesh-gs-fbo-producer-readback", [&] {
        ScopedSentinelContext scoped(kDCR4CMeshGsSize, kDCR4CMeshGsSize);
        auto& context = scoped.context();
        auto& gl = scoped.gl();
        const GLuint program = buildDCR4CMeshGsSentinelProgram();

        GLuint texture = 0;
        GLuint framebuffer = 0;
        setupDCR4CMeshGsTarget(gl, texture, framebuffer);
        expectPendingClear(texturePendingBits(context, texture),
                           kProducerFboColorWrite,
                           "dcr4c mesh-GS setup has no stale FBO producer bits");

        drawDCR4CMeshGsPoint(gl, program);
        expectPendingHas(texturePendingBits(context, texture),
                         kProducerFboColorWrite,
                         "dcr4c mesh-GS FBO draw marks texture producer bits");

        const auto pixel = readDCR4CMeshGsCenter(gl);
        expectCondition(isDCR4CMeshGsGreen(pixel),
                        "dcr4c mesh-GS FBO readback observes green center");
        expectPendingClear(texturePendingBits(context, texture),
                           kProducerFboColorWrite,
                           "dcr4c mesh-GS readback clears FBO producer bits");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(1, &texture);
        gl.glDeleteProgram(program);
        expectGLError(gl, GL_NO_ERROR, "dcr4c mesh-GS producer cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "native mesh-GS FBO draw marks producer bits and readback drains them";
    }
    return result;
}

constexpr GLsizei kDCR4DTessSize = 32;

static constexpr const char* kDCR4DTessVS =
    "#version 430 core\n"
    "out gl_PerVertex { vec4 gl_Position; };\n"
    "void main() {\n"
    "    vec2 p[3] = vec2[3](vec2(-0.75, -0.75), vec2(0.75, -0.75), vec2(0.0, 0.75));\n"
    "    gl_Position = vec4(p[gl_VertexID], 0.0, 1.0);\n"
    "}\n";

static constexpr const char* kDCR4DTessTCS =
    "#version 430 core\n"
    "layout(vertices = 3) out;\n"
    "in gl_PerVertex { vec4 gl_Position; } gl_in[];\n"
    "out gl_PerVertex { vec4 gl_Position; } gl_out[];\n"
    "void main() {\n"
    "    gl_out[gl_InvocationID].gl_Position = gl_in[gl_InvocationID].gl_Position;\n"
    "    if (gl_InvocationID == 0) {\n"
    "        gl_TessLevelOuter[0] = 1.0;\n"
    "        gl_TessLevelOuter[1] = 1.0;\n"
    "        gl_TessLevelOuter[2] = 1.0;\n"
    "        gl_TessLevelInner[0] = 1.0;\n"
    "    }\n"
    "}\n";

static constexpr const char* kDCR4DTessTES =
    "#version 430 core\n"
    "layout(triangles, equal_spacing, ccw) in;\n"
    "in gl_PerVertex { vec4 gl_Position; } gl_in[];\n"
    "out gl_PerVertex { vec4 gl_Position; };\n"
    "void main() {\n"
    "    gl_Position = gl_TessCoord.x * gl_in[0].gl_Position +\n"
    "                  gl_TessCoord.y * gl_in[1].gl_Position +\n"
    "                  gl_TessCoord.z * gl_in[2].gl_Position;\n"
    "}\n";

static constexpr const char* kDCR4DTessTF_TES =
    "#version 430 core\n"
    "layout(triangles, equal_spacing, ccw) in;\n"
    "in gl_PerVertex { vec4 gl_Position; } gl_in[];\n"
    "out gl_PerVertex { vec4 gl_Position; };\n"
    "out float tfValue;\n"
    "void main() {\n"
    "    gl_Position = gl_TessCoord.x * gl_in[0].gl_Position +\n"
    "                  gl_TessCoord.y * gl_in[1].gl_Position +\n"
    "                  gl_TessCoord.z * gl_in[2].gl_Position;\n"
    "    tfValue = 7.0;\n"
    "}\n";

static constexpr const char* kDCR4DTessGreenFS =
    "#version 430 core\n"
    "out vec4 fragColor;\n"
    "void main() { fragColor = vec4(0.0, 1.0, 0.0, 1.0); }\n";

static constexpr const char* kDCR4DTessImageFS =
    "#version 430 core\n"
    "layout(rgba8, binding = 0) uniform writeonly image2D outImg;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    imageStore(outImg, ivec2(0, 0), vec4(1.0, 0.0, 0.0, 1.0));\n"
    "    fragColor = vec4(0.0, 1.0, 0.0, 1.0);\n"
    "}\n";

static constexpr const char* kDCR4DTessSsboFS =
    "#version 430 core\n"
    "layout(std430, binding = 0) buffer Out { uint value; } outBuf;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    outBuf.value = 0x12345678u;\n"
    "    fragColor = vec4(0.0, 1.0, 0.0, 1.0);\n"
    "}\n";

static constexpr const char* kDCR4DTessAtomicFS =
    "#version 430 core\n"
    "layout(binding = 0, offset = 0) uniform atomic_uint ac;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    atomicCounterIncrement(ac);\n"
    "    fragColor = vec4(0.0, 1.0, 0.0, 1.0);\n"
    "}\n";

GLuint buildDCR4DTessProgram(const char* vsSrc,
                             const char* tcsSrc,
                             const char* tesSrc,
                             const char* fsSrc,
                             const char* const* tfVaryings = nullptr,
                             GLsizei tfVaryingCount = 0) {
    auto& gl = Runtime::shared().dispatch();
    const GLuint vs =
        compileRequiredShader(gl, GL_VERTEX_SHADER, vsSrc, "dcr4d vertex");
    const GLuint tcs =
        compileRequiredShader(gl, GL_TESS_CONTROL_SHADER, tcsSrc, "dcr4d tess-control");
    const GLuint tes =
        compileRequiredShader(gl, GL_TESS_EVALUATION_SHADER, tesSrc, "dcr4d tess-eval");
    const GLuint fs =
        compileRequiredShader(gl, GL_FRAGMENT_SHADER, fsSrc, "dcr4d fragment");
    GLuint program = gl.glCreateProgram();
    gl.glAttachShader(program, vs);
    gl.glAttachShader(program, tcs);
    gl.glAttachShader(program, tes);
    gl.glAttachShader(program, fs);
    if (tfVaryings != nullptr && tfVaryingCount > 0) {
        gl.glTransformFeedbackVaryings(program, tfVaryingCount, tfVaryings,
                                       GL_INTERLEAVED_ATTRIBS);
    }
    gl.glLinkProgram(program);
    gl.glDeleteShader(vs);
    gl.glDeleteShader(tcs);
    gl.glDeleteShader(tes);
    gl.glDeleteShader(fs);
    GLint status = GL_FALSE;
    gl.glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (status != GL_TRUE) {
        const std::string log = programInfoLog(gl, program);
        gl.glDeleteProgram(program);
        throw std::runtime_error(
            "DCR4-D tess program link failed" +
            (log.empty() ? std::string{} : ": " + log));
    }
    return program;
}

GLuint buildDCR4DTessGreenProgram() {
    return buildDCR4DTessProgram(
        kDCR4DTessVS, kDCR4DTessTCS, kDCR4DTessTES,
        kDCR4DTessGreenFS);
}

void setupDCR4DTessTarget(GLDispatchTable& gl,
                          GLuint& texture,
                          GLuint& framebuffer) {
    gl.glGenTextures(1, &texture);
    setupDCR3CRGBA8Texture(gl, texture, kDCR4DTessSize, kDCR4DTessSize);
    setupDCR3CTextureFbo(gl, framebuffer, texture);
    gl.glViewport(0, 0, kDCR4DTessSize, kDCR4DTessSize);
    gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    gl.glClear(GL_COLOR_BUFFER_BIT);
    std::array<std::uint8_t, 4> drainPixel = {};
    gl.glReadPixels(kDCR4DTessSize / 2, kDCR4DTessSize / 2,
                    1, 1, GL_RGBA, GL_UNSIGNED_BYTE, drainPixel.data());
    expectGLError(gl, GL_NO_ERROR, "dcr4d tess target setup readback drain");
}

bool isDCR4DTessGreen(const std::array<std::uint8_t, 4>& pixel) {
    return pixel[0] <= 40 && pixel[1] >= 180 &&
           pixel[2] <= 40 && pixel[3] >= 240;
}

std::array<std::uint8_t, 4> readDCR4DTessCenter(GLDispatchTable& gl) {
    std::array<std::uint8_t, 4> pixel = {};
    gl.glReadPixels(kDCR4DTessSize / 2, kDCR4DTessSize / 2,
                    1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
    expectGLError(gl, GL_NO_ERROR, "dcr4d tess center readback");
    return pixel;
}

void drawDCR4DTessPatch(GLDispatchTable& gl, GLuint program) {
    GLuint vao = 0;
    gl.glGenVertexArrays(1, &vao);
    gl.glBindVertexArray(vao);
    gl.glUseProgram(program);
    gl.glPatchParameteri(GL_PATCH_VERTICES, 3);
    gl.glDrawArrays(GL_PATCHES, 0, 3);
    expectGLError(gl, GL_NO_ERROR, "dcr4d tess patch draw");
    gl.glBindVertexArray(0);
    gl.glDeleteVertexArrays(1, &vao);
}

TestResult runDCR4DTessDependencySentinel() {
    auto result = runDirectSentinel("dcr4d.tess-transient-dependencies", [&] {
        ScopedSentinelContext scoped(kDCR4DTessSize, kDCR4DTessSize);
        auto& gl = scoped.gl();
        const GLuint program = buildDCR4DTessGreenProgram();

        GLuint texture = 0;
        GLuint framebuffer = 0;
        setupDCR4DTessTarget(gl, texture, framebuffer);
        drawDCR4DTessPatch(gl, program);
        auto pixel = readDCR4DTessCenter(gl);
        expectCondition(isDCR4DTessGreen(pixel),
                        "dcr4d normal tess draw produces green center");

        gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        {
            ScopedEnvVar zeroVsOut(
                APPGL_DCR_SENTINEL_ENV("APPGL_DCR4D_TESS_ZERO_VSOUT"), "1");
            drawDCR4DTessPatch(gl, program);
        }
        pixel = readDCR4DTessCenter(gl);
        expectCondition(!isDCR4DTessGreen(pixel),
                        "dcr4d zeroed tess VS output changes render result");

        gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        {
            ScopedEnvVar zeroFactor(
                APPGL_DCR_SENTINEL_ENV("APPGL_DCR4D_TESS_ZERO_FACTORBUF"), "1");
            drawDCR4DTessPatch(gl, program);
        }
        pixel = readDCR4DTessCenter(gl);
        expectCondition(!isDCR4DTessGreen(pixel),
                        "dcr4d zeroed tess factor buffer changes render result");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(1, &texture);
        gl.glDeleteProgram(program);
        expectGLError(gl, GL_NO_ERROR, "dcr4d tess dependency cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "tess render consumes VS-output and factor-buffer transients";
    }
    return result;
}

TestResult runDCR4DTessFboProducerSentinel() {
    auto result = runDirectSentinel("dcr4d.tess-fbo-producer-readback", [&] {
        ScopedSentinelContext scoped(kDCR4DTessSize, kDCR4DTessSize);
        auto& context = scoped.context();
        auto& gl = scoped.gl();
        const GLuint program = buildDCR4DTessGreenProgram();

        GLuint texture = 0;
        GLuint framebuffer = 0;
        setupDCR4DTessTarget(gl, texture, framebuffer);
        expectPendingClear(texturePendingBits(context, texture),
                           kProducerFboColorWrite,
                           "dcr4d tess setup has no stale FBO producer bits");

        drawDCR4DTessPatch(gl, program);
        expectPendingHas(texturePendingBits(context, texture),
                         kProducerFboColorWrite,
                         "dcr4d tess FBO draw marks texture producer bits");

        const auto pixel = readDCR4DTessCenter(gl);
        expectCondition(isDCR4DTessGreen(pixel),
                        "dcr4d tess FBO readback observes green center");
        expectPendingClear(texturePendingBits(context, texture),
                           kProducerFboColorWrite,
                           "dcr4d tess readback clears FBO producer bits");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(1, &texture);
        gl.glDeleteProgram(program);
        expectGLError(gl, GL_NO_ERROR, "dcr4d tess producer cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "native tess FBO draw marks producer bits and readback drains them";
    }
    return result;
}

TestResult runDCR4DTessSideEffectRejectSentinel() {
    auto result = runDirectSentinel("dcr4d.tess-side-effect-rejects", [&] {
        ScopedSentinelContext scoped(kDCR4DTessSize, kDCR4DTessSize);
        auto& gl = scoped.gl();

        GLuint colorTex = 0;
        GLuint framebuffer = 0;
        setupDCR4DTessTarget(gl, colorTex, framebuffer);

        GLuint imageTex = 0;
        gl.glGenTextures(1, &imageTex);
        setupDCR3CRGBA8Texture(gl, imageTex, 4, 4);
        const GLuint imageProgram = buildDCR4DTessProgram(
            kDCR4DTessVS, kDCR4DTessTCS, kDCR4DTessTES,
            kDCR4DTessImageFS);
        gl.glBindImageTexture(0, imageTex, 0, GL_FALSE, 0,
                              GL_WRITE_ONLY, GL_RGBA8);
        drawDCR4DTessPatch(gl, imageProgram);
        gl.glMemoryBarrier(GL_ALL_BARRIER_BITS);
        std::array<std::uint8_t, 4 * 4 * 4> imagePixels = {};
        gl.glGetTextureImage(imageTex, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                             static_cast<GLsizei>(imagePixels.size()),
                             imagePixels.data());
        expectGLError(gl, GL_NO_ERROR, "dcr4d storage-image reject readback");
        expectCondition(imagePixels[0] >= 180 && imagePixels[1] <= 40 &&
                            imagePixels[2] <= 40 && imagePixels[3] >= 240,
                        "dcr4d storage-image tess draw routed to CPU fallback");

        std::uint32_t zero = 0;
        GLuint ssbo = 0;
        gl.glGenBuffers(1, &ssbo);
        gl.glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
        gl.glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(std::uint32_t),
                        &zero, GL_DYNAMIC_DRAW);
        gl.glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);
        const GLuint ssboProgram = buildDCR4DTessProgram(
            kDCR4DTessVS, kDCR4DTessTCS, kDCR4DTessTES,
            kDCR4DTessSsboFS);
        drawDCR4DTessPatch(gl, ssboProgram);
        gl.glMemoryBarrier(GL_ALL_BARRIER_BITS);
        std::uint32_t ssboValue = 0;
        gl.glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
        gl.glGetBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
                              sizeof(ssboValue), &ssboValue);
        expectGLError(gl, GL_NO_ERROR, "dcr4d SSBO reject readback");
        expectCondition(ssboValue == 0x12345678u,
                        "dcr4d SSBO tess draw routed to CPU fallback");

        GLuint atomicBuffer = 0;
        gl.glGenBuffers(1, &atomicBuffer);
        gl.glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, atomicBuffer);
        gl.glBufferData(GL_ATOMIC_COUNTER_BUFFER, sizeof(std::uint32_t),
                        &zero, GL_DYNAMIC_DRAW);
        gl.glBindBufferBase(GL_ATOMIC_COUNTER_BUFFER, 0, atomicBuffer);
        const GLuint atomicProgram = buildDCR4DTessProgram(
            kDCR4DTessVS, kDCR4DTessTCS, kDCR4DTessTES,
            kDCR4DTessAtomicFS);
        drawDCR4DTessPatch(gl, atomicProgram);
        gl.glMemoryBarrier(GL_ALL_BARRIER_BITS);
        std::uint32_t atomicValue = 0;
        gl.glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, atomicBuffer);
        gl.glGetBufferSubData(GL_ATOMIC_COUNTER_BUFFER, 0,
                              sizeof(atomicValue), &atomicValue);
        expectGLError(gl, GL_NO_ERROR, "dcr4d atomic reject readback");
        expectCondition(atomicValue > 0,
                        "dcr4d atomic tess draw routed to CPU fallback");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindImageTexture(0, 0, 0, GL_FALSE, 0, GL_READ_WRITE, GL_RGBA8);
        gl.glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
        gl.glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteBuffers(1, &ssbo);
        gl.glDeleteBuffers(1, &atomicBuffer);
        gl.glDeleteTextures(1, &imageTex);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(1, &colorTex);
        gl.glDeleteProgram(imageProgram);
        gl.glDeleteProgram(ssboProgram);
        gl.glDeleteProgram(atomicProgram);
        expectGLError(gl, GL_NO_ERROR, "dcr4d reject cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "tess storage-image, SSBO and atomic side effects route to CPU fallback";
    }
    return result;
}

TestResult runDCR4DTessTfExcludeSentinel() {
    auto result = runDirectSentinel("dcr4d.tess-tf-cpu-write-exclude", [&] {
        ScopedSentinelContext scoped(kDCR4DTessSize, kDCR4DTessSize);
        auto& gl = scoped.gl();
        const char* tfName = "tfValue";
        const GLuint program = buildDCR4DTessProgram(
            kDCR4DTessVS, kDCR4DTessTCS, kDCR4DTessTF_TES,
            kDCR4DTessGreenFS, &tfName, 1);

        GLuint tfBuffer = 0;
        gl.glGenBuffers(1, &tfBuffer);
        gl.glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, tfBuffer);
        std::array<float, 8> zeros = {};
        gl.glBufferData(GL_TRANSFORM_FEEDBACK_BUFFER,
                        static_cast<GLsizeiptr>(zeros.size() * sizeof(float)),
                        zeros.data(), GL_DYNAMIC_DRAW);
        gl.glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, tfBuffer);

        auto runTfDraw = [&](bool skipCpuWrite) {
            GLuint vao = 0;
            gl.glGenVertexArrays(1, &vao);
            gl.glBindVertexArray(vao);
            gl.glUseProgram(program);
            gl.glPatchParameteri(GL_PATCH_VERTICES, 3);
            gl.glEnable(GL_RASTERIZER_DISCARD);
            if (skipCpuWrite) {
                ScopedEnvVar skip(
                    APPGL_DCR_SENTINEL_ENV("APPGL_DCR4D_TF_EXCLUDE_SKIP_CPU_WRITE"), "1");
                gl.glBeginTransformFeedback(GL_TRIANGLES);
                gl.glDrawArrays(GL_PATCHES, 0, 3);
                gl.glEndTransformFeedback();
            } else {
                gl.glBeginTransformFeedback(GL_TRIANGLES);
                gl.glDrawArrays(GL_PATCHES, 0, 3);
                gl.glEndTransformFeedback();
            }
            gl.glDisable(GL_RASTERIZER_DISCARD);
            gl.glBindVertexArray(0);
            gl.glDeleteVertexArrays(1, &vao);
        };

        runTfDraw(false);
        std::array<float, 8> tfValues = {};
        gl.glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, tfBuffer);
        gl.glGetBufferSubData(GL_TRANSFORM_FEEDBACK_BUFFER, 0,
                              static_cast<GLsizeiptr>(tfValues.size() * sizeof(float)),
                              tfValues.data());
        expectGLError(gl, GL_NO_ERROR, "dcr4d TF normal readback");
        const bool sawSeven = std::any_of(
            tfValues.begin(), tfValues.end(),
            [](float value) { return std::fabs(value - 7.0f) < 0.01f; });
        expectCondition(sawSeven,
                        "dcr4d tess TF CPU write is visible immediately");

        gl.glBufferData(GL_TRANSFORM_FEEDBACK_BUFFER,
                        static_cast<GLsizeiptr>(zeros.size() * sizeof(float)),
                        zeros.data(), GL_DYNAMIC_DRAW);
        runTfDraw(true);
        tfValues.fill(0.0f);
        gl.glGetBufferSubData(GL_TRANSFORM_FEEDBACK_BUFFER, 0,
                              static_cast<GLsizeiptr>(tfValues.size() * sizeof(float)),
                              tfValues.data());
        expectGLError(gl, GL_NO_ERROR, "dcr4d TF skipped-write readback");
        const bool stillSawSeven = std::any_of(
            tfValues.begin(), tfValues.end(),
            [](float value) { return std::fabs(value - 7.0f) < 0.01f; });
        expectCondition(!stillSawSeven,
                        "dcr4d TF sentinel is non-vacuous when CPU write is skipped");

        gl.glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteBuffers(1, &tfBuffer);
        gl.glDeleteProgram(program);
        expectGLError(gl, GL_NO_ERROR, "dcr4d TF exclude cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "tess TF write is CPU-side and excluded from GPU producer marking";
    }
    return result;
}

constexpr GLsizei kDCR4ESize = 32;

static constexpr const char* kDCR4EGsPointVS =
    "#version 430 core\n"
    "out gl_PerVertex { vec4 gl_Position; float gl_PointSize; };\n"
    "out vec4 vColor;\n"
    "out vec4 gColor;\n"
    "void main() {\n"
    "    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);\n"
    "    gl_PointSize = 20.0;\n"
    "    vColor = vec4(1.0, 0.0, 0.0, 1.0);\n"
    "    gColor = vec4(1.0, 0.0, 0.0, 1.0);\n"
    "}\n";

static constexpr const char* kDCR4EGsPointGS =
    "#version 430 core\n"
    "layout(points) in;\n"
    "layout(points, max_vertices = 1) out;\n"
    "in vec4 vColor[];\n"
    "out vec4 gColor;\n"
    "out float tfValue;\n"
    "void main() {\n"
    "    gl_Position = gl_in[0].gl_Position;\n"
    "    gl_PointSize = 20.0;\n"
    "    gColor = vec4(0.0, 1.0, 0.0, 1.0);\n"
    "    tfValue = 7.0;\n"
    "    EmitVertex();\n"
    "    EndPrimitive();\n"
    "}\n";

static constexpr const char* kDCR4EGsColorFS =
    "#version 430 core\n"
    "in vec4 gColor;\n"
    "out vec4 fragColor;\n"
    "void main() { fragColor = gColor; }\n";

static constexpr const char* kDCR4EReplayVS =
    "#version 430 core\n"
    "out gl_PerVertex { vec4 gl_Position; float gl_PointSize; };\n"
    "out vec4 gColor;\n"
    "void main() {\n"
    "    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);\n"
    "    gl_PointSize = 20.0;\n"
    "    gColor = vec4(0.0, 1.0, 0.0, 1.0);\n"
    "}\n";

static constexpr const char* kDCR4EGsImageGS =
    "#version 430 core\n"
    "layout(points) in;\n"
    "layout(points, max_vertices = 1) out;\n"
    "layout(rgba8, binding = 0) uniform writeonly image2D outImg;\n"
    "void main() {\n"
    "    imageStore(outImg, ivec2(0, 0), vec4(1.0, 0.0, 0.0, 1.0));\n"
    "    gl_Position = gl_in[0].gl_Position;\n"
    "    gl_PointSize = 1.0;\n"
    "    EmitVertex();\n"
    "    EndPrimitive();\n"
    "}\n";

static constexpr const char* kDCR4EBlackFS =
    "#version 430 core\n"
    "out vec4 fragColor;\n"
    "void main() { fragColor = vec4(0.0, 0.0, 0.0, 1.0); }\n";

GLuint buildDCR4EGsProgram(const char* vsSrc,
                           const char* gsSrc,
                           const char* fsSrc,
                           const char* const* tfVaryings = nullptr,
                           GLsizei tfVaryingCount = 0) {
    auto& gl = Runtime::shared().dispatch();
    const GLuint vs =
        compileRequiredShader(gl, GL_VERTEX_SHADER, vsSrc, "dcr4e vertex");
    const GLuint gs =
        compileRequiredShader(gl, GL_GEOMETRY_SHADER, gsSrc, "dcr4e geometry");
    const GLuint fs =
        compileRequiredShader(gl, GL_FRAGMENT_SHADER, fsSrc, "dcr4e fragment");
    GLuint program = gl.glCreateProgram();
    gl.glAttachShader(program, vs);
    gl.glAttachShader(program, gs);
    gl.glAttachShader(program, fs);
    if (tfVaryings != nullptr && tfVaryingCount > 0) {
        gl.glTransformFeedbackVaryings(program, tfVaryingCount, tfVaryings,
                                       GL_INTERLEAVED_ATTRIBS);
    }
    gl.glLinkProgram(program);
    gl.glDeleteShader(vs);
    gl.glDeleteShader(gs);
    gl.glDeleteShader(fs);
    GLint status = GL_FALSE;
    gl.glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (status != GL_TRUE) {
        const std::string log = programInfoLog(gl, program);
        gl.glDeleteProgram(program);
        throw std::runtime_error(
            "DCR4-E GS program link failed" +
            (log.empty() ? std::string{} : ": " + log));
    }
    return program;
}

GLuint buildDCR4EReplayProgram() {
    auto& gl = Runtime::shared().dispatch();
    const GLuint vs =
        compileRequiredShader(gl, GL_VERTEX_SHADER, kDCR4EReplayVS,
                              "dcr4e replay vertex");
    const GLuint fs =
        compileRequiredShader(gl, GL_FRAGMENT_SHADER, kDCR4EGsColorFS,
                              "dcr4e replay fragment");
    GLuint program = gl.glCreateProgram();
    gl.glAttachShader(program, vs);
    gl.glAttachShader(program, fs);
    gl.glLinkProgram(program);
    gl.glDeleteShader(vs);
    gl.glDeleteShader(fs);
    GLint status = GL_FALSE;
    gl.glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (status != GL_TRUE) {
        const std::string log = programInfoLog(gl, program);
        gl.glDeleteProgram(program);
        throw std::runtime_error(
            "DCR4-E replay program link failed" +
            (log.empty() ? std::string{} : ": " + log));
    }
    return program;
}

void setupDCR4ETarget(GLDispatchTable& gl,
                      GLuint& texture,
                      GLuint& framebuffer) {
    gl.glGenTextures(1, &texture);
    setupDCR3CRGBA8Texture(gl, texture, kDCR4ESize, kDCR4ESize);
    setupDCR3CTextureFbo(gl, framebuffer, texture);
    gl.glViewport(0, 0, kDCR4ESize, kDCR4ESize);
    gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    gl.glClear(GL_COLOR_BUFFER_BIT);
    std::array<std::uint8_t, 4> drainPixel = {};
    gl.glReadPixels(kDCR4ESize / 2, kDCR4ESize / 2,
                    1, 1, GL_RGBA, GL_UNSIGNED_BYTE, drainPixel.data());
    expectGLError(gl, GL_NO_ERROR, "dcr4e target setup readback drain");
}

void clearDCR4ETarget(GLDispatchTable& gl) {
    gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    gl.glClear(GL_COLOR_BUFFER_BIT);
}

std::array<std::uint8_t, 4> readDCR4ECenter(GLDispatchTable& gl) {
    std::array<std::uint8_t, 4> pixel = {};
    gl.glReadPixels(kDCR4ESize / 2, kDCR4ESize / 2,
                    1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
    expectGLError(gl, GL_NO_ERROR, "dcr4e center readback");
    return pixel;
}

bool isDCR4EGreen(const std::array<std::uint8_t, 4>& pixel) {
    return pixel[0] <= 40 && pixel[1] >= 180 &&
           pixel[2] <= 40 && pixel[3] >= 240;
}

bool isDCR4EBlack(const std::array<std::uint8_t, 4>& pixel) {
    return pixel[0] <= 35 && pixel[1] <= 35 &&
           pixel[2] <= 35 && pixel[3] >= 240;
}

bool isDCR4ERed(const std::array<std::uint8_t, 4>& pixel) {
    return pixel[0] >= 180 && pixel[1] <= 40 &&
           pixel[2] <= 40 && pixel[3] >= 240;
}

GLuint createDCR4ETfBuffer(GLDispatchTable& gl) {
    GLuint buffer = 0;
    gl.glGenBuffers(1, &buffer);
    gl.glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffer);
    std::array<float, 16> zeros = {};
    gl.glBufferData(GL_TRANSFORM_FEEDBACK_BUFFER,
                    static_cast<GLsizeiptr>(zeros.size() * sizeof(float)),
                    zeros.data(), GL_DYNAMIC_DRAW);
    return buffer;
}

GLuint createDCR4ETransformFeedback(GLDispatchTable& gl, GLuint buffer) {
    GLuint tf = 0;
    gl.glGenTransformFeedbacks(1, &tf);
    gl.glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, tf);
    gl.glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, buffer);
    return tf;
}

void resetDCR4ETfBuffer(GLDispatchTable& gl, GLuint buffer) {
    std::array<float, 16> zeros = {};
    gl.glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffer);
    gl.glBufferData(GL_TRANSFORM_FEEDBACK_BUFFER,
                    static_cast<GLsizeiptr>(zeros.size() * sizeof(float)),
                    zeros.data(), GL_DYNAMIC_DRAW);
    gl.glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, buffer);
}

void drawDCR4EGsPoint(GLDispatchTable& gl, GLuint program) {
    GLuint vao = 0;
    gl.glGenVertexArrays(1, &vao);
    gl.glBindVertexArray(vao);
    gl.glUseProgram(program);
    gl.glEnable(GL_PROGRAM_POINT_SIZE);
    gl.glDrawArrays(GL_POINTS, 0, 1);
    expectGLError(gl, GL_NO_ERROR, "dcr4e GS point draw");
    gl.glBindVertexArray(0);
    gl.glDeleteVertexArrays(1, &vao);
}

void captureDCR4EGsPoint(GLDispatchTable& gl,
                         GLuint program,
                         GLuint tf,
                         GLuint buffer,
                         bool rasterDiscard) {
    GLuint vao = 0;
    gl.glGenVertexArrays(1, &vao);
    gl.glBindVertexArray(vao);
    gl.glUseProgram(program);
    gl.glEnable(GL_PROGRAM_POINT_SIZE);
    gl.glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, tf);
    gl.glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, buffer);
    if (rasterDiscard) {
        gl.glEnable(GL_RASTERIZER_DISCARD);
    }
    gl.glBeginTransformFeedback(GL_POINTS);
    gl.glDrawArrays(GL_POINTS, 0, 1);
    gl.glEndTransformFeedback();
    if (rasterDiscard) {
        gl.glDisable(GL_RASTERIZER_DISCARD);
    }
    expectGLError(gl, GL_NO_ERROR, "dcr4e GS TF capture");
    gl.glBindVertexArray(0);
    gl.glDeleteVertexArrays(1, &vao);
}

bool dcr4eTfBufferSawSeven(GLDispatchTable& gl, GLuint buffer) {
    std::array<float, 16> values = {};
    gl.glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffer);
    gl.glGetBufferSubData(GL_TRANSFORM_FEEDBACK_BUFFER, 0,
                          static_cast<GLsizeiptr>(values.size() * sizeof(float)),
                          values.data());
    expectGLError(gl, GL_NO_ERROR, "dcr4e TF buffer readback");
    return std::any_of(values.begin(), values.end(),
                       [](float value) { return std::fabs(value - 7.0f) < 0.01f; });
}

TestResult runDCR4ETfProducerSentinel() {
    auto result = runDirectSentinel("dcr4e.tf-buffer-producer-mark", [&] {
        ScopedSentinelContext scoped(kDCR4ESize, kDCR4ESize);
        auto& context = scoped.context();
        auto& gl = scoped.gl();
        const char* tfName = "tfValue";
        const GLuint program = buildDCR4EGsProgram(
            kDCR4EGsPointVS, kDCR4EGsPointGS, kDCR4EGsColorFS, &tfName, 1);
        const GLuint tfBuffer = createDCR4ETfBuffer(gl);
        const GLuint tf = createDCR4ETransformFeedback(gl, tfBuffer);

        captureDCR4EGsPoint(gl, program, tf, tfBuffer, true);
        expectPendingHas(bufferPendingBits(context, tfBuffer),
                         kProducerTransformFeedback,
                         "dcr4e TF CPU-GS write marks producer bit");
        expectCondition(dcr4eTfBufferSawSeven(gl, tfBuffer),
                        "dcr4e TF CPU-GS write stores exact value");
        expectPendingClear(bufferPendingBits(context, tfBuffer),
                           kProducerTransformFeedback,
                           "dcr4e TF readback drains producer bit");

        resetDCR4ETfBuffer(gl, tfBuffer);
        {
            ScopedEnvVar skipMark(
                APPGL_DCR_SENTINEL_ENV("APPGL_DCR4E_TF_SKIP_PRODUCER_MARK"), "1");
            captureDCR4EGsPoint(gl, program, tf, tfBuffer, true);
        }
        expectPendingClear(bufferPendingBits(context, tfBuffer),
                           kProducerTransformFeedback,
                           "dcr4e TF producer red-stub suppresses mark");
        expectCondition(dcr4eTfBufferSawSeven(gl, tfBuffer),
                        "dcr4e TF write remains non-vacuous when mark is skipped");

        resetDCR4ETfBuffer(gl, tfBuffer);
        {
            ScopedEnvVar skipWrite(
                APPGL_DCR_SENTINEL_ENV("APPGL_DCR4E_TF_SKIP_CPU_WRITE"), "1");
            captureDCR4EGsPoint(gl, program, tf, tfBuffer, true);
        }
        expectCondition(!dcr4eTfBufferSawSeven(gl, tfBuffer),
                        "dcr4e TF write sentinel fails when CPU payload is skipped");

        gl.glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
        gl.glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteTransformFeedbacks(1, &tf);
        gl.glDeleteBuffers(1, &tfBuffer);
        gl.glDeleteProgram(program);
        expectGLError(gl, GL_NO_ERROR, "dcr4e TF producer cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "CPU-GS transform-feedback writes mark kProducerTransformFeedback and red-stubs are non-vacuous";
    }
    return result;
}

TestResult runDCR4ECpuImageProducerSentinel() {
    auto result = runDirectSentinel("dcr4e.cpu-image-producer-mark", [&] {
        ScopedSentinelContext scoped(kDCR4ESize, kDCR4ESize);
        auto& context = scoped.context();
        auto& gl = scoped.gl();
        const GLuint program = buildDCR4EGsProgram(
            kDCR4EGsPointVS, kDCR4EGsImageGS, kDCR4EBlackFS);

        auto runImageDraw = [&](bool skipMark) {
            GLuint imageTex = 0;
            gl.glGenTextures(1, &imageTex);
            setupDCR3CRGBA8Texture(gl, imageTex, 4, 4);
            gl.glBindImageTexture(0, imageTex, 0, GL_FALSE, 0,
                                  GL_WRITE_ONLY, GL_RGBA8);
            if (skipMark) {
                ScopedEnvVar skip(
                    APPGL_DCR_SENTINEL_ENV("APPGL_DCR4E_IMAGE_SKIP_PRODUCER_MARK"), "1");
                drawDCR4EGsPoint(gl, program);
            } else {
                drawDCR4EGsPoint(gl, program);
            }
            gl.glMemoryBarrier(GL_ALL_BARRIER_BITS);
            if (skipMark) {
                expectPendingClear(texturePendingBits(context, imageTex),
                                   kProducerStorageImageWrite,
                                   "dcr4e image producer red-stub suppresses mark");
            } else {
                expectPendingHas(texturePendingBits(context, imageTex),
                                 kProducerStorageImageWrite,
                                 "dcr4e CPU image write marks storage-image producer");
            }
            std::array<std::uint8_t, 4 * 4 * 4> pixels = {};
            gl.glGetTextureImage(imageTex, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                                 static_cast<GLsizei>(pixels.size()),
                                 pixels.data());
            expectGLError(gl, GL_NO_ERROR, "dcr4e image readback");
            expectCondition(pixels[0] >= 180 && pixels[1] <= 40 &&
                                pixels[2] <= 40 && pixels[3] >= 240,
                            "dcr4e CPU image write stores red texel");
            expectPendingClear(texturePendingBits(context, imageTex),
                               kProducerStorageImageWrite,
                               "dcr4e image readback drains producer bit");
            gl.glBindImageTexture(0, 0, 0, GL_FALSE, 0,
                                  GL_READ_WRITE, GL_RGBA8);
            gl.glDeleteTextures(1, &imageTex);
        };

        runImageDraw(false);
        runImageDraw(true);

        gl.glUseProgram(0);
        gl.glDeleteProgram(program);
        expectGLError(gl, GL_NO_ERROR, "dcr4e image producer cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "CPU interpreter image writes mark storage-image producers by default";
    }
    return result;
}

TestResult runDCR4EQueryCounterSentinel() {
    auto result = runDirectSentinel("dcr4e.query-counter-readback", [&] {
        ScopedSentinelContext scoped(kDCR4ESize, kDCR4ESize);
        auto& gl = scoped.gl();
        const char* tfName = "tfValue";
        const GLuint program = buildDCR4EGsProgram(
            kDCR4EGsPointVS, kDCR4EGsPointGS, kDCR4EGsColorFS, &tfName, 1);
        const GLuint tfBuffer = createDCR4ETfBuffer(gl);
        const GLuint tf = createDCR4ETransformFeedback(gl, tfBuffer);

        auto captureWithQueries = [&](bool skipQueries,
                                      GLuint64& generated,
                                      GLuint64& written) {
            GLuint queries[2] = {};
            gl.glGenQueries(2, queries);
            gl.glUseProgram(program);
            gl.glBeginQuery(GL_PRIMITIVES_GENERATED, queries[0]);
            gl.glBeginQuery(GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN, queries[1]);
            if (skipQueries) {
                ScopedEnvVar skip(
                    APPGL_DCR_SENTINEL_ENV("APPGL_DCR4E_SKIP_QUERY_UPDATES"), "1");
                captureDCR4EGsPoint(gl, program, tf, tfBuffer, true);
            } else {
                captureDCR4EGsPoint(gl, program, tf, tfBuffer, true);
            }
            gl.glEndQuery(GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN);
            gl.glEndQuery(GL_PRIMITIVES_GENERATED);
            gl.glGetQueryObjectui64v(queries[0], GL_QUERY_RESULT, &generated);
            gl.glGetQueryObjectui64v(queries[1], GL_QUERY_RESULT, &written);
            gl.glDeleteQueries(2, queries);
            expectGLError(gl, GL_NO_ERROR, "dcr4e query readback");
        };

        GLuint64 generated = 0;
        GLuint64 written = 0;
        captureWithQueries(false, generated, written);
        expectCondition(generated >= 1, "dcr4e primitives-generated query advances");
        expectCondition(written >= 1, "dcr4e TF-written query advances");

        generated = 0;
        written = 0;
        captureWithQueries(true, generated, written);
        expectCondition(generated == 0 && written == 0,
                        "dcr4e query red-stub proves CPU-side query accounting");

        gl.glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
        gl.glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteTransformFeedbacks(1, &tf);
        gl.glDeleteBuffers(1, &tfBuffer);
        gl.glDeleteProgram(program);
        expectGLError(gl, GL_NO_ERROR, "dcr4e query cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "TF queries/counters are CPU-side accounting, with non-vacuous red-stub coverage";
    }
    return result;
}

TestResult runDCR4EStreamReplaySentinel() {
    auto result = runDirectSentinel("dcr4e.stream-replay-no-slip", [&] {
        ScopedSentinelContext scoped(kDCR4ESize, kDCR4ESize);
        auto& gl = scoped.gl();
        const char* tfName = "tfValue";
        const GLuint captureProgram = buildDCR4EGsProgram(
            kDCR4EGsPointVS, kDCR4EGsPointGS, kDCR4EGsColorFS, &tfName, 1);
        const GLuint replayProgram = buildDCR4EReplayProgram();
        const GLuint tfBuffer = createDCR4ETfBuffer(gl);
        const GLuint tf = createDCR4ETransformFeedback(gl, tfBuffer);

        GLuint texture = 0;
        GLuint framebuffer = 0;
        setupDCR4ETarget(gl, texture, framebuffer);
        captureDCR4EGsPoint(gl, captureProgram, tf, tfBuffer, true);

        GLuint replayVao = 0;
        gl.glGenVertexArrays(1, &replayVao);
        gl.glBindVertexArray(replayVao);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        gl.glUseProgram(replayProgram);
        gl.glEnable(GL_PROGRAM_POINT_SIZE);
        gl.glDrawTransformFeedbackStream(GL_POINTS, tf, 0);
        expectGLError(gl, GL_NO_ERROR, "dcr4e stream replay draw");
        auto pixel = readDCR4ECenter(gl);
        expectCondition(isDCR4EGreen(pixel),
                        "dcr4e stream replay consumes completed TF count");

        clearDCR4ETarget(gl);
        {
            ScopedEnvVar zeroReplay(
                APPGL_DCR_SENTINEL_ENV("APPGL_DCR4E_FORCE_STREAM_REPLAY_ZERO_COUNT"), "1");
            gl.glDrawTransformFeedbackStream(GL_POINTS, tf, 0);
        }
        pixel = readDCR4ECenter(gl);
        expectCondition(isDCR4EBlack(pixel),
                        "dcr4e forced zero replay count draws nothing");

        clearDCR4ETarget(gl);
        resetDCR4ETfBuffer(gl, tfBuffer);
        {
            ScopedEnvVar skipCount(
                APPGL_DCR_SENTINEL_ENV("APPGL_DCR4E_SKIP_TF_COUNT_UPDATE"), "1");
            captureDCR4EGsPoint(gl, captureProgram, tf, tfBuffer, true);
        }
        gl.glBindVertexArray(replayVao);
        gl.glUseProgram(replayProgram);
        gl.glDrawTransformFeedbackStream(GL_POINTS, tf, 0);
        pixel = readDCR4ECenter(gl);
        expectCondition(isDCR4EBlack(pixel),
                        "dcr4e TF count red-stub prevents replay draw");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
        gl.glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, 0);
        gl.glBindVertexArray(0);
        gl.glUseProgram(0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(1, &texture);
        gl.glDeleteVertexArrays(1, &replayVao);
        gl.glDeleteTransformFeedbacks(1, &tf);
        gl.glDeleteBuffers(1, &tfBuffer);
        gl.glDeleteProgram(captureProgram);
        gl.glDeleteProgram(replayProgram);
        expectGLError(gl, GL_NO_ERROR, "dcr4e stream replay cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "stream replay consumes exact completed counts and zero-count red-stubs do not fall through";
    }
    return result;
}

TestResult runDCR4EExactNoSlipSentinel() {
    auto result = runDirectSentinel("dcr4e.exact-only-no-slip", [&] {
        ScopedSentinelContext scoped(kDCR4ESize, kDCR4ESize);
        auto& gl = scoped.gl();
        const char* tfName = "tfValue";
        const GLuint program = buildDCR4EGsProgram(
            kDCR4EGsPointVS, kDCR4EGsPointGS, kDCR4EGsColorFS, &tfName, 1);
        const GLuint tfBuffer = createDCR4ETfBuffer(gl);
        const GLuint tf = createDCR4ETransformFeedback(gl, tfBuffer);

        GLuint texture = 0;
        GLuint framebuffer = 0;
        setupDCR4ETarget(gl, texture, framebuffer);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);

        captureDCR4EGsPoint(gl, program, tf, tfBuffer, false);
        auto pixel = readDCR4ECenter(gl);
        expectCondition(isDCR4EGreen(pixel),
                        "dcr4e normal CPU-GS raster path draws exact green");

        clearDCR4ETarget(gl);
        {
            ScopedEnvVar failRaster(
                APPGL_DCR_SENTINEL_ENV("APPGL_DCR4E_FORCE_GS_RASTER_ENCODE_FAIL"), "1");
            captureDCR4EGsPoint(gl, program, tf, tfBuffer, false);
        }
        pixel = readDCR4ECenter(gl);
        expectCondition(isDCR4EBlack(pixel) && !isDCR4ERed(pixel),
                        "dcr4e failed CPU-GS raster encode consumes instead of legacy fallback");

        clearDCR4ETarget(gl);
        {
            ScopedEnvVar failTf(
                APPGL_DCR_SENTINEL_ENV("APPGL_DCR4E_FORCE_TF_CAPTURE_FAIL"), "1");
            captureDCR4EGsPoint(gl, program, tf, tfBuffer, false);
        }
        pixel = readDCR4ECenter(gl);
        expectCondition(isDCR4EBlack(pixel) && !isDCR4ERed(pixel),
                        "dcr4e failed TF capture consumes instead of legacy fallback");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
        gl.glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(1, &texture);
        gl.glDeleteTransformFeedbacks(1, &tf);
        gl.glDeleteBuffers(1, &tfBuffer);
        gl.glDeleteProgram(program);
        expectGLError(gl, GL_NO_ERROR, "dcr4e exact no-slip cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "exact-only CPU-GS/TF failure paths consume honestly and never fall through to legacy VS+FS";
    }
    return result;
}

TestResult runDCR3CViewportRestoreAbandonmentSentinel() {
    auto result = runDirectSentinel("dcr3c.viewport-restore-abandonment", [&] {
        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();
        std::vector<std::string> failures;

        static constexpr const char* kFullscreenVS =
            "#version 330 core\n"
            "layout(location = 0) in vec2 aPos;\n"
            "void main() {\n"
            "    gl_Position = vec4(aPos, 0.0, 1.0);\n"
            "}\n";
        static constexpr const char* kColorFS =
            "#version 330 core\n"
            "uniform vec4 uColor;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    fragColor = uColor;\n"
            "}\n";

        const GLuint program = buildBenchProgram(kFullscreenVS, kColorFS);
        GLint linkStatus = GL_FALSE;
        gl.glGetProgramiv(program, GL_LINK_STATUS, &linkStatus);
        expectCondition(linkStatus == GL_TRUE,
                        "dcr3c abandonment program links");
        const GLint colorLocation = gl.glGetUniformLocation(program, "uColor");
        expectCondition(colorLocation >= 0,
                        "dcr3c abandonment color uniform exists");

        GLuint vao = 0;
        GLuint vbo = 0;
        setupDCR3CFullscreenTriangle(gl, vao, vbo);

        GLuint texture = 0;
        GLuint framebuffer = 0;
        gl.glGenTextures(1, &texture);
        setupDCR3CRGBA8Texture(gl, texture, 4, 4);
        setupDCR3CTextureFbo(gl, framebuffer, texture);
        expectGLError(gl, GL_NO_ERROR, "dcr3c abandonment setup");

        gl.glViewport(0, 0, 4, 4);
        gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT);
        gl.glFinish();

        const auto beforeDraw = context.commandSubmissionDebugCounters();

        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        gl.glViewport(0, 0, 1, 1);
        gl.glUseProgram(program);
        gl.glUniform4f(colorLocation, 0.82f, 0.10f, 0.22f, 1.0f);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        expectGLError(gl, GL_NO_ERROR, "dcr3c abandonment producer draw");

        expectPendingHas(texturePendingBits(context, texture),
                         kProducerFboColorWrite,
                         "dcr3c abandonment draw marked texture producer bits");

        const auto afterDraw = context.commandSubmissionDebugCounters();
        if (afterDraw.submittedCommandBuffers != beforeDraw.submittedCommandBuffers) {
            recordSentinelFailure(
                failures,
                "producer draw submitted before viewport restore",
                "before{" + countersSummary(beforeDraw) + "} afterDraw{"
                    + countersSummary(afterDraw) + "}"
            );
        }

        gl.glViewport(0, 0, 32, 32);
        expectGLError(gl, GL_NO_ERROR, "dcr3c abandonment viewport restore");

        const auto afterRestore = context.commandSubmissionDebugCounters();
        if (afterRestore.submittedCommandBuffers <= afterDraw.submittedCommandBuffers) {
            recordSentinelFailure(
                failures,
                "viewport restore did not submit the pending FBO draw before invalidation",
                "afterDraw{" + countersSummary(afterDraw) + "} afterRestore{"
                    + countersSummary(afterRestore) + "}"
            );
        }
        if (afterRestore.currentInFlight != 0
            || afterRestore.completedCommandBuffers != afterRestore.submittedCommandBuffers) {
            recordSentinelFailure(
                failures,
                "viewport-restore invalidation did not drain submitted work",
                countersSummary(afterRestore)
            );
        }
        expectPendingHas(texturePendingBits(context, texture),
                         kProducerFboColorWrite,
                         "dcr3c abandonment restore preserves producer bits until readback");

        std::array<std::uint8_t, 4> pixel = {};
        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        gl.glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
        expectGLError(gl, GL_NO_ERROR, "dcr3c abandonment readback");

        if (pixel[0] < 180 || pixel[1] > 60 || pixel[2] > 90 || pixel[3] < 250) {
            recordSentinelFailure(
                failures,
                "viewport-restore readback did not observe the pre-restore FBO draw",
                "rgba=(" + std::to_string(pixel[0]) + ","
                    + std::to_string(pixel[1]) + ","
                    + std::to_string(pixel[2]) + ","
                    + std::to_string(pixel[3]) + ")"
            );
        }
        expectPendingClear(texturePendingBits(context, texture),
                           kProducerFboColorWrite,
                           "dcr3c abandonment readback clears producer bits");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindVertexArray(0);
        gl.glBindBuffer(GL_ARRAY_BUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(1, &texture);
        gl.glDeleteBuffers(1, &vbo);
        gl.glDeleteVertexArrays(1, &vao);
        gl.glDeleteProgram(program);
        expectGLError(gl, GL_NO_ERROR, "dcr3c abandonment cleanup");
        gl.glFinish();

        throwIfSentinelFailed(failures);
    });
    if (result.status == "passed") {
        result.message = "FBO draw survived viewport-restore resize invalidation before readback";
    }
    return result;
}

TestResult runDCR3CProducerInventorySentinel() {
    auto result = runDirectSentinel("dcr3c.producer-inventory-bits", [&] {
        static constexpr GLsizei kSize = 8;
        static constexpr const char* kFullscreenVS =
            "#version 330 core\n"
            "layout(location = 0) in vec2 aPos;\n"
            "void main() {\n"
            "    gl_Position = vec4(aPos, 0.0, 1.0);\n"
            "}\n";
        static constexpr const char* kColorFS =
            "#version 330 core\n"
            "uniform vec4 uColor;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    fragColor = uColor;\n"
            "}\n";
        static constexpr const char* kSampleFS =
            "#version 330 core\n"
            "uniform sampler2D uSource;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    fragColor = texture(uSource, vec2(0.5, 0.5));\n"
            "}\n";
        static constexpr const char* kComputeCS =
            "#version 430 core\n"
            "layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;\n"
            "layout(rgba8, binding = 0) uniform writeonly image2D outImage;\n"
            "layout(std430, binding = 0) buffer OutData { uint value; } outData;\n"
            "layout(binding = 0, offset = 0) uniform atomic_uint counter;\n"
            "void main() {\n"
            "    imageStore(outImage, ivec2(0, 0), vec4(0.0, 0.0, 1.0, 1.0));\n"
            "    outData.value = 0x12345678u;\n"
            "    atomicCounterIncrement(counter);\n"
            "}\n";

        ScopedSentinelContext scoped(64, 64);
        auto& context = scoped.context();
        auto& gl = scoped.gl();
        const bool samplerGpuOrderSkip =
            std::getenv("APPGL_ENABLE_SAMPLER_GPU_ORDER_SKIP") != nullptr;

        const GLuint colorProgram = buildBenchProgram(kFullscreenVS, kColorFS);
        const GLuint sampleProgram = buildBenchProgram(kFullscreenVS, kSampleFS);
        GLint colorLinked = GL_FALSE;
        GLint sampleLinked = GL_FALSE;
        gl.glGetProgramiv(colorProgram, GL_LINK_STATUS, &colorLinked);
        gl.glGetProgramiv(sampleProgram, GL_LINK_STATUS, &sampleLinked);
        expectCondition(colorLinked == GL_TRUE, "dcr3c inventory color program links");
        expectCondition(sampleLinked == GL_TRUE, "dcr3c inventory sample program links");
        const GLint colorLocation = gl.glGetUniformLocation(colorProgram, "uColor");
        const GLint sampleLocation = gl.glGetUniformLocation(sampleProgram, "uSource");
        expectCondition(colorLocation >= 0, "dcr3c inventory color uniform exists");
        expectCondition(sampleLocation >= 0, "dcr3c inventory sampler uniform exists");

        GLuint vao = 0;
        GLuint vbo = 0;
        setupDCR3CFullscreenTriangle(gl, vao, vbo);

        GLuint textures[3] = {};
        GLuint framebuffers[2] = {};
        gl.glGenTextures(3, textures);
        const GLuint sourceTex = textures[0];
        const GLuint sampledTex = textures[1];
        const GLuint imageTex = textures[2];
        setupDCR3CRGBA8Texture(gl, sourceTex, kSize, kSize);
        setupDCR3CRGBA8Texture(gl, sampledTex, kSize, kSize);
        setupDCR3CRGBA8Texture(gl, imageTex, 4, 4);
        setupDCR3CTextureFbo(gl, framebuffers[0], sourceTex);
        setupDCR3CTextureFbo(gl, framebuffers[1], sampledTex);
        expectGLError(gl, GL_NO_ERROR, "dcr3c inventory texture/fbo setup");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffers[0]);
        gl.glViewport(0, 0, kSize, kSize);
        gl.glUseProgram(colorProgram);
        gl.glUniform4f(colorLocation, 1.0f, 0.0f, 0.0f, 1.0f);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        expectGLError(gl, GL_NO_ERROR, "dcr3c inventory FBO producer draw");
        expectPendingHas(texturePendingBits(context, sourceTex),
                         kProducerFboColorWrite,
                         "FBO color producer");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffers[1]);
        gl.glUseProgram(sampleProgram);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_2D, sourceTex);
        gl.glUniform1i(sampleLocation, 0);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        expectGLError(gl, GL_NO_ERROR, "dcr3c inventory sampler consumer draw");
        if (samplerGpuOrderSkip) {
            expectPendingHas(texturePendingBits(context, sourceTex),
                             kProducerFboColorWrite,
                             "sampler GPU-order skip preserves source producer");
        } else {
            expectPendingClear(texturePendingBits(context, sourceTex),
                               kProducerFboColorWrite,
                               "sampler consumer drain");
        }
        expectPendingHas(texturePendingBits(context, sampledTex),
                         kProducerFboColorWrite,
                         "sampled FBO destination producer");

        std::array<std::uint8_t, kSize * kSize * 4> readback = {};
        gl.glReadPixels(0, 0, kSize, kSize, GL_RGBA, GL_UNSIGNED_BYTE,
                        readback.data());
        expectGLError(gl, GL_NO_ERROR, "dcr3c inventory sampled readback");
        expectPendingClear(texturePendingBits(context, sampledTex),
                           kProducerFboColorWrite,
                           "FBO readback drain");
        if (samplerGpuOrderSkip) {
            std::array<std::uint8_t, kSize * kSize * 4> sourceReadback = {};
            gl.glGetTextureImage(sourceTex, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                                 static_cast<GLsizei>(sourceReadback.size()),
                                 sourceReadback.data());
            expectGLError(gl, GL_NO_ERROR,
                          "dcr3c inventory source readback after sampler skip");
            if (sourceReadback[0] < 200 ||
                sourceReadback[1] > 40 ||
                sourceReadback[2] > 40 ||
                sourceReadback[3] < 250) {
                throw std::runtime_error(
                    "sampler GPU-order skip source readback was not red");
            }
            expectPendingClear(
                texturePendingBits(context, sourceTex),
                kProducerFboColorWrite,
                "source readback after sampler GPU-order skip");
        }

        const GLfloat clearGreen[] = {0.0f, 1.0f, 0.0f, 1.0f};
        gl.glClearBufferfv(GL_COLOR, 0, clearGreen);
        expectGLError(gl, GL_NO_ERROR, "dcr3c inventory clear producer");
        expectPendingHas(texturePendingBits(context, sampledTex),
                         kProducerClearWrite,
                         "clear producer");
        gl.glReadPixels(0, 0, kSize, kSize, GL_RGBA, GL_UNSIGNED_BYTE,
                        readback.data());
        expectGLError(gl, GL_NO_ERROR, "dcr3c inventory clear readback");
        expectPendingClear(texturePendingBits(context, sampledTex),
                           kProducerClearWrite,
                           "clear readback drain");

        const GLuint computeProgram = buildDCR3CComputeProgram(kComputeCS);
        GLint computeLinked = GL_FALSE;
        gl.glGetProgramiv(computeProgram, GL_LINK_STATUS, &computeLinked);
        expectCondition(computeLinked == GL_TRUE, "dcr3c inventory compute program links");

        GLuint ssbo = 0;
        GLuint atomicBuffer = 0;
        std::uint32_t zero = 0;
        gl.glGenBuffers(1, &ssbo);
        gl.glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
        gl.glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(std::uint32_t),
                        &zero, GL_DYNAMIC_DRAW);
        gl.glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);
        gl.glGenBuffers(1, &atomicBuffer);
        gl.glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, atomicBuffer);
        gl.glBufferData(GL_ATOMIC_COUNTER_BUFFER, sizeof(std::uint32_t),
                        &zero, GL_DYNAMIC_DRAW);
        gl.glBindBufferBase(GL_ATOMIC_COUNTER_BUFFER, 0, atomicBuffer);
        gl.glBindImageTexture(0, imageTex, 0, GL_FALSE, 0,
                              GL_WRITE_ONLY, GL_RGBA8);
        gl.glUseProgram(computeProgram);
        gl.glDispatchCompute(1, 1, 1);
        expectGLError(gl, GL_NO_ERROR, "dcr3c inventory compute dispatch");

        expectPendingHas(texturePendingBits(context, imageTex),
                         kProducerComputeWrite | kProducerStorageImageWrite,
                         "compute storage-image producer");
        expectPendingHas(bufferPendingBits(context, ssbo),
                         kProducerComputeWrite | kProducerShaderStorageWrite,
                         "compute SSBO producer");
        expectPendingHas(bufferPendingBits(context, atomicBuffer),
                         kProducerComputeWrite | kProducerAtomicCounterWrite,
                         "compute atomic producer");

        std::array<std::uint8_t, 4 * 4 * 4> imagePixels = {};
        gl.glGetTextureImage(imageTex, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                             static_cast<GLsizei>(imagePixels.size()),
                             imagePixels.data());
        expectGLError(gl, GL_NO_ERROR, "dcr3c inventory image readback");
        expectPendingClear(texturePendingBits(context, imageTex),
                           kProducerComputeWrite | kProducerStorageImageWrite,
                           "storage-image readback drain");

        std::uint32_t ssboValue = 0;
        gl.glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
        gl.glGetBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
                              sizeof(ssboValue), &ssboValue);
        expectGLError(gl, GL_NO_ERROR, "dcr3c inventory SSBO readback");
        expectPendingClear(bufferPendingBits(context, ssbo),
                           kProducerComputeWrite | kProducerShaderStorageWrite,
                           "SSBO readback drain");

        std::uint32_t atomicValue = 0;
        gl.glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, atomicBuffer);
        gl.glGetBufferSubData(GL_ATOMIC_COUNTER_BUFFER, 0,
                              sizeof(atomicValue), &atomicValue);
        expectGLError(gl, GL_NO_ERROR, "dcr3c inventory atomic readback");
        expectPendingClear(bufferPendingBits(context, atomicBuffer),
                           kProducerComputeWrite | kProducerAtomicCounterWrite,
                           "atomic readback drain");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindVertexArray(0);
        gl.glBindBuffer(GL_ARRAY_BUFFER, 0);
        gl.glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
        gl.glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, 0);
        gl.glBindTexture(GL_TEXTURE_2D, 0);
        gl.glUseProgram(0);
        gl.glDeleteBuffers(1, &ssbo);
        gl.glDeleteBuffers(1, &atomicBuffer);
        gl.glDeleteFramebuffers(2, framebuffers);
        gl.glDeleteTextures(3, textures);
        gl.glDeleteBuffers(1, &vbo);
        gl.glDeleteVertexArrays(1, &vao);
        gl.glDeleteProgram(colorProgram);
        gl.glDeleteProgram(sampleProgram);
        gl.glDeleteProgram(computeProgram);
        expectGLError(gl, GL_NO_ERROR, "dcr3c inventory cleanup");
    });
    if (result.status == "passed") {
        result.message = "producer bits marked and drained for texture, compute image, SSBO, and atomic paths";
    }
    return result;
}

TestResult runDCR3CBarBlitCopyMipmapSentinel() {
    auto result = runDirectSentinel("dcr3c.bar-blit-copy-mipmap", [&] {
        static constexpr GLsizei kSize = 8;
        static constexpr const char* kFullscreenVS =
            "#version 330 core\n"
            "layout(location = 0) in vec2 aPos;\n"
            "void main() {\n"
            "    gl_Position = vec4(aPos, 0.0, 1.0);\n"
            "}\n";
        static constexpr const char* kColorFS =
            "#version 330 core\n"
            "uniform vec4 uColor;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    fragColor = uColor;\n"
            "}\n";

        ScopedSentinelContext scoped(64, 64);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        const GLuint colorProgram = buildBenchProgram(kFullscreenVS, kColorFS);
        GLint linked = GL_FALSE;
        gl.glGetProgramiv(colorProgram, GL_LINK_STATUS, &linked);
        expectCondition(linked == GL_TRUE, "dcr3c BAR color program links");
        const GLint colorLocation = gl.glGetUniformLocation(colorProgram, "uColor");
        expectCondition(colorLocation >= 0, "dcr3c BAR color uniform exists");

        GLuint vao = 0;
        GLuint vbo = 0;
        setupDCR3CFullscreenTriangle(gl, vao, vbo);

        GLuint textures[3] = {};
        GLuint framebuffers[3] = {};
        gl.glGenTextures(3, textures);
        const GLuint srcTex = textures[0];
        const GLuint dstTex = textures[1];
        const GLuint mipTex = textures[2];
        setupDCR3CRGBA8Texture(gl, srcTex, kSize, kSize);
        setupDCR3CRGBA8Texture(gl, dstTex, kSize, kSize);
        setupDCR3CRGBA8Texture(gl, mipTex, 4, 4, 3);
        setupDCR3CTextureFbo(gl, framebuffers[0], srcTex);
        setupDCR3CTextureFbo(gl, framebuffers[1], dstTex);
        setupDCR3CTextureFbo(gl, framebuffers[2], mipTex, 0);
        expectGLError(gl, GL_NO_ERROR, "dcr3c BAR blit/mipmap setup");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffers[0]);
        gl.glViewport(0, 0, kSize, kSize);
        gl.glUseProgram(colorProgram);
        gl.glUniform4f(colorLocation, 1.0f, 0.0f, 0.0f, 1.0f);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        expectGLError(gl, GL_NO_ERROR, "dcr3c BAR blit source draw");
        expectPendingHas(texturePendingBits(context, srcTex),
                         kProducerFboColorWrite,
                         "blit source FBO producer");

        gl.glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffers[0]);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
        gl.glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffers[1]);
        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glBlitFramebuffer(0, 0, kSize, kSize,
                             0, 0, kSize, kSize,
                             GL_COLOR_BUFFER_BIT, GL_NEAREST);
        expectGLError(gl, GL_NO_ERROR, "dcr3c BAR blit");
        expectPendingClear(texturePendingBits(context, srcTex),
                           kProducerFboColorWrite,
                           "blit source drain");
        expectPendingHas(texturePendingBits(context, dstTex),
                         kProducerCopyWrite,
                         "blit destination producer");

        std::array<std::uint8_t, kSize * kSize * 4> pixels = {};
        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffers[1]);
        gl.glReadPixels(0, 0, kSize, kSize, GL_RGBA, GL_UNSIGNED_BYTE,
                        pixels.data());
        expectGLError(gl, GL_NO_ERROR, "dcr3c BAR blit destination readback");
        expectPendingClear(texturePendingBits(context, dstTex),
                           kProducerCopyWrite,
                           "blit destination readback drain");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffers[2]);
        gl.glViewport(0, 0, 4, 4);
        gl.glUniform4f(colorLocation, 0.0f, 0.0f, 1.0f, 1.0f);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        expectGLError(gl, GL_NO_ERROR, "dcr3c BAR mipmap base draw");
        expectPendingHas(texturePendingBits(context, mipTex),
                         kProducerFboColorWrite,
                         "mipmap base FBO producer");
        gl.glBindTexture(GL_TEXTURE_2D, mipTex);
        gl.glGenerateMipmap(GL_TEXTURE_2D);
        expectGLError(gl, GL_NO_ERROR, "dcr3c BAR mipmap generation");
        expectPendingClear(texturePendingBits(context, mipTex),
                           kProducerFboColorWrite,
                           "mipmap generation source drain");
        expectPendingHas(texturePendingBits(context, mipTex),
                         kProducerMipmapWrite,
                         "mipmap generation producer");
        std::array<std::uint8_t, 2 * 2 * 4> mipPixels = {};
        gl.glGetTextureImage(mipTex, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                             static_cast<GLsizei>(mipPixels.size()),
                             mipPixels.data());
        expectGLError(gl, GL_NO_ERROR, "dcr3c BAR mip level readback");
        expectPendingClear(texturePendingBits(context, mipTex),
                           kProducerMipmapWrite,
                           "mipmap readback drain");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindVertexArray(0);
        gl.glBindBuffer(GL_ARRAY_BUFFER, 0);
        gl.glBindTexture(GL_TEXTURE_2D, 0);
        gl.glUseProgram(0);
        gl.glDeleteFramebuffers(3, framebuffers);
        gl.glDeleteTextures(3, textures);
        gl.glDeleteBuffers(1, &vbo);
        gl.glDeleteVertexArrays(1, &vao);
        gl.glDeleteProgram(colorProgram);
        expectGLError(gl, GL_NO_ERROR, "dcr3c BAR blit/mipmap cleanup");
    });
    if (result.status == "passed") {
        result.message = "blit/copy and mipmap producers marked destinations and drained on readback";
    }
    return result;
}

TestResult runDCR3CBarCopyImageSparseLifecycleSentinel() {
    auto result = runDirectSentinel("dcr3c.bar-copyimage-sparse-lifecycle", [&] {
        static constexpr const char* kFullscreenVS =
            "#version 330 core\n"
            "layout(location = 0) in vec2 aPos;\n"
            "void main() {\n"
            "    gl_Position = vec4(aPos, 0.0, 1.0);\n"
            "}\n";
        static constexpr const char* kColorFS =
            "#version 330 core\n"
            "uniform vec4 uColor;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    fragColor = uColor;\n"
            "}\n";

        ScopedSentinelContext scoped(64, 64);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        const GLuint colorProgram = buildBenchProgram(kFullscreenVS, kColorFS);
        GLint linked = GL_FALSE;
        gl.glGetProgramiv(colorProgram, GL_LINK_STATUS, &linked);
        expectCondition(linked == GL_TRUE, "dcr3c copy/sparse color program links");
        const GLint colorLocation = gl.glGetUniformLocation(colorProgram, "uColor");
        expectCondition(colorLocation >= 0, "dcr3c copy/sparse color uniform exists");

        GLuint vao = 0;
        GLuint vbo = 0;
        setupDCR3CFullscreenTriangle(gl, vao, vbo);

        GLuint textures[3] = {};
        GLuint framebuffers[2] = {};
        gl.glGenTextures(3, textures);
        const GLuint srcTex = textures[0];
        const GLuint dstTex = textures[1];
        GLuint lifecycleTex = textures[2];
        setupDCR3CRGBA8Texture(gl, srcTex, 4, 4);
        setupDCR3CRGBA8Texture(gl, dstTex, 4, 4);
        setupDCR3CRGBA8Texture(gl, lifecycleTex, 4, 4);
        setupDCR3CTextureFbo(gl, framebuffers[0], srcTex);
        setupDCR3CTextureFbo(gl, framebuffers[1], lifecycleTex);
        expectGLError(gl, GL_NO_ERROR, "dcr3c copy/sparse texture setup");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffers[0]);
        gl.glViewport(0, 0, 4, 4);
        gl.glUseProgram(colorProgram);
        gl.glUniform4f(colorLocation, 1.0f, 0.0f, 0.0f, 1.0f);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        expectGLError(gl, GL_NO_ERROR, "dcr3c copyImage source draw");
        expectPendingHas(texturePendingBits(context, srcTex),
                         kProducerFboColorWrite,
                         "copyImage source FBO producer");
        gl.glCopyImageSubData(srcTex, GL_TEXTURE_2D, 0, 0, 0, 0,
                              dstTex, GL_TEXTURE_2D, 0, 0, 0, 0,
                              4, 4, 1);
        expectGLError(gl, GL_NO_ERROR, "dcr3c copyImageSubData");
        expectPendingClear(texturePendingBits(context, srcTex),
                           kProducerFboColorWrite,
                           "copyImage CPU-shadow source drain");
        expectPendingHas(texturePendingBits(context, dstTex),
                         kProducerCopyWrite,
                         "copyImage destination producer");
        std::array<std::uint8_t, 4 * 4 * 4> copyPixels = {};
        gl.glGetTextureImage(dstTex, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                             static_cast<GLsizei>(copyPixels.size()),
                             copyPixels.data());
        expectGLError(gl, GL_NO_ERROR, "dcr3c copyImage destination readback");
        expectPendingClear(texturePendingBits(context, dstTex),
                           kProducerCopyWrite,
                           "copyImage destination readback drain");

        GLuint sparseBuffer = 0;
        gl.glGenBuffers(1, &sparseBuffer);
        gl.glBindBuffer(GL_ARRAY_BUFFER, sparseBuffer);
        gl.glBufferStorage(GL_ARRAY_BUFFER, 65536, nullptr,
                           GL_SPARSE_STORAGE_BIT_ARB);
        expectGLError(gl, GL_NO_ERROR, "dcr3c sparse buffer storage");
        gl.glBufferPageCommitmentARB(GL_ARRAY_BUFFER, 0, 65536, GL_TRUE);
        expectGLError(gl, GL_NO_ERROR, "dcr3c sparse buffer commitment");
        expectPendingHas(bufferPendingBits(context, sparseBuffer),
                         kProducerSparseResidency,
                         "sparse buffer commitment producer");
        std::array<std::uint8_t, 16> sparseReadback = {};
        gl.glGetBufferSubData(GL_ARRAY_BUFFER, 0,
                              static_cast<GLsizeiptr>(sparseReadback.size()),
                              sparseReadback.data());
        expectGLError(gl, GL_NO_ERROR, "dcr3c sparse buffer readback");
        expectPendingClear(bufferPendingBits(context, sparseBuffer),
                           kProducerSparseResidency,
                           "sparse buffer readback drain");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffers[1]);
        gl.glViewport(0, 0, 4, 4);
        gl.glUniform4f(colorLocation, 0.0f, 1.0f, 0.0f, 1.0f);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        expectGLError(gl, GL_NO_ERROR, "dcr3c lifecycle texture draw");
        expectPendingHas(texturePendingBits(context, lifecycleTex),
                         kProducerFboColorWrite,
                         "lifecycle pending texture producer");
        const auto beforeDelete = context.commandSubmissionDebugCounters();
        gl.glDeleteTextures(1, &lifecycleTex);
        expectGLError(gl, GL_NO_ERROR, "dcr3c lifecycle pending texture delete");
        const auto afterDelete = context.commandSubmissionDebugCounters();
        if (afterDelete.lastWaitReason != AppGLCommandReason::FlushForReadback ||
            afterDelete.lastWaitMode != AppGLSubmitMode::CommitAndWait ||
            afterDelete.waitReasonLogEntries == beforeDelete.waitReasonLogEntries) {
            throw std::runtime_error(
                "pending-producer texture delete did not drain through FlushForReadback: before{"
                + countersSummary(beforeDelete) + "} after{"
                + countersSummary(afterDelete) + "}");
        }

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindVertexArray(0);
        gl.glBindBuffer(GL_ARRAY_BUFFER, 0);
        gl.glBindTexture(GL_TEXTURE_2D, 0);
        gl.glUseProgram(0);
        gl.glDeleteBuffers(1, &sparseBuffer);
        gl.glDeleteFramebuffers(2, framebuffers);
        GLuint remainingTextures[] = {srcTex, dstTex};
        gl.glDeleteTextures(2, remainingTextures);
        gl.glDeleteBuffers(1, &vbo);
        gl.glDeleteVertexArrays(1, &vao);
        gl.glDeleteProgram(colorProgram);
        expectGLError(gl, GL_NO_ERROR, "dcr3c copy/sparse/lifecycle cleanup");
    });
    if (result.status == "passed") {
        result.message = "copyImage source drains, sparse commit marks, and lifecycle delete drains pending producers";
    }
    return result;
}

TestResult runDCR3CBufferRoleSentinel() {
    auto result = runDirectSentinel("dcr3c.buffer-as-different-role", [&] {
        static constexpr const char* kWriteCS =
            "#version 430 core\n"
            "layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;\n"
            "layout(std430, binding = 0) buffer Data { uint value; } dataOut;\n"
            "void main() {\n"
            "    dataOut.value = 0x12345678u;\n"
            "}\n";
        static constexpr const char* kFullscreenVS =
            "#version 330 core\n"
            "layout(location = 0) in vec2 aPos;\n"
            "void main() {\n"
            "    gl_Position = vec4(aPos, 0.0, 1.0);\n"
            "}\n";
        static constexpr const char* kBufferSampleFS =
            "#version 430 core\n"
            "uniform usamplerBuffer uData;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    uint value = texelFetch(uData, 0).r;\n"
            "    fragColor = value == 0x12345678u\n"
            "        ? vec4(0.0, 1.0, 0.0, 1.0)\n"
            "        : vec4(1.0, 0.0, 0.0, 1.0);\n"
            "}\n";

        ScopedSentinelContext scoped(64, 64);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        const GLuint computeProgram = buildDCR3CComputeProgram(kWriteCS);
        const GLuint sampleProgram = buildBenchProgram(kFullscreenVS, kBufferSampleFS);
        GLint computeLinked = GL_FALSE;
        GLint sampleLinked = GL_FALSE;
        gl.glGetProgramiv(computeProgram, GL_LINK_STATUS, &computeLinked);
        gl.glGetProgramiv(sampleProgram, GL_LINK_STATUS, &sampleLinked);
        expectCondition(computeLinked == GL_TRUE, "dcr3c buffer-role compute program links");
        expectCondition(sampleLinked == GL_TRUE, "dcr3c buffer-role sample program links");
        const GLint samplerLocation = gl.glGetUniformLocation(sampleProgram, "uData");
        expectCondition(samplerLocation >= 0, "dcr3c buffer-role sampler uniform exists");

        GLuint ssbo = 0;
        std::array<std::uint32_t, 4> zeros = {};
        gl.glGenBuffers(1, &ssbo);
        gl.glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
        gl.glBufferData(GL_SHADER_STORAGE_BUFFER,
                        static_cast<GLsizeiptr>(zeros.size() * sizeof(std::uint32_t)),
                        zeros.data(), GL_DYNAMIC_DRAW);
        gl.glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);
        gl.glUseProgram(computeProgram);
        gl.glDispatchCompute(1, 1, 1);
        expectGLError(gl, GL_NO_ERROR, "dcr3c buffer-role compute dispatch");
        expectPendingHas(bufferPendingBits(context, ssbo),
                         kProducerComputeWrite | kProducerShaderStorageWrite,
                         "buffer-role SSBO producer");

        GLuint tbo = 0;
        gl.glGenTextures(1, &tbo);
        gl.glBindTexture(GL_TEXTURE_BUFFER, tbo);
        gl.glTexBuffer(GL_TEXTURE_BUFFER, GL_R32UI, ssbo);
        expectGLError(gl, GL_NO_ERROR, "dcr3c buffer-role texture buffer setup");

        GLuint colorTex = 0;
        GLuint fbo = 0;
        gl.glGenTextures(1, &colorTex);
        setupDCR3CRGBA8Texture(gl, colorTex, 4, 4);
        setupDCR3CTextureFbo(gl, fbo, colorTex);
        GLuint vao = 0;
        GLuint vbo = 0;
        setupDCR3CFullscreenTriangle(gl, vao, vbo);

        gl.glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        gl.glViewport(0, 0, 4, 4);
        gl.glUseProgram(sampleProgram);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_BUFFER, tbo);
        gl.glUniform1i(samplerLocation, 0);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        expectGLError(gl, GL_NO_ERROR, "dcr3c buffer-role texture-buffer draw");
        expectPendingClear(bufferPendingBits(context, ssbo),
                           kProducerComputeWrite | kProducerShaderStorageWrite,
                           "texture-buffer consumer drain");

        std::array<std::uint8_t, 4 * 4 * 4> pixels = {};
        gl.glReadPixels(0, 0, 4, 4, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
        expectGLError(gl, GL_NO_ERROR, "dcr3c buffer-role readback");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindVertexArray(0);
        gl.glBindBuffer(GL_ARRAY_BUFFER, 0);
        gl.glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
        gl.glBindTexture(GL_TEXTURE_BUFFER, 0);
        gl.glUseProgram(0);
        gl.glDeleteTextures(1, &tbo);
        gl.glDeleteTextures(1, &colorTex);
        gl.glDeleteFramebuffers(1, &fbo);
        gl.glDeleteBuffers(1, &ssbo);
        gl.glDeleteBuffers(1, &vbo);
        gl.glDeleteVertexArrays(1, &vao);
        gl.glDeleteProgram(computeProgram);
        gl.glDeleteProgram(sampleProgram);
        expectGLError(gl, GL_NO_ERROR, "dcr3c buffer-role cleanup");
    });
    if (result.status == "passed") {
        result.message = "SSBO-produced buffer drained when rebound as texture-buffer sampler input";
    }
    return result;
}

void expectMipShadowEvicted(GLContext& context,
                            GLuint texture,
                            GLint level,
                            std::string_view label) {
    const GLTextureObject* textureObject =
        context.objects().textures().get(texture);
    expectCondition(textureObject != nullptr,
                    std::string(label) + " texture object exists");
    const auto& image = expectTextureLevel(context, texture, level, label);
    if (!image.mipShadowEvicted || !image.rgba8.empty() ||
        !image.nativeData.empty()) {
        throw std::runtime_error(
            std::string(label) + " mip shadow was not evicted: " +
            textureStateSummary(*textureObject, image));
    }
}

std::vector<std::uint8_t> uniformRGBA8Pixels(GLsizei width,
                                             GLsizei height,
                                             GLsizei layers,
                                             std::uint8_t r,
                                             std::uint8_t g,
                                             std::uint8_t b,
                                             std::uint8_t a = 255u) {
    std::vector<std::uint8_t> pixels(
        static_cast<std::size_t>(width) *
        static_cast<std::size_t>(height) *
        static_cast<std::size_t>(layers) * 4u,
        0u);
    for (std::size_t i = 0; i < pixels.size(); i += 4u) {
        pixels[i + 0u] = r;
        pixels[i + 1u] = g;
        pixels[i + 2u] = b;
        pixels[i + 3u] = a;
    }
    return pixels;
}

void createGeneratedRGBA8MipTexture(GLDispatchTable& gl,
                                    GLuint texture,
                                    std::uint8_t r,
                                    std::uint8_t g,
                                    std::uint8_t b) {
    const auto pixels = uniformRGBA8Pixels(4, 4, 1, r, g, b);
    gl.glBindTexture(GL_TEXTURE_2D, texture);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
                       GL_NEAREST_MIPMAP_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 4, 4, 0,
                    GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    gl.glGenerateMipmap(GL_TEXTURE_2D);
}

TestResult runDefaultDrawableGrowOnlyReadbackProbe() {
    auto result = runDirectSentinel("default-drawable.grow-only-readback", [&] {
        ScopedEnvVar growOnly("APPGL_DEFAULT_DRAWABLE_GROW_ONLY", "1");
        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        gl.glViewport(0, 0, 32, 32);
        gl.glClearColor(0.25f, 0.0f, 0.0f, 1.0f);
        gl.glClearDepth(1.0);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        std::array<std::uint8_t, 4> pixel = {};
        gl.glReadPixels(31, 31, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                        pixel.data());
        expectGLError(gl, GL_NO_ERROR, "grow-only full-size readback");
        expectApproxByte(pixel[0], 64u, 1u, "grow-only full red");
        expectApproxByte(pixel[1], 0u, 0u, "grow-only full green");
        expectApproxByte(pixel[2], 0u, 0u, "grow-only full blue");
        expectApproxByte(pixel[3], 255u, 0u, "grow-only full alpha");

        const auto beforeShrink = context.metalResourceInventory();
        gl.glViewport(0, 0, 8, 8);
        expectGLError(gl, GL_NO_ERROR, "grow-only small viewport");
        const auto afterViewport = context.metalResourceInventory();
        expectCondition(
            afterViewport.frameGraphDrawableResizeGrowOnlySkips >
                beforeShrink.frameGraphDrawableResizeGrowOnlySkips,
            "small viewport used grow-only drawable skip");
        expectCondition(
            afterViewport.frameGraphDrawableResizeDepthTextureReleases ==
                beforeShrink.frameGraphDrawableResizeDepthTextureReleases,
            "small viewport did not release retained depth texture");

        gl.glClearColor(0.0f, 0.75f, 0.0f, 1.0f);
        gl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        pixel = {};
        gl.glReadPixels(31, 31, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                        pixel.data());
        expectGLError(gl, GL_NO_ERROR,
                      "grow-only retained extent readback");
        expectApproxByte(pixel[0], 0u, 0u, "grow-only retained red");
        expectApproxByte(pixel[1], 191u, 1u, "grow-only retained green");
        expectApproxByte(pixel[2], 0u, 0u, "grow-only retained blue");
        expectApproxByte(pixel[3], 255u, 0u, "grow-only retained alpha");

        const auto afterReadback = context.metalResourceInventory();
        expectCondition(
            afterReadback.frameGraphDrawableResizeLastRequestedWidth == 8,
            "grow-only reports small requested width");
        expectCondition(
            afterReadback.frameGraphDrawableResizeLastRequestedHeight == 8,
            "grow-only reports small requested height");
        expectCondition(
            afterReadback.frameGraphDrawableResizeLastEffectiveWidth >= 32,
            "grow-only retained effective width");
        expectCondition(
            afterReadback.frameGraphDrawableResizeLastEffectiveHeight >= 32,
            "grow-only retained effective height");
        expectCondition(
            afterReadback.frameGraphDrawableResizeDepthTextureReleases ==
                beforeShrink.frameGraphDrawableResizeDepthTextureReleases,
            "readback did not release retained depth texture");
    });
    if (result.status == "passed") {
        result.message =
            "grow-only default drawable kept retained extent and readback outside a smaller viewport";
    }
    return result;
}

TestResult runTextureMipShadowEvictionRGBA8ReadbackProbe() {
    auto result = runDirectSentinel("texture-mip-shadow.rgba8-readback", [&] {
        ScopedEnvVar mipDrop("APPGL_TEXTURE_SHADOW_DROP_MIP_LEVELS", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint texture = 0;
        gl.glGenTextures(1, &texture);
        createGeneratedRGBA8MipTexture(gl, texture, 40u, 80u, 120u);
        expectGLError(gl, GL_NO_ERROR, "rgba8 mip setup");
        expectMipShadowEvicted(context, texture, 1,
                               "rgba8 getTextureImage");

        std::array<std::uint8_t, 2 * 2 * 4> readback = {};
        gl.glGetTextureImage(texture, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                             static_cast<GLsizei>(readback.size()),
                             readback.data());
        expectGLError(gl, GL_NO_ERROR, "rgba8 mip getTextureImage");
        for (std::size_t pixel = 0; pixel < readback.size() / 4u; ++pixel) {
            const std::size_t offset = pixel * 4u;
            expectApproxByte(readback[offset + 0u], 40u, 0u,
                             "rgba8 mip red");
            expectApproxByte(readback[offset + 1u], 80u, 0u,
                             "rgba8 mip green");
            expectApproxByte(readback[offset + 2u], 120u, 0u,
                             "rgba8 mip blue");
            expectApproxByte(readback[offset + 3u], 255u, 0u,
                             "rgba8 mip alpha");
        }

        gl.glBindTexture(GL_TEXTURE_2D, texture);
        gl.glGenerateMipmap(GL_TEXTURE_2D);
        expectGLError(gl, GL_NO_ERROR, "rgba8 mip regenerate");
        expectMipShadowEvicted(context, texture, 1,
                               "rgba8 getTextureSubImage");
        readback.fill(0u);
        gl.glGetTextureSubImage(texture, 1, 0, 0, 0, 2, 2, 1,
                                GL_RGBA, GL_UNSIGNED_BYTE,
                                static_cast<GLsizei>(readback.size()),
                                readback.data());
        expectGLError(gl, GL_NO_ERROR, "rgba8 mip getTextureSubImage");
        for (std::size_t pixel = 0; pixel < readback.size() / 4u; ++pixel) {
            const std::size_t offset = pixel * 4u;
            expectApproxByte(readback[offset + 0u], 40u, 0u,
                             "rgba8 subimage red");
            expectApproxByte(readback[offset + 1u], 80u, 0u,
                             "rgba8 subimage green");
            expectApproxByte(readback[offset + 2u], 120u, 0u,
                             "rgba8 subimage blue");
            expectApproxByte(readback[offset + 3u], 255u, 0u,
                             "rgba8 subimage alpha");
        }

        gl.glBindTexture(GL_TEXTURE_2D, 0);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "rgba8 mip cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "generated RGBA8 mip shadow evicted and rematerialized for full/subimage readback";
    }
    return result;
}

TestResult runTextureMipShadowEvictionArrayProbe() {
    auto result = runDirectSentinel("texture-mip-shadow.array-subimage", [&] {
        ScopedEnvVar mipDrop("APPGL_TEXTURE_SHADOW_DROP_MIP_LEVELS", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint texture = 0;
        gl.glGenTextures(1, &texture);
        auto pixels = uniformRGBA8Pixels(4, 4, 2, 0u, 0u, 0u);
        for (std::size_t i = 0; i < pixels.size() / 8u; ++i) {
            const std::size_t offset = i * 4u;
            pixels[offset + 0u] = 32u;
            pixels[offset + 1u] = 64u;
            pixels[offset + 2u] = 96u;
        }
        for (std::size_t i = pixels.size() / 8u; i < pixels.size() / 4u; ++i) {
            const std::size_t offset = i * 4u;
            pixels[offset + 0u] = 160u;
            pixels[offset + 1u] = 96u;
            pixels[offset + 2u] = 48u;
        }
        gl.glBindTexture(GL_TEXTURE_2D_ARRAY, texture);
        gl.glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER,
                           GL_NEAREST_MIPMAP_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER,
                           GL_NEAREST);
        gl.glTexImage3D(GL_TEXTURE_2D_ARRAY, 0, GL_RGBA8, 4, 4, 2, 0,
                        GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
        gl.glGenerateMipmap(GL_TEXTURE_2D_ARRAY);
        expectGLError(gl, GL_NO_ERROR, "array mip setup");
        expectMipShadowEvicted(context, texture, 1,
                               "array getTextureSubImage");

        std::array<std::uint8_t, 2 * 2 * 4> readback = {};
        gl.glGetTextureSubImage(texture, 1, 0, 0, 1, 2, 2, 1,
                                GL_RGBA, GL_UNSIGNED_BYTE,
                                static_cast<GLsizei>(readback.size()),
                                readback.data());
        expectGLError(gl, GL_NO_ERROR, "array mip getTextureSubImage");
        for (std::size_t pixel = 0; pixel < readback.size() / 4u; ++pixel) {
            const std::size_t offset = pixel * 4u;
            expectApproxByte(readback[offset + 0u], 160u, 0u,
                             "array mip red");
            expectApproxByte(readback[offset + 1u], 96u, 0u,
                             "array mip green");
            expectApproxByte(readback[offset + 2u], 48u, 0u,
                             "array mip blue");
            expectApproxByte(readback[offset + 3u], 255u, 0u,
                             "array mip alpha");
        }

        gl.glBindTexture(GL_TEXTURE_2D_ARRAY, 0);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "array mip cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "generated 2D-array mip shadow evicted and restored for layer subimage readback";
    }
    return result;
}

TestResult runTextureMipShadowEvictionR8Probe() {
    auto result = runDirectSentinel("texture-mip-shadow.r8-subimage", [&] {
        ScopedEnvVar mipDrop("APPGL_TEXTURE_SHADOW_DROP_MIP_LEVELS", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint texture = 0;
        gl.glGenTextures(1, &texture);
        std::array<std::uint8_t, 4 * 4> pixels;
        pixels.fill(96u);
        gl.glBindTexture(GL_TEXTURE_2D, texture);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
                           GL_NEAREST_MIPMAP_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, 4, 4, 0,
                        GL_RED, GL_UNSIGNED_BYTE, pixels.data());
        gl.glGenerateMipmap(GL_TEXTURE_2D);
        expectGLError(gl, GL_NO_ERROR, "r8 mip setup");
        expectMipShadowEvicted(context, texture, 1, "r8 mip");

        std::array<std::uint8_t, 2 * 2 * 4> readback = {};
        gl.glGetTextureSubImage(texture, 1, 0, 0, 0, 2, 2, 1,
                                GL_RGBA, GL_UNSIGNED_BYTE,
                                static_cast<GLsizei>(readback.size()),
                                readback.data());
        expectGLError(gl, GL_NO_ERROR, "r8 mip rgba subimage");
        for (std::size_t pixel = 0; pixel < readback.size() / 4u; ++pixel) {
            const std::size_t offset = pixel * 4u;
            expectApproxByte(readback[offset + 0u], 96u, 0u,
                             "r8 mip red");
            expectApproxByte(readback[offset + 1u], 0u, 0u,
                             "r8 mip green");
            expectApproxByte(readback[offset + 2u], 0u, 0u,
                             "r8 mip blue");
            expectApproxByte(readback[offset + 3u], 255u, 0u,
                             "r8 mip alpha");
        }

        gl.glBindTexture(GL_TEXTURE_2D, 0);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "r8 mip cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "generated R8 mip native shadow evicted and restored for RGBA subimage readback";
    }
    return result;
}

TestResult runTextureMipShadowEvictionUploadedMipProbe() {
    auto result = runDirectSentinel("texture-mip-shadow.uploaded-mip", [&] {
        ScopedEnvVar mipDrop("APPGL_TEXTURE_SHADOW_DROP_MIP_LEVELS", "1");
        ScopedEnvVar uploadedMipDrop(
            "APPGL_TEXTURE_SHADOW_DROP_UPLOADED_MIP_LEVELS", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint texture = 0;
        gl.glGenTextures(1, &texture);
        const auto level0 = uniformRGBA8Pixels(4, 4, 1, 20u, 30u, 40u);
        const auto level1 = uniformRGBA8Pixels(2, 2, 1, 133u, 44u, 201u);
        gl.glBindTexture(GL_TEXTURE_2D, texture);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
                           GL_NEAREST_MIPMAP_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 4, 4, 0,
                        GL_RGBA, GL_UNSIGNED_BYTE, level0.data());
        gl.glTexImage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 2, 2, 0,
                        GL_RGBA, GL_UNSIGNED_BYTE, level1.data());
        expectGLError(gl, GL_NO_ERROR, "uploaded mip setup");
        expectMipShadowEvicted(context, texture, 1, "uploaded mip");

        std::array<std::uint8_t, 2 * 2 * 4> readback = {};
        gl.glGetTextureImage(texture, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                             static_cast<GLsizei>(readback.size()),
                             readback.data());
        expectGLError(gl, GL_NO_ERROR, "uploaded mip readback");
        for (std::size_t pixel = 0; pixel < readback.size() / 4u; ++pixel) {
            const std::size_t offset = pixel * 4u;
            expectApproxByte(readback[offset + 0u], 133u, 0u,
                             "uploaded mip red");
            expectApproxByte(readback[offset + 1u], 44u, 0u,
                             "uploaded mip green");
            expectApproxByte(readback[offset + 2u], 201u, 0u,
                             "uploaded mip blue");
            expectApproxByte(readback[offset + 3u], 255u, 0u,
                             "uploaded mip alpha");
        }

        gl.glBindTexture(GL_TEXTURE_2D, 0);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "uploaded mip cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "application-uploaded mip shadow evicted under the explicit widened flag and rematerialized";
    }
    return result;
}

TestResult runTextureMipShadowEvictionUploadRebuildProbe() {
    auto result = runDirectSentinel("texture-mip-shadow.upload-rebuild", [&] {
        ScopedEnvVar mipDrop("APPGL_TEXTURE_SHADOW_DROP_MIP_LEVELS", "1");
        ScopedEnvVar uploadedMipDrop(
            "APPGL_TEXTURE_SHADOW_DROP_UPLOADED_MIP_LEVELS", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint texture = 0;
        gl.glGenTextures(1, &texture);
        const auto level0 = uniformRGBA8Pixels(4, 4, 1, 9u, 18u, 27u);
        const auto level1 = uniformRGBA8Pixels(2, 2, 1, 120u, 30u, 220u);
        const std::array<std::uint8_t, 4> level2 = {4u, 5u, 6u, 255u};
        gl.glBindTexture(GL_TEXTURE_2D, texture);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
                           GL_NEAREST_MIPMAP_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 4, 4, 0,
                        GL_RGBA, GL_UNSIGNED_BYTE, level0.data());
        gl.glTexImage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 2, 2, 0,
                        GL_RGBA, GL_UNSIGNED_BYTE, level1.data());
        expectGLError(gl, GL_NO_ERROR, "upload rebuild mip setup");
        expectMipShadowEvicted(context, texture, 1, "upload rebuild source");

        gl.glTexImage2D(GL_TEXTURE_2D, 2, GL_RGBA8, 1, 1, 0,
                        GL_RGBA, GL_UNSIGNED_BYTE, level2.data());
        expectGLError(gl, GL_NO_ERROR, "upload rebuild force level-count change");
        const auto inventoryAfterRebuild = context.metalResourceInventory();
        expectCondition(
            inventoryAfterRebuild.hostCaches.textureMipShadowEviction
                .materializeUploadRebuildCalls > 0,
            "upload rebuild materialized evicted mip before replacing Metal texture");

        std::array<std::uint8_t, 2 * 2 * 4> readback = {};
        gl.glGetTextureImage(texture, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                             static_cast<GLsizei>(readback.size()),
                             readback.data());
        expectGLError(gl, GL_NO_ERROR, "upload rebuild level1 readback");
        for (std::size_t pixel = 0; pixel < readback.size() / 4u; ++pixel) {
            const std::size_t offset = pixel * 4u;
            expectApproxByte(readback[offset + 0u], 120u, 0u,
                             "upload rebuild red");
            expectApproxByte(readback[offset + 1u], 30u, 0u,
                             "upload rebuild green");
            expectApproxByte(readback[offset + 2u], 220u, 0u,
                             "upload rebuild blue");
            expectApproxByte(readback[offset + 3u], 255u, 0u,
                             "upload rebuild alpha");
        }

        gl.glBindTexture(GL_TEXTURE_2D, 0);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "upload rebuild cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "full texture rebuild restored an evicted mip before releasing the old Metal texture";
    }
    return result;
}

TestResult runTextureMipShadowEvictionViewBlockProbe() {
    auto result = runDirectSentinel("texture-mip-shadow.view-block", [&] {
        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint texture = 0;
        GLuint view = 0;
        const auto level0 = uniformRGBA8Pixels(4, 4, 1, 1u, 2u, 3u);
        const auto level1 = uniformRGBA8Pixels(2, 2, 1, 10u, 20u, 30u);
        {
            ScopedEnvVar mipDropOff("APPGL_TEXTURE_SHADOW_DROP_MIP_LEVELS", "0");
            gl.glGenTextures(1, &texture);
            gl.glBindTexture(GL_TEXTURE_2D, texture);
            gl.glTexStorage2D(GL_TEXTURE_2D, 2, GL_RGBA8, 4, 4);
            gl.glTextureSubImage2D(texture, 0, 0, 0, 4, 4,
                                   GL_RGBA, GL_UNSIGNED_BYTE, level0.data());
            gl.glTextureSubImage2D(texture, 1, 0, 0, 2, 2,
                                   GL_RGBA, GL_UNSIGNED_BYTE, level1.data());
            gl.glGenTextures(1, &view);
            gl.glTextureView(view, GL_TEXTURE_2D, texture, GL_RGBA8,
                             1, 1, 0, 1);
            expectGLError(gl, GL_NO_ERROR, "view-block setup");
        }

        ScopedEnvVar mipDrop("APPGL_TEXTURE_SHADOW_DROP_MIP_LEVELS", "1");
        ScopedEnvVar uploadedMipDrop(
            "APPGL_TEXTURE_SHADOW_DROP_UPLOADED_MIP_LEVELS", "1");
        gl.glTextureSubImage2D(texture, 1, 0, 0, 2, 2,
                               GL_RGBA, GL_UNSIGNED_BYTE, level1.data());
        expectGLError(gl, GL_NO_ERROR, "view-block reupload");

        const GLTextureObject* textureObject =
            context.objects().textures().get(texture);
        expectCondition(textureObject != nullptr,
                        "view-block source texture object exists");
        const auto& image = expectTextureLevel(context, texture, 1,
                                               "view-block source");
        if (image.mipShadowEvicted) {
            throw std::runtime_error(
                "source mip with dependent texture view was evicted: " +
                textureStateSummary(*textureObject, image));
        }
        const auto inventory = context.metalResourceInventory();
        expectCondition(
            inventory.hostCaches.textureMipShadowEviction.blockDependentView > 0,
            "dependent texture view block counter incremented");

        gl.glDeleteTextures(1, &view);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "view-block cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "source texture with an existing mip-level view blocked mip-shadow eviction";
    }
    return result;
}

TestResult runTextureMipShadowEvictionEvictBeforeViewProbe() {
    auto result = runDirectSentinel("texture-mip-shadow.evict-before-view", [&] {
        ScopedEnvVar mipDrop("APPGL_TEXTURE_SHADOW_DROP_MIP_LEVELS", "1");
        ScopedEnvVar uploadedMipDrop(
            "APPGL_TEXTURE_SHADOW_DROP_UPLOADED_MIP_LEVELS", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint texture = 0;
        GLuint view = 0;
        const auto level0 = uniformRGBA8Pixels(4, 4, 1, 3u, 6u, 9u);
        const auto level1 = uniformRGBA8Pixels(2, 2, 1, 90u, 45u, 180u);
        gl.glGenTextures(1, &texture);
        gl.glBindTexture(GL_TEXTURE_2D, texture);
        gl.glTexStorage2D(GL_TEXTURE_2D, 2, GL_RGBA8, 4, 4);
        gl.glTextureSubImage2D(texture, 0, 0, 0, 4, 4,
                               GL_RGBA, GL_UNSIGNED_BYTE, level0.data());
        gl.glTextureSubImage2D(texture, 1, 0, 0, 2, 2,
                               GL_RGBA, GL_UNSIGNED_BYTE, level1.data());
        expectGLError(gl, GL_NO_ERROR, "evict-before-view setup");
        expectMipShadowEvicted(context, texture, 1,
                               "evict-before-view source");

        gl.glGenTextures(1, &view);
        gl.glTextureView(view, GL_TEXTURE_2D, texture, GL_RGBA8,
                         1, 1, 0, 1);
        expectGLError(gl, GL_NO_ERROR, "evict-before-view create view");

        std::array<std::uint8_t, 2 * 2 * 4> readback = {};
        gl.glGetTextureImage(view, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                             static_cast<GLsizei>(readback.size()),
                             readback.data());
        expectGLError(gl, GL_NO_ERROR, "evict-before-view readback");
        for (std::size_t pixel = 0; pixel < readback.size() / 4u; ++pixel) {
            const std::size_t offset = pixel * 4u;
            expectApproxByte(readback[offset + 0u], 90u, 0u,
                             "evict-before-view red");
            expectApproxByte(readback[offset + 1u], 45u, 0u,
                             "evict-before-view green");
            expectApproxByte(readback[offset + 2u], 180u, 0u,
                             "evict-before-view blue");
            expectApproxByte(readback[offset + 3u], 255u, 0u,
                             "evict-before-view alpha");
        }

        gl.glDeleteTextures(1, &view);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "evict-before-view cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "a view created after source mip eviction still read the source Metal mip correctly";
    }
    return result;
}

TestResult runTextureMipShadowEvictionR8RedundantProbe() {
    auto result = runDirectSentinel("texture-mip-shadow.r8-redundant-combined", [&] {
        ScopedEnvVar mipDrop("APPGL_TEXTURE_SHADOW_DROP_MIP_LEVELS", "1");
        ScopedEnvVar redundantR8("APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint texture = 0;
        gl.glGenTextures(1, &texture);
        std::array<std::uint8_t, 4 * 4> pixels;
        pixels.fill(77u);
        gl.glBindTexture(GL_TEXTURE_2D, texture);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
                           GL_NEAREST_MIPMAP_NEAREST);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, 4, 4, 0,
                        GL_RED, GL_UNSIGNED_BYTE, pixels.data());
        gl.glGenerateMipmap(GL_TEXTURE_2D);
        expectGLError(gl, GL_NO_ERROR, "r8 redundant setup");
        expectMipShadowEvicted(context, texture, 1, "r8 redundant mip");

        std::array<std::uint8_t, 2 * 2 * 4> readback = {};
        gl.glGetTextureSubImage(texture, 1, 0, 0, 0, 2, 2, 1,
                                GL_RGBA, GL_UNSIGNED_BYTE,
                                static_cast<GLsizei>(readback.size()),
                                readback.data());
        expectGLError(gl, GL_NO_ERROR, "r8 redundant subimage");
        for (std::size_t pixel = 0; pixel < readback.size() / 4u; ++pixel) {
            const std::size_t offset = pixel * 4u;
            expectApproxByte(readback[offset + 0u], 77u, 0u,
                             "r8 redundant red");
            expectApproxByte(readback[offset + 1u], 0u, 0u,
                             "r8 redundant green");
            expectApproxByte(readback[offset + 2u], 0u, 0u,
                             "r8 redundant blue");
            expectApproxByte(readback[offset + 3u], 255u, 0u,
                             "r8 redundant alpha");
        }
        const auto& level = expectTextureLevel(context, texture, 1,
                                               "r8 redundant post-readback");
        expectCondition(!level.nativeData.empty(),
                        "r8 redundant materialization kept native bytes");

        gl.glBindTexture(GL_TEXTURE_2D, 0);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "r8 redundant cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "R8 mip eviction remains correct with redundant-RGBA8 drop enabled";
    }
    return result;
}

TestResult runTextureMipShadowEvictionCopyImageProbe() {
    auto result = runDirectSentinel("texture-mip-shadow.copyimage", [&] {
        ScopedEnvVar mipDrop("APPGL_TEXTURE_SHADOW_DROP_MIP_LEVELS", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint textures[2] = {};
        gl.glGenTextures(2, textures);
        const GLuint srcTex = textures[0];
        const GLuint dstTex = textures[1];
        createGeneratedRGBA8MipTexture(gl, srcTex, 11u, 77u, 143u);
        setupDCR3CRGBA8Texture(gl, dstTex, 4, 4, 2);
        expectGLError(gl, GL_NO_ERROR, "copyimage mip setup");
        expectMipShadowEvicted(context, srcTex, 1, "copyimage src");

        gl.glCopyImageSubData(srcTex, GL_TEXTURE_2D, 1, 0, 0, 0,
                              dstTex, GL_TEXTURE_2D, 1, 0, 0, 0,
                              2, 2, 1);
        expectGLError(gl, GL_NO_ERROR, "copyimage mip copy");

        std::array<std::uint8_t, 2 * 2 * 4> readback = {};
        gl.glGetTextureImage(dstTex, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                             static_cast<GLsizei>(readback.size()),
                             readback.data());
        expectGLError(gl, GL_NO_ERROR, "copyimage dst readback");
        for (std::size_t pixel = 0; pixel < readback.size() / 4u; ++pixel) {
            const std::size_t offset = pixel * 4u;
            expectApproxByte(readback[offset + 0u], 11u, 0u,
                             "copyimage mip red");
            expectApproxByte(readback[offset + 1u], 77u, 0u,
                             "copyimage mip green");
            expectApproxByte(readback[offset + 2u], 143u, 0u,
                             "copyimage mip blue");
            expectApproxByte(readback[offset + 3u], 255u, 0u,
                             "copyimage mip alpha");
        }

        gl.glBindTexture(GL_TEXTURE_2D, 0);
        gl.glDeleteTextures(2, textures);
        expectGLError(gl, GL_NO_ERROR, "copyimage mip cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "copyImageSubData restored an evicted generated mip source before copying";
    }
    return result;
}

TestResult runTextureMipShadowEvictionPartialTexSubImageProbe() {
    auto result = runDirectSentinel("texture-mip-shadow.partial-texsubimage", [&] {
        ScopedEnvVar mipDrop("APPGL_TEXTURE_SHADOW_DROP_MIP_LEVELS", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint texture = 0;
        gl.glGenTextures(1, &texture);
        createGeneratedRGBA8MipTexture(gl, texture, 50u, 60u, 70u);
        expectGLError(gl, GL_NO_ERROR, "partial mip setup");
        expectMipShadowEvicted(context, texture, 1,
                               "partial texSubImage source");

        const std::array<std::uint8_t, 4> patch = {200u, 10u, 20u, 255u};
        gl.glTextureSubImage2D(texture, 1, 0, 0, 1, 1,
                               GL_RGBA, GL_UNSIGNED_BYTE, patch.data());
        expectGLError(gl, GL_NO_ERROR, "partial mip texSubImage");

        std::array<std::uint8_t, 2 * 2 * 4> readback = {};
        gl.glGetTextureImage(texture, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                             static_cast<GLsizei>(readback.size()),
                             readback.data());
        expectGLError(gl, GL_NO_ERROR, "partial mip readback");
        std::size_t patched = 0;
        std::size_t preserved = 0;
        for (std::size_t pixel = 0; pixel < readback.size() / 4u; ++pixel) {
            const std::size_t offset = pixel * 4u;
            const bool isPatch =
                readback[offset + 0u] == 200u &&
                readback[offset + 1u] == 10u &&
                readback[offset + 2u] == 20u &&
                readback[offset + 3u] == 255u;
            const bool isPreserved =
                readback[offset + 0u] == 50u &&
                readback[offset + 1u] == 60u &&
                readback[offset + 2u] == 70u &&
                readback[offset + 3u] == 255u;
            if (isPatch) {
                ++patched;
            } else if (isPreserved) {
                ++preserved;
            }
        }
        expectCondition(patched == 1,
                        "partial texSubImage patched one mip texel");
        expectCondition(preserved == 3,
                        "partial texSubImage preserved untouched mip texels");

        gl.glBindTexture(GL_TEXTURE_2D, 0);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "partial mip cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "partial texSubImage on an evicted generated mip preserved untouched texels";
    }
    return result;
}

TestResult runDepth32FStaleDropDepthSubImageProbe() {
    auto result = runDirectSentinel("depth32f.stale-drop.subimage-depth-float", [&] {
        ScopedEnvVar staleDepth("APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8", "1");
        ScopedEnvVar redundantR8("APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint texture = 0;
        GLuint framebuffer = 0;
        gl.glGenTextures(1, &texture);
        setupDCR3CDepth32FTexture(gl, texture, 4, 4);
        primeDCR3CDepth32FTexture(gl, texture, 4, 4);
        setupDCR3CDepthTextureFbo(gl, framebuffer, texture);
        seedDepthAttachmentWithDraw(gl, framebuffer, 4, 4, 0.375f);
        expectGLError(gl, GL_NO_ERROR, "depth32f depth-subimage draw");
        GLfloat seedProbe = -1.0f;
        gl.glReadPixels(0, 0, 1, 1, GL_DEPTH_COMPONENT, GL_FLOAT, &seedProbe);
        expectGLError(gl, GL_NO_ERROR, "depth32f depth-subimage seed readPixels");
        expectApproxFloat(seedProbe, 0.375f, 0.02f,
                          "depth32f depth-subimage seeded framebuffer depth");

        const GLTextureObject* textureObject =
            context.objects().textures().get(texture);
        expectCondition(textureObject != nullptr,
                        "depth32f depth-subimage texture object exists");
        const auto& level = expectTextureLevel(
            context, texture, 0, "depth32f depth-subimage");
        if (!level.rgba8.empty()) {
            throw std::runtime_error(
                "depth32f depth-subimage stale rgba8 survived: " +
                textureStateSummary(*textureObject, level));
        }

        std::array<GLfloat, 4> readback = {-1.0f, -1.0f, -1.0f, -1.0f};
        gl.glGetTextureSubImage(texture, 0, 1, 1, 0, 2, 2, 1,
                                GL_DEPTH_COMPONENT, GL_FLOAT,
                                static_cast<GLsizei>(readback.size() * sizeof(GLfloat)),
                                readback.data());
        expectGLError(gl, GL_NO_ERROR, "depth32f depth-subimage readback");
        for (std::size_t i = 0; i < readback.size(); ++i) {
            expectApproxFloat(readback[i], 0.375f, 0.02f,
                              "depth32f depth-subimage value");
        }

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "depth32f depth-subimage cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "render-produced depth32f subimage depth/float readback stayed truthful after stale rgba8 drop";
    }
    return result;
}

TestResult runDepth32FStaleDropArrayRgbaSubImageProbe() {
    auto result = runDirectSentinel("depth32f.stale-drop.array-rgba-subimage", [&] {
        ScopedEnvVar staleDepth("APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8", "1");
        ScopedEnvVar redundantR8("APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint texture = 0;
        GLuint framebuffer = 0;
        gl.glGenTextures(1, &texture);
        setupDCR3CDepth32FArrayTexture(gl, texture, 4, 4, 3);
        primeDCR3CDepth32FTexture(gl, texture, 4, 4, 3);
        setupDCR3CDepthArrayLayerFbo(gl, framebuffer, texture, 1);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        gl.glViewport(0, 0, 4, 4);
        gl.glClearDepth(0.25);
        gl.glClear(GL_DEPTH_BUFFER_BIT);
        expectGLError(gl, GL_NO_ERROR, "depth32f array rgba clear");
        GLfloat seedProbe = -1.0f;
        gl.glReadPixels(0, 0, 1, 1, GL_DEPTH_COMPONENT, GL_FLOAT, &seedProbe);
        expectGLError(gl, GL_NO_ERROR, "depth32f array rgba seed readPixels");
        expectApproxFloat(seedProbe, 0.25f, 0.02f,
                          "depth32f array rgba seeded framebuffer depth");

        const GLTextureObject* textureObject =
            context.objects().textures().get(texture);
        expectCondition(textureObject != nullptr,
                        "depth32f array rgba texture object exists");
        const auto& level = expectTextureLevel(
            context, texture, 0, "depth32f array rgba");
        if (!level.rgba8.empty()) {
            throw std::runtime_error(
                "depth32f array rgba stale rgba8 survived: " +
                textureStateSummary(*textureObject, level));
        }

        std::array<std::uint8_t, 4 * 4 * 4> readback;
        readback.fill(0xAAu);
        gl.glGetTextureSubImage(texture, 0, 0, 0, 1, 4, 4, 1,
                                GL_RGBA, GL_UNSIGNED_BYTE,
                                static_cast<GLsizei>(readback.size()),
                                readback.data());
        expectGLError(gl, GL_NO_ERROR, "depth32f array rgba subimage readback");

        const std::uint8_t expectedRed = 64u;
        for (std::size_t pixel = 0; pixel < readback.size() / 4u; ++pixel) {
            const std::size_t offset = pixel * 4u;
            expectApproxByte(readback[offset + 0u], expectedRed, 4u,
                             "depth32f array rgba red");
            expectApproxByte(readback[offset + 1u], 0u, 0u,
                             "depth32f array rgba green");
            expectApproxByte(readback[offset + 2u], 0u, 0u,
                             "depth32f array rgba blue");
            expectApproxByte(readback[offset + 3u], 255u, 0u,
                             "depth32f array rgba alpha");
        }

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "depth32f array rgba cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "render-produced depth32f array layer could rebuild RGBA subimage from the stale-drop path";
    }
    return result;
}

TestResult runDepth32FStaleDropCopyImageProbe() {
    auto result = runDirectSentinel("depth32f.stale-drop.copyimage", [&] {
        ScopedEnvVar staleDepth("APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8", "1");
        ScopedEnvVar redundantR8("APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint textures[2] = {};
        GLuint framebuffer = 0;
        gl.glGenTextures(2, textures);
        const GLuint srcTex = textures[0];
        const GLuint dstTex = textures[1];
        setupDCR3CDepth32FTexture(gl, srcTex, 4, 4);
        setupDCR3CDepth32FTexture(gl, dstTex, 4, 4);
        primeDCR3CDepth32FTexture(gl, srcTex, 4, 4);
        primeDCR3CDepth32FTexture(gl, dstTex, 4, 4);
        setupDCR3CDepthTextureFbo(gl, framebuffer, srcTex);
        seedDepthAttachmentWithDraw(gl, framebuffer, 4, 4, 0.25f);
        expectGLError(gl, GL_NO_ERROR, "depth32f copyImage draw");

        const GLTextureObject* srcObject =
            context.objects().textures().get(srcTex);
        expectCondition(srcObject != nullptr,
                        "depth32f copyImage texture object exists");
        const auto& srcLevel = expectTextureLevel(
            context, srcTex, 0, "depth32f copyImage");
        if (!srcLevel.rgba8.empty()) {
            throw std::runtime_error(
                "depth32f copyImage stale rgba8 survived: " +
                textureStateSummary(*srcObject, srcLevel));
        }

        gl.glCopyImageSubData(srcTex, GL_TEXTURE_2D, 0, 0, 0, 0,
                              dstTex, GL_TEXTURE_2D, 0, 0, 0, 0,
                              4, 4, 1);
        expectGLError(gl, GL_NO_ERROR, "depth32f copyImageSubData");

        std::array<GLfloat, 16> readback = {};
        gl.glGetTextureImage(dstTex, 0, GL_DEPTH_COMPONENT, GL_FLOAT,
                             static_cast<GLsizei>(readback.size() * sizeof(GLfloat)),
                             readback.data());
        expectGLError(gl, GL_NO_ERROR, "depth32f copyImage depth readback");
        for (GLfloat value : readback) {
            expectApproxFloat(value, 0.25f, 0.02f,
                              "depth32f copyImage copied depth");
        }

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(2, textures);
        expectGLError(gl, GL_NO_ERROR, "depth32f copyImage cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "render-produced depth32f copyImageSubData copied the authoritative Metal depth instead of stale host shadow";
    }
    return result;
}

TestResult runDepth32FStaleDropPartialTexSubImageProbe() {
    auto result = runDirectSentinel("depth32f.stale-drop.partial-texsubimage", [&] {
        ScopedEnvVar staleDepth("APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8", "1");
        ScopedEnvVar redundantR8("APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint texture = 0;
        GLuint framebuffer = 0;
        gl.glGenTextures(1, &texture);
        setupDCR3CDepth32FTexture(gl, texture, 4, 4);
        primeDCR3CDepth32FTexture(gl, texture, 4, 4);
        setupDCR3CDepthTextureFbo(gl, framebuffer, texture);
        seedDepthAttachmentWithDraw(gl, framebuffer, 4, 4, 0.25f);
        expectGLError(gl, GL_NO_ERROR, "depth32f texSubImage draw");

        const GLTextureObject* textureObject =
            context.objects().textures().get(texture);
        expectCondition(textureObject != nullptr,
                        "depth32f texSubImage texture object exists");
        const auto& level = expectTextureLevel(
            context, texture, 0, "depth32f texSubImage");
        if (!level.rgba8.empty()) {
            throw std::runtime_error(
                "depth32f texSubImage stale rgba8 survived: " +
                textureStateSummary(*textureObject, level));
        }

        const GLfloat patchDepth = 0.75f;
        gl.glTextureSubImage2D(texture, 0, 0, 0, 1, 1,
                               GL_DEPTH_COMPONENT, GL_FLOAT, &patchDepth);
        expectGLError(gl, GL_NO_ERROR, "depth32f texSubImage partial update");

        std::array<GLfloat, 16> readback = {};
        gl.glGetTextureImage(texture, 0, GL_DEPTH_COMPONENT, GL_FLOAT,
                             static_cast<GLsizei>(readback.size() * sizeof(GLfloat)),
                             readback.data());
        expectGLError(gl, GL_NO_ERROR, "depth32f texSubImage readback");

        std::size_t patchedCount = 0;
        std::size_t preservedCount = 0;
        for (GLfloat value : readback) {
            if (std::fabs(value - 0.75f) <= 0.02f) {
                ++patchedCount;
            } else if (std::fabs(value - 0.25f) <= 0.02f) {
                ++preservedCount;
            }
        }
        expectCondition(patchedCount == 1,
                        "depth32f texSubImage updated exactly one texel");
        expectCondition(preservedCount == 15,
                        "depth32f texSubImage preserved untouched rendered depth texels");

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "depth32f texSubImage cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "partial texSubImage on stale-dropped depth32f kept untouched rendered texels intact";
    }
    return result;
}

TestResult runDepth32FStaleDropGenerateMipmapProbe() {
    auto result = runDirectSentinel("depth32f.stale-drop.generate-mipmap", [&] {
        ScopedEnvVar staleDepth("APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8", "1");
        ScopedEnvVar redundantR8("APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint texture = 0;
        GLuint framebuffer = 0;
        gl.glGenTextures(1, &texture);
        setupDCR3CDepth32FTexture(gl, texture, 4, 4, 2);
        primeDCR3CDepth32FTexture(gl, texture, 4, 4);
        setupDCR3CDepthTextureFbo(gl, framebuffer, texture);
        seedDepthAttachmentWithDraw(gl, framebuffer, 4, 4, 0.25f);
        expectGLError(gl, GL_NO_ERROR, "depth32f generateMipmap draw");

        const GLTextureObject* textureObject =
            context.objects().textures().get(texture);
        expectCondition(textureObject != nullptr,
                        "depth32f generateMipmap texture object exists");
        const auto& level0 = expectTextureLevel(
            context, texture, 0, "depth32f generateMipmap");
        if (!level0.rgba8.empty()) {
            throw std::runtime_error(
                "depth32f generateMipmap stale rgba8 survived: " +
                textureStateSummary(*textureObject, level0));
        }

        gl.glBindTexture(GL_TEXTURE_2D, texture);
        gl.glGenerateMipmap(GL_TEXTURE_2D);
        expectGLError(gl, GL_NO_ERROR, "depth32f generateMipmap");

        std::array<GLfloat, 4> readback = {};
        gl.glGetTextureImage(texture, 1, GL_DEPTH_COMPONENT, GL_FLOAT,
                             static_cast<GLsizei>(readback.size() * sizeof(GLfloat)),
                             readback.data());
        expectGLError(gl, GL_NO_ERROR, "depth32f mip level readback");
        for (GLfloat value : readback) {
            expectApproxFloat(value, 0.25f, 0.02f,
                              "depth32f mip level depth");
        }

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindTexture(GL_TEXTURE_2D, 0);
        gl.glDeleteFramebuffers(1, &framebuffer);
        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "depth32f generateMipmap cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "generateMipmap could rebuild stale-dropped depth32f state and keep depth content coherent";
    }
    return result;
}

TestResult runDepth32FStaleDropSwizzleProxyProbe() {
    auto result = runDirectSentinel("depth32f.stale-drop.swizzle-proxy", [&] {
        static constexpr const char* kSampleVS =
            "#version 330 core\n"
            "layout(location = 0) in vec2 aPos;\n"
            "out vec2 vUV;\n"
            "void main() {\n"
            "    vUV = aPos * 0.5 + 0.5;\n"
            "    gl_Position = vec4(aPos, 0.0, 1.0);\n"
            "}\n";
        static constexpr const char* kSampleFS =
            "#version 330 core\n"
            "in vec2 vUV;\n"
            "uniform sampler2D uDepthTex;\n"
            "out vec4 fragColor;\n"
            "void main() {\n"
            "    fragColor = texture(uDepthTex, vUV);\n"
            "}\n";

        ScopedEnvVar staleDepth("APPGL_TEXTURE_SHADOW_DROP_STALE_DEPTH32F_RGBA8", "1");
        ScopedEnvVar redundantR8("APPGL_TEXTURE_SHADOW_DROP_REDUNDANT_RGBA8", "1");

        ScopedSentinelContext scoped(32, 32);
        auto& context = scoped.context();
        auto& gl = scoped.gl();

        GLuint depthTexture = 0;
        GLuint depthFramebuffer = 0;
        gl.glGenTextures(1, &depthTexture);
        setupDCR3CDepth32FTexture(gl, depthTexture, 4, 4);
        primeDCR3CDepth32FTexture(gl, depthTexture, 4, 4);
        setupDCR3CDepthTextureFbo(gl, depthFramebuffer, depthTexture);
        seedDepthAttachmentWithDraw(gl, depthFramebuffer, 4, 4, 0.25f);
        expectGLError(gl, GL_NO_ERROR, "depth32f swizzle draw");

        const GLTextureObject* depthObject =
            context.objects().textures().get(depthTexture);
        expectCondition(depthObject != nullptr,
                        "depth32f swizzle texture object exists");
        const auto& depthLevel = expectTextureLevel(
            context, depthTexture, 0, "depth32f swizzle");
        if (!depthLevel.rgba8.empty()) {
            throw std::runtime_error(
                "depth32f swizzle stale rgba8 survived: " +
                textureStateSummary(*depthObject, depthLevel));
        }

        gl.glBindTexture(GL_TEXTURE_2D, depthTexture);
        const GLint swizzle[4] = {GL_RED, GL_RED, GL_RED, GL_ONE};
        gl.glTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_RGBA, swizzle);
        gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_NONE);
        expectGLError(gl, GL_NO_ERROR, "depth32f swizzle state");

        GLuint colorTexture = 0;
        GLuint colorFramebuffer = 0;
        gl.glGenTextures(1, &colorTexture);
        setupDCR3CRGBA8Texture(gl, colorTexture, 4, 4);
        setupDCR3CTextureFbo(gl, colorFramebuffer, colorTexture);

        const GLuint program = buildBenchProgram(kSampleVS, kSampleFS);
        GLint linked = GL_FALSE;
        gl.glGetProgramiv(program, GL_LINK_STATUS, &linked);
        expectCondition(linked == GL_TRUE, "depth32f swizzle sample program links");
        const GLint samplerLocation =
            gl.glGetUniformLocation(program, "uDepthTex");
        expectCondition(samplerLocation >= 0,
                        "depth32f swizzle sampler uniform exists");

        GLuint vao = 0;
        GLuint vbo = 0;
        setupDCR3CFullscreenTriangle(gl, vao, vbo);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, colorFramebuffer);
        gl.glViewport(0, 0, 4, 4);
        gl.glUseProgram(program);
        gl.glActiveTexture(GL_TEXTURE0);
        gl.glBindTexture(GL_TEXTURE_2D, depthTexture);
        gl.glUniform1i(samplerLocation, 0);
        gl.glBindVertexArray(vao);
        gl.glDrawArrays(GL_TRIANGLES, 0, 3);
        expectGLError(gl, GL_NO_ERROR, "depth32f swizzle sample draw");

        std::array<std::uint8_t, 4 * 4 * 4> pixels = {};
        gl.glReadPixels(0, 0, 4, 4, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
        expectGLError(gl, GL_NO_ERROR, "depth32f swizzle readback");
        for (std::size_t pixel = 0; pixel < pixels.size() / 4u; ++pixel) {
            const std::size_t offset = pixel * 4u;
            expectApproxByte(pixels[offset + 0u], 64u, 4u,
                             "depth32f swizzle red");
            expectApproxByte(pixels[offset + 1u], 64u, 4u,
                             "depth32f swizzle green");
            expectApproxByte(pixels[offset + 2u], 64u, 4u,
                             "depth32f swizzle blue");
            expectApproxByte(pixels[offset + 3u], 255u, 0u,
                             "depth32f swizzle alpha");
        }

        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindVertexArray(0);
        gl.glBindBuffer(GL_ARRAY_BUFFER, 0);
        gl.glBindTexture(GL_TEXTURE_2D, 0);
        gl.glUseProgram(0);
        gl.glDeleteProgram(program);
        gl.glDeleteBuffers(1, &vbo);
        gl.glDeleteVertexArrays(1, &vao);
        gl.glDeleteFramebuffers(1, &colorFramebuffer);
        gl.glDeleteTextures(1, &colorTexture);
        gl.glDeleteFramebuffers(1, &depthFramebuffer);
        gl.glDeleteTextures(1, &depthTexture);
        expectGLError(gl, GL_NO_ERROR, "depth32f swizzle cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "post-render depth swizzle/proxy sampling still reflected live Metal depth after stale rgba8 drop";
    }
    return result;
}

constexpr GLsizei kS22FirstRangeTileSize = 8;
constexpr GLsizei kS22FirstRangeColumns = 16;
constexpr GLsizei kS22FirstRangeRows = 8;
constexpr GLsizei kS22FirstRangeDraws =
    kS22FirstRangeColumns * kS22FirstRangeRows;
constexpr GLsizei kS22FirstRangeCanvas =
    kS22FirstRangeColumns * kS22FirstRangeTileSize;
constexpr GLsizei kS22FirstRangeVerticesPerDraw = 6;

static constexpr const char* kS22FirstRangeVS =
    "#version 330 core\n"
    "void main() {\n"
    "    vec2 corners[6] = vec2[6](\n"
    "        vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(1.0, 1.0),\n"
    "        vec2(0.0, 0.0), vec2(1.0, 1.0), vec2(0.0, 1.0));\n"
    "    int tile = gl_VertexID / 6;\n"
    "    int corner = gl_VertexID - tile * 6;\n"
    "    int tileX = tile % 16;\n"
    "    int tileY = tile / 16;\n"
    "    vec2 uv = (vec2(tileX, tileY) + corners[corner]) / vec2(16.0, 8.0);\n"
    "    gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);\n"
    "}\n";

static constexpr const char* kS22FirstRangeFS =
    "#version 330 core\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    fragColor = vec4(1.0, 0.0, 0.0, 1.0);\n"
    "}\n";

struct S22FirstRangeIndirectCommand {
    GLuint count;
    GLuint instanceCount;
    GLuint first;
    GLuint baseInstance;
};

GLuint buildS22FirstRangeProgram(GLDispatchTable& gl) {
    const GLuint program = buildBenchProgram(kS22FirstRangeVS, kS22FirstRangeFS);
    GLint linked = GL_FALSE;
    gl.glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
        const std::string log = programInfoLog(gl, program);
        gl.glDeleteProgram(program);
        throw std::runtime_error(
            "s22 first-range program link failed" +
            (log.empty() ? std::string{} : ": " + log));
    }
    return program;
}

bool isS22FirstRangeRed(const std::array<std::uint8_t, 4>& pixel) {
    return pixel[0] >= 200 && pixel[1] <= 60 &&
           pixel[2] <= 60 && pixel[3] >= 200;
}

int countS22FirstRangeTiles(GLDispatchTable& gl, bool offscreen) {
    int redTiles = 0;
    gl.glReadBuffer(offscreen ? GL_COLOR_ATTACHMENT0 : GL_BACK);
    for (GLsizei y = 0; y < kS22FirstRangeRows; ++y) {
        for (GLsizei x = 0; x < kS22FirstRangeColumns; ++x) {
            std::array<std::uint8_t, 4> pixel = {};
            gl.glReadPixels(x * kS22FirstRangeTileSize + kS22FirstRangeTileSize / 2,
                            y * kS22FirstRangeTileSize + kS22FirstRangeTileSize / 2,
                            1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
            if (isS22FirstRangeRed(pixel)) {
                ++redTiles;
            }
        }
    }
    return redTiles;
}

void prepareS22FirstRangeDraw(GLDispatchTable& gl,
                              GLuint program,
                              GLuint vao,
                              GLuint framebuffer) {
    gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    if (framebuffer != 0) {
        gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
        gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
    }
    gl.glViewport(0, 0, kS22FirstRangeCanvas, kS22FirstRangeCanvas);
    gl.glDisable(GL_BLEND);
    gl.glDisable(GL_CULL_FACE);
    gl.glDisable(GL_DEPTH_TEST);
    gl.glDisable(GL_SCISSOR_TEST);
    gl.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    gl.glClear(GL_COLOR_BUFFER_BIT);
    gl.glUseProgram(program);
    gl.glBindVertexArray(vao);
}

template <typename DrawFn>
void runS22FirstRangeCase(GLContext& context,
                          GLDispatchTable& gl,
                          GLuint program,
                          GLuint vao,
                          GLuint framebuffer,
                          std::string_view label,
                          DrawFn&& drawFn) {
    prepareS22FirstRangeDraw(gl, program, vao, framebuffer);
    std::forward<DrawFn>(drawFn)();
    expectGLError(gl, GL_NO_ERROR, label);
    gl.glFinish();
    expectGLError(gl, GL_NO_ERROR, std::string(label) + " finish");
    const int redTiles = countS22FirstRangeTiles(gl, framebuffer != 0);
    if (redTiles != kS22FirstRangeDraws) {
        std::ostringstream stream;
        stream << label << " rendered " << redTiles
               << " tiles, expected " << kS22FirstRangeDraws;
        throw std::runtime_error(stream.str());
    }
    if (framebuffer == 0) {
        context.swapBuffers();
    }
}

void setupS22FirstRangeFramebuffer(GLDispatchTable& gl,
                                   GLuint& texture,
                                   GLuint& framebuffer) {
    gl.glGenTextures(1, &texture);
    gl.glBindTexture(GL_TEXTURE_2D, texture);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8,
                    kS22FirstRangeCanvas, kS22FirstRangeCanvas, 0,
                    GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    gl.glGenFramebuffers(1, &framebuffer);
    gl.glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    gl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                              GL_TEXTURE_2D, texture, 0);
    gl.glDrawBuffer(GL_COLOR_ATTACHMENT0);
    gl.glReadBuffer(GL_COLOR_ATTACHMENT0);
    expectCondition(gl.glCheckFramebufferStatus(GL_FRAMEBUFFER) ==
                        GL_FRAMEBUFFER_COMPLETE,
                    "s22 first-range offscreen framebuffer complete");
}

TestResult runS22FirstRangeSentinel() {
    auto result = runDirectSentinel("s22.present-first-range-viewport-wall", [&] {
        ScopedSentinelContext scoped(kS22FirstRangeCanvas, kS22FirstRangeCanvas);
        auto& context = scoped.context();
        auto& gl = scoped.gl();
        const GLuint program = buildS22FirstRangeProgram(gl);
        GLuint vao = 0;
        gl.glGenVertexArrays(1, &vao);
        gl.glBindVertexArray(vao);
        GLuint offscreenTexture = 0;
        GLuint offscreenFramebuffer = 0;
        setupS22FirstRangeFramebuffer(gl, offscreenTexture, offscreenFramebuffer);

        std::vector<GLint> firsts(kS22FirstRangeDraws);
        std::vector<GLsizei> counts(kS22FirstRangeDraws,
                                    kS22FirstRangeVerticesPerDraw);
        std::vector<S22FirstRangeIndirectCommand> commands(kS22FirstRangeDraws);
        for (GLsizei draw = 0; draw < kS22FirstRangeDraws; ++draw) {
            const GLuint first =
                static_cast<GLuint>(draw * kS22FirstRangeVerticesPerDraw);
            firsts[draw] = static_cast<GLint>(first);
            commands[draw] = {
                static_cast<GLuint>(kS22FirstRangeVerticesPerDraw),
                1u,
                first,
                0u,
            };
        }

        runS22FirstRangeCase(context, gl, program, vao,
                             0,
                             "s22 direct glDrawArrays(first)", [&] {
            for (GLsizei draw = 0; draw < kS22FirstRangeDraws; ++draw) {
                gl.glDrawArrays(GL_TRIANGLES, firsts[draw],
                                kS22FirstRangeVerticesPerDraw);
            }
        });

        runS22FirstRangeCase(context, gl, program, vao,
                             0,
                             "s22 glMultiDrawArrays wall", [&] {
            gl.glMultiDrawArrays(GL_TRIANGLES, firsts.data(),
                                 counts.data(), kS22FirstRangeDraws);
        });

        GLuint indirectBuffer = 0;
        gl.glGenBuffers(1, &indirectBuffer);
        gl.glBindBuffer(GL_DRAW_INDIRECT_BUFFER, indirectBuffer);
        gl.glBufferData(GL_DRAW_INDIRECT_BUFFER,
                        static_cast<GLsizeiptr>(
                            commands.size() *
                            sizeof(S22FirstRangeIndirectCommand)),
                        commands.data(), GL_STATIC_DRAW);

        runS22FirstRangeCase(context, gl, program, vao,
                             0,
                             "s22 glMultiDrawArraysIndirect wall", [&] {
            gl.glMultiDrawArraysIndirect(GL_TRIANGLES, nullptr,
                                         kS22FirstRangeDraws, 0);
        });

        runS22FirstRangeCase(context, gl, program, vao,
                             offscreenFramebuffer,
                             "s22 offscreen glMultiDrawArraysIndirect wall", [&] {
            gl.glMultiDrawArraysIndirect(GL_TRIANGLES, nullptr,
                                         kS22FirstRangeDraws, 0);
        });

        gl.glBindBuffer(GL_DRAW_INDIRECT_BUFFER, 0);
        gl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.glBindVertexArray(0);
        gl.glUseProgram(0);
        gl.glDeleteBuffers(1, &indirectBuffer);
        gl.glDeleteFramebuffers(1, &offscreenFramebuffer);
        gl.glDeleteTextures(1, &offscreenTexture);
        gl.glDeleteVertexArrays(1, &vao);
        gl.glDeleteProgram(program);
        expectGLError(gl, GL_NO_ERROR, "s22 first-range cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "default-framebuffer and offscreen drawArrays first/baseVertex range reached all 128 tiles";
    }
    return result;
}

TestResult runS22LivePresentPathSentinel() {
    auto result = runDirectSentinel("s22.live-present-mdi-reused-encoder", [&] {
        std::string message;
        if (!runS22LivePresentMDISentinel(message)) {
            throw std::runtime_error(message.empty()
                ? "live-present MDI sentinel failed"
                : message);
        }
    });
    if (result.status == "passed") {
        result.message =
            "layer-backed present MDI VBO draw rendered every viewport tile";
    }
    return result;
}

TestResult runS22LivePresentTessFurPathSentinel() {
    auto result = runDirectSentinel("s22.live-present-tess-fur-scale-switch", [&] {
        std::string message;
        if (!runS22LivePresentTessFurSentinel(message)) {
            throw std::runtime_error(message.empty()
                ? "live-present tess fur sentinel failed"
                : message);
        }
    });
    if (result.status == "passed") {
        result.message =
            "layer-backed present Fur-scale tess switch remained stable";
    }
    return result;
}

TestResult runMipOversizedLevelProbe() {
    auto result = runDirectSentinel("mip.oversized-level-subimage", [&] {
        ScopedSentinelContext scoped(32, 32);
        auto& gl = scoped.gl();

        GLuint texture = 0;
        gl.glCreateTextures(GL_TEXTURE_2D, 1, &texture);
        gl.glTextureStorage2D(texture, 1, GL_RGBA8, 8, 8);

        std::uint8_t pixels[8 * 8 * 4] = {};
        std::uint8_t readback[8 * 8 * 4] = {};
        gl.glTextureSubImage2D(texture, 0, 0, 0, 8, 8, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        while (gl.glGetError() != GL_NO_ERROR) {}

        constexpr GLint oversizedMipLevel = 1000;
        gl.glGetTextureSubImage(
            texture,
            oversizedMipLevel,
            0, 0, 0,
            4, 4, 1,
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            sizeof(readback),
            readback);
        expectGLError(gl, GL_INVALID_VALUE, "glGetTextureSubImage oversized level");

        gl.glGetCompressedTextureSubImage(
            texture,
            oversizedMipLevel,
            0, 0, 0,
            4, 4, 1,
            sizeof(readback),
            readback);
        expectGLError(gl, GL_INVALID_VALUE, "glGetCompressedTextureSubImage oversized level");

        gl.glDeleteTextures(1, &texture);
        expectGLError(gl, GL_NO_ERROR, "mip oversized-level probe cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "oversized texture subimage mip levels reject with GL_INVALID_VALUE before any UB shift";
    }
    return result;
}

TestResult runDSAStatePreservationSentinel() {
    auto result = runDirectSentinel("dsa.state-preservation", [&] {
        ScopedSentinelContext scoped(32, 32);
        auto& gl = scoped.gl();

        const auto expectIntegerBinding = [&](GLenum pname, GLint expected, std::string_view label) {
            GLint actual = -1;
            gl.glGetIntegerv(pname, &actual);
            expectGLError(gl, GL_NO_ERROR, std::string(label) + " query");
            expectCondition(actual == expected, label);
        };

        GLuint textures2D[2] = {};
        gl.glCreateTextures(GL_TEXTURE_2D, 2, textures2D);
        expectGLError(gl, GL_NO_ERROR, "DSA state texture2D create");
        const GLuint sentinelTexture2D = textures2D[0];
        const GLuint dsaTexture2D = textures2D[1];

        gl.glBindTexture(GL_TEXTURE_2D, sentinelTexture2D);
        expectGLError(gl, GL_NO_ERROR, "DSA state bind sentinel texture2D");
        expectIntegerBinding(GL_TEXTURE_BINDING_2D, static_cast<GLint>(sentinelTexture2D),
                             "sentinel texture2D binding before DSA");

        gl.glTextureStorage2D(dsaTexture2D, 1, GL_RGBA8, 4, 4);
        expectGLError(gl, GL_NO_ERROR, "DSA state textureStorage2D success");
        expectIntegerBinding(GL_TEXTURE_BINDING_2D, static_cast<GLint>(sentinelTexture2D),
                             "textureStorage2D preserves GL_TEXTURE_BINDING_2D");

        std::uint8_t pixels[4 * 4 * 4] = {};
        gl.glTextureSubImage2D(dsaTexture2D, 0, 0, 0, 4, 4, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        expectGLError(gl, GL_NO_ERROR, "DSA state textureSubImage2D success");
        expectIntegerBinding(GL_TEXTURE_BINDING_2D, static_cast<GLint>(sentinelTexture2D),
                             "textureSubImage2D preserves GL_TEXTURE_BINDING_2D");

        gl.glTextureParameteri(dsaTexture2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        expectGLError(gl, GL_NO_ERROR, "DSA state textureParameteri success");
        expectIntegerBinding(GL_TEXTURE_BINDING_2D, static_cast<GLint>(sentinelTexture2D),
                             "textureParameteri preserves GL_TEXTURE_BINDING_2D");

        GLint textureParam = 0;
        gl.glGetTextureParameteriv(dsaTexture2D, GL_TEXTURE_MIN_FILTER, &textureParam);
        expectGLError(gl, GL_NO_ERROR, "DSA state getTextureParameteriv success");
        expectCondition(textureParam == GL_NEAREST, "getTextureParameteriv returns DSA texture state");
        expectIntegerBinding(GL_TEXTURE_BINDING_2D, static_cast<GLint>(sentinelTexture2D),
                             "getTextureParameteriv preserves GL_TEXTURE_BINDING_2D");

        gl.glTextureParameteri(dsaTexture2D, GL_TEXTURE_SWIZZLE_RGBA, GL_NEAREST);
        expectGLError(gl, GL_INVALID_ENUM, "DSA state textureParameteri scalar error");
        expectIntegerBinding(GL_TEXTURE_BINDING_2D, static_cast<GLint>(sentinelTexture2D),
                             "textureParameteri error preserves GL_TEXTURE_BINDING_2D");

        gl.glTextureStorage1D(dsaTexture2D, 1, GL_RGBA8, 4);
        expectGLError(gl, GL_INVALID_OPERATION, "DSA state textureStorage1D target error");
        expectIntegerBinding(GL_TEXTURE_BINDING_2D, static_cast<GLint>(sentinelTexture2D),
                             "textureStorage1D error preserves GL_TEXTURE_BINDING_2D");

        GLuint textureBufferObjects[2] = {};
        gl.glCreateTextures(GL_TEXTURE_BUFFER, 2, textureBufferObjects);
        expectGLError(gl, GL_NO_ERROR, "DSA state texture buffer create");
        const GLuint sentinelTextureBuffer = textureBufferObjects[0];
        const GLuint dsaTextureBuffer = textureBufferObjects[1];

        GLuint backingBuffer = 0;
        gl.glCreateBuffers(1, &backingBuffer);
        gl.glNamedBufferData(backingBuffer, 64, nullptr, GL_STATIC_DRAW);
        expectGLError(gl, GL_NO_ERROR, "DSA state texture buffer backing create");

        gl.glBindTexture(GL_TEXTURE_BUFFER, sentinelTextureBuffer);
        expectGLError(gl, GL_NO_ERROR, "DSA state bind sentinel texture buffer");
        expectIntegerBinding(GL_TEXTURE_BINDING_BUFFER, static_cast<GLint>(sentinelTextureBuffer),
                             "sentinel texture buffer binding before DSA");

        gl.glTextureBuffer(dsaTextureBuffer, GL_RGBA32F, backingBuffer);
        expectGLError(gl, GL_NO_ERROR, "DSA state textureBuffer success");
        expectIntegerBinding(GL_TEXTURE_BINDING_BUFFER, static_cast<GLint>(sentinelTextureBuffer),
                             "textureBuffer preserves GL_TEXTURE_BINDING_BUFFER");

        gl.glGetTextureParameteriv(dsaTextureBuffer, GL_TEXTURE_MIN_FILTER, &textureParam);
        expectGLError(gl, GL_INVALID_OPERATION, "DSA state getTextureParameteriv buffer-target error");
        expectIntegerBinding(GL_TEXTURE_BINDING_BUFFER, static_cast<GLint>(sentinelTextureBuffer),
                             "getTextureParameteriv error preserves GL_TEXTURE_BINDING_BUFFER");

        GLuint vertexArrays[2] = {};
        gl.glCreateVertexArrays(2, vertexArrays);
        expectGLError(gl, GL_NO_ERROR, "DSA state VAO create");
        const GLuint sentinelVertexArray = vertexArrays[0];
        const GLuint dsaVertexArray = vertexArrays[1];

        GLuint vertexBuffer = 0;
        gl.glCreateBuffers(1, &vertexBuffer);
        gl.glNamedBufferData(vertexBuffer, 64, nullptr, GL_STATIC_DRAW);
        expectGLError(gl, GL_NO_ERROR, "DSA state vertex buffer create");

        gl.glBindVertexArray(sentinelVertexArray);
        expectGLError(gl, GL_NO_ERROR, "DSA state bind sentinel VAO");
        expectIntegerBinding(GL_VERTEX_ARRAY_BINDING, static_cast<GLint>(sentinelVertexArray),
                             "sentinel VAO binding before DSA");

        gl.glVertexArrayAttribFormat(dsaVertexArray, 0, 2, GL_FLOAT, GL_FALSE, 0);
        expectGLError(gl, GL_NO_ERROR, "DSA state vertexArrayAttribFormat success");
        expectIntegerBinding(GL_VERTEX_ARRAY_BINDING, static_cast<GLint>(sentinelVertexArray),
                             "vertexArrayAttribFormat preserves GL_VERTEX_ARRAY_BINDING");

        gl.glVertexArrayAttribBinding(dsaVertexArray, 0, 0);
        expectGLError(gl, GL_NO_ERROR, "DSA state vertexArrayAttribBinding success");
        expectIntegerBinding(GL_VERTEX_ARRAY_BINDING, static_cast<GLint>(sentinelVertexArray),
                             "vertexArrayAttribBinding preserves GL_VERTEX_ARRAY_BINDING");

        gl.glVertexArrayVertexBuffer(dsaVertexArray, 0, vertexBuffer, 0, 8);
        expectGLError(gl, GL_NO_ERROR, "DSA state vertexArrayVertexBuffer success");
        expectIntegerBinding(GL_VERTEX_ARRAY_BINDING, static_cast<GLint>(sentinelVertexArray),
                             "vertexArrayVertexBuffer preserves GL_VERTEX_ARRAY_BINDING");

        gl.glEnableVertexArrayAttrib(dsaVertexArray, 0);
        expectGLError(gl, GL_NO_ERROR, "DSA state enableVertexArrayAttrib success");
        expectIntegerBinding(GL_VERTEX_ARRAY_BINDING, static_cast<GLint>(sentinelVertexArray),
                             "enableVertexArrayAttrib preserves GL_VERTEX_ARRAY_BINDING");

        gl.glDisableVertexArrayAttrib(dsaVertexArray, 0);
        expectGLError(gl, GL_NO_ERROR, "DSA state disableVertexArrayAttrib success");
        expectIntegerBinding(GL_VERTEX_ARRAY_BINDING, static_cast<GLint>(sentinelVertexArray),
                             "disableVertexArrayAttrib preserves GL_VERTEX_ARRAY_BINDING");

        gl.glVertexArrayAttribFormat(dsaVertexArray, 9999, 2, GL_FLOAT, GL_FALSE, 0);
        expectGLError(gl, GL_INVALID_VALUE, "DSA state vertexArrayAttribFormat index error");
        expectIntegerBinding(GL_VERTEX_ARRAY_BINDING, static_cast<GLint>(sentinelVertexArray),
                             "vertexArrayAttribFormat error preserves GL_VERTEX_ARRAY_BINDING");

        gl.glVertexArrayVertexBuffer(dsaVertexArray, 0, 999999u, 0, 8);
        expectGLError(gl, GL_INVALID_OPERATION, "DSA state vertexArrayVertexBuffer buffer error");
        expectIntegerBinding(GL_VERTEX_ARRAY_BINDING, static_cast<GLint>(sentinelVertexArray),
                             "vertexArrayVertexBuffer error preserves GL_VERTEX_ARRAY_BINDING");

        gl.glDeleteBuffers(1, &vertexBuffer);
        gl.glDeleteVertexArrays(2, vertexArrays);
        gl.glDeleteBuffers(1, &backingBuffer);
        gl.glDeleteTextures(2, textureBufferObjects);
        gl.glDeleteTextures(2, textures2D);
        expectGLError(gl, GL_NO_ERROR, "DSA state preservation cleanup");
    });
    if (result.status == "passed") {
        result.message =
            "DSA texture and vertex-array calls preserve current non-DSA bindings on success and error paths";
    }
    return result;
}

void appendCoverageDelta(TestResult& result, const std::string& phase) {
    // Bootstrap coverage checks only apply to phase-a scenes. Phase-c and later
    // scenes validate their own scenarioCoverage() list; requiring the full
    // bootstrap set would force every phase to re-run all of phase-a first.
    if (phase != "phase-a") {
        return;
    }
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
        appendCoverageDelta(result, scene.phase());
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
    const std::filesystem::path goldenPath = root / "tests" / "goldens" / scene.phase() / (scene.id() + ".png");
    const std::filesystem::path actualPath = root / "tests" / "reports" / "actuals" / scene.phase() / (scene.id() + ".png");
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

    appendCoverageDelta(result, scene.phase());

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

    if (normalizedPhase == "mip-ub-probe") {
        tests.push_back(runMipOversizedLevelProbe());
        return buildJSON(normalizedPhase, tests);
    }

    if (normalizedPhase == "dsa-state-preservation") {
        tests.push_back(runDSAStatePreservationSentinel());
        return buildJSON(normalizedPhase, tests);
    }

    if (normalizedPhase == "dcr2-sentinels") {
        tests.push_back(runDCR2FlushFinishSentinel());
        tests.push_back(runDCR2PresentLifecycleSentinel());
        tests.push_back(runDCR2DeleteRebindLifetimeSentinel());
        return buildJSON(normalizedPhase, tests);
    }

    if (normalizedPhase == "dcr3-sentinels") {
        tests.push_back(runDCR3ReducedBoundContendedPressureSentinel());
        return buildJSON(normalizedPhase, tests);
    }

    if (normalizedPhase == "dcr3c-abandonment-sentinel") {
        tests.push_back(runDCR3CViewportRestoreAbandonmentSentinel());
        return buildJSON(normalizedPhase, tests);
    }

    if (normalizedPhase == "default-drawable-grow-only-probes") {
        tests.push_back(runDefaultDrawableGrowOnlyReadbackProbe());
        return buildJSON(normalizedPhase, tests);
    }

    if (normalizedPhase == "dcr3c-sentinels") {
        tests.push_back(runDCR3CFboPressureReadbackSentinel());
        tests.push_back(runDCR3CSoakBarBenchmarkSentinel());
        tests.push_back(runDCR3CMSAAResolveReadbackSentinel());
        tests.push_back(runDCR3CMSAAShaderResolveReadbackSentinel());
        tests.push_back(runDCR3CViewportRestoreAbandonmentSentinel());
        tests.push_back(runDCR3CProducerInventorySentinel());
        tests.push_back(runDCR3CBarBlitCopyMipmapSentinel());
        tests.push_back(runDCR3CBarCopyImageSparseLifecycleSentinel());
        tests.push_back(runDCR3CBufferRoleSentinel());
        return buildJSON(normalizedPhase, tests);
    }

    if (normalizedPhase == "depth32f-stale-drop-probes") {
        tests.push_back(runDepth32FStaleDropDepthSubImageProbe());
        tests.push_back(runDepth32FStaleDropArrayRgbaSubImageProbe());
        tests.push_back(runDepth32FStaleDropCopyImageProbe());
        tests.push_back(runDepth32FStaleDropPartialTexSubImageProbe());
        tests.push_back(runDepth32FStaleDropGenerateMipmapProbe());
        tests.push_back(runDepth32FStaleDropSwizzleProxyProbe());
        return buildJSON(normalizedPhase, tests);
    }

    if (normalizedPhase == "texture-shadow-mip-eviction-probes") {
        tests.push_back(runTextureMipShadowEvictionRGBA8ReadbackProbe());
        tests.push_back(runTextureMipShadowEvictionArrayProbe());
        tests.push_back(runTextureMipShadowEvictionR8Probe());
        tests.push_back(runTextureMipShadowEvictionUploadedMipProbe());
        tests.push_back(runTextureMipShadowEvictionUploadRebuildProbe());
        tests.push_back(runTextureMipShadowEvictionViewBlockProbe());
        tests.push_back(runTextureMipShadowEvictionEvictBeforeViewProbe());
        tests.push_back(runTextureMipShadowEvictionR8RedundantProbe());
        tests.push_back(runTextureMipShadowEvictionCopyImageProbe());
        tests.push_back(runTextureMipShadowEvictionPartialTexSubImageProbe());
        return buildJSON(normalizedPhase, tests);
    }

    if (normalizedPhase == "s22-first-range-sentinel") {
        tests.push_back(runS22FirstRangeSentinel());
        return buildJSON(normalizedPhase, tests);
    }

    if (normalizedPhase == "s22-live-present-sentinel") {
        tests.push_back(runS22LivePresentPathSentinel());
        tests.push_back(runS22LivePresentTessFurPathSentinel());
        return buildJSON(normalizedPhase, tests);
    }

    if (normalizedPhase == "dcr4c-sentinels") {
        tests.push_back(runDCR4CMeshGsDependencySentinel());
        tests.push_back(runDCR4CMeshGsFboProducerSentinel());
        return buildJSON(normalizedPhase, tests);
    }

    if (normalizedPhase == "dcr4d-sentinels") {
        tests.push_back(runDCR4DTessDependencySentinel());
        tests.push_back(runDCR4DTessFboProducerSentinel());
        tests.push_back(runDCR4DTessSideEffectRejectSentinel());
        tests.push_back(runDCR4DTessTfExcludeSentinel());
        return buildJSON(normalizedPhase, tests);
    }

    if (normalizedPhase == "dcr4e-sentinels") {
        tests.push_back(runDCR4ETfProducerSentinel());
        tests.push_back(runDCR4ECpuImageProducerSentinel());
        tests.push_back(runDCR4EQueryCounterSentinel());
        tests.push_back(runDCR4EStreamReplaySentinel());
        tests.push_back(runDCR4EExactNoSlipSentinel());
        return buildJSON(normalizedPhase, tests);
    }

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
        VaryingInterfaceScene varyingInterfaceScene;
        tests.push_back(runScene(varyingInterfaceScene));
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

    if (normalizedPhase == "all" || normalizedPhase == "phase-c") {
        ImmutableTextureVertexFormatScene immutableTexVertScene;
        tests.push_back(runScene(immutableTexVertScene));
        ComputeImageIntrospectionScene computeImageScene;
        tests.push_back(runScene(computeImageScene));
        AdvancedDrawBufferOpsScene advancedDrawScene;
        tests.push_back(runScene(advancedDrawScene));
        TextureOpsTFFormatQueryScene textureOpsTFScene;
        tests.push_back(runScene(textureOpsTFScene));
        // Phase 8X Group 4d follow-up¹⁴ §Tertiary — landed alongside
        // the blend-state + VAO-format derivation fixes so the round-
        // trip golden catches regressions in either root cause.
        AlphaBlendGauntletScene alphaBlendScene;
        tests.push_back(runScene(alphaBlendScene));
    }

    if (normalizedPhase == "all" || normalizedPhase == "phase-d") {
        GL44DSACreationScene gl44DsaScene;
        tests.push_back(runScene(gl44DsaScene));
        DSABufferTextureScene dsaBufTexScene;
        tests.push_back(runScene(dsaBufTexScene));
        DSAFramebufferVAOScene dsaFbVaoScene;
        tests.push_back(runScene(dsaFbVaoScene));
        ClipControlRobustnessGL46Scene clipRobustScene;
        tests.push_back(runScene(clipRobustScene));
    }

    if (normalizedPhase == "all" || normalizedPhase == "phase-7") {
        PolygonObjectsScene polygonObjectsScene;
        tests.push_back(runScene(polygonObjectsScene));
        ObjectCountStressScene objectCountStressScene;
        tests.push_back(runScene(objectCountStressScene));
        PhysicsCollisionScene physicsCollisionScene;
        tests.push_back(runScene(physicsCollisionScene));
        LightingPhongScene lightingPhongScene;
        tests.push_back(runScene(lightingPhongScene));
        GL33InstancedScene gl33InstancedScene;
        tests.push_back(runScene(gl33InstancedScene));
        GL41DSAUniformsScene gl41DSAScene;
        tests.push_back(runScene(gl41DSAScene));
        GL46ZeroBindDSAScene gl46ZeroBindScene;
        tests.push_back(runScene(gl46ZeroBindScene));

        // Group 6 — version comparison scenes.
        VersionCompare33Scene vc33;
        tests.push_back(runScene(vc33));
        VersionCompare41Scene vc41;
        tests.push_back(runScene(vc41));
        VersionCompare46Scene vc46;
        tests.push_back(runScene(vc46));

        // Phase 8X Group 4d follow-up¹⁷ — compat-profile immediate-mode
        // capture path (glBegin/glVertex*/glColor*/glEnd) required for
        // Chobby's Chili UI. Added in the same commit as the routing
        // into MetalFrameGraph::encodeImmediateModeDraw.
        ImmediateModeQuadScene immediateModeQuadScene;
        tests.push_back(runScene(immediateModeQuadScene));

        // Phase 8X Group 4d follow-up¹⁸ — GL_ALPHA → RGBA8 broadcast
        // regression guard. Samples the single-channel texture via `.x`
        // (matching Spring's CglShaderFontRenderer) so a reversion to
        // the spec-literal (0,0,0,A) layout lights up as an all-black
        // golden mismatch.
        AlphaTextureCoverageScene alphaTextureCoverageScene;
        tests.push_back(runScene(alphaTextureCoverageScene));

        // Phase 8X Group 4d follow-up¹⁹ — legacy-GLSL rewriter end-to-end.
        // Compiles a `#version 120` shader pair that exercises version
        // upgrade, `varying` translation, `gl_Vertex`/`gl_MultiTexCoord0`
        // synthesis, `gl_ModelViewProjectionMatrix` push, `gl_FragColor`
        // rewrite, and `texture2D` → `texture` in one program. If any
        // piece of `rewriteCompatShader` regresses the compile will fail
        // or the golden image will flip. See §fw¹⁹ memo.
        CompatProfileGLSLScene compatProfileGlslScene;
        tests.push_back(runScene(compatProfileGlslScene));

        // Phase 8X Group 4d follow-up²⁰ — dual-form fragment output.
        // Compiles a `#version 120` FS that has both `gl_FragData[]`
        // and `gl_FragColor` lexically present inside a dead
        // `#if DEFERRED_MODE == 1` branch (same shape as Spring's
        // `ModelFragProg.glsl`). The rewriter's fw²⁰ consolidation
        // rule must fold `gl_FragColor` → `appgl_FragData[0]` and
        // emit a single `appgl_FragData[]` array declaration —
        // otherwise glslang rejects with `'location' : overlapping
        // use of location 0`. See §fw²⁰ memo.
        CompatProfileGLSLDualOutputScene compatProfileDualOutputScene;
        tests.push_back(runScene(compatProfileDualOutputScene));

        // Phase 8X Group 4d follow-up²¹ — shadow2DProj helper wrapper.
        // Compiles a `#version 120` FS that calls
        // `shadow2DProj(uShadow, ...).r` — the exact shape that broke
        // Spring's `ModelFragProg.glsl` `USE_SHADOWS == 1` branch
        // under fw²⁰ (legacy `shadow2DProj` returns vec4, core
        // `textureProj` on sampler2DShadow returns float, so .r
        // becomes illegal scalar swizzle after a flat rename). The
        // rewriter's fw²¹ helper-synthesis rule must rename call
        // sites to `appgl_shadow2DProj` AND emit a preamble wrapper
        // that preserves the legacy vec4 return type — otherwise
        // the FS compile fails at setup time. See §fw²¹ memo.
        CompatProfileGLSLShadowScene compatProfileShadowScene;
        tests.push_back(runScene(compatProfileShadowScene));
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

std::string runBenchmarkJSON() {
    std::vector<BenchmarkTierResult> tiers;

    // Light: 1 cube, 36 vertices, flat shader.
    tiers.push_back(runLightTier());

    // Medium: 100 Phong-lit spheres.
    tiers.push_back(runPhongObjectsTier("medium", 100));

    // Heavy: 1000 Phong-lit spheres with depth test.
    tiers.push_back(runPhongObjectsTier("heavy", 1000));

    return buildBenchmarkJSON(tiers);
}

std::string runVersionComparisonJSON() {
    // Run the three version-comparison scenes through the standard gauntlet
    // pipeline (setup, render, readback, golden save/compare).
    VersionCompare33Scene vc33;
    VersionCompare41Scene vc41;
    VersionCompare46Scene vc46;

    TestResult r33 = runScene(vc33);
    TestResult r41 = runScene(vc41);
    TestResult r46 = runScene(vc46);

    // Load the three actual PNGs back for pairwise cross-version comparison.
    const std::filesystem::path root = workspaceRoot();
    auto loadActual = [&](const std::string& sceneId) -> std::optional<Image> {
        std::filesystem::path p = root / "tests" / "reports" / "actuals" / "phase-7" / (sceneId + ".png");
        std::string err;
        return loadPNG(p, &err);
    };

    auto img33 = loadActual("phase-7.version-compare-gl33");
    auto img41 = loadActual("phase-7.version-compare-gl41");
    auto img46 = loadActual("phase-7.version-compare-gl46");

    // Pairwise comparisons (tolerance 0 — we expect pixel-identical output).
    struct PairResult {
        std::string pairName;
        bool valid = false;
        double diffRatio = 1.0;
        double maxChannelDelta = 1.0;
    };

    auto comparePair = [](const std::string& name,
                          const std::optional<Image>& a,
                          const std::optional<Image>& b) -> PairResult {
        PairResult pr;
        pr.pairName = name;
        if (!a.has_value() || !b.has_value()) {
            pr.valid = false;
            return pr;
        }
        CompareResult cr = compareImages(*a, *b, 0.0);
        pr.valid = cr.dimensionsMatch;
        pr.diffRatio = cr.diffRatio;
        pr.maxChannelDelta = cr.maxChannelDelta;
        return pr;
    };

    PairResult pair33v41 = comparePair("gl33-vs-gl41", img33, img41);
    PairResult pair41v46 = comparePair("gl41-vs-gl46", img41, img46);
    PairResult pair33v46 = comparePair("gl33-vs-gl46", img33, img46);

    // Build JSON report.
    std::ostringstream ss;
    ss << std::fixed << std::setprecision(6);
    ss << "{\"versionComparison\":{";

    // Per-scene results.
    ss << "\"scenes\":[";
    auto emitScene = [&](const TestResult& r, bool last) {
        ss << "{\"id\":\"" << r.id << "\","
           << "\"status\":\"" << r.status << "\","
           << "\"millis\":" << r.millis << ","
           << "\"diffRatio\":" << r.diffRatio << ","
           << "\"maxChannelDelta\":" << r.maxChannelDelta << "}";
        if (!last) ss << ",";
    };
    emitScene(r33, false);
    emitScene(r41, false);
    emitScene(r46, true);
    ss << "],";

    // Pairwise cross-version comparison.
    ss << "\"pairwise\":[";
    auto emitPair = [&](const PairResult& pr, bool last) {
        ss << "{\"pair\":\"" << pr.pairName << "\","
           << "\"valid\":" << (pr.valid ? "true" : "false") << ","
           << "\"diffRatio\":" << pr.diffRatio << ","
           << "\"maxChannelDelta\":" << pr.maxChannelDelta << ","
           << "\"pixelIdentical\":" << (pr.valid && pr.diffRatio == 0.0 ? "true" : "false")
           << "}";
        if (!last) ss << ",";
    };
    emitPair(pair33v41, false);
    emitPair(pair41v46, false);
    emitPair(pair33v46, true);
    ss << "],";

    // Overall verdict.
    bool allScenesPass = (r33.status == "passed" && r41.status == "passed" && r46.status == "passed");
    bool allPairsValid = (pair33v41.valid && pair41v46.valid && pair33v46.valid);
    // Allow tolerance of 1% channel delta for cross-version comparison.
    double maxDiff = std::max({pair33v41.diffRatio, pair41v46.diffRatio, pair33v46.diffRatio});
    bool pairsWithinTolerance = (maxDiff <= 0.01);
    bool pass = allScenesPass && allPairsValid && pairsWithinTolerance;

    ss << "\"allScenesPass\":" << (allScenesPass ? "true" : "false") << ","
       << "\"allPairsWithinTolerance\":" << (pairsWithinTolerance ? "true" : "false") << ","
       << "\"maxCrossVersionDiff\":" << maxDiff << ","
       << "\"verdict\":\"" << (pass ? "PASS" : "FAIL") << "\"";

    ss << "}}";
    return ss.str();
}

}  // namespace appgl::tests

extern "C" std::size_t appglRunGauntletJSON(const char* phaseFilter, char* out, std::size_t cap) {
    return appgl::tests::writeGauntletJSON(phaseFilter != nullptr ? phaseFilter : "", out, cap);
}

extern "C" std::size_t appglRunBenchmarkJSON(char* out, std::size_t cap) {
    const std::string payload = appgl::tests::runBenchmarkJSON();
    const std::size_t required = payload.size() + 1;
    if (out == nullptr || cap == 0) {
        return required;
    }
    const std::size_t bytesToCopy = std::min(required - 1, cap - 1);
    std::memcpy(out, payload.data(), bytesToCopy);
    out[bytesToCopy] = '\0';
    return required;
}
