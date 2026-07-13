# C2d Enumerated Shadow Matrix Design

Status: M1-M3/M5/M4 accepted; consolidated freeze verification in progress
Thread: `legacy-piglit`  
Required implementation base: `f00b14557ddef9b367c55f45a61151618d8b9027`  
Prepared: 2026-07-12  

Accepted implementation stack: M1 `3728f2d`, M2 `60c6f5f`, M3 `c3197fa`, M5 `7eb6217`, and M4
`84bae63`. Each mechanism remains a separate commit on required base `f00b145`.

## 1. Decision

The first admissible C2d candidate is a combined, bisectable stack containing all three mandatory
mechanisms:

1. A raw-depth compare binding path that preserves the GL-visible mip and layer range, including
   `textureQueryLevels` behavior.
2. Narrow frontend activation of the core legacy `shadow1D` and `shadow2D` overloads even when the
   shader does not name `GL_EXT_gpu_shader4`.
3. Cube and cube-array compare-coordinate clamping only while
   `GL_TEXTURE_CUBE_MAP_SEAMLESS` is disabled.

Client-attribute packing entered the accepted stack only after the original two cube-shadow rows
failed while VBO-backed clones of the same rows passed. That differential proved the remaining
defect was client-array transport rather than compare binding, frontend lowering, cube filtering,
or test content. M4 keeps the repair isolated to compatibility `GL_QUADS` draws whose every
reflected active input is an enabled, divisor-zero legacy client-memory stream.

The eight-row recovery contract is exact. Other changes are collateral predictions, not reasons to
accept a candidate.

### 1.1 M5 implementation record

M5 owns E12, E15, and every explicit-LOD `sampler1DShadow` cell. Apple Metal exposed two independent
failures while reducing those cells:

1. `depth2d.sample_compare` with explicit LOD is unreliable when the promoted 1D depth resource has
   physical height one. A height-one candidate failed; a height-two copy of the same data passed.
   Negative controls preserved the failure, so padding is load-bearing rather than incidental.
2. Apple Metal miscompiles non-uniform resource selection for depth-compare resources. More than 80
   variants were exercised across argument buffers, direct bindings, switches, branchless selects,
   fixed readers, array slices, `sample_compare`, and raw depth reads. Pipeline creation succeeded,
   but dynamic selection did not produce reliable data.

The accepted fallback uses one fixed resource rather than selecting a resource or array slice:

- The depth atlas has base-mip width and height `2 * logicalMipCount`. Logical mip `i` occupies rows
  `2*i` and `2*i+1`; both rows contain the same depth data. The height-two band remains mandatory.
- A same-shape `R32Float` or `R16Unorm` scalar mirror is populated from a synchronized staging copy.
  Shader reads and manual comparison use this color-format mirror, while the height-two depth atlas
  remains the authoritative padding/control artifact. Both atlases are refreshed from the same
  synchronized source snapshot.
- Logical mip selection is an ordinary Y coordinate on the fixed scalar texture. X addressing
  applies effective repeat, mirrored-repeat, clamp-to-edge, or clamp-to-border state. Linear
  filtering compares each tap before interpolation, and mip interpolation blends compare results.
- The translator recognizes only SPIRV-Cross's promoted-1D coordinate shape, `float2(x, 0.5)`.
  Native 2D shadow calls retain the existing compare-coordinate control and do not declare or bind
  the 1D sidecar.

The final E15 blocker was upstream of M5 sampling. The fragment-only compatibility linker forced
all shadow inputs to `vec2`; generated MSL therefore reconstructed `appgl_TexCoord[0].z` as zero.
Piglit's Less half passed accidentally with `-0.05`, while its Greater half failed with `+0.05`.
Restricting the synthesized-width repair to `sampler1DShadow` preserves the compare reference and
moved E15 from `-1/100` to `153/153 PASS`. E12 is also `153/153 PASS`.

The exact E15 contract is the `-nobias` row and remains `153/153 PASS`. A broader diagnostic run of
`textureLodOffset 1DShadow` with Piglit's bias-expanded state matrix is `679/780 PASS`. Those 101
bias-expanded failures are `KP-E15-BIAS`: a known-partial future matrix cell, outside the exact
eight-row contract and hold set, and not evidence against the accepted explicit-LOD mechanism.

The permanent focused probe assigns edge variants inside the existing 1D explicit-LOD cells:

