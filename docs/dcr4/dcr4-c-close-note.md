# DCR4-C Close Note

Status: mesh-GS drawArrays grouping implemented; runtime ordering policy remains the existing CPU completion wait between VS-as-compute and mesh render.

## Implementation Pattern

- Added the `FallbackNsGroup` submission subgroup so DCR4-C can distinguish honest native-mesh unsupported paths from approximate legacy fallback.
- Threaded `fallbackSubgroupKind` through translated draws and tagged mesh-native fallback/NS cases when native mesh was attempted but could not encode.
- Declared native mesh-GS parent groups with `MeshGsPrepassGroup` and `MeshGsRenderGroup`, including the existing private `MeshVsOutputBuffer` transient.
- Added a DCR4-C-only sentinel hook, `APPGL_DCR4C_MESH_GS_ZERO_VSOUT`, that zero-fills the private VS-output buffer in the prepass command buffer before the render pass consumes it.
- Marked successful native mesh-GS producer writes through the generic DCR3 producer funnel after `encodeMetalMeshGSDraw`.

## Native Mesh Producer Audit

Active native-mesh producers:

- Bound draw-FBO attachments: active when native mesh-GS renders to a user FBO. DCR4-C now collects color/depth/stencil attachment writes with the same framebuffer attachment helper used elsewhere and calls `markGpuResourceWrites`. The red/green sentinel failed before this fix with missing pending bits (`expected=0x1 actual=0x0`) and passes after the fix.
- Storage-image texture writes: active when mesh or fragment reflection resolves an image whose access is not read-only. DCR4-C now marks every `writtenImageTextureNames` entry as `kProducerStorageImageWrite`.
- Default framebuffer writes: active only for framebuffer 0 and continue to invalidate the default framebuffer shadow after a successful native draw.

Explicitly excluded or non-producer surfaces:

- SSBO writes and storage-buffer-backed atomic routes are not active in the DCR4-C native mesh path. `MetalMeshGSDrawInfo` has no SSBO/atomic binding vectors and `encodeMetalMeshGSDraw` has no corresponding buffer binding loop. DCR4-C now rejects native mesh when mesh or fragment reflection exposes storage buffers, routing to CPU fallback when available or to honest NS/fallback grouping otherwise.
- The private `vsOutBuf` is not a GL-visible producer. It is an internal transient written by `MeshVertexCompute` and consumed by `MeshDraw`, retained until the current mesh-render wait completes, and declared with `CpuCompletionWait`.
- UBOs, default-uniform bytes, vertex buffers, sampled textures, read-only images, and raster-state snapshots are reads, not producer writes.
- Transform-feedback-active draws remain outside the native mesh path and belong to DCR4-E/F4 CPU/TF grouping.

## Sentinel Results

Artifact/log root: `tests/reports/s22-fantastic-rebuild/DCR4-C-local`.

- `dcr4c.mesh-gs-vsout-dependency`: pass. Normal native mesh draw is green; zeroing the prepass output buffer makes the render result non-green, proving the mesh render consumes the VS-as-compute output.
- `dcr4c.mesh-gs-fbo-producer-readback`: pass. Native mesh-GS FBO draw sets the texture producer bit and readback drains it.
- `build-release` and `build-release-fp64on` both pass `./appgl_gauntlet_cli dcr4c-sentinels`.

## Gate Results

- Build: `cmake --build build-release --target appgl_gauntlet_cli --target AppGL -j8` passed with existing `MTLResourceUsageSample` deprecation warnings and the existing duplicate-library linker warning.
- Build fp64-on: `cmake --build build-release-fp64on --target appgl_gauntlet_cli --target AppGL -j8` passed with the same existing warnings.
- `geometry_shader-full.qpa`: 132 pass, 2 fail, 2 not supported; no changes versus B2 baseline; P->F 0, P->NonPass 0. SHA256 `0a65327c83fd96bf014abae27055a6903efc2f2aa6b87b22f8286cb9fc55c344`.
- `texture_gather-gs-tess-residual.qpa`: 2 pass; one NonPass->P improvement versus B2 baseline (`KHR-GL46.texture_gather.gather-geometry-shader` Fail->Pass); P->F 0, P->NonPass 0. SHA256 `19d61e36371b79f0c12af5dd0d7bdcc0bf491d84313640bde654720a5d4a2c4f`.
- `transform_feedback-full.qpa`: 21 pass; no changes versus B2 baseline; P->F 0, P->NonPass 0. SHA256 `d91937c209b70a4424d82802bf43f95ed8f6ced112e4bb36f8bb84ebb021cf64`.

SCOUT-W was not crowned locally. Per DCR4-C gate-of-record, Foreman owns routing the final artifact to SCOUT-W.
