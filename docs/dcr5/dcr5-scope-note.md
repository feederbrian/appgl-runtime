# DCR-5 Scope Note

Status: Foreman+Clerk co-review folds applied; Phase 0 is authorized.

Thread: `s22-fantastic-rebuild`.

Baseline: DCR4-G crowned source HEAD
`8643e07f9e29fe1d5a7047213c4584adbf080513` (`8643e07`).

Scope: DCR-5 is the consolidated argument-buffer-on baseline-residuals
sub-track surfaced by the DCR4-F audit and preserved through DCR4-G cleanup.
It is a fix track, not a feature-tail inventory pass, and not a rerun of the
DCR4 composition crown. The label starts with the nine tractable
argbuf-on residual items below, with one Hard-NS sister register item tracked
alongside the work but not folded into the tractable gate. Phase 0 may
reclassify byte-identical argbuf-on/no-argbuf residuals out of DCR-5 and into
the later feature-tail; the final DCR-5 tractable set may therefore be nine or
fewer items.

This note scopes and sequences the work only. No runtime fix is proposed here.

## Goals

1. Repair the scoped argbuf-on residuals without changing the default-off
   argument-buffer policy.
2. Preserve DCR4-F/G properties: F1-F4 composition behavior, production
   hook-off builds, and hook-enabled sentinel verification.
3. Use a compile-gate-aware driver from the first DCR-5 rung: production
   dylibs for conformance, hook-enabled dylibs only for sentinel red-stub
   checks.
4. Keep each fix rung source-localized with explicit rebuild, dylib SHA/UUID
   capture, bidirectional binary-string proof, and P->F/P->NonPass accounting.
5. Leave the S22 feature-tail and final conformance verdict unblocked by
   unclear DCR-5 bookkeeping.

## Non-Goals

- No default-on change for `APPGL_ENABLE_ARGUMENT_BUFFERS`.
- No broad rewrite of F1/F2/F3/F4 routing.
- No new production environment red-stub hooks.
- No S23 punt for the nine tractable items.
- No per-case micro-rung split unless a specific item proves internally
  separable during diagnosis.
- No classification of the nine tractable items as honest NotSupported merely
  because the current argbuf-on path fails. Compute samplerBuffer already works
  on the texture-buffer path, and the rest of the cluster is Metal binding,
  synchronization, or resource-declaration work.

## Entry Baseline

- DCR4-G HEAD: `8643e07`.
- Production hook-off release dylib SHA:
  `b520ddb4431d24a169c8e5530eac1e715d4f00c6987805ec738d016aa8affe7a`.
- Production hook-off fp64-on dylib SHA:
  `dd762cbb1bf0052df7094042545a3c5bcfd015b562e651d4750e9787edf373ff`.
- Hook-enabled release dylib SHA:
  `98493c2311cbc7605e914cff2575decf3a00e4502f023bdec4d67c9e83f473c6`.
- Hook-enabled fp64-on dylib SHA:
  `837642078f32e4a66b9387018c4f9055bba0886308550aa2e997307666bb72c5`.
- DCR4-G proved production DCR hook strings empty and hook-enabled DCR hook
  strings present.
- DCR4-G hook-enabled DCR4-F composition harness:
  - argbuf-off: `9 passed / 1 failed / 1 not_run`.
  - argbuf-on: `7 passed / 3 failed / 1 not_run`.
- The argbuf-on DCR4-F composition failures are the texture-buffer residuals:
  `control1`, `control1b`, and `f4-tf-buffer-to-f1-texture-buffer-alias`.
- DCR4-F argbuf-on full-env evidence showed:
  - tessellation: 36 Pass / 103 Fail / 1 NotSupported, 103 Pass->Fail versus
    DCR4-D under argbuf-on.
  - shader image load/store: 24 focused argbuf-on failures.
  - shader storage buffer object: 23 focused argbuf-on failures.
  - framebuffer blit: 3 focused argbuf-on failures.
  - DSA framebuffers: 1 focused argbuf-on failure.
  - texture-buffer framebuffer readback: 1 focused argbuf-on failure.
  - DCR3C and DCR4D sentinel failures isolate to
    `APPGL_ENABLE_ARGUMENT_BUFFERS=1`.

## Work Items

### 1. F1 Vertex/Fragment Texture-Buffer Fetch

Evidence: DCR4-F and DCR4-G both leave the argbuf-on texture-buffer
composition controls red: `control1`, `control1b`, and the F4 TF buffer alias
sentinel. CTS `KHR-GL46.texture_buffer.texture_buffer_texture_buffer_range`
is the matching texture-buffer family signal. The no-argbuf DCR4-F package
keeps the CPU texture-buffer controls green, so the failure is tied to the
argbuf-on graphics path rather than texture-buffer support in general.

