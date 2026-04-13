# AppGL

AppGL is an OpenGL 4.6 Core Profile translation layer for macOS and Apple
Silicon. It exposes a complete `libGL`-compatible C API and translates GL
draw calls, shaders, and state into Metal at runtime, so existing OpenGL
applications can run on macOS without rewriting to MoltenVK, Metal, or
WebGPU first.

## What it is

- A drop-in replacement for the deprecated macOS OpenGL framework.
- A single dynamic or static library (`libAppGL.dylib` or `libAppGL.a`)
  plus three public headers (`AppGL/AppGL.h`, `AppGL/glcorearb.h`,
  `AppGL/khrplatform.h`).
- A GLSL-to-MSL shader translation pipeline built on glslang and
  SPIRV-Cross.
- A parity-tested implementation: every new GL entry point is shipped
  with at least one golden image test in the gauntlet suite under
  `tests/goldens/`.

## What it is not

- Not a replacement for an actual Metal-native renderer if you are
  starting a new project today.
- Not a full-driver implementation — extensions outside GL 4.6 Core
  are not covered.
- Not a performance tier equal to hand-written Metal. AppGL aims to
  stay within 10–20 % of the native Metal path on the tested scenes;
  see [performance-levers.md](performance-levers.md) for the tunable
  knobs that get you there.

## Supported GL versions

AppGL implements the full GL 4.6 Core surface along with every earlier
core version back to 3.3:

| GL version | Status | Notes |
|------------|--------|-------|
| 3.3 Core   | Implemented | Bind-based API, immediate vertex attribs, query objects, all classic entry points |
| 4.0        | Implemented | Per-buffer blend state, `gl_MinSampleShading`, tessellation stubs |
| 4.1        | Implemented | `glProgramUniform*` DSA uniforms, separable program pipelines, f64 uniforms and vertex attribs |
| 4.2        | Implemented | Immutable texture storage, atomic counters, image load/store, transform feedback indexed |
| 4.3        | Implemented | Separated vertex format, SSBO, compute shaders, program resource introspection |
| 4.4        | Implemented | Buffer storage immutability, clear buffer, texture mirror-clamp |
| 4.5        | Implemented | Full DSA object creation, `glCreateBuffers`, `glNamedBufferStorage`, clip control |
| 4.6        | Implemented | Indirect count draws, polygon offset clamp, SPIR-V binary shader ingestion |

The same gauntlet test scene renders pixel-identical through the GL 3.3
bind-based path, the GL 4.1 DSA-uniforms path, and the GL 4.6 full-DSA
path — see the Phase 7 version comparison report in the project repo
for the measured verdict.

## Build and link

See [integration.md](integration.md) for the full build and link
instructions, including the CMake targets, the public headers, and
how to initialize a context against a `CAMetalLayer` or an offscreen
framebuffer.

## Performance tuning

See [performance-levers.md](performance-levers.md) for the documented
runtime and build-time knobs that trade parity, memory, or
compatibility for measured speedups.

## Double precision

See [double-precision.md](double-precision.md) for the planned
alternate build path that preserves f64 fidelity end-to-end for
applications that cannot tolerate the default f64 -> f32 narrowing.

## Project layout

```
appgl-runtime/
  CMakeLists.txt            CMake build definition
  include/AppGL/            Public C headers
  src/                      Library source (caps, context, state, shader, ...)
  tests/                    Headless gauntlet, golden images
  tools/gen_from_registry/  Khronos XML -> C++ dispatch codegen
  third_party/stb           Image I/O helpers for the test harness
  docs/                     This directory
```

Everything needed to build, link, and test AppGL lives under this one
directory. The translation layer does not depend on any OpenGL
framework at runtime — it is a pure Metal consumer.
