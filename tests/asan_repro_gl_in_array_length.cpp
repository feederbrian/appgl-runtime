// ASAN reproducer for session-12 gl_in_array_length SIGSEGV.
//
// Bypasses glcts's test-enumeration overhead (minutes under ASAN
// to even reach the selected test case). Directly dlopens libAppGL
// (built with APPGL_ENABLE_ASAN=ON), creates an offscreen context,
// compiles a minimal VS + GS + FS program shaped after CTS
// `KHR-GL46.geometry_shader.input.gl_in_array_length`, and fires a
// draw that invokes `emulateGeometryDraw` and the SpirvModule
// parse/use path. ASAN should report the heap-corruption site at
// the first draw call.
//
// Build:
//   cd build-asan && ninja asan_repro
//
// Run:
//   ASAN_OPTIONS="detect_leaks=0:abort_on_error=0:halt_on_error=0" \
//     ./asan_repro
//
// The binary prints the per-call GL error codes to stdout so you
// can trace which call triggers the crash.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <string>

#include "AppGL/AppGL.h"
#include "AppGL/glcorearb.h"

namespace {

// Public AppGL API pointers (dlsym from libAppGL.dylib).
using CreateOffscreenFn = AppGLContext* (*)(int, int);
using DestroyFn = void (*)(AppGLContext*);
using MakeCurrentFn = void (*)(AppGLContext*);
using GetProcAddressFn = AppGLProc (*)(const char*);

CreateOffscreenFn gCreateOffscreen = nullptr;
DestroyFn gDestroy = nullptr;
MakeCurrentFn gMakeCurrent = nullptr;
GetProcAddressFn gGetProcAddress = nullptr;

// Shadow GL entry points we need.
PFNGLCREATESHADERPROC glCreateShader_ = nullptr;
PFNGLSHADERSOURCEPROC glShaderSource_ = nullptr;
PFNGLCOMPILESHADERPROC glCompileShader_ = nullptr;
PFNGLGETSHADERIVPROC glGetShaderiv_ = nullptr;
PFNGLGETSHADERINFOLOGPROC glGetShaderInfoLog_ = nullptr;
PFNGLCREATEPROGRAMPROC glCreateProgram_ = nullptr;
PFNGLATTACHSHADERPROC glAttachShader_ = nullptr;
PFNGLLINKPROGRAMPROC glLinkProgram_ = nullptr;
PFNGLGETPROGRAMIVPROC glGetProgramiv_ = nullptr;
PFNGLGETPROGRAMINFOLOGPROC glGetProgramInfoLog_ = nullptr;
PFNGLUSEPROGRAMPROC glUseProgram_ = nullptr;
PFNGLGENVERTEXARRAYSPROC glGenVertexArrays_ = nullptr;
PFNGLBINDVERTEXARRAYPROC glBindVertexArray_ = nullptr;
PFNGLDRAWARRAYSPROC glDrawArrays_ = nullptr;
PFNGLGETERRORPROC glGetError_ = nullptr;

template <typename T>
void load(const char* name, T& out) {
    out = reinterpret_cast<T>(gGetProcAddress(name));
    if (out == nullptr) {
        std::fprintf(stderr, "failed to load %s\n", name);
        std::exit(1);
    }
}

void checkGL(const char* tag) {
    GLenum err = glGetError_();
    std::printf("  [%s] gl error = 0x%04x\n", tag, err);
    std::fflush(stdout);
}

GLuint compile(GLenum stage, const char* src, const char* tag) {
    std::printf("compile %s ...\n", tag);
    std::fflush(stdout);
    GLuint s = glCreateShader_(stage);
    glShaderSource_(s, 1, &src, nullptr);
    glCompileShader_(s);
    GLint ok = 0;
    glGetShaderiv_(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048] = {0};
        GLsizei len = 0;
        glGetShaderInfoLog_(s, sizeof(log), &len, log);
        std::fprintf(stderr, "%s compile failed: %s\n", tag, log);
        std::exit(2);
    }
    checkGL(tag);
    return s;
}

}  // namespace

