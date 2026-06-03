#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  tools/publish_gate_dylib_artifact.sh \
    --artifact-id ID \
    --dylib PATH \
    --source-commit SHA \
    --parent-commit SHA \
    [--output-root DIR] \
    [--build-dir BUILD_DIR] \
    [--cmake-cache PATH] \
    [--cmake-build-type TYPE] \
    [--appgl-fp64-emulation ON|OFF] \
    [--appgl-vendor-third-party ON|OFF] \
    [--published-utc TIMESTAMP] \
    [--diagnostic-label TEXT] \
    [--no-current-lib] \
    [--metadata-only]

Publishes a lightweight gate artifact:
  gate-artifacts/ID/libAppGL.dylib
  gate-artifacts/ID/libAppGL.dylib.meta
  gate-artifacts/ID/libAppGL.dylib.sha256
  gate-artifacts/ID/SHA256SUMS
  gate-artifacts/ID/shape/binary-shape.txt

By default it also mirrors libAppGL.dylib, .meta, and .sha256 to current-lib/.
Release-shape enforcement is ON by default. Use --diagnostic-label for explicit
diagnostic/debug artifact opt-out; diagnostic artifacts still emit full shape
evidence.
EOF
}

die() {
    printf 'publish_gate_dylib_artifact: %s\n' "$*" >&2
    exit 2
}

cache_value() {
    local cache="$1"
    local key="$2"
    [ -f "$cache" ] || return 0
    awk -v key="$key" '
        index($0, key ":") == 1 || index($0, key "=") == 1 {
            eq = index($0, "=")
            if (eq > 0) {
                print substr($0, eq + 1)
                exit
            }
        }
    ' "$cache"
}

abs_path() {
    local path="$1"
    local dir
    dir="$(cd "$(dirname "$path")" && pwd)"
    printf '%s/%s\n' "$dir" "$(basename "$path")"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

artifact_id=""
dylib=""
source_commit=""
parent_commit=""
output_root="$repo_root/gate-artifacts"
build_dir=""
cmake_cache=""
cmake_build_type=""
appgl_fp64_emulation=""
appgl_vendor_third_party=""
published_utc=""
diagnostic_label=""
current_lib=1
metadata_only=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --artifact-id) artifact_id="${2:-}"; shift 2 ;;
        --dylib) dylib="${2:-}"; shift 2 ;;
        --source-commit) source_commit="${2:-}"; shift 2 ;;
        --parent-commit) parent_commit="${2:-}"; shift 2 ;;
        --output-root) output_root="${2:-}"; shift 2 ;;
        --build-dir) build_dir="${2:-}"; shift 2 ;;
        --cmake-cache) cmake_cache="${2:-}"; shift 2 ;;
        --cmake-build-type) cmake_build_type="${2:-}"; shift 2 ;;
        --appgl-fp64-emulation) appgl_fp64_emulation="${2:-}"; shift 2 ;;
        --appgl-vendor-third-party) appgl_vendor_third_party="${2:-}"; shift 2 ;;
        --published-utc) published_utc="${2:-}"; shift 2 ;;
        --diagnostic-label) diagnostic_label="${2:-}"; shift 2 ;;
        --no-current-lib) current_lib=0; shift ;;
        --metadata-only) metadata_only=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$artifact_id" ] || die "--artifact-id is required"
[ -n "$dylib" ] || die "--dylib is required"
[ -n "$source_commit" ] || die "--source-commit is required"
[ -n "$parent_commit" ] || die "--parent-commit is required"
[ -f "$dylib" ] || die "missing dylib: $dylib"

dylib="$(abs_path "$dylib")"
if [ -z "$build_dir" ]; then
    build_dir="$(dirname "$dylib")"
fi
build_dir="$(cd "$build_dir" && pwd)"
if [ -z "$cmake_cache" ]; then
    cmake_cache="$build_dir/CMakeCache.txt"
fi
if [ -f "$cmake_cache" ]; then
    cmake_cache="$(abs_path "$cmake_cache")"
fi

if [ -z "$cmake_build_type" ]; then
    cmake_build_type="$(cache_value "$cmake_cache" CMAKE_BUILD_TYPE)"
fi
if [ -z "$appgl_fp64_emulation" ]; then
    appgl_fp64_emulation="$(cache_value "$cmake_cache" APPGL_FP64_EMULATION)"
fi
if [ -z "$appgl_vendor_third_party" ]; then
    appgl_vendor_third_party="$(cache_value "$cmake_cache" APPGL_VENDOR_THIRD_PARTY)"
fi
[ -n "$cmake_build_type" ] || cmake_build_type="unknown"
[ -n "$appgl_fp64_emulation" ] || appgl_fp64_emulation="unknown"
[ -n "$appgl_vendor_third_party" ] || appgl_vendor_third_party="unknown"

output_root="$(mkdir -p "$output_root" && cd "$output_root" && pwd)"
artifact_dir="$output_root/$artifact_id"
dest="$artifact_dir/libAppGL.dylib"

mkdir -p "$artifact_dir/shape"
if [ "$metadata_only" -eq 0 ]; then
    cp -p "$dylib" "$dest"