- clamp-to-edge at the low and high endpoint;
- repeat and mirrored-repeat with negative and over-one coordinates;
- a linear footprint straddling two distinct compare outcomes;
- a linear footprint at the last logical texel of every mip, with hostile values in adjacent atlas
  bands, to detect cross-band bleed.

These are data variants within the 256-cell executable, so the ownership and gate totals remain
221 focused-owned cells and approximately 346 targeted invocations per flavor.

### 1.2 Accepted discriminator and M4 record

Before M4, corrected VBO clones for E850 and E3656 passed while both original client-array programs
failed. M4 `84bae63` packs a draw-local interleaved record only for the proven compatibility-quad
shape. It preserves each input's GL type, component count, normalization, and integer flag. Mixed
VBO/client, separated-format, divisor, transform-feedback, fp64, unsupported packed-format, native
topology, and `gl_VertexID`/base-sensitive draws retain the prior path.

After M4, the untouched E850 and E3656 client-array programs pass. The two historical landmines,
`spec@arb_draw_buffers@fbo-mrt-new-bind` and
`spec@ext_transform_feedback@tessellation triangle_strip flat_last`, also pass on the same binary.
The corrected-VBO clone executables did not survive the later host reboot; the recorded pre-M4
clone-pass/original-fail differential is the source of record, while the consolidated freeze reruns
the untouched originals and both landmines.

## 2. Source Findings

### 2.1 Compare binding

`resolveSamplerBindings` currently records `effectiveTextureSampleMipRange`, then binds
`resolveSwizzledTexture`. That resolver can return a legacy-swizzled view, a depth/stencil proxy, a
sampling proxy for an ARB texture view, or a base/max-level view. A Metal `sample_compare` receiver
must instead see a depth-format texture without color swizzle/proxy semantics.

The retired C2d commit `180cabd99188e6d805e6e8761fdbe2ab787567bb` proved that binding
`GLTextureObject::metalTexture` restores the two cube-shadow rows, but it bypassed the base/max mip
view. The follow-up `9e3bd2fb66c84d53b161cd510d9746fba407b98f` special-cased shaders that
use `textureQueryLevels`; that restored the six CTS query-level cases but made compare lookup and
query lookup observe different Metal texture objects. The new design removes that split.

### 2.2 Frontend lowering

`kGpuShader4ShadowWrappers` already contains vec4-returning wrappers for the legacy shadow family.
Emission is currently guarded by `hasGpuShader4Directive`, which is true only when the original
source contains `GL_EXT_gpu_shader4`. The four GLSL 1.20 expected rows use the core legacy
`shadow1D`/`shadow2D` names without that extension token, so they fail before compare sampling.

Only the core legacy pair is ungated. Array, explicit-LOD, gradient, and offset names introduced by
`GL_EXT_gpu_shader4` remain extension-scoped. This avoids silently advertising the whole extension.
The existing extension-only offset wrappers also drop their `offset` argument when calling the core
intrinsic. They are therefore compile/semantic hold targets and must not be broadened as part of the
four-row frontend repair.

### 2.3 Cube clamping

`injectDepthCompareFlip` currently handles `depth2d` and `depth2d_array` receivers only. The retired
C2d change added `depthcube` and `depthcube_array`, then clamped the two minor direction components
to the selected face interior when seamless cube sampling was disabled. This is the correct scope,
but the new implementation must use an explicit compare-coordinate flag rather than overloading a
field named `compareFlipY` with two meanings.

Cube clamp behavior must be proven for implicit, gradient, and explicit-LOD lookups. A clamp based
only on level-zero width is not accepted for lower mip levels. If generated MSL exposes an explicit
level, the helper uses that level's width. Implicit/gradient forms must use an LOD-correct inset or
fail the focused matrix; they may not silently fall back to a level-zero approximation.

### 2.4 Client-array discriminator

The two surrendered Piglit programs both use client-memory attributes and `GL_QUADS`:

- `tests/texturing/sampler-cube-shadow.c`: two vec4 attributes.
- `tests/spec/arb_texture_cube_map_array/sampler-cube-array-shadow.c`: two vec4 attributes plus a
  float compare reference.

That correlation is not causation. The retired C2d composite added broad reflected-attribute
packing and simultaneously exposed the MRT and transform-feedback landmines. The VBO clone
differential is mandatory before any packing code returns.

## 3. Matrix Axes

