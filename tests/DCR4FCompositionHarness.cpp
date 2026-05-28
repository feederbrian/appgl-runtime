#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <functional>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include <sys/wait.h>
#include <unistd.h>

#include "AppGL/AppGL.h"
#include "AppGL/glcorearb.h"

namespace {

using CreateOffscreenFn = AppGLContext* (*)(int, int);
using DestroyContextFn = void (*)(AppGLContext*);
using MakeCurrentFn = void (*)(AppGLContext*);
using GetProcAddressFn = AppGLProc (*)(const char*);

constexpr GLsizei kSize = 32;

struct Options {
    std::string library = "build-release/libAppGL.dylib";
    std::string label = "dcr4-f-composition";
    std::string only;
    std::string argbuf = "on";
};

struct GLApi {
    PFNGLACTIVETEXTUREPROC ActiveTexture = nullptr;
    PFNGLATTACHSHADERPROC AttachShader = nullptr;
    PFNGLBEGINQUERYPROC BeginQuery = nullptr;
    PFNGLBEGINTRANSFORMFEEDBACKPROC BeginTransformFeedback = nullptr;
    PFNGLBINDBUFFERPROC BindBuffer = nullptr;
    PFNGLBINDBUFFERBASEPROC BindBufferBase = nullptr;
    PFNGLBINDFRAMEBUFFERPROC BindFramebuffer = nullptr;
    PFNGLBINDTEXTUREPROC BindTexture = nullptr;
    PFNGLBINDTRANSFORMFEEDBACKPROC BindTransformFeedback = nullptr;
    PFNGLBINDVERTEXARRAYPROC BindVertexArray = nullptr;
    PFNGLBUFFERDATAPROC BufferData = nullptr;
    PFNGLCHECKFRAMEBUFFERSTATUSPROC CheckFramebufferStatus = nullptr;
    PFNGLCLEARPROC Clear = nullptr;
    PFNGLCLEARCOLORPROC ClearColor = nullptr;
    PFNGLCOMPILESHADERPROC CompileShader = nullptr;
    PFNGLCREATEPROGRAMPROC CreateProgram = nullptr;
    PFNGLCREATESHADERPROC CreateShader = nullptr;
    PFNGLDELETEBUFFERSPROC DeleteBuffers = nullptr;
    PFNGLDELETEFRAMEBUFFERSPROC DeleteFramebuffers = nullptr;
    PFNGLDELETEPROGRAMPROC DeleteProgram = nullptr;
    PFNGLDELETEQUERIESPROC DeleteQueries = nullptr;
    PFNGLDELETESHADERPROC DeleteShader = nullptr;
    PFNGLDELETETEXTURESPROC DeleteTextures = nullptr;
    PFNGLDELETETRANSFORMFEEDBACKSPROC DeleteTransformFeedbacks = nullptr;
    PFNGLDELETEVERTEXARRAYSPROC DeleteVertexArrays = nullptr;
    PFNGLDISABLEPROC Disable = nullptr;
    PFNGLDISPATCHCOMPUTEPROC DispatchCompute = nullptr;
    PFNGLDRAWARRAYSPROC DrawArrays = nullptr;
    PFNGLDRAWBUFFERPROC DrawBuffer = nullptr;
    PFNGLDRAWTRANSFORMFEEDBACKSTREAMPROC DrawTransformFeedbackStream = nullptr;
    PFNGLENABLEPROC Enable = nullptr;
    PFNGLENABLEVERTEXATTRIBARRAYPROC EnableVertexAttribArray = nullptr;
    PFNGLENDQUERYPROC EndQuery = nullptr;
    PFNGLENDTRANSFORMFEEDBACKPROC EndTransformFeedback = nullptr;
    PFNGLFINISHPROC Finish = nullptr;
    PFNGLFRAMEBUFFERTEXTURE2DPROC FramebufferTexture2D = nullptr;
    PFNGLGENBUFFERSPROC GenBuffers = nullptr;
    PFNGLGENFRAMEBUFFERSPROC GenFramebuffers = nullptr;
    PFNGLGENQUERIESPROC GenQueries = nullptr;
    PFNGLGENTEXTURESPROC GenTextures = nullptr;
    PFNGLGENTRANSFORMFEEDBACKSPROC GenTransformFeedbacks = nullptr;
    PFNGLGENVERTEXARRAYSPROC GenVertexArrays = nullptr;
    PFNGLGETBUFFERSUBDATAPROC GetBufferSubData = nullptr;
    PFNGLGETERRORPROC GetError = nullptr;
    PFNGLGETPROGRAMINFOLOGPROC GetProgramInfoLog = nullptr;
    PFNGLGETPROGRAMIVPROC GetProgramiv = nullptr;
    PFNGLGETQUERYOBJECTUI64VPROC GetQueryObjectui64v = nullptr;
    PFNGLGETSHADERINFOLOGPROC GetShaderInfoLog = nullptr;
    PFNGLGETSHADERIVPROC GetShaderiv = nullptr;
    PFNGLGETUNIFORMLOCATIONPROC GetUniformLocation = nullptr;
    PFNGLLINKPROGRAMPROC LinkProgram = nullptr;
    PFNGLPATCHPARAMETERIPROC PatchParameteri = nullptr;
    PFNGLREADBUFFERPROC ReadBuffer = nullptr;
    PFNGLREADPIXELSPROC ReadPixels = nullptr;
    PFNGLSHADERSOURCEPROC ShaderSource = nullptr;
    PFNGLTEXBUFFERPROC TexBuffer = nullptr;
    PFNGLTEXIMAGE2DPROC TexImage2D = nullptr;
    PFNGLTEXPARAMETERIPROC TexParameteri = nullptr;
    PFNGLTRANSFORMFEEDBACKVARYINGSPROC TransformFeedbackVaryings = nullptr;
    PFNGLUNIFORM1IPROC Uniform1i = nullptr;
    PFNGLUNIFORM4FPROC Uniform4f = nullptr;
    PFNGLUSEPROGRAMPROC UseProgram = nullptr;
    PFNGLVERTEXATTRIBPOINTERPROC VertexAttribPointer = nullptr;
    PFNGLVIEWPORTPROC Viewport = nullptr;
};

struct RuntimeApi {
    void* handle = nullptr;
    CreateOffscreenFn createOffscreen = nullptr;
    DestroyContextFn destroyContext = nullptr;
    MakeCurrentFn makeCurrent = nullptr;
    GetProcAddressFn getProcAddress = nullptr;
    GLApi gl;
};

struct SentinelResult {
    std::string name;
    std::string status = "failed";
    std::string green = "not-run";
    std::string red = "not-run";
    std::string message;
    std::vector<std::string> observations;
};

struct SentinelCase {
    const char* name;
    SentinelResult (*runner)(RuntimeApi&);
};

[[noreturn]] void fail(const std::string& message) {
    throw std::runtime_error(message);
}

void expect(bool condition, const std::string& message) {
    if (!condition) {
        fail(message);
    }
}

Options parseOptions(int argc, char** argv) {
    Options options;
    for (int i = 1; i < argc; ++i) {
        const std::string_view arg(argv[i]);
        auto takeValue = [&](std::string_view name) -> std::string_view {
            const std::string prefix = std::string(name) + "=";
            if (arg.rfind(prefix, 0) == 0) {
                return arg.substr(prefix.size());
            }
            if (arg == name && i + 1 < argc) {
                ++i;
                return argv[i];
            }
            return {};
        };

        if (auto value = takeValue("--library"); !value.empty()) {
            options.library = std::string(value);
        } else if (auto value = takeValue("--label"); !value.empty()) {
            options.label = std::string(value);
        } else if (auto value = takeValue("--only"); !value.empty()) {
            options.only = std::string(value);
        } else if (auto value = takeValue("--argbuf"); !value.empty()) {
            options.argbuf = std::string(value);
            if (options.argbuf != "on" && options.argbuf != "off") {
                fail("--argbuf must be 'on' or 'off'");
            }
        } else if (arg == "--help" || arg == "-h") {
            std::cout
                << "Usage: appgl_dcr4f_composition [options]\n"
                << "  --library PATH  libAppGL.dylib to dlopen\n"
                << "  --label NAME    JSON label\n"
                << "  --only NAME     run one sentinel by exact name\n"
                << "  --argbuf MODE   on or off; default on for DCR4-F parity\n";
            std::exit(0);
        } else {
            fail("unknown argument: " + std::string(arg));
        }
    }
    return options;
}

template <typename T>
void loadSymbol(void* handle, const char* name, T& out) {
    out = reinterpret_cast<T>(dlsym(handle, name));
    if (out == nullptr) {
        const char* error = dlerror();
        fail(std::string("missing dylib symbol ") + name +
             (error != nullptr ? std::string(": ") + error : std::string{}));
    }
}

template <typename T>
void loadGL(RuntimeApi& api, const char* name, T& out) {
    out = reinterpret_cast<T>(api.getProcAddress(name));
    if (out == nullptr) {
        fail(std::string("missing GL entry point ") + name);
    }
}

RuntimeApi loadRuntime(const Options& options) {
    setenv("APPGL_COMMAND_BUFFER_BOUND", "48", 0);
    setenv("APPGL_COMMAND_BUFFER_RESERVE", "4", 0);
    setenv("APPGL_COMMAND_BUFFER_TIMEOUT_MS", "30000", 0);
    if (options.argbuf == "on") {
        setenv("APPGL_ENABLE_ARGUMENT_BUFFERS", "1", 1);
    } else {
        unsetenv("APPGL_ENABLE_ARGUMENT_BUFFERS");
    }
    setenv("APPGL_ENABLE_METAL_TESS", "1", 1);
    setenv("APPGL_ENABLE_METAL_TESS_TF", "1", 1);
    setenv("APPGL_ENABLE_TESS_EMUL", "1", 1);
    setenv("APPGL_ENABLE_TESS_EMUL_GLIN", "1", 1);
    setenv("APPGL_LIFT_TESS_UNIFORM_GUARD", "1", 1);

    RuntimeApi api;
    api.handle = dlopen(options.library.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (api.handle == nullptr) {
        fail("dlopen failed for " + options.library + ": " + dlerror());
    }

    loadSymbol(api.handle, "appglCreateOffscreenContext", api.createOffscreen);
    loadSymbol(api.handle, "appglDestroyContext", api.destroyContext);
    loadSymbol(api.handle, "appglMakeCurrent", api.makeCurrent);
    loadSymbol(api.handle, "appglGetProcAddress", api.getProcAddress);

    auto& gl = api.gl;
    loadGL(api, "glActiveTexture", gl.ActiveTexture);
    loadGL(api, "glAttachShader", gl.AttachShader);
    loadGL(api, "glBeginQuery", gl.BeginQuery);
    loadGL(api, "glBeginTransformFeedback", gl.BeginTransformFeedback);
    loadGL(api, "glBindBuffer", gl.BindBuffer);
    loadGL(api, "glBindBufferBase", gl.BindBufferBase);
    loadGL(api, "glBindFramebuffer", gl.BindFramebuffer);
    loadGL(api, "glBindTexture", gl.BindTexture);
    loadGL(api, "glBindTransformFeedback", gl.BindTransformFeedback);
    loadGL(api, "glBindVertexArray", gl.BindVertexArray);
    loadGL(api, "glBufferData", gl.BufferData);
    loadGL(api, "glCheckFramebufferStatus", gl.CheckFramebufferStatus);
    loadGL(api, "glClear", gl.Clear);
    loadGL(api, "glClearColor", gl.ClearColor);
    loadGL(api, "glCompileShader", gl.CompileShader);
    loadGL(api, "glCreateProgram", gl.CreateProgram);
    loadGL(api, "glCreateShader", gl.CreateShader);
    loadGL(api, "glDeleteBuffers", gl.DeleteBuffers);
    loadGL(api, "glDeleteFramebuffers", gl.DeleteFramebuffers);
    loadGL(api, "glDeleteProgram", gl.DeleteProgram);
    loadGL(api, "glDeleteQueries", gl.DeleteQueries);
    loadGL(api, "glDeleteShader", gl.DeleteShader);
    loadGL(api, "glDeleteTextures", gl.DeleteTextures);
    loadGL(api, "glDeleteTransformFeedbacks", gl.DeleteTransformFeedbacks);
    loadGL(api, "glDeleteVertexArrays", gl.DeleteVertexArrays);
    loadGL(api, "glDisable", gl.Disable);
    loadGL(api, "glDispatchCompute", gl.DispatchCompute);
    loadGL(api, "glDrawArrays", gl.DrawArrays);
    loadGL(api, "glDrawBuffer", gl.DrawBuffer);
    loadGL(api, "glDrawTransformFeedbackStream", gl.DrawTransformFeedbackStream);
    loadGL(api, "glEnable", gl.Enable);
    loadGL(api, "glEnableVertexAttribArray", gl.EnableVertexAttribArray);
    loadGL(api, "glEndQuery", gl.EndQuery);
    loadGL(api, "glEndTransformFeedback", gl.EndTransformFeedback);
    loadGL(api, "glFinish", gl.Finish);
    loadGL(api, "glFramebufferTexture2D", gl.FramebufferTexture2D);
    loadGL(api, "glGenBuffers", gl.GenBuffers);
    loadGL(api, "glGenFramebuffers", gl.GenFramebuffers);
    loadGL(api, "glGenQueries", gl.GenQueries);
    loadGL(api, "glGenTextures", gl.GenTextures);
    loadGL(api, "glGenTransformFeedbacks", gl.GenTransformFeedbacks);
    loadGL(api, "glGenVertexArrays", gl.GenVertexArrays);
    loadGL(api, "glGetBufferSubData", gl.GetBufferSubData);
    loadGL(api, "glGetError", gl.GetError);
    loadGL(api, "glGetProgramInfoLog", gl.GetProgramInfoLog);
    loadGL(api, "glGetProgramiv", gl.GetProgramiv);
    loadGL(api, "glGetQueryObjectui64v", gl.GetQueryObjectui64v);
    loadGL(api, "glGetShaderInfoLog", gl.GetShaderInfoLog);
    loadGL(api, "glGetShaderiv", gl.GetShaderiv);
    loadGL(api, "glGetUniformLocation", gl.GetUniformLocation);
    loadGL(api, "glLinkProgram", gl.LinkProgram);
    loadGL(api, "glPatchParameteri", gl.PatchParameteri);
    loadGL(api, "glReadBuffer", gl.ReadBuffer);
    loadGL(api, "glReadPixels", gl.ReadPixels);
    loadGL(api, "glShaderSource", gl.ShaderSource);
    loadGL(api, "glTexBuffer", gl.TexBuffer);
    loadGL(api, "glTexImage2D", gl.TexImage2D);
    loadGL(api, "glTexParameteri", gl.TexParameteri);
    loadGL(api, "glTransformFeedbackVaryings", gl.TransformFeedbackVaryings);
    loadGL(api, "glUniform1i", gl.Uniform1i);
    loadGL(api, "glUniform4f", gl.Uniform4f);
    loadGL(api, "glUseProgram", gl.UseProgram);
    loadGL(api, "glVertexAttribPointer", gl.VertexAttribPointer);
    loadGL(api, "glViewport", gl.Viewport);
    return api;
}

class ScopedEnvVar {
public:
    ScopedEnvVar(const char* name, const char* value)
        : name_(name) {
        const char* current = std::getenv(name);
        if (current != nullptr) {
            hadOld_ = true;
            oldValue_ = current;
        }
        setenv(name, value, 1);
    }

    ~ScopedEnvVar() {
        if (hadOld_) {
            setenv(name_.c_str(), oldValue_.c_str(), 1);
        } else {
            unsetenv(name_.c_str());
        }
    }

private:
    std::string name_;
    std::string oldValue_;
    bool hadOld_ = false;
};

void checkGLError(const GLApi& gl, std::string_view where) {
    const GLenum error = gl.GetError();
    if (error != GL_NO_ERROR) {
        std::ostringstream stream;
        stream << where << " produced GL error 0x" << std::hex << error;
        fail(stream.str());
    }
}

std::string pixelString(const std::array<std::uint8_t, 4>& pixel) {
    std::ostringstream stream;
    stream << "(" << static_cast<int>(pixel[0])
           << "," << static_cast<int>(pixel[1])
           << "," << static_cast<int>(pixel[2])
           << "," << static_cast<int>(pixel[3]) << ")";
    return stream.str();
}

bool isGreen(const std::array<std::uint8_t, 4>& pixel) {
    return pixel[0] <= 45 && pixel[1] >= 175 &&
           pixel[2] <= 45 && pixel[3] >= 230;
}

bool isMagenta(const std::array<std::uint8_t, 4>& pixel) {
    return pixel[0] >= 175 && pixel[1] <= 60 &&
           pixel[2] >= 150 && pixel[3] >= 230;
}

GLuint compileShader(const GLApi& gl, GLenum stage, const char* source, const char* label) {
    const GLuint shader = gl.CreateShader(stage);
    gl.ShaderSource(shader, 1, &source, nullptr);
    gl.CompileShader(shader);
    GLint ok = GL_FALSE;
    gl.GetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[4096] = {};
        GLsizei length = 0;
        gl.GetShaderInfoLog(shader, sizeof(log), &length, log);
        fail(std::string(label) + " compile failed: " + log);
    }
    return shader;
}

struct ShaderStage {
    GLenum stage;
    const char* source;
    const char* label;
};

GLuint buildProgram(const GLApi& gl,
                    std::initializer_list<ShaderStage> stages,
                    const char* label,
                    const char* const* tfVaryings = nullptr,
                    GLsizei tfVaryingCount = 0) {
    std::vector<GLuint> shaders;
    GLuint program = gl.CreateProgram();
    for (const auto& stage : stages) {
        const GLuint shader = compileShader(gl, stage.stage, stage.source, stage.label);
        shaders.push_back(shader);
        gl.AttachShader(program, shader);
    }
    if (tfVaryings != nullptr && tfVaryingCount > 0) {
        gl.TransformFeedbackVaryings(program, tfVaryingCount, tfVaryings,
                                     GL_INTERLEAVED_ATTRIBS);
    }
    gl.LinkProgram(program);
    for (GLuint shader : shaders) {
        gl.DeleteShader(shader);
    }

    GLint ok = GL_FALSE;
    gl.GetProgramiv(program, GL_LINK_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[4096] = {};
        GLsizei length = 0;
        gl.GetProgramInfoLog(program, sizeof(log), &length, log);
        gl.DeleteProgram(program);
        fail(std::string(label) + " link failed: " + log);
    }
    return program;
}

void setupFullscreenTriangle(const GLApi& gl, GLuint& vao, GLuint& vbo) {
    static constexpr GLfloat vertices[] = {
        -1.0f, -1.0f,
         3.0f, -1.0f,
        -1.0f,  3.0f,
    };
    gl.GenVertexArrays(1, &vao);
    gl.BindVertexArray(vao);
    gl.GenBuffers(1, &vbo);
    gl.BindBuffer(GL_ARRAY_BUFFER, vbo);
    gl.BufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(GLfloat), nullptr);
    checkGLError(gl, "fullscreen triangle setup");
}

