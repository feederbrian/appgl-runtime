#!/usr/bin/env bash
# Run the vacuous-pass detector against tessellation_shader.* for both
# the env-off and env-on (APPGL_LIFT_TESS_UNIFORM_GUARD=1) configurations.
# Produces a combined JSONL sidecar in specs-worker-docs/ and prints a
# side-by-side summary.
#
# Usage:
#   tools/run_detector_baseline.sh
#   tools/run_detector_baseline.sh --case 'KHR-GL46.tessellation_shader.tessellation_invariance.*'
#   tools/run_detector_baseline.sh --skip-env-off       # only run env-on
#   tools/run_detector_baseline.sh --reuse-logs         # skip CTS, reclassify from /tmp/detector-*.{qpa,log}
#
# Outputs:
#   /tmp/detector-{off,on}-<date>.qpa
#   /tmp/detector-{off,on}-<date>.log     (merged stdout+stderr)
#   specs-worker-docs/detector-baseline-<date>.jsonl

set -euo pipefail

# Locate the project root from this script's own location rather than a
# hardcoded absolute path, so the tool works from any checkout and for any
# user. Layout assumed: <project-root>/appgl-runtime/tools/<this script>
# Override with APPGL_PROJECT_ROOT if the tree is arranged differently.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPGL_RUNTIME="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="${APPGL_PROJECT_ROOT:-$(cd -- "${APPGL_RUNTIME}/.." && pwd)}"
CTS_DIR="${REPO_ROOT}/specs/VK-GL-CTS/build-appgl/external/openglcts/modules"
GLCTS="${CTS_DIR}/glcts"
CLASSIFY="${APPGL_RUNTIME}/tools/detector_classify.py"

CASE='KHR-GL46.tessellation_shader.*'
RUN_OFF=1
RUN_ON=1
REUSE_LOGS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --case)         CASE="$2"; shift 2 ;;
        --skip-env-off) RUN_OFF=0;  shift ;;
        --skip-env-on)  RUN_ON=0;   shift ;;
        --reuse-logs)   REUSE_LOGS=1; shift ;;
        -h|--help)
            sed -n '2,19p' "$0"
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

DATE="$(date +%Y-%m-%d)"
OUT_JSONL="${REPO_ROOT}/specs-worker-docs/detector-baseline-${DATE}.jsonl"
mkdir -p "$(dirname "$OUT_JSONL")"
: > "$OUT_JSONL"

echo "Detector baseline sweep — case='${CASE}'"
echo "  glcts:    $GLCTS"
echo "  classify: $CLASSIFY"
echo "  jsonl:    $OUT_JSONL"
echo

run_sweep() {
    local label="$1"
    shift
    # remaining args are NAME=VALUE pairs to layer on top of APPGL_DETECTOR_TF=1
    local qpa="/tmp/detector-${label}-${DATE}.qpa"
    local log="/tmp/detector-${label}-${DATE}.log"

    if [[ $REUSE_LOGS -eq 1 ]]; then
        echo "=== reclassify: ${label}  (--reuse-logs, no CTS run) ==="
    else
        echo "=== sweep: ${label}  (extra-env: ${*:-<none>}) ==="
        pushd "$CTS_DIR" >/dev/null
        # `2>&1 | tee` interleaves stdout (deqp test markers) and stderr
        # (runtime detector lines) so the classifier can pair them.
        env APPGL_DETECTOR_TF=1 "$@" ./glcts \
            --deqp-case="$CASE" \
            --deqp-log-filename="$qpa" 2>&1 | tee "$log" >/dev/null || true
        popd >/dev/null
    fi

    if [[ ! -s "$qpa" ]]; then
        echo "  WARNING: QPA not present at $qpa" >&2
        if [[ $REUSE_LOGS -eq 0 ]]; then
            echo "  (CTS may have crashed before writing — see $log)" >&2
            tail -20 "$log" >&2 || true
        fi
        return 1
    fi

    echo "--- classify: ${label} ---"
    python3 "$CLASSIFY" \
        --qpa "$qpa" \
        --log "$log" \
        --env "${label}" \
        --out "$OUT_JSONL" \
        --append
    echo
}

SWEEP_OK=1
if [[ $RUN_OFF -eq 1 ]]; then
    run_sweep env-off || SWEEP_OK=0
fi
if [[ $RUN_ON -eq 1 ]]; then
    run_sweep env-on APPGL_LIFT_TESS_UNIFORM_GUARD=1 || SWEEP_OK=0
fi

echo "=== combined JSONL: $OUT_JSONL ==="
echo "lines: $(wc -l < "$OUT_JSONL")"
echo
echo "side-by-side classification by env:"
python3 - <<PY "$OUT_JSONL"
import json, sys, collections
path = sys.argv[1]
by_env = collections.defaultdict(collections.Counter)
for line in open(path):
    r = json.loads(line)
    by_env[r["env"]][r["classification"]] += 1
keys = ["GENUINE_PASS", "VACUOUS_PASS", "NO_TF_READ_PASS",
        "GENUINE_FAIL", "NOT_SUPPORTED", "PENDING"]
envs = sorted(by_env)
print(f"  {'classification':22s} " + " ".join(f"{e:>10s}" for e in envs))
for k in keys:
    print(f"  {k:22s} " + " ".join(f"{by_env[e].get(k,0):10d}" for e in envs))
print()
for e in envs:
    s = by_env[e]
    denom = sum(s[k] for k in ["GENUINE_PASS", "VACUOUS_PASS",
                               "NO_TF_READ_PASS", "GENUINE_FAIL", "PENDING"])
    if not denom: continue
    gen, vac, nor = s["GENUINE_PASS"], s["VACUOUS_PASS"], s["NO_TF_READ_PASS"]
    print(f"  [{e}] genuine={gen}/{denom} ({gen/denom:.1%})  "
          f"vacuous={vac}/{denom} ({vac/denom:.1%})  "
          f"no-tf-read={nor}/{denom} ({nor/denom:.1%})")
PY