### 3.1 Sampler dimensions

| Code | GLSL sampler |
| --- | --- |
| D1 | `sampler1DShadow` |
| D2 | `sampler2DShadow` |
| DC | `samplerCubeShadow` |
| D1A | `sampler1DArrayShadow` |
| D2A | `sampler2DArrayShadow` |
| DCA | `samplerCubeArrayShadow` |

Rectangle and multisample samplers are outside C2d. Rectangle has no mip chain, and multisample
samplers do not use filtered shadow lookup overloads.

### 3.2 Compare-view classes

| Code | Storage/view setup | Required observation |
| --- | --- | --- |
| V0 | Uploaded direct depth texture, base 0, full chain | Raw depth compare and full level count |
| V1 | Direct texture with nonzero `BASE_LEVEL` and capped `MAX_LEVEL` | Compare and query see the same clipped chain |
| V2 | Immutable root plus `glTextureView` with nonzero min level and layer subset; local base/max also varied | Target, source level range, and source layer range are preserved |
| V3 | Depth content produced through an FBO, then compare-sampled | V0/V1/V2 rules plus correct producer orientation |

For DC and DCA, each view class has two state instances:

- S0: seamless disabled, face-local clamp required.
- S1: seamless enabled, no AppGL clamp permitted.

The non-cube classes have only S0. The operation/dimension table has 56 legal cells. Four view
classes produce 224 cells, and the second seamless state adds 32 cube-family instances, for 256
focused runtime cells.

### 3.3 Operation forms

`O` and `B` are explicit axes. `B` means a shader-call bias overload and is fragment-only. Every
legal cell also runs sampler/texture LOD-bias state at 0, +1, and -1 inside the probe so call bias
and sampler state cannot be conflated.

| Code | GLSL form | Family | Offset | Call bias | Legal dimensions |
| --- | --- | --- | --- | --- | --- |
| T | `texture` / legacy plain shadow | implicit | no | no | D1,D2,DC,D1A,D2A,DCA |
| TB | `texture(..., bias)` / legacy bias shadow | implicit | no | yes | D1,D2,DC,D1A,D2A,DCA |
| TO | `textureOffset` | implicit | yes | no | D1,D2,D1A,D2A |
| TOB | `textureOffset(..., bias)` | implicit | yes | yes | D1,D2,D1A,D2A |
| G | `textureGrad` | grad | no | no | D1,D2,DC,D1A,D2A,DCA |
| GO | `textureGradOffset` | grad | yes | no | D1,D2,D1A,D2A |
| L | `textureLod` | lod | no | no | D1,D2,DC,D1A,D2A,DCA |
| LO | `textureLodOffset` | lod | yes | no | D1,D2,D1A,D2A |
| P | `textureProj` | proj implicit | no | no | D1,D2 |
| PB | `textureProj(..., bias)` | proj implicit | no | yes | D1,D2 |
| PO | `textureProjOffset` | proj implicit | yes | no | D1,D2 |
| POB | `textureProjOffset(..., bias)` | proj implicit | yes | yes | D1,D2 |
| PG | `textureProjGrad` | proj grad | no | no | D1,D2 |
| PGO | `textureProjGradOffset` | proj grad | yes | no | D1,D2 |
| PL | `textureProjLod` | proj lod | no | no | D1,D2 |
| PLO | `textureProjLodOffset` | proj lod | yes | no | D1,D2 |

All other form/dimension products are specification-invalid and are `N/A`, not uncovered.

## 4. Existing Coverage Map

### 4.1 Coverage tokens

Expected Piglit tokens:

| Token | Exact row |
| --- | --- |
| E4 | T2 row 4, `GL2:texture() 1DShadow` |
| E6 | T2 row 6, `GL2:texture() 2DShadow` |
| E7 | T2 row 7, `GL2:texture(bias) 1DShadow` |
| E8 | T2 row 8, `GL2:texture(bias) 2DShadow` |
| E12 | T2 row 12, `textureGradOffset 1DShadow` |
| E15 | T2 row 15, `textureLodOffset 1DShadow` |
| E850 | Full-suite row 850, `texturing@sampler-cube-shadow` |
| E3656 | Full-suite row 3656, `arb_texture_cube_map_array-sampler-cube-array-shadow` |
| KP-E15-BIAS | Bias-expanded `textureLodOffset 1DShadow`; known partial `679/780` |

