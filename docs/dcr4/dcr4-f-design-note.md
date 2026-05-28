# DCR4-F Design Note

Status: co-review approved for checkpoint sentinel construction. Full DCR4-F
gating remains blocked until Foreman sends the second implementation go.

Scope: all-surfaces-simultaneous composition audit for the already reapplied
FANTASTIC surfaces:

- F1: argument-buffer ABI, translated graphics, and compute dispatch grouping.
- F2: hardware mesh-GS drawArrays grouping.
- F3: hardware tessellation grouping.
- F4: CPU-GS/TF exact B4 emulation and stream replay grouping.

DCR4-F is not a new feature surface. It must not widen routing, flip defaults,
remove waits, introduce a scheduler, or count approximate fallback as progress.
It audits whether the four surfaces still obey the DCR-3/DCR-4 submission
contract when they touch the same GL-visible resources in one process, frame,
or draw sequence.

## Rung Boundary

DCR4-F checks composition hazards that isolated F1-F4 gates cannot prove:

- producers from different surfaces collide or interleave on the same FBO,
  buffer, texture, image, transform-feedback buffer, or query object.
- pending-producer state from one surface leaks into another surface's consume,
  or a consume clears producer state too broadly.
- an EXCLUDE classification proven in isolation becomes invalid when another
  surface co-writes or immediately consumes the same resource.
- ordering proof is carried across surface boundaries, including current
  command-buffer drains, standalone paths, commit-before-abandon, and explicit
  CPU completion waits.

The safe default follows Section 105 asymmetry: MARK by default for every
GL-visible write. Over-marking is a performance issue for S23; a wrong EXCLUDE
is a race or stale-read bug. EXCLUDE remains allowed only with non-vacuous
red/green proof under composition.

## Co-Review Folds

Foreman and Clerk approved DCR4-F with six required folds. These are part of
the audit design, not optional implementation detail.

### Fold 1: Two-Tier Red Stubs

Preferred red stubs are distinguishable public GL observations. Seed a prior
value `Q`, write the expected value `P`, and make stale/abandoned reads observe
`Q` where `Q != P`. This avoids the cleared-zero ambiguity: wrong output must
not be indistinguishable from a valid zero result.

Internal `producerPending` bit-state assertions are fallback-only. Use them
only when a public observation is infeasible or nondeterministic. If an
internal hook is required, prefer compile-time instrumentation over a runtime
env gate so the shipped CTS gate target remains byte-identical to the accepted
22496e5 dylib. The instrumented build is a separate supplementary artifact
with a different hash by design. It is mechanism proof only; conformance gates
and P->F accounting always run on the shipped dylib.

### Fold 2: Aliasing Recheck

The producer key is currently GL-name plus producer bits. That can miss a
hazard when two surfaces touch the same backing storage through different
keys. DCR4-F must explicitly check:

- buffer subranges through `glBindBufferRange`.
- the same buffer rebound as different targets, such as SSBO, texture buffer,
  TF buffer, atomic counter buffer, or pixel transfer buffer.
- texture views, especially `glTextureView`, where one backing store has
  multiple GL texture names. A mark under the view name and a drain under the
  base name can miss unless the implementation reconciles to backing storage.

The audit must prove alias keys compose or report the gap as a hazard.

### Fold 3: Query Double-Count Split

Mixed F3/F4 query accounting needs two independent checks:

- skip-half: construct a red stub where one surface's query update is skipped;
  readback must catch the missing contribution.
- double-count-half: either construct a double-count red stub, prove structurally
  that only one accounting path can update the counter, or disclose honestly
  that a double-count red stub could not be constructed.

The final report must not collapse this into "if possible" language.

### Fold 4: Concurrent Transform Feedback

Sequential F3 TF write followed by F4 replay is necessary but not sufficient.
The composition risk is concurrent ownership: an F1 GPU-pending write to a TF
buffer and an F3 CPU-immediate TF write to the same buffer. F3's isolated
"immediately visible, no pending GPU producer" EXCLUDE is valid only if the
CPU write is always ordered after draining any pending GPU producer on that
buffer. If this cannot be proven, F3 must MARK instead of EXCLUDE under the
Section 105 composition rule.

### Fold 5: EXCLUDE Completeness Cross-Check

