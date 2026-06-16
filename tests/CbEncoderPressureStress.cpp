// S25 W2 — CB resource/encoder-pressure synthetic stress + calibration harness.
//
// Reproduces the Research-Stats SIGABRT
// (IOGPUMetalCommandBufferStorageAllocResourceAtIndex -> abort) deterministically,
// WITHOUT WZ menu-nav. The fault site is the command buffer's RESOURCE list, so the
// harness grows per-CB pressure two ways, accumulated in ONE command buffer (no present):
//   (1) render-pass/encoder transitions: each iteration switches FBO <-> default FB;
//   (2) DISTINCT resources per draw: each iteration binds a FRESH texture (and, with
//       STRESS_DISTINCT_VBO=1, a fresh vertex buffer) so the CB's resident-resource
//       set grows by ~1-2 per iteration -- mimicking Research Stats rendering many
//       distinct pie_Draw3DButton 3D models/textures in one frame's command buffer.
//
// CALIBRATION (pre-fix): ramp STRESS_N until the process aborts (rc=134); the last
//   flushed progress line ~= the per-CB resource cap. Run @ APPGL_PARALLEL_ENCODE=1 for
//   the cap; @ APPGL_PARALLEL_ENCODE=0 for the serial-isolation A/B.
// GATE (post-fix): the CB-rotation (maybeFlushCurrentForPressure at the calibrated
//   threshold) must keep per-CB pressure under the cap -> assert COMPLETE at heavy N.
//
// Env:
//   STRESS_N=<n>             iterations (default 4096)
//   STRESS_FBO_SIZE=<n>      FBO/texture dim (default 64)
//   STRESS_DISTINCT_RES=0|1  fresh texture per draw (default 1)
//   STRESS_DISTINCT_VBO=0|1  fresh vertex buffer per draw (default 1)
//   APPGL_PARALLEL_ENCODE=0|1  serial vs parallel worker-batch path
//
// Standalone (no GauntletRunner dep); template: tests/asan_repro_gl_in_array_length.cpp

#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>

#include "AppGL/AppGL.h"
#include "AppGL/glcorearb.h"

