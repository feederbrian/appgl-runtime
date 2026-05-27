# DCR3-C Generic Producer-Pending Flag Design

## Objective

DCR3-C part (a) restores readback-time producer coherence without restoring the
removed RC-A02 draw-tail drain. The fix is resource-scoped:

1. Every GPU write to a GL resource sets a pending-producer flag.
2. Every consumer that reads, binds for a dependent read, or destroys/redefines
   that resource checks and drains the flag first.
3. The flag clears only after the producing command buffer is complete.

The correctness proof is symmetric:

- `exhaustive-produce-mark`: every GPU-write-to-resource reaches the producer
  mark funnel.
- `exhaustive-consume-edge`: every CPU readback, GPU dependent binding,
  copy-source read, and lifecycle edge reaches the consumer drain funnel.

Both halves are required. A missed producer mark can serve stale data even if
all consumers drain perfectly; a missed consumer drain can serve stale data even
if every producer marks perfectly.

## Non-Goals

- Do not edit `makeCommandBufferImpl`, `maybeFlushCurrentForPressure`, pressure
  thresholds, submit-mode tables, completion handlers, in-flight counters, or
  command-buffer allocation policy.
- Do not add a per-draw wait.
- Do not fold a clip-control metadata/orientation fix into this change. Keep
  `clip_control[_ARB].viewport_bounds` as a flag-only isolate point: if the
  generic producer flag fixes it, it is producer coherence; if it persists, it
  must be a separate attributed clip/viewport fix with broad preservation gates.

## Existing Precedent

`GLTextureObject::msaaFramebufferWriteNeedsSamplerFlush` already proves the
timing model:

- Mark after a GPU producer writes an MSAA color texture as an FBO attachment.
- Drain later in `resolveSamplerBindings` before a shader samples the texture.
- Drain during framebuffer deletion if that pending attachment would otherwise
  lose its metadata.

That precedent is correct but too narrow. DCR3-C replaces the one-off Boolean
with typed per-resource pending state and routes both marking and draining
through structural funnels.

## Resource State

Add a bitset to each GPU-backed resource:

```cpp
enum GLProducerPendingBits : uint32_t {
    kProducerFboColorWrite        = 1u << 0,
    kProducerFboDepthStencilWrite = 1u << 1,
    kProducerStorageImageWrite    = 1u << 2,
    kProducerShaderStorageWrite   = 1u << 3,
    kProducerAtomicCounterWrite   = 1u << 4,
    kProducerTransformFeedback    = 1u << 5,
    kProducerCopyWrite            = 1u << 6,
    kProducerClearWrite           = 1u << 7,
    kProducerComputeWrite         = 1u << 8,
    kProducerUploadWrite          = 1u << 9,
    kProducerSparseResidency      = 1u << 10,
    kProducerMipmapWrite          = 1u << 11,
};
```

Storage:

- `GLTextureObject`: FBO texture writes, storage-image writes, copy/blit
  destinations, mipmap-generated levels, sparse texture commit/sidecar writes,
  and async upload writes.
- `GLRenderbufferObject`: FBO renderbuffer writes, renderbuffer clears, mirrors,
  and copy/blit destinations.
- `GLBufferObject`: SSBO writes, atomic counter writes, transform-feedback
  writes, compute writes, copy destinations, indirect-command writes, vertex and
  element buffer writes, texture-buffer source writes, and sparse buffer commits.

The bitset is conservative. If reflection or access metadata cannot prove a
binding is read-only, it is treated as writable and marked after a successful
producer command.

## Produce-Mark Funnel

The implementation should create one GL-context-level producer funnel, not a
collection of direct flag writes:

```cpp
struct GpuResourceWrite {
    enum class Kind { Texture, Renderbuffer, Buffer };
    Kind kind;
    GLuint name;
    uint32_t producerBits;
};

using GpuResourceWriteSet = std::vector<GpuResourceWrite>;

void markGpuResourceWrites(const GpuResourceWriteSet& writes);
```

All GPU resource-writing entry points must build a `GpuResourceWriteSet` and
call `markGpuResourceWrites` only after the relevant framegraph encode/commit
succeeds. No producer site writes resource flags directly. This gives one
auditable place where flags are set, analogous to the command-buffer allocation
funnel: a new GPU write path that does not produce a write set is visibly
outside the funnel and fails review.

### Structural Write-Set Sources

The write set is collected at the places where GL object identity is still
available. MetalFrameGraph sees Metal handles, so the funnel belongs in
`GLContext::Impl`, immediately around the framegraph calls.