The explicit EXCLUDE list below must be proven complete. The cross-check source
of truth is the actual DCR4-B/C/D/E notes and their Section 101 producer audits,
not memory. The final report must state which notes/audits were checked and
whether any additional EXCLUDE rows were found.

### Fold 6: Lifecycle As Third Invalidation Mode

Composition invalidates EXCLUDEs through more than co-write and co-consume.
DELETE, REDEFINE, ORPHAN, map/unmap, and storage replacement of a resource
while another surface has a pending producer on the same backing storage is a
third invalidation mode. The lifecycle rechecks must specifically cover TF
buffers and query-related CPU state, not only FBO textures.

## Implemented Group Baseline

DCR4-F should audit the names and behavior already in the tree:

- `TranslatedDrawGroup` and `ComputeDispatchGroup`, with optional
  `ArgumentBindingGroup`.
- `MeshGsDrawGroup`, `MeshGsPrepassGroup`, and `MeshGsRenderGroup`.
- `TessDrawGroup`, `TessVertexGroup`, `TessControlGroup`,
  `TessFactorClampGroup`, `TessDomainGroup`, `TessEvalGroup`, and
  `TessRenderGroup`.
- `CpuGsExpansionGroup`, `TransformFeedbackCaptureGroup`, and
  `StreamReplayGroup`.
- `FallbackNsGroup` for exact-only or honest-NS boundaries.

No DCR4-F implementation should add a second resource contract. GL-visible
writes must continue through `markGpuResourceWrites`; GL-visible reads must
drain through the producer-pending funnel; internal transients must stay
declared as submission transients with an explicit ordering mechanism.

## Cross-Surface Producer Interaction Matrix

DCR4-F treats "co-active" as one process and one frame/draw sequence where
two or more surfaces reference the same GL object without an intervening full
process reset. The object can be a framebuffer attachment, SSBO, storage-image
texture, transform-feedback buffer, query object, or objectless default
framebuffer state. The audit is about the GL-visible object boundary, not the
internal Metal buffers used to implement a surface.

### Same-Resource Co-Activity

| Resource | F1 argbuf/translated/compute | F2 mesh-GS | F3 tess | F4 B4 CPU/TF | Composition risk |
| --- | --- | --- | --- | --- | --- |
| User FBO attachment | Produces through translated draws; consumes through sampling, readback, blit/copy, or later draw loads. | Produces through native mesh render; consumes sampled textures and loaded attachments. | Produces through tess render; consumes sampled textures and loaded attachments. | Produces through raster replay; consumes loaded attachments when raster is active. | All four can co-produce the same texture/renderbuffer in sequence. Missing one mark or over-broad one drain creates stale readback or clears another surface's pending bit. |
| Default framebuffer | Produces objectless default-framebuffer state. | Produces objectless default-framebuffer state. | Produces objectless default-framebuffer state. | Produces objectless default-framebuffer state. | No producer-pending key exists. Composition must prove default-framebuffer invalidation survives drains, resize, restore, and present without pretending it is a GL object producer. |
| Storage-image texture | Produces in graphics and compute; consumes via texture/image reads. | Can produce wired storage-image writes and can consume sampled/read image textures. | Native hardware path must reject side-effect image writes unless fully wired; can consume sampled textures. | CPU interpreter image writes and raster FS writes can produce; CPU interpreters can consume. | MARK-by-default is safe; the risky case is a CPU-side or native-tess EXCLUDE being reused after another surface GPU-wrote the same texture. |
| SSBO buffer | Produces in graphics and compute; consumes as SSBO, texture buffer, readback, or CPU fallback input. | Native mesh currently excludes storage-buffer/atomic producer routes. | Native hardware path rejects storage-buffer side effects unless fully wired. | Raster FS translated subgroup can produce; CPU fallback can consume buffer data. | F2/F3 EXCLUDE must remain route-local. If F1/F4 co-write the same buffer, F2/F3 must not claim an unwired native route or skip the required drain. |
| Atomic counter buffer | Produces in graphics and compute; readback consumes. | Native mesh excludes storage-buffer-backed atomic routes. | Native hardware path rejects atomic side effects unless fully wired. | Raster FS translated subgroup can produce; CPU fallback/query logic can consume. | Same as SSBO: the EXCLUDE is safe only if native F2/F3 never become the writer for that shared object. |
| Transform-feedback buffer | Can read, redefine, map, delete, or otherwise consume the buffer after other surfaces write it. | TF-active draws are excluded from native mesh. | Tess CPU TF path writes bytes but was isolated as CPU-immediate rather than GPU-pending. | CPU-GS/VS TF capture writes and marks `kProducerTransformFeedback`; stream replay consumes counts and buffers. | F3's CPU-side TF EXCLUDE is the sharpest composition risk: a shared TF buffer can be written by F3 then replayed or lifecycle-drained by F4/F1. |
| Query object | Ordinary draw query consumers/readbacks can bracket mixed work. | Query side effects are not a mesh producer object. | CPU-side tess query updates. | CPU-side GS/TF query updates. | No producer-pending key exists. Composition must prove mixed F3/F4 query accounting is neither skipped nor double-counted. |
| Aliased backing storage | Can mark a base object or a rebound buffer role. | Can consume a sampled texture/view or FBO attachment alias. | Can consume sampled textures and fallback buffers. | Can consume/write TF buffers, images, and raster outputs. | A producer marked under one GL name/target can be missed by a drain under another name/target unless backing aliases are reconciled. |
| Internal transient | Argbuf payloads, ring bytes, SSBO-size sidecars. | `MeshVsOutputBuffer`. | Tess factor/control/domain/eval buffers. | `EmulatedDraw` CPU temporaries and optional `appgl-vstf-out`. | These are never GL producers. Composition must prove a shared GL object is not hidden behind an internal-transient EXCLUDE. |

