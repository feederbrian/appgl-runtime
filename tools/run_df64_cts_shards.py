#!/usr/bin/env python3
"""
Run the Decision F df64 CTS surface through external glcts shards.

The runner is intentionally harness-only. It exports the target case list,
splits gpu_shader_fp64.builtin cases on function-family boundaries, snapshots
the AppGL dylib into the output directory, runs N glcts processes with isolated
QPA/log files, then summarizes status counts and baseline preservation.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections import Counter, OrderedDict
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable


CASE_PATTERNS = (
    "KHR-GL46.gpu_shader_fp64.*",
    "KHR-GL46.vertex_attrib_64bit.*",
)
EXPECTED_TOTAL_CASES = 663
DEFAULT_EXPECTED_PASS = 611
DEFAULT_EXPECTED_FAIL = 52
DEFAULT_BASELINE_SECONDS = 9134.20

TYPE_SUFFIXES = tuple(sorted((
    "dmat2x3",
    "dmat2x4",
    "dmat3x2",
    "dmat3x4",
    "dmat4x2",
    "dmat4x3",
    "double",
    "dvec2",
    "dvec3",
    "dvec4",
    "dmat2",
    "dmat3",
    "dmat4",
), key=len, reverse=True))

CASE_RE = re.compile(r"^TEST:\s+(.+?)\s*$")
QPA_STATUS_RE = re.compile(r'StatusCode="([^"]+)"')
QPA_DURATION_RE = re.compile(r'<Number Name="TestDuration"[^>]*>(\d+)</Number>')


@dataclass
class Shard:
    index: int
    name: str
    cases: list[str]
    weight: float
    cases_path: Path
    trie_path: Path
    qpa_path: Path
    log_path: Path


@dataclass
class ShardRun:
    shard: Shard
    returncode: int
    elapsed_seconds: float
    qpa_size: int
    log_size: int


def repo_paths() -> tuple[Path, Path]:
    appgl_root = Path(__file__).resolve().parents[1]
    repo_root = appgl_root.parent
    return repo_root, appgl_root


def default_baseline_qpas(appgl_root: Path) -> list[Path]:
    reports = appgl_root / "tests" / "reports"
    return [
        reports / "appgl-cw-s20-df64-phase7-2x-fp64-core.qpa",
        reports / "appgl-cw-s20-df64-phase7-2x-fp64-builtin.qpa",
        reports / "appgl-cw-s20-df64-phase7-2x-vertex-4case.qpa",
    ]


def default_weight_qpas(appgl_root: Path) -> list[Path]:
    qpa_dir = (
        appgl_root
        / "tests"
        / "reports"
        / "df64-shards"
        / "appgl-cw-s20-df64-shards-calibration-4w-phase2-realdevice"
        / "qpa"
    )
    return sorted(qpa_dir.glob("*.qpa"))


def run_capture(command: list[str], cwd: Path, env: dict[str, str]) -> str:
    proc = subprocess.run(
        command,
        cwd=str(cwd),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"command failed with {proc.returncode}: {' '.join(command)}\n"
            f"{proc.stdout[-4000:]}"
        )
    return proc.stdout


def make_env(appgl_lib_dir: Path, extra_env: list[str]) -> dict[str, str]:
    env = os.environ.copy()
    existing = env.get("DYLD_LIBRARY_PATH", "")
    parts = [str(appgl_lib_dir)]
    if existing:
        parts.append(existing)
    env["DYLD_LIBRARY_PATH"] = os.pathsep.join(parts)
    for item in extra_env:
        if "=" not in item:
            raise ValueError(f"--env expects KEY=VALUE, got {item!r}")
        key, value = item.split("=", 1)
        env[key] = value
    return env


def export_cases(glcts: Path, cts_dir: Path, env: dict[str, str]) -> list[str]:
    seen: set[str] = set()
    cases: list[str] = []
    for pattern in CASE_PATTERNS:
        out = run_capture(
            [
                str(glcts),
                f"--deqp-case={pattern}",
                "--deqp-runmode=stdout-caselist",
            ],
            cwd=cts_dir,
            env=env,
        )
        for line in out.splitlines():
            m = CASE_RE.match(line)
            if not m:
                continue
            case = m.group(1)
            if (
                case.startswith("KHR-GL46.gpu_shader_fp64.")
                or case.startswith("KHR-GL46.vertex_attrib_64bit.")
            ) and case not in seen:
                seen.add(case)
                cases.append(case)
    return cases


def load_case_file(path: Path) -> list[str]:
    return [
        line.strip()
        for line in path.read_text().splitlines()
        if line.strip() and not line.startswith("#")
    ]


def parse_qpa(path: Path) -> dict[str, dict[str, float | str]]:
    raw = path.read_bytes().decode("utf-8", errors="replace")
    results: dict[str, dict[str, float | str]] = {}
    for block in raw.split("#beginTestCaseResult")[1:]:
        head = block.lstrip().split(None, 1)
        if not head:
            continue
        case = head[0].strip()
        status_m = QPA_STATUS_RE.search(block)
        duration_m = QPA_DURATION_RE.search(block)
        if not status_m:
            continue
        duration_s = 0.0
        if duration_m:
            duration_s = int(duration_m.group(1)) / 1_000_000.0
        results[case] = {
            "status": status_m.group(1),
            "duration_seconds": duration_s,
        }
    return results


def load_baseline(paths: list[Path]) -> dict[str, dict[str, float | str]]:
    baseline: dict[str, dict[str, float | str]] = {}
    for path in paths:
        if path.exists():
            baseline.update(parse_qpa(path))
    return baseline


def builtin_family(case: str) -> str:
    prefix = "KHR-GL46.gpu_shader_fp64.builtin."
    name = case[len(prefix):]
    for suffix in TYPE_SUFFIXES:
        marker = "_" + suffix
        if name.endswith(marker):
            return name[: -len(marker)]
    return name.rsplit("_", 1)[0]


def group_name(case: str) -> str:
    if case.startswith("KHR-GL46.gpu_shader_fp64.fp64."):
        return "gpu_shader_fp64.fp64"
    if case.startswith("KHR-GL46.gpu_shader_fp64.builtin."):
        return "gpu_shader_fp64.builtin." + builtin_family(case)
    if case.startswith("KHR-GL46.vertex_attrib_64bit."):
        return "vertex_attrib_64bit"
    return "misc"


def group_cases(cases: list[str]) -> OrderedDict[str, list[str]]:
    grouped: OrderedDict[str, list[str]] = OrderedDict()
    for case in cases:
        grouped.setdefault(group_name(case), []).append(case)
    return grouped


def case_weight(case: str, weights: dict[str, dict[str, float | str]]) -> float:
    entry = weights.get(case)
    if entry:
        weight = float(entry.get("duration_seconds", 0.0))
        if weight > 0.0:
            return weight
    return 1.0


def assign_shards(
    cases: list[str],
    grouped: OrderedDict[str, list[str]],
    weights: dict[str, dict[str, float | str]],
    workers: int,
    out_dir: Path,
    label: str,
) -> list[Shard]:
    shard_cases: list[list[str]] = [[] for _ in range(workers)]
    shard_weights = [0.0 for _ in range(workers)]
    group_weights: list[tuple[str, list[str], float]] = []
    for name, group in grouped.items():
        weight = sum(case_weight(case, weights) for case in group)
        group_weights.append((name, group, weight))

    original_order = {case: idx for idx, case in enumerate(cases)}
    for _name, group, weight in sorted(group_weights, key=lambda item: item[2], reverse=True):
        shard_index = min(range(workers), key=lambda idx: shard_weights[idx])
        shard_cases[shard_index].extend(group)
        shard_weights[shard_index] += weight

    shards_dir = out_dir / "shards"
    shards_dir.mkdir(parents=True, exist_ok=True)
    qpa_dir = out_dir / "qpa"
    qpa_dir.mkdir(parents=True, exist_ok=True)
    logs_dir = out_dir / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)

    shards: list[Shard] = []
    for idx, selected in enumerate(shard_cases):
        selected.sort(key=lambda case: original_order[case])
        name = f"{label}-w{workers}-shard{idx:02d}"
        cases_path = shards_dir / f"{name}.cases.txt"
        trie_path = shards_dir / f"{name}.trie"
        qpa_path = qpa_dir / f"{name}.qpa"
        log_path = logs_dir / f"{name}.log"
        cases_path.write_text("\n".join(selected) + "\n")
        trie_path.write_text(cases_to_trie(selected) + "\n")
        shards.append(
            Shard(
                index=idx,
                name=name,
                cases=selected,
                weight=shard_weights[idx],
                cases_path=cases_path,
                trie_path=trie_path,
                qpa_path=qpa_path,
                log_path=log_path,
            )
        )
    return shards


def cases_to_trie(cases: Iterable[str]) -> str:
    root: dict[str, dict] = {}
    for case in cases:
        node = root
        for part in case.split("."):
            node = node.setdefault(part, {})
    return trie_node(root)


def trie_node(node: dict[str, dict]) -> str:
    parts: list[str] = []
    for key in sorted(node):
        child = node[key]
        if child:
            parts.append(f"{key}{trie_node(child)}")
        else:
            parts.append(key)
    return "{" + ",".join(parts) + "}"


def summarize_cases(cases: list[str]) -> Counter[str]:
    counts = Counter()
    for case in cases:
        if case.startswith("KHR-GL46.gpu_shader_fp64.fp64."):
            counts["gpu_shader_fp64.fp64"] += 1
        elif case.startswith("KHR-GL46.gpu_shader_fp64.builtin."):
            counts["gpu_shader_fp64.builtin"] += 1
        elif case.startswith("KHR-GL46.vertex_attrib_64bit."):
            counts["vertex_attrib_64bit"] += 1
        else:
            counts["other"] += 1
    counts["total"] = len(cases)
    return counts


def write_case_artifacts(
    out_dir: Path,
    cases: list[str],
    grouped: OrderedDict[str, list[str]],
) -> None:
    case_dir = out_dir / "case-lists"
    group_dir = case_dir / "groups"
    group_dir.mkdir(parents=True, exist_ok=True)
    (case_dir / "df64-all.cases.txt").write_text("\n".join(cases) + "\n")
    for name, group in grouped.items():
        safe = name.replace(".", "_")
        (group_dir / f"{safe}.cases.txt").write_text("\n".join(group) + "\n")


def run_shard(
    shard: Shard,
    glcts: Path,
    run_cwd: Path,
    env: dict[str, str],
    extra_deqp_args: list[str],
) -> ShardRun:
    start = time.monotonic()
    command = [
        str(glcts),
        f"--deqp-caselist-file={shard.trie_path}",
        f"--deqp-log-filename={shard.qpa_path}",
        "--deqp-surface-type=fbo",
        "--deqp-watchdog=disable",
        "--deqp-log-images=disable",
        "--deqp-terminate-on-fail=disable",
    ] + extra_deqp_args
    with shard.log_path.open("w", encoding="utf-8", errors="replace") as log:
        log.write("$ " + " ".join(command) + "\n")
        log.flush()
        proc = subprocess.run(
            command,
            cwd=str(run_cwd),
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
    elapsed = time.monotonic() - start
    return ShardRun(
        shard=shard,
        returncode=proc.returncode,
        elapsed_seconds=elapsed,
        qpa_size=shard.qpa_path.stat().st_size if shard.qpa_path.exists() else 0,
        log_size=shard.log_path.stat().st_size if shard.log_path.exists() else 0,
    )


def run_shards(
    shards: list[Shard],
    glcts: Path,
    run_cwd: Path,
    env: dict[str, str],
    extra_deqp_args: list[str],
    workers: int,
) -> tuple[list[ShardRun], float]:
    started = time.monotonic()
    results: list[ShardRun] = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(run_shard, shard, glcts, run_cwd, env, extra_deqp_args): shard
            for shard in shards
        }
        for future in as_completed(futures):
            result = future.result()
            results.append(result)
            print(
                f"[done] {result.shard.name}: rc={result.returncode} "
                f"elapsed={format_seconds(result.elapsed_seconds)} "
                f"qpa={result.qpa_size} log={result.log_size}",
                flush=True,
            )
    wall = time.monotonic() - started
    results.sort(key=lambda result: result.shard.index)
    return results, wall


def merge_qpas(qpa_paths: list[Path], out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8", errors="replace") as out:
        out.write("#sessionInfo targetName \"AppGL df64 sharded merge\"\n")
        out.write("#beginSession\n\n")
        for path in qpa_paths:
            if not path.exists():
                continue
            raw = path.read_text(encoding="utf-8", errors="replace")
            for block in raw.split("#beginTestCaseResult")[1:]:
                if "#endTestCaseResult" not in block:
                    continue
                body = block.split("#endTestCaseResult", 1)[0]
                out.write("#beginTestCaseResult")
                out.write(body)
                out.write("#endTestCaseResult\n\n")
        out.write("#endSession\n")


def build_summary(
    cases: list[str],
    shards: list[Shard],
    shard_runs: list[ShardRun],
    wall_seconds: float | None,
    baseline: dict[str, dict[str, float | str]],
    weights: dict[str, dict[str, float | str]],
    baseline_seconds: float,
    expect_pass: int,
    expect_fail: int,
    out_dir: Path,
) -> dict:
    observed: dict[str, dict[str, float | str]] = {}
    for shard in shards:
        if shard.qpa_path.exists():
            observed.update(parse_qpa(shard.qpa_path))

    status_counts = Counter(str(entry["status"]) for entry in observed.values())
    missing = sorted(set(cases) - set(observed)) if observed else []
    extra = sorted(set(observed) - set(cases)) if observed else []
    mismatches = []
    if observed:
        for case, old in baseline.items():
            if case not in observed:
                continue
            old_status = str(old["status"])
            new_status = str(observed[case]["status"])
            if old_status != new_status:
                mismatches.append({
                    "case": case,
                    "baseline": old_status,
                    "observed": new_status,
                })

    run_by_index = {run.shard.index: run for run in shard_runs}
    run_records = []
    for shard in shards:
        run = run_by_index.get(shard.index)
        run_records.append({
            "name": shard.name,
            "index": shard.index,
            "returncode": run.returncode if run is not None else None,
            "elapsed_seconds": (
                round(run.elapsed_seconds, 3) if run is not None else None
            ),
            "cases": len(shard.cases),
            "weight_seconds": round(shard.weight, 3),
            "cases_path": str(shard.cases_path),
            "trie_path": str(shard.trie_path),
            "qpa": str(shard.qpa_path),
            "qpa_size": run.qpa_size if run is not None else 0,
            "log": str(shard.log_path),
            "log_size": run.log_size if run is not None else 0,
        })

    speedup = None
    if wall_seconds and wall_seconds > 0:
        speedup = baseline_seconds / wall_seconds

    pass_count_preserved = None
    if observed:
        pass_count_preserved = (
            status_counts.get("Pass", 0) == expect_pass
            and status_counts.get("Fail", 0) == expect_fail
            and not missing
            and not extra
            and not mismatches
        )

    summary = {
        "case_counts": dict(summarize_cases(cases)),
        "status_counts": dict(status_counts),
        "expected_status_counts": {
            "Pass": expect_pass,
            "Fail": expect_fail,
        },
        "pass_count_preserved": pass_count_preserved,
        "missing_cases": missing,
        "extra_cases": extra,
        "status_mismatches_vs_baseline": mismatches,
        "baseline_cases": len(baseline),
        "weight_cases": len(weights),
        "wall_seconds": round(wall_seconds, 3) if wall_seconds is not None else None,
        "baseline_seconds": baseline_seconds,
        "speedup_vs_baseline": round(speedup, 3) if speedup is not None else None,
        "shards": run_records,
        "merged_qpa": str(out_dir / "merged" / "df64-sharded-merged.qpa"),
    }
    return summary


def write_summary_text(summary: dict, out_path: Path) -> None:
    lines = []
    lines.append("df64 CTS sharding summary")
    lines.append("")
    lines.append(f"cases: {summary['case_counts']}")
    lines.append(f"statuses: {summary['status_counts']}")
    lines.append(f"expected: {summary['expected_status_counts']}")
    lines.append(f"pass_count_preserved: {summary['pass_count_preserved']}")
    lines.append(
        f"baseline_cases: {summary['baseline_cases']} "
        f"weight_cases: {summary['weight_cases']}"
    )
    if summary.get("wall_seconds") is not None:
        lines.append(
            f"wall: {format_seconds(float(summary['wall_seconds']))} "
            f"speedup_vs_baseline: {summary['speedup_vs_baseline']}"
        )
    if summary["missing_cases"]:
        lines.append(f"missing_cases: {len(summary['missing_cases'])}")
    if summary["extra_cases"]:
        lines.append(f"extra_cases: {len(summary['extra_cases'])}")
    if summary["status_mismatches_vs_baseline"]:
        lines.append(
            "status_mismatches_vs_baseline: "
            f"{len(summary['status_mismatches_vs_baseline'])}"
        )
        for item in summary["status_mismatches_vs_baseline"][:20]:
            lines.append(
                f"  {item['baseline']} -> {item['observed']} {item['case']}"
            )
    lines.append("")
    lines.append("shards:")
    for shard in summary["shards"]:
        rc = shard["returncode"] if shard["returncode"] is not None else "not-run"
        elapsed = (
            format_seconds(float(shard["elapsed_seconds"]))
            if shard["elapsed_seconds"] is not None
            else "not-run"
        )
        lines.append(
            f"  {shard['name']}: rc={rc} "
            f"cases={shard['cases']} weight={format_seconds(shard['weight_seconds'])} "
            f"elapsed={elapsed} "
            f"qpa_size={shard['qpa_size']} log_size={shard['log_size']}"
        )
    out_path.write_text("\n".join(lines) + "\n")


def format_seconds(seconds: float) -> str:
    total = int(round(seconds))
    hours, rem = divmod(total, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f"{hours}h{minutes:02d}m{secs:02d}s"
    if minutes:
        return f"{minutes}m{secs:02d}s"
    return f"{secs}s"


def copy_runtime_snapshot(source_dir: Path, out_dir: Path) -> Path:
    source = source_dir / "libAppGL.dylib"
    if not source.exists():
        raise FileNotFoundError(f"missing AppGL dylib: {source}")
    snapshot_dir = out_dir / "runtime-snapshot"
    snapshot_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, snapshot_dir / source.name)
    return snapshot_dir


def parse_args(argv: list[str]) -> argparse.Namespace:
    repo_root, appgl_root = repo_paths()
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    default_glcts = repo_root / "specs" / "VK-GL-CTS" / "build-appgl" / "external" / "openglcts" / "modules" / "glcts"
    default_lib_dir = appgl_root / "build-fp64-phase1"
    default_out = appgl_root / "tests" / "reports" / "df64-shards" / f"run-{timestamp}"

    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument("--workers", type=int, required=True, help="Number of concurrent glcts processes.")
    parser.add_argument("--out-dir", type=Path, default=default_out, help="Output directory for shards, QPAs, logs, and summary.")
    parser.add_argument("--glcts", type=Path, default=default_glcts, help="Path to glcts executable.")
    parser.add_argument("--appgl-lib-dir", type=Path, default=default_lib_dir, help="Directory containing libAppGL.dylib.")
    parser.add_argument("--label", default="df64", help="Short label used in shard artifact filenames.")
    parser.add_argument("--case-file", type=Path, help="Reuse an existing plain case-name file instead of exporting.")
    parser.add_argument("--prepare-only", action="store_true", help="Export and write shards, but do not run glcts.")
    parser.add_argument("--no-runtime-snapshot", action="store_true", help="Use --appgl-lib-dir directly instead of copying libAppGL.dylib.")
    parser.add_argument("--baseline-qpa", action="append", type=Path, default=[], help="QPA used for status preservation. Can repeat.")
    parser.add_argument("--no-default-baseline-qpas", action="store_true", help="Do not use the Phase 7.2x default baseline QPAs.")
    parser.add_argument("--weight-qpa", action="append", type=Path, default=[], help="QPA used for shard weighting. Can repeat.")
    parser.add_argument("--no-default-weight-qpas", action="store_true", help="Do not use the Phase 2 real-device QPAs for shard weighting.")
    parser.add_argument("--baseline-seconds", type=float, default=DEFAULT_BASELINE_SECONDS, help="Unsharded wall-clock baseline for speedup calculation.")
    parser.add_argument("--expect-pass", type=int, default=DEFAULT_EXPECTED_PASS, help="Expected Pass count for preservation.")
    parser.add_argument("--expect-fail", type=int, default=DEFAULT_EXPECTED_FAIL, help="Expected Fail count for preservation.")
    parser.add_argument("--env", action="append", default=[], help="Extra environment KEY=VALUE for glcts.")
    parser.add_argument("--extra-deqp-arg", action="append", default=[], help="Extra deqp argument appended to each shard run.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.workers < 1:
        raise SystemExit("--workers must be >= 1")

    repo_root, appgl_root = repo_paths()
    args.out_dir = args.out_dir.resolve()
    args.glcts = args.glcts.resolve()
    args.appgl_lib_dir = args.appgl_lib_dir.resolve()
    cts_dir = args.glcts.parent
    args.out_dir.mkdir(parents=True, exist_ok=True)

    lib_dir = args.appgl_lib_dir
    if not args.no_runtime_snapshot:
        lib_dir = copy_runtime_snapshot(lib_dir, args.out_dir).resolve()

    env = make_env(lib_dir, args.env)

    baseline_paths = [] if args.no_default_baseline_qpas else default_baseline_qpas(appgl_root)
    baseline_paths.extend(args.baseline_qpa)
    baseline = load_baseline(baseline_paths)

    weight_paths = [] if args.no_default_weight_qpas else default_weight_qpas(appgl_root)
    weight_paths.extend(args.weight_qpa)
    existing_weight_paths = [path for path in weight_paths if path.exists()]
    weights = load_baseline(weight_paths) if existing_weight_paths else baseline
    weight_source = "weight_qpas" if existing_weight_paths else "baseline_qpas"

    if args.case_file:
        cases = load_case_file(args.case_file)
    else:
        cases = export_cases(args.glcts, cts_dir, env)

    grouped = group_cases(cases)
    write_case_artifacts(args.out_dir, cases, grouped)
    shards = assign_shards(cases, grouped, weights, args.workers, args.out_dir, args.label)

    manifest = {
        "repo_root": str(repo_root),
        "appgl_root": str(appgl_root),
        "glcts": str(args.glcts),
        "cts_dir": str(cts_dir),
        "run_cwd": str(lib_dir),
        "appgl_lib_dir_used": str(lib_dir),
        "runtime_snapshot": not args.no_runtime_snapshot,
        "workers": args.workers,
        "case_patterns": CASE_PATTERNS,
        "case_counts": dict(summarize_cases(cases)),
        "groups": {name: len(group) for name, group in grouped.items()},
        "baseline_qpas": [str(path) for path in baseline_paths if path.exists()],
        "weight_source": weight_source,
        "weight_qpas": [str(path) for path in weight_paths if path.exists()],
        "baseline_cases": len(baseline),
        "weight_cases": len(weights),
        "shards": [
            {
                "name": shard.name,
                "index": shard.index,
                "cases": len(shard.cases),
                "weight_seconds": round(shard.weight, 3),
                "cases_path": str(shard.cases_path),
                "trie_path": str(shard.trie_path),
                "qpa_path": str(shard.qpa_path),
                "log_path": str(shard.log_path),
            }
            for shard in shards
        ],
    }
    (args.out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    counts = summarize_cases(cases)
    print(
        f"prepared {counts['total']} cases: "
        f"fp64={counts['gpu_shader_fp64.fp64']} "
        f"builtin={counts['gpu_shader_fp64.builtin']} "
        f"vertex64={counts['vertex_attrib_64bit']}"
    )
    print(
        f"baseline cases={len(baseline)} weight cases={len(weights)} "
        f"weight_source={weight_source}"
    )
    for shard in shards:
        print(
            f"  {shard.name}: cases={len(shard.cases)} "
            f"weight={format_seconds(shard.weight)}"
        )

    if counts["total"] != EXPECTED_TOTAL_CASES:
        print(
            f"WARNING: expected {EXPECTED_TOTAL_CASES} cases, got {counts['total']}",
            file=sys.stderr,
        )

    shard_runs: list[ShardRun] = []
    wall_seconds: float | None = None
    if not args.prepare_only:
        print(f"running {len(shards)} shards with {args.workers} workers")
        shard_runs, wall_seconds = run_shards(
            shards,
            args.glcts,
            lib_dir,
            env,
            args.extra_deqp_arg,
            args.workers,
        )
        merge_qpas([shard.qpa_path for shard in shards], args.out_dir / "merged" / "df64-sharded-merged.qpa")

    summary = build_summary(
        cases,
        shards,
        shard_runs,
        wall_seconds,
        baseline,
        weights,
        args.baseline_seconds,
        args.expect_pass,
        args.expect_fail,
        args.out_dir,
    )
    (args.out_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    write_summary_text(summary, args.out_dir / "summary.txt")

    print(f"summary: {args.out_dir / 'summary.txt'}")
    if not args.prepare_only:
        print(f"statuses: {summary['status_counts']}")
        print(f"pass_count_preserved: {summary['pass_count_preserved']}")
        if summary.get("wall_seconds") is not None:
            print(
                f"wall={format_seconds(float(summary['wall_seconds']))} "
                f"speedup={summary['speedup_vs_baseline']}x"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