Likely class: graphics render-encoder argument-buffer view setup for
buffer-backed textures. Compute samplerBuffer works, so the first hypothesis is
an orphaned, mis-ranged, or wrongly typed MTLTexture view in the vertex/fragment
argbuf binding path.

First fix path: compare non-argbuf texture-buffer sampler binding against the
argbuf materialization path in the translated graphics draw. Preserve Clerk's
DCR4-F orphaned-view diagnostic as the ordered first probe:

1. Bind-time snapshot check: determine whether the
   `MTLTextureTypeTextureBuffer` view snapshots contents at bind or references
   the backing storage live.
2. View-refresh semantics on underlying-buffer mutation: determine whether
   `writeBufferRange` / `syncMetalFromShadow` invalidates or refreshes the
   texture-buffer view after CPU shadow or Metal buffer mutation.
3. Shared-storage recreation versus barrier requirement: determine whether
   `MTLTextureTypeTextureBuffer` over shared storage needs explicit view
   recreation after mutation, or whether a barrier/synchronization step is
   sufficient on this path.

After those checks, verify buffer range, pixel format, byte stride, offset
alignment, lifetime, and resource slot assignment for both vertex and fragment
stages.

Gate: DCR4-F composition `--argbuf=on` texture-buffer controls, CTS
`texture_buffer_texture_buffer_range`, and the single texture-buffer
framebuffer-readback case from item 9.

### 2. Argbuf Tessellation 103-Case Cluster

Evidence: DCR4-F argbuf-on tessellation is 36 Pass / 103 Fail /
1 NotSupported in both release and fp64-on, with 103 Pass->Fail versus the
DCR4-D no-argbuf baseline. The minus-argbuf attribution run returns to
139 Pass / 1 NotSupported.

Likely class: hardware tessellation argbuf resource declaration or binding,
not an inherent tessellation limitation. The failure count is broad enough that
the bug is probably in common tess resource binding, stage payload plumbing, or
visibility of F1-produced resources to TCS/TES/FS under argbuf-on.

First fix path: start after item 1 unless diagnosis proves independence.
Validate TCS/TES sampled texture, UBO, SSBO sidecar, and tess factor/eval buffer
bindings under argument buffers. Confirm that native tess still rejects side
effect images, SSBO writes, and atomics unless those resources are fully wired.

Gate: full tessellation case list in production argbuf-on release and fp64-on,
diffed against the DCR4-D baseline; DCR4-D sentinels in hook-enabled argbuf-on
mode.

### 3. Argbuf MSAA Resolve Readback Synchronization

Evidence: DCR4-F hard sentinel attribution isolates
`dcr3c.msaa-shader-resolve-readback-sync` to argument buffers. Command-buffer
only and full-minus-argbuf runs pass; argbuf-only fails with the same
shader-resolved sample mismatch.

Likely class: producer/readback or resolve visibility changes when argbuf-on
submission is active. This may be a resource declaration gap rather than an MSAA
algorithm issue, because the DCR3C sentinel is green without argument buffers.

First fix path: inspect argbuf-on draw/resolve submission group declarations
for MSAA textures, shader-resolve sampler reads, and readback drains. Confirm
that the resolved texture and its source MSAA attachment are declared through
the same producer-pending path used by non-argbuf submission.

Gate: `dcr3c.msaa-shader-resolve-readback-sync` and
`dcr3c.msaa-resolve-readback-sync` in hook-enabled argbuf-on mode, plus
production no-argbuf DCR3C sentinels to prove no regression.

### 4. Argbuf Atomic Tess Fallback

Evidence: DCR4-F hard sentinel attribution isolates
`dcr4d.tess-side-effect-rejects` to argument buffers. The expected behavior is
that an atomic tess draw routes to CPU fallback or a reviewed unsupported path;
under argbuf-on it fails that expectation.

Likely class: native tess acceptance logic diverges when argument buffers are
enabled, allowing a route that still lacks fully wired atomic side effects.

First fix path: audit the side-effect rejection predicate shared by tess route
selection and argbuf resource reflection. The fix should preserve DCR4-D's
contract: hardware tess cannot claim atomic, image, or SSBO side effects unless
the complete binding and producer-marking path exists.

Gate: DCR4-D hook-enabled sentinels with argbuf-on and full-minus-metal-tess
attribution; tess CTS subset from item 2 to ensure the fallback guard does not
mask valid tess cases.

### 5. Argbuf Image Load/Store

