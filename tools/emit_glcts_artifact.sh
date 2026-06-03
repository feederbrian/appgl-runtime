#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  tools/emit_glcts_artifact.sh \
    --artifact-id ID \
    --build-dir BUILD_DIR \
    --variant VARIANT \
    --source-commit SHA \
    --parent-commit SHA \
    --schema SCHEMA \
    [--output-root DIR] \
    [--cts-modules DIR] \
    [--cluster-check-root DIR] \
    [--sentinels TEXT] \
    [--notes TEXT] \
    [--diagnostic-label TEXT] \
    [--no-preflight]

Emits a CTS runnable artifact containing:
  libAppGL.dylib, current-lib/libAppGL.dylib, glcts, and gl_cts/data.

The gl_cts/data payload is mandatory because shader/preprocessor CTS cases
load files relative to the glcts working directory.

Release-shape enforcement is ON by default. Use --diagnostic-label for explicit
diagnostic/debug artifact opt-out; diagnostic artifacts still emit full binary
shape evidence.
EOF
}

die() {
    printf 'emit_glcts_artifact: %s\n' "$*" >&2
    exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$(cd "$repo_root/.." && pwd)"

artifact_id=""
build_dir=""
variant=""
source_commit=""
parent_commit=""
schema=""
output_root="$repo_root/tests/reports/s22-fantastic-rebuild"
cts_modules="$workspace_root/specs/VK-GL-CTS/build-appgl/external/openglcts/modules"
cluster_check_root=""
sentinels=""
notes=""
diagnostic_label=""
run_preflight=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --artifact-id) artifact_id="${2:-}"; shift 2 ;;
        --build-dir) build_dir="${2:-}"; shift 2 ;;
        --variant) variant="${2:-}"; shift 2 ;;
        --source-commit) source_commit="${2:-}"; shift 2 ;;
        --parent-commit) parent_commit="${2:-}"; shift 2 ;;
        --schema) schema="${2:-}"; shift 2 ;;
        --output-root) output_root="${2:-}"; shift 2 ;;
        --cts-modules) cts_modules="${2:-}"; shift 2 ;;
        --cluster-check-root) cluster_check_root="${2:-}"; shift 2 ;;
        --sentinels) sentinels="${2:-}"; shift 2 ;;
        --notes) notes="${2:-}"; shift 2 ;;
        --diagnostic-label) diagnostic_label="${2:-}"; shift 2 ;;
        --no-preflight) run_preflight=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$artifact_id" ] || die "--artifact-id is required"
[ -n "$build_dir" ] || die "--build-dir is required"
[ -n "$variant" ] || die "--variant is required"
[ -n "$source_commit" ] || die "--source-commit is required"
[ -n "$parent_commit" ] || die "--parent-commit is required"
[ -n "$schema" ] || die "--schema is required"

build_dir="$(cd "$build_dir" && pwd)"
output_root="$(mkdir -p "$output_root" && cd "$output_root" && pwd)"
cts_modules="$(cd "$cts_modules" && pwd)"
artifact_dir="$output_root/$artifact_id"

dylib="$build_dir/libAppGL.dylib"
glcts="$cts_modules/glcts"
cts_data="$cts_modules/gl_cts/data"

[ -f "$dylib" ] || die "missing dylib: $dylib"
[ -x "$glcts" ] || die "missing executable glcts: $glcts"
[ -d "$cts_data" ] || die "missing CTS data directory: $cts_data"
[ -f "$cts_data/gl30/declarations.test" ] || die "CTS data incomplete: missing gl30/declarations.test"

printf '[emit] artifact: %s\n' "$artifact_dir"
printf '[emit] dylib:    %s\n' "$dylib"
printf '[emit] glcts:    %s\n' "$glcts"
printf '[emit] cts data: %s\n' "$cts_data"

rm -rf "$artifact_dir"
mkdir -p "$artifact_dir/current-lib" "$artifact_dir/gl_cts" \
         "$artifact_dir/qpa" "$artifact_dir/logs" "$artifact_dir/status" \
         "$artifact_dir/shape"

cp -p "$dylib" "$artifact_dir/libAppGL.dylib"
cp -p "$dylib" "$artifact_dir/current-lib/libAppGL.dylib"
cp -p "$glcts" "$artifact_dir/glcts"
/usr/bin/ditto "$cts_data" "$artifact_dir/gl_cts/data"

