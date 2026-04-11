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
#include "../src/objects/GLObjectStore.h"
#include "../src/runtime/AppGLRuntime.h"
#include "../src/shared/JsonUtil.h"
#include "../src/state/GLStateTracker.h"

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

constexpr std::array<FunctionId, 118> kBootstrapFunctions = {
    FunctionId::glCullFace,
    FunctionId::glFrontFace,
    FunctionId::glHint,
    FunctionId::glLineWidth,
    FunctionId::glPointSize,
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
    FunctionId::glPixelStorei,
    FunctionId::glPixelStoref,
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
        VertexInputStateScene vertexInputScene;
        tests.push_back(runScene(vertexInputScene));
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
