# Integration Guide

This guide walks through building AppGL, linking it into a macOS
application, and bringing up a GL context against a Metal layer or an
offscreen framebuffer.

## Prerequisites

- macOS 14 or later with the Xcode command line tools installed.
- CMake 3.28 or later.
- Python 3.10 or later (used by the dispatch codegen tool).
- Optional: `glslang` and `SPIRV-Cross` sources fetched via
  `scripts/fetch_third_party.sh` for the in-process shader translator.
  Without them AppGL falls back to accepting SPIR-V binaries directly.

## Building the library

AppGL builds with a straight CMake configure and build:

```bash
cmake -S . -B build -G Ninja
cmake --build build
```

This produces three targets:

| Target                | Output              | Use case                                    |
|-----------------------|---------------------|---------------------------------------------|
| `AppGL` (SHARED)      | `libAppGL.dylib`    | Runtime linking, apps that dlopen the layer |
| `AppGL_static` (STATIC) | `libAppGL.a`      | Compile-time linking, fully self-contained  |
| `appgl_gauntlet_cli`  | `appgl_gauntlet_cli`| Headless test runner over the full gauntlet |

Both library targets ship with the public headers under
`include/AppGL/`:

- `AppGL/AppGL.h` — the AppGL entry points (context lifecycle,
  make-current, swap, coverage and gauntlet JSON readback).
- `AppGL/glcorearb.h` — the Khronos GL 4.6 Core ARB header.
- `AppGL/khrplatform.h` — the Khronos platform typedef header.

To build against the vendored shader translator (enables GLSL source
compilation instead of accepting only SPIR-V binaries), first run
`scripts/fetch_third_party.sh` and then pass
`-DAPPGL_VENDOR_THIRD_PARTY=ON` to CMake.

## Linking AppGL into an application

### CMake consumer

```cmake
find_library(APPGL_LIBRARY AppGL PATHS /path/to/appgl/build REQUIRED)
target_include_directories(your_app PRIVATE /path/to/appgl/include)
target_link_libraries(your_app PRIVATE
  "${APPGL_LIBRARY}"
  "-framework Metal"
  "-framework QuartzCore"
  "-framework Foundation"
  "-framework AppKit"
)
```

### Xcode consumer

Add `libAppGL.dylib` (or `libAppGL.a`) to **Link Binary With
Libraries**, and add the `include/` directory to **Header Search
Paths**. Link against `Metal.framework`, `QuartzCore.framework`,
`Foundation.framework`, and `AppKit.framework`.

## Bringing up a context

### On a Cocoa window with a CAMetalLayer

```c
#include <AppGL/AppGL.h>

// Given a CAMetalLayer* pointer obtained from a backing NSView.
AppGLContext* ctx = appglCreateContextForLayer((void*)metalLayer);
appglMakeCurrent(ctx);

// Any call from glcorearb.h now goes through AppGL.
glClearColor(0.1f, 0.1f, 0.15f, 1.0f);
glClear(GL_COLOR_BUFFER_BIT);

appglSwapBuffers(ctx);
appglDestroyContext(ctx);
```

`appglCreateContextForLayer()` takes ownership of presenting to the
layer. The layer's pixel format, drawable size, and scale are
detected from the `CAMetalLayer` at context creation time; resize
events propagate through the next drawable acquisition.

### Headless / offscreen

```c
AppGLContext* ctx = appglCreateOffscreenContext(1280, 720);
appglMakeCurrent(ctx);

// Render into the default framebuffer, then read back with
// glReadPixels or attach your own FBO.
```

The offscreen context backs the default framebuffer with an RGBA8
MTLTexture at the requested size, with a matching depth-stencil
attachment. This is the mode used by the headless gauntlet runner.

## Running the gauntlet

The headless gauntlet executable is the authoritative parity test
suite for AppGL. It renders every tracked scene into the offscreen
backend and compares the result against the golden images shipped
under `tests/goldens/`.

```bash
./build/appgl_gauntlet_cli                    # run phase-a
./build/appgl_gauntlet_cli phase-7            # run phase-7 only
./build/appgl_gauntlet_cli all                # run every phase
./build/appgl_gauntlet_cli benchmark          # 3-tier performance benchmark
./build/appgl_gauntlet_cli compare            # GL 3.3 vs 4.1 vs 4.6 version comparison
```

The CLI prints a JSON report to stdout and returns 0 on success,
1 on infrastructure failure, or 2 on a gauntlet diff failure.

Last-run actuals land under `tests/reports/actuals/<phase>/<scene>.png`
for side-by-side comparison against the golden.

## API surface reference

The public headers expose two layers:

1. The GL surface (`glcorearb.h`) — every GL 3.3–4.6 Core entry
   point, identical to the upstream Khronos header.
2. The AppGL surface (`AppGL.h`) — nine C entry points for context
   lifecycle and diagnostic JSON readback:

   ```c
   AppGLContext* appglCreateContextForLayer(void* layer);
   AppGLContext* appglCreateOffscreenContext(int width, int height);
   void          appglDestroyContext(AppGLContext* context);
   void          appglMakeCurrent(AppGLContext* context);
   void          appglSwapBuffers(AppGLContext* context);
   size_t        appglCoverageSnapshotJSON(char* out, size_t cap);
   size_t        appglRunGauntletJSON(const char* phaseFilter, char* out, size_t cap);
   size_t        appglRunBenchmarkJSON(char* out, size_t cap);
   size_t        appglDiagnosticsJSON(char* out, size_t cap);
   size_t        appglLiveDiagnosticsJSON(char* out, size_t cap);
   ```

All five `*JSON` entry points use the size-probe convention: call
with `out == NULL` to get the required buffer size, then call again
with a caller-owned buffer of at least that size.

`appglDiagnosticsJSON` is the full dump — it walks the current context's
object store and reports buffer/texture/renderbuffer bytes alongside the
ring-buffered fields. Use it for startup/shutdown snapshots. If called
after context destruction it falls back to the last-known inventory captured
during `unregisterContext`, so BAR-style post-mortem hooks (fired from
`DestroyWindowAndContext`) still report the final session state instead of
all-zeros.

`appglLiveDiagnosticsJSON` is a lightweight poll variant — it skips the
object-store walk entirely and emits only the pipeline cache metrics, the
shader translation log, and the error log. Use it for end-of-frame polling
where walking tens of thousands of objects per frame would be wasteful.
