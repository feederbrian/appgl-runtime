#pragma once

#include <stddef.h>
#include "khrplatform.h"
#include "glcorearb.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AppGLContext AppGLContext;

AppGLContext* appglCreateContextForLayer(void* layer);
AppGLContext* appglCreateOffscreenContext(int width, int height);
void appglDestroyContext(AppGLContext* context);
void appglMakeCurrent(AppGLContext* context);
void appglSwapBuffers(AppGLContext* context);

/**
 * Opaque function-pointer type returned by appglGetProcAddress. Callers
 * cast this back to the appropriate PFNGL<NAME>PROC type before invoking
 * the entry point, matching the GLX/WGL/EGL get-proc-address convention.
 */
typedef void (*AppGLProc)(void);

/**
 * Canonical loader entry point. Resolves an OpenGL 4.6 core entry point
 * name (e.g. "glClearColor", "glDrawArrays") to a callable function
 * pointer, or returns NULL if the name is not part of the generated core
 * manifest. This is the supported surface for external GL loaders (glad /
 * GLEW / in-engine loaders in Recoil/BAR) to populate their dispatch
 * tables against the AppGL runtime without linking against the generated
 * entry points directly.
 *
 * Resolution is O(log N) across the 657-entry sorted table and does not
 * require a current AppGL context — the loader pattern wants to run at
 * program startup before any context is made current.
 */
AppGLProc appglGetProcAddress(const char* name);
size_t appglCoverageSnapshotJSON(char* out, size_t cap);
size_t appglRunGauntletJSON(const char* phaseFilter, char* out, size_t cap);
size_t appglRunBenchmarkJSON(char* out, size_t cap);
size_t appglDiagnosticsJSON(char* out, size_t cap);
/**
 * Lightweight poll-friendly diagnostics dump. Emits only the fields that can
 * change frame-to-frame (pipeline cache metrics, shader translations, error
 * log) without walking the object store. Safe to call every frame from an
 * engine integration hook — the cost is bounded by the internal ring buffer
 * sizes (32 shader translations + 64 error records) and a single metrics read.
 *
 * Prefer this over appglDiagnosticsJSON for in-frame polling; use the full
 * variant for startup/shutdown snapshots where the O(N) object-store walk
 * is acceptable.
 */
size_t appglLiveDiagnosticsJSON(char* out, size_t cap);

#ifdef __cplusplus
}
#endif