Passing Piglit hold tokens:

| Token | Exact row |
| --- | --- |
| H-GO2 | `textureGradOffset 2DShadow` |
| H-LO2 | `textureLodOffset 2DShadow` |
| H-PO1 | `textureProjOffset 1DShadow` |
| H-PO2 | `textureProjOffset 2DShadow` |
| H-POB1 | `textureProjOffset(bias) 1DShadow` |
| H-POB2 | `textureProjOffset(bias) 2DShadow` |

Positive CTS tokens are from `KHR-GL46.ext_texture_shadow_lod`:

| Token | CTS cases |
| --- | --- |
| C-T-D2A | `texture.sampler2darrayshadow_{vertex,fragment}` |
| C-TB-D2A | `texture.sampler2darrayshadow_bias_fragment` |
| C-T-DCA | `texture.samplercubearrayshadow_{vertex,fragment}` |
| C-TB-DCA | `texture.samplercubearrayshadow_bias_fragment` |
| C-TO-D2A | `textureoffset.sampler2darrayshadow_{vertex,fragment}` |
| C-TOB-D2A | `textureoffset.sampler2darrayshadow_bias_fragment` |
| C-L-D2A | `texturelod.sampler2darrayshadow_{vertex,fragment}` |
| C-L-DC | `texturelod.samplercubeshadow_{vertex,fragment}` |
| C-L-DCA | `texturelod.samplercubearrayshadow_fragment` |
| C-LO-D2A | `texturelodoffset.sampler2darrayshadow_{vertex,fragment}` |

`F-<view>-<op>-<dim>-<state>` means the planned table-driven focused probe owns the cell. `N/A`
means the GLSL overload is invalid.

### 4.2 V0 matrix

| Op | D1 | D2 | DC | D1A | D2A | DCA |
| --- | --- | --- | --- | --- | --- | --- |
| T | E4 | E6 | E850 | F | C-T-D2A | E3656 + C-T-DCA |
| TB | E7 | E8 | F | F | C-TB-D2A | C-TB-DCA |
| TO | F | F | N/A | F | C-TO-D2A | N/A |
| TOB | F | F | N/A | F | C-TOB-D2A | N/A |
| G | F | F | F | F | F | F |
| GO | E12 | H-GO2 | N/A | F | F | N/A |
| L | F | F | C-L-DC | F | C-L-D2A | C-L-DCA |
| LO | E15 + KP-E15-BIAS | H-LO2 | N/A | F | C-LO-D2A | N/A |
| P | F | F | N/A | N/A | N/A | N/A |
| PB | F | F | N/A | N/A | N/A | N/A |
| PO | H-PO1 | H-PO2 | N/A | N/A | N/A | N/A |
| POB | H-POB1 | H-POB2 | N/A | N/A | N/A | N/A |
| PG | F | F | N/A | N/A | N/A | N/A |
| PGO | F | F | N/A | N/A | N/A | N/A |
| PL | F | F | N/A | N/A | N/A | N/A |
| PLO | F | F | N/A | N/A | N/A | N/A |

The 33 V0 cells uncovered by existing Piglit/CTS compare-result evidence are:

- T: D1A.
- TB: DC, D1A.
- TO: D1, D2, D1A.
- TOB: D1, D2, D1A.
- G: D1, D2, DC, D1A, D2A, DCA.
- GO: D1A, D2A.
- L: D1, D2, D1A.
- LO: D1A.
- P: D1, D2.
- PB: D1, D2.
- PG, PGO, PL, PLO: D1 and D2 for each form.

### 4.3 V1 matrix

Existing Piglit miplevel-selection evidence varies direct-texture base/max state for exactly these 12
cells:

`T/D1`, `T/D2`, `TB/D1`, `TB/D2`, `GO/D1`, `GO/D2`, `LO/D1`, `LO/D2`,
`PO/D1`, `PO/D2`, `POB/D1`, and `POB/D2`.

Every other legal V1 cell maps to the focused probe. The 44 uncovered V1 cells are:

- T and TB: DC, D1A, D2A, DCA for each form.
- TO and TOB: D1, D2, D1A, D2A for each form.
- G: all six dimensions.
- GO: D1A, D2A.
- L: all six dimensions.
- LO: D1A, D2A.
- P and PB: D1 and D2 for each form.
- PG, PGO, PL, PLO: D1 and D2 for each form.

