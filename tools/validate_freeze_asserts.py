#!/usr/bin/env python3
"""Validate AppGL freeze proof assertions with polarity-aware checks.

The freezer emits source_worktree_dirty=false when the source tree is clean.
This validator treats that as a positive source_worktree_clean=true assertion
instead of feeding the raw map to all(asserts.values()).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


FALSE_IS_PASS_ASSERTS = {
    "source_worktree_dirty": "source_worktree_clean",
}

B2_LINE_HELPER_TOKENS = (
    "framebufferAttachmentColorChannelSize",
    "FboColorAlphaMode",
    "blendFactorWithEffectiveDestinationAlpha",
    "B2b RGB/no-alpha",
)

SOURCE_SUFFIXES = {
    ".c",
    ".cc",
    ".cpp",
    ".h",
    ".hpp",
    ".m",
    ".mm",
}


def load_asserts(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        proof = json.load(handle)
    asserts = proof.get("asserts")
    if not isinstance(asserts, dict):
        raise ValueError(f"{path} does not contain an object-valued 'asserts' map")
    return asserts


def normalize_asserts(asserts: dict[str, Any]) -> tuple[dict[str, bool], list[str]]:
    normalized: dict[str, bool] = {}
    failures: list[str] = []
    for key in sorted(asserts):
        value = asserts[key]
        if key in FALSE_IS_PASS_ASSERTS:
            clean_key = FALSE_IS_PASS_ASSERTS[key]
            if value is False:
                normalized[clean_key] = True
            else:
                normalized[clean_key] = False
                failures.append(f"{key}=true; expected false clean-state polarity")
            continue
        if value is True:
            normalized[key] = True
        else:
            normalized[key] = False
            failures.append(f"{key}={value!r}; expected true")
    return normalized, failures


def source_text(root: Path) -> str:
    src_root = root / "src"
    if not src_root.is_dir():
        raise ValueError(f"{src_root} is not a directory")
    chunks: list[str] = []
    for path in sorted(src_root.rglob("*")):
        if not path.is_file() or path.suffix not in SOURCE_SUFFIXES:
            continue
        try:
            chunks.append(path.read_text(encoding="utf-8", errors="ignore"))
        except OSError as exc:
            raise ValueError(f"failed to read {path}: {exc}") from exc
    return "\n".join(chunks)


def validate_b2_line_helpers(root: Path) -> tuple[dict[str, bool], list[str]]:
    text = source_text(root)
    results = {
        f"helper:{token}": token in text
        for token in B2_LINE_HELPER_TOKENS
    }
    failures = [
        f"missing B2-line helper/source token: {token}"
        for token in B2_LINE_HELPER_TOKENS
        if token not in text
    ]
    return results, failures


def write_normalized(path: Path, normalized: dict[str, bool]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{key}={str(value).lower()}" for key, value in sorted(normalized.items())]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate AppGL freeze proof assertions."
    )
    parser.add_argument("proof_json", type=Path, help="FREEZE-PROOF*.json path")
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path.cwd(),
        help="source checkout root for helper probes",
    )
    parser.add_argument(
        "--profile",
        choices=("generic", "r06-b2-line"),
        default="generic",
        help="optional source-token probe profile",
    )
    parser.add_argument(
        "--emit-normalized",
        type=Path,
        help="write normalized assertion key/value lines",
    )
    args = parser.parse_args(argv)

    try:
        asserts = load_asserts(args.proof_json)
        normalized, failures = normalize_asserts(asserts)
        if args.profile == "r06-b2-line":
            helper_results, helper_failures = validate_b2_line_helpers(
                args.source_root
            )
            normalized.update(helper_results)
            failures.extend(helper_failures)
        if args.emit_normalized is not None:
            write_normalized(args.emit_normalized, normalized)
    except Exception as exc:
        print(f"freeze_asserts_pass=false", file=sys.stderr)
        print(f"error={exc}", file=sys.stderr)
        return 2

    if failures:
        print("freeze_asserts_pass=false")
        for failure in failures:
            print(f"failure={failure}")
        return 1

    print("freeze_asserts_pass=true")
    for key, value in sorted(normalized.items()):
        print(f"{key}={str(value).lower()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
