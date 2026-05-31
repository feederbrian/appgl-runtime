#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "AppGL/AppGL.h"
#include "AppGL/glcorearb.h"

namespace {

using Clock = std::chrono::steady_clock;

using CreateOffscreenFn = AppGLContext* (*)(int, int);
using DestroyContextFn = void (*)(AppGLContext*);
using MakeCurrentFn = void (*)(AppGLContext*);
using SwapBuffersFn = void (*)(AppGLContext*);
using GetProcAddressFn = AppGLProc (*)(const char*);

struct Options {
    std::string library = "libAppGL.dylib";
    std::string label = "bar-b";
    std::string mode = "producer";
    int size = 128;
    int frames = 96;
    int warmupFrames = 8;
    int chainDraws = 48;
    int uploadEvery = 24;
    int shaderIters = 4;
};

struct GLApi {
    PFNGLACTIVETEXTUREPROC ActiveTexture = nullptr;
    PFNGLATTACHSHADERPROC AttachShader = nullptr;
    PFNGLBINDBUFFERPROC BindBuffer = nullptr;
    PFNGLBINDFRAMEBUFFERPROC BindFramebuffer = nullptr;
    PFNGLBINDTEXTUREPROC BindTexture = nullptr;
    PFNGLBINDVERTEXARRAYPROC BindVertexArray = nullptr;
    PFNGLBUFFERDATAPROC BufferData = nullptr;
    PFNGLCHECKFRAMEBUFFERSTATUSPROC CheckFramebufferStatus = nullptr;
    PFNGLCOMPILESHADERPROC CompileShader = nullptr;
    PFNGLCREATEPROGRAMPROC CreateProgram = nullptr;
    PFNGLCREATESHADERPROC CreateShader = nullptr;
    PFNGLDELETEBUFFERSPROC DeleteBuffers = nullptr;
    PFNGLDELETEFRAMEBUFFERSPROC DeleteFramebuffers = nullptr;
    PFNGLDELETEPROGRAMPROC DeleteProgram = nullptr;
    PFNGLDELETESHADERPROC DeleteShader = nullptr;
    PFNGLDELETETEXTURESPROC DeleteTextures = nullptr;
    PFNGLDELETEVERTEXARRAYSPROC DeleteVertexArrays = nullptr;
    PFNGLDRAWARRAYSPROC DrawArrays = nullptr;
    PFNGLDRAWELEMENTSPROC DrawElements = nullptr;
    PFNGLDRAWBUFFERPROC DrawBuffer = nullptr;
    PFNGLENABLEVERTEXATTRIBARRAYPROC EnableVertexAttribArray = nullptr;
    PFNGLFINISHPROC Finish = nullptr;
    PFNGLFRAMEBUFFERTEXTURE2DPROC FramebufferTexture2D = nullptr;
    PFNGLGENBUFFERSPROC GenBuffers = nullptr;
    PFNGLGENFRAMEBUFFERSPROC GenFramebuffers = nullptr;
    PFNGLGENTEXTURESPROC GenTextures = nullptr;
    PFNGLGENVERTEXARRAYSPROC GenVertexArrays = nullptr;
    PFNGLGETERRORPROC GetError = nullptr;
    PFNGLGETPROGRAMINFOLOGPROC GetProgramInfoLog = nullptr;
    PFNGLGETPROGRAMIVPROC GetProgramiv = nullptr;
    PFNGLGETSHADERINFOLOGPROC GetShaderInfoLog = nullptr;
    PFNGLGETSHADERIVPROC GetShaderiv = nullptr;
    PFNGLGETUNIFORMLOCATIONPROC GetUniformLocation = nullptr;
    PFNGLLINKPROGRAMPROC LinkProgram = nullptr;
    PFNGLREADBUFFERPROC ReadBuffer = nullptr;
    PFNGLREADPIXELSPROC ReadPixels = nullptr;
    PFNGLSHADERSOURCEPROC ShaderSource = nullptr;
    PFNGLTEXIMAGE2DPROC TexImage2D = nullptr;
    PFNGLTEXPARAMETERIPROC TexParameteri = nullptr;
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
    SwapBuffersFn swapBuffers = nullptr;
    GetProcAddressFn getProcAddress = nullptr;
    GLApi gl;
};

struct RunResult {
    int frames = 0;
    int chainDraws = 0;
    int drawsPerFrame = 0;
    int totalDraws = 0;
    int textureUploads = 0;
    double coreMs = 0.0;
    double perDrawUs = 0.0;
    double isolatedReadbackMs = 0.0;
    double finishMs = 0.0;
    std::array<unsigned char, 4> readbackPixel{0, 0, 0, 0};
};

enum class ProfileBucket : std::size_t {
    BindFramebuffer,
    Viewport,
    UseProgram,
    BindVertexArray,
    Uniform,
    ActiveTexture,
    BindTexture,
    DrawArrays,
    DrawElements,
    TexImage2D,
    SwapBuffers,
    Finish,
    Count,
};

struct ProfileBucketStats {
    std::uint64_t count = 0;
    double totalUs = 0.0;
};

struct CoreProfileStats {
    int frames = 0;
    std::array<ProfileBucketStats, static_cast<std::size_t>(ProfileBucket::Count)> buckets{};
    double wallUs = 0.0;

