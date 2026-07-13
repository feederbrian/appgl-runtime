#!/usr/bin/env python3

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time


VIEWS = ("V0", "V1", "V2", "V3")
DIMENSIONS = {
    "D1": "1DShadow",
    "D2": "2DShadow",
    "DC": "CubeShadow",
    "D1A": "1DArrayShadow",
    "D2A": "2DArrayShadow",
    "DCA": "CubeArrayShadow",
}
OPERATIONS = {
    "T": ("texture()", ("D1", "D2", "DC", "D1A", "D2A", "DCA")),
    "TB": ("texture(bias)", ("D1", "D2", "DC", "D1A", "D2A", "DCA")),
    "TO": ("textureOffset", ("D1", "D2", "D1A", "D2A")),
    "TOB": ("textureOffset(bias)", ("D1", "D2", "D1A", "D2A")),
    "G": ("textureGrad", ("D1", "D2", "DC", "D1A", "D2A", "DCA")),
    "GO": ("textureGradOffset", ("D1", "D2", "D1A", "D2A")),
    "L": ("textureLod", ("D1", "D2", "DC", "D1A", "D2A", "DCA")),
    "LO": ("textureLodOffset", ("D1", "D2", "D1A", "D2A")),
    "P": ("textureProj", ("D1", "D2")),
    "PB": ("textureProj(bias)", ("D1", "D2")),
    "PO": ("textureProjOffset", ("D1", "D2")),
    "POB": ("textureProjOffset(bias)", ("D1", "D2")),
    "PG": ("textureProjGrad", ("D1", "D2")),
    "PGO": ("textureProjGradOffset", ("D1", "D2")),
    "PL": ("textureProjLod", ("D1", "D2")),
    "PLO": ("textureProjLodOffset", ("D1", "D2")),
}
CUBE_SEAMLESS_OPERATIONS = frozenset(("T", "TB", "G", "L"))
CUBE_DIMENSIONS = frozenset(("DC", "DCA"))
RESULT_RE = re.compile(r'PIGLIT:\s*\{[^\n]*"result"\s*:\s*"([^"]+)"')
CELL_RE = re.compile(
    r"C2D_CELL id=(\S+).*"
    r"expected_immutable_levels=(\d+) queried_immutable_levels=(\d+) .*"
    r"expected_view_levels=(\d+) queried_view_levels=(\d+)"
)
PROBE_RE = re.compile(
    r"C2D_RESULT id=(\S+) passed=(\d+) total=(\d+) failures=(\d+)"
)


def generate_manifest() -> dict:
    cells = []
    for view in VIEWS:
        for operation, (cli_operation, dimensions) in OPERATIONS.items():
            for dimension in dimensions:
                cell_id = f"{view}-{operation}-{dimension}-S0"
                expected = (
                    "EXPECTED_PARTIAL"
                    if operation == "LO" and dimension == "D1" and view != "V2"
                    else "PASS"
                )
                cells.append(
                    {
                        "id": cell_id,
                        "view": view,
                        "operation": operation,
                        "operation_cli": cli_operation,
                        "dimension": dimension,
                        "dimension_cli": DIMENSIONS[dimension],
                        "seamless": False,
                        "expected": expected,
                        "variants": {
                            "lod_bias": [-1, 0, 1],
                            "mip_filter": ["nearest", "nearest_mipmap_nearest"],
                            "clip_origins": (
                                ["lower", "upper"] if view == "V3" else ["lower"]
                            ),
                        },
                    }
                )
        for operation in ("T", "TB", "G", "L"):
            cli_operation = OPERATIONS[operation][0]
            for dimension in ("DC", "DCA"):
                cells.append(
                    {
                        "id": f"{view}-{operation}-{dimension}-S1",
                        "view": view,
                        "operation": operation,
                        "operation_cli": cli_operation,
                        "dimension": dimension,
                        "dimension_cli": DIMENSIONS[dimension],
                        "seamless": True,
                        "expected": "PASS",
                        "variants": {
                            "lod_bias": [-1, 0, 1],
                            "mip_filter": ["nearest", "nearest_mipmap_nearest"],
                            "clip_origins": (
                                ["lower", "upper"] if view == "V3" else ["lower"]
                            ),
                        },
                    }
                )
    return {
        "schema": "appgl.c2d-shadow-matrix.v1",
        "source": "docs/c2d-enumerated-shadow-matrix-design.md sections 3-5",
        "cell_count": len(cells),
        "cells": cells,
    }


