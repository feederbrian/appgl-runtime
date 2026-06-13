# S25 W2 §3 — Temporal Center-Snapshot (confound-free wipe-vs-sky resolver)

Obs-only, gated under the SAME latch as §1/§2 (`APPGL_W2_SURVIVAL_CONTENT_PROBE=1`);
default-OFF; matrix-safe. **Authoritative resolver — supersedes §2.**

## Why §2 was retracted (the confound)

§2 (drawOver/benignSky) classified a `contentMissing` frame by whether any post-3D
drawable activity occurred. Foreman's autogame run (s25-content-passtrace,
run-20260613T151153Z) showed `contentPresentWithPost3DDraw` ≡ `lean3DContentPresent`
at **every** per-interval record (24/24, 53/53, 89/89, 143/143, 173/173): the
HUD/overlay pass runs on 100% of frames. So `benignSky` (= missing AND *no* post-3D
activity) is **structurally unreachable** → `benignSky=0` is forced by frame
structure, not evidence → `drawOver ≡ contentMissing` → §2 adds zero power over §1.
Root cause of the validation-miss: the §2 benign-sky control had **no overlay**, so
it discriminated trivially; real WZ always has the overlay. §2 counts post-3D
activity *anywhere*; the question is whether it covers the scene-CENTER.

## §3 design (immune to the confound)

Compare the scene-center PIXEL at two times:
- **T1** = center 8×8 blitted at the close of the last drawable pass that contained
  a lean-3D landing — i.e. the moment the overlay pass opens, BEFORE it over-draws.
  Hook: `captureTemporalT1IfPending()` in `noteDrawablePassOpenForSurvival` (the
  previous render encoder is already ended, so a blit encoder is safe). The §2
  ViaPass finding (a separate post-3D drawable pass exists every frame) is what
  makes T1 capturable. Latest-wins ⇒ T1 = center after the last 3D pass.
- **T2** = center at present (the existing §1 blit).

Both compared to the frame's clear color in the present CB's completion handler.
On a missing frame (T2 clear ≥75%):

| T1 | T2 | verdict |
|----|----|---------|
| non-clear | clear | **REAL WIPE** — center HAD 3D, then lost it (`contentMissingWipeConfirmed`) |
| clear | clear | **BENIGN SKY** — 3D never drew the center (`contentMissingSkyConfirmed`) |
| (no T1) | clear | `contentMissingT1Unavailable` — no pre-overlay snapshot (honest) |

Immune to the universal-overlay confound: T1 is captured **before** the overlay, and
it reads the SAME center pixel at two times — a HUD that draws edges every frame
cannot change the center-pixel comparison.

## Validation (`s25-w2-3-temporal-validation`, both green) — confound-MATCHING

The discipline that the §2 control violated: **both controls carry an identical
universal center-covering overlay** (a depth-only clear forces a separate post-3D
pass; a fullscreen blue draw paints the clear color over the center — the same in
both). The ONLY difference is whether the 3D covered the center first (T1):

- **WIPE control:** 3D (red) covers the center (T1 non-clear) → overlay clears it
  (T2 clear) ⇒ `wipeConfirmed > 0`, `skyConfirmed == 0`.
- **SKY control:** 3D (red) off-center (T1 clear) + the SAME overlay (T2 clear) ⇒
  `skyConfirmed > 0`, `wipeConfirmed == 0` (no false-wipe).

Proving discrimination WITH the overlay present is the whole point — §2 failed by
omitting it. (§2 would call BOTH controls drawOver; §3 splits them on T1.)

## Field methodology (the wipe is INTERMITTENT)

Foreman: the autogame spectator-auto-scroll wipe is probabilistic + brief (cMISS
swung 0 → 6 → 30 across runs; ~3-15% of frames when it fires, some runs none) — NOT
deterministic-same-frames, and far briefer than the operator's "blue most of the
time." So: **a B run must verify `lean3DContentMissing > 0` before its verdict is
trusted; re-run until it wipes.** B (per-frame) is the primary arbiter — a coarse
async screencapture burst can miss a 6-frame wipe and instead catch the static
game-over MENU (which the FBO gameplay-gate excludes from cMISS).

The autogame-rate-vs-operator-"most-of-the-time" gap is most likely the SAME
draw-over mechanism at different motion-intensity (manual pan > auto-scroll). If §3
confirms WIPE, the operator's post-fix confirmation run is **RECOMMENDED** (not just
optional) to verify the fix generalizes to the higher-rate manual-pan case.

## Eyeball (opt-in, `APPGL_W2_SURVIVAL_IMAGE_DIR`)

On the FIRST §3-confirmed-wipe frame, the T1 and T2 center pixels are written
16×-upscaled side-by-side to `<dir>/w2-wipe-T1-T2.ppm` (256×128). Left = T1, right
= T2 — an unimpeachable single-frame proof (content → clear) on the EXACT wiped
frame, with no game-over-menu confusion (the failure mode of a coarse async
full-frame screencapture). Default-OFF: no env ⇒ no file writes (the matrix and
gauntlet controls leave the filesystem untouched). One-shot per run. Validated:
the wipe-control emits T1=(255,0,0) red / T2=(0,0,255) blue — faithful.

## Field result (2026-06-13): autogame = BENIGN SKY, not wipe

Foreman ran the run-until-wipe loop on the §3 SHA: 8 runs, 5 verified-wipe
(cMISS 32–88), §3 UNANIMOUS **WIPE=0 / SKY=100% / T1unavailable=0**. The
autogame's spectator-phase center-clear is the auto-scroll camera at sky (T1
already clear ⇒ the 3D never drew the center), NOT a draw-over wipe. §1 (real
center-clear) + §2 (confounded drawOver) were false leads; §3 resolved them. The
autogame does NOT reproduce the operator's manual-pan wipe (it has no camera
control) — the operator's wipe is real (reported "blue most of the time" / "stale/
sparse 3D" during pan) and needs the operator's pan conditions under §3 + eyeball.

## Matrix-safety

43+2-phase sweep: every parallel-encode/lean/survival/present phase green + the new
§3 validation phase green; the 6 failures (dcr4c/d/e GS-mesh, phase-7/a/c
smoke-coverage) are pre-existing and unrelated — all §3 code is behind the latch.