The six `KHR-GL46.texture_query_levels.*Shadow_test` cases are metadata holds for V1; they do not
replace a compare-result cell.

### 4.4 V2 and V3 matrices

No existing Piglit or CTS row in the accepted evidence simultaneously proves a shadow compare result
through an ARB texture view. Therefore all 56 legal V2 cells are explicitly uncovered and map to
`F-V2-*`.

No existing accepted row proves every operation form against FBO-produced depth content. Therefore
all 56 legal V3 cells are explicitly uncovered and map to `F-V3-*`. Existing 2D compare-flip code is
a mechanism anchor, not matrix coverage.

### 4.5 Seamless-state expansion

The legal cube-family forms are T, TB, G, and L for DC and DCA. Across V0-V3 this is 32 base cells.
Existing shadow tests do not explicitly toggle seamless state. Their default-disabled executions own
only S0 where otherwise listed above. All 32 S1 instances are explicitly uncovered and map to the
focused probe. The color-only Piglit row
`arb_seamless_cubemap-three-faces-average` is a mandatory hold, not a shadow-compare cell.

Summary:

| Class | Cells | Existing compare evidence | Uncovered and assigned to focused probe |
| --- | ---: | ---: | ---: |
| V0 | 56 | 23 | 33 |
| V1 | 56 | 12 | 44 |
| V2 | 56 | 0 | 56 |
| V3 | 56 | 0 | 56 |
| S1 cube expansion | 32 | 0 | 32 |
| Total | 256 | 35 | 221 |

The focused probe still executes all 256 cells so the 35 suite-covered cells have a deterministic,
single-purpose twin.

## 5. Focused Probe Contract

The permanent probe uses Piglit's table-driven `tex-miplevel-selection` engine extended through
Piglit commit `7828d1ef2` (`tests/texturing/tex-miplevel-selection.c`). Runtime-repo assets
`tools/c2d_shadow_matrix.py` and `tools/c2d_shadow_matrix_manifest.json` generate and validate the
exact cell inventory. The runner refuses a manifest that differs from its source-of-truth table.

The manifest contains 64 cells for each of V0, V1, V2, and V3: 56 legal operation/dimension cells
at S0 plus the eight legal cube-family S1 expansions. The total is exactly 256. Each logical cell
has one isolated runner record. V3 records aggregate lower-left and upper-left clip-origin probe
variants, both of which must produce terminal results. The four `V*-LO-D1-S0` cells are explicitly
`EXPECTED_PARTIAL`; they still execute and must report a non-vacuous mix of passing and failing
variants. Every other cell initially requires `PASS`.

Build the probe engine with:

```sh
cmake --build /Users/excalibur/Documents/Developer/OpenGL\ 4.6\ Mac/specs/piglit/build \
  --target tex-miplevel-selection -j8
```

Run a flavor with:

```sh
python3 tools/c2d_shadow_matrix.py \
  --manifest tools/c2d_shadow_matrix_manifest.json \
  --binary /Users/excalibur/Documents/Developer/OpenGL\ 4.6\ Mac/specs/piglit/build/bin/tex-miplevel-selection \
  --library /absolute/path/to/frozen/libAppGL.dylib \
  --bridge /Users/excalibur/Documents/Developer/OpenGL\ 4.6\ Mac/live-targets/appgl-bridge/libappgl_bridge.dylib \
  --out /new/output/directory --flavor default
```

Each probe process emits the cell ID, view/seamless/origin state, expected and queried immutable
storage-level and view-level counts, per-variant pass total, and terminal Piglit result. This follows
`ARB_texture_view`: `GL_TEXTURE_IMMUTABLE_LEVELS` is inherited from the source texture, while
`GL_TEXTURE_VIEW_NUM_LEVELS` reports the view's visible subset. The runner rejects timeout, signal,
skip, missing terminal result, missing cell/probe record, either query-count mismatch, empty
execution, or an outcome that differs from the cell's declared `PASS`/`EXPECTED_PARTIAL` class.
Its result schema keeps capability `skip` and malformed-result `error` separate from `unsafe`;
`unsafe` is reserved for timeout or signal termination so the safety-zero claim remains literal.

Deterministic data rules:

1. Allocate at least four depth mip levels with distinct compare outcomes per level.
2. Use alternating neighboring depth texels for offset forms so dropping the offset necessarily
   changes the result.