elif [ "$dylib" != "$dest" ]; then
    die "--metadata-only requires --dylib to point at $dest"
fi

[ -f "$dest" ] || die "missing published dylib: $dest"

dylib_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
dylib_uuid="$(dwarfdump --uuid "$dest" | awk '/UUID:/ {print $2; exit}')"
dylib_arch="$(lipo -archs "$dest")"
dylib_size="$(stat -f '%z' "$dest")"
[ -n "$published_utc" ] || published_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

shape_report="$artifact_dir/shape/binary-shape.txt"
shape_args=(
    "$repo_root/tools/appgl_binary_shape_report.sh"
    --dylib "$dest"
    --out "$shape_report"
    --cmake-cache "$cmake_cache"
    --artifact-id "$artifact_id"
    --source-commit "$source_commit"
    --parent-commit "$parent_commit"
    --require-release-shape
)
if [ -n "$diagnostic_label" ]; then
    shape_args+=(--diagnostic-label "$diagnostic_label")
fi
"${shape_args[@]}"

release_shape_status="$(awk -F': ' '/^release_shape_status:/ {print $2; exit}' "$shape_report")"
nm_m_lines="$(awk -F': ' '/^nm_m_lines:/ {print $2; exit}' "$shape_report")"
stubs_size="$(awk -F': ' '/^__stubs_size_bytes:/ {print $2; exit}' "$shape_report")"
linkedit_filesize="$(awk -F': ' '/^__LINKEDIT_filesize:/ {print $2; exit}' "$shape_report")"
linkedit_vmsize="$(awk -F': ' '/^__LINKEDIT_vmsize:/ {print $2; exit}' "$shape_report")"
shape_sha="$(shasum -a 256 "$shape_report" | awk '{print $1}')"

meta="$dest.meta"
{
    printf 'artifact_id: %s\n' "$artifact_id"
    printf 'source_commit: %s\n' "$source_commit"
    printf 'parent_commit: %s\n' "$parent_commit"
    printf 'build_dir: %s\n' "$build_dir"
    printf 'cmake_cache: %s\n' "$cmake_cache"
    printf 'cmake_build_type: %s\n' "$cmake_build_type"
    printf 'appgl_fp64_emulation: %s\n' "$appgl_fp64_emulation"
    printf 'appgl_vendor_third_party: %s\n' "$appgl_vendor_third_party"
    [ -z "$diagnostic_label" ] || printf 'diagnostic_label: "%s"\n' "$diagnostic_label"
    printf 'dylib_sha256: %s\n' "$dylib_sha"
    printf 'dylib_uuid: %s\n' "$dylib_uuid"
    printf 'dylib_arch: %s\n' "$dylib_arch"
    printf 'dylib_size_bytes: %s\n' "$dylib_size"
    printf 'binary_shape_report: shape/binary-shape.txt\n'
    printf 'binary_shape_sha256: %s\n' "$shape_sha"
    printf 'release_shape_status: %s\n' "$release_shape_status"
    printf 'nm_m_lines: %s\n' "$nm_m_lines"
    printf '__stubs_size_bytes: %s\n' "$stubs_size"
    printf '__LINKEDIT_filesize: %s\n' "$linkedit_filesize"
    printf '__LINKEDIT_vmsize: %s\n' "$linkedit_vmsize"
    printf 'published_utc: %s\n' "$published_utc"
} > "$meta"
meta_sha="$(shasum -a 256 "$meta" | awk '{print $1}')"

printf '%s  %s\n' "$dylib_sha" "libAppGL.dylib" > "$artifact_dir/libAppGL.dylib.sha256"

if [ "$current_lib" -eq 1 ]; then
    mkdir -p "$artifact_dir/current-lib"
    cp -p "$dest" "$artifact_dir/current-lib/libAppGL.dylib"
    cp -p "$meta" "$artifact_dir/current-lib/libAppGL.dylib.meta"
    printf '%s  %s\n' "$dylib_sha" "current-lib/libAppGL.dylib" > "$artifact_dir/current-lib/libAppGL.dylib.sha256"
fi

(
    cd "$artifact_dir"
    {
        printf '%s  %s\n' "$dylib_sha" "libAppGL.dylib"
        [ "$current_lib" -eq 0 ] || printf '%s  %s\n' "$dylib_sha" "current-lib/libAppGL.dylib"
        printf '%s  %s\n' "$meta_sha" "libAppGL.dylib.meta"
        [ "$current_lib" -eq 0 ] || printf '%s  %s\n' "$meta_sha" "current-lib/libAppGL.dylib.meta"
        printf '%s  %s\n' "$shape_sha" "shape/binary-shape.txt"
    } > SHA256SUMS
)

printf '[publish] artifact: %s\n' "$artifact_dir"
printf '[publish] dylib_sha256: %s\n' "$dylib_sha"
printf '[publish] dylib_uuid: %s\n' "$dylib_uuid"
printf '[publish] dylib_arch: %s\n' "$dylib_arch"
printf '[publish] release_shape_status: %s\n' "$release_shape_status"
printf '[publish] shape: %s\n' "$shape_report"
printf '[publish] meta: %s\n' "$meta"
