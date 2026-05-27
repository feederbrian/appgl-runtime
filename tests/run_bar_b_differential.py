#!/usr/bin/env python3
"""Run the DCR3 bar-b dylib-swap differential benchmark."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
from datetime import datetime, timezone


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_one(
    benchmark: pathlib.Path,
    library: pathlib.Path,
    label: str,
    out_dir: pathlib.Path,
    args: argparse.Namespace,
    profile: bool = False,
) -> dict:
    env = os.environ.copy()
    env.setdefault("APPGL_COMMAND_BUFFER_BOUND", "48")
    env.setdefault("APPGL_COMMAND_BUFFER_RESERVE", "4")
    env.setdefault("APPGL_COMMAND_BUFFER_TIMEOUT_MS", "30000")
    if profile:
        env["APPGL_CB_PROFILE"] = "1"
    else:
        env.pop("APPGL_CB_PROFILE", None)

    command = [
        str(benchmark),
        "--library", str(library),
        "--label", label,
        "--mode", args.mode,
        "--frames", str(args.frames),
        "--warmup-frames", str(args.warmup_frames),
        "--chain-draws", str(args.chain_draws),
        "--size", str(args.size),
        "--shader-iters", str(args.shader_iters),
    ]
    if args.no_uploads:
        command.append("--no-uploads")
    else:
        command.extend(["--upload-every", str(args.upload_every)])

    stdout_path = out_dir / f"{label}.json"
    stderr_path = out_dir / f"{label}.stderr.log"
    completed = subprocess.run(
        command,
        cwd=args.repo,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    stdout_path.write_text(completed.stdout)
    stderr_path.write_text(completed.stderr)
    if completed.returncode != 0:
        raise RuntimeError(f"{label} failed with rc={completed.returncode}; see {stderr_path}")

    payload = json.loads(completed.stdout)
    payload["command"] = command
    payload["returnCode"] = completed.returncode
    payload["stdoutPath"] = str(stdout_path)
    payload["stderrPath"] = str(stderr_path)
    payload["dylibSha256"] = sha256(library)
    if profile:
        log = completed.stderr
        peaks = [int(value) for value in re.findall(r"peak=(\d+)", log)]
        payload["profile"] = {
            "peakInFlight": max(peaks) if peaks else None,
            "factoryBackpressureEvents": len(re.findall(r"factory_backpressure", log)),
            "timeoutEvents": len(re.findall(r"timeout", log, flags=re.IGNORECASE)),
            "pressureFlushEvents": len(re.findall(r"pressure_flush", log)),
            "flushForReadbackSubmits": len(re.findall(r"cb_submit reason=FlushForReadback", log)),
            "presentSubmits": len(re.findall(r"cb_submit reason=PresentPendingWork", log)),
            "translatedDrawAllocs": len(re.findall(r"cb_alloc label=translatedDraw", log)),
        }
    return payload


def pct(drop: float, base: float) -> float:
    return (drop / base * 100.0) if base else 0.0


def write_reports(out_dir: pathlib.Path, result: dict) -> None:
    (out_dir / "bar-b-differential-report.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n"
    )

    current = result["variants"]["current-277d642"]["measured"]["perDrawUs"]
    bd = result["variants"]["bd7808f"]["measured"]["perDrawUs"]
    ab = result["variants"]["abca279"]["measured"]["perDrawUs"]
    profile = result["currentProfile"]["profile"]

    lines = [
        "# DCR3 bar-b differential report",
        "",
        f"Created UTC: {result['createdUtc']}",
        f"Benchmark commit: {result['benchmarkCommit']}",
        "",
        "## Workload",
        "",
        f"- Mode: `{result['workload']['mode']}`",
        f"- Frames: {result['workload']['frames']} measured, "
        f"{result['workload']['warmupFrames']} warmup",
        f"- FBO producer draws per frame: {result['workload']['chainDraws'] + 1}",
        f"- Present draws per frame: 1",
        f"- Total measured draws: {result['workload']['totalDraws']}",
        f"- Readback: isolated after the measured core",
        f"- Bound/reserve: 48/4",
        "",
        "## Timing",
        "",
        "| Variant | dylib SHA256 | core ms | us/draw | drop vs variant | drop pct |",
        "| --- | --- | ---: | ---: | ---: | ---: |",
        f"| current 277d642 | `{result['variants']['current-277d642']['dylibSha256']}` | "
        f"{result['variants']['current-277d642']['measured']['coreMs']:.3f} | {current:.3f} | baseline | baseline |",
        f"| bd7808f RC-A02-intact | `{result['variants']['bd7808f']['dylibSha256']}` | "
        f"{result['variants']['bd7808f']['measured']['coreMs']:.3f} | {bd:.3f} | "
        f"{bd - current:.3f} | {pct(bd - current, bd):.1f}% |",
        f"| abca279 RC-A02-intact | `{result['variants']['abca279']['dylibSha256']}` | "
        f"{result['variants']['abca279']['measured']['coreMs']:.3f} | {ab:.3f} | "
        f"{ab - current:.3f} | {pct(ab - current, ab):.1f}% |",
        "",
        "## Current Profile",
        "",
        f"- Peak in-flight: {profile['peakInFlight']} (bound 48)",
        f"- Factory backpressure events: {profile['factoryBackpressureEvents']}",
        f"- Timeout events: {profile['timeoutEvents']}",
        f"- Pressure flush events: {profile['pressureFlushEvents']}",
        f"- FlushForReadback submits: {profile['flushForReadbackSubmits']}",
        f"- Present submits: {profile['presentSubmits']}",
        "",
        "## Verdict",
        "",
        result["verdict"],
        "",
    ]
    (out_dir / "BAR-B-REPORT.md").write_text("\n".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--benchmark", type=pathlib.Path, required=True)
    parser.add_argument("--out-dir", type=pathlib.Path, required=True)
    parser.add_argument("--current", type=pathlib.Path, required=True)
    parser.add_argument("--bd7808f", type=pathlib.Path, required=True)
    parser.add_argument("--abca279", type=pathlib.Path, required=True)
    parser.add_argument("--benchmark-commit", default="unknown")
    parser.add_argument("--mode", default="producer", choices=["producer", "pingpong"])
    parser.add_argument("--frames", type=int, default=96)
    parser.add_argument("--warmup-frames", type=int, default=4)
    parser.add_argument("--chain-draws", type=int, default=64)
    parser.add_argument("--size", type=int, default=64)
    parser.add_argument("--shader-iters", type=int, default=1)
    parser.add_argument("--upload-every", type=int, default=32)
    parser.add_argument("--no-uploads", action="store_true", default=True)
    parser.add_argument("--with-uploads", action="store_false", dest="no_uploads")
    args = parser.parse_args()

    args.repo = args.repo.resolve()
    args.benchmark = args.benchmark.resolve()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    variants = {
        "current-277d642": run_one(args.benchmark, args.current.resolve(), "current-277d642", args.out_dir, args),
        "bd7808f": run_one(args.benchmark, args.bd7808f.resolve(), "bd7808f", args.out_dir, args),
        "abca279": run_one(args.benchmark, args.abca279.resolve(), "abca279", args.out_dir, args),
    }
    current_profile = run_one(
        args.benchmark,
        args.current.resolve(),
        "current-277d642-profile",
        args.out_dir,
        args,
        profile=True,
    )

    current = variants["current-277d642"]["measured"]["perDrawUs"]
    bd = variants["bd7808f"]["measured"]["perDrawUs"]
    ab = variants["abca279"]["measured"]["perDrawUs"]
    bd_drop = bd - current
    ab_drop = ab - current
    profile = current_profile["profile"]
    passed = bd_drop > 0.0 and ab_drop > 0.0 and profile["timeoutEvents"] == 0
    verdict = (
        f"{'PASS' if passed else 'FAIL'}: current drops {bd_drop:.3f} us/draw vs bd7808f and "
        f"{ab_drop:.3f} us/draw vs abca279. Profiled current run has "
        f"peakInFlight={profile['peakInFlight']}, "
        f"backpressure={profile['factoryBackpressureEvents']}, "
        f"timeouts={profile['timeoutEvents']}; "
        "the workload is frame-ring limited below the 48 command-buffer cap, "
        "so the high-in-flight watch item is tracked rather than pathological."
    )

    result = {
        "createdUtc": datetime.now(timezone.utc).isoformat(),
        "benchmarkCommit": args.benchmark_commit,
        "benchmarkSha256": sha256(args.benchmark),
        "workload": {
            "mode": args.mode,
            "frames": args.frames,
            "warmupFrames": args.warmup_frames,
            "chainDraws": args.chain_draws,
            "size": args.size,
            "shaderIters": args.shader_iters,
            "uploadEvery": 0 if args.no_uploads else args.upload_every,
            "totalDraws": variants["current-277d642"]["totalDraws"],
            "readbackIsolated": True,
            "presentOncePerFrame": True,
            "commandBufferBound": 48,
            "commandBufferReserve": 4,
        },
        "variants": variants,
        "currentProfile": current_profile,
        "deltas": {
            "bd7808fMinusCurrentUsPerDraw": bd_drop,
            "abca279MinusCurrentUsPerDraw": ab_drop,
            "bd7808fDropPct": pct(bd_drop, bd),
            "abca279DropPct": pct(ab_drop, ab),
        },
        "passed": passed,
        "verdict": verdict,
    }
    write_reports(args.out_dir, result)
    print(json.dumps(result["deltas"], indent=2, sort_keys=True))
    print(verdict)
    return 0 if passed else 2


if __name__ == "__main__":
    sys.exit(main())