3. Use non-unit projection q values for projective forms.
4. Give array layers and cube faces distinct patterns so a wrong layer or face cannot pass.
5. V1 uses base 1 and max 2. V2 uses a root with at least five levels, a nonzero view min level, and
   a nonzero layer subset, then varies local base/max.
6. V3 populates the same patterns through framebuffer writes and tests both LOWER_LEFT and
   UPPER_LEFT clip origins where supported.
7. Cube S0/S1 samples within the filter footprint of a face edge with conflicting adjacent-face
   compare outcomes.
8. Each legal form runs texture/sampler LOD-bias state 0, +1, and -1. Explicit call-bias forms also
   use a nonzero call bias.
9. The probe queries immutable-storage and view-span metadata from the exact texture object bound for
   compare; the separate six-case CTS hold verifies shader-side `textureQueryLevels` coherence.
10. The probe rejects compile failure, warning-only fallback, timeout, signal, missing result, and
    resource backstop as non-pass.

The first baseline-attribution run also includes a standalone Objective-C/OpenGL attachment repro in
the gate artifact. It creates 1D-array, 2D-array, and cube-array depth stores without Piglit and
attaches mip level 2, layer 9. This distinguishes a probe setup defect from a runtime FBO capability
gap before matrix skips are classified.

The primary matrix uses VBO attributes. Two extra clones reproduce E850 and E3656 with VBOs while
the original Piglit rows retain their client arrays. This is the client-packing discriminator.

## 6. Mechanism Design

### M1. Raw depth compare view with coherent mip/query semantics

Add a dedicated `resolveDepthCompareTexture` path and a separately owned cached
`metalDepthCompareView` on `GLTextureObject`.

1. Materialize an ARB texture view first. Its `metalTexture` already encodes source min level,
   target type, and source slice subset.
2. Start from that raw depth-format Metal texture. Do not call `resolveSwizzledTexture`, do not use
   `metalSamplingProxy`, and do not apply color/legacy swizzles.
3. Derive a plain, non-swizzled Metal view for the GL-visible `BASE_LEVEL..MAX_LEVEL` range. Share a
   range helper with the ordinary sampling-view path so compare sampling and query lowering cannot
   drift. Do not collapse the view to one level merely because the min filter is non-mipmapped.
4. Preserve the materialized texture's Metal type and complete slice range. For V2, base/max values
   are local to the GL texture view.
5. If the visible range is the complete materialized range, return `metalTexture` directly.
6. Cache only the ranged view. Key it by raw Metal texture identity, texture type, pixel format,
   first level, level count, first slice, and slice count.
7. Release/invalidate it on storage replacement, ARB view rematerialization, base/max change,
   texture deletion, R5 eviction, and any path that replaces `metalTexture`. Include it in residency
   inventory and rebuild accounting.
8. Use this path whenever effective sampler state selects `COMPARE_REF_TO_TEXTURE` and the GL
   internal format has a depth component, including sampler-object compare state.
9. Remove the `stageUsesTextureQueryLevels` exception. The compare view itself must expose the
   correct `get_num_mip_levels()` result.

Estimated runtime-source size: 140-220 added/changed lines across `GLObjectStore.h`, `GLContext.mm`,
and residency/invalidation bookkeeping.

### M2. Core legacy shadow overload activation

Refactor wrapper selection so each entry has an activation class.

1. Mark only `shadow1D` and `shadow2D` as core-legacy entries.
2. Detect their actual code call sites regardless of the gpu_shader4 directive, then rename the call
   and inject only the required wrapper.
3. Keep vec4 replication. Keep fragment-only bias overloads fragment-only. Keep the existing
   explicit LOD-zero lowering for non-fragment implicit legacy lookups.
4. Leave array, offset, gradient, explicit-LOD, and other gpu_shader4-only entries behind the
   extension gate.
5. Do not rewrite declarations, macros, comments, or similarly prefixed identifiers.
6. Gate the four exact GLSL 1.20 rows plus negative lookup-function compile tests before combining
   with M1.

Estimated runtime-source size: 25-60 lines in `CompatShaderRewrite.cpp`, plus 80-120 lines of
frontend-focused tests.

### M3. Seamless-aware cube compare clamping

Replace the ambiguous scalar control with explicit per-texture-slot compare-coordinate flags:

- bit 0: flip 2D compare Y for FBO-produced LOWER_LEFT content.
- bit 1: clamp cube compare direction to the selected face interior.