### Surface Pairs

| Pair | Same-resource composition that can happen | Required DCR4-F proof |
| --- | --- | --- |
| F1 graphics -> F2 mesh | translated draw writes an FBO texture/renderbuffer or storage image, then mesh-GS samples/reads it or draws into the same FBO | producer bits from F1 survive until F2's read/drain; F2 does not clear unrelated pending bits. |
| F1 compute -> F2 mesh | compute writes a storage image or buffer-backed texture source, then mesh-GS samples/reads it | `ComputeDispatchGroup` producer bits force visibility before `MeshGsDrawGroup`; skip-mark red stub must fail. |
| F1 graphics/compute -> F3 tess | translated/compute writes texture, SSBO, image, atomic, or FBO state used by hardware tess | F3 drains F1 producers before sampled/read use; native tess side-effect EXCLUDEs are not bypassed. |
| F1 graphics/compute -> F4 CPU/TF | F1 writes buffers/textures that CPU interpreters read, or F1 draws into an FBO later used by F4 raster/replay | CPU-side consumers drain pending GPU producers before reading CPU shadows; no stale buffer/image data. |
| F2 mesh -> F1 graphics/compute | mesh writes FBO/image producers, then translated draw or compute samples/reads/writes the same object | F2 marks FBO/storage-image writes and F1 drains exactly those bits. |
| F2 mesh -> F3 tess | mesh and tess draw to the same FBO sequence, or mesh writes a texture sampled by tess | FBO producer state is ordered across the standalone mesh path and tess path. |
| F2 mesh -> F4 CPU/TF | mesh writes a resource that F4 CPU interpreter, raster replay, or stream replay reads; F4 raster later writes the same FBO | F4 drains F2 producers before CPU read; F4 raster producer marking remains separate. |
| F3 tess -> F1 graphics/compute | tess render writes an FBO texture/renderbuffer later consumed by translated draw or compute | tess FBO producer bits are visible to F1 drains; no reliance on same-queue command-buffer order. |
| F3 tess -> F2 mesh | tess render writes a texture/FBO then mesh samples or draws into it, and reverse order in the same frame | both directions preserve producer bits and current-CB drain semantics. |
| F3 tess -> F4 CPU/TF | tess CPU TF write or tess point replay is followed by F4 capture/replay using the same TF buffer/FBO | DCR4-D TF EXCLUDE is re-proven with F4 replay/capture; no stale counts or double counting. |
| F4 CPU/TF -> F1 graphics/compute | CPU-GS TF writes a buffer, CPU image writes a texture, or raster replay writes FBO/image/SSBO/atomic resources before F1 consumes them | F4 marks TF and CPU image writes; translated raster side effects reuse F1 producer marking. |
| F4 CPU/TF -> F2 mesh | F4 CPU image or raster replay writes a texture/FBO that mesh-GS samples or draws into | CPU writes are either marked or explicitly excluded with proof; mesh does not consume stale state. |
| F4 CPU/TF -> F3 tess | F4 writes texture/FBO/TF/query state consumed by tess or used in the same query sequence | tess drains F4 producers; query/TF CPU object state remains correctly accounted. |

