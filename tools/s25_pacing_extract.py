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
                "contentPresentWithPost3DDraw")
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
            # §2 pass-trace: split the contentMissing frames into DRAW-OVER (a
            # real, localizable wipe) vs benign SKY (3D drew off-center).
            do = d["contentMissingDrawOver"]; bs = d["contentMissingBenignSky"]
            if cm:
                via_p = d["contentMissingDrawOverViaPass"]
                via_d = d["contentMissingDrawOverViaDraw"]
                print(f"SURVIVAL §2 RESIDUAL: of {cm} missing — DRAW-OVER={do} "
                      f"(viaPass={via_p} separate-overlay-pass / viaDraw={via_d} "
                      f"serial-draw)  benignSky={bs}")
                if do > bs and do > 0:
                    tgt = ("separate post-3D overlay PASS" if via_p >= via_d
                           else "serial post-3D DRAW")
                    print(f"  VERDICT: DRAW-OVER dominant ⇒ REAL WIPE the autogame "
                          f"caught (NO operator); fix target = {tgt}.")
                elif bs > 0 and do == 0:
                    print("  VERDICT: benignSky only ⇒ INCONCLUSIVE — either the "
                          "3D drew off-center (benign) OR a same-pass lean over-"
                          "draw (the §2 blind spot). Needs the temporal snapshot "
                          "or an operator pan-run; do NOT read as 'benign proven'.")
            print("READ: landing matched≈withLean ⇒ 3D lands. §1 contentMissing "
                  "⇒ scene-center reads the CLEAR color. §2 splits WHY: DRAW-OVER "
                  "(localizable wipe) vs benign SKY. (Needs "
                  "APPGL_W2_SURVIVAL_CONTENT_PROBE=1.)")

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