void setupRGBA8Texture(const GLApi& gl, GLuint texture, GLsizei width, GLsizei height) {
    gl.BindTexture(GL_TEXTURE_2D, texture);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0,
                  GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    checkGLError(gl, "RGBA8 texture setup");
}

void setupTextureFbo(const GLApi& gl, GLuint& texture, GLuint& fbo) {
    gl.GenTextures(1, &texture);
    setupRGBA8Texture(gl, texture, kSize, kSize);
    gl.GenFramebuffers(1, &fbo);
    gl.BindFramebuffer(GL_FRAMEBUFFER, fbo);
    gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                            GL_TEXTURE_2D, texture, 0);
    gl.DrawBuffer(GL_COLOR_ATTACHMENT0);
    gl.ReadBuffer(GL_COLOR_ATTACHMENT0);
    const GLenum status = gl.CheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        std::ostringstream stream;
        stream << "framebuffer incomplete: 0x" << std::hex << status;
        fail(stream.str());
    }
}

std::array<std::uint8_t, 4> readCenter(const GLApi& gl) {
    std::array<std::uint8_t, 4> pixel = {};
    gl.ReadPixels(kSize / 2, kSize / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
    checkGLError(gl, "center readback");
    return pixel;
}

void drawFullscreenColor(const GLApi& gl,
                         GLuint program,
                         GLint colorLocation,
                         GLuint vao,
                         float r,
                         float g,
                         float b,
                         float a) {
    gl.UseProgram(program);
    gl.Uniform4f(colorLocation, r, g, b, a);
    gl.BindVertexArray(vao);
    gl.DrawArrays(GL_TRIANGLES, 0, 3);
    checkGLError(gl, "fullscreen color draw");
}

void drawFullscreenSample2D(const GLApi& gl,
                            GLuint program,
                            GLint samplerLocation,
                            GLuint vao,
                            GLuint texture) {
    gl.UseProgram(program);
    gl.ActiveTexture(GL_TEXTURE0);
    gl.BindTexture(GL_TEXTURE_2D, texture);
    gl.Uniform1i(samplerLocation, 0);
    gl.BindVertexArray(vao);
    gl.DrawArrays(GL_TRIANGLES, 0, 3);
    checkGLError(gl, "fullscreen texture sample draw");
}

void drawFullscreenSampleBuffer(const GLApi& gl,
                                GLuint program,
                                GLint samplerLocation,
                                GLuint vao,
                                GLuint texture) {
    gl.UseProgram(program);
    gl.ActiveTexture(GL_TEXTURE0);
    gl.BindTexture(GL_TEXTURE_BUFFER, texture);
    gl.Uniform1i(samplerLocation, 0);
    gl.BindVertexArray(vao);
    gl.DrawArrays(GL_TRIANGLES, 0, 3);
    checkGLError(gl, "fullscreen buffer sample draw");
}

void drawMeshPoint(const GLApi& gl, GLuint program) {
    GLuint vao = 0;
    gl.GenVertexArrays(1, &vao);
    gl.BindVertexArray(vao);
    gl.UseProgram(program);
    gl.Enable(GL_PROGRAM_POINT_SIZE);
    gl.DrawArrays(GL_POINTS, 0, 1);
    checkGLError(gl, "mesh-GS point draw");
    gl.BindVertexArray(0);
    gl.DeleteVertexArrays(1, &vao);
}

void drawTessPatch(const GLApi& gl, GLuint program) {
    GLuint vao = 0;
    gl.GenVertexArrays(1, &vao);
    gl.BindVertexArray(vao);
    gl.UseProgram(program);
    gl.PatchParameteri(GL_PATCH_VERTICES, 3);
    gl.DrawArrays(GL_PATCHES, 0, 3);
    checkGLError(gl, "tess patch draw");
    gl.BindVertexArray(0);
    gl.DeleteVertexArrays(1, &vao);
}

void captureTessTfPoint(const GLApi& gl,
                        GLuint program,
                        GLuint tf,
                        GLuint buffer,
                        bool skipCpuWrite) {
    GLuint vao = 0;
    gl.GenVertexArrays(1, &vao);
    gl.BindVertexArray(vao);
    gl.UseProgram(program);
    gl.PatchParameteri(GL_PATCH_VERTICES, 3);
    gl.BindTransformFeedback(GL_TRANSFORM_FEEDBACK, tf);
    gl.BindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, buffer);
    gl.Enable(GL_RASTERIZER_DISCARD);
    if (skipCpuWrite) {
        ScopedEnvVar skip("APPGL_DCR4D_TF_EXCLUDE_SKIP_CPU_WRITE", "1");
        gl.BeginTransformFeedback(GL_POINTS);
        gl.DrawArrays(GL_PATCHES, 0, 3);
        gl.EndTransformFeedback();
    } else {
        gl.BeginTransformFeedback(GL_POINTS);
        gl.DrawArrays(GL_PATCHES, 0, 3);
        gl.EndTransformFeedback();
    }
    gl.Disable(GL_RASTERIZER_DISCARD);
    checkGLError(gl, "tess TF point capture");
    gl.BindVertexArray(0);
    gl.DeleteVertexArrays(1, &vao);
}

