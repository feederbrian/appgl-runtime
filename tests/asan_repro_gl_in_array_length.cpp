// ASAN reproducer for GS-emulation heap corruption.
// See iter 158 notes for details.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <string>

#include "AppGL/AppGL.h"
#include "AppGL/glcorearb.h"

namespace {

using CreateOffscreenFn = AppGLContext* (*)(int, int);
using DestroyFn = void (*)(AppGLContext*);
using MakeCurrentFn = void (*)(AppGLContext*);
using GetProcAddressFn = AppGLProc (*)(const char*);

CreateOffscreenFn gCreateOffscreen = nullptr;
DestroyFn gDestroy = nullptr;
MakeCurrentFn gMakeCurrent = nullptr;
GetProcAddressFn gGetProcAddress = nullptr;

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
PFNGLDELETEPROGRAMPROC glDeleteProgram_ = nullptr;
PFNGLDELETESHADERPROC glDeleteShader_ = nullptr;
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

GLuint compileOrDie(GLenum stage, const char* src, const char* tag) {
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
    return s;
}

}  // namespace

int main(int argc, char** argv) {
    void* handle = dlopen("libAppGL.dylib", RTLD_NOW);
    if (handle == nullptr) {
        std::fprintf(stderr, "dlopen libAppGL.dylib failed: %s\n", dlerror());
        return 1;
    }

    gCreateOffscreen = reinterpret_cast<CreateOffscreenFn>(dlsym(handle, "appglCreateOffscreenContext"));
    gDestroy = reinterpret_cast<DestroyFn>(dlsym(handle, "appglDestroyContext"));
    gMakeCurrent = reinterpret_cast<MakeCurrentFn>(dlsym(handle, "appglMakeCurrent"));
    gGetProcAddress = reinterpret_cast<GetProcAddressFn>(dlsym(handle, "appglGetProcAddress"));

    AppGLContext* ctx = gCreateOffscreen(64, 64);
    gMakeCurrent(ctx);

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
    load("glDeleteProgram", glDeleteProgram_);
    load("glDeleteShader", glDeleteShader_);
    load("glGenVertexArrays", glGenVertexArrays_);
    load("glBindVertexArray", glBindVertexArray_);
    load("glDrawArrays", glDrawArrays_);
    load("glGetError", glGetError_);

    const char* vs_src =
        "#version 400 core\n"
        "void main() { gl_Position = vec4(gl_VertexID, 0.0, 0.0, 1.0); }\n";
    const char* fs_src =
        "#version 400 core\n"
        "out vec4 fs_out;\n"
        "void main() { fs_out = vec4(1.0); }\n";

    GLuint vs = compileOrDie(GL_VERTEX_SHADER, vs_src, "VS");
    GLuint fs = compileOrDie(GL_FRAGMENT_SHADER, fs_src, "FS");

    GLuint vao = 0;
    glGenVertexArrays_(1, &vao);
    glBindVertexArray_(vao);

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
    const int outVerts[] = {1, 2, 3};

    int iter = 0;
    // When START_AT is set, skip forward. Useful for isolating "does combo
    // N crash alone?" vs "does combo N crash only after combos 1..N-1?".
    const int startAt = []{
        if (const char* e = std::getenv("START_AT")) return std::atoi(e);
        return 0;
    }();
    for (const auto& in : inputs) {
        for (std::size_t outIdx = 0; outIdx < 3; ++outIdx) {
            ++iter;
            if (iter < startAt) continue;
            std::printf("\niter %d: input=%s output=%s\n", iter, in.layout, outputs[outIdx]);
            std::fflush(stdout);

            std::string gs_src =
                "#version 400 core\n"
                "layout(" + std::string(in.layout) + ") in;\n"
                "layout(" + std::string(outputs[outIdx]) + ") out;\n"
                "flat out int in_array_size;\n"
                "void main() {\n"
                "  for (int n = 0; n < " + std::to_string(outVerts[outIdx]) + "; ++n) {\n"
                "    in_array_size = gl_in.length();\n"
                "    EmitVertex();\n"
                "  }\n"
                "  EndPrimitive();\n"
                "}\n";

            std::puts("  A: compile GS"); std::fflush(stdout);
            const char* gs_ptr = gs_src.c_str();
            GLuint gs = compileOrDie(GL_GEOMETRY_SHADER, gs_ptr, "GS");
            std::puts("  B: createProgram"); std::fflush(stdout);
            GLuint prog = glCreateProgram_();
            std::puts("  C: attach"); std::fflush(stdout);
            glAttachShader_(prog, vs);
            glAttachShader_(prog, gs);
            glAttachShader_(prog, fs);
            std::puts("  D: link"); std::fflush(stdout);
            glLinkProgram_(prog);
            GLint linkOk = 0;
            glGetProgramiv_(prog, GL_LINK_STATUS, &linkOk);
            if (!linkOk) {
                std::fprintf(stderr, "link failed\n");
                return 3;
            }
            std::puts("  E: useProgram"); std::fflush(stdout);
            glUseProgram_(prog);

            std::printf("  → drawArrays(mode=0x%X, count=%d)\n", in.drawMode, in.count);
            std::fflush(stdout);
            glDrawArrays_(in.drawMode, 0, in.count);
            GLenum err = glGetError_();
            std::printf("  after drawArrays: err=0x%X\n", err);
            std::fflush(stdout);

            // Clean up program + gs shader after each iteration.
            if (std::getenv("NO_DELETE") == nullptr) {
                glDeleteProgram_(prog);
                glDeleteShader_(gs);
            }
        }
    }

    gMakeCurrent(nullptr);
    gDestroy(ctx);
    std::puts("clean shutdown");
    return 0;
}
