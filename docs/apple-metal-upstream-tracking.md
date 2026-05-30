# Apple Metal Upstream Tracking — TIME-LIMITED Constraints Inventory

**Document purpose:** track known Apple Metal capability constraints that affect AppGL implementation. Each constraint has a TIME-LIMITED status (per Item 38 LIVE methodology framework) — Apple Metal evolution may unlock native paths, retiring the AppGL emulation layer for that constraint.

**Audience:** AppGL project maintainer (review at each macOS/Xcode/Metal major release).

**Last updated:** 2026-05-30 (Sprint 22 conformance close, HEAD `093a6bd`; S22-close empirical refinement to Constraint 1 — §75-B FIRMLY CONFIRMED specific MS-store endpoint per §2.1.1 below)

**Cross-references:**
- `specs-worker-docs/canonical/CANONICAL-OPERATIONAL-CONTEXT.md` Item 32 LIVE-MAXIMAL (platform-blocked classification) + Item 38 LIVE (TIME-LIMITED vs TIME-PERMANENT classification framework)
- `specs-worker-docs/canonical/EXTENSION-MODULAR-PATTERN.md` (extension architecture for advertising/de-advertising control)
- `appgl-runtime/docs/double-precision.md` (FP64 partial constraint coverage)

---

## §1. Classification frameworks

Two orthogonal classification axes per Item 38 LIVE + Item 64 LIVE Sprint 19 frameworks:

### Time-axis (Item 38 LIVE)

**TIME-LIMITED**: Constraint expected to be resolved via Apple Metal toolchain / compiler / framework evolution. AppGL implementation engages emulation/workaround as **provisional** — retired when Apple Metal upstream evolution provides native path. Examples: MSL compiler bugs, missing attribute support, capability matrix gaps.

**TIME-PERMANENT**: Constraint expected to remain permanent (hardware-locked or design-locked). AppGL implementation either provides emulation (with permanent perf cost) OR accepts NotSupported classification. Examples: hardware ALU absence (FP64), fundamental architectural design constraints.

### Resolution-mechanism axis (Item 64 LIVE)

**HARD**: Hardware-locked constraint; requires emulation OR permanent NS classification. No software-only workaround possible without simulating the missing hardware. Example: FP64 ALU absence on Apple Silicon.

**SOFT**: Toolchain/driver/Metal-capability-matrix-locked constraint; workaroundable via SPIRV-Cross patches OR novel pipeline routing OR runtime workarounds OR await Apple upstream version-advance. Software-only resolution path exists (even if Apple-version-dependent). Example: MSL compiler attribute rejection that may be fixed in future Metal toolchain release.

### Classification interaction

Most constraints map cleanly:
- SOFT + TIME-LIMITED: software workaround + Apple evolution likely (most common Sprint 19 constraints)
- SOFT + TIME-PERMANENT: software workaround required permanently (rare; Apple design choice unlikely to change)
- HARD + TIME-PERMANENT: hardware-locked + permanent (FP64 on Apple Silicon)
- HARD + TIME-LIMITED: hypothetical hardware addition (rare; Apple Silicon roadmap dependent)

Default Sprint 19+ inventory:
- 9 of 10 tracked constraints are SOFT + TIME-LIMITED (Apple Metal evolution potential)
- 1 of 10 is HARD + TIME-PERMANENT (FP64; matches Intel iGPU industry posture)

### Reclassification triggers

- New macOS release with Metal version advance
- New Xcode with updated Metal toolchain
- Apple Developer documentation update revealing previously-undocumented native path
- Apple WWDC announcement of capability addition
- Apple Silicon roadmap revealing hardware capability addition (HARD → SOFT/RESOLVED transition; rare)

---

## §1.5. Inventory summary (at-a-glance; refined 2026-05-11 per Item 64 LIVE 3-tier classification)