    void add(ProfileBucket bucket, double us) {
        auto& stats = buckets[static_cast<std::size_t>(bucket)];
        ++stats.count;
        stats.totalUs += us;
    }
};

const char* profileBucketName(ProfileBucket bucket) {
    switch (bucket) {
    case ProfileBucket::BindFramebuffer: return "bind_framebuffer";
    case ProfileBucket::Viewport: return "viewport";
    case ProfileBucket::UseProgram: return "use_program";
    case ProfileBucket::BindVertexArray: return "bind_vertex_array";
    case ProfileBucket::Uniform: return "uniform";
    case ProfileBucket::ActiveTexture: return "active_texture";
    case ProfileBucket::BindTexture: return "bind_texture";
    case ProfileBucket::DrawArrays: return "draw_arrays";
    case ProfileBucket::DrawElements: return "draw_elements";
    case ProfileBucket::TexImage2D: return "tex_image_2d";
    case ProfileBucket::SwapBuffers: return "swap_buffers";
    case ProfileBucket::Finish: return "finish";
    case ProfileBucket::Count: break;
    }
    return "unknown";
}

double elapsedUs(Clock::time_point start, Clock::time_point end) {
    return std::chrono::duration<double, std::micro>(end - start).count();
}

double profileAccountedUs(const CoreProfileStats& stats) {
    double total = 0.0;
    for (const auto& bucket : stats.buckets) {
        total += bucket.totalUs;
    }
    return total;
}

void dumpCoreProfile(const char* runLabel,
                     const char* segment,
                     const CoreProfileStats& stats) {
    if (stats.frames == 0) {
        return;
    }
    const auto& drawArraysBucket = stats.buckets[static_cast<std::size_t>(ProfileBucket::DrawArrays)];
    const auto& drawElementsBucket = stats.buckets[static_cast<std::size_t>(ProfileBucket::DrawElements)];
    const std::uint64_t drawCalls = drawArraysBucket.count + drawElementsBucket.count;
    const double accountedUs = profileAccountedUs(stats);
    const double denom = stats.wallUs > 0.0 ? stats.wallUs : 1.0;
    std::fprintf(stderr,
        "[APPGL_BARB_PROFILE] run=%s segment=%s frames=%d draw_calls=%llu "
        "wall_us=%.3f wall_per_draw_us=%.3f accounted_us=%.3f "
        "accounted_per_draw_us=%.3f unattributed_us=%.3f\n",
        runLabel,
        segment,
        stats.frames,
        static_cast<unsigned long long>(drawCalls),
        stats.wallUs,
        drawCalls > 0 ? stats.wallUs / static_cast<double>(drawCalls) : 0.0,
        accountedUs,
        drawCalls > 0 ? accountedUs / static_cast<double>(drawCalls) : 0.0,
        std::max(0.0, stats.wallUs - accountedUs));
    for (std::size_t i = 0; i < static_cast<std::size_t>(ProfileBucket::Count); ++i) {
        const auto& bucket = stats.buckets[i];
        if (bucket.count == 0) {
            continue;
        }
        const ProfileBucket bucketId = static_cast<ProfileBucket>(i);
        std::fprintf(stderr,
            "[APPGL_BARB_PROFILE] run=%s segment=%s bucket=%s count=%llu "
            "total_us=%.3f avg_us=%.3f pct_wall=%.2f\n",
            runLabel,
            segment,
            profileBucketName(bucketId),
            static_cast<unsigned long long>(bucket.count),
            bucket.totalUs,
            bucket.totalUs / static_cast<double>(bucket.count),
            (bucket.totalUs * 100.0) / denom);
    }
}

[[noreturn]] void fail(const std::string& message) {
    throw std::runtime_error(message);
}

int parseInt(std::string_view value, std::string_view name) {
    char* end = nullptr;
    const std::string owned(value);
    const long parsed = std::strtol(owned.c_str(), &end, 10);
    if (end == owned.c_str() || *end != '\0' || parsed <= 0 || parsed > 1'000'000) {
        fail("invalid integer for " + std::string(name) + ": " + owned);
    }
    return static_cast<int>(parsed);
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
        } else if (auto value = takeValue("--mode"); !value.empty()) {
            options.mode = std::string(value);
        } else if (auto value = takeValue("--size"); !value.empty()) {
            options.size = parseInt(value, "--size");
        } else if (auto value = takeValue("--frames"); !value.empty()) {
            options.frames = parseInt(value, "--frames");
        } else if (auto value = takeValue("--warmup-frames"); !value.empty()) {
            options.warmupFrames = parseInt(value, "--warmup-frames");
        } else if (auto value = takeValue("--chain-draws"); !value.empty()) {
            options.chainDraws = parseInt(value, "--chain-draws");
        } else if (auto value = takeValue("--upload-every"); !value.empty()) {
            options.uploadEvery = parseInt(value, "--upload-every");
        } else if (auto value = takeValue("--shader-iters"); !value.empty()) {
            options.shaderIters = parseInt(value, "--shader-iters");
        } else if (arg == "--no-uploads") {
            options.uploadEvery = 0;
        } else if (arg == "--help" || arg == "-h") {
            std::cout
                << "Usage: appgl_bar_b_benchmark [options]\n"
                << "  --library PATH        libAppGL.dylib to dlopen (default: libAppGL.dylib)\n"
                << "  --label NAME          label emitted in JSON (default: bar-b)\n"
                << "  --mode producer|pingpong|general\n"
                << "                         producer is primary: many FBO writes, one consume\n"
                << "                         general uses glDrawElements + glFinish, no FBO-sample edge\n"
                << "  --size N              offscreen/FBO size (default: 128)\n"
                << "  --frames N            measured present-once frames (default: 96)\n"
                << "  --warmup-frames N     untimed warmup frames (default: 8)\n"
                << "  --chain-draws N       ping-pong FBO draws per frame after seed (default: 48)\n"
                << "  --upload-every N      depth uploads every N chain draws, or --no-uploads\n"
                << "  --shader-iters N      sample shader work multiplier (default: 4)\n";
            std::exit(0);
        } else {
            fail("unknown argument: " + std::string(arg));
        }
    }

    if (options.uploadEvery < 0) {
        fail("--upload-every must be non-negative");
    }
    if (options.mode != "producer" && options.mode != "pingpong" && options.mode != "general") {
        fail("--mode must be producer, pingpong, or general");
    }
    return options;
}

