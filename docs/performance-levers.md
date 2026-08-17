# Performance Levers

AppGL ships with a set of tunable optimizations, organized by the risk
they pose to GL parity. The default build enables every Tier 1 lever
because they are zero-cost and pixel-identical. Tier 2 and Tier 3 levers
are opt-in and trade some combination of parity, memory, or
compatibility for measured speedups.

This document describes each lever, the measured impact on the Phase 7
benchmark suite, and how to enable or disable it. For the underlying
research and the full optimization catalog including experimental levers
not yet in the tree, see the internal Phase 7 optimization notes.

## Tier 1 — Always on (safe, high impact)

These levers are enabled by default in every build. They hold the GL
specification exactly but remove unnecessary work on the hot path.

### Triple-buffered vertex / index ring buffer

Inline `glBufferData` uploads and glDraw* calls against client-side
arrays bounce through a per-frame ring buffer sized to the working set
of the previous N frames. Eliminates the per-draw MTLBuffer allocation
that was the dominant cost of the legacy path.

Measured impact: 2.4x speedup on object-count-stress (1000 sphere scene).

Flag: always on. No runtime toggle.

### Depth/stencil state cache

The Metal `MTLDepthStencilState` objects are cached by a 64-bit hash of
the GL depth and stencil state block. Previously the state was rebuilt
on every draw.

Measured impact: ~18 % reduction on the depth-heavy physics-collision
scene, zero cost elsewhere.

Flag: always on.

### Uniform scratch buffer

Per-draw UBO packing lands in a ring-buffer scratch allocation instead
of a fresh MTLBuffer. Uses the same lifetime guarantees as the vertex
ring.

Measured impact: 12 % reduction in CPU frame time across the shader-
heavy scenes (lighting-phong, gl46-zero-bind-dsa).

Flag: always on.

### Deferred clear / render pass merge

`glClear` calls that land immediately before a draw into the same
render target are absorbed into the draw's `MTLRenderPassDescriptor`
load action, eliminating a redundant encoder begin/end pair.

Measured impact: 4-6 % reduction on scenes that clear-and-draw every
frame, zero cost when the clear is actually needed.

Flag: always on.

### Direct Metal buffer binding for VBO-backed draws

When a draw call's vertex data lives entirely in a bound
`GL_ARRAY_BUFFER` (the common case), AppGL binds the `MTLBuffer`
directly to the render encoder instead of routing through a shadow
copy.

Measured impact: 22 % reduction on polygon-objects (static VBO scene).

Flag: always on.

### Encoder state deduplication

The render encoder tracks the last-bound pipeline state, vertex
buffers, uniform buffers, depth/stencil state, cull mode, and
viewport. Redundant binds within a single render pass are dropped.

Measured impact: 8-14 % reduction on scenes that draw many objects
with small state deltas.

Flag: always on.

### Precomputed uniform layout

Per-program uniform block layouts are computed once at link time and
cached on the `GLProgramObject`. The draw path packs uniforms using
the cached offset table instead of walking the reflection data every
frame.

Measured impact: 5-9 % reduction on the shader-heavy scenes.

Flag: always on.

### Semaphore-based frame pacing

Frame submission blocks on a counting semaphore sized to the number of
in-flight frames (default 2) so the CPU cannot run more than N frames
ahead of the GPU. Previously the CPU could stall the GPU by allocating
ahead on the shared ring buffers.

Measured impact: eliminates frame-time spikes on busy scenes, no
steady-state overhead.

Flag: always on. Configure in-flight count via
`APPGL_INFLIGHT_FRAMES` environment variable (default 2, max 3).

## Tier 2 — Opt-in (moderate risk, high reward)

These levers are shipped in the tree but disabled by default. They are
safe in the sense of "your app will probably work fine" but may
introduce behavior differences under edge cases.

### `APPGL_LAZY_UNIFORM_PACKING`

Defers UBO packing from `glDraw*` to the actual Metal encoder setup.
When the same uniforms are bound for multiple consecutive draws, the
packing work is done once. Breaks parity under one rare case: apps
that modify a uniform value *between* a `glDraw*` call and a
subsequent state query that reads back the same uniform.