[ -f "$artifact_dir/gl_cts/data/gl30/declarations.test" ] \
    || die "emitted artifact is missing gl_cts/data/gl30/declarations.test"

dylib_sha="$(shasum -a 256 "$artifact_dir/libAppGL.dylib" | awk '{print $1}')"
glcts_sha="$(shasum -a 256 "$artifact_dir/glcts" | awk '{print $1}')"
dylib_uuid="$(dwarfdump --uuid "$artifact_dir/libAppGL.dylib" | awk '/UUID:/ {print $2; exit}')"
dylib_size="$(stat -f '%z' "$artifact_dir/libAppGL.dylib")"
shape_report="$artifact_dir/shape/binary-shape.txt"
shape_args=(
    "$repo_root/tools/appgl_binary_shape_report.sh"
    --dylib "$artifact_dir/libAppGL.dylib"
    --out "$shape_report"
    --cmake-cache "$build_dir/CMakeCache.txt"
    --artifact-id "$artifact_id"
    --variant "$variant"
    --source-commit "$source_commit"
    --parent-commit "$parent_commit"
    --require-release-shape
)
if [ -n "$diagnostic_label" ]; then
    shape_args+=(--diagnostic-label "$diagnostic_label")
fi
"${shape_args[@]}"
shape_sha="$(shasum -a 256 "$shape_report" | awk '{print $1}')"
release_shape_status="$(awk -F': ' '/^release_shape_status:/ {print $2; exit}' "$shape_report")"
nm_m_lines="$(awk -F': ' '/^nm_m_lines:/ {print $2; exit}' "$shape_report")"
stubs_size="$(awk -F': ' '/^__stubs_size_bytes:/ {print $2; exit}' "$shape_report")"
linkedit_filesize="$(awk -F': ' '/^__LINKEDIT_filesize:/ {print $2; exit}' "$shape_report")"
linkedit_vmsize="$(awk -F': ' '/^__LINKEDIT_vmsize:/ {print $2; exit}' "$shape_report")"
spirv_cross_head="unknown"
if [ -d "$repo_root/third_party/SPIRV-Cross/.git" ]; then
    spirv_cross_head="$(git -C "$repo_root/third_party/SPIRV-Cross" rev-parse HEAD)"
fi

(
    cd "$artifact_dir"
    find gl_cts/data -type f ! -name '.DS_Store' | LC_ALL=C sort | while IFS= read -r file; do
        shasum -a 256 "$file"
    done > gl_cts/data.sha256
)
cts_data_file_count="$(find "$artifact_dir/gl_cts/data" -type f ! -name '.DS_Store' | wc -l | tr -d ' ')"
cts_data_manifest_sha="$(shasum -a 256 "$artifact_dir/gl_cts/data.sha256" | awk '{print $1}')"

cp -p "$artifact_dir/libAppGL.dylib" "$artifact_dir/current-lib/libAppGL.dylib"
printf '%s  %s\n' "$dylib_sha" "$artifact_dir/libAppGL.dylib" > "$artifact_dir/libAppGL.dylib.sha256"
printf '%s  %s\n' "$dylib_sha" "$artifact_dir/current-lib/libAppGL.dylib" > "$artifact_dir/current-lib/libAppGL.dylib.sha256"

cat > "$artifact_dir/libAppGL.dylib.meta" <<EOF
artifact_id: $artifact_id
variant: $variant
source_commit: $source_commit
dylib_sha256: $dylib_sha
dylib_uuid: $dylib_uuid
dylib_size_bytes: $dylib_size
binary_shape_report: shape/binary-shape.txt
binary_shape_sha256: $shape_sha
release_shape_status: $release_shape_status
nm_m_lines: $nm_m_lines
__stubs_size_bytes: $stubs_size
__LINKEDIT_filesize: $linkedit_filesize
__LINKEDIT_vmsize: $linkedit_vmsize
EOF
cp -p "$artifact_dir/libAppGL.dylib.meta" "$artifact_dir/current-lib/libAppGL.dylib.meta"