template <typename T>
void loadSymbol(void* handle, const char* name, T& out) {
    out = reinterpret_cast<T>(dlsym(handle, name));
    if (out == nullptr) {
        fail(std::string("missing dylib symbol ") + name + ": " + dlerror());
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

    RuntimeApi api;
    api.handle = dlopen(options.library.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (api.handle == nullptr) {
        fail("dlopen failed for " + options.library + ": " + dlerror());
    }

    loadSymbol(api.handle, "appglCreateOffscreenContext", api.createOffscreen);
    loadSymbol(api.handle, "appglDestroyContext", api.destroyContext);
    loadSymbol(api.handle, "appglMakeCurrent", api.makeCurrent);
    loadSymbol(api.handle, "appglSwapBuffers", api.swapBuffers);
    loadSymbol(api.handle, "appglGetProcAddress", api.getProcAddress);

    auto& gl = api.gl;
    loadGL(api, "glActiveTexture", gl.ActiveTexture);
    loadGL(api, "glAttachShader", gl.AttachShader);
    loadGL(api, "glBindBuffer", gl.BindBuffer);
    loadGL(api, "glBindFramebuffer", gl.BindFramebuffer);
    loadGL(api, "glBindTexture", gl.BindTexture);
    loadGL(api, "glBindVertexArray", gl.BindVertexArray);
    loadGL(api, "glBufferData", gl.BufferData);
    loadGL(api, "glCheckFramebufferStatus", gl.CheckFramebufferStatus);
    loadGL(api, "glCompileShader", gl.CompileShader);
    loadGL(api, "glCreateProgram", gl.CreateProgram);
    loadGL(api, "glCreateShader", gl.CreateShader);
    loadGL(api, "glDeleteBuffers", gl.DeleteBuffers);
    loadGL(api, "glDeleteFramebuffers", gl.DeleteFramebuffers);
    loadGL(api, "glDeleteProgram", gl.DeleteProgram);
    loadGL(api, "glDeleteShader", gl.DeleteShader);
    loadGL(api, "glDeleteTextures", gl.DeleteTextures);
    loadGL(api, "glDeleteVertexArrays", gl.DeleteVertexArrays);
    loadGL(api, "glDrawArrays", gl.DrawArrays);
    loadGL(api, "glDrawElements", gl.DrawElements);
    loadGL(api, "glDrawBuffer", gl.DrawBuffer);
    loadGL(api, "glEnableVertexAttribArray", gl.EnableVertexAttribArray);
    loadGL(api, "glFinish", gl.Finish);
    loadGL(api, "glFramebufferTexture2D", gl.FramebufferTexture2D);
    loadGL(api, "glGenBuffers", gl.GenBuffers);
    loadGL(api, "glGenFramebuffers", gl.GenFramebuffers);
    loadGL(api, "glGenTextures", gl.GenTextures);
    loadGL(api, "glGenVertexArrays", gl.GenVertexArrays);
    loadGL(api, "glGetError", gl.GetError);
    loadGL(api, "glGetProgramInfoLog", gl.GetProgramInfoLog);
    loadGL(api, "glGetProgramiv", gl.GetProgramiv);
    loadGL(api, "glGetShaderInfoLog", gl.GetShaderInfoLog);
    loadGL(api, "glGetShaderiv", gl.GetShaderiv);
    loadGL(api, "glGetUniformLocation", gl.GetUniformLocation);
    loadGL(api, "glLinkProgram", gl.LinkProgram);
    loadGL(api, "glReadBuffer", gl.ReadBuffer);
    loadGL(api, "glReadPixels", gl.ReadPixels);
    loadGL(api, "glShaderSource", gl.ShaderSource);
    loadGL(api, "glTexImage2D", gl.TexImage2D);
    loadGL(api, "glTexParameteri", gl.TexParameteri);
    loadGL(api, "glUniform1i", gl.Uniform1i);
    loadGL(api, "glUniform4f", gl.Uniform4f);
    loadGL(api, "glUseProgram", gl.UseProgram);
    loadGL(api, "glVertexAttribPointer", gl.VertexAttribPointer);
    loadGL(api, "glViewport", gl.Viewport);

    return api;
}

void checkGLError(const GLApi& gl, std::string_view where) {
    const GLenum error = gl.GetError();
    if (error != GL_NO_ERROR) {
        std::ostringstream stream;
        stream << where << " produced GL error 0x" << std::hex << error;
        fail(stream.str());
    }
}

GLuint compileShader(const GLApi& gl, GLenum stage, const std::string& source, const char* label) {
    const GLuint shader = gl.CreateShader(stage);
    const char* sourcePtr = source.c_str();
    gl.ShaderSource(shader, 1, &sourcePtr, nullptr);
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

GLuint buildProgram(const GLApi& gl,
                    const std::string& vertexSource,
                    const std::string& fragmentSource,
                    const char* label) {
    const GLuint vs = compileShader(gl, GL_VERTEX_SHADER, vertexSource, "vertex shader");
    const GLuint fs = compileShader(gl, GL_FRAGMENT_SHADER, fragmentSource, "fragment shader");
    const GLuint program = gl.CreateProgram();
    gl.AttachShader(program, vs);
    gl.AttachShader(program, fs);
    gl.LinkProgram(program);
    gl.DeleteShader(vs);
    gl.DeleteShader(fs);

    GLint ok = GL_FALSE;
    gl.GetProgramiv(program, GL_LINK_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[4096] = {};
        GLsizei length = 0;
        gl.GetProgramInfoLog(program, sizeof(log), &length, log);
        fail(std::string(label) + " link failed: " + log);
    }
    return program;
}

std::string makeSampleFragmentShader(int shaderIters) {
    std::ostringstream stream;
    stream
        << "#version 330 core\n"
        << "uniform sampler2D uSource;\n"
        << "out vec4 fragColor;\n"
        << "void main() {\n"
        << "    vec4 s = texture(uSource, vec2(0.5, 0.5));\n"
        << "    for (int i = 0; i < " << shaderIters << "; ++i) {\n"
        << "        s = vec4(s.g, s.b, s.r, 1.0) * 0.998 + vec4(0.001, 0.0, 0.0, 0.0);\n"
        << "    }\n"
        << "    fragColor = vec4(s.r, s.g, s.b, 1.0);\n"
        << "}\n";
    return stream.str();
}

class BenchmarkRun {
public:
    BenchmarkRun(RuntimeApi& api, AppGLContext* context, const Options& options)
        : api_(api),
          context_(context),
          options_(options),
          profileEnabled_(std::getenv("APPGL_BARB_PROFILE") != nullptr) {
        const auto setupStart = Clock::now();
        setup();
        if (profileEnabled_) {
            const auto setupEnd = Clock::now();
            std::fprintf(stderr,
                "[APPGL_BARB_PROFILE] setup total_us=%.3f\n",
                elapsedUs(setupStart, setupEnd));
        }
    }

    ~BenchmarkRun() {
        cleanup();
    }

    RunResult run(int frames, bool measured) {
        RunResult result;
        result.frames = frames;
        result.chainDraws = options_.chainDraws;
        result.drawsPerFrame = drawsPerFrame();
        result.totalDraws = frames * result.drawsPerFrame;
        result.textureUploads = 0;

        auto& gl = api_.gl;
        const auto preFinishStart = Clock::now();
        gl.Finish();
        const auto preFinishEnd = Clock::now();
        if (profileEnabled_) {
            std::fprintf(stderr,
                "[APPGL_BARB_PROFILE] run=%s outside=pre_run_finish total_us=%.3f\n",
                measured ? "measured" : "warmup",
                elapsedUs(preFinishStart, preFinishEnd));
        }

        CoreProfileStats totalProfile;
        CoreProfileStats firstFrameProfile;
        CoreProfileStats remainingProfile;
        const auto coreStart = Clock::now();
        for (int frame = 0; frame < frames; ++frame) {
            CoreProfileStats* frameProfile =
                profileEnabled_ ? (frame == 0 ? &firstFrameProfile : &remainingProfile) : nullptr;
            if (profileEnabled_) {
                activeTotalProfile_ = &totalProfile;
                activeFrameProfile_ = frameProfile;
            }
            const auto frameStart = Clock::now();
            runFrame(frame, result.textureUploads);
            const auto frameEnd = Clock::now();
            if (profileEnabled_) {
                const double frameUs = elapsedUs(frameStart, frameEnd);
                totalProfile.wallUs += frameUs;
                ++totalProfile.frames;
                if (frameProfile != nullptr) {
                    frameProfile->wallUs += frameUs;
                    ++frameProfile->frames;
                }
                activeTotalProfile_ = nullptr;
                activeFrameProfile_ = nullptr;
            }
        }
        const auto coreEnd = Clock::now();

        result.coreMs = std::chrono::duration<double, std::milli>(coreEnd - coreStart).count();
        result.perDrawUs = result.totalDraws > 0
            ? (result.coreMs * 1000.0) / static_cast<double>(result.totalDraws)
            : 0.0;
        if (profileEnabled_) {
            const char* label = measured ? "measured" : "warmup";
            dumpCoreProfile(label, "all_frames", totalProfile);
            dumpCoreProfile(label, "first_frame", firstFrameProfile);
            dumpCoreProfile(label, "remaining_frames", remainingProfile);
        }

        const auto readbackStart = Clock::now();
        if (isGeneralMode()) {
            gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
            gl.ReadBuffer(GL_BACK);
        } else {
            gl.BindFramebuffer(GL_FRAMEBUFFER, framebuffers_[currentTexture_]);
            gl.ReadBuffer(GL_COLOR_ATTACHMENT0);
        }
        const auto readbackBindEnd = Clock::now();
        gl.ReadPixels(options_.size / 2, options_.size / 2, 1, 1,
                      GL_RGBA, GL_UNSIGNED_BYTE, result.readbackPixel.data());
        const auto readPixelsEnd = Clock::now();
        const auto readbackEnd = Clock::now();
        checkGLError(gl, measured ? "measured isolated readback" : "warmup isolated readback");
        const auto readbackCheckEnd = Clock::now();
        result.isolatedReadbackMs =
            std::chrono::duration<double, std::milli>(readbackEnd - readbackStart).count();
        if (profileEnabled_) {
            std::fprintf(stderr,
                "[APPGL_BARB_PROFILE] run=%s outside=readback_bind total_us=%.3f\n",
                measured ? "measured" : "warmup",
                elapsedUs(readbackStart, readbackBindEnd));
            std::fprintf(stderr,
                "[APPGL_BARB_PROFILE] run=%s outside=read_pixels total_us=%.3f\n",
                measured ? "measured" : "warmup",
                elapsedUs(readbackBindEnd, readPixelsEnd));
            std::fprintf(stderr,
                "[APPGL_BARB_PROFILE] run=%s outside=readback_check_error total_us=%.3f\n",
                measured ? "measured" : "warmup",
                elapsedUs(readbackEnd, readbackCheckEnd));
        }

        const auto finishStart = Clock::now();
        gl.Finish();
        const auto finishEnd = Clock::now();
        result.finishMs =
            std::chrono::duration<double, std::milli>(finishEnd - finishStart).count();
        if (profileEnabled_) {
            std::fprintf(stderr,
                "[APPGL_BARB_PROFILE] run=%s outside=final_finish total_us=%.3f\n",
                measured ? "measured" : "warmup",
                elapsedUs(finishStart, finishEnd));
        }

        if (result.readbackPixel[3] < 240) {
            fail("readback alpha check failed");
        }
        checkGLError(gl, measured ? "measured finish" : "warmup finish");
        return result;
    }

private:
    bool isGeneralMode() const {
        return options_.mode == "general";
    }

    int drawsPerFrame() const {
        if (isGeneralMode()) {
            return options_.chainDraws;
        }
        return options_.chainDraws + 2; // seed + chain + default present draw
    }

    template <typename Fn>
    void profileCall(ProfileBucket bucket, Fn&& fn) {
        if (!profileEnabled_) {
            fn();
            return;
        }
        const auto start = Clock::now();
        fn();
        const auto end = Clock::now();
        const double us = elapsedUs(start, end);
        if (activeTotalProfile_ != nullptr) {
            activeTotalProfile_->add(bucket, us);
        }
        if (activeFrameProfile_ != nullptr) {
            activeFrameProfile_->add(bucket, us);
        }
    }

    void setup() {
        auto& gl = api_.gl;
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

        seedProgram_ = buildProgram(gl, kFullscreenVS, kSeedFS, "seed program");
        sampleProgram_ = buildProgram(gl, kFullscreenVS, makeSampleFragmentShader(options_.shaderIters),
                                      "sample program");
        seedColorLocation_ = gl.GetUniformLocation(seedProgram_, "uColor");
        sampleSourceLocation_ = gl.GetUniformLocation(sampleProgram_, "uSource");
        if (seedColorLocation_ < 0 || sampleSourceLocation_ < 0) {
            fail("required uniform was optimized out");
        }

        const GLfloat vertices[] = {
            -1.0f, -1.0f,
             3.0f, -1.0f,
            -1.0f,  3.0f,
        };
        gl.GenVertexArrays(1, &vao_);
        gl.BindVertexArray(vao_);
        gl.GenBuffers(1, &vbo_);
        gl.BindBuffer(GL_ARRAY_BUFFER, vbo_);
        gl.BufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
        gl.EnableVertexAttribArray(0);
        gl.VertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(GLfloat), nullptr);
        const GLushort indices[] = {0, 1, 2};
        gl.GenBuffers(1, &ebo_);
        gl.BindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo_);
        gl.BufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);

        gl.GenTextures(2, textures_.data());
        for (GLuint texture : textures_) {
            gl.BindTexture(GL_TEXTURE_2D, texture);
            gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            gl.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, options_.size, options_.size, 0,
                          GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        }

        gl.GenFramebuffers(2, framebuffers_.data());
        for (int index = 0; index < 2; ++index) {
            gl.BindFramebuffer(GL_FRAMEBUFFER, framebuffers_[index]);
            gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                    GL_TEXTURE_2D, textures_[index], 0);
            gl.DrawBuffer(GL_COLOR_ATTACHMENT0);
            gl.ReadBuffer(GL_COLOR_ATTACHMENT0);
            const GLenum status = gl.CheckFramebufferStatus(GL_FRAMEBUFFER);
            if (status != GL_FRAMEBUFFER_COMPLETE) {
                std::ostringstream stream;
                stream << "ping-pong framebuffer " << index
                       << " incomplete: 0x" << std::hex << status;
                fail(stream.str());
            }
        }

        gl.GenTextures(1, &depthUploadTexture_);
        gl.BindTexture(GL_TEXTURE_2D, depthUploadTexture_);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        depthPixels_.resize(16 * 16);
        checkGLError(gl, "setup");
    }

    void runFrame(int frame, int& textureUploads) {
        if (options_.mode == "general") {
            runGeneralFrame(frame, textureUploads);
        } else if (options_.mode == "pingpong") {
            runPingPongFrame(frame, textureUploads);
        } else {
            runProducerFrame(frame, textureUploads);
        }
    }

    void maybeUploadDepth(int frame, int iteration, int& textureUploads) {
        if (options_.uploadEvery <= 0 || ((iteration + 1) % options_.uploadEvery) != 0) {
            return;
        }
        auto& gl = api_.gl;
        for (std::size_t pixel = 0; pixel < depthPixels_.size(); ++pixel) {
            depthPixels_[pixel] = static_cast<std::uint16_t>(
                0x1000u + ((frame * 131u + iteration * 97u + pixel * 13u) & 0x7fffu));
        }
        profileCall(ProfileBucket::BindTexture, [&] {
            gl.BindTexture(GL_TEXTURE_2D, depthUploadTexture_);
        });
        profileCall(ProfileBucket::TexImage2D, [&] {
            gl.TexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT16, 16, 16, 0,
                          GL_DEPTH_COMPONENT, GL_UNSIGNED_SHORT, depthPixels_.data());
        });
        ++textureUploads;
    }

    void runProducerFrame(int frame, int& textureUploads) {
        auto& gl = api_.gl;
        profileCall(ProfileBucket::BindFramebuffer, [&] {
            gl.BindFramebuffer(GL_FRAMEBUFFER, framebuffers_[0]);
        });
        profileCall(ProfileBucket::Viewport, [&] {
            gl.Viewport(0, 0, options_.size, options_.size);
        });
        profileCall(ProfileBucket::UseProgram, [&] {
            gl.UseProgram(seedProgram_);
        });
        profileCall(ProfileBucket::BindVertexArray, [&] {
            gl.BindVertexArray(vao_);
        });

        for (int iteration = 0; iteration <= options_.chainDraws; ++iteration) {
            const float r = static_cast<float>((frame * 17 + iteration * 3) % 251) / 255.0f;
            const float g = static_cast<float>((frame * 31 + iteration * 5) % 251) / 255.0f;
            const float b = static_cast<float>((frame * 47 + iteration * 7) % 251) / 255.0f;
            profileCall(ProfileBucket::Uniform, [&] {
                gl.Uniform4f(seedColorLocation_, r, g, b, 1.0f);
            });
            profileCall(ProfileBucket::DrawArrays, [&] {
                gl.DrawArrays(GL_TRIANGLES, 0, 3);
            });
            maybeUploadDepth(frame, iteration, textureUploads);
        }

        currentTexture_ = 0;
        drawPresentSample();
    }

    void runGeneralFrame(int frame, int& textureUploads) {
        auto& gl = api_.gl;
        profileCall(ProfileBucket::BindFramebuffer, [&] {
            gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
        });
        profileCall(ProfileBucket::Viewport, [&] {
            gl.Viewport(0, 0, options_.size, options_.size);
        });
        profileCall(ProfileBucket::UseProgram, [&] {
            gl.UseProgram(seedProgram_);
        });
        profileCall(ProfileBucket::BindVertexArray, [&] {
            gl.BindVertexArray(vao_);
        });

        for (int iteration = 0; iteration < options_.chainDraws; ++iteration) {
            const float r = static_cast<float>((frame * 17 + iteration * 3) % 251) / 255.0f;
            const float g = static_cast<float>((frame * 31 + iteration * 5) % 251) / 255.0f;
            const float b = static_cast<float>((frame * 47 + iteration * 7) % 251) / 255.0f;
            profileCall(ProfileBucket::Uniform, [&] {
                gl.Uniform4f(seedColorLocation_, r, g, b, 1.0f);
            });
            profileCall(ProfileBucket::DrawElements, [&] {
                gl.DrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_SHORT, nullptr);
            });
            maybeUploadDepth(frame, iteration, textureUploads);
        }

        profileCall(ProfileBucket::Finish, [&] {
            gl.Finish();
        });
    }

    void runPingPongFrame(int frame, int& textureUploads) {
        auto& gl = api_.gl;
        profileCall(ProfileBucket::BindFramebuffer, [&] {
            gl.BindFramebuffer(GL_FRAMEBUFFER, framebuffers_[0]);
        });
        profileCall(ProfileBucket::Viewport, [&] {
            gl.Viewport(0, 0, options_.size, options_.size);
        });
        profileCall(ProfileBucket::UseProgram, [&] {
            gl.UseProgram(seedProgram_);
        });
        profileCall(ProfileBucket::Uniform, [&] {
            gl.Uniform4f(seedColorLocation_,
                         1.0f,
                         static_cast<float>((frame * 17) % 7) * 0.01f,
                         static_cast<float>((frame * 31) % 5) * 0.01f,
                         1.0f);
        });
        profileCall(ProfileBucket::BindVertexArray, [&] {
            gl.BindVertexArray(vao_);
        });
        profileCall(ProfileBucket::DrawArrays, [&] {
            gl.DrawArrays(GL_TRIANGLES, 0, 3);
        });

        currentTexture_ = 0;
        for (int iteration = 0; iteration < options_.chainDraws; ++iteration) {
            const int destination = 1 - currentTexture_;
            profileCall(ProfileBucket::BindFramebuffer, [&] {
                gl.BindFramebuffer(GL_FRAMEBUFFER, framebuffers_[destination]);
            });
            profileCall(ProfileBucket::Viewport, [&] {
                gl.Viewport(0, 0, options_.size, options_.size);
            });
            profileCall(ProfileBucket::UseProgram, [&] {
                gl.UseProgram(sampleProgram_);
            });
            profileCall(ProfileBucket::ActiveTexture, [&] {
                gl.ActiveTexture(GL_TEXTURE0);
            });
            profileCall(ProfileBucket::BindTexture, [&] {
                gl.BindTexture(GL_TEXTURE_2D, textures_[currentTexture_]);
            });
            profileCall(ProfileBucket::Uniform, [&] {
                gl.Uniform1i(sampleSourceLocation_, 0);
            });
            profileCall(ProfileBucket::BindVertexArray, [&] {
                gl.BindVertexArray(vao_);
            });
            profileCall(ProfileBucket::DrawArrays, [&] {
                gl.DrawArrays(GL_TRIANGLES, 0, 3);
            });
            currentTexture_ = destination;
            maybeUploadDepth(frame, iteration, textureUploads);
        }

        drawPresentSample();
    }

    void drawPresentSample() {
        auto& gl = api_.gl;
        profileCall(ProfileBucket::BindFramebuffer, [&] {
            gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
        });
        profileCall(ProfileBucket::Viewport, [&] {
            gl.Viewport(0, 0, options_.size, options_.size);
        });
        profileCall(ProfileBucket::UseProgram, [&] {
            gl.UseProgram(sampleProgram_);
        });
        profileCall(ProfileBucket::ActiveTexture, [&] {
            gl.ActiveTexture(GL_TEXTURE0);
        });
        profileCall(ProfileBucket::BindTexture, [&] {
            gl.BindTexture(GL_TEXTURE_2D, textures_[currentTexture_]);
        });
        profileCall(ProfileBucket::Uniform, [&] {
            gl.Uniform1i(sampleSourceLocation_, 0);
        });
        profileCall(ProfileBucket::BindVertexArray, [&] {
            gl.BindVertexArray(vao_);
        });
        profileCall(ProfileBucket::DrawArrays, [&] {
            gl.DrawArrays(GL_TRIANGLES, 0, 3);
        });
        profileCall(ProfileBucket::SwapBuffers, [&] {
            api_.swapBuffers(context_);
        });
    }

    void cleanup() {
        if (cleanedUp_) {
            return;
        }
        cleanedUp_ = true;
        auto& gl = api_.gl;
        if (depthUploadTexture_ != 0) {
            gl.DeleteTextures(1, &depthUploadTexture_);
        }
        if (framebuffers_[0] != 0 || framebuffers_[1] != 0) {
            gl.DeleteFramebuffers(2, framebuffers_.data());
        }
        if (textures_[0] != 0 || textures_[1] != 0) {
            gl.DeleteTextures(2, textures_.data());
        }
        if (vbo_ != 0) {
            gl.DeleteBuffers(1, &vbo_);
        }
        if (ebo_ != 0) {
            gl.DeleteBuffers(1, &ebo_);
        }
        if (vao_ != 0) {
            gl.DeleteVertexArrays(1, &vao_);
        }
        if (seedProgram_ != 0) {
            gl.DeleteProgram(seedProgram_);
        }
        if (sampleProgram_ != 0) {
            gl.DeleteProgram(sampleProgram_);
        }
        gl.Finish();
    }

    RuntimeApi& api_;
    AppGLContext* context_ = nullptr;
    Options options_;
    GLuint seedProgram_ = 0;
    GLuint sampleProgram_ = 0;
    GLint seedColorLocation_ = -1;
    GLint sampleSourceLocation_ = -1;
    GLuint vao_ = 0;
    GLuint vbo_ = 0;
    GLuint ebo_ = 0;
    std::array<GLuint, 2> textures_{0, 0};
    GLuint depthUploadTexture_ = 0;
    std::array<GLuint, 2> framebuffers_{0, 0};
    std::vector<std::uint16_t> depthPixels_;
    int currentTexture_ = 0;
    bool cleanedUp_ = false;
    bool profileEnabled_ = false;
    CoreProfileStats* activeTotalProfile_ = nullptr;
    CoreProfileStats* activeFrameProfile_ = nullptr;
};

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