namespace {

using CreateOffscreenFn = AppGLContext* (*)(int, int);
using DestroyFn = void (*)(AppGLContext*);
using MakeCurrentFn = void (*)(AppGLContext*);
using GetProcAddressFn = AppGLProc (*)(const char*);

GetProcAddressFn gGetProcAddress = nullptr;

template <typename T>
void load(const char* name, T& out) {
    out = reinterpret_cast<T>(gGetProcAddress(name));
    if (out == nullptr) {
        std::fprintf(stderr, "[stress] failed to load %s\n", name);
        std::exit(1);
    }
}

PFNGLCREATESHADERPROC glCreateShader_ = nullptr;
PFNGLSHADERSOURCEPROC glShaderSource_ = nullptr;
PFNGLCOMPILESHADERPROC glCompileShader_ = nullptr;
PFNGLGETSHADERIVPROC glGetShaderiv_ = nullptr;
PFNGLCREATEPROGRAMPROC glCreateProgram_ = nullptr;
PFNGLATTACHSHADERPROC glAttachShader_ = nullptr;
PFNGLLINKPROGRAMPROC glLinkProgram_ = nullptr;
PFNGLGETPROGRAMIVPROC glGetProgramiv_ = nullptr;
PFNGLUSEPROGRAMPROC glUseProgram_ = nullptr;
PFNGLGETUNIFORMLOCATIONPROC glGetUniformLocation_ = nullptr;
PFNGLUNIFORM1IPROC glUniform1i_ = nullptr;
PFNGLACTIVETEXTUREPROC glActiveTexture_ = nullptr;
PFNGLGENVERTEXARRAYSPROC glGenVertexArrays_ = nullptr;
PFNGLBINDVERTEXARRAYPROC glBindVertexArray_ = nullptr;
PFNGLGENBUFFERSPROC glGenBuffers_ = nullptr;
PFNGLBINDBUFFERPROC glBindBuffer_ = nullptr;
PFNGLBUFFERDATAPROC glBufferData_ = nullptr;
PFNGLVERTEXATTRIBPOINTERPROC glVertexAttribPointer_ = nullptr;
PFNGLENABLEVERTEXATTRIBARRAYPROC glEnableVertexAttribArray_ = nullptr;
PFNGLGENFRAMEBUFFERSPROC glGenFramebuffers_ = nullptr;
PFNGLBINDFRAMEBUFFERPROC glBindFramebuffer_ = nullptr;
PFNGLFRAMEBUFFERTEXTURE2DPROC glFramebufferTexture2D_ = nullptr;
PFNGLCHECKFRAMEBUFFERSTATUSPROC glCheckFramebufferStatus_ = nullptr;
PFNGLGENTEXTURESPROC glGenTextures_ = nullptr;
PFNGLBINDTEXTUREPROC glBindTexture_ = nullptr;
PFNGLTEXIMAGE2DPROC glTexImage2D_ = nullptr;
PFNGLTEXPARAMETERIPROC glTexParameteri_ = nullptr;
PFNGLVIEWPORTPROC glViewport_ = nullptr;
PFNGLCLEARPROC glClear_ = nullptr;
PFNGLCLEARCOLORPROC glClearColor_ = nullptr;
PFNGLDRAWARRAYSPROC glDrawArrays_ = nullptr;
PFNGLFINISHPROC glFinish_ = nullptr;
PFNGLGETERRORPROC glGetError_ = nullptr;

GLuint compileOrDie(GLenum stage, const char* src) {
    GLuint s = glCreateShader_(stage);
    glShaderSource_(s, 1, &src, nullptr);
    glCompileShader_(s);
    GLint ok = 0;
    glGetShaderiv_(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        std::fprintf(stderr, "[stress] shader compile failed\n");
        std::exit(2);
    }
    return s;
}

int envInt(const char* name, int dflt) {
    if (const char* e = std::getenv(name)) return std::atoi(e);
    return dflt;
}

}  // namespace