Evidence: DCR4-F argbuf-on focused image load/store has 24 failures in both
release and fp64-on. The DCR4-F final no-argbuf prep improves by two passes
relative to argbuf-on but still has accepted image-family residuals; DCR-5
must isolate the argbuf-on component rather than silently inheriting the
no-argbuf family state.

Likely class: storage-image argument-buffer descriptors, access qualifiers,
format/view setup, or producer declaration for graphics and compute image side
effects.

First fix path: compare `resolveImageBindings` and translated draw/compute
image write-set declaration between argbuf and non-argbuf paths. Check both
sampled/image resource slots and memory-barrier visibility before readback or
subsequent sampling.

Phase 0 disposition rule: run the byte-identical-vs-divergence comparison
before any fix. If argbuf-on failures are byte-identical to no-argbuf failures,
reclassify the matching residual out of DCR-5 and into the later feature-tail.
If the argbuf-on result diverges, the divergent residual stays in DCR-5.

Gate: focused `shader_image_load_store` argbuf-on release/fp64-on list, plus
no-argbuf family rerun for P->F/P->NonPass guard.

### 6. Argbuf SSBO

Evidence: DCR4-F argbuf-on focused SSBO has 23 failures in both release and
fp64-on. The no-argbuf final package has `shader_storage_buffer_object.*`
fully passing, making this a clean argbuf-on repair target.

Likely class: SSBO argument-buffer descriptors, size sidecars, buffer range
metadata, or memory-barrier/producer bits for shader storage writes and later
reads.

First fix path: trace SSBO resolution through translated graphics and compute
argbuf materialization. Confirm descriptor buffer, offset, range, and sidecar
bindings match the non-argbuf path and that writable/unknown-access buffers
enter the producer-pending write set.

Gate: focused SSBO argbuf-on release/fp64-on list, full no-argbuf SSBO family,
and DCR3C `producer-inventory-bits` / `buffer-as-different-role` sentinels.

### 7. Argbuf Framebuffer Blit

Evidence: DCR4-F argbuf-on focused framebuffer blit has 3 failures in both
release and fp64-on. The no-argbuf final package also reports 3 framebuffer
blit failures, so DCR-5 must first separate an argbuf-specific visibility issue
from an accepted non-argbuf family residual.

Likely class: producer-pending drain, source/destination attachment
declaration, or readback staging behavior when an argbuf-on producer precedes
a blit/copy/readback path.

First fix path: replay the three cases with argbuf-on and no-argbuf production
dylibs at DCR5 entry. If the failures are byte-identical, reclassify the item
out of DCR-5 and into the later feature-tail. If they diverge, keep the item in
DCR-5 and prioritize the argbuf-specific producer declaration and drain path.

Gate: focused framebuffer blit list, DCR3C `bar-blit-copy-mipmap`, and
production no-argbuf guard.

### 8. Argbuf DSA Framebuffers

Evidence: DCR4-F argbuf-on focused DSA framebuffers has one failure in both
release and fp64-on. The no-argbuf final package also reports one DSA
framebuffer failure, so this item needs entry classification before code
changes.

Likely class: DSA attachment state, framebuffer completeness/readback state, or
producer-pending metadata for a framebuffer object updated through DSA APIs
while an argbuf-on producer is active.

First fix path: identify the exact failing DSA case, then compare argbuf-on
and no-argbuf output first. If the failures are byte-identical, reclassify the
item out of DCR-5 and into the later feature-tail. If they diverge, keep the
item in DCR-5 and compare attachment object identity and producer/readback
declarations between DSA and bindful paths. Avoid broad framebuffer refactors
until the single failing route is known.

Gate: focused DSA framebuffer list, read-pixels focused probes, and DCR3C FBO
readback sentinels.

### 9. Argbuf Texture-Buffer Framebuffer Readback

Evidence: DCR4-F argbuf-on focused
`texture_buffer_operations_framebuffer_readback` has one failure in both
release and fp64-on, while DCR4-F final no-argbuf prep has this probe passing.

Likely class: same root as item 1 until disproven: buffer-backed texture view
setup, alias tracking, or readback visibility after texture-buffer sampling in
an argbuf-on graphics path.

First fix path: keep this as the readback leg of item 1 during the first fix
rung. Split only if texture-buffer sampling becomes green while framebuffer
readback remains red.

Gate: this single case plus item 1's texture-buffer composition controls.

## Hard-NS Sister Item

Decision: keep `KHR-GL46.shader_atomic_counters.basic-usage-simple` as a
sister Hard-NS register item, not folded into the nine DCR-5 tractable work
items.

Rationale:

- The DCR4-F Hard-NS draft shows the timeout is stable at current `22496e5`
  and vintage `abca279` under argbuf-on.
- Corrected samples stop inside CTS validation:
  `SACSubcaseBase::ValidateReadBuffer` -> `tcu::fuzzyCompare` ->
  `tcu::bilinearSample`.
- Samples do not show an AppGL or Metal command-buffer wait as the cause.
- Folding this into DCR-5 would mix a CTS-internal validation wall with
  tractable AppGL binding/synchronization fixes.

Tracking rule: every DCR-5 package should carry the Hard-NS register draft
forward and state whether the sister item is unchanged, unlocked, or superseded
by new evidence. It does not block a DCR-5 crown unless co-review changes its
classification.

At every phase exit, Foreman+Clerk co-review must include an explicit Hard-NS
sister attestation for `KHR-GL46.shader_atomic_counters.basic-usage-simple`:
unchanged, unlocked, or superseded.

The family-order quarantine for
`KHR-GL46.shader_atomic_counter_ops_tests.ShaderAtomicCounterOpsExchangeTestCase`
also stays separate. It is an isolated argbuf-on failure/family-order artifact,
not the Hard-NS timeout.

## Proposed Sequencing

### Phase 0: Entry Reproduction And Classification

- Rebuild production hook-off release and fp64-on from `8643e07`.
- Rebuild hook-enabled release and fp64-on for sentinels only.
- Capture starting SHA/UUID and DCR hook-string proof.
- Reproduce the nine item families with production argbuf-on.
- For items 5, 7, and 8, record byte-identical-vs-divergence no-argbuf
  comparisons before any fix because their family state is not purely
  argbuf-only in the DCR4-F final package.
- Reclassify byte-identical argbuf-on/no-argbuf residuals out of DCR-5 and into
  the later feature-tail with a DCR-5 record note. Argbuf-specific divergence
  stays in DCR-5. Reclassify-out is not a failure; it is the scope boundary
  working as designed.

### Phase 1: Texture-Buffer Foundation

Owns items 1 and 9. This is first because it is a direct F1 graphics
argbuf-view problem and may also remove the DCR4-F composition argbuf-on reds.

Exit: texture-buffer composition controls and
`texture_buffer_operations_framebuffer_readback` are green under argbuf-on, or
the readback case is split with evidence. Then replay downstream items
2, 3, 4, 5, 6, 7, and 8 if they remain in DCR-5, classify each as
CASCADE-CLEARED, CASCADE-REDUCED, or UNCHANGED, and use that reduced residual
set as the Phase 2 starting scope.

### Phase 2: Tessellation And Tess Side-Effect Fallback

Owns items 2 and 4. Start after texture-buffer foundation unless entry
diagnosis proves tess is independent.

Exit: tessellation 103-cluster no longer shows unexplained Pass->Fail versus
DCR4-D under argbuf-on, and DCR4-D atomic tess fallback sentinel is green in
the hook-enabled argbuf-on build. Then replay downstream items 5, 6, 3, 7, and
8 if they remain in DCR-5, classify each as CASCADE-CLEARED, CASCADE-REDUCED,
or UNCHANGED, and use that reduced residual set as the Phase 3 starting scope.

### Phase 3: Storage Side-Effect Resources

Owns items 5 and 6. Image load/store and SSBO share descriptor, range, access,
and producer-declaration risks, so they should be diagnosed together but may
land as separate commits if fixes touch different funnels.

Exit: argbuf-on SSBO focused list is green; image load/store argbuf-on delta is
resolved or the remaining non-argbuf-equivalent residual is explicitly
classified with co-review. Then replay downstream items 3, 7, and 8 if they
remain in DCR-5, classify each as CASCADE-CLEARED, CASCADE-REDUCED, or
UNCHANGED, and use that reduced residual set as the Phase 4 starting scope.

### Phase 4: Framebuffer, Blit, DSA, Resolve Tail

Owns items 3, 7, and 8. These are synchronization/readback-heavy and should run
after the core resource descriptors are corrected.

Exit: DCR3C MSAA resolve/readback sentinel is green under argbuf-on, and the
framebuffer blit/DSA focused failures are fixed or classified with exact
argbuf-vs-no-argbuf evidence. The Phase 4 exit replay is the final DCR-5
residual set.

## Phase Exit Co-Review

Foreman+Clerk co-review happens at the four phase exits, not every mini-rung
commit. Mini-rung SHA-confirms remain Foreman-procedural. At each phase exit:

- Apply cross-family cascade replay as scope compression, not just
  verification.
