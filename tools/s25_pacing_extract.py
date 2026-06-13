#!/usr/bin/env python3
"""S25 Rung-1 readings extractor (UNCOMMITTED scratch — keep off the pin).

Reads a periodic diagnostics JSONL capture (one JSON object per line, the
autogame wrapper's poll stream) and reduces the S25 instrument sections to
the readings-packet numbers. Everything in the stream is CUMULATIVE; this
tool works on first→last deltas (and per-interval deltas for percentile
stability checks).

Usage: s25_pacing_extract.py <capture.jsonl> [--intervals]
"""

import json
import sys


def find_key(obj, key):
    """Depth-first search for the first occurrence of key in nested dicts."""
    if isinstance(obj, dict):
        if key in obj:
            return obj[key]
        for v in obj.values():
            hit = find_key(v, key)
            if hit is not None:
                return hit
    elif isinstance(obj, list):
        for v in obj:
            hit = find_key(v, key)
            if hit is not None:
                return hit
    return None


def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def hist_delta(first, last):
    d = {}
    for k, v in (last or {}).items():
        dv = v - (first or {}).get(k, 0)
        if dv > 0:
            d[int(k)] = dv
    return dict(sorted(d.items()))


def percentile(hist, p):
    """p in [0,1] from a {ms_bucket: count} delta histogram (1ms buckets)."""
    total = sum(hist.values())
    if total == 0:
        return None
    target = p * total
    seen = 0
    for ms, n in hist.items():
        seen += n
        if seen >= target:
            return ms
    return max(hist)