| Producer family | Structural source for `GpuResourceWriteSet` |
| --- | --- |
| FBO draw outputs | The bound draw FBO attachment table resolved once after successful translated/immediate/solid draw encoding. |
| FBO clears | The framebuffer attachment selected by `clearColorAttachment`, depth clear, stencil clear, or full `glClear` state. |
| Graphics storage images | `resolveImageBindings` records texture object names and image access while preparing draw bindings. Writable/read-write images enter the write set after successful draw encoding. |
| Graphics SSBOs and atomics | `resolveSSBOBindings` records buffer object names for SSBO and atomic counter bindings. Writable or unknown-access buffers enter the write set after successful draw encoding. |
| Compute storage images | Compute dispatch binding construction records texture object names and access. Writable/read-write images enter the write set after successful dispatch. |
| Compute SSBOs and atomics | Compute dispatch binding construction records buffer object names. Writable or unknown-access buffers enter the write set after successful dispatch. |
| Copy/blit destinations | Copy/blit setup already resolves source and destination GL objects. Destination objects enter the write set after successful GPU copy/blit encoding. |
| Mipmap generation | `generateMipmaps` owns the texture object and generated destination levels. The texture enters the write set after GPU mipmap generation or GPU-assisted level writes. |
| Sparse commit/sidecar | Sparse texture/buffer commit and sparse storage-image sidecar helpers own the texture/buffer object. The resource enters the write set after GPU residency/sidecar writes. |
| Upload/mirror/fp64/TF/tess/mesh | Existing keep-wait paths still route their destination GL object into the write set before any future async conversion is allowed. |

Default-framebuffer draws have no GL resource object to mark. They remain covered
by the existing default-readback `encodePendingWork()` + `flushForReadback()`
path. That is why `clip_control[_ARB].viewport_bounds` is kept as an isolate:
if it fails after object-backed producer flags are correct, its root is not a
missing per-resource producer flag.

### Produce-Mark Exhaustiveness Argument

The proof obligation is: every GPU command that can mutate a GL resource must
declare its destination through `GpuResourceWriteSet`.

By construction:

- Render-pass producers cannot mutate object-backed storage except through the
  currently bound draw framebuffer attachments or graphics write bindings
  already resolved for the draw. Both are structural write-set sources.
- Compute producers cannot mutate object-backed storage except through compute
  image/SSBO/atomic bindings or indirect/storage buffers already resolved for
  dispatch. Those bindings are structural write-set sources.
- Blit/copy/mipmap/sparse/upload producers cannot mutate object-backed storage
  without an explicit destination object argument. Those destination objects are
  structural write-set sources.
- Emulation producers such as transform feedback, tessellation, mesh, fp64
  sidecars, and sparse sidecars must name the destination object before encoding
  their GPU work. They are not converted to async unless they route through the
  same write-set funnel.

Per-site producer marking is allowed only where a real structural source is
impossible. Any such exception must have a red-before-green sentinel proving the
missed mark would reproduce stale data.

## Consume-Drain Funnel

The consume side should also use one helper instead of open-coded drains:

```cpp
bool drainPendingGpuProducers(const GpuResourceReadSet& reads);
```

Behavior:

1. Inspect all resources in the read set.
2. If none carry matching pending bits, return without touching the framegraph.
3. If any carry matching pending bits, call `frameGraph->flushForReadback()` once.
4. Clear drained bits on all resources in that read set after the wait completes.

The helper reuses the existing `FlushForReadback` reason. It does not allocate a
new pressure path or alter commit policy.

### Structural Read-Set Sources

| Consumer family | Structural source for `GpuResourceReadSet` |
| --- | --- |
| Pixel readback | `readPixels` resolves the read framebuffer/attachment and delegates through color/depth/stencil read helpers. Those helpers form the read set. |
| Texture readback | `getTextureImage` resolves the texture object and level before any Metal read/staging path. That resolved object forms the read set. |
| Buffer readback | `getBufferSubData`, DSA buffer get, `mapBuffer`, `mapBufferRange`, and internal `readBufferRange` callers resolve a `GLBufferObject` before reading CPU-visible contents. That object forms the read set. |
| GPU sampler reads | `resolveSamplerBindings` resolves texture object names for sampled textures, shadow samplers, multisample samplers, texture buffers, and `textureSize`. Those objects form the read set before binding. |
| GPU image reads | `resolveImageBindings` resolves texture object names and access. Read-only/read-write images form the read set before binding. |
| GPU SSBO/atomic reads | `resolveSSBOBindings` and compute binding construction resolve buffer object names. Buffers with pending producer bits form the read set before binding. |
| Vertex/index/indirect reads | Vertex-array setup, element-array setup, draw indirect, dispatch indirect, and internal `readIndirectBuffer` resolve buffer objects before Metal or CPU consumes them. Those buffers form the read set. |
| Copy/blit source reads | CopyImageSubData, CopyTextureSubImage, and GPU blit setup resolve source objects before encoding. Those sources form the read set. |
| Lifecycle/redefinition | Delete, detach, storage redefinition, texture-buffer rebinding, buffer orphaning, sparse decommit/recommit, and framebuffer deletion resolve objects before metadata is discarded. Those objects form the read set. |