### Resource Classes

| Resource class | Active producer surfaces | Active consumer surfaces | Composition rule |
| --- | --- | --- | --- |
| User FBO color/depth/stencil attachments | F1 translated draw, F2 mesh render, F3 tess render, F4 raster replay | all graphics paths, readback, texture sampling if attachment is a texture | all user-FBO writes mark `kProducerFboColorWrite` or `kProducerFboDepthStencilWrite`; every later read drains the specific attachment object. |
| Default framebuffer | F1, F2, F3, F4 raster paths | presentation/readback paths | objectless side effect. Keep default-framebuffer invalidation; do not invent a producer bit. Composition sentinel must still prove no current-CB abandon loses it. |
| Storage image texture | F1 graphics/compute, F2 mesh when wired, F4 CPU interpreter image writes and raster FS writes | F1/F2/F3/F4 texture/image reads | mark `kProducerStorageImageWrite` by default. F3 hardware tess native path must reject side-effect images unless fully wired. |
| SSBO buffer | F1 graphics/compute and F4 raster FS translated subgroup | F1 compute/graphics, CPU fallback interpreters, possible later draws | mark `kProducerShaderStorageWrite` or compute-write bits where wired. F2 native mesh and F3 hardware tess keep SSBO side effects excluded/rejected. |
| Atomic counter buffer | F1 graphics/compute and F4 raster FS translated subgroup | all later shader paths or readback | mark `kProducerAtomicCounterWrite` where wired. F2/F3 native side-effect excludes must stay enforced under composition. |
| Transform-feedback buffer | F4 CPU-GS/VS TF capture; F3 tess CPU TF write path | readback, buffer redefinition/delete, F4 stream replay, later CPU/GPU consumers | F4 marks `kProducerTransformFeedback`; DCR4-D CPU tess TF EXCLUDE must be revalidated when F4 uses the same buffer. |
| TF object stream counts | F4 capture, F3 tess TF accounting | F4 stream replay, EndTransformFeedback, queries | CPU object state, not a producer-pending resource. Revalidate with replay and count-red-stub sentinels. |
| Query object state | F3 tess TF/query accounting, F4 CPU-GS/TF query accounting, ordinary draw queries | query readback across mixed draw sequences | CPU object state, not producer-pending. Revalidate no skip, no double count, and no cross-surface leak. |
| Internal transients | F1 argbuf/ring/sidecar payloads, F2 `vsOutBuf`, F3 tess buffers, F4 `EmulatedDraw` temporaries | only their owning parent/subgroups | never mark as GL producers. Revalidate that a shared GL object is not accidentally classified as an internal transient. |

## Composition Hazards

The sharp focus is EXCLUDE-invalidated-by-composition. MARKed producers are
composition-safe because an extra drain is a performance problem. EXCLUDEs are
composition-risky because an unmarked producer can race a different surface's
read or lifecycle operation. DCR4-F therefore spends most of its burden proving
that each isolation EXCLUDE is still route-local and still non-GL-visible when
another surface touches the same GL object.

### Producer Leak Across Surface

Pending producer state is keyed by GL object and producer bits, not by the
surface that wrote it. DCR4-F must prove:

- a producer bit set by one surface is visible to a different surface's drain.
- a drain clears only the bits it consumed, not unrelated pending work from a
  later surface.
- CPU-written F4 resources and GPU-written F1/F2/F3 resources behave the same
  at the GL-visible boundary.
- repeated writes from different surfaces to the same object do not leave stale
  producer bits that cause false readback behavior or hide missing marks.

### EXCLUDE Invalidated By Composition

