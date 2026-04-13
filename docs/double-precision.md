# Double Precision (f64) Build

Metal has no native `double`-precision ALU on Apple Silicon. Every
fragment or vertex pipeline stage executes in single-precision float
on the GPU regardless of what the shader source declared. This
document covers how AppGL handles GLSL `double`, `dvec2`, `dvec3`,
`dvec4`, `dmat*`, and the related uniform and vertex attribute
entry points — and how the planned alternate build path preserves
f64 end-to-end for applications that cannot tolerate the default
narrowing.

> **Status:** the default f64 -> f32 narrowing path is shipped.
> The f64-buffer-backed alternate build is designed but not yet
> wired in. This document is the design specification; the
> `APPGL_DOUBLE_UNIFORM_BUFFER_BACKED` build option is the tracking
> flag.

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