| # | Constraint | Classification | Resolution path | Sprint status |
|---|---|---|---|---|
| 1 | writable `texture2d_ms` Metal compiler reject | **HARD-TIME-LIMITED** | β2 emulation via sidecar architectural commitment | Sprint 19 Decision I β engaged |
| 2 | `[[primitive_shading_rate]]` MSL attribute UNKNOWN | ✓ **RESOLVED at Xcode 26.2 / SDK 26.2** | Apple toolchain version-advance | **Sprint 20 GOOD tier delivered +960 FSR PASS** (per Item 65 LIVE) |
| 3 | `double` types in MSL buffer storage | **SOFT** | CPU byte-copy fallback (Item 38 LIVE pattern) | Sprint 19 commit 165cb1c |
| 4 | `MTLTextureUsageShaderWrite` for `MTLHeapTypeSparse` | **HARD-TIME-LIMITED** | Joint with #1 emulation | Sprint 19 β2 |
| 5 | `MTLDepthClipModeClip` ignored at hardware | **HARD-TIME-LIMITED** | gl_ClipDistance synthesis emulation candidate | BANKED |
| 6 | RGBA32F graphics storage-image | **HARD-TIME-LIMITED** candidate | Compute-bypass hypothesis (novel pipeline) OR Apple upgrade | Sprint 19 research |
| 7 | Depth16Unorm→R16Unorm view assertion | **SOFT** | Capability-gated containment + cache hygiene | Sprint 19 β2 Phase 7.1 |
| 8 | `MTLHeapTypeSparse` shader writes don't land in tiles | **HARD-TIME-LIMITED** | β2 sidecar architectural commitment | Sprint 19 β2 Phase 7.2 |
| 9 | AGX mipmapLevel OOB on 1D/1D-array clamp Color | **HARD-TIME-LIMITED** | Sprint 20+ novel pipeline candidate | BANKED Sprint 20+ Phase 9.2 |
| 10 | **Apple Silicon native FP64 ALU absence** | **HARD-PERMANENT** | **df64 emulation OR permanent NS** | **Decision F pending Sprint 21+** |