void captureGsTfPoint(const GLApi& gl,
                      GLuint program,
                      GLuint tf,
                      GLuint buffer,
                      bool skipCpuWrite) {
    GLuint vao = 0;
    gl.GenVertexArrays(1, &vao);
    gl.BindVertexArray(vao);
    gl.UseProgram(program);
    gl.Enable(GL_PROGRAM_POINT_SIZE);
    gl.BindTransformFeedback(GL_TRANSFORM_FEEDBACK, tf);
    gl.BindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, buffer);
    gl.Enable(GL_RASTERIZER_DISCARD);
    if (skipCpuWrite) {
        ScopedEnvVar skip("APPGL_DCR4E_TF_SKIP_CPU_WRITE", "1");
        gl.BeginTransformFeedback(GL_POINTS);
        gl.DrawArrays(GL_POINTS, 0, 1);
        gl.EndTransformFeedback();
    } else {
        gl.BeginTransformFeedback(GL_POINTS);
        gl.DrawArrays(GL_POINTS, 0, 1);
        gl.EndTransformFeedback();
    }
    gl.Disable(GL_RASTERIZER_DISCARD);
    checkGLError(gl, "GS TF point capture");
    gl.BindVertexArray(0);
    gl.DeleteVertexArrays(1, &vao);
}

GLuint createTfObject(const GLApi& gl, GLuint buffer) {
    GLuint tf = 0;
    gl.GenTransformFeedbacks(1, &tf);
    gl.BindTransformFeedback(GL_TRANSFORM_FEEDBACK, tf);
    gl.BindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, buffer);
    checkGLError(gl, "TF object setup");
    return tf;
}

void resetFloatBuffer(const GLApi& gl, GLuint buffer, float value) {
    std::array<float, 16> values = {};
    values.fill(value);
    gl.BindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffer);
    gl.BufferData(GL_TRANSFORM_FEEDBACK_BUFFER,
                  static_cast<GLsizeiptr>(values.size() * sizeof(float)),
                  values.data(), GL_DYNAMIC_DRAW);
    checkGLError(gl, "float buffer reset");
}

void writeFloatBufferPattern(const GLApi& gl, GLuint buffer, float first, float rest) {
    std::array<float, 16> values = {};
    values.fill(rest);
    values[0] = first;
    gl.BindBuffer(GL_TEXTURE_BUFFER, buffer);
    gl.BufferData(GL_TEXTURE_BUFFER,
                  static_cast<GLsizeiptr>(values.size() * sizeof(float)),
                  values.data(), GL_DYNAMIC_DRAW);
    checkGLError(gl, "float buffer patterned CPU write");
}

std::array<float, 16> readFloatBuffer(const GLApi& gl, GLuint buffer) {
    std::array<float, 16> values = {};
    gl.BindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffer);
    gl.GetBufferSubData(GL_TRANSFORM_FEEDBACK_BUFFER, 0,
                        static_cast<GLsizeiptr>(values.size() * sizeof(float)),
                        values.data());
    checkGLError(gl, "float buffer readback");
    return values;
}

bool sawFloat(const std::array<float, 16>& values, float expected) {
    return std::any_of(values.begin(), values.end(), [&](float value) {
        return std::fabs(value - expected) < 0.01f;
    });
}

std::string firstFloats(const std::array<float, 16>& values) {
    std::ostringstream stream;
    stream << std::fixed << std::setprecision(2)
           << values[0] << "," << values[1] << "," << values[2] << "," << values[3];
    return stream.str();
}

static constexpr const char* kFullscreenVS =
    "#version 330 core\n"
    "layout(location = 0) in vec2 aPos;\n"
    "void main() { gl_Position = vec4(aPos, 0.0, 1.0); }\n";

static constexpr const char* kColorFS =
    "#version 330 core\n"
    "uniform vec4 uColor;\n"
    "out vec4 fragColor;\n"
    "void main() { fragColor = uColor; }\n";

static constexpr const char* kSample2DFS =
    "#version 330 core\n"
    "uniform sampler2D uSource;\n"
    "out vec4 fragColor;\n"
    "void main() { fragColor = texture(uSource, vec2(0.5, 0.5)); }\n";

static constexpr const char* kSampleBufferFS =
    "#version 430 core\n"
    "uniform samplerBuffer uData;\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "    float value = texelFetch(uData, 0).r;\n"
    "    if (abs(value - 7.0) < 0.01) {\n"
    "        fragColor = vec4(0.0, 1.0, 0.0, 1.0);\n"
    "    } else if (abs(value - 5.0) < 0.01) {\n"
    "        fragColor = vec4(1.0, 0.0, 1.0, 1.0);\n"
    "    } else if (abs(value - 1.0) < 0.01) {\n"
    "        fragColor = vec4(1.0, 1.0, 0.0, 1.0);\n"
    "    } else if (abs(value) < 0.01) {\n"
    "        fragColor = vec4(0.0, 0.0, 1.0, 1.0);\n"
    "    } else {\n"
    "        fragColor = vec4(1.0, 0.0, 0.0, 1.0);\n"
    "    }\n"
    "}\n";

static constexpr const char* kMeshVS =
    "#version 410 core\n"
    "out gl_PerVertex { vec4 gl_Position; float gl_PointSize; float gl_ClipDistance[1]; };\n"
    "out vec4 vColor;\n"
    "void main() {\n"
    "    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);\n"
    "    gl_PointSize = 16.0;\n"
    "    gl_ClipDistance[0] = 1.0;\n"
    "    vColor = vec4(0.0, 1.0, 0.0, 1.0);\n"
    "}\n";

static constexpr const char* kMeshGS =
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

static constexpr const char* kMeshFS =
    "#version 410 core\n"
    "in vec4 gColor;\n"
    "out vec4 fragColor;\n"
    "void main() { fragColor = gColor; }\n";

static constexpr const char* kTessVS =
    "#version 430 core\n"
    "out gl_PerVertex { vec4 gl_Position; };\n"
    "void main() {\n"
    "    vec2 p[3] = vec2[3](vec2(-0.75, -0.75), vec2(0.75, -0.75), vec2(0.0, 0.75));\n"
    "    gl_Position = vec4(p[gl_VertexID], 0.0, 1.0);\n"
    "}\n";

static constexpr const char* kTessTCS =
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

