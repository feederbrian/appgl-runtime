# S25 W2 §2 — Drawable-Pass Trace (draw-over-vs-sky localizer)

Obs-only extension of the §1 survival content probe. Gated under the SAME env
latch (`APPGL_W2_SURVIVAL_CONTENT_PROBE=1`); default-OFF; matrix-safe.

## The residual it closes

§1 proved: through the autogame spectator phase (sp196-270 of the 5754c36
content-run), the lean-3D draw LANDS on the presented drawable every frame
(`drawableMatched`/`leanInPresentedCB`/`lean3DSurvived` all +30/interval) YET
the scene-CENTER reads the clear color (`lean3DContentMissing` climbs to 30/30,
`lean3DContentPresent` frozen). Structural-survived + content-clear is the
draw-over signature — but the structural counters cannot separate:

- **DRAW-OVER (real wipe):** a later drawable pass painted the clear color over
  the 3D. A **Load**-action pass open does NOT reset `drawableLastWriteWas3D`
  (only Clear/DontCare does), so "survived" stays high while the center is wiped.
- **BENIGN SKY:** the last lean-3D draw landed, but the center it produced is
  the clear color (the 3D pass cleared, geometry drew OFF-center — a camera
  framing empty terrain). No over-draw.

FBO-up (133→165 across the spectator boundary) argues against a wholly-empty
view, but the center specifically could still be sky. The trace resolves it
directly and localizes the over-drawing pass for the fix.

## Design (the load-bearing choices)

Per frame, record what touched the drawable AFTER the first lean-3D landing
("Post3D"): new drawable passes (by load action) + non-3D default-FB draws.

- **Latch-once, NOT reset-per-landing.** A later lean overlay draw must not
  erase the over-draw signal — that is the exact blindness the structural
  counter has. The window latches on the first lean-3D landing and holds.
- **Decrement-lean.** The per-draw census tentatively counts every default-FB
  draw; a lean-3D landing then decrements its own tentative count (a 3D draw is
  not an over-draw). So only NON-3D drawable draws persist.
- **Pass-open census is robust to lean overlay draws** (the open is counted
  before any lean draw in the new pass), so a separate UI/overlay-compositing
  pass is caught even when its draws are lean — the representative real case.

Cross-tabulated against the §1 verdict in the probe's async completion handler:

| §1 verdict | Post3D Load-pass or non-3D draw | bucket |
|---|---|---|
| missing | yes | `contentMissingDrawOver` (+`ViaPass`/`ViaDraw` split) |
| missing | no | `contentMissingBenignSky` |
| present | yes | `contentPresentWithPost3DDraw` (context) |

`ViaPass` = separate post-3D drawable pass (UI/overlay) — the likely fix target.
`ViaDraw` = serial post-3D draw in an existing pass.

## Known blind spot (honest)

A draw-over issued as a **lean draw in the SAME pass as the 3D** (no new pass
open) is decremented like a 3D draw → reads zero. So an **all-zero Post3D on a
contentMissing frame is INCONCLUSIVE** (benign-sky OR same-pass-lean-over-draw),
NOT proof of benign sky. If the autogame lands there, the next instrument is a
temporal pixel snapshot (center-after-3D-pass vs center-at-present), or an
operator pan-run. A SEPARATE-pass over-draw is caught robustly.

## Validation (`s25-w2-2-pass-trace-validation`, both green)

- **DRAW-OVER positive control:** red 3D (lean) covers center, then a SERIAL
  (SSBO-side-effect ⇒ lean-ineligible) over-draw paints the clear color over it.
  → `contentMissingDrawOver` > 0.
- **BENIGN-SKY negative control:** red 3D draws off-center (corner triangle),
  center stays clear, no over-draw. → `contentMissingBenignSky` > 0 AND
  `contentMissingDrawOver` == 0 (no false-positive — the key anti-bias guard).

Note: the pass-census path (`ViaPass`) is not independently positive-controlled
— the synthetic separate-pass-overwrite construction (FBO interlude) did not
composite the post-interlude pass into the presented frame. It feeds the same
bucket logic as the validated draw-census path; on real data both paths are live.

## Matrix-safety

Full 43-phase sweep: every parallel-encode / lean / survival / present phase
green; the new validation phase green. The 6 failures (dcr4c/d/e GS-mesh
emulation, phase-7/a/c smoke-coverage) are pre-existing and unrelated — all §2
additions are behind `survivalContentProbeLatched` and inert when off.
