# Double Precision (f64) Runtime Opt-In

Metal has no native `double`-precision ALU on Apple Silicon. Every
fragment or vertex pipeline stage executes in single-precision float
on the GPU regardless of what the shader source declared. This
document covers how AppGL handles GLSL `double`, `dvec2`, `dvec3`,
`dvec4`, `dmat*`, and the related uniform and vertex attribute
entry points, plus the runtime flag that allows porters to expose
the conformance FP64 emulation path in the default build.

> **Status:** the default build does not advertise
> `GL_ARB_gpu_shader_fp64` or `GL_ARB_vertex_attrib_64bit` unless the
> runtime opt-in is enabled. The historical `build-fp64-phase1`
> compile flag remains supported, but it is no longer required for
> the default-build CTS path.

## Default behavior — lossy narrowing

Out of the box, AppGL accepts every f64 entry point in the GL 4.1
surface and narrows the values to f32 when they cross into Metal:

- `glUniform1d`, `glUniform1dv`, ..., `glUniform4d*`
- `glUniformMatrix{2,3,4}dv`, `glUniformMatrix{2x3,2x4,3x2,3x4,4x2,4x3}dv`
- `glProgramUniform{1..4}d*`, `glProgramUniformMatrix*dv`
- `glVertexAttribL{1..4}d*`, `glVertexAttribLPointer`

The original f64 values are preserved in a CPU-side shadow store
keyed on the uniform location (or vertex attribute binding point),
so `glGetUniformdv` and `glGetVertexAttribLdv` readback round-trips
losslessly. Only the values that actually reach the GPU are f32.

The GLSL-to-MSL translator rewrites `double` to `float`, `dvec4`
to `float4`, `dmat4` to `float4x4`, and so on. Any shader arithmetic
on `double` types executes at single precision.

This behavior matches what the real macOS OpenGL driver did on
Apple Silicon and on the Intel-era Macs that lacked native f64 ALUs.
Applications that use f64 uniforms for numerical stability near
their coordinate origin (a common pattern in large-world renderers)
will see the same artifacts they saw on the native driver.

## Runtime opt-in

The FP64 extension surface is gated at runtime. AppGL resolves the
gate in this order:

1. User-editable JSON override.
2. Porter/runtime environment flag.
3. CMake default (`APPGL_FP64_EMULATION`).

The default build has `APPGL_FP64_EMULATION=OFF`, so FP64 CTS cases
that check `GL_ARB_gpu_shader_fp64` or `GL_ARB_vertex_attrib_64bit`
must report `NotSupported` unless a JSON or environment override
enables the feature. The CTS `gpu_shader_fp64.fp64.state_query` case
intentionally bypasses the extension check, so it is not a valid
default-off advertising probe. A shipped port can enable the same
default-build runtime by setting one of these environment flags before
loading AppGL:

```bash
APPGL_ENABLE_FP64_EMULATION=1
```

Accepted aliases are `APPGL_ENABLE_GPU_SHADER_FP64=1` and
`APPGL_ENABLE_VERTEX_ATTRIB_64BIT=1`. Explicit false values such as
`0`, `false`, `no`, `off`, or `disabled` turn the runtime gate off.
`APPGL_DF64_FORCE_ADVERTISE=1` is still measurement-only and only
relaxes the Metal-family probe; it does not enable FP64 by itself.

### JSON override

AppGL also looks for an `appgl-options.json` file. This is intended
for end users and overrides porter flags, including a porter-provided
enable flag.

Search order:

1. `APPGL_OPTIONS_JSON` or `APPGL_CONFIG_JSON` if set.
2. `appgl-options.json` in the current working directory.
3. `appgl-options.json` next to the process executable.
4. `appgl-options.json` in the app bundle resources.

Accepted keys may be top-level or nested under `appgl` or `features`:
`fp64_emulation`, `f64_emulation`, `gpu_shader_fp64`, and
`vertex_attrib_64bit`. Values may be booleans, boolean strings, or an
object containing `enabled`, `force`, or `value`.

```json
{
  "appgl": {
    "fp64_emulation": true
  }
}
```

## Alternate path — f64-buffer-backed emulation

For applications that cannot tolerate the narrowing — scientific
visualization, astronomical renderers, CAD tools with planet-scale
bounds — AppGL is designed to build in an alternate f64 mode
selected at compile time via:

```bash
cmake -DAPPGL_DOUBLE_UNIFORM_BUFFER_BACKED=ON -S . -B build-f64
```

In this mode the translation layer behaves as follows.

### Uniform storage

f64 uniforms are packed into a dedicated `MTLBuffer` bound at a
reserved slot (`kDoubleUniformBuffer = 30`) instead of flowing
through the standard uniform descriptor. The buffer layout matches
the GLSL std140 layout with `double` sized at 8 bytes.

### Shader rewrite

The GLSL-to-MSL translator emits a shim header that redefines
`double`, `dvec*`, and `dmat*` as struct wrappers around `uint2`
pairs representing the IEEE 754 f64 bit pattern. Every arithmetic
operator that would have run natively on f64 is replaced with a
call into a double-double library compiled from existing open
source (Bailey's QD library is the current reference). Function
call sites that pass or return `double` are rewritten to pass the
`uint2` representation.

The library implements the f64 addition, subtraction,
multiplication, division, square root, and comparison operators
using f32 double-double arithmetic on the GPU. Accuracy is not
bit-exact to IEEE 754 f64 but is good to ~50 bits of mantissa
precision — sufficient for the large-world and numerical stability
use cases this mode targets.

### Vertex attributes

f64 vertex attributes packed via `glVertexAttribLPointer` flow
through a compute kernel that runs before the draw call and unpacks
the f64 stream into an f32 stream at the bound vertex buffer slot.
The compute pass writes into a ring buffer owned by the vertex
pipeline; the draw call reads from the unpacked f32 stream via the
standard vertex descriptor.

This keeps the vertex shader stage running in single precision
while preserving the f64 fidelity of the input data up to the
point of division by the f32 range.

### Performance

The alternate path is significantly slower than the default:

| Operation | Default (narrowing) | f64-buffer-backed |
|-----------|---------------------|-------------------|
| `glUniform4d` call | ~50 ns | ~50 ns (CPU side identical) |
| Shader `dvec4` add | 1 cycle | ~30 cycles |
| Shader `dmat4 * dvec4` | 16 cycles | ~800 cycles |
| Vertex attribute unpack (compute pre-pass) | 0 | 1 dispatch per frame |

Enable only on scenes where f64 fidelity is a correctness
requirement, not a nice-to-have. The gauntlet will ship a
`phase-7.double-precision-large-world` scene to track regressions
in the alternate path once it lands.

## Tracking

The alternate path is gated on `APPGL_DOUBLE_UNIFORM_BUFFER_BACKED`.
Work is tracked in a dedicated phase plan separate from this
document. Applications that want to be ready can already call the
f64 entry points today — the default build will narrow, and the
alternate build will preserve precision once the rewrite shim is
implemented. No application-side code changes will be required to
switch between builds.