static constexpr const char* kTessTES =
    "#version 430 core\n"
    "layout(triangles, equal_spacing, ccw) in;\n"
    "in gl_PerVertex { vec4 gl_Position; } gl_in[];\n"
    "out gl_PerVertex { vec4 gl_Position; };\n"
    "void main() {\n"
    "    gl_Position = gl_TessCoord.x * gl_in[0].gl_Position +\n"
    "                  gl_TessCoord.y * gl_in[1].gl_Position +\n"
    "                  gl_TessCoord.z * gl_in[2].gl_Position;\n"
    "}\n";

static constexpr const char* kTessTfPointTES =
    "#version 430 core\n"
    "layout(triangles, equal_spacing, ccw, point_mode) in;\n"
    "in gl_PerVertex { vec4 gl_Position; } gl_in[];\n"
    "out gl_PerVertex { vec4 gl_Position; float gl_PointSize; };\n"
    "out float tfValue;\n"
    "void main() {\n"
    "    gl_Position = gl_TessCoord.x * gl_in[0].gl_Position +\n"
    "                  gl_TessCoord.y * gl_in[1].gl_Position +\n"
    "                  gl_TessCoord.z * gl_in[2].gl_Position;\n"
    "    gl_PointSize = 20.0;\n"
    "    tfValue = 7.0;\n"
    "}\n";

static constexpr const char* kTessGreenFS =
    "#version 430 core\n"
    "out vec4 fragColor;\n"
    "void main() { fragColor = vec4(0.0, 1.0, 0.0, 1.0); }\n";

static constexpr const char* kGsPointVS =
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

static constexpr const char* kGsPointGS =
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

static constexpr const char* kGsColorFS =
    "#version 430 core\n"
    "in vec4 gColor;\n"
    "out vec4 fragColor;\n"
    "void main() { fragColor = gColor; }\n";

static constexpr const char* kReplayVS =
    "#version 430 core\n"
    "out gl_PerVertex { vec4 gl_Position; float gl_PointSize; };\n"
    "out vec4 gColor;\n"
    "void main() {\n"
    "    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);\n"
    "    gl_PointSize = 20.0;\n"
    "    gColor = vec4(0.0, 1.0, 0.0, 1.0);\n"
    "}\n";

static constexpr const char* kReplayValueVS =
    "#version 430 core\n"
    "layout(location = 0) in float aValue;\n"
    "out gl_PerVertex { vec4 gl_Position; float gl_PointSize; };\n"
    "out vec4 gColor;\n"
    "void main() {\n"
    "    gl_Position = vec4(0.0, 0.0, 0.0, 1.0);\n"
    "    gl_PointSize = 20.0;\n"
    "    if (abs(aValue - 7.0) < 0.01) {\n"
    "        gColor = vec4(0.0, 1.0, 0.0, 1.0);\n"
    "    } else if (abs(aValue - 5.0) < 0.01) {\n"
    "        gColor = vec4(1.0, 0.0, 1.0, 1.0);\n"
    "    } else {\n"
    "        gColor = vec4(1.0, 0.0, 0.0, 1.0);\n"
    "    }\n"
    "}\n";

static constexpr const char* kComputeWriteThreeCS =
    "#version 430 core\n"
    "layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;\n"
    "layout(std430, binding = 0) buffer Data { float value; } dataOut;\n"
    "void main() { dataOut.value = 3.0; }\n";

SentinelResult runSentinel(const std::string& name,
                           const std::function<void(SentinelResult&)>& body) {
    SentinelResult result;
    result.name = name;
    try {
        body(result);
        result.status = "passed";
    } catch (const std::exception& ex) {
        result.status = "failed";
        result.message = ex.what();
    }
    return result;
}

SentinelResult runMeshToTranslatedFbo(RuntimeApi& api) {
    return runSentinel("dcr4f.f2-mesh-to-f1-translated-fbo", [&](SentinelResult& result) {
        const auto& gl = api.gl;
        const GLuint colorProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kFullscreenVS, "fullscreen vertex"},
            {GL_FRAGMENT_SHADER, kColorFS, "color fragment"},
        }, "color program");
        const GLuint sampleProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kFullscreenVS, "fullscreen vertex"},
            {GL_FRAGMENT_SHADER, kSample2DFS, "sample fragment"},
        }, "sample program");
        const GLuint meshProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kMeshVS, "mesh vertex"},
            {GL_GEOMETRY_SHADER, kMeshGS, "mesh geometry"},
            {GL_FRAGMENT_SHADER, kMeshFS, "mesh fragment"},
        }, "mesh-GS program");
        const GLint colorLoc = gl.GetUniformLocation(colorProgram, "uColor");
        const GLint sampleLoc = gl.GetUniformLocation(sampleProgram, "uSource");
        expect(colorLoc >= 0 && sampleLoc >= 0, "required uniforms present");

        GLuint vao = 0;
        GLuint vbo = 0;
        setupFullscreenTriangle(gl, vao, vbo);
        GLuint sourceTex = 0;
        GLuint sourceFbo = 0;
        GLuint destTex = 0;
        GLuint destFbo = 0;
        setupTextureFbo(gl, sourceTex, sourceFbo);
        setupTextureFbo(gl, destTex, destFbo);

        auto execute = [&](bool red) {
            gl.BindFramebuffer(GL_FRAMEBUFFER, sourceFbo);
            gl.Viewport(0, 0, kSize, kSize);
            drawFullscreenColor(gl, colorProgram, colorLoc, vao, 1.0f, 0.0f, 1.0f, 1.0f);
            if (red) {
                ScopedEnvVar zero("APPGL_DCR4C_MESH_GS_ZERO_VSOUT", "1");
                drawMeshPoint(gl, meshProgram);
            } else {
                drawMeshPoint(gl, meshProgram);
            }

            gl.BindFramebuffer(GL_FRAMEBUFFER, destFbo);
            gl.Viewport(0, 0, kSize, kSize);
            gl.ClearColor(0.0f, 0.0f, 0.0f, 1.0f);
            gl.Clear(GL_COLOR_BUFFER_BIT);
            drawFullscreenSample2D(gl, sampleProgram, sampleLoc, vao, sourceTex);
            return readCenter(gl);
        };

        const auto greenPixel = execute(false);
        expect(isGreen(greenPixel), "green mesh->translated path did not produce green");
        result.green = "passed";
        result.observations.push_back("green pixel=" + pixelString(greenPixel));

        const auto redPixel = execute(true);
        expect(!isGreen(redPixel), "red mesh VS-output stub still produced green");
        result.red = "passed";
        result.observations.push_back("red pixel=" + pixelString(redPixel));
        result.message = "F2 mesh FBO producer was consumed by an F1 translated sampler; zeroed VS-output red stub stayed public-observable";

        gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.BindVertexArray(0);
        gl.BindBuffer(GL_ARRAY_BUFFER, 0);
        gl.BindTexture(GL_TEXTURE_2D, 0);
        gl.UseProgram(0);
        gl.DeleteFramebuffers(1, &sourceFbo);
        gl.DeleteFramebuffers(1, &destFbo);
        gl.DeleteTextures(1, &sourceTex);
        gl.DeleteTextures(1, &destTex);
        gl.DeleteBuffers(1, &vbo);
        gl.DeleteVertexArrays(1, &vao);
        gl.DeleteProgram(colorProgram);
        gl.DeleteProgram(sampleProgram);
        gl.DeleteProgram(meshProgram);
        checkGLError(gl, "mesh->translated cleanup");
    });
}

SentinelResult runTessToTranslatedFbo(RuntimeApi& api) {
    return runSentinel("dcr4f.f3-tess-to-f1-translated-fbo", [&](SentinelResult& result) {
        const auto& gl = api.gl;
        const GLuint colorProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kFullscreenVS, "fullscreen vertex"},
            {GL_FRAGMENT_SHADER, kColorFS, "color fragment"},
        }, "color program");
        const GLuint sampleProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kFullscreenVS, "fullscreen vertex"},
            {GL_FRAGMENT_SHADER, kSample2DFS, "sample fragment"},
        }, "sample program");
        const GLuint tessProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kTessVS, "tess vertex"},
            {GL_TESS_CONTROL_SHADER, kTessTCS, "tess control"},
            {GL_TESS_EVALUATION_SHADER, kTessTES, "tess eval"},
            {GL_FRAGMENT_SHADER, kTessGreenFS, "tess fragment"},
        }, "tess green program");
        const GLint colorLoc = gl.GetUniformLocation(colorProgram, "uColor");
        const GLint sampleLoc = gl.GetUniformLocation(sampleProgram, "uSource");
        expect(colorLoc >= 0 && sampleLoc >= 0, "required uniforms present");

        GLuint vao = 0;
        GLuint vbo = 0;
        setupFullscreenTriangle(gl, vao, vbo);
        GLuint sourceTex = 0;
        GLuint sourceFbo = 0;
        GLuint destTex = 0;
        GLuint destFbo = 0;
        setupTextureFbo(gl, sourceTex, sourceFbo);
        setupTextureFbo(gl, destTex, destFbo);

        auto execute = [&](bool red) {
            gl.BindFramebuffer(GL_FRAMEBUFFER, sourceFbo);
            gl.Viewport(0, 0, kSize, kSize);
            drawFullscreenColor(gl, colorProgram, colorLoc, vao, 1.0f, 0.0f, 1.0f, 1.0f);
            if (red) {
                ScopedEnvVar zero("APPGL_DCR4D_TESS_ZERO_FACTORBUF", "1");
                drawTessPatch(gl, tessProgram);
            } else {
                drawTessPatch(gl, tessProgram);
            }

            gl.BindFramebuffer(GL_FRAMEBUFFER, destFbo);
            gl.Viewport(0, 0, kSize, kSize);
            gl.ClearColor(0.0f, 0.0f, 0.0f, 1.0f);
            gl.Clear(GL_COLOR_BUFFER_BIT);
            drawFullscreenSample2D(gl, sampleProgram, sampleLoc, vao, sourceTex);
            return readCenter(gl);
        };

        const auto greenPixel = execute(false);
        expect(isGreen(greenPixel), "green tess->translated path did not produce green");
        result.green = "passed";
        result.observations.push_back("green pixel=" + pixelString(greenPixel));

        const auto redPixel = execute(true);
        expect(!isGreen(redPixel), "red tess factor-buffer stub still produced green");
        result.red = "passed";
        result.observations.push_back("red pixel=" + pixelString(redPixel));
        result.message = "F3 tess FBO producer was consumed by an F1 translated sampler; zeroed-factor red stub stayed public-observable";

        gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.BindVertexArray(0);
        gl.BindBuffer(GL_ARRAY_BUFFER, 0);
        gl.BindTexture(GL_TEXTURE_2D, 0);
        gl.UseProgram(0);
        gl.DeleteFramebuffers(1, &sourceFbo);
        gl.DeleteFramebuffers(1, &destFbo);
        gl.DeleteTextures(1, &sourceTex);
        gl.DeleteTextures(1, &destTex);
        gl.DeleteBuffers(1, &vbo);
        gl.DeleteVertexArrays(1, &vao);
        gl.DeleteProgram(colorProgram);
        gl.DeleteProgram(sampleProgram);
        gl.DeleteProgram(tessProgram);
        checkGLError(gl, "tess->translated cleanup");
    });
}