Enable via environment variable:

```bash
export APPGL_LAZY_UNIFORM_PACKING=1
```

Measured impact: 6-11 % reduction on heavy state-delta scenes.

### `APPGL_SKIP_SHADOW_BUFFER_STATIC`

For buffers created with `GL_STATIC_DRAW` or `glBufferStorage` without
`GL_MAP_READ_BIT`, skip the CPU-side shadow copy entirely. The Metal
buffer is the only copy. Breaks parity under one rare case:
`glGetBufferSubData` on a buffer that would otherwise have had a
shadow copy.

Enable via environment variable:

```bash
export APPGL_SKIP_SHADOW_BUFFER_STATIC=1
```

Measured impact: 30-50 % memory reduction on scenes with large
static VBOs / IBOs.

### `APPGL_ASYNC_PIPELINE_COMPILATION`

Compile `MTLRenderPipelineState` objects on a background queue when
the shader set is first seen, with a fallback to a stub pipeline for
the first few frames. Subsequent frames pick up the compiled
pipeline once it is ready. Breaks parity for the first N frames of
any scene that has never seen a given shader combination — stub
pipeline draws appear as solid black.

Enable via environment variable:

```bash
export APPGL_ASYNC_PIPELINE_COMPILATION=1
```

Measured impact: eliminates the ~50 ms first-frame stall on cold
cache, steady-state unchanged.

### `APPGL_INDEX_BYTE_CACHE`

Cache the expanded GL_UNSIGNED_BYTE -> GL_UNSIGNED_SHORT index buffer
across draws of the same IBO. Previously expanded every draw. Safe
unless the app mutates an 8-bit index buffer between draws without
orphaning it.

Enable via environment variable:

```bash
export APPGL_INDEX_BYTE_CACHE=1
```

Measured impact: 25 % reduction on scenes that draw many objects
with 8-bit indices (common in mobile-ported content).

## Tier 3 — Experimental (high risk, high reward)

These levers are documented as design points but are not yet shipped
in the tree. They will appear as opt-in flags in a future release
once the parity gauntlet is extended to cover them.

- **Parallel command encoding** (Option C): split large gauntlet
  scenes into independent render pass descriptors encoded on
  separate command encoders and submitted in a single
  `MTLCommandBuffer`. Measured 1.8x speedup on the object-count
  benchmark in prototype testing. Breaks parity under GL's
  deterministic draw ordering requirement for scenes that assume
  in-order fragment updates to overlapping geometry.

- **Indirect Command Buffers (ICBs)**: encode the GL draw stream
  into a Metal indirect command buffer once per scene and reuse
  across frames. Prototype showed 3x speedup on the static physics
  scene. Requires per-scene validation because GL state changes
  between draws break the precompiled ICB.

- **MTLHeap-backed texture pool**: allocate texture storage from a
  single persistent `MTLHeap` instead of per-texture allocations.
  Saves ~200 µs per texture creation. Breaks parity for
  `glTexStorage` immutability semantics under aliasing.

- **MTLBinaryArchive for pipeline cache**: serialize compiled
  pipeline state objects to disk so subsequent runs skip MSL
  compilation entirely. Expected 80 % reduction in first-frame cost.
  Interacts with the `dev.appgl.AppGL/shaders` cache directory.

- **Argument buffers for bindless textures**: replace per-draw
  texture argument tables with a persistent argument buffer. 15-20 %
  reduction on heavy texture scenes. Requires a GL extension
  surface that the app must opt into.

For the latest status on each of these and for measured deltas
against the Phase 7 baseline, see the internal optimization catalog.

## Benchmark baseline

All "measured impact" numbers in this document are against the
Phase 7 3-tier benchmark suite running on an M1 Max / 64 GB / macOS
14.4, with the pipeline cache warmed and in `Release` configuration.
Your numbers will differ based on hardware, thermal state, and scene
complexity. Use `appgl_gauntlet_cli benchmark` to generate a local
baseline before tuning.
