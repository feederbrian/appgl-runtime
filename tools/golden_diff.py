#!/usr/bin/env python3
"""
Golden Diff for CTS QPA results.

Compares two CTS `.qpa` files (e.g. AppGL vs a reference implementation
like Mesa/llvmpipe or NVIDIA) and reports per-test-name agreement and
disagreement. Focused on the buckets that matter for claims-auditing:

  agree       — both impls report the same status (good)
  us_only_fail — ref passes, we fail (real gap to close)
  us_only_pass — we pass, ref fails (FALSE POSITIVE — poisoning candidate)
  under_advt  — ref passes, we report NotSupported (under-advertised cap)
  over_advt   — we pass, ref reports NotSupported (claim beyond spec)

Usage:
    ./golden_diff.py --ref <path/to/reference.qpa> --us <path/to/appgl.qpa>
                     [--category PREFIX] [--detail us_only_pass[,other,...]]

The script only reads QPA — no test re-runs, no network, no deps beyond
stdlib. Can compare sweeps captured weeks apart as long as both ran the
same CTS version.
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path


_CASE_RE = re.compile(r"#beginTestCaseResult\s+(\S+)")
_STATUS_RE = re.compile(r'StatusCode="([^"]+)"')


def load_qpa(path: Path) -> dict[str, str]:
    """Return { CasePath -> StatusCode } from a CTS QPA file."""
    raw = path.read_bytes().decode("utf-8", errors="replace")
    results: dict[str, str] = {}
    # Each test block starts with `#beginTestCaseResult <path>` and ends
    # with `#endTestCaseResult`. Split and walk.
    blocks = raw.split("#beginTestCaseResult")
    for block in blocks[1:]:
        # First token after the marker is the CasePath; then StatusCode
        # appears inside a <Result ...> tag.
        head = block.lstrip().split(None, 1)
        if not head:
            continue
        case = head[0].strip()
        status_m = _STATUS_RE.search(block)
        if not status_m:
            continue
        results[case] = status_m.group(1)
    return results


CLASSIFY = {
    ("Pass", "Pass"): "agree",
    ("Fail", "Fail"): "agree",
    ("NotSupported", "NotSupported"): "agree",
    ("Pass", "Fail"): "us_only_fail",  # ref passes, we fail → real bug
    ("Fail", "Pass"): "us_only_pass",  # we pass, ref fails → false positive
    ("Pass", "NotSupported"): "under_advt",  # ref passes, we NS
    ("NotSupported", "Pass"): "over_advt",  # we pass, ref NS
}


def classify(ref: str, us: str) -> str:
    return CLASSIFY.get((ref, us), f"other:{ref}→{us}")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    p.add_argument("--ref", required=True, type=Path, help="Reference QPA")
    p.add_argument("--us", required=True, type=Path, help="AppGL QPA")
    p.add_argument("--category", default="", help="Optional CasePath prefix filter (e.g. KHR-GL46.packed_pixels.)")
    p.add_argument(
        "--detail",
        default="",
        help="Comma-separated bucket names to print test-name listings for (e.g. us_only_pass,us_only_fail)",
    )
    p.add_argument("--limit", type=int, default=30, help="Max test names to print per detailed bucket")
    args = p.parse_args()

    ref = load_qpa(args.ref)
    us = load_qpa(args.us)
    if args.category:
        ref = {k: v for k, v in ref.items() if k.startswith(args.category)}
        us = {k: v for k, v in us.items() if k.startswith(args.category)}

    # Build the union of test names
    all_cases = sorted(set(ref) | set(us))

    buckets: dict[str, list[tuple[str, str, str]]] = defaultdict(list)
    only_ref = 0
    only_us = 0
    for case in all_cases:
        r = ref.get(case)
        u = us.get(case)
        if r is None:
            only_us += 1
            buckets[f"us_only_entry:{u}"].append((case, "—", u))
        elif u is None:
            only_ref += 1
            buckets[f"ref_only_entry:{r}"].append((case, r, "—"))
        else:
            buckets[classify(r, u)].append((case, r, u))

    total = len(all_cases)
    print(f"Ref QPA : {args.ref}  ({len(ref)} cases)")
    print(f"Us QPA  : {args.us}  ({len(us)} cases)")
    if args.category:
        print(f"Filter  : {args.category!r}")
    print(f"Union   : {total} test cases")
    if only_ref:
        print(f"  ({only_ref} present only in ref — likely CTS-version drift)")
    if only_us:
        print(f"  ({only_us} present only in us — likely CTS-version drift)")
    print()

    headline_order = [
        "agree",
        "us_only_fail",
        "us_only_pass",
        "under_advt",
        "over_advt",
    ]
    print(f"{'bucket':<18} {'count':>7}  description")
    print("-" * 70)
    for k in headline_order:
        n = len(buckets.get(k, []))
        desc = {
            "agree": "both impls reach same verdict",
            "us_only_fail": "ref passes, we FAIL (real bug to close)",
            "us_only_pass": "ref fails, we PASS (FALSE POSITIVE candidate)",
            "under_advt": "ref passes, we mark NotSupported",
            "over_advt": "ref NotSupported, we pass (we claim beyond spec)",
        }[k]
        print(f"  {k:<16} {n:>7}  {desc}")
    # Any uncovered status pairings (e.g. QualityWarning, Waiver, InternalError)
    other_buckets = sorted(k for k in buckets if k not in headline_order and not k.startswith("us_only_entry") and not k.startswith("ref_only_entry"))
    if other_buckets:
        print()
        print("Other status pairings:")
        for k in other_buckets:
            print(f"  {k:<30} {len(buckets[k]):>5}")

    # Optional detail listings
    if args.detail:
        wanted = [w.strip() for w in args.detail.split(",") if w.strip()]
        for key in wanted:
            entries = buckets.get(key, [])
            if not entries:
                print(f"\n{key}: 0 cases")
                continue
            print(f"\n{key}: {len(entries)} cases (showing up to {args.limit})")
            for case, r, u in entries[: args.limit]:
                print(f"  ref={r:<13} us={u:<13} {case}")
            if len(entries) > args.limit:
                print(f"  … (+{len(entries) - args.limit} more)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
