#!/usr/bin/env python3
"""
Vacuous-pass detector classifier.

Pairs a CTS QPA log with a combined stdout+stderr stream produced by
running glcts with `APPGL_DETECTOR_TF=1` and `2>&1`. Emits one JSONL line
per test recording a classification:

  GENUINE_PASS   — Pass + at least one TF read with non-zero bytes
  VACUOUS_PASS   — Pass + at least one TF read, but every read all-zero
  NO_TF_READ_PASS — Pass + no TF reads observed (test verifies via other
                    means, e.g. PRIMITIVES_GENERATED / onscreen color)
  GENUINE_FAIL   — Status != Pass and != NotSupported
  NOT_SUPPORTED  — NotSupported (skipped from baseline counts)
  PENDING        — Pending / CompatibilityWarning / unknown

Test boundaries come from deqp's built-in stdout marker
`Test case '<name>'..\\n` printed by tcuTestSessionExecutor.cpp at the
start of each iteration. TF-read lines come from the runtime detector
(GLContext.mm). They interleave when stdout+stderr are merged via 2>&1.

Usage
-----

    glcts --deqp-case='KHR-GL46.tessellation_shader.*' \\
          --deqp-log-filename=/tmp/sweep.qpa 2>&1 | tee /tmp/sweep.log

    detector_classify.py \\
        --qpa /tmp/sweep.qpa \\
        --log /tmp/sweep.log \\
        --env env-off \\
        --out specs-worker-docs/detector-baseline-2026-04-25.jsonl

    # or --append to add a second sweep's classifications to an existing
    # JSONL file:
    detector_classify.py --qpa ... --log ... --env env-on \\
        --out specs-worker-docs/detector-baseline-2026-04-25.jsonl --append

Each output line:

    {"test": "KHR-GL46.tessellation_shader.tessellation_invariance.invariance_rule6",
     "env": "env-off",
     "classification": "VACUOUS_PASS",
     "status": "Pass",
     "tf_reads": 24,
     "tf_reads_nonzero": 0,
     "max_nonzero_bytes": 0,
     "total_bytes_read": 864,
     "buffers_seen": [1]}
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Optional


_CASE_RE = re.compile(r"#beginTestCaseResult\s+(\S+)")
_STATUS_RE = re.compile(r'StatusCode="([^"]+)"')
_TEST_BOUNDARY_RE = re.compile(r"^Test case '([^']+)'\.\.\s*$")
_DETECTOR_RE = re.compile(
    r"^APPGL_DETECTOR tf_read "
    r"target=0x([0-9A-Fa-f]+) "
    r"buf=(\d+) "
    r"offset=(-?\d+) "
    r"length=(-?\d+) "
    r"nonzero_bytes=(\d+) "
    r"first_nonzero_offset=(-?\d+)\s*$"
)


def load_qpa_status(path: Path) -> dict[str, str]:
    """Return { CasePath -> StatusCode } from a CTS QPA file."""
    raw = path.read_bytes().decode("utf-8", errors="replace")
    results: dict[str, str] = {}
    blocks = raw.split("#beginTestCaseResult")
    for block in blocks[1:]:
        head = block.lstrip().split(None, 1)
        if not head:
            continue
        case = head[0].strip()
        status_m = _STATUS_RE.search(block)
        if status_m:
            results[case] = status_m.group(1)
    return results


def parse_combined_log(path: Path) -> dict[str, list[dict[str, int]]]:
    """Walk the merged stdout+stderr log; group APPGL_DETECTOR lines by
    the most recently announced test boundary. Returns { test -> [reads] }
    where each read is {"target", "buf", "offset", "length",
    "nonzero_bytes", "first_nonzero_offset"}.

    Lines with no preceding `Test case '<name>'..` boundary (e.g.
    detector lines fired during context init before the first test) go
    into the "<pre-test>" pseudo-bucket and are dropped from output.
    """
    reads_by_test: dict[str, list[dict[str, int]]] = defaultdict(list)
    current = "<pre-test>"
    with path.open("r", errors="replace") as fp:
        for line in fp:
            tb = _TEST_BOUNDARY_RE.match(line)
            if tb is not None:
                current = tb.group(1)
                # Ensure key exists even if test makes no TF reads, so we
                # can distinguish "saw the test" from "missing from log".
                _ = reads_by_test[current]
                continue
            d = _DETECTOR_RE.match(line)
            if d is not None:
                reads_by_test[current].append({
                    "target": int(d.group(1), 16),
                    "buf": int(d.group(2)),
                    "offset": int(d.group(3)),
                    "length": int(d.group(4)),
                    "nonzero_bytes": int(d.group(5)),
                    "first_nonzero_offset": int(d.group(6)),
                })
    reads_by_test.pop("<pre-test>", None)
    return reads_by_test


def classify(status: str, reads: list[dict[str, int]]) -> str:
    if status == "NotSupported":
        return "NOT_SUPPORTED"
    if status != "Pass":
        # Fail, InternalError, ResourceError, Crash, Timeout, Pending …
        if status in {"Pending", "CompatibilityWarning"}:
            return "PENDING"
        return "GENUINE_FAIL"
    # status == Pass
    if not reads:
        return "NO_TF_READ_PASS"
    if any(r["nonzero_bytes"] > 0 for r in reads):
        return "GENUINE_PASS"
    return "VACUOUS_PASS"


def build_records(qpa: dict[str, str],
                  reads_by_test: dict[str, list[dict[str, int]]],
                  env: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    # Use union of QPA test names + log test names so we don't drop tests
    # the log saw but the QPA didn't (shouldn't happen for an in-sync run,
    # but be defensive).
    all_tests = sorted(set(qpa) | set(reads_by_test))
    for t in all_tests:
        status = qpa.get(t, "<missing-from-qpa>")
        reads = reads_by_test.get(t, [])
        nonzero_reads = [r for r in reads if r["nonzero_bytes"] > 0]
        record = {
            "test": t,
            "env": env,
            "classification": classify(status, reads),
            "status": status,
            "tf_reads": len(reads),
            "tf_reads_nonzero": len(nonzero_reads),
            "max_nonzero_bytes": max((r["nonzero_bytes"] for r in reads), default=0),
            "total_bytes_read": sum(r["length"] for r in reads),
            "buffers_seen": sorted({r["buf"] for r in reads}),
        }
        records.append(record)
    return records


def summarize(records: list[dict[str, Any]], env: str) -> Counter[str]:
    c: Counter[str] = Counter()
    for r in records:
        c[r["classification"]] += 1
    return c


def write_jsonl(records: list[dict[str, Any]], out: Path, append: bool) -> None:
    mode = "a" if append else "w"
    with out.open(mode) as fp:
        for r in records:
            fp.write(json.dumps(r, separators=(",", ":")) + "\n")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    p.add_argument("--qpa", required=True, type=Path,
                   help="CTS QPA log (--deqp-log-filename output)")
    p.add_argument("--log", required=True, type=Path,
                   help="Merged stdout+stderr from the same glcts run "
                        "(captured via `... 2>&1 | tee <path>`)")
    p.add_argument("--env", required=True,
                   help="Label for this sweep, e.g. env-off / env-on")
    p.add_argument("--out", required=True, type=Path,
                   help="JSONL sidecar to write (one line per test)")
    p.add_argument("--append", action="store_true",
                   help="Append to --out instead of overwriting")
    p.add_argument("--filter-prefix", default="",
                   help="Only emit tests whose name starts with this prefix")
    args = p.parse_args()

    qpa = load_qpa_status(args.qpa)
    reads_by_test = parse_combined_log(args.log)

    if args.filter_prefix:
        qpa = {k: v for k, v in qpa.items() if k.startswith(args.filter_prefix)}
        reads_by_test = {k: v for k, v in reads_by_test.items()
                         if k.startswith(args.filter_prefix)}

    records = build_records(qpa, reads_by_test, args.env)
    write_jsonl(records, args.out, append=args.append)

    summary = summarize(records, args.env)
    print(f"[{args.env}] {len(records)} tests classified → {args.out}")
    for k in ("GENUINE_PASS", "VACUOUS_PASS", "NO_TF_READ_PASS",
              "GENUINE_FAIL", "NOT_SUPPORTED", "PENDING"):
        print(f"  {k:18s} {summary.get(k, 0):4d}")
    other = sum(v for k, v in summary.items() if k not in {
        "GENUINE_PASS", "VACUOUS_PASS", "NO_TF_READ_PASS",
        "GENUINE_FAIL", "NOT_SUPPORTED", "PENDING"})
    if other:
        print(f"  {'OTHER':18s} {other:4d}")

    # Detector-baseline headline: pass-rate excluding NotSupported, with
    # vacuous separated out so the number can't be confused for genuine.
    denom = sum(summary.get(k, 0) for k in (
        "GENUINE_PASS", "VACUOUS_PASS", "NO_TF_READ_PASS", "GENUINE_FAIL", "PENDING"))
    if denom:
        gen = summary.get("GENUINE_PASS", 0)
        vac = summary.get("VACUOUS_PASS", 0)
        nor = summary.get("NO_TF_READ_PASS", 0)
        print(f"  → genuine-pass rate (excl NS): {gen}/{denom} = {gen/denom:.1%}")
        print(f"  → vacuous-pass rate (excl NS): {vac}/{denom} = {vac/denom:.1%}")
        print(f"  → no-TF-read pass rate (excl NS): {nor}/{denom} = {nor/denom:.1%}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