def validate_manifest(manifest: dict) -> None:
    cells = manifest.get("cells", [])
    if manifest.get("cell_count") != 256 or len(cells) != 256:
        raise ValueError(f"matrix must contain exactly 256 cells, found {len(cells)}")
    ids = [cell["id"] for cell in cells]
    if len(set(ids)) != len(ids):
        raise ValueError("matrix contains duplicate cell IDs")
    for view in VIEWS:
        count = sum(cell["view"] == view for cell in cells)
        if count != 64:
            raise ValueError(f"{view} must contain 64 cells, found {count}")
    partial = {cell["id"] for cell in cells if cell["expected"] == "EXPECTED_PARTIAL"}
    expected_partial = {f"{view}-LO-D1-S0" for view in VIEWS if view != "V2"}
    if partial != expected_partial:
        raise ValueError(
            f"known-partial set mismatch: expected {sorted(expected_partial)}, "
            f"found {sorted(partial)}"
        )


def final_result(stdout: str, stderr: str) -> str:
    matches = RESULT_RE.findall(stdout + "\n" + stderr)
    return matches[-1] if matches else ""


def run_variant(
    cell: dict,
    origin: str,
    binary: Path,
    env: dict[str, str],
    timeout: float,
    stdout_path: Path,
    stderr_path: Path,
) -> dict:
    command = [
        str(binary),
        cell["operation_cli"],
        cell["dimension_cli"],
        f"-c2d-view={cell['view']}",
        f"-c2d-cell-id={cell['id']}",
        f"-c2d-clip-origin={origin}",
        "-inplace",
        "-auto",
        "-fbo",
    ]
    if cell["seamless"]:
        command.append("-c2d-seamless")
    started = time.monotonic()
    timed_out = False
    with stdout_path.open("w") as stdout_file, stderr_path.open("w") as stderr_file:
        try:
            completed = subprocess.run(
                command,
                env=env,
                stdout=stdout_file,
                stderr=stderr_file,
                text=True,
                timeout=timeout,
                check=False,
            )
            return_code = completed.returncode
        except subprocess.TimeoutExpired:
            timed_out = True
            return_code = 124
    elapsed = round(time.monotonic() - started, 3)
    stdout = stdout_path.read_text()
    stderr = stderr_path.read_text()
    result = final_result(stdout, stderr)
    cell_match = CELL_RE.search(stdout + "\n" + stderr)
    probe_match = PROBE_RE.search(stdout + "\n" + stderr)
    expected_immutable_levels = int(cell_match.group(2)) if cell_match else -1
    queried_immutable_levels = int(cell_match.group(3)) if cell_match else -1
    expected_view_levels = int(cell_match.group(4)) if cell_match else -1
    queried_view_levels = int(cell_match.group(5)) if cell_match else -1
    passed = int(probe_match.group(2)) if probe_match else -1
    total = int(probe_match.group(3)) if probe_match else -1
    failures = int(probe_match.group(4)) if probe_match else -1
    return {
        "origin": origin,
        "command": command,
        "exit_code": return_code,
        "elapsed_sec": elapsed,
        "timed_out": timed_out,
        "signaled": return_code < 0,
        "piglit_result": result,
        "has_cell_record": cell_match is not None,
        "has_probe_record": probe_match is not None,
        "expected_immutable_levels": expected_immutable_levels,
        "queried_immutable_levels": queried_immutable_levels,
        "immutable_query_match": (
            expected_immutable_levels == queried_immutable_levels
        ),
        "expected_view_levels": expected_view_levels,
        "queried_view_levels": queried_view_levels,
        "view_query_match": expected_view_levels == queried_view_levels,
        "query_match": (
            expected_immutable_levels == queried_immutable_levels
            and expected_view_levels == queried_view_levels
        ),
        "passed": passed,
        "total": total,
        "failures": failures,
    }


def classify(cell: dict, variants: list[dict]) -> tuple[str, bool, bool]:
    safety = all(
        not item["timed_out"]
        and not item["signaled"]
        for item in variants
    )
    if not safety:
        return "unsafe", False, False
    if any(item["piglit_result"] == "skip" for item in variants):
        return "skip", False, True
    if any(
        item["piglit_result"] not in {"pass", "fail"}
        or not item["has_cell_record"]
        or not item["has_probe_record"]
        for item in variants
    ):
        return "error", False, True
    all_pass = all(
        item["piglit_result"] == "pass"
        and item["exit_code"] == 0
        and item["query_match"]
        and item["failures"] == 0
        and item["total"] > 0
        for item in variants
    )
    all_partial = all(
        item["piglit_result"] == "fail"
        and item["exit_code"] != 0
        and item["query_match"]
        and 0 < item["passed"] < item["total"]
        and item["failures"] > 0
        for item in variants
    )
    observed = "pass" if all_pass else "partial" if all_partial else "fail"
    expected_match = (
        (cell["expected"] == "PASS" and observed == "pass")
        or (cell["expected"] == "EXPECTED_PARTIAL" and observed == "partial")
    )
    return observed, expected_match, True