- Classify each downstream item as:
  - CASCADE-CLEARED: prior fix made the item exit-clean.
  - CASCADE-REDUCED: only the reduced residual carries to the owning phase.
  - UNCHANGED: the original residual carries forward.
- Use the cascade residual, not the original enumeration, as the next phase's
  starting scope.
- Record the Hard-NS sister attestation: unchanged, unlocked, or superseded.
- Preserve the don't-crown lock; only SCOUT-W owns the final gate-of-record.

## Gate Plan

The DCR-5 driver must apply the compile-gating discipline from the start:
Section 108 hash semantics, Section 109 source/build ifdef discipline, and the
Section 91 compile-gate-aware split.

### Per-Fix Rung

- `git diff --check`.
- Explicit production hook-off rebuilds:
  - `cmake --build build-release --target AppGL appgl_gauntlet_cli -j8`
  - `cmake --build build-release-fp64on --target AppGL appgl_gauntlet_cli -j8`
- Explicit hook-enabled rebuilds when red-stub sentinels are needed:
  - `build-release-dcrhooks`
  - `build-release-fp64on-dcrhooks`
- Capture old/new SHA256 and UUID for release and fp64-on dylibs.
- Include bidirectional binary-string proof at each per-rung SHA-confirm:
  production hook-off dylibs must contain zero DCR hook strings, and
  hook-enabled dylibs must contain the expected nonzero DCR hook-string set.
- If runtime source changed, a dylib hash change is expected and must be
  distinguished from stale-build risk by the rebuild logs.
- If a rung is test/docs only, unchanged production hashes are expected and
  must be stated.
- Run only production hook-off dylibs for CTS conformance results.
- Run hook-enabled dylibs only for DCR red-stub sentinel checks and composition
  harness checks that need compile-gated hooks.
- Record P->F, P->NonPass, NonPass->P, and newly red sentinel status versus the
  accepted comparator for the affected family.
- Keep artifact roots under
  `tests/reports/s22-fantastic-rebuild/DCR5-<rung>-<shortsha>/`.

Foreman SHA-confirm cadence: request Foreman SHA-confirm at each completed
mini-rung commit, not only at the end. Each commit is a Section 106 fix-path
event; the final aggregate is the Section 108 commit-stability proof. DCR-5 is
expected to be multi-commit and the fixes touch shared binding/synchronization
funnels, so per-rung confirmation keeps stale-build detection close to the
source change. A final aggregate confirm still precedes SCOUT-W routing.

### Final DCR-5 Gate

Production hook-off release and fp64-on:

- All remaining DCR-5 item case lists under `APPGL_ENABLE_ARGUMENT_BUFFERS=1`.
- No-argbuf guard runs for the same families where the entry baseline was not
  argbuf-only.
- Full tessellation case list, because item 2 is a 103-case cluster.
- Focused shader image load/store and SSBO lists.
- Focused framebuffer blit, DSA framebuffer, read-pixels, buffer-storage
  read-pixels, and texture-buffer framebuffer-readback lists.
- DCR4-F composition harness `--argbuf=on` may run against hook-enabled dylibs
  for red-stub parity, but any CTS conformance claim comes from production
  hook-off dylibs.

Hook-enabled release and fp64-on:

- `dcr3-sentinels`.
- `dcr3c-sentinels`, with emphasis on MSAA resolve/readback checks.
- `dcr4c-sentinels`.
- `dcr4d-sentinels`, with emphasis on atomic tess fallback.
- `dcr4e-sentinels`.
- DCR4-F composition harness `--argbuf=off` and `--argbuf=on`.

Required proof:

- Production hook strings remain absent.
- Hook-enabled test strings remain present.
- Bidirectional binary-string proof is present for the final aggregate:
  production equals zero DCR hook strings and hook-enabled equals the expected
  nonzero DCR hook-string set.
- Dyld proof shows gauntlet and harness binaries loading the packaged dylib.
- `SHA256SUMS` covers the final package.
- The Hard-NS sister register note is carried forward unchanged or updated with
  new evidence.

## Exit Criteria

DCR-5 can be routed to SCOUT-W when:

1. The remaining tractable DCR-5 items are green under their scoped argbuf-on
   gate, or any remaining item has an exact co-reviewed split between fixed
   argbuf behavior and a separate non-argbuf-equivalent residual.
2. No new production hook-off no-argbuf P->F or P->NonPass deltas are present.
3. No DCR4-F/G composition property regresses.
4. Section 91 production-vs-hook test split is visible in the artifact.
5. SHA/UUID, dyld, string-proof, and diff-check artifacts are complete.
6. The Hard-NS sister item and family-order quarantine are explicitly carried
   forward for S22 close review.