def main():
    path = sys.argv[1]
    rows = load(path)
    pacing_rows = [(r, find_key(r, "framePacing")) for r in rows]
    pacing_rows = [(r, p) for r, p in pacing_rows if p]
    if not pacing_rows:
        print("no framePacing sections found")
        return
    first_row, first = pacing_rows[0]
    last_row, last = pacing_rows[-1]

    fp_first, fp_last = first.get("pacing", {}), last.get("pacing", {})
    frames = fp_last.get("frames", 0) - fp_first.get("frames", 0)
    total_us = fp_last.get("frameTimeUsTotal", 0) - fp_first.get("frameTimeUsTotal", 0)
    hist = hist_delta(fp_first.get("histMs"), fp_last.get("histMs"))

    print(f"== PACING (delta over {len(pacing_rows)} intervals) ==")
    print(f"frames={frames}")
    if frames:
        print(f"avg_ms={total_us / frames / 1000.0:.3f}  "
              f"fps={frames / (total_us / 1e6):.1f}" if total_us else "")
        print(f"p50_ms={percentile(hist, 0.50)}  p90_ms={percentile(hist, 0.90)}  "
              f"p99_ms={percentile(hist, 0.99)}  p99.9_ms={percentile(hist, 0.999)}  "
              f"max_ms={fp_last.get('frameTimeUsMax', 0)/1000.0:.1f}")
        for tier in ("hitch25", "hitch50", "hitch100"):
            d = fp_last.get(tier, 0) - fp_first.get(tier, 0)
            print(f"{tier}={d} ({d / frames * 100:.2f}%/frame)")

    # Main-thread stall share: wait-kind µs deltas vs wall time.
    cb_first = find_key(first_row, "commandBuffers") or {}
    cb_last = find_key(last_row, "commandBuffers") or {}
    print("\n== STALL (GL-thread blocking µs, delta) ==")
    stall_total = 0.0
    for k in ("inFlightTokenWaitUsTotal", "ringSlotWaitUsTotal",
              "completionWaitUsTotal", "drainAllWaitUsTotal"):
        d = cb_last.get(k, 0) - cb_first.get(k, 0)
        stall_total += d
        print(f"{k}={d}")
    dw = last.get("drawableWaitUs", 0) - first.get("drawableWaitUs", 0)
    stall_total += dw
    print(f"drawableWaitUs={dw}")
    if total_us:
        print(f"stall_share={stall_total / total_us * 100:.2f}% of frame wall")

    # Copy-headroom (arm b).
    ch_first, ch_last = first.get("copyHeadroom"), last.get("copyHeadroom")
    if ch_last:
        print("\n== COPY-HEADROOM (delta) ==")
        for bucket in ("fb0", "fbo"):
            bf, bl = (ch_first or {}).get(bucket, {}), ch_last.get(bucket, {})
            draws = bl.get("draws", 0) - bf.get("draws", 0)
            if not draws:
                print(f"{bucket}: draws=0")
                continue
            fill_us = bl.get("fillUsTotal", 0) - bf.get("fillUsTotal", 0)
            fills = bl.get("fillSuccesses", 0) - bf.get("fillSuccesses", 0)
            attempts = bl.get("fillAttempts", 0) - bf.get("fillAttempts", 0)
            retains = bl.get("retains", 0) - bf.get("retains", 0)
            retain_us = bl.get("retainUsTotal", 0) - bf.get("retainUsTotal", 0)
            ubytes = bl.get("uniformBytes", 0) - bf.get("uniformBytes", 0)
            ibytes = bl.get("inlineUboBytes", 0) - bf.get("inlineUboBytes", 0)
            th = bl.get("textureHandles", 0) - bf.get("textureHandles", 0)
            bh = bl.get("bufferHandles", 0) - bf.get("bufferHandles", 0)
            print(f"{bucket}: draws={draws}"
                  + (f" fill_us_per_attempt={fill_us/attempts:.3f}"
                     f" fill_success_rate={fills/attempts*100:.1f}%" if attempts else "")
                  + (f" retain_us_per_draw={retain_us/draws:.3f}"
                     f" retains_per_draw={retains/draws:.2f}" if retains else "")
                  + f" uniformB/draw={ubytes/draws:.0f} inlineUboB/draw={ibytes/draws:.0f}"
                  + f" tex/draw={th/draws:.2f} buf/draw={bh/draws:.2f}")
        fb0 = ch_last.get("fb0", {})
        fbo = ch_last.get("fbo", {})
        tot = fb0.get("draws", 0) + fbo.get("draws", 0)
        if tot:
            print(f"FBO share of draws: {fbo.get('draws', 0)/tot*100:.1f}% (cumulative)")
        rel = ch_last.get("releaseUsTotal", 0) - (ch_first or {}).get("releaseUsTotal", 0)
        print(f"releaseUs={rel} arenaPeak={ch_last.get('arenaPeak', 0)} "
              f"drains={ch_last.get('arenaDrains', 0)}")
        # Site-split (commit C, 65666b4+): name-keyed fill-failure map, fb0 real fills only.
        ff_f = (ch_first or {}).get("fillFailBySite", {})
        ff_l = ch_last.get("fillFailBySite", {})
        ff = {k: ff_l.get(k, 0) - ff_f.get(k, 0) for k in ff_l}
        ff = {k: v for k, v in ff.items() if v > 0}
        ff_total = sum(ff.values())
        if ff_total:
            print("fillFailBySite:", {k: f"{v} ({v/ff_total*100:.1f}%)"
                                      for k, v in sorted(ff.items(), key=lambda x: -x[1])})
            attempts0 = ch_last.get("fb0", {}).get("fillAttempts", 0) - \
                (ch_first or {}).get("fb0", {}).get("fillAttempts", 0)
            if attempts0:
                print(f"fill_fail_total={ff_total} ({ff_total/attempts0*100:.1f}% of fb0 attempts)")
        # Sub-reason split inside plan_missing_or_mismatch (commit D+).
        ps_f = (ch_first or {}).get("planFailBySubReason", {})
        ps_l = ch_last.get("planFailBySubReason", {})
        ps = {k: ps_l.get(k, 0) - ps_f.get(k, 0) for k in ps_l}
        ps = {k: v for k, v in ps.items() if v > 0}
        ps_total = sum(ps.values())
        if ps_total:
            print("planFailBySubReason:", {k: f"{v} ({v/ps_total*100:.1f}%)"
                                           for k, v in sorted(ps.items(), key=lambda x: -x[1])})
            plan_total = ff.get("plan_missing_or_mismatch", 0)
            if plan_total and ps_total != plan_total:
                print(f"WARN: sub-reason sum {ps_total} != plan_missing_or_mismatch {plan_total}")

    # Record-plan memo (W2, commit E+).
    rp_f, rp_l = first.get("recordPlanMemo", {}), last.get("recordPlanMemo", {})
    if rp_l:
        print("\n== RECORD-PLAN MEMO (W2, delta) ==")
        for k in ("hits", "misses", "buildFails", "evictions",
                  "verifyMismatches"):
            print(f"{k}={rp_l.get(k, 0) - rp_f.get(k, 0)}")
        print(f"size={rp_l.get('size', 0)} peak={rp_l.get('peak', 0)}")
        h = rp_l.get("hits", 0) - rp_f.get("hits", 0)
        m = rp_l.get("misses", 0) - rp_f.get("misses", 0)
        if h + m:
            print(f"hit_rate={h/(h+m)*100:.1f}%")

    # Present-vs-lean-landing localization (W2.1 live-defect instrument).
    pl_f = first.get("presentLeanLanding", {})
    pl_l = last.get("presentLeanLanding", {})
    if pl_l:
        print("\n== PRESENT-LEAN-LANDING (W2.1 localization, delta) ==")
        keys = ("swapPresents", "withLeanEncoded", "drawableMatched",
                "drawableMismatched", "leanInPresentedCB", "leanInPriorCB",
                "candidatesButZeroEncoded", "lean3DSurvived",
                "lean3DOverwritten", "lean3DContentPresent",
                "lean3DContentMissing", "contentExcludedNonGameplay",
                "contentMissingDrawOver", "contentMissingDrawOverViaPass",
                "contentMissingDrawOverViaDraw", "contentMissingBenignSky",
                "contentPresentWithPost3DDraw",
                "contentMissingWipeConfirmed", "contentMissingSkyConfirmed",
                "contentMissingT1Unavailable",
                "spatialPresentFrames", "spatialDegradedFrames")
        d = {k: pl_l.get(k, 0) - pl_f.get(k, 0) for k in keys}
        for k in keys:
            print(f"{k}={d[k]}")
        wl = d["withLeanEncoded"]
        if wl:
            print(f"drawable_match_rate={d['drawableMatched']/wl*100:.2f}%  "
                  f"in_presented_cb_rate={d['leanInPresentedCB']/wl*100:.2f}%")
            print(f"SURVIVAL structural: survived={d['lean3DSurvived']/wl*100:.2f}%  "
                  f"overwritten={d['lean3DOverwritten']/wl*100:.2f}%")
            cp = d["lean3DContentPresent"]; cm = d["lean3DContentMissing"]
            ct = cp + cm
            if ct:
                print(f"SURVIVAL §1 CONTENT: present={cp/ct*100:.2f}%  "
                      f"MISSING={cm/ct*100:.2f}%  (sampled={ct})")
            # §2 pass-trace (CONFOUNDED on real data — kept for contrast only):
            # presentWithPost3DDraw≡present ⇒ universal overlay ⇒ benignSky
            # unreachable ⇒ drawOver≡missing. NOT authoritative; §3 is.
            do = d["contentMissingDrawOver"]; bs = d["contentMissingBenignSky"]
            pp = d["contentPresentWithPost3DDraw"]
            if cm:
                via_p = d["contentMissingDrawOverViaPass"]
                via_d = d["contentMissingDrawOverViaDraw"]
                confounded = (pp == cp)  # post-3D activity on 100% of present frames
                print(f"SURVIVAL §2 (contrast): drawOver={do} "
                      f"(viaPass={via_p}/viaDraw={via_d}) benignSky={bs}"
                      + ("  ⚠CONFOUNDED (presentWithPost3DDraw==present ⇒ universal "
                         "overlay ⇒ benignSky unreachable ⇒ NOT authoritative)"
                         if confounded else ""))
            # §3 TEMPORAL (CONFOUND-FREE — authoritative): T1 (pre-overlay center)
            # vs T2 (present center). wipe = center HAD 3D then lost it; sky = 3D
            # never drew the center.
            wipe = d["contentMissingWipeConfirmed"]
            sky = d["contentMissingSkyConfirmed"]
            t1na = d["contentMissingT1Unavailable"]
            if cm:
                print(f"SURVIVAL §3 RESIDUAL (authoritative): of {cm} missing — "
                      f"WIPE={wipe}  SKY={sky}  T1unavailable={t1na}")
                if wipe > sky and wipe > 0:
                    print("  VERDICT: REAL WIPE confirmed — the scene-center had 3D "
                          "content BEFORE the overlay (T1 non-clear) and reads clear "
                          "at present (T2). Parallel-encode over-draw. → fix.")
                elif sky > 0 and wipe == 0:
                    print("  VERDICT: BENIGN SKY — the 3D never drew the center "
                          "(T1 already clear). The autogame's center-clear is not a "
                          "wipe → genuine reopen (operator's defect is elsewhere).")
                elif t1na >= cm and cm > 0:
                    print("  VERDICT: T1 UNAVAILABLE on all missing frames — no "
                          "pre-overlay snapshot captured; cannot temporally resolve "
                          "(investigate the T1 hook on this path).")
            else:
                print("  (no missing frames this run — §3 idle; the wipe is "
                      "INTERMITTENT, re-run until lean3DContentMissing>0)")
            print("READ: §1 contentMissing ⇒ scene-center reads CLEAR. §3 "
                  "(authoritative) splits WHY via the center pixel at two times: "
                  "WIPE (T1 nonclear→T2 clear) vs SKY (T1 clear→T2 clear). §2 is "
                  "confounded by the universal overlay. (Needs "
                  "APPGL_W2_SURVIVAL_CONTENT_PROBE=1; wipe is intermittent.)")

        # §4 SPATIAL (LEAN-AGNOSTIC — works serial + parallel). Freeze counters =
        # the fault test; the grid = WHERE the 3D is on a degraded frame.
        sp = d.get("spatialPresentFrames", 0); sd = d.get("spatialDegradedFrames", 0)
        if sp or sd:
            tot = sp + sd
            print(f"\n== §4 SPATIAL (lean-agnostic) ==")
            print(f"spatialPresentFrames={sp}  spatialDegradedFrames={sd}  "
                  f"(degraded={sd/tot*100:.1f}% of {tot} gameplay frames)")
            print("FREEZE/FAULT: degraded-dominant + present-frozen = the persistent "
                  "corruption. Compare PARALLEL vs SERIAL run-until-freeze: serial "
                  "degraded≈0 (renders clean) ⇒ W2-LEAN-PATH is the cause; serial "
                  "degraded-dominant too ⇒ pre-existing renderer bug (out-of-W2).")
            if pl_l.get("frozenSpatialReady"):
                gi = pl_l.get("frozenGridInner", 0); gt = pl_l.get("frozenGridTotal", 0)
                gm = pl_l.get("frozenGridMap", "")
                print(f"WHERE (frozen frame): frozenGridInner={gi} frozenGridTotal={gt} "
                      f"(of 256 cells; inner=central-quarter viewport)")
                if gi > 0:
                    print("  VERDICT: 3D renders OFF-CENTER (present in the viewport, "
                          "wrong place) ⇒ stale/wrong VIEWPORT or TRANSFORM cached.")
                else:
                    print("  VERDICT: 3D renders NOWHERE (no viewport-center content) ⇒ "
                          "stale/wrong TARGET or null/wrong plan/descriptor.")
                if gm:
                    print("  grid 16x16 (1=content, 0=clear), row-major top→bottom:")
                    for r in range(16):
                        print("    " + gm[r*16:(r+1)*16])
            else:
                print("WHERE: no frozen full-frame captured (no degraded frame after "
                      "onset, or probe off) — re-run until freeze.")
            # §5 batch-pass-state: degraded-vs-present per-flush clear/depth rates.
            dbf = pl_l.get("degradedBatchFlushes", 0)
            pbf = pl_l.get("presentBatchFlushes", 0)
            if dbf or pbf:
                def rate(num, den): return (num / den) if den else 0.0
                dcc = pl_l.get("degradedBatchColorClears", 0)
                ddl = pl_l.get("degradedBatchDepthLoads", 0)
                ddc = pl_l.get("degradedBatchDepthClears", 0)
                pcc = pl_l.get("presentBatchColorClears", 0)
                pdl = pl_l.get("presentBatchDepthLoads", 0)
                pdc = pl_l.get("presentBatchDepthClears", 0)
                print("\n== §5 BATCH-PASS-STATE (degraded vs present, per flush) ==")
                print(f"flushes: degraded={dbf} present={pbf}")
                print(f"color-CLEAR rate: degraded={rate(dcc,dbf):.2f} "
                      f"present={rate(pcc,pbf):.2f}   "
                      f"depth-LOAD rate: degraded={rate(ddl,dbf):.2f} "
                      f"present={rate(pdl,pbf):.2f}   "
                      f"depth-CLEAR rate: degraded={rate(ddc,dbf):.2f} "
                      f"present={rate(pdc,pbf):.2f}")
                dccr, pccr = rate(dcc,dbf), rate(pcc,pbf)
                ddlr, pdlr = rate(ddl,dbf), rate(pdl,pbf)
                if dccr > pccr + 0.05:
                    print("  VERDICT: (b) CLEAR-TIMING — degraded frames read a HIGHER "
                          "color-CLEAR rate ⇒ a late parallel batch clears the 3D away "
                          "(S24-flicker parallel analogue; fix = port a9ccea4 "
                          "frame-boundary-clear discipline to the parallel batch).")
                elif ddlr > pdlr + 0.05:
                    print("  VERDICT: (a) DEPTH-DISCARD — degraded frames LOAD (not "
                          "clear) depth at a higher rate ⇒ stale depth discards the new "
                          "3D fragments (fix = the batch pass depth load/clear).")
                else:
                    print("  VERDICT: batch clear/depth state does NOT differ "
                          "degraded-vs-present ⇒ neither (a) nor (b) at the loadAction "
                          "level — deeper (per-draw depth contents / race); escalate.")
                # §5.1 WIPE-ORDERING (the 3rd-confound gate): a batch color-Clear
                # AFTER a prior batch this frame rendered 3D = the real wipe (vs a
                # benign frame-start clear). + the interposer.
                dca = pl_l.get("degradedBatchClearAfter3D", 0)
                pca = pl_l.get("presentBatchClearAfter3D", 0)
                dec = pl_l.get("degradedEncodeClears", 0)
                pec = pl_l.get("presentEncodeClears", 0)
                dmc = pl_l.get("degradedMidFrameCommits", 0)
                pmc = pl_l.get("presentMidFrameCommits", 0)
                degf = d.get("spatialDegradedFrames", 0)
                presf = d.get("spatialPresentFrames", 0)
                print("\n== §5.1 WIPE-ORDERING + INTERPOSER (per frame) ==")
                print(f"clearAfter3D: degraded={dca} (/{degf}fr={rate(dca,degf):.3f}) "
                      f"present={pca} (/{presf}fr={rate(pca,presf):.3f})")
                print(f"interposer — encodeClears/fr: deg={rate(dec,degf):.2f} "
                      f"pres={rate(pec,presf):.2f}   midFrameCommits/fr: "
                      f"deg={rate(dmc,degf):.2f} pres={rate(pmc,presf):.2f}")
                if rate(dca, degf) > rate(pca, presf) + 0.05 and dca > 0:
                    interp = ("2nd-glClear-mid-frame (encodeClears>1)"
                              if rate(dec, degf) > rate(pec, presf) + 0.05
                              else "NOT a 2nd-glClear (encodeClears same) — "
                                   "re-arm via another interposer, investigate")
                    adv = (" + mid-frame drawable-ADVANCE (frame split across "
                           "drawables)" if rate(dmc, degf) > rate(pmc, presf) + 0.05
                           else "")
                    print(f"  VERDICT: (b)-WIPE CONFIRMED — degraded frames clear "
                          f"color AFTER a prior batch rendered 3D (≫ present). "
                          f"Interposer = {interp}{adv}. → fix site PINNED.")
                else:
                    print("  VERDICT: clearAfter3D NOT higher on degraded ⇒ §5's "
                          "clear-rate was a FIRST-PASS-TYPE confound, NOT a wipe — "
                          "re-examine the mechanism (do NOT fix the clear-timing).")
                # §6 WRONG-PLAN (needs APPGL_W2_PLAN_VERIFY=1): a cache HIT served a
                # plan whose content ≠ fresh-rebuild = MSL-identity-key collision →
                # wrong PSO → encode-but-no-pixels = NOWHERE.
                dvm = pl_l.get("degradedVerifyMismatches", 0)
                pvm = pl_l.get("presentVerifyMismatches", 0)
                vchecks = find_key(last, "verifyChecks")  # latch-engagement proof
                if dvm or pvm or "degradedVerifyMismatches" in pl_l:
                    print("\n== §6 WRONG-PLAN (verify-mismatch, needs APPGL_W2_PLAN_VERIFY=1) ==")
                    print(f"verifyMismatches/frame: degraded={rate(dvm,degf):.3f} "
                          f"({dvm}) present={rate(pvm,presf):.3f} ({pvm})  "
                          f"verifyChecks={vchecks} (latch {'ENGAGED' if (vchecks or 0) > 0 else 'NOT ENGAGED'})")
                    if (vchecks or 0) == 0:
                        print("  ⚠ verifyChecks=0 ⇒ APPGL_W2_PLAN_VERIFY did NOT engage "
                              "— a 0-mismatch is a FALSE-NEGATIVE. Re-run with the latch "
                              "actually set before launch.")
                    elif dvm == 0:
                        print("  VERDICT: latch ENGAGED + degraded verifyMismatches=0 ⇒ "
                              "the cached plans are CORRECT (NOT a wrong-plan) ⇒ PIVOT to "
                              "the child-encoder shared-state-application ALT (fits "
                              "whole-scene-gone: one wrong shared state wipes all draws).")
                    elif rate(dvm, degf) > rate(pvm, presf) + 0.01:
                        permf = rate(dvm, degf)
                        if permf >= 5.0:
                            shape = ("MANY mismatches/frame ⇒ the MSL-collision hits "
                                     "most post-pan draws ⇒ directly explains WHOLE-"
                                     "SCENE-GONE. CLEAN wrong-plan.")
                        else:
                            shape = ("FEW mismatches/frame but whole-scene-gone ⇒ "
                                     "wrong-plan is REAL but INSUFFICIENT alone ⇒ a "
                                     "shared-state AMPLIFICATION (one wrong-PSO draw "
                                     "corrupts shared child-encoder/pipeline state → all "
                                     "subsequent draws fail). Fix needs BOTH.")
                        print(f"  VERDICT: WRONG-PLAN CONFIRMED (degraded≫present, "
                              f"{permf:.1f}/frame) — cached plan content ≠ fresh rebuild "
                              f"= MSL-identity-key collision → non-null-but-WRONG (per "
                              f"operator: DEGENERATE → no fragments) PSO → NOWHERE. "
                              f"{shape} FIX = recordPlanIdentityKey → CONTENT hash "
                              f"(:20584), stays parallel.")
                    else:
                        print("  VERDICT: verifyMismatches present but NOT degraded≫present "
                              "⇒ background mismatches, not the freeze cause — re-examine.")
                # §7 CHILD-ENCODER APPLIED-STATE: the descriptor is correct (§6) but
                # the per-draw applied state can be degenerate (scissor 1x1 clips all).
                dsd = pl_l.get("degradedScissorDegen", 0); psd = pl_l.get("presentScissorDegen", 0)
                ddn = pl_l.get("degradedDepthStateNull", 0); pdn = pl_l.get("presentDepthStateNull", 0)
                dld = pl_l.get("degradedLeanDraws", 0); pld = pl_l.get("presentLeanDraws", 0)
                samp = pl_l.get("degenSample")
                if dld or pld or "degradedScissorDegen" in pl_l:
                    print("\n== §7 CHILD-ENCODER APPLIED-STATE (degraded vs present) ==")
                    print(f"lean-3D draws: degraded={dld} present={pld}")
                    print(f"scissorDegenerate(1x1): degraded={dsd} ({rate(dsd,dld)*100:.1f}% of dg draws) "
                          f"present={psd} ({rate(psd,pld)*100:.1f}%)")
                    print(f"depthStateNull: degraded={ddn} ({rate(ddn,dld)*100:.1f}%) "
                          f"present={pdn} ({rate(pdn,pld)*100:.1f}%)")
                    if samp:
                        print(f"  degenSample (first degenerate draw): {samp}")
                    if rate(dsd, dld) > rate(psd, pld) + 0.02 and dsd > 0:
                        print("  VERDICT: DEGENERATE SCISSOR CONFIRMED — degraded lean-3D "
                              "draws compute the 1x1-corner scissor (≫present) ⇒ ALL "
                              "fragments clipped = whole-scene NOWHERE. The degenSample "
                              "names the exact computation (scissorXYWH vs rtWH → "
                              "finalWH≤0). FIX targets the scissor Y-flip/finalW/H "
                              "(metalY = rtH − scissorY − scissorH): likely a wrong/stale "
                              "rtH (colorTexture.height) at the parallel-batch flush vs "
                              "what the GL scissor was set for. Site: encodeLeanDirect…:9996.")
                    elif rate(ddn, dld) > rate(pdn, pld) + 0.02 and ddn > 0:
                        print("  VERDICT: DEPTH-STATE-NULL higher on degraded ⇒ the depth-"
                              "stencil state isn't applied to the child encoder on bad "
                              "frames — investigate descriptor.depthStencilState / "
                              "passDepthStencil on the degraded batch.")
                    elif dld > 0 and dsd == 0 and ddn == 0:
                        print("  VERDICT: scissor + depth-state CLEAN on degraded draws ⇒ "
                              "the applied state is correct too — the suppression is "
                              "elsewhere (blend/color-write-mask in the PSO, or a "
                              "parallel child-encoder concurrency hazard). Re-examine.")
                # §8-(b) A/B FORCE-BATTERY: the arm whose degraded RATE → 0 (while
                # control stays frozen) = the causal suppressor. Engagement
                # (forced* > 0) must hold or the arm never actually applied.
                ab = pl_l.get("abBattery")
                if ab:
                    dba = ab.get("degradedByArm", [0, 0, 0])
                    pba = ab.get("presentByArm", [0, 0, 0])
                    names = ["control", "depthAlways", "fullColor"]
                    print("\n== §8-(b) A/B FORCE-BATTERY (per-arm freeze rate) ==")
                    print(f"  usesOffscreenTarget={ab.get('usesOffscreenTarget')} "
                          "(0 ⇒ (a) wrong-target moot — data-confirmed)")
                    print(f"  engagement: forcedDepthAlways={ab.get('forcedDepthAlways')} "
                          f"forcedFullColor={ab.get('forcedFullColor')} "
                          f"(variant-missing={ab.get('forcedFullColorMissing')})")
                    print(f"  rebuilds deg/pres={ab.get('degradedRebuilds')}/"
                          f"{ab.get('presentRebuilds')}  resizes={ab.get('degradedResizes')}/"
                          f"{ab.get('presentResizes')}  (0/0 expected on autogame; nonzero only "
                          "under an operator pan = rebuild-then-load live)")
                    rates = []
                    for i, n in enumerate(names):
                        tot = dba[i] + pba[i]
                        r = rate(dba[i], tot)
                        rates.append(r)
                        print(f"  arm{i} {n:11s}: degraded={dba[i]} present={pba[i]} "
                              f"freeze-rate={r * 100:.1f}%")
                    ps = ab.get("passiveSample")
                    if ps:
                        print(f"  passiveSample (a degraded lean-3D draw): "
                              f"blendEnabled={ps.get('blendEnabled')} "
                              f"maskRGBA={ps.get('maskRGBA')}")
                    ctrl = rates[0]
                    restorers = [i for i in (1, 2)
                                 if ctrl - rates[i] > 0.15 and (dba[i] + pba[i]) > 0]
                    eng_ok = (ab.get("forcedDepthAlways", 0) > 0 or
                              ab.get("forcedFullColor", 0) > 0)
                    if not eng_ok:
                        print("  VERDICT: NO arm engaged (forced*=0) ⇒ the battery never "
                              "applied — run did not exercise the lean path; re-run.")
                    elif not restorers:
                        print("  VERDICT: NO arm restores (all freeze-rates ≈ control) ⇒ NOT "
                              "depth-reject, NOT color-mask/blend → the lean draws produce no "
                              "visible output for another reason (geometry/MVP-degenerate or "
                              "shader-output-nothing) → GPU-marker / next probe.")
                    else:
                        win = min(restorers, key=lambda i: rates[i])
                        if win == 1:
                            print("  VERDICT: arm1 depth-ALWAYS RESTORES ⇒ the lean 3D was "
                                  "DEPTH-REJECTING (non-rebuild path; rebuilds=0 on autogame) → "
                                  "fix the lean-pass depth compare/contents. design-before-code.")
                        else:
                            bd = "blend" if (ps and ps.get("blendEnabled")) else "write-mask"
                            print("  VERDICT: arm2 full-color-output RESTORES ⇒ color "
                                  f"SUPPRESSED (passiveSample ⇒ likely {bd}) → fix the W2-prepare "
                                  "mask/blend capture (stale/adjacent glColorMask snapshot). "
                                  "design-before-code.")
                # §9 GEOMETRY/DATA-INTEGRITY: a check whose degraded rate ≫ present
                # = the DATA the lean draws consume is degenerate. Expect
                # degenUniform CLEAN (uniforms deep-copied-safe → points to §9.1 vbuf).
                geo = pl_l.get("geometry")
                if geo:
                    print("\n== §9 GEOMETRY/DATA-INTEGRITY (degraded vs present) ==")
                    print(f"  checks(engagement)={geo.get('checks')}")
                    checks = [
                        ("degenUniform(MVP all-zero/NaN)", "DegenUniform",
                         "wrong/stale MVP @W2-prepare → fix prepare uniform-capture"),
                        ("nullTexture(unbound→discard)", "NullTexture",
                         "stale/null texture @W2-prepare → fix prepare texture-capture"),
                        ("degenDrawParams(zero count)", "DegenDrawParams",
                         "degenerate draw-params @W2-prepare → fix count/mode capture"),
                        ("nullVbuf(null vertex ptr)", "NullVbuf",
                         "null/stale vbuf binding @W2-prepare → fix buffer-ptr capture"),
                    ]
                    pinned = None
                    for label, key, fix in checks:
                        d = geo.get("degraded" + key, 0)
                        p = geo.get("present" + key, 0)
                        print(f"  {label:34s}: degraded={d} present={p}")
                        if d > 0 and d > p * 2:
                            pinned = (label, fix)
                    s = geo.get("sample")
                    if s:
                        mvp = s.get("mvp", [])
                        print(f"  sample: vertexCount={s.get('vertexCount')} "
                              f"indexCount={s.get('indexCount')} "
                              f"instanceCount={s.get('instanceCount')} mode={s.get('mode')} "
                              f"vbufPtr={s.get('vbufPtr')} vtxUniformSize={s.get('vtxUniformSize')} "
                              f"fragTex={s.get('fragTexCount')}")
                        if len(mvp) >= 16:
                            print(f"    mvp diag=[{mvp[0]},{mvp[5]},{mvp[10]},{mvp[15]}] "
                                  f"transl=[{mvp[12]},{mvp[13]},{mvp[14]}] "
                                  "(eyeball: zero/garbage/sane?)")
                    if geo.get("checks", 0) == 0:
                        print("  VERDICT: engagement=0 — lean path not exercised; re-run.")
                    elif pinned:
                        print(f"  VERDICT: {pinned[0]} degraded≫present ⇒ PIN → {pinned[1]}")
                    else:
                        print("  VERDICT: §9-gross CLEAN (no degraded≫present degeneracy) — "
                              "EXPECTED for uniforms (deep-copied-safe). The suppression is a "
                              "SUBTLE data bug: the VERTEX-BUFFER content (raw ptr 9314, mutable "
                              "across the deferred-encode window) → run §9.1 vbuf-content-hash "
                              "(record-vs-encode); if that too is clean → Metal frame-capture.")
                    # §9.1 vbuf content-integrity (record-vs-encode hash).
                    vb = geo.get("vbufChecks")
                    if vb:
                        dc = vb.get("degradedChecks", 0); pc = vb.get("presentChecks", 0)
                        dm = vb.get("degradedMismatch", 0); pm = vb.get("presentMismatch", 0)
                        print(f"  §9.1 vbuf-hash: checks deg/pres={dc}/{pc}  "
                              f"mismatch deg/pres={dm}/{pm}")
                        vs = vb.get("sample")
                        if vs:
                            print(f"    mismatch sample: recordHash={vs.get('recordHash')} "
                                  f"encodeHash={vs.get('encodeHash')} vbufPtr={vs.get('vbufPtr')} "
                                  f"offset={vs.get('offset')}")
                        if dc == 0 and pc == 0:
                            print("    §9.1 VERDICT: 0 checks — vbufs not CPU-readable (Private) "
                                  "→ can't hash → Metal frame-capture is the next step.")
                        elif dm > 0 and dm > pm * 2:
                            print("    §9.1 VERDICT: vbuf record≠encode degraded≫present ⇒ "
                                  "STALE-VBUF PIN — the vertex DATA is overwritten in the deferred "
                                  "record→encode window → fix: snapshot/deep-copy the vertex data "
                                  "at record (like the uniforms), or hold the ring-buffer slot "
                                  "until the deferred encode consumes it.")
                        else:
                            print("    §9.1 VERDICT: vbuf content STABLE across record→encode (no "
                                  "mismatch) → NOT the overwrite hazard → Metal frame-capture for "
                                  "a subtle finite-wrong MVP / vertex-data.")
                # §10 FBO-source-readback (EDGE-2: the 3D-FBO the composition samples).
                fbo = geo.get("fboSource")
                if fbo and fbo.get("checks", 0) > 0:
                    dsc = fbo.get("degradedSourceClear", 0)
                    dsco = fbo.get("degradedSourceContent", 0)
                    psc = fbo.get("presentSourceClear", 0)
                    psco = fbo.get("presentSourceContent", 0)
                    dtot = dsc + dsco
                    ptot = psc + psco
                    dcr = rate(dsco, dtot)
                    pcr = rate(psco, ptot)
                    print("\n== §10 FBO-SOURCE-READBACK (the 3D-FBO the composition samples) ==")
                    print(f"  checks={fbo.get('checks')} "
                          f"compositionTexturedDraws={fbo.get('compositionTexturedDraws')}")
                    print(f"  degraded source: content={dsco} clear={dsc} "
                          f"→ content-rate={dcr * 100:.1f}%")
                    print(f"  present  source: content={psco} clear={psc} "
                          f"→ content-rate={pcr * 100:.1f}%")
                    dptr = fbo.get("degradedSourcePtr", 0)
                    pptr = fbo.get("presentSourcePtr", 0)
                    print(f"  source ptr: degraded={dptr} present={pptr}")
                    if dptr and pptr and dptr != pptr:
                        print("  VERDICT: source PTR DIFFERS (degraded≠present) ⇒ the composition "
                              "binds a WRONG/STALE FBO on degraded frames → fix the FBO rebind.")
                    elif ptot > 0 and pcr > 0.5 and pcr - dcr > 0.25:
                        print("  VERDICT: degraded source-content ≪ present (the 3D-FBO is "
                              "CLEAR/empty on degraded while healthy frames hold 3D) ⇒ the 3D-"
                              "RENDER is DROPPED on the FBO-encode path → chase why the lean path "
                              "skips/uncommits the FBO render. design-before-code.")
                    elif dtot > 0 and dcr > 0.5:
                        print("  VERDICT: degraded source HAS 3D content (≈present) but §4 drawable "
                              "is CLEAR ⇒ the FBO is rendered but NOT COMPOSITED = HANDOFF/ORDERING "
                              "(FBO-write→composition-read barrier lost) → (c) CB-ordering follow-"
                              "up → fix = restore the dependency. design-before-code.")
                    else:
                        print("  VERDICT: ambiguous (low rates / no clear delta) — Foreman's Metal "
                              "frame-capture is the ground-truth (or sample >1 readback point).")
                # §11 CB-epoch order: names the FBO-write→composition-read violation.
                eo = geo.get("epochOrder")
                if eo and eo.get("checks", 0) > 0:
                    dra = eo.get("degradedRenderAfterRead", 0)
                    pra = eo.get("presentRenderAfterRead", 0)
                    dsc2 = eo.get("degradedSameCb", 0)
                    psc2 = eo.get("presentSameCb", 0)
                    drb = eo.get("degradedRenderBeforeRead", 0)
                    prb = eo.get("presentRenderBeforeRead", 0)
                    dtot = dra + dsc2 + drb
                    ptot = pra + psc2 + prb
                    print("\n== §11 CB-EPOCH ORDER (FBO-render vs composition-read) ==")
                    print(f"  checks={eo.get('checks')}")
                    print(f"  degraded: renderAfterRead={dra} sameCb={dsc2} "
                          f"renderBeforeRead={drb}")
                    print(f"  present : renderAfterRead={pra} sameCb={psc2} "
                          f"renderBeforeRead={prb}")
                    drar = rate(dra, dtot)
                    prar = rate(pra, ptot)
                    if dra > 0 and drar - prar > 0.15:
                        print("  VERDICT: degraded renderAfterRead ≫ present ⇒ SMOKING GUN — "
                              "the FBO is RENDERED on a LATER CB than the composition READS it "
                              "(out-of-order: composition's CB read the FBO before the FBO-render "
                              "CB's writes landed). FIX = enforce same-CB-after the FBO-render at "
                              "the composition flush (re-apply C49 to the deferred/parallel path).")
                    elif drb > 0 and rate(drb, dtot) - rate(prb, ptot) > 0.15:
                        print("  VERDICT: degraded renderBeforeRead ≫ present ⇒ SPLIT — composition "
                              "on a later CB than the (earlier) FBO-render; cross-CB sync failed → "
                              "FIX = a targeted dependency / force same-CB at that edge.")
                    elif dsc2 > 0 and rate(dsc2, dtot) > 0.5:
                        print("  VERDICT: degraded SAME-CB dominant ⇒ NOT a CB-split — the FBO-"
                              "render + composition are same-CB but still frozen = an INTRA-CB "
                              "pass-order reorder (FBO pass encoded after the composition pass) — "
                              "the capture's pass-order view confirms; FIX = the encode order.")
                    else:
                        print("  VERDICT: no clear degraded-vs-present epoch delta — re-examine / "
                              "the operator capture is the execution-order tiebreaker.")

    # Parallel-encode share (arm c).
    pe_first, pe_last = first.get("parallelEncode", {}), last.get("parallelEncode", {})
    if pe_last.get("enabled"):
        print("\n== PARALLEL-ENCODE (delta) ==")
        for k in ("translatedDraws", "candidateDraws", "parallelEncodedDraws",
                  "descriptorEncodedDraws", "serialFallbackDraws", "batchCount",
                  "batchDraws", "maxBatchSize", "parallelEncodeWallUs",
                  "sumWorkerEncodeUs", "descriptorWorkerWallUs",
                  "descriptorWorkerSumUs"):
            print(f"{k}={pe_last.get(k, 0) - pe_first.get(k, 0)}")
        br_f, br_l = pe_first.get("boundaryReasons", {}), pe_last.get("boundaryReasons", {})
        deltas = {k: br_l.get(k, 0) - br_f.get(k, 0) for k in br_l}
        deltas = {k: v for k, v in deltas.items() if v > 0}
        total_b = sum(deltas.values())
        print("boundaryReasons:", {k: f"{v} ({v/total_b*100:.1f}%)"
                                   for k, v in sorted(deltas.items(), key=lambda x: -x[1])}
              if total_b else "{}")
        td = pe_last.get("translatedDraws", 0) - pe_first.get("translatedDraws", 0)
        fbo_b = deltas.get("fbo_draw", 0)
        if td:
            print(f"fbo_draw boundary share: {fbo_b/td*100:.1f}% of translated draws")

    if "--intervals" in sys.argv:
        print("\n== PER-INTERVAL FRAME COUNTS (stability) ==")
        prev = None
        for r, p in pacing_rows:
            f = p.get("pacing", {}).get("frames", 0)
            if prev is not None:
                print(f"  +{f - prev}")
            prev = f


if __name__ == "__main__":
    main()