Default-framebuffer readback remains a separate broad queue drain because no GL
object exists for a read set.

### Consume-Edge Exhaustiveness Argument

The proof obligation is: every operation that can observe GPU-written resource
contents must call `drainPendingGpuProducers` before observing or invalidating
that resource.

By construction:

- CPU-visible reads all pass through object-resolution helpers before copying or
  mapping memory. Those helpers are the readback funnel.
- GPU dependent reads all pass through binding-resolution helpers before Metal
  receives textures or buffers. Those helpers are the GPU-bind funnel.
- Copy/blit commands pass through source-resolution helpers before encoding.
  Those helpers are the copy-source funnel.
- Lifecycle operations pass through object deletion/redefinition helpers before
  storage or metadata is dropped. Those helpers are the lifecycle funnel.

Open-coded calls to `frameGraph->flushForReadback()` should either be folded into
this helper or documented as no-resource/default-framebuffer cases.

## Confirmed Residual Classes

### 1. Depth/Clip: `clip_control[_ARB].viewport_bounds`

Source shape:

- Produce: draw under clip-control origin and viewport bounds.
- Consume: default-framebuffer readback through `glu::readPixels`.
- Current state: default readback already has a broad `flushForReadback()` path.

Design coverage:

- Object-backed FBO color/depth/stencil writes mark through the FBO attachment
  write-set source.
- Object-backed color/depth/stencil readbacks drain through the readback funnel.
- Default framebuffer continues to use the existing broad drain because there is
  no resource object to flag.

Attribution rule:

- If the generic producer flag fixes this residual, classify it as producer
  coherence.
- If it persists, do not co-land a fix. Split a separate clip-control metadata
  commit and gate it broadly across texture-repeat mode, draw-indirect,
  face-culling, viewport, coordinate, and clip-origin surfaces.

### 2. Compute Output: `compute_shader.pipeline-post-fs`

Source shape:

- FBO render writes texture A.
- Compute reads image A and writes texture B.
- Compute reads image B and writes texture A.
- `glGetTexImage(A)` validates the result.

Design coverage:

- Render-to-texture A marks through the FBO attachment write-set source.
- Compute image read A drains through compute image read-set construction.
- Compute image write B marks through compute image write-set construction.
- Compute image read B drains through compute image read-set construction.
- Compute image write A marks through compute image write-set construction.
- `glGetTexImage(A)` drains through the texture-readback funnel.

### 3. SSBO/Image: `shader_subroutine.ssbo_atomic_image_load_store`

Source shape:

- Fragment subroutine writes atomic counter buffers, then maps the atomic buffer.
- Fragment subroutine performs SSBO atomics, then maps the SSBO.
- Fragment subroutine performs image stores, then verifies texture contents.

Design coverage:

- Graphics SSBO/atomic/image bindings record writable resources during
  `resolveSSBOBindings` and `resolveImageBindings`.
- Successful draw encoding marks those buffers/textures through
  `markGpuResourceWrites`.
- `glMapBuffer`, `glGetBufferSubData`, and texture readback drain through the
  CPU readback funnels.
- Later image/sampler/SSBO shader consumers drain through GPU binding funnels.

This covers the current gap where `GL_SHADER_STORAGE_BARRIER_BIT`,
`GL_SHADER_IMAGE_ACCESS_BARRIER_BIT`, and `GL_ATOMIC_COUNTER_BARRIER_BIT` are
treated as GPU-only while raw map/get paths do not flush pending graphics writes.

### 4. Texture Read: `texture_cube_map_array.texture_size_fragment_sh`

Source shape:

- Fragment shader calls `textureSize` on cube-map-array samplers.
- Draw writes returned dimensions into 2D render-target textures.
- Validation attaches those textures for readback and calls `glReadPixels`.

Design coverage:

- Sampler/`textureSize` input textures drain through `resolveSamplerBindings`.
- Render-target result textures mark through the FBO attachment write-set source.
- Readback of those result textures drains through framebuffer attachment
  readback helpers.

This generalizes the MSAA-only sampler drain to single-sample render targets and
texture-size-only shader consumers.

## Sentinel Plan

Every accepted sentinel must be red on the pre-fix build first. A sentinel that
passes on the broken baseline is false-green and does not prove coverage.

### Inventory Sentinels