An EXCLUDE is valid only for the route and resource ownership it was proven
against. DCR4-F must revalidate these isolation-proven EXCLUDEs:

- F1 argbuf payloads, uniform-ring bytes, SSBO-size sidecars, and sidecar
  binding payloads are internal transients, not GL producers. They must not be
  used to hide a write to a GL buffer/texture/sidecar object that another
  surface consumes.
- F2 native mesh excludes transform-feedback-active draws, SSBO writes, and
  storage-buffer-backed atomic side effects. Under composition, F2 must still
  reject or fallback when the same program/FBO sequence also uses F1/F4
  side-effect resources.
- F2 `MeshVsOutputBuffer` is internal and ordered by the current
  `CpuCompletionWait`. Revalidate it is never exposed as the shared GL buffer
  consumed by another surface.
- F3 hardware tess excludes storage-image, SSBO, and atomic side effects from
  the native path unless fully wired. Composition must prove F1/F4 co-writes do
  not let the hardware tess route claim those side effects.
- F3 tess TF CPU write was isolated as immediately visible CPU state rather
  than a pending GPU producer. Composition must revalidate this with F4 replay,
  F4 capture, readback, and buffer lifecycle operations on the same TF buffer.
- F3 query updates are CPU-side query object state. Composition must prove
  mixed F3/F4 query sequences update once and read back correctly.
- F3 tess internal buffers (`factorBuf`, `cpOutBuf`, `domainCoordBuf`,
  `totalVertCountBuf`, `tesComputeOutBuf`, etc.) are not GL producers.
  Composition must not classify point replay or TF copy destinations as those
  internal buffers.
- F4 TF object counts and query state are CPU object state, not
  producer-pending storage. Revalidate with stream replay and query readback
  after other surfaces have also updated the same query/TF sequence.
- F4 `EmulatedDraw` CPU temporaries and optional `appgl-vstf-out` are internal.
  The GL-visible TF buffer or image written from them must still be marked or
  explicitly proven immediate.
- Default framebuffer writes remain objectless. Composition must prove resize,
  restore, and present paths preserve them without pretending a producer bit
  exists.
- Aliased backing storage must not be treated as independent just because the
  GL name or binding target differs. If a producer key does not reconcile base
  texture/view texture names or buffer target aliases, the EXCLUDE is invalid
  under composition.

### Explicit EXCLUDE Reverification List

The gating audit should report each item below as pass/fail with the sentinel,
CTS case, or trace that proved it:

| EXCLUDE | Original isolated reason | Composition recheck |
| --- | --- | --- |
| F1 argbuf and ring payloads | CPU-populated implementation payload consumed by the same draw/dispatch encode, not a GL object. | Run with the underlying GL buffer/texture also written by F2/F3/F4; prove the GL object still drains through producer-pending, while argbuf payloads remain internal. |
| F1 fp64/sparse/image sidecars that are internal-only | Sidecar payloads are implementation details unless they back a GL-visible resource. | Prove a GL-visible sidecar destination is MARKed when another surface later consumes it; only implementation-only sidecars stay excluded. |
| F2 TF-active native mesh exclusion | Native mesh does not write TF buffers. | In a sequence with F4 TF active on the same program/resource family, prove F2 is not selected and exact CPU/TF or honest-NS owns the write. |
| F2 SSBO/atomic native mesh exclusion | Native mesh has no SSBO/atomic binding/write loop. | With an SSBO/atomic bound and later read by F1/F4, prove native F2 rejects/fallbacks and cannot become an unmarked writer. |
| F2 `MeshVsOutputBuffer` transient | Private Metal buffer ordered by `CpuCompletionWait`; not a GL buffer. | Reuse the same GL buffer name elsewhere in the sequence and prove producer state attaches only to the GL buffer, not the transient. |
| F3 storage-image/SSBO/atomic native tess exclusion | Hardware tess route does not bind or mark these side effects. | With F1/F4 co-writing the same image/buffer, prove F3 native side-effect route rejects/fallbacks and does not clear or skip the existing producer bits. |
| F3 tess TF CPU-write EXCLUDE | Tess TF bytes are CPU-written and immediately visible in isolation. | Feed the same TF buffer to F4 replay/readback/lifecycle; prove skipped CPU write fails and normal write is visible without needing a hidden GPU wait. |
| F3 query CPU-state EXCLUDE | Query objects are CPU-side state, not buffer/texture producer state. | One query spans F3 and F4 work; prove summed counts, no double count, and red stubs for skipped updates. |
| F3 tess internal buffers | Private stage buffers with explicit waits; not GL-visible. | Point replay and TF copy destinations must be classified as FBO/TF producers, not as tess internal transients. |
| F4 TF object count EXCLUDE | Stream counts are CPU object state. | Capture with F4, interleave F3/F1 work, then replay; zero-count red stub must fail replay while buffer bytes remain independently checked. |
| F4 query CPU-state EXCLUDE | Query objects are CPU-side state. | Mixed F3/F4 query bracketing proves no leak between per-surface accounting paths. |
| F4 `EmulatedDraw` and `appgl-vstf-out` transients | CPU temporary or readback helper buffer, not GL-visible storage. | The TF buffer/image/FBO written from the temporary is MARKed or explicitly proven immediate when F1/F2/F3 later consumes it. |
| Default framebuffer objectless writes | No texture/renderbuffer object owns producer bits for framebuffer 0. | Mixed F1-F4 default-framebuffer sequence plus resize/restore/present proves the objectless invalidation path composes. |
| Buffer/texture alias keys | Name plus producer bits may not represent all aliases of the same backing storage. | Buffer-range, rebound-target, and texture-view tests prove marks/drains reconcile aliases, or report the missing reconciliation as a hazard. |