void writeJSON(const Options& options, const RunResult& warmup, const RunResult& measured) {
    std::cout << std::fixed << std::setprecision(6);
    std::cout
        << "{"
        << "\"benchmark\":\"dcr3-bar-b-fbo-real-app\","
        << "\"label\":\"" << jsonEscape(options.label) << "\","
        << "\"library\":\"" << jsonEscape(options.library) << "\","
        << "\"mode\":\"" << jsonEscape(options.mode) << "\","
        << "\"commandBufferBound\":48,"
        << "\"commandBufferReserve\":4,"
        << "\"readbackIsolated\":true,"
        << "\"presentOncePerFrame\":" << (options.mode == "general" ? "false" : "true") << ","
        << "\"size\":" << options.size << ","
        << "\"frames\":" << options.frames << ","
        << "\"warmupFrames\":" << options.warmupFrames << ","
        << "\"chainDraws\":" << options.chainDraws << ","
        << "\"drawsPerFrame\":" << measured.drawsPerFrame << ","
        << "\"totalDraws\":" << measured.totalDraws << ","
        << "\"uploadEvery\":" << options.uploadEvery << ","
        << "\"textureUploads\":" << measured.textureUploads << ","
        << "\"shaderIters\":" << options.shaderIters << ","
        << "\"warmup\":{"
        << "\"frames\":" << warmup.frames << ","
        << "\"coreMs\":" << warmup.coreMs << ","
        << "\"perDrawUs\":" << warmup.perDrawUs << ","
        << "\"isolatedReadbackMs\":" << warmup.isolatedReadbackMs << ","
        << "\"finishMs\":" << warmup.finishMs
        << "},"
        << "\"measured\":{"
        << "\"coreMs\":" << measured.coreMs << ","
        << "\"perDrawUs\":" << measured.perDrawUs << ","
        << "\"isolatedReadbackMs\":" << measured.isolatedReadbackMs << ","
        << "\"finishMs\":" << measured.finishMs << ","
        << "\"readbackRGBA\":["
        << static_cast<int>(measured.readbackPixel[0]) << ","
        << static_cast<int>(measured.readbackPixel[1]) << ","
        << static_cast<int>(measured.readbackPixel[2]) << ","
        << static_cast<int>(measured.readbackPixel[3]) << "]"
        << "}"
        << "}\n";
}

} // namespace

int main(int argc, char** argv) {
    try {
        const Options options = parseOptions(argc, argv);
        RuntimeApi api = loadRuntime(options);

        AppGLContext* context = api.createOffscreen(options.size, options.size);
        if (context == nullptr) {
            fail("appglCreateOffscreenContext returned null");
        }
        api.makeCurrent(context);

        RunResult warmup;
        RunResult measured;
        {
            BenchmarkRun run(api, context, options);
            warmup = run.run(options.warmupFrames, false);
            measured = run.run(options.frames, true);
        }

        api.makeCurrent(nullptr);
        api.destroyContext(context);
        dlclose(api.handle);

        writeJSON(options, warmup, measured);
        return 0;
    } catch (const std::exception& ex) {
        std::fprintf(stderr, "appgl_bar_b_benchmark: %s\n", ex.what());
        return 1;
    }
}