**Inventory totals (Sprint 20 mid-Sprint update)**:
- HARD-PERMANENT: 1 (FP64; hardware-locked Apple Silicon)
- HARD-TIME-LIMITED: 6 (Apple Metal version-locked; requires architectural emulation/novel-pipeline; could resolve via Apple upstream version-advance)
- SOFT: 2 (Constraints 3 + 7; resolvable via runtime fallback OR capability-gating)
- **RESOLVED**: 1 (Constraint #2 primitive_shading_rate per Apple toolchain advance Xcode 26.2 / SDK 26.2; Sprint 20 first empirical TIME-LIMITED → RESOLVED transition; Item 65 LIVE)

**Critical observation**: Only ONE truly hardware-locked permanent constraint (FP64; Apple Silicon design). Seven Apple Metal toolchain/driver constraints are HARD-TIME-LIMITED (require substantial architectural commitment NOW; could resolve via Apple version-advance LATER). Two are SOFT (lighter-touch workarounds suffice). Absolute CTS-46 ceiling at 95.81% (without df64 emulation) is fundamentally driven by the single HARD-PERMANENT constraint.

**HARD vs SOFT threshold judgment**: classification depends on architectural-commitment-scope. β2 sidecar emulation = HARD; CPU byte-copy fallback = SOFT. The gradient is "substantial novel architecture vs lighter-touch resolution".

---

## §2. Active constraints inventory

### Constraint 1: writable `texture2d_ms<float, access::write>` Metal compiler rejection

**Status:** TIME-LIMITED (Sprint 19 active emulation engagement per Decision I β)
**First observed:** Sprint 19 Day 2 (2026-05-11)
**Apple Metal version observed:** Metal 2.4 / Metal 3.2 (macOS 26.x / Xcode 17)

**Technical detail:**
- Metal compiler emits static_assert rejection when MSL attempts `texture2d_ms<float, access::write>` declaration
- Apple Metal capability matrix permits MS textures as render targets and as `access::read_write` for compute (sampled), but NOT as `access::write` for image-store semantics
- GL `ARB_sparse_texture2` (and dependent `ARB_sparse_texture_clamp`) require imageStore semantics on MS textures for full conformance

**CTS impact:**
- `KHR-GL46.sparse_texture2_tests` — 1,204 NS tests
- `KHR-GL46.sparse_texture_clamp_tests` — 575 NS tests (clamp derives from sparse_texture2 fragment shader semantics)
- Combined: ~1,779 NS tests pending emulation

**AppGL approach (Sprint 19 β commitment):**
- Architectural emulation per Decision I β adjudication
- Approach TBD per Sprint 19 engagement (candidate strategies: compute-shader bypass + per-sample dispatch + resolve pattern; or CPU emulation sister to GS path)
- Tracked in `appgl-runtime/src/extensions/sparse_texture2/` and `appgl-runtime/src/extensions/sparse_texture_clamp/` modules

**Monitoring criteria:**
- Check `MTLTextureType2DMultisampleArray` + `MTLTextureUsageShaderWrite` capability advertising in each Metal release notes
- Check `MTLDevice supportsMSTextureSampleWriteAccess` (or equivalent capability flag) in MTLDevice.h
- Test compilation of MSL fragment that uses `texture2d_ms<float, access::write>` against newer Apple toolchains
- Apple Developer documentation reference: `Metal Programming Guide § Multisample Textures`

**Reclassification trigger:**
- If Metal compiler accepts writable MS texture access at some future version → AppGL emulation layer can be deprecated; native path adopted
- Document update: move to "Constraint resolved Sprint N (Metal X.Y)" section + retire emulation per Decision-I-2 (reverse)

### Constraint 1.1 (S22-close empirical refinement): MS-store specific endpoint structurally incomplete — `basic-allTargets-store`

**Status:** §75-B-LATENT-IMPLEMENTATION-GAP FIRMLY CONFIRMED (S22 close 2026-05-30; structural implementation work pending)
**First observed:** Sprint 22 NS-POST Phase 1 + Path X bidirectional-side-effect investigation
**Apple Metal version observed:** Metal 3.2 (macOS 26.x / Xcode 17) — runtime-side gap, not Metal-compiler-side

**Technical detail:**
- `KHR-GL46.shader_image_load_store.basic-allTargets-store` test exercises the MS storage-image *store* path when `GL_MAX_IMAGE_SAMPLES > 0` is advertised (which Sprint 22 step (2) `e0391674` enabled).
- The store branch executes (no Metal compiler reject — the sidecar accepts the path) but the written texel does not land in the GPU texture; the verifier read-back returns the default-cleared state (`First bad color: [1, 0, 0, 0.301961]` / black/cleared signal).
- Distinct from Constraint 1 (which is the COMPILE-TIME `texture2d_ms<float, access::write>` Metal compiler reject) — this is the RUNTIME-PIPELINE endpoint where the sidecar emulation routes the store but the write does not reach the texture for this specific test surface.
- The sidecar architectural commitment from Constraint 1 / Constraint 8 (β2 sidecar) is partial; the `basic-allTargets-store` endpoint specifically requires further implementation work on the storage-image MS-write reach-the-texture path.

**Empirical persistence evidence base** (S22 close — strongest empirical confirmation case in S22):
- 6-commit-lineage attempt axis: 2 direct attempts (Path X full-scope + Path Z surgical) + 4 indirect-coincidental attempts (IE-roots + DSA RGB32 + internalformat + shader_integer_mix) — all preserved `Fail`
- 4-gate-event axis: Path R baseline + MED-tier-completion gate-of-record + Sweep #2.6 PERFECT focused validation + FINAL CROWN #3 — all confirmed `Fail/Fail`

**CTS impact:**
- `KHR-GL46.shader_image_load_store.basic-allTargets-store` — 1 test (currently the only confirmed §75-B-FIRMLY-CONFIRMED instance)
- Adjacent surface verified at full-sweep: `basic-allTargets-load-ms` PASS; non-MS variants of `basic-allTargets-store` PASS — the gap is specific to the MS-store endpoint

**AppGL approach:**
- Deferred to a future implementation pass; not addressable via narrow-fix or shared-code-path narrowing (empirically proven across 6 attempts)
- Tracked in `tests/caselists/ns-post-phase1-deep-inspection-pending.txt` with class-tag `§75-B-LATENT-IMPLEMENTATION-GAP-OUR`
- Resolution requires routing the MS store-image write through a path that reaches the GPU texture end-to-end (likely via the same sidecar lineage as Constraint 1 / 8 but extended to the store-image-write reach axis)

**Monitoring criteria:**
- If a future Apple Metal toolchain advance resolves Constraint 1 (writable `texture2d_ms` accepted natively), this latent endpoint likely resolves with it
- If AppGL completes the sidecar storage-image-write extension internally, this resolves without Apple version-advance

**Reclassification trigger:**
- Constraint 1 resolved via Apple toolchain → both resolve together; remove this entry
- AppGL sidecar storage-image-write extension lands internally → reclassify to RESOLVED with cross-reference to the sprint that closed it

**Cross-references:**
- See [conformance-status.md](conformance-status.md) §75-B description
- See `tests/caselists/ns-post-phase1-deep-inspection-pending.txt` for the canonical pending caselist with class-tag annotations

---

### Constraint 2: `[[primitive_shading_rate]]` MSL attribute UNKNOWN

**Status:** TIME-LIMITED (Sprint 19 GOOD FSR subextension banked pending unlock)
**First observed:** Sprint 19 Day 2 (2026-05-11)
**Apple Metal version observed:** Metal 2.4 / Metal 3.2 (macOS 26.x / Xcode 17)

**Technical detail:**
- SPIRV-Cross MSL backend emits `uint gl_PrimitiveShadingRateEXT [[primitive_shading_rate]]` for vertex-stage SPIR-V with `PrimitiveShadingRate` capability
- Apple Metal toolchain rejects: "unknown attribute 'primitive_shading_rate' ignored under macos-metal2.4 AND metal3.2"
- Cross-domain triangulation Item 22 LIVE divergence event: SPIRV-TW source-read says attribute should exist; AppGL-CW empirical confirms Apple rejection

**CTS impact:**
- `KHR-GL46.fragment_shading_rate_primitive.*` ~600 NS tests (primitive-gated subextension)

**AppGL approach (current):**
- BANKED with substrate; advertising NOT flipped for primitive subextension
- Combiner/attachment subextensions advertising-flippable independently (engaged Sprint 19 GOOD tier)

**Monitoring criteria:**
- Check Apple Metal Feature Set Tables for primitive shading rate support
- Test MSL compilation with `[[primitive_shading_rate]]` against newer Apple toolchains
- Apple Developer documentation reference: `Variable Rate Shading` section in Metal Shading Language guide

**Reclassification trigger:**
- If Metal toolchain accepts `[[primitive_shading_rate]]` → advertising flip becomes safe; +~600 NS recovery

---

### Constraint 3: `double` types in MSL buffer storage

**Status:** TIME-LIMITED (Sprint 19 Day 2 CPU byte-copy fallback emulation landed; commit `165cb1c`)
**First observed:** Sprint 19 Day 2 (2026-05-11; Cluster E SSBO basic-stdLayout case3 422-cluster repair surfaced)
**Apple Metal version observed:** Metal 2.4 / Metal 3.2 (macOS 26.x / Xcode 17)

**Technical detail:**
- MSL doesn't support `double` types in buffer storage qualifiers
- Affects rasterizer-discard + compute dispatch path for SSBO with `double` member types

**CTS impact:**
- `KHR-GL46.shader_storage_buffer_object.basic-stdLayout case3` (14 tests; subset of broader SSBO `double` use)
- Broader FP64 buffer storage tests gated by FP64 + buffer interaction (covered in `double-precision.md`)

**AppGL approach (current):**
- CPU byte-copy fallback per Item 38 LIVE workaround
- VS-rasterizer-discard + compute dispatch path through CPU emulation when SSBO contains `double` members
- Implemented Sprint 19 commit `165cb1c`

**Monitoring criteria:**
- Check Metal Shading Language guide updates for `double` type support in buffer qualifiers
- Test MSL compilation of `struct Foo { double x; }; device Foo *buf;` against newer toolchains

**Reclassification trigger:**
- If MSL accepts `double` in buffer storage → CPU byte-copy fallback can be removed; native path adopted

---

### Constraint 4: `MTLTextureUsageShaderWrite` NOT supported for `MTLHeapTypeSparse`

**Status:** TIME-LIMITED (Sprint 19 sparse_texture2 architectural emulation territory)
**First observed:** Sprint 19 Day 2 (2026-05-11; sparse_texture2 write-side investigation)
**Apple Metal version observed:** Metal 2.4 / Metal 3.2

**Technical detail:**
- `MTLTextureUsageShaderWrite` flag not permitted on sparse-heap-backed textures
- Sparse texture sampled access works; write/imageStore access does not
- Related to Constraint 1 (MS texture write) but at sparse-heap level

**CTS impact:**
- Subset of `KHR-GL46.sparse_texture2_tests` requiring imageStore + sparse residency interaction
- `SparseTexture2Commitment` specific test subset

**AppGL approach:**
- Combined with Constraint 1 in Sprint 19 β emulation commitment
- Sparse-texture2 module will determine usage at allocation time + emulate writes as needed

**Monitoring criteria:**
- Check `MTLHeap` documentation updates for sparse + writeable capability
- Test sparse-heap-backed texture with `MTLTextureUsageShaderWrite` against newer toolchains

**Reclassification trigger:**
- Joint with Constraint 1 — likely co-evolve in Apple Metal updates

---

### Constraint 5: `MTLDepthClipModeClip` ignored at hardware

**Status:** TIME-LIMITED (Sprint 17 Bank-Group-A-2 Architecture A; emulation via gl_ClipDistance synthesis pending Sprint 18+)
**First observed:** Sprint 17 Day 7+ (2026-05-07)
**Apple Metal version observed:** Metal 2.4 (macOS 26.x / Xcode 17 on M1 Max)

**Technical detail:**
- Metal accepts `MTLDepthClipModeClip` in pipeline descriptor but hardware/driver does not apply expected clipping
- Affects clip_control extension `depth_mode_zero_to_one` and related variants
- Sprint 17 Item 32 LIVE 1st-instance empirical anchor

**CTS impact:**
- `KHR-GL46.clip_control.*` — partial test impact (specific depth_mode variants)
- Bank-Group-A-2 Architecture A territory

**AppGL approach (current):**
- BANKED Sprint 17→18→19 (Architecture A multi-variant MSL design preserved; gl_ClipDistance synthesis pending engagement)
- gl_ClipDistance synthesis workaround mapped (Option α/β/γ design space)

**Monitoring criteria:**
- Check Metal pipeline descriptor depth-clip behavior on M1+ across macOS releases
- Apple Developer documentation reference: `MTLRenderPipelineDescriptor depthClipMode` section

**Reclassification trigger:**
- If `MTLDepthClipModeClip` becomes hardware-respected → Bank-Group-A-2 advertising flip + emulation retired

---

### Constraint 6: RGBA32F graphics storage-image platform behavior

**Status:** RESEARCH-PENDING-CLASSIFICATION (Sprint 18 Decision E2-defer territory; Sprint 19 Day 1 PRE-MIN research front)
**First observed:** Sprint 18 (2026-05-10)
**Apple Metal version observed:** Metal 2.4 / Metal 3.2

**Technical detail:**
- Native RGBA32F upload: CORRECT
- Ordinary fragment sampling RGBA32F: PASSES
- Graphics storage-image RGBA32F imageLoad/imageStore: FAILS with correct MSL + correct binding
- R8UI graphics storage-image: WORKS (format-specific, not blanket gap)
- Compute storage-image RGBA32F: WORKS (only GRAPHICS-stage fails)

**CTS impact:**
- ~20-27 RGBA32F-graphics-specific tests
- `KHR-GL46.shader_image_load_store.*` subset with RGBA32F graphics-stage tests

**AppGL approach (Sprint 19 research front):**
- Compute-bypass-for-graphics-write hypothesis (Clerk priority research)
- Sprint 19 Day 1 PRE-MIN research front per Decision E2-defer adjudication

**Monitoring criteria:**
- Test graphics-stage RGBA32F imageStore against newer Apple toolchains
- Check Apple Metal Feature Set Tables for storage-image format×stage support matrix

**Reclassification trigger:**
- If graphics-stage RGBA32F storage-image works on newer Apple Metal → research-front retired; native path adopted
- If hardware-locked at all Apple toolchain versions → reclassify TIME-PERMANENT; emulation via compute-bypass

---

### Constraint 7-NEW (Sprint 19 β2 Phase 7.1): Depth16Unorm→R16Unorm view assertion

**Status:** TIME-LIMITED (Sprint 19 β2 Phase 7.1 image binding cache lifecycle fix; emulation via separate view tracking)
**First observed:** Sprint 19 β2 Phase 7.1 (2026-05-11)
**Apple Metal version observed:** Metal 2.4 / Metal 3.2 (macOS 26.x / Xcode 17)

**Technical detail:**
- Metal asserts when creating a `Depth16Unorm` view that aliases to `R16Unorm`
- Affects sparse texture image binding cache when texture view re-interpretation needed
- Surfaced during β2 image binding lifecycle work; cache mismanagement triggered assertion path

**CTS impact:**
- Subset of `KHR-GL46.sparse_texture2_tests` requiring depth-format image binding paths
- Image binding cache lifecycle hygiene affected broader paths

**AppGL approach (Sprint 19):**
- Phase 7.1 image binding cache lifecycle fix landed (commit `1b07cb9`)
- Separate view tracking + cache cleanup discipline
- Sister to Item 14 LIVE cascade-discovery pattern (bonus catch during β2 work)

**Monitoring criteria:**
- Check `MTLTextureDescriptor` view-format support across Metal releases
- Test Depth16Unorm view creation in newer Apple toolchains

**Reclassification trigger:**
- If view-format aliasing becomes more permissive in newer Metal → cache lifecycle simplification possible
- AppGL fix retained as safety-net regardless

---

### Constraint 8-NEW (Sprint 19 β2 Phase 7.2): `MTLHeapTypeSparse` shader writes don't land in tiles

**Status:** TIME-LIMITED (Sprint 19 β2 Phase 7.2 deferred; sister to Constraint 1 + 4)
**First observed:** Sprint 19 β2 Phase 7.2 (2026-05-11)
**Apple Metal version observed:** Metal 2.4 / Metal 3.2 (macOS 26.x / Xcode 17)

**Technical detail:**
- Distinct from Constraint 4 (MTLTextureUsageShaderWrite hard rejection at allocation): Constraint 8 is silent-no-propagation
- Metal accepts shader writes to sparse-heap-backed textures at API/compile level
- BUT writes silently DO NOT propagate to the underlying sparse tiles
- Discovered during β2 sparse texture image-store empirical validation

**CTS impact:**
- Subset of `KHR-GL46.sparse_texture2_tests` requiring imageStore + sparse residency interaction
- `SparseTexture2Commitment` test cases involving write-side data verification

**AppGL approach (Sprint 19):**
- BANKED Sprint 19; emulation candidate for Sprint 20+ closure-phase
- Sister-pattern to Constraint 1 + 4 emulation strategies (compute-bypass + per-sample dispatch + resolve)
- Item 38 LIVE TIME-LIMITED candidate per Apple Metal sparse-heap evolution potential

**Monitoring criteria:**
- Test shader writes to sparse-heap-backed textures with empirical verification of write-side data
- Check Apple Metal Feature Set Tables for sparse-heap shader-write support advertising

**Reclassification trigger:**
- Joint with Constraint 1 + 4 — Apple Metal sparse-heap evolution likely co-evolves shader-write semantics

---

### Constraint 9-NEW (Sprint 19 β2 Phase 7.6.5+8): AGX mipmapLevel OOB on 1D/1D-array clamp Color

**Status:** TIME-LIMITED candidate Item 32 LIVE #7 (Sprint 19 β2 Phase 7.6.5+8; Phase 9.2 clamp Lookup correctness territory)
**First observed:** Sprint 19 β2 Phase 7.6.5+8 (2026-05-11)
**Apple Metal version observed:** Metal 2.4 / Metal 3.2 (macOS 26.x / Xcode 17)

**Technical detail:**
- AGX driver assertion: `mipmapLevel OOB` on 1D / 1D-array sparse_texture_clamp Color test cases
- Sparse texture clamp depth Color path works for 2D / 2D-array / cube / cube-array targets
- 1D / 1D-array clamp Color specific AGX assertion path

**CTS impact:**
- Subset of `KHR-GL46.sparse_texture_clamp_tests` 1D/1D-array Color cases
- Component of clamp 22.8% LOW pass-rate at β2 close-arc (Decision I β LOW rule HELD per Item 38)

**AppGL approach (Sprint 19+):**
- BANKED to Phase 9.2 clamp Lookup correctness (Foreman pre-pref deferred per Item 32 candidate)
- Sprint 20+ closure-phase candidate
- Sister to Constraint 7+8 (Apple Metal sparse-heap evolution dependency)

**Monitoring criteria:**
- Test 1D/1D-array sparse texture clamp Color paths against newer Apple Metal versions
- Check AGX driver release notes for sparse texture mipmap level validation changes

**Reclassification trigger:**
- If AGX driver mipmap level validation tightens or AppGL workaround surfaces → clamp 1D/1D-array Color advertising-flip-ready
- Apple Metal sparse-heap evolution may co-resolve

---

### Constraint 10: Apple Silicon native FP64 ALU absence

**Status:** TIME-PERMANENT (hardware-locked; Item 38 LIVE refined sub-classification)
**First observed:** Project inception (Apple Silicon design constraint)
**Hardware:** All Apple Silicon (M1, M2, M3, future)

**Technical detail:**
- Apple Silicon GPUs lack native FP64 (double-precision) ALU instructions
- Industry-standard limitation matching Intel iGPU and most mobile GPU architectures
- Hardware design decision unlikely to change in near-term Apple Silicon evolution

**CTS impact:**
- `KHR-GL46.gpu_shader_fp64.*` — 658 NS tests
- `KHR-GL46.vertex_attrib_64bit.*` — 4 NS tests (FP64-tied)
- Total: ~662 NS tests

**AppGL approach (current + future):**
- Default: lossy f32 narrowing (matches macOS OpenGL driver historical behavior; Apple Silicon + Intel iGPU posture)
- Designed alternate path: `APPGL_DOUBLE_UNIFORM_BUFFER_BACKED=ON` cmake build option for emulation (df64 software emulation)
- See `appgl-runtime/docs/double-precision.md` for full specification

**Pending project decision** (Decision F per User-decisions queue): commit to df64 emulation Sprint 20+ OR accept TIME-PERMANENT classification + ~97% CTS-46 ceiling

**Monitoring criteria:**
- Watch Apple Silicon roadmap for hypothetical FP64 ALU addition (low probability)
- Industry-standard FP64-on-GPU posture monitoring (other vendors)

**Reclassification trigger:**
- If future Apple Silicon adds native FP64 → reclassify TIME-LIMITED → native path adopted; emulation deprecated
- Until then: TIME-PERMANENT classification reasonable

---

## §3. Monitoring cadence (project maintainer)

### Per Apple/Xcode major release
1. Check Metal Feature Set Tables for capability additions
2. Test MSL compilation against existing constraint emit patterns
3. Run AppGL gauntlet at new Metal version to detect behavior changes
4. Update this document with any constraint reclassification

### Per AppGL Sprint close
1. Check Item 32 LIVE-MAXIMAL ledger for new constraint additions
2. Cross-reference with this document; add new Section 2 entries as needed
3. Reclassification audit if Apple toolchain update occurred mid-Sprint

#### S22 close audit (2026-05-30)
1. **New empirical refinement to Constraint 1**: §75-B-FIRMLY-CONFIRMED specific MS-store endpoint surfaced during S22 NS-POST Phase 1 deep-inspection (see new §2 Constraint 1.1 entry above). Strongest single-arc persistence evidence (6-attempt + 4-gate-event axes) for a runtime-pipeline endpoint gap. Tracked as latent-implementation-gap; resolution path likely joint with Constraint 1 Apple-toolchain advance OR internal sidecar extension.
2. **No new TIME-LIMITED → RESOLVED transitions this sprint.** Constraint 2 RESOLVED at Sprint 20 remains the only empirical transition; Constraints 1, 3-10 unchanged at S22 close.
3. **No new constraints added.** S22 NS-POST inventory work confirmed the existing 10-constraint inventory remains complete; the §75-B refinement at §2.1.1 is a sub-endpoint of Constraint 1 not a net-new constraint.

### Per quarter (low cadence)
1. Apple Developer documentation review for sparse texture / MS / FP64 / VRS feature evolution
2. Industry context: other GL-on-Metal implementations + their constraint posture (informational)

---

## §4. Update protocol

### Adding a new constraint
1. Identify constraint via Item 32 LIVE-MAXIMAL ledger entry
2. Add new Section 2 entry with: status, observed-date, Apple Metal version, technical detail, CTS impact, AppGL approach, monitoring criteria, reclassification trigger
3. Cross-reference with relevant Sprint substrate memos

### Reclassifying TIME-LIMITED → TIME-PERMANENT
- Apply if multiple Apple Metal version-advances pass without resolution (e.g., 2+ major macOS releases)
- Document rationale + accept emulation as permanent provisional infrastructure

### Reclassifying TIME-LIMITED → RESOLVED
- Apple Metal upstream evolution provides native path
- AppGL emulation layer can be retired
- Update document with "Constraint resolved Sprint N (Metal X.Y)" section
- Retire AppGL emulation per separate engineering work

### Reclassifying TIME-PERMANENT → TIME-LIMITED (rare)
- Apple Silicon hardware roadmap reveals capability addition
- Document update + monitor pending native path

---

## §5. Methodology framework anchors

**Item 32 LIVE-MAXIMAL** (Implementation-correct-but-platform-blocked): canonical methodology surface tracking these constraints in operational ledger
**Item 38 LIVE** (Unfit-case TIME-LIMITED vs TIME-PERMANENT classification framework): sub-classification used in this document
**Item 17 LIVE-MAXIMAL** (Bank-leftover-cross-sprint NEW MECHANISM): cross-sprint allocation mechanism for constraint emulation work
**NORM #5 refined** (Extension-modular discipline): emulation lives in dedicated modules per Item 55 LIVE-MAXIMAL pattern
**NORM #4** (patch-upstream-not-workaround): tracking document enables monitoring for upstream evolution that retires AppGL workarounds

---

End of Apple Metal Upstream Tracking. Maintainer: User. Authored: Clerk 2026-05-11 per User direction Sprint 19 Decision I β adjudication. Document is living reference; updates per Section 4 protocol.