### Ordering Carry Across Boundaries

Do not treat same-queue command-buffer order as a cross-surface visibility
proof. DCR4-F carries the DCR4-A ordering rule:

- F2 prepass -> render stays backed by the current CPU completion wait.
- F3 tess stage edges and GPU->CPU reads stay backed by the current CPU
  completion waits.
- F4 optional VS-only TF helper keeps `VertexTransformFeedbackReadback`.
- F1 compute keeps its existing compute commit-and-wait behavior.
- current-command-buffer drains before standalone mesh/tess work must not
  abandon pending translated work.
- resize, restore, delete, and redefinition paths must use commit-before-abandon
  before replacing resources touched by any F1-F4 group.

Any implementation that removes one of these waits is out of DCR4-F scope and
needs a separate ordering proof, such as legal same-command-buffer ordering,
known Metal hazard tracking, or an explicit fence.

## Composition Sentinel Plan

Sentinels should be added before relying on CTS deltas. Each sentinel needs a
green path and at least one red stub that proves the checked mechanism is
non-vacuous. For a pure verification rung, new composition sentinels should be
test-only and should not change the runtime dylib. In this tree,
`tests/GauntletRunner.cpp` is linked into `libAppGL.dylib`, so adding a new
`dcr4f-sentinels` phase there is a runtime-dylib delta unless co-review
explicitly accepts that classification. The default placement should be a
standalone dynamic-linked harness that loads the packaged `current-lib`
`libAppGL.dylib`; existing DCR3/DCR4 per-surface sentinel phases can still be
rerun through the already-packaged dynamic CLI.

Some red stubs need internal `producerPending` assertions. If those cannot be
proven through public GL-visible behavior, the audit should either reuse an
existing internal sentinel phase or escalate the need for a test-only internal
hook before implementation. It should not silently turn a no-runtime
verification rung into a runtime-source change.