SentinelResult runCpuWriteToTextureBufferControl(RuntimeApi& api) {
    return runSentinel("dcr4f.control1-cpu-bufferdata-to-f1-texture-buffer-sample", [&](SentinelResult& result) {
        const auto& gl = api.gl;
        const GLuint sampleProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kFullscreenVS, "fullscreen vertex"},
            {GL_FRAGMENT_SHADER, kSampleBufferFS, "buffer sample fragment"},
        }, "buffer sample program");
        const GLint sampleLoc = gl.GetUniformLocation(sampleProgram, "uData");
        expect(sampleLoc >= 0, "buffer sampler uniform present");

        GLuint vao = 0;
        GLuint vbo = 0;
        setupFullscreenTriangle(gl, vao, vbo);
        GLuint buffer = 0;
        gl.GenBuffers(1, &buffer);
        writeFloatBufferPattern(gl, buffer, 7.0f, 5.0f);
        GLuint tbo = 0;
        gl.GenTextures(1, &tbo);
        gl.BindTexture(GL_TEXTURE_BUFFER, tbo);
        gl.TexBuffer(GL_TEXTURE_BUFFER, GL_R32F, buffer);
        checkGLError(gl, "control texture-buffer setup");

        GLuint colorTex = 0;
        GLuint fbo = 0;
        setupTextureFbo(gl, colorTex, fbo);
        gl.BindFramebuffer(GL_FRAMEBUFFER, fbo);
        gl.Viewport(0, 0, kSize, kSize);
        gl.ClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.Clear(GL_COLOR_BUFFER_BIT);
        drawFullscreenSampleBuffer(gl, sampleProgram, sampleLoc, vao, tbo);
        const auto pixel = readCenter(gl);
        const auto values = readFloatBuffer(gl, buffer);
        const bool pixelOk = isGreen(pixel);
        const bool bufferOk = sawFloat(values, 7.0f);
        result.green = (pixelOk && bufferOk) ? "passed" : "failed";
        result.red = "not-applicable";
        result.observations.push_back("cpu-write sample pixel=" + pixelString(pixel) +
                                      " floats=" + firstFloats(values));
        result.message = "Plain CPU glBufferData P=7/Q=5 texture-buffer sample sanity control";

        gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.BindBuffer(GL_TEXTURE_BUFFER, 0);
        gl.BindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, 0);
        gl.BindTexture(GL_TEXTURE_BUFFER, 0);
        gl.UseProgram(0);
        gl.DeleteFramebuffers(1, &fbo);
        gl.DeleteTextures(1, &colorTex);
        gl.DeleteTextures(1, &tbo);
        gl.DeleteBuffers(1, &buffer);
        gl.DeleteBuffers(1, &vbo);
        gl.DeleteVertexArrays(1, &vao);
        gl.DeleteProgram(sampleProgram);
        checkGLError(gl, "CPU-write texture-buffer control cleanup");

        expect(pixelOk, "plain CPU write was not observed through texture-buffer sample");
        expect(bufferOk, "plain CPU write buffer did not contain P=7");
    });
}

SentinelResult runCpuWriteToRgbaTextureBufferControl(RuntimeApi& api) {
    return runSentinel("dcr4f.control1b-cpu-bufferdata-rgba32f-to-f1-texture-buffer-sample", [&](SentinelResult& result) {
        const auto& gl = api.gl;
        const GLuint sampleProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kFullscreenVS, "fullscreen vertex"},
            {GL_FRAGMENT_SHADER, kSampleBufferFS, "buffer sample fragment"},
        }, "buffer sample program");
        const GLint sampleLoc = gl.GetUniformLocation(sampleProgram, "uData");
        expect(sampleLoc >= 0, "buffer sampler uniform present");

        GLuint vao = 0;
        GLuint vbo = 0;
        setupFullscreenTriangle(gl, vao, vbo);
        GLuint buffer = 0;
        gl.GenBuffers(1, &buffer);
        writeFloatBufferPattern(gl, buffer, 7.0f, 5.0f);
        GLuint tbo = 0;
        gl.GenTextures(1, &tbo);
        gl.BindTexture(GL_TEXTURE_BUFFER, tbo);
        gl.TexBuffer(GL_TEXTURE_BUFFER, GL_RGBA32F, buffer);
        checkGLError(gl, "RGBA32F control texture-buffer setup");

        GLuint colorTex = 0;
        GLuint fbo = 0;
        setupTextureFbo(gl, colorTex, fbo);
        gl.BindFramebuffer(GL_FRAMEBUFFER, fbo);
        gl.Viewport(0, 0, kSize, kSize);
        gl.ClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.Clear(GL_COLOR_BUFFER_BIT);
        drawFullscreenSampleBuffer(gl, sampleProgram, sampleLoc, vao, tbo);
        const auto pixel = readCenter(gl);
        const auto values = readFloatBuffer(gl, buffer);
        const bool pixelOk = isGreen(pixel);
        const bool bufferOk = sawFloat(values, 7.0f);
        result.green = (pixelOk && bufferOk) ? "passed" : "failed";
        result.red = "not-applicable";
        result.observations.push_back("rgba32f cpu-write sample pixel=" + pixelString(pixel) +
                                      " floats=" + firstFloats(values));
        result.message = "Plain CPU glBufferData P=7/Q=5 texture-buffer sample sanity control with GL_RGBA32F vector texels";

        gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.BindBuffer(GL_TEXTURE_BUFFER, 0);
        gl.BindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, 0);
        gl.BindTexture(GL_TEXTURE_BUFFER, 0);
        gl.UseProgram(0);
        gl.DeleteFramebuffers(1, &fbo);
        gl.DeleteTextures(1, &colorTex);
        gl.DeleteTextures(1, &tbo);
        gl.DeleteBuffers(1, &buffer);
        gl.DeleteBuffers(1, &vbo);
        gl.DeleteVertexArrays(1, &vao);
        gl.DeleteProgram(sampleProgram);
        checkGLError(gl, "RGBA32F CPU-write texture-buffer control cleanup");

        expect(pixelOk, "plain RGBA32F CPU write was not observed through texture-buffer sample");
        expect(bufferOk, "plain RGBA32F CPU write buffer did not contain P=7");
    });
}

SentinelResult runF4TfToF1BufferAlias(RuntimeApi& api) {
    return runSentinel("dcr4f.f4-tf-buffer-to-f1-texture-buffer-alias", [&](SentinelResult& result) {
        const auto& gl = api.gl;
        const char* tfName = "tfValue";
        const GLuint gsProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kGsPointVS, "GS vertex"},
            {GL_GEOMETRY_SHADER, kGsPointGS, "GS geometry"},
            {GL_FRAGMENT_SHADER, kGsColorFS, "GS fragment"},
        }, "GS TF program", &tfName, 1);
        const GLuint sampleProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kFullscreenVS, "fullscreen vertex"},
            {GL_FRAGMENT_SHADER, kSampleBufferFS, "buffer sample fragment"},
        }, "buffer sample program");
        const GLint sampleLoc = gl.GetUniformLocation(sampleProgram, "uData");
        expect(sampleLoc >= 0, "buffer sampler uniform present");

        GLuint vao = 0;
        GLuint vbo = 0;
        setupFullscreenTriangle(gl, vao, vbo);
        GLuint tfBuffer = 0;
        gl.GenBuffers(1, &tfBuffer);
        resetFloatBuffer(gl, tfBuffer, 5.0f);
        const GLuint tf = createTfObject(gl, tfBuffer);
        GLuint tbo = 0;
        gl.GenTextures(1, &tbo);
        auto rebindTextureBuffer = [&] {
            gl.BindTexture(GL_TEXTURE_BUFFER, tbo);
            gl.TexBuffer(GL_TEXTURE_BUFFER, GL_R32F, tfBuffer);
            checkGLError(gl, "TF buffer texture alias setup");
        };
        rebindTextureBuffer();

        GLuint colorTex = 0;
        GLuint fbo = 0;
        setupTextureFbo(gl, colorTex, fbo);

        auto execute = [&](bool skipProducerMark) {
            resetFloatBuffer(gl, tfBuffer, 5.0f);
            rebindTextureBuffer();
            if (skipProducerMark) {
                ScopedEnvVar skipMark("APPGL_DCR4E_TF_SKIP_PRODUCER_MARK", "1");
                captureGsTfPoint(gl, gsProgram, tf, tfBuffer, false);
            } else {
                captureGsTfPoint(gl, gsProgram, tf, tfBuffer, false);
            }
            gl.BindFramebuffer(GL_FRAMEBUFFER, fbo);
            gl.Viewport(0, 0, kSize, kSize);
            gl.ClearColor(0.0f, 0.0f, 0.0f, 1.0f);
            gl.Clear(GL_COLOR_BUFFER_BIT);
            drawFullscreenSampleBuffer(gl, sampleProgram, sampleLoc, vao, tbo);
            const auto pixel = readCenter(gl);
            const auto values = readFloatBuffer(gl, tfBuffer);
            return std::make_pair(pixel, values);
        };

        const auto green = execute(false);
        const bool greenPixelOk = isGreen(green.first);
        const bool greenBufferOk = sawFloat(green.second, 7.0f);
        result.green = (greenPixelOk && greenBufferOk) ? "passed" : "failed";
        result.observations.push_back("green pixel=" + pixelString(green.first) +
                                      " floats=" + firstFloats(green.second));

        const auto red = execute(true);
        const bool redPixelOk = !isGreen(red.first);
        const bool redBufferOk = sawFloat(red.second, 7.0f);
        if (greenPixelOk && greenBufferOk) {
            result.red = (redPixelOk && redBufferOk) ? "passed" : "failed";
        } else {
            result.red = "not-interpretable";
        }
        result.observations.push_back("mark-skip red pixel=" + pixelString(red.first) +
                                      " floats=" + firstFloats(red.second));
        result.message = "F4 CPU-GS TF buffer write was consumed through an F1 texture-buffer alias after rebinding the buffer texture; mark-skip red keeps P=7 CPU-visible";

        gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.BindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
        gl.BindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, 0);
        gl.BindBuffer(GL_ARRAY_BUFFER, 0);
        gl.BindTexture(GL_TEXTURE_BUFFER, 0);
        gl.UseProgram(0);
        gl.DeleteFramebuffers(1, &fbo);
        gl.DeleteTextures(1, &colorTex);
        gl.DeleteTextures(1, &tbo);
        gl.DeleteTransformFeedbacks(1, &tf);
        gl.DeleteBuffers(1, &tfBuffer);
        gl.DeleteBuffers(1, &vbo);
        gl.DeleteVertexArrays(1, &vao);
        gl.DeleteProgram(gsProgram);
        gl.DeleteProgram(sampleProgram);
        checkGLError(gl, "F4 TF alias cleanup");

        expect(greenPixelOk, "F4 TF value was not observed through F1 texture-buffer alias");
        expect(greenBufferOk, "green TF buffer did not contain 7.0");
        if (result.red != "not-interpretable") {
            expect(redPixelOk, "F4 skipped producer mark still sampled as green");
            expect(redBufferOk, "F4 skipped producer mark red did not keep P=7 CPU-visible");
        }
    });
}

