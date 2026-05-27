# DCR3-C Generic Producer Pending Audit Aid

Generated from the patched tree after the DCR3-C generic producer pending
implementation. Line numbers are from `src/context/GLContext.mm` after the
sentinel patch.

## Mutation Funnel

Producer bits are physically mutable only through `GLProducerPendingAccess`,
defined in `GLContext.mm`. The `GLProducerPendingState` mutators remain private
in `GLObjectStore.h`; tests only read `producerPending.bits()`.

Current mutation grep:

- `GLProducerPendingAccess::mark`: `GLContext.mm:2971`, inside
  `markGpuResourceWrites`.
- `GLProducerPendingAccess::clear`: `GLContext.mm:2997`, `3012`, `3024`,
  `3036`, inside `drainPendingGpuProducers`.
- `GLProducerPendingAccess::clearAll`: `GLContext.mm:3040`, `3044`, `3049`,
  inside storage release/lifecycle cleanup.

## Mark Call-Sites

`markGpuResourceWrites` / `markFramebufferAttachmentWrite` call-sites:

- `2965`: funnel definition.
- `3085`, `3089`, `3118`: framebuffer attachment helper wrappers.
- `11467`: `clearBoundFramebuffer` marks affected FBO attachments.
- `12512`, `12553`, `12594`: `blitFramebuffer` marks color/depth/stencil
  destination attachments.
- `16504`: `copyBufferSubData` marks destination buffer.
- `18138`, `18180`: `copyTexImage2D` marks destination texture for blit and
  CPU-read paths.
- `19050`, `19091`: sparse texture page commitment marks texture residency.
- `19831`: `generateMipmap` marks mipmap producer.
- `40462`: translated graphics draw marks FBO, storage-image, SSBO, and atomic
  producers after framegraph encode.
- `45339`, `45867`: direct and indirect compute dispatch mark storage-image,
  SSBO, and atomic producers.
- `48368`: `copyImageSubData` marks destination texture/renderbuffer.
- `48957`: sparse buffer page commitment marks buffer residency.
- `49436`, `49463`, `49504`: `clearTexImage` / `clearTexSubImage` mark texture
  clear producers.
- `50377`: `blitReadFBOToTextureSubImage` marks destination texture.
- `52772`, `52787`, `52822`, `52835`, `52850`, `52882`, `52895`, `52922`,
  `52931`: DSA framebuffer clear entry points mark affected attachments.

## Drain Call-Sites

`drainPendingGpuProducers` / `drainFramebufferAttachmentProducer` call-sites:

- `2975`, `3004`, `3015`, `3028`: drain funnel definitions for read sets and
  direct buffer/texture/renderbuffer drains.
- `3065`, `3069`: framebuffer attachment drain helper.
- `3122`, `3148`, `3177`: storage release drains before lifecycle teardown.
- `5978`: `generateMipmaps` drains the source texture before CPU-shadow
  downsample.
- `7840`: sampler/texture-buffer binding resolution drains sampled textures and
  texture-buffer source buffers.
- `8450`, `8512`, `8971`: graphics SSBO/atomic/image read binding resolution
  drains buffer/image read sets.
- `9252`: buffer CPU read helper drains before copying from buffer storage.
- `10796`: native renderbuffer clear materialization drains before CPU-side
  rewrite.
- `11472`, `11901`, `12002`, `12641`: color/depth/stencil/native FBO readback
  drains attachment producers.
- `16700`: `mapBufferRange` drains read mappings.
- `18103`: `copyTexImage2D` depth/stencil source drains before Metal blit.
- `20094`: framebuffer deletion drains live attachment producers.
- `45336`, `45864`: compute dispatch drains read sets before encode.
- `48051`: `copyImageSubData` drains source texture/renderbuffer before
  CPU-shadow read.
- `50341`: `blitReadFBOToTextureSubImage` drains source attachment before blit.
- `51080`: `getTextureImage` drains before CPU texture readback.

## Documented Bypass Exceptions

The remaining open-coded `flushForReadback()` calls are intentionally limited:

- `2990`, `3010`, `3022`, `3034`: the funnel itself. These are not bypasses;
  they are the only generic producer-pending wait sites.
- `15155`: default framebuffer readback. No GL resource object owns the default
  framebuffer image, so `readPixels` keeps the existing
  `encodePendingWork()` + `flushForReadback()` default-FB path.
- `40464`: fp64 graphics SSBO sidecar sync. The sidecar copy is an immediate
  transport/backing synchronization step for fp64 emulation, not a resource
  producer flag transition.
- `44651`: explicit `memoryBarrier` CPU-visible barrier bits. This is a
  no-resource GL barrier path where the application explicitly requests
  CPU-visible completion without naming a concrete object read set.

Raw grep:

```text
2990:            frameGraph->flushForReadback();
3010:            frameGraph->flushForReadback();
3022:            frameGraph->flushForReadback();
3034:            frameGraph->flushForReadback();
15155:        impl_->frameGraph->flushForReadback();
40464:            frameGraph->flushForReadback();
44651:        impl_->frameGraph->flushForReadback();
```