Set bit 1 only for depth cube/cube-array compare bindings while
`GL_TEXTURE_CUBE_MAP_SEAMLESS` is disabled. Extend translator receiver discovery and helper-parameter
threading to `depthcube` and `depthcube_array`. Wrap both `sample_compare` and `gather_compare` call
sites. Preserve anchor-failure fallback and diagnostics.

The clamp keeps the major component unchanged and clamps only the two minor components. Its inset
must correspond to the actual lookup mip. S1 leaves the coordinate byte-for-byte unchanged. V3 cube
orientation is not guessed; any additional face transform requires focused-probe evidence and a
separate adjudication.

Estimated runtime-source size: 90-150 lines across `ShaderTranslator.cpp`, `GLContext.mm`,
`MetalFrameGraph.h`, and `MetalFrameGraph.mm`.

### M4. Conditional client-attribute packing

Do not implement unless both VBO clones pass and their original client-array rows fail after M1-M3.
If proven, add a draw-local pack only when topology emulation needs a contiguous record and every
reflected active input is an enabled, non-instanced client-memory stream. Build layout from vertex
reflection, preserve declared GL type/size/normalization, and leave VAO state untouched. Mixed
VBO/client, transform-feedback, native topology, divisor, and unsupported packed-type cases retain
the existing path.

Run the two historical landmines immediately after this commit. A failure rejects M4 even if E850
and E3656 recover.

Estimated runtime-source size if proven: 60-120 lines. Estimated size when not proven: zero.

### Aggregate size

Mandatory runtime stack M1-M3: approximately 255-430 added/changed lines. Focused/frontend test
work: approximately 450-700 lines. Conditional M4 adds 60-120 runtime lines only on differential
proof.

## 7. Exact Expected Set

| Row | Exact test | Current class | Required mechanism | Expected candidate result |
| ---: | --- | --- | --- | --- |
| 4 | `spec@glsl-1.20@execution@tex-miplevel-selection gl2:texture() 1dshadow` | frontend compile | M2 + M1 | pass |
| 6 | `spec@glsl-1.20@execution@tex-miplevel-selection gl2:texture() 2dshadow` | frontend compile | M2 + M1 | pass |
| 7 | `spec@glsl-1.20@execution@tex-miplevel-selection gl2:texture(bias) 1dshadow` | frontend compile | M2 + M1 | pass |
| 8 | `spec@glsl-1.20@execution@tex-miplevel-selection gl2:texture(bias) 2dshadow` | frontend compile | M2 + M1 | pass |
| 12 | `spec@glsl-1.30@execution@tex-miplevel-selection texturegradoffset 1dshadow` | compare result | M1 | pass |
| 15 | `spec@glsl-1.30@execution@tex-miplevel-selection texturelodoffset 1dshadow` | compare result | M1 | pass |
| 850 | `texturing@sampler-cube-shadow` | cube compare; client-correlated | M1 + M3, M4 only if proven | pass |
| 3656 | `spec@arb_texture_cube_map_array@arb_texture_cube_map_array-sampler-cube-array-shadow` | cube-array compare; client-correlated | M1 + M3, M4 only if proven | pass |

### Predicted collateral by class

- Likely positive: direct 1D/2D shadow comparisons that currently reach valid `sample_compare` MSL
  through a color-swizzled or proxy view.
- Likely positive: depth compare through clipped base/max ranges and ARB texture views, where the
  underlying Metal depth storage is otherwise valid.
- Likely positive: nonseamless cube/cube-array compare lookups near a face edge.
- Compile-only positive: core legacy `shadow1D`/`shadow2D` plain and fragment-bias calls without an
  EXT directive.
- Must remain unchanged: color sampling, non-compare depth sampling, seamless-enabled cube sampling,
  texture gather results, sampler completeness, and gpu_shader4-only wrapper availability.
- Not claimed: old full-suite timeout/RSS-backstop rows. They require fresh isolated execution before
  any status change is attributed to C2d.

## 8. Hold Set

Every hold executes in default and f64on flavors with exact artifact identity.

Mandatory Piglit manifests:

1. K4b/K4c restored shadow-offset six:
   `gate-artifacts/r0.7-t2c-freeze-20260712T172423Z/shadow-offset-6.rows.tsv`.