SentinelResult runF4TfReplayVsTextureBufferControl(RuntimeApi& api) {
    return runSentinel("dcr4f.control2-f4-tf-to-stream-replay-vs-texture-buffer", [&](SentinelResult& result) {
        const auto& gl = api.gl;
        const char* tfName = "tfValue";
        const GLuint gsProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kGsPointVS, "GS vertex"},
            {GL_GEOMETRY_SHADER, kGsPointGS, "GS geometry"},
            {GL_FRAGMENT_SHADER, kGsColorFS, "GS fragment"},
        }, "GS TF program", &tfName, 1);
        const GLuint replayProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kReplayValueVS, "replay value vertex"},
            {GL_FRAGMENT_SHADER, kGsColorFS, "replay value fragment"},
        }, "stream replay value program");
        const GLuint sampleProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kFullscreenVS, "fullscreen vertex"},
            {GL_FRAGMENT_SHADER, kSampleBufferFS, "buffer sample fragment"},
        }, "buffer sample program");
        const GLint sampleLoc = gl.GetUniformLocation(sampleProgram, "uData");
        expect(sampleLoc >= 0, "buffer sampler uniform present");

        GLuint fullscreenVao = 0;
        GLuint fullscreenVbo = 0;
        setupFullscreenTriangle(gl, fullscreenVao, fullscreenVbo);
        GLuint replayVao = 0;
        gl.GenVertexArrays(1, &replayVao);
        GLuint tfBuffer = 0;
        gl.GenBuffers(1, &tfBuffer);
        resetFloatBuffer(gl, tfBuffer, 5.0f);
        const GLuint tf = createTfObject(gl, tfBuffer);
        GLuint tbo = 0;
        gl.GenTextures(1, &tbo);
        auto rebindTextureBuffer = [&] {
            gl.BindTexture(GL_TEXTURE_BUFFER, tbo);
            gl.TexBuffer(GL_TEXTURE_BUFFER, GL_R32F, tfBuffer);
            checkGLError(gl, "control TF texture-buffer alias setup");
        };
        rebindTextureBuffer();

        GLuint colorTex = 0;
        GLuint fbo = 0;
        setupTextureFbo(gl, colorTex, fbo);

        auto recapture = [&] {
            resetFloatBuffer(gl, tfBuffer, 5.0f);
            rebindTextureBuffer();
            captureGsTfPoint(gl, gsProgram, tf, tfBuffer, false);
        };

        recapture();
        gl.BindFramebuffer(GL_FRAMEBUFFER, fbo);
        gl.Viewport(0, 0, kSize, kSize);
        gl.ClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.Clear(GL_COLOR_BUFFER_BIT);
        gl.BindVertexArray(replayVao);
        gl.BindBuffer(GL_ARRAY_BUFFER, tfBuffer);
        gl.EnableVertexAttribArray(0);
        gl.VertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 0, nullptr);
        gl.UseProgram(replayProgram);
        gl.Enable(GL_PROGRAM_POINT_SIZE);
        gl.DrawTransformFeedbackStream(GL_POINTS, tf, 0);
        checkGLError(gl, "control TF stream replay value draw");
        const auto replayPixel = readCenter(gl);

        recapture();
        gl.BindFramebuffer(GL_FRAMEBUFFER, fbo);
        gl.Viewport(0, 0, kSize, kSize);
        gl.ClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.Clear(GL_COLOR_BUFFER_BIT);
        drawFullscreenSampleBuffer(gl, sampleProgram, sampleLoc, fullscreenVao, tbo);
        const auto tboPixel = readCenter(gl);
        const auto values = readFloatBuffer(gl, tfBuffer);

        const bool replayOk = isGreen(replayPixel);
        const bool textureOk = isGreen(tboPixel);
        const bool bufferOk = sawFloat(values, 7.0f);
        result.green = replayOk ? "passed" : "failed";
        result.red = textureOk ? "unexpected-green" : "scoped-non-green";
        result.observations.push_back("stream-replay vertex pixel=" + pixelString(replayPixel));
        result.observations.push_back("texture-buffer sample pixel=" + pixelString(tboPixel) +
                                      " floats=" + firstFloats(values));
        result.message = "Same F4 CPU-GS TF P=7 buffer consumed via stream replay/vertex read and texture-buffer fetch in separate clean executions";

        gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.BindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
        gl.BindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, 0);
        gl.BindBuffer(GL_ARRAY_BUFFER, 0);
        gl.BindTexture(GL_TEXTURE_BUFFER, 0);
        gl.BindVertexArray(0);
        gl.UseProgram(0);
        gl.DeleteFramebuffers(1, &fbo);
        gl.DeleteTextures(1, &colorTex);
        gl.DeleteTextures(1, &tbo);
        gl.DeleteTransformFeedbacks(1, &tf);
        gl.DeleteBuffers(1, &tfBuffer);
        gl.DeleteBuffers(1, &fullscreenVbo);
        gl.DeleteVertexArrays(1, &fullscreenVao);
        gl.DeleteVertexArrays(1, &replayVao);
        gl.DeleteProgram(gsProgram);
        gl.DeleteProgram(replayProgram);
        gl.DeleteProgram(sampleProgram);
        checkGLError(gl, "F4 TF replay-vs-texture-buffer control cleanup");

        expect(replayOk, "F4 TF P=7 was not observed through stream replay vertex read");
        expect(bufferOk, "F4 TF control buffer did not contain P=7");
    });
}

SentinelResult runF4TfLifecycleRedefine(RuntimeApi& api) {
    return runSentinel("dcr4f.f4-tf-buffer-lifecycle-redefine", [&](SentinelResult& result) {
        const auto& gl = api.gl;
        const char* tfName = "tfValue";
        const GLuint gsProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kGsPointVS, "GS vertex"},
            {GL_GEOMETRY_SHADER, kGsPointGS, "GS geometry"},
            {GL_FRAGMENT_SHADER, kGsColorFS, "GS fragment"},
        }, "GS TF program", &tfName, 1);

        GLuint tfBuffer = 0;
        gl.GenBuffers(1, &tfBuffer);
        resetFloatBuffer(gl, tfBuffer, 5.0f);
        const GLuint tf = createTfObject(gl, tfBuffer);

        captureGsTfPoint(gl, gsProgram, tf, tfBuffer, false);
        const auto green = readFloatBuffer(gl, tfBuffer);
        const bool greenOk = sawFloat(green, 7.0f);
        result.green = greenOk ? "passed" : "failed";
        result.observations.push_back("green floats=" + firstFloats(green));

        resetFloatBuffer(gl, tfBuffer, 5.0f);
        captureGsTfPoint(gl, gsProgram, tf, tfBuffer, false);
        resetFloatBuffer(gl, tfBuffer, 11.0f);
        const auto lifecycle = readFloatBuffer(gl, tfBuffer);
        const bool lifecycleOk = sawFloat(lifecycle, 11.0f) && !sawFloat(lifecycle, 7.0f);
        result.observations.push_back("lifecycle redefine floats=" + firstFloats(lifecycle));

        resetFloatBuffer(gl, tfBuffer, 5.0f);
        captureGsTfPoint(gl, gsProgram, tf, tfBuffer, true);
        const auto red = readFloatBuffer(gl, tfBuffer);
        const bool redOk = !sawFloat(red, 7.0f) && sawFloat(red, 5.0f);
        result.red = redOk ? "passed" : "failed";
        result.observations.push_back("red floats=" + firstFloats(red));
        result.message = "F4 TF bytes are publicly readable, skipped-write preserves Q=5, and buffer redefinition after an unconsumed P=7 capture replaces storage with lifecycle Q=11";

        gl.BindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
        gl.BindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, 0);
        gl.UseProgram(0);
        gl.DeleteTransformFeedbacks(1, &tf);
        gl.DeleteBuffers(1, &tfBuffer);
        gl.DeleteProgram(gsProgram);
        checkGLError(gl, "F4 TF lifecycle cleanup");

        expect(greenOk, "F4 TF lifecycle green capture did not write P=7");
        expect(lifecycleOk, "F4 TF lifecycle redefine did not replace buffer contents with Q=11");
        expect(redOk, "F4 TF lifecycle skipped-write did not preserve Q=5");
    });
}