int main() {
    void* handle = dlopen("libAppGL.dylib", RTLD_NOW);
    if (handle == nullptr) {
        std::fprintf(stderr, "[stress] dlopen libAppGL.dylib failed: %s\n", dlerror());
        return 1;
    }
    auto createOffscreen = reinterpret_cast<CreateOffscreenFn>(dlsym(handle, "appglCreateOffscreenContext"));
    auto destroy = reinterpret_cast<DestroyFn>(dlsym(handle, "appglDestroyContext"));
    auto makeCurrent = reinterpret_cast<MakeCurrentFn>(dlsym(handle, "appglMakeCurrent"));
    gGetProcAddress = reinterpret_cast<GetProcAddressFn>(dlsym(handle, "appglGetProcAddress"));
    if (!createOffscreen || !destroy || !makeCurrent || !gGetProcAddress) {
        std::fprintf(stderr, "[stress] dlsym of AppGL entrypoints failed\n");
        return 1;
    }

    const int N = envInt("STRESS_N", 4096);
    const int FB = envInt("STRESS_FBO_SIZE", 64);
    const bool distinctRes = envInt("STRESS_DISTINCT_RES", 1) != 0;
    const bool distinctVbo = envInt("STRESS_DISTINCT_VBO", 1) != 0;
    const bool batchMode = envInt("STRESS_BATCH", 1) != 0;  // consecutive same-target draws -> worker-batch path
    const char* pe = std::getenv("APPGL_PARALLEL_ENCODE");
    std::fprintf(stderr, "[stress] START N=%d fbo=%d distinctRes=%d distinctVbo=%d batch=%d APPGL_PARALLEL_ENCODE=%s\n",
                 N, FB, distinctRes ? 1 : 0, distinctVbo ? 1 : 0, batchMode ? 1 : 0, pe ? pe : "(unset)");
    std::fflush(stderr);

    AppGLContext* ctx = createOffscreen(256, 256);
    makeCurrent(ctx);

    load("glCreateShader", glCreateShader_);
    load("glShaderSource", glShaderSource_);
    load("glCompileShader", glCompileShader_);
    load("glGetShaderiv", glGetShaderiv_);
    load("glCreateProgram", glCreateProgram_);
    load("glAttachShader", glAttachShader_);
    load("glLinkProgram", glLinkProgram_);
    load("glGetProgramiv", glGetProgramiv_);
    load("glUseProgram", glUseProgram_);
    load("glGetUniformLocation", glGetUniformLocation_);
    load("glUniform1i", glUniform1i_);
    load("glActiveTexture", glActiveTexture_);
    load("glGenVertexArrays", glGenVertexArrays_);
    load("glBindVertexArray", glBindVertexArray_);
    load("glGenBuffers", glGenBuffers_);
    load("glBindBuffer", glBindBuffer_);
    load("glBufferData", glBufferData_);
    load("glVertexAttribPointer", glVertexAttribPointer_);
    load("glEnableVertexAttribArray", glEnableVertexAttribArray_);
    load("glGenFramebuffers", glGenFramebuffers_);
    load("glBindFramebuffer", glBindFramebuffer_);
    load("glFramebufferTexture2D", glFramebufferTexture2D_);
    load("glCheckFramebufferStatus", glCheckFramebufferStatus_);
    load("glGenTextures", glGenTextures_);
    load("glBindTexture", glBindTexture_);
    load("glTexImage2D", glTexImage2D_);
    load("glTexParameteri", glTexParameteri_);
    load("glViewport", glViewport_);
    load("glClear", glClear_);
    load("glClearColor", glClearColor_);
    load("glDrawArrays", glDrawArrays_);
    load("glFinish", glFinish_);
    load("glGetError", glGetError_);

    // Triangle that samples a bound texture (so each draw REFERENCES its texture +
    // its vertex buffer -> those become resident resources in the command buffer).
    const char* vs =
        "#version 400 core\n"
        "layout(location=0) in vec2 pos;\n"
        "void main(){ gl_Position = vec4(pos, 0.0, 1.0); }\n";
    const char* fs =
        "#version 400 core\n"
        "uniform sampler2D s;\n"
        "out vec4 c;\n"
        "void main(){ c = texture(s, vec2(0.5)) + vec4(0.01); }\n";
    GLuint prog = glCreateProgram_();
    glAttachShader_(prog, compileOrDie(GL_VERTEX_SHADER, vs));
    glAttachShader_(prog, compileOrDie(GL_FRAGMENT_SHADER, fs));
    glLinkProgram_(prog);
    GLint linkOk = 0;
    glGetProgramiv_(prog, GL_LINK_STATUS, &linkOk);
    if (!linkOk) {
        std::fprintf(stderr, "[stress] program link failed\n");
        return 3;
    }
    glUseProgram_(prog);
    const GLint sLoc = glGetUniformLocation_(prog, "s");

    GLuint vao = 0;
    glGenVertexArrays_(1, &vao);
    glBindVertexArray_(vao);

    const float tri[6] = {-0.5f, -0.5f, 0.5f, -0.5f, 0.0f, 0.5f};
    // A shared vertex buffer (used when distinctVbo is off).
    GLuint sharedVbo = 0;
    glGenBuffers_(1, &sharedVbo);
    glBindBuffer_(GL_ARRAY_BUFFER, sharedVbo);
    glBufferData_(GL_ARRAY_BUFFER, sizeof(tri), tri, GL_STATIC_DRAW);
    glVertexAttribPointer_(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
    glEnableVertexAttribArray_(0);

    // A shared sampled texture (used when distinctRes is off).
    GLuint sharedTex = 0;
    glGenTextures_(1, &sharedTex);
    glBindTexture_(GL_TEXTURE_2D, sharedTex);
    const unsigned char px0[4] = {128, 128, 128, 255};
    glTexImage2D_(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, px0);
    glTexParameteri_(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri_(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

    // The render-target FBO (the per-button render target analogue).
    GLuint fboTex = 0;
    glGenTextures_(1, &fboTex);
    glBindTexture_(GL_TEXTURE_2D, fboTex);
    glTexImage2D_(GL_TEXTURE_2D, 0, GL_RGBA8, FB, FB, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri_(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri_(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    GLuint fbo = 0;
    glGenFramebuffers_(1, &fbo);
    glBindFramebuffer_(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D_(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fboTex, 0);
    if (glCheckFramebufferStatus_(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        std::fprintf(stderr, "[stress] FBO incomplete\n");
        return 4;
    }

    // One heavy "frame": N iterations accumulated in ONE command buffer (no present).
    // Each iteration optionally allocates a DISTINCT texture + vertex buffer (grows the
    // CB's resident-resource set) and forces FBO->default render-pass transitions. If
    // the accumulated per-CB resources exceed the IOGPU cap, the next resource alloc
    // aborts in IOGPUMetalCommandBufferStorageAllocResourceAtIndex.
    // batchMode (default): consecutive draws to ONE target (default FB) so they coalesce
    // into the lean-direct WORKER-BATCH (parallel) path -- the actual crash site -- rather
    // than forcing serial fallback via FBO<->default target switches (the probe showed the
    // alternating version took kind=serial, missing the crash path).
    if (batchMode) {
        glBindFramebuffer_(GL_FRAMEBUFFER, 0);
        glViewport_(0, 0, 256, 256);
    }
    for (int i = 0; i < N; ++i) {
        GLuint tex = sharedTex;
        if (distinctRes) {
            glGenTextures_(1, &tex);
            glBindTexture_(GL_TEXTURE_2D, tex);
            const unsigned char px[4] = {(unsigned char)(i & 0xFF), 64, 32, 255};
            glTexImage2D_(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
            glTexParameteri_(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            glTexParameteri_(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        }
        if (distinctVbo) {
            GLuint vbo = 0;
            glGenBuffers_(1, &vbo);
            glBindBuffer_(GL_ARRAY_BUFFER, vbo);
            glBufferData_(GL_ARRAY_BUFFER, sizeof(tri), tri, GL_STATIC_DRAW);
            glVertexAttribPointer_(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
            glEnableVertexAttribArray_(0);
        }
        glActiveTexture_(GL_TEXTURE0);
        glBindTexture_(GL_TEXTURE_2D, tex);
        glUniform1i_(sLoc, 0);

        if (batchMode) {
            // consecutive draw to the SAME bound target -> coalesces into the worker-batch
            glDrawArrays_(GL_TRIANGLES, 0, 3);
        } else {
            glBindFramebuffer_(GL_FRAMEBUFFER, fbo);   // render pass A: into the FBO
            glViewport_(0, 0, FB, FB);
            glClearColor_(0.0f, 0.0f, 0.0f, 1.0f);
            glClear_(GL_COLOR_BUFFER_BIT);
            glDrawArrays_(GL_TRIANGLES, 0, 3);
            glBindFramebuffer_(GL_FRAMEBUFFER, 0);     // render pass B: default FB (transition)
            glViewport_(0, 0, 256, 256);
            glDrawArrays_(GL_TRIANGLES, 0, 3);
        }

        if (((i + 1) & 63) == 0) {
            std::fprintf(stderr, "[stress] progress i=%d/%d (transitions=%d, distinctResAlloc=%d)\n",
                         i + 1, N, 2 * (i + 1), distinctRes ? (i + 1) : 0);
            std::fflush(stderr);
        }
    }

    glFinish_();  // force-commit the accumulated command buffer
    std::fprintf(stderr, "[stress] STRESS_COMPLETE N=%d transitions=%d glErr=0x%X (NO abort)\n",
                 N, 2 * N, glGetError_());
    std::fflush(stderr);

    makeCurrent(nullptr);
    destroy(ctx);
    return 0;
}
