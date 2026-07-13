#!/usr/bin/env python3

import argparse
import csv
import hashlib
import json
from pathlib import Path


FLAVORS = ("default", "f64on")
UNRESOLVED = frozenset(("unsafe", "error"))


def load_results(path: Path) -> dict[str, dict]:
    records = json.loads(path.read_text())
    indexed = {record["id"]: record for record in records}
    if len(indexed) != 256 or len(records) != 256:
        raise ValueError(f"{path}: expected 256 unique records")
    return indexed


def file_identity(path: Path) -> dict:
    return {
        "path": str(path),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def compact(record: dict) -> dict:
    variants = record["variants"]
    measured = [item for item in variants if item["total"] >= 0]
    return {
        "observed": record["observed"],
        "safety": record["safety"],
        "passed": sum(item["passed"] for item in measured),
        "total": sum(item["total"] for item in measured),
        "failures": sum(item["failures"] for item in measured),
        "origins": [item["origin"] for item in variants],
        "piglit_results": [item["piglit_result"] for item in variants],
        "query_match": all(item["query_match"] for item in measured),
    }


def attribute(baseline: dict, candidate: dict) -> str:
    baseline_state = baseline["observed"]
    candidate_state = candidate["observed"]
    if baseline_state in UNRESOLVED or candidate_state in UNRESOLVED:
        return "harness-unresolved"
    if baseline_state == "pass":
        return "unchanged-pass" if candidate_state == "pass" else "candidate-regression"
    return "candidate-recovery" if candidate_state == "pass" else "pre-existing-gap"


def shape(record: dict) -> tuple:
    compacted = compact(record)
    return (
        compacted["observed"],
        compacted["passed"],
        compacted["total"],
        compacted["failures"],
        compacted["query_match"],
        tuple(compacted["piglit_results"]),
    )


def combined_attribution(per_flavor: dict[str, dict]) -> str:
    values = {item["attribution"] for item in per_flavor.values()}
    if "candidate-regression" in values:
        return "candidate-regression"
    if "harness-unresolved" in values:
        return "harness-unresolved"
    if values == {"unchanged-pass"}:
        return "unchanged-pass"
    if values == {"candidate-recovery"}:
        return "candidate-recovery"
    if values == {"pre-existing-gap"}:
        return "pre-existing-gap"
    return "mixed-nonregression"


def counts(rows: list[dict], key: str) -> dict[str, int]:
    result = {}
    for row in rows:
        value = row[key]
        result[value] = result.get(value, 0) + 1
    return dict(sorted(result.items()))


def main() -> int:
    parser = argparse.ArgumentParser()
    for flavor in FLAVORS:
        parser.add_argument(f"--candidate-{flavor}", type=Path, required=True)
        parser.add_argument(f"--baseline-{flavor}", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    if args.out.exists():
        raise SystemExit(f"refusing existing output directory: {args.out}")
    args.out.mkdir(parents=True)

    paths = {
        flavor: {
            "candidate": getattr(args, f"candidate_{flavor}"),
            "baseline": getattr(args, f"baseline_{flavor}"),
        }
        for flavor in FLAVORS
    }
    results = {
        flavor: {
            arm: load_results(path)
            for arm, path in flavor_paths.items()
        }
        for flavor, flavor_paths in paths.items()
    }
    ids = set(results["default"]["candidate"])
    for flavor in FLAVORS:
        for arm in ("candidate", "baseline"):
            if set(results[flavor][arm]) != ids:
                raise ValueError(f"{flavor}/{arm}: cell inventory mismatch")

    rows = []
    first = results["default"]["candidate"]
    for cell_id in sorted(ids, key=lambda item: first[item]["ordinal"]):
        source = first[cell_id]
        per_flavor = {}
        for flavor in FLAVORS:
            baseline_record = results[flavor]["baseline"][cell_id]
            candidate_record = results[flavor]["candidate"][cell_id]
            per_flavor[flavor] = {
                "baseline": compact(baseline_record),
                "candidate": compact(candidate_record),
                "attribution": attribute(baseline_record, candidate_record),
                "changed_shape": shape(baseline_record) != shape(candidate_record),
            }
        rows.append(
            {
                "ordinal": source["ordinal"],
                "id": cell_id,
                "view": source["view"],
                "operation": source["operation"],
                "dimension": source["dimension"],
                "seamless": source["seamless"],
                "flavors": per_flavor,
                "combined_attribution": combined_attribution(per_flavor),
            }
        )

    map_path = args.out / "three-way-map.json"
    map_path.write_text(json.dumps(rows, indent=2) + "\n")
    fields = [
        "ordinal", "id", "view", "operation", "dimension", "seamless",
        "default_baseline", "default_candidate", "default_attribution",
        "default_changed_shape", "f64on_baseline", "f64on_candidate",
        "f64on_attribution", "f64on_changed_shape", "combined_attribution",
    ]
    with (args.out / "three-way-map.tsv").open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields, dialect="excel-tab")
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    "ordinal": row["ordinal"],
                    "id": row["id"],
                    "view": row["view"],
                    "operation": row["operation"],
                    "dimension": row["dimension"],
                    "seamless": row["seamless"],
                    "default_baseline": row["flavors"]["default"]["baseline"]["observed"],
                    "default_candidate": row["flavors"]["default"]["candidate"]["observed"],
                    "default_attribution": row["flavors"]["default"]["attribution"],
                    "default_changed_shape": row["flavors"]["default"]["changed_shape"],
                    "f64on_baseline": row["flavors"]["f64on"]["baseline"]["observed"],
                    "f64on_candidate": row["flavors"]["f64on"]["candidate"]["observed"],
                    "f64on_attribution": row["flavors"]["f64on"]["attribution"],
                    "f64on_changed_shape": row["flavors"]["f64on"]["changed_shape"],
                    "combined_attribution": row["combined_attribution"],
                }
            )

    regressions = [
        row for row in rows
        if row["combined_attribution"] == "candidate-regression"
    ]
    (args.out / "candidate-regressions.json").write_text(
        json.dumps(regressions, indent=2) + "\n"
    )
    known_state = {
        "schema": "appgl.c2d-shadow-known-cell-state.v1",
        "baseline": {
            flavor: file_identity(paths[flavor]["baseline"])
            for flavor in FLAVORS
        },
        "cells": [
            {
                "id": row["id"],
                "default": row["flavors"]["default"]["baseline"],
                "f64on": row["flavors"]["f64on"]["baseline"],
            }
            for row in rows
        ],
    }
    (args.out / "known-cell-state.json").write_text(
        json.dumps(known_state, indent=2) + "\n"
    )
    summary = {
        "schema": "appgl.c2d-shadow-attribution.v1",
        "cell_count": len(rows),
        "inputs": {
            flavor: {
                arm: file_identity(path)
                for arm, path in flavor_paths.items()
            }
            for flavor, flavor_paths in paths.items()
        },
        "default": counts(
            [
                {"attribution": row["flavors"]["default"]["attribution"]}
                for row in rows
            ],
            "attribution",
        ),
        "f64on": counts(
            [
                {"attribution": row["flavors"]["f64on"]["attribution"]}
                for row in rows
            ],
            "attribution",
        ),
        "combined": counts(rows, "combined_attribution"),
        "candidate_regression_count": len(regressions),
        "candidate_regression_ids": [row["id"] for row in regressions],
    }
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 1 if regressions else 0


if __name__ == "__main__":
    raise SystemExit(main())
