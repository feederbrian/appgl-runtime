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
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#include "../include/AppGL/AppGL.h"
#include "../include/AppGL/glcorearb.h"
#include "../src/context/GLContext.h"
#include "../src/debug/CoverageStore.h"
#include "../src/runtime/AppGLRuntime.h"
#include "../src/shared/JsonUtil.h"

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

constexpr std::array<FunctionId, 52> kBootstrapFunctions = {
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
        (void)context;
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

    scene.setup(*context);
    scene.render(*context);

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