SentinelResult runComputePendingToTessTf(RuntimeApi& api) {
    return runSentinel("dcr4f.f1-compute-pending-to-f3-tess-tf-same-buffer", [&](SentinelResult& result) {
        const auto& gl = api.gl;
        const char* tfName = "tfValue";
        const GLuint computeProgram = buildProgram(gl, {
            {GL_COMPUTE_SHADER, kComputeWriteThreeCS, "compute write-three"},
        }, "compute write-three program");
        const GLuint tessTfProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kTessVS, "tess vertex"},
            {GL_TESS_CONTROL_SHADER, kTessTCS, "tess control"},
            {GL_TESS_EVALUATION_SHADER, kTessTfPointTES, "tess TF eval"},
            {GL_FRAGMENT_SHADER, kTessGreenFS, "tess fragment"},
        }, "tess TF point program", &tfName, 1);

        GLuint buffer = 0;
        gl.GenBuffers(1, &buffer);
        resetFloatBuffer(gl, buffer, 0.0f);
        const GLuint tf = createTfObject(gl, buffer);

        auto execute = [&](bool red) {
            resetFloatBuffer(gl, buffer, 0.0f);
            gl.BindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffer);
            gl.UseProgram(computeProgram);
            gl.DispatchCompute(1, 1, 1);
            checkGLError(gl, "F1 compute write-three dispatch");
            captureTessTfPoint(gl, tessTfProgram, tf, buffer, red);
            return readFloatBuffer(gl, buffer);
        };

        const auto green = execute(false);
        expect(sawFloat(green, 7.0f), "F3 tess TF did not overwrite F1 compute Q with P=7");
        expect(!sawFloat(green, 3.0f), "green path still observed stale compute Q=3");
        result.green = "passed";
        result.observations.push_back("green floats=" + firstFloats(green));

        const auto red = execute(true);
        expect(!sawFloat(red, 7.0f) && sawFloat(red, 3.0f),
               "red F3 skipped-write did not expose prior F1 compute Q=3");
        result.red = "passed";
        result.observations.push_back("red floats=" + firstFloats(red));
        result.message = "F1 compute-pending write and F3 CPU-immediate TF write shared one buffer with Q=3/P=7 coverage";

        gl.BindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
        gl.BindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, 0);
        gl.BindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
        gl.UseProgram(0);
        gl.DeleteTransformFeedbacks(1, &tf);
        gl.DeleteBuffers(1, &buffer);
        gl.DeleteProgram(computeProgram);
        gl.DeleteProgram(tessTfProgram);
        checkGLError(gl, "compute->tess TF cleanup");
    });
}

SentinelResult runTessTfToStreamReplay(RuntimeApi& api) {
    return runSentinel("dcr4f.f3-tess-tf-to-f4-stream-replay", [&](SentinelResult& result) {
        const auto& gl = api.gl;
        const char* tfName = "tfValue";
        const GLuint tessTfProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kTessVS, "tess vertex"},
            {GL_TESS_CONTROL_SHADER, kTessTCS, "tess control"},
            {GL_TESS_EVALUATION_SHADER, kTessTfPointTES, "tess TF eval"},
            {GL_FRAGMENT_SHADER, kTessGreenFS, "tess fragment"},
        }, "tess TF point program", &tfName, 1);
        const GLuint replayProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kReplayVS, "replay vertex"},
            {GL_FRAGMENT_SHADER, kGsColorFS, "replay fragment"},
        }, "stream replay program");

        GLuint buffer = 0;
        gl.GenBuffers(1, &buffer);
        resetFloatBuffer(gl, buffer, 0.0f);
        const GLuint tf = createTfObject(gl, buffer);
        GLuint colorTex = 0;
        GLuint fbo = 0;
        setupTextureFbo(gl, colorTex, fbo);
        GLuint replayVao = 0;
        gl.GenVertexArrays(1, &replayVao);

        captureTessTfPoint(gl, tessTfProgram, tf, buffer, false);
        gl.BindFramebuffer(GL_FRAMEBUFFER, fbo);
        gl.Viewport(0, 0, kSize, kSize);
        gl.ClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        gl.Clear(GL_COLOR_BUFFER_BIT);
        gl.BindVertexArray(replayVao);
        gl.UseProgram(replayProgram);
        gl.Enable(GL_PROGRAM_POINT_SIZE);
        gl.DrawTransformFeedbackStream(GL_POINTS, tf, 0);
        checkGLError(gl, "tess TF stream replay draw");
        const auto greenPixel = readCenter(gl);
        expect(isGreen(greenPixel), "F4 stream replay did not consume F3 tess TF count");
        result.green = "passed";
        result.observations.push_back("green pixel=" + pixelString(greenPixel));

        gl.ClearColor(1.0f, 0.0f, 1.0f, 1.0f);
        gl.Clear(GL_COLOR_BUFFER_BIT);
        {
            ScopedEnvVar zeroReplay("APPGL_DCR4E_FORCE_STREAM_REPLAY_ZERO_COUNT", "1");
            gl.DrawTransformFeedbackStream(GL_POINTS, tf, 0);
        }
        checkGLError(gl, "forced-zero stream replay draw");
        const auto redPixel = readCenter(gl);
        expect(!isGreen(redPixel) && isMagenta(redPixel),
               "forced-zero stream replay red stub did not preserve Q=magenta");
        result.red = "passed";
        result.observations.push_back("red pixel=" + pixelString(redPixel));
        result.message = "F3 tess TF count was consumed by F4 stream replay; forced zero replay count preserved seeded Q";

        gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
        gl.BindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
        gl.BindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, 0);
        gl.BindVertexArray(0);
        gl.UseProgram(0);
        gl.DeleteFramebuffers(1, &fbo);
        gl.DeleteTextures(1, &colorTex);
        gl.DeleteVertexArrays(1, &replayVao);
        gl.DeleteTransformFeedbacks(1, &tf);
        gl.DeleteBuffers(1, &buffer);
        gl.DeleteProgram(tessTfProgram);
        gl.DeleteProgram(replayProgram);
        checkGLError(gl, "tess TF stream replay cleanup");
    });
}

struct QueryCounts {
    GLuint64 generated = 0;
    GLuint64 written = 0;
};

SentinelResult runMixedQuerySkip(RuntimeApi& api) {
    return runSentinel("dcr4f.mixed-f3-f4-query-skip-half", [&](SentinelResult& result) {
        const auto& gl = api.gl;
        const char* tfName = "tfValue";
        const GLuint tessTfProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kTessVS, "tess vertex"},
            {GL_TESS_CONTROL_SHADER, kTessTCS, "tess control"},
            {GL_TESS_EVALUATION_SHADER, kTessTfPointTES, "tess TF eval"},
            {GL_FRAGMENT_SHADER, kTessGreenFS, "tess fragment"},
        }, "tess TF point program", &tfName, 1);
        const GLuint gsProgram = buildProgram(gl, {
            {GL_VERTEX_SHADER, kGsPointVS, "GS vertex"},
            {GL_GEOMETRY_SHADER, kGsPointGS, "GS geometry"},
            {GL_FRAGMENT_SHADER, kGsColorFS, "GS fragment"},
        }, "GS TF program", &tfName, 1);

        GLuint buffer = 0;
        gl.GenBuffers(1, &buffer);
        resetFloatBuffer(gl, buffer, 0.0f);
        const GLuint tf = createTfObject(gl, buffer);

        auto runQueries = [&](bool skipF4Queries) {
            QueryCounts counts;
            GLuint queries[2] = {};
            gl.GenQueries(2, queries);
            gl.BeginQuery(GL_PRIMITIVES_GENERATED, queries[0]);
            gl.BeginQuery(GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN, queries[1]);
            captureTessTfPoint(gl, tessTfProgram, tf, buffer, false);
            if (skipF4Queries) {
                ScopedEnvVar skip("APPGL_DCR4E_SKIP_QUERY_UPDATES", "1");
                captureGsTfPoint(gl, gsProgram, tf, buffer, false);
            } else {
                captureGsTfPoint(gl, gsProgram, tf, buffer, false);
            }
            gl.EndQuery(GL_TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN);
            gl.EndQuery(GL_PRIMITIVES_GENERATED);
            gl.GetQueryObjectui64v(queries[0], GL_QUERY_RESULT, &counts.generated);
            gl.GetQueryObjectui64v(queries[1], GL_QUERY_RESULT, &counts.written);
            gl.DeleteQueries(2, queries);
            checkGLError(gl, "mixed query readback");
            return counts;
        };

        const QueryCounts green = runQueries(false);
        expect(green.generated > 0 && green.written > 0,
               "mixed F3/F4 query green path did not advance counters");
        result.green = "passed";
        result.observations.push_back("green generated=" + std::to_string(green.generated) +
                                      " written=" + std::to_string(green.written));

        const QueryCounts red = runQueries(true);
        expect(red.generated < green.generated || red.written < green.written,
               "F4 query skip red stub did not lower mixed query counts");
        result.red = "passed";
        result.observations.push_back("red generated=" + std::to_string(red.generated) +
                                      " written=" + std::to_string(red.written));
        result.message = "Mixed F3/F4 query accounting advanced in green and caught a skipped F4 half in red";

        gl.BindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
        gl.BindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, 0);
        gl.UseProgram(0);
        gl.DeleteTransformFeedbacks(1, &tf);
        gl.DeleteBuffers(1, &buffer);
        gl.DeleteProgram(tessTfProgram);
        gl.DeleteProgram(gsProgram);
        checkGLError(gl, "mixed query cleanup");
    });
}

SentinelResult doubleCountDisclosure() {
    SentinelResult result;
    result.name = "dcr4f.mixed-f3-f4-query-double-count-red-stub";
    result.status = "not-run";
    result.green = "not-applicable";
    result.red = "not-constructed";
    result.message =
        "No public runtime red hook currently forces double-counting; DCR4-F must cover this by structural proof or supplementary instrumentation before full gating.";
    return result;
}