int main(int argc, char** argv) {
    // Respect DYLD_LIBRARY_PATH if the user set one; fall back to the
    // local soname lookup.
    void* handle = dlopen("libAppGL.dylib", RTLD_NOW);
    if (handle == nullptr) {
        std::fprintf(stderr, "dlopen libAppGL.dylib failed: %s\n", dlerror());
        return 1;
    }

    gCreateOffscreen = reinterpret_cast<CreateOffscreenFn>(
        dlsym(handle, "appglCreateOffscreenContext"));
    gDestroy = reinterpret_cast<DestroyFn>(
        dlsym(handle, "appglDestroyContext"));
    gMakeCurrent = reinterpret_cast<MakeCurrentFn>(
        dlsym(handle, "appglMakeCurrent"));
    gGetProcAddress = reinterpret_cast<GetProcAddressFn>(
        dlsym(handle, "appglGetProcAddress"));
    if (!gCreateOffscreen || !gDestroy || !gMakeCurrent || !gGetProcAddress) {
        std::fprintf(stderr, "missing AppGL symbols\n");
        return 1;
    }

    AppGLContext* ctx = gCreateOffscreen(64, 64);
    if (ctx == nullptr) {
        std::fprintf(stderr, "appglCreateOffscreenContext failed\n");
        return 1;
    }
    gMakeCurrent(ctx);
    std::puts("context created + made current");
    std::fflush(stdout);

    load("glCreateShader", glCreateShader_);
    load("glShaderSource", glShaderSource_);
    load("glCompileShader", glCompileShader_);
    load("glGetShaderiv", glGetShaderiv_);
    load("glGetShaderInfoLog", glGetShaderInfoLog_);
    load("glCreateProgram", glCreateProgram_);
    load("glAttachShader", glAttachShader_);
    load("glLinkProgram", glLinkProgram_);
    load("glGetProgramiv", glGetProgramiv_);
    load("glGetProgramInfoLog", glGetProgramInfoLog_);
    load("glUseProgram", glUseProgram_);
    load("glGenVertexArrays", glGenVertexArrays_);
    load("glBindVertexArray", glBindVertexArray_);
    load("glDrawArrays", glDrawArrays_);
    load("glGetError", glGetError_);
    std::puts("entry points loaded");
    std::fflush(stdout);

    const char* vs_src =
        "#version 400 core\n"
        "void main() {\n"
        "  gl_Position = vec4(gl_VertexID, 0.0, 0.0, 1.0);\n"
        "}\n";

    const char* fs_src =
        "#version 400 core\n"
        "out vec4 fs_out;\n"
        "void main() { fs_out = vec4(1.0); }\n";

    // Iterate all 5 input topology × 3 output topology combos the
    // CTS test exercises. The heap corruption only appears for
    // specific combos.
    struct InputTopo { const char* layout; GLenum drawMode; GLsizei count; };
    const InputTopo inputs[] = {
        {"points",                GL_POINTS,                   1},
        {"lines",                 GL_LINES,                    2},
        {"lines_adjacency",       GL_LINES_ADJACENCY,          4},
        {"triangles",             GL_TRIANGLES,                3},
        {"triangles_adjacency",   GL_TRIANGLES_ADJACENCY,      6},
    };
    const char* outputs[] = {
        "points, max_vertices=1",
        "line_strip, max_vertices=2",
        "triangle_strip, max_vertices=3",
    };
    const int outputVertices[] = {1, 2, 3};

    GLuint vs = compile(GL_VERTEX_SHADER, vs_src, "VS");
    GLuint fs = compile(GL_FRAGMENT_SHADER, fs_src, "FS");

    GLuint vao = 0;
    glGenVertexArrays_(1, &vao);
    glBindVertexArray_(vao);
    checkGL("bindVAO");

    for (const auto& in : inputs) {
        for (std::size_t outIdx = 0; outIdx < 3; ++outIdx) {
            std::printf("\n=== input=%s output=%s ===\n", in.layout, outputs[outIdx]);
            std::fflush(stdout);

            std::string gs_src =
                "#version 400 core\n"
                "layout(" + std::string(in.layout) + ") in;\n"
                "layout(" + std::string(outputs[outIdx]) + ") out;\n"
                "flat out int in_array_size;\n"
                "void main() {\n"
                "  for (int n = 0; n < " + std::to_string(outputVertices[outIdx]) + "; ++n) {\n"
                "    in_array_size = gl_in.length();\n"
                "    EmitVertex();\n"
                "  }\n"
                "  EndPrimitive();\n"
                "}\n";

            const char* gs_ptr = gs_src.c_str();
            GLuint gs = compile(GL_GEOMETRY_SHADER, gs_ptr, "GS");

            GLuint prog = glCreateProgram_();
            glAttachShader_(prog, vs);
            glAttachShader_(prog, gs);
            glAttachShader_(prog, fs);
            glLinkProgram_(prog);
            GLint linkOk = 0;
            glGetProgramiv_(prog, GL_LINK_STATUS, &linkOk);
            if (!linkOk) {
                char log[2048] = {0};
                GLsizei len = 0;
                glGetProgramInfoLog_(prog, sizeof(log), &len, log);
                std::fprintf(stderr, "link failed: %s\n", log);
                continue;
            }
            checkGL("link");
            glUseProgram_(prog);
            checkGL("useProgram");

            std::printf("→ drawArrays(mode=0x%X, count=%d)\n", in.drawMode, in.count);
            std::fflush(stdout);
            glDrawArrays_(in.drawMode, 0, in.count);
            checkGL("drawArrays");
        }
    }

    gMakeCurrent(nullptr);
    gDestroy(ctx);
    std::puts("clean shutdown");
    return 0;
}