| Class | Sentinel shape | Red signal required before fix |
| --- | --- | --- |
| Depth/clip | Draw under clip-control + viewport into object-backed FBO color/depth targets and into default framebuffer; read through normal color/depth/default readback. | Object-backed stale read proves producer gap. Default-only persistence after producer fix proves separate metadata root. |
| Compute output | Render texture A, compute image read A/write B, compute image read B/write A, then `glGetTexImage(A)`. | Stale final texture before image/FBO producer handoff. |
| SSBO/atomic | Fragment shader writes SSBO and atomic counter buffers, then immediate `glMapBuffer`/`glGetBufferSubData`. | Stale buffer contents before buffer producer drain. |
| Storage image | Fragment shader imageStore to texture, then shader imageLoad/sample or texture readback. | Stale texture contents before storage-image producer drain. |
| Texture read | Single-sample FBO render target later consumed by sampler/`textureSize`, with final `glReadPixels`. Include the cube-map-array texture-size shape. | Stale sampled/readback result before generalized texture producer drain. |

### BAR-Only Producer Sentinels

These are mandatory because CTS P->F=0 cannot prove coverage for producers that
CTS does not reach. Each must reproduce stale data with the flag disabled or
missing, then pass with the flag.

| BAR-only class | Sentinel shape | Coverage proof |
| --- | --- | --- |
| Blit producer | GPU blit/copy writes a texture or renderbuffer, then a shader samples it and CPU readback validates the dependent result. | Proves copy/blit destinations enter the produce funnel and sampler/readback consumers drain. |
| Mipmap generation | Base level is GPU-produced, mipmap generation writes lower levels, then shader samples a generated level or `glGetTexImage` reads it. | Proves mipmap-generated levels enter the produce funnel and texture consumers drain. |
| `copyImageSubData` CPU-shadow-read | Source object has pending GPU write; copyImageSubData takes a CPU-shadow/fallback read path; destination is later sampled/read back. | Proves copyImageSubData source drains before CPU-shadow reads and destination marks after copy. |
| Sparse commit | Sparse texture/buffer commit or sparse sidecar write produces residency/data, then shader samples/loads or CPU readback validates. | Proves sparse commit/sidecar producers mark and later consumers drain. |
| Lifecycle with pending producer | Delete/redefine/orphan an object carrying pending producer bits before any other drain, then validate no stale/lost write on surviving destination or alias. | Proves lifecycle read-set drains before metadata is discarded. |
| Buffer-as-different-role | GPU writes a buffer as SSBO/atomic/compute output, then same storage is used as vertex, element, indirect, or texture-buffer source. | Proves buffer role changes drain through GPU binding funnels, not only map/get. |

If any candidate passes on the broken build, it must be widened until it reaches
a real missed producer-consumer edge or excluded as non-discriminating audit
coverage.

## Acceptance Bar

Part (a) is accepted only when all five conditions hold:

1. Produce-mark coverage is structural: every GPU-write-to-resource reaches
   `markGpuResourceWrites`, with documented exceptions only where a funnel is
   impossible and covered by red-green sentinels.
2. Consume-edge coverage is structural: every CPU readback, GPU dependent bind,
   copy-source read, and lifecycle/redefinition edge reaches
   `drainPendingGpuProducers`, with documented no-resource/default-framebuffer
   exceptions.
3. Full 19,716-case re-gate in both variants has P->F=0 versus `abca279`, clean
   coverage, and variant-independent residual behavior.
4. Producer-coverage audit is green, including the BAR-only sentinels for blit,
   mipmap generation, copyImageSubData CPU-shadow read, sparse commit, and the
   four inventory classes.
5. Pressure-net b/c carry is byte-identical: no changes to pressure or commit
   machinery.

## Backward-Carry Guarantee

DCR3-C part (a) adds only readback-coherence metadata and consumer-side waits.
All waits enter through the existing `flushForReadback()`/`FlushForReadback`
semantics. A separate typed CPU-visible barrier wrapper is intentionally out of
scope for this change.

The pressure-net remains unchanged:

- No edits to command-buffer pressure decisions.
- No edits to submit-mode tables.
- No edits to `makeCommandBufferImpl`.
- No edits to `maybeFlushCurrentForPressure`.
- No edits to completion handlers, in-flight counters, or pressure flush
  allocation behavior.

That preserves the 591e07c -> d30d762 -> 0787abc pressure behavior while moving
RC-A02's broad producer safety to resource-specific readback-time gates.

## Clerk Review Checklist

- Is `exhaustive-produce-mark` argued by structural funnel, with mandatory
  sentinels for any unavoidable per-site exception?
- Is `exhaustive-consume-edge` argued by structural funnel, including CPU
  readback, GPU bind-for-sample/read, copy-source, and lifecycle?
- Do sentinels reproduce failure first and include BAR-only producers: blit,
  mipmap generation, copyImageSubData CPU-shadow read, sparse commit, plus the
  four inventory classes?
- Is `clip_control[_ARB].viewport_bounds` held separate unless the generic flag
  alone closes it?
- Is the pressure-net explicitly out of scope and byte-identical?