std::string jsonEscape(std::string_view value) {
    std::ostringstream stream;
    for (char ch : value) {
        switch (ch) {
        case '\\': stream << "\\\\"; break;
        case '"': stream << "\\\""; break;
        case '\n': stream << "\\n"; break;
        case '\r': stream << "\\r"; break;
        case '\t': stream << "\\t"; break;
        default:
            if (static_cast<unsigned char>(ch) < 0x20) {
                stream << "\\u"
                       << std::hex << std::setw(4) << std::setfill('0')
                       << static_cast<int>(static_cast<unsigned char>(ch))
                       << std::dec << std::setfill(' ');
            } else {
                stream << ch;
            }
        }
    }
    return stream.str();
}

void emitJson(const Options& options, const std::vector<SentinelResult>& results) {
    int passed = 0;
    int failed = 0;
    int notRun = 0;
    for (const auto& result : results) {
        if (result.status == "passed") {
            ++passed;
        } else if (result.status == "failed") {
            ++failed;
        } else {
            ++notRun;
        }
    }

    std::cout << "{\n"
              << "  \"label\": \"" << jsonEscape(options.label) << "\",\n"
              << "  \"library\": \"" << jsonEscape(options.library) << "\",\n"
              << "  \"kind\": \"dcr4-f-standalone-public-sentinel-construction\",\n"
              << "  \"summary\": {\n"
              << "    \"passed\": " << passed << ",\n"
              << "    \"failed\": " << failed << ",\n"
              << "    \"not_run\": " << notRun << "\n"
              << "  },\n"
              << "  \"results\": [\n";
    for (std::size_t i = 0; i < results.size(); ++i) {
        const auto& result = results[i];
        std::cout << "    {\n"
                  << "      \"name\": \"" << jsonEscape(result.name) << "\",\n"
                  << "      \"status\": \"" << jsonEscape(result.status) << "\",\n"
                  << "      \"green\": \"" << jsonEscape(result.green) << "\",\n"
                  << "      \"red\": \"" << jsonEscape(result.red) << "\",\n"
                  << "      \"message\": \"" << jsonEscape(result.message) << "\",\n"
                  << "      \"observations\": [";
        for (std::size_t j = 0; j < result.observations.size(); ++j) {
            if (j != 0) {
                std::cout << ", ";
            }
            std::cout << "\"" << jsonEscape(result.observations[j]) << "\"";
        }
        std::cout << "]\n"
                  << "    }" << (i + 1 == results.size() ? "\n" : ",\n");
    }
    std::cout << "  ]\n"
              << "}\n";
}

std::vector<SentinelCase> sentinelCases() {
    return {
        {"dcr4f.f2-mesh-to-f1-translated-fbo", runMeshToTranslatedFbo},
        {"dcr4f.f3-tess-to-f1-translated-fbo", runTessToTranslatedFbo},
        {"dcr4f.control1-cpu-bufferdata-to-f1-texture-buffer-sample",
         runCpuWriteToTextureBufferControl},
        {"dcr4f.control1b-cpu-bufferdata-rgba32f-to-f1-texture-buffer-sample",
         runCpuWriteToRgbaTextureBufferControl},
        {"dcr4f.f4-tf-buffer-to-f1-texture-buffer-alias", runF4TfToF1BufferAlias},
        {"dcr4f.control2-f4-tf-to-stream-replay-vs-texture-buffer",
         runF4TfReplayVsTextureBufferControl},
        {"dcr4f.f4-tf-buffer-lifecycle-redefine", runF4TfLifecycleRedefine},
        {"dcr4f.f1-compute-pending-to-f3-tess-tf-same-buffer", runComputePendingToTessTf},
        {"dcr4f.f3-tess-tf-to-f4-stream-replay", runTessTfToStreamReplay},
        {"dcr4f.mixed-f3-f4-query-skip-half", runMixedQuerySkip},
    };
}

std::vector<SentinelResult> runSelectedInProcess(const Options& options) {
    RuntimeApi api = loadRuntime(options);

    std::vector<SentinelResult> results;
    auto runWithContext = [&](const char* label,
                              SentinelResult (*runner)(RuntimeApi&)) {
        std::cerr << "BEGIN " << label << "\n";
        AppGLContext* context = api.createOffscreen(64, 64);
        if (context == nullptr) {
            SentinelResult result;
            result.name = label;
            result.status = "failed";
            result.message = "failed to create AppGL offscreen context";
            return result;
        }
        api.makeCurrent(context);
        SentinelResult result = runner(api);
        api.gl.Finish();
        api.makeCurrent(nullptr);
        api.destroyContext(context);
        std::cerr << "END " << label << " status=" << result.status << "\n";
        return result;
    };

    auto shouldRun = [&](const char* name) {
        return options.only.empty() || options.only == name;
    };
    for (const auto& sentinel : sentinelCases()) {
        if (shouldRun(sentinel.name)) {
            results.push_back(runWithContext(sentinel.name, sentinel.runner));
        }
    }
    if (shouldRun("dcr4f.mixed-f3-f4-query-double-count-red-stub")) {
        results.push_back(doubleCountDisclosure());
    }
    if (api.handle != nullptr) {
        dlclose(api.handle);
    }
    return results;
}

void writeAll(int fd, const void* data, std::size_t size) {
    const auto* bytes = static_cast<const char*>(data);
    while (size > 0) {
        const ssize_t written = write(fd, bytes, size);
        if (written <= 0) {
            _exit(125);
        }
        bytes += written;
        size -= static_cast<std::size_t>(written);
    }
}

void readAll(int fd, void* data, std::size_t size) {
    auto* bytes = static_cast<char*>(data);
    while (size > 0) {
        const ssize_t got = read(fd, bytes, size);
        if (got <= 0) {
            fail("failed to read child sentinel result");
        }
        bytes += got;
        size -= static_cast<std::size_t>(got);
    }
}

void writeString(int fd, const std::string& value) {
    const std::uint64_t size = value.size();
    writeAll(fd, &size, sizeof(size));
    if (!value.empty()) {
        writeAll(fd, value.data(), value.size());
    }
}

std::string readString(int fd) {
    std::uint64_t size = 0;
    readAll(fd, &size, sizeof(size));
    if (size > 1024 * 1024) {
        fail("child sentinel result string was unexpectedly large");
    }
    std::string value(static_cast<std::size_t>(size), '\0');
    if (size > 0) {
        readAll(fd, value.data(), value.size());
    }
    return value;
}

void writeResult(int fd, const SentinelResult& result) {
    writeString(fd, result.name);
    writeString(fd, result.status);
    writeString(fd, result.green);
    writeString(fd, result.red);
    writeString(fd, result.message);
    const std::uint64_t observationCount = result.observations.size();
    writeAll(fd, &observationCount, sizeof(observationCount));
    for (const auto& observation : result.observations) {
        writeString(fd, observation);
    }
}

SentinelResult readResult(int fd) {
    SentinelResult result;
    result.name = readString(fd);
    result.status = readString(fd);
    result.green = readString(fd);
    result.red = readString(fd);
    result.message = readString(fd);
    std::uint64_t observationCount = 0;
    readAll(fd, &observationCount, sizeof(observationCount));
    if (observationCount > 1024) {
        fail("child sentinel returned too many observations");
    }
    for (std::uint64_t i = 0; i < observationCount; ++i) {
        result.observations.push_back(readString(fd));
    }
    return result;
}

SentinelResult runOneInChild(const Options& options, const SentinelCase& sentinel) {
    int pipeFds[2] = {-1, -1};
    if (pipe(pipeFds) != 0) {
        fail("failed to create child result pipe");
    }

    const pid_t pid = fork();
    if (pid < 0) {
        close(pipeFds[0]);
        close(pipeFds[1]);
        fail("failed to fork child sentinel process");
    }
    if (pid == 0) {
        close(pipeFds[0]);
        Options childOptions = options;
        childOptions.only = sentinel.name;
        SentinelResult result;
        try {
            const auto childResults = runSelectedInProcess(childOptions);
            if (!childResults.empty()) {
                result = childResults.front();
            } else {
                result.name = sentinel.name;
                result.status = "failed";
                result.message = "child sentinel produced no result";
            }
        } catch (const std::exception& ex) {
            result.name = sentinel.name;
            result.status = "failed";
            result.message = ex.what();
        }
        writeResult(pipeFds[1], result);
        close(pipeFds[1]);
        _exit(result.status == "failed" ? 1 : 0);
    }

    close(pipeFds[1]);
    SentinelResult result;
    try {
        result = readResult(pipeFds[0]);
    } catch (const std::exception& ex) {
        result.name = sentinel.name;
        result.status = "failed";
        result.message = ex.what();
    }
    close(pipeFds[0]);

    int childStatus = 0;
    if (waitpid(pid, &childStatus, 0) < 0) {
        fail("failed to wait for child sentinel process");
    }
    if (WIFSIGNALED(childStatus)) {
        result.name = sentinel.name;
        result.status = "failed";
        result.message = "child sentinel terminated by signal " +
                         std::to_string(WTERMSIG(childStatus));
    } else if (WIFEXITED(childStatus) && WEXITSTATUS(childStatus) != 0 &&
               result.status != "failed") {
        result.status = "failed";
        result.message = "child sentinel exited " +
                         std::to_string(WEXITSTATUS(childStatus));
    }
    return result;
}

std::vector<SentinelResult> runAllOutOfProcess(const Options& options) {
    std::vector<SentinelResult> results;
    for (const auto& sentinel : sentinelCases()) {
        std::cerr << "BEGIN " << sentinel.name << " child\n";
        SentinelResult result = runOneInChild(options, sentinel);
        std::cerr << "END " << sentinel.name << " child status="
                  << result.status << "\n";
        results.push_back(std::move(result));
    }
    results.push_back(doubleCountDisclosure());
    return results;
}

} // namespace

int main(int argc, char** argv) {
    try {
        const Options options = parseOptions(argc, argv);
        std::vector<SentinelResult> results =
            options.only.empty()
                ? runAllOutOfProcess(options)
                : runSelectedInProcess(options);
        if (results.empty()) {
            fail("no sentinel matched --only=" + options.only);
        }
        emitJson(options, results);

        const bool failed = std::any_of(results.begin(), results.end(), [](const SentinelResult& result) {
            return result.status == "failed";
        });
        return failed ? 1 : 0;
    } catch (const std::exception& ex) {
        std::cerr << "fatal: " << ex.what() << "\n";
        return 2;
    }
}