| Sentinel | Green path | Red stub proof |
| --- | --- | --- |
| `dcr4f.f1-compute-to-f2-mesh-texture` | F1 compute writes a storage image texture, F2 mesh-GS samples it and renders expected color | skip F1 storage-image producer mark or skip compute write; mesh output must fail or pending-bit assertion must fail. |
| `dcr4f.f1-compute-to-f3-tess-texture` | F1 compute writes a texture, F3 hardware tess samples it and renders expected color | skip F1 producer mark; tess consume/readback must expose stale or missing pending-bit behavior. |
| `dcr4f.f2-mesh-to-f1-translated-fbo` | F2 mesh writes an FBO texture, F1 translated draw samples it into another FBO | skip F2 FBO mark; sentinel must catch missing mark before readback or wrong sampled result. |
| `dcr4f.f3-tess-to-f1-translated-fbo` | F3 tess render writes an FBO texture, F1 translated draw samples it | skip F3 FBO mark; read/drain assertion or sampled result must fail. |
| `dcr4f.f2-f3-shared-fbo-order` | F2 mesh and F3 tess draw sequentially to the same FBO with load/blend/depth dependency in both directions | force one producer mark off; final pixels or pending-bit checks must distinguish the lost edge. |
| `dcr4f.f4-tf-buffer-to-f1-read-redefine` | F4 CPU-GS TF writes a buffer, then F1/readback/redefinition consumes it | skip TF producer mark and separately skip CPU TF write; one red catches mark absence, one catches data absence. |
| `dcr4f.f4-image-to-f2-f3-sample` | F4 CPU interpreter image write is sampled by F2 mesh or F3 tess in the next draw | skip F4 image producer mark; sampled result or pending assertion must fail. |
| `dcr4f.f3-tf-exclude-with-f4-replay` | F3 tess CPU TF write feeds a subsequent F4 stream replay or readback on the same TF buffer | skip F3 CPU TF write; replay/readback must fail, proving the EXCLUDE is not vacuous. |
| `dcr4f.f1-pending-vs-f3-tf-cpu-same-buffer` | F1 creates a GPU-pending write to a buffer, then F3 CPU TF writes a distinct pattern to the same TF buffer after the required drain/order point | seed prior `Q`; if F3 writes without ordering after F1, readback/replay can observe stale/interleaved `Q` or F1 pattern instead of F3 `P`. |
| `dcr4f.mixed-query-accounting-skip` | one query object spans an F3 tess draw and an F4 CPU-GS/TF draw; counts equal the sum of both | skip one half and prove readback misses that contribution. |
| `dcr4f.mixed-query-accounting-double-count` | same mixed query sequence, with a single-source accounting proof or constructed double-update red stub | double-count red stub must over-report, or report structural impossibility/honest no-stub disclosure. |
| `dcr4f.exact-only-composed-no-slip` | F1 argbuf active, F2/F3 possible, and an F4 exact-only B4 route fails under env force-fail; draw is consumed or honest-NS | force F4 raster or TF failure; output must not appear via stripped VS+FS or native approximate fallback. |
| `dcr4f.commit-before-abandon-all-surfaces` | run F1 compute/translated, F2 mesh, F3 tess, and F4 TF/raster work, then resize/redefine/delete shared resources | force legacy abandon path if a test hook exists; sentinel must catch lost writes or stale readback. |
| `dcr4f.alias-buffer-targets` | write a buffer through one target/range and consume through another target/range in a different surface | seed `Q`, write `P`, then consume via alias; stale `Q` or partial-range leakage proves alias reconciliation failed. |
| `dcr4f.alias-texture-view` | write through a base texture or FBO view, then consume/drain through a texture view or base texture on another surface | seed view/base with distinct `Q`, write `P`, and prove the alias consume sees `P` and drains the backing hazard. |
| `dcr4f.tf-lifecycle-during-pending` | a TF buffer or aliased buffer has pending work from one surface, then another surface redefines/orphans/deletes it | seed `Q` and write `P`; lifecycle operation must drain or preserve correctness, never leave stale `Q` or lose `P`. |
| `dcr4f.dynamic-cli-loads-artifact-dylib` | packaged sentinel CLI loads `current-lib/libAppGL.dylib` through `@rpath` and reports the artifact UUID | stale or static-linked CLI must fail an otool/dyld/UUID assertion. |

The sentinel implementation may split these into smaller tests if one test
would be too fragile, but the final DCR4-F report must cover every resource
class in the matrix.

### Checkpoint Harness Placement

The first checkpoint uses `tests/DCR4FCompositionHarness.cpp`, a standalone
dynamic harness compiled manually into
`tests/reports/s22-fantastic-rebuild/DCR4-F-local/bin`. It is intentionally
not wired into CMake and does not change `libAppGL.dylib`; it resolves GL entry
points through the public `appglGetProcAddress` API after `dlopen` of the
candidate dylib.

Checkpoint-built public GL-observable sentinels:

- `dcr4f.f2-mesh-to-f1-translated-fbo`.
- `dcr4f.f3-tess-to-f1-translated-fbo`.
- `dcr4f.f4-tf-buffer-to-f1-texture-buffer-alias`.
- `dcr4f.f4-tf-buffer-lifecycle-redefine`.
- `dcr4f.f1-compute-pending-to-f3-tess-tf-same-buffer`.
- `dcr4f.f3-tess-tf-to-f4-stream-replay`.
- `dcr4f.mixed-f3-f4-query-skip-half`.

Held or explicitly disclosed at checkpoint:

- no internal `producerPending` bit assertion hook was added.
- no runtime env hook currently constructs a public double-count query red
  stub; this must become a structural proof or supplementary instrumented
  build before full gating.
- texture-view alias and default-framebuffer lifecycle coverage remain in the
  final DCR4-F audit matrix, not in the first standalone checkpoint harness.

## DCR-3 Legs And Existing Sentinels To Revalidate

The post-review gating run must keep F1-F4 active simultaneously and rerun the
existing DCR-3 proof set, not only the new composition sentinels:

- bounded-outstanding pressure net:
  `dcr3.reduced-bound-contended-pressure`,
  `dcr3c.fbo-pressure-readback`, and `dcr3c.sustained-soak-bar`.
- producer funnel/readback coherence:
  `dcr3c.msaa-resolve-readback-sync`,
  `dcr3c.msaa-shader-resolve-readback-sync`,
  `dcr3c.producer-inventory-bits`,
  `dcr3c.bar-blit-copy-mipmap`,
  `dcr3c.bar-copyimage-sparse-lifecycle`, and
  `dcr3c.buffer-as-different-role`.
- commit-before-state-invalidation:
  `dcr3c.viewport-restore-abandonment`.

The report should state which env/profile settings made F1 argument buffers,
F2 mesh-GS, F3 tess, and F4 B4 exact CPU/TF paths active in the same process
or sequence. If a sentinel cannot make all four active in one GL context, it
must state the reason and use the narrowest multi-surface sequence that still
shares the target GL resource.

## Local Gates After Co-Review Go

Verification gates should include:

- `git diff --check`.
- build `AppGL` explicitly, or build `all`, before CTS or artifact emission in
  both release and fp64-on configurations.
- for a pure verification rung, confirm HEAD, confirm no runtime-source delta,
  and expect the 22496e5 dylib hash to remain unchanged. Section 106
  dylib-hash-change verification applies again only if DCR4-F finds a hazard
  that requires a runtime code fix.
- run new composition sentinels from a standalone dynamic-linked harness, or
  from a co-reviewed test-only internal hook if public GL behavior cannot prove
  the red stub.
- rerun the existing DCR4-C, DCR4-D, and DCR4-E sentinel phases in both
  variants through the dynamic-linked CLI to prove isolated gates still hold
  against the packaged dylib.
- run focused CTS families that exercise the composed resources:
  `geometry_shader.*`, `tessellation_shader.*`, `transform_feedback.*`,
  storage-image, SSBO, shader-atomic-counter, and framebuffer/readback probes.
- enumerate P->F, P->NonPass, and NonPass->P versus the accepted DCR4-E
  baseline for both variants.

Gate-of-record stays with SCOUT-W. No local crown.

## Artifact Requirements

DCR4-F and later F/G artifacts must carry forward the DCR4-E stale-build
prevention:

- build `AppGL` or `all` explicitly before packaging.
- include the dylib SHA and UUID in metadata.
- prove the dylib hash changed for runtime-code changes. For no-runtime
  verification, record that the unchanged hash is expected.
- package a dynamic-linked `appgl_gauntlet_cli` that resolves
  `@rpath/libAppGL.dylib` to `current-lib/libAppGL.dylib`.
- record `otool -L` or dyld-load proof that sentinels executed against the
  packaged dylib, not `AppGL_static`.
- verify `SHA256SUMS` after copying final dylib, CTS binary, CTS data manifest,
  and dynamic CLI.

## Non-Goals

- No new native B4 route.
- No F2/F3 default-policy flip.
- No wait removal or async rewrite.
- No new producer-pending object type for query or TF object counters unless a
  separate design proves it.
- No approximate fallback or stripped VS+FS fallback for exact-only routes.
- No SCOUT-W crown claim from local results.