def run_manifest(args: argparse.Namespace, manifest: dict) -> int:
    if args.out.exists():
        raise SystemExit(f"refusing existing output directory: {args.out}")
    args.out.mkdir(parents=True)
    logs = args.out / "logs"
    logs.mkdir()
    env = os.environ.copy()
    for key in (
        "APPGL_COMPAT_PROFILE",
        "APPGL_COMPAT_VERSION",
        "APPGL_COMPAT_REQUEST_PROFILE",
    ):
        env.pop(key, None)
    env.update(
        {
            "APPGL_COMPAT_ADMISSION": "full",
            "APPGL_TEXTUREGATHER_DISPLAY_DETACHED": "1",
            "PIGLIT_DARWIN_GL_LIBRARY": str(args.library),
            "DYLD_INSERT_LIBRARIES": f"{args.library}:{args.bridge}",
        }
    )

    selected = manifest["cells"]
    if args.cell:
        requested = set(args.cell)
        selected = [cell for cell in selected if cell["id"] in requested]
        missing = requested - {cell["id"] for cell in selected}
        if missing:
            raise SystemExit(f"unknown cells: {', '.join(sorted(missing))}")

    records = []
    for ordinal, cell in enumerate(selected, 1):
        variants = []
        for origin in cell["variants"]["clip_origins"]:
            stem = f"{ordinal:03d}-{cell['id']}-{origin}"
            variants.append(
                run_variant(
                    cell,
                    origin,
                    args.binary,
                    env,
                    args.timeout,
                    logs / f"{stem}.stdout.log",
                    logs / f"{stem}.stderr.log",
                )
            )
        observed, expected_match, safety = classify(cell, variants)
        records.append(
            {
                "ordinal": ordinal,
                "id": cell["id"],
                "view": cell["view"],
                "operation": cell["operation"],
                "dimension": cell["dimension"],
                "seamless": cell["seamless"],
                "expected": cell["expected"],
                "observed": observed,
                "expected_match": expected_match,
                "safety": safety,
                "variants": variants,
            }
        )
        print(
            f"[{ordinal:03d}/{len(selected):03d}] {cell['id']} "
            f"expected={cell['expected']} observed={observed}"
        )

    with (args.out / "results.json").open("w") as output:
        json.dump(records, output, indent=2)
        output.write("\n")
    with (args.out / "results.tsv").open("w", newline="") as output:
        fields = [
            "ordinal",
            "id",
            "view",
            "operation",
            "dimension",
            "seamless",
            "expected",
            "observed",
            "expected_match",
            "safety",
        ]
        writer = csv.DictWriter(output, fieldnames=fields, dialect="excel-tab")
        writer.writeheader()
        for record in records:
            writer.writerow({field: record[field] for field in fields})

    summary = {
        "schema": "appgl.c2d-shadow-matrix-results.v1",
        "flavor": args.flavor,
        "library": str(args.library),
        "library_sha256": hashlib.sha256(args.library.read_bytes()).hexdigest(),
        "binary": str(args.binary),
        "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        "cell_count": len(records),
        "pass_count": sum(record["observed"] == "pass" for record in records),
        "partial_count": sum(record["observed"] == "partial" for record in records),
        "fail_count": sum(record["observed"] == "fail" for record in records),
        "skip_count": sum(record["observed"] == "skip" for record in records),
        "error_count": sum(record["observed"] == "error" for record in records),
        "unsafe_count": sum(record["observed"] == "unsafe" for record in records),
        "expected_mismatch_count": sum(
            not record["expected_match"] for record in records
        ),
        "safety_zero": all(record["safety"] for record in records),
    }
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if summary["expected_mismatch_count"] == 0 and summary["safety_zero"] else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--write-manifest", type=Path)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--library", type=Path)
    parser.add_argument("--bridge", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--flavor")
    parser.add_argument("--cell", action="append")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    generated = generate_manifest()
    validate_manifest(generated)
    if args.write_manifest:
        args.write_manifest.write_text(json.dumps(generated, indent=2) + "\n")
        return 0
    required = (args.manifest, args.binary, args.library, args.bridge, args.out, args.flavor)
    if any(item is None for item in required):
        parser.error(
            "run mode requires --manifest, --binary, --library, --bridge, --out, and --flavor"
        )
    manifest = json.loads(args.manifest.read_text())
    validate_manifest(manifest)
    if manifest != generated:
        raise SystemExit("manifest does not match the table-driven source of truth")
    return run_manifest(args, manifest)


if __name__ == "__main__":
    raise SystemExit(main())