preflight_status="not-run"
preflight_text="not-run"
if [ "$run_preflight" -eq 1 ]; then
    set +e
    (
        cd "$artifact_dir" &&
        DYLD_LIBRARY_PATH="$artifact_dir" \
        APPGL_ENABLE_METAL_TESS=1 \
        APPGL_ENABLE_METAL_TESS_TF=1 \
        APPGL_ENABLE_TESS_EMUL=1 \
        APPGL_ENABLE_TESS_EMUL_GLIN=1 \
        APPGL_LIFT_TESS_UNIFORM_GUARD=1 \
        ./glcts \
            --deqp-case=dEQP-GL45-ES3.info.renderer \
            --deqp-log-filename="$artifact_dir/qpa/renderer-preflight.qpa" \
            --deqp-watchdog=disable \
            --deqp-log-images=disable \
            --deqp-terminate-on-fail=disable \
            > "$artifact_dir/logs/renderer-preflight.stdout" \
            2> "$artifact_dir/logs/renderer-preflight.stderr"
    )
    rc="$?"
    set -e
    printf '%s\n' "$rc" > "$artifact_dir/status/renderer-preflight.rc"
    preflight_status="rc=$rc"
    preflight_text="dEQP-GL45-ES3.info.renderer window-default"
    [ "$rc" -eq 0 ] || die "renderer preflight failed with rc=$rc"
fi

created_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
meta_file="$artifact_dir/$artifact_id.meta"
{
    printf 'schema: %s\n' "$schema"
    printf 'artifact_id: %s\n' "$artifact_id"
    printf 'created_utc: "%s"\n' "$created_utc"
    printf 'source_commit: %s\n' "$source_commit"
    printf 'parent_commit: %s\n' "$parent_commit"
    printf 'spirv_cross_head: %s\n' "$spirv_cross_head"
    printf 'variant: %s\n' "$variant"
    printf 'dylib_sha256: %s\n' "$dylib_sha"
    printf 'dylib_uuid: %s\n' "$dylib_uuid"
    printf 'dylib_size_bytes: %s\n' "$dylib_size"
    printf 'binary_shape_report: %s\n' "shape/binary-shape.txt"
    printf 'binary_shape_sha256: %s\n' "$shape_sha"
    printf 'release_shape_status: "%s"\n' "$release_shape_status"
    printf 'nm_m_lines: %s\n' "$nm_m_lines"
    printf '__stubs_size_bytes: %s\n' "$stubs_size"
    printf '__LINKEDIT_filesize: %s\n' "$linkedit_filesize"
    printf '__LINKEDIT_vmsize: %s\n' "$linkedit_vmsize"
    printf 'glcts_sha256: %s\n' "$glcts_sha"
    printf 'cts_data_source: %s\n' "$cts_data"
    printf 'cts_data_file_count: %s\n' "$cts_data_file_count"
    printf 'cts_data_manifest_sha256: %s\n' "$cts_data_manifest_sha"
    printf 'preflight: "%s"\n' "$preflight_text"
    printf 'preflight_status: "%s"\n' "$preflight_status"
    [ -z "$cluster_check_root" ] || printf 'cluster_check_root: %s\n' "$cluster_check_root"
    [ -z "$sentinels" ] || printf 'sentinels: "%s"\n' "$sentinels"
    [ -z "$notes" ] || printf 'notes: "%s"\n' "$notes"
    [ -z "$diagnostic_label" ] || printf 'diagnostic_label: "%s"\n' "$diagnostic_label"
} > "$meta_file"

{
    printf '%s  %s\n' "$dylib_sha" "$artifact_dir/libAppGL.dylib"
    printf '%s  %s\n' "$dylib_sha" "$artifact_dir/current-lib/libAppGL.dylib"
    printf '%s  %s\n' "$glcts_sha" "$artifact_dir/glcts"
    printf '%s  %s\n' "$cts_data_manifest_sha" "$artifact_dir/gl_cts/data.sha256"
    printf '%s  %s\n' "$shape_sha" "$shape_report"
} > "$artifact_dir/SHA256SUMS"

printf '[emit] complete: %s\n' "$artifact_dir"
printf '[emit] cts data files: %s manifest_sha256=%s\n' "$cts_data_file_count" "$cts_data_manifest_sha"
