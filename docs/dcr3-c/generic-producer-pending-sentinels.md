# DCR3-C Generic Producer Pending Sentinels

Focused phase: `./build-release-fp64on/appgl_gauntlet_cli dcr3c-sentinels`

Last local run: passed, eight tests.

## Existing Sentinels

- `dcr3c.fbo-pressure-readback`: reduced command-buffer bound, chained
  object-backed FBO draws, texture uploads, and final FBO readback.
- `dcr3c.sustained-soak-bar`: longer BAR-shaped FBO accumulation and one
  default-framebuffer presentation.
- `dcr3c.msaa-resolve-readback-sync`: MSAA FBO draw, blit resolve, and resolved
  readback without per-draw waits.
- `dcr3c.msaa-shader-resolve-readback-sync`: MSAA texture producer consumed by
  sampler2DMS shader resolve, then read back.

## New Inventory Sentinels

- `dcr3c.producer-inventory-bits`
  - FBO texture write sets `kProducerFboColorWrite`; sampler consumer drains it.
  - FBO readback drains destination FBO producer bits.
  - `glClearBufferfv` sets `kProducerClearWrite`; readback drains it.
  - Compute image write sets `kProducerComputeWrite |
    kProducerStorageImageWrite`; `glGetTextureImage` drains it.
  - Compute SSBO write sets `kProducerComputeWrite |
    kProducerShaderStorageWrite`; `glGetBufferSubData` drains it.
  - Compute atomic write sets `kProducerComputeWrite |
    kProducerAtomicCounterWrite`; `glGetBufferSubData` drains it.

This covers the four non-clip inventory classes: compute output, SSBO/atomic,
storage image, and texture-read handoff. Clip-control metadata remains isolated
and was not changed.

## New BAR-Only Sentinels

- `dcr3c.bar-blit-copy-mipmap`
  - FBO source draw sets `kProducerFboColorWrite`.
  - `glBlitFramebuffer` drains source and marks destination
    `kProducerCopyWrite`.
  - Destination readback drains copy bits.
  - `glGenerateMipmap` drains base-level producer bits and marks
    `kProducerMipmapWrite`; mip-level `glGetTextureImage` drains it.

- `dcr3c.bar-copyimage-sparse-lifecycle`
  - `glCopyImageSubData` drains a pending source texture before the CPU-shadow
    read path and marks the destination `kProducerCopyWrite`.
  - Sparse `glBufferPageCommitmentARB` marks `kProducerSparseResidency`;
    `glGetBufferSubData` drains it.
  - Deleting a texture with pending FBO producer bits verifies the lifecycle
    release path drains via `FlushForReadback`.

- `dcr3c.buffer-as-different-role`
  - Compute writes a buffer as SSBO, setting `kProducerComputeWrite |
    kProducerShaderStorageWrite`.
  - The same buffer is rebound as `GL_TEXTURE_BUFFER` and sampled by a fragment
    shader.
  - Sampler binding resolution drains the buffer through the texture-buffer
    source read path.

## Run Result

The focused run returned:

```text
"phase":"dcr3c-sentinels","passed":true
dcr3c.fbo-pressure-readback: passed
dcr3c.sustained-soak-bar: passed
dcr3c.msaa-resolve-readback-sync: passed
dcr3c.msaa-shader-resolve-readback-sync: passed
dcr3c.producer-inventory-bits: passed
dcr3c.bar-blit-copy-mipmap: passed
dcr3c.bar-copyimage-sparse-lifecycle: passed
dcr3c.buffer-as-different-role: passed
```

## Red-First Evidence

Broken-build method: temporarily stub the four `drainPendingGpuProducers`
overloads in `GLContext.mm` to return before flushing or clearing. Producer
marks still run, so failures occur at the consume/drain edge rather than at the
mark edge.

New sentinel red signals from that drain-disabled build:

```text
dcr3c.producer-inventory-bits:
  sampler consumer drain retained pending bits mask=0x1 actual=0x1

dcr3c.bar-blit-copy-mipmap:
  blit source drain retained pending bits mask=0x1 actual=0x1

dcr3c.bar-copyimage-sparse-lifecycle:
  copyImage CPU-shadow source drain retained pending bits mask=0x1 actual=0x1

dcr3c.buffer-as-different-role:
  texture-buffer consumer drain retained pending bits mask=0x108 actual=0x108
```

All four new sentinels go red when the generic consume funnel is disabled and
green with the fixed funnel restored.