2. K4c crown nine:
   `gate-artifacts/r0.7-t2c-freeze-20260712T172423Z/crown-defining-9.rows.tsv`.
3. T2 ladder 17, exactly the T2-A five plus T2-B twelve:
   `gate-artifacts/r0.7-t2a-freeze-20260712T080341Z/t2a-target-5.rows.tsv` and
   `gate-artifacts/r0.7-t2b-freeze-20260712T135550Z/t2b-target-12.rows.tsv`.
4. Prior recoveries 38:
   `gate-artifacts/r0.7-t2c-freeze-20260712T172423Z/prior-recoveries-38.rows.tsv`.
5. Historical landmines:
   `gate-artifacts/r0.7-t2c-freeze-20260712T172423Z/landmines-2.rows.tsv`.
6. Cube/color/view holds:
   `gate-artifacts/r0.7-t2c-freeze-20260712T172423Z/cube-client-6.rows.tsv`.

Mandatory CTS mechanism holds:

- All six cases in
  `gate-artifacts/r0.7-k4b-freeze-20260711T211217Z/focused-10.cases` whose names begin
  `KHR-GL46.texture_query_levels`.
- All 16 positive `KHR-GL46.ext_texture_shadow_lod` cases listed in section 4.1.
- Shadow entries from `KHR-GL46.negative_texture_lookup_functions_with_bias_tests`, at minimum
  `textureProjOffset_sampler1DShadow_bias`, `shadow1D_sampler1DShadow_bias`,
  `shadow2D_sampler2DShadow_bias`, `shadow1DProj_sampler1DShadow_bias`, and
  `shadow2DProj_sampler2DShadow_bias`.

The two landmines are specifically:

- `spec@arb_draw_buffers@fbo-mrt-new-bind`.
- `spec@ext_transform_feedback@tessellation triangle_strip flat_last`.

Pass means pass. Skip, timeout, signal, quarantine, missing final result, or RSS/backstop is not an
acceptable hold outcome.

## 9. Staging and Gates

Implementation order after approval:

1. Add the focused probe and VBO discriminator without runtime changes. Record the 256-cell baseline.
2. Commit M1 alone. Run E12/E15, the six query-level CTS cases, V0/V1/V2 focused cells, and the
   existing holds.
3. Commit M2 alone on M1. Run E4/E6/E7/E8 and the five negative frontend cases, then rerun M1 gates.
4. Commit M3 alone on M1+M2. Run E850/E3656, all 64 cube-state focused instances, and cube/color/view
   holds.
5. Run the VBO/client discriminator. Add M4 only on the required differential and immediately run
   both landmines.
6. The first publishable candidate is the combined M1+M2+M3 stack, plus M4 only if proven. Build both
   default and f64on identities from the exact approved SHA.
7. Run the complete targeted gate in both flavors. Only then request approval for the full 7,763-row
   suite in each flavor.

Targeted gate estimate per flavor:

- 256 focused matrix invocations, one process per cell.
- 53 unique existing Piglit hold commands after de-duplicating the six manifests above.
- 6 query-level CTS holds.
- 8 exact expected rows.
- 16 positive EXT shadow-LOD CTS rows.
- 5 negative frontend CTS rows.
- 2 incremental VBO clones; the original client rows are already in the expected eight.
- Total: approximately 346 targeted invocations per flavor, 692 across default and f64on.

The final promotion gate adds 7,763 Piglit rows per flavor. Gate estimates exclude build/provenance
checks and repeat runs requested for nondeterminism.

## 10. Acceptance and Stop Conditions

Accept for full-suite adjudication only if:

1. All eight exact expected rows pass in both flavors.
2. All 256 focused cells pass in both flavors.
3. All query-level cases report the same visible level count used by compare sampling.
4. Every de-duplicated hold row remains pass in both flavors.
5. No wrapper outside the core legacy pair becomes newly available without its required extension.
6. M4 is absent unless the VBO/client differential proves it, and both landmines pass if M4 exists.
7. Candidate dylibs have recorded SHA-256, UUID, source SHA, install name, codesign, and loaded-runtime
   identity.

Stop immediately on any expected-row compile failure, compare/query view disagreement, S1 coordinate
mutation, hold regression, landmine regression, timeout, resource backstop, crash, or artifact
identity mismatch. Do not compensate by widening the frontend gate, bypassing base/max state,
binding a color proxy to a depth receiver, or reintroducing global client-attribute packing.
