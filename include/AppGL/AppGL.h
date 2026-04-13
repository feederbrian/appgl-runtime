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
size_t appglCoverageSnapshotJSON(char* out, size_t cap);
size_t appglRunGauntletJSON(const char* phaseFilter, char* out, size_t cap);
size_t appglRunBenchmarkJSON(char* out, size_t cap);
size_t appglDiagnosticsJSON(char* out, size_t cap);

#ifdef __cplusplus
}
#endif
